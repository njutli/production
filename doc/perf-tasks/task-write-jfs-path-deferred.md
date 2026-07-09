# 任务（GLM）：写侧根因 —— 查 JuiceFS 吞噬 deferred 收益 + 补 compaction 反压定量

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-06
> 来源：`doc/perf-analysis/11_1-step2-stall-compaction-branch.md` 待办 A + 待办 B（步骤 2 写侧冲线的根因分支）。
> 定位：**不重跑 14 的扫参数**（已证明写类瓶颈不在 mu/buffer）。本任务一次测到位三件事：
> ① 验证/固化 stall 分析（干净起跑线定义）；② **查 JuiceFS 写路径为何吃掉后端 deferred 的 +23% 收益（核心，待办 A）**；③ **补 compaction 反压 perf 定量时间线（待办 B）**。

---

## 0. 背景与已定论（GLM 请先读，避免重复劳动）

已由 GLM 上一轮（`results/cold-baseline-recheck-20260706/`）坐实、本任务不再重测：
- **stall 触发条件 = 单流持续写 + OSD 已有 compaction 积压（`compact_queue_len>0`）**；干净态 128G 多 job 零 stall；`compact` 命令秒级清积压，**restart OSD 不清磁盘 LSM 积压**。
- **过去冷态基线数据可信**，不必作废。
- **rados 直打 EC 池**：`bluestore_prefer_deferred_size=0`(SSD 行为) vs `=65536`(HDD 误判) → **后端 +23%**（256K 均值 72.3 vs 58.6，高性能窗口 18s vs 7s）。原始：`results/cold-baseline-recheck-20260706/rados-deferred-comparison/`。
- **但经 JuiceFS 端到端（P6 32G 单job）改同参数无收益甚至略慢**；且 JuiceFS multi-seqwrite 40.8 明显低于 rados 256K 裸能力 52.7（**约 -23% JuiceFS 层损耗**）。

**核心谜题（待办 A）**：后端明明有 +23% 空间，为什么经 JuiceFS 写路径就没了？JuiceFS 在哪一环吃掉了后端收益？**这可能才是写侧真实的软件瓶颈。**

---

## 1. 铁律（沿用 14/15/16/17，本任务同样严格）

1. 二进制 patched `/usr/local/bin/juicefs`（`juicefs --version` 须含 `1.3.1+2025-12-02.e0032b2a`），开跑确认并落盘。
2. 冷态口径：挂载显式 `--cache-size 0`；**不传 `--max-readahead`**；不开 writeback、不加大 cache。
3. **干净起跑线（本任务核心纪律）**：每格开测前**必须 `compact` 到全部 OSD `compact_queue_len=0` 且 `compact_running=0`**（不是 restart，不是只看 HEALTH_OK）。用 `skills/TESTING-GUIDE.md` §1.3/§3.2 的 admin socket 方法。把 compact 前后的 `compact_queue_len` 落盘，证明起跑线干净。
4. **只认 r1**；但每格跑 3 轮看方差（写类在此环境方差大，单次不足判定）。
5. 单 master 串行；后台 `setsid ... </dev/null >run.log 2>&1 & disown`，确认进 fio 再放手；杀 fio 等 `pgrep -x fio` 空。
6. 密码 .11=`TurboAi@303`，.13/.14=`123456`。OSD 映射 node1(.11)=osd0,1 / node2(.13)=osd2,3 / node3(.14)=osd4,5。
7. **一切结论必须有落盘原始数据对账；无数据支撑标"未取证/存疑"；不凭观察/记忆写结论；不取多轮 MAX；不跨目录拼旧数；不手填 summary。**
8. 改 OSD config（deferred/throttle）后**务必回滚**（记录默认值 → `ceph config rm osd <param>` → 重启 OSD → 确认 HEALTH_OK），全程落盘 `ops.log`。

---

## 2. 实验 A（核心）：定位 JuiceFS 吞噬 deferred 收益的环节

### 设计：后端与 JuiceFS 分层对照，同参数改动看两层各自反应
四组测试，每组同时采**后端侧**（rados/OSD perf/iostat）与 **JuiceFS 侧**（juicefs stats/系统资源），定位收益消失在哪一层：

| 组 | 路径 | deferred_size | 目的 |
|----|----|:---:|----|
| A1 | rados 直打池 256K | 65536 (HDD) | 后端基线（复现 58.6）|
| A2 | rados 直打池 256K | 0 (SSD) | 后端优化（复现 72.3，确认 +23% 可重现）|
| A3 | JuiceFS seqwrite/multi-seqwrite 256K | 65536 (HDD) | 端到端基线 |
| A4 | JuiceFS seqwrite/multi-seqwrite 256K | 0 (SSD) | 端到端优化（看 +23% 是否传导上来）|

- rados：`rados bench -p juicefs-data 60 write -b 256K -t 16`（对齐上轮口径，可重现 58.6/72.3）。
- JuiceFS：seqwrite（单job 4G）+ multi-seqwrite（16job×4G=64G），bs=256K，`--end_fsync=1`，冷态 mu=150。
- **每组 3 轮**，改 deferred 后重启相关 OSD 使生效，起跑前 `compact` 到干净。

### 关键采集（回答"收益在哪消失"）
1. **JuiceFS 侧写路径可观测**（A3/A4 运行期同跑）：
   - `juicefs stats <挂载点> -l 1 --interval 1 --count <runtime+5> > jfs-stats-<组>.txt`（看 object put 并发、fuse 写、buffer、blockcache 等分段）。
   - 采 juicefs 进程 CPU/内存（`top -b`/`pidstat`），看是否 JuiceFS 自身成为瓶颈。
