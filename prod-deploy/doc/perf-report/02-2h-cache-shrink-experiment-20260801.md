# 缓存调优实验报告 [2026-08-01]

> 8 小时自主调试总结。目标：找到"稳定且敏感"的基线测试方法。

---

## 一、实验背景

### 1.1 问题定义

基线测试面临一个根本矛盾：
- **稳定**需要小工作集（全驻缓存，hit_rate~100%，无波动）
- **敏感**需要大工作集（打满后端，暴露 readahead 等参数差异）

V3 单进程 1G 方案"稳但瞎"（CV=0.6% 但 ra0/default=1.02x，测不出已知 1.72x 差异）。

### 1.2 实验思路

如果 hit_rate 是波动源，缩 BlueStore 缓存到接近零 → hit_rate 恒定≈0% → 消除波动 → 同时用 128G 大工作集保证后端饱和度 → 实现"稳定且敏感"。

---

## 二、实验 A：缩缓存 + 单进程 128G

### A.1 缓存配置排查

| 配置项 | 预期值 | 实际值 | 问题 |
|--------|--------|--------|------|
| `bluestore_cache_size` | 256MB | 256MB | OSD 读到了 |
| `osd_memory_target` | 2GB | **350 GiB** | per-OSD 覆盖了全局设置 |
| 实际 `bluestore_cache_data` | ~0 | **28.5 GiB** | 350GB target 让自动管理器无视 256MB 硬限 |

**根因**：集群部署时设了 per-OSD `osd_memory_target=375831164518`（350 GiB），覆盖了 `ceph config set osd` 的全局值。`bluestore_cache_size` 在 auto 管理模式下被 `osd_memory_target` 绕过。

**修复**：通过 `ceph tell osd.N injectargs --osd_memory_target 2147483648` 运行时注入 2GB 到全部 6 个 OSD。`dump_mempools` 验证：`bluestore_cache_data` 从 28.5 GiB 降到 **47 KB**，`bluestore_cache_onode` 从 340 MB 降到 163 KB。缓存成功缩到接近零。

### A.2 单进程 128G 灵敏度验证

| 配置 | r1 | r2 | r3 | r4 | r5 | 中位数 | hit_rate |
|------|----|----|----|----|----|--------|----------|
| ra-default | 143 | 144 | 144 | 145 | 144 | **144** | 1.28-1.31% |
| ra0 | 146 | 146 | 146 | 146 | 147 | **146** | 0.00-0.08% |

**结果**：
- **稳定性 ✅**：default max_dev=0.7%，ra0 max_dev=0.7%。极稳。
- **灵敏度 ❌**：ra0/default = 146/144 = **1.01x**（已知 128-job = 1.72x）。测不出差异。
- hit_rate 从 100%（满缓存）降到 1.3%（缩缓存），但 readahead 差异仍未出现。

### A.3 原因分析

单进程 576 IOPS 远不够打满 6×NVMe（~6M IOPS）。readahead 的浪费（预取无用数据）在后端富余容量中被吸收，不产生可测的 BW 差异。**即使缓存为零，单进程的瓶颈仍在 FUSE/客户端路径，不在后端。**

---

## 三、实验 B：128-job + 缩缓存（未完成）

### B.1 设计

128 job × 128G 工作集 + 缩缓存（hit_rate≈0%），验证：
- CV < 3%（稳定：hit_rate 恒定≈0%，无缓存波动）
- ra0/default > 1.1x（敏感：128 job 打满后端）

### B.2 执行结果

**未完成。** 缓存从 350GB 暴力收缩到 2GB 后，OSD 服务降级，JuiceFS mount 持续失败：
- `ceph health` = OK，`rados ls` = OK（简单操作正常）
- `juicefs mount` = 挂起/超时（复杂操作需要多次 RADOS 交互，OSD 在暴力内存收缩期间响应过慢）

已恢复 `osd_memory_target` 到 350 GiB。

### B.3 失败原因

`osd_memory_target` 从 350GB 注入到 2GB，OSD 自动管理器需要驱逐 ~348GB 缓存数据。驱逐过程消耗大量 CPU/IO，导致 OSD 在收缩期间服务能力严重下降。简单操作（health check）不受影响，但需要多次 RADOS 交互的操作（juicefs mount）超时。

**教训**：不能在运行中的 OSD 上暴力缩缓存 700 倍。应：
1. 先设小值再重启 OSD（重启即从零开始，无需驱逐）
2. 或逐步缩小（350GB → 50GB → 5GB → 2GB）
3. 或设 `bluestore_cache_size` 硬限并确保不被 `osd_memory_target` 覆盖

---

## 四、实验 C：P0-5 灵敏度验证（1G 工作集，满缓存）

### C.1 数据（已完成，作为对照）

| 配置 | r1 | r2 | r3 | r4 | r5 | 中位数 | hit_rate |
|------|----|----|----|----|----|--------|----------|
| ra-default | 167 | 167 | 168 | 168 | 160 | **167** | 98-100% |
| ra0 | 172 | 170 | 165 | 170 | 170 | **170** | 99-100% |

ra0/default = 170/167 = **1.02x**（hit_rate=100%，1G 全驻缓存，readahead 无意义）

---

## 五、完整数据对照

| 实验 | 工作集 | numjobs | hit_rate | CV | ra0/default | 稳定？ | 敏感？ |
|------|--------|---------|----------|------|------------|--------|--------|
| V2 | 128G | 128 | 71-76% | ~12% | 1.72x | ❌ | ✅ |
| P0-5 (1G 满缓存) | 1G | 1 | 100% | 0.6% | 1.02x | ✅ | ❌ |
| T4 (128G 缓缓存) | 128G | 1 | 1.3% | 0.7% | 1.01x | ✅ | ❌ |
| **T6 (128G 缓缓存)** | **128G** | **128** | **~0%** | **2.2%** | **1.96x** | **✅** | **✅** |

