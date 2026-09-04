#!/usr/bin/env python3
"""Deterministically repair 04-6 mechanism evidence from frozen local raw data.

This program has no network or subprocess path.  It writes only two derived
``mechanism.json`` files and one post-mechanism analyzer result below the
explicit evidence root supplied by the caller.  Existing, different derived
files are never overwritten.
"""
from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import math
import os
import re
import statistics
import tempfile
from pathlib import Path


FORMAL_WINDOW = "[15,175)"
FORMAL_START_NS = 15_000_000_000
FORMAL_END_NS = 175_000_000_000
HOSTS = ("10.20.1.150", "10.20.1.151", "10.20.1.152")
DEVICES = ("nvme2n1", "nvme3n1")
OSDS = tuple(range(6))
MIN_FORMAL_SAMPLES = 12
MIN_COUNTER_SPAN_S = 140.0
RUN_RE = re.compile(r"run=(\d+)(?:-(\d+))?msec")
IOSTAT_RE = re.compile(r"^tikv-(10\.20\.1\.(?:150|151|152))-(\d+)\.txt$")


class RepairError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RepairError(message)


def finite_number(value, label: str) -> float:
    require(type(value) in (int, float), f"{label} must be a JSON number")
    value = float(value)
    require(math.isfinite(value), f"{label} must be finite")
    return value


def formal_bounds(cell: Path) -> tuple[int, int, int]:
    fio = cell / "fio.txt"
    end_file = cell / "fio-end-ns.txt"
    require(fio.is_file() and end_file.is_file(), f"missing fio timing evidence in {cell}")
    matches = RUN_RE.findall(fio.read_text(errors="replace"))
    require(bool(matches), f"fio runtime absent in {fio}")
    run_ms = max(int(second or first) for first, second in matches)
    require(175_000 <= run_ms <= 190_000, f"unexpected runtime {run_ms}ms in {cell.name}")
    end_ns = int(end_file.read_text().strip())
    t0_ns = end_ns - run_ms * 1_000_000
    return t0_ns + FORMAL_START_NS, t0_ns + FORMAL_END_NS, t0_ns


def relative_source(cell: Path, path: Path) -> str:
    try:
        value = path.relative_to(cell).as_posix()
    except ValueError as exc:
        raise RepairError(f"source escapes cell: {path}") from exc
    p = Path(value)
    require(not p.is_absolute() and ".." not in p.parts and path.is_file(),
            f"invalid source file: {value}")
    return value


def parse_iostat_util(path: Path) -> dict[str, float]:
    found: dict[str, float] = {}
    for line in path.read_text(errors="replace").splitlines():
        fields = line.split()
        if not fields or fields[0] not in DEVICES:
            continue
        require(len(fields) >= 2, f"short iostat row in {path}")
        require(fields[0] not in found, f"duplicate {fields[0]} row in {path}")
        try:
            value = float(fields[-1])
        except ValueError as exc:
            raise RepairError(f"invalid %util in {path}: {line}") from exc
        require(math.isfinite(value) and 0 <= value <= 101,
                f"out-of-range %util {value} in {path}")
        found[fields[0]] = value
    require(set(found) == set(DEVICES), f"OSD device rows missing in {path}: {sorted(found)}")
    return found


