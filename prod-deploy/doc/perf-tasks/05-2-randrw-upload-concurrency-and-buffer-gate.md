# 05-2 任务书：randrw 上传并发闸门验证（1 MiB 主验证 + 256 KiB 条件筛选）

> 日期：2026-09-15（2026-09-15 按 Opus↔GPT 两轮复核一致结论精简，原稿的 256K 主判、1M 2×2
> 与 4M 三臂 Phase V 均已修订/删除）
>
> 面向：执行方采集原始证据，第二方（GPT/Luna）独立复算与裁决
>
> 状态：`COMPLETED / VALID / NO_CANDIDATE`
>
> 执行结果：RUN `20260915-141750`。Phase A 裁决 `RESOLUTION_INSUFFICIENT / SCREEN_CONTINUE=FAIL`；
> Phase B1 `uploading p95=98.15<120`，未触发 B2；Phase C 未触发。正式报告：
> `doc/perf-report/05-2-randrw-upload-concurrency-and-buffer-gate-20260915.md`。
>
> 上位计划：`doc/perf-analysis/05-block-size-adaptive-performance-comparison-plan.md`
>
> 立项依据：`doc/perf-report/audit-05-1-05-1b-bs-data-usability-and-comparison-20260915.md` §六/§七
>
> 复核一致结论：`doc/deploy-log/review-05-1-05-1b-audit-and-05-2-20260915.md`
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`（有效带宽主口径、平衡设计、噪声底、Gate 0、第二方复算）、
> `skills/TESTING-GUIDE.md` §1.3/§2.2/§3、`skills/test-commands-reference.md` §8.3、
> `skills/SYSTEM-SAFETY-SKILL.md`、`doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`

```text
03-19  randwrite inode 并行度：128→256 inode 仅 +24%~26%，明写"若 uploader 持续打满 150 才做 U300"
  ↓
04-6b  Phase C 预注册 U300（max-uploads 150→300），因先命中 FUSE1M 候选而取消，从未执行
  ↓
05-1   randrw 标准 BS 曲线 + FUSE1M 适配（1M 有 L1 信号，4M 停止）
  ↓
05-1b  卷 BlockSize 联动：B1M 强信号；B4M 受 buffer1024 混杂；B64 无收益
  ↓
审计   12/12 个 B256 大 BS 格 PUT 在途量 147.6~149.8 / 150，逐秒 gauge 全窗 =150.0
       ⇒ 1M/4M 写向天花板 = 150 槽 × 256 KiB ÷ PUT 延迟，是参数闸门而非后端能力
       ⇒ 256K 推算在途量仅 105~140/150（70%~93%），"接近"而非"顶在"闸门
  ↓
05-2   Phase A：1M 的 max-uploads 150/300 单变量配对（已完成，无候选）
       Phase B：256K 先 1 格筛选，过 PROXIMITY 门才做四格 C/T
       Phase C：仅当 U300 有效且 buffer 成为新闸门，才做 buffer 300/1024 配对
  ├─ 无材料信号 → 记录闸门已解但无净收益，randrw 大 BS 转对象大小/架构方向，05 阶段照常继续
  └─ 有材料信号 → 登记 L1 候选，另立 L2 正式效应 + 七项非劣回归后才谈交付
