# 任务（GLM）：写 IOPS 墙定位 —— op 卡在哪一段（perf 分段延迟拆解 + 客户端网卡实测）

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-08
> 来源：`results/backend-rados-fulldiag-20260708/` 收尾。全量诊断已坐实：256K+EC4+2 单客户端稳态写 ~56 MB/s = **IOPS 恒定 ~230（16→128 并发不变，延迟线性增长 = 队列饱和）**；网络墙被勘误否定（客户端仅 47%）；EC 比副本快（证伪 EC 瓶颈）。
> **但"IOPS 墙的根因"仍是推断，未实测**。GLM 归到"WAL/DB/Data 共享单盘 fsync 慢"，但：① 盘物理是 SSD（裸 4K randread 6542 IOPS），**只有 38 fsync/s/OSD 低得反常**；② **hdd 误判 + throttle 已验证无效**（`clean-deferred-retest` 把 `throttle_cost_per_io` 从 670000 改到 4000、`deferred_size=0`，干净态后端仅 +0.9%）→ **throttle 不是墙**。
> 本任务：**用 perf 分段延迟把单个写 op 的耗时拆到各段，实测定位墙在哪一段；并实测客户端网卡确认没打满。不再调 throttle（已证无效）。**

---

## 0. 背景与要回答的问题（GLM 请先读）

### 已排除（不要再试）
- ❌ **并发不足**：16→128 并发 IOPS 恒定 ~230（`backend-rados-fulldiag` 2A 坐实）。
- ❌ **网络带宽墙（客户端侧）**：客户端只发 1 份数据 ~56 MB/s = 1GbE 的 47%；EC 分发走 OSD 侧网络，不走客户端网卡。
- ❌ **throttle 层 / hdd 误判**：`throttle_cost_per_io` 670000→4000（167×）+ `deferred_size=0` 干净态实测仅 +0.9%（`clean-deferred-retest-20260707`）。**IO 不是卡在 throttle 层。**
- ❌ **EC 4+2 本身**：EC 写比副本 size=3 快一倍（证伪）。

### 核心谜题
写 op 完成速率被锁死在 **~230 IOPS（per-OSD ~38/s）**，对 SSD 而言异常低。**每个写 op 的时间（~230 IOPS 下单 op 处理 ~4-5ms 级）花在了哪一段？** 候选（都在 throttle 之后）：
- **kv/WAL fsync 串行**：`kv_sync_lat`（RocksDB WAL fsync 落盘）。
- **kv 提交排队**：`state_kv_queued_lat` / `state_kv_commiting_lat`。
- **EC 分片协调**：primary 等 6 个分片 ack，`subop_w_latency`。
- **aio 落盘等待**：`state_aio_wait_lat` / `state_deferred_aio_wait_lat`。

**判据**：哪一段占单 op 总延迟的大头，墙就在那一段。

### 关键分支（决定后续路线）
- 若墙在 **kv_sync/WAL fsync**（且 ceph 节点 sdb iostat %util 高）→ 是 WAL 落盘串行 → 下一步验独立 WAL 设备（内存盘曾提但当时无 stall 前提；此处目的不同，是提 fsync 速率）。
- 若墙在 **kv_sync 但 sdb %util 低**（<50%）→ **盘不忙、是软件串行**（RocksDB 单线程 kv_sync / OSD op shard 不足）→ 查 `bluestore_sync_submit_transaction`、kv_sync 线程、osd op 线程/shard 数。
- 若墙在 **subop_w（EC 协调）**→ 是 EC PG 协调串行 → 架构性，倾向"接受上限、转多客户端聚合"。
- **无论哪段，`txc_throttle_lat` 都应很小**（再次坐实 throttle 不是墙）。

---

## 1. 基线口径变更（本任务起，写入 TESTING-GUIDE）

**物理盘是 SSD，后续测试基线一律用 SSD 配置，与硬件相符。** 本任务开测前将 6 OSD 显式设为 SSD 行为并落盘：
- `bluestore_prefer_deferred_size = 0`、`bluestore_throttle_cost_per_io = 4000`（SSD 值）。
- 注：这**不是为提速**（已证无收益），是让口径与硬件一致、排除 hdd 保守参数的其它副作用。用 `ceph tell osd.* injectargs`（运行时，避免重启退化态；`ceph config set` 会被 cephadm 本地 config 覆盖，见 `clean-deferred-retest` §7）。
- 改完**五确认**（HEALTH_OK + degraded=0 + OSD up/in + iostat idle + compact queue_len=0），落盘 `recovery-confirm.txt`。

