#!/usr/bin/env python3
"""Offline 04-tmp3g evidence validator and deterministic analyzer."""
# DEFECT-D01 DEFECT-D02 DEFECT-D03 DEFECT-D12 DEFECT-D17 DEFECT-D19
# DEFECT-D21 DEFECT-D22 DEFECT-D23 DEFECT-D29
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
import tempfile
from pathlib import Path

CELLS = (("S01", "psync", 1, 120), ("C08A", "libaio", 8, 120),
         ("C01", "libaio", 1, 60), ("C02", "libaio", 2, 60),
         ("C04", "libaio", 4, 60), ("C08B", "libaio", 8, 120),
         ("S02", "psync", 1, 120))
TARGET_MIB = 3051.76


class EvidenceError(RuntimeError):
    pass


def fio_doc(path: Path) -> dict:
    try:
        doc = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"invalid fio JSON: {path}") from exc
    jobs = doc.get("jobs")
    if not isinstance(jobs, list) or len(jobs) != 1 or int(jobs[0].get("error", -1)) != 0:
        raise EvidenceError("fio job count/error mismatch")
    return doc


def merged_options(doc: dict) -> dict:
    opts = dict(doc.get("global options") or doc.get("global_options") or {})
    opts.update(doc["jobs"][0].get("job options") or doc["jobs"][0].get("job_options") or {})
    return opts


def validate_contract(doc: dict, expected_file: str, engine: str, qd: int, runtime: int) -> int:
    job = doc["jobs"][0]; opts = merged_options(doc)
    required = {"rw": "write", "bs": "16M", "size": "10G", "direct": "1",
                "numjobs": "1", "ioengine": engine, "iodepth": str(qd),
                "runtime": str(runtime), "allow_file_create": "0"}
    for key, expected in required.items():
        if str(opts.get(key, "")) != expected:
            raise EvidenceError(f"fio option mismatch {key}={opts.get(key)!r}, expected={expected}")
    if str(opts.get("filename") or job.get("filename")) != expected_file:
        raise EvidenceError("fio filename mismatch")
    if "time_based" in opts and str(opts["time_based"]) not in ("", "1", "True", "true"):
        raise EvidenceError("time_based mismatch")
    write_bytes = int((job.get("write") or {}).get("io_bytes", 0)); read_bytes = int((job.get("read") or {}).get("io_bytes", 0))
    if write_bytes <= 10 * 1024**3 or read_bytes != 0:
        raise EvidenceError("fio direction/time_based byte proof failed")
    run_ms = int(job.get("job_runtime", 0))
    if not runtime * 1000 - 2000 <= run_ms <= runtime * 1000 + 5000:
        raise EvidenceError(f"runtime mismatch {run_ms}")
    return run_ms


def read_log(path: Path) -> list[tuple[float, float, float]]:
    rows = []; previous = 0.0
    for no, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip(): continue
        fields = line.split(",")
        if len(fields) < 2: raise EvidenceError(f"short bw row {path}:{no}")
        end = float(fields[0]) / 1000.0; mib = float(fields[1]) / 1024.0
        if end <= previous or mib < 0 or not math.isfinite(end + mib): raise EvidenceError(f"invalid bw row {path}:{no}")
        rows.append((previous, end, mib)); previous = end
    return rows


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values); pos = (len(ordered) - 1) * fraction; low, high = math.floor(pos), math.ceil(pos)
    return ordered[low] if low == high else ordered[low] + (ordered[high] - ordered[low]) * (pos - low)


