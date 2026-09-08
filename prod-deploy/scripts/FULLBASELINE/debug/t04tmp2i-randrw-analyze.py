#!/usr/bin/env python3
"""Fail-closed offline analyzer for the 04-tmp2i T128 randrw closure."""
import argparse
import csv
import json
import math
import re
import shutil
import statistics
from collections import defaultdict
from pathlib import Path


class EvidenceError(RuntimeError):
    pass


CORE = ("A0-pre", "T128-P25", "T128-R", "T128-W", "A0-post")
OPTIONAL = ("T128-P50", "T128-P75")
JOBS = 128
FORMAL_START, FORMAL_STOP = 15, 175


def percentile(values, q):
    xs = sorted(values)
    pos = (len(xs) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    return xs[lo] if lo == hi else xs[lo] * (hi - pos) + xs[hi] * (pos - lo)


def _number(value):
    try:
        return float(str(value).strip())
    except (TypeError, ValueError) as exc:
        raise EvidenceError(f"non-numeric value: {value!r}") from exc


def _first(row, names, default=None):
    for name in names:
        if name in row and str(row[name]).strip() not in ("", "NA", "NaN", "null"):
            return _number(row[name])
    return default


def _tsv(path):
    if not path.is_file():
        return []
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def fio_contract(cell):
    path = cell / "fio.json"
    if not path.is_file():
        raise EvidenceError(f"{cell.name}: fio.json missing")
    try:
        jobs = json.loads(path.read_text()).get("jobs", [])
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"{cell.name}: invalid fio.json") from exc
    if len(jobs) != JOBS:
        raise EvidenceError(f"{cell.name}: expected {JOBS} jobs, got {len(jobs)}")
    read_bytes = write_bytes = 0
    read_runtimes = []
    write_runtimes = []
    runtimes = []
    for job in jobs:
        if int(job.get("error", -1)) != 0:
            raise EvidenceError(f"{cell.name}: fio job error")
        read, write = job.get("read", {}), job.get("write", {})
        read_bytes += int(read.get("io_bytes", 0)); write_bytes += int(write.get("io_bytes", 0))
        read_runtimes.append(int(read.get("runtime", 0)))
        write_runtimes.append(int(write.get("runtime", 0)))
        runtimes.append(max(int(read.get("runtime", 0)), int(write.get("runtime", 0)),
                           int(job.get("job_runtime", 0))))
    runtime_ms = max(runtimes)
    if not 175000 <= runtime_ms <= 320000:
        raise EvidenceError(f"{cell.name}: runtime outside contract: {runtime_ms}")
    end_path = next((x for x in (cell / "fio-end-epoch-ns.txt", cell / "fio-end-ns.txt") if x.is_file()), None)
    if end_path is None:
        raise EvidenceError(f"{cell.name}: fio end sidecar missing")
    try:
        end_ns = int(end_path.read_text().strip())
    except ValueError as exc:
        raise EvidenceError(f"{cell.name}: invalid fio end sidecar") from exc
    start_ns = end_ns - runtime_ms * 1_000_000
    if start_ns <= 0:
        raise EvidenceError(f"{cell.name}: derived I/O start invalid")
    explicit = next((x for x in (cell / "fio-start-epoch-ns.txt", cell / "fio-start-ns.txt") if x.is_file()), None)
    if explicit is not None:
        try:
            stated = int(explicit.read_text().strip())
        except ValueError as exc:
            raise EvidenceError(f"{cell.name}: invalid fio start sidecar") from exc
        # The shell timestamp is taken before fio opens 128 files; it may be
        # earlier than the actual I/O start by many seconds.  It must never be
        # materially later than the end-runtime derived start.
        if stated > start_ns + 2_000_000_000:
            raise EvidenceError(f"{cell.name}: fio start sidecar is after derived I/O start")
    read_runtime_ms = max(read_runtimes); write_runtime_ms = max(write_runtimes)
    if read_runtime_ms <= 0 or write_runtime_ms <= 0:
        raise EvidenceError(f"{cell.name}: directional runtime missing")
    read_mib_s = read_bytes / (read_runtime_ms / 1000.0) / 1048576.0
    write_mib_s = write_bytes / (write_runtime_ms / 1000.0) / 1048576.0
    return {"read_bytes": read_bytes, "write_bytes": write_bytes, "runtime_ms": runtime_ms,
            "read_runtime_ms": read_runtime_ms, "write_runtime_ms": write_runtime_ms,
            "read_mib_s": read_mib_s, "write_mib_s": write_mib_s,
            "end_ns": end_ns, "start_ns": start_ns}


def _bw_paths(cell):
    for base in (cell / "bw", cell / "formal" / "bw"):
        paths = sorted(base.glob("randrw_bw.*.log"))
        if paths:
            return paths
    return []


