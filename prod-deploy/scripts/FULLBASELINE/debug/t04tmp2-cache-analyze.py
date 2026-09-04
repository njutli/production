#!/usr/bin/env python3
"""Offline L1 analyzer for 04-tmp2 randread ABBA screen."""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path


class EvidenceError(RuntimeError):
    pass


ROUND_ORDER = [("R01-A", "A"), ("R02-B", "B"), ("R03-B", "B"), ("R04-A", "A")]


def percentile(values: list[float], p: float) -> float:
    xs = sorted(values)
    if not xs:
        raise EvidenceError("percentile of empty series")
    pos = (len(xs) - 1) * p
    lo, hi = math.floor(pos), math.ceil(pos)
    return xs[lo] if lo == hi else xs[lo] * (hi - pos) + xs[hi] * (pos - lo)


def discover_logs(bw_dir: Path) -> list[tuple[int, Path]]:
    rows: list[tuple[int, Path]] = []
    for path in bw_dir.glob("read_test_bw.*.log"):
        match = re.fullmatch(r"read_test_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"unexpected bw log name: {path.name}")
        rows.append((int(match.group(1)), path))
    rows.sort()
    ids = [job for job, _ in rows]
    if len(rows) != 128 or ids != list(range(1, 129)):
        raise EvidenceError(f"bw logs require ids 1..128; count={len(rows)} ids={ids[:8]}..{ids[-8:]}")
    return rows


def aggregate_logs(bw_dir: Path) -> dict[int, float]:
    series: dict[int, dict[int, float]] = defaultdict(lambda: defaultdict(float))
    weights: dict[int, dict[int, float]] = defaultdict(lambda: defaultdict(float))
    for job, path in discover_logs(bw_dir):
        previous = 0.0
        line_count = 0
        with path.open(newline="") as handle:
            for line_count, row in enumerate(csv.reader(handle), 1):
                if len(row) < 3:
                    raise EvidenceError(f"truncated bw row: {path}:{line_count}")
                try:
                    end = float(row[0].strip()) / 1000.0
                    value_mib = float(row[1].strip()) / 1024.0
                    direction = int(row[2].strip())
                except ValueError as exc:
                    raise EvidenceError(f"invalid bw row: {path}:{line_count}") from exc
                if direction != 0:
                    raise EvidenceError(f"non-read direction: {path}:{line_count} direction={direction}")
                if end <= previous or value_mib < 0:
                    raise EvidenceError(f"nonmonotonic/negative bw row: {path}:{line_count}")
                start, previous = previous, end
                for second in range(math.floor(start), math.ceil(end)):
                    overlap = min(end, second + 1) - max(start, second)
                    if overlap > 0:
                        series[second][job] += value_mib * overlap
                        weights[second][job] += overlap
        if line_count < 175:
            raise EvidenceError(f"short bw log: {path} rows={line_count}")
    aggregate: dict[int, float] = {}
    for second in sorted(series):
        if len(series[second]) != 128:
            continue
        if any(weights[second].get(job, 0) <= 0 for job in range(1, 129)):
            continue
        aggregate[second] = sum(series[second][job] / weights[second][job] for job in range(1, 129))
    return aggregate


def stats_for_window(series: dict[int, float], start: int = 15, length: int = 160) -> dict:
    seconds = list(range(start, start + length))
    missing = [second for second in seconds if second not in series]
    if missing:
        raise EvidenceError(f"formal window incomplete: missing={missing[:8]} count={len(missing)}")
    values = [series[second] for second in seconds]
    windows = [statistics.mean(values[offset : offset + 40]) for offset in range(0, 160, 40)]
    mean = statistics.mean(values)
    if mean <= 0:
        raise EvidenceError("non-positive formal mean")
    return {
        "start_second": start,
        "complete_seconds": length,
        "mean_MiBs": mean,
        "median_MiBs": statistics.median(values),
        "cv_pct": statistics.pstdev(values) / mean * 100.0,
        "p10_MiBs": percentile(values, 0.10),
        "p90_MiBs": percentile(values, 0.90),
        "windows_MiBs": windows,
        "w4_w1": windows[3] / windows[0],
        "per_second_MiBs": {str(second): series[second] for second in seconds},
    }


def fio_runtime_ms(fio_json: Path) -> tuple[int, int]:
    data = json.loads(fio_json.read_text())
    jobs = data.get("jobs")
    if not isinstance(jobs, list) or len(jobs) != 128:
        raise EvidenceError(f"fio JSON requires 128 jobs, got {0 if not isinstance(jobs, list) else len(jobs)}")
    runtimes: list[int] = []
    io_bytes = 0
    for job in jobs:
        if int(job.get("error", -1)) != 0:
            raise EvidenceError(f"fio job error: {job.get('jobname')}={job.get('error')}")
        read = job.get("read")
        if not isinstance(read, dict):
            raise EvidenceError(f"fio read object missing: {job.get('jobname')}")
        try:
            runtimes.append(int(read["runtime"]))
            io_bytes += int(read["io_bytes"])
        except (KeyError, TypeError, ValueError) as exc:
            raise EvidenceError(f"fio runtime/io_bytes missing: {job.get('jobname')}") from exc
    run_ms = max(runtimes)
    if not 175_000 <= run_ms <= 190_000:
        raise EvidenceError(f"unexpected fio runtime: {run_ms}ms")
    return run_ms, io_bytes


def analyze_round(round_dir: Path, label: str, arm: str) -> dict:
    if (label, arm) not in ROUND_ORDER and (label, arm) != ("POST-A", "A"):
        raise EvidenceError(f"invalid label/arm: {label}/{arm}")
    fio_json = round_dir / "fio.json"
    end_file = round_dir / "fio-end-ns.txt"
    if not fio_json.is_file() or not end_file.is_file():
        raise EvidenceError(f"round missing fio JSON/end timestamp: {round_dir}")
    run_ms, io_bytes = fio_runtime_ms(fio_json)
    try:
        end_ns = int(end_file.read_text().strip())
    except ValueError as exc:
        raise EvidenceError("invalid fio end timestamp") from exc
    if end_ns <= run_ms * 1_000_000:
        raise EvidenceError("fio end timestamp precedes runtime")
    actual_t0_ns = end_ns - run_ms * 1_000_000
    aggregate = aggregate_logs(round_dir / "bw")
    result = stats_for_window(aggregate, 15, 160)
    # ±1 s sensitivity is meaningful for the bandwidth log itself. +58 s is asserted
    # separately by the extended synthetic fixture because a 180 s run cannot contain [73,233).
    minus = stats_for_window(aggregate, 14, 160)["mean_MiBs"]
    plus = stats_for_window(aggregate, 16, 160)["mean_MiBs"]
    base = result["mean_MiBs"]
    result.update(
        {
            "schema": 1,
            "label": label,
            "arm": arm,
            "run_ms": run_ms,
            "fio_end_ns": end_ns,
            "actual_t0_ns": actual_t0_ns,
            "fio_read_bytes": io_bytes,
            "start_sensitivity_pct": {"minus_1s": (minus / base - 1) * 100, "plus_1s": (plus / base - 1) * 100},
        }
    )
    return result


def analyze_screen(inputs: list[Path], cache_contract: str) -> dict:
    if len(inputs) != 4:
        raise EvidenceError("screen requires exactly four round JSON files")
    rows = [json.loads(path.read_text()) for path in inputs]
    observed = [(str(row.get("label")), str(row.get("arm"))) for row in rows]
    if observed != ROUND_ORDER:
        raise EvidenceError(f"matrix order differs from ABBA: {observed}")
    values = [float(row["mean_MiBs"]) for row in rows]
    if any(not math.isfinite(value) or value <= 0 for value in values):
        raise EvidenceError(f"non-positive/non-finite round value: {values}")
    a_mean = statistics.mean((values[0], values[3]))
    b_mean = statistics.mean((values[1], values[2]))
    effect = b_mean / a_mean - 1.0
    epsilon = max(abs(values[3] / values[0] - 1.0), abs(values[2] / values[1] - 1.0))
    material = max(0.05, 2.0 * epsilon)
    pair_effects = [values[1] / values[0] - 1.0, values[2] / values[3] - 1.0]
    b_w_stable = all(0.95 <= float(rows[index]["w4_w1"]) <= 1.05 for index in (1, 2))
    if cache_contract != "PASS":
        verdict = "CACHE_SCREEN_EVIDENCE_INVALID"
    elif epsilon >= 0.05:
        verdict = "CACHE_SCREEN_RESOLUTION_INSUFFICIENT"
    elif effect >= material and all(value > 0 for value in pair_effects) and b_w_stable:
        verdict = "CACHE_SCREEN_MATERIAL_SIGNAL"
    elif effect <= -material:
        verdict = "CACHE_SCREEN_LOCAL_PATH_REGRESSION"
    else:
        verdict = "CACHE_SCREEN_NO_MATERIAL_SIGNAL"
    return {
        "schema": 1,
        "matrix": [label for label, _ in ROUND_ORDER],
        "values_MiBs": values,
        "A_mean_MiBs": a_mean,
        "B_mean_MiBs": b_mean,
        "effect_pct": effect * 100.0,
        "epsilon_pct": epsilon * 100.0,
        "material_line_pct": material * 100.0,
        "pair_effects_pct": [value * 100.0 for value in pair_effects],
        "B_w4_w1_stable": b_w_stable,
        "cache_contract": cache_contract,
        "verdict": verdict,
    }


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def synthetic_logs(root: Path, seconds: int = 240) -> Path:
    bw = root / "bw"
    bw.mkdir(parents=True, exist_ok=True)
    for job in range(1, 129):
        with (bw / f"read_test_bw.{job}.log").open("w") as handle:
            for second in range(1, seconds + 1):
                # KiB/s, direction=0. Slow drift makes a +58 s shift observable.
                handle.write(f"{second * 1000},{1024 + second * 4 + job},0,0\n")
    return bw


def self_test(root: Path) -> dict:
    root.mkdir(parents=True, exist_ok=True)
    aggregate = aggregate_logs(synthetic_logs(root))
    base = stats_for_window(aggregate, 15, 160)
    minus = stats_for_window(aggregate, 14, 160)["mean_MiBs"]
    plus = stats_for_window(aggregate, 16, 160)["mean_MiBs"]
    shifted = stats_for_window(aggregate, 73, 160)
    if abs(minus / base["mean_MiBs"] - 1) >= 0.01 or abs(plus / base["mean_MiBs"] - 1) >= 0.01:
        raise EvidenceError("±1 second sensitivity exceeds 1% in fixture")
    if abs(shifted["mean_MiBs"] / base["mean_MiBs"] - 1) <= 0.05:
        raise EvidenceError("+58 second fixture shift did not materially change result")
    rounds = []
    for (label, arm), value in zip(ROUND_ORDER, (100.0, 112.0, 113.0, 101.0)):
        row = {"label": label, "arm": arm, "mean_MiBs": value, "w4_w1": 1.0}
        path = root / f"{label}.json"; write_json(path, row); rounds.append(path)
    screen = analyze_screen(rounds, "PASS")
    if screen["verdict"] != "CACHE_SCREEN_MATERIAL_SIGNAL":
        raise EvidenceError(f"fixture verdict mismatch: {screen['verdict']}")
    return {"bandwidth": base, "plus_58s": shifted, "screen": screen, "status": "PASS"}


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("round")
    p.add_argument("--round-dir", type=Path, required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--arm", choices=("A", "B"), required=True)
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("screen")
    p.add_argument("--inputs", type=Path, nargs=4, required=True)
    p.add_argument("--cache-contract", choices=("PASS", "FAIL"), required=True)
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("self-test")
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    return ap


def main() -> int:
    args = parser().parse_args()
    if args.command == "round":
        data = analyze_round(args.round_dir, args.label, args.arm)
    elif args.command == "screen":
        data = analyze_screen(args.inputs, args.cache_contract)
    else:
        data = self_test(args.root)
    write_json(args.output, data)
    print(f"TMP2_ANALYZE_PASS command={args.command} output={args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (EvidenceError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"TMP2_ANALYZE_FAIL: {exc}", file=sys.stderr)
        raise SystemExit(42)
