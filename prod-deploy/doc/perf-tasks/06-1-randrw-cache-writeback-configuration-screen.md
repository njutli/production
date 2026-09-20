# 06-1 任务书：randrw 缓存与 writeback 组合包筛选（四格）

> 日期：2026-09-15（按 GPT 评审 `/tmp/review-06-stage-plan-and-taskbooks-20260915.md` 修订：
> 缩为四格组合包、加因果范围强制声明、writeback 改"先排空后卸载"、多设备改逐路径白名单与逐设备空间门、
> ops/s 改用 histogram `_count`、96 GiB 改称"固定读缓存预算"、删除原 Phase B/C）
>
> 面向：执行方采集原始证据，第二方（GPT/Luna）独立复算与裁决
>
> 状态：`COMPLETED / RESOLUTION_INSUFFICIENT / NO_CANDIDATE`。有效 RUN `20260915-204941` 已完成并安全闭环；正式报告见 `doc/perf-report/06-1-randrw-cache-writeback-configuration-screen-20260915.md`。
> 2026-09-16 审计订正：`+16.32%～+19.56%` 为窗长依赖瞬时均值，不登记为效应；轮内衰减由
> 宿主脏页吸收/回压获得强定量支持，原“缓存盘服务率导致衰减”归因撤销。禁止 `drop_caches` 与
> 页缓存成为主导变量使本次 ABBA 未实现状态对称；本任务不重跑。
>
> 是否重跑：否。首次执行；但**复用** 04-tmp2j / 04-tmp2f 已验证的驱动骨架（见 §四 阶段 0）。
>
> 上位计划：`doc/perf-analysis/06-randrw-cache-and-write-path-tuning-plan.md`
>
> 立项依据：`doc/perf-report/04-tmp3j-direct-rados-write-service-curve-20260907.md`（后端未硬封顶的**非循环**证据）、
> `doc/perf-report/04-tmp2j-randrw-read-cache-capacity-curve-retest-20260907.md`（纯读缓存五档曲线）、
> `report/周报-JuiceFS调优工作汇总-20260912.md` §1.2（读缓存 `+12.32%`、读缓存+writeback `-16.88%`）、
> `report/周报-JuiceFS调优工作汇总-20260919.md` §3（源码机制 M1--M4/M2'）
>
> 承接的结果目录：`/mnt/c/SunRise/test/04-tmp2j/`、`/mnt/c/SunRise/test/04-tmp2*/`（writeback 系列）
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、`skills/TESTING-GUIDE.md` §1.3/§2.2/§3、
> `skills/test-commands-reference.md` §8.3、`skills/SYSTEM-SAFETY-SKILL.md`、`doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`

```text
04-tmp2j  randrw 纯读缓存五档：32/64/96/128/256 GiB → +5.62/+3.95/+9.82/+11.07/+14.84%
          命中率 11.08%→47.41%，M=5.03%；96 GiB 为**最小平台档**（非容量给足）
  ↓
04-tmp2f  writeback：randwrite 短时前台 +45.69%，脏峰值约 53 GiB
  ↓
04-tmp3j  直接 RADOS 256K 写 QD32/64/128 = 3271/3660/3949 MiB/s 且**未饱和**
          > JuiceFS 在 randrw 达成的对象 PUT 2177--2275 MiB/s ⇒ 纯写口径无 2.2 GiB/s 硬上限
          ⚠️ 纯写 != 混合；剩余约束可能在客户端路径，也可能来自 GET/PUT 混合服务关系，待区分
  ↓
0912 周报 randrw：读缓存 128G +12.32%（排空 0 s）；读缓存+writeback / **仅 25% 容量** -16.88%（排空 57 s）
  ↓
05-2      U300 无一致收益（RESOLUTION_INSUFFICIENT）⇒ 无继续扫上传并发的依据
  ↓
源码      M4：cache-size=0 连带强制关 writeback+prefetch ⇒ 05 全系列都在最保守模式
          M2'：writeback 下暂存块 os.Link 硬链接进读缓存 ⇒ 刚写的块天然本地可读
  ↓
06-1      你在这里：`96 GiB 读缓存预算 + writeback + 本地多路径`这一**组合包**是否有材料收益？
  ├─ 有 → 登记**组合包** L1 候选；另立小任务拆变量；⛔ 不在本任务内扩矩阵
  └─ 无 → 关闭该配置包，⛔ 不追加单格找漂亮样本，直接进 06-2 profile 门
后续：06-2（先过构建溯源门 + 动态 profile/Amdahl 门，才谈改源码）
```

一句话：**在容量与本地并行度都改善后，重新判定 `读缓存 + writeback` 这一整套配置包相对同轮无缓存锚能否让 randrw 取得材料收益；本任务只回答"组合包是否有收益"，⛔ 不归因到单项。**

## 〇、最小决策与生命周期合同

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=0912 周报 §1.2（读缓存 +12.32%/排空 0 s；读缓存+writeback -16.88%/排空 57 s，容量仅 25%）；
              04-tmp2j（96 GiB 最小平台档：+9.82%、命中 31.55%；256 GiB：+14.84%、命中 47.41%；M=5.03%）；
              04-tmp3j（直接 RADOS 256K 写 QD128=3949 MiB/s 未饱和 > JuiceFS PUT 2177--2275 ⇒ 后端未硬封顶）；
              源码 M2'（disk_cache.go:773 暂存块 os.Link 进读缓存）与 M4（SelfCheck 强制关 writeback）
