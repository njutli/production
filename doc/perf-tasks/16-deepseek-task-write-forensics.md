# 16 执行任务（deepseek）：写侧根因取证 —— 后端裸能力 / layout 悖论 / compaction / 磁盘介质误判 / 内存盘对照

> 出题：opencode（规划/校验）　执行：deepseek　日期：2026-07-05（周末，做扎实，重取证不重跑量）
> 依据：`results/write-push-retest-20260705/STATUS.md` 复盘 + 用户六点质疑。
> **本轮不是继续扫参数，而是给几个"猜想"逐条取证或推翻。** 上一轮把"几十G连续写必触发 stall / 写侧被硬件封死 / 必须加硬件"当结论下早了——这些都还没有定量证据。本轮目标：拿到能定案、能向领导要预算的**硬证据链**。

---

## 0. 本轮要回答/推翻的具体命题（每条都要有落盘原始数据判决）

| 编号 | 命题（deepseek/opencode 之前的说法） | 现状 | 本轮判决实验 |
|----|----|----|----|
| P1 | "几十G连续写必触发 RocksDB compaction/BlueFS stall" | **未证实**（128G layout 当年没报 stall，是反例，从没解释） | 实验1（阶梯写入找真实门槛）|
| P2 | "过去的顺序写/layout 数据可能被 compaction 污染、不准" | **未查**（当年从没在 layout 期间采后端状态） | 实验1（layout 式写入复现 + 全程采后端）|
| P3 | "写侧被硬件封死，参数不可解，稳态只有 40-43" | **证据不足**（从没直接测过后端裸顺序写能力） | 实验2（rados/fio 直打池测裸能力）|
| P4 | "stall 根因 = compaction 反压（前台写 > compaction 消化）" | **只有 health 文本，无 perf 定量** | 实验3（OSD perf 时间线坐实）|
| P5 | "WAL/DB 与 Data 同盘是瓶颈" | **拓扑已初步确认同盘（single_shared_device=1）** | 实验4（内存盘独立 WAL/DB 对照）|
| P6 | "盘是 SSD" vs "Ceph 认成 HDD" | **opencode 已查实：物理 SSD（randread 6542 IOPS/151us），但 Ceph 里 rotational=1/type=hdd（RAID 卡 PERC H730 误判）** | 实验5（介质误判影响 + 可能的免硬件解法）|

> ⚠️ **铁律（重复上轮，本轮更严）**：任何 stall / OSD 身份 / compaction 判断，**必须有落盘的原始文件能对账**（`ceph health detail` 全文、`ceph daemon osd.X perf dump` 全文、iostat 全文）。上一轮 STATUS.md 里"osd.0/osd.2 stalled"因脚本 abort 没写 backend-after → 无据，本轮此类禁止。**凭观察/记忆写进结论 = 数据作废。**

---

## 1. 环境关键事实（opencode 已查，deepseek 据此执行，勿推翻）

- **盘**：每节点 `sdb` 953G 挂在 **PERC H730 Mini RAID 卡**后；`lsblk ROTA=1`、Ceph `rotational=1/bluestore_bdev_type=hdd` —— **但物理实测是 SSD**（裸设备 randread 4K：IOPS=6542、avg lat=151us、99.88%<250us）。**结论：物理 SSD，Ceph 因 RAID 卡不透传介质而误判为 HDD。**
- **BlueStore 拓扑**：`bluefs_single_shared_device=1`、`bluefs_dedicated_db=0`、`bluefs_dedicated_wal=0` → WAL/DB/Data **全在同一 `sdb`**。
- OSD 映射：node1(.11)=osd0,1；node2(.13)=osd2,3；node3(.14)=osd4,5。
- 内存充足：三台 OSD 节点各 251G，可用 215-229G → **内存盘做临时独立 WAL/DB 对照可行**（实验4）。
- 二进制：patched `/usr/local/bin/juicefs`（`1.3.1+2025-12-02.e0032b2a`），挂载 `--cache-size 0`、不传 `--max-readahead`。
- 密码：.11=`TurboAi@303`，.13/.14=`123456`（照仓库明文写法）。
- OSD perf 采集：`sudo cephadm shell -- ceph daemon osd.X perf dump`（容器化，须在 fio 运行窗口内采）。
- **无业务数据**：集群无任何业务部署，全是测试数据，**实验4 允许有创操作（迁移/破坏单个 OSD），无需额外批准**，但**必须全程详录操作步骤 + 保留关键原始日志**（见实验4）。

