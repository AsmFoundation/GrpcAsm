# In-process request path: milestone B step 5a (route tables)

**Question:** does looking routes up in the application's table
(`ga_app_routes`) cost anything per request? The table replaced
`hpack.asm`'s hard-coded `/kvasm.v1.KvAsm/` prefix and method names.

**Answer:** no. The lookup runs once per distinct `:path` field of a
connection: the HPACK meaning cache and h2n's header-block cache keep the
result. Each of the three remaining tests on the request path changed from
`cmp` against `M_UPLOAD` to a flag test: one instruction each, before and
after.

## Results

Minimum and median over 12 interleaved rounds, pinned to vCPU 31 of 32.
[`../bench_ga.sh`](../bench_ga.sh) ran
`bench_ga.sh 12 step4 step5a`:
- `step4` was a worktree of 3b6426d;
- `step5a` was the tree of the commit that added this folder.

| Workload | KvAsm 0.3.0 | Step 4 | Step 5a |
|---|---|---|---|
| GET of a 16-byte key, 100-byte value (1,024 keys) | 70.44 ns (median 71.05) | 70.08 ns (70.91) | 69.79 ns (70.27) |
| `grpc.health.v1.Health/Check` | 44.22 ns (44.43) | 41.63 ns (41.75) | 41.54 ns (41.86) |

- **Same output:** all three variants print the same output digests (GET
  `ac0261a8a9d4f821`, health check `230fab4af7318bff`), so their replies are
  byte-identical.
- **Raw data:** [`lines.out`](lines.out) has one full line per variant,
  [`bench.out`](bench.out) the round summary.
- **Method:** the same as
  [`2026-11-17-steps-3-4`](../2026-11-17-steps-3-4/README.md).
