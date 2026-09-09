#!/usr/bin/env python3
"""Offline-only descriptive analyzer for 04-8.

It consumes a frozen cell directory and never contacts Ceph, TiKV, JuiceFS or
the remote host.  The executor supplies raw fio files; this tool only performs
the deterministic bandwidth/window arithmetic needed for independent review.
It deliberately does not approve a production change.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import tempfile
from pathlib import Path

WINDOWS = (("W1", 15.0, 55.0), ("W2", 55.0, 95.0),
           ("W3", 95.0, 135.0), ("W4", 135.0, 175.0))


def finite(value):
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def percentile(values, q):
    values = sorted(values)
    if not values:
        return None
    pos = (len(values) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    return values[lo] if lo == hi else values[lo] + (values[hi] - values[lo]) * (pos - lo)


def _runtime_ms(data):
    jobs = data.get("jobs", [])
    if len(jobs) != 1 or int(jobs[0].get("error", -1)) != 0:
        raise ValueError("fio must contain one successful grouped job")
    options = jobs[0].get("job options", {})
    runtime = []
    for direction in ("read", "write"):
        value = finite(jobs[0].get(direction, {}).get("runtime"))
        if value and value > 0:
            runtime.append(value)
    if not runtime:
        raise ValueError("fio runtime is missing")
    return max(runtime), int(options.get("numjobs", 1))


def _intervals(path, wanted_direction=None, default_direction=0):
    previous = {0: 0.0, 1: 0.0}
    rows = []
    for raw in path.read_text(errors="replace").splitlines():
        fields = raw.replace(",", " ").split()
        if len(fields) < 2:
            continue
        timestamp = finite(fields[0])
        # fio bandwidth logs use KiB/s in column 2 and relative milliseconds
        bandwidth = finite(fields[1])
        direction = int(fields[2]) if len(fields) >= 3 and fields[2].strip() else default_direction
        if direction not in (0, 1):
            raise ValueError(f"invalid ddir in {path}")
        if timestamp is None or bandwidth is None or timestamp <= previous[direction]:
            continue
        begin = previous[direction]
        previous[direction] = timestamp
        if wanted_direction is None or direction == wanted_direction:
            rows.append((begin / 1000.0, timestamp / 1000.0, bandwidth / 1024.0))
    if not rows:
        raise ValueError(f"no usable interval rows in {path}")
    return rows


def _weighted_series(logs, wanted_direction=None, default_direction=0):
    bins = {}
    for path in logs:
        job = {}
        for start, end, value in _intervals(path, wanted_direction, default_direction):
            for second in range(math.floor(start), math.ceil(end)):
                overlap = min(end, second + 1.0) - max(start, float(second))
                if overlap > 0:
                    total, weight = job.get(second, (0.0, 0.0))
                    job[second] = (total + value * overlap, weight + overlap)
        for second, (total, weight) in job.items():
            if weight > 0:
                bins.setdefault(second, {})[path.name] = total / weight
    # A second is valid only if every per-job log contributed to it.
    expected = {path.name for path in logs}
    return {second: sum(values.values()) for second, values in bins.items()
            if set(values) == expected}


def analyze_cell(cell, expected_jobs, direction=None, default_direction=0):
    cell = Path(cell)
    if not cell.is_dir() or cell.is_symlink():
        raise ValueError(f"invalid cell directory: {cell}")
    rc = (cell / "fio.rc").read_text().strip()
    if rc != "0":
        raise ValueError(f"{cell}: fio rc={rc}")
    runtime, actual_jobs = _runtime_ms(json.loads((cell / "fio.json").read_text()))
    if actual_jobs != expected_jobs:
        raise ValueError(f"{cell}: numjobs={actual_jobs}, expected={expected_jobs}")
    logs = sorted((cell / "bwlog").glob("*.log"))
    if len(logs) != expected_jobs:
        raise ValueError(f"{cell}: bw log count={len(logs)}, expected={expected_jobs}")
    wanted_direction = {"read": 0, "write": 1}.get(direction)
    series = _weighted_series(logs, wanted_direction, default_direction)
    formal = [series[s] for s in sorted(series) if 15 <= s < 175]
    if len(formal) < 144:
        raise ValueError(f"{cell}: formal window has only {len(formal)} complete seconds")
    windows = {}
    for name, lo, hi in WINDOWS:
        values = [series[s] for s in sorted(series) if lo <= s < hi]
        if len(values) < 36:
            raise ValueError(f"{cell}: {name} has only {len(values)} complete seconds")
        mean = statistics.mean(values)
        windows[name] = {"n": len(values), "mean_MiB_s": mean,
                         "median_MiB_s": statistics.median(values),
                         "P10_MiB_s": percentile(values, .10),
                         "P90_MiB_s": percentile(values, .90),
                         "CV": statistics.pstdev(values) / mean if mean else None}
    end_ns = int((cell / "fio-end-ns.txt").read_text().strip())
    start_ns = end_ns - int(runtime * 1_000_000)
    return {"cell": cell.name, "direction": direction or "aggregate",
            "expected_jobs": expected_jobs,
            "runtime_ms": runtime, "actual_io_start_ns": start_ns,
            "formal_seconds": len(formal),
            "effective_bw_MiB_s": statistics.mean(formal),
            "formal_median_MiB_s": statistics.median(formal),
            "formal_CV": statistics.pstdev(formal) / statistics.mean(formal),
            "windows": windows,
            "series": {str(k): v for k, v in sorted(series.items())}}


def pair_effect(cells, candidate, baseline):
    return cells[candidate]["effective_bw_MiB_s"] / cells[baseline]["effective_bw_MiB_s"] - 1.0


def _metrics_text(path):
    values = {}
    for raw in Path(path).read_text(errors="replace").splitlines():
        if not raw or raw.startswith("#") or " " not in raw:
            continue
        name, value = raw.split(None, 1)
        name = name.split("{", 1)[0]
        number = finite(value.split()[0])
        if number is not None:
            values[name] = values.get(name, 0.0) + number
    return values


def metrics_delta(before, after, output, mode):
    pre, post = _metrics_text(before), _metrics_text(after)

    def delta(*names):
        for name in names:
            if name in post:
                # JuiceFS omits some zero-valued counters from a fresh
                # mount's .stats.  A missing pre counter is therefore the
                # exact zero baseline; post must still contain the metric.
                value = post[name] - pre.get(name, 0.0)
                if value < 0:
                    raise ValueError(f"counter decreased: {name}")
                return value
        raise ValueError(f"missing metric: {names[0]}")

    # These names are the Prometheus names emitted by the frozen 04-6b
    # JuiceFS metrics endpoint.  Keep the historical suffixed spelling as a
    # read-only compatibility fallback for older captures.
    read_duration = delta("juicefs_fuse_ops_durations_seconds_read",
                          "juicefs_fuse_ops_durations_seconds_read_sum")
    read_bytes = delta("juicefs_fuse_read_size_bytes_sum")
    read_count = delta("juicefs_fuse_ops_total_read")
    result = {
        "mode": mode,
        "read_bytes": read_bytes,
        "read_duration_s": read_duration,
        "read_ns_per_byte": read_duration * 1e9 / read_bytes if read_bytes else None,
        "read_count": read_count,
    }
    if mode == "detector":
        ns = result["read_ns_per_byte"]
        result["detector_calibration_ns_per_byte"] = 3.287
        result["detector_tolerance"] = 0.10
        result["detector_max_ns_per_byte"] = 3.287 * 1.10
        # The detector rejects only abnormally slow mounts.  A lower ns/B is
        # better and must not be treated as a bad tier.
        result["detector_gate"] = bool(ns is not None and ns <= 3.287 * 1.10)
        if not result["detector_gate"]:
            raise ValueError(f"detector ns/B above slow-tier ceiling: {ns}")
    elif mode == "seqwrite":
        write_duration = delta("juicefs_fuse_ops_durations_seconds_write",
                               "juicefs_fuse_ops_durations_seconds_write_sum")
        write_bytes = delta("juicefs_fuse_written_size_bytes_sum",
                            "juicefs_fuse_write_size_bytes_sum")
        write_count = delta("juicefs_fuse_ops_total_write")
        put_duration = delta("juicefs_object_request_durations_histogram_seconds_PUT_sum")
        put_count = delta("juicefs_object_request_durations_histogram_seconds_PUT_total")
        result.update({
            "write_bytes": write_bytes,
            "write_duration_s": write_duration,
            "write_ns_per_byte": write_duration * 1e9 / write_bytes if write_bytes else None,
            "write_count": write_count,
            "write_average_request_bytes": write_bytes / write_count if write_count else None,
            "put_count": put_count,
            "put_duration_s": put_duration,
            "put_average_duration_ms": put_duration * 1000.0 / put_count if put_count else None,
        })
    else:
        raise ValueError(f"unknown metrics mode: {mode}")
    Path(output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def phase_a(root, output):
    root = Path(root)
    order = [("S01", "A"), ("S02", "B"), ("S03", "B"), ("S04", "A"),
             ("S05", "B"), ("S06", "A"), ("S07", "A"), ("S08", "B")]
    cells = {name: analyze_cell(root / "cells" / f"{name}-seqwrite", 1, None, 1) for name, _ in order}
    effects = [pair_effect(cells, "S02", "S01"), pair_effect(cells, "S03", "S04"),
               pair_effect(cells, "S05", "S06"), pair_effect(cells, "S08", "S07")]
    noise = [cells["S03"]["effective_bw_MiB_s"] / cells["S02"]["effective_bw_MiB_s"] - 1.0,
             cells["S07"]["effective_bw_MiB_s"] / cells["S06"]["effective_bw_MiB_s"] - 1.0]
    result = {"schema": 1, "scope": "descriptive_only", "phase": "A",
              "formal_window": "[15,175)", "cells": cells,
              "pair_effects": effects, "epsilon": max(abs(x) for x in noise),
              "boundary_M": max(.05, 2 * max(abs(x) for x in noise)),
              "same_arm_noise": noise,
              "mechanism_verdict": "REQUIRES_INDEPENDENT_REVIEW"}
    Path(output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def phase_b(root, output):
    root = Path(root)
    names = ("C01", "C02", "C03", "C04")
    workloads = ("seqread", "mseqread", "randread", "mseqwrite", "randwrite", "randrw")
    cells = {name: {} for name in names}
    for name in names:
        for workload in workloads:
            expected = 128 if workload in {"randread", "randwrite", "randrw"} else (16 if workload in {"mseqread", "mseqwrite"} else 1)
            cell = root / "cells" / f"{name}-{workload}"
            if workload == "randrw":
                # randrw is two independent directions; never add them.
                cells[name][workload] = {
                    "read": analyze_cell(cell, expected, "read", 0),
                    "write": analyze_cell(cell, expected, "write", 1),
                }
            else:
                default_direction = 0 if workload in {"seqread", "mseqread"} else 1
                cells[name][workload] = analyze_cell(cell, expected, None, default_direction)
    effects = {}
    for workload in workloads:
        if workload == "randrw":
            effects[workload] = {}
            for direction in ("read", "write"):
                directional = {k: cells[k][workload][direction] for k in names}
                effects[workload][direction] = [
                    pair_effect(directional, "C02", "C01"),
                    pair_effect(directional, "C03", "C04"),
                ]
        else:
            effects[workload] = [
                pair_effect({k: cells[k][workload] for k in names}, "C02", "C01"),
                pair_effect({k: cells[k][workload] for k in names}, "C03", "C04"),
            ]
    result = {"schema": 1, "scope": "descriptive_only", "phase": "B",
              "formal_window": "[15,175)", "cells": cells,
              "pair_effects": effects,
              "mechanism_verdict": "REQUIRES_INDEPENDENT_REVIEW"}
    Path(output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def self_test():
    def make_cell(cell, jobs, read_bw=1000, write_bw=None):
        cell.mkdir(parents=True); (cell / "bwlog").mkdir()
        (cell / "fio.rc").write_text("0\n")
        payload = {"error": 0, "job options": {"numjobs": jobs}}
        if read_bw is not None:
            payload["read"] = {"runtime": 180000}
        if write_bw is not None:
            payload["write"] = {"runtime": 180000}
        (cell / "fio.json").write_text(json.dumps({"jobs": [payload]}))
        (cell / "fio-end-ns.txt").write_text("180000000000\n")
        for job in range(jobs):
            if write_bw is None:
                rows = "\n".join(f"{i * 1000},{read_bw},0" for i in range(1, 181)) + "\n"
            else:
                # fio randrw emits read/write rows interleaved in one per-job log;
                # column 3 (ddir) is the direction contract.
                rows = "\n".join(
                    f"{i * 1000},{read_bw},0\n{i * 1000},{write_bw},1"
                    for i in range(1, 181)) + "\n"
            (cell / "bwlog" / f"job-{job}.log").write_text(rows)

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory); cell = root / "cell"
        make_cell(cell, 1)
        result = analyze_cell(cell, 1)
        assert abs(result["effective_bw_MiB_s"] - 0.9765625) < 1e-9
        assert result["formal_seconds"] == 160
        mseq = root / "mseq"; make_cell(mseq, 16, read_bw=2048)
        assert abs(analyze_cell(mseq, 16)["effective_bw_MiB_s"] - 32.0) < 1e-9
        mixed = root / "randrw"; make_cell(mixed, 128, read_bw=1024, write_bw=512)
        read = analyze_cell(mixed, 128, "read", 0)
        write = analyze_cell(mixed, 128, "write", 1)
        assert abs(read["effective_bw_MiB_s"] - 128.0) < 1e-9
        assert abs(write["effective_bw_MiB_s"] - 64.0) < 1e-9
        assert read["effective_bw_MiB_s"] != write["effective_bw_MiB_s"]
        before = root / "metrics.before"; after = root / "metrics.after"
        # Minimal fixture copied from the actual 04-6b juicefs.stats schema
        # (20260905.../cells/W04-SW/pre-mechanism/juicefs.stats), rather than
        # inventing the old/nonexistent *_sum duration or fuse_write_size
        # names.
        metric_names = (
            "juicefs_fuse_ops_durations_seconds_read",
            "juicefs_fuse_read_size_bytes_sum",
            "juicefs_fuse_ops_total_read",
            "juicefs_fuse_ops_durations_seconds_write",
            "juicefs_fuse_written_size_bytes_sum",
            "juicefs_fuse_ops_total_write",
            "juicefs_object_request_durations_histogram_seconds_PUT_sum",
            "juicefs_object_request_durations_histogram_seconds_PUT_total",
        )
        # Values below are the corresponding pre-snapshot values copied from
        # the 04-6b W04-SW juicefs.stats fixture; only the post values add the
        # deliberately small test interval.
        before_values = {
            metric_names[0]: 0.000026887999999999997,
            metric_names[1]: 0,
            metric_names[2]: 7,
            metric_names[3]: 2243.8441404745395,
            metric_names[4]: 772167172096,
            metric_names[5]: 2945584,
            metric_names[6]: 26958.314898408134,
            metric_names[7]: 2945584,
        }
        before.write_text("\n".join(f"{name} {before_values[name]}" for name in metric_names) + "\n")
        after_values = {
            metric_names[0]: before_values[metric_names[0]] + 3.287,
            metric_names[1]: 1_000_000_000,
            metric_names[2]: before_values[metric_names[2]] + 10,
            metric_names[3]: before_values[metric_names[3]] + 2.0,
            metric_names[4]: before_values[metric_names[4]] + 2_000_000,
            metric_names[5]: before_values[metric_names[5]] + 4,
            metric_names[6]: before_values[metric_names[6]] + 0.8,
            metric_names[7]: before_values[metric_names[7]] + 8,
        }
        after.write_text("\n".join(f"{name} {after_values[name]}" for name in metric_names) + "\n")
        metric_result = metrics_delta(before, after, root / "metrics.json", "detector")
        assert metric_result["detector_gate"] is True
        seq_metrics = metrics_delta(before, after, root / "seq-metrics.json", "seqwrite")
        assert abs(seq_metrics["write_average_request_bytes"] - 500_000) < 1e-9
        zero_pre = root / "metrics.zero-pre"
        zero_pre.write_text("\n".join(
            f"{name} {before_values[name]}" for name in metric_names[:3]
        ) + f"\n{metric_names[4]} 0\n")
        zero_metrics = metrics_delta(zero_pre, after, root / "zero-pre-metrics.json", "seqwrite")
        assert zero_metrics["write_count"] == after_values[metric_names[5]]
        assert zero_metrics["put_count"] == after_values[metric_names[7]]
    print("T048_ANALYZER_SELF_TEST_PASS")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    metrics = sub.add_parser("metrics")
    metrics.add_argument("before")
    metrics.add_argument("after")
    metrics.add_argument("output")
    metrics.add_argument("--mode", choices=("detector", "seqwrite"), required=True)
    for name, function in (("phase-a", phase_a), ("phase-b", phase_b)):
        command = sub.add_parser(name)
        command.add_argument("root")
        command.add_argument("output")
        command.set_defaults(function=function)
    args = parser.parse_args()
    if args.command == "self-test":
        self_test()
    elif args.command == "metrics":
        metrics_delta(args.before, args.after, args.output, args.mode)
    else:
        args.function(args.root, args.output)


if __name__ == "__main__":
    main()
