; =============================================================================
; grpcasm_client.inc — GrpcAsm's gRPC client (client.asm): its structures,
; limits and API, for the engine's own modules and for NASM programs that
; call it.
;
; What the client is: one HTTP/2 connection to one gRPC server, carrying
; unary calls, pipelined. It is owned by one thread at a time: no locks are
; taken and none are needed, so several connections in parallel are several
; clients, one per thread (or handed between threads with their own
; synchronization).
;
; Two ways to drive it:
;   * Socket mode: ga_client_connect opens the TCP connection, exchanges the
;     HTTP/2 prefaces and returns once the server's SETTINGS arrived. Then
;     ga_client_poll waits for input, processes it and sends what is queued;
;     ga_client_unary is a blocking call on top of it.
;   * Bytes in, bytes out (no socket): ga_client_new creates a client whose
;     output the caller sends itself (ga_client_output / ga_client_consume)
;     and whose input the caller hands over (ga_client_input). A benchmark
;     or an event loop that owns its sockets (kvbench) drives it this way.
; Both share every line of the protocol code.
;
; Calls: register each method once (ga_client_method, a path such as
; "/helloworld.Greeter/SayHello"), then issue calls with the handle it
; returned (ga_client_call). The handle is what lets the HPACK encoder keep a
; finished header block per method: after a method's first call, its
; HEADERS frame carries 6 bytes, copied, not encoded.
;
; Completion: every call issued successfully ends with exactly one call of
; its done callback, on the thread that drives the client, from inside
; ga_client_input / ga_client_poll / ga_client_unary / ga_client_free:
;   done(context, status, message, message_length, response, response_length)
;     status    gRPC status: 0 OK, else the server's grpc-status or one the
;               client derived (UNAVAILABLE when the connection ends,
;               INTERNAL for a malformed response, RESOURCE_EXHAUSTED above
;               max_response, DEADLINE_EXCEEDED for a unary timeout, ...)
;     message   the status message (percent-decoded), or 0 with length 0
;     response  status 0: the response message (protobuf bytes, after the
;               gRPC framing); else 0 with length 0
; Every pointer is valid only during the callback. The callback may issue
; new calls (ga_client_call); it must not re-enter ga_client_input,
; ga_client_poll or ga_client_unary (they return -EBUSY) and must never free
; the client.
;
; Errors are negative errno values, like the server's C ABI.
; =============================================================================
%ifndef GRPCASM_CLIENT_INC
%define GRPCASM_CLIENT_INC

%include "server.inc"                   ; Pool, HpackDec (hpack.inc), READ_CHUNK

