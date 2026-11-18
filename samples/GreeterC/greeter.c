/*
 * greeter.c — helloworld.Greeter/SayHello in C, on libgrpcasm.so (grpcasm.h): the C ABI's
 * sample. It answers exactly as samples/Greeter (the assembly one) does, with the same
 * settings, log lines and exit codes, so tests/greeter/run.sh checks both
 * (tests/greeter_c.sh builds this one in the toolchain image and runs that suite on it).
 *
 * Build (Linux x86-64, glibc 2.34+):
 *   gcc -std=c11 -O2 -Wall -Wextra -Werror -I src/GrpcAsm.Native/include \
 *       -o greeter samples/GreeterC/greeter.c \
 *       -L src/GrpcAsm.Native/bin/Release/libc -lgrpcasm -Wl,-rpath,'$ORIGIN'
 *   (then put libgrpcasm.so next to the executable)
 *
 * Settings: GREETER_PORT (1..65535, default 50051) and GREETER_WORKERS (1..256, default 1),
 * parsed strictly; an invalid value is logged with its name and the process exits 2.
 */
#define _POSIX_C_SOURCE 200809L

#include <inttypes.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "grpcasm.h"

/**
 * Writes one log line in the engine's format, "ts=<seconds>.<ms> level=<LEVEL> <fields>",
 * with a single fprintf so lines from different threads do not interleave.
 * @param level  "INFO" or "ERROR"
 * @param format the fields, printf-style
 */
static void log_line(const char *level, const char *format, ...) {
  char fields[512];
  va_list args;
  va_start(args, format);
  vsnprintf(fields, sizeof fields, format, args);
  va_end(args);
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  fprintf(stderr, "ts=%lld.%03ld level=%s %s\n", (long long)now.tv_sec, now.tv_nsec / 1000000,
          level, fields);
}

/**
 * Reads a strict decimal setting: digits only (no sign, no whitespace), within [min, max].
 * @param name    the environment variable
 * @param min     the smallest value accepted
 * @param max     the largest value accepted
 * @param fallback the value when the variable is unset
 * @param value   receives the value
 * @return 0, or -1 when the variable is set but invalid (empty included).
 */
static int env_u32(const char *name, uint32_t min, uint32_t max, uint32_t fallback,
                   uint32_t *value) {
  const char *text = getenv(name);
  if (!text) {
    *value = fallback;
    return 0;
  }
  if (!*text) return -1;
  uint64_t v = 0;
  for (const char *p = text; *p; p++) {
    if (*p < '0' || *p > '9' || p - text >= 19) return -1;  /* 19 digits never overflow */
    v = v * 10 + (uint64_t)(*p - '0');
  }
  if (v < min || v > max) return -1;
  *value = (uint32_t)v;
  return 0;
}

/**
 * SayHello: HelloReply{message = "Hello " + HelloRequest.name}.
 * @param context  unused
 * @param call     the call, answered exactly once here
 * @param request  the HelloRequest (valid during this call only)
 * @param length   its length
 * @return 0, or -1 to end the connection (out of memory).
 */
static int say_hello(void *context, grpcasm_call *call, const uint8_t *request, size_t length) {
  (void)context;
  const uint8_t *name;
  size_t name_length;
  if (grpcasm_pb_bytes(request, length, 1, &name, &name_length) < 0) {
    return grpcasm_call_fail(call, 3, "malformed request message") < 0 ? -1 : 0;
  }
  /* HelloReply: tag 0x0A (field 1, length-delimited), the varint length of "Hello " + name,
     "Hello ", then the name. */
  size_t message_length = 6 + name_length;
  uint8_t head[16];
  size_t h = 0;
  head[h++] = 0x0A;
  for (size_t v = message_length;; v >>= 7) {
    if (v < 0x80) {
      head[h++] = (uint8_t)v;
      break;
    }
    head[h++] = (uint8_t)(v | 0x80);
  }
  memcpy(head + h, "Hello ", 6);
  h += 6;
  uint8_t *reply = malloc(h + name_length);
  if (!reply) return -1;
  memcpy(reply, head, h);
  if (name_length) memcpy(reply + h, name, name_length);
  int rc = grpcasm_call_reply(call, reply, h + name_length);
  free(reply);
  return rc < 0 ? -1 : 0;
}

/**
 * Settings, the server, SayHello, then serve until SIGTERM or SIGINT.
 * @return 0 after a clean shutdown, 1 when the server cannot start (the library logs why),
 *         2 on an invalid setting.
 */
int main(void) {
  signal(SIGPIPE, SIG_IGN);  /* sockets use MSG_NOSIGNAL too: belt and braces */
  uint32_t version = grpcasm_version();
  if ((version >> 8) != ((GRPCASM_VERSION_MAJOR << 8) | GRPCASM_VERSION_MINOR)) {
    log_line("ERROR", "msg=\"libgrpcasm version mismatch\" library=%" PRIu32 ".%" PRIu32,
             version >> 16, (version >> 8) & 0xFF);
    return 1;
  }
  uint32_t port, workers;
  if (env_u32("GREETER_PORT", 1, 65535, 50051, &port) < 0) {
    log_line("ERROR", "msg=\"invalid setting\" name=GREETER_PORT");
    return 2;
  }
  if (env_u32("GREETER_WORKERS", 1, 256, 1, &workers) < 0) {
    log_line("ERROR", "msg=\"invalid setting\" name=GREETER_WORKERS");
    return 2;
  }
  log_line("INFO", "msg=\"starting\" service=helloworld.Greeter port=%" PRIu32 " workers=%" PRIu32,
           port, workers);

  grpcasm_options options = {.size = sizeof options, .port = port, .workers = workers};
  grpcasm_server *server;
  int rc = grpcasm_server_new(&options, &server);
  if (rc < 0) {
    log_line("ERROR", "msg=\"cannot create the server\" error=%d", rc);
    return 1;
  }
  rc = grpcasm_server_add_unary(server, "/helloworld.Greeter/SayHello", say_hello, NULL);
  if (rc < 0) {
    log_line("ERROR", "msg=\"cannot register SayHello\" error=%d", rc);
    grpcasm_server_free(server);
    return 1;
  }
  uint64_t totals[3] = {0, 0, 0};
  rc = grpcasm_server_run(server, totals);
  grpcasm_server_free(server);
  if (rc < 0) return 1;  /* the library logged why (port in use, a worker that failed) */
  log_line("INFO", "msg=\"stopped\" connections=%" PRIu64 " requests=%" PRIu64 " errors=%" PRIu64,
           totals[0], totals[1], totals[2]);
  return 0;
}
