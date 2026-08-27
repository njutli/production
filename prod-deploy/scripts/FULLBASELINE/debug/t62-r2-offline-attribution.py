#!/usr/bin/env python3
"""Offline, read-only attribution for 03-20B-R2 evidence.

The R2 wrapper recorded ``fio_start`` immediately after forking fio.  With 256
processes, fio spent about one minute starting workers before its timed I/O
interval.  This analyzer derives the actual I/O epoch from fio's own completion
timestamp and runtime, then aligns device/host/TiKV/client samples to that epoch.

It never connects to the test environment and never modifies the evidence tree.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import glob
import hashlib
import math
import os
from pathlib import Path
import re
import statistics
import sys
from typing import Iterable


WINDOWS = (("W1", 15, 55), ("W2", 55, 95), ("W3", 95, 135), ("W4", 135, 175))
TARGET_MIB_S = 6250.0
NODES = ("10.20.1.150", "10.20.1.151", "10.20.1.152")

LATENCY_PAIRS = (
    ("storage-write", "tikv_storage_engine_async_request_duration_seconds", '{type="write"}'),
    ("raft-append", "tikv_raftstore_append_log_duration_seconds", ""),
    ("raft-commit", "tikv_raftstore_commit_log_duration_seconds", ""),
    ("apply-wait", "tikv_raftstore_apply_wait_time_duration_secs", ""),
    ("scheduler-prewrite", "tikv_scheduler_command_duration_seconds", '{type="prewrite"}'),
    ("scheduler-commit", "tikv_scheduler_command_duration_seconds", '{type="commit"}'),
)


def fail(message: str) -> "None":
    raise SystemExit(f"ERROR: {message}")


def mean(values: Iterable[float]) -> float:
    data = list(values)
    return statistics.fmean(data) if data else math.nan


def pct_ratio(numerator: float, denominator: float) -> float:
    return numerator / denominator * 100.0 if denominator else math.nan


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path, help="extracted R2 evidence directory")
    parser.add_argument(
        "--io-start",
        type=int,
        help="override derived actual-I/O epoch; intended only for sensitivity checks",
    )
    return parser.parse_args()


def phase_epochs(root: Path) -> tuple[int, int]:
    registered = None
    ended = None
    for line in (root / "phase.tsv").read_text().splitlines():
        fields = line.split("\t")
        if len(fields) >= 3 and fields[1] == "D-B256" and fields[2].startswith("fio_start"):
            registered = int(fields[0])
        if len(fields) >= 3 and fields[1] == "D-B256" and fields[2].startswith("fio_end"):
            ended = int(fields[0])
    if registered is None or ended is None:
        fail("phase.tsv lacks fio_start/fio_end")
    return registered, ended


def derive_io_start(root: Path, registered: int) -> tuple[int, float, int]:
    text = (root / "arm/fio.stdout").read_text(errors="replace")
    run_match = re.search(r"run=(\d+)-(\d+)msec", text)
    end_match = re.search(
        r"pid=\d+:\s+(?P<stamp>[A-Z][a-z]{2} [A-Z][a-z]{2} +\d+ \d\d:\d\d:\d\d \d{4})",
        text,
    )
    wrapper = (root / "wrapper.log").read_text(errors="replace")
    zone_match = re.search(r"[+-]\d{4}", wrapper)
    if not run_match or not end_match or not zone_match:
        fail("cannot derive I/O start from fio runtime/end timestamp/wrapper timezone")
    runtime_s = max(int(run_match.group(1)), int(run_match.group(2))) / 1000.0
    zone_text = zone_match.group(0)
    zone = dt.timezone(
        dt.timedelta(
            hours=int(zone_text[1:3]) * (1 if zone_text[0] == "+" else -1),
            minutes=int(zone_text[3:5]) * (1 if zone_text[0] == "+" else -1),
        )
    )
    finished = dt.datetime.strptime(end_match.group("stamp"), "%a %b %d %H:%M:%S %Y").replace(tzinfo=zone)
    io_start_float = finished.timestamp() - runtime_s
    io_start = round(io_start_float)
    return io_start, runtime_s, io_start - registered


def verify_manifest(root: Path) -> tuple[int, int, list[str]]:
    manifest = root / "MANIFEST.md5"
    if not manifest.is_file():
        return 0, 0, ["MANIFEST.md5 missing"]
    total = 0
    passed = 0
    errors: list[str] = []
    for raw in manifest.read_text(errors="replace").splitlines():
        match = re.match(r"^([0-9a-fA-F]{32})\s+[ *](.+)$", raw)
        if not match:
            errors.append(f"malformed manifest line: {raw[:80]}")
            continue
        total += 1
        expected, name = match.groups()
        name = name.removeprefix("./")
        path = root / name
        if not path.is_file():
            errors.append(f"missing: {name}")
            continue
        digest = hashlib.md5(path.read_bytes()).hexdigest()
        if digest == expected.lower():
            passed += 1
        else:
            errors.append(f"md5 mismatch: {name}")
    return passed, total, errors


def required_post_evidence(root: Path) -> list[str]:
    required = (
        "skill-check-post.txt",
        "fingerprint/mount-post.txt",
        "fingerprint/remote-sampler-post.tsv",
    )
    return [name for name in required if not (root / name).is_file()]


def bw_seconds(root: Path) -> dict[int, float]:
    paths = sorted(glob.glob(str(root / "arm/bw/D-B256_bw.*.log")))
    if len(paths) != 256:
        fail(f"expected 256 BW logs, found {len(paths)}")
    result: dict[int, float] = collections.defaultdict(float)
    for path in paths:
        with open(path, encoding="utf-8") as stream:
            for line in stream:
                fields = [item.strip() for item in line.split(",")]
                if len(fields) < 2:
                    continue
                second = int(float(fields[0])) // 1000
                result[second] += float(fields[1]) / 1024.0
    return dict(result)


def parse_device(path: Path) -> dict[int, tuple[float, float, float, float]]:
    result = {}
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) != 8:
            fail(f"bad device schema in {path}: {len(fields)} fields")
        epoch = int(fields[0])
        # wkB/s, w_await, aqu-sz, util
        result[epoch] = tuple(map(float, (fields[3], fields[5], fields[6], fields[7])))
    return result


def parse_host(path: Path) -> dict[int, tuple[float, ...]]:
    result = {}
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) != 20:
            fail(f"bad host schema in {path}: {len(fields)} fields")
        result[int(fields[0])] = tuple(map(float, fields[1:]))
    return result


def valid_client_host_epochs(path: Path) -> list[int]:
    rows: dict[int, list[list[str]]] = collections.defaultdict(list)
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            fields = line.rstrip().split("\t")
            if fields and fields[0].isdigit():
                rows[int(fields[0])].append(fields)
    return sorted(
        epoch
        for epoch, grouped_rows in rows.items()
        if len(grouped_rows) == 1
        and len(grouped_rows[0]) == 12
        and all(re.fullmatch(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", item) for item in grouped_rows[0][1:])
    )


def metric_key(sample: str) -> tuple[str, float]:
    name, value = sample.rsplit(" ", 1)
    return name, float(value)


def wanted_metric(name: str) -> bool:
    if name == "process_cpu_seconds_total":
        return True
    if name == 'tikv_engine_compaction_flow_bytes{db="kv",type="bytes_written"}':
        return True
    if name == 'tikv_engine_stall_micro_seconds{db="kv"}':
        return True
    if name.startswith("tikv_thread_cpu_seconds_total{") and 'name="rocksdb:low"' in name:
        return True
    if name.startswith("tikv_threads_io_bytes_total{") and 'name="rocksdb:low"' in name:
        return True
    for _, stem, labels in LATENCY_PAIRS:
        if name in (f"{stem}_sum{labels}", f"{stem}_count{labels}"):
            return True
    return False


def parse_tikv(path: Path) -> dict[int, dict[str, float]]:
    result: dict[int, dict[str, float]] = collections.defaultdict(dict)
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            fields = line.rstrip().split("\t", 2)
            if len(fields) != 3:
                continue
            name, value = metric_key(fields[2])
            if wanted_metric(name):
                result[int(fields[0])][name] = value
    return dict(result)


def parse_client(path: Path) -> dict[int, dict[str, float]]:
    wanted = {
        "juicefs_object_request_uploading",
        "juicefs_process_cpu_seconds_total",
        "juicefs_used_buffer_size_bytes",
        "juicefs_staging_blocks",
    }
    result: dict[int, dict[str, float]] = collections.defaultdict(dict)
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            fields = line.rstrip().split("\t", 1)
            if len(fields) != 2:
                continue
            name, value = metric_key(fields[1])
            bare = name.split("{", 1)[0]
            if bare in wanted:
                result[int(fields[0])][bare] = value
    return dict(result)


def selected_epochs(data: dict[int, object], start: int, lo: int, hi: int) -> list[int]:
    return sorted(epoch for epoch in data if start + lo <= epoch < start + hi)


def counter_delta(data: dict[int, dict[str, float]], key: str, epochs: list[int]) -> tuple[float, float]:
    present = [epoch for epoch in epochs if key in data[epoch]]
    if len(present) < 2:
        return math.nan, math.nan
    first, last = present[0], present[-1]
    return data[last][key] - data[first][key], float(last - first)


def host_counter_rate(data: dict[int, tuple[float, ...]], epochs: list[int], indexes: tuple[int, ...], scale: float) -> float:
    if len(epochs) < 2:
        return math.nan
    first, last = epochs[0], epochs[-1]
    delta = sum(data[last][index] - data[first][index] for index in indexes)
    return delta / (last - first) / scale


def format_float(value: float, digits: int = 2) -> str:
    return "NA" if math.isnan(value) else f"{value:.{digits}f}"


def print_table(headers: tuple[str, ...], rows: Iterable[tuple[object, ...]]) -> None:
    print("| " + " | ".join(headers) + " |")
    print("|" + "|".join("---" for _ in headers) + "|")
    for row in rows:
        print("| " + " | ".join(str(item) for item in row) + " |")


def main() -> int:
    args = parse_args()
    root = args.evidence.resolve()
    if not root.is_dir():
        fail(f"not a directory: {root}")

    registered, phase_end = phase_epochs(root)
    derived_start, runtime_s, launch_delay = derive_io_start(root, registered)
    io_start = args.io_start if args.io_start is not None else derived_start
    manifest_pass, manifest_total, manifest_errors = verify_manifest(root)
    missing_post = required_post_evidence(root)

    bw = bw_seconds(root)
    devices = {node: parse_device(root / f"samplers/tikv-device-{node}.tsv") for node in NODES}
    hosts = {node: parse_host(root / f"samplers/tikv-host-{node}.tsv") for node in NODES}
    tikv = {node: parse_tikv(root / f"samplers/tikv-metrics-{node}.tsv") for node in NODES}
    client = parse_client(root / "samplers/client-runtime.tsv")
    client_host_epochs = valid_client_host_epochs(root / "samplers/client-host.tsv")

    print("# 03-20B-R2 offline attribution")
    print()
    print(f"- evidence: `{root}`")
    print(f"- registered fio_start: `{registered}`")
    print(f"- derived actual-I/O start: `{derived_start}` (launch offset `{launch_delay}s`)")
    print(f"- selected actual-I/O start: `{io_start}`")
    print(f"- fio runtime: `{runtime_s:.3f}s`; phase end: `{phase_end}`")
    print(f"- manifest: `{manifest_pass}/{manifest_total}`; errors: `{len(manifest_errors)}`")
    print(f"- missing automatic post evidence: `{','.join(missing_post) if missing_post else 'NONE'}`")
    print()

    print("## Bandwidth")
    print()
    bw_rows = []
    for label, lo, hi in WINDOWS + (("formal", 15, 175),):
        values = [bw[second] for second in range(lo, hi) if second in bw]
        avg = mean(values)
        cv = pct_ratio(statistics.pstdev(values), avg) if values else math.nan
        bw_rows.append((label, len(values), format_float(avg), format_float(cv), format_float(pct_ratio(avg, TARGET_MIB_S))))
    print_table(("window", "seconds", "MiB/s", "CV%", "target%"), bw_rows)
    w1 = mean(bw[second] for second in range(15, 55) if second in bw)
    w4 = mean(bw[second] for second in range(135, 175) if second in bw)
    print(f"\nW4/W1 = `{w4 / w1:.3f}`")

    print("\n## Corrected device windows")
    print()
    device_rows = []
    device_summary: dict[str, dict[str, tuple[float, float, float, float]]] = collections.defaultdict(dict)
    for node in NODES:
        for label, lo, hi in WINDOWS:
            epochs = selected_epochs(devices[node], io_start, lo, hi)
            columns = tuple(mean(devices[node][epoch][index] for epoch in epochs) for index in range(4))
            device_summary[node][label] = columns
        for label, _, _ in WINDOWS:
            wk, await_ms, queue, util = device_summary[node][label]
            device_rows.append((node, label, format_float(wk / 1024), format_float(await_ms), format_float(queue), format_float(util)))
    print_table(("node", "window", "write MiB/s", "w_await ms", "aqu-sz", "util%"), device_rows)

    print("\n## Corrected TiKV windows")
    print()
    tikv_rows = []
    tikv_summary: dict[str, dict[str, tuple[float, float, float, float, float, float]]] = collections.defaultdict(dict)
    comp_key = 'tikv_engine_compaction_flow_bytes{db="kv",type="bytes_written"}'
    stall_key = 'tikv_engine_stall_micro_seconds{db="kv"}'
    for node in NODES:
        for label, lo, hi in WINDOWS:
            epochs = selected_epochs(tikv[node], io_start, lo, hi)
            comp_delta, comp_dt = counter_delta(tikv[node], comp_key, epochs)
            proc_delta, proc_dt = counter_delta(tikv[node], "process_cpu_seconds_total", epochs)
            stall_delta, stall_dt = counter_delta(tikv[node], stall_key, epochs)
            low_keys = sorted({key for epoch in epochs for key in tikv[node][epoch] if key.startswith("tikv_thread_cpu_seconds_total{")})
            low_cpu = 0.0
            low_count = 0
            for key in low_keys:
                delta, seconds = counter_delta(tikv[node], key, epochs)
                if not math.isnan(delta) and seconds > 0:
                    low_cpu += delta / seconds * 100.0
                    low_count += 1
            low_avg = low_cpu / low_count if low_count else math.nan
            low_io = {}
            for direction in ("read", "write"):
                io_keys = sorted(
                    {
                        key
                        for epoch in epochs
                        for key in tikv[node][epoch]
                        if key.startswith("tikv_threads_io_bytes_total{") and f'io="{direction}"' in key
                    }
                )
                io_rate = 0.0
                io_count = 0
                for key in io_keys:
                    delta, seconds = counter_delta(tikv[node], key, epochs)
                    if not math.isnan(delta) and seconds > 0:
                        io_rate += delta / seconds / 1048576
                        io_count += 1
                low_io[direction] = io_rate if io_count else math.nan
            values = (
                comp_delta / comp_dt / 1048576 if comp_dt > 0 else math.nan,
                proc_delta / proc_dt if proc_dt > 0 else math.nan,
                low_avg,
                low_io["read"],
                low_io["write"],
                pct_ratio(stall_delta / 1e6, stall_dt) if stall_dt > 0 else math.nan,
            )
            tikv_summary[node][label] = values
        for label in ("W1", "W4"):
            engine_write, proc_cpu, low_cpu, low_read, low_write, stall = tikv_summary[node][label]
            tikv_rows.append(
                (
                    node,
                    label,
                    format_float(engine_write),
                    format_float(low_read),
                    format_float(low_write),
                    format_float(proc_cpu),
                    format_float(low_cpu),
                    format_float(stall, 4),
                )
            )
    print_table(
        (
            "node",
            "window",
            "engine bytes-written MiB/s",
            "rocksdb:low read MiB/s",
            "rocksdb:low write MiB/s",
            "process CPU cores",
            "rocksdb:low avg CPU%",
            "stall%",
        ),
        tikv_rows,
    )

    print("\n## Corrected foreground latency")
    print()
    latency_rows = []
    for display, stem, labels in LATENCY_PAIRS:
        values = {}
        rates = {}
        for window in ("W1", "W4"):
            _, lo, hi = next(item for item in WINDOWS if item[0] == window)
            total_sum = 0.0
            total_count = 0.0
            total_seconds = []
            for node in NODES:
                epochs = selected_epochs(tikv[node], io_start, lo, hi)
                sum_delta, _ = counter_delta(tikv[node], f"{stem}_sum{labels}", epochs)
                count_delta, count_seconds = counter_delta(tikv[node], f"{stem}_count{labels}", epochs)
                if not math.isnan(sum_delta) and not math.isnan(count_delta):
                    total_sum += sum_delta
                    total_count += count_delta
                    total_seconds.append(count_seconds)
            values[window] = total_sum / total_count * 1000.0 if total_count else math.nan
            rates[window] = total_count / mean(total_seconds) if total_seconds else math.nan
        ratio = values["W4"] / values["W1"] if values["W1"] else math.nan
        latency_rows.append(
            (
                display,
                format_float(values["W1"], 3),
                format_float(values["W4"], 3),
                format_float(ratio),
                format_float(rates["W1"]),
                format_float(rates["W4"]),
            )
        )
    print_table(("metric", "W1 ms", "W4 ms", "W4/W1", "W1 count/s", "W4 count/s"), latency_rows)

    print("\n## Corrected client supply")
    print()
    client_rows = []
    for label, _, _ in WINDOWS:
        _, lo, hi = next(item for item in WINDOWS if item[0] == label)
        epochs = selected_epochs(client, io_start, lo, hi)
        uploading = mean(client[epoch].get("juicefs_object_request_uploading", math.nan) for epoch in epochs)
        buffer_mib = mean(client[epoch].get("juicefs_used_buffer_size_bytes", math.nan) / 1048576 for epoch in epochs)
        staging = mean(client[epoch].get("juicefs_staging_blocks", math.nan) for epoch in epochs)
        cpu_epochs = [epoch for epoch in epochs if "juicefs_process_cpu_seconds_total" in client[epoch]]
        cpu_delta = (
            client[cpu_epochs[-1]]["juicefs_process_cpu_seconds_total"]
            - client[cpu_epochs[0]]["juicefs_process_cpu_seconds_total"]
        )
        cpu = cpu_delta / (cpu_epochs[-1] - cpu_epochs[0]) if len(cpu_epochs) >= 2 else math.nan
        client_rows.append((label, format_float(uploading), format_float(buffer_mib), format_float(staging), format_float(cpu)))
    print_table(("window", "uploading", "buffer MiB", "staging blocks", "client CPU cores"), client_rows)

    print("\n## Corrected host constraints")
    print()
    host_rows = []
    for node in NODES:
        for label in ("W1", "W4"):
            _, lo, hi = next(item for item in WINDOWS if item[0] == label)
            epochs = selected_epochs(hosts[node], io_start, lo, hi)
            # tuple indexes: cpu[0:10], io_some=10, io_full=11, cpu_some=12,
            # pid_utime=13, pid_stime=14, pid_start=15, read=16, write=17, load=18.
            pid_cpu = host_counter_rate(hosts[node], epochs, (13, 14), 100.0)
            io_some = host_counter_rate(hosts[node], epochs, (10,), 1e6) * 100.0
            io_full = host_counter_rate(hosts[node], epochs, (11,), 1e6) * 100.0
            host_rows.append((node, label, format_float(pid_cpu), format_float(io_some), format_float(io_full)))
    print_table(("node", "window", "TiKV CPU cores", "IO PSI some%", "IO PSI full%"), host_rows)

    print("\n## Artifact gate")
    artifact_ok = manifest_total > 0 and manifest_pass == manifest_total and not manifest_errors
    post_ok = not missing_post
    w4_client_host = [epoch for epoch in client_host_epochs if io_start + 135 <= epoch < io_start + 175]
    w4_client_host_gap = max((b - a for a, b in zip(w4_client_host, w4_client_host[1:])), default=math.inf)
    w4_client_host_ok = len(w4_client_host) >= 38 and w4_client_host_gap <= 2
    print(f"- internal manifest: `{'PASS' if artifact_ok else 'FAIL'}`")
    print(f"- automatic cleanup/post evidence: `{'PASS' if post_ok else 'FAIL'}`")
    print(
        "- corrected W4 client-host coverage: "
        f"`{len(w4_client_host)}/40 max_gap={w4_client_host_gap}s "
        f"{'PASS' if w4_client_host_ok else 'FAIL'}`"
    )
    print("- execution-history single-attempt gate: `NOT IN ARCHIVE; reconcile against execution report/attempt records`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
