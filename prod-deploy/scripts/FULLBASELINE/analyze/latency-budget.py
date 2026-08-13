#!/usr/bin/env python3
"""latency-budget.py — 跨层延迟预算提取器

把 FULLBASELINE_V4 每轮已采但从未挖掘的数据（jfs-stats pre/post、fio.txt、nic.txt）
加上 instrument.sh 的 I1-I4，提取成一张分层瓶颈定位表。

用法:
    python3 latency-budget.py <V4_RESULTS_ROOT> [LABEL ...] [--instr <INSTR_DIR>] [--tsv out.tsv]

例:
    python3 latency-budget.py /tmp/opencode-fullbaseline-v4 T36-A1 T36-B1 --instr /tmp/opencode-t3.6

判据纪律（03 计划 §14.2）:
  - 吞吐一律取 fio 汇总 READ/WRITE 行，不用 PROGRESS.txt
  - perf dump / .stats 全是累计计数器，必须 post-pre 取增量
  - 放大率是档位免疫指标（跨 8 实例 CV 0.04-0.94%），吞吐不是（跨实例极差 29.9%）
"""
import os, re, sys, json, glob, statistics as st

MiB = 1024 ** 2
KEYS = [
    "juicefs_fuse_ops_durations_histogram_seconds_sum", "juicefs_fuse_ops_durations_histogram_seconds_total",
    "juicefs_fuse_ops_total_read", "juicefs_fuse_ops_total_write",
    "juicefs_fuse_read_size_bytes_sum", "juicefs_fuse_write_size_bytes_sum",
    "juicefs_meta_ops_durations_histogram_seconds_sum", "juicefs_meta_ops_durations_histogram_seconds_total",
    "juicefs_object_request_durations_histogram_seconds_GET_sum", "juicefs_object_request_durations_histogram_seconds_GET_total",
    "juicefs_object_request_durations_histogram_seconds_PUT_sum", "juicefs_object_request_durations_histogram_seconds_PUT_total",
    "juicefs_object_request_data_bytes_GET", "juicefs_object_request_data_bytes_PUT",
    "juicefs_process_cpu_seconds_total", "juicefs_used_buffer_size_bytes",
    "juicefs_used_read_buffer_size_bytes", "juicefs_staging_blocks",
]
U = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}


def parse_stats(p):
    d = {}
    try:
        for ln in open(p, errors="ignore"):
            f = ln.split()
            if len(f) == 2 and f[0] in KEYS:
                try:
                    d[f[0]] = float(f[1])
                except ValueError:
                    pass
    except OSError:
        pass
    return d


def parse_fio(p):
    o = {"rbw": 0.0, "wbw": 0.0, "rio": 0.0, "wio": 0.0, "clat_us": 0.0, "slat_us": 0.0, "sec": 0.0}
    try:
        t = open(p, errors="ignore").read()
    except OSError:
        return o
    for tag, kb, ki in (("READ", "rbw", "rio"), ("WRITE", "wbw", "wio")):
        m = re.search(r'^\s+%s: bw=([0-9.]+)MiB/s.*?io=([0-9.]+)([KMGT])iB.*?run=(\d+)-' % tag, t, re.M)
        if m:
            o[kb] = float(m.group(1))
            o[ki] = float(m.group(2)) * U[m.group(3)]
            o["sec"] = max(o["sec"], int(m.group(4)) / 1000.0)
    for key, name in (("clat_us", "clat"), ("slat_us", "slat")):
        m = re.search(r'\s+%s \((usec|msec|nsec)\).*?avg=\s*([0-9.]+)' % name, t)
        if m:
            v = float(m.group(2))
            o[key] = v * (1000.0 if m.group(1) == "msec" else (1e-3 if m.group(1) == "nsec" else 1.0))
    return o


def nic_delta(p):
    ts, rx, tx = [], [], []
    try:
        for ln in open(p, errors="ignore"):
            if "|" not in ln:
                continue
            a, b = ln.split("|", 1)
            f = b.split()
            if len(f) < 10:
                continue
            try:
                ts.append(int(a.strip())); rx.append(int(f[1])); tx.append(int(f[9]))
            except ValueError:
                pass
    except OSError:
        return (0.0, 0.0, 0.0, 0, 0)
    if len(ts) < 3:
        return (0.0, 0.0, 0.0, 0, 0)

    def steady(v):
        r = [(v[i] - v[i - 1]) / (ts[i] - ts[i - 1]) for i in range(1, len(ts)) if ts[i] > ts[i - 1]]
        if not r:
            return 0.0
        mx = max(r)
        s = [x for x in r if x > 0.5 * mx]
        return st.median(s) if s else 0.0
    return (steady(rx) / MiB, steady(tx) / MiB, float(ts[-1] - ts[0]), ts[0], ts[-1])


