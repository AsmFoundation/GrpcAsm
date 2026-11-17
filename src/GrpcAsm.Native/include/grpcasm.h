/*
 * grpcasm.h — the C ABI of GrpcAsm: a gRPC server whose HTTP/2, HPACK, gRPC and event-loop
 * engine is x86-64 assembly (libgrpcasm.so, Linux x86-64, glibc 2.34+).
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

#ifdef __cplusplus
}
#endif

#endif /* GRPCASM_H */