SCREEN_CONTINUE=见 §三.3 四条材料信号
SCREEN_STOP=只在非性能硬门失败时中止；效应为负或 <5% 一律照常跑完并留数
FORMAL_MATRIX=有收益则先另立**拆变量归因小任务**，再另立 L2 正式效应量；本任务不自动升级
CAUSAL_SCOPE=组合包。⛔ 不得归因到 cache-size / writeback / 多路径任一单项；⛔ 不得表述为"逐个消除混杂"
NOT_IN_SCOPE=⛔ 不再扫 cache-size 容量曲线（04-tmp2j 已闭环）
            ⛔ 不设 --cache-expire（回拨暂存块 atime，优先逐出刚写的块）
            ⛔ 不改 max-uploads/buffer-size/max-fuse-io/卷 BlockSize
            ⛔ 不做 M1 相关改动（属 06-2）
            ⛔ 不做 --cache-large-write 单独臂（writeback 下已被 M2' 覆盖）
            ⛔ 不追加无 writeback 单格、不追加 upload-delay/单盘对照格（原 Phase B/C，已按评审删除）
ESTIMATED_WALL_CLOCK=离线准备 <=90 min；环境执行 1.5--3 h（固定 4 格）

MINIMUM_DECISION_SET=Phase A 四格 ABBA（C1 → T1 → T2 → C2），唯一通过/不通过项，无条件 Phase
STOP_AFTER_ANSWER=Phase A 出数即完成；⛔ 不补"漂亮样本"、⛔ 不就地扩矩阵
MAX_PREP_BUDGET=复用 t04tmp2j-randrw-cache-run.sh + t04tmp2f-writeback-run.sh 骨架与 t05-2 分析器，<=90 min
MAX_EXECUTION_BUDGET=未经新授权只执行 Phase A 四格且 <=4 h

EVIDENCE_ROOT=/mnt/c/SunRise/test/06-1/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-06-1-<RUN_ID>
LOCAL_CACHE_CONTRACT=逐路径合同，见 §2.4。每条 <APPROVED_PATH_i>/jfs-06-1-<RUN_ID> 独立登记与清理
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=不新建/不销毁 JuiceFS 卷、不 layout、不改卷格式；
              仅创建并在**验证 rawstaging 归零后**删除本 RUN 自建缓存目录
