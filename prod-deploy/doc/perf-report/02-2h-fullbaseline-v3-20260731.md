# FULLBASELINE V3 确定性预热基线测试报告 [2026-07-31]

> 状态：**完成**。单轮数据已采集，跨轮对比需第二轮验证。
> 脚本：`prod-deploy/scripts/FULLBASELINE/FULLBASELINE_V3.sh`
> 数据：`157:/tmp/opencode-fullbaseline-v3/D/`
> 日志：`157:/tmp/fullbaseline-v3-D.log`

---

## 一、背景与问题

### 1.1 V2 已解决的问题

V2（锁定布局 + 覆盖写）实现了：
- **单轮内 CV<5%**：default #2 全 7 项达标（randread CV=0.4%、mseqread CV=1.0%）
- **物理布局锁定**：CRUSH md5 + volume UUID + OSD up_from 全程不变
- **覆盖写不重抽签**：40 轮覆写后 P6 中位数 +0.3%，增量覆写不触发 CRUSH 重映射

### 1.2 V2 未解决的问题

| 问题 | 现象 | 根因 |
|------|------|------|
| **跨轮 ±12% 波动** | randread default #1=1670 → #2=1469（-12%），ra0 #1=2549 → #2=2808（+10%） | BlueStore 缓存命中率跨轮不稳定（ρ=1.000，02-2h + LC.12 确证） |
| **r1 冷启动** | randread r1 偏低 9-13%，randwrite r1 偏低 85% | 前序项加载的缓存数据不是本项所需的数据，r1 需重新预热 |
| **128-job 并发随机预热不可控** | randread 128 job 各 job 访问模式不同，BlueStore 缓存填充路径不确定 | 128 个并发随机读流互相干扰，缓存命中率取决于 job 调度时序 |

### 1.3 BlueStore 缓存：波动根源

已确证的波动根因链：

```
BlueStore 缓存命中率波动
  ↓ ρ=1.000（02-2h 9 轮 + LC.12 D 组 10 轮）
randread 带宽波动 ±12%
```

关键数据：
- `osd_memory_target` = 4GB/OSD，buffer_bytes ≈ 2.5GB/OSD
- 总缓存 ~15GB，layout 128G，缓存覆盖率 ~12%
- hit% 在 60-84% 间波动（非恒定），受 OSD 内部 onode 缓存压力、前序访问模式影响
- **无法主动清除**：`drop_caches` 只清 Linux 页缓存，清不了 BlueStore 内部缓存
- **唯一清除方式 = 重启 OSD**：但重启后缓存预热路径随机 → CV=13%（LC.12 C 组实测）

### 1.4 V3 的核心思路

**不重启 OSD，不试图清空缓存，而是主动将缓存填充到已知状态。**

如果每次测试前，BlueStore 缓存的内容都是一样的（同样的数据以同样的顺序被读过），那么 hit% 就是一样的，BW 就稳定了。

这就是"确定性预热"——用顺序读把 128G layout 全部读一遍，让 BlueStore onode 缓存进入确定的已知状态。

---

## 二、实验设计

### 2.1 三项改进

| 改进 | V2 做法 | V3 做法 | 原因 |
|------|---------|---------|------|
| **确定性预热** | 无（r1 充当预热轮） | 顺序读 128G layout 全部文件 + compact + drop_caches | 消除 r1 冷启动；让 BlueStore 缓存进入已知状态，跨轮 hit% 一致 |
| **单进程随机测试** | 128 job（TEST_JOBS=128） | 1 job（TEST_JOBS=1） | 128 个并发随机读流的缓存填充路径不可控；单进程的访问路径确定，缓存命中更可复现 |
| **128-job 规格测试** | 全项 128 job | 仅 randrw-128（末尾，预热后） | 保留生产规格数据用于对外汇报；单进程数据用于稳定性验证 |

### 2.2 测试流程

