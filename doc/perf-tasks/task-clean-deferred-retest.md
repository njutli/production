# 任务（GLM）：干净态 HDD/SSD deferred 对比重测（为"JuiceFS 吞噬 deferred 收益"提供可靠对比基线）

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-07
> 来源：`doc/perf-analysis/11_1-step2-stall-compaction-branch.md` 待办 A 的**前置卡点**。
> 定位：核心目标是"查 JuiceFS 为何吃掉 deferred 的后端 +23% 收益"，前提是有**可靠的干净态 HDD/SSD 对比数据**。此前两轮（`write-jfs-path-20260706`、`stall-repro-memdisk-20260706`）的 SSD 侧数据**全部作废**——都在 OSD 退化态（HEALTH_WARN + degraded pgs）就开测。**本任务只干一件事：在干净态下拿到可靠的 HDD vs SSD 对比，后端 + JuiceFS 端到端同时采。**

---

## 0. 为什么必须重测（GLM 请先读）

前两轮 SSD 侧全部踩同一个坑：**改 `deferred_size`/`throttle` 后重启 OSD → 集群进入退化态（`HEALTH_WARN slow ops` + `Degraded data redundancy: N pgs degraded`）→ 没等恢复就开测**。证据：
- `stall-repro-memdisk-20260706/A1-A4-retest/ops.log`：切 SSD 后 health = `HEALTH_WARN ... 29 pgs degraded` 就开测，A2 rados 仅 **27.6 MB/s**（干净态应 ~72）。
- `write-jfs-path-20260706`：A2/A4 在 A3 stall 后退化态跑，同样作废。

**唯一已知的干净态可靠数据点**：`cold-baseline-recheck-20260706/rados-deferred-comparison/` 测得 rados 直打池 SSD 72.3 vs HDD 58.6 = **+23%**。本任务要在**同等干净态**下把 HDD/SSD 的 **rados 后端 + JuiceFS 端到端**四组都测干净，形成可对比的完整矩阵。

---

## 1. 铁律

1. 二进制 patched `/usr/local/bin/juicefs`（`juicefs --version` 含 `1.3.1+2025-12-02.e0032b2a`），开跑确认并落盘。
2. 冷态口径：JuiceFS 挂载显式 `--cache-size 0`；**不传 `--max-readahead`**；不开 writeback、不加大 cache。写测 mu=150 bs=256K `--end_fsync=1`。
3. **【本任务最高纪律 · 两级干净起跑线】** 分两种情形，都要逐条落盘确认（见 `skills/TESTING-GUIDE.md` §5.4）：

   **(a) 每组（A1/A2/A3/A4）开测前，一律做「净态三确认」**（保证组间横向可比、无残余状态污染）：
   - ① **清池数据**：destroy JuiceFS 卷后，**还要显式清 `juicefs-data` 池里 rados bench 灌进去的对象**（destroy 卷不会删这些非 JuiceFS 对象）；`rados df` 落盘确认 `juicefs-data` 对象数≈0（或仅元数据）。
   - ② `compact` 到全部 OSD `compact_queue_len=0` 且 `compact_running=0`（清残余状态、防 stall）。
   - ③ 各节点 `iostat -x 1` sdb `%util≈0`（无后台 I/O）+ `ceph health` = HEALTH_OK。
   > 组间**不改 config、不重启 OSD** 时（如 A1→A3、A2→A4），**不会产生 degraded pgs**，只做上面净态三确认即可，无需等恢复。

   **(b) 仅在切 HDD↔SSD 模式那一次（改 config + 重启 OSD 后），额外做「五确认 + 等 10+min」**（重启必然进退化态）：
   - ① `ceph health detail` = **HEALTH_OK**（不是 WARN）；
   - ② **degraded pgs 清零**（`ceph -s` 无 `Degraded data redundancy` / `pgs degraded`）；
   - ③ 所有 OSD `up`/`in`（`ceph osd tree`）；
   - ④ 各节点 `iostat -x 1` sdb `%util≈0`（无后台恢复/compaction I/O）；
   - ⑤ 起跑前 `compact` 到 `compact_queue_len=0` / `compact_running=0`。
   - 经验上冷重启后需等 **10+ min**。**HDD 组与 SSD 组必须在同等干净态下测，否则对比无效、本任务白做。**

   > ⚠️ 注意：`compact_queue_len` 提取此前两轮都写成了空值（字段路径 bug，实际只验了 `compact_running`）。本任务务必确认真的取到数字 0，落盘时不能是空白。用 §4 的正确 JSON 路径。
