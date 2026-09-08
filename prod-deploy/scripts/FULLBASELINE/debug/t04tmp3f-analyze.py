#!/usr/bin/env python3
"""Analyze the fixed 04-tmp3f read-only matrix from raw fio/metric evidence."""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import tempfile
from collections import defaultdict
from pathlib import Path

TARGET_MIB_S = 5149.84
CELLS = ("A01", "A02", "B01", "C01", "C02", "C03", "C04", "B02", "A03", "A04")
FACTORS = {
    "APP_BS_A": (("A01", "A02"), ("A04", "A03")),
    "APP_BS_C": (("C01", "C02"), ("C04", "C03")),
    "RA32": (("A02", "B01"), ("A03", "B02")),
    "MAX_FUSE_1M": (("B01", "C02"), ("B02", "C03")),
}
ANCHORS = {
    "A_256K": ("A01", "A04"), "A_20M": ("A02", "A03"),
    "B_20M": ("B01", "B02"), "C_256K": ("C01", "C04"), "C_20M": ("C02", "C03"),
}


class EvidenceError(RuntimeError):
    pass


def contract(path: Path) -> dict[str, str]:
    out = {}
    for line in (path / "cell-contract.tsv").read_text().splitlines():
        fields = line.split("\t", 1)
        if len(fields) == 2:
            out[fields[0]] = fields[1]
    return out


def fio_options(doc: dict) -> tuple[dict, dict]:
    jobs = doc.get("jobs") or []
    if len(jobs) != 1:
        raise EvidenceError("exactly one fio job required")
    job = jobs[0]
    opts = dict(doc.get("global options") or doc.get("global_options") or {})
    opts.update(job.get("job options") or job.get("job_options") or {})
    return opts, job


def bandwidth_rows(path: Path) -> list[tuple[float, float, float]]:
    rows, previous = [], 0.0
    for line_no, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split(",")
        if len(fields) < 2:
            raise EvidenceError(f"short bandwidth row {line_no}")
        try:
            end, kib_s = float(fields[0]) / 1000.0, float(fields[1])
        except ValueError as exc:
            raise EvidenceError(f"bad bandwidth row {line_no}") from exc
        if end <= previous or kib_s < 0 or not math.isfinite(end + kib_s):
            raise EvidenceError(f"invalid bandwidth row {line_no}")
        rows.append((previous, end, kib_s / 1024.0))
        previous = end
    return rows


def formal_seconds(rows: list[tuple[float, float, float]], start: int = 10, finish: int = 50) -> list[float]:
    weighted = defaultdict(lambda: [0.0, 0.0])
    for begin, end, value in rows:
        for second in range(math.floor(begin), math.ceil(end)):
            overlap = min(end, second + 1.0) - max(begin, float(second))
            if overlap > 0:
                weighted[second][0] += value * overlap
                weighted[second][1] += overlap
    values = []
    for second in range(start, finish):
        total, weight = weighted[second]
        if weight < 0.999:
            raise EvidenceError(f"formal window gap at second {second}")
        values.append(total / weight)
    return values


def metric_rows(path: Path) -> list[tuple[int, str, float]]:
    rows = []
    for line_no, row in enumerate(path.read_text(errors="replace").splitlines()[1:], 2):
        fields = row.split("\t", 2)
        if len(fields) != 3:
            raise EvidenceError(f"bad metric row {line_no}")
        try:
            epoch, value = int(fields[0]), float(fields[2])
        except ValueError as exc:
            raise EvidenceError(f"bad metric row {line_no}") from exc
        if math.isfinite(value):
            rows.append((epoch, fields[1], value))
    return rows


def family(rows, name: str, label: str | None = None) -> dict[int, float]:
    out = defaultdict(float)
    for epoch, key, value in rows:
        if key != name and not key.startswith(name + "{"):
            continue
        if label and label not in key:
            continue
        out[epoch] += value
    return dict(out)


def delta_near(series: dict[int, float], start_ns: int, end_ns: int) -> tuple[float, float]:
    if not series:
        raise EvidenceError("required metric family absent")
    left = [x for x in series if abs(x - start_ns) <= 2_000_000_000]
    right = [x for x in series if abs(x - end_ns) <= 2_000_000_000]
    if not left or not right:
        raise EvidenceError("metric boundary coverage")
    a = min(left, key=lambda x: abs(x - start_ns)); b = min(right, key=lambda x: abs(x - end_ns))
    if b <= a or series[b] < series[a]:
        raise EvidenceError("metric boundary order/reset")
    return series[b] - series[a], (b - a) / 1e9


