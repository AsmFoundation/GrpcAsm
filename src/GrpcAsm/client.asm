; =============================================================================
; client.asm — GrpcAsm's gRPC client (milestone D): HTTP/2 (RFC 9113) and
; HPACK (RFC 7541) on the client side, unary calls, pipelined.
;
; Contract and structures: include/grpcasm_client.inc. In short, a GaClient
; is one connection owned by one thread; calls are issued with a method
; handle and complete through a callback, on that thread.
;
; Where the time goes, and what this file does about it:
;   * Requests. A method's header block is HPACK-encoded once with the
;     dynamic table (literals with incremental indexing for :path,
;     :authority, content-type and te), and from the next call on it is six
;     indexed bytes, cached per method and copied with two 8-byte moves
;     (gc_encode_block). The HEADERS frame and the call's whole DATA frame
;     leave back to back, which is what the server engine's fused path
;     expects (h2n.asm: no second header parse, no map lookup).
;   * Responses are parsed in place from the input. A response whose HEADERS,
;     DATA and trailers arrive in one input is handed to its callback as a
;     pointer into that input: no copy. Only a response that spans inputs is
;     copied, once, at the end of the input (gc_fixup_borrowed). Header blocks
;     go through the engine's decoder (hpack.asm), whose meanings tell
;     :status 200, the content-type and grpc-status apart without comparing a
;     single string once the table is warm.
;   * Flow control never paces the server: every stream and the connection
;     get the protocol's maximum window, topped up when half of it is used.
;     A unary response is bounded by max_response instead.
;
; Protocol coverage (the client's side of RFC 9113): the connection preface
; and the server's (SETTINGS first), SETTINGS and their ACK, PING, GOAWAY in
; both directions (calls above the server's last stream id fail UNAVAILABLE,
; the others finish), RST_STREAM (mapped to gRPC statuses as the gRPC spec
; does), flow control both ways (including SETTINGS_INITIAL_WINDOW_SIZE
; changes and overflow), CONTINUATION sequencing and bounds, padding,
; PRIORITY validation, PUSH_PROMISE refused (push is disabled), informational
; 1xx responses skipped, malformed responses (RFC 9113 §8.1.1) as stream
; errors, and HPACK table size updates when the server shrinks its table.
;
; gRPC coverage: Trailers-Only and headers + message + trailers responses;
; the HTTP status mapping for non-200 responses; percent-decoded
; grpc-message; exactly one uncompressed message per unary response.
;
; Threading: none. One thread drives a client at a time. The HPACK static
; meanings (ga_hpack_global_init) are written by every ga_client_new with the
; values they already hold, so a client and a server in one process share
; them safely.
; =============================================================================

default rel
bits 64

%define GA_CLIENT_IMPL                  ; this file defines the API it declares
%include "grpcasm_sys.inc"
%include "server.inc"
%include "hpack.inc"
%include "grpcasm_client.inc"

extern malloc
extern calloc
extern realloc
extern free
extern memcpy
extern memmove
extern strlen
extern clock_gettime
extern getaddrinfo
extern freeaddrinfo
extern ga_keyeq
extern ga_pool_malloc
extern ga_pool_calloc
extern ga_pool_free
extern ga_pool_realloc
extern ga_pool_destroy
extern ga_hpack_global_init
extern ga_hpack_init
extern ga_hpack_free
extern ga_hpack_decode

global ga_client_new
global ga_client_connect
global ga_client_free
global ga_client_method
global ga_client_call
global ga_client_unary
global ga_client_input
global ga_client_output
global ga_client_consume
global ga_client_flush
global ga_client_poll
global ga_client_fd

; ---- frame types, flags, error codes, settings (RFC 9113 §6, §7) -----------------
%define FT_DATA             0
%define FT_HEADERS          1
%define FT_PRIORITY         2
%define FT_RST_STREAM       3
%define FT_SETTINGS         4
%define FT_PUSH_PROMISE     5
%define FT_PING             6
%define FT_GOAWAY           7
%define FT_WINDOW_UPDATE    8
%define FT_CONTINUATION     9

%define FF_END_STREAM       0x01
%define FF_ACK              0x01
%define FF_END_HEADERS      0x04
%define FF_PADDED           0x08
%define FF_PRIORITY         0x20

%define E_NO_ERROR          0x0
%define E_PROTOCOL          0x1
%define E_FLOW_CONTROL      0x3
%define E_FRAME_SIZE        0x6
%define E_REFUSED_STREAM    0x7
%define E_CANCEL            0x8
%define E_COMPRESSION       0x9
%define E_ENHANCE_YOUR_CALM 0xb
%define E_INADEQUATE_SECURITY 0xc

%define S_HEADER_TABLE_SIZE 1
%define S_ENABLE_PUSH       2
%define S_MAX_STREAMS       3
%define S_INITIAL_WINDOW    4
%define S_MAX_FRAME_SIZE    5
%define S_ENABLE_CONNECT    8

%define FRAME_HDR           9
%define DEFAULT_WINDOW      65535       ; windows until SETTINGS / WINDOW_UPDATE say more
%define FRAME_LIMIT         16777215    ; largest SETTINGS_MAX_FRAME_SIZE (§6.5.2)
%define MAX_STREAM_ID       0x7FFFFFFF
%define CONT_SELF_DEP       0x100       ; block flag: HEADERS depended on its own stream

; ---- Linux: system calls, errno, sockets, poll ----------------------------------------
%define SYS_poll            7
%define SYS_socket          41
%define SYS_connect         42
%define SYS_setsockopt      54
%define SYS_getsockopt      55
%define EBADF               9
%define EBUSY               16
%define EPROTO              71
%define EMSGSIZE            90
%define ESHUTDOWN           108
%define ETIMEDOUT           110
%define ECONNRESET          104
%define EHOSTUNREACH        113
%define EINPROGRESS         115
%define ECANCELED           125
%define AF_UNSPEC           0
%define SOCK_STREAM         1
%define SOCK_NONBLOCK       0x800
%define SOCK_CLOEXEC        0x80000
%define IPPROTO_TCP         6
%define TCP_NODELAY         1
%define SOL_SOCKET          1
%define SO_ERROR            4
%define POLLIN              1
%define POLLOUT             4
%define POLLERR             8
%define POLLHUP             0x10
%define MSG_NOSIGNAL        0x4000      ; sendto: a vanished peer must not SIGPIPE us
%define CLOCK_MONOTONIC     1
; struct addrinfo (glibc, x86-64)
%define AI_FAMILY           4
%define AI_SOCKTYPE         8
%define AI_PROTOCOL         12
%define AI_ADDRLEN          16
%define AI_ADDR             24
%define AI_NEXT             40
%define ADDRINFO_SIZE       48

; ---- the header-decoding context gc_header_block hands to gc_hdr_field -----------------
%define HX_STATUS           1           ; :status seen
%define HX_CT_OK            2           ; content-type application/grpc[...]
%define HX_BAD              4           ; malformed (RFC 9113 §8.1.1)
%define HX_TRAILERS         8           ; the block is trailers: no pseudo-headers
%define HX_REGULAR          16          ; a regular field was seen (pseudo after it: bad)
struc HdrCtx
    .call:              resq 1          ; GaCall*, or 0: decode for HPACK sync only
    .client:            resq 1          ; GaClient* (its pool keeps grpc-message)
    .status:            resq 1          ; :status, 0 until seen
    .gstatus:           resq 1          ; grpc-status, -1 until seen
    .flags:             resq 1          ; HX_*
endstruc

section .rodata
; The client connection preface (§3.4), sent as one unit:
;   the 24-byte magic;
;   SETTINGS: ENABLE_PUSH = 0 (no PUSH_PROMISE may arrive), INITIAL_WINDOW_SIZE
;   = 2^31 - 1 (every response stream at the protocol maximum);
;   WINDOW_UPDATE(0): the connection window from 65,535 to 2^31 - 1.
gc_preface:
    db      "PRI * HTTP/2.0", 13, 10, 13, 10, "SM", 13, 10, 13, 10
    db      0, 0, 12, FT_SETTINGS, 0, 0, 0, 0, 0
    db      0, S_ENABLE_PUSH, 0, 0, 0, 0
    db      0, S_INITIAL_WINDOW, 0x7F, 0xFF, 0xFF, 0xFF
    db      0, 0, 4, FT_WINDOW_UPDATE, 0, 0, 0, 0, 0
    db      0x7F, 0xFF, 0x00, 0x00      ; 2^31 - 1 - 65,535
gc_preface_len  equ $ - gc_preface
%if GC_WINDOW - DEFAULT_WINDOW != 0x7FFF0000
    %error "the preface's WINDOW_UPDATE increment must match GC_WINDOW"
%endif

s_te:           db "te"
v_trailers:     db "trailers"
v_ctype:        db "application/grpc"
s_localhost:    db "localhost"
s_localhost_len equ $ - s_localhost

; Status messages the client produces (static: nothing to free).
%macro MSG 2+
%1: db %2
%1_len equ $ - %1
%endmacro
MSG m_closed,       "connection closed by the server"
MSG m_lost,         "connection lost"
MSG m_oom,          "client out of memory"
MSG m_conn_error,   "connection error: the server broke the HTTP/2 protocol"
MSG m_client_closed, "client closed"
MSG m_goaway,       "connection draining (GOAWAY): the call was not processed"
MSG m_no_ids,       "connection out of stream ids"
MSG m_refused,      "stream refused by the server"
MSG m_cancelled,    "call cancelled by the server"
MSG m_reset,        "stream reset by the server"
MSG m_malformed,    "malformed response"
MSG m_flow,         "flow-control error on the response stream"
MSG m_ctype,        "response content-type is not application/grpc"
MSG m_nostatus,     "response without grpc-status"
MSG m_frame,        "response is not exactly one gRPC message"
MSG m_compressed,   "compressed response, but no compression was negotiated"
MSG m_too_large,    "response larger than max_response"
MSG m_no_trailers,  "response ended without trailers"
MSG m_deadline,     "deadline exceeded"
MSG m_http,         "HTTP status "

section .text

; =============================================================================
; ga_client_new — create a client without a socket (bytes in, bytes out).
;
; @param  rdi  GaClientConfig*, or 0 for every default
; @param  rsi  GaClient** — receives the client (0 on failure)
; @returns eax = 0, -EINVAL (out pointer 0, an authority of 0 or more than
;          GC_MAX_AUTHORITY bytes, max_response or max_calls above its limit)
;          or -ENOMEM.
; @remarks The client's output already holds the connection preface: the
;          caller sends ga_client_output's bytes before anything else.
;          Calls may be issued at once: until the server's SETTINGS arrive the
;          protocol's defaults apply (65,535-byte windows, 16 KiB frames, no
;          stream limit), exactly what the server assumes of us.
;          The authority defaults to "localhost" here; ga_client_connect
;          derives "host:port".
; =============================================================================
ga_client_new:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    sub     rsp, 32                     ; [0] authority [8] its length [16] max_response
                                        ; [24] max_calls; 5 pushes + 32: aligned
    mov     r12, rdi
    mov     r13, rsi
    test    r13, r13
    jz      .einval
    mov     qword [r13], 0
    lea     rax, [s_localhost]
    mov     [rsp], rax
    mov     qword [rsp + 8], s_localhost_len
    mov     qword [rsp + 16], GC_DEFAULT_MAX_RESPONSE
    mov     qword [rsp + 24], GC_DEFAULT_MAX_CALLS
    test    r12, r12
    jz      .validated
    ; Every field is checked before anything is allocated, so a bad
    ; configuration costs nothing to refuse.
    mov     rax, [r12 + GaClientConfig.authority]
    test    rax, rax
    jz      .cfg_response
    mov     rcx, [r12 + GaClientConfig.authority_len]
    test    rcx, rcx
    jz      .einval
    cmp     rcx, GC_MAX_AUTHORITY
    ja      .einval
    mov     [rsp], rax
    mov     [rsp + 8], rcx
.cfg_response:
    mov     rax, [r12 + GaClientConfig.max_response]
    test    rax, rax
    jz      .cfg_calls
    cmp     rax, GC_LIMIT_MAX_RESPONSE
    ja      .einval
    mov     [rsp + 16], rax
.cfg_calls:
    mov     rax, [r12 + GaClientConfig.max_calls]
    test    rax, rax
    jz      .validated
    cmp     rax, GC_LIMIT_MAX_CALLS
    ja      .einval
    mov     [rsp + 24], rax
.validated:
    call    ga_hpack_global_init wrt ..plt
    mov     edi, 1
    mov     esi, GaClient_size
    call    calloc wrt ..plt
    test    rax, rax
    jz      .enomem
    mov     rbx, rax
    mov     qword [rbx + GaClient.fd], -1
    ; From here on a failure frees whatever was set up (gc_destroy frees
    ; null pointers as nothing, and the pool and decoder start zeroed).
    mov     edi, OUT_INITIAL
    call    malloc wrt ..plt
    test    rax, rax
    jz      .fail
    mov     [rbx + GaClient.out_buf], rax
    mov     qword [rbx + GaClient.out_cap], OUT_INITIAL
    mov     edi, GC_CARRY_CAP
    call    malloc wrt ..plt
    test    rax, rax
    jz      .fail
    mov     [rbx + GaClient.carry], rax
    mov     edi, GC_SCRATCH
    call    malloc wrt ..plt
    test    rax, rax
    jz      .fail
    mov     [rbx + GaClient.scratch], rax
    mov     qword [rbx + GaClient.scratch + 8], GC_SCRATCH
    mov     rdi, [rsp + 8]
    call    malloc wrt ..plt
    test    rax, rax
    jz      .fail
    mov     [rbx + GaClient.authority], rax
    mov     rdx, [rsp + 8]
    mov     [rbx + GaClient.authority_len], rdx
    mov     rdi, rax
    mov     rsi, [rsp]
    call    memcpy wrt ..plt
    lea     rdi, [rbx + GaClient.hpack]
    lea     rsi, [rbx + GaClient.pool]
    mov     edx, GC_HPACK_TABLE
    call    ga_hpack_init wrt ..plt
    test    rax, rax
    jnz     .fail
    ; The call ring: a power of two at least twice max_calls, so that a free
    ; slot is never more than a few stream ids away (gc_start skips ids whose
    ; slot a long call still holds).
    mov     rax, [rsp + 24]
    mov     [rbx + GaClient.max_calls], rax
    add     rax, rax
    mov     ecx, 16
.pow2:
    cmp     rcx, rax
    jae     .ring
    shl     rcx, 1
    jmp     .pow2
.ring:
    lea     rax, [rcx - 1]
    mov     [rbx + GaClient.ring_mask], rax
    mov     rdi, rcx
    mov     esi, 8
    call    calloc wrt ..plt
    test    rax, rax
    jz      .fail
    mov     [rbx + GaClient.calls], rax
    mov     edi, 8 * 8
    call    malloc wrt ..plt
    test    rax, rax
    jz      .fail
    mov     [rbx + GaClient.methods], rax
    mov     qword [rbx + GaClient.mcap], 8
    mov     rax, [rsp + 16]
    mov     [rbx + GaClient.max_response], rax
    mov     qword [rbx + GaClient.next_id], 1
    mov     qword [rbx + GaClient.send_window], DEFAULT_WINDOW
    mov     qword [rbx + GaClient.recv_window], GC_WINDOW
    mov     qword [rbx + GaClient.peer_window], DEFAULT_WINDOW
    mov     qword [rbx + GaClient.peer_frame], GC_FRAME_MAX
    mov     eax, 0xFFFFFFFF                 ; no stream limit until SETTINGS name one
    mov     [rbx + GaClient.peer_streams], rax
    mov     qword [rbx + GaClient.enc_max], GC_ENC_MAX
    mov     qword [rbx + GaClient.enc_old], 1   ; empty table: oldest = newest + 1
    lea     rsi, [gc_preface]
    mov     edx, gc_preface_len
    mov     rdi, [rbx + GaClient.out_buf]
    mov     [rbx + GaClient.out_len], rdx
    call    memcpy wrt ..plt
    mov     [r13], rbx
    xor     eax, eax
    jmp     .out
.fail:
    mov     rdi, rbx
    call    gc_destroy
.enomem:
    mov     eax, -ENOMEM
    jmp     .out
.einval:
    mov     eax, -EINVAL
.out:
    add     rsp, 32
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_destroy — release every byte a client holds, without callbacks.
; Internal.
; @param  rdi  GaClient* (possibly half-built by ga_client_new)
; @returns nothing.
; @remarks Calls still registered are pool blocks, given back with the pool:
;          ga_client_free completes them first; ga_client_new's failure path
;          has none. Closes the socket when there is one.
; =============================================================================
gc_destroy:
    push    rbx
    push    r12
    sub     rsp, 8                      ; 2 pushes + 8: aligned
    mov     rbx, rdi
    mov     rdi, [rbx + GaClient.fd]
    test    rdi, rdi
    js      .no_fd
    mov     eax, SYS_close
    syscall
.no_fd:
    lea     rdi, [rbx + GaClient.hpack]
    call    ga_hpack_free wrt ..plt     ; no-op when never initialized
    xor     r12d, r12d
.method:
    cmp     r12, [rbx + GaClient.nmethods]
    jae     .methods_done
    mov     rax, [rbx + GaClient.methods]
    mov     rdi, [rax + r12*8]
    call    free wrt ..plt
    inc     r12
    jmp     .method
.methods_done:
    mov     rdi, [rbx + GaClient.methods]
    call    free wrt ..plt
    mov     rdi, [rbx + GaClient.calls]
    call    free wrt ..plt
    mov     rdi, [rbx + GaClient.out_buf]
    call    free wrt ..plt
    mov     rdi, [rbx + GaClient.carry]
    call    free wrt ..plt
    mov     rdi, [rbx + GaClient.scratch]
    call    free wrt ..plt
    mov     rdi, [rbx + GaClient.authority]
    call    free wrt ..plt
    mov     rdi, [rbx + GaClient.read_buf]
    call    free wrt ..plt
    mov     rdi, [rbx + GaClient.hb_buf]
    call    free wrt ..plt
    lea     rdi, [rbx + GaClient.pool]
    call    ga_pool_destroy wrt ..plt
    mov     rdi, rbx
    call    free wrt ..plt
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; =============================================================================
; ga_client_free — end every call, close the connection, free the client.
;
; @param  rdi  GaClient*, or 0 (ignored)
; @returns nothing.
; @remarks Calls still in flight or queued complete first, with CANCELLED
;          "client closed": every issued call gets its one callback. In socket
;          mode a GOAWAY(NO_ERROR) is offered to the socket (one non-blocking
;          send, ignored if refused) before it is closed.
;          Footgun: never call it from a callback, or while another thread
;          drives the client — the callback's caller still uses the client.
; =============================================================================
ga_client_free:
    test    rdi, rdi
    jz      .none
    push    rbx
    sub     rsp, 16                     ; [0..8) GOAWAY payload; 1 push + 16: aligned
    mov     rbx, rdi
    mov     rsi, -ECANCELED
    mov     edx, GC_CANCELLED
    lea     rcx, [m_client_closed]
    mov     r8d, m_client_closed_len
    call    gc_close                    ; no-op when already closed
    cmp     qword [rbx + GaClient.fd], 0
    jl      .destroy
    mov     qword [rsp], 0              ; last stream id 0 (the server opened none),
    mov     rdi, rbx                    ; NO_ERROR
    mov     esi, FT_GOAWAY
    xor     edx, edx
    xor     ecx, ecx
    mov     r8, rsp
    mov     r9d, 8
    call    gc_write_frame
    mov     rdi, rbx
    call    gc_flush                    ; best effort: the socket closes either way
