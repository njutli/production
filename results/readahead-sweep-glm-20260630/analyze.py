#!/usr/bin/env python3
"""Analyze OSD op_r_out_bytes from readahead sweep results."""
import json, os, re, sys

OUTDIR = "/home/turboai/production/results/readahead-sweep-glm-20260630"

RA_VALUES = ["0", "4", "default"]
WORKLOADS = ["randread", "randwrite", "randrw"]
ROUNDS = 3

def get_json_field(filepath, field):
    """Extract a numeric field from OSD perf dump JSON."""
    try:
        with open(filepath) as f:
            data = json.load(f)
        return data["osd"][field]
    except Exception:
        # Fallback: grep
        try:
            with open(filepath) as f:
                txt = f.read()
            m = re.search(r'"' + field + r'":\s*(\d+)', txt)
            return int(m.group(1)) if m else 0
        except:
            return 0

def get_latency_fields(filepath):
    """Extract op_r_latency avgcount and sum."""
    try:
        with open(filepath) as f:
            data = json.load(f)
        lat = data["osd"]["op_r_latency"]
        return lat.get("avgcount", 0), lat.get("sum", 0)
    except:
        return 0, 0

def analyze_run(ra, rw, round_num):
    """Analyze one run: return dict with all metrics."""
    tag = f"ra{ra}-{rw}-r{round_num}"
    fio_file = os.path.join(OUTDIR, f"{tag}-fio.txt")
    nic_file = os.path.join(OUTDIR, f"{tag}-nic.txt")

    # Parse fio output
    read_bw = write_bw = read_io = write_io = None
    iodepth64 = None
    if os.path.exists(fio_file):
        with open(fio_file) as f:
            txt = f.read()
        m = re.search(r'READ:.*bw=([0-9.]+)MiB/s.*io=(\d+)MiB', txt)
        if m:
            read_bw, read_io = float(m.group(1)), int(m.group(2))
        m = re.search(r'WRITE:.*bw=([0-9.]+)MiB/s.*io=(\d+)MiB', txt)
        if m:
            write_bw, write_io = float(m.group(1)), int(m.group(2))
        # IO depth
        m = re.search(r'>=64[=\s]+([0-9.]+)%', txt)
        if m:
            iodepth64 = float(m.group(1))

    # Parse NIC
    nic_rx_mib = None
    if os.path.exists(nic_file):
        with open(nic_file) as f:
            for line in f:
                m = re.match(r'rx_delta_mib=(\S+)', line)
                if m:
                    nic_rx_mib = float(m.group(1))

    # Parse OSD jsons
    osd_read_bytes = 0  # op_r_out_bytes delta sum
    osd_read_ops = 0    # op_r delta sum
    osd_write_bytes = 0 # op_w_in_bytes delta sum
    osd_write_ops = 0   # op_w delta sum
    osd_lat_count = 0   # op_r_latency avgcount delta
    osd_lat_sum = 0.0   # op_r_latency sum delta
    osd_details = []

    for osd in range(6):
        before_file = os.path.join(OUTDIR, f"{tag}-osd{osd}-before.json")
        after_file = os.path.join(OUTDIR, f"{tag}-osd{osd}-after.json")

        if not os.path.exists(before_file) or not os.path.exists(after_file):
            osd_details.append({"osd": osd, "error": "missing"})
            continue

        rb = get_json_field(before_file, "op_r_out_bytes")
        ra_ = get_json_field(after_file, "op_r_out_bytes")
        r_delta = ra_ - rb

        rop_b = get_json_field(before_file, "op_r")
        rop_a = get_json_field(after_file, "op_r")
        rop_delta = rop_a - rop_b

        wb = get_json_field(before_file, "op_w_in_bytes")
        wa = get_json_field(after_file, "op_w_in_bytes")
        w_delta = wa - wb

        wop_b = get_json_field(before_file, "op_w")
        wop_a = get_json_field(after_file, "op_w")
        wop_delta = wop_a - wop_b

        lb_c, lb_s = get_latency_fields(before_file)
        la_c, la_s = get_latency_fields(after_file)
        lat_delta_c = la_c - lb_c
        lat_delta_s = la_s - lb_s

        osd_read_bytes += r_delta
        osd_read_ops += rop_delta
        osd_write_bytes += w_delta
        osd_write_ops += wop_delta
        osd_lat_count += lat_delta_c
        osd_lat_sum += lat_delta_s

        node = {0: "node1", 1: "node1", 2: "node2", 3: "node2", 4: "node3", 5: "node3"}[osd]
        osd_details.append({
            "osd": osd, "node": node,
            "read_bytes": r_delta, "read_ops": rop_delta,
            "write_bytes": w_delta, "write_ops": wop_delta,
            "lat_count": lat_delta_c, "lat_sum": lat_delta_s,
            "lat_avg_ms": (lat_delta_s / lat_delta_c * 1000) if lat_delta_c > 0 else 0,
            "per_op_bytes": (r_delta / rop_delta) if rop_delta > 0 else 0,
        })

    # Calculate amplification
    fio_read_bytes = read_io * 1048576 if read_io else 0
    fio_write_bytes = write_io * 1048576 if write_io else 0
    fio_total_bytes = fio_read_bytes + fio_write_bytes

    backend_read_amp = (osd_read_bytes / fio_read_bytes) if fio_read_bytes > 0 else None
    nic_read_amp = (nic_rx_mib * 1048576 / fio_read_bytes) if (nic_rx_mib and fio_read_bytes > 0) else None
    backend_write_amp = (osd_write_bytes / fio_write_bytes) if fio_write_bytes > 0 else None

    return {
        "ra": ra, "rw": rw, "round": round_num,
        "read_bw": read_bw, "write_bw": write_bw,
        "read_io": read_io, "write_io": write_io,
        "nic_rx_mib": nic_rx_mib,
        "osd_read_bytes": osd_read_bytes,
        "osd_read_bytes_mib": osd_read_bytes / 1048576,
        "osd_read_ops": osd_read_ops,
        "osd_write_bytes": osd_write_bytes,
        "osd_write_bytes_mib": osd_write_bytes / 1048576,
        "osd_write_ops": osd_write_ops,
        "backend_read_amp": backend_read_amp,
        "nic_read_amp": nic_read_amp,
        "backend_write_amp": backend_write_amp,
        "osd_lat_count": osd_lat_count,
        "osd_lat_sum": osd_lat_sum,
        "osd_lat_avg_ms": (osd_lat_sum / osd_lat_count * 1000) if osd_lat_count > 0 else 0,
        "iodepth_ge64": iodepth64,
        "osd_details": osd_details,
    }

