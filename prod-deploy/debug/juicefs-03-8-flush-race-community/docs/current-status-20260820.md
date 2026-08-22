# 当前现状说明

## 日期：2026-08-20

---

## 1. Bug 概述

JuiceFS v1.3.1 的 `writer.go` 中，`prepareID` 以异步 goroutine 运行，需要与 `writeChunk` 竞争同一把 `fileWriter` 互斥锁。由于锁顺序的确定性，`s.id` 在 `writeChunk` 检查时始终为 0，导致满 block 的 `FlushTo` 被跳过——ID 就绪后 `SetID` 不补派发。这是锁顺序决定的 ordering bug，不是 data race。

该 bug 在 v1.3.1 上导致 randwrite 吞吐从 ~3000 MiB/s 塌至 551 MiB/s（缓冲节流自锁）。main 分支因排水路径优化（#6311、#7016）掩盖了该竞态，未表现塌态，但插桩实测跳过率 99.2%，竞态同样存在。

## 2. 补丁方案

| 方案 | 改动 | 效果 |
|------|------|------|
| A-sync | `go s.prepareID(...)` → `s.prepareID(...)`（同步） | 恢复性能，但阻塞首次 WriteAt、非 EIO 额外重试 |
| **B-async-catchup** | 保留异步，在 `SetID(s.id)` 后补 `FlushTo`，条件 `s.id > 0 && !s.freezed && int(s.slen) >= f.w.blockSize`，错误映射 `syscall.EIO` | 恢复性能，保留异步边界，不影响 WriteAt，五条语义保持 |

**B 为社区提交候选**，仅改 `pkg/vfs/writer.go`（7 行）+ `pkg/vfs/writer_flush_test.go`（3 项回归测试）。

## 3. 已完成测试

### U01：latest main 最小洁净回放（PASS）

- main commit `53835e24`（与 C03 frozen commit 相同）
- Stock：U1 10/10 FAIL+marker，U2 PASS，U3 10/10 FAIL+marker → TARGET-BEHAVIOR-PRESENT
- B patch 标准 `git apply` 成功，无 context-only port
- B 三项 single 3/3、count=100 300/300、race=20 60/60，无 DATA RACE
- Q C02 十项 single 10/10、count=20 200/200、race=5 50/50
- full pkg/vfs PASS，gofmt/vet/build 全通过
- R replay：B/R diff 一致，single 3/3、count=20 60/60
- **终态：PASS-B-LATEST-MAIN-MINIMAL**

### V02：v1.3.1 S/A/B 真实 Ceph 性能验证（PASS，B/A 非劣不可判）

- Latin-square 9 位置 × 6 fio = 54 runs，全部 rc=0，每 run 128 per-job bw log
- META_PROFILE=DAYTIME（meta rate 16,787/s ≥ 8,000/s）
- B integrity verify：rc=0，0 verify errors

#### Randwrite arm-level 稳态中位数

| 臂 | Arm-level (MiB/s) |
|---|---|
| S-stock | 560.9（< 1000，确认塌态） |
| A-sync | 1778.1（≥ 1653，确认恢复） |
| B-catchup | 1917.0（≥ 1653，确认恢复） |

#### 机械判据

| 指标 | 值 | 结论 |
|---|---|---|
| B/S | 3.42 | ✅ 观察恢复（≥3.0） |
| 0.70×B/S | 2.39 | ❌ 稳健 3× 不成立（<3.0） |
| B/A | 1.078 | ✅ 观察非劣（≥0.95） |
| 0.70×B/A | 0.755 | ❌ 稳健非劣不成立（<0.95） |
| randrw B/A (write) | 1.073 | ✅ 观察非劣（≥0.944） |
| randrw B/A (read) | 1.077 | ✅ 观察非劣（≥0.944） |

"稳健不成立"的原因：B/A 差距仅 7.8%，而 mount tier 噪声 ±30%，3 个 mount/arm 不足以做 5% 精密非劣证明。B 恢复是真实的（最坏档 B/S 仍有 2.39 倍）。

- **终态：PASS-B-V131-RECOVERY-A-COMPARISON-INCONCLUSIVE**

### V02-PRE / V02-PRE-R1：对象池恢复与重新认证（READY）

- V02-PRE：3h 自然观察停滞（NATURAL=STALLED），一次 `gc --compact` 清掉 5M 重叠 slice，objects 7.46M → 2.43M
- V02-PRE-R1：三次只读采样 objects=2,434,623 ≤ 3.11M，间隔 143s/158s
- 双证据 HANDOFF_CORE=PASS，ASSET_GATE=YES，HANDOFF_FINAL=PASS

