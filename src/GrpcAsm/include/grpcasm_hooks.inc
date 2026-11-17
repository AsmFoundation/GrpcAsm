; =============================================================================
; grpcasm_hooks.inc — the application hooks: every call the GrpcAsm engine
; makes into the application built on it.
;
; The engine holds no application logic. When a worker, a connection or a
; call reaches one of the points below, the engine calls a fixed symbol, and
; the application linked with libgrpcasm.a defines it as a global function
; (KvServer: samples/KvServer/grpc.asm and hooks.asm). This file is that whole
; contract (docs/ROADMAP.md, milestone B steps 3 and 4): the engine names no
; application symbol other than these, and the application reaches the engine
; only through the ga_* exports and the structures of server.inc.
;
; Why link-time symbols rather than a table of function pointers: the engine
; calls each hook with a direct `call rel32`, so there is no pointer to load,
; no indirect branch to predict and nothing to register at startup, and a
; missing hook fails the link instead of crashing at run time (every hook is
; called from worker.asm, h2n.asm or grpc.asm, which every server links). The
; price is one application per executable; the ga_app_ prefix keeps the names
; out of other code's way. How the C, .NET and Python APIs bind them is
; milestone C.
;
; Calling convention (System V AMD64, like every ga_* function):
;   - arguments in rdi, rsi, rdx, rcx; the result in eax or rax, as noted;
;   - rbx, rbp and r12-r15 must be preserved; any other general-purpose or
;     vector register may be clobbered;
;   - rsp is 16-byte aligned at the call (rsp = 16n + 8 on entry), and the
;     direction flag is clear and must be clear again on return.
;
; Threads: a worker's hooks run on that worker's own thread, which owns its
; connections and streams, so per-worker and per-connection state needs no
; lock. The exceptions are ga_app_worker_init and ga_app_worker_fini, which
; run on the thread that creates or frees the worker (main).
;
; Ownership: the engine allocates a Stream when a request's HEADERS open it,
; buffers its body, validates the call and frees the Stream when it ends
; (engine grpc.asm). What the application keeps for a call lives in
; Stream.app (GA_STREAM_APP_SIZE bytes, zeroed at open); while that holds
; something to release, the application sets ST_APP_STATE and the engine
; calls ga_app_call_release before freeing the stream, however the stream
; ends. Its per-connection state lives in Conn.app. An answer may be deferred
; to the end of the read: the application sets ST_BATCHED, links the stream on
; Conn.batch_head (through Stream.batch_next, in arrival order) and answers it
; in ga_app_batch_end. Stream.method is the route byte hpack.asm resolved
; from :path through the application's route table (ga_app_routes below).
; =============================================================================

%ifndef GRPCASM_HOOKS_INC
%define GRPCASM_HOOKS_INC

; ---- worker hooks: rdi = Worker* ---------------------------------------------
; Worker.app is the context the application passed to ga_worker_create (rsi),
; and Worker.app_worker the application's own per-worker slot: 0 until
; ga_app_worker_init stores something there. The engine reads neither.

; ga_app_worker_init — set up the application's per-worker state.
; @param   rdi  Worker* (id, app and cfg set; app_worker = 0)
; @returns rax = 0, or a negative errno: the engine then logs "worker setup
;          failed step=ga_app_worker_init errno=..." and ga_worker_create
;          returns 0 after freeing the worker (ga_app_worker_fini included).
; @remarks Runs inside ga_worker_create on the creating thread, before the
;          worker's thread, epoll instance and sockets exist.
extern ga_app_worker_init

; ga_app_worker_fini — release the application's per-worker state.
; @param   rdi  Worker*
; @returns nothing.
; @remarks Runs when the worker is freed: after its thread was joined, or when
;          ga_worker_create fails at any step. It must therefore accept a
;          worker whose ga_app_worker_init failed or never ran (app_worker
;          still 0). Every connection is closed by then.
extern ga_app_worker_fini

