#!/usr/bin/env python3
"""L0-only 04-6b capacity ledger builder.

This module is deliberately offline: it reads only an explicit TSV supplied by
the caller (or frozen task anchors for lower-bound annotations), never probes
Ceph/TiKV/JuiceFS and never treats a report sentence as an upper bound.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import tempfile
from pathlib import Path

TARGET = 6250.0
ITEMS = (
    ("seqread", "read", 1432.9, "04-6 frozen raw anchor", "/mnt/c/SunRise/test/04-6/20260903-214003/04-6-20260903-214003-evidence.tar.gz"),
    ("seqwrite", "write", 1555.0, "04-6 frozen raw anchor", "/mnt/c/SunRise/test/04-6/20260903-214003/04-6-20260903-214003-evidence.tar.gz"),
    ("mseqread", "read", 4687.0, "04-6/U141d frozen raw anchors", "/mnt/c/SunRise/test/04-6/20260903-214003/04-6-20260903-214003-evidence.tar.gz"),
    ("mseqwrite", "write", 4933.11, "U141d frozen raw anchor; 04-6 W02=3853.67", "/home/lilingfeng/demo/production/prod-deploy/doc/perf-report/04-6-stage04-final-capacity-and-tuning-exit-decision-20260903.md"),
    ("randread", "read", None, "required same-window op_r raw is absent from L0 inputs", "/home/lilingfeng/demo/production/prod-deploy/doc/perf-report/04-1b-randread-explicit-primary-steering-ab-20260902.md"),
    ("randwrite", "write", None, "meta-write rate is not a MiB/s capacity ceiling", "/home/lilingfeng/demo/production/prod-deploy/doc/perf-report/04-6-stage04-final-capacity-and-tuning-exit-decision-20260903.md"),
    ("randrw", "read", 1756.77, "04-6 frozen raw M02 anchor", "/mnt/c/SunRise/test/04-6/20260903-214003/04-6-20260903-214003-evidence.tar.gz"),
    ("randrw", "write", 1757.03, "04-6 frozen raw M02 anchor", "/mnt/c/SunRise/test/04-6/20260903-214003/04-6-20260903-214003-evidence.tar.gz"),
)
FIELDS = ("item", "direction", "target_MiB_s", "best_credible_MiB_s",
          "best_evidence", "gap_factor", "fuse_amp", "object_amp",
          "ceph_op_amp", "tikv_txn_amp", "physical_byte_amp",
          "measured_component_cap", "cap_evidence_class",
          "implied_logical_roof", "target_to_roof", "remaining_knob",
          "verdict", "scope", "source_path")


def number(value):
    try:
        x = float(value)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def read_explicit_input(path: Path):
    """Read only a declared raw-derived TSV; unknown/missing fields stay NA."""
    if not path:
        return {}
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"input is not a regular file: {path}")
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    result = {}
    for row in rows:
        key = (row.get("item", ""), row.get("direction", ""))
        value = number(row.get("best_credible_MiB_s"))
        evidence = row.get("best_evidence", "").strip()
        klass = row.get("cap_evidence_class", "").strip()
        # A report-only claim cannot promote a ledger value.
        if value is not None and ("report" in evidence.lower() or
                                  klass not in {"SPEC_HARD_LIMIT", "MEASURED_SERVICE_WALL",
                                                "SERIAL_PATH_BOUND_IN_TESTED_IMPLEMENTATION",
                                                "MEASURED_LOWER_BOUND_ONLY"}):
            value = None
        result[key] = (value, evidence, klass, row.get("source_path", ""))
    return result


def build_rows(measured=None):
    measured = measured or {}
    rows = []
    for item, direction, frozen, note, default_source in ITEMS:
        key = (item, direction)
        value, evidence, klass, source_path = measured.get(key, (None, "", "", ""))
        if value is None and frozen is not None:
            # Frozen anchors are explicitly lower bounds, never roofs.
            value, evidence, klass = frozen, note, "MEASURED_LOWER_BOUND_ONLY"
        target = TARGET
        if value is None:
            best = "NOT_MEASURED"; gap = "NOT_MEASURED"; verdict = "EVIDENCE_GAP"
        else:
            best = f"{value:.6f}"; gap = f"{target / value:.6f}"
            verdict = "LOWER_BOUND_ONLY" if klass == "MEASURED_LOWER_BOUND_ONLY" else "MEASURED"
        rows.append({
            "item": item, "direction": direction, "target_MiB_s": f"{target:.2f}",
            "best_credible_MiB_s": best,
            "best_evidence": evidence or "NOT_MEASURED",
            "gap_factor": gap, "fuse_amp": "NOT_MEASURED", "object_amp": "NOT_MEASURED",
            "ceph_op_amp": "NOT_MEASURED", "tikv_txn_amp": "NOT_MEASURED",
            "physical_byte_amp": "NOT_MEASURED", "measured_component_cap": "NOT_MEASURED",
            "cap_evidence_class": klass or "NOT_MEASURED",
            "implied_logical_roof": "NOT_MEASURED", "target_to_roof": "NOT_MEASURED",
            "remaining_knob": "SCREEN_ONLY; no production change",
            "verdict": verdict, "scope": "04-6b L0; not a formal parameter effect",
            "source_path": source_path or default_source,
        })
    return rows


def write_ledger(rows, output: Path, source: str):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS, delimiter="\t", lineterminator="\n")
        writer.writeheader(); writer.writerows(rows)
    source_map = output.parent.parent / "common" / "source-map.tsv"
    source_map.parent.mkdir(parents=True, exist_ok=True)
    with source_map.open("w", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(("item", "direction", "source_path", "field", "window", "formula", "evidence_limit"))
        for row in rows:
            writer.writerow((row["item"], row["direction"], row["source_path"] or source, "best_credible_MiB_s",
                             "frozen anchor/L0", "frozen lower-bound anchor; no roof inference",
                             row["cap_evidence_class"]))
    knob = output.parent / "knob-ledger.tsv"
    with knob.open("w", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(("knob", "screen", "status", "basis"))
        writer.writerows((("R8", "mseqread", "UNRESOLVED_OR_SCREEN_ONLY", "no formal effect"),
                          ("F1", "max-fuse-io", "UNRESOLVED_OR_SCREEN_ONLY", "no formal effect"),
                          ("U300", "max-uploads", "UNRESOLVED_OR_SCREEN_ONLY", "no formal effect")))
    return {"rows": len(rows), "not_measured": sum(r["best_credible_MiB_s"] == "NOT_MEASURED" for r in rows)}


def percentile(values, q):
    xs = sorted(values); pos = (len(xs) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    return xs[lo] if lo == hi else xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


def bw_values(cell: Path):
    """Sum per-job bw logs and use completion-job_runtime for the I/O origin."""
    if (cell / "fio.rc").read_text().strip() != "0":
        raise ValueError(f"{cell}: fio rc is not zero")
    data = json.loads((cell / "fio.json").read_text())
    jobs = data.get("jobs", [])
    expected_jobs = 1 if cell.name.endswith("-SR") else 16
    # The executor uses --group_reporting: fio emits one aggregate JSON job,
    # while --per_job_logs still emits one bandwidth log per worker.
    if len(jobs) != 1 or int(jobs[0].get("error", -1)) != 0:
        raise ValueError(f"{cell}: fio job/error contract failed")
    try:
        reported_jobs = int(jobs[0].get("job options", {}).get("numjobs", 1))
    except (TypeError, ValueError):
        raise ValueError(f"{cell}: invalid fio numjobs")
    if reported_jobs != expected_jobs:
        raise ValueError(f"{cell}: fio numjobs mismatch expected={expected_jobs} actual={reported_jobs}")
    runtime_ms = number(jobs[0].get("read", {}).get("runtime")) or 0
    if runtime_ms <= 0:
        raise ValueError(f"{cell}: aggregate read runtime missing")
    end_ns = int((cell / "fio-end-ns.txt").read_text())
    start_ns = end_ns - int(runtime_ms * 1_000_000)
    bins = {}
    logs = sorted((cell / "bwlog").glob("*.log"))
    if len(logs) != expected_jobs:
        raise ValueError(f"{cell}: expected {expected_jobs} bw logs, got {len(logs)}")
    for path in logs:
        for line in path.read_text(errors="replace").splitlines():
            fields = line.replace(",", " ").split()
            if len(fields) < 2:
                continue
            try:
                rel = float(fields[0]) / 1000.0
                bw = float(fields[1]) / 1024.0
            except ValueError:
                continue
            if 15.0 <= rel < 175.0:
                bins.setdefault(int(rel), 0.0); bins[int(rel)] += bw
    if len(bins) < 144:
        raise ValueError(f"{cell}: formal bw window too sparse ({len(bins)})")
    formal_values = [v for _, v in sorted(bins.items())]
    formal_mean = statistics.mean(formal_values)
    windows = {}
    for name, lo, hi in (("W1", 15, 55), ("W2", 55, 95), ("W3", 95, 135), ("W4", 135, 175)):
        values = [v for t, v in sorted(bins.items()) if lo <= t < hi]
        if not values:
            raise ValueError(f"{cell}: missing {name}")
        med = statistics.median(values); mean = statistics.mean(values)
        cv = statistics.pstdev(values) / mean if mean else None
        windows[name] = {"n": len(values), "median_MiB_s": med, "P10_MiB_s": percentile(values, .10),
                         "P90_MiB_s": percentile(values, .90), "CV": cv}
    return {"actual_io_start_ns": start_ns, "completion_job_runtime_ms": runtime_ms,
            "effective_bw_MiB_s": formal_mean,
            "formal_median_MiB_s": statistics.median(formal_values),
            "formal_CV": statistics.pstdev(formal_values) / formal_mean if formal_mean else None,
            "formal_seconds": len(formal_values), "windows": windows}


def mechanism_covariates(root: Path, cell_name: str):
    mount = root / "mounts" / cell_name.split("-", 1)[0]
    state = mount / "mount-process.tsv"
    def thread_rows(path):
        file = root / "cells" / cell_name / path / "worker-threads.tsv"
        if not file.is_file(): return {}
        return {r.get("tid"): r for r in csv.DictReader(file.open(), delimiter="\t") if r.get("tid")}
    pre, post = thread_rows("pre-mechanism"), thread_rows("post-mechanism")
    deltas = []
    for tid in set(pre) & set(post):
        if pre[tid].get("comm") != post[tid].get("comm") or "msgr-worker" not in post[tid].get("comm", ""):
            continue
        try:
            delta = (float(post[tid]["utime_ticks"]) + float(post[tid]["stime_ticks"]) -
                     float(pre[tid]["utime_ticks"]) - float(pre[tid]["stime_ticks"]))
            if delta > 0: deltas.append(delta)
        except (KeyError, ValueError): pass
    mean = statistics.mean(deltas) if deltas else None
    def stats(path):
        result = {}
        file = root / "cells" / cell_name / path / "juicefs.stats"
        if not file.is_file(): return result
        for line in file.read_text(errors="replace").splitlines():
            fields = line.split()
            if len(fields) != 2: continue
            value = number(fields[1])
            if value is not None: result[fields[0]] = value
        return result
    pre_stats, post_stats = stats("pre-mechanism"), stats("post-mechanism")
    def delta(key):
        if key not in pre_stats or key not in post_stats: return None
        value = post_stats[key] - pre_stats[key]
        return value if value >= 0 else None
    fuse_duration = delta("juicefs_fuse_ops_durations_seconds_read")
    fuse_count = delta("juicefs_fuse_ops_total_read")
    fuse_bytes = delta("juicefs_fuse_read_size_bytes_sum")
    get_duration = delta("juicefs_object_request_durations_histogram_seconds_GET_sum")
    get_count = delta("juicefs_object_request_durations_histogram_seconds_GET_total")
    get_bytes = delta("juicefs_object_request_data_bytes_GET")
    ns_per_byte = fuse_duration * 1e9 / fuse_bytes if fuse_duration is not None and fuse_bytes else None
    return {"active_worker_count": len(deltas) if deltas else "NOT_MEASURED",
            "worker_cpu_cv": statistics.pstdev(deltas) / mean if mean else "NOT_MEASURED",
            "worker_cpu_delta_ticks": deltas if deltas else "NOT_MEASURED",
            "ns_per_byte": ns_per_byte if ns_per_byte is not None else "NOT_MEASURED",
            "fuse_read_count": fuse_count if fuse_count is not None else "NOT_MEASURED",
            "fuse_read_bytes": fuse_bytes if fuse_bytes is not None else "NOT_MEASURED",
            "fuse_read_duration_s": fuse_duration if fuse_duration is not None else "NOT_MEASURED",
            "get_count": get_count if get_count is not None else "NOT_MEASURED",
            "get_bytes": get_bytes if get_bytes is not None else "NOT_MEASURED",
            "get_duration_s": get_duration if get_duration is not None else "NOT_MEASURED"}


def phase_a_report(root: Path, output: Path):
    endpoints = ("R01-SR", "R01-MSR", "R02-MSR", "R02-SR", "R03-SR", "R03-MSR", "R04-MSR", "R04-SR")
    cells = {}
    for name in endpoints:
        cell = root / "cells" / name
        result = bw_values(cell); result["cell"] = name; result.update(mechanism_covariates(root, name)); cells[name] = result
    pairs = []
    for workload, a, b, c, d in (("seqread", "R02-SR", "R01-SR", "R03-SR", "R04-SR"),
                                  ("mseqread", "R02-MSR", "R01-MSR", "R03-MSR", "R04-MSR")):
        def effective(name): return cells[name]["effective_bw_MiB_s"]
        base1, cand1, base2, cand2 = effective(b), effective(a), effective(d), effective(c)
        p1, p2 = cand1 / base1 - 1.0, cand2 / base2 - 1.0
        effect = math.sqrt((1.0 + p1) * (1.0 + p2)) - 1.0
        screen = ("SCREEN_CANDIDATE_PENDING_MECHANISM" if p1 >= .05 and p2 >= .05
                  else "SCREEN_STOP_NO_CONSISTENT_UPGRADE_SIGNAL")
        pairs.append({"workload": workload, "pair1": f"{a}/{b}", "pair2": f"{c}/{d}",
                      "P1": p1, "P2": p2, "paired_effect": effect, "screen": screen})
    result = {"schema": 1, "formal_window": "[15,175)", "cells": list(cells.values()), "pairs": pairs,
              "verdict": "SCREEN_ONLY; L0 does not sign production capacity"}
    output.parent.mkdir(parents=True, exist_ok=True); output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    with (output.parent / "phase-a-windows.tsv").open("w", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n"); writer.writerow(("cell", "effective_bw_MiB_s", "W1", "W2", "W3", "W4", "CV", "ns_per_byte", "active_worker_count"))
        for row in result["cells"]:
            writer.writerow((row["cell"], row["effective_bw_MiB_s"], *(row["windows"][x]["median_MiB_s"] for x in ("W1", "W2", "W3", "W4")), row["formal_CV"], row["ns_per_byte"], row["active_worker_count"]))
    with (output.parent / "phase-a-pairs.tsv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=("workload", "pair1", "pair2", "P1", "P2", "paired_effect", "screen"), delimiter="\t", lineterminator="\n"); writer.writeheader(); writer.writerows(pairs)
    return result


def bw_write_values(cell: Path, expected_jobs: int):
    """Parse a Phase-B write cell using the same [15,175) log contract."""
    if (cell / "fio.rc").read_text().strip() != "0":
        raise ValueError(f"{cell}: fio rc is not zero")
    data = json.loads((cell / "fio.json").read_text()); jobs = data.get("jobs", [])
    if len(jobs) != 1 or int(jobs[0].get("error", -1)) != 0:
        raise ValueError(f"{cell}: fio job/error contract failed")
    options = jobs[0].get("job options", {})
    if int(options.get("numjobs", 0)) != expected_jobs or options.get("rw") not in (None, "write"):
        raise ValueError(f"{cell}: write fio contract failed")
    runtime_ms = number(jobs[0].get("write", {}).get("runtime")) or 0
    if runtime_ms <= 0: raise ValueError(f"{cell}: aggregate write runtime missing")
    bins = {}
    logs = sorted((cell / "bwlog").glob("*.log"))
    if len(logs) != expected_jobs: raise ValueError(f"{cell}: expected {expected_jobs} bw logs, got {len(logs)}")
    for path in logs:
        for line in path.read_text(errors="replace").splitlines():
            fields = line.replace(",", " ").split()
            if len(fields) < 2: continue
            try: rel, bw = float(fields[0]) / 1000.0, float(fields[1]) / 1024.0
            except ValueError: continue
            if 15.0 <= rel < 175.0: bins.setdefault(int(rel), 0.0); bins[int(rel)] += bw
    if len(bins) < 144: raise ValueError(f"{cell}: formal write window too sparse ({len(bins)})")
    values = [v for _, v in sorted(bins.items())]; mean = statistics.mean(values)
    windows = {}
    for name, lo, hi in (("W1",15,55),("W2",55,95),("W3",95,135),("W4",135,175)):
        part = [v for t,v in sorted(bins.items()) if lo <= t < hi]
        if not part: raise ValueError(f"{cell}: missing {name}")
        windows[name] = {"n":len(part), "median_MiB_s":statistics.median(part), "P10_MiB_s":percentile(part,.10), "P90_MiB_s":percentile(part,.90), "CV":statistics.pstdev(part)/statistics.mean(part) if statistics.mean(part) else None}
    return {"completion_job_runtime_ms": runtime_ms, "effective_bw_MiB_s": mean, "formal_median_MiB_s": statistics.median(values), "formal_CV": statistics.pstdev(values)/mean if mean else None, "formal_seconds": len(values), "windows": windows}


def write_mechanism_covariates(root: Path, cell_name: str, runtime_s: float):
    """Derive full-cell write service rates from frozen before/after counters."""
    cell = root / "cells" / cell_name

    def stats(path):
        result = {}
        if not path.is_file(): return result
        for line in path.read_text(errors="replace").splitlines():
            fields = line.split()
            if len(fields) == 2 and number(fields[1]) is not None:
                result[fields[0]] = float(fields[1])
        return result

    pre = stats(cell / "pre-mechanism" / "juicefs.stats")
    post = stats(cell / "post-mechanism" / "juicefs.stats")
    def delta(key):
        if key not in post: return None
        value = post[key] - pre.get(key, 0.0)
        return value if value >= 0 else None
    def ratio(a, b): return a / b if a is not None and b else None

    fuse_count = delta("juicefs_fuse_ops_total_write")
    fuse_bytes = delta("juicefs_fuse_written_size_bytes_sum")
    put_count = delta("juicefs_object_request_durations_histogram_seconds_PUT_total")
    put_bytes = delta("juicefs_object_request_data_bytes_PUT")
    put_duration = delta("juicefs_object_request_durations_histogram_seconds_PUT_sum")
    meta_count = delta("juicefs_meta_ops_total_Write")
    meta_duration = delta("juicefs_meta_ops_duration_seconds_Write")

    osd_count = osd_bytes = osd_latency_count = osd_latency_sum = 0.0
    osd_files = 0
    for osd in range(6):
        before = cell / "pre-mechanism" / "ceph-osd" / f"osd-{osd}.json"
        after = cell / "post-mechanism" / "ceph-osd" / f"osd-{osd}.json"
        if not before.is_file() or not after.is_file(): continue
        b, a = json.loads(before.read_text())["osd"], json.loads(after.read_text())["osd"]
        osd_count += float(a["op_w"]) - float(b["op_w"])
        osd_bytes += float(a["op_w_in_bytes"]) - float(b["op_w_in_bytes"])
        osd_latency_count += float(a["op_w_latency"]["avgcount"]) - float(b["op_w_latency"]["avgcount"])
        osd_latency_sum += float(a["op_w_latency"]["sum"]) - float(b["op_w_latency"]["sum"])
        osd_files += 1
    if osd_files != 6 or min(osd_count, osd_bytes, osd_latency_count, osd_latency_sum) < 0:
        osd_count = osd_bytes = osd_latency_count = osd_latency_sum = None

    if not runtime_s or None in (fuse_count, fuse_bytes, put_count, put_bytes, put_duration, meta_count, meta_duration):
        return "NOT_MEASURED"
    return {
        "runtime_s": runtime_s,
        "fuse_write_count": fuse_count,
        "fuse_write_bytes": fuse_bytes,
        "fuse_write_rate_s": ratio(fuse_count, runtime_s),
        "fuse_write_avg_bytes": ratio(fuse_bytes, fuse_count),
        "put_count": put_count,
        "put_bytes": put_bytes,
        "put_rate_s": ratio(put_count, runtime_s),
        "put_avg_bytes": ratio(put_bytes, put_count),
        "put_avg_latency_ms": 1000.0 * ratio(put_duration, put_count),
        "meta_write_rate_s": ratio(meta_count, runtime_s),
        "meta_write_avg_latency_ms": 1000.0 * ratio(meta_duration, meta_count),
        "osd_op_w_rate_s": ratio(osd_count, runtime_s),
        "osd_op_w_avg_bytes": ratio(osd_bytes, osd_count),
        "osd_op_w_avg_latency_ms": 1000.0 * ratio(osd_latency_sum, osd_latency_count),
    }


def phase_b_report(root: Path, output: Path):
    endpoints = (("W01-SW", "seqwrite", 1), ("W01-MSW", "mseqwrite", 16),
                 ("W02-MSW", "mseqwrite", 16), ("W02-SW", "seqwrite", 1),
                 ("W03-SW", "seqwrite", 1), ("W03-MSW", "mseqwrite", 16),
                 ("W04-MSW", "mseqwrite", 16), ("W04-SW", "seqwrite", 1))
    cells = {}
    for name, kind, jobs in endpoints:
        cell = root / "cells" / name; result = bw_write_values(cell, jobs); result["cell"] = name; result["workload"] = kind
        mechanism = mechanism_covariates(root, name)
        # Existing sidecar names are read/GET counters.  Never attach those
        # read counters to a write result; this minimal write sampler does not
        # claim write-side request counters.
        for key in ("fuse_read_count", "fuse_read_bytes", "fuse_read_duration_s",
                    "get_count", "get_bytes", "get_duration_s", "ns_per_byte"):
            mechanism[key] = "NOT_MEASURED"
        mechanism["write_mechanism"] = write_mechanism_covariates(root, name, result["completion_job_runtime_ms"] / 1000.0)
        result.update(mechanism); cells[name] = result
    pairs = []
    for workload, a, b, c, d in (("seqwrite", "W02-SW", "W01-SW", "W03-SW", "W04-SW"),
                                  ("mseqwrite", "W02-MSW", "W01-MSW", "W03-MSW", "W04-MSW")):
        p1 = cells[a]["effective_bw_MiB_s"] / cells[b]["effective_bw_MiB_s"] - 1.0
        p2 = cells[c]["effective_bw_MiB_s"] / cells[d]["effective_bw_MiB_s"] - 1.0
        mechanism_gate = {"status": "NOT_APPLICABLE"}
        if p1 >= .05 and p2 >= .05:
            checks = []
            for candidate, baseline in ((a, b), (c, d)):
                cm, bm = cells[candidate]["write_mechanism"], cells[baseline]["write_mechanism"]
                if not isinstance(cm, dict) or not isinstance(bm, dict):
                    checks.append({"pair": f"{candidate}/{baseline}", "pass": False, "reason": "write mechanism unavailable"}); continue
                values = {
                    "put_rate_ratio": cm["put_rate_s"] / bm["put_rate_s"],
                    "osd_op_w_rate_ratio": cm["osd_op_w_rate_s"] / bm["osd_op_w_rate_s"],
                    "fuse_avg_bytes_ratio": cm["fuse_write_avg_bytes"] / bm["fuse_write_avg_bytes"],
                    "osd_latency_ratio": cm["osd_op_w_avg_latency_ms"] / bm["osd_op_w_avg_latency_ms"],
                }
                values["pass"] = (values["put_rate_ratio"] >= 1.05 and values["osd_op_w_rate_ratio"] >= 1.05 and
                                  values["fuse_avg_bytes_ratio"] >= 3.5 and values["osd_latency_ratio"] <= 1.10)
                values["pair"] = f"{candidate}/{baseline}"; checks.append(values)
            mechanism_gate = {"status": "PASS" if all(x["pass"] for x in checks) else "FAIL", "checks": checks,
                              "contract": "PUT and OSD op_w rate >=1.05x; FUSE average write >=3.5x; OSD mean latency <=1.10x"}
            screen = "SCREEN_CONTINUE_OPEN_05" if mechanism_gate["status"] == "PASS" else "CANDIDATE_PENDING_MECHANISM"
        else:
            screen = "STOP_NO_CONSISTENT_UPGRADE_SIGNAL"
        pairs.append({"workload": workload, "pair1": f"{a}/{b}", "pair2": f"{c}/{d}", "P1": p1, "P2": p2,
                      "paired_effect": math.sqrt((1+p1)*(1+p2))-1, "screen": screen, "mechanism_gate": mechanism_gate})
    result = {"schema": 1, "formal_window": "[15,175)", "cells": list(cells.values()), "pairs": pairs,
              "verdict": "SCREEN_ONLY; Phase B does not sign production capacity"}
    output.parent.mkdir(parents=True, exist_ok=True); output.write_text(json.dumps(result, indent=2, sort_keys=True)+"\n")
    with (output.parent / "phase-b-windows.tsv").open("w", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n"); writer.writerow(("cell","workload","effective_bw_MiB_s","W1","W2","W3","W4","CV","fuse_read_count","get_count"))
        for row in result["cells"]: writer.writerow((row["cell"],row["workload"],row["effective_bw_MiB_s"],*(row["windows"][x]["median_MiB_s"] for x in ("W1","W2","W3","W4")),row["formal_CV"],row.get("fuse_read_count"),row.get("get_count")))
    with (output.parent / "phase-b-pairs.tsv").open("w", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n"); writer.writerow(("workload","pair1","pair2","P1","P2","paired_effect","screen","mechanism_gate"))
        for row in pairs: writer.writerow((row["workload"],row["pair1"],row["pair2"],row["P1"],row["P2"],row["paired_effect"],row["screen"],row["mechanism_gate"]["status"]))
    return result


def self_test():
    with tempfile.TemporaryDirectory(prefix="t046-ledger-") as tmp:
        root = Path(tmp); inp = root / "raw.tsv"; out = root / "capacity-ledger.tsv"
        inp.write_text("item\tdirection\tbest_credible_MiB_s\tbest_evidence\tcap_evidence_class\n"
                       "randread\tread\t999\tformal raw\tMEASURED_LOWER_BOUND_ONLY\n"
                       "seqread\tread\t999\tformal report\tMEASURED_SERVICE_WALL\n")
        rows = build_rows(read_explicit_input(inp)); result = write_ledger(rows, out, str(inp))
        assert result["rows"] == len(ITEMS) and result["not_measured"] == 1
        data = list(csv.DictReader(out.open(), delimiter="\t"))
        assert data[0]["best_credible_MiB_s"] == "1432.900000"
        assert next(x for x in data if x["item"] == "seqread")["best_credible_MiB_s"] == "1432.900000"
        assert next(x for x in data if x["item"] == "randread")["best_credible_MiB_s"] == "999.000000"
        phase = root / "phase"; (phase / "cells").mkdir(parents=True)
        for name in ("R01-SR", "R01-MSR", "R02-MSR", "R02-SR", "R03-SR", "R03-MSR", "R04-MSR", "R04-SR"):
            cell = phase / "cells" / name; (cell / "bwlog").mkdir(parents=True)
            count = 1 if name.endswith("-SR") else 16
            (cell / "fio.json").write_text(json.dumps({"jobs": [{"job_runtime": 180000 * count,
                "error": 0, "job options": {"numjobs": str(count)}, "read": {"runtime": 180000}}]}))
            (cell / "fio.rc").write_text("0\n")
            (cell / "fio-end-ns.txt").write_text(str(180 * 10**9))
            for i in range(count):
                (cell / "bwlog" / (name + f".{i}.log")).write_text("\n".join(f"{x*1000} {1024000/count}" for x in range(180)) + "\n")
        phase_result = phase_a_report(phase, phase / "derived" / "verdict.json")
        assert len(phase_result["cells"]) == 8 and len(phase_result["pairs"]) == 2
        phase_b = root / "phase-b"
        for name, count in (("W01-SW",1),("W01-MSW",16),("W02-MSW",16),("W02-SW",1),("W03-SW",1),("W03-MSW",16),("W04-MSW",16),("W04-SW",1)):
            cell = phase_b / "cells" / name; (cell / "bwlog").mkdir(parents=True)
            (cell / "fio.json").write_text(json.dumps({"jobs":[{"error":0,"job options":{"numjobs":count,"rw":"write"},"write":{"runtime":180000}}]})); (cell / "fio.rc").write_text("0\n"); (cell / "fio-end-ns.txt").write_text(str(180*10**9))
            for i in range(count): (cell / "bwlog" / (name+f".{i}.log")).write_text("\n".join(f"{x*1000} {1024000/count}" for x in range(180))+"\n")
        phase_b_result = phase_b_report(phase_b, phase_b / "derived" / "verdict.json")
        assert len(phase_b_result["cells"]) == 8 and len(phase_b_result["pairs"]) == 2
        assert all(x["get_count"] == "NOT_MEASURED" and x["write_mechanism"] == "NOT_MEASURED" for x in phase_b_result["cells"])
        assert all(x["screen"] == "STOP_NO_CONSISTENT_UPGRADE_SIGNAL" for x in phase_b_result["pairs"])
    print("T046_CAPACITY_ANALYZER_SELF_TEST_PASS")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("ledger"); p.add_argument("--output", required=True, type=Path)
    p.add_argument("--input", type=Path); p.add_argument("--source", default="NOT_MEASURED")
    p = sub.add_parser("phase-a"); p.add_argument("--root", required=True, type=Path); p.add_argument("--output", required=True, type=Path)
    p = sub.add_parser("phase-b"); p.add_argument("--root", required=True, type=Path); p.add_argument("--output", required=True, type=Path)
    sub.add_parser("self-test")
    args = parser.parse_args()
    if args.command == "self-test":
        self_test(); return
    if args.command == "phase-a":
        phase_a_report(args.root, args.output); print("T046B_PHASE_A_ANALYZE_PASS"); return
    if args.command == "phase-b":
        phase_b_report(args.root, args.output); print("T046B_PHASE_B_ANALYZE_PASS"); return
    measured = read_explicit_input(args.input) if args.input else {}
    result = write_ledger(build_rows(measured), args.output, args.source)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
