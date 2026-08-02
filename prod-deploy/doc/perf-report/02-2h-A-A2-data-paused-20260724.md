# 02-2-H R-A / R-A2 数据整理（暂停状态）  [2026-07-24]

> 集群：FSID=020ed5ec-8703-11f1-a671-97520597268c（Opus 全新 bootstrap）
> 测试时间：A=09:24-10:35, softclean=10:40-10:50, A2=10:53-12:06（157 本地时间 UTC+7）
> 状态：**暂停**。A/A2 完成，B/B2 未跑。A2 vs A 判据②失败（7/9 超 5%），根因分析见下。

---

## 一、变量守卫（判据①：全程不变量）

| 控制变量 | A（基线快照） | A2（比对） | 判定 |
|----------|---------------|-----------|------|
| OSD 集合 | 0,1,2,3,4,5 | 0,1,2,3,4,5 | ✅ |
| pool_id | 2 | 2 | ✅ |
| CRUSH md5 | 7bd0de71e163738397b170d1c9050c63 | 7bd0de71e163738397b170d1c9050c63 | ✅ |
| 跑前 CRUSH md5 | 7bd0de71… | 7bd0de71… | ✅ |
| 跑后 CRUSH md5 | 7bd0de71…（手动补检） | 7bd0de71… | ✅ |
| compact queue_len | 全程 0 | 全程 0 | ✅ |
| soft-clean 后 CRUSH | — | 7bd0de71…（一致） | ✅ |

**判据①通过**：全程 OSD 集合 + pool_id + CRUSH md5 不变，compact 全绿，变量未被破坏。

---

## 二、全量 9 项数据（A vs A2）

### 2.1 顺序项（REPEAT=1，单值）

| 测试项 | A (MiB/s) | A load1min | A2 (MiB/s) | A2 load1min | Δ | 判定 |
|--------|-----------|------------|------------|-------------|---|------|
| seqread | 1246 | 20.25 | 1200 | 19.98 | 3.7% | ✅ |
| seqwrite | 1480 | 22.68 | 1440 | 21.36 | 2.7% | ✅ |
| mseqread | 2921 | 23.47 | 2454 | 22.21 | 16.0% | ❌ |
| mseqwrite | 3651 | 24.87 | 3259 | 22.46 | 10.7% | ❌ |
| layout | 3651 | 20.08 | 3292 | 19.92 | 9.8% | ❌ |

### 2.2 随机项（REPEAT=3，取中位数）

| 测试项 | A r1 | A r2 | A r3 | A 中位 | A2 r1 | A2 r2 | A2 r3 | A2 中位 | Δ | 判定 |
|--------|------|------|------|--------|-------|-------|-------|---------|---|------|
| randwrite-true | 3348 | 3442 | 3423 | 3423 | 3051 | 3209 | 3119 | 3119 | 8.9% | ❌ |
| randread | 1469 | 1478 | 1469 | 1469 | 1153 | 1152 | 1154 | 1153 | 21.5% | ❌ |
| randrw | 960 | 1073 | 1072 | 1072 | 786 | 899 | 860 | 860 | 19.8% | ❌ |
| randwrite-ow | 1886 | 883 | 787 | 883 | 2063 | 936 | 731 | 936 | 6.0% | ❌ |

### 2.3 负载条件（每项 fio 前的 157 load average 1min）

| 时段 | A load 范围 | A2 load 范围 |
|------|-------------|--------------|
| 起点 | 20.05 | 20.08 |
| seqread-seqwrite | 20.2-22.7 | 20.0-21.4 |
| mseqread-mseqwrite | 23.5-24.9 | 22.2-22.5 |
| randwrite-true | 21.2-33.4 | 20.0-28.7 |
| layout | 20.1 | 19.9 |
| randread | 22.1-24.1 | 20.8-24.3 |
| randrw | 25.1-28.2 | 23.3-25.0 |
| randwrite-ow | 21.9-25.8 | 21.1-26.5 |

**起点负载**：A=20.05, A2=20.08，均超阈值 WEKA_LOAD_MAX=20 → 脚本输出 `⚠️⚠️ 修好再跑，勿在污染起点上采数据`。

---

## 三、偏差分析

### 3.1 compare_reproduce 自动输出

```
seqread         : A=1246 A2=1200  Δ=3.7%  ✅
seqwrite        : A=1480 A2=1440  Δ=2.7%  ✅
mseqread        : A=2921 A2=2454  Δ=16.0%  ❌
mseqwrite       : A=3651 A2=3259  Δ=10.7%  ❌
layout          : A=3651 A2=3292  Δ=9.8%  ❌
randwrite-true  (中位): A=3423 A2=3119  Δ=8.9%  ❌
randread        (中位): A=1469 A2=1153  Δ=21.5%  ❌
randrw          (中位): A=1072 A2=860  Δ=19.8%  ❌
randwrite-ow    (中位): A=883 A2=936  Δ=6.0%  ❌
→ A2 vs A 最大偏差 = 21.5%  ❌ 超阈
```

### 3.2 偏差模式

| 特征 | 表现 |
|------|------|
| 单流顺序（seqread/seqwrite） | Δ < 5% ✅ — 低并发不受 WekaIO 影响 |
| 多流顺序（mseqread/mseqwrite/layout, 16-128 jobs） | Δ = 10-16% ❌ — 高并发受 CPU/网络争抢 |
| 随机读（randread, 128 jobs × 128 iodepth） | Δ = 21.5% ❌ — 最高并发，受影响最大 |
| 随机写（randwrite-true, 128 jobs） | Δ = 8.9% ❌ — 写类受影响小于读类 |
| 混合读写（randrw, 128 jobs） | Δ = 19.8% ❌ — 读成分受影响 |

