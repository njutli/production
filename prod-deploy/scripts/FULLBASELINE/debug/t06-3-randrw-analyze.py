#!/usr/bin/env python3
"""06-3 offline burst-screen analysis; never connects to or mutates a test host.

The primary endpoint is the single fio group's bytes / max(R/W runtime).
Historical replay is retrospective, not a revision of the 06-1 verdict.
Only stateless percentile/Prometheus helpers are reused from 06-1; its window,
missing-second, runtime and screening gates are deliberately NOT imported.

Bandwidth log timestamps are relative milliseconds and values are KiB/s.
Intervals are integrated separately by direction, with overlap weighting.
Long directional gaps are UNKNOWN, not zeros or a claim that the next rate
held throughout the gap. The conventional previous-record integral is retained
as an explicitly provisional diagnostic. It is never rescaled to JSON bytes.
fio-3.28 source: https://raw.githubusercontent.com/axboe/fio/fio-3.28/stat.c
(__add_samples skips zero deltas; add_log_sample averages by direction).
"""
from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import importlib.util
import io
import json
import math
import re
import shlex
import statistics
import sys
import tarfile
from collections import defaultdict
from pathlib import Path, PurePosixPath

sys.dont_write_bytecode = True
_legacy_path = Path(__file__).with_name("t06-1-randrw-analyze.py")
if hashlib.sha256(_legacy_path.read_bytes()).hexdigest() != "47d33247eb0ced35d1bf283cd970fe2bd89735664f16177f1062bf5a2227ed38":
    raise SystemExit("frozen 06-1 analyzer dependency drift")
_spec = importlib.util.spec_from_file_location(
    "t061_offline_helpers", _legacy_path)
_legacy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_legacy)
percentile, parse_prom, metric = _legacy.percentile, _legacy.parse_prom, _legacy.metric
EvidenceError = _legacy.EvidenceError

MIB = 1048576
JOBS = 128
CELLS = ("C1", "S1", "W1", "W2", "S2", "C2")
HISTORY_CELLS = ("C1", "T1", "T2", "C2")
HISTORY_SHA256 = "ce8ec6c203d4bae4d8bf39cea38d1af64d7e67fe2a9001d6fa8b2af47383357c"
HISTORY_EXPECTED = {
    "C1": (1804.716316, 1808.101975), "T1": (2157.687192, 2161.697057),
    "T2": (2080.462626, 2083.520242), "C2": (1676.884347, 1680.624484),
}
JFS_MD5 = "24fae0852051c80ca571cb2f20275d46"
WORKLOAD = {"ioengine": "libaio", "iodepth": "128", "numjobs": "128",
            "rw": "randrw", "rwmixread": "50", "bs": "256k", "direct": "1",
            "filesize": "1g", "size": "1g", "openfiles": "128",
            "time_based": "1", "runtime": "180", "group_reporting": "1",
            "fallocate": "none", "allow_file_create": "0", "randrepeat": "1",
            "randseed": "20260915", "per_job_logs": "1", "log_avg_msec": "1000"}


class TextSource:
    """Adapter for the legacy read-only Prometheus parser; no temporary files."""
    def __init__(self, text):
        self.text = text

    def read_text(self, **_):
        return self.text


class Evidence:
    def __init__(self, files):
        self.files = files

    def text(self, name, required=True):
        if name not in self.files:
            if required:
                raise EvidenceError(f"missing evidence: {name}")
            return None
        return self.files[name]

    def data(self, name):
        return json.loads(self.text(name))

    def rows(self, name, required=True):
        content = self.text(name, required)
        return list(csv.DictReader(io.StringIO(content), delimiter="\t")) if content else []


def number(value, label, positive=False):
    if isinstance(value, bool) or value is None:
        raise EvidenceError(f"{label}: missing/invalid number")
    try:
        result = float(value)
    except (ValueError, TypeError) as exc:
        raise EvidenceError(f"{label}: not numeric") from exc
    if not math.isfinite(result) or result < 0 or (positive and result <= 0):
        raise EvidenceError(f"{label}: out of range")
    return result


def primary_endpoint(data, shell_start_ns, shell_end_ns, expected_jobs=JOBS):
    jobs = data.get("jobs")
    if not isinstance(jobs, list) or len(jobs) != 1:
        raise EvidenceError("fio JSON must contain exactly one complete group, not per-job rows")
    job = jobs[0]
    if job.get("error") != 0 or isinstance(job.get("error"), bool):
        raise EvidenceError("fio error missing/nonzero")
    if job.get("groupid") != 0:
        raise EvidenceError("fio groupid must be exactly 0")
    options = dict(data.get("global options", {}))
    options.update(job.get("job options", {}))
    if str(options.get("group_reporting")) != "1" or str(options.get("numjobs")) != str(expected_jobs):
        raise EvidenceError("group_reporting/numjobs do not establish the complete single group")
    times, directions = {}, {}
    for direction in ("read", "write"):
        part = job.get(direction, {})
        times[direction] = number(part.get("runtime"), direction + ".runtime", True)
        size = number(part.get("io_bytes"), direction + ".io_bytes", True)
        if not size.is_integer():
            raise EvidenceError(direction + ".io_bytes must be an integer")
        directions[direction] = {"io_bytes": int(size), "runtime_ms": times[direction]}
    runtime_ms = max(times.values())
    runtime = runtime_ms / 1000
    for part in directions.values():
        part["MiB_s"] = part["io_bytes"] / runtime / MIB
        part["historical_2700_target_gap_MiB_s"] = part["MiB_s"] - 2700
        part["above_historical_2700_numeric_target"] = part["MiB_s"] >= 2700
    start = int(shell_start_ns)
    end = int(shell_end_ns)
    if start <= 0 or end <= start:
        raise EvidenceError("invalid shell start/end bounds")
    if data.get("timestamp_ms") is not None:
        done_ns = int(number(data["timestamp_ms"], "timestamp_ms", True) * 1_000_000)
        source, tolerance = "fio.json.timestamp_ms", 0.002
    elif data.get("timestamp") is not None:
        # fio seconds are truncated; retain explicit ±1 s timing uncertainty.
        done_ns = int(number(data["timestamp"], "timestamp", True) * 1_000_000_000)
        source, tolerance = "fio.json.timestamp (one-second precision)", 1.002
    else:
        raise EvidenceError("fio completion timestamp missing; shell completion is not a replacement")
    actual_ns = done_ns - int(runtime_ms * 1_000_000)
    if done_ns > end + int(tolerance * 1e9) or done_ns < start - int(tolerance * 1e9):
        raise EvidenceError("JSON completion is outside shell timing bounds")
    if actual_ns < start - int(tolerance * 1e9):
        raise EvidenceError("JSON completion minus runtime precedes shell fork")
    return {"runtime_s": runtime, "directional": directions,
            "formula": "R/W.io_bytes / (max(read.runtime,write.runtime)/1000) / 2^20",
            "group_count": 1, "numjobs": expected_jobs,
            "job_runtime_ignored": job.get("job_runtime"),
            "actual_io_start_epoch_ns": actual_ns, "completion_epoch_ns": done_ns,
            "completion_source": source, "timing_precision_s": tolerance,
            "shell_start_epoch_ns": start, "shell_end_epoch_ns": end,
            "actual_minus_shell_start_s": (actual_ns - start) / 1e9,
            "shell_end_minus_json_completion_s": (end - done_ns) / 1e9,
            "completion_tail_after_180_s": max(0.0, runtime - 180)}


def log_intervals(content, runtime):
    previous = {0: 0.0, 1: 0.0}
    seen = set()
    intervals = {0: [], 1: []}
    for line, row in enumerate(csv.reader(io.StringIO(content)), 1):
        if not row or not any(x.strip() for x in row):
            continue
        if len(row) < 3:
            raise EvidenceError(f"short bandwidth row {line}")
        end = number(row[0], "bandwidth ms", True) / 1000
        value = number(row[1], "bandwidth KiB/s") / 1024
        direction = int(row[2])
        if direction not in (0, 1):
            raise EvidenceError("unsupported bandwidth direction")
        begin = previous[direction]
        if end <= begin or end > runtime + 0.010:
            raise EvidenceError(f"nonmonotonic/out-of-runtime log timestamp: {end}")
        # Per-direction records can differ by 1 ms. Do NOT use global-row time.
        # A >1.5 s interval at log_avg_msec=1000 may omit a no-completion
        # interval, a whole log record or have a delayed sample. None proves 0.
        trusted = end - begin <= 1.5
        intervals[direction].append((begin, min(end, runtime), value, trusted))
        previous[direction] = end
        seen.add(direction)
    if seen != {0, 1}:
        raise EvidenceError("bandwidth log lacks a READ or WRITE direction")
    return intervals


