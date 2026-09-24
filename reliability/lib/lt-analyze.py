#!/usr/bin/env python3
"""Analyze LT hourly fio windows and safety samples without touching the cluster."""
from __future__ import annotations

import csv
import json
import pathlib
import statistics
import sys
import tempfile


def fail(message: str) -> None:
    raise SystemExit(f"LT_ANALYZE_FAIL\t{message}")


def percentile(job: dict, direction: str, value: str) -> float:
    section = job.get(direction) or {}
    # The end-to-end latency seen by fio is lat=slat+clat.  On JuiceFS/FUSE,
    # submission may block for much longer than completion, so preferring clat
    # can hide the dominant wait by orders of magnitude.
    for name, scale in (("lat_ns", 1 / 1000), ("lat_us", 1),
                        ("clat_ns", 1 / 1000), ("clat_us", 1)):
        table = (section.get(name) or {}).get("percentile") or {}
        raw = table.get(value)
        if isinstance(raw, (int, float)):
            return float(raw) * scale
    return 0.0


def latency_stat(job: dict, direction: str, field: str) -> float:
    """Return a fio latency statistic in microseconds."""
    section = job.get(direction) or {}
    for name, scale in (("lat_ns", 1 / 1000), ("lat_us", 1),
                        ("clat_ns", 1 / 1000), ("clat_us", 1)):
        raw = (section.get(name) or {}).get(field)
        if isinstance(raw, (int, float)):
            return float(raw) * scale
    return 0.0


def bandwidth_log_gap(window: pathlib.Path) -> tuple[int, float]:
    values: dict[int, float] = {}
    for path in (window / "bw").glob("*.log"):
        with path.open(errors="replace") as stream:
            for line in stream:
                fields = [item.strip() for item in line.split(",")]
                if len(fields) < 2:
                    continue
                try:
                    stamp, value = int(fields[0]), float(fields[1])
                except ValueError:
                    continue
                values[stamp] = values.get(stamp, 0) + value
    stamps = sorted(values)
    if not stamps:
        return 0, float("inf")
    longest = 0.0
    for left, right in zip(stamps, stamps[1:]):
        longest = max(longest, max(0.0, (right - left) / 1000 - 1.0))
    zero_run = run = 0
    for stamp in stamps:
        if values[stamp] <= 0:
            run += 1; zero_run = max(zero_run, run)
        else:
            run = 0
    return len(stamps), max(longest, float(zero_run))


