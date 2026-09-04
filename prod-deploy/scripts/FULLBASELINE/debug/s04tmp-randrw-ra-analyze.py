#!/usr/bin/env python3
"""Offline-only analyzer for 04-tmp max-readahead randrw A/B."""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

ARM_ORDER = ["A", "B", "B", "A", "B", "A", "A", "B"]
LABELS = [f"R{i:02d}" for i in range(1, 9)]
PAIR_SEEDS = [41001, 41001, 41002, 41002, 41003, 41003, 41004, 41004]
T95_DF4 = 2.7764451051977987
T95_ONE_DF4 = 2.131846786326649


class EvidenceError(RuntimeError):
    pass


def percentile(vals: list[float], p: float) -> float:
    xs = sorted(vals); pos = (len(xs) - 1) * p; lo = math.floor(pos); hi = math.ceil(pos)
    return xs[lo] if lo == hi else xs[lo] * (hi - pos) + xs[hi] * (pos - lo)


def exact_log_files(bwdir: Path, expected: int = 128) -> list[tuple[int, Path]]:
    files = sorted(bwdir.glob("*_bw.*.log"))
    rows = []
    for path in files:
        match = re.search(r"_bw\.(\d+)\.log$", path.name)
        if not match:
            raise EvidenceError(f"unexpected bw-log name: {path.name}")
        rows.append((int(match.group(1)), path))
    ids = [x[0] for x in rows]
    if len(rows) != expected or sorted(ids) != list(range(1, expected + 1)) or len(set(ids)) != expected:
        raise EvidenceError(f"require unique bw-log ids 1..{expected}; count={len(rows)} ids={ids}")
    return sorted(rows)


def mixed_logs(bwdir: Path, start_sec: int = 15) -> dict:
    files = exact_log_files(bwdir)
    values = {0: defaultdict(lambda: defaultdict(float)), 1: defaultdict(lambda: defaultdict(float))}
    weights = {0: defaultdict(lambda: defaultdict(float)), 1: defaultdict(lambda: defaultdict(float))}
    for job, path in files:
        previous = {0: 0.0, 1: 0.0}; seen = {0: 0, 1: 0}
        with path.open(newline="") as handle:
            for line_no, row in enumerate(csv.reader(handle), 1):
                if len(row) < 3:
                    raise EvidenceError(f"truncated bw row {path}:{line_no}")
                try:
                    end = float(row[0]) / 1000.0
                    rate = float(row[1]) / 1024.0
                    direction = int(row[2])
                except ValueError as exc:
                    raise EvidenceError(f"invalid bw row {path}:{line_no}") from exc
                if direction not in (0, 1) or end <= previous[direction] or rate < 0:
                    raise EvidenceError(f"bad direction/time/rate {path}:{line_no}")
                begin = previous[direction]; previous[direction] = end; seen[direction] += 1
                for second in range(math.floor(begin), math.ceil(end)):
                    overlap = min(end, second + 1) - max(begin, second)
                    if overlap > 0:
                        values[direction][second][job] += rate * overlap
                        weights[direction][second][job] += overlap
        if any(seen[d] < 175 for d in (0, 1)):
            raise EvidenceError(f"direction missing/truncated in {path}: {seen}")

    result = {}
    series_by_direction = {}
    for direction, name in ((0, "read"), (1, "write")):
        aggregate = {}
        for second in sorted(values[direction]):
            if len(values[direction][second]) != 128:
                continue
            if any(weights[direction][second].get(job, 0) <= 0 for job in range(1, 129)):
                continue
            aggregate[second] = sum(values[direction][second][job] / weights[direction][second][job]
                                    for job in range(1, 129))
        formal_seconds = list(range(start_sec, start_sec + 160))
        formal = [aggregate[x] for x in formal_seconds if x in aggregate]
        if len(formal) != 160:
            raise EvidenceError(f"{name} formal window has {len(formal)} complete seconds, expected 160")
        windows = []
        for begin in range(start_sec, start_sec + 160, 40):
            vals = [aggregate[x] for x in range(begin, begin + 40) if x in aggregate]
            if len(vals) != 40:
                raise EvidenceError(f"{name} window {begin}:{begin+40} incomplete")
            windows.append(statistics.mean(vals))
        mean = statistics.mean(formal)
        if mean <= 0:
            raise EvidenceError(f"{name} formal mean is not positive")
        result[name] = {
            "n_logs": 128, "formal_n": 160, "mean_MiBs": mean,
            "median_MiBs": statistics.median(formal),
            "cv_pct": statistics.pstdev(formal) / mean * 100,
            "p10_MiBs": percentile(formal, .10), "p90_MiBs": percentile(formal, .90),
            "windows_MiBs": windows, "w4_w1": windows[-1] / windows[0],
            "per_second_MiBs": {str(x): aggregate[x] for x in formal_seconds},
        }
        series_by_direction[name] = formal
    read = series_by_direction["read"]; write = series_by_direction["write"]
    mr = statistics.mean(read); mw = statistics.mean(write)
    covariance = sum((a - mr) * (b - mw) for a, b in zip(read, write)) / len(read)
    denom = statistics.pstdev(read) * statistics.pstdev(write)
    result["combined_explanatory"] = {
        "mean_MiBs": statistics.mean(a + b for a, b in zip(read, write)),
        "read_write_correlation": covariance / denom if denom else None,
        "not_a_verdict_endpoint": True,
    }
    return result