---

## 2. 通用工具（每个实验复用）

- **后端状态快照** `snapshot_backend <file_prefix>`：`ceph health detail` + `ceph -s` + `ceph osd perf` + `ceph df detail` + `ceph osd df`，全文落盘。
- **后端 perf 时间线** `perf_timeline_start <outdir> <interval>`：后台起一个循环，每 `interval` 秒对 6 个 OSD 采 `ceph daemon osd.X perf dump` 全文 + `ceph health detail`，**带时间戳**追加到 `<outdir>/osd<X>-perf-timeline.txt` 和 `<outdir>/health-timeline.txt`。fio 结束后停。
- **节点磁盘忙碌** `iostat_start <ip> <outdir>`：在 OSD 节点后台 `iostat -x 1` 落盘（看 sdb %util、r/s+w/s、await）。
- **起跑线判据**：每格开测前 `ceph health`=OK 且 `ceph osd perf` commit latency 回落 idle；**若上一格留下 stall，restart 受影响 OSD 等 HEALTH_OK 再开**（把等待/restart 过程落盘）。

---

## 3. 实验 1（最高优先）：阶梯写入找 stall 真实门槛 + 复现 layout 悖论（判 P1/P2）

**目的**：回答"到底写多少、什么写法才触发 stall？128G layout 式写入触不触发？过去数据准不准？"

**设计**：冷态 mu=150。从干净态起（restart OSD → HEALTH_OK → drop cache），**单调递增单次连续写入量**，每档全程开 `perf_timeline` + `iostat`，记录该档是否出现 stall / 何时出现 / 哪个 OSD / 带宽是否掉：

| 档 | 写入方式 | 总量 | 观察 |
|----|----|----|----|
| S1 | fio 顺序写 单job | 8G | 是否 stall？带宽？ |
| S2 | fio 顺序写 单job | 32G | ↑ |
| S3 | fio 顺序写 单job | 64G | ↑（对齐上轮 B1-nj1=41.5+stall）|
| S4 | fio 顺序写 单job | 128G | ↑ |
| **S5** | **复现 layout 写法**：128 job × 1G（与历史 layout step8 完全同口径） | 128G | **关键**：这就是"当年 layout"的写法，看它到底触不触发 stall |

- 每档之间 **restart 受影响 OSD 回到干净态**再跑下一档（分离各档，不让前档余波污染）。
- **判 P1**：找到 stall 的真实触发门槛（是"累计量"还是"持续写时长"还是"某并发度"）。
- **判 P2（layout 悖论核心）**：S5 用历史 layout 的确切写法（128job×1G，默认参数）。
  - 若 S5 **也触发 stall/退化** → 说明**当年 layout 其实也退化了，只是从没采过后端状态所以没发现** → 过去顺序写/layout 数据可信度存疑，需重测；
  - 若 S5 **不触发**而 S3/S4 单job大写触发 → 说明触发条件不是"总量"而是**写模式差异**（如单流持续 vs 多流分散、fresh 卷 vs 已满卷、是否 end_fsync），**"几十G必触发"这个说法就是错的**，要改写。
- **产出**：`results/write-forensics-20260705/exp1-threshold/`，含各档 fio + perf-timeline + iostat + health-timeline + 一张"写入量/写法 → 是否 stall / 触发时刻 / 带宽"表 + P1/P2 判决。

---

## 4. 实验 2：后端裸顺序写能力（判 P3，回答用户"后端裸能力顺序写到底能到多少"）

**目的**：绕开 JuiceFS，直接对 Ceph 池测顺序写裸能力。若裸能力 >>59 而 JuiceFS 只有 40-43 → 瓶颈在 JuiceFS 层不是硬件，"写侧判死刑"就是错的。

**设计**：
1. `rados bench -p juicefs-data <sec> write -b 4M -t 16`（EC 4+2 池，注意 rados bench 会算进 EC 放大）；再测 `-b 256K` 一档对齐 JuiceFS 对象口径。
2. 全程 `perf_timeline` + `iostat`，看裸写是否也触发 stall、在多大吞吐/多少量时触发。
3. 记录 `Bandwidth (MB/sec)`、`Max latency`、cur MB/s 时间线（看是否也有 stall 式塌陷）。
- **判 P3**：
  - 裸能力（去 EC 放大后的有效值）明显 >59 → 写侧瓶颈不在后端硬件裸吞吐，"判死刑"推翻，回头查 JuiceFS 写路径；
  - 裸能力本身就卡在 ~40-50 且同样 stall → 确认后端受限，与实验1/3/4 合并成"硬件/配置"证据链。