def interval_window(jobs, direction, left, right):
    duration = max(0.0, right - left)
    if not duration:
        return {"range_s": [left, right], "available": True, "MiB_s": None,
                "known_integral_MiB": 0.0, "unknown_job_seconds": 0.0,
                "provisional_overlap_integral_MiB": 0.0,
                "provisional_overlap_MiB_s": None}
    known, provisional, covered = 0.0, 0.0, 0.0
    for job in jobs:
        for begin, end, value, trusted in job[direction]:
            overlap = max(0.0, min(right, end) - max(left, begin))
            provisional += overlap * value
            if trusted:
                known += overlap * value
                covered += overlap
    unknown = max(0.0, duration * len(jobs) - covered)
    available = unknown < 1e-6
    return {"range_s": [left, right], "available": available,
            "MiB_s": known / duration if available else None,
            "known_integral_MiB": known, "unknown_job_seconds": unknown,
            "coverage_fraction": covered / (duration * len(jobs)),
            "provisional_overlap_integral_MiB": provisional,
            "provisional_overlap_MiB_s": provisional / duration,
            "provisional_values_are_not_signed_off": not available}


def bandwidth_diagnostics(files, primary, expected_jobs=JOBS):
    names = [name for name in files if re.fullmatch(r"formal/bw/randrw_bw\.\d+\.log", name)]
    ids = sorted(int(name.split(".")[-2]) for name in names)
    if ids != list(range(1, expected_jobs + 1)):
        raise EvidenceError(f"128-log completeness/unique IDs failed: got {len(ids)}/{expected_jobs}")
    runtime = primary["runtime_s"]
    jobs = [log_intervals(files[name], runtime) for name in names]
    result = {"log_count": len(jobs), "unknown_is_not_zero": True,
              "low_speed_samples_removed": 0, "rescale_factor": None,
              "integration_policy": "directional previous-record overlap; gaps >1.5 s and unrecorded tails unknown",
              "diagnostic_status": "COMPLETE"}
    for direction, label in enumerate(("read", "write")):
        full = interval_window(jobs, direction, 0, runtime)
        json_mib = primary["directional"][label]["io_bytes"] / MIB
        deviation = (full["provisional_overlap_integral_MiB"] / json_mib - 1) * 100
        windows = {f"W{i+1}": interval_window(jobs, direction, i * 45, (i + 1) * 45)
                   for i in range(4)}
        legacy = interval_window(jobs, direction, 15, 175)
        tail = interval_window(jobs, direction, 180, max(180, runtime))
        checks = []
        if abs(deviation) > 5:
            checks.append("REVIEW_LOG_JSON_INTEGRAL_DIFFERENCE_GT_5_PERCENT")
            # Values remain visible as diagnostics, but no associated window is
            # signed off until the integral mismatch has been explained.
            for window in list(windows.values()) + [legacy, tail]:
                window["available"] = False
                window["MiB_s"] = None
                window["provisional_values_are_not_signed_off"] = True
        if not full["available"]:
            checks.append("DIAGNOSTIC_LIMITED_UNKNOWN_INTERVAL_OR_JOB_COMPLETION_TAIL")
        if checks:
            result["diagnostic_status"] = "REVIEW" if abs(deviation) > 5 else (
                result["diagnostic_status"] if result["diagnostic_status"] == "REVIEW" else "DIAGNOSTIC_LIMITED")
        # Never compute a CV by deleting unknown or slow seconds.
        second_stats = None
        if legacy["available"]:
            seconds = [interval_window(jobs, direction, second, second + 1)["MiB_s"]
                       for second in range(15, 175)]
            mean = statistics.mean(seconds)
            second_stats = {"mean_MiB_s": mean, "median_MiB_s": statistics.median(seconds),
                            "CV_pct": statistics.pstdev(seconds) / mean * 100 if mean else None,
                            "P10_MiB_s": percentile(seconds, .1), "P90_MiB_s": percentile(seconds, .9)}
        w1, w4 = windows["W1"]["MiB_s"], windows["W4"]["MiB_s"]
        result[label] = {"full_log_integral": full,
                         "log_minus_json_integral_pct": deviation,
                         "json_minus_provisional_log_MiB": json_mib - full["provisional_overlap_integral_MiB"],
                         "windows_45s": windows, "tail_after_180s": tail,
                         "legacy_15_175_diagnostic_only": legacy,
                         "legacy_second_statistics": second_stats,
                         "W4_over_W1": w4 / w1 if w1 and w4 is not None else None,
                         "issues": checks}
    return result


def optional_metric(snapshot, name, method=""):
    try:
        return metric(snapshot, name, method)
    except EvidenceError:
        return None


def mechanism_diagnostics(evidence, primary, registration=None):
    start, end = primary["actual_io_start_epoch_ns"], primary["completion_epoch_ns"]
    result = {"scope": "actual full I/O interval; observed peaks, not an unobserved true maximum",
              "issues": []}
    rows = [row for row in evidence.rows("meminfo-1hz.tsv", False)
            if start <= int(row["epoch_ns"]) <= end]
    result["meminfo_samples"] = len(rows)
    for field in ("Dirty_kB", "Writeback_kB", "Cached_kB"):
        result[field.replace("_kB", "_observed_peak_GiB")] = (
            max(number(row[field], field) for row in rows) / 1048576 if rows else None)
    snapshots = []
    for name in evidence.files:
        match = re.fullmatch(r"mechanism/(\d+)\.prom", name)
        if match and start <= int(match[1]) <= end:
            snapshots.append((int(match[1]), parse_prom(TextSource(evidence.files[name]))))
    snapshots.sort(key=lambda item: item[0])
    result["prom_samples"] = len(snapshots)
    gauges = {"staging_bytes": "juicefs_staging_block_bytes",
              "staging_blocks": "juicefs_staging_blocks",
              "staging_writing_blocks": "juicefs_staging_writing_blocks",
              "uploading": "juicefs_object_request_uploading",
              "blockcache_bytes": "juicefs_blockcache_bytes"}
    for label, name in gauges.items():
        values = [value for _, snap in snapshots if (value := optional_metric(snap, name)) is not None]
        result[label + "_observed_peak"] = max(values) if values else None
    result["counter_deltas"] = {}
    if len(snapshots) >= 2:
        result["counter_interval_s"] = (snapshots[-1][0] - snapshots[0][0]) / 1e9
        result["max_sampling_gap_s"] = max((b[0] - a[0]) / 1e9 for a, b in zip(snapshots, snapshots[1:]))
        specs = dict(_legacy.COUNTER_SPECS)
        if registration:
            specs["staging_errors"] = (registration["staging_errors"], "")
        for label, (name, method_name) in specs.items():
            values = [optional_metric(snap, name, method_name) for _, snap in snapshots]
            if any(value is None for value in values):
                if (label in ("object_errors", "staging_errors") and all(value is None for value in values)
                        and registration and registration.get("error_counter_absent_is_zero") is True):
                    result["counter_deltas"][label] = 0
                    result["issues"].append("zero_by_approved_absent_error_counter_registration:" + label)
                else:
                    result["counter_deltas"][label] = None
                    result["issues"].append("missing_counter:" + label)
            elif any(b < a for a, b in zip(values, values[1:])):
                result["counter_deltas"][label] = None
                result["issues"].append("counter_reset:" + label)
            else:
                result["counter_deltas"][label] = values[-1] - values[0]
        hits = result["counter_deltas"].get("hit_bytes")
        misses = result["counter_deltas"].get("miss_bytes")
        result["hit_ratio"] = hits / (hits + misses) if hits is not None and misses is not None and hits + misses else None
    else:
        result["issues"].append("insufficient_prom_samples")
    if not rows:
        result["issues"].append("missing_full_interval_meminfo")
    return result


