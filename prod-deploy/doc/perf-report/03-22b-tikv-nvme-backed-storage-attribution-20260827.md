# 03-22b 测试报告：TiKV NVMe-backed A1/B1 逻辑隔离归因

## 日期与结论

- 日期：2026-08-27
- RUN_ID：`20260826-164047`
- 工作负载：randwrite，256 KiB，256 job / 256 inode，iodepth 64，runtime 180 s
- A1：每节点一个 128 GiB NVMe-backed loop/ext4，KV、WAL、Raft共享
- B1：每节点96 GiB KV与32 GiB WAL/Raft两个NVMe-backed loop/ext4，底层仍为同一`/dev/nvme1n1`
- 正式判定：**`EVIDENCE_INVALID`**

R01/A1与R02/B1通过全部证据和稳定性门；R03/B1的数据、采集与环境证据完整，但正式窗CV为`10.701303%`，超过预注册的`10%`稳定性硬门，analyzer按合同拒绝生成`arm-analysis.json`。RUN随即在R03停止，R04--R08未运行。因此本RUN不能给出A1/B1正式因果结论，也不能用R01/R02一个配对宣告逻辑隔离有效或无效。

本RUN仍把CV上升的直接触发层定位得比03-20更清楚：测试后半程TiKV compaction写放大与WAL/Raft同步写共同汇聚到同一物理NVMe，设备队列和同步延迟一起上升，产生越来越深的带宽低谷；三节点RocksDB hard write-stall计数始终为0，属于软性排队而非硬停写。R02与R03的正式中位数几乎相同（`3651.45`与`3651.23 MiB/s`），差异主要是R03尾部低谷更深，说明当前问题首先是稳定性而不是平均服务率全面下降。

---

## 1. 设计、变量与推断边界

预注册顺序为：

```text
R01=A1, R02=B1, R03=B1, R04=A1,
R05=B1, R06=A1, R07=A1, R08=B1
```

每个arm均重新对精确loop执行`mkfs.ext4`并启动fresh PD/TiKV；工作集来自同一immutable seed的metadata restore与`clone -p`。正式窗为实际I/O起点后的`[15,175)`，W1--W4各40秒；256份fio interval-average日志按与自然秒的重叠时长加权后逐秒求和。

A1/B1只改变同一物理NVMe之上的逻辑拓扑：

| 比较 | 可回答 | 不可回答 |
|---|---|---|
| A1↔B1 | 独立loop/ext4及其上层queue/worker在同一NVMe上是否有材料收益 | 真实物理分盘、独立控制器或PCIe路径收益 |
| 历史H↔A1/B1 | fresh临时TiKV、nested loop和当前环境的组合差异 | fresh状态、介质、loop开销的单因素贡献 |
| 03-22 RAM↔03-22b NVMe | RAM与NVMe方向性工程参照 | 同日随机化介质效应 |

由于正式矩阵只完成2个PASS arm并在第3个arm触发硬门，所有臂间数字只能标为描述性结果。

---

## 2. 证据完整性与归档

最终archive已持久化到：

```text
results/prod-stage03-raw-20260827/opencode-t3.22b-20260826-164047.tar.gz
```

| 项 | 结果 |
|---|---|
| archive bytes | `59001849` |
| 外层SHA-256 | `7cd9e57276a19b2ee17966b369bc3a0fac75da3869582ae226689b8e225ac137` |
| tar结构 | 3438个成员；可完整列举，含根级`SHA256SUMS` |
| R01/R02 | 各有256份BW log、I/O起点、完整sampler和`arm-analysis.json` |
| R03 | 256份BW log、I/O起点、完整sampler、invalid evidence v2与`RUN_INVALID.tsv`；analyzer按失败合同不写JSON |
| RUN_INVALID | `failed_instance=R03`，reason=`formal-stability-cv-gate-failed` |
| finalize | `FINALIZE_PASS mode=invalid`；只证明证据与环境闭包，不使性能矩阵转为有效 |

首次finalize在151静默退出，根因是脚本把不存在的可选legacy destroy audit作为引用字面量加入数组。只读逐断言和`bash -x`唯一确认后，修复为“legacy仅在`-e`或`-L`时加入、SHA-bound audit使用nullglob且总数至少1”，并新增三种Gate 0夹具。首次失败证据被保留在archive的`closure/finalize-failed-legacy-audit-literal-20260827/`，没有伪造151/152的legacy audit。

---

## 3. 正式arm结果与RUN判定

### 3.1 带宽和稳定性

