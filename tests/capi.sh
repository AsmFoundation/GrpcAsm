#!/usr/bin/env bash
# =============================================================================
# capi.sh — the C ABI's contract (tests/capi/run.sh) against the freshly built
# libgrpcasm.so: every documented error code, the lifecycle, and the call
# functions through nghttp.
#
# Usage: tests/capi.sh
#
# Where it runs: in KvAsm's toolchain image (gcc, nghttp2's nghttp):
#   docker build --target toolchain -t kvasm-toolchain <kvasm>
# The library, the header and the test sources are mounted read-only.
#
# Exit status: run.sh's (0 = every phase passed).
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library_dir="$here/src/GrpcAsm.Native/bin/Release"

if [ ! -f "$library_dir/libgrpcasm.so" ]; then
  echo "build first: dotnet build GrpcAsm.slnx -c Release" >&2
  exit 2
fi

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the container
# paths into Windows paths.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$library_dir:/lib-under-test:ro" \
  -v "$here/src/GrpcAsm.Native/include:/inc:ro" \
  -v "$here/tests/capi:/t:ro" \
  kvasm-toolchain:latest bash /t/run.sh /lib-under-test /inc /t
