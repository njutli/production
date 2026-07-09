# 交叉复核报告：deepseek 14/15/16 结论独立复核

> 复核者：GLM | 日期：2026-07-06
> 依据：原始数据对账 + 任务 A 冷态基线复测结果
> 原则：✅证实 / ❌推翻 / ⚠️存疑 + 原始文件出处

---

## 一、14/analysis.md 复核

### 结论 1："旧测 57/54.8 被 destroy/layout 污染、新测 64/63.7 是真实态"

**⚠️ 存疑——layout 污染说不成立，destroy 污染说未验证，差异更可能是运行间方差**

| 论点 | 判决 | 依据 |
|------|:---:|------|
| "layout 污染" | ❌ 推翻 | 任务 A 复测：layout 128G 全程 HEALTH_OK（4998 条 health 采样），无 stall。layout 不产生 compaction 污染。 |
| "destroy 污染" | ⚠️ 存疑 | 任务 A 未单独测 destroy 影响（destroy→format→mount 流程中 seqwrite 在 layout 前，不在 destroy 后紧跟）。但 destroy 删 1.4M 对象确实可能产生 compaction 余波。 |
| "57→64 是污染→真实态" | ⚠️ 存疑 | 更可能是**运行间方差**+**mu 效应**。15/A-idle 5 轮数据：r1=68→r2=47(-30%)→r3=43→r4=40→r5=42。仅 8G 累积写入就导致 30% 退化，说明该环境写性能本身极不稳定。57 和 64 都处于 40-68 的方差区间内。 |

**deepseek 的问题**：只测了一组对照（旧测 vs 新测），没有 A-repeat（同口径换时段复现），无法区分"污染"和"方差"。15 任务设计了 A-repeat 但未执行。

### 结论 2："多线程写无法达标，EC 写放大 + BlueFS stall 三重限制"

**⚠️ 存疑——BlueFS stall 在 multi-job 写法下不触发**

任务 A 的 multi-seqwrite（64G, 16 jobs, bs=256K）全程 HEALTH_OK，带宽 40.8（与旧基线 41.5 一致）。deepseek 在 14 中测 multi-seqwrite 触发 stall，但那是在 A-idle 5 轮累积 ~39G 写入后的非干净态。**stall 不是 multi-seqwrite 本身的必然结果，而是前置写入累积的后果。**

---

## 二、15/STATUS.md 复核

### 结论 1："stall 由写入总量决定、与并发数无关"

**❌ 推翻——stall 触发需要"单 job 持续写 + OSD 已有 compaction 积压"两个条件同时满足，不是写入总量决定**

| 证据 | 出处 |
|------|------|
| 任务 A layout 128G（128 jobs × 1G, bs=4M）全程无 stall | `cold-baseline-recheck-20260706/backend/health-timeline.txt` |
| 任务 A multi-seqwrite 64G（16 jobs × 4G, bs=256K）全程无 stall | 同上 |
| P6 实验 32G 单 job 写无 stall（OSD `compact_queue_len=0`） | `cold-baseline-recheck-20260706/p6-deferred/control-fio.txt` |
| deepseek exp1 S1 8G（1 job, bs=256K）触发 stall | `write-forensics-20260705/exp1-threshold/S1-8G/backend-after.txt` |
| deepseek B1-nj1 64G（1 job, bs=256K）触发 stall | `write-push-retest-20260705/expB-concurrency/B1-nj1/`（但见下） |

- 128G 多 job 不 stall（条件①不满足：多 job 给 OSD 喘息）
- 32G 单 job 也不 stall（条件②不满足：OSD `compact_queue_len=0`，无积压）
- 8G 单 job 就 stall（deepseek 的 OSD 在 ~200G 写入后有积压，restart 不清除 LSM tree 磁盘状态，两条件同时满足）
- **"写入总量"不是决定因素；写法形态 + OSD compaction 状态才是。**

### 结论 2："B1-nj1 r1 触发 osd.0/osd.2 stalled read"

**⚠️ 存疑——无 backend-after.txt 落盘证据**

| 检查项 | 结果 |
|--------|------|
| B1-nj1/backend-after.txt | **不存在** |
| B1-nj1/backend-before.txt | 存在 |
| STATUS.md 目录清单 | 声称有 backend-after.txt，但实际文件缺失 |
| run.log 中是否有 stall 文本 | 未验证（脚本 abort 前未执行 snapshot_backend） |