def window_row(path: pathlib.Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid fio JSON {path}: {exc}")
    jobs = data.get("jobs") or []
    if not jobs:
        fail(f"fio jobs missing: {path}")
    read_bytes = sum(int((j.get("read") or {}).get("io_bytes") or 0) for j in jobs)
    write_bytes = sum(int((j.get("write") or {}).get("io_bytes") or 0) for j in jobs)
    read_bw = sum(float((j.get("read") or {}).get("bw_bytes") or
                        float((j.get("read") or {}).get("bw") or 0) * 1024) for j in jobs) / 2**20
    write_bw = sum(float((j.get("write") or {}).get("bw_bytes") or
                         float((j.get("write") or {}).get("bw") or 0) * 1024) for j in jobs) / 2**20
    errors = sum(int(j.get("error") or j.get("total_err") or j.get("total_io_errors") or 0) for j in jobs)
    read_p95 = max((percentile(j, "read", "95.000000") for j in jobs), default=0)
    read_p99 = max((percentile(j, "read", "99.000000") for j in jobs), default=0)
    write_p95 = max((percentile(j, "write", "95.000000") for j in jobs), default=0)
    write_p99 = max((percentile(j, "write", "99.000000") for j in jobs), default=0)
    read_mean = max((latency_stat(j, "read", "mean") for j in jobs), default=0)
    read_max = max((latency_stat(j, "read", "max") for j in jobs), default=0)
    write_mean = max((latency_stat(j, "write", "mean") for j in jobs), default=0)
    write_max = max((latency_stat(j, "write", "max") for j in jobs), default=0)
    if read_bytes > 0 and (read_p99 <= 0 or read_mean <= 0 or read_max <= 0):
        fail(f"read latency evidence missing: {path}")
    if write_bytes > 0 and (write_p99 <= 0 or write_mean <= 0 or write_max <= 0):
        fail(f"write latency evidence missing: {path}")
    # fio's default percentile histogram may top out near 17.1s.  When the mean
    # exceeds the reported P99, the histogram value is censored and must not be
    # presented as an exact percentile.  Use the mean as a conservative safety
    # gate while preserving the raw P99 field for traceability.
    latency_censored = ((read_bytes > 0 and (read_mean > read_p99 or
                                             (read_p99 >= 17_000_000 and read_max > read_p99))) or
                        (write_bytes > 0 and (write_mean > write_p99 or
                                              (write_p99 >= 17_000_000 and write_max > write_p99))))
    read_gate = max(read_p99, read_mean)
    write_gate = max(write_p99, write_mean)
    log_points, max_gap = bandwidth_log_gap(path.parent)
    try:
        fio_rc = int((path.parent / "fio.rc").read_text().strip())
    except (OSError, ValueError):
        fio_rc = -1
    return dict(read_bytes=read_bytes, write_bytes=write_bytes, read_bw_mib_s=read_bw,
                write_bw_mib_s=write_bw, read_p95_us=read_p95, read_p99_us=read_p99,
                write_p95_us=write_p95, write_p99_us=write_p99,
                read_mean_us=read_mean, read_max_us=read_max,
                write_mean_us=write_mean, write_max_us=write_max,
                read_latency_gate_us=read_gate, write_latency_gate_us=write_gate,
                latency_histogram_censored=latency_censored, errors=errors,
                bw_log_points=log_points, max_bw_log_gap_s=max_gap, fio_rc=fio_rc)


def load_config(root: pathlib.Path) -> dict[str, str]:
    # config.env uses shell quoting.  Only simple numeric/string values needed by
    # the analyzer are accepted here; no shell evaluation is performed.
    wanted = {}
    for line in (root / "config.env").read_text().splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if value.startswith("'") and value.endswith("'"):
            value = value[1:-1]
        value = value.replace("\\ ", " ")
        wanted[key] = value
    return wanted


def recovery_cycles(values: list[int]) -> tuple[int, list[int]]:
    """Count material rise->fall cycles; thresholds avoid counting sampler noise."""
    if len(values) < 3:
        return 0, []
    span = max(values) - min(values)
    epsilon = max(8192, int(span * 0.02))
    base = peak = values[0]
    rising = False
    lows = []
    for value in values[1:]:
        if not rising:
            peak = max(peak, value)
            if peak - base >= epsilon:
                rising = True
        elif peak - value >= epsilon:
            lows.append(value); base = peak = value; rising = False
        else:
            peak = max(peak, value)
    return len(lows), lows


def analyze(root: pathlib.Path) -> None:
    if not root.is_absolute() or not root.is_dir() or root.is_symlink():
        fail("root must be an existing absolute non-symlink directory")
    config = load_config(root)
    windows = sorted((root / "windows").glob("*/fio.json"))
    if not windows:
        fail("no fio windows")
    rows = []
    for index, path in enumerate(windows, 1):
        row = window_row(path)
        row["window"] = index
        row["path"] = str(path.relative_to(root))
        rows.append(row)
    phase_by_window = {}
    contract_path = root / "window-contract.tsv"
    if contract_path.exists():
        for item in csv.DictReader(contract_path.open(), delimiter="\t"):
            phase_by_window[int(item["window"])] = item["phase"]
    for row in rows:
        row["phase"] = phase_by_window.get(row["window"], "steady")
    derived = root / "derived"
    derived.mkdir(mode=0o700, exist_ok=True)
    fields = ["window", "phase", "read_bytes", "write_bytes", "read_bw_mib_s", "write_bw_mib_s",
              "read_p95_us", "read_p99_us", "write_p95_us", "write_p99_us",
              "read_mean_us", "read_max_us", "write_mean_us", "write_max_us",
              "read_latency_gate_us", "write_latency_gate_us", "latency_histogram_censored",
              "errors", "fio_rc", "path"]
    fields[-1:-1] = ["bw_log_points", "max_bw_log_gap_s"]
    summary_tmp = derived / ".hourly-summary.tsv.tmp"
    with summary_tmp.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fields, delimiter="\t")
        writer.writeheader(); writer.writerows(rows)
    summary_tmp.replace(derived / "hourly-summary.tsv")

    samples_path = root / "samples/ceph.tsv"
    samples = list(csv.DictReader(samples_path.open(), delimiter="\t")) if samples_path.exists() else []
    integrity_rc = int((root / "verify-final/fio.rc").read_text().strip()) if (root / "verify-final/fio.rc").exists() else -1
    min_read = float(config.get("LT_MIN_READ_BW_MIB", "0"))
    min_write = float(config.get("LT_MIN_WRITE_BW_MIB", "0"))
    max_p99 = float(config.get("LT_MAX_P99_US", "inf"))
    min_ratio = float(config.get("LT_MIN_WINDOW_RATIO_PCT", "70")) / 100
    max_p99_ratio = float(config.get("LT_MAX_P99_RATIO", "3"))
    max_gap = float(config.get("LT_MAX_WINDOW_GAP_S", "30"))
    errors = sum(r["errors"] for r in rows)
    phase_reference = {}
    for row in rows:
        phase_reference.setdefault(row["phase"], row)
    perf_ok = all(
        (r["read_bytes"] == 0 or r["read_bw_mib_s"] >= min_read) and
        (r["write_bytes"] == 0 or r["write_bw_mib_s"] >= min_write) and
        (phase_reference[r["phase"]]["read_bw_mib_s"] == 0 or r["read_bw_mib_s"] >= phase_reference[r["phase"]]["read_bw_mib_s"] * min_ratio) and
        (phase_reference[r["phase"]]["write_bw_mib_s"] == 0 or r["write_bw_mib_s"] >= phase_reference[r["phase"]]["write_bw_mib_s"] * min_ratio) and
        max(r["read_latency_gate_us"], r["write_latency_gate_us"]) <= max_p99 and
        max(r["read_latency_gate_us"], r["write_latency_gate_us"]) <= max(1, max(phase_reference[r["phase"]]["read_latency_gate_us"], phase_reference[r["phase"]]["write_latency_gate_us"])) * max_p99_ratio and
        r["max_bw_log_gap_s"] <= max_gap and r["errors"] == 0 and r["fio_rc"] == 0
        for r in rows
    )
    db_columns = [key for key in (samples[0].keys() if samples else []) if key.startswith("db_free_")]
    if samples and not db_columns:
        raise SystemExit("missing per-OSD DB columns")
    capacity = {
        "sample_count": len(samples),
        "objects_start": int(samples[0]["objects"]) if samples else None,
        "objects_end": int(samples[-1]["objects"]) if samples else None,
        "stored_start": int(samples[0]["stored"]) if samples else None,
        "stored_end": int(samples[-1]["stored"]) if samples else None,
        "per_osd_db_min_bytes": {key: min(int(r[key]) for r in samples) for key in db_columns} if samples else {},
        "per_osd_db_end_bytes": {key: int(samples[-1][key]) for key in db_columns} if samples else {},
    }
    object_values = [int(row["objects"]) for row in samples]
    cycle_count, cycle_lows = recovery_cycles(object_values)
    low_drift_pct = None
    if len(cycle_lows) >= 2 and cycle_lows[0]:
        low_drift_pct = (cycle_lows[-1] - cycle_lows[0]) / cycle_lows[0] * 100
    capacity.update({"detected_object_recovery_cycles": cycle_count,
                     "object_cycle_lows": cycle_lows,
                     "object_low_drift_pct": low_drift_pct})
    manifest_path = root / "dataset-prepared.tsv"
    logical_bytes = 0
    if manifest_path.exists():
        for line in manifest_path.read_text().splitlines():
            fields_in_line = line.split("\t")
            if len(fields_in_line) == 3:
                logical_bytes += int(fields_in_line[2])
    total_read_bytes = sum(row["read_bytes"] for row in rows)
    total_write_bytes = sum(row["write_bytes"] for row in rows)
    capacity.update({"dataset_logical_bytes": logical_bytes,
                     "total_read_bytes": total_read_bytes,
                     "total_write_bytes": total_write_bytes,
                     "write_overwrite_equivalents": total_write_bytes / logical_bytes if logical_bytes else None})
    client_samples_path = root / "samples/client.tsv"
    client_samples = list(csv.DictReader(client_samples_path.open(), delimiter="\t")) if client_samples_path.exists() else []
    client_resources = {}
    for key in ("mem_available_bytes", "result_free_bytes", "juicefs_rss_bytes", "juicefs_threads", "juicefs_fds"):
        values = [int(row[key]) for row in client_samples if row.get(key, "").isdigit()]
        if values:
            client_resources[key] = {"start": values[0], "end": values[-1],
                                     "min": min(values), "max": max(values)}
    slice_checkpoints = []
    for path in sorted((root / "metadata").glob("*/analysis.json")):
        value = json.loads(path.read_text())
        slice_checkpoints.append({"checkpoint": path.parent.name,
                                  "raw_records": value["raw_records"],
                                  "raw_full_slice_bytes": value["raw_full_slice_bytes"],
                                  "visible_full_slice_bytes": value["visible_full_slice_bytes"],
                                  "fully_shadowed_full_slice_bytes": value["fully_shadowed_full_slice_bytes"],
                                  "amplification": value["raw_full_slice_amplification"]})
    duration = int(config.get("LT_DURATION_S", "0"))
    sample_interval = max(1, int(config.get("LT_SAMPLE_INTERVAL_S", "60")))
    minimum_samples = max(1, int(duration / sample_interval * 0.70))
    monitoring_ok = len(samples) >= minimum_samples
    slo_frozen = config.get("LT_SLO_FROZEN", "0") == "1"
    case_id = config.get("LT_CASE_ID", "unknown")
    native_capacity = "PASS_SCREEN" if samples and not (root / "STOP.txt").exists() else "FAIL"
    max_amp = float(config.get("LT_MAX_SLICE_AMP", "128"))
    max_low_drift = float(config.get("LT_MAX_LOW_DRIFT_PCT", "10"))
    amps = [item["amplification"] for item in slice_checkpoints if item["amplification"] is not None]
    metadata_gap = (root / "metadata-evidence-gap.tsv").exists()
    if not monitoring_ok and native_capacity != "FAIL":
        native_capacity = "INCONCLUSIVE_EVIDENCE_GAP"
    elif case_id == "LT-001" and native_capacity != "FAIL":
        native_capacity = "NOT_APPLICABLE_READ_ONLY"
    elif amps and max(amps) > max_amp:
        native_capacity = "FAIL"
    elif metadata_gap and case_id in {"LT-002", "LT-003", "LT-004"}:
        native_capacity = "INCONCLUSIVE_METADATA_GAP"
    elif case_id in {"LT-002", "LT-003"} and native_capacity != "FAIL":
        if duration < 86400 or cycle_count < 3:
            native_capacity = "INCONCLUSIVE_LONG_BOUND"
        elif low_drift_pct is not None and low_drift_pct > max_low_drift:
            native_capacity = "FAIL"
        else:
            native_capacity = "PASS"
    if not perf_ok:
        performance_verdict = "FAIL"
    elif not monitoring_ok:
        performance_verdict = "INCONCLUSIVE_EVIDENCE_GAP"
    elif duration > 7200 and not slo_frozen:
        performance_verdict = "INCONCLUSIVE_SLO_NOT_FROZEN"
    elif duration >= 86400:
        performance_verdict = "PASS"
    else:
        performance_verdict = "PASS_SCREEN"
    verdict = {
        "case": case_id,
        "profile": config.get("LT_PROFILE"),
        "duration_s": duration,
        "windows": len(rows),
        "data_correctness": "PASS" if integrity_rc == 0 else "FAIL",
        "performance_long_term": performance_verdict,
        "monitoring_evidence": {"status": "PASS" if monitoring_ok else "INCONCLUSIVE",
                                "samples": len(samples), "minimum_samples": minimum_samples},
        "capacity_long_term": native_capacity,
        "maintenance_cost": "MEASURED" if case_id == "LT-004" and (root / "maintenance/runtime.tsv").exists() else "NOT_APPLICABLE",
        "fio_errors": errors,
        "read_bw_mib_s": {"min": min((r["read_bw_mib_s"] for r in rows), default=0), "median": statistics.median(r["read_bw_mib_s"] for r in rows)},
        "write_bw_mib_s": {"min": min((r["write_bw_mib_s"] for r in rows), default=0), "median": statistics.median(r["write_bw_mib_s"] for r in rows)},
        "capacity": capacity,
        "client_resources": client_resources,
        "slice_checkpoints": slice_checkpoints,
        "metadata_evidence_gap": metadata_gap,
        "note": "A 2-hour run is a safety screen; native capacity convergence needs >=24h and >=3 visible growth/recovery cycles.",
    }
    (derived / "verdict.json").write_text(json.dumps(verdict, ensure_ascii=False, indent=2) + "\n")
    print(f"LT_ANALYZE_PASS\tcase={case_id}\twindows={len(rows)}\tverdict={derived / 'verdict.json'}")


