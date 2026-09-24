#!/usr/bin/env python3
"""Offline second-party analyzer for 06-5's C-R-W-W-R-C matrix.

The primary endpoint is complete fio bytes divided by the actual maximum
directional runtime.  Per-job logs are retained as a separate, overlap-
weighted [15,175) window diagnostic with four 40-second subwindows.  No
environment command is executed by this module.
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import math
import statistics
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEGACY = HERE / "t06-1-randrw-analyze.py"
_spec = importlib.util.spec_from_file_location("t061_helpers", LEGACY)
_legacy = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_legacy)
EvidenceError = _legacy.EvidenceError
aggregate_logs = _legacy.aggregate_logs
window_stats = _legacy.window_stats
percentile = _legacy.percentile

CELLS = ("C1", "R1", "W1", "W2", "R2", "C2")
ARM_FOR = {"C1": "C", "C2": "C", "R1": "R", "R2": "R", "W1": "W", "W2": "W"}
RECOVERY = ("canary", "C1-post", "R1-post", "W1-post", "W2-post", "R2-post", "C2-post")
MIB = 1048576
FORMAL_START = 15
FORMAL_STOP = 175


def _number(value, label):
    try:
        value = float(value)
    except (TypeError, ValueError) as exc:
        raise EvidenceError(f"{label}: not numeric") from exc
    if not math.isfinite(value) or value <= 0:
        raise EvidenceError(f"{label}: non-positive/non-finite")
    return value


def primary_endpoint(cell: Path):
    formal = cell / "formal"
    data = json.loads((formal / "fio.json").read_text())
    jobs = data.get("jobs")
    if not isinstance(jobs, list) or len(jobs) not in (1, 128):
        raise EvidenceError(f"{cell.name}: expected one grouped or 128 per-job JSON records")
    read_bytes = write_bytes = 0
    runtimes = []
    for job in jobs:
        if job.get("error") != 0:
            raise EvidenceError(f"{cell.name}: fio error")
        for direction in ("read", "write"):
            part = job.get(direction, {})
            size = _number(part.get("io_bytes"), f"{cell.name}:{direction}.io_bytes")
            runtime = _number(part.get("runtime"), f"{cell.name}:{direction}.runtime")
            if not size.is_integer():
                raise EvidenceError(f"{cell.name}:{direction}.io_bytes not integer")
            if direction == "read":
                read_bytes += int(size)
            else:
                write_bytes += int(size)
            runtimes.append(runtime)
    runtime_ms = max(runtimes)
    runtime_s = runtime_ms / 1000.0
    if runtime_s < 179.0 or runtime_s > 320.0:
        raise EvidenceError(f"{cell.name}: runtime outside 180-second contract: {runtime_s}")
    end_ns = int((formal / "fio-end-epoch-ns.txt").read_text().strip())
    registered_ns = int((formal / "fio-start-epoch-ns.txt").read_text().strip())
    actual_ns = end_ns - int(runtime_ms * 1_000_000)
    delta_s = (actual_ns - registered_ns) / 1e9
    if registered_ns > actual_ns + 2_000_000_000:
        raise EvidenceError(f"{cell.name}: registered start follows actual start")
    return {
        "runtime_s": runtime_s,
        "actual_io_start_epoch_ns": actual_ns,
        "fio_end_epoch_ns": end_ns,
        "actual_minus_registered_start_s": delta_s,
        "directional": {
            "read": {"io_bytes": read_bytes, "MiB_s": read_bytes / runtime_s / MIB},
            "write": {"io_bytes": write_bytes, "MiB_s": write_bytes / runtime_s / MIB},
        },
    }


def optional_windows(cell: Path, runtime_s):
    logs = sorted((cell / "formal" / "bw").glob("randrw_bw.*.log"))
    if len(logs) != 128:
        raise EvidenceError(f"{cell.name}: expected 128 bw logs, got {len(logs)}")
    series = aggregate_logs(logs, runtime_s)
    return {"read": window_stats(series[0]), "write": window_stats(series[1])}


def recovery_result(root: Path, name: str):
    recovery = root / "recovery" / name
    if not (recovery / "PASS").is_file():
        raise EvidenceError(f"recovery {name}: PASS marker missing")
    rows = []
    import csv
    with (recovery / "gate.tsv").open() as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    if len(rows) < 4:
        raise EvidenceError(f"recovery {name}: fewer than four gate samples")
    tail = rows[-3:]
    objects = [int(row["objects"]) for row in tail]
    stored = [int(row["stored"]) for row in tail]
    if len(set(objects)) != 1 or max(stored) - min(stored) > 16 * MIB:
        raise EvidenceError(f"recovery {name}: object/stored tail not stable")
    for row in tail:
        if any(int(row[key]) != 0 for key in ("pending_150", "pending_151", "pending_152")):
            raise EvidenceError(f"recovery {name}: TiKV pending is nonzero")
    return {"label": name, "samples": len(rows), "objects": objects[-1], "stored": stored[-1]}


def cell_result(root: Path, name: str):
    cell = root / "cells" / name
    if not (cell / "PASS").is_file():
        raise EvidenceError(f"{name}: PASS marker missing")
    if (cell / "formal" / "fio.rc").read_text().strip() != "0":
        raise EvidenceError(f"{name}: formal fio rc is not zero")
    primary = primary_endpoint(cell)
    windows = optional_windows(cell, primary["runtime_s"])
    return {"cell": name, "arm": ARM_FOR[name], "primary": primary, "windows": windows,
            "nonperformance_errors": []}


def _gain(numerator, denominator):
    return (numerator / denominator - 1.0) * 100.0


def _direction_effect(rows, numerator, denominator, direction):
    by = {row["cell"]: row for row in rows}
    values = lambda cell: by[cell]["primary"]["directional"][direction]["MiB_s"]
    pairs = [_gain(values(numerator + str(i)), values(denominator + str(i))) for i in (1, 2)]
    drift = {arm: _gain(values(arm + "2"), values(arm + "1")) for arm in ("C", "R", "W")}
    epsilon = max(abs(value) for value in drift.values())
    material = max(5.0, 2.0 * epsilon)
    positive = all(value >= material for value in pairs)
    negative = all(value <= -material for value in pairs)
    return {"paired_effects_pct": pairs, "same_arm_change_pct": drift,
            "epsilon_pct": epsilon, "M_pct": material,
            "material_positive": positive, "material_negative": negative,
            "same_sign": (positive or negative)}


def decide(rows):
    errors = [row["cell"] for row in rows if row.get("nonperformance_errors")]
    if len(rows) != len(CELLS) or {row["cell"] for row in rows} != set(CELLS):
        return {"RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "FINAL_STATE": "PAUSED_INCONCLUSIVE",
                "errors": ["missing_or_duplicate_cell"]}
    effects = {}
    for label, numerator, denominator in (("R/C", "R", "C"), ("W/R", "W", "R"), ("W/C", "W", "C")):
        effects[label] = {direction: _direction_effect(rows, numerator, denominator, direction)
                          for direction in ("read", "write")}
    epsilon = max(detail["epsilon_pct"] for effect in effects.values() for detail in effect.values())
    material = max(5.0, 2.0 * epsilon)
    if errors:
        validity, final = "EVIDENCE_INVALID", "PAUSED_INCONCLUSIVE"
    elif epsilon >= 5.0:
        validity, final = "RESOLUTION_INSUFFICIENT", "PAUSED_INCONCLUSIVE"
    else:
        def positive(label):
            return all(effects[label][d]["material_positive"] for d in ("read", "write"))
        wc, rc, wr = positive("W/C"), positive("R/C"), positive("W/R")
        if wc and rc and not wr:
            final = "RESOLVED_CACHE_PATH"
        elif wc and wr:
            final = "RESOLVED_WRITEBACK_BURST"
        elif wc and not rc and not wr:
            final = "RESOLVED_INTERACTION_ONLY"
        elif not wc:
            final = "RESOLVED_STATE_DEPENDENT_NO_DELIVERABLE"
        else:
            final = "PAUSED_INCONCLUSIVE"
        validity = "VALID"
    return {"RUN_VALIDITY_STATE": validity, "FINAL_STATE": final,
            "epsilon_pct": epsilon, "M_pct": material, "effects": effects,
            "errors": errors,
            "formula": "endpoint = complete direction bytes / max(read,write actual runtime); M=max(5%,2epsilon)"}


def analyze(root: Path):
    rows, errors = [], []
    recovery = []
    if not (root / "PHASE_PASS").is_file():
        errors.append("PHASE_PASS missing")
    if not (root / "scrub-restore.txt").is_file() or (root / "STOP-SCRUB-RESTORE-FAILED").exists():
        errors.append("scrub restoration not proven")
    for name in RECOVERY:
        try:
            recovery.append(recovery_result(root, name))
        except (EvidenceError, OSError, ValueError) as exc:
            errors.append(str(exc))
    for name in CELLS:
        try:
            rows.append(cell_result(root, name))
        except (EvidenceError, OSError, ValueError, json.JSONDecodeError) as exc:
            errors.append(f"{name}: {exc}")
    if errors:
        return {"schema": 1, "cells": rows, "recovery": recovery, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID",
                "FINAL_STATE": "PAUSED_INCONCLUSIVE", "errors": errors}
    result = decide(rows)
    result.update({"schema": 1, "cells": rows, "recovery": recovery, "formal_window": "[15,175)",
                   "four_windows": "W1-W4=40s each"})
    return result


def _fixture(root: Path, rates=None):
    rates = rates or {"C1": 100, "R1": 110, "W1": 111, "W2": 112, "R2": 111, "C2": 101}
    for index, name in enumerate(CELLS):
        cell = root / "cells" / name
        (cell / "formal" / "bw").mkdir(parents=True)
        (cell / "formal" / "fio.rc").write_text("0\n")
        rate = rates[name]
        end = 2_000_000_000_000 + index * 300_000_000_000 + 180_000_000_000
        start = end - 180_000_000_000
        data = {"jobs": [{"error": 0, "read": {"io_bytes": rate * 180 * MIB, "runtime": 180000},
                           "write": {"io_bytes": rate * 180 * MIB, "runtime": 180000}}]}
        (cell / "formal" / "fio.json").write_text(json.dumps(data))
        (cell / "formal" / "fio-start-epoch-ns.txt").write_text(str(start))
        (cell / "formal" / "fio-end-epoch-ns.txt").write_text(str(end))
        (cell / "PASS").write_text("CELL_RAW_PASS\n")
        rows = "".join(f"{second * 1000},{rate * 1024},0\n{second * 1000},{rate * 1024},1\n"
                        for second in range(1, 181))
        for job in range(1, 129):
            (cell / "formal" / "bw" / f"randrw_bw.{job}.log").write_text(rows)
    (root / "PHASE_PASS").write_text("PHASE_RAW_PASS\n")
    (root / "scrub-restore.txt").write_text("RESTORE_PASS\n")
    for index, name in enumerate(RECOVERY):
        directory = root / "recovery" / name
        directory.mkdir(parents=True)
        (directory / "PASS").write_text("RECOVERY_GATE_PASS\n")
        body = "sample\tobjects\tstored\tpending_150\tpending_151\tpending_152\n"
        body += "".join(f"{sample}\t{2_000_000 + index}\t523000000000\t0\t0\t0\n" for sample in range(1, 5))
        (directory / "gate.tsv").write_text(body)


def self_test():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _fixture(root)
        result = analyze(root)
        assert result["RUN_VALIDITY_STATE"] == "VALID"
        assert result["FINAL_STATE"] == "RESOLVED_CACHE_PATH"
        assert abs(result["effects"]["R/C"]["read"]["paired_effects_pct"][0] - 10.0) < 1e-9
        assert result["effects"]["W/R"]["write"]["paired_effects_pct"][0] < 5.0
        assert result["cells"][0]["windows"]["read"]["formal_seconds"] == 160
        noisy = copy.deepcopy(result["cells"])
        for row in noisy:
            if row["cell"] == "C2":
                row["primary"]["directional"]["read"]["MiB_s"] *= 1.10
                row["primary"]["directional"]["write"]["MiB_s"] *= 1.10
        assert decide(noisy)["RUN_VALIDITY_STATE"] == "RESOLUTION_INSUFFICIENT"
    return {"status": "PASS", "checks": ["C-R-W-W-R-C_matrix", "actual_runtime_endpoint",
            "overlap_weighted_four_windows", "R/C_W/R_W/C_effects", "epsilon_and_M", "noise_gate"]}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    run = sub.add_parser("analyze")
    run.add_argument("--root", required=True, type=Path)
    run.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = self_test() if args.command == "self-test" else analyze(args.root)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if getattr(args, "output", None):
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    else:
        print(text, end="")
    if result.get("RUN_VALIDITY_STATE") == "EVIDENCE_INVALID":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