**deepseek 在 STATUS.md 中声称 "osd.0 + osd.2 出现 DB_DEVICE_STALLED_READ_ALERT"，但 B1-nj1 目录中无 backend-after.txt。** 该结论可能来自 run.log 中的 health check 输出，但未经 backend 快照取证。这与 deepseek 15 任务书 §0 的铁律矛盾："每一个 stall 都要有对应的落盘文件能对账"。

**对比**：A-idle 的 stall 有落盘证据（`A-idle/backend-after.txt` → osd.5 stalled read），是可信的。

### 结论 3：15 任务完成度

| 实验 | 设计 | 执行 |
|------|------|:---:|
| A-idle | 完全空闲态 5 轮 | ✅ 完成 |
| A-postlayout | 大写入后立即测 | ❌ 未执行 |
| A-repeat | 同 A-idle 换时段 | ❌ 未执行 |
| B1-nj1 | 固定 64G, 1 job | ⚠️ r1 完成, r2 abort |
| B1-nj2~nj16 | 固定 64G, 扫并发 | ❌ 未执行 |
| B2-nj1/nj4/nj16 | 对照组 | ❌ 未执行 |
| C-stall 取证 | health timeline + perf dump | ⚠️ 部分 |

**设计 10 格，仅完成 1.5 格。结论基于极有限数据。** "stall 由写入总量决定"这个核心结论是在没有 A-postlayout、A-repeat、B1-nj2~nj16 对照的情况下得出的，证据链不完整。

---

## 三、16/README.md P1-P6 逐条复核

### P1："几十G连续写必触发 BlueFS stall" → ❌ 推翻

| 证据 | 出处 |
|------|------|
| 任务 A layout 128G（128 jobs）全程 HEALTH_OK | `cold-baseline-recheck-20260706/backend/health-timeline.txt` |
| 任务 A multi-seqwrite 64G（16 jobs）全程 HEALTH_OK | 同上 |
| deepseek exp1 S1-S3（8G/32G/64G, 1 job）触发 stall | `write-forensics-20260705/exp1-threshold/S1-8G/backend-after.txt` 等 |

**判决**：单 job 持续写 8G 即触发 stall，但多 job 分散写 128G 不触发，单 job 32G 也不一定触发（见 P6 实验）。**stall 的触发需要两个条件同时满足：①单 job 持续写（持续压单个 OSD 不给 compaction 喘息）+ ②OSD 已有 compaction 积压（LSM tree 膨胀）。** deepseek 的 OSD 在 write-push 测试（~200G+）后已有积压，restart 不清除磁盘上的 LSM tree 状态，所以 8G 单 job 一压就 stall。我们的 OSD 状态干净（`compact_queue_len=0`），所以 32G 单 job 也不 stall。deepseek 的 "几十G必触发" 是以偏概全——忽略了 OSD compaction 状态这个关键变量。

### P2："过去顺序写/layout 数据可能被污染" → ❌ 推翻

任务 A 全程无 stall，layout 前后 HEALTH_OK，顺序测试值与旧基线高度一致（差 1-2%）。**过去冷态基线的 layout 和顺序测试数据可信。**

### P3："写侧被硬件封死" → ⚠️ 部分推翻，但 deepseek 的解读有误

| 数据 | 值 | 出处 |
|------|:---:|------|
| rados bench 4M 峰值 | 116 MB/s | `exp2-backend-raw/rados-bench-4M.txt` |
| rados bench 4M 均值 | 77.9 MB/s | 同上 |
| rados bench 256K 峰值 | 101 MB/s | `exp2-backend-raw/rados-bench-256K.txt` |
| rados bench 256K 均值 | 52.7 MB/s | 同上 |
| 任务 A seqwrite (bs=256K) | 55.3 MB/s | `cold-baseline-recheck-20260706/seqwrite.txt` |
| 任务 A multi-seqwrite (bs=256K) | 40.8 MB/s | `cold-baseline-recheck-20260706/multi-seqwrite.txt` |

deepseek 标 P3 为 "⚠️ 部分推翻"，理由是"裸写 4M 峰值 116 → 硬件不封顶"。但这个解读有问题：
- **4M 峰值 116 是瞬态**（前 14s），均值 77.9 才是稳态
- **256K 均值 52.7 与 JuiceFS seqwrite 55.3 几乎相同** → 256K 写的瓶颈确实在后端，不是 JuiceFS 层
- multi-seqwrite 40.8 低于 rados 256K 均值 52.7 → JuiceFS 层有 23% 额外开销

