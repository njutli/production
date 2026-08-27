#!/usr/bin/env python3
"""Strict unique-epoch evidence validator for 03-20B-R2."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile

TIKV_IPS = ("10.20.1.150", "10.20.1.151", "10.20.1.152")
SAMPLERS = (
    "client-runtime", "client-host",
    *(f"tikv-metrics-{ip}" for ip in TIKV_IPS),
    *(f"tikv-device-{ip}" for ip in TIKV_IPS),
    *(f"tikv-host-{ip}" for ip in TIKV_IPS),
    "ceph", "pool",
)
NUMBER = re.compile(r"^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$")

TIKV_REQUIRED = {
    "process_cpu": re.compile(r"^process_cpu_seconds_total\s"),
    "compaction_flow": re.compile(r"^tikv_engine_compaction_flow_bytes\{"),
    "pending_compaction": re.compile(r"^tikv_engine_pending_compaction_bytes\{"),
    "wal_sync": re.compile(r"^tikv_engine_wal_file_sync_micro_seconds\{"),
    "storage_write": re.compile(r"^tikv_storage_engine_async_request_duration_seconds_(?:sum|count)\{type=\"write\"}"),
    "raft_append": re.compile(r"^tikv_raftstore_append_log_duration_seconds_(?:sum|count)\s"),
    "raft_commit": re.compile(r"^tikv_raftstore_commit_log_duration_seconds_(?:sum|count)\s"),
    "apply_wait": re.compile(r"^tikv_raftstore_apply_wait_time_duration_secs_(?:sum|count)\s"),
    "rocksdb_low_cpu": re.compile(r'^tikv_thread_cpu_seconds_total\{[^}]*name="rocksdb:low"'),
    "rocksdb_high_cpu": re.compile(r'^tikv_thread_cpu_seconds_total\{[^}]*name="rocksdb:high"'),
    "raftstore_cpu": re.compile(r'^tikv_thread_cpu_seconds_total\{[^}]*name="raftstore_'),
    "apply_cpu": re.compile(r'^tikv_thread_cpu_seconds_total\{[^}]*name="apply_'),
    "rocksdb_low_io": re.compile(r'^tikv_threads_io_bytes_total\{[^}]*name="rocksdb:low"'),
}
CLIENT_REQUIRED = (
    "juicefs_object_request_uploading",
    "juicefs_process_cpu_seconds_total",
    "juicefs_used_buffer_size_bytes",
)


def role_paths(config_path: Path) -> tuple[tuple[str, str], ...]:
    data = json.loads(config_path.read_text())
    kv = data.get("storage", {}).get("data-dir", "")
    wal = data.get("rocksdb", {}).get("wal-dir", "") or kv
    raft_engine = data.get("raft-engine", {})
    if raft_engine.get("enable"):
        raft = raft_engine.get("dir", "")
    else:
        raft = data.get("raftstore", {}).get("raftdb-path", "") or (f"{kv}/raft" if kv else "")
    result = (("kv", kv), ("raft", raft), ("wal", wal))
    if any(not path or not path.startswith("/") for _role, path in result):
        raise ValueError("active TiKV role path missing or not absolute")
    return result


def osd_key_paths(perf_path: Path) -> tuple[tuple[str, str], ...]:
    data = json.loads(perf_path.read_text())
    found: dict[str, list[str]] = {name: [] for name in ("compact_running", "compact_queue_len", "kv_sync_lat")}

    def walk(value: object, prefix: str = "") -> None:
        if not isinstance(value, dict):
            return
        for key, child in value.items():
            path = f"{prefix}.{key}" if prefix else key
            if key in ("compact_running", "compact_queue_len"):
                found[key].append(path)
            if key == "kv_sync_lat" and isinstance(child, dict) and "avgtime" in child:
                found["kv_sync_lat"].append(f"{path}.avgtime")
            walk(child, path)

    walk(data)
    if any(len(found[name]) != 1 for name in found):
        raise ValueError(f"OSD key paths are missing or ambiguous: {found}")
    return tuple((name, found[name][0]) for name in ("compact_running", "compact_queue_len", "kv_sync_lat"))


def is_number(value: str) -> bool:
    return bool(NUMBER.match(value))


def load_rows(path: Path, min_ts: int | None = None, max_ts: int | None = None) -> list[list[str]]:
    if not path.is_file():
        return []
    rows: list[list[str]] = []
    with path.open(errors="replace") as handle:
        for raw in handle:
            if not raw.strip() or raw.startswith("#"):
                continue
            parts = raw.rstrip("\n").split("\t")
            if parts and parts[0].isdigit():
                ts = int(parts[0])
                if min_ts is not None and ts < min_ts:
                    continue
                if max_ts is not None and ts >= max_ts:
                    continue
                rows.append(parts)
    return rows


def grouped(rows: list[list[str]], start: int, end: int) -> dict[int, list[list[str]]]:
    result: dict[int, list[list[str]]] = {}
    for row in rows:
        ts = int(row[0])
        if start <= ts < end:  # deliberately half-open
            result.setdefault(ts, []).append(row)
    return result


def max_gap(epochs: list[int]) -> int:
    return max((b - a for a, b in zip(epochs, epochs[1:])), default=0)


def monotonic(rows: list[list[str]], columns: tuple[int, ...]) -> bool:
    previous: list[float] | None = None
    for row in sorted(rows, key=lambda item: int(item[0])):
        current = [float(row[index]) for index in columns]
        if previous is not None and any(a > b for a, b in zip(previous, current)):
            return False
        previous = current
    return True


def device_leaves(out: Path) -> dict[str, set[str]]:
    path = out / "device/device-map.tsv"
    mapping = {ip: set() for ip in TIKV_IPS}
    roles = {ip: set() for ip in TIKV_IPS}
    for row in load_rows_without_epoch(path):
        if len(row) != 8:
            continue
        ip, role, _cfg, _target, _source, _fstype, _majmin, leaves = row
        if ip not in mapping or role not in {"kv", "raft", "wal"}:
            continue
        leaf_set = {os.path.basename(item) for item in leaves.split(",") if item}
        if leaf_set:
            mapping[ip].update(leaf_set)
            roles[ip].add(role)
    for ip in TIKV_IPS:
        if roles[ip] != {"kv", "raft", "wal"} or not mapping[ip]:
            mapping[ip].clear()
    return mapping


def load_rows_without_epoch(path: Path) -> list[list[str]]:
    if not path.is_file():
        return []
    return [line.rstrip("\n").split("\t") for line in path.open(errors="replace") if line.strip()]


def valid_device_epoch(rows: list[list[str]], leaves: set[str]) -> bool:
    seen: set[str] = set()
    for row in rows:
        if len(row) != 8 or not all(is_number(value) for value in row[2:]):
            return False
        values = [float(value) for value in row[2:]]
        # Short iostat intervals can report a small amount above 100%; large
        # excursions still indicate a schema/parse error.
        if any(value < 0 for value in values) or values[-1] > 105.0:
            return False
        seen.add(os.path.basename(row[1]))
    return leaves.issubset(seen)


def valid_host_rows(rows: list[list[str]]) -> bool:
    if not rows or any(len(row) != 20 or not all(is_number(value) for value in row[1:]) for row in rows):
        return False
    if any(float(row[index]) < 0 for row in rows for index in range(11, 19)):
        return False
    starts = {row[16] for row in rows}
    return len(starts) == 1 and monotonic(rows, (11, 12, 13, 14, 15, 17, 18))


def valid_client_host_rows(rows: list[list[str]]) -> bool:
    return bool(rows) and all(len(row) == 12 and all(is_number(value) for value in row[1:]) for row in rows)


def valid_metrics_epoch(rows: list[list[str]]) -> bool:
    payload = [row[2] for row in rows if len(row) == 3 and not row[2].startswith("#")]
    return bool(payload) and all(any(pattern.search(line) for line in payload) for pattern in TIKV_REQUIRED.values())


def valid_client_epoch(rows: list[list[str]]) -> bool:
    payload = [row[1] for row in rows if len(row) == 2 and not row[1].startswith("#")]
    return all(any(line.startswith(name) for line in payload) for name in CLIENT_REQUIRED)


def registry_ok(out: Path) -> tuple[bool, str]:
    pid_paths = {path.stem: path for path in (out / "samplers").glob("*.pid")}
    pgid_paths = {path.stem: path for path in (out / "samplers").glob("*.pgid")}
    pids = set(pid_paths)
    pgids = set(pgid_paths)
    expected = set(SAMPLERS)
    values_ok = all(
        pid_paths[name].read_text().strip().isdigit()
        and pid_paths[name].read_text().strip() == pgid_paths[name].read_text().strip()
        for name in expected
    ) if pids == expected and pgids == expected else False
    ok = pids == expected and pgids == expected and values_ok
    return ok, f"pid={len(pids)}/13 pgid={len(pgids)}/13"


def error_files_ok(out: Path) -> tuple[bool, int]:
    paths = list((out / "samplers").glob("*.errors.tsv"))
    names = {path.name.removesuffix(".errors.tsv") for path in paths}
    paths.extend((out / "samplers").glob("*.launcher.stderr"))
    nonempty = sum(1 for path in paths if path.stat().st_size)
    return nonempty == 0 and names == set(SAMPLERS), nonempty


def emit(rows: list[str], name: str, got: int | str, expected: int | str, gap: int | str, ok: bool, detail: str = "") -> None:
    rows.append(f"{name}\t{got}\t{expected}\t{gap}\t{'PASS' if ok else 'FAIL'}\t{detail}")


def validate(out: Path, start: int, preflight: bool) -> int:
    windows = (
        [("preflight_120s", start, start + 120)] if preflight else
        [("W1", start + 15, start + 55), ("W2", start + 55, start + 95),
         ("W3", start + 95, start + 135), ("W4", start + 135, start + 175)]
    )
    result: list[str] = ["scope\tstream\tvalid_epochs\texpected\tmax_gap\tstatus\tdetail"]
    passed = True
    leaves = device_leaves(out)
    range_begin = min(begin for _scope, begin, _end in windows)
    range_end = max(end for _scope, _begin, end in windows)
    device_cache = {ip: load_rows(out / f"samplers/tikv-device-{ip}.tsv", range_begin, range_end) for ip in TIKV_IPS}
    host_cache = {ip: load_rows(out / f"samplers/tikv-host-{ip}.tsv", range_begin, range_end) for ip in TIKV_IPS}
    metric_cache = {ip: load_rows(out / f"samplers/tikv-metrics-{ip}.tsv", range_begin, range_end) for ip in TIKV_IPS}
    client_cache = load_rows(out / "samplers/client-runtime.tsv", range_begin, range_end)
    client_host_cache = load_rows(out / "samplers/client-host.tsv", range_begin, range_end)
    pool_cache = load_rows(out / "samplers/pool.tsv", range_begin, range_end)
    ceph_cache = load_rows(out / "samplers/ceph.tsv", range_begin, range_end)

    reg_ok, reg_detail = registry_ok(out)
    emit(result, "registry", reg_detail, "13/13", "-", reg_ok)
    passed &= reg_ok

    for scope, begin, end in windows:
        duration = end - begin
        for ip in TIKV_IPS:
            device_groups = grouped(device_cache[ip], begin, end)
            good_device = sorted(ts for ts, rows in device_groups.items() if leaves[ip] and valid_device_epoch(rows, leaves[ip]))
            minimum = math.ceil(duration * 0.95)
            gap = max_gap(good_device)
            ok = len(good_device) >= minimum and gap <= 2
            emit(result, f"{scope}/tikv-device-{ip}", len(good_device), duration, gap, ok, f"leaves={','.join(sorted(leaves[ip])) or 'NONE'}")
            passed &= ok

            host_groups = grouped(host_cache[ip], begin, end)
            good_host = sorted(ts for ts, rows in host_groups.items() if len(rows) == 1 and valid_host_rows(rows))
            flat_host = [host_groups[ts][0] for ts in good_host]
            gap = max_gap(good_host)
            ok = len(good_host) >= minimum and gap <= 2 and valid_host_rows(flat_host)
            emit(result, f"{scope}/tikv-host-{ip}", len(good_host), duration, gap, ok)
            passed &= ok

            metric_groups = grouped(metric_cache[ip], begin, end)
            good_metrics = sorted(ts for ts, rows in metric_groups.items() if valid_metrics_epoch(rows))
            expected = duration // 5
            minimum_metrics = math.ceil(expected * 0.90)
            gap = max_gap(good_metrics)
            ok = len(good_metrics) >= minimum_metrics and gap <= 6
            emit(result, f"{scope}/tikv-metrics-{ip}", len(good_metrics), expected, gap, ok, f"minimum={minimum_metrics}")
            passed &= ok

        client_groups = grouped(client_cache, begin, end)
        good_client = sorted(ts for ts, rows in client_groups.items() if valid_client_epoch(rows))
        minimum = math.ceil(duration * 0.95)
        gap = max_gap(good_client)
        ok = len(good_client) >= minimum and gap <= 2
        emit(result, f"{scope}/client-runtime", len(good_client), duration, gap, ok)
        passed &= ok

        client_host_groups = grouped(client_host_cache, begin, end)
        good_client_host = sorted(ts for ts, rows in client_host_groups.items() if len(rows) == 1 and valid_client_host_rows(rows))
        gap = max_gap(good_client_host)
        ok = len(good_client_host) >= minimum and gap <= 2
        emit(result, f"{scope}/client-host", len(good_client_host), duration, gap, ok)
        passed &= ok

        pool_groups = grouped(pool_cache, begin, end)
        good_pool = sorted(ts for ts, rows in pool_groups.items() if len(rows) == 1 and len(rows[0]) == 4 and all(item.isdigit() for item in rows[0]) and int(rows[0][1]) <= 8_000_000)
        pool_expected = max(1, duration // 15)
        ok = len(good_pool) >= math.ceil(pool_expected * 0.80)
        emit(result, f"{scope}/pool", len(good_pool), pool_expected, "-", ok)
        passed &= ok

        ceph_groups = grouped(ceph_cache, begin, end)
        good_ceph = sorted(ts for ts, rows in ceph_groups.items() if len(rows) == 1 and len(rows[0]) >= 3 and rows[0][1] == "HEALTH_OK" and "active+clean" in rows[0][2])
        ceph_expected = max(1, duration // 30)
        ok = len(good_ceph) >= ceph_expected
        emit(result, f"{scope}/ceph", len(good_ceph), ceph_expected, "-", ok)
        passed &= ok

    errors_ok, nonempty = error_files_ok(out)
    emit(result, "errors", nonempty, 0, "-", errors_ok)
    passed &= errors_ok
    stop_ok = not (out / "STOP.txt").exists()
    emit(result, "stop-file", int(not stop_ok), 0, "-", stop_ok)
    passed &= stop_ok

    destination = out / ("preflight/coverage.tsv" if preflight else "coverage.tsv")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(result) + "\n")
    with (out / "coverage.log").open("a") as handle:
        handle.write(f"=== {'preflight' if preflight else 'formal'} ===\n")
        handle.write("\n".join(result) + "\n")
    print("\n".join(result))
    print(f"OVERALL\t{'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


def fixture_metric_lines(ts: int, ip: str) -> list[str]:
    samples = (
        "process_cpu_seconds_total 1",
        'tikv_engine_compaction_flow_bytes{db="kv",type="bytes_written"} 1',
        'tikv_engine_pending_compaction_bytes{cf="default",db="kv"} 0',
        'tikv_engine_wal_file_sync_micro_seconds{db="kv",type="wal_file_sync_average"} 1',
        'tikv_storage_engine_async_request_duration_seconds_sum{type="write"} 1',
        'tikv_storage_engine_async_request_duration_seconds_count{type="write"} 1',
        "tikv_raftstore_append_log_duration_seconds_sum 1",
        "tikv_raftstore_append_log_duration_seconds_count 1",
        "tikv_raftstore_commit_log_duration_seconds_sum 1",
        "tikv_raftstore_commit_log_duration_seconds_count 1",
        "tikv_raftstore_apply_wait_time_duration_secs_sum 1",
        "tikv_raftstore_apply_wait_time_duration_secs_count 1",
        'tikv_thread_cpu_seconds_total{name="rocksdb:low",tid="1"} 1',
        'tikv_thread_cpu_seconds_total{name="rocksdb:high",tid="2"} 1',
        'tikv_thread_cpu_seconds_total{name="raftstore_1_0",tid="3"} 1',
        'tikv_thread_cpu_seconds_total{name="apply_0",tid="4"} 1',
        'tikv_threads_io_bytes_total{io="write",name="rocksdb:low",tid="1"} 1',
    )
    return [f"{ts}\t{ip}\t{sample}" for sample in samples]


def self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="t61-validator-") as temp:
        out = Path(temp)
        (out / "samplers").mkdir()
        (out / "device").mkdir()
        start = 1_000
        mapping = []
        for ip in TIKV_IPS:
            for role in ("kv", "raft", "wal"):
                mapping.append(f"{ip}\t{role}\t/data/{role}\t/data\t/dev/nvme1n1\text4\t259:5\t/dev/nvme1n1")
        (out / "device/device-map.tsv").write_text("\n".join(mapping) + "\n")

        for name in SAMPLERS:
            (out / f"samplers/{name}.pid").write_text("123\n")
            (out / f"samplers/{name}.pgid").write_text("123\n")
            (out / f"samplers/{name}.errors.tsv").write_text("")

        seconds = range(start, start + 180)
        for ip in TIKV_IPS:
            (out / f"samplers/tikv-device-{ip}.tsv").write_text("".join(f"{ts}\tnvme1n1\t0\t1\t0.1\t1.0\t2.0\t99.0\n" for ts in seconds))
            (out / f"samplers/tikv-host-{ip}.tsv").write_text("".join(f"{ts}\t1\t0\t1\t100\t0\t0\t0\t0\t0\t0\t{ts}\t{ts}\t{ts}\t{ts}\t{ts}\t77\t{ts}\t{ts}\t1.0\n" for ts in seconds))
            metrics = [line for ts in range(start, start + 180, 5) for line in fixture_metric_lines(ts, ip)]
            (out / f"samplers/tikv-metrics-{ip}.tsv").write_text("\n".join(metrics) + "\n")
        client = []
        for ts in seconds:
            client.extend((f"{ts}\tjuicefs_object_request_uploading 1", f"{ts}\tjuicefs_process_cpu_seconds_total {ts}", f"{ts}\tjuicefs_used_buffer_size_bytes 1"))
        (out / "samplers/client-runtime.tsv").write_text("\n".join(client) + "\n")
        (out / "samplers/client-host.tsv").write_text("".join(f"{ts}\t1\t0\t1\t100\t0\t0\t0\t0\t0\t0\t1000\n" for ts in seconds))
        (out / "samplers/pool.tsv").write_text("".join(f"{ts}\t2434672\t1\t1\n" for ts in range(start, start + 180, 15)))
        (out / "samplers/ceph.tsv").write_text("".join(f"{ts}\tHEALTH_OK\t33 pgs: 33 active+clean\n" for ts in range(start, start + 180, 30)))

        with contextlib.redirect_stdout(io.StringIO()):
            assert validate(out, start, preflight=False) == 0

        target = out / "samplers/tikv-metrics-10.20.1.151.tsv"
        original = target.read_text()
        target.write_text("\n".join(line for line in original.splitlines() if not line.startswith("1100\t")) + "\n")
        with contextlib.redirect_stdout(io.StringIO()):
            assert validate(out, start, preflight=False) == 1  # 7/8 in W3 must fail
        target.write_text(original)

        host = out / "samplers/tikv-host-10.20.1.150.tsv"
        bad_rows = []
        for line in host.read_text().splitlines():
            fields = line.split("\t")
            fields[11] = "-1"
            bad_rows.append("\t".join(fields))
        host.write_text("\n".join(bad_rows) + "\n")
        with contextlib.redirect_stdout(io.StringIO()):
            assert validate(out, start, preflight=False) == 1

        config = out / "tikv-config.json"
        config.write_text(json.dumps({
            "storage": {"data-dir": "/data/kv"},
            "rocksdb": {"wal-dir": "/data/wal"},
            "raft-engine": {"enable": True, "dir": "/data/raft-engine"},
            "raftstore": {"raftdb-path": "/wrong/inactive-raftdb"},
        }))
        assert dict(role_paths(config)) == {"kv": "/data/kv", "raft": "/data/raft-engine", "wal": "/data/wal"}
        config.write_text(json.dumps({
            "storage": {"data-dir": "/data/kv"},
            "rocksdb": {"wal-dir": ""},
            "raft-engine": {"enable": False},
            "raftstore": {"raftdb-path": "/data/raftdb"},
        }))
        assert dict(role_paths(config)) == {"kv": "/data/kv", "raft": "/data/raftdb", "wal": "/data/kv"}
        perf = out / "osd-perf.json"
        perf.write_text(json.dumps({"rocksdb": {"compact_running": 0, "compact_queue_len": 0}, "bluestore": {"kv_sync_lat": {"avgtime": 0.001}}}))
        assert dict(osd_key_paths(perf)) == {
            "compact_running": "rocksdb.compact_running",
            "compact_queue_len": "rocksdb.compact_queue_len",
            "kv_sync_lat": "bluestore.kv_sync_lat.avgtime",
        }

    print("t61 validator self-test: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--preflight", action="store_true")
    group.add_argument("--formal", action="store_true")
    group.add_argument("--self-test", action="store_true")
    group.add_argument("--role-paths", metavar="CONFIG")
    group.add_argument("--osd-keys", metavar="PERF_JSON")
    parser.add_argument("dir", nargs="?")
    parser.add_argument("start_epoch", nargs="?", type=int)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.role_paths:
        for role, path in role_paths(Path(args.role_paths)):
            print(f"{role}\t{path}")
        return 0
    if args.osd_keys:
        for name, path in osd_key_paths(Path(args.osd_keys)):
            print(f"{name}\t{path}")
        return 0
    if args.dir is None or args.start_epoch is None:
        parser.error("--preflight/--formal require DIR START_EPOCH")
    return validate(Path(args.dir), args.start_epoch, args.preflight)


if __name__ == "__main__":
    sys.exit(main())
