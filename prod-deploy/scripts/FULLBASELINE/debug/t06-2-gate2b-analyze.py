#!/usr/bin/env python3
import argparse
import csv
import gzip
import json
import math
import pathlib
import re
import hashlib
import statistics
from collections import defaultdict


def fio_summary(path):
    data = json.loads(path.read_text())
    jobs = data["jobs"]
    return {
        "read_mib_s": sum(j["read"]["bw_bytes"] for j in jobs) / 1048576,
        "write_mib_s": sum(j["write"]["bw_bytes"] for j in jobs) / 1048576,
        "runtime_s": max(max(j["read"]["runtime"], j["write"]["runtime"]) for j in jobs) / 1000,
    }


def aggregate_bw_logs(cell):
    paths = sorted((cell / "formal" / "bw").glob("randrw_bw.*.log"))
    if len(paths) != 128:
        raise ValueError(f"{cell.name}: expected 128 bw logs, got {len(paths)}")
    sums = {0: defaultdict(lambda: defaultdict(float)), 1: defaultdict(lambda: defaultdict(float))}
    weights = {0: defaultdict(lambda: defaultdict(float)), 1: defaultdict(lambda: defaultdict(float))}
    ids = []
    for path in paths:
        match = re.fullmatch(r"randrw_bw\.(\d+)\.log", path.name)
        if not match:
            raise ValueError(f"unexpected log name: {path.name}")
        job = int(match.group(1)); ids.append(job)
        previous = {0: 0.0, 1: 0.0}; seen = set()
        with path.open(newline="") as stream:
            for row in csv.reader(stream):
                if not row or not any(x.strip() for x in row):
                    continue
                if len(row) < 3:
                    raise ValueError(f"short row: {path.name}")
                end = float(row[0]) / 1000.0
                value = float(row[1]) / 1024.0
                direction = int(row[2])
                if direction not in (0, 1) or end < previous[direction] or end > 181:
                    raise ValueError(f"bad row: {path.name}: {row}")
                begin = previous[direction]; previous[direction] = end; seen.add(direction)
                for second in range(math.floor(begin), math.ceil(end)):
                    overlap = min(end, 180.0, second + 1.0) - max(begin, float(second))
                    if overlap > 0:
                        sums[direction][second][job] += value * overlap
                        weights[direction][second][job] += overlap
        if seen != {0, 1}:
            raise ValueError(f"directions incomplete: {path.name}")
    if sorted(ids) != list(range(1, 129)):
        raise ValueError("job IDs are not 1..128")
    result = {}
    for direction, label in ((0, "read"), (1, "write")):
        series = {}
        for second, jobs in sums[direction].items():
            if len(jobs) == 128 and all(weights[direction][second][j] > 0 for j in range(1, 129)):
                series[second] = sum(jobs[j] / weights[direction][second][j] for j in range(1, 129))
        values = [series[s] for s in range(15, 175) if s in series]
        if len(values) != 160:
            raise ValueError(f"{cell.name} {label}: formal coverage {len(values)}/160")
        windows = [statistics.mean(series[s] for s in range(15 + 40 * i, 55 + 40 * i)) for i in range(4)]
        mean = statistics.mean(values)
        result[label] = {
            "mean_mib_s": mean,
            "cv_pct": statistics.pstdev(values) / mean * 100 if mean else math.inf,
            "w1_mib_s": windows[0], "w2_mib_s": windows[1],
            "w3_mib_s": windows[2], "w4_mib_s": windows[3],
            "w4_w1": windows[3] / windows[0] if windows[0] else math.inf,
        }
    return result