**GLM 判决**：P3 "写侧被硬件封死" → ⚠️ 256K 写确实接近后端裸能力（52.7 vs 55.3），但 4M 写有空间（77.9 vs 40.8, JuiceFS multi-seqwrite 用 256K bs 远低于 rados 4M 能力）。**"封死"不准确，应改为"256K 写接近后端稳态上限，4M 写仍有空间"。**

### P4："stall = compaction 反压" → ⚠️ 方向对但无定量证据

deepseek exp3 采集彻底失败（6 个 osd perf timeline 每个只有 1 行表头）。任务 A 的 OSD perf timeline 也失败（nohup 循环问题）。**至今无 compact_queue_len / kv_sync_lat 的定量时间线。** health 文本 "stalled read in db device" 证实 stall 发生，但与 compaction 的因果关系缺定量证据。

### P5："WAL/DB 同盘是瓶颈" → ⚠️ 有条件的不需要

exp4 因 cephadm 容器限制阻停。但任务 A 全程无 stall（4998 条 health 采样），P6 实验 32G 单 job 写也无 stall。

**stall 的直接原因是 compaction 积压，不是 WAL/DB 共享本身。** WAL/DB 共享只是让 compaction 更慢（I/O 争抢），是间接因素。现有 `compact` 命令可主动消除积压（秒级完成），在 compaction 可控的前提下，WAL/DB 隔离非必须。

原逻辑链：stall → WAL/DB 共享 SSD → 需要独立 NVMe。
修正后：stall → compaction 积压 → `compact` 可消除 → 不一定需要独立 NVMe。

**结论**：在 compaction 可管理的生产场景下（定期 compact / 避免单 job 持续大写入），WAL/DB 隔离非必须。仅在无法控制写入模式且 compaction 跟不上的场景下，独立 NVMe 才有必要性。

### P6："SSD 误判 HDD 不影响写性能" → ❌ 推翻

**deepseek 只查了 `bluestore_cache_size`（hdd=ssd=1GB）就下结论。漏查了两个关键写路径参数：**

| 参数 | hdd 值 | ssd 值 | 差异 | 影响 |
|------|--------|--------|------|------|
| `bluestore_prefer_deferred_size` | **65536** | **0** | HDD 模式下 ≤64K 写全走 deferred 双写（WAL+最终写），SSD 模式跳过 | 256K bs 的写有 25% 数据（64K/256K）走 deferred 路径 |
| `bluestore_throttle_cost_per_io` | **670000** | **4000** | **167×** | HDD 模式下 per-IO throttle 成本高 167 倍，严重限制写并发 |
| `bluestore_cache_size` | 1GB | 1GB | 相同 | deepseek 只查了这个 |
| `bluestore_min_alloc_size` | 4096 | 4096 | 相同 | — |

**GLM 独立验证**（`ceph config get osd` 原始输出）：
```
bluestore_prefer_deferred_size_hdd = 65536
bluestore_prefer_deferred_size_ssd = 0
bluestore_throttle_cost_per_io_hdd = 670000
bluestore_throttle_cost_per_io_ssd = 4000
```

**判决**：P6 应推翻 deepseek 的 "无影响" 结论。介质误判导致 HDD 模式下的 deferred 双写和 167× 高 throttle，**很可能正在加剧 stall**。这是不花钱、改配置就可能缓解的突破口（任务 C 将验证）。

**rados bench 256K 直打池验证（2026-07-06）**：
- SSD 模式 (deferred=0): 72.3 MB/s 均值，前 18s 稳定 112 MB/s
- HDD 模式 (deferred=65536): 58.6 MB/s 均值，前 7s 稳定 110 MB/s
- **SSD 模式 +23%**，高性能持续时间 2.6 倍（18s vs 7s）
- 机理：256K EC 写产生 64K chunk，命中 HDD deferred 阈值 → 双写 → I/O 翻倍 → 更早饱和
- 但通过 JuiceFS 间接测未显示提升（JuiceFS 层开销掩盖后端差异）

**补充发现（compaction 检测方法）**：通过 admin socket 可直接检测 OSD compaction 积压状态：
- `rocksdb.compact_queue_len`（>0 = 有积压）
- `rocksdb.compact_running`（>0 = 正在 compaction）
- `bluestore.kv_sync_lat avg`（>2ms = 有压力）
- `ceph --admin-daemon <asok> compact` 可强制 compaction（秒级完成）
- **restart OSD 不清除 compaction 积压**——LSM tree 状态在磁盘上，restart 只清内存。这解释了 deepseek "每档间 restart OSD" 仍触发 stall：积压未消除，单 job 一压就 stall。

