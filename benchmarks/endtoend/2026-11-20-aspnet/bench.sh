#!/usr/bin/env bash
# =============================================================================
# bench.sh — the same C# services on two servers: GrpcAsm (samples/GreeterNet,
# whose HTTP/2, HPACK, gRPC and event loops are assembly) against ASP.NET Core
# gRPC (samples/GreeterAspNet: Kestrel and grpc-dotnet), with GrpcAsm's
# assembly Greeter as the floor. Runs inside kvasm-toolchain (run.sh starts it
# there); the method of benchmarks/endtoend/2026-11-18-dotnet, extended.
#
# Usage: bench.sh ROUNDS
# Mounts: /g (samples/Greeter/bin/Release/libc: the assembly greeter),
#   /net (GreeterNet), /asp (GreeterAspNet), both published self-contained,
#   /req (make_requests.cs's request bodies and reply sizes), /here (this
#   folder: cpuns.c), /out (results)
#
# Sets, run in this order every round (SETS selects them):
#   S1  SayHello("world"), server on 1 vCPU:
#         asm net-raw net-typed net-service aspnet aspnet@DOTNET_gcServer=0
#   O1  shop.Orders/Place, a 989-byte order, server on 1 vCPU:
#         net-service aspnet
#   S4  SayHello, server on 4 vCPUs:  asm net-service aspnet
#   O4  Orders.Place, server on 4 vCPUs:  net-service aspnet
# Variants:
#   asm          samples/Greeter (NASM API), GREETER_WORKERS = the vCPUs
#   net-service  GreeterNet's default: GreeterService and OrdersService, the
#                grpc-dotnet classes, bound through GrpcAsmServer.ServiceBinder
#   net-typed    GreeterNet, SayHello as a Func<HelloRequest, HelloReply>
#   net-raw      GreeterNet, SayHello as a span handler (GrpcAsmProtobuf)
#   aspnet       GreeterAspNet: the same classes on Kestrel, Server GC as
#                ASP.NET Core ships it; its thread pool sizes itself to the
#                vCPUs it is pinned to
#   aspnet@DOTNET_gcServer=0   the control: Workstation GC, GreeterNet's (a
#                console app's default), so the GC mode cannot explain a gap
#   A variant may carry extra environment for its server after an @,
#   comma-separated.
# Environment (defaults in brackets): SETS ["S1 O1 S4 O4"]; WARMUP_S [12],
#   MEASURE_S [8], LATENCY_S [8] seconds; RATE_HELLO [10000] and RATE_ORDER
#   [5000] calls/s of the fixed-rate latency runs (1-vCPU sets only).
#
# Each run, in order:
#   1. a fresh server, the whole process pinned (taskset) to the set's vCPUs:
#      the last one (1-vCPU sets) or the last four. Every thread is checked to
#      be on them after the run: a .NET server's GC, JIT and I/O threads share
#      those vCPUs with the request work, so CPU per call is the full cost.
#   2. warm-up, WARMUP_S seconds of load: the tiered JIT of both .NET servers
#      needs seconds of load to converge (5 to 12 s in the C4 drift runs), and
#      every server gets the same.
#   3. saturation, MEASURE_S seconds: h2load at full concurrency (1 vCPU:
#      8 connections x 32 streams, 2 threads on the two vCPUs below; 4 vCPUs:
#      32 x 32, 8 threads on the eight below). The server's CPU time is read
#      around it (cpuns: every thread, user and system, in ns).
#   4. latency (1-vCPU sets): LATENCY_S seconds at a fixed rate both servers
#      sustain (h2load --rps, 8 connections), every request's time logged;
#      p50, p99 and p99.9 from the log.
#   5. SIGTERM: the server must exit 0; a GrpcAsm server's stopped line must
#      count 0 errors.
# Every h2load run must end with every call succeeded, and its DATA bytes must
#   equal the calls times the reply's framed size (make_requests.cs): an error
#   answer carries no message, so this catches a failed call on a server that
#   counts nothing itself.
# Timing-based runs (-D): the calls in flight at the deadline (8 x 32) are not
#   counted by h2load, but may reach the server; GrpcAsm's stopped line is
#   therefore not compared with h2load's total (C4 compared them exactly with
#   call-count runs). The DATA check is exact.
# The order of the variants rotates every round, so over a multiple of a set's
#   size, each variant holds each position equally often; comparisons are made
#   within a round (paired), so a drift of the host cancels out.
#
# Output: /out/raw.tsv (one line per run) and /out/bench.txt (the log, then a
# summary per set: medians, and per round the ratios against aspnet).
# =============================================================================
set -euo pipefail
# run() executes in command substitutions; without this, errexit stops at
# their boundary and a failed step inside would go unnoticed.
shopt -s inherit_errexit
ROUNDS=${1:-12}
read -r -a SETS <<< "${SETS:-S1 O1 S4 O4}"
WARMUP_S=${WARMUP_S:-12}
MEASURE_S=${MEASURE_S:-8}
LATENCY_S=${LATENCY_S:-8}
RATE_HELLO=${RATE_HELLO:-10000}
RATE_ORDER=${RATE_ORDER:-5000}
PORT=50391
W=/tmp/b
mkdir -p "$W"
cp /g/greeter "$W/asm" && chmod +x "$W/asm"
cp -r /net "$W/net" && chmod +x "$W/net/GreeterNet"
cp -r /asp "$W/asp" && chmod +x "$W/asp/GreeterAspNet"
cp /req/* "$W/"
gcc -std=c11 -O2 -Wall -Wextra -Werror -o "$W/cpuns" /here/cpuns.c
N=$(nproc)

# variants SET — the set's variants, in round-1 order.
variants() {
  case $1 in
    S1) echo "asm net-raw net-typed net-service aspnet aspnet@DOTNET_gcServer=0" ;;
    O1) echo "net-service aspnet" ;;
    S4) echo "asm net-service aspnet" ;;
    O4) echo "net-service aspnet" ;;
    *) echo "FAIL: unknown set $1" >&2; exit 1 ;;
  esac
}

{
  echo "vCPUs in the VM: $N; sets: ${SETS[*]}; $ROUNDS rounds; warm-up ${WARMUP_S}s, saturation ${MEASURE_S}s," \
       "latency ${LATENCY_S}s at $RATE_HELLO (SayHello) / $RATE_ORDER (Orders) calls/s"
  for s in "${SETS[@]}"; do echo "  $s: $(variants "$s")"; done
  echo "requests: hello $(stat -c %s "$W/req-hello.bin") bytes, order $(stat -c %s "$W/req-order.bin") bytes (framed);" \
       "replies: hello $(cat "$W/reply-hello.size"), order $(cat "$W/reply-order.size") bytes (framed)"
} | tee /out/bench.txt
printf 'set\tround\tposition\tvariant\treq_per_s\tcpu_ns_per_call\tserver_busy\trss_mb\tp50_us\tp99_us\tp999_us\n' > /out/raw.tsv

# fail WHY [LOG] — report, show the server log, stop everything, exit 1.
fail() {
  echo "FAIL: $1" >&2
  [[ -n "${2:-}" && -f "$2" ]] && tail -40 "$2" >&2
  pkill -KILL -f "$W/" 2> /dev/null || true
  exit 1
}

# check LABEL OUTPUT REPLY_SIZE LOG — one h2load run's verdict: every call
# done succeeded (none failed, errored or timed out) and the DATA bytes equal
# calls x reply size. Prints the succeeded count.
check() {
  local label=$1 out=$2 size=$3 log=$4 counts data
  counts=$(echo "$out" | sed -n -E 's/^requests: [0-9]+ total, [0-9]+ started, ([0-9]+) done, ([0-9]+) succeeded, ([0-9]+) failed, ([0-9]+) errored, ([0-9]+) timeout.*/\1 \2 \3 \4 \5/p')
  local done_n ok failed errored timeouts
  read -r done_n ok failed errored timeouts <<< "$counts"
  [[ -n "${ok:-}" && $ok -gt 0 && $ok -eq $done_n && $failed -eq 0 && $errored -eq 0 && $timeouts -eq 0 ]] \
    || { echo "$out" >&2; fail "$label: not every call succeeded" "$log"; }
  data=$(echo "$out" | sed -n -E 's/^traffic: .* \(([0-9]+)\) data.*/\1/p')
  [[ "$data" -eq $((ok * size)) ]] || { echo "$out" >&2; fail "$label: $data data bytes, expected $ok x $size" "$log"; }
  echo "$ok"
}

