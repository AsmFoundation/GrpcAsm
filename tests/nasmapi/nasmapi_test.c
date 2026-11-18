/*
 * nasmapi_test.c — the code grpcasm.inc generates, called directly (tests/nasmapi.sh).
 *
 * Built three times, once per service file, with -DVARIANT_TABLE, -DVARIANT_CHAIN or
 * -DVARIANT_ALIAS, and linked with that file's object and libgrpcasm.a (for ga_keyeq). No
 * server runs: the generated hooks are called with a fake Stream whose route byte is set, and
 * each handler reports which one ran (`hit`, its return value). What is checked:
 *   - the route table: every entry's path, route byte and order, and its end;
 *   - the dispatch: every route reaches its handler, through a jump table (TABLE), a compare
 *     chain (CHAIN) or an alias (ALIAS: the hook IS the handler, compared by address);
 *   - a route of the other kind, or an unused number, hits the jump table's trap (-1);
 *   - the streaming hooks: a chain over two end handlers (TABLE), aliases (ALIAS), the -1
 *     stubs when there is no streaming method (CHAIN);
 *   - the health check: every declared service, and near misses;
 *   - the default hooks, and a hook the application writes itself (ALIAS: GA_USES_HOOK).
 * Exit status 0 when every check passed.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* The engine's hooks, as the generated code defines them (grpcasm_hooks.inc). */
extern int ga_app_unary(void *conn, void *stream, const void *message, size_t length);
extern int ga_app_stream_data(void *conn, void *stream, const void *data, size_t length);
extern int ga_app_stream_end(void *conn, void *stream);
extern int ga_app_health_service(const char *name, size_t length);
extern int64_t ga_app_worker_init(void *worker);
extern int ga_app_batch_end(void *conn);
extern void ga_app_worker_fini(void *worker);
extern void ga_app_worker_resume(void *worker);
extern void ga_app_worker_pause(void *worker);
extern void ga_app_worker_tick(void *worker);
extern void ga_app_call_release(void *conn, void *stream);
extern const uint8_t ga_app_routes[];
extern int64_t hit;

static int g_failures;

/** CHECK(condition, printf-format, ...) — records a failure without stopping. */
#define CHECK(cond, ...)                                                                       \
  do {                                                                                         \
    if (!(cond)) {                                                                             \
      fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                                     \
      fprintf(stderr, __VA_ARGS__);                                                            \
      fputc('\n', stderr);                                                                     \
      g_failures++;                                                                            \
    }                                                                                          \
  } while (0)

/*
 * A fake Stream: the generated dispatch reads only Stream.method, the sixth quadword
 * (server.inc: next, prev, conn, id, flags, method). The handlers never touch it.
 */
static uint64_t g_stream[32];

/** Calls the unary dispatch for a route. @returns the handler's (or the trap's) result. */
static int unary(int route) {
  g_stream[5] = (uint64_t)route;
  hit = 0;
  return ga_app_unary(NULL, g_stream, NULL, 0);
}

/** Calls the streaming data dispatch for a route. @returns the result. */
static int stream_data(int route) {
  g_stream[5] = (uint64_t)route;
  hit = 0;
  return ga_app_stream_data(NULL, g_stream, NULL, 0);
}

/** Calls the streaming end dispatch for a route. @returns the result. */
static int stream_end(int route) {
  g_stream[5] = (uint64_t)route;
  hit = 0;
  return ga_app_stream_end(NULL, g_stream);
}

/** The expected route table: paths and route bytes, in order. */
typedef struct {
  const char *path;
  int route;
} Route;

/** Walks ga_app_routes ([length][route][path], a zero length at the end) against `want`. */
static void check_routes(const Route *want, int n) {
  const uint8_t *p = ga_app_routes;
  for (int i = 0; i < n; i++) {
    size_t len = strlen(want[i].path);
    CHECK(p[0] == len && p[1] == want[i].route && memcmp(p + 2, want[i].path, len) == 0,
          "route entry %d: want %s (%d), got length %u route %u", i, want[i].path, want[i].route,
          p[0], p[1]);
    p += 2 + p[0];
  }
  CHECK(p[0] == 0, "the route table does not end after %d entries", n);
}

/** Checks the health check's answer for a name. */
static void check_health(const char *name, int serving) {
  int got = ga_app_health_service(name, strlen(name));
  CHECK((got != 0) == serving, "health '%s': got %d, want %s", name, got,
        serving ? "SERVING" : "NOT_FOUND");
}