def iostat_formal(cell: Path) -> dict:
    lo, hi, t0 = formal_bounds(cell)
    values = {(host, dev): [] for host in HOSTS for dev in DEVICES}
    sources: list[Path] = []
    epochs_by_host = {host: set() for host in HOSTS}
    for path in sorted((cell / "sampler" / "iostat").glob("tikv-*.txt")):
        match = IOSTAT_RE.fullmatch(path.name)
        if not match:
            continue
        host, epoch_text = match.groups()
        epoch = int(epoch_text)
        if not lo <= epoch < hi:
            continue
        parsed = parse_iostat_util(path)
        sources.append(path)
        epochs_by_host[host].add(epoch)
        for dev, value in parsed.items():
            values[(host, dev)].append(value)
    epoch_sets = list(epochs_by_host.values())
    require(all(len(x) >= MIN_FORMAL_SAMPLES for x in epoch_sets),
            f"insufficient formal iostat samples: { {h: len(v) for h, v in epochs_by_host.items()} }")
    require(all(x == epoch_sets[0] for x in epoch_sets[1:]),
            "three hosts do not have identical formal iostat epochs")
    counts = {key: len(rows) for key, rows in values.items()}
    require(set(counts.values()) == {len(epoch_sets[0])}, f"device sample count mismatch: {counts}")
    medians = {f"{host}/{dev}": statistics.median(values[(host, dev)])
               for host in HOSTS for dev in DEVICES}
    all_values = [value for rows in values.values() for value in rows]
    return {
        "t0_ns": t0,
        "formal_start_ns": lo,
        "formal_end_ns": hi,
        "epoch_count": len(epoch_sets[0]),
        "observation_count": len(all_values),
        "device_p50_pct": medians,
        "global_p50_pct": statistics.median(all_values),
        "min_pct": min(all_values),
        "max_pct": max(all_values),
        "sources": sources,
    }


def require_six_saturated_devices(data: dict) -> None:
    medians = data["device_p50_pct"]
    expected = {f"{host}/{dev}" for host in HOSTS for dev in DEVICES}
    require(set(medians) == expected, f"expected six OSD devices, got {sorted(medians)}")
    failed = {key: value for key, value in medians.items() if value < 90.0}
    require(not failed, f"OSD device formal-window P50 below 90%: {failed}")
    require(finite_number(data["global_p50_pct"], "global_p50_pct") >= 90.0,
            "global OSD device P50 below 90%")


def osd_completion(cell: Path, direction: str) -> dict:
    require(direction in ("r", "w"), "direction must be r or w")
    lo, hi, _ = formal_bounds(cell)
    path = cell / "sampler" / "osd-perf.tsv"
    require(path.is_file(), f"missing {path}")
    rows: dict[int, list[dict[str, str]]] = {osd: [] for osd in OSDS}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            epoch = int(row["epoch_ns"])
            osd = int(row["osd"])
            require(osd in OSDS, f"unexpected OSD id {osd} in {path}")
            if lo <= epoch < hi:
                rows[osd].append(row)
    require(all(len(value) >= MIN_FORMAL_SAMPLES for value in rows.values()),
            f"insufficient OSD samples in {cell.name}")
    epoch_sequences = [[int(row["epoch_ns"]) for row in rows[osd]] for osd in OSDS]
    require(all(sequence == epoch_sequences[0] for sequence in epoch_sequences[1:]),
            f"OSD counter epochs are not identical in {cell.name}")
    first_epochs = {int(value[0]["epoch_ns"]) for value in rows.values()}
    last_epochs = {int(value[-1]["epoch_ns"]) for value in rows.values()}
    require(len(first_epochs) == len(last_epochs) == 1,
            f"OSD counter endpoints are not aligned in {cell.name}")
    start_ns, end_ns = next(iter(first_epochs)), next(iter(last_epochs))
    elapsed = (end_ns - start_ns) / 1_000_000_000
    require(elapsed >= MIN_COUNTER_SPAN_S, f"OSD formal counter span too short: {elapsed:.3f}s")
    count_key = f"op_{direction}"
    bytes_key = f"op_{direction}_{'out' if direction == 'r' else 'in'}_bytes"
    latency_key = f"op_{direction}_lat_sum"
    delta_count = delta_bytes = delta_latency = 0.0
    for osd in OSDS:
        before, after = rows[osd][0], rows[osd][-1]
        dc = float(after[count_key]) - float(before[count_key])
        db = float(after[bytes_key]) - float(before[bytes_key])
        dl = float(after[latency_key]) - float(before[latency_key])
        require(dc >= 0 and db >= 0 and dl >= 0,
                f"non-monotonic OSD counter in {cell.name}/osd.{osd}")
        delta_count += dc
        delta_bytes += db
        delta_latency += dl
    return {
        "first_epoch_ns": start_ns,
        "last_epoch_ns": end_ns,
        "elapsed_s": elapsed,
        "sample_count_per_osd": len(rows[0]),
        "ops_per_s": delta_count / elapsed,
        "MiB_per_s": delta_bytes / elapsed / (1024 * 1024),
        "average_latency_ms": (delta_latency / delta_count * 1000) if delta_count else None,
        "source": path,
    }


