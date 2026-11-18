/*
 * grpcasm.c — kvbench's "grpcasm" protocol: gRPC over HTTP/2 cleartext through GrpcAsm's
 * client (libgrpcasm.so, grpcasm_client_*), in place of kvbench's own nghttp2 module (grpc.c).
 *
 * Why it exists: milestone D measures GrpcAsm's client against the client KvAsm benchmarks
 * with, kvbench on nghttp2. kvbench's protocol modules are bytes in, bytes out: the engine
 * owns the sockets, the epoll loop, the workload, the latency histograms and the validation,
 * and a module only turns requests into bytes and bytes into completions. This module does the
 * same with GrpcAsm's client in its bytes mode, so the threads, event loop, workload and
 * judging are identical between `--protocol grpc` and `--protocol grpcasm`; only the HTTP/2 and
 * gRPC client differs.
 *
 * The calls and their judging are grpc.c's: Get, Put and the health check, with GET values
 * verified byte for byte. The streaming workloads (--upload, --download) are not supported:
 * GrpcAsm's client has unary calls only (milestone D).
 *
 * Differences that belong to the clients, not to this module:
 *   - nghttp2's module copies each response into its slot; GrpcAsm's client hands the
 *     response over in place when it arrived within one read, so nothing is copied here;
 *   - GrpcAsm's client sends a call's HEADERS and DATA frames back to back.
 *
 * Built by build.sh in this folder, from a KvAsm checkout's kvbench sources plus this file.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <grpcasm.h>

#include "kvbench.h"

typedef struct GaConn GaConn;

/** One call in flight: what the completion needs to judge and record it. */
typedef struct {
  GaConn *g;
  uint8_t op;
  uint64_t key, t0;
  uint8_t *req;             /**< the request message (the client adds the gRPC framing) */
} GaSlot;

/** Per-connection state: the client and a fixed pool of call slots. */
struct GaConn {
  Conn *c;
  grpcasm_client *client;
  int m_get, m_put, m_ping;   /**< method handles */
  GaSlot *slots;
  uint32_t *free_list;
  uint32_t nfree, nslots;
  uint64_t now;             /**< receive time of the bytes being processed */
  int detaching;            /**< set while the client is freed: completions are dropped */
};

/**
 * Reads a protobuf varint without passing end (grpc.c's).
 * @param p    cursor, advanced on success
 * @param end  one past the last byte
 * @param out  receives the value
 * @returns 1 on success, 0 if truncated or overlong
 */
static int varint(const uint8_t **p, const uint8_t *end, uint64_t *out) {
  uint64_t v = 0;
  for (int shift = 0; shift < 64 && *p < end; shift += 7) {
    uint8_t b = *(*p)++;
    v |= (uint64_t)(b & 0x7F) << shift;
    if (!(b & 0x80)) {
      *out = v;
      return 1;
    }
  }
  return 0;
}

/**
 * Judges a finished call exactly as grpc.c's judge does, from the client's completion: a
 * gRPC status (the client already turned HTTP and transport failures into one) and the
 * response message without its 5-byte gRPC prefix (the client checked the framing).
 * @param op      OP_GET, OP_SET or OP_PING
 * @param key     key id (GET: the expected value)
 * @param status  gRPC status
 * @param m       response message
 * @param mlen    its length
 * @returns ST_OK, ST_MISS, ST_BAD_VALUE or ST_ERROR
 */
static int judge(int op, uint64_t key, int status, const uint8_t *m, size_t mlen) {
  if (status != 0) return ST_ERROR;
  const uint8_t *end = m + mlen;
  switch (op) {
  case OP_GET: { /* GetResponse{found = true (08 01), value (12 len bytes)} */
    if (mlen == 0) return ST_MISS;
    uint64_t vlen;
    if (end - m < 3 || m[0] != 0x08 || m[1] != 0x01 || m[2] != 0x12) return ST_BAD_VALUE;
    m += 3;
    if (!varint(&m, end, &vlen) || vlen != (uint64_t)(end - m)) return ST_BAD_VALUE;
    return value_ok(key, m, (size_t)vlen) ? ST_OK : ST_BAD_VALUE;
  }
  case OP_SET: /* PutResponse: created (08 01) or replaced (empty) */
    return mlen == 0 || (mlen == 2 && m[0] == 0x08 && m[1] == 0x01) ? ST_OK : ST_ERROR;
  default: /* HealthCheckResponse{status = SERVING} */
    return mlen == 2 && m[0] == 0x08 && m[1] == 0x01 ? ST_OK : ST_ERROR;
  }
}

/**
 * The client's done callback: judge, free the slot, record the completion.
 * @param context  the GaSlot
 * @param status   gRPC status
 * @param message  status message (unused: the outcome is judged, not logged)
 * @param message_length  its length
 * @param response  response message (valid only during this call)
 * @param response_length  its length
 */
static void ga_done(void *context, int status, const char *message, size_t message_length,
                    const uint8_t *response, size_t response_length) {
  (void)message;
  (void)message_length;
  GaSlot *sl = context;
  GaConn *g = sl->g;
  g->free_list[g->nfree++] = (uint32_t)(sl - g->slots);
  if (g->detaching) return; /* the run is over: grpcasm_client_free cancels what is left */
  int result = judge(sl->op, sl->key, status, response, response_length);
  complete(g->c, sl->op, sl->key, sl->t0, g->now, result);
}

