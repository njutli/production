#!/usr/bin/env python3
"""Strict offline validation and fixed-window BW calculation for one 03-22c arm."""
from __future__ import annotations

import glob
import gzip
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def fail(msg: str) -> None:
    raise SystemExit(f"E_T66_ANALYZE\t{msg}")


def resample_bw_rows(rows: list[tuple[int, float]], name: str) -> tuple[dict[int, float], dict[str, int]]:
    """Convert fio interval-average KiB/s samples to one-second MiB/s bins.

    With log_avg_msec=1000, a row at t describes the average rate since the
    previous row (the first row starts at t=0). fio 3.28 timestamps jitter
    around integer seconds, so flooring each timestamp is neither unique nor
    energy preserving. Allocate rate * overlap to every intersected 1s bin.
    """
    if len(rows) < 170:
        fail(f"short bw log {name}: {len(rows)} samples")
    bins: dict[int, float] = defaultdict(float)
    coverage: dict[int, float] = defaultdict(float)
    prev_ms = 0
    duplicate_floor = 0
    previous_floor = -1
    min_step = 10**9
    max_step = 0
    for timestamp_ms, kib_s in rows:
        if timestamp_ms <= prev_ms:
            fail(f"non-increasing BW timestamp in {name}: prev={prev_ms} current={timestamp_ms}")
        step = timestamp_ms - prev_ms
        min_step = min(min_step, step)
        max_step = max(max_step, step)
        if step > 5000:
            fail(f"BW sampling gap exceeds 5000ms in {name}: {step}ms")
        floored = timestamp_ms // 1000
        if floored == previous_floor:
            duplicate_floor += 1
        previous_floor = floored
        rate_mib_s = kib_s / 1024.0
        cursor = prev_ms
        while cursor < timestamp_ms:
            sec = cursor // 1000
            boundary = min(timestamp_ms, (sec + 1) * 1000)
            overlap_s = (boundary - cursor) / 1000.0
            bins[sec] += rate_mib_s * overlap_s
            coverage[sec] += overlap_s
            cursor = boundary
        prev_ms = timestamp_ms
    if not 175000 <= prev_ms <= 181000:
        fail(f"unexpected final BW timestamp in {name}: {prev_ms}ms")
    for sec in range(15, 175):
        if abs(coverage.get(sec, 0.0) - 1.0) > 1e-9:
            fail(f"BW resample coverage in {name} second={sec}: {coverage.get(sec, 0.0):.9f}/1.0")
    stats = {
        "rows": len(rows), "first_ms": rows[0][0], "last_ms": rows[-1][0],
        "min_step_ms": min_step, "max_step_ms": max_step,
        "duplicate_floor_seconds": duplicate_floor,
    }
    return dict(bins), stats


def aggregate_bw(arm: Path) -> dict[int, float]:
    files = sorted(glob.glob(str(arm / "bw" / "*_bw.*.log")))
    if len(files) != 256:
        fail(f"expected 256 bw logs, got {len(files)}")
    values: dict[int, float] = defaultdict(float)
    diagnostics = []
    for name in files:
        rows = []
        for raw in Path(name).read_text().splitlines():
            parts = [x.strip() for x in raw.split(",")]
            if len(parts) < 3:
                fail(f"malformed bw row: {name}: {raw}")
            try:
                timestamp_ms = int(parts[0])
                kib_s = float(parts[1])
            except ValueError:
                fail(f"non-numeric bw row: {name}: {raw}")
            direction = int(parts[2])
            if direction != 1:
                fail(f"non-write direction in {name}: {direction}")
            if kib_s < 0:
                fail(f"negative bandwidth in {name}: {kib_s}")
            rows.append((timestamp_ms, kib_s))
        file_bins, stats = resample_bw_rows(rows, name)
        for sec, value in file_bins.items():
            values[sec] += value
        diagnostics.append((name, stats))
    with (arm / "bw-resample.tsv").open("w") as f:
        f.write("path\trows\tfirst_ms\tlast_ms\tmin_step_ms\tmax_step_ms\tduplicate_floor_seconds\n")
        for name, s in diagnostics:
            f.write(f"{name}\t{s['rows']}\t{s['first_ms']}\t{s['last_ms']}\t"
                    f"{s['min_step_ms']}\t{s['max_step_ms']}\t{s['duplicate_floor_seconds']}\n")
    return dict(values)


