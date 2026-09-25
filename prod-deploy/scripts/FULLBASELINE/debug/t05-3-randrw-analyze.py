#!/usr/bin/env python3
"""Offline descriptive analyzer for the 05-3 pure random curves.

It consumes only persisted runner evidence.  It makes no causal decision and
never contacts a host or changes an environment.
"""
from __future__ import annotations
import argparse, csv, json, math, statistics, tempfile
from pathlib import Path

RUNTIME = 180
START, STOP = 15, 175
JOBS = 128
ORDER = ("256K-A", "4K-1", "16K-1", "64K-1", "1M-1", "4M-1",
         "4M-2", "1M-2", "64K-2", "16K-2", "4K-2", "256K-B")

class EvidenceError(RuntimeError): pass

def finite(v):
    try: x = float(v)
    except (TypeError, ValueError) as e: raise EvidenceError("non-numeric") from e
    if not math.isfinite(x): raise EvidenceError("non-finite")
    return x

def cell_dir(root: Path, direction: str, cell: str) -> Path:
    p = root / "cells" / f"{direction}-{cell}"
    if not p.is_dir() or p.is_symlink(): raise EvidenceError(f"cell missing: {direction}-{cell}")
    return p

def fio_data(cell: Path, direction: str) -> tuple[dict, float, int]:
    rc_file = cell / "fio.rc"
    if rc_file.is_file() and rc_file.read_text().strip() != "0": raise EvidenceError("fio rc nonzero")
    p = cell / "fio.json"
    try: d = json.loads(p.read_text())
    except (OSError, json.JSONDecodeError) as e: raise EvidenceError("invalid fio.json") from e
    jobs = d.get("jobs")
    if not isinstance(jobs, list) or not jobs: raise EvidenceError("fio jobs missing")
    if any(int(j.get("error", -1)) != 0 for j in jobs): raise EvidenceError("fio error")
    side = "read" if direction == "randread" else "write"
    vals = [j.get(side, {}) for j in jobs]
    total = sum(int(x.get("io_bytes", 0)) for x in vals)
    if total <= 0: raise EvidenceError(f"{side} io_bytes missing")
    runtimes = [finite(x.get("runtime", 0)) for x in vals if finite(x.get("runtime", 0)) > 0]
    if not runtimes: raise EvidenceError("runtime missing")
    end = cell / "fio-end-epoch-ns.txt"
    try: end_ns = int(end.read_text().strip())
    except (OSError, ValueError) as e: raise EvidenceError("fio end timestamp missing") from e
    runtime = max(RUNTIME, max(runtimes) / 1000.0)
    start_ns = end_ns - int(runtime * 1_000_000_000)
    if start_ns <= 0: raise EvidenceError("invalid derived start")
    return d, runtime, start_ns