# ============================================================
# Analyze all runs
# ============================================================
results = []
for ra in RA_VALUES:
    for rw in WORKLOADS:
        for r in range(1, ROUNDS + 1):
            res = analyze_run(ra, rw, r)
            results.append(res)

# ============================================================
# Print main tables
# ============================================================

print("=" * 80)
print("TABLE 1: Backend amplification vs readahead (randread)")
print("=" * 80)
print(f"{'ra':<10} {'round':<7} {'BW(MiB/s)':<10} {'io(MiB)':<10} {'NIC_RX(MiB)':<12} {'OSD_out(MiB)':<13} {'BE_amp':<8} {'NIC_amp':<8} {'lat(ms)':<8}")
print("-" * 80)
for ra in RA_VALUES:
    for r in range(1, ROUNDS + 1):
        res = [x for x in results if x["ra"] == ra and x["rw"] == "randread" and x["round"] == r][0]
        be = f"{res['backend_read_amp']:.2f}x" if res['backend_read_amp'] else "NA"
        nic = f"{res['nic_read_amp']:.2f}x" if res['nic_read_amp'] else "NA"
        print(f"{ra:<10} {r:<7} {res['read_bw'] or 'NA':<10} {res['read_io'] or 'NA':<10} {res['nic_rx_mib'] or 'NA':<12} {res['osd_read_bytes_mib']:<13.1f} {be:<8} {nic:<8} {res['osd_lat_avg_ms']:<8.1f}")
    # averages
    rs = [x for x in results if x["ra"] == ra and x["rw"] == "randread"]
    avg_bw = sum(x['read_bw'] for x in rs if x['read_bw']) / len(rs)
    avg_be = sum(x['backend_read_amp'] for x in rs if x['backend_read_amp']) / len([x for x in rs if x['backend_read_amp']])
    avg_nic = sum(x['nic_read_amp'] for x in rs if x['nic_read_amp']) / len([x for x in rs if x['nic_read_amp']])
    avg_lat = sum(x['osd_lat_avg_ms'] for x in rs) / len(rs)
    print(f"{ra+' avg':<10} {'':<7} {avg_bw:<10.1f} {'':<10} {'':<12} {'':<13} {f'{avg_be:.2f}x':<8} {f'{avg_nic:.2f}x':<8} {avg_lat:<8.1f}")
    print()