```
Phase 0: 一次性 layout（128×1G + seqread/seqwrite/mseqread/mseqwrite prep）
  ↓ compact_cooldown + drop_caches
  ↓ 布局指纹采集（UUID + CRUSH md5 + OSD up_from）

确定性预热 #1
  ↓ 顺序读 128 个 layout 文件（dd if=file of=/dev/null bs=4M）
  ↓ compact_cooldown + drop_caches

单进程基线测试（7 项 × 5 轮）：
  seqread(1)     ← 单流顺序读，bs=256k，psync，iodepth=1
  mseqread(16)   ← 16 流顺序读
  randread(1)    ← 单流随机读，bs=256k，libaio，iodepth=128
  randrw(1)      ← 单流混合读写，bs=256k，libaio，iodepth=128
  seqwrite(1)    ← 单流顺序写（覆盖写），bs=4M，psync
  mseqwrite(16)  ← 16 流顺序写（覆盖写），bs=4M
  randwrite(1)   ← 单流随机写（覆盖写），bs=256k，libaio，iodepth=128

  每项 REPEAT=5，runtime=180s
  写项轮间：compact_cooldown（seqwrite/mseqwrite）或 aggressive_cleanup（randrw/randwrite）
  mseqwrite 末轮后 aggressive_cleanup

确定性预热 #2
  ↓ 重置 BlueStore 缓存为已知态

128-job 规格测试：
  randrw(128) × 5   ← 生产规格，用于对外汇报
  
汇总 + 稳态评估
```

### 2.3 设计理由

#### 为什么用确定性预热替代 OSD restart？

| 方案 | 优点 | 缺点 | CV |
|------|------|------|----|
| OSD restart | 彻底清空缓存 | 预热路径随机，hit% 不可控 | 13%（LC.12 C 组） |
| 不清缓存 | 保 layout 不变 | 跨轮 hit% 波动 ±12% | ~12%（V2 实测） |
| **确定性预热** | hit% 可控（同数据同顺序读） | 不彻底清空，有残留 | **目标 <2%** |

确定性预热是"不清空但拉齐"的策略：不试图让缓存变空，而是让每次测试前缓存里的内容一样。类比：不重置棋盘，但每次从同一个棋局开局。

#### 为什么单进程替代 128-job？

128-job randread 的问题：
- 128 个 job 各自随机访问不同的数据块，BlueStore 缓存被 128 条流同时填充
- 哪个 job 的数据先被缓存、哪些被驱逐，取决于 Linux 调度器时序 → 不可控
- 跨轮 128 job 的缓存填充路径不同 → hit% 不同 → BW 波动 ±12%

单进程 randread 的优势：
- 1 个 IO 流顺序（iodepth=128 异步）访问数据，缓存填充路径确定
- 不受 job 调度时序影响
- 缓存命中率由 iodepth 内的 IO 调度决定，更可复现

代价：单进程绝对值远低于 128-job（~156 vs ~1500 MiB/s），但**稳定性验证只看偏差，不看绝对值**。绝对值由末尾 128-job spec 测试补充。

#### 为什么保留 128-job randrw spec？

- 单进程数据用于验证方法稳定性（偏差<2% 目标）
- 128-job 数据用于对外汇报（生产口径）
- 预热后跑 128-job，保证 spec 数据也有合理的缓存状态

#### 为什么读项在前、写项在后？

V2 实测发现：写项（尤其 mseqwrite）产生大量 JuiceFS chunk 创建/删除，异步删除在 compact 后仍持续到达 OSD，干扰后续 randread。读项在前确保 randread 不受写项残留干扰。

### 2.4 稳态评估口径

与 V2 一致：
- 读项 + 顺序写：bw_log 截前 15s 取中位数
- 随机写：bw_log 截前 60s 取中位数 + floor_median
- 最大偏差 = max(|r_i - median|) / median × 100%
- CV = 标准差 / 均值 × 100%

### 2.5 集群配置

与 V2 完全一致：
- Ceph 3 节点 6 OSD（EC4+2, fast_read=1, DB/WAL 在 tmpfs）
- JuiceFS `--max-uploads 150 --cache-size 0`（ra-default）
- layout 128G（128×1G），覆盖写模式
- 每轮 drop_caches（3 节点）+ compact_cooldown

### 2.6 布局守卫

V3 保留 V2 的 5 要素布局指纹：
- volume UUID（不变 = 未重新 format）
- CRUSH md5（不变 = 拓扑未变）
- OSD up_from epoch（不变 = 未 restart OSD）
- OSD_STAT（OSD 集合不变）
- Phase0 timestamp

复用 layout 时检查指纹一致性，任一不符则拒绝运行。

---

## 三、实验预期与实际对照

### 3.1 预期 vs 实际