后续：05-3 randread/randwrite BS 曲线 → 05-4 seq → 05-5 mseq → 05-6 汇总与有方对比
```

一句话：**在 1 MiB 上把已被实测证明顶格的 `--max-uploads 150` 单变量解闸，看 randrw 能否越过
`150 槽 × 256 KiB ÷ PUT 延迟` 这条算术天花板；256K 与 buffer 只在证据触发时才测。**

## 〇、最小决策与生命周期合同

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=审计 audit-05-1-05-1b-…-20260915（1M/4M 共 12/12 格 PUT 在途 147.6~149.8/150、
              逐秒 gauge 全窗=150.0；buffer p95 全部越配置值；256K 仅有 105~140/150 的推算）；
              04-tmp3j（RADOS 256K 写 QD128=3948.86 MiB/s 未到平台）；
              05-1b M 组（B1M 解闸后 2593/2614 MiB/s，uploading 回落到 60.5）
SCREEN_CONTINUE=见 §三.3 四条材料信号（效应门 + 对象 PUT 字节吞吐同向 + READ 不回归 + 口径自洽）
SCREEN_STOP=只在非性能硬门失败时中止执行；效应 <5% 或为负一律照常跑完该 Phase 并留数
FORMAL_MATRIX=候选获批后另立 05-2b：同实例 ABBA-BAAB 8 轮 + 七项非劣回归；本任务不自动升级
NOT_IN_SCOPE=U450/U600 不预注册、不预期、不写入任何判据（避免退化成参数扫描）
ESTIMATED_WALL_CLOCK=离线准备 <=60 min；环境执行 1.5--3 h（最少 5 格、最多 13 格，纯 fio 15--39 min）

MINIMUM_DECISION_SET=Phase A（1M，U150/U300 各 2 位置，4 格，必做）
              + Phase B1（256K，U150 基线 1 格，必做筛选，不进入效应量）
              + Phase B2（256K 四格，仅 PROXIMITY 门触发）
              + Phase C（1M buffer 四格，仅 Phase A 有效且 buffer 成为新闸门）
STOP_AFTER_ANSWER=Phase A 出数即完成主问题；条件 Phase 未触发即取消，⛔ 不补"漂亮样本"
MAX_PREP_BUDGET=复用 t05-1/t05-1b 驱动与已验证分析器，脚本改动 + Gate 0 合计 <=60 min
MAX_EXECUTION_BUDGET=未经新授权只执行本任务三个 Phase 且 <=3.5 h

EVIDENCE_ROOT=/mnt/c/SunRise/test/05-2/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-05-2-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=本任务不新建/不销毁任何 JuiceFS 卷、不 layout、不改卷格式；
              只使用既有 B256 生产卷 + 固定 rw_test 资产 + RUN 专属任务挂载。
              需要收口的环境资产只有：任务挂载、fio 进程、sampler 进程、
              以及（若获授权）scrub flags 与 OSD compact 次数账
```

- `COMMON`：inventory、实际脚本与 SHA、二进制/配置身份、挂载计划、scrub 计划、`commands.sh`，
  每 RUN 一份。
