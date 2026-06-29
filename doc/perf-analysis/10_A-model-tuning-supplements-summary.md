# 10_A 三份模型调优补充（tun/）总结与裁决（2026-06-23，2026-06-23 更新验证结果）

> 本文是对 `tun/` 目录下三份独立模型调优补充文档的**汇总、去重、纠偏**，
> 并对照本目录最新结果文档 `10_3` 标注哪些建议已被实测**证实 / 证伪 / 取代**。

> 本文是对 `tun/` 目录下三份独立模型调优补充文档的**汇总、去重、纠偏**，
> 并对照本目录最新结果文档 `10_3` 标注哪些建议已被实测**证实 / 证伪 / 取代**。
>
> 三份原文保留在 `tun/` 作为出处与附录，不删除。本文为它们的统一索引与决策入口。
>
> 来源:
> - `tun/11-glm51-tuning-supplement.md`（GLM5.1，2026-06-22）
> - `tun/12-glm52-tuning-supplement.md`（GLM5.2，2026-06-22）
> - `tun/residual-amplification-tuning-qwen.md`（qwen，2026-06-22）
>
> ⚠️ **重要时间线**：三份均写于 `10_3`（L1 裸 RADOS 实测）**之前**，基于"残余 2.5×
> 放大归因未定"的假设。`10_3` 已实测 **L1 裸 RADOS 256K 随机读放大 = 1.04×**，
> 据此**证实放大在 JuiceFS 内部，不在 librados/EC/网络层**。本文据此对三份的诸多
> "EC / 网络 / 后端" 类建议做了证伪标注——阅读时务必以 `10_3` 结论为准。

---

## 〇、一句话总评

三份文档高度互补，共同最大贡献是**把"2.5× 残余放大如何分解"从悬案细化为一批可执行
剥离实验**。但 `10_3` 之后，其中针对 **EC 分片 / 网络 / 后端口径** 的实验大多已被
"放大在 JuiceFS 内部（L1=1.04×）"这一实测结论**提前证伪或降级**；真正仍然有效的，
是三份里指向 **JuiceFS / FUSE 内部** 的那几条（FUSE 节流、元数据缓存、pprof、slice 碎片）。

---

## 一、三份各自的核心主张

### 1.1 GLM5.1（`11`）—— 硬约束 + tcpdump 分解

- **§1 硬约束计算**：2.5× 放大下 `124 ÷ 2.5 = 49.6` 是单客户端千兆理论上限，
  当前 45.9 已达 92.5%，**单客户端 59 在 1Gbps + 2.5× 下物理不可达**。
- **§2 P0 = tcpdump 分解 2.5×（2026-06-23 GLM5.1 已自我修正）**：原稿认为 `sar` 含
  Ceph 后台噪声、tcpdump 可能测出真实 RAF < 2.5×；**修正后明确：OSD↔OSD 心跳/scrub
  等噪声走 OSD 之间、不上客户端网卡，故客户端侧 2.5× 是纯 JuiceFS 应用层放大**。
  tcpdump 的价值**不是"发现放大<2.5×"，而是分解 2.5× 的构成**（一次读触发几个对象 GET /
  每 GET 多大 → 区分 slice 碎片化 vs prefetch 拉相邻 block）。
- **§2.5 JuiceFS slice 碎片化**：多轮 layout+randwrite 后 slice 分裂，一次读触发多对象 GET；
  用 `juicefs fsck` / `gc --compact` 检查与缓解。
- **§3 FUSE 参数**：splice 零拷贝、max_read/max_write、max_pages、no_readahead。
- **§5 pprof CPU 热力图**：定位 FUSE 读路径 CPU 热点。
- **§6 256K 对象 rados bench**：修正"118/145 是 4M 对象口径错位"的后端裸上限。
  ✅ **此项 `10_3` 已实测完成**（L1 256K t=128 = 112.7 MB/s，已替代 4M 的 118/145）。

### 1.2 GLM5.2（`12`）—— 补 GLM5.1/qwen 未触及的六个新角度

- **§2 EC 4+2 → EC 2+1 对照**：同 1.5× 存储开销，读分片 4→2，是比"EC vs 副本 size=3"
  更干净的中间档对照，补 `09_1 §4` 的逻辑缺口。
- **§3 `allow_ec_overwrites=false` 对照**：怀疑 overwrites=true 下读时拉 6 分片做校验
  （多 1.5× 流量），是"幽灵 1.4×"的嫌疑。
- **§4 OSD 侧 perf dump**：把后端 145 拆成排队 vs 处理延迟；并建议测读路径
  `bluestore_cache_size_ssd`（`09_1` 只测了写路径参数）。