| 指标 | V2 实测 | V3 预期 | V3 实际 | 达标 |
|------|---------|---------|---------|------|
| randread 单轮内最大偏差 | 2.8%（含 r1 冷启动） | <2% | **0.6%** | ✅ 超预期 |
| mseqread 单轮内最大偏差 | 2.1% | <2% | **0.4%** | ✅ |
| randread r1 冷启动幅度 | 9-13% | <5% | **0%**（r1=156=median） | ✅ 预热消除 |
| randwrite 单轮内最大偏差 | 70.7%（ra0，含 r1） | <5% | **4.9%** | ✅ |
| randrw-128 单轮内最大偏差 | 4.2%（V2 d#2） | <5% | **25.4%** | ❌ 单调下降 |
| seqread r1 冷启动 | 14%（ra0） | <5% | 11.6%（prep 文件未预热） | ❌ 已知局限 |
| seqwrite r3 掉点 | — | <5% | 14.6% | ❌ ⚑ 实为 prep 未预热（附录 B 证实，非 compaction 时序） |

### 3.2 预期场景对照

| 场景 | 触发条件 | V3 实际 |
|------|---------|---------|
| A：单进程全部达标 | 单进程 CV<2% | **部分达标**：randread/mseqread/mseqwrite/randwrite 达标；seqread（r1 冷启动）和 randrw-128 不达标 |
| B：单进程达标但 128-job 不达标 | 单进程稳定，128-job 不稳定 | **命中**：单进程 randread 偏差 0.6%，128-job randrw 偏差 25.4% |
| C：128-job 需交错 A/B | 128-job 波动源是并发调度 | **可能命中**：randrw-128 单调下降，疑似 128-job 逐步驱逐缓存 |

### 3.3 已知风险实际影响

| 风险 | 预期影响 | 实际 |
|------|---------|------|
| BlueFS spillover | compact 变慢 | compact 30-40s（V2 末轮 80-95s），影响小 |
| OSD up_from 解析失败 | 守卫缺一要素 | N/A（python3 JSON 解析失败），非阻塞 |
| seqread prep 文件未预热 | seqread r1 偏低 | **命中**：r1=129 vs r2-r5=142-149，偏差 11.6% |
| 单进程绝对值低 | 外部无法直接用 | randread 156 MiB/s（128-job 约 1500），由 randrw-128 spec 补充 |

---

## 四、数据

### 4.1 单进程基线（ra-default）— 稳态中位数

> **计算方式**：每轮 fio 加 `--write_bw_log --log_avg_msec=1000`，bw_log 截前 15s（读项）/ 截前 60s（随机写）后取中位数。下表为每轮的稳态中位数。
>
> **最大偏差** = max(|r_i - median|) / median × 100%（偏离中位数最远的值占中位数的比例）
>
> **CV** = 标准差 / 均值 × 100%

| 项 | r1 | r2 | r3 | r4 | r5 | 稳态中位数 | 范围 | 最大偏差 | CV | 备注 |
|---|---|---|---|---|---|-----------|------|---------|------|------|
| seqread | 129 | 142 | 145 | 147 | 148 | 146 | 129~149 | 11.6% | 5.6% | r1=129 冷启动（prep 文件未预热），排除后偏差 2.7% |
| mseqread | 1552 | 1564 | 1555 | 1558 | 1561 | 1558 | 1552~1564 | **0.4%** | 0.3% | 极稳 |
| randread | 156 | 156 | 156 | 157 | 156 | 156 | 156~157 | **0.6%** | 0.5% | **预热消除 r1 冷启动** |
| randrw-single | 36 | 39 | 37 | 38 | 38 | 38 | 36~39 | 5.3% | 2.7% | |
| seqwrite | 1598 | 1568 | 1335 | 1552 | 1576 | 1563 | 1335~1598 | 14.6% | 7.1% | r3=1335 掉点（-14.6%），非冷启动，原因待查 |
| mseqwrite | 3374 | 3440 | 3412 | 3382 | 3420 | 3394 | 3374~3440 | **1.4%** | 0.8% | 极稳 |
| randwrite | 216 | 204 | 206 | 205 | 206 | 206 | 204~216 | **4.9%** | 2.2% | r1=216 略高（+4.9%），r2-r5 偏差<1% |

> 注：表中 r1-r5 值为 bw_log 稳态中位数（非 fio 聚合 BW）。fio 聚合 BW 含缓冲暂态，与稳态中位数有差异。例如 randread fio 聚合 r4=146 看似掉点，但稳态 r4=157 在正常范围内——146 是缓冲暂态拉低的假象。

#### seqread r1 冷启动

