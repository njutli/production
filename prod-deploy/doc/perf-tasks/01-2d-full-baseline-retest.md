# 任务书 01-2d：完整基线重测（不限速 + 限速，default + ra0）

> 面向 GLM。本任务书是对 00 ~ 01-2c 全部基线测试的**一次性完整重测**，
> 解决历轮测试中遗留的数据采集缺陷，产出一份方法论无瑕疵的双口径基线。
>
> **⚠️ 测试过程必须严格遵守 `skills/` 下全部文档**：
> - `skills/TESTING-GUIDE.md`：health 检查 / compact cooldown / 缓冲暂态 / 可靠性判据 / OSD compaction 状态检查（admin socket）
> - `skills/test-commands-reference.md`：完整 fio 命令 + §8.3 稳态中位数 + §9 数据采集
> - `skills/LONG-RUNNING-TEST-SKILL.md`：长跑任务监控
>
> 特别是 TESTING-GUIDE 的以下要求**不可省略**：
> - §1.3：高强度写后必须用 admin socket 检查 `compact_queue_len`/`compact_running`/`kv_sync_lat`，三指标全绿才继续
> - §2.2：每个 fio 命令前必须调用 `check_ceph_health`
> - §3：layout 后必须 compact cooldown 并轮询至 `compact_running=0`
> - 写项之间必须 compact cooldown（randwrite-true → layout → randrw → randwrite-ow 之间均需）
>
> 前置文档（必读）：
> - `doc/perf-tasks/task-progression.md`——任务演进脉络与历轮问题清单
> - `doc/deploy-log/bw-statistics-audit.md`——统计口径审计台账

---

## 〇、测试背景：为什么要重测

### 历轮测试遗留的问题

从 00（全量基线）到 01-2c（default 补测），经历了 5 轮测试 + 1 轮审计，但**始终没有一份方法论无瑕疵的完整基线**。核心问题链如下：

| 轮次 | 发现的问题 | 后续轮次是否修复 |
|------|-----------|----------------|
| 00 | ① bw_log 只拷回 1 份合并文件（缺 per-job）；② randrw 冷启动失真 | 01-1 未修（同样只拷 1 份） |
| 01-1 | 同 00 的 bw_log 问题；randrw 72.7 确认冷启动失真 | 01-2 任务书点名要修，但实际仍未拷回 per-job |
| 01-2 | ① randrw summary 编造中位数；② 第 1 轮冷启动失真；③ bw.log 仍只有 1 份 | 01-2b 针对性修复（仅 randrw） |
| 01-2b | ✅ randrw 正确了（128 per-job + §8.3 + 方案 A） | 但只补了 randrw，其他项没跑 |
| 01-2c | 补了 default randread + randrw | 但 mseqread、randwrite 从未用正确方法采集；限速从未重测 |
| AUDIT | 确认 01-1 的 per-job 文件已被覆盖丢失，不可恢复 | — |

### 从未解决的问题（本次重测必须解决）

1. **mseqread（不限速 + 限速，default + ra0）**：从 00 至今从未用正确方法（16 份 per-job 文件 §8.3 聚合）采集过。
2. **randwrite（不限速 + 限速，default + ra0）**：同上。fio 聚合行含 FUSE 写缓冲膨胀（~7-8%），不可用。
3. **限速口径全部 128-job time_based 项**：randread 前 60s 零完成、randwrite FUSE 缓冲膨胀、randrw 冷启动失真——三种不同原因导致全部不可信，从未重测。
4. **randread / randrw 的 §8.3 准确值**：01-2c/01-2b 的 per-job 文件在 157 上有但未拷回本地，且日期不同（07-16 vs 01-1 的 07-14/07-15），不能替代同日基线。

---

## 一、任务目标

用**正确方法**一次性跑完全量基线，产出 4 组数据：

| 组 | readahead | 口径 | 验收线 |
|----|-----------|------|--------|
| A | default | 不限速 100GbE | 6250 MiB/s |
| B | ra0（`--max-readahead 0`） | 不限速 100GbE | 6250 MiB/s |
| C | default | 千兆限速 TBF 1Gbps | 59 MB/s |
| D | ra0 | 千兆限速 TBF 1Gbps | 59 MB/s |

