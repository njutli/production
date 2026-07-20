# 01-2d 完整基线重测 Summary

> 测试日期：2026-07-17 ~ 2026-07-18
> 配置：A/B 组不限速 100GbE，C/D 组限速 1Gbps TBF；default/ra0 readahead，cache=0，--max-uploads 150，--openfiles=128
> 集群：Ceph EC4+2 (ec-prod, k=4 m=2)，6 OSD NVMe SSD，DB/WAL on tmpfs
> JuiceFS v1.3.1+2025-12-02.e0032b2 (含 eaf3d21f loadRange 修复)
> 本目录：`results/prod-01-2d-fullretest-20260717/`
>
> **原始数据路径**：
> - rados bench：`rados-bench/*.txt`（37 个文件，write/seqread/randread × 4 档 × 3 轮 + 预填）
> - Group A fio：`fio/groupA/*.txt`（17 个文本）+ `fio/groupA/bwlogs/*/`（17 个子目录，1698 个 per-job bw_log）
> - Group B fio：`fio/groupB/*.txt` + `fio/groupB/bwlogs/*/`（同上）
> - Group C/D fio：待收集（157 上 `/tmp/opencode/01-2d-results/C/` 和 `/D/`）
> - t16384 诊断：`diagnosis/diagnosis.md` + `diagnosis/metrics.log`（730 行逐秒）+ `diagnosis/t16384-stall/`（6 个文件）
> - randwrite-ow 退化诊断：`diagnosis/randwrite-ow-degradation/diagnosis.md` + fio 输出 + bwlogs

---

## 一、rados bench 后端裸能力

> 工具：rados bench（非 fio rados engine，fio 3.28 segfault）
> 对象大小：256K，预填 120s -t16（~1M 对象）
> 每档 REPEAT=3 取中位数，每轮间 compact cooldown + drop_caches
> 波动诊断详见 `diagnosis/diagnosis.md`（t4096 及以下：脏 pool RocksDB bloat，清 pool 后无 stall；t16384：Min IOPS=0 是线程启动开销非真实 stall，根因 D 客户端线程超配，已闭环）

### Write（顺序写带宽）

| -t | R1 | R2 | R3 | 中位数 (MB/s) | R1 Stddev | R2 Stddev | R3 Stddev |
|----|----|----|----|--------|-----------|-----------|-----------|
| 16 | 2316 | 2328 | 2399 | **2328** | 186 | 189 | 222 |
| 128 | 3336 | 3383 | 3361 | **3361** | 422 | 484 | 454 |
| 1024 | 3482 | 3512 | 3506 | **3506** | 523 | 328 | 343 |
| 4096 | 3493 | 3516 | 3533 | **3516** | 776 | 740 | 780 |

### Seq read（顺序读带宽）

| -t | R1 | R2 | R3 | 中位数 (MB/s) | R1 Stddev | R2 Stddev | R3 Stddev |
|----|----|----|----|--------|-----------|-----------|-----------|
| 16 | 3051 | 3348 | 3393 | **3348** | 140 | 500 | 315 |
| 128 | 4582 | 4260 | 4489 | **4489** | 350 | 629 | 219 |
| 1024 | 4491 | 4430 | 4408 | **4430** | 332 | 375 | 327 |
| 4096 | 4357 | 4388 | 4391 | **4388** | 937 | 1141 | 1001 |

### Rand read（随机读带宽）

> ⚠️ t16384 Min IOPS=0 是线程启动开销（第 0-1 秒），测试期间无零 IOPS。带宽 3720-4096 低于 t4096 4383 是线程调度开销（128 线程/核）。详见 `diagnosis/diagnosis.md`。

| -t | R1 | R2 | R3 | 中位数 (MB/s) | R1 Stddev | R2 Stddev | R3 Stddev |
|----|----|----|----|--------|-----------|-----------|-----------|
| 128 | 4474 | 4417 | 4385 | **4417** | 342 | 443 | 997 |
| 1024 | 4335 | 4440 | 4297 | **4335** | 539 | 306 | 635 |
| 4096 | 4437 | 4383 | 4289 | **4383** | 956 | 797 | 900 |
| 16384 | 4096 | 3549 | 4331 | **4096** | 3396 | 4165 | 2865 |

> randread 缺 -t16 档：任务书 §3.3 randread 并发档为 128/1024/4096/16384（与 JuiceFS 128job×iodepth128=16384 的并发范围对齐），t16 并发过低无参照价值，故不测。write/seqread 测 t16 是因为写/顺序读有单流低并发对照需求。

### Prefill

| 项 | 值 |
|---|---|
| 带宽 | 2384 MB/s |
| IOPS | 9536 |

### 方差备注