def aggregate_logs(cell):
    """Aggregate 128 fio logs into READ/WRITE MiB/s natural-second series."""
    logs = _bw_paths(cell)
    if len(logs) != JOBS:
        raise EvidenceError(f"{cell.name}: expected {JOBS} bw logs, got {len(logs)}")
    sums = {0: defaultdict(lambda: defaultdict(float)), 1: defaultdict(lambda: defaultdict(float))}
    weights = {0: defaultdict(lambda: defaultdict(float)), 1: defaultdict(lambda: defaultdict(float))}
    ids = []
    for path in logs:
        match = re.fullmatch(r"randrw_bw\.(\d+)\.log", path.name)
        if not match:
            raise EvidenceError(f"{cell.name}: unexpected bw log {path.name}")
        job = int(match.group(1)); ids.append(job); previous = {0: 0.0, 1: 0.0}; seen = set()
        with path.open(newline="") as handle:
            for row in csv.reader(handle):
                if not row or not any(str(x).strip() for x in row):
                    continue
                if len(row) < 3:
                    raise EvidenceError(f"{cell.name}: direction field missing in {path.name}")
                try:
                    end, value, direction = float(row[0]) / 1000.0, float(row[1]) / 1024.0, int(row[2])
                except ValueError as exc:
                    raise EvidenceError(f"{cell.name}: invalid bw row in {path.name}") from exc
                if direction not in (0, 1) or end < previous[direction]:
                    raise EvidenceError(f"{cell.name}: invalid direction/timestamp in {path.name}")
                start, previous[direction] = previous[direction], end; seen.add(direction)
                for second in range(math.floor(start), math.ceil(end)):
                    overlap = min(end, second + 1) - max(start, second)
                    if overlap > 0:
                        sums[direction][second][job] += value * overlap
                        weights[direction][second][job] += overlap
        if seen != {0, 1}:
            raise EvidenceError(f"{cell.name}: {path.name} lacks READ or WRITE rows")
    if sorted(ids) != list(range(1, JOBS + 1)):
        raise EvidenceError(f"{cell.name}: bw job ids incomplete")
    result = {}
    for direction in (0, 1):
        result[direction] = {}
        for second, jobs in sums[direction].items():
            if len(jobs) == JOBS and all(weights[direction][second][j] > 0 for j in range(1, JOBS + 1)):
                result[direction][second] = sum(jobs[j] / weights[direction][second][j]
                                                for j in range(1, JOBS + 1))
    return result


def bandwidth_window(series, start=FORMAL_START, stop=FORMAL_STOP):
    missing = [x for x in range(start, stop) if x not in series]
    present = [x for x in range(start, stop) if x in series]
    if len(present) < 150:
        raise EvidenceError(f"formal bandwidth diagnostic coverage too sparse: {len(present)}/160")
    values = [series[x] for x in present]
    mean = statistics.mean(values); cuts = [round(i * len(values) / 4) for i in range(5)]
    windows = [statistics.mean(values[cuts[i]:cuts[i + 1]]) for i in range(4)]
    return {"mean_MiBs": mean, "median_MiBs": statistics.median(values),
            "cv_pct": statistics.pstdev(values) / mean * 100 if mean else math.inf,
            "p10_MiBs": percentile(values, .1), "p90_MiBs": percentile(values, .9),
            "windows_MiBs": windows, "W1_MiBs": windows[0], "W2_MiBs": windows[1],
            "W3_MiBs": windows[2], "W4_MiBs": windows[3],
            "W4_W1": windows[3] / windows[0] if windows[0] else math.inf,
            "formal_seconds": len(values), "missing_seconds": missing,
            "coverage_pct": len(values) / (stop - start) * 100.0}


# Stable names used by the offline Gate and by older 2h review notebooks.
def foreground_stats(series, start=FORMAL_START, stop=FORMAL_STOP):
    return bandwidth_window(series, start, stop)


def anchor_drift(anchor_values):
    """Return maximum pairwise relative drift (percent) for A0 values."""
    values = list(anchor_values.values()) if isinstance(anchor_values, dict) else list(anchor_values)
    if len(values) < 3:
        raise EvidenceError("three A0 values are required")
    return max(abs(float(a) / float(b) - 1) * 100 for a in values for b in values if a != b)


def pressure_test(candidate, reference, factor=.70):
    """Apply the registered -30% pressure to a READ/WRITE candidate."""
    read = candidate.get("read_MiBs", candidate.get("read", 0)) * factor
    write = candidate.get("write_MiBs", candidate.get("write", 0)) * factor
    ref_read = reference.get("read", reference.get("READ", 0))
    ref_write = reference.get("write", reference.get("WRITE", 0))
    return {"factor": factor, "read_MiBs": read, "write_MiBs": write,
            "read_effect_pct": _relative(read, ref_read),
            "write_effect_pct": _relative(write, ref_write)}


def pareto_decision(entries):
    """Return entries not strictly dominated in both READ and WRITE."""
    return [x for x in entries if not any(
        y is not x and y["read_effect_pct"] >= x["read_effect_pct"] and
        y["write_effect_pct"] >= x["write_effect_pct"] and
        (y["read_effect_pct"] > x["read_effect_pct"] or y["write_effect_pct"] > x["write_effect_pct"])
        for y in entries)]


