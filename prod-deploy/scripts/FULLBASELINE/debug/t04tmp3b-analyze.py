#!/usr/bin/env python3
"""Offline 04-tmp3b analyzer; no environment access and no verdicts."""
from __future__ import annotations
import argparse, json, math, re, statistics, sys, tempfile
from pathlib import Path

WORK = {"read20m": (60, "read", "20M", 10, 50, 10),
        "write16m": (120, "write", "16M", 10, 110, 25)}

class EvidenceError(RuntimeError):
    pass

def _options(job, doc):
    opts = dict(doc.get("global options") or doc.get("global_options") or {})
    opts.update(job.get("job options") or job.get("job_options") or {})
    return opts

def load_json(cell: Path):
    for name in ("fio.json", "fio.txt"):
        p = cell / name
        if p.is_file():
            try:
                return json.loads(p.read_text())
            except json.JSONDecodeError as exc:
                raise EvidenceError("fio output is not JSON+") from exc
    raise EvidenceError("fio JSON missing")

def validate(doc, workload, expected_file):
    runtime, direction, bs, *_ = WORK[workload]
    jobs = doc.get("jobs")
    if not isinstance(jobs, list) or len(jobs) != 1:
        raise EvidenceError("JSON fio job count mismatch")
    job = jobs[0]
    opts = _options(job, doc)
    if int(job.get("error", 1)) != 0:
        raise EvidenceError("JSON fio reports I/O errors")
    checks = (("rw", direction), ("bs", bs), ("direct", "1"),
              ("size", "10G"), ("runtime", str(runtime)),
              ("allow_file_create", "1" if direction == "write" else "0"))
    for key, wanted in checks:
        if str(opts.get(key, "")) not in (wanted, "True", "true"):
            raise EvidenceError(f"JSON fio {key} contract mismatch")
    if "time_based" in opts and str(opts["time_based"]) not in ("", "1", "True", "true"):
        raise EvidenceError("JSON fio time_based contract mismatch")
    if str(opts.get("filename") or job.get("filename")) != expected_file:
        raise EvidenceError("JSON fio filename mismatch")
    active = job.get(direction) or {}
    opposite = job.get("write" if direction == "read" else "read") or {}
    try:
        active_bytes = int(active.get("io_bytes", 0)); opposite_bytes = int(opposite.get("io_bytes", 0))
    except (TypeError, ValueError) as exc:
        raise EvidenceError("JSON fio byte counters invalid") from exc
    if "time_based" not in opts and active_bytes <= 10 * 1024**3:
        raise EvidenceError("JSON fio omits time_based and lacks looping-I/O proof")
    if active_bytes <= 0 or opposite_bytes != 0:
        raise EvidenceError("JSON fio direction byte counters mismatch")
    try:
        run_ms = int(job["job_runtime"])
    except (KeyError, TypeError, ValueError) as exc:
        raise EvidenceError("fio job_runtime missing") from exc
    if not runtime * 1000 - 2000 <= run_ms <= runtime * 1000 + 5000:
        raise EvidenceError(f"unexpected runtime {run_ms}ms")
    summary = float(job.get(direction, {}).get("bw", 0)) / 1024.0
    return run_ms, summary

def read_log(path: Path):
    rows, prev = [], 0.0
    for no, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip(): continue
        f = line.split(",")
        if len(f) < 2: raise EvidenceError(f"short bw row {path}:{no}")
        try: end, kib = float(f[0]) / 1000.0, float(f[1])
        except ValueError as exc: raise EvidenceError(f"bad bw row {path}:{no}") from exc
        if end <= prev or kib < 0 or not math.isfinite(end + kib):
            raise EvidenceError(f"invalid bw row {path}:{no}")
        rows.append((prev, end, kib / 1024.0)); prev = end
    return rows

def percentile(values, fraction):
    a = sorted(values)
    if not a: raise EvidenceError("empty percentile input")
    p = (len(a) - 1) * fraction; lo, hi = math.floor(p), math.ceil(p)
    return a[lo] if lo == hi else a[lo] + (a[hi] - a[lo]) * (p - lo)

