#!/usr/bin/env python3
"""03-1 probe cross-validation: compute Pearson r + Spearman rho from bw logs."""
import glob, statistics as st, math, os, sys

V4_RESULTS = "/tmp/opencode-fullbaseline-v4"
NUM = 8
LO, HI = 15, 175

def bw_mean(subdir, direction):
    per = {}
    for f in glob.glob(subdir + "/*_bw.*.log"):
        for line in open(f):
            p = line.split(',')
            if len(p) < 3: continue
            if int(p[2]) != direction: continue
            t = int(p[0]) // 1000
            per[t] = per.get(t, 0.0) + float(p[1]) / 1024.0
    if not per:
        return None
    t0 = min(per)
    vals = [per[k] for k in sorted(per) if LO <= k - t0 <= HI]
    return st.mean(vals) if vals else None

def pearson(x, y):
    n = len(x)
    mx, my = sum(x)/n, sum(y)/n
    sxy = sum((xi-mx)*(yi-my) for xi,yi in zip(x,y))
    sxx = sum((xi-mx)**2 for xi in x)
    syy = sum((yi-my)**2 for yi in y)
    if sxx == 0 or syy == 0: return float('nan')
    return sxy / math.sqrt(sxx * syy)

def spearman(x, y):
    rx = [sorted(x).index(v)+1 for v in x]
    ry = [sorted(y).index(v)+1 for v in y]
    return pearson(rx, ry)

rows = []
for i in range(1, NUM+1):
    label = f"X{i}"
    # randread r1 (direction=0)
    rr_dir = f"{V4_RESULTS}/{label}/randread-{label}-r1"
    rr = bw_mean(rr_dir, 0)
    # mseqwrite r1, r2 (direction=1)
    mw_r1 = bw_mean(f"{V4_RESULTS}/{label}/mseqwrite-{label}-r1", 1)
    mw_r2 = bw_mean(f"{V4_RESULTS}/{label}/mseqwrite-{label}-r2", 1)
    mw_vals = [v for v in [mw_r1, mw_r2] if v is not None]
    mw_med = st.median(mw_vals) if mw_vals else None
    mw_range = ((max(mw_vals)-min(mw_vals))/mw_med*100) if len(mw_vals)==2 and mw_med else None
    rows.append((label, rr, mw_r1, mw_r2, mw_med, mw_range))

print("=" * 100)
print(f"{'Inst':<6} {'randread':>10} {'mseq_r1':>10} {'mseq_r2':>10} {'mseq_med':>10} {'r1r2极差%':>10}")
print("-" * 100)
for label, rr, mw1, mw2, mwm, rng in rows:
    def fmt(v): return f"{v:.1f}" if v is not None else "N/A"
    def fmtp(v): return f"{v:.1f}%" if v is not None else "N/A"
    print(f"{label:<6} {fmt(rr):>10} {fmt(mw1):>10} {fmt(mw2):>10} {fmt(mwm):>10} {fmtp(rng):>10}")
print("=" * 100)

rr_vals = [r[1] for r in rows if r[1] is not None]
mw_vals = [r[4] for r in rows if r[4] is not None]
n = min(len(rr_vals), len(mw_vals))
rr_fit = rr_vals[:n]
mw_fit = mw_vals[:n]

if n >= 3:
    r = pearson(rr_fit, mw_fit)
    rho = spearman(rr_fit, mw_fit)
    print(f"\nn={n}  Pearson r={r:.4f}  Spearman rho={rho:.4f}")

    rr_min, rr_max = min(rr_fit), max(rr_fit)
    rr_range = (rr_max - rr_min) / st.median(rr_fit) * 100
    hi_count = sum(1 for v in rr_fit if 1830 <= v <= 1930)
    print(f"\nrandread range: {rr_min:.1f} - {rr_max:.1f} (极差 {rr_range:.1f}%)")
    print(f"高档带 [1830,1930] 命中: {hi_count}/{n}")
    mw_ranges = [r[5] for r in rows if r[5] is not None]
    if mw_ranges:
        print(f"mseqwrite 轮间极差: {min(mw_ranges):.1f}% - {max(mw_ranges):.1f}% (all <=6.3%: {all(v<=6.3 for v in mw_ranges)})")
else:
    print(f"\n只有 {n} 个有效点，不足以计算相关系数")