```

## 一、背景、目标与边界

### 1.1 为什么做

05 阶段全部 randrw 数据都在 `cache-size=0` 下取得，而 `Config.SelfCheck` 明确该值为 0 时**连带强制关闭 writeback 与 prefetch**（M4）。而 04-tmp3j 用直接 RADOS（绕过 TiKV/FUSE）测得 256 KiB 写 QD32/64/128 = `3271/3660/3949 MiB/s` 且**未饱和**，高于 JuiceFS 在 05-2 randrw 中达成的对象 PUT 字节吞吐 `2177--2275 MiB/s` ⇒ **直接 RADOS 只证明 PUT 没有在 `2.2 GiB/s` 处形成独立的**纯写**硬上限；randrw 的剩余约束**可能位于客户端路径，也可能来自 GET/PUT 混合服务关系**，需 06 阶段继续区分。**

⚠️ 该证据的必带限定：04-tmp3j 为**纯写、无并发 GET**；05-2 中后端同时承担约 `2.0 GB/s` GET，对象层总量约 `4.2 GB/s` 已接近 RADOS 纯写的 `3.95 GB/s`。⇒ 只能得出"后端未硬封顶"，⛔ **不得推出"PUT 可达 3.9 GB/s"**，⛔ 不得预告任何具体收益幅度。

缓存模式的唯一现有数据点是 0912 周报的 `-16.88%`，但该格 `cache-size` 仅为热集 **25%**。本任务在容量与本地并行度都改善后重测一次。

### 1.2 唯一主问题（通过/不通过项）

**在 `固定 96 GiB 读缓存预算 + --writeback + 已批准的本地多路径`配置下，randrw 相对同轮 `cache-size=0` 锚，READ 与 WRITE 双方向能否取得至少 `M = max(5%, 2ε)` 的材料收益？**

### 1.3 ⚑ 因果范围（强制声明项，必须进报告结论节）

Phase A 的 T 臂**同时**改变三项：`cache-size`（0 → 96 GiB）、writeback（关 → 开）、`cache-dir` 数量与物理设备（含由此改变的本地读写 I/O 形态）。

⇒ 本任务**只能回答"这套组合包是否有收益"**。
⛔ **不得归因到容量、writeback 或多路径各自的贡献。**
⛔ **不得表述为"逐个消除混杂"。**
⛔ **正收益不得被引用为"writeback 有效"或"多路径有效"。**
若有正收益，另立**拆变量归因小任务**；⛔ 不在本任务内扩矩阵。

### 1.4 三项配置的性质（表述要求，已按评审降级）

| 项 | 核实结论 | 允许的表述 |
|---|---|---|
| `cache-size=98304 MiB`（96 GiB） | 04-tmp2j 五档 `+5.62/+3.95/+9.82/+11.07/+14.84%`（32/64/96/128/256 GiB），命中率 `11.08%→47.41%`，`M=5.03%`；**96 GiB 为最小平台档**（`+9.82%`、命中 `31.55%`），并未完整容纳 128 GiB 热集 | ⛔ 不得称"容量给足"。称 **"固定 96 GiB 读缓存预算"**；底层文件系统可用物理容量作**独立安全条件**（§2.5） |
| 多 `--cache-dir` 跨设备 | 源码只证 `raw/` 与 `rawstaging/` 同属一个 cache store（`disk_cache.go:718/722`）、M2' 的 `os.Link` 要求同一文件系统 ⇒ **"分盘"不可实现**；但**未实测**原测试本地盘是否在带宽/IOPS/时延上饱和 | ⛔ 不得称"已核实混杂"。称 **"提高本地并行能力的候选配置"**；报告须用既有或本轮 iostat 说明单盘是否饱和 |
| `--upload-delay=0s`（默认） | 暂存完成后内联发起上传并占用 `currentUpload` 槽（`cached_store.go:443`） | 主格保持默认以使积压有界；"拉开"属另立任务，⛔ 本任务不测 |

### 1.5 明确不回答

1. ⛔ 不回答最优 `cache-size`（04-tmp2j 已闭环）。
2. ⛔ 不回答单项归因（§1.3）。
3. ⛔ 不回答 M1 消除后能到多少（属 06-2）。
4. ⛔ 不回答"是否可生产"。即使全部信号通过也**只登记组合包 L1 候选**。
5. ⛔ 不回答竞品对比。有方环境不再可用，≥1M 对比行已永久 `NOT_COMPARABLE`。
6. ⛔ 不把短窗前台带宽解释为长期持久化能力（§三.5 强制项）。

## 二、口径与矩阵

### 2.1 fio 合同（逐字沿用 05 系列，本任务不改一个字）

```
--directory=<私有挂载点> --name=rw_test --filesize=1G --size=1G
--bs=256K --rw=randrw --rwmixread=50 --ioengine=libaio --iodepth=128
--numjobs=128 --direct=1 --fallocate=none --allow_file_create=0 --openfiles=128
--group_reporting --time_based --runtime=180
--write_bw_log/--write_lat_log per-job + --log_avg_msec=1000
```

复用既有 `rw_test.0.0`--`rw_test.127.0`（128 × 1 GiB）固定资产，仅覆盖写。⛔ 不 layout、⛔ 不创建文件。

### 2.2 固定软件与公共挂载条件

| 项 | 值 |
|---|---|
| 客户端 | 157 |
| 二进制 | 部署归档中的 exact patched JuiceFS v1.4.1，MD5 `24fae0852051c80ca571cb2f20275d46`。⛔ **本任务不重新构建二进制** |
| 卷 | 既有 `juicefs-prod`（B256），⛔ 不 format |
| `--max-fuse-io` | `256K` |
| `--buffer-size` | `300`（MiB） |
| `--max-uploads` | `150` |
| `--max-downloads` | `200` |
| `--free-space-ratio` | `0.20`（沿用 04-tmp2 系列 ⇒ `stageFull` 阈值 = 设备可用空间比 `<10%`） |
| `--cache-expire` | ⛔ **不设**（默认 `0s`）。设置会使 `stagedBlockCooldown=CacheExpire/2` 回拨暂存块 atime，优先逐出刚写的块 |
| `--writeback-threshold-size` | 默认 `0`（= 全部暂存） |
| `--max-stage-write` | 默认 `1000` |
| 挂载 | **每格私有挂载点**；卸载顺序见 §2.6；⛔ 不触碰既有 `/mnt/juicefs` |

### 2.3 Phase A：组合包 vs 无缓存锚（4 格，唯一 Phase）

顺序 **ABBA**：`C1 → T1 → T2 → C2`

| 顺序 | cell | cache-size | cache-dir | writeback | upload-delay |
|---:|---|---|---|---|---|
| 1 | C1 | `0` | 无 | 关（M4 强制） | — |
| 2 | T1 | `98304` | `<APPROVED_DIRS>` | **开** | `0s`（默认） |
| 3 | T2 | `98304` | `<APPROVED_DIRS>` | **开** | `0s`（默认） |
| 4 | C2 | `0` | 无 | 关 | — |

- 效应量：`T1/C1` 与 `T2/C2` 两组位置配对；同臂 `C1↔C2`、`T1↔T2` 给噪声底 `ε = max(|Δ|)`；`M = max(5%, 2ε)`；`ε >= 5%` 记 `RESOLUTION_INSUFFICIENT`。
- 零假设对照 = 两个 C 格之间（真值恒为 0）。
- ⛔ 禁止引用历史 `cache-size=0` 数字作对照（0912 周报已明确标注历史值"不是同窗 A/B"）。

### 2.4 ⚑ 本地缓存路径逐路径合同（安全前置）

只读 inventory **只能发现设备，不构成在其上写缓存的授权**。因此：

1. **每条 `cache-dir` 必须来自 Gate 0 显式批准的路径白名单** `<APPROVED_PATH_1>[:<APPROVED_PATH_2>...]`；⛔ 不得"发现 ≥2 个独立设备就自动使用"。
2. 每条路径必须登记：**源设备、文件系统、挂载点、属主、总容量、可用空间、业务用途**。
3. ⛔ **排除**：系统盘、`md0`、Weka 盘、TiKV/OSD 在用盘、业务盘、未知挂载。
4. 每个缓存目录必须：**本 RUN 创建、非符号链接、路径在白名单内、起点为空**（沿用 04-tmp2j 的 `cache_not_empty` 检查）。
5. **生命周期清理只覆盖本 RUN 自建目录**，且只在 §2.6 的 rawstaging 归零验证之后执行；动作前后各记一条 `incidents.tsv`。
6. 若白名单最终只批准 1 条路径 ⇒ 记 **`MULTI_DIR_UNAVAILABLE`**，Phase A 照常执行，报告须声明"本地多路径杠杆本轮不可用，组合包只含容量与 writeback 两项"。
7. `<APPROVED_DIRS>` 与 `LOCAL_CACHE_CONTRACT` 必须逐条一致，⛔ 不得出现单一 `LOCAL_CACHE_ROOT` 与多路径并存的不一致写法。

### 2.5 ⚑ staging 空间门（按设备逐一过门）

- **排空能力取 04-tmp2f 的严格排空观测，净脏峰值取 04-tmp2g 的 `W64=52.632 GiB`、`W128=53.202 GiB`**；两类证据不得混写。⛔ **不得用 05-2 在 `cache-size=0` 下观测的 `2.2 GB/s` 当 writeback 配置的保证值。**
- **前台写入取上界**，并加安全余量。
- **一致性哈希不保证暂存块均匀分布**（`consistenthash.New(100, murmur3.Sum32)`）⇒ 必须按**每个 cache-dir 所在设备的最坏偏斜**分别过门。
- 短窗净积压可能达**数百 GiB**，远大于 96 GiB 读缓存预算；两者记账不同（暂存块 `size<0` 不占 `cache-size`），但**争用同一文件系统可用空间**，须一并计入。
- **单位统一用 GiB / GiB/s**，⛔ 禁 GB/GiB 混用。
- ⛔ **不得在 `stageFull`（设备可用空间比 `< free-space-ratio/2 = 10%`）会命中的配置下跑正式格**；不足则降 runtime 或不启用该路径。

### 2.6 ⚑ writeback 生命周期顺序（强制，⛔ 不得改序）

```
fio 结束
→ **保持原挂载存活**（由它继续上传 rawstaging）
→ 等待并验证每个 cache-dir 的 rawstaging 归零（逐秒记录占用与耗时）
→ 可选：原挂载初步读回（仅作快速自检）
→ 优雅卸载原挂载
→ **用 `cache-size=0` 的私有验证挂载重新挂载同一卷**
→ 抽样读取本格覆盖过的区域，确认可读且无 EIO
→ 卸载验证挂载
→ 卷内 GC + 恢复门
→ **仅在以上全部通过后**，清理本 RUN 缓存目录
```

⚠️ **排空超时 ⇒ 保留挂载与现场取证并停测**，⛔ 不得先卸载再尝试正常排空。
理由：卸载后 `uploader()` goroutine 已终止，`rawstaging` 内未上传块只能靠下次挂载同一 cache-dir 续传；若此时删除缓存目录，**未上传数据直接丢失**。

⚑ **为什么必须用独立 `cache-size=0` 验证挂载**：原挂载带读缓存，且 Linux 页缓存也可能保留数据 ⇒ **在原挂载上读回只能证明"当前挂载仍可读"，不能证明 Ceph 上的对象已可独立读取**。`cache-size=0` 会强制关闭读缓存/writeback/prefetch（M4），使读必须穿透到对象层。

⚠️ **该检查的能力边界（必须在报告中声明）**：
- 本检查只做**远端可读性 + 无 EIO**，⛔ **不构成内容正确性验证**。
- 原因：fio randrw 对固定资产做随机覆盖，**没有可复算的期望内容清单**。
- 若要做内容校验，须在 fio 合同中加入可复算数据模式（如 `verify=`），但这会**改变冻结负载**并使结果与 05 系列不可比 ⇒ **属另立任务，⛔ 不在本任务范围**。
- 辅助项：可另跑 `juicefs fsck`（只读）作补充，⛔ 但同样不等于内容校验。

### 2.7 预热合同（全格一致）

04-tmp2j 报告 §line 74--78：冷缓存逐格重建，且预热数据驻留 Linux 页缓存 ⇒ 正式窗内块设备读计数接近零。据此预注册：

1. **每格前执行同一条固定预热命令、固定时长**（Gate 0 冻结并登记 SHA256），预热**不进入正式窗**。
2. **无缓存锚格（C 臂）也跑完全相同的预热**，保持时间轴与后端状态对称。⛔ 不得只给 T 臂预热。
3. **必须分别记录**：正式窗内 ① 应用层带宽、② 各 `cache-dir` 设备的 iostat（块设备层）、③ `/proc/meminfo` 的 `Cached`/`Dirty`/`Writeback` 逐秒。
4. ⚑ **预注册解释规则**：若正式窗块设备读计数接近零而应用带宽高，**判为"命中经由页缓存供给"**，⛔ 不得表述为 NVMe 介质速度，⛔ 不得据此推算可持续本地带宽。

### 2.8 机制指标（每格必采；指标名已按评审订正）

| 指标 | 来源（prometheus 名，`juicefs_` 前缀） | 用途 |
|---|---|---|
| **对象请求次数** | **`object_request_durations_histogram_seconds_count{method=...}` 增量** | **PUT/GET ops/s 的唯一主口径** |
| 对象数据字节吞吐 | `object_request_data_bytes{method=...}` 增量 ÷ 正式窗长 | 字节吞吐。⛔ **该指标是字节计数器，不得当作请求数来源**；仅在逐请求对象大小已验证后可作旁证 |
| 对象请求错误 | `object_request_errors` | 硬门 |
| 读缓存命中 | `blockcache_hits` / `blockcache_miss` / `blockcache_hit_bytes` / `blockcache_miss_bytes` | 缓存是否真在工作 |
| 本地缓存写入与淘汰 | `blockcache_writes` / `blockcache_write_bytes` / `blockcache_drops` / `blockcache_evicts` / `blockcache_blocks` / `blockcache_bytes` | 本地介质写入量与淘汰压力 |
| 本地缓存读时延 | `blockcache_read_hist_seconds` | 本地读路径成本 |
| **暂存错误与延迟** | **`staging_block_errors`** / `staging_block_delay_seconds` | **stage 是否静默回落同步 PUT** |
| `stageFull` 命中 | 挂载日志 + 各缓存设备可用空间比逐秒 | 硬门（§2.5） |
| 上传在途 | `object_request_uploading` **mean / p95 / max** | **三项都要**（05-2 D1 教训：p95 不是运行水位） |
| **排空时长 + 净积压峰值** | fio 结束到 `rawstaging` 归零的时长；`rawstaging` 占用逐秒峰值（按设备分列） | **§三.3 / §三.5 强制项** |
| 各缓存设备 iostat + `/proc/meminfo` | 逐秒 | §2.7 解释规则 |
| 客户端 CPU / NIC | 逐秒 | 排除客户端成为新瓶颈 |

⚑ **指标名必须在 Gate 0 从实际 `.prom` dump 核对**，⛔ 不得凭文档假设（本条由"用字节计数器当请求数"的评审意见固化而来）。

## 三、有效性、裁决与数据来源

### 3.1 非性能硬门（失败即 `EVIDENCE_INVALID` 并停，⛔ 不得用性能好坏删样）

| 门 | 判据 | 数据来源 |
|---|---|---|
| **路径授权** | 每条 `cache-dir` 在批准白名单内、非符号链接、本 RUN 创建、起点为空；已排除系统盘/`md0`/Weka/TiKV/OSD/业务盘/未知挂载 | `gate0/cache-path-contract.tsv`、`cells/<cell>/cache-dir-state.tsv` |
| **逐设备空间门** | 按 §2.5 逐设备（含最坏偏斜）估算净积压上限，可用空间须同时容纳该上限与 `free-space-ratio` 保留 | `gate0/staging-headroom-per-device.tsv` |
| **`stageFull` 未命中** | 正式窗与排空期内各缓存设备可用空间比恒 `>= 10%` | `cells/<cell>/df-1hz.tsv` |
| **stage 无静默回落** | `staging_block_errors` 增量 = `0` | `cells/<cell>/metrics-*.prom` |
| **排空闭环（先排空后卸载）** | 每个 writeback 格在**卸载前**完成 `rawstaging` 归零；超时即**保留挂载**停测 | `cells/<cell>/drain.tsv` |
| **远端持久化读回** | 在**独立 `cache-size=0` 验证挂载**上抽样读回本格覆盖区域，可读且无 EIO。⚠️ 只证可读性，⛔ 不构成内容正确性验证（§2.6） | `cells/<cell>/readback-verify.tsv`、`verify-mount.tsv` |
| 缓存目录闭环 | 清理只在归零验证后执行，且只覆盖本 RUN 目录；前后各记 `incidents.tsv` | `cells/<cell>/cache-dir-state.tsv`、`incidents.tsv` |
| 采样覆盖 | 正式窗逐秒无缺秒；最大采样间隔 `<= 1.5 s` | `cells/<cell>/sampler-*.tsv` |
| 身份指纹 | 挂载 PID/starttime/exe md5（须为 `24fae085…`）、`findmnt` 与卷名一致；无外来 fio | `cells/<cell>/mount-process.tsv`、`foreign-fio.tsv` |
| 集群健康 | 起止 `HEALTH_OK`、6/6 OSD up/in、97/97 PG active+clean | `inventory/`、`closeout/` |
| 资产完整 | 128 × `1073741824` B 起止一致 | `assets-start.tsv` / `assets-end.tsv` |
| 预热一致 | 每格预热命令与时长完全一致且 rc=0 | `cells/<cell>/warmup.log` |
| 指标名核对 | Gate 0 已从实际 `.prom` 核对 §2.8 全部指标名 | `gate0/metric-names.tsv` |

### 3.2 性能口径（⛔ 性能端点不触发删样）

- 起点 = `fio 报告完成时刻 − JSON 实际 runtime`；**必须打印"实际起点 − 登记起点"差值**，>2 s 说明存在启动期污染。
- 正式窗 `[15,175)`（160 s），多 job 按与自然秒的**重叠时长加权**摊分后逐秒求和，只保留 job 数齐全的秒。
- 报 mean / median / 秒级 CV / P10 / P90，以及 W1--W4 与 `W4/W1`。fio summary 只作旁证。
- 带宽、CV、`W4/W1`、延迟**再差都是结果**，⛔ 不得作为删样理由。

### 3.3 材料信号（`SCREEN_CONTINUE`，四条全部满足才登记组合包 L1 候选）

1. **效应门**：READ 与 WRITE 相对两组位置对照的四个效应**同向**，且较小效应 `>= M = max(5%, 2ε)`。
2. **本地介质承担**：本地缓存设备读写字节量相对 C 臂**材料上升**，且应用带宽提升与之同向。
   ⚑ 若应用带宽涨而本地介质与对象层流量都不动，**先判口径/采样错误**，⛔ 不得直接采信。
3. **后端对象请求率不下降**：PUT 请求数（histogram `_count`）相对 C 臂不出现材料下降 —— 即收益不是靠饿死后端换来的。
   ⚠️ writeback 下前台与后台已解耦，本条只作**自洽检查**，⛔ 不得据其推断共享 op 预算（属 06-2）。
4. **排空与积压可接受**：`staging_block_errors=0`、`stageFull` 未命中、排空时长与逐设备净积压峰值均在 Gate 0 预注册上限内、读回检查通过。

### 3.4 四态裁决

沿用指导书 §二.15：`VALID` / `EVIDENCE_INVALID` / `RESOLUTION_INSUFFICIENT` / `INCONCLUSIVE`。
⛔ 不得写"可生产""等价""确定无效""已达架构上限"。

### 3.5 强制声明项（缺任一条报告不予通过）

1. **因果范围声明**（§1.3）：必须出现在报告**结论节**，不得只在正文提一句。
2. **持久性声明**：ack 先于持久化 + 排空窗口时长 + 逐设备净积压峰值 + `stageFull` 命中时会静默回落同步 PUT。
3. **多路径可用性声明**：`MULTI_DIR_USED=<n>` 或 `MULTI_DIR_UNAVAILABLE`。
4. **单盘饱和证据**：用既有或本轮 iostat 说明单盘是否饱和；未能说明则表述为"候选配置，饱和未证"。
5. **页缓存解释规则判定结果**（§2.7.4）。
6. **读回检查能力边界声明**：仅远端可读性 + 无 EIO，⛔ 不构成内容正确性验证；内容校验须改冻结负载，属另立任务（§2.6）。

## 四、执行步骤与授权停点

### 阶段 0A：纯离线准备（⛔ 全程禁止 SSH 与任何远端命令）

> 签收记录：原始 `RUN_ID=20260915-200000` 与 replacement `RUN_ID=20260915-204941` 均经 GPT + Luna 二方签收；远端调用数 `0`。
> 证据：`/mnt/c/SunRise/test/06-1/20260915-200000/gate0-r2/`（加入路径身份漂移硬门后的最终版）。
> 冻结 SHA256：driver `c2c105aa4f28662fcae4ac52f1760617eedfd52ccea7a1da1d502eeca48bbec8`；
> analyzer `eb6ea8e81806793571fffa647b585795b442817342236c47e4f60ff9951a5b33`；
> Gate `ec8ed31c76c3b2820e3c37a5ba80c06966fb93f3738154d5c2421a12c2be439f`。
> 执行前发现 Go 进程标题截断兼容性后，driver 仅修复 PID 身份门并重新过 Gate，replacement SHA256 为
> `4a0d104322fbe9d7b790842866d242133082a358f0f3b1acb799bac593be1336`。执行后离线 analyzer 修复“按每秒首样本检查间隔”的聚合假 gap，SHA256 为
> `47d33247eb0ced35d1bf283cd970fe2bd89735664f16177f1062bf5a2227ed38`；两项均有独立复核记录。

- [x] 0A-1 通读 `skills/EVIDENCE-INTEGRITY-SKILL.md`、`SYSTEM-SAFETY-SKILL.md`、`TESTING-GUIDE.md` 与本任务书，回传关键点确认；**显式确认 §1.3 因果范围与 §2.6 生命周期顺序**。
- [x] 0A-2 基于 `t04tmp2j-randrw-cache-run.sh`（读缓存）与 `t04tmp2f-writeback-run.sh`（writeback）骨架产出 `t06-1-randrw-cache-driver.sh`；分析器复用 `t05-2-randrw-analyze.py` 并扩展 §2.8 指标。登记三个脚本 SHA256。
- [x] 0A-3 `bash -n` + `--self-test`（**纯离线**，用合成数据）：矩阵顺序、正式窗边界解析值、时间锚交叉检查、多 job 重叠加权、`ε`/`M` 计算、四态裁决、`stageFull`/`staging_block_errors` 门、**生命周期顺序门（必须验证"卸载动作在归零验证之后"且"验证挂载在原挂载卸载之后"）**、缓存目录白名单与非符号链接检查。
- [x] 0A-4 产出**静态命令计划**：阶段 0B 与 Phase A 将要执行的全部命令逐条列出，标注只读/写；产出 `gate0/command-plan.tsv`。
- [x] 0A-5 冻结预热命令与时长（§2.7），登记 SHA256。
- [x] 0A-6 声明本 RUN 全部写操作清单与禁止项。
- ⛔ **停点 1**：回传 0A 全部产物（脚本 SHA256、self-test 结果、命令计划），等第二方审核 + 用户授权后才可进入 0B。

### 阶段 0B：远端只读 inventory（允许 SSH 与只读命令；⛔ 禁止创建目录 / mount / fio / 任何配置修改）

> 条件签收记录：GPT + Luna 已确认 inventory、空间门与指标合同通过；远端写操作数 `0`。
> 证据：`/mnt/c/SunRise/test/06-1/20260915-200000/gate0b/`。
> 唯一候选为 `/mnt/jfs-cache/04tmp3`（`/dev/nvme1n1`）；与 `/mnt/beegfs-meta` 为同一文件系统的双挂载别名，故 `MULTI_DIR_UNAVAILABLE`。
> 用户已确认该设备在完整测试窗口内不承载业务并批准唯一路径；执行期间未使用同盘别名 `/mnt/beegfs-meta`。

- [x] 0B-1 **候选设备与路径清点（只读）**：型号、容量、可用空间、文件系统、挂载点、属主、业务用途；标注排除项（系统盘、`md0`、Weka 盘、TiKV/OSD 在用盘、业务盘、未知挂载）。产出 `gate0/devices.tsv` 与 `gate0/cache-path-contract.tsv`（**路径白名单提案，待用户逐条批准**）。
- [x] 0B-2 **逐设备空间门反算**（§2.5，用 04-tmp2f 排空观测、04-tmp2g 净脏峰值 + 最坏偏斜 + 统一 GiB）；产出 `gate0/staging-headroom-per-device.tsv`。
- [x] 0B-3 **从实际 `.prom` dump 核对 §2.8 全部指标名**（只读抓取现有挂载的 metrics endpoint）；产出 `gate0/metric-names.tsv`。
- [x] 0B-4 只读 inventory：Ceph 健康、OSD/PG、TiKV pending-compaction、`/mnt/juicefs` 身份、资产 128 × 1 GiB、二进制 MD5（须为 `24fae085…`）、fio 版本、无外来 fio、`MemTotal`/`lscpu`/NIC。
- [x] 0B-5 **scrub 策略二选一并写明恢复计划**（默认：Phase 内暂停 `noscrub+nodeep-scrub` + 精确恢复）。主动 OSD compact 默认禁用；如需预案须预列命令、目标 OSD、次数上限与授权行。
- [x] 0B-6 汇总 `gate0/gate.tsv`，并声明**远端写操作数 = 0**。
- ⛔ **停点 2**：回传 0B 结果，等第二方审核 Gate 0 + **用户逐条批准 cache-dir 白名单与全部写操作**后才可进入 Phase A。

### 阶段 1：Phase A（4 格 ABBA，唯一 Phase）

- [x] 1-1 Phase 起始恢复门：卷内 GC（`juicefs gc --compact --delete --threads 32`）+ 被动等待 pool objects/stored 稳定与三节点 TiKV pending-compaction 连续三点为 0。
- [x] 1-2 按 `C1 → T1 → T2 → C2` 逐格执行，**严格按 §2.6 顺序**：创建空缓存目录（如需）→ 私有挂载 → 预热 → fio 180 s → **保持原挂载等 rawstaging 归零** → 优雅卸载原挂载 → **`cache-size=0` 私有验证挂载抽样读回（可读性 + 无 EIO）** → 卸载验证挂载 → GC + 恢复门 → 清理本 RUN 缓存目录（前后各记 `incidents.tsv`）。
- [x] 1-3 每格产出 §2.8 全部指标与 per-job 日志。
- ⛔ **停点 3**：回传 Phase A 原始数据，由第二方独立复算效应量、`ε`、`M`、四条材料信号并给出四态裁决。

### 阶段 2：收口（无论性能如何都必须完成）

- [x] 2-1 scrub flag 按原状态精确恢复并验证。
- [x] 2-2 确认无任务 fio / sampler / 挂载残留；各设备 `rawstaging` 全部归零。
- [x] 2-3 删除本 RUN 自建缓存目录并验证；⛔ 不得对非本 RUN 目录做递归删除。
- [x] 2-4 Ceph `HEALTH_OK`、6/6 OSD、97/97 PG active+clean；资产 128 × 1 GiB 完整。
- [x] 2-5 证据打包 + SHA256SUMS + 持久化到 `EVIDENCE_ROOT` 并校验；GPT/Luna 复核后已删除157上有效/无效 RUN 的四个精确 result/prep 临时根。
- [x] 2-6 按 skill 复核执行合规，GPT + Luna 独立复算一致。

## 五、交付物

```
/mnt/c/SunRise/test/06-1/<RUN_ID>/
├── gate0/            devices.tsv cache-path-contract.tsv staging-headroom-per-device.tsv
│                     metric-names.tsv gate.tsv self-test.* input-sha256.tsv plan/
├── inventory/        只读环境快照
├── cells/<cell>/     mount-*.tsv findmnt.tsv foreign-fio.tsv warmup.log
│                     fio.json formal/bw/*.log formal/clat/*.log
│                     metrics-pre.prom metrics-post.prom juicefs-metrics-1hz.tsv
│                     df-1hz.tsv iostat-1hz.tsv meminfo-1hz.tsv client-sidecar.tsv
│                     cache-dir-state.tsv drain.tsv readback-verify.tsv verify-mount.tsv
├── closeout/         恢复门、scrub 恢复、缓存目录清理、资产、健康
├── incidents.tsv     append-only
└── SHA256SUMS
```

- 正式报告：`doc/perf-report/06-1-randrw-cache-writeback-configuration-screen-<日期>.md`
- `doc/deploy-log/results-table.md` 追加小节
- 上位计划 §九 追加执行进展行
- 报告必带 §3.5 的**五条强制声明项**与 §3.3 四条材料信号逐条 PASS/FAIL

## 六、通用注意事项（必带）

1. **数据统计口径**：主口径为实际 I/O 起点 + 重叠加权重采样 + 正式窗 + 四子窗（指导书 §二.13）。⛔ fio summary 不得作主口径。
2. **冷态净化**：⛔ 本任务不执行 `drop_caches`（会破坏 §2.7 页缓存观测口径）；页缓存状态改为逐秒记录并纳入解释规则。
3. **fresh-volume / 冷启动失真**：缓存逐格冷建，故 §2.7 预热合同为**必须项**，⛔ 不得省略或只给单臂。
4. **后端干净态**：每格后 GC + 被动恢复门；主动 OSD compact 默认禁用。
5. **环境前置检查**：阶段 0 只读 inventory 必须先过。
6. **记录规范**：所有判据指名数据来源文件（§三各表已列）；`incidents.tsv` **append-only**，异常/修复在动作前后各记一条，⛔ 不得改写历史行。
7. **skill 合规自查**：测试前通读确认（0-1），测试后复核（2-6）。
8. **分层授权**：可自主修复区 = 本 RUN 自建缓存目录、私有挂载、本 RUN 采集脚本；禁止擅动区 = 卷格式、pool/PG/CRUSH、TiKV/OSD 配置、`/mnt/juicefs`、固定资产、scrub 以外的集群开关、**二进制替换**、**白名单外的任何本地路径**。
9. **非性能门与性能端点分离**（§三.1 / §三.2 已分表）。
10. **RUN 有效性状态机与禁止补样**：四态预注册（§3.4）；⛔ 禁同 RUN 热改脚本后正常签收、补样替换、拼接无效 RUN 点值、门失败后改挑有利判据。失败即先**保留现场**，⛔ 禁 `fusermount -uz` / `umount -l` / `losetup -D` / `rm -rf` / 模式 kill / kill mount PID。唯一工程例外：若故障发生在某格正式负载启动前、尚无该格性能端点，可在完整保留并标记原 RUN 为 `EVIDENCE_INVALID_PRELOAD`、确认无残留且修复重新过离线 Gate 后，用新 RUN **整套重跑四格**；原 RUN（包括其中已完成的格）全部不得进入效应量，且最多允许一次此类替代运行。
11. **多臂设计**：ABBA 最小平衡筛选；同臂相邻对给 `ε`；`M = max(5%, 2ε)`；⛔ 禁先设边界后测噪声。零假设对照 = 两个 C 格之间。
12. **Gate 0**：未过 ⛔ 禁止连接环境。
13. **第二方复算**：执行方只交原始数据，统计与裁决由第二方独立完成。
14. **scrub 条件性控制**：Gate 0 前二选一，Phase 内暂停、结束立即只恢复本任务拥有的 flag。
15. **证据分级**：`L1_SCREEN`，⛔ 不自动升级 `L2_FORMAL`；有收益先另立拆变量归因小任务。
16. **数据生命周期**：遵循 `TEST-DATA-LIFECYCLE-POLICY.md`，先持久化校验再清远端。
17. **精简与尽快闭环**：固定四格，出数即回答主问题；⛔ 不补"漂亮样本"、⛔ 不就地扩矩阵。

## 七、红线汇总

**本任务特有：**

1. ⛔ **writeback 格必须"先排空后卸载"**（§2.6）。卸载后 uploader 已终止，此时清理缓存目录会**丢失未上传数据**；排空超时须保留挂载与现场。
1b. ⛔ **读回必须在独立 `cache-size=0` 验证挂载上做** —— 原挂载带读缓存且页缓存可能保留数据，在其上读回只证明"当前挂载可读"，⛔ 不证明对象已可从 Ceph 独立读取。
1c. ⛔ **不得把读回检查表述为内容正确性验证** —— 随机覆盖无期望内容清单，只能做可读性 + EIO 检查。
1d. ⛔ **阶段 0A 全程禁止 SSH**；远端只读 inventory 属阶段 0B，且 0B **远端写操作数必须为 0**。
2. ⛔ **不得把组合包收益归因到单项**，⛔ 不得表述为"逐个消除混杂"（§1.3）。
3. ⛔ **不得称 96 GiB 为"容量给足"** —— 实测 `+9.82%`、命中 `31.55%`，只是最小平台档。
4. ⛔ **不得称单盘带宽饱和为"已核实混杂"** —— 未实测；只能称候选配置。
5. ⛔ **不得表述"读缓存与 staging 分盘"** —— 同 `cache.dir` 且 `os.Link` 要求同一文件系统，设计上不可实现。
6. ⛔ **不得把 `stageFull` 归因于 `cache-size`** —— 它由设备可用空间比决定（`< free-space-ratio/2`）。
7. ⛔ **不得用 `object_request_data_bytes` 当请求数来源** —— 它是字节计数器；请求数取 histogram `_count`。
8. ⛔ **不得用 05-2 的 `2.2 GB/s` 当 writeback 配置的排空保证值**；空间门须按设备逐一过、单位统一 GiB。
9. ⛔ **不得使用白名单外的本地路径**；只读发现设备 ≠ 获得写授权。
10. ⛔ **不得设置 `--cache-expire`**；⛔ 不得只给 T 臂预热；⛔ 不得引用历史 `cache-size=0` 数字作对照。
11. ⛔ **不得把正式窗块设备读计数接近零的高带宽解释为 NVMe 介质速度**（§2.7.4）。
12. ⛔ **不得只报前台带宽** —— 必须同表给出排空时长与逐设备净积压峰值。
13. ⛔ **不重新构建二进制**（本任务用部署归档 MD5 `24fae085…`）；⛔ 不触碰 `/mnt/juicefs`；⛔ 不 format / layout / destroy 卷。

**复述关键通用红线：** 性能端点不得删样；四态必须预注册且不得写"可生产/等价/确定无效/已达架构上限"；禁止补样与热改后正常签收；失败保留现场；`incidents.tsv` append-only；Gate 0 未过禁止上环境；统计由第二方复算。

## 八、完成线

- [x] 用户批准本任务书（2026-09-15；批准启动阶段 0A）
- [x] 阶段 0A 纯离线产物签收（远端调用数 = 0；GPT + Luna 二方签收）
- [ ] 阶段 0B 只读 inventory 完成（远端写操作数 = 0），缓存路径白名单经用户逐条批准
- [ ] Phase A 四格全部 `fio rc=0`、sampler 完整、正式窗无缺秒
- [ ] 每个 writeback 格在卸载前完成排空归零；并在独立 `cache-size=0` 验证挂载上通过读回（可读性 + 无 EIO）
- [ ] 第二方独立复算给出效应量、`ε`、`M`、四条材料信号与四态裁决
- [ ] 收口全项通过（含缓存目录清理与二进制未被替换），证据持久化并校验
- [ ] 正式报告含 §3.5 五条强制声明项；results-table 与上位计划进展行落地
