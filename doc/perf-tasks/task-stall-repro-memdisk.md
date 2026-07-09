# 任务（GLM）：stall 复现归因（净态 vs 连续负载）+ 内存盘独立 WAL/DB 对照

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-06
> 来源：`results/write-jfs-path-20260706/`（实验 A）经 opencode 逐文件对账后的下一步。
> 定位：**方向 1**。先坐实"multi-seqwrite 64G 到底在什么前置条件下才 stall"，再决定/验证内存盘隔离能否解决。
> 与 `task-write-jfs-path-deferred.md`（实验 A/B）的关系：本任务是实验 A 复盘后的**接续**，实验 A 的 SSD 侧（A2/A4）数据已判**作废**（见下 §0），deferred 端到端收益的重测放到本任务 stall 被控制住之后（§3）。

---

## 0. 背景：为什么要做这个任务（GLM 请先读）

opencode 已对账 `results/write-jfs-path-20260706/` 全部原始数据，结论：

### 可靠、可据此推进的
- **A3（JuiceFS HDD mu=150 multi-seqwrite 64G）的 stall 是真的、证据充分**：fio 原文跑 1479771ms（24.6min）仅 44.3 MiB/s；`A3/multi-health-timeline.txt` 810 行 stalled read，末尾停在 5/6 OSD WARN。
- **对象大小事实可靠**：JuiceFS 256K block 落成名为 `262144` 的 RADOS 对象（`A3/ops.log` 有 dd 探针）。

### 不可靠 / 超纲、本任务要修正的
1. **`stall-osd-perf.txt` 是单点快照**：`read_random_bytes`/`bytes_written_wal` 是 OSD 启动以来累计计数器，`op_w_latency avg` 是生命周期均值。A3 vs A4 两者 OSD 启动时刻不同（A4 前刚 cold restart），**累计值不可直接比**。故报告"deferred=0 减 WAL 5-7×"、"根因是 BlueFS 随机读饱和"均属**推断，未坐实**。→ 本任务必须采 **delta 或时间序列**。
2. **A4 SSD 端到端根本没测出稳态带宽**：`A4/multi-seqwrite-r1.txt` 只有 "Laying out IO file" 就被 stall 打断，无 fio summary。SSD 侧带宽结论（54.8、-3%）全部作废。
3. **A2/A4 全程在退化态**：A3 stall 后监控停在 WARN，SSD cold-restart（18:40:46）距 A2 开跑（18:43:57）仅 ~3min，OSD 未必恢复。SSD 四格 deferred 收益对比是拿脏数据比的，作废。
4. **A3 起跑线是否干净未被证明**：顶层 `ops.log` 那次 compact + HEALTH_OK **无时间戳**；A3 自己的 `ops.log` 开头只有 destroy/format/mount，**无 compact 记录**。A3 是紧接 A1 rados bench（17:47 结束）、中间只隔 ~3min、**未 compact / 未清 / 未空闲确认**就开跑的。

### 本任务要回答的核心问题
> **A3 的 stall 是"A3(mu=150 multi 64G) 本身就够触发"，还是"A1 rados 连续负载 + 未清状态"累积助燃触发的？**

这直接决定内存盘该怎么验、以及后续每格之间是否必须清状态。参照系：`17` 号任务净态基线（从干净态跑 layout 128G + multi-seqwrite 64G）**零 stall**——同样是 multi-seqwrite 64G，净态不 stall、本轮 stall，差异很可能就在"前面垫了 A1 且没清"。

---

## 1. 铁律（必须严格遵守；本任务重点是"起跑线"与"采样方式"）

1. 二进制 patched `/usr/local/bin/juicefs`（`juicefs --version` 含 `1.3.1+2025-12-02.e0032b2a`），开跑确认并落盘。
2. 冷态口径：挂载显式 `--cache-size 0`；**不传 `--max-readahead`**；不开 writeback、不加大 cache。JuiceFS 写测 mu=150 bs=256K `--end_fsync=1`。
3. **【本任务核心纪律 · 净态三确认】** 每个"净态起跑"的格子，开测前必须依次落盘证明:
   - ① **清集群数据**：删掉 juicefs 卷/测试对象，池空（`rados df` 落盘确认 `juicefs-data` 对象数≈0 或仅元数据）。
   - ② **compact 全部 OSD 到干净**：`compact` 后验 6 个 OSD 全部 `compact_queue_len=0` 且 `compact_running=0`（admin socket，见 §4）。落盘 compact 前后的值。
   - ③ **空闲确认**：`ceph health detail` = HEALTH_OK，且 `iostat -x 1` 观察 sdb 几秒确认 util≈0（无后台 I/O）。落盘。
   > compact 用 `skills/TESTING-GUIDE.md` §1.3/§3.2 方法。**不是 restart，不是只看 HEALTH_OK**。
