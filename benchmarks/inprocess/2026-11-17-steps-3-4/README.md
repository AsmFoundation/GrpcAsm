# In-process request path: KvAsm 0.3.0 against milestone B steps 3 and 4

**Question:** do steps 3 and 4 of milestone B cost anything per request?

- Step 3 made every call from the engine into the application go through a
  `ga_app_*` hook.
- Step 4 moved the generic half of KvServer's `grpc.asm` into the engine.

**Answer:** no. GET costs the same as KvAsm 0.3.0 within noise. The health
check is 6% cheaper after step 4. All three servers produce byte-identical
replies.

## Results

Minimum and median over 12 interleaved rounds. Each round runs every variant
once, in turn, pinned to the same vCPU.

| Workload | KvAsm 0.3.0 | Step 3 | Step 4 | Step 4 against KvAsm |
|---|---|---|---|---|
| GET of a 16-byte key, 100-byte value (1,024 keys) | 70.22 ns (median 71.64) | 70.08 ns (71.61) | 70.11 ns (71.32) | −0.2%, within noise |
| `grpc.health.v1.Health/Check` | 44.38 ns (44.66) | 44.44 ns (44.60) | **41.71 ns** (41.83) | **−6.0%** |

**Same output:**
- All three variants print the same output digest for each workload: GET
  `ac0261a8a9d4f821`, health check `230fab4af7318bff`.
- They send the same bytes out per batch: 2,224 for GET, 592 for the health
  check.
- The server counted every request.

This also cross-checks that the refactoring changed no reply. See
[`lines.out`](lines.out) for one full line per variant (cycles, p90, digest).

**Why the health check got cheaper:**
- Step 4's `ga_grpc_dispatch` is frameless. Its health check has its own
  small frame, and a decoder that only looks for field 1.
- Before, the health check went through KvServer's dispatch: a frame of 6
  pushes plus 104 bytes, and `kv_pb_decode_kv`.

**Why GET did not change:**
- Step 4 adds one direct tail call: `ga_grpc_dispatch` jumps to
  `ga_app_unary`.
- It also replaces three loads and ORs in `stream_free`'s fast path with a
  flag test.
- Neither shows above the noise.

## What was measured

The run uses KvAsm's audit harness unchanged: `bench_h2.c`, `benchabi.asm`
and `calib.asm` in KvAsm's
[`benchmarks/results/2026-11-15-asm-audit`](https://github.com/AsmFoundation/KvAsm/tree/main/benchmarks/results/2026-11-15-asm-audit).

**What the harness does:**
- It drives the server's own objects in process: `h2_process`, then the batch
  hook, then `conn_window_refill`.
- Each batch holds 16 pipelined unary requests on a hand-built `Worker` and
  `Conn`. There is no socket, system call or client.
- So the figure is the user-space request path: frame parsing, the
  header-block cache, stream open and close, dispatch, hashing, lookup and
  reply framing.
- It says nothing about kernel time, or about memory stalls at large key
  counts.
- The minimum of many short trials is repeatable to well under 1%.

**The three variants:**

| Name | What |
|---|---|
| `kvasm` | KvAsm 0.3.0 (60d7e81), `server/` built from source by its Makefile |
| `s3` | GrpcAsm at 85d066c (step 3), built with AsmFoundation.Sdk 0.1.0 |
| `s4` | GrpcAsm with step 4 (the commit that added this folder), same SDK |

[`bench_ga.sh`](bench_ga.sh) builds all three and runs the rounds.

- It ports the harness to the GrpcAsm names with `sed`: four engine names and
  `Worker.table` → `Worker.app`. Nothing else differs.
- `h2_process` and `conn_window_refill` are internal to `h2n.o`, so `objcopy`
  makes them global in a copy. The code under test is unchanged.

**Host:** the owner's PC, through Docker Desktop's VM (32 vCPUs), pinned to
vCPU 31, in the `kvasm-toolchain` image. Other work shares the host. That is
why the rounds are interleaved: every variant gets the same chances at a
quiet moment.

## Reproducing it

```bash
# A worktree of the step-3 commit, built:
git worktree add --detach ../ga-step3 85d066c
dotnet build ../ga-step3/GrpcAsm.slnx -c Release -nodeReuse:false
dotnet build GrpcAsm.slnx -c Release -nodeReuse:false

MSYS_NO_PATHCONV=1 docker run --rm \
  -v "<KvAsm checkout>/benchmarks/results/2026-11-15-asm-audit:/audit:ro" \
  -v "<KvAsm checkout>:/kvasm:ro" \
  -v "<step-3 worktree>:/s3:ro" -v "<this GrpcAsm tree>:/s4:ro" \
  -v "<results folder>:/out" -v "<folder holding bench_ga.sh>:/scripts:ro" \
  kvasm-toolchain:latest bash /scripts/bench_ga.sh 12
```

## A pitfall found while running it

**What happened:** the first run showed KvAsm 0.3.0 at 95.91 ns per GET, with
a different output digest and 1,184 bytes per batch.

**The cause:** the KvAsm checkout held a stale, ignored `server/build/` from
2026-11-15. `cp -r` gave the copied objects fresh timestamps, so `make`
considered them up to date and linked them.

**The fix:** the script now deletes `build/` after copying the tree.

**The lesson:** compare the digests before the times. The mismatched digest
exposed the stale objects at once.