def parse_run_ms(text: str) -> int:
    values = [int(b or a) for a, b in re.findall(r"run=(\d+)(?:-(\d+))?msec", text)]
    if not values:
        raise EvidenceError("fio output lacks run=...msec")
    run = max(values)
    if not 175000 <= run <= 190000:
        raise EvidenceError(f"unexpected fio runtime {run}ms")
    return run


def validate_assets(path: Path) -> dict:
    rows = []
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if not reader.fieldnames or not {"name", "size", "inode", "mtime"}.issubset(reader.fieldnames):
            raise EvidenceError("asset TSV fields missing")
        rows = list(reader)
    expected = {f"rw_test.{i}.0" for i in range(128)}
    names = [x["name"] for x in rows]
    if len(rows) != 128 or len(set(names)) != 128 or set(names) != expected:
        raise EvidenceError("asset names must be exactly rw_test.0.0..rw_test.127.0")
    if any(int(x["size"]) != 1073741824 for x in rows):
        raise EvidenceError("all assets must be exactly 1 GiB")
    if any(not x["inode"].isdigit() for x in rows):
        raise EvidenceError("asset inode is not numeric")
    return {"asset_count": 128, "size_each": 1073741824, "total_size": 128 * 1073741824}


def validate_objects(path: Path, pool: str, seed: int | None, tolerance: int) -> dict:
    data = json.loads(path.read_text())
    pools = [x for x in data.get("pools", []) if x.get("name", x.get("pool_name")) == pool]
    if len(pools) != 1:
        raise EvidenceError(f"pool {pool}: expected one JSON row, got {len(pools)}")
    value = pools[0].get("stats", {}).get("objects")
    stored = pools[0].get("stats", {}).get("stored")
    if not isinstance(value, (int, float)) or not math.isfinite(float(value)) or value < 0 or int(value) != value:
        raise EvidenceError(f"invalid JSON objects counter: {value!r}")
    if not isinstance(stored, (int, float)) or not math.isfinite(float(stored)) or stored < 0:
        raise EvidenceError(f"invalid JSON stored counter: {stored!r}")
    count = int(value); within = None if seed is None else abs(count - seed) <= tolerance
    if seed is not None and not within:
        raise EvidenceError(f"objects={count} outside seed={seed} tolerance={tolerance}")
    return {"pool": pool, "objects": count, "stored": float(stored), "seed": seed, "tolerance": tolerance,
            "within_seed_tolerance": within}


def transpose(a): return [list(x) for x in zip(*a)]


def matmul(a, b):
    bt = transpose(b)
    return [[sum(x * y for x, y in zip(row, col)) for col in bt] for row in a]


def invert(a):
    n = len(a); z = [list(map(float, row)) + [1.0 if i == j else 0.0 for j in range(n)]
                      for i, row in enumerate(a)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda row: abs(z[row][col]))
        if abs(z[pivot][col]) < 1e-12:
            raise EvidenceError("singular fixed model")
        z[col], z[pivot] = z[pivot], z[col]
        scale = z[col][col]; z[col] = [x / scale for x in z[col]]
        for row in range(n):
            if row == col: continue
            scale = z[row][col]; z[row] = [x - scale * y for x, y in zip(z[row], z[col])]
    return [row[n:] for row in z]


def model(values: list[float]) -> dict:
    if len(values) != 8:
        raise EvidenceError("registered model requires eight rounds")
    design = []
    for index, arm in enumerate(ARM_ORDER, 1):
        x = index - 4.5; design.append([1.0, x, x * x, 1.0 if arm == "B" else 0.0])
    inv = invert(matmul(transpose(design), design))
    beta = [x[0] for x in matmul(matmul(inv, transpose(design)), [[v] for v in values])]
    residual = [value - sum(a * b for a, b in zip(row, beta)) for value, row in zip(values, design)]
    sigma2 = sum(x * x for x in residual) / 4
    se = math.sqrt(max(0.0, sigma2 * inv[3][3]))
    a_values = [v for v, arm in zip(values, ARM_ORDER) if arm == "A"]
    a_mean = statistics.mean(a_values); effect = beta[3] / a_mean * 100; se_pct = se / a_mean * 100
    half = T95_DF4 * se_pct; one_low = effect - T95_ONE_DF4 * se_pct
    pairs = [(values[1] / values[0] - 1) * 100, (values[2] / values[3] - 1) * 100,
             (values[4] / values[5] - 1) * 100, (values[7] / values[6] - 1) * 100]
    return {
        "beta": beta, "a_raw_mean_MiBs": a_mean,
        "b_raw_mean_MiBs": statistics.mean(v for v, a in zip(values, ARM_ORDER) if a == "B"),
        "effect_pct": effect, "ci95_pct": [effect - half, effect + half],
        "one_sided95_low_pct": one_low, "ci95_halfwidth_pct": half,
        "cross_arm_pair_effect_pct": pairs, "values_MiBs": values,
    }


