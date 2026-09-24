#!/usr/bin/env python3
"""Offline C1/T1/T2/C2 endpoint and bandwidth-screen recomputation for 06-2c."""

from __future__ import annotations

import json
import math
import sys
import tempfile
from pathlib import Path

CELLS = ("C1", "T1", "T2", "C2")
MIB = 1024 * 1024
EXPECTED_BW_LOGS = {f"randrw_bw.{job}.log" for job in range(1, 129)}


class EvidenceError(RuntimeError):
    pass


def _no_symlink_path(path: Path, stop: Path) -> bool:
    """Return false if path or any component below stop is a symlink."""
    try:
        relative = path.relative_to(stop)
    except ValueError:
        return False
    current = stop
    for part in (Path("."), *relative.parts):
        current = current / part
        if current.is_symlink():
            return False
    return True


def _number(value, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{label}: expected JSON number")
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise EvidenceError(f"{label}: expected positive finite value")
    return result


def _integer_bytes(value, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{label}: expected integer byte count")
    if not math.isfinite(float(value)) or int(value) != value or value <= 0:
        raise EvidenceError(f"{label}: expected positive integer byte count")
    return int(value)


def parse_cell(root: Path, cell: str) -> dict:
    base = root / "cells" / cell
    formal = base / "formal"
    bw_dir = formal / "bw"
    if not all(_no_symlink_path(path, root) for path in (base, formal, bw_dir)):
        raise EvidenceError(f"{cell}: evidence path escapes through a symlink")
    for required in (base / "PASS", formal / "fio.rc", formal / "fio.json"):
        if not required.is_file() or required.is_symlink():
            raise EvidenceError(f"{cell}: missing or symlink evidence {required.relative_to(root)}")

    if (base / "PASS").read_text().strip() not in ("CELL_RAW_PASS", "PASS"):
        raise EvidenceError(f"{cell}: PASS marker has unexpected contents")
    if (formal / "fio.rc").read_text().strip() != "0":
        raise EvidenceError(f"{cell}: fio.rc is not zero")

    if not bw_dir.is_dir() or bw_dir.is_symlink():
        raise EvidenceError(f"{cell}: missing or symlink bw directory")
    logs = {p.name for p in bw_dir.glob("randrw_bw.*.log") if p.is_file() and not p.is_symlink()}
    if logs != EXPECTED_BW_LOGS:
        raise EvidenceError(f"{cell}: expected exactly 128 contiguous per-job bw logs, got {len(logs)}")

    try:
        data = json.loads((formal / "fio.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"{cell}: invalid fio.json: {exc}") from exc
    jobs = data.get("jobs") if isinstance(data, dict) else None
    if not isinstance(jobs, list) or len(jobs) != 1 or not isinstance(jobs[0], dict):
        raise EvidenceError(f"{cell}: expected exactly one group_reporting JSON job")
    job = jobs[0]
    if isinstance(job.get("error"), bool) or job.get("error") != 0:
        raise EvidenceError(f"{cell}: fio job error is not zero")

    directions = {}
    runtimes = []
    for direction in ("read", "write"):
        part = job.get(direction)
        if not isinstance(part, dict):
            raise EvidenceError(f"{cell}: missing {direction} result")
        byte_count = _integer_bytes(part.get("io_bytes"), f"{cell}:{direction}.io_bytes")
        runtime_ms = _number(part.get("runtime"), f"{cell}:{direction}.runtime")
        directions[direction] = {"io_bytes": byte_count, "runtime_ms": runtime_ms}
        runtimes.append(runtime_ms)

    runtime_ms = max(runtimes)
    runtime_s = runtime_ms / 1000.0
    for direction in ("read", "write"):
        directions[direction]["MiB_s"] = directions[direction]["io_bytes"] / runtime_s / MIB

    return {
        "cell": cell,
        "runtime_s": runtime_s,
        "read": directions["read"],
        "write": directions["write"],
        "bw_log_count": len(logs),
    }


def _effect(numerator: float, denominator: float) -> float:
    return numerator / denominator - 1.0


def analyze(root: Path) -> dict:
    if not root.is_dir() or root.is_symlink():
        raise EvidenceError("run root is missing, not a directory, or a symlink")
    phase_pass = root / "PHASE_PASS"
    if not phase_pass.is_file() or phase_pass.is_symlink():
        raise EvidenceError("PHASE_PASS marker missing")
    for marker, expected in (
        ("PORTAL_RESTORE_PASS", "PORTAL_RESTORE_PASS"),
        ("WRAPPER_PASS", "WRAPPER_PASS"),
        ("wrapper.rc", "0"),
    ):
        path = root / marker
        if not path.is_file() or path.is_symlink() or path.read_text().strip() != expected:
            raise EvidenceError(f"{marker}: wrapper/portal lifecycle is not closed")

    rows = [parse_cell(root, cell) for cell in CELLS]
    by_cell = {row["cell"]: row for row in rows}
    effects = {}
    drifts = {}
    epsilon = 0.0
    for direction in ("read", "write"):
        key = f"{direction}_MiB_s"
        values = {cell: by_cell[cell][direction]["MiB_s"] for cell in CELLS}
        t1_c1 = _effect(values["T1"], values["C1"])
        t2_c2 = _effect(values["T2"], values["C2"])
        c_drift = _effect(values["C2"], values["C1"])
        t_drift = _effect(values["T2"], values["T1"])
        effects[direction] = {
            "T1_over_C1_fraction": t1_c1,
            "T2_over_C2_fraction": t2_c2,
            "T1_over_C1_pct": t1_c1 * 100.0,
            "T2_over_C2_pct": t2_c2 * 100.0,
        }
        drifts[direction] = {
            "C2_over_C1_fraction": c_drift,
            "T2_over_T1_fraction": t_drift,
            "C2_over_C1_pct": c_drift * 100.0,
            "T2_over_T1_pct": t_drift * 100.0,
        }
        epsilon = max(epsilon, abs(c_drift), abs(t_drift))

    materiality = max(0.05, 2.0 * epsilon)
    paired = [
        effects[direction][name]
        for direction in ("read", "write")
        for name in ("T1_over_C1_fraction", "T2_over_C2_fraction")
    ]
    all_positive_material = all(value > 0 and value >= materiality for value in paired)
    if all_positive_material:
        bandwidth_state = "BANDWIDTH_SIGNAL_MECHANISM_UNRESOLVED"
    elif epsilon >= 0.05:
        bandwidth_state = "RESOLUTION_INSUFFICIENT"
    elif any(value > 0 for value in paired) and any(value < 0 for value in paired):
        bandwidth_state = "INCONCLUSIVE"
    else:
        bandwidth_state = "SCREEN_STOP"

    return {
        "schema": "06-2c-bandwidth-analysis-v1",
        "scope": "BANDWIDTH_ENDPOINTS_ONLY_MECHANISM_GATE_NOT_EVALUATED",
        "cells": rows,
        "effects": effects,
        "same_arm_drifts": drifts,
        "epsilon_fraction": epsilon,
        "epsilon_pct": epsilon * 100.0,
        "M_fraction": materiality,
        "M_pct": materiality * 100.0,
        "resolution_insufficient": epsilon >= 0.05,
        "all_four_paired_effects_positive_and_material": all_positive_material,
        "bandwidth_state": bandwidth_state,
        "screen_continue_requires_mechanism_evidence": True,
        "formula": "direction bytes / max(read runtime, write runtime); epsilon=max(abs(C2/C1-1),abs(T2/T1-1)) across R/W; M=max(5%,2*epsilon)",
    }


def write_outputs(result: dict, output: Path) -> None:
    if output.exists() or output.is_symlink():
        raise EvidenceError("output directory must not already exist")
    output.mkdir(parents=True, mode=0o700)
    (output / "analysis.json").write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")

    with (output / "cells.tsv").open("w") as stream:
        stream.write("cell\truntime_s\tread_bytes\twrite_bytes\tread_MiB_s\twrite_MiB_s\tbw_log_count\n")
        for row in result["cells"]:
            stream.write(
                f"{row['cell']}\t{row['runtime_s']:.6f}\t{row['read']['io_bytes']}\t"
                f"{row['write']['io_bytes']}\t{row['read']['MiB_s']:.6f}\t"
                f"{row['write']['MiB_s']:.6f}\t{row['bw_log_count']}\n"
            )

    with (output / "verdict.txt").open("w") as stream:
        stream.write(f"bandwidth_state={result['bandwidth_state']}\n")
        stream.write("scope=BANDWIDTH_ENDPOINTS_ONLY_MECHANISM_GATE_NOT_EVALUATED\n")
        stream.write(f"epsilon_pct={result['epsilon_pct']:.8f}\nM_pct={result['M_pct']:.8f}\n")
        stream.write(f"resolution_insufficient={str(result['resolution_insufficient']).upper()}\n")
        for direction in ("read", "write"):
            for name in ("T1_over_C1_pct", "T2_over_C2_pct"):
                stream.write(f"{direction}_{name}={result['effects'][direction][name]:.8f}\n")
        stream.write("mechanism_gate=NOT_EVALUATED\n")


def _fixture(root: Path, rates: dict[str, tuple[float, float]]) -> None:
    root.mkdir()
    (root / "PHASE_PASS").write_text("PHASE_RAW_PASS\n")
    (root / "PORTAL_RESTORE_PASS").write_text("PORTAL_RESTORE_PASS\n")
    (root / "WRAPPER_PASS").write_text("WRAPPER_PASS\n")
    (root / "wrapper.rc").write_text("0\n")
    for cell, (read_mib_s, write_mib_s) in rates.items():
        formal = root / "cells" / cell / "formal"
        bw = formal / "bw"
        bw.mkdir(parents=True)
        (formal / "fio.rc").write_text("0\n")
        runtime_ms = 180_000
        jobs = [{
            "error": 0,
            "read": {"io_bytes": int(read_mib_s * MIB * 180), "runtime": runtime_ms},
            "write": {"io_bytes": int(write_mib_s * MIB * 180), "runtime": runtime_ms},
        }]
        (formal / "fio.json").write_text(json.dumps({"jobs": jobs}) + "\n")
        (root / "cells" / cell / "PASS").write_text("CELL_RAW_PASS\n")
        for job in range(1, 129):
            (bw / f"randrw_bw.{job}.log").write_text("")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="t062c-analyze-selftest-") as temp:
        base = Path(temp)
        fixture = base / "run"
        rates = {"C1": (100, 100), "T1": (120, 120), "T2": (121.2, 121.2), "C2": (101, 101)}
        _fixture(fixture, rates)
        result = analyze(fixture)
        assert result["bandwidth_state"] == "BANDWIDTH_SIGNAL_MECHANISM_UNRESOLVED"
        assert math.isclose(result["epsilon_fraction"], 0.01, rel_tol=0, abs_tol=1e-12)
        assert math.isclose(result["M_fraction"], 0.05, rel_tol=0, abs_tol=1e-12)
        assert math.isclose(result["effects"]["read"]["T1_over_C1_fraction"], 0.2, rel_tol=0, abs_tol=1e-12)
        output = base / "derived"
        write_outputs(result, output)
        assert json.loads((output / "analysis.json").read_text())["scope"].endswith("MECHANISM_GATE_NOT_EVALUATED")
        assert (output / "cells.tsv").is_file() and (output / "verdict.txt").is_file()

        noisy = base / "noisy"
        noisy_rates = {"C1": (100, 100), "T1": (120, 120), "T2": (121.2, 121.2), "C2": (110, 110)}
        _fixture(noisy, noisy_rates)
        assert analyze(noisy)["bandwidth_state"] == "RESOLUTION_INSUFFICIENT"

        broken = base / "broken"
        _fixture(broken, rates)
        (broken / "cells" / "T1" / "formal" / "bw" / "randrw_bw.128.log").unlink()
        try:
            analyze(broken)
        except EvidenceError as exc:
            assert "bw logs" in str(exc)
        else:
            raise AssertionError("missing per-job log was accepted")

        bad_rc = base / "bad-rc"
        _fixture(bad_rc, rates)
        (bad_rc / "cells" / "C1" / "formal" / "fio.rc").write_text("1\n")
        try:
            analyze(bad_rc)
        except EvidenceError as exc:
            assert "fio.rc" in str(exc)
        else:
            raise AssertionError("nonzero fio.rc was accepted")

        bad_group = base / "bad-group"
        _fixture(bad_group, rates)
        path = bad_group / "cells" / "T2" / "formal" / "fio.json"
        doc = json.loads(path.read_text())
        doc["jobs"].append(doc["jobs"][0])
        path.write_text(json.dumps(doc) + "\n")
        try:
            analyze(bad_group)
        except EvidenceError as exc:
            assert "exactly one" in str(exc)
        else:
            raise AssertionError("multiple fio groups were accepted")

        missing_restore = base / "missing-restore"
        _fixture(missing_restore, rates)
        (missing_restore / "PORTAL_RESTORE_PASS").unlink()
        try:
            analyze(missing_restore)
        except EvidenceError as exc:
            assert "lifecycle" in str(exc)
        else:
            raise AssertionError("missing portal restore marker was accepted")

        bad_wrapper_rc = base / "bad-wrapper-rc"
        _fixture(bad_wrapper_rc, rates)
        (bad_wrapper_rc / "wrapper.rc").write_text("47\n")
        try:
            analyze(bad_wrapper_rc)
        except EvidenceError as exc:
            assert "lifecycle" in str(exc)
        else:
            raise AssertionError("nonzero wrapper rc was accepted")

    print("T062C_ANALYZE_SELF_TEST_PASS")


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        self_test()
        return 0
    if len(argv) == 2:
        try:
            result = analyze(Path(argv[0]))
            write_outputs(result, Path(argv[1]))
        except (EvidenceError, OSError, ValueError) as exc:
            print(f"T062C_ANALYZE_FAIL\t{exc}", file=sys.stderr)
            return 1
        print("T062C_ANALYZE_PASS")
        return 0
    print(f"usage: {Path(sys.argv[0]).name} --self-test | RUN_ROOT NEW_OUTPUT_DIR", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
