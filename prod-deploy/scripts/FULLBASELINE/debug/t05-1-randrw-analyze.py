#!/usr/bin/env python3
"""Offline-only analyzer for the 05-1 randrw block-size screen.

The executor is expected to provide raw fio JSON, the complete per-job
randrw bandwidth logs, and an end timestamp.  This module never contacts a
host or changes an environment.  It deliberately reports measurements only;
effect sizes and the L1 decision remain the second party's responsibility.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import tempfile
from pathlib import Path

JOBS = 128
RUNTIME_S = 180
FORMAL_START = 15.0
FORMAL_STOP = 175.0
WINDOWS = (("W1", 15.0, 55.0), ("W2", 55.0, 95.0),
           ("W3", 95.0, 135.0), ("W4", 135.0, 175.0))
BS_VALUES = ("4K", "16K", "64K", "256K", "1M", "4M")
PHASE_A_ORDER = ("256K-A", "4K", "16K", "64K", "1M", "4M",
                 "4M", "1M", "64K", "16K", "4K", "256K-B")


class EvidenceError(RuntimeError):
    """Raised when a raw evidence contract is not satisfied."""


def _finite(value: object) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise EvidenceError(f"non-numeric value: {value!r}") from exc
    if not math.isfinite(result):
        raise EvidenceError(f"non-finite value: {value!r}")
    return result


def _cell_path(root: Path, name: str) -> Path:
    candidates = (root / "cells" / name,
                  root / "cells" / f"{name}-randrw",
                  root / name)
    for candidate in candidates:
        if candidate.is_dir() and not candidate.is_symlink():
            return candidate
    raise EvidenceError(f"cell not found: {name}")


def _fio_json(cell: Path) -> dict:
    candidates = (cell / "fio.json", cell / "formal" / "fio.json")
    path = next((item for item in candidates if item.is_file()), None)
    if path is None:
        raise EvidenceError(f"{cell.name}: fio.json missing")
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"{cell.name}: invalid fio JSON") from exc
    jobs = data.get("jobs")
    # fio emits one aggregated job object when group_reporting=1 even though
    # the executor started 128 jobs.  The independent job-count proof is the
    # exact 1..128 per-job bw-log set validated below.
    if not isinstance(jobs, list) or len(jobs) not in (1, JOBS):
        raise EvidenceError(f"{cell.name}: expected one grouped or {JOBS} fio jobs")
    for job in jobs:
        if int(job.get("error", -1)) != 0:
            raise EvidenceError(f"{cell.name}: fio job error")
    return data


def _validate_job_contract(cell: Path) -> str:
    path = next((item for item in (cell / "fio.job", cell / "formal" / "fio.job")
                 if item.is_file()), None)
    if path is None:
        raise EvidenceError(f"{cell.name}: fio.job missing")
    values = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("[") or line.startswith("#"):
            continue
        if "=" not in line:
            raise EvidenceError(f"{cell.name}: invalid fio.job row: {line}")
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    expected = {
        "ioengine": "libaio", "iodepth": "128", "numjobs": "128",
        "rw": "randrw", "rwmixread": "50", "filesize": "1G",
        "size": "1G", "direct": "1", "fallocate": "none",
        "allow_file_create": "0", "openfiles": "128", "time_based": "1",
        "runtime": "180", "group_reporting": "1", "randrepeat": "1",
    }
    for key, expected_value in expected.items():
        if values.get(key) != expected_value:
            raise EvidenceError(f"{cell.name}: fio.job contract mismatch: {key}")
    if values.get("per_job_logs") not in ("0", "1"):
        raise EvidenceError(f"{cell.name}: fio.job contract mismatch: per_job_logs")
    if values.get("bs") not in BS_VALUES:
        raise EvidenceError(f"{cell.name}: unsupported bs in fio.job")
    if not values.get("filename_format", "").endswith("/test_dir/rw_test.$jobnum.0"):
        raise EvidenceError(f"{cell.name}: filename_format contract mismatch")
    if values.get("write_lat_log"):
        if values["per_job_logs"] != "0" or values.get("log_avg_msec") != "0":
            raise EvidenceError(f"{cell.name}: completion-log contract mismatch")
        if not values["write_lat_log"].endswith("/formal/bw/randrw"):
            raise EvidenceError(f"{cell.name}: write_lat_log contract mismatch")
        return "completion"
    if values.get("log_avg_msec") != "1000":
        raise EvidenceError(f"{cell.name}: bandwidth-log averaging mismatch")
    if not values.get("write_bw_log", "").endswith("/formal/bw/randrw"):
        raise EvidenceError(f"{cell.name}: write_bw_log contract mismatch")
    return "aggregate" if values["per_job_logs"] == "0" else "per-job"


def _runtime_and_start(cell: Path, data: dict) -> tuple[float, int]:
    runtimes = []
    for job in data["jobs"]:
        for direction in ("read", "write"):
            runtime = _finite(job.get(direction, {}).get("runtime", 0))
            if runtime > 0:
                runtimes.append(runtime)
    if not runtimes:
        raise EvidenceError(f"{cell.name}: directional runtime missing")
    runtime_ms = max(runtimes)
    if runtime_ms > 320000:
        raise EvidenceError(f"{cell.name}: directional runtime exceeds contract: {runtime_ms}")
    end_path = next((item for item in (cell / "fio-end-epoch-ns.txt",
                                       cell / "fio-end-ns.txt",
                                       cell / "formal" / "fio-end-epoch-ns.txt")
                     if item.is_file()), None)
    if end_path is None:
        raise EvidenceError(f"{cell.name}: fio end timestamp missing")
    try:
        end_ns = int(end_path.read_text().strip())
    except ValueError as exc:
        raise EvidenceError(f"{cell.name}: invalid fio end timestamp") from exc
    # `group_reporting=1` may report a runtime longer than 180s while slow
    # jobs drain, whereas 128-job JSON may retain only shorter per-job
    # runtimes.  Use at least the frozen 180s contract and extend to the
    # observed grouped runtime when it is longer.
    effective_runtime_s = max(float(RUNTIME_S), runtime_ms / 1000.0)
    start_ns = end_ns - int(effective_runtime_s * 1_000_000_000)
    if start_ns <= 0:
        raise EvidenceError(f"{cell.name}: derived I/O start is invalid")
    stated_path = next((item for item in (cell / "fio-start-ns.txt",
                                          cell / "fio-start-epoch-ns.txt",
                                          cell / "formal" / "fio-start-ns.txt")
                        if item.is_file()), None)
    stated_delta = None
    if stated_path is not None:
        try:
            stated = int(stated_path.read_text().strip())
        except ValueError as exc:
            raise EvidenceError(f"{cell.name}: invalid fio start timestamp") from exc
        stated_delta = (start_ns - stated) / 1e9
        if stated > start_ns + 2_000_000_000:
            raise EvidenceError(f"{cell.name}: stated start is after derived I/O start")
    return effective_runtime_s, start_ns


def _log_dir(cell: Path) -> Path:
    for candidate in (cell / "bw", cell / "formal" / "bw",
                      cell / "bwlog", cell / "formal" / "bwlog"):
        if candidate.is_dir():
            return candidate
    raise EvidenceError(f"{cell.name}: bandwidth-log directory missing")


def _parse_logs(cell: Path, runtime_s: float,
                log_mode: str) -> tuple[dict[int, dict[int, float]], dict[int, float]]:
    """Return direction -> natural-second -> summed MiB/s.

    fio's first column is relative milliseconds and its second column is
    KiB/s.  With the frozen ``log_avg_msec=1000`` contract, each row is one
    one-second sampling window ending at its timestamp.  fio omits idle
    windows; those gaps (including a job's tail) must contribute zero rather
    than stretching the next non-zero value backwards across the gap.
    """
    log_dir = _log_dir(cell)
    if log_mode == "completion":
        completion = log_dir / "randrw_clat.log"
        if not completion.is_file() or completion.is_symlink():
            raise EvidenceError(f"{cell.name}: aggregate completion log missing")
        paths = [completion]
    elif log_mode == "per-job":
        paths = sorted(log_dir.glob("randrw_bw.*.log"))
        if len(paths) != JOBS:
            raise EvidenceError(f"{cell.name}: expected {JOBS} bandwidth logs, got {len(paths)}")
    else:
        aggregate = log_dir / "randrw_bw.log"
        if not aggregate.is_file() or aggregate.is_symlink():
            raise EvidenceError(f"{cell.name}: aggregate bandwidth log missing")
        if list(log_dir.glob("randrw_bw.*.log")):
            raise EvidenceError(f"{cell.name}: mixed aggregate and per-job logs")
        paths = [aggregate]
    bins: dict[int, dict[int, float]] = {
        0: {second: 0.0 for second in range(math.ceil(runtime_s))},
        1: {second: 0.0 for second in range(math.ceil(runtime_s))},
    }
    covered_seconds = {0: 0.0, 1: 0.0}
    ids = []
    global_seen = set()
    for path in paths:
        if log_mode == "completion":
            with path.open(newline="") as stream:
                for row in csv.reader(stream):
                    if not row or not any(field.strip() for field in row):
                        continue
                    if len(row) < 4:
                        raise EvidenceError(f"{cell.name}: short completion row")
                    try:
                        end = float(row[0]) / 1000.0
                        direction = int(row[2])
                        io_bytes = int(row[3])
                    except ValueError as exc:
                        raise EvidenceError(f"{cell.name}: invalid completion row") from exc
                    if direction not in (0, 1) or end < 0 or end > runtime_s + 1.0 or io_bytes <= 0:
                        raise EvidenceError(f"{cell.name}: invalid completion timestamp/direction/size")
                    second = min(math.floor(end), math.ceil(runtime_s) - 1)
                    bins[direction][second] += io_bytes / 1048576.0
                    global_seen.add(direction)
            continue
        if log_mode == "per-job":
            try:
                job_id = int(path.name.removeprefix("randrw_bw.").removesuffix(".log"))
            except ValueError as exc:
                raise EvidenceError(f"{cell.name}: unexpected log {path.name}") from exc
            if not 1 <= job_id <= JOBS:
                raise EvidenceError(f"{cell.name}: invalid job id {job_id}")
            ids.append(job_id)
        previous_end = {0: None, 1: None}
        seen = set()
        with path.open(newline="") as stream:
            for row in csv.reader(stream):
                if not row or not any(field.strip() for field in row):
                    continue
                if len(row) < 3:
                    raise EvidenceError(f"{cell.name}: short row in {path.name}")
                try:
                    end = float(row[0]) / 1000.0
                    value = float(row[1]) / 1024.0
                    direction = int(row[2])
                except ValueError as exc:
                    raise EvidenceError(f"{cell.name}: invalid row in {path.name}") from exc
                if direction not in (0, 1) or end <= 0 or end > runtime_s + 1.0:
                    raise EvidenceError(f"{cell.name}: invalid timestamp/direction in {path.name}")
                if (log_mode == "per-job" and previous_end[direction] is not None
                        and end - previous_end[direction] < 0.90):
                    raise EvidenceError(f"{cell.name}: overlapping 1s samples in {path.name}")
                previous_end[direction] = end
                begin = max(0.0, end - 1.0)
                seen.add(direction)
                global_seen.add(direction)
                for second in range(math.floor(begin), math.ceil(end)):
                    overlap = min(end, runtime_s, second + 1.0) - max(begin, float(second))
                    if overlap <= 0:
                        continue
                    bins[direction][second] += value * overlap
                    covered_seconds[direction] += overlap
        if log_mode == "per-job" and seen != {0, 1}:
            raise EvidenceError(f"{cell.name}: {path.name} lacks READ or WRITE rows")
    if log_mode == "per-job" and sorted(ids) != list(range(1, JOBS + 1)):
        raise EvidenceError(f"{cell.name}: job IDs are not exactly 1..128")
    if global_seen != {0, 1}:
        raise EvidenceError(f"{cell.name}: aggregate log lacks READ or WRITE rows")
    if log_mode == "completion":
        zero_seconds = {direction: float(sum(value == 0 for value in bins[direction].values()))
                        for direction in (0, 1)}
    else:
        zero_seconds = {direction: JOBS * runtime_s - covered_seconds[direction]
                        for direction in (0, 1)}
    if any(value < -1e-6 for value in zero_seconds.values()):
        raise EvidenceError(f"{cell.name}: sampled duration exceeds runtime")
    return bins, zero_seconds


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    pos = (len(ordered) - 1) * fraction
    lo, hi = math.floor(pos), math.ceil(pos)
    return ordered[lo] if lo == hi else ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def _window_stats(series: dict[int, float], start: float = FORMAL_START,
                  stop: float = FORMAL_STOP, origin: float = FORMAL_START) -> dict:
    seconds = [second for second in range(math.ceil(start), math.ceil(stop))
               if second in series]
    if len(seconds) < 150:
        raise EvidenceError(f"formal coverage too sparse: {len(seconds)}/160")
    values = [series[second] for second in seconds]
    windows = {}
    window_defs = tuple((f"W{index + 1}", origin + index * 40.0,
                         origin + (index + 1) * 40.0)
                        for index in range(4))
    for name, left, right in window_defs:
        child = [series[second] for second in seconds if left <= second < right]
        if len(child) < 36:
            raise EvidenceError(f"{name} coverage too sparse: {len(child)}/40")
        mean = statistics.mean(child)
        windows[name] = {"n": len(child), "mean_MiB_s": mean,
                         "median_MiB_s": statistics.median(child),
                         "P10_MiB_s": _percentile(child, .10),
                         "P90_MiB_s": _percentile(child, .90),
                         "CV": statistics.pstdev(child) / mean if mean else math.inf}
    mean = statistics.mean(values)
    return {"mean_MiB_s": mean, "median_MiB_s": statistics.median(values),
            "P10_MiB_s": _percentile(values, .10),
            "P90_MiB_s": _percentile(values, .90),
            "CV": statistics.pstdev(values) / mean if mean else math.inf,
            "formal_seconds": len(seconds), "missing_seconds":
            [second for second in range(15, 175) if second not in series],
            "windows": windows,
            "W4_W1": windows["W4"]["mean_MiB_s"] / windows["W1"]["mean_MiB_s"]
            if windows["W1"]["mean_MiB_s"] else math.inf,
            "series": {str(second): series[second] for second in seconds}}


def analyze_cell(root: Path, name: str) -> dict:
    cell = _cell_path(Path(root), name)
    log_mode = _validate_job_contract(cell)
    data = _fio_json(cell)
    runtime_s, start_ns = _runtime_and_start(cell, data)
    jobs = data["jobs"]
    byte_stats = {}
    for direction, label in (("read", "read"), ("write", "write")):
        total = sum(int(job.get(direction, {}).get("io_bytes", 0)) for job in jobs)
        if total <= 0:
            raise EvidenceError(f"{cell.name}: {label} io_bytes missing")
        byte_stats[label] = {"io_bytes": total,
                             "summary_MiB_s": total / runtime_s / 1048576.0}
    logs, zero_seconds = _parse_logs(cell, runtime_s, log_mode)
    bandwidth = {label: _window_stats(logs[direction])
                 for direction, label in ((0, "read"), (1, "write"))}
    for direction, label in ((0, "read"), (1, "write")):
        summary = byte_stats[label]["summary_MiB_s"]
        formal = bandwidth[label]["mean_MiB_s"]
        bandwidth[label]["formal_vs_fio_summary_delta_pct"] = (
            (formal / summary - 1.0) * 100.0 if summary else math.nan)
        integrated = sum(logs[direction].values())
        expected = byte_stats[label]["io_bytes"] / 1048576.0
        delta = (integrated / expected - 1.0) * 100.0 if expected else math.nan
        bandwidth[label]["full_log_integrated_MiB"] = integrated
        bandwidth[label]["full_log_vs_fio_io_bytes_delta_pct"] = delta
        if not math.isfinite(delta) or abs(delta) > 12.0:
            raise EvidenceError(f"{cell.name}: {label} bw-log/io_bytes mismatch: {delta:.2f}%")
    return {"cell": name, "runtime_s": runtime_s,
            "actual_io_start_epoch_ns": start_ns,
            "read_write_start_rule": "fio_end_epoch_ns - max directional runtime_ms",
            "fio_summary": byte_stats,
            "formal": bandwidth,
            "zero_fill_seconds": {"read": zero_seconds[0], "write": zero_seconds[1]},
            "bw_log_mode": log_mode,
            "evidence_status": "RAW_MEASUREMENTS_ONLY"}


def analyze(root: Path, cells: list[str], output: Path) -> dict:
    rows = []
    errors = []
    for name in cells:
        try:
            rows.append(analyze_cell(root, name))
        except EvidenceError as exc:
            errors.append(str(exc))
    result = {"schema": 1, "scope": "offline_descriptive_only",
              "formal_window": "[15,175)", "cells": rows,
              "errors": errors,
              "RUN_VALIDITY_STATE": "EVIDENCE_INVALID" if errors else "ACTIVE",
              "decision": "REQUIRES_SECOND_PARTY_REVIEW"}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def _make_fixture(root: Path, read: float = 100.0, write: float = 80.0,
                  shifted: bool = False, jobs: int = JOBS,
                  grouped_json: bool = False, tail_s: int = RUNTIME_S,
                  aggregate: bool = False, completion: bool = False) -> None:
    cell = root / "cells" / "fixture"
    cell.mkdir(parents=True)
    bw = cell / "bw"
    bw.mkdir()
    shifted_seconds = min(58, tail_s) if shifted else 0
    read_bytes = int((read * tail_s + 100.0 * shifted_seconds) * 1048576)
    write_bytes = int((write * tail_s + 60.0 * shifted_seconds) * 1048576)
    payload = [{"error": 0, "read": {"runtime": RUNTIME_S * 1000, "io_bytes": read_bytes},
                "write": {"runtime": RUNTIME_S * 1000, "io_bytes": write_bytes}}
               for _ in range(jobs)]
    if grouped_json:
        payload = [{"error": 0, "read": {"runtime": RUNTIME_S * 1000,
                                           "io_bytes": read_bytes * jobs},
                    "write": {"runtime": RUNTIME_S * 1000,
                               "io_bytes": write_bytes * jobs}}]
    (cell / "fio.json").write_text(json.dumps({"jobs": payload[:1] if grouped_json else payload}))
    log_option = ("write_lat_log=/fixture/formal/bw/randrw\nlog_avg_msec=0"
                  if completion else
                  "write_bw_log=/fixture/formal/bw/randrw\nlog_avg_msec=1000")
    (cell / "fio.job").write_text("""[global]
ioengine=libaio
iodepth=128
numjobs=128
rw=randrw
rwmixread=50
bs=256K
filesize=1G
size=1G
direct=1
fallocate=none
allow_file_create=0
openfiles=128
time_based=1
runtime=180
group_reporting=1
randrepeat=1
%s
per_job_logs=%s
filename_format=/mnt/fixture/test_dir/rw_test.$jobnum.0
[job]
""" % (log_option, "0" if aggregate or completion else "1"))
    (cell / "fio-end-epoch-ns.txt").write_text(str(181_000_000_000))
    (cell / "fio-start-epoch-ns.txt").write_text(str(1_000_000_000))
    if completion:
        with (bw / "randrw_clat.log").open("w") as stream:
            for job in range(1, jobs + 1):
                for second in range(1, tail_s + 1):
                    base_read = read + (100.0 if shifted and second <= 58 else 0.0)
                    base_write = write + (60.0 if shifted and second <= 58 else 0.0)
                    stream.write(f"{second * 1000},{job},0,{int(base_read * 1048576)},0\n")
                    stream.write(f"{second * 1000},{job},1,{int(base_write * 1048576)},0\n")
        return
    aggregate_stream = (bw / "randrw_bw.log").open("w") if aggregate else None
    try:
      for job in range(1, jobs + 1):
        stream = aggregate_stream or (bw / f"randrw_bw.{job}.log").open("w")
        try:
            for second in range(1, tail_s + 1):
                # One irregular first interval proves overlap weighting; the
                # optional shift produces a visible four-window difference.
                end = second * 1000 + (1 if second == 1 else 0)
                base_read = read + (100.0 if shifted and second <= 58 else 0.0)
                base_write = write + (60.0 if shifted and second <= 58 else 0.0)
                stream.write(f"{end},{base_read * 1024},0,0\n")
                stream.write(f"{end},{base_write * 1024},1,0\n")
        finally:
            if aggregate_stream is None:
                stream.close()
    finally:
        if aggregate_stream is not None:
            aggregate_stream.close()


def self_test() -> dict:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _make_fixture(root)
        result = analyze_cell(root, "fixture")
        assert result["formal"]["read"]["formal_seconds"] == 160
        assert abs(result["formal"]["read"]["mean_MiB_s"] - 12800.0) < 1e-9
        assert abs(result["formal"]["write"]["mean_MiB_s"] - 10240.0) < 1e-9
        # ±1s sensitivity is small for a flat fixture; a +58s shift changes
        # W1-W4 and therefore catches analyzers using line number as seconds.
        flat = result["formal"]["read"]["windows"]
        shifted_root = root / "shifted"
        _make_fixture(shifted_root, shifted=True)
        shifted = analyze_cell(shifted_root, "fixture")["formal"]["read"]["windows"]
        assert shifted["W1"]["mean_MiB_s"] != shifted["W4"]["mean_MiB_s"]
        assert flat["W1"]["mean_MiB_s"] != shifted["W1"]["mean_MiB_s"]
        grouped_root = root / "grouped"
        _make_fixture(grouped_root, grouped_json=True)
        grouped = analyze_cell(grouped_root, "fixture")
        assert grouped["formal"]["read"]["formal_seconds"] == 160
        aggregate_root = root / "aggregate"
        _make_fixture(aggregate_root, grouped_json=True, aggregate=True)
        aggregate = analyze_cell(aggregate_root, "fixture")
        assert aggregate["bw_log_mode"] == "aggregate"
        assert abs(aggregate["formal"]["read"]["mean_MiB_s"] - 12800.0) < 1e-9
        completion_root = root / "completion"
        _make_fixture(completion_root, grouped_json=True, completion=True)
        completion = analyze_cell(completion_root, "fixture")
        assert completion["bw_log_mode"] == "completion"
        assert abs(completion["formal"]["read"]["mean_MiB_s"] - 12800.0) < 1e-9
        tail_root = root / "tail"
        _make_fixture(tail_root, tail_s=60)
        tail = analyze_cell(tail_root, "fixture")
        assert tail["zero_fill_seconds"]["read"] > 100.0
        assert tail["formal"]["read"]["formal_seconds"] == 160
        # The summary covers the whole 180s runtime, while formal starts at
        # t=15; their difference is expected and must be reported, not used
        # to reject a valid early-completion trace.
        assert tail["formal"]["read"]["formal_vs_fio_summary_delta_pct"] != 0.0
        # Explicit timing sensitivity fixture: ±1s is below 1%, while a
        # +58s origin shift moves W1-W4 across a startup transient.
        flat_series = {second: 100.0 for second in range(300)}
        centered = _window_stats(flat_series)
        minus = _window_stats(flat_series, start=14, stop=174, origin=14)
        transient_series = {second: (200.0 if second < 58 else 100.0)
                            for second in range(300)}
        transient = _window_stats(transient_series)
        plus = _window_stats(transient_series, start=73, stop=233, origin=73)
        for name in ("W1", "W2", "W3", "W4"):
            assert abs(minus["windows"][name]["mean_MiB_s"] /
                       centered["windows"][name]["mean_MiB_s"] - 1.0) < .01
        assert any(abs(plus["windows"][name]["mean_MiB_s"] -
                       transient["windows"][name]["mean_MiB_s"]) > 1.0
                   for name in ("W1", "W2", "W3", "W4"))
        bad = root / "bad"
        _make_fixture(bad, jobs=127)
        try:
            analyze_cell(bad, "fixture")
        except EvidenceError:
            pass
        else:
            raise AssertionError("missing-job fixture was accepted")
        bad_direction = root / "bad-direction"
        _make_fixture(bad_direction)
        bad_log = bad_direction / "cells" / "fixture" / "bw" / "randrw_bw.1.log"
        rows = bad_log.read_text().splitlines()
        bad_log.write_text(rows[0].replace(",0,", ",7,") + "\n" + "\n".join(rows[1:]) + "\n")
        try:
            analyze_cell(bad_direction, "fixture")
        except EvidenceError:
            pass
        else:
            raise AssertionError("invalid-direction fixture was accepted")
    return {"status": "PASS", "jobs": JOBS,
            "directions": ["read", "write"],
            "checks": ["overlap_weighting", "formal_window", "four_windows",
                       "actual_io_start", "gap_and_tail_zero_fill", "summary_difference_guard",
                       "missing_job_rejection", "aggregate_log", "completion_log"]}


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    cell = sub.add_parser("cell")
    cell.add_argument("--root", required=True, type=Path)
    cell.add_argument("--name", required=True)
    cell.add_argument("--output", required=True, type=Path)
    batch = sub.add_parser("batch")
    batch.add_argument("--root", required=True, type=Path)
    batch.add_argument("--cells", nargs="+", required=True)
    batch.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "self-test":
        print(json.dumps(self_test(), sort_keys=True))
        return
    if args.command == "cell":
        result = analyze_cell(args.root, args.name)
    else:
        result = analyze(args.root, args.cells, args.output)
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
