; =============================================================================
; server.asm — the server's life: start every worker, serve until SIGTERM or
; SIGINT, then drain and stop.
;
;   ga_server_run   the whole lifecycle in one call, for an application's
;                   main once its own setup (configuration, data) is done
;
; Moved out of KvServer's main.asm (KvAsm 60d7e81) in milestone B step 5b,
; with the same steps, in the same order, and the same log lines
; ("listening", "shutdown requested", "worker startup failed"), so KvAsm's
; end-to-end suite, which reads them, still pins the behavior.
;
; Signals: SIGTERM and SIGINT are blocked in the calling thread before any
; worker exists. Workers inherit the mask, so the signals are only ever
; consumed by this function's sigwaitinfo. That also works as PID 1 in a
; container, where the default signal actions are ignored. The caller should
; ignore SIGPIPE before calling (KvServer and the Greeter do): sockets use
; MSG_NOSIGNAL, and ignoring SIGPIPE is the belt and braces.
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"
%include "server.inc"
%include "log.inc"                      ; LOGBUF_BYTES sizes the frame's log slot

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
extern ga_logb_init
extern ga_logb_str
extern ga_logb_u64
extern ga_logb_emit

; ga_server_run's frame
%define F_SET       0               ; sigset_t (128 bytes)
%define F_INFO      128             ; siginfo_t (128 bytes)
%define F_STATS     256             ; one worker's counters (3 x u64)
%define F_TOTALS    280             ; the sums (3 x u64)
%define F_LOG       304             ; LogBuf, LOGBUF_BYTES long
%define F_FRAME     (F_LOG + LOGBUF_BYTES)

; The prologue does 6 pushes and `sub rsp, F_FRAME + 8`. Calls are only
; 16-byte aligned if F_FRAME is a multiple of 16 (entry rsp is 8 mod 16,
; 6 pushes keep it there, the extra 8 fixes it). Checked here, so that a
; LOGBUF_BYTES or frame change cannot misalign every call this makes.
%if (F_FRAME % 16) != 0 || (F_LOG % 16) != 0
    %error "ga_server_run frame: F_LOG and F_FRAME must be multiples of 16"
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

section .text

global ga_server_run:function

; -----------------------------------------------------------------------------
; LOGBEGIN level / LOGLIT literal, length / LOGNUM value / LOGEND — one log
; line built in the frame's LogBuf (log.asm), as KvServer's main builds its own.
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
; ga_server_run — run the server until SIGTERM or SIGINT, then drain and stop.
;
; @param  rdi  const Config* (Config.port, .workers, .max_streams, .max_conns,
;              .idle_timeout_ns, .grace_ns, .conn_budget and .max_request are
;              the engine's; read-only from here on, by every worker)
; @param  rsi  the application's context, kept as Worker.app by every worker
;              (KvServer: its KvTable*; may be 0)
; @param  rdx  the totals, 3 x u64 written after a clean shutdown: the
;              connections accepted, the requests and the errors, summed over
;              the workers; or 0 when the caller does not want them
; @returns eax = 0 after a clean shutdown, 1 when a worker could not be
;          created or started (logged "worker startup failed"; the caller
;          should exit at once, since workers that did start keep running).
; @remarks The steps, in order: block SIGTERM and SIGINT in this thread;
;          classify HPACK's static entries (ga_hpack_global_init, once,
;          before any worker could decode); create every worker, which binds
;          every listener, so a port that cannot be bound fails startup before
;          any worker serves; start them all; log "listening"; wait in
;          sigwaitinfo (EINTR keeps waiting); log "shutdown requested"; stop
;          every worker (each drains its connections within Config.grace_ns);
;          join them, summing their counters; free the worker list.
;          ga_worker_create calls the application's ga_app_worker_init, so a
;          failing init also lands on the "worker startup failed" path. The
;          caller is expected to have checked the port with ga_port_probe
;          before its own long setup, so that a busy port fails fast.
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

    ; The HPACK decoder (hpack.asm) classifies the 61 static entries once,
    ; before any worker could decode a header block (read-only after).
    call    ga_hpack_global_init wrt ..plt

    mov     rdi, [rbx + Config.workers]
    mov     esi, 8
    call    calloc wrt ..plt
    test    rax, rax
    jz      .failed
    mov     r14, rax                    ; Worker*[]
    xor     r12d, r12d
.create:
    cmp     r12, [rbx + Config.workers]
    jae     .start
    mov     rdi, r12
    mov     rsi, rbp
    mov     rdx, rbx
    call    ga_worker_create wrt ..plt
    test    rax, rax
    jz      .failed
    mov     [r14 + r12*8], rax
    inc     r12
    jmp     .create
.start:
    xor     r12d, r12d
.start_next:
    cmp     r12, [rbx + Config.workers]
    jae     .running
    mov     rdi, [r14 + r12*8]
    call    ga_worker_start wrt ..plt
    test    eax, eax
    jnz     .failed                     ; (pthread_create failure: fatal)
    inc     r12
    jmp     .start_next

.running:
    LOGBEGIN lvl_info
    LOGLIT  m_listen, L_listen
    LOGLIT  k_port, 6
    LOGNUM  [rbx + Config.port]
    LOGLIT  k_workers, 9
    LOGNUM  [rbx + Config.workers]
    LOGEND

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

    xor     r12d, r12d
.stop_next:
    cmp     r12, [rbx + Config.workers]
    jae     .join
    mov     rdi, [r14 + r12*8]
    call    ga_worker_stop wrt ..plt
    inc     r12
    jmp     .stop_next
.join:
    xor     eax, eax
    mov     [rsp + F_TOTALS], rax
    mov     [rsp + F_TOTALS + 8], rax
    mov     [rsp + F_TOTALS + 16], rax
    xor     r12d, r12d
.join_next:
    cmp     r12, [rbx + Config.workers]
    jae     .joined
    mov     rdi, [r14 + r12*8]
    lea     rsi, [rsp + F_STATS]
    call    ga_worker_join wrt ..plt
    mov     rax, [rsp + F_STATS]
    add     [rsp + F_TOTALS], rax
    mov     rax, [rsp + F_STATS + 8]
    add     [rsp + F_TOTALS + 8], rax
    mov     rax, [rsp + F_STATS + 16]
    add     [rsp + F_TOTALS + 16], rax
    inc     r12
    jmp     .join_next
.joined:
    mov     rdi, r14
    call    free wrt ..plt
    test    r15, r15
    jz      .clean                      ; the caller does not want the totals
    mov     rax, [rsp + F_TOTALS]
    mov     [r15], rax
    mov     rax, [rsp + F_TOTALS + 8]
    mov     [r15 + 8], rax
    mov     rax, [rsp + F_TOTALS + 16]
    mov     [r15 + 16], rax
.clean:
    xor     eax, eax
    jmp     .return

.failed:
    ; Workers created so far never started (or some did): stopping and
    ; joining the started ones would need bookkeeping; a startup failure is
    ; fatal and the process exits at once, letting the kernel reclaim
    ; everything.
    LOGBEGIN lvl_error
    LOGLIT  m_f_worker, L_f_worker
    LOGEND
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

section .note.GNU-stack noalloc noexec nowrite progbits
