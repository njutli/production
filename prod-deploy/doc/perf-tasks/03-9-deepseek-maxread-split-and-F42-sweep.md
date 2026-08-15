# 03-9-deepseek：`-o max_read` 读写分离路线验证（现网原版二进制）+ F42 段1 重测 v3（只读 sweep）

> 任务书类型：**两个 P0 段**（段A：无补丁过渡路线验证；段B：读侧串行资源定位）+ 三个 P2 附加段（段A2 并发读写共享性、段C 负控、段D TiKV 侦察）
> 作者：DeepSeek　｜　日期：2026-08-13　｜　执行方：GLM
> 母文档：03-7-lite（段1 三版失败记录、§5.1 预登记预测）、03-8（FlushTo 竞态补丁）、bugzilla-20260813（§5.3 边界预测）
> 🔴 **所有统计量由 DeepSeek 计算，GLM 只出原始数字与原文粘贴**（同 03-7-lite/03-8 口径）
> 🔴 脚本：本地 `scripts/FULLBASELINE/debug/t39-nsbgate.sh`（判档门）、`t39-segA.sh`、`t39-segB.sh`，scp 到 157 `/tmp/` 后执行。脚本已在本地验证：ns/B 门对 03-7L 已知好/坏档精确复现（4.789 FAIL / 3.443 PASS）；jobfile 生成对 fio 3.41 `--parse-only` 全绿。

---

## ⚑ 计划线

```
03-6  完成：--max-fuse-io 256K ⇒ randread +115.6%、randrw +52.3%；顺序读零收益
03-7L 完成：256K 纯 randwrite 崩塌 5.8×（−82%）⇒ 固化被阻；段1 三次未定位 F42
03-8  执行中：写侧崩塌根因 = 上游 FlushTo 登记竞态（bugzilla INTERNAL-2026-08-13-001），补丁 A/B 验证中
        │
        ├─ 03-8 段1 通过 ─→ 补丁 256K 路线成立（生产需携带定制二进制）
        └─ 03-8 段1 失败 ─→ 唯一现网路线 = 本任务段A（-o max_read 读写分离）
              │
★ 03-9（你在这里）：
  段A（P0，~1.5h）：原版二进制 + --max-fuse-io 128K -o max_read=262144
        ⇒ 读请求 256K（吃 +115.6%）+ 写请求 128K（避开 FlushTo 竞态）
        ⇒ 判：randread 落 [3906,4219] 且 randwrite 落 [2817,3397]
  段A2（P2，~10min）：同挂载 randread+randwrite 并行 ⇒ 判 F42 是否读写共享
  段B（P0，~1.4h）：F42 段1 v3——fio jobfile 独占文件子集（v2 争用教训）
        ⇒ 并发 8..128 × 3 pass + I2b 逐线程 CPU ⇒ 点名 ~4.1 GiB/s 串行资源
  段C（P2，~0.25h）：负控 bs=128k randwrite @256K 挂载（bugzilla §5.3 边界预测：仍塌）
  段D（P2，~0.25h）：TiKV/PD 指标可达性 + randwrite 期间抓取（F44 候选验证输入）
        │
  段A 通过 ─→ 256K 固化有无补丁路线可选；上游 issue 附证据
  段B 点名 ─→ 另起任务（客户端 librados/messenger 路径调优）
一句话：用现网原版二进制保住读 +115.6% 且写不塌（段A），点出读侧 4.1 GiB/s 串行资源（段B），
      顺带判 F42 读写共享性（段A2）并给 meta 墙（F44）抓服务端证据（段D）。
```

---

## 〇、背景

03-8 的补丁路线严格更优（randrw 写侧 1939 vs 1274），但**依赖定制二进制**。生产决策需要知道：**不带补丁的现网原版二进制**能否保住 03-6 的全部读侧收益且写侧不塌。路线原理（`-o max_read`）：

- `--max-fuse-io` 内部同时设置 FUSE `max_read` 与 `max_write`；`juicefs mount -o value` 会把原始选项**透传进 FUSE 参数表并覆盖**前者 ⇒ 可以只改其一。
- **读侧要 256K**：单请求带宽 = 尺寸÷延迟，尺寸×2、延迟仅×0.92 ⇒ randread +115.6%（03-6 机制）。
- **写侧必须留 128K**：max_write=256K 时每个 256K 写恰好攒满一个新 slice 的首笔写，撞上 `id==0` 竞态被 FlushTo 永久跳过 ⇒ 崩塌 5.8×（03-8 根因）；128K 时内核把 256K 应用写拆成两笔**连续** 128K，第二笔续写时编号已就绪 ⇒ 正常上传（PUT/写op=0.52）。

