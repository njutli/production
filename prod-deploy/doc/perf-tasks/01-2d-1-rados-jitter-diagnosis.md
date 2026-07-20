# 任务书 01-2d-1：rados bench 后端随机读带宽波动诊断专项

> 面向 GLM。本任务书是 **01-2d 的前置诊断专项**，不产出基线数据，
> 唯一目标：**定位 rados bench 随机读带宽剧烈波动（Min IOPS 周期性归零）的根因，并判断是否可消除**。
> 只有本专项确认"波动来源已查明、且可消除或已确认为架构固有"之后，才回到 01-2d §3.3 正式跑 rados bench 基线。
>
> **⚠️ 测试过程必须严格遵守 `skills/` 下全部文档**（同 01-2d）：
> - `skills/TESTING-GUIDE.md`：§1.3 OSD compaction/LSM 检查（admin socket）、§2.2 health 检查、§3 compact cooldown
> - `skills/LONG-RUNNING-TEST-SKILL.md`：长跑监控
>
> 前置文档（必读）：
> - `doc/perf-tasks/01-2d-full-baseline-retest.md` §3.3——正式 rados bench 步骤（本专项完成后才执行）
> - `doc/perf-tasks/task-progression.md`——任务演进脉络
> - `results/prod-fullretest-A-nolimit-default-20260717-124907/rados-bench/`——上一轮问题数据（本专项要复现并解释的对象）

---

## 〇、背景：上一轮 rados bench 暴露的波动问题

2026-07-17 GLM 首测 `prod-fullretest-A-nolimit-default-.../rados-bench` 的原始数据显示，后端随机读带宽**在同参数下不可复现、且测试期间存在整秒 IO 完全停顿**：

| 档 | 轮 | Bandwidth (MB/s) | Avg IOPS | Min IOPS | Max IOPS | Stddev IOPS | Avg Lat (s) |
|----|----|------------------|----------|----------|----------|-------------|-------------|
| prefill(write) | — | 2217 | 8871 | 7842 | 9439 | 316 | 0.0018 |
| t128 | 1 | 3672 | 14690 | 13958 | 15350 | 316 | 0.0087 |
| t128 | 2 | 4022 | 16090 | **7370** | 17622 | 1927 | 0.0079 |
| t1024 | 1 | 2065 | 8260 | **8** | 14413 | 6518 | 0.120 |
| t4096 | 1 | **168** | 673 | **0** | 6136 | 904 | **5.89** |
| t4096 | 2 | 4454 | 17816 | 10119 | 20575 | 1597 | 0.229 |
| t16384 | 1 | 3737 | 14949 | **0** | 18884 | 4535 | 1.056 |
| t16384 | 2 | 4200 | 16798 | **0** | 24085 | 3936 | 0.962 |

**关键观察**：
1. **写(prefill)非常稳**（Stddev 316，Min/Max=83%），**波动是随机读路径特有的**，不是机器整体抖动。
2. 随机读高并发档普遍 **Min IOPS = 0**——测试期间有整秒完全没有 IO 完成，是**间歇性 stall / 卡死**，不是统计噪声，延长测试时间无法消除（只会把 stall 稀释进平均值，藏得更深）。
3. 同参数不可复现（t4096：168 vs 4454，差 26×）。
4. GLM 上一轮只查了 compact 三指标（全绿），把根因**猜**为"LSM level-0 膨胀"，但无逐秒对齐证据，且无法解释"t16384 未 compact 却自行回升"。

**结论：在解释清楚波动来源前，任何 rados 稳态值都是伪稳态，正式基线不得开跑。**

---

## 一、诊断目标（唯一）

**回答一个问题**：随机读带宽 stall（Min IOPS 归零 / 带宽骤降）的**主因**是下列哪一个，以及**能否消除**：