2. **后端 OSD perf**（所有组运行期，admin socket 直采，见 §3）：`op_w_latency`、`subop_w_latency`、`bluestore.kv_sync_lat`、`bluestore.throttle_lat`、`bluefs.bytes_written_wal/sst`、`bluefs.read_random_bytes`、`rocksdb.compact*`。
3. **iostat sdb**：每 OSD 节点 `iostat -x 1`，看 deferred=0 后 sdb 写量/util 是否下降（deferred 双写减少的直接证据）。
4. **NIC TX/RX**：每组记录，写测看 TX。

### 判据（务必给出明确归属）
- 若 **A4 端到端也涨 ~23%**（之前 P6 无收益是 32G 场景/方差所致）→ deferred=0 端到端有效，**可考虑纳入基线**（回报 opencode 决策）。
- 若 **A2 后端涨但 A4 端到端不涨** → 收益被 JuiceFS 层吞掉。用 juicefs stats + OSD perf 对比定位：
  - JuiceFS 写是否根本没触发后端 deferred 路径（如 JuiceFS 攒成 4M object 写，chunk 已 >64K deferred 阈值，改 deferred 对它无意义）？
  - 还是 JuiceFS 层（object 合并/上传并发 mu/fuse 写回/librados 提交）本身的开销 >> 后端节省？
  - **量化 JuiceFS 层损耗**：`(rados 256K 均值 − JuiceFS multi-seqwrite) / rados 256K 均值`，并指出损耗发生在 stats 的哪一段。
- **产出**：`results/write-jfs-path-20260706/expA/`，含四组 fio/rados 原始 + jfs-stats + OSD perf + iostat + ops.log（config 改动/回滚）+ 一张"后端 vs 端到端 收益对照表" + **收益消失环节的定位结论**。

> ⚠️ 关键洞察方向（供参考，不预设结论）：JuiceFS 默认把写攒成 block-size（我们是 256K）大小的 object 上传。若 JuiceFS 实际写到 RADOS 的对象 ≥ 64K，则**根本不命中 HDD deferred 阈值（65536）**，那 deferred 参数对 JuiceFS 路径本就无影响——这能解释"后端 rados 256K 命中 deferred 有收益，JuiceFS 不命中所以无收益"。**请用实际写到池的对象大小分布（rados ls / 对象 stat / juicefs stats object put 大小）验证或推翻这一点。** 这是本任务最可能的破案点。

---

## 3. 实验 B：补 compaction 反压 perf 定量时间线（待办 B）

### 修上两轮采集失败的坑
deepseek exp3 与 GLM task A 的 OSD perf timeline 均失败（nohup 远端循环不工作 / cephadm shell 太慢）。**本任务用 OSD 节点本地前台可控脚本 + admin socket 直采**：

```bash
# 在触发 stall 的 OSD 所在节点本地执行（sshpass 起，但脚本本身在节点上前台循环，输出重定向到本地文件）
FSID=$(sudo ceph fsid)
ASOK="/var/run/ceph/${FSID}/ceph-osd.<X>.asok"
END=$(( $(date +%s) + 400 ))
while [ $(date +%s) -lt $END ]; do
  echo "=== $(date +%s) $(date) ===" >> osd<X>-perf-timeline.txt
  sudo ceph --admin-daemon "$ASOK" perf dump >> osd<X>-perf-timeline.txt 2>&1
  sleep 3
done
```

- **先制造一个会 stall 的场景**：从**已有 compaction 积压**的 OSD 起（或先跑一轮大写入制造积压、不 compact），再单 job 持续写 64G，触发 stall。
- 运行期只盯**触发 stall 的 1-2 个 OSD**（别 6 个全采），每 3s 一次。
- 同步采 `iostat -x 1` sdb + health-timeline（每 5s `ceph health detail`，确认循环真跑满全程，别再只跑 1 秒）。

### 判据（把 P4 从"方向对"升为"定量坐实"）
stall 出现时刻是否对齐：`rocksdb.compact_queue_len` 堆积 + `bluestore.kv_sync_lat` 飙升 + `bluefs.read_random_bytes` 暴涨 + iostat sdb `%util`≈100% 且读写双高。
- **产出**：`results/write-jfs-path-20260706/expB/`，含 osd perf timeline + iostat + health-timeline + 关键字段随时间表 + "stall=compaction反压"的定量判决（✅坐实/❌否则）。

---

## 4. 回报 opencode（最终一条消息）
1. **实验 A**：deferred=0 端到端到底有没有 +23% 收益？若没有，**收益消失在哪一环**（附对象大小分布 / juicefs stats / OSD perf 证据）→ 写侧真实软件瓶颈定位；是否建议纳入基线。
2. **实验 B**：compaction 反压的 perf 定量时间线是否坐实 P4。
3. JuiceFS 层损耗量化（rados 裸能力 vs JuiceFS 端到端差多少、差在哪）。
4. 任何异常（config 未回滚、版本不符、采集失败）如实列。
5. 不擅自改验收口径；无数据支撑标"未取证"。

## 5. 明确不做
- ❌ 不重跑 14 扫 mu/buffer；不测读类/randrw（本任务只写侧根因）。
- ❌ 不开 writeback、不加大 cache、不传 `--max-readahead`。
- ❌ 改 config / 动 OSD 后不回滚（务必回滚，`ops.log` 留痕）。
- ❌ 不把没落盘的观察写进结论。
