#!/usr/bin/env bash
# =============================================================================
# run.sh — the C ABI's contract, end to end (inside the kvasm-toolchain image;
# tests/capi.sh runs it there).
#
# Usage: run.sh LIBDIR INCDIR SRCDIR
#   LIBDIR  holds libgrpcasm.so   INCDIR  holds grpcasm.h
#   SRCDIR  holds capi_unit.c and capi_server.c
#
# Phases:
#   1. capi_unit: every documented error code, the options' size and range
#      rules, the process's one server slot, a stop from another thread,
#      freeing a running server, grpcasm_pb_bytes (no traffic)
#   2. capi_server through nghttp, each answer checked exactly:
#      - reply, and the refusal of a second answer (-EALREADY);
#      - fail with a status and message, the percent-encoding of the message,
#        its 1,024-byte cap, and statuses the API refuses;
#      - a handler that does not answer (INTERNAL);
#      - one that ends its connection (the next connection is still served);
#      - a 3 MiB reply;
#      - health derived from the registered paths;
#      - an unknown method;
#      then a clean SIGTERM with the counters printed
# =============================================================================
set -euo pipefail

LIB=${1:?usage: run.sh LIBDIR INCDIR SRCDIR}
INC=${2:?usage: run.sh LIBDIR INCDIR SRCDIR}
SRC=${3:?usage: run.sh LIBDIR INCDIR SRCDIR}
W=$(mktemp -d)
PORT=50281
PID=

# fail WHY [FILE] — report, show FILE and the server's output, stop it, exit 1.
fail() {
  echo "FAIL: $1" >&2
  if [[ -n "${2:-}" && -f "$2" ]]; then sed -n 1,40p "$2" >&2; fi
  if [[ -f "$W/server.log" ]]; then echo "--- server log" >&2; cat "$W/server.log" >&2; fi
  if [[ -n "$PID" ]]; then kill -KILL "$PID" 2>/dev/null || true; fi
  exit 1
}

cp "$LIB/libgrpcasm.so" "$W/"
for program in capi_unit capi_server; do
  gcc -std=c11 -O2 -Wall -Wextra -Werror -I "$INC" -o "$W/$program" "$SRC/$program.c" \
      -L "$W" -lgrpcasm -pthread -Wl,-rpath,"\$ORIGIN" || fail "$program does not compile"
done

echo "capi: phase 1 — the API's contract (capi_unit)"
"$W/capi_unit" 50271 || fail "capi_unit"

echo "capi: phase 2 — the call functions through nghttp (capi_server)"
CAPI_PORT=$PORT "$W/capi_server" > "$W/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
  grep -q 'msg="listening"' "$W/server.log" && break
  kill -0 "$PID" 2>/dev/null || fail "capi_server exited at startup"
  sleep 0.05
done

# call NAME PATH BODY — a POST through nghttp; BODY is a printf format. Sets STATUS,
# GSTATUS, GMSG and HEX (the body as hex). nghttp runs twice: -v for the headers,
# plain for the body.
call() {
  local name=$1 path=$2 body=$3
  # shellcheck disable=SC2059 # the body is a printf format on purpose
  printf "$body" > "$W/req.bin"
  nghttp -v -H ':method: POST' -H 'content-type: application/grpc' -H 'te: trailers' \
         -d "$W/req.bin" "http://127.0.0.1:$PORT$path" > "$W/resp.txt" 2>&1 \
    || fail "$name: nghttp failed" "$W/resp.txt"
  STATUS=$(grep -a -o -E ':status: [0-9]+' "$W/resp.txt" | head -1 | cut -d' ' -f2)
  GSTATUS=$(grep -a -o -E 'grpc-status: [0-9]+' "$W/resp.txt" | head -1 | cut -d' ' -f2 || true)
  GMSG=$(grep -a -o -E 'grpc-message: .*' "$W/resp.txt" | head -1 | cut -d' ' -f2- || true)
  nghttp -H ':method: POST' -H 'content-type: application/grpc' -H 'te: trailers' \
         -d "$W/req.bin" "http://127.0.0.1:$PORT$path" > "$W/body.bin" 2>/dev/null || true
  HEX=$(od -v -A n -t x1 "$W/body.bin" | tr -d ' \n')
}

