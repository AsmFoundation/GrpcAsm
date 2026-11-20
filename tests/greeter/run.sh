#!/usr/bin/env bash
# =============================================================================
# run.sh — the Greeter's end-to-end checks: the GrpcAsm engine tested the way
# any application uses it, with no KvAsm code in the server.
#
# Usage (inside the kvasm-toolchain image; tests/greeter.sh runs it there):
#   run.sh GREETER
#
# Phases (each starts a fresh server; any failure prints the server log and
# exits 1):
#   1. calls, every answer checked byte for byte with nghttp, an independent
#      HTTP/2 client: SayHello (a short, an empty and a 300-byte name, whose
#      lengths need two-byte varints), a malformed request, the built-in health
#      service ("", "helloworld.Greeter", an unknown name), an unknown method,
#      GET (405 + allow), a wrong content-type (415 + accept), and the
#      compressed flag without a grpc-encoding (INTERNAL); then the server must
#      stop with exit 0 after SIGTERM and count exactly the calls made
#   2. HTTP/2 conformance: h2spec must pass all 146 cases (no failure, no
#      skip), as KvAsm's suite requires of the same engine
#   3. startup refusals: invalid GREETER_PORT / GREETER_WORKERS (exit 2, named
#      in the log), a port another Greeter already serves (exit 1)
# Env: GREETER_TEST_PORT (default 50251); GREETER_MODE, passed on to the server
# (samples/GreeterNet): "service" changes one expectation, the malformed
# request's status (see phase 1).
# =============================================================================
set -euo pipefail

GREETER=${1:?usage: run.sh GREETER}
PORT=${GREETER_TEST_PORT:-50251}
WORK=$(mktemp -d)
PID=

# fail WHY [FILE] — report, show FILE and the server log, stop any server, exit 1.
fail() {
  echo "FAIL: $1" >&2
  if [[ -n "${2:-}" && -f "$2" ]]; then sed -n 1,60p "$2" >&2; fi
  if [[ -f "$WORK/server.log" ]]; then echo "--- server log" >&2; cat "$WORK/server.log" >&2; fi
  if [[ -n "$PID" ]]; then kill -KILL "$PID" 2>/dev/null || true; fi
  exit 1
}

# start_server NAME [VAR=VALUE...] — a fresh Greeter on $PORT, up when it logs "listening".
start_server() {
  local name=$1
  shift
  env GREETER_PORT="$PORT" "$@" "$GREETER" > "$WORK/server.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 100); do
    grep -q 'msg="listening"' "$WORK/server.log" && return 0
    kill -0 "$PID" 2>/dev/null || fail "$name: the server exited at startup"
    sleep 0.05
  done
  fail "$name: the server did not start"
}

# stop_server — SIGTERM; the server must exit 0 with its "stopped" line.
stop_server() {
  kill -TERM "$PID"
  local rc=0
  wait "$PID" || rc=$?
  PID=
  [[ $rc -eq 0 ]] || fail "the server exited $rc after SIGTERM"
  grep -q 'msg="stopped"' "$WORK/server.log" || fail "no stopped line after SIGTERM"
}

# call NAME PATH BODY [CTYPE] — one POST through nghttp. BODY is a printf
# format (\x escapes). Sets STATUS, GSTATUS, GMSG and HEX (the response body as
# lowercase hex). nghttp runs twice: -v for the headers, plain for the body.
call() {
  local name=$1 path=$2 body=$3 ctype=${4:-application/grpc}
  # shellcheck disable=SC2059 # the body is a printf format on purpose
  printf "$body" > "$WORK/req.bin"
  nghttp -v -H ':method: POST' -H "content-type: $ctype" -H 'te: trailers' \
         -d "$WORK/req.bin" "http://127.0.0.1:$PORT$path" > "$WORK/resp.txt" 2>&1 \
    || fail "$name: nghttp failed" "$WORK/resp.txt"
  STATUS=$(grep -a -o -E ':status: [0-9]+' "$WORK/resp.txt" | head -1 | cut -d' ' -f2)
  GSTATUS=$(grep -a -o -E 'grpc-status: [0-9]+' "$WORK/resp.txt" | head -1 | cut -d' ' -f2 || true)
  GMSG=$(grep -a -o -E 'grpc-message: .*' "$WORK/resp.txt" | head -1 | cut -d' ' -f2- || true)
  HEX=$(nghttp -H ':method: POST' -H "content-type: $ctype" -H 'te: trailers' \
          -d "$WORK/req.bin" "http://127.0.0.1:$PORT$path" 2>/dev/null | od -v -A n -t x1 | tr -d ' \n')
  CALLS=$((CALLS + 2))                  # two connections, two requests
}