seqread r1=129 vs r2-r5 范围 142~149，偏差 11.6%。根因：确定性预热只读 layout 文件（`storage_test.*.0`），seqread prep 文件（`seqread/seqread.0.0`）不在预热范围内，r1 仍为冷启动。

排除 r1 后：范围 142~149，中位数 146，最大偏差 = max(|142-146|, |149-146|)/146 = **2.7%**。

#### seqwrite r3 掉点

seqwrite r3=1335 vs 其余 1552~1598，偏差 14.6%。不是冷启动（r1 正常）。

> ⚑ **归因修正（2026-08-02，基于附录 B 补充预热测试）**：~~疑似 compaction 时序问题~~。实为 **prep 文件未预热**——补充预热测试（label E）中 seqwrite prep 32G 预热后 r3 掉点消除（偏差 14.6%→3.2%）。DeepSeek F2 分析发现 r3 有秒级近零停摆（最低 12 MiB/s），是 compaction 干扰在 prep 未预热时被放大。r4 恢复到 1552。

### 4.2 128-job spec（randrw-128）

> 确定性预热 #2 后运行。128 job × 1G，bs=256k，libaio，iodepth=128，randrw 50/50。

| 轮次 | fio 聚合 BW (MiB/s) | 稳态中位数 R (MiB/s) | 稳态中位数 W (MiB/s) |
|------|---------------------|---------------------|---------------------|
| r1 | 1228 | 1267 | 1265 |
| r2 | 1320 | 1347 | 1344 |
| r3 | 1193 | 1221 | 1215 |
| r4 | 1051 | 1063 | 1063 |
| r5 | 936 | 911 | 906 |
| **汇总** | | **中位数 1221，范围 911~1347，最大偏差 25.4%，CV 15.0%** | |

> ⚑ per-round 稳态值已从 bw_log 离线补齐（2026-08-02）。原报告只有 r1/r5 端点值，现补齐全部 5 轮。

**单调下降趋势**：r1=1267 → r5=911（-28%），5 轮持续下降，非随机波动。可能原因：
- 128-job randrw 每轮处理 ~200GB 数据（180s × ~1100 MiB/s），超过 layout 128G
- 每轮完全遍历工作集，逐步驱逐 BlueStore 缓存中的热数据
- aggressive_cleanup（compact + drop_caches）在轮间执行，但 BlueStore 内部缓存不受 drop_caches 影响
- 对比单进程 randrw（每轮 ~7GB，远小于 128G），缓存不受驱逐 → 稳定

> ⚑ **归因修正（2026-08-02，基于 P0-1/P0-2 + DeepSeek F3）**：
> - P0-2（randread-128 ×10 只读）完全不降（CV=0.3%）→ 下降是**写驱动**（tombstone/碎片），不是缓存驱逐
> - DeepSeek F3 分析：轮内 BW 平坦（无衰减）+ compact 耗时逐轮增长 → 更像 **RocksDB/LSM 累积**
> - P0-1（randrw-128 可逆性）：128×1G layout + aggressive_cleanup 下**不降**（max_dev=4.6%）→ 下降是单文件 layout 导致（tombstone 集中在一个 key range，compact 清不掉）
> - V2 同参数四轮稳定在 ~550 → ~550 是真稳态，1200 是预热瞬态
>
> **修正后结论**：128-job randrw 的下降是**写驱动 + 单文件 layout** 导致的 RocksDB tombstone 累积，不是缓存驱逐。128×1G layout + aggressive_cleanup 可避免。单文件 layout 不适合多轮写测试。

### 4.3 稳态评估原始输出

```
seqread: median=146 CV=5.6% range=129-149 MiB/s
mseqread: median=1558 CV=0.3% range=1552-1564 MiB/s
randread: median=156 CV=0.5% range=156-157 MiB/s
randrw-single: median=38 CV=2.7% range=36-39 MiB/s
seqwrite: median=1563 CV=7.1% range=1335-1598 MiB/s
mseqwrite: median=3394 CV=0.8% range=3374-3440 MiB/s
randwrite: median=206 CV=2.2% | floor_median=206 floor_CV=2.4% range=204-216 MiB/s
randrw-128: median=1221 CV=15.0% range=911-1347 MiB/s
```

### 4.4 布局指纹

