#!/usr/bin/env bash
# =============================================================================
# run.sh — the client's checks, inside the kvasm-toolchain image
# (tests/client.sh runs it there).
#
# Usage: run.sh LIBDIR INCDIR GREETER CAPIDIR SRCDIR GREETER_CLIENT
#   LIBDIR   holds libgrpcasm.so          INCDIR   holds grpcasm.h
#   GREETER  the assembly Greeter binary  CAPIDIR  holds capi_server.c
#   SRCDIR   holds client_test.c          GREETER_CLIENT  the NASM client
#
# What runs: the Greeter and capi_server on their own ports, then client_test
# against both (and against the scripted server it starts itself), then the
# NASM client against the Greeter: an assembly client and an assembly server,
# no C between them. Both servers are stopped with SIGTERM afterwards and must
# exit 0: the client's traffic, including the connection it breaks on
# purpose, leaves them clean.
# =============================================================================
set -euo pipefail

USAGE="usage: run.sh LIBDIR INCDIR GREETER CAPIDIR SRCDIR GREETER_CLIENT"
LIB=${1:?$USAGE}
INC=${2:?$USAGE}
GREETER=${3:?$USAGE}
CAPI=${4:?$USAGE}
SRC=${5:?$USAGE}
GREETER_CLIENT=${6:?$USAGE}
W=$(mktemp -d)
GREETER_PORT=50291
CAPI_PORT=50292
PIDS=()

# fail WHY — report, show both servers' logs, stop them, exit 1.
fail() {
  echo "FAIL: $1" >&2
  for log in greeter capi; do
    [[ -f "$W/$log.log" ]] && { echo "--- $log log" >&2; tail -n 30 "$W/$log.log" >&2; }
  done
  for pid in "${PIDS[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
  exit 1
}

# wait_listening LOG PID — until the server logs that it listens.
wait_listening() {
  for _ in $(seq 1 100); do
    grep -q 'msg="listening"' "$1" && return 0
    kill -0 "$2" 2>/dev/null || fail "$1: the server exited at startup"
    sleep 0.05
  done
  fail "$1: the server did not start"
}

cp "$LIB/libgrpcasm.so" "$W/"
for program in "$CAPI/capi_server" "$SRC/client_test"; do
  name=$(basename "$program")
  gcc -std=c11 -O2 -Wall -Wextra -Werror -I "$INC" -o "$W/$name" "$program.c" \
      -L "$W" -lgrpcasm -pthread -Wl,-rpath,"\$ORIGIN" || fail "$name does not compile"
done

GREETER_PORT=$GREETER_PORT GREETER_WORKERS=2 "$GREETER" > "$W/greeter.log" 2>&1 &
PIDS+=($!)
wait_listening "$W/greeter.log" "${PIDS[0]}"
CAPI_PORT=$CAPI_PORT "$W/capi_server" > "$W/capi.log" 2>&1 &
PIDS+=($!)
wait_listening "$W/capi.log" "${PIDS[1]}"

"$W/client_test" "$GREETER_PORT" "$CAPI_PORT" || fail "client_test"

echo "client: phase 4 — the NASM client against the assembly Greeter"
out=$(GREETER_PORT=$GREETER_PORT "$GREETER_CLIENT" asm 2>&1) || fail "greeter_client: $out"
[[ "$out" == "Hello asm" ]] || fail "greeter_client printed '$out'"
out=$(GREETER_PORT=$GREETER_PORT "$GREETER_CLIENT" 2>&1) || fail "greeter_client: $out"
[[ "$out" == "Hello world" ]] || fail "greeter_client (default name) printed '$out'"
rc=0
out=$(GREETER_PORT=1 "$GREETER_CLIENT" 2>&1) || rc=$?
[[ $rc -eq 1 && "$out" == "greeter_client: connect failed, errno 111" ]] \
  || fail "greeter_client without a server: exit $rc, '$out'"
echo "  ok: Hello asm, Hello world, and ECONNREFUSED without a server"

for pid in "${PIDS[@]}"; do
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [[ $rc -eq 0 ]] || fail "a server exited $rc after SIGTERM"
done
PIDS=()
echo "client: all phases passed"
