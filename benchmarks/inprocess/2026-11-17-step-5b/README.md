# In-process request path: milestone B step 5b (server lifecycle, Greeter)

**Question:** step 5b moved KvServer's process lifecycle into the engine
(`ga_server_run`). It also turned the health check's field-1 decoder into the
public `ga_pb_field_bytes`, which takes a field number in `rbx`. Does any of
it reach the request path?

**Answer:** no.
- `ga_server_run` runs before and after serving.
- The decoder change is two instructions on the health path (a `push`/`pop`
  of `rbx`), within noise.

## Results

Minimum and median over 12 interleaved rounds, pinned to vCPU 31 of 32.
[`../bench_ga.sh`](../bench_ga.sh) ran `bench_ga.sh 12 step5a step5b`:
- `step5a` was a worktree of 9364336;
- `step5b` was the tree of the commit that added this folder.

| Workload | KvAsm 0.3.0 | Step 5a | Step 5b |
|---|---|---|---|
| GET of a 16-byte key, 100-byte value (1,024 keys) | 70.42 ns (median 70.69) | 68.99 ns (69.81) | 69.58 ns (69.74) |
| `grpc.health.v1.Health/Check` | 44.15 ns (45.34) | 41.58 ns (42.86) | 41.72 ns (42.57) |

- **Same output:** all three variants print the same output digests (GET
  `ac0261a8a9d4f821`, health check `230fab4af7318bff`).
- **Raw data:** [`lines.out`](lines.out) has one full line per variant,
  [`bench.out`](bench.out) the round summary.
- **Method:** the same as
  [`2026-11-17-steps-3-4`](../2026-11-17-steps-3-4/README.md).
