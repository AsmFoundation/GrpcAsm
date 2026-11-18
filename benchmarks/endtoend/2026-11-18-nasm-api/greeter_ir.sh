#!/usr/bin/env bash
# =============================================================================
# greeter_ir.sh — instructions per SayHello, exactly: each Greeter under
# callgrind serves two fixed loads (h2load), and the difference of the two
# totals divided by the difference of the request counts is the per-request
# cost. Startup, shutdown and the main thread cancel out. Callgrind counts
# instructions, not time, so the host's load does not enter the result.
#
# Usage: greeter_ir.sh [N1 N2]   (defaults 20000 and 120000 requests)
# Runs in kvasm-valgrind:local (valgrind 3.24, h2load).
# Mounts: /v/before/greeter, /v/after/greeter, /out (results)
# =============================================================================
set -euo pipefail
N1=${1:-20000}
N2=${2:-120000}
W=/tmp/ir
mkdir -p "$W"
printf '\x00\x00\x00\x00\x07\x0a\x05world' > "$W/req.bin"

# total VARIANT N — callgrind's instruction total for one server run of N requests.
total() {
  local v=$1 n=$2 out="$W/cg.$1.$2"
  cp "/v/$v/greeter" "$W/$v" && chmod +x "$W/$v"
  GREETER_PORT=50591 GREETER_WORKERS=1 valgrind --tool=callgrind --callgrind-out-file="$out" \
    "$W/$v" > "$W/$v.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 400); do grep -q 'msg="listening"' "$W/$v.log" && break; sleep 0.05; done
  h2load -n "$n" -c 4 -m 16 -t 1 -d "$W/req.bin" -H 'content-type: application/grpc' \
    -H 'te: trailers' http://127.0.0.1:50591/helloworld.Greeter/SayHello > "$W/h2load.$v.$n" 2>&1
  grep -q "$n succeeded" "$W/h2load.$v.$n" || { echo "FAIL: $v did not answer $n requests" >&2; exit 1; }
  kill -TERM "$pid"; wait "$pid" || true
  # callgrind writes one file per thread with --separate-threads=no (the default): one total.
  callgrind_annotate "$out" 2>/dev/null | awk '/PROGRAM TOTALS/ {gsub(",", "", $1); print $1; exit}'
}

for v in before after; do
  t1=$(total "$v" "$N1")
  t2=$(total "$v" "$N2")
  awk -v v="$v" -v t1="$t1" -v t2="$t2" -v n1="$N1" -v n2="$N2" \
    'BEGIN { printf "%-6s %d instructions at %d requests, %d at %d: %.1f per request\n", v, t1, n1, t2, n2, (t2 - t1) / (n2 - n1) }' \
    | tee -a /out/greeter_ir.txt
done
