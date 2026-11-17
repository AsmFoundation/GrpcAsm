; =============================================================================
; greeter.asm — helloworld.Greeter on the GrpcAsm engine: the service's route
; table, its one method and every hook the engine calls.
;
; SayHello(HelloRequest{string name = 1}) answers HelloReply{string message =
; 1} with "Hello " + name (grpc/examples/protos/helloworld.proto). The answer
; is framed with ga_h2n_reply_parts: a head of at most 17 bytes built on the
; stack (the gRPC prefix, the field's tag and length, "Hello ") and the name
; as the body, straight from the request. No allocation, and no copy of the
; name until h2n writes it into the DATA frame.
;
; The engine does everything else: HTTP/2, the 405/415/UNIMPLEMENTED/framing
; checks, the health service (this file only names "helloworld.Greeter" for
; it), drain and shutdown. The Greeter keeps no per-worker, per-connection or
; per-call state, so most hooks are empty. Each one is still defined: the
; engine calls every hook by a direct call that the linker binds (milestone C
; is where a hook an application does not need is assembled away instead).
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"
%include "server.inc"
%include "grpcasm_reply.inc"

%define R_SAY_HELLO         1           ; the route of /helloworld.Greeter/SayHello

extern ga_pb_field_bytes
extern ga_grpc_refuse
extern ga_h2n_reply_parts
extern ga_keyeq

section .rodata
; The route table (grpcasm_routes.inc): exact paths, first match wins.
global ga_app_routes:data
ga_app_routes:
    GA_ROUTE "/helloworld.Greeter/SayHello", R_SAY_HELLO
    GA_ROUTES_END

; The one named service the engine's health check reports SERVING for (the
; empty name, the whole server, needs no entry).
CSTR v_service,     "helloworld.Greeter"

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

global ga_app_unary:function
global ga_app_stream_data:function
global ga_app_stream_end:function
global ga_app_stream_fill:function
global ga_app_batch_end:function
global ga_app_call_release:function
global ga_app_health_service:function
global ga_app_worker_init:function
global ga_app_worker_fini:function
global ga_app_worker_resume:function
global ga_app_worker_pause:function
global ga_app_worker_tick:function

; =============================================================================
; ga_app_unary — SayHello: answer "Hello " + name.
; @param  rdi  Conn*   @param rsi  Stream* (route R_SAY_HELLO, the only one)
; @param  rdx  the HelloRequest message   @param rcx  its length
; @returns eax = 0, or -1 when the answer could not be queued (out of memory:
;          the engine ends the connection).
; @remarks An absent name is the empty string (proto3), so "Hello " is a valid
;          answer. A message that is not well-formed protobuf is
;          INVALID_ARGUMENT. The name may be as long as the engine's request
;          limit (Config.max_request), so its varint length takes up to 4
;          bytes; the head is at most 5 + 1 + 5 + 6 = 17 bytes, below the
;          name-length slot at [rsp + 24].
; =============================================================================
ga_app_unary:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32                     ; [0..24) the head, [24] the name's length;
                                        ; 3 pushes + 32: rsp 16-aligned for calls
    mov     r12, rdi                    ; Conn*
    mov     rbx, rsi                    ; Stream*
    mov     rdi, rdx
    mov     rsi, rcx
    mov     edx, 1                      ; HelloRequest.name
    call    ga_pb_field_bytes wrt ..plt ; rdx, rcx = the name (0, 0 when absent)
    test    rax, rax
    jnz     .malformed
    mov     r13, rdx                    ; the name
    mov     [rsp + 24], rcx             ; its length
    ; HelloReply: tag 0x0A (field 1, length-delimited), the varint length of
    ; "Hello " + name, then "Hello "; the name follows as the body.
    mov     byte [rsp + GRPC_PREFIX], 0x0A
    lea     rax, [rcx + 6]              ; the message field's length
    lea     rdi, [rsp + GRPC_PREFIX + 1]
