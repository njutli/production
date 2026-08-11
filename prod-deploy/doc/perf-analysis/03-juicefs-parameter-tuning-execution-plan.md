# 03 · JuiceFS 参数调优执行计划

> 建立：2026-08-06　｜　**本版重构：2026-08-11**（并入 03-4 全部实测结论；剥离任务级叙事；作废内容归拢至附录 A）
> 上一版（641 行，含 03-1/03-2 复核过程叙事）见 git `eab18a3`，不再维护。
>
> 上阶段计划：`doc/perf-analysis/02-backend-raw-cap-and-juicefs-tuning-plan.md`（§十一 交接章）
> 基线交付：`report/基线测试报告-JuiceFS-E6-20260806.md`
> 方法沉淀：`skills/{FULLBASELINE,TUNING,SYSTEM-SAFETY}-SKILL.md`
> 原始数据：`results/stability-raw/`（含 `MANIFEST.md`）

---

## 〇、文档角色与编号约定

| 文档 | 职责 | 更新时机 |
|---|---|---|
| **本计划书** | **全部调优计划的唯一归属地**：分线、旋钮盘点、判据体系、排期、红线、待拍板 | 结论变化时原地更新 |
| **任务书** `doc/perf-tasks/03-N-*.md` | **一个**调优项或**一个**具体任务的执行描述（前置、步骤、回报格式、红线） | 开工前写，执行中不改 |
| **报告** `doc/perf-report/03-N-*-<date>.md` | 该任务的结果与结论 | 任务结束后写 |
| **周报** `report/周报-*.md` | 一周工作总结（对外） | **仅周末编写/修改** |

**两套编号，不要混**：

- **`T1.x / T2.x / T3 / T4`** = 调优实验编号，定义在本计划书（§六-§九）。这是"要做什么"。
- **`03-N`** = 任务书序号，一本任务书承载一个 `T` 编号或一个具体任务。这是"哪一次去做"。

对应关系见 §十一.1 台账。已发生的巧合：`03-1`~`03-4` 四本任务书承载的都是**前置测量**而非调优本身，这不代表 03 阶段是准备阶段——调优本体就是 §六-§九。

---

## 一、分线依据：按"切换代价"而非"改什么"

02 计划的 A/B/C/D 是按**改什么**分类（后端 / JuiceFS / OS / 方法论）。02-2 稳定性攻坚证明，真正决定能不能测的是**切换这个旋钮要付出多少噪声代价**：

| 切换方式 | 噪声代价 | 可用分辨力 | 结论 |
|---|---|---|---|
| `ceph config set`（在线，不 remount 不重启） | 仅剩轮间噪声 | **1.5-7.6%（逐项）** | ✅ 本阶段主力 = **T1** |
| 需 remount（JuiceFS 挂载参数） | 重抽档位，跨实例极差 **29.9%** | 需多实例分布比较 | ⚠ 成本 ×4 = **T2** |
| 需重启 OSD | CV 0.27%→**4.5%**，组合 9.5-13.0% | 效应 3-7% 被吞 | ⛔ 不做（§十） |
| 需重铺 layout / format / EC profile | 换 epoch，绝对值不可比；曾致 PG 落点 100% 改变、漂移 16-37% | σ_layout 未知 | ⛔ 先测 σ_layout = **T4** |

02 计划条目全部映射进来，不丢项 —— 见 §十二。

---

## 二、公理层事实（本阶段不再重验）

### 2.1 结构事实

| # | 事实 | 出处 |
|---|---|---|
| F1 | **性能档位属于 JuiceFS 挂载实例**：同实例轮间 ≤1.1%，跨实例极差 **29.9%**（1334-1891）。remount 不是波动源，是**抽签动作** | `02-2h-e6-v4-…md` §13.5 |
| F2 | 档位机制**未定**（RSS/IRQ 饥饿假设被 r=+0.01 否证），已主动放弃归因，改走探针验签 | 同上 §十四 |
| F3 | 档位**多档非二元**：≈1870 / 1790 / 1750 / 1714 / 1334，历史另有 1698 / 1834 | 同上 §13.5 |
| F4 | 高档带 `[1830,1930]` 内极紧凑：档内 2.2%，03-1 六实例 **1.3%** | §13.x / 03-1 |
| F5 | **读写解耦**：randread 跨 1222 GiB 写入极差仅 2.0%，与轮前对象数、累计写入量均不相关 | R4/R5 |
| F6 | **写侧受对象数支配**：r(randrw, 轮前 objects) = **−0.807**；安全上限 ≤3.11M；拐点 ∈ (3.78M, 4.40M]；`compact_秒 ≈ 1.95e-4 × 回收对象数` | R5 |
| F7 | **重启 OSD 本身是大波动源**：不重启 0.27% / 只重灌数据 3.9% / 只重启 OSD **4.5%** / 组合 ~10% | `02-2h-lc-locate-…md:78-81` |
| F8 | 重启 OSD 不改 CRUSH 映射，但超 `mon_osd_down_out_interval`（600s）会被标 out → 真重映射 + backfill | 本阶段核查 |
| F9 | **首轮效应 + 首运行效应**真实存在（首轮跑在干净池上系统性偏高）；"randwrite 单调下行"已被推翻 | W2 |
| F10 | **randrw 双口径**：`FULLBASELINE_V4.sh` 输出读侧（1215），`r5chk.py` 输出读写合计（2430）。同一性能，报数必须标口径 | W2 |
| F11 | **ITEMS 子集的绝对值 ≠ 全量运行的绝对值** ⇒ 每个战役自带同 `ITEMS` 基线臂，**禁止与全量签收值 1215/2860 直接比** | 本阶段核查 |
| F12 | 六类"降噪"手段全部无效或有害（缩缓存 / 内存盘 / 单进程 / 拉长 runtime 等）；单进程"稳但瞎"：CV 0.6% 但把 1.72× 真实差异测成 1.02× | 周报 §三 |
| **F22** | **JuiceFS 当前挂载无本地盘缓存**：`--max-uploads 150 --cache-size 0`（`/proc/1631722/cmdline` 实查）⇒ 观测到的 hit_rate 46-50% 不来自本地盘，磁盘紧张不影响性能数据有效性 | 03-4 复核 |
| **F28** | **旋钮的"runtime flag"≠"改了就生效"，必须查代码路径**（2026-08-11 桌面核查，见 §5.5）：`handle_conf_change` 跟踪列表 + 逐 op 直读 `cct->_conf` 才是真生效；**`rocksdb_cache_size` 带 `runtime` flag 但 block cache 只在 `_open_db` 建一次 ⇒ 改了不重启无效** ⇒ K2 作废 | `BlueStore.cc:5905/8262`、`RocksDBStore.cc:554` |
| **F30** | **`rocksdb_cache_size` 在 mon 里是比例阀且真生效**：`cache_kv_ratio = rocksdb_cache_size / mon_memory_target`（`OSDMonitor.cc:1061`），余量对半分给两个 OSDMap 缓存；我们集群 512 MiB / 2 GiB = **0.25**，`inc`/`full` 各 768 MiB。**但 mon 不在 JuiceFS 数据路径上**（数据走 librados→OSD，mon 只在 map 变化时被查；quorum age 13d、堆用量 363 MiB ≪ 2 GiB）⇒ 对七项基准效应**结构性为 0**。详见 §5.6 | §5.6 |
| **F29** | **OSD 侧 KV(RocksDB) 缓存实际是 ~9 GiB，不是 512 MiB**：`bluestore_cache_size=30 GiB`（显式设置，非 0 ⇒ 覆盖 `_ssd` 的 3 GiB）× `bluestore_cache_kv_ratio=0.30`。运行态旁证：`bluestore_cache_meta` 0.60 GiB + `cache_onode` 0.62 GiB = **1.22 GiB**，落在 30 GiB×`meta_ratio` 0.05 = 1.5 GiB 预算内；若走 3 GiB 默认则预算仅 0.15 GiB（不可能） ⇒ **01-5「512 MiB KV cache 太小」的前提读的是死配置** | 桌面核查 + `ceph tell osd.0 perf dump` |

### 2.2 噪声与漂移事实（判据分母的来源）