---

## 2. 铁律
1. rados bench 直打 `juicefs-data`（EC 4+2）池，不经 JuiceFS，从 client(.12) 发起。
2. 开测前净态三确认（池清零 + compact 到 `compact_queue_len=0`（数字非空白）+ iostat idle + HEALTH_OK），落盘。
3. **perf 采集用 admin socket 直采**（`sudo ceph --admin-daemon /var/run/ceph/$(sudo ceph fsid)/ceph-osd.X.asok perf dump`），**测前 t0 + 测后 tend 各一份完整 dump**，报告用 **delta 且用分段的 avgcount/sum 算"测窗内平均单段延迟"**（见 §4，不能用 lifetime `avgtime`）。
4. 网卡/iostat 采集在**对应节点本地前台循环**（不用 nohup 后台易丢），每 1s，覆盖整段测试。
5. 单 master 串行；后台任务确认进 fio/rados 再放手；杀完等 `pgrep` 空。
6. 密码 .11=`TurboAi@303`，.13/.14=`123456`；OSD 映射 node1(.11)=osd0,1 / node2(.13)=osd2,3 / node3(.14)=osd4,5；盘 sdb。
7. **一切结论对账原始数据；无数据标"未取证"；不取 MAX；不手填 summary；改 config 落盘并在任务末回滚记录。**

---

## 3. 实验：256K t64 write 300s + 三路同步采集

**一组测试，三路同步采集**（这是本任务全部，不需要多组）：

```
基线：SSD 参数（§1）+ 净态三确认
负载：rados bench -p juicefs-data 300 write -b 256K -t 64 --no-cleanup   （逐秒落盘）
      测完 rados -p juicefs-data cleanup
```

### 采集 A【关键刀 · 客户端网卡】
在 client(.12) 本地：`sar -n DEV 1 305 > client-nic-eno1.txt`（或 `ifstat -i eno1 1`）。
- **看 eno1 的 tx/rx（txkB/s）峰值和稳态**。判据：稳态 tx 是否接近 ~118 MB/s（≈120000 kB/s）。
- **这是二分整个问题的那一刀**：若客户端网卡**没打满** → 墙在 ceph 集群侧（继续看采集 B/C 定位 op 段）；若**打满了** → 是客户端侧写放大（基本不可能，因 EC 分发不走客户端网卡，但要用数据确认）。

### 采集 B【核心 · OSD perf 分段延迟】
测前对 6 OSD 各采一份 `perf dump` 存 `osdX-perf-t0.txt`，测后存 `osdX-perf-tend.txt`。
报告要拆出**测窗内单个写 op 的分段平均延迟**（每段 `delta_sum/delta_avgcount`，见 §4），至少这些段：

| 段 | 字段（bluestore 下）| 含义 |
|----|----|----|
| throttle | `txc_throttle_lat` | 在 throttle 等（预期很小，坐实 throttle 不是墙）|
| 准备 | `state_prepare_lat` | op 准备 |
| aio 落盘等待 | `state_aio_wait_lat` | 等数据 aio 完成 |
| kv 排队 | `state_kv_queued_lat` | 等进 kv 提交队列 |
| kv 提交中 | `state_kv_commiting_lat` | RocksDB 提交进行中 |
| **WAL fsync** | `kv_sync_lat` | **WAL fsync 落盘（最大嫌疑）** |
| kv flush/commit/final | `kv_flush_lat` / `kv_commit_lat` / `kv_final_lat` | RocksDB 各阶段 |
| deferred | `state_deferred_aio_wait_lat` | deferred 写等待 |

同时在 **osd 段**（非 bluestore 段）拆：`op_w_latency`（写 op 总延迟）、`op_w_prepare_latency`、`op_w_process_latency`、`subop_w_latency`（**EC 分片子操作延迟，EC 协调嫌疑**）。
- **判据**：把 `op_w_latency` 的测窗平均值当"单 op 总时间"，看上面哪段占最大比例。占大头的段 = 墙。

### 采集 C【顺手 · 坐实盘忙不忙 + ceph 节点网卡】
- 3 台 ceph 节点本地 `iostat -x 1 305 > cephX-iostat-sdb.txt`：看 sdb 的 `%util`、`w/s`（每秒写 IOPS）、`w_await`、`aqu-sz`。
  - **判据**：sdb %util≈100% + w/s 高 → 盘忙，墙在盘；sdb %util 低（<50%）+ w/s 不高 → **盘不忙，墙在软件串行**（印证"SSD 只有 38 fsync/s 反常"是软件所致）。
