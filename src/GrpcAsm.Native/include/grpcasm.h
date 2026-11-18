/*
 * grpcasm.h — the C ABI of GrpcAsm: a gRPC server and client whose HTTP/2, HPACK, gRPC and
 * event-loop engine is x86-64 assembly (libgrpcasm.so, Linux x86-64, glibc 2.34+).
 *
 * The server is described first; the client (grpcasm_client_*) follows at the end.
 *
 * A program creates a server from options, registers its unary methods (a full path such as
 * "/helloworld.Greeter/SayHello" and a handler), and either runs it until SIGTERM or SIGINT
 * (grpcasm_server_run, for standalone programs) or starts and stops it itself
 * (grpcasm_server_start / grpcasm_server_stop, for a host whose runtime owns the signals:
 * .NET, Python, a larger C program).
 *
 * Handlers run on the server's worker threads, one call at a time per worker, and must not
 * block: a worker serves all of its connections. A handler answers its call exactly once,
 * before it returns, with grpcasm_call_reply or grpcasm_call_fail; the call handle is
 * invalid after the handler returns. The request bytes are valid only during the handler.
 *
 * The engine also answers, without any handler: the gRPC health service
 * (grpc.health.v1.Health/Check: SERVING for "" and for every service that has a registered
 * method, NOT_FOUND otherwise; NOT_SERVING while draining), UNIMPLEMENTED for unknown
 * methods, the HTTP-level 405/415, the message framing and compression rules, and
 * RESOURCE_EXHAUSTED above max_message_bytes.
 *
 * Process-wide limit: one started server per process (the engine binds its application hooks
 * at link time); starting a second one returns -EBUSY until the first is stopped.
 *
 * Errors are negative errno values (EINVAL, ENOMEM, ...), as the Linux kernel's own ABI.
 *
 * ABI: every exported function and struct here is part of GRPCASM_0.1 (the version script);
 * grpcasm_options is passed with its size, so fields appended later never break callers
 * built against this header.
 */
#ifndef GRPCASM_H
#define GRPCASM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** The version this header describes: grpcasm_version() returns it from the library. */
#define GRPCASM_VERSION_MAJOR 0
#define GRPCASM_VERSION_MINOR 1
#define GRPCASM_VERSION_PATCH 0

/**
 * The library's version, (major << 16) | (minor << 8) | patch. Compare the major and minor
 * with GRPCASM_VERSION_* to detect a mismatched libgrpcasm.so at run time.
 */
uint32_t grpcasm_version(void);

/**
 * Server options. Zero means "the default" for every field, so `{ .size = sizeof opts }` is
 * a complete, valid configuration.
 */
typedef struct grpcasm_options {
  /** sizeof(grpcasm_options) as the caller compiled it: fields beyond it are defaults. */
  uint32_t size;
  /** TCP port, 1..65535. Default 50051. Every worker binds it (SO_REUSEPORT). */
  uint32_t port;
  /** Worker threads (event loops), 1..256. Default 1. */
  uint32_t workers;
  /** Concurrent calls per connection (SETTINGS_MAX_CONCURRENT_STREAMS), 1..1000. Default 100. */
  uint32_t max_streams;
  /** Connections per worker, 1..1000000. Default 10000. */
  uint32_t max_connections;
  /** Seconds without traffic before a connection is closed. Default 300; UINT32_MAX: never. */
  uint32_t idle_timeout_seconds;
  /** Seconds a stopping server lets calls in flight finish, 1..3600. Default 10. */
  uint32_t shutdown_grace_seconds;
  /** Request bytes one connection may buffer, in MiB, 1..4096. Default 64. */
  uint32_t connection_buffer_mb;
  /**
   * Largest request message accepted, in bytes; larger ones are RESOURCE_EXHAUSTED. Default
   * 4 MiB (gRPC's usual limit). Must fit connection_buffer_mb.
   */
  uint32_t max_message_bytes;
} grpcasm_options;

/** A server: created by grpcasm_server_new, freed by grpcasm_server_free. */
typedef struct grpcasm_server grpcasm_server;

/** One call, valid only while its handler runs. */
typedef struct grpcasm_call grpcasm_call;

/**
 * A unary method's handler.
 *
 * @param context  the pointer given to grpcasm_server_add_unary
 * @param call     the call: answer it once with grpcasm_call_reply or grpcasm_call_fail
 * @param request  the request message (protobuf bytes, after the gRPC framing); valid only
 *                 until the handler returns
 * @param length   its length
 * @return 0, or a negative value to end the connection (after an out-of-memory answer,
 *         say). A handler that returns 0 without answering gets INTERNAL "handler returned
 *         without a reply" sent for it.
 */