4. **【本任务核心纪律 · 采样方式】** OSD perf **禁止用单点快照下结论**。必须：
   - 测前采一次"基线快照"（t0），测中每 3s 采一次时间序列，测后采一次（t_end）。
   - 关键计数器（`read_random_bytes`/`bytes_written_wal`/`bytes_written_sst`/`kv_sync_lat` 的 sum/count）报告时**给 delta（t_end − t0）或随时间曲线**，绝不拿累计裸值跨格比。
   - 采集脚本在 **OSD 节点本地前台循环**（不用 nohup 后台易丢），见 §4。
5. **只认 r1**；stall 场景 fio 可能被打断，如实记录是否跑完 / 被 abort。
6. 单 master 串行；后台 `setsid ... </dev/null >run.log 2>&1 & disown`，确认进 fio 再放手；杀 fio 等 `pgrep -x fio` 空再起下一格。
7. 密码 .11=`TurboAi@303`，.13/.14=`123456`。OSD 映射 node1(.11)=osd0,1 / node2(.13)=osd2,3 / node3(.14)=osd4,5；盘均为 sdb。
8. **一切结论必须有落盘原始数据对账；无数据支撑标"未取证/存疑"；不凭观察/记忆写结论；不取多轮 MAX；不跨目录拼旧数；不手填 summary。**
9. 改 OSD config / 动 OSD 磁盘（内存盘）后**务必回滚并落盘 `ops.log`**：记录默认值 → 改 → 测 → 复原 → 确认 HEALTH_OK + 所有 OSD up/in + 池数据完整性。**集群无业务数据，可有创，但全程详录 + 回滚。**

---

## 2. 阶段一：stall 归因对照（净态-单A3 vs 连续-A1→A3）

**目的**：分离"前序连续负载 + 未清状态"这个变量，判断 stall 到底是谁触发的。

### 两组对照（其余条件完全一致：JuiceFS HDD deferred=65536 mu=150 bs=256K）

| 组 | 前置状态 | 负载序列 | 想验证 |
|----|----|----|----|
| **G1 净态-单A3** | 净态三确认（清数据+compact+空闲，§1.3） | 直接 JuiceFS multi-seqwrite 16×4G=64G | 干净起跑线下，A3 本身是否触发 stall |
| **G2 连续-A1→A3** | 同样从净态三确认起跑，但 **A1→A3 之间不清、不 compact** | 先 rados bench 256K HDD 3×60s（复刻本轮 A1）→ 紧接 JuiceFS multi-seqwrite 64G（复刻本轮 A3 顺序与间隔） | 复现本轮，验证"前序负载 + 未清状态"是否为助燃剂 |

> G2 要尽量复刻本轮真实节奏：rados 3 轮结束后 ~3min 内开 JuiceFS，中间**不做**任何 compact/drop/清理。

### 每组采集（务必按 §1.4 采时间序列，不是单点）
- **health-timeline**：每 5s `ceph health detail`，全程覆盖（确认循环真跑满，别只跑 1 秒）。落盘 stall 起始/结束时刻、受影响 OSD 数、cooldown。
- **OSD perf 时间序列**：对**最可能 stall 的 OSD**（先全采一遍看哪些先告警，再聚焦 1-2 个；或直接 6 个都本地前台采，按节点分脚本），每 3s：`op_w_latency`、`subop_w_latency`、`bluestore.kv_sync_lat`、`bluestore.throttle_lat`、`bluefs.bytes_written_wal/sst`、`bluefs.read_random_bytes`、`rocksdb.compact_queue_len/compact_running`。测前测后各一次基线快照算 delta。
- **iostat sdb**：每 OSD 节点 `iostat -x 1`，看 stall 时 sdb 是否 %util≈100% + 读写双高、r_await 飙升。
- **fio 原文**：完整落盘（含 bw/clat/lat 分布/run time）；被 abort 也保留。

### 阶段一判据（给明确归属，附时间序列证据）
- **若 G1 净态-单A3 也 stall** → A3(mu=150 multi 64G) 本身即可触发，与前序负载无关。→ 直接进阶段二内存盘对照。
- **若 G1 不 stall、G2 才 stall** → 证明 stall = **连续负载 + 未清状态累积**触发。→ 说明：(a) 内存盘该在 **G2 连续场景**下验才有意义；(b) "每格之间清状态"是必需的操作纪律（写回 TESTING-GUIDE）。
- **无论哪种**，用时间序列 delta 判定 stall 时刻是否对齐：`read_random_bytes` 暴涨 + `kv_sync_lat`/`op_w_latency` 飙升 + iostat sdb 读高 util 满。**据此坐实/否定"根因=BlueFS 随机读在共享 SSD 上与数据写争抢"**（把上轮的单点推断升为定量结论，或推翻）。
- **同时校验 `compact_queue_len`**：全程是否始终为 0（若是，则确证此 stall ≠ compaction 积压，与上轮 P4 修正一致）；若非 0，记录堆积曲线。

---

## 3. 阶段二：内存盘独立 WAL/DB 对照（视阶段一结论决定在哪个场景验）

**前提**：阶段一已确认能稳定复现 stall（且知道在 G1 还是 G2 场景）。

