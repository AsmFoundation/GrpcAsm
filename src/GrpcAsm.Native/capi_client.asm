; =============================================================================
; capi_client.asm — the client half of GrpcAsm's C ABI (include/grpcasm.h):
; grpcasm_client_* over the engine's client (client.asm, ga_client_*).
;
; Almost everything is a tail jump: the engine's client functions already use
; the System V convention, the same argument order and negative-errno results
; as the header promises. A C call therefore costs one jmp more than calling
; the engine from NASM. What is adapted here:
;   * grpcasm_client_options, a size-versioned struct of 32-bit fields
;     (fields beyond the caller's `size` are defaults, like the server's
;     grpcasm_options), becomes the engine's GaClientConfig;
;   * NUL-terminated C strings (method paths, the authority) get their lengths;
;   * grpcasm_client_output returns the length and stores the pointer, where
;     the engine returns both in registers.
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"
%include "grpcasm_client.inc"           ; GaClientConfig and the ga_client_* externs

extern strlen

global grpcasm_client_new
global grpcasm_client_connect
global grpcasm_client_free
global grpcasm_client_method
global grpcasm_client_call
global grpcasm_client_unary
global grpcasm_client_poll
global grpcasm_client_flush
global grpcasm_client_fd
global grpcasm_client_input
global grpcasm_client_output
global grpcasm_client_consume

; grpcasm_client_options (grpcasm.h): its offsets.
%define CO_SIZE         0               ; uint32_t size
%define CO_MAX_RESPONSE 4               ; uint32_t max_response_bytes
%define CO_MAX_CALLS    8               ; uint32_t max_concurrent_calls
%define CO_CONNECT_MS   12              ; uint32_t connect_timeout_ms
%define CO_AUTHORITY    16              ; const char *authority

section .text

; =============================================================================
; client_config — grpcasm_client_options into a GaClientConfig. Internal.
; @param  rdi  const grpcasm_client_options*, or NULL (every default)
; @param  rsi  GaClientConfig* to fill
; @returns eax = 0, or -EINVAL (a size that does not cover itself, or an
;          authority that is empty or longer than 255 bytes).
; @remarks A field is read only when the caller's size covers it, so a program
;          built against an older, shorter struct gets defaults for the rest.
;          Range checks of the numbers are the engine's (ga_client_new).
; =============================================================================
client_config:
    push    rbx
    push    r12
    push    r13                         ; 3 pushes: aligned
    mov     rbx, rdi
    mov     r12, rsi
    xor     eax, eax
    mov     [r12 + GaClientConfig.authority], rax
    mov     [r12 + GaClientConfig.authority_len], rax
    mov     [r12 + GaClientConfig.max_response], rax
    mov     [r12 + GaClientConfig.max_calls], rax
    mov     [r12 + GaClientConfig.connect_ms], rax
    test    rbx, rbx
    jz      .ok
    mov     r13d, [rbx + CO_SIZE]
    cmp     r13d, 4
    jb      .einval
    cmp     r13d, CO_MAX_RESPONSE + 4
    jb      .ok
    mov     eax, [rbx + CO_MAX_RESPONSE]
    mov     [r12 + GaClientConfig.max_response], rax
    cmp     r13d, CO_MAX_CALLS + 4
    jb      .ok
    mov     eax, [rbx + CO_MAX_CALLS]
    mov     [r12 + GaClientConfig.max_calls], rax
    cmp     r13d, CO_CONNECT_MS + 4
    jb      .ok
    mov     eax, [rbx + CO_CONNECT_MS]
    mov     [r12 + GaClientConfig.connect_ms], rax
    cmp     r13d, CO_AUTHORITY + 8
    jb      .ok
    mov     rdi, [rbx + CO_AUTHORITY]
    test    rdi, rdi
    jz      .ok
    mov     [r12 + GaClientConfig.authority], rdi
    call    strlen wrt ..plt
    test    rax, rax
    jz      .einval
    cmp     rax, GC_MAX_AUTHORITY
    ja      .einval
    mov     [r12 + GaClientConfig.authority_len], rax
.ok:
    xor     eax, eax
    jmp     .out