.destroy:
    mov     rdi, rbx
    call    gc_destroy
    add     rsp, 16
    pop     rbx
.none:
    ret

; =============================================================================
; ga_client_method — register a method's path, or find it registered.
;
; @param  rdi  GaClient*
; @param  rsi  path bytes, "/<package.Service>/<Method>"
; @param  rdx  path length, 1..GC_MAX_PATH
; @returns eax = the method's handle (0, 1, ...: the registration order), or
;          -EINVAL (no path, empty, too long, or not starting with '/') or
;          -ENOMEM.
; @remarks Registering the same path again returns the same handle (a linear
;          search: methods are registered once, not per call). The path is
;          copied. A handle stays valid for the client's lifetime.
; =============================================================================
ga_client_method:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14                         ; 5 pushes: aligned
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    test    r12, r12
    jz      .einval
    test    r13, r13
    jz      .einval
    cmp     r13, GC_MAX_PATH
    ja      .einval
    cmp     byte [r12], '/'
    jne     .einval
    xor     ebp, ebp
.find:
    cmp     rbp, [rbx + GaClient.nmethods]
    jae     .new
    mov     rax, [rbx + GaClient.methods]
    mov     r14, [rax + rbp*8]
    cmp     [r14 + GaMethod.path_len], r13
    jne     .skip
    mov     rdi, [r14 + GaMethod.path]
    mov     rsi, r12
    mov     rdx, r13
    call    ga_keyeq wrt ..plt
    test    eax, eax
    jnz     .found
.skip:
    inc     rbp
    jmp     .find
.found:
    mov     eax, ebp
    jmp     .out
.new:
    mov     rax, [rbx + GaClient.nmethods]
    cmp     rax, [rbx + GaClient.mcap]
    jb      .room
    mov     rsi, [rbx + GaClient.mcap]
    shl     rsi, 4                      ; twice the capacity, 8 bytes each
    mov     rdi, [rbx + GaClient.methods]
    call    realloc wrt ..plt
    test    rax, rax
    jz      .enomem
    mov     [rbx + GaClient.methods], rax
    shl     qword [rbx + GaClient.mcap], 1
.room:
    ; One block: the GaMethod, then the path's bytes.
    lea     rdi, [r13 + GaMethod_size]
    call    malloc wrt ..plt
    test    rax, rax
    jz      .enomem
    mov     r14, rax
    lea     rdi, [r14 + GaMethod_size]
    mov     [r14 + GaMethod.path], rdi
    mov     [r14 + GaMethod.path_len], r13
    mov     qword [r14 + GaMethod.seq], 0
    mov     qword [r14 + GaMethod.gen], -1  ; no cached block yet
    mov     qword [r14 + GaMethod.block_len], 0
    mov     rsi, r12
    mov     rdx, r13
    call    memcpy wrt ..plt
    mov     rax, [rbx + GaClient.nmethods]
    mov     rcx, [rbx + GaClient.methods]
    mov     [rcx + rax*8], r14
    inc     qword [rbx + GaClient.nmethods]
    jmp     .out                        ; eax = the new handle
.enomem:
    mov     eax, -ENOMEM
    jmp     .out
.einval:
    mov     eax, -EINVAL
.out:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; ga_client_call — issue a unary call.
;
; @param  rdi  GaClient*
; @param  esi  method handle (ga_client_method)
; @param  rdx  request message (protobuf bytes, without the gRPC framing);
;              may be 0 when the length is 0
; @param  rcx  its length, below 4 GiB
; @param  r8   done callback (grpcasm_client.inc), never 0
; @param  r9   its context
; @returns eax = 0: the call is issued and done will run exactly once; or,
;          and then done never runs: -EINVAL (bad handle, no callback, no
;          request bytes), -EMSGSIZE (4 GiB or more), -ESHUTDOWN (the server
;          sent GOAWAY, or the connection used up its stream ids: open a new
;          client), the connection's error once it failed (-ECONNRESET, ...),
;          or -ENOMEM.
; @remarks The request is framed into the output buffer at once when the
;          call gets a stream (copied); a call over the concurrency limit
;          (max_calls, the server's MAX_CONCURRENT_STREAMS) waits in a queue
;          with its own copy. Nothing is sent: in socket mode the next
;          ga_client_flush / poll sends it, in bytes mode the caller does —
;          so many calls issued back to back leave in one send.
;          May be called from a done callback (the usual way to keep a
;          pipeline full).
; =============================================================================
ga_client_call:
    sub     rsp, 8                      ; aligned for the call
    call    gc_call
    add     rsp, 8
    test    rax, rax
    js      .out                        ; eax = -errno
    xor     eax, eax
.out:
    ret

; =============================================================================
; gc_call — ga_client_call's body. Internal.
; @param  as ga_client_call
; @returns rax = the GaCall* (issued), or -errno (nothing issued).
; @remarks ga_client_unary needs the call itself, to cancel it on timeout.
; =============================================================================
gc_call:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; [0] context; 6 pushes + 8: aligned
    mov     rbx, rdi
    movsxd  r12, esi
    mov     r13, rdx
    mov     r14, rcx
    mov     r15, r8
    mov     [rsp], r9
    test    r15, r15
    jz      .einval
    test    r12, r12
    js      .einval
    cmp     r12, [rbx + GaClient.nmethods]
    jae     .einval
    mov     eax, 0xFFFFFFFF
    cmp     r14, rax
    ja      .emsgsize
    test    r14, r14
    jz      .state
    test    r13, r13
    jz      .einval
.state:
    mov     rax, [rbx + GaClient.flags]
    test    eax, GCF_CLOSED
    jnz     .closed
    test    eax, GCF_GOAWAY | GCF_NO_IDS
    jnz     .eshutdown
    mov     edi, 1
    mov     esi, GaCall_size
    lea     rdx, [rbx + GaClient.pool]
    call    ga_pool_calloc wrt ..plt
    test    rax, rax
    jz      .enomem
    mov     rbp, rax
    mov     rax, [rbx + GaClient.methods]
    mov     rax, [rax + r12*8]
    mov     [rbp + GaCall.method], rax
    mov     [rbp + GaCall.done], r15
    mov     rax, [rsp]
    mov     [rbp + GaCall.ctx], rax
    mov     [rbp + GaCall.req_len], r14
    mov     qword [rbp + GaCall.grpc_status], -1
    ; A stream now, or the queue: the queue keeps its order, so a call never
    ; overtakes one that is already waiting.
    cmp     qword [rbx + GaClient.queue_head], 0
    jne     .queue
    mov     rax, [rbx + GaClient.max_calls]
    mov     rcx, [rbx + GaClient.peer_streams]
    cmp     rcx, rax
    cmovb   rax, rcx
    cmp     [rbx + GaClient.active], rax
    jae     .queue
    mov     rdi, rbx
    mov     rsi, rbp
    mov     rdx, r13
    call    gc_start
    test    eax, eax
    js      .free_enomem                ; nothing was changed: the call never existed
    jnz     .free_eshutdown             ; no stream id left (GCF_NO_IDS is now set)
    mov     rax, rbp
    jmp     .out
.queue:
    test    r14, r14
    jz      .enqueue
    mov     rdi, r14
    lea     rsi, [rbx + GaClient.pool]
    call    ga_pool_malloc wrt ..plt
    test    rax, rax
    jz      .free_enomem
    mov     [rbp + GaCall.req], rax
    mov     rdi, rax
    mov     rsi, r13
    mov     rdx, r14
    call    memcpy wrt ..plt
.enqueue:
    or      qword [rbp + GaCall.flags], GCC_QUEUED
    mov     rax, [rbx + GaClient.queue_tail]
    test    rax, rax
    jz      .q_first
    mov     [rax + GaCall.next], rbp
    jmp     .q_tail
.q_first:
    mov     [rbx + GaClient.queue_head], rbp
.q_tail:
    mov     [rbx + GaClient.queue_tail], rbp
    mov     rax, rbp
    jmp     .out
.free_eshutdown:
    mov     r12, -ESHUTDOWN
    jmp     .free
.free_enomem:
    mov     r12, -ENOMEM
.free:
    lea     rsi, [rbx + GaClient.pool]
    mov     rdi, [rbp + GaCall.req]
    call    ga_pool_free wrt ..plt
    mov     rdi, rbp
    lea     rsi, [rbx + GaClient.pool]
    call    ga_pool_free wrt ..plt
    mov     rax, r12
    jmp     .out
.closed:
    mov     rax, [rbx + GaClient.error]
    jmp     .out
.eshutdown:
    mov     rax, -ESHUTDOWN
    jmp     .out
.emsgsize:
    mov     rax, -EMSGSIZE
    jmp     .out
.enomem:
    mov     rax, -ENOMEM
    jmp     .out
.einval:
    mov     rax, -EINVAL
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_start — give a call a stream and frame its request. Internal.
;
; @param  rdi  GaClient*   @param rsi  GaCall* (not open)
; @param  rdx  the request message's bytes (the caller's, or GaCall.req)
; @returns eax = 0 (started; what the windows did not allow waits on the pend
;          list with the call's own copy), 1 (no stream id left: GCF_NO_IDS is
;          set and nothing was changed), -1 (out of memory: nothing was
;          changed).
; @remarks Every allocation happens before the first byte is framed: the
;          output buffer is grown to hold the HEADERS frame and every DATA
;          frame the windows allow, then rewound, so the writes below only
;          ever take reserve's fast path. An out-of-memory therefore never
;          leaves a half-written request (a HEADERS without its DATA would
;          leave the stream open on the server, and the encoder's table out
;          of step).
;          Stream ids: the next odd id whose ring slot is free. A long call
;          holding the slot of the next id makes us skip that id, which RFC
;          9113 allows (§5.1.1: skipped ids are closed).
; =============================================================================
gc_start:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24                     ; [0] id [8] ring slot [16] block length; aligned
    mov     rbx, rdi
    mov     rbp, rsi
    mov     r12, rdx
    mov     rax, [rbx + GaClient.next_id]
.id:
    cmp     rax, MAX_STREAM_ID
    ja      .no_ids
    mov     rcx, rax
    shr     rcx, 1
    and     rcx, [rbx + GaClient.ring_mask]
    mov     rdx, [rbx + GaClient.calls]
    cmp     qword [rdx + rcx*8], 0
    je      .have_id
    add     rax, 2
    jmp     .id
.have_id:
    mov     [rsp], rax
    mov     [rsp + 8], rcx
    ; What the windows allow now: min(total, stream window, connection window),
    ; where a fresh stream's window is the server's initial window.
    mov     r14, [rbp + GaCall.req_len]
    add     r14, GRPC_PREFIX            ; total bytes of [prefix | message]
    mov     rax, [rbx + GaClient.peer_window]
    mov     rcx, [rbx + GaClient.send_window]
    cmp     rcx, rax
    cmovl   rax, rcx
    test    rax, rax
    jg      .positive
    xor     eax, eax
.positive:
    mov     r13, r14
    cmp     r13, rax
    cmova   r13, rax                    ; r13 = bytes framed now
    ; Room: the HEADERS frame (block bound, see gc_encode_block) plus each
    ; DATA frame's header and payload.
    mov     rax, [rbp + GaCall.method]
    mov     r15, [rax + GaMethod.path_len]
    add     r15, [rbx + GaClient.authority_len]
    add     r15, FRAME_HDR + 128
    test    r13, r13
    jz      .room
    mov     rcx, [rbx + GaClient.peer_frame]
    mov     rax, r13
    cmp     rax, rcx
    ja      .many_frames
    lea     r15, [r15 + r13 + FRAME_HDR]
    jmp     .room
.many_frames:
    xor     edx, edx
    lea     rax, [r13 + rcx - 1]
    div     rcx                         ; frames = ceil(now / peer_frame)
    imul    rax, rax, FRAME_HDR
    add     r15, rax
    add     r15, r13
.room:
    ; The copy a pending request needs, first (it is the other allocation).
    cmp     r13, r14
    je      .no_copy
    cmp     qword [rbp + GaCall.req], 0
    jne     .no_copy
    mov     rdi, [rbp + GaCall.req_len]
    test    rdi, rdi
    jz      .no_copy                    ; only the prefix waits: nothing to keep
    lea     rsi, [rbx + GaClient.pool]
    call    ga_pool_malloc wrt ..plt
    test    rax, rax
    jz      .nomem
    mov     [rbp + GaCall.req], rax
    mov     rdi, rax
    mov     rsi, r12
    mov     rdx, [rbp + GaCall.req_len]
    call    memcpy wrt ..plt
.no_copy:
    mov     rdi, rbx
    mov     rsi, r15
    call    gc_out_reserve
    test    rax, rax
    jz      .nomem                      ; (a copy just made is freed with the call)
    sub     rax, [rbx + GaClient.out_buf]
    mov     [rbx + GaClient.out_len], rax ; rewind: the room stays reserved
    ; ---- committed: register the stream ----
    mov     rax, [rsp]
    mov     rcx, [rsp + 8]
    mov     rdx, [rbx + GaClient.calls]
    mov     [rdx + rcx*8], rbp
    mov     [rbp + GaCall.id], rax
    add     rax, 2
    mov     [rbx + GaClient.next_id], rax
    inc     qword [rbx + GaClient.active]
    or      qword [rbp + GaCall.flags], GCC_OPEN
    mov     rax, [rbx + GaClient.peer_window]
    mov     [rbp + GaCall.send_window], rax
    mov     qword [rbp + GaCall.recv_window], GC_WINDOW
    ; HEADERS: [frame header][block]
    mov     rax, [rbp + GaCall.method]
    mov     rsi, [rax + GaMethod.path_len]
    add     rsi, [rbx + GaClient.authority_len]
    add     rsi, FRAME_HDR + 128
    mov     rdi, rbx
    call    gc_out_reserve              ; fast path: the room is there
    mov     r15, rax
    mov     rdi, rbx
    mov     rsi, [rbp + GaCall.method]
    lea     rdx, [r15 + FRAME_HDR]
    call    gc_encode_block
    mov     [rsp + 16], rax
    mov     rdi, r15
    mov     esi, eax
    mov     edx, FT_HEADERS
    mov     ecx, FF_END_HEADERS
    mov     r8d, [rbp + GaCall.id]
    call    gc_put_hdr
    mov     rax, [rsp + 16]
    lea     rax, [r15 + rax + FRAME_HDR]
    sub     rax, [rbx + GaClient.out_buf]
    mov     [rbx + GaClient.out_len], rax ; the HEADERS frame's real end
    ; DATA: what the windows allow; the rest waits for WINDOW_UPDATE.
    mov     rdi, rbx
    mov     rsi, rbp
    mov     rdx, [rbp + GaCall.req]
    test    rdx, rdx
    cmovz   rdx, r12                    ; framed from the copy when there is one
    call    gc_send_data
    test    eax, eax
    jz      .ok
    js      .nomem_late                 ; cannot happen: the room is reserved
    or      qword [rbp + GaCall.flags], GCC_PEND
    mov     qword [rbp + GaCall.pend_next], 0
    mov     rax, [rbx + GaClient.pend_tail]
    test    rax, rax
    jz      .p_first
    mov     [rax + GaCall.pend_next], rbp
    jmp     .p_tail
.p_first:
    mov     [rbx + GaClient.pend_head], rbp
.p_tail:
    mov     [rbx + GaClient.pend_tail], rbp
.ok:
    xor     eax, eax
    jmp     .out
.nomem_late:
    ; Defensive: gc_send_data only reserves what was reserved above. Should it
    ; ever fail, the connection is unusable (a HEADERS frame without its
    ; DATA): close it rather than leave a stream hanging.
    mov     rdi, rbx
    mov     rsi, -ENOMEM
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_oom]
    mov     r8d, m_oom_len
    call    gc_close
    xor     eax, eax                    ; the call was completed by gc_close
    jmp     .out
.no_ids:
    or      qword [rbx + GaClient.flags], GCF_NO_IDS
    mov     eax, 1
    jmp     .out
.nomem:
    mov     eax, -1
.out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_send_data — frame as much of a call's request as the windows allow.
; Internal.
; @param  rdi  GaClient*   @param rsi  GaCall* (open)
; @param  rdx  the message's bytes (the caller's, or GaCall.req)
; @returns eax = 0 (the whole request is framed, END_STREAM included), 1 (the
;          windows closed first: the rest waits), -1 (out of memory).
; @remarks The request is the byte stream [0][length, 4 bytes big-endian]
;          [message]; GaCall.req_off says how much of it is framed. Frames
;          are at most the server's SETTINGS_MAX_FRAME_SIZE; the one that
;          ends the stream carries END_STREAM.
; =============================================================================
gc_send_data:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24                     ; [0..5) the gRPC prefix; aligned
    mov     rbx, rdi
    mov     rbp, rsi
    mov     r12, rdx
    mov     byte [rsp], 0               ; compressed flag: never
    mov     eax, [rbp + GaCall.req_len]
    bswap   eax
    mov     [rsp + 1], eax
.frame:
    mov     r13, [rbp + GaCall.req_len]
    add     r13, GRPC_PREFIX
    sub     r13, [rbp + GaCall.req_off] ; bytes not framed yet
    jz      .done
    mov     rax, [rbp + GaCall.send_window]
    mov     rcx, [rbx + GaClient.send_window]
    cmp     rcx, rax
    cmovl   rax, rcx
    test    rax, rax
    jle     .pending                    ; a window is closed (or negative)
    cmp     r13, rax
    cmova   r13, rax
    mov     rax, [rbx + GaClient.peer_frame]
    cmp     r13, rax
    cmova   r13, rax                    ; r13 = this frame's payload
    mov     rdi, rbx
    lea     rsi, [r13 + FRAME_HDR]
    call    gc_out_reserve
    test    rax, rax
    jz      .nomem
    mov     r14, rax
    mov     rax, [rbp + GaCall.req_len]
    add     rax, GRPC_PREFIX
    sub     rax, [rbp + GaCall.req_off]
    xor     ecx, ecx
    cmp     rax, r13
    jne     .hdr
    mov     ecx, FF_END_STREAM          ; this frame ends the request