每组跑全量 9 项（seqread / seqwrite / mseqread / mseqwrite / **randwrite-真写** / layout / randread / randrw / **randwrite-覆写**）。randwrite 两种口径（真随机写 §6.2 + 覆写 §6.4）都测。

---

## 二、红线（本次测试绝对不能重蹈的覆辙）

### 红线 1：bw_log 必须保留全部 per-job 文件

**历史问题**：00/01-1/01-2/01-2c 全部只拷回 1 份合并 bw_log（`<prefix>_bw.log`，不带 `.<job_id>`），导致 §8.3 的"128 job 按时间戳对齐求和"无法执行，退化为"单 job 中位数 × numjobs"外推。

**本次要求**：
- fio 命令**不加** `--per_job_logs=0`（保持默认 `per_job_logs=1`），让 fio 为每个 job 生成独立文件 `<prefix>_bw.<job_id>.log`（已本机验证 fio 3.41 默认即生成 numjobs 份）。
- **回收走三层跳板（WSL→HK ECS→157），无直连 scp、无 `thailand` 主机**。用 `config.sh` 的 `ssh_to_client` 在 157 上打包，再经 HK 中转拷回。参考流程：
  ```bash
  # ① 157 上打 tar（经 ssh_to_client）——用通配符 *_bw.*.log 抓全部 per-job 文件
  ssh_to_client "cd /tmp/jfs-bw && tar czf /tmp/bwlogs-<group>-<item>.tgz *_bw.*.log"
  # ② 经 HK 跳板把 tgz 拉回本地 RESULTS_DIR（sshpass 两跳，禁直连）
  #    具体拉取用 config.sh 既有跳板 scp 封装；严禁 `scp thailand:...` 这类直连写法
  # ③ 本地解包到结果目录
  tar xzf bwlogs-<group>-<item>.tgz -C "${RESULTS_DIR}/"
  ```
  > **历史真凶**：旧 commands.sh 结尾直接 `rm -rf TEST_DIR`、根本没有回收步骤，且当年拷贝用 `*_bw.log`（匹配不到 `*_bw.<N>.log`），这是"只剩一份合并 log"的根因。本次务必用 `*_bw.*.log` 通配并先拷后删。
- **验证**：解包后 `ls ${RESULTS_DIR}/<prefix>_bw.*.log | wc -l` 必须等于 numjobs（128 或 16）。不等则采集失败，重拷；**验证通过前不得删 157 上的 TEST_DIR / bw_log**。
- **每项测试前**清空 `/tmp/jfs-bw/`（`ssh_to_client "rm -f /tmp/jfs-bw/*"`），防上轮残留混入。

### 红线 2：randrw / randwrite-覆写 必须用 skill §6.4 方案 A（复用 layout，禁用 create_on_open）

**历史问题**：00/01-1 的 randrw 用 `--create_on_open=1` + 空目录，第 1 轮读命中未写数据的空洞 → R 虚低 W 虚高 → R/W 严重不均衡 → 数据作废。

**本次要求**：
- randrw、randwrite-覆写 **直接照抄 skill `test-commands-reference.md` §6.4 命令**（analysis 版，复用 §5 layout 铺好的 `${TEST_DIR}` 128 文件工作集），**不得自拟 filesize/size**——自拟单文件 1G 会把工作集缩小 128 倍，是新口径。
- **不加** `--create_on_open=1`，用 `--fallocate=none` 复用已有文件。
- randwrite-真写（§6.2）是**另一独立口径**：fresh volume + `--create_on_open=1 --nrfiles=100`，测真实新写，须在 layout **之前**跑、跑完清卷（见 §3.2 顺序）。
- 三条命令均以 skill 原文为准，本任务书不再复述 fio 行，避免口径漂移。

### 红线 3：REPEAT=3 严格取中位数，禁止取平均、禁止挑轮次

**历史问题**：01-2 的 randrw summary 取了 r2/r3 的平均冒充中位数，还悄悄丢了异常的 r1。

