#!/usr/bin/env python3
"""Offline bandwidth, OSD-load and fixed-matrix analyzer for 04-1/R1."""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

ARM_ORDER = ["A", "B", "B", "A", "B", "A", "A", "B"]
T95_DF4 = 2.7764451051977987
T95_ONE_DF4 = 2.131846786326649


class EvidenceError(RuntimeError): pass


def percentile(vals, p):
    xs=sorted(vals); x=(len(xs)-1)*p; lo=math.floor(x); hi=math.ceil(x)
    return xs[lo] if lo==hi else xs[lo]*(hi-x)+xs[hi]*(x-lo)


def read_logs(bwdir: Path, expected=128, start_sec=15):
    files=sorted(bwdir.glob("*_bw.*.log"))
    ids=[]
    for p in files:
        m=re.search(r"_bw\.(\d+)\.log$",p.name)
        if not m: raise EvidenceError(f"unexpected bw log name: {p.name}")
        ids.append(int(m.group(1)))
    if len(files)!=expected or sorted(ids)!=list(range(1,expected+1)):
        raise EvidenceError(f"bw logs require ids 1..{expected}; got count={len(files)} ids={ids[:5]}..")
    series=defaultdict(lambda: defaultdict(float)); weights=defaultdict(lambda: defaultdict(float))
    for job,p in zip(ids,files):
        prev=0.0; rows=0
        with p.open(newline='') as fh:
            for row in csv.reader(fh):
                if len(row)<3: raise EvidenceError(f"truncated row {p}:{rows+1}")
                try: end=float(row[0])/1000.0; val=float(row[1])/1024.0; direction=int(row[2])
                except ValueError as exc: raise EvidenceError(f"bad bw row {p}:{rows+1}") from exc
                if direction!=0: raise EvidenceError(f"non-read direction in randread log {p}:{rows+1}")
                if end<=prev or val<0: raise EvidenceError(f"nonmonotonic/negative bw row {p}:{rows+1}")
                start=prev; prev=end; rows+=1
                for sec in range(math.floor(start),math.ceil(end)):
                    overlap=min(end,sec+1)-max(start,sec)
                    if overlap>0:
                        series[sec][job]+=val*overlap; weights[sec][job]+=overlap
        if rows < start_sec + 160: raise EvidenceError(f"truncated bw log {p}: {rows} rows")
    aggregate={}
    for sec in sorted(series):
        if len(series[sec])!=expected: continue
        if any(weights[sec].get(j,0)<=0 for j in ids): continue
        aggregate[sec]=sum(series[sec][j]/weights[sec][j] for j in ids)
    formal=[aggregate[s] for s in range(start_sec,start_sec+160) if s in aggregate]
    if len(formal)!=160: raise EvidenceError(f"formal window has {len(formal)} complete seconds, expected 160")
    windows=[]
    for a in (start_sec,start_sec+40,start_sec+80,start_sec+120):
        vals=[aggregate[s] for s in range(a,a+40) if s in aggregate]
        if len(vals)!=40: raise EvidenceError(f"window {a}:{a+40} incomplete")
        windows.append(statistics.mean(vals))
    mean=statistics.mean(formal); sd=statistics.pstdev(formal)
    return {"n_logs":expected,"formal_n":160,"mean_MiBs":mean,
            "median_MiBs":statistics.median(formal),"cv_pct":sd/mean*100,
            "p10_MiBs":percentile(formal,.10),"p90_MiBs":percentile(formal,.90),
            "windows_MiBs":windows,"w4_w1":windows[-1]/windows[0],
            "per_second_MiBs":{str(s):aggregate[s] for s in range(start_sec,start_sec+160)}}


def parse_run_ms(text: str):
    vals=[]
    for a,b in re.findall(r"run=(\d+)(?:-(\d+))?msec",text): vals.append(int(b or a))
    if not vals: raise EvidenceError("fio output has no run=...msec")
    run=max(vals)
    if not 175000<=run<=190000: raise EvidenceError(f"unexpected fio runtime {run}ms")
    return run


def load_osd_tsv(paths):
    by=defaultdict(list)
    for p in paths:
        with p.open(newline='') as fh:
            rd=csv.DictReader(fh,delimiter='\t')
            required={'epoch_ns','osd','op_r','op_r_out_bytes','op_r_latency_sum','op_r_latency_count'}
            if not rd.fieldnames or not required.issubset(rd.fieldnames):
                raise EvidenceError(f"missing OSD TSV fields in {p}")
            for r in rd:
                key=int(r['osd']); by[key].append((int(r['epoch_ns']),float(r['op_r']),
                    float(r['op_r_out_bytes']),float(r['op_r_latency_sum']),float(r['op_r_latency_count'])))
    if len(by)!=6: raise EvidenceError(f"expected six OSDs, got {sorted(by)}")
    for osd,rows in by.items():
        rows.sort()
        epochs=[x[0] for x in rows]
        if len(set(epochs))!=len(epochs): raise EvidenceError(f"duplicate epoch for osd.{osd}")
    return by