def sidecar(path: Path, start_ns: int, end_ns: int) -> dict:
    rows = []
    for row in csv.DictReader(path.open(), delimiter="\t"):
        try:
            epoch = int(row["epoch_ns"])
        except (KeyError, ValueError) as exc:
            raise EvidenceError("bad sidecar") from exc
        if start_ns <= epoch <= end_ns:
            rows.append((epoch, row))
    if len(rows) < 35:
        raise EvidenceError("sidecar formal coverage")
    first_epoch, first = rows[0]; last_epoch, last = rows[-1]
    wall = (last_epoch - first_epoch) / 1e9
    if wall <= 0:
        raise EvidenceError("sidecar time order")
    return {
        "samples": len(rows),
        "cpu_mean_cores": ((float(last["utime_ticks"]) - float(first["utime_ticks"])) +
                           (float(last["stime_ticks"]) - float(first["stime_ticks"]))) / 100.0 / wall,
        "rss_pages_max": max(float(row["rss_pages"]) for _, row in rows),
        "threads_max": max(float(row["threads"]) for _, row in rows),
        "nic_rx_mib_s": (float(last["rx_bytes"]) - float(first["rx_bytes"])) / 2**20 / wall,
        "nic_tx_mib_s": (float(last["tx_bytes"]) - float(first["tx_bytes"])) / 2**20 / wall,
    }


def analyze_cell(path: Path) -> dict:
    c = contract(path)
    if c.get("engine") != "psync" or c.get("qd") != "1" or c.get("runtime_s") != "60":
        raise EvidenceError("cell execution contract")
    doc = json.loads((path / "fio.json").read_text())
    opts, job = fio_options(doc)
    for key, wanted in (("rw", "read"), ("bs", c["bs"]), ("size", "10G"), ("ioengine", "psync"),
                        ("iodepth", "1"), ("direct", "1"), ("numjobs", "1"), ("allow_file_create", "0")):
        if str(opts.get(key, "")) != wanted:
            raise EvidenceError(f"fio contract {key}: {opts.get(key)!r}")
    filename = str(opts.get("filename") or job.get("filename") or "")
    if filename != c.get("filename"):
        raise EvidenceError("fio filename contract")
    if "time_based" in opts and str(opts["time_based"]) not in ("1", "True", "true"):
        raise EvidenceError("fio time_based false")
    if int(job.get("error", -1)) != 0 or int((job.get("write") or {}).get("io_bytes", 0)) != 0:
        raise EvidenceError("fio error or unexpected write")
    if int((job.get("read") or {}).get("io_bytes", 0)) <= 10 * 1024**3:
        raise EvidenceError("time_based looping proof")
    runtime_ms = int(job.get("job_runtime", 0))
    if not 58_000 <= runtime_ms <= 65_000:
        raise EvidenceError("fio runtime")
    rc = int((path / "fio.rc").read_text().strip())
    if rc != 0:
        raise EvidenceError("fio return code")
    logs = sorted((path / "bwlog").glob("*_bw.*.log"))
    if len(logs) != 1:
        raise EvidenceError("one per-job bandwidth log required")
    rows = bandwidth_rows(logs[0])
    if not rows or rows[-1][1] < 59 or rows[-1][1] > 65:
        raise EvidenceError("bandwidth coverage")
    values = formal_seconds(rows)
    mean = statistics.mean(values)
    completion_ns = int((path / "completion-ns.txt").read_text().strip())
    actual_start_ns = completion_ns - runtime_ms * 1_000_000
    formal_start_ns = actual_start_ns + 10_000_000_000
    formal_end_ns = actual_start_ns + 50_000_000_000
    metrics = metric_rows(path / "juicefs-metrics.tsv")
    get_bytes, _ = delta_near(family(metrics, "juicefs_object_request_data_bytes", 'method="GET"'), formal_start_ns, formal_end_ns)
    get_count, _ = delta_near(family(metrics, "juicefs_object_request_durations_histogram_seconds_count", 'method="GET"'), formal_start_ns, formal_end_ns)
    get_duration, _ = delta_near(family(metrics, "juicefs_object_request_durations_histogram_seconds_sum", 'method="GET"'), formal_start_ns, formal_end_ns)
    if min(get_bytes, get_count, get_duration) <= 0:
        raise EvidenceError("non-positive GET metrics")
    fuse_rows = family(metrics, "juicefs_fuse_ops_total", 'method="read"')
    if not fuse_rows:
        fuse_rows = family(metrics, "juicefs_fuse_read_size_bytes_count")
    fuse_count, _ = delta_near(fuse_rows, formal_start_ns, formal_end_ns)
    errors = family(metrics, "juicefs_object_request_errors")
    error_delta = delta_near(errors, formal_start_ns, formal_end_ns)[0] if errors else None
    client = sidecar(path / "client-sidecar.tsv", formal_start_ns, formal_end_ns)
    avg_get_size = get_bytes / get_count; avg_get_latency = get_duration / get_count
    return {
        "cell": path.name, "bs": c["bs"], "formal_window_s": [10, 50],
        "effective_bw_mib_s": mean, "median_mib_s": statistics.median(values),
        "cv_pct": statistics.pstdev(values) / mean * 100,
        "windows_mib_s": [statistics.mean(values[i:i + 10]) for i in range(0, 40, 10)],
        "fio_summary_mib_s": float((job.get("read") or {}).get("bw_bytes", 0)) / 2**20,
        "actual_start_ns": actual_start_ns, "completion_ns": completion_ns,
        "get_count_delta": get_count, "get_bytes_delta": get_bytes, "get_duration_s_delta": get_duration,
        "avg_get_size_bytes": avg_get_size, "avg_get_latency_ms": avg_get_latency * 1000,
        "get_inflight_little": mean * 2**20 * avg_get_latency / avg_get_size,
        "get_per_fio_io": get_count / float((job.get("read") or {}).get("total_ios", 1)),
        "fuse_read_count_delta": fuse_count, "object_errors_delta": error_delta,
        "client": client,
    }