**本次要求**：
- 每项 3 轮，取**中位数**（3 个值排序后的第 2 个），不取平均
- 3 轮全部保留，不丢弃任何一轮
- 若某轮明显异常（如 R/W 比偏离 0.9-1.1），在 summary 中标注但不剔除

### 红线 4：限速测试必须先部署限速网络环境

**历史问题**：限速测试与不限速测试共用 `/tmp/jfs-bw/`，且切换网络环境时未充分验证。

**本次要求**：
- 不限速组（A/B）先测，测完后再切换到限速网络环境（`config-limit.sh`）
- 限速测试前验证：`tc qdisc show dev eno12409` 确认 TBF 已生效，`ceph -s` 确认 MON/OSD 在 10.114.1.x
- 限速测试后验证：TBF 累计字节数增长合理（`tc -s qdisc show dev eno12409`）

### 红线 5：每项测试必须记录完整命令

**历史问题**：01-1 的限速/不限速 default 目录没有 `commands.sh`，无法追溯实际 fio 参数。

**本次要求**：
- 每组结果目录必须有 `commands.sh`（完整可执行命令记录），与 01-1 ra0 目录格式一致
- 测试前先写好 `commands.sh`，测试中照此执行，测试后随结果一起保存

### 红线 6：157 上 `/tmp/jfs-bw/` 每轮清空

**历史问题**：01-1 的 per-job 文件被后续测试覆盖丢失。

**本次要求**：
- **每项测试前** `rm -f /tmp/jfs-bw/*`（157 上执行）
- **每项测试后** 立即拷回全部 bw_log 到本地结果目录
- 不依赖 157 上的临时文件持久化

### 红线 7：`--openfiles` 必须 = numjobs（禁止用 100）

**历史问题**：00 至 01-4 全部 JuiceFS 测试的 128-job 项均使用 `--openfiles=100`（skill §6.2/§6.3/§6.4 原文写死 100）。`--openfiles=100` + `numjobs=128` 意味着只有 100 个 job 能同时打开文件，**28 个 job 排队等 fd**，制造假瓶颈。

BeeGFS 测试已证实此问题：单变量对照实验显示 `--openfiles 100→128` 修复后 layout 性能 +507%（1640→9964 MiB/s），BeeGFS skill 已明确要求 `--openfiles=128`（= numjobs）。详见 `beegfs-production/results/20260707-beegfs-cold-baseline-v2/evidence/control-experiment-conclusion.md`。

**本次要求**：
- 所有 128-job fio 命令：`--openfiles=128`（= numjobs）
- 所有 16-job fio 命令：`--openfiles=16`（= numjobs）或不设（fio 默认无限制 = numjobs）
- 1-job 项不设 `--openfiles`
- **skill §6.2/§6.3/§6.4 原文仍写 100，已在本任务书同步修订为 128，skill 文件后续更新**

---

## 三、测试矩阵

### 3.1 全量 10 项 × 4 组 = 40 项测试

| 顺序 | 项 | bs | numjobs | iodepth | runtime | REPEAT | skill 命令源 | 说明 |
|------|---|----|---------|--------|---------|--------|-----------|------|
| 1 | seqread | 256k | 1 | 1 | 180s | 1 | §4.1 | 单流顺序读，psync |
| 2 | seqwrite | 4M | 1 | 1 | — | 1 | §4.2 | 定量写 4G，end_fsync=1 |
| 3 | mseqread | 256k | 16 | 1 | 180s | 1 | §4.4 | 多流顺序读，psync |
| 4 | mseqwrite | 4M | 16 | 1 | — | 1 | §4.5 | 定量写，end_fsync=1 |
| 5 | **randwrite-真写** | 256k | 128 | 128 | 180s | 3 | **§6.2** | 真随机写，fresh volume + create_on_open + nrfiles=100 |
| 6 | layout | 4M | 128 | 128 | — | 1 | §5 | 铺盘 128×1G，libaio，end_fsync=1（randwrite-真写后 fresh 重建，再铺） |
| 7 | randread | 256k | 128 | 128 | 180s | 3 | §6.1 | 随机读，复用 layout（只读，不改数据） |
| 8 | randrw | 256k | 128 | 128 | 180s | 3 | **§6.4** | 混合读写，**方案 A** 复用 layout（覆写，禁用 create_on_open） |
| 9 | **randwrite-覆写** | 256k | 128 | 128 | 180s | 3 | **§6.4** | 覆写随机写，方案 A 复用 layout（与 randrw 同口径，隔离文件创建开销） |
| 10 | **rados bench 后端裸能力** | 256k | — | — | 60s×4档 | **3** | **§3.3** | rados bench 并发扫描（4 档×3 轮取中位数），仅作后端量级参照 |

