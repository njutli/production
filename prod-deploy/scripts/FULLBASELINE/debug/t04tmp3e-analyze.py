#!/usr/bin/env python3
"""Offline analyzer for 04-tmp3e Reader/FUSE diagnostics."""
from __future__ import annotations
import argparse, csv, json, math, statistics, tempfile
from collections import defaultdict
from pathlib import Path

class EvidenceError(RuntimeError):
    pass

WINDOWS = {30: (5, 25), 60: (10, 50)}

def options(doc):
    job = (doc.get("jobs") or [{}])[0]
    out = dict(doc.get("global options") or doc.get("global_options") or {})
    out.update(job.get("job options") or job.get("job_options") or {})
    return out, job

def metric_rows(path):
    rows = []
    for no, line in enumerate(Path(path).read_text(errors="replace").splitlines()[1:], 2):
        f = line.split("\t", 2)
        if len(f) != 3:
            raise EvidenceError(f"bad metric row {no}")
        try:
            epoch, value = int(f[0]), float(f[2])
        except ValueError as exc:
            raise EvidenceError(f"bad metric row {no}") from exc
        if not math.isfinite(value):
            raise EvidenceError(f"non-finite metric row {no}")
        rows.append((epoch, f[1], value))
    return rows

def family_rows(rows, family, label=None):
    result = defaultdict(float)
    for epoch, key, value in rows:
        if not key.startswith(family + "{") and key != family:
            continue
        if label and label not in key.split("{", 1)[-1]:
            continue
        result[epoch] += value
    return dict(result)

def boundary(series, start, end):
    if not series:
        raise EvidenceError("required metric absent")
    left = [x for x in series if start - 2_000_000_000 <= x <= start + 2_000_000_000]
    right = [x for x in series if end - 2_000_000_000 <= x <= end + 2_000_000_000]
    if not left or not right:
        raise EvidenceError("metric boundary coverage")
    a = min(left, key=lambda x: abs(x - start))
    b = min(right, key=lambda x: abs(x - end))
    if b <= a:
        raise EvidenceError("metric boundary order")
    delta = series[b] - series[a]
    if delta < 0:
        raise EvidenceError("metric counter reset")
    return delta, (b - a) / 1e9