| 候选根因 | 判定信号 | 处理方式 |
|---|---|---|
| A. RocksDB compaction / LSM level-0 膨胀 | stall 秒对齐 `l0_files` 尖峰 / `compaction bytes` 增长 / `kv_sync_lat` 尖峰 | 强制 compact + 调 LSM，**可消除** |
| B. DB/WAL on tmpfs 内存压力 | stall 秒对齐 tmpfs 占用逼近上限 / 系统 `si/so` 换页 / kswapd 活跃 | 挪 DB/WAL 或调内存，**可消除** |
| C. EC4+2 + failure-domain=osd fan-in 尾延迟 | stall 秒对齐单 OSD op 队列深度打满 / subop latency 尖峰；并发越高越严重 | **架构固有，延长时间无解**，只能接受或用副本池对照验证 |
| D. 客户端(157)线程超配调度抖动 | stall 与后端指标无关；157 侧 CPU sys / run-queue 飙升；降低 -t 后 stall 消失 | 属工具配置，降 -t 即可，**非后端问题** |

**产出必须明确指认主因（可多因，但要排序），并给出"是否可消除 / 如何消除"的判断。**

---

## 二、诊断方法：逐秒采集 + 时间对齐

不追求带宽值，追求**把 stall 发生的时刻与后端/系统指标的尖峰做逐秒对齐**。

### 2.1 测试档位（精简，不用全扫）

只测两档，覆盖"低并发稳"与"高并发 stall"两种状态：

- **t128**（上一轮相对稳，作对照基线）
- **t4096**（上一轮出现 168 崩点，作 stall 复现档）

每档跑 **2 轮**：第 1 轮为"未干预"（compact cooldown 后直接跑，尽量复现 stall）；第 2 轮为"强制 compact + l0_files 回落确认后"跑，看 stall 是否消失（用于验证根因 A）。

### 2.2 rados bench 逐秒输出

`rados bench` 默认每秒打印一行 cur MB/s / cur IOPS / avg lat。**必须完整保存逐秒输出**（`tee` 到文件），后续用于定位哪一秒发生 stall（cur IOPS 骤降/归零的秒）。

```bash
POOL=juicefs-data
RUNNAME=rados-diag
# 预填（若 pool 已有 rados-l1 对象可复用，否则先预填 120s；预填后 compact cooldown）
sudo rados bench -p ${POOL} 120 write -b 262144 -t 16 --no-cleanup --run-name ${RUNNAME}
# compact cooldown + 确认 l0_files 回落（见 §2.3）+ drop_caches(157+3 slaves)

for t in 128 4096; do
  # 第 1 轮：未干预
  sudo rados bench -p ${POOL} 60 rand -t ${t} --run-name ${RUNNAME} \
    | tee rados-diag-t${t}-r1.txt
  # 强制 compact 全 OSD + 轮询 compact_running=0 + 确认 l0_files<10 + drop_caches
  # 第 2 轮：干预后
  sudo rados bench -p ${POOL} 60 rand -t ${t} --run-name ${RUNNAME} \
    | tee rados-diag-t${t}-r2.txt
done
```

### 2.3 后台逐秒指标采集（贯穿每一轮 rados bench 全程）

在 rados bench 运行的同时，**每 1 秒**采集下列指标并带时间戳落盘，供事后与逐秒带宽对齐。三层跳板经 `config.sh` 的 `ssh_to_slave` 到各 OSD 节点（10.20.1.150/151/152，每节点 2 OSD）执行 admin socket。

对**每个 OSD**（`ceph osd ls` 动态枚举）每秒采：

```
ASOK=/var/run/ceph/${FSID}/ceph-osd.${id}.asok
sudo ceph --admin-daemon "$ASOK" perf dump
```
从 perf dump 提取（带秒级时间戳）：
- `rocksdb.l0_files`（LSM level-0 文件数 → 候选 A）
- `rocksdb.compact_running` / `compact_queue_len`
- `rocksdb.submit_sync_latency` / `kv_sync_lat`（→ 候选 A）
- `osd.op_r_latency` / `osd.subop_latency`（尾延迟 → 候选 C）
- `osd.op_queue_len` 或 `osd.numpg` op 积压（单 OSD 排队 → 候选 C）

同时在**每个 OSD 节点**每秒采系统级（→ 候选 B）：
- tmpfs 挂载点占用（DB/WAL 所在，`df` 该挂载点 used%）
- `/proc/vmstat` 的 `pgscan_kswapd` / `si` / `so`（换页）、`free -m` available

同时在 **157 客户端**每秒采（→ 候选 D）：
- CPU sys% / usr%（rados bench 进程 + 全局）
- run-queue 长度（`/proc/loadavg` 或 `vmstat 1` 的 `r` 列）

