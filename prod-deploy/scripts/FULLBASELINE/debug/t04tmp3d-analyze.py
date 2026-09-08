#!/usr/bin/env python3
"""Offline analyzer for one 04-tmp3d rados bench read cell."""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from pathlib import Path


class EvidenceError(RuntimeError):
    pass


ROW = re.compile(r"^\s*(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)")


def parse_rows(path: Path):
    rows = []
    for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        match = ROW.match(line)
        if not match:
            continue
        sec = int(match.group(1))
        try:
            cur = float(match.group(6))
        except ValueError as exc:
            raise EvidenceError(f"invalid current bandwidth at line {number}") from exc
        if sec < 0 or not math.isfinite(cur) or cur < 0:
            raise EvidenceError(f"invalid row at line {number}")
        rows.append((sec, cur))
    if not rows:
        raise EvidenceError("no per-second rados rows")
    rows.sort()
    if len({sec for sec, _ in rows}) != len(rows):
        raise EvidenceError("duplicate per-second rows")
    return rows


def parse_summary(path: Path):
    for line in path.read_text(errors="replace").splitlines():
        if "Bandwidth (MB/sec):" in line:
            try:
                return float(line.rsplit(":", 1)[1].strip())
            except ValueError:
                raise EvidenceError("invalid rados summary bandwidth")
    return None


def percentile(values, p):
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    pos = (len(values) - 1) * p
    lo, hi = math.floor(pos), math.ceil(pos)
    return values[lo] + (values[hi] - values[lo]) * (pos - lo)


def analyze(path, runtime=25, stable=15, expected_size=None, expected_qd=None):
    path = Path(path)
    rows = parse_rows(path)
    if runtime and max(sec for sec, _ in rows) < runtime - 2:
        raise EvidenceError("per-second output shorter than requested runtime")
    if stable < 1 or len(rows) < stable:
        raise EvidenceError("stable window is not covered")
    secs = [sec for sec, _ in rows]
    if secs != list(range(min(secs), max(secs) + 1)):
        raise EvidenceError("per-second output has a gap")
    values = [value for _, value in rows[-stable:]]
    mean = statistics.mean(values)
    if mean <= 0:
        raise EvidenceError("stable bandwidth is non-positive")
    summary = parse_summary(path)
    result = {
        "rows": len(rows),
        "first_sec": rows[0][0],
        "last_sec": rows[-1][0],
        "stable_seconds": stable,
        "stable_start_sec": rows[-stable][0],
        "stable_end_sec": rows[-1][0],
        # rados bench labels this column MB/s, but computes bytes / 2^20 / s.
        "stable_mean_MiBs": mean,
        "stable_median_MiBs": statistics.median(values),
        "stable_cv_pct": statistics.pstdev(values) / mean * 100,
        "stable_p10_MiBs": percentile(values, 0.10),
        "stable_p90_MiBs": percentile(values, 0.90),
        "stable_values_MiBs": values,
        "summary_MBps": summary,
        "summary_MiBs": summary,
    }
    if summary is not None:
        result["summary_minus_stable_pct"] = (summary / mean - 1) * 100
    if expected_size is not None:
        result["object_size_bytes"] = expected_size
    if expected_qd is not None:
        result["qd"] = expected_qd
    return result


def self_test():
    import tempfile

    with tempfile.TemporaryDirectory(prefix="t04tmp3d-") as temp:
        path = Path(temp) / "cell.stdout"
        lines = ["  sec Cur ops started finished avg MB/s cur MB/s last lat(s) avg lat(s)"]
        lines += [f" {i:3d}  4  100  100  100.0  100.0  0.001  0.001" for i in range(25)]
        lines += ["Bandwidth (MB/sec): 101.0"]
        path.write_text("\n".join(lines) + "\n")
        result = analyze(path, runtime=25, stable=15)
        assert abs(result["stable_mean_MiBs"] - 100) < 1e-9
        assert result["stable_end_sec"] == 24
    print("T04TMP3D_ANALYZER_SELFTEST_PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("cell", "self-test"))
    parser.add_argument("path", nargs="?")
    parser.add_argument("--runtime", type=int, default=25)
    parser.add_argument("--stable", type=int, default=15)
    parser.add_argument("--size", type=int)
    parser.add_argument("--qd", type=int)
    args = parser.parse_args()
    if args.mode == "self-test":
        self_test()
        return
    if not args.path:
        raise EvidenceError("cell stdout path required")
    print(json.dumps(analyze(Path(args.path), args.runtime, args.stable, args.size, args.qd), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (EvidenceError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"T04TMP3D_ANALYZER_FAIL\t{exc}")
        raise SystemExit(2)