def health_gate(cell: Path) -> Path:
    lo, hi, _ = formal_bounds(cell)
    path = cell / "sampler" / "ceph-health.tsv"
    require(path.is_file(), f"missing {path}")
    count = 0
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            if not lo <= int(row["epoch_ns"]) < hi:
                continue
            count += 1
            require(row["total_pgs"] == "97" and row["active_clean_pgs"] == "97"
                    and row["other_states"] == "none",
                    f"non-clean PG state in {cell.name}: {row}")
            allowed = ((row["health"] == "HEALTH_WARN" and row["check_keys"] == "OSDMAP_FLAGS")
                       or (row["health"] == "HEALTH_OK" and row["check_keys"] == "none"))
            require(allowed, f"unexpected health state in {cell.name}: {row}")
    require(count >= MIN_FORMAL_SAMPLES, f"insufficient health samples in {cell.name}: {count}")
    return path


def bluestore_hit_ratio(cell: Path) -> dict:
    lo, hi, _ = formal_bounds(cell)
    hit = miss = 0.0
    sources: list[Path] = []
    raw = cell / "sampler" / "raw"
    for osd in OSDS:
        samples: list[tuple[int, Path, float, float]] = []
        for path in sorted(raw.glob(f"osd-{osd}-*.json")):
            match = re.fullmatch(rf"osd-{osd}-(\d+)\.json", path.name)
            require(match is not None, f"unexpected OSD raw filename {path.name}")
            epoch = int(match.group(1))
            if not lo <= epoch < hi:
                continue
            data = json.loads(path.read_text())
            blue = data.get("bluestore", {})
            require("buffer_hit_bytes" in blue and "buffer_miss_bytes" in blue,
                    f"BlueStore buffer counters missing in {path}")
            samples.append((epoch, path, float(blue["buffer_hit_bytes"]),
                            float(blue["buffer_miss_bytes"])))
        require(len(samples) >= MIN_FORMAL_SAMPLES, f"insufficient BlueStore samples for osd.{osd}")
        before, after = samples[0], samples[-1]
        dh, dm = after[2] - before[2], after[3] - before[3]
        require(dh >= 0 and dm >= 0, f"non-monotonic BlueStore counters for osd.{osd}")
        hit += dh
        miss += dm
        sources.extend((before[1], after[1]))
    require(hit + miss > 0, "no BlueStore read bytes in formal window")
    return {"hit_bytes": hit, "miss_bytes": miss, "hit_ratio": hit / (hit + miss),
            "sources": sources}


def max_thread_p50(cell: Path) -> dict:
    lo, hi, _ = formal_bounds(cell)
    path = cell / "sampler" / "mount-threads.tsv"
    by_thread: dict[tuple[str, str], list[tuple[int, int]]] = {}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            epoch = int(row["epoch_ns"])
            if lo <= epoch < hi:
                key = (row["tid"], row["comm"])
                ticks = int(row["utime_ticks"]) + int(row["stime_ticks"])
                by_thread.setdefault(key, []).append((epoch, ticks))
    rates = []
    for key, samples in by_thread.items():
        if len(samples) < 2:
            continue
        intervals = [(b_ticks - a_ticks) / ((b_epoch - a_epoch) / 1_000_000_000)
                     for (a_epoch, a_ticks), (b_epoch, b_ticks) in zip(samples, samples[1:])]
        require(all(value >= 0 for value in intervals), f"non-monotonic thread ticks: {key}")
        rates.append((statistics.median(intervals), key))
    require(bool(rates), f"no usable thread samples in {cell.name}")
    value, key = max(rates)
    # The RUN did not freeze USER_HZ, so retain the raw ticks/s unit instead of
    # manufacturing a CPU percentage.  This field is descriptive only and
    # never upgrades R02.
    return {"p50_ticks_per_second": value, "tid": key[0], "comm": key[1], "source": path}


