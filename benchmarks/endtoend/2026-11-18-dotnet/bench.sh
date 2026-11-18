#!/usr/bin/env bash
# =============================================================================
# bench.sh — SayHello end to end on one engine, four ways to write the handler:
#   asm        samples/Greeter: the NASM API, the reply written in place
#   c          samples/GreeterC on libgrpcasm.so: a function pointer, malloc + copy
#   net-raw    samples/GreeterNet, GREETER_MODE=raw: a .NET handler through the
#              reverse call, GrpcAsmProtobuf for the name, the reply on the stack
#   net-typed  samples/GreeterNet, GREETER_MODE=typed: Google.Protobuf parses
#              HelloRequest and serializes HelloReply
# Runs inside kvasm-toolchain (run.sh starts it there), cabi_bench.sh's method
# (benchmarks/endtoend/2026-11-17-c-abi) with a warm-up and CPU time added.
#
# Usage: bench.sh ROUNDS
# Mounts: /g (samples/Greeter/bin/Release), /libga (libgrpcasm.so), /inc
#         (grpcasm.h), /src (samples/GreeterC), /net (GreeterNet, published
#         self-contained), /here (this folder: cpuns.c), /out (results)
# Environment (defaults in brackets):
#   VARIANTS ["asm c net-raw net-typed net-typed@DOTNET_TieredCompilation=0"]
#            the servers, in round-1 order; the first is the baseline of the
#            summary. A variant may carry extra environment for its server
#            after an @, comma-separated. The last default variant is the
#            warm-up's check: with tiering off, .NET compiles every method
#            optimized at once (no PGO), so the default net-typed must be at
#            least as cheap once its tiered JIT has converged.
#   WARMUP [7000000]  CALLS [2000000]  calls per run, warm-up and measured
#
# Each run starts a fresh server with one worker. The whole process is pinned
# to the last vCPU: a .NET server's GC, JIT and signal threads share that vCPU
# with its worker, so its numbers are the full cost of a call. h2load (8
# connections x 32 streams, 2 threads) runs on the two vCPUs below. The
# warm-up is long on purpose (about 10 s): with its background thread on the
# busy vCPU, .NET's tiered JIT (tier 0, instrumented tier, PGO-optimized tier
# 1) took 5 to 12 s to converge in drift runs, and a 200,000-call warm-up
# (0.3 s) measured the typed handler 356 ns per call too high
# (results-tiering-warmup-200k). Every server gets the same warm-up. The
# server's CPU time is read around the measured run (cpuns: every thread, in
# ns). The order rotates every round, so over as many rounds as there are
# variants each server holds each position once.
#
# Output: /out/raw.tsv (one line per run) and /out/bench.txt (the log and the
# summary: medians, paired per-round differences against the baseline).
# =============================================================================
set -euo pipefail
# run() executes in command substitutions; without this, errexit stops at
# their boundary and a failed step inside would go unnoticed.
shopt -s inherit_errexit
ROUNDS=${1:-10}
read -r -a VARIANTS <<< "${VARIANTS:-asm c net-raw net-typed net-typed@DOTNET_TieredCompilation=0}"
WARMUP=${WARMUP:-7000000}
CALLS=${CALLS:-2000000}
PORT=50391
W=/tmp/b
mkdir -p "$W"
cp /g/greeter "$W/asm" && chmod +x "$W/asm"
cp /libga/libgrpcasm.so "$W/"
gcc -std=c11 -O2 -Wall -Wextra -Werror -I /inc -o "$W/c" /src/greeter.c \
    -L "$W" -lgrpcasm -Wl,-rpath,"\$ORIGIN"
gcc -std=c11 -O2 -Wall -Wextra -Werror -o "$W/cpuns" /here/cpuns.c
cp -r /net "$W/net" && chmod +x "$W/net/GreeterNet"
printf '\x00\x00\x00\x00\x07\x0a\x05world' > "$W/req.bin"
N=$(nproc)
SERVER_CPU=$((N - 1))
LOAD_CPUS="$((N - 3)),$((N - 2))"
echo "server on vCPU $SERVER_CPU (1 worker, the whole process), h2load on $LOAD_CPUS;" \
     "$ROUNDS rounds; $WARMUP warm-up + $CALLS measured calls per run; variants: ${VARIANTS[*]}" | tee /out/bench.txt
printf 'round\tposition\tvariant\treq_per_s\tcpu_ns_per_call\tserver_util\n' > /out/raw.tsv

# load N — h2load, N SayHello("world") calls; prints its output.
load() {
  taskset -c "$LOAD_CPUS" h2load -n "$1" -c 8 -m 32 -t 2 -d "$W/req.bin" \
    -H 'content-type: application/grpc' -H 'te: trailers' \
    "http://127.0.0.1:$PORT/helloworld.Greeter/SayHello" 2>&1
}

