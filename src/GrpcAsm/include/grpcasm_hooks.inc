; =============================================================================
; grpcasm_hooks.inc — the application hooks: every call the GrpcAsm engine
; makes into the application built on it.
;
; The engine holds no application logic. When a worker, a connection or a
; stream reaches one of the points below, the engine calls a fixed symbol,
; and the application linked with libgrpcasm.a defines it as a global
; function (KvServer: samples/KvServer/grpc.asm and hooks.asm). This file is
; that whole contract (docs/ROADMAP.md, milestone B step 3): the engine names
; no application symbol other than these, and the application reaches the
; engine only through the ga_* exports and the structures of server.inc.
;
; Why link-time symbols rather than a table of function pointers: the engine
; calls each hook with a direct `call rel32`, so there is no pointer to load,
; no indirect branch to predict and nothing to register at startup, and a
; missing hook fails the link instead of crashing at run time (every hook is
; called from worker.asm or h2n.asm, which every server links). The price is
; one application per executable; the ga_app_ prefix keeps the names out of
; other code's way. How the C, .NET and Python APIs bind them is milestone C.
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
; Ownership: the engine allocates a Stream from the worker's pool when a
; request's HEADERS open it and links it on Conn.streams; the application
; frees it (ga_app_stream_release, ga_app_free_streams), because the
; per-connection accounting (Conn.streams, Conn.buffered, the batch) is still
; the application's until step 4 moves the generic half into the engine.
; Stream.method is the route hpack.asm resolved from :path (fixed routes
; until step 5's route tables).
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
;          epoll_wait, before any connection is touched: every stream hook and
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

; ---- connection and stream hooks: rdi = Conn* (Stream* for the fill) ----------

; ga_app_dispatch — a request is complete: validate it, run it, answer it.
; @param   rdi  Conn*
; @param   rsi  Stream* (END_STREAM received; header fields resolved into
;               Stream.method and Stream.flags; the body in req_buf/req_len)
; @returns eax = 0, or -1 (out of memory while queuing the answer: the
;          engine ends the connection).
; @remarks The stream may be answered and freed before this returns, so the
;          engine never touches it afterwards. A body that arrived whole in
;          one DATA frame is not copied: ST_BORROWED, req_buf points into the
;          worker's read buffer and stays valid until ga_app_batch_end has
;          returned, which lets the answer wait for the batch (KvServer
;          batches Get, Put and Delete).
extern ga_app_dispatch

; ga_app_batch_end — every frame of one read has been processed.
; @param   rdi  Conn*
; @returns eax = 0, or -1 (out of memory: the engine ends the connection).
; @remarks Called by ga_h2n_read after each read's frames, unless the
;          connection is failing (H2F_CLOSING: its queued work is dropped with
;          it), and before the read buffer is reused: the last point where
;          ST_BORROWED bodies are valid. KvServer executes and answers its
;          batched calls here; its write batching and prefetch pipeline rest
;          on this hook (KvAsm ADR 0011).
extern ga_app_batch_end

; ga_app_stream_append — buffer a chunk of a request body.
; @param   rdi  Conn*   @param rsi  Stream*
; @param   rdx  data    @param rcx  length
; @returns eax = 0 (buffered, or dropped because the application marked the
;          stream oversize, ST_TOO_LARGE), or 1 (over the connection's
;          buffering budget: the engine resets the stream with
;          ENHANCE_YOUR_CALM).
; @remarks For each DATA payload of a non-streaming route that the engine
;          does not borrow (see ga_app_dispatch), after flow-control
;          accounting. The data is valid only during the call.
extern ga_app_stream_append

; ga_app_stream_data — consume a chunk of a client-streaming request.
; @param   rdi  Conn*   @param rsi  Stream* (a streaming route; KvServer:
;               M_UPLOAD)
; @param   rdx  data    @param rcx  length (> 0)
; @returns eax = 0 (consumed; the stream lives on), 1 (answered early, an
;          error: the stream may already be closed and freed, so the engine
;          does not touch it), or -1 (out of memory: the connection ends).
; @remarks Called as each non-empty DATA payload arrives, after flow-control
;          accounting; the engine never buffers these bodies, and the data is
;          valid only during the call. END_STREAM still ends in
;          ga_app_dispatch.
extern ga_app_stream_data

; ga_app_stream_fill — produce the next bytes of a generated response body.
; @param   rdi  Stream* (ST_GEN; resp_len = the body's exact total length)
; @param   rsi  destination, inside the DATA frame the engine is writing
; @param   rdx  n: bytes to write (the calls never ask past resp_len)
; @returns nothing; exactly n bytes must be written.
; @remarks Called as flow-control windows and output room allow, so a body of
;          any size costs a fixed amount of connection memory. Must neither
;          fail nor allocate: the frame header is already written.
extern ga_app_stream_fill

; ga_app_stream_release — unlink a stream from its connection and free it.
; @param   rdi  Conn*   @param rsi  Stream*
; @returns nothing.
; @remarks Called for every stream the engine closes (a complete response, a
;          reset, an open that failed), except one batched for
;          ga_app_batch_end (ST_BATCHED): that one is marked ST_CLOSED and
;          left to the batch. Also returns the stream's buffered bytes to the
;          connection's budget.
extern ga_app_stream_release

; ga_app_free_streams — free every stream still attached to a connection.
; @param   rdi  Conn*
; @returns nothing.
; @remarks Called by the worker at connection teardown (linger and destroy),
;          after ga_h2n_close released the engine's own per-connection state.
;          Must be idempotent: a lingering connection is torn down again when
;          it is destroyed.
extern ga_app_free_streams

%endif
