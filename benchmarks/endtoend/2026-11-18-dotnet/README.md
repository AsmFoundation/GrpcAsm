# 2026-11-18 — .NET handlers on GrpcAsmServer (milestone C4)

**Question:** what does a handler written in .NET (`GrpcAsm.Net`, over the C ABI) cost per
call, against the assembly and C handlers on the same engine?

**Answer, at steady state:** in the server's CPU time per call, paired within each round
against the assembly Greeter (540 ns per call in this setup):

| Greeter | handler | extra CPU per call (paired median) |
|---|---|---|
| `samples/GreeterC` | C, behind a function pointer; `malloc` + copy of the reply | **+11 ns** |
| `samples/GreeterNet`, raw | .NET reverse call; `GrpcAsmProtobuf` reads the name in place; the reply framed on the stack | **+77 ns** |
| `samples/GreeterNet`, typed | Google.Protobuf parses and serializes; two strings and two objects per call | **+201 ns** |

- **The precision is tens of nanoseconds.** The host was busy outside the VM, and two of
  the ten rounds caught interference that halved the assembly Greeter's throughput. Without
  those two rounds the medians are +37, +105 and +228 ns.
- **The typed handler needs its JIT to converge first.** It took 5 to 12 s of load here,
  with the JIT's background thread on the worker's vCPU. A 0.3 s warm-up measured it at
  +587 ns (see "The warm-up" below).
- **Calls per second did not differ:** h2load is the limit in this setup. The server's one
  worker is 34% busy for the assembly Greeter and 48% busy for the typed .NET one.

## The measure: the server's CPU time per call

The earlier Greeter benchmarks (`2026-11-17-c-abi`, `2026-11-18-nasm-api`) compared h2load's
calls per second. Measured here with the server's CPU time, that setup is **client-bound**:
the assembly Greeter's worker is busy 22 to 38% of the time (median 34%). Equal calls per
second therefore says nothing about the server's own cost. Those two READMEs now carry a
correction.

- **`cpuns`** ([cpuns.c](cpuns.c)) reads the server process's CPU clock
  (`clock_getcpuclockid`): every thread, user and system, in ns. bench.sh reads it just
  before and after the measured run. In this VM, `/proc/PID/schedstat` and
  `sum_exec_runtime` read zero, `/proc/PID/stat` counts 10 ms ticks, and WSL2 has no PMU,
  so `perf stat` cannot count instructions.
- **The whole server process is pinned to one vCPU,** so a .NET server's GC, JIT and signal
  threads are charged to it along with the worker: the number is the full cost of a call.
- **Compare within a round, never across runs.** In a client-bound loop the server's cost
  per call depends on the client's pace, through how many requests each wakeup finds. The
  assembly Greeter cost 398 ns per call when h2load ran at 718,000 calls/s (the 0.3 s
  warm-up run) and 540 ns at 638,000 (the final run).

## Results

[`results/`](results): 10 rounds; per run, a fresh server, 7,000,000 warm-up calls, then
2,000,000 measured. h2load: 8 connections × 32 streams, SayHello("world").

| Greeter | server CPU ns/call, median [q1–q3] | paired extra vs asm | server busy (median) | calls/s (median) |
|---|---|---|---|---|
| asm | 540.0 [511.0–559.0] | — | 33.8% | 637,588 |
| C | 566.0 [561.3–567.2] | +11.4 | 35.4% | 635,290 |
| .NET raw | 637.6 [592.1–687.4] | +77.3 | 39.7% | 642,483 |
| .NET typed | 751.5 [708.5–792.9] | +201.0 | 47.8% | 680,076 |
| .NET typed, `DOTNET_TieredCompilation=0` | 881.2 [829.4–885.0] | +300.4 | 54.6% | 631,051 |

The last row checks the warm-up. With tiering off, .NET compiles every method optimized at
its first call, without profile-guided optimization (PGO). Once the default tiered JIT has
converged, its PGO code must be at least as cheap. Here it is cheaper by 100 to 130 ns per
call (paired medians +201 against +300; medians 751.5 against 881.2), so the warm-up was
long enough.

**What the extra nanoseconds are made of.** This is an attribution by reasoning; the parts
were not timed separately.

- **.NET raw against C (+72 ns from the medians):** the .NET side pays three managed/native
  transitions per call:
  - the reverse call into managed code (the switch to cooperative mode and back, with a GC
    poll);
  - two P/Invokes, `grpcasm_pb_bytes` and `grpcasm_call_reply`, each with its own GC
    transition;
  - plus the `GCHandle` lookup and the delegate call.

  The C Greeter pays `malloc`, `free` and a copy instead.
