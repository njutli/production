#!/usr/bin/env python3
"""Independent full-run analyzer for the minimal 04-7 A-B-B-A screen."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
from pathlib import Path


CELLS = ("A1", "B1", "B2", "A2")
JOBS = 128
RUNTIME_S = 180


class EvidenceError(RuntimeError):
    pass


def runs(values: list[int]) -> list[tuple[int, int]]:
    out: list[list[int]] = []
    for value in sorted(values):
        if not out or value != out[-1][-1] + 1:
            out.append([value])
        else:
            out[-1].append(value)
    return [(item[0], item[-1]) for item in out]


def fmt_runs(values: list[int]) -> str:
    return ",".join(str(a) if a == b else f"{a}-{b}" for a, b in runs(values)) or "NONE"


def weighted_latency(jobs: list[dict], direction: str, kind: str) -> tuple[float, float]:
    counts = [int(job[direction][kind].get("N", 0)) for job in jobs]
    total = sum(counts)
    if total <= 0:
        raise EvidenceError(f"missing {direction}/{kind} samples")
    mean_ms = sum(float(job[direction][kind]["mean"]) * n for job, n in zip(jobs, counts)) / total / 1e6
    maximum_ms = max(float(job[direction][kind]["max"]) for job in jobs) / 1e6
    return mean_ms, maximum_ms


def parse_logs(cell: Path) -> dict[str, dict]:
    paths = sorted((cell / "formal" / "bw").glob("randrw_bw.*.log"))
    if len(paths) != JOBS:
        raise EvidenceError(f"{cell.name}: expected {JOBS} bw logs, got {len(paths)}")
    present = {0: {second: set() for second in range(1, RUNTIME_S + 1)},
               1: {second: set() for second in range(1, RUNTIME_S + 1)}}
    max_gap = {0: 0, 1: 0}
    ids = []
    for path in paths:
        match = re.fullmatch(r"randrw_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"unexpected bw log: {path}")
        job_id = int(match.group(1)); ids.append(job_id)
        per_direction = {0: [], 1: []}
        for row in csv.reader(path.open()):
            if not row or not any(field.strip() for field in row):
                continue
            if len(row) < 3:
                raise EvidenceError(f"short bw row: {path}")
            timestamp_ms, direction = int(row[0]), int(row[2])
            if direction not in (0, 1) or timestamp_ms < 0:
                raise EvidenceError(f"invalid bw row: {path}")
            bucket = int(timestamp_ms / 1000 + 0.5)
            if 1 <= bucket <= RUNTIME_S:
                present[direction][bucket].add(job_id)
            per_direction[direction].append(timestamp_ms)
        for direction in (0, 1):
            if not per_direction[direction]:
                raise EvidenceError(f"{path}: missing direction {direction}")
            gaps = [b - a for a, b in zip(per_direction[direction], per_direction[direction][1:])]
            max_gap[direction] = max(max_gap[direction], max(gaps, default=0))
    if sorted(ids) != list(range(1, JOBS + 1)):
        raise EvidenceError("job IDs are not exactly 1..128")
    result = {}
    for direction, name in ((0, "read"), (1, "write")):
        zero = [second for second, jobs in present[direction].items() if not jobs]
        partial = sum(1 for jobs in present[direction].values() if 0 < len(jobs) < JOBS)
        result[name] = {
            "synchronized_no_record_seconds": len(zero),
            "synchronized_no_record_runs": fmt_runs(zero),
            "partial_job_seconds": partial,
            "max_record_gap_ms": max_gap[direction],
            "interval_policy": "NO_BACKFILL",
        }
    return result


def parse_cell(root: Path, name: str) -> dict:
    cell = root / "cells" / name
    required = (cell / "PASS", cell / "drain-status.txt", cell / "readback-cache0" / "PASS",
                cell / "cache-cleanup", cell / "formal" / "fio.json", cell / "mount-warmup.argv")
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise EvidenceError(f"{name}: missing lifecycle evidence: {missing}")
    if (cell / "drain-status.txt").read_text().strip() != "STRICT_ZERO":
        raise EvidenceError(f"{name}: writeback did not strictly drain")
    data = json.loads((cell / "formal" / "fio.json").read_text())
    jobs = data.get("jobs", [])
    if len(jobs) != JOBS or any(int(job.get("error", -1)) for job in jobs):
        raise EvidenceError(f"{name}: fio job contract")
    argv = (cell / "mount-warmup.argv").read_text()
    expected_async = name.startswith("B")
    if ("async_dio" in argv) != expected_async:
        raise EvidenceError(f"{name}: async_dio variable contract")
    direction_rows = {}
    for direction in ("read", "write"):
        runtime_ms = max(int(job[direction].get("runtime", 0)) for job in jobs)
        if not 175000 <= runtime_ms <= 320000:
            raise EvidenceError(f"{name}: {direction} runtime {runtime_ms}")
        io_bytes = sum(int(job[direction].get("io_bytes", 0)) for job in jobs)
        latencies = {}
        for kind in ("slat_ns", "clat_ns", "lat_ns"):
            mean_ms, max_ms = weighted_latency(jobs, direction, kind)
            latencies[kind.removesuffix("_ns") + "_mean_ms"] = mean_ms
            latencies[kind.removesuffix("_ns") + "_max_ms"] = max_ms
        direction_rows[direction] = {
            "io_bytes": io_bytes,
            "runtime_ms": runtime_ms,
            "bandwidth_MiB_s": io_bytes / (runtime_ms / 1000) / 2**20,
            **latencies,
        }
    gaps = parse_logs(cell)
    read = direction_rows["read"]["bandwidth_MiB_s"]
    write = direction_rows["write"]["bandwidth_MiB_s"]
    total_latency = (direction_rows["read"]["lat_mean_ms"] + direction_rows["write"]["lat_mean_ms"]) / 2
    return {
        "cell": name,
        "async_dio": expected_async,
        "read": direction_rows["read"],
        "write": direction_rows["write"],
        "mean_direction_MiB_s": (read + write) / 2,
        "mean_total_latency_ms": total_latency,
        "mean_synchronized_no_record_seconds": (
            gaps["read"]["synchronized_no_record_seconds"]
            + gaps["write"]["synchronized_no_record_seconds"]
        ) / 2,
        "gaps": gaps,
        "capability_evidence": "INFERRED_FROM_EXACT_MOUNT_ARGV",
    }


def pct(new: float, old: float) -> float:
    if old == 0:
        raise EvidenceError("zero denominator")
    return (new / old - 1) * 100


def decision(rows: dict[str, dict]) -> dict:
    pairs = (("B1", "A1"), ("B2", "A2"))
    effects = {}
    for b, a in pairs:
        effects[f"{b}/{a}"] = {
            "read_pct": pct(rows[b]["read"]["bandwidth_MiB_s"], rows[a]["read"]["bandwidth_MiB_s"]),
            "write_pct": pct(rows[b]["write"]["bandwidth_MiB_s"], rows[a]["write"]["bandwidth_MiB_s"]),
            "mean_pct": pct(rows[b]["mean_direction_MiB_s"], rows[a]["mean_direction_MiB_s"]),
            "total_latency_pct": pct(rows[b]["mean_total_latency_ms"], rows[a]["mean_total_latency_ms"]),
            "synchronized_gap_pct": (
                pct(rows[b]["mean_synchronized_no_record_seconds"], rows[a]["mean_synchronized_no_record_seconds"])
                if rows[a]["mean_synchronized_no_record_seconds"] else None
            ),
        }
    drift_values = []
    for newer, older in (("A2", "A1"), ("B2", "B1")):
        for endpoint in ("read", "write"):
            drift_values.append(abs(pct(rows[newer][endpoint]["bandwidth_MiB_s"], rows[older][endpoint]["bandwidth_MiB_s"])))
        drift_values.append(abs(pct(rows[newer]["mean_direction_MiB_s"], rows[older]["mean_direction_MiB_s"])))
    epsilon = max(drift_values)
    material = max(10.0, 2 * epsilon)
    pair_rows = list(effects.values())
    bandwidth_positive = all(item["mean_pct"] >= material for item in pair_rows)
    directional_safe = all(min(item["read_pct"], item["write_pct"]) >= -material for item in pair_rows)
    latency_better = all(item["total_latency_pct"] <= -material for item in pair_rows)
    gap_better = all(item["synchronized_gap_pct"] is not None and item["synchronized_gap_pct"] <= -material for item in pair_rows)
    materially_negative = all(item["mean_pct"] <= -material for item in pair_rows)
    if epsilon >= 10:
        verdict = "RESOLUTION_INSUFFICIENT"
    elif bandwidth_positive and directional_safe and (latency_better or gap_better):
        verdict = "CONTINUE_CANDIDATE"
    elif materially_negative:
        verdict = "STOP_NEGATIVE"
    elif effects["B1/A1"]["mean_pct"] * effects["B2/A2"]["mean_pct"] < 0:
        verdict = "INCONCLUSIVE"
    else:
        verdict = "STOP_NO_SIGNAL"
    return {
        "epsilon_pct": epsilon,
        "material_threshold_pct": material,
        "pair_effects": effects,
        "latency_materially_better_both_pairs": latency_better,
        "synchronized_gap_materially_better_both_pairs": gap_better,
        "verdict": verdict,
    }


def write_tsv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader(); writer.writerows(rows)


def analyze(root: Path) -> dict:
    rows_list = [parse_cell(root, name) for name in CELLS]
    rows = {row["cell"]: row for row in rows_list}
    result = {"schema": 1, "run_id": root.name.removeprefix("opencode-04-7-"),
              "primary_endpoint": "FIO_JSON_FULL_TIMED_RUN", "cells": rows_list, **decision(rows)}
    flat = []
    for row in rows_list:
        flat.append({
            "cell": row["cell"], "async_dio": int(row["async_dio"]),
            "read_MiB_s": row["read"]["bandwidth_MiB_s"],
            "write_MiB_s": row["write"]["bandwidth_MiB_s"],
            "mean_MiB_s": row["mean_direction_MiB_s"],
            "read_gap_seconds": row["gaps"]["read"]["synchronized_no_record_seconds"],
            "write_gap_seconds": row["gaps"]["write"]["synchronized_no_record_seconds"],
            "mean_total_latency_ms": row["mean_total_latency_ms"],
        })
    write_tsv(root / "analysis-cells.tsv", flat)
    (root / "analysis.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def self_test() -> dict:
    def cell(mean: float, read: float, write: float, latency: float, gaps: float):
        return {"mean_direction_MiB_s": mean, "read": {"bandwidth_MiB_s": read},
                "write": {"bandwidth_MiB_s": write}, "mean_total_latency_ms": latency,
                "mean_synchronized_no_record_seconds": gaps}
    positive = {"A1": cell(100, 100, 100, 10, 20), "B1": cell(120, 120, 120, 8, 10),
                "B2": cell(121, 121, 121, 8, 10), "A2": cell(101, 101, 101, 10, 20)}
    assert decision(positive)["verdict"] == "CONTINUE_CANDIDATE"
    negative = {"A1": cell(100, 100, 100, 10, 20), "B1": cell(85, 85, 85, 12, 25),
                "B2": cell(86, 86, 86, 12, 25), "A2": cell(101, 101, 101, 10, 20)}
    assert decision(negative)["verdict"] == "STOP_NEGATIVE"
    assert runs([2, 3, 7, 8, 9]) == [(2, 3), (7, 9)]
    return {"status": "PASS"}


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("analyze", "self-test"):
        item = sub.add_parser(name); item.add_argument("--root", type=Path); item.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "self-test":
        result = self_test()
    else:
        if args.root is None or args.output is None:
            parser.error("analyze requires --root and --output")
        result = analyze(args.root)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(result.get("verdict", result.get("status")))


if __name__ == "__main__":
    main()
