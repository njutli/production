#!/usr/bin/env python3
"""r2-analyze.py — R2（挂载档位机制归因）独立分析器

用途：
  1) mount-gear-attrib-test.sh 因组数误算（bash 特殊变量 GROUPS，见脚本头注）被中途 kill 时，
     脚本内嵌的分析段不会执行 —— 用本文件对已采到的组做同样的分析。
  2) 支持三种 IRQ 亲和性来源（157 上 irqbalance active，映射会漂移，优先用时间上最接近的）：
       ① <R>/g<N>/irq-affinity.txt      每组快照（修复版脚本产出）
       ② --trace <file>                 外部追踪器（每 30s 一次，格式见下）
       ③ <R>/irq-affinity.txt           全局单次快照（最差，仅回退用）
     外部追踪器格式：
       === ts=<epoch> <HH:MM:SS>
       <irq> <core>
       ...

用法：
  python3 r2-analyze.py [结果目录] [--trace /tmp/r2-irq-affinity-trace.txt]
  默认结果目录 /tmp/r2-mount-gear-attrib

口径与判据与 FULLBASELINE_V4.sh 一致：逐秒均值(15-175s)；组间极差按 (max-min)/median。
"""
import os
import sys
import glob
import re
import statistics
from collections import defaultdict

R = "/tmp/r2-mount-gear-attrib"
TRACE = None
args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == "--trace":
        TRACE = args[i + 1]; i += 2
    else:
        R = args[i]; i += 1


def is_starved(core):
    try:
        c = int(core)
    except (TypeError, ValueError):
        return False
    return 1 <= c <= 16


def load_affinity_file(path):
    """<R>/…/irq-affinity.txt → (irq→core, starved set)"""
    core, st = {}, set()
    if not os.path.exists(path):
        return core, st
    for line in open(path):
        f = line.split()
        if len(f) < 2 or not f[0].isdigit():
            continue
        core[f[0]] = f[1]
        if (len(f) >= 4 and f[3] == "1") or is_starved(f[1]):
            st.add(f[0])
    return core, st


def load_trace(path):
    """外部追踪器 → [(epoch, {irq: core}), ...] 按时间升序"""
    out = []
    if not path or not os.path.exists(path):
        return out
    ts, cur = None, {}
    for line in open(path, errors="ignore"):
        m = re.match(r"===\s*ts=(\d+)", line)
        if m:
            if ts is not None and cur:
                out.append((ts, cur))
            ts, cur = int(m.group(1)), {}
            continue
        f = line.split()
        if len(f) == 2 and f[0].isdigit():
            cur[f[0]] = f[1]
    if ts is not None and cur:
        out.append((ts, cur))
    out.sort(key=lambda x: x[0])
    return out


def group_ts(gdir):
    """该组的挂载时刻（placement.txt 的 ts=<epoch>）"""
    p = os.path.join(gdir, "placement.txt")
    if os.path.exists(p):
        m = re.search(r"ts=(\d+)", open(p, errors="ignore").read())
        if m:
            return int(m.group(1))
    for f in ("irq-t0.txt", "irq-affinity.txt"):
        q = os.path.join(gdir, f)
        if os.path.exists(q):
            return int(os.path.getmtime(q))
    return None


def per_sec_mean(sub):
    per = defaultdict(float)
    # ⚑ 2026-08-05：只认目录同名 label 前缀，防跨跑残留污染（R2 g1 教训）
    _lb = os.path.basename(sub.rstrip("/"))
    _files = glob.glob(os.path.join(sub, _lb + "_bw.*.log"))
    _stray = [x for x in glob.glob(os.path.join(sub, "*_bw.*.log")) if x not in _files]
    if _stray:
        print("  [warn] %s 忽略 %d 个非本轮 bw log" % (_lb, len(_stray)))
    for f in _files:
        for line in open(f):
            q = line.strip().split(",")
            if len(q) < 3:
                continue
            try:
                s = int(q[0]) // 1000; bw = float(q[1]); d = int(q[2])
            except ValueError:
                continue
            if d == 0:
                per[s] += bw
    if not per:
        return None
    ks = sorted(per); t0 = ks[0]
    w = [per[k] / 1024.0 for k in ks if 15 <= k - t0 <= 175]
    return statistics.mean(w) if w else None


