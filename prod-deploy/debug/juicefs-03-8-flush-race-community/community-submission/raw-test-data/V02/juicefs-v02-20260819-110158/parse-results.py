#!/usr/bin/env python3
"""V02 bw log parser: calculate steady p50 for all 54 runs."""
import os, sys, glob, statistics

OUT = "/tmp/juicefs-v02-20260819-110158"
RUN_ID = "20260819-110158"

# Latin-square: (block, arm, position, label)
POSITIONS = [
    (1, "S", 1, "S1"), (1, "A", 1, "A1"), (1, "B", 1, "B1"),
    (2, "B", 2, "B2"), (2, "S", 2, "S2"), (2, "A", 2, "A2"),
    (3, "A", 3, "A3"), (3, "B", 3, "B3"), (3, "S", 3, "S3"),
]

ARMS = {"S": ["S1","S2","S3"], "A": ["A1","A2","A3"], "B": ["B1","B2","B3"]}

def parse_bw_log(filepath):
    """Parse one bw log file. Returns list of (timestamp_s, bw_mibps, direction)."""
    entries = []
    try:
        with open(filepath) as f:
            for line in f:
                parts = line.strip().split(",")
                if len(parts) < 3:
                    continue
                ts_ms = int(parts[0].strip())
                bw_kibps = int(float(parts[1].strip()))
                direction = int(parts[2].strip())
                ts_s = ts_ms / 1000.0
                bw_mibps = bw_kibps / 1024.0
                entries.append((ts_s, bw_mibps, direction))
    except:
        pass
    return entries

def calc_run_p50(run_dir, prefix):
    """Calculate steady p50 for one run. Returns (write_p50, read_p50) in MiB/s."""
    pattern = os.path.join(run_dir, f"{prefix}_bw.*.log")
    files = sorted(glob.glob(pattern))
    if len(files) < 128:
        return None, None, len(files)

    # Collect all entries from all jobs
    # Group by (timestamp_second, direction), sum bw across jobs
    from collections import defaultdict
    ts_dir_bw = defaultdict(lambda: defaultdict(float))  # {ts_second: {direction: total_bw}}

    for f in files:
        for ts_s, bw_mibps, direction in parse_bw_log(f):
            ts_second = int(ts_s)
            ts_dir_bw[ts_second][direction] += bw_mibps

    if not ts_dir_bw:
        return None, None, len(files)

    # Sort by timestamp
    sorted_ts = sorted(ts_dir_bw.keys())

    # Cut first 45 seconds (1/4 of 180s)
    steady_ts = [t for t in sorted_ts if t >= 45]

    if len(steady_ts) < 130:
        return None, None, len(files)

    # Get write and read values
    write_vals = [ts_dir_bw[t].get(1, 0) for t in steady_ts]
    read_vals = [ts_dir_bw[t].get(0, 0) for t in steady_ts]

    write_p50 = statistics.median(write_vals) if write_vals else None
    read_p50 = statistics.median(read_vals) if read_vals else None

    return write_p50, read_p50, len(files)

# Parse all 54 runs
results = []
print("=== Per-run results ===")
print(f"{'label':<6} {'item':<10} {'round':<6} {'write_p50':>12} {'read_p50':>12} {'bw_files':>8} {'valid':>6}")