def effect(left: dict, right: dict) -> float:
    return (right["effective_bw_mib_s"] / left["effective_bw_mib_s"] - 1.0) * 100.0


def classify(deltas: list[float]) -> str:
    if all(value >= 10.0 for value in deltas):
        return "L1_MATERIAL_SIGNAL"
    if all(abs(value) < 5.0 for value in deltas):
        return "NO_MATERIAL_SIGNAL"
    return "RESOLUTION_INSUFFICIENT"


def verdict(root: Path) -> dict:
    cells = {name: analyze_cell(root / "cells" / name) for name in CELLS}
    anchors = {name: effect(cells[a], cells[b]) for name, (a, b) in ANCHORS.items()}
    valid = (all(abs(value) <= 8.0 for value in anchors.values()) and
             all(item.get("object_errors_delta") in (0, 0.0) for item in cells.values()))
    factors = {}
    for name, pairs in FACTORS.items():
        values = [effect(cells[left], cells[right]) for left, right in pairs]
        factors[name] = {"pairs": [list(pair) for pair in pairs], "delta_pct": values,
                         "verdict": classify(values) if valid else "EVIDENCE_INVALID_ANCHOR_DRIFT"}
    target_arms = {
        "A": all(cells[name]["effective_bw_mib_s"] >= TARGET_MIB_S for name in ("A02", "A03")),
        "B": all(cells[name]["effective_bw_mib_s"] >= TARGET_MIB_S for name in ("B01", "B02")),
        "C": all(cells[name]["effective_bw_mib_s"] >= TARGET_MIB_S for name in ("C02", "C03")),
    }
    return {
        "evidence_valid": valid,
        "cells": cells,
        "anchor_drift_pct": anchors,
        "factors": factors,
        "target_mib_s": TARGET_MIB_S,
        "target_by_arm": target_arms,
        "read_target_observed_twice_l1": valid and any(target_arms.values()),
        "verdict": ("EVIDENCE_INVALID_ANCHOR_DRIFT" if not valid else
                    "READ_TARGET_OBSERVED_TWICE_L1" if any(target_arms.values()) else
                    "READ_TARGET_NOT_MET"),
    }


