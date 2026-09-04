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


def percentile(values, q):
    xs = sorted(values)
    pos = (len(xs) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    return xs[lo] if lo == hi else xs[lo] * (hi - pos) + xs[hi] * (pos - lo)


def aggregate_logs(cell: Path, item: str, direction: int):
    logs = sorted((cell / "bw").glob(f"{item}_bw.*.log"))
    if not logs:
        raise EvidenceError(f"no bw logs for {item}")
    expected = 16 if item == "mseqread" else 128
    if len(logs) != expected:
        raise EvidenceError(f"{item} expected {expected} logs, got {len(logs)}")
    ids = []
    for path in logs:
        match = re.fullmatch(rf"{re.escape(item)}_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"unexpected bw log name: {path.name}")
        ids.append(int(match.group(1)))
    if sorted(ids) != list(range(1, expected + 1)):
        raise EvidenceError(f"bw log ids incomplete: {sorted(ids)[:8]}..{sorted(ids)[-8:]}")
    sums = defaultdict(lambda: defaultdict(float))
    weights = defaultdict(lambda: defaultdict(float))
    for job, path in enumerate(logs):
        previous = {0: 0.0, 1: 0.0, 2: 0.0}
        with path.open(newline="") as handle:
            for row in csv.reader(handle):
                if len(row) < 3:
                    raise EvidenceError(f"truncated row in {path}")
                end = float(row[0]) / 1000.0
                value = float(row[1]) / 1024.0
                row_dir = int(row[2])
                if row_dir not in previous:
                    raise EvidenceError(f"invalid direction {row_dir} in {path}")
                start, previous[row_dir] = previous[row_dir], end
                if row_dir != direction:
                    continue
                for second in range(math.floor(start), math.ceil(end)):
                    overlap = min(end, second + 1) - max(start, second)
                    if overlap > 0:
                        sums[second][job] += value * overlap
                        weights[second][job] += overlap
    series = {}
    for second in sums:
        if len(sums[second]) == expected:
            series[second] = sum(sums[second][j] / weights[second][j] for j in range(expected))
    return series


def window(series, start=15, stop=175):
    missing = [x for x in range(start, stop) if x not in series]
    if missing:
        raise EvidenceError(f"window missing {len(missing)} seconds")
    values = [series[x] for x in range(start, stop)]
    mean = statistics.mean(values)
    cuts = [round(i * len(values) / 4) for i in range(5)]
    windows = [statistics.mean(values[cuts[i]:cuts[i + 1]]) for i in range(4)]
    return {
        "mean_MiBs": mean,
        "median_MiBs": statistics.median(values),
        "cv_pct": statistics.pstdev(values) / mean * 100,
        "p10_MiBs": percentile(values, 0.1),
        "p90_MiBs": percentile(values, 0.9),
        "windows_MiBs": windows,
        "w4_w1": windows[-1] / windows[0],
    }


def fio_totals(path: Path):
    data = json.loads(path.read_text())
    read = write = runtime = 0
    for job in data.get("jobs", []):
        if int(job.get("error", -1)) != 0:
            raise EvidenceError("fio job error")
        read += int(job.get("read", {}).get("io_bytes", 0))
        write += int(job.get("write", {}).get("io_bytes", 0))
        direction_runtime = max(int(job.get("read", {}).get("runtime", 0)),
                                int(job.get("write", {}).get("runtime", 0)))
        # With group_reporting, fio's job_runtime is accumulated across workers
        # (for example 16 * 180 s), while direction runtime remains wall time.
        runtime = max(runtime, direction_runtime or int(job.get("job_runtime", 0)))
    if not 175000 <= runtime <= 320000:
        raise EvidenceError(f"unexpected runtime {runtime}")
    return read, write, runtime


def sampler_contract(path: Path, tier_gib: int):
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if len(rows) < 170:
        raise EvidenceError(f"runtime sampler too short: {len(rows)}")
    fields = ("epoch_ns", "df_used", "df_avail", "staging_blocks", "staging_files", "staging_bytes", "rx_bytes", "tx_bytes", "base_stat")
    for row in rows:
        if any(row.get(key) in (None, "", "NA") for key in fields):
            raise EvidenceError("runtime sampler has missing/NA field")
    tail = rows[-30:]
    times = [int(x["epoch_ns"]) / 1e9 for x in tail]
    used = [int(x["df_used"]) for x in tail]
    if any(b <= a for a, b in zip(times, times[1:])):
        raise EvidenceError("runtime sampler time is nonmonotonic")
    budget = tier_gib * 1024 ** 3
    delta_ratio = abs(used[-1] - used[0]) / budget
    xm = statistics.mean(times); ym = statistics.mean(used)
    denom = sum((x - xm) ** 2 for x in times)
    slope_per_minute = 60 * sum((x - xm) * (y - ym) for x, y in zip(times, used)) / denom if denom else math.inf
    slope_ratio = abs(slope_per_minute) / budget
    return {"samples": len(rows), "tail_delta_ratio": delta_ratio, "tail_slope_ratio_per_min": slope_ratio,
            "occupancy_steady": delta_ratio <= 0.05 or slope_ratio <= 0.02}


def half_ratio(series, stop):
    values = [series[x] for x in range(60, stop) if x in series]
    if len(values) != stop - 60:
        raise EvidenceError("steady bandwidth interval incomplete")
    middle = len(values) // 2
    first, second = statistics.mean(values[:middle]), statistics.mean(values[middle:])
    return second / first


def drain_contract(cell: Path):
    path = cell / "drain.tsv"
    if not path.is_file():
        raise EvidenceError("write cell drain evidence missing")
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if len(rows) < 2:
        raise EvidenceError("drain evidence too short")
    zeros = rows[-2:]
    if any(float(x["staging_blocks"]) != 0 or int(x["staging_files"]) != 0 or int(x["staging_bytes"]) != 0 for x in zeros):
        raise EvidenceError("staging did not end at two zero samples")
    return True


def analyze_cell(cell: Path):
    item, tier = cell.name.rsplit("-c", 1)
    if not (cell / "PASS").is_file():
        raise EvidenceError(f"cell lacks PASS: {cell.name}")
    read_bytes, write_bytes, runtime_ms = fio_totals(cell / "fio.json")
    stop = round(runtime_ms / 1000) - 5
    row = {"cell": cell.name, "item": item, "tier_GiB": int(tier), "fio_read_bytes": read_bytes,
           "fio_write_bytes": write_bytes, "runtime_ms": runtime_ms}
    row["sampler"] = sampler_contract(cell / "runtime.tsv", int(tier))
    ratios = []
    if item != "randwrite":
        read_series = aggregate_logs(cell, item, 0)
        row["read"] = window(read_series, 15, stop)
        ratios.append(half_ratio(read_series, stop))
    if item in ("randwrite", "randrw"):
        for direction, label in ((1, "write"),):
            series = aggregate_logs(cell, item, direction)
            row[label] = window(series, 15, stop)
            ratios.append(half_ratio(series, stop))
    drain = int((cell / "drain-seconds.txt").read_text().strip())
    row["drain_seconds"] = drain
    if write_bytes:
        drain_contract(cell)
        row["effective_durable_MiBs"] = write_bytes / 1048576.0 / (runtime_ms / 1000.0 + drain)
    row["steady_half_ratios"] = ratios
    row["steady_state"] = row["sampler"]["occupancy_steady"] and all(0.90 <= x <= 1.10 for x in ratios)
    row["point_status"] = "VALID_STEADY" if row["steady_state"] else "NO_STEADY_STATE_WITHIN_BUDGET"
    return row


def analyze(root: Path):
    expected = [f"{item}-c{tier}" for item in ("mseqread", "randread", "randwrite", "randrw") for tier in (16, 64, 32)]
    rows = [analyze_cell(root / "cells" / name) for name in expected]
    steady = sum(x["steady_state"] for x in rows)
    verdict = "CACHE_CAPACITY_CURVE_VALID" if steady == len(rows) else "CACHE_CAPACITY_CURVE_PARTIAL_NO_STEADY_STATE"
    return {"run_id": root.name.removeprefix("opencode-04tmp2b-"), "cells": rows,
            "steady_cells": steady, "total_cells": len(rows), "verdict": verdict, "schema": 1}


def self_test(root: Path):
    values = {x: 100.0 + x for x in range(240)}
    stats = window(values)
    if not 194.0 < stats["mean_MiBs"] < 195.0 or len(stats["windows_MiBs"]) != 4:
        raise EvidenceError("window fixture mismatch")
    long_values = {x: 200.0 for x in range(320)}
    long_stats = window(long_values, 15, 295)
    if long_stats["w4_w1"] != 1.0:
        raise EvidenceError("300 second window fixture mismatch")
    sampler = root / "runtime.tsv"
    root.mkdir(parents=True, exist_ok=True)
    with sampler.open("w") as handle:
        handle.write("epoch_ns\tdf_used\tdf_avail\tstaging_blocks\tstaging_files\tstaging_bytes\trx_bytes\ttx_bytes\tbase_stat\n")
        for second in range(180):
            handle.write(f"{second * 1000000000}\t1073741824\t10737418240\t0\t0\t0\t{second}\t{second}\t1 2 3\n")
    sampler_result = sampler_contract(sampler, 16)
    if not sampler_result["occupancy_steady"]:
        raise EvidenceError("stable sampler fixture rejected")
    drain = root / "drain.tsv"
    drain.write_text("epoch\tstaging_blocks\tstaging_files\tstaging_bytes\n1\t0\t0\t0\n11\t0\t0\t0\n")
    drain_contract(root)
    mixed = root / "randrw-c16" / "bw"
    mixed.mkdir(parents=True)
    for job in range(1, 129):
        with (mixed / f"randrw_bw.{job}.log").open("w") as handle:
            for second in range(1, 181):
                handle.write(f"{second * 1000},1024,0,0\n{second * 1000},2048,1,0\n")
    read_series = aggregate_logs(mixed.parent, "randrw", 0)
    write_series = aggregate_logs(mixed.parent, "randrw", 1)
    if window(read_series)["mean_MiBs"] != 128.0 or window(write_series)["mean_MiBs"] != 256.0:
        raise EvidenceError("mixed-direction bw fixture mismatch")
    return {"status": "PASS", "window": stats, "window_300s": long_stats,
            "sampler": sampler_result, "mixed_direction": "PASS"}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("analyze"); p.add_argument("--root", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("self-test"); p.add_argument("--root", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.root) if args.command == "analyze" else self_test(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(result.get("verdict", result.get("status")))


if __name__ == "__main__":
    main()