def lifecycle_diagnostics(evidence, primary):
    result = {"content_correctness": "NOT_PROVEN", "remote_readable": False,
              "drain_seconds": None, "terminal_zero_samples": 0, "issues": []}
    try:
        result["drain_seconds"] = number(evidence.text("drain-seconds.txt").strip(), "drain_seconds")
        result["write_MiB_s_including_drain_descriptive"] = primary["directional"]["write"]["io_bytes"] / (
            primary["runtime_s"] + result["drain_seconds"]) / MIB
    except (EvidenceError, ValueError) as exc:
        result["issues"].append(str(exc))
    drain = evidence.rows("drain.tsv", False)
    state = dict(line.split("\t", 1) for line in (evidence.text("state.tsv", False) or "").splitlines() if "\t" in line)
    non_wb = state.get("arm") in ("C", "S")
    zero_fields = ("staging_blocks", "staging_bytes", "staging_writing_blocks",
                   "staging_files", "staging_file_bytes")
    valid_drain = [row for row in drain if all(field in row for field in zero_fields)]
    if valid_drain:
        by_time = defaultdict(list)
        for row in valid_drain:
            by_time[int(row["epoch_ns"])].append(row)
        for timestamp in sorted(by_time, reverse=True):
            if all(queue_value_zero(row[field], field, non_wb) for row in by_time[timestamp]
                   for field in zero_fields + tuple(f for f in ("pending", "uploading") if f in row)):
                result["terminal_zero_samples"] += 1
            else:
                break
        stages = [number(row["staging_bytes"], "staging_bytes") for row in valid_drain if row["staging_bytes"] != "NA"]
        result["drain_staging_bytes_observed_peak"] = max(stages) if stages else None
        result["non_writeback_staging_gauges_not_registered"] = non_wb and not stages
        result["drain_terminal_epoch_ns"] = max(by_time)
    try:
        rb = evidence.data("readback/fio.json")
        jobs = rb.get("jobs", [])
        checks = dict(line.split("\t", 1) for line in evidence.text("readback-verify.tsv").splitlines() if "\t" in line)
        result["remote_readable"] = bool(jobs) and all(job.get("error") == 0 and
            number(job.get("read", {}).get("io_bytes"), "readback.io_bytes", True) > 0 for job in jobs) and checks.get("rc") == "0"
    except (EvidenceError, ValueError) as exc:
        result["issues"].append(str(exc))
    recovery = evidence.text("post-warmup-recovery-seconds.txt", False)
    result["post_warmup_recovery_seconds"] = number(recovery.strip(), "recovery_seconds") if recovery else None
    return result


def capture_check(errors, label, fn):
    try:
        fn()
    except (EvidenceError, KeyError, ValueError, TypeError, IndexError) as exc:
        errors.append(label + ": " + str(exc))


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def queue_value_zero(value, field, non_wb=False):
    # In C/S, WB staging gauges may be absent because that subsystem is not
    # instantiated. The JuiceFS pending gauge is unregistered on this binary;
    # NA is a registration state, not a measured zero. Uploading and the
    # independently traversed rawstaging files still MUST be zero.
    if field == "pending":
        return value == "NA"
    if value == "NA" and non_wb and field in ("staging_blocks", "staging_bytes", "staging_writing_blocks"):
        return True
    return number(value, field) == 0


def argv_options(text):
    words = shlex.split(text)
    options = {}
    for index, word in enumerate(words):
        if not word.startswith("--"):
            continue
        if "=" in word:
            key, value = word.split("=", 1)
        else:
            key = word
            value = words[index + 1] if index + 1 < len(words) and not words[index + 1].startswith("--") else True
        require(key not in options, "duplicate command flag: " + key)
        options[key] = value
    return words, options


def validate_quiet_baseline(shared):
    rows = shared.rows("quiet-baseline.tsv")
    timestamps = [int(row["epoch_ns"]) for row in rows]
    require(len(rows) >= 2 and timestamps == sorted(set(timestamps)), "quiet timestamps invalid")
    require(timestamps[-1] - timestamps[0] >= 120e9, "quiet baseline shorter than 120 seconds")
    require(max(b - a for a, b in zip(timestamps, timestamps[1:])) <= 3e9, "quiet baseline sampling gap")
    # Match the frozen driver's nearest-rank P95, independently recomputed.
    dirty = sorted(number(row["Dirty_kB"], "quiet Dirty") for row in rows)[math.ceil(.95 * len(rows)) - 1]
    writeback = sorted(number(row["Writeback_kB"], "quiet Writeback") for row in rows)[math.ceil(.95 * len(rows)) - 1]
    computed = {"dirty_limit_kB": dirty + 8 * 1024 * 1024,
                "writeback_limit_kB": writeback + 1024 * 1024}
    baseline = shared.data("quiet-baseline.json")
    require(baseline.get("p95_method") == "nearest_rank", "quiet P95 method not frozen")
    for key, value in computed.items():
        require(abs(number(baseline.get(key), key) - value) <= 1, "quiet JSON does not match independently derived " + key)
    return computed, timestamps[-1]