def snap(f):
    d = {}
    if os.path.exists(f):
        for line in open(f):
            q = line.split()
            if len(q) == 2 and q[0].isdigit():
                d[q[0]] = int(q[1])
    return d


def irq_delta(gdir, sub):
    """t0 → tend（tend 缺失则用最后一个 irq-t<N>.txt）"""
    a = snap(os.path.join(gdir, "irq-t0.txt")) or snap(os.path.join(sub, "irq-t0.txt"))
    b = snap(os.path.join(gdir, "irq-tend.txt")) or snap(os.path.join(sub, "irq-tend.txt"))
    if not b:
        cands = []
        for d_ in (gdir, sub):
            for f in glob.glob(os.path.join(d_, "irq-t*.txt")):
                m = re.search(r"irq-t(\d+)\.txt$", f)
                if m and int(m.group(1)) > 0:
                    cands.append((int(m.group(1)), f))
        if cands:
            b = snap(max(cands)[1])
    if not a or not b:
        return None
    return {k: b[k] - a.get(k, 0) for k in b if b[k] - a.get(k, 0) > 0}


def numa_of_threads(gdir, sub):
    n0 = n1 = 0
    for d_ in (gdir, sub):
        f = os.path.join(d_, "sampling.txt")
        if not os.path.exists(f):
            continue
        for line in open(f, errors="ignore"):
            m = re.search(r"node0=(\d+) node1=(\d+)", line)
            if m:
                n0 += int(m.group(1)); n1 += int(m.group(2))
    tot = n0 + n1
    return (100.0 * n1 / tot) if tot else None


trace = load_trace(TRACE)
gl_core, gl_starved = load_affinity_file(os.path.join(R, "irq-affinity.txt"))

print("结果目录: %s" % R)
print("IRQ 亲和性来源: 每组快照优先 / 追踪器 %s（%d 个时间点）/ 全局快照 %d 队列"
      % (TRACE or "未提供", len(trace), len(gl_core)))
print("")

rows = []
for g in range(1, 2000):
    gdir = os.path.join(R, "g%d" % g)
    sub = os.path.join(R, "g%d-r1" % g)
    if not os.path.isdir(sub):
        if g > 30 and not rows:
            break
        if not os.path.isdir(gdir):
            continue
        continue
    if os.path.exists(os.path.join(sub, "INVALID.txt")):
        continue
    bw = per_sec_mean(sub)
    if bw is None:
        continue

    src = "组快照"
    g_core, g_starved = load_affinity_file(os.path.join(gdir, "irq-affinity.txt"))
    if not g_core and trace:
        ts = group_ts(gdir)
        if ts is not None:
            best = min(trace, key=lambda x: abs(x[0] - ts))
            g_core = best[1]
            g_starved = set(k for k, c in best[1].items() if is_starved(c))
            src = "追踪器(Δ%ds)" % abs(best[0] - ts)
    if not g_core:
        g_core, g_starved = gl_core, gl_starved
        src = "全局快照"

    d = irq_delta(gdir, sub) or {}
    tot = sum(d.values())
    st = sum(v for k, v in d.items() if k in g_starved)
    share = 100.0 * st / tot if tot else None
    thr = 0.5 * tot / len(d) if d else 0
    active = sum(1 for v in d.values() if v >= thr)
    acts = sum(1 for k, v in d.items() if k in g_starved and v >= thr)
    top = sorted(d.items(), key=lambda kv: -kv[1])[:5]
    top_s = " ".join("irq%s(c%s%s)=%.1f%%" % (
        k, g_core.get(k, "?"), "*" if k in g_starved else "", 100.0 * v / tot if tot else 0)
        for k, v in top)
    rows.append((g, bw, share, active, acts, numa_of_threads(gdir, sub), top_s, len(g_starved), src))

if not rows:
    print("没有可分析的组（缺 bw log）")
    sys.exit(0)

