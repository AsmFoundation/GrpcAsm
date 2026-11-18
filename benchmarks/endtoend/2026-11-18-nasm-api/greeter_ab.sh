#!/usr/bin/env bash
# =============================================================================
# greeter_ab.sh — SayHello end to end: the Greeter before milestone C3
# (hand-written hooks, its reply framed by ga_h2n_reply_parts from a head on
# the stack) against the Greeter on the NASM API (grpcasm.inc: the handler is
# ga_app_unary by alias, the reply written in place), with h2load, in
# interleaved rounds, inside kvasm-toolchain. cabi_bench.sh's method
# (benchmarks/endtoend/2026-11-17-c-abi).
#
# Usage: greeter_ab.sh ROUNDS
# Mounts: /v/before/greeter, /v/after/greeter (the two binaries), /out (results)
#
# Each round starts each server on one worker pinned to the last vCPU, drives
# it with h2load (8 connections x 32 streams, 400,000 requests) pinned to the
# two vCPUs below, and records req/s. The order alternates between rounds.
# Prints the median, min and max per variant and the per-round ratio.
# =============================================================================
set -euo pipefail
ROUNDS=${1:-8}
W=/tmp/b
mkdir -p "$W"
for v in before after; do cp "/v/$v/greeter" "$W/$v" && chmod +x "$W/$v"; done
printf '\x00\x00\x00\x00\x07\x0a\x05world' > "$W/req.bin"
N=$(nproc); SERVER_CPU=$((N - 1)); LOAD_CPUS="$((N - 3)),$((N - 2))"
echo "server on vCPU $SERVER_CPU (1 worker), h2load on $LOAD_CPUS; $ROUNDS rounds" | tee /out/greeter_ab.txt

# run VARIANT — one h2load run against that Greeter; prints req/s.
run() {
  GREETER_PORT=50491 GREETER_WORKERS=1 taskset -c "$SERVER_CPU" "$W/$1" > "$W/$1.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 100); do grep -q 'msg="listening"' "$W/$1.log" && break; sleep 0.05; done
  local out
  out=$(taskset -c "$LOAD_CPUS" h2load -n 400000 -c 8 -m 32 -t 2 -d "$W/req.bin" \
          -H 'content-type: application/grpc' -H 'te: trailers' \
          http://127.0.0.1:50491/helloworld.Greeter/SayHello 2>&1)
  kill -TERM "$pid"; wait "$pid" || true
  echo "$out" | grep -q '400000 succeeded' || { echo "FAIL: $1 did not answer every request" >&2; echo "$out" >&2; exit 1; }
  echo "$out" | grep -o -E 'finished in [0-9.]+[a-z]+, [0-9.]+ req/s' | grep -o -E '[0-9.]+ req/s' | cut -d' ' -f1
}

declare -A rps=()
for r in $(seq 1 "$ROUNDS"); do
  if (( r % 2 )); then order=(before after); else order=(after before); fi
  declare -A this=()
  for v in "${order[@]}"; do this[$v]=$(run "$v"); rps[$v]+="${this[$v]} "; done
  awk -v r="$r" -v b="${this[before]}" -v a="${this[after]}" \
    'BEGIN { printf "round %d: before %.0f, after %.0f req/s, ratio %.3f\n", r, b, a, a / b }' | tee -a /out/greeter_ab.txt
done
for v in before after; do
  printf '%s\n' ${rps[$v]} | sort -g | awk -v v="$v" '{x[NR]=$1} END {printf "%-6s median %10.0f req/s   min %10.0f   max %10.0f   (%d rounds)\n", v, x[int((NR+1)/2)], x[1], x[NR], NR}' | tee -a /out/greeter_ab.txt
done