4. **只认 r1**，但每组 rados/seqwrite 各跑 **3 轮**看方差（写类方差大）。multi-seqwrite 跑 1 轮（64G 耗时长）。
5. 单 master 串行；后台 `setsid ... </dev/null >run.log 2>&1 & disown`，确认进 fio 再放手；杀 fio 等 `pgrep -x fio` 空。
6. 密码 .11=`TurboAi@303`，.13/.14=`123456`。OSD 映射 node1(.11)=osd0,1 / node2(.13)=osd2,3 / node3(.14)=osd4,5；盘均 sdb。
7. **一切结论必须有落盘原始数据对账；无数据支撑标"未取证/存疑"；不凭观察/记忆写结论；不取多轮 MAX；不跨目录拼旧数；不手填 summary。**
8. 改 OSD config 后**务必回滚并落盘 `ops.log`**（记录默认值 → 改 → 重启 → 确认恢复 → 测 → 复原 → 再确认 HEALTH_OK + degraded 清零 + 6 OSD up/in）。集群无业务数据，可有创，全程详录 + 回滚。

---

## 2. 实验设计：干净态 2×2 对比矩阵

改一次 config、等一次恢复，测该模式下的 rados + JuiceFS 两组；再切另一模式重复。**关键是把"等恢复"这一步做足。**

### 执行顺序（减少切换次数：先 HDD 组、再 SSD 组）

```
阶段 HDD (deferred=65536, throttle=670000  —— 默认/HDD 误判值)
  0. 确认当前即 HDD 模式(或改回)；若因改 config 重启了 OSD → 【§1.3(b) 五确认 + 等 10+min】
  A1  【开测前净态三确认：清池对象/compact/idle】 rados bench 256K 3×60s   → 后端 HDD 基线
  A3  【开测前净态三确认：清池对象+destroy/format 卷/compact/idle】
      JuiceFS seqwrite 3×4G + multi-seqwrite 1×64G                        → 端到端 HDD 基线
      （A3 期间同采后端 + JuiceFS 侧）

阶段 SSD (deferred=0, throttle=4000  —— SSD 正确值)
  0. 改 config；重启 OSD；【§1.3(b) 五确认 + 等 10+min】等到 HEALTH_OK + degraded=0 + iostat idle
  A2  【开测前净态三确认】 rados bench 256K 3×60s   → 后端 SSD（目标复现 ~72，确认 +23% 可重现）
  A4  【开测前净态三确认】 JuiceFS seqwrite 3×4G + multi-seqwrite 1×64G  → 端到端 SSD（看 +23% 是否传导上来）

回滚：改回 HDD 默认值；重启；【五确认】确认 HEALTH_OK + degraded=0 + 6 OSD up/in；落盘。
```

> **组间干净起跑线（重要）**：A1→A3、A2→A4 之间**不改 config、不重启 OSD**，只做净态三确认（§1.3(a)）即可，**无需**等 degraded 恢复。**关键是 A1/A2 的 rados bench 会往 `juicefs-data` 池灌对象，A3/A4 开测前必须显式清掉这些池对象**（destroy JuiceFS 卷删不掉它们），否则 A3/A4 带着 A1/A2 的残留起跑，`(A1−A3)/A1` 的 JuiceFS 损耗会被污染。

| 组 | 路径 | deferred | throttle | 目的 |
|----|----|:---:|:---:|----|
| A1 | rados 直打 juicefs-data 256K | 65536 | 670000 | 后端 HDD 基线（对齐上轮 58.6）|
| A2 | rados 直打 juicefs-data 256K | 0 | 4000 | 后端 SSD（复现 72.3，确认 +23%）|
| A3 | JuiceFS seqwrite+multi 256K | 65536 | 670000 | 端到端 HDD 基线 |
| A4 | JuiceFS seqwrite+multi 256K | 0 | 4000 | 端到端 SSD（+23% 是否传导）|

- rados：`rados bench -p juicefs-data 60 write -b 256K -t 16`（对齐上轮口径）。
- JuiceFS：seqwrite 单job 4G ×3，multi-seqwrite 16job×4G=64G ×1，bs=256K `--end_fsync=1` mu=150。
- **每组（A1/A2/A3/A4）开测前一律净态三确认（清池对象/compact 到 queue_len=0/iostat idle）**；A3/A4 用同一 layout 口径（destroy→format→挂载→写）。组间不改 config 时不必等 degraded 恢复。

### JuiceFS 侧同步采集（A3/A4，为下一步"收益在哪消失"铺垫）
A3/A4 的 seqwrite/multi 运行期同时采:
- `juicefs stats <挂载点> -l 1 --interval 1 --count <runtime+5> > jfs-stats-<组>.txt`（object put 并发、fuse 写、buffer、blockcache 分段）。
- JuiceFS 进程 CPU/内存（`top -b`/`pidstat`）。
- 实际写到池的对象大小分布（`rados -p juicefs-data ls | head` + 抽样 `rados -p juicefs-data stat <obj>`，或看对象名 `_262144` 后缀）——为验证"JuiceFS 是否命中 deferred 阈值"留证据。

### 后端 OSD perf（所有组，见 §4，delta 口径）
测前测后各一份完整 `perf dump` 作 t0/t_end，报告给 **delta**（不用累计裸值跨组比）：`op_w_latency`、`subop_w_latency`、`bluestore.kv_sync_lat`、`bluestore.throttle_lat`、`bluefs.bytes_written_wal/sst`、`bluestore.deferred_write_ops/deferred_write_bytes`（**这是直接验 deferred 是否生效的关键计数器**）。
- **iostat sdb**（每 OSD 节点 `iostat -x 1`）：看 deferred=0 后 sdb 写量/util 是否下降（deferred 双写减少的直接证据）。