.varint:
    cmp     rax, 0x80
    jb      .last
    mov     r8d, eax
    or      r8d, 0x80                   ; 7 bits and a continuation bit
    mov     [rdi], r8b
    inc     rdi
    shr     rax, 7
    jmp     .varint
.last:
    mov     [rdi], al
    inc     rdi
    mov     dword [rdi], 'Hell'
    mov     word [rdi + 4], 'o '
    add     rdi, 6
    mov     r8, rdi
    sub     r8, rsp                     ; the head's length
    ; The gRPC prefix: flag 0, then the big-endian length of the protobuf
    ; payload (the head after the prefix, plus the name).
    lea     rax, [r8 - GRPC_PREFIX]
    add     rax, [rsp + 24]
    bswap   eax
    mov     byte [rsp], 0
    mov     [rsp + 1], eax
    mov     rdi, r12
    mov     rsi, rbx
    mov     rdx, rsp                    ; head
    mov     rcx, r8                     ; head length
    mov     r8, r13                     ; body: the name
    mov     r9, [rsp + 24]
    call    ga_h2n_reply_parts wrt ..plt
    jmp     .out
.malformed:
    mov     rdi, r12
    mov     rsi, rbx
    lea     rdx, [nv_e_malformed]
    mov     ecx, 4
    call    ga_grpc_refuse wrt ..plt
.out:
    ; h2n's reply functions return 0 or -1; normalize so the hook's contract
    ; holds whatever negative value they pick.
    test    eax, eax
    jz      .done
    mov     eax, -1
.done:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; ga_app_health_service — whether this server serves a named service.
; @param  rdi  the service name   @param rsi  its length (> 0)
; @returns eax != 0 for "helloworld.Greeter", 0 otherwise (NOT_FOUND).
; =============================================================================
ga_app_health_service:
    cmp     rsi, v_service_len
    jne     .unknown
    lea     rsi, [v_service]
    mov     edx, v_service_len
    jmp     ga_keyeq wrt ..plt          ; (name, "helloworld.Greeter", length)
.unknown:
    xor     eax, eax
    ret

; =============================================================================
; ga_app_stream_data, ga_app_stream_end — never called: the Greeter has no
; client-streaming route.
; @param  rdi  Conn*   @param rsi  Stream*   (stream_data: rdx data, rcx length)
; @returns eax = -1: if the engine ever routed a stream here, ending the
;          connection is the safe answer to a call this service cannot have.
; =============================================================================
ga_app_stream_data:
ga_app_stream_end:
    mov     eax, -1
    ret

; =============================================================================
; ga_app_stream_fill — never called: the Greeter never generates a body
; (ST_GEN).
; @param  rdi  Stream*   @param rsi  destination   @param rdx  bytes
; @returns does not return.
; @remarks The contract says "exactly n bytes must be written"; a call here
;          would be an engine bug, and ud2 makes it loud instead of sending
;          garbage.
; =============================================================================
ga_app_stream_fill:
    ud2

; =============================================================================
; ga_app_batch_end — nothing is ever deferred here.
; @param  rdi  Conn*
; @returns eax = 0.
; =============================================================================
ga_app_batch_end:
    xor     eax, eax
    ret

; =============================================================================
; ga_app_worker_init — no per-worker state.
; @param  rdi  Worker*
; @returns rax = 0.
; =============================================================================
ga_app_worker_init:
    xor     eax, eax
    ret

; =============================================================================
; ga_app_call_release, ga_app_worker_fini, _resume, _pause, _tick — nothing
; to release, nothing to do around a sleep, nothing periodic.
; @param  rdi  Conn* (call_release, with rsi = Stream*) or Worker*
; @returns nothing.
; =============================================================================
ga_app_call_release:
ga_app_worker_fini:
ga_app_worker_resume:
ga_app_worker_pause:
ga_app_worker_tick:
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