def validate_new_cell(evidence, shared, name, primary, mechanism, lifecycle):
    """Independently recompute core checks; a PASS marker is never sufficient."""
    errors = []
    try:
        contract = shared.data("gate0/approved-contract.json")
        require(contract.get("schema") == "06-3-v1" and contract.get("status") == "APPROVED", "contract schema/approval")
        require(contract.get("metrics", {}).get("pending") == "UNREGISTERED", "pending registration contract")
        require(re.fullmatch(r"[0-9]{8}-[0-9]{6}", str(contract.get("run_id", ""))), "contract RUN_ID")
        require(not set(contract["approved_osd_flags"]) & {"noscrub", "nodeep-scrub", "noout", "nobackfill", "norecover", "pause", "pauserd", "pausewr"}, "unsafe preexisting OSD flag")
    except (EvidenceError, ValueError, TypeError) as exc:
        contract = {}
        errors.append("frozen contract: " + str(exc))
    data = evidence.data("formal/fio.json")
    options = dict(data.get("global options", {}))
    options.update(data["jobs"][0].get("job options", {}))
    def workload():
        require(primary["runtime_s"] >= 179.999, "formal workload ended before planned 180 seconds")
        for key, expected in WORKLOAD.items():
            require(str(options.get(key, "")).lower() == expected, "fio workload mismatch: " + key)
        require(options.get("filename_format") == f"/tmp/jfs-06-3-{contract['run_id']}-{name}/test_dir/rw_test.$jobnum.0", "formal fio filename_format or cross-RUN data")
        require(evidence.text("formal/fio.rc").strip() == "0", "formal fio rc nonzero")
        require(evidence.text("warmup/fio.rc").strip() == "0", "warmup rc nonzero")
        warm = evidence.data("warmup/fio.json")
        require(bool(warm.get("jobs")) and all(j.get("error") == 0 for j in warm["jobs"]), "warmup fio errors")
        warm_opts = dict(warm.get("global options", {}))
        warm_opts.update(warm["jobs"][0].get("job options", {}))
        require(str(warm_opts.get("rw")) == "randread" and str(warm_opts.get("runtime")) == "60", "warmup not 60-second randread")
        require(max(number(job.get("read", {}).get("runtime"), "warmup.runtime", True) for job in warm["jobs"]) >= 59999, "warmup finished early")
    capture_check(errors, "workload", workload)
    def identity():
        state = dict(line.split("\t", 1) for line in evidence.text("state.tsv").splitlines() if "\t" in line)
        arm = name[0]
        for key, expected in (("cell", name), ("arm", arm),
                              ("cache_mib", "0" if arm == "C" else "98304"),
                              ("writeback", "1" if arm == "W" else "0"),
                              ("cache_large_write", "0" if arm == "C" else "1")):
            require(state.get(key) == expected, "state mismatch: " + key)
        for tag in ("formal", "verify"):
            rows = evidence.rows("mount-process-" + tag + ".tsv")
            require(len(rows) == 2 and sum(row["is_worker"] == "yes" for row in rows) == 1, "mount parent/worker identity")
            require(all(row["exe_md5"] == JFS_MD5 and int(row["starttime_ticks"]) > 0 for row in rows), "binary identity")
            found = evidence.text("findmnt-" + tag + ".tsv")
            require("fuse.juicefs" in found and "JuiceFS:juicefs-prod" in found, "mount source/type")
            words, flags = argv_options(evidence.text("mount-command-" + tag + ".txt"))
            require("mount" in words, "mount launch command absent")
            destination = f"/tmp/jfs-06-3-{contract['run_id']}-{name}" + ("-verify" if tag == "verify" else "")
            require(words[-1] == destination and words[-2] == contract["meta"], "actual mount destination/META mismatch")
            require(destination in found.split(), "findmnt destination mismatch")
            for flag, expected in (("--max-fuse-io", "256K"), ("--buffer-size", "300"),
                                   ("--max-uploads", "150"), ("--max-downloads", "200")):
                require(flags.get(flag) == expected, "common mount option mismatch: " + flag)
            cached = tag == "formal" and arm in ("S", "W")
            require(flags.get("--cache-size") == ("98304" if cached else "0"), "actual cache size mismatch")
            require(("--writeback" in flags) == (tag == "formal" and arm == "W"), "actual writeback mismatch")
            require(("--cache-large-write" in flags) == cached, "actual cache-large-write mismatch")
            require("--cache-partial-only" not in flags, "unregistered cache-partial-only")
            if cached:
                require(flags.get("--cache-dir") == state["cache_dirs"], "actual cache path mismatch")
                require(float(flags.get("--free-space-ratio", -1)) == .20 and str(flags.get("--upload-delay")) in ("0", "0s"), "cache free-space/upload-delay mismatch")
        assets = evidence.text("assets-before.tsv")
        require(assets == evidence.text("assets-mounted.tsv") == evidence.text("assets-after.tsv"), "asset identity changed")
        rows = [row.split("\t") for row in assets.splitlines() if row]
        require(len(rows) == 128 and {row[0] for row in rows} == {f"rw_test.{n}.0" for n in range(128)} and
                all(len(row) == 3 and int(row[2]) == 1073741824 for row in rows), "asset set/size")
        require(len({row[1] for row in rows}) == 128, "asset inode alias")
        require(hashlib.sha256(assets.encode()).hexdigest() == contract["assets_sha256"], "asset hash differs from approved inventory")
    capture_check(errors, "identity", identity)
    def health():
        for tag in ("before", "post-warmup", "pre-formal", "after"):
            base = "health-" + tag + "/"
            status = evidence.data(base + "ceph-status.json")
            require(status.get("fsid") == contract["ceph_fsid"], "Ceph FSID mismatch")
            h = status.get("health", {})
            flags = evidence.data(base + "osd-dump.json").get("flags", [])
            if isinstance(flags, str):
                flags = flags.split(",")
            flags = {flag.strip().replace("nodeep_scrub", "nodeep-scrub") for flag in flags if flag.strip()}
            require(flags == set(contract["approved_osd_flags"]) | {"noscrub", "nodeep-scrub"}, "foreign/missing OSD flags")
            checks = h.get("checks", {})
            if h.get("status") == "HEALTH_OK":
                require(not checks, "HEALTH_OK contradicts checks")
            else:
                require(h.get("status") == "HEALTH_WARN" and set(checks) == {"OSDMAP_FLAGS"}, "Ceph health")
                warning = checks["OSDMAP_FLAGS"].get("summary", {}).get("message", "")
                match = re.fullmatch(r"(.+?) flag\(s\) set", warning)
                require(match and {flag.strip().replace("nodeep_scrub", "nodeep-scrub") for flag in match[1].split(",")} == {"noscrub", "nodeep-scrub"}, "foreign warning flags")
            osds = evidence.data(base + "osd-stat.json")
            require(all(osds.get(key) == 6 for key in ("num_osds", "num_up_osds", "num_in_osds")), "OSD count")
            states = [line.split()[1] for line in evidence.text(base + "pgs.txt").splitlines()
                      if len(line.split()) > 1 and line.split()[0][:1].isdigit()]
            require(states and all(state == "active+clean" for state in states), "PG state")
    capture_check(errors, "health", health)
    def restoration():
        require(lifecycle["remote_readable"], "readback JSON/rc not closed")
        require(lifecycle["drain_seconds"] is not None, "drain timing absent")
        require(lifecycle["terminal_zero_samples"] >= 3, "need three consecutive zero drain snapshots")
        zero_fields = ("staging_blocks", "staging_bytes", "staging_writing_blocks", "pending", "uploading", "staging_files", "staging_file_bytes")
        drain_rows = evidence.rows("drain.tsv")
        require(all(all(field in row for field in zero_fields) for row in drain_rows), "drain lacks core pending/uploading fields")
        require(all(row["pending"] == "NA" for row in drain_rows), "unregistered pending must be NA in drain")
        drain_times = [int(row["epoch_ns"]) for row in drain_rows]
        require(drain_times == sorted(set(drain_times)), "drain sampling timestamps invalid")
        require(drain_times[0] >= primary["completion_epoch_ns"], "drain raw precedes formal completion")
        strict_done = int(evidence.text("strict-drain-end-ns.txt"))
        require(strict_done >= drain_times[-1], "strict-drain timestamp precedes final zero")
        readback_done = number(evidence.data("readback/fio.json").get("timestamp_ms"), "readback timestamp_ms", True) * 1000000
        require(readback_done >= strict_done, "readback precedes strict drain")
        require(evidence.text("RECOVERY_PASS", False) is not None, "recovery completion absent")
        rows = evidence.rows("recovery.tsv")
        require(rows, "recovery raw absent")
        require(all(row.get("pending") == "NA" for row in rows), "unregistered pending must be NA in recovery")
        baseline, baseline_end = validate_quiet_baseline(shared)
        dirty_limit = baseline["dirty_limit_kB"]
        writeback_limit = baseline["writeback_limit_kB"]
        warm = evidence.data("warmup/fio.json")
        warm_done_ns = int(number(warm.get("timestamp_ms"), "warmup.timestamp_ms", True) * 1000000)
        require(baseline_end < warm_done_ns, "quiet baseline was not frozen before warmup")
        zeros = ("staging_blocks", "staging_bytes", "staging_writing_blocks", "pending", "uploading", "staging_files", "staging_file_bytes")
        clean = []
        for row in reversed(rows):
            if (number(row["Dirty_kB"], "Dirty") > dirty_limit or
                number(row["Writeback_kB"], "Writeback") > writeback_limit or
                any(not queue_value_zero(row[key], key, not name.startswith("W")) for key in zeros)):
                break
            clean.append(int(row["epoch_ns"]))
        require(len(clean) >= 2 and max(clean) - min(clean) >= 30e9, "post-warmup recovery not sustained 30 seconds")
        require(min(clean) >= warm_done_ns, "recovery clean window began before warmup completed")
        require(max(clean) <= primary["shell_start_epoch_ns"], "recovery occurs after formal fork")
        require(max(b - a for a, b in zip(sorted(clean), sorted(clean)[1:])) <= 3e9, "recovery raw sampling gap")
    capture_check(errors, "recovery", restoration)
    def capacity():
        space = contract["space"]
        stop_avail = sum(number(space[key], key, True) for key in ("filesystem_reserve_bytes", "business_reserve_bytes", "stop_margin_bytes"))
        min_mem = number(space["minimum_mem_available_bytes"], "minimum_mem_available_bytes", True)
        cell_ceiling = sum(number(space[key], key, True) for key in ("read_cache_bytes", "worst_backlog_bytes"))
        initial = evidence.rows("start-resources.tsv")
        require(len(initial) == 1, "initial resource evidence missing/ambiguous")
        require(int(initial[0]["epoch_ns"]) < primary["shell_start_epoch_ns"] and
                number(initial[0]["avail_bytes"], "initial avail") >= number(space["minimum_start_avail_bytes"], "minimum_start_avail_bytes", True) and
                number(initial[0]["MemAvailable_bytes"], "initial memory") >= min_mem, "approved initial resource budget")
        rows = evidence.rows("safety.tsv")
        start, end = primary["actual_io_start_epoch_ns"], primary["completion_epoch_ns"]
        sampled = [row for row in rows if start - 1e9 <= int(row["epoch_ns"]) <= end + 1e9]
        require(sampled, "space/memory safety raw missing")
        timestamps = [int(row["epoch_ns"]) for row in sampled]
        require(timestamps == sorted(set(timestamps)), "safety timestamp order")
        max_gap_ns = (9 + number(space["monitor_interval_seconds"], "monitor_interval_seconds", True)) * 1e9
        require(timestamps[0] - start <= max_gap_ns and end - timestamps[-1] <= max_gap_ns, "safety does not cover I/O boundaries")
        require(len(timestamps) > 1 and max(b - a for a, b in zip(timestamps, timestamps[1:])) <= max_gap_ns, "safety raw sampling gap")
        require(all(number(row["avail_bytes"], "avail") >= stop_avail and
                    number(row["MemAvailable_bytes"], "MemAvailable") >= min_mem for row in sampled), "approved space/memory safety threshold")
        start_avail = number(initial[0]["avail_bytes"], "initial avail", True)
        require(all(number(row["avail_bytes"], "avail") + cell_ceiling >= start_avail for row in sampled),
                "approved per-cell cache-plus-stage occupancy ceiling")
    capture_check(errors, "capacity", capacity)
    for label in ("object_errors", "staging_errors"):
        value = mechanism["counter_deltas"].get(label)
        if value is None:
            errors.append("safety error counter unavailable: " + label)
        elif value != 0:
            errors.append("safety error counter nonzero: " + label)
    if re.search(r"stage.?full|upload it directly", evidence.text("juicefs-formal.log", False) or "", re.I):
        mechanism["issues"].append("stageFull_pressure_or_direct_upload_fallback_observed; not alone an evidence invalidation")
    return errors