- `RAW_CELL`：fio JSON+、聚合逐秒 bw log、实际 I/O 起止、挂载身份
  （PID/starttime/exe md5/**完整 cmdline**）、逐秒 JuiceFS 机制指标、客户端 sidecar、
  健康门，按 cell 增量保存。
- 身份、健康、I/O 错误、日志或 sampler 覆盖失败 ⇒ `INCIDENT_STATUS=OPEN`，未归因前不清现场。

## 一、背景、目标与边界

### 1.1 为什么做

审计从 05-1/05-1b 的原始归档复算出一个此前没人看的事实：**所有 `bs=1M/4M`、卷为 B256 的
randrw 格，上传槽都被 100% 占满**（PUT 在途 `147.6--149.8`，上限 `--max-uploads 150`；
逐秒 gauge mean=p95=max=`150.0`，12/12 格）。于是写向带宽被一条算术式锁死：

```text
写向上限 = 150 (槽) × 256 KiB (对象) ÷ PUT 延迟
  PUT 19.95 ms → 1880 MiB/s   （1M-C1 实测对象层 1849）
  PUT 16.29 ms → 2302 MiB/s   （1M-T1 实测对象层 2284）
```

而同批证据显示三处都有余量：对象层总流量 B256 只有 `4.12--5.15 GiB/s`，B1M/B4M 已达
`6.07--6.15 GiB/s`；直接 RADOS 256 KiB 写在 QD128 达 `3948.86 MiB/s` 且未到平台；
客户端只用 `7.75--10.20` 核 / 64 核、NIC 单向 `3220 MiB/s` / 100GbE（约 27%）。

`max-uploads 150→300` 已被 03-19、04-6b Phase C、05-1b §2.6 三次预注册，但**从未在写侧执行过**
（01-3 测过 300/600，但对象是 randread，该参数控写不控读）。

⚠️ **256K 的状态是推算而非实测**（审计 §六.7）：`1749.3 ÷ 0.25 = 6997 PUT/s`，
乘同配置 PUT 延迟 `15.03--19.95 ms` 得在途量 `105--140 / 150`（70%--93%）。
因此 256K 只能作为**条件筛选**，主验证点放在证据最硬的 1M。

`buffer-size` 在所有大 BS 格都越过配置值（p95 `334--1234 MiB`），05-1b 把它当"两臂公共条件"
从 300 抬到 1024，结果让 B256/4M 对照臂掉了约 15%（`2201.56→1873.85`），
读放大同步从 `1.06` 升到 `1.37`。⇒ 它是第二道闸，但**必须在 uploads 解闸后再单独配对测**，
⛔ 不能与 uploads 混在一个 2×2 里（原稿的 2×2 只对 uploads 主效应免疫一阶漂移，
buffer 主效应与交互项与漂移共线，见复核记录 §二.2）。

### 1.2 唯一主问题

固定 `128 job × iodepth 128、libaio、50/50 randrw、direct=1、无缓存、writeback 关闭、
既有 B256 生产卷与固定 `rw_test` 资产、FUSE1M` 时：
**在 `fio bs=1M` 上把 `--max-uploads` 从 150 提到 300（其余逐字不变），
能否让 READ 与 WRITE 双向相对同位置对照取得至少 `M = max(5%, 2ε)` 的材料收益？**

附带问题只用于决定下一步，不单独扩矩阵：

1. 256K 规格点的 `uploading` 实际水位是否接近上限（Phase B1 一格筛选）；
2. 解闸后新的限制项落在哪一层（对象 PUT 字节吞吐是否同步上升 / buffer 是否成为新闸门）；
3. `buffer 300→1024` 在 uploads 已解闸时是否仍是负效应（Phase C，条件触发）。

### 1.3 明确不回答

- ⛔ 不重跑 05-1 标准曲线、不重跑 05-1b 的 B64/B1M/B4M 矩阵；
- ⛔ **不做 B4M 三臂净收益验证**（已按复核结论从本任务删除；B4M 维持 `NET_GAIN_UNPROVEN`
  且已撤出交付候选，只有未来明确要部署该专用卷时才另立任务）；
- ⛔ 不预注册、不预期、不执行 `max-uploads 450/600`；
- ⛔ 不扫 `max-downloads`、readahead、`async_dio`、`buffer 2048`、中间 BlockSize；
- ⛔ 不改 `bs` 之外的任何 fio 字段来制造更高峰值；
- ⛔ 不测读缓存、writeback、`writeback_cache`；
- ⛔ 不新建/销毁卷、不 layout、不修改卷 BlockSize、不新建/删除 Ceph pool、
  不改 TiKV/OSD/CRUSH 全局配置；
- L1 结果不能直接改通用生产基线；候选须另立 L2 并完成七项非劣回归。

## 二、口径与矩阵

### 2.1 fio 合同（逐字沿用 05-1/05-1b，仅 `bs` 可变）

```text
rw=randrw            rwmixread=50        ioengine=libaio
iodepth=128          numjobs=128         filesize=1G / size=1G
direct=1             fallocate=none      allow_file_create=0
openfiles=128        time_based=1        runtime=180
group_reporting=1    randrepeat=1        log_avg_msec=1000
per_job_logs=0（单一聚合 bw 日志）
filename_format=<mnt>/test_dir/rw_test.$jobnum.0
```

全部 Phase 复用既有 128 × 1 GiB `rw_test` 文件，⛔ 不 layout、不增删文件；每格前后校验
`128 个文件 × 1,073,741,824 字节`。

### 2.2 固定软件与公共挂载条件

| 项 | 固定值 |
|---|---|
| JuiceFS | `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46` |
| 卷 | 既有 `juicefs-prod`，BlockSize=256 KiB（⛔ 不修改） |
| Ceph 客户端 | RUN 私有 conf，`ms_async_op_threads=8`（交付规则是 `>= OSD 数据连接数 × 1.33`，不随本任务参数缩放） |
| 公共挂载项 | `--max-downloads 200 --cache-size 0 --metrics 127.0.0.1:<port>`，writeback 关闭，readahead 默认 |
| `--max-fuse-io` | Phase A/C = `1M`（05-1 已确认该 BS 下 FUSE1M 有 L1 信号）；Phase B = `256K`（规格点交付值） |
| `--buffer-size` | Phase A/B = `300`（交付值，固定）；Phase C 为唯一被改动项 |
| Ceph | 现有 6 OSD、EC4+2、同一数据 pool；⛔ 不新建 pool、不改 CRUSH/PG |
| 每格恢复门 | **卷内 GC → 等 objects/stored 稳定 → 三节点 TiKV pending-compaction 连续 3 点为 0 → health 门**（与 05-1/05-1b 完全一致，被动等待） |

⚠️ 每格必须落盘**完整 mount cmdline**，并由分析器断言 `--max-uploads`/`--buffer-size`/
`--max-fuse-io` 实际取值与矩阵一致（变量守卫，指导书 §二.9）。

### 2.3 Phase A：1 MiB 解闸（本任务唯一通过/不通过项，必做）

```text
bs=1M，FUSE1M，buffer-size=300（固定），唯一变量 = --max-uploads
C = 150      T = 300
顺序：C1 → T1 → T2 → C2        （位置均值两臂均为 2.5）
```

- 效应只用位置相邻配对 `T1/C1` 与 `T2/C2`；
- 同臂 `C1↔C2`、`T1↔T2` 给噪声底 `ε = max(|Δ|)`，`M = max(5%, 2ε)`；
- 若 `ε >= 5%` 记 `RESOLUTION_INSUFFICIENT`（05-1 Phase B 的 1M 同臂漂移约 `2.0%--4.5%`，
  预期可分辨）。

### 2.4 Phase B：256 KiB 规格点的条件筛选

**Phase B1（必做，1 格，⛔ 不进入任何效应量）**：
`bs=256K`、FUSE256K、`buffer=300`、`uploads=150`（**完全等于当前交付配置**），
只读取正式窗 `juicefs_object_request_uploading` 的 p95。

```text
256K_UPLOAD_PROXIMITY_GATE：正式窗 uploading p95 >= 120（= 150 的 80%，沿用 05-1b §2.6 已预注册阈值）
  触发     → 执行 Phase B2
  未触发   → 记 GATE_NOT_TRIGGERED，停止 256K 的该参数方向
```

⚠️ 命名为 **PROXIMITY（接近）而非 SATURATION（饱和）**：`p95 >= 120` 只表示"接近并发上限、
值得测试"，⛔ 不得写成"已证明 256K 上传槽饱和"；真正的持续饱和须看到接近 150 的占用比例
或等价 Little 在途量。

**Phase B2（条件，4 格）**：`bs=256K`、FUSE256K、`buffer=300`，
`C=150 / T=300`，顺序 `C1 → T1 → T2 → C2`，判据同 §2.3。

**顺序约束（复核议定）**：Phase B1 必须位于**一次完整恢复门之后**，
⛔ 不得紧接 Phase A 的高强度 1M 写入，以免累计状态压低 `uploading` 水位造成假阴性；
且 B1 与 B2 相邻执行，保证门读数与效应量落在同一状态区间。

### 2.5 Phase C：buffer 的条件配对（4 格，仅在双条件满足时执行）

```text
触发条件（两个都必须满足，由第二方从 Phase A 原始证据判定）：
  ① Phase A 的 U300 通过 §三.3 全部材料信号；
  ② buffer 成为新闸门：T 臂正式窗 used_buffer p95 越过配置值 300 MiB
     且 对象 PUT 字节吞吐不再随 PUT 在途量同向上升
矩阵：bs=1M、FUSE1M、uploads=300 固定，C = buffer 300 / T = buffer 1024
顺序：C1 → T1 → T2 → C2
```

⛔ 不做 `uploads × buffer` 的 2×2：原稿的 2×2 只能让 uploads 主效应一阶抵消漂移，
buffer 主效应（位置偏置 `−3d` 与 `−d`，同号）与交互项与漂移共线。
本任务不需要交互项来做决策，因此改为两个变量各自在平衡配对内估计，
⛔ 也不声称能估交互项。

### 2.6 机制指标（每格必采）

| 层 | 指标 | 用途 |
|---|---|---|
| 上传闸门 | `juicefs_object_request_uploading` 逐秒 mean/p95/max | 解闸是否生效、T 臂是否又打满 300 |
| 对象层（**主机制判据**） | `juicefs_object_request_data_bytes{method="PUT"}` 正式窗增量 ÷ 窗长 | **对象 PUT 字节吞吐**；见 §三.3 |
| 对象层（辅助分解） | `juicefs_object_request_durations_histogram_seconds_{count,sum}` 按 method | PUT/GET ops/s、平均时延、Little 在途量、平均对象大小 |
| 对象层（GET） | 同上 + `data_bytes{method="GET"}` | READ 是否回归、读放大是否变化 |
| 缓冲 | `juicefs_used_buffer_size_bytes` 逐秒 p95 | Phase C 触发条件之一 |
| FUSE | `juicefs_fuse_{read,written}_size_bytes_{count,sum}` | 应用侧请求粒度与放大分母 |
| 元数据 | `juicefs_transaction_durations_histogram_seconds_{count,sum}` | 事务速率/时延/在途量（状态漂移协变量） |
| 客户端 | mount 进程 utime/stime/RSS、数据网 NIC rx/tx | CPU 与网卡余量 |
| Ceph | pool bytes/ops/latency、6 OSD 利用率与 `op_w` 完成率/平均写延迟 | **记录与解释项**，见 §三.3 |
| TiKV | 三节点 pending-compaction、meta qps/延迟 | 恢复门与状态漂移协变量 |

## 三、有效性、裁决与数据来源

### 3.1 非性能硬门（失败即相关 Phase `EVIDENCE_INVALID` 并停，⛔ 不得用性能好坏删样）

| 硬门 | 原始来源 |
|---|---|
| 二进制 MD5、META、卷 Name/UUID/BlockSize 与既有生产卷一致（未被改动） | `common/identity/*`、`status-prod.json` |
| **矩阵变量守卫**：实际 `--max-uploads`/`--buffer-size`/`--max-fuse-io` 等于该格计划值 | `cells/*/mount-processes.tsv`（完整 cmdline）+ `plans/matrix.tsv` |
| 挂载 PID/starttime/exe md5 与该格登记一致，无跨格串用 | `cells/*/mount-processes.tsv` |
| 资产为 128 × 1,073,741,824 B，fio 未创建新文件 | 每格 `assets-before/after.tsv` |
| fio `rc=0`、`error=0`、实际 runtime ≈ 180 s | `formal/fio.rc`、`formal/fio.json` |
| READ/WRITE 聚合逐秒日志完整；实际 I/O 起点与登记起点差值 <= 2 s 且已打印 | `formal/bw/randrw_bw.log`、`fio-{start,end}-epoch-ns.txt` |
| sampler 覆盖正式窗，无反向计数器跳变 | `juicefs-metrics.tsv`、`sampler-status.tsv` |
| Ceph `HEALTH_OK`（若获授权暂停 scrub，仅允许单一 `OSDMAP_FLAGS` 例外）、6/6 OSD up/in、PG 全 active+clean | 每格 `health-pre/post.json`、`osd-stat.json`、`pg-state.tsv` |
| 恢复门通过：卷内 GC 完成、objects/stored 稳定、三节点 TiKV pending 连续 3 点为 0 | `recovery-*/`、`tikv-pending.tsv` |
| 无 foreign fio、无容量不足、无 I/O error、任务外挂载/进程指纹不变 | `foreign-fio.tsv`、`df.tsv`、env 快照 |

### 3.2 性能口径（⛔ 性能端点不触发删样）

- 起点 = fio 报告完成时刻 − 实际 runtime 毫秒；⛔ 禁用 fork 时刻/脚本登记起点/sampler 启动时刻；
- 逐秒日志按与自然秒的重叠时长加权摊分后逐秒求和；⛔ 禁把第 N 行当第 N 秒；
- 正式窗 `[15,175)`，输出 mean/median/秒级 CV/P10/P90 与 W1--W4 及 `W4/W1`；
- READ、WRITE 分开报告，⛔ 不相加；fio summary 只作旁证，但**必须同时落盘**
  （审计已确认小 BS 上正式窗比 summary 低 4%--9%，对外比对需要两栏）；
- 每个 Phase 用位置相邻的 `T1/C1`、`T2/C2` 算两组百分比效应；同臂相邻对给噪声底 `ε`。

四态判定沿用指导书 §二.15：`VALID` / `EVIDENCE_INVALID` / `RESOLUTION_INSUFFICIENT` /
`INCONCLUSIVE`。L1 只决定"是否值得 L2"，⛔ 不得写"可生产""等价""确定无效"。

### 3.3 材料信号（`SCREEN_CONTINUE`，四条全部满足才登记候选）

```text
1) READ 与 WRITE 相对两组位置对照的四个效应同向，且较小效应 >= M = max(5%, 2ε)
2) 对象 PUT 字节吞吐（juicefs_object_request_data_bytes{method="PUT"} 正式窗增量 ÷ 窗长）
   与应用 WRITE 带宽同向材料提升；PUT ops/s 作辅助分解项（用于区分"更多请求"与"更大对象"）
