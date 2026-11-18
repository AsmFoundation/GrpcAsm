# End to end: SayHello through the C ABI against the assembly Greeter

**Question:** what does a C handler behind `libgrpcasm.so` cost, against the
assembly Greeter? Through the C ABI, each call pays for an indirect call
through the registered function pointer and a `grpcasm_call` built in the
adapter's frame. `samples/GreeterC` also `malloc`s and copies each reply.

**Answer:** nothing measurable end to end. The two medians are 0.15% apart,
well inside the spread between rounds.

> **Correction (2026-11-18, milestone C4).** This setup is client-bound, so it
> could not have shown a cost on the server's side. The server's CPU time,
> measured in [`2026-11-18-dotnet`](../2026-11-18-dotnet/README.md) with the
> same h2load shape, shows the assembly Greeter's worker busy only about a
> third of the time. Equal calls per second followed from that. The CPU time
> per call does show the cost: the C Greeter takes **11 to 56 ns more server
> CPU per call** than the assembly one. That is the function-pointer call, the
> `malloc`, the copy and the `free`, out of 400 to 540 ns per call; the paired
> medians of three runs vary with the host's load. "Nothing measurable" is
> withdrawn: the cost is small, not zero.

## Results

One worker, pinned to vCPU 31 of 32. `h2load` ran on vCPUs 29–30 with 8
connections, 32 concurrent streams each, and 400,000 SayHello("world") calls
per run. There were 6 rounds; each round ran both servers in turn.

| Server | Median | Min | Max |
|---|---|---|---|
| `samples/Greeter` (assembly) | 755,153 calls/s | 712,927 | 787,782 |
| `samples/GreeterC` (C, on `libgrpcasm.so`) | 753,994 calls/s | 704,075 | 777,351 |

Every call of every run succeeded (400,000 of 400,000).

```text
server on vCPU 31 (1 worker), h2load on 29,30; 6 rounds
  asm: requests: 400000 total, 400000 started, 400000 done, 400000 succeeded
  c: requests: 400000 total, 400000 started, 400000 done, 400000 succeeded
asm  median     755153 req/s   min     712927   max     787782   (6 rounds)
c    median     753994 req/s   min     704075   max     777351   (6 rounds)
```

## Method and limits

[`cabi_bench.sh`](cabi_bench.sh) ran inside the `kvasm-toolchain` image on the
owner's PC, through Docker Desktop's VM. It builds the C Greeter with `gcc -O2`
against `grpcasm.h` and `libgrpcasm.so`, as `tests/greeter_c.sh` does.

**The caveat:** this is end to end, with real sockets and a load generator, on
a host that other work shares. It can show that the C ABI costs nothing next to
a call's system calls and HTTP/2 framing. It cannot resolve a few nanoseconds.
That would need an in-process harness, as `benchmarks/inprocess` does for
KvServer.

**Reproduce:**

```bash
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "<GrpcAsm>/samples/Greeter/bin/Release:/g:ro" \
  -v "<GrpcAsm>/src/GrpcAsm.Native/bin/Release:/libga:ro" \
  -v "<GrpcAsm>/src/GrpcAsm.Native/include:/inc:ro" \
  -v "<GrpcAsm>/samples/GreeterC:/src:ro" \
  -v "<this folder>:/scripts:ro" kvasm-toolchain:latest bash /scripts/cabi_bench.sh 6
```

Mount the library anywhere but `/lib`: a mount there hides the container's own
`/lib`, dynamic loader included, and nothing can start.