若 `-o` 透传顺序不生效，备选对称形式 `--max-fuse-io 256K -o max_write=131072` 等价。**是否生效以 `/proc/mounts` 实测为准，两种形式都在段A 覆盖。**

段B 背景：F42（客户端 ~4.1 GiB/s 精确饱和的串行资源，仅用 6.2/96 核，randread 4058 被钉死）是读侧 6250 的最后一道已知墙。03-7-lite 段1 三次失败均为方法问题（v1：fio 选项值 4096 字符上限 + 脚本无挂载步骤；v2：共享文件清单致多 job 争用同一组文件，sweep 20~111 MiB/s，锚点 4078 证明 directory 模式正常）。v3 改用 **fio jobfile：每个并发点生成 J 个 job 段、每段独占 128/J 个互斥文件**——总工作集恒 128 GiB、总打开数恒 128、无跨 job 争用、不触 4096 上限。

---

## 一、目标

- **段A（唯一通过/不通过项）**：原版二进制 + 读写分离挂载下，**randread 与 randwrite 同时落各自平台**（判据见 §三.1）。通过 ⇒ "无补丁过渡路线"成立；不通过 ⇒ 如实记录，由 DeepSeek 判定（如写向落 256K 平台即 `-o` 未生效的证据）。
- **段A2（P2，只报数据）**：同挂载 randread+randwrite 并行，预登记 A2a/A2b/A2c 三结局对账（§三.4）——直接回答"读墙 F42 与写墙 F44 是否共享"这一 6250 路径问题。
- **段B（只报数据，尽力点名，无通过/不通过）**：交付并发-吞吐-延迟曲线 + I2b 逐线程 CPU；预登记预测 H1/H2/H3 跑完对账（§三.2）。点名成功与否都要回报。
- **段C（P2，只报数据）**：负控验证 bugzilla §5.3 边界（写尺寸<块大小仍塌），供上游 issue 附件。
- **段D（P2，只报数据）**：TiKV/PD metrics 端点可达性 + randwrite 期间 1Hz 抓取（F44 候选的服务端证据，供 DeepSeek 分析；抓不到只记录，不重试不推断）。

---

## 二、口径与矩阵

- 挂载（段A）：`--max-uploads 150 --cache-size 0 --max-fuse-io 128K -o max_read=262144`（首选 FORM1）；备选 FORM2 `--max-uploads 150 --cache-size 0 --max-fuse-io 256K -o max_write=131072`。二进制 = 现网原版 `juicefs`。⛔ 不碰 `/usr/local/bin/juicefs`。
- 挂载（段B）：`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`，现网原版（读路径与补丁无关）。
- 效应项口径（段A）：走 V4（`SKIP_REMOUNT=1` 单实例，`REPEAT=2`，`RUNTIME=180`，`OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000`）。V4 项参数：randread/randrw/randwrite 均 `bs=256k iodepth=128 numjobs=128 direct=1`。
- 段B sweep：`j ∈ {8,16,32,64,128}` × 3 pass（升/降/升，F17），每点 180s + 20s 沉降；jobfile 参数与 V4 randread 相同（`bs=256k rw=randread ioengine=libaio iodepth=128 direct=1 fallocate=none file_service_type=random filesize=1g size=1g time_based runtime=180`）+ `--readonly` 旗标。
- 段C：`bs=128k rw=randwrite`，directory 模式 `storage_test.*.0`，numjobs=128，1 轮。
- 判档门（段A/段B 共用）：mseqread 2 轮，ns/B = Δ`fuse_ops_durations_histogram_seconds_{sum,total}` ÷ Δ`juicefs_fuse_read_size_bytes_sum`/Δ`juicefs_fuse_ops_total_read`（`t39-nsbgate.sh` 已实现），参照 **3.287**，偏离 **>10%** ⇒ 丢弃重挂；**每次重试必须换 label**（§二.10.4.1 硬规则，03-7L 段2b 复用 label 被累计行稀释的教训）。
- 🔴 锚点 BW 与 4058 的 ±3% 比对**仅作描述**，不作中止条件（防基线漂移误杀，§二.10.4.2 教训：03-7L 段2b 用 raw 平台门 6/6 误杀）。

---

## 三、判据（每条指名数据来源）

### 3.1 段A（label `T39-A1`，效应项）