---

## 3. 判据（回报 opencode）

1. **干净态后端 deferred +23% 是否复现**：A2(SSD) vs A1(HDD) 差多少？（目标复现 ~72 vs ~58）。附 `deferred_write_ops/bytes` delta 证明 SSD 模式真的关掉了 deferred 双写、iostat sdb 写量下降。
2. **端到端 deferred 收益是否传导**：A4(SSD) vs A3(HDD) 差多少？
   - 若 **A4 也涨 ~23%** → deferred=0 端到端有效，**回报 opencode 决策是否纳入基线**。
   - 若 **A2 涨但 A4 不涨** → 收益被 JuiceFS 层吞掉 → 进入待办 A 的"定位在哪一环"（本任务先给出对象大小分布 + jfs-stats + 后端/端到端差值，作为下一步输入）。
3. **JuiceFS 层损耗量化**（干净态，HDD 与 SSD 各一组）：`(rados 256K − JuiceFS seqwrite)/rados`、`(rados 256K − JuiceFS multi)/rados`；注明 rados-bench(16线程同对象) 与 multi-fio(16job同文件) 口径差异。
4. 任何异常（config 未回滚、版本不符、采集失败、退化态未恢复就测）如实列。
5. 不擅自改验收口径；无数据支撑标"未取证"。

---

## 4. OSD perf / compact 采集参考（修此前采集坑）

```bash
# admin socket 直采（毫秒级，勿用 cephadm shell 每次拉容器）
FSID=$(sudo ceph fsid)
ASOK="/var/run/ceph/${FSID}/ceph-osd.<X>.asok"

# perf dump 完整落盘（t0/t_end 各一份，报告给 delta）
sudo ceph --admin-daemon "$ASOK" perf dump > osd<X>-perf-t0.txt

# 正确提取 compact_queue_len（此前写成空值的坑：注意 JSON 路径在 "rocksdb" 下）
sudo ceph --admin-daemon "$ASOK" perf dump \
  | python3 -c "import sys,json; r=json.load(sys.stdin).get('rocksdb',{}); print('compact_queue_len=%s compact_running=%s'%(r.get('compact_queue_len','N/A'), r.get('compact_running','N/A')))"

# deferred 计数器（验 SSD 模式是否真关了 deferred 双写）
sudo ceph --admin-daemon "$ASOK" perf dump \
  | python3 -c "import sys,json; b=json.load(sys.stdin).get('bluestore',{}); print('deferred_write_ops=%s deferred_write_bytes=%s'%(b.get('deferred_write_ops'), b.get('deferred_write_bytes')))"

# compact 单台 + 轮询确认 queue_len=0（务必确认取到数字，非空白）
sudo ceph --admin-daemon "$ASOK" compact
```

- health-timeline：master 侧 `while ...; do date; ceph health detail; sleep 5; done`，覆盖全程（确认真跑满，别只跑 1 秒）。
- 采集脚本若循环，在 **OSD 节点本地前台**跑，输出重定向本地文件后 scp 回（不用 nohup 后台易丢）。

---

## 5. 产出与目录

`results/clean-deferred-retest-20260707/`：
```
├── ops.log                      # 全程操作 + config 改动/回滚 + 每次确认落盘
├── recovery-confirm-hdd.txt     # 切到/确认 HDD 模式后 五确认证据（若重启了 OSD）
├── recovery-confirm-ssd.txt     # 切到 SSD 模式后 五确认证据（重点：HEALTH_OK+degraded=0+iostat idle）
├── clean-confirm-A{1,2,3,4}.txt # 每组开测前 净态三确认证据（清池对象/compact queue_len=0/idle，queue_len 必须是数字非空白）
├── A1/ rados-bench-r{1,2,3}.txt + osd-perf-t0/tend + iostat
├── A2/ 同上
├── A3/ seqwrite-r{1,2,3}.txt + multi-seqwrite-r1.txt + jfs-stats + object-size + osd-perf + iostat + health-timeline
├── A4/ 同上
└── report.md                    # 2×2 对比矩阵 + deferred delta 证据 + JuiceFS 损耗量化 + 收益是否传导结论
```

---

## 6. 明确不做
- ❌ 不重跑 14 扫 mu/buffer；不测读类/randrw。
- ❌ **不在退化态 OSD 上测带宽**（切模式后必须五确认 + 等 10+min 恢复）。
- ❌ 不拿单点 perf 累计裸值跨组比（用 t0/t_end delta）。
- ❌ 不做内存盘/stall 复现（已在 `stall-repro-memdisk` 闭环，本任务不碰）。
- ❌ 改 config 后不回滚（务必回滚，`ops.log` 留痕）。
- ❌ 不把没落盘的观察写进结论；`compact_queue_len` 落盘不能是空白。
