#!/usr/bin/env python3
import argparse
import csv
import json
import math
import re
import statistics
from collections import defaultdict
from pathlib import Path


class EvidenceError(RuntimeError):
    pass


CELLS = ("A0-pre", "C02", "C04", "C08", "C16", "C32", "A0-post")
TIERS = {"A0-pre": 0, "C02": 2, "C04": 4, "C08": 8, "C16": 16, "C32": 32, "A0-post": 0}
METRICS = (
    "juicefs_blockcache_bytes", "juicefs_blockcache_blocks",
    "juicefs_blockcache_hits", "juicefs_blockcache_miss",
    "juicefs_blockcache_hit_bytes", "juicefs_blockcache_miss_bytes",
    "juicefs_blockcache_write_bytes", "juicefs_blockcache_evicts",
    "juicefs_blockcache_drops",
)


def percentile(values, q):
    xs = sorted(values)
    pos = (len(xs) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    return xs[lo] if lo == hi else xs[lo] * (hi - pos) + xs[hi] * (pos - lo)


def aggregate_logs(cell, prefix="randread"):
    logs = sorted((cell / "formal" / "bw").glob(prefix + "_bw.*.log"))
    if len(logs) != 128:
        raise EvidenceError(f"expected 128 formal bw logs, got {len(logs)}")
    ids = []
    sums = defaultdict(lambda: defaultdict(float))
    weights = defaultdict(lambda: defaultdict(float))
    for path in logs:
        match = re.fullmatch(prefix + r"_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"unexpected bw log {path.name}")
        job_id = int(match.group(1))
        ids.append(job_id)
        previous = 0.0
        with path.open(newline="") as handle:
            for row in csv.reader(handle):
                if len(row) < 2:
                    raise EvidenceError(f"truncated bw row in {path}")
                end = float(row[0]) / 1000.0
                value = float(row[1]) / 1024.0
                direction = int(row[2]) if len(row) > 2 else 0
                if direction != 0:
                    continue
                start = previous
                previous = end
                for second in range(math.floor(start), math.ceil(end)):
                    overlap = min(end, second + 1) - max(start, second)
                    if overlap > 0:
                        sums[second][job_id] += value * overlap
                        weights[second][job_id] += overlap
    if sorted(ids) != list(range(1, 129)):
        raise EvidenceError("formal bw log ids incomplete")
    result = {}
    for second, jobs in sums.items():
        if len(jobs) != 128 or any(weights[second][job] <= 0 for job in jobs):
            continue
        result[second] = sum(jobs[job] / weights[second][job] for job in jobs)
    return result


def bandwidth_window(series, start=15, stop=175):
    missing = [x for x in range(start, stop) if x not in series]
    if missing:
        raise EvidenceError(f"bandwidth window missing {len(missing)} seconds")
    values = [series[x] for x in range(start, stop)]
    cuts = [round(i * len(values) / 4) for i in range(5)]
    windows = [statistics.mean(values[cuts[i]:cuts[i + 1]]) for i in range(4)]
    mean = statistics.mean(values)
    return {
        "mean_MiBs": mean,
        "median_MiBs": statistics.median(values),
        "cv_pct": statistics.pstdev(values) / mean * 100 if mean else math.inf,
        "p10_MiBs": percentile(values, 0.10),
        "p90_MiBs": percentile(values, 0.90),
        "windows_MiBs": windows,
        "w4_w1": windows[-1] / windows[0] if windows[0] else math.inf,
    }


def fio_runtime_ms(path):
    data = json.loads(path.read_text())
    jobs = data.get("jobs", [])
    if len(jobs) != 128:
        raise EvidenceError(f"expected 128 fio jobs, got {len(jobs)}")
    runtime = 0
    for job in jobs:
        if int(job.get("error", -1)) != 0:
            raise EvidenceError("fio job error")
        runtime = max(runtime, int(job.get("read", {}).get("runtime", 0)))
    if not 175000 <= runtime <= 320000:
        raise EvidenceError(f"unexpected fio runtime {runtime}")
    return runtime


def parse_metrics(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name_value = re.match(r"^([a-zA-Z_:][a-zA-Z0-9_:]*(?:\{[^}]*\})?)\s+([-+0-9.eE]+)$", line)
        if not name_value:
            continue
        name = name_value.group(1).split("{", 1)[0]
        if name in METRICS:
            result[name] = result.get(name, 0.0) + float(name_value.group(2))
    missing = [name for name in METRICS if name not in result]
    if missing:
        raise EvidenceError(f"metrics missing: {','.join(missing)}")
    return result


def metric_delta(before, after, name):
    return after[name] - before[name]


def cache_usage(path):
    values = {}
    for part in path.read_text().strip().split("\t"):
        key, value = part.split("=", 1)
        values[key] = int(value)
    return values


def sampler_contract(path):
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if len(rows) < 150:
        raise EvidenceError(f"runtime sampler too short: {len(rows)}")
    fields = ("epoch_ns", "df_used", "df_avail", "rx_bytes", "tx_bytes",
              "cache_bytes", "cache_blocks", "hit_bytes", "miss_bytes", "evicts", "drops")
    for row in rows:
        if any(row.get(key) in (None, "", "NA") for key in fields):
            raise EvidenceError("runtime sampler has missing/NA field")
    times = [int(row["epoch_ns"]) for row in rows]
    if any(b <= a for a, b in zip(times, times[1:])):
        raise EvidenceError("sampler time is nonmonotonic")
    span_seconds = (times[-1] - times[0]) / 1e9
    if span_seconds < 175:
        raise EvidenceError(f"runtime sampler span too short: {span_seconds:.3f}s")
    drops = int(float(rows[-1]["drops"])) - int(float(rows[0]["drops"]))
    return {
        "samples": len(rows),
        "span_seconds": span_seconds,
        "rx_delta": int(rows[-1]["rx_bytes"]) - int(rows[0]["rx_bytes"]),
        "tx_delta": int(rows[-1]["tx_bytes"]) - int(rows[0]["tx_bytes"]),
        "cache_bytes_last": int(float(rows[-1]["cache_bytes"])),
        "cache_bytes_max": max(int(float(row["cache_bytes"])) for row in rows),
        "hit_bytes_delta": int(float(rows[-1]["hit_bytes"])) - int(float(rows[0]["hit_bytes"])),
        "miss_bytes_delta": int(float(rows[-1]["miss_bytes"])) - int(float(rows[0]["miss_bytes"])),
        "evicts_delta": int(float(rows[-1]["evicts"])) - int(float(rows[0]["evicts"])),
        "drops_delta": drops,
    }


def analyze_cell(cell):
    name = cell.name
    tier = TIERS[name]
    formal = cell / "formal"
    runtime_ms = fio_runtime_ms(formal / "fio.json")
    stop = max(175, round(runtime_ms / 1000) - 5)
    series = aggregate_logs(cell)
    row = {"cell": name, "cache_GiB": tier, "runtime_ms": runtime_ms}
    row["randread"] = bandwidth_window(series, 15, stop)
    row["runtime"] = sampler_contract(cell / "runtime.tsv")
    mounted = parse_metrics(cell / "metrics-mounted.txt")
    formal_metrics = parse_metrics(cell / "metrics-formal.txt")
    warm = parse_metrics(cell / "metrics-warmed.txt") if tier else mounted
    row["metrics"] = {
        "mounted": mounted,
        "warmed": warm,
        "formal": formal_metrics,
        "formal_hit_bytes_delta": metric_delta(warm, formal_metrics, "juicefs_blockcache_hit_bytes"),
        "formal_miss_bytes_delta": metric_delta(warm, formal_metrics, "juicefs_blockcache_miss_bytes"),
        "formal_evicts_delta": metric_delta(warm, formal_metrics, "juicefs_blockcache_evicts"),
        "formal_drops_delta": metric_delta(warm, formal_metrics, "juicefs_blockcache_drops"),
    }
    mounted_usage = cache_usage(cell / "cache-usage-mounted.tsv")
    row["cache_usage"] = {
        "mounted": mounted_usage,
        "warmed": cache_usage(cell / "cache-usage-warmed.tsv") if tier else mounted_usage,
        "formal": cache_usage(cell / "cache-usage-formal.tsv"),
    }
    limit = tier * 1024 ** 3
    logical_limit = min(limit, 16 * 1024 ** 3)
    # The gauge accounts for one 4 KiB cache-file overhead per 256 KiB block.
    # A fully resident 16 GiB workset therefore reports about 16.25 GiB.
    object_overhead = (logical_limit // (256 * 1024)) * 4096 if logical_limit else 0
    gauge_upper = logical_limit + object_overhead + 256 * 1024
    logical_bytes = row["metrics"]["formal"]["juicefs_blockcache_bytes"]
    row["occupancy_ratio"] = logical_bytes / logical_limit if logical_limit else 0
    row["occupancy_near_target"] = (
        logical_bytes >= int(logical_limit * 0.80) and logical_bytes <= gauge_upper
        if tier else logical_bytes == 0
    )
    row["cache_contract"] = (
        logical_bytes >= 0
        and logical_bytes <= max(limit + 256 * 1024, gauge_upper)
        and row["occupancy_near_target"]
        and row["metrics"]["formal_drops_delta"] == 0
        and row["runtime"]["drops_delta"] == 0
    )
    row["steady_state"] = (
        row["randread"]["w4_w1"] >= 0.90
        and row["randread"]["w4_w1"] <= 1.10
        and row["cache_contract"]
    )
    row["point_status"] = "VALID_STEADY" if row["steady_state"] else "INVALID_CONTRACT"
    return row


def analyze(root):
    rows = [analyze_cell(root / "cells" / name) for name in CELLS]
    return {
        "run_id": root.name.removeprefix("opencode-04tmp2c-"),
        "cells": rows,
        "valid_cells": sum(row["point_status"] == "VALID_STEADY" for row in rows),
        "total_cells": len(rows),
        "verdict": "CACHE_RESIDENCY_CURVE_VALID" if all(row["steady_state"] for row in rows) else "CACHE_RESIDENCY_CURVE_INVALID",
        "schema": 1,
    }


def self_test(root):
    root.mkdir(parents=True, exist_ok=True)
    series = {second: 100.0 for second in range(300)}
    stats = bandwidth_window(series)
    if stats["mean_MiBs"] != 100.0 or stats["w4_w1"] != 1.0:
        raise EvidenceError("bandwidth fixture mismatch")
    metrics = "\n".join(f"{name} {index}" for index, name in enumerate(METRICS, 1)) + "\n"
    (root / "metrics.txt").write_text(metrics)
    if len(parse_metrics(root / "metrics.txt")) != len(METRICS):
        raise EvidenceError("metrics fixture mismatch")
    sampler = root / "runtime.tsv"
    fields = "epoch_ns\tdf_used\tdf_avail\trx_bytes\ttx_bytes\tcache_bytes\tcache_blocks\thit_bytes\tmiss_bytes\tevicts\tdrops\n"
    with sampler.open("w") as handle:
        handle.write(fields)
        for second in range(180):
            # runtime.tsv stores epoch nanoseconds; keep the fixture's 180 rows
            # both monotonic and representative of a 180-second sample span.
            handle.write(f"{(second + 1) * 1_000_000_000}\t1\t2\t{second}\t{second}\t100\t1\t{second}\t0\t0\t0\n")
    if sampler_contract(sampler)["drops_delta"] != 0:
        raise EvidenceError("sampler fixture mismatch")
    return {"status": "PASS", "cells": list(CELLS), "workset_bytes": 16 * 1024 ** 3}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("analyze")
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("self-test")
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.root) if args.command == "analyze" else self_test(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(result.get("verdict", result.get("status")))


if __name__ == "__main__":
    main()