def cell_analysis(cell: Path, expected_file: str, engine: str, qd: int, runtime: int) -> dict:
    doc = fio_doc(cell / "fio.txt"); run_ms = validate_contract(doc, expected_file, engine, qd, runtime)
    logs = sorted((cell / "bwlog").glob("*_bw.*.log"))
    if len(logs) != 1: raise EvidenceError(f"expected one per-job log, got {len(logs)}")
    sec = {}; rows = read_log(logs[0])
    if not rows or rows[-1][1] < runtime - 1 or rows[-1][1] > runtime + 5: raise EvidenceError("bw log runtime coverage mismatch")
    for begin, end, mib in rows:
        for second in range(math.floor(begin), math.ceil(end)):
            overlap = min(end, second + 1) - max(begin, float(second))
            if overlap > 0:
                value, weight = sec.get(second, (0.0, 0.0)); sec[second] = (value + mib * overlap, weight + overlap)
    start, finish = (10, 110) if runtime == 120 else (10, 50)
    values = [sec[second][0] / sec[second][1] for second in range(start, finish) if second in sec]
    if len(values) != finish - start: raise EvidenceError("formal window coverage mismatch")
    width = len(values) // 4; windows = [statistics.mean(values[i * width:(i + 1) * width]) for i in range(4)]
    write = doc["jobs"][0].get("write") or {}
    summary = float(write.get("bw_bytes", 0)) / 1024**2 if write.get("bw_bytes") is not None else float(write.get("bw", 0)) / 1024.0
    end_ns = int((cell / "fio-end-ns.txt").read_text().strip()); registered_ns = int((cell / "fio-registered-start-ns.txt").read_text().strip())
    actual_start_ns = end_ns - run_ms * 1_000_000; mean = statistics.mean(values)
    clat = write.get("clat_ns") or {}
    pct = clat.get("percentile") or {}
    p99 = pct.get("99.000000", pct.get("99.0", pct.get("99", 0)))
    return {"engine": engine, "qd": qd, "runtime_s": runtime, "runtime_ms": run_ms,
            "registered_to_actual_start_s": (actual_start_ns - registered_ns) / 1e9,
            "summary_MiBs": summary, "formal_mean_MiBs": mean, "formal_median_MiBs": statistics.median(values),
            "formal_cv_pct": statistics.pstdev(values) / mean * 100, "formal_p10_MiBs": percentile(values, .10),
            "formal_p90_MiBs": percentile(values, .90), "windows_MiBs": windows,
            "w4_w1": windows[-1] / windows[0] if windows[0] else None,
            "clat_mean_ns": float(clat.get("mean", 0)), "clat_p99_ns": float(p99)}


def validate_supporting_evidence(root: Path, cell: str) -> None:
    path = root / "cells" / cell
    for name in ("metrics-pre.txt", "metrics-post.txt", "host-pre.tsv", "host-post.tsv"):
        if not (path / name).is_file() or (path / name).stat().st_size == 0:
            raise EvidenceError(f"supporting evidence missing: {cell}/{name}")
    health = root / f"health-{cell}-post" / "PASS"
    if not health.is_file():
        raise EvidenceError(f"post-cell health missing: {cell}")
    drain = path / "upload-drain.tsv"
    rows = list(drain.read_text().splitlines()) if drain.is_file() else []
    if len(rows) < 3 or any(row.split("\t")[-1] != "0" for row in rows[-2:]):
        raise EvidenceError(f"upload drain not strictly closed: {cell}")
    if (path / "fio.rc").read_text().strip() != "0":
        raise EvidenceError(f"fio rc nonzero: {cell}")
    expected_async = "on" if cell.startswith("C") else "off"
    mode_path = path / "mount-mode-ref.tsv"
    if not mode_path.is_file():
        raise EvidenceError(f"mount mode evidence missing: {cell}")
    mode = dict(line.split("\t", 1) for line in mode_path.read_text().splitlines() if "\t" in line)
    if mode.get("async_dio") != expected_async or not mode.get("worker_pid", "").isdigit() or not mode.get("worker_starttime", "").isdigit():
        raise EvidenceError(f"mount mode/PID mismatch: {cell}")

    def asset(name: str) -> dict[str, str]:
        asset_path = path / name
        if not asset_path.is_file():
            raise EvidenceError(f"asset evidence missing: {cell}/{name}")
        values = list(csv.DictReader(asset_path.open(), delimiter="\t"))
        if len(values) != 1:
            raise EvidenceError(f"asset evidence row mismatch: {cell}/{name}")
        return values[0]

    pre, post, remount = asset("assets-pre.tsv"), asset("assets-post.tsv"), asset("assets-remount.tsv")
    run_id = root.name.removeprefix("opencode-04tmp3g-")
    expected_tail = f"/test_dir/04tmp3g-{run_id}/{cell}.bin"
    if any(not row["path"].endswith(expected_tail) for row in (pre, post, remount)):
        raise EvidenceError(f"asset relative path mismatch: {cell}")
    if pre["inode"] != post["inode"] or pre["bytes"] != "10737418240":
        raise EvidenceError(f"pre/post asset identity mismatch: {cell}")
    for key in ("inode", "bytes", "head_sha256", "tail_sha256"):
        if post[key] != remount[key]:
            raise EvidenceError(f"post/remount asset mismatch: {cell}/{key}")