# run VARIANT[@VAR=VALUE,...] — one fresh server, warm-up, measured run,
# SIGTERM. Prints "req/s cpu-ns-per-call server-utilization". Fails loudly on
# any call that did not succeed, a bad exit, or a stopped line that miscounts.
run() {
  local spec=$1 v=${1%%@*} cmd extra=()
  [[ $spec == *@* ]] && IFS=, read -r -a extra <<< "${spec#*@}"
  local log="$W/${spec//[^A-Za-z0-9_.-]/_}.log"
  case $v in
    asm) cmd=("$W/asm") ;;
    c) cmd=("$W/c") ;;
    net-raw) cmd=(env GREETER_MODE=raw "$W/net/GreeterNet") ;;
    net-typed) cmd=(env GREETER_MODE=typed "$W/net/GreeterNet") ;;
    *) echo "FAIL: unknown variant $v" >&2; exit 1 ;;
  esac
  # taskset and env exec the server: $! is the server's own pid.
  GREETER_PORT=$PORT GREETER_WORKERS=1 taskset -c "$SERVER_CPU" env "${extra[@]}" "${cmd[@]}" > "$log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 200); do grep -q 'msg="listening"' "$log" && break; sleep 0.05; done
  grep -q 'msg="listening"' "$log" || { echo "FAIL: $spec did not start" >&2; cat "$log" >&2; exit 1; }
  local out
  out=$(load "$WARMUP")
  echo "$out" | grep -q "$WARMUP succeeded" || { echo "FAIL: $spec warm-up" >&2; echo "$out" >&2; exit 1; }
  local c0 t0 c1 t1
  c0=$("$W/cpuns" "$pid"); t0=$(date +%s%N)
  out=$(load "$CALLS")
  t1=$(date +%s%N); c1=$("$W/cpuns" "$pid")
  echo "$out" | grep -q "$CALLS succeeded" || { echo "FAIL: $spec measured run" >&2; echo "$out" >&2; exit 1; }
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [[ $rc -eq 0 ]] || { echo "FAIL: $spec exited $rc after SIGTERM" >&2; cat "$log" >&2; exit 1; }
  grep -q "msg=\"stopped\" connections=16 requests=$((WARMUP + CALLS)) errors=0" "$log" \
    || { echo "FAIL: $spec's stopped line" >&2; cat "$log" >&2; exit 1; }
  local rps
  rps=$(echo "$out" | grep -o -E 'finished in [0-9.]+[a-z]+, [0-9.]+ req/s' | grep -o -E '[0-9.]+ req/s' | cut -d' ' -f1)
  awk -v r="$rps" -v c=$((c1 - c0)) -v t=$((t1 - t0)) -v n="$CALLS" \
    'BEGIN { printf "%s %.1f %.3f\n", r, c / n, c / t }'
}

K=${#VARIANTS[@]}
for r in $(seq 1 "$ROUNDS"); do
  for p in $(seq 0 $((K - 1))); do
    v=${VARIANTS[$(((r - 1 + p) % K))]}
    # An assignment, not "read < <(run)": a process substitution's failure
    # would be ignored, this one stops the benchmark (errexit).
    line=$(run "$v")
    read -r rps ns util <<< "$line"
    printf '%d\t%d\t%s\t%s\t%s\t%s\n' "$r" $((p + 1)) "$v" "$rps" "$ns" "$util" >> /out/raw.tsv
    printf 'round %2d  %-12s %10.0f req/s  %7.1f server-ns/call  server busy %5.1f%%\n' \
      "$r" "$v" "$rps" "$ns" "$(awk -v u="$util" 'BEGIN { print u * 100 }')" | tee -a /out/bench.txt
  done
done

# ---- summary ----
# Per variant: median and range of req/s and of the server's CPU ns per call;
# then the paired difference of CPU ns per call against the baseline (the
# first variant) within each round, whose median is the headline: a drift of
# the host that hits a whole round cancels out of it.
{
  echo
  printf '%-34s %12s %10s %10s %16s %26s\n' variant "median req/s" min max "server-ns/call" "paired extra ns/call [range]"
  awk -F'\t' -v variants="${VARIANTS[*]}" '
    function sort(a, n,   i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t } }
    function median(a, n) { return n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2 }
    NR > 1 { rps[$3, $1] = $4 + 0; ns[$3, $1] = $5 + 0; if ($1 > rounds) rounds = $1 }
    END {
      k = split(variants, order, " "); base = order[1]
      for (i = 1; i <= k; i++) {
        v = order[i]
        for (r = 1; r <= rounds; r++) { a[r] = rps[v, r]; b[r] = ns[v, r]; d[r] = ns[v, r] - ns[base, r] }
        sort(a, rounds); sort(b, rounds); sort(d, rounds)
        printf "%-34s %12.0f %10.0f %10.0f %16.1f %+12.1f [%+.1f .. %+.1f]\n", v, median(a, rounds), a[1], a[rounds], median(b, rounds), median(d, rounds), d[1], d[rounds]
      }
    }' /out/raw.tsv
} | tee -a /out/bench.txt