| # | 事实 | 出处 |
|---|---|---|
| **F13** | **读侧同实例漂移底噪（n=10，锁 pid，夜间 11h46m）三项性质不同**：`randread` **1.30%** 无 lag 依赖 = 纯噪声；`seqread` **3.89%** 无 lag 依赖 = 大噪声；`mseqread` lag1 **0.50%** 但随 lag 单调增长到 **1.69%(lag8)**，Spearman(运行序,值)=**+0.939** ⇒ 系统性单调上行漂移 | `03-2-…md` §四/§五 |
| **F15** | **写侧同实例漂移底噪已测定（n=10 run，38h17min，同一 pid=1631722）**：见 §三.2 完整表。关键结论 —— `randwrite` lag1 **2.13%** 最干净；`randrw` **2.78%**；`mseqwrite` **3.78%**；**`seqwrite` lag1 7.25% / 38h 极差 11.79% ⇒ 移出判据集** | 03-4；`bw-raw.tsv` 601 行经 opencode 独立重算 |
| **F16** | **38h 尺度存在与旋钮无关的单调退化**：`seqwrite` ρ(run序)=**−0.758**、1529→1370 = **−10.4%**；`randwrite` ρ=−0.624；`randread` ρ=−0.467；`mseqwrite` 无趋势(+0.152)。**回归掉 randread 后 seqwrite 残差极差反而升到 12.89%**（降幅 −9.3%）⇒ 非外部负载共因，是独立机制。周六/周日均值差：seqwrite **+5.88%** | 03-4 |
| **F17** | **A/B 紧邻交错可抵消 ~87% 的时间漂移**：03-3 日间 4.5h 漂移 1.72%（Spearman −0.771），交错后残差 0.233%。生效三判据：6 个 median `B A B A B A` 完全交织、Mann-Whitney U=7/9 不显著、两项符号相反 | 03-3 |
| **F18** | **randread 是协变量，不是看门狗**：日间 4.5h 跌 1.72%，最低点 1830.7 距高档带下界 1830 仅 **0.04%** 余量 ⇒ `±2%` / 区间式在线看门狗在数十小时尺度必然误报。实例同一性须用 **pid + starttime_ticks** 硬判据 | 03-3 |

> ⚑ **F16 的处置 = 声明超出作业尺度，不研究**。调优战役单次 ≤14h 且强制交错（F17），不进入 38h 区域。理由：追机理需要多实例 × 多昼夜对照，成本远超收益，而交错已把它压掉 87%。**纪律**：任何单战役跨度 >14h 必须拆批，且不得跨周末边界比较绝对值。

### 2.3 对象数与池行为事实（写侧战役的物理约束）

| # | 事实 | 出处 |
|---|---|---|
| **F19** | **池内对象大小恒为 256 KiB（精确，非平均）**：`objects × 262144 ≡ stored`，在 `pool-trace.tsv` **20,054/20,054 行**逐行成立 ⇒ 对象口径与字节口径是**同一个测量**，不存在"哪个更可信" | 03-4 |
| **F20** | **换算系数是分项的，没有全局常数**：顺序写（seqwrite/mseqwrite）**f=1.000**，即每 256 KiB 恰好 1 个新对象、零覆写（`io=268GiB` vs 对象 +1,098,336，比值 1.000）；随机覆写（randrw/randwrite）**f=0.876**，即 292 KiB/新对象。把 292 套到顺序写上**低估 25%** | 03-4 / R5 |
| **F21** | **单轮生成量实测**（`io=` ÷ 256 KiB，10 run 均值）：`randrw` 214.8 GiB→**0.88M**；`seqwrite` 252.8 GiB→**1.04M**；`randwrite` 518.9 GiB→**2.13M**（gross）；`mseqwrite` **846.9 GiB→3.47M**。mseqwrite 是唯一的量级异类 | 03-4 |
| **F23** | 🔴 **`obj_gate()` 是轮边界闸门，不是运行时看门狗** ⇒ `OBJ_MAX=10M` 红线**实测被击穿且全程无人察觉**：池峰值 **10,691,356**（106.9% 红线，2.55 TiB）@ 08-09 17:54:59，窗口内 38 个采样点 >10M、累计 9.5min。峰值成因：mseqwrite r4 结束 7.0M + 单轮 gross 3.47M ≈ 10.5M，全在轮内 | 03-4 |
| **F24** | 峰值 10.69M / 2.55 TiB 下集群仍 **HEALTH_OK**，`max_avail` 最低 23.99 TiB（与 03-1 的 17.03M / 15.30% 安全一致）⇒ 击穿是**机制失效**，不是安全事件 | 03-4 |
| **F25** | 🔴 **不存在时间驱动的后台回收**：池在 3,453,658 上静置 **8 小时零变化**（23:10→07:14，2568 行采样全同，HEALTH_OK）⇒ **唯一有效回收手段是显式 `juicefs gc --compact`**，"等待自愈"不可依赖。**F14 因此降级**，见附录 A | 03-4 |
| **F26** | **`gc --compact` 第二遍完全无效**：同一轮 p1/p2 的 `scanned` 与 `pending_delete_bytes` **逐字节相同**（如 4,440,410 / 36,104,568,832 两遍一致）⇒ `OBJ_GC_PASSES=2` 是纯浪费，应改 1 | 03-4 §5 |
| **F27** | `gc --compact` 清不掉约 9.2% 的顺序写残留（101,120 对象 = 24.7 GiB），机制为结构性待删切片（探针 C：第二遍 `deleted 0 pending slices`）；randrw 五轮地板恒为基线+1，无欠账 ⇒ **每轮起点对齐度是分项的** | 03-4 A2 |

---

## 三、判据体系（唯一判定口径）

### 3.1 判定式

```
效应成立 ⟺ |median(B臂) − median(A臂)| ≥ 门槛
门槛 = max( 该项可检出效应量 , 2 × 该项同实例漂移底噪(lag1) )
```

- **lag1 口径是唯一可用口径**，因为 A/B 紧邻交错下相邻单元恒为异臂。若允许任意间隔，门槛按全对 max 计算，读侧三项全部失效（F13）。
- 落在门槛内 ⇒ 结论**"无收益"**，不得写成"略有提升"。
- 判据触发后须**再交错一对复核**。

### 3.2 判据表（⚑ 2026-08-11 补齐写侧四项）

| 项 | 可检出效应量 | 同实例底噪 lag1 | **门槛** | 38h 极差（参考） | 裁定 |
|---|---|---|---|---|---|
| `mseqread` | ≥1.5% | 0.50% | **1.50%** | 1.69%(lag8) | ✅ 判据（最灵敏） |
| `randread` | ≥3.0% | 1.40% | **3.00%** | 2.22% | ✅ 判据 + **档位协变量** |
| `randwrite` | ≥4.0% | 2.13% | **4.26%** | 5.00% | ✅ **写侧首选判据** |
| `randrw`（读侧） | ≥3.0% | 2.78% | **5.56%** | 2.78% | ✅ 判据 |
| `mseqwrite` | ≥7.0% | 3.78% | **7.56%** | 4.24% | ⚠ 勉强可用，只判大效应 |
| `seqwrite` | ≥5.0% | **7.25%** | 14.50% | **11.79%** | ⛔ **移出判据集**（F15/F16） |
| `seqread` | ≥4.0% | **3.89%** | 7.78% | — | ⛔ **移出判据集**（F13） |

> 数据来源：读侧 `03-2-…md` §四；写侧 `/tmp/opencode-03-4-bw-raw.tsv`（601 行）+ `rounds.tsv`，由 opencode 从 fio 汇总行独立重算。
> ⛔ 两个移出项的 `ITEMS` 位置可保留用于旁证与异常检测，**不得用于宣告收益或无收益**。

### 3.3 三条硬纪律

1. **紧邻交错强制**：一律 `A B A B A B`，**禁分臂串行**（会使判据全线失效并可能伪造"有效"结论），`A-B-A` 降为退化下限，**禁 A-B 两点比较**，两臂必须同时段。
2. **每臂 ≥3 run 取 median**：门槛余量最薄处只有 0.4-0.5 pp，单对比较的不确定性吃掉全部余量。
3. **报数纪律**：写侧剔首轮（F9）；randrw 标读侧/合计（F10）；`ITEMS` 各臂完全相同且不与全量签收值比（F11）；报告须给**两版底噪** —— 原始极差（**门槛取这版**）+ 回归掉 randread 的残差极差（参考）。

### 3.4 签收基线现状

| 项 | 签收值 (MiB/s) | 状态 | 03-4 同实例实测 median（5 项 ITEMS 口径） |
|---|---|---|---|
| mseqread | 4160 | ✅ 正式 | — |
| randread | 1880 | ✅ 正式 | 1846.0 |
| randrw | 1215 读侧 | ✅ 正式 | 1222.5 |
| randwrite | ≈2860 | ⚑ 暂签 | 2940.5 |
| seqwrite | 1400 | ⚠ 条件 | 1433.0 |
| mseqwrite | 4800 | ⚠ 条件 | 4854.0 |
| seqread | 1290 | ⚠ 条件 | — |

> ⚠ 右列是 `ITEMS = randread randrw seqwrite mseqwrite randwrite`（5 项）口径，按 F11 **不可与左列直接比**，仅供同口径内部参照。
> `randwrite` 转正：需干净池数据点，由 T1 基线臂自然产出（**不能用 03-4 的数据**，其 r1-r3 受 mseqwrite 残留污染）。
> `seqread` 转正：需 ≥3 实例含日间窗口。

---

## 四、目标与验收

**主目标**：在不重启 OSD、不重铺 layout 的约束下，把七项性能相对签收基线提升，且每项收益都通过 §三 判据。

**次目标**：`randwrite` 转正；把 T1/T2 协议固化进 `TUNING-SKILL.md` 使后续旋钮可直接套用。

