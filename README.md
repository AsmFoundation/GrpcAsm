# GrpcAsm

**A gRPC server and client in x86-64 assembly**, for consumers that want peak
performance with the fewest jumps, the least computation and the smallest stack
between the network and their code.

> **Status: in development.** Nothing is released yet. The plan, with every
> decision and milestone, is [docs/ROADMAP.md](docs/ROADMAP.md).

## Your C# gRPC service, on an engine in assembly

An ordinary grpc-dotnet service class, the one ASP.NET Core hosts with
`app.MapGrpcService<GreeterService>()`, runs on GrpcAsm with one line:

```csharp
using var server = new GrpcAsmServer(new GrpcAsmServerOptions { Port = 50051, Workers = 4 });
Greeter.BindService(server.ServiceBinder, new GreeterService());  // your class, unchanged
server.Start();
```

The same classes ([`samples/Greeter.Service`](samples/Greeter.Service)), hosted by
GrpcAsm ([`samples/GreeterNet`](samples/GreeterNet)) and by ASP.NET Core gRPC
([`samples/GreeterAspNet`](samples/GreeterAspNet)), each pinned to the same vCPUs,
measured in 12 paired rounds
([evidence and method](benchmarks/endtoend/2026-11-20-aspnet/README.md)):

| Workload | Server vCPUs | GrpcAsm + your class | ASP.NET Core gRPC | Calls per second | Server CPU per call |
|---|---|---|---|---|---|
| SayHello | 4 | 2,355,328 calls/s | 363,388 calls/s | 6.4× (a floor: the load generator is the limit) | 12.2× less |
| A 989-byte order | 4 | 973,914 calls/s | 249,200 calls/s | 4.0× (both saturated) | 4.0× less |
| SayHello | 1 | 778,008 calls/s | 34,671 calls/s | 21.9× (a floor) | 46× less |
| A 989-byte order | 1 | 307,126 calls/s | 21,911 calls/s | 13.9× (both saturated) | 13.9× less |