def interp(rows, target):
    left=[x for x in rows if x[0]<=target]; right=[x for x in rows if x[0]>=target]
    if not left or not right: raise EvidenceError("OSD sampler does not bracket formal window")
    a=left[-1]; b=right[0]
    if b[0]-a[0]>3_000_000_000: raise EvidenceError("OSD sampler gap exceeds 3s")
    if a[0]==b[0]: return a[1:]
    f=(target-a[0])/(b[0]-a[0])
    return tuple(x+(y-x)*f for x,y in zip(a[1:],b[1:]))


def osd_metrics(paths, t0_ns):
    by=load_osd_tsv(paths); start=t0_ns+15_000_000_000; end=t0_ns+175_000_000_000
    elapsed=(end-start)/1e9; result=[]
    for osd in sorted(by):
        a=interp(by[osd],start); b=interp(by[osd],end); delta=[y-x for x,y in zip(a,b)]
        if any(x<0 for x in delta): raise EvidenceError(f"counter wrap/reset on osd.{osd}")
        r=delta[0]/elapsed; out=delta[1]/elapsed
        lat=delta[2]/delta[3] if delta[3]>0 else None
        result.append({"osd":osd,"op_r_per_s":r,"op_r_out_bytes_per_s":out,
                       "op_r_latency_s":lat,"delta_op_r":delta[0]})
    rates=[x['op_r_per_s'] for x in result]; mean=statistics.mean(rates)
    if mean<=0: raise EvidenceError("zero OSD read service rate")
    total=sum(rates)
    for x in result: x['share']=x['op_r_per_s']/total
    return {"elapsed_s":elapsed,"osds":result,"I_op":max(rates)/mean,
            "CV_op":statistics.pstdev(rates)/mean}


def transpose(a): return [list(x) for x in zip(*a)]
def matmul(a,b):
    bt=transpose(b); return [[sum(x*y for x,y in zip(r,c)) for c in bt] for r in a]
def invert(a):
    n=len(a); z=[list(map(float,r))+[1.0 if i==j else 0.0 for j in range(n)] for i,r in enumerate(a)]
    for c in range(n):
        p=max(range(c,n),key=lambda r:abs(z[r][c]));
        if abs(z[p][c])<1e-12: raise EvidenceError('singular model')
        z[c],z[p]=z[p],z[c]; q=z[c][c]; z[c]=[x/q for x in z[c]]
        for r in range(n):
            if r==c: continue
            q=z[r][c]; z[r]=[x-q*y for x,y in zip(z[r],z[c])]
    return [r[n:] for r in z]


def model(values):
    if len(values)!=8: raise EvidenceError('formal matrix requires eight rounds')
    x=[]
    for i,arm in enumerate(ARM_ORDER,1):
        t=i-4.5; x.append([1,t,t*t,1 if arm=='B' else 0])
    inv=invert(matmul(transpose(x),x)); beta=[r[0] for r in matmul(matmul(inv,transpose(x)),[[v] for v in values])]
    residual=[y-sum(a*b for a,b in zip(row,beta)) for row,y in zip(x,values)]
    s2=sum(e*e for e in residual)/4; se=math.sqrt(s2*inv[3][3]); a_mean=statistics.mean(v for v,a in zip(values,ARM_ORDER) if a=='A')
    effect=beta[3]/a_mean*100; half=T95_DF4*se/a_mean*100; one=T95_ONE_DF4*se/a_mean*100
    # Adjusted B mean is the mean prediction at the eight balanced time positions with arm B.
    adjusted_b=statistics.mean(beta[0]+beta[1]*(i-4.5)+beta[2]*(i-4.5)**2+beta[3] for i in range(1,9))
    return {"beta":beta,"a_raw_mean_MiBs":a_mean,
            "b_raw_mean_MiBs":statistics.mean(v for v,a in zip(values,ARM_ORDER) if a=='B'),
            "b_adjusted_mean_MiBs":adjusted_b,"effect_pct":effect,
            "ci95_pct":[effect-half,effect+half],"one_sided95_low_pct":effect-one,
            "ci95_halfwidth_pct":half}


def command_round(args, osd_only=False):
    end_ns=int((args.round_dir/'fio-end-ns.txt').read_text().strip())
    run_ms=parse_run_ms((args.round_dir/'fio.txt').read_text(errors='replace'))
    t0_ns=end_ns-run_ms*1_000_000
    osd=osd_metrics(list(args.round_dir.glob('osd-*/osd-perf.tsv')),t0_ns)
    out={"schema":1,"t0_ns":t0_ns,"run_ms":run_ms,"osd":osd}
    if not osd_only: out['bandwidth']=read_logs(args.round_dir/'bw')
    args.output.write_text(json.dumps(out,indent=2,sort_keys=True)+'\n')
    print(f"OSD_EVIDENCE_PASS I_op={osd['I_op']:.6f} CV_op={osd['CV_op']:.6f}")
    if not osd_only: print(f"ROUND_EVIDENCE_PASS BW={out['bandwidth']['mean_MiBs']:.3f}")


