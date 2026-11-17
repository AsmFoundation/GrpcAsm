#!/usr/bin/env bash
# =============================================================================
# kvsuite.sh - KvAsm's whole end-to-end suite against samples/KvServer, the
# reference consumer of the GrpcAsm engine (milestone B, docs/ROADMAP.md).
#
# Usage: tests/kvsuite.sh <path to a KvAsm checkout> [fuzz iterations]
#
# What runs: KvAsm's tests/integration/run.sh - protocol, limits, pipelining,
# cancellation, concurrency, streaming, graceful shutdown, idle timeouts,
# snapshots, startup refusals, h2spec (146 cases), the fuzzer's request matrix
# and 3,000 fuzzed connections, streaming limits and fairness - with the
# server binary under test being samples/KvServer/bin/Release/kvserver.
#
# Why KvAsm's suite: every extraction step must leave the engine's behavior
# exactly as KvAsm's (h2spec, fuzzing and the exact-answer matrix catch protocol
# changes; the itest phases catch store, streaming and lifecycle changes).
#
# Where it runs: in KvAsm's toolchain image (gcc, nghttp2, h2spec), built from
# KvAsm's Dockerfile:  docker build --target toolchain -t kvasm-toolchain <kvasm>
# The test programs are built from the KvAsm checkout inside the container; the
# checkout and the binary are mounted read-only. The container has its own
# network namespace, so the test port cannot collide with anything on the host.
#
# Exit status: run.sh's (0 = every phase passed).
# =============================================================================
set -euo pipefail

kvasm="${1:?usage: tests/kvsuite.sh <path to a KvAsm checkout> [fuzz iterations]}"
iterations="${2:-3000}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary_dir="$here/samples/KvServer/bin/Release"

if [ ! -f "$binary_dir/kvserver" ]; then
  echo "build first: dotnet build GrpcAsm.slnx -c Release" >&2
  exit 2
fi

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the /ro and /bin
# container paths into Windows paths.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$kvasm/server:/ro:ro" \
  -v "$binary_dir:/bin-under-test:ro" \
  -e FUZZ_ITERATIONS="$iterations" \
  kvasm-toolchain:latest bash -c '
    set -e
    cp -r /ro /tmp/s && cd /tmp/s && rm -rf build
    # Only the test programs are built from KvAsm; the server is the one under test.
    make build/tests/itest_grpc build/tests/mksnap build/tests/fuzz_h2 >/tmp/make.log 2>&1 \
      || { tail -20 /tmp/make.log; exit 1; }
    cp /bin-under-test/kvserver /tmp/kvserver && chmod +x /tmp/kvserver
    FUZZ_BIN=build/tests/fuzz_h2 bash tests/integration/run.sh \
      /tmp/kvserver build/tests/itest_grpc build/tests/mksnap'