- **产出**：`exp2-backend-raw/`，含 rados bench 原始输出 + perf/iostat + 裸能力结论（注明 EC 放大换算）。

---

## 5. 实验 3：compaction 反压定量取证（判 P4）

**目的**：把"stall = compaction 反压"从 health 文本升级为 perf 定量证据。

**设计**：在实验1 必触发 stall 的那一档（如 S3 64G）运行期间，`perf_timeline` 间隔调密（5-10s），事后从 timeline 里提取并画出随时间变化：
- RocksDB：`rocksdb_compact*`、`compact_queue_len`（**堆积=反压核心证据**）、`submit_latency`、`get_latency`；
- BlueStore：`kv_sync_lat`、`kv_commit_lat`、`state_kv_queued_lat`、`throttle_lat`（**飙升=前台被反压**）；
- BlueFS：`read_random_*`、`bytes_written_sst/wal`（**read_random 暴涨 = stalled read**）；
- OSD：`op_w_latency`、`subop_w_latency`。
- iostat sdb：`%util` 是否 100%、读写是否同时高（compaction 读 + 数据写抢盘）。
- **判 P4**：若 stall 时刻对齐 `compact_queue_len` 堆积 + `kv_sync_lat` 飙升 + `bluefs read_random` 暴涨 + sdb %util 打满且读写双高 → **compaction 反压 + 单盘争抢**坐实。
- **产出**：`exp3-compaction/`，含加密采样的 timeline + 关键字段随时间表 + 判决。

---

## 6. 实验 4（有创，无需批准，但必须详录）：内存盘独立 WAL/DB 对照（判 P5，最有说服力的"隔离元数据IO"证据）

> 用户明确：集群无业务数据，可有创；**要求全程详录操作步骤 + 保留关键原始日志**。

**目的**：把 osd.5 的 WAL/DB 从共享 sdb 迁到内存盘（tmpfs），其余不变，重跑触发档，看**osd.5 的 stall 是否消失 / perf 是否改善**。若消失 → **铁证"瓶颈在 WAL/DB 与 Data 争抢同盘"**，即"隔离元数据IO（独立 NVMe）可解"。

**⚠️ 口径警告（必须写进结论）**：tmpfs 远快于任何 NVMe（内存带宽~10GB/s、零寻道）。**本实验只能定性证明"隔离 WAL/DB 有效"，不能拿 tmpfs 的数字预测 NVMe 的实际收益**。报告写"独立 WAL/DB 设备可消除此瓶颈（内存盘对照证明），实际收益取决于所选 NVMe 规格"。

**操作（只动 osd.5，node3=.14；EC 4+2 容 2 故障，单 OSD 安全；全程每步落盘到 `exp4-memdb/ops.log`）**：
1. **前置取证**：`snapshot_backend`、`ceph osd metadata osd.5`、`ceph-volume lvm list`（若容器报错见下）、记录当前 `ceph -s`。
2. node3 建 tmpfs：`mkdir -p /mnt/osd5-memdb && mount -t tmpfs -o size=20G tmpfs /mnt/osd5-memdb`（DB 大小按当前 db_used 估，留余量；落盘 `df -h`）。
3. `ceph osd set noout`（防迁移期误判 out）。
4. 停 osd.5：`ceph orch daemon stop osd.5`（或 `systemctl` 对应 unit，记录用的确切命令）。
5. 迁移 DB 到内存盘：用 `cephadm shell` 内 `ceph-bluestore-tool bluefs-bdev-new-db --path /var/lib/ceph/osd/ceph-5 --dev-target <memdb设备>`（**确切命令以 osd.5 实际路径为准，先 `--command bluefs-bdev-sizes` 看现状，每步 stdout 全落盘**）。
6. 启 osd.5，`ceph -s` 等回 `HEALTH_OK`/osd.5 up。
7. **重跑实验1 的触发档（S3 64G）**，全程 `perf_timeline` 只关注 osd.5，对比 osd.5 stall 是否消失、`bluefs read_random`/`kv_sync_lat` 是否回落、带宽是否改善。同时看仍在共享盘的 osd.4 是否照旧 stall（同节点对照）。
8. **回滚**：`ceph osd unset noout`；把 DB 迁回或直接 **销毁重建 osd.5**（无业务数据，重建最干净）：记录 `ceph orch osd rm 5 --replace --zap` → 等重建 → `HEALTH_OK`。回滚每步落盘。
- **判 P5**：osd.5（内存DB）不再 stall / perf 显著改善，而 osd.4（共享盘）照旧 → **隔离 WAL/DB 有效，坐实"必须独立 DB 设备"方向**。
- **产出**：`exp4-memdb/`，含 `ops.log`（逐命令 + stdout）、迁移前后 metadata、S3 重跑的 fio + osd.5/osd.4 perf 对比、回滚日志。