# expect NAME STATUS GSTATUS HEX [MSG] — the last call's answer, exactly.
expect() {
  local name=$1 status=$2 gstatus=$3 hex=$4 msg=${5:-}
  [[ "$STATUS" == "$status" ]] || fail "$name: :status $STATUS, want $status" "$WORK/resp.txt"
  [[ "${GSTATUS:-}" == "$gstatus" ]] || fail "$name: grpc-status ${GSTATUS:-none}, want $gstatus" "$WORK/resp.txt"
  [[ "$HEX" == "$hex" ]] || fail "$name: body $HEX, want $hex" "$WORK/resp.txt"
  [[ -z "$msg" || "${GMSG:-}" == "$msg" ]] || fail "$name: grpc-message '${GMSG:-}', want '$msg'" "$WORK/resp.txt"
  echo "  ok: $name"
}

echo "greeter: phase 1 — calls, every answer exact"
CALLS=0
start_server calls GREETER_WORKERS=2
call "SayHello world" /helloworld.Greeter/SayHello '\x00\x00\x00\x00\x07\x0a\x05world'
expect "SayHello world" 200 0 000000000d0a0b48656c6c6f20776f726c64
call "SayHello, no name" /helloworld.Greeter/SayHello '\x00\x00\x00\x00\x00'
expect "SayHello, no name" 200 0 00000000080a0648656c6c6f20
# 300 bytes of 'a': the request's length is the varint ac 02; the answer's
# message is 306 bytes (b2 02) and its payload 309 (0x135).
NAME300=$(head -c 300 /dev/zero | tr '\0' 'a')
A300=$(printf '%s' "$NAME300" | od -v -A n -t x1 | tr -d ' \n')
call "SayHello, 300-byte name" /helloworld.Greeter/SayHello "\\x00\\x00\\x00\\x01\\x2f\\x0a\\xac\\x02$NAME300"
expect "SayHello, 300-byte name" 200 0 "00000001350ab20248656c6c6f20$A300"
call "SayHello, malformed" /helloworld.Greeter/SayHello '\x00\x00\x00\x00\x02\x0a\x09'
# The Greeters written against GrpcAsm's own APIs (assembly, C, GreeterNet's
# typed and raw modes) refuse a request they cannot parse INVALID_ARGUMENT.
# GreeterNet's "service" mode is a grpc-dotnet class bound through
# GrpcAsmServer.ServiceBinder, which answers as ASP.NET Core answers the same
# bytes: UNKNOWN "Exception was thrown by handler." (measured against Kestrel:
# tests/GrpcAsm.Net.Tests, ParityTests.A_malformed_request_is_refused_as_by_ASP_NET_Core).
if [[ ${GREETER_MODE:-} == service ]]; then
  expect "SayHello, malformed" 200 2 "" "Exception was thrown by handler."
else
  expect "SayHello, malformed" 200 3 "" "malformed request message"
