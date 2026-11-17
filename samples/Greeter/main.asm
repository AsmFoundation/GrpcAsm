; =============================================================================
; main.asm — the Greeter's process: settings, then the engine's server.
;
; Startup, in this order:
;   1. ignore SIGPIPE (sockets also use MSG_NOSIGNAL; belt and braces)
;   2. settings from the environment, parsed strictly (decimal digits only, no
;      sign, no whitespace, no overflow, range-checked): an invalid value is
;      logged with its name and the process exits 2, because a typo must never
;      fall back to a default
;        GREETER_PORT      1..65535   default 50051
;        GREETER_WORKERS   1..256     default 1
;      Everything else the engine reads has a fixed value, KvServer's
;      defaults: 100 streams per connection, 10,000 connections per worker,
;      a 300 s idle timeout, a 10 s shutdown grace and a 64 MiB per-connection
;      buffering budget. The request limit is 4 MiB, gRPC's usual maximum
;      message size.
;   3. refuse a port another process holds (ga_port_probe)       (exit 1)
;   4. ga_server_run: block the signals, start the workers, serve until
;      SIGTERM or SIGINT, drain, join                             (exit 1 if a
;      worker cannot start)
; Shutdown ends with a "stopped" line carrying the engine's counters, and
; exit 0.
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"
%include "server.inc"
%include "log.inc"                      ; LOGBUF_BYTES sizes main's log slot

%define SIGPIPE         13
%define SIG_IGN         1

%define DEFAULT_PORT    50051
%define DEFAULT_WORKERS 1
%define MAX_WORKERS     256

extern signal
extern getenv
extern ga_port_probe
extern ga_server_run
extern ga_logb_init
extern ga_logb_str
extern ga_logb_cstr
extern ga_logb_u64
extern ga_logb_emit

; main's frame
%define F_TOTALS    0               ; ga_server_run's totals (3 x u64)
%define F_LOG       32              ; LogBuf lives here, LOGBUF_BYTES long
%define F_FRAME     (F_LOG + LOGBUF_BYTES)

; The prologue does 2 pushes and `sub rsp, F_FRAME + 8`. Entry rsp is 8 mod
; 16 and the 2 pushes leave it there, so calls are 16-byte aligned exactly
; when F_FRAME is a multiple of 16: checked here.
%if (F_FRAME % 16) != 0 || (F_LOG % 16) != 0
    %error "main frame: F_LOG and F_FRAME must be multiples of 16"
%endif

section .rodata
lvl_info:   db "INFO", 0
lvl_error:  db "ERROR", 0
m_starting: db ' msg="starting" service=helloworld.Greeter'
L_starting  equ $ - m_starting
k_port:     db " port="
k_workers:  db " workers="
m_invalid:  db ' msg="invalid setting" name='
L_invalid   equ $ - m_invalid
m_f_port:   db ' msg="port already in use, refusing to share it"'
L_f_port    equ $ - m_f_port
k_errno:    db " errno="
m_stopped:  db ' msg="stopped" connections='
L_stopped   equ $ - m_stopped
k_requests: db " requests="
k_errors:   db " errors="
n_port:     db "GREETER_PORT", 0
n_workers:  db "GREETER_WORKERS", 0

; Section-level alignment instead of `alignb` (NASM's alignb emits warning
; pragmas that -w+all -w+error rejects). Config is written once before any
; thread starts, then only read.
section .bss align=64
g_cfg:      resb Config_size

section .text

global main

