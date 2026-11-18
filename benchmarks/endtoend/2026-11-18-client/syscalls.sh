#!/usr/bin/env bash
# =============================================================================
# syscalls.sh — requests per server syscall, for each client: the test of the
# batching hypothesis that shape B raised (README.md).
#
# Usage: syscalls.sh RESULTS_DIR [ROUNDS]
#   (run.sh must have built bin/ first; the same environment variables as
#   run.sh choose the shape: SERVER_CPUS, WORKERS, CLIENT_CPUS, THREADS,
#   CONNS, DEPTH, KEYS, VALUE, WARMUP, DURATION)
#
# For each run, the server's /proc/1/io syscr (read-type syscalls: every
# read() the workers make on their sockets) is sampled right before and after
# the kvbench run, through a helper container in the server's PID namespace
# (the server's image is FROM scratch). kvbench's JSON counts the measured
# phase's requests only, so the warm-up is the shortest kvbench accepts; its
# few requests make both protocols' ratios a little low, alike.
#
# Prints one line per run: protocol, requests, server reads, requests per read.
# =============================================================================
set -euo pipefail

RESULTS=${1:?usage: syscalls.sh RESULTS_DIR [ROUNDS]}
ROUNDS=${2:-2}
SERVER_CPUS=${SERVER_CPUS:-0-3}
WORKERS=${WORKERS:-4}
CLIENT_CPUS=${CLIENT_CPUS:-16-31}
THREADS=${THREADS:-16}
CONNS=${CONNS:-64}
DEPTH=${DEPTH:-16}
KEYS=${KEYS:-1000000}
VALUE=${VALUE:-100}
DURATION=${DURATION:-8}
SERVER=ga-client-sys
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$RESULTS"
export MSYS_NO_PATHCONV=1

docker rm -f "$SERVER" >/dev/null 2>&1 || true
docker run -d --name "$SERVER" --cpuset-cpus "$SERVER_CPUS" \
  -e KVASM_WORKERS="$WORKERS" -e KVASM_CAPACITY=$((KEYS * 5 / 4)) kvasm:0.3.0 >/dev/null
trap 'docker rm -f "$SERVER" >/dev/null 2>&1 || true' EXIT

# client PROTOCOL EXTRA... — kvbench in the server's namespaces (run.sh's).
client() {
  local protocol=$1
  shift
  docker run --rm --network "container:$SERVER" --pid "container:$SERVER" \
    --cpuset-cpus "$CLIENT_CPUS" -v "$here/bin:/kb:ro" kvasm-toolchain:latest \
    "/kb/kvbench-$protocol" --protocol "$protocol" --port 50051 --threads "$THREADS" \
    --connections "$CONNS" --depth "$DEPTH" --keys "$KEYS" --value-size "$VALUE" "$@"
}

# io FIELD — the server's /proc/1/io counter (syscr or syscw). Reading another
# process's io file is a ptrace-level access: the helper needs SYS_PTRACE.
io() {
  docker run --rm --cap-add SYS_PTRACE --pid "container:$SERVER" alpine:3 cat /proc/1/io \
    | awk -v f="$1:" '$1 == f {print $2}'
}

client grpc --load-only --wait-ready 30 > /dev/null
: > "$RESULTS/syscalls.txt"
for round in $(seq 1 "$ROUNDS"); do
  for protocol in grpc grpcasm; do
    r0=$(io syscr); w0=$(io syscw)
    line=$(client "$protocol" --warmup 0.1 --duration "$DURATION" --server-pid 1 --label "$protocol-s$round")
    r1=$(io syscr); w1=$(io syscw)
    ops=$(echo "$line" | grep -o '"ops":[0-9]*' | head -1 | cut -d: -f2)
    # syscw stays 0: the server sends with sendto(), a socket call that does not
    # pass through the VFS counters; read() on a socket does. Reads are what the
    # batching question needs (one read takes every request that has arrived).
    awk -v p="$protocol" -v n="$round" -v ops="$ops" -v r=$((r1 - r0)) \
      'BEGIN { printf "%s round %d: %d requests, server reads %d, %.1f requests per read\n",
               p, n, ops, r, (r ? ops / r : 0) }' | tee -a "$RESULTS/syscalls.txt"
  done
done