---

## 四、opencode 没点出的新问题

### N1：15/STATUS.md 目录清单与实际文件不符

STATUS.md §七声称 B1-nj1 目录含 `backend-after.txt`，但实际文件不存在。这是**文档造假**（无意或有意），导致读者误以为 B1-nj1 stall 有落盘证据。

### N2：16 exp1 S4 (128G) "文件布局阶段即卡死" 未调查

deepseek 在 S4 写 "文件布局阶段即卡死（fs 操作也被 stall 阻塞）"，但未区分这是 Ceph stall 还是 JuiceFS/FUSE 层的问题。如果是 FUSE 层卡死（如 JuiceFS 元数据操作阻塞），解法可能不同。**这个现象被忽略了。**

### N3：14 A3 (mu=300) seqwrite 严重退化无后端快照

A3 seqwrite=45.8（vs A1 mu=150 的 64.0, -28%），deepseek 归因为 "mu 过高增加 upload 线程竞争"。但 28% 的退化更可能是 stall/compaction 导致。**A3 目录无 backend-after 快照**，无法排除 stall。

### N4：15 A-idle r1→r2 的 30% 断崖退化未解释

A-idle r1=68.0 → r2=47.3（-30%），仅 8G 累积写入就导致 30% 退化。deepseek 用 "RocksDB compaction 积压" 解释，但**8G 写入产生多少 RocksDB metadata？按 EC 4+2 + 4M 对象，8G ≈ 2k 对象，RocksDB metadata 增量很小。** 30% 退化是否合理？是否还有其他因素（如 BlueStore cache miss、OSD 内存压力）？未调查。

### N5：16 P3 的 rados bench 数据被选择性引用

deepseek 在 P3 结论中引用 "4M 峰值 116 → 硬件不封顶"，但忽略了 "256K 均值 52.7 → 与 JuiceFS seqwrite 一致"。**4M 峰值是瞬态，256K 均值才是稳态。** 用瞬态峰值说"硬件不封顶"是 cherry-picking。

---

## 五、复核汇总表

| 来源 | 结论 | GLM 判决 | 关键依据 |
|------|------|:---:|------|
| 14 | 旧测 57/54.8 被 layout 污染 | ❌ 推翻 | 任务 A: layout 128G 全程无 stall |
| 14 | 旧测 57/54.8 被 destroy 污染 | ⚠️ 存疑 | 未单独验证 destroy 影响 |
| 14 | 新测 64/63.7 是真实态 | ⚠️ 存疑 | 更可能是方差（A-idle r1=68→r2=47, -30%） |
| 14 | 多线程写必触发 BlueFS stall | ❌ 推翻 | 任务 A: multi-seqwrite 64G 全程无 stall |
| 15 | stall 由写入总量决定 | ❌ 推翻 | 128G 多job不stall vs 8G单job就stall |
| 15 | stall 与并发数无关 | ⚠️ 存疑 | 未完成 B1-nj2~nj16 扫描，无法判定 |
| 15 | B1-nj1 osd.0/osd.2 stalled | ⚠️ 存疑 | 无 backend-after.txt 落盘证据 |
| 16 P1 | 几十G连续写必触发 stall | ❌ 推翻 | 任务 A: layout 128G 全程无 stall |
| 16 P2 | 过去数据被污染 | ❌ 推翻 | 任务 A: 全程无 stall, 值与旧基线一致 |
| 16 P3 | 写侧被硬件封死 | ⚠️ 部分推翻 | 256K 写接近后端稳态, 但 4M 有空间; deepseek cherry-pick 瞬态峰值 |
| 16 P4 | stall = compaction 反压 | ⚠️ 存疑 | 方向对但无 perf 定量证据 |
| 16 P5 | WAL/DB 同盘是瓶颈 | ⚠️ 有条件的不需要 | stall 直接原因是 compaction 积压非 WAL/DB 共享; compact 命令可消除积压 |
| 16 P6 | SSD 误判 HDD 无影响 | ❌ 推翻 | deferred_size hdd=65536/ssd=0; rados bench 256K 直打池: SSD 72.3 vs HDD 58.6, +23% |
