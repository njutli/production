#!/usr/bin/env python3
"""Deterministic analyzer for 04-tmp3i LOCAL1 + RA8/RA32 ABBA."""
from __future__ import annotations

import argparse, json, math, statistics, sys, tempfile
from pathlib import Path

TARGET_MIBPS = 5149.84
AB_CELLS = ("A1", "B1", "B2", "A2")

class EvidenceError(RuntimeError): pass

def load_json(path: Path) -> dict:
    try: return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc: raise EvidenceError(f"invalid_json:{path}") from exc

def fio_job(path: Path) -> tuple[dict, dict]:
    doc=load_json(path); jobs=doc.get("jobs")
    if not isinstance(jobs,list) or len(jobs)!=1: raise EvidenceError(f"fio_job_count:{path}")
    job=jobs[0]
    if int(job.get("error",-1))!=0: raise EvidenceError(f"fio_error:{path}")
    opts=dict(doc.get("global options") or doc.get("global_options") or {})
    opts.update(job.get("job options") or job.get("job_options") or {})
    return job,opts

def expect_options(opts: dict, prefix: str, *, write: bool=False) -> None:
    expected={"rw":"write" if write else "read","bs":"20M","size":"10G","direct":"1","numjobs":"1","ioengine":"psync","iodepth":"1"}
    if not write: expected["runtime"]="60"
    for key,value in expected.items():
        if str(opts.get(key,""))!=value: raise EvidenceError(f"{prefix}_option_{key}:{opts.get(key)!r}")
    if not write and "time_based" in opts and str(opts["time_based"]).lower() not in ("","1","true"): raise EvidenceError(f"{prefix}_time_based")
    if write and str(opts.get("end_fsync","")).lower() not in ("1","true"): raise EvidenceError("local1_end_fsync")

def read_bw_log(path: Path, begin: int=10, end: int=50) -> list[float]:
    rows=[]; previous=0.0
    for number,line in enumerate(path.read_text().splitlines(),1):
        if not line.strip(): continue
        fields=line.split(",")
        if len(fields)<2: raise EvidenceError(f"bw_short:{path}:{number}")
        finish=float(fields[0])/1000.0; value=float(fields[1])/1024.0
        if finish<=previous or value<0 or not math.isfinite(finish+value): raise EvidenceError(f"bw_invalid:{path}:{number}")
        rows.append((previous,finish,value)); previous=finish
    seconds={}
    for start,finish,value in rows:
        for second in range(math.floor(start),math.ceil(finish)):
            overlap=min(finish,second+1.0)-max(start,float(second))
            if overlap>0:
                total,weight=seconds.get(second,(0.0,0.0)); seconds[second]=(total+value*overlap,weight+overlap)
    values=[seconds[x][0]/seconds[x][1] for x in range(begin,end) if x in seconds]
    if len(values)!=end-begin: raise EvidenceError(f"bw_window:{path}:{len(values)}/{end-begin}")
    return values

def only_bw_log(cell: Path) -> Path:
    logs=list((cell/"bw").glob("*_bw.*.log"))
    if len(logs)!=1: raise EvidenceError(f"bw_log_count:{cell}:{len(logs)}")
    return logs[0]

def metric_map(path: Path) -> dict[str,int]:
    wanted={"juicefs_blockcache_hit_bytes","juicefs_blockcache_miss_bytes"}; result={k:0 for k in wanted}; found=set()
    try: lines=path.read_text().splitlines()
    except OSError as exc: raise EvidenceError(f"metrics_missing:{path}") from exc
    for line in lines:
        if not line or line.startswith("#"): continue
        fields=line.split(); name=fields[0].split("{")[0]
        if name in result: result[name]+=int(float(fields[-1])); found.add(name)
    if found!=wanted: raise EvidenceError(f"metrics_keys:{path}")
    return result

