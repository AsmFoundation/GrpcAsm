#!/usr/bin/env python3
"""analyze.py — the paired verdict of run.sh's blocks.

Usage: python analyze.py RESULTS_DIR

Reads RESULTS_DIR/raw.jsonl (one kvbench JSON line per run, labels "<protocol>-b<block>") and
prints, as Markdown:

* one row per block: each client's throughput, client CPU per request, server CPU per request
  and p50/p99 latency, and the block's ratios (grpcasm / grpc);
* the summary: the median ratio, its range over the blocks, how many blocks favor GrpcAsm's
  client, and the two-sided sign-test p-value of that count.

Why ratios per block: run.sh runs both clients back to back in each block, in alternating
order. A host whose speed drifts (other programs on the same PC) moves both runs of a block
together, so the ratio inside a block is what is compared, never two absolute numbers from
different moments.

Every run must be valid (kvbench's own verdict: no errors, no misses, no bad values);
otherwise the script stops, naming the run.
"""

import json
import statistics
import sys
from math import comb
from pathlib import Path


def per_op_ns(result: dict, key: str) -> float:
    """CPU nanoseconds per request of one side.

    Args:
        result: kvbench's "result" object.
        key: "client_cpu_s" or "server_cpu_s".

    Returns:
        Nanoseconds per completed request, or NaN when kvbench could not read that side.
    """
    seconds = result.get(key, -1)
    if seconds is None or seconds < 0 or not result.get("ops"):
        return float("nan")
    return seconds / result["ops"] * 1e9


def sign_test(wins: int, n: int) -> float:
    """Two-sided exact sign test.

    Args:
        wins: blocks where the ratio favors one side.
        n: blocks.

    Returns:
        The probability of a split at least this lopsided if neither side were better.
    """
    k = max(wins, n - wins)
    tail = sum(comb(n, i) for i in range(k, n + 1)) / 2**n
    return min(1.0, 2 * tail)


def main() -> int:
    """Prints the analysis. @returns the exit status (1 for an invalid run)."""
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    runs = {}
    for line in Path(sys.argv[1], "raw.jsonl").read_text().splitlines():
        if not line.strip():
            continue
        run = json.loads(line)
        result = run.get("result", {})
        if not result.get("valid"):
            print(f"invalid run {run.get('label')}: {result.get('error_text')}", file=sys.stderr)
            return 1
        protocol, block = run["label"].rsplit("-b", 1)
        runs[(int(block), protocol)] = result

    blocks = sorted({b for b, _ in runs})
    rows, ratios = [], {"ops": [], "client": [], "server": [], "p50": [], "p99": []}
    for b in blocks:
        g, a = runs.get((b, "grpc")), runs.get((b, "grpcasm"))
        if not g or not a:
            continue
        ops = a["ops_per_sec"] / g["ops_per_sec"]
        client = per_op_ns(a, "client_cpu_s") / per_op_ns(g, "client_cpu_s")
        server = per_op_ns(a, "server_cpu_s") / per_op_ns(g, "server_cpu_s")
        p50 = a["latency_us"]["p50"] / g["latency_us"]["p50"]
        p99 = a["latency_us"]["p99"] / g["latency_us"]["p99"]
        for key, value in zip(ratios, (ops, client, server, p50, p99)):
            ratios[key].append(value)
        rows.append(
            f"| {b} | {g['ops_per_sec'] / 1e6:.2f}M | {a['ops_per_sec'] / 1e6:.2f}M | **{ops:.2f}×** "
            f"| {per_op_ns(g, 'client_cpu_s'):.0f} | {per_op_ns(a, 'client_cpu_s'):.0f} "
            f"| {per_op_ns(g, 'server_cpu_s'):.0f} | {per_op_ns(a, 'server_cpu_s'):.0f} "
            f"| {g['latency_us']['p50']:.0f} / {g['latency_us']['p99']:.0f} "
            f"| {a['latency_us']['p50']:.0f} / {a['latency_us']['p99']:.0f} |"
        )

    print("| block | nghttp2 ops/s | GrpcAsm ops/s | ratio | nghttp2 client ns/req "
          "| GrpcAsm client ns/req | server ns/req (nghttp2) | server ns/req (GrpcAsm) "
          "| nghttp2 p50/p99 µs | GrpcAsm p50/p99 µs |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    print("\n".join(rows))
    print()
    n = len(ratios["ops"])
    labels = {
        "ops": ("throughput (GrpcAsm ÷ nghttp2)", lambda r: r > 1),
        "client": ("client CPU per request (GrpcAsm ÷ nghttp2)", lambda r: r < 1),
        "server": ("server CPU per request (with GrpcAsm ÷ with nghttp2)", lambda r: r < 1),
        "p50": ("p50 latency (GrpcAsm ÷ nghttp2)", lambda r: r < 1),
        "p99": ("p99 latency (GrpcAsm ÷ nghttp2)", lambda r: r < 1),
    }
    for key, (label, better) in labels.items():
        values = ratios[key]
        wins = sum(1 for r in values if better(r))
        print(f"- **{label}:** median {statistics.median(values):.3f}, range "
              f"{min(values):.3f}–{max(values):.3f}; GrpcAsm better in {wins}/{n} blocks "
              f"(sign test p = {sign_test(wins, n):.3f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