# run SET SPEC — one fresh server, warm-up, saturation, latency, SIGTERM.
# Prints "req/s cpu-ns-per-call server-busy rss-mb p50 p99 p999" ("-" where
# not measured).
run() {
  local set=$1 spec=$2 v=${2%%@*} extra=()
  [[ $spec == *@* ]] && IFS=, read -r -a extra <<< "${spec#*@}"
  local vcpus=1 workload=hello path=/helloworld.Greeter/SayHello rate=$RATE_HELLO
  case $set in
    O1) workload=order path=/shop.Orders/Place rate=$RATE_ORDER ;;
    S4) vcpus=4 ;;
    O4) vcpus=4 workload=order path=/shop.Orders/Place ;;
  esac
  local server_cpus load_cpus shape
  if [[ $vcpus -eq 1 ]]; then
    server_cpus=$((N - 1)); load_cpus="$((N - 3)),$((N - 2))"; shape=(-c 8 -m 32 -t 2)
  else
    server_cpus="$((N - 4))-$((N - 1))"; load_cpus="$((N - 12))-$((N - 5))"; shape=(-c 32 -m 32 -t 8)
  fi
  local cmd
  case $v in
    asm) cmd=(env GREETER_WORKERS=$vcpus "$W/asm") ;;
    net-raw | net-typed | net-service) cmd=(env GREETER_WORKERS=$vcpus GREETER_MODE=${v#net-} "$W/net/GreeterNet") ;;
    aspnet) cmd=("$W/asp/GreeterAspNet") ;;
    *) fail "unknown variant $v" ;;
  esac
  local log="$W/${set}_${spec//[^A-Za-z0-9_.-]/_}.log" req="$W/req-$workload.bin" size
  size=$(cat "$W/reply-$workload.size")
  local h=(-d "$req" -H 'content-type: application/grpc' -H 'te: trailers' "http://127.0.0.1:$PORT$path")

  # taskset and env exec the server: $! is the server's own pid.
  GREETER_PORT=$PORT taskset -c "$server_cpus" env "${extra[@]}" "${cmd[@]}" > "$log" 2>&1 &
  local pid=$!
  local up=0
  for _ in $(seq 1 400); do
    if (exec 3<> "/dev/tcp/127.0.0.1/$PORT") 2> /dev/null; then up=1; break; fi
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.05
  done
  [[ $up -eq 1 ]] || fail "$set $spec did not start" "$log"

  local out
  out=$(taskset -c "$load_cpus" h2load -D "$WARMUP_S" "${shape[@]}" "${h[@]}" 2>&1)
  check "$set $spec warm-up" "$out" "$size" "$log" > /dev/null
  # A second for the server to settle: a timed h2load run ends by aborting the
  # calls in flight (8 x 32), and grpc-dotnet logs each cancellation with its
  # stack trace (Information, the template's level for its category); without
  # the pause that burst would be charged to the measured run. Every server
  # gets the same pause.
  sleep 1
  local c0 t0 c1 t1 calls
  c0=$("$W/cpuns" "$pid"); t0=$(date +%s%N)
  out=$(taskset -c "$load_cpus" h2load -D "$MEASURE_S" "${shape[@]}" "${h[@]}" 2>&1)
  t1=$(date +%s%N); c1=$("$W/cpuns" "$pid")
  calls=$(check "$set $spec saturation" "$out" "$size" "$log")
  local rps
  rps=$(echo "$out" | grep -o -E 'finished in [0-9.]+[a-z]+, [0-9.]+ req/s' | grep -o -E '[0-9.]+ req/s' | cut -d' ' -f1)

  local p50=- p99=- p999=-
  if [[ $vcpus -eq 1 ]]; then
    sleep 1 # the same settling as before the saturation run
    rm -f "$W/latency.log"
    out=$(taskset -c "$load_cpus" h2load -D "$LATENCY_S" --rps=$((rate / 8)) -c 8 -m 8 -t 2 \
      --log-file="$W/latency.log" "${h[@]}" 2>&1)
    check "$set $spec latency" "$out" "$size" "$log" > /dev/null
    # Every logged request must have succeeded, and the server must have kept
    # the rate (at least 95% of the calls it was offered). The log's third
    # column is each request's time in microseconds; the percentiles come
    # from the sorted column (sort, not gawk's asort: the image's awk is mawk).
    local bad
    bad=$(awk -F'\t' -v want=$((rate * LATENCY_S)) '
      $2 != 200 { bad++ }
      END { if (bad || NR < 0.95 * want) print NR, bad + 0 }' "$W/latency.log")
    [[ -z $bad ]] || fail "$set $spec latency run: $bad (calls logged, non-200) of $((rate * LATENCY_S)) offered" "$log"
    read -r p50 p99 p999 <<< "$(cut -f3 "$W/latency.log" | sort -n | awk '
      function at(q,   i) { i = int(NR * q); return d[i < 1 ? 1 : i] }
      { d[NR] = $1 }
      END { printf "%d %d %d\n", at(0.50), at(0.99), at(0.999) }')"
  fi

  # Every thread on the server's vCPUs (the pin held), and the peak RSS. A
  # subset counts: Server GC pins each heap's thread to one vCPU of the set
  # ("28" within "28-31"), which is still inside the pin.
  local lo=${server_cpus%-*} hi=${server_cpus#*-} strays
  strays=$(grep -h Cpus_allowed_list /proc/"$pid"/task/*/status | awk -v lo="$lo" -v hi="$hi" '
    {
      n = split($2, parts, ",")
      for (i = 1; i <= n; i++) {
        m = split(parts[i], ends, "-")
        first = ends[1] + 0; last = (m == 2 ? ends[2] : ends[1]) + 0
        if (first < lo || last > hi) { print; next }
      }
    }' | wc -l)
  [[ $strays -eq 0 ]] || fail "$set $spec: $strays threads allowed off vCPUs $server_cpus" "$log"
  local rss
  rss=$(awk '/^VmHWM:/ { printf "%.1f", $2 / 1024 }' /proc/"$pid"/status)

  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [[ $rc -eq 0 ]] || fail "$set $spec exited $rc after SIGTERM" "$log"
  if [[ $v != aspnet ]]; then
    grep -q -E 'msg="stopped" connections=[0-9]+ requests=[0-9]+ errors=0$' "$log" \
      || fail "$set $spec's stopped line" "$log"
  fi
  awk -v r="$rps" -v c=$((c1 - c0)) -v t=$((t1 - t0)) -v n="$calls" -v m="$rss" \
      -v a="$p50" -v b="$p99" -v e="$p999" \
    'BEGIN { printf "%s %.1f %.3f %s %s %s %s\n", r, c / n, c / t, m, a, b, e }'
}

for r in $(seq 1 "$ROUNDS"); do
  for s in "${SETS[@]}"; do
    read -r -a vs <<< "$(variants "$s")"
    k=${#vs[@]}
    for p in $(seq 0 $((k - 1))); do
      v=${vs[$(((r - 1 + p) % k))]}
      # An assignment, not "read < <(run)": a process substitution's failure
      # would be ignored, this one stops the benchmark (errexit).
      line=$(run "$s" "$v")
      read -r rps ns busy rss p50 p99 p999 <<< "$line"
      printf '%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$r" $((p + 1)) "$v" "$rps" "$ns" "$busy" "$rss" "$p50" "$p99" "$p999" >> /out/raw.tsv
      printf 'round %2d %s %-26s %10.0f req/s %9.1f server-ns/call  busy %5.1f%%  rss %6s MB  p50/p99/p99.9 %s/%s/%s us\n' \
        "$r" "$s" "$v" "$rps" "$ns" "$(awk -v u="$busy" 'BEGIN { print u * 100 }')" "$rss" "$p50" "$p99" "$p999" | tee -a /out/bench.txt
    done
  done
done

# ---- summary ----
# Per set and variant: medians of every measure; then, per round, the
# variant's req/s divided by aspnet's and aspnet's CPU ns per call divided by
# the variant's (both "times better than ASP.NET Core"), as medians with their
# range: a drift of the host that hits a whole round cancels out of them.
{
  echo
  for s in "${SETS[@]}"; do
    echo "== $s"
    printf '%-26s %11s %11s %7s %8s %20s %22s %22s\n' variant "req/s" "ns/call" busy "rss MB" "p50/p99/p99.9 us" "req/s vs aspnet" "aspnet ns / this ns"
    awk -F'\t' -v set="$s" -v variants="$(variants "$s")" '
      function sort(a, n,   i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t } }
      function median(a, n) { return n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2 }
      NR > 1 && $1 == set {
        rps[$4, $2] = $5 + 0; ns[$4, $2] = $6 + 0; busy[$4, $2] = $7 + 0; rss[$4, $2] = $8 + 0
        p50[$4, $2] = $9; p99[$4, $2] = $10; p999[$4, $2] = $11
        if ($2 > rounds) rounds = $2
      }
      END {
        k = split(variants, order, " ")
        for (i = 1; i <= k; i++) {
          v = order[i]
          for (r = 1; r <= rounds; r++) {
            a[r] = rps[v, r]; b[r] = ns[v, r]; c[r] = busy[v, r]; d[r] = rss[v, r]
            e[r] = p50[v, r] + 0; f[r] = p99[v, r] + 0; g[r] = p999[v, r] + 0
            x[r] = rps[v, r] / rps["aspnet", r]; y[r] = ns["aspnet", r] / ns[v, r]
          }
          sort(a, rounds); sort(b, rounds); sort(c, rounds); sort(d, rounds)
          sort(e, rounds); sort(f, rounds); sort(g, rounds); sort(x, rounds); sort(y, rounds)
          lat = p50[v, 1] == "-" ? "-" : sprintf("%d/%d/%d", median(e, rounds), median(f, rounds), median(g, rounds))
          printf "%-26s %11.0f %11.1f %6.1f%% %8.1f %20s %8.2fx [%.2f..%.2f] %8.2fx [%.2f..%.2f]\n", \
            v, median(a, rounds), median(b, rounds), 100 * median(c, rounds), median(d, rounds), lat, \
            median(x, rounds), x[1], x[rounds], median(y, rounds), y[1], y[rounds]
        }
      }' /out/raw.tsv
  done
} | tee -a /out/bench.txt
