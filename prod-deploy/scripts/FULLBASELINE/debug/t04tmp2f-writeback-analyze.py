#!/usr/bin/env python3
"""Offline evidence analyzer for 04-tmp2f writeback capacity points."""

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


CAPACITY_GIB = {f"W{x}-randwrite": x for x in (20, 32, 64, 96, 128)}
CORE = ("W20-randwrite", "W32-randwrite", "W64-randwrite", "W128-randwrite")
EXPECTED_JOBS = 128


def tsv_rows(path):
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def tsv_map(path):
    result = {}
    with path.open(newline="") as handle:
        for row in csv.reader(handle, delimiter="\t"):
            if len(row) == 2 and row[0] not in ("metric", "key"):
                result[row[0]] = row[1]
    return result


def aggregate_logs(cell):
    logs = list((cell / "bw").glob("randwrite_bw.*.log"))
    if len(logs) != EXPECTED_JOBS:
        raise EvidenceError(f"{cell.name}: expected 128 bw logs, got {len(logs)}")
    sums = defaultdict(lambda: defaultdict(float))
    weights = defaultdict(lambda: defaultdict(float))
    ids = set()
    for path in logs:
        match = re.fullmatch(r"randwrite_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"unexpected bw log {path}")
        job = int(match.group(1)); ids.add(job); previous = 0.0
        with path.open(newline="") as handle:
            for row in csv.reader(handle):
                if len(row) < 3:
                    raise EvidenceError(f"truncated bw row {path}")
                end = float(row[0]) / 1000.0; value = float(row[1]) / 1024.0
                start, previous = previous, end
                if int(row[2]) != 1:
                    continue
                for second in range(math.floor(start), math.ceil(end)):
                    overlap = min(end, second + 1) - max(start, second)
                    if overlap > 0:
                        sums[second][job] += value * overlap
                        weights[second][job] += overlap
    if ids != set(range(1, EXPECTED_JOBS + 1)):
        raise EvidenceError("per-job bw log ids incomplete")
    return {second: sum(values[j] / weights[second][j] for j in values)
            for second, values in sums.items() if len(values) == EXPECTED_JOBS}


def bandwidth(series, start=15, stop=175):
    missing = [x for x in range(start, stop) if x not in series]
    if missing:
        raise EvidenceError(f"formal window missing {len(missing)} seconds")
    values = [series[x] for x in range(start, stop)]
    cuts = [round(i * len(values) / 4) for i in range(5)]
    windows = [statistics.mean(values[cuts[i]:cuts[i + 1]]) for i in range(4)]
    mean = statistics.mean(values)
    return {"mean_MiBs": mean, "median_MiBs": statistics.median(values),
            "cv_pct": statistics.pstdev(values) / mean * 100,
            "windows_MiBs": windows, "w4_w1": windows[-1] / windows[0]}


def fio_contract(path):
    data = json.loads(path.read_text()); jobs = data.get("jobs", [])
    if len(jobs) != EXPECTED_JOBS or any(int(x.get("error", -1)) for x in jobs):
        raise EvidenceError("fio job contract failed")
    runtimes = [int(x.get("write", {}).get("runtime", 0)) for x in jobs]
    if any(not 175000 <= x <= 190000 for x in runtimes):
        raise EvidenceError(f"fio runtime contract failed: {min(runtimes)}..{max(runtimes)}")
    written = sum(int(x.get("write", {}).get("io_bytes", 0)) for x in jobs)
    if written <= 0:
        raise EvidenceError("fio wrote zero bytes")
    return max(runtimes), written


def numeric_rows(path):
    rows = tsv_rows(path)
    if not rows:
        raise EvidenceError(f"empty sampler {path}")
    required = ("epoch_ns", "staging_blocks", "staging_block_bytes", "staging_writing_blocks",
                "available_bytes")
    if any(any(row.get(k) in (None, "", "NA") for k in required) for row in rows):
        raise EvidenceError(f"missing sampler field in {path}")
    numeric = []
    try:
        for row in rows:
            numeric.append({key: int(float(row[key])) for key in required})
    except (ValueError, TypeError) as exc:
        raise EvidenceError(f"nonnumeric sampler field in {path}: {exc}") from exc
    times = [row["epoch_ns"] for row in numeric]
    if any(right <= left for left, right in zip(times, times[1:])):
        raise EvidenceError(f"non-monotonic sampler time in {path}")
    return rows


def milestone_seconds(rows, fio_end_ns, start_bytes, ratio):
    if start_bytes == 0:
        return 0.0
    threshold = start_bytes * ratio
    for row in rows:
        if float(row["staging_block_bytes"]) <= threshold:
            return max(0.0, (int(row["epoch_ns"]) - fio_end_ns) / 1e9)
    return None


def health_contract(path):
    data = json.loads(path.read_text()); health = data.get("health", {})
    status = health.get("status"); keys = set(health.get("checks", {}))
    if not (status == "HEALTH_OK" and not keys or status == "HEALTH_WARN" and keys == {"OSDMAP_FLAGS"}):
        raise EvidenceError(f"unexpected Ceph health in {path}: {status} {sorted(keys)}")
    states = data.get("pgmap", {}).get("pgs_by_state", [])
    if not states or any(x.get("state_name") != "active+clean" for x in states):
        raise EvidenceError(f"non-clean PG state in {path}")


def recovery_contract(root, name):
    path = root / "recovery" / f"after-{name}"
    if not (path / "PASS").is_file() or not (path / "health-post-scrub-lease.txt").is_file():
        raise EvidenceError(f"{name}: post-cell recovery marker/lease missing")
    health_contract(path / "health-post.json")
    objects = {row["key"]: int(row["value"]) for row in tsv_rows(path / "objects.tsv")}
    passes = sorted((key for key in objects if key.startswith("pass")), key=lambda x: int(x[4:]))
    if not passes or objects[passes[-1]] > objects.get("limit", -1):
        raise EvidenceError(f"{name}: object count did not return")
    compact = [row for row in csv.reader((path / "compact-state.tsv").open(), delimiter="\t") if len(row) == 5]
    if not compact:
        raise EvidenceError(f"{name}: compact cooldown evidence missing")
    final_round = max(int(row[0]) for row in compact)
    if any(row[2] != "0" or row[3] != "0" for row in compact if int(row[0]) == final_round):
        raise EvidenceError(f"{name}: OSD compact did not cool down")
    pending = tsv_rows(path / "tikv-pending.tsv"); by_endpoint = defaultdict(list)
    for row in pending:
        by_endpoint[row["endpoint"]].append(int(row["pending_compaction_bytes"]))
    expected = {"10.20.1.150:20180", "10.20.1.151:20180", "10.20.1.152:20180"}
    if set(by_endpoint) != expected or any(len(v) < 3 or any(v[-3:]) for v in by_endpoint.values()):
        raise EvidenceError(f"{name}: TiKV compaction debt did not close")
    return {"final_objects": objects[passes[-1]], "object_limit": objects["limit"],
            "compact_final_round": final_round}


def analyze_cell(root, name):
    cell = root / "cells" / name
    if not (cell / "PASS").is_file():
        raise EvidenceError(f"{name}: completion marker missing")
    verdict_data = tsv_map(cell / "verdict.tsv")
    verdict = verdict_data.get("verdict")
    if verdict not in {"LIFECYCLE_FAIL", "LIFECYCLE_PASS_TIGHT", "OBSERVED_SAFE_POINT"}:
        raise EvidenceError(f"{name}: invalid verdict {verdict}")
    state = tsv_map(cell / "state.tsv")
    if state.get("status") != "DESTROYED":
        raise EvidenceError(f"{name}: storage not destroyed")
    for phase in ("health-pre", "health-post", "health-final"):
        health_contract(cell / phase / "ceph-status.json")
        if not (cell / phase / "scrub-lease.txt").is_file():
            raise EvidenceError(f"{name}: {phase} scrub lease evidence missing")
    runtime_ms, written = fio_contract(cell / "fio.json")
    runtime = numeric_rows(cell / "runtime.tsv"); drain = numeric_rows(cell / "drain.tsv")
    actual = int((cell / "actual-available-bytes.txt").read_text())
    nominal = CAPACITY_GIB[name] * 1024**3
    if not nominal * .90 <= actual <= nominal:
        raise EvidenceError(f"{name}: implausible actual available {actual}")
    all_rows = runtime + drain
    peak = max(int(x["staging_block_bytes"]) for x in all_rows)
    minimum_free = min(int(x["available_bytes"]) for x in all_rows)
    end_bytes = int(drain[0]["staging_block_bytes"])
    fio_end_ns = int((cell / "fio-end-epoch-ns.txt").read_text())
    drain_status = (cell / "drain-status.txt").read_text().strip()
    drain_seconds = int((cell / "drain-seconds.txt").read_text()) if (cell / "drain-seconds.txt").is_file() else None
    zero_keys = ("staging_blocks", "staging_block_bytes", "staging_writing_blocks",
                 "staging_files", "staging_file_bytes")
    snapshot = tsv_rows(cell / "rawstaging-at-drain-end.tsv")
    try:
        snapshot_bytes = sum(int(row["size_bytes"]) for row in snapshot)
        last_files = int(drain[-1]["staging_files"]); last_file_bytes = int(drain[-1]["staging_file_bytes"])
    except (KeyError, ValueError) as exc:
        raise EvidenceError(f"{name}: invalid rawstaging evidence: {exc}") from exc
    if verdict == "LIFECYCLE_FAIL":
        if drain_status != "TIMEOUT" or drain_seconds is not None:
            raise EvidenceError(f"{name}: timeout verdict/status mismatch")
        # The daemon continues draining while the first recursive snapshot is
        # read.  Validate its aggregate bounds, then require the stable snapshot
        # taken after the formal mount stops to be an exact tuple subset.
        if not snapshot or len(snapshot) > last_files or snapshot_bytes > last_file_bytes:
            raise EvidenceError(f"{name}: timeout rawstaging snapshot violates drain bounds")
        stable = tsv_rows(cell / "rawstaging-after-formal-umount.tsv")
        def tuples(rows):
            out = set()
            for row in rows:
                path = row.get("path", "")
                item = (path, int(row["inode"]), int(row["size_bytes"]))
                if item in out or "/rawstaging/" not in path or int(row["size_bytes"]) < 0:
                    raise EvidenceError(f"{name}: invalid or duplicate rawstaging tuple")
                out.add(item)
            return out
        initial_set, stable_set = tuples(snapshot), tuples(stable)
        # It is valid for the original daemon to finish draining between the
        # 900-second snapshot and the later graceful unmount/recovery step.
        if not stable_set.issubset(initial_set):
            raise EvidenceError(f"{name}: stable post-unmount residual is not a snapshot subset")
        span = (int(drain[-1]["epoch_ns"]) - int(drain[0]["epoch_ns"])) / 1e9
        if span < 895:
            raise EvidenceError(f"{name}: timeout drain span too short: {span}")
    else:
        if len(snapshot) != last_files or snapshot_bytes != last_file_bytes:
            raise EvidenceError(f"{name}: rawstaging snapshot disagrees with final drain sample")
        if drain_status != "STRICT_ZERO" or drain_seconds is None or not 0 <= drain_seconds <= 900:
            raise EvidenceError(f"{name}: strict drain verdict/status mismatch")
        if len(drain) < 2 or any(any(float(row[k]) != 0 for k in zero_keys) for row in drain[-2:]):
            raise EvidenceError(f"{name}: last two drain samples are not strict zero")
    reads = tsv_rows(cell / "recovery-read-sample.tsv")
    if len(reads) != 3 or any(row.get("read_status") != "PASS" for row in reads):
        raise EvidenceError(f"{name}: recovery read sample failed")
    log_counts = {k: int(v) for k, v in tsv_map(cell / "log-counts-formal.tsv").items()}
    required_counts = {"direct_fallback", "real_enospc", "hardlink_error", "noncapacity_upload_error"}
    if set(log_counts) != required_counts:
        raise EvidenceError(f"{name}: log count schema mismatch {sorted(log_counts)}")
    if log_counts["noncapacity_upload_error"]:
        raise EvidenceError(f"{name}: non-capacity upload error cannot enter curve")
    if verdict == "OBSERVED_SAFE_POINT" and (log_counts["real_enospc"] or log_counts["hardlink_error"]):
        raise EvidenceError(f"{name}: safe-point verdict contradicts error counts")
    if verdict == "LIFECYCLE_PASS_TIGHT" and not (log_counts["real_enospc"] or log_counts["hardlink_error"]):
        raise EvidenceError(f"{name}: tight-pass verdict lacks capacity error")
    if verdict != "LIFECYCLE_FAIL" and drain_seconds is None:
        raise EvidenceError(f"{name}: strict drain seconds missing")
    effective = None if verdict == "LIFECYCLE_FAIL" else written / 1048576 / (runtime_ms / 1000 + drain_seconds)
    return {
        "cell": name, "nominal_GiB": CAPACITY_GIB[name], "actual_available_bytes": actual,
        "actual_available_GiB": actual / 1024**3, "peak_staging_bytes": peak,
        "peak_staging_ratio_pct": peak / actual * 100, "minimum_observed_free_bytes": minimum_free,
        "fio_runtime_ms": runtime_ms, "fio_write_bytes": written,
        "foreground": bandwidth(aggregate_logs(cell)),
        "drain_seconds_to_95pct": milestone_seconds(drain, fio_end_ns, end_bytes, .05),
        "drain_seconds_to_99pct": milestone_seconds(drain, fio_end_ns, end_bytes, .01),
        "strict_zero_seconds": drain_seconds, "effective_MiBs": effective,
        "log_counts": log_counts, "verdict": verdict,
    }


def analyze(root):
    cells = {path.name for path in (root / "cells").iterdir() if path.is_dir()}
    missing = set(CORE) - cells
    if missing:
        raise EvidenceError(f"core capacity cells missing: {sorted(missing)}")
    results = [analyze_cell(root, x) for x in CORE]
    by_name = {x["cell"]: x for x in results}
    requires_w96 = (by_name["W64-randwrite"]["verdict"] == "LIFECYCLE_FAIL" and
                    by_name["W128-randwrite"]["verdict"] != "LIFECYCLE_FAIL")
    if requires_w96:
        if "W96-randwrite" not in cells:
            raise EvidenceError("conditional W96 required but missing")
        results.append(analyze_cell(root, "W96-randwrite"))
    elif "W96-randwrite" in cells:
        raise EvidenceError("W96 present without preregistered condition")
    safe = [x for x in results if x["verdict"] == "OBSERVED_SAFE_POINT"]
    capacity = (f"OBSERVED_MIN_SAFE_POINT:{min(x['actual_available_GiB'] for x in safe):.3f}_GiB"
                if safe else "NO_SAFE_POINT_AT_OR_BELOW_128_GIB")
    recovery = {x["cell"]: recovery_contract(root, x["cell"]) for x in results}
    return {"schema": 1, "run_id": root.name.removeprefix("opencode-04tmp2f-"),
            "curve": "COMPLETE", "capacity": capacity, "cells": results,
            "recovery": recovery}


def self_test(root):
    root.mkdir(parents=True, exist_ok=True)
    stable = {x: 1000.0 for x in range(180)}
    stats = bandwidth(stable)
    if stats["mean_MiBs"] != 1000 or stats["w4_w1"] != 1:
        raise EvidenceError("bandwidth self-test")
    rows = [{"epoch_ns": str(x * 10**9), "staging_block_bytes": str(100 - x),
             "available_bytes": "1000"} for x in range(3)]
    if milestone_seconds(rows, 0, 100, .99) != 1:
        raise EvidenceError("milestone self-test")
    return {"status": "PASS"}


def main():
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="cmd", required=True)
    for command in ("analyze", "self-test"):
        p = sub.add_parser(command); p.add_argument("--root", required=True, type=Path); p.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(); result = analyze(args.root) if args.cmd == "analyze" else self_test(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(result.get("curve", result.get("status")))


if __name__ == "__main__":
    main()