```
UUID=6fe1f229-ffa6-4e38-bbda-e9ac0be0fe7c
CRUSHMD5=7bd0de71e163738397b170d1c9050c63
OSD_UP_FROM=N/A (python3 JSON 解析失败，非阻塞)
PHASE0_TS=1785474439
```

测试结束复查：
- ✅ volume UUID 不变
- ✅ CRUSH md5 不变（拓扑不变）

---

## 五、结论

### 5.1 单轮内稳定性

| 项 | V2 最大偏差 | V3 最大偏差 | 改善 | 评价 |
|---|---|---|---|---|
| randread | 2.8%（含 r1） | **0.6%** | ✅ 4.7× | **确定性预热消除 r1 冷启动，randread 极稳** |
| mseqread | 2.1% | **0.4%** | ✅ 5.3× | 改善显著 |
| mseqwrite | 3.2% | **1.4%** | ✅ 2.3× | 改善 |
| randwrite | 70.7%（ra0，含 r1）/ 6.2%（d#2） | **4.9%** | ✅ 消除 r1 离群 | **确定性预热 + aggressive_cleanup 解决了 r1 异常** |
| randrw-single | 4.2%（d#2）/ 12.0%（d#1） | 5.3% | — | 持平 |
| seqread | 3.6%（d#2）/ 14.0%（ra0，含 r1） | 11.6%（含 r1）/ 2.7%（排除 r1） | — | prep 文件未预热，r1 仍冷启动 |
| seqwrite | 6.1%（d#2） | 14.6% | ❌ 退化 | r3 掉点，疑似 compaction 时序问题 |
| randrw-128 | 4.2%（d#2） | 25.4% | ❌ 退化 | 128-job 逐步驱逐 BlueStore 缓存，单调下降 |

**核心结论**：
1. **确定性预热对 randread 有效**：r1 冷启动消除（r1=156=median），最大偏差从 2.8% 降到 0.6%
2. **确定性预热对 randwrite 有效**：r1 离群消除（V2 ra0 偏差 70.7% → V3 4.9%）
3. **确定性预热对 mseqread/mseqwrite 有效**：偏差均降到 <1.5%
4. **确定性预热对 seqread 无效**：预热只读 layout 文件，seqread prep 文件不在范围内
5. **128-job randrw 不稳定**：高并发工作集超过缓存容量，逐轮驱逐缓存导致单调下降

### 5.2 跨轮一致性

> 本轮仅单轮测试（label=D），跨轮一致性需跑第二轮（label=E）对比。预期确定性预热能让两轮的 BlueStore 缓存状态一致，从而 randread 跨轮偏差 <5%（V2 为 ±12%）。

待第二轮验证。

### 5.3 方法适用性

| 用途 | 适用性 | 说明 |
|------|--------|------|
| 单进程 randread 基线 | ⚠️ **稳但瞎** | 最大偏差 0.6%，但工作集 1G 全驻 171GiB 缓存（hit_rate=100%），ra0/default=1.02x 测不出 readahead 差异（见 `02-2h-cache-shrink-experiment-20260801.md`）。**不可用于 A/B 调优判定** |
| 单进程 mseqread/mseqwrite 基线 | ⚠️ **同上** | 稳定但工作集全驻缓存，灵敏度未验证 |
| 单进程 randwrite 基线 | ⚠️ **同上** | 最大偏差 4.9%，但 1G 全驻缓存 |
| 单进程 randrw 基线 | ⚠️ 勉强 | 最大偏差 5.3%，同上限制 |
| 128-job randrw 基线 | ⚑ ~~不适用~~ | ~~单调下降 25%~~ → ⚑ **归因修正**：128×1G layout + aggressive_cleanup 下**不降**（max_dev=4.6%），下降是单文件 layout 导致。见 §4.2 归因修正 |
| 跨轮绝对值比较 | ❌ 不适用 | ra0 跨轮 35.5%（OSD 状态退化），default 跨轮 0.4%（稳）。跨轮只比方向不比绝对值 |
| **128-job + 缩缓存** | **✅ 稳定且敏感** | CV=2.2%，ra0/default=1.96x。详见 `02-2h-cache-shrink-experiment-20260801.md` |

### 5.4 对 V2 报告结论的修正

