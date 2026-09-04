# STAGE03 JUICEFS PERFORMANCE TUNING FINAL REPORT

## 文档状态

| 项 | 内容 |
|---|---|
| 阶段 | 03：JuiceFS参数调优、稳定性归因与架构可达性分析 |
| 报告日期 | 2026-08-28 |
| 后续修订 | 2026-08-31：04阶段U1完成，交付基座锁定为patched v1.4.1 |
| 阶段状态 | **已完成** |
| 目标 | 单客户端不限速100GbE口径，有效带宽达到网卡单向带宽一半，即`6250 MiB/s` |
| 最终判定 | **目标未达成；在线/低风险调优空间已收口；不可达原因已进入架构层** |
| 正式交付配置 | **JuiceFS v1.4.1 + B-catchup补丁** + 256K FUSE + 客户端私有`ms_async_op_threads=8` |
| 写侧最终归因 | 03-22c正式RUN `20260828-083811`，`EVIDENCE_VALID` |
| **交付基座版本锁定** | **已完成**：04阶段U1签`REPLACE_APPROVED`；见§5.6.4与U141d最终报告 |

### VERDICT（机器可读，引用请以本表为准）

```text
STAGE03_STATE            = STAGE03_COMPLETE_TARGET_NOT_MET_ARCHITECTURE_LIMIT
WRITE_SIDE_CEILING       = 3756.51 MiB/s (60.10% of 6250, 256-inode / fresh temp TiKV / RAM logs)
DELIVERY_RANDWRITE       = 2707 MiB/s (43.3%, 128-inode 交付口径)
READ_SIDE_BEST           = 5544 MiB/s (88.7%)；单挂载渐近上限≈6280；PG均衡理论值≈6267
TIKV_MEDIA_EFFECT        = +0.26% (全部本地存储 RAM vs NVMe，同拓扑)
LOGS_ISOLATION_EFFECT    = +5.05% 配对中位（4/4正向）；该值为真实第二NVMe的【上界】
BASELINE_VERSION_LOCK    = PATCHED_V141_APPROVED (MD5 24fae0852051c80ca571cb2f20275d46)
V141_ORIGINAL_RANDWRITE  = 551 MiB/s（必须携带B-catchup补丁）
```

本报告是03阶段唯一的整体收口入口。各阶段性任务书、报告和原始数据仍作为证据来源，但阶段状态、最终配置、未达标原因和后续方向以本报告为准。

---

## 一、执行摘要

03阶段完成了三类工作：

1. 建立足以判断小幅调优收益的稳定性与证据协议；
2. 修复JuiceFS随机写代码缺陷，并完成客户端、FUSE、librados和TiKV参数/容量边界测试；
3. 对剩余读写瓶颈完成架构归因，明确哪些措施可以生产固化、哪些需要改变集群或修改代码。

阶段内最主要的可交付收益如下：

- **修复JuiceFS v1.3.1随机写FlushTo异步补派发缺陷**：避免256K FUSE下randwrite从约`3000 MiB/s`塌至`551 MiB/s`；补丁版本恢复到正常写侧平台，且同日二进制对照显示新补丁方案相对旧方案写侧约`+5.8%`。
- **固化`ms_async_op_threads=8`**：高并发randread相对默认3线程的保守同批收益至少`+37.4%`，交付基线相对03-10为`+44.7%`；跨挂载CV由`20.01%`降至`0.79%`。该配置只通过客户端私有`CEPH_CONF`注入，不修改集群级Ceph配置。
- **确认WAL/Raft与KV物理路径分离有稳定性收益**：正式4组配对带宽全部提高，中位`+5.05%`；CV中位改善`2.36 pp`，`W4/W1`中位提高`0.0694`。但RAM logs不是可持久化生产方案，真实生产落地需三台TiKV节点各有一块独立持久设备。
- **量化TiKV存储介质的作用，并给出分离收益的上界**：同拓扑下把TiKV全部本地存储从NVMe换成RAM仅差`+0.26%`，介质效应量级为`0%--3%`；因此`+5.05%`是真实第二块NVMe的带宽**上界**，采购理由只能是稳定性（§5.5）。
- **确认v1.4.1必须携带随机写补丁并完成版本锁定**：v1.4.1原版randwrite为`551/552/551 MiB/s`（跨`2.6`倍池对象数三轮恒值），加B-catchup补丁后恢复到正常平台。04阶段U141d最终补证得到randrw读/写`−0.52%/−0.51%`、randwrite`−2.08%`、mseqwrite`+2.96%`，四端点均排除超过5%退化；因此exact patched v1.4.1获准替代v1.3.1，stock v1.4.1仍排除（§5.6.4）。

所有原口径测试项均未稳定达到`6250 MiB/s`。这不代表阶段失败或仍需继续扫参数，而是阶段产出了可交付的不可达结论：

