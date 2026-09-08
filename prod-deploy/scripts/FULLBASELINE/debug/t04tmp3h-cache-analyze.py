#!/usr/bin/env python3
"""Deterministic analyzer for 04-tmp3h's four-command cache tiers."""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
import tempfile
from pathlib import Path

CP_TARGET_GBS = 2.0
FIO_TARGET_MIB = {"read": 5149.84, "write": 3051.76}
TIERS = ("T32", "T64", "T96", "T128")
ORDERS = ("FWD", "REV")


class EvidenceError(RuntimeError):
    pass


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"invalid JSON: {path}") from exc


def fio_options(doc: dict) -> dict:
    jobs = doc.get("jobs")
    if not isinstance(jobs, list) or len(jobs) != 1 or int(jobs[0].get("error", -1)):
        raise EvidenceError("fio job-count/error contract failed")
    options = dict(doc.get("global options") or doc.get("global_options") or {})
    options.update(jobs[0].get("job options") or jobs[0].get("job_options") or {})
    return options


def read_bw_log(path: Path, begin: int, end: int) -> list[float]:
    rows: list[tuple[float, float, float]] = []
    previous = 0.0
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split(",")
        if len(fields) < 2:
            raise EvidenceError(f"short bandwidth row {path}:{number}")
        finish = float(fields[0]) / 1000.0
        value = float(fields[1]) / 1024.0
        if finish <= previous or value < 0 or not math.isfinite(finish + value):
            raise EvidenceError(f"invalid bandwidth row {path}:{number}")
        rows.append((previous, finish, value)); previous = finish
    seconds: dict[int, tuple[float, float]] = {}
    for start, finish, value in rows:
        for second in range(math.floor(start), math.ceil(finish)):
            overlap = min(finish, second + 1.0) - max(start, float(second))
            if overlap > 0:
                total, weight = seconds.get(second, (0.0, 0.0))
                seconds[second] = (total + value * overlap, weight + overlap)
    values = [seconds[x][0] / seconds[x][1] for x in range(begin, end) if x in seconds]
    if len(values) != end - begin:
        raise EvidenceError(f"formal bandwidth window incomplete: {len(values)}/{end-begin}")
    return values


def metric_map(path: Path) -> dict[str, int]:
    wanted = {"juicefs_blockcache_hit_bytes", "juicefs_blockcache_miss_bytes"}
    values = {key: 0 for key in wanted}; found = set()
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split(); name = fields[0].split("{")[0]
        if name in wanted:
            values[name] += int(float(fields[-1])); found.add(name)
    if found != wanted:
        raise EvidenceError(f"cache metrics missing in {path}")
    return values


def cache_hit_ratio(cell: Path, order: str, label: str, allow_zero: bool = False) -> float | None:
    pre = metric_map(cell / f"{order}-{label}-pre.metrics")
    post = metric_map(cell / f"{order}-{label}-post.metrics")
    hit = post["juicefs_blockcache_hit_bytes"] - pre["juicefs_blockcache_hit_bytes"]
    miss = post["juicefs_blockcache_miss_bytes"] - pre["juicefs_blockcache_miss_bytes"]
    if hit < 0 or miss < 0:
        raise EvidenceError(f"{order}-{label}: invalid cache counter deltas")
    if hit + miss == 0:
        if allow_zero:
            return None
        raise EvidenceError(f"{order}-{label}: zero cache counter activity")
    return hit / (hit + miss)


def drain_result(path: Path, runtime_path: Path, written: int, foreground_seconds: float) -> dict:
    status = Path(str(path) + ".status").read_text().strip()
    if status != "STRICT_ZERO":
        raise EvidenceError(f"strict drain failed: {path} ({status})")
    seconds = float(Path(str(path) + ".seconds").read_text())
    rows = list(csv.DictReader(path.open(), delimiter="\t"))
    if len(rows) < 2:
        raise EvidenceError(f"drain samples incomplete: {path}")
    runtime_rows = list(csv.DictReader(runtime_path.open(), delimiter="\t"))
    if not runtime_rows:
        raise EvidenceError(f"foreground runtime samples missing: {runtime_path}")
    keys = ("staging_blocks", "staging_block_bytes", "staging_writing_blocks",
            "staging_files", "staging_file_bytes")
    if any(int(float(row[key])) for row in rows[-2:] for key in keys):
        raise EvidenceError(f"drain final two samples are not both zero: {path}")
    final_gap = (int(rows[-1]["epoch_ns"]) - int(rows[-2]["epoch_ns"])) / 1e9
    if final_gap < 9.5:
        raise EvidenceError(f"drain final zero samples too close: {final_gap:.3f}s")
    if not 0 <= seconds <= 900:
        raise EvidenceError(f"drain duration outside contract: {seconds}s")
    combined = runtime_rows + rows
    return {"drain_seconds": seconds,
            "foreground_staging_peak_bytes": max(int(float(row["staging_block_bytes"])) for row in runtime_rows),
            "staging_peak_bytes": max(int(float(row["staging_block_bytes"])) for row in combined),
            "minimum_available_bytes": min(int(float(row["available_bytes"])) for row in combined),
            "effective_durable_MiBs": written / 1024**2 / (foreground_seconds + seconds)}


