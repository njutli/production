#!/usr/bin/env python3
"""Offline analyzer for the 04-tmp2g fixed-write foreground curve."""

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
    "W20A-randwrite": 20,
    "W32-randwrite": 32,
    "W64-randwrite": 64,
    "W128-randwrite": 128,
    "W20B-randwrite": 20,
}
CORE = tuple(CAPACITY_GIB)
EXPECTED_JOBS = 128
BYTES_PER_JOB = 1024 ** 3
TOTAL_WRITE_BYTES = EXPECTED_JOBS * BYTES_PER_JOB


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
    # sums already contains MiB/s multiplied by the overlap with this one-second
    # bucket.  Do not divide the final partial sample back to a full second;
    # completed jobs must contribute zero for the remainder of the bucket.
    return {second: sum(values.values()) for second, values in sums.items()}


def bandwidth(series, runtime_ms, written, wall_seconds):
    # Per-job bw logs are relative to each job's active-I/O start rather than
    # the shell launch timestamp.  Keep their windows as active-I/O diagnostics;
    # the user-visible primary rate below deliberately uses launch-to-return wall.
    stop = max(1, math.ceil(runtime_ms / 1000))
    values = [series.get(x, 0.0) for x in range(stop)]
    if not any(values):
        raise EvidenceError("bandwidth series has no write samples")
    cuts = [round(i * len(values) / 4) for i in range(5)]
    windows = [statistics.mean(values[cuts[i]:cuts[i + 1]]) for i in range(4)]
    foreground = written / 1048576 / wall_seconds
    log_mean = statistics.mean(values)
    def prefix(seconds):
        subset = values[:min(seconds, len(values))]
        return statistics.mean(subset)
    return {"mean_MiBs": foreground, "log_mean_MiBs": log_mean,
            "active_io_to_foreground_ratio": log_mean / foreground,
            "median_second_MiBs": statistics.median(values),
            "cv_pct": statistics.pstdev(values) / log_mean * 100,
            "first_30s_MiBs": prefix(30), "first_60s_MiBs": prefix(60),
            "windows_MiBs": windows, "w4_w1": windows[-1] / windows[0]}


def fio_contract(path):
    data = json.loads(path.read_text()); jobs = data.get("jobs", [])
    if len(jobs) != EXPECTED_JOBS or any(int(x.get("error", -1)) for x in jobs):
        raise EvidenceError("fio job contract failed")
    writes = [x.get("write", {}) for x in jobs]
    runtimes = [int(x.get("runtime", 0)) for x in writes]
    sizes = [int(x.get("io_bytes", 0)) for x in writes]
    elapsed = [int(x.get("elapsed", 0)) for x in jobs]
    reported_bw = [int(x.get("bw_bytes", 0)) for x in writes]
    if any(not 0 < x <= 900000 for x in runtimes):
        raise EvidenceError(f"fio runtime implausible: {min(runtimes)}..{max(runtimes)}")
    if any(x != BYTES_PER_JOB for x in sizes) or sum(sizes) != TOTAL_WRITE_BYTES:
        raise EvidenceError(f"fixed write contract failed: {sizes[:3]} total={sum(sizes)}")
    if any(not 0 < x <= 902 for x in elapsed):
        raise EvidenceError(f"fio elapsed implausible: {min(elapsed)}..{max(elapsed)}")
    if any(x <= 0 for x in reported_bw):
        raise EvidenceError("fio reported active bandwidth missing")
    written = sum(sizes)
    return max(runtimes), max(elapsed), written, sum(reported_bw) / 1048576


