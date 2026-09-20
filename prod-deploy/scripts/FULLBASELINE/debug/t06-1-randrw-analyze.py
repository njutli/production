#!/usr/bin/env python3
"""Offline, fail-closed second-party analyzer for 06-1.

The analyzer reads only an evidence tree.  Its primary bandwidth comes from
the actual fio I/O start and overlap-weighted per-job bandwidth logs.  The
four-cell effect decision is deliberately separate from non-performance
evidence validity.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import tempfile
from collections import defaultdict
from pathlib import Path

CELLS = ("C1", "T1", "T2", "C2")
JOBS = 128
FORMAL_START = 15
FORMAL_STOP = 175
METRIC_LINE = re.compile(
    r"^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{([^}]*)\})?\s+([-+0-9.eE]+)(?:\s+\d+)?$"
)
COUNTER_SPECS = {
    "get_bytes": ("juicefs_object_request_data_bytes", "GET"),
    "put_bytes": ("juicefs_object_request_data_bytes", "PUT"),
    "get_count": ("juicefs_object_request_durations_histogram_seconds_count", "GET"),
    "put_count": ("juicefs_object_request_durations_histogram_seconds_count", "PUT"),
    "object_errors": ("juicefs_object_request_errors", ""),
    "cache_hits": ("juicefs_blockcache_hits", ""),
    "cache_miss": ("juicefs_blockcache_miss", ""),
    "hit_bytes": ("juicefs_blockcache_hit_bytes", ""),
    "miss_bytes": ("juicefs_blockcache_miss_bytes", ""),
    "cache_writes": ("juicefs_blockcache_writes", ""),
    "cache_write_bytes": ("juicefs_blockcache_write_bytes", ""),
    "cache_drops": ("juicefs_blockcache_drops", ""),
    "cache_evicts": ("juicefs_blockcache_evicts", ""),
    "cache_read_seconds_sum": ("juicefs_blockcache_read_hist_seconds_sum", ""),
    "cache_read_seconds_count": ("juicefs_blockcache_read_hist_seconds_count", ""),
    "staging_errors": ("juicefs_staging_block_errors", ""),
    "staging_delay_seconds": ("juicefs_staging_block_delay_seconds", ""),
}


class EvidenceError(RuntimeError):
    pass


def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def fio_timing(cell: Path):
    fio = next((path for path in (cell / "formal" / "fio.json", cell / "fio.json") if path.is_file()), None)
    end_file = next((path for path in (cell / "formal" / "fio-end-epoch-ns.txt", cell / "fio-end-epoch-ns.txt") if path.is_file()), None)
    start_file = next((path for path in (cell / "formal" / "fio-start-epoch-ns.txt", cell / "fio-start-epoch-ns.txt", cell / "fio-start-ns.txt") if path.is_file()), None)
    if fio is None or end_file is None or start_file is None:
        raise EvidenceError(f"{cell.name}: fio timing evidence missing")
    data = json.loads(fio.read_text())
    jobs = data.get("jobs", [])
    if not isinstance(jobs, list) or len(jobs) not in (1, JOBS):
        raise EvidenceError(f"{cell.name}: invalid grouped/per-job JSON count")
    runtimes = []
    for job in jobs:
        if int(job.get("error", -1)) != 0:
            raise EvidenceError(f"{cell.name}: fio error")
        for direction in ("read", "write"):
            value = float(job.get(direction, {}).get("runtime", 0)) / 1000.0
            if value > 0:
                runtimes.append(value)
    if not runtimes:
        raise EvidenceError(f"{cell.name}: directional runtime absent")
    runtime = max(180.0, max(runtimes))
    if runtime > 320.0:
        raise EvidenceError(f"{cell.name}: runtime outside contract")
    end_ns = int(end_file.read_text().strip())
    registered_start_ns = int(start_file.read_text().strip())
    actual_start_ns = end_ns - int(runtime * 1_000_000_000)
    delta_s = (actual_start_ns - registered_start_ns) / 1e9
    if registered_start_ns > actual_start_ns + 2_000_000_000:
        raise EvidenceError(f"{cell.name}: registered start is after actual I/O start")
    return data, runtime, actual_start_ns, end_ns, delta_s


def aggregate_logs(paths, runtime_s, expected_jobs=JOBS):
    if len(paths) != expected_jobs:
        raise EvidenceError(f"expected {expected_jobs} logs, got {len(paths)}")
    sums = {0: defaultdict(lambda: defaultdict(float)),
            1: defaultdict(lambda: defaultdict(float))}
    weights = {0: defaultdict(lambda: defaultdict(float)),
               1: defaultdict(lambda: defaultdict(float))}
    ids = []
    for path in paths:
        match = re.fullmatch(r"randrw_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"unexpected bandwidth log: {path.name}")
        job = int(match.group(1))
        ids.append(job)
        seen = set()
        previous = {0: 0.0, 1: 0.0}
        with path.open(newline="") as stream:
            for row in csv.reader(stream):
                if not row or not any(field.strip() for field in row):
                    continue
                if len(row) < 3:
                    raise EvidenceError(f"short bandwidth row: {path.name}")
                end = float(row[0]) / 1000.0
                value = float(row[1]) / 1024.0
                direction = int(row[2])
                if direction not in (0, 1) or not math.isfinite(value):
                    raise EvidenceError(f"invalid direction/value: {path.name}")
                if end < previous[direction] or end > runtime_s + 1.0:
                    raise EvidenceError(f"invalid timestamp: {path.name}")
                begin = previous[direction]
                previous[direction] = end
                seen.add(direction)
                for second in range(math.floor(begin), math.ceil(end)):
                    overlap = min(end, runtime_s, second + 1.0) - max(begin, float(second))
                    if overlap <= 0:
                        continue
                    sums[direction][second][job] += value * overlap
                    weights[direction][second][job] += overlap
        if seen != {0, 1}:
            raise EvidenceError(f"{path.name}: READ/WRITE direction incomplete")
    if sorted(ids) != list(range(1, expected_jobs + 1)):
        raise EvidenceError("bandwidth job IDs are not contiguous")
    result = {0: {}, 1: {}}
    for direction in (0, 1):
        for second, jobs in sums[direction].items():
            if len(jobs) != expected_jobs:
                continue
            if not all(weights[direction][second][job] > 0 for job in range(1, expected_jobs + 1)):
                continue
            result[direction][second] = sum(
                jobs[job] / weights[direction][second][job]
                for job in range(1, expected_jobs + 1)
            )
    return result


def window_stats(series, start=FORMAL_START, stop=FORMAL_STOP, origin=FORMAL_START):
    seconds = [second for second in range(math.ceil(start), math.ceil(stop)) if second in series]
    expected = math.ceil(stop) - math.ceil(start)
    if len(seconds) != expected:
        raise EvidenceError(f"formal coverage {len(seconds)}/{expected}")
    values = [series[second] for second in seconds]
    windows = {}
    for index in range(4):
        left = origin + index * 40
        right = left + 40
        child = [series[second] for second in seconds if left <= second < right]
        if len(child) != 40:
            raise EvidenceError(f"W{index + 1} coverage {len(child)}/40")
        windows[f"W{index + 1}"] = statistics.mean(child)
    mean = statistics.mean(values)
    return {
        "mean_MiB_s": mean,
        "median_MiB_s": statistics.median(values),
        "CV_pct": statistics.pstdev(values) / mean * 100.0 if mean else math.inf,
        "P10_MiB_s": percentile(values, 0.10),
        "P90_MiB_s": percentile(values, 0.90),
        "formal_seconds": len(values),
        "missing_seconds": [second for second in range(15, 175) if second not in series],
        "windows_MiB_s": windows,
        "W4_W1": windows["W4"] / windows["W1"] if windows["W1"] else math.inf,
    }


def parse_prom(path: Path):
    values = defaultdict(float)
    for raw in path.read_text(errors="replace").splitlines():
        match = METRIC_LINE.match(raw.strip())
        if not match:
            continue
        name, labels, raw_value = match.groups()
        label = ""
        if labels:
            method = re.search(r'(?:^|,)method="([^"]+)"', labels)
            if method:
                label = method.group(1)
        values[(name, label)] += float(raw_value)
    return values


def metric(snapshot, name, method=""):
    key = (name, method)
    if method:
        if key not in snapshot:
            raise EvidenceError(f"metric missing: {name} method={method}")
        return snapshot[key]
    matches = [value for (metric_name, _), value in snapshot.items() if metric_name == name]
    if not matches:
        raise EvidenceError(f"metric missing: {name} method={method or 'ALL'}")
    return sum(matches)


def counter_deltas(first, last, scope="metrics"):
    deltas = {}
    for label, (name, method_name) in COUNTER_SPECS.items():
        before = metric(first, name, method_name)
        after = metric(last, name, method_name)
        if after < before:
            raise EvidenceError(f"{scope}: counter reset: {label}")
        deltas[label] = after - before
    return deltas


def mechanism_stats(cell: Path, actual_start_ns: int):
    paths = []
    for item in (cell / "mechanism").glob("*.prom"):
        try:
            paths.append((int(item.stem), item))
        except ValueError as exc:
            raise EvidenceError(f"{cell.name}: non-epoch metric filename") from exc
    candidates = sorted((ts, parse_prom(path)) for ts, path in paths
                        if actual_start_ns + 15_000_000_000 <= ts < actual_start_ns + 175_000_000_000)
    by_second = {}
    for ts, snapshot in candidates:
        second = int((ts - actual_start_ns) // 1_000_000_000)
        by_second.setdefault(second, (ts, snapshot))
    missing = [second for second in range(15, 175) if second not in by_second]
    if missing:
        raise EvidenceError(f"{cell.name}: mechanism missing seconds: {missing}")
    selected = [by_second[second] for second in range(15, 175)]
    # Gap is a property of the raw sampling stream.  Checking only the first
    # selected point in each natural second creates artificial ~1.6 s gaps
    # when the real sampler cadence is ~0.82 s and some seconds have 2 points.
    timestamps = [row[0] for row in candidates]
    if max(right - left for left, right in zip(timestamps, timestamps[1:])) > 1_500_000_000:
        raise EvidenceError(f"{cell.name}: mechanism sampling gap")
    first, last = selected[0][1], selected[-1][1]
    elapsed = (selected[-1][0] - selected[0][0]) / 1e9
    deltas = counter_deltas(first, last, cell.name)
    uploading = [metric(snapshot, "juicefs_object_request_uploading") for _, snapshot in selected]
    cache_bytes = [metric(snapshot, "juicefs_blockcache_bytes") for _, snapshot in selected]
    cache_blocks = [metric(snapshot, "juicefs_blockcache_blocks") for _, snapshot in selected]
    hit_total = deltas["hit_bytes"] + deltas["miss_bytes"]
    return {
        "samples": len(selected),
        "elapsed_s": elapsed,
        "GET_MiB_s": deltas["get_bytes"] / elapsed / 1048576.0,
        "PUT_MiB_s": deltas["put_bytes"] / elapsed / 1048576.0,
        "GET_ops_s": deltas["get_count"] / elapsed,
        "PUT_ops_s": deltas["put_count"] / elapsed,
        "object_errors_delta": deltas["object_errors"],
        "blockcache_hits_delta": deltas["cache_hits"],
        "blockcache_miss_delta": deltas["cache_miss"],
        "hit_bytes_delta": deltas["hit_bytes"],
        "miss_bytes_delta": deltas["miss_bytes"],
        "hit_ratio": deltas["hit_bytes"] / hit_total if hit_total else 0.0,
        "blockcache_writes_delta": deltas["cache_writes"],
        "cache_write_bytes_delta": deltas["cache_write_bytes"],
        "cache_drops_delta": deltas["cache_drops"],
        "cache_evicts_delta": deltas["cache_evicts"],
        "blockcache_read_seconds_delta": deltas["cache_read_seconds_sum"],
        "blockcache_read_count_delta": deltas["cache_read_seconds_count"],
        "blockcache_read_mean_ms": (
            deltas["cache_read_seconds_sum"] / deltas["cache_read_seconds_count"] * 1000.0
            if deltas["cache_read_seconds_count"] else 0.0
        ),
        "staging_block_errors_delta": deltas["staging_errors"],
        "staging_block_delay_seconds_delta": deltas["staging_delay_seconds"],
        "uploading_mean": statistics.mean(uploading),
        "uploading_p95": percentile(uploading, 0.95),
        "uploading_max": max(uploading),
        "blockcache_bytes_max": max(cache_bytes),
        "blockcache_blocks_max": max(cache_blocks),
    }


def validate_df_rows(rows, actual_start_ns: int, scope="df"):
    by_dir = defaultdict(dict)
    raw_timestamps = defaultdict(list)
    lower = actual_start_ns + FORMAL_START * 1_000_000_000
    upper = actual_start_ns + FORMAL_STOP * 1_000_000_000
    for row in rows:
        timestamp = int(row["epoch_ns"])
        if lower <= timestamp < upper:
            second = int((timestamp - actual_start_ns) // 1_000_000_000)
            by_dir[row["dir"]].setdefault(second, row)
            raw_timestamps[row["dir"]].append(timestamp)
    if not by_dir:
        raise EvidenceError(f"{scope}: no cache-device df samples")
    ratios = []
    for directory, samples in by_dir.items():
        missing = [second for second in range(FORMAL_START, FORMAL_STOP) if second not in samples]
        if missing:
            raise EvidenceError(f"{scope}: {directory} missing seconds: {missing}")
        timestamps = sorted(raw_timestamps[directory])
        if max(right - left for left, right in zip(timestamps, timestamps[1:])) > 1_500_000_000:
            raise EvidenceError(f"{scope}: {directory} sampling gap")
        ratios.extend(float(samples[second]["avail_bytes"]) / float(samples[second]["total_bytes"])
                      for second in range(FORMAL_START, FORMAL_STOP))
    return {"samples": len(ratios), "devices": len(by_dir),
            "samples_per_device": FORMAL_STOP - FORMAL_START,
            "min_available_ratio": min(ratios), "stageFull": min(ratios) < 0.10}


def df_gate(cell: Path, actual_start_ns: int):
    if not cell.name.startswith("T"):
        return {"samples": 0, "devices": 0, "samples_per_device": 0,
                "min_available_ratio": None, "stageFull": False}
    path = cell / "df-1hz.tsv"
    if not path.is_file():
        raise EvidenceError(f"{cell.name}: df sampler missing")
    return validate_df_rows(list(csv.DictReader(path.open(), delimiter="\t")),
                            actual_start_ns, cell.name)


def lifecycle_gate(cell: Path):
    readback = cell / "readback-verify.tsv"
    if not readback.is_file() or "remote_readable\tPASS" not in readback.read_text():
        raise EvidenceError(f"{cell.name}: cache-size=0 readback missing/failed")
    if not cell.name.startswith("T"):
        return {"drain_seconds": 0, "strict_zero": True, "readback": "PASS"}
    drain = cell / "drain.tsv"
    seconds = cell / "drain-seconds.txt"
    if not drain.is_file() or not seconds.is_file():
        raise EvidenceError(f"{cell.name}: drain evidence missing")
    rows = list(csv.DictReader(drain.open(), delimiter="\t"))
    if len(rows) < 4:
        raise EvidenceError(f"{cell.name}: drain evidence too short")
    unique_dirs = {row["dir"] for row in rows}
    tail = rows[-2 * len(unique_dirs):]
    fields = ("staging_blocks", "staging_bytes", "staging_writing_blocks",
              "staging_files", "staging_file_bytes")
    strict = all(float(row[field]) == 0 for row in tail for field in fields)
    drain_seconds = int(seconds.read_text().strip())
    if not strict or not 0 <= drain_seconds <= 900:
        raise EvidenceError(f"{cell.name}: strict drain gate failed")
    return {"drain_seconds": drain_seconds, "strict_zero": strict, "readback": "PASS"}


def analyze_cell(root: Path, name: str):
    cell = root / "cells" / name
    if not (cell / "PASS").is_file():
        raise EvidenceError(f"{name}: PASS missing")
    data, runtime, start_ns, end_ns, start_delta = fio_timing(cell)
    paths = sorted((cell / "formal" / "bw").glob("randrw_bw.*.log"))
    series = aggregate_logs(paths, runtime)
    formal = {"read": window_stats(series[0]), "write": window_stats(series[1])}
    mechanism = mechanism_stats(cell, start_ns)
    df = df_gate(cell, start_ns)
    lifecycle = lifecycle_gate(cell)
    log_text = "\n".join(path.read_text(errors="replace") for path in cell.glob("juicefs-*.log"))
    stage_full_log = bool(re.search(r"stage.?full|upload it directly", log_text, re.I))
    hard_errors = []
    if mechanism["object_errors_delta"] != 0:
        hard_errors.append("object_request_errors")
    if mechanism["staging_block_errors_delta"] != 0:
        hard_errors.append("staging_block_errors")
    if df["stageFull"] or stage_full_log:
        hard_errors.append("stageFull")
    return {
        "cell": name, "runtime_s": runtime, "actual_io_start_epoch_ns": start_ns,
        "fio_end_epoch_ns": end_ns, "actual_minus_registered_start_s": start_delta,
        "formal": formal, "mechanism": mechanism, "df": df,
        "lifecycle": lifecycle, "nonperformance_errors": hard_errors,
    }


def decide(rows):
    by = {row["cell"]: row for row in rows}
    effects = {}
    noise_values = []
    for direction in ("read", "write"):
        value = lambda cell: by[cell]["formal"][direction]["mean_MiB_s"]
        effects[direction] = {
            "T1_over_C1_pct": (value("T1") / value("C1") - 1) * 100,
            "T2_over_C2_pct": (value("T2") / value("C2") - 1) * 100,
        }
        noise_values.extend([
            abs(value("C2") / value("C1") - 1) * 100,
            abs(value("T2") / value("T1") - 1) * 100,
        ])
    epsilon = max(noise_values)
    material = max(5.0, 2 * epsilon)
    paired = [value for direction in effects.values() for value in direction.values()]
    invalid = any(row["nonperformance_errors"] for row in rows)
    if invalid:
        validity = "EVIDENCE_INVALID"
        screen = "NO_DECISION"
    elif epsilon >= 5.0:
        validity = "RESOLUTION_INSUFFICIENT"
        screen = "NO_DECISION"
    elif all(value >= material for value in paired):
        validity = "VALID"
        screen = "COMBINATION_L1_CANDIDATE"
    elif all(value <= -material for value in paired):
        validity = "VALID"
        screen = "MATERIAL_REGRESSION"
    elif all(value >= 0 for value in paired) or all(value <= 0 for value in paired):
        validity = "VALID"
        screen = "NO_MATERIAL_BENEFIT"
    else:
        validity = "INCONCLUSIVE"
        screen = "NO_DECISION"
    return {"effects_pct": effects, "epsilon_pct": epsilon, "M_pct": material,
            "RUN_VALIDITY_STATE": validity, "SCREEN_DECISION": screen,
            "causal_scope": "96GiB read cache + writeback + approved multi-path package; no single-variable attribution"}


def analyze(root: Path):
    rows, errors = [], []
    for name in CELLS:
        try:
            rows.append(analyze_cell(root, name))
        except (EvidenceError, OSError, ValueError, json.JSONDecodeError) as exc:
            errors.append(str(exc))
    if errors:
        return {"schema": 1, "cells": rows, "errors": errors,
                "RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "SCREEN_DECISION": "NO_DECISION"}
    result = decide(rows)
    result.update({"schema": 1, "formal_window": "[15,175)", "cells": rows})
    return result


def replay_cell(cell: Path):
    _, runtime, start_ns, end_ns, start_delta = fio_timing(cell)
    paths = sorted((cell / "formal" / "bw").glob("randrw_bw.*.log"))
    series = aggregate_logs(paths, runtime)
    return {"cell": cell.name, "runtime_s": runtime,
            "actual_io_start_epoch_ns": start_ns, "fio_end_epoch_ns": end_ns,
            "actual_minus_registered_start_s": start_delta,
            "formal": {"read": window_stats(series[0]), "write": window_stats(series[1])},
            "evidence_mode": "historical_bandwidth_replay"}


def self_test():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        logs = []
        for job in (1, 2):
            path = root / f"randrw_bw.{job}.log"
            path.write_text("1001,102400,0,0\n1001,81920,1,0\n2000,102400,0,0\n2000,81920,1,0\n")
            logs.append(path)
        aggregate = aggregate_logs(logs, 2.0, expected_jobs=2)
        assert abs(aggregate[0][0] - 200.0) < 1e-9
        assert abs(aggregate[1][0] - 160.0) < 1e-9
        flat = {second: 100.0 for second in range(300)}
        center = window_stats(flat)
        minus = window_stats(flat, 14, 174, 14)
        plus_one = window_stats(flat, 16, 176, 16)
        assert abs(minus["mean_MiB_s"] / center["mean_MiB_s"] - 1) < 0.01
        assert abs(plus_one["mean_MiB_s"] / center["mean_MiB_s"] - 1) < 0.01
        incomplete = dict(flat)
        del incomplete[80]
        try:
            window_stats(incomplete)
        except EvidenceError:
            pass
        else:
            raise AssertionError("missing formal second was accepted")
        transient = {second: (200.0 if second < 58 else 100.0) for second in range(300)}
        shifted = window_stats(transient, 73, 233, 73)
        base = window_stats(transient)
        assert shifted["windows_MiB_s"] != base["windows_MiB_s"]
        fixture_rows = []
        for cell, value in (("C1", 100.0), ("T1", 110.0), ("T2", 111.0), ("C2", 101.0)):
            fixture_rows.append({"cell": cell, "formal": {direction: {"mean_MiB_s": value} for direction in ("read", "write")}, "nonperformance_errors": []})
        decision = decide(fixture_rows)
        assert decision["RUN_VALIDITY_STATE"] == "VALID"
        assert decision["SCREEN_DECISION"] == "COMBINATION_L1_CANDIDATE"
        bad = [dict(row) for row in fixture_rows]
        bad[0] = dict(bad[0], nonperformance_errors=["stageFull"])
        assert decide(bad)["RUN_VALIDITY_STATE"] == "EVIDENCE_INVALID"
        noisy = []
        for cell, value in (("C1", 100.0), ("T1", 110.0), ("T2", 120.0), ("C2", 107.0)):
            noisy.append({"cell": cell, "formal": {direction: {"mean_MiB_s": value} for direction in ("read", "write")}, "nonperformance_errors": []})
        assert decide(noisy)["RUN_VALIDITY_STATE"] == "RESOLUTION_INSUFFICIENT"
        first = {(name, method): 1.0 for name, method in COUNTER_SPECS.values()}
        last = {(name, method): 2.0 for name, method in COUNTER_SPECS.values()}
        deltas = counter_deltas(first, last, "self-test")
        assert set(deltas) == set(COUNTER_SPECS) and all(value == 1.0 for value in deltas.values())
        missing_metric = dict(last)
        missing_metric.pop(COUNTER_SPECS["staging_delay_seconds"])
        try:
            counter_deltas(first, missing_metric, "self-test")
        except EvidenceError:
            pass
        else:
            raise AssertionError("missing required mechanism metric was accepted")
        df_rows = []
        for directory in ("/cache-a", "/cache-b"):
            for second in range(FORMAL_START, FORMAL_STOP):
                df_rows.append({"epoch_ns": str(second * 1_000_000_000 + 100_000_000),
                                "dir": directory, "avail_bytes": "90", "total_bytes": "100"})
        df_result = validate_df_rows(df_rows, 0, "self-test")
        assert df_result["devices"] == 2 and df_result["samples"] == 320
        incomplete_df = [row for row in df_rows
                         if not (row["dir"] == "/cache-b" and row["epoch_ns"] == "80100000000")]
        try:
            validate_df_rows(incomplete_df, 0, "self-test")
        except EvidenceError:
            pass
        else:
            raise AssertionError("missing per-device df second was accepted")
    return {"status": "PASS", "checks": ["overlap_weighting", "formal_window",
            "formal_window_rejects_missing_second",
            "start_sensitivity_plus_minus_1s_and_plus_58s", "epsilon_M",
            "four_state", "stageFull_and_staging_error_hard_gate",
            "complete_mechanism_metrics_and_missing_metric_rejection",
            "per_device_df_160s_and_missing_second_rejection"]}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    run = sub.add_parser("analyze")
    run.add_argument("--root", required=True, type=Path)
    run.add_argument("--output", type=Path)
    replay = sub.add_parser("replay-cell")
    replay.add_argument("--cell", required=True, type=Path)
    replay.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "self-test":
        result = self_test()
    elif args.command == "analyze":
        result = analyze(args.root)
    else:
        result = replay_cell(args.cell)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if getattr(args, "output", None):
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