- **§5 PG primary 分布 / `primary_affinity` / balancer**：小集群 PG 不均可能造成热点 OSD。
- **§6 MTU 9000 jumbo frame**：64K 分片在 MTU 1500 下小包头开销，估降 RAF ~0.1×。
- **§7 多客户端 RAF 摊薄验证**：直指 `10_2` 4cl 聚合 92.1 > 单客户端天花板 58 的矛盾未被正面解释。

### 1.3 qwen（`residual-amplification-tuning-qwen`）—— 比例论 + FUSE 节流

- **核心比例论**：`达标率 = 1 / RAF`，与网卡绝对带宽无关 → 主张"**降 RAF 才是出路，升网卡无用**"。
- **方向一 FUSE `congestion_threshold` / `max_background`**：内核默认仅 9/12，而 workload
  iodepth/numjobs=128，FUSE 内核层可能在 9 个在途请求就节流；看 `/sys/fs/fuse/connections/*/waiting`，
  调到 768/1024。**零成本，最可能立竿见影。**
- **方向二 元数据强缓存复测**（attr/entry/open-cache）。
- **方向三 残余放大逐层剥离量化法**。
- **方向四 JuiceFS FUSE dispatch 单线程模型调研**。

---

## 二、关键裁决

### 2.1 ⚠️ qwen "升网卡无用" —— 片面，不可作决策依据

- 推理 `达标率=1/RAF` 数学自洽，但**默认"换万兆后 RAF 仍 2.5×"**。
- 而 2.5× 中很大一块次因是"单客户端千兆 RX 已饱和"（10 文档已确认次因 A）。万兆把 RX 墙
  移除后，有效读从"被 124÷2.5 卡死"释放到"后端 ÷ 纯协议放大"。
- 且按用户口径，换万兆验收线同步抬到 590——"比例目标"确实不靠升网卡达成，但**千兆下
  因 RX 先饱和根本到不了比例线，万兆下才有可能逼近 1/RAF 上限**。
- → **采纳"降 RAF 是千兆下唯一软件出路"，但拒绝"升网卡无用"的绝对判断。**

### 2.2 GLM5.1 "49.6 物理上限" —— 成立，但着力点被 `10_3` 改写

- GLM5.1 §1 的 49.6 计算前提是"2.5× 放大等比例占用客户端网卡 RX"。
- 这个前提**实际成立**：`10_3` 实测 JuiceFS 单客户端 randread 时 NIC RX≈113、有效读 45.9，
  比值≈2.5×——即 2.5× 确实大部分落在客户端网卡 RX 上（与 GLM5.1 2026-06-23 修正一致：
  OSD↔OSD 噪声不上客户端网卡，客户端侧 2.5× 是纯应用层数据放大）。
- 故 **`124 ÷ 2.5 = 49.6` 作为"当前 2.5× 不变时的单客户端千兆上限"仍然成立**，45.9 已达 92.5%。
- 真正被 `10_3` 改变的不是这个上限，而是**降 2.5× 的着力点**：L1=1.04× 证明放大不在
  EC/网络,无法靠换池/jumbo 降；只能从 JuiceFS 内部（预读/碎片/调度）降。
  降到 2.1× 才能让千兆上限抬到 59。
- → tcpdump（GLM5.1 §2.4 P0）仍是关键第一刀，但用途已随 GLM5.1 修正而变：
  **不是"看 2.5× 里多少上网卡"（已知几乎全部上），而是"拆这 2.5× 由几个对象 GET 构成"**
  （slice 碎片化 1 block=多 GET vs prefetch 拉相邻 block），据此选降放大的手段。

---

## 三、对照 `10_3` 的逐条状态