typedef int (*grpcasm_unary_fn)(void *context, grpcasm_call *call, const uint8_t *request,
                                size_t length);

/**
 * Creates a server (not started).
 *
 * @param options  options, or NULL for every default
 * @param server   receives the server (NULL on failure)
 * @return 0, -EINVAL (a field out of range, max_message_bytes above the connection buffer,
 *         or server NULL) or -ENOMEM.
 */
int grpcasm_server_new(const grpcasm_options *options, grpcasm_server **server);

/**
 * Registers a unary method before the server starts.
 *
 * @param server   the server
 * @param path     the method's full path, "/<package.Service>/<Method>", 3..255 bytes; copied
 * @param handler  its handler
 * @param context  passed to the handler as is
 * @return 0, -EINVAL (NULL argument, malformed path), -EEXIST (path already registered),
 *         -ENOSPC (62 methods already) or -EBUSY (the server has been started).
 */
int grpcasm_server_add_unary(grpcasm_server *server, const char *path, grpcasm_unary_fn handler,
                             void *context);

/**
 * Starts the server: every worker binds the port and serves until grpcasm_server_stop.
 *
 * Does not touch signals: the worker threads inherit the calling thread's signal mask, so a
 * host that does not want its signal handlers to run on them blocks those signals around
 * this call. Logs "listening" on success.
 *
 * @return 0, -EBUSY (this server already started, or another one runs in this process),
 *         -EADDRINUSE (another process serves the port; logged) or -EIO (a worker could not
 *         start; logged, nothing left running).
 */
int grpcasm_server_start(grpcasm_server *server);

/**
 * Stops a started server: every worker stops accepting, sends GOAWAY, lets the calls in
 * flight finish (up to shutdown_grace_seconds), and exits. Call it once, from any thread
 * except a worker (never from a handler).
 *
 * @param server  the server (a server that is not running is left alone)
 * @param totals  receives connections accepted, requests and errors, summed over the
 *                workers; or NULL
 */
void grpcasm_server_stop(grpcasm_server *server, uint64_t totals[3]);

/**
 * Runs the server until SIGTERM or SIGINT, for standalone programs: blocks both signals in
 * the calling thread (the workers inherit that), starts, waits, logs "shutdown requested",
 * stops.
 *
 * @param server  the server
 * @param totals  as for grpcasm_server_stop, or NULL
 * @return 0 after a clean shutdown, or grpcasm_server_start's error.
 */
int grpcasm_server_run(grpcasm_server *server, uint64_t totals[3]);

/** Frees a server, stopping it first if it runs. NULL is ignored. */
void grpcasm_server_free(grpcasm_server *server);

/**
 * Answers a call with one message and status OK.
 *
 * @param call     the call
 * @param message  the response message (protobuf bytes, without gRPC framing), copied before
 *                 this returns; may be NULL when length is 0
 * @param length   its length, below 4 GiB
 * @return 0, -EALREADY (the call was answered), -EMSGSIZE (4 GiB or more) or -1 (out of
 *         memory: return a negative value from the handler to end the connection).
 */
int grpcasm_call_reply(grpcasm_call *call, const void *message, size_t length);

/**
 * Answers a call with an error status (a Trailers-Only response).
 *
 * @param call     the call
 * @param status   a gRPC status code, 1..16 (OK is grpcasm_call_reply's)
 * @param message  the grpc-message text, or NULL; bytes outside printable ASCII and '%' are
 *                 percent-encoded as the gRPC protocol requires; at most 1024 bytes are sent
 * @return 0, -EALREADY, -EINVAL (status out of range) or -1 (out of memory).
 */
int grpcasm_call_fail(grpcasm_call *call, int status, const char *message);

/**
 * Finds a length-delimited field (string, bytes, an embedded message) of a protobuf message,
 * zero-copy, after checking the whole message (the engine's own decoder: unknown fields
 * skipped, the last occurrence wins).
 *
 * @param message  the message
 * @param length   its length
 * @param field    the field number, 1..2^29-1
 * @param value    receives a pointer into message (NULL when absent)
 * @param value_length  receives the field's length (0 when absent)
 * @return 1 (present), 0 (absent) or -EINVAL (malformed message, or a NULL out pointer).
 */
