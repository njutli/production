#!/usr/bin/env python3
"""Offline L1 analyzer for the 04-tmp2 fixed-window ABBA screen.

The analyzer intentionally consumes only local evidence.  It validates the
128 per-job bandwidth logs, derives the formal window from the recorded fio
I/O start/end, and computes the four-cell ABBA decision without importing the
larger randrw or multi-round model.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import sys
import tempfile
from pathlib import Path


EXPECTED_JOBS = 128
FORMAL_START = 15
FORMAL_END = 175
CELL_NAMES = ("R01-A", "R02-B", "R03-B", "R04-A")


class EvidenceError(RuntimeError):
    pass


def percentile(values: list[float], p: float) -> float:
    if not values:
        raise EvidenceError("empty percentile input")
    xs = sorted(values)
    pos = (len(xs) - 1) * p
    lo, hi = math.floor(pos), math.ceil(pos)
    return xs[lo] if lo == hi else xs[lo] * (hi - pos) + xs[hi] * (pos - lo)


def parse_runtime(text: str) -> int | None:
    matches = [int(b or a) for a, b in re.findall(r"run=(\d+)(?:-(\d+))?msec", text)]
    return max(matches) if matches else None


def read_cell(cell: Path) -> dict:
    start_file = cell / "fio-start-ns.txt"
    end_file = cell / "fio-end-ns.txt"
    if not start_file.is_file() or not end_file.is_file():
        raise EvidenceError(f"{cell}: missing actual fio start/end timestamps")
    try:
        start_ns = int(start_file.read_text().strip())
        end_ns = int(end_file.read_text().strip())
    except ValueError as exc:
        raise EvidenceError(f"{cell}: invalid fio timestamp") from exc
    duration_ns = end_ns - start_ns
    if not 175_000_000_000 <= duration_ns <= 190_000_000_000:
        raise EvidenceError(f"{cell}: unexpected I/O duration {duration_ns}ns")

    fio_text = ""
    for candidate in (cell / "fio.txt", cell / "fio.stdout"):
        if candidate.is_file():
            fio_text = candidate.read_text(errors="replace")
            break
    if fio_text:
        runtime = parse_runtime(fio_text)
        if runtime is not None and not 175_000 <= runtime <= 190_000:
            raise EvidenceError(f"{cell}: fio reports unexpected runtime {runtime}ms")

    bw_dir = cell / "bw"
    if not bw_dir.is_dir():
        raise EvidenceError(f"{cell}: missing bw directory")
    log_files = sorted(bw_dir.glob("*_bw.*.log"))
    indexed: dict[int, Path] = {}
    for path in log_files:
        match = re.search(r"_bw\.(\d+)\.log$", path.name)
        if not match:
            raise EvidenceError(f"{cell}: unexpected bandwidth log name {path.name}")
        job = int(match.group(1))
        if job in indexed:
            raise EvidenceError(f"{cell}: duplicate bandwidth log {job}")
        indexed[job] = path
    expected_ids = set(range(1, EXPECTED_JOBS + 1))
    if set(indexed) != expected_ids or len(indexed) != EXPECTED_JOBS:
        raise EvidenceError(
            f"{cell}: require exactly 128 logs numbered 1..128, got {sorted(indexed)}"
        )

    # Aggregate each one-second interval using the overlap-weighted method
    # used by s04r1-analyze.py.  fio bw values are KiB/s; report MiB/s.
    sums: dict[int, dict[int, float]] = {}
    weights: dict[int, dict[int, float]] = {}
    for job in sorted(indexed):
        previous = 0.0
        rows = 0
        with indexed[job].open(newline="") as handle:
            for row in csv.reader(handle):
                if len(row) < 3:
                    raise EvidenceError(f"{indexed[job]}:{rows + 1}: truncated row")
                try:
                    finish = float(row[0]) / 1000.0
                    bandwidth = float(row[1]) / 1024.0
                    direction = int(row[2])
                except ValueError as exc:
                    raise EvidenceError(f"{indexed[job]}:{rows + 1}: malformed row") from exc
                if finish <= previous or bandwidth < 0 or direction != 0:
                    raise EvidenceError(f"{indexed[job]}:{rows + 1}: invalid read interval")
                for second in range(math.floor(previous), math.ceil(finish)):
                    overlap = min(finish, second + 1) - max(previous, second)
                    if overlap > 0:
                        sums.setdefault(second, {})[job] = sums.setdefault(second, {}).get(job, 0.0) + bandwidth * overlap
                        weights.setdefault(second, {})[job] = weights.setdefault(second, {}).get(job, 0.0) + overlap
                previous = finish
                rows += 1
        if previous < FORMAL_END or rows < FORMAL_END:
            raise EvidenceError(f"{indexed[job]}: log ends before formal window")

    aggregate: dict[int, float] = {}
    for second in range(FORMAL_START, FORMAL_END):
        if second not in sums or set(sums[second]) != expected_ids:
            raise EvidenceError(f"{cell}: formal second {second} lacks all 128 jobs")
        if any(weights[second].get(job, 0.0) <= 0 for job in expected_ids):
            raise EvidenceError(f"{cell}: formal second {second} has incomplete weight")
        aggregate[second] = sum(sums[second][job] / weights[second][job] for job in expected_ids)

    formal = [aggregate[second] for second in range(FORMAL_START, FORMAL_END)]
    windows = [statistics.mean(formal[i : i + 40]) for i in range(0, 160, 40)]
    mean = statistics.mean(formal)
    return {
        "n_logs": EXPECTED_JOBS,
        "io_start_ns": start_ns,
        "io_end_ns": end_ns,
        "io_duration_s": duration_ns / 1e9,
        "formal_window_s": [FORMAL_START, FORMAL_END],
        "formal_n": len(formal),
        "mean_MiBs": mean,
        "median_MiBs": statistics.median(formal),
        "cv_pct": statistics.pstdev(formal) / mean * 100 if mean else math.inf,
        "p10_MiBs": percentile(formal, 0.10),
        "p90_MiBs": percentile(formal, 0.90),
        "windows_MiBs": windows,
        "w4_w1": windows[3] / windows[0] if windows[0] else math.inf,
    }


def analyze_screen(root: Path) -> dict:
    cells = {}
    for name in CELL_NAMES:
        cell = root / name
        if not cell.is_dir():
            raise EvidenceError(f"missing cell {name}")
        cells[name] = read_cell(cell)
    values = [cells[name]["mean_MiBs"] for name in CELL_NAMES]
    a_mean = statistics.mean((values[0], values[3]))
    b_mean = statistics.mean((values[1], values[2]))
    effect = b_mean / a_mean - 1 if a_mean else math.nan
    epsilon = max(abs(values[3] / values[0] - 1), abs(values[2] / values[1] - 1))
    material_line = max(0.05, 2 * epsilon)
    b_windows_stable = all(0.95 <= cells[name]["w4_w1"] <= 1.05 for name in CELL_NAMES if name.endswith("-B"))
    b_above_adjacent_a = values[1] > values[0] and values[2] > values[3]
    if not all(cells[name]["n_logs"] == EXPECTED_JOBS for name in CELL_NAMES):
        verdict = "CACHE_SCREEN_EVIDENCE_INVALID"
    elif epsilon >= 0.05:
        verdict = "CACHE_SCREEN_RESOLUTION_INSUFFICIENT"
    elif effect >= material_line and b_above_adjacent_a and b_windows_stable:
        verdict = "CACHE_SCREEN_MATERIAL_SIGNAL"
    elif effect < -material_line:
        verdict = "CACHE_SCREEN_LOCAL_PATH_REGRESSION"
    else:
        verdict = "CACHE_SCREEN_NO_MATERIAL_SIGNAL"
    return {
        "schema": 1,
        "arms": list(CELL_NAMES),
        "cells": cells,
        "A_mean_MiBs": a_mean,
        "B_mean_MiBs": b_mean,
        "effect": effect,
        "effect_pct": effect * 100,
        "epsilon": epsilon,
        "epsilon_pct": epsilon * 100,
        "material_line": material_line,
        "material_line_pct": material_line * 100,
        "verdict": verdict,
    }


def write_fixture(root: Path, a: float = 5000.0, b: float = 6000.0) -> None:
    for index, name in enumerate(CELL_NAMES):
        cell = root / name
        bw = cell / "bw"
        bw.mkdir(parents=True)
        value = a if name.endswith("-A") else b
        # Deliberately use 180 complete one-second rows, giving a 15..175s
        # window and enough prefix/suffix to prove the start offset is honored.
        for job in range(1, EXPECTED_JOBS + 1):
            with (bw / f"read_test_bw.{job}.log").open("w", newline="") as handle:
                out = csv.writer(handle)
                for second in range(1, 181):
                    out.writerow((second * 1000, value * 1024, 0))
        start = 1_000_000_000_000 + index * 1_000_000_000
        (cell / "fio-start-ns.txt").write_text(f"{start}\n")
        (cell / "fio-end-ns.txt").write_text(f"{start + 180_000_000_000}\n")
        (cell / "fio.txt").write_text("run=180000-180000msec\n")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="t04tmp2-analyzer-") as directory:
        root = Path(directory)
        write_fixture(root)
        result = analyze_screen(root)
        if result["verdict"] != "CACHE_SCREEN_MATERIAL_SIGNAL":
            raise EvidenceError(f"synthetic positive verdict was {result['verdict']}")
        (root / "R04-A" / "bw" / "read_test_bw.128.log").unlink()
        try:
            analyze_screen(root)
        except EvidenceError:
            pass
        else:
            raise EvidenceError("synthetic missing-log negative was accepted")
    print("T04TMP2_ANALYZER_SELFTEST: PASS")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    screen = sub.add_parser("screen")
    screen.add_argument("--root", type=Path, required=True)
    screen.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "self-test":
            self_test()
        else:
            result = analyze_screen(args.root)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
            print(f"T04TMP2_ANALYZER_PASS verdict={result['verdict']} effect_pct={result['effect_pct']:.3f}")
    except (EvidenceError, OSError, ValueError) as exc:
        print(f"T04TMP2_ANALYZER_FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