## 4. 03-16：N1/N2 读边界实验（部分完成，Pair B STOP）

- 目标：用两个独立只读挂载测单/双挂载读扩展边界
- 36 个 randread fio run（只读），两个 pair 各 18 run

### 第一次执行（STOP）

- 系统负载 43（常态 24），因用户在 /tmp 做文件清理操作
- Pair A ns/B 判档三次失败（4.1~4.9 vs 预期 3.287 ±10%）
- 确认与环境干扰相关，非 B 补丁问题

### 第二次执行（Pair A 完成，Pair B STOP）

- 系统负载恢复 25，环境正常
- **Pair A：ns/B 判档通过，18 个 fio run 全部 rc=0，2400 bw log**
- **Pair B：ns/B 判档三次失败**
  - t1：Q 侧 ns/B=3.636，偏差 10.6%（差 0.6% 过门）
  - t2：P 侧 ns/B=4.925，偏差 49.8%
  - t3：P 侧 ns/B=4.744，偏差 44.3%
- t1 到 t2 之间环境突然变差（ns/B 从 3.6 跳到 4.9），原因待查
- Mounts 已清理，objects=2,434,620，health OK

### ns/B 偏高的可能原因

1. 环境干扰（文件操作、高负载）——第一次执行已确认
2. TiKV 元数据延迟波动——时钟漂移 0.067s 可能间接影响
3. ns/B 基线 3.287 本身可能随环境变化漂移——Pair A 通过但 Pair B 失败说明波动性大
4. B 补丁不改读路径和元数据路径，不影响 ns/B

## 5. 二进制变更

`/tmp/juicefs-03-8` 从 A-sync 版本替换为 B-catchup 版本：

| | 旧（A-sync） | 新（B-catchup） |
|---|---|---|
| 补丁 | loadRange + A-sync | loadRange + B-v1.3-port |
| 版本 | 1.3.1+2026-08-13.e0032b2a-03-8-ceph | 1.3.1+2025-12-02.e0032b2a |
| MD5 | 1f60618c44fda1c19fecd75d52e053e9 | de93563f11a5ff3bd94dd25a4e0283b1 |
| 旧版备份 | — | /tmp/juicefs-03-8-async-backup |

后续测试统一使用 B 版本。03-16 任务书的 expected md5 为旧 A-sync 版本，记录为已知偏差。

## 6. 集群当前状态

- Ceph：HEALTH_OK（时钟漂移间歇性 HEALTH_WARN，mon.ceph-node2 skew ~0.067s）
- Pool objects：2,434,620（≤ 3.11M 闸门）
- PG：33 active+clean，6 OSD up/in
- 无 JuiceFS 挂载和 session
- 历史遗留监控已清理
- 157 /tmp：~20G 可用

## 7. 证据位置

| 测试 | 报告 | Archive / 数据 |
|------|------|---------|
| U01 | `report/U01-execution-20260818-130955.md` | `/home/lilingfeng/tmp/juicefs-u01-20260818-130955-artifacts.tar.gz` |
| V02 | `report/V02-execution-20260819-110158.md` | `/home/lilingfeng/tmp/juicefs-v02-20260819-110158.tar.gz` |
| V02-PRE | `report/V02-PRE-execution-20260818-160041.md` | `/home/lilingfeng/tmp/juicefs-v02-pre-20260818-160041.tar.gz` |
| V02-PRE-R1 | `report/V02-PRE-R1-execution-20260819-102825.md` | `/home/lilingfeng/tmp/juicefs-v02-pre-r1-20260819-102825.tar.gz` |
| 03-16 | `/tmp/production/opencode-t3.16/`（157，Pair A 完整 18 runs，Pair B STOP） | 未归档 |
| 社区报告 | `community-submission/test-report.md` | — |

## 8. 待决事项

1. **03-16 Pair B STOP**：ns/B 波动大，需要分析方判断是否调整基线、放宽容差或等待环境更稳定时重试
2. **社区提交**：U01 + V02 证据已足够支撑 B patch 提交，等待用户/Codex 决定
3. **B/A 稳健非劣**：需要更多 mount 或独立验证才能升级为稳健非劣
4. **03-16 任务书 md5**：需更新 expected md5 以匹配 B 版本二进制，或保留为已知偏差