def write_fixture(path: Path, cell_name: str, bs: str, mib_s: float) -> None:
    (path / "bwlog").mkdir(parents=True, exist_ok=True)
    filename = "/tmp/testfile"
    (path / "cell-contract.tsv").write_text(
        f"cell\t{cell_name}\nbs\t{bs}\nengine\tpsync\nqd\t1\nruntime_s\t60\nfilename\t{filename}\n")
    job = {"error": 0, "job_runtime": 60000,
           "job options": {"rw": "read", "bs": bs, "size": "10G", "ioengine": "psync",
                           "iodepth": "1", "direct": "1", "numjobs": "1", "allow_file_create": "0",
                           "filename": filename},
           "read": {"io_bytes": 20 * 1024**3, "total_ios": 1000, "bw_bytes": mib_s * 2**20},
           "write": {"io_bytes": 0}}
    (path / "fio.json").write_text(json.dumps({"jobs": [job]})); (path / "fio.rc").write_text("0\n")
    (path / "completion-ns.txt").write_text("1060000000000\n")
    (path / "bwlog" / f"{cell_name}_bw.1.log").write_text(
        "".join(f"{(i + 1) * 1000},{mib_s * 1024}\n" for i in range(60)))
    metric_lines = ["epoch_ns\tmetric\tvalue"]
    sidecar_lines = ["epoch_ns\tpid\tutime_ticks\tstime_ticks\trss_pages\tthreads\trx_bytes\ttx_bytes"]
    for i in range(65):
        epoch = 1_000_000_000_000 + i * 1_000_000_000
        for family_name, value, labels in (
            ("juicefs_object_request_data_bytes", i * 1024**2, '{method="GET"}'),
            ("juicefs_object_request_durations_histogram_seconds_count", i * 10, '{method="GET"}'),
            ("juicefs_object_request_durations_histogram_seconds_sum", i * .01, '{method="GET"}'),
            ("juicefs_object_request_errors", 0, '{method="GET"}'),
            ("juicefs_fuse_ops_total", i * 20, '{method="read"}')):
            metric_lines.append(f"{epoch}\t{family_name}{labels}\t{value}")
        sidecar_lines.append(f"{epoch}\t1\t{i * 10}\t{i * 2}\t1\t2\t{i * 1000000}\t{i * 2000000}")
    (path / "juicefs-metrics.tsv").write_text("\n".join(metric_lines) + "\n")
    (path / "client-sidecar.tsv").write_text("\n".join(sidecar_lines) + "\n")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="t04tmp3f-") as tmp:
        root = Path(tmp); values = {name: 1000.0 for name in CELLS}
        for name in CELLS:
            write_fixture(root / "cells" / name, name, "256K" if name in ("A01", "C01", "C04", "A04") else "20M", values[name])
        result = verdict(root)
        assert result["evidence_valid"] and result["factors"]["RA32"]["verdict"] == "NO_MATERIAL_SIGNAL"
        bad = root / "cells" / "A01" / "fio.json"
        doc = json.loads(bad.read_text()); doc["jobs"][0]["error"] = 5; bad.write_text(json.dumps(doc))
        try:
            verdict(root)
        except EvidenceError:
            pass
        else:
            raise AssertionError("fio error fixture must fail")
        write_fixture(root / "cells" / "A01", "A01", "256K", 1000.0)
        metrics = root / "cells" / "A01" / "juicefs-metrics.tsv"
        saved = metrics.read_text(); metrics.write_text("epoch_ns\tmetric\tvalue\n")
        try:
            verdict(root)
        except EvidenceError:
            pass
        else:
            raise AssertionError("missing metrics fixture must fail")
        metrics.write_text(saved)
        next((root / "cells" / "A01" / "bwlog").glob("*_bw.*.log")).unlink()
        try:
            verdict(root)
        except EvidenceError:
            pass
        else:
            raise AssertionError("missing bwlog fixture must fail")
    print("T04TMP3F_ANALYZER_SELFTEST_PASS")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("cell", "verdict", "self-test"))
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    if args.mode == "self-test":
        self_test(); return
    if not args.path:
        parser.error("path required")
    result = analyze_cell(Path(args.path)) if args.mode == "cell" else verdict(Path(args.path))
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