def med(values: dict[int, float], lo: int, hi: int) -> float:
    xs = [values[x] for x in range(lo, hi) if x in values]
    if len(xs) < hi - lo - 2:
        fail(f"BW window [{lo},{hi}) coverage={len(xs)}/{hi-lo}")
    return statistics.median(xs)


def estimate_io_start(root: Path) -> float:
    arm = root / "arm"
    files = sorted(arm.glob("bw/*_bw.*.log"))
    if len(files) != 256:
        fail(f"I/O-start derivation expected 256 bw logs, got {len(files)}")
    phase = [x.split("\t") for x in (arm/"phase.tsv").read_text().splitlines() if x.strip()]
    launch = next((float(x[0]) for x in phase if len(x) >= 2 and x[1] == "launch"), None)
    end = next((float(x[0]) for x in phase if len(x) >= 2 and x[1] == "end"), None)
    if launch is None or end is None or not launch < end:
        fail("invalid launch/end phase for I/O-start derivation")
    rows = []
    estimates = []
    for path in files:
        times = []
        for raw in path.read_text().splitlines():
            parts = [x.strip() for x in raw.split(",")]
            if len(parts) < 3:
                fail(f"malformed bw row during I/O-start derivation: {path}: {raw}")
            times.append(int(parts[0]))
        if not times:
            fail(f"empty bw log during I/O-start derivation: {path}")
        last_ms = max(times)
        if not 175000 <= last_ms <= 181000:
            fail(f"unexpected final relative timestamp {last_ms}ms: {path}")
        mtime_ns = path.stat().st_mtime_ns
        estimate = mtime_ns / 1e9 - last_ms / 1000.0
        estimates.append(estimate)
        rows.append((path, mtime_ns, last_ms, estimate))
    start = statistics.median(estimates)
    spread = max(estimates) - min(estimates)
    if spread > 2.0:
        fail(f"I/O-start estimate spread too large: {spread:.6f}s")
    if not launch < start < end or not 178 <= end - start <= 183:
        fail(f"implausible derived I/O start: launch={launch} start={start} end={end}")
    with (arm/"fio-io-start-estimates.tsv").open("w") as f:
        f.write("path\tmtime_ns\tlast_relative_ms\testimated_start_epoch\n")
        for path, mtime_ns, last_ms, estimate in rows:
            f.write(f"{path}\t{mtime_ns}\t{last_ms}\t{estimate:.9f}\n")
    (arm/"fio-io-start.epoch").write_text(f"{start:.9f}\n")
    (arm/"fio-io-start.method").write_text(
        "median(bw_log_mtime_ns/1e9-last_relative_ms/1000); "
        f"n=256; spread_s={spread:.9f}\n"
    )
    print(f"IO_START_DERIVE_PASS epoch={start:.9f} estimates=256 spread_s={spread:.9f}")
    return start


