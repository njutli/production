#!/usr/bin/env python3
"""Second-party mechanism analysis for 05-2.

New runs use 1 Hz snapshots named by epoch nanoseconds and are restricted to
the fio [15,175) formal window. The historical replay path accepts only an
05-1 pre/post endpoint pair and labels it as non-formal replay evidence.
"""
import argparse
import json
import math
import re
import statistics
import tempfile
from pathlib import Path

LINE = re.compile(r"^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{([^}]*)\})?\s+([-+0-9.eE]+)(?:\s+\d+)?$")
RUNTIME_S = 180.0
FORMAL_LEFT_S = 15.0
FORMAL_RIGHT_S = 175.0


class EvidenceError(RuntimeError):
    pass


def percentile(values, fraction):
    ordered = sorted(values)
    pos = (len(ordered) - 1) * fraction
    lo, hi = math.floor(pos), math.ceil(pos)
    return ordered[lo] if lo == hi else ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def snapshot(path, allow_missing_counters=False):
    out = {key: 0.0 for key in ("uploading", "put_bytes", "put_count", "put_sum", "buffer")}
    seen = set()
    for raw in path.read_text(errors="replace").splitlines():
        match = LINE.match(raw.strip())
        if not match:
            continue
        name, labels, raw_value = match.groups()
        value = float(raw_value)
        label_put = labels is not None and 'method="PUT"' in labels
        key = None
        if name == "juicefs_object_request_uploading":
            key = "uploading"
        elif name == "juicefs_used_buffer_size_bytes":
            key = "buffer"
        elif ((name == "juicefs_object_request_data_bytes" and label_put)
              or name == "juicefs_object_request_data_bytes_PUT"):
            key = "put_bytes"
        elif ((name == "juicefs_object_request_durations_histogram_seconds_count" and label_put)
              or name in ("juicefs_object_request_durations_histogram_seconds_PUT_count",
                          "juicefs_object_request_durations_histogram_seconds_PUT_total")):
            key = "put_count"
        elif ((name == "juicefs_object_request_durations_histogram_seconds_sum" and label_put)
              or name == "juicefs_object_request_durations_histogram_seconds_PUT_sum"):
            key = "put_sum"
        if key:
            out[key] += value
            seen.add(key)
    required = {"uploading", "buffer"}
    if not allow_missing_counters:
        required |= {"put_bytes", "put_count", "put_sum"}
    missing = required - seen
    if missing:
        raise EvidenceError(f"{path}: missing metrics {sorted(missing)}")
    return out


def io_window(cell):
    end_path = cell / "formal" / "fio-end-epoch-ns.txt"
    fio_path = cell / "formal" / "fio.json"
    if not end_path.is_file() or not fio_path.is_file():
        raise EvidenceError(f"{cell.name}: fio time evidence missing")
    end_ns = int(end_path.read_text().strip())
    data = json.loads(fio_path.read_text())
    runtimes = []
    for job in data.get("jobs", []):
        if int(job.get("error", 0)) != 0:
            raise EvidenceError(f"{cell.name}: fio job error")
        for direction in ("read", "write"):
            value = float(job.get(direction, {}).get("runtime", 0)) / 1000.0
            if value:
                runtimes.append(value)
    runtime = max([RUNTIME_S] + runtimes)
    start_ns = end_ns - int(runtime * 1_000_000_000)
    return start_ns, end_ns, runtime


def rows_for_cell(cell):
    start_ns, end_ns, runtime = io_window(cell)
    mechanism = sorted((cell / "mechanism").glob("*.prom"))
    if mechanism:
        candidates = []
        for path in mechanism:
            try:
                epoch_ns = int(path.stem)
            except ValueError as exc:
                raise EvidenceError(f"{path}: sampler filename is not epoch-ns") from exc
            candidates.append((epoch_ns, path))
        left = start_ns + int(FORMAL_LEFT_S * 1e9)
        right = start_ns + int(FORMAL_RIGHT_S * 1e9)
        selected = [(ts, snapshot(path)) for ts, path in candidates if left <= ts < right]
        if len(selected) < 150:
            raise EvidenceError(f"{cell.name}: formal sampler coverage {len(selected)}/160")
        if selected[0][0] - left > 2_500_000_000 or right - selected[-1][0] > 2_500_000_000:
            raise EvidenceError(f"{cell.name}: formal sampler boundary gap exceeds 2.5s")
        return selected, "formal_1hz", start_ns, end_ns, runtime

    pre, post = cell / "metrics-pre.prom", cell / "metrics-post.prom"
    if pre.is_file() and post.is_file():
        return [(start_ns, snapshot(pre, allow_missing_counters=True)),
                (end_ns, snapshot(post))], "historical_endpoint_replay", start_ns, end_ns, runtime
    raise EvidenceError(f"{cell.name}: no supported mechanism evidence")


