#!/usr/bin/env bash
# =============================================================================
# run.sh — milestone C4's measurement: what a .NET handler on GrpcAsmServer
# costs per call, against the assembly and C Greeters on the same engine.
#
# Usage: run.sh [ROUNDS]   (default 10; a multiple of the number of variants
#                           keeps the rotation even)
# Environment: RESULTS [results] the folder for this run's files, relative to
#              this folder or absolute; VARIANTS, WARMUP, CALLS go to bench.sh
#              (see its header): e.g. WARMUP=2000000 RESULTS=results-warmup-2m
#
# Steps:
#   1. provenance and the host's load (outside the Docker VM) into
#      results/environment.txt, sampled before and after the runs;
#   2. GreeterNet published self-contained for linux-x64 into bin/greeter-net
#      (the toolchain image has no .NET runtime);
#   3. bench.sh in kvasm-toolchain, with the assembly Greeter and
#      libgrpcasm.so from the solution's Release build: build that first
#      (dotnet build GrpcAsm.slnx -c Release). Nothing is built while the
#      servers run.
# =============================================================================
set -euo pipefail
ROUNDS=${1:-10}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
results=${RESULTS:-results}
[[ $results == /* || $results == [A-Za-z]:* ]] || results="$here/$results"
mkdir -p "$results"

for f in "$repo/samples/Greeter/bin/Release/greeter" "$repo/src/GrpcAsm.Native/bin/Release/libgrpcasm.so"; do
  [[ -f "$f" ]] || { echo "build first: dotnet build GrpcAsm.slnx -c Release ($f missing)" >&2; exit 2; }
done

# host_load — the average CPU load of the whole PC over 5 s, in % of its
# logical CPUs (Windows; elsewhere "not sampled"). The Docker VM's own work is
# part of it, so it is sampled while no benchmark runs.
host_load() {
  if command -v powershell > /dev/null 2>&1; then
    powershell -NoProfile -Command "[math]::Round(((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5).CounterSamples | Measure-Object CookedValue -Average).Average, 1)" | tr -d '\r'
  else
    echo "not sampled"
  fi
}

# Provenance first: git is a Windows program here and needs the shell's path
# conversion, which the docker call below must not get.
rev="$(git -C "$repo" rev-parse --short HEAD) + $(git -C "$repo" status --porcelain | wc -l) uncommitted paths"
load_before=$(host_load)

echo "run.sh: publishing GreeterNet (self-contained, linux-x64)"
dotnet publish "$repo/samples/GreeterNet/GreeterNet.csproj" -c Release -r linux-x64 --self-contained \
  -o "$here/bin/greeter-net" -v quiet -nologo

{
  echo "date: $(date -u +%FT%TZ)"
  echo "grpcasm: $rev"
  echo "dotnet: SDK $(dotnet --version), GreeterNet self-contained (its runtime: $(grep -o 'Microsoft.NETCore.App.Runtime.linux-x64/[^"]*' "$here/bin/greeter-net/GreeterNet.deps.json" | head -1))"
  echo "bench: rounds $ROUNDS, variants ${VARIANTS:-asm c net-raw net-typed net-typed@DOTNET_TieredCompilation=0}, warm-up ${WARMUP:-7000000}, measured ${CALLS:-2000000}"
  echo "host load before (whole PC, % of its logical CPUs, 5 s): $load_before"
  echo "containers running: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
} > "$results/environment.txt"

export MSYS_NO_PATHCONV=1
docker run --rm \
  -v "$repo/samples/Greeter/bin/Release:/g:ro" \
  -v "$repo/src/GrpcAsm.Native/bin/Release:/libga:ro" \
  -v "$repo/src/GrpcAsm.Native/include:/inc:ro" \
  -v "$repo/samples/GreeterC:/src:ro" \
  -v "$here/bin/greeter-net:/net:ro" \
  -v "$here:/here:ro" \
  -v "$results:/out" \
  -e VARIANTS -e WARMUP -e CALLS \
  kvasm-toolchain:latest bash /here/bench.sh "$ROUNDS"
unset MSYS_NO_PATHCONV

echo "host load after (whole PC, % of its logical CPUs, 5 s): $(host_load)" >> "$results/environment.txt"
cat "$results/environment.txt"
