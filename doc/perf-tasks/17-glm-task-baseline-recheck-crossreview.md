# 17 执行任务（GLM）：冷态全量基线复测（加强 stall 检查）+ 交叉复核 deepseek 14/15/16

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-06
> 定位：GLM 兼做**独立复核者 + 补测者**。deepseek 近三轮（14/15/16）取证有进步，但仍出现"只查一个参数就下结论"的老毛病（P6 测反了）。本任务让 GLM：
> ①用**你当初做冷态全量基线的原方法**复测一次，但**这次全程盯 stall**（回答一个关键悖论：当年基线是不是其实也 stall 了、只是没查 → 决定过去数据准不准）；
> ②**独立复核 deepseek 14/15/16 的结论**，用原始数据挑错，或许能发现 opencode/deepseek 都疏漏的点。

---

## 0. 背景：我们最近做了什么（请 GLM 先通读，自己判断）

近期由 deepseek 执行、opencode 规划的三个写侧任务，任务书与结果数据目录如下。**请 GLM 先读任务书 + 抽查原始数据，形成自己的独立判断**（不要只信 README 的结论）：

| 任务书 | 主题 | 结果数据目录 |
|----|----|----|
| `doc/perf-analysis/14-deepseek-task-step2-write-push.md` | 写侧冲线（扫 mu/buffer 推三项写过 59） | `results/write-push-20260704/`（含 README.md / analysis.md） |
| `doc/perf-analysis/15-deepseek-task-write-retest-forensics.md` | 后端状态控制 + 并发扫描 + stall 取证 | `results/write-push-retest-20260705/`（含 STATUS.md） |
| `doc/perf-analysis/16-deepseek-task-write-forensics.md` | 后端裸能力 / layout 悖论 / compaction / 介质误判 / 内存盘对照 | `results/write-forensics-20260705/`（含 README.md，判决 P1-P6） |

**opencode 已校验出的问题（供 GLM 参考，但请独立复核、不要照抄，可能还有遗漏）**：
- **P6 结论测反了**：deepseek 只查 `bluestore_cache_size`（hdd=ssd=1GB）就断"SSD 误判 HDD 不影响写"。但漏查了两个关键写路径参数——`bluestore_prefer_deferred_size`（**hdd=65536 / ssd=0**，导致 ≤64K 写全走 deferred 双写、放大 WAL/compaction 压力）和 `bluestore_throttle_cost_per_io`（**hdd=670000 / ssd=4000**，167×）。**介质误判很可能正在加剧 stall，这是不花钱、改配置就可能缓解的突破口。**
- **exp3（compaction 定量）采集彻底失败**：6 个 `osd*-perf-timeline.txt` 每个只有 1 行表头，零数据。根因：用 `cephadm shell` 每 15s 拉容器采 6 OSD，开销太大跑不完周期。
- **exp4（内存盘 WAL/DB 对照）阻停**：在 `cephadm shell` 容器内跑 `ceph-bluestore-tool` 找不到 `/var/lib/ceph/osd/ceph-5/block`（容器没挂设备进去）。
- **exp1 S5（layout 128job×1G 写法）未执行**：所以"当年 layout 也被污染"仍是推论、未坐实。
- **exp2 一个被忽略的矛盾**：rados bench 持续写（256K 60s / 4M 30s）**全程 HEALTH_OK 不 stall**，而 JuiceFS 写 8G 就 stall → 说明触发 stall 的不只是"写入量"，**写的形态（小 IO deferred、对象数、元数据密度）也是关键变量**（又指向 P6 的 deferred_size）。

> GLM 请带着"deepseek 可能只查了一半就下结论"的警惕去复核，重点找**有没有别的结论也是这样草率下的**。

---

## 1. 任务 A：冷态全量基线复测 + 全程 stall 检查（核心，回答"过去数据准不准"）

### 目的
你当初做的冷态全量基线（`results/full-bs256k-cold-r1-20260626-200742/`，走 destroy→format→mount→顺序读写→128G layout→随机读写全流程）**当年没有采集任何 stall/后端状态**。现在 deepseek 发现"持续写 8G 就触发 BlueFS stall"。**那个基线里的 layout（128G 顺序写）和顺序写测试，当年是不是其实也 stall 了、只是没人看？** 这直接决定：**过去所有冷态基线数据到底准不准、要不要作废重来。**

### 做法
- **完全沿用你当年的冷态全量基线方法**（同 `tests/bench-fullmatrix.sh` / `bench-baseline-rerun.sh` 的 destroy→format→layout→全项 口径，256K block、cache=0 冷态、只认 r1），保证与旧基线**可直接对比**。用 patched 二进制（`/usr/local/bin/juicefs`，`1.3.1+2025-12-02.e0032b2a`）。
- **唯一的增强：全程并行采集后端 stall / 状态时间线**，覆盖每一个阶段（尤其 **layout(128G 顺序写)** 和 **顺序写/多线程写**）：
  1. **后端 health 时间线**（在 master 上后台循环，**每 5s** 一次，带时间戳，落盘 `backend/health-timeline.txt`）：`sudo ceph health detail`。必须真正跑满整个测试全程（deepseek 上轮 health-timeline 只跑了 1 秒就停了，这是 bug，务必确认循环在整个 fio 期间持续）。
  2. **每阶段前后快照** `snapshot_backend`：`ceph health detail` + `ceph -s` + `ceph osd perf` + `ceph df detail` + `ceph osd df`，落盘 `backend/<阶段>-{before,after}.txt`。
  3. **OSD admin-socket perf 时间线（关键，别再用 cephadm shell）**：见 §3 的正确采法，**每 5s** 采触发压力的 OSD，落盘 `backend/osd<X>-perf-timeline.txt`。
  4. **OSD 节点 iostat**：每节点后台 `iostat -x 1` 落盘（看 sdb %util / 读写是否双高）。