def osd_lat(instr, tag):
    """I4: 6 OSD 聚合 op 延迟增量（avgcount/sum 对，单位 s）"""
    out = {}
    for k, path in (("op_r", "op_r_latency"), ("op_w", "op_w_latency"),
                    ("sub_w", "subop_w_latency"), ("commit", "op_w_process_latency")):
        cnt = tot = 0.0
        for i in range(6):
            try:
                a = json.load(open(os.path.join(instr, f"i4-osdperf-{tag}-pre-osd{i}.json")))
                b = json.load(open(os.path.join(instr, f"i4-osdperf-{tag}-post-osd{i}.json")))
            except Exception:
                continue
            for src, sign in ((b, 1), (a, -1)):
                o = src.get("osd", {}).get(path)
                if isinstance(o, dict):
                    cnt += sign * o.get("avgcount", 0)
                    tot += sign * o.get("sum", 0)
        out[k] = (tot / cnt * 1e6) if cnt > 0 else float("nan")
        out[k + "_n"] = cnt
    return out


def _win(t, w):
    """w=(t0,t1) 时间窗过滤；w 为 None 时不过滤"""
    return w is None or (w[0] <= t <= w[1])


def i1_peaks(instr, tag, w=None):
    f = os.path.join(instr, f"i1-jfsstats-{tag}.tsv")
    pk = {}
    try:
        for ln in open(f, errors="ignore"):
            p = ln.rstrip("\n").split("\t")
            if len(p) != 3 or p[0] == "ts":
                continue
            try:
                t = int(p[0]); v = float(p[2])
            except ValueError:
                continue
            if not _win(t, w):
                continue
            pk[p[1]] = max(pk.get(p[1], 0.0), v)
    except OSError:
        return {}
    if not pk:
        return {}
    return {"buf_peak_MiB": pk.get("juicefs_used_buffer_size_bytes", 0) / MiB,
            "rbuf_peak_MiB": pk.get("juicefs_used_read_buffer_size_bytes", 0) / MiB,
            "uploading_peak": pk.get("juicefs_object_request_uploading", 0)}


