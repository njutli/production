#!/usr/bin/env python3
"""Independent, fail-closed analyzer for the 04-tmp2j randrw read-cache curve."""
import argparse,csv,json,math,re,statistics
from collections import defaultdict
from pathlib import Path
class EvidenceError(RuntimeError): pass
CELLS=("A0-pre","C32","C128","C64","A0-mid","C256","C96","A0-post")
TIERS={"A0-pre":0,"C32":32,"C64":64,"C96":96,"C128":128,"C256":256,"A0-mid":0,"A0-post":0}
JOBS=128
METRICS=("juicefs_blockcache_bytes","juicefs_blockcache_blocks","juicefs_blockcache_hits","juicefs_blockcache_miss","juicefs_blockcache_hit_bytes","juicefs_blockcache_miss_bytes","juicefs_blockcache_write_bytes","juicefs_blockcache_evicts","juicefs_blockcache_drops")
def percentile(v,q):
    x=sorted(v); p=(len(x)-1)*q; a,b=math.floor(p),math.ceil(p); return x[a] if a==b else x[a]*(b-p)+x[b]*(p-a)
def fio(path):
    d=json.loads(path.read_text()); jobs=d.get("jobs",[])
    if len(jobs)!=JOBS or any(int(j.get("error",-1))!=0 for j in jobs): raise EvidenceError(f"{path}: fio contract")
    rt=max(max(int(j.get("read",{}).get("runtime",0)),int(j.get("write",{}).get("runtime",0)),int(j.get("job_runtime",0))) for j in jobs)
    if not 175000<=rt<=320000: raise EvidenceError(f"{path}: runtime {rt}")
    end=path.parent/"fio-end-epoch-ns.txt"
    if not end.is_file(): raise EvidenceError(f"{path}: end sidecar missing")
    return rt,int(end.read_text().strip())
def logs(cell):
    paths=sorted((cell/"formal"/"bw").glob("randrw_bw.*.log"))
    if len(paths)!=JOBS: raise EvidenceError(f"{cell.name}: expected 128 logs, got {len(paths)}")
    sums={0:defaultdict(lambda:defaultdict(float)),1:defaultdict(lambda:defaultdict(float))}
    weights={0:defaultdict(lambda:defaultdict(float)),1:defaultdict(lambda:defaultdict(float))}; ids=[]
    for p in paths:
        m=re.fullmatch(r"randrw_bw.(\\d+).log",p.name)
        if not m: raise EvidenceError(f"unexpected log {p.name}")
        jid=int(m.group(1)); ids.append(jid); prev={0:0.,1:0.}; seen=set()
        for row in csv.reader(p.open()):
            if not row or not any(row): continue
            if len(row)<3: raise EvidenceError(f"{p}: direction missing")
            end,val,dr=float(row[0])/1000,float(row[1])/1024,int(row[2])
            if dr not in (0,1) or end<prev[dr]: raise EvidenceError(f"{p}: bad row")
            start,prev[dr]=prev[dr],end; seen.add(dr)
            for sec in range(math.floor(start),math.ceil(end)):
                ov=min(end,sec+1)-max(start,sec)
                if ov>0: sums[dr][sec][jid]+=val*ov; weights[dr][sec][jid]+=ov
        if seen!={0,1}: raise EvidenceError(f"{p}: missing direction")
    if sorted(ids)!=list(range(1,JOBS+1)): raise EvidenceError("job ids incomplete")
    return {dr:{sec:sum(x[j]/weights[dr][sec][j] for j in x) for sec,x in sums[dr].items() if len(x)==JOBS and all(weights[dr][sec][j]>0 for j in range(1,JOBS+1))} for dr in (0,1)}
def window(series,start=15,stop=175):
    if any(i not in series for i in range(start,stop)): raise EvidenceError("formal window incomplete")
    v=[series[i] for i in range(start,stop)]; cuts=[round(i*len(v)/4) for i in range(5)]; ws=[statistics.mean(v[cuts[i]:cuts[i+1]]) for i in range(4)]; mean=statistics.mean(v)
    return {"mean_MiBs":mean,"median_MiBs":statistics.median(v),"cv_pct":statistics.pstdev(v)/mean*100 if mean else math.inf,"p10_MiBs":percentile(v,.1),"p90_MiBs":percentile(v,.9),"windows_MiBs":ws,"w4_w1":ws[-1]/ws[0] if ws[0] else math.inf}
def metrics(path):
    out={}
    for line in path.read_text().splitlines():
        m=re.match(r"^([A-Za-z_:][A-Za-z0-9_:]*(?:\\{[^}]*\\})?)\\s+([-+0-9.eE]+)$",line)
        if m:
            n=m.group(1).split("{",1)[0]
            if n in METRICS: out[n]=out.get(n,0)+float(m.group(2))
    missing=[n for n in METRICS if n not in out]
    if missing: raise EvidenceError("metrics missing: "+",".join(missing))
    return out