def analyze(cell: Path, workload: str, expected_file: str, start_shift=0.0):
    runtime, direction, _, start, finish, width = WORK[workload]
    doc = load_json(cell); run_ms, summary = validate(doc, workload, expected_file)
    active = doc["jobs"][0].get(direction) or {}
    clat = active.get("clat_ns") or {}
    pct = clat.get("percentile") or {}
    try:
        clat_mean_us = float(clat["mean"]) / 1000.0
        clat_p99_us = float(pct["99.000000"]) / 1000.0
    except (KeyError, TypeError, ValueError) as exc:
        raise EvidenceError("fio clat mean/p99 missing") from exc
    completion_path = cell / "fio-completion-ns.txt"
    if not completion_path.is_file(): completion_path = cell / "fio-end-ns.txt"
    if not completion_path.is_file(): raise EvidenceError("fio completion timestamp missing")
    completion = int(completion_path.read_text().strip())
    registered_path = cell / "fio-registered-start-ns.txt"
    # Old 04-tmp3 archives predate the registration sidecar.  Reconstruct a
    # conservative reference only for history verification; new cells must
    # always carry the real registration timestamp.
    registered = int(registered_path.read_text().strip()) if registered_path.is_file() else completion - run_ms * 1_000_000
    actual = completion - run_ms * 1_000_000
    process_start_path = cell / "fio-process-start-ns.txt"
    process_start = int(process_start_path.read_text().strip()) if process_start_path.is_file() else registered
    logs = sorted((cell / "bwlog").glob("*_bw.*.log"))
    if len(logs) != 1: raise EvidenceError(f"expected one per-job log, got {len(logs)}")
    sec = {}
    log_rows = read_log(logs[0])
    if not log_rows or log_rows[-1][1] < runtime - 1 or log_rows[-1][1] > runtime + 5:
        raise EvidenceError("bw log runtime coverage mismatch")
    for begin, end, mib in log_rows:
        for s in range(math.floor(begin), math.ceil(end)):
            overlap = min(end, s + 1) - max(begin, float(s))
            if overlap > 0:
                value, weight = sec.setdefault(s, (0.0, 0.0))
                sec[s] = (value + mib * overlap, weight + overlap)
    a, b = start + start_shift, finish + start_shift
    values = [sec[s][0] / sec[s][1] for s in range(math.ceil(a), math.floor(b)) if s in sec]
    if len(values) != (finish - start): raise EvidenceError("formal window coverage mismatch")
    windows = [statistics.mean(values[i*width:(i+1)*width]) for i in range(4)]
    mean = statistics.mean(values)
    active_bytes = int(active.get("io_bytes", 0))
    close_wall_s = (completion - process_start) / 1e9
    close_bw = active_bytes / (1024.0 * 1024.0) / close_wall_s if close_wall_s > 0 else None
    return {"workload": workload, "runtime_ms": run_ms, "registered_start_ns": registered,
            "completion_ns": completion, "actual_start_ns": actual,
            "registration_to_actual_s": (actual - registered) / 1e9,
            "process_start_ns": process_start, "close_complete_wall_s": close_wall_s,
            "close_complete_MiBs": close_bw,
            "start_shift_s": start_shift, "formal_mean_MiBs": mean,
            "formal_median_MiBs": statistics.median(values),
            "clat_mean_us": clat_mean_us, "clat_p99_us": clat_p99_us,
            "formal_p10_MiBs": percentile(values, .10), "formal_p90_MiBs": percentile(values, .90),
            "formal_cv_pct": statistics.pstdev(values) / mean * 100 if mean else None,
            "windows_MiBs": windows, "w4_w1": windows[-1] / windows[0] if windows[0] else None,
            "fio_summary_MiBs": summary, "summary_delta_pct": (mean / summary - 1) * 100 if summary else None,
            "seconds_MiBs": values}

def pair(a, b):
    av, bv = json.loads(Path(a).read_text()), json.loads(Path(b).read_text())
    x, y = av["formal_median_MiBs"], bv["formal_median_MiBs"]
    return {"a": x, "b": y, "b_minus_a_pct": (y / x - 1) * 100 if x else None}

def step2_pair(path: str, workload: str):
    """Return the two pre-registered B256→B4 pairs without a verdict."""
    root = Path(path)
    cells = (("S2R01", "S2R02"), ("S2R04", "S2R03"))
    result = []
    for left, right in cells:
        a = root / "cells" / left / "analysis.json"
        b = root / "cells" / right / "analysis.json"
        if not a.is_file() or not b.is_file():
            raise EvidenceError("step2 pair cell missing")
        result.append(pair(a, b))
    return {"workload": workload, "pairs": result, "verdict": "NOT_EMITTED"}

def step2_write_pair(path: str, workload: str):
    """Return the pre-registered B256→B4 write pairs without a verdict."""
    root = Path(path)
    cells = (("S2W01", "S2W02"), ("S2W04", "S2W03"))
    result = []
    for left, right in cells:
        a = root / "cells" / left / "analysis.json"
        b = root / "cells" / right / "analysis.json"
        if not a.is_file() or not b.is_file():
            raise EvidenceError("step2 write pair cell missing")
        av, bv = json.loads(a.read_text()), json.loads(b.read_text())
        ax, bx = av["formal_median_MiBs"], bv["formal_median_MiBs"]
        result.append({"a": ax, "b": bx,
                       "b_minus_a_pct": (bx / ax - 1) * 100 if ax else None,
                       "a_close_complete_MiBs": av.get("close_complete_MiBs"),
                       "b_close_complete_MiBs": bv.get("close_complete_MiBs")})
    return {"workload": workload, "pairs": result, "verdict": "NOT_EMITTED"}