def validate_sidecar(round_dir: Path) -> dict:
    sampler = round_dir / "sampler"; heartbeat = sampler / "heartbeat.tsv"; perf = sampler / "osd-perf.tsv"
    if not (heartbeat.is_file() and perf.is_file() and (sampler / "SAMPLER_PASS").is_file()):
        raise EvidenceError("sampler evidence incomplete")
    with heartbeat.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if len(rows) < 3:
        raise EvidenceError("sampler heartbeat has fewer than three samples")
    epochs = [int(x["epoch_ns"]) for x in rows]
    if epochs != sorted(set(epochs)) or any(int(x["osd_rows"]) != 6 for x in rows):
        raise EvidenceError("heartbeat epoch/OSD-row contract failed")
    run_ms = parse_run_ms((round_dir / "fio.txt").read_text(errors="replace"))
    end_ns = int((round_dir / "fio-end-ns.txt").read_text().strip()); actual = end_ns - run_ms * 1_000_000
    if epochs[0] > actual or epochs[-1] < actual + 175_000_000_000:
        raise EvidenceError("sampler does not bracket actual formal window")
    with perf.open(newline="") as handle:
        perf_rows = list(csv.DictReader(handle, delimiter="\t"))
    required = {"epoch_ns", "osd", "op_r", "op_r_out_bytes", "op_w", "op_w_in_bytes",
                "compact_running", "compact_queue_len", "kv_sync_sum", "kv_sync_count"}
    if not perf_rows or not required.issubset(perf_rows[0]):
        raise EvidenceError("OSD sidecar fields missing")
    by_osd = defaultdict(list)
    for row in perf_rows:
        by_osd[int(row["osd"])].append(row)
    if len(by_osd) != 6:
        raise EvidenceError(f"OSD sidecar requires six OSDs, got {sorted(by_osd)}")
    counters = ("op_r", "op_r_out_bytes", "op_w", "op_w_in_bytes", "kv_sync_sum", "kv_sync_count")
    for osd, osd_rows in by_osd.items():
        osd_rows.sort(key=lambda x: int(x["epoch_ns"])); previous = None
        for row in osd_rows:
            current = tuple(float(row[x]) for x in counters)
            if previous is not None and any(a < b for a, b in zip(current, previous)):
                raise EvidenceError(f"OSD counter wrapped/reset on osd.{osd}")
            previous = current
    health_files = sorted((sampler / "raw").glob("health-*.json")); pg_files = sorted((sampler / "raw").glob("pg-*.json"))
    if health_files or pg_files:
        if len(health_files) != len(rows) or len(pg_files) != len(rows):
            raise EvidenceError("health/PG sampling coverage differs from heartbeat")
        for path in health_files:
            data = json.loads(path.read_text()); status = data.get("status"); checks = data.get("checks", {})
            if not ((status == "HEALTH_OK" and not checks) or
                    (status == "HEALTH_WARN" and set(checks) == {"OSDMAP_FLAGS"})):
                raise EvidenceError(f"unexpected health during formal window: {path.name}")
        for path in pg_files:
            data = json.loads(path.read_text()); pg_rows = data.get("pg_stats", data.get("pg_map", {}).get("pg_stats", []))
            if not pg_rows or any(str(x.get("state", "")) != "active+clean" for x in pg_rows):
                raise EvidenceError(f"nonclean/scrub PG during formal window: {path.name}")
    return {"heartbeat_samples": len(rows), "osds": 6, "actual_t0_ns": actual,
            "first_sample_ns": epochs[0], "last_sample_ns": epochs[-1]}