def metric_map(path):
    out = {}
    for line in path.read_text(errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        name = parts[0].split("{", 1)[0]
        try:
            out[name] = out.get(name, 0.0) + float(parts[1])
        except ValueError:
            pass
    return out


def find_metric(metrics, suffix):
    rows = [(k, v) for k, v in metrics.items() if k == suffix or k.endswith("_" + suffix)]
    if len(rows) != 1:
        raise ValueError(f"metric {suffix}: expected one aggregate, got {rows}")
    return rows[0]


def histogram(path, suffix):
    count = total = 0.0
    buckets = defaultdict(float)
    for line in path.read_text(errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        token = parts[0]; name = token.split("{", 1)[0]
        try:
            value = float(parts[1])
        except ValueError:
            continue
        if name.endswith("_" + suffix + "_count") or name == suffix + "_count":
            count += value
        elif name.endswith("_" + suffix + "_sum") or name == suffix + "_sum":
            total += value
        elif name.endswith("_" + suffix + "_bucket") or name == suffix + "_bucket":
            match = re.search(r'(?:^|,)le="([^"]+)"', token[token.find("{") + 1:token.rfind("}")])
            if match:
                buckets[match.group(1)] += value
    if count == 0 and not buckets:
        raise ValueError(f"histogram missing: {suffix}")
    return {"count": count, "sum": total, "buckets": dict(buckets)}


def histogram_delta(pre_path, post_path, suffix):
    a, b = histogram(pre_path, suffix), histogram(post_path, suffix)
    count = b["count"] - a["count"]
    total = b["sum"] - a["sum"]
    bucket = {k: b["buckets"].get(k, 0) - a["buckets"].get(k, 0) for k in b["buckets"]}
    if count < 0 or total < 0 or any(v < 0 for v in bucket.values()):
        raise ValueError(f"histogram reset: {suffix}")
    def quantile(q):
        target = count * q
        for bound, cumulative in sorted(bucket.items(), key=lambda x: math.inf if x[0] == "+Inf" else float(x[0])):
            if cumulative >= target:
                return math.inf if bound == "+Inf" else float(bound)
        return math.nan
    return {"count": count, "sum": total, "mean": total / count if count else math.nan,
            "p50_upper_bound": quantile(0.5), "p95_upper_bound": quantile(0.95), "buckets": bucket}


def union_ns(intervals):
    if not intervals:
        return 0
    intervals.sort()
    total = 0
    left, right = intervals[0]
    for a, b in intervals[1:]:
        if a <= right:
            right = max(right, b)
        else:
            total += right - left
            left, right = a, b
    return total + right - left


def analyze_intervals(path, start_ns, end_ns):
    flush, total = [], []
    invalid = 0
    with gzip.open(path, "rt", errors="replace") as f:
        header = next(f).rstrip("\n")
        match = re.search(r"overflow=(\d+)$", header)
        if not match:
            raise ValueError("interval header lacks overflow")
        overflow = int(match.group(1))
        records = 0
        for line in f:
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 5:
                invalid += 1
                continue
            _, rs, fs, fe, re_ = map(int, fields)
            if not (rs <= fs <= fe <= re_):
                invalid += 1
                continue
            if rs < start_ns or re_ > end_ns:
                continue
            total.append((rs, re_))
            flush.append((fs, fe))
            records += 1
    raw_flush = sum(b - a for a, b in flush)
    raw_total = sum(b - a for a, b in total)
    union_flush = union_ns(flush)
    union_total = union_ns(total)
    return {
        "records_formal": records,
        "overflow": overflow,
        "invalid": invalid,
        "raw_flush_ns": raw_flush,
        "raw_total_ns": raw_total,
        "union_flush_ns": union_flush,
        "union_total_ns": union_total,
        "f_raw_intervals": raw_flush / raw_total if raw_total else math.nan,
        "f_dedup": union_flush / union_total if union_total else math.nan,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("root", type=pathlib.Path)
    p.add_argument("--epsilon-source-file", type=pathlib.Path, required=True)
    p.add_argument("--epsilon-source-sha256", required=True)
    args = p.parse_args()
    source_bytes = args.epsilon_source_file.read_bytes()
    source_sha = hashlib.sha256(source_bytes).hexdigest()
    if source_sha != args.epsilon_source_sha256:
        raise ValueError(f"epsilon source SHA mismatch: {source_sha}")
    source_json = json.loads(source_bytes)
    epsilon = float(source_json["epsilon_pct"]) / 100.0
    if not (0 <= epsilon < 1):
        raise ValueError(f"invalid epsilon: {epsilon}")
    cells = args.root / "profile" / "gate2b" / "cells"
    b_fio = fio_summary(cells / "B" / "formal" / "fio.json")
    i_fio = fio_summary(cells / "I" / "formal" / "fio.json")
    b = aggregate_bw_logs(cells / "B")
    i = aggregate_bw_logs(cells / "I")
    pre = metric_map(cells / "I" / "metrics.pre.prom")
    post = metric_map(cells / "I" / "metrics.post.prom")
    metric_names = [
        "instrument_read_flush_wait_seconds_total",
        "instrument_read_total_wait_seconds_total",
        "instrument_read_calls_total",
        "instrument_flush_calls_total",
        "instrument_flush_errors_total",
        "instrument_flush_lock_wait_seconds_total",
        "instrument_flush_lock_hold_seconds_total",
        "instrument_flush_cond_wait_seconds_total",
        "instrument_dependency_wait_seconds_total",
        "instrument_dependency_wait_events_total",
        "instrument_dependency_edges_observed_total",
        "instrument_slice_new_id_seconds_total",
        "instrument_slice_new_id_calls_total",
        "instrument_slice_new_id_errors_total",
        "instrument_slice_finish_seconds_total",
        "instrument_slice_finish_calls_total",
        "instrument_slice_finish_errors_total",
        "instrument_meta_write_seconds_total",
        "instrument_meta_write_calls_total",
        "instrument_meta_write_errors_total",
    ]
    deltas = {}
    resolved = {}
    for suffix in metric_names:
        pre_name, pre_value = find_metric(pre, suffix)
        post_name, post_value = find_metric(post, suffix)
        if pre_name != post_name:
            raise ValueError(f"metric name drift: {pre_name} vs {post_name}")
        resolved[suffix] = pre_name
        deltas[suffix] = post_value - pre_value
    flush_s = deltas["instrument_read_flush_wait_seconds_total"]
    total_s = deltas["instrument_read_total_wait_seconds_total"]
    f_counter = flush_s / total_s if total_s else math.nan
    start_ns = int((cells / "I" / "formal" / "fio-start-epoch-ns.txt").read_text())
    end_ns = int((cells / "I" / "formal" / "fio-end-epoch-ns.txt").read_text())
    intervals = analyze_intervals(cells / "I" / "read-intervals.tsv.gz", start_ns, end_ns)
    histogram_names = [
        "instrument_flush_duration_seconds",
        "instrument_flush_scope_chunks",
        "instrument_flush_scope_slices",
        "instrument_flush_scope_unfrozen_slices",
        "instrument_flush_scope_dep_edges",
        "instrument_flush_scope_dep_closure_depth",
    ]
    histograms = {name: histogram_delta(cells / "I" / "metrics.pre.prom", cells / "I" / "metrics.post.prom", name)
                  for name in histogram_names}
    f = intervals["f_dedup"]
    gmax = f / (1 - f) if 0 <= f < 1 else math.inf
    f_raw = intervals["f_raw_intervals"]
    gmax_raw_request_weighted = f_raw / (1 - f_raw) if 0 <= f_raw < 1 else math.inf
    margin = max(0.05, 2 * epsilon)
    counter_interval_diff = abs(f_counter - intervals["f_raw_intervals"])
    counter_interval_tolerance = 0.02
    verdict = "CONTINUE_GATE3" if intervals["overflow"] == 0 and intervals["invalid"] == 0 and gmax >= margin else "STOP_RANGE_FLUSH"
    instrumentation_errors = sum(deltas[name] for name in (
        "instrument_flush_errors_total", "instrument_slice_new_id_errors_total",
        "instrument_slice_finish_errors_total", "instrument_meta_write_errors_total"))
    staging_error_name, staging_error_pre = find_metric(pre, "staging_block_errors")
    staging_error_post_name, staging_error_post = find_metric(post, "staging_block_errors")
    if staging_error_name != staging_error_post_name or staging_error_post < staging_error_pre:
        raise ValueError("staging error metric drift/reset")
    staging_errors_delta = staging_error_post - staging_error_pre
    if (intervals["overflow"] or intervals["invalid"] or not math.isfinite(f) or
            counter_interval_diff > counter_interval_tolerance or instrumentation_errors != 0 or
            staging_errors_delta != 0):
        verdict = "EVIDENCE_INVALID"
    result = {
        "baseline": b,
        "instrumented": i,
        "fio_summary_sidecar": {"baseline": b_fio, "instrumented": i_fio},
        "observability_overhead": {
            "read_pct": (i["read"]["mean_mib_s"] / b["read"]["mean_mib_s"] - 1) * 100,
            "write_pct": (i["write"]["mean_mib_s"] / b["write"]["mean_mib_s"] - 1) * 100,
            "attribution": "OVERHEAD_NOT_IDENTIFIED",
            "caveat": "B then I sequential execution is confounded by within-run and cross-cell state drift; the delta is descriptive only",
        },
        "counter_f": f_counter,
        "intervals": intervals,
        "counter_interval_raw_abs_diff": counter_interval_diff,
        "counter_interval_tolerance": counter_interval_tolerance,
        "epsilon": epsilon,
        "epsilon_source_file": str(args.epsilon_source_file),
        "epsilon_source_sha256": source_sha,
        "instrumentation_errors": instrumentation_errors,
        "staging_errors_delta": staging_errors_delta,
        "margin": margin,
        "gmax": gmax,
        "gmax_raw_request_weighted": gmax_raw_request_weighted,
        "verdict": verdict,
        "metric_names": resolved,
        "metric_deltas": deltas,
        "histogram_deltas": histograms,
        "caveat": "deduplicated wall-union F is the preregistered decision metric but approaches one when any of 128 concurrent reads is nearly always in Flush; do not interpret its Gmax as a throughput prediction. Raw request-weighted F and Gmax are corroborating capacity-oriented bounds",
    }
    out = args.root / "profile" / "gate2b"
    (out / "gate2b-analysis.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    with (out / "observability-overhead.tsv").open("w") as fobj:
        fobj.write("metric\tbaseline\tinstrumented\tdelta_pct\n")
        for direction in ("read", "write"):
            fobj.write(f"{direction}_mib_s\t{b[direction]['mean_mib_s']:.6f}\t{i[direction]['mean_mib_s']:.6f}\t{result['observability_overhead'][direction + '_pct']:.6f}\n")
    with (out / "amdahl.tsv").open("w") as fobj:
        fobj.write("f_counter_raw\tf_interval_raw\tf_dedup\tgmax_dedup\tgmax_raw_request_weighted\tepsilon\tmargin\toverflow\tinvalid\tverdict\n")
        fobj.write(f"{f_counter:.9f}\t{intervals['f_raw_intervals']:.9f}\t{f:.9f}\t{gmax:.9f}\t{gmax_raw_request_weighted:.9f}\t{epsilon:.6f}\t{margin:.6f}\t{intervals['overflow']}\t{intervals['invalid']}\t{verdict}\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
