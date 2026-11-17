; =============================================================================
; grpc.asm — the engine's gRPC call layer: what every gRPC server does with a
; call between HTTP/2 (h2n.asm) and the application's methods.
;
;   ga_grpc_stream_append   buffer a request body within the per-stream
;                           (Config.max_request) and per-connection
;                           (Config.conn_budget) budgets
;   ga_grpc_stream_data     a client-streaming payload: the HTTP-level checks,
;                           then the application's ga_app_stream_data
;   ga_grpc_dispatch        END_STREAM: method and content-type (405, 415),
;                           routing (UNIMPLEMENTED), size (RESOURCE_EXHAUSTED),
;                           the 5-byte message framing and the compression
;                           rules, the built-in health service, then the
;                           application's ga_app_unary with the message
;   ga_grpc_stream_release  unlink and free one Stream (h2n closes every
;                           stream through it)
;   ga_grpc_free_streams    free every Stream of a connection (teardown)
;   ga_grpc_refuse          answer a call with a Trailers-Only gRPC error
;   ga_grpc_write_prefix    write a gRPC message prefix
;   ga_pb_field_bytes       find a length-delimited field of a protobuf
;                           message (the health check's decoder, for
;                           applications too)
;
; Moved here from KvAsm's grpc.asm (60d7e81) in milestone B step 4
; (docs/ROADMAP.md). Every status, every message text and the order of the
; checks are KvAsm's, which is what keeps KvAsm's end-to-end suite a valid
; gate; only the 405/415 body texts no longer name KvAsm.
;
; The application's per-call state lives in Stream.app (GA_STREAM_APP_SIZE
; bytes, zeroed when the stream opens, never read here). When the
; application attaches something that must be released — memory, a pin — it
; sets ST_APP_STATE, and stream_free calls its ga_app_call_release first;
; every other stream is freed with one call.
;
; Threading: everything here runs on the worker thread that owns the
; connection, between the application's resume and pause hooks.
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"
%include "server.inc"
%include "grpcasm_hooks.inc"            ; the application's ga_app_* hooks
%include "grpcasm_reply.inc"

; First request-buffer size: 240 + the pool's 16-byte header fills a 256-byte
; block exactly (a KvServer GetRequest is 23 bytes; a Put of a 100-byte value
; about 130).
%define MIN_REQ_CAP             240

; HealthCheckResponse.ServingStatus (grpc/health/v1/health.proto)
%define HEALTH_SERVING          1
%define HEALTH_NOT_SERVING      2

extern memcpy
extern ga_pool_free
extern ga_pool_realloc
extern ga_h2n_reply_parts
extern ga_h2n_reply_static
extern ga_h2n_reply_headers

; ---- static replies -----------------------------------------------------------
section .rodata
CSTR s_status,      ":status"
CSTR s_200,         "200"
CSTR s_405,         "405"
CSTR s_415,         "415"
CSTR s_ctype,       "content-type"
CSTR s_ctype_grpc,  "application/grpc"
CSTR s_ctype_text,  "text/plain; charset=utf-8"
CSTR s_allow,       "allow"
CSTR s_accept,      "accept"
; Plain HTTP error bodies. Beyond helping a human with curl, a body keeps the
; stream open while flow control holds its DATA — HTTP/2 conformance suites
; (h2spec) rely on that to exercise stream limits and window handling.
CSTR b_405,         "405 method not allowed: this is a gRPC server, send POST", 10
CSTR b_415,         "415 unsupported media type: send content-type application/grpc", 10
CSTR s_gstatus,     "grpc-status"
CSTR s_gmessage,    "grpc-message"
CSTR s_c3,          "3"
CSTR s_c5,          "5"
CSTR s_c8,          "8"
CSTR s_c12,         "12"
CSTR s_c13,         "13"
CSTR s_m_method,    "unknown method"
CSTR s_m_compress,  "compressed messages are not supported"
CSTR s_m_badflag,   "compressed flag set without a grpc-encoding"
CSTR s_accept_enc,  "grpc-accept-encoding"
CSTR s_m_framing,   "expected exactly one uncompressed request message"
CSTR s_m_malformed, "malformed request message"
CSTR s_m_toolarge,  "request message too large"
CSTR s_m_noservice, "unknown service"
CSTR v_post,        "POST"
CSTR v_identity,    "identity"

