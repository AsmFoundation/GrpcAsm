# 2026-11-20 — your C# service on GrpcAsm against ASP.NET Core gRPC

**Question:** the same C# gRPC service classes, hosted once by GrpcAsm (the HTTP/2, HPACK,
gRPC and event-loop engine in assembly, `samples/GreeterNet`) and once by ASP.NET Core gRPC
(Kestrel and grpc-dotnet, `samples/GreeterAspNet`): how do the two servers compare, in calls
per second, the server's CPU per call, latency and memory?

**Answer:** GrpcAsm serves the same C# classes with 4 to 46 times less server CPU per call,
and 4 to 22 times the calls per second. The gap is largest where the server's own work
dominates (SayHello), and smallest where the service's own work does (the order, which both
servers parse with the same Google.Protobuf). Medians of 12 rounds; the ratios are paired
within each round:

| Workload | Server vCPUs | GrpcAsm + your class | ASP.NET Core gRPC | Calls per second | Server CPU per call |
|---|---|---|---|---|---|
| SayHello | 4 | 2,355,328 calls/s, 0.92 µs | 363,388 calls/s, 11.24 µs | **6.4×** (a floor: h2load is the limit) | **12.2× less** |
| Orders.Place, 989 bytes | 4 | 973,914 calls/s, 4.12 µs | 249,200 calls/s, 16.42 µs | **4.0×** (both saturated) | **4.0× less** |
| SayHello | 1 | 778,008 calls/s, 0.62 µs | 34,671 calls/s, 30.56 µs | **21.9×** (a floor) | **46× less** |
| Orders.Place, 989 bytes | 1 | 307,126 calls/s, 3.44 µs | 21,911 calls/s, 48.15 µs | **13.9×** (both saturated) | **13.9× less** |

- **Latency at a fixed rate both sustain (1 vCPU):**
  - SayHello at 10,000 calls/s: p50 / p99 / p99.9 of 134 / 388 / 698 µs on GrpcAsm against
    930 / 2,972 / 10,079 µs on ASP.NET Core (p50 6.4×, p99 7.3× lower, paired);
  - Orders at 5,000 calls/s: 230 / 548 / 854 µs against 1,060 / 3,851 / 15,130 µs (4.6× and
    7.3×).
- **Memory:** peak RSS 52–55 MB on GrpcAsm (the .NET runtime included), 101 MB on ASP.NET Core
  on one vCPU and 167–179 MB on four.
- **Your class costs what a delegate costs.** The bound `GreeterService` against SayHello as a
  typed delegate, paired: +7 ns per call (median; −255 to +217 over the rounds, above zero in 6
  of 12: noise). Over the assembly Greeter's 420 ns: raw span handler +47 ns, typed delegate
  +206 ns (C4 measured +201), the class +252 ns.
- **ASP.NET Core's GC mode does not explain it:** with Workstation GC it costs 0.96× of its
  Server GC's CPU per call (0.73 to 1.13 over the rounds).
- **ASP.NET Core costs 2.7–2.9 times less per call on four vCPUs than on one** (SayHello 30.6
  → 11.2 µs, Orders 48.2 → 16.4 µs), while GrpcAsm costs 1.2–1.5 times more (0.62 → 0.92 µs,
  3.44 → 4.12 µs). One vCPU is therefore ASP.NET Core's least favorable shape, and the
  four-vCPU rows are the fairer headline. The benchmark measures this, not why. A plausible
  cause, not measured here: on one vCPU, Kestrel's I/O threads and the thread pool take turns
  on it.
- **Where h2load is the limit:** GrpcAsm's SayHello. Its worker is 29–48% busy on one vCPU,
  and 213% of 400% on four, so its calls per second are a floor. ASP.NET Core is saturated in
  every set, at 105% of one vCPU and 403–405% of four (see "Limits" on the extra 5%). The
  order saturates GrpcAsm too, so those two rows compare full capacity on both sides.

