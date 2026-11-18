; =============================================================================
; main.asm — greeter_client: one helloworld.Greeter/SayHello call through
; GrpcAsm's client, from NASM (include/grpcasm_client.inc).
;
;   greeter_client [name]      prints "Hello <name>" (name default "world")
;
; Server: GREETER_HOST (default 127.0.0.1), GREETER_PORT (default 50051).
; GREETER_CALLS (default 1) repeats the call that many times on the one
; connection and prints the last reply: from the second call on, the request
; headers are indexed references into the server's HPACK table, which is what
; an interoperability test of the encoder needs.
; Exit status: 0 when every call returned OK, 1 otherwise; a failure prints
; the connect error or the call's status and message to stderr, and stops.
;
; The program defines no routes and no server hooks: it links against the
; engine's default empty route table (routes_default.asm), which the HPACK
; decoder needs and only servers fill.
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"
%include "grpcasm_client.inc"

extern getenv
extern atoi
extern strlen
extern ga_pb_field_bytes

global main

%define NAME_MAX            127         ; one-byte varint length in the request

section .rodata
s_host_env:     db "GREETER_HOST", 0
s_port_env:     db "GREETER_PORT", 0
s_calls_env:    db "GREETER_CALLS", 0
s_default_host: db "127.0.0.1", 0
s_default_port: db "50051", 0
s_world:        db "world", 0
s_path:         db "/helloworld.Greeter/SayHello"
s_path_len      equ $ - s_path
s_connect:      db "greeter_client: connect failed, errno "
s_connect_len   equ $ - s_connect
s_status:       db "greeter_client: status "
s_status_len    equ $ - s_status
s_call:         db "greeter_client: call refused, errno "
s_call_len      equ $ - s_call
s_sep:          db ": "
s_newline:      db 10

section .text

; =============================================================================
; main — connect, call, print, free.
; @param  edi  argc   @param rsi  argv
; @returns eax = 0 (OK) or 1.
; @remarks Frame: [0] the 7th argument of ga_client_unary (the timeout),
;          [8] GaClient*, [16] the callback's context: the exit status it
;          sets, then [24] whether it prints the reply (the last call only),
;          [32..32+2+NAME_MAX) the HelloRequest.
; =============================================================================
main:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 168                    ; 6 pushes + 168: aligned for calls
    lea     r12, [s_world]
    cmp     edi, 1
    jle     .named
    mov     r12, [rsi + 8]              ; argv[1]
.named:
    lea     rdi, [s_host_env]
    call    getenv wrt ..plt
    lea     r13, [s_default_host]
    test    rax, rax
    cmovnz  r13, rax
    lea     rdi, [s_port_env]
    call    getenv wrt ..plt
    lea     rdi, [s_default_port]
    test    rax, rax
    cmovnz  rdi, rax
    call    atoi wrt ..plt
    mov     r14d, eax                   ; port (ga_client_connect checks its range)
    mov     rdi, r13
    mov     esi, r14d
    xor     edx, edx                    ; every default; authority "host:port"
    lea     rcx, [rsp + 8]
    call    ga_client_connect wrt ..plt
    test    eax, eax
    jnz     .connect_failed
    mov     rdi, [rsp + 8]
    lea     rsi, [s_path]
    mov     edx, s_path_len
    call    ga_client_method wrt ..plt
    mov     r15d, eax                   ; the method's handle
    ; HelloRequest{name}: tag 0x0A, a one-byte length, the bytes.
    mov     rdi, r12
    call    strlen wrt ..plt
    mov     ecx, NAME_MAX
    cmp     rax, rcx
    cmova   rax, rcx
    mov     rbx, rax
    mov     byte [rsp + 32], 0x0A
    mov     [rsp + 33], bl
    lea     rdi, [rsp + 34]
    mov     rsi, r12
    mov     rcx, rbx
    rep     movsb
    ; GREETER_CALLS: how many calls (default, and at least, 1).
    lea     rdi, [s_calls_env]
    call    getenv wrt ..plt
    mov     ebp, 1
    test    rax, rax
    jz      .call
    mov     rdi, rax
    call    atoi wrt ..plt
    cmp     eax, 1
    jl      .call
    mov     ebp, eax