> **randwrite 测两种口径**（用户确认）：**§6.2 真随机写**（新建文件，含文件创建开销，反映真实新写场景）+ **§6.4 覆写**（复用 layout，隔离创建开销，与 randrw 口径可比）。
>
> **rados bench 后端裸能力（新增）**：绕过 JuiceFS/FUSE/CephFS，直测 Ceph RADOS EC4+2 后端天花板。用 `rados bench -t` 扫描 4 档并发（128/1024/4096/16384），16384 与 JuiceFS `128 jobs × iodepth 128` 同并发。详见 §3.3。
> 注意：`rados bench` 的 `-b` 参数只在 write 模式有效（设定对象大小），rand 模式不能用 `-b`，对象大小由预填 write 决定。
>
> **执行顺序的污染规避（关键）**：
> - seq 测试后立即清卷（§4.2.1），清零 seq 产生的 ~136G 数据，再跑 randwrite-真写。
> - randwrite-真写后再清卷（§4.2.1），清零 randwrite-true 产生的 ~1.5T 数据，再跑 layout。
> - 清卷用 `juicefs destroy`（删 pool 对象），不用 `juicefs format`（不删对象）。
> - destroy 后必须 compact cooldown（清理 tombstone 积压）。
> - layout 铺满 128×1G → randread（只读，不改数据）→ randrw（覆写 layout）→ randwrite-覆写（覆写 layout）。
> - randread 排在 randrw/randwrite-覆写**之前**（只读项先跑，写项在后，避免读到被覆写过的数据）。
> - 写项之间（randrw→randwrite-ow）必须 compact cooldown。

### 3.2 执行顺序

```
每组内顺序：
rados bench 预填 + randread 扫 4 档 + cleanup + compact cooldown
  → seqread → seqwrite → mseqread → mseqwrite → randwrite-真写(fresh) → 清卷 → layout → compact cooldown → randread → randrw → randwrite-覆写
```

```
组 A (不限速 default)  → rados bench + 全 9 项
组 B (不限速 ra0)      → rados bench + 全 9 项
    ↓ 切换网络环境（config-limit.sh）
组 C (限速 default)     → rados bench + 全 9 项
组 D (限速 ra0)        → rados bench + 全 9 项
```

> 每组内顺序（严格照此，避免写项污染读项、fresh 卷污染 layout）：
> seqread → seqwrite → mseqread → mseqwrite → **清卷（§4.2.1：umount → sleep 65 → destroy → compact cooldown → format → mount → mkdir）** → **randwrite-真写(fresh)** → **清卷（§4.2.1）** → layout(铺盘) → **compact cooldown** → randread(只读) → randrw(覆写) → randwrite-覆写

> 不限速先测（双网分离，public=10.3.1 + cluster=10.3.2）
> 限速后测（单网 eno12409 + TBF 1Gbps，MON/OSD 切到 10.114.1.x）
> A→B 切换只需重挂 JuiceFS（改 readahead），不切网络
> B→C 切换需要切网络环境（config-limit.sh），重挂 JuiceFS
> C→D 切换只需重挂 JuiceFS（改 readahead），不切网络

### 3.3 rados bench 后端裸能力全模式测试（每组跑一次，在 JuiceFS 9 项之前）

**目的**：绕过 JuiceFS/FUSE/CephFS，直测 Ceph RADOS EC4+2 后端天花板。覆盖**写、顺序读、随机读**三种 I/O 模式，与 JuiceFS 各对应测试项做量级参照。

