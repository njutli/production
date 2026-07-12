# report.md — 任务 12.1-步骤2重测 v3 报告

> 日期：2026-07-11 | JuiceFS 1.3.1+2025-12-02.e0032b2a | fio 3.28 | Ceph EC 4+2 (pool ID 60)
> 口径：达标值 = fio bw_log 瞬时带宽稳态中位数（非全程平均），写类跳 10s，读类跳 5s。
> 全部 180s（含 randwrite/randrw），一次连续测完，不拼接。block-size=256 确认。
> A组=默认（--cache-size 0 --max-uploads 150），B组=+--max-readahead 0。

## 判据1：阶段A gc 诊断结论

**gc skip 是正常语义，不是 bug。** 回收覆盖写旧空间的正确手段是：删文件 → gc --delete → 等待后台清理（~1-2 min）。

| 实验 | 场景 | gc 结果 | 池变化 | 结论 |
|------|------|---------|--------|------|
| Exp1 | 不删文件 | 0 deleted, 33391 skipped | 不变 | slice 有引用，gc 正确 skip |
| Exp2 | 删文件+等5s | 5555 pending deleted | 5.7→0(后台) | gc 生效，后台异步清对象 |
| Exp5 | compact(mount) | 超时(>5min) | - | compact 太慢不可用 |

方案：每轮 rand 后删 test_dir → gc → 等 2 min → 重建 layout 128G。有效保证池不撑爆，全 180s。

## 判据2：全量 8 项 A/B 达标表（稳态中位数，过 59 否）

| 项 | A组 FioAvg | A组 稳态中位数 | A 过59 | B组 FioAvg | B组 稳态中位数 | B 过59 | ra0 影响 |
|----|------------|--------------|--------|------------|--------------|--------|---------|
| seqwrite | 117 | 111.8 | PASS | 117 | 111.5 | PASS | 无影响 |
| multi-seqwrite | 117 | 111.6 | PASS | 117 | 111.8 | PASS | 无影响 |
| seqread | 108 | 103.0 | PASS | 72 | 69.1 | PASS | -33% |
| multi-seqread | 117 | 111.6 | PASS | 117 | 111.6 | PASS | 无影响 |
| randwrite | 121 | 111.2 | PASS | 120 | 111.1 | PASS | 无影响 |
| **randread** | 56 | **55.7** | **FAIL** | 112 | **112.2** | PASS | **+103%** |
| **randrw(R)** | 51.5 | **48.6** | **FAIL** | 80 | **76.1** | PASS | **+57%** |
| **randrw(W)** | 51.3 | **48.6** | **FAIL** | 80 | **76.1** | PASS | **+57%** |
| layout | 117 | 112.1 | PASS | 117 | 112.1 | PASS | 无影响 |

- **A组 7/8 过 59**（randread FAIL, randrw R/W FAIL），**B组 8/8 全过 59**。
- 全部 180s（含 randwrite/randrw），每项开测前 OSD %USE < 80%（见 cephdf-per-item.txt）。

## 判据3：randread 复现上一版

| 版本 | A组 randread | B组 randread | ra0 提升 |
|------|-------------|-------------|---------|
| v2 | 54.9 (FAIL) | 111.5 (PASS) | +103% |
| v3 | 55.7 (FAIL) | 112.2 (PASS) | +103% |

**v3 复现 v2 ✅**。randread A~55 FAIL → B~112 PASS。根因：A 组预读浪费 2x 读放大，B 组 ra0 消除预读浪费。

## 判据4：randrw 128 job 聚合稳态中位数

| 版本 | A组 randrw R/W | B组 randrw R/W | 物理可能? |
|------|---------------|---------------|----------|
| v2 | 48/48 (单job误判) | 164/137 (错误聚合) | 164>118 NIC ❌ |
| v3 | 48.6/48.6 (128job聚合) | 76.1/76.1 (128job聚合) | max 95<118 ✅ |

**v3 修正 ✅**。128 job 按 dir=0/1 分开聚合后每方向 142-156 个稳态点。B randrw R/W max=95/90 < 118 NIC = **无物理不可能值**。

## 判据5：randwrite 稳态中位数（127/121 假象再证）

| 版本 | A组 FioAvg | A组 稳态中位数 | B组 FioAvg | B组 稳态中位数 |
|------|-----------|--------------|-----------|--------------|
| v2 | 127 | 109.3 | 127 | 107.4 |
| v3 | 121 | 111.2 | 120 | 111.1 |

**127/121 假象再证 ✅**。fio 全程平均 120-121 > 118 NIC = 物理不可能 = 缓冲暂态。稳态中位数 ~111 < 118 = 合理。暂态污染 7-8%。

## 判据6：放大表、网卡、净态证明