int grpcasm_pb_bytes(const uint8_t *message, size_t length, uint32_t field,
                     const uint8_t **value, size_t *value_length);

/* ======================================================================================== */
/* Client                                                                                   */
/* ======================================================================================== */

/*
 * A client is one HTTP/2 connection to one gRPC server, carrying unary calls, pipelined. One
 * thread drives a client at a time (no locks): for parallel connections, use one client per
 * thread.
 *
 * Two ways to drive it:
 *   - Socket mode: grpcasm_client_connect opens the connection and returns once the server's
 *     HTTP/2 preface arrived. grpcasm_client_poll then waits, processes what the server sent
 *     and sends what is queued; grpcasm_client_unary is a blocking call on top of it. For an
 *     event loop of your own, grpcasm_client_fd gives the socket.
 *   - Bytes in, bytes out: grpcasm_client_new creates a client without a socket. The caller
 *     sends what grpcasm_client_output shows (then grpcasm_client_consume) and hands over what
 *     it receives (grpcasm_client_input). A benchmark or an I/O framework that owns its
 *     sockets drives the client this way; the protocol code is the same.
 *
 * Calls: register each method once (grpcasm_client_method returns a handle), then call it
 * with the handle. The handle is what lets the client reuse a method's encoded HTTP/2 header
 * block: after a method's first call, its headers cost a 16-byte copy.
 *
 * Completion: every call that grpcasm_client_call or grpcasm_client_unary accepted (return
 * value 0) ends with exactly one call of its done function, on the thread driving the client,
 * from inside grpcasm_client_input, _poll, _unary or _free. The callback may issue new calls;
 * it must not call grpcasm_client_input, _poll or _unary (they return -EBUSY), and must never
 * free the client.
 *
 * Statuses the client produces itself: UNAVAILABLE (14) when the connection ends or the
 * server's GOAWAY says the call was not processed; INTERNAL (13) for a response that breaks
 * HTTP/2 or gRPC; RESOURCE_EXHAUSTED (8) above max_response_bytes; DEADLINE_EXCEEDED (4) when
 * grpcasm_client_unary's timeout passes; CANCELLED (1) for calls still running when the client
 * is freed; and the gRPC mapping of a non-200 HTTP status.
 */

/** A client: created by grpcasm_client_new or _connect, freed by grpcasm_client_free. */
typedef struct grpcasm_client grpcasm_client;

/**
 * Client options. Zero means "the default" for every field, so `{ .size = sizeof opts }` is a
 * complete, valid configuration.
 */
typedef struct grpcasm_client_options {
  /** sizeof(grpcasm_client_options) as the caller compiled it: fields beyond it are defaults. */
  uint32_t size;
  /**
   * Largest response message accepted, in bytes, below 2 GiB. Default 4 MiB. A larger
   * response is cancelled and its call completes RESOURCE_EXHAUSTED.
   */
  uint32_t max_response_bytes;
  /**
   * Calls in flight on the connection, 1..65536. Default 1000. More calls wait in a queue,
   * in order; so do calls above the server's SETTINGS_MAX_CONCURRENT_STREAMS.
   */
  uint32_t max_concurrent_calls;
  /** grpcasm_client_connect: milliseconds for the connection and the HTTP/2 handshake. Default 10000. */
  uint32_t connect_timeout_ms;
  /**
   * The :authority of every call, 1..255 bytes, or NULL: "host:port" for
   * grpcasm_client_connect ("[host]:port" for an IPv6 address), "localhost" for
   * grpcasm_client_new. Copied.
   */
  const char *authority;
} grpcasm_client_options;

/**
 * A call's completion.
 *
 * @param context          the pointer given with the call
 * @param status           the gRPC status: 0 OK, else the server's or one the client produced
 * @param message          the status message (percent-decoded), or NULL
 * @param message_length   its length
 * @param response         status 0: the response message (protobuf bytes, after the gRPC
 *                         framing); else NULL
 * @param response_length  its length
 *
 * Every pointer is valid only until the function returns.
 */
typedef void (*grpcasm_client_done_fn)(void *context, int status, const char *message,
                                       size_t message_length, const uint8_t *response,
                                       size_t response_length);

