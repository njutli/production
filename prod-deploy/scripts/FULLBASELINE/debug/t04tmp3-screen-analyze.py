#!/usr/bin/env python3
"""Offline 04-tmp3 L1 evidence checker.

It validates one captured cell and computes only a reproducible screen value.
It does not decide an L2 effect and has no network or environment access.
"""
# DEFECT-D01 DEFECT-D02 DEFECT-D03 DEFECT-D12 DEFECT-D17 DEFECT-D19
# DEFECT-D21 DEFECT-D22 DEFECT-D23 DEFECT-D29
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import tempfile
from pathlib import Path

EXPECTED = {"seq_read": (60, 20), "seq_write": (120, 16)}
WINDOWS = {"seq_read": (10, 50, 10), "seq_write": (10, 110, 25)}


class EvidenceError(RuntimeError):
    pass


def runtime(text: str, expected: int) -> int:
    m = re.search(r"run=(\d+)msec", text)
    if m:
        value = int(m.group(1))
    else:
        # The frozen command contract uses json+.  fio JSON stores the
        # timed-I/O duration per job as job_runtime (milliseconds); accept
        # exactly one consistent value and retain the legacy text fixture.
        try:
            doc = json.loads(text)
            jobs = doc.get("jobs", [])
            values = {int(job["job_runtime"]) for job in jobs
                      if isinstance(job, dict) and "job_runtime" in job}
        except (json.JSONDecodeError, TypeError, ValueError, KeyError) as exc:
            raise EvidenceError("fio output lacks run=<msec> or JSON job_runtime") from exc
        if len(values) != 1:
            raise EvidenceError("JSON fio output lacks one consistent job_runtime")
        value = values.pop()
    if not expected * 1000 - 2000 <= value <= expected * 1000 + 5000:
        raise EvidenceError(f"unexpected runtime {value}ms")
    return value


def validate_fio_json(text: str, workload: str, jobs: int, expected_file: str) -> None:
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as exc:
        raise EvidenceError("fio output is not JSON+") from exc
    expected_rw = "read" if workload == "seq_read" else "write"
    expected_bs = "20M" if workload == "seq_read" else "16M"
    global_opts = doc.get("global options") or doc.get("global_options") or {}
    rows = doc.get("jobs")
    if not isinstance(rows, list) or len(rows) != jobs:
        raise EvidenceError("JSON fio job count mismatch")
    for job in rows:
        if not isinstance(job, dict) or int(job.get("error", 1)) != 0:
            raise EvidenceError("JSON fio reports I/O errors")
        if "job_runtime" not in job:
            raise EvidenceError("JSON fio job_runtime missing")
        job_opts = job.get("job options") or job.get("job_options") or {}
        opts = dict(global_opts)
        opts.update(job_opts)
        if str(opts.get("rw", "")) != expected_rw or str(opts.get("bs", "")) != expected_bs:
            raise EvidenceError("JSON fio rw/bs contract mismatch")
        if str(opts.get("direct", "")) not in ("1", "True", "true"):
            raise EvidenceError("JSON fio direct contract mismatch")
        if str(opts.get("size", "")) != "10G":
            raise EvidenceError("JSON fio size contract mismatch")
        if "time_based" in opts and str(opts["time_based"]) not in ("", "1", "True", "true"):
            raise EvidenceError("JSON fio time_based contract mismatch")
        if int(str(opts.get("runtime", "0"))) != EXPECTED[workload][0]:
            raise EvidenceError("JSON fio runtime option mismatch")
        if str(opts.get("allow_file_create", "")) not in ("0", "False", "false"):
            raise EvidenceError("JSON fio allow_file_create contract mismatch")
        filename = opts.get("filename") or job.get("filename")
        if str(filename) != expected_file:
            raise EvidenceError(f"JSON fio filename mismatch: {filename!r}")
        active = job.get(expected_rw) or {}
        opposite = job.get("write" if expected_rw == "read" else "read") or {}
        try:
            active_bytes = int(active.get("io_bytes", 0))
            opposite_bytes = int(opposite.get("io_bytes", 0))
        except (TypeError, ValueError) as exc:
            raise EvidenceError("JSON fio byte counters invalid") from exc
        # fio 3.28 omits flag-only time_based from job options.  When omitted,
        # completing more than the 10 GiB file size plus the full job_runtime
        # is the captured semantic proof that the job looped by time.
        if "time_based" not in opts and active_bytes <= 10 * 1024**3:
            raise EvidenceError("JSON fio omits time_based and lacks looping-I/O proof")
        if active_bytes <= 0 or opposite_bytes != 0:
            raise EvidenceError("JSON fio direction byte counters mismatch")