def validate_samples(root: Path, io_start: float) -> tuple[dict[str, int], dict[str, int]]:
    lo, hi = io_start + 15, io_start + 175
    counts = {}
    log_growth = []
    for node in ("10.20.1.150", "10.20.1.151", "10.20.1.152"):
        path = root / "samplers" / node / "node-samples.txt"
        if not path.exists(): fail(f"missing node sampler: {node}")
        lines = path.read_text().splitlines()
        epochs = [int(x.split("\t")[1]) / 1e9 for x in lines if x.startswith("BEGIN\t")]
        selected_epochs=sorted(x for x in epochs if lo <= x < hi)
        n = len(selected_epochs)
        counts[f"node-{node}"] = n
        if n < 152: fail(f"node sampler {node} formal coverage={n}/160")
        if any(b-a > 2.5 for a,b in zip(selected_epochs,selected_epochs[1:])):
            fail(f"node sampler {node} has a formal-window gap >2.5s")
        status = root / "samplers" / node / "sampler-status.tsv"
        if not status.exists() or not status.read_text().startswith("SAMPLER_EXIT_AFTER_FIO\t"):
            fail(f"node sampler status is not normal: {node}")
        errors = root / "samplers" / node / "tikv-capacity-errors.txt"
        if not errors.exists() or errors.stat().st_size:
            fail(f"TiKV capacity error evidence missing/nonempty: {node}")
        for abort in ("CAPACITY_SAFETY_ABORT", "MEMORY_SAFETY_ABORT"):
            if (root / "samplers" / node / abort).exists():
                fail(f"node safety abort exists: {node}: {abort}")
        for snap in ("nvme-smart-pre.json", "nvme-smart-post.json"):
            path = root / "samplers" / node / snap
            try:
                data=json.loads(path.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                fail(f"bad/missing NVMe SMART snapshot {node}/{snap}: {exc}")
            if not isinstance(data, dict) or not data:
                fail(f"empty NVMe SMART snapshot: {node}/{snap}")
        current = None
        role_used: dict[str, list[int]] = defaultdict(list)
        for line in lines:
            parts = line.split("\t")
            if parts[0] == "BEGIN":
                current = int(parts[1]) / 1e9
            elif parts[0] == "DF" and current is not None:
                if len(parts) != 5: fail(f"malformed DF sample: {node}: {line}")
                role, used_pct, avail = parts[1], int(parts[3]), int(parts[4])
                if used_pct >= 70 or avail < 8 * 1024**3:
                    fail(f"capacity hard gate failed: node={node} role={role} used={used_pct} avail={avail}")
                # df used bytes are not emitted directly; total-used is recoverable
                # only approximately from percent, so use available deltas for the
                # D1 canary growth contract (max available drop).
                role_used[role].append(avail)
        if "logs" in role_used:
            vals=role_used["logs"]
            log_growth.append(max(vals)-min(vals))
    hb = root / "samplers" / "metrics" / "metrics-heartbeat.tsv"
    rows = [x.split("\t") for x in hb.read_text().splitlines() if x.strip()]
    for node in ("10.20.1.150", "10.20.1.151", "10.20.1.152"):
        epochs = {int(x[0]) for x in rows if x[1] == node and lo <= int(x[0]) < hi}
        counts[f"metrics-{node}"] = len(epochs)
        if len(epochs) < 29: fail(f"metrics sampler {node} formal coverage={len(epochs)}/32")
        ordered=sorted(epochs)
        if any(b-a > 10 for a,b in zip(ordered,ordered[1:])):
            fail(f"metrics sampler {node} has a formal-window gap >10s")
        for x in rows:
            if x[1] == node and lo <= int(x[0]) < hi:
                try:
                    with gzip.open(x[2], "rt") as f:
                        if not f.readline(): fail(f"empty metrics snapshot {x[2]}")
                except OSError as exc:
                    fail(f"bad metrics gzip {x[2]}: {exc}")
    pdhb = root / "samplers" / "metrics" / "pd-stores-heartbeat.tsv"
    pdrows = [x.split("\t") for x in pdhb.read_text().splitlines() if x.strip()]
    selected = [x for x in pdrows if lo <= int(x[0]) < hi]
    if len(selected) < 29: fail(f"PD store-status formal coverage={len(selected)}/32")
    pd_epochs=sorted({int(x[0]) for x in selected})
    if any(b-a > 10 for a,b in zip(pd_epochs,pd_epochs[1:])):
        fail("PD store-status sampler has a formal-window gap >10s")
    for epoch, name in selected:
        try:
            with gzip.open(name, "rt") as f: stores=json.load(f).get("stores",[])
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"bad PD stores snapshot {name}: {exc}")
        if len(stores) != 3 or any(x.get("store",{}).get("state_name") != "Up" for x in stores):
            fail(f"PD store state not all Up: {name}")
    cp = root / "samplers" / "client" / "client.tsv"
    epochs = sorted(int(x.split("\t")[0]) / 1e9 for x in cp.read_text().splitlines() if x.strip())
    selected_client=[x for x in epochs if lo <= x < hi]
    n = len(selected_client)
    counts["client"] = n
    if n < 152: fail(f"client sampler formal coverage={n}/160")
    if any(b-a > 2.5 for a,b in zip(selected_client,selected_client[1:])):
        fail("client sampler has a formal-window gap >2.5s")
    for name in ("metrics", "client"):
        status=root/"samplers"/name/"sampler-status.tsv"
        if not status.exists() or not status.read_text().startswith("SAMPLER_EXIT_AFTER_FIO\t"):
            fail(f"{name} sampler status is not normal")
    osdhb = root / "samplers" / "osd" / "osd-heartbeat.tsv"
    try:
        osdrows=[x.split("\t") for x in osdhb.read_text().splitlines() if x.strip()]
    except OSError as exc:
        fail(f"OSD sampler heartbeat missing: {exc}")
    osd_ids=sorted({x[1] for x in osdrows if len(x)==3})
    if len(osd_ids) != 6:
        fail(f"OSD sampler expected 6 OSD ids, got {osd_ids}")
    for osd in osd_ids:
        selected=[x for x in osdrows if x[1]==osd and lo <= int(x[0]) < hi]
        counts[f"osd-{osd}"]=len(selected)
        if len(selected) < 29:
            fail(f"OSD sampler osd.{osd} formal coverage={len(selected)}/32")
        ordered=sorted({int(x[0]) for x in selected})
        if any(b-a > 10 for a,b in zip(ordered,ordered[1:])):
            fail(f"OSD sampler osd.{osd} has a formal-window gap >10s")
        for _, _, name in selected:
            try:
                data=json.loads(Path(name).read_text())
            except (OSError, json.JSONDecodeError) as exc:
                fail(f"bad OSD perf snapshot {name}: {exc}")
            if not isinstance(data, dict) or not data:
                fail(f"empty OSD perf snapshot {name}")
    status=root/"samplers"/"osd"/"sampler-status.tsv"
    if not status.exists() or not status.read_text().startswith("SAMPLER_EXIT_AFTER_FIO\t"):
        fail("osd sampler status is not normal")
    return counts, {"d1_logs_peak_available_drop_bytes": max(log_growth, default=0)}