def i3_rtt(instr, tag, w=None):
    f = os.path.join(instr, f"i3-tikv-rtt-{tag}.txt")
    v = []
    try:
        for ln in open(f, errors="ignore"):
            m = re.search(r'^\[(\d+)\.\d+\].*time=([0-9.]+) ms', ln)
            if m:
                if not _win(int(m.group(1)), w):
                    continue
                v.append(float(m.group(2)))
            elif w is None:
                m2 = re.search(r'time=([0-9.]+) ms', ln)
                if m2:
                    v.append(float(m2.group(1)))
    except OSError:
        return {}
    if not v:
        return {}
    v.sort()
    return {"rtt_p50": v[len(v) // 2], "rtt_p99": v[min(len(v) - 1, int(len(v) * 0.99))],
            "rtt_max": v[-1], "rtt_n": len(v)}


def i3_mgmt(instr, tag, w=None):
    """管理网(10GbE, TiKV 元数据) vs public(100GbE, 数据面) 流量占比"""
    rows = []
    try:
        for ln in open(os.path.join(instr, f"i3-net-{tag}.tsv"), errors="ignore"):
            p = ln.split()
            if len(p) < 5 or p[0] == "ts":
                continue
            try:
                t = int(p[0])
                if not _win(t, w):
                    continue
                rows.append(tuple(int(x) for x in p[:5]))
            except ValueError:
                pass
    except OSError:
        return {}
    if len(rows) < 3:
        return {}
    dt = rows[-1][0] - rows[0][0]
    if dt <= 0:
        return {}
    return {"mgmt_rx_MiBs": (rows[-1][3] - rows[0][3]) / dt / MiB,
            "mgmt_tx_MiBs": (rows[-1][4] - rows[0][4]) / dt / MiB,
            "pub_rx_MiBs": (rows[-1][1] - rows[0][1]) / dt / MiB,
            "pub_tx_MiBs": (rows[-1][2] - rows[0][2]) / dt / MiB}


def i2_cores(instr, tag, w=None):
    """i2-proc-<TAG>.tsv 表头驱动解析。
    2026-08-12 起表头为 ts pid utime stime num_threads rss_kb（新增 pid 列）；
    兼容旧格式 ts utime stime num_threads rss_kb。跨 pid 边界的差分丢弃（remount 会重置 utime）。"""
    f = os.path.join(instr, f"i2-proc-{tag}.tsv")
    rows = []
    cols = None
    try:
        for ln in open(f, errors="ignore"):
            p = ln.split()
            if not p:
                continue
            if p[0] == "ts":
                cols = p
                continue
            try:
                t = int(p[0])
                if not _win(t, w):
                    continue
                if cols and "pid" in cols:
                    rows.append((t, p[1], int(p[2]) + int(p[3])))
                else:
                    rows.append((t, "NA", int(p[1]) + int(p[2])))
            except (ValueError, IndexError):
                pass
    except OSError:
        return {}
    if len(rows) < 5:
        return {}
    HZ = 100.0
    r = []
    for i in range(1, len(rows)):
        if rows[i][1] != rows[i - 1][1]:      # pid 变化（remount）⇒ 该差分无意义
            continue
        dt = rows[i][0] - rows[i - 1][0]
        if dt <= 0:
            continue
        v = (rows[i][2] - rows[i - 1][2]) / HZ / dt
        if v >= 0:
            r.append(v)
    if not r:
        return {}
    return {"cores_med": st.median(r), "cores_p95": sorted(r)[int(len(r) * 0.95)], "cores_max": max(r),
            "pid_changes": float(len({x[1] for x in rows}) - 1)}


def collect(root, labels, instr):
    out = []
    for run in sorted(os.listdir(root)):
        d = os.path.join(root, run)
        if not os.path.isdir(d):
            continue
        if labels and run not in labels:
            continue
        for sub in sorted(os.listdir(d)):
            m = re.match(r'^([a-z]+)-' + re.escape(run) + r'-r(\d+)$', sub)
            if not m:
                continue
            item, rnd = m.group(1), int(m.group(2))
            sd = os.path.join(d, sub)
            f = parse_fio(os.path.join(sd, "fio.txt"))
            if f["rbw"] + f["wbw"] <= 0:
                continue
            a = parse_stats(os.path.join(sd, "jfs-stats-pre.txt"))
            b = parse_stats(os.path.join(sd, "jfs-stats-post.txt"))
            D = {k: b.get(k, 0) - a.get(k, 0) for k in KEYS}
            RX, TX, win, t0, t1 = nic_delta(os.path.join(sd, "nic.txt"))
            sec = f["sec"] or win or 180.0
            r = dict(label=run, item=item, round=rnd, sec=sec,
                     rbw=f["rbw"], wbw=f["wbw"], eff=f["rbw"] + f["wbw"],
                     eff_r=f["rbw"], eff_w=f["wbw"],
                     clat_us=f["clat_us"], slat_us=f["slat_us"], nic_rx=RX, nic_tx=TX)

            def rat(n, dn):
                return n / dn if dn else float("nan")
            r["fuse_rd"] = D["juicefs_fuse_ops_total_read"]
            r["fuse_wr"] = D["juicefs_fuse_ops_total_write"]
            r["fuse_rdsz"] = rat(D["juicefs_fuse_read_size_bytes_sum"], D["juicefs_fuse_ops_total_read"])
            r["fuse_wrsz"] = rat(D["juicefs_fuse_write_size_bytes_sum"], D["juicefs_fuse_ops_total_write"])
            r["fuse_lat"] = rat(D["juicefs_fuse_ops_durations_histogram_seconds_sum"],
                                D["juicefs_fuse_ops_durations_histogram_seconds_total"]) * 1e6
            r["meta_n"] = D["juicefs_meta_ops_durations_histogram_seconds_total"]
            r["meta_lat"] = rat(D["juicefs_meta_ops_durations_histogram_seconds_sum"],
                                D["juicefs_meta_ops_durations_histogram_seconds_total"]) * 1e6
            r["get_n"] = D["juicefs_object_request_durations_histogram_seconds_GET_total"]
            r["get_lat"] = rat(D["juicefs_object_request_durations_histogram_seconds_GET_sum"],
                               D["juicefs_object_request_durations_histogram_seconds_GET_total"]) * 1e6
            r["put_n"] = D["juicefs_object_request_durations_histogram_seconds_PUT_total"]
            r["put_lat"] = rat(D["juicefs_object_request_durations_histogram_seconds_PUT_sum"],
                               D["juicefs_object_request_durations_histogram_seconds_PUT_total"]) * 1e6
            r["amp_rx"] = rat(RX, f["rbw"])
            r["amp_tx"] = rat(TX, f["wbw"])
            r["amp_jfs_get"] = rat(D["juicefs_object_request_data_bytes_GET"], f["rio"])
            r["amp_jfs_put"] = rat(D["juicefs_object_request_data_bytes_PUT"], f["wio"])
            r["inflight_get"] = r["get_n"] / sec * (r["get_lat"] / 1e6) if r["get_lat"] == r["get_lat"] else float("nan")
            r["inflight_put"] = r["put_n"] / sec * (r["put_lat"] / 1e6) if r["put_lat"] == r["put_lat"] else float("nan")
            r["inflight_meta"] = r["meta_n"] / sec * (r["meta_lat"] / 1e6) if r["meta_lat"] == r["meta_lat"] else float("nan")
            r["cores"] = D["juicefs_process_cpu_seconds_total"] / sec
            if instr:
                # 优先按轮次标签取；缺失则按 LABEL 标签取并用该轮 nic.txt 时间窗切片
                per_round = f"{item}-{run}-r{rnd}"
                if glob.glob(os.path.join(instr, f"*-{per_round}*")):
                    tag, w = per_round, None
                else:
                    tag, w = run, ((t0, t1) if t1 > t0 else None)
                r["instr_tag"] = tag
                for src in (osd_lat(instr, tag), i1_peaks(instr, tag, w),
                            i3_rtt(instr, tag, w), i3_mgmt(instr, tag, w), i2_cores(instr, tag, w)):
                    r.update(src)
            out.append(r)
    return out


def agg(rows, key):
    v = [x[key] for x in rows if key in x and isinstance(x[key], float) and x[key] == x[key]]
    return st.median(v) if v else float("nan")


def main():
    args = [a for a in sys.argv[1:]]
    if not args:
        print(__doc__)
        return 2
    root = args[0]
    labels, instr, tsv = [], None, None
    i = 1
    while i < len(args):
        if args[i] == "--instr":
            instr = args[i + 1]; i += 2
        elif args[i] == "--tsv":
            tsv = args[i + 1]; i += 2
        else:
            labels.append(args[i]); i += 1
    rows = collect(root, labels, instr)
    if not rows:
        print("未解析到任何轮次，检查路径/LABEL")
        return 1
    print(f"解析 {len(rows)} 轮  root={root}  labels={labels or 'ALL'}  instr={instr or 'None'}\n")
    groups = {}
    for r in rows:
        groups.setdefault((r["label"], r["item"]), []).append(r)

    # 遵循 TASK-BOOK-AUTHORING-GUIDE §二.1：randrw 的 R/W 分开报，不合计
    # （读=入向吃 RX、写=出向吃 TX，100GbE 全双工各向独立，各自对 6250 MiB/s 验收线）
    H = (f"{'label':10} {'item':10} {'n':>2} {'有效读':>8} {'有效写':>8} {'FUSE尺寸':>9} {'FUSE延迟':>9} "
         f"{'GET延迟':>9} {'PUT延迟':>9} {'meta延迟':>10} {'GET/IO':>7} {'RX放大':>7} {'TX放大':>7} "
         f"{'在飞GET':>8} {'在飞meta':>9} {'核数':>6}")
    print(H); print("-" * len(H))
    for (lab, item), g in sorted(groups.items()):
        print(f"{lab:10} {item:10} {len(g):2} {agg(g,'eff_r'):8.0f} {agg(g,'eff_w'):8.0f} {agg(g,'fuse_rdsz'):8.0f}B "
              f"{agg(g,'fuse_lat'):8.0f}u {agg(g,'get_lat'):8.0f}u {agg(g,'put_lat'):8.0f}u "
              f"{agg(g,'meta_lat'):9.0f}u {agg(g,'get_n')/max(1,agg(g,'fuse_rd')):7.2f} "
              f"{agg(g,'amp_rx'):7.2f} {agg(g,'amp_tx'):7.2f} {agg(g,'inflight_get'):8.0f} "
              f"{agg(g,'inflight_meta'):9.0f} {agg(g,'cores'):6.2f}")

    extra = ["op_r", "op_w", "buf_peak_MiB", "rbuf_peak_MiB", "rtt_p50", "rtt_p99", "cores_p95", "mgmt_rx_MiBs"]
    if any(k in rows[0] for k in extra):
        print(f"\n{'label':10} {'item':10} {'OSD读延迟':>10} {'OSD写延迟':>10} {'buffer峰':>9} "
              f"{'读buffer峰':>11} {'RTT_p50':>8} {'RTT_p99':>8} {'核数p95':>8} {'管理网RX':>9} {'管理网TX':>9}")
        for (lab, item), g in sorted(groups.items()):
            print(f"{lab:10} {item:10} {agg(g,'op_r'):9.0f}u {agg(g,'op_w'):9.0f}u "
                  f"{agg(g,'buf_peak_MiB'):8.1f}M {agg(g,'rbuf_peak_MiB'):10.1f}M "
                  f"{agg(g,'rtt_p50'):7.3f}m {agg(g,'rtt_p99'):7.3f}m {agg(g,'cores_p95'):8.2f} "
                  f"{agg(g,'mgmt_rx_MiBs'):8.2f}M {agg(g,'mgmt_tx_MiBs'):8.2f}M")

    if tsv:
        cols = sorted({k for r in rows for k in r})
        with open(tsv, "w") as fh:
            fh.write("\t".join(cols) + "\n")
            for r in rows:
                fh.write("\t".join(str(r.get(c, "")) for c in cols) + "\n")
        print(f"\n逐轮 TSV 已写入 {tsv}（{len(rows)} 行 × {len(cols)} 列）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