def validate_mechanism(cell: Path, data: dict, expected_saturated: bool) -> None:
    require(isinstance(data, dict), "mechanism must be a JSON object")
    require(data.get("formal_window") == FORMAL_WINDOW, "formal_window schema mismatch")
    require(data.get("saturated") is expected_saturated, "saturated schema mismatch")
    require(isinstance(data.get("component"), str) and data["component"], "component is required")
    sources = data.get("source_files")
    require(isinstance(sources, list) and sources and len(sources) == len(set(sources)),
            "source_files must be a non-empty unique list")
    for source in sources:
        require(isinstance(source, str) and source, "source_files contains invalid entry")
        p = Path(source)
        require(not p.is_absolute() and ".." not in p.parts and (cell / p).is_file(),
                f"source_files entry is invalid: {source}")
    if expected_saturated:
        require(finite_number(data.get("util_p50_pct"), "util_p50_pct") >= 90.0,
                "saturated mechanism lacks >=90% hard evidence")
    require("completion_rate_reproduces_history_pct" not in data,
            "historical-limit evidence is not available in this repair")


def load_analyzer():
    path = Path(__file__).with_name("t04-6-capacity-analyze.py")
    require(path.is_file(), f"original analyzer missing: {path}")
    spec = importlib.util.spec_from_file_location("t046_capacity_analyze", path)
    require(spec is not None and spec.loader is not None, "cannot load original analyzer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_mechanisms(root: Path, pre: dict) -> tuple[dict, dict]:
    w_cells = {name: root / "cells" / name for name in ("W01", "W02", "W03")}
    r02 = root / "cells" / "R02"
    require(all(path.is_dir() for path in (*w_cells.values(), r02)), "required cell directory missing")

    w_curve = pre["projects"]["mseqwrite"]["curve"]
    require(w_curve["anchor_drift"] <= 0.05, "W anchor drift exceeds 5%")
    require(w_curve["scale_ratio"] <= 1.15, "W fio completion rate is not a plateau")
    require(w_curve["lat_ratio"] is not None and w_curve["lat_ratio"] >= 1.60,
            "W P50 latency ratio is below 1.60")
    r_curve = pre["projects"]["mseqread"]["curve"]
    require(r_curve["lat_ratio"] is not None and r_curve["lat_ratio"] < 1.60,
            "R no longer satisfies the registered non-upgrade condition")
    for project in ("randrw", "randrw.write"):
        curve = pre["projects"][project]["curve"]
        require(curve["anchor_drift"] > 0.05 and curve["status"] == "INCONCLUSIVE_DRIFT",
                f"{project} drift gate unexpectedly changed")

    completions = {cell: osd_completion(path, "w") for cell, path in w_cells.items()}
    low_ops = statistics.mean((completions["W01"]["ops_per_s"], completions["W03"]["ops_per_s"]))
    low_bytes = statistics.mean((completions["W01"]["MiB_per_s"], completions["W03"]["MiB_per_s"]))
    op_ratio = completions["W02"]["ops_per_s"] / low_ops
    byte_ratio = completions["W02"]["MiB_per_s"] / low_bytes
    require(op_ratio <= 1.15 and byte_ratio <= 1.15,
            f"W OSD completion-rate ratio exceeds 1.15: ops={op_ratio}, bytes={byte_ratio}")
    for cell in (*w_cells.values(), r02):
        health_gate(cell)

    w_util = iostat_formal(w_cells["W02"])
    require_six_saturated_devices(w_util)
    w_sources = [w_cells["W02"] / name for name in
                 ("fio.txt", "fio-end-ns.txt", "latency.tsv", "sampler/osd-perf.tsv",
                  "sampler/ceph-health.tsv", "sampler/iostat.tsv")]
    w_sources.extend(w_util["sources"])
    w = {
        "schema": "t04-6-mechanism-v1",
        "formal_window": FORMAL_WINDOW,
        "component": "Ceph EC4+2 six-OSD data-device write service",
        "saturated": True,
        "util_p50_pct": w_util["global_p50_pct"],
        "device_util": {
            "metric": "iostat %util; median over samples whose filename epoch is in the formal window",
            "hosts": list(HOSTS), "devices_per_host": list(DEVICES),
            "epoch_count_per_device": w_util["epoch_count"],
            "observation_count": w_util["observation_count"],
            "device_p50_pct": w_util["device_p50_pct"],
            "min_pct": w_util["min_pct"], "max_pct": w_util["max_pct"],
        },
        "completion_rate": {
            "formula": "sum(OSD counter last-first) / aligned elapsed seconds inside [15,175)",
            "W01": {k: v for k, v in completions["W01"].items() if k != "source"},
            "W02": {k: v for k, v in completions["W02"].items() if k != "source"},
            "W03": {k: v for k, v in completions["W03"].items() if k != "source"},
            "high_to_low_mean_ops_ratio": op_ratio,
            "high_to_low_mean_bytes_ratio": byte_ratio,
        },
        "registered_curve_gate": {
            "anchor_drift": w_curve["anchor_drift"], "scale_ratio": w_curve["scale_ratio"],
            "lat_ratio": w_curve["lat_ratio"],
        },
        "source_files": sorted({relative_source(w_cells["W02"], p) for p in w_sources}),
        "cross_cell_source_files": [
            "cells/W01/sampler/osd-perf.tsv", "cells/W03/sampler/osd-perf.tsv"
        ],
    }
    validate_mechanism(w_cells["W02"], w, True)
    for source in w["cross_cell_source_files"]:
        require((root / source).is_file(), f"cross-cell source missing: {source}")

    r_util = iostat_formal(r02)
    r_hit = bluestore_hit_ratio(r02)
    r_thread = max_thread_p50(r02)
    r_completion = osd_completion(r02, "r")
    r_sources = [r02 / name for name in
                 ("fio.txt", "fio-end-ns.txt", "latency.tsv", "sampler/osd-perf.tsv",
                  "sampler/ceph-health.tsv", "sampler/iostat.tsv", "sampler/mount-threads.tsv",
                  "sampler/client-host.tsv", "sampler/nic.tsv")]
    r_sources.extend(r_util["sources"])
    r_sources.extend(r_hit["sources"])
    r = {
        "schema": "t04-6-mechanism-v1",
        "formal_window": FORMAL_WINDOW,
        "component": "unresolved BlueStore-cache-served read path",
        "saturated": False,
        "util_p50_pct": r_util["global_p50_pct"],
        "non_upgrade_reason": "registered fio P50 latency ratio is below 1.60 and no hard saturation proof exists",
        "registered_curve_gate": {
            "anchor_drift": r_curve["anchor_drift"], "scale_ratio": r_curve["scale_ratio"],
            "lat_ratio": r_curve["lat_ratio"],
        },
        "bluestore_buffer_hit_ratio": r_hit["hit_ratio"],
        "bluestore_buffer_hit_bytes": r_hit["hit_bytes"],
        "bluestore_buffer_miss_bytes": r_hit["miss_bytes"],
        "max_mount_thread_p50_ticks_per_second": r_thread["p50_ticks_per_second"],
        "mount_thread_cpu_pct_note": "not computed because USER_HZ was not frozen in RUN evidence",
        "max_mount_thread": {"tid": r_thread["tid"], "comm": r_thread["comm"]},
        "osd_read_completion": {k: v for k, v in r_completion.items() if k != "source"},
        "device_p50_pct": r_util["device_p50_pct"],
        "source_files": sorted({relative_source(r02, p) for p in r_sources}),
    }
    validate_mechanism(r02, r, False)
    return w, r


def deterministic_json(data: dict) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def write_new_or_identical(path: Path, text: str) -> None:
    require(not path.is_symlink(), f"refuse symlink output: {path}")
    if path.exists():
        require(path.is_file() and path.read_text() == text,
                f"existing derived file differs; refusing overwrite: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def repair(root: Path) -> dict:
    require(root.is_absolute() and root.is_dir() and not root.is_symlink(),
            "evidence root must be an absolute, existing, non-symlink directory")
    analyzer = load_analyzer()
    pre = analyzer.analyze_matrix(root)
    w, r = build_mechanisms(root, pre)
    w_path, r_path = root / "cells/W02/mechanism.json", root / "cells/R02/mechanism.json"
    write_new_or_identical(w_path, deterministic_json(w))
    write_new_or_identical(r_path, deterministic_json(r))

    w_check = analyzer.mechanism(root / "cells/W02")
    r_check = analyzer.mechanism(root / "cells/R02")
    require(w_check["present"] and w_check["saturated"] and w_check["hard_evidence"]
            and w_check["valid_provenance"], "original analyzer rejected W02 mechanism")
    require(r_check["present"] and not r_check["saturated"],
            "original analyzer unexpectedly upgraded R02")
    post = analyzer.analyze_matrix(root)
    require(post["projects"]["mseqwrite"]["curve"]["status"] == "SERVICE_PLATEAU_IDENTIFIED",
            "W curve did not close to SERVICE_PLATEAU_IDENTIFIED")
    require(post["projects"]["mseqread"]["curve"]["status"] == "PARTIAL_SCALING",
            "R curve was unexpectedly upgraded")
    for project in ("randrw", "randrw.write"):
        require(post["projects"][project]["curve"]["status"] == "INCONCLUSIVE_DRIFT",
                f"{project} drift was unexpectedly overridden")
    require(post["stage_decision"] == "STAGE04_CONTINUE_DIAGNOSIS",
            "original analyzer stage decision unexpectedly changed")
    output = root / "analysis-postmechanism.json"
    write_new_or_identical(output, deterministic_json(post))
    return {"w_path": str(w_path), "r_path": str(r_path), "analysis_path": str(output),
            "w_status": post["projects"]["mseqwrite"]["curve"]["status"],
            "r_status": post["projects"]["mseqread"]["curve"]["status"],
            "randrw_status": post["projects"]["randrw"]["curve"]["status"],
            "randrw_write_status": post["projects"]["randrw.write"]["curve"]["status"],
            "stage_decision": post["stage_decision"]}


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="t04-6-mechanism-") as directory:
        cell = Path(directory) / "cells/W02"
        (cell / "sampler/iostat").mkdir(parents=True)
        (cell / "sampler").mkdir(exist_ok=True)
        (cell / "fio.txt").write_text("fio: run=180000msec\n")
        (cell / "fio-end-ns.txt").write_text(str(180_000_000_000))
        for epoch_s in range(20, 180, 10):
            if epoch_s >= 175:
                continue
            for host in HOSTS:
                path = cell / "sampler/iostat" / f"tikv-{host}-{epoch_s * 1_000_000_000}.txt"
                path.write_text("Device r/s %util\n" + "\n".join(
                    f"{dev} 1.0 95.0" for dev in DEVICES) + "\n")
        util = iostat_formal(cell)
        require_six_saturated_devices(util)
        assert util["observation_count"] == 96 and util["global_p50_pct"] == 95.0
        bad = dict(util)
        bad["device_p50_pct"] = dict(util["device_p50_pct"])
        bad["device_p50_pct"][f"{HOSTS[0]}/{DEVICES[0]}"] = 89.9
        try:
            require_six_saturated_devices(bad)
        except RepairError:
            pass
        else:
            raise AssertionError("sub-90 device was accepted")

        mechanism = {"formal_window": FORMAL_WINDOW, "component": "fixture",
                     "saturated": True, "util_p50_pct": 95.0,
                     "source_files": [relative_source(cell, util["sources"][0])]}
        validate_mechanism(cell, mechanism, True)
        mechanism["util_p50_pct"] = 89.9
        try:
            validate_mechanism(cell, mechanism, True)
        except RepairError:
            pass
        else:
            raise AssertionError("mechanism hard-evidence gate did not fail")
    print("T046_MECHANISM_SELFTEST_PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("repair")
    run.add_argument("root", type=Path)
    sub.add_parser("self-test")
    args = parser.parse_args()
    try:
        if args.command == "self-test":
            self_test()
        else:
            result = repair(args.root.resolve())
            print("T046_MECHANISM_REPAIR_PASS")
            print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (RepairError, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"T046_MECHANISM_REPAIR_FAIL\t{exc}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
