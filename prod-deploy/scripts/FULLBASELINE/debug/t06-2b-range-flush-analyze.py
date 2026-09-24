#!/usr/bin/env python3
"""Independent 06-2b H/C/T six-cell recomputation."""
import json
import math
import pathlib
import sys

CELLS = ("H0", "C1", "T1", "T2", "C2", "H1")


def fail(message):
    raise SystemExit("T062B_ANALYZE_FAIL\t" + message)


def parse_cell(root, cell):
    base = root / "cells" / cell
    required = (base / "PASS", base / "formal" / "fio.json", base / "formal" / "fio.rc")
    if not all(p.is_file() for p in required):
        fail(f"missing_cell_evidence:{cell}")
    if (base / "formal" / "fio.rc").read_text().strip() != "0":
        fail(f"fio_rc:{cell}")
    if len(list((base / "formal" / "bw").glob("randrw_bw.*.log"))) != 128:
        fail(f"bw_log_count:{cell}")
    data = json.loads((base / "formal" / "fio.json").read_text())
    jobs = data.get("jobs") or []
    if len(jobs) != 1:
        fail(f"fio_group_count:{cell}:{len(jobs)}")
    job = jobs[0]
    if int(job.get("error", 0)) != 0:
        fail(f"fio_job_error:{cell}")
    read, write = job.get("read", {}), job.get("write", {})
    runtime_ms = max(float(read.get("runtime", 0)), float(write.get("runtime", 0)))
    if not 175000 <= runtime_ms <= 210000:
        fail(f"runtime_contract:{cell}:{runtime_ms}")
    result = {"cell": cell, "runtime_s": runtime_ms / 1000.0}
    for direction, values in (("read", read), ("write", write)):
        io_bytes = int(values.get("io_bytes", 0))
        if io_bytes <= 0:
            fail(f"zero_bytes:{cell}:{direction}")
        result[direction + "_bytes"] = io_bytes
        result[direction + "_MiB_s"] = io_bytes / (runtime_ms / 1000.0) / 2**20
    return result


def effect(numerator, denominator):
    return numerator / denominator - 1.0


def analyze(root):
    if not (root / "PHASE_PASS").is_file():
        fail("phase_not_pass")
    rows = {cell: parse_cell(root, cell) for cell in CELLS}
    effects = {}
    for direction in ("read", "write"):
        key = direction + "_MiB_s"
        effects[f"T1_over_C1_{direction}"] = effect(rows["T1"][key], rows["C1"][key])
        effects[f"T2_over_C2_{direction}"] = effect(rows["T2"][key], rows["C2"][key])
    eps = max(
        abs(effect(rows["C2"][d + "_MiB_s"], rows["C1"][d + "_MiB_s"]))
        for d in ("read", "write")
    )
    eps = max(eps, *(abs(effect(rows["T2"][d + "_MiB_s"], rows["T1"][d + "_MiB_s"])) for d in ("read", "write")))
    materiality = max(0.05, 2.0 * eps)
    screen_continue = all(v > 0 and v >= materiality for v in effects.values())
    means = {}
    for build, cells in (("H", ("H0", "H1")), ("C", ("C1", "C2")), ("T", ("T1", "T2"))):
        for direction in ("read", "write"):
            means[f"{build}_{direction}_MiB_s"] = sum(rows[c][direction + "_MiB_s"] for c in cells) / 2
    return {
        "schema": "06-2b-analysis-v1",
        "cells": [rows[c] for c in CELLS],
        "effects": effects,
        "epsilon": eps,
        "materiality": materiality,
        "screen_continue": screen_continue,
        "means": means,
    }


def write_outputs(result, output):
    output.mkdir(parents=True, exist_ok=False)
    (output / "analysis.json").write_text(json.dumps(result, indent=2) + "\n")
    with (output / "cells.tsv").open("w") as f:
        f.write("cell\truntime_s\tread_bytes\twrite_bytes\tread_MiB_s\twrite_MiB_s\n")
        for row in result["cells"]:
            f.write(f"{row['cell']}\t{row['runtime_s']:.6f}\t{row['read_bytes']}\t{row['write_bytes']}\t{row['read_MiB_s']:.6f}\t{row['write_MiB_s']:.6f}\n")
    with (output / "verdict.txt").open("w") as f:
        f.write("SCREEN_CONTINUE\n" if result["screen_continue"] else "SCREEN_STOP\n")
        f.write(f"epsilon={result['epsilon']:.8f}\nmateriality={result['materiality']:.8f}\n")
        for key, value in sorted(result["effects"].items()):
            f.write(f"{key}={value:.8f}\n")


def self_test():
    # Pure arithmetic fixture: 20% T gain, 1% repeated-position drift.
    c1, c2, t1, t2 = 100.0, 101.0, 120.0, 121.2
    eps = max(abs(effect(c2, c1)), abs(effect(t2, t1)))
    threshold = max(0.05, 2 * eps)
    assert math.isclose(eps, 0.01, rel_tol=0, abs_tol=1e-12)
    assert effect(t1, c1) >= threshold and effect(t2, c2) >= threshold
    print("T062B_ANALYZE_SELF_TEST_PASS")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 3:
        write_outputs(analyze(pathlib.Path(sys.argv[1])), pathlib.Path(sys.argv[2]))
        print("T062B_ANALYZE_PASS")
    else:
        fail("usage: --self-test | ROOT OUTPUT_NEW_DIR")