- 单流项目受串行请求/提交周期约束；
- 高并发读进入当前6 OSD集群服务率及主PG分布约束；
- randwrite先受单inode同步TiKV事务周期约束，提高inode并发后又进入TiKV KV/compaction共享服务率；
- randrw受单客户端/集群读写共享容量约束；
- WAL/Raft隔离能减轻尾部，但不足以填补剩余约40%写带宽缺口。

因此03阶段可以按“**调优目标未达成，但可调空间、稳定性机制和架构原因均已闭环**”正式结束。

---

## 二、目标、范围与判定口径

### 2.1 测试目标

- 网络：100GbE，不限速，单向理论带宽约`12500 MiB/s`；
- 阶段目标：每个测试方向的有效带宽达到`6250 MiB/s`；
- 主要工作负载：`seqread`、`seqwrite`、`mseqread`、`mseqwrite`、`randread`、`randwrite`和`randrw`；
- `randrw`读写必须分向报告，禁止把两向相加后与单向目标比较。

### 2.2 03阶段允许的主调优范围

- JuiceFS客户端和FUSE参数；
- JuiceFS v1.3.1局部代码修复；
- 客户端私有librados配置；
- 不重启生产OSD、不重铺生产数据、不改变CRUSH/PG/EC拓扑的在线Ceph参数；
- 不修改生产TiKV数据目录前提下的只读归因和隔离临时集群实验。

需重启OSD/TiKV、重平衡数据、增加硬件、重建pool/layout或改变元数据事务语义的实验不属于03阶段必做项，统一记录在[集群变更型测试TODO](../perf-tasks/TODO-cluster-changing-experiments-after-stage03.md)。

### 2.3 有效带宽与证据纪律

阶段最终采用以下纪律：

- 使用实际fio I/O起点而不是进程fork时刻；
- 多job带宽按每份interval log与自然秒的时间重叠加权汇总；
- 正式窗、CV、W1--W4和`W4/W1`必须同时保存；
- 多臂实验采用同轮配对、ABBA/平衡顺序，禁止直接相减跨日终值；
- 证据完整性门与性能稳定性端点分离，不能因CV差而删除完整样本；
- 无效RUN只能保留工程观察，不能进入正式效应量。

---

## 三、最终交付配置

### 3.1 生产候选基座

```text
JuiceFS binary:
  /tmp/juicefs-1.4.1-patched
  version: 1.4.1 + B-catchup
  md5: 24fae0852051c80ca571cb2f20275d46

mount options:
  --max-fuse-io 256K
  --max-uploads 150
  --cache-size 0

client-private ceph.conf:
  [client]
  ms_async_op_threads = 8
```

`ms_async_op_threads`的交付规则不是固定写死8，而是：

```text
ms_async_op_threads >= OSD数据连接数 × 1.33
```

当前6个OSD对应8个线程。其作用是让worker数大于6条OSD数据连接数，从结构上降低建连落位偏斜；OSD数变化后必须重新计算。

### 3.2 适用范围与限制

- `ms_async_op_threads=8`只对高并发读有材料收益；低并发seqread中worker未饱和，基本无收益；
- 增加线程的客户端CPU成本约`1.24--1.42`核，生产客户端需保留余量；
- `mseqread`的基线命中率约`92.8%--93.3%`，主要测到buffer，不得把其全部提升归因于存储路径；
- WAL/Raft RAM分离没有进入交付配置；它是因果探针，不是持久化方案；
- B-catchup补丁未进入stock v1.4.1，生产交付必须保存源码commit、补丁顺序、构建参数、二进制校验和及回滚版本；若重新构建而非部署上述同MD5制品，须先完成可重现构建闭环与P0兼容性smoke。

---

## 四、交付配置七项基线与目标状态

下表来自03-17f V13交付配置的3次独立挂载中位数；写侧基线由03-17g同日二进制归因解锁。
04阶段U1是在同条件版本A/B中批准V14不发生材料性退化，并没有重新定义03阶段绝对基线，故表中
数值继续作为交付参考锚；新部署V14不得把U141d单轮/臂均值与本表混拼。它不与改变inode数、
临时TiKV或RAM介质的架构探针混用。

| 测试项 | 方向 | 交付中位 MiB/s | 目标达成率 | 状态与边界 |
|---|---|---:|---:|---|
| seqread | 读 | `1449` | `23.2%` | 未达标；单流串行延迟架构限制 |
| mseqread | 读 | `5366` | `85.9%` | 未达标；命中率约93%，不是纯存储路径值 |
| randread | 读 | `5544` | `88.7%` | 未达标；高并发读最佳可固化值 |
| randrw | 读 | `1870` | `29.9%` | 未达标；必须与写向分别验收 |
| randrw | 写 | `1870` | `29.9%` | 未达标；不得与读向相加 |
| seqwrite | 写 | `1570` | `25.1%` | 未达标；单流写提交链无在线参数解 |
| mseqwrite | 写 | `4676` | `74.8%` | 未达标；在线参数空间已结束 |
| randwrite | 写 | `2707` | `43.3%` | 未达标；该值为meta慢态交付基线 |

