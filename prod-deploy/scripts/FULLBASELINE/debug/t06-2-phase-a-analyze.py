#!/usr/bin/env python3
"""Fail-closed analyzer for 06-2 Phase A ABBA evidence."""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import pathlib
import re
import statistics

CELLS = ("C1", "T1", "T2", "C2")
EXPECTED = {
    "C1": ("50533485977e187146c53b2cf2497b929df70b590a8a6b655a32c9e8c8d94dc9", "c8f4ba0cbd0b2e8a555bc2c55366a88409fa4371"),
    "C2": ("50533485977e187146c53b2cf2497b929df70b590a8a6b655a32c9e8c8d94dc9", "c8f4ba0cbd0b2e8a555bc2c55366a88409fa4371"),
    "T1": ("a83343bc62e023f090a99d37872665516429765055968349de6eaefb2a81fc76", "c165d294839fd49ec31d4e2d2c999bc08db25939"),
    "T2": ("a83343bc62e023f090a99d37872665516429765055968349de6eaefb2a81fc76", "c165d294839fd49ec31d4e2d2c999bc08db25939"),
}
COUNTERS = (
    "instrument_read_flush_wait_seconds_total", "instrument_read_total_wait_seconds_total",
    "instrument_read_calls_total", "instrument_flush_calls_total", "instrument_flush_errors_total",
    "instrument_dependency_wait_seconds_total", "instrument_dependency_wait_events_total",
    "instrument_slice_new_id_errors_total", "instrument_slice_finish_errors_total",
    "instrument_meta_write_errors_total", "staging_block_errors",
)
HISTOGRAMS = (
    "instrument_flush_duration_seconds", "instrument_flush_scope_chunks",
    "instrument_flush_scope_slices", "instrument_flush_scope_unfrozen_slices",
    "instrument_flush_scope_dep_edges", "instrument_flush_scope_dep_closure_depth",
    "instrument_flush_scope_extra_chunks",
)