def command_manip(args):
    rows=[json.loads(Path(x).read_text()) for x in args.inputs]
    if len(rows)!=4: raise EvidenceError('manipulation requires W01..W04')
    vals=[x['osd']['I_op'] for x in rows]; a=statistics.mean([vals[0],vals[3]]); b=statistics.mean([vals[1],vals[2]])
    if a<1.10: verdict='R1_MECHANISM_ABSENT_NOW'
    elif b>1.05 or a-b<0.05: verdict='R1_MECHANISM_NOT_MANIPULATED'
    else: verdict='R1_MANIPULATION_PASS'
    out={"verdict":verdict,"A_mean_I_op":a,"B_mean_I_op":b,"delta":a-b,"round_I_op":vals}
    args.output.write_text(json.dumps(out,indent=2,sort_keys=True)+'\n'); print(f"VERDICT={verdict}")


def command_matrix(args):
    rows=[json.loads(Path(x).read_text()) for x in args.inputs]
    if len(rows)!=8: raise EvidenceError('matrix requires R01..R08')
    values=[x['bandwidth']['mean_MiBs'] for x in rows]; m=model(values)
    # Target decision uses an adjusted B one-sided lower bound derived from the same arm coefficient SE.
    b_low=m['b_adjusted_mean_MiBs']-(m['effect_pct']-m['one_sided95_low_pct'])/100*m['a_raw_mean_MiBs']
    m['b_adjusted_one_sided95_low_MiBs']=b_low; m['values_MiBs']=values; m['arms']=ARM_ORDER
    if m['ci95_halfwidth_pct']>5: verdict='R1_RESOLUTION_INSUFFICIENT'
    elif b_low>=6250: verdict='R1_TARGET_CONFIRMED'
    elif m['b_adjusted_mean_MiBs']>=6250: verdict='R1_TARGET_OBSERVED_NOT_CONFIRMED'
    elif m['ci95_pct'][0]>0: verdict='R1_BENEFIT_CONFIRMED_TARGET_NOT_MET'
    elif m['ci95_pct'][0]<=0<=m['ci95_pct'][1]: verdict='R1_NO_DETECTABLE_BENEFIT'
    else: verdict='R1_LAYOUT_REGRESSION'
    m['verdict']=verdict; args.output.write_text(json.dumps(m,indent=2,sort_keys=True)+'\n'); print(f"VERDICT={verdict}")


def command_r1b_manip(a):
    """R1B N/S manipulation analysis. Strict 4-round validation."""
    required_rounds=["W01","W02","W03","W04"]
    seen={}
    for inp in a.inputs:
        d=json.load(open(inp))
        rd=inp.parent.name
        if rd not in required_rounds:
            raise EvidenceError(f"unexpected round dir: {rd}")
        if rd in seen:
            raise EvidenceError(f"duplicate round: {rd}")
        iop=d.get("osd",{}).get("I_op")
        if iop is None or not isinstance(iop,(int,float)) or not math.isfinite(iop):
            raise EvidenceError(f"round {rd}: I_op missing/non-finite: {iop}")
        seen[rd]=float(iop)
    for r in required_rounds:
        if r not in seen:
            raise EvidenceError(f"missing round: {r}")
    n_vals=[seen[r] for r in ("W01","W04")]
    s_vals=[seen[r] for r in ("W02","W03")]
    n_mean=statistics.mean(n_vals)
    s_mean=statistics.mean(s_vals)
    diff=n_mean-s_mean
    round_iop={r:seen[r] for r in required_rounds}
    if n_mean>=1.10 and s_mean<=1.05 and diff>=0.05:
        verdict="R1B_MANIPULATION_PASS"
    else:
        verdict="R1B_MANIPULATION_NOT_MANIPULATED"
    result={"N_mean_I_op":n_mean,"S_mean_I_op":s_mean,"N_minus_S":diff,
            "round_I_op":round_iop,"verdict":verdict}
    a.output.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(f"VERDICT={verdict}")


def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    for name in ('round','osd'):
        p=sub.add_parser(name); p.add_argument('--round-dir',type=Path,required=True); p.add_argument('--output',type=Path,required=True)
    for name in ('manipulation','matrix','r1b-manipulation'):
        p=sub.add_parser(name); p.add_argument('--inputs',nargs='+',type=Path,required=True); p.add_argument('--output',type=Path,required=True)
    a=ap.parse_args(); a.output.parent.mkdir(parents=True,exist_ok=True)
    if a.cmd=='round': command_round(a)
    elif a.cmd=='osd': command_round(a,True)
    elif a.cmd=='manipulation': command_manip(a)
    elif a.cmd=='r1b-manipulation': command_r1b_manip(a)
    else: command_matrix(a)


if __name__=='__main__':
    try: main()
    except EvidenceError as exc: print(f"E_R1_ANALYZE\t{exc}",file=sys.stderr); raise SystemExit(42)