| 建议 | 来源 | `10_3` 后状态 | 说明 |
|------|------|--------------|------|
| tcpdump 分解 2.5× 的构成（几 GET/读、每 GET 多大） | GLM5.1 §2.4 | ✅ **已完成并裁决（10_A_2_3 §4.4 strace + 重测）** | tcpdump 全量 2.75× 因窗口噪声**降级不采用**；以 **strace 2.60×**（应用层净）+ **NIC 2.98×**（numjobs=8 重测）为准。strace 每 fio read = 139 次 ≈ 4 OSD × 35，**精确对齐 EC 4+2、排除 slice 碎片化**；无需 Ceph dissector 再裁决 |
| FUSE `congestion_threshold`/`max_background` | qwen 方向一 | ❌ **已证伪（10_A_1）** | randread 期间 `waiting ≈ 0/1` 全程 50 个采样点，FUSE 内核未节流；当前 50/37 已足够覆盖 iodepth=128 |
| 元数据强缓存复测 | qwen 方向二 | ❌ **已证伪（10_A_2_3）** | attr-cache/entry-cache/open-cache=300 对纯 randread 无增益，确认 TiKV 元数据往返非瓶颈 |
| pprof CPU 热力图 | GLM5.1 §5 | ✅ **仍有效** | 定位 JuiceFS 内部 CPU 热点，正中放大归属层 |
| JuiceFS slice 碎片化 fsck/gc | GLM5.1 §2.5 | ✅ **仍有效** | 内部对象 GET 放大，属 JuiceFS 层 |
| **FUSE 预读控制 `no_readahead` + `--prefetch 0`** | GLM5.1 §3.4/§2.2 | ✅ **仍有效，升为高优先** | 10_A_2_3 mount 日志已确认 cache-size=0 时 `--prefetch` 自动禁用；`no_readahead` 待 kernel 支持后验证（当前 fusermount3 3.10.5 不支持） |
| FUSE splice/max_read/max_pages | GLM5.1 §3 | ⚠️ **kernel/fusermount 不支持（10_A_7）** | fusermount3 3.10.5 + kernel 5.15 不支持 splice_read/splice_write/splice_move/max_write/max_pages/no_readahead；max_read 被静默忽略（仍 128K）。需升级内核才能验证 |
| JuiceFS 线程模型调研 | qwen 方向四 | ✅ **仍有效** | 内部；判断是否 FUSE dispatch 单线程瓶颈（解释为何并发参数无效） |
| 残余放大逐层剥离量化法 | qwen 方向三 | 🔁 **已被合并** | 其"剥 EC/改 block 看 RX"已被 `10_3` L1 做掉/证伪；剩余有效内核=L1/L2/L3 分层定位 + tcpdump 分解，已并入候选第 2 与 L2 行，不重复列 |
| 256K 对象 rados bench（修后端口径） | GLM5.1 §6 | ✅ **已被 `10_3` 完成** | L1 256K t=128 = 112.7 MB/s，已替代 4M 的 118/145 |
| EC 4+2 → EC 2+1 对照 | GLM5.2 §2 | ⚠️ **优先级大降** | L1=1.04× 已证 EC 取片几乎不放大网卡流量；改分片数预计收益极小 |
| `allow_ec_overwrites=false` 对照 | GLM5.2 §3 | ⚠️ **基本证伪** | 若 parity 校验读多拉分片，L1 RX 应远 >1.04×；实测 1.04× 说明无此放大 |
| MTU 9000 jumbo | GLM5.2 §6 | ⚠️ **降级** | 头开销已含在 L1 的 1.04× 里（仅 4%），jumbo 至多省这 4% 的一部分 |
| OSD perf dump 拆后端延迟 | GLM5.2 §4 | 🔶 **仍可做但非主线** | 后端裸能力 112.7 已知充足，瓶颈不在后端；仅多客户端天花板分析时有用 |
| `bluestore_cache_size_ssd` 读缓存 | GLM5.2 §4.4 | 🔶 **非主线** | 同上，后端非瓶颈 |
| PG primary 分布 / balancer | GLM5.2 §5 | 🔶 **非主线** | 抬后端天花板，但当前瓶颈在 JuiceFS 内部非后端 |
| 多客户端 RAF 摊薄验证（解释 92.1>58） | GLM5.2 §7 | ✅ **文档缺口仍需补** | `10_3` 修正后端到 112.7 后，4cl 92.1 已可由"后端 112.7÷~1.x"解释，但仍建议在 10_2 正面补一句 |
| EC 取片非主因结论需加限定 | GLM5.2 §9 | ✅ **已被 `10_3` 直接坐实** | L1=1.04× 是比 EC 2+1 更强的证据，结论无需再加限定，反而被加强 |

图例：✅ 有效/已完成 ｜ ⚠️ 已被 `10_3` 证伪或大幅降级 ｜ 🔶 可做但非当前主线

---

## 四、整合后的候选清单（含验证结果）

> 2026-06-23 更新：顺位 1/2/3/4/7 已完成验证并记录在新文档中。