3) READ 方向没有材料性回归
4) 口径自洽：若应用 WRITE 提升而对象 PUT 字节吞吐无对应变化 ⇒ 先判定口径或采样证据不一致，
   ⛔ 不得直接宣称解闸成功
```

**降为记录与解释项**（⛔ 均不作删样门、⛔ 均不单独否决吞吐候选）：
PUT 在途量、PUT 平均延迟、OSD 平均写延迟与 `op_w` 完成率、秒级 CV、`W4/W1`、
`clat P95/P99`、客户端 CPU/NIC。它们的用途是说明**收益成本与新瓶颈位置**。

> 为什么不用"OSD 写延迟恶化 < 10%"作门：Little 定律下并发↑必然带来排队延迟↑，
> 用延迟否决吞吐会系统性误杀真实收益；且指导书 §二.14 明确"验收门与有效性门不得共用阈值、
> 带宽/CV/延迟不作删样门"。先例 04-6b 的 seqwrite 机制门同样是**完成率为主判据、延迟为旁证**。

**无净收益的机制签名**（用于解释，不用于删样）：
`PUT 在途量 ↑ 而对象 PUT 字节吞吐 ≈ 不变`（即延迟与在途量同比例恶化）⇒ 后端已在膝点。
出现该签名时按 `§0 NOT_IN_SCOPE` 停止，⛔ 不得据此扩展到更高并发档。

## 四、执行步骤与授权停点

### 阶段 0：离线 Gate 0（未过 ⛔ 禁止 SSH / mount / fio / juicefs / ceph 任何一条）

1. **测试前通读并确认**：`skills/SYSTEM-SAFETY-SKILL.md`、`skills/TESTING-GUIDE.md`
   §1.3/§2.2/§3、`skills/test-commands-reference.md` §8.3、`skills/EVIDENCE-INTEGRITY-SKILL.md`、
   `doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`，并显式回报关键点。
2. 只复用并参数化 `t05-1-randrw-driver.sh` / `t05-1b-randrw-driver.sh` 的 fio、正式窗、GC、
   恢复门与健康门逻辑；⛔ 禁新建编排框架；⛔ 本任务不需要临时卷/layout/destroy 组件。
3. Gate 只覆盖本次新增路径：`--max-uploads`/`--buffer-size` 渲染与**变量守卫**、
   `C1→T1→T2→C2` 平衡序列、Phase B1 单格筛选与门判定、Phase B2/C 的条件触发分支、
   危险命令扫描（无明文口令、无 `rm -rf`、无 pool delete/create、无 format、无强制/懒卸载、
   无模式 kill、无 sudo 写）。
4. 分析器必须在 05-1 Phase B 与 05-1b 正式补测归档上重放并复现已签收数字，
   并做起点敏感性三算（±1 s 变化 <1%；+58 s 必须显著改变四窗）；
   同时必须输出 `uploading` gauge 与**对象 PUT 字节吞吐**（§三.3 的主机制判据）。
5. **scrub 二选一必须在此勾定**（指导书 §二.19.1：预注册二选一，⛔ 禁止运行中改口径）：
   - **默认申请**：按 Phase 暂停 `noscrub + nodeep-scrub` + 立即精确恢复（与 05-1b 一致）。
     须提交：FSID、原始 flags、独立状态驱动控制脚本（plan/inspect/restore、
     只恢复自己新增的 flag、持久保存 set/unset epoch 与前后状态）、预计暂停时长、风险与授权行；
   - **备选**：保持 scrub 开启 + 预注册协变量规则（逐格记录与正式窗的重叠秒数并作为协变量报告，
     ⛔ 不得据此删样）。
6. **主动 OSD compact 属条件动作，必须在此预列**：默认恢复方式是被动等待（§2.2）；
   仅当恢复门连续超时才允许执行，须预列完整命令 `ceph tell osd.<id> compact`、
   6 个目标 OSD、**次数上限**与授权行；⛔ 未获授权不得执行；⛔ 仍禁 OSD restart 代替恢复。

**停点 G0**：回传 Gate 结果、实际脚本 SHA、完整挂载计划、scrub 二选一的选择与计划、
compact 条件计划与次数预算、全部写操作清单。用户未授权前 ⛔ 禁止 mount、fio、GC、
设置任何 Ceph flag、执行任何 compact。本任务预期无 sudo 写。

### 阶段 1：Phase A（1 MiB 解闸，必做）

获一次授权后连续完成：只读 inventory 与任务外服务/挂载/进程指纹 → `C1→T1→T2→C2` 四格
（每格：health → 挂载并落盘完整 cmdline → 资产校验 → sampler → fio 180 s →
机制/健康采集 → 优雅卸载 → 卷内 GC → 恢复门轮询）→ 增量持久化。

**停点 G1**：只交原始数据 + 逐门 PASS/FAIL + `incidents.tsv`；⛔ 执行方不算效应量、不挑轮次、
不下结论、不自行启动条件 Phase。第二方复算后决定：
① Phase B1 是否执行（默认执行）；② Phase C 是否触发。

### 阶段 2：Phase B1/B2 与条件 Phase C

- 先跑 Phase B1（1 格），**且必须在一次完整恢复门之后**；
  由第二方读 `uploading` p95 判 `256K_UPLOAD_PROXIMITY_GATE`；
- 门触发则连续跑 Phase B2 四格；未触发则记 `GATE_NOT_TRIGGERED` 并跳过；
- Phase C 只在第二方明确指出"哪个 Phase、哪个触发指标、唯一参数值"并获授权后执行。

**停点 G2**：原始证据持久化后暂停，交第二方复算与裁决。

### 阶段 3：收口（无论性能如何都必须完成）

任务挂载优雅卸载、fio/sampler 进程清零、卷内 GC、恢复门（objects/stored/TiKV pending）、
scrub flags 精确恢复并验收（若使用）、compact 次数账与授权对照、任务外指纹对比、
证据持久化与 SHA256 核验、生命周期盘点。
⚠️ 本任务**没有临时卷**，因此环境资产收口只涉及挂载/进程/flags/compact 账；
任一恢复失败按安全事件优先处理，⛔ 不得先写性能结论。

**末步（测试后 skill 合规自查，必带）**：逐条复核 ① 未出现 `ceph osd pool delete`、
未出现 `juicefs format/destroy`（本任务不建不销卷）；② 清理未夹带禁止操作；
③ 每写格后恢复门已轮询至 TiKV pending 连续 3 点为 0（若用过主动 compact，
须同时给出 `compact_running=0` 且 `compact_queue_len=0` 与次数账）；
④ drop_caches/预热按预注册口径对称执行且未影响 157 共置业务；
⑤ 统计口径为实际 I/O 起点 + 重叠加权 + 正式窗。任一不符须显式标注并说明对结论的影响。

## 五、交付物

```text
/mnt/c/SunRise/test/05-2/<RUN_ID>/
├── run-state.tsv
├── common/{inventory,identity,plans,scripts,scrub,commands.sh}
├── phases/{A,B1,B2,C}/cells/
├── incidents/
├── derived/
├── manifest.sha256
├── persistence.tsv
└── retention.tsv
```

- 正式报告：`doc/perf-report/05-2-randrw-upload-concurrency-and-buffer-gate-<DATE>.md`，
  必须在抬头给出机器可读 verdict 行；
- 更新：`doc/deploy-log/results-table.md`、05 阶段计划书执行进展；
- 报告须列出 `VALIDITY_STATE / LIFECYCLE_STATE / EVIDENCE_ROOT / MANIFEST_PATH /
  REMOTE_STATUS / LOCAL_STATUS / INCIDENT_STATUS / ENVIRONMENT_ASSET_STATUS`，
  并显式记录 `256K_UPLOAD_PROXIMITY_GATE` 与 Phase C 触发条件的判定结果（含未触发）；
- 若Phase A或条件触发后的Phase B2产生材料变化，报告须新增“05-2新值 / 05-1b冻结快照 /
  有方既有区间”同口径对比表；新值不得回填覆盖05-1b历史快照。若无材料变化，只记录无变化，
  不重复整张竞品表；
- 长期保留最小可复算 raw、实际脚本/命令、身份、最终分析与报告；审核后精确清理远端 RUN 目录与
  重复暂存/解压副本，⛔ 不得清理其他 RUN 或环境资产。

## 六、通用注意事项（必带，逐条固化）

1. **统计口径**：实际 I/O 起点 + 重叠加权自然秒 + 正式窗 + W1--W4；randrw 读写分开报、
   ⛔ 不相加；fio summary 只作旁证；⛔ 禁"一份合并 log × numjobs"外推；超网卡线速
   （100GbE ≈ 12500 MiB/s）的均值一律不认。
2. **冷态口径**：`direct=1 + cache-size=0` 且被测路径不依赖客户端页缓存，预注册**跳过 157 本机
   `drop_caches`**（157 有 WekaIO/K8s 共置业务）；两臂对称，并在报告记录该口径。
3. **fresh-volume 失真**：本任务全程复用已 layout 的固定资产，⛔ 不 layout、
   ⛔ 禁 `create_on_open`、⛔ 禁轮间 relayout。
4. **后端干净态**：每格后按 §2.2 的被动恢复门轮询（卷内 GC + objects/stored 稳定 +
   TiKV pending 连续 3 点为 0）；主动 `ceph tell osd.<id> compact` 仅在恢复门连续超时且
   已获 G0 授权时使用并计次；⛔ 禁用 OSD restart 代替恢复；⛔ 禁 `ceph osd pool delete/create`。
5. **环境前置**：开测前 `ceph health` `HEALTH_OK`、6/6 OSD up/in；每格前后落盘完整 health JSON
   与逐 PG state；**157 红线**：⛔ 禁动内核/网卡/RoCE/IRQ/NUMA/md0/WekaIO/K8s 及任务外路径。
6. **记录规范**：结果目录必须含 `commands.sh` 与实际脚本全文 + SHA；WSL 持久化根统一
   `/mnt/c/SunRise/test/`；远端 `/tmp` 只作临时区，⛔ 不得作为唯一副本；源端清理前必须先完成
   本地持久化 + SHA256 + 文件数 + 归档可读性三项核验。
7. **卷安全**：本任务 ⛔ 不执行 `juicefs format`、⛔ 不执行 `juicefs destroy`、
   ⛔ 不新建/删除卷或 pool。若任何步骤看起来需要建卷或清卷，立即停止并报告——
   那说明矩阵被误解。
8. **挂载档位**：本任务变量是挂载参数，必须 remount，因此逐格记录
   `pid/starttime_ticks/exe_md5/完整 cmdline` 并对两臂对称施加；位置相邻配对 + 同臂噪声底是抗
   档位的主手段；⛔ 禁用"同一挂载多跑几轮"代替配对（同挂载所有轮次是同一档）。
9. **分层授权**：脚本 bug、只读采集增强、不改变量的路径适配可自主修复并记 incident；
   🔴 改变量（矩阵、判据、卷、pool、BlockSize、FUSE、readahead、buffer、uploads、scrub flags、
   compact 次数、fio 字段）前必须停止并报告，⛔ 不得绕道。
10. **scrub**：策略在 G0 二选一勾定（默认按 Phase 暂停 + 精确恢复），
    ⛔ **禁止运行中改口径**（指导书 §二.19.1）。若使用暂停：只设 `noscrub + nodeep-scrub`、
    标记 `SCRUB_PAUSED_FOR_CONTROLLED_BENCHMARK`、同一矩阵全部臂对称保持不变、
    ⛔ 禁轮间 set/unset、Phase 结束（含失败/中止）立即精确恢复并验收原 flag；
    恢复优先于证据收口，恢复失败按安全事件处理。
11. **RUN 有效性**：⛔ 禁同 RUN 热改脚本后按正常签收、⛔ 禁换 RUN_ID 重来、⛔ 禁补样替换、
    ⛔ 禁与历史有效 RUN 拼接效应量；失败即保留现场（⛔ 禁 `fusermount -uz`、`umount -l`、
    `rm -rf`、模式 kill、kill mount PID）；`incidents.tsv` append-only，动作前后各记一条。
12. **每个判据指名来源**：每条判据写明读哪个文件、取哪个字段、怎么算；报告每个数字可回溯到
    文件路径 + 字段名；计数器名必须实查后写入（本任务用到的名称已在审计中实查验证）。
13. **执行方只交原始数据**，统计由第二方独立复算；订正必须写在报告开头，⛔ 不得放附录。
14. **先回答问题再完善工程**：未触发的条件 Phase ⛔ 不写脚本、不运行；
    ⛔ 不为"看起来完整"扩大矩阵；⛔ 不预注册 U450/U600。

## 七、红线汇总

- 🔴 157 上 WekaIO / K8s / 内核 / 网卡 / RoCE / md0 / 任务外路径与进程：⛔ 一律不动；
- 🔴 ⛔ 禁 `ceph osd pool delete/create`、⛔ 禁改 CRUSH/PG/pool 参数、⛔ 禁改 TiKV/OSD 全局配置、
  ⛔ 禁重启任何服务；
- 🔴 ⛔ 禁 `juicefs format` / `juicefs destroy` / 修改卷 BlockSize —— 本任务不涉及任何卷生命周期；
- 🔴 变量守卫：实际 mount cmdline 与矩阵不一致 ⇒ 立即停止并记 incident，⛔ 不得事后追认；
- 🔴 全局 Ceph flags（`noscrub/nodeep-scrub`）与主动 OSD compact 都属环境控制动作，
  只能执行 G0 已列明并获单独授权的精确计划，⛔ 不属于执行方可自主修复项；
- 🔴 sudo 写操作必须先列出完整命令、节点与目标并获确认；本任务默认不需要 sudo 写；
- 🔴 证据文件清理与环境资产（挂载/进程/flags/compact 账）清理必须分开授权与审计。

## 八、完成线

同时满足才能关闭 05-2：

- **Phase A 四格**给出 `T/C` 两组位置配对效应、同臂噪声底 `ε`、`M = max(5%,2ε)` 与明确四态裁决，
  并按 §三.3 四条材料信号逐条给出 PASS/FAIL；
- **Phase B1** 给出 256K 正式窗 `uploading` p95 与 `256K_UPLOAD_PROXIMITY_GATE` 判定；
  触发时 Phase B2 四格完成并给出裁决，未触发时记 `GATE_NOT_TRIGGERED`；
- **Phase C** 明确记为"已触发并完成"或"未触发已取消"，⛔ 没有悬空分支；
- 每格机制指标齐全，能回答"解闸后新的限制项在哪一层"；若出现"在途量↑而 PUT 字节吞吐不变"
  的膝点签名，明确记录并**停止**该方向（⛔ 不扩展更高并发档）；
- 任务挂载、fio/sampler 进程精确收口，scrub flags（若用过）已恢复并验收，
  compact 次数与授权一致，Ceph/TiKV 与任务外指纹恢复；⛔ 无临时卷需要清理；
- 原始证据持久化且可被第二方独立复算，报告、results-table 与 05 计划书完成更新。