def analyze_cell(cell):
    rows, mode, start_ns, end_ns, runtime = rows_for_cell(cell)
    timestamps = [row[0] for row in rows]
    elapsed = (timestamps[-1] - timestamps[0]) / 1e9
    if elapsed <= 0:
        raise EvidenceError(f"{cell.name}: non-positive mechanism interval")
    for key in ("put_bytes", "put_count", "put_sum"):
        series = [row[1][key] for row in rows]
        if any(right < left for left, right in zip(series, series[1:])):
            raise EvidenceError(f"{cell.name}: {key} counter reset")
    uploading = [row[1]["uploading"] for row in rows]
    buffers = [row[1]["buffer"] for row in rows]
    deltas = {key: rows[-1][1][key] - rows[0][1][key]
              for key in ("put_bytes", "put_count", "put_sum")}
    count = deltas["put_count"]
    return {
        "cell": cell.name,
        "evidence_mode": mode,
        "sample_count": len(rows),
        "sample_elapsed_s": elapsed,
        "fio_runtime_s": runtime,
        "actual_io_start_epoch_ns": start_ns,
        "fio_end_epoch_ns": end_ns,
        "uploading_mean": statistics.mean(uploading),
        "uploading_p95": percentile(uploading, .95),
        "uploading_max": max(uploading),
        "buffer_p95_MiB": percentile(buffers, .95) / 1048576.0,
        "put_bytes_delta": deltas["put_bytes"],
        "put_bytes_rate_MiB_s": deltas["put_bytes"] / elapsed / 1048576.0,
        "put_ops_s": count / elapsed,
        "put_avg_size_KiB": deltas["put_bytes"] / count / 1024.0 if count else None,
        "put_avg_latency_ms": deltas["put_sum"] / count * 1000.0 if count else None,
    }


def analyze(root):
    rows = []
    cells_dir = root / "cells"
    if not cells_dir.is_dir():
        raise EvidenceError("cells directory missing")
    for cell in sorted(cells_dir.iterdir()):
        if cell.is_dir() and (cell / "formal" / "fio.json").is_file():
            rows.append(analyze_cell(cell))
    if not rows:
        raise EvidenceError("no analyzable cells")
    return {"schema": 2, "root": str(root), "cells": rows,
            "decision": "REQUIRES_SECOND_PARTY_EFFECT_RECOMPUTATION"}


def self_test():
    with tempfile.TemporaryDirectory() as temp:
        cell = Path(temp) / "cells" / "fixture"
        formal, mechanism = cell / "formal", cell / "mechanism"
        formal.mkdir(parents=True)
        mechanism.mkdir()
        start = 1_000_000_000_000
        end = start + int(RUNTIME_S * 1e9)
        (formal / "fio-end-epoch-ns.txt").write_text(f"{end}\n")
        (formal / "fio.json").write_text(json.dumps({"jobs": [{"error": 0, "read": {"runtime": 180000}, "write": {"runtime": 180000}}]}))
        for second in range(181):
            ts = start + int(second * 1e9)
            text = (f'juicefs_object_request_uploading{{mp="x"}} {100 + second % 20}\n'
                    f'juicefs_used_buffer_size_bytes{{mp="x"}} {second * 1048576}\n'
                    f'juicefs_object_request_data_bytes{{method="PUT",mp="x"}} {second * 10485760}\n'
                    f'juicefs_object_request_durations_histogram_seconds_count{{method="PUT",mp="x"}} {second * 40}\n'
                    f'juicefs_object_request_durations_histogram_seconds_sum{{method="PUT",mp="x"}} {second * 0.8}\n')
            (mechanism / f"{ts}.prom").write_text(text)
        result = analyze(Path(temp))["cells"][0]
        assert result["sample_count"] == 160
        assert abs(result["put_bytes_rate_MiB_s"] - 10.0) < 1e-9
        assert abs(result["put_avg_latency_ms"] - 20.0) < 1e-9
    print(json.dumps({"status": "PASS", "checks": ["formal_window", "counter_rate", "uploading", "PUT_count_sum"]}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("self-test", "analyze"))
    parser.add_argument("--root", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "self-test":
        self_test()
        return
    if args.root is None:
        raise SystemExit("--root required")
    result = analyze(args.root)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