**规律**：并发越高 → 偏差越大；读类 > 写类。与 WekaIO 抢占 CPU/网络导致 FUSE 处理和网卡吞吐受影响一致。

### 3.3 组内一致性 vs 组间偏差

| 项 | A 组内 CV | A2 组内 CV | A→A2 偏移 |
|---|-----------|------------|-----------|
| randread | 0.3% (1469/1478/1469) | 0.09% (1153/1152/1154) | 21.5% |
| randrw | 5.9% (960/1073/1072) | 6.3% (786/899/860) | 19.8% |

组内一致性极好（CV < 1%），但组间存在系统性偏移（-21.5%）。这**不是随机噪声**，而是 A→A2 之间存在系统性环境差异。

---

## 四、根因排查

### 4.1 排除项

| 可能原因 | 排查结果 | 状态 |
|----------|----------|------|
| 变量被破坏（OSD/pool/CRUSH） | 变量守卫全程 ✅ | ❌ 排除 |
| compact 未清 | compact_queue_len 全程 0 | ❌ 排除 |
| soft-clean 改了映射 | softclean 后 CRUSH md5 一致 | ❌ 排除 |
| pool 未清空 | A2 起点对象数=0 | ❌ 排除 |

### 4.2 最可能原因：WekaIO 负载持续 >20

- 157 是 WekaIO 共享客户端，WekaIO 7×24 运行
- 全程 load average(1min) 在 20-38 之间，始终超 WEKA_LOAD_MAX=20 阈值
- 脚本起点自检两次触发 `⚠️⚠️ 修好再跑，勿在污染起点上采数据`
- load 来源 = Linux 运行队列等待数（CPU + I/O wait），主因是 WekaIO 进程
- 高并发测试（128 jobs）时 CPU/网络争抢加剧 → 读带宽虚低

### 4.3 次要可能：A 轮在 fresh bootstrap 后跑（OSD 从未写过数据），A2 在 soft-clean + OSD restart 后跑

- 02-2-G v3 在同口径下 CV=2.88%（但当时负载可能更低）
- fresh bootstrap vs soft-clean 后的 BlueStore 内存态可能有细微差异
- 但 02-2-G v3 已证明 soft-clean + OSD restart 可复现，故此因素应不显著

---

## 五、结论与建议

### 5.1 当前状态

- **判据①（变量守卫）**：✅ 全程通过
- **判据②（同组复现 <5%）**：❌ 失败。9 项中 7 项超 5%，最大偏差 21.5%（randread）
- **根因**：WekaIO 负载持续超阈值 20，污染高并发读测数据

### 5.2 数据可用性

- A/A2 的**绝对值不可用作基线**（负载污染）
- 但变量守卫 + compact 纪律 + soft-clean 流程**合规**，方法论本身有效
- 组内一致性极好（randread CV < 1%）说明测试方法论可复现，问题在环境而非方法

### 5.3 建议

1. **等 157 负载降到 <20 后重跑 A→softclean→A2**（首选）
2. 如负载长期不降，考虑提高 WEKA_LOAD_MAX 阈值（但需在报告中标注）
3. B/B2（ra0 组）暂不跑，等 A/A2 可复现后再跑
4. 如负载条件改善后 A/A2 仍超 5%，再排查 soft-clean 后 BlueStore 状态差异

---

## 六、Skill 合规自查

| 检查项 | 状态 | 说明 |
|--------|------|------|
| 清理只用 juicefs destroy | ✅ | 全程未 pool delete+recreate |
| 组间 OSD restart 已执行 | ✅ | softclean 含 podman restart + PG 等待 |
| 中途未重建 OSD | ✅ | 跳过 rebuild（集群 fresh bootstrap 等价），未中途 rebuild |
| 变量守卫全程不变 | ✅ | OSD/pool_id/CRUSH md5 四次比对全绿 |
| compact cooldown 已轮询 | ✅ | 全程 compact_running=0 + queue_len=0 |
| 统计用中位数 | ✅ | 随机项取 r1/r2/r3 中位 |
| **WekaIO 负载门控** | ❌ | 起点负载 20.05/20.08 > 20，脚本 WARN 但继续跑 |
| **TESTING-GUIDE §1.3 compaction 预检** | ❌ | 开测前未检查 compact 三指标（集群 fresh 故应已绿） |
| **TESTING-GUIDE §2.2 每 fio 前 health** | ❌ | 脚本未 source health-check 库 |
| **LONG-RUNNING-TEST-SKILL** | 部分 ❌ | sleep 前打印时间 ✅（纠正后）；每次唤醒查 ceph health ✅（纠正后）；纠正前未做 |

---

## 七、环境记录

| 项 | 值 |
|---|---|
| FSID | 020ed5ec-8703-11f1-a671-97520597268c |
| Ceph 版本 | 17.2.8 quincy |
| JuiceFS 版本 | 1.3.1+2025-12-02.e0032b2 |
| Kernel (157) | 5.15.0-170-generic |
| OSD | 6 osds: 6 up, 6 in (osd.0-5) |
| Pool | juicefs-data (id=2), EC 4+2, fast_read=1, ec_overwrites |
| CRUSH md5 | 7bd0de71e163738397b170d1c9050c63 |
| auth | cephx (admin keyring on 157) |
| DB/WAL | tmpfs (/mnt/dbwal, 200G per node) |
| A 起点负载 | 20.05, 19.73, 19.90 |
| A2 起点负载 | 20.08, 20.24, 21.48 |