print("组   逐秒均值   饥饿队列中断占比   活跃队列数  其中饥饿  线程node1占比  本组饥饿队列数  亲和性来源")
for g, bw, share, active, acts, n1, top_s, nst, src in rows:
    print("g%-3d %8.0f %14s %12d %9d %13s %13d  %s" % (
        g, bw, "%.2f%%" % share if share is not None else "NA",
        active, acts, "%.0f%%" % n1 if n1 is not None else "NA", nst, src))

print("")
print("各组中断量 top5 队列（c=绑定核，* = 落在被外部租户占满的 core 1-16）：")
for r_ in rows:
    print("  g%-3d %s" % (r_[0], r_[6]))

bws = [r[1] for r in rows]
med = statistics.median(bws)
rng = (max(bws) - min(bws)) / med * 100
print("")
print("组间: n=%d median=%.0f 极差幅度=%.1f%% range=%.0f-%.0f" % (len(bws), med, rng, min(bws), max(bws)))

have = [r for r in rows if r[2] is not None]
if len(have) >= 4:
    lo = [r for r in have if r[1] < med]
    hi = [r for r in have if r[1] >= med]
    sl = statistics.mean([r[2] for r in lo]) if lo else 0.0
    sh = statistics.mean([r[2] for r in hi]) if hi else 0.0
    xs = [r[2] for r in have]; ys = [r[1] for r in have]
    mx = statistics.mean(xs); my = statistics.mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den = (sum((x - mx) ** 2 for x in xs) * sum((y - my) ** 2 for y in ys)) ** 0.5
    r_p = num / den if den else 0.0
    print("低档组(<median) 饥饿占比均值=%.2f%%  高档组=%.2f%%  Pearson r(BW,饥饿占比)=%.2f" % (sl, sh, r_p))
    print("")
    if rng <= 5:
        print("判定: 未复现多档（极差 %.1f%% ≤5%%）⇒ R1 的分散可能含当日外部租户瞬态，需重复 R1" % rng)
    elif r_p <= -0.6 and sl > sh:
        print("判定: 机制定案 —— RSS/IRQ 饥饿（r=%.2f，低档组饥饿占比 %.2f%% > 高档组 %.2f%%）" % (r_p, sl, sh))
        print("      解法候选（按侵入性从低到高，均需另行授权）：")
        print("      ① irqbalance 设 IRQBALANCE_BANNED_CPUS 禁用 core 1-16（根因：irqbalance 正把中断搬到满载核）")
        print("      ② 开 RPS 把收包软中断搬到空闲核（rx-*/rps_cpus，可回滚）")
        print("      ③ 静态钉 IRQ 亲和到 core>=17 并停 irqbalance（否则会被搬回）")
    elif abs(r_p) < 0.15:
        print("判定: 🔴 主假设被否证 —— 与饥饿队列无相关（r=%.2f，低档 %.2f%% vs 高档 %.2f%% 差异 <1pp）" % (r_p, sl, sh))
        print("      ⇒ 不再追机制；改走 R3 档位甄别协议（探针筛高档实例）拿可签收基线")
    elif sl > sh:
        print("判定: 方向一致但相关弱（r=%.2f）⇒ 饥饿队列是部分因素，另有共因；看 sampling.txt 的 %%soft 与 ss rtt" % r_p)
    else:
        print("判定: 与饥饿队列无关（r=%.2f）⇒ 转候选：线程落核/内存首触 NUMA、Go runtime 一次性初始化" % r_p)

nu = 1 if os.path.exists(os.path.join(R, "UNCLEAN_UMOUNT.txt")) else 0
md5 = set(open(f).read().strip() for f in glob.glob(os.path.join(R, "g*-r1", "config-md5.txt")))
uf = set(open(f).read().strip() for f in glob.glob(os.path.join(R, "g*-r1", "up_from.txt")))
inv = len(glob.glob(os.path.join(R, "g*-r1", "INVALID.txt")))
ok = (nu == 0 and len(md5) <= 1 and len(uf) <= 1 and inv == 0)
print("")
print("GUARD: 非优雅卸载=%d  config-md5种类=%d  up_from种类=%d  INVALID轮=%d  %s"
      % (nu, len(md5), len(uf), inv, "OK" if ok else "FAIL"))