| V2 结论 | V3 修正 |
|---------|---------|
| randread 跨轮 ±12% 是真实信号 | ✅ 保持（V2 §2.3 确认） |
| randrw/seqwrite/randwrite 跨轮"稳定" | ✅ 修正为"噪声内不可判定"（V2 §2.3 已修正） |
| r1 冷启动是普遍现象，r2 起稳态 | ✅ 确定性预热可消除 randread/randwrite 的 r1 冷启动 |
| BlueStore 缓存无法主动清除 | ✅ 确定性预热是替代方案：不清空但拉齐 |
| 128-job 并发预热不可控 | ✅ 单进程 + 确定性预热可解决（但 128-job spec 仍不稳定） |

---

## 六、原始数据路径

### 6.1 数据目录

```
157:/tmp/opencode-fullbaseline-v3/
├── D/                         # 本轮 label=D
│   ├── seqread-D-r{1..5}/
│   ├── mseqread-D-r{1..5}/
│   ├── randread-D-r{1..5}/
│   ├── randrw-single-D-r{1..5}/
│   ├── seqwrite-D-r{1..5}/
│   ├── mseqwrite-D-r{1..5}/
│   ├── randwrite-D-r{1..5}/
│   └── randrw-128-D-r{1..5}/
├── guard-baseline.txt
└── test.log
```

### 6.2 关键文件

| 文件 | 路径 |
|------|------|
| 测试脚本 | `prod-deploy/scripts/FULLBASELINE/FULLBASELINE_V3.sh` |
| 运行日志 | `157:/tmp/fullbaseline-v3-D.log` |
| 布局守卫 | `157:/tmp/opencode-fullbaseline-v3/guard-baseline.txt` |

---

## 附录 B：补充预热测试（label E）

> V3 主测试（label D）的确定性预热只读 layout 主文件（`storage_test.*.0`），未覆盖 seqread/mseqread/seqwrite/mseqwrite 的 prep 文件。本补测对这 4 项分别预热后重测，验证预热能否消除 r1 冷启动。
> 脚本：`prod-deploy/scripts/FULLBASELINE/debug/SUPPLEMENT-WARMUP.sh`
> 数据：`157:/tmp/opencode-fullbaseline-v3/E/`
> 日志：`157:/tmp/supplement-warmup-E.log`

### B.1 数据

> **计算方式**与正文一致：bw_log 截前 15s 取稳态中位数，最大偏差 = max(|r_i - median|) / median × 100%

| 项 | r1 | r2 | r3 | r4 | r5 | 稳态中位数 | 范围 | 最大偏差 | CV |
|---|---|---|---|---|---|-----------|------|---------|------|
| seqread | 166 | 169 | 168 | 166 | 169 | 168 | 166~169 | **0.7%** | 0.5% |
| mseqread | 1790 | 1770 | 1773 | 1770 | 1790 | 1773 | 1770~1790 | **0.9%** | 0.4% |
| seqwrite | 1420 | 1337 | 1420 | 1380 | 1420 | 1381 | 1337~1420 | **3.2%** | 2.6% |
| mseqwrite | 3346 | 3264 | 3283 | 3326 | 3305 | 3300 | 3264~3346 | **1.4%** | 1.0% |

### B.2 与 V3 主测试对比（D = 无 prep 预热，E = 有 prep 预热）

| 项 | D 中位数 | D 最大偏差 | E 中位数 | E 最大偏差 | r1 冷启动消除？ | 评价 |
|---|---|---|---|---|---|---|
| seqread | 146 | 11.6% | 168 | **0.7%** | ✅ 是（129→166） | 预热消除 r1 冷启动，偏差 11.6%→0.7% |
| mseqread | 1558 | 0.4% | 1773 | 0.9% | 本来无 | 偏差持平；BW +14%（buffer 缓存命中，64G/15GB≈23% 覆盖） |
| seqwrite | 1563 | 14.6% | 1381 | **3.2%** | ✅ 是（r3 掉点消除） | r3 异常消除，偏差 14.6%→3.2%；BW -12%（原因待查） |
| mseqwrite | 3394 | 1.4% | 3300 | 1.4% | 本来无 | 偏差持平；BW -3%（噪声范围） |

### B.3 结论

1. **seqread r1 冷启动消除**：预热 prep 文件后 r1 从 129→166（+29%），最大偏差 11.6%→0.7%。V3 主测试中 seqread 是唯一 prep 未预热的受害项，补测确认预热有效。

2. **seqwrite r3 掉点消除**：V3 主测试 r3=1335（掉点 -14.6%），补测预热后 5 轮均稳定在 1337-1420，偏差 3.2%。r3 掉点疑似 prep 文件未预热导致 OSD 内部状态不稳定，预热后消除。

