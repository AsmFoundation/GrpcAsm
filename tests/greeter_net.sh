#!/usr/bin/env bash
# =============================================================================
# greeter_net.sh — the .NET API end to end: samples/GreeterNet (SayHello in C#,
# on GrpcAsmServer over libgrpcasm.so) is published self-contained for
# linux-x64, then tests/greeter/run.sh, the assembly Greeter's own suite, runs
# on it three times: with GreeterService, the grpc-dotnet class bound through
# GrpcAsmServer.ServiceBinder (the default), with the typed delegate
# (Google.Protobuf) and with the raw one (GrpcAsmProtobuf, the reply framed by
# hand). Exact answers through nghttp, h2spec 146/146, startup refusals, a
# clean SIGTERM: the .NET Greeter must be indistinguishable from the assembly
# and C ones, whichever way its handler is written.
#
# Usage: tests/greeter_net.sh
#
# Where it runs: the publish on the host (.NET 10 SDK; Windows cross-publishes
# to linux-x64 as Linux does), the suite in KvAsm's toolchain image (nghttp,
# h2spec), as greeter.sh:
#   docker build --target toolchain -t kvasm-toolchain <kvasm>
# Why self-contained: the toolchain image has no .NET runtime. The publish
# carries one (and libgrpcasm.so, through GrpcAsm.Net's reference to
# GrpcAsm.Native); GreeterNet sets InvariantGlobalization, as the image has no
# ICU either.
#
# Exit status: run.sh's (0 = every phase passed in every mode), or dotnet
# publish's.
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
publish_dir="$here/samples/GreeterNet/bin/publish/linux-x64"

dotnet publish "$here/samples/GreeterNet/GreeterNet.csproj" -c Release -r linux-x64 --self-contained \
  -o "$publish_dir" -v quiet -nologo

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the container
# paths into Windows paths. The copy restores the executable bit, which a
# publish on Windows cannot record.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$publish_dir:/net-under-test:ro" \
  -v "$here/tests/greeter:/t:ro" \
  kvasm-toolchain:latest bash -c '
    set -e
    cp -r /net-under-test /tmp/gn && chmod +x /tmp/gn/GreeterNet
    echo "greeter_net: GreeterService, the grpc-dotnet class (ServiceBinder)"
    GREETER_MODE=service bash /t/run.sh /tmp/gn/GreeterNet
    echo "greeter_net: typed handler (Google.Protobuf)"
    GREETER_MODE=typed bash /t/run.sh /tmp/gn/GreeterNet
    echo "greeter_net: raw handler (GrpcAsmProtobuf)"
    GREETER_MODE=raw bash /t/run.sh /tmp/gn/GreeterNet'