- **每个测试项开始前确认起跑线干净**（HEALTH_OK + osd perf 回落）；若上一项留下 stall，**如实记录**（不要偷偷 restart 掩盖——我们正是要看基线流程里 stall 何时发生）。但为不让前项污染后项，**允许在项间 restart + 记录**，两种信息都要（"发生了 stall" 和 "restart 后干净重测的值"）。

### 要回答
- 基线流程里 **layout(128G) 阶段到底 stall 没有**？哪个 OSD？何时？→ 若 stall 了 → **当年基线的 layout 之后的所有测试项（随机读写等）都是在污染态下测的,旧数据可信度存疑,需要给出"哪些项受影响/差多少"的评估**。
- **顺序写 / 多线程写**阶段是否 stall？→ 直接关系到我们向领导承诺的顺序写数字准不准。
- 复测出的冷态各项 r1，与旧基线（`full-bs256k-cold-r1-20260626-200742` 及 `results-table-patched.md`）**逐项对比**，差异归因（stall 污染？运行间方差？）。

### 产出
`results/cold-baseline-recheck-20260706/`：全流程原始 fio + backend 时间线/快照 + iostat + 一张"阶段 → 是否 stall / 时刻 / 带宽"表 + 与旧基线对比表 + 结论（过去冷态数据是否可信 / 哪些需重测）。

---

## 2. 任务 B：独立复核 deepseek 14/15/16 结论（挑错）

逐条对账原始数据，对 deepseek 的关键结论给 **✅证实 / ❌推翻 / ⚠️存疑 + 原始文件出处**。至少覆盖：

1. **14/analysis.md**："旧测 57/54.8 被 destroy/layout 污染、新测 64/63.7 是真实态"——是污染还是运行间方差？（opencode 认为两次是同配置、差异是方差 + 那种深度饱和态本身不稳，请独立判）
2. **15/STATUS.md**："stall 由写入总量决定、与并发数无关"（B1-nj1 单进程 64G 也 stall）——证据够吗？B1-nj1 的 "osd.0/osd.2 stalled" 有没有落盘证据（opencode 查发现 abort 前没写 backend-after）？
3. **16/README.md 的 P1-P6**：逐条复核。**特别是 P3（后端裸能力）和 P6（介质误判）**——P3 的 rados 256K=52.7 均值是否可信、能否支撑"瓶颈在后端不在 JuiceFS"；P6 是否如 opencode 所说测反了（补验 §4）。
4. **主动找 opencode 没点出的问题**：deepseek 还有没有别的"抽样不足/口径混淆/凭观察写结论"的地方？

### 产出
`results/cold-baseline-recheck-20260706/cross-review.md`：对 14/15/16 关键结论的独立复核表 + 发现的新问题。

---

## 3. 正确的 OSD perf 采集方法（修 deepseek exp3 的失败）

**不要用 `cephadm shell` 每次拉容器**（开销大、跑不完周期，上轮就是这样只留了表头）。改用 **admin socket 直采**，socket 在 host 上 `/var/run/ceph/<fsid>/`：

```bash
# 在对应 OSD 节点本地后台跑（sshpass 起 nohup 循环，事后 scp 回）
FSID=$(sudo ceph fsid)
ASOK=$(ls /var/run/ceph/$FSID/ceph-osd.<X>.asok 2>/dev/null)   # 确认路径
# 每 5s 采一次，毫秒级开销
while true; do
  echo "=== $(date +%s) $(date) ===" >> osd<X>-perf-timeline.txt
  sudo ceph --admin-daemon "$ASOK" perf dump >> osd<X>-perf-timeline.txt 2>&1
  sleep 5
done
```

- 若 host 上没有 asok，用 `sudo cephadm shell --name osd.<X> -- ceph daemon osd.<X> perf dump`（`--name` 会把该 OSD 的 socket 挂进容器），但仍**只盯 1-2 个触发 stall 的 OSD**，别 6 个全采。
- 关键字段：`bluefs`(`read_random_bytes`/`slow_total_bytes`/`bytes_written_wal`/`bytes_written_sst`)、`bluestore`(`kv_sync_lat`/`kv_commit_lat`/`throttle_lat`/`state_kv_queued_lat`)、`rocksdb`(`compact*`/`submit_transaction*`)、`osd`(`op_w_latency`/`subop_w_latency`)。
- **判据**：stall 时刻是否对齐 `compact` 活动 + `kv_sync_lat` 飙升 + `bluefs read_random` 暴涨 + iostat sdb %util 打满且读写双高 → 坐实 compaction 反压。