/**
 * Creates the client (bytes mode) and the slot pool for a connected socket.
 * @param c  connection
 * @returns 0, or -1 on failure
 */
static int ga_attach(Conn *c) {
  if (g_opt.workload == WL_UPLOAD || g_opt.workload == WL_DOWNLOAD) {
    conn_fail(c, "grpcasm: streaming workloads are not supported (unary calls only)");
    return -1;
  }
  GaConn *g = calloc(1, sizeof *g);
  if (!g) return -1;
  g->c = c;
  g->nslots = (uint32_t)g_opt.depth;
  g->slots = calloc(g->nslots, sizeof *g->slots);
  g->free_list = calloc(g->nslots, sizeof *g->free_list);
  if (!g->slots || !g->free_list) return -1;
  size_t req_cap = 2 + KEY_BYTES + 1 + 10 + g_opt.value_size;
  for (uint32_t i = 0; i < g->nslots; i++) {
    g->slots[i].g = g;
    g->slots[i].req = malloc(req_cap);
    if (!g->slots[i].req) return -1;
    g->free_list[g->nfree++] = g->nslots - 1 - i;
  }
  /* The same :authority as grpc.c; responses of at most a value plus its framing. */
  grpcasm_client_options options = {
      .size = sizeof options,
      .max_response_bytes = 64 + g_opt.value_size,
      .max_concurrent_calls = (uint32_t)g_opt.depth,
      .authority = "kvasm",
  };
  if (grpcasm_client_new(&options, &g->client) != 0) return -1;
  g->m_get = grpcasm_client_method(g->client, "/kvasm.v1.KvAsm/Get");
  g->m_put = grpcasm_client_method(g->client, "/kvasm.v1.KvAsm/Put");
  g->m_ping = grpcasm_client_method(g->client, "/grpc.health.v1.Health/Check");
  if (g->m_get < 0 || g->m_put < 0 || g->m_ping < 0) return -1;
  c->proto_state = g;
  return 0;
}

/**
 * Frees the client and the slot pool.
 * @param c  connection
 */
static void ga_detach(Conn *c) {
  GaConn *g = c->proto_state;
  if (!g) return;
  g->detaching = 1;
  if (g->client) grpcasm_client_free(g->client);
  for (uint32_t i = 0; g->slots && i < g->nslots; i++) free(g->slots[i].req);
  free(g->slots);
  free(g->free_list);
  free(g);
  c->proto_state = NULL;
}

/**
 * Starts one call (grpc.c's requests, without the 5-byte prefix: the client frames them).
 * The engine never issues more than depth requests per connection, so a slot is free.
 * @param c    connection
 * @param op   OP_GET, OP_SET or OP_PING
 * @param key  key id
 * @param t0   start time
 */
static void ga_issue(Conn *c, int op, uint64_t key, uint64_t t0) {
  GaConn *g = c->proto_state;
  GaSlot *sl = &g->slots[g->free_list[--g->nfree]];
  sl->op = (uint8_t)op;
  sl->key = key;
  sl->t0 = t0;
  uint8_t *m = sl->req;
  size_t mlen = 0;
  if (op != OP_PING) {
    m[0] = 0x0A; /* field 1 (key), length-delimited */
    m[1] = KEY_BYTES;
    key_format((char *)m + 2, key);
    mlen = 2 + KEY_BYTES;
    if (op == OP_SET) {
      m[mlen++] = 0x12; /* field 2 (value) */
      uint32_t v = g_opt.value_size;
      while (v >= 0x80) {
        m[mlen++] = (uint8_t)(v | 0x80);
        v >>= 7;
      }
      m[mlen++] = (uint8_t)v;
      value_fill(m + mlen, key);
      mlen += g_opt.value_size;
    }
  }
  int method = op == OP_GET ? g->m_get : op == OP_SET ? g->m_put : g->m_ping;
  int rc = grpcasm_client_call(g->client, method, m, mlen, ga_done, sl);
  if (rc != 0) {
    g->free_list[g->nfree++] = (uint32_t)(sl - g->slots);
    complete(c, op, key, t0, now_ns(), ST_ERROR);
    conn_fail(c, "grpcasm: grpcasm_client_call failed");
  }
}

/**
 * Feeds received bytes to the client (its callbacks complete calls).
 * @param c     connection
 * @param data  received bytes
 * @param len   count
 * @param now   receive time
 * @returns 0, or -1 when the connection failed
 */
static int ga_input(Conn *c, const uint8_t *data, size_t len, uint64_t now) {
  GaConn *g = c->proto_state;
  g->now = now;
  int rc = grpcasm_client_input(g->client, data, len);
  if (rc < 0) {
    conn_fail(c, "grpcasm: the connection failed");
    return -1;
  }
  return 0;
}

/**
 * Moves the client's pending output (requests, acknowledgements, WINDOW_UPDATE) into the
 * connection's output buffer. The client has already framed it: one copy, no cap needed.
 * @param c  connection
 * @returns 0
 */
static int ga_collect(Conn *c) {
  GaConn *g = c->proto_state;
  const uint8_t *data;
  size_t n = grpcasm_client_output(g->client, &data);
  if (n) {
    out_put(c, data, n);
    grpcasm_client_consume(g->client, n);
  }
  return 0;
}

const Proto proto_grpcasm = {
    .name = "grpcasm",
    .attach = ga_attach,
    .detach = ga_detach,
    .issue = ga_issue,
    .input = ga_input,
    .collect = ga_collect,
    .parses_in_place = 0,
};
