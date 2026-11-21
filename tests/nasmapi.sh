#!/usr/bin/env bash
# =============================================================================
# nasmapi.sh — the code grpcasm.inc generates (milestone C3), called directly:
# tests/nasmapi/{table,chain,alias}.asm declare services with the NASM API,
# and nasmapi_test.c checks each one's route table, dispatch (jump table,
# compare chain, alias), streaming hooks, health check and default hooks.
#
# Usage: tests/nasmapi.sh
#
# Where it runs: in KvAsm's toolchain image (nasm, gcc). The include folder,
# the freshly built libgrpcasm.a (for ga_keyeq) and the test sources are
# mounted read-only.
#
# The servers (samples/Greeter, samples/KvServer) cover the alias and the
# compare chain end to end; this covers every generated shape, including the
# jump table no sample has.
#
# Exit status: 0 when every variant passed.
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$here/src/GrpcAsm/bin/Release/libc/linux-x64/libgrpcasm.a"
[ -f "$archive" ] || { echo "build first: dotnet build GrpcAsm.slnx -c Release" >&2; exit 2; }

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the container
# paths into Windows paths.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$here/src/GrpcAsm/include:/inc:ro" \
  -v "$here/src/GrpcAsm/bin/Release/libc/linux-x64:/lib-under-test:ro" \
  -v "$here/tests/nasmapi:/t:ro" \
  kvasm-toolchain:latest bash -c '
    set -e
    W=$(mktemp -d)
    for v in table chain alias; do
      nasm -f elf64 -w+all -w-reloc-rel-dword -w-reloc-abs-qword -w+error -I /inc/ -o "$W/$v.o" "/t/$v.asm"
      V=$(echo "$v" | tr a-z A-Z)
      gcc -std=c11 -O2 -Wall -Wextra -Werror -DVARIANT_$V -o "$W/test_$v" /t/nasmapi_test.c \
          "$W/$v.o" /lib-under-test/libgrpcasm.a -pthread
      "$W/test_$v"
      echo "  ok: $v"
    done
    echo "nasmapi: all variants passed"'