.call:
    mov     qword [rsp + 16], 1         ; failed until the callback says otherwise
    xor     eax, eax
    cmp     ebp, 1
    sete    al
    mov     [rsp + 24], rax             ; print the reply of the last call only
    mov     qword [rsp], 5000           ; timeout: the 7th argument, on the stack
    mov     rdi, [rsp + 8]
    mov     esi, r15d
    lea     rdx, [rsp + 32]
    lea     rcx, [rbx + 2]
    lea     r8, [on_reply]
    lea     r9, [rsp + 16]
    call    ga_client_unary wrt ..plt
    test    eax, eax
    js      .call_failed                ; refused: the callback never ran
    cmp     qword [rsp + 16], 0
    jne     .done                       ; a failed call stops the run (it printed why)
    dec     ebp
    jnz     .call
.done:
    mov     rdi, [rsp + 8]
    call    ga_client_free wrt ..plt
    mov     eax, [rsp + 16]
    jmp     .out
.call_failed:
    neg     eax
    mov     r12d, eax
    mov     edi, 2
    lea     rsi, [s_call]
    mov     edx, s_call_len
    call    write_out
    mov     edi, 2
    mov     esi, r12d
    call    write_decimal
    mov     edi, 2
    lea     rsi, [s_newline]
    mov     edx, 1
    call    write_out
    mov     qword [rsp + 16], 1
    jmp     .done
.connect_failed:
    neg     eax
    mov     ebx, eax
    mov     edi, 2
    lea     rsi, [s_connect]
    mov     edx, s_connect_len
    call    write_out
    mov     edi, 2
    mov     esi, ebx
    call    write_decimal
    mov     edi, 2
    lea     rsi, [s_newline]
    mov     edx, 1
    call    write_out
    mov     eax, 1
.out:
    add     rsp, 168
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; on_reply — the call's done callback (grpcasm_client.inc).
; @param  rdi  context: int64 exit status, then int64 "print the reply"
; @param  esi  gRPC status
; @param  rdx  message   @param rcx  its length
; @param  r8   HelloReply bytes   @param r9  their length
; @returns nothing. Sets the exit status: 0 for an OK reply (printed when
;          asked), 1 for a failure (always printed, to stderr).
; =============================================================================
on_reply:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                         ; 5 pushes: aligned for calls
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     r14, rcx
    test    r12d, r12d
    jnz     .failed
    ; HelloReply.message is field 1.
    mov     rdi, r8
    mov     rsi, r9
    mov     edx, 1
    call    ga_pb_field_bytes wrt ..plt
    test    rax, rax
    jnz     .malformed
    mov     qword [rbx], 0
    cmp     qword [rbx + 8], 0
    je      .out                        ; not the last call: nothing to print
    mov     edi, 1
    mov     rsi, rdx
    mov     rdx, rcx
    call    write_out
    mov     edi, 1
    lea     rsi, [s_newline]
    mov     edx, 1
    call    write_out
    mov     qword [rbx], 0
    jmp     .out
.malformed:
    mov     r12d, GC_INTERNAL           ; reported like a failed call
    xor     r14d, r14d
.failed:
    mov     edi, 2
    lea     rsi, [s_status]
    mov     edx, s_status_len
    call    write_out
    mov     edi, 2
    mov     esi, r12d
    call    write_decimal
    test    r14, r14
    jz      .newline
    mov     edi, 2
    lea     rsi, [s_sep]
    mov     edx, 2
    call    write_out
    mov     edi, 2
    mov     rsi, r13
    mov     rdx, r14
    call    write_out
.newline:
    mov     edi, 2
    lea     rsi, [s_newline]
    mov     edx, 1
    call    write_out
    mov     qword [rbx], 1
.out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; write_out — write(fd, bytes, length), retried on EINTR. Leaf.
; @param  edi  fd   @param rsi  bytes   @param rdx  length
; @returns nothing (a failed write of a message is not worth more).
; =============================================================================
write_out:
    mov     eax, SYS_write
    syscall
    cmp     rax, -EINTR
    je      write_out
    ret

; =============================================================================
; write_decimal — write an unsigned number in decimal. Leaf (no calls but
; write_out's syscall).
; @param  edi  fd   @param esi  the number
; @returns nothing.
; =============================================================================
write_decimal:
    sub     rsp, 24                     ; [0..16) the digits, written backwards
    mov     eax, esi
    lea     rsi, [rsp + 16]
    mov     ecx, 10
.digit:
    xor     edx, edx
    div     ecx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    eax, eax
    jnz     .digit
    lea     rdx, [rsp + 16]
    sub     rdx, rsi
    call    write_out
    add     rsp, 24
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
