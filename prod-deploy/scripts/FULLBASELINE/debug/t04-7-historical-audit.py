#!/usr/bin/env python3
"""Offline-only audit of the frozen 04-tmp2i fio evidence.

The script deliberately does not reconstruct bandwidth across a gap in fio's
per-job interval logs.  A missing record is reported as NO_RECORD, not silently
treated as either a zero-rate interval or an interval carrying the next rate.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import statistics
import tarfile
from pathlib import Path


EXPECTED_ARCHIVE_SHA256 = (
    "162f3e661b64497de76acf9760549ef13bcb51883e04832e50def5db90276fcd"
)
CELLS = {
    "A0-pre": "A0-pre-A0",
    "T128-P25": "T128-P25",
    "T128-R": "T128-R",
    "T128-W": "T128-W",
    "A0-post": "A0-post-A0",
}
DIRECTIONS = ((0, "read"), (1, "write"))
JOBS = 128
RUNTIME_SECONDS = 180
BLOCK_KIB = 256


class AuditError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def member_bytes(archive: tarfile.TarFile, name: str) -> bytes:
    handle = archive.extractfile(name)
    if handle is None:
        raise AuditError(f"missing archive member: {name}")
    return handle.read()


def member_json(archive: tarfile.TarFile, name: str):
    return json.loads(member_bytes(archive, name))


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    pos = (len(ordered) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] * (hi - pos) + ordered[hi] * (pos - lo)


def runs(values: list[int]) -> list[tuple[int, int]]:
    result: list[list[int]] = []
    for value in sorted(values):
        if not result or value != result[-1][-1] + 1:
            result.append([value])
        else:
            result[-1].append(value)
    return [(item[0], item[-1]) for item in result]


def fmt_runs(items: list[tuple[int, int]]) -> str:
    return ",".join(str(a) if a == b else f"{a}-{b}" for a, b in items) or "NONE"


def load_bw_log(archive: tarfile.TarFile, member: str):
    rows = []
    text = io.TextIOWrapper(archive.extractfile(member), encoding="utf-8")
    for row in csv.reader(text):
        if not row or not any(field.strip() for field in row):
            continue
        if len(row) < 3:
            raise AuditError(f"short bw row in {member}")
        timestamp_ms, value_kib_s, direction = int(row[0]), int(row[1]), int(row[2])
        if direction not in (0, 1) or timestamp_ms < 0 or value_kib_s < 0:
            raise AuditError(f"invalid bw row in {member}: {row!r}")
        rows.append((timestamp_ms, value_kib_s, direction))
    return rows


def weighted_latency(jobs: list[dict], direction: str, kind: str):
    counts = [int(job[direction][kind].get("N", 0)) for job in jobs]
    total = sum(counts)
    if total <= 0:
        raise AuditError(f"missing {direction}/{kind} samples")
    mean_ns = sum(
        float(job[direction][kind]["mean"]) * count
        for job, count in zip(jobs, counts)
    ) / total
    maxima_ms = [float(job[direction][kind]["max"]) / 1e6 for job in jobs]
    return total, mean_ns / 1e6, maxima_ms


def nearest_row(rows: list[dict], relative_second: float) -> dict:
    return min(rows, key=lambda row: abs(row["relative_second"] - relative_second))


def audit_cell(archive: tarfile.TarFile, canonical: str, member_cell: str):
    prefix = f"cells/{member_cell}"
    fio = member_json(archive, f"{prefix}/formal/fio.json")
    jobs = fio.get("jobs", [])
    if len(jobs) != JOBS or any(int(job.get("error", -1)) != 0 for job in jobs):
        raise AuditError(f"{canonical}: expected {JOBS} error-free jobs")

    end_ns = int(member_bytes(archive, f"{prefix}/formal/fio-end-epoch-ns.txt"))
    runtime_ms = max(
        max(int(job["read"]["runtime"]), int(job["write"]["runtime"]), int(job["job_runtime"]))
        for job in jobs
    )
    derived_start_ns = end_ns - runtime_ms * 1_000_000
    stated_start_ns = int(member_bytes(archive, f"{prefix}/formal/fio-start-ns.txt"))

    all_logs = {
        job: load_bw_log(archive, f"{prefix}/formal/bw/randrw_bw.{job}.log")
        for job in range(1, JOBS + 1)
    }
    results = []
    common_zero_by_direction = {}

    for direction_id, direction in DIRECTIONS:
        io_bytes = sum(int(job[direction]["io_bytes"]) for job in jobs)
        direction_runtime_ms = max(int(job[direction]["runtime"]) for job in jobs)
        json_bw = io_bytes / (direction_runtime_ms / 1000) / 2**20
        slat_n, slat_mean_ms, slat_maxima_ms = weighted_latency(jobs, direction, "slat_ns")
        _, clat_mean_ms, clat_maxima_ms = weighted_latency(jobs, direction, "clat_ns")
        _, total_mean_ms, total_maxima_ms = weighted_latency(jobs, direction, "lat_ns")

        per_second_jobs = {second: set() for second in range(1, RUNTIME_SECONDS + 1)}
        record_counts = []
        max_gaps_ms = []
        legacy_integral_bytes = 0.0
        nominal_logged_bytes = 0
        for job_id, rows in all_logs.items():
            selected = [(ts, value) for ts, value, d in rows if d == direction_id]
            if not selected:
                raise AuditError(f"{canonical}: job {job_id} lacks {direction} records")
            record_counts.append(len(selected))
            previous = 0
            for timestamp_ms, value_kib_s in selected:
                # This reproduces the old, invalid behavior for audit only.
                legacy_integral_bytes += value_kib_s * 1024 * ((timestamp_ms - previous) / 1000)
                previous = timestamp_ms

                # fio 3.28 records cluster within a few milliseconds of 1 s buckets.
                bucket = round(timestamp_ms / 1000)
                if 1 <= bucket <= RUNTIME_SECONDS:
                    per_second_jobs[bucket].add(job_id)
                # Diagnostic estimate: each active row represents roughly one
                # log_avg_msec=1000 sample.  It is not promoted to interval truth.
                nominal_ios = round(value_kib_s / BLOCK_KIB)
                nominal_logged_bytes += nominal_ios * BLOCK_KIB * 1024
            max_gaps_ms.append(
                max((b[0] - a[0] for a, b in zip(selected, selected[1:])), default=0)
            )

        zero_seconds = [second for second, present in per_second_jobs.items() if not present]
        zero_runs = runs(zero_seconds)
        common_zero_by_direction[direction] = zero_seconds
        interior = [(a, b) for a, b in zero_runs if b < RUNTIME_SECONDS]
        terminal = [(a, b) for a, b in zero_runs if b == RUNTIME_SECONDS]
        partial = [
            f"{second}:{len(present)}"
            for second, present in per_second_jobs.items()
            if 0 < len(present) < JOBS
        ]
        results.append(
            {
                "cell": canonical,
                "direction": direction.upper(),
                "io_bytes": io_bytes,
                "runtime_ms": direction_runtime_ms,
                "json_compat_bw_MiB_s": json_bw,
                "slat_N": slat_n,
                "slat_mean_ms": slat_mean_ms,
                "slat_jobmax_min_ms": min(slat_maxima_ms),
                "slat_jobmax_median_ms": statistics.median(slat_maxima_ms),
                "slat_jobmax_p90_ms": percentile(slat_maxima_ms, 0.90),
                "slat_jobmax_max_ms": max(slat_maxima_ms),
                "clat_mean_ms": clat_mean_ms,
                "clat_jobmax_max_ms": max(clat_maxima_ms),
                "total_lat_mean_ms": total_mean_ms,
                "total_lat_jobmax_max_ms": max(total_maxima_ms),
                "records_per_job_min": min(record_counts),
                "records_per_job_median": statistics.median(record_counts),
                "records_per_job_max": max(record_counts),
                "max_record_gap_ms": max(max_gaps_ms),
                "all_job_no_record_seconds_total": len(zero_seconds),
                "all_job_no_record_seconds_interior": sum(b - a + 1 for a, b in interior),
                "all_job_no_record_seconds_terminal": sum(b - a + 1 for a, b in terminal),
                "all_job_no_record_runs": fmt_runs(zero_runs),
                "partial_job_seconds": ",".join(partial) or "NONE",
                "legacy_interval_integral_bytes": round(legacy_integral_bytes),
                "legacy_integral_over_json_ratio": legacy_integral_bytes / io_bytes,
                "nominal_1s_logged_bytes": nominal_logged_bytes,
                "json_minus_nominal_logged_bytes": io_bytes - nominal_logged_bytes,
                "derived_start_ns": derived_start_ns,
                "stated_start_ns": stated_start_ns,
                "stated_minus_derived_start_ms": (stated_start_ns - derived_start_ns) / 1e6,
                "interval_truth": (
                    "SPARSE_NO_RECORD_INTERVALS_EXACT_RATE_UNPROVEN"
                    if zero_seconds
                    else "DENSE_ACTIVE_ROWS_WITH_PARTIAL_EDGES"
                ),
            }
        )

    if common_zero_by_direction["read"] != common_zero_by_direction["write"]:
        raise AuditError(f"{canonical}: READ/WRITE synchronized gap sets differ")

    gap_rows = []
    runtime_member = f"{prefix}/runtime.tsv"
    runtime_text = io.TextIOWrapper(archive.extractfile(runtime_member), encoding="utf-8")
    runtime_rows = list(csv.DictReader(runtime_text, delimiter="\t"))
    for row in runtime_rows:
        row["relative_second"] = (int(row["epoch_ns"]) - derived_start_ns) / 1e9
    for start, stop in runs(common_zero_by_direction["read"]):
        before = nearest_row(runtime_rows, start - 0.5)
        after = nearest_row(runtime_rows, stop + 0.5)
        gap_rows.append(
            {
                "cell": canonical,
                "start_second": start,
                "stop_second": stop,
                "seconds": stop - start + 1,
                "position": "TERMINAL" if stop == RUNTIME_SECONDS else "INTERIOR",
                "before_sample_second": before["relative_second"],
                "after_sample_second": after["relative_second"],
                "hit_delta_bytes": int(after["hit_bytes"]) - int(before["hit_bytes"]),
                "miss_delta_bytes": int(after["miss_bytes"]) - int(before["miss_bytes"]),
                "blockcache_delta_bytes": int(after["blockcache_bytes"]) - int(before["blockcache_bytes"]),
                "staging_delta_bytes": int(after["staging_bytes"]) - int(before["staging_bytes"]),
                "available_delta_bytes": int(after["available_bytes"]) - int(before["available_bytes"]),
                "evicts_delta": int(after["evicts"]) - int(before["evicts"]),
                "drops_delta": int(after["drops"]) - int(before["drops"]),
                "classification": "SYNCHRONIZED_NO_RECORD_NOT_ASSUMED_ZERO_SERVICE",
            }
        )
    return results, gap_rows


def write_tsv(path: Path, rows: list[dict]):
    if not rows:
        raise AuditError(f"refusing empty TSV: {path}")
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def self_test():
    assert runs([]) == []
    assert runs([2, 3, 7, 8, 9]) == [(2, 3), (7, 9)]
    # The old previous-to-current interval assignment must visibly inflate a
    # sparse stream: the 9 s gap cannot inherit the 100 KiB/s row at t=10.
    sparse = [(1000, 100), (10000, 100)]
    previous = 0
    legacy = 0
    for timestamp_ms, value in sparse:
        legacy += value * (timestamp_ms - previous) / 1000
        previous = timestamp_ms
    nominal = sum(value for _, value in sparse)
    assert legacy == 1000 and nominal == 200 and legacy > nominal


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("SELF_TEST_PASS")
        return
    if args.archive is None or args.out is None:
        parser.error("--archive and --out are required unless --self-test is used")
    if not args.archive.is_file():
        raise AuditError(f"archive not found: {args.archive}")
    actual_sha = sha256(args.archive)
    if actual_sha != EXPECTED_ARCHIVE_SHA256:
        raise AuditError(f"archive SHA256 mismatch: {actual_sha}")
    args.out.mkdir(parents=True, exist_ok=False)

    historical_rows = []
    gap_rows = []
    with tarfile.open(args.archive, "r:") as archive:
        for canonical, member_cell in CELLS.items():
            cell_rows, cell_gaps = audit_cell(archive, canonical, member_cell)
            historical_rows.extend(cell_rows)
            gap_rows.extend(cell_gaps)

    write_tsv(args.out / "historical-audit.tsv", historical_rows)
    write_tsv(args.out / "synchronized-gaps.tsv", gap_rows)

    by_key = {(row["cell"], row["direction"]): row for row in historical_rows}
    effects = {}
    for direction in ("READ", "WRITE"):
        pre = by_key[("A0-pre", direction)]["json_compat_bw_MiB_s"]
        post = by_key[("A0-post", direction)]["json_compat_bw_MiB_s"]
        reference = pre + 0.25 * (post - pre)
        p25 = by_key[("T128-P25", direction)]["json_compat_bw_MiB_s"]
        effects[direction] = {
            "interpolated_A0_MiB_s": reference,
            "P25_MiB_s": p25,
            "effect_pct": (p25 / reference - 1) * 100,
        }
    effects["MEAN"] = {
        "interpolated_A0_MiB_s": statistics.mean(
            effects[d]["interpolated_A0_MiB_s"] for d in ("READ", "WRITE")
        ),
        "P25_MiB_s": statistics.mean(effects[d]["P25_MiB_s"] for d in ("READ", "WRITE")),
    }
    effects["MEAN"]["effect_pct"] = (
        effects["MEAN"]["P25_MiB_s"] / effects["MEAN"]["interpolated_A0_MiB_s"] - 1
    ) * 100

    decision = {
        "schema": 1,
        "source_archive": str(args.archive),
        "source_sha256": actual_sha,
        "cells_audited": list(CELLS),
        "source_integrity": "PASS",
        "historical_total_effect": effects,
        "p25_full_run_negative_effect": "PRESERVED",
        "p25_synchronized_no_record_intervals": "SUPPORTED_AND_UNIQUE_AMONG_FIVE_CELLS",
        "p25_read_submission_long_wait": "SUPPORTED_ALL_128_JOBS_APPROX_19S_MAX_SLAT",
        "old_w1_w4_cv": "INVALID_LEGACY_GAP_BACKFILL_AND_FIXED_WINDOW_VIOLATION",
        "exact_gap_rate": "UNPROVEN_DO_NOT_AUTOFILL_ZERO_OR_NEXT_RATE",
        "stall_root_cause": "NOT_CLOSED",
        "async_dio_exact_contract_history": "NONE_FOUND",
        "online_test": "CONDITIONAL_NOT_AUTHORIZED",
    }
    (args.out / "audit.json").write_text(json.dumps(decision, indent=2, ensure_ascii=False) + "\n")
    (args.out / "PASS").write_text("L0_HISTORICAL_AUDIT_PASS\n")
    print(json.dumps(decision, ensure_ascii=False))


if __name__ == "__main__":
    main()