**背景**：01-2 的 rados bench 仅测了 `-t 128` 随机读，并发与 JuiceFS 16384 不可比，且缺少写/顺序读数据。01-2d-1 诊断确认干净 pool 上无 stall，可正式开跑。

> **⚠️ 前置依赖**：01-2d-1 诊断已完成，根因 = RocksDB bloat from dirty pool（可消除），干净 pool 上无 stall。diagnosis.md 给出"可开跑"回执。
>
> **⚠️ 前轮教训**（2026-07-17）：
> 1. 每档 REPEAT=3 取中位数，禁止只跑 1 轮。方差判据：Min/Max IOPS < 0.7 或 Stddev/Avg > 15% → 该轮作废重采。
> 2. 稳态 = 低方差，不是高带宽。低方差轮才代表后端稳态。
> 3. 数据异常当场排查，不得跳过。compact 三指标全绿不保证 LSM 最优，须额外查 `get_latency`。
> 4. rados bench 值仅供后端量级参照，**禁止与 fio 值跨工具相除算"FUSE 开销/倍率"**。

**命令**（沿用老集群方法，不使用 fio rados engine，fio 3.28 在本机有 segfault bug）：

```bash
POOL=juicefs-data
RUNNAME=rados-l1

# ========== Phase 1: Write sweep（写带宽 + 创建对象）==========
# 每档 REPEAT=3，每轮 cleanup + compact + drop_caches 保证起点一致
for t in 16 128 1024 4096; do
  for r in 1 2 3; do
    # cleanup + compact cooldown + drop_caches
    sudo rados -p ${POOL} cleanup --run-name ${RUNNAME} 2>/dev/null
    # compact + verify compact_running=0 + get_latency<10us
    # drop_caches（157 + 3 slaves）
    sudo rados bench -p ${POOL} 60 write -b 262144 -t ${t} --no-cleanup --run-name ${RUNNAME} \
      | tee rados-write-t${t}-r${r}.txt
  done
done
# 最后一次 cleanup（清除 write sweep 的对象，为 read 测试准备干净 pool）
sudo rados -p ${POOL} cleanup --run-name ${RUNNAME} 2>/dev/null
# compact cooldown

# ========== Phase 2: Prefill（为 read 测试创建对象）==========
sudo rados bench -p ${POOL} 120 write -b 262144 -t 16 --no-cleanup --run-name ${RUNNAME}
# compact cooldown + verify + drop_caches

# ========== Phase 3: Sequential read sweep ==========
for t in 16 128 1024 4096; do
  for r in 1 2 3; do
    # compact cooldown + drop_caches
    sudo rados bench -p ${POOL} 60 seq -t ${t} --run-name ${RUNNAME} \
      | tee rados-seqread-t${t}-r${r}.txt
  done
done

# ========== Phase 4: Random read sweep ==========
for t in 128 1024 4096 16384; do            # 16384 与 JuiceFS 128job×iodepth128 同并发
  for r in 1 2 3; do
    # compact cooldown + drop_caches
    sudo rados bench -p ${POOL} 60 rand -t ${t} --run-name ${RUNNAME} \
      | tee rados-randread-t${t}-r${r}.txt
  done
done

# ========== Phase 5: Cleanup ==========
sudo rados -p ${POOL} cleanup --run-name ${RUNNAME} 2>/dev/null
# compact cooldown（清理 tombstone，为后续 JuiceFS 测试准备干净 pool）
```

> **关键**：
> - `-b 262144` 只在 write 模式有效（设定对象大小为 256K），seq/rand 模式不能用 `-b`，对象大小由预填 write 决定。
> - `--run-name` 用于标记对象，cleanup 只删除该 run-name 的对象。
> - **每档每轮之间必须 compact cooldown + drop_caches**，否则前一档遗留的 LSM 状态会污染下一档（前轮 -t1024→-t4096 连锁退化到 168）。
> - compact 验证：`compact_running=0` + `compact_queue_len=0` + `get_latency avg < 10μs`（三指标 + get_latency 四绿才继续）。
> - 方差判据：Min/Max IOPS < 0.7 或 Stddev/Avg > 15% → 该轮作废重采。
> - `-t 16384`：157 有 1007 GB RAM，默认 8MB 栈 × 16384 = 128 GB，在可用范围内。