补充边界：

- 交付二进制本身没有造成写侧回退；03-17g同日ABBA显示其相对旧二进制约`+5.8%`。03-17f相对早期3018的下降主要来自跨日元数据状态变化；
- 03-22c的D1为256-inode、fresh临时TiKV、WAL/Raft RAM隔离，正式中位`3756.51 MiB/s`。它是架构边界探针，不是原128-inode生产测试项的替代基线；
- 03-17e双挂载D128合计中位`6125.7 MiB/s`、单轮最大`6293 MiB/s`，改变了挂载/并发语义且未稳定越线，不能据此宣布原单挂载randread达标。

---

## 五、阶段内确认有效的调优手段

### 5.1 JuiceFS随机写代码修复

JuiceFS v1.3.1中，异步`prepareID`与`writeChunk`竞争同一`fileWriter`锁；`writeChunk`检查时slice ID尚未就绪，满block的`FlushTo`被跳过，而`SetID`之后没有补派发。256K FUSE下该问题导致缓冲排水自锁，randwrite从约3 GiB/s降至`551 MiB/s`。

最终方案保留异步ID创建，在ID就绪后按条件补`FlushTo`，避免把用户WriteAt返回强制依赖于slice分配。该修复恢复性能并保留异步边界，是03阶段必须固化的代码项。

### 5.2 FUSE 256K请求

`--max-fuse-io 256K`将4 MiB应用I/O的FUSE请求拆分数由32减少到16。单流seqread/seqwrite相对128K历史口径观察到约`+13%/+20%`，但多流项没有同幅收益；它是交付基座的一部分，不是解决6250缺口的充分条件。

### 5.3 librados Messenger线程

默认3个msgr worker下，6条OSD数据连接在建连时可能落成不均衡分布，单个worker打满而其他worker欠载，造成不同挂载间15%--40%的抽签波动。8个worker使6条连接最多各占一个worker，消除结构性碰撞。

正式交付结果：

- randread好档对好档保守收益`+37.4%`，跨批交付值`+44.7%`；
- randread跨挂载CV由`20.01%`降至`0.79%`；
- 写侧A/B为`+0.7%`，处于噪声内，没有写侧代价。

### 5.4 TiKV WAL/Raft物理路径隔离探针

03-22c最终正式RUN在同一fresh临时TiKV、同一seed、相同KV文件系统和相同B256负载下，只把32 GiB WAL/Raft backing由共享NVMe移至RAM：

| 指标 | B1c：共享NVMe | D1：RAM logs | 正式效应 |
|---|---:|---:|---:|
| 四臂中位带宽 | `3607.63` | `3756.51` | 配对中位`+5.05%`，4/4正向 |
| CV | 个别arm达`12.19%` | `6.30%--7.55%` | 配对中位改善`2.36 pp`，4/4改善 |
| W4/W1 | 最低`0.810` | `0.946--0.994` | 配对中位提高`0.0694`，4/4改善 |
| Raft sync | W1约`0.22--0.23 ms`，W4约`0.74--0.80 ms` | W1/W4约`0.074--0.083 ms` | 同步日志尾延迟稳定 |

结论：WAL/Raft与KV/compaction共享物理设备是尾部波动放大因素，真实物理分离有明确的生产探索价值；但带宽收益未过`15%`材料门，且D1仍只达目标`60.10%`，因此它不是平均吞吐主墙。

### 5.5 存储介质本身不是随机写主因，`+5.05%`是分离收益的上界

在完全相同的“KV、WAL、Raft共盘”拓扑、相同seed/clone协议和相同B256负载下，只把TiKV的**全部本地存储**在介质间切换：

| 对照 | 来源 | TiKV本地存储介质 | 中位带宽 MiB/s |
|---|---|---|---:|
| 03-22 A（R01/R04） | `03-22-...-20260826.md` §3.1 | 全部RAM（tmpfs-backed loop/ext4） | `3699.30` |
| 03-22b A1（R01） | `03-22b-...-20260827.md` §3.1 | NVMe-backed loop/ext4 | `3709.03` |
| 差 | — | — | **`+0.26%`** |

即**把TiKV全部本地存储放进内存，相对放在NVMe上只差`0.26%`**。两者为跨RUN对照（03-22整体`EVIDENCE_INVALID`），因此只能作工程量级判断，但该量级差异过小，不可能由跨RUN噪声掩盖一个大效应。

