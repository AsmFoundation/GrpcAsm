#!/usr/bin/env bash
# cabi_bench.sh — SayHello end to end: the assembly Greeter against the C one on libgrpcasm.so
# (a C handler behind a function pointer, which also mallocs and copies its reply), with
# h2load, interleaved rounds, inside kvasm-toolchain.
# Mounts: /g (samples/Greeter/bin/Release), /libga (libgrpcasm.so; not /lib, which would hide the loader), /inc (grpcasm.h), /src (greeter.c)
set -euo pipefail
ROUNDS=${1:-6}
W=/tmp/b; mkdir -p "$W"
cp /g/greeter "$W/asm" && chmod +x "$W/asm"
cp /libga/libgrpcasm.so "$W/"
gcc -std=c11 -O2 -Wall -Wextra -Werror -I /inc -o "$W/c" /src/greeter.c -L "$W" -lgrpcasm -Wl,-rpath,"\$ORIGIN"
printf '\x00\x00\x00\x00\x07\x0a\x05world' > "$W/req.bin"
N=$(nproc); SERVER_CPU=$((N - 1)); LOAD_CPUS="$((N - 3)),$((N - 2))"
echo "server on vCPU $SERVER_CPU (1 worker), h2load on $LOAD_CPUS; $ROUNDS rounds"
declare -A rps=()
for r in $(seq 1 "$ROUNDS"); do
  for v in asm c; do
    GREETER_PORT=50391 GREETER_WORKERS=1 taskset -c "$SERVER_CPU" "$W/$v" > "$W/$v.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do grep -q 'msg="listening"' "$W/$v.log" && break; sleep 0.05; done
    out=$(taskset -c "$LOAD_CPUS" h2load -n 400000 -c 8 -m 32 -t 2 -d "$W/req.bin" \
            -H 'content-type: application/grpc' -H 'te: trailers' \
            http://127.0.0.1:50391/helloworld.Greeter/SayHello 2>&1)
    kill -TERM $pid; wait $pid || true
    ok=$(echo "$out" | grep -o -E 'requests: [0-9]+ total, [0-9]+ started, [0-9]+ done, [0-9]+ succeeded' )
    v_rps=$(echo "$out" | grep -o -E 'finished in [0-9.]+[a-z]+, [0-9.]+ req/s' | grep -o -E '[0-9.]+ req/s' | cut -d' ' -f1)
    rps[$v]+="$v_rps "
    [[ $r -eq 1 ]] && echo "  $v: $ok"
  done
done
for v in asm c; do
  printf '%s\n' ${rps[$v]} | sort -g | awk -v v="$v" '{x[NR]=$1} END {printf "%-4s median %10.0f req/s   min %10.0f   max %10.0f   (%d rounds)\n", v, x[int((NR+1)/2)], x[1], x[NR], NR}'
done
