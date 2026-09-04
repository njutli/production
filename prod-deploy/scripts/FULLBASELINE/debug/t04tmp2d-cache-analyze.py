#!/usr/bin/env python3
"""Offline analyzer for the 04-tmp2d production-aligned read-cache curve."""

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


POINTS = ("A0-pre", "C25", "C50", "C75", "C100", "C200", "A0-post")
ITEMS = ("mseqread", "randread")
CELLS = tuple(f"{item}-{point}" for item in ITEMS for point in POINTS)
JOBS = {"mseqread": 16, "randread": 128}
WORKSET_GIB = {"mseqread": 64, "randread": 128}
FRACTION = {"A0-pre": 0, "C25": .25, "C50": .50, "C75": .75,
            "C100": 1.0, "C200": 2.0, "A0-post": 0}
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


def aggregate_logs(cell, item):
    expected = JOBS[item]
    logs = sorted((cell / "formal" / "bw").glob(f"{item}_bw.*.log"))
    if len(logs) != expected:
        raise EvidenceError(f"{cell.name}: expected {expected} bw logs, got {len(logs)}")
    ids = []
    sums = defaultdict(lambda: defaultdict(float))
    weights = defaultdict(lambda: defaultdict(float))
    for path in logs:
        match = re.fullmatch(rf"{item}_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"unexpected bw log {path.name}")
        job_id = int(match.group(1)); ids.append(job_id)
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
                start, previous = previous, end
                for second in range(math.floor(start), math.ceil(end)):
                    overlap = min(end, second + 1) - max(start, second)
                    if overlap > 0:
                        sums[second][job_id] += value * overlap
                        weights[second][job_id] += overlap
    if sorted(ids) != list(range(1, expected + 1)):
        raise EvidenceError(f"{cell.name}: per-job log ids incomplete")
    result = {}
    for second, jobs in sums.items():
        if len(jobs) == expected and all(weights[second][job] > 0 for job in jobs):
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
        "mean_MiBs": mean, "median_MiBs": statistics.median(values),
        "cv_pct": statistics.pstdev(values) / mean * 100 if mean else math.inf,
        "p10_MiBs": percentile(values, .10), "p90_MiBs": percentile(values, .90),
        "windows_MiBs": windows,
        "w4_w1": windows[-1] / windows[0] if windows[0] else math.inf,
    }


def fio_runtime_ms(path, expected):
    jobs = json.loads(path.read_text()).get("jobs", [])
    if len(jobs) != expected or any(int(job.get("error", -1)) != 0 for job in jobs):
        raise EvidenceError(f"{path}: fio job contract failed")
    runtime = max(int(job.get("read", {}).get("runtime", 0)) for job in jobs)
    if not 175000 <= runtime <= 320000:
        raise EvidenceError(f"unexpected fio runtime {runtime}")
    return runtime


def parse_metrics(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^([a-zA-Z_:][a-zA-Z0-9_:]*(?:\{[^}]*\})?)\s+([-+0-9.eE]+)$", line)
        if match:
            name = match.group(1).split("{", 1)[0]
            if name in METRICS:
                result[name] = result.get(name, 0.0) + float(match.group(2))
    missing = [name for name in METRICS if name not in result]
    if missing:
        raise EvidenceError(f"metrics missing: {','.join(missing)}")
    return result


def cache_usage(path):
    return {k: int(v) for k, v in (part.split("=", 1) for part in path.read_text().strip().split("\t"))}


def sampler_contract(path):
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if len(rows) < 150:
        raise EvidenceError(f"runtime sampler too short: {len(rows)}")
    fields = ("epoch_ns", "rx_bytes", "tx_bytes", "cache_bytes", "cache_blocks",
              "hit_bytes", "miss_bytes", "evicts", "drops")
    if any(any(row.get(key) in (None, "", "NA") for key in fields) for row in rows):
        raise EvidenceError("runtime sampler has missing field")
    times = [int(row["epoch_ns"]) for row in rows]
    if any(b <= a for a, b in zip(times, times[1:])) or (times[-1] - times[0]) / 1e9 < 175:
        raise EvidenceError("runtime sampler time contract failed")
    def delta(name):
        return int(float(rows[-1][name])) - int(float(rows[0][name]))
    return {
        "samples": len(rows), "span_seconds": (times[-1] - times[0]) / 1e9,
        "rx_delta": delta("rx_bytes"), "tx_delta": delta("tx_bytes"),
        "hit_bytes_delta": delta("hit_bytes"), "miss_bytes_delta": delta("miss_bytes"),
        "evicts_delta": delta("evicts"), "drops_delta": delta("drops"),
        "cache_bytes_last": int(float(rows[-1]["cache_bytes"])),
        "cache_bytes_max": max(int(float(row["cache_bytes"])) for row in rows),
    }


