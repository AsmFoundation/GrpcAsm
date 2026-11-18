# 2026-11-18 — KvServer on the NASM API (milestone C3), in process

KvServer before milestone C3 (`ede4ecb`) and after it, timed in process by KvAsm's `bench_h2`
harness ([`../bench_ga.sh`](../bench_ga.sh): `bench_ga.sh 12 before after`), against KvAsm
0.3.0 itself.

**What changed in KvServer:**

- **Routes and hooks:** the hand-written route table (`routes.asm`) and health check gave way
  to a `GA_SERVICE` declaration (`include/grpcasm.inc`), from which `GA_APP_END` generates
  the table, the dispatch and the health check.
- **Unary methods:** the one `ga_app_unary` that served Get, Put, Delete and Download (and
  tested the route twice per call) became three entries, `kv_get` (Get, Delete), `kv_put` and
  `kv_download`. The generated compare chain jumps to them, Get first.
- **Upload's handlers** became `ga_app_stream_data` / `ga_app_stream_end` by alias.

## Result

`bench.out` (minimum and median over 12 interleaved rounds, one vCPU), `lines.out` (a full
line per variant):

| workload | KvAsm 0.3.0 | before C3 | after C3 |
|---|---|---|---|
| GET, ns/request (min / median) | 66.93 / 67.46 | 67.15 / 67.68 | 66.82 / 67.29 |
| health check, ns/request (min / median) | 42.00 / 42.21 | 39.56 / 39.79 | 39.53 / 39.87 |

- **The same answers:** every variant prints the same output digests (GET `ac0261a8a9d4f821`,
  ping `230fab4af7318bff`) and the server counted every request.
- **The same speed:** the GET median is 0.6% lower after C3 and the health check's 0.2% higher,
  both inside the rounds' spread (11–12 of 12 rounds within 2% of the minimum). The port costs
  nothing. The route tests the old entry made are gone from the Get path, but the generated
  compare that replaces them costs about as much.

Harness change in this commit: `bench_ga.sh` leaves the engine's `routes_default.o` out of the
objects it links. It is milestone D's fallback route table, meant for the archive, and as a
plain object it clashes with KvServer's table, in either tree.
