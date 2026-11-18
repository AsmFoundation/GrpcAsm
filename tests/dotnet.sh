#!/usr/bin/env bash
# =============================================================================
# dotnet.sh — GrpcAsm.Net's tests (tests/GrpcAsm.Net.Tests) on Linux, from any
# host: in mcr.microsoft.com/dotnet/sdk:10.0, on a clean copy of the sources.
#
# Usage: tests/dotnet.sh
#
# Why a container: libgrpcasm.so is a Linux x64 ELF file, so the tests run on
# Linux only (on Windows the test project skips every test with the reason).
# CI runs them natively instead.
#
# Why a copy: building in the container from the mounted tree would overwrite
# the host's obj/ folders (their restore files name host paths). The sources
# are copied without bin/ and obj/, and AsmFoundation.Sdk builds the whole
# chain there, with its linux-x64 toolchain package: libgrpcasm.so,
# GrpcAsm.Net, the tests. NuGet packages persist in the grpcasm-nuget volume.
#
# Exit status: dotnet test's (0 = every test passed; GRPCASM_REQUIRE_LINUX=1
# makes a skipped test a failure).
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the container
# paths into Windows paths.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$here:/src:ro" \
  -v grpcasm-nuget:/root/.nuget/packages \
  -e GRPCASM_REQUIRE_LINUX=1 -e DOTNET_NOLOGO=1 -e DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  mcr.microsoft.com/dotnet/sdk:10.0 bash -c '
    set -e
    mkdir -p /work
    cd /src
    tar --exclude="./.git" --exclude="*/bin" --exclude="*/obj" --exclude="./artifacts" -cf - . | tar -xf - -C /work
    cd /work
    dotnet test --project tests/GrpcAsm.Net.Tests/GrpcAsm.Net.Tests.csproj -c Release'
