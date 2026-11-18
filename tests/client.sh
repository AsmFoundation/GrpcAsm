#!/usr/bin/env bash
# =============================================================================
# client.sh — GrpcAsm's gRPC client (grpcasm_client_*) end to end, against
# the freshly built libgrpcasm.so: tests/client/run.sh starts the assembly
# Greeter and tests/capi/capi_server, then runs tests/client/client_test.c
# against them and against its own scripted HTTP/2 server, and finally the
# NASM client (samples/GreeterClient) against the assembly Greeter.
#
# Usage: tests/client.sh
#
# Where it runs: in KvAsm's toolchain image (gcc, glibc 2.34+):
#   docker build --target toolchain -t kvasm-toolchain <kvasm>
# The library, the header, the Greeter and the test sources are mounted
# read-only.
#
# Exit status: run.sh's (0 = every check passed).
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library_dir="$here/src/GrpcAsm.Native/bin/Release/libc"
greeter="$here/samples/Greeter/bin/Release/libc/greeter"
greeter_client="$here/samples/GreeterClient/bin/Release/libc/greeter_client"

if [ ! -f "$library_dir/libgrpcasm.so" ] || [ ! -f "$greeter" ] || [ ! -f "$greeter_client" ]; then
  echo "build first: dotnet build GrpcAsm.slnx -c Release" >&2
  exit 2
fi

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the container
# paths into Windows paths.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$library_dir:/lib-under-test:ro" \
  -v "$here/src/GrpcAsm.Native/include:/inc:ro" \
  -v "$here/samples/Greeter/bin/Release/libc:/greeter:ro" \
  -v "$here/samples/GreeterClient/bin/Release/libc:/gclient:ro" \
  -v "$here/tests/capi:/capi:ro" \
  -v "$here/tests/client:/t:ro" \
  kvasm-toolchain:latest bash /t/run.sh /lib-under-test /inc /greeter/greeter /capi /t \
    /gclient/greeter_client