At a fixed rate both sustain on one vCPU, p99 latency is 7.3 times lower, and peak memory is
about half (52–55 MB against 101–179 MB). The gap is smallest where the service's own work
dominates (the order's parsing is Google.Protobuf on both servers). Hosting the class costs
what a delegate costs. The bound class's tests compare its answers and errors with ASP.NET
Core's, call by call.

**What GrpcAsm does not do yet:** unary methods only; a handler must finish before it
returns (an `async` handler that really awaits is refused); no request headers, deadline or
peer in the context. Linux x86-64 at run time. Details in
[`src/GrpcAsm.Net`](#what-is-here-today) below.

## What it will be

- **The engine:** the HTTP/2, HPACK, gRPC and event-loop engine of
  [KvAsm](https://github.com/AsmFoundation/KvAsm), generalized.
  - KvAsm passes h2spec 146/146, and its native engine doubled what one core
    serves over nghttp2.
  - It is generalized from one key-value service to any gRPC service:
    assembly-time route tables, unary and streaming calls, and hooks for
    consumers that batch work across an epoll batch.
- **A client:** an HPACK encoder and pipelined calls (unary calls today;
  streaming next).
- **Four ways to use it:**
  - NASM (`grpcasm.inc`, here today: services declared in a few lines, the
    dispatch generated at assembly time, replies written in place);
  - a C ABI (`grpcasm.h`, `libgrpcasm.so` / `.a`; the shared library is here
    today);
  - .NET (`GrpcAsm.Net`, here today: inline handlers, and the client behind
    `Task`s);
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
  application written in NASM declares its service with
  [`include/grpcasm.inc`](src/GrpcAsm/include/grpcasm.inc):

  ```nasm
  GA_SERVICE "helloworld.Greeter"
      GA_UNARY "SayHello", say_hello
  GA_SERVICE_END
  GA_APP_END
  ```

  - **Generated at assembly time:** the route table, the dispatch (an alias
    for one method, so no instruction runs between the engine and the
    handler; a compare chain or a jump table for more), the health check and
    every hook the application does not write.
  - **Replies:** `GA_REPLY_BEGIN` / `GA_REPLY_END` write the reply in place,
    inside the frames in the connection's output buffer.
  - **Running it:** the process goes to `ga_server_run`, or to
    `ga_server_start` / `ga_server_stop` for a host that owns the signals.
- **`src/GrpcAsm.Native`:** `libgrpcasm.so`, the C ABI. It is
  [`include/grpcasm.h`](src/GrpcAsm.Native/include/grpcasm.h): register unary
  handlers at run time, then start and stop the server, or run it until a
  signal. Answers go through `grpcasm_call_reply` and `grpcasm_call_fail`. The
  .NET API builds on it, and the Python API will.
- **`src/GrpcAsm.Net`:** GrpcAsm from .NET, over the C ABI. A server whose
  handlers run inline on the engine's worker threads, and the assembly client
  behind `Task`s. Your grpc-dotnet service class, the same one ASP.NET Core
  hosts with `MapGrpcService<GreeterService>()`, runs on it with one line:

  ```csharp
  using var server = new GrpcAsmServer(new GrpcAsmServerOptions { Port = 50051, Workers = 4 });
  Greeter.BindService(server.ServiceBinder, new GreeterService());  // the class, unchanged
  server.Start();

  await using GrpcAsmClient client = await GrpcAsmClient.ConnectAsync("127.0.0.1", 50051);
  HelloReply reply = await client.CallAsync(client.Method("/helloworld.Greeter/SayHello"),
      new HelloRequest { Name = "asm" }, HelloReply.Parser);
  ```

  - **Service classes:** `GrpcAsmServer.ServiceBinder` is the
    `ServiceBinderBase` that Grpc.Tools' generated `BindService` registers
    with, with no reflection (NativeAOT-safe). The request and the response go
    through the method's own marshallers, with a `ServerCallContext` per call.
    Errors reach clients exactly as from ASP.NET Core: the tests call both
    servers and compare. The limits today: unary methods only (a streaming
    method is refused when the service is bound); a handler's `Task` must be
    complete when it returns (an `async` method that really awaits is
    answered UNIMPLEMENTED); no request headers, deadline or peer in the
    context, and custom response headers or trailers are refused.
  - **Delegate handlers:** typed (Google.Protobuf), or raw over spans, with
    `GrpcAsmProtobuf.TryGetBytes` reading fields in place through the
    engine's decoder. Every handler answers before it returns, as the C ABI
    requires, so a handler that blocks stalls its worker.
  - **Exceptions** are answered as grpc-dotnet answers them (`RpcException`
    with its status, anything else UNKNOWN) and never cross into the engine.
  - **The cost of a .NET handler** at steady state, in server CPU per call,
    paired against the assembly Greeter's 540 ns: +77 ns raw and +201 ns
    typed. A C handler costs +11 ns. The typed handler reaches its steady
    state after seconds of load, once the tiered JIT has converged
    ([evidence](benchmarks/endtoend/2026-11-18-dotnet/README.md), with its
    precision).
- **`samples/Greeter`:** `helloworld.Greeter/SayHello` on the engine alone,
  declared with the NASM API. It is the smallest complete application, and
  the generic test service.
- **`samples/GreeterC`:** the same service in C on `libgrpcasm.so`. From
  outside, it is indistinguishable from the assembly Greeter.
- **`samples/Greeter.Service`:** the C# services of the comparison below,
  ordinary grpc-dotnet classes: `GreeterService` (SayHello) and
  `OrdersService` (`shop.Orders/Place`, which prices a ~1 KiB order).
- **`samples/GreeterNet`:** those classes on `GrpcAsmServer`, bound through
  `ServiceBinder` (`GREETER_MODE=service`, the default), or SayHello as a
  typed or a raw delegate (`typed`, `raw`). It passes the Greeter's suite in
  every mode. A request that is not a valid `HelloRequest` is refused as each
  way of writing the handler refuses it: INVALID_ARGUMENT for the delegates,
  UNKNOWN for the class (as ASP.NET Core answers it).
- **`samples/GreeterAspNet`:** the same classes on ASP.NET Core gRPC (Kestrel
  and grpc-dotnet), set up as `dotnet new grpc` sets them up: the rival.
- **`samples/KvServer`:** KvAsm's key-value service on the engine. It is the
  reference consumer, held to KvAsm's whole end-to-end suite.
- **The client** (`src/GrpcAsm/client.asm`, `include/grpcasm_client.inc`; in
  C, `grpcasm_client_*` in `grpcasm.h`):
  - one HTTP/2 connection with pipelined unary calls and a callback per call;
  - socket mode, with a blocking unary call, or bytes in and bytes out;
  - from a method's second call, its headers are 6 indexed bytes, and a
    response that arrives in one read reaches its callback without a copy.
  - Measured in kvbench against its nghttp2 client, on KvAsm 0.3.0, where
    the client is the limit: 2.54× the calls per second, at 0.37× the client
    CPU per call, with 17% less server CPU per call
    ([evidence](benchmarks/endtoend/2026-11-18-client/README.md), including
    the server-bound case and its loopback caveat).
- **`samples/GreeterClient`:** SayHello from NASM through the client, with no
  server code linked.

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
| `tests/nasmapi.sh` | The code `grpcasm.inc` generates, called directly: the route table, the dispatch as alias, compare chain and jump table, the health check, the hooks |
| `tests/client.sh` | The client against the Greeter, `capi_server` and a scripted HTTP/2 server (GOAWAY, RST_STREAM, 1xx, CONTINUATION, deadlines, a response split at every byte, ...), then the NASM client |
| `tests/dotnet.sh` | GrpcAsm.Net's 56 tests on Linux (in the .NET SDK image; on a Linux machine, `dotnet test --project tests/GrpcAsm.Net.Tests -c Release`): .NET handlers called by grpc-dotnet; the same service classes on GrpcAsm and on Kestrel in one process, their answers and errors compared; the client against them and against Kestrel; the protobuf helper |
| `tests/greeter_net.sh` | The .NET Greeter, published self-contained, through the Greeter's suite in each mode: the bound class, the typed and the raw delegate |
| `dotnet test --project tests/Greeter.Interop -c Release` | grpc-dotnet against the Greeter (sizes up to 1 MiB, 1,000 concurrent calls, health, error statuses), and the NASM client against a grpc-dotnet (Kestrel) server |
| `tests/kvsuite.sh <KvAsm checkout>` | KvAsm's end-to-end suite against KvServer: protocol, streaming, shutdown, h2spec, the fuzzer |
| `benchmarks/inprocess/bench_ga.sh` | The request path timed in process against KvAsm 0.3.0 (see its header) |

- **The shell suites** run in KvAsm's toolchain image:
  `docker build --target toolchain -t kvasm-toolchain <KvAsm checkout>`.
- **The interop tests** start the Greeter in a stock `debian:bookworm-slim`
  container through Testcontainers.

## License

[Apache-2.0](LICENSE).
