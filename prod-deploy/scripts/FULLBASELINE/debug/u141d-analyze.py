#!/usr/bin/env python3
"""Offline analyzer for U141d.

It reuses the frozen U141b parser/resampler for fio artefacts, then applies the
pre-registered U141d 8-round quadratic-trend model.  It never accesses mounts,
Ceph, JuiceFS, or the network.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import re
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
BASE_ANALYZER = SCRIPT_DIR / "u141b-analyze.py"
ARM_ORDER = ["V13", "V14", "V14", "V13", "V14", "V13", "V13", "V14"]
CROSS_PAIRS = [(1, 2), (4, 3), (6, 5), (7, 8)]
EXPECTED = {
    "A": {"items": ["randrw", "randwrite"],
          "endpoints": ["randrw.read", "randrw.write", "randwrite.write"]},
    "B": {"items": ["mseqwrite"], "endpoints": ["mseqwrite.write"]},
}
EXPECTED_LOGS = {"randrw": 128, "randwrite": 128, "mseqwrite": 16}
FORMAL_N = 160
PRECISION_HALFW_PCT = 5.0
CONTROL_LINE_PCT = -5.0
REDLINE_PCT = -10.0

# n=8.  The quadratic primary model has df=4; the registered linear and
# unadjusted sensitivities have df=5/6.  Values are frozen rather than made
# dependent on scipy availability.
T_TWO_SIDED_95 = {
    4: 2.7764451051977987,
    5: 2.570581835636314,
    6: 2.4469118487916806,
}
T_ONE_SIDED_95 = {
    4: 2.131846786326649,
    5: 2.0150483733330233,
    6: 1.9431802805153022,
}


class EvidenceError(Exception):
    """The archive cannot support the registered computation."""


def load_base_analyzer():
    if not BASE_ANALYZER.is_file():
        raise EvidenceError(f"missing frozen parser: {BASE_ANALYZER}")
    spec = importlib.util.spec_from_file_location("u141b_frozen", BASE_ANALYZER)
    if spec is None or spec.loader is None:
        raise EvidenceError(f"cannot import {BASE_ANALYZER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BASE = load_base_analyzer()


def item_kind(name: str) -> str:
    for kind in ("randrw", "randwrite", "mseqwrite"):
        if name.startswith(kind + "-") or name == kind:
            return kind
    return "unknown"


def endpoint_stats(result: dict, kind: str) -> dict[str, dict]:
    """Return registered endpoint(s); randrw directions are never summed."""
    if kind == "randrw":
        if not result.get("mixed") or set(result.get("directions", {})) != {"read", "write"}:
            raise EvidenceError("randrw does not contain independent READ and WRITE directions")
        return {
            "randrw.read": result["directions"]["read"],
            "randrw.write": result["directions"]["write"],
        }
    return {f"{kind}.write": result}


def analyze_round_dir(round_dir: str | Path, expected_items: list[str]) -> dict:
    round_dir = str(round_dir)
    found = BASE.find_items(round_dir)
    by_kind: dict[str, tuple[str, dict]] = {}
    for name, info in found.items():
        kind = item_kind(name)
        if kind == "unknown":
            continue
        if kind in by_kind:
            raise EvidenceError(f"duplicate {kind} item directories in {round_dir}")
        by_kind[kind] = (name, info)

    if set(by_kind) != set(expected_items):
        raise EvidenceError(
            f"item set mismatch in {round_dir}: got={sorted(by_kind)} "
            f"expected={sorted(expected_items)}")

    output = {"round_dir": round_dir, "items": {}, "endpoints": {}}
    for kind in expected_items:
        name, info = by_kind[kind]
        result = BASE.analyze_item(info)
        n_logs = int(result.get("n_logs", 0))
        if n_logs != EXPECTED_LOGS[kind]:
            raise EvidenceError(
                f"{kind}: log count {n_logs}, expected {EXPECTED_LOGS[kind]}")

        compact = {
            "directory": name,
            "n_logs": n_logs,
            "run_s": result.get("run_s"),
            "summary_MiBs": result.get("summary_MiBs"),
            "formal": result.get("formal"),
            "windows": result.get("windows"),
            "w4_w1": result.get("w4_w1"),
        }
        output["items"][kind] = compact

        for endpoint, stats in endpoint_stats(result, kind).items():
            formal = stats.get("formal", {})
            if formal.get("n") != FORMAL_N:
                raise EvidenceError(
                    f"{endpoint}: formal sample count {formal.get('n')}, expected {FORMAL_N}")
            mean = formal.get("mean")
            if mean is None or not math.isfinite(float(mean)) or float(mean) <= 0:
                raise EvidenceError(f"{endpoint}: invalid formal mean {mean!r}")
            output["endpoints"][endpoint] = {
                "mean_MiBs": float(mean),
                "median_MiBs": formal.get("median"),
                "cv_pct": formal.get("cv_pct"),
                "n": formal.get("n"),
                "windows": stats.get("windows"),
                "w4_w1": stats.get("w4_w1"),
            }
    return output


def transpose(a: list[list[float]]) -> list[list[float]]:
    return [list(row) for row in zip(*a)]


def matmul(a: list[list[float]], b: list[list[float]]) -> list[list[float]]:
    bt = transpose(b)
    return [[sum(x * y for x, y in zip(row, col)) for col in bt] for row in a]


def invert(a: list[list[float]]) -> list[list[float]]:
    n = len(a)
    aug = [list(map(float, row)) + [1.0 if i == j else 0.0 for j in range(n)]
           for i, row in enumerate(a)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda r: abs(aug[r][col]))
        if abs(aug[pivot][col]) < 1e-12:
            raise EvidenceError("singular design matrix")
        aug[col], aug[pivot] = aug[pivot], aug[col]
        scale = aug[col][col]
        aug[col] = [x / scale for x in aug[col]]
        for row in range(n):
            if row == col:
                continue
            factor = aug[row][col]
            aug[row] = [x - factor * y for x, y in zip(aug[row], aug[col])]
    return [row[n:] for row in aug]


def ols_effect(values: list[float], arms: list[str] | None = None,
               trend_order: int = 2) -> dict:
    if len(values) != 8:
        raise EvidenceError(f"registered matrix requires 8 values, got {len(values)}")
    arms = arms or ARM_ORDER
    if arms != ARM_ORDER:
        raise EvidenceError(f"arm order mismatch: {arms} != {ARM_ORDER}")
    if trend_order not in (0, 1, 2):
        raise EvidenceError(f"unsupported trend order {trend_order}")

    xmat = []
    for idx, arm in enumerate(arms, 1):
        x = idx - 4.5
        row = [1.0]
        if trend_order >= 1:
            row.append(x)
        if trend_order >= 2:
            row.append(x * x)
        row.append(1.0 if arm == "V14" else 0.0)
        xmat.append(row)

    xt = transpose(xmat)
    xtx_inv = invert(matmul(xt, xmat))
    ycol = [[float(v)] for v in values]
    beta = [row[0] for row in matmul(matmul(xtx_inv, xt), ycol)]
    fitted = [sum(c * b for c, b in zip(row, beta)) for row in xmat]
    residuals = [y - fit for y, fit in zip(values, fitted)]
    p = len(beta)
    df = len(values) - p
    if df != 4 and trend_order == 2:
        raise EvidenceError(f"registered quadratic model requires df=4, got {df}")
    rss = sum(e * e for e in residuals)
    sigma2 = rss / df
    arm_index = p - 1
    se_arm = math.sqrt(max(0.0, sigma2 * xtx_inv[arm_index][arm_index]))
    arm_mibs = beta[arm_index]
    v13_values = [v for v, arm in zip(values, arms) if arm == "V13"]
    denom = sum(v13_values) / len(v13_values)
    effect_pct = arm_mibs / denom * 100.0
    se_pct = se_arm / denom * 100.0

    t_two = T_TWO_SIDED_95.get(df)
    t_one = T_ONE_SIDED_95.get(df)
    if t_two is None or t_one is None:
        raise EvidenceError(f"no frozen t critical value for df={df}")
    halfw = t_two * se_pct
    ci_low, ci_high = effect_pct - halfw, effect_pct + halfw
    one_low = effect_pct - t_one * se_pct
    one_high = effect_pct + t_one * se_pct

    if one_high < REDLINE_PCT:
        classification = "MATERIAL_REGRESSION"
    elif halfw > PRECISION_HALFW_PCT:
        classification = "RESOLUTION_INSUFFICIENT"
    elif ci_high < 0.0:
        classification = "SMALL_REGRESSION_MEASURED"
    elif ci_low > 0.0:
        classification = "IMPROVEMENT_MEASURED"
    else:
        classification = "NO_DETECTABLE_DIFFERENCE"

    if one_low >= CONTROL_LINE_PCT:
        control5 = "EXCLUDES_GT5_REGRESSION"
    elif one_high < CONTROL_LINE_PCT:
        control5 = "CONFIRMS_GT5_REGRESSION"
    else:
        control5 = "UNRESOLVED_AT_5"
    if one_low >= REDLINE_PCT:
        redline10 = "EXCLUDES_GT10_REGRESSION"
    elif one_high < REDLINE_PCT:
        redline10 = "CONFIRMS_GT10_REGRESSION"
    else:
        redline10 = "UNRESOLVED_AT_10"

    med = sorted(residuals)
    median_e = (med[3] + med[4]) / 2.0
    absdev = sorted(abs(e - median_e) for e in residuals)
    mad = (absdev[3] + absdev[4]) / 2.0
    robust_noise_pct = 1.4826 * mad / denom * 100.0

    return {
        "trend_order": trend_order,
        "n": len(values),
        "df": df,
        "v13_mean_MiBs": denom,
        "v14_mean_MiBs": sum(v for v, a in zip(values, arms) if a == "V14") / 4.0,
        "arm_effect_MiBs": arm_mibs,
        "effect_pct": effect_pct,
        "se_pct": se_pct,
        "ci95_low_pct": ci_low,
        "ci95_high_pct": ci_high,
        "ci95_halfwidth_pct": halfw,
        "one_sided95_low_pct": one_low,
        "one_sided95_high_pct": one_high,
        "classification": classification,
        "control5": control5,
        "redline10": redline10,
        "robust_residual_noise_pct": robust_noise_pct,
        "coefficients": beta,
        "residuals_MiBs": residuals,
    }


def cross_pairs(values: list[float]) -> list[dict]:
    out = []
    for v13_round, v14_round in CROSS_PAIRS:
        v13, v14 = values[v13_round - 1], values[v14_round - 1]
        out.append({
            "pair": f"R{v13_round:02d}/R{v14_round:02d}",
            "v13_MiBs": v13,
            "v14_MiBs": v14,
            "effect_pct": (v14 / v13 - 1.0) * 100.0,
        })
    return out


def collect_phase(run_root: str | Path, phase: str) -> dict:
    phase = phase.upper()
    if phase not in EXPECTED:
        raise EvidenceError(f"unknown phase {phase}")
    root = Path(run_root)
    base = root / "v4"
    if not base.is_dir():
        raise EvidenceError(f"missing v4 directory: {base}")
    meta_path = root / "RUN_META.tsv"
    if not meta_path.is_file():
        raise EvidenceError(f"missing RUN_META.tsv: {meta_path}")
    metadata = {}
    for line in meta_path.read_text().splitlines()[1:]:
        fields = line.split("\t", 1)
        if len(fields) == 2:
            metadata[fields[0]] = fields[1]
    run_id = metadata.get("run_id")
    if not run_id or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", run_id):
        raise EvidenceError(f"invalid run_id in {meta_path}: {run_id!r}")
    pattern = re.compile(
        rf"^U141D-{re.escape(run_id)}-{phase}-R(\d{{2}})-(V13|V14)$")
    round_dirs: dict[int, tuple[str, Path]] = {}
    for entry in sorted(base.iterdir()):
        match = pattern.match(entry.name)
        if not match or not entry.is_dir():
            continue
        number = int(match.group(1))
        if number in round_dirs:
            raise EvidenceError(f"duplicate formal round R{number:02d}")
        round_dirs[number] = (match.group(2), entry)
    if set(round_dirs) != set(range(1, 9)):
        missing = sorted(set(range(1, 9)) - set(round_dirs))
        extra = sorted(set(round_dirs) - set(range(1, 9)))
        raise EvidenceError(f"incomplete phase {phase}: missing={missing} extra={extra}")

    rounds = {}
    endpoints = {name: [] for name in EXPECTED[phase]["endpoints"]}
    arms = []
    for number in range(1, 9):
        arm, directory = round_dirs[number]
        if arm != ARM_ORDER[number - 1]:
            raise EvidenceError(
                f"R{number:02d} arm={arm}, expected {ARM_ORDER[number - 1]}")
        result = analyze_round_dir(directory, EXPECTED[phase]["items"])
        rounds[f"R{number:02d}"] = {"arm": arm, **result}
        arms.append(arm)
        for endpoint in endpoints:
            endpoints[endpoint].append(result["endpoints"][endpoint]["mean_MiBs"])

    analyses = {}
    for endpoint, values in endpoints.items():
        analyses[endpoint] = {
            "per_round_MiBs": values,
            "arms": arms,
            "quadratic": ols_effect(values, arms, 2),
            "linear_sensitivity": ols_effect(values, arms, 1),
            "unadjusted": ols_effect(values, arms, 0),
            "cross_pairs": cross_pairs(values),
        }
    return {"run_root": str(root), "run_id": run_id, "phase": phase, "rounds": rounds,
            "analyses": analyses}


def write_phase_outputs(report: dict, output_dir: str | Path) -> None:
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    phase = report["phase"].lower()
    json_path = out / f"u141d-{phase}-analysis.json"
    tsv_path = out / f"u141d-{phase}-analysis.tsv"
    md_path = out / f"u141d-{phase}-analysis.md"
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    header = ("endpoint\tv13_mean_MiBs\tv14_mean_MiBs\teffect_pct\tci95_low_pct\t"
              "ci95_high_pct\thalfwidth_pct\tone95_low_pct\tclassification\t"
              "control5\tredline10\n")
    rows = []
    md_rows = []
    for endpoint, payload in report["analyses"].items():
        r = payload["quadratic"]
        rows.append(
            f"{endpoint}\t{r['v13_mean_MiBs']:.6f}\t{r['v14_mean_MiBs']:.6f}\t"
            f"{r['effect_pct']:.6f}\t{r['ci95_low_pct']:.6f}\t{r['ci95_high_pct']:.6f}\t"
            f"{r['ci95_halfwidth_pct']:.6f}\t{r['one_sided95_low_pct']:.6f}\t"
            f"{r['classification']}\t{r['control5']}\t{r['redline10']}\n")
        md_rows.append(
            f"| {endpoint} | {r['v13_mean_MiBs']:.1f} | {r['v14_mean_MiBs']:.1f} | "
            f"{r['effect_pct']:+.2f}% | [{r['ci95_low_pct']:+.2f}%, "
            f"{r['ci95_high_pct']:+.2f}%] | {r['classification']} |")
    tsv_path.write_text(header + "".join(rows))
    md_path.write_text(
        f"# U141d phase {report['phase']} offline analysis\n\n"
        "| endpoint | V13 mean | V14 mean | effect | two-sided 95% CI | classification |\n"
        "|---|---:|---:|---:|---:|---|\n" + "\n".join(md_rows) + "\n\n"
        "> These classifications describe measured performance only; they do not approve replacement.\n")


def cmd_round(args) -> int:
    try:
        result = analyze_round_dir(args.round_dir, args.expect.split())
    except (EvidenceError, BASE.GateFail, OSError, ValueError) as exc:
        print(f"EVIDENCE_INVALID: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def cmd_matrix(args) -> int:
    try:
        report = collect_phase(args.run_root, args.phase)
        write_phase_outputs(report, args.output_dir or Path(args.run_root) / "analysis")
    except (EvidenceError, BASE.GateFail, OSError, ValueError) as exc:
        print(f"EVIDENCE_INVALID: {exc}", file=sys.stderr)
        return 2
    for endpoint, payload in report["analyses"].items():
        r = payload["quadratic"]
        print(f"{endpoint:16s} effect={r['effect_pct']:+6.2f}% "
              f"CI95=[{r['ci95_low_pct']:+6.2f},{r['ci95_high_pct']:+6.2f}]% "
              f"{r['classification']} {r['control5']} {r['redline10']}")
    print(f"U141D_PHASE_{report['phase']}_ANALYSIS: COMPLETE_NO_REPLACE_VERDICT")
    return 0


def cmd_replay(_args) -> int:
    """Replay the report-level U141b round summaries; this is code proof, not evidence."""
    fixtures = {
        "randrw.read": [2031, 1892, 1852, 1878, 1770, 1887, 1800, 1855],
        "randwrite.write": [2916, 2788, 2730, 2680, 2668, 2659, 2682, 2651],
    }
    failures = []
    print("=== U141b report-level replay (rounded summary values; not a verdict) ===")
    for endpoint, values in fixtures.items():
        result = ols_effect(values)
        pairs = cross_pairs(values)
        negative = sum(p["effect_pct"] < 0 for p in pairs)
        print(f"{endpoint:16s} arm={result['effect_pct']:+.3f}% "
              f"CIhalf={result['ci95_halfwidth_pct']:.3f}pp negative_pairs={negative}/4")
        if endpoint == "randrw.read" and not (result["effect_pct"] < 0 and negative == 3):
            failures.append("randrw negative tendency not reproduced")
        if endpoint == "randwrite.write" and not (abs(result["effect_pct"]) < 3 and negative == 2):
            failures.append("randwrite overlap/near-zero tendency not reproduced")
    if failures:
        for failure in failures:
            print(f"  [FAIL] {failure}")
        return 1
    print("U141D_REPORT_REPLAY: PASS")
    return 0


def cmd_selftest(_args) -> int:
    failures = []

    def check(name: str, condition: bool):
        print(f"  [{'PASS' if condition else 'FAIL'}] {name}")
        if not condition:
            failures.append(name)

    print("=== design balance ===")
    x = [i - 4.5 for i in range(1, 9)]
    arm = [1 if a == "V14" else 0 for a in ARM_ORDER]
    arm_centered = [a - 0.5 for a in arm]
    check("four slots per arm", sum(arm) == 4)
    check("arm orthogonal to linear trend",
          abs(sum(a * xx for a, xx in zip(arm_centered, x))) < 1e-12)
    qmean = sum(xx * xx for xx in x) / 8.0
    check("arm orthogonal to quadratic trend",
          abs(sum(a * (xx * xx - qmean) for a, xx in zip(arm_centered, x))) < 1e-12)

    print("=== effect recovery and denominator ===")
    base = [5000 + 20 * xx - 3 * xx * xx for xx in x]
    values = [b - (200 if a == "V14" else 0) for b, a in zip(base, ARM_ORDER)]
    result = ols_effect(values)
    check("known -200 MiB/s recovered", abs(result["arm_effect_MiBs"] + 200) < 1e-8)
    check("small negative classified as measured regression",
          result["classification"] == "SMALL_REGRESSION_MEASURED")
    exact10 = [100.0 if a == "V13" else 90.0 for a in ARM_ORDER]
    result10 = ols_effect(exact10)
    check("effect denominator is V13 mean (-10% exactly)",
          abs(result10["effect_pct"] + 10.0) < 1e-8)

    print("=== classification and precision ===")
    severe = [100.0 if a == "V13" else 70.0 for a in ARM_ORDER]
    check("-30% is material regression",
          ols_effect(severe)["classification"] == "MATERIAL_REGRESSION")
    noisy = [100, 89, 130, 75, 120, 110, 90, 80]
    check("large uncertainty is not treated as pass",
          ols_effect(noisy)["classification"] == "RESOLUTION_INSUFFICIENT")
    try:
        ols_effect(values[:7])
        incomplete_rejected = False
    except EvidenceError:
        incomplete_rejected = True
    check("7/8 matrix rejected", incomplete_rejected)
    check("registered t critical df4", abs(T_TWO_SIDED_95[4] - 2.7764451) < 1e-6)

    if failures:
        print(f"U141D_ANALYZER_SELFTEST: FAIL ({len(failures)})")
        return 1
    print("U141D_ANALYZER_SELFTEST: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("selftest").set_defaults(func=cmd_selftest)
    sub.add_parser("replay-u141b").set_defaults(func=cmd_replay)

    p_round = sub.add_parser("round")
    p_round.add_argument("round_dir")
    p_round.add_argument("--expect", required=True,
                         help="space-separated exact item set")
    p_round.set_defaults(func=cmd_round)

    p_matrix = sub.add_parser("matrix")
    p_matrix.add_argument("run_root")
    p_matrix.add_argument("phase", choices=["A", "B", "a", "b"])
    p_matrix.add_argument("--output-dir")
    p_matrix.set_defaults(func=cmd_matrix)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