; ---- limits and defaults ---------------------------------------------------------
; Socket mode reads this much per read(): the server's READ_CHUNK, for the
; same reason (several responses per read, one copy of the kernel's data).
%define GC_READ_CHUNK           READ_CHUNK
; Frames of up to 16,384 bytes (our SETTINGS_MAX_FRAME_SIZE, the protocol
; default) plus their 9-byte header: the largest frame a read can split, which
; the client keeps until the rest arrives.
%define GC_FRAME_MAX            16384
%define GC_CARRY_CAP            (GC_FRAME_MAX + 9 + 7)
; HPACK: the response decoder keeps the default 4,096-byte table; its Huffman
; output buffer must hold at least that (ga_hpack_decode's contract), and is
; larger so that a long grpc-message still decodes whole.
%define GC_HPACK_TABLE          4096
%define GC_SCRATCH              16384
; The request encoder's table: at most 4,096 bytes, less when the server's
; SETTINGS_HEADER_TABLE_SIZE says so. Every entry accounts at least 32
; bytes, so at most 128 live entries; their sizes sit in a ring of that many.
%define GC_ENC_MAX              4096
%define GC_ENC_RING             128
; A header block that came in CONTINUATION frames is assembled up to this
; size, from at most this many frames (the server's bounds).
%define GC_MAX_BLOCK            65536
%define GC_MAX_CONTINUATION     64
; Paths and authorities are bounded so that a request's header block always
; fits one HEADERS frame (16,384 bytes), with room for the size updates.
%define GC_MAX_PATH             2048
%define GC_MAX_AUTHORITY        255
; A finished header block is cached per method when it is this short (two
; 8-byte moves copy it). All-indexed blocks are 6 to 10 bytes.
%define GC_BLOCK_CACHE          16
; Receive windows the client grants: the protocol maximum for every stream
; (SETTINGS_INITIAL_WINDOW_SIZE) and for the connection (a WINDOW_UPDATE in
; the preface). A unary response is bounded by max_response anyway, and the
; connection window is topped up once half of it is used, so the server is
; never paced by flow control.
%define GC_WINDOW               0x7FFFFFFF
%define GC_DEFAULT_MAX_RESPONSE 4194304 ; 4 MiB, gRPC's usual message limit
%define GC_LIMIT_MAX_RESPONSE   0x7FFFFFF0
%define GC_DEFAULT_MAX_CALLS    1000    ; concurrent calls per client
%define GC_LIMIT_MAX_CALLS      65536
%define GC_DEFAULT_CONNECT_MS   10000   ; connect and HTTP/2 handshake

; ---- gRPC status codes the client produces itself (grpc/doc/statuscodes.md) ------
%define GC_OK                   0
%define GC_CANCELLED            1
%define GC_UNKNOWN              2
%define GC_DEADLINE_EXCEEDED    4
%define GC_PERMISSION_DENIED    7
%define GC_RESOURCE_EXHAUSTED   8
%define GC_UNIMPLEMENTED        12
%define GC_INTERNAL             13
%define GC_UNAVAILABLE          14
%define GC_UNAUTHENTICATED      16

; ---- GaClientConfig: what ga_client_new and ga_client_connect take -------------------
; Zero means "the default" for every field but the authority of
; ga_client_new (which has no host to derive it from: default "localhost").
struc GaClientConfig
    .authority:         resq 1          ; :authority bytes (copied), or 0
    .authority_len:     resq 1          ; 1..GC_MAX_AUTHORITY
    .max_response:      resq 1          ; largest response message, bytes
    .max_calls:         resq 1          ; concurrent calls; more wait in a queue
    .connect_ms:        resq 1          ; ga_client_connect: connect + handshake
endstruc

; ---- GaMethod: one registered path and its cached header block --------------------
struc GaMethod
    .path:              resq 1          ; the path's bytes (malloc'd copy)
    .path_len:          resq 1
    ; Sequence number of this path's entry in the encoder's table (0 = not
    ; there): its index is 62 + (newest sequence - this one) while it lives.
    .seq:               resq 1
    ; The encoder generation .block was built for (-1: none). Any insertion,
    ; eviction or size change moves the generation, and a stale block is
    ; rebuilt by the next call.
    .gen:               resq 1
    .block_len:         resq 1
    .block:             resb GC_BLOCK_CACHE
endstruc

; ---- GaCall: one call --------------------------------------------------------------
%define GCC_QUEUED      1               ; waiting for a stream (over the concurrency limit)
%define GCC_OPEN        2               ; holds a stream id, in GaClient.calls
%define GCC_PEND        4               ; request bytes wait for flow-control window
%define GCC_HEADERS     8               ; the response's (final) header block arrived
%define GCC_BORROWED    16              ; .resp points into the input being processed
%define GCC_CT_OK       32              ; content-type: application/grpc[...]
struc GaCall
    .next:              resq 1          ; queue link (GCC_QUEUED)
    .pend_next:         resq 1          ; pend list link (GCC_PEND)
    .bnext:             resq 1          ; borrowed list link (GCC_BORROWED)
    .id:                resq 1          ; stream id, 0 while queued
    .flags:             resq 1          ; GCC_*
    .method:            resq 1          ; GaMethod*
    .done:              resq 1          ; completion callback
    .ctx:               resq 1          ; its context argument
    .req:               resq 1          ; owned copy of the request message, or 0
    .req_len:           resq 1          ; message length (the framing adds 5 bytes)
    .req_off:           resq 1          ; bytes of [prefix | message] framed so far
    .send_window:       resq 1          ; signed: what the server lets us send here
    .recv_window:       resq 1          ; signed: what we still let the server send
    .resp:              resq 1          ; response DATA: [prefix | message] bytes
    .resp_len:          resq 1
    .resp_cap:          resq 1          ; owned capacity; 0 while none or borrowed
    .http_status:       resq 1          ; :status, 0 until the header block
    .grpc_status:       resq 1          ; grpc-status, -1 until one arrives
    .msg:               resq 1          ; grpc-message (owned copy), or 0
    .msg_len:           resq 1
endstruc

; ---- GaClient: one connection -------------------------------------------------------
%define GCF_GOAWAY      1               ; GOAWAY received: no new calls
%define GCF_CLOSED      2               ; the connection failed or ended: nothing works
%define GCF_BUSY        4               ; inside input/poll/unary: re-entry refused
%define GCF_SETTINGS    8               ; the server's first SETTINGS arrived
%define GCF_NO_IDS      16              ; stream ids exhausted: no new calls
%define GCF_TSU         32              ; next header block starts with size update(s)
struc GaClient
    ; ---- connection and buffers ----
    .fd:                resq 1          ; socket mode: the socket; -1 without one
    .flags:             resq 1          ; GCF_*
    .error:             resq 1          ; negative errno once GCF_CLOSED, else 0
    .out_buf:           resq 1          ; queued output (malloc'd): [out_off, out_len)
    .out_cap:           resq 1
    .out_len:           resq 1
    .out_off:           resq 1
    .read_buf:          resq 1          ; socket mode's read buffer, or 0
    .carry:             resq 1          ; partial frame kept between inputs
    .carry_len:         resq 1
    .completed:         resq 1          ; callbacks run by the current input/poll
    ; ---- HTTP/2 ----
    .next_id:           resq 1          ; next stream id (odd)
    .send_window:       resq 1          ; signed: connection window for our DATA
    .recv_window:       resq 1          ; connection window still granted to the server
    .peer_window:       resq 1          ; server's SETTINGS_INITIAL_WINDOW_SIZE
    .peer_frame:        resq 1          ; server's SETTINGS_MAX_FRAME_SIZE
    .peer_streams:      resq 1          ; server's SETTINGS_MAX_CONCURRENT_STREAMS
    .goaway_id:         resq 1          ; last stream id of the server's GOAWAY
    .cont_id:           resq 1          ; stream of the header block being continued
    .cont_flags:        resq 1          ; END_STREAM / self-dependency of its HEADERS
    .cont_count:        resq 1          ; CONTINUATION frames in that block
    .hb_buf:            resq 1          ; header block assembly (malloc'd)
    .hb_len:            resq 1
    .hb_cap:            resq 1
    .scratch:           resq 2          ; {buffer, capacity}: the decoder's Huffman output
    .hpack:             resb HpackDec_size ; response header decoder
    ; ---- HPACK encoder (the server's decoder table, as we fill it) ----
    .enc_max:           resq 1          ; table size the encoder may use
    .enc_size:          resq 1          ; accounted size of the live entries
    .enc_seq:           resq 1          ; sequence of the newest entry (0: none yet)
    .enc_old:           resq 1          ; sequence of the oldest live entry
    .enc_gen:           resq 1          ; moves whenever an index may change
    .enc_tsu_min:       resq 1          ; smallest size since the last block (GCF_TSU)
    .auth_seq:          resq 1          ; sequences of the per-connection fields
    .ct_seq:            resq 1
    .te_seq:            resq 1
    .authority:         resq 1          ; :authority bytes (malloc'd copy)
    .authority_len:     resq 1
    .enc_sizes:         resw GC_ENC_RING ; accounted size of each live entry
    ; ---- calls ----
    .calls:             resq 1          ; GaCall*[ring_mask + 1], slot (id >> 1) & mask
    .ring_mask:         resq 1
    .active:            resq 1          ; calls holding a stream
    .max_calls:         resq 1
    .max_response:      resq 1
    .queue_head:        resq 1          ; calls waiting for a stream (FIFO)
    .queue_tail:        resq 1
    .pend_head:         resq 1          ; calls waiting for window (FIFO)
    .pend_tail:         resq 1
    .borrowed:          resq 1          ; calls whose response borrows the input
    .methods:           resq 1          ; GaMethod*[mcap]
    .nmethods:          resq 1
    .mcap:              resq 1
    ; ---- counters ----
    .st_calls:          resq 1          ; calls completed
    .st_failed:         resq 1          ; ... with a status other than OK
    .pool:              resb Pool_size  ; calls, response and message buffers
endstruc

; ---- the API (client.asm), System V calling convention -------------------------------
; client.asm defines these itself (GA_CLIENT_IMPL), so only consumers see the
; extern declarations.
%ifndef GA_CLIENT_IMPL
extern ga_client_new                   ; (GaClientConfig*, GaClient**) -> 0 / -errno
extern ga_client_connect                ; (host, port, GaClientConfig*, GaClient**) -> 0 / -errno
extern ga_client_free                   ; (GaClient*)
extern ga_client_method                 ; (GaClient*, path, length) -> handle / -errno
extern ga_client_call                   ; (GaClient*, handle, request, length, done, context) -> 0 / -errno
extern ga_client_unary                  ; (... same, timeout_ms) -> 0 / -errno
extern ga_client_input                  ; (GaClient*, data, length) -> completed / -errno
extern ga_client_output                 ; (GaClient*) -> rax data, rdx length
extern ga_client_consume                ; (GaClient*, length)
extern ga_client_flush                  ; (GaClient*) -> 0 sent / 1 pending / -errno
extern ga_client_poll                   ; (GaClient*, timeout_ms) -> completed / -errno
extern ga_client_fd                     ; (GaClient*) -> fd / -1
%endif

%endif
