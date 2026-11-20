#!/usr/bin/env bash
# =============================================================================
# run.sh — the head-to-head: the same C# service classes on GrpcAsm (the engine
# in assembly) and on ASP.NET Core gRPC, measured side by side by bench.sh.
#
# Usage: run.sh [ROUNDS]   (default 12: a multiple of every set's size, 6, 3
#                           and 2, keeps the rotation even)
# Environment: RESULTS [results] the folder for this run's files, relative to
#              this folder or absolute; SETS, WARMUP_S, MEASURE_S, LATENCY_S,
#              RATE_HELLO, RATE_ORDER go to bench.sh (see its header), e.g. a
#              quick check: SETS="S1" WARMUP_S=2 MEASURE_S=2 LATENCY_S=2 run.sh 1
#
# Steps:
#   1. provenance and the host's load (outside the Docker VM) into
#      results/environment.txt, sampled before and after the runs;
#   2. GreeterNet and GreeterAspNet published self-contained for linux-x64
#      into bin/ (the toolchain image has no .NET runtime), their GC modes
#      read from the published runtimeconfig files;
#   3. make_requests.cs writes the request bodies and the reply sizes into
#      bin/requests (from the sample's own types);
#   4. bench.sh in kvasm-toolchain, with the assembly Greeter from the
#      solution's Release build: build that first (dotnet build GrpcAsm.slnx
#      -c Release). Nothing is built while the servers run.
# =============================================================================
set -euo pipefail
ROUNDS=${1:-12}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
results=${RESULTS:-results}
[[ $results == /* || $results == [A-Za-z]:* ]] || results="$here/$results"
mkdir -p "$results"

greeter="$repo/samples/Greeter/bin/Release/libc/greeter"
[[ -f "$greeter" ]] || { echo "build first: dotnet build GrpcAsm.slnx -c Release ($greeter missing)" >&2; exit 2; }

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

echo "run.sh: publishing GreeterNet and GreeterAspNet (self-contained, linux-x64)"
rm -rf "$here/bin/greeter-net" "$here/bin/greeter-aspnet" "$here/bin/requests"
dotnet publish "$repo/samples/GreeterNet/GreeterNet.csproj" -c Release -r linux-x64 --self-contained \
  -o "$here/bin/greeter-net" -v quiet -nologo
dotnet publish "$repo/samples/GreeterAspNet/GreeterAspNet.csproj" -c Release -r linux-x64 --self-contained \
  -o "$here/bin/greeter-aspnet" -v quiet -nologo
echo "run.sh: request bodies"
dotnet run "$here/make_requests.cs" -- "$here/bin/requests"

# gc_mode RUNTIMECONFIG — "Server" or "Workstation", as the published app runs.
gc_mode() { grep -q '"System.GC.Server": true' "$1" && echo Server || echo Workstation; }

{
  echo "date: $(date -u +%FT%TZ)"
  echo "grpcasm: $rev"
  echo "dotnet: SDK $(dotnet --version); runtime in both publishes: $(grep -o 'Microsoft.NETCore.App.Runtime.linux-x64/[^"]*' "$here/bin/greeter-net/GreeterNet.deps.json" | head -1)"
  echo "aspnetcore: $(grep -o 'Microsoft.AspNetCore.App.Runtime.linux-x64/[^"]*' "$here/bin/greeter-aspnet/GreeterAspNet.deps.json" | head -1); grpc-dotnet: $(grep -o '"Grpc.AspNetCore.Server/[^"]*' "$here/bin/greeter-aspnet/GreeterAspNet.deps.json" | head -1 | tr -d '"')"
  echo "GC as published: GreeterNet $(gc_mode "$here/bin/greeter-net/GreeterNet.runtimeconfig.json"), GreeterAspNet $(gc_mode "$here/bin/greeter-aspnet/GreeterAspNet.runtimeconfig.json")"
  echo "bench: rounds $ROUNDS, sets ${SETS:-S1 O1 S4 O4}, warm-up ${WARMUP_S:-12}s, saturation ${MEASURE_S:-8}s, latency ${LATENCY_S:-8}s at ${RATE_HELLO:-10000}/${RATE_ORDER:-5000} calls/s"
  echo "host load before (whole PC, % of its logical CPUs, 5 s): $load_before"
  echo "containers running: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
} > "$results/environment.txt"

export MSYS_NO_PATHCONV=1
docker run --rm \
  -v "$repo/samples/Greeter/bin/Release/libc:/g:ro" \
  -v "$here/bin/greeter-net:/net:ro" \
  -v "$here/bin/greeter-aspnet:/asp:ro" \
  -v "$here/bin/requests:/req:ro" \
  -v "$here:/here:ro" \
  -v "$results:/out" \
  -e SETS -e WARMUP_S -e MEASURE_S -e LATENCY_S -e RATE_HELLO -e RATE_ORDER \
  kvasm-toolchain:latest bash -c 'uname -r > /out/kernel.txt; lscpu | grep -E "Model name|^CPU\(s\)" >> /out/kernel.txt; bash /here/bench.sh "$1"' _ "$ROUNDS"
unset MSYS_NO_PATHCONV

echo "host load after (whole PC, % of its logical CPUs, 5 s): $(host_load)" >> "$results/environment.txt"
cat "$results/kernel.txt" >> "$results/environment.txt" && rm -f "$results/kernel.txt"
cat "$results/environment.txt"