.hdr:
    mov     rdi, r14
    mov     esi, r13d
    mov     edx, FT_DATA
    mov     r8d, [rbp + GaCall.id]
    call    gc_put_hdr
    add     r14, FRAME_HDR              ; payload destination
    mov     r15, r13                    ; payload bytes still to place
    mov     rax, [rbp + GaCall.req_off]
    cmp     rax, GRPC_PREFIX
    jae     .body
    ; The prefix's remaining bytes first (all 5 unless a window cut it).
    mov     ecx, GRPC_PREFIX
    sub     ecx, eax
    cmp     rcx, r15
    cmova   rcx, r15
.prefix:
    mov     dl, [rsp + rax]
    mov     [r14], dl
    inc     rax
    inc     r14
    dec     r15
    dec     rcx
    jnz     .prefix
.body:
    test    r15, r15
    jz      .advance
    ; Message offset = (req_off + bytes of this frame already placed) - 5.
    mov     rsi, [rbp + GaCall.req_off]
    add     rsi, r13
    sub     rsi, r15
    sub     rsi, GRPC_PREFIX
    add     rsi, r12
    mov     rdi, r14
    mov     rdx, r15
    call    memcpy wrt ..plt
.advance:
    add     [rbp + GaCall.req_off], r13
    sub     [rbp + GaCall.send_window], r13
    sub     [rbx + GaClient.send_window], r13
    jmp     .frame
.done:
    xor     eax, eax
    jmp     .out
.pending:
    mov     eax, 1
    jmp     .out
.nomem:
    mov     eax, -1
.out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_pump — move what windows and stream slots now allow. Internal.
; @param  rdi  GaClient*
; @returns eax = 0, or -1 when out of memory.
; @remarks Runs after every input (windows may have opened, calls may have
;          freed their streams) and after a cancellation. Two steps:
;          1. pending requests, in arrival order, while the connection window
;             is open (a call blocked by its own stream window is passed
;             over, not waited for); a finished one leaves the pend list and
;             gives its request copy back;
;          2. queued calls get streams while the concurrency limit allows. If
;             the stream ids run out, the queue fails UNAVAILABLE: those
;             calls can only run on a new connection.
; =============================================================================
gc_pump:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14                         ; 5 pushes: aligned
    mov     rbx, rdi
    xor     r12d, r12d                  ; previous call on the pend list
    mov     rbp, [rbx + GaClient.pend_head]
.pend:
    test    rbp, rbp
    jz      .queue
    cmp     qword [rbx + GaClient.send_window], 0
    jle     .queue
    mov     r13, [rbp + GaCall.pend_next]
    mov     rdi, rbx
    mov     rsi, rbp
    mov     rdx, [rbp + GaCall.req]
    call    gc_send_data
    test    eax, eax
    js      .nomem
    jnz     .keep
    ; Framed in full: off the list (prev-linked), copy released.
    test    r12, r12
    jz      .unlink_head
    mov     [r12 + GaCall.pend_next], r13
    jmp     .unlinked
.unlink_head:
    mov     [rbx + GaClient.pend_head], r13
.unlinked:
    cmp     [rbx + GaClient.pend_tail], rbp
    jne     .tail_ok
    mov     [rbx + GaClient.pend_tail], r12
.tail_ok:
    and     qword [rbp + GaCall.flags], ~GCC_PEND
    mov     rdi, [rbp + GaCall.req]
    lea     rsi, [rbx + GaClient.pool]
    call    ga_pool_free wrt ..plt
    mov     qword [rbp + GaCall.req], 0
    mov     rbp, r13
    jmp     .pend
.keep:
    mov     r12, rbp
    mov     rbp, r13
    jmp     .pend
.queue:
    mov     rbp, [rbx + GaClient.queue_head]
    test    rbp, rbp
    jz      .ok
    test    qword [rbx + GaClient.flags], GCF_CLOSED | GCF_GOAWAY | GCF_NO_IDS
    jnz     .ok                         ; GOAWAY / closing already failed the queue
    mov     rax, [rbx + GaClient.max_calls]
    mov     rcx, [rbx + GaClient.peer_streams]
    cmp     rcx, rax
    cmovb   rax, rcx
    cmp     [rbx + GaClient.active], rax
    jae     .ok
    mov     rdi, rbx
    mov     rsi, rbp
    mov     rdx, [rbp + GaCall.req]
    call    gc_start
    test    eax, eax
    js      .nomem                      ; still queued, nothing changed
    jnz     .no_ids
    ; Started: off the queue (it is the head).
    mov     rax, [rbp + GaCall.next]
    mov     [rbx + GaClient.queue_head], rax
    test    rax, rax
    jnz     .q_ok
    mov     qword [rbx + GaClient.queue_tail], 0
.q_ok:
    mov     qword [rbp + GaCall.next], 0
    and     qword [rbp + GaCall.flags], ~GCC_QUEUED
    test    qword [rbp + GaCall.flags], GCC_PEND
    jnz     .queue                      ; the copy is still needed
    mov     rdi, [rbp + GaCall.req]
    lea     rsi, [rbx + GaClient.pool]
    call    ga_pool_free wrt ..plt
    mov     qword [rbp + GaCall.req], 0
    jmp     .queue
.no_ids:
    ; Every queued call fails: none can get a stream on this connection.
.fail_queue:
    mov     rsi, [rbx + GaClient.queue_head]
    test    rsi, rsi
    jz      .ok
    mov     rdi, rbx
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_no_ids]
    mov     r8d, m_no_ids_len
    xor     r9d, r9d
    call    gc_complete
    jmp     .fail_queue
.ok:
    xor     eax, eax
    jmp     .out
.nomem:
    mov     eax, -1
.out:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_encode_block — a call's request header block. Internal.
;
; @param  rdi  GaClient*   @param rsi  GaMethod*
; @param  rdx  destination: at least 128 + path + authority bytes of room
; @returns rax = the block's length.
; @remarks The fields: :method POST (static 3), :scheme http (static 6),
;          :path, :authority, content-type: application/grpc, te: trailers.
;          The last four are indexed when the server's table holds them, and
;          inserted (literal with incremental indexing) otherwise, so from a
;          method's second call on the whole block is indexed: 6 bytes. That
;          block is kept in the method (GC_BLOCK_CACHE bytes) with the
;          encoder generation it is valid for, and copied as it is while
;          nothing in the table moves — the steady state costs two loads and
;          two stores, no encoding.
;          A pending size update (the server shrank its table) opens the
;          block, as RFC 7541 §4.2 requires; such a block is never cached.
;          The cached copy writes 16 bytes whatever the length: the room
;          above covers it, and the caller frames from the real length.
; =============================================================================
gc_encode_block:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; aligned
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx                    ; cursor
    ; The generation alone decides. A pending size update (GCF_TSU) never
    ; meets a valid cached block: gc_enc_set_max moves the generation when it
    ; sets the flag, and a block is cached only by a build, which clears the
    ; flag first. (A planted bug that skipped this check entirely changed no
    ; test result, which is how the invariant was confirmed: the check was
    ; redundant, and cost two instructions per call.)
    mov     rax, [r12 + GaMethod.gen]
    cmp     rax, [rbx + GaClient.enc_gen]
    jne     .build
    mov     rax, [r12 + GaMethod.block]
    mov     [r13], rax
    mov     rax, [r12 + GaMethod.block + 8]
    mov     [r13 + 8], rax
    mov     rax, [r12 + GaMethod.block_len]
    jmp     .out
.build:
    mov     r14, r13                    ; block start
    xor     r15d, r15d                  ; 0 while the block stays cacheable
    test    qword [rbx + GaClient.flags], GCF_TSU
    jz      .fixed
    ; Dynamic table size update(s), RFC 7541 §6.3: the smallest size since
    ; the last block first when it differs, then the final one (§4.2).
    and     qword [rbx + GaClient.flags], ~GCF_TSU
    mov     r15d, 1
    mov     rsi, [rbx + GaClient.enc_tsu_min]
    cmp     rsi, [rbx + GaClient.enc_max]
    jae     .final_size
    mov     rdi, r13
    mov     edx, 5
    mov     ecx, 0x20
    call    gc_put_int
    mov     r13, rax
.final_size:
    mov     rdi, r13
    mov     rsi, [rbx + GaClient.enc_max]
    mov     edx, 5
    mov     ecx, 0x20
    call    gc_put_int
    mov     r13, rax
.fixed:
    mov     word [r13], 0x8683          ; 0x83 :method POST, 0x86 :scheme http
    add     r13, 2
    mov     rdi, rbx
    mov     rsi, r13
    lea     rdx, [r12 + GaMethod.seq]
    mov     ecx, 4                      ; :path (static name 4)
    mov     r8, [r12 + GaMethod.path]
    mov     r9, [r12 + GaMethod.path_len]
    call    gc_field
    mov     r13, rax
    or      r15d, edx
    mov     rdi, rbx
    mov     rsi, r13
    lea     rdx, [rbx + GaClient.auth_seq]
    mov     ecx, 1                      ; :authority (static name 1)
    mov     r8, [rbx + GaClient.authority]
    mov     r9, [rbx + GaClient.authority_len]
    call    gc_field
    mov     r13, rax
    or      r15d, edx
    mov     rdi, rbx
    mov     rsi, r13
    lea     rdx, [rbx + GaClient.ct_seq]
    mov     ecx, 31                     ; content-type (static name 31)
    lea     r8, [v_ctype]
    mov     r9d, 16
    call    gc_field
    mov     r13, rax
    or      r15d, edx
    mov     rdi, rbx
    mov     rsi, r13
    lea     rdx, [rbx + GaClient.te_seq]
    xor     ecx, ecx                    ; te: a literal name
    lea     r8, [v_trailers]
    mov     r9d, 8
    call    gc_field
    mov     r13, rax
    or      r15d, edx
    mov     rax, r13
    sub     rax, r14                    ; block length
    test    r15d, r15d
    jnz     .out                        ; something was inserted: not the steady form
    cmp     rax, GC_BLOCK_CACHE
    ja      .out
    mov     rcx, [r14]
    mov     [r12 + GaMethod.block], rcx
    mov     rcx, [r14 + 8]
    mov     [r12 + GaMethod.block + 8], rcx
    mov     [r12 + GaMethod.block_len], rax
    mov     rcx, [rbx + GaClient.enc_gen]
    mov     [r12 + GaMethod.gen], rcx
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_field — one request field: indexed, or inserted. Internal.
;
; @param  rdi  GaClient*   @param rsi  destination cursor
; @param  rdx  the field's sequence slot (GaMethod.seq or a GaClient.*_seq)
; @param  ecx  static table index of the name: 4 :path, 1 :authority, 31
;              content-type; 0 = the literal name "te"
; @param  r8   value   @param r9  value length
; @returns rax = the cursor after the field; edx = 1 when the field changed
;          the table or is a literal (the block is not the steady form), else 0.
; @remarks Indexed when the slot's entry is still live: index = 62 + (newest
;          sequence - its sequence), which is where the server's decoder has
;          it. Otherwise a literal with incremental indexing on the static
;          name, and the entry's new sequence goes into the slot. An entry
;          too large for the table (32 + name + value > enc_max: only with a
;          tiny server table) is sent without indexing, and the slot is
;          cleared.
; =============================================================================
gc_field:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; [0] the entry's accounted size; aligned
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14d, ecx
    mov     r15, r8
    mov     rbp, r9
    mov     rax, [r13]
    test    rax, rax
    jz      .literal
    cmp     rax, [rbx + GaClient.enc_old]
    jb      .literal                    ; evicted since
    mov     rsi, [rbx + GaClient.enc_seq]
    sub     rsi, rax
    add     rsi, 62
    mov     rdi, r12
    mov     edx, 7
    mov     ecx, 0x80
    call    gc_put_int
    xor     edx, edx
    jmp     .out
.literal:
    ; Accounted size (RFC 7541 §4.1): 32 + name length + value length.
    mov     eax, 2                      ; "te"
    cmp     r14d, 4
    jne     .not_path
    mov     eax, 5                      ; ":path"
    jmp     .size
.not_path:
    cmp     r14d, 1
    jne     .not_authority
    mov     eax, 10                     ; ":authority"
    jmp     .size
.not_authority:
    cmp     r14d, 31
    jne     .size
    mov     eax, 12                     ; "content-type"
.size:
    lea     rsi, [rbp + rax + HPACK_ENTRY_OVERHEAD]
    mov     [rsp], rsi
    cmp     rsi, [rbx + GaClient.enc_max]
    ja      .unindexed
    test    r14d, r14d
    jz      .inc_te
    mov     rdi, r12
    mov     esi, r14d
    mov     edx, 6
    mov     ecx, 0x40                   ; 01xxxxxx: literal with incremental indexing
    call    gc_put_int
    jmp     .inc_value
.inc_te:
    mov     byte [r12], 0x40            ; new name
    lea     rdi, [r12 + 1]
    lea     rsi, [s_te]
    mov     edx, 2
    call    gc_put_str
.inc_value:
    mov     rdi, rax
    mov     rsi, r15
    mov     rdx, rbp
    call    gc_put_str
    mov     r12, rax
    mov     rdi, rbx
    mov     rsi, [rsp]
    call    gc_enc_insert
    mov     [r13], rax                  ; the entry's sequence (0: not stored)
    mov     rax, r12
    mov     edx, 1
    jmp     .out
.unindexed:
    test    r14d, r14d
    jz      .un_te
    mov     rdi, r12
    mov     esi, r14d
    mov     edx, 4
    xor     ecx, ecx                    ; 0000xxxx: literal without indexing
    call    gc_put_int
    jmp     .un_value
.un_te:
    mov     byte [r12], 0
    lea     rdi, [r12 + 1]
    lea     rsi, [s_te]
    mov     edx, 2
    call    gc_put_str
.un_value:
    mov     rdi, rax
    mov     rsi, r15
    mov     rdx, rbp
    call    gc_put_str
    mov     qword [r13], 0
    mov     edx, 1
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_put_int — an HPACK integer with an N-bit prefix (RFC 7541 §5.1).
; Internal, leaf.
; @param  rdi  destination   @param rsi  value
; @param  edx  N (4..7)      @param ecx  the first byte's high bits
; @returns rax = the byte after the integer. Clobbers rcx, rsi, rdi, r8.
; =============================================================================
gc_put_int:
    mov     r8d, ecx
    mov     ecx, edx
    mov     eax, 1
    shl     eax, cl
    dec     eax                         ; 2^N - 1
    cmp     rsi, rax
    jae     .long
    or      r8d, esi
    mov     [rdi], r8b
    lea     rax, [rdi + 1]
    ret
.long:
    or      r8d, eax
    mov     [rdi], r8b
    inc     rdi
    sub     rsi, rax
.more:
    cmp     rsi, 128
    jb      .last
    mov     eax, esi
    or      al, 0x80                    ; 7 bits and "more follows"
    mov     [rdi], al
    inc     rdi
    shr     rsi, 7
    jmp     .more
.last:
    mov     [rdi], sil
    lea     rax, [rdi + 1]
    ret

; =============================================================================
; gc_put_str — an HPACK string literal, raw (RFC 7541 §5.2). Internal.
; @param  rdi  destination   @param rsi  bytes   @param rdx  length
; @returns rax = the byte after the string.
; @remarks Never Huffman-coded: a request's literals go out once per
;          connection (then they are indexed), so the coding would save a
;          few bytes once and cost a table walk.
; =============================================================================
gc_put_str:
    push    rbx
    push    r12
    push    r13                         ; 3 pushes: aligned
    mov     r12, rsi
    mov     r13, rdx
    mov     rsi, rdx
    mov     edx, 7
    xor     ecx, ecx
    call    gc_put_int
    mov     rbx, rax
    mov     rdi, rax
    mov     rsi, r12
    mov     rdx, r13
    call    memcpy wrt ..plt
    lea     rax, [rbx + r13]
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; gc_enc_insert — record an entry the server's decoder inserts. Internal, leaf.
; @param  rdi  GaClient*   @param rsi  its accounted size (32 + name + value)
; @returns rax = the entry's sequence, or 0 when it is larger than the table
;          (which empties it, RFC 7541 §4.4).
; @remarks Evicts the oldest entries until the new one fits — exactly what
;          the decoder does — and moves the generation, which retires every
;          cached block (their indices may have shifted).
; =============================================================================
gc_enc_insert:
    inc     qword [rdi + GaClient.enc_gen]
    cmp     rsi, [rdi + GaClient.enc_max]
    jbe     .evict
    mov     rax, [rdi + GaClient.enc_seq]
    inc     rax
    mov     [rdi + GaClient.enc_old], rax
    mov     qword [rdi + GaClient.enc_size], 0
    xor     eax, eax
    ret
.evict:
    mov     rax, [rdi + GaClient.enc_size]
    add     rax, rsi
    cmp     rax, [rdi + GaClient.enc_max]
    jbe     .add
    mov     rcx, [rdi + GaClient.enc_old]
    and     ecx, GC_ENC_RING - 1
    movzx   eax, word [rdi + GaClient.enc_sizes + rcx*2]
    sub     [rdi + GaClient.enc_size], rax
    inc     qword [rdi + GaClient.enc_old]
    jmp     .evict
.add:
    mov     rax, [rdi + GaClient.enc_seq]
    inc     rax
    mov     [rdi + GaClient.enc_seq], rax
    mov     ecx, eax
    and     ecx, GC_ENC_RING - 1
    mov     [rdi + GaClient.enc_sizes + rcx*2], si
    add     [rdi + GaClient.enc_size], rsi
    ret

; =============================================================================
; gc_enc_set_max — the server's SETTINGS_HEADER_TABLE_SIZE changed.
; Internal, leaf.
; @param  rdi  GaClient*   @param rsi  the server's new decoder limit
; @returns nothing.
; @remarks The encoder uses min(limit, GC_ENC_MAX). When that changes, entries
;          are evicted to fit, cached blocks retire, and the next header block
;          announces the size (GCF_TSU, keeping the smallest value seen since
;          the last block, RFC 7541 §4.2).
; =============================================================================
gc_enc_set_max:
    mov     eax, GC_ENC_MAX
    cmp     rsi, rax
    cmova   rsi, rax
    cmp     rsi, [rdi + GaClient.enc_max]
    je      .ret
    mov     [rdi + GaClient.enc_max], rsi
