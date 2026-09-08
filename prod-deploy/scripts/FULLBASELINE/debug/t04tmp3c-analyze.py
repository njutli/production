#!/usr/bin/env python3
"""Offline analyzer for an 04-tmp3c 60-second read cell."""
from __future__ import annotations

import argparse
import json
import math
import statistics
import tempfile
from collections import defaultdict
from pathlib import Path


class EvidenceError(RuntimeError):
    pass


def options(job, doc):
    result = dict(doc.get("global options") or doc.get("global_options") or {})
    result.update(job.get("job options") or job.get("job_options") or {})
    return result


def read_bw_log(path):
    rows, previous = [], 0.0
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split(",")
        if len(fields) < 2:
            raise EvidenceError(f"short bw row {number}")
        try:
            end = float(fields[0]) / 1000.0
            mib = float(fields[1]) / 1024.0
        except ValueError as exc:
            raise EvidenceError(f"invalid bw row {number}") from exc
        if end <= previous or mib < 0 or not math.isfinite(end + mib):
            raise EvidenceError(f"invalid bw interval {number}")
        rows.append((previous, end, mib))
        previous = end
    return rows


def formal_seconds(rows):
    weighted = defaultdict(lambda: [0.0, 0.0])
    for begin, end, value in rows:
        for second in range(math.floor(begin), math.ceil(end)):
            overlap = min(end, second + 1.0) - max(begin, float(second))
            if overlap > 0:
                weighted[second][0] += value * overlap
                weighted[second][1] += overlap
    values = []
    for second in range(10, 50):
        value, weight = weighted[second]
        if weight < 0.999:
            raise EvidenceError(f"formal window gap at second {second}")
        values.append(value / weight)
    return values


def parse_metric_key(key):
    family = key.split("{", 1)[0]
    labels = key.split("{", 1)[1].rsplit("}", 1)[0] if "{" in key else ""
    return family, labels


def metric_series(path, family, method="GET"):
    by_epoch = defaultdict(float)
    for number, line in enumerate(path.read_text().splitlines()[1:], 2):
        fields = line.split("\t", 2)
        if len(fields) != 3:
            raise EvidenceError(f"bad metric row {number}")
        epoch, key, raw = fields
        got_family, labels = parse_metric_key(key)
        if got_family != family or (method and f'method="{method}"' not in labels) or "le=" in labels:
            continue
        try:
            by_epoch[int(epoch)] += float(raw)
        except ValueError as exc:
            raise EvidenceError(f"bad metric value {number}") from exc
    return dict(by_epoch)


def boundary_delta(series, start, end):
    if not series:
        raise EvidenceError("required metric absent")
    before = [epoch for epoch in series if start - 2_000_000_000 <= epoch <= start + 2_000_000_000]
    after = [epoch for epoch in series if end - 2_000_000_000 <= epoch <= end + 2_000_000_000]
    if not before or not after:
        raise EvidenceError("metric boundary coverage")
    left = min(before, key=lambda value: abs(value - start))
    right = min(after, key=lambda value: abs(value - end))
    if right <= left:
        raise EvidenceError("metric boundary order")
    delta = series[right] - series[left]
    if delta < 0:
        raise EvidenceError("counter reset")
    return delta, (right - left) / 1e9, left, right


def validate_fio(cell, expected_file):
    doc = json.loads((cell / "fio.json").read_text())
    jobs = doc.get("jobs")
    if not isinstance(jobs, list) or len(jobs) != 1:
        raise EvidenceError("unique fio job required")
    job = jobs[0]
    opts = options(job, doc)
    checks = (("rw", "read"), ("bs", "20M"), ("direct", "1"),
              ("size", "10G"), ("runtime", "60"), ("allow_file_create", "0"))
    for key, wanted in checks:
        if str(opts.get(key, "")) not in (wanted, "True", "true"):
            raise EvidenceError(f"fio contract {key}")
    # fio 3.28 records most options in JSON but omits a present flag-only
    # --time_based option.  If it does emit the key, it must be truthy; when it
    # omits the key, looping beyond size is the independent runtime proof below.
    if "time_based" in opts and str(opts["time_based"]) not in ("1", "True", "true"):
        raise EvidenceError("fio time_based false")
    if str(opts.get("filename") or job.get("filename")) != expected_file:
        raise EvidenceError("fio filename mismatch")
    if int(job.get("error", 1)) != 0:
        raise EvidenceError("fio reports an I/O error")
    read = job.get("read") or {}
    if int(read.get("io_bytes", 0)) <= 10 * 1024**3 or int((job.get("write") or {}).get("io_bytes", 0)) != 0:
        raise EvidenceError("fio direction or looping contract")
    runtime_ms = int(job.get("job_runtime", 0))
    if not 58_000 <= runtime_ms <= 65_000:
        raise EvidenceError("fio runtime mismatch")
    return job, read, runtime_ms