def _runtime_metrics(cell, start_ns):
    path = next((x for x in (cell / "runtime.tsv", cell / "sampler" / "runtime.tsv") if x.is_file()), None)
    if path is None:
        raise EvidenceError(f"{cell.name}: runtime.tsv missing")
    rows = _tsv(path); selected = []
    for row in rows:
        epoch = _first(row, ("epoch_ns", "timestamp_ns", "ts_ns"))
        if epoch is None:
            raise EvidenceError(f"{cell.name}: runtime epoch missing")
        if start_ns + FORMAL_START * 1e9 <= epoch < start_ns + FORMAL_STOP * 1e9:
            selected.append(row)
    epochs = [_first(row, ("epoch_ns", "timestamp_ns", "ts_ns")) for row in selected]
    if len(selected) < 150:
        raise EvidenceError(f"{cell.name}: runtime formal coverage too sparse: {len(selected)}/160")
    if epochs[0] > start_ns + 17 * 1e9 or epochs[-1] < start_ns + 173 * 1e9:
        raise EvidenceError(f"{cell.name}: runtime sampler does not span formal window")
    if max(b - a for a, b in zip(epochs, epochs[1:])) > 2.5e9:
        raise EvidenceError(f"{cell.name}: runtime sampler gap exceeds 2.5s")
    def delta(names):
        vals = [_first(row, names) for row in selected]; vals = [x for x in vals if x is not None]
        return vals[-1] - vals[0] if len(vals) >= 2 else None
    def peak(names):
        vals = [_first(row, names) for row in selected]; vals = [x for x in vals if x is not None]
        return max(vals) if vals else None
    def minimum(names):
        vals = [_first(row, names) for row in selected]; vals = [x for x in vals if x is not None]
        return min(vals) if vals else None
    hit = delta(("hit_bytes", "juicefs_blockcache_hit_bytes", "blockcache_hit_bytes"))
    miss = delta(("miss_bytes", "juicefs_blockcache_miss_bytes", "blockcache_miss_bytes"))
    if hit is None or miss is None or hit < 0 or miss < 0:
        raise EvidenceError(f"{cell.name}: hit/miss counters missing or invalid")
    result = {"samples": len(selected), "hit_bytes_delta": hit, "miss_bytes_delta": miss,
              "hit_ratio": hit / (hit + miss) if hit + miss else 0.0,
              "blockcache_peak_bytes": peak(("blockcache_bytes", "cache_bytes", "juicefs_blockcache_bytes")),
              "raw_peak_bytes": None,
              "staging_peak_bytes": peak(("staging_bytes", "staging_block_bytes", "juicefs_staging_block_bytes")),
              "min_free_bytes": minimum(("min_free_bytes", "df_avail", "available_bytes", "df_available_bytes")),
              "evicts_delta": delta(("evicts", "juicefs_blockcache_evicts")),
              "drops_delta": delta(("drops", "juicefs_blockcache_drops"))}
    if result["staging_peak_bytes"] is None:
        raise EvidenceError(f"{cell.name}: staging field missing")
    return result


def _inode_summary(cell):
    paths = sorted(cell.glob("cache-inodes-*.tsv")) or sorted((cell / "formal").glob("cache-inodes-*.tsv"))
    if not paths:
        return {"files": None, "bytes": None, "unique_inodes": None}
    names, size, inodes = set(), 0, set()
    for path in paths:
        snapshot_inodes = {}
        for row in _tsv(path):
            if row.get("path"): names.add(row["path"])
            item_size = int(_first(row, ("size_bytes", "bytes", "staging_bytes"), 0) or 0)
            device = str(row.get("device", ""))
            inode = _first(row, ("inode", "ino"))
            key = (device, int(inode)) if inode is not None else ("path", row.get("path", ""))
            snapshot_inodes[key] = max(item_size, snapshot_inodes.get(key, 0))
        size = max(size, sum(snapshot_inodes.values())); inodes.update(snapshot_inodes)
    return {"files": len(names), "bytes": size, "unique_inodes": len(inodes)}


def _cache_df_min_free(cell):
    for path in (cell / "cache-df.tsv", cell / "cache-df-formal.tsv"):
        if not path.is_file():
            continue
        values = []
        for row in _tsv(path):
            value = _first(row, ("min_free_bytes", "df_avail", "available_bytes", "avail"))
            if value is not None:
                values.append(value)
        if values:
            return min(values)
        for line in path.read_text().splitlines()[1:]:
            fields = line.split()
            if len(fields) >= 4:
                try:
                    values.append(float(fields[3]))
                except ValueError:
                    pass
        if values:
            return min(values)
    return None


def _lifecycle(cell, fio, name):
    rows = _tsv(cell / "drain.tsv"); safe = True
    writeback = name.startswith("T") and name.rsplit("-", 1)[-1] in {"W", "P25", "P50", "P75"}
    if writeback and not rows:
        safe = False
    if rows:
        if len(rows) < 2: safe = False
        for row in rows[-2:]:
            for names in (("staging_blocks",), ("staging_bytes", "staging_block_bytes"),
                          ("staging_writing_blocks",), ("staging_files",), ("staging_file_bytes",)):
                if (_first(row, names, 0) or 0) != 0: safe = False
    drain = 0.0
    if (cell / "drain-seconds.txt").is_file():
        try: drain = float((cell / "drain-seconds.txt").read_text().strip())
        except ValueError as exc: raise EvidenceError(f"{cell.name}: invalid drain seconds") from exc
    elif writeback:
        safe = False
    if not 0 <= drain <= 900: safe = False
    elapsed = fio["runtime_ms"] / 1000 + drain
    strict_end = cell / "strict-drain-end-ns.txt"
    if writeback and strict_end.is_file():
        try: elapsed = (int(strict_end.read_text().strip()) - fio["start_ns"]) / 1e9
        except ValueError as exc: raise EvidenceError(f"{cell.name}: invalid strict drain end") from exc
        if elapsed < fio["runtime_ms"] / 1000: safe = False
    verdict = None
    if (cell / "verdict.tsv").is_file():
        for row in csv.reader((cell / "verdict.tsv").open(), delimiter="\t"):
            if len(row) == 2 and row[0] == "verdict": verdict = row[1]
    if verdict in {"LIFECYCLE_FAIL", "TIMEOUT", "CAPACITY_FAIL"}: safe = False
    return {"safe": safe, "verdict": verdict or ("LIFECYCLE_PASS" if safe else "LIFECYCLE_FAIL"),
            "drain_seconds": drain,
            "effective_durable_write_MiBs": fio["write_bytes"] / 1048576.0 / elapsed}


