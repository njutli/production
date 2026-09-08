#!/usr/bin/env python3
"""04-tmp2j final-window curve analysis; reuses the signed 04-tmp2i parser."""
import argparse
import importlib.util
import json
import math
import statistics
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE_PATH = HERE / "t04tmp2i-randrw-analyze.py"
spec = importlib.util.spec_from_file_location("tmp2i_base", BASE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load 04-tmp2i analyzer")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

ORDER = ("A0-pre", "C32", "C128", "C64", "A0-mid", "C256", "C96", "A0-post")
CAPACITIES = (32, 64, 96, 128, 256)
POSITIONS = {name: index for index, name in enumerate(ORDER)}


def formal_cell(root, name):
    row = base.analyze_cell(Path(root), name)
    for direction in ("read", "write"):
        stats = row["bandwidth"][direction]
        stats["fio_summary_MiBs"] = stats["mean_MiBs"]
        stats["mean_MiBs"] = stats["bwlog_observed_mean_MiBs"]
    row["mean_direction_MiBs"] = statistics.mean(
        row["bandwidth"][d]["mean_MiBs"] for d in ("read", "write")
    )
    runtime = base._tsv(Path(root) / "cells" / name / "runtime.tsv")
    start_ns = row["fio"]["start_ns"]
    selected = [r for r in runtime if start_ns + base.FORMAL_START * 1e9 <= base._first(r, ("epoch_ns",)) < start_ns + base.FORMAL_STOP * 1e9]
    if len(selected) >= 2:
        required = ("nic_rx_bytes", "nic_tx_bytes", "cache_read_ios", "cache_write_ios",
                    "cache_read_sectors", "cache_write_sectors", "cache_read_ms",
                    "cache_write_ms", "cache_io_ms", "cache_weighted_io_ms")
        if any(base._first(r, (field,)) is None for r in (selected[0], selected[-1]) for field in required):
            raise base.EvidenceError(f"{name}: NIC/cache-device runtime counters missing")
        elapsed = (base._first(selected[-1], ("epoch_ns",)) - base._first(selected[0], ("epoch_ns",))) / 1e9
        def delta(field):
            return base._first(selected[-1], (field,)) - base._first(selected[0], (field,))
        rios, wios = delta("cache_read_ios"), delta("cache_write_ios")
        row["metrics"].update({
            "nic_rx_MiBs": delta("nic_rx_bytes") / elapsed / 1048576.0,
            "nic_tx_MiBs": delta("nic_tx_bytes") / elapsed / 1048576.0,
            "cache_read_MiBs": delta("cache_read_sectors") * 512.0 / elapsed / 1048576.0,
            "cache_write_MiBs": delta("cache_write_sectors") * 512.0 / elapsed / 1048576.0,
            "cache_await_ms": (delta("cache_read_ms") + delta("cache_write_ms")) / (rios + wios) if rios + wios else 0.0,
            "cache_util_pct": delta("cache_io_ms") / (elapsed * 1000.0) * 100.0,
        })
    return row


def rel(value, reference):
    return (value / reference - 1.0) * 100.0


def anchor_reference(rows, name, direction):
    values = {row["cell"]: row for row in rows}
    pos = POSITIONS[name]
    if pos < POSITIONS["A0-mid"]:
        left, right = "A0-pre", "A0-mid"
    else:
        left, right = "A0-mid", "A0-post"
    lp, rp = POSITIONS[left], POSITIONS[right]
    fraction = (pos - lp) / (rp - lp)
    def value(anchor):
        if direction == "mean":
            return values[anchor]["mean_direction_MiBs"]
        return values[anchor]["bandwidth"][direction]["mean_MiBs"]
    return value(left) + fraction * (value(right) - value(left))


def analyze(root):
    root = Path(root)
    rows = [formal_cell(root, name) for name in ORDER]
    by_name = {row["cell"]: row for row in rows}
    anchors = ("A0-pre", "A0-mid", "A0-post")
    drift_values = []
    for direction in ("read", "write", "mean"):
        vals = []
        for name in anchors:
            row = by_name[name]
            vals.append(row["mean_direction_MiBs"] if direction == "mean" else
                        row["bandwidth"][direction]["mean_MiBs"])
        drift_values.extend(abs(rel(a, b)) for i, a in enumerate(vals) for b in vals[i + 1:])
    drift = max(drift_values)
    margin = max(5.0, drift)
    points = []
    for capacity in CAPACITIES:
        name = f"C{capacity}"
        row = by_name[name]
        effects = {}
        refs = {}
        for direction in ("read", "write", "mean"):
            value = row["mean_direction_MiBs"] if direction == "mean" else row["bandwidth"][direction]["mean_MiBs"]
            reference = anchor_reference(rows, name, direction)
            refs[direction] = reference
            effects[direction] = rel(value, reference)
        points.append({
            "cell": name, "capacity_GiB": capacity,
            "read_MiBs": row["bandwidth"]["read"]["mean_MiBs"],
            "write_MiBs": row["bandwidth"]["write"]["mean_MiBs"],
            "mean_direction_MiBs": row["mean_direction_MiBs"],
            "reference_MiBs": refs, "effect_pct": effects,
            "hit_ratio": row["metrics"]["hit_ratio"],
            "blockcache_peak_bytes": row["metrics"]["blockcache_peak_bytes"],
            "evicts_delta": row["metrics"]["evicts_delta"],
            "drops_delta": row["metrics"]["drops_delta"],
        })
    best_factor = max(1.0 + p["effect_pct"]["mean"] / 100.0 for p in points)
    platform = None
    for point in points:
        factor = 1.0 + point["effect_pct"]["mean"] / 100.0
        no_material_below_best = rel(factor, best_factor) >= -margin
        no_direction_regression = min(point["effect_pct"]["read"], point["effect_pct"]["write"]) >= -margin
        larger = [p for p in points if p["capacity_GiB"] > point["capacity_GiB"]]
        no_larger_gain = all(rel(1.0 + p["effect_pct"]["mean"] / 100.0, factor) <= margin for p in larger)
        if no_material_below_best and no_direction_regression and no_larger_gain:
            platform = point["capacity_GiB"]
            break
    validity = "VALID" if drift <= 8.0 else "RESOLUTION_INSUFFICIENT"
    return {
        "status": "PASS", "validity_state": validity, "curve_state": "CURVE_COMPLETE",
        "A0_drift_pct": drift, "M_pct": margin, "platform_GiB": platform,
        "formal_window_seconds": [base.FORMAL_START, base.FORMAL_STOP],
        "order": list(ORDER), "points": points, "cells": rows,
    }


def write_summary(result, path):
    with Path(path).open("w") as handle:
        handle.write("cell\tcapacity_gib\tread_mib_s\twrite_mib_s\tmean_direction_mib_s\tread_effect_pct\twrite_effect_pct\tmean_effect_pct\thit_ratio\n")
        for p in result["points"]:
            handle.write(f'{p["cell"]}\t{p["capacity_GiB"]}\t{p["read_MiBs"]:.6f}\t{p["write_MiBs"]:.6f}\t{p["mean_direction_MiBs"]:.6f}\t{p["effect_pct"]["read"]:.6f}\t{p["effect_pct"]["write"]:.6f}\t{p["effect_pct"]["mean"]:.6f}\t{p["hit_ratio"]:.9f}\n')


def self_test(root):
    root = Path(root)
    if root.exists():
        raise base.EvidenceError("fixture root exists")
    for index, name in enumerate(ORDER):
        value = 100.0 if name.startswith("A0-") else 100.0 + int(name[1:]) / 32.0
        cell = root / "cells" / name
        base._fixture_cell(cell, value, value)
        runtime = cell / "runtime.tsv"
        lines = runtime.read_text().splitlines()
        extra = ("nic_rx_bytes", "nic_tx_bytes", "cache_read_ios", "cache_write_ios",
                 "cache_read_sectors", "cache_write_sectors", "cache_read_ms",
                 "cache_write_ms", "cache_io_ms", "cache_weighted_io_ms")
        rewritten = [lines[0] + "\t" + "\t".join(extra)]
        for sec, line in enumerate(lines[1:]):
            rewritten.append(line + "\t" + "\t".join(str(sec * (i + 1)) for i in range(len(extra))))
        runtime.write_text("\n".join(rewritten) + "\n")
    result = analyze(root)
    if result["validity_state"] != "VALID" or len(result["points"]) != 5:
        raise base.EvidenceError("curve fixture failed")
    sparse = root / "cells" / "C32" / "runtime.tsv"
    lines = sparse.read_text().splitlines()
    sparse.write_text("\n".join(lines[:20]) + "\n")
    try:
        analyze(root)
    except base.EvidenceError:
        pass
    else:
        raise base.EvidenceError("sparse sampler accepted")
    trend = {sec: 100.0 + sec * 0.2 for sec in range(300)}
    nominal = base.bandwidth_window(trend, 15, 175)["mean_MiBs"]
    plus_one = base.bandwidth_window(trend, 16, 176)["mean_MiBs"]
    plus_58 = base.bandwidth_window(trend, 73, 233)["mean_MiBs"]
    if abs(rel(plus_one, nominal)) >= 1.0:
        raise base.EvidenceError("one-second sensitivity fixture failed")
    if abs(rel(plus_58, nominal)) <= 5.0:
        raise base.EvidenceError("58-second sensitivity fixture failed")
    return {"status": "PASS", "cells": len(ORDER), "points": len(CAPACITIES),
            "sensitivity": {"plus_1_pct": rel(plus_one, nominal),
                            "plus_58_pct": rel(plus_58, nominal)}}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("analyze"); p.add_argument("--root", required=True); p.add_argument("--output", required=True); p.add_argument("--summary")
    p = sub.add_parser("validate-cell"); p.add_argument("--root", required=True); p.add_argument("--name", required=True); p.add_argument("--output", required=True)
    p = sub.add_parser("cell-summary"); p.add_argument("--cell", required=True); p.add_argument("--output", required=True)
    p = sub.add_parser("self-test"); p.add_argument("--root", required=True); p.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.command == "analyze":
        result = analyze(args.root)
        if args.summary: write_summary(result, args.summary)
    elif args.command == "validate-cell":
        result = formal_cell(args.root, args.name)
    elif args.command == "cell-summary":
        row = formal_cell(Path(args.cell).parents[1], Path(args.cell).name)
        result = {"cell": row["cell"], "read_mib_s": row["bandwidth"]["read"]["mean_MiBs"],
                  "write_mib_s": row["bandwidth"]["write"]["mean_MiBs"],
                  "mean_direction_mib_s": row["mean_direction_MiBs"]}
    else:
        result = self_test(args.root)
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
