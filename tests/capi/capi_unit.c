/*
 * capi_unit.c — the C ABI's contract without traffic: every documented error code of
 * grpcasm.h, the options' size and range rules, the process-wide server slot, a stop from
 * another thread, freeing a running server, and grpcasm_pb_bytes.
 *
 * Usage: capi_unit PORT   (two consecutive free ports, PORT and PORT + 1)
 * Exit status: 0 when every check passes; each failure is printed with its line.
 * Built and run by tests/capi/run.sh inside the toolchain image.
 */
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "grpcasm.h"

static int failures;

/** Records a failed check, with the expression and its line. */
#define CHECK(cond)                                                     \
  do {                                                                  \
    if (!(cond)) {                                                      \
      fprintf(stderr, "  FAIL line %d: %s\n", __LINE__, #cond);         \
      failures++;                                                       \
    }                                                                   \
  } while (0)

/** A handler that is never called here: the unit checks make no calls. */
static int never(void *context, grpcasm_call *call, const uint8_t *request, size_t length) {
  (void)context; (void)request; (void)length;
  return grpcasm_call_fail(call, 13, "unexpected") < 0 ? -1 : 0;
}

/**
 * Whether something accepts TCP connections on 127.0.0.1:port.
 * @return 1 when a connect succeeds, else 0.
 */
static int listening(uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return 0;
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int ok = connect(fd, (struct sockaddr *)&a, sizeof a) == 0;
  close(fd);
  return ok;
}

/** What the stopping thread is given and returns. */
typedef struct stopper {
  grpcasm_server *server;
  uint64_t totals[3];
} stopper;

/** Thread body: stops the server (grpcasm_server_stop from a thread that did not start it). */
static void *stop_thread(void *arg) {
  stopper *s = arg;
  grpcasm_server_stop(s->server, s->totals);
  return NULL;
}

/** Creates a server on a port with one route, or reports the failure. */
static grpcasm_server *make(uint16_t port) {
  grpcasm_options o = {.size = sizeof o, .port = port};
  grpcasm_server *s = NULL;
  CHECK(grpcasm_server_new(&o, &s) == 0);
  if (s) CHECK(grpcasm_server_add_unary(s, "/test.Api/Echo", never, NULL) == 0);
  return s;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: capi_unit PORT\n");
    return 2;
  }
  uint16_t port = (uint16_t)atoi(argv[1]);

  /* version */
  CHECK(grpcasm_version() == ((GRPCASM_VERSION_MAJOR << 16) | (GRPCASM_VERSION_MINOR << 8) |
                              GRPCASM_VERSION_PATCH));

  /* grpcasm_server_new: defaults, the size rule, ranges */
  grpcasm_server *s = NULL;
  CHECK(grpcasm_server_new(NULL, &s) == 0 && s != NULL);
  grpcasm_server_free(s);
  CHECK(grpcasm_server_new(NULL, NULL) == -EINVAL);
  grpcasm_options o = {.size = 2};
  CHECK(grpcasm_server_new(&o, &s) == -EINVAL && s == NULL);
  o = (grpcasm_options){.size = 4, .port = 70000};  /* size 4: port is beyond it, ignored */
  CHECK(grpcasm_server_new(&o, &s) == 0);
  grpcasm_server_free(s);
  o = (grpcasm_options){.size = sizeof o, .port = 70000};
  CHECK(grpcasm_server_new(&o, &s) == -EINVAL);
  o = (grpcasm_options){.size = sizeof o, .workers = 257};
  CHECK(grpcasm_server_new(&o, &s) == -EINVAL);
  o = (grpcasm_options){.size = sizeof o, .max_streams = 1001};
  CHECK(grpcasm_server_new(&o, &s) == -EINVAL);
  o = (grpcasm_options){.size = sizeof o, .shutdown_grace_seconds = 3601};
  CHECK(grpcasm_server_new(&o, &s) == -EINVAL);
  o = (grpcasm_options){.size = sizeof o, .idle_timeout_seconds = 86401};
  CHECK(grpcasm_server_new(&o, &s) == -EINVAL);
  o = (grpcasm_options){.size = sizeof o, .idle_timeout_seconds = UINT32_MAX};  /* never */
  CHECK(grpcasm_server_new(&o, &s) == 0);
  grpcasm_server_free(s);
  o = (grpcasm_options){.size = sizeof o, .connection_buffer_mb = 1, .max_message_bytes = 2 << 20};
  CHECK(grpcasm_server_new(&o, &s) == -EINVAL);  /* a message larger than the buffer */
  o = (grpcasm_options){.size = sizeof o, .connection_buffer_mb = 4097};
  CHECK(grpcasm_server_new(&o, &s) == -EINVAL);

  /* grpcasm_server_add_unary: paths, duplicates, capacity */
  CHECK(grpcasm_server_new(NULL, &s) == 0);
  const char *bad[] = {"", "/", "/a", "/a/", "//m", "/a/b/c", "a/b", "/a//"};
  for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
    if (grpcasm_server_add_unary(s, bad[i], never, NULL) != -EINVAL) {
      fprintf(stderr, "  FAIL: path '%s' was accepted\n", bad[i]);
      failures++;
    }
  }
  CHECK(grpcasm_server_add_unary(NULL, "/a/b", never, NULL) == -EINVAL);
  CHECK(grpcasm_server_add_unary(s, NULL, never, NULL) == -EINVAL);
  CHECK(grpcasm_server_add_unary(s, "/a/b", NULL, NULL) == -EINVAL);
  CHECK(grpcasm_server_add_unary(s, "/a/b", never, NULL) == 0);
  CHECK(grpcasm_server_add_unary(s, "/a/b", never, NULL) == -EEXIST);
  char path[300];
  for (int i = 1; i < 62; i++) {
    snprintf(path, sizeof path, "/svc%d/m", i);
    CHECK(grpcasm_server_add_unary(s, path, never, NULL) == 0);
  }
  CHECK(grpcasm_server_add_unary(s, "/one/more", never, NULL) == -ENOSPC);
  grpcasm_server_free(s);
  CHECK(grpcasm_server_new(NULL, &s) == 0);
  memset(path, 'x', sizeof path);
  path[0] = '/';
  path[100] = '/';
  path[255] = '\0';  /* 255 bytes: the longest path */
  CHECK(grpcasm_server_add_unary(s, path, never, NULL) == 0);
  memset(path, 'y', sizeof path);
  path[0] = '/';
  path[100] = '/';
  path[256] = '\0';  /* 256 bytes: one too many */
  CHECK(grpcasm_server_add_unary(s, path, never, NULL) == -EINVAL);
  grpcasm_server_free(s);

  /* lifecycle: start, the process's one slot, a stop from another thread */
  grpcasm_server *a = make(port), *b = make((uint16_t)(port + 1));
  CHECK(a && b);
  CHECK(grpcasm_server_start(NULL) == -EINVAL);
  CHECK(grpcasm_server_start(a) == 0);
  CHECK(listening(port));
  CHECK(grpcasm_server_start(a) == -EBUSY);        /* already started */
  CHECK(grpcasm_server_start(b) == -EBUSY);        /* another server runs here */
  CHECK(grpcasm_server_add_unary(a, "/late/m", never, NULL) == -EBUSY);
  stopper st = {.server = a};
  pthread_t t;
  CHECK(pthread_create(&t, NULL, stop_thread, &st) == 0);
  pthread_join(t, NULL);
  CHECK(st.totals[0] >= 1);                        /* listening() connected once */
  CHECK(!listening(port));
  CHECK(grpcasm_server_start(a) == -EBUSY);        /* a stopped server does not restart */
  grpcasm_server_stop(a, NULL);                    /* a second stop is a no-op */
  CHECK(grpcasm_server_start(b) == 0);             /* the slot was released */
  CHECK(listening((uint16_t)(port + 1)));
  grpcasm_server_free(b);                          /* frees a running server: stops it */
  CHECK(!listening((uint16_t)(port + 1)));
  grpcasm_server *c = make(port);
  CHECK(c && grpcasm_server_start(c) == 0);        /* and released the slot */
  grpcasm_server_free(c);
  grpcasm_server_free(a);
  grpcasm_server_free(NULL);

  /* grpcasm_pb_bytes: {1: "abc", 2: "z"} */
  const uint8_t msg[] = {0x0A, 3, 'a', 'b', 'c', 0x12, 1, 'z'};
  const uint8_t *v;
  size_t n;
  CHECK(grpcasm_pb_bytes(msg, sizeof msg, 1, &v, &n) == 1 && n == 3 && memcmp(v, "abc", 3) == 0);
  CHECK(grpcasm_pb_bytes(msg, sizeof msg, 2, &v, &n) == 1 && n == 1 && v[0] == 'z');
  CHECK(grpcasm_pb_bytes(msg, sizeof msg, 3, &v, &n) == 0 && v == NULL && n == 0);
  CHECK(grpcasm_pb_bytes(msg, 4, 1, &v, &n) == -EINVAL);   /* truncated */
  CHECK(grpcasm_pb_bytes(msg, sizeof msg, 0, &v, &n) == -EINVAL);
  CHECK(grpcasm_pb_bytes(msg, sizeof msg, 1, NULL, &n) == -EINVAL);
  CHECK(grpcasm_pb_bytes(NULL, 0, 1, &v, &n) == 0);        /* the empty message */

  if (failures) {
    fprintf(stderr, "capi_unit: %d check(s) failed\n", failures);
    return 1;
  }
  printf("capi_unit: all checks passed\n");
  return 0;
}