def read_log(path: Path):
    # fio bw logs use relative milliseconds and KiB/s; both conversions are
    # intentional before interval-overlap resampling to natural seconds.
    rows = []
    previous = 0.0
    for no, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split(",")
        if len(fields) < 2:
            raise EvidenceError(f"short bw row {path}:{no}")
        try:
            end = float(fields[0]) / 1000.0
            kib = float(fields[1])
        except ValueError as exc:
            raise EvidenceError(f"bad bw row {path}:{no}") from exc
        if end <= previous or kib < 0 or not math.isfinite(end + kib):
            raise EvidenceError(f"invalid/non-monotonic bw row {path}:{no}")
        rows.append((previous, end, kib / 1024.0))
        previous = end
    return rows


def percentile(values, fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise EvidenceError("empty percentile input")
    pos = (len(ordered) - 1) * fraction
    low = math.floor(pos)
    high = math.ceil(pos)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (pos - low)


def analyze(cell: Path, workload: str, expected_file: str, jobs: int = 1, start_shift: float = 0.0):
    expected_s, expected_bs = EXPECTED[workload]
    out = (cell / "fio.txt").read_text()
    validate_fio_json(out, workload, jobs, expected_file)
    run_ms = runtime(out, expected_s)
    end_ns = int((cell / "fio-end-ns.txt").read_text().strip())
    actual_start_ns = end_ns - run_ms * 1_000_000
    logs = sorted((cell / "bwlog").glob("*_bw.*.log"))
    if len(logs) != jobs:
        raise EvidenceError(f"expected {jobs} per-job logs, got {len(logs)}")
    sec = {}
    for job, log in enumerate(logs):
        log_rows = read_log(log)
        if not log_rows or log_rows[-1][1] < expected_s - 1 or log_rows[-1][1] > expected_s + 5:
            raise EvidenceError(f"bw log runtime coverage mismatch: {log}")
        for begin, end, mib in log_rows:
            for s in range(math.floor(begin), math.ceil(end)):
                overlap = min(end, s + 1) - max(begin, float(s))
                if overlap > 0:
                    value, weight = sec.setdefault(s, {}).get(job, (0.0, 0.0))
                    sec[s][job] = (value + mib * overlap, weight + overlap)
    start, finish, width = WINDOWS[workload]
    start += start_shift
    finish += start_shift
    values = []
    for s in range(math.ceil(start), math.floor(finish)):
        samples = sec.get(s, {})
        if len(samples) != jobs:
            raise EvidenceError(f"incomplete second {s}")
        values.append(sum(v / weight for v, weight in samples.values()))
    if len(values) != width * 4:
        raise EvidenceError("formal window coverage mismatch")
    mean = statistics.mean(values)
    windows = []
    for offset in range(4):
        # WINDOWS gives the width of each formal window (10s read, 25s write).
        a = math.ceil(start + offset * width)
        b = math.floor(start + (offset + 1) * width)
        if b - a != width:
            raise EvidenceError("formal subwindow width mismatch")
        windows.append(statistics.mean(values[offset * width:(offset + 1) * width]))
    p10 = percentile(values, 0.10)
    p90 = percentile(values, 0.90)
    return {"workload": workload, "runtime_ms": run_ms, "actual_start_ns": actual_start_ns,
            "start_shift_s": start_shift, "formal_mean_MiBs": mean,
            "formal_median_MiBs": statistics.median(values),
            "formal_p10_MiBs": p10, "formal_p90_MiBs": p90,
            "formal_cv_pct": statistics.pstdev(values) / mean * 100 if mean else None,
            "windows_MiBs": windows, "w4_w1": windows[-1] / windows[0] if windows[0] else None}


def self_test() -> int:
    json_runtime = runtime(json.dumps({"jobs": [{"job_runtime": 60000}]}), 60)
    if json_runtime != 60000:
        raise AssertionError("json+ runtime fixture failed")
    with tempfile.TemporaryDirectory(prefix="t04tmp3-fixture-") as name:
        root = Path(name)
        cell = root / "cell"; (cell / "bwlog").mkdir(parents=True)
        def fio_json(workload, runtime_ms, filename):
            rw = "read" if workload == "seq_read" else "write"
            bs = "20M" if workload == "seq_read" else "16M"
            # fio represents flag-only --time_based as an empty string in
            # real CLI JSON; keep that exact shape in the regression fixture.
            active = {"io_bytes": 20 * 1024**3}
            opposite = {"io_bytes": 0}
            row = {"job_runtime": runtime_ms, "error": 0, "job options": {"filename": filename, "rw": rw, "bs": bs, "direct": "1", "size": "10G", "runtime": str(runtime_ms // 1000), "allow_file_create": "0"}, rw: active, "write" if rw == "read" else "read": opposite}
            return json.dumps({"jobs": [row]})
        read_file = "/tmp/read/testfile1"
        write_file = "/tmp/write/W01/testfile1"
        (cell / "fio.txt").write_text(fio_json("seq_read", 60000, read_file))
        (cell / "fio-end-ns.txt").write_text("1600000000000\n")
        # Deliberately offset interval boundaries to exercise overlap weighting.
        rows = [f"{(i + 0.4) * 1000:.0f},1024\n" for i in range(60)]
        (cell / "bwlog/read_bw.1.log").write_text("".join(rows))
        good = analyze(cell, "seq_read", read_file)
        if not (good["formal_mean_MiBs"] > 0 and good["actual_start_ns"] == 1540000000000):
            raise AssertionError("basic fixture failed")
        if len(good["windows_MiBs"]) != 4 or good["windows_MiBs"] != [1.0] * 4:
            raise AssertionError("read 10s x4 windows failed")
        if not (good["formal_p10_MiBs"] == 1.0 and good["formal_p90_MiBs"] == 1.0):
            raise AssertionError("read P10/P90 failed")
        (cell / "fio.txt").write_text(fio_json("seq_write", 120000, write_file))
        rows = [f"{(i + 0.4) * 1000:.0f},{1024 if i < 60 else 2048}\n" for i in range(120)]
        (cell / "bwlog/read_bw.1.log").write_text("".join(rows))
        write = analyze(cell, "seq_write", write_file)
        if len(write["windows_MiBs"]) != 4 or not (write["formal_p10_MiBs"] == 1.0 and write["formal_p90_MiBs"] == 2.0):
            raise AssertionError("write 25s x4/P10/P90 failed")
        (cell / "fio.txt").write_text(fio_json("seq_read", 60000, read_file))
        rows = [f"{(i + 0.4) * 1000:.0f},1024\n" for i in range(60)]
        (cell / "bwlog/read_bw.1.log").write_text("".join(rows))
        for delta in (-1, 1):
            nearby = analyze(cell, "seq_read", read_file, start_shift=delta)
            if abs(nearby["formal_mean_MiBs"] / good["formal_mean_MiBs"] - 1) >= .01:
                raise AssertionError("±1s sensitivity exceeds 1%")
        (cell / "bwlog/read_bw.2.log").write_text("")
        try:
            analyze(cell, "seq_read", read_file)
        except EvidenceError:
            pass
        else:
            raise AssertionError("missing-job fixture did not fail")
    print("T04TMP3_ANALYZER_SELFTEST_PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("self-test", "cell"))
    parser.add_argument("root", nargs="?")
    parser.add_argument("workload", nargs="?", choices=tuple(EXPECTED))
    parser.add_argument("--expected-file")
    args = parser.parse_args()
    if args.command == "self-test":
        return self_test()
    if not args.root or not args.workload or not args.expected_file:
        parser.error("cell requires ROOT, WORKLOAD and --expected-file")
    print(json.dumps(analyze(Path(args.root), args.workload, args.expected_file), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EvidenceError as exc:
        print(f"T04TMP3_ANALYZER_FAIL\t{exc}", file=sys.stderr)
        raise SystemExit(2)