| arm | 臂 | median MiB/s | mean MiB/s | CV | W1 | W2 | W3 | W4 | W4/W1 | 6250达成率 | 判定 |
|---|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| R01 | A1 | 3709.03 | 3665.71 | 6.83% | 3812.83 | 3593.98 | 3709.03 | 3703.42 | 0.971 | 59.34% | PASS |
| R02 | B1 | 3651.45 | 3599.18 | 8.52% | 3735.46 | 3688.88 | 3594.08 | 3539.21 | 0.947 | 58.42% | PASS |
| R03 | B1 | 3651.23 | 3584.47 | **10.70%** | 3810.66 | 3659.65 | 3510.91 | 3493.13 | 0.917 | 58.42% | **FAIL：CV** |
| R04--R08 | — | — | — | — | — | — | — | — | — | — | 未运行 |

R03的`W4/W1=0.916673`仍高于0.90，唯一正式失败项是CV。该CV不是缺log、采样错窗、容量不足、Ceph异常或TiKV store Down造成；这些非性能证据门均通过。

### 3.2 只允许描述的比较

| 比较 | 数值 | 边界 |
|---|---:|---|
| R02/B1相对R01/A1 | `−1.55%` | 仅一个相邻配对，且全RUN无效 |
| R03/B1相对R02/B1 median | `−0.006%` | 中位数几乎不变 |
| R02→R03 CV | `8.52%→10.70%` | 同一B1的低尾加深，不等于平均带宽持续下降 |
| R01/A1相对历史H中心2880 | `+28.79%` | 跨阶段组合效应 |
| R02/R03 B1相对历史H中心2880 | 约`+26.78%` | 跨阶段组合效应 |

A1/B1都只有约`3.65--3.71 GiB/s`，距6250仍有约`2.54--2.60 GiB/s`。即使忽略RUN无效，现有点值也没有显示逻辑分离接近达标。

---

## 4. CV升高的秒级定位

### 4.1 现象不是整体带宽平移，而是尾段深跌

| arm | 全窗CV | W4 CV | 正式窗最低秒 MiB/s | 说明 |
|---|---:|---:|---:|---|
| R01/A1 | 6.83% | 7.75% | 2986.6 | 尾段低谷有限 |
| R02/B1 | 8.52% | 12.34% | 2193.4 | 后半程开始出现深跌 |
| R03/B1 | 10.70% | 16.41% | **1508.6** | 尾段深跌触发CV硬门 |

R03的W1均值为`3811.0 MiB/s`，反而高于R02 W1的`3691.7 MiB/s`；两轮全窗median也几乎相同。这不支持“下一轮从开头就整体变慢”的简单累计退化模型。

### 4.2 R03前后台竞争同步增长

三节点约1秒iostat/PSI与约5秒TiKV Prometheus快照按正式I/O起点对齐后：

| 指标（三节点聚合/均值口径） | R03 W1 | R03 W4 | 方向 |
|---|---:|---:|---|
| fio带宽均值 | 3811.0 MiB/s | 3329.6 MiB/s | −12.6% |
| TiKV pending compaction | 0.12 GiB | 11.29 GiB | 大幅累积 |
| compaction写流量 | 7.2 MiB/s | 670.9 MiB/s | 与前台同步写重叠 |
| 底层NVMe `w_await` | 2.60 ms | 18.05 ms | 6.9× |
| 底层NVMe `aqu-sz` | 28.9 | 92.3 | 3.2× |
| I/O PSI some | 22.0 ms/s | 72.1 ms/s | 3.3× |
| Raft engine sync | 0.168 ms | 0.763 ms | 4.5× |
| commit-log平均延迟 | 约1.04 ms | 约8.59 ms | 8.2× |

R03最低点附近不是单节点偶发：例如相对秒146，150/151/152的底层NVMe `w_await`约为`52.28/26.77/30.64 ms`，队列深度约`194.8/153.2/129.7`。

5秒窗口内带宽与关键压力指标的Pearson相关系数为：

| 指标 | r(BW, 指标) |
|---|---:|
| pending compaction bytes | −0.797 |
| compaction written bytes/s | −0.674 |
| TiKV apply wait | −0.725 |
| commit-log latency | −0.804 |
| Raft engine sync latency | −0.821 |
| 底层NVMe `w_await`（约1秒） | −0.406 |

相关性本身不是单独的因果证明，但时间顺序、三节点同步出现和物理共享路径一致：compaction debt建立后，后台写入抬高同一NVMe队列，WAL/Raft同步事务被放大，前台带宽出现深低谷。

### 4.3 排除与尚未唯一定位的层级

- `tikv_engine_write_stall`、全部stall reason和`stall_micro_seconds`均为0，排除RocksDB硬写停顿。
- 每个arm重新mkfs并启动fresh TiKV，排除SST/WAL/Raft文件直接跨arm遗留。
- R03 W1较快且median未下降，不支持单纯的全局热降频或从起点开始的介质退化。
- 现有证据仍不能唯一拆开compaction调度相位、NVMe内部FTL/GC/温度状态与Ceph/OSD运行期扰动；03-22b没有同步保存足够的NVMe SMART和OSD秒级数据。

因此当前最准确的定位是：**直接触发层已收敛到TiKV轮内compaction与WAL/Raft在同一物理NVMe上的软性排队；R03为何比R02更严重的跨轮残差尚未唯一归因。**