| # | 判据 | 值域 | 数据来源（文件:字段） |
|---|---|---|---|
| A1 | randread 中位数 | **[3906, 4219]**（256K 平台 4027~4096 ±3%，REFERENCE-VALUES 表一） | 157 `/tmp/opencode-fullbaseline-v4/rounds.tsv` 列3，label=T39-A1、item=randread |
| A2 | randwrite 中位数 | **[2817, 3397]**（128K 平台 2942~3258 ±4.26% 门槛，REFERENCE-VALUES 表一/四） | rounds.tsv 列3，label=T39-A1、item=randwrite |
| A3 | 档位门 | ns/B ∈ [2.958, 3.616]（3.287±10%） | `probe-gate.log` + 探针轮次 `jfs-stats-{pre,post}.txt` |
| A4 | 挂载生效 | `/proc/mounts`：max_read=262144；max_write 可见时 =131072 | `arm-verify.txt` 全文 |
| A5 | 写侧机制 | randwrite 轮内平均写请求尺寸 ≈ **131072**（Δ`juicefs_fuse_write_size_bytes_sum`÷Δ`juicefs_fuse_ops_total_write`） | 各轮 `jfs-stats-{pre,post}.txt`（DeepSeek 复算） |
| A6 | 环境门 | 全程 `HEALTH_OK`、8 run 无 SMOKE、pid/starttime_ticks 跨阶段恒定 | `health.txt`、`instances.txt`、V4 轮目录 `SMOKE*` |

- **通过 = A1 且 A2**（A3-A6 为一致性护栏）。A2 若落界外：先查 A5（写请求尺寸）与档位，再下结论；F11 注记：03-7L 同量级对象数下 WF1/WF2 randwrite 2968~3701 与历史平台一致 ⇒ 对象数影响小，但落界外时须点名对象数证据。
- **randrw（描述性）**：读向与 256K 平台 **1931~1978**、写向与 128K 平台 **1263~1278** 对照（REFERENCE-VALUES 表一，禁相加）。写向若落 256K 平台 ⇒ `-o` 未对写侧生效（与 A4 矛盾 ⇒ 异常上报，不自行解释）。

### 3.2 段B（label `T39B` 系列）

| # | 判据 | 值域 | 数据来源 |
|---|---|---|---|
| B1 | 判档门 | ns/B ∈ [2.958, 3.616] | `probe-gate.log`（mseqread 探针，`t39-nsbgate.sh`） |
| B2 | 锚点口径 | 描述性：BW vs **4058±3%**；偏离>3% 须在报告显式标注并继续 | `s1v3-bw.tsv` 行 `T39B-anchor` + `fio-T39B-anchor.txt` |
| B3 | 预登记对账 | H1/H2/H3 三选一（见 §三.2.1） | `s1v3-bw.tsv`（15 行 sweep）+ `fio-*.txt` 的 `READ: bw=`/lat 行 |
| B4 | I2b 点名 | 是否存在某线程稳定 ≥95% 单核；是⇒点名（comm+tid）；否⇒排除单线程假设（回报转查锁/内存带宽） | `i2-threads-*.tsv`（DeepSeek 复算） |
| B4+ | pprof 点名 | 每点 goroutine dump + 锚点/j128-p2 30s CPU profile ⇒ 饱和 goroutine 直接点名（比 I2b 线程级更强；metrics 端口已实测可访问） | `pprof-goroutine-*.txt`、`pprof-cpu-*.pprof`（DeepSeek 分析） |
| B5 | 首点校验 | 每点 rc=0 且有 `READ: bw=` 行 | `s1v3-bw.tsv` 列4/5 |

#### 3.2.1 预登记预测（03-7-lite §5.1，开跑前已登记，跑完对账，禁事后编故事）

- **H1**：吞吐在 j=8~16 即近 4.0 GiB/s，此后并发×8 吞吐不动、延迟线性涨 ⇒ 硬饱和点存在。
- **H2**：拐点在中段，拐点处并发 = 串行资源服务台数。
- **H3**：低并发单位吞吐更高（128 过饱和）⇒ 只作 roofline 参考。
- **交叉校验**：sweep 的 j=128 点（1 文件/job）应与锚点（directory 模式）一致；差 >3% ⇒ 两种 file 指派模式在 128 并发有实质差异，标注并以锚点为准。

### 3.3 段C（label `T39C-bs128k`，只报数据）

| # | 判据 | 值域 | 数据来源 |
|---|---|---|---|
| C1 | 负控 | 描述性：bw **<1000** 判"塌"（对照 128K 平台 2942~3258）；≈2942+ 则与 bugzilla §5.3 预测矛盾，如实上报 | `s1v3-bw.tsv` 行 `T39C-bs128k` |