同向的第二组：03-22 B（RAM，分盘）`3716.64` 对 03-22c B1c（NVMe，分盘）`3607.63`，差`+3.02%`。⇒ **介质效应量级为`0%--3%`。**

这条对照有两个直接后果，是本节必须单列的原因：

1. **随机写的主要约束不在存储介质**，而在同步元数据事务与KV/compaction服务率。这与§6.3的roofline一致，并解释了为什么把logs放进RAM也只买到`+5.05%`。
2. **`+5.05%`必须理解为真实第二块NVMe的带宽收益【上界】，不是点估计。** D1把32 GiB logs backing放在RAM，其介质服务时间与共享争用严格优于任何持久化NVMe；因此新增一块真实NVMe的带宽收益**不会超过`+5.05%`**。

⚑ 因此§8.1的采购建议必须按此上界表述：**为WAL/Raft增加独立盘的理由应落在稳定性（CV配对中位`+2.36 pp`、`W4/W1`配对中位`+0.0694`、D1四臂全部`CV≤10%`且`W4/W1≥0.90`），⛔ 不得以“补齐剩余约40%带宽缺口”为由申请该硬件。**

同时暴露一个尚未拆分的更大因子：历史H中心约`2880`→fresh临时集群`3607.63/3756.51`，组合差`+25%--30%`，**比已测出的介质效应大一个数量级，且从未被单独测量**。它同时包含fresh RocksDB namespace、元数据规模/region数、临时集群起点与nested loop。处置见[TODO C01/C01b](../perf-tasks/TODO-cluster-changing-experiments-after-stage03.md)。

### 5.6 JuiceFS v1.4.1版本替换评估（03阶段前期 + 04阶段最终闭合）

03阶段末对v1.4.1能否替代交付基座做了前期评估；当时只闭合了补丁必要性，正式替换判定随后由
04阶段U141b/U141d完成，最终结果见§5.6.4。

#### 5.6.1 v1.4.1原版存在同一随机写缺陷，必须携带补丁（可正式引用）

同集群、同挂载参数、同文件资产下：

| 二进制 | md5 | randwrite逐轮 MiB/s | 轮间CV |
|---|---|---|---:|
| v1.4.1原版（tag v1.4.1, commit 0b90c7d） | `58f4406e40e2001601711413682f4dde` | `551 / 552 / 551` | `0.10%` |
| v1.4.1 + B-catchup补丁 | `24fae0852051c80ca571cb2f20275d46` | `2754 / 2726 / 2679` | `1.39%` |

`551 MiB/s`与v1.3.1原版的崩塌值一致，说明该缺陷在v1.4.1中同样存在，未被上游修复（与03-17系列“主线重构只是掩盖竞态、竞态代码相同”的结论一致）。

该结论有一条独立的强支撑：原版三轮分别在池对象数 `6,332,742 / 6,332,742 / 2,434,678`（相差`2.6`倍）下运行，带宽仍恒为`551/552/551`（逐轮见`obj-gate-V141R.tsv`）。这排除了池状态、缓存状态与测试时段等环境因素，崩塌完全来自代码路径。

> **生产含义：若升级到v1.4.1，必须同时携带B-catchup补丁，否则随机写降至约五分之一。**

#### 5.6.2 元数据格式双向兼容，回滚可行（工程观察）

评估期间v1.3.1与v1.4.1在同一生产卷上多次交替挂载均成功，卷Setting未出现不可逆变化。该项将在U141b中作为独立验收门（P0兼容性门）正式确认。

#### 5.6.3 替换判定为什么尚未闭合

两次全量七项对比均因**测试设计**问题不能作为正式判定依据：

| 批次 | 失效原因 | 定性 |
|---|---|---|
| U141（32 cell ABBA） | mseqwrite每轮净增`0.9--1.3M`对象、`gc --compact`对活数据无效，池自`2.4347M`单向棘轮到`5.36M`；19/32 cell越`S15=3.11M`；**每一项B臂平均起点都高于A臂** ⇒ 臂效应与对象数共线不可分离。randrw批内`r(obj,BW)=−0.863`（斜率−33.5 MiB/s per M obj），预测漂移大于观测臂间差。randwrite的G8流形门8/8残差为负、均值−1.82σ、A臂越界 ⇒ 按预注册降级为不可判 | `EVIDENCE_INVALID` |
| V141R / V141P（两个全量对） | 序贯非交叉：原版全在`22:10--01:05`、补丁版全在`07:25--10:03`，臂与时段完全共线。补丁仅改`pkg/vfs/writer.go`（纯写路径），故三个读项是零假设对照，真值必为0，实测却为`−5.25% / −2.26% / +1.03%`（跨度`6.27 pp`），而轮内CV仅`1.1%` ⇒ 该设计对`|Δ|<5.2%`无分辨力，而替换判定要分辨的正是`3%--6%`量级 | `EVIDENCE_INVALID` |