def usage(path): return {k:int(v) for k,v in (x.split("=",1) for x in path.read_text().strip().split("\\t"))}
def sampler(path,start):
    rows=list(csv.DictReader(path.open(),delimiter="\\t")); sel=[r for r in rows if start+15e9<=int(r["epoch_ns"])<start+175e9]
    if len(sel)<150: raise EvidenceError(f"sampler coverage {len(sel)}/160")
    ts=[int(r["epoch_ns"]) for r in sel]
    if max(b-a for a,b in zip(ts,ts[1:]))>2.5e9 or ts[-1]<start+173e9: raise EvidenceError("sampler timing contract")
    for r in sel:
        if any(r.get(k) in (None,"","NA") for k in ("rx_bytes","tx_bytes","cache_bytes","cache_blocks","hit_bytes","miss_bytes","evicts","drops")): raise EvidenceError("sampler field missing")
    delta=lambda k:int(float(sel[-1][k]))-int(float(sel[0][k]))
    h,mi=delta("hit_bytes"),delta("miss_bytes")
    return {"samples":len(sel),"hit_bytes_delta":h,"miss_bytes_delta":mi,"hit_ratio":h/(h+mi) if h+mi else 0,"evicts_delta":delta("evicts"),"drops_delta":delta("drops"),"cache_bytes_max":max(int(float(r["cache_bytes"])) for r in sel)}
def cell(root,name):
    c=root/"cells"/name
    if not (c/"PASS").is_file(): raise EvidenceError(f"{name}: PASS missing")
    rt,end=fio(c/"formal"/"fio.json"); start=end-rt*1000000; b=logs(c); read,write=window(b[0]),window(b[1]); m0=metrics(c/"metrics-mounted.txt"); mw=metrics(c/"metrics-warmed.txt") if TIERS[name] else m0; mf=metrics(c/"metrics-formal.txt"); h=mf["juicefs_blockcache_hit_bytes"]-mw["juicefs_blockcache_hit_bytes"]; mi=mf["juicefs_blockcache_miss_bytes"]-mw["juicefs_blockcache_miss_bytes"]
    return {"cell":name,"cache_GiB":TIERS[name],"runtime_ms":rt,"read":read,"write":write,"mean_direction_MiBs":(read["mean_MiBs"]+write["mean_MiBs"])/2,"start_ns":start,"sampler":sampler(c/"runtime.tsv",start),"hit_ratio":h/(h+mi) if h+mi else 0,"cache_gauge_GiB":mf["juicefs_blockcache_bytes"]/1024**3,"cache_usage":usage(c/"cache-usage-formal.tsv"),"formal_evicts":mf["juicefs_blockcache_evicts"]-mw["juicefs_blockcache_evicts"],"formal_drops":mf["juicefs_blockcache_drops"]-mw["juicefs_blockcache_drops"]}
def analyze(root):
    rows=[cell(root,n) for n in CELLS]; by={x["cell"]:x for x in rows}; idx={n:i for i,n in enumerate(CELLS)}
    def anchor(n):
        i=idx[n]; l,r=(0,4) if i<4 else (4,7); a=by[CELLS[l]]["mean_direction_MiBs"]; b=by[CELLS[r]]["mean_direction_MiBs"]; return a+(b-a)*(i-l)/(r-l)
    effects={n:(by[n]["mean_direction_MiBs"]/anchor(n)-1)*100 for n in CELLS if TIERS[n]}; a=[by[n]["mean_direction_MiBs"] for n in ("A0-pre","A0-mid","A0-post")]; drift=max(abs(x/y-1)*100 for x in a for y in a if x!=y)
    return {"schema":1,"run_id":root.name.removeprefix("opencode-04tmp2j-"),"cells":rows,"a0_drift_pct":drift,"effects_mean_direction_pct":effects,"resolution":"RESOLUTION_INSUFFICIENT" if drift>8 else "SUFFICIENT_FOR_L1_CURVE","verdict":"READ_CACHE_RANDRW_CURVE_COMPLETE" if all(x["sampler"]["samples"]>=150 for x in rows) else "EVIDENCE_INVALID"}
def self_test(root):
    root.mkdir(parents=True,exist_ok=True); q=window({i:100. for i in range(180)}); assert q["mean_MiBs"]==100 and q["w4_w1"]==1; return {"status":"PASS","cells":CELLS}
def main():
    p=argparse.ArgumentParser(); s=p.add_subparsers(dest="cmd",required=True)
    for cmd in ("analyze","self-test"):
        q=s.add_parser(cmd); q.add_argument("--root",type=Path,required=True); q.add_argument("--output",type=Path,required=True)
    a=p.parse_args(); r=analyze(a.root) if a.cmd=="analyze" else self_test(a.root); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(r,indent=2,sort_keys=True)+"\n"); print(r.get("verdict",r.get("status")))
if __name__=="__main__": main()