def logs(cell: Path, direction: str, runtime: float) -> tuple[dict[int, float], float, float, float]:
    prefix = f"{direction}-{cell.name.removeprefix(direction + '-') }"
    paths = sorted((cell / "bw").glob(prefix + "_bw.*.log"))
    if len(paths) != JOBS: raise EvidenceError(f"expected 128 logs, got {len(paths)}")
    ids = []
    series = {i: 0.0 for i in range(math.ceil(runtime))}; formal_coverage = 0.0; longest_gap = 0.0; integrated_mib = 0.0; per_job_coverage=[]; per_job_gap=[]
    for path in paths:
        try: ids.append(int(path.name.rsplit(".", 2)[1]))
        except (ValueError, IndexError) as e: raise EvidenceError("bad log id") from e
        with path.open(newline="") as stream:
            previous = None; intervals=[]; matched=0
            for row in csv.reader(stream):
                if not row or not any(x.strip() for x in row): continue
                if len(row) < 3: raise EvidenceError("short log row")
                end = finite(row[0]) / 1000.0; value = finite(row[1]) / 1024.0
                d = int(row[2])
                wanted = 0 if direction == "randread" else 1
                if d != wanted: raise EvidenceError("unexpected data direction")
                if end <= 0 or end > runtime + 1: raise EvidenceError("invalid log timestamp")
                if previous is not None and end <= previous: raise EvidenceError("non-monotonic log rows")
                begin = max(0.0, end - 1.0 if previous is None else max(previous, end - 1.0))
                previous = end; intervals.append((begin, end)); matched += 1
                integrated_mib += value * (end - begin)
                for second in range(math.floor(begin), math.ceil(end)):
                    overlap = min(end, second + 1.0, runtime) - max(begin, float(second))
                    if overlap > 0: series[second] += value * overlap
            if matched == 0: raise EvidenceError("empty bandwidth log")
            clipped=[]; job_gap=0.0
            for begin,end in intervals:
                left,right=max(begin,float(START)),min(end,float(STOP))
                if right>left: clipped.append((left,right))
            clipped.sort(); cursor=float(START)
            for begin,end in clipped:
                if begin>cursor: job_gap=max(job_gap,begin-cursor)
                formal_coverage += max(0.0,end-max(cursor,begin)); cursor=max(cursor,end)
            job_gap=max(job_gap,float(STOP)-cursor); longest_gap=max(longest_gap,job_gap)
            per_job_coverage.append(sum(max(0.0,min(e,float(STOP))-max(b,float(START))) for b,e in clipped))
            per_job_gap.append(job_gap)
    if sorted(ids) != list(range(1, JOBS + 1)): raise EvidenceError("log ids not 1..128")
    return series, min(per_job_coverage), max(per_job_gap), integrated_mib

def stats(series: dict[int, float]) -> dict:
    vals = [series[i] for i in range(START, STOP)]
    if len(vals) != 160: raise EvidenceError("formal window coverage")
    def pct(f):
        a = sorted(vals); x=(len(a)-1)*f; lo,hi=math.floor(x),math.ceil(x)
        return a[lo] if lo==hi else a[lo]+(a[hi]-a[lo])*(x-lo)
    windows = {}
    for n in range(4):
        v=[series[i] for i in range(START+n*40, START+(n+1)*40)]
        m=statistics.mean(v); windows[f"W{n+1}"]={"mean_MiB_s":m,"CV":statistics.pstdev(v)/m if m else math.inf}
    mean=statistics.mean(vals)
    return {"mean_MiB_s":mean,"median_MiB_s":statistics.median(vals),"P10_MiB_s":pct(.1),"P90_MiB_s":pct(.9),"CV":statistics.pstdev(vals)/mean if mean else math.inf,"formal_seconds":160,"windows":windows,"W4_W1":windows["W4"]["mean_MiB_s"]/windows["W1"]["mean_MiB_s"] if windows["W1"]["mean_MiB_s"] else math.inf}

def analyze_cell(root: Path, direction: str, cell: str) -> dict:
    p=cell_dir(root,direction,cell); data,runtime,start=fio_data(p,direction); series,coverage,longest_gap,integrated_mib=logs(p,direction,runtime)
    side="read" if direction=="randread" else "write"; total=sum(int(j.get(side,{}).get("io_bytes",0)) for j in data["jobs"])
    summary=total/runtime/1048576.0; formal=stats(series)
    integral_ratio=integrated_mib/(total/1048576.0)
    formal["min_per_job_coverage_seconds"]=coverage; formal["max_per_job_gap_seconds"]=longest_gap
    formal["bwlog_integral_over_fio_bytes"]=integral_ratio
    formal["window_status"]="UNKNOWN/REVIEW" if longest_gap>5.0 or coverage<150.0 or abs(integral_ratio-1.0)>0.05 else "MEASURED"
    side_data=[j.get(side,{}) for j in data["jobs"]]
    def agg(key): return sum(float(x.get(key,0) or 0) for x in side_data)
    clats=[j.get("clat_ns",{}) for j in side_data]
    # fio --group_reporting produces one aggregate job. Quantiles cannot be
    # added across multiple independent jobs, so leave them unknown otherwise.
    clat=clats[0] if len(clats)==1 else {}
    quantiles=clat.get("percentile") or {}
    clat_mean=(sum(float(x.get("mean",0) or 0)*float(x.get("N",0) or 0) for x in clats)
               /sum(float(x.get("N",0) or 0) for x in clats)) if any(x.get("N",0) for x in clats) else None
    return {"direction":direction,"cell":cell,"runtime_s":runtime,"actual_io_start_epoch_ns":start,"fio_summary":{"io_bytes":total,"summary_MiB_s":summary,"iops":agg("iops"),"clat_mean_ns":clat_mean,"clat_p95_ns":quantiles.get("95.000000"),"clat_p99_ns":quantiles.get("99.000000")},"formal":formal,"evidence_status":"RAW_MEASUREMENTS_ONLY"}