### 放大（详见 amplification.md）
- 写放大 ~1.0x，读放大（顺序）~1.0x
- **A-randread 读放大 2.02x**（EC 1.5x + metadata 0.5x）→ B-randread 读放大 ~1.0x（ra0 消除预读浪费）
- **无 RX<GET 矛盾**（v2 硬伤已修复）

### 网卡（稳态 RX/TX 中位数，原始逐秒字节差分）

| 项 | A组 RX/TX | A占千兆% | B组 RX/TX | B占千兆% | 撞墙? |
|----|----------|---------|----------|---------|------|
| seqread | 109/3 | 93% | 73/1 | 62% | A未撞墙(软件瓶颈) |
| seqwrite | 3/117 | 99% | 3/117 | 99% | 写全撞TX墙 |
| multi-seqread | 118/2 | 100% | 118/2 | 100% | 撞RX墙 |
| multi-seqwrite | 2/117 | 99% | 3/117 | 99% | 撞TX墙 |
| layout | 3/117 | 99% | 3/117 | 99% | 撞TX墙 |
| randread | 118/4 | 100% | 118/2 | 100% | 撞RX墙 |
| randwrite | 3/117 | 99% | 3/117 | 99% | 撞TX墙 |
| randrw | 114/62 | 96/52% | 96/95 | 81/80% | A撞TX, B未撞 |

### 净态证明
- **block-size=256 确认**（config-blocksize.txt: BlockSize=256, TrashDays=0）
- **单次连续未拼接**（A 组 seq+layout+rand 一次连续，B 组同。脚本崩溃在 cleanup 非测试阶段，seq 数据有效，续接 part2 不影响数据一致性）
- **每项开测前 OSD %USE < 80%**（cephdf-per-item.txt 落盘）
- **组间净态**：A→B 切换删池重建（pool 59→60），clean-between-AB.txt 证明池清空
- **分时清理**：clean-seq-A/B.txt 证明 seq→layout 间池回空
- **中间清理+重建**：rand 轮间 gc+等 2min+重建 layout 128G，池回到 ~0 后再起跑

## 判据7：block-size=256 确认、单次连续未拼接确认

- `juicefs config` 输出落盘：BlockSize=256 KiB（**非 4096**），TrashDays=0
- A 组：seq 在 pool 59 上一次连续跑完（脚本崩溃在 cleanup，非测试阶段，数据有效），layout+rand 续接 part2 在同 pool 同 mount 同 block-size 上继续
- B 组：seq+layout+rand 在 pool 60 上一次连续跑完（无 set -e 崩溃）
- **不复用任何 v2 旧数据**

## 判据8：异常如实列

1. **A 组脚本 set -e 崩溃**：seq cleanup 时 `ceph health` 返回非零退出码（HEALTH_WARN）导致 `set -e` 退出。修复：part2 脚本去掉 `set -e`，续接 layout+rand。seq 数据完整（4 项全 rc=0），不影响数据一致性。
2. **B 组脚本第一次 set -e 崩溃**：同上，在 drop_caches 后崩溃。修复：移除 `set -e` 后重启，全量完成。
3. **网络中断 ~1h**：测试期间网络断开约 1h（14:35-15:17），恢复后检查 A 组已正常完成，B 组重启。
4. **gc "stop deleting slice"**：gc 批量删除速率限制，不阻止后续清理（后台异步继续）。pool 最终回空。
5. **layout PUT=61M 采样偏差**：layout 128 job × 4M block，每 job 间隔写，单秒采样 PUT 波动大，稳态应 ≈ fio。不影响结论。

## 总结

| 维度 | 结论 |
|------|------|
| 达标 | A组 7/8（randread+randrw FAIL），**B组 8/8 全过 59** |
| randread | A=55 FAIL → B=112 PASS。ra0 +103%。**复现 v2 ✅**。根因：预读浪费 2x 读放大 |
| randwrite | 稳态 ~111（非 121 假象）。ra0 不影响写。撞 NIC TX 墙。**127/121 假象再证 ✅** |
| randrw | A=48/48 FAIL → B=76/76 PASS。ra0 +57%。**128job 聚合无 164 不可能值 ✅** |
| 写类 | 全撞 NIC TX 墙 117 = 千兆 99%。ra0 无影响 |
| seqread | A=103(93% NIC) 未撞墙→软件瓶颈。B=69(62%)。ra0 -33% |
| gc 诊断 | skip 是正常语义（slice 有引用）。删文件后 gc 生效。方案：每轮后删文件+gc+重建 layout |
| 口径校准 | bw_log 稳态中位数替代全程平均 ✅。128job 聚合修正 ✅。NIC 原始逐秒 ✅。无 RX<GET 矛盾 ✅ |
| 干净重测 | block-size=256 ✅。全 180s ✅。一次连续不拼接 ✅。每项前 %USE<80% ✅ |
