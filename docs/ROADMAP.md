# GrpcAsm — the plan

This is the single plan for **GrpcAsm** (`AsmFoundation/GrpcAsm`): a gRPC server
**and** client in x86-64 assembly, with NASM, C, .NET and Python APIs, distributed
as NuGet packages.

GrpcAsm builds with **AsmSdk** (`AsmFoundation/AsmSdk`, NuGet
`AsmFoundation.Sdk`).

- **AsmSdk is a product of its own:** enterprise-grade project, dependency and
  build management for assembly, on MSBuild and NuGet, for any assembly
  codebase.
- **GrpcAsm is one consumer of it, not its purpose.** Milestone A below records
  the AsmSdk work GrpcAsm depends on.
- **AsmSdk keeps its own roadmap, changelog and releases.**

Everything here was decided by the owner on 2026-11-17, from options laid out side
by side. Milestones are cut so that each one ends tested, committed and pushed.
Each later milestone builds only on what an earlier one shipped.

## Principles

1. **Peak performance for every consumer.** In the owner's words: "Really hack in
   the abilities of the assembly language as any consumer of server will must be
   able to peak performance and least jumps or compute or stack". Concretely:
   - **Zero-copy:** a handler reads its request where it lies in the receive
     buffer, and writes its reply into the send queue, framed in place.
   - **No stack frames that the API imposes:** a leaf handler needs no prologue.
     The NASM convention passes everything in registers.
   - **Specialization at assembly time:** route tables and dispatch are built by
     NASM macros. Handlers can be inlined at the dispatch site, so a route costs
     no indirect call.
   - **Steady state is one compare:** KvAsm's header-block cache turns a repeated
     request header block into its route with one compare. GrpcAsm keeps that
     path for every route.
   - **Batches:** handlers can defer their replies to the end of an epoll batch,
     for example to prefetch. KvAsm's GET pipeline is the reference user.
2. **Measured, not argued.** Every design that has a rival is decided by a paired
   measurement, KvAsm's rule. The defaults below that are marked "by
   measurement" stay open until then.
3. **Linux x86-64 at runtime.** The server and client run on Linux x86-64, like
   KvAsm. The toolchain builds them on Windows, Linux and macOS.
4. **Every public claim has evidence,** kept in a claims ledger as KvAsm does.

## Owner's decisions (2026-11-17)

| Question | Choice | Note |
|---|---|---|
| Scope | Server **and client**, then KvAsm rebuilt on GrpcAsm | "least jumps or compute or stack" |
| Public APIs | NASM (`grpcasm.inc`), C ABI (`grpcasm.h`), .NET (`GrpcAsm.Net`) | plus **Python through the C ABI** |
| Toolchain | **Bundled in NuGet:** NASM + LLVM `ld.lld` / `llvm-ar` | no WSL, apt or Docker needed to build |
| Home | **Two public repos:** AsmFoundation/AsmSdk and AsmFoundation/GrpcAsm | published to nuget.org; Apache-2.0 |

## What the prototype proved (2026-11-17)

These ran in a throw-away prototype before this plan was written:

- `dotnet build` of a `.slnx` resolved a custom SDK named `AsmFoundation.Sdk` from
  a NuGet feed (`global.json` → `msbuild-sdks`).
- The SDK assembled `.asm` files with NASM and linked a Linux shared object
  exporting the right symbol, with an SONAME. It ran from Windows, through WSL.
- Incremental builds skipped up-to-date work.

**Gotchas found:**

- `.slnx` needs `Type="13B669BE-BB05-4DDF-9536-439F39A36129"` (generic MSBuild
  project) for the `.asmproj` extension.
- An SDK riding on `Microsoft.NET.Sdk` must define an empty
  `CreateManifestResourceNames`, because an unknown extension gets no language
  targets.
- A persistent MSBuild node caches SDK files. Use `-nodeReuse:false` while
  iterating on the SDK.

## Milestone A — AsmSdk 0.1.0, the build system GrpcAsm uses

**Status (2026-11-17): released as AsmFoundation.Sdk 0.1.0.**

- `github.com/AsmFoundation/AsmSdk`, tag `v0.1.0`.
- CI is green on win-x64, linux-x64 and osx-arm64. `tests/run.py` passes 21/21
  on each: Linux runs the outputs, the other two build and inspect them.
