#!/usr/bin/env python3
"""Offline analyzer for the 04-tmp2e randwrite writeback-capacity curve."""

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


CAPACITY_GIB = {
    "W16-randwrite": 16,
    "W32-randwrite": 32,
    "W64-randwrite": 64,
    "W96-randwrite": 96,
    "W128-randwrite": 128,
}
CELLS = tuple(CAPACITY_GIB)
EXPECTED_JOBS = 128


def aggregate_write_logs(cell: Path):
    logs = sorted((cell / "bw").glob("randwrite_bw.*.log"))
    if len(logs) != EXPECTED_JOBS:
        raise EvidenceError(f"{cell.name}: expected 128 bw logs, got {len(logs)}")
    ids = []
    sums = defaultdict(lambda: defaultdict(float))
    weights = defaultdict(lambda: defaultdict(float))
    for path in logs:
        match = re.fullmatch(r"randwrite_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"unexpected log name: {path.name}")
        job = int(match.group(1))
        ids.append(job)
        previous = 0.0
        with path.open(newline="") as handle:
            for row in csv.reader(handle):
                if len(row) < 3:
                    raise EvidenceError(f"truncated row: {path}")
                end = float(row[0]) / 1000.0
                value_mib = float(row[1]) / 1024.0
                direction = int(row[2])
                start, previous = previous, end
                if direction != 1:
                    continue
                for second in range(math.floor(start), math.ceil(end)):
                    overlap = min(end, second + 1) - max(start, second)
                    if overlap > 0:
                        sums[second][job] += value_mib * overlap
                        weights[second][job] += overlap
    if sorted(ids) != list(range(1, EXPECTED_JOBS + 1)):
        raise EvidenceError("per-job bw log ids incomplete")
    result = {}
    for second, jobs in sums.items():
        if len(jobs) == EXPECTED_JOBS and all(weights[second][job] > 0 for job in jobs):
            result[second] = sum(jobs[job] / weights[second][job] for job in jobs)
    return result


def window(series, start=15, stop=175):
    missing = [second for second in range(start, stop) if second not in series]
    if missing:
        raise EvidenceError(f"formal window missing {len(missing)} seconds")
    values = [series[second] for second in range(start, stop)]
    cuts = [round(i * len(values) / 4) for i in range(5)]
    quarters = [statistics.mean(values[cuts[i]:cuts[i + 1]]) for i in range(4)]
    mean = statistics.mean(values)
    return {
        "mean_MiBs": mean,
        "median_MiBs": statistics.median(values),
        "cv_pct": statistics.pstdev(values) / mean * 100 if mean else math.inf,
        "windows_MiBs": quarters,
        "w4_w1": quarters[-1] / quarters[0] if quarters[0] else math.inf,
    }


def fio_contract(path: Path):
    data = json.loads(path.read_text())
    jobs = data.get("jobs", [])
    if len(jobs) != EXPECTED_JOBS:
        raise EvidenceError(f"expected 128 fio jobs, got {len(jobs)}")
    if any(int(job.get("error", -1)) != 0 for job in jobs):
        raise EvidenceError("fio job error")
    runtimes = [int(job.get("write", {}).get("runtime", 0)) for job in jobs]
    if any(not 175000 <= runtime <= 190000 for runtime in runtimes):
        raise EvidenceError(f"unexpected fio runtime range: {min(runtimes)}..{max(runtimes)}")
    runtime_ms = max(runtimes)
    write_bytes = sum(int(job.get("write", {}).get("io_bytes", 0)) for job in jobs)
    if write_bytes <= 0:
        raise EvidenceError("fio reports zero write bytes")
    return runtime_ms, write_bytes


def sampler_contract(path: Path, require_writeback: bool):
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if len(rows) < 170:
        raise EvidenceError(f"runtime sampler too short: {len(rows)}")
    required = ["epoch_ns", "rx_bytes", "tx_bytes", "base_stat"]
    if require_writeback:
        required += ["staging_blocks", "staging_block_bytes", "staging_writing_blocks",
                     "cache_bytes", "hit_bytes", "miss_bytes", "evicts", "drops"]
    if any(any(row.get(key) in (None, "", "NA") for key in required) for row in rows):
        raise EvidenceError("runtime sampler contains missing value")
    times = [int(row["epoch_ns"]) for row in rows]
    if any(right <= left for left, right in zip(times, times[1:])):
        raise EvidenceError("runtime timestamps are not strictly increasing")
    if (times[-1] - times[0]) / 1e9 < 170:
        raise EvidenceError("runtime sampler span is too short")
    result = {"samples": len(rows), "span_seconds": (times[-1] - times[0]) / 1e9}
    if require_writeback:
        result["peak_staging_blocks"] = max(int(row["staging_blocks"]) for row in rows)
        result["peak_staging_bytes"] = max(int(row["staging_block_bytes"]) for row in rows)
    return result


def capacity_contract(cell: Path, name: str):
    lines = [line.split() for line in (cell / "cache-df.tsv").read_text().splitlines() if line.strip()]
    if len(lines) != 2 or len(lines[1]) != 2:
        raise EvidenceError(f"{name}: unexpected cache df evidence")
    filesystem_bytes, available_bytes = map(int, lines[1])
    nominal_bytes = CAPACITY_GIB[name] * 1024**3
    if not 0 < available_bytes <= filesystem_bytes <= nominal_bytes:
        raise EvidenceError(f"{name}: invalid capacity evidence")
    if available_bytes < nominal_bytes * 0.90:
        raise EvidenceError(f"{name}: available capacity unexpectedly low")
    return {
        "nominal_backing_GiB": CAPACITY_GIB[name],
        "filesystem_bytes": filesystem_bytes,
        "available_bytes": available_bytes,
        "available_GiB": available_bytes / 1024**3,
    }


def state_contract(root: Path, cell: Path, name: str):
    values = defaultdict(list)
    with (cell / "state.tsv").open(newline="") as handle:
        for row in csv.reader(handle, delimiter="\t"):
            if len(row) == 2:
                values[row[0]].append(row[1])
    expected_run = root.name.removeprefix("opencode-04tmp2e-")
    expected_backing = f"/mnt/jfs-cache/jfs-04tmp2e-{expected_run}/{name}.img"
    if values.get("run_id") != [expected_run] or values.get("cell") != [name]:
        raise EvidenceError(f"{name}: state RUN/cell identity mismatch")
    if values.get("backing") != [expected_backing]:
        raise EvidenceError(f"{name}: state backing identity mismatch")
    if not values.get("status") or values["status"][-1] != "DESTROYED":
        raise EvidenceError(f"{name}: storage lifecycle not destroyed")


def drain_contract(cell: Path):
    path = cell / "drain.tsv"
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if len(rows) < 2:
        raise EvidenceError("W16 drain evidence too short")
    for row in rows[-2:]:
        if (float(row["staging_blocks"]) != 0 or float(row["staging_block_bytes"]) != 0
                or float(row["staging_writing_blocks"]) != 0
                or int(row["staging_files"]) != 0
                or int(row["staging_file_bytes"]) != 0):
            raise EvidenceError("W16 did not end with two zero staging samples")
    seconds = int((cell / "drain-seconds.txt").read_text().strip())
    if not 0 <= seconds <= 900:
        raise EvidenceError(f"invalid drain seconds: {seconds}")
    return seconds


def metric_value(path: Path, name: str):
    pattern = re.compile(rf"^{re.escape(name)}(?:\{{[^}}]*\}})?\s+([-+0-9.eE]+)$")
    values = []
    for line in path.read_text().splitlines():
        match = pattern.match(line)
        if match:
            values.append(float(match.group(1)))
    if not values:
        raise EvidenceError(f"metric missing: {name} in {path}")
    return sum(values)


def require_empty_file(path: Path):
    if not path.is_file() or path.stat().st_size != 0:
        raise EvidenceError(f"upload-error evidence is absent or nonempty: {path}")


def recovery_contract(root: Path, label: str):
    recovery = root / "recovery" / label
    if not (recovery / "PASS").is_file():
        raise EvidenceError(f"recovery PASS missing: {label}")
    health = json.loads((recovery / "health-post.json").read_text())
    if health.get("health", {}).get("status") != "HEALTH_OK":
        raise EvidenceError(f"recovery health failed: {label}")
    objects = {}
    with (recovery / "objects.tsv").open(newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            objects[row["key"]] = int(row["value"])
    final_keys = sorted((key for key in objects if key.startswith("pass")), key=lambda x: int(x[4:]))
    if not final_keys or objects[final_keys[-1]] > objects["limit"]:
        raise EvidenceError(f"objects did not return: {label}")
    compact = []
    with (recovery / "compact-state.tsv").open(newline="") as handle:
        for row in csv.reader(handle, delimiter="\t"):
            if len(row) == 5:
                compact.append(row)
    if not compact:
        raise EvidenceError(f"compact evidence missing: {label}")
    last_round = max(int(row[0]) for row in compact)
    last = [row for row in compact if int(row[0]) == last_round]
    if any(row[2] != "0" or row[3] != "0" for row in last):
        raise EvidenceError(f"compact did not close: {label}")
    pending = list(csv.DictReader((recovery / "tikv-pending.tsv").open(), delimiter="\t"))
    by_endpoint = defaultdict(list)
    for row in pending:
        by_endpoint[row.get("endpoint")].append(int(row["pending_compaction_bytes"]))
    expected = {"10.20.1.150:20180", "10.20.1.151:20180", "10.20.1.152:20180"}
    if set(by_endpoint) != expected or any(len(values) < 3 or any(values[-3:]) for values in by_endpoint.values()):
        raise EvidenceError(f"TiKV pending compaction did not close: {label}")
    return {"final_objects": objects[final_keys[-1]], "limit": objects["limit"],
            "compact_last_round": last_round, "osds": len(last), "tikv_endpoints": len(by_endpoint)}


def analyze_cell(root: Path, name: str):
    cell = root / "cells" / name
    if not (cell / "PASS").is_file():
        raise EvidenceError(f"{name}: PASS missing")
    state_contract(root, cell, name)
    runtime_ms, write_bytes = fio_contract(cell / "fio.json")
    if (cell / "sampler.rc").read_text().strip() != "0":
        raise EvidenceError(f"{name}: sampler rc is not zero")
    for health_name in ("health-pre", "health-post", "health-final"):
        health = json.loads((cell / health_name / "ceph-status.json").read_text())
        if health.get("health", {}).get("status") != "HEALTH_OK":
            raise EvidenceError(f"{name}: {health_name} is not HEALTH_OK")
    require_empty_file(cell / "upload-errors-formal.txt")
    result = {
        "cell": name,
        "runtime_ms": runtime_ms,
        "fio_write_bytes": write_bytes,
        "bandwidth": window(aggregate_write_logs(cell)),
        "sampler": sampler_contract(cell / "runtime.tsv", name.startswith("W")),
        "capacity": capacity_contract(cell, name),
    }
    drain_seconds = drain_contract(cell)
    if name.startswith("W"):
        require_empty_file(cell / "upload-errors-recovery.txt")
        sample_rows = list(csv.DictReader((cell / "recovery-read-sample.tsv").open(), delimiter="\t"))
        if len(sample_rows) != 3 or any(row.get("read_status") != "PASS" for row in sample_rows):
            raise EvidenceError("W16 recovery read sample failed")
        metrics = cell / "metrics-mounted-recovery.txt"
        for metric in ("juicefs_staging_blocks", "juicefs_staging_block_bytes", "juicefs_staging_writing_blocks"):
            if metric_value(metrics, metric) != 0:
                raise EvidenceError(f"W16 recovery metric not zero: {metric}")
    result["drain_seconds"] = drain_seconds
    result["effective_durable_MiBs"] = (
        write_bytes / 1048576.0 / (runtime_ms / 1000.0 + drain_seconds)
    )
    return result


def analyze(root: Path):
    cells = [analyze_cell(root, name) for name in CELLS]
    recovery = {
        f"after-{name}": recovery_contract(root, f"after-{name}")
        for name in CELLS
    }
    return {
        "run_id": root.name.removeprefix("opencode-04tmp2e-"),
        "cells": cells,
        "recovery": recovery,
        "verdict": "RANDWRITE_WRITEBACK_CAPACITY_CURVE_PASS",
        "schema": 2,
    }


def self_test(root: Path):
    root.mkdir(parents=True, exist_ok=True)
    stable = {second: 1280.0 for second in range(180)}
    stats = window(stable)
    if stats["mean_MiBs"] != 1280.0 or stats["w4_w1"] != 1.0:
        raise EvidenceError("window fixture failed")
    sample = root / "runtime.tsv"
    with sample.open("w") as handle:
        handle.write(
            "epoch_ns\tstaging_blocks\tstaging_block_bytes\tstaging_writing_blocks\t"
            "cache_bytes\thit_bytes\tmiss_bytes\tevicts\tdrops\trx_bytes\ttx_bytes\tbase_stat\n"
        )
        for second in range(180):
            handle.write(
                f"{second * 1000000000}\t0\t0\t0\t0\t0\t0\t0\t0\t"
                f"{second}\t{second}\t1 2 3\n"
            )
    sampler_contract(sample, True)
    drain = root / "drain.tsv"
    drain.write_text("epoch\tstaging_blocks\tstaging_block_bytes\tstaging_writing_blocks\tstaging_files\tstaging_file_bytes\n1\t0\t0\t0\t0\t0\n11\t0\t0\t0\t0\t0\n")
    (root / "drain-seconds.txt").write_text("10\n")
    if drain_contract(root) != 10:
        raise EvidenceError("drain fixture failed")
    return {"status": "PASS", "window": stats}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    analyze_parser = sub.add_parser("analyze")
    analyze_parser.add_argument("--root", required=True, type=Path)
    analyze_parser.add_argument("--output", required=True, type=Path)
    test_parser = sub.add_parser("self-test")
    test_parser.add_argument("--root", required=True, type=Path)
    test_parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = analyze(args.root) if args.command == "analyze" else self_test(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(result.get("verdict", result.get("status")))


if __name__ == "__main__":
    main()
