#!/usr/bin/env python3
"""Independent offline recomputation for 06-4 direct=1/direct=0 ABBA."""
from __future__ import annotations
import argparse, json, math, tempfile
from pathlib import Path

CELLS = ("D1", "B1", "B2", "D2")
MIB = 2**20

def fail(msg: str) -> None:
    raise SystemExit("T064_ANALYZE_FAIL\t" + msg)

def required_lifecycle(root: Path, cell: str) -> None:
    c = root / "cells" / cell
    for name in ("PASS", "RECOVERY_PASS", "FSYNC_PASS", "DRAIN_PASS",
                 "UNMOUNTED_formal", "READBACK_PASS", "UNMOUNTED_verify"):
        if not (c / name).is_file(): fail(f"{cell}:missing_{name}")
    try:
        if int((c / "formal" / "fio.rc").read_text().strip()) != 0: fail(f"{cell}:fio_rc")
    except (OSError, ValueError): fail(f"{cell}:fio_rc_missing")
    logs = list((c / "formal" / "bw").glob("randrw_bw.*.log"))
    if len(logs) != 128: fail(f"{cell}:bw_log_count={len(logs)}")
    try:
        fs = json.loads((c / "fsync-summary.json").read_text())
        if fs.get("status") != "PASS" or fs.get("files") != 128: fail(f"{cell}:fsync_contract")
    except (OSError, json.JSONDecodeError): fail(f"{cell}:fsync_summary")

def primary(path: Path, expected_direct: int) -> dict:
    try:
        data = json.loads(path.read_text()); jobs = data["jobs"]
        if len(jobs) != 1: fail(f"{path}:expected_one_group")
        job = jobs[0]
        if job.get("error") != 0: fail(f"{path}:fio_error")
        opts = dict(data.get("global options", {})); opts.update(job.get("job options", {}))
        required = {"rw":"randrw", "bs":"256K", "numjobs":"128", "iodepth":"128",
                    "group_reporting":"1", "invalidate":"0"}
        for key, value in required.items():
            if str(opts.get(key, "")).lower() != value.lower(): fail(f"{path}:{key}_contract")
        if str(opts.get("direct", "")) != str(expected_direct): fail(f"{path}:direct_contract")
        r, w = job["read"], job["write"]
        runtime = max(float(r["runtime"]), float(w["runtime"])) / 1000
        if not 170 <= runtime <= 240: fail(f"{path}:runtime={runtime}")
        values = {"read_MiB_s": int(r["io_bytes"]) / runtime / MIB,
                  "write_MiB_s": int(w["io_bytes"]) / runtime / MIB,
                  "runtime_s": runtime, "iodepth_level": job.get("iodepth_level", {})}
        if not all(math.isfinite(values[k]) and values[k] >= 0 for k in ("read_MiB_s", "write_MiB_s")):
            fail(f"{path}:nonfinite")
        return values
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        fail(f"{path}:malformed:{exc}")

def analyze(root: Path) -> dict:
    rows = {}
    for cell in CELLS:
        required_lifecycle(root, cell)
        rows[cell] = primary(root / "cells" / cell / "formal" / "fio.json", 1 if cell.startswith("D") else 0)
    pairs, decision = {}, True
    for direction in ("read_MiB_s", "write_MiB_s"):
        e1 = rows["B1"][direction] / rows["D1"][direction] - 1
        e2 = rows["B2"][direction] / rows["D2"][direction] - 1
        dd = rows["D2"][direction] / rows["D1"][direction] - 1
        bd = rows["B2"][direction] / rows["B1"][direction] - 1
        epsilon = max(abs(dd), abs(bd)); material = max(.05, 2 * epsilon)
        passed = e1 > 0 and e2 > 0 and e1 >= material and e2 >= material
        decision &= passed
        pairs[direction] = {"B1_over_D1_pct":e1*100, "B2_over_D2_pct":e2*100,
            "D2_over_D1_drift_pct":dd*100, "B2_over_B1_drift_pct":bd*100,
            "epsilon_pct":epsilon*100, "materiality_M_pct":material*100, "screen_pass":passed}
    return {"schema":"06-4-buffered-io-v1", "status":"VALID_SCREEN",
            "verdict":"SCREEN_CONTINUE" if decision else "SCREEN_STOP",
            "primary_formula":"io_bytes / max(read.runtime,write.runtime) / 2^20",
            "cells":rows, "paired_effects":pairs,
            "scope":"independent buffered-I/O application model; direct=1 baseline is unchanged"}

def fixture(root: Path) -> None:
    for cell, direct, value in (("D1",1,100),("B1",0,140),("B2",0,142),("D2",1,101)):
        c = root / "cells" / cell; out = c / "formal"; (out / "bw").mkdir(parents=True)
        for name in ("PASS","RECOVERY_PASS","FSYNC_PASS","DRAIN_PASS","UNMOUNTED_formal","READBACK_PASS","UNMOUNTED_verify"):
            (c/name).touch()
        (c/"fsync-summary.json").write_text('{"status":"PASS","files":128}\n'); (out/"fio.rc").write_text("0\n")
        for i in range(128): (out/"bw"/f"randrw_bw.{i}.log").touch()
        job={"error":0,"job options":{"rw":"randrw","bs":"256K","numjobs":"128","iodepth":"128",
             "group_reporting":"1","invalidate":"0","direct":str(direct)},
             "read":{"runtime":180000,"io_bytes":value*MIB*180},"write":{"runtime":180000,"io_bytes":value*MIB*180}}
        (out/"fio.json").write_text(json.dumps({"jobs":[job]}))

def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="t064-analyzer-") as td:
        root=Path(td); fixture(root); result=analyze(root)
        assert result["verdict"] == "SCREEN_CONTINUE"
        (root/"cells"/"B1"/"FSYNC_PASS").unlink()
        try: analyze(root)
        except SystemExit: pass
        else: fail("negative_fixture_accepted")
    print(json.dumps({"status":"PASS","schema":"06-4-buffered-io-v1"}))

def main() -> None:
    p=argparse.ArgumentParser(); p.add_argument("command",choices=("analyze","self-test")); p.add_argument("root",nargs="?")
    a=p.parse_args()
    if a.command == "self-test": self_test(); return
    if not a.root: p.error("analyze requires ROOT")
    root=Path(a.root); result=analyze(root)
    (root/"analysis-06-4.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps(result,indent=2))

if __name__ == "__main__": main()