def self_test() -> None:
    fixture = {"jobs": [{"read": {"io_bytes": 1048576, "bw_bytes": 1048576,
        "clat_ns": {"mean": 2500, "max": 5000,
                    "percentile": {"95.000000": 2000, "99.000000": 4000}},
        "lat_ns": {"mean": 3500, "max": 7000,
                   "percentile": {"95.000000": 3000, "99.000000": 6000}}},
        "write": {"io_bytes": 0, "bw_bytes": 0}, "total_err": 0}]}
    with tempfile.TemporaryDirectory(prefix="lt-analyze-window-selftest-") as name:
        window = pathlib.Path(name)
        path = window / "fio.json"
        path.write_text(json.dumps(fixture))
        (window / "fio.rc").write_text("0\n")
        bw = window / "bw"; bw.mkdir()
        (bw / "fio_bw.1.log").write_text("0, 1024, 0\n1000, 1024, 0\n2000, 1024, 0\n")
        row = window_row(path)
        assert row["read_bw_mib_s"] == 1 and row["read_p99_us"] == 6
        assert row["read_mean_us"] == 3.5 and row["read_max_us"] == 7
        assert row["errors"] == 0 and row["fio_rc"] == 0 and row["max_bw_log_gap_s"] == 0
        assert row["latency_histogram_censored"] is False
        missing = json.loads(json.dumps(fixture))
        del missing["jobs"][0]["read"]["lat_ns"]
        del missing["jobs"][0]["read"]["clat_ns"]["mean"]
        path.write_text(json.dumps(missing))
        try:
            window_row(path)
        except SystemExit as exc:
            assert "latency evidence missing" in str(exc)
        else:
            raise AssertionError("missing latency evidence was accepted")
    assert recovery_cycles([10000, 20000, 10000, 21000, 11000, 22000, 12000])[0] == 3
    with tempfile.TemporaryDirectory(prefix="lt-analyze-full-selftest-") as name:
        root = pathlib.Path(name)
        (root / "config.env").write_text(
            "LT_CASE_ID=LT-001\nLT_PROFILE=seqread\nLT_DURATION_S=7200\n"
            "LT_SAMPLE_INTERVAL_S=60\nLT_MIN_READ_BW_MIB=1\nLT_MIN_WRITE_BW_MIB=1\n"
            "LT_MAX_P99_US=10000000\nLT_MIN_WINDOW_RATIO_PCT=70\n"
            "LT_MAX_P99_RATIO=3\nLT_MAX_WINDOW_GAP_S=30\nLT_SLO_FROZEN=0\n"
        )
        window = root / "windows/0001"; (window / "bw").mkdir(parents=True)
        (window / "fio.json").write_text(json.dumps(fixture)); (window / "fio.rc").write_text("0\n")
        (window / "bw/fio_bw.1.log").write_text("0, 1024, 0\n1000, 1024, 0\n2000, 1024, 0\n")
        samples = root / "samples"; samples.mkdir()
        fixture_osds = [0, 2, 3, 4, 5, 6]
        header = ["epoch", "objects", "stored", *[f"db_free_{i}" for i in fixture_osds]]
        with (samples / "ceph.tsv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, header, delimiter="\t")
            writer.writeheader()
            for index in range(90):
                writer.writerow({"epoch": index, "objects": 10000, "stored": 10000,
                                 **{f"db_free_{i}": 20 * 2**30 for i in fixture_osds}})
        (root / "verify-final").mkdir(); (root / "verify-final/fio.rc").write_text("0\n")
        analyze(root); analyze(root)
        verdict = json.loads((root / "derived/verdict.json").read_text())
        assert verdict["data_correctness"] == "PASS"
        assert verdict["performance_long_term"] == "PASS_SCREEN"
        assert verdict["monitoring_evidence"]["status"] == "PASS"
    print("LT_ANALYZE_SELF_TEST_PASS")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
    elif len(sys.argv) == 2:
        analyze(pathlib.Path(sys.argv[1]))
    else:
        fail("usage: lt-analyze.py ROOT | --self-test")
