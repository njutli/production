#!/usr/bin/env python3
"""Offline 04-6 capacity-curve analyzer.

The analyzer has no network, Ceph, JuiceFS, fio, or environment side effects.
It consumes one cell directory at a time and computes the frozen 8->16->8,
8->16->8, and 64->128->64 curves.  Missing mechanism evidence is reported,
never silently inferred from a busy-looking resource.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

FORMAL_START, FORMAL_END = 15, 175
WINDOWS = [("W1", 15, 55), ("W2", 55, 95), ("W3", 95, 135), ("W4", 135, 175)]
EXPECTED = {"R01": ("mseqread", 8), "R02": ("mseqread", 16), "R03": ("mseqread", 8),
            "W01": ("mseqwrite", 8), "W02": ("mseqwrite", 16), "W03": ("mseqwrite", 8),
            "M01": ("randrw", 64), "M02": ("randrw", 128), "M03": ("randrw", 64)}


class EvidenceError(RuntimeError):
    pass


UNIT_TO_US = {"nsec": 0.001, "usec": 1.0, "msec": 1000.0, "sec": 1_000_000.0}


def latency_from_fio(path: Path, item: str):
    """Extract grouped fio clat P50/P95/P99 without rerunning the workload."""
    text = path.read_text(errors="replace")
    wanted = ("read", "write") if item == "randrw" else (("read",) if item == "mseqread" else ("write",))
    result = {}
    direction_headers = list(re.finditer(r"(?m)^  (read|write):[^\n]*$", text))
    for index, header in enumerate(direction_headers):
        direction = header.group(1)
        if direction not in wanted or direction in result:
            continue
        end = direction_headers[index + 1].start() if index + 1 < len(direction_headers) else len(text)
        block = text[header.start():end]
        marker = re.search(r"clat percentiles \((nsec|usec|msec|sec)\):\s*\n", block)
        if not marker:
            raise EvidenceError(f"fio output lacks {direction} clat percentiles")
        percentile_text = block[marker.end():]
        lines = []
        for line in percentile_text.splitlines():
            if not re.match(r"^\s*\|", line):
                break
            lines.append(line)
        joined = " ".join(lines)
        values = {}
        for q in ("50.00", "95.00", "99.00"):
            match = re.search(rf"{re.escape(q)}th=\[\s*([0-9.]+)\]", joined)
            if not match:
                raise EvidenceError(f"fio output lacks {direction} P{q}")
            values[q] = float(match.group(1)) * UNIT_TO_US[marker.group(1)]
        result[direction] = values
    if set(result) != set(wanted):
        raise EvidenceError(f"fio directions mismatch expected={wanted} got={tuple(result)}")
    return result


def write_latency_tsv(data, output: Path):
    with output.open("w", newline="") as f:
        writer = csv.writer(f, delimiter="\t", lineterminator="\n")
        writer.writerow(("direction", "p50_us", "p95_us", "p99_us"))
        for direction in ("read", "write"):
            if direction in data:
                row = data[direction]
                writer.writerow((direction, row["50.00"], row["95.00"], row["99.00"]))


def percentile(values, q):
    if not values:
        return None
    xs = sorted(values); k = (len(xs) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return xs[lo] if lo == hi else xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def parse_run_ms(text):
    vals = [int(b or a) for a, b in re.findall(r"run=(\d+)(?:-(\d+))?msec", text)]
    if not vals:
        raise EvidenceError("fio output lacks run=<msec>")
    run = max(vals)
    if not 175000 <= run <= 190000:
        raise EvidenceError(f"unexpected runtime {run}ms")
    return run


def parse_rows(path, default_direction):
    rows = []
    for no, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split(",")
        if len(fields) < 2:
            raise EvidenceError(f"short bandwidth row {path}:{no}")
        try:
            end, rate = float(fields[0]), float(fields[1])
            direction = int(fields[2]) if len(fields) >= 3 and fields[2].strip() else default_direction
        except ValueError as exc:
            raise EvidenceError(f"bad bandwidth row {path}:{no}") from exc
        if end <= 0 or rate < 0 or direction not in (0, 1):
            raise EvidenceError(f"invalid bandwidth row {path}:{no}")
        rows.append((end / 1000.0, rate / 1024.0, direction))
    return rows


def aggregate_logs(cell, item, jobs):
    bw = cell / "bw"
    paths = sorted(bw.glob("*_bw.*.log"))
    found = {}
    for p in paths:
        m = re.search(r"_bw\.(\d+)\.log$", p.name)
        if not m:
            raise EvidenceError(f"unexpected bw-log name {p.name}")
        job = int(m.group(1))
        if job in found:
            raise EvidenceError(f"duplicate job log {job}")
        found[job] = p
    if sorted(found) != list(range(1, jobs + 1)):
        raise EvidenceError(f"expected per-job logs 1..{jobs}, got {sorted(found)}")
    acc = {0: defaultdict(lambda: defaultdict(float)), 1: defaultdict(lambda: defaultdict(float))}
    weights = {0: defaultdict(lambda: defaultdict(float)), 1: defaultdict(lambda: defaultdict(float))}
    for job, path in found.items():
        prev = {0: 0.0, 1: 0.0}; seen = {0: 0, 1: 0}
        default = 0 if item == "mseqread" else 1
        for end, mib, direction in parse_rows(path, default):
            begin = prev[direction]; prev[direction] = end; seen[direction] += 1
            if end <= begin:
                raise EvidenceError(f"non-monotonic timestamps in {path}")
            for sec in range(math.floor(begin), math.ceil(end)):
                overlap = min(end, sec + 1) - max(begin, float(sec))
                if overlap > 0:
                    acc[direction][sec][job] += mib * overlap
                    weights[direction][sec][job] += overlap
        if item == "randrw" and (seen[0] < 175 or seen[1] < 175):
            raise EvidenceError(f"randrw direction coverage missing in {path}")
        if item != "randrw" and seen[default] < 175:
            raise EvidenceError(f"bandwidth coverage missing in {path}")
    result = {}
    directions = (0, 1) if item == "randrw" else ((0,) if item == "mseqread" else (1,))
    for direction in directions:
        series = {}
        for sec in range(FORMAL_START, FORMAL_END):
            if len(acc[direction][sec]) != jobs:
                raise EvidenceError(f"incomplete formal second {sec} direction={direction}")
            series[sec] = sum(acc[direction][sec][j] / weights[direction][sec][j]
                              for j in range(1, jobs + 1))
        values = [series[s] for s in range(FORMAL_START, FORMAL_END)]
        windows = [statistics.mean([series[s] for s in range(a, b)]) for _, a, b in WINDOWS]
        mean = statistics.mean(values)
        result["read" if direction == 0 else "write"] = {
            "formal_mean_MiBs": mean, "formal_median_MiBs": statistics.median(values),
            "p50_MiBs": percentile(values, .50), "cv_pct": statistics.pstdev(values) / mean * 100,
            "windows_MiBs": windows, "w4_w1": windows[-1] / windows[0],
            "formal_n": len(values), "per_second_MiBs": {str(k): v for k, v in series.items()},
        }
    return result


def parse_latency(cell, item):
    p = cell / "latency.tsv"
    if not p.exists():
        return None
    with p.open(newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    if not rows:
        raise EvidenceError("latency.tsv is empty")
    def one(row):
        out = {}
        for key in ("p50_us", "p95_us", "p99_us"):
            if key not in row:
                raise EvidenceError(f"latency.tsv missing {key}")
            out[key] = float(row[key])
            if not math.isfinite(out[key]) or out[key] < 0:
                raise EvidenceError(f"invalid {key}")
        return out
    if item == "randrw":
        selected = {r.get("direction", ""): r for r in rows}
        if not {"read", "write"}.issubset(selected):
            raise EvidenceError("randrw latency.tsv requires read and write rows")
        return {"read": one(selected["read"]), "write": one(selected["write"])}
    wanted = "read" if item == "mseqread" else "write"
    row = next((r for r in rows if r.get("direction", "") in (item, "all", wanted)), rows[0])
    return one(row)


def mechanism(cell):
    p = cell / "mechanism.json"
    if not p.exists():
        return {"present": False, "saturated": False, "missing": True}
    data = json.loads(p.read_text())
    if not isinstance(data, dict):
        raise EvidenceError("mechanism.json must be object")
    provenance = data.get("source_files")
    formal = data.get("formal_window") == "[15,175)"
    if not isinstance(provenance, list) or not provenance or not all(isinstance(x, str) and x for x in provenance):
        provenance = None
    elif any(Path(x).is_absolute() or ".." in Path(x).parts or not (cell / x).is_file() for x in provenance):
        provenance = None
    sat = data.get("saturated") is True
    # A declarative saturated=true is accepted only with one of the hard §4.3
    # proofs, avoiding a free-form resource correlation becoming a plateau.
    util = data.get("util_p50_pct", data.get("cpu_p50_pct"))
    hard = type(util) in (int, float) and math.isfinite(util) and util >= 90
    completion = data.get("completion_rate_reproduces_history_pct")
    hard = hard or (type(completion) in (int, float) and math.isfinite(completion) and abs(completion) <= 10)
    valid_provenance = bool(provenance) and formal
    return {"present": True, "saturated": sat and hard and valid_provenance,
            "hard_evidence": hard, "valid_provenance": valid_provenance,
            "component": data.get("component"), "buffer_hit_ratio": data.get("buffer_hit_ratio"),
            "raw": data}


def validate_cell(root, cell_id):
    if cell_id not in EXPECTED:
        raise EvidenceError(f"unknown cell {cell_id}")
    item, jobs = EXPECTED[cell_id]; cell = root / "cells" / cell_id
    if not cell.is_dir():
        raise EvidenceError(f"missing cell directory {cell}")
    text = (cell / "fio.txt").read_text(errors="replace")
    run_ms = parse_run_ms(text)
    end_path = cell / "fio-end-ns.txt"
    if not end_path.exists():
        raise EvidenceError(f"missing {end_path}")
    end_ns = int(end_path.read_text().strip()); actual_t0 = end_ns - run_ms * 1_000_000
    stats = aggregate_logs(cell, item, jobs)
    lat = parse_latency(cell, item)
    mech = mechanism(cell)
    out = {"cell": cell_id, "item": item, "numjobs": jobs, "run_ms": run_ms,
           "actual_t0_ns": actual_t0, "latency": lat, "mechanism": mech, "directions": stats}
    if item == "randrw":
        out["directions"] = {"read": stats["read"], "write": stats["write"]}
    return out


def curve(low, high, after, latency_low_before, latency_high, latency_low_after, mech):
    before = low["formal_mean_MiBs"]; after_bw = after["formal_mean_MiBs"]
    anchor = abs(after_bw / before - 1) if before else float("inf")
    ratio = high["formal_mean_MiBs"] / statistics.mean((before, after_bw))
    lat_ratio = None
    if latency_low_before and latency_high and latency_low_after:
        latency_anchor = statistics.mean((latency_low_before.get("p50_us", 0),
                                          latency_low_after.get("p50_us", 0)))
        if latency_anchor > 0:
            lat_ratio = latency_high["p50_us"] / latency_anchor
    status = "INCONCLUSIVE_DRIFT" if anchor > .05 else "PARTIAL_SCALING"
    if anchor <= .05 and ratio >= 1.60:
        status = "SCALABLE_AT_TESTED_RANGE"
    elif anchor <= .05 and ratio <= 1.15 and lat_ratio is not None and lat_ratio >= 1.60 and mech["saturated"]:
        status = "SERVICE_PLATEAU_IDENTIFIED"
    return {"anchor_drift": anchor, "scale_ratio": ratio, "scale_eff": ratio / 2,
            "lat_ratio": lat_ratio, "status": status, "mechanism_saturated": mech["saturated"]}


def analyze_matrix(root):
    cells = {c: validate_cell(root, c) for c in EXPECTED}
    projects = {}
    for name, ids, direction in (("mseqread", ("R01", "R02", "R03"), "read"),
                                 ("mseqwrite", ("W01", "W02", "W03"), "write"),
                                 ("randrw", ("M01", "M02", "M03"), "read")):
        low, high, after = (cells[x]["directions"][direction] for x in ids)
        lats = [cells[x]["latency"] for x in ids]
        lats = [x[direction] if name == "randrw" else x for x in lats]
        mech = cells[ids[1]]["mechanism"]
        if name == "mseqread" and type(mech.get("buffer_hit_ratio")) in (int, float) \
                and mech["buffer_hit_ratio"] >= .80:
            component = str(mech.get("component") or "").lower()
            if "ceph" in component or "osd" in component:
                mech = dict(mech)
                mech["saturated"] = False
                mech["buffer_guard"] = "buffer-dominated mseqread cannot close a Ceph/OSD wall"
        projects[name] = {"curve": curve(low, high, after, lats[0], lats[1], lats[2], mech),
                          "direction": direction,
                          "latency": {"low": lats[0], "high": lats[1], "low_after": lats[2]},
                          "mechanism": mech}
    # randrw write is an independent endpoint, never added to read.
    low, high, after = (cells[x]["directions"]["write"] for x in ("M01", "M02", "M03"))
    lats = [cells[x]["latency"]["write"] for x in ("M01", "M02", "M03")]
    projects["randrw.write"] = {"curve": curve(low, high, after, lats[0], lats[1], lats[2], cells["M02"]["mechanism"]),
                                 "direction": "write",
                                 "latency": {"low": lats[0], "high": lats[1], "low_after": lats[2]}}
    # Capacity curves alone cannot close §6: the knob-exclusion ledger and
    # architecture boundary require an independent review of historical and
    # same-window evidence.  The analyzer therefore never emits a final
    # stage decision automatically.
    decision = "STAGE04_CONTINUE_DIAGNOSIS"
    return {"evidence_level": "L1_SCREEN", "formal_window": "[15,175)",
            "latency_scope": "fio whole-cell percentiles; formal clat logs require independent cross-check",
            "cells": cells,
            "projects": projects, "stage_decision": decision,
            "decision_note": "No ACTIONABLE_TUNING_FOUND is emitted by the offline analyzer."}


def write_json(data, path):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def selftest():
    with tempfile.TemporaryDirectory(prefix="t046-analyze-") as td:
        root = Path(td); end = 1_000_000_000_000
        for cid, (item, jobs) in EXPECTED.items():
            cell = root / "cells" / cid; (cell / "bw").mkdir(parents=True)
            cell.joinpath("fio.txt").write_text("fio: run=180000msec\n")
            cell.joinpath("fio-end-ns.txt").write_text(str(end))
            direction = 0 if item == "mseqread" else 1
            for j in range(1, jobs + 1):
                p = cell / "bw" / f"{item}_bw.{j}.log"
                with p.open("w") as f:
                    for sec in range(1, 181):
                        rate = 1000 if jobs == 8 else (1800 if jobs == 16 else (900 if jobs == 64 else 1500))
                        if item == "randrw":
                            f.write(f"{sec*1000},{rate*1024},0\n{sec*1000},{rate*1024},1\n")
                        else:
                            f.write(f"{sec*1000},{rate*1024},{direction}\n")
            if item == "randrw":
                cell.joinpath("latency.tsv").write_text("direction\tp50_us\tp95_us\tp99_us\nread\t10\t20\t30\nwrite\t11\t22\t33\n")
            else:
                cell.joinpath("latency.tsv").write_text("direction\tp50_us\tp95_us\tp99_us\nall\t10\t20\t30\n")
        data = analyze_matrix(root)
        assert data["projects"]["mseqread"]["curve"]["status"] == "SCALABLE_AT_TESTED_RANGE"
        assert "randrw.write" in data["projects"] and data["projects"]["randrw.write"]["direction"] == "write"
        assert data["stage_decision"] == "STAGE04_CONTINUE_DIAGNOSIS"
        fio = root / "fio-sample.txt"
        fio.write_text("""  read: IOPS=1, BW=1MiB/s\n    clat percentiles (msec):\n     | 50.00th=[ 10], 95.00th=[ 20], 99.00th=[ 30]\n  write: IOPS=1, BW=1MiB/s\n    clat percentiles (usec):\n     | 50.00th=[ 40], 95.00th=[ 50], 99.00th=[ 60]\n""")
        parsed = latency_from_fio(fio, "randrw")
        assert parsed["read"]["50.00"] == 10000 and parsed["write"]["99.00"] == 60
    print("T046_ANALYZER_SELFTEST_PASS")


def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("matrix"); p.add_argument("root", type=Path); p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("fio-latency"); p.add_argument("fio", type=Path)
    p.add_argument("--item", choices=("mseqread", "mseqwrite", "randrw"), required=True)
    p.add_argument("--output", type=Path, required=True)
    sub.add_parser("self-test")
    args = ap.parse_args()
    try:
        if args.cmd == "self-test": selftest(); return 0
        if args.cmd == "fio-latency":
            write_latency_tsv(latency_from_fio(args.fio, args.item), args.output)
            print(f"T046_LATENCY_PASS\t{args.output}"); return 0
        write_json(analyze_matrix(args.root), args.output); print(f"T046_ANALYSIS_PASS\t{args.output}"); return 0
    except (EvidenceError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"T046_ANALYSIS_FAIL\t{exc}", file=sys.stderr); return 1


if __name__ == "__main__":
    raise SystemExit(main())