; ga_app_worker_resume — the worker is about to process events.
; @param   rdi  Worker*
; @returns nothing.
; @remarks Called when the worker's thread starts and after every return from
;          epoll_wait, before any connection is touched: every call hook and
;          every tick runs between a resume and the next pause. KvServer
;          rejoins its QSBR readers here (an XCHG, which is also the fence
;          that orders the worker's later reads of the store).
extern ga_app_worker_resume

; ga_app_worker_pause — the worker is about to sleep or to exit.
; @param   rdi  Worker*
; @returns nothing.
; @remarks Called before every epoll_wait and once when the loop ends; no
;          hook runs again before the next resume. KvServer leaves its QSBR
;          readers here, so a sleeping worker never holds up reclamation.
extern ga_app_worker_pause

; ga_app_worker_tick — periodic work, once per housekeeping pass.
; @param   rdi  Worker*
; @returns nothing.
; @remarks About once per second whether or not traffic arrives, after the
;          engine has swept its idle connections. KvServer returns retired
;          records to the allocator here, so memory comes back even when no
;          writes happen.
extern ga_app_worker_tick

; ---- call hooks: rdi = Conn*, rsi = Stream* (Stream* first for the fill) ------

; ga_app_unary — run a validated call whose request is one message.
; @param   rdi  Conn*
; @param   rsi  Stream* (already counted and marked ST_RESPONDED)
; @param   rdx  the request message (protobuf, after the 5-byte prefix)
; @param   rcx  its length
; @returns eax = 0, or -1 (out of memory while queuing the answer: the
;          engine ends the connection).
; @remarks The engine calls this at END_STREAM, by tail call, once the
;          method (POST), content-type, route, size limit, framing (exactly
;          one message) and compression rules have passed; the health
;          service never reaches it. Decoding the message is the
;          application's: answer with ga_h2n_reply_*, refuse with
;          ga_grpc_refuse, or defer the answer to ga_app_batch_end. The
;          stream may be answered and freed before this returns, so the
;          engine never touches it afterwards. The message is valid until
;          ga_app_batch_end has returned: it may sit in the worker's read
;          buffer (ST_BORROWED, a body that arrived in one DATA frame) rather
;          than in Stream.req_buf.
extern ga_app_unary

; ga_app_stream_data — consume a chunk of a client-streaming request.
; @param   rdi  Conn*   @param rsi  Stream* (a GA_ROUTE_CLIENT_STREAM route;
;               KvServer: Upload)
; @param   rdx  data    @param rcx  length (> 0)
; @returns eax = 0 (consumed; the stream lives on), 1 (answered early, an
;          error: the stream may already be closed and freed, so the engine
;          does not touch it), or -1 (out of memory: the connection ends).
; @remarks Called as each non-empty DATA payload arrives, after flow-control
;          accounting and after the engine checked that the request is POST
;          with a gRPC content-type and has no answer yet (it refuses a
;          non-gRPC upload with 405/415 itself, and drops what follows an
;          answer). The engine never buffers these bodies, and the data is
;          valid only during the call. An application that answers early
;          sets ST_RESPONDED and counts the call (Worker.st_requests): the
;          engine will not count it at END_STREAM.
extern ga_app_stream_data

; ga_app_stream_end — a client-streaming request ended (END_STREAM).
; @param   rdi  Conn*   @param rsi  Stream* (already counted and marked
;               ST_RESPONDED)
; @returns eax = 0, or -1 (out of memory: the engine ends the connection).
; @remarks Called by tail call once the method, content-type and route are
;          checked; the body went to ga_app_stream_data as it arrived, so
;          there is no framing to check. Not called for a call already
;          answered early.
extern ga_app_stream_end

; ga_app_stream_fill — produce the next bytes of a generated response body.
; @param   rdi  Stream* (ST_GEN; resp_len = the body's exact total length)
; @param   rsi  destination, inside the DATA frame the engine is writing
; @param   rdx  n: bytes to write (the calls never ask past resp_len)
; @returns nothing; exactly n bytes must be written.
; @remarks Called as flow-control windows and output room allow, so a body of
;          any size costs a fixed amount of connection memory. Must neither
;          fail nor allocate: the frame header is already written.
extern ga_app_stream_fill

; ga_app_batch_end — every frame of one read has been processed.
; @param   rdi  Conn*
; @returns eax = 0, or -1 (out of memory: the engine ends the connection).
; @remarks Called by ga_h2n_read after each read's frames, unless the
;          connection is failing (H2F_CLOSING: its deferred work is dropped
;          with it), and before the read buffer is reused: the last point
;          where ST_BORROWED messages are valid. The application answers the
;          streams it deferred on Conn.batch_head, and releases the ones the
;          peer reset meanwhile (ST_CLOSED) with ga_grpc_stream_release.
;          KvServer's write batching and prefetch pipeline rest on this hook
;          (KvAsm ADR 0011).
extern ga_app_batch_end

; ga_app_call_release — release the application's state of an ending call.
; @param   rdi  Conn*   @param rsi  Stream* (ST_APP_STATE set)
; @returns nothing.
; @remarks Called by the engine's stream_free, before it frees the stream's
;          buffers and the stream itself, for every stream with ST_APP_STATE
;          however it ends: answered, reset by either side, or torn down with
;          its connection (drain, idle timeout, a broken peer). Must not
;          answer the stream or touch the connection's output. KvServer frees
;          an unpublished record here and drops a download's pin.
extern ga_app_call_release

; ga_app_health_service — whether the application serves a named service.
; @param   rdi  the service name (not NUL-terminated)   @param rsi  its length (> 0)
; @returns eax != 0 when served (the health check answers SERVING, or
;          NOT_SERVING while the worker drains), 0 when unknown (NOT_FOUND).
; @remarks Called by the built-in grpc.health.v1.Health/Check for a non-empty
;          service name; the empty name means the whole server and needs no
;          hook. A leaf in practice: compare and return.
extern ga_app_health_service

; ---- the route table (data, not code) --------------------------------------------

; ga_app_routes — the application's methods: a table built with GA_ROUTE and
; ended with GA_ROUTES_END (grpcasm_routes.inc), in the application's .rodata.
; @remarks hpack.asm reads it, never writes it, to classify every new :path
;          (exact match, first entry wins; the built-in health path is checked
;          first). It holds no pointers, so it needs no relocation. Defined
;          like a hook: `global ga_app_routes:data`, then the entries.
extern ga_app_routes

%endif
