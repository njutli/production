#!/usr/bin/env python3
"""U141b analyzer: per-job BW resample -> formal window -> W1..W4 -> paired effect + noise floor.

Implements skills/EVIDENCE-INTEGRITY-SKILL.md §1 and §2 verbatim:
  * actual timed-I/O start = fio completion time - run= actual milliseconds
  * interval-overlap weighted resampling of --log_avg_msec interval-average logs
  * per-second sum over jobs, dropping seconds with incomplete job coverage
  * formal window [15,175) + W1..W4 (40s each) + W4/W1 + per-second CV
  * paired effect over ABBA-BAAB, noise floor from same-arm adjacent pairs
  * decision boundary M = max(engineering_bound, 2*eps)   -- NEVER preset

NO network / mount / ceph / juicefs access.  Pure offline computation.

Subcommands
-----------
  selftest                     synthetic fixtures (D01/D02/D17 assertions)
  round   <round_dir>          analyze one V4 round directory
  fixture <dir> [--tol 2.0]    self-prove against a historical archive (§5.0.2)
  matrix  <run_root>           full 32-round matrix -> effect sizes + verdict
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from collections import defaultdict

# ---------------------------------------------------------------- constants

FORMAL_START = 15.0
FORMAL_END = 175.0
WINDOWS = [("W1", 15.0, 55.0), ("W2", 55.0, 95.0), ("W3", 95.0, 135.0), ("W4", 135.0, 175.0)]
KIB_PER_MIB = 1024.0

# ABBA-BAAB, frozen.  index = round number (1-based).
ARM_ORDER = ["V13", "V14", "V14", "V13", "V14", "V13", "V13", "V14"]
CROSS_PAIRS = [(1, 2), (4, 3), (6, 5), (7, 8)]   # (V13 round, V14 round)
SAME_ARM_PAIRS = [(2, 3), (6, 7)]                #真值恒为 0
ENGINEERING_BOUND = 3.0                          # percent

# Item tolerance tiers, calibrated on the 08-25 V141 archives.
#   STRICT   : per-second CV <7% -> formal median must track the summary closely
#   MODERATE : mseqwrite runs at CV 12-13% and W4/W1 can exceed 1, so neither a
#              2% tolerance nor a monotonic-decay assertion is valid for it
#   DECAY    : strong in-run decay -> assert W1>W4 and W4/W1 in (0,1] instead
STRICT_ITEMS = {"seqread", "mseqread", "randread", "seqwrite"}
MODERATE_ITEMS = {"mseqwrite"}
MODERATE_TOL = 8.0
DECAY_ITEMS = {"randwrite", "randrw"}


class GateFail(Exception):
    pass


# ---------------------------------------------------------------- fio text

_RE_RUN = re.compile(r"run=(\d+)-(\d+)msec")
_RE_DONE = re.compile(
    r"pid=\d+:\s+\w{3}\s+(\w{3})\s+(\d+)\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})"
)
_RE_BW = re.compile(r"^\s*(READ|WRITE):\s+bw=([0-9.]+)([KMG]i?B)/s", re.M)
_MONTHS = {m: i + 1 for i, m in enumerate(
    "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split())}


def parse_fio_text(path: str) -> dict:
    """Extract run_ms, completion epoch and summary bandwidths from fio stdout."""
    txt = open(path, errors="replace").read()

    m = _RE_RUN.search(txt)
    if not m:
        raise GateFail(f"{path}: no run=<ms> found")
    run_ms = int(m.group(2))

    done_epoch = None
    d = _RE_DONE.search(txt)
    if d:
        import calendar
        mon, day, hh, mm, ss, yyyy = d.groups()
        done_epoch = calendar.timegm((
            int(yyyy), _MONTHS[mon], int(day), int(hh), int(mm), int(ss), 0, 0, 0))

    summary = {}
    for direction, val, unit in _RE_BW.findall(txt):
        v = float(val)
        if unit.startswith("K"):
            v /= 1024.0
        elif unit.startswith("G"):
            v *= 1024.0
        summary[direction] = v

    return {
        "run_ms": run_ms,
        "run_s": run_ms / 1000.0,
        "done_epoch": done_epoch,
        # D01: the ONLY legitimate start.  fork time is forbidden.
        "io_start_epoch": (done_epoch - run_ms / 1000.0) if done_epoch else None,
        "summary_MiBs": summary,
        "summary_total_MiBs": sum(summary.values()) if summary else None,
    }


# ---------------------------------------------------------------- resampling

def parse_bw_log(path: str) -> list:
    """fio bw log rows: (rel_ms, KiB/s, ddir).  Column 0 is RELATIVE ms, col 2 is
    the direction (0=read, 1=write).  randrw interleaves BOTH directions in the
    same file, so ddir MUST be carried through -- treating the rows as one
    monotonic series silently drops half of them."""
    out = []
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            parts = line.split(",")
            if len(parts) < 2:
                continue
            try:
                ms = int(parts[0].strip())
                val = float(parts[1].strip())
            except ValueError:
                continue
            ddir = 1
            if len(parts) >= 3:
                try:
                    ddir = int(parts[2].strip())
                except ValueError:
                    ddir = 1
            out.append((ms, val, ddir))
    return out


def log_ddirs(rows: list) -> set:
    return {d for _, _, d in rows}


def resample_sum(logs: dict, offset: float = 0.0, ddir: int = None) -> dict:
    """§1.2 reference implementation.  logs: {job_id: [(rel_ms, KiB/s), ...]}

    Each interval [prev_ms, ms) carries an interval-AVERAGE.  Distribute it onto
    natural seconds weighted by temporal OVERLAP, then average per (sec, job),
    then sum across jobs -- keeping only seconds where every job reported.
    """
    if not logs:
        return {}
    acc = defaultdict(lambda: defaultdict(float))   # sec -> job -> value*weight
    wgt = defaultdict(lambda: defaultdict(float))   # sec -> job -> weight

    for job, rows in logs.items():
        prev = {}                       # per-direction previous timestamp
        for row in rows:
            if len(row) == 3:
                ms, kibps, d = row
            else:                       # tolerate 2-tuples from synthetic fixtures
                ms, kibps = row
                d = 1
            if ddir is not None and d != ddir:
                continue
            a = prev.get(d, 0) / 1000.0 + offset
            b = ms / 1000.0 + offset
            prev[d] = ms
            if b <= a:
                continue
            mibps = kibps / KIB_PER_MIB
            for sec in range(int(math.floor(a)), int(math.ceil(b))):
                ov = min(b, sec + 1.0) - max(a, float(sec))
                if ov <= 0:
                    continue
                acc[sec][job] += mibps * ov
                wgt[sec][job] += ov

    njobs = len(logs)
    series = {}
    for sec in sorted(acc):
        if len(acc[sec]) != njobs:          # incomplete coverage -> drop
            continue
        series[sec] = sum(acc[sec][j] / wgt[sec][j] for j in acc[sec])
    return series


# ---------------------------------------------------------------- statistics

def _median(v):
    if not v:
        return None
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def _pct(v, q):
    if not v:
        return None
    s = sorted(v)
    k = (len(s) - 1) * q / 100.0
    lo, hi = int(math.floor(k)), int(math.ceil(k))
    return s[lo] if lo == hi else s[lo] + (s[hi] - s[lo]) * (k - lo)


def window_stats(series: dict, lo: float, hi: float) -> dict:
    vals = [v for s, v in series.items() if lo <= s < hi]
    if not vals:
        return {"n": 0, "mean": None, "median": None, "cv_pct": None,
                "p10": None, "p90": None, "min": None}
    mean = sum(vals) / len(vals)
    if len(vals) > 1:
        var = sum((x - mean) ** 2 for x in vals) / (len(vals) - 1)
        cv = math.sqrt(var) / mean * 100.0 if mean else None
    else:
        cv = None
    return {"n": len(vals), "mean": mean, "median": _median(vals), "cv_pct": cv,
            "p10": _pct(vals, 10), "p90": _pct(vals, 90), "min": min(vals)}


def analyze_series(series: dict) -> dict:
    out = {"formal": window_stats(series, FORMAL_START, FORMAL_END), "windows": {}}
    for name, lo, hi in WINDOWS:
        out["windows"][name] = window_stats(series, lo, hi)
    w1 = out["windows"]["W1"]["mean"]
    w4 = out["windows"]["W4"]["mean"]
    out["w4_w1"] = (w4 / w1) if (w1 and w4) else None
    return out


# ---------------------------------------------------------------- one round

def find_items(round_dir: str) -> dict:
    """V4 layout: <round_dir>/<item>-<LABEL>-r<N>/{fio.txt,*_bw.*.log}"""
    items = {}
    for name in sorted(os.listdir(round_dir)):
        sub = os.path.join(round_dir, name)
        if not os.path.isdir(sub):
            continue
        fio = os.path.join(sub, "fio.txt")
        if not os.path.isfile(fio):
            continue
        logs = [f for f in os.listdir(sub) if "_bw." in f and f.endswith(".log")]
        items[name] = {"dir": sub, "fio": fio, "logs": sorted(logs)}
    return items


def analyze_item(info: dict, offset: float = 0.0) -> dict:
    meta = parse_fio_text(info["fio"])
    logs = {}
    for fname in info["logs"]:
        rows = parse_bw_log(os.path.join(info["dir"], fname))
        if rows:
            logs[fname] = rows
    if not logs:
        raise GateFail(f"{info['dir']}: no usable per-job bw log")

    ddirs = set()
    for rows in logs.values():
        ddirs |= log_ddirs(rows)
    mixed = ddirs == {0, 1}

    if mixed:
        # randrw: R and W are independent full-duplex directions.
        # ⛔ Project rule: never sum them, never compare the sum to a one-way target.
        res = analyze_series(resample_sum(logs, offset=offset, ddir=1))
        res["directions"] = {}
        for name, dv, skey in (("read", 0, "READ"), ("write", 1, "WRITE")):
            sub = analyze_series(resample_sum(logs, offset=offset, ddir=dv))
            ssum = meta["summary_MiBs"].get(skey)
            sm = sub["formal"]["median"]
            sub["summary_MiBs"] = ssum
            sub["formal_vs_summary_pct"] = \
                ((sm - ssum) / ssum * 100.0) if (ssum and sm) else None
            res["directions"][name] = sub
    else:
        res = analyze_series(resample_sum(logs, offset=offset))

    res["mixed"] = mixed
    res["ddirs"] = sorted(ddirs)
    res["n_logs"] = len(logs)
    res["run_s"] = meta["run_s"]
    res["io_start_epoch"] = meta["io_start_epoch"]
    res["done_epoch"] = meta["done_epoch"]
    res["summary_MiBs"] = meta["summary_MiBs"]
    # for mixed workloads the "total" is meaningless as an acceptance figure;
    # keep it only so the deviation column stays comparable per direction
    res["summary_total_MiBs"] = (
        meta["summary_MiBs"].get("WRITE") if mixed else meta["summary_total_MiBs"])

    st = res["summary_total_MiBs"]
    fm = res["formal"]["median"]
    res["formal_vs_summary_pct"] = ((fm - st) / st * 100.0) if (st and fm) else None
    return res


def cmd_round(args) -> int:
    items = find_items(args.round_dir)
    if not items:
        print(f"FAIL: no item dir with fio.txt under {args.round_dir}", file=sys.stderr)
        return 1
    out = {"round_dir": args.round_dir, "items": {}}
    for name, info in sorted(items.items()):
        try:
            out["items"][name] = analyze_item(info)
        except GateFail as exc:
            out["items"][name] = {"error": str(exc)}
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0


# ---------------------------------------------------------------- fixture

def _item_kind(name: str) -> str:
    for k in ("mseqread", "mseqwrite", "seqread", "seqwrite",
              "randread", "randrw", "randwrite"):
        if name.startswith(k):
            return k
    return "unknown"


def cmd_fixture(args) -> int:
    """§5.0.2  Self-prove the analyzer on a historical archive with known answers."""
    items = find_items(args.dir)
    if not items:
        print(f"FAIL: no items under {args.dir}", file=sys.stderr)
        return 1

    print(f"=== U141b analyzer self-proof on {args.dir} ===")
    print(f"tolerance for low-decay items: {args.tol:.1f}%\n")
    hdr = (f"{'item':28} {'kind':10} {'logs':>4} {'summary':>9} {'formal_med':>10} "
           f"{'d%':>7} {'CV%':>6} {'W1':>8} {'W4':>8} {'W4/W1':>6} {'verdict':>8}")
    print(hdr)
    print("-" * len(hdr))

    failures, checked = [], 0
    for name, info in sorted(items.items()):
        kind = _item_kind(name)
        try:
            r = analyze_item(info)
        except GateFail as exc:
            failures.append(f"{name}: {exc}")
            print(f"{name:28} {kind:10} {'-':>4} {'ERROR':>9}  {exc}")
            continue

        st = r["summary_total_MiBs"] or 0.0
        fm = r["formal"]["median"] or 0.0
        d = r["formal_vs_summary_pct"]
        cv = r["formal"]["cv_pct"]
        w1 = r["windows"]["W1"]["mean"]
        w4 = r["windows"]["W4"]["mean"]
        ratio = r["w4_w1"]

        verdict = "OK"
        if kind in STRICT_ITEMS:
            checked += 1
            if d is None or abs(d) > args.tol:
                verdict = "FAIL"
                failures.append(
                    f"{name}: strict item formal_median deviates {d:.2f}% "
                    f"from summary (tol {args.tol}%)")
        elif kind in MODERATE_ITEMS:
            checked += 1
            if d is None or abs(d) > MODERATE_TOL:
                verdict = "FAIL"
                failures.append(
                    f"{name}: moderate item formal_median deviates {d:.2f}% "
                    f"from summary (tol {MODERATE_TOL}%)")
        elif kind in DECAY_ITEMS:
            checked += 1
            if not (w1 and w4) or ratio is None:
                verdict = "FAIL"
                failures.append(f"{name}: missing W1/W4")
            elif not (w1 > w4):
                verdict = "FAIL"
                failures.append(f"{name}: expected W1>W4, got W1={w1:.1f} W4={w4:.1f}")
            elif not (0.0 < ratio <= 1.0):
                verdict = "FAIL"
                failures.append(f"{name}: W4/W1={ratio:.3f} outside (0,1]")

        if r.get("mixed"):
            checked += 1
            dirs = r["directions"]
            for dn in ("read", "write"):
                sub = dirs[dn]
                sd = sub["formal_vs_summary_pct"]
                print(f"    ->{dn:6} summary={sub['summary_MiBs']:8.1f} "
                      f"formal_med={sub['formal']['median'] or 0:8.1f} "
                      f"d={(sd if sd is not None else float('nan')):+6.2f}% "
                      f"CV={sub['formal']['cv_pct'] or 0:5.2f}% "
                      f"W4/W1={sub['w4_w1'] if sub['w4_w1'] is not None else float('nan'):.3f}")
                if sd is None or abs(sd) > 8.0:
                    verdict = "FAIL"
                    failures.append(f"{name}[{dn}]: direction formal_median deviates "
                                    f"{sd:.2f}% from its own summary (tol 8%)")
            rs = dirs["read"]["formal"]["median"] or 0
            ws = dirs["write"]["formal"]["median"] or 0
            both = r["summary_MiBs"].get("READ", 0) + r["summary_MiBs"].get("WRITE", 0)
            if fm and both and abs(fm - both) / both < 0.05:
                verdict = "FAIL"
                failures.append(f"{name}: reported value equals READ+WRITE summed "
                                "-- randrw directions must never be added")

        print(f"{name:28} {kind:10} {r['n_logs']:>4} {st:9.1f} {fm:10.1f} "
              f"{(d if d is not None else float('nan')):7.2f} "
              f"{(cv if cv is not None else float('nan')):6.2f} "
              f"{(w1 or 0):8.1f} {(w4 or 0):8.1f} "
              f"{(ratio if ratio is not None else float('nan')):6.3f} {verdict:>8}")

    # ---- D01 start-sensitivity triple run
    print("\n=== start-sensitivity (D01) ===")
    # Pick the item with the STRONGEST in-run decay: a flat series cannot show a
    # window shift no matter how correct the window logic is, so a flat probe
    # would make this gate vacuous.
    probe, best = None, -1.0
    for nm, inf in sorted(items.items()):
        try:
            rr = analyze_item(inf)
        except GateFail:
            continue
        a, b = rr["windows"]["W1"]["mean"], rr["windows"]["W4"]["mean"]
        if a and b:
            score = abs(a - b) / a
            if score > best:
                probe, best = (nm, inf), score
    if probe is None:
        probe = sorted(items.items())[0]
    name, info = probe
    print(f"probe item: {name}")
    base = analyze_item(info, offset=0.0)
    print(f"{'offset':>8} {'formal_mean':>12} {'W1':>9} {'W4':>9} {'delta_formal%':>14}")
    sens = {}
    for off in (0.0, +1.0, -1.0, +58.0):
        r = analyze_item(info, offset=off)
        fmean = r["formal"]["mean"] or 0.0
        bmean = base["formal"]["mean"] or 1.0
        dev = (fmean - bmean) / bmean * 100.0
        sens[off] = {"formal_mean": fmean, "W1": r["windows"]["W1"]["mean"],
                     "W4": r["windows"]["W4"]["mean"], "dev_pct": dev}
        def _fmt(x):
            return "    (none)" if x is None else f"{x:9.1f}"
        print(f"{off:>+8.0f} {fmean:12.2f} {_fmt(r['windows']['W1']['mean'])} "
              f"{_fmt(r['windows']['W4']['mean'])} {dev:14.3f}")

    for off in (+1.0, -1.0):
        if abs(sens[off]["dev_pct"]) >= 1.0:
            failures.append(f"start-sensitivity: {off:+.0f}s changed formal mean by "
                            f"{sens[off]['dev_pct']:.2f}% (must be <1%)")
    # +58 s MUST visibly move the windows, otherwise window logic is dead code
    w1b, w1s = base["windows"]["W1"]["mean"], sens[58.0]["W1"]
    w4b, w4s = base["windows"]["W4"]["mean"], sens[58.0]["W4"]
    # NOTE: use "is not None", not truthiness.  A shifted W1 can legitimately be
    # 0.0 (no samples left in the window) and 0.0 is falsy -- the earlier
    # `if w1b and w1s` silently skipped the strongest possible signal.
    # A shifted window may end up with NO samples at all, in which case
    # window_stats returns mean=None.  That is a 100% displacement -- the
    # strongest possible evidence the window logic works.  Treating None (or the
    # falsy 0.0) as "unchanged" is exactly how this gate can be made vacuous.
    def _shift(baseline, shifted):
        if baseline in (None, 0):
            return 0.0
        if shifted is None:
            return 100.0
        return abs(shifted - baseline) / baseline * 100.0

    moved = max(_shift(w1b, w1s), _shift(w4b, w4s))
    print(f"\n+58s max window shift: {moved:.2f}%  (must be >5%)")
    if moved <= 5.0:
        failures.append(
            f"start-sensitivity: +58s only moved windows by {moved:.2f}% "
            "-> window logic is not effective (this is exactly the 03-20B-R2 defect)")

    ios = base["io_start_epoch"]
    done = base["done_epoch"]
    if ios and done:
        print(f"actual I/O start epoch = {int(ios)}  (done {int(done)} - run {base['run_s']:.3f}s)")

    print()
    if failures:
        print(f"U141B_ANALYZER_FIXTURE: FAIL ({len(failures)} problem(s))")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"U141B_ANALYZER_FIXTURE: PASS ({checked} item checks + start-sensitivity)")
    return 0


# ---------------------------------------------------------------- matrix

def cmd_matrix(args) -> int:
    """Full phase matrix -> per-item paired effect, noise floor, verdict."""
    rounds = {}
    v4 = os.path.join(args.run_root, "v4")
    base = v4 if os.path.isdir(v4) else args.run_root
    pat = re.compile(r"U141B-(P\d)-R(\d{2})-(V13|V14)$")
    for name in sorted(os.listdir(base)):
        m = pat.match(name)
        if m and os.path.isdir(os.path.join(base, name)):
            rounds.setdefault(m.group(1), {})[int(m.group(2))] = {
                "arm": m.group(3), "dir": os.path.join(base, name)}

    if not rounds:
        print(f"FAIL: no U141B-P*-R??-V1? round dirs under {base}", file=sys.stderr)
        return 1

    report = {"run_root": args.run_root, "phases": {}}
    for phase in sorted(rounds):
        rs = rounds[phase]
        ph = {"rounds": {}, "arm_order_ok": None, "balance": {}, "items": {}}

        # arm order + balance self-check (§3.1)
        got = [rs[i]["arm"] if i in rs else None for i in range(1, 9)]
        ph["arm_order_expected"] = ARM_ORDER
        ph["arm_order_actual"] = got
        ph["arm_order_ok"] = all(
            got[i] is None or got[i] == ARM_ORDER[i] for i in range(8))
        for arm in ("V13", "V14"):
            pos = [i + 1 for i in range(8) if ARM_ORDER[i] == arm]
            ph["balance"][arm] = {"positions": pos, "mean": sum(pos) / len(pos)}

        # collect per-round per-item values
        per_item = defaultdict(dict)     # kind -> round -> formal median
        for rnum in sorted(rs):
            rd = rs[rnum]["dir"]
            entry = {"arm": rs[rnum]["arm"], "items": {}}
            try:
                items = find_items(rd)
            except OSError as exc:
                entry["error"] = str(exc)
                ph["rounds"][rnum] = entry
                continue
            for name, info in sorted(items.items()):
                kind = _item_kind(name)
                try:
                    r = analyze_item(info)
                except GateFail as exc:
                    entry["items"][kind] = {"error": str(exc)}
                    continue
                entry["items"][kind] = {
                    "formal_median": r["formal"]["median"],
                    "formal_mean": r["formal"]["mean"],
                    "cv_pct": r["formal"]["cv_pct"],
                    "w4_w1": r["w4_w1"],
                    "n_logs": r["n_logs"],
                    "summary_total_MiBs": r["summary_total_MiBs"],
                }
                if r["formal"]["median"]:
                    per_item[kind][rnum] = r["formal"]["median"]
            ph["rounds"][rnum] = entry

        # paired effect + noise floor (§2.3)
        for kind, vals in sorted(per_item.items()):
            dk, missing = [], []
            for a_r, b_r in CROSS_PAIRS:
                if a_r in vals and b_r in vals and vals[a_r]:
                    dk.append({"pair": f"R{a_r:02d}/R{b_r:02d}",
                               "v13": vals[a_r], "v14": vals[b_r],
                               "d_pct": (vals[b_r] / vals[a_r] - 1.0) * 100.0})
                else:
                    missing.append(f"R{a_r:02d}/R{b_r:02d}")

            eps_list = []
            for x, y in SAME_ARM_PAIRS:
                if x in vals and y in vals and vals[x]:
                    eps_list.append({"pair": f"R{x:02d}/R{y:02d}",
                                     "arm": ARM_ORDER[x - 1],
                                     "d_pct": (vals[y] / vals[x] - 1.0) * 100.0})

            res = {"per_round": vals, "cross_pairs": dk, "missing_pairs": missing,
                   "same_arm_pairs": eps_list}

            if not dk or missing:
                res["verdict"] = "EVIDENCE_INVALID"
                res["reason"] = f"incomplete matrix, missing {missing}"
                ph["items"][kind] = res
                continue

            d_med = _median([x["d_pct"] for x in dk])
            eps = max((abs(e["d_pct"]) for e in eps_list), default=None)
            res["d_med_pct"] = d_med
            res["eps_pct"] = eps

            if eps is None:
                res["verdict"] = "EVIDENCE_INVALID"
                res["reason"] = "no same-arm adjacent pair -> noise floor unknown"
            else:
                M = max(ENGINEERING_BOUND, 2.0 * eps)
                res["boundary_M_pct"] = M
                n_ok = sum(1 for x in dk if x["d_pct"] >= -M)
                n_neg = sum(1 for x in dk if x["d_pct"] < -M)
                res["pairs_ge_minusM"] = n_ok
                res["pairs_lt_minusM"] = n_neg
                if eps >= ENGINEERING_BOUND:
                    res["verdict"] = "RESOLUTION_INSUFFICIENT"
                    res["reason"] = (f"eps={eps:.2f}% >= engineering bound "
                                     f"{ENGINEERING_BOUND:.1f}%; only an upper bound "
                                     "may be reported")
                elif d_med >= -M and n_ok >= 3:
                    res["verdict"] = "NON_INFERIOR"
                elif d_med < -M and n_neg >= 3:
                    res["verdict"] = "MATERIAL_REGRESSION"
                else:
                    res["verdict"] = "INCONCLUSIVE"
            ph["items"][kind] = res

        report["phases"][phase] = ph

    # overall
    verdicts = {k: v.get("verdict")
                for ph in report["phases"].values() for k, v in ph["items"].items()}
    if not verdicts:
        overall = "EVIDENCE_INVALID"
    elif "EVIDENCE_INVALID" in verdicts.values():
        overall = "EVIDENCE_INVALID"
    elif "MATERIAL_REGRESSION" in verdicts.values():
        overall = "REPLACE_REJECTED"
    elif all(v == "NON_INFERIOR" for v in verdicts.values()):
        overall = "REPLACE_APPROVED_PENDING_P0_AND_ALL_ITEMS"
    else:
        overall = "REPLACE_NOT_PROVEN"
    report["overall_verdict"] = overall
    report["note"] = ("overall verdict covers ONLY the items present here; P0 rollback "
                      "gate and non-performance hard gates are判定 elsewhere")

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        for phase in sorted(report["phases"]):
            ph = report["phases"][phase]
            print(f"\n=== {phase} ===")
            print(f"arm order ok: {ph['arm_order_ok']}   balance: "
                  + "  ".join(f"{a}={ph['balance'][a]['mean']:.1f}" for a in ph["balance"]))
            for kind, r in sorted(ph["items"].items()):
                print(f"\n  [{kind}]  verdict={r['verdict']}")
                if "reason" in r:
                    print(f"    reason: {r['reason']}")
                for x in r.get("cross_pairs", []):
                    print(f"    {x['pair']}  V13={x['v13']:8.1f}  V14={x['v14']:8.1f}"
                          f"  d={x['d_pct']:+7.2f}%")
                for e in r.get("same_arm_pairs", []):
                    print(f"    same-arm {e['pair']} ({e['arm']})  d={e['d_pct']:+7.2f}%")
                if r.get("d_med_pct") is not None:
                    print(f"    D_med={r['d_med_pct']:+.2f}%  eps={r['eps_pct']:.2f}%"
                          f"  M={r.get('boundary_M_pct', float('nan')):.2f}%")
        print(f"\nOVERALL: {report['overall_verdict']}")
    return 0


# ---------------------------------------------------------------- selftest

def _synth_logs(njobs, nsec, value, interval_ms=1000, skew_ms=0):
    """Synthetic interval-average logs.  skew_ms misaligns intervals vs natural sec."""
    logs = {}
    for j in range(njobs):
        rows, t = [], skew_ms
        for _ in range(nsec):
            t += interval_ms
            rows.append((t, value * KIB_PER_MIB))
        logs[f"job{j}"] = rows
    return logs


def cmd_selftest(args) -> int:
    fails = []

    def check(name, cond, detail=""):
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f"  {detail}" if detail else ""))
        if not cond:
            fails.append(name)

    print("=== D02: interval-overlap resampling ===")
    logs = _synth_logs(4, 200, 100.0)
    s = resample_sum(logs)
    st = analyze_series(s)
    check("aligned intervals -> exact 4x100 MiB/s",
          st["formal"]["mean"] is not None and abs(st["formal"]["mean"] - 400.0) < 1e-6,
          f"mean={st['formal']['mean']}")

    logs = _synth_logs(4, 200, 100.0, skew_ms=500)   # deliberately misaligned
    s = resample_sum(logs)
    st = analyze_series(s)
    check("misaligned intervals still -> 400 MiB/s (no row-index-as-second)",
          st["formal"]["mean"] is not None and abs(st["formal"]["mean"] - 400.0) < 1e-6,
          f"mean={st['formal']['mean']}")

    print("=== D02: incomplete job coverage must drop the second ===")
    logs = _synth_logs(3, 200, 100.0)
    logs["jobX"] = [(1000, 100.0 * KIB_PER_MIB)]     # only 1 s of data
    s = resample_sum(logs)
    check("seconds with missing jobs dropped", 1 not in s or len(s) < 199,
          f"kept={len(s)} secs")

    print("=== W1..W4 and W4/W1 ===")
    rows = {}
    for j in range(2):
        r, t = [], 0
        for sec in range(200):
            t += 1000
            r.append((t, (200.0 if sec < 100 else 100.0) * KIB_PER_MIB))
        rows[f"job{j}"] = r
    st = analyze_series(resample_sum(rows))
    check("W1 > W4 on a decaying series", st["windows"]["W1"]["mean"] > st["windows"]["W4"]["mean"],
          f"W1={st['windows']['W1']['mean']:.1f} W4={st['windows']['W4']['mean']:.1f}")
    check("W4/W1 in (0,1]", st["w4_w1"] is not None and 0 < st["w4_w1"] <= 1.0,
          f"W4/W1={st['w4_w1']:.3f}")

    print("=== D01: start offset must move the windows ===")
    st58 = analyze_series(resample_sum(rows, offset=58.0))
    moved = abs(st58["windows"]["W4"]["mean"] - st["windows"]["W4"]["mean"]) / \
        st["windows"]["W4"]["mean"] * 100.0
    check("+58s shifts W4 by >5%", moved > 5.0, f"shift={moved:.1f}%")

    print("=== §2.3 noise floor and boundary ===")
    for a in ("V13", "V14"):
        pos = [i + 1 for i in range(8) if ARM_ORDER[i] == a]
        check(f"{a} position mean == 4.5", abs(sum(pos) / len(pos) - 4.5) < 1e-9,
              f"positions={pos}")
    check("2 same-arm adjacent pairs registered", len(SAME_ARM_PAIRS) == 2)
    check("4 cross pairs registered", len(CROSS_PAIRS) == 4)
    check("same-arm pairs really are same arm",
          all(ARM_ORDER[x - 1] == ARM_ORDER[y - 1] for x, y in SAME_ARM_PAIRS))
    check("cross pairs really are cross arm",
          all(ARM_ORDER[x - 1] != ARM_ORDER[y - 1] for x, y in CROSS_PAIRS))
    check("boundary M widens with eps",
          max(ENGINEERING_BOUND, 2 * 4.0) == 8.0 and max(ENGINEERING_BOUND, 2 * 0.5) == 3.0)

    print("=== D03: primary metric must come from per-job logs, never the summary ===")
    # Functional check: build a fixture whose fio summary is deliberately WRONG.
    # If the analyzer ever fell back to the summary, formal_median would follow it.
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        item = os.path.join(td, "randwrite-SELFTEST-r1")
        os.makedirs(item)
        # logs say a flat 2 x 300 = 600 MiB/s over 200 s
        for j in range(2):
            with open(os.path.join(item, f"st_bw.{j + 1}.log"), "w") as fh:
                t = 0
                for _ in range(200):
                    t += 1000
                    fh.write(f"{t}, {int(300.0 * KIB_PER_MIB)}, 1, 262144, 0\n")
        # fio.txt claims 9999 MiB/s -- a value the logs do not support
        with open(os.path.join(item, "fio.txt"), "w") as fh:
            fh.write("storage_test: (groupid=0, jobs=2): err= 0: "
                     "pid=1: Tue Aug 25 09:29:09 2026\n"
                     "Run status group 0 (all jobs):\n"
                     "  WRITE: bw=9999MiB/s (10485MB/s), io=1GiB (1GB), "
                     "run=200000-200000msec\n")
        found = find_items(td)
        check("find_items locates the round item", len(found) == 1, f"found={list(found)}")
        r = analyze_item(found["randwrite-SELFTEST-r1"])
        check("formal median follows the logs (600), not the summary (9999)",
              r["formal"]["median"] is not None and abs(r["formal"]["median"] - 600.0) < 1e-6,
              f"formal_median={r['formal']['median']}")
        check("summary parsed and kept only as a deviation reference",
              abs((r["summary_total_MiBs"] or 0) - 9999.0) < 1e-6
              and r["formal_vs_summary_pct"] is not None
              and r["formal_vs_summary_pct"] < -90.0,
              f"summary={r['summary_total_MiBs']} dev={r['formal_vs_summary_pct']:.1f}%")
        # D01 again, on a path that actually parses fio.txt
        check("io_start_epoch = done_epoch - run_s",
              r["io_start_epoch"] is not None and r["done_epoch"] is not None
              and abs(r["done_epoch"] - r["io_start_epoch"] - r["run_s"]) < 1e-6,
              f"start={r['io_start_epoch']} done={r['done_epoch']} run={r['run_s']}")

    print("=== D17: malformed input must raise, not silently return zero ===")
    with tempfile.TemporaryDirectory() as td:
        item = os.path.join(td, "randwrite-BAD-r1")
        os.makedirs(item)
        with open(os.path.join(item, "fio.txt"), "w") as fh:
            fh.write("no run= line here at all\n")
        open(os.path.join(item, "st_bw.1.log"), "w").close()
        raised = False
        try:
            analyze_item({"dir": item, "fio": os.path.join(item, "fio.txt"),
                          "logs": ["st_bw.1.log"]})
        except GateFail:
            raised = True
        check("missing run= raises GateFail", raised)

    print()
    if fails:
        print(f"U141B_ANALYZER_SELFTEST: FAIL -> {fails}")
        return 1
    print("U141B_ANALYZER_SELFTEST: PASS")
    return 0


# ---------------------------------------------------------------- cli

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("selftest").set_defaults(func=cmd_selftest)

    p = sub.add_parser("round")
    p.add_argument("round_dir")
    p.set_defaults(func=cmd_round)

    p = sub.add_parser("fixture")
    p.add_argument("dir")
    p.add_argument("--tol", type=float, default=2.0)
    p.set_defaults(func=cmd_fixture)

    p = sub.add_parser("matrix")
    p.add_argument("run_root")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_matrix)

    args = ap.parse_args()
    try:
        return args.func(args)
    except GateFail as exc:
        print(f"GATE FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