for block, arm, pos, label in POSITIONS:
    pos_dir = os.path.join(OUT, "runs", f"block{block}-{label}")
    for item in ["randwrite", "randrw"]:
        prefix_base = f"{label}-rw" if item == "randwrite" else f"{label}-rr"
        mount_write_vals = []
        mount_read_vals = []
        for round_num in [1, 2, 3]:
            run_dir = os.path.join(pos_dir, f"{item}-{round_num}")
            prefix = f"{prefix_base}{round_num}"
            wp50, rp50, nfiles = calc_run_p50(run_dir, prefix)
            valid = "YES" if wp50 is not None and nfiles >= 128 else "NO"
            rp50_str = f"{rp50:.1f}" if rp50 else "0.0"
            wp50_str = f"{wp50:.1f}" if wp50 else "N/A"
            print(f"{label:<6} {item:<10} r{round_num}      {wp50_str:>12} {rp50_str:>12} {nfiles:>8} {valid:>6}")
            results.append((label, item, round_num, wp50, rp50, nfiles, valid))
            if valid == "YES":
                mount_write_vals.append(wp50)
                if rp50:
                    mount_read_vals.append(rp50)

        # Mount-level median (2nd of 3 sorted)
        if len(mount_write_vals) >= 3:
            mw = sorted(mount_write_vals)[1]
            print(f"  {label} {item} mount-level write_p50 = {mw:.1f}")
        if len(mount_read_vals) >= 3:
            mr = sorted(mount_read_vals)[1]
            print(f"  {label} {item} mount-level read_p50 = {mr:.1f}")

# Arm-level medians
print("\n=== Arm-level results ===")
for arm, labels in ARMS.items():
    arm_writes = []
    arm_reads = []
    for label in labels:
        for item in ["randwrite", "randrw"]:
            mount_vals_w = []
            mount_vals_r = []
            for r in [1, 2, 3]:
                for (lbl, itm, rnd, wp, rp, nf, v) in results:
                    if lbl == label and itm == item and rnd == r and v == "YES":
                        mount_vals_w.append(wp)
                        if rp:
                            mount_vals_r.append(rp)
            if len(mount_vals_w) >= 3:
                mw = sorted(mount_vals_w)[1]
                if item == "randwrite":
                    arm_writes.append(mw)
                # For randrw, we use write p50 for B/A comparison
            if len(mount_vals_r) >= 3:
                mr = sorted(mount_vals_r)[1]
                if item == "randrw":
                    arm_reads.append(mr)

    arm_write = sorted(arm_writes)[1] if len(arm_writes) >= 3 else None
    print(f"{arm} randwrite arm-level = {arm_write:.1f}" if arm_write else f"{arm} randwrite INSUFFICIENT")

# B/S, B/A
arm_vals = {}
for arm, labels in ARMS.items():
    vals = []
    for label in labels:
        mvals = []
        for r in [1,2,3]:
            for (lbl, itm, rnd, wp, rp, nf, v) in results:
                if lbl == label and itm == "randwrite" and rnd == r and v == "YES":
                    mvals.append(wp)
        if len(mvals) >= 3:
            vals.append(sorted(mvals)[1])
    if len(vals) >= 3:
        arm_vals[arm] = sorted(vals)[1]

print("\n=== Mechanical judgments (randwrite) ===")
if "S" in arm_vals and "B" in arm_vals and "A" in arm_vals:
    s = arm_vals["S"]
    a = arm_vals["A"]
    b = arm_vals["B"]
    print(f"S_arm_p50 = {s:.1f}")
    print(f"A_arm_p50 = {a:.1f}")
    print(f"B_arm_p50 = {b:.1f}")
    print(f"B/S = {b/s:.2f}" if s > 0 else "B/S = N/A")
    print(f"0.70*B/S = {0.7*b/s:.2f}" if s > 0 else "0.70*B/S = N/A")
    print(f"B/A = {b/a:.4f}" if a > 0 else "B/A = N/A")
    print(f"0.70*B/A = {0.7*b/a:.4f}" if a > 0 else "0.70*B/A = N/A")
    print(f"(B/A)/0.70 = {b/a/0.7:.4f}" if a > 0 else "(B/A)/0.70 = N/A")
    print(f"S < 1000: {'YES' if s < 1000 else 'NO'}")
    print(f"B >= 1653: {'YES' if b >= 1653 else 'NO'}")
    print(f"B/S >= 3.0: {'YES' if b/s >= 3.0 else 'NO'}")
