; =============================================================================
; greeter.asm — helloworld.Greeter on GrpcAsm's NASM API (include/grpcasm.inc).
;
; SayHello(HelloRequest{string name = 1}) answers HelloReply{string message =
; 1} with "Hello " + name (grpc/examples/protos/helloworld.proto).
;
; The four lines of GA_SERVICE ... GA_APP_END are the whole service
; declaration. They generate:
;   * the route table;
;   * the dispatch: with one method, ga_app_unary IS say_hello, an alias, so
;     the engine's call reaches it with no instruction in between;
;   * the health check, SERVING "helloworld.Greeter";
;   * the no-op hooks the engine expects (the Greeter keeps no per-worker,
;     per-connection or per-call state).
; Until milestone C3 this file wrote all of them by hand.
;
; The reply is written in place (GA_REPLY_BEGIN / GA_REPLY_END): the tag,
; the length, "Hello " and the name go straight into the connection's
; output buffer, inside the frames the engine reserved around them. There is
; no allocation, no head built on the stack, and no copy beyond the name's
; one move from the request.
;
; The engine does everything else: HTTP/2, the 405/415/UNIMPLEMENTED/framing
; checks, drain and shutdown.
; =============================================================================

default rel
bits 64

%include "grpcasm.inc"

extern memcpy

GA_SERVICE "helloworld.Greeter"
    GA_UNARY "SayHello", say_hello
GA_SERVICE_END
GA_APP_END

section .rodata
; INVALID_ARGUMENT for a request that is not a well-formed HelloRequest.
CSTR s_status,      ":status"
CSTR s_200,         "200"
CSTR s_ctype,       "content-type"
CSTR s_ctype_grpc,  "application/grpc"
CSTR s_gstatus,     "grpc-status"
CSTR s_gmessage,    "grpc-message"
CSTR s_c3,          "3"
CSTR s_m_malformed, "malformed request message"

section .data.rel.ro progbits alloc noexec write align=8
TRAILERS_ONLY nv_e_malformed, s_c3, s_m_malformed

section .text

; =============================================================================
; say_hello — SayHello: answer "Hello " + name (ga_app_unary for its route).
; @param  rdi  Conn*   @param rsi  Stream*
; @param  rdx  the HelloRequest message   @param rcx  its length
; @returns eax = 0, or -1 when the answer could not be queued (out of memory:
;          the engine ends the connection).
; @remarks An absent name is the empty string (proto3), so "Hello " is a
;          valid answer. A message that is not well-formed protobuf is
;          INVALID_ARGUMENT. The name may be as long as the engine's request
;          limit (Config.max_request), so its varint length takes up to 4
;          bytes: the reply is at most 1 + 5 + 6 + the name's length.
; =============================================================================
say_hello:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8                      ; [0] the message's start; 4 pushes + 8: aligned
    mov     r12, rdi                    ; Conn*
    mov     rbx, rsi                    ; Stream*
    mov     rdi, rdx
    mov     rsi, rcx
    mov     edx, 1                      ; HelloRequest.name
    call    ga_pb_field_bytes wrt ..plt ; rdx, rcx = the name (0, 0 when absent)
    test    rax, rax
    jnz     .malformed
    mov     r13, rdx                    ; the name
    mov     r14, rcx                    ; its length
    lea     rdx, [r14 + 1 + 5 + 6]      ; the most the reply can take
    GA_REPLY_BEGIN r12, rbx, rdx
    test    rax, rax
    jz      .nomem
    mov     [rsp], rax
    ; HelloReply: tag 0x0A (field 1, length-delimited), the varint length of
    ; "Hello " + name, then the bytes.
    mov     byte [rax], 0x0A
    lea     rcx, [r14 + 6]              ; the message field's length
    lea     rdi, [rax + 1]
.varint:
    cmp     rcx, 0x80
    jb      .last
    mov     r8d, ecx
    or      r8d, 0x80                   ; 7 bits and a continuation bit
    mov     [rdi], r8b
    inc     rdi
    shr     rcx, 7
    jmp     .varint
.last:
    mov     [rdi], cl
    inc     rdi
    mov     dword [rdi], 'Hell'
    mov     word [rdi + 4], 'o '
    add     rdi, 6
    mov     rsi, r13
    mov     rdx, r14
    call    memcpy wrt ..plt            ; rax = where the name starts (memcpy's dst)
    add     rax, r14
    sub     rax, [rsp]                  ; the message's length
    GA_REPLY_END r12, rbx, rax
    jmp     .out
.malformed:
    mov     rdi, r12
    mov     rsi, rbx
    lea     rdx, [nv_e_malformed]
    mov     ecx, 4
    call    ga_grpc_refuse wrt ..plt
    jmp     .out
.nomem:
    mov     eax, -1
.out:
    ; The reply functions return 0 or -1; normalize so the hook's contract
    ; holds whatever negative value they pick.
    test    eax, eax
    jz      .done
    mov     eax, -1
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
