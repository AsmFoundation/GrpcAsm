/*
 * capi_server.c — a test service for the C ABI's call functions, driven by tests/capi/run.sh
 * through nghttp. Each route exercises one part of the contract:
 *
 *   /test.Api/Echo    replies the request bytes, then checks that a second reply and a fail
 *                     are both refused with -EALREADY (if not, it ends the connection, which
 *                     the script sees)
 *   /test.Api/Fail    request = [status byte][message bytes]: grpcasm_call_fail with them; a
 *                     status the API refuses (-EINVAL) is answered OK with "EINVAL"
 *   /test.Api/Silent  returns without answering: the library must send INTERNAL
 *   /test.Api/Drop    returns -1: the library must end the connection
 *   /test.Api/Big     request = a decimal size: replies that many 'x' bytes
 *
 * Usage: CAPI_PORT=<port> capi_server   (serves until SIGTERM, then prints its counters)
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "grpcasm.h"

/** Echo: the request back, then two answers that must be refused. */
static int echo(void *context, grpcasm_call *call, const uint8_t *request, size_t length) {
  (void)context;
  if (grpcasm_call_reply(call, request, length) < 0) return -1;
  if (grpcasm_call_reply(call, request, length) != -EALREADY) return -1;
  if (grpcasm_call_fail(call, 2, "late") != -EALREADY) return -1;
  return 0;
}

/** Fail: [status][message] into grpcasm_call_fail. */
static int fail(void *context, grpcasm_call *call, const uint8_t *request, size_t length) {
  (void)context;
  if (length < 1) return grpcasm_call_fail(call, 3, "empty request") < 0 ? -1 : 0;
  char *message = malloc(length);
  if (!message) return -1;
  memcpy(message, request + 1, length - 1);
  message[length - 1] = '\0';
  int rc = grpcasm_call_fail(call, request[0], message);
  free(message);
  if (rc == -EINVAL) return grpcasm_call_reply(call, "EINVAL", 6) < 0 ? -1 : 0;
  return rc < 0 ? -1 : 0;
}

/** Silent: no answer; the library answers INTERNAL. */
static int silent(void *context, grpcasm_call *call, const uint8_t *request, size_t length) {
  (void)context; (void)call; (void)request; (void)length;
  return 0;
}

/** Drop: asks the library to end the connection. */
static int drop(void *context, grpcasm_call *call, const uint8_t *request, size_t length) {
  (void)context; (void)call; (void)request; (void)length;
  return -1;
}

/** Big: as many 'x' bytes as the request's decimal number says. */
static int big(void *context, grpcasm_call *call, const uint8_t *request, size_t length) {
  (void)context;
  char digits[24] = {0};
  memcpy(digits, request, length < sizeof digits - 1 ? length : sizeof digits - 1);
  size_t size = strtoull(digits, NULL, 10);
  char *reply = malloc(size ? size : 1);
  if (!reply) return -1;
  memset(reply, 'x', size);
  int rc = grpcasm_call_reply(call, reply, size);
  free(reply);
  return rc < 0 ? -1 : 0;
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  const char *port_text = getenv("CAPI_PORT");
  grpcasm_options o = {.size = sizeof o, .port = port_text ? (uint32_t)atoi(port_text) : 50061,
                       .workers = 2};
  grpcasm_server *s;
  if (grpcasm_server_new(&o, &s) < 0) return 1;
  struct { const char *path; grpcasm_unary_fn fn; } routes[] = {
      {"/test.Api/Echo", echo}, {"/test.Api/Fail", fail}, {"/test.Api/Silent", silent},
      {"/test.Api/Drop", drop}, {"/test.Api/Big", big}};
  for (size_t i = 0; i < sizeof routes / sizeof routes[0]; i++) {
    if (grpcasm_server_add_unary(s, routes[i].path, routes[i].fn, NULL) < 0) return 1;
  }
  uint64_t totals[3] = {0, 0, 0};
  int rc = grpcasm_server_run(s, totals);
  grpcasm_server_free(s);
  if (rc < 0) return 1;
  fprintf(stderr, "capi_server: stopped connections=%" PRIu64 " requests=%" PRIu64
                  " errors=%" PRIu64 "\n", totals[0], totals[1], totals[2]);
  return 0;
}
