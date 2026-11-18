/*
 * client_test.c — the gRPC client of libgrpcasm.so (grpcasm_client_*), end to end.
 *
 * Usage: client_test GREETER_PORT CAPI_PORT
 *   GREETER_PORT  the assembly Greeter (samples/Greeter), already listening on 127.0.0.1
 *   CAPI_PORT     tests/capi/capi_server, already listening on 127.0.0.1
 *
 * Phases:
 *   1. the Greeter: exact replies, a 20,000-call pipeline kept 128 deep from the callbacks,
 *      the health service, an unknown method, method handles, and the bytes-in/bytes-out
 *      mode driven over a socket of this program's own;
 *   2. capi_server: OK and error statuses, percent-decoded messages, a handler that does not
 *      answer, a 3 MiB response, max_response (RESOURCE_EXHAUSTED, then the connection still
 *      works), a 2 MiB request (request flow control), the concurrency queue, and a dropped
 *      connection (UNAVAILABLE, then calls are refused);
 *   3. a scripted HTTP/2 server inside this program, for what real servers rarely do:
 *      1xx responses, CONTINUATION, padding, Trailers-Only, the HTTP status mapping,
 *      RST_STREAM, malformed responses (and the client's RST_STREAM back), PING, GOAWAY,
 *      deadlines (and the client's RST_STREAM CANCEL), the server closing the connection,
 *      SETTINGS_HEADER_TABLE_SIZE 0 (the size update in the next header block) with
 *      SETTINGS_MAX_CONCURRENT_STREAMS 1 (the queue), and a response written one byte at a
 *      time (frames split across every read).
 *
 * Exit status: 0 when every check passed; each failure is printed with its line.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "grpcasm.h"

static int g_failures;

/** CHECK(condition, printf-format, ...) — records a failure without stopping the run. */
#define CHECK(cond, ...)                                                                       \
  do {                                                                                         \
    if (!(cond)) {                                                                             \
      fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                                     \
      fprintf(stderr, __VA_ARGS__);                                                            \
      fputc('\n', stderr);                                                                     \
      g_failures++;                                                                            \
    }                                                                                          \
  } while (0)

/* ---------------------------------------------------------------------------------------- */
/* Results                                                                                  */
/* ---------------------------------------------------------------------------------------- */

/** One call's completion, copied out of the callback (whose pointers die with it). */
typedef struct {
  int done;                 /**< completions seen: must end at exactly 1 */
  int status;
  char message[2048];
  size_t message_length;
  uint8_t *response;        /**< malloc'd copy, or NULL */
  size_t response_length;
} Result;

/** The done callback of most tests: copies the completion into a Result. */
static void on_done(void *context, int status, const char *message, size_t message_length,
                    const uint8_t *response, size_t response_length) {
  Result *r = context;
  r->done++;
  r->status = status;
  r->message_length = message_length < sizeof r->message ? message_length : sizeof r->message;
  if (message_length) memcpy(r->message, message, r->message_length);
  free(r->response);
  r->response = NULL;
  r->response_length = response_length;
  if (response_length) {
    r->response = malloc(response_length);
    memcpy(r->response, response, response_length);
  }
}

/** Resets a Result before a call. */
static void result_reset(Result *r) {
  free(r->response);
  memset(r, 0, sizeof *r);
}

/** True when the result is exactly (status, message, response). */
static int result_is(const Result *r, int status, const char *message, const void *response,
                     size_t response_length) {
  size_t mlen = message ? strlen(message) : 0;
  return r->done == 1 && r->status == status && r->message_length == mlen &&
         (mlen == 0 || memcmp(r->message, message, mlen) == 0) &&
         r->response_length == response_length &&
         (response_length == 0 || memcmp(r->response, response, response_length) == 0);
}

/** Prints a result for a failed check. */
static const char *describe(const Result *r) {
  static char text[256];
  snprintf(text, sizeof text, "done=%d status=%d message='%.*s' response=%zu bytes", r->done,
           r->status, (int)(r->message_length > 120 ? 120 : r->message_length), r->message,
           r->response_length);
  return text;
}