def analyze_cell(evidence, name, shared=None, historical=False):
    primary = primary_endpoint(evidence.data("formal/fio.json"),
        evidence.text("formal/fio-start-epoch-ns.txt"), evidence.text("formal/fio-end-epoch-ns.txt"))
    issues = []
    try:
        bw = bandwidth_diagnostics(evidence.files, primary)
    except (EvidenceError, ValueError) as exc:
        bw = {"diagnostic_status": "DIAGNOSTIC_LIMITED", "error": str(exc)}
        issues.append("missing_or_malformed_raw_bandwidth_logs: " + str(exc))
    try:
        registration = None if historical else shared.data("gate0/approved-contract.json")["metrics"]
        mechanism = mechanism_diagnostics(evidence, primary, registration)
    except (EvidenceError, ValueError, KeyError, TypeError) as exc:
        mechanism = {"issues": [str(exc)], "counter_deltas": {}}
    try:
        lifecycle = lifecycle_diagnostics(evidence, primary)
    except (EvidenceError, ValueError, KeyError, TypeError) as exc:
        lifecycle = {"content_correctness": "NOT_PROVEN", "remote_readable": False,
                     "drain_seconds": None, "terminal_zero_samples": 0, "issues": [str(exc)]}
    core = [] if historical else validate_new_cell(evidence, shared, name, primary, mechanism, lifecycle)
    # Missing raw logs invalidates the new evidence package, NOT arithmetic
    # traceability of its separately displayed byte/runtime endpoint.
    if not historical:
        core.extend(issues)
    return {"cell": name, "primary": primary, "primary_endpoint_status": "TRACEABLE",
            "bandwidth_diagnostics": bw, "mechanism": mechanism, "lifecycle": lifecycle,
            "nonperformance_errors": core, "diagnostic_issues": issues,
            "EVIDENCE_VALIDITY": "RETROSPECTIVE_ONLY" if historical else ("EVIDENCE_INVALID" if core else "VALID")}


def pair_matrix(rows):
    by = {row["cell"]: row for row in rows}
    effects = {}
    valid = set(by) == set(CELLS) and all(row.get("EVIDENCE_VALIDITY") == "VALID" for row in rows)
    for numerator, denominator in (("S", "C"), ("W", "C"), ("W", "S")):
        label = numerator + "/" + denominator
        if not all(arm + str(i) in by for arm in (numerator, denominator) for i in (1, 2)):
            effects[label] = {"SCREEN_DECISION": "NO_DECISION_MISSING_CELL"}
            continue
        detail, directional_pass = {}, []
        for direction in ("read", "write"):
            value = lambda arm, i: by[arm + str(i)]["primary"]["directional"][direction]["MiB_s"]
            gains = [(value(numerator, i) / value(denominator, i) - 1) * 100 for i in (1, 2)]
            drift = {arm: (value(arm, 2) / value(arm, 1) - 1) * 100 for arm in (numerator, denominator)}
            epsilon = max(abs(x) for x in drift.values())
            material = max(5.0, 2 * epsilon)
            passed = all(gain > 0 and gain + 1e-10 >= material for gain in gains)
            directional_pass.append(passed)
            detail[direction] = {"paired_effects_pct": gains, "same_arm_change_pct": drift,
                "epsilon_pct": epsilon, "M_pct": material,
                "fine_effect_resolution_insufficient": epsilon >= 5,
                "two_pairs_above_material_line": passed,
                "ratio_of_means_pct_descriptive": ((value(numerator, 1) + value(numerator, 2)) /
                    (value(denominator, 1) + value(denominator, 2)) - 1) * 100}
        effects[label] = {"directional": detail,
            "SCREEN_DECISION": "NO_DECISION_EVIDENCE_INVALID" if not valid else (
                "SCREEN_CONTINUE" if all(directional_pass) else "SCREEN_STOP_NO_CLEAR_REPEATABLE_BENEFIT"),
            "causal_scope": "WB increment on S base" if denominator == "S" else "configuration package, not isolated CLW effect"}
    return {"comparisons": effects, "RUN_VALIDITY_STATE": "VALID" if valid else "EVIDENCE_INVALID",
            "positions": {"C": [1, 6], "S": [2, 5], "W": [3, 4]},
            "arm_mean_position": {"C": 3.5, "S": 3.5, "W": 3.5},
            "balanced_positions_do_not_prove_state_symmetry": True,
            "production_delivery": "NOT_DECIDED_BY_L1_SCREEN"}


def wanted(name):
    # Exclude enormous latency/CPU logs and all unrelated payloads. No extractall.
    return (name in {"quiet-baseline.json", "quiet-baseline.tsv", "commands.sh", "gate0/approved-contract.json"} or
            bool(re.fullmatch(r"cells/[^/]+/(?:[^/]+|formal/(?:fio\.json|fio\.job|fio\.rc|fio-(?:start|end)-epoch-ns\.txt)|formal/bw/randrw_bw\.\d+\.log|warmup/(?:fio\.json|fio\.rc)|readback/fio\.json|mechanism/\d+\.prom|health-(?:before|after|post-warmup|pre-formal)/(?:ceph-status\.json|osd-stat\.json|osd-dump\.json|pgs\.txt))", name)))


def load_tree(root):
    files = {}
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        if path.is_file() and wanted(relative):
            require(not path.is_symlink() and path.resolve().is_relative_to(root.resolve()), "symlink evidence unsupported")
            files[relative] = path.read_text(errors="strict")
    return files


def load_archive(path, expected_sha=HISTORY_SHA256):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    require(actual == expected_sha, "historical archive SHA256 mismatch: " + actual)
    files, roots = {}, set()
    with tarfile.open(path, "r|gz") as archive:
        for member in archive:
            parts = PurePosixPath(member.name).parts
            require(not PurePosixPath(member.name).is_absolute() and ".." not in parts, "unsafe archive member")
            if len(parts) < 2:
                continue
            relative = "/".join(parts[1:])
            if member.isdir():
                continue
            if not wanted(relative):
                continue
            roots.add(parts[0])
            require(member.isfile() and not member.issym() and not member.islnk(), "non-regular selected archive member")
            require(relative not in files, "duplicate selected archive member")
            require(member.size <= 32 * 1024 * 1024, "oversized evidence member")
            files[relative] = archive.extractfile(member).read().decode("utf-8")
    require(len(roots) == 1, "archive must have exactly one RUN root")
    return files, actual