.evict:
    cmp     [rdi + GaClient.enc_size], rsi
    jbe     .evicted
    mov     rcx, [rdi + GaClient.enc_old]
    and     ecx, GC_ENC_RING - 1
    movzx   eax, word [rdi + GaClient.enc_sizes + rcx*2]
    sub     [rdi + GaClient.enc_size], rax
    inc     qword [rdi + GaClient.enc_old]
    jmp     .evict
.evicted:
    inc     qword [rdi + GaClient.enc_gen]
    test    qword [rdi + GaClient.flags], GCF_TSU
    jz      .first
    cmp     rsi, [rdi + GaClient.enc_tsu_min]
    jae     .ret
.first:
    mov     [rdi + GaClient.enc_tsu_min], rsi
    or      qword [rdi + GaClient.flags], GCF_TSU
.ret:
    ret

; =============================================================================
; ga_client_input — process bytes received from the server (bytes mode; the
; socket layer uses the same path).
;
; @param  rdi  GaClient*   @param rsi  bytes   @param rdx  length
; @returns rax = the number of calls completed (their callbacks ran), or
;          -EBUSY (called from a callback) or the connection's error when it
;          had already failed (nothing was processed).
; @remarks The bytes need not be whole frames: an incomplete frame is kept
;          and finished by the next input. They are only read during this
;          call. Afterwards the output may hold new bytes (SETTINGS and PING
;          acknowledgements, WINDOW_UPDATE, calls issued by callbacks,
;          requests the windows let through): send them.
;          A protocol violation by the server queues GOAWAY and fails every
;          call (INTERNAL): those completions are counted, and the next input
;          returns the error.
; =============================================================================
ga_client_input:
    push    rbx                         ; 1 push: aligned
    mov     rbx, rdi
    mov     rax, [rbx + GaClient.flags]
    test    eax, GCF_BUSY
    jnz     .busy
    test    eax, GCF_CLOSED
    jnz     .closed
    or      qword [rbx + GaClient.flags], GCF_BUSY
    mov     qword [rbx + GaClient.completed], 0
    call    gc_input_core               ; rdi, rsi, rdx as given
    and     qword [rbx + GaClient.flags], ~GCF_BUSY
    mov     rax, [rbx + GaClient.completed]
    pop     rbx
    ret
.busy:
    mov     rax, -EBUSY
    pop     rbx
    ret
.closed:
    mov     rax, [rbx + GaClient.error]
    pop     rbx
    ret

; =============================================================================
; gc_input_core — frames from one input, the carry first. Internal.
; @param  rdi  GaClient*   @param rsi  bytes   @param rdx  length
; @returns nothing (failures close the client: GCF_CLOSED, calls completed).
; @remarks Order matters:
;          1. a frame carried from the last input is completed from these
;             bytes and run from the carry buffer;
;          2. the whole frames of these bytes run in place;
;          3. responses still borrowing input bytes (the carry's or these)
;             are copied out — before step 4 reuses the carry buffer;
;          4. a trailing incomplete frame is carried (at most one frame:
;             gc_frames refuses oversized ones before waiting for them);
;          5. the connection window is topped up, and gc_pump moves pending
;             requests and queued calls.
; =============================================================================
gc_input_core:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; aligned
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    xor     r14d, r14d                  ; leftover length (step 4)
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jnz     .out
    mov     rbp, [rbx + GaClient.carry_len]
    test    rbp, rbp
    jz      .main
    ; ---- 1. finish the carried frame ----
    cmp     rbp, FRAME_HDR
    jae     .have_hdr
    mov     r15, FRAME_HDR
    sub     r15, rbp
    cmp     r15, r13
    cmova   r15, r13
    mov     rdi, [rbx + GaClient.carry]
    add     rdi, rbp
    mov     rsi, r12
    mov     rdx, r15
    call    memcpy wrt ..plt
    add     rbp, r15
    add     r12, r15
    sub     r13, r15
    mov     [rbx + GaClient.carry_len], rbp
    cmp     rbp, FRAME_HDR
    jb      .out                        ; still no whole header: nothing else came
.have_hdr:
    mov     rax, [rbx + GaClient.carry]
    mov     eax, [rax]
    bswap   eax
    shr     eax, 8                      ; payload length
    cmp     eax, GC_FRAME_MAX
    ja      .frame_size
    lea     r15, [rax + FRAME_HDR]      ; the whole frame
    mov     rdx, r15
    sub     rdx, rbp
    cmp     rdx, r13
    cmova   rdx, r13
    test    rdx, rdx
    jz      .check
    mov     [rsp], rdx
    mov     rdi, [rbx + GaClient.carry]
    add     rdi, rbp
    mov     rsi, r12
    call    memcpy wrt ..plt
    mov     rdx, [rsp]
    add     rbp, rdx
    add     r12, rdx
    sub     r13, rdx
    mov     [rbx + GaClient.carry_len], rbp
.check:
    cmp     rbp, r15
    jb      .out                        ; the frame is still incomplete
    mov     qword [rbx + GaClient.carry_len], 0
    mov     rdi, rbx
    mov     rsi, [rbx + GaClient.carry]
    mov     rdx, r15
    call    gc_frames
    test    rax, rax
    js      .nomem
.main:
    ; ---- 2. this input's whole frames ----
    test    r13, r13
    jz      .fixup
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jnz     .fixup
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    call    gc_frames
    test    rax, rax
    js      .nomem
    add     r12, rax
    mov     r14, r13
    sub     r14, rax                    ; incomplete trailing frame
.fixup:
    ; ---- 3. borrowed responses ----
    mov     rdi, rbx
    call    gc_fixup_borrowed
    test    eax, eax
    js      .nomem
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jnz     .out
    ; ---- 4. the carry ----
    test    r14, r14
    jz      .after
    mov     rdi, [rbx + GaClient.carry]
    mov     rsi, r12
    mov     rdx, r14
    mov     [rbx + GaClient.carry_len], r14
    call    memcpy wrt ..plt
.after:
    ; ---- 5. windows and queues ----
    mov     rdi, rbx
    call    gc_after_input
    test    eax, eax
    js      .nomem
    jmp     .out
.frame_size:
    mov     rdi, rbx
    mov     esi, E_FRAME_SIZE
    call    gc_conn_error
    jmp     .out
.nomem:
    mov     rdi, rbx
    mov     rsi, -ENOMEM
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_oom]
    mov     r8d, m_oom_len
    call    gc_close
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_after_input — connection window top-up and gc_pump. Internal.
; @param  rdi  GaClient*
; @returns eax = 0, or -1 when out of memory.
; @remarks Once more than half of the connection window is used, one
;          WINDOW_UPDATE restores all of it (the server's own strategy).
; =============================================================================
gc_after_input:
    push    rbx                         ; 1 push: aligned
    mov     rbx, rdi
    xor     eax, eax
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jnz     .out
    mov     rax, [rbx + GaClient.recv_window]
    cmp     rax, GC_WINDOW / 2
    jge     .pump
    mov     edx, GC_WINDOW
    sub     rdx, rax
    mov     qword [rbx + GaClient.recv_window], GC_WINDOW
    mov     rdi, rbx
    xor     esi, esi
    call    gc_send_window
    test    eax, eax
    js      .out
.pump:
    mov     rdi, rbx
    call    gc_pump
.out:
    pop     rbx
    ret

; =============================================================================
; gc_fixup_borrowed — copy out the responses that point into the input.
; Internal.
; @param  rdi  GaClient*
; @returns eax = 0, or -1 when out of memory (the caller closes the client).
; @remarks A response's first DATA frame is borrowed (GaCall.resp points into
;          the input) in the hope that its trailers arrive in the same input,
;          which is the case for small pipelined responses: then the callback
;          reads it in place and nothing is copied. Calls still incomplete at
;          the end of the input get their bytes copied here, once.
; =============================================================================
gc_fixup_borrowed:
    push    rbx
    push    rbp
    push    r12                         ; 3 pushes: aligned
    mov     rbx, rdi
.next:
    mov     rbp, [rbx + GaClient.borrowed]
    test    rbp, rbp
    jz      .done
    mov     rax, [rbp + GaCall.bnext]
    mov     [rbx + GaClient.borrowed], rax
    and     qword [rbp + GaCall.flags], ~GCC_BORROWED
    mov     rdi, [rbp + GaCall.resp_len]
    lea     rsi, [rbx + GaClient.pool]
    call    ga_pool_malloc wrt ..plt
    test    rax, rax
    jz      .nomem
    mov     r12, rax
    mov     rdi, rax
    mov     rsi, [rbp + GaCall.resp]
    mov     rdx, [rbp + GaCall.resp_len]
    call    memcpy wrt ..plt
    mov     [rbp + GaCall.resp], r12
    mov     rax, [rbp + GaCall.resp_len]
    mov     [rbp + GaCall.resp_cap], rax
    jmp     .next
.nomem:
    ; This call's bytes are lost; its completion (from gc_close) does not
    ; read them: a failed call is handed no response.
    mov     qword [rbp + GaCall.resp], 0
    mov     qword [rbp + GaCall.resp_len], 0
    mov     eax, -1
    jmp     .out
.done:
    xor     eax, eax
.out:
    pop     r12
    pop     rbp
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; LOOKUP dst, sid — dst = the open call holding stream `sid` (a 64-bit
; register), or 0. Expects rbx = GaClient*. Clobbers rax, rcx.
; One load and one compare: a slot holds at most one call, and a slot whose
; call has another id means this stream has finished (or was skipped).
; -----------------------------------------------------------------------------
%macro LOOKUP 2
    mov     rax, %2
    shr     rax, 1
    and     rax, [rbx + GaClient.ring_mask]
    mov     rcx, [rbx + GaClient.calls]
    mov     %1, [rcx + rax*8]
    test    %1, %1
    jz      %%done
    cmp     [%1 + GaCall.id], %2
    je      %%done
    xor     %1, %1
%%done:
%endmacro

; =============================================================================
; gc_frames — run every whole frame of a buffer. Internal.
;
; @param  rdi  GaClient*   @param rsi  bytes   @param rdx  length
; @returns rax = bytes consumed (whole frames; the rest is an incomplete
;          frame for the carry), or -1 when out of memory.
; @remarks Registers across the loop: rbx client, r12 frame start, r13 end,
;          r14 payload, r15 payload length, rbp the frame's call in handlers.
;          A connection error (gc_conn_error) closes the client and stops the
;          loop; everything left is reported consumed (it is dropped).
;          Callbacks run inside this loop (completions): they may issue calls,
;          which only append to the output and the ring — nothing this loop
;          holds a pointer into.
; =============================================================================
%define L_FLAGS     0
%define L_SID       8
%define L_TYPE      16
%define L_T0        24
%define L_T1        32
%define L_BASE      40
gc_frames:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56                     ; 6 pushes + 56: aligned
    mov     rbx, rdi
    mov     r12, rsi
    lea     r13, [rsi + rdx]
    mov     [rsp + L_BASE], rsi
.frame:
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jnz     .all
    mov     rax, r13
    sub     rax, r12
    cmp     rax, FRAME_HDR
    jb      .partial
    mov     eax, [r12]
    bswap   eax                         ; length(24) | type(8)
    movzx   edx, al
    shr     eax, 8
    mov     r15, rax
    mov     [rsp + L_TYPE], rdx
    movzx   ecx, byte [r12 + 4]
    mov     [rsp + L_FLAGS], rcx
    mov     ecx, [r12 + 5]
    bswap   ecx
    and     ecx, MAX_STREAM_ID          ; the reserved bit is ignored (§4.1)
    mov     [rsp + L_SID], rcx
    ; Larger than our SETTINGS_MAX_FRAME_SIZE (the default): checked before
    ; waiting for the payload, so nothing oversized is ever carried (§4.2).
    cmp     r15, GC_FRAME_MAX
    ja      .frame_size_error
    lea     rcx, [r15 + FRAME_HDR]
    mov     rax, r13
    sub     rax, r12
    cmp     rax, rcx
    jb      .partial
    lea     r14, [r12 + FRAME_HDR]
    ; The server's preface is a SETTINGS frame, first (§3.4).
    test    qword [rbx + GaClient.flags], GCF_SETTINGS
    jnz     .sequencing
    cmp     edx, FT_SETTINGS
    jne     .protocol_error
    test    byte [rsp + L_FLAGS], FF_ACK
    jnz     .protocol_error
.sequencing:
    ; Inside a header block only its CONTINUATION frames may come (§6.10).
    mov     rax, [rbx + GaClient.cont_id]
    test    rax, rax
    jz      .dispatch
    cmp     edx, FT_CONTINUATION
    jne     .protocol_error
    cmp     rax, [rsp + L_SID]
    jne     .protocol_error
    jmp     .f_continuation
.dispatch:
    ; Most frequent first: a unary response is HEADERS, DATA, HEADERS.
    cmp     edx, FT_HEADERS
    je      .f_headers
    cmp     edx, FT_DATA
    je      .f_data
    cmp     edx, FT_WINDOW_UPDATE
    je      .f_window
    cmp     edx, FT_SETTINGS
    je      .f_settings
    cmp     edx, FT_PING
    je      .f_ping
    cmp     edx, FT_RST_STREAM
    je      .f_rst
    cmp     edx, FT_GOAWAY
    je      .f_goaway
    cmp     edx, FT_PRIORITY
    je      .f_priority
    cmp     edx, FT_CONTINUATION
    je      .protocol_error             ; no header block is open
    cmp     edx, FT_PUSH_PROMISE
    je      .protocol_error             ; push is disabled (our ENABLE_PUSH 0, §8.4)
    ; Unknown frame types are ignored (§4.1, §5.5).
.next:
    lea     r12, [r14 + r15]
    jmp     .frame
.partial:
    mov     rax, r12
    sub     rax, [rsp + L_BASE]
    jmp     .out
.all:
    mov     rax, r13
    sub     rax, [rsp + L_BASE]
    jmp     .out
.protocol_error:
    mov     esi, E_PROTOCOL
    jmp     .conn_error
.frame_size_error:
    mov     esi, E_FRAME_SIZE
    jmp     .conn_error
.flow_error:
    mov     esi, E_FLOW_CONTROL
.conn_error:
    mov     rdi, rbx
    call    gc_conn_error
    jmp     .all
.fatal:
    mov     rax, -1
.out:
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

    ; ---------------------------------------------------------------- HEADERS
.f_headers:
    mov     ecx, [rsp + L_SID]
    test    ecx, ecx
    jz      .protocol_error             ; (§6.2)
    mov     rsi, r14
    mov     rdx, r15
    xor     r8d, r8d                    ; pad length
    test    byte [rsp + L_FLAGS], FF_PADDED
    jz      .h_unpadded
    test    rdx, rdx
    jz      .frame_size_error
    movzx   r8d, byte [rsi]
    inc     rsi
    dec     rdx
.h_unpadded:
    xor     r9d, r9d                    ; block flags
    test    byte [rsp + L_FLAGS], FF_PRIORITY
    jz      .h_no_priority
    cmp     rdx, 5
    jb      .frame_size_error
    mov     eax, [rsi]
    bswap   eax
    and     eax, MAX_STREAM_ID
    cmp     eax, ecx
    jne     .h_priority_ok
    mov     r9d, CONT_SELF_DEP          ; a stream error, after the block is decoded
.h_priority_ok:
    add     rsi, 5
    sub     rdx, 5
.h_no_priority:
    cmp     r8, rdx
    ja      .protocol_error             ; padding beyond the payload (§6.2)
    sub     rdx, r8
    movzx   eax, byte [rsp + L_FLAGS]
    and     eax, FF_END_STREAM
    or      r9d, eax
    test    byte [rsp + L_FLAGS], FF_END_HEADERS
    jz      .h_open_block
    mov     rdi, rbx
    mov     r8d, r9d
    mov     rcx, rdx
    mov     rdx, rsi
    mov     esi, [rsp + L_SID]
    call    gc_header_block
    test    eax, eax
    js      .fatal
    jmp     .next
.h_open_block:
    mov     [rbx + GaClient.cont_flags], r9
    xor     eax, eax
    mov     [rbx + GaClient.hb_len], rax
    mov     [rbx + GaClient.cont_count], rax
    mov     rdi, rbx
    call    gc_hb_append                ; rsi = fragment, rdx = length
    test    eax, eax
    js      .fatal
    jnz     .calm_error
    mov     rax, [rsp + L_SID]
    mov     [rbx + GaClient.cont_id], rax
    jmp     .next
.calm_error:
    mov     esi, E_ENHANCE_YOUR_CALM    ; a header block beyond our bounds
    jmp     .conn_error

    ; ----------------------------------------------------------- CONTINUATION
.f_continuation:
    inc     qword [rbx + GaClient.cont_count]
    cmp     qword [rbx + GaClient.cont_count], GC_MAX_CONTINUATION
    ja      .calm_error
    mov     rdi, rbx
    mov     rsi, r14
    mov     rdx, r15
    call    gc_hb_append
    test    eax, eax
    js      .fatal
    jnz     .calm_error
    test    byte [rsp + L_FLAGS], FF_END_HEADERS
    jz      .next
    mov     rdi, rbx
    mov     esi, [rbx + GaClient.cont_id]
    mov     rdx, [rbx + GaClient.hb_buf]
    mov     rcx, [rbx + GaClient.hb_len]
    mov     r8d, [rbx + GaClient.cont_flags]
    mov     qword [rbx + GaClient.cont_id], 0
    call    gc_header_block
    test    eax, eax
    js      .fatal
    jmp     .next

    ; ------------------------------------------------------------------- DATA
.f_data:
    mov     ecx, [rsp + L_SID]
    test    ecx, ecx
    jz      .protocol_error             ; (§6.1)
    mov     rsi, r14
    mov     rdx, r15
    test    byte [rsp + L_FLAGS], FF_PADDED
    jz      .d_unpadded
    test    r15, r15
    jz      .frame_size_error
    movzx   eax, byte [r14]
    cmp     rax, r15
    jae     .protocol_error             ; padding covers the payload (§6.1)
    inc     rsi
    lea     rdx, [r15 - 1]
    sub     rdx, rax
.d_unpadded:
    mov     [rsp + L_T0], rsi
    mov     [rsp + L_T1], rdx
    ; The whole payload, padding included, counts against the connection
    ; window, whatever the stream's state (§6.9).
    sub     [rbx + GaClient.recv_window], r15
    js      .flow_error
    mov     rdx, [rsp + L_SID]
    LOOKUP  rbp, rdx
    test    rbp, rbp
    jnz     .d_call
    mov     rax, [rsp + L_SID]
    test    eax, 1
    jz      .protocol_error             ; an even id: no such stream can exist
    cmp     rax, [rbx + GaClient.next_id]
    jae     .protocol_error             ; DATA on an idle stream (§5.1)
    jmp     .next                       ; a call we finished or cancelled: dropped