⇒ 正式判定移交**04阶段前置项U141b**（`doc/perf-tasks/u141b-juicefs-141-replace-131-decision.md`）：轮级交错ABBA-BAAB把臂间时间间隔从小时级压到十分钟级，矩阵内保留同臂相邻对直接测噪声底`ε`，判定边界`M=max(3%, 2ε)`由数据推出。U141b通过后本报告§3.1的交付基座需相应修订。

#### 5.6.4 04阶段U141d最终判定（2026-08-31修订）

U141d用预注册二阶轮序趋势模型完成生产最相关写路径补证：randrw读/写效应分别为
`−0.52%/−0.51%`，randwrite为`−2.08%`，mseqwrite为`+2.96%`；四端点的单侧95%下界
均高于`−5%`。P0的`V14→V13→V14`挂载回滚通过，V14只增加空默认`Tiers`字段。

最终签 `REPLACE_APPROVED`：exact patched v1.4.1（MD5 `24fae085...`）替代patched v1.3.1；
该结论不覆盖stock v1.4.1，也不表示v1.4.1确认更快。完整统计、边界和证据见
[U141d最终报告](u141d-juicefs-v141-replace-v131-final-20260831.md)。

---

## 六、目标不可达的架构原因

### 6.1 单流顺序读

seqread为单流`psync iodepth=1`，吞吐由单请求完成周期决定。6250 MiB/s在256 KiB请求下要求约`41 µs`的等效周期，而现有链路一次跨网librados往返已经约`200 µs`以上；实测串行延迟约`1.46 ms`。在不改变单流语义、请求并行度或客户端架构的情况下，目标物理不可达。

### 6.2 高并发随机读

提高并发后，客户端线程、CPU和100GbE均有余量，但OSD `op_r`服务率增长趋缓、每op处理延迟上升。三轮拟合得到单挂载渐近上限约`6280 MiB/s`，目标6250已经是该上限的99.5%；实际J128稳定值为`5516.7 MiB/s`。

六个OSD的主PG/op分布长期固定为约`6:6:5:6:5:4`，max/mean约`1.136`。按最热OSD约束推算，完全均衡理论值约`6267 MiB/s`，与客户端拟合上限相互验证。要继续提升需要改变PG/pool/OSD布局，而不是继续增加下载并发或msgr线程。

### 6.3 随机写

写侧存在两级架构墙：

```text
128活跃inode：
  每inode内meta Write受open-file lock串行
  + 同步TiKV transaction约10--13 ms
  → 逻辑Write在客户端排队放大到约186--201 ms

提高到256活跃inode：
  独立inode通道增加
  → 很快进入TiKV KV/compaction及同步提交共享服务率
  → pending compaction、设备队列和提交延迟在轮内增长
```

6250 MiB/s、256 KiB写入要求约`25000`次逻辑写/秒；当前稳定meta提交能力约`12K/s`量级。128 inode要达标要求单通道周期约`5.1--5.6 ms`，低于历史快态约`9.97 ms`，因此小参数无法填补约2倍提交率缺口。

03-22c进一步证明：把WAL/Raft移到RAM后，Raft sync和带宽稳定性改善，但KV pending仍增长到约`11--16 GiB`，物理NVMe等待也没有消失。剩余主墙位于同步元数据事务和KV/compaction共享服务率，不在网卡、客户端CPU、`max-uploads`或单独的logs设备。

### 6.4 混合读写

同挂载并发读写在真实重叠窗口表现为读写强反相关，合计服务量主要落在约`4.0--4.2 GiB/s`，提高单侧供给会改变读写配比而不能让两向各自达到6250。多挂载和更高并发只能作为架构容量探针，不能替代原单挂载randrw验收语义。

### 6.5 顺序写与多流顺序项

seqwrite受单流写提交链约束，mseqwrite虽达到`4676 MiB/s`但仍缺约25%。03阶段未识别出具有明确剩余余量、可在线调整且预期超过稳定性门的单一队列或参数。继续提升需要改变并行语义、元数据提交方式、pool/OSD布局或集群容量，因此归入架构变更而不是保留一个无证据的参数待办。

---

## 七、元数据引擎波动原因最终结论

历史环境的跨日TiKV/RocksDB状态会影响一轮开始时的性能档位，但不是轮内波动成立的必要条件。即使每个arm使用fresh TiKV、fresh本地文件系统和同一immutable seed，B256仍会在单轮内重新生成约`11--16 GiB` pending compaction，并出现同步提交延迟和带宽尾段变化。

当前可成立的因果表述是：

