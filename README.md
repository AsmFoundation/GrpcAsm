# GrpcAsm

**A gRPC server and client in x86-64 assembly**, for consumers that want peak
performance with the fewest jumps, the least computation and the smallest stack
between the network and their code.

> **Status: in development.** Nothing is released yet. The plan, with every
> decision and milestone, is [docs/ROADMAP.md](docs/ROADMAP.md).

## What it will be

- **The engine:** the HTTP/2, HPACK, gRPC and event-loop engine of
  [KvAsm](https://github.com/AsmFoundation/KvAsm), generalized.
  - KvAsm passes h2spec 146/146, and its native engine doubled what one core
    serves over nghttp2.
  - It is generalized from one key-value service to any gRPC service:
    assembly-time route tables, unary and streaming calls, and hooks for
    consumers that batch work across an epoll batch.
- **A client:** an HPACK encoder and pipelined calls.
- **Four ways to use it:**
  - NASM (`grpcasm.inc`: register calling convention, handlers inlined at the
    dispatch site);
  - a C ABI (`grpcasm.h`, `libgrpcasm.so` / `.a`);
  - .NET (`GrpcAsm.Net`);
  - Python, through the C ABI.
- **Distributed as NuGet packages.** It builds with
  [AsmSdk](https://github.com/AsmFoundation/AsmSdk) (`AsmFoundation.Sdk`),
  AsmFoundation's project, dependency and build management for assembly on
  MSBuild and NuGet. AsmSdk is a product of its own, and GrpcAsm is one of its
  consumers. The repository is a solution of `.asmproj` and `.csproj`
  projects.

Runtime: Linux x86-64. Build machines: Windows, Linux and macOS, through
AsmSdk's bundled toolchain.

## What is here today

- **`src/GrpcAsm`:** the engine, a static library (`libgrpcasm.a`). An
  application defines the hooks in `include/grpcasm_hooks.inc` and a route
  table (`include/grpcasm_routes.inc`), then hands its process to
  `ga_server_run`.
- **`src/GrpcAsm.Native`:** `libgrpcasm.so`, the C ABI. It is
  [`include/grpcasm.h`](src/GrpcAsm.Native/include/grpcasm.h): register unary
  handlers at run time, then start and stop the server, or run it until a
  signal. Answers go through `grpcasm_call_reply` and `grpcasm_call_fail`. The
  .NET and Python APIs will build on it.
- **`samples/Greeter`:** `helloworld.Greeter/SayHello` on the engine alone. It
  is the smallest complete application, and the generic test service.
- **`samples/GreeterC`:** the same service in C on `libgrpcasm.so`. From
  outside, it is indistinguishable from the assembly Greeter.
- **`samples/KvServer`:** KvAsm's key-value service on the engine. It is the
  reference consumer, held to KvAsm's whole end-to-end suite.

## Building and testing

The solution builds with the .NET SDK on Windows, Linux or macOS. AsmSdk
brings NASM and the linker as NuGet packages.

```bash
dotnet build GrpcAsm.slnx -c Release
```

Then, with Docker:

| Command | What it checks |
|---|---|
| `tests/greeter.sh` | The Greeter: exact answers through `nghttp`, h2spec 146/146, startup refusals, a clean SIGTERM |
| `tests/greeter_c.sh` | The C Greeter on `libgrpcasm.so`, compiled with `-Werror`, through the same suite |
| `tests/capi.sh` | The C ABI's contract: every error code, the lifecycle, every call function through `nghttp` |
| `dotnet test --project tests/Greeter.Interop -c Release` | grpc-dotnet against the Greeter: sizes up to 1 MiB, 1,000 concurrent calls, health, error statuses |
| `tests/kvsuite.sh <KvAsm checkout>` | KvAsm's end-to-end suite against KvServer: protocol, streaming, shutdown, h2spec, the fuzzer |
| `benchmarks/inprocess/bench_ga.sh` | The request path timed in process against KvAsm 0.3.0 (see its header) |

- **The shell suites** run in KvAsm's toolchain image:
  `docker build --target toolchain -t kvasm-toolchain <KvAsm checkout>`.
- **The .NET tests** start the Greeter in a stock `debian:bookworm-slim`
  container through Testcontainers.

## License

[Apache-2.0](LICENSE).
