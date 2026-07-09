# 干净态 HDD/SSD deferred 对比重测报告

> 日期：2026-07-07
> 目录：`results/clean-deferred-retest-20260707/`
> 配置：patched v1.3.1 (1.3.1+2025-12-02.e0032b2a), cache=0, mu=150, bs=256K, EC 4+2
> 任务书：`doc/perf-tasks/task-clean-deferred-retest.md`

---

## 一、结论

**deferred=0 的后端 +23% 收益在干净态下不可复现。**

- 后端 rados：A2(SSD) 57.9 vs A1(HDD) 57.4 = **+0.9%**（此前 `cold-baseline-recheck-20260706` 测得 72.3 vs 58.6 = +23%，不可复现）
- 端到端 JuiceFS seqwrite：A4(SSD) 63.2 vs A3(HDD) 62.4 = **+1.3%**
- 端到端 multi-seqwrite：A4(SSD) 65.9 vs A3(HDD) 57.5 = **+14.6%**（仅 1 轮，不能排除方差）
- **deferred config 确认生效**：HDD 模式 deferred delta=+2026 writes/OSD；SSD 模式 delta=+1 write/OSD（几乎为零）

---

## 二、2×2 对比矩阵

| 组 | 路径 | deferred | throttle | r1 | r2 | r3 | 均值 | 单位 |
|----|----|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| A1 | rados bench 256K 3×60s | 65536 | 670000 | 68.5 | 51.8 | 51.9 | **57.4** | MB/s |
| A2 | rados bench 256K 3×60s | 0 | 4000 | 64.4 | 55.1 | 54.3 | **57.9** | MB/s |
| A3 | JuiceFS seqwrite 3×4G | 65536 | 670000 | 65.5 | 60.8 | 60.8 | **62.4** | MiB/s |
| A4 | JuiceFS seqwrite 3×4G | 0 | 4000 | 64.7 | 62.2 | 62.6 | **63.2** | MiB/s |
| A3 | JuiceFS multi-seqwrite 1×64G | 65536 | 670000 | - | - | - | **57.5** | MiB/s |
| A4 | JuiceFS multi-seqwrite 1×64G | 0 | 4000 | - | - | - | **65.9** | MiB/s |

> 注：rados bench 单位为 MB/s（rados bench 原始输出），JuiceFS fio 单位为 MiB/s。1 MiB/s ≈ 1.0485 MB/s。

### Delta 汇总

| 对比 | HDD | SSD | Delta |
|------|:---:|:---:|:---:|
| 后端 rados bench | 57.4 | 57.9 | **+0.9%** |
| 端到端 seqwrite | 62.4 | 63.2 | **+1.3%** |
| 端到端 multi-seqwrite | 57.5 | 65.9 | **+14.6%** |

---

## 三、Deferred Config 验证（关键证据）

### 3.1 deferred 计数器 delta（A1 HDD vs A2 SSD）

| OSD | A1(HDD) t0 | A1(HDD) tend | A1 delta | A2(SSD) t0 | A2(SSD) tend | A2 delta |
|-----|:---:|:---:|:---:|:---:|:---:|:---:|
| 0 | 175 | 2201 | **+2026** | 78 | 78 | **0** |
| 1 | 3157 | 5183 | **+2026** | 3082 | 3082 | **0** |
| 2 | 135 | 2161 | **+2026** | 70 | 70 | **0** |
| 3 | 3152 | 5178 | **+2026** | 3069 | 3069 | **0** |
| 4 | 3133 | 5159 | **+2026** | 3082 | 3082 | **0** |
| 5 | 3115 | 5141 | **+2026** | 3070 | 3070 | **0** |

> `issued_deferred_writes` 计数器。A1 每 OSD +2026 deferred writes（HDD 模式 deferred 生效）；A2 每 OSD +0（SSD 模式 deferred=0 完全关闭）。**证明 config 变更确实生效。**

### 3.2 A3/A4 deferred delta（JuiceFS 端到端）

| OSD | A3(HDD) delta | A4(SSD) delta |
|-----|:---:|:---:|
| 0 | +2026 | +1 |
| 1 | +2026 | +1 |
| 2 | +2026 | +2 |
| 3 | +2026 | +1 |
| 4 | +2026 | +1 |
| 5 | +2026 | +1 |

> A3 每 OSD +2026（与 A1 一致）；A4 每 OSD +1~2（极小残余，可能来自元数据小写）。**SSD 模式 deferred 几乎完全关闭。**

### 3.3 对象大小确认

```
对象名格式: juicefs-prod/chunks/0/XX/XXXXX_YY_262144
对象大小:   262144 bytes = 256 KiB
对象数:     ~312K (A3: 312309, A4: 312220)
```

JuiceFS 写 256K 对象 → EC 4+2 切 4×64K data chunk + 2×64K parity chunk → 64K 命中 HDD deferred 阈值 (65536) ✓

---

## 四、JuiceFS 层损耗量化

| 场景 | rados 256K | JuiceFS | 损耗 |
|------|:---:|:---:|:---:|
| HDD seqwrite (单job 4G) | 57.4 MB/s | 62.4 MiB/s ≈ 65.4 MB/s | **-13.9%**（JuiceFS 更快） |
| HDD multi-seqwrite (16job 64G) | 57.4 MB/s* | 57.5 MiB/s ≈ 60.3 MB/s | **-5.1%** |
| SSD seqwrite | 57.9 MB/s | 63.2 MiB/s ≈ 66.3 MB/s | **-14.5%**（JuiceFS 更快） |
| SSD multi-seqwrite | 57.9 MB/s* | 65.9 MiB/s ≈ 69.1 MB/s | **-19.3%** |

