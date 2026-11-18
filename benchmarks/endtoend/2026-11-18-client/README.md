# 2026-11-18 — GrpcAsm's client against kvbench's nghttp2 client

Milestone D's measurement ([docs/ROADMAP.md](../../../docs/ROADMAP.md)): GrpcAsm's gRPC
client (`libgrpcasm.so`, `grpcasm_client_*`) against the client KvAsm is benchmarked with,
[kvbench](https://github.com/AsmFoundation/KvAsm/tree/main/benchmarks/kvbench) on nghttp2. Both
drive the same server, KvAsm 0.3.0.

## Method

- **One load generator, two protocol modules.** kvbench owns the sockets, the epoll loop, the
  workload, the latency histograms and the checks of every value. A protocol module only turns
  requests into bytes and bytes into completions.
  - `--protocol grpc` is KvAsm's own module on nghttp2, built exactly as KvAsm builds it
    (static-PIE, `build.sh`).
  - `--protocol grpcasm` is [`grpcasm.c`](grpcasm.c): the same calls and the same judging,
    through GrpcAsm's client in its bytes-in, bytes-out mode. kvbench's other sources are
    patched by four mechanical lines (the protocol's name and its table entry).
- **The server:** `kvasm:0.3.0` (image `sha256:e69cebef…`), 4 workers on vCPUs 0-3, preloaded
  once with 1,000,000 keys of 100-byte values. Both clients read the same keys from the same
  process.
- **The clients:** containers in the server's network namespace (loopback) and PID namespace
  (so kvbench reads the server's CPU time per thread, `--server-pid 1`).
- **Paired blocks:** each block runs both clients back to back, the order alternating between
  blocks; 2 s of warm-up, then 8 s measured. `analyze.cs` compares the two runs within each
  block, never absolute numbers from different moments.
- **The host:** a Windows PC (i9-13900K, 32 logical CPUs) running the WSL2 Docker VM
  (32 vCPUs). Other programs were busy outside the VM: 48.8% of the 32 logical CPUs, sampled
  before shape A (other Claude Code sessions, Python workers). Inside the VM nothing else ran.
  The paired design is what makes the ratios hold under that load. The absolute numbers are
  this session's, and are not comparable with other sessions.

Reproduce: `bash run.sh <KvAsm checkout> <results dir> [blocks]` (see the variables in its
header), then `dotnet run analyze.cs -- <results dir>`. The tables below were printed by
`analyze.py`; `analyze.cs`, its .NET port of 2026-11-18, prints them byte for byte the same
from the three results folders (Python's half-to-even rounding included).

## Shape A — client-bound: 2 client threads, 16 connections × 16 in flight

The client has 2 vCPUs against a 4-worker server, so throughput measures the clients. Results:
[`results-a-client-bound/`](results-a-client-bound).

| block | nghttp2 ops/s | GrpcAsm ops/s | ratio | nghttp2 client ns/req | GrpcAsm client ns/req | server ns/req (nghttp2) | server ns/req (GrpcAsm) | nghttp2 p50/p99 µs | GrpcAsm p50/p99 µs |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 0.96M | 2.47M | **2.57×** | 2221 | 817 | 967 | 793 | 187 / 602 | 83 / 330 |
| 2 | 0.98M | 2.49M | **2.54×** | 2170 | 808 | 956 | 792 | 189 / 610 | 83 / 326 |
| 3 | 1.02M | 2.58M | **2.53×** | 2087 | 783 | 887 | 746 | 175 / 569 | 82 / 313 |
| 4 | 1.03M | 2.41M | **2.33×** | 2066 | 834 | 888 | 806 | 175 / 578 | 86 / 334 |
| 5 | 0.97M | 2.47M | **2.53×** | 2190 | 815 | 954 | 793 | 185 / 602 | 83 / 338 |
| 6 | 1.00M | 2.58M | **2.57×** | 2121 | 788 | 939 | 734 | 181 / 602 | 82 / 309 |

- **Throughput:** median **2.54×**, range 2.33–2.57; GrpcAsm better in 6/6 blocks (sign test
  p = 0.031).
- **Client CPU per request:** median **0.372×** (about 2,130 ns → 800 ns), range 0.368–0.404;
  6/6.
- **Server CPU per request:** median **0.830×**, range 0.782–0.908; 6/6. The same server does
  17% less work per request when GrpcAsm's client calls it. Two things the client does explain
  it:
  - It sends each call's HEADERS and DATA frames back to back. The server then takes its fused
    path (one header parse, no stream-map lookup for the DATA). nghttp2 sends the HEADERS of
    several calls before their DATA frames, which the server handles one frame at a time.
  - Its request header block is 6 indexed bytes per call.
- **Latency:** p50 median 0.453×, p99 median 0.549×; 6/6 each.

The client CPU per request includes kvbench's own work (its epoll loop, `recv`/`send`, the
workload, histograms, value checks), which is the same in both modules: the ratio of the
libraries alone is lower still.

## Shape B — the standard shape: 16 client threads, 64 connections × 16 in flight

KvAsm's standard benchmark shape (16 client vCPUs, 64 connections × 16), against the same 4
server workers: the server is the bottleneck now. Results:
[`results-b-standard-shape/`](results-b-standard-shape).

| block | nghttp2 ops/s | GrpcAsm ops/s | ratio | nghttp2 client ns/req | GrpcAsm client ns/req | server ns/req (nghttp2) | server ns/req (GrpcAsm) | nghttp2 p50/p99 µs | GrpcAsm p50/p99 µs |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4.42M | 3.81M | **0.86×** | 2853 | 1255 | 895 | 1113 | 179 / 676 | 237 / 627 |
| 2 | 3.85M | 3.80M | **0.99×** | 3288 | 1299 | 914 | 1115 | 183 / 1044 | 230 / 791 |
| 3 | 3.29M | 3.23M | **0.98×** | 3745 | 1412 | 1004 | 1318 | 200 / 1516 | 268 / 987 |
| 4 | 3.77M | 3.52M | **0.94×** | 3342 | 1347 | 962 | 1203 | 196 / 963 | 245 / 897 |
| 5 | 3.77M | 3.43M | **0.91×** | 3325 | 1374 | 951 | 1231 | 198 / 954 | 251 / 897 |
| 6 | 3.78M | 3.63M | **0.96×** | 3323 | 1322 | 966 | 1173 | 196 / 954 | 247 / 791 |

- **Client CPU per request:** median **0.400×**, 6/6, as in shape A.
- **Throughput:** median **0.947×** (0.863–0.986), **lower** in 6/6 blocks.
- **Server CPU per request:** median **1.247×** (1.214–1.312), **higher** in 6/6.
- **Latency:** p50 1.266× (higher), p99 0.878× (lower), 6/6 each.

The same server spends 25% more CPU per request here, where it spent 17% less in shape A. Two
explanations were tested:

1. **Smaller batches at the server: disproved.** The faster client might send fewer requests
   per burst, so the server would read fewer per `read()`. `syscalls.sh` counts the server's
   reads (`/proc/1/io` syscr) per request. Both clients deliver **15.8 requests per read**, in
   shape B and in shape A alike: every read takes a connection's whole window of 16.
2. **Waking the client: confirmed.** On one machine over loopback, the server's `sendto()`
   also wakes the client thread that sleeps in `epoll_wait`, on the server's own CPU. Under
   WSL2 that wakeup is a VM-exiting interrupt; KvAsm measured it at about half a server core
   (KvAsm `benchmarks/results/2026-09-26-profile-memory`). GrpcAsm's client needs a third of
   the CPU here (client utilization 0.30 against nghttp2's 0.79), so its threads are asleep when
   responses arrive and must be woken. nghttp2's are mostly still running. In shape A both
   clients are saturated (utilization about 1.0) and never sleep, and there the server's cost
   per request fell. Shape C removes the wakeups.

## Shape C — the standard shape with busy-polling clients (diagnostic)

Shape B again, with kvbench's `--busy-poll`: client threads poll with a zero timeout and never
sleep, so no wakeup is charged to the server. This approximates a client on another machine,
woken by its own network card. Both clients burn their 16 vCPUs, so client CPU per request is
not meaningful here. 4 blocks (a sign test cannot pass p = 0.05 with 4; all 4 agree). Results:
[`results-c-standard-busy-poll/`](results-c-standard-busy-poll).

| block | nghttp2 ops/s | GrpcAsm ops/s | ratio | server ns/req (nghttp2) | server ns/req (GrpcAsm) | nghttp2 p50/p99 µs | GrpcAsm p50/p99 µs |
|---|---|---|---|---|---|---|---|
| 1 | 5.12M | 7.06M | **1.38×** | 752 | 600 | 130 / 1122 | 98 / 946 |
| 2 | 4.92M | 7.19M | **1.46×** | 758 | 589 | 132 / 1171 | 90 / 938 |
| 3 | 4.90M | 7.31M | **1.49×** | 768 | 579 | 126 / 1253 | 101 / 823 |
| 4 | 4.77M | 7.31M | **1.53×** | 773 | 582 | 121 / 1417 | 99 / 856 |

- **Throughput:** median **1.476×** (1.380–1.534), 4/4.
- **Server CPU per request:** median **0.766×** (0.753–0.798), 4/4: the server does 23% less
  work per request for GrpcAsm's client, the shape A effect (fused HEADERS+DATA, indexed
  headers) without the wakeups.
- **Latency:** p50 0.776×, p99 0.729×, 4/4 each.

## Verdict

- **GrpcAsm's client costs 0.37–0.42× nghttp2's CPU per request** (kvbench's own work
  included), in every shape: 2.4–2.7× cheaper.
- **Where the client is the limit, it moves 2.54× the requests** (shape A), at less than half
  the latency.
- **It also makes the server's work smaller:** 17% (shape A) to 23% (shape C) less server CPU
  per request, from the frame layout and the header encoding it sends.
- **One case goes the other way:** a server-bound benchmark on one machine with blocking
  clients (shape B). There the client's idleness costs the server its wakeups, and throughput
  is 0.95×. A client on another machine wakes on its own network card, which shape C
  approximates (1.48×). Confirming that with two machines is open: this host has one.