| 级别 | 标准 |
|---|---|
| **单旋钮判定** | 满足 §3.1 判定式 |
| **阶段成功** | 至少一项正式签收项（mseqread / randread / randrw）取得可判收益；或给出"在线旋钮空间已穷尽"的清单式结论 |
| **阶段失败但可交付** | 全部旋钮无可判收益 ⇒ 结论"EC 4+2 + FUSE 在在线可调空间内已到位"，剩余空间归因到需重启 / 需重铺 / 需换架构三类，交 04 阶段 |

**不设 ≥6250 MiB/s 达标线**：01 阶段已证 FUSE 单进程封顶为架构固有，6250 属 04 阶段（io_uring / kernel mount）范畴。

---

## 五、旋钮盘点

### 5.1 判定方法（可复现）

1. 源码判 runtime 可改：`src/common/options/{global,osd}.yaml.in` 是否带 `runtime` flag（`/home/lilingfeng/project/ceph`，⚠ 本地是 main，集群是 v17 quincy）；
2. 实查现值：`ceph config get osd.N <key>` / `ceph config dump`；
3. **落地验证（必做）**：`ceph config set` 后用 `ceph tell osd.N config get <key>` 确认运行态已变，而非只写进 mon config store。

### 5.2 T1 候选：OSD 侧在线可切（全部已核 `runtime=true`）

| # | 旋钮 | 现值 → 试值 | 机制假设 | 目标项 | 预期 | 门槛 | 可判 |
|---|---|---|---|---|---|---|---|
| K1 | `bluestore_default_buffered_read` | `true` → `false` | 旁路 OSD 侧 page-cache 双缓冲，省一次拷贝 | randread / mseqread | 2-5% | 3.0 / 1.5% | ✅ |
| ~~K2~~ | ~~`rocksdb_cache_size` 512 MiB → 2-4 GiB~~ | ❌ **已作废（2026-08-11 桌面核查）**，见 §5.5 与 F28/F29 | — | — | — | ⛔ parked → 04 |
| K3 | `bluestore_throttle_bytes` / `_deferred_bytes` | 64/128 MiB → 256/512 MiB | 写路径 in-flight 限流；02-1 已确认 buffer 压力 sleep 是写劣化根因 | randwrite / randrw | 3-10% | 4.26 / 5.56% | ✅ |
| K4 | `bluestore_prefer_deferred_size_ssd` + `_deferred_batch_ops_ssd` | 0/16 → 65536/64 | EC 4+2 下 256K 写切成 64K/shard，恰等于 `max_blob_size_ssd`；走 deferred(WAL) 批量合并可减少小 IO 落盘 | randwrite | 5-15% | 4.26% | ✅ |
| K5 | `bluestore_max_blob_size_ssd` | 64 KiB → 256 KiB | 加大 blob 降元数据条目数 ⇒ **可能同时缓解 F6 的对象数膨胀**（双重收益） | 写侧 + 拐点位置 | 3-10% | 4.26% | ✅ |
| K6 | `bluestore_csum_type` | `crc32c` → `none` | 削 OSD CPU；读路径也做校验，读写都可能受益 | 全部 | 2-6% | — | ⚠ 需拍板（数据完整性） |
| K7 | `osd_mclock_max_capacity_iops_ssd`（归一化 osd.3） | osd.3 缺失→默认 21500；同伴 63911-79983 | §5.4 异常一 | 全部 | 未知 | — | ✅ 先诊断 |
| K8 | `osd_mclock_profile` | `balanced` → `high_client_ops` | **阴性对照**：源码 `mclock_common.h` 两 profile 的 client `limit` 均为 0(=max)，空闲集群预期 ≈0 | 读侧 | ~0 | — | ✅ **已做，见 §十一.1** |

> K3/K4/K5 的目标项已按 §3.2 改写：原表写 `seqwrite / mseqwrite`，现**首选 randwrite（门槛 4.26%）+ randrw（5.56%）**，seqwrite 移出。

### 5.5 ⚑ 运行时生效性桌面核查（2026-08-11 新增，开工前置）

**为什么必须做**：`ceph config set` 成功 ≠ 旋钮生效。`ceph config get` 只证明写进了 mon config store；`ceph tell osd.N config get` 只证明 OSD 进程的配置视图变了；**都不证明数据路径真的换了行为**。真生效只有两条路径：

- **A 路**：出现在 `BlueStore::get_tracked_conf_keys` / `handle_conf_change`（`BlueStore.cc:5905`）⇒ 变更时有回调重算内部状态；
- **B 路**：数据路径内每 op 直读 `cct->_conf->xxx` ⇒ 天然实时。

**核查结果**

| 旋钮 | 真生效？ | 路径 | 证据 |
|---|---|---|---|
| **K1** `bluestore_default_buffered_read` | ✅ | **B 路** | 读路径内直读 `cct->_conf`（`BlueStore.cc:13129` / `:13547`），每 op 生效 |
| ~~**K2**~~ `rocksdb_cache_size` | ❌ **无效** | 两路都不在 | ① `BlueStore::_open_db` 调 `db->set_cache_size(cache_kv_ratio × cache_size)`（`BlueStore.cc:8262`）置 `set_cache_flag=true`；② `RocksDBStore.cc:554` 的 `if (!set_cache_flag) { cache_size = conf->rocksdb_cache_size; }` **分支永不进入** ⇒ 512 MiB 从未被读取；③ 不在 `handle_conf_change` 列表；④ **即使读了也没用** —— block cache 在 `do_open` 里 `create_block_cache()` 建一次，改配置不会 resize ⇒ **必须重启 OSD ⇒ 撞 F7** |
| **K3** `bluestore_throttle_bytes` / `_deferred_bytes` | ✅ | **A 路** | 两者均在 `handle_conf_change` |
| **K4** `bluestore_prefer_deferred_size_ssd` / `_deferred_batch_ops_ssd` | ✅ | **A 路** | 均在 `handle_conf_change` |
| **K5** `bluestore_max_blob_size_ssd` | ✅ | **A 路** | 在 `handle_conf_change` |
| **K6** `bluestore_csum_type` | ✅ | **A 路** | 在 `handle_conf_change` |
| **K7 / K8** mclock | ✅ | 独立子系统 | K8 已在 03-3 实证可生效（判为无收益是判据结论，不是失效） |

> ⚠ **版本风险**：本地 checkout 是 **main 分支且为浅克隆**（`git log -S` 无法回溯），集群是 **v17 quincy**。但 K2 的裁定**与版本无关** —— 第 ④ 条（block cache 在 open 时建一次、改配置不 resize ⇒ 需重启 OSD ⇒ 撞 F7）在任何版本都成立，因此**不需要 v17 源码复核即可结案**。
>
> 🔴 **纪律（写入 `TUNING-SKILL.md`）**：**任何旋钮进入排期前，必须先做这张表的桌面核查**。K2 的教训 —— 它带着 `runtime` flag、`ceph config set` 会成功、`ceph tell config get` 会显示新值，然后跑 4.5h A/B 得到"无收益"，而这个"无收益"是**假阴性**，会被写进报告当成真结论。桌面核查花 30 分钟，省 4.5h 机器时间 + 一个错结论。

### 5.6 ⚑ `rocksdb_cache_size` 的真实归属（K2 结案调查，2026-08-11）

> 起因：用户指出"这个选项被设计出来必然有用，只是我们的场景不让它生效，需要查清它在什么情况下生效、有没有必要调"。§5.5 只证明了"在我们这里无效"，没回答"它为谁而生"，结论不完整。本节补齐。

**全树只有一处调用 `db->set_cache_size()`**：`BlueStore::_prepare_db_environment`（`BlueStore.cc:8262`，由 `_open_db` 在 `:8278` 调用）。⇒ **凡是不经 BlueStore 的 RocksDBStore 使用者，`set_cache_flag` 都是 false，`rocksdb_cache_size` 就生效**（`RocksDBStore.cc:554`）。

**它的两个真实消费者**

| 消费者 | 怎么用 | 是否 runtime 真生效 |
|---|---|---|
| **① `ceph-mon`（我们集群正在用）** | **它在 mon 里是"比例阀"，不是绝对缓存大小**：`OSDMonitor::_set_cache_ratios()`（`OSDMonitor.cc:1061`）算 `cache_kv_ratio = rocksdb_cache_size / mon_memory_target`，余量再对半分给两个 OSDMap 缓存：`cache_inc_ratio = cache_full_ratio = (1 − cache_kv_ratio) / 2`。三者交给 PriorityCache 管理器 `pcm` 统一伸缩（`pcm->insert("kv"/"inc"/"full")`） | ✅ **是**。`OSDMonitor::handle_conf_change` 跟踪 `"rocksdb_cache_size"`（`:501/:514`）→ 调 `_update_pcm_cache_settings()` |
| **② 离线 / 非 BlueStore 的 KV 使用者** | `ceph-kvstore-tool` 等直接开 RocksDBStore 的路径；**历史上是 FileStore 的 omap DB** —— 这就是这个选项的由来，也解释了为什么它的默认值 512 MiB 是个"OSD 量级"的数 | ✅（离线场景无所谓 runtime） |