> *rados bench 是 16 线程并发写不同对象到同一池；fio multi-seqwrite 是 16 job 写不同文件。口径不完全一致，损耗值仅供参考。
>
> **JuiceFS seqwrite 反而比 rados bench 快**——因为 fio seqwrite 是单流顺序写（更高效），rados bench 是 16 线程并发写（更随机）。这不是 JuiceFS "负损耗"，而是 I/O pattern 不同。

---

## 五、+23% 不可复现的归因分析

### 5.1 此前 +23% 的来源

`cold-baseline-recheck-20260706/rados-deferred-comparison/`：
- HDD 58.6 MB/s, SSD 72.3 MB/s, +23%
- 该次 SSD 测试通过 `ceph config set` + `ceph osd crush set-device-class` 改 OSD class 实现

### 5.2 本次结果

- HDD 57.4, SSD 57.9, +0.9%
- deferred config 确认生效（delta=0），但无性能收益

### 5.3 可能原因

| 因素 | 说明 |
|------|------|
| **单次测量方差 > +23%（主因）** | 本轮 A1/A2 的 r1 比 r2/r3 高 17-32%（A1: 68.5 vs 51.8/51.9 = +32%；A2: 64.4 vs 55.1/54.3 = +17%）。单轮方差本身就超过 +23%，上轮 72.3 vs 58.6 各只跑 1 轮，完全可能是 r1 冷启动红利落在 SSD 组、没落在 HDD 组。本轮 3 轮均值后红利被摊平，差距收敛到 +0.9% |
| **上轮混入 PG 重映射变量（混淆因子）** | 上轮 `cold-baseline-recheck-20260706` 通过 `ceph osd crush set-device-class` 改 OSD class，这会触发 PG 重映射。重映射完成后 PG 分布、primary 角色可能与本轮不同。本轮用 `injectargs` 只改运行时参数，PG 分布不动。上轮的 +23% **可能根本不是 deferred 带来的**，而是 PG 重映射后 I/O 路径变化带来的，与 deferred=0 是两个变量混在一起 |

> 注：本轮每组开测前的「净态三确认」第二步 compact 到 queue_len=0 已将 RocksDB/BlueStore LSM 树压平到稳定态（memtable flush、各 level SST 收敛、无待合并输入），因此 **LSM 树状态差异不是原因**。此前版本的「BlueFS/RocksDB 状态可能不同」推测在 compact 充分的前提下不成立，已删除。

### 5.4 结论

**上轮 +23% 不可复现，不应作为决策依据。** 本轮 3 轮均值 HDD 57.4 vs SSD 57.9 = +0.9%，在测量方差范围内。deferred=0 在后端 rados 层面无明显收益。

---

## 六、multi-seqwrite +14.6% 信号

| | A3(HDD) | A4(SSD) | Delta |
|--|:---:|:---:|:---:|
| multi-seqwrite 64G | 57.5 MiB/s | 65.9 MiB/s | +14.6% |
| runtime | 1137s | 988s | -13.1% |

**仅 1 轮，不能排除方差。** 但如果真实，可能原因：
- multi-seqwrite 16 job 并发，deferred 双写在高并发下竞争更激烈
- deferred=0 消除双写后，高并发场景下 I/O 路径更短
- 需后续 ≥2 轮验证

---

## 七、异常与注意事项

| 项 | 说明 |
|----|------|
| **ceph config set + restart 不生效** | cephadm 部署的 OSD 有本地 config 文件覆盖 mon 数据库；需用 `ceph tell osd.X injectargs` 直接注入运行时 |
| **systemctl ceph-osd@X.service 不存在** | cephadm 服务名格式为 `ceph-<FSID>@osd.<X>.service` |
| **回滚后 HEALTH_WARN slow ops** | injectargs 切换 config 后 osd.0 出现 slow ops（临时，预计自动恢复） |
| **上轮 +23% 来源存疑** | 上轮通过改 OSD crush class 实现 SSD 模式，与本轮 injectargs 方式不同；可能是 class 切换导致的 PG 重映射而非 deferred 本身带来的收益 |

---

## 八、对下一步的建议

1. **deferred=0 不纳入基线**：后端 +0.9% 在方差范围内，不值得引入 config 变更风险
2. **multi-seqwrite +14.6% 需验证**：如有余力，补测 ≥2 轮 multi-seqwrite 确认是否真实
3. **上轮 72.3 标记为不可复现**：在后续分析中不再引用此数据点
4. **stall 防护**：deferred=0 虽无带宽收益，但之前验证可延迟 stall 5×（2min→11min），如需 stall 防护可考虑

---

## 九、文件清单

```
results/clean-deferred-retest-20260707/
├── ops.log                      # 全程操作 + config 改动/回滚 + 每次确认落盘
├── recovery-confirm-ssd.txt     # SSD 模式 五确认证据
├── clean-confirm-A{1,2,3,4}.txt # 每组开测前 净态三确认证据
├── A1/ rados-bench-r{1,2,3}.txt + osd-perf-t0/tend
├── A2/ 同上
├── A3/ seqwrite-r{1,2,3}.txt + multi-seqwrite-r1.txt + jfs-stats-* + object-size + osd-perf + health-timeline
├── A4/ 同上
└── report.md                    # 本报告
```