section .data.rel.ro progbits alloc noexec write align=8
; RFC 9110 §15.5.6: a 405 MUST carry Allow. §15.5.16: a 415 can name the
; accepted media type in Accept. Both carry a text body (static, ST_STATIC_RESP).
nv_405:             NV s_status, s_405
                    NV s_allow, v_post
                    NV s_ctype, s_ctype_text
nv_415:             NV s_status, s_415
                    NV s_accept, s_ctype_grpc
                    NV s_ctype, s_ctype_text
TRAILERS_ONLY nv_e_method,    s_c12, s_m_method
; Unsupported codec: gRPC requires UNIMPLEMENTED *and* a grpc-accept-encoding
; header so the client can retry with a codec we accept. The fifth entry
; directly follows the macro's four, so the array is contiguous (count 5).
TRAILERS_ONLY nv_e_compress,  s_c12, s_m_compress
                    NV s_accept_enc, v_identity
; Compressed flag without a declared codec is a sender bug, not a missing
; feature: INTERNAL, as grpc-go and grpc-core answer it.
TRAILERS_ONLY nv_e_badflag,   s_c13, s_m_badflag
TRAILERS_ONLY nv_e_framing,   s_c13, s_m_framing
TRAILERS_ONLY nv_e_malformed, s_c3,  s_m_malformed
TRAILERS_ONLY nv_e_toolarge,  s_c8,  s_m_toolarge
TRAILERS_ONLY nv_e_noservice, s_c5,  s_m_noservice

section .text

global ga_grpc_dispatch:function
global ga_grpc_stream_append:function
global ga_grpc_stream_data:function
global ga_grpc_stream_release:function
global ga_grpc_free_streams:function
global ga_grpc_refuse:function
global ga_grpc_write_prefix:function
global ga_pb_field_bytes:function