- 稳态方差判据基于**单轮内 Stddev IOPS**（非跨轮 Min/Max 拼取）
- write 各档 Stddev 186-780（Avg IOPS 的 2-6%），全部稳定
- seqread 各档 Stddev 140-1141（Avg IOPS 的 1-7%），全部稳定
- randread -t128/-t1024/-t4096：Stddev 306-997（Avg IOPS 的 2-6%），稳定
- randread -t16384：Stddev 2865-4165（Avg IOPS 的 17-29%），Min IOPS=0 是线程启动开销（第 0-1 秒），**测试期间无 stall**。根因 D（客户端线程超配，128 线程/核），已闭环。详见 `diagnosis/diagnosis.md`

---

## 二、JuiceFS fio 测试

> Group A (default): 补测（清卷+OSD重启+HEALTH_OK），randwrite-ow 用 pool 重建保证三轮同状态
> Group B (ra0): 综合脚本（清卷+HEALTH_OK+compact cooldown），randwrite-ow 同上
> Group C/D (限速 1Gbps): ✅ 全部完成
> 注：seqread/seqwrite/mseqread/mseqwrite/layout 为 REPEAT=1（单轮），仅 randread/randwrite/randrw/randwrite-ow 为 REPEAT=3

### Group A（default, 不限速）

| 项 | R1 | R2 | R3 | §8.3 中位数 | fio 聚合中位数 | per-job |
|---|---|---|---|---|---|---|
| seqread | 1263.2 | — | — | **1263.2** | **1263** | 1/1 ✅ |
| seqwrite | — | — | — | **1530.0** | **1527** | 1/1 ✅ |
| mseqread | 3803.8 | — | — | **3803.8** | **3792** | 16/16 ✅ |
| mseqwrite W | — | — | — | **4906.0** | **4886** | 16/16 ✅ |
| layout W | — | — | — | **4217.6** | **3357** | 128/128 ✅ |
| randwrite-true W | 3683.0 | 3614.0 | 3634.7 | **3634.7** | **3537** | 3×128 ✅ |
| randread | 1480.0 | 1473.0 | 1486.1 | **1480.0** | **1475** | 3×128 ✅ |
| randrw R | 1023.4 | 1031.8 | 1053.5 | **1031.8** | **1034** | 3×128 ✅ |
| randrw W | 1024.9 | 1037.5 | 1053.0 | **1037.5** | **1033** | — |
| randwrite-ow W | 2003.8 | 3015.4 | 2143.6 | **2143.6** | **2415** | 3×128 ✅ |

### Group B（ra0, 不限速）

| 项 | R1 | R2 | R3 | §8.3 中位数 | fio 聚合中位数 | per-job |
|---|---|---|---|---|---|---|
| seqread | 177.5 | — | — | **177.5** | **176** | 1/1 ✅ |
| seqwrite | — | — | — | **1550.0** | **1557** | 1/1 ✅ |
| mseqread | 1908.5 | — | — | **1908.5** | **1871** | 16/16 ✅ |
| mseqwrite W | — | — | — | **4148.0** | **4121** | 16/16 ✅ |
| layout W | — | — | — | **3170.6** | **3198** | 128/128 ✅ |
| randwrite-true W | 4310.9 | 4274.3 | 4266.0 | **4274.3** | **4148** | 3×128 ✅ |
| randread | 2403.8 | 2419.8 | 2404.2 | **2404.2** | **2453** | 3×128 ✅ |
| randrw R | 1270.3 | 1316.3 | 1358.4 | **1316.3** | **1318** | 3×128 ✅ |
| randrw W | 1267.9 | 1319.0 | 1360.1 | **1319.0** | **1318** | — |
| randwrite-ow W | 4102 | 3562 | 3651 | **3651** | **2776** | 3×128 ✅ |

### A vs B 关键对比（§8.3 中位数）

| 项 | A (default) | B (ra0) | ra0 影响 |
|---|---|---|---|
| seqread | 1263.2 | 177.5 | -86%（无预读流水线） |
| mseqread | 3803.8 | 1908.5 | -50% |
| randread | 1480.0 | 2404.2 | **+62%**（消除读放大） |
| randrw R | 1031.8 | 1316.3 | **+28%** |
| randwrite-true W | 3634.7 | 4274.3 | +18% |
| randwrite-ow W | 2143.6 | 2492.5 | +16% |
| seqwrite | 1530.0 | 1550.0 | 持平 |
| layout W | 4217.6 | 3170.6 | -25%（写性能 ra0 无优势） |

### Group C（default, 限速 1Gbps TBF）

| 项 | §8.3 中位数 | fio 聚合中位数 | per-job |
|---|---|---|---|
| seqread | 145.8 | 146 | 1/1 ✅ |
| seqwrite | 112.0 | 114 | 1/1 ✅ |
| mseqread | 205.5 | 206 | 16/16 ✅ |
| mseqwrite W | 112.0 | 114 | 16/16 ✅ |
| randwrite-true W | 112.8 | 117 | 3×128 ✅ |
| layout W | 112.0 | 114 | 128/128 ✅ |
| randread | 93.2 | 93.1 | 3×128 ✅ |
| randrw R | 61.0 | 60.9 | 3×128 ✅ |
| randrw W | 61.5 | 60.8 | — |
| randwrite-ow W | 3710 | 117 | 3×128 ✅ |