.d_call:
    sub     [rbp + GaCall.recv_window], r15
    js      .d_flow
    test    qword [rbp + GaCall.flags], GCC_HEADERS
    jz      .d_malformed                ; DATA before the response headers (§8.1)
    mov     rcx, [rsp + L_T1]
    test    rcx, rcx
    jz      .d_appended
    mov     rdi, rbx
    mov     rsi, rbp
    mov     rdx, [rsp + L_T0]
    call    gc_append
    test    eax, eax
    js      .fatal
    jnz     .next                       ; too large: the call is gone
.d_appended:
    test    byte [rsp + L_FLAGS], FF_END_STREAM
    jz      .next
    ; The stream ended on DATA: a gRPC response ends with trailers.
    mov     rdi, rbx
    mov     rsi, rbp
    call    gc_end_remote
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, GC_INTERNAL
    lea     rcx, [m_no_trailers]
    mov     r8d, m_no_trailers_len
    xor     r9d, r9d
    call    gc_complete
    jmp     .next
.d_flow:
    mov     edx, E_FLOW_CONTROL
    lea     rcx, [m_flow]
    mov     r8d, m_flow_len
    jmp     .d_stream_error
.d_malformed:
    mov     edx, E_PROTOCOL
    lea     rcx, [m_malformed]
    mov     r8d, m_malformed_len
.d_stream_error:
    mov     rdi, rbx
    mov     rsi, rbp
    movzx   r9d, byte [rsp + L_FLAGS]
    and     r9d, FF_END_STREAM          ; the server's side is closed if it said so
    call    gc_stream_error
    jmp     .next

    ; ---------------------------------------------------------- WINDOW_UPDATE
.f_window:
    cmp     r15, 4
    jne     .frame_size_error           ; (§6.9)
    mov     eax, [r14]
    bswap   eax
    and     eax, MAX_STREAM_ID          ; increment
    mov     [rsp + L_T0], rax
    mov     rdx, [rsp + L_SID]
    test    rdx, rdx
    jnz     .w_stream
    test    eax, eax
    jz      .protocol_error             ; zero increment on the connection
    add     rax, [rbx + GaClient.send_window]
    cmp     rax, MAX_WINDOW
    jg      .flow_error                 ; beyond 2^31 - 1 (§6.9.1)
    mov     [rbx + GaClient.send_window], rax
    jmp     .next                       ; gc_pump frames what waited
.w_stream:
    LOOKUP  rbp, rdx
    test    rbp, rbp
    jnz     .w_call
    mov     rax, [rsp + L_SID]
    test    eax, 1
    jz      .protocol_error
    cmp     rax, [rbx + GaClient.next_id]
    jae     .protocol_error             ; WINDOW_UPDATE on an idle stream (§5.1)
    jmp     .next                       ; a finished stream: ignored
.w_call:
    mov     rax, [rsp + L_T0]
    test    rax, rax
    jz      .w_zero
    add     rax, [rbp + GaCall.send_window]
    cmp     rax, MAX_WINDOW
    jg      .w_overflow
    mov     [rbp + GaCall.send_window], rax
    jmp     .next
.w_zero:
    mov     edx, E_PROTOCOL
    lea     rcx, [m_malformed]
    mov     r8d, m_malformed_len
    jmp     .w_stream_error
.w_overflow:
    mov     edx, E_FLOW_CONTROL
    lea     rcx, [m_flow]
    mov     r8d, m_flow_len
.w_stream_error:
    mov     rdi, rbx
    mov     rsi, rbp
    xor     r9d, r9d
    call    gc_stream_error
    jmp     .next

    ; --------------------------------------------------------------- SETTINGS
.f_settings:
    cmp     qword [rsp + L_SID], 0
    jne     .protocol_error             ; (§6.5)
    test    byte [rsp + L_FLAGS], FF_ACK
    jz      .s_new
    test    r15, r15
    jnz     .frame_size_error           ; an ACK carries nothing
    jmp     .next
.s_new:
    mov     rax, r15
    xor     edx, edx
    mov     ecx, 6
    div     rcx
    test    rdx, rdx
    jnz     .frame_size_error
    mov     rbp, r14                    ; entry cursor
.s_entry:
    lea     rax, [r14 + r15]
    cmp     rbp, rax
    jae     .s_done
    movzx   eax, word [rbp]
    xchg    al, ah                      ; identifier
    mov     ecx, [rbp + 2]
    bswap   ecx                         ; value
    add     rbp, 6
    cmp     eax, S_HEADER_TABLE_SIZE
    je      .s_table
    cmp     eax, S_ENABLE_PUSH
    je      .s_push
    cmp     eax, S_MAX_STREAMS
    je      .s_streams
    cmp     eax, S_INITIAL_WINDOW
    je      .s_window
    cmp     eax, S_MAX_FRAME_SIZE
    je      .s_frame
    cmp     eax, S_ENABLE_CONNECT
    je      .s_bool
    jmp     .s_entry                    ; unknown: ignored (§6.5.2)
.s_table:
    mov     rdi, rbx
    mov     esi, ecx
    call    gc_enc_set_max
    jmp     .s_entry
.s_push:
    test    ecx, ecx
    jnz     .protocol_error             ; a server may only say 0 (§6.5.2)
    jmp     .s_entry
.s_streams:
    mov     [rbx + GaClient.peer_streams], rcx
    jmp     .s_entry                    ; a raise lets gc_pump start queued calls
.s_bool:
    cmp     ecx, 1
    ja      .protocol_error
    jmp     .s_entry
.s_frame:
    cmp     ecx, GC_FRAME_MAX
    jb      .protocol_error
    cmp     ecx, FRAME_LIMIT
    ja      .protocol_error
    mov     [rbx + GaClient.peer_frame], rcx
    jmp     .s_entry
.s_window:
    cmp     ecx, MAX_WINDOW
    ja      .flow_error                 ; (§6.5.2)
    ; Every stream's send window moves by the difference (§6.9.2). Only the
    ; calls with request bytes still to send have a window that matters: the
    ; others never send again.
    mov     rax, rcx
    sub     rax, [rbx + GaClient.peer_window]
    mov     [rbx + GaClient.peer_window], rcx
    mov     rdx, [rbx + GaClient.pend_head]
.s_adjust:
    test    rdx, rdx
    jz      .s_entry
    mov     rcx, [rdx + GaCall.send_window]
    add     rcx, rax
    cmp     rcx, MAX_WINDOW
    jg      .flow_error
    mov     [rdx + GaCall.send_window], rcx
    mov     rdx, [rdx + GaCall.pend_next]
    jmp     .s_adjust
.s_done:
    or      qword [rbx + GaClient.flags], GCF_SETTINGS
    mov     rdi, rbx
    mov     esi, FT_SETTINGS
    mov     edx, FF_ACK
    xor     ecx, ecx
    xor     r8d, r8d
    xor     r9d, r9d
    call    gc_write_frame
    test    eax, eax
    js      .fatal
    jmp     .next

    ; ------------------------------------------------------------------- PING
.f_ping:
    cmp     qword [rsp + L_SID], 0
    jne     .protocol_error             ; (§6.7)
    cmp     r15, 8
    jne     .frame_size_error
    test    byte [rsp + L_FLAGS], FF_ACK
    jnz     .next
    mov     rdi, rbx
    mov     esi, FT_PING
    mov     edx, FF_ACK
    xor     ecx, ecx
    mov     r8, r14                     ; echo the opaque data
    mov     r9d, 8
    call    gc_write_frame
    test    eax, eax
    js      .fatal
    jmp     .next

    ; ------------------------------------------------------------- RST_STREAM
.f_rst:
    mov     rdx, [rsp + L_SID]
    test    rdx, rdx
    jz      .protocol_error             ; (§6.4)
    cmp     r15, 4
    jne     .frame_size_error
    LOOKUP  rbp, rdx
    test    rbp, rbp
    jnz     .r_call
    mov     rax, [rsp + L_SID]
    test    eax, 1
    jz      .protocol_error
    cmp     rax, [rbx + GaClient.next_id]
    jae     .protocol_error             ; RST_STREAM on an idle stream (§6.4)
    jmp     .next                       ; already finished
.r_call:
    ; gRPC's mapping (doc/PROTOCOL-HTTP2.md, "Errors"): REFUSED_STREAM means
    ; the call was not processed (UNAVAILABLE, safe to retry), CANCEL is
    ; CANCELLED, ENHANCE_YOUR_CALM RESOURCE_EXHAUSTED, INADEQUATE_SECURITY
    ; PERMISSION_DENIED, anything else INTERNAL.
    mov     eax, [r14]
    bswap   eax
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_refused]
    mov     r8d, m_refused_len
    cmp     eax, E_REFUSED_STREAM
    je      .r_complete
    mov     edx, GC_CANCELLED
    lea     rcx, [m_cancelled]
    mov     r8d, m_cancelled_len
    cmp     eax, E_CANCEL
    je      .r_complete
    lea     rcx, [m_reset]
    mov     r8d, m_reset_len
    mov     edx, GC_RESOURCE_EXHAUSTED
    cmp     eax, E_ENHANCE_YOUR_CALM
    je      .r_complete
    mov     edx, GC_PERMISSION_DENIED
    cmp     eax, E_INADEQUATE_SECURITY
    je      .r_complete
    mov     edx, GC_INTERNAL
.r_complete:
    mov     rdi, rbx
    mov     rsi, rbp
    xor     r9d, r9d
    call    gc_complete                 ; the stream is closed: nothing is sent back
    jmp     .next

    ; ----------------------------------------------------------------- GOAWAY
.f_goaway:
    cmp     qword [rsp + L_SID], 0
    jne     .protocol_error             ; (§6.8)
    cmp     r15, 8
    jb      .frame_size_error
    mov     eax, [r14]
    bswap   eax
    and     eax, MAX_STREAM_ID          ; the last stream the server processes
    mov     rdi, rbx
    mov     esi, eax
    call    gc_goaway
    jmp     .next

    ; --------------------------------------------------------------- PRIORITY
.f_priority:
    mov     rdx, [rsp + L_SID]
    test    rdx, rdx
    jz      .protocol_error             ; (§6.3)
    LOOKUP  rbp, rdx
    mov     eax, E_FRAME_SIZE
    cmp     r15, 5
    jne     .p_error
    mov     ecx, [r14]
    bswap   ecx
    and     ecx, MAX_STREAM_ID
    cmp     rcx, [rsp + L_SID]
    jne     .next                       ; advisory, unused (§5.3.2)
    mov     eax, E_PROTOCOL             ; a stream depending on itself (§5.3.1)
.p_error:
    test    rbp, rbp
    jz      .next                       ; not one of our open calls: nothing to reset
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, eax
    lea     rcx, [m_malformed]
    mov     r8d, m_malformed_len
    xor     r9d, r9d
    call    gc_stream_error
    jmp     .next

; =============================================================================
; gc_header_block — act on one complete response header block. Internal.
;
; @param  rdi  GaClient*   @param esi  stream id
; @param  rdx  block       @param rcx  length
; @param  r8d  END_STREAM | CONT_SELF_DEP
; @returns eax = 0 (handled errors included), or -1 when out of memory.
; @remarks Every block is decoded, even one for a finished call: the HPACK
;          table must follow every block the server encodes (RFC 7541 §4.3).
;          For an open call:
;            first block, :status 1xx   informational: skipped (END_STREAM on
;                                       it is malformed)
;            first block                the response headers: :status,
;                                       content-type; with END_STREAM it is a
;                                       Trailers-Only response, finished here
;            second block               trailers: END_STREAM required, no
;                                       pseudo-headers; finishes the call
;          A malformed block is a stream error: RST_STREAM(PROTOCOL_ERROR) and
;          INTERNAL. A block on a stream we never opened is a connection
;          error (servers open no streams, and push is off).
; =============================================================================
gc_header_block:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56                     ; [0..40) HdrCtx; 6 pushes + 56: aligned
    mov     rbx, rdi
    mov     r12d, esi                   ; zero-extended stream id
    mov     r13, rdx
    mov     r14, rcx
    mov     r15d, r8d
    LOOKUP  rbp, r12
    mov     [rsp + HdrCtx.client], rbx
    mov     qword [rsp + HdrCtx.status], 0
    mov     qword [rsp + HdrCtx.gstatus], -1
    mov     qword [rsp + HdrCtx.flags], 0
    mov     [rsp + HdrCtx.call], rbp
    test    rbp, rbp
    jz      .unknown
    test    qword [rbp + GaCall.flags], GCC_HEADERS
    jz      .decode
    mov     qword [rsp + HdrCtx.flags], HX_TRAILERS
    jmp     .decode
.unknown:
    test    r12d, 1
    jz      .idle
    cmp     r12, [rbx + GaClient.next_id]
    jae     .idle
.decode:
    lea     rdi, [rbx + GaClient.hpack]
    mov     rsi, r13
    mov     rdx, r14
    mov     rcx, rsp
    lea     r8, [gc_hdr_field]
    lea     r9, [rbx + GaClient.scratch]
    call    ga_hpack_decode wrt ..plt
    test    rax, rax
    jnz     .decode_error
    test    rbp, rbp
    jz      .done                       ; HPACK sync only
    test    r15d, CONT_SELF_DEP
    jnz     .malformed
    test    qword [rsp + HdrCtx.flags], HX_BAD
    jnz     .malformed
    test    qword [rbp + GaCall.flags], GCC_HEADERS
    jnz     .trailers
    ; ---- the response's header block (or Trailers-Only) ----
    test    qword [rsp + HdrCtx.flags], HX_STATUS
    jz      .malformed                  ; :status is mandatory (§8.3.2)
    mov     rax, [rsp + HdrCtx.status]
    cmp     rax, 100
    jb      .final
    cmp     rax, 199
    ja      .final
    test    r15d, FF_END_STREAM
    jnz     .malformed                  ; an informational response cannot end the stream
    jmp     .done
.final:
    mov     [rbp + GaCall.http_status], rax
    mov     ecx, GCC_HEADERS
    test    qword [rsp + HdrCtx.flags], HX_CT_OK
    jz      .flags
    or      ecx, GCC_CT_OK
.flags:
    or      [rbp + GaCall.flags], rcx
    mov     rax, [rsp + HdrCtx.gstatus]
    test    rax, rax
    js      .no_status
    mov     [rbp + GaCall.grpc_status], rax
.no_status:
    test    r15d, FF_END_STREAM
    jz      .done
    jmp     .finish
.trailers:
    test    r15d, FF_END_STREAM
    jz      .malformed                  ; trailers must end the stream (§8.1)
    mov     rax, [rsp + HdrCtx.gstatus]
    test    rax, rax
    js      .finish
    mov     [rbp + GaCall.grpc_status], rax
.finish:
    mov     rdi, rbx
    mov     rsi, rbp
    call    gc_end_remote
    mov     rdi, rbx
    mov     rsi, rbp
    call    gc_finish
    jmp     .done
.malformed:
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, E_PROTOCOL
    lea     rcx, [m_malformed]
    mov     r8d, m_malformed_len
    mov     r9d, r15d
    and     r9d, FF_END_STREAM
    call    gc_stream_error
    jmp     .done
.idle:
    mov     rdi, rbx
    mov     esi, E_PROTOCOL
    call    gc_conn_error
    jmp     .done
.decode_error:
    cmp     rax, HPACK_ERR_NOMEM
    je      .nomem
    mov     rdi, rbx
    mov     esi, E_COMPRESSION          ; our table no longer matches the server's
    call    gc_conn_error
    jmp     .done
.nomem:
    mov     eax, -1
    jmp     .out
.done:
    xor     eax, eax
.out:
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_hdr_field — ga_hpack_decode's handler for response fields. Internal.
;
; @param  rdi  HdrCtx*   @param rsi  name   @param rdx  name length
; @param  rcx  value     @param r8   value length   @param r9  meaning
; @returns eax = 0 always: problems are recorded in the context, so the
;          block is always decoded to its end (the table must stay in step).
; @remarks Acts on meanings (hpack.inc), not names: once the table is warm,
;          :status 200 is VC_OK and grpc-status is HF_GRPC_STATUS without a
;          string compare. Rules (RFC 9113 §8.3, §8.1.1): only :status among
;          the pseudo-headers, once, before every regular field and never in
;          trailers; no connection-specific fields; values without NUL, CR,
;          LF or edge whitespace. A grpc-message too long for the decoder's
;          scratch buffer is dropped (the status still counts); any other
;          oversized field is malformed.
; =============================================================================
gc_hdr_field:
    mov     r10, [rdi + HdrCtx.call]
    test    r10, r10
    jz      .ret                        ; HPACK sync only
    movzx   eax, r9b                    ; field code
    test    r9d, HF_OVERSIZE
    jnz     .oversize
    test    r9d, HF_VALUE_BAD
    jnz     .bad
    lea     r11d, [rax - 1]
    cmp     r11d, HF_PSEUDO_LAST - 1
    jbe     .pseudo                     ; codes 1..6
    or      qword [rdi + HdrCtx.flags], HX_REGULAR
    cmp     eax, HF_GRPC_STATUS
    je      .gstatus
    cmp     eax, HF_CONTENT_TYPE
    je      .ctype
    cmp     eax, HF_GRPC_MESSAGE
    je      gc_keep_message             ; tail call: copies the value, returns 0
    cmp     eax, HF_BAD_NAME
    je      .bad
    cmp     eax, HF_CONN_SPECIFIC
    je      .bad
    jmp     .ret
.oversize:
    cmp     eax, HF_GRPC_MESSAGE
    je      .ret
    jmp     .bad
.pseudo:
    test    qword [rdi + HdrCtx.flags], HX_TRAILERS | HX_REGULAR
    jnz     .bad
    cmp     eax, HF_STATUS
    jne     .bad                        ; a request pseudo-header, or an unknown one
    test    qword [rdi + HdrCtx.flags], HX_STATUS
    jnz     .bad                        ; twice
    or      qword [rdi + HdrCtx.flags], HX_STATUS
    mov     r11d, r9d
    shr     r11d, 8
    and     r11d, 0xFF                  ; value class
    cmp     r11d, VC_OK
    jne     .digits
    mov     qword [rdi + HdrCtx.status], 200
    jmp     .ret
.digits:
    cmp     r8, 3
    jne     .bad                        ; :status is exactly three digits
    xor     eax, eax
    xor     edx, edx
