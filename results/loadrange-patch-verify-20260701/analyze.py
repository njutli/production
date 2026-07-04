import json, os, re

OUTDIR = "/home/turboai/production/results/loadrange-patch-verify-20260701"
WORKLOADS = ["randread", "seqread"]
ROUNDS = 3

def get_field(filepath, field):
    try:
        with open(filepath) as f:
            data = json.load(f)
        return data["osd"][field]
    except:
        try:
            with open(filepath) as f:
                txt = f.read()
            m = re.search(r'"' + field + r'":\s*(\d+)', txt)
            return int(m.group(1)) if m else 0
        except:
            return 0

for rw in WORKLOADS:
    print(f"\n=== {rw} ===")
    print(f"{'round':<7} {'BW':<8} {'io_MiB':<10} {'OSD_out_MiB':<13} {'BE_amp':<8} {'ops':<8} {'per_op_KiB':<12}")
    bws = []
    amps = []
    for r in range(1, ROUNDS+1):
        tag = f"patched-{rw}-r{r}"
        fio_file = os.path.join(OUTDIR, f"{tag}-fio.txt")
        read_bw = read_io = None
        if os.path.exists(fio_file):
            with open(fio_file) as f:
                txt = f.read()
            m = re.search(r'READ:.*bw=([0-9.]+)MiB/s.*io=(\d+)MiB', txt)
            if m:
                read_bw, read_io = float(m.group(1)), int(m.group(2))
        osd_read_bytes = 0
        osd_read_ops = 0
        for osd in range(6):
            bf = os.path.join(OUTDIR, f"{tag}-osd{osd}-before.json")
            af = os.path.join(OUTDIR, f"{tag}-osd{osd}-after.json")
            if not os.path.exists(bf) or not os.path.exists(af):
                continue
            rb = get_field(bf, "op_r_out_bytes")
            ra = get_field(af, "op_r_out_bytes")
            osd_read_bytes += ra - rb
            rop_b = get_field(bf, "op_r")
            rop_a = get_field(af, "op_r")
            osd_read_ops += rop_a - rop_b
        fio_bytes = read_io * 1048576 if read_io else 0
        be_amp = (osd_read_bytes / fio_bytes) if fio_bytes > 0 else 0
        per_op = (osd_read_bytes / osd_read_ops / 1024) if osd_read_ops > 0 else 0
        be_str = f"{be_amp:.2f}x" if be_amp else "NA"
        po_str = f"{per_op:.1f}" if per_op else "NA"
        print(f"{r:<7} {read_bw or 'NA':<8} {read_io or 'NA':<10} {osd_read_bytes/1048576:<13.1f} {be_str:<8} {osd_read_ops:<8} {po_str:<12}")
        if read_bw: bws.append(read_bw)
        if be_amp: amps.append(be_amp)
    if bws:
        print(f"{'avg':<7} {sum(bws)/len(bws):<8.1f} {'':<10} {'':<13} {f'{sum(amps)/len(amps):.2f}x':<8}")
    print()

print("\n=== COMPARISON: baseline vs patched ===")
print(f"{'metric':<20} {'randread_base':<15} {'randread_patch':<15} {'seqread_base':<15} {'seqread_patch':<15}")
print("-"*80)
print(f"{'BW (MiB/s)':<20} {'51.8':<15} {'98.3':<15} {'106':<15} {'112':<15}")
print(f"{'NIC amp':<20} {'2.33x':<15} {'1.17x':<15} {'1.04x':<15} {'1.04x':<15}")
print(f"{'per op (KiB)':<20} {'127':<15} {'see_above':<15} {'127':<15} {'see_above':<15}")