def analyze_matrix(run_root: Path) -> None:
    expected={"R01":"B1c","R02":"D1","R03":"D1","R04":"B1c",
              "R05":"D1","R06":"B1c","R07":"B1c","R08":"D1"}
    data_by_instance={}
    for instance, arm in expected.items():
        path=run_root/"instances"/instance/"arm-analysis.json"
        if not path.exists(): fail(f"matrix missing {path}")
        data=json.loads(path.read_text())
        if data.get("evidence_class") != "FORMAL" or data.get("arm") != arm or not data.get("evidence_valid"):
            fail(f"matrix identity/evidence gate failed: {instance}")
        data_by_instance[instance]=data
    bw={x:float(v["formal_median_MiBs"]) for x,v in data_by_instance.items()}
    pairs=[("R01","R02"),("R04","R03"),("R06","R05"),("R07","R08")]
    effects=[100*(bw[b]-bw[a])/bw[a] for a,b in pairs]
    a_vals=[bw[x] for x in ("R01","R04","R06","R07")]
    b_vals=[bw[x] for x in ("R02","R03","R05","R08")]
    cv_effects=[float(data_by_instance[a]["cv_pct"])-float(data_by_instance[b]["cv_pct"]) for a,b in pairs]
    w4_effects=[float(data_by_instance[b]["w4_w1"])-float(data_by_instance[a]["w4_w1"]) for a,b in pairs]
    d1_instances=("R02","R03","R05","R08")
    result={
        "valid_arms":8,
        "b1c_median_MiBs":statistics.median(a_vals),
        "d1_median_MiBs":statistics.median(b_vals),
        "pair_effect_pct":effects,
        "pair_effect_median_pct":statistics.median(effects),
        "positive_pairs":sum(x>0 for x in effects),
        "material_gain_pass":sum(x>0 for x in effects)>=3 and statistics.median(effects)>=15,
        "cv_improvement_pp":cv_effects,
        "cv_improvement_median_pp":statistics.median(cv_effects),
        "cv_improved_pairs":sum(x>0 for x in cv_effects),
        "w4_w1_improvement":w4_effects,
        "w4_w1_improvement_median":statistics.median(w4_effects),
        "w4_w1_improved_pairs":sum(x>0 for x in w4_effects),
        "stability_improvement_pass":sum(x>0 for x in cv_effects)>=3 and statistics.median(cv_effects)>=2.0 and sum(x>0 for x in w4_effects)>=3 and statistics.median(w4_effects)>=0.03,
        "d1_deployment_stable_pass":all(float(data_by_instance[x]["cv_pct"])<=10.0 and float(data_by_instance[x]["w4_w1"])>=0.90 for x in d1_instances),
        "half_nic_target_pass":statistics.median(b_vals)>=6250,
        "historical_engineering_reference":{
            "H_MiBs":2880.0,"RAM_A_partial_MiBs":3699.30,"RAM_B_partial_MiBs":3716.64,
            "causal_use":"forbidden; cross-stage direction/scale only"},
    }
    out=run_root/"analysis"; out.mkdir(parents=True,exist_ok=True)
    (out/"matrix-analysis.json").write_text(json.dumps(result,indent=2,sort_keys=True)+"\n")
    print(json.dumps(result,sort_keys=True))


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        v={x: float(x) for x in range(1,181)}
        assert med(v,15,55) == 34.5
        # Constant 1 MiB/s with the exact 3000/3999ms duplicate-floor shape
        # observed on fio 3.28 must remain 1 MiB/s after interval resampling.
        times = [999, 1999, 3000, 3999]
        while times[-1] < 180000:
            times.append(min(180000, times[-1] + 1000))
        bins, stats = resample_bw_rows([(t, 1024.0) for t in times], "self-test")
        assert stats["duplicate_floor_seconds"] >= 1
        assert all(abs(bins[x] - 1.0) < 1e-12 for x in range(15,175))
        print("t66 analyzer self-test: PASS")
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--derive-io-start":
        estimate_io_start(Path(sys.argv[2]))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--matrix":
        analyze_matrix(Path(sys.argv[2]))
        return
    if len(sys.argv) != 2: fail("usage: t66-analyze.py ARM_DIR")
    root=Path(sys.argv[1]); arm=root/"arm"
    if (arm/"fio.rc").read_text().strip() != "0": fail("fio rc is not zero")
    stdout=(arm/"fio.stdout").read_text()
    if "err= 0" not in stdout: fail("fio stdout lacks err=0")
    io_start=float((arm/"fio-io-start.epoch").read_text().strip())
    if not (arm/"fio-io-start.method").exists(): fail("missing I/O-start derivation method")
    values=aggregate_bw(arm)
    windows={f"W{i+1}": med(values,15+40*i,55+40*i) for i in range(4)}
    formal=med(values,15,175)
    stable=[values[x] for x in range(15,175) if x in values]
    mean=statistics.mean(stable)
    cv=statistics.pstdev(stable)/mean*100
    counts, capacity=validate_samples(root,io_start)
    evidence_class = "NONFORMAL_CANARY" if (root/"NONFORMAL_CANARY").exists() else "FORMAL"
    arm=(root/"volume.tsv").read_text()
    arm=next((x.split("\t",1)[1] for x in arm.splitlines() if x.startswith("cluster\t")),None)
    if arm not in ("B1c","D1"): fail("volume state lacks B1c/D1 identity")
    deployment_stable = cv <= 10.0 and windows["W4"]/windows["W1"] >= 0.90
    sorted_stable=sorted(stable)
    bottom_count=max(1,len(sorted_stable)//10)
    result={"evidence_class":evidence_class,
            "arm":arm,"evidence_valid":True,"deployment_stable":deployment_stable,
            "bw_resample_method":"fio interval-average, time-weighted into 1s bins",
            "formal_median_MiBs":formal,"mean_MiBs":mean,"cv_pct":cv,
            "minimum_second_MiBs":min(stable),
            "bottom_decile_mean_MiBs":statistics.mean(sorted_stable[:bottom_count]),
            "w4_w1":windows["W4"]/windows["W1"],"windows_MiBs":windows,
            "target_pct":formal/6250*100,"coverage":counts,"capacity":capacity}
    (root/"arm-analysis.json").write_text(json.dumps(result,indent=2,sort_keys=True)+"\n")
    if root.name == "ARM-CANARY-D1":
        preflight=root.parent.parent/"preflight"; preflight.mkdir(parents=True,exist_ok=True)
        peak=capacity["d1_logs_peak_available_drop_bytes"]
        (preflight/"d1-logs-canary.tsv").write_text(
            f"source_instance\t{root.name}\npeak_growth_bytes\t{peak}\nsafety_formula\t2*(peak+1GiB)<=fresh_free\n")
    print(json.dumps(result,sort_keys=True))


if __name__ == "__main__":
    main()