---

## 4. 补验 P6：介质误判是否加剧 stall（免硬件突破口，重点）

这是最可能"不花钱就见效"的方向，务必做实：

1. **取证差异参数**（只读，全落盘）：`ceph config get osd bluestore_prefer_deferred_size_hdd/ssd`、`..._throttle_cost_per_io_hdd/ssd`、`bluestore_min_alloc_size_hdd/ssd`、`bluestore_deferred_batch_ops_hdd/ssd` 等所有 hdd/ssd 分叉参数，列出"因误判为 HDD 而实际生效的值 vs 若识别为 SSD 应生效的值"。
2. **对照实验**：在**触发 stall 的场景**（如冷态单进程写 32G/64G）下，测两组：
   - **对照组**：现状（Ceph 认 HDD，deferred_size=65536）。
   - **实验组**：把该 OSD（或全体，先单 OSD 稳妥）显式设成 SSD 行为——`ceph config set osd bluestore_prefer_deferred_size 0`（关小 IO deferred 双写）、必要时 `bluestore_throttle_cost_per_io 4000`；**记录所有默认值以便回滚**，改完重启该 OSD 生效。
   - 对比：stall 是否推迟/消失、写带宽是否提升、`bluefs bytes_written_wal` 是否下降（deferred 双写减少的直接证据）。
3. **判据**：若关掉 deferred（SSD 行为）后 stall 明显缓解 → **P6 应推翻 deepseek 的"无影响"，改为"介质误判是可通过配置消除的重要诱因"**，且这是**优先于加硬件**的解法。
- **回滚**：实验后把改过的 config 复原（`ceph config rm osd <param>` 或设回默认），重启 OSD，确认 HEALTH_OK。**全程落盘 `results/cold-baseline-recheck-20260706/p6-deferred/ops.log`。**

> ⚠️ 也可考虑用 `ceph osd crush set-device-class ssd osd.X` 纠正设备类，但这会触发数据迁移，**先用 config set 参数覆盖的轻量方式验证机理**，别急着改 device class。

---

## 5. （可选，视 §4 结果决定）重试内存盘 WAL/DB 对照（修 exp4）

若 §4 改配置仍不足以解决、需坐实"隔离 WAL/DB 有效"：修 deepseek exp4 的容器路径 bug——
- 用 `cephadm shell --name osd.5` 让容器挂到 osd.5 的目录/设备，再跑 `ceph-bluestore-tool bluefs-bdev-new-db`；或直接进 osd.5 的容器操作。
- 内存盘 loop 设备做 new-db 目标（deepseek 已建好 `/dev/loop10` on tmpfs，可复用思路）。
- 无业务数据，可有创；**全程详录操作 + 原始日志**，做完**回滚**（迁回 or 销毁重建 osd.5），确认 HEALTH_OK。

---

## 6. 通用铁律（与 14/15/16 一致）

- 二进制 patched v1.3.1，挂载 `--cache-size 0`，不传 `--max-readahead`，不开 writeback，不加大 cache。
- 冷态口径、只认 r1；单 master 串行；后台 `setsid ... </dev/null >run.log 2>&1 & disown`，确认进 fio 再放手；杀 fio 等 `pgrep -x fio` 空。
- 密码：.11=`TurboAi@303`，.13/.14=`123456`。OSD 映射：node1(.11)=osd0,1 / node2(.13)=osd2,3 / node3(.14)=osd4,5。
- **一切结论必须有落盘原始数据对账；无数据支撑一律标"未取证/存疑"；不凭观察或记忆写结论；不取多轮 MAX；不跨目录拼旧数；不手填 summary。**
- health-timeline 循环必须确认真正跑满整个 fio 全程（别再像上轮只跑 1 秒）。

---

## 7. 回报 opencode（最终一条消息）

1. **任务A**：冷态基线复测的 layout/顺序写阶段**到底 stall 没有** → 过去冷态数据是否可信、哪些需重测；与旧基线逐项对比。
2. **任务B**：对 deepseek 14/15/16 关键结论的独立复核（✅/❌/⚠️ + 出处），以及**你发现的、opencode 没点出的新问题**。
3. **P6 补验**：关 deferred（SSD 行为）后 stall/带宽/WAL 写入的变化 → 介质误判是不是可配置消除的诱因（免硬件突破口成立否）。
4. compaction 反压的 perf 定量证据（admin socket 采到的）。
5. （若做）内存盘 WAL/DB 隔离结果。
6. 汇总"要不要向领导要 NVMe 预算"的证据链现状：哪些齐了、哪些还缺、有没有免硬件的更优解。

## 8. 明确不做
- ❌ 不继续盲扫 mu/buffer；不测读类/randrw（除非基线全流程本就含，则照旧采但重点在写侧+stall）。
- ❌ 不把没落盘的观察写进结论；不擅自改验收口径。
- ❌ 改 config / 动 OSD 后务必回滚，不留残状态。