- Trusted publishing pushed `AsmFoundation.Sdk` and the three
  `AsmFoundation.Toolchain.<rid>` packages to nuget.org.
- **Milestone F is de-risked:** KvAsm's unmodified server builds with the SDK
  on Windows (NASM 3.02 + `ld.lld`, glibc through the stub, 14 s, a 308 KB
  PIE). KvAsm's whole end-to-end suite passes against that binary: every
  phase, h2spec 146/146, fuzzing 3,000 connections plus the request matrix.
  - **What is left for F:** the official image is a static-PIE
    `FROM scratch` build with glibc linked in. An SDK build links glibc
    dynamically, so the image would carry glibc, or the static link would use
    `AsmToolchain=System`. That is a decision to measure, not assume.

**Packages:**

- `AsmFoundation.Sdk` is the MSBuild SDK (package type `MSBuildSdk`). A project
  starts with `<Project Sdk="AsmFoundation.Sdk">`.
- `AsmFoundation.Toolchain.<host-rid>` carries NASM, `ld.lld` and `llvm-ar` for
  `win-x64`, `linux-x64` and `osx-arm64`. The SDK downloads the one that matches
  the build machine (a `PackageDownload` during restore). Every host produces the
  same Linux x86-64 ELF output.

**The `.asmproj` model (rides on `Microsoft.NET.Sdk` like Microsoft's NoTargets):**

- `OutputType`: `Library` (shared `.so`), `StaticLibrary` (`.a`), `Exe` (static
  or PIE executable), `Objects`.
- Sources: `**/*.asm` by default (`AsmSource` items). Include directories come
  from `AsmIncludeDirectory` items, preprocessor symbols from `AsmDefine`. Extra
  NASM flags go in `AsmFlags`, defaulting to `-w+all -w+error`.
- **Incremental builds:** NASM `-MD` dependency files, so editing an `.inc`
  rebuilds exactly the sources that include it.
- **Hosted vs freestanding:**
  - A hosted library (it calls libc) links against a libc stub that the SDK
    generates. It gets `DT_NEEDED libc.so.6` without a Linux sysroot, so it
    builds on Windows and macOS.
  - Freestanding code (no libc) links with nothing.
  - `AsmToolchain=System` uses the machine's `nasm`, `ld` and `gcc` instead, for
    links that need a real sysroot (for example KvAsm's static glibc).
- **References:**
  - **ProjectReference** between asmprojs links the referenced output and adds
    its include directories.
  - **PackageReference** to an asm package does the same through the package's
    `build/` props.
  - A **csproj** referencing an asmproj gets the `.so` copied next to it, for
    P/Invoke tests.
- **Pack:** `dotnet pack` writes the native NuGet layout:
  - `include/` (`.inc`, `.h`);
  - `src/` (optional `.asm` sources, for consumers who specialize at assembly
    time);
  - `native/linux-x64/*.a` (not `lib/`, which NuGet treats as managed
    assemblies) and `runtimes/linux-x64/native/*.so`;
  - generated `build/<id>.props`/`.targets` that wire all of the above into a
    consuming asmproj.
- **Versioning:** NuGet package versions are the dependency versions. An asm
  library is pinned like any .NET library.

**Exit criteria:**

- CI on ubuntu, windows and macos builds the sample solution: a shared library,
  a static library, an executable, a package consumed through PackageReference
  from a local feed, and a csproj that P/Invokes the shared library.
- The Linux job runs the outputs.
- Packages are published through nuget.org trusted publishing (a new policy for
  AsmFoundation/AsmSdk).

## Milestone B — GrpcAsm server

**Status (2026-11-17): steps 1 to 4 of 5 done.**

**Step 1 — physical split, no instruction changed (done):**

- `src/GrpcAsm/GrpcAsm.asmproj` builds `libgrpcasm.a` (131 KB) from
  KvAsm's `h2n`, `hpack`, `worker`, `pool`, `log` and `util`.
- `samples/KvServer/KvServer.asmproj` is the rest of KvAsm (store, cuckoo
  table, snapshot, `grpc.asm`, configuration, `main`). It links the engine
  through a ProjectReference.
- Both build from the published AsmFoundation.Sdk 0.1.0.
- **Verified:** `tests/kvsuite.sh` runs KvAsm's whole end-to-end suite
  against the split binary and every phase passes (h2spec 146/146, the
  500-conversation matrix exact, 3,000 fuzzed connections). That is the gate
  for every following step.

**Step 2 — the engine's own names (done):**

- The 37 symbols the engine defines are now `ga_*` in both projects. They
  are its interface: the `ga_h2n_*` reply functions, `ga_hpack_*`,
  `ga_pool_*`, `ga_worker_*`, `ga_logb_*`, `ga_keyeq` and others.
- **The application's hooks keep their `kv_*` names** (`kv_grpc_*`,
  `kv_qsbr_*`, `kv_store_reclaim*`, `kv_hcache_*`): they are what step 3
  replaces.
- **The include split:**
  - `kvasm.inc` → the engine's `grpcasm_sys.inc` (syscall numbers, errno,
    mmap) and the application's `kvasm.inc` (key hash, private cache, futex,
    store structures);
  - `pbstream.inc` moved to the application.

  The engine assembled without them, which proves it uses nothing of the KV
  definitions.
