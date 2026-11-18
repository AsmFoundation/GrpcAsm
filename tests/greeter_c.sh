#!/usr/bin/env bash
# =============================================================================
# greeter_c.sh — the C ABI end to end: samples/GreeterC/greeter.c is compiled
# against include/grpcasm.h and linked with the freshly built libgrpcasm.so,
# then tests/greeter/run.sh, the assembly Greeter's own suite, runs on it:
# exact answers through nghttp, h2spec 146/146, startup refusals, a clean
# SIGTERM. The two Greeters must be indistinguishable from outside.
#
# Usage: tests/greeter_c.sh
#
# Where it runs: in KvAsm's toolchain image (gcc, nghttp2's nghttp, h2spec):
#   docker build --target toolchain -t kvasm-toolchain <kvasm>
# The library, the header and the source are mounted read-only.
#
# Exit status: run.sh's (0 = every phase passed), or 1 if the C program does
# not compile with -Wall -Wextra -Werror.
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library_dir="$here/src/GrpcAsm.Native/bin/Release/libc"

if [ ! -f "$library_dir/libgrpcasm.so" ]; then
  echo "build first: dotnet build GrpcAsm.slnx -c Release" >&2
  exit 2
fi

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the container
# paths into Windows paths.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$library_dir:/lib-under-test:ro" \
  -v "$here/src/GrpcAsm.Native/include:/inc:ro" \
  -v "$here/samples/GreeterC:/src:ro" \
  -v "$here/tests/greeter:/t:ro" \
  kvasm-toolchain:latest bash -c '
    set -e
    mkdir -p /tmp/c && cp /lib-under-test/libgrpcasm.so /tmp/c/
    gcc -std=c11 -O2 -Wall -Wextra -Werror -I /inc -o /tmp/c/greeter /src/greeter.c \
        -L /tmp/c -lgrpcasm -Wl,-rpath,"\$ORIGIN"
    echo "greeter_c: built against grpcasm.h, linked with libgrpcasm.so"
    bash /t/run.sh /tmp/c/greeter'