| 顺位 | 实验 | 来源 | 为什么 | 验证结果 | 成本 |
|------|------|------|--------|---------|------|
| ~~1~~ | ~~**FUSE `waiting` / `congestion_threshold`/`max_background`**~~ | qwen | — | ❌ **已证伪（10_A_1）**：waiting≈0，FUSE 未节流 | 极低 |
| 2 | **tcpdump / strace 分解 2.5× 构成** | GLM5.1 | 定位降放大的具体着力点 | ✅ **已基本完成（10_A_2_3 §4.4 strace）**：syscall 层 Ceph/fio=2.60×，4 OSD 参与（排除 slice 碎片），每读 139 read() 调用 | 低 |
| ~~3~~ | ~~**元数据强缓存复测**（attr/entry/open-cache）~~ | qwen | — | ❌ **已证伪（10_A_2_3）**：对纯 randread 无增益 | 极低 |
| ~~4~~ | ~~**预读关停 `--max-readahead 0`**~~ | GLM5.1 §3.4/§2.2 | — | ⚠️ **结论修正（见 `10_A_4` §六真冷态 sweep）**：早前"readahead 是主要放大来源、关停达标 77.7"是 **cache=100G（prefetch 开）口径**。**真冷态（`--cache-size 0`，连带强制关 prefetch）下：readahead 量 1~default 间随机读不变（37.2~37.7），仅全关(0)到 52.0，仍不达标。readahead 非 2.5× 放大主因；真主因=EC 取片+librados 协议帧（strace 139≈4×35）** | 极低（已完成） |
| 5 | **pprof CPU 热力图** | GLM5.1 | 精确定位内部热点（FUSE/调度/拷贝） | 待测 | 中 |
| 6 | **slice 碎片化 fsck / gc --compact** | GLM5.1 | 内部对象 GET 放大 | 待测 | 低 |
| ~~7~~ | ~~FUSE splice/max_read/max_pages~~ | GLM5.1 | — | ❌ **kernel/fusermount 不支持（10_A_7）**：fusermount3 3.10.5 + kernel 5.15 不支持 splice/max_write/max_pages/no_readahead；max_read 被静默忽略 | 低 |
| 8 | **JuiceFS 线程模型调研**（是否 FUSE dispatch 单线程瓶颈） | qwen 方向四 | 解释"并发参数为何全无效"，指导后续是否值得改源码 | 待测 | 低 |
| — | L2 CephFS 同口径对照（区分 FUSE 层 vs JuiceFS 协议层） | 10/10_3 | 精确归因，但不改优化方向 | 待测 | 中 |

> EC 2+1 / overwrites=false / MTU jumbo / 256K rados bench / OSD perf dump / PG 均衡
> 等"后端与网络"类实验已被 `10_3`（L1=1.04×）证伪或降级，**不再列入主线**，仅在需要
> 抬"多客户端聚合天花板"时回看 GLM5.2 §4/§5/§7。

---

## 五、验证结果文档索引

以下为本轮验证新建的独立结果文档（2026-06-23）：

| 文档 | 顺位 | 结论 |
|------|------|------|
| `10_A_1-fuse-congestion-threshold-result.md` | 1 | ❌ FUSE 节流非瓶颈（waiting≈0） |
| `10_A_2_3-tcpdump-metadata-cache-results.md` | 2+3 | ✅ 已裁决：放大以 strace 2.60×／NIC 2.98×（numjobs=8）为准，tcpdump 2.75× 降级；slice 碎片化经 strace（139≈4×35）排除；❌ 元数据缓存无效 |
| `10_A_7-fuse-splice-maxread-results.md` | 7 | ❌ kernel/fusermount 不支持 splice/max_read/max_pages/no_readahead |

---

## 六、需回填到其他文档的两点（GLM5.2 提出，仍有效）

1. **`10_2` 补一句解释 4cl 聚合 92.1 vs 单客户端天花板**：`10_3` 已把后端裸上限从 145
   修正为 256K 口径 112.7，4cl 92.1 已可由"后端 112.7 ÷ 多客户端低放大"解释，矛盾消解，
   但文档应正面写明，避免读者以为不自洽。
2. **`09_1 §4 / §7.5` 的"EC 取片非主因"** 已被 `10_3` L1=1.04× 强化坐实，可在该处加一行
   指向 `10_3`，无需再保留"对照可能下得太早"的保留意见。

---

## 七、一句话结论（2026-06-23 更新）

三份模型补充在 `10_3` 实测"放大在 JuiceFS 内部（L1=1.04×）"之后被重新筛选。截至 2026-06-23，候选清单 8 项中已完成 5 项验证（4 项有明确结论）：

| 状态 | 项 | 结论 |
|------|---|------|
| ❌ 已证伪 | 1(FUSE 节流) 3(元数据缓存) 7(FUSE splice/max_read) | 均非瓶颈或不可用 |
| ✅ 已基本完成 | 2(tcpdump/strace) | **strace syscall 层 2.60×**，4 OSD 参与（排除 slice 碎片），139 read()/fio read |
| → 待测 | 4(FUSE 预读) 5(pprof) 6(slice 碎片/gc) 8(线程模型) | 下一轮优先 |

**核心发现**：strace 证明每个 fio 256K 读取恰好触发 4 个 Ceph OSD 应答（EC 4+2 理论值），排除 slice 碎片化。2.60× 放大来自 librados 的 ~5KB 粒度分段读行为 + Ceph messenger 协议开销——属 librados 层，非 JuiceFS 内部放大。

**指向 librados 层的优化（连接池、读取合并、批量操作）可能是比 JuiceFS/FUSE 调参更有效的下一轮方向。**
EC/网络/后端类建议已被 L1=1.04× 证伪或降级。qwen 的"降 RAF 是软件出路"采纳，"升网卡无用"驳回。