**数据处理与产出**：
- 每档每模式保存 3 份原始 txt，summary 中每档取 3 轮 Bandwidth 中位数，并列出 Stddev IOPS / Min IOPS / Max IOPS。
- 三种模式分别列表，不跨模式相除。
- **禁止**写出"后端天花板=某单点值"、"FUSE 开销=X%"这类由挑轮次或跨工具相除得来的结论。

---

## 四、固定配置

### 4.1 JuiceFS format（不变）

```bash
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
  "${META}" juicefs-prod
```

### 4.2 JuiceFS mount（按组不同）

> **注意**：`--storage`、`--bucket`、`--access-key`、`--secret-key`、`--block-size` 是 format-time 选项，mount 时从 format 元数据读取，无需在 mount 命令中重复。以下命令已去掉冗余的 format-time 选项。

```bash
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"

# 组 A/C (default)：
juicefs mount -d --max-uploads 150 --cache-size 0 "${META}" "${MNT}"

# 组 B/D (ra0)：
juicefs mount -d --max-uploads 150 --cache-size 0 --max-readahead 0 "${META}" "${MNT}"
```

### 4.2.1 清卷序列（两处使用：seq 测试后/randwrite-true 前、randwrite-true 后/layout 前）

> **⚠️ 关键**：`juicefs format` 不删除任何 pool 对象，只重置 TiKV 元数据。必须用 `juicefs destroy` 删除 pool 中 JuiceFS 拥有的对象。`destroy` 需要正确的 UUID（从 `juicefs status` 提取），不能传卷名。

```bash
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"

# 1. 卸载
juicefs umount "${MNT}"

# 2. 等会话过期（JuiceFS session TTL ~65s，不等待会导致 destroy 失败）
sleep 65

# 3. 提取 UUID（关键！不能传卷名，必须传 UUID）
UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)

# 4. destroy（删除 pool 中 JuiceFS 拥有的对象 + TiKV 元数据）
[ -n "${UUID}" ] && juicefs destroy "${META}" "${UUID}" --yes

# 5. compact cooldown（destroy 产生大量 tombstone，必须 compact 清理）
for osd in 0 1 2 3 4 5; do sudo ceph tell osd.${osd} compact 2>/dev/null; done
# 轮询至 compact_running=0（见 §4.4）

# 6. format（初始化新卷元数据）
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
  "${META}" juicefs-prod

# 7. mount（按组选择 mount 命令，见 §4.2）+ mkdir
# 组 A/C: juicefs mount -d --max-uploads 150 --cache-size 0 "${META}" "${MNT}"
# 组 B/D: juicefs mount -d --max-uploads 150 --cache-size 0 --max-readahead 0 "${META}" "${MNT}"
mkdir -p "${TEST_DIR}"
```

> **destroy vs format vs pool delete**：
> - `juicefs format`：只重置 TiKV 元数据，**不删任何 pool 对象**。单独使用无效。
> - `juicefs destroy`：删除 pool 中 JuiceFS 前缀的对象 + TiKV 元数据。**标准清卷方式**。需正确 UUID。
> - `ceph osd pool delete + create`：删除全部对象（核弹）。仅在 destroy 失败或孤儿对象累积时使用。
>
> **destroy 的代价**：大卷 destroy 耗时较长（老集群 1.4M 对象 ~21 分钟），产生 RocksDB tombstone 积压。destroy 后必须 compact cooldown。

### 4.3 通用 fio 参数

```
--bs=256k(读)/4M(写) --direct=1 --group_reporting
--write_bw_log=<prefix> --log_avg_msec=1000
```

> **不加 `--per_job_logs=0`**：保持默认 `per_job_logs=1`，确保每个 job 生成独立 bw_log 文件。

### 4.4 每轮跑前 / 铺盘后

```bash
# 157 + 3 slave 上执行（冷态必做）
sync && echo 3 > /proc/sys/vm/drop_caches
# 157 上清空 bw_log 目录（经 ssh_to_client）
rm -f /tmp/jfs-bw/*
```