fi
call "health, whole server" /grpc.health.v1.Health/Check '\x00\x00\x00\x00\x00'
expect "health, whole server" 200 0 00000000020801
call "health, helloworld.Greeter" /grpc.health.v1.Health/Check '\x00\x00\x00\x00\x14\x0a\x12helloworld.Greeter'
expect "health, helloworld.Greeter" 200 0 00000000020801
call "health, unknown service" /grpc.health.v1.Health/Check '\x00\x00\x00\x00\x06\x0a\x04nope'
expect "health, unknown service" 200 5 "" "unknown service"
call "unknown method" /helloworld.Greeter/SayGoodbye '\x00\x00\x00\x00\x07\x0a\x05world'
expect "unknown method" 200 12 "" "unknown method"
call "compressed flag, no encoding" /helloworld.Greeter/SayHello '\x01\x00\x00\x00\x07\x0a\x05world'
expect "compressed flag, no encoding" 200 13 "" "compressed flag set without a grpc-encoding"
call "wrong content-type" /helloworld.Greeter/SayHello '\x00\x00\x00\x00\x07\x0a\x05world' text/plain
[[ "$STATUS" == 415 && -z "${GSTATUS:-}" ]] || fail "wrong content-type: :status $STATUS grpc-status ${GSTATUS:-none}" "$WORK/resp.txt"
grep -a -q 'accept: application/grpc' "$WORK/resp.txt" || fail "415 without accept" "$WORK/resp.txt"
echo "  ok: wrong content-type"
nghttp -v "http://127.0.0.1:$PORT/" > "$WORK/resp.txt" 2>&1 || fail "GET: nghttp failed" "$WORK/resp.txt"
grep -a -q ':status: 405' "$WORK/resp.txt" || fail "GET: not 405" "$WORK/resp.txt"
grep -a -q 'allow: POST' "$WORK/resp.txt" || fail "GET: 405 without allow" "$WORK/resp.txt"
CALLS=$((CALLS + 1))
echo "  ok: GET is 405 with allow: POST"
stop_server
grep -q "msg=\"stopped\" connections=$CALLS requests=$CALLS " "$WORK/server.log" \
  || fail "the stopped line does not count the $CALLS calls"
echo "  ok: exit 0 after SIGTERM, $CALLS calls counted"

echo "greeter: phase 2 — HTTP/2 conformance (h2spec), all 146 cases"
start_server h2spec GREETER_WORKERS=2
# h2spec exits non-zero whenever anything fails; the JUnit report decides.
h2spec -h 127.0.0.1 -p "$PORT" -o 2 -j "$WORK/h2spec.xml" > "$WORK/h2spec.txt" 2>&1 || true
stop_server
grep -q "tests," "$WORK/h2spec.txt" || fail "h2spec did not run" "$WORK/h2spec.txt"
# JUnit: <testcase package=".." classname="..">, then <error> (failed) or
# <skipped> on the next line; a passing case closes on the same line.
awk '/<testcase /{
       match($0, /package="[^"]*"/);   p = substr($0, RSTART + 9, RLENGTH - 10)
       match($0, /classname="[^"]*"/); c = substr($0, RSTART + 11, RLENGTH - 12)
       w = 1; next }
     w && /<error>/   { print p " | " c; w = 0; next }
     w && /<skipped>/ { print "SKIPPED " p " | " c; w = 0; next }
     { w = 0 }' "$WORK/h2spec.xml" > "$WORK/h2spec.fail"
[[ ! -s "$WORK/h2spec.fail" ]] || fail "h2spec failures:
$(cat "$WORK/h2spec.fail")" "$WORK/h2spec.txt"
echo "  $(grep "tests," "$WORK/h2spec.txt")"

echo "greeter: phase 3 — startup refusals"
# refuse NAME EXIT LOGTEXT [VAR=VALUE...] — the server must exit EXIT, logging LOGTEXT.
refuse() {
  local name=$1 want=$2 text=$3
  shift 3
  local rc=0
  env GREETER_PORT="$PORT" "$@" timeout 5 "$GREETER" > "$WORK/refuse.log" 2>&1 || rc=$?
  [[ $rc -eq $want ]] || fail "$name: exit $rc, want $want" "$WORK/refuse.log"
  grep -q -- "$text" "$WORK/refuse.log" || fail "$name: no '$text' in the log" "$WORK/refuse.log"
  echo "  refused: $name (exit $want)"
}
refuse "port abc" 2 'name=GREETER_PORT' GREETER_PORT=abc
refuse "port 0" 2 'name=GREETER_PORT' GREETER_PORT=0
refuse "port 65536" 2 'name=GREETER_PORT' GREETER_PORT=65536
refuse "empty port" 2 'name=GREETER_PORT' GREETER_PORT=
refuse "workers 0" 2 'name=GREETER_WORKERS' GREETER_WORKERS=0
refuse "workers 257" 2 'name=GREETER_WORKERS' GREETER_WORKERS=257
start_server busy
refuse "port in use" 1 'port already in use'
stop_server
echo "greeter: all phases passed"