- **Typed against raw (+114 ns):** parsing (a `HelloRequest` and its string), `"Hello " +
  name` (another string), a `HelloReply`, `CalculateSize` and `WriteTo` (UTF-8 both ways),
  and the gen-0 collections of what that allocates.

## The warm-up

The first full run used a warm-up of 200,000 calls (0.3 s):
[`results-warmup-200k/`](results-warmup-200k), 12 rounds, 400,000 measured calls, the
first version of bench.sh, whose summary shows differences of medians:

| Greeter | server CPU ns/call (median) | paired extra vs asm (median) |
|---|---|---|
| asm | 398.1 | — |
| C | 443.5 | +55.8 |
| .NET raw | 503.9 | +98.7 |
| .NET typed | 989.4 | +587.4 |

C and raw .NET agree with the final run within its precision. The typed handler did not: it
was still running unconverged JIT code.

- **The tiering check** ([`results-tiering-warmup-200k/`](results-tiering-warmup-200k), 8
  rounds, the same short warm-up): with tiering off, the typed handler cost 356 ns per call
  less than with tiering on. Every round agreed, with differences from −376 to −231 ns.
  Tiering made no difference to the raw handler.
- **A 2,000,000-call warm-up** ([`results-warmup-2m/`](results-warmup-2m), 4 rounds, about
  3 s) was still not enough for the typed handler (+787 ns). C (+47.5 ns) and raw .NET
  (+96.8 ns) repeated their values.
- **Drift** ([`drift.sh`](drift.sh), [`results-drift/drift.txt`](results-drift/drift.txt)):
  one server, successive 400,000-call windows.
  - With tiering on, the typed handler reached its steady cost after 5 s in one pass and
    12 s in the other. Once there, it is cheaper than with tiering off.
  - RSS stays flat (about 51 MB) and the thread count stays at 9: the high early numbers
    are the JIT, not a leak.

**For anyone measuring a .NET service on GrpcAsm:** warm it up for seconds of load, not a
number of calls, and check convergence (a tiering-off control, or windows that stop
falling).

## Method and limits

- **Where:** [`run.sh`](run.sh) on the owner's PC (i9-13900K, 32 logical CPUs, Docker
  Desktop's WSL2 VM with 32 vCPUs).
  1. It publishes `samples/GreeterNet` self-contained for linux-x64.
  2. Then it runs [`bench.sh`](bench.sh) in `kvasm-toolchain` (Debian 13, glibc 2.41). The
     image has no .NET runtime and no ICU, hence the self-contained, invariant-globalization
     publish.
  3. The C Greeter is compiled there with `gcc -O2 -Werror` against `libgrpcasm.so`, as
     `tests/greeter_c.sh` does.
- **What ran:** .NET 10.0.15 (the runtime pack in the publish), built with SDK 11.0.100.
  GrpcAsm 64ecffb plus the uncommitted C4 tree, committed with this folder.
- **The host was busy outside the VM:** 55 to 91% of its 32 logical CPUs, sampled before
  and after each run (`environment.txt`), from other Claude Code sessions and Python
  workers. Inside the VM nothing else ran.
- **The design copes with that load:**
  - the rotation puts each server in each position equally often;
  - the paired differences cancel whatever hits a whole round.
- **What remains is noise in single runs:** rounds 2 and 10 of the final run halved the
  assembly Greeter's throughput (1,160 ns per call).
- **Every run is checked:**
  - every call succeeded;
  - the server exited 0 on SIGTERM;
  - its stopped line counted exactly the calls made, with 0 errors.
- **Not measured:**
  - **A server-bound run.** Saturating one worker at 2 million calls/s needs more load
    generator than this host had free.
  - **Instruction counts for .NET.** There is no PMU in WSL2, and callgrind cannot follow
    JIT code reliably. The assembly Greeter's count is in `2026-11-18-nasm-api` (700.3
    instructions per call).

**Reproduce:** build the solution first (`dotnet build GrpcAsm.slnx -c Release`), then:

```bash
bash run.sh                                   # the final run: 10 rounds, 5 variants
WARMUP=200000 CALLS=400000 VARIANTS="asm c net-raw net-typed" RESULTS=results-x bash run.sh 12
```