def fio_result(cell: Path, order: str, direction: str) -> dict:
    label = f"{order}-fio-{direction}"; root = cell / label
    doc = load_json(root / "fio.json"); options = fio_options(doc)
    expected = {"rw": direction, "bs": "20M" if direction == "read" else "16M",
                "size": "10G", "direct": "1", "numjobs": "1",
                "runtime": "60" if direction == "read" else "120"}
    for key, value in expected.items():
        if str(options.get(key, "")) != value:
            raise EvidenceError(f"{label}: option {key}={options.get(key)!r}, expected {value}")
    # fio 3.28 omits a true boolean time_based option from JSON; reject only
    # an explicit false value and separately require the full configured runtime.
    if "time_based" in options and str(options["time_based"]) not in ("", "1", "true", "True"):
        raise EvidenceError(f"{label}: time_based contract failed")
    if (root / "fio.rc").read_text().strip() != "0":
        raise EvidenceError(f"{label}: nonzero fio rc")
    job = doc["jobs"][0]; io = job.get(direction) or {}
    other = job.get("write" if direction == "read" else "read") or {}
    if int(io.get("io_bytes", 0)) <= 0 or int(other.get("io_bytes", 0)) != 0:
        raise EvidenceError(f"{label}: direction/byte proof failed")
    runtime = 60 if direction == "read" else 120
    run_ms = int(job.get("job_runtime", io.get("runtime", 0)))
    if not runtime * 1000 - 2000 <= run_ms <= runtime * 1000 + 5000:
        raise EvidenceError(f"{label}: runtime mismatch {run_ms}")
    logs = list((root / "bw").glob("*_bw.*.log"))
    if len(logs) != 1:
        raise EvidenceError(f"{label}: expected one bw log, got {len(logs)}")
    begin, end = (10, 50) if direction == "read" else (10, 110)
    values = read_bw_log(logs[0], begin, end)
    summary = float(io.get("bw_bytes", 0)) / 1024**2
    if summary <= 0:
        summary = float(io.get("bw", 0)) / 1024.0
    formal = statistics.mean(values)
    start_ns = int((root / "start-ns.txt").read_text()); end_ns = int((root / "end-ns.txt").read_text())
    if end_ns <= start_ns:
        raise EvidenceError(f"{label}: invalid wall clock")
    result = {"summary_MiBs": summary, "formal_mean_MiBs": formal,
              "formal_cv_pct": statistics.pstdev(values) / formal * 100,
              "wall_seconds": (end_ns - start_ns) / 1e9, "io_bytes": int(io["io_bytes"]),
              "target_MiBs": FIO_TARGET_MIB[direction],
              "target_pass": summary > FIO_TARGET_MIB[direction] and formal > FIO_TARGET_MIB[direction]}
    if direction == "read":
        result["cache_hit_ratio"] = cache_hit_ratio(cell, order, "fio-read")
    else:
        result.update(drain_result(cell / f"{order}-fio-write-drain.tsv", root / "runtime.tsv",
                                   int(io["io_bytes"]), result["wall_seconds"]))
    return result


def cp_result(cell: Path, order: str, direction: str) -> dict:
    label = f"{order}-cp-{direction}"; root = cell / label
    if (root / "cp.rc").read_text().strip() != "0":
        raise EvidenceError(f"{label}: nonzero cp rc")
    seconds = float((root / "time-real.txt").read_text().strip())
    if seconds <= 0:
        raise EvidenceError(f"{label}: invalid duration")
    exact_bytes = 20 * 1024**3
    result = {"seconds": seconds, "GBs": exact_bytes / seconds / 1e9, "target_GBs": CP_TARGET_GBS}
    result["target_pass"] = result["GBs"] > CP_TARGET_GBS
    if direction == "read":
        # Buffered cp can be served entirely by the Linux page cache after the
        # mandated warm-up, in which case JuiceFS block-cache counters do not move.
        result["cache_hit_ratio"] = cache_hit_ratio(cell, order, "cp-read", allow_zero=True)
    else:
        result.update(drain_result(cell / f"{order}-cp-write-drain.tsv", root / "runtime.tsv",
                                   exact_bytes, seconds))
    return result


