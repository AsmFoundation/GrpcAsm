#!/usr/bin/env bash
# =============================================================================
# greeter.sh — the Greeter's end-to-end checks (tests/greeter/run.sh) against
# samples/Greeter/bin/Release/libc/linux-x64/greeter: exact answers through nghttp, h2spec
# (all 146 cases), startup refusals and a clean SIGTERM.
#
# Usage: tests/greeter.sh
#
# Where it runs: in KvAsm's toolchain image (nghttp2's nghttp client, h2spec),
# built from KvAsm's Dockerfile:
#   docker build --target toolchain -t kvasm-toolchain <kvasm>
# Unlike kvsuite.sh it needs no KvAsm checkout: nothing is built in the
# container. The binary and the script are mounted read-only; the container
# has its own network namespace, so the test port cannot collide with
# anything on the host.
#
# Exit status: run.sh's (0 = every phase passed).
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary_dir="$here/samples/Greeter/bin/Release/libc/linux-x64"

if [ ! -f "$binary_dir/greeter" ]; then
  echo "build first: dotnet build GrpcAsm.slnx -c Release" >&2
  exit 2
fi

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the container
# paths into Windows paths.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$binary_dir:/bin-under-test:ro" \
  -v "$here/tests/greeter:/t:ro" \
  kvasm-toolchain:latest bash -c '
    set -e
    cp /bin-under-test/greeter /tmp/greeter && chmod +x /tmp/greeter
    bash /t/run.sh /tmp/greeter'
