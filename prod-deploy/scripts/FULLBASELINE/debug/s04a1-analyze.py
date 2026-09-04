#!/usr/bin/env python3
"""Strict 04-2 arm summaries plus the frozen matrix contract."""
from __future__ import annotations

import importlib.util
import json
import math
import statistics
import sys
from pathlib import Path

MATRIX = ("C", "L", "L", "C", "L", "C", "C", "L")


def fail(msg: str) -> None:
    raise SystemExit(f"E_S04A1_ANALYZE\t{msg}")


def load_t65():
    path = Path(__file__).with_name("t65-analyze.py")
    if not path.is_file():
        fail(f"missing reused analyzer: {path}")
    spec = importlib.util.spec_from_file_location("s04a1_t65_analyze", path)
    if spec is None or spec.loader is None:
        fail("cannot load reused analyzer")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def percentile(values: list[float], q: float) -> float:
    xs = sorted(values)
    pos = (len(xs) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return xs[lo]
    return xs[lo] * (hi - pos) + xs[hi] * (pos - lo)


def analyze_arm(root: Path, identity: str) -> dict[str, object]:
    if identity not in {"H0", "H1", "ARM-CANARY-C", "ARM-CANARY-L", "R01", "R02", "R03", "R04", "R05", "R06", "R07", "R08"}:
        fail(f"invalid arm identity: {identity}")
    arm = root / "arm"
    if (arm / "fio.rc").read_text().strip() != "0":
        fail("fio rc is not zero")
    if "err= 0" not in (arm / "fio.stdout").read_text():
        fail("fio stdout lacks err=0")
    io_start = float((arm / "fio-io-start.epoch").read_text().strip())
    mod = load_t65()
    values = mod.aggregate_bw(arm)
    stable = [values[x] for x in range(15, 175) if x in values]
    if len(stable) != 160:
        fail(f"formal window coverage={len(stable)}/160")
    windows = {
        f"W{i+1}": statistics.mean(values[x] for x in range(15 + 40 * i, 55 + 40 * i))
        for i in range(4)
    }
    mean = statistics.mean(stable)
    median = statistics.median(stable)
    cv = statistics.pstdev(stable) / mean * 100.0
    result: dict[str, object] = {
        "identity": identity,
        "io_start_epoch": io_start,
        "formal_seconds": 160,
        "formal_window": "[15,175)",
        "mean_MiBs": mean,
        "median_MiBs": median,
        "cv_pct": cv,
        "p10_MiBs": percentile(stable, 0.10),
        "p90_MiBs": percentile(stable, 0.90),
        "windows_mean_MiBs": windows,
        "w4_w1": windows["W4"] / windows["W1"],
        "target_pct": mean / 6250.0 * 100.0,
        "hard_evidence_gate": "PASS",
        "stability_is_endpoint_not_exclusion": True,
    }
    (root / "arm-analysis.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def validate_matrix(path: Path) -> None:
    got = tuple(x.strip() for x in path.read_text().strip().split(","))
    if got != MATRIX:
        fail("matrix differs from C,L,L,C,L,C,C,L")


def self_test() -> None:
    xs = [float(x) for x in range(160)]
    assert percentile(xs, 0.10) == 15.9
    assert percentile(xs, 0.90) == 143.1
    assert MATRIX.count("C") == MATRIX.count("L") == 4
    print("S04A1_ANALYZER_SELF_TEST_PASS")


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "--arm":
        print(json.dumps(analyze_arm(Path(sys.argv[2]), sys.argv[3]), sort_keys=True))
        return 0
    if len(sys.argv) == 2:
        validate_matrix(Path(sys.argv[1]))
        print("ANALYZER_CONTRACT_PASS\tOLS_C_L_quadratic_round\tH0_H1_anchor_drift")
        return 0
    fail("usage: s04a1-analyze.py --self-test | --arm ROOT IDENTITY | MATRIX_FILE")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