def round_command(args) -> None:
    data = mixed_logs(args.round_dir / "bw", args.start_sec)
    fio_text = (args.round_dir / "fio.txt").read_text(errors="replace")
    run_ms = parse_run_ms(fio_text)
    end_ns = int((args.round_dir / "fio-end-ns.txt").read_text().strip())
    start_registered = int((args.round_dir / "fio-start-ns.txt").read_text().strip())
    actual_start = end_ns - run_ms * 1_000_000
    output = {"schema": 1, "label": args.label, "arm": args.arm, "randseed": args.randseed,
              "run_ms": run_ms, "actual_t0_ns": actual_start,
              "registered_start_ns": start_registered,
              "start_delta_s": (actual_start - start_registered) / 1e9,
              "directions": data}
    args.output.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(f"ROUND_EVIDENCE_PASS label={args.label} arm={args.arm} "
          f"read={data['read']['mean_MiBs']:.3f} write={data['write']['mean_MiBs']:.3f}")


def matrix_command(args) -> None:
    rows = [json.loads(Path(x).read_text()) for x in args.inputs]
    if [x.get("label") for x in rows] != LABELS or [x.get("arm") for x in rows] != ARM_ORDER:
        raise EvidenceError("label/arm matrix differs from frozen ABBA-BAAB")
    if [int(x.get("randseed", -1)) for x in rows] != PAIR_SEEDS:
        raise EvidenceError("formal randseed pairing differs from frozen contract")
    endpoints = {}
    for direction in ("read", "write"):
        endpoints[direction] = model([float(x["directions"][direction]["mean_MiBs"]) for x in rows])
    if any(x["ci95_halfwidth_pct"] > 5 for x in endpoints.values()):
        verdict = "RW_RA_RESOLUTION_INSUFFICIENT"
    elif any(x["ci95_pct"][1] < -5 for x in endpoints.values()):
        verdict = "RW_RA0_REGRESSION"
    elif all(x["effect_pct"] >= 5 and x["one_sided95_low_pct"] > 0 for x in endpoints.values()):
        verdict = "RW_RA0_DUAL_DIRECTION_BENEFIT_CONFIRMED"
    elif ((endpoints["read"]["effect_pct"] >= 5) != (endpoints["write"]["effect_pct"] >= 5)
          or any(x["effect_pct"] <= -5 for x in endpoints.values())):
        verdict = "RW_RA0_DIRECTION_TRADEOFF"
    elif all(x["effect_pct"] < 5 and x["ci95_pct"][0] <= 0 <= x["ci95_pct"][1]
             for x in endpoints.values()):
        verdict = "RW_RA0_NO_MATERIAL_BENEFIT"
    else:
        verdict = "RW_RA_INCONCLUSIVE"
    output = {"schema": 1, "verdict": verdict, "arms": ARM_ORDER, "labels": LABELS,
              "randseeds": PAIR_SEEDS, "endpoints": endpoints,
              "executor_must_not_use_this_output": True}
    args.output.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(f"VERDICT={verdict}")


def main() -> None:
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="command", required=True)
    assets = sub.add_parser("assets"); assets.add_argument("--input", type=Path, required=True)
    assets.add_argument("--output", type=Path, required=True)
    objects = sub.add_parser("objects"); objects.add_argument("--input", type=Path, required=True)
    objects.add_argument("--pool", required=True); objects.add_argument("--seed", type=int)
    objects.add_argument("--tolerance", type=int, default=8192); objects.add_argument("--output", type=Path, required=True)
    rnd = sub.add_parser("round"); rnd.add_argument("--round-dir", type=Path, required=True)
    rnd.add_argument("--label", required=True); rnd.add_argument("--arm", choices=("A", "B"), required=True)
    rnd.add_argument("--randseed", type=int, required=True); rnd.add_argument("--start-sec", type=int, default=15)
    rnd.add_argument("--output", type=Path, required=True)
    matrix = sub.add_parser("matrix"); matrix.add_argument("--inputs", nargs="+", required=True)
    matrix.add_argument("--output", type=Path, required=True)
    sidecar = sub.add_parser("sidecar"); sidecar.add_argument("--round-dir", type=Path, required=True)
    sidecar.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(); args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.command == "assets":
        out = validate_assets(args.input); args.output.write_text(json.dumps(out, indent=2) + "\n")
        print("ASSET_CONTRACT_PASS count=128 size=1073741824")
    elif args.command == "objects":
        out = validate_objects(args.input, args.pool, args.seed, args.tolerance)
        args.output.write_text(json.dumps(out, indent=2) + "\n")
        print(f"OBJECT_CONTRACT_PASS objects={out['objects']}")
    elif args.command == "round": round_command(args)
    elif args.command == "sidecar":
        out = validate_sidecar(args.round_dir); args.output.write_text(json.dumps(out, indent=2) + "\n")
        print(f"SIDECAR_CONTRACT_PASS samples={out['heartbeat_samples']} osds=6")
    else: matrix_command(args)


if __name__ == "__main__":
    try:
        main()
    except (EvidenceError, AssertionError, KeyError, ValueError) as exc:
        print(f"E_S04TMP_ANALYZE\t{exc}", file=sys.stderr)
        raise SystemExit(42)