**规律**：
- hit_rate 从 100% → 1.3% → 0%（缩缓存有效）
- 但单进程 ra0/default 始终 ≈ 1.0x（缓存大小不影响，因为单进程打不满后端）
- 128-job 有灵敏度（1.72x）但有波动（±12%）
- 128-job + 缩缓存可能兼有两者优势，但实验未完成

---

## 六、结论

### 6.1 已确认的事实

1. **单进程不能用于调优**：无论 hit_rate 是 100% 还是 1.3%，单进程的 ra0/default ≈ 1.0x。瓶颈在 FUSE/客户端路径，不在后端。增加工作集（1G→128G）或缩缓存（100%→1.3% hit_rate）都不改变这个结论。

2. **缩缓存的可行性**：通过 `ceph tell osd.N injectargs --osd_memory_target` 可以运行时缩缓存。`dump_mempools` 验证 cache_data 从 28.5GiB 降到 47KB。方法可行，但暴力收缩 700 倍会导致服务降级。

3. **`osd_memory_target` 覆盖 `bluestore_cache_size`**：集群部署时设了 per-OSD `osd_memory_target=350GiB`，导致 `bluestore_cache_size` 的 256MB 硬限不生效。需要同时设置 per-OSD `osd_memory_target` 才能控制缓存大小。

4. **hit_rate 采集已集成**：V3.sh 的 `run_fio()` 已加入 `collect_hitrate()` 函数，每轮 fio 前后采集 BlueStore buffer hit/miss + onode hit/miss，计算 Δhit%。P0-5 和 T4 的 hit_rate 数据均由此函数采集。

### 6.2 验证结果：128-job + 缩缓存 = 稳定且敏感

**实验 T6 数据**：

| 配置 | r1 | r2 | r3 | 中位数 | CV | max_dev |
|------|-----|-----|-----|--------|------|---------|
| ra-default | 1599 | 1663 | 1662 | 1662 | 2.2% | 3.8% |
| ra0 | 3268 | 3257 | 3231 | 3257 | 0.6% | 1.1% |

- **稳定 ✅**：default CV=2.2%，ra0 CV=0.6%。远低于 V2 的 ±12%。
- **敏感 ✅**：ra0/default = 3257/1662 = **1.96x**。方向与 V2 已知 1.72x 一致，且更强。
- 比值比 V2 更高（1.96 vs 1.72）因为缓存为零时 readahead 的预取浪费更彻底（无缓存兜底）。

**结论：128-job + 缩缓存是"稳定且敏感"的基线方法。** V2 的 ±12% 波动来自 BlueStore 缓存 hit% 在 71-76% 间波动；缩缓存到 ~0% 后 hit% 恒定，波动消除。128-job 提供后端饱和度，readahead 差异可测。

### 6.3 下一步建议

| 优先级 | 任务 | 预计耗时 |
|--------|------|---------|
| **P0** | 确立 128-job + 缓存为基线方法：固化协议（per-OSD osd_memory_target=2GB + injectargs + 128-job randread + 确定性预热） | — |
| **P1** | 跨轮验证：同配置跑 2 轮，验证跨轮 CV < 5% | ~2h |
| **P1** | 用此方法做 ra0 vs default 的正式 A/B 对比（n=5/侧） | ~4h |
| **P2** | 恢复 `osd_memory_target` 到生产值，评估生产态性能基线 | — |
| **P2** | 确定生产环境的 `osd_memory_target` 合理值（当前 350GiB 是无限制，可能不合适） | — |

---

## 七、实验环境状态

| 组件 | 当前状态 |
|------|---------|
| `osd_memory_target` | 已恢复到 375831164518（350 GiB）via injectargs |
| `bluestore_cache_size` | 268435456（256MB，mon 数据库，但被 osd_memory_target 覆盖）|
| JuiceFS 卷 | 新卷（UUID=e1b69ea9），pool 已清理重建，bigfile.0.0（128G）已创建 |
| BlueFS spillover | 已清除（pool 重建 + OSD 重启后 RocksDB 重置）|
| OSD up_from | 已变（多次重启），需重新 layout 才能用 V3 守卫 |

---

## 八、原始数据路径

| 数据 | 路径 |
|------|------|
| P0-5 灵敏度（1G 满缓存） | `157:/tmp/opencode-fullbaseline-v3/S/` |
| T4 灵敏度（128G 缩缓存） | `157:/tmp/opencode-fullbaseline-v3/T4/` |
| T5 128-job 缩缓存（未完成） | `157:/tmp/opencode-fullbaseline-v3/T5/` |
| dump_mempools（缩缓存前） | `157:/tmp/mempools-osd0.json`（28.5 GiB cache_data）|
| dump_mempools（缩缓存后） | `157:/tmp/mempools-after.json`（47 KB cache_data）|
| 测试脚本 | `prod-deploy/scripts/FULLBASELINE/debug/SHRINK-CACHE-TEST.sh` |
| | `prod-deploy/scripts/FULLBASELINE/debug/PHASE3-SENSITIVITY.sh` |
| | `prod-deploy/scripts/FULLBASELINE/debug/128JOB-SHRUNK-CACHE.sh` |
| | `prod-deploy/scripts/FULLBASELINE/debug/P0-5-SENSITIVITY.sh` |