def analyze_cell(root, name):
    item, point = name.split("-", 1)
    cell = root / "cells" / name
    if not (cell / "PASS").is_file():
        raise EvidenceError(f"{name}: PASS missing")
    runtime_ms = fio_runtime_ms(cell / "formal" / "fio.json", JOBS[item])
    bw = bandwidth_window(aggregate_logs(cell, item), 15, min(175, round(runtime_ms / 1000) - 5))
    mounted = parse_metrics(cell / "metrics-mounted.txt")
    warmed = parse_metrics(cell / "metrics-warmed.txt") if point.startswith("C") else mounted
    formal = parse_metrics(cell / "metrics-formal.txt")
    delta = lambda key: formal[key] - warmed[key]
    hit, miss = delta("juicefs_blockcache_hit_bytes"), delta("juicefs_blockcache_miss_bytes")
    runtime = sampler_contract(cell / "runtime.tsv")
    return {
        "cell": name, "item": item, "point": point,
        "cache_GiB": WORKSET_GIB[item] * FRACTION[point],
        "cache_fraction": FRACTION[point], "runtime_ms": runtime_ms, "bandwidth": bw,
        "hit_ratio": hit / (hit + miss) if hit + miss > 0 else 0,
        "cache_gauge_GiB": formal["juicefs_blockcache_bytes"] / 1024 ** 3,
        "formal_hit_bytes": hit, "formal_miss_bytes": miss,
        "formal_evicts": delta("juicefs_blockcache_evicts"),
        "formal_drops": delta("juicefs_blockcache_drops"),
        "cache_usage": cache_usage(cell / "cache-usage-formal.tsv"),
        "runtime": runtime,
        "performance_steady_observation": .90 <= bw["w4_w1"] <= 1.10,
        "evidence_status": "VALID",
    }


def analyze(root):
    rows = [analyze_cell(root, name) for name in CELLS]
    effects = {}
    for item in ITEMS:
        selected = {row["point"]: row for row in rows if row["item"] == item}
        a0 = statistics.mean(selected[p]["bandwidth"]["mean_MiBs"] for p in ("A0-pre", "A0-post"))
        effects[item] = {
            "a0_mean_MiBs": a0,
            "a0_drift_pct": (selected["A0-post"]["bandwidth"]["mean_MiBs"] /
                             selected["A0-pre"]["bandwidth"]["mean_MiBs"] - 1) * 100,
            "gain_pct": {p: (selected[p]["bandwidth"]["mean_MiBs"] / a0 - 1) * 100
                         for p in POINTS if p.startswith("C")},
        }
    return {"run_id": root.name.removeprefix("opencode-04tmp2d-"), "cells": rows,
            "effects": effects, "valid_cells": len(rows), "total_cells": len(CELLS),
            "verdict": "READ_CACHE_CURVE_COMPLETE", "schema": 1}


def self_test(root):
    root.mkdir(parents=True, exist_ok=True)
    stats = bandwidth_window({second: 100.0 for second in range(180)})
    if stats["mean_MiBs"] != 100.0 or stats["w4_w1"] != 1.0:
        raise EvidenceError("bandwidth fixture mismatch")
    metrics = "\n".join(f"{name} {index}" for index, name in enumerate(METRICS, 1)) + "\n"
    (root / "metrics.txt").write_text(metrics)
    if len(parse_metrics(root / "metrics.txt")) != len(METRICS):
        raise EvidenceError("metrics fixture mismatch")
    return {"status": "PASS", "cells": list(CELLS)}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("analyze", "self-test"):
        child = sub.add_parser(command)
        child.add_argument("--root", type=Path, required=True)
        child.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.root) if args.command == "analyze" else self_test(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(result.get("verdict", result.get("status")))


if __name__ == "__main__":
    main()