- `kv_tag_match` (the store's tag scan, unused by the engine) moved unchanged
  to `samples/KvServer/tagmatch.asm`.
- **Verified:** `tests/kvsuite.sh` passes every phase.

**Step 3 — the hook interface (done):**

- `src/GrpcAsm/include/grpcasm_hooks.inc` declares and documents twelve
  `ga_app_*` hooks: their registers, results, threads and when each one runs.
  They are now the only way the engine calls the application. `h2n.asm` and
  `worker.asm` include the file in place of their lists of KV symbols.
  - **Per worker,** each taking only the `Worker*`: `ga_app_worker_init`,
    `_fini`, `_resume` (after every wake-up), `_pause` (before every sleep and
    at exit) and `_tick` (once per housekeeping pass).
    - `init` returns 0 or a negative errno. The worker logs a failure as its
      own setup step (`step=ga_app_worker_init`).
    - `fini` must accept a worker whose `init` failed or never ran.
  - **Per connection and stream:** `ga_app_dispatch`, `ga_app_batch_end`,
    `ga_app_stream_append`, `ga_app_stream_data`, `ga_app_stream_fill`,
    `ga_app_stream_release` and `ga_app_free_streams`. These are KvAsm's
    `kv_grpc_*` functions, renamed for what they are.
- **Two generic `Worker` fields:**
  - `Worker.table` became `Worker.app`, the context passed to
    `ga_worker_create`;
  - `Worker.hcache` became `Worker.app_worker`, the application's per-worker
    slot.

  The engine reads neither.
- KvServer's new `hooks.asm` runs exactly the KV code that the worker used to
  call directly: the private record cache, QSBR online and offline, and
  reclamation.
- **How the hooks are bound:** they are link-time symbols, so the engine calls
  them with a direct `call rel32`. There is no pointer to load and nothing to
  register, and a missing hook fails the link. The linked `kvserver` has no
  dynamic relocation and no `.dynsym` entry for any `ga_app_*` symbol.
- **What it costs, measured on the objects:**
  - The per-request code did not change. Assembled before and after, `h2n`,
    `hpack` and `pool` and KvServer's `grpc`, `store` and `main` have
    byte-identical `.text` and the same relocation counts. Only `worker.o`
    changed.
  - Per epoll pass, the pause and resume hooks each add one direct `jmp` and
    two loads from the `Worker` (KvServer's hooks tail-call `kv_qsbr_*`).
    Each pass already costs an `epoll_wait` system call.
  - The paired A/B against KvAsm 0.3.0 (milestone F) measures the whole.
- **Verified:**
  - `tests/kvsuite.sh` passes every phase: h2spec 146/146, the
    500-conversation matrix exact and 3,000 fuzzed connections. Phase 2b runs
    through the private caches that `ga_app_worker_init` now creates.
  - The failure path was forced in a container. With both caches at 24 bits
    under a 1 GiB `ulimit -v`, worker 0 logs `worker setup failed
    step=ga_app_worker_init errno=12` and startup ends cleanly (exit 1). With
    the caches off, the server starts and stops cleanly under the same cap.

**Step 4 — the generic half of `grpc.asm` in the engine (done):**

- **The engine's call layer:** `src/GrpcAsm/grpc.asm`, functions
  `ga_grpc_*`. Every status, every message text and the order of the checks
  are KvAsm's, which keeps KvAsm's suite a valid gate. Only the 405/415 body
  texts no longer name KvAsm. The layer covers:
  - body buffering within the per-stream and per-connection budgets;
  - `ga_grpc_dispatch`: the 405/415 checks, UNIMPLEMENTED, RESOURCE_EXHAUSTED,
    the 5-byte framing and the compression rules;
  - the health service, built in;
  - the early 405/415 of a client-streaming request (`ga_grpc_stream_data`);
  - stream release and teardown;
  - `ga_grpc_refuse` and `ga_grpc_write_prefix` for applications.
- **`ga_grpc_dispatch` is frameless:** every path is a tail call, into the
  application, the health check or a reply.
- **The application's areas, sized at assembly time:**
  - **`Stream.app`** (`GA_STREAM_APP_SIZE`, 72 bytes) replaces KvAsm's nine KV
    fields in `Stream`. The `Stream` stays 224 bytes, so it still fits one
    256-byte pool block. KvServer overlays its `KvCall` there, with an
    assembly-time check that it fits.
  - **`Conn.app`** (`GA_CONN_APP_SIZE`, 8 bytes) holds KvServer's upload
    budget (`KvConn`).
  - **The deferred-answer list** stays the engine's: `Conn.batch_head`,
    `Stream.batch_next`, `ST_BATCHED`, `ST_CLOSED`.
- **`ST_APP_STATE`:** the application sets this flag while `Stream.app` holds
  something to release. The engine's `stream_free` then calls
  `ga_app_call_release` first, however the stream ends. Every other stream is
  still freed with one call. KvServer clears the flag when a Put's record is
  published.
- **The hooks are twelve again:**
  - the five worker hooks;
  - `ga_app_unary` (a validated message), `ga_app_stream_data`,
    `ga_app_stream_end` and `ga_app_stream_fill`;
  - `ga_app_batch_end`, `ga_app_call_release` and `ga_app_health_service`.

  `ga_app_dispatch`, `_stream_append`, `_stream_release` and `_free_streams`
  became the engine's own (`ga_grpc_*`).
- **`include/grpcasm_reply.inc`** has the static reply-table macros (`CSTR`,
  `NV`, `TRAILERS_ONLY`) and the `GRPC_*` codes, for the engine and its
  applications.
- **KvServer's `grpc.asm`** went from 2,349 to 1,966 lines. What is left is
  the KV service: decode, batch, Upload, Download. The engine's new
  `grpc.asm` has 785 lines, most of them documentation.
- **Measured** (`benchmarks/inprocess/2026-11-17-steps-3-4`): KvAsm's
  in-process harness (`bench_h2`) drove KvAsm 0.3.0, step 3 and step 4, with
  12 interleaved rounds.
  - **GET:** 70.22, 70.08 and 70.11 ns per request, the same within noise.
  - **Health check:** 44.38, 44.44 and **41.71 ns**, so step 4 is 6.0% faster.
  - All three variants print the same output digests, so their replies are
    byte-identical.
- **Verified:** `tests/kvsuite.sh` passes every phase: h2spec 146/146, the
  matrix exact, 3,000 fuzzed connections, and the streaming limits and
  fairness phases.

**The next steps:**

- **Step 5:** route tables instead of `hpack.asm`'s hard-coded
  `/kvasm.v1.KvAsm/` prefix, plus a generic Echo/Greeter test service with its
  own tests (h2spec, a fuzz matrix, interop with grpc-dotnet).

**The plan for the server, as first written:**

- **Move the engine out of KvAsm:** `h2n` (HTTP/2), `hpack`, the gRPC framing,
  the epoll worker (two-phase loop, `SO_REUSEPORT`, drain, idle timeouts), the
  pool, the header-block cache and logging. Their tests come along (h2spec, the
  fuzzer with its request matrix, end-to-end suites) against a generic test
  service.
- **Generalize what was KvAsm-specific:**
  - a route table instead of the hard-coded `/kvasm.v1.KvAsm/` routes: built
    at assembly time (NASM API), or registered at run time (C ABI);
  - unary, client-streaming, server-streaming and bidirectional methods;
  - server streaming as a pull generator (`on_fill` when the flow-control window
    opens): no buffering, as KvAsm's Download does;
  - client streaming delivered as it arrives, as KvAsm's Upload does;
  - the standard health service built in;
  - `grpc-timeout` deadlines, metadata access, status and message trailers.
- **Hooks for consumers that batch:** begin and end of an epoll batch, deferred
  replies, and per-worker state (KvAsm's QSBR reclamation and prefetching GETs).

## Milestone C — the APIs

- **NASM** (`grpcasm.inc`):
  - `GA_SERVICE` / `GA_UNARY` / `GA_SERVER_STREAM` / … macros build the route
    table at assembly time.
  - A register calling convention: handlers may clobber only what they are told
    to, and no stack frame is required.
  - Reply macros (`GA_REPLY_BEGIN`/`GA_REPLY_END`) write in place.
  - An option to inline handlers at the dispatch site.
- **C ABI** (`grpcasm.h` + `libgrpcasm.so`/`.a`): server, routes, call and reply
  operations, streaming, client. Function-pointer handlers, a stable ABI and
  `ga_version()`.
- **.NET** (`GrpcAsm.Net`):
  - `GrpcAsmServer`, `GrpcAsmClient`, typed handlers through Google.Protobuf, and
    raw handlers over spans.
  - Inline (on the event loop) or offloaded (thread pool) handlers. The default
    is decided by measurement.
- **Python** (`grpcasm`, through the C ABI): server and client with Python
  callables. A wheel bundles `libgrpcasm.so`.

## Milestone D — GrpcAsm client

- **The HTTP/2 client side:**
  - preface and SETTINGS, odd stream ids, flow control;
  - an HPACK *encoder* (KvAsm only decodes): the static table plus a dynamic
    table, so a repeated call's header block is a few indexed bytes;
  - response HEADERS, DATA and trailers decoded with the existing decoder.
- **Calls:**
  - pipelined unary calls with batch submission and one flush;
  - streaming calls;
  - completion callbacks run on the client's event loop;
  - a blocking convenience layer for C and Python.
- **Measure it against the benchmark client KvAsm uses** (kvbench on nghttp2,
  which tops out near 9.3M requests/s on the test machine).

## Milestone E — packages and release 0.1.0

- **NuGet `GrpcAsm`** (native, built with AsmSdk): `include/`, `src/` (sources
  for specialization at assembly time), the static and shared libraries, and the
  build props.
- **NuGet `GrpcAsm.Net`.**
- **PyPI `grpcasm`** (a manylinux x86_64 wheel). This needs a PyPI account for
  trusted publishing. Until then the wheel ships as a release asset.
- Greeter samples in asm, C, C# and Python; interoperability tests against
  grpc-dotnet (and grpcio) in both directions.
- Docs and a claims ledger; CI and release workflows; trusted publishing; release
  0.1.0.

## Milestone F — KvAsm on GrpcAsm

- `KvAsm.asmproj` with `<PackageReference Include="GrpcAsm" />`. The KV methods
  become GrpcAsm handlers; the batch pipeline and reclamation use the hooks of
  milestone B.
- **The gate:**
  - KvAsm's full suite passes: h2spec, fuzzing, end-to-end, .NET 380 tests;
  - a paired A/B against KvAsm 0.3.0 shows no regression on any operation
    (KvAsm's standard workloads);
  - then KvAsm 0.4.0 is released.

## Risks and open questions

- **LLVM size.** Official release archives are 0.7–1.9 GB per OS. Only `ld.lld`
  and `llvm-ar` are extracted, but they are still large, statically linked
  binaries. If the packages come out too big, build `lld` from source with only
  the X86 target in the release workflow.
- **Glibc-static executables** (KvAsm today) cannot link without a sysroot.
  `AsmToolchain=System` keeps them building on Linux. A freestanding runtime is a
  separate decision, and its allocator would have to be measured against glibc's.
- **Python handlers** run under the GIL. The transport stays in assembly, but
  handler throughput is Python's.
- **The NuGet ID** `GrpcAsm` and the `AsmFoundation.*` prefix are free today (to
  be checked again before the first push). Reserving the prefix on nuget.org is
  worth doing.