.einval:
    mov     eax, -EINVAL
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; grpcasm_client_new — a client without a socket (grpcasm.h).
; @param  rdi  const grpcasm_client_options* or NULL
; @param  rsi  grpcasm_client** out
; @returns eax = 0, -EINVAL or -ENOMEM (ga_client_new).
; =============================================================================
grpcasm_client_new:
    push    rbx
    sub     rsp, 48                     ; [0..40) GaClientConfig; 1 push + 48: aligned
    mov     rbx, rsi
    test    rbx, rbx
    jz      .einval
    mov     qword [rbx], 0
    mov     rsi, rsp
    call    client_config
    test    eax, eax
    jnz     .out
    mov     rdi, rsp
    mov     rsi, rbx
    call    ga_client_new wrt ..plt
    jmp     .out
.einval:
    mov     eax, -EINVAL
.out:
    add     rsp, 48
    pop     rbx
    ret

; =============================================================================
; grpcasm_client_connect — connect a client to host:port (grpcasm.h).
; @param  rdi  const char *host   @param esi  uint16_t port
; @param  rdx  const grpcasm_client_options* or NULL
; @param  rcx  grpcasm_client** out
; @returns eax = 0, or ga_client_connect's negative errno.
; =============================================================================
grpcasm_client_connect:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56                     ; [0..40) GaClientConfig; 4 pushes + 56: aligned
    mov     r12, rdi
    movzx   r13d, si
    mov     r14, rcx
    test    r14, r14
    jz      .einval
    mov     qword [r14], 0
    mov     rdi, rdx
    mov     rsi, rsp
    call    client_config
    test    eax, eax
    jnz     .out
    mov     rdi, r12
    mov     esi, r13d
    mov     rdx, rsp
    mov     rcx, r14
    call    ga_client_connect wrt ..plt
    jmp     .out
.einval:
    mov     eax, -EINVAL
.out:
    add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; grpcasm_client_method — register a method by its NUL-terminated path.
; @param  rdi  grpcasm_client*   @param rsi  const char *path
; @returns eax = the handle, or -EINVAL / -ENOMEM (ga_client_method).
; =============================================================================
grpcasm_client_method:
    push    rbx
    push    r12
    sub     rsp, 8                      ; 2 pushes + 8: aligned
    mov     rbx, rdi
    mov     r12, rsi
    test    rbx, rbx
    jz      .einval
    test    r12, r12
    jz      .einval
    mov     rdi, r12
    call    strlen wrt ..plt
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, rax
    call    ga_client_method wrt ..plt
    jmp     .out
.einval:
    mov     eax, -EINVAL
.out:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; =============================================================================
; grpcasm_client_output — the bytes waiting to be sent (bytes mode).
; @param  rdi  grpcasm_client*   @param rsi  const uint8_t **data (or NULL)
; @returns rax = their number; *data = where they are.
; =============================================================================
grpcasm_client_output:
    push    rbx                         ; 1 push: aligned
    mov     rbx, rsi
    call    ga_client_output wrt ..plt
    test    rbx, rbx
    jz      .out
    mov     [rbx], rax
.out:
    mov     rax, rdx
    pop     rbx
    ret

; =============================================================================
; The rest are the engine's functions as they are: same arguments, same
; results (grpcasm.h documents them). A tail jump keeps the caller's stack as
; it was, so grpcasm_client_unary's seventh argument is where
; ga_client_unary looks for it.
; =============================================================================
grpcasm_client_free:
    jmp     ga_client_free wrt ..plt
grpcasm_client_call:
    jmp     ga_client_call wrt ..plt
grpcasm_client_unary:
    jmp     ga_client_unary wrt ..plt
grpcasm_client_poll:
    jmp     ga_client_poll wrt ..plt
grpcasm_client_flush:
    jmp     ga_client_flush wrt ..plt
grpcasm_client_fd:
    jmp     ga_client_fd wrt ..plt
grpcasm_client_input:
    jmp     ga_client_input wrt ..plt
grpcasm_client_consume:
    jmp     ga_client_consume wrt ..plt

section .note.GNU-stack noalloc noexec nowrite progbits