def analyze(root: Path, output: Path) -> dict:
    rows=[]; errors=[]
    for direction in ("randread","randwrite"):
        for cell in ORDER:
            try: rows.append(analyze_cell(root,direction,cell))
            except EvidenceError as e: errors.append(f"{direction}-{cell}: {e}")
    formal_review=any(x["formal"]["window_status"] != "MEASURED" for x in rows)
    state="EVIDENCE_INVALID" if errors else "PARTIAL_FORMAL_REVIEW" if formal_review else "MEASURED_PENDING_REVIEW"
    result={"schema":1,"scope":"offline_descriptive_only","formal_window":"[15,175)","cells":rows,"errors":errors,"RUN_VALIDITY_STATE":state,"decision":"REQUIRES_SECOND_PARTY_REVIEW"}
    output.write_text(json.dumps(result,indent=2,sort_keys=True)+"\n"); return result

def self_test():
    with tempfile.TemporaryDirectory() as td:
        root=Path(td); p=root/"cells"/"randread-256K-A"; (p/"bw").mkdir(parents=True)
        jobs=[]
        for n in range(1,JOBS+1):
            jobs.append({"error":0,"read":{"runtime":180000,"io_bytes":180*100*1048576}})
            with (p/"bw"/f"randread-256K-A_bw.{n}.log").open("w") as f:
                for s in range(1,181): f.write(f"{s*1000+250},102400,0,0\n")
        (p/"fio.json").write_text(json.dumps({"jobs":jobs})); (p/"fio-end-epoch-ns.txt").write_text("181000000000")
        x=analyze_cell(root,"randread","256K-A"); assert x["formal"]["formal_seconds"]==160 and abs(x["formal"]["mean_MiB_s"]-12800)<1e-6
        assert x["formal"]["max_per_job_gap_seconds"] < 1
        shifted=root/"shifted"; import shutil; shutil.copytree(root,shifted)
        for q in (shifted/"cells"/"randread-256K-A"/"bw").glob("*.log"):
            rows=[r for r in q.read_text().splitlines() if int(r.split(',')[0]) > 58000]; q.write_text("\n".join(rows)+"\n")
        y=analyze_cell(shifted,"randread","256K-A"); assert y["formal"]["window_status"]=="UNKNOWN/REVIEW" and y["formal"]["max_per_job_gap_seconds"]>5 and y["formal"]["min_per_job_coverage_seconds"]<150
        (shifted/"cells"/"randread-256K-A"/"fio-end-epoch-ns.txt").write_text("239000000000")
        z=analyze_cell(shifted,"randread","256K-A"); assert z["actual_io_start_epoch_ns"] != y["actual_io_start_epoch_ns"]
    print(json.dumps({"status":"PASS","checks":["start_time","non_integer_overlap","formal_window","gap_review","128_logs","summary","end_time_derivation"]}))

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest="cmd",required=True); sub.add_parser("self-test"); a=sub.add_parser("analyze"); a.add_argument("--root",type=Path,required=True); a.add_argument("--output",type=Path,required=True); x=ap.parse_args()
    if x.cmd=="self-test": self_test()
    else: print(json.dumps(analyze(x.root,x.output),indent=2,sort_keys=True))
if __name__=="__main__": main()