def fio_timing(cell, elapsed_seconds):
    try:
        start_text = (cell / "fio-start-epoch-ns.txt").read_text().strip()
        end_text = (cell / "fio-end-epoch-ns.txt").read_text().strip()
    except FileNotFoundError as exc:
        raise EvidenceError(f"{cell.name}: fio timing sidecar missing") from exc
    if not re.fullmatch(r"[1-9][0-9]*", start_text) or not re.fullmatch(r"[1-9][0-9]*", end_text):
        raise EvidenceError(f"{cell.name}: invalid fio timing sidecar")
    start_ns, end_ns = int(start_text), int(end_text)
    wall_seconds = (end_ns - start_ns) / 1e9
    if end_ns <= start_ns or abs(wall_seconds - elapsed_seconds) > 2:
        raise EvidenceError(
            f"{cell.name}: fio wall/elapsed mismatch {wall_seconds} vs {elapsed_seconds}"
        )
    return start_ns, end_ns, wall_seconds


def foreground_decision(a, b, w32, w64, w128):
    anchor = (a + b) / 2
    drift = (b / a - 1) * 100
    effects = {
        "W32-randwrite": (w32 / anchor - 1) * 100,
        "W64-randwrite": (w64 / anchor - 1) * 100,
        "W128-randwrite": (w128 / anchor - 1) * 100,
    }
    means = [anchor, w32, w64, w128]
    nondecreasing = all(right >= left for left, right in zip(means, means[1:]))
    if abs(drift) > 8:
        verdict = "INCONCLUSIVE_DRIFT"
    elif nondecreasing and effects["W128-randwrite"] >= 10:
        verdict = "FOREGROUND_CAPACITY_SIGNAL"
    elif max(effects.values()) < 5:
        verdict = "NO_MATERIAL_FOREGROUND_SIGNAL"
    else:
        verdict = "RESOLUTION_INSUFFICIENT"
    return {
        "anchor_mean_MiBs": anchor,
        "anchor_drift_pct": drift,
        "capacity_effects_pct": effects,
        "nondecreasing": nondecreasing,
        "foreground_verdict": verdict,
    }


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
    runtime_ms, elapsed_seconds, written, fio_active_mibs = fio_contract(cell / "fio.json")
    _, fio_end_ns, wall_seconds = fio_timing(cell, elapsed_seconds)
    runtime = numeric_rows(cell / "runtime.tsv"); drain = numeric_rows(cell / "drain.tsv")
    actual = int((cell / "actual-available-bytes.txt").read_text())
    nominal = CAPACITY_GIB[name] * 1024**3
    if not nominal * .90 <= actual <= nominal:
        raise EvidenceError(f"{name}: implausible actual available {actual}")
    all_rows = runtime + drain
    peak = max(int(x["staging_block_bytes"]) for x in all_rows)
    minimum_free = min(int(x["available_bytes"]) for x in all_rows)
    end_bytes = int(drain[0]["staging_block_bytes"])
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
    effective = None if verdict == "LIFECYCLE_FAIL" else written / 1048576 / (wall_seconds + drain_seconds)
    return {
        "cell": name, "nominal_GiB": CAPACITY_GIB[name], "actual_available_bytes": actual,
        "actual_available_GiB": actual / 1024**3, "peak_staging_bytes": peak,
        "cache_to_dataset_pct": actual / TOTAL_WRITE_BYTES * 100,
        "fixed_total_write_bytes": written,
        "peak_staging_ratio_pct": peak / actual * 100, "minimum_observed_free_bytes": minimum_free,
        "fio_runtime_ms": runtime_ms, "fio_elapsed_seconds": elapsed_seconds,
        "fio_wall_seconds": wall_seconds,
        "fio_non_io_overhead_seconds": wall_seconds - runtime_ms / 1000,
        "fio_reported_active_MiBs": fio_active_mibs,
        "fio_write_bytes": written,
        "foreground": bandwidth(aggregate_logs(cell), runtime_ms, written, wall_seconds),
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
    extra = cells - set(CORE)
    if extra:
        raise EvidenceError(f"unexpected capacity cells: {sorted(extra)}")
    by_name = {x["cell"]: x for x in results}
    a = by_name["W20A-randwrite"]["foreground"]["mean_MiBs"]
    b = by_name["W20B-randwrite"]["foreground"]["mean_MiBs"]
    decision = foreground_decision(
        a, b,
        by_name["W32-randwrite"]["foreground"]["mean_MiBs"],
        by_name["W64-randwrite"]["foreground"]["mean_MiBs"],
        by_name["W128-randwrite"]["foreground"]["mean_MiBs"],
    )
    active_decision = foreground_decision(
        by_name["W20A-randwrite"]["fio_reported_active_MiBs"],
        by_name["W20B-randwrite"]["fio_reported_active_MiBs"],
        by_name["W32-randwrite"]["fio_reported_active_MiBs"],
        by_name["W64-randwrite"]["fio_reported_active_MiBs"],
        by_name["W128-randwrite"]["fio_reported_active_MiBs"],
    )
    safe = [x for x in results if x["verdict"] == "OBSERVED_SAFE_POINT"]
    capacity = (f"OBSERVED_MIN_SAFE_POINT:{min(x['actual_available_GiB'] for x in safe):.3f}_GiB"
                if safe else "NO_SAFE_POINT_AT_OR_BELOW_128_GIB")
    recovery = {x["cell"]: recovery_contract(root, x["cell"]) for x in results}
    return {"schema": 1, "run_id": root.name.removeprefix("opencode-04tmp2g-"),
            "curve": "COMPLETE", "capacity": capacity, "cells": results,
            **decision,
            "fio_active_io": {
                "anchor_mean_MiBs": active_decision["anchor_mean_MiBs"],
                "anchor_drift_pct": active_decision["anchor_drift_pct"],
                "capacity_effects_pct": active_decision["capacity_effects_pct"],
                "nondecreasing": active_decision["nondecreasing"],
                "verdict": active_decision["foreground_verdict"],
            },
            "recovery": recovery}


def self_test(root):
    root.mkdir(parents=True, exist_ok=True)
    stable = {x: 1024.0 for x in range(128)}
    stats = bandwidth(stable, 128000, TOTAL_WRITE_BYTES, 128.0)
    if stats["mean_MiBs"] != 1024 or stats["w4_w1"] != 1:
        raise EvidenceError("bandwidth self-test")

    fixture = root / "fio-contract"
    fixture.mkdir()
    good = {"jobs": [{"error": 0, "elapsed": 128,
                                  "write": {"runtime": 128000,
                                               "bw_bytes": 8388608,
                                               "io_bytes": BYTES_PER_JOB}}
                     for _ in range(EXPECTED_JOBS)]}
    fio_json = fixture / "fio.json"
    fio_json.write_text(json.dumps(good))
    if fio_contract(fio_json) != (128000, 128, TOTAL_WRITE_BYTES, 1024.0):
        raise EvidenceError("fixed-volume fio contract self-test")
    good["jobs"][0]["write"]["io_bytes"] -= 1
    fio_json.write_text(json.dumps(good))
    try:
        fio_contract(fio_json)
    except EvidenceError:
        pass
    else:
        raise EvidenceError("fixed-volume rejection self-test")

    (fixture / "fio-start-epoch-ns.txt").write_text("1000000000\n")
    (fixture / "fio-end-epoch-ns.txt").write_text("129000000000\n")
    if fio_timing(fixture, 128)[2] != 128.0:
        raise EvidenceError("fio wall timing self-test")
    (fixture / "fio-end-epoch-ns.txt").unlink()
    try:
        fio_timing(fixture, 128)
    except EvidenceError:
        pass
    else:
        raise EvidenceError("missing timing rejection self-test")

    cases = (
        ((100, 100, 110, 120, 130), "FOREGROUND_CAPACITY_SIGNAL"),
        ((100, 100, 101, 102, 103), "NO_MATERIAL_FOREGROUND_SIGNAL"),
        ((100, 100, 110, 105, 115), "RESOLUTION_INSUFFICIENT"),
        ((100, 109, 110, 120, 130), "INCONCLUSIVE_DRIFT"),
    )
    for values, expected in cases:
        actual = foreground_decision(*values)["foreground_verdict"]
        if actual != expected:
            raise EvidenceError(f"decision self-test: expected {expected}, got {actual}")
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