int main(void) {
#if defined(VARIANT_TABLE)
  const Route routes[] = {{"/test.Api/U1", 1},   {"/test.Api/U2", 2},   {"/test.Api/U3", 3},
                          {"/test.Api/S1", 0x44}, {"/test.Api/U4", 5},   {"/test.Api/U5", 6},
                          {"/test.Api/S2", 0x47}, {"/test.Other/U6", 8}, {"/test.Other/U7", 40}};
  check_routes(routes, 9);
  /* The jump table: every unary route to its handler. */
  const int unary_routes[] = {1, 2, 3, 5, 6, 8, 40};
  for (int i = 0; i < 7; i++) {
    int rc = unary(unary_routes[i]);
    CHECK(rc == i + 1 && hit == i + 1, "unary route %d: handler %lld (rc %d), want %d",
          unary_routes[i], (long long)hit, rc, i + 1);
  }
  /* A streaming route's number and an unused number land on the trap. */
  CHECK(unary(4) == -1 && hit == 0, "unary dispatch of route 4 (S1's number): rc should be -1");
  CHECK(unary(10) == -1 && hit == 0, "unary dispatch of the unused route 10: rc should be -1");
  CHECK(unary(63) == -1 && hit == 0, "unary dispatch of route 63: rc should be -1");
  /* The streaming chain: one shared data handler, two end handlers. */
  CHECK(stream_data(0x44) == 100 && stream_data(0x47) == 100, "stream data: shared handler");
  CHECK(stream_end(0x44) == 101 && hit == 101, "stream end S1: %lld", (long long)hit);
  CHECK(stream_end(0x47) == 102 && hit == 102, "stream end S2: %lld", (long long)hit);
  check_health("test.Api", 1);
  check_health("test.Other", 1);
  check_health("test.Ap", 0);
  check_health("test.Apj", 0);
  check_health("test.Otherx", 0);
  /* The default hooks: callable, with the engine's results. */
  CHECK(ga_app_worker_init(NULL) == 0, "default worker_init");
  CHECK(ga_app_batch_end(NULL) == 0, "default batch_end");
  ga_app_worker_fini(NULL);
  ga_app_worker_resume(NULL);
  ga_app_worker_pause(NULL);
  ga_app_worker_tick(NULL);
  ga_app_call_release(NULL, NULL);
#elif defined(VARIANT_CHAIN)
  const Route routes[] = {{"/test.Chain/A", 7}, {"/test.Chain/B", 8}, {"/test.Chain/C", 9}};
  check_routes(routes, 3);
  CHECK(unary(7) == 1 && hit == 1, "chain: route 7");
  CHECK(unary(8) == 2 && hit == 2, "chain: route 8");
  CHECK(unary(9) == 3 && hit == 3, "chain: route 9");
  /* No client-streaming method: the stubs end the connection. */
  CHECK(stream_data(0x41) == -1 && stream_end(0x41) == -1, "streaming stubs return -1");
  check_health("test.Chain", 1);
  check_health("test.Chai", 0);
#elif defined(VARIANT_ALIAS)
  extern int h_one(void *, void *, const void *, size_t);
  extern int h_up_data(void *, void *, const void *, size_t);
  extern int h_up_end(void *, void *);
  const Route routes[] = {{"/test.Alias/One", 1}, {"/test.Alias/Up", 0x42}};
  check_routes(routes, 2);
  /* One method of each kind: the hook is the handler itself, no instruction between. */
  CHECK((void *)ga_app_unary == (void *)h_one, "ga_app_unary is not h_one's address");
  CHECK((void *)ga_app_stream_data == (void *)h_up_data, "ga_app_stream_data is not h_up_data");
  CHECK((void *)ga_app_stream_end == (void *)h_up_end, "ga_app_stream_end is not h_up_end");
  CHECK(unary(1) == 1, "alias: unary");
  CHECK(stream_data(0x42) == 100 && stream_end(0x42) == 101, "alias: the streaming handlers");
  CHECK(ga_app_batch_end(NULL) == 77, "GA_USES_HOOK batch_end: the application's own runs");
  check_health("test.Alias", 1);
#else
#error "build with -DVARIANT_TABLE, -DVARIANT_CHAIN or -DVARIANT_ALIAS"
#endif
  if (g_failures) {
    fprintf(stderr, "nasmapi_test: %d check(s) failed\n", g_failures);
    return 1;
  }
  return 0;
}