def _cell_dir(root, name):
    direct = root / "cells" / name
    if direct.is_dir():
        return direct
    # The original 2h runner names the no-cache anchor output A0-pre-A0.
    legacy = root / "cells" / f"{name}-A0" if name.startswith("A0-") else None
    return legacy if legacy is not None and legacy.is_dir() else direct


def analyze_cell(root, name):
    cell = _cell_dir(root, name)
    passed = (cell / "PASS").is_file()
    recovered_unsafe = (cell / "RECOVERY-CLOSED").is_file()
    if not passed and not recovered_unsafe:
        raise EvidenceError(f"{name}: PASS/recovery marker missing")
    for rc_name in ("fio.rc", "sampler.rc"):
        rc_path = cell / rc_name
        if not rc_path.is_file():
            raise EvidenceError(f"{name}: {rc_name} missing")
        if rc_path.read_text().strip() != "0":
            raise EvidenceError(f"{name}: {rc_name} is non-zero")
    for error_path in cell.glob("*error*.txt"):
        if error_path.stat().st_size:
            raise EvidenceError(f"{name}: non-empty error evidence {error_path.name}")
    for health_path in cell.glob("health-*/**/*.json"):
        try:
            health = json.loads(health_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise EvidenceError(f"{name}: invalid health evidence") from exc
        status = health.get("health", {}).get("status", health.get("status"))
        checks = health.get("health", {}).get("checks", health.get("checks", {}))
        check_names = sorted(checks) if isinstance(checks, dict) else []
        expected_paused = status == "HEALTH_WARN" and check_names == ["OSDMAP_FLAGS"]
        if status not in (None, "HEALTH_OK") and not expected_paused:
            raise EvidenceError(f"{name}: unhealthy Ceph evidence {status}/{check_names}")
    fio = fio_contract(cell); series = aggregate_logs(cell)
    bandwidth = {label: bandwidth_window(series[direction]) for direction, label in ((0, "read"), (1, "write"))}
    for label in ("read", "write"):
        bandwidth[label]["bwlog_observed_mean_MiBs"] = bandwidth[label]["mean_MiBs"]
        bandwidth[label]["mean_MiBs"] = fio[f"{label}_mib_s"]
    metrics = _runtime_metrics(cell, fio["start_ns"]); inode_summary = _inode_summary(cell)
    if name.startswith("A0-"):
        metrics["raw_peak_bytes"] = 0
    elif metrics["raw_peak_bytes"] is None:
        metrics["raw_peak_bytes"] = inode_summary["bytes"]
    if metrics["raw_peak_bytes"] is None:
        raise EvidenceError(f"{name}: raw cache peak missing")
    if metrics["min_free_bytes"] is None:
        metrics["min_free_bytes"] = _cache_df_min_free(cell)
    if metrics["min_free_bytes"] is None:
        raise EvidenceError(f"{name}: min-free field missing")
    lifecycle = _lifecycle(cell, fio, name)
    if recovered_unsafe:
        lifecycle["safe"] = False
        lifecycle["verdict"] = "RECOVERY_CLOSED_ORIGINAL_CELL_UNSAFE"
    return {"cell": name, "fio": fio, "bandwidth": bandwidth, "metrics": metrics,
            "inode_summary": inode_summary, "lifecycle": lifecycle,
            "mean_direction_MiBs": (bandwidth["read"]["mean_MiBs"] + bandwidth["write"]["mean_MiBs"]) / 2,
            "evidence_status": "VALID"}


def online_cell_summary(cell):
    """Return the pre-registered formal-window bandwidth for an executed cell.

    This deliberately ignores lifecycle and PASS markers so the runner can make
    the pre-registered within-group supplement decision before final analysis.
    """
    cell = Path(cell)
    fio = fio_contract(cell)
    # The online adaptive decision uses the complete fio directional byte/time
    # totals.  Per-second bwlogs remain a trend/CV diagnostic and cannot veto a
    # completed cell merely because old fio omits a few zero-I/O tail samples.
    return {"cell": cell.name, "read_mib_s": fio["read_mib_s"],
            "write_mib_s": fio["write_mib_s"],
            "mean_direction_mib_s": (fio["read_mib_s"] + fio["write_mib_s"]) / 2}


def _relative(value, ref): return (value / ref - 1) * 100 if ref else math.nan


def _anchor_refs(rows):
    anchors = {x["cell"]: x["bandwidth"] for x in rows if x["cell"].startswith("A0-")}
    if set(anchors) != {"A0-pre", "A0-mid", "A0-post"}: raise EvidenceError("three A0 anchors are required")
    values = {d: {a: anchors[a][d]["mean_MiBs"] for a in anchors} for d in ("read", "write")}
    values["mean"] = {a: (values["read"][a] + values["write"][a]) / 2 for a in anchors}
    pairwise = [abs(values[d][a] / values[d][b] - 1) * 100 for d in values
                for a in values[d] for b in values[d] if a < b]
    pre_mid = max(abs(values[d]["A0-pre"] / values[d]["A0-mid"] - 1) * 100 for d in values)
    refs = {}
    for group, (left, right, fraction) in GROUP_STAGE.items():
        refs[group] = {d: values[d][left] + fraction * (values[d][right] - values[d][left]) for d in values}
    return {"values": values, "drift_final_pct": max(pairwise), "drift_pre_mid_pct": pre_mid,
            "M_online_pct": max(8.0, pre_mid), "M_final_pct": max(5.0, max(pairwise)), "refs": refs}


def _decisions(rows, anchors):
    by_name = {x["cell"]: x for x in rows}; groups = {}; dominance = {}
    for group in GROUP_ORDER:
        ref = anchors["refs"][group]; entries = []
        optional = [suffix for suffix in ("P25", "P75") if f"{group}-{suffix}" in by_name]
        suffixes = ("R", "W", "P50", *optional)
        for suffix in suffixes:
            item = by_name[f"{group}-{suffix}"]; read = item["bandwidth"]["read"]["mean_MiBs"]; write = item["bandwidth"]["write"]["mean_MiBs"]
            entry = {"cell": item["cell"], "read_MiBs": read, "write_MiBs": write,
                     "mean_direction_MiBs": (read + write) / 2,
                     "read_effect_pct": _relative(read, ref["read"]), "write_effect_pct": _relative(write, ref["write"]),
                     "mean_effect_pct": _relative((read + write) / 2, ref["mean"]),
                     "lifecycle_safe": item["lifecycle"]["safe"], "drain_seconds": item["lifecycle"]["drain_seconds"],
                     "min_free_bytes": item["metrics"]["min_free_bytes"]}
            entry["safe_candidate"] = entry["lifecycle_safe"]; entries.append(entry)
        groups[group] = {"reference": ref, "points": entries}
        for x in entries:
            dominance[x["cell"]] = []
            for y in entries:
                if x is y: continue
                dr = _relative(x["read_MiBs"], y["read_MiBs"]); dw = _relative(x["write_MiBs"], y["write_MiBs"])
                if min(dr, dw) >= -anchors["M_online_pct"] and max(dr, dw) >= anchors["M_online_pct"]:
                    dominance[x["cell"]].append(y["cell"])
            x["materially_dominates"] = dominance[x["cell"]]
            x["pressure_read_effect_pct"] = _relative(x["read_MiBs"] * .70, ref["read"])
            x["pressure_write_effect_pct"] = _relative(x["write_MiBs"] * .70, ref["write"])
            x["pressure_safe"] = x["lifecycle_safe"] and x["pressure_read_effect_pct"] >= -anchors["M_online_pct"] and x["pressure_write_effect_pct"] >= -anchors["M_online_pct"]
        safe = [x for x in entries if x["safe_candidate"]]
        pareto = [x["cell"] for x in safe if not any(y["read_effect_pct"] >= x["read_effect_pct"] and y["write_effect_pct"] >= x["write_effect_pct"] and (y["read_effect_pct"] > x["read_effect_pct"] or y["write_effect_pct"] > x["write_effect_pct"]) for y in safe)]
        pressure_dominance = {}
        for x in safe:
            pressure_dominance[x["cell"]] = []
            for y in entries:
                if y is x:
                    continue
                dr = _relative(x["read_MiBs"] * .70, y["read_MiBs"])
                dw = _relative(x["write_MiBs"] * .70, y["write_MiBs"])
                if min(dr, dw) >= -anchors["M_online_pct"] and max(dr, dw) >= anchors["M_online_pct"]:
                    pressure_dominance[x["cell"]].append(y["cell"])
            x["pressure_materially_dominates"] = pressure_dominance[x["cell"]]
        robust = [x["cell"] for x in safe if x["pressure_safe"] and
                  len(pressure_dominance[x["cell"]]) == len(entries) - 1]
        adaptive = ("EARLY_STOP" if robust and not optional else
                    "SUPPLEMENT_COMPLETE" if optional else "SUPPLEMENT_REQUIRED")
        groups[group].update({"safe_candidates": [x["cell"] for x in safe], "pareto": pareto,
                              "pressure_robust": robust, "pressure_material_dominance": pressure_dominance,
                              "adaptive_decision": adaptive, "supplement_points": optional})
    validity = "RESOLUTION_INSUFFICIENT" if anchors["drift_final_pct"] > 8 else "VALID"
    robust_count = sum(bool(x["pressure_robust"]) and x["adaptive_decision"] == "EARLY_STOP" for x in groups.values())
    pareto_count = sum(bool(x["pareto"]) for x in groups.values())
    if validity != "VALID": verdict = "PLATFORM_NEEDS_L2"
    elif robust_count == len(groups): verdict = "SCREEN_CANDIDATES"
    elif pareto_count: verdict = "PARETO_ONLY"
    else: verdict = "NO_SAFE_MATERIAL_CANDIDATE"
    states = {k: v["adaptive_decision"] for k, v in groups.items()}
    if all(state == "EARLY_STOP" for state in states.values()):
        global_state = "EARLY_STOP"
    elif all(state in {"EARLY_STOP", "SUPPLEMENT_COMPLETE"} for state in states.values()):
        global_state = "SUPPLEMENT_COMPLETE"
    else:
        global_state = "SUPPLEMENT_REQUIRED"
    return groups, {"RUN_VALIDITY_STATE": validity, "CACHE_VERDICT": verdict, "material_dominance": dominance,
                    "adaptive_matrix": {"global": global_state, "groups": states}}


def analyze(root):
    root = Path(root); cells_dir = root / "cells"
    actual = {x.name for x in cells_dir.iterdir() if x.is_dir()} if cells_dir.is_dir() else set()
    optional_names = {f"{group}-{suffix}" for group in GROUP_ORDER for suffix in ("P25", "P75")}
    legacy_anchors = {f"{name}-A0" for name in CORE if name.startswith("A0-")}
    canonical = {name for name in CORE + tuple(optional_names)
                 if name in actual or (name.startswith("A0-") and f"{name}-A0" in actual)}
    if (root / "RESOLUTION-STOP-A0-MID").is_file():
        prefix = CORE[:CORE.index("A0-mid") + 1]
        missing_prefix = sorted(set(prefix) - canonical)
        forbidden_later = sorted(set(CORE[CORE.index("A0-mid") + 1:]) & canonical)
        if missing_prefix or forbidden_later:
            return {"schema": 2, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID",
                    "CACHE_VERDICT": "NO_DECISION", "missing_cells": missing_prefix,
                    "unexpected_later_cells": forbidden_later}
        analyze_names = list(prefix) + sorted(name for name in optional_names if name in canonical)
        rows, errors = [], []
        for name in analyze_names:
            try: rows.append(analyze_cell(root, name))
            except EvidenceError as exc: errors.append(str(exc))
        if errors:
            return {"schema": 2, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID",
                    "CACHE_VERDICT": "NO_DECISION", "errors": errors, "cells": rows}
        by_name = {x["cell"]: x for x in rows}
        def values(name):
            read = by_name[name]["bandwidth"]["read"]["mean_MiBs"]
            write = by_name[name]["bandwidth"]["write"]["mean_MiBs"]
            return (read, write, (read + write) / 2)
        pre, mid = values("A0-pre"), values("A0-mid")
        drift = max(abs(mid[i] / pre[i] - 1) * 100 for i in range(3))
        state = "RESOLUTION_INSUFFICIENT" if drift > 8 else "EVIDENCE_INVALID"
        return {"schema": 2, "RUN_VALIDITY_STATE": state, "CACHE_VERDICT": "NO_DECISION",
                "stop_reason": "A0_MID_DRIFT", "drift_pre_mid_pct": drift, "cells": rows}
    extras = actual - set(CORE) - optional_names - legacy_anchors
    missing, extra = sorted(set(CORE) - canonical), sorted(extras)
    if missing or extra:
        return {"schema": 2, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "CACHE_VERDICT": "NO_DECISION", "missing_cells": missing, "extra_cells": extra}
    supplement_errors = []
    for group in GROUP_ORDER:
        present = [f"{group}-{suffix}" in canonical for suffix in ("P25", "P75")]
        if any(present) and not all(present):
            supplement_errors.append(f"{group}: P25/P75 supplement must be complete")
    if supplement_errors:
        return {"schema": 2, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "CACHE_VERDICT": "NO_DECISION", "errors": supplement_errors}
    errors, rows = [], []
    analyze_names = list(CORE) + [name for name in sorted(optional_names) if name in canonical]
    for name in analyze_names:
        try: rows.append(analyze_cell(root, name))
        except EvidenceError as exc: errors.append(str(exc))
    if errors:
        return {"schema": 2, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "CACHE_VERDICT": "NO_DECISION", "errors": errors, "cells": rows}
    try: anchors = _anchor_refs(rows); groups, decision = _decisions(rows, anchors)
    except EvidenceError as exc:
        return {"schema": 2, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "CACHE_VERDICT": "NO_DECISION", "errors": [str(exc)], "cells": rows}
    return {"schema": 2, "run_id": root.name.removeprefix("opencode-04tmp2h-"), "RUN_VALIDITY_STATE": decision["RUN_VALIDITY_STATE"],
            "CACHE_VERDICT": decision["CACHE_VERDICT"], "anchors": anchors, "groups": groups,
            "material_dominance": decision["material_dominance"], "adaptive_matrix": decision["adaptive_matrix"],
            "cells": rows, "formal_window_seconds": [FORMAL_START, FORMAL_STOP]}


def _tmp2i_analyze(root):
    """Analyze only the registered T128 five-cell screen plus optional P50/P75."""
    root = Path(root)
    cells_dir = root / "cells"
    actual = {x.name for x in cells_dir.iterdir() if x.is_dir()} if cells_dir.is_dir() else set()
    legacy_anchors = {f"{name}-A0" for name in CORE if name.startswith("A0-")}
    canonical = {name for name in CORE + OPTIONAL
                 if name in actual or (name.startswith("A0-") and f"{name}-A0" in actual)}
    extras = actual - set(CORE) - set(OPTIONAL) - legacy_anchors
    missing = sorted(set(CORE) - canonical)
    decision_path = root / "supplement-decisions.tsv"
    supplement = None
    if decision_path.is_file():
        lines = [x.split("\t") for x in decision_path.read_text().splitlines() if x.strip()]
        if len(lines) == 1 and len(lines[0]) == 2 and lines[0][0] == "T128" and lines[0][1] in {"ADD", "SKIP"}:
            supplement = lines[0][1]
    optional_present = [name for name in OPTIONAL if name in canonical]
    contract_errors = []
    if supplement is None:
        contract_errors.append("supplement decision missing or invalid")
    elif supplement == "ADD" and set(optional_present) != set(OPTIONAL):
        contract_errors.append("ADD requires complete P50/P75 supplement")
    elif supplement == "SKIP" and optional_present:
        contract_errors.append("SKIP forbids P50/P75 supplement")
    if missing or extras or contract_errors:
        return {"schema": 3, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "CACHE_VERDICT": "NO_DECISION",
                "missing_cells": missing, "extra_cells": sorted(extras), "errors": contract_errors}

    order = ["A0-pre", "T128-P25"]
    if supplement == "ADD":
        order += ["T128-P50", "T128-P75"]
    order += ["T128-R", "T128-W", "A0-post"]
    rows, errors = [], []
    for name in order:
        try:
            rows.append(analyze_cell(root, name))
        except EvidenceError as exc:
            errors.append(str(exc))
    if errors:
        return {"schema": 3, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "CACHE_VERDICT": "NO_DECISION",
                "errors": errors, "cells": rows}

    by_name = {row["cell"]: row for row in rows}
    def triple(name):
        row = by_name[name]
        read = row["bandwidth"]["read"]["mean_MiBs"]
        write = row["bandwidth"]["write"]["mean_MiBs"]
        return (read, write, (read + write) / 2)
    pre, post = triple("A0-pre"), triple("A0-post")
    drift = max(abs(post[i] / pre[i] - 1) * 100 for i in range(3))
    margin = max(5.0, drift)
    points = []
    intermediates = order[1:-1]
    for index, name in enumerate(intermediates, 1):
        value = triple(name)
        fraction = index / (len(intermediates) + 1)
        ref = tuple(pre[i] + fraction * (post[i] - pre[i]) for i in range(3))
        points.append({"cell": name, "read_MiBs": value[0], "write_MiBs": value[1],
                       "mean_direction_MiBs": value[2], "read_effect_pct": _relative(value[0], ref[0]),
                       "write_effect_pct": _relative(value[1], ref[1]),
                       "mean_effect_pct": _relative(value[2], ref[2]),
                       "a0_reference": {"read_MiBs": ref[0], "write_MiBs": ref[1], "mean_direction_MiBs": ref[2]},
                       "lifecycle_safe": by_name[name]["lifecycle"]["safe"]})
    point_map = {point["cell"]: point for point in points}
    p25 = point_map["T128-P25"]
    p25_direct_effect = {"read_pct": _relative(p25["read_MiBs"], pre[0]),
                         "write_pct": _relative(p25["write_MiBs"], pre[1]),
                         "mean_pct": _relative(p25["mean_direction_MiBs"], pre[2])}
    provisional = (p25_direct_effect["mean_pct"] >= 0 and p25_direct_effect["read_pct"] > -5 and
                   p25_direct_effect["write_pct"] > -5 and p25["lifecycle_safe"])
    expected_supplement = "ADD" if provisional else "SKIP"
    if supplement != expected_supplement:
        return {"schema": 3, "RUN_VALIDITY_STATE": "EVIDENCE_INVALID", "CACHE_VERDICT": "NO_DECISION",
                "errors": [f"supplement decision {supplement} disagrees with registered rule {expected_supplement}"],
                "A0_drift_pct": drift, "M_pct": margin, "points": points, "cells": rows}

    validity = "RESOLUTION_INSUFFICIENT" if drift > 8 else "VALID"
    pure_best = max(point_map[name]["mean_direction_MiBs"] for name in ("T128-R", "T128-W"))
    candidates = []
    for name in ("T128-P25", "T128-P50", "T128-P75"):
        if name not in point_map:
            continue
        point = point_map[name]
        if (point["lifecycle_safe"] and point["mean_effect_pct"] >= margin and
                point["read_effect_pct"] > -margin and point["write_effect_pct"] > -margin and
                _relative(point["mean_direction_MiBs"], pure_best) >= -margin):
            candidates.append(name)
    verdict = ("MIXED_CACHE_CANDIDATE_REQUIRES_L2" if validity == "VALID" and candidates else
               "NO_MATERIAL_MIXED_CACHE_CANDIDATE" if validity == "VALID" else "NO_DECISION")
    old_p25_mean = 1474.16
    repair_delta = _relative(p25["mean_direction_MiBs"], old_p25_mean)
    return {"schema": 3, "run_id": root.name.removeprefix("opencode-04tmp2i-"),
            "RUN_VALIDITY_STATE": validity, "CACHE_VERDICT": verdict,
            "A0_drift_pct": drift, "M_pct": margin, "supplement_decision": supplement,
            "p25_provisional_signal": provisional, "p25_direct_A0_pre_effect": p25_direct_effect,
            "mixed_candidates": candidates, "points": points,
            "post_repair_difference": {"old_04tmp2h_T128_P25_mean_MiBs": old_p25_mean,
                                       "difference_pct": repair_delta,
                                       "label": "POST_REPAIR_DIFFERENCE_MATERIAL" if repair_delta >= 10 else "POST_REPAIR_DIFFERENCE_NOT_MATERIAL",
                                       "causal_claim": False},
            "cells": rows, "formal_window_seconds": [FORMAL_START, FORMAL_STOP]}


# Override the inherited 04-tmp2h multi-capacity analyzer with the registered
# 04-tmp2i T128-only contract while retaining its mature parsing primitives.
analyze = _tmp2i_analyze


def _fixture_cell(cell, read=100.0, write=100.0, start_ns=1_000_000_000):
    cell.mkdir(parents=True, exist_ok=True); (cell / "PASS").write_text("\n")
    (cell / "fio.rc").write_text("0\n"); (cell / "sampler.rc").write_text("0\n")
    read_bytes = int(read * 1048576 * 180 / JOBS)
    write_bytes = int(write * 1048576 * 180 / JOBS)
    jobs = [{"error": 0, "read": {"runtime": 180000, "io_bytes": read_bytes},
             "write": {"runtime": 180000, "io_bytes": write_bytes}} for _ in range(JOBS)]
    (cell / "fio.json").write_text(json.dumps({"jobs": jobs})); (cell / "fio-end-epoch-ns.txt").write_text(str(start_ns + 180_000_000_000)); (cell / "fio-start-epoch-ns.txt").write_text(str(start_ns))
    bw = cell / "bw"; bw.mkdir(exist_ok=True)
    for job in range(1, JOBS + 1):
        with (bw / f"randrw_bw.{job}.log").open("w") as out:
            for sec in range(1, 181): out.write(f"{sec * 1000},{read * 1024},0,0\n{sec * 1000},{write * 1024},1,0\n")
    with (cell / "runtime.tsv").open("w") as out:
        out.write("epoch_ns\thit_bytes\tmiss_bytes\traw_bytes\tstaging_bytes\tmin_free_bytes\tevicts\tdrops\n")
        for sec in range(181): out.write(f"{start_ns + sec * 1_000_000_000}\t{sec}\t{sec}\t100\t0\t1000000\t0\t0\n")
    if not cell.name.startswith("A0-"):
        (cell / "cache-inodes-formal-end.tsv").write_text(
            "path\tdevice\tinode\tsize_bytes\n/cache/raw/block\t1\t1\t100\n")
    (cell / "drain.tsv").write_text("epoch_ns\tstaging_blocks\tstaging_bytes\tstaging_files\tstaging_file_bytes\n1\t0\t0\t0\t0\n11\t0\t0\t0\t0\n"); (cell / "drain-seconds.txt").write_text("10\n")


def self_test(root):
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    for name in CORE:
        value = 95 if name == "T128-P25" else 100
        _fixture_cell(root / "cells" / name, value, value)
    (root / "supplement-decisions.tsv").write_text("T128\tSKIP\n")
    result = analyze(root)
    if result["RUN_VALIDITY_STATE"] != "VALID" or result["p25_provisional_signal"]:
        raise EvidenceError("five-cell early-stop fixture failed")
    p25 = root / "cells" / "T128-P25"
    lines = (p25 / "runtime.tsv").read_text().splitlines()
    (p25 / "runtime.tsv").write_text("\n".join(lines[:120]) + "\n")
    try:
        analyze_cell(root, "T128-P25")
    except EvidenceError:
        pass
    else:
        raise EvidenceError("sparse sampler fixture accepted")
    _fixture_cell(p25, 110, 110)
    (root / "supplement-decisions.tsv").write_text("T128\tADD\n")
    if analyze(root)["RUN_VALIDITY_STATE"] != "EVIDENCE_INVALID":
        raise EvidenceError("missing conditional supplement accepted")
    for name in OPTIONAL:
        _fixture_cell(root / "cells" / name, 108, 108)
    result = analyze(root)
    if result["RUN_VALIDITY_STATE"] != "VALID" or not result["p25_provisional_signal"]:
        raise EvidenceError("seven-cell supplement fixture failed")
    _fixture_cell(root / "cells" / "A0-post", 106, 106)
    _fixture_cell(root / "cells" / "T128-P25", 100.5, 100.5)
    result = analyze(root)
    if result["RUN_VALIDITY_STATE"] != "VALID" or not result["p25_provisional_signal"]:
        raise EvidenceError("runner/analyzer direct-A0 branch fixture failed")
    _fixture_cell(root / "cells" / "A0-post", 120, 120)
    if analyze(root)["RUN_VALIDITY_STATE"] != "RESOLUTION_INSUFFICIENT":
        raise EvidenceError("anchor drift fixture accepted")
    return {"status": "PASS", "mandatory_cells": len(CORE), "optional_cells": len(OPTIONAL),
            "defect_fixtures": ["five-cell-stop", "sparse-sampler", "missing-supplement",
                                "seven-cell-add", "direct-A0-branch", "anchor-drift"]}


def main():
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="command", required=True)
    for command in ("analyze", "self-test"):
        p = sub.add_parser(command); p.add_argument("--root", required=True, type=Path); p.add_argument("--output", required=True, type=Path)
    p = sub.add_parser("cell-summary"); p.add_argument("--cell", required=True, type=Path); p.add_argument("--output", required=True, type=Path)
    p = sub.add_parser("validate-cell"); p.add_argument("--root", required=True, type=Path); p.add_argument("--name", required=True); p.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "analyze": result = analyze(args.root)
    elif args.command == "self-test": result = self_test(args.root)
    elif args.command == "cell-summary": result = online_cell_summary(args.cell)
    else:
        result = {"status": "PASS", "cell": analyze_cell(args.root, args.name)}
    args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(result.get("CACHE_VERDICT", result.get("status", result.get("RUN_VALIDITY_STATE"))))


if __name__ == "__main__": main()