**为什么在 BlueStore 里必然失效**：BlueStore 引入统一缓存预算（`bluestore_cache_size × bluestore_cache_kv_ratio`）后接管了 KV 缓存的分配，`_prepare_db_environment` 无条件覆盖。**与 `bluestore_cache_autotune` 无关** —— autotune=true 时初值仍来自这里，之后由 PriorityCache 重新平衡；autotune=false 时就是静态比例。两条路都不读 `rocksdb_cache_size`。

**我们集群的实际数值**（已实查）

```
rocksdb_cache_size     = 536870912   (512 MiB)
mon_memory_target      = 2147483648  (2 GiB)
mon_memory_autotune    = true        ← 默认，比例阀确实在生效
mon_osd_cache_size_min = 134217728   (128 MiB)
⇒ cache_kv_ratio = 512 MiB / 2 GiB = 0.25
⇒ inc / full 两个 OSDMap 缓存各得 (1 − 0.25)/2 = 0.375 → 各 768 MiB
mon 实际堆用量 = 363 MiB（远低于 2 GiB target，比例阀不吃紧）
mon quorum age = 13d（无 map 抖动）
```

**评估：不值得调，且不是"效应低于门槛"，是结构性为零**

| 理由 | 证据 |
|---|---|
| mon **不在 JuiceFS 数据路径上** | 数据路径 = FUSE → JuiceFS → TiKV(元数据) + Ceph OSD(数据，走 librados)。mon 只在 OSDMap epoch 变化时被查询，不参与每个 IO |
| 我们的负载**不产生 map 变化** | `pg_num` 冻结 32、autoscale off、无扩缩容、quorum age 13d |
| 比例阀**不吃紧** | mon 堆用量 363 MiB ≪ `mon_memory_target` 2 GiB ⇒ 三个缓存都没到需要抢内存的地步 |
| OSDMap **本身极小** | 6 OSD / 32 PG 的 map，`inc`/`full` 各 768 MiB 是巨幅过配 |

⇒ **调它 = 改变一个不在数据路径上的守护进程里、三个都不紧张的缓存之间的分配比例。对七项基准的预期效应是结构性 0，不是"测不出"。** ⇒ **parked → 04，且不排测试**。

**复活条件（什么时候它真的重要）**

1. **大规模集群 + OSDMap 高频抖动**（数百至数千 OSD、频繁 up/down）：mon 的 RocksDB 与 OSDMap 缓存会实质影响 mon CPU、`ceph -s` 响应与 map 分发延迟；
2. **mon 内存吃紧**（`mon_memory_target` 成为约束）：这时才需要在 kv 与两个 OSDMap 缓存之间重新分配；
3. **离线大 store 操作**：`ceph-kvstore-tool` 处理超大 mon/osd store 时；
4. FileStore 后端（已废弃/移除）——历史场景。

> 🔴 **顺带记住正确的阀门**：若将来真要调 **OSD 侧** KV 缓存，正确旋钮是 `bluestore_cache_size`（现 30 GiB）与 `bluestore_cache_kv_ratio`（现 0.30），**不是** `rocksdb_cache_size`。但这两个 `level: dev`、**无 runtime flag**，且 block cache 只在 `_open_db` 建一次 ⇒ 必须重启 OSD ⇒ 撞 F7。这是 04 阶段（可接受重启窗口时）的事。

### 5.3 已确认不可在线切（本阶段 parked → 04）

| 旋钮 | 原因 |
|---|---|
| `cephx_sign_messages`（02 计划 A2.1，原 P1 最大项） | 无 runtime flag；只影响新建连接，均匀生效须重启全部 OSD ⇒ 撞 F7。**02 计划排 P1 是在不知 F7 的前提下做的** |
| `ms_crc_data` / `ms_crc_header` | 无 runtime flag |
| `osd_op_num_shards_ssd`(8) / `_threads_per_shard_ssd`(2)（02 计划 A2.3） | 无 runtime flag |
| `ms_async_op_threads` | 无 runtime flag |
| `objecter_inflight_op_bytes` / `_ops` | 无 runtime flag；且实测调大只 +3%（噪声内），已排除 |
| `bluestore_cache_size` / `_cache_kv_ratio` | 无 runtime flag（dev 级，`level: dev`）。已显式设为 30 GiB / 0.30 且 `autotune=false` ⇒ **这两个才是 KV 缓存的真正阀门（实际 ~9 GiB，F29），但都改不了** |
| `osd_memory_target` | runtime=true 但已无空间：§5.4 异常二 |
| ⚑ **`rocksdb_cache_size`（原 K2）** | **带 `runtime` flag 但改了不生效**：block cache 在 `_open_db` 建一次、不 resize ⇒ 需重启 OSD ⇒ 撞 F7。且实际 KV 缓存已是 ~9 GiB（F29），"512 MiB 太小"的前提本身不成立。详见 §5.5 |
| C 线全部（NVMe 队列 / IRQ 亲和 / MTU / TCP） | 需重启服务或撞 157 红线；MTU 9000 还需 IT 确认交换机，且等价全链路重连 ⇒ 撞 F1+F7 |

### 5.4 集群实查发现的两个异常

**异常一：osd.3 的 mClock IOPS 容量缺失，比同伴低 3-3.7×**

```
osd.0 = 78571   osd.1 = 75968   osd.2 = 79983
osd.3 = (config dump 中无此项) → 取默认 21500
osd.4 = 65524   osd.5 = 63911
```

`osd_op_queue = mclock_scheduler`（Quincy 默认），容量值由 OSD 首次启动自测并写回 mon config store，osd.3 显然没写回。诚实的期望：两 profile 的 client `limit` 均为 0（不设上限），空闲集群下 mClock 不硬性截断客户端 op，容量值主要影响 reservation 绝对刻度 ⇒ **预期效应可能很小**。但值得做：EC 4+2 写须集齐 6 shard、读需 4/6，任何 OSD 被结构性压低都会传导到每个 IO，而这是**免费、在线、可回滚**的不对称修正。与长期未量化的 **PG 主分布 9:1 倾斜 + straggler（osd.4 延迟 4-5×）** 同族。⛔ 换 `osd_op_queue=wpq` 需重启 ⇒ parked。

**异常二：`osd_memory_target` 已是 350 GiB/OSD，02 计划 A2.2 作废**

```
host:ceph-node1 = 375831164518 (350 GiB)   node2 = 375831178854   node3 = 377978635264
默认层 = 2147483648（被 host 层覆盖）      osd_memory_target_autotune = true
```

02 计划 A2.2 写"调到 16GB"，实际已是它的 **22 倍**（cephadm autotune 按主机内存分配）。同时 `bluestore_cache_size` 被钉在 30 GiB 且 `autotune=false` —— 两者**语义冲突**。⇒ A2.2 作废，改为 K2：不动总量，只调 KV/RocksDB 那一份的生效路径。

---

## 六、T1：OSD 侧在线旋钮 —— P0

> 本阶段**唯一能拿到 1.5-3% 分辨力**的战役类型，所有能塞进 T1 的都优先塞进来。

### 6.1 协议

```
[前置] 挂载一次 → 探针 randread 75s → 必须落在高档带 [1830,1930]，否则优雅卸载重挂
   ↓ 记录 pid + starttime_ticks（全程比对，禁 forced-mount）
[全程 SKIP_REMOUNT=1，绝不 remount、绝不重启 OSD]
   ↓
紧邻交错（强制）： A B A B A B      ← 不是 AAA BBB
   每个 A/B 单元 = 1 个 run，相邻单元必须异臂，两臂同时段
   ↓
[写侧战役] 每轮起点走 §八 对象数门禁
   ↓
判定：§3.1 判定式
```

**实例同一性与档位处置（F18）**

- 用 **pid + starttime_ticks** 硬判据，**不用带宽值**做看门狗。
- `randread` 每 run 记录，作**外部负载协变量**，不作中止依据。
- 中止线放到远离常态波动处：single-run median **<1700**（落在 F3 多档 1714 与 1334 之间的空隙），且须**连续 2 run** 触发。
- 报告给两版底噪（§3.3 第 3 条）。

**配置变更纪律**

- 一次只测**一个**旋钮；测组合前每个必须单独测过。
- 每次 `ceph config set` **必须配对给出恢复命令**，事先 `ceph config dump > snapshot` 存档。
- `ceph health` 连续 3 次（间隔 5min）非 OK ⇒ 立停。

### 6.2 排期与成本

单项实测耗时（5 轮/run，03-4 标定）：`randread` 28min｜`randrw` 39min｜`seqwrite` 40min｜`mseqwrite` 55min｜`randwrite` 65min。**5 项全量 = 227min，与 10 run 实测 median 230min 吻合。**