> `ceph-volume lvm list` 上轮容器报 `unsupported shim version` → 改用 `ceph osd metadata osd.X` + node 上 `lsblk`/`dmsetup ls` 拿设备关系，别卡在这个命令上。

---

## 7. 实验 5（低成本，配置侧）：SSD 被误判为 HDD 的影响 + 免硬件解法探路（判 P6）

**目的**：物理 SSD 被 Ceph 当 HDD → BlueStore 用 HDD 保守策略（cache/compaction/min_alloc 等）。这可能是**不加硬件、改配置就能缓解**的方向，性价比最高，值得先探。

**设计（只读/低风险优先）**：
1. 取证当前因误判导致的差异化配置：`ceph config show osd.5 | grep -iE "hdd|ssd|bluestore_cache|compaction|min_alloc"`，`ceph config get osd bluestore_cache_size_hdd/ssd` 等，落盘。
2. **探路（可选，谨慎）**：在 osd.5 上试 `ceph config set osd.5 bluestore_cache_size <按SSD档调大>` 或相关 SSD 向参数（**只改 osd.5 做对照，记录默认值以便回滚**），重跑触发档看是否缓解。**不确定的参数先只读取证、列出候选，不乱改**；要改先在 ops.log 记默认值。
- **产出**：`exp5-media-misjudge/`，含 config 取证 + 候选可调参数清单 + （若试）osd.5 调参前后对比 + 结论"改配置能否缓解 / 多大程度"。

---

## 8. 执行顺序与依赖

1. **实验 1（阶梯+layout悖论）先跑** —— 它直接判 P1/P2，且 S3/S5 为实验3/4 提供"必触发档"。
2. **实验 2（裸能力）** 可与实验1 并行思路但仍串行执行（单 master 串行），判 P3。
3. **实验 3（compaction 定量）** 复用实验1 的触发档采密集 perf。
4. **实验 5（介质误判/配置）** 低成本先探——**若实验5 改配置就大幅缓解，实验4 加硬件的必要性就下降**，所以实验5 值得在实验4 之前出个初步结论。
5. **实验 4（内存盘对照）** 最后做（有创），拿最硬的"隔离WAL/DB有效"证据。

> 串行、后台起（`setsid ... </dev/null >run.log 2>&1 & disown`，确认进 fio 再放手）；杀 fio 等 `pgrep -x fio` 空再起下一个。每格前确认起跑线干净。

---

## 9. 回报 opencode（最终一条消息）

对 §0 的 **P1-P6 逐条给判决**（✅证实/❌推翻/⚠️存疑 + 原始数据出处），特别是：
1. **P1/P2**：stall 真实触发门槛 + 写法；layout 式写入(S5)到底触不触发 → 过去数据准不准的结论。
2. **P3**：后端裸顺序写能力数字（去EC放大）→ 写侧到底是不是硬件封死。
3. **P4**：compaction 反压的 perf 定量证据。
4. **P5**：内存盘独立 WAL/DB 后 osd.5 stall 是否消失（隔离元数据IO 是否有效）。
5. **P6**：SSD 被误判 HDD 的影响 + 改配置能否免硬件缓解。
6. 汇总成"要不要向领导要 NVMe 预算"的证据链现状（哪些齐了、哪些还缺）。
- **不自行改验收口径、不凭记忆写结论、无数据支撑一律标"未取证"。**

---

## 10. 明确不做

- ❌ 不继续盲扫 mu/buffer（上轮已知参数不是主杠杆）。
- ❌ 不测读类/randrw（本轮只写侧根因）。
- ❌ 不开 writeback、不加大 cache、不传 `--max-readahead`。
- ❌ 不把没落盘的观察写进结论；不取多轮 MAX；不跨目录拼旧数。
- ❌ 实验4 回滚务必做完（unset noout + 重建/迁回 osd.5），不留残状态。