## Full results

[`results/raw.tsv`](results/raw.tsv) has one line per run, and [`results/bench.txt`](results/bench.txt)
the log and bench.sh's own summary. Medians over 12 rounds, with quartiles; "vs aspnet" are
the medians of the per-round ratios, with their range:

**S1, SayHello, 1 vCPU** (latency at 10,000 calls/s):

| Variant | Calls/s [q1–q3] | CPU ns/call [q1–q3] | Busy | RSS MB | p50 / p99 / p99.9 µs | Calls/s vs aspnet | CPU: aspnet ÷ this |
|---|---|---|---|---|---|---|---|
| asm (NASM API) | 755,086 [712,703–767,606] | 420.1 [398.1–444.6] | 29.1% | 1.1 | 106 / 316 / 516 | 20.85× [16.50–33.83] | 72.75× [53.02–107.97] |
| net-raw (span handler) | 767,524 [762,874–774,610] | 473.0 [461.6–479.3] | 35.5% | 30.0 | 126 / 380 / 651 | 21.74× [18.21–34.42] | 64.13× [54.13–99.22] |
| net-typed (delegate) | 748,012 [714,043–763,866] | 614.9 [594.5–713.4] | 45.0% | 51.2 | 128 / 382 / 720 | 21.61× [16.23–28.81] | 49.75× [33.39–56.31] |
| **net-service (your class)** | **778,008 [726,050–783,419]** | **623.6 [612.3–807.0]** | 48.4% | 51.8 | **134 / 388 / 698** | **21.85× [17.77–31.09]** | **46.45× [35.83–56.37]** |
| **aspnet** | **34,671 [33,385–36,877]** | **30,561.5 [28,699.7–31,607.7]** | 105.5% | 101.3 | **930 / 2,972 / 10,079** | 1 | 1 |
| aspnet, Workstation GC | 35,528 [34,255–36,929] | 29,712.8 [28,596.2–30,988.3] | 105.5% | 102.4 | 876 / 2,541 / 10,564 | 1.04× [0.88–1.36] | 1.04× [0.88–1.36] |

**O1, Orders.Place, 1 vCPU** (latency at 5,000 calls/s):

| Variant | Calls/s [q1–q3] | CPU ns/call [q1–q3] | Busy | RSS MB | p50 / p99 / p99.9 µs | Calls/s vs aspnet | CPU: aspnet ÷ this |
|---|---|---|---|---|---|---|---|
| **net-service (your class)** | **307,126 [295,688–310,339]** | **3,437.6 [3,409.0–3,570.2]** | 105.1% | 53.3 | **230 / 548 / 854** | **13.91× [12.52–16.35]** | **13.91× [12.52–16.37]** |
| **aspnet** | **21,911 [20,311–23,027]** | **48,154.8 [45,920.4–51,950.6]** | 105.4% | 101.2 | **1,060 / 3,851 / 15,130** | 1 | 1 |

**S4, SayHello, 4 vCPUs:**

| Variant | Calls/s [q1–q3] | CPU ns/call [q1–q3] | Busy | RSS MB | Calls/s vs aspnet | CPU: aspnet ÷ this |
|---|---|---|---|---|---|---|
| asm (NASM API) | 2,238,528 [2,177,310–2,331,527] | 615.5 [601.8–642.5] | 115.5% | 1.6 | 6.19× [5.45–8.41] | 18.25× [15.41–24.82] |
| **net-service (your class)** | **2,355,328 [2,261,851–2,368,311]** | **920.1 [899.4–954.4]** | 212.7% | 52.1 | **6.41× [5.34–9.15]** | **12.20× [10.55–17.36]** |
| **aspnet** | **363,388 [334,137–378,976]** | **11,238.2 [10,861.4–12,145.8]** | 405.2% | 179.2 | 1 | 1 |