### 3.4 段A2（label `T39A2-rwcon`，只报数据，预登记对账）

| # | 判据 | 预登记结局 | 数据来源 |
|---|---|---|---|
| A2-1 | 读向 BW | **A2a 独立**：读 ≈[3906,4219] 且 写 ≈[2817,3397]，合计 ≈7 GiB/s | `s1v3-bw.tsv` 行 `T39A2-rwcon-read/write` + 两个 `fio-*.txt` |
| A2-2 | 写向 BW | **A2b 共享**：合计被钉在 ~4.1 GiB/s（F42 墙），读向被写挤占 <4058 | 同上 |
| A2-3 | 一致性 | **A2c 部分共享**：合计介于两者；逐秒 log 看挤占模式 | `bwlog/T39A2-rwcon-*_bw.*.log`（DeepSeek 复算） |

含义：A2a ⇒ 读墙（F42）与写墙（F44 meta）**互不共享**，6250 各治各的；A2b ⇒ 客户端串行资源**读写共用**，两向同时达标不可行，路线必须换。注意段A2 跑在段A 已判档的同实例上（pid 恒定由 `instances.txt` verify 行证明）。

### 3.5 段D（TiKV/PD 侦察，只报数据）

| # | 判据 | 值域 | 数据来源 |
|---|---|---|---|
| D1 | 可达性 | 6 个端点逐个 http 码（2379/metrics、9090/metrics、20180/metrics、20181/metrics ×3 主机） | `tikv-reach.log` |
| D2 | 抓取 | randwrite 期间 1Hz 指标子集（grpc/PD/TiKV scheduler 相关前缀） | `tikv-metrics-T39-A1.txt`（行数；内容 DeepSeek 分析） |

⛔ 抓取失败只记录不重试；任何"TiKV 是/不是瓶颈"的结论都不由 GLM 出——原始数据交 DeepSeek（R3/R4）。

---

## 四、执行步骤

**步骤 0（测试前）**：通读 skill 并确认关键点——`TESTING-GUIDE.md`（§1.3 compaction 三指标 / §2.2 health / §3 cooldown）、`test-commands-reference.md`（§8.3 稳态中位数）、AUTHORING-GUIDE（§二.8 / §二.10 / §二.11）。⛔ 本任务**无 layout、无 destroy、无 pool 操作**；全程只 mount/umount + fio。

**段A（~1.5h，`bash /tmp/t39-segA.sh`）**：
1. scp 三脚本到 `/tmp/`，`chmod +x`；开跑前 `bash -n` 三个脚本 + `md5sum` 与任务书比对。
2. 跑 `t39-segA.sh`：健康检查 → FORM1 挂载 + `/proc/mounts` 验证 → mseqread 判档门（≤3 试×2 形式，重试换 label）→ randread→randrw→randwrite（V4，同实例；randwrite 期间自动做段D 抓取）→ **段A2 并发读写** → health 落盘。
3. 每步后 `tail` `progress.txt`/`probe-gate.log` 确认推进；任何 STOP ⇒ 停并回报。

**段B（~1.4h，`bash /tmp/t39-segB.sh`）**：
4. 段A 结束后跑 `t39-segB.sh`（自带段前 compact cooldown）：挂 256K + 判档门 → 锚点 → 15 sweep 点 → 段C（默认跑）→ 恢复 128K 挂载。
5. 砍单开关：`RUN_SEGC=0 bash /tmp/t39-segB.sh` 跳过段C；pass3 可砍（改脚本内 `for p in 1 2 3` 为 `1 2`，改动须报告声明）。

**末步（测试后）**：对照 skill 逐条复核执行合规并记录——① 未动 `/usr/local/bin/juicefs`、未碰 `/tmp/ray`；② 写项后 compact cooldown 已轮询至全绿；③ 每 fio 前 V4 内部 drop_caches（段B 非 V4 点按 v2 先例不 drop，等温口径，须在报告声明）；④ 统计口径 §8.3；⑤ randrw 分向报。**任一不符显式标注，不得默默跳过**（§二.8）。

---

## 五、交付物（GLM，全部落盘 157 `/tmp/opencode-t3.9/`）