def analyze_order(cell: Path, order: str) -> dict:
    results = {"cp_read": cp_result(cell, order, "read"),
               "fio_read": fio_result(cell, order, "read"),
               "cp_write": cp_result(cell, order, "write"),
               "fio_write": fio_result(cell, order, "write")}
    return {"order": order, "commands": results,
            "all_targets_pass": all(item["target_pass"] for item in results.values())}


def analyze_tier(cell: Path) -> dict:
    if (cell / "CAPACITY_TIMEOUT.tsv").is_file():
        return {"tier": cell.name, "verdict": "CAPACITY_NOT_SUFFICIENT", "reason": "DRAIN_TIMEOUT", "orders": {}}
    fwd = load_json(cell / "FWD-analysis.json"); orders = {"FWD": fwd}
    if not fwd.get("all_targets_pass"):
        verdict = "CAPACITY_NOT_SUFFICIENT"
    elif not (cell / "REV-analysis.json").is_file():
        raise EvidenceError(f"{cell.name}: passing FWD lacks REV")
    else:
        rev = load_json(cell / "REV-analysis.json"); orders["REV"] = rev
        verdict = "FOUR_COMMAND_CACHE_TARGET_CONFIRMED" if rev.get("all_targets_pass") else "ORDER_SENSITIVE_NOT_CONFIRMED"
    return {"tier": cell.name, "verdict": verdict, "orders": orders}


def analyze_run(root: Path) -> dict:
    tiers = {}
    for tier in TIERS:
        path = root / "cells" / tier / "tier-analysis.json"
        if not path.is_file(): break
        tiers[tier] = load_json(path)
        if tiers[tier].get("verdict") == "FOUR_COMMAND_CACHE_TARGET_CONFIRMED":
            return {"validity": "VALID", "verdict": "FOUR_COMMAND_CACHE_TARGET_CONFIRMED",
                    "minimum_verified_tier": tier, "tiers": tiers}
    if set(tiers) == set(TIERS):
        return {"validity": "VALID", "verdict": "NO_VERIFIED_CACHE_BUDGET_LE_128G",
                "minimum_verified_tier": None, "tiers": tiers}
    raise EvidenceError("tier matrix incomplete without early success")


def self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="t04tmp3h-fixture-") as tmp:
        root = Path(tmp); (root / "bw").mkdir()
        (root / "bw" / "x_bw.1.log").write_text("".join(f"{(i+1)*1000},6144000\n" for i in range(60)))
        values = read_bw_log(root / "bw" / "x_bw.1.log", 10, 50)
        if len(values) != 40 or round(statistics.mean(values), 3) != 6000: raise AssertionError("bandwidth fixture failed")
        tier = root / "T32"; tier.mkdir(); (tier / "CAPACITY_TIMEOUT.tsv").write_text("FWD\tDRAIN_TIMEOUT\n")
        if analyze_tier(tier)["verdict"] != "CAPACITY_NOT_SUFFICIENT": raise AssertionError("capacity fixture failed")
    print("T04TMP3H_ANALYZER_SELFTEST_PASS"); return 0


def main() -> int:
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="mode", required=True)
    order = sub.add_parser("order"); order.add_argument("cell"); order.add_argument("order", choices=ORDERS)
    tier = sub.add_parser("tier"); tier.add_argument("cell")
    run = sub.add_parser("run"); run.add_argument("root")
    sub.add_parser("self-test"); args = parser.parse_args()
    if args.mode == "order": result = analyze_order(Path(args.cell), args.order)
    elif args.mode == "tier": result = analyze_tier(Path(args.cell))
    elif args.mode == "run": result = analyze_run(Path(args.root))
    else: return self_test()
    print(json.dumps(result, indent=2, sort_keys=True)); return 0


if __name__ == "__main__":
    try: raise SystemExit(main())
    except EvidenceError as exc:
        print(f"T04TMP3H_ANALYZER_FAIL\t{exc}", file=sys.stderr); raise SystemExit(42)