/** Polls until *done reaches want or timeout_ms passes. @return 0 on success, -1 on timeout. */
static int poll_until(grpcasm_client *c, const int *done, int want, int timeout_ms) {
  struct timespec t0, t;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  while (*done < want) {
    clock_gettime(CLOCK_MONOTONIC, &t);
    long elapsed = (t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000;
    if (elapsed >= timeout_ms) return -1;
    int rc = grpcasm_client_poll(c, (int)(timeout_ms - elapsed));
    if (rc < 0 && *done < want) return -1;
  }
  return 0;
}

/** Counts the done flags of n results. */
static int all_done(const Result *r, int n) {
  int sum = 0;
  for (int i = 0; i < n; i++) sum += r[i].done;
  return sum;
}

/* ---------------------------------------------------------------------------------------- */
/* Phase 1: the Greeter                                                                      */
/* ---------------------------------------------------------------------------------------- */

/** A HelloRequest{name}: tag 0x0A, length, bytes (names below 128 bytes). */
static size_t hello_request(uint8_t *out, const char *name) {
  size_t n = strlen(name);
  out[0] = 0x0A;
  out[1] = (uint8_t)n;
  memcpy(out + 2, name, n);
  return n + 2;
}

/** The pipeline: every completion checks its reply and issues the next call. */
typedef struct {
  grpcasm_client *client;
  int method;
  int issued, completed, wrong, total;
  int slot_name[128];       /**< the name number each slot's call carries */
} Pipeline;

typedef struct {
  Pipeline *p;
  int slot;
} Slot;

static Slot g_slots[128];

static void pipeline_issue(Pipeline *p, int slot);

static void pipeline_done(void *context, int status, const char *message, size_t message_length,
                          const uint8_t *response, size_t response_length) {
  (void)message;
  (void)message_length;
  Slot *s = context;
  Pipeline *p = s->p;
  char want[32];
  int n = snprintf(want, sizeof want, "Hello n%05d", p->slot_name[s->slot]);
  if (status != 0 || response_length != (size_t)n + 2 || response[0] != 0x0A ||
      response[1] != n || memcmp(response + 2, want, (size_t)n) != 0)
    p->wrong++;
  p->completed++;
  if (p->issued < p->total) pipeline_issue(p, s->slot);
}

static void pipeline_issue(Pipeline *p, int slot) {
  uint8_t req[32];
  char name[16];
  snprintf(name, sizeof name, "n%05d", p->issued);
  p->slot_name[slot] = p->issued;
  p->issued++;
  size_t len = hello_request(req, name);
  int rc = grpcasm_client_call(p->client, p->method, req, len, pipeline_done, &g_slots[slot]);
  CHECK(rc == 0, "pipeline call: %d", rc);
}

/** Bytes mode over a socket of our own: the client never sees the socket. */
static void bytes_mode(int port) {
  grpcasm_client *c = NULL;
  grpcasm_client_options options = {.size = sizeof options, .authority = "127.0.0.1"};
  CHECK(grpcasm_client_new(&options, &c) == 0 && c, "client_new");
  if (!c) return;
  CHECK(grpcasm_client_fd(c) == -1, "a bytes-mode client has no socket");
  CHECK(grpcasm_client_poll(c, 0) == -EBADF, "poll needs a socket");
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  CHECK(connect(fd, (struct sockaddr *)&a, sizeof a) == 0, "connect: %s", strerror(errno));
  int m = grpcasm_client_method(c, "/helloworld.Greeter/SayHello");
  Result r = {0};
  uint8_t req[32];
  size_t len = hello_request(req, "bytes");
  CHECK(grpcasm_client_call(c, m, req, len, on_done, &r) == 0, "call");
  uint8_t buf[65536];
  for (int i = 0; i < 1000 && !r.done; i++) {
    const uint8_t *out;
    size_t n = grpcasm_client_output(c, &out);
    if (n) {
      ssize_t w = write(fd, out, n);
      CHECK(w > 0, "write");
      grpcasm_client_consume(c, (size_t)w);
    }
    struct pollfd pfd = {.fd = fd, .events = POLLIN};
    if (poll(&pfd, 1, 1000) <= 0) continue;
    ssize_t got = read(fd, buf, sizeof buf);
    if (got <= 0) break;
    CHECK(grpcasm_client_input(c, buf, (size_t)got) >= 0, "input");
  }
  CHECK(result_is(&r, 0, NULL, "\x0a\x0bHello bytes", 13), "bytes mode: %s", describe(&r));
  close(fd);
  result_reset(&r);
  grpcasm_client_free(c);
}

static void phase_greeter(int port) {
  printf("client: phase 1 — the Greeter\n");
  grpcasm_client *c = NULL;
  int rc = grpcasm_client_connect("127.0.0.1", (uint16_t)port, NULL, &c);
  CHECK(rc == 0 && c, "connect: %d", rc);
  if (!c) return;
  CHECK(grpcasm_client_fd(c) >= 0, "a socket");
  int m = grpcasm_client_method(c, "/helloworld.Greeter/SayHello");
  CHECK(m >= 0, "method: %d", m);
  CHECK(grpcasm_client_method(c, "/helloworld.Greeter/SayHello") == m, "same path, same handle");
  CHECK(grpcasm_client_method(c, "") == -EINVAL, "empty path");
  CHECK(grpcasm_client_method(c, "nope") == -EINVAL, "path without '/'");
  CHECK(grpcasm_client_call(c, m + 100, "", 0, on_done, NULL) == -EINVAL, "unknown handle");
  CHECK(grpcasm_client_call(c, m, "", 0, NULL, NULL) == -EINVAL, "no callback");

  Result r = {0};
  uint8_t req[64];
  size_t len = hello_request(req, "world");
  CHECK(grpcasm_client_unary(c, m, req, len, on_done, &r, 5000) == 0, "unary");
  CHECK(result_is(&r, 0, NULL, "\x0a\x0bHello world", 13), "SayHello: %s", describe(&r));
  /* Again: this time the method's header block is the cached, all-indexed one. */
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, m, req, len, on_done, &r, 5000) == 0, "unary 2");
  CHECK(result_is(&r, 0, NULL, "\x0a\x0bHello world", 13), "SayHello again: %s", describe(&r));
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, m, NULL, 0, on_done, &r, 5000) == 0, "unary empty");
  CHECK(result_is(&r, 0, NULL, "\x0a\x06Hello ", 8), "no name: %s", describe(&r));
  printf("  ok: SayHello, twice, and without a name\n");

  int health = grpcasm_client_method(c, "/grpc.health.v1.Health/Check");
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, health, NULL, 0, on_done, &r, 5000) == 0, "health");
  CHECK(result_is(&r, 0, NULL, "\x08\x01", 2), "health SERVING: %s", describe(&r));
  int unknown = grpcasm_client_method(c, "/helloworld.Greeter/Nothing");
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, unknown, NULL, 0, on_done, &r, 5000) == 0, "unknown");
  CHECK(r.done == 1 && r.status == 12, "unknown method: %s", describe(&r));
  printf("  ok: health SERVING, unknown method UNIMPLEMENTED\n");

  Pipeline p = {.client = c, .method = m, .total = 20000};
  for (int i = 0; i < 128; i++) {
    g_slots[i].p = &p;
    g_slots[i].slot = i;
    pipeline_issue(&p, i);
  }
  CHECK(poll_until(c, &p.completed, p.total, 30000) == 0, "pipeline: %d of %d", p.completed,
        p.total);
  CHECK(p.wrong == 0, "pipeline: %d wrong replies", p.wrong);
  printf("  ok: %d pipelined calls, 128 in flight, every reply checked\n", p.completed);
  result_reset(&r);
  grpcasm_client_free(c);

  bytes_mode(port);
  printf("  ok: bytes in, bytes out, over our own socket\n");
}