| 序 | 战役 | 旋钮 | `ITEMS` | 单 run | 6 run 交错 |
|---|---|---|---|---|---|
| ~~T1.0~~ | ~~协议自检~~ | ~~K8~~ | — | — | ✅ **已完成**（§十一.1） |
| ~~T1.1 原~~ | ~~读侧 OSD 缓存~~ | ~~K2~~ | — | — | ❌ **取消**（§5.5：旋钮不生效） |
| **T1.1** | 读侧缓冲旁路 | **K1** | `randread mseqread` | ~44min | **~4.5h** |
| **T1.2** | 容量归一化 | **K7** | `randread randrw` | ~67min | **~7h** |
| **T1.3** | 写侧限流 | K3 | `randread randrw randwrite` | ~132min | **~13h** |
| **T1.4** | 写侧 deferred | K4 | `randread randwrite` | ~93min | **~9.5h** |
| **T1.5** | blob 尺寸 | K5 | `randread randrw randwrite` | ~132min | **~13h** |
| **T1.6** | 校验和 | K6 | 全项 | ~227min | ~23h ⚠ 需拍板，放最后 |

> ⚑ **2026-08-11 重编号**：原 T1.1(K2) 取消，其后各项依次前移。**读侧只剩 T1.1(K1) + T1.2(K7) ≈ 11.5h**（原 16h），写侧 T1.3-T1.5 ≈ 35.5h。
> 🔴 **K2 的取消是 03 阶段第一个"桌面核查省下机器时间"的案例**：它原本是 P1 期望最高项（预期 3-8%），若照排会花 4.5h 得到一个假阴性。

> ⚑ **写侧 `ITEMS` 已剔除 seqwrite / mseqwrite**，依据：① 两项均已移出或勉强可用（§3.2）；② mseqwrite 是 F23 击穿 10M 红线的唯一成因、F27 起点不对齐的唯一来源、且最贵（55min/run）。剔除后单 run 从 227min 降到 132min（**−42%**），峰值对象数从 10.69M 降到 **~4.1M**（41% 余量），unaligned 轮归零。代价：触发 F11，写侧战役自带基线臂即可，不与全量签收值比。**此项待拍板（§十五 第 3 项）。**

---

## 七、T2：JuiceFS 挂载参数（多实例分布比较）—— P1

> `--max-uploads` / `--buffer-size` / `--max-fuse-io` / `--max-readahead` / `--cache-size` **全部需 remount** ⇒ 每次都是重抽档位（F1）。JuiceFS 侧无在线可切等价旋钮（`juicefs config` 只改 format 级，属 T4）。

### 7.1 设计

```
每臂挂载 N=12 次，A/B 交错（禁分臂串行）
每次挂载：randread 探针 75s → 记录档位 → 跑 ITEMS
   ↓
取每臂**探针落在高档带 [1830,1930] 的子集**（命中率 ~61%，n≈7/臂）
   ↓
比较两臂高档子集的 median
```

**为什么成立**：F4 + 03-1 独立复现 —— 高档带内极差仅 **1.3%**（n=6）。"探针判为高档"这个门控把档位污染压到 1.3% 量级，配合 n≈7 取中位数，残余档位噪声 ≈0.5%，足以支撑 3% 级效应判定。

**⚠ 探针能力边界（03-1 已否证的三件事）**：留一法 r=**−0.1291**、传导增益 0.221、SNR 差 22 倍。⇒ ✅ 探针**仅**用于：确认 randread 自身在高档、确认实例同一性、作外部负载协变量。🔴 **探针归一化已作废**；🔴 不能用探针筛"其它项也在高档"；🔴 不要把探针当看门狗。

**⚠ 读侧挂载参数（`--max-readahead` 类）本阶段不做**：探针本身就是 randread，改读侧参数会同时改探针，门控失效；写侧探针分辨力不足（需 11-29%，而要判的中档只差 4.8-8.8%）⇒ 推迟到 04，或等出现"与读路径解耦又能分辨 5% 档差"的第三种探针（目前无候选）。`--max-readahead 0`（ra0）口径已由用户拍板锁定，本阶段不动。

### 7.2 排期

| 序 | 战役 | 参数 | `ITEMS` | 挂载次数 | 机器时间 |
|---|---|---|---|---|---|
| **T2.1** | 上传并发 | `--max-uploads 150 → 300` | `randread randwrite` | 24（交错） | ~8h |
| **T2.2** | 写缓冲 | `--buffer-size 300 → 1024` | `randread randrw randwrite` | 24 | ~10h |
| **T2.3** | FUSE IO 上限复核 | `--max-fuse-io 128K → 256K` | 写侧先做一半 | 24 | ~10h（读侧另 ~10h） |
| — | 读侧参数 | — | — | — | ⛔ 推迟 04 |

> **T2.3 是 02 计划 B1 的清算项**：02-1b 的"读 +16% 写 +70%"建立在**漂移基线**上（当时写 683↔1760 差 2.6×），必须在收敛基线上重验。这是 02 计划里唯一"已声称大收益但可能是假的"结论，优先级应高但成本最高 ⇒ 先做写侧一半看方向。

---

## 八、T3：写侧对象数预算（T1.3-T1.5 / T2.1-T2.3 的前置约束）

不是独立战线，是**所有写侧战役的物理前置**。

### 8.1 预算算式（⚑ 2026-08-11 依 F19-F27 全部实测值重写）

| 量 | 值 | 来源 |
|---|---|---|
| 对象大小 | **256 KiB 恒定精确** | F19（20,054/20,054 行） |
| 稳定起点（基线） | **2,359,530** 对象 = 576 GiB | prep 建 layout 3×128G + seqread 32G + seqwrite 32G + mseqread 64G + mseqwrite 64G，逐字节对上 |
| **性能**安全上限（轮前） | 3.11M | F6 |
| **性能**拐点区间 | (3.78M, 4.40M] | F6 |
| **单轮 gross 生成量** | `randrw` **0.88M**｜`seqwrite` **1.04M**｜`randwrite` **2.13M**｜`mseqwrite` **3.47M** | F21 实测 |
| 换算系数 | 顺序写 **f=1.000**（256 KiB/新对象）｜随机覆写 **f=0.876**（292 KiB/新对象） | F20 |
| 峰值实测 | **10,691,356**（含 mseqwrite） / **~4.1M**（剔除 mseqwrite+seqwrite 后推算） | F23 / F21 |
| 回收手段 | **只有显式 `gc --compact`**，一遍即可（第二遍逐字节无效） | F25 / F26 |
| 不可回收残留 | 顺序写 ~9.2%（结构性待删切片）；randrw ~0 | F27 |
| **集群容量**安全上界（已验证） | 17.03M / 6.1 TiB / 15.30% 全程 HEALTH_OK | 03-1 |

> 🔴 **两个"上限"不是一回事，不要混**：**3.11M / 拐点 3.78M 是性能拐点**（超过它 randrw 开始掉，影响数据可用性）；**17.03M 是集群容量安全上界**（超过它才有健康风险）。写侧战役同时受两者约束，但违反前者只是数据作废，违反后者才是安全事件。

**峰值口径算式**：`峰值 = 该项轮前起点 + 单轮 gross`。mseqwrite 最坏情形 = r4 起点 7.0M + 3.47M = **10.5M** ⇒ 这就是 F23 击穿的来源。

### 8.2 纪律

1. **门禁逐轮生效，不是逐战役**。轮前查 `OBJECTS`，达标即过；未达标则**立即显式 `gc --compact` 一遍**（不是等待），仍不达标则记 `UNALIGNED` 后**继续**（不中止战役），事后按起点值筛轮。
2. 🔴 **禁止依赖"等待自愈"**。F25 已证池可 8 小时零变化；F14 的 66min 自愈**只观测到一次、机制未定**（附录 A）。原 §8.2"首选办法是等待"**作废**。
3. 🔴 **必须有运行时看门狗**。轮边界闸门物理上看不见轮内峰值（F23）⇒ 写侧战役开工前必须补：由 `pool-tracer` 采样（15s 间隔，实测 20,054 行 0 ERR、最大间隔 16s）触发停机，或把闸门下沉到 fio 运行期间。**这是写侧战役的开工前置**（§十一.2）。
4. **`OBJ_GC_PASSES` 改 1**（F26），每战役省下大量 gc 时间。
5. **报数必须附**：该轮**轮前对象数** + 该 run **峰值对象数**（来自 `pool-trace.tsv`），使事后可做 F6 偏相关校正。
6. **优先用低对象数 `ITEMS`**：剔除 mseqwrite 后峰值从 10.69M 降到 ~4.1M，门禁问题基本消失（§6.2 注）。
7. **A/B 交错是硬要求**：即使有门禁，残余对象数漂移仍与时间序共线，且 F13/F16 已证同实例本身存在与时间共线的漂移。

---

## 九、T4：重铺类（layout / format 级）—— 暂缓

**属于这一类**：JuiceFS **BlockSize**（format 时定，只能建新卷）、format 级 **compress**、**EC profile / 新池**、**pg_num**。

**为什么不能直接测**：重铺 = 换 layout epoch，等价一次超级 compact（对象数归零）⇒ 跨 epoch 绝对值不可比 ⇒ 两臂都必须重铺且 A/B 交错重铺。σ_layout（同参数重铺的批间标准差）**未知**且有理由认为不小：删池重建曾致 32/32 数据 PG 的 acting set **100% 改变**、randread 漂移 16-37%（`00-baseline-20260723.md:223,250,306`）。⛔ 脚本 `phase0_layout`（`FULLBASELINE_V4.sh:722`）含 `rm -rf ${TEST_DIR}/*`（384 文件，10.5min）。