def analyze(path, expected_file):
    cell = Path(path)
    job, read, runtime_ms = validate_fio(cell, expected_file)
    logs = sorted((cell / "bwlog").glob("*_bw.*.log"))
    if len(logs) != 1:
        raise EvidenceError(f"expected one bw log, got {len(logs)}")
    rows = read_bw_log(logs[0])
    if not rows or rows[-1][1] < 59 or rows[-1][1] > 65:
        raise EvidenceError("bw log runtime coverage")
    values = formal_seconds(rows)
    completion = int((cell / "completion-ns.txt").read_text())
    actual = completion - runtime_ms * 1_000_000
    start, end = actual + 10_000_000_000, actual + 50_000_000_000
    metrics = cell / "juicefs-metrics.tsv"
    families = {
        "get_bytes": "juicefs_object_request_data_bytes",
        "get_count": "juicefs_object_request_durations_histogram_seconds_count",
        "get_duration": "juicefs_object_request_durations_histogram_seconds_sum",
    }
    deltas = {name: boundary_delta(metric_series(metrics, family), start, end)
              for name, family in families.items()}
    get_bytes, metric_seconds, metric_start, metric_end = deltas["get_bytes"]
    get_count = deltas["get_count"][0]
    get_duration = deltas["get_duration"][0]
    if get_count <= 0 or get_bytes <= 0 or get_duration <= 0:
        raise EvidenceError("non-positive GET delta")
    mean = statistics.mean(values)
    avg_size = get_bytes / get_count
    avg_latency_s = get_duration / get_count
    clat = read.get("clat_ns") or {}; percentile = clat.get("percentile") or {}
    return {
        "actual_start_ns": actual,
        "completion_ns": completion,
        "runtime_ms": runtime_ms,
        "formal_start_ns": start,
        "formal_end_ns": end,
        "formal_mean_MiBs": mean,
        "formal_median_MiBs": statistics.median(values),
        "formal_cv_pct": statistics.pstdev(values) / mean * 100,
        "formal_windows_MiBs": [statistics.mean(values[index:index + 10]) for index in range(0, 40, 10)],
        "formal_seconds_MiBs": values,
        "fio_summary_MiBs": float(read.get("bw", 0)) / 1024,
        "clat_mean_us": float(clat.get("mean", 0)) / 1000,
        "clat_p99_us": float(percentile.get("99.000000", 0)) / 1000,
        "metric_start_ns": metric_start,
        "metric_end_ns": metric_end,
        "metric_interval_s": metric_seconds,
        "get_bytes_delta": get_bytes,
        "get_count_delta": get_count,
        "get_duration_s_delta": get_duration,
        "avg_get_size_bytes": avg_size,
        "avg_get_latency_ms": avg_latency_s * 1000,
        "inflight_little": mean * 1024**2 * avg_latency_s / avg_size,
    }


def self_test():
    with tempfile.TemporaryDirectory(prefix="t04tmp3c-") as temp:
        cell = Path(temp); (cell / "bwlog").mkdir()
        (cell / "bwlog/x_bw.1.log").write_text("".join(f"{(i + 1) * 1000},1024\n" for i in range(60)))
        (cell / "completion-ns.txt").write_text("1060000000000\n")
        job = {"error": 0, "job_runtime": 60000,
               "job options": {"rw": "read", "bs": "20M", "direct": "1", "size": "10G", "runtime": "60", "allow_file_create": "0", "filename": "/x"},
               "read": {"bw": 1024, "io_bytes": 20 * 1024**3, "clat_ns": {"mean": 1000, "percentile": {"99.000000": 2000}}}, "write": {"io_bytes": 0}}
        (cell / "fio.json").write_text(json.dumps({"jobs": [job]}))
        lines = ["epoch_ns\tmetric\tvalue"]
        for i in range(62):
            epoch = 1_000_000_000_000 + i * 1_000_000_000
            for family, rate in (("juicefs_object_request_data_bytes", 1024), ("juicefs_object_request_durations_histogram_seconds_count", 1), ("juicefs_object_request_durations_histogram_seconds_sum", .001)):
                lines.append(f'{epoch}\t{family}{{method="GET",vol_name="x"}}\t{i * rate}')
        (cell / "juicefs-metrics.tsv").write_text("\n".join(lines) + "\n")
        result = analyze(cell, "/x")
        assert result["formal_windows_MiBs"] == [1, 1, 1, 1]
        assert result["avg_get_size_bytes"] == 1024
        assert abs(result["avg_get_latency_ms"] - 1) < 1e-9
    print("T04TMP3C_ANALYZER_SELFTEST_PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("cell", "self-test"))
    parser.add_argument("path", nargs="?")
    parser.add_argument("--expected-file")
    args = parser.parse_args()
    if args.mode == "self-test":
        self_test()
    else:
        if not args.path or not args.expected_file:
            raise EvidenceError("cell path and expected file required")
        print(json.dumps(analyze(args.path, args.expected_file), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (EvidenceError, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"T04TMP3C_ANALYZER_FAIL\t{exc}", file=__import__("sys").stderr)
        raise SystemExit(2)