/* ---------------------------------------------------------------------------------------- */
/* Phase 2: capi_server                                                                      */
/* ---------------------------------------------------------------------------------------- */

static void phase_capi(int port) {
  printf("client: phase 2 — capi_server\n");
  grpcasm_client *c = NULL;
  int rc = grpcasm_client_connect("127.0.0.1", (uint16_t)port, NULL, &c);
  CHECK(rc == 0 && c, "connect: %d", rc);
  if (!c) return;
  int echo = grpcasm_client_method(c, "/test.Api/Echo");
  int fail = grpcasm_client_method(c, "/test.Api/Fail");
  int silent = grpcasm_client_method(c, "/test.Api/Silent");
  int big = grpcasm_client_method(c, "/test.Api/Big");
  int drop = grpcasm_client_method(c, "/test.Api/Drop");
  Result r = {0};

  CHECK(grpcasm_client_unary(c, echo, "hello", 5, on_done, &r, 5000) == 0, "echo");
  CHECK(result_is(&r, 0, NULL, "hello", 5), "Echo: %s", describe(&r));
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, echo, NULL, 0, on_done, &r, 5000) == 0, "echo empty");
  CHECK(result_is(&r, 0, NULL, NULL, 0), "Echo empty: %s", describe(&r));
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, fail, "\x05not here", 9, on_done, &r, 5000) == 0, "fail");
  CHECK(result_is(&r, 5, "not here", NULL, 0), "Fail: %s", describe(&r));
  result_reset(&r);
  /* The server percent-encodes "a\nb%c\xff" as "a%0Ab%25c%FF"; the client decodes it. */
  CHECK(grpcasm_client_unary(c, fail, "\x03" "a\nb%c\xff", 7, on_done, &r, 5000) == 0, "fail%%");
  CHECK(result_is(&r, 3, "a\nb%c\xff", NULL, 0), "percent-decoding: %s", describe(&r));
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, silent, NULL, 0, on_done, &r, 5000) == 0, "silent");
  CHECK(result_is(&r, 13, "handler returned without a reply", NULL, 0), "Silent: %s",
        describe(&r));
  printf("  ok: OK, error statuses, percent-decoding, INTERNAL\n");

  result_reset(&r);
  CHECK(grpcasm_client_unary(c, big, "3145728", 7, on_done, &r, 10000) == 0, "big");
  int all_x = r.response_length == 3145728;
  for (size_t i = 0; all_x && i < r.response_length; i++) all_x = r.response[i] == 'x';
  CHECK(r.done == 1 && r.status == 0 && all_x, "Big: %s", describe(&r));
  printf("  ok: a 3 MiB response\n");

  /* A 2 MiB request: twice the server's stream window, so it waits for WINDOW_UPDATE. */
  size_t big_len = 2u << 20;
  uint8_t *big_req = malloc(big_len);
  for (size_t i = 0; i < big_len; i++) big_req[i] = (uint8_t)(i * 7);
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, echo, big_req, big_len, on_done, &r, 10000) == 0, "echo 2 MiB");
  CHECK(result_is(&r, 0, NULL, big_req, big_len), "Echo 2 MiB: %s", describe(&r));
  free(big_req);
  printf("  ok: a 2 MiB request, past the stream window\n");
  grpcasm_client_free(c);

  /* max_response: a 3 MiB response against a 1 MiB limit. */
  grpcasm_client_options small = {.size = sizeof small, .max_response_bytes = 1u << 20};
  CHECK(grpcasm_client_connect("127.0.0.1", (uint16_t)port, &small, &c) == 0, "connect small");
  echo = grpcasm_client_method(c, "/test.Api/Echo");
  big = grpcasm_client_method(c, "/test.Api/Big");
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, big, "3145728", 7, on_done, &r, 10000) == 0, "big small");
  CHECK(result_is(&r, 8, "response larger than max_response", NULL, 0), "too large: %s",
        describe(&r));
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, echo, "still", 5, on_done, &r, 5000) == 0, "echo after");
  CHECK(result_is(&r, 0, NULL, "still", 5), "after RESOURCE_EXHAUSTED: %s", describe(&r));
  printf("  ok: max_response cancels the call, the connection goes on\n");
  grpcasm_client_free(c);

  /* The concurrency queue: 50 calls, 2 at a time. */
  grpcasm_client_options two = {.size = sizeof two, .max_concurrent_calls = 2};
  CHECK(grpcasm_client_connect("127.0.0.1", (uint16_t)port, &two, &c) == 0, "connect two");
  echo = grpcasm_client_method(c, "/test.Api/Echo");
  drop = grpcasm_client_method(c, "/test.Api/Drop");
  Result many[50];
  memset(many, 0, sizeof many);
  char text[50][8];
  for (int i = 0; i < 50; i++) {
    snprintf(text[i], sizeof text[i], "m%02d", i);
    CHECK(grpcasm_client_call(c, echo, text[i], 3, on_done, &many[i]) == 0, "queue call %d", i);
  }
  int done = 0;
  for (int i = 0; i < 400 && done < 50; i++) {
    grpcasm_client_poll(c, 50);
    done = all_done(many, 50);
  }
  for (int i = 0; i < 50; i++)
    CHECK(result_is(&many[i], 0, NULL, text[i], 3), "queued %d: %s", i, describe(&many[i]));
  for (int i = 0; i < 50; i++) result_reset(&many[i]);
  printf("  ok: 50 calls through a 2-call limit\n");

  /* Drop: the server ends the connection; the call fails UNAVAILABLE, later calls refuse. */
  result_reset(&r);
  CHECK(grpcasm_client_unary(c, drop, NULL, 0, on_done, &r, 5000) == 0, "drop");
  CHECK(r.done == 1 && r.status == 14, "Drop: %s", describe(&r));
  rc = grpcasm_client_call(c, echo, "x", 1, on_done, &r);
  CHECK(rc < 0, "a call after the connection ended: %d", rc);
  CHECK(grpcasm_client_poll(c, 0) < 0, "poll after the connection ended");
  printf("  ok: a dropped connection fails its call UNAVAILABLE, then refuses calls\n");
  result_reset(&r);
  grpcasm_client_free(c);
}

