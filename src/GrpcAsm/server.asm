; =============================================================================
; server.asm — the server's life: start every worker, serve, then drain and
; stop.
;
;   ga_server_start  start every worker (binding every listener); returns a
;                    handle, or 0 after undoing a partial startup
;   ga_server_stop   drain, stop and join every worker; free the handle
;   ga_server_run    start, serve until SIGTERM or SIGINT, stop: the whole
;                    lifecycle of a standalone server in one call
;
; ga_server_run moved out of KvServer's main.asm (KvAsm 60d7e81) in milestone
; B step 5b with the same steps, order and log lines ("listening", "shutdown
; requested", "worker startup failed"), which KvAsm's end-to-end suite reads.
; Milestone C step 1 split it into start and stop, so that a process whose
; runtime owns the signals (a .NET or Python host, through the C ABI) can run
; a server without giving them up.
;
; Signals: ga_server_start and ga_server_stop never touch them. Workers inherit
; the signal mask of the thread that calls ga_server_start, so a host that
; does not want its signal handlers to run on worker threads blocks those
; signals around that call. ga_server_run blocks SIGTERM and SIGINT in the
; calling thread before starting, so the workers inherit that, and the signals
; are only ever consumed by its sigwaitinfo. That also works as PID 1 in a
; container, where the default signal actions are ignored. A standalone caller
; should ignore SIGPIPE first (KvServer and the Greeter do): sockets use
; MSG_NOSIGNAL, and ignoring SIGPIPE is the belt and braces.
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"
%include "server.inc"
%include "log.inc"                      ; LOGBUF_BYTES sizes the log frames

%define SIGINT          2
%define SIGTERM         15
%define SIG_BLOCK       0

extern sigemptyset
extern sigaddset
extern pthread_sigmask
extern sigwaitinfo
extern calloc
extern free
extern ga_hpack_global_init
extern ga_worker_create
extern ga_worker_start
extern ga_worker_stop
extern ga_worker_join
extern ga_worker_destroy
extern ga_logb_init
extern ga_logb_str
extern ga_logb_cstr
extern ga_logb_u64
extern ga_logb_emit

; ---- GaServer: a running server (ga_server_start's handle) ----------------------
struc GaServer
    .cfg:       resq 1                  ; Config* (the caller's; read by every worker)
    .count:     resq 1                  ; workers, = Config.workers at start
    .workers:   resq 1                  ; Worker*[count]
endstruc

; ga_server_run's frame
%define F_SET       0               ; sigset_t (128 bytes)
%define F_INFO      128             ; siginfo_t (128 bytes)
%define F_LOG       256             ; LogBuf, LOGBUF_BYTES long
%define F_FRAME     (F_LOG + LOGBUF_BYTES)

; ga_server_run does 6 pushes and `sub rsp, F_FRAME + 8`; log_listening and
; log_startup_failed each do 1 push and `sub rsp, LOGBUF_BYTES`. Calls are
; 16-byte aligned only if those sizes are multiples of 16 (entry rsp is 8 mod
; 16): checked here, so that a LOGBUF_BYTES or frame change cannot misalign
; every call these make.
%if (F_FRAME % 16) != 0 || (F_LOG % 16) != 0 || (LOGBUF_BYTES % 16) != 0
    %error "server.asm frames: F_LOG, F_FRAME and LOGBUF_BYTES must be multiples of 16"
%endif

section .rodata
lvl_info:   db "INFO", 0
lvl_error:  db "ERROR", 0
m_listen:   db ' msg="listening" transport=h2c'
L_listen    equ $ - m_listen
k_port:     db " port="
k_workers:  db " workers="
m_shutdown: db ' msg="shutdown requested" signal='
L_shutdown  equ $ - m_shutdown
m_f_worker: db ' msg="worker startup failed"'
L_f_worker  equ $ - m_f_worker
k_step:     db " step="
; Which part of ga_server_start failed: the server's own memory, a worker's
; creation (worker.asm has logged the details: "worker setup failed step=..."),
; or a worker's thread.
st_alloc:   db "alloc", 0
st_create:  db "create", 0
st_start:   db "start", 0

section .text

global ga_server_start:function
global ga_server_stop:function
global ga_server_run:function

; -----------------------------------------------------------------------------
; LOGBEGIN level / LOGLIT literal, length / LOGNUM value / LOGEND — one log
; line built in the frame's LogBuf at [rsp + F_LOG] (log.asm).
; -----------------------------------------------------------------------------
%macro LOGBEGIN 1
    lea     rdi, [rsp + F_LOG]
    lea     rsi, [%1]
    call    ga_logb_init wrt ..plt
%endmacro
%macro LOGLIT 2
    lea     rdi, [rsp + F_LOG]
    lea     rsi, [%1]
    mov     edx, %2
    call    ga_logb_str wrt ..plt
%endmacro
%macro LOGNUM 1
    lea     rdi, [rsp + F_LOG]
    mov     rsi, %1
    call    ga_logb_u64 wrt ..plt
%endmacro
%macro LOGEND 0
    lea     rdi, [rsp + F_LOG]
    call    ga_logb_emit wrt ..plt
%endmacro

; =============================================================================
; ga_server_start — start every worker; the server then serves until
; ga_server_stop.
;
; @param  rdi  const Config* (Config.port, .workers, .max_streams, .max_conns,
;              .idle_timeout_ns, .grace_ns, .conn_budget and .max_request are
;              the engine's). It must stay valid and unchanged until
;              ga_server_stop has returned: every worker reads it.
; @param  rsi  the application's context, kept as Worker.app by every worker
;              (KvServer: its KvTable*; may be 0)
; @returns rax = the server's handle, or 0 when it could not start: then
;          "worker startup failed step=alloc|create|start" was logged and
;          everything this call made is undone (the workers that started are
;          stopped and joined, the others destroyed, the memory freed), so the
;          caller may simply report the failure.
; @remarks The steps: classify HPACK's static entries (ga_hpack_global_init,
;          idempotent; before any worker could decode); create every worker,
;          which binds every listener and calls ga_app_worker_init, so a port
;          that cannot be bound fails before any worker serves; start them
;          all; log "listening". The workers inherit the calling thread's
;          signal mask (see the file header). Not reentrant for one Config:
;          start each server once, and stop it once.
; =============================================================================
ga_server_start:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; [0] the failed step's name, on the failure
                                        ; paths; 6 pushes + 8: 16-aligned for calls
    mov     rbx, rdi                    ; Config*
    mov     rbp, rsi                    ; the application's context

    ; The HPACK decoder (hpack.asm) classifies the 61 static entries once,
    ; before any worker could decode a header block (read-only after).
    call    ga_hpack_global_init wrt ..plt

    mov     edi, 1
    mov     esi, GaServer_size
    call    calloc wrt ..plt
    test    rax, rax
    jz      .fail_alloc
    mov     r15, rax                    ; GaServer*
    mov     [r15 + GaServer.cfg], rbx
    mov     rax, [rbx + Config.workers]
    mov     [r15 + GaServer.count], rax
    mov     rdi, rax
    mov     esi, 8
    call    calloc wrt ..plt
    test    rax, rax
    jz      .fail_list
    mov     r14, rax                    ; Worker*[]
    mov     [r15 + GaServer.workers], r14

    xor     r12d, r12d                  ; workers created
.create:
    cmp     r12, [r15 + GaServer.count]
    jae     .start
    mov     rdi, r12
    mov     rsi, rbp
    mov     rdx, rbx
    call    ga_worker_create wrt ..plt
    test    rax, rax
    jz      .fail_create
    mov     [r14 + r12*8], rax
    inc     r12
    jmp     .create
.start:
    xor     r13d, r13d                  ; workers started
.start_next:
    cmp     r13, r12
    jae     .running
    mov     rdi, [r14 + r13*8]
    call    ga_worker_start wrt ..plt
    test    eax, eax
    jnz     .fail_start                 ; (pthread_create failure)
    inc     r13
    jmp     .start_next

.running:
    mov     rdi, rbx
    call    log_listening
    mov     rax, r15
    jmp     .return

.fail_start:
    ; Workers [0, r13) run: stop them all first (each drains), then join them
    ; (ga_worker_join frees each). Workers [r13, r12) were created only.
    lea     rax, [st_start]
    mov     [rsp], rax
    xor     ebp, ebp
.fs_stop:
    cmp     rbp, r13
    jae     .fs_join
    mov     rdi, [r14 + rbp*8]
    call    ga_worker_stop wrt ..plt
    inc     rbp
    jmp     .fs_stop
.fs_join:
    xor     ebp, ebp
.fs_join_next:
    cmp     rbp, r13
    jae     .fs_unstarted
    mov     rdi, [r14 + rbp*8]
    xor     esi, esi                    ; no counters wanted
    call    ga_worker_join wrt ..plt
    inc     rbp
    jmp     .fs_join_next
.fs_unstarted:
    mov     rbp, r13                    ; destroy [r13, r12) below
    jmp     .destroy_from
.fail_create:
    lea     rax, [st_create]
    mov     [rsp], rax
    xor     ebp, ebp                    ; destroy [0, r12): none started
.destroy_from:
    cmp     rbp, r12
    jae     .free_list
    mov     rdi, [r14 + rbp*8]
    call    ga_worker_destroy wrt ..plt
    inc     rbp
    jmp     .destroy_from
.free_list:
    mov     rdi, r14
    call    free wrt ..plt
.free_server:
    mov     rdi, r15
    call    free wrt ..plt
    jmp     .log_failure
.fail_list:
    lea     rax, [st_alloc]
    mov     [rsp], rax
    jmp     .free_server
.fail_alloc:
    lea     rax, [st_alloc]
    mov     [rsp], rax
.log_failure:
    mov     rdi, [rsp]
    call    log_startup_failed
    xor     eax, eax
.return:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; ga_server_stop — drain, stop and join every worker, then free the server.
; @param  rdi  the handle from ga_server_start (invalid afterwards)
; @param  rsi  uint64_t totals[3] out: the connections accepted, the requests
;              and the errors, summed over the workers; or 0
; @returns nothing; returns once every worker has exited.
; @remarks Callable from any thread, exactly once per handle. Every worker is
;          told to stop first (each closes its listener, sends GOAWAY, lets
;          the calls in flight finish, and closes what remains after
;          Config.grace_ns), then they are joined, so the drains run in
;          parallel and the whole stop takes about one grace period at most.
; =============================================================================
ga_server_stop:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                         ; 5 pushes: rsp 16-aligned for calls
    sub     rsp, 32                     ; [0..24) one worker's counters
    mov     rbx, rdi                    ; GaServer*
    mov     r15, rsi                    ; totals, or 0
    mov     r14, [rbx + GaServer.workers]
    xor     r12d, r12d
.stop_next:
    cmp     r12, [rbx + GaServer.count]
    jae     .join
    mov     rdi, [r14 + r12*8]
    call    ga_worker_stop wrt ..plt
    inc     r12
    jmp     .stop_next
.join:
    test    r15, r15
    jz      .join_start
    xor     eax, eax
    mov     [r15], rax
    mov     [r15 + 8], rax
    mov     [r15 + 16], rax
.join_start:
    xor     r12d, r12d
.join_next:
    cmp     r12, [rbx + GaServer.count]
    jae     .joined
    mov     rdi, [r14 + r12*8]
    mov     rsi, rsp
    call    ga_worker_join wrt ..plt
    test    r15, r15
    jz      .joined_one
    mov     rax, [rsp]
    add     [r15], rax
    mov     rax, [rsp + 8]
    add     [r15 + 8], rax
    mov     rax, [rsp + 16]
    add     [r15 + 16], rax
.joined_one:
    inc     r12
    jmp     .join_next
.joined:
    mov     rdi, r14
    call    free wrt ..plt
    mov     rdi, rbx
    call    free wrt ..plt
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; ga_server_run — run the server until SIGTERM or SIGINT, then drain and stop.
;
; @param  rdi  const Config* (as for ga_server_start)
; @param  rsi  the application's context (as for ga_server_start)
; @param  rdx  the totals, 3 x u64 written after a clean shutdown (as for
;              ga_server_stop), or 0
; @returns eax = 0 after a clean shutdown, 1 when the server could not start
;          ("worker startup failed" was logged; nothing is left running).
; @remarks Blocks SIGTERM and SIGINT in this thread first (the workers inherit
;          the mask, so only this function's sigwaitinfo consumes them; EINTR
;          keeps waiting), then ga_server_start, which logs "listening". On a
;          signal it logs "shutdown requested signal=N" and calls
;          ga_server_stop. The caller is expected to have checked the port
;          with ga_port_probe before its own long setup, so that a busy port
;          fails fast.
; =============================================================================
ga_server_run:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, F_FRAME + 8            ; 6 pushes + frame + 8 => 16-aligned
    mov     rbx, rdi                    ; Config*
    mov     rbp, rsi                    ; the application's context
    mov     r15, rdx                    ; the totals, or 0

    lea     rdi, [rsp + F_SET]
    call    sigemptyset wrt ..plt
    lea     rdi, [rsp + F_SET]
    mov     esi, SIGTERM
    call    sigaddset wrt ..plt
    lea     rdi, [rsp + F_SET]
    mov     esi, SIGINT
    call    sigaddset wrt ..plt
    mov     edi, SIG_BLOCK
    lea     rsi, [rsp + F_SET]
    xor     edx, edx
    call    pthread_sigmask wrt ..plt

    mov     rdi, rbx
    mov     rsi, rbp
    call    ga_server_start
    test    rax, rax
    jz      .failed
    mov     r14, rax                    ; GaServer*

.wait_signal:
    lea     rdi, [rsp + F_SET]
    lea     rsi, [rsp + F_INFO]
    call    sigwaitinfo wrt ..plt
    test    eax, eax
    js      .wait_signal                ; EINTR: keep waiting
    mov     r13d, eax
    LOGBEGIN lvl_info
    LOGLIT  m_shutdown, L_shutdown
    LOGNUM  r13
    LOGEND

    mov     rdi, r14
    mov     rsi, r15
    call    ga_server_stop
    xor     eax, eax
    jmp     .return
.failed:
    mov     eax, 1
.return:
    add     rsp, F_FRAME + 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; log_listening — the "listening transport=h2c port=N workers=N" line.
; Internal.
; @param  rdi  const Config*
; @returns nothing.
; @remarks Its own frame holds the LogBuf (at rsp), so ga_server_start keeps a
;          small frame. 1 push + LOGBUF_BYTES (a multiple of 16, checked
;          above): calls are 16-byte aligned.
; =============================================================================
log_listening:
    push    rbx
    sub     rsp, LOGBUF_BYTES
    mov     rbx, rdi                    ; Config*
    mov     rdi, rsp
    lea     rsi, [lvl_info]
    call    ga_logb_init wrt ..plt
    mov     rdi, rsp
    lea     rsi, [m_listen]
    mov     edx, L_listen
    call    ga_logb_str wrt ..plt
    mov     rdi, rsp
    lea     rsi, [k_port]
    mov     edx, 6
    call    ga_logb_str wrt ..plt
    mov     rdi, rsp
    mov     rsi, [rbx + Config.port]
    call    ga_logb_u64 wrt ..plt
    mov     rdi, rsp
    lea     rsi, [k_workers]
    mov     edx, 9
    call    ga_logb_str wrt ..plt
    mov     rdi, rsp
    mov     rsi, [rbx + Config.workers]
    call    ga_logb_u64 wrt ..plt
    mov     rdi, rsp
    call    ga_logb_emit wrt ..plt
    add     rsp, LOGBUF_BYTES
    pop     rbx
    ret

; =============================================================================
; log_startup_failed — the "worker startup failed step=..." line. Internal.
; @param  rdi  the step's name (NUL-terminated: alloc, create or start)
; @returns nothing.
; @remarks The LogBuf is at rsp. 1 push + LOGBUF_BYTES (a multiple of 16,
;          checked above): calls are 16-byte aligned.
; =============================================================================
log_startup_failed:
    push    rbx
    sub     rsp, LOGBUF_BYTES
    mov     rbx, rdi                    ; the step's name
    mov     rdi, rsp
    lea     rsi, [lvl_error]
    call    ga_logb_init wrt ..plt
    mov     rdi, rsp
    lea     rsi, [m_f_worker]
    mov     edx, L_f_worker
    call    ga_logb_str wrt ..plt
    mov     rdi, rsp
    lea     rsi, [k_step]
    mov     edx, 6
    call    ga_logb_str wrt ..plt
    mov     rdi, rsp
    mov     rsi, rbx
    call    ga_logb_cstr wrt ..plt
    mov     rdi, rsp
    call    ga_logb_emit wrt ..plt
    add     rsp, LOGBUF_BYTES
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