**定案打法**

1. **先做 σ_layout 试点**：同参数重铺 K=4，只跑 `randread randrw randwrite`，6-8h。σ_layout ≤2% → 可做随机区组设计；>5% → T4 全线关闭到 04。
2. **BlockSize 当"验证机制预测"而非"精测"**：256K→1M 是"对象数 ÷ 4"的 **300% 级**效应（F6 给了对象数→性能的定量关系），属验证性实验，K 可压到 2-3。⚑ F19 使这个预测更硬：对象数与字节量严格 256 KiB 挂钩，BlockSize 改 1M 后该恒等式的系数应变为 1 MiB，**可直接用 `stored/objects` 验证是否真生效**。
3. "同池两卷交错测"降级为**备选**：写侧共享池，对象数会被另一卷污染。

---

## 十、暂不做清单与复活条件

| 项 | 为什么不做 | 复活条件 |
|---|---|---|
| 需重启 OSD 的一切旋钮（cephx / Messenger / 线程模型 / `osd_op_queue=wpq`） | F7：重启本身 4.5-13% 噪声 > 效应 3-7% | 找到"重启后噪声可复位"的手段；或效应预期 >15%；或接受 24+24 次 sham restart |
| `--layout` / format 级 / EC profile / pg_num | σ_layout 未知，可能 16-37% | §九 试点显示 σ_layout ≤2% |
| 读侧挂载参数（`--max-readahead` 类） | 探针被污染，无可用替代探针 | 出现第三种探针，能分辨 5% 档差且与读路径解耦 |
| C 线（NVMe 队列 / IRQ / MTU / TCP） | 需重启服务或撞 157 红线；MTU 需 IT 确认 | 用户放宽 157 sysctl 红线；MTU 需网络组答复 |
| 档位机制归因 | F2 已主动放弃 | 有新假设且可在不重启前提下检验 |
| **38h 尺度单调退化机理（F16）** | ⚑ **本版新增**：超出作业尺度（战役 ≤14h），交错已压掉 87%，追机理需多实例×多昼夜对照 | 出现单战役必须 >14h 的需求；或退化幅度增大到吃掉判据余量 |
| **`seqwrite` / `seqread` 作判据** | 门槛 14.50% / 7.78% ≫ 效应量 5% / 4% | 找到降噪手段使 lag1 底噪降到效应量的一半以下 |
| **`rocksdb_cache_size`（原 K2）** | ⚑ 在 BlueStore 里不生效；真实消费者是 mon 的缓存比例阀，而 **mon 不在数据路径上** ⇒ 效应结构性为 0（§5.6） | ① 集群规模增至数百 OSD 且 OSDMap 高频抖动；② mon 内存吃紧（`mon_memory_target` 成为约束）；③ 离线大 store 操作 |
| **OSD 侧 KV 缓存（`bluestore_cache_size` / `_cache_kv_ratio`）** | `level: dev` 无 runtime flag，block cache 只在 `_open_db` 建一次 ⇒ 需重启 OSD ⇒ 撞 F7 | 04 阶段获得可接受的 OSD 重启窗口，或找到重启后噪声可复位的手段 |
| 04 阶段候选：io_uring FUSE / kernel mount | 内核 5.15 < 6.1 | 内核升级 |

---

## 十一、执行台账与排期

### 11.1 已完成任务台账

| 任务书 | 承载 | 产出结论 | 报告 |
|---|---|---|---|
| **03-1** | 探针交叉验证 | 🔴 **否证**：写侧探针不能作细粒度门控（留一法 r=−0.129、传导增益 0.221、SNR 差 22 倍）。副产品：传导增益首个定量值、高档带内极差 1.3%(n=6)、高档命中率 ~61%、**17.03M/6.1TiB 安全性验证** | `03-1-probe-cross-validation-20260806.md` |
| **03-2** | 读侧漂移底噪 | **F13**：randread 1.30% / mseqread 0.50%+单调漂移 / seqread 3.89% ⇒ 填上 T1 判据分母，seqread 移出 | `03-2-…md` |
| **03-3** | **T1.0** K8 协议自检 | ✅ **协议可信**：K8 判为无收益（预期 0，实得 0）。副产品：**F17 交错抵消 87%**、**F18 randread 是协变量不是看门狗** | `03-3-…md` |
| **03-4** | 写侧漂移底噪（WD1-WD10，38h17min，10 run 全 rc=0） | **F15/F16/F19-F27** 共 12 条。核心：写侧四项底噪测定、seqwrite 移出、对象数模型实测、**OBJ_MAX 红线被击穿（F23）**、**后台自愈不可依赖（F25）** | 待写 |

> 03-4 首次尝试（周五）因 V4 设计缺陷中止（`item_seqwrite`/`item_mseqwrite` 只调 `compact_cooldown` 不含 `gc --compact`，且"意外→中止→等人"在无人值守下必然丢数据）。改造为"记录后继续 + 预授权决策表 + 时间盒"后一次跑通 10 run。归档 `157:/tmp/opencode-03-4-weekend-20260809.tar.gz`（50M）。

### 11.2 开工前置（当前唯一阻塞）

| # | 项 | 阻塞谁 | 状态 |
|---|---|---|---|
| 1 | ~~**V4 磁盘门禁 20G → 5G**~~ | **一切战役** | ✅ **已完成（08-11）**，新 md5 `4198ea2676ba56744a3cd5eba17a5eab`，已上传 157 两端核对一致。原因：157 根盘 98% 满且由外部租户占据（docker 95G / `/home/server` 70G / weka 48G / turboai 31G / `/var/log` 29G / `/tmp/ray` 24G），**我们全部数据仅 306M**。20G 门禁使任何外部租户写 1G 就能掐死长跑（WD11/WD12 即如此）。清盘无意义也无权限 |
| 2 | 03-5 任务书（**T1.1 / K1** `bluestore_default_buffered_read`） | T1.1 | ✅ **已完成（08-11）** `doc/perf-tasks/03-5-t1.1-buffered-read-k1.md`，318→342 行，6 个 bash 块全过 `bash -n` |
| 3 | **运行时对象数看门狗**（§8.2 纪律 3） | **仅写侧 T1.3-T1.5 / T2** | ⏳ 待做，不阻塞读侧 |
| 4 | `OBJ_GC_PASSES` 2→1（F26） | 写侧（省时） | ⏳ 待做 |
| 5 | 旋钮授权 | K1/K7 ✅ **已批（08-11）**｜K3-K5 待读侧结果 | ✅ / ⏳ |

### 11.3 决策树

```
[判据分母]  ✅ 齐了：读侧 F13(03-2) + 写侧 F15(03-4)   ← 调优不再缺任何前置测量
[T1.0 协议自检]  ✅ 通过（03-3）
        ↓
[前置 1+2：门禁 5G + 03-5 任务书]
        ↓
[T1.1 K1] → [T1.2 K7]                  读侧 ~11.5h，门槛最好（1.5-3.0%）
        ↑ 原 T1.1(K2) 已于 2026-08-11 桌面核查取消（旋钮不生效，§5.5）
        ↓
   【决策点】读侧是否已榨干？是否值得投写侧 ~35h？
        ↓ 是（且先清前置 3+4）
[T1.3 K3] → [T1.4 K4] → [T1.5 K5]      写侧 ~35.5h
        ↓
[T2.3-写侧] --max-fuse-io 清算 → [T2.1] → [T2.2]
        ↓
[汇总]  有可判收益 → 组合验证（4 臂：基线 / A / B / A+B）→ 生产配置建议
        无            → 结论"在线空间已穷尽"，归因三类，转 04
        ↓
[可选] T1.6 K6（需拍板） / T4 σ_layout 试点（需拍板）
```

### 11.4 优先级表

| 优先级 | 项 | 预期收益 | 机器时间 | 风险 |
|:---:|---|---|---|---|
| ✅ | 03-2 / 03-3 / 03-4（判据分母 + 协议自检） | 已完成 | 已花 ~60h | — |
| **P0** | 前置 1+2（门禁 + 03-5 任务书） | 解除阻塞 | 开发 ~1h | 低 |
| ~~P1~~ | ~~T1.1 K2~~ | ❌ **取消**（§5.5 旋钮不生效） | — | — |
| **P1** | **T1.1 K1** `buffered_read` | 2-5% | ~4.5h | 低 |
| **P2** | **T1.2 K7** osd.3 归一化（兼诊断 straggler） | 未知，免费 | ~7h | 低 |
| **P2** | 前置 3+4（看门狗 + GC_PASSES） | 解除写侧阻塞 | 开发 ~2h | 低 |
| **P2** | T1.3 K3 / T1.4 K4 / T1.5 K5 | 3-15% | ~35.5h | 低 |
| **P2** | T2.3-写侧（清算 02 计划最大存疑结论） | 高信息量 | ~10h | 低 |
| **P3** | T2.1 / T2.2 | 中 | ~18h | 低 |
| **P3** | `randwrite` 转正 | 收口 | 0（T1 基线臂自然产出） | 0 |
| **P3** | `seqread` 转正（需 ≥3 实例含日间） | 收口 | ~6h（可搭 T2 便车） | 低 |
| **P4** | T1.6 K6 `csum=none` | 2-6% | ~23h | ⚠ 数据完整性，需拍板 |
| **P4** | T4 σ_layout 试点 | 决定 T4 开不开 | 6-8h | 中（`rm -rf` 测试目录） |
| ⛔ | 需重启 OSD / 读侧挂载参数 / C 线 / F16 机理 | — | — | §十 |