### 做法
1. **在能复现 stall 的那个场景（G1 或 G2）下，先复测一次作为"共享 SSD 基线"**（已在阶段一拿到，直接引用即可，不必重跑）。
2. **给 OSD 加内存盘作为独立 WAL/DB**（三台 OSD 节点各 251G 内存，可用 215-229G，足够）：
   - 用 tmpfs/ramdisk 创建内存块设备，把 BlueFS WAL+DB 迁到内存盘（当前 `bluefs_single_shared_device=1`，WAL/DB/Data 同在 sdb）。
   - deepseek exp4 曾卡在容器路径（`ceph-bluestore-tool` 在 cephadm shell 内找不到 osd block）——本任务用 `cephadm shell --name osd.X` 挂设备重试，或用 `ceph-volume` / OSD 重建方式；**详录每一步命令与返回码到 ops.log**。
   - 逐台做，每台做完确认 OSD up/in、HEALTH_OK 再做下一台。
3. **同一场景、同一净态三确认起跑，重跑 multi-seqwrite 64G**，对比是否还 stall、带宽是否恢复。
4. **回滚**：测完把 WAL/DB 迁回 sdb（或按记录复原 OSD），确认集群 HEALTH_OK、6 OSD 全 up/in、池数据完整。

### 阶段二判据
- 内存盘后 **stall 消失 + multi-seqwrite 带宽显著回升** → **坐实 WAL/DB 隔离是解决此 stall 的手段**（P5 从"可选优化"回升为"对 mu=150 高并发写必要"，但须注明这是内存盘定性证明，NVMe 收益需另测/保守表述）。
- 内存盘后 **仍 stall** → WAL/DB 隔离不是充分手段，回到"每格之间清状态 + 降 mu/并发"的运行纪律路线；如实记录，不硬凑结论。
- ⚠️ **口径提醒**：内存盘远快于任何 NVMe，**只能定性证明"隔离 WAL/DB 有效"，不能定量预测生产 NVMe 的收益**。报告务必标注此局限，禁止用内存盘数据向"必须上 NVMe"做定量背书。

---

## 4. OSD perf / compact 采集参考（修上两轮采集失败的坑）

deepseek exp3 与 GLM 上轮的 timeline 均失败（nohup 远端循环不工作 / cephadm shell 太慢 / 只跑 1 秒 / 只有单点快照）。本任务统一用 **OSD 节点本地前台循环 + admin socket 直采**：

```bash
# 在 OSD 所在节点本地执行；输出重定向到本地文件，跑完 scp 回 master
FSID=$(sudo ceph fsid)
for X in <本节点的两个osd编号>; do :; done   # 例 node1: 0 1
ASOK="/var/run/ceph/${FSID}/ceph-osd.<X>.asok"
END=$(( $(date +%s) + <覆盖整段测试的秒数, 留足余量> ))
while [ $(date +%s) -lt $END ]; do
  echo "=== $(date +%s) $(date) ===" >> osd<X>-perf-timeline.txt
  sudo ceph --admin-daemon "$ASOK" perf dump >> osd<X>-perf-timeline.txt 2>&1
  sleep 3
done
```

- compact 单台：`sudo ceph --admin-daemon "$ASOK" compact`；验证：`perf dump` 里 `rocksdb.compact_queue_len` / `compact_running`。
- **测前测后各存一份完整 perf dump 作 t0/t_end 基线**，报告给 delta。
- health-timeline：master 侧 `while ...; do date; ceph health detail; sleep 5; done`，确认跑满全程。

---

## 5. 回报 opencode（最终一条消息）

1. **阶段一结论**：G1 净态-单A3 是否 stall？G2 连续-A1→A3 是否 stall？→ **stall 的真正触发条件**（本身足够 / 需前序连续负载+未清状态）。附时间序列 delta 证据坐实/否定"根因=BlueFS 随机读争抢"，以及 `compact_queue_len` 是否始终为 0。
2. **阶段二结论**：内存盘独立 WAL/DB 后，stall 是否消失、带宽是否回升 → WAL/DB 隔离是否为解决手段（附内存盘只能定性的局限说明）。
3. 明确回答：后续实验 A（deferred 端到端收益重测）该在哪个净态/隔离条件下重跑才干净（供下一任务书用）。
4. 任何异常（config/内存盘未回滚、版本不符、采集失败、fio 被 abort）如实列。
5. 不擅自改验收口径；无数据支撑标"未取证"。

---

## 6. 明确不做
- ❌ 不重跑 14 扫 mu/buffer；不测读类/randrw（本任务只做 stall 复现归因 + 内存盘对照）。
- ❌ **不拿单点 perf 快照的累计计数器跨格比较下结论**（必须 delta / 时间序列）。
- ❌ **不在退化态 OSD 上采带宽结论**（每格净态三确认起跑）。
- ❌ 不用内存盘数据向"必须上 NVMe"做定量背书（只定性）。
- ❌ 改 config / 动 OSD 磁盘后不回滚（务必回滚，`ops.log` 留痕）。
- ❌ 不把没落盘的观察写进结论。