> **layout 铺盘后、随机项开测前必须跑 §3.2 compact cooldown**（`compact` 命令 + 轮询至 `compact_running=0`），否则铺盘的 128G 写积压会污染 randread 首轮。restart OSD 不清积压，必须 compact。
> 高强度写项（randwrite-真写、randrw、randwrite-覆写）之间同样建议 compact cooldown。

---

## 五、数据处理

### 5.1 §8.3 稳态中位数（所有 time_based 项）

- **1-job 项**（seqread）：读 `seqread_bw.1.log`，截首 1/4，取中位数 / 1024 → MiB/s
- **16-job 项**（mseqread）：glob 全部 `mseqread_bw.*.log`（16 个），按时间戳对齐求和，截首 1/4，取中位数 / 1024
- **128-job time_based 项**（randread / randwrite-true / randwrite-ow / randrw，每轮各 128 个 per-job 文件）：glob 全部 `<prefix>-r<i>_bw.*.log`，按时间戳对齐求和，按 `data_direction` 分读(0)/写(1)，截首 1/4，取中位数 / 1024。
  - randread 只有 d=0；randwrite-true / randwrite-ow 只有 d=1；randrw 有 d=0+d=1（R/W 分列）。
- **写类必须走稳态中位数**：randwrite/randrw 的写受 JuiceFS 客户端写缓冲暂态影响（fio 平均偏高约 7-8%，甚至超网卡线速），**不能取 fio 平均行**，必须 §8.3 稳态中位数。
- REPEAT=3：取 3 轮 §8.3 值的中位数（第 2 大），不取平均、不挑轮次。

### 5.2 定量项（seqwrite/mseqwrite/layout）

- 取 fio `Run status group 0 (all jobs)` 的 `bw=` 值（= total_data / total_time）
- 定量测试无爬升段问题，fio BW 即准确值

### 5.3 randrw R/W 分列

- R 和 W 分别报，不合计（读=入向、写=出向，全双工独立）
- 分别对照验收线评估

---

## 六、验收判据

| 口径 | 验收线 | 依据 |
|------|--------|------|
| 不限速 | 单项 ≥ 6250 MiB/s | 100GbE 网卡半速 |
| 限速 | 单项 ≥ 59 MB/s | 1Gbps 网卡半速（118/2；聚合上限 3×118=354 MB/s）。**注意单位=MB/s（十进制），与不限速的 MiB/s 不同，勿混** |

- 稳态中位数 ≥ 验收线 = ✅ 达标
- 稳态中位数 < 验收线 = ❌ 未达标
- 单客户端 FUSE 是预期瓶颈，不限速口径下单项未达 6250 不代表后端能力不足

---

## 七、环境前提

- 集群已部署（01-1 部署的 Ceph EC4+2 + TiKV + JuiceFS），fsid `7bb47ec2-8061-11f1-a671-97520597268c`
- JuiceFS 版本 `1.3.1+2025-12-02.e0032b2`（含 eaf3d21f loadRange 修复）
- 157 CPU: Intel Xeon E5-2683 v4, 64 逻辑核
- 不限速网络：100GbE 双网分离（public=10.3.1.0/24, cluster=10.3.2.0/24）
- 限速网络：eno12409 10GbE + TBF 1Gbps（MON/OSD 切到 10.114.1.x）
- 红线：不动 157 内核/100GbE 网卡/RoCE/md0（WekaIO 红线）

---

## 八、产出清单（每组结果目录必须包含）