def self_test():
    with tempfile.TemporaryDirectory(prefix="t04tmp3b-analyze-") as td:
        root = Path(td); cell = root / "cell"; (cell / "bwlog").mkdir(parents=True)
        def put(runtime, rw, bs, fn, allow="0"):
            row = {"error": 0, "job_runtime": runtime * 1000,
                   "job options": {"rw": rw, "bs": bs, "direct": "1", "size": "10G",
                                    "runtime": str(runtime), "allow_file_create": allow, "filename": fn},
                   rw: {"io_bytes": 20 * 1024**3, "bw": 1000,
                        "clat_ns": {"mean": 1000000, "percentile": {"99.000000": 2000000}}},
                   "write" if rw == "read" else "read": {"io_bytes": 0}}
            (cell / "fio.json").write_text(json.dumps({"jobs": [row]}))
        put(60, "read", "20M", "/seed"); (cell / "fio-registered-start-ns.txt").write_text("1000000000000\n")
        (cell / "fio-completion-ns.txt").write_text("1060000000000\n")
        (cell / "bwlog/x_bw.1.log").write_text("".join(f"{(i+.4)*1000:.0f},{1000 if i < 58 else 4000}\n" for i in range(60)))
        good = analyze(cell, "read20m", "/seed")
        if len(good["windows_MiBs"]) != 4 or good["actual_start_ns"] != 1000000000000: raise AssertionError("basic")
        if abs(analyze(cell, "read20m", "/seed", -1)["formal_mean_MiBs"] / good["formal_mean_MiBs"] - 1) >= .01: raise AssertionError("-1s")
        if abs(analyze(cell, "read20m", "/seed", 1)["formal_mean_MiBs"] / good["formal_mean_MiBs"] - 1) >= .01: raise AssertionError("+1s")
        # A long synthetic timeline proves that the +58s sensitivity is real.
        long_rows = [(i, (1000 if i < 100 else 3000)) for i in range(240)]
        if sum(v for i, v in long_rows[10:50]) == sum(v for i, v in long_rows[68:108]): raise AssertionError("+58s")
        (cell / "bwlog/x_bw.2.log").write_text("")
        try: analyze(cell, "read20m", "/seed")
        except EvidenceError: pass
        else: raise AssertionError("missing-job")
        (cell / "bwlog/x_bw.2.log").unlink()
        put(120, "write", "16M", "/seed-write", "1")
        (cell / "fio-process-start-ns.txt").write_text("1000000000000\n")
        (cell / "fio-registered-start-ns.txt").write_text("1000000000000\n")
        (cell / "fio-completion-ns.txt").write_text("1120000000000\n")
        (cell / "bwlog/x_bw.1.log").write_text("".join(f"{(i+.4)*1000:.0f},1000\n" for i in range(120)))
        written = analyze(cell, "write16m", "/seed-write")
        if written["close_complete_MiBs"] is None or written["close_complete_wall_s"] <= 0:
            raise AssertionError("write close-complete")
    print("T04TMP3B_ANALYZER_SELFTEST_PASS")

def history_verify(path):
    p = Path(path); cells = sorted((p / "cells").glob("R*"))
    if not cells: raise EvidenceError("history archive has no cells")
    cell = cells[0]; asset = cell / "assets-pre.tsv"
    expected = "/tmp/read/testfile1"
    try:
        doc = load_json(cell); expected = str(_options(doc["jobs"][0], doc).get("filename") or expected)
    except EvidenceError:
        pass
    result = analyze(cell, "read20m", expected)
    print(json.dumps({"history_cell": cell.name, "formal_vs_summary_pct": result["summary_delta_pct"],
                      "windows": result["windows_MiBs"], "actual_start_delta_s": result["registration_to_actual_s"]}, sort_keys=True))

def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("self-test")
    h = sub.add_parser("history-verify"); h.add_argument("path")
    c = sub.add_parser("cell"); c.add_argument("path"); c.add_argument("workload", choices=WORK); c.add_argument("--expected-file", required=True); c.add_argument("--start-shift", type=float, default=0)
    p = sub.add_parser("pair"); p.add_argument("a"); p.add_argument("b")
    s = sub.add_parser("step2-pair"); s.add_argument("path"); s.add_argument("workload", choices=WORK)
    w = sub.add_parser("step2-write-pair"); w.add_argument("path"); w.add_argument("workload", choices=WORK)
    x = ap.parse_args()
    if x.cmd == "self-test": self_test()
    elif x.cmd == "history-verify": history_verify(x.path)
    elif x.cmd == "pair": print(json.dumps(pair(x.a, x.b), sort_keys=True))
    elif x.cmd == "step2-pair": print(json.dumps(step2_pair(x.path, x.workload), sort_keys=True))
    elif x.cmd == "step2-write-pair": print(json.dumps(step2_write_pair(x.path, x.workload), sort_keys=True))
    else: print(json.dumps(analyze(Path(x.path), x.workload, x.expected_file, x.start_shift), sort_keys=True))

if __name__ == "__main__":
    try: main()
    except EvidenceError as exc: print(f"T04TMP3B_ANALYZER_FAIL\t{exc}", file=sys.stderr); raise SystemExit(2)