.digit:
    movzx   r11d, byte [rcx + rdx]
    sub     r11d, '0'
    cmp     r11d, 9
    ja      .bad
    imul    eax, eax, 10
    add     eax, r11d
    inc     edx
    cmp     edx, 3
    jb      .digit
    mov     [rdi + HdrCtx.status], rax
    jmp     .ret
.ctype:
    mov     r11d, r9d
    shr     r11d, 8
    and     r11d, 0xFF
    cmp     r11d, VC_OK
    jne     .ret
    or      qword [rdi + HdrCtx.flags], HX_CT_OK
    jmp     .ret
.gstatus:
    ; 1 to 3 decimal digits; anything else reads as UNKNOWN, as gRPC
    ; implementations do with a status they cannot parse.
    mov     qword [rdi + HdrCtx.gstatus], GC_UNKNOWN
    test    r8, r8
    jz      .ret
    cmp     r8, 3
    ja      .ret
    xor     eax, eax
    xor     edx, edx
.gdigit:
    movzx   r11d, byte [rcx + rdx]
    sub     r11d, '0'
    cmp     r11d, 9
    ja      .ret
    imul    eax, eax, 10
    add     eax, r11d
    inc     rdx
    cmp     rdx, r8
    jb      .gdigit
    mov     [rdi + HdrCtx.gstatus], rax
    jmp     .ret
.bad:
    or      qword [rdi + HdrCtx.flags], HX_BAD
.ret:
    xor     eax, eax
    ret

; =============================================================================
; gc_keep_message — copy a grpc-message value into its call. Internal; the
; tail of gc_hdr_field.
; @param  rdi  HdrCtx*   @param rcx  value   @param r8  value length
; @returns eax = 0.
; @remarks The value is valid only during the handler call, so it is copied
;          (pool). A second grpc-message replaces the first. Out of memory
;          drops the message, not the call.
; =============================================================================
gc_keep_message:
    push    rbx
    push    r12
    push    r13                         ; 3 pushes on the handler's entry: aligned
    mov     rbx, rdi
    mov     r12, rcx
    mov     r13, r8
    mov     r10, [rbx + HdrCtx.call]
    mov     rdi, [r10 + GaCall.msg]
    test    rdi, rdi
    jz      .alloc
    mov     rsi, [rbx + HdrCtx.client]
    lea     rsi, [rsi + GaClient.pool]
    call    ga_pool_free wrt ..plt
    mov     r10, [rbx + HdrCtx.call]
    mov     qword [r10 + GaCall.msg], 0
    mov     qword [r10 + GaCall.msg_len], 0
.alloc:
    test    r13, r13
    jz      .ret
    mov     rdi, r13
    mov     rsi, [rbx + HdrCtx.client]
    lea     rsi, [rsi + GaClient.pool]
    call    ga_pool_malloc wrt ..plt
    test    rax, rax
    jz      .ret
    mov     r10, [rbx + HdrCtx.call]
    mov     [r10 + GaCall.msg], rax
    mov     [r10 + GaCall.msg_len], r13
    mov     rdi, rax
    mov     rsi, r12
    mov     rdx, r13
    call    memcpy wrt ..plt
.ret:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; gc_append — add a DATA payload to a call's response. Internal.
; @param  rdi  GaClient*   @param rsi  GaCall*
; @param  rdx  payload     @param rcx  length (> 0)
; @returns eax = 0, 1 (the response passed max_response: the stream is reset
;          with CANCEL and the call completed RESOURCE_EXHAUSTED — it is
;          gone), or -1 when out of memory.
; @remarks The first payload is borrowed (see gc_fixup_borrowed). A second
;          one in the same input copies both into an owned buffer; later ones
;          append, the buffer doubling up to the limit.
; =============================================================================
gc_append:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; aligned
    mov     rbx, rdi
    mov     rbp, rsi
    mov     r12, rdx
    mov     r13, rcx
    mov     r14, [rbp + GaCall.resp_len]
    add     r14, r13                    ; the new length
    mov     r15, [rbx + GaClient.max_response]
    add     r15, GRPC_PREFIX            ; the most a response may carry
    cmp     r14, r15
    ja      .too_large
    mov     rax, [rbp + GaCall.resp_cap]
    test    rax, rax
    jnz     .owned
    test    qword [rbp + GaCall.flags], GCC_BORROWED
    jnz     .own
    ; The first bytes: borrowed.
    mov     [rbp + GaCall.resp], r12
    mov     [rbp + GaCall.resp_len], r13
    or      qword [rbp + GaCall.flags], GCC_BORROWED
    mov     rax, [rbx + GaClient.borrowed]
    mov     [rbp + GaCall.bnext], rax
    mov     [rbx + GaClient.borrowed], rbp
    xor     eax, eax
    jmp     .out
.own:
    mov     rdi, r14
    add     rdi, rdi
    cmp     rdi, r15
    cmova   rdi, r15                    ; capacity: twice the length, within the limit
    mov     [rsp], rdi
    lea     rsi, [rbx + GaClient.pool]
    call    ga_pool_malloc wrt ..plt
    test    rax, rax
    jz      .nomem
    mov     rsi, [rbp + GaCall.resp]    ; the borrowed bytes, before the pointer moves
    mov     rdx, [rbp + GaCall.resp_len]
    mov     [rbp + GaCall.resp], rax
    mov     rcx, [rsp]
    mov     [rbp + GaCall.resp_cap], rcx
    mov     rdi, rax
    call    memcpy wrt ..plt
    lea     rdi, [rbx + GaClient.borrowed]
    xor     esi, esi
    mov     edx, GaCall.bnext
    mov     rcx, rbp
    call    gc_unlink
    and     qword [rbp + GaCall.flags], ~GCC_BORROWED
    jmp     .copy
.owned:
    cmp     r14, rax
    jbe     .copy
    mov     rsi, r14
    add     rsi, rsi
    cmp     rsi, r15
    cmova   rsi, r15
    mov     [rsp], rsi
    mov     rdi, [rbp + GaCall.resp]
    lea     rdx, [rbx + GaClient.pool]
    call    ga_pool_realloc wrt ..plt
    test    rax, rax
    jz      .nomem
    mov     [rbp + GaCall.resp], rax
    mov     rcx, [rsp]
    mov     [rbp + GaCall.resp_cap], rcx
.copy:
    mov     rdi, [rbp + GaCall.resp]
    add     rdi, [rbp + GaCall.resp_len]
    mov     rsi, r12
    mov     rdx, r13
    call    memcpy wrt ..plt
    mov     [rbp + GaCall.resp_len], r14
    xor     eax, eax
    jmp     .out
.too_large:
    mov     rdi, rbx
    mov     esi, [rbp + GaCall.id]
    mov     edx, E_CANCEL               ; the server is still sending: stop it
    call    gc_send_rst
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, GC_RESOURCE_EXHAUSTED
    lea     rcx, [m_too_large]
    mov     r8d, m_too_large_len
    xor     r9d, r9d
    call    gc_complete
    mov     eax, 1
    jmp     .out
.nomem:
    mov     eax, -1
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_finish — the server ended a call's stream: decide its status, complete
; it. Internal.
; @param  rdi  GaClient*   @param rsi  GaCall* (GCC_HEADERS set)
; @returns nothing.
; @remarks In the order gRPC clients apply them:
;            :status other than 200    the HTTP mapping (400 INTERNAL, 401
;                                      UNAUTHENTICATED, 403 PERMISSION_DENIED,
;                                      404 UNIMPLEMENTED, 429/502/503/504
;                                      UNAVAILABLE, else UNKNOWN), message
;                                      "HTTP status NNN"
;            content-type not gRPC     INTERNAL
;            no grpc-status            INTERNAL
;            grpc-status not 0         that status, the grpc-message
;                                      percent-decoded, no response
;            grpc-status 0             the response must be exactly one
;                                      uncompressed message: then OK with it,
;                                      else INTERNAL
; =============================================================================
gc_finish:
    push    rbx
    push    rbp
    push    r12
    sub     rsp, 32                     ; [0..16) "HTTP status NNN"; 3 pushes + 32: aligned
    mov     rbx, rdi
    mov     rbp, rsi
    mov     rax, [rbp + GaCall.http_status]
    cmp     rax, 200
    jne     .http
    test    qword [rbp + GaCall.flags], GCC_CT_OK
    jz      .ctype
    mov     rax, [rbp + GaCall.grpc_status]
    test    rax, rax
    js      .nostatus
    jnz     .status
    mov     rcx, [rbp + GaCall.resp_len]
    cmp     rcx, GRPC_PREFIX
    jb      .frame                      ; no message at all
    mov     rdx, [rbp + GaCall.resp]
    movzx   eax, byte [rdx]
    test    eax, eax
    jnz     .flagged
    mov     eax, [rdx + 1]
    bswap   eax
    add     rax, GRPC_PREFIX
    cmp     rax, rcx
    jne     .frame                      ; truncated, or more than one message
    lea     r9, [rdx + GRPC_PREFIX]
    mov     rdi, rbx
    mov     rsi, rbp
    xor     edx, edx                    ; OK
    xor     ecx, ecx
    xor     r8d, r8d
    call    gc_complete
    jmp     .out
.status:
    mov     r12d, eax
    mov     rdi, [rbp + GaCall.msg]
    mov     rsi, [rbp + GaCall.msg_len]
    call    gc_percent_decode
    mov     [rbp + GaCall.msg_len], rax
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, r12d
    mov     rcx, [rbp + GaCall.msg]
    mov     r8, rax
    xor     r9d, r9d
    call    gc_complete
    jmp     .out
.http:
    mov     edx, GC_INTERNAL
    cmp     rax, 400
    je      .http_msg
    mov     edx, GC_UNAUTHENTICATED
    cmp     rax, 401
    je      .http_msg
    mov     edx, GC_PERMISSION_DENIED
    cmp     rax, 403
    je      .http_msg
    mov     edx, GC_UNIMPLEMENTED
    cmp     rax, 404
    je      .http_msg
    mov     edx, GC_UNAVAILABLE
    cmp     rax, 429
    je      .http_msg
    cmp     rax, 502
    jb      .unknown
    cmp     rax, 504
    jbe     .http_msg
.unknown:
    mov     edx, GC_UNKNOWN
.http_msg:
    mov     r12d, edx
    ; "HTTP status " then the three digits.
    mov     rcx, [m_http]
    mov     [rsp], rcx
    mov     ecx, [m_http + 8]
    mov     [rsp + 8], ecx
    mov     ecx, 10
    xor     edx, edx
    div     rcx
    add     dl, '0'
    mov     [rsp + 14], dl
    xor     edx, edx
    div     rcx
    add     dl, '0'
    mov     [rsp + 13], dl
    xor     edx, edx
    div     rcx
    add     dl, '0'
    mov     [rsp + 12], dl
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, r12d
    mov     rcx, rsp
    mov     r8d, m_http_len + 3
    xor     r9d, r9d
    call    gc_complete
    jmp     .out
.flagged:
    cmp     eax, 1
    jne     .frame
    lea     rcx, [m_compressed]
    mov     r8d, m_compressed_len
    jmp     .internal
.ctype:
    lea     rcx, [m_ctype]
    mov     r8d, m_ctype_len
    jmp     .internal
.nostatus:
    lea     rcx, [m_nostatus]
    mov     r8d, m_nostatus_len
    jmp     .internal
.frame:
    lea     rcx, [m_frame]
    mov     r8d, m_frame_len
.internal:
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, GC_INTERNAL
    xor     r9d, r9d
    call    gc_complete
.out:
    add     rsp, 32
    pop     r12
    pop     rbp
    pop     rbx
    ret
%if m_http_len != 12
    %error "gc_finish copies the 12 bytes of m_http with two moves"
%endif

; =============================================================================
; gc_percent_decode — decode a grpc-message in place (gRPC: "%XX" escapes).
; Internal, leaf.
; @param  rdi  bytes (may be 0 when the length is 0)   @param rsi  length
; @returns rax = the decoded length. A '%' not followed by two hex digits is
;          kept as it is (lenient, as gRPC implementations are).
; =============================================================================
gc_percent_decode:
    xor     ecx, ecx                    ; read index
    xor     eax, eax                    ; write index
.next:
    cmp     rcx, rsi
    jae     .done
    movzx   edx, byte [rdi + rcx]
    cmp     edx, '%'
    jne     .copy
    lea     r8, [rcx + 2]
    cmp     r8, rsi
    jae     .copy
    movzx   r8d, byte [rdi + rcx + 1]
    call    .hex
    jc      .copy
    mov     r9d, r8d
    movzx   r8d, byte [rdi + rcx + 2]
    call    .hex
    jc      .copy
    shl     r9d, 4
    or      r9d, r8d
    mov     [rdi + rax], r9b
    inc     rax
    add     rcx, 3
    jmp     .next
.copy:
    mov     [rdi + rax], dl
    inc     rax
    inc     rcx
    jmp     .next
.done:
    ret
.hex:                                   ; r8d = a character -> its value, CF=1 if not hex
    sub     r8d, '0'
    cmp     r8d, 9
    jbe     .hex_ok
    or      r8d, 0x20                   ; (c - '0') | 0x20: 'A'..'F' and 'a'..'f' alike
    sub     r8d, 'a' - '0'
    cmp     r8d, 5
    ja      .hex_bad
    add     r8d, 10
.hex_ok:
    clc
    ret
.hex_bad:
    stc
    ret

; =============================================================================
; gc_complete — end a call: detach it, run its callback, free it. Internal.
;
; @param  rdi  GaClient*   @param rsi  GaCall*
; @param  edx  gRPC status
; @param  rcx  message (valid until the callback returns), or 0
; @param  r8   message length
; @param  r9   the response message (status 0: inside GaCall.resp, whose
;              length minus the 5-byte prefix is the message's), or 0
; @returns nothing.
; @remarks The call leaves every structure BEFORE its callback runs, so the
;          callback may issue calls that take its stream slot. Its buffers
;          are freed after the callback (the message and the response may
;          live in them). Counts the completion for the current input/poll.
; =============================================================================
gc_complete:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; aligned
    mov     rbx, rdi
    mov     rbp, rsi
    mov     r12d, edx
    mov     r13, rcx
    mov     r14, r8
    mov     r15, r9
    mov     rax, [rbp + GaCall.flags]
    test    eax, GCC_OPEN
    jz      .not_open
    mov     rcx, [rbp + GaCall.id]
    shr     rcx, 1
    and     rcx, [rbx + GaClient.ring_mask]
    mov     rdx, [rbx + GaClient.calls]
    mov     qword [rdx + rcx*8], 0
    dec     qword [rbx + GaClient.active]
.not_open:
    test    qword [rbp + GaCall.flags], GCC_PEND
    jz      .not_pend
    lea     rdi, [rbx + GaClient.pend_head]
    lea     rsi, [rbx + GaClient.pend_tail]
    mov     edx, GaCall.pend_next
    mov     rcx, rbp
    call    gc_unlink
.not_pend:
    test    qword [rbp + GaCall.flags], GCC_BORROWED
    jz      .not_borrowed
    lea     rdi, [rbx + GaClient.borrowed]
    xor     esi, esi
    mov     edx, GaCall.bnext
    mov     rcx, rbp
    call    gc_unlink
.not_borrowed:
    test    qword [rbp + GaCall.flags], GCC_QUEUED
    jz      .detached
    lea     rdi, [rbx + GaClient.queue_head]
    lea     rsi, [rbx + GaClient.queue_tail]
    mov     edx, GaCall.next
    mov     rcx, rbp
    call    gc_unlink
.detached:
    mov     qword [rbp + GaCall.flags], 0
    inc     qword [rbx + GaClient.completed]
    inc     qword [rbx + GaClient.st_calls]
    test    r12d, r12d
    jz      .callback
    inc     qword [rbx + GaClient.st_failed]
.callback:
    xor     r9d, r9d                    ; response length
    test    r15, r15
    jz      .call
    mov     r9, [rbp + GaCall.resp_len]
    sub     r9, GRPC_PREFIX
.call:
    mov     rdi, [rbp + GaCall.ctx]
    mov     esi, r12d
    mov     rdx, r13
    mov     rcx, r14
    mov     r8, r15
    call    [rbp + GaCall.done]
    lea     r12, [rbx + GaClient.pool]
    cmp     qword [rbp + GaCall.resp_cap], 0
    je      .no_resp
    mov     rdi, [rbp + GaCall.resp]
    mov     rsi, r12
    call    ga_pool_free wrt ..plt
.no_resp:
    mov     rdi, [rbp + GaCall.req]
    mov     rsi, r12
    call    ga_pool_free wrt ..plt
    mov     rdi, [rbp + GaCall.msg]
    mov     rsi, r12
    call    ga_pool_free wrt ..plt
    mov     rdi, rbp
    mov     rsi, r12
    call    ga_pool_free wrt ..plt
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_unlink — remove a call from a singly linked list. Internal, leaf.
; @param  rdi  the list's head pointer   @param rsi  its tail pointer, or 0
; @param  rdx  the link's offset in GaCall   @param rcx  the call
; @returns nothing (a call not on the list is left alone).
; @remarks A scan from the head: the lists are short, and the call removed is
;          nearly always the head (pipelined responses complete in order).
;          Clobbers rax, r8, r9.
; =============================================================================
gc_unlink:
    xor     r8d, r8d                    ; previous
    mov     rax, [rdi]
.scan:
    test    rax, rax
    jz      .ret
    cmp     rax, rcx
    je      .found
    mov     r8, rax
    mov     rax, [rax + rdx]
    jmp     .scan
.found:
    mov     r9, [rcx + rdx]
    test    r8, r8
    jz      .head
    mov     [r8 + rdx], r9
    jmp     .tail
.head:
    mov     [rdi], r9
.tail:
    test    rsi, rsi
    jz      .clear
    cmp     [rsi], rcx
    jne     .clear
    mov     [rsi], r8
.clear:
    mov     qword [rcx + rdx], 0
.ret:
    ret

; =============================================================================
; gc_end_remote — the server ended its side of a call's stream. Internal.
; @param  rdi  GaClient*   @param rsi  GaCall*
; @returns nothing.
; @remarks If our request is not fully sent (a server may answer early), the
;          rest is abandoned with RST_STREAM(CANCEL), which also closes our
;          side; a fully sent request needs nothing (the stream is closed).
;          Out of memory for the frame is ignored: the call ends either way.
; =============================================================================
gc_end_remote:
    mov     rax, [rsi + GaCall.req_len]
    add     rax, GRPC_PREFIX
    cmp     [rsi + GaCall.req_off], rax
    jae     .ret
    mov     esi, [rsi + GaCall.id]
    mov     edx, E_CANCEL
    jmp     gc_send_rst                 ; tail call
.ret:
    ret

; =============================================================================
; gc_stream_error — a stream error on a call: RST_STREAM, then INTERNAL.
; Internal.
; @param  rdi  GaClient*   @param rsi  GaCall*   @param edx  HTTP/2 error code
; @param  rcx  message     @param r8   its length
; @param  r9d  non-zero when the server already ended the stream
; @returns nothing.
; @remarks No RST_STREAM on a stream closed both ways (the server ended it
;          and our request is fully sent): frames on a closed stream are
;          forbidden (§5.1).
; =============================================================================
gc_stream_error:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14                         ; 5 pushes: aligned
    mov     rbx, rdi
    mov     rbp, rsi
    mov     r12d, edx
    mov     r13, rcx
    mov     r14, r8
    test    r9d, r9d
    jz      .rst
    mov     rax, [rbp + GaCall.req_len]
    add     rax, GRPC_PREFIX
    cmp     [rbp + GaCall.req_off], rax
    jae     .complete
.rst:
    mov     rdi, rbx
    mov     esi, [rbp + GaCall.id]
    mov     edx, r12d
    call    gc_send_rst
.complete:
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, GC_INTERNAL
    mov     rcx, r13
    mov     r8, r14
    xor     r9d, r9d
    call    gc_complete
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_goaway — the server sent GOAWAY. Internal.
; @param  rdi  GaClient*   @param esi  its last stream id
; @returns nothing.
; @remarks Calls above the last stream id were not processed (RFC 9113 §6.8):
;          they fail UNAVAILABLE (safe to retry elsewhere). So do the queued
;          ones, which can no longer get a stream. Calls up to the id
;          continue. New calls are refused (-ESHUTDOWN). A later GOAWAY may
;          lower the id further, never raise it.
; =============================================================================
gc_goaway:
    push    rbx
    push    rbp
    push    r12                         ; 3 pushes: aligned
    mov     rbx, rdi
    mov     r12d, esi
    test    qword [rbx + GaClient.flags], GCF_GOAWAY
    jz      .first
    cmp     r12, [rbx + GaClient.goaway_id]
    jae     .queue
.first:
    or      qword [rbx + GaClient.flags], GCF_GOAWAY
    mov     [rbx + GaClient.goaway_id], r12
    xor     ebp, ebp
.slot:
    cmp     rbp, [rbx + GaClient.ring_mask]
    ja      .queue
    mov     rax, [rbx + GaClient.calls]
    mov     rsi, [rax + rbp*8]
    test    rsi, rsi
    jz      .next
    cmp     [rsi + GaCall.id], r12
    jbe     .next
    mov     rdi, rbx
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_goaway]
    mov     r8d, m_goaway_len
    xor     r9d, r9d
    call    gc_complete