```
${RESULTS_DIR}/
├── commands.sh                         # 完整可执行命令记录
├── env-snapshot.txt                    # 测前环境快照（ceph -s / JuiceFS version / mount 选项 / tc qdisc）
├── ceph-status-after.txt               # 测后 Ceph 状态
├── seqread.txt + seqread_bw.1.log      # §9.1 + §9.2
├── seqwrite.txt + seqwrite_bw.1.log
├── multi-seqread.txt + mseqread_bw.1~16.log   # 16 个 per-job 文件
├── multi-seqwrite.txt + mseqwrite_bw.1~16.log
├── randwrite-true-full.txt + randwrite-true-r{1,2,3}_bw.1~128.log  # §6.2 真随机写(fresh)
├── layout.txt + layout_bw.1~128.log    # 128 个 per-job 文件
├── randread-full.txt + randread-r{1,2,3}_bw.1~128.log  # 3 轮 × 128 文件
├── randrw-full.txt + randrw-r{1,2,3}_bw.1~128.log
├── randwrite-ow-full.txt + randwrite-ow-r{1,2,3}_bw.1~128.log      # §6.4 覆写(复用layout)
└── summary.md                          # 汇总（§8.3 稳态中位数 + fio 聚合行对照）
```

> **验证脚本**（测完每组后执行，在 `${RESULTS_DIR}` 内）：
> ```bash
> for prefix in seqread seqwrite mseqread mseqwrite \
>               randwrite-true-r1 layout randread-r1 randrw-r1 randwrite-ow-r1; do
>   count=$(ls ${prefix}_bw.*.log 2>/dev/null | wc -l)
>   case $prefix in
>     seqread|seqwrite) expected=1;;
>     mseqread|mseqwrite) expected=16;;
>     *) expected=128;;
>   esac
>   echo "$prefix: $count / $expected files $([ "$count" = "$expected" ] && echo OK || echo 'MISSING')"
> done
> ```

---

## 八·五、分组交付（必须遵守，防整批失败前功尽弃）

本任务 40 项、含铺盘 + 每轮 drop_caches + compact cooldown + 限速组切网络，是**长时连续测试**（粗估十几~二十几小时）。**严禁一口气跑完再统一处理**，必须按组分段交付：

1. **按组独立结果目录**：A/B/C/D 各建独立 `${RESULTS_DIR}`（如 `prod-fullretest-A-nolimit-default-<ts>/`），互不覆盖。
2. **每组测完立即三件事**（做完才能进下一组）：
   - ① 用 §八验证脚本核对 per-job bw_log 数量全部齐（128/16/1），**不齐则该组重采，不得进下一组**；
   - ② 跑 §5 数据处理，产出该组 `summary.md`（§8.3 稳态中位数 + fio 聚合行对照 + 达标判定）；
   - ③ 回填该组真值到 `doc/deploy-log/results-table.md`。
3. **每组开测前**：`ceph health` 必须 `HEALTH_OK`、OSD 全 `up`；确认 mount readahead 选项、（限速组）`tc qdisc show dev eno12409` 确认 TBF 生效、`ceph -s` MON/OSD 在 10.114.1.x。
4. **组间检查点汇报**：每组完成后向人工反馈"该组 10 项达标情况 + 是否有异常轮次 + per-job 文件数校验结果"，确认无误再启下一组。任一组出现系统性异常（如超网卡线速、R/W 严重不均衡、bw_log 缺失）**立即停下报告，不盲目续跑**。
5. **顺序建议**：先跑不限速 A/B（不切网络，A→B 仅重挂改 readahead）；确认两组干净后再切 `config-limit.sh` 跑 C/D。B→C 切网络后须重新验证环境（第 3 条）再开测。

---

## 九、总结

本任务书的核心目的是：**用正确方法一次性跑完全量基线，彻底解决 5 轮测试遗留的数据采集缺陷**。七条红线确保：

1. per-job bw_log 全量保留（不再只拷 1 份）
2. randrw 用方案 A 消除冷启动失真（不再 create_on_open + 空目录）
3. REPEAT=3 严格取中位数（不取平均、不挑轮次）
4. 限速测试验证 TBF 生效（不再缺网络环境验证）
5. 每组记录完整命令（不再缺 commands.sh）
6. 每轮清空 bw_log 目录（不再被覆盖丢失）
7. `--openfiles=128`（= numjobs，不再用 100 制造假瓶颈）

完成后产出 4 组（A/B/C/D）× 10 项 = 40 项数据（含 rados bench 后端裸能力 + randwrite 含真写/覆写两口径），全部带 per-job bw_log 或 rados bench 原始输出，可执行 §8.3 正确聚合，形成方法论无瑕疵的基线。