def cache_ratio(cell: Path) -> tuple[float,float,int,int]:
    pre=metric_map(cell/"metrics-pre.txt"); post=metric_map(cell/"metrics-post.txt")
    hit=post["juicefs_blockcache_hit_bytes"]-pre["juicefs_blockcache_hit_bytes"]
    miss=post["juicefs_blockcache_miss_bytes"]-pre["juicefs_blockcache_miss_bytes"]
    if hit<0 or miss<0 or hit+miss<=0: raise EvidenceError(f"cache_delta:{cell.name}")
    return hit/(hit+miss),miss/(hit+miss),hit,miss

def clat_result(io: dict, bs_bytes: int) -> dict:
    block=io.get("clat_ns") or io.get("clat_us") or io.get("clat_ms") or {}; scale=1.0
    if "clat_us" in io: scale=1000.0
    elif "clat_ms" in io: scale=1000000.0
    mean_ns=float(block.get("mean",0))*scale; pct=block.get("percentile") or {}
    p99_ns=float(pct.get("99.000000",pct.get("99.0",0)))*scale
    if mean_ns<=0: raise EvidenceError("clat_mean")
    return {"clat_mean_us":mean_ns/1000.0,"clat_p99_us":p99_ns/1000.0 if p99_ns else None,"latency_estimated_MiBs":bs_bytes/(mean_ns/1e9)/1024**2}

def analyze_read(cell: Path, *, require_cache: bool) -> dict:
    try: marker=(cell/"PASS").read_text().strip()
    except OSError as exc: raise EvidenceError(f"cell_pass:{cell.name}") from exc
    if marker not in ("CELL_PASS","LOCAL1_PASS"): raise EvidenceError(f"cell_pass:{cell.name}")
    job,opts=fio_job(cell/"fio.json"); expect_options(opts,cell.name)
    read=job.get("read") or {}; write=job.get("write") or {}; io_bytes=int(read.get("io_bytes",0)); runtime_ms=int(job.get("job_runtime",read.get("runtime",0)))
    if io_bytes<=0 or int(write.get("io_bytes",0))!=0: raise EvidenceError(f"read_bytes:{cell.name}")
    if not 58000<=runtime_ms<=65000: raise EvidenceError(f"runtime:{cell.name}:{runtime_ms}")
    values=read_bw_log(only_bw_log(cell)); summary=float(read.get("bw_bytes",0))/1024**2
    if summary<=0: summary=float(read.get("bw",0))/1024.0
    formal=statistics.mean(values)
    result={"summary_MiBs":summary,"formal_MiBs":formal,"formal_cv_pct":statistics.pstdev(values)/formal*100,"io_bytes":io_bytes,"iops":float(read.get("iops",0)),"target_pass":summary>=TARGET_MIBPS and formal>=TARGET_MIBPS}
    result.update(clat_result(read,20*1024**2))
    if require_cache:
        for side in ("pre","post"):
            health=cell/f"health-{side}"
            if not (health/"ceph-status.json").is_file() or not (health/"reference-mount.tsv").is_file(): raise EvidenceError(f"health_evidence:{cell.name}:{side}")
        if (cell/"asset-pre.tsv").read_bytes()!=(cell/"asset-post.tsv").read_bytes(): raise EvidenceError(f"asset_drift:{cell.name}")
        hit_ratio,miss_ratio,hit_bytes,miss_bytes=cache_ratio(cell)
        try: rx=int((cell/"ceph-rx-bytes.txt").read_text().strip())
        except (OSError,ValueError) as exc: raise EvidenceError(f"ceph_rx:{cell.name}") from exc
        if rx<0: raise EvidenceError(f"ceph_rx_negative:{cell.name}")
        rx_ratio=rx/io_bytes
        result.update({"cache_hit_pct":hit_ratio*100,"cache_miss_pct":miss_ratio*100,"cache_hit_bytes":hit_bytes,"cache_miss_bytes":miss_bytes,"ceph_rx_bytes":rx,"ceph_rx_pct_of_fio_read":rx_ratio*100,"cache_residency_pass":hit_ratio>=.995 and miss_ratio<=.005 and rx_ratio<=.01})
        if not result["cache_residency_pass"]: raise EvidenceError(f"cache_residency:{cell.name}")
    return result

