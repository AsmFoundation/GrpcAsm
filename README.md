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
- **Distributed as NuGet packages,** built with
  [AsmSdk](https://github.com/AsmFoundation/AsmSdk) (`AsmFoundation.Sdk`). The
  repository is a solution of `.asmproj` and `.csproj` projects.

Runtime: Linux x86-64. Build machines: Windows, Linux and macOS, through
AsmSdk's bundled toolchain.

## License

[Apache-2.0](LICENSE).