1. `arm-verify.txt` 全文（段A 各次挂载 max_read/max_write + want + EFFECTIVE form；段B max_read；RESTORED 行）
2. `instances.txt` 全文（pid + starttime_ticks + 全部 verify 行）
3. `probe-gate.log` + `remount-retry.log` 全文（重挂次数逐臂报出；**重试 label 必须不同**）
4. `rounds.tsv` 中 `T39-A1`、`PROBE-T39-*` 全部行；`bw-raw.tsv` 全文（段A）
5. `s1v3-bw.tsv` 全文（段B 锚点 + 15 sweep + 段C）
6. 5 个 jobfile（`job-j{8,16,32,64,128}.job`）原件
7. 各 `fio-*.txt` 的 `READ/WRITE: bw=` 行（逐点逐 pass）
8. `i1-jfsstats-*.tsv`、`i2-threads-*.tsv`、`i2-proc-*.tsv` 行数逐文件（不粘全文，DeepSeek 拉原件）
9. **pprof（F42 点名证据）**：每点 `pprof-goroutine-*.txt` + 锚点/j128-p2 的 `pprof-cpu-*.pprof` 文件清单与大小；每挂载 `metrics_port`（`arm-verify.txt`/`instances.txt` 内）
10. `health.txt`、`wrapper.log`、`progress.txt` 全文；段A 各轮 `mount-cmd.txt`（含 `-o` 参数行）
11. 段D：`tikv-reach.log` 全文 + `tikv-metrics-T39-A1.txt` 行数
12. 段A2：`fio-T39A2-rwcon-{read,write}.txt` 的 bw 行 + `s1v3-bw.tsv` 对应行
13. 异常与偏差逐条（pid 变化、rc 非零、SMOKE 残留、锚点偏离、写尺寸≠131072、TiKV 端点全不可达、pprof 端口未发现等）

---

## 六、风险与污染规则

1. **`-o` 透传不生效**：/proc/mounts 验证失败即换 FORM2；两形式均败 ⇒ 停，回报（⛔ 不许在未验证的挂载上跑效应项）。
2. **坏档**：判档门 + 重试换 label + 单挂载三项联合判定（A1+A2+A3 同时落界与坏档假设矛盾）；任何"成立"结论附坏档压力测试（d_max=−30%，§二.10.4.4）。
3. **漂移**：锚点/BW 平台比对只作描述不作中止（§二.10.4.2）；若判档 PASS 但效应项偏离平台，报告显式标注"同会话基线漂移"证据链。
4. **写项污染读项**：段A 写项（randrw/randwrite）后 V4 已做 aggressive_cleanup；段B 段首另有 compact cooldown 兜底（§二.4）。
5. **F11 对象拐点**：randwrite 绝对值与历史平台对比时，交付物含 `t37l-objwatch.sh` 输出（OBJ_GATE=1 已开）。
6. ⛔ 全程：不碰 `/usr/local/bin/juicefs`、不碰 `/tmp/ray`、无 layout/destroy、段B 只读（`--readonly` 旗标 + 禁新文件）。
7. 时钟：157 时间 = WSL − 1h；归档 fio mtime 与报告时间线有 ~55min 系统偏差（已记档，报告照录）。
8. **与 03-8 的衔接**：若 03-8 已执行其段3（`-o max_read`），段A 与其重叠——段A 仍执行（03-8 段3 无 randrw、无写请求尺寸行为学验证）；若 03-8 段1 通过，段A 的定位 = 无补丁过渡路线量化，结论措辞由 DeepSeek 定。

---

## 七、时间预算与砍单顺序

| 段 | 内容 | 预算 |
|---|---|---|
| A | 分离挂载验证（含重挂余量） | ~1.5h |
| A2 | 并发读写共享性 | ~0.2h |
| B | F42 sweep v3 | ~1.4h |
| C | 负控 | ~0.25h |
| D | TiKV 侦察（含在段A randwrite 内） | ~0.1h（另计） |
| **合计** | | **≤3.5h**，白天/傍晚单会话可跑 |

砍单顺序：**段C → 段D → 段B pass3 → 段A2 → 段A 的 randrw 轮次**。⛔ 段A randread+randwrite 与段B 锚点+pass1/2 不可砍。

---

## 八、红线汇总

- ⛔ 禁动：`/usr/local/bin/juicefs`、`/tmp/ray`、内核/网卡/RoCE/md0/WekaIO 路径（157 有业务在跑）。
- ⛔ 无 layout / destroy / pool 操作；段B 全程只读。
- ⛔ 判档门 = ns/B 判别器（>10% 阈），重试必须换 label；禁 raw 吞吐 ±3% 门当判档。
- ⛔ 统计全部由 DeepSeek 复算；GLM 出原始数字 + 原文粘贴（§二.11）。
- ⛔ randrw 读/写分报禁相加；效应 = (处理−对照)/对照；一律中位数。
- ⛔ 脚本改动（砍 pass3 等）必须报告声明；改变量（挂载形式、item、轮数、判据）先停后报。