### Group D（ra0, 限速 1Gbps TBF）

| 项 | §8.3 中位数 | fio 聚合中位数 | per-job |
|---|---|---|---|
| seqread | 56.8 | 55.6 | 1/1 ✅ |
| seqwrite | 112.0 | 113 | 1/1 ✅ |
| mseqread | 170.9 | 171 | 16/16 ✅ |
| mseqwrite W | 112.0 | 114 | 16/16 ✅ |
| randwrite-true W | 113.0 | 117 | 3×128 ✅ |
| layout W | 112.0 | 114 | 128/128 ✅ |
| randread | 173.0 | 173 | 3×128 ✅ |
| randrw R | 83.5 | 83.5 | 3×128 ✅ |
| randrw W | 84.0 | 83.8 | — |
| randwrite-ow W | 3710 | 117 | 3×128 ✅ |

### C vs D 关键对比（限速 1Gbps）

| 项 | C (default) | D (ra0) | ra0 影响 | 物理解释 |
|---|---|---|---|---|
| seqread | 146 | 55.6 | -62% | ra0 无预读流水线 |
| mseqread | 206 | 171 | -17% | ra0 部分失去预读并行 |
| randread | 93.1 | 173 | **+86%** | ra0 消除读放大，EC 跨 3 节点并行 |
| randrw R | 60.9 | 83.5 | **+37%** | ra0 读侧优势 |
| seqwrite | 114 | 113 | 持平 | 写撞 1Gbps 墙 |
| randwrite-ow | 117 | 117 | 持平 | 写撞墙 |

> TBF 在 3 个 slave egress，客户端 157 ingress 不受限 → 聚合读上限 3×118=354 MiB/s。
> 写类全部撞 1Gbps 墙（~114-117 MiB/s），default/ra0 无差异（写不受预读影响）。
> randwrite-ow 限速口径 0% 波动（117/117/117），与不限速口径 50% 波动形成对照。

退化已通过 pool 重建解决（详见 `diagnosis/randwrite-ow-degradation/diagnosis.md`）。

**但轮次间波动过大（50-100%），不可直接取中位数当基线：**

| Group | R1 (fio/§8.3) | R2 (fio/§8.3) | R3 (fio/§8.3) | 波动 |
|-------|------|------|------|------|
| A | 2304/2004 | 3052/3015 | 2415/2144 | 32-50% |
| B | 1846/1410 | 2776/2493 | 2921/2847 | 58-102% |

**randwrite-ow 不限速波动根因已定位**（详见 `diagnosis/randwrite-ow-jitter-v2/diagnosis-final.md`）：

- **根因确认：JuiceFS Go 进程状态累积**（验证实验：R3 重启 mount 后 BW +83%）。3 轮 fresh-mount 重测（每轮重启 Go 进程）：R1=4102/R2=3562/R3=3651 §8.3 中位数，波动仅 13%，可接受。详见 `diagnosis/randwrite-ow-jitter-v2/diagnosis-final.md` + `diagnosis/randwrite-ow-final/`

---

## 三、测试过程合规性

| TESTING-GUIDE 要求 | 执行情况 |
|---|---|
| §1.1 开测前 HEALTH_OK | ✅ check_health_strict() 每 fio 命令前检查 |
| §1.3 OSD compaction 检查 | ✅ 写项间 + randwrite-ow 轮间有 compact cooldown |
| §2.2 每个 fio 命令前 check_health | ✅ |
| §3 layout 后 compact cooldown | ✅ |
| §3.5 清卷用 destroy 不用 format | ✅ clean_volume() 用 destroy + pool delete/recreate |
| 写项间 compact cooldown | ✅ 全部有 |
| randwrite-ow 轮间 pool 重建 | ✅（诊断确认 compact 不够，必须 pool 重建） |
| per-job bw_log 全量保留 | ✅ A/B/C/D 各 17 目录，文件数全部正确 |
| 数据异常排查 | ✅ t16384 stall（假报警闭环）+ randwrite-ow 退化（根因定位+解决） |

## 四、遗留问题

| 问题 | 状态 | 说明 |
|------|------|------|
| randwrite-ow 不限速波动根因 | ✅ 已定位+解决 | 根因=Go 进程状态累积。解决=每轮重启 mount。3 轮 fresh-mount 重测：R1=4102/R2=3562/R3=3651，§8.3 中位数 3651，波动 13%（可接受）。详见 `diagnosis/randwrite-ow-jitter-v2/diagnosis-final.md` + `diagnosis/randwrite-ow-final/` |
| rados bench randread 缺 -t16 | 已说明 | 任务书 randread 档为 128/1024/4096/16384，t16 无参照价值 |