; -----------------------------------------------------------------------------
; LOGBEGIN level / LOGLIT literal, length / LOGNUM value / LOGEND — one log
; line built in the frame's LogBuf (log.asm).
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
; main — see the file header.
; @param  edi  argc (unused: settings come from the environment)
; @param  rsi  argv (unused)
; @returns eax = 0 after a clean shutdown, 1 on a startup failure (port in
;          use, a worker that could not start), 2 on an invalid setting.
; =============================================================================
main:
    push    rbx
    push    r15
    sub     rsp, F_FRAME + 8            ; 2 pushes + frame + 8 => 16-aligned

    mov     edi, SIGPIPE
    mov     esi, SIG_IGN
    call    signal wrt ..plt

    lea     r15, [g_cfg]                ; .bss: every other field is 0
    lea     rdi, [n_port]
    mov     esi, 1
    mov     edx, 65535
    mov     ecx, DEFAULT_PORT
    call    env_u64
    test    rax, rax
    js      .bad_port
    mov     [r15 + Config.port], rax
    lea     rdi, [n_workers]
    mov     esi, 1
    mov     edx, MAX_WORKERS
    mov     ecx, DEFAULT_WORKERS
    call    env_u64
    test    rax, rax
    js      .bad_workers
    mov     [r15 + Config.workers], rax
    mov     qword [r15 + Config.max_streams], 100
    mov     qword [r15 + Config.max_conns], 10000
    mov     rax, 300 * 1000000000
    mov     [r15 + Config.idle_timeout_ns], rax
    mov     rax, 10 * 1000000000
    mov     [r15 + Config.grace_ns], rax
    mov     qword [r15 + Config.conn_budget], 64 * 1048576
    mov     qword [r15 + Config.max_request], 4 * 1048576

    LOGBEGIN lvl_info
    LOGLIT  m_starting, L_starting
    LOGLIT  k_port, 6
    LOGNUM  [r15 + Config.port]
    LOGLIT  k_workers, 9
    LOGNUM  [r15 + Config.workers]
    LOGEND

    ; Refuse to join another process's SO_REUSEPORT group (ga_port_probe
    ; explains the split-brain this prevents).
    mov     rdi, [r15 + Config.port]
    call    ga_port_probe wrt ..plt
    test    rax, rax
    jz      .serve
    neg     rax
    mov     rbx, rax                    ; errno (98 = EADDRINUSE)
    LOGBEGIN lvl_error
    LOGLIT  m_f_port, L_f_port
    LOGLIT  k_port, 6
    LOGNUM  [r15 + Config.port]
    LOGLIT  k_errno, 7
    LOGNUM  rbx
    LOGEND
    mov     eax, 1
    jmp     .return

.serve:
    mov     rdi, r15                    ; Config*
    xor     esi, esi                    ; no application context: Worker.app = 0
    lea     rdx, [rsp + F_TOTALS]
    call    ga_server_run wrt ..plt
    test    eax, eax
    jnz     .return                     ; 1: "worker startup failed" was logged
    LOGBEGIN lvl_info
    LOGLIT  m_stopped, L_stopped
    LOGNUM  [rsp + F_TOTALS]
    LOGLIT  k_requests, 10
    LOGNUM  [rsp + F_TOTALS + 8]
    LOGLIT  k_errors, 8
    LOGNUM  [rsp + F_TOTALS + 16]
    LOGEND
    xor     eax, eax
    jmp     .return

.bad_port:
    lea     rbx, [n_port]
    jmp     .bad_setting
.bad_workers:
    lea     rbx, [n_workers]
.bad_setting:
    LOGBEGIN lvl_error
    LOGLIT  m_invalid, L_invalid
    lea     rdi, [rsp + F_LOG]
    mov     rsi, rbx
    call    ga_logb_cstr wrt ..plt
    LOGEND
    mov     eax, 2
.return:
    add     rsp, F_FRAME + 8
    pop     r15
    pop     rbx
    ret

; =============================================================================
; env_u64 — a strict decimal setting from the environment. Internal.
; @param  rdi  the variable's name (NUL-terminated)
; @param  rsi  the smallest value accepted   @param rdx  the largest
; @param  rcx  the value when the variable is unset
; @returns rax = the value, or -1 when the variable is set but invalid: empty,
;          a character other than 0-9, more than 19 digits (no overflow is
;          possible below that), or outside [rsi, rdx].
; @remarks An unset variable takes the default; a set one must be valid. The
;          three pushes also align the stack for getenv (entry rsp = 16n + 8).
; =============================================================================
env_u64:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi                    ; min
    mov     r13, rdx                    ; max
    mov     rbx, rcx                    ; default
    call    getenv wrt ..plt
    test    rax, rax
    jz      .default
    xor     edx, edx                    ; the value
    xor     ecx, ecx                    ; digits seen
.digit:
    movzx   r8d, byte [rax + rcx]
    test    r8d, r8d
    jz      .end
    sub     r8d, '0'
    cmp     r8d, 9
    ja      .bad                        ; not a decimal digit (unsigned: below '0' too)
    inc     ecx
    cmp     ecx, 19
    ja      .bad                        ; 19 digits always fit in 64 bits
    imul    rdx, rdx, 10
    add     rdx, r8
    jmp     .digit
.end:
    test    ecx, ecx
    jz      .bad                        ; set but empty
    cmp     rdx, r12
    jb      .bad
    cmp     rdx, r13
    ja      .bad
    mov     rax, rdx
    jmp     .out
.default:
    mov     rax, rbx
    jmp     .out
.bad:
    mov     rax, -1
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