> **稳定性专项工作到此结束**。不再单独测底噪、不再追波动来源、不再做专门的稳定性 run。此后稳定性数据**搭车产出**：每个战役的基线臂天然就是稳定性样本，零额外成本。

---

## 十二、02 计划条目映射（不丢项）

| 02 计划 | 03 归属 | 变化 |
|---|---|---|
| A1 cluster_network 修复 | 已完成（Z1 生效，`10.3.2.0/24` 已核） | 关闭 |
| A2.1 cephx 分级 | §5.3 parked → 04 | **从 P1 降级**（无 runtime flag + F7） |
| A2.2 osd_memory_target 16GB | **作废** → K2 | 实查已 350 GiB（§5.4 异常二） |
| A2.3 Messenger/线程模型 | §5.3 parked → 04 | 无 runtime flag |
| A3 OSD 扩容 / A4 EC stripe | T4 / 04 | A4 属重铺类 |
| B1 FUSE dispatch（max-fuse-io） | **T2.3**（P2） | 从"已确认收益"改为"待清算的存疑结论" |
| B2 JuiceFS 内部参数 | **T1（K1/K3-K7）+ T2.1/T2.2** | 按切换代价重分，逐项配门槛；⚑ K2 已取消（§5.5） |
| B3 多实例可扩展性 | 04（依赖 A 线） | 不变 |
| B4 io_uring / kernel mount | 04 | 内核 5.15 阻塞 |
| C1-C4 | §十 暂不做 | 撞红线 / 需重启 |
| D1 randwrite-ow 波动分析 | **已完成**（02-2 稳定性攻坚是它的超集） | 关闭 |
| D2 大 block-size 基线 | 04 | 新口径，与本阶段基线不可比 |
| D3 细粒度并发扫描 | 04 | 并入 B3 |

---

## 十三、脚本状态与待改

### 13.1 当前版本

| 项 | 值 |
|---|---|
| `FULLBASELINE_V4.sh` | **md5 `4198ea2676ba56744a3cd5eba17a5eab` / 1368 行**（2026-08-11 磁盘门禁 20G→5G）｜✅ 已上传 157 并核对一致 |
| 历史 | ~~`dec5ee132fd6be25bbe744c6024466f1`~~（03-4 改造后）｜~~`4551ef3c0d405734ea0a4a281427a989` / 1373 行~~（有 PLATEAU 等待逻辑的旧版）｜~~`3fd1281fea1c08342051d64fc8eb1348` / 1272 行~~（无 `obj_gate`） |
| 🔴 纪律 | 上传到 157 后**必须在 157 上再算一次 md5 核对**（03-4 起跑前已因此发现 157 仍是旧版） |
| 🔴 纪律 | **不留多份脚本副本**（wrapper 是编排器不是副本，允许） |
| 🔴 纪律 | 长跑期间冻结本体，改动后 md5 须同步到 `FULLBASELINE-SKILL.md`、本计划、后续每份任务书的校验行 |

### 13.2 03-4 已落地的改造

1. `item_seqwrite` / `item_mseqwrite` 循环内 `compact_cooldown` → `aggressive_cleanup`（含 `gc --compact`），与 randrw / randwrite 一致；
2. `obj_gate()` 整段替换：**删除全部 PLATEAU / OBJ_TIMEOUT / 30min-sleep 等待逻辑**（F25 证明等待无效）。新逻辑 = 取数 → 查 `OBJ_MAX`（唯一硬停）→ 达标则过 → 否则显式 `gc --compact` → 仍不达标则 **SOFT-PASS**（记 `UNALIGNED` 后继续）；
3. 新增 `OBJ_GC_PASSES` / `OBJ_GC_SETTLE`；新增顶层 `pool_sample()`（取数失败重试 5×30s）；
4. wrapper 时间盒化：连续 2 次 rc≠0 才停、tracer 自愈重启、`drain_ladder` 阶梯排空。

> **设计原则（已验证有效，写入 `TUNING-SKILL.md`）**：无人值守长跑必须"记录后继续 + 预授权决策表 + 时间盒终止"，不能"遇意外就中止等人"。

### 13.3 待改清单

| # | 改动 | 理由 | 优先级 |
|---|---|---|---|
| 1 | **磁盘门禁 20G → 5G** | §11.2 第 1 项 | **P0** |
| 2 | **运行时对象数看门狗**（轮内峰值可见） | F23 红线被击穿 | **P2**（写侧前置） |
| 3 | `OBJ_GC_PASSES` 2 → 1 | F26 第二遍逐字节无效 | P2 |
| 4 | `PROGRESS.txt` 的 `randread_median` 口径统一 | 与 `rounds.tsv` **10/10 不一致**（系统性偏低 0.16-0.59%，如 WD3 报 1850 实为 1861），疑取了 `_bw.1.log` 逐秒均值 | P2 |
| 5 | `rounds.tsv` 表头修正（现 5 列，数据实为 8 列 `LABEL round BW_MiBs hit status pg_gate pg gear`） | 易误读 | P3 |
| 6 | `summary()`(:874) / `steady_state_eval`(:1015) 硬编码 7 项 → 读 `ITEMS` | 缺项走 `NA`，不崩不误判但输出难读 | P3 |
| 7 | 清理 4 处重复函数定义（`drop_caches` / `compact_cooldown` / `aggressive_cleanup` / `mkdir -p`） | 当前无害（后定义生效且函数体一致） | P3 |
| 8 | 交错编排 wrapper（`A B A B A B` 逐 run 交替 `ceph config set` + 记录恢复命令） | §6.1 | ✅ 已走通（03-1/03-3/03-4 模式） |
| 9 | 每 run 前后存 `dump_mempools` + `perf dump` | H1 观测 | ✅ 已采集，结论未定（附录 A） |

---

## 十四、口径与红线

### 14.1 测试口径（已固化在 `skills/FULLBASELINE-SKILL.md`）

- **验收口径**：逐秒均值，窗口 `15 ≤ sec − t0 ≤ 175`（**全局 t0**，非每文件 t0 —— 后者有 1.3% 系统性偏差）；取该项**逐轮中位数**。不认 fio 汇总 BW（`rounds.tsv` 的 `BW_MiBs` 列是 fio 汇总值，**不是验收口径**）。
- **方向位**：randrw 必须过滤方向（V4 `:979` 取读侧），报数标口径（F10）。
- **首轮规则**：`randwrite` / `randrw` 首轮单独记录、不进 L2 统计（F9）。
- 固定口径：block size 256K（对齐 EC stripe_width）、openfiles=128、`--max-readahead 0`、`--cache-size 0`、pool 3 EC 4+2 pg_num=32（冻结、autoscale off）。
- **门控前置**：任何 A/B 对比前必须探针门控并固定实例（F1）。
- **ITEMS 纪律**：子集绝对值 ≠ 全量绝对值，每战役自带同 `ITEMS` 基线臂（F11）。

### 14.2 取数纪律（踩过的坑）

- `ceph df --format=json` 的 `stored` / `max_avail` **全是字节**：`/2**30`=GiB、`/2**40`=TiB。同类量必须同口径 —— 曾把 `906,484,580,352 B`（906 **GB** = 844 GiB）当成 906 GiB。
- 取对象数**必须** `ceph df --format=json` + `python3`（157 **无 `jq`**）；不许 parse `2.36M` 这种缩写；取数失败**不许回落成 0**。
- `pgrep -c fio` 会匹配内核线程 `vfio-irqfd-clean`（恒 ≥1）⇒ 必须 `pgrep -af fio`。
- `perf dump` 全是**累计计数器**，必须取增量再算相关（直接用会得到伪相关）。
- 🔴 **一切除法/百分比/极差/CV/底噪/判据判定由 opencode 做，执行方只出原始表 + TSV**。依据：GLM 在 03-4 期间出过四个数值错（排空耗时 300s→实为 106s、峰值 906GiB→844GiB、排空速率 1.02→2.30 GiB/s、回收率 3324→9408 obj/s），另有 `randread_median` 口径不一致（§13.3 第 4 项）与磁盘占用误报（称 fio 日志占 20G，实为 306M）。
- `gc` 日志要**完整统计行，禁 `tail -3`**（旧 V4 的 `tail -3` 正是长期看不清 gc 行为的原因）。

### 14.3 红线（`skills/SYSTEM-SAFETY-SKILL.md`）