.next:
    inc     rbp
    jmp     .slot
.queue:
    mov     rsi, [rbx + GaClient.queue_head]
    test    rsi, rsi
    jz      .out
    mov     rdi, rbx
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_goaway]
    mov     r8d, m_goaway_len
    xor     r9d, r9d
    call    gc_complete
    jmp     .queue
.out:
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_close — the connection is over: refuse everything, fail every call.
; Internal.
; @param  rdi  GaClient*   @param rsi  the error new calls get (negative errno)
; @param  edx  the gRPC status calls complete with
; @param  rcx  message   @param r8  its length
; @returns nothing (a client already closed is left alone).
; @remarks GCF_CLOSED is set before the first callback, so a callback that
;          issues a call gets the error instead of a stream.
; =============================================================================
gc_close:
    test    qword [rdi + GaClient.flags], GCF_CLOSED
    jnz     .ret
    or      qword [rdi + GaClient.flags], GCF_CLOSED
    mov     [rdi + GaClient.error], rsi
    jmp     gc_fail_all                 ; tail call: rdi, edx, rcx, r8 as given
.ret:
    ret

; =============================================================================
; gc_fail_all — complete every open and queued call with one status.
; Internal.
; @param  rdi  GaClient*   @param edx  gRPC status
; @param  rcx  message     @param r8   its length
; @returns nothing.
; @remarks Callers set GCF_CLOSED first: nothing can join the ring or the
;          queue while it is walked.
; =============================================================================
gc_fail_all:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14                         ; 5 pushes: aligned
    mov     rbx, rdi
    mov     r12d, edx
    mov     r13, rcx
    mov     r14, r8
    xor     ebp, ebp
.slot:
    cmp     rbp, [rbx + GaClient.ring_mask]
    ja      .queue
    mov     rax, [rbx + GaClient.calls]
    mov     rsi, [rax + rbp*8]
    test    rsi, rsi
    jz      .next
    mov     rdi, rbx
    mov     edx, r12d
    mov     rcx, r13
    mov     r8, r14
    xor     r9d, r9d
    call    gc_complete
.next:
    inc     rbp
    jmp     .slot
.queue:
    mov     rsi, [rbx + GaClient.queue_head]
    test    rsi, rsi
    jz      .out
    mov     rdi, rbx
    mov     edx, r12d
    mov     rcx, r13
    mov     r8, r14
    xor     r9d, r9d
    call    gc_complete
    jmp     .queue
.out:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_conn_error — the server broke the protocol: GOAWAY, then close.
; Internal.
; @param  rdi  GaClient*   @param esi  HTTP/2 error code
; @returns nothing.
; @remarks GOAWAY(last stream id 0 — the server opened none — and the code)
;          is queued for the socket layer to flush; every call fails
;          INTERNAL; the client's error is -EPROTO.
; =============================================================================
gc_conn_error:
    push    rbx
    sub     rsp, 16                     ; [0..8) GOAWAY payload; 1 push + 16: aligned
    mov     rbx, rdi
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jnz     .out
    mov     dword [rsp], 0
    bswap   esi
    mov     [rsp + 4], esi
    mov     rdi, rbx
    mov     esi, FT_GOAWAY
    xor     edx, edx
    xor     ecx, ecx
    mov     r8, rsp
    mov     r9d, 8
    call    gc_write_frame              ; out of memory: closed all the same
    mov     rdi, rbx
    mov     rsi, -EPROTO
    mov     edx, GC_INTERNAL
    lea     rcx, [m_conn_error]
    mov     r8d, m_conn_error_len
    call    gc_close
.out:
    add     rsp, 16
    pop     rbx
    ret

; =============================================================================
; gc_hb_append — add a fragment to the header block being assembled.
; Internal.
; @param  rdi  GaClient*   @param rsi  fragment   @param rdx  length
; @returns eax = 0, 1 (the block would pass GC_MAX_BLOCK), -1 (out of memory).
; =============================================================================
gc_hb_append:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8                      ; 4 pushes + 8: aligned
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     rax, [rbx + GaClient.hb_len]
    add     rax, r13
    cmp     rax, GC_MAX_BLOCK
    ja      .too_big
    cmp     rax, [rbx + GaClient.hb_cap]
    jbe     .copy
    ; Grow: double (at least 1 KiB, at most GC_MAX_BLOCK). The capacity is
    ; recorded only once realloc succeeded: on failure the old buffer and its
    ; capacity stay exactly as they were.
    mov     rsi, [rbx + GaClient.hb_cap]
    add     rsi, rsi
    cmp     rsi, rax
    cmovb   rsi, rax
    mov     ecx, 1024
    cmp     rsi, rcx
    cmovb   rsi, rcx
    mov     ecx, GC_MAX_BLOCK
    cmp     rsi, rcx
    cmova   rsi, rcx
    mov     r14, rsi
    mov     rdi, [rbx + GaClient.hb_buf]
    call    realloc wrt ..plt
    test    rax, rax
    jz      .nomem
    mov     [rbx + GaClient.hb_buf], rax
    mov     [rbx + GaClient.hb_cap], r14
.copy:
    mov     rdi, [rbx + GaClient.hb_buf]
    add     rdi, [rbx + GaClient.hb_len]
    mov     rsi, r12
    mov     rdx, r13
    call    memcpy wrt ..plt
    add     [rbx + GaClient.hb_len], r13
    xor     eax, eax
    jmp     .out
.too_big:
    mov     eax, 1
    jmp     .out
.nomem:
    mov     eax, -1
.out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; gc_out_reserve — n bytes at the end of the output. Internal.
; @param  rdi  GaClient*   @param rsi  n
; @returns rax = pointer to the n bytes (out_len already past them), or 0
;          when the buffer cannot grow (nothing changed).
; @remarks Sent bytes at the front (out_off) are dropped before the buffer
;          grows: a socket that takes output slowly keeps the buffer the size
;          of what is unsent, not of everything ever queued. Callers that
;          reserve generously set out_len back to their real end.
; =============================================================================
gc_out_reserve:
    mov     rax, [rdi + GaClient.out_len]
    lea     rdx, [rax + rsi]
    cmp     rdx, [rdi + GaClient.out_cap]
    ja      .slow
    mov     [rdi + GaClient.out_len], rdx
    add     rax, [rdi + GaClient.out_buf]
    ret
.slow:
    push    rbx
    push    r12
    push    r13                         ; 3 pushes: aligned
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdx, [rbx + GaClient.out_off]
    test    rdx, rdx
    jz      .grow
    ; Drop the sent front, then try again.
    mov     rdi, [rbx + GaClient.out_buf]
    lea     rsi, [rdi + rdx]
    mov     rdx, [rbx + GaClient.out_len]
    sub     rdx, [rbx + GaClient.out_off]
    mov     [rbx + GaClient.out_len], rdx
    mov     qword [rbx + GaClient.out_off], 0
    call    memmove wrt ..plt
    mov     rax, [rbx + GaClient.out_len]
    lea     rdx, [rax + r12]
    cmp     rdx, [rbx + GaClient.out_cap]
    ja      .grow
    mov     [rbx + GaClient.out_len], rdx
    add     rax, [rbx + GaClient.out_buf]
    jmp     .out
.grow:
    mov     r13, [rbx + GaClient.out_len]
    add     r13, r12                    ; needed
    mov     rsi, [rbx + GaClient.out_cap]
    add     rsi, rsi
    cmp     rsi, r13
    cmovb   rsi, r13
    mov     r12, rsi                    ; new capacity
    mov     rdi, [rbx + GaClient.out_buf]
    call    realloc wrt ..plt
    test    rax, rax
    jz      .out                        ; the old buffer is still valid and owned
    mov     [rbx + GaClient.out_buf], rax
    mov     [rbx + GaClient.out_cap], r12
    mov     rcx, [rbx + GaClient.out_len]
    mov     [rbx + GaClient.out_len], r13
    add     rax, rcx
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; gc_put_hdr — write a 9-byte frame header. Internal, leaf.
; @param  rdi  destination   @param esi  payload length (< 2^24)
; @param  edx  type   @param ecx  flags   @param r8d  stream id
; @returns nothing. Clobbers rax, rdx, r8.
; =============================================================================
gc_put_hdr:
    mov     eax, esi
    shl     eax, 8
    bswap   eax                         ; length big-endian in the low 3 bytes...
    shl     edx, 24
    or      eax, edx                    ; ...then the type
    mov     [rdi], eax
    mov     [rdi + 4], cl
    bswap   r8d
    mov     [rdi + 5], r8d
    ret

; =============================================================================
; gc_write_frame — append one complete frame to the output. Internal.
; @param  rdi  GaClient*   @param esi  type   @param edx  flags
; @param  ecx  stream id   @param r8  payload   @param r9  payload length
; @returns eax = 0, or -1 when out of memory.
; =============================================================================
gc_write_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; [0] frame start; aligned
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     rbp, r8
    mov     r15, r9
    lea     rsi, [r9 + FRAME_HDR]
    call    gc_out_reserve
    test    rax, rax
    jz      .nomem
    mov     [rsp], rax
    mov     rdi, rax
    mov     esi, r15d
    mov     edx, r12d
    mov     ecx, r13d
    mov     r8d, r14d
    call    gc_put_hdr
    test    r15, r15
    jz      .ok
    mov     rdi, [rsp]
    add     rdi, FRAME_HDR
    mov     rsi, rbp
    mov     rdx, r15
    call    memcpy wrt ..plt
.ok:
    xor     eax, eax
    jmp     .out
.nomem:
    mov     eax, -1
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_send_rst / gc_send_window — small control frames. Internal.
; gc_send_rst:    @param rdi GaClient*  @param esi stream id  @param edx code
; gc_send_window: @param rdi GaClient*  @param esi stream id (0 = connection)
;                 @param edx increment (1 .. 2^31 - 1)
; @returns eax = 0, or -1 when out of memory.
; =============================================================================
gc_send_rst:
    sub     rsp, 24                     ; [0..4) payload; aligned
    bswap   edx
    mov     [rsp], edx
    mov     ecx, esi
    mov     esi, FT_RST_STREAM
    xor     edx, edx
    mov     r8, rsp
    mov     r9d, 4
    call    gc_write_frame
    add     rsp, 24
    ret

gc_send_window:
    sub     rsp, 24                     ; [0..4) payload; aligned
    bswap   edx
    mov     [rsp], edx
    mov     ecx, esi
    mov     esi, FT_WINDOW_UPDATE
    xor     edx, edx
    mov     r8, rsp
    mov     r9d, 4
    call    gc_write_frame
    add     rsp, 24
    ret

; =============================================================================
; ga_client_output — the bytes waiting to be sent (bytes mode).
; @param  rdi  GaClient*
; @returns rax = pointer to them, rdx = their number (0: nothing to send).
; @remarks Valid until the next call into the client. After sending some of
;          them, report how many with ga_client_consume.
; =============================================================================
ga_client_output:
    mov     rax, [rdi + GaClient.out_buf]
    mov     rcx, [rdi + GaClient.out_off]
    add     rax, rcx
    mov     rdx, [rdi + GaClient.out_len]
    sub     rdx, rcx
    ret

; =============================================================================
; ga_client_consume — n bytes of the output were sent (bytes mode).
; @param  rdi  GaClient*   @param rsi  n (more than is waiting counts as all)
; @returns nothing.
; =============================================================================
ga_client_consume:
    mov     rax, [rdi + GaClient.out_len]
    sub     rax, [rdi + GaClient.out_off]
    cmp     rsi, rax
    jae     .all
    add     [rdi + GaClient.out_off], rsi
    ret
.all:
    xor     eax, eax
    mov     [rdi + GaClient.out_len], rax
    mov     [rdi + GaClient.out_off], rax
    ret

; =============================================================================
; ga_client_fd — the client's socket (socket mode), for an event loop.
; @param  rdi  GaClient*
; @returns eax = the file descriptor, or -1 for a bytes-mode client.
; =============================================================================
ga_client_fd:
    mov     rax, [rdi + GaClient.fd]
    ret

; =============================================================================
; ga_client_flush — send queued output (socket mode).
; @param  rdi  GaClient*
; @returns eax = 0 (everything sent), 1 (the socket is full: wait until it is
;          writable, POLLOUT), -EBADF (bytes mode), or the error that ended
;          the connection (its calls then completed UNAVAILABLE, possibly
;          during this call).
; =============================================================================
ga_client_flush:
    cmp     qword [rdi + GaClient.fd], 0
    jl      .ebadf
    jmp     gc_flush                    ; tail call
.ebadf:
    mov     eax, -EBADF
    ret

; =============================================================================
; gc_flush — ga_client_flush's body. Internal.
; @param  rdi  GaClient* (socket mode)
; @returns eax as ga_client_flush.
; @remarks A send error (the server reset the connection) closes the client:
;          its calls complete UNAVAILABLE "connection lost" right here.
;          Output queued after a close (the final GOAWAY) is still offered.
; =============================================================================
gc_flush:
    push    rbx                         ; 1 push: aligned
    mov     rbx, rdi
.send:
    mov     rdx, [rbx + GaClient.out_len]
    mov     rax, [rbx + GaClient.out_off]
    sub     rdx, rax
    jz      .empty
    mov     rdi, [rbx + GaClient.fd]
    mov     rsi, [rbx + GaClient.out_buf]
    add     rsi, rax
    mov     r10d, MSG_NOSIGNAL
    xor     r8d, r8d
    xor     r9d, r9d
    mov     eax, SYS_sendto
    syscall
    cmp     rax, -EINTR
    je      .send
    cmp     rax, -EAGAIN
    je      .full
    test    rax, rax
    js      .lost
    add     [rbx + GaClient.out_off], rax
    jmp     .send
.empty:
    xor     eax, eax
    mov     [rbx + GaClient.out_len], rax
    mov     [rbx + GaClient.out_off], rax
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jz      .out
    mov     rax, [rbx + GaClient.error]
    jmp     .out
.full:
    mov     eax, 1
    jmp     .out
.lost:
    xor     ecx, ecx                    ; what was queued cannot leave any more
    mov     [rbx + GaClient.out_len], rcx
    mov     [rbx + GaClient.out_off], rcx
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jnz     .closed
    mov     rdi, rbx
    mov     rsi, rax
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_lost]
    mov     r8d, m_lost_len
    call    gc_close
.closed:
    mov     rax, [rbx + GaClient.error]
.out:
    pop     rbx
    ret

; =============================================================================
; ga_client_poll — wait for the server, process what it sent, send what is
; queued (socket mode).
;
; @param  rdi  GaClient*
; @param  esi  timeout in milliseconds: 0 = do not wait, -1 = no limit
; @returns rax = calls completed during this call (their callbacks ran;
;          0 after a timeout), or -EBUSY (from a callback), -EBADF (bytes
;          mode), or the connection's error once it is closed and nothing
;          completed.
; @remarks One poll(2), then reads until the socket is drained (at most 8
;          reads of GC_READ_CHUNK, so one busy connection cannot keep the
;          caller forever), then one flush — callbacks that issued calls see
;          them sent in that same flush. The server closing the connection
;          completes every call UNAVAILABLE.
; =============================================================================
ga_client_poll:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    sub     rsp, 16                     ; [0..8) struct pollfd; 5 pushes + 16: aligned
    mov     rbx, rdi
    mov     r12d, esi
    mov     rax, [rbx + GaClient.flags]
    test    eax, GCF_BUSY
    jnz     .busy
    test    eax, GCF_CLOSED
    jnz     .closed
    cmp     qword [rbx + GaClient.fd], 0
    jl      .ebadf
    or      qword [rbx + GaClient.flags], GCF_BUSY
    mov     qword [rbx + GaClient.completed], 0
    mov     rdi, rbx
    call    gc_flush
    test    eax, eax
    js      .done
    mov     ecx, POLLIN
    test    eax, eax
    jz      .events
    or      ecx, POLLOUT                ; output still waits for room