---

## 5. seed、reset与闭包

### 5.1 formal seed

| 项 | 值 |
|---|---|
| volume UUID | `82d3e3d8-857e-4e82-a9e9-5ea02529bf22` |
| metadata dump SHA-256 | `66432a7acffa3460c60acd7b65cf234374587b6978c6a74f1253727635f67e83` |
| layout manifest SHA-256 | `a127a81e8cf7a30b5c86c37d770b67dd2a91fd88de58794917ebe5b2eed756a2` |
| content anchors SHA-256 | `4cbf69fad8a6fd18b84f528db687839695260e545f5d14ee21e232b09fdde293` |
| JuiceFS MD5 | `de93563f11a5ff3bd94dd25a4e0283b1` |
| seed pool objects | `2958981` |

R01/R02/G01/G02均完成seed/pool/local-FS return。R03失败后没有启动R04，而是按invalid分支清除G03 leaked objects，随后以`mode=abort-invalid-run`销毁formal seed。

archive中保留metadata dump、layout manifest和anchors，但最终pool回到pre-format附近，原seed对应的524288个Ceph数据对象已经删除。因此后续RUN可以复用布局**合同和校验参考**，不能只load该dump继续使用旧seed数据；必须在新RUN中重新创建一次immutable seed。

### 5.2 生产恢复与资源销毁

| 项 | 结果 |
|---|---|
| 三节点A1/B1 backing | 精确销毁，空间分别回`avail_pre±2 GiB` |
| 临时资源 | 无RUN mount、loop、tmpfs、PD/TiKV/JuiceFS/fio进程或state残留 |
| production PD/TiKV | 三节点active，stores连续三次3/3 Up |
| production TiKV mount | `/dev/nvme1n1` on `/mnt/jfs-tikv`，指纹不变 |
| Ceph | `HEALTH_OK` |
| 最终pool objects | `2434669`，相对pre-format `2434691`只差−22 |

---

## 6. 协议与脚本结论

03-22b把03-22暴露的生命周期问题系统性修复：每arm精确mkfs、fresh-FS baseline、role容量门、fio生命周期sampler、seed/pool/local reset和失败闭包均生效。R03因此是在**有效采集条件下测到不稳定**，不是脚本把环境事故误报为性能结果。

本RUN也暴露一个实验设计问题：当研究目标本身包含“能否降低CV”时，把CV阈值同时定义为证据有效门，会在控制臂真实不稳定时使整RUN失去因果回答能力。后续03-22c必须拆成：

1. 非性能证据有效门：覆盖、身份、健康、容量、内存、reset、无I/O错误；
2. 性能稳定端点：CV和`W4/W1`作为正式比较结果及部署验收门，而不是删掉完整arm的理由。

这不改变03-22b的预注册判定；03-22b仍严格保持`EVIDENCE_INVALID`。

---

## 7. 架构结论与下一步

1. **目标仍未达到。** 当前最好的正式PASS arm R01/A1为`3709.03 MiB/s`，仅达6250的59.34%，缺口`2540.97 MiB/s`。
2. **逻辑分离没有形成可签收收益。** 唯一已完成配对R02/R01为−1.55%，但矩阵无效，不能正式否证B1。
3. **CV直接机制已定位。** TiKV compaction与同步日志共享物理NVMe形成轮内软排队，是尾段深跌的直接触发层；不是hard stall。
4. **下一实验应做最小物理路径探针。** 03-22c用同RUN的B1c控制臂对比D1：KV仍在NVMe，只把WAL/Raft的32 GiB backing移到RAM。它同时移除logs设备服务时间和与KV共享NVMe的争用，不能等价为真实第二块NVMe。
5. **03-22b数据不能作为03-22c唯一分母。** 当前RUN无效且跨RUN存在状态漂移；03-22c必须同窗重测B1c，并补采NVMe SMART/温度与Ceph OSD秒级指标。

条件C（fresh TiKV直接使用原生共享NVMe ext4）仍是独立问题，用于拆nested-loop/native与历史状态；它不应塞入03-22c的B1c/D1最小差异矩阵。

## 8. 最终结论

03-22b的环境执行、失败闭包、生产恢复和归档均已完成，但正式A1/B1矩阵因R03稳定性门失败而无效。它没有回答“逻辑隔离是否提高带宽”，却可靠回答了“波动从哪里直接产生”：在256-inode randwrite下，TiKV轮内compaction持续建立并与WAL/Raft同步写共享同一物理NVMe，队列和同步延迟在后半程放大，形成深低谷并推高CV。

下一步不是补跑本RUN，也不是继续扫描inode、`max-uploads`或compaction worker；应由独立03-22c在同一新RUN内做B1c/D1配对，把logs物理路径从共享NVMe移除，并把稳定性作为正式端点而非证据删除条件。