> JuiceFS按inode串行推进同步元数据事务；高并发randwrite持续向TiKV产生KV/WAL/Raft写入，后台RocksDB compaction从W1即存在并在轮内形成债务。WAL/Raft与KV/compaction共享物理设备时，同步日志尾延迟被设备排队放大，客户端能够完成的meta事务减少，继而使上传管线失去供给并出现带宽低谷。这是软排队和服务率不足，不是RocksDB hard stall。

主动清理可以统一起点、避免跨arm污染，但无法阻止本轮重新建立compaction debt。WAL/Raft隔离可以改善稳定性，却不能消除KV主墙。

---

## 八、后续改造方向

### 8.1 可以形成近期生产决策的方向

如果三台TiKV节点能够各增加一块对称、持久、低尾延迟设备，可以评估WAL/Raft与KV SST/compaction真实物理分离。

⚑ **但必须按§5.5的上界表述，不得夸大：**

| 项 | 结论 |
|---|---|
| 带宽收益 | **上界 `+5.05%`**。D1的RAM logs严格优于任何持久化NVMe，真实第二块盘不会超过此值 |
| 稳定性收益 | CV配对中位`+2.36 pp`、`W4/W1`配对中位`+0.0694`、D1四臂全部`CV≤10%`且`W4/W1≥0.90` |
| 采购理由 | **只能是稳定性**。⛔ 不得以“补齐剩余约40%带宽缺口”为由申请该硬件——介质效应实测仅`0%--3%` |
| 验收方式 | 新拓扑稳定后重做生产等价共享盘/独立盘A/B，⛔ 不得直接引用RAM探针的`+5.05%`作为承诺值 |

同一NVMe上的目录、分区、LVM或两个loop仍共享控制器、队列、FTL和介质尾延迟，不能冒充真实物理隔离。

### 8.2 若继续追求写侧6250

按优先级进入新的架构阶段：

1. 减少每个数据写触发的同步元数据事务，研究批量/合并提交；
2. 在保持顺序、一致性和故障恢复语义下，实现同inode有序pipeline；
3. 增加带独立NVMe的TiKV节点，分摊region/leader和KV compaction服务率；
4. 评估更适合该同步小事务模型的元数据组件或分片方案。

### 8.3 若继续追求读侧6250

1. 优先在新测试pool验证更均衡的PG分布，禁止直接热改当前生产pool；
2. 评估增加OSD或改变pool/EC/stripe布局；
3. 新拓扑稳定后重新建立基线，不把重平衡期间的短时峰值当成收益。

### 8.4 可选归因而非调优

条件C使用现有生产NVMe原生ext4运行fresh临时TiKV，用于拆分历史H与fresh/nested-loop组合差异。它不需要额外NVMe，但需要停止生产TiKV和独立维护窗口；不做条件C不影响本报告的架构收口。

⚑ **优先级修订（2026-08-28）**：由于§5.5测出介质效应仅`0%--3%`，而H→fresh的`+25%--30%`比它大一个数量级且从未单独测量，条件C（C01）与新增的**元数据规模sweep（C01b）**的信息价值已高于继续做介质类实验。它们仍属“归因”而非“调优”，但应在架构阶段优先安排，用于给C03/C04定优先级。

全部集群变更项、风险和启动条件见[TODO-cluster-changing-experiments-after-stage03.md](../perf-tasks/TODO-cluster-changing-experiments-after-stage03.md)。

---

## 九、稳定性与数据准确性建设

03阶段不是只得到若干终值，还形成了后续性能实验可复用的证据合同：

- 一次layout建立immutable seed，每arm只restore/clone；
- fresh同时覆盖metadata namespace、本地文件系统、旧目录、容量和loop/ext4；
- 使用实际I/O起点和完整interval logs；
- 每arm执行独立GC和pool return；
- 容量、内存、swap、sampler覆盖、UUID/PID/anchor、配置和生产指纹属于非性能硬门；
- CV和`W4/W1`保留为性能端点，不因结果差删除arm；
- 失败保留现场并使RUN失效，不允许同RUN热修、补跑或拼样；
- 冻结manifest、执行账本、hash归档和独立离线复算。

这些规则实际阻止了三类误判：03-22容量污染被误认成存储臂性能、03-22b因CV删除控制臂、首次03-22c未经授权变更后仍签收。最终正式03-22c完成8/8 arm、G01--G08闭环、891行授权账本和9973项归档校验，才把WAL/Raft隔离效应签为`+5.05%`及稳定性4/4改善。