1. ⛔ 禁 `pkill -f fio` / `pkill -f juicefs` / `killall`（157 是 **3075 人共享机**，跑 WekaIO/K8s）
2. ⛔ 禁 `--layout`（含 `rm -rf ${TEST_DIR}/*`）、禁 `--allow-restart`
3. ⛔ 不重启 157、不重启任何 OSD；不动 157 内核 / 100GbE NIC / md0 / WekaIO
4. ⛔ 不改 IRQ / RPS / pg_num（autoscale 保持 off）
5. ⛔ **不动 `/tmp/ray`**（24G，owner `server`，外部租户）及任何非我们创建的目录
6. ⚠ `ceph config set` 属改集群配置：**每个旋钮单独授权**，须附配对恢复命令，事先 `ceph config dump` 存档
7. ⚠ `ceph health` 连续 3 次（间隔 5min）非 OK ⇒ 立停上报
8. ✅ 已授权 sudo：`ceph tell osd.N compact`、3 节点 `drop_caches`、`juicefs gc --compact`、`umount`/`mount`
9. 157 的 `/tmp` 易失 ⇒ 每个战役结束**当天**归档到 `results/`

### 14.4 长跑红线（03-4 验证有效，5 条）

① `objects` > 上限｜② health 连续 3 次非 OK｜③ 实例变（pid / starttime_ticks 变化或 `forced-mount`）｜④ `/tmp` < 5G 或 `max_avail` < 10 TiB｜⑤ 连续 2 run rc≠0 或连续 2 run randread median < 1700。**其余一切"记录 + 继续 + 事后报告"。**

---

## 十五、待拍板

| # | 问题 | 建议 |
|---|---|---|
| ~~1~~ | ~~授权哪些 `ceph config set` 旋钮？~~ | ✅ **2026-08-11 用户已批 K1 + K7**。K1 授权块见 `doc/perf-tasks/03-5-t1.1-buffered-read-k1.md` §旋钮授权（含配对恢复命令）；K7 待 03-6 任务书。写侧 K3-K5 待读侧结果出来后再批 |
| **2** | V4 磁盘门禁 20G → 5G（动脚本本体，md5 会变） | 建议批。不改则一切战役无法起跑，且清盘既无意义（我们占 306M）也无权限（其余是外部租户） |
| **3** | 写侧 `ITEMS` 是否剔除 `seqwrite` + `mseqwrite`？ | **建议剔除**。收益：单 run −42%、峰值对象数 10.69M→~4.1M、unaligned 归零、三个写侧战役共省 ~28h。代价：触发 F11（需自带基线臂，不与全量签收值比）；失去唯一的大块写项 |
| 4 | K7 给 osd.3 补 mclock 容量 | 建议授权。这是**修一个明显的配置缺失**（21500 vs 同伴 63911-79983），即使无性能收益也应修 |
| 5 | K6 `bluestore_csum_type = none` 是否可测？ | 涉及**数据完整性**。建议先不做，仅在 K1-K5 全无收益时评估，且测完立即改回 |
| 6 | 接受"一次只测一个旋钮 + 组合前各自单测"的时间成本？ | 建议接受，否则出了差异归因不了 |
| 7 | T4 σ_layout 试点（6-8h，含 `rm -rf` 测试目录）是否排？ | 建议暂不排，等 T1 结果。BlockSize 是 300% 级效应，值得做但要等在线空间榨干 |
| 8 | T1 是否强制排夜间？ | ⚑ **建议放宽**。原理由是"档位稳定只在夜间测过"，但 03-3（日间 4.5h）+ 03-4（38h 跨昼夜）已覆盖日间，且 F17 证明交错抵消 87% 的时段漂移。**改为：不限时段，但两臂必须同时段、且不得跨周末边界比较绝对值（F16 周六/周日 seqwrite 差 5.88%）** |

---

## 附录 A：已作废 / 已降级的结论（防止复引用）

| 结论 | 处置 | 依据 |
|---|---|---|
| **F14「JuiceFS 后台任务自动回收，66min 内自愈排空，对象数无永久泄漏」** | 🔴 **降级为"曾观测到一次，机制未定，不得作为设计依据"** | F25：池在 3,453,658 上静置 8 小时零变化（2568 行采样全同）。原 §8.2 纪律"首选办法是等待"**作废**，改为显式 `gc --compact` |
| 「脚本无 `gc --delete` ⇒ 对象泄漏 1.83M/实例」 | ❌ 作废（我在 03-1 报告 §七 写错，已用 ⚑⚑ 撤回） | F25/F27：不是泄漏，是回收需显式触发 + 约 9.2% 结构性残留 |
| 「探针归一化」/「用探针筛其它项也在高档」/「探针当看门狗」 | ❌ 全部作废 | 03-1 留一法 r=−0.129；03-3 F18 |
| 「r=0.88 ⇒ 写侧指标可作读侧调优的门控探针」（03-1 执行方结论） | ❌ 作废，改判为"组间同向传导成立（增益 0.221），组内无相关" | 03-1 复核，详见 `03-1-…md` §二 |
| 「T2 读侧调优难度降到与写侧同级」 | ❌ 作废，仍是最难 | 同上 |
| 档位在线看门狗（`±2%` / 区间式） | ❌ 作废 | F18：日间 4.5h 跌 1.72%，距下界仅 0.04% 余量 ⇒ 必然误报 |
| `obj_gate` 的 PLATEAU 三前置设计（`drain_started` + `elapsed≥2400s` + `plateau_count≥3`） | ❌ 作废，整套等待逻辑已删 | F25 |
| 「字节口径优先于对象口径」 | ❌ 撤回，两者是**同一个测量** | F19：`objects × 256 KiB ≡ stored` 逐行成立 |
| 「每 292 KiB 生成 1 对象」（作为全局常数） | ❌ 作废，换算系数**分项**：顺序写 256 KiB / 随机覆写 292 KiB | F20：把 292 套到顺序写低估 25% |
| 旧对象数基准 0.86 / 0.98 / 2.01 / 3.02 / 3.32M、6.47M、32.3M、35.85M、6.02M 门限论证 | ❌ 全部作废 | F21 实测值取代 |
| `OBJ_TARGET = 2.50M`（仅高于基线 140K） | ❌ 作废，比不可避免的欠账还小，是设计缺陷 | F27；已改 2.90M |
| 02 计划 A2.2「osd_memory_target 调到 16GB」 | ❌ 作废 | §5.4 异常二：已是 350 GiB |
| 02 计划 §11.4「分臂串行」 | ❌ 作废，改 A/B 紧邻交错 | F13/F17 |
| 「03-1 的 mseqwrite 绝对值」 | ❌ 报废，仅可作组内/组间相对比较 | X3 起已越过 F6 拐点下界 3.78M，X3-X8 全程在拐点之上，污染与实例序/档位序共线 |
| **K2 `rocksdb_cache_size` 512 MiB → 2-4 GiB（原 T1.1，P1 期望最高项）** | ❌ **取消**（2026-08-11 桌面核查 + 归属调查） | §5.5 / F28：带 `runtime` flag 但 `set_cache_flag` 使 512 MiB 在 BlueStore 里永不被读取，且 block cache 在 `_open_db` 建一次不 resize ⇒ 需重启 OSD ⇒ 撞 F7（**版本无关**）。⚑ §5.6 / F30 补充：该选项**并非无用** —— 它是 **mon 的缓存比例阀**且在 mon 里真生效，只是 mon 不在数据路径上 ⇒ 对我们效应结构性为 0。复活条件见 §十 |
| **01-5 §十二「512 MiB KV cache 太小，EC 每 op 4× RocksDB 查会吃延迟」** | ❌ **前提作废** | F29：实际 KV 缓存 = 30 GiB × 0.30 = **~9 GiB**（18×），运行态 meta 用量 1.22 GiB 旁证。缓存不小，假设失去依据 |
| H1「服务端 BlueStore 缓存渐进升温」 | ⏸ **未定论**，挪 T1.1/T1.2 顺带观测 | 取增量后 `d_buffer_hit%` 69.085→69.265、Spearman(run)=+0.886（n=6 临界）但与 mseqread 仅 0.486 不显著、幅度仅 +0.18pp；`d_onode_hit%` 无趋势(−0.371) |

---

> **附：文档索引**
> - 03 阶段：本计划 / `doc/perf-tasks/03-*.md` / `doc/perf-report/03-*.md`
> - 02 阶段：`doc/perf-analysis/02-backend-raw-cap-and-juicefs-tuning-plan.md`（§十一 交接章）
> - 01 阶段：`doc/perf-analysis/01-baseline-review-and-nolimit-plan.md`
> - 交付物：`report/基线测试报告-JuiceFS-E6-20260806.md`、`report/周报-JuiceFS调优工作汇总-20260802.md`
> - 方法：`skills/{FULLBASELINE,TUNING,SYSTEM-SAFETY}-SKILL.md`、`skills/TASK-BOOK-AUTHORING-GUIDE.md`
> - 数据：`results/stability-raw/`（+ `MANIFEST.md`）、`157:/tmp/opencode-03-4-weekend-20260809.tar.gz`
> - 源码：Ceph `/home/lilingfeng/project/ceph`（⚠ 本地是 main，集群 v17 quincy，查 flag 须注意版本差异）、JuiceFS `/home/lilingfeng/project/juicefs`
</content>
</invoke>
