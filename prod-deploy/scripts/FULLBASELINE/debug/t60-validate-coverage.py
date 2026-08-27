#!/usr/bin/env python3
"""t60-validate-coverage.py - Coverage validator for 03-20B-R1
Usage:
  python3 t60-validate-coverage.py --preflight <dir> <fio_start_epoch>
  python3 t60-validate-coverage.py --formal <dir> <fio_start_epoch>
  python3 t60-validate-coverage.py --help
"""
import sys, os, argparse, glob

def count_valid_lines(filepath, ts_col=0, min_ts=None, max_ts=None):
    """Count lines where column ts_col is a valid integer in [min_ts, max_ts]."""
    if not os.path.exists(filepath):
        return 0, []
    ts_list = []
    with open(filepath) as f:
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) <= ts_col:
                continue
            try:
                ts = int(parts[ts_col])
                if min_ts is not None and ts < min_ts:
                    continue
                if max_ts is not None and ts > max_ts:
                    continue
                ts_list.append(ts)
            except ValueError:
                continue
    return len(ts_list), ts_list

def max_gap(ts_list):
    if len(ts_list) < 2:
        return 0
    gaps = [ts_list[i+1] - ts_list[i] for i in range(len(ts_list)-1)]
    return max(gaps) if gaps else 0

def coverage_pct(n, expected):
    return 100.0 * n / expected if expected > 0 else 0

def validate(args):
    out = args.dir
    start = int(args.fio_start_epoch)
    is_preflight = args.preflight
    is_formal = args.formal

    if is_preflight:
        # Check 120s preflight: start to start+120 (samples collected during validation)
        w_start = start
        w_end = start + 120
        windows = [("preflight_120s", w_start, w_end, 120)]
    else:
        # Formal windows
        windows = [
            ("W1", start+15, start+55, 40),
            ("W2", start+55, start+95, 40),
            ("W3", start+95, start+135, 40),
            ("W4", start+135, start+175, 40),
        ]

    results = []
    all_pass = True

    tikv_ips = ["10.20.1.150", "10.20.1.151", "10.20.1.152"]

    for wname, w_start, w_end, expected in windows:
        # Device coverage per node
        for ip in tikv_ips:
            for stype in ["tikv-device", "tikv-host"]:
                f = os.path.join(out, "samplers", f"{stype}-{ip}.tsv")
                n, ts_list = count_valid_lines(f, 0, w_start, w_end)
                mg = max_gap(ts_list)
                pct = coverage_pct(n, expected)
                thresh = 95 if "device" in stype or "host" in stype else 90
                gap_thresh = 2 if "device" in stype or "host" in stype else 6
                ok = pct >= thresh and mg <= gap_thresh
                if not ok:
                    all_pass = False
                results.append(f"{wname}\t{stype}-{ip}\t{n}/{expected}\t{pct:.1f}%\tmaxgap={mg}s\t{'PASS' if ok else 'FAIL'}")

        # TiKV metrics per node
        for ip in tikv_ips:
            f = os.path.join(out, "samplers", f"tikv-metrics-{ip}.tsv")
            n, ts_list = count_valid_lines(f, 0, w_start, w_end)
            mg = max_gap(ts_list)
            pct = coverage_pct(n, expected // 5)  # 5s interval
            ok = pct >= 90 and mg <= 6
            if not ok:
                all_pass = False
            results.append(f"{wname}\ttikv-metrics-{ip}\t{n}/{expected//5}\t{pct:.1f}%\tmaxgap={mg}s\t{'PASS' if ok else 'FAIL'}")

        # Client
        for stype in ["client-runtime", "client-host"]:
            f = os.path.join(out, "samplers", f"{stype}.tsv")
            n, ts_list = count_valid_lines(f, 0, w_start, w_end)
            mg = max_gap(ts_list)
            pct = coverage_pct(n, expected)
            ok = pct >= 95 and mg <= 2
            if not ok:
                all_pass = False
            results.append(f"{wname}\t{stype}\t{n}/{expected}\t{pct:.1f}%\tmaxgap={mg}s\t{'PASS' if ok else 'FAIL'}")

        # Pool (15s interval)
        f = os.path.join(out, "samplers", "pool.tsv")
        n, _ = count_valid_lines(f, 0, w_start, w_end)
        pct = coverage_pct(n, expected // 15)
        ok = pct >= 80
        if not ok:
            all_pass = False
        results.append(f"{wname}\tpool\t{n}/{expected//15}\t{pct:.1f}%\t{'PASS' if ok else 'FAIL'}")

    # Check errors (ignore locale warnings)
    err_files = glob.glob(os.path.join(out, "samplers", "*.errors.tsv"))
    total_errors = 0
    for ef in err_files:
        with open(ef) as f:
            for line in f:
                if 'setlocale' in line or 'LC_ALL' in line or 'locale' in line:
                    continue
                total_errors += 1
    if total_errors > 0:
        all_pass = False
        results.append(f"errors\ttotal\t{total_errors}\t\tFAIL")
    else:
        results.append("errors\ttotal\t0\t\tPASS")

    # Output
    for r in results:
        print(r)

    # Write to file
    cov_file = os.path.join(out, "coverage.tsv" if is_formal else "preflight/coverage.tsv")
    os.makedirs(os.path.dirname(cov_file), exist_ok=True)
    with open(cov_file, 'w') as f:
        for r in results:
            f.write(r + '\n')
    with open(os.path.join(out, "coverage.log"), 'a') as f:
        f.write(f"=== {'preflight' if is_preflight else 'formal'} ===\n")
        for r in results:
            f.write(r + '\n')

    print(f"\nOVERALL: {'PASS' if all_pass else 'FAIL'}")
    return 0 if all_pass else 1

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    g = parser.add_mutually_exclusive_group(required=True)
    g.add_argument('--preflight', action='store_true')
    g.add_argument('--formal', action='store_true')
    parser.add_argument('dir', help='Output directory')
    parser.add_argument('fio_start_epoch', help='fio start epoch (unix seconds)')
    args = parser.parse_args()
    sys.exit(validate(args))