/**
 * Connects to a gRPC server over cleartext HTTP/2 (h2c, prior knowledge).
 *
 * Tries every address the host resolves to, then exchanges the HTTP/2 prefaces: it returns
 * once the server's SETTINGS arrived. Sets TCP_NODELAY.
 *
 * @param host     a name or an IPv4/IPv6 address
 * @param port     the server's port
 * @param options  options, or NULL
 * @param client   receives the client (NULL on failure)
 * @return 0, -EINVAL, -EHOSTUNREACH (the name did not resolve), the last address's connect
 *         error (-ECONNREFUSED, ...), -ETIMEDOUT, -EPROTO (the server is not HTTP/2) or
 *         -ENOMEM.
 */
int grpcasm_client_connect(const char *host, uint16_t port, const grpcasm_client_options *options,
                           grpcasm_client **client);

/**
 * Creates a client without a socket (bytes in, bytes out). Its output already holds the
 * HTTP/2 connection preface; calls may be issued at once.
 *
 * @return 0, -EINVAL or -ENOMEM.
 */
int grpcasm_client_new(const grpcasm_client_options *options, grpcasm_client **client);

/**
 * Frees a client. Calls still running complete first, CANCELLED "client closed". In socket
 * mode a GOAWAY is offered to the socket, which is then closed. NULL is ignored. Never call it
 * from a callback.
 */
void grpcasm_client_free(grpcasm_client *client);

/**
 * Registers a method, or finds it registered.
 *
 * @param path  "/<package.Service>/<Method>", 1..2048 bytes; copied
 * @return the method's handle (>= 0), -EINVAL or -ENOMEM.
 */
int grpcasm_client_method(grpcasm_client *client, const char *path);

/**
 * Issues a unary call. The request is copied; nothing is sent yet (grpcasm_client_flush or
 * _poll sends, or the caller in bytes mode), so calls issued back to back leave in one send.
 *
 * @param method   a handle from grpcasm_client_method
 * @param request  the request message (protobuf bytes, without gRPC framing); may be NULL when
 *                 length is 0
 * @param length   its length, below 4 GiB
 * @param done     called once when the call completes (never NULL)
 * @param context  passed to done
 * @return 0 (done will run exactly once), or (done never runs) -EINVAL, -EMSGSIZE,
 *         -ESHUTDOWN (the server sent GOAWAY, or the connection used up its stream ids: open a
 *         new client), the connection's error once it failed, or -ENOMEM.
 */
int grpcasm_client_call(grpcasm_client *client, int method, const void *request, size_t length,
                        grpcasm_client_done_fn done, void *context);

/**
 * Issues a call and waits for it (socket mode). Other calls make progress meanwhile.
 *
 * @param timeout_ms  milliseconds before the call is cancelled and completes
 *                    DEADLINE_EXCEEDED; -1 waits without a limit
 * @return 0 when the call completed (done ran; its status says how), or what
 *         grpcasm_client_call returns, -EBUSY (from a callback) or -EBADF (bytes mode).
 */
int grpcasm_client_unary(grpcasm_client *client, int method, const void *request, size_t length,
                         grpcasm_client_done_fn done, void *context, int timeout_ms);

/**
 * Sends what is queued, waits for the server up to timeout_ms (0: not at all, -1: no limit),
 * processes what arrived, and sends again (socket mode).
 *
 * @return the number of calls completed (callbacks run), -EBUSY, -EBADF, or the connection's
 *         error once it ended and nothing completed.
 */
int grpcasm_client_poll(grpcasm_client *client, int timeout_ms);

/**
 * Sends what is queued without waiting (socket mode).
 *
 * @return 0 (all sent), 1 (the socket is full: wait for POLLOUT), -EBADF, or the error that
 *         ended the connection (its calls then completed UNAVAILABLE).
 */
int grpcasm_client_flush(grpcasm_client *client);

/** The client's socket for an event loop (socket mode), or -1 (bytes mode). */
int grpcasm_client_fd(const grpcasm_client *client);

/**
 * Processes bytes received from the server (bytes mode). They need not be whole frames, and
 * are only read during the call. Afterwards, send the output.
 *
 * @return the number of calls completed, -EBUSY, or the connection's error once it failed.
 */
int grpcasm_client_input(grpcasm_client *client, const uint8_t *data, size_t length);

/**
 * The bytes waiting to be sent (bytes mode): stores where they are in *data (when data is not
 * NULL) and returns how many. Valid until the next call into the client.
 */
size_t grpcasm_client_output(grpcasm_client *client, const uint8_t **data);

/** Reports that length bytes of the output were sent (bytes mode). */
void grpcasm_client_consume(grpcasm_client *client, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* GRPCASM_H */
