#!/usr/bin/env bash
# =============================================================================
# drift.sh — how a .NET Greeter's cost per call changes while it runs: one
# GreeterNet serves WINDOWS successive h2load runs of 400,000 calls, and the
# server's CPU time per call is printed for each window, with the time since
# the server started. This is how the tiered JIT's convergence time was found
# (results-drift/drift.txt), which sets bench.sh's warm-up.
#
# Usage (inside kvasm-toolchain, as bench.sh; mounts /net = GreeterNet
# published self-contained, /here = this folder for cpuns.c):
#   drift.sh MODE WINDOWS [VAR=VALUE...]
#     MODE     typed or raw (GREETER_MODE)
#     WINDOWS  how many 400,000-call windows
#     VAR=...  extra environment for the server, e.g.
#              DOTNET_TieredCompilation=0 or DOTNET_TieredPGO=0
# Example, from this folder after run.sh has published bin/greeter-net:
#   MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD/bin/greeter-net:/net:ro" \
#     -v "$PWD:/here:ro" kvasm-toolchain:latest bash /here/drift.sh typed 14
#
# Output: one line, "MODE ENV: <ns per call>@<seconds since start> ...".
# The server is pinned to the last vCPU and h2load to the two below, as in
# bench.sh. Each window opens new connections (a new h2load run).
# =============================================================================
set -euo pipefail
MODE=$1
WINDOWS=${2:-12}
shift 2
W=/tmp/d
mkdir -p "$W"
# Reused across calls in one container: a second drift.sh run skips the copy.
[[ -x "$W/net/GreeterNet" ]] || { cp -r /net "$W/net" && chmod +x "$W/net/GreeterNet"; }
[[ -x "$W/cpuns" ]] || gcc -O2 -o "$W/cpuns" /here/cpuns.c
printf '\x00\x00\x00\x00\x07\x0a\x05world' > "$W/req.bin"
N=$(nproc)
start=$(date +%s%N)
GREETER_MODE=$MODE GREETER_PORT=50392 GREETER_WORKERS=1 taskset -c $((N - 1)) env "$@" "$W/net/GreeterNet" > "$W/s.log" 2>&1 &
pid=$!
for _ in $(seq 1 200); do grep -q listening "$W/s.log" && break; sleep 0.05; done
line=""
for w in $(seq 1 "$WINDOWS"); do
  c0=$("$W/cpuns" $pid)
  out=$(taskset -c "$((N - 3)),$((N - 2))" h2load -n 400000 -c 8 -m 32 -t 2 -d "$W/req.bin" \
        -H 'content-type: application/grpc' -H 'te: trailers' http://127.0.0.1:50392/helloworld.Greeter/SayHello 2>&1)
  c1=$("$W/cpuns" $pid)
  echo "$out" | grep -q '400000 succeeded' || { echo "window $w failed"; exit 1; }
  line+=$(awk -v c=$((c1 - c0)) -v t=$(( ($(date +%s%N) - start) / 1000000 )) 'BEGIN{printf " %.0f@%.1fs", c/400000, t/1000}')
done
kill -TERM $pid
wait $pid
echo "$MODE ${*:-default}:$line"
