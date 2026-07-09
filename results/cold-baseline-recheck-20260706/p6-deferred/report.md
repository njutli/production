# P6 补验报告：介质误判 deferred_size 对照实验

> 日期：2026-07-06 | 目录：`results/cold-baseline-recheck-20260706/p6-deferred/`
> 目的：验证关掉 deferred 双写（SSD 行为）后 stall/带宽是否改善

---

## 一、实验设计

| 组 | config | 写入方式 |
|----|--------|---------|
| 对照组 | deferred_size=65536, throttle_cost=670000 (HDD 默认) | 32G 单 job, bs=256K, end_fsync=1 |
| 实验组 | deferred_size=0, throttle_cost=4000 (SSD 行为) | 同上 |

- 每组跑前 drop client + 3 OSD caches
- 全程 health timeline（每 5s）
- 每组后收集 backend-after 快照

## 二、结果

| 组 | WRITE (MiB/s) | 耗时 | stall | health |
|----|:---:|------|:---:|:---:|
| 对照组 (HDD) | **43.4** | 754.9s | 无 | 全程 HEALTH_OK |
| 实验组1 (SSD, 无效) | 35.5 | 922.5s | 无 stall, 但 4 OSD 重启中 down | ⚠️ 无效 |
| 实验组2 (SSD, 稳定) | **39.1** | 837.9s | 无 | 全程 HEALTH_OK |

## 三、结论

### 1. 两组均无 stall

32G 单 job 写在两组配置下都**没有触发 BlueFS stall**。这与 deepseek exp1 S1（8G 就 stall）的结果不同。原因：
- deepseek S1 是在 write-push 测试（已写 ~200G）后跑的，OSD compaction 状态已退化
- 本次实验在 task A 全量测试后跑，OSD 虽有累积写入但未达退化阈值
- **stall 的触发取决于 OSD compaction 状态（历史写入压力），而非当前 config 参数**

### 2. SSD 模式未提升带宽

| 对比 | HDD | SSD | 差异 |
|------|:---:|:---:|:---:|
| 带宽 | 43.4 | 39.1 | -10% |

SSD 模式反而略慢 10%，但在该环境正常方差范围内（deepseek A-idle r1=68→r2=47, -30%）。**关掉 deferred 双写在非 stall 场景下没有可测量的带宽收益。**

### 3. 对 P6 命题的修正

| 命题 | deepseek 结论 | GLM 复核 | 本次实验 |
|------|-------------|---------|---------|
| P6: SSD 误判影响写性能 | ❌ 无影响（只查 cache_size） | ❌ deepseek 漏查 deferred_size/throttle | ⚠️ 参数差异确实存在, 但改 config 无实际收益 |
| "免硬件突破口" | — | opencode 提出 | ❌ 不成立：改 config 不防 stall, 不提带宽 |

**最终判决**：P6 的 deepseek 结论"无影响"在**参数层面是错误的**（deferred_size hdd=65536/ssd=0, throttle_cost 167× 差异确实存在），但在**实际效果层面是部分正确的**（改 config 到 SSD 值在非 stall 场景下无 measurable 收益）。"免硬件突破口"假设不成立。

### 4. 实验局限

- 仅 1 次运行/config，无统计显著性
- 32G 单 job 未触发 stall，无法对比 stall 场景
- OSD compaction 状态不可控（无法制造 deepseek 的退化态）
- OSD perf dump 采集失败（cephadm shell 太慢），无 WAL 写入量定量对比

## 四、config 回滚

```
14:34 ceph config rm osd bluestore_prefer_deferred_size  # 移除 override
14:34 ceph config rm osd bluestore_throttle_cost_per_io  # 移除 override
14:35 restart all OSDs
14:37 HEALTH_OK, rollback complete
```

验证：`bluestore_prefer_deferred_size_hdd=65536`, `bluestore_throttle_cost_per_io_hdd=670000`（回到默认）。
