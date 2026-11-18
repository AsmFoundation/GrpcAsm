#!/usr/bin/env bash
# =============================================================================
# build.sh — the two kvbench binaries of the client A/B, inside the
# kvasm-toolchain image (run.sh runs it there).
#
# Usage: build.sh KVBENCH_SRC LIBDIR INCDIR HERE OUT
#   KVBENCH_SRC  a KvAsm checkout's benchmarks/kvbench (read-only)
#   LIBDIR       holds libgrpcasm.so      INCDIR  holds grpcasm.h
#   HERE         this folder (grpcasm.c)  OUT     where the binaries go
#
# Produces:
#   OUT/kvbench-grpc     KvAsm's kvbench exactly as KvAsm builds it
#                        (static-PIE, nghttp2 from the image), unmodified
#   OUT/kvbench-grpcasm  the same sources plus grpcasm.c, with --protocol
#                        grpcasm selecting it; linked with libgrpcasm.so
#                        (copied next to it, found through $ORIGIN)
#
# The patch to kvbench is four mechanical lines, applied with sed and checked:
# the protocol enum and its name, the option parser, the module table, and the
# depth limit that --protocol grpc already has (servers allow 100 streams).
# =============================================================================
set -euo pipefail

SRC=${1:?usage: build.sh KVBENCH_SRC LIBDIR INCDIR HERE OUT}
LIB=${2:?}
INC=${3:?}
HERE=${4:?}
OUT=${5:?}
W=$(mktemp -d)
mkdir -p "$OUT"

# ---- the reference: KvAsm's kvbench, built as its Makefile builds it ----
cp -r "$SRC" "$W/ref"
make -s -C "$W/ref" all
cp "$W/ref/build/kvbench" "$OUT/kvbench-grpc"

# ---- the A side: the same sources, plus the grpcasm protocol module ----
cp -r "$SRC" "$W/ga"
rm -rf "$W/ga/build"
cp "$HERE/grpcasm.c" "$W/ga/"
# patch EXPECTED FILE SED-EXPRESSION — apply, then check that it changed the file.
patch_line() {
  local file=$1 expr=$2
  cp "$W/ga/$file" "$W/before"
  sed -i "$expr" "$W/ga/$file"
  if cmp -s "$W/before" "$W/ga/$file"; then
    echo "build.sh: the patch '$expr' no longer applies to $file" >&2
    exit 1
  fi
}
patch_line kvbench.h 's/enum { PROTO_RESP, PROTO_MEMCACHE, PROTO_GRPC };/enum { PROTO_RESP, PROTO_MEMCACHE, PROTO_GRPC, PROTO_GRPCASM };/'
patch_line kvbench.h 's/extern const Proto proto_resp, proto_memcache, proto_grpc;/extern const Proto proto_resp, proto_memcache, proto_grpc, proto_grpcasm;/'
patch_line main.c 's/: !strcmp(optarg, "grpc")     ? PROTO_GRPC/: !strcmp(optarg, "grpcasm")  ? PROTO_GRPCASM\n                    : !strcmp(optarg, "grpc")     ? PROTO_GRPC/'
patch_line main.c 's/static const char \*proto_names\[\] = {"resp", "memcache", "grpc"};/static const char *proto_names[] = {"resp", "memcache", "grpc", "grpcasm"};/'
patch_line main.c 's/g_opt.proto == PROTO_GRPC && g_opt.depth > 100/(g_opt.proto == PROTO_GRPC || g_opt.proto == PROTO_GRPCASM) \&\& g_opt.depth > 100/'
patch_line engine.c 's/: &proto_grpc;/: g_opt.proto == PROTO_GRPCASM ? \&proto_grpcasm : \&proto_grpc;/'
cp "$LIB/libgrpcasm.so" "$OUT/"
NGHTTP2_PREFIX=${NGHTTP2_PREFIX:-/opt/nghttp2}
gcc -std=c11 -O2 -g -Wall -Wextra -Werror -D_GNU_SOURCE -I"$NGHTTP2_PREFIX/include" -I "$INC" \
    -Wl,-z,relro -Wl,-z,now -o "$OUT/kvbench-grpcasm" \
    "$W/ga/main.c" "$W/ga/engine.c" "$W/ga/proto.c" "$W/ga/grpc.c" "$W/ga/stats.c" \
    "$W/ga/crc32c.c" "$W/ga/grpcasm.c" \
    "$NGHTTP2_PREFIX/lib/libnghttp2.a" -L "$OUT" -lgrpcasm -lm -pthread -Wl,-rpath,'$ORIGIN'
echo "build.sh: $OUT/kvbench-grpc (nghttp2) and $OUT/kvbench-grpcasm (libgrpcasm.so)"