- 3 台 ceph 节点本地 `sar -n DEV 1 305`（顺手，看 OSD 侧网卡是否才是真瓶颈，非关键刀）。

---

## 4. perf delta 计算方法（避免 lifetime 均值坑）

每个延迟段 perf dump 结构为 `{avgcount, sum, avgtime}`，`avgtime` 是**生命周期均值**，会被历史稀释。**必须用测窗 delta**：

```
测窗内该段平均单次延迟 = (sum_tend − sum_t0) / (avgcount_tend − avgcount_t0)
```

提取脚本示例（对每 OSD 每段）：
```bash
python3 - "$t0" "$tend" <<'EOF'
import sys, json
t0=json.load(open(sys.argv[1])); te=json.load(open(sys.argv[2]))
def seg(root, name):
    a=root.get(name,{})
    return a.get("avgcount",0), a.get("sum",0.0)
bs0=t0.get("bluestore",{}); bse=te.get("bluestore",{})
for name in ["txc_throttle_lat","state_prepare_lat","state_aio_wait_lat",
             "state_kv_queued_lat","state_kv_commiting_lat","kv_sync_lat",
             "kv_flush_lat","kv_commit_lat","kv_final_lat","state_deferred_aio_wait_lat"]:
    c0,s0=seg(bs0,name); c1,s1=seg(bse,name); dc=c1-c0
    if dc>0: print("%-26s dcount=%d  avg=%.3f ms"%(name, dc, (s1-s0)/dc*1000))
EOF
```
（osd 段的 `op_w_latency`/`subop_w_latency` 同理，root 换成 osd 段。）

---

## 5. 回报 opencode（最终一条消息）
1. **客户端网卡 eno1 稳态 tx**：多少 MB/s、占 1GbE 几 %。→ 墙在 ceph 侧还是客户端侧（关键刀结论）。
2. **单写 op 分段延迟拆解表**（6 OSD 或代表性 OSD）：`op_w_latency` 总时间 = 各段之和，**哪段占大头**。明确 `txc_throttle_lat` 是否很小（坐实 throttle 不是墙）。
3. **ceph 节点 sdb iostat**：%util / w/s / w_await → **盘忙不忙**，墙是盘物理还是软件串行。
4. **总判决**（给证据）：墙在 **① WAL fsync 串行(盘) / ② kv_sync 软件串行(盘不忙) / ③ EC subop 协调 / ④ 其它**，并给下一步方向建议（是否有软件参数可救、还是架构上限该转多客户端聚合）。
5. 异常（采集失败、config 未回滚）如实列。

## 6. 明确不做
- ❌ 不再调 throttle_cost_per_io（已证无效）；不再验 hdd 误判对吞吐的影响（已证无效）。
- ❌ 不经 JuiceFS；不改验收口径。
- ❌ 不用 lifetime `avgtime` 下结论（用 t0/tend delta）。
- ❌ 改 config 后不回滚（SSD 基线参数若决定保留则明确记录为新基线，否则回滚，见 §7 决策）。
- ❌ 无数据支撑写进结论。

## 7. SSD 基线是否保留（回报时说明）
本任务把 OSD 设为 SSD 参数作为基线。测完由 opencode/用户决策：
- 若保留为新基线（与硬件相符）→ 落盘记录当前值为"SSD 基线"，写入 TESTING-GUIDE，不回滚。
- 若回滚 → 记录默认(hdd)值并复原。
- **本任务默认：保留 SSD 参数**（性能无差异但口径正确），除非用户另有决定；GLM 只需把"改了什么、当前值、如何回滚"完整落盘。

## 8. 产出目录
`results/iops-wall-locate-20260708/`：
```
├── ops.log                    # 全程 + SSD 参数变更 + 净态/五确认
├── recovery-confirm.txt       # SSD 参数注入后 五确认
├── clean-confirm.txt          # 净态三确认（compact queue_len 为数字）
├── rados-write-256k-t64-300s.txt   # 逐秒原始
├── client-nic-eno1.txt        # 关键刀：客户端网卡
├── osd{0..5}-perf-t0.txt / -tend.txt
├── ceph{11,13,14}-iostat-sdb.txt
├── ceph{11,13,14}-nic.txt     # 顺手
├── segment-latency.md         # 分段延迟拆解表（delta 口径）+ 各 OSD
└── report.md                  # 关键刀结论 + 分段拆解 + 盘忙否 + 总判决
```