def load_common(path: pathlib.Path):
    spec = importlib.util.spec_from_file_location("gate2b_common", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load common analyzer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def labeled_sum(path: pathlib.Path, name: str, method: str | None = None) -> float:
    value = 0.0
    found = False
    for line in path.read_text(errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        token, *rest = line.split()
        metric_name = token.split("{", 1)[0]
        if len(rest) != 1 or not (metric_name == name or metric_name.endswith("_" + name)):
            continue
        if method is not None and not re.search(rf'(?:^|,)method="{re.escape(method)}"(?:,|$)', token[token.find("{") + 1: token.rfind("}")]):
            continue
        value += float(rest[0]); found = True
    if not found:
        raise ValueError(f"missing metric {name} method={method}")
    return value


def metric_delta(pre: pathlib.Path, post: pathlib.Path, name: str, method: str | None = None) -> float:
    value = labeled_sum(post, name, method) - labeled_sum(pre, name, method)
    if value < 0:
        raise ValueError(f"counter reset {name} method={method}")
    return value


def fio_actual_window(cell: pathlib.Path) -> tuple[int, int, float]:
    data = json.loads((cell / "formal/fio.json").read_text())
    runtimes = [float(job[d]["runtime"]) / 1000 for job in data["jobs"] for d in ("read", "write") if float(job[d]["runtime"]) > 0]
    runtime = max(runtimes)
    end = int((cell / "formal/fio-end-epoch-ns.txt").read_text())
    actual = end - int(runtime * 1e9)
    return actual + 15_000_000_000, actual + 175_000_000_000, runtime


def live_identity(cell: pathlib.Path, name: str) -> dict:
    rows = (cell / "binary-live.tsv").read_text().splitlines()
    if len(rows) != 2:
        raise ValueError(f"{name}: invalid binary identity rows")
    keys = rows[0].split("\t"); vals = rows[1].split("\t"); data = dict(zip(keys, vals))
    sha, build = EXPECTED[name]
    if data.get("cell") != name or data.get("sha256") != sha or data.get("gnu_build_id") != build:
        raise ValueError(f"{name}: binary identity mismatch")
    return data


def sample_coverage(cell: pathlib.Path) -> dict:
    rows = (cell / "formal/sampler-coverage.tsv").read_text().splitlines()
    if len(rows) != 2:
        raise ValueError(f"{cell.name}: sampler coverage missing")
    values = rows[1].split("\t")
    result = {"samples": int(values[0]), "start_lag_s": float(values[1]), "end_lag_s": float(values[2]), "max_gap_s": float(values[3])}
    if result["samples"] < 170 or result["start_lag_s"] > 1.5 or result["end_lag_s"] > 1.5 or result["max_gap_s"] > 1.5:
        raise ValueError(f"{cell.name}: sampler coverage failed")
    return result


def uploading_stats(cell: pathlib.Path, start_ns: int, stop_ns: int) -> dict:
    values = []
    for path in (cell / "formal").glob("metrics-*.prom"):
        match = re.fullmatch(r"metrics-(\d+)\.prom", path.name)
        if match and start_ns <= int(match.group(1)) < stop_ns:
            values.append(labeled_sum(path, "juicefs_object_request_uploading"))
    if len(values) < 150:
        raise ValueError(f"{cell.name}: uploading formal samples {len(values)}")
    ordered = sorted(values)
    def pct(q):
        return ordered[min(len(ordered) - 1, math.ceil(q * len(ordered)) - 1)]
    return {"samples": len(values), "mean": statistics.mean(values), "p95": pct(.95), "max": max(values)}


def boundary_metrics(cell: pathlib.Path, start_ns: int, stop_ns: int) -> tuple[pathlib.Path, pathlib.Path, dict]:
    rows = []
    for path in (cell / "formal").glob("metrics-*.prom"):
        match = re.fullmatch(r"metrics-(\d+)\.prom", path.name)
        if match:
            rows.append((int(match.group(1)), path))
    before = [row for row in rows if row[0] <= start_ns]
    after = [row for row in rows if row[0] >= stop_ns]
    if not before or not after:
        raise ValueError(f"{cell.name}: formal boundary metrics missing")
    left = max(before); right = min(after)
    lag_left = (start_ns - left[0]) / 1e9; lag_right = (right[0] - stop_ns) / 1e9
    if lag_left > 1.5 or lag_right > 1.5:
        raise ValueError(f"{cell.name}: formal boundary metrics gap")
    return left[1], right[1], {"start_lag_s": lag_left, "stop_lag_s": lag_right,
                              "effective_window_s": (right[0] - left[0]) / 1e9}


def auxiliary_sampler_gate(cell: pathlib.Path, start_ns: int, stop_ns: int) -> dict:
    if (cell / "formal/sampler.rc").read_text().strip() != "0":
        raise ValueError(f"{cell.name}: sampler rc nonzero")
    result = {}
    for filename in ("df-1hz.tsv", "meminfo-1hz.tsv"):
        lines = [line for line in (cell / "formal" / filename).read_text().splitlines()[1:] if line]
        epochs = [int(line.split("\t", 1)[0]) for line in lines]
        selected = [value for value in epochs if start_ns <= value < stop_ns]
        if len(selected) < 150:
            raise ValueError(f"{cell.name}: {filename} formal coverage {len(selected)}")
        result[filename] = len(selected)
    ratios = []
    for line in (cell / "formal/df-1hz.tsv").read_text().splitlines()[1:]:
        fields = line.split("\t")
        if len(fields) == 4 and start_ns <= int(fields[0]) < stop_ns:
            ratios.append(int(fields[3]) / int(fields[2]))
    if not ratios or min(ratios) < .10:
        raise ValueError(f"{cell.name}: cache stageFull/free-space gate")
    result["min_available_ratio"] = min(ratios)
    return result


def analyze_cell(common, root: pathlib.Path, name: str) -> dict:
    cell = root / "phase-a/cells" / name
    if not (cell / "SHA256SUMS").is_file() or (cell / "formal/fio.rc").read_text().strip() != "0":
        raise ValueError(f"{name}: raw cell did not pass")
    identity = live_identity(cell, name)
    coverage = sample_coverage(cell)
    evidence_errors = []
    try:
        bandwidth = common.aggregate_bw_logs(cell)
    except ValueError as exc:
        bandwidth = None
        evidence_errors.append(str(exc))
    fio = common.fio_summary(cell / "formal/fio.json")
    start_ns, stop_ns, runtime = fio_actual_window(cell)
    if not 179 <= runtime <= 182:
        evidence_errors.append(f"{name}: fio runtime outside contract: {runtime}")
    pre, post, metric_window = boundary_metrics(cell, start_ns, stop_ns)
    auxiliary = auxiliary_sampler_gate(cell, start_ns, stop_ns)
    counters = {metric: metric_delta(pre, post, metric) for metric in COUNTERS}
    histograms = {metric: common.histogram_delta(pre, post, metric) for metric in HISTOGRAMS}
    intervals = common.analyze_intervals(cell / "read-intervals.tsv.gz", start_ns, stop_ns)
    object_stats = {}
    metric_seconds = metric_window["effective_window_s"]
    for method in ("GET", "PUT"):
        object_stats[method] = {
            "requests": metric_delta(pre, post, "juicefs_object_request_durations_histogram_seconds_count", method),
            "bytes": metric_delta(pre, post, "juicefs_object_request_data_bytes", method),
        }
        object_stats[method]["ops_s"] = object_stats[method]["requests"] / metric_seconds
        object_stats[method]["mib_s"] = object_stats[method]["bytes"] / metric_seconds / 1048576
    errors = sum(counters[k] for k in COUNTERS if k.endswith("errors_total") or k == "staging_block_errors")
    if errors != 0 or intervals["overflow"] != 0 or intervals["invalid"] != 0:
        raise ValueError(f"{name}: instrumentation/staging/interval error")
    return {
        "cell": name, "identity": identity, "sampler": coverage, "runtime_s": runtime,
        "metric_window": metric_window,
        "auxiliary_sampler": auxiliary,
        "bandwidth": bandwidth, "fio_summary": fio, "counters": counters,
        "histograms": histograms, "intervals": intervals, "objects": object_stats,
        "uploading": uploading_stats(cell, start_ns, stop_ns),
        "drain_seconds": int((cell / "drain-seconds.txt").read_text()),
        "evidence_errors": evidence_errors,
    }


def decision(cells: list[dict]) -> dict:
    by = {x["cell"]: x for x in cells}
    effects = {}
    noise = []
    valid_bandwidth = all(x["bandwidth"] is not None for x in cells)
    if valid_bandwidth:
        for direction in ("read", "write"):
            v = lambda c: by[c]["bandwidth"][direction]["mean_mib_s"]
            effects[direction] = {"T1_over_C1_pct": (v("T1") / v("C1") - 1) * 100,
                                  "T2_over_C2_pct": (v("T2") / v("C2") - 1) * 100}
            noise.extend((abs(v("C2") / v("C1") - 1) * 100, abs(v("T2") / v("T1") - 1) * 100))
        epsilon = max(noise); margin = max(5.0, 2 * epsilon)
        paired = [v for x in effects.values() for v in x.values()]
    else:
        epsilon = None; margin = None; paired = []
    descriptive = {}
    for direction in ("read", "write"):
        key = direction + "_mib_s"
        v = lambda c: by[c]["fio_summary"][key]
        descriptive[direction] = {"T1_over_C1_pct": (v("T1") / v("C1") - 1) * 100,
                                  "T2_over_C2_pct": (v("T2") / v("C2") - 1) * 100}
    scope = {c: by[c]["histograms"]["instrument_flush_scope_chunks"]["mean"] for c in CELLS}
    flush = {c: by[c]["counters"]["instrument_read_flush_wait_seconds_total"] / max(1, by[c]["counters"]["instrument_read_calls_total"]) for c in CELLS}
    mechanism = (scope["T1"] < scope["C1"] and scope["T2"] < scope["C2"] and
                 flush["T1"] < flush["C1"] and flush["T2"] < flush["C2"])
    if any(x["evidence_errors"] for x in cells):
        state, verdict = "EVIDENCE_INVALID", "NO_DECISION"
    elif epsilon >= 5:
        state, verdict = "RESOLUTION_INSUFFICIENT", "NO_DECISION"
    elif all(x >= margin for x in paired) and mechanism:
        state, verdict = "VALID", "SCREEN_CONTINUE"
    elif all(x <= -margin for x in paired):
        state, verdict = "VALID", "MATERIAL_REGRESSION"
    elif all(x >= 0 for x in paired) or all(x <= 0 for x in paired):
        state, verdict = "VALID", "NO_MATERIAL_BENEFIT"
    else:
        state, verdict = "INCONCLUSIVE", "NO_DECISION"
    return {"effects_pct": effects, "fio_summary_descriptive_effects_pct": descriptive,
            "epsilon_pct": epsilon, "M_pct": margin,
            "scope_chunks_mean": scope, "flush_wait_per_read_s": flush,
            "mechanism_both_pairs_improved": mechanism,
            "RUN_VALIDITY_STATE": state, "SCREEN_DECISION": verdict,
            "PHASE_B": "TRIGGERED" if verdict == "SCREEN_CONTINUE" else "NOT_TRIGGERED"}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("root", type=pathlib.Path)
    p.add_argument("--common", type=pathlib.Path, required=True)
    args = p.parse_args()
    common = load_common(args.common)
    cells = [analyze_cell(common, args.root, name) for name in CELLS]
    result = {"schema": 1, "formal_window": "[15,175)", "cells": cells, "decision": decision(cells)}
    out = args.root / "phase-a/analysis"
    out.mkdir(mode=0o700, exist_ok=False)
    (out / "phase-a-analysis.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