**O4, Orders.Place, 4 vCPUs:**

| Variant | Calls/s [q1–q3] | CPU ns/call [q1–q3] | Busy | RSS MB | Calls/s vs aspnet | CPU: aspnet ÷ this |
|---|---|---|---|---|---|---|
| **net-service (your class)** | **973,914 [947,992–997,204]** | **4,119.9 [4,016.8–4,226.1]** | 398.9% | 54.7 | **4.02× [3.12–4.29]** | **4.05× [3.20–4.31]** |
| **aspnet** | **249,200 [239,482–253,535]** | **16,418.2 [15,956.9–16,905.0]** | 402.6% | 166.9 | 1 | 1 |

**The run:** 2026-11-20, GrpcAsm 2431f2e with no uncommitted change, .NET 10.0.15 in both
publishes (SDK 11.0.100), ASP.NET Core 10.0.15, grpc-dotnet 2.85.0, WSL2 kernel 5.15.153.
The PC's load outside the VM was 52.7% before the run and 27.3% after
([`results/environment.txt`](results/environment.txt)). All 156 runs passed every check.

## What runs

- **The services are one set of classes,** in `samples/Greeter.Service`, unchanged on both
  servers:
  - `GreeterService`: `helloworld.Greeter/SayHello`, `"Hello " + name`, the template's code;
  - `OrdersService`: `shop.Orders/Place`, which prices an order. The request is
    `SampleOrders.Benchmark()`: 12 lines, a nested address, a coupon, 989 bytes. Its work is
    parsing 73 field values (35 of them strings) into 14 messages (the order, its address, 12
    lines), a checked sum over the lines, and a 57-byte receipt.
- **GrpcAsm** binds them with `Greeter.BindService(server.ServiceBinder, new GreeterService())`
  (and `Orders.BindService`), the line ASP.NET Core spells
  `app.MapGrpcService<GreeterService>()`. A call runs inline on the engine's worker: the
  request through the method's marshaller over the engine's receive buffer, the handler, a
  `ServerCallContext`, the response through the marshaller, `grpcasm_call_reply`.
- **ASP.NET Core** is the `dotnet new grpc` template's program and `appsettings.json`
  (logging at Information, `Microsoft.AspNetCore` at Warning), with an h2c endpoint and the
  content root pinned to the program's folder (see "The rival's setup" below).