.events:
    mov     eax, [rbx + GaClient.fd]
    mov     [rsp], eax
    mov     [rsp + 4], cx
    mov     word [rsp + 6], 0
    mov     rdi, rsp
    mov     esi, 1
    movsxd  rdx, r12d
    mov     eax, SYS_poll
    syscall
    test    rax, rax
    jle     .done                       ; timeout, EINTR, or a poll error: nothing to do
    movzx   ebp, word [rsp + 6]         ; revents
    test    ebp, POLLOUT
    jz      .readable
    mov     rdi, rbx
    call    gc_flush
    test    eax, eax
    js      .done
.readable:
    test    ebp, POLLIN | POLLHUP | POLLERR
    jz      .flush
    mov     r13d, 8                     ; reads per poll
.read:
    mov     rdi, [rbx + GaClient.fd]
    mov     rsi, [rbx + GaClient.read_buf]
    mov     edx, GC_READ_CHUNK
    xor     eax, eax                    ; SYS_read
    syscall
    cmp     rax, -EINTR
    je      .read
    cmp     rax, -EAGAIN
    je      .flush
    test    rax, rax
    jz      .eof
    js      .error
    mov     r14, rax
    mov     rdi, rbx
    mov     rsi, [rbx + GaClient.read_buf]
    mov     rdx, rax
    call    gc_input_core
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jnz     .flush                      ; offer the GOAWAY of a connection error
    cmp     r14, GC_READ_CHUNK
    jb      .flush                      ; a short read: the socket is drained
    dec     r13d
    jnz     .read
    jmp     .flush
.eof:
    mov     rdi, rbx
    mov     rsi, -ECONNRESET
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_closed]
    mov     r8d, m_closed_len
    call    gc_close
    jmp     .done
.error:
    mov     rdi, rbx
    mov     rsi, rax
    mov     edx, GC_UNAVAILABLE
    lea     rcx, [m_lost]
    mov     r8d, m_lost_len
    call    gc_close
    jmp     .done
.flush:
    mov     rdi, rbx
    call    gc_flush
.done:
    and     qword [rbx + GaClient.flags], ~GCF_BUSY
    mov     rax, [rbx + GaClient.completed]
    test    rax, rax
    jnz     .out
    test    qword [rbx + GaClient.flags], GCF_CLOSED
    jz      .out
.closed:
    mov     rax, [rbx + GaClient.error]
    jmp     .out
.busy:
    mov     rax, -EBUSY
    jmp     .out
.ebadf:
    mov     rax, -EBADF
.out:
    add     rsp, 16
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_now_ms — the monotonic clock in milliseconds. Internal.
; @returns rax = CLOCK_MONOTONIC in ms.
; =============================================================================
gc_now_ms:
    sub     rsp, 24                     ; [0..16) struct timespec; aligned
    mov     edi, CLOCK_MONOTONIC
    mov     rsi, rsp
    call    clock_gettime wrt ..plt
    imul    rcx, [rsp], 1000
    mov     rax, [rsp + 8]
    xor     edx, edx
    mov     r8d, 1000000
    div     r8
    add     rax, rcx
    add     rsp, 24
    ret

; =============================================================================
; ga_client_unary — one call, waited for (socket mode).
;
; @param  rdi  GaClient*   @param esi  method handle
; @param  rdx  request     @param rcx  its length
; @param  r8   done callback   @param r9  its context
; @param  [rsp + 8]  timeout in milliseconds (int; -1 = no limit)
; @returns eax = 0 when the call completed (done ran: its status says how);
;          or, and then done never ran, -EBUSY (from a callback), -EBADF
;          (bytes mode), or ga_client_call's errors.
; @remarks Other calls in flight make progress meanwhile (their callbacks run
;          too). At the deadline the call is cancelled (RST_STREAM CANCEL when
;          it holds a stream) and completes DEADLINE_EXCEEDED.
; =============================================================================
ga_client_unary:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40                     ; [0] done [8] context [16] finished
                                        ; [24] deadline; 6 pushes + 40: aligned
    mov     rbx, rdi
    mov     r15d, [rsp + 40 + 48 + 8]   ; the 7th argument: timeout
    mov     rax, [rbx + GaClient.flags]
    test    eax, GCF_BUSY
    jnz     .busy
    cmp     qword [rbx + GaClient.fd], 0
    jl      .ebadf
    test    r8, r8
    jz      .einval
    mov     [rsp], r8
    mov     [rsp + 8], r9
    mov     qword [rsp + 16], 0
    lea     r8, [gc_unary_done]         ; the trampoline marks the frame finished
    mov     r9, rsp
    call    gc_call                     ; rdi, esi, rdx, rcx as given
    test    rax, rax
    js      .out
    mov     rbp, rax
    test    r15d, r15d
    js      .wait
    call    gc_now_ms
    movsxd  rcx, r15d
    add     rax, rcx
    mov     [rsp + 24], rax
.wait:
    cmp     qword [rsp + 16], 0
    jne     .ok
    mov     esi, -1
    test    r15d, r15d
    js      .poll
    call    gc_now_ms
    mov     rcx, [rsp + 24]
    sub     rcx, rax
    jle     .expired
    mov     esi, ecx
.poll:
    mov     rdi, rbx
    call    ga_client_poll
    test    rax, rax
    jns     .wait
    cmp     qword [rsp + 16], 0
    jne     .ok                         ; the connection ended, and with it the call
.expired:
    or      qword [rbx + GaClient.flags], GCF_BUSY
    mov     rdi, rbx
    mov     rsi, rbp
    call    gc_cancel
    mov     rdi, rbx
    call    gc_pump                     ; a freed stream may start a queued call
    and     qword [rbx + GaClient.flags], ~GCF_BUSY
    mov     rdi, rbx
    call    gc_flush
.ok:
    xor     eax, eax
    jmp     .out
.busy:
    mov     eax, -EBUSY
    jmp     .out
.ebadf:
    mov     eax, -EBADF
    jmp     .out
.einval:
    mov     eax, -EINVAL
.out:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; gc_unary_done — ga_client_unary's callback trampoline. Internal.
; @param  rdi  the unary frame ([0] done [8] context [16] finished)
; @param  esi, rdx, rcx, r8, r9  the completion, passed on unchanged
; @returns what the caller's done returns (nothing).
; =============================================================================
gc_unary_done:
    mov     qword [rdi + 16], 1
    mov     rax, [rdi]
    mov     rdi, [rdi + 8]
    jmp     rax                         ; tail call: the caller's done

; =============================================================================
; gc_cancel — end a call before its response: DEADLINE_EXCEEDED. Internal.
; @param  rdi  GaClient*   @param rsi  GaCall* (open or queued)
; @returns nothing.
; @remarks An open call's stream is reset with CANCEL (frames still in flight
;          for it are then dropped by id); a queued call just leaves the queue.
; =============================================================================
gc_cancel:
    push    rbx
    push    rbp
    sub     rsp, 8                      ; 2 pushes + 8: aligned
    mov     rbx, rdi
    mov     rbp, rsi
    test    qword [rbp + GaCall.flags], GCC_OPEN
    jz      .complete
    mov     rdi, rbx
    mov     esi, [rbp + GaCall.id]
    mov     edx, E_CANCEL
    call    gc_send_rst
.complete:
    mov     rdi, rbx
    mov     rsi, rbp
    mov     edx, GC_DEADLINE_EXCEEDED
    lea     rcx, [m_deadline]
    mov     r8d, m_deadline_len
    xor     r9d, r9d
    call    gc_complete
    add     rsp, 8
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; ga_client_connect — open a TCP connection and a client on it (socket mode).
;
; @param  rdi  host: a name or an address, NUL-terminated
; @param  esi  port, 1..65535
; @param  rdx  GaClientConfig*, or 0 (its authority defaults to "host:port",
;              with brackets around an IPv6 address)
; @param  rcx  GaClient** — receives the client (0 on failure)
; @returns eax = 0 once the server's SETTINGS arrived, or -EINVAL (bad
;          argument, a host longer than 247 bytes without an authority),
;          -EHOSTUNREACH (the name did not resolve), the connect error of the
;          last address tried (-ECONNREFUSED, ...), -ETIMEDOUT (connect_ms
;          passed, default 10 s), -EPROTO (the server is not HTTP/2), or
;          -ENOMEM.
; @remarks Every address getaddrinfo returns is tried in turn, non-blocking,
;          within what is left of the timeout. TCP_NODELAY is set: requests
;          are batched by the client already, and Nagle would only add delay.
; =============================================================================
%define CN_HINTS        0               ; struct addrinfo hints (48 bytes)
%define CN_RES          48              ; struct addrinfo *res
%define CN_CFG          56              ; GaClientConfig copy (40 bytes)
%define CN_DEADLINE     96
%define CN_ERR          104             ; error of the last address tried
%define CN_PFD          112             ; struct pollfd
%define CN_OPT          120             ; int option / socklen
%define CN_AUTH         128             ; "host:port" (256 bytes)
%define CN_SIZE         384
ga_client_connect:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, CN_SIZE + 8            ; 6 pushes + 392: aligned
    mov     r12, rdi                    ; host
    mov     r13d, esi                   ; port
    mov     r14, rcx                    ; out
    test    r14, r14
    jz      .einval
    mov     qword [r14], 0
    test    r12, r12
    jz      .einval
    test    r13d, r13d
    jz      .einval
    cmp     r13d, 65535
    ja      .einval
    ; The configuration, copied (so its authority can be filled in).
    xor     eax, eax
    mov     [rsp + CN_CFG + GaClientConfig.authority], rax
    mov     [rsp + CN_CFG + GaClientConfig.authority_len], rax
    mov     [rsp + CN_CFG + GaClientConfig.max_response], rax
    mov     [rsp + CN_CFG + GaClientConfig.max_calls], rax
    mov     qword [rsp + CN_CFG + GaClientConfig.connect_ms], GC_DEFAULT_CONNECT_MS
    test    rdx, rdx
    jz      .authority
    mov     rax, [rdx + GaClientConfig.authority]
    mov     [rsp + CN_CFG + GaClientConfig.authority], rax
    mov     rax, [rdx + GaClientConfig.authority_len]
    mov     [rsp + CN_CFG + GaClientConfig.authority_len], rax
    mov     rax, [rdx + GaClientConfig.max_response]
    mov     [rsp + CN_CFG + GaClientConfig.max_response], rax
    mov     rax, [rdx + GaClientConfig.max_calls]
    mov     [rsp + CN_CFG + GaClientConfig.max_calls], rax
    mov     rax, [rdx + GaClientConfig.connect_ms]
    test    rax, rax
    jz      .authority
    mov     [rsp + CN_CFG + GaClientConfig.connect_ms], rax
.authority:
    cmp     qword [rsp + CN_CFG + GaClientConfig.authority], 0
    jne     .resolve
    ; "host:port", or "[host]:port" when the host is an IPv6 address.
    mov     rdi, r12
    call    strlen wrt ..plt
    test    rax, rax
    jz      .einval
    cmp     rax, GC_MAX_AUTHORITY - 6 - 2
    ja      .einval
    mov     r15, rax                    ; host length
    lea     rbp, [rsp + CN_AUTH]        ; cursor
    xor     ecx, ecx
.colon:
    cmp     byte [r12 + rcx], ':'
    je      .ipv6
    inc     rcx
    cmp     rcx, r15
    jb      .colon
    xor     ebx, ebx                    ; no brackets
    jmp     .host
.ipv6:
    mov     ebx, 1
    mov     byte [rbp], '['
    inc     rbp
.host:
    mov     rdi, rbp
    mov     rsi, r12
    mov     rdx, r15
    call    memcpy wrt ..plt
    add     rbp, r15
    test    ebx, ebx
    jz      .port
    mov     byte [rbp], ']'
    inc     rbp
.port:
    mov     byte [rbp], ':'
    inc     rbp
    ; Decimal port: digits are written backwards into 5 bytes, then moved.
    mov     eax, r13d
    lea     rdi, [rbp + 5]
    mov     ecx, 10
.digit:
    xor     edx, edx
    div     ecx
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    test    eax, eax
    jnz     .digit
    lea     rdx, [rbp + 5]
    sub     rdx, rdi                    ; digits
    mov     rsi, rdi
    mov     rdi, rbp
    mov     rbx, rdx
    call    memmove wrt ..plt
    add     rbp, rbx
    lea     rax, [rsp + CN_AUTH]
    mov     [rsp + CN_CFG + GaClientConfig.authority], rax
    sub     rbp, rax
    mov     [rsp + CN_CFG + GaClientConfig.authority_len], rbp
.resolve:
    call    gc_now_ms
    add     rax, [rsp + CN_CFG + GaClientConfig.connect_ms]
    mov     [rsp + CN_DEADLINE], rax
    lea     rdi, [rsp + CN_HINTS]
    xor     eax, eax
    mov     ecx, ADDRINFO_SIZE / 8
.zero:
    mov     [rdi + rcx*8 - 8], rax
    dec     ecx
    jnz     .zero
    mov     dword [rsp + CN_HINTS + AI_FAMILY], AF_UNSPEC
    mov     dword [rsp + CN_HINTS + AI_SOCKTYPE], SOCK_STREAM
    mov     qword [rsp + CN_RES], 0
    mov     rdi, r12
    xor     esi, esi                    ; no service: the port is set below
    lea     rdx, [rsp + CN_HINTS]
    lea     rcx, [rsp + CN_RES]
    call    getaddrinfo wrt ..plt
    test    eax, eax
    jnz     .unresolved
    mov     qword [rsp + CN_ERR], -EHOSTUNREACH
    mov     r15, [rsp + CN_RES]         ; current address
    mov     ebx, -1                     ; the socket that connected
.try:
    test    r15, r15
    jz      .tried
    ; sin_port / sin6_port: offset 2 of both sockaddr layouts, big-endian.
    mov     rax, [r15 + AI_ADDR]
    mov     ecx, r13d
    xchg    cl, ch
    mov     [rax + 2], cx
    mov     edi, [r15 + AI_FAMILY]
    mov     esi, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
    mov     edx, IPPROTO_TCP
    mov     eax, SYS_socket
    syscall
    test    eax, eax
    js      .failed_socket
    mov     ebp, eax
    mov     edi, ebp
    mov     rsi, [r15 + AI_ADDR]
    mov     edx, [r15 + AI_ADDRLEN]
    mov     eax, SYS_connect
    syscall
    test    eax, eax
    jz      .connected
    cmp     eax, -EINPROGRESS
    jne     .failed
    ; Wait for the connection within the time that is left.
    call    gc_now_ms
    mov     rdx, [rsp + CN_DEADLINE]
    sub     rdx, rax
    jle     .timed_out
    mov     [rsp + CN_PFD], ebp
    mov     word [rsp + CN_PFD + 4], POLLOUT
    mov     word [rsp + CN_PFD + 6], 0
    lea     rdi, [rsp + CN_PFD]
    mov     esi, 1
    mov     eax, SYS_poll
    syscall
    cmp     rax, -EINTR
    je      .timed_out                  ; (rare: treated as the deadline)
    test    rax, rax
    jle     .timed_out
    ; The result of the connect: SO_ERROR.
    mov     dword [rsp + CN_OPT], 0
    mov     dword [rsp + CN_OPT + 4], 4
    mov     edi, ebp
    mov     esi, SOL_SOCKET
    mov     edx, SO_ERROR
    lea     r10, [rsp + CN_OPT]
    lea     r8, [rsp + CN_OPT + 4]
    mov     eax, SYS_getsockopt
    syscall
    test    eax, eax
    js      .failed
    mov     eax, [rsp + CN_OPT]
    neg     eax
    test    eax, eax
    jz      .connected
.failed:
    movsxd  rax, eax
    mov     [rsp + CN_ERR], rax
    mov     edi, ebp
    mov     eax, SYS_close
    syscall
    mov     r15, [r15 + AI_NEXT]
    jmp     .try
.failed_socket:
    movsxd  rax, eax
    mov     [rsp + CN_ERR], rax
    mov     r15, [r15 + AI_NEXT]
    jmp     .try
.timed_out:
    mov     qword [rsp + CN_ERR], -ETIMEDOUT
    mov     edi, ebp
    mov     eax, SYS_close
    syscall
    jmp     .tried                      ; the deadline covers every address
.connected:
    mov     ebx, ebp
.tried:
    mov     rdi, [rsp + CN_RES]
    call    freeaddrinfo wrt ..plt
    test    ebx, ebx
    js      .connect_failed
    mov     dword [rsp + CN_OPT], 1
    mov     edi, ebx
    mov     esi, IPPROTO_TCP
    mov     edx, TCP_NODELAY
    lea     r10, [rsp + CN_OPT]
    mov     r8d, 4
    mov     eax, SYS_setsockopt
    syscall                             ; a failure only costs latency: ignored
    ; The client, on this socket.
    lea     rdi, [rsp + CN_CFG]
    lea     rsi, [rsp + CN_RES]         ; (reused as the out slot)
    call    ga_client_new
    test    eax, eax
    jnz     .close_return
    mov     r15, [rsp + CN_RES]
    mov     [r15 + GaClient.fd], rbx
    mov     edi, GC_READ_CHUNK
    call    malloc wrt ..plt
    test    rax, rax
    jz      .free_enomem
    mov     [r15 + GaClient.read_buf], rax
    ; The handshake: our preface goes out, the server's SETTINGS must come.
.handshake:
    test    qword [r15 + GaClient.flags], GCF_SETTINGS
    jnz     .done
    call    gc_now_ms
    mov     rcx, [rsp + CN_DEADLINE]
    sub     rcx, rax
    jle     .free_timeout
    mov     rdi, r15
    mov     esi, ecx
    call    ga_client_poll
    test    rax, rax
    jns     .handshake
    mov     ebx, eax                    ; the connection's error
    jmp     .free_return
.free_timeout:
    mov     ebx, -ETIMEDOUT
    jmp     .free_return
.free_enomem:
    mov     ebx, -ENOMEM
.free_return:
    mov     rdi, r15
    call    gc_destroy                  ; no calls exist yet; closes the socket
    mov     eax, ebx
    jmp     .out
.done:
    mov     [r14], r15
    xor     eax, eax
    jmp     .out
.close_return:
    mov     ebp, eax
    mov     edi, ebx
    mov     eax, SYS_close
    syscall
    mov     eax, ebp
    jmp     .out
.connect_failed:
    mov     rax, [rsp + CN_ERR]
    jmp     .out
.unresolved:
    mov     eax, -EHOSTUNREACH
    jmp     .out
.einval:
    mov     eax, -EINVAL
.out:
    add     rsp, CN_SIZE + 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
%if CN_AUTH + 256 > CN_SIZE || CN_CFG + GaClientConfig_size > CN_DEADLINE
    %error "ga_client_connect's frame layout overlaps"
%endif

section .note.GNU-stack noalloc noexec nowrite progbits