准确性投入的详细性价比复盘见[03-22c报告 §9.3](03-22c-tikv-hybrid-ram-logs-attribution-20260828.md#93-稳定性方法论收益)。结论是：防止错误生产结论和保护生产环境的性价比高，但逐小步人工往返造成的一次性时间/token效率中等偏低；后续应保留高价值门禁，将机械步骤固化成批量自动执行。

⚑ **本阶段结束时已完成该固化，后续任务不再重新发明**：

| 产物 | 作用 |
|---|---|
| [`skills/EVIDENCE-INTEGRITY-SKILL.md`](../../skills/EVIDENCE-INTEGRITY-SKILL.md) | 可复用机械件：有效带宽主口径与参考实现、多臂平衡与噪声底自校准、RUN有效性状态机、非性能门与性能端点分离、离线Gate 0、隔离台架合同、第二方复算、分阶段粒度 |
| [`skills/fixtures/known-defect-classes.tsv`](../../skills/fixtures/known-defect-classes.tsv) | **机器可校验**的32条已知缺陷类（含`severity`与`static_check`），Gate 0必须逐条断言覆盖；`CRIT/HIGH`共22条必须全覆盖。新踩的坑必须追加并填写`origin` |
| [`TASK-BOOK-AUTHORING-GUIDE.md`](../perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md) §二.13--18 | 每份任务书必须**声明**的条款：口径升级、门与端点分离、状态机、平衡设计、Gate 0、第二方复算 |

固化的量化依据：约**30个**缺陷是在集群上、用一整轮180 s arm才发现的，而它们全部是纯bash/解析缺陷；同一个B256负载被跑了**12 arm**，其中**4次只为修仪表**。因此优化目标不是“每个RUN几道门”，而是**离线发现的缺陷 / 集群上发现的缺陷**这个比率。

---

## 十、证据有效性边界

### 10.1 可以正式引用

- 03-17f/03-17g：交付配置和七项基线、msgr=8收益与写侧中性；
- 03-18：per-inode串行和TiKV同步事务周期roofline；
- 03-22c正式重跑：B1c/D1 4-pair效应、稳定性和机制时间线；
- **§5.6.1 v1.4.1原版randwrite崩塌`551 MiB/s`与B-catchup补丁必要性**（同日、同集群、跨`2.6`倍对象数三轮恒值，且03-7L独立复现同值551）；
- 03阶段计划书中经订正保留的F61/F62/F66/F69--F79。

### 10.2 只能作为工程观察

- 03-22 RAM A/B：R05容量生命周期失败，整体`EVIDENCE_INVALID`；
- 03-22b A1/B1：R03触发原CV硬门，矩阵未完成，整体`EVIDENCE_INVALID`；
- 首次03-22c：存在未经授权的容量/门限变化和执行合同缺口，`EVIDENCE_INVALID`；
- 03-20B系列：资源方向有价值，但原协议、字段或时间轴存在硬门问题，不能单独承担最终因果签收；
- **§5.5的介质效应`+0.26%`/`+3.02%`**：跨RUN对照，只作量级判断，⛔ 不得作为随机化因果效应量；
- **U141（32 cell ABBA）**：对象数棘轮使臂效应与池状态共线，`EVIDENCE_INVALID`；
- **V141R/V141P（两个全量七项对）**：序贯非交叉，纯读零假设实测偏差`5.25%`，`EVIDENCE_INVALID`。其randwrite原版臂三轮`551/552/551`可正式引用（见§10.1），但**七项对比的任何臂间差值不得引用**；
- **§5.5的H→fresh `+25%--30%`**：组合差，包含fresh状态、元数据规模、临时集群起点与nested loop，⛔ 不得归因到任何单因素。

正式报告不得把上述无效RUN的部分点值与有效RUN拼接成新的效应量。

---

## 十一、阶段完成判定

| 完成条件 | 状态 | 说明 |
|---|---|---|
| 建立稳定性和调优收益判定协议 | **完成** | 已能区分真实收益、环境漂移和不完整证据；已固化为`skills/EVIDENCE-INTEGRITY-SKILL.md`与GUIDE §二.13--18 |
| 修复阻断调优的JuiceFS写侧代码缺陷 | **完成** | 256K randwrite崩塌已修复 |
| 固化可生产使用的客户端配置 | **完成** | 256K FUSE、max-uploads 150、cache 0、私有msgr=8 |
| 定位元数据引擎波动原因 | **完成** | 轮内compaction/同步提交软排队，logs路径放大尾部 |
| 验证WAL/Raft隔离收益 | **完成** | 带宽约5%（且为上界），稳定性4/4改善 |
| **量化TiKV存储介质对随机写的作用** | **完成** | 介质效应`0%--3%`，不是主因；见§5.5 |
| **v1.4.1随机写缺陷与补丁必要性** | **完成** | 原版`551 MiB/s`，必须携带B-catchup补丁；见§5.6.1 |
| **v1.4.1能否替换交付基座** | **完成** | 04阶段U141d签`REPLACE_APPROVED`；exact patched v1.4.1锁定，见§5.6.4 |
| 达到6250 MiB/s | **未完成** | 七项原口径均未稳定达标 |
| 解释目标不可达原因 | **完成** | 已按单流、高并发读、随机写和混合读写形成架构结论 |
| 给出后续改造方向 | **完成** | 物理分盘、事务架构、TiKV扩容、PG/pool/OSD变更；04阶段计划书另立 |

**最终状态：`STAGE03_COMPLETE_TARGET_NOT_MET_ARCHITECTURE_LIMIT`。**

该状态表示：03阶段工作完成，但性能目标没有通过现有在线/低风险调优达到。条件C、真实第二NVMe、TiKV扩容、PG/pool重构和元数据代码改造均是新阶段或独立架构项目，不属于03阶段欠账。

⚑ **后续修订必须写明**：03阶段收口时 `BASELINE_VERSION_LOCK` 尚为 pending；04阶段U1已于
2026-08-31签`REPLACE_APPROVED`并按约定修订本报告§3.1/§4。性能批准只覆盖归档中的exact patched
v1.4.1；重新构建仍须闭合可重现制品身份。

---

## 十二、主要证据索引

| 内容 | 文档 |
|---|---|
| 03阶段计划、发现F1--F79和最终入口 | [03-juicefs-parameter-tuning-execution-plan.md](../perf-analysis/03-juicefs-parameter-tuning-execution-plan.md) |
| 交付配置七项基线 | [03-17f-deliver-config-baseline-20260821.md](03-17f-deliver-config-baseline-20260821.md) |
| 二进制与meta漂移归因 | [03-17g-binary-meta-attribution-20260822.md](03-17g-binary-meta-attribution-20260822.md) |
| 单inode/TiKV事务roofline | [03-18-tikv-meta-latency-attribution-20260822.md](03-18-tikv-meta-latency-attribution-20260822.md) |
| inode并发与共享墙 | [03-19-randwrite-inode-concurrency-20260823.md](03-19-randwrite-inode-concurrency-20260823.md) |
| TiKV轮内compaction机制 | [03-20A-tikv-inrun-compaction-attribution-20260823.md](03-20A-tikv-inrun-compaction-attribution-20260823.md) |
| TiKV物理隔离可行性盘点 | [03-21-tikv-storage-isolation-feasibility-inventory-20260824.md](03-21-tikv-storage-isolation-feasibility-inventory-20260824.md) |
| 03-22无效RUN及方法收益 | [03-22-tikv-ram-block-storage-isolation-ab-20260826.md](03-22-tikv-ram-block-storage-isolation-ab-20260826.md) |
| 03-22b NVMe软排队定位 | [03-22b-tikv-nvme-backed-storage-attribution-20260827.md](03-22b-tikv-nvme-backed-storage-attribution-20260827.md) |
| 03-22c正式因果签收 | [03-22c-tikv-hybrid-ram-logs-attribution-20260828.md](03-22c-tikv-hybrid-ram-logs-attribution-20260828.md) |
| v1.4.1原版崩塌与补丁必要性 | [juicefs-v1.4.1-vs-patched-v1.3.1-baseline-20260824.md](juicefs-v1.4.1-vs-patched-v1.3.1-baseline-20260824.md)（⚑ 该报告对照列有误，仅§randwrite原版逐轮值可引用） |
| v1.4.1替换判定失效分析 | [u141-abba-non-inferiority-20260824.md](u141-abba-non-inferiority-20260824.md)（`EVIDENCE_INVALID`，对象数棘轮） |
| v1.4.1替换正式判定任务书 | [u141b-juicefs-141-replace-131-decision.md](../perf-tasks/u141b-juicefs-141-replace-131-decision.md)（04阶段前置项） |
| v1.4.1替换最终判定 | [u141d-juicefs-v141-replace-v131-final-20260831.md](u141d-juicefs-v141-replace-v131-final-20260831.md)（`REPLACE_APPROVED`） |
| 证据完整性与统计口径机械件 | [EVIDENCE-INTEGRITY-SKILL.md](../../skills/EVIDENCE-INTEGRITY-SKILL.md) + [known-defect-classes.tsv](../../skills/fixtures/known-defect-classes.tsv) |
| 任务书必带清单 | [TASK-BOOK-AUTHORING-GUIDE.md](../perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md) §二.13--18 |
| 04阶段计划 | [04-metadata-architecture-and-layout-plan.md](../perf-analysis/04-metadata-architecture-and-layout-plan.md) |
| 阶段外集群变更测试 | [TODO-cluster-changing-experiments-after-stage03.md](../perf-tasks/TODO-cluster-changing-experiments-after-stage03.md) |
| 领导汇报版周报 | [周报-JuiceFS调优工作汇总-20260828.md](../../report/周报-JuiceFS调优工作汇总-20260828.md) |