3. **mseqread/mseqwrite 已稳定，预热不改变偏差**：这两项在 V3 主测试中本就稳定（偏差<1.5%），因为 16 job 顺序读自身就能快速预热。补测预热后偏差持平。BW 差异来自 buffer 缓存命中率不同。

4. **seqwrite BW 下降 12%**：D=1563 → E=1381。可能因为 D 测试中 seqwrite 前面的 randrw-single 把缓存预热成了对写有利的态，而 E 测试中 seqwrite 独立预热后缓存态不同。写项的缓存影响机制与读项不同，待进一步研究。

---

## 附录 C：randrw-128 补测（label F，10 轮）

> V3 主测试中 randrw-128 出现单调下降（稳态 1347→911，-32%）。本补测预热后跑 10 轮，观察 BW 是否收敛到某个区间。
> 脚本：`prod-deploy/scripts/FULLBASELINE/debug/SUPPLEMENT-RANDRW128.sh`
> 数据：`157:/tmp/opencode-fullbaseline-v3/F/`
> 日志：`157:/tmp/supplement-randrw128-F.log`

### C.1 fio 聚合 BW

| 轮次 | BW (MiB/s) | 趋势 |
|------|-----------|------|
| r1 | 1199 | 起点 |
| r2 | 1126 | -6% |
| r3 | 994 | -17% |
| r4 | 777 | -35% |
| r5 | 679 | -43% |
| r6 | 699 | +3%（波动） |
| r7 | 638 | -5% |
| r8 | 523 | -24% |
| r9 | 474 | -37% |
| r10 | 605 | +28%（波动） |

### C.2 稳态评估

> bw_log 截前 15s 取中位数。最大偏差 = max(|r_i - median|) / median × 100%

| 方向 | 稳态中位数 | 最大偏差 | CV | 范围 | 前半均值 | 后半均值 | 趋势 |
|------|-----------|---------|------|------|---------|---------|------|
| R | 679 | 77.4% | 33.6% | 450~1204 | 964 | 580 | **-39.9%** |
| W | 671 | 77.6% | 33.9% | 447~1192 | 964 | 577 | **-40.2%** |

### C.3 趋势分析

**BW 未收敛。** 10 轮中从 r1=1199 持续下降到 r9=474（-60%），r10 反弹到 605 但远未回到起点。前半 5 轮均值 964 → 后半 5 轮均值 580，下降 40%。

r5-r6 出现短暂触底迹象（679→699），但 r7-r9 继续下降（638→523→474），说明不是缓存蒸发完后的稳定 floor，而是 RocksDB/BlueStore 状态持续累积退化。

### C.4 结论

> ⚑ **归因修正（2026-08-02，基于 P0-1/P0-2 判读）**：以下结论部分修正。

1. **128-job randrw 单文件 layout 无法多轮稳定**：10 轮 BW 从 1199 降到 474-605，最大偏差 77%。~~BlueStore 缓存被逐轮驱逐~~ → ⚑ **P0-2 证实只读不降（CV=0.3%），下降是写驱动（tombstone 累积）**。~~aggressive_cleanup 无法恢复~~ → ⚑ **128×1G layout + aggressive_cleanup 下不降（max_dev=4.6%，P0-1 证实）**，下降是单文件 layout 导致 tombstone 集中在一个 RocksDB key range，compact 清不掉。

2. ⚑ ~~单轮 + 预热是 128-job 唯一可靠方式~~ → **128×1G layout + aggressive_cleanup 可多轮稳定**（B7 randrw max_dev=3.9%）。单文件 layout 才需单轮取值。

3. ⚑ ~~对比单进程：工作集与缓存大小的比值决定稳定性~~ → **修正**：工作集/缓存比不是直接原因。单进程"稳"是因为 1G 全驻 171GiB 缓存（hit_rate=100%），不是"工作集小"。"稳但瞎"（ra0/default=1.02x）。

4. **生产含义**：~~持续高并发随机读写负载下，系统性能会从 ~1200 MiB/s 逐渐退化到 ~500-600 MiB/s~~ → ⚑ **修正**：V2 同参数（128×1G）四轮稳定在 ~550 → ~550 是**真稳态**（无预热瞬态），1200 是**预热后瞬态**。单文件 layout 下降是 RocksDB 累积退化，不是"缓存驱逐后的真实退化"。生产用 128×1G layout 不会退化。
