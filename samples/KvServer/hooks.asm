; =============================================================================
; hooks.asm — KvServer's worker hooks for the GrpcAsm engine.
;
; The engine's worker calls these at fixed points, each with the Worker* in
; rdi (contracts: src/GrpcAsm/include/grpcasm_hooks.inc). They run exactly
; the KV store code that the worker used to call directly (KvAsm 60d7e81):
; the private L1/L2 record cache, QSBR (quiescent-state-based reclamation: a
; worker is "online" while it may hold record pointers) and the reclamation
; of retired records.
;
; Worker.app is the context main passed to ga_worker_create, here the
; KvTable*. Worker.app_worker is this worker's private cache (HCache*), or 0
; when caching is off.
; =============================================================================

default rel
bits 64

%include "kvasm.inc"
%include "server.inc"

extern kv_hcache_create
extern kv_hcache_destroy
extern kv_qsbr_online
extern kv_qsbr_offline
extern kv_store_reclaim
extern kv_store_reclaim_local

section .text

; =============================================================================
; ga_app_worker_init — create this worker's private record cache, if any.
; @param  rdi  Worker* (id, cfg and app set; app_worker still 0)
; @returns rax = 0 (created, or caching is off), or -ENOMEM (the cache could
;          not be allocated: the engine fails the worker's creation).
; @remarks Caching is on when KVASM_CACHE_L1_BITS or _L2_BITS is non-zero
;          (ADR 0006); main enabled the table's invalidation generations
;          before any worker was created. The push both saves rbx and aligns
;          the stack for the call (rsp = 16n + 8 on entry).
; =============================================================================
global ga_app_worker_init:function
ga_app_worker_init:
    mov     rax, [rdi + Worker.cfg]
    mov     rsi, [rax + Config.cache_l1_bits]
    mov     rdx, [rax + Config.cache_l2_bits]
    mov     rcx, rsi
    or      rcx, rdx
    jz      .ok                         ; caching off: no per-worker state
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx + Worker.app]     ; KvTable*; rsi, rdx = L1 and L2 bits
    call    kv_hcache_create wrt ..plt
    mov     [rbx + Worker.app_worker], rax
    pop     rbx
    test    rax, rax
    jz      .failed
.ok:
    xor     eax, eax
    ret
.failed:
    mov     rax, -ENOMEM
    ret

; =============================================================================
; ga_app_worker_fini — free this worker's private record cache.
; @param  rdi  Worker*
; @returns nothing.
; @remarks Safe after a failed or skipped init: kv_hcache_destroy ignores 0.
;          A tail call: the callee returns straight to the engine, with the
;          stack exactly as at this hook's entry.
; =============================================================================
global ga_app_worker_fini:function
ga_app_worker_fini:
    mov     rdi, [rdi + Worker.app_worker]
    jmp     kv_hcache_destroy wrt ..plt

; =============================================================================
; ga_app_worker_resume — the worker is about to touch the store: go online.
; @param  rdi  Worker*
; @returns nothing.
; @remarks kv_qsbr_online publishes the worker's reader slot with an XCHG,
;          the fence that orders the worker's later reads of the table after
;          the announcement (store.asm). The worker id is the slot. Tail call.
; =============================================================================
global ga_app_worker_resume:function
ga_app_worker_resume:
    mov     esi, [rdi + Worker.id]      ; read before rdi is overwritten
    mov     rdi, [rdi + Worker.app]
    jmp     kv_qsbr_online wrt ..plt

; =============================================================================
; ga_app_worker_pause — the worker is about to sleep or exit: go offline.
; @param  rdi  Worker*
; @returns nothing.
; @remarks Offline is also a quiescent state, so a sleeping worker never holds
;          up reclamation. Tail call.
; =============================================================================
global ga_app_worker_pause:function
ga_app_worker_pause:
    mov     esi, [rdi + Worker.id]      ; read before rdi is overwritten
    mov     rdi, [rdi + Worker.app]
    jmp     kv_qsbr_offline wrt ..plt

; =============================================================================
; ga_app_worker_tick — periodic reclamation, once per housekeeping pass.
; @param  rdi  Worker*
; @returns nothing.
; @remarks This worker's own slot first (ADR 0011): its batched writes retired
;          records there and only it may free them; after a burst of writes
;          the last batches' records would otherwise wait for its next write.
;          The budget is the forced-reclamation one (store.asm
;          RECLAIM_BATCH_FORCE). Worker 0 then drains the global limbo, which
;          the per-write paths fill. The push both saves rbx and aligns the
;          stack for the calls.
; =============================================================================
global ga_app_worker_tick:function
ga_app_worker_tick:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx + Worker.app]
    mov     esi, [rbx + Worker.id]
    mov     edx, 4096
    call    kv_store_reclaim_local wrt ..plt
    cmp     qword [rbx + Worker.id], 0
    jne     .out
    mov     rdi, [rbx + Worker.app]
    call    kv_store_reclaim wrt ..plt  ; the global limbo (per-write paths)
.out:
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