def read_bw(path):
    rows, previous = [], 0.0
    for no, line in enumerate(Path(path).read_text(errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        f = line.split(",")
        if len(f) < 2:
            raise EvidenceError(f"short bandwidth row {no}")
        try:
            end, kib = float(f[0]) / 1000.0, float(f[1])
        except ValueError as exc:
            raise EvidenceError(f"bad bandwidth row {no}") from exc
        if end <= previous or kib < 0 or not math.isfinite(end + kib):
            raise EvidenceError(f"invalid bandwidth row {no}")
        rows.append((previous, end, kib / 1024.0))
        previous = end
    return rows

def formal_seconds(rows, start, finish):
    weighted = defaultdict(lambda: [0.0, 0.0])
    for begin, end, value in rows:
        for sec in range(math.floor(begin), math.ceil(end)):
            overlap = min(end, sec + 1.0) - max(begin, float(sec))
            if overlap > 0:
                weighted[sec][0] += value * overlap
                weighted[sec][1] += overlap
    values = []
    for sec in range(start, finish):
        total, weight = weighted[sec]
        if weight < 0.999:
            raise EvidenceError(f"formal window gap at second {sec}")
        values.append(total / weight)
    return values

def sidecar_summary(path, start_ns, end_ns):
    rows = list(csv.DictReader(Path(path).open(), delimiter="\t"))
    if not rows:
        return {}
    inside = []
    for row in rows:
        try:
            e = int(row["epoch_ns"])
        except (KeyError, ValueError) as exc:
            raise EvidenceError("bad client sidecar") from exc
        if start_ns <= e <= end_ns:
            inside.append((e, row))
    if len(inside) < 3:
        raise EvidenceError("client sidecar coverage")
    result = {}
    for key in ("utime_ticks", "stime_ticks", "rss_pages", "threads", "rx_bytes", "tx_bytes"):
        if key not in inside[0][1]:
            continue
        try:
            vals = [float(r[key]) for _, r in inside]
        except ValueError as exc:
            raise EvidenceError(f"bad client {key}") from exc
        result[key + "_max"] = max(vals)
        result[key + "_median"] = statistics.median(vals)
    first_e, first = inside[0]
    last_e, last = inside[-1]
    wall = (last_e - first_e) / 1e9
    if wall > 0 and "rx_bytes" in first and "tx_bytes" in first:
        result["nic_rx_MiBs"] = (float(last["rx_bytes"]) - float(first["rx_bytes"])) / 2**20 / wall
        result["nic_tx_MiBs"] = (float(last["tx_bytes"]) - float(first["tx_bytes"])) / 2**20 / wall
    if wall > 0 and "utime_ticks" in first and "stime_ticks" in first:
        hz = 100.0
        result["cpu_mean_cores"] = ((float(last["utime_ticks"]) - float(first["utime_ticks"])) +
                                    (float(last["stime_ticks"]) - float(first["stime_ticks"]))) / hz / wall
    return result

def read_contract(cell):
    path = Path(cell) / "cell-contract.tsv"
    result = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            f = line.split("\t", 1)
            if len(f) == 2:
                result[f[0]] = f[1]
    return result

def analyze_cell(path, expected_file=None, expected_engine=None, expected_qd=None, expected_runtime=None):
    cell = Path(path)
    contract = read_contract(cell)
    engine = expected_engine or contract.get("engine")
    qd = int(expected_qd if expected_qd is not None else contract.get("qd", 0))
    runtime = int(expected_runtime if expected_runtime is not None else contract.get("runtime_s", 0))
    if engine not in ("psync", "libaio") or qd < 1 or runtime not in WINDOWS:
        raise EvidenceError("expected engine/qd/runtime required")
    doc = json.loads((cell / "fio.json").read_text())
    opts, job = options(doc)
    if str(opts.get("ioengine", "")) != engine:
        raise EvidenceError("ioengine contract mismatch")
    try:
        actual_qd = int(str(opts.get("iodepth", "")))
    except ValueError as exc:
        raise EvidenceError("iodepth missing") from exc
    if actual_qd != qd:
        raise EvidenceError("iodepth contract mismatch")
    for key, wanted in (("rw", "read"), ("bs", "20M"), ("size", "10G"), ("direct", "1"), ("allow_file_create", "0")):
        if str(opts.get(key, "")) not in (wanted, "True", "true"):
            raise EvidenceError(f"fio contract {key}")
    if not expected_file or str(opts.get("filename") or job.get("filename")) != expected_file:
        raise EvidenceError("fio filename mismatch")
    if "time_based" in opts and str(opts["time_based"]) not in ("1", "True", "true"):
        raise EvidenceError("fio time_based false")
    if int(job.get("error", 1)) != 0:
        raise EvidenceError("fio reports an error")
    read = job.get("read") or {}
    if int(read.get("io_bytes", 0)) <= 10 * 1024**3:
        raise EvidenceError("looping read proof missing")
    if int((job.get("write") or {}).get("io_bytes", 0)) != 0:
        raise EvidenceError("unexpected write I/O")
    runtime_ms = int(job.get("job_runtime", 0))
    if not runtime * 1000 - 2000 <= runtime_ms <= runtime * 1000 + 5000:
        raise EvidenceError("fio runtime mismatch")
    logs = sorted((cell / "bwlog").glob("*_bw.*.log"))
    if len(logs) != 1:
        raise EvidenceError("one bandwidth log required")
    bw_rows = read_bw(logs[0])
    if not bw_rows or bw_rows[-1][1] < runtime - 1 or bw_rows[-1][1] > runtime + 5:
        raise EvidenceError("bandwidth runtime coverage")
    win_start, win_end = WINDOWS[runtime]
    values = formal_seconds(bw_rows, win_start, win_end)
    completion = int((cell / "completion-ns.txt").read_text().strip())
    actual_start = completion - runtime_ms * 1_000_000
    start_ns, end_ns = actual_start + win_start * 1_000_000_000, actual_start + win_end * 1_000_000_000
    rows = metric_rows(cell / "juicefs-metrics.tsv")
    get_bytes = boundary(family_rows(rows, "juicefs_object_request_data_bytes", 'method="GET"'), start_ns, end_ns)
    get_count = boundary(family_rows(rows, "juicefs_object_request_durations_histogram_seconds_count", 'method="GET"'), start_ns, end_ns)
    get_duration = boundary(family_rows(rows, "juicefs_object_request_durations_histogram_seconds_sum", 'method="GET"'), start_ns, end_ns)
    if min(get_bytes[0], get_count[0], get_duration[0]) <= 0:
        raise EvidenceError("non-positive GET metrics")
    mean = statistics.mean(values)
    if mean <= 0:
        raise EvidenceError("non-positive bandwidth")
    avg_size = get_bytes[0] / get_count[0]
    avg_latency = get_duration[0] / get_count[0]
    fuse_counts = family_rows(rows, "juicefs_fuse_ops_total", 'method="read"')
    if not fuse_counts:
        fuse_counts = family_rows(rows, "juicefs_fuse_read_size_bytes_count")
    fuse_count = boundary(fuse_counts, start_ns, end_ns)
    if fuse_count[0] <= 0:
        raise EvidenceError("non-positive FUSE read count")
    fuse_bytes = family_rows(rows, "juicefs_fuse_read_size_bytes_sum")
    fuse_read_bytes = boundary(fuse_bytes, start_ns, end_ns) if fuse_bytes else (None, None)
    # JuiceFS exposes read duration as a per-method counter.  The aggregate
    # histogram mixes lookup/open/etc. and must not be labelled read latency.
    fuse_duration = family_rows(rows, "juicefs_fuse_ops_durations_seconds", 'method="read"')
    fuse_latency = None
    if fuse_duration:
        duration_delta, _ = boundary(fuse_duration, start_ns, end_ns)
        fuse_latency = duration_delta / fuse_count[0] * 1000
    errors = family_rows(rows, "juicefs_object_request_errors")
    object_errors = boundary(errors, start_ns, end_ns)[0] if errors else None
    gauges = family_rows(rows, "juicefs_used_read_buffer_size_bytes")
    gauge_values = [v for e, v in gauges.items() if start_ns <= e <= end_ns]
    client = sidecar_summary(cell / "client-sidecar.tsv", actual_start, completion)
    result = {
        "cell": cell.name, "engine": engine, "qd": qd, "runtime_s": runtime,
        "formal_window_s": [win_start, win_end], "actual_start_ns": actual_start,
        "formal_start_ns": start_ns, "formal_end_ns": end_ns, "completion_ns": completion,
        "runtime_ms": runtime_ms, "stable_mean_MiBs": mean,
        "stable_median_MiBs": statistics.median(values),
        "stable_cv_pct": statistics.pstdev(values) / mean * 100,
        "stable_values_MiBs": values,
        "get_bytes_delta": get_bytes[0], "get_count_delta": get_count[0],
        "get_duration_s_delta": get_duration[0], "avg_get_size_bytes": avg_size,
        "avg_get_latency_ms": avg_latency * 1000,
        "inflight_little": mean * 2**20 * avg_latency / avg_size,
        "fuse_read_count": fuse_count[0], "fuse_read_bytes": fuse_read_bytes[0] if fuse_read_bytes[0] is not None else None,
        "fuse_read_avg_latency_ms": fuse_latency,
        "object_errors_delta": object_errors,
        "read_buffer_max_bytes": max(gauge_values) if gauge_values else None,
        "read_buffer_median_bytes": statistics.median(gauge_values) if gauge_values else None,
        "client_summary": client,
        "cpu_mean_cores": client.get("cpu_mean_cores"),
        "nic_rx_MiBs": client.get("nic_rx_MiBs"),
        "nic_tx_MiBs": client.get("nic_tx_MiBs"),
    }
    return result

def load_cells(root, prefix):
    cells = []
    for path in sorted(Path(root).glob(prefix + "*")):
        if path.is_dir() and (path / "analysis.json").is_file():
            cells.append(json.loads((path / "analysis.json").read_text()))
    if not cells:
        raise EvidenceError(f"no {prefix} cells")
    return cells

def phase_summary(root, prefix):
    cells = load_cells(root, prefix)
    out = {"phase": prefix, "cells": cells}
    if prefix == "A":
        # A01 and A02 are both QD1 (psync anchor and libaio diagnostic); use
        # stable cell IDs so the anchor cannot be silently overwritten.
        by_id = {x.get("cell"): x for x in cells}
        anchor = by_id.get("A01")
        high = by_id.get("A05")
        libaio = [by_id[q] for q in ("A02", "A03", "A04", "A05") if q in by_id]
        mids = [by_id[q] for q in ("A03", "A04") if q in by_id]
        out["psync_anchor_MiBs"] = anchor["stable_median_MiBs"] if anchor else None
        out["qd8_inflight"] = high["inflight_little"] if high else None
        out["qd8_gain_pct"] = ((high["stable_median_MiBs"] / anchor["stable_median_MiBs"] - 1) * 100
                              if anchor and high else None)
        end_anchor = by_id.get("A06")
        out["anchor_drift_pct"] = ((end_anchor["stable_median_MiBs"] / anchor["stable_median_MiBs"] - 1) * 100
                                   if anchor and end_anchor else None)
        growth = [b["stable_median_MiBs"] >= a["stable_median_MiBs"] * 1.05 and
                  b["inflight_little"] >= a["inflight_little"] * 1.05
                  for a,b in zip(libaio, libaio[1:])]
        out["growing_qd_steps"] = sum(growth)
        out["evidence_valid"] = bool(anchor and end_anchor and len(libaio) == 4 and
                                     abs(out["anchor_drift_pct"]) <= 5 and
                                     all((x.get("object_errors_delta") in (0, 0.0)) for x in cells))
        out["application_qd_scalable"] = bool(out["evidence_valid"] and high and len(mids) >= 1 and
            sum(growth) >= 2 and high["inflight_little"] >= libaio[0]["inflight_little"] * 1.25)
    else:
        ra32 = [x for x in cells if x.get("qd") == 1 and x.get("cell") in ("B01", "B04")]
        ra64 = [x for x in cells if x.get("qd") == 1 and x.get("cell") in ("B02", "B03")]
        out["ra64_pair_gain_pct"] = [((b["stable_median_MiBs"] / a["stable_median_MiBs"] - 1) * 100)
                                     for a, b in zip(ra32, ra64)] if len(ra32) == 2 and len(ra64) == 2 else []
        out["evidence_valid"] = bool(len(ra32) == 2 and len(ra64) == 2 and
                                     all((x.get("object_errors_delta") in (0, 0.0)) for x in cells))
    return out

def phase_a_gate(root):
    d = phase_summary(root, "A")
    print(json.dumps(d, sort_keys=True))
    return 0 if d.get("application_qd_scalable") else 1

def self_test():
    with tempfile.TemporaryDirectory(prefix="t04tmp3e-analyze-") as td:
        root = Path(td); (root / "bwlog").mkdir()
        (root / "cell-contract.tsv").write_text("engine\tlibaio\nqd\t2\nruntime_s\t30\n")
        job = {"error": 0, "job_runtime": 30000,
               "job options": {"ioengine": "libaio", "iodepth": "2", "rw": "read", "bs": "20M",
                               "size": "10G", "direct": "1", "allow_file_create": "0", "filename": "/x"},
               "read": {"io_bytes": 20 * 1024**3}, "write": {"io_bytes": 0}}
        (root / "fio.json").write_text(json.dumps({"jobs": [job]}))
        # Completion is 30 seconds after the first sampler point, so the
        # formal [5,25) window is covered by the synthetic 0..34s samples.
        (root / "completion-ns.txt").write_text("1030000000000\n")
        (root / "bwlog/x_bw.1.log").write_text("".join(f"{(i+1)*1000},1024\n" for i in range(30)))
        lines = ["epoch_ns\tmetric\tvalue"]
        for i in range(35):
            e = 1_000_000_000_000 + i * 1_000_000_000
            for fam, val in (("juicefs_object_request_data_bytes", i*1024**2),
                             ("juicefs_object_request_durations_histogram_seconds_count", i*10),
                             ("juicefs_object_request_durations_histogram_seconds_sum", i*.01),
                             ("juicefs_fuse_ops_total", i*20),
                             ("juicefs_fuse_read_size_bytes_sum", i*1024**2),
                             ("juicefs_fuse_read_size_bytes_count", i*4),
                             ("juicefs_used_read_buffer_size_bytes", i*1024)):
                labels = '{method="GET"}' if "object" in fam else ('{method="read"}' if fam == "juicefs_fuse_ops_total" else "")
                lines.append(f"{e}\t{fam}{labels}\t{val}")
        (root / "juicefs-metrics.tsv").write_text("\n".join(lines) + "\n")
        client = ["epoch_ns\tpid\tutime_ticks\tstime_ticks\trss_pages\tthreads\trx_bytes\ttx_bytes"]
        client += [f"{1_000_000_000_000+i*1_000_000_000}\t1\t{i*10}\t{i*2}\t1\t2\t{i*1000000}\t{i*2000000}" for i in range(35)]
        (root / "client-sidecar.tsv").write_text("\n".join(client) + "\n")
        result = analyze_cell(root, "/x", "libaio", 2, 30)
        assert result["inflight_little"] > 0 and result["fuse_read_count"] > 0
        assert result["read_buffer_max_bytes"] is not None
        assert result["client_summary"]["cpu_mean_cores"] > 0
        # Reuse the fixture to exercise the alternate 60-second contract and
        # its [10,50) formal window as well.
        (root / "cell-contract.tsv").write_text("engine\tlibaio\nqd\t2\nruntime_s\t60\n")
        job["job_runtime"] = 60000
        (root / "fio.json").write_text(json.dumps({"jobs": [job]}))
        (root / "completion-ns.txt").write_text("1060000000000\n")
        (root / "bwlog/x_bw.1.log").write_text("".join(f"{(i+1)*1000},1024\n" for i in range(60)))
        lines = ["epoch_ns\tmetric\tvalue"]
        for i in range(65):
            e = 1_000_000_000_000 + i * 1_000_000_000
            for fam, val in (("juicefs_object_request_data_bytes", i*1024**2),
                             ("juicefs_object_request_durations_histogram_seconds_count", i*10),
                             ("juicefs_object_request_durations_histogram_seconds_sum", i*.01),
                             ("juicefs_fuse_ops_total", i*20),
                             ("juicefs_fuse_read_size_bytes_sum", i*1024**2),
                             ("juicefs_fuse_read_size_bytes_count", i*4),
                             ("juicefs_used_read_buffer_size_bytes", i*1024)):
                labels = '{method="GET"}' if "object" in fam else ('{method="read"}' if fam == "juicefs_fuse_ops_total" else "")
                lines.append(f"{e}\t{fam}{labels}\t{val}")
        (root / "juicefs-metrics.tsv").write_text("\n".join(lines) + "\n")
        client = ["epoch_ns\tpid\tutime_ticks\tstime_ticks\trss_pages\tthreads\trx_bytes\ttx_bytes"]
        client += [f"{1_000_000_000_000+i*1_000_000_000}\t1\t{i*10}\t{i*2}\t1\t2\t{i*1000000}\t{i*2000000}" for i in range(65)]
        (root / "client-sidecar.tsv").write_text("\n".join(client) + "\n")
        result = analyze_cell(root, "/x", "libaio", 2, 60)
        assert result["formal_window_s"] == [10, 50]
    print("T04TMP3E_ANALYZER_SELFTEST_PASS")

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    sub.add_parser("self-test")
    c = sub.add_parser("cell")
    c.add_argument("path")
    c.add_argument("--expected-file", dest="expected_file", required=True)
    c.add_argument("--expected-engine", "--engine", dest="engine", required=True)
    c.add_argument("--expected-qd", "--qd", dest="qd", type=int, required=True)
    c.add_argument("--expected-runtime", "--runtime", dest="runtime", type=int, required=True)
    a = sub.add_parser("phase-a"); a.add_argument("root")
    b = sub.add_parser("phase-b"); b.add_argument("root")
    g = sub.add_parser("phase-a-gate"); g.add_argument("root")
    args = ap.parse_args()
    if args.mode == "self-test":
        self_test(); return
    if args.mode == "cell":
        print(json.dumps(analyze_cell(args.path, args.expected_file, args.engine, args.qd, args.runtime), sort_keys=True)); return
    if args.mode == "phase-a":
        print(json.dumps(phase_summary(args.root, "A"), sort_keys=True)); return
    if args.mode == "phase-b":
        print(json.dumps(phase_summary(args.root, "B"), sort_keys=True)); return
    raise SystemExit(phase_a_gate(args.root))

if __name__ == "__main__":
    try:
        main()
    except (EvidenceError, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"T04TMP3E_ANALYZER_FAIL\t{exc}")
        raise SystemExit(2)