print()
print("=" * 80)
print("TABLE 2: Three workload BW vs readahead (acceptance view)")
print("=" * 80)
print(f"{'ra':<10} {'rw':<12} {'r1_R':<8} {'r1_W':<8} {'r2_R':<8} {'r2_W':<8} {'r3_R':<8} {'r3_W':<8} {'avg_R':<8} {'avg_W':<8} {'total':<8}")
print("-" * 80)
for ra in RA_VALUES:
    for rw in WORKLOADS:
        rs = [x for x in results if x["ra"] == ra and x["rw"] == rw]
        vals = []
        for r in range(1, 4):
            res = [x for x in rs if x["round"] == r]
            if res:
                vals.append((res[0]['read_bw'], res[0]['write_bw']))
            else:
                vals.append((None, None))
        avg_r = sum(x[0] for x in vals if x[0]) / len([x for x in vals if x[0]]) if any(x[0] for x in vals) else 0
        avg_w = sum(x[1] for x in vals if x[1]) / len([x for x in vals if x[1]]) if any(x[1] for x in vals) else 0
        total = avg_r + avg_w
        r1r, r1w = vals[0]
        r2r, r2w = vals[1]
        r3r, r3w = vals[2]
        print(f"{ra:<10} {rw:<12} {r1r or 'NA':<8} {r1w or 'NA':<8} {r2r or 'NA':<8} {r2w or 'NA':<8} {r3r or 'NA':<8} {r3w or 'NA':<8} {avg_r:<8.1f} {avg_w:<8.1f} {total:<8.1f}")
    print()

print()
print("=" * 80)
print("TABLE 3: Backend amplification for randrw (read + write)")
print("=" * 80)
print(f"{'ra':<10} {'round':<7} {'R_BW':<8} {'W_BW':<8} {'R_io':<8} {'W_io':<8} {'OSD_R(MiB)':<11} {'OSD_W(MiB)':<11} {'R_amp':<8} {'W_amp':<8} {'NIC_RX':<10}")
print("-" * 80)
for ra in RA_VALUES:
    for r in range(1, ROUNDS + 1):
        res = [x for x in results if x["ra"] == ra and x["rw"] == "randrw" and x["round"] == r][0]
        r_amp = f"{res['backend_read_amp']:.2f}x" if res['backend_read_amp'] else "NA"
        w_amp = f"{res['backend_write_amp']:.2f}x" if res['backend_write_amp'] else "NA"
        print(f"{ra:<10} {r:<7} {res['read_bw'] or 'NA':<8} {res['write_bw'] or 'NA':<8} {res['read_io'] or 'NA':<8} {res['write_io'] or 'NA':<8} {res['osd_read_bytes_mib']:<11.1f} {res['osd_write_bytes_mib']:<11.1f} {r_amp:<8} {w_amp:<8} {res['nic_rx_mib'] or 'NA':<10}")
    print()

print()
print("=" * 80)
print("TABLE 4: OSD per-node detail (randread r1, for amplification source)")
print("=" * 80)
for ra in RA_VALUES:
    res = [x for x in results if x["ra"] == ra and x["rw"] == "randread" and x["round"] == 1][0]
    print(f"\nra={ra} randread r1: BE_amp={res['backend_read_amp']:.2f}x" if res['backend_read_amp'] else f"\nra={ra} randread r1: BE_amp=NA")
    print(f"  {'osd':<5} {'node':<7} {'read_bytes(MiB)':<16} {'read_ops':<10} {'per_op(KiB)':<12} {'lat(ms)':<8}")
    for d in res['osd_details']:
        if 'error' in d:
            print(f"  {d['osd']:<5} {'ERROR':<7}")
        else:
            print(f"  {d['osd']:<5} {d['node']:<7} {d['read_bytes']/1048576:<16.1f} {d['read_ops']:<10} {d['per_op_bytes']/1024:<12.1f} {d['lat_avg_ms']:<8.1f}")

print()
print("=" * 80)
print("TABLE 5: randwrite backend (op_w_in_bytes) amplification")
print("=" * 80)
print(f"{'ra':<10} {'round':<7} {'W_BW':<8} {'W_io(MiB)':<10} {'OSD_W_in(MiB)':<14} {'W_amp':<8} {'NIC_RX(MiB)':<12}")
print("-" * 80)
for ra in RA_VALUES:
    for r in range(1, ROUNDS + 1):
        res = [x for x in results if x["ra"] == ra and x["rw"] == "randwrite" and x["round"] == r][0]
        w_amp = f"{res['backend_write_amp']:.2f}x" if res['backend_write_amp'] else "NA"
        print(f"{ra:<10} {r:<7} {res['write_bw'] or 'NA':<8} {res['write_io'] or 'NA':<10} {res['osd_write_bytes_mib']:<14.1f} {w_amp:<8} {res['nic_rx_mib'] or 'NA':<12}")
    print()