def drift(a: float, b: float) -> float:
    return abs(b / a - 1.0) * 100.0


def run_analysis(root: Path) -> dict:
    results = {}; run_id = root.name.removeprefix("opencode-04tmp3g-")
    for cell, engine, qd, runtime in CELLS:
        path = root / "cells" / cell
        if not (path / "PASS").is_file() or not (path / "assets-remount.tsv").is_file(): raise EvidenceError(f"cell/remount evidence missing: {cell}")
        validate_supporting_evidence(root, cell)
        tag = "C" if cell.startswith("C") else ("SYNC1" if cell == "S01" else "SYNC2")
        if not (root / "cells" / tag / "mount-log-gate.PASS").is_file():
            raise EvidenceError(f"mount log gate missing: {tag}")
        expected = f"/tmp/jfs-04tmp3g-{run_id}-{tag}/test_dir/04tmp3g-{run_id}/{cell}.bin"
        results[cell] = cell_analysis(path, expected, engine, qd, runtime)
    s_drift = drift(results["S01"]["formal_mean_MiBs"], results["S02"]["formal_mean_MiBs"])
    c_drift = drift(results["C08A"]["formal_mean_MiBs"], results["C08B"]["formal_mean_MiBs"])
    if s_drift > 8 or c_drift > 8: verdict = "EVIDENCE_INVALID"
    else:
        passed = all(results[cell][key] >= TARGET_MIB for cell in ("C08A", "C08B") for key in ("summary_MiBs", "formal_mean_MiBs"))
        verdict = "WRITE_ASYNC_TARGET_CONFIRMED" if passed else "WRITE_ASYNC_TARGET_NOT_MET"
    return {"validity": "VALID" if verdict != "EVIDENCE_INVALID" else "EVIDENCE_INVALID", "verdict": verdict,
            "target_MiBs": TARGET_MIB, "sync_anchor_drift_pct": s_drift, "qd8_drift_pct": c_drift, "cells": results}


def self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="t04tmp3g-fixture-") as name:
        cell = Path(name) / "cell"; (cell / "bwlog").mkdir(parents=True); expected = "/tmp/test.bin"
        doc = {"jobs": [{"error": 0, "job_runtime": 120000, "job options": {"filename": expected, "rw": "write", "bs": "16M", "size": "10G", "direct": "1", "numjobs": "1", "ioengine": "libaio", "iodepth": "8", "runtime": "120", "allow_file_create": "0", "time_based": ""}, "write": {"io_bytes": 20 * 1024**3, "bw_bytes": 3200 * 1024**2}, "read": {"io_bytes": 0}}]}
        (cell / "fio.txt").write_text(json.dumps(doc)); (cell / "fio-end-ns.txt").write_text("220000000000\n"); (cell / "fio-registered-start-ns.txt").write_text("99900000000\n")
        (cell / "bwlog" / "x_bw.1.log").write_text("".join(f"{(i+1)*1000},3276800\n" for i in range(120)))
        got = cell_analysis(cell, expected, "libaio", 8, 120)
        if round(got["formal_mean_MiBs"], 3) != 3200 or len(got["windows_MiBs"]) != 4: raise AssertionError("formal window fixture failed")
        try: cell_analysis(cell, expected, "psync", 1, 120)
        except EvidenceError: pass
        else: raise AssertionError("contract-negative fixture did not fail")
    print("T04TMP3G_ANALYZER_SELFTEST_PASS"); return 0


def main() -> int:
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="command", required=True); sub.add_parser("self-test")
    cell = sub.add_parser("cell"); cell.add_argument("root"); cell.add_argument("--expected-file", required=True); cell.add_argument("--engine", choices=("psync", "libaio"), required=True); cell.add_argument("--qd", type=int, required=True); cell.add_argument("--runtime", type=int, choices=(60, 120), required=True)
    run = sub.add_parser("run"); run.add_argument("root"); args = parser.parse_args()
    if args.command == "self-test": return self_test()
    if args.command == "cell": print(json.dumps(cell_analysis(Path(args.root), args.expected_file, args.engine, args.qd, args.runtime), sort_keys=True)); return 0
    print(json.dumps(run_analysis(Path(args.root)), indent=2, sort_keys=True)); return 0


if __name__ == "__main__":
    try: raise SystemExit(main())
    except EvidenceError as exc:
        print(f"T04TMP3G_ANALYZER_FAIL\t{exc}", file=sys.stderr); raise SystemExit(42)
