#!/usr/bin/env bash
# =============================================================================
# run.sh — milestone D's measurement: GrpcAsm's client against kvbench's own
# gRPC client (nghttp2), the client KvAsm is benchmarked with.
#
# Usage: run.sh KVASM_CHECKOUT RESULTS_DIR [BLOCKS]
#   KVASM_CHECKOUT  a KvAsm checkout (its benchmarks/kvbench is built as is)
#   RESULTS_DIR     where raw.jsonl and environment.txt go
#   BLOCKS          paired blocks (default 6)
#
# Environment (defaults in brackets):
#   SERVER_CPUS [0-3]    WORKERS [4]     the server: KvAsm 0.3.0 (kvasm:0.3.0)
#   CLIENT_CPUS [16-17]  THREADS [2]     the client container's vCPUs, threads
#   CONNS [16]  DEPTH [16]               connections, calls in flight on each
#   KEYS [1000000]  VALUE [100]          preloaded keys, value bytes
#   WARMUP [2]  DURATION [8]             seconds per run
#   WORKLOAD [get]                       get (100% GET) or ping (health check)
#   EXTRA []                             more kvbench flags for the measured
#                                        runs, e.g. --busy-poll (client threads
#                                        never sleep: no wakeup is charged to
#                                        the server; a diagnostic, never mixed
#                                        with blocking runs in one comparison)
#
# Design:
#   * One server for the whole session, preloaded once: both clients read the
#     same keys from the same process.
#   * The same kvbench (threads, epoll loop, workload, histograms, value
#     checks); only the protocol module differs: --protocol grpc (nghttp2,
#     static-PIE, exactly KvAsm's build) or grpcasm (libgrpcasm.so).
#   * Paired blocks: each block runs both clients back to back, in alternating
#     order (odd blocks grpc first), so a drift of the host hits both and a
#     position effect cancels out over the blocks.
#   * The default shape is client-bound on purpose: 2 client threads against
#     4 server workers. Throughput then measures the clients, and kvbench
#     reports both sides' CPU per request (client: its own rusage; server: the
#     server's threads, through --server-pid in the shared PID namespace).
# =============================================================================
set -euo pipefail

KVASM=${1:?usage: run.sh KVASM_CHECKOUT RESULTS_DIR [BLOCKS]}
RESULTS=${2:?usage: run.sh KVASM_CHECKOUT RESULTS_DIR [BLOCKS]}
BLOCKS=${3:-6}
SERVER_CPUS=${SERVER_CPUS:-0-3}
WORKERS=${WORKERS:-4}
CLIENT_CPUS=${CLIENT_CPUS:-16-17}
THREADS=${THREADS:-2}
CONNS=${CONNS:-16}
DEPTH=${DEPTH:-16}
KEYS=${KEYS:-1000000}
VALUE=${VALUE:-100}
WARMUP=${WARMUP:-2}
DURATION=${DURATION:-8}
WORKLOAD=${WORKLOAD:-get}
SERVER=ga-client-ab
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
mkdir -p "$RESULTS"
RESULTS="$(cd "$RESULTS" && pwd)"

# Provenance first: git is a Windows program here and needs the shell's path
# conversion, which the docker calls below must not get.
grpcasm_rev="$(git -C "$repo" rev-parse --short HEAD) $(git -C "$repo" status --porcelain | wc -l) uncommitted"
kvasm_rev="$(git -C "$KVASM" rev-parse --short HEAD)"

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting container paths.
export MSYS_NO_PATHCONV=1

echo "run.sh: building both kvbench binaries"
docker run --rm \
  -v "$KVASM/benchmarks/kvbench:/kvbench:ro" \
  -v "$repo/src/GrpcAsm.Native/bin/Release:/lib-under-test:ro" \
  -v "$repo/src/GrpcAsm.Native/include:/inc:ro" \
  -v "$here:/here:ro" \
  -v "$here/bin:/out" \
  kvasm-toolchain:latest bash /here/build.sh /kvbench /lib-under-test /inc /here /out

{
  echo "date: $(date -u +%FT%TZ)"
  echo "grpcasm: $grpcasm_rev"
  echo "kvasm: $kvasm_rev"
  echo "host load (outside the VM, % of 32 logical CPUs): ${HOST_LOAD:-not sampled}"
  echo "server: kvasm:0.3.0 $(docker image inspect kvasm:0.3.0 --format '{{.Id}}')"
  echo "shape: server cpus $SERVER_CPUS workers $WORKERS; client cpus $CLIENT_CPUS threads $THREADS"
  echo "       conns $CONNS depth $DEPTH keys $KEYS value $VALUE warmup $WARMUP duration $DURATION"
  echo "       workload $WORKLOAD, blocks $BLOCKS, extra kvbench flags: ${EXTRA:-none}"
  echo "containers running: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
} > "$RESULTS/environment.txt"
cat "$RESULTS/environment.txt"

docker rm -f "$SERVER" >/dev/null 2>&1 || true
docker run -d --name "$SERVER" --cpuset-cpus "$SERVER_CPUS" \
  -e KVASM_WORKERS="$WORKERS" -e KVASM_CAPACITY=$((KEYS * 5 / 4)) \
  kvasm:0.3.0 >/dev/null
trap 'docker rm -f "$SERVER" >/dev/null 2>&1 || true' EXIT

# client PROTOCOL EXTRA... — one kvbench run in the server's network and PID
# namespaces, on the client vCPUs; prints its JSON line.
client() {
  local protocol=$1
  shift
  docker run --rm --network "container:$SERVER" --pid "container:$SERVER" \
    --cpuset-cpus "$CLIENT_CPUS" -v "$here/bin:/kb:ro" kvasm-toolchain:latest \
    "/kb/kvbench-$protocol" --protocol "$protocol" --port 50051 --threads "$THREADS" \
    --connections "$CONNS" --depth "$DEPTH" --keys "$KEYS" --value-size "$VALUE" "$@"
}

echo "run.sh: preloading $KEYS keys"
client grpc --load-only --wait-ready 30 > "$RESULTS/preload.json"

workload_flag=()
[[ "$WORKLOAD" == ping ]] && workload_flag=(--ping)
read -r -a extra_flags <<< "${EXTRA:-}"
: > "$RESULTS/raw.jsonl"
for block in $(seq 1 "$BLOCKS"); do
  if (( block % 2 )); then order=(grpc grpcasm); else order=(grpcasm grpc); fi
  for protocol in "${order[@]}"; do
    line=$(client "$protocol" "${workload_flag[@]}" "${extra_flags[@]}" --warmup "$WARMUP" --duration "$DURATION" \
             --server-pid 1 --label "$protocol-b$block")
    echo "$line" >> "$RESULTS/raw.jsonl"
    echo "block $block $protocol: $(echo "$line" | grep -o '"ops_per_sec":[0-9]*' | head -1)"
  done
done
echo "run.sh: $(wc -l < "$RESULTS/raw.jsonl") runs in $RESULTS/raw.jsonl"