def analyze_files(files, historical=False):
    cells, failures = [], []
    for name in HISTORY_CELLS if historical else CELLS:
        prefix = "cells/" + name + "/"
        evidence = Evidence({key[len(prefix):]: value for key, value in files.items() if key.startswith(prefix)})
        try:
            cells.append(analyze_cell(evidence, name, Evidence(files), historical))
        except (EvidenceError, OSError, ValueError, KeyError, TypeError) as exc:
            failures.append({"cell": name, "error": str(exc), "primary_endpoint_status": "INVALID"})
    result = {"schema": "06-3-burst-screen-v1", "cells": cells, "errors": failures,
              "primary_contract": "single-group complete bytes / actual maximum directional runtime",
              "window_contract": "[0,180) four 45-second diagnostics; >180 completion tail separate",
              "legacy_window_is_diagnostic_only": "[15,175)",
              "low_speed_or_nonzero_drain_is_not_a_rejection_rule": True}
    if historical:
        result.update({"evidence_mode": "RETROSPECTIVE_06_1_ONLY", "original_06_1_verdict_modified": False,
                       "RUN_VALIDITY_STATE": "RETROSPECTIVE_ONLY", "SCREEN_DECISION": "NOT_PREREGISTERED_NEW_RUN"})
        checks = {}
        for row in cells:
            name = row["cell"]
            checks[name] = {direction: abs(row["primary"]["directional"][direction]["MiB_s"] - HISTORY_EXPECTED[name][i]) < 0.000001
                            for i, direction in enumerate(("read", "write"))}
        result["known_answer_checks"] = checks
        result["replay_check"] = "PASS" if not failures and len(cells) == 4 and all(all(c.values()) for c in checks.values()) else "FAIL"
    else:
        for previous, current in zip(cells, cells[1:]):
            if current["primary"]["shell_start_epoch_ns"] <= previous["primary"]["completion_epoch_ns"]:
                current["nonperformance_errors"].append("six-cell fixed order violated or formal intervals overlap")
                current["EVIDENCE_VALIDITY"] = "EVIDENCE_INVALID"
        result.update(pair_matrix(cells))
    return result


def table_text(result):
    out = io.StringIO()
    fields = ["cell", "runtime_s", "read_bytes", "write_bytes", "read_MiB_s", "write_MiB_s",
              "completion_tail_s", "diagnostics", "R_W1", "R_W2", "R_W3", "R_W4",
              "W_W1", "W_W2", "W_W3", "W_W4", "Dirty_peak_GiB", "staging_peak_bytes",
              "drain_s", "remote_readable", "evidence_validity"]
    writer = csv.writer(out, delimiter="\t", lineterminator="\n")
    writer.writerow(fields)
    for row in result.get("cells", []):
        p, bw, m, life = row["primary"], row["bandwidth_diagnostics"], row["mechanism"], row["lifecycle"]
        values = [row["cell"], p["runtime_s"], p["directional"]["read"]["io_bytes"], p["directional"]["write"]["io_bytes"],
                  p["directional"]["read"]["MiB_s"], p["directional"]["write"]["MiB_s"],
                  p["completion_tail_after_180_s"], bw["diagnostic_status"]]
        values += [bw.get(direction, {}).get("windows_45s", {}).get("W" + str(i), {}).get("MiB_s")
                   for direction in ("read", "write") for i in range(1, 5)]
        values += [m.get("Dirty_observed_peak_GiB"), m.get("staging_bytes_observed_peak"), life["drain_seconds"], life["remote_readable"], row["EVIDENCE_VALIDITY"]]
        writer.writerow(["UNKNOWN" if value is None else value for value in values])
    return out.getvalue()


def fixture_files():
    """A complete synthetic six-cell package, never materialized on disk."""
    def tsv(fields, rows):
        return "\t".join(fields) + "\n" + "".join("\t".join(map(str, row)) + "\n" for row in rows)
    result = {
        "quiet-baseline.tsv": tsv(("epoch_ns", "Dirty_kB", "Writeback_kB"),
            [(int((1500 + second) * 1e9), 1024, 0) for second in range(121)]),
        "quiet-baseline.json": json.dumps({"p95_method": "nearest_rank", "dirty_limit_kB": 1024 + 8 * 1048576, "writeback_limit_kB": 1048576}),
    }
    run = "20990101-000000"
    assets = "".join(f"rw_test.{i}.0\t{i+1}\t1073741824\n" for i in range(128))
    health = {"fsid": "fixture-fsid", "health": {"status": "HEALTH_OK", "checks": {}}}
    result["gate0/approved-contract.json"] = json.dumps({"schema": "06-3-v1", "status": "APPROVED", "run_id": run, "meta": "fixture-meta",
        "ceph_fsid": "fixture-fsid", "approved_osd_flags": [], "assets_sha256": hashlib.sha256(assets.encode()).hexdigest(),
        "space": {"minimum_mem_available_bytes": 1024**3, "read_cache_bytes": 96 * 1024**3,
                  "worst_backlog_bytes": 256 * 1024**3, "filesystem_reserve_bytes": 1024**3,
                  "business_reserve_bytes": 1024**3, "stop_margin_bytes": 1024**3, "monitor_interval_seconds": 1,
                  "minimum_start_avail_bytes": 1024**4},
        "metrics": {"pending": "UNREGISTERED", "uploading": "juicefs_object_request_uploading",
                    "staging_errors": "juicefs_staging_block_errors", "error_counter_absent_is_zero": False}})
    prom = "".join(name + ("{method=\"" + method_name + "\"}" if method_name else "") + " 0\n"
                   for name, method_name in _legacy.COUNTER_SPECS.values())
    prom += "juicefs_staging_block_bytes 0\njuicefs_staging_blocks 0\njuicefs_staging_writing_blocks 0\njuicefs_object_request_uploading 0\njuicefs_blockcache_bytes 0\n"
    zero_fields = ("epoch_ns", "staging_blocks", "staging_bytes", "staging_writing_blocks",
                   "pending", "uploading", "staging_files", "staging_file_bytes")
    for index, name in enumerate(CELLS):
        prefix = "cells/" + name + "/"
        base = 2000 + index * 300
        actual_ns = int((base + .1) * 1e9)
        finish_ns = actual_ns + 180_000_000_000
        arm = name[0]
        mount = f"/tmp/jfs-06-3-{run}-{name}"
        cache = f"/mnt/jfs-cache/04tmp3/06-3-{run}-{name}"
        rate = {"C": 100, "S": 120, "W": 150}[arm]
        options = dict(WORKLOAD, filename_format=mount + "/test_dir/rw_test.$jobnum.0")
        data = {"timestamp_ms": finish_ns // 1000000, "global options": options,
                "jobs": [{"groupid": 0, "error": 0, "job_runtime": 180000 * 128,
                          "read": {"io_bytes": rate * 180 * MIB, "runtime": 180000},
                          "write": {"io_bytes": rate * 180 * MIB, "runtime": 180000}}]}
        cell = {"formal/fio.json": json.dumps(data), "formal/fio.rc": "0\n",
                "formal/fio-start-epoch-ns.txt": str(int(base * 1e9)),
                "formal/fio-end-epoch-ns.txt": str(finish_ns + 10000000),
                "warmup/fio.rc": "0\n",
                "warmup/fio.json": json.dumps({"timestamp_ms": (base - 32) * 1000,
                    "global options": {"rw": "randread", "runtime": "60"},
                    "jobs": [{"error": 0, "read": {"runtime": 60000}}]}),
                "PASS": "CELL_RAW_PASS\n", "RECOVERY_PASS": "RECOVERY_PASS\n",
                "state.tsv": f"cell\t{name}\narm\t{arm}\ncache_mib\t{0 if arm == 'C' else 98304}\nwriteback\t{int(arm == 'W')}\ncache_large_write\t{int(arm != 'C')}\ncache_dirs\t{cache if arm != 'C' else 'NONE'}\n",
                "assets-before.tsv": assets, "assets-mounted.tsv": assets, "assets-after.tsv": assets,
                "readback/fio.json": json.dumps({"timestamp_ms": (finish_ns + 3_000_000_000) // 1000000,
                    "jobs": [{"error": 0, "read": {"io_bytes": 4 * MIB}}]}),
                "readback-verify.tsv": "rc\t0\nremote_readable\tPASS\ncontent_correctness\tNOT_PROVEN\n",
                "drain-seconds.txt": "2\n", "post-warmup-recovery-seconds.txt": "31\n",
                "strict-drain-end-ns.txt": str(finish_ns + 2_000_000_000),
                "drain.tsv": tsv(zero_fields, [(finish_ns + second * 1_000_000_000, 0, 0, 0, "NA", 0, 0, 0) for second in range(3)]),
                "recovery.tsv": tsv(("epoch_ns", "Dirty_kB", "Writeback_kB") + zero_fields[1:],
                    [(int((base - 31 + second) * 1e9), 1024, 0, 0, 0, 0, "NA", 0, 0, 0) for second in range(31)]),
                "meminfo-1hz.tsv": tsv(("epoch_ns", "Cached_kB", "Dirty_kB", "Writeback_kB"),
                    [(actual_ns + second * 1_000_000_000, 1024, 1024, 0) for second in range(181)]),
                "df-1hz.tsv": tsv(("epoch_ns", "dir", "avail_bytes", "total_bytes"),
                    [(actual_ns + second * 1_000_000_000, cache, 8 * 1024**4, 10 * 1024**4) for second in range(181)]),
                "safety.tsv": tsv(("epoch_ns", "avail_bytes", "MemAvailable_bytes"),
                    [(actual_ns + second * 1_000_000_000, 8 * 1024**4, 128 * 1024**3) for second in range(181)]),
                "start-resources.tsv": tsv(("epoch_ns", "avail_bytes", "MemAvailable_bytes"),
                    [(int((base - 100) * 1e9), 8 * 1024**4, 128 * 1024**3)]),
                f"mechanism/{actual_ns}.prom": prom,
                f"mechanism/{finish_ns}.prom": prom,
                "juicefs-formal.log": "synthetic fixture; no errors\n"}
        for tag in ("formal", "verify"):
            cell["mount-process-" + tag + ".tsv"] = tsv(
                ("pid", "ppid", "starttime_ticks", "exe_md5", "is_worker", "cmdline"),
                [(101, 1, 100, JFS_MD5, "no", "juicefs mount -d"), (102, 101, 101, JFS_MD5, "yes", "juicefs mount -d")])
            destination = mount + ("-verify" if tag == "verify" else "")
            cell["findmnt-" + tag + ".tsv"] = "JuiceFS:juicefs-prod " + destination + " fuse.juicefs rw\n"
            command = "/tmp/juicefs-1.4.1-patched mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 --max-downloads 200"
            if tag == "formal" and arm != "C":
                command += f" --cache-dir {cache} --cache-size 98304 --free-space-ratio 0.20 --upload-delay 0 --cache-large-write"
                if arm == "W":
                    command += " --writeback"
            else:
                command += " --cache-size 0"
            cell["mount-command-" + tag + ".txt"] = command + " fixture-meta " + destination + "\n"
        for tag in ("before", "post-warmup", "pre-formal", "after"):
            cell["health-" + tag + "/ceph-status.json"] = json.dumps(health)
            cell["health-" + tag + "/osd-stat.json"] = json.dumps({"num_osds": 6, "num_up_osds": 6, "num_in_osds": 6})
            cell["health-" + tag + "/osd-dump.json"] = '{"flags":"noscrub,nodeep-scrub"}'
            cell["health-" + tag + "/pgs.txt"] = "1.0 active+clean\n"
        logs = "".join(f"{second * 1000},{rate * 8},{direction}\n" for second in range(1, 181) for direction in (0, 1))
        for job in range(1, 129):
            cell[f"formal/bw/randrw_bw.{job}.log"] = logs
        result.update({prefix + key: value for key, value in cell.items()})
    return result