> **采集脚本要求**：每条记录格式 `<epoch_ts> <host> <metric> <value>`，落到 `rados-diag-metrics-t${t}-r${n}.log`。GLM 自行实现采集循环（后台 `while sleep 1` + 时间戳），跨节点用 `ssh_to_slave` 打包批量取，避免每秒建连开销过大——可在各节点本地起采集脚本、测完统一回收（经三层跳板打 tar 回收，禁直连 scp / 禁 `thailand:`）。

---

## 三、分析：时间对齐

1. 从每份 `rados-diag-t${t}-r${n}.txt` 逐秒输出中，**标出 cur IOPS 骤降/归零的秒**（stall 秒集合）。
2. 把 stall 秒 与 §2.3 各指标的**同一秒**值对齐，看哪个指标在 stall 秒同步出现尖峰：
   - stall 秒对齐 `l0_files` 高 / `kv_sync_lat` 尖峰 → **A（compaction/LSM）**
   - stall 秒对齐 tmpfs 逼近满 / kswapd 活跃 / si-so 非零 → **B（tmpfs 内存压力）**
   - stall 秒对齐单 OSD op 队列打满 / subop latency 尖峰，且 t4096 比 t128 严重得多 → **C（EC fan-in 尾延迟，架构固有）**
   - stall 与后端指标都不对齐，反而对齐 157 sys% / run-queue 飙升 → **D（客户端线程超配）**
3. 对比 t128（稳）与 t4096（stall）两档的指标差异，进一步坐实主因。
4. 对比每档 r1（未干预）与 r2（compact 后）：若 r2 的 stall 明显减少 → 支持 A；若 r2 仍 stall → 排除 A 为主因。

---

## 四、产出

结果目录：`results/prod-rados-jitter-diag-<ts>/`（不占正式基线编号，standalone 诊断）。

必含：
1. 全部逐秒 rados bench 输出（`rados-diag-t{128,4096}-r{1,2}.txt`）。
2. 全部逐秒指标日志（`rados-diag-metrics-*.log`）+ 采集脚本本体。
3. `commands.sh`（完整命令记录）+ env-snapshot（ceph -s / ceph osd tree / osd df / 各节点 DB-WAL tmpfs 挂载情况 / JuiceFS 版本 / 157 红线未动确认）。
4. **`diagnosis.md`**（核心产出），必须包含：
   - stall 秒清单 + 对齐分析表（stall 秒 × 各候选指标值）；
   - **主因指认**（A/B/C/D，可排序多因）+ 证据；
   - **是否可消除**：若 A/B/D → 给出消除手段并在 r2/降 -t 中验证；若 C → 明确"架构固有、rados 单点值不可作天花板、正式测只能报稳态中位数+方差区间并标注尾延迟受限"；
   - **对 01-2d §3.3 的回执**：正式 rados bench 是否可开跑；若需先施加某项干预（如挪 DB/WAL、限 -t 上限），写明。

---

## 五、红线与前置（同 01-2d）

- **157 上 WekaIO 业务在跑=红线**：禁动内核/网卡/RoCE/md0/WekaIO 路径；157 只跑 rados bench 客户端 + 轻量采集。
- 环境前置：`ceph health` = `HEALTH_OK`、OSD 全 `up`；JuiceFS 版本含 eaf3d21f（本专项不挂 JuiceFS，仅确认集群态）。
- SSH 三层跳板（WSL→HK ECS→157→slaves），用 `config.sh` 的 `ssh_to_client`/`ssh_to_slave`；**禁直连 scp、禁 `thailand:` 写法**；回收经跳板打 tar。
- 每轮之间 compact cooldown（轮询 `compact_running=0`）+ 确认 `l0_files` 回落 + drop_caches（157+3 slaves）。
- BeeGFS 与本测抢同批盘须错峰，开测前确认 BeeGFS 侧无并发压力。

---

## 六、与 01-2d 的衔接

```
01-2d-1（本专项）: 定位波动根因 → diagnosis.md 给出"是否可开跑"回执
        │
        ├─ 若波动可消除（A/B/D）→ 施加消除手段后
        └─ 若波动为架构固有（C）→ 明确报告方式（中位数+方差区间+尾延迟标注）
        ▼
01-2d §3.3: 正式 rados bench 基线（每档 REPEAT=3，按 §3.3 稳态判据取中位数）
```
