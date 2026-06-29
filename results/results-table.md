# Test Results Summary

> Date: 2026-06-25 ~ 2026-06-26
> Env: 3-node Ceph (6 OSD, EC 4+2) / JuiceFS v1.3.1 / TiKV meta / 1Gbps
> mu = max-uploads, ra = max-readahead

## 1. Cold Baseline (cache=0, drop_caches)

| Test | cold-R1 | cold-R2 | Diff |
|------|---------|---------|------|
| seqread 1job | 78.7 | 79.4 | +0.9% |
| seqwrite 1job | 54.4 | 53.9 | -0.9% |
| multi-seqread 16job | 109 | 110 | +0.9% |
| multi-seqwrite 16job | 40.4 | 40.0 | -1.0% |
| layout 128G | 31.8 | 33.4 | +5.0% |
| randread r1-r3 | 29.7 | 31.8 | +7.1% |
| randwrite r1-r3 | 33.6 | 33.3 | -0.9% |
| randrw READ r1-r3 | 14.9 | 16.2 | +8.7% |
| randrw WRITE r1-r3 | 14.6 | 15.9 | +8.9% |

## 2. Warm Baseline (cache=100G, no drop_caches)

| Test | warm-R1 | warm-R2 | Diff |
|------|---------|---------|------|
| seqread 1job | 48.6 | 47.1 | -3.1% |
| seqwrite 1job | 53.5 | 51.6 | -3.6% |
| multi-seqread 16job | 107 | 107 | +0.0% |
| multi-seqwrite 16job | 39.0 | 39.5 | +1.3% |
| randread r6-r7 | 272 | 273 | +0.4% |
| randwrite r1-r7 | 48.8 | 45.3 | -7.2% |
| randrw READ r1-r7 | 14.9 | 13.6 | -8.7% |
| randrw WRITE r1-r7 | 14.6 | 13.4 | -8.2% |

## 3. All Tests Comparison

| Test | Config | seqR | seqW | mseqR | mseqW | layout | randR | randW | randrw R/W |
|------|--------|------|------|-------|-------|--------|-------|-------|------------|
| cold-R1 | Ceph-direct / block=256K (seq bs=4M, rand bs=256K) / cache=0 / mu=20 | 78.7 | 54.4 | 109 | 40.4 | 31.8 | 29.7 | 33.6 | 14.9/14.6 |
| cold-R2 | Ceph-direct / block=256K (seq bs=4M, rand bs=256K) / cache=0 / mu=20 | 79.4 | 53.9 | 110 | 40.0 | 33.4 | 31.8 | 33.3 | 16.2/15.9 |
| warm-R1 | Ceph-direct / block=256K (seq bs=4M, rand bs=256K) / cache=100G / ra=0 | 48.6 | 53.5 | 107 | 39.0 | - | 272 | 48.8 | 14.9/14.6 |
| warm-R2 | Ceph-direct / block=256K (seq bs=4M, rand bs=256K) / cache=100G / ra=0 | 47.1 | 51.6 | 107 | 39.5 | - | 273 | 45.3 | 13.6/13.4 |
| mu150 | Ceph-direct / block=256K (seq bs=4M, rand bs=256K) / cache=0 / mu=150 | - | 54.0 | - | 39.9 | - | - | - | - |
| rgw-4m-bs256k | S3/RGW(haproxy) / block=256K (seq bs=4M, rand bs=256K) / cache=0 / mu=150 | 76.1 | 23.0 | 108 | 20.7 | 19.6 | 27.7 | 30.1 | 11.1/11.1 |
| direct-4m-bs256k | Ceph-direct / block=256K (seq bs=4M, rand bs=256K) / cache=0 / mu=150 | 79.8 | 48.3 | 108 | 40.7 | 37.4 | 29.5 | 53.1 | 18.8/18.4 |

## 4. Key Findings

### 4.1 Baseline Reproducibility
- Cold: 2 rounds diff <10%, reliable
- Warm: seq R/W diff <5%; randread convergence trend consistent (r1->r7 increasing)

### 4.2 --max-uploads=150 No Effect
- seqwrite: 54.0 vs 54.4 (default 20), no improvement
- multi-seqwrite: 39.9 vs 40.4 (default 20), no improvement
- Cause: direct Ceph mode, EC write amplification coordinated by client, bottleneck is OSD latency not connection count

### 4.3 RGW Hurts Write Performance
- seqwrite: 23.0 (RGW) vs 48.3 (direct), -52%
- multi-seqwrite: 20.7 (RGW) vs 40.7 (direct), -49%
- Cause: extra HTTP hop + haproxy balance source may not truly load-balance

### 4.4 fio bs=4M / block-size=256K No Effect on Read
- seqread: 79.8 vs 79.4 (baseline), same
- multi-seqread: 108 vs 110 (baseline), same
- randread: 29.5 vs 29.7 (baseline), same
- Conclusion: JuiceFS aggregates/splits internally, bs != block-size has no significant read impact

### 4.5 Seq Write Gap vs Official Benchmark
- Official ~150+ MB/s, ours 54 MB/s
- Cause 1: cache=0 disables writeback, sync write to backend (Opus)
- Cause 2: EC 4+2 write amplification 6x vs S3 single PUT
- Cause 3: --max-uploads 20 vs 150 (verified no effect)

## 5. Result Directories

- **cold-R1**: `results/baseline-rerun-20260625/`
  - randread/write/rw: mean of r1-r3
- **cold-R2**: `results/baseline-rerun2-20260625/`
  - randread/write/rw: mean of r1-r3
- **warm-R1**: `results/warm-baseline-noRA-20260625/`
  - randread: mean of r6-r7 (converged); randwrite/rw: mean of r1-r7
- **warm-R2**: `results/warm-baseline2-20260625/`
  - randread: mean of r6-r7 (converged); randwrite/rw: mean of r1-r7
- **mu150**: `results/maxuploads150-20260626/`
  - seqwrite only
- **rgw-4m-bs256k**: `results/rgw-4m-bs256k-20260626/`
  - randread/write/rw: mean of r1-r3
- **direct-4m-bs256k**: `results/norgw-4m-bs256k-20260626/`
  - randread/write/rw: mean of r1-r3