def self_test():
    checks = []
    data = {"timestamp_ms": 1000400, "global options": {"group_reporting": "1", "numjobs": "128"},
            "jobs": [{"groupid": 0, "error": 0, "job_runtime": 51200000,
                      "read": {"io_bytes": 400 * MIB, "runtime": 400000},
                      "write": {"io_bytes": 800 * MIB, "runtime": 399000}}]}
    primary = primary_endpoint(data, 600000000000, 1000500000000)
    assert primary["runtime_s"] == 400 and primary["directional"]["read"]["MiB_s"] == 1
    assert primary["directional"]["write"]["MiB_s"] == 2 and primary["actual_io_start_epoch_ns"] == 600400000000
    checks += ["single_group_not_times_128", "max_direction_runtime_not_job_runtime", "long_tail_not_clipped", "json_timestamp_preferred_over_shell_end"]
    for mutate in (lambda d: d.update(jobs=d["jobs"] * 2),
                   lambda d: d["jobs"][0].pop("error"),
                   lambda d: d["jobs"][0].update(error=5),
                   lambda d: d["jobs"][0]["read"].pop("io_bytes"),
                   lambda d: d["jobs"][0]["write"].pop("runtime"),
                   lambda d: d.pop("timestamp_ms")):
        bad = copy.deepcopy(data)
        mutate(bad)
        try:
            primary_endpoint(bad, 600000000000, 1000500000000)
        except EvidenceError:
            pass
        else:
            raise AssertionError("malformed primary endpoint accepted")
    checks += ["missing_error_bytes_runtime_timestamp_rejected", "per_job_json_rejected"]
    # An explicit zero is trusted. A missing interval is not zero; no deletion
    # or normalization by only the covered fraction is permitted.
    full = {0: [(0, 1, 10, True), (1, 2, 0, True)], 1: [(0, 2, 2, False)]}
    assert interval_window([full], 0, 0, 2)["MiB_s"] == 5
    assert interval_window([full], 1, 0, 2)["MiB_s"] is None
    intervals = log_intervals("1000,1024,0\n1001,2048,1\n3000,1024,0\n3001,2048,1\n", 4)
    assert not intervals[0][-1][3] and not intervals[1][-1][3]
    assert interval_window([intervals], 0, 0, 4)["unknown_job_seconds"] == 3
    checks += ["explicit_zero_kept", "unknown_not_zero", "directional_sparse_gap_not_forward_filled", "unrecorded_tail_unknown"]
    overlap = {0: [(0, .5, 2, True), (.5, 1.5, 4, True)], 1: []}
    assert interval_window([overlap], 0, 0, 1)["MiB_s"] == 3
    checks.append("overlap_weighted_integral")
    try:
        bandwidth_diagnostics({}, primary)
    except EvidenceError:
        checks.append("missing_logs_rejected_without_losing_primary_arithmetic")
    else:
        raise AssertionError("missing logs accepted")
    def row(name, read, write=None):
        return {"cell": name, "EVIDENCE_VALIDITY": "VALID", "primary": {"directional": {
            "read": {"MiB_s": read}, "write": {"MiB_s": read if write is None else write}}}}
    rows = [row(name, {"C": 100, "S": 115, "W": 140}[name[0]]) for name in CELLS]
    result = pair_matrix(rows)
    assert all(value["SCREEN_DECISION"] == "SCREEN_CONTINUE" for value in result["comparisons"].values())
    # Direction-specific epsilon: high R noise cannot be silently substituted
    # for W noise; strong signals may pass despite epsilon >= 5%.
    rows = [row("C1", 100, 100), row("S1", 150, 110), row("W1", 200, 130),
            row("W2", 220, 130), row("S2", 165, 110), row("C2", 110, 100)]
    result = pair_matrix(rows)["comparisons"]["S/C"]
    assert result["SCREEN_DECISION"] == "SCREEN_CONTINUE"
    assert result["directional"]["read"]["fine_effect_resolution_insufficient"]
    assert result["directional"]["write"]["M_pct"] == 5
    rows[1]["EVIDENCE_VALIDITY"] = "EVIDENCE_INVALID"
    assert pair_matrix(rows)["comparisons"]["S/C"]["SCREEN_DECISION"] == "NO_DECISION_EVIDENCE_INVALID"
    assert pair_matrix(rows[:-1])["RUN_VALIDITY_STATE"] == "EVIDENCE_INVALID"
    checks += ["six_cell_three_comparison_pairmatrix", "epsilon_and_M_separate_read_write",
               "large_signal_with_high_noise_still_screenable", "invalid_or_missing_cell_blocks_decision"]
    snap = parse_prom(TextSource('juicefs_object_request_data_bytes{method="GET"} 123\n'))
    assert metric(snap, "juicefs_object_request_data_bytes", "GET") == 123
    checks.append("reuse_stateless_prometheus_helpers")
    fixture = fixture_files()
    package = analyze_files(fixture)
    assert package["RUN_VALIDITY_STATE"] == "VALID", [(r["cell"], r["nonperformance_errors"]) for r in package["cells"]]
    assert all(value["SCREEN_DECISION"] == "SCREEN_CONTINUE" for value in package["comparisons"].values())
    checks.append("complete_six_cell_raw_fixture_validates_end_to_end")
    # Single-field negative mutations rerun the actual evidence validator, not
    # a hand-written model of that validator.
    prefix = "cells/W1/"
    original = Evidence({key[len(prefix):]: value for key, value in fixture.items() if key.startswith(prefix)})
    original_row = next(row for row in package["cells"] if row["cell"] == "W1")
    negative = {
        "actual_mount_missing_writeback": ("mount-command-formal.txt", original.text("mount-command-formal.txt").replace(" --writeback", "")),
        "fio_rc_failure": ("formal/fio.rc", "1\n"),
        "changed_asset": ("assets-after.tsv", original.text("assets-after.tsv").replace("rw_test.0.0\t1\t", "rw_test.0.0\t2\t")),
        "only_pass_without_recovery_raw": ("recovery.tsv", "epoch_ns\tDirty_kB\tWriteback_kB\n"),
        "health_error": ("health-before/ceph-status.json", '{"health":{"status":"HEALTH_ERR"}}'),
        "foreign_health_flag": ("health-before/osd-dump.json", '{"flags":"noscrub,nodeep-scrub,noout"}'),
        "memory_safety_violation": ("safety.tsv", original.text("safety.tsv").replace(str(128 * 1024**3), "0", 1)),
        "capacity_safety_violation": ("safety.tsv", original.text("safety.tsv").replace(str(8 * 1024**4), "0", 1)),
        "stage_ceiling_violation": ("safety.tsv", original.text("safety.tsv").replace(str(8 * 1024**4), str(8 * 1024**4 - 400 * 1024**3), 1)),
    }
    for label, (key, value) in negative.items():
        changed = Evidence(dict(original.files, **{key: value}))
        failures = validate_new_cell(changed, Evidence(fixture), "W1", original_row["primary"], original_row["mechanism"], original_row["lifecycle"])
        assert failures, label
        checks.append("reject_" + label)
    forged = dict(fixture)
    forged["quiet-baseline.json"] = '{"p95_method":"nearest_rank","dirty_limit_kB":999999999,"writeback_limit_kB":1048576}'
    assert validate_new_cell(original, Evidence(forged), "W1", original_row["primary"], original_row["mechanism"], original_row["lifecycle"])
    checks.append("reject_forged_quiet_threshold_recompute_raw_p95")
    early = copy.deepcopy(original_row["primary"])
    early["runtime_s"] = 179
    assert validate_new_cell(original, Evidence(fixture), "W1", early, original_row["mechanism"], original_row["lifecycle"])
    checks.append("reject_formal_early_completion_without_rejecting_long_tail")
    incomplete_drain = dict(original_row["lifecycle"], terminal_zero_samples=2)
    assert validate_new_cell(original, Evidence(fixture), "W1", original_row["primary"], original_row["mechanism"], incomplete_drain)
    checks.append("reject_two_instead_of_three_terminal_zero_snapshots")
    broken = Evidence(dict(original.files, **{"meminfo-1hz.tsv": "epoch_ns\nBAD\n"}))
    preserved = analyze_cell(broken, "W1", Evidence(fixture))
    assert preserved["primary"]["directional"]["read"]["MiB_s"] == 150
    checks.append("malformed_optional_diagnostic_preserves_primary")
    cp = "cells/C1/"
    control = {key[len(cp):]: value for key, value in fixture.items() if key.startswith(cp)}
    for filename in ("drain.tsv", "recovery.tsv"):
        records = list(csv.DictReader(io.StringIO(control[filename]), delimiter="\t"))
        for record in records:
            for key in ("staging_blocks", "staging_bytes", "staging_writing_blocks"):
                record[key] = "NA"
        stream = io.StringIO()
        writer = csv.DictWriter(stream, fieldnames=list(records[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(records)
        control[filename] = stream.getvalue()
    assert analyze_cell(Evidence(control), "C1", Evidence(fixture))["EVIDENCE_VALIDITY"] == "VALID"
    checks.append("non_WB_unregistered_staging_NA_is_not_a_measured_zero")
    stagefull = Evidence(dict(original.files, **{"juicefs-formal.log": "stageFull; upload it directly\n"}))
    assert not validate_new_cell(stagefull, Evidence(fixture), "W1", original_row["primary"], copy.deepcopy(original_row["mechanism"]), original_row["lifecycle"])
    checks.append("stageFull_fallback_alone_does_not_erase_fullperiod_primary")
    mismatch = {"runtime_s": 2, "directional": {d: {"io_bytes": MIB} for d in ("read", "write")}}
    mismatch_result = bandwidth_diagnostics({"formal/bw/randrw_bw.1.log": "1000,1024,0\n1000,1024,1\n2000,1024,0\n2000,1024,1\n"}, mismatch, expected_jobs=1)
    assert mismatch_result["diagnostic_status"] == "REVIEW" and mismatch_result["read"]["log_minus_json_integral_pct"] == 100
    assert mismatch_result["read"]["windows_45s"]["W1"]["MiB_s"] is None
    checks.append("integral_difference_over_5_percent_REVIEW_never_rescaled")
    registration = {"staging_errors": "custom_staging_error", "error_counter_absent_is_zero": True}
    absent_files = {key: "\n".join(line for line in value.splitlines() if not line.startswith("juicefs_object_request_errors"))
                    if key.startswith("mechanism/") else value for key, value in original.files.items()}
    absent = mechanism_diagnostics(Evidence(absent_files), original_row["primary"], registration)
    assert absent["counter_deltas"]["staging_errors"] == absent["counter_deltas"]["object_errors"] == 0
    assert sum("zero_by_approved_absent_error_counter_registration" in issue for issue in absent["issues"]) == 2
    checks.append("approved_metric_registration_and_absent_error_zero_are_explicit")
    return {"status": "PASS", "checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    test = sub.add_parser("self-test")
    test.add_argument("--output", type=Path)
    for command in ("analyze", "replay-archive"):
        child = sub.add_parser(command)
        child.add_argument("--root" if command == "analyze" else "--archive", required=True, type=Path)
        child.add_argument("--output", type=Path)
        child.add_argument("--table", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "self-test":
            result = self_test()
        elif args.command == "replay-archive":
            files, sha = load_archive(args.archive)
            result = analyze_files(files, historical=True)
            result["archive_sha256"] = sha
            result["archive"] = str(args.archive)
        else:
            result = analyze_files(load_tree(args.root))
    except (EvidenceError, OSError, ValueError, tarfile.TarError) as exc:
        result = {"status": "FAIL", "error": str(exc)}
    text = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    else:
        print(text, end="")
    if getattr(args, "table", None):
        args.table.parent.mkdir(parents=True, exist_ok=True)
        args.table.write_text(table_text(result))
    return 1 if (result.get("status") == "FAIL" or result.get("replay_check") == "FAIL" or
                 result.get("RUN_VALIDITY_STATE") == "EVIDENCE_INVALID") else 0


if __name__ == "__main__":
    raise SystemExit(main())