/* ---------------------------------------------------------------------------------------- */
/* Phase 3: a scripted HTTP/2 server                                                         */
/* ---------------------------------------------------------------------------------------- */

/** One frame as the scripted server reads it. */
typedef struct {
  int type, flags;
  uint32_t sid;
  uint32_t length;
  uint8_t payload[16384 + 16];
} Frame;

/** The scripted server's state: its listening socket, scenario, and verdict. */
typedef struct {
  int listen_fd, port, scenario;
  char why[256];            /**< empty when every server-side check passed */
} Fake;

static int read_all(int fd, void *p, size_t n) {
  uint8_t *b = p;
  while (n) {
    ssize_t got = read(fd, b, n);
    if (got <= 0) return -1;
    b += got;
    n -= (size_t)got;
  }
  return 0;
}

static int write_all(int fd, const void *p, size_t n) {
  const uint8_t *b = p;
  while (n) {
    ssize_t w = write(fd, b, n);
    if (w <= 0) return -1;
    b += w;
    n -= (size_t)w;
  }
  return 0;
}

/** Writes one frame; @return 0 or -1. */
static int send_frame(int fd, int type, int flags, uint32_t sid, const void *payload, size_t n) {
  uint8_t h[9] = {(uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n, (uint8_t)type,
                  (uint8_t)flags,     (uint8_t)(sid >> 24), (uint8_t)(sid >> 16),
                  (uint8_t)(sid >> 8), (uint8_t)sid};
  if (write_all(fd, h, 9)) return -1;
  return n ? write_all(fd, payload, n) : 0;
}

/** Reads one frame; @return 0 or -1 (EOF, error, or the 5 s receive timeout). */
static int recv_frame(int fd, Frame *f) {
  uint8_t h[9];
  if (read_all(fd, h, 9)) return -1;
  f->length = (uint32_t)h[0] << 16 | (uint32_t)h[1] << 8 | h[2];
  f->type = h[3];
  f->flags = h[4];
  f->sid = ((uint32_t)h[5] << 24 | (uint32_t)h[6] << 16 | (uint32_t)h[7] << 8 | h[8]) &
           0x7FFFFFFF;
  if (f->length > 16384) return -1;
  return read_all(fd, f->payload, f->length);
}

/** An HPACK literal without indexing, new name (lengths below 127). @return its size. */
static size_t lit(uint8_t *p, const char *name, const char *value) {
  size_t n = strlen(name), v = strlen(value);
  p[0] = 0x00;
  p[1] = (uint8_t)n;
  memcpy(p + 2, name, n);
  p[2 + n] = (uint8_t)v;
  memcpy(p + 3 + n, value, v);
  return 3 + n + v;
}

/** A :status literal on the static name 8 (lengths below 127). @return its size. */
static size_t status_lit(uint8_t *p, const char *value) {
  p[0] = 0x08;
  p[1] = (uint8_t)strlen(value);
  memcpy(p + 2, value, p[1]);
  return 2 + p[1];
}

/** Sends a whole OK response carrying `message` (below 16 KiB) on stream sid. */
static int send_ok(int fd, uint32_t sid, const char *message) {
  uint8_t block[64], data[16384];
  size_t b = 0;
  block[b++] = 0x88; /* :status 200 */
  b += lit(block + b, "content-type", "application/grpc");
  size_t m = strlen(message);
  data[0] = 0;
  data[1] = (uint8_t)(m >> 24);
  data[2] = (uint8_t)(m >> 16);
  data[3] = (uint8_t)(m >> 8);
  data[4] = (uint8_t)m;
  memcpy(data + 5, message, m);
  uint8_t trailers[32];
  size_t t = lit(trailers, "grpc-status", "0");
  if (send_frame(fd, 1, 0x4, sid, block, b)) return -1;
  if (send_frame(fd, 0, 0, sid, data, m + 5)) return -1;
  return send_frame(fd, 1, 0x5, sid, trailers, t);
}

/** Accepts the client, checks its preface, sends our SETTINGS. @return the socket or -1. */
static int fake_accept(Fake *f, const uint8_t *settings, size_t settings_length) {
  int fd = accept(f->listen_fd, NULL, NULL);
  if (fd < 0) {
    snprintf(f->why, sizeof f->why, "accept: %s", strerror(errno));
    return -1;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  struct timeval tv = {.tv_sec = 5};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  char magic[24];
  if (read_all(fd, magic, 24) || memcmp(magic, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", 24)) {
    snprintf(f->why, sizeof f->why, "no client preface");
    close(fd);
    return -1;
  }
  send_frame(fd, 4, 0, 0, settings, settings_length);
  return fd;
}

/**
 * Reads frames until `count` HEADERS frames arrived; records their stream ids and the first
 * byte of their header blocks. @return 0 or -1.
 */
static int wait_headers(int fd, int count, uint32_t *sids, uint8_t *first_bytes) {
  Frame *fr = malloc(sizeof *fr);
  int seen = 0, rc = 0;
  while (seen < count) {
    if (recv_frame(fd, fr)) {
      rc = -1;
      break;
    }
    if (fr->type == 1) {
      if (sids) sids[seen] = fr->sid;
      if (first_bytes) first_bytes[seen] = fr->length ? fr->payload[0] : 0;
      seen++;
    }
  }
  free(fr);
  return rc;
}

/** Reads frames until one of `type` on `sid` (and, for RST_STREAM, with `code`). @return 0/-1. */
static int wait_frame(int fd, int type, uint32_t sid, int code) {
  Frame *fr = malloc(sizeof *fr);
  int rc = -1;
  while (recv_frame(fd, fr) == 0) {
    if (fr->type != type || fr->sid != sid) continue;
    if (type == 3) {
      uint32_t got = (uint32_t)fr->payload[0] << 24 | (uint32_t)fr->payload[1] << 16 |
                     (uint32_t)fr->payload[2] << 8 | fr->payload[3];
      if ((int)got != code) continue;
    }
    if (type == 6 && !(fr->flags & 1)) continue; /* a PING ACK, not a PING */
    rc = 0;
    break;
  }
  free(fr);
  return rc;
}

/**
 * Reads every frame that arrives within `ms` milliseconds. @return 1 when one of them was a
 * HEADERS frame (a stream opened), else 0.
 */
static int headers_within(int fd, int ms) {
  Frame *fr = malloc(sizeof *fr);
  int opened = 0;
  struct timeval quick = {.tv_usec = ms * 1000}, normal = {.tv_sec = 5};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &quick, sizeof quick);
  while (recv_frame(fd, fr) == 0)
    if (fr->type == 1) opened = 1;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &normal, sizeof normal);
  free(fr);
  return opened;
}

/** The scripted server's thread: one scenario, one connection. */
static void *fake_main(void *arg) {
  Fake *f = arg;
  f->why[0] = 0;
  uint32_t sids[8];
  uint8_t first[8];
  int fd = -1;
  switch (f->scenario) {
  case 1: { /* 1xx, CONTINUATION, padding, Trailers-Only, HTTP mapping, RST, malformed, PING */
    fd = fake_accept(f, NULL, 0);
    if (fd < 0) break;
    if (wait_headers(fd, 5, sids, NULL)) {
      snprintf(f->why, sizeof f->why, "5 HEADERS did not arrive");
      break;
    }
    send_frame(fd, 6, 0, 0, "pingpong", 8);
    uint8_t b[256];
    size_t n = status_lit(b, "100");
    send_frame(fd, 1, 0x4, sids[0], b, n);                /* informational: skipped */
    b[0] = 0x88;
    send_frame(fd, 1, 0x0, sids[0], b, 1);                /* :status 200, block continues */
    n = lit(b, "content-type", "application/grpc");
    send_frame(fd, 9, 0x4, sids[0], b, n);                /* CONTINUATION ends it */
    uint8_t padded[32] = {3, 0, 0, 0, 0, 4, 0x0A, 2, 'o', 'k', 0, 0, 0};
    send_frame(fd, 0, 0x8, sids[0], padded, 13);          /* PADDED DATA: 3 pad bytes */
    n = lit(b, "grpc-status", "0");
    send_frame(fd, 1, 0x5, sids[0], b, n);
    n = 0;
    b[n++] = 0x88;
    n += lit(b + n, "content-type", "application/grpc");
    n += lit(b + n, "grpc-status", "7");
    n += lit(b + n, "grpc-message", "no%20way");
    send_frame(fd, 1, 0x5, sids[1], b, n);                /* Trailers-Only */
    n = status_lit(b, "503");
    send_frame(fd, 1, 0x5, sids[2], b, n);                /* HTTP 503 -> UNAVAILABLE */
    uint8_t refused[4] = {0, 0, 0, 7};
    send_frame(fd, 3, 0, sids[3], refused, 4);            /* REFUSED_STREAM */
    n = lit(b, "content-type", "application/grpc");
    send_frame(fd, 1, 0x4, sids[4], b, n);                /* no :status: malformed */
    if (wait_frame(fd, 6, 0, 0)) {
      snprintf(f->why, sizeof f->why, "no PING ACK");
      break;
    }
    if (wait_frame(fd, 3, sids[4], 1))
      snprintf(f->why, sizeof f->why, "no RST_STREAM(PROTOCOL_ERROR) for the malformed response");
    break;
  }
  case 2: { /* GOAWAY: the last two calls of five were not processed */
    fd = fake_accept(f, NULL, 0);
    if (fd < 0) break;
    if (wait_headers(fd, 5, sids, NULL)) {
      snprintf(f->why, sizeof f->why, "5 HEADERS did not arrive");
      break;
    }
    uint8_t goaway[8] = {0, 0, 0, (uint8_t)sids[2], 0, 0, 0, 0};
    send_frame(fd, 7, 0, 0, goaway, 8);
    send_ok(fd, sids[0], "one");
    send_ok(fd, sids[1], "two");
    send_ok(fd, sids[2], "three");
    usleep(200000);
    break;
  }
  case 3: { /* a deadline, then the server closes the connection */
    fd = fake_accept(f, NULL, 0);
    if (fd < 0) break;
    if (wait_headers(fd, 2, sids, NULL)) {
      snprintf(f->why, sizeof f->why, "2 HEADERS did not arrive");
      break;
    }
    if (wait_frame(fd, 3, sids[1], 8))
      snprintf(f->why, sizeof f->why, "no RST_STREAM(CANCEL) after the deadline");
    break; /* closing the socket fails the other call UNAVAILABLE */
  }
  case 4: { /* SETTINGS_HEADER_TABLE_SIZE 0 and SETTINGS_MAX_CONCURRENT_STREAMS 1 */
    uint8_t settings[12] = {0, 1, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1};
    fd = fake_accept(f, settings, 12);
    if (fd < 0) break;
    for (int i = 0; i < 3; i++) {
      if (wait_headers(fd, 1, sids, first)) {
        snprintf(f->why, sizeof f->why, "call %d did not arrive", i);
        break;
      }
      /* Only the first block opens with the size update to 0 (0x20); the others start
       * with :method POST (0x83), and none may arrive before the previous call ends. */
      if (i == 0 && first[0] != 0x20) {
        snprintf(f->why, sizeof f->why, "first block starts 0x%02x, not 0x20", first[0]);
        break;
      }
      if (i > 0 && first[0] != 0x83) {
        snprintf(f->why, sizeof f->why, "block %d starts 0x%02x, not 0x83", i, first[0]);
        break;
      }
      /* 100 ms of the client's traffic (its DATA, its SETTINGS ACK): no HEADERS may be in
       * it while this call is open. */
      if (headers_within(fd, 100)) {
        snprintf(f->why, sizeof f->why, "a second stream opened over the limit of 1");
        break;
      }
      send_ok(fd, sids[0], "q");
    }
    break;
  }
  case 5: { /* a response written one byte at a time */
    fd = fake_accept(f, NULL, 0);
    if (fd < 0) break;
    if (wait_headers(fd, 1, sids, NULL)) {
      snprintf(f->why, sizeof f->why, "the call did not arrive");
      break;
    }
    /* Build the whole response, then write it byte by byte. */
    int pair[2];
    socketpair(AF_UNIX, SOCK_STREAM, 0, pair);
    char message[301];
    memset(message, 'z', 300);
    message[300] = 0;
    send_ok(pair[0], sids[0], message);
    shutdown(pair[0], SHUT_WR);
    uint8_t byte;
    while (read(pair[1], &byte, 1) == 1) {
      write_all(fd, &byte, 1);
      usleep(300);
    }
    close(pair[0]);
    close(pair[1]);
    usleep(200000);
    break;
  }
  }
  if (fd >= 0) close(fd);
  return NULL;
}

/** Starts the scripted server for one scenario; the caller joins the thread. */
static pthread_t fake_start(Fake *f, int scenario) {
  f->scenario = scenario;
  pthread_t t;
  pthread_create(&t, NULL, fake_main, f);
  return t;
}

static void phase_scripted(void) {
  printf("client: phase 3 — a scripted HTTP/2 server\n");
  Fake f = {0};
  f.listen_fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {.sin_family = AF_INET};
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  bind(f.listen_fd, (struct sockaddr *)&a, sizeof a);
  socklen_t alen = sizeof a;
  getsockname(f.listen_fd, (struct sockaddr *)&a, &alen);
  f.port = ntohs(a.sin_port);
  listen(f.listen_fd, 4);
  grpcasm_client *c = NULL;
  Result r[5];
  memset(r, 0, sizeof r);

  /* 1. Every response shape, and the client's answers to PING and to a malformed response. */
  pthread_t t = fake_start(&f, 1);
  CHECK(grpcasm_client_connect("127.0.0.1", (uint16_t)f.port, NULL, &c) == 0, "connect 1");
  int m = grpcasm_client_method(c, "/test.Script/Call");
  for (int i = 0; i < 5; i++)
    CHECK(grpcasm_client_call(c, m, "x", 1, on_done, &r[i]) == 0, "call %d", i);
  int done = 0;
  for (int i = 0; i < 100 && done < 5; i++) {
    grpcasm_client_poll(c, 50);
    done = all_done(r, 5);
  }
  for (int i = 0; i < 10; i++) grpcasm_client_poll(c, 20); /* the PING ACK and RST leave */
  CHECK(result_is(&r[0], 0, NULL, "\x0a\x02ok", 4), "1xx + CONTINUATION + padding: %s",
        describe(&r[0]));
  CHECK(result_is(&r[1], 7, "no way", NULL, 0), "Trailers-Only: %s", describe(&r[1]));
  CHECK(result_is(&r[2], 14, "HTTP status 503", NULL, 0), "HTTP 503: %s", describe(&r[2]));
  CHECK(result_is(&r[3], 14, "stream refused by the server", NULL, 0), "REFUSED_STREAM: %s",
        describe(&r[3]));
  CHECK(result_is(&r[4], 13, "malformed response", NULL, 0), "malformed: %s", describe(&r[4]));
  pthread_join(t, NULL);
  CHECK(f.why[0] == 0, "server, scenario 1: %s", f.why);
  grpcasm_client_free(c);
  printf("  ok: 1xx, CONTINUATION, padding, Trailers-Only, HTTP 503, REFUSED_STREAM, "
         "malformed + RST_STREAM, PING ACK\n");

  /* 2. GOAWAY. */
  for (int i = 0; i < 5; i++) result_reset(&r[i]);
  t = fake_start(&f, 2);
  CHECK(grpcasm_client_connect("127.0.0.1", (uint16_t)f.port, NULL, &c) == 0, "connect 2");
  m = grpcasm_client_method(c, "/test.Script/Call");
  for (int i = 0; i < 5; i++)
    CHECK(grpcasm_client_call(c, m, "x", 1, on_done, &r[i]) == 0, "call %d", i);
  done = 0;
  for (int i = 0; i < 100 && done < 5; i++) {
    grpcasm_client_poll(c, 50);
    done = all_done(r, 5);
  }
  CHECK(result_is(&r[0], 0, NULL, "one", 3), "under GOAWAY: %s", describe(&r[0]));
  CHECK(result_is(&r[1], 0, NULL, "two", 3), "under GOAWAY: %s", describe(&r[1]));
  CHECK(result_is(&r[2], 0, NULL, "three", 5), "the last stream id: %s", describe(&r[2]));
  CHECK(r[3].done == 1 && r[3].status == 14, "above GOAWAY: %s", describe(&r[3]));
  CHECK(r[4].done == 1 && r[4].status == 14, "above GOAWAY: %s", describe(&r[4]));
  CHECK(grpcasm_client_call(c, m, "x", 1, on_done, &r[0]) == -ESHUTDOWN, "a call after GOAWAY");
  pthread_join(t, NULL);
  CHECK(f.why[0] == 0, "server, scenario 2: %s", f.why);
  grpcasm_client_free(c);
  printf("  ok: GOAWAY finishes the processed calls, fails the others, refuses new ones\n");

  /* 3. A deadline, then the server leaves. */
  for (int i = 0; i < 5; i++) result_reset(&r[i]);
  t = fake_start(&f, 3);
  CHECK(grpcasm_client_connect("127.0.0.1", (uint16_t)f.port, NULL, &c) == 0, "connect 3");
  m = grpcasm_client_method(c, "/test.Script/Call");
  CHECK(grpcasm_client_call(c, m, "x", 1, on_done, &r[0]) == 0, "call");
  CHECK(grpcasm_client_unary(c, m, "y", 1, on_done, &r[1], 300) == 0, "unary");
  CHECK(result_is(&r[1], 4, "deadline exceeded", NULL, 0), "deadline: %s", describe(&r[1]));
  for (int i = 0; i < 100 && !r[0].done; i++) grpcasm_client_poll(c, 50);
  CHECK(result_is(&r[0], 14, "connection closed by the server", NULL, 0), "server left: %s",
        describe(&r[0]));
  CHECK(grpcasm_client_call(c, m, "x", 1, on_done, &r[2]) == -ECONNRESET, "a call after EOF");
  pthread_join(t, NULL);
  CHECK(f.why[0] == 0, "server, scenario 3: %s", f.why);
  grpcasm_client_free(c);
  printf("  ok: DEADLINE_EXCEEDED with RST_STREAM(CANCEL); the server leaving fails the rest\n");

  /* 4. A server table of 0 bytes and one stream at a time. */
  for (int i = 0; i < 5; i++) result_reset(&r[i]);
  t = fake_start(&f, 4);
  CHECK(grpcasm_client_connect("127.0.0.1", (uint16_t)f.port, NULL, &c) == 0, "connect 4");
  m = grpcasm_client_method(c, "/test.Script/Call");
  for (int i = 0; i < 3; i++)
    CHECK(grpcasm_client_call(c, m, "x", 1, on_done, &r[i]) == 0, "call %d", i);
  done = 0;
  for (int i = 0; i < 100 && done < 3; i++) {
    grpcasm_client_poll(c, 50);
    done = all_done(r, 3);
  }
  for (int i = 0; i < 3; i++)
    CHECK(result_is(&r[i], 0, NULL, "q", 1), "table 0, limit 1, call %d: %s", i,
          describe(&r[i]));
  pthread_join(t, NULL);
  CHECK(f.why[0] == 0, "server, scenario 4: %s", f.why);
  grpcasm_client_free(c);
  printf("  ok: HEADER_TABLE_SIZE 0 (size update, then literals), MAX_CONCURRENT_STREAMS 1\n");

  /* 5. A response that arrives one byte at a time. */
  for (int i = 0; i < 5; i++) result_reset(&r[i]);
  t = fake_start(&f, 5);
  CHECK(grpcasm_client_connect("127.0.0.1", (uint16_t)f.port, NULL, &c) == 0, "connect 5");
  m = grpcasm_client_method(c, "/test.Script/Call");
  CHECK(grpcasm_client_unary(c, m, "x", 1, on_done, &r[0], 10000) == 0, "unary");
  char zs[300];
  memset(zs, 'z', sizeof zs);
  CHECK(result_is(&r[0], 0, NULL, zs, 300), "byte by byte: %s", describe(&r[0]));
  pthread_join(t, NULL);
  CHECK(f.why[0] == 0, "server, scenario 5: %s", f.why);
  grpcasm_client_free(c);
  printf("  ok: a response split at every byte\n");
  for (int i = 0; i < 5; i++) result_reset(&r[i]);
  close(f.listen_fd);
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: client_test GREETER_PORT CAPI_PORT\n");
    return 2;
  }
  phase_greeter(atoi(argv[1]));
  phase_capi(atoi(argv[2]));
  phase_scripted();
  if (g_failures) {
    fprintf(stderr, "client_test: %d check(s) failed\n", g_failures);
    return 1;
  }
  printf("client_test: every check passed\n");
  return 0;
}