; =============================================================================
; ga_grpc_dispatch — a request is complete: validate it, then route it.
;
; @param  rdi  Conn*   @param rsi  Stream* (END_STREAM received; its header
;              fields resolved into Stream.method and Stream.flags by h2n)
; @returns eax = 0, or -1 when an answer could not be queued (out of memory
;          in h2n's output buffer: h2n ends the connection).
; @remarks The order of the checks follows the gRPC HTTP/2 spec, and KvAsm's
;          suite pins it: method and content-type are HTTP-level (405, 415),
;          then routing (UNIMPLEMENTED), then the body's size
;          (RESOURCE_EXHAUSTED: ga_grpc_stream_append marked it TOO_LARGE),
;          then the 5-byte message framing, then the message itself, which is
;          the application's (ga_app_unary) or the health service's.
;          Compressed-flag handling matches grpc-go and grpc-core: flag 1
;          with a declared codec (grpc-encoding other than identity) is
;          UNIMPLEMENTED plus grpc-accept-encoding: identity; flag 1 with no
;          codec, or identity, is INTERNAL (the sender contradicts itself);
;          flag 0 is accepted whatever grpc-encoding says, because it means
;          "not compressed".
;          A client-streaming route (GA_ROUTE_CLIENT_STREAM; KvServer: Upload)
;          consumed its body as it arrived, so its end goes to
;          ga_app_stream_end with no framing
;          check. A call answered early (ST_RESPONDED: a streaming request
;          refused while its body was still arriving) is left alone and not
;          counted again.
;          Frameless: every path ends in a tail call (the application, the
;          health check, or a reply), which keeps the stack the application
;          runs on one return address deep. The stream may be answered and
;          freed before this returns, so the caller must not touch it.
; =============================================================================
ga_grpc_dispatch:
    mov     rax, [rsi + Stream.flags]
    test    eax, ST_RESPONDED
    jnz     .answered                   ; refused early: nothing to add
    mov     rcx, [rdi + Conn.worker]
    inc     qword [rcx + Worker.st_requests]
    or      rax, ST_RESPONDED
    mov     [rsi + Stream.flags], rax
    test    eax, ST_POST
    jz      .http_405
    test    eax, ST_CT_OK
    jz      .http_415
    mov     rcx, [rsi + Stream.method]
    cmp     rcx, GA_ROUTE_UNKNOWN
    je      .e_method                   ; no route matched the :path
    test    cl, GA_ROUTE_CLIENT_STREAM
    jnz     .stream_end                 ; body already consumed: no framing to check
    test    eax, ST_TOO_LARGE
    jnz     .e_toolarge

    ; gRPC framing: exactly one message, uncompressed.
    mov     r8, [rsi + Stream.req_len]
    cmp     r8, GRPC_PREFIX
    jb      .e_framing
    mov     rdx, [rsi + Stream.req_buf]
    movzx   r9d, byte [rdx]
    cmp     r9d, 1
    je      .compressed
    ja      .e_framing                  ; flag values other than 0/1 are undefined
    mov     r9d, [rdx + 1]
    bswap   r9d                         ; big-endian length (the write zero-extends)
    lea     r10, [r9 + GRPC_PREFIX]
    cmp     r10, r8
    jne     .e_framing
    add     rdx, GRPC_PREFIX            ; the message
    mov     rcx, r9                     ; its length
    cmp     qword [rsi + Stream.method], GA_ROUTE_HEALTH
    je      health_check                ; tail jump (Conn*, Stream*, message, length)
    jmp     ga_app_unary wrt ..plt      ; tail call (Conn*, Stream*, message, length)

.stream_end:
    jmp     ga_app_stream_end wrt ..plt ; tail call (Conn*, Stream*)
.answered:
    xor     eax, eax
    ret
.http_405:
    lea     rdx, [nv_405]
    lea     rcx, [b_405]
    mov     r8d, b_405_len
    jmp     reply_http_error            ; tail jump
.http_415:
    lea     rdx, [nv_415]
    lea     rcx, [b_415]
    mov     r8d, b_415_len
    jmp     reply_http_error            ; tail jump
.e_method:
    lea     rdx, [nv_e_method]
    jmp     .refuse4
.e_toolarge:
    lea     rdx, [nv_e_toolarge]
    jmp     .refuse4
.e_framing:
    lea     rdx, [nv_e_framing]
    jmp     .refuse4
.compressed:
    ; ST_ENCODED was set by h2n for a grpc-encoding other than identity
    ; (eax still holds the flags).
    test    eax, ST_ENCODED
    jz      .e_badflag
    lea     rdx, [nv_e_compress]
    mov     ecx, 5                      ; + grpc-accept-encoding
    jmp     ga_grpc_refuse              ; tail call
.e_badflag:
    lea     rdx, [nv_e_badflag]
.refuse4:
    mov     ecx, 4                      ; :status, content-type, grpc-status, grpc-message
    jmp     ga_grpc_refuse              ; tail call (Conn*, Stream*, fields, count)

; =============================================================================
; ga_grpc_stream_data — the next DATA payload of a client-streaming call.
;
; @param  rdi  Conn*   @param rsi  Stream* (a client-streaming route)
; @param  rdx  data    @param rcx  length (> 0)
; @returns eax = 0 (consumed, or dropped after an answer), 1 (answered early:
;          the stream may already be closed and freed, so the caller must not
;          touch it), or -1 (out of memory: the connection ends).
; @remarks h2n calls this for every non-empty payload of such a call, as it
;          arrives (after flow-control accounting). Dispatch's HTTP-level
;          checks run before the application sees anything, so a non-gRPC
;          upload is refused (405/415, counted as a request) before its body
;          travels; ST_RESPONDED then makes the rest of the body be dropped
;          here, and h2n resets the stream once the answer is out
;          (RST_STREAM(NO_ERROR), RFC 9113 §8.1). The checks are three flag
;          tests per payload; the payload itself goes to ga_app_stream_data
;          by tail call.
; =============================================================================
ga_grpc_stream_data:
    mov     rax, [rsi + Stream.flags]
    test    eax, ST_RESPONDED
    jnz     .drop                       ; answered already: nobody reads the rest
    test    eax, ST_POST
    jz      .http_405
    test    eax, ST_CT_OK
    jz      .http_415
    jmp     ga_app_stream_data wrt ..plt ; tail call, same arguments
.drop:
    xor     eax, eax
    ret
.http_405:
    lea     rdx, [nv_405]
    lea     rcx, [b_405]
    mov     r8d, b_405_len
    jmp     .http_error
.http_415:
    lea     rdx, [nv_415]
    lea     rcx, [b_415]
    mov     r8d, b_415_len
.http_error:
    ; Answered here, so ga_grpc_dispatch will not count the call at
    ; END_STREAM (ST_RESPONDED): count it now. The body may wait for window,
    ; so the stream can outlive this call.
    mov     r9, [rdi + Conn.worker]
    inc     qword [r9 + Worker.st_requests]
    or      qword [rsi + Stream.flags], ST_RESPONDED
    sub     rsp, 8                      ; entry rsp = 16n + 8: aligned for the call
    call    reply_http_error
    add     rsp, 8
    test    eax, eax
    jnz     .fatal
    mov     eax, 1                      ; answered: possibly closed and freed already
    ret
.fatal:
    mov     eax, -1
    ret

; =============================================================================
; reply_http_error — answer with a plain HTTP error: 3 header fields and a
; static text body. Internal.
; @param  rdi  Conn*   @param rsi  Stream*   @param rdx  HdrField[3]
; @param  rcx  body (.rodata)   @param r8  body length
; @returns eax = 0, or -1 when out of memory (the caller ends the connection).
; @remarks ST_STATIC_RESP makes h2n end the stream on the body's last DATA
;          frame (no gRPC trailers) and makes stream_free leave the .rodata
;          body alone. A tail call into h2n.
; =============================================================================
reply_http_error:
    or      qword [rsi + Stream.flags], ST_STATIC_RESP
    mov     [rsi + Stream.resp_buf], rcx
    mov     [rsi + Stream.resp_len], r8
    mov     qword [rsi + Stream.resp_off], 0
    mov     ecx, 3                      ; rdx = the 405 or 415 fields
    jmp     ga_h2n_reply_static wrt ..plt

; =============================================================================
; ga_grpc_refuse — answer a call with a Trailers-Only gRPC error.
; @param  rdi  Conn*   @param rsi  Stream*
; @param  rdx  HdrField array (TRAILERS_ONLY, grpcasm_reply.inc)
; @param  ecx  field count (4, or more when the table extends the four)
; @returns eax = 0, or -1 when out of memory (the caller ends the connection).
; @remarks One HEADERS frame with END_STREAM. The stream is closed and freed
;          by the answer, so the caller must not touch it afterwards; a
;          request whose body is still arriving also gets
;          RST_STREAM(NO_ERROR) from h2n, which stops the rest of its body.
;          Counts the error (Worker.st_errors).
; =============================================================================
ga_grpc_refuse:
    mov     rax, [rdi + Conn.worker]
    inc     qword [rax + Worker.st_errors]
    jmp     ga_h2n_reply_headers wrt ..plt ; tail call, same arguments

; =============================================================================
; ga_grpc_write_prefix — the 5-byte gRPC message prefix: flag 0 (not
; compressed) and the big-endian 32-bit length. Leaf.
; @param  rdi  destination (5 bytes writable)
; @param  rsi  the message's length, without the prefix (< 2^32)
; @returns nothing. Clobbers eax.
; =============================================================================
ga_grpc_write_prefix:
    mov     byte [rdi], 0
    mov     eax, esi
    bswap   eax
    mov     [rdi + 1], eax
    ret

; =============================================================================
; health_check — grpc.health.v1.Health/Check, built into every server.
; Internal (tail-jumped from ga_grpc_dispatch).
; @param  rdi  Conn*   @param rsi  Stream* (route GA_ROUTE_HEALTH)
; @param  rdx  the HealthCheckRequest message   @param rcx  its length
; @returns eax = 0, or -1 when out of memory (the caller ends the connection).
; @remarks HealthCheckRequest{string service = 1}. An empty or absent service
;          means the whole server; any other name must be one the
;          application serves (ga_app_health_service), else the answer is
;          NOT_FOUND, as the health protocol specifies. The status is SERVING,
;          or NOT_SERVING once this worker is draining, so probes and load
;          balancers stop routing here before the connection closes.
;          The 7-byte answer (prefix + 08 status) is built on the stack and
;          framed by ga_h2n_reply_parts, which copies it: no response
;          buffer, so no allocation now and no free when the stream closes.
;          A malformed request is INVALID_ARGUMENT, by the same rules as
;          KvServer's decoder (ga_pb_field_bytes).
; =============================================================================
health_check:
    push    rbx
    push    r12
    sub     rsp, 24                     ; [0..8) the answer; 2 pushes + 24: aligned
    mov     r12, rdi                    ; Conn*
    mov     rbx, rsi                    ; Stream*
    mov     rdi, rdx
    mov     rsi, rcx
    mov     edx, 1                      ; HealthCheckRequest.service
    call    ga_pb_field_bytes           ; rdx, rcx = the service name
    test    rax, rax
    jnz     .malformed
    test    rcx, rcx
    jz      .status                     ; "" or absent: the whole server
    mov     rdi, rdx
    mov     rsi, rcx
    call    ga_app_health_service wrt ..plt
    test    eax, eax
    jz      .no_service
.status:
    mov     rax, [r12 + Conn.worker]
    mov     ecx, HEALTH_SERVING
    cmp     qword [rax + Worker.draining], 0
    je      .reply
    mov     ecx, HEALTH_NOT_SERVING
.reply:
    ; prefix: flag 0, length 2 (00 00 00 02 big-endian); then field 1
    ; (wire type varint: 08) with the status, which is below 128.
    mov     byte [rsp], 0
    mov     dword [rsp + 1], 0x02000000
    shl     ecx, 8
    or      ecx, 0x08
    mov     [rsp + GRPC_PREFIX], cx
    mov     rdi, r12
    mov     rsi, rbx
    mov     rdx, rsp
    mov     ecx, GRPC_PREFIX + 2        ; the whole message is the head
    xor     r8d, r8d                    ; no body
    xor     r9d, r9d
    call    ga_h2n_reply_parts wrt ..plt
    jmp     .out
.malformed:
    lea     rdx, [nv_e_malformed]
    jmp     .refuse
.no_service:
    lea     rdx, [nv_e_noservice]
.refuse:
    mov     rdi, r12
    mov     rsi, rbx
    mov     ecx, 4
    call    ga_grpc_refuse
.out:
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

; =============================================================================
; ga_pb_field_bytes — the last occurrence of a length-delimited field (bytes,
; string, an embedded message) of a protobuf message, once the whole message
; has been checked.
; @param  rdi  the message (may be anything when the length is 0)
; @param  rsi  its length
; @param  edx  the field number (1 .. 2^29 - 1)
; @returns rax = 0 with rdx = the field's bytes and rcx = their length (both 0
;          when the field is absent), or rax = -EINVAL for a malformed
;          message. Clobbers rsi, rdi, r8-r11; preserves rbx.
; @remarks The rules of KvServer's kv_pb_decode_kv field loop, so the health
;          check accepts and refuses exactly what KvAsm's did: unknown fields
;          of wire types 0, 1, 2 and 5 are skipped; groups (3, 4), the
;          undefined types (6, 7), field number 0, tags above 2^32 - 1, and
;          any varint or length that runs past the end are malformed; the
;          field with another wire type counts as an unknown field; a repeated
;          field replaces the earlier one (protobuf's last-wins). Every length
;          is checked against the bytes left before a pointer is formed from
;          it. Zero-copy: the result points into the message. One pass, no
;          allocation; no stack alignment needed (it calls only a leaf).
; =============================================================================
ga_pb_field_bytes:
    push    rbx
    mov     ebx, edx                    ; the wanted field, kept across pb_read_varint
    lea     rdx, [rdi + rsi]            ; end
    mov     rsi, rdi                    ; cursor
    xor     r10d, r10d                  ; the field's bytes (0 = absent)
    xor     edi, edi                    ; the field's length
.field:
    cmp     rsi, rdx
    jae     .ok                         ; clean end of message
    call    pb_read_varint              ; tag
    jc      .bad
    mov     r11, rax
    shr     r11, 3                      ; field number
    jz      .bad                        ; field 0 is invalid
    mov     rcx, 0xFFFFFFFF
    cmp     rax, rcx
    ja      .bad                        ; field numbers are < 2^29
    and     eax, 7                      ; wire type
    cmp     eax, 2
    je      .length_delimited
    test    eax, eax
    je      .skip_varint
    cmp     eax, 1
    je      .skip_fixed64
    cmp     eax, 5
    je      .skip_fixed32
    jmp     .bad                        ; 3/4 (groups), 6/7 (undefined)
.skip_varint:
    call    pb_read_varint
    jc      .bad
    jmp     .field
.skip_fixed64:
    mov     rcx, rdx
    sub     rcx, rsi
    cmp     rcx, 8
    jb      .bad
    add     rsi, 8
    jmp     .field
.skip_fixed32:
    mov     rcx, rdx
    sub     rcx, rsi
    cmp     rcx, 4
    jb      .bad
    add     rsi, 4
    jmp     .field
.length_delimited:
    call    pb_read_varint              ; payload length
    jc      .bad
    mov     rcx, rdx
    sub     rcx, rsi                    ; bytes remaining
    cmp     rax, rcx
    ja      .bad                        ; checked before rsi + rax is ever formed
    cmp     r11, rbx
    jne     .skip_bytes
    mov     r10, rsi                    ; the wanted field: remember it (last wins)
    mov     rdi, rax
.skip_bytes:
    add     rsi, rax
    jmp     .field
.ok:
    mov     rdx, r10
    mov     rcx, rdi
    xor     eax, eax
    pop     rbx
    ret
.bad:
    mov     rax, -EINVAL
    pop     rbx
    ret

; =============================================================================
; pb_read_varint — read one base-128 varint. Internal, leaf.
; @param  rsi  cursor (advanced past the varint on success)
; @param  rdx  end of the message
; @returns rax = value, CF = 0 on success; CF = 1 if the varint is truncated,
;          longer than 10 bytes, or does not fit in 64 bits.
; @remarks Clobbers rax, rcx, r8, r9 only (ga_pb_field_bytes keeps its state
;          in rbx, rdi, r10 and r11). The same code as KvServer's proto.asm.
; =============================================================================
pb_read_varint:
    xor     eax, eax
    xor     ecx, ecx                    ; shift
.byte:
    cmp     rsi, rdx
    jae     .err                        ; truncated
    movzx   r8d, byte [rsi]
    inc     rsi
    mov     r9d, r8d
    and     r9d, 0x7F
    cmp     ecx, 63
    jne     .fits
    cmp     r9d, 1                      ; the 10th byte may only carry bit 63
    ja      .err
.fits:
    shl     r9, cl
    or      rax, r9
    test    r8b, 0x80
    jz      .done
    add     ecx, 7
    cmp     ecx, 63
    ja      .err                        ; an 11th byte would be needed
    jmp     .byte
.done:
    clc
    ret
.err:
    stc
    ret

; =============================================================================
; ga_grpc_stream_append — buffer request body bytes of a stream.
;
; @param  rdi  Conn*   @param rsi  Stream*   @param rdx  data   @param rcx  len
; @returns eax = 0 (appended, or dropped because the stream is TOO_LARGE),
;          or 1 (the connection's buffering budget would be exceeded: the
;          stream is now TOO_LARGE and the caller must reset it with
;          ENHANCE_YOUR_CALM).
; @remarks Two budgets bound memory: a stream whose body exceeds max_request
;          is marked TOO_LARGE (answered RESOURCE_EXHAUSTED at END_STREAM, its
;          bytes dropped); a connection whose buffered bytes would exceed
;          conn_budget gets that stream reset. Buffers grow geometrically,
;          capped at max_request; out of memory is treated as oversize.
;          h2n.asm calls this for every DATA payload it does not borrow
;          (a body that arrives whole in one frame is dispatched in place).
; =============================================================================
ga_grpc_stream_append:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; [0] result; 6 pushes + 8: aligned for calls
    mov     qword [rsp], 0
    mov     r14, rdi                    ; Conn*
    mov     rbx, rsi                    ; Stream*
    mov     r12, rdx                    ; data
    mov     r13, rcx                    ; len
    test    qword [rbx + Stream.flags], ST_TOO_LARGE
    jnz     .out
    mov     rbp, [rbx + Stream.req_len]
    add     rbp, r13                    ; new length
    mov     rcx, [r14 + Conn.worker]
    mov     rcx, [rcx + Worker.cfg]
    mov     rax, [rcx + Config.max_request]
    add     rax, GRPC_PREFIX
    cmp     rbp, rax
    ja      .too_large
    cmp     rbp, [rbx + Stream.req_cap]
    jbe     .append
    ; grow: max(new_len, 2*cap, MIN_REQ_CAP), capped at max_request + prefix
    mov     rdx, [rbx + Stream.req_cap]
    shl     rdx, 1
    cmp     rdx, rbp
    cmovb   rdx, rbp
    mov     r8d, MIN_REQ_CAP
    cmp     rdx, r8
    cmovb   rdx, r8
    cmp     rdx, rax
    cmova   rdx, rax
    mov     r8, rdx
    sub     r8, [rbx + Stream.req_cap]  ; growth
    mov     r9, [r14 + Conn.buffered]
    add     r9, r8
    cmp     r9, [rcx + Config.conn_budget]
    ja      .over_budget
    push    rdx
    push    r8
    mov     rdi, [rbx + Stream.req_buf]
    mov     rsi, rdx
    mov     rax, [r14 + Conn.worker]
    lea     rdx, [rax + Worker.pool]
    call    ga_pool_realloc wrt ..plt
    pop     r8
    pop     rdx
    test    rax, rax
    jz      .too_large                  ; out of memory: treat like oversize
    mov     [rbx + Stream.req_buf], rax
    mov     [rbx + Stream.req_cap], rdx
    add     [r14 + Conn.buffered], r8
.append:
    mov     rdi, [rbx + Stream.req_buf]
    add     rdi, [rbx + Stream.req_len]
    mov     rsi, r12
    mov     rdx, r13
    call    memcpy wrt ..plt
    mov     [rbx + Stream.req_len], rbp
    jmp     .out
.over_budget:
    mov     qword [rsp], 1              ; the caller resets the stream
.too_large:
    or      qword [rbx + Stream.flags], ST_TOO_LARGE
    mov     rax, [rbx + Stream.req_cap]
    sub     [r14 + Conn.buffered], rax
    mov     rdi, [rbx + Stream.req_buf]
    mov     rax, [r14 + Conn.worker]
    lea     rsi, [rax + Worker.pool]
    call    ga_pool_free wrt ..plt
    xor     eax, eax
    mov     [rbx + Stream.req_buf], rax
    mov     [rbx + Stream.req_len], rax
    mov     [rbx + Stream.req_cap], rax
.out:
    mov     eax, [rsp]
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; ga_grpc_free_streams — free every Stream still attached to a connection.
; @param  rdi  Conn*
; @returns nothing.
; @remarks Called by the worker at connection teardown (linger and destroy),
;          after ga_h2n_close: the HTTP/2 layer releases its own state (stream
;          map, pend list, HPACK ring) but never the Streams, which live on
;          Conn.streams and would otherwise leak. Idempotent: the list, the
;          buffered count and the deferred batch are cleared, so a lingering
;          connection that comes through conn_destroy later frees nothing
;          twice.
; =============================================================================
ga_grpc_free_streams:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    mov     rbx, [r12 + Conn.streams]
.next:
    test    rbx, rbx
    jz      .done
    mov     rdi, rbx
    mov     rbx, [rbx + Stream.next]
    call    stream_free
    jmp     .next
.done:
    xor     eax, eax
    mov     [r12 + Conn.streams], rax
    mov     [r12 + Conn.buffered], rax
    mov     [r12 + Conn.batch_head], rax  ; a batch of freed streams must not survive
    mov     [r12 + Conn.batch_tail], rax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; =============================================================================
; stream_free — release a Stream and its buffers to the worker's pool.
; Internal.
; @param  rdi  Stream* (its conn and conn's worker must still be alive)
; @returns nothing.
; @remarks Buffers the Stream does not own are left alone: a borrowed request
;          body (ST_BORROWED, h2n's zero-copy path) and a static response
;          body (ST_STATIC_RESP, .rodata). Absent buffers are skipped here
;          rather than handed to ga_pool_free (which would ignore NULL):
;          on the fast paths — a unary call whose body arrived in one frame,
;          answered straight into the output buffer — neither buffer exists,
;          so this is two calls saved on every request.
;          The application's per-call state is released first, through
;          ga_app_call_release, when it set ST_APP_STATE: every way a stream
;          ends — its response completed, a reset from either side, the
;          connection's teardown, drain or idle timeout — comes through here,
;          which is what lets an application promise that an interrupted
;          upload stores nothing and a download never leaks its pin.
; =============================================================================
stream_free:
    ; The common case first: a unary call answered straight into the output
    ; buffer owns nothing but the Stream itself — no application state, no
    ; response buffer, and a request body that was borrowed from the read
    ; buffer or never existed. One block goes back to the pool, as a tail
    ; call (ga_pool_free needs the entry alignment this function was entered
    ; with, and gets it).
    mov     rax, [rdi + Stream.flags]
    test    eax, ST_APP_STATE
    jnz     .full
    cmp     qword [rdi + Stream.resp_buf], 0 ; a static body is non-zero too: the full path skips it
    jne     .full
    test    eax, ST_BORROWED
    jnz     .only_stream
    cmp     qword [rdi + Stream.req_buf], 0
    jne     .full
.only_stream:
    mov     rax, [rdi + Stream.conn]
    mov     rax, [rax + Conn.worker]
    lea     rsi, [rax + Worker.pool]
    jmp     ga_pool_free wrt ..plt      ; (Stream*, Pool*)
.full:
    push    rbx
    push    r12
    sub     rsp, 8                      ; 2 pushes + 8: rsp 16-aligned for calls
    mov     rbx, rdi
    mov     rax, [rbx + Stream.conn]
    mov     rax, [rax + Conn.worker]
    lea     r12, [rax + Worker.pool]
    test    qword [rbx + Stream.flags], ST_APP_STATE
    jz      .no_app_state               ; most calls: one test
    mov     rdi, [rbx + Stream.conn]
    mov     rsi, rbx
    call    ga_app_call_release wrt ..plt
.no_app_state:
    test    qword [rbx + Stream.flags], ST_BORROWED
    jnz     .borrowed                   ; points into the read buffer: not ours
    mov     rdi, [rbx + Stream.req_buf]
    test    rdi, rdi
    jz      .borrowed                   ; no body buffer was ever allocated
    mov     rsi, r12
    call    ga_pool_free wrt ..plt
.borrowed:
    test    qword [rbx + Stream.flags], ST_STATIC_RESP
    jnz     .static_resp                ; .rodata text: freeing it would crash
    mov     rdi, [rbx + Stream.resp_buf]
    test    rdi, rdi
    jz      .static_resp                ; answered without a response buffer
    mov     rsi, r12
    call    ga_pool_free wrt ..plt
.static_resp:
    mov     rdi, rbx
    mov     rsi, r12
    call    ga_pool_free wrt ..plt
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; =============================================================================
; ga_grpc_stream_release — remove a Stream from its connection and free it.
; @param  rdi  Conn*   @param rsi  Stream*
; @returns nothing.
; @remarks Also returns the stream's buffered request bytes to the
;          connection's budget. h2n.asm releases every stream it closes
;          through this function, which keeps Conn.streams and
;          Conn.buffered exact; an application releases the deferred streams
;          the peer reset meanwhile (ST_CLOSED) through it too.
; =============================================================================
ga_grpc_stream_release:
    mov     rcx, [rsi + Stream.prev]
    mov     rdx, [rsi + Stream.next]
    test    rcx, rcx
    jz      .head
    mov     [rcx + Stream.next], rdx
    jmp     .fix
.head:
    mov     [rdi + Conn.streams], rdx
.fix:
    test    rdx, rdx
    jz      .unlinked
    mov     [rdx + Stream.prev], rcx
.unlinked:
    mov     rax, [rsi + Stream.req_cap]
    sub     [rdi + Conn.buffered], rax
    mov     rdi, rsi
    jmp     stream_free                 ; tail call (keeps the caller's alignment)

section .note.GNU-stack noalloc noexec nowrite progbits
