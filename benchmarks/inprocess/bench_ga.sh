#!/usr/bin/env bash
# =============================================================================
# bench_ga.sh — KvAsm's in-process request-path benchmark (bench_h2) for
# KvAsm 0.3.0 and any number of GrpcAsm trees, in interleaved rounds.
# Runs inside the kvasm-toolchain image (KvAsm's Dockerfile, target
# toolchain).
#
# Mounts (read-only unless noted):
#   /audit      KvAsm's benchmarks/results/2026-11-15-asm-audit: bench_h2.c,
#               benchabi.asm and calib.asm, the harness, used unchanged
#   /kvasm      a KvAsm checkout: server/ is built here, from a clean copy
#   /v/NAME     one GrpcAsm tree per variant NAME, already built (the obj/
#               folders of dotnet build GrpcAsm.slnx -c Release)
#   /out        results (read-write)
#
# Usage: bench_ga.sh ROUNDS NAME [NAME...]
#   e.g. docker run ... -v <step-4 worktree>:/v/step4:ro
#                      -v <this tree>:/v/step5:ro ... bash bench_ga.sh 12 step4 step5
#
# Why the harness is ported by sed and not rewritten: the GrpcAsm trees
# differ from KvAsm only in four engine names (ga_hpack_global_init,
# ga_h2n_open, ga_app_batch_end, and ga_h2n_read in a comment) and one Worker
# field (Worker.app, formerly Worker.table), so the same measurement code
# drives every variant. h2_process and conn_window_refill are internal to
# h2n.o: objcopy makes them global in a copy (the code under test is
# unchanged).
#
# Read the output digests before the times: variants fed the same input must
# print the same digest. A different one means a variant answered
# differently — or was not built from what you think (the stale-objects
# pitfall in 2026-11-17-steps-3-4/README.md).
#
# Output: /out/bench.out (min and median per variant and workload) and
# /out/lines.out (one full line per variant and workload: cycles, digest,
# requests counted by the server).
# =============================================================================
set -euo pipefail
ROUNDS=$1
shift
VARIANTS=("$@")
W=/tmp/w
mkdir -p "$W"
CPU=$(( $(nproc) - 1 ))                 # one vCPU for every run: the last

# ---- KvAsm 0.3.0: its own objects, the harness as the audit used it -----------
cp -r /kvasm/server /tmp/kv
rm -rf /tmp/kv/build                    # the checkout may hold stale objects: build from source
make -C /tmp/kv -j"$(nproc)" >/dev/null
K=/tmp/kv/build/obj
nasm -f elf64 -o "$W/calib.o" /audit/calib.asm
nasm -f elf64 -I /tmp/kv/include/ -o "$W/benchabi-kvasm.o" /audit/benchabi.asm
objcopy --globalize-symbol=h2_process --globalize-symbol=conn_window_refill "$K/h2n.o" "$W/h2n_g-kvasm.o"
KV_OBJS=$(ls "$K"/*.o | grep -v -E '/(h2n|main)\.o$')
gcc -std=c11 -O2 -g -Wall -Wextra -I /tmp/kv/tests -o "$W/bench-kvasm" /audit/bench_h2.c \
    "$W/benchabi-kvasm.o" "$W/calib.o" "$W/h2n_g-kvasm.o" $KV_OBJS -pthread

# ---- GrpcAsm variants: the same harness with the engine's names ----------------
sed -e 's/\bkv_hpack_global_init\b/ga_hpack_global_init/g' \
    -e 's/\bkv_h2n_open\b/ga_h2n_open/g' \
    -e 's/\bkv_h2n_read\b/ga_h2n_read/g' \
    -e 's/\bkv_grpc_run_batch\b/ga_app_batch_end/g' /audit/bench_h2.c > "$W/bench_h2_ga.c"
sed -e 's/\bWorker\.table\b/Worker.app/' /audit/benchabi.asm > "$W/benchabi_ga.asm"
for v in "${VARIANTS[@]}"; do
  T=/v/$v
  E=$T/src/GrpcAsm/obj/Release/asm/obj
  A=$T/samples/KvServer/obj/Release/asm/obj
  nasm -f elf64 -I "$T/src/GrpcAsm/include/" -I "$T/samples/KvServer/include/" \
       -o "$W/benchabi-$v.o" "$W/benchabi_ga.asm"
  objcopy --globalize-symbol=h2_process --globalize-symbol=conn_window_refill "$E/h2n.o" "$W/h2n_g-$v.o"
  # The engine and KvServer each have a grpc.o (from step 4): list both by path.
  OBJS="$(ls "$E"/*.o | grep -v -E '/h2n\.o$') $(ls "$A"/*.o | grep -v -E '/main\.o$')"
  gcc -std=c11 -O2 -g -Wall -Wextra -I /kvasm/server/tests -o "$W/bench-$v" "$W/bench_h2_ga.c" \
      "$W/benchabi-$v.o" "$W/calib.o" "$W/h2n_g-$v.o" $OBJS -pthread
done

# ---- interleaved rounds (the audit's abbench.sh) -------------------------------
# summary VARIANT NS... — the minimum over the rounds, the median, and how many
# rounds came within 2% of the minimum (the image has no python3: awk, with the
# audit's python statistics: median = sorted[n / 2], 0-based).
summary() {
  local v=$1
  shift
  printf '%s\n' "$@" | sort -g | awk -v v="$v" '
    { x[NR] = $1 }
    END {
      m = x[1]; near = 0
      for (i = 1; i <= NR; i++) if (x[i] <= m * 1.02) near++
      printf "%-8s min %7.2f ns/request   median %7.2f   rounds within 2%% of min: %d/%d\n",
             v, m, x[int(NR / 2) + 1], near, NR
    }'
}
ALL=(kvasm "${VARIANTS[@]}")
{
  echo "vCPU $CPU of $(nproc); $ROUNDS interleaved rounds; bench get|ping 1024 keys, 40 trials x 1000 batches"
  for mode in get ping; do
    echo "## $mode"
    declare -A all=()
    for r in $(seq 1 "$ROUNDS"); do
      for v in "${ALL[@]}"; do
        ns=$(taskset -c "$CPU" "$W/bench-$v" "$mode" 1024 40 1000 | head -1 | sed -E 's/^[a-z]+: ([0-9.]+) ns.*/\1/')
        all[$v]+="$ns "
      done
    done
    for v in "${ALL[@]}"; do summary "$v" ${all[$v]}; done
    unset all
  done
} | tee /out/bench.out
for mode in get ping; do
  for v in "${ALL[@]}"; do
    echo "$v $(taskset -c "$CPU" "$W/bench-$v" "$mode" 1024 40 1000 | head -1)"
  done
done | tee /out/lines.out