# expect NAME GSTATUS HEX [MSG] — the last call's answer, exactly.
expect() {
  local name=$1 gstatus=$2 hex=$3 msg=${4:-}
  [[ "$STATUS" == 200 ]] || fail "$name: :status $STATUS" "$W/resp.txt"
  [[ "${GSTATUS:-}" == "$gstatus" ]] || fail "$name: grpc-status ${GSTATUS:-none}, want $gstatus" "$W/resp.txt"
  [[ "$HEX" == "$hex" ]] || fail "$name: body $HEX, want $hex" "$W/resp.txt"
  [[ -z "$msg" || "${GMSG:-}" == "$msg" ]] || fail "$name: grpc-message '${GMSG:-}', want '$msg'" "$W/resp.txt"
  echo "  ok: $name"
}

call "reply, then two refused answers" /test.Api/Echo '\x00\x00\x00\x00\x05hello'
expect "reply, then two refused answers" 0 000000000568656c6c6f
call "fail with a status" /test.Api/Fail '\x00\x00\x00\x00\x09\x05not here'
expect "fail with a status" 5 "" "not here"
# '\n', '%' and 0xff are percent-encoded; the request is [3]["a\nb%c\xff"].
call "fail, percent-encoded" /test.Api/Fail '\x00\x00\x00\x00\x07\x03a\x0ab%%c\xff'
expect "fail, percent-encoded" 3 "" "a%0Ab%25c%FF"
call "status 0 refused" /test.Api/Fail '\x00\x00\x00\x00\x02\x00x'
expect "status 0 refused" 0 0000000006$(printf EINVAL | od -v -A n -t x1 | tr -d ' \n')
call "status 17 refused" /test.Api/Fail '\x00\x00\x00\x00\x02\x11x'
expect "status 17 refused" 0 0000000006$(printf EINVAL | od -v -A n -t x1 | tr -d ' \n')
LONG=$(head -c 2000 /dev/zero | tr '\0' 'm')
call "a 2,000-byte message is cut at 1,024" /test.Api/Fail "\\x00\\x00\\x00\\x07\\xd1\\x0d$LONG"
[[ ${#GMSG} -eq 1024 && "$GSTATUS" == 13 ]] || fail "message cap: ${#GMSG} bytes, status $GSTATUS" "$W/resp.txt"
echo "  ok: a 2,000-byte message is cut at 1,024"
call "no answer gets INTERNAL" /test.Api/Silent '\x00\x00\x00\x00\x00'
expect "no answer gets INTERNAL" 13 "" "handler returned without a reply"
printf '\x00\x00\x00\x00\x00' > "$W/req.bin"
nghttp -v -H ':method: POST' -H 'content-type: application/grpc' -H 'te: trailers' \
       -d "$W/req.bin" "http://127.0.0.1:$PORT/test.Api/Drop" > "$W/resp.txt" 2>&1 || true
grep -a -q 'grpc-status' "$W/resp.txt" && fail "Drop: the call was answered" "$W/resp.txt"
call "after a dropped connection" /test.Api/Echo '\x00\x00\x00\x00\x02ok'
expect "after a dropped connection" 0 00000000026f6b
echo "  ok: a handler that returns -1 ends its connection only"
call "a 3 MiB reply" /test.Api/Big '\x00\x00\x00\x00\x073145728'
SIZE=$(stat -c %s "$W/body.bin")
[[ "$GSTATUS" == 0 && "$SIZE" -eq $((3145728 + 5)) ]] || fail "Big: $SIZE bytes, status $GSTATUS" "$W/resp.txt"
[[ "$(tail -c +6 "$W/body.bin" | tr -d 'x' | wc -c)" -eq 0 ]] || fail "Big: not all 'x'"
echo "  ok: a 3 MiB reply"
call "health, a registered service" /grpc.health.v1.Health/Check '\x00\x00\x00\x00\x0a\x0a\x08test.Api'
expect "health, a registered service" 0 00000000020801
call "health, unknown" /grpc.health.v1.Health/Check '\x00\x00\x00\x00\x06\x0a\x04nope'
expect "health, unknown" 5 "" "unknown service"
call "unknown method" /test.Api/Nothing '\x00\x00\x00\x00\x00'
expect "unknown method" 12 "" "unknown method"

kill -TERM "$PID"
rc=0
wait "$PID" || rc=$?
PID=
[[ $rc -eq 0 ]] || fail "capi_server exited $rc after SIGTERM"
grep -q 'shutdown requested' "$W/server.log" || fail "no shutdown line"
grep -q 'capi_server: stopped connections=' "$W/server.log" || fail "no counters"
echo "  ok: exit 0 after SIGTERM ($(grep -o 'connections=.*' "$W/server.log"))"
echo "capi: all phases passed"