- **The floor and the other C# styles,** on SayHello only: GrpcAsm's assembly Greeter
  (`samples/Greeter`, the NASM API), and GreeterNet with SayHello as a typed delegate
  (`Func<HelloRequest, HelloReply>`) and as a raw span handler (milestone C4's two styles).
- **Both .NET servers run .NET 10.0.15,** published self-contained for linux-x64, each with
  its project type's default GC: Server GC for ASP.NET Core (the web SDK's default),
  Workstation for GreeterNet (a console app's). A control row runs ASP.NET Core with
  Workstation GC too, so the GC mode cannot explain the gap.

## Method

[`run.sh`](run.sh) publishes both servers, writes the request bodies with
[`make_requests.cs`](make_requests.cs) (from the sample's own types), and runs
[`bench.sh`](bench.sh) in KvAsm's toolchain image (Debian 13, h2load 1.64) on the owner's PC:
an i9-13900K, Docker Desktop's WSL2 VM with 32 vCPUs. Per round, four sets:

| Set | Workload | Server vCPUs | Load (h2load) | Variants |
|---|---|---|---|---|
| S1 | SayHello("world") | 1 | 8 connections × 32 streams, 2 threads | asm, net-raw, net-typed, net-service, aspnet, aspnet (Workstation GC) |
| O1 | Orders.Place, 989-byte order | 1 | the same | net-service, aspnet |
| S4 | SayHello("world") | 4 | 32 × 32, 8 threads | asm, net-service, aspnet |
| O4 | Orders.Place | 4 | the same | net-service, aspnet |

Each run:

1. **A fresh server,** the whole process pinned with `taskset` to the set's vCPUs (the last
   one, or the last four). After the run every thread is checked to be allowed only on them:
   a .NET server's GC, JIT and I/O threads share those vCPUs with the request work, so the CPU
   per call is the whole cost. GrpcAsm runs one worker per vCPU; ASP.NET Core's thread pool
   sizes itself to the vCPUs it is pinned to.
2. **Warm-up: 12 s of load.** Both .NET servers' tiered JIT needs seconds of load to converge
   (5–12 s in [C4's drift runs](../2026-11-18-dotnet/README.md)), and every server gets the
   same. Then a 1 s pause: a timed h2load run ends by aborting its 256 calls in flight, and
   grpc-dotnet logs each cancellation with a stack trace; the pause keeps that burst out of
   the measured run.
3. **Saturation: 8 s.** h2load at full concurrency; the server's CPU time is read around it
   with [`cpuns`](cpuns.c) (every thread, user and system, in ns).
4. **Latency (1-vCPU sets): 8 s at a fixed rate both servers sustain,** 10,000 calls/s for
   SayHello and 5,000 for Orders (h2load `--rps`, 8 connections), every request's time logged;
   p50, p99 and p99.9 from the log.
5. **SIGTERM:** the server must exit 0, and a GrpcAsm server's stopped line must count no
   error.

**Every h2load run is checked exactly:** every call done succeeded, and the DATA bytes h2load
received equal the calls times the reply's framed size (18 bytes for SayHello, 57 for Orders).
An error answer carries no message, so one failed call anywhere breaks the equality, on a
server that counts nothing itself (ASP.NET Core) as on one that does.

**Rounds:** 12, with the variants' order rotated every round (12 is a multiple of every set's
size, so each variant holds each position equally often). Comparisons are made within a round
(paired): a change of the host's load that hits a whole round cancels out of the ratios.

## The rival's setup

- **The template's content root is the working directory.** Started from anywhere else, the
  program finds no `appsettings.json` and logs every request at Information. The pilot ran it
  that way by accident: 8,364 calls/s on one vCPU, with a log line per call. GreeterAspNet
  pins the content root to the program's folder, so the template's logging levels apply
  wherever it starts. That is the fair setup, and the one measured.
- **Server GC, as shipped, is the better GC here.** In the pilot, on one vCPU, Server GC cost
  28.9 µs per call and Workstation GC 32.7 µs. Both are measured in S1.
- **Pinning holds.** All of ASP.NET Core's threads were inside the pin. Server GC pins each
  heap's thread to one vCPU of the set, which is inside it too.

## Limits

- **h2load is the limit for GrpcAsm's SayHello:** its worker is a fraction busy (see the busy
  column), so GrpcAsm's calls per second there are a floor, not its capacity. The CPU per call
  is the exact comparison. ASP.NET Core is saturated in every set, and GrpcAsm in the Orders
  sets.
- **A saturated pinned server reads 104–105% busy** in this VM: its CPU clock runs a few
  percent ahead of the wall clock. Every server is measured the same way, and the ratios are
  within a round.
- **The host is shared:** other work ran on the PC outside the VM (host load before and after
  the run is in [`results/environment.txt`](results/environment.txt)). The rotation and the
  pairing cope with it; single runs carry its noise.
- **Not measured:** two machines (the client shares the PC with the server), streaming calls
  (GrpcAsm.Net hosts unary methods only), handlers that await I/O (GrpcAsm refuses them today),
  TLS (GrpcAsm has none).

**Reproduce:** build the solution first (`dotnet build GrpcAsm.slnx -c Release`), then:

```bash
bash run.sh                                                            # 12 rounds, about 75 minutes
SETS="S1" WARMUP_S=2 MEASURE_S=2 LATENCY_S=2 RESULTS=results-x bash run.sh 1   # a quick check
```
