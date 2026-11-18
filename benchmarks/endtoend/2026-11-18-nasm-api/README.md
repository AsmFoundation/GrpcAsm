# 2026-11-18 — the Greeter on the NASM API (milestone C3)

The Greeter before milestone C3 (`ede4ecb`: hand-written hooks, its reply framed by
`ga_h2n_reply_parts` from a head built on the stack) against the Greeter on the NASM API
(`include/grpcasm.inc`: `say_hello` is `ga_app_unary` by alias, and the reply is written in
place with `GA_REPLY_BEGIN` / `GA_REPLY_END`).

## Instructions per call: callgrind, exact

[`greeter_ir.sh`](greeter_ir.sh), in `kvasm-valgrind:local`. Each Greeter runs under callgrind
(one worker) and serves 20,000, then 120,000 SayHello calls from h2load. The difference of the
two instruction totals over the 100,000 extra calls is the per-call cost; startup, shutdown
and the main thread cancel out, and the host's load does not enter.
[`results/greeter_ir.txt`](results/greeter_ir.txt):

| Greeter | instructions at 20,000 calls | at 120,000 | per call |
|---|---|---|---|
| before C3 | 14,654,214 | 86,978,470 | **723.2** |
| on the NASM API | 14,192,808 | 84,219,186 | **700.3** |

**23 instructions fewer per call (−3.2%)**, all in the reply. The template is written straight
into the output buffer, and the message is written once, where the socket reads it. Before,
the head was built on the stack and then copied into the buffer, which also meant passing
through `reply_fast`'s checks. The dispatch is unchanged: both Greeters are reached directly
(before, the handler was `ga_app_unary`; now it is its alias).

## End to end: h2load, noisy

[`greeter_ab.sh`](greeter_ab.sh), in `kvasm-toolchain`, the method of
`benchmarks/endtoend/2026-11-17-c-abi`. One worker on the last vCPU, h2load (8 connections ×
32 streams, 400,000 calls) on the two below, 8 interleaved rounds.
[`results/greeter_ab.txt`](results/greeter_ab.txt):

| Greeter | median req/s | min | max |
|---|---|---|---|
| before C3 | 747,106 | 725,496 | 782,638 |
| on the NASM API | 746,011 | 662,077 | 782,001 |

**No difference end to end**: the per-round ratios run from 0.86 to 1.04. 23 instructions are a
few nanoseconds. The server's one core spends about 1.34 µs per call end to end (747,000 calls
per second, kernel included), so the difference is under 1%. That is below this host's noise,
with other programs busy outside the VM (see `2026-11-18-client/README.md`).

> **Correction (2026-11-18, milestone C4).** "1.34 µs per call" was the client's pace, not
> the server's cost: this h2load setup is client-bound. The server's CPU time, measured in
> [`2026-11-18-dotnet`](../2026-11-18-dotnet/README.md) with the same shape, shows the
> worker busy only about a third of the time. The assembly Greeter costs **400 to 540 ns of
> server CPU per call**, kernel included, depending on the client's pace. The conclusion
> stands for another reason: 23 instructions are a few nanoseconds of that. This end-to-end
> comparison could not have shown them either way. The callgrind counts above are exact,
> independent of load, and stand.

Both Greeters pass the same suite: exact answers, h2spec 146/146, the 12 grpc-dotnet interop
tests. The first reply on each connection, and every message larger than a frame (the interop
tests send up to 1 MiB), take `ga_h2n_reply_begin`'s buffered path. The rest are written in
place.