def analyze_local(cell: Path) -> dict:
    result=analyze_read(cell,require_cache=False); write,opts=fio_job(cell/"write.json"); expect_options(opts,"LOCAL1_write",write=True)
    if int((write.get("write") or {}).get("io_bytes",0))!=10*1024**3: raise EvidenceError("local1_write_bytes")
    result["mechanism"]="same-loop-ext4-direct"; return result

def drift(left: float,right: float) -> float:
    mean=(left+right)/2.0; return abs(left-right)/mean*100 if mean else float("inf")

def analyze(root: Path) -> dict:
    cells={"LOCAL1":analyze_local(root/"cells"/"LOCAL1")}
    for name in AB_CELLS: cells[name]=analyze_read(root/"cells"/name,require_cache=True)
    drift_a=drift(cells["A1"]["formal_MiBs"],cells["A2"]["formal_MiBs"]); drift_b=drift(cells["B1"]["formal_MiBs"],cells["B2"]["formal_MiBs"])
    if drift_a>8 or drift_b>8: validity=verdict="RESOLUTION_INSUFFICIENT"
    else:
        validity="VALID"; b_values=[cells[x][key] for x in ("B1","B2") for key in ("summary_MiBs","formal_MiBs")]
        verdict="RA32_CACHED_SYNC_READ_TARGET_CONFIRMED" if min(b_values)>=TARGET_MIBPS else "BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET"
    a_mean=statistics.mean(cells[x]["formal_MiBs"] for x in ("A1","A2")); b_mean=statistics.mean(cells[x]["formal_MiBs"] for x in ("B1","B2"))
    return {"validity":validity,"verdict":verdict,"target_MiBs":TARGET_MIBPS,"anchor_drift_pct":{"A":drift_a,"B":drift_b},"formal_mean_MiBs":{"A":a_mean,"B":b_mean},"B_vs_A_pct":(b_mean/a_mean-1)*100,"cells":cells}

def decision_fixture(a1: float,a2: float,b1: float,b2: float,evidence: bool=True) -> str:
    if not evidence: return "EVIDENCE_INVALID"
    if drift(a1,a2)>8 or drift(b1,b2)>8: return "RESOLUTION_INSUFFICIENT"
    return "RA32_CACHED_SYNC_READ_TARGET_CONFIRMED" if min(b1,b2)>=TARGET_MIBPS else "BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET"

def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="t04tmp3i-") as tmp:
        log=Path(tmp)/"x_bw.1.log"; log.write_text("".join(f"{i*1000},6144000\n" for i in range(1,61))); values=read_bw_log(log)
        assert len(values)==40 and round(statistics.mean(values),3)==6000.0
    assert decision_fixture(2800,2820,5200,5250)=="RA32_CACHED_SYNC_READ_TARGET_CONFIRMED"
    assert decision_fixture(2800,2820,5000,5050)=="BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET"
    assert decision_fixture(2800,3100,5200,5250)=="RESOLUTION_INSUFFICIENT"
    assert decision_fixture(2800,2820,5200,5250,False)=="EVIDENCE_INVALID"
    print("T04TMP3I_ANALYZER_SELFTEST_PASS")

def main() -> int:
    parser=argparse.ArgumentParser(); parser.add_argument("mode",choices=("run","self-test")); parser.add_argument("root",nargs="?",type=Path); args=parser.parse_args()
    if args.mode=="self-test": self_test(); return 0
    if args.root is None: parser.error("root is required for run")
    try: output=analyze(args.root)
    except (EvidenceError,OSError,ValueError,KeyError) as exc:
        print(json.dumps({"validity":"EVIDENCE_INVALID","verdict":"EVIDENCE_INVALID","error":str(exc)},indent=2,sort_keys=True)); return 42
    print(json.dumps(output,indent=2,sort_keys=True)); return 0

if __name__=="__main__": sys.exit(main())
