# U141b 任务书：patched v1.4.1 能否替代 patched v1.3.1 的正式判定

## 日期：2026-08-28

> 面向：GLM 执行；opencode 离线独立复算与签收。
>
> **执行模式：分阶段执行。** 每个 phase 内部**完全自主、不许中途停下提问**；
> phase 边界处停下回传，由 opencode 审核本 phase 全部硬门与原始数据后才放行下一 phase。
> 共 5 个检查点：Gate 0 → 阶段 I(含 P0) → P1+P2 → P3 → （条件）P4。
> ⚑ 这个粒度是刻意选的：03-22 系列的复盘显示"每小步停下等一句指令"协调成本极高、边际信息极低，
> 而"整批跑完再看"又会让一个 phase 的 8 臂一起废掉。**phase 边界是唯一有决策价值的停点。**
>
> 状态：任务书已就绪，**尚未上环境**。不占 03-xx 编号（这是交付基座版本决策，不是调优任务）。
>
> 承接：`doc/perf-report/u141-abba-non-inferiority-20260824.md`（对象数棘轮污染，主判据失效）、
> `doc/perf-report/juicefs-v1.4.1-vs-patched-v1.3.1-baseline-20260824.md`（对照列错误）、
> 以及 08-25 的 `V141R`/`V141P` 全量对（序贯非交叉，纯读零假设漂移 −5.25%）。
>
> 方法论：执行前必须完整阅读 `skills/EVIDENCE-INTEGRITY-SKILL.md`（**本任务的主口径、
> 平衡设计、噪声底自校准、Gate 0 与状态机全部出自该 skill**）、
> `skills/fixtures/known-defect-classes.tsv`（Gate 0 必须逐条覆盖）、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.13--18、
> `skills/SYSTEM-SAFETY-SKILL.md`、`skills/TESTING-GUIDE.md`、
> `skills/test-commands-reference.md` §8.3/§9、`skills/LONG-RUNNING-TEST-SKILL.md`、
> `skills/interleaved-ab-tuning-skill.md`、`skills/baseline-reproduction-skill.md` §2.2/§2.5/§3.1/§4.3。

```text
03-8   B-catchup 补丁定型，patched v1.3.1 成为交付基座
  ↓
03-17f 交付配置七项基线（seqread 1449 / mseqread 5366 / randread 5544 / randrw 1870
        / seqwrite 1570 / mseqwrite 4676 / randwrite 2707）
  ↓
08-24  v1.4.1 原版 randwrite 崩塌 551；+B-catchup 恢复 → 补丁必要性已封板
  ↓
U141   ABBA 32 cell：mseqwrite 造成对象数 2.43M→5.36M 单向棘轮，臂与对象数共线 → 主判据失效
  ↓
V141R/V141P 全量对：序贯非交叉，纯读零假设给出 ±5.25% 块级偏置底噪 → 无法分辨 3-6% 效应
  ↓
U141b  轮级交错 ABBA-BAAB + 自校准底噪  ← 你在这里
  ├─ 六项全部非劣 → REPLACE_APPROVED，patched v1.4.1 取代 patched v1.3.1
  ├─ 任一项材料性退步 → REPLACE_REJECTED，列明退步项与幅度
  ├─ 底噪高于边界 → RESOLUTION_INSUFFICIENT，只给上界不给结论
  └─ 任一非性能硬门失败 → EVIDENCE_INVALID，保留现场，禁止补样
```

一句话：在同一生产卷、同一挂载参数、同一 Ceph 数据面上，把 JuiceFS 二进制作为唯一变量，
用**轮级交错**的 ABBA-BAAB 平衡矩阵测 6 项（外加条件性第 7 项），
并用矩阵内自带的**同臂相邻对**自校准噪声底，给出 patched v1.4.1 能否替代 patched v1.3.1 的正式结论。

---

## 〇、为什么必须重做，以及这次改了什么

U141 与 V141R/V141P 都不是执行失败，是**设计失败**。三条根因：

| 根因 | U141 / V141R-P 的表现 | U141b 的修法 |
|---|---|---|
| 臂与时间共线 | V141R 全在 22:10–01:05、V141P 全在 07:25–10:03；纯读项真值必为 0 却实测 −5.25%/−2.26%/+1.03% | 交错粒度从 **block（小时级）** 降到 **round（十分钟级）**，臂间时间间隔缩短一个数量级 |
| 对象数单向棘轮 | mseqwrite 每轮净增 0.9–1.3M，`gc --compact` 对活数据无效，池 2.43M→5.36M，19/32 cell 越 S15 | mseqwrite 移出主矩阵；seqwrite 在每个 block 起点强制排空；ABBA-BAAB 使任何单调漂移一阶抵消 |
| 噪声底未知就设边界 | U141 把边界设在 ±3%，而实测块级偏置达 5.25%，判据无分辨力 | 矩阵内置 **2 个同臂相邻对**（真值=0）直接测噪声底；边界由数据推出，不预设 |

同时吸收 03-22c 已验证的分析纪律（`03-22c-tikv-hybrid-ram-logs-attribution-20260828.md` §9.3）：
以**实际 timed-I/O 起点**对齐、保留 **per-job BW 日志**、报 **W1–W4 / CV / W4/W1**、
**非性能证据门与性能端点分离**（CV 差不是删样本的理由）。

⚑ **不使用 03-22c 的 t66 seed/clone/GC 台架**，原因有两条，必须写进报告：
① t66 只覆盖 randwrite-256inode 单负载，本任务需要 7 项；
② t66 依赖 `juicefs dump/load/clone`，而这三个命令的行为本身就随版本变化，会把待测变量塞进台架。

⚑ **不使用 meta 延迟流形残差判据**（`BW = 1753.6 + 171.5 × 1000/lat`）。理由：U141 已出现 8/8 randwrite
残差全负、均值 −96.1 MiB/s（−1.82σ）、A 臂越界，G8 判据失守；且 03-20B-R2/03-22b/03-22c 已把轮内衰减
归因到 TiKV compaction 与共享 NVMe 软排队，`T_serial_transaction` 不是常数。该流形只允许作为旁证打印，
**不得作为判据**。

---

## 一、唯一目标与问题层级

唯一通过/不通过问题：

> 在同一生产 JuiceFS 卷、同一挂载参数（`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`
> + 私有 `CEPH_CONF` 内 `ms_async_op_threads=8`）、同一 Ceph 数据面和同一文件资产上，
> 把二进制从 `de93563f11a5ff3bd94dd25a4e0283b1`（patched v1.3.1）换成
> `24fae0852051c80ca571cb2f20275d46`（patched v1.4.1）后，
> **七项有效带宽是否每一项都非劣**？

其余只报数据，不作结论：

1. 各项的配对效应量与置信区间；
2. randwrite 的 W1–W4 / CV / W4/W1 是否被版本改变；
3. 元数据格式的双向兼容性与回滚可行性；
4. 距 6250 MiB/s 的缺口（本任务不追求达标，只判版本等价）。

本任务**不测试任何新参数**，不改 TiKV/Ceph/内核/网卡配置，不新增 layout，不动生产 PD/TiKV 服务。

---

## 二、冻结对象与唯一变量

### 2.1 保护对象（全程不得变化）

| 对象 | 冻结要求 |
|---|---|
| 生产 PD/TiKV | systemd 服务、PID/starttime/exe、`/opt/*/conf`、`/mnt/jfs-tikv` 全程不变；只允许 HTTP 只读查询 |
| 生产块设备 | `/dev/nvme0n1`–`/dev/nvme3n1` 全部只读保护；任何命令不得含 `nvme` 写操作 |
| Ceph | 同一 6 OSD、同一 `juicefs-data` pool、同一 CRUSH/PG；只允许 `health/df/osd dump/pg dump/tell ... perf dump` 与已授权的 `ceph tell osd.N compact` |
| 系统 ceph.conf | md5 必须恒为 `5b6be34179a64e0a5f9c6d3a9690041f`；⛔ 禁改、禁 `ceph config set` |
| 私有 msgr conf | `/tmp/t141-msgr8.conf` md5 必须恒为 `86351c58848c7e4caaa1bbeccb211730` |
| 测试脚本 | `/tmp/FULLBASELINE_V4.sh` md5 必须恒为 `4198ea2676ba56744a3cd5eba17a5eab`；⛔ 一个字节都不许改 |
| 文件资产 | `read_test.*.0` 128 个（mtime 必须仍是 `08-04 17:06`）、`rw_test.*.0` 128 个、`storage_test.*.0` 128 个，每个恰 1073741824 字节 |
| 157 | 禁动 WekaIO、K8s、内核、网卡、RoCE、md0 |

### 2.2 唯一变量

| 臂 | 二进制 | md5 | PATH shim |
|---|---|---|---|
| **V13**（在位基座） | `/tmp/juicefs-03-8` | `de93563f11a5ff3bd94dd25a4e0283b1` | `/tmp/t53-bin-new` |
| **V14**（候选） | `/tmp/juicefs-1.4.1-patched` | `24fae0852051c80ca571cb2f20275d46` | `/tmp/t141p-bin` |

两个 shim 目录下均只有一个符号链接 `juicefs`。切臂**只允许**通过 `PATH="<shim>:$PATH"` 实现，
⛔ 禁止 `cp`/`ln -sf` 覆盖 `/usr/local/bin/juicefs`（该文件是错版本 `bdd182cf2cd43be657cb4ec0b5a6a048`，全程不得使用）。

### 2.3 工作负载（全部沿用 V4 冻结值，不得改）

| 项 | fio 规格 | 载体 |
|---|---|---|
| seqread | `psync iodepth=1`，bs=256K，1 job | `test_dir/seqread/` |
| mseqread | `psync iodepth=1`，bs=256K，16 job | `test_dir/mseqread/` |
| randread | `libaio iodepth=128`，bs=256K，128 job，openfiles=128 | `read_test.*.0` |
| randrw | `libaio iodepth=128`，bs=256K，128 job，50/50 | `rw_test.*.0` |
| seqwrite | `psync iodepth=1`，**bs=4M**，size=32G | `test_dir/seqwrite/` |
| mseqwrite | `psync iodepth=1`，**bs=4M**，size=4G，16 job | `test_dir/mseqwrite/` |
| randwrite | `libaio iodepth=128`，bs=256K，128 job，openfiles=128 | `storage_test.*.0` |

`RUNTIME=180`，`REPEAT=1`（每次 V4 调用只跑一轮，轮级交错靠外层循环实现），`direct=1`。

---

## 三、矩阵与交错顺序

### 3.1 固定顺序（⛔ 禁改、禁补点、禁挑轮）

每个 phase 都是 8 轮，顺序恒为：

```text
R01=V13  R02=V14  R03=V14  R04=V13   |   R05=V14  R06=V13  R07=V13  R08=V14
        ── ABBA block 1 ──                    ── BAAB block 2 ──
```

**跨臂配对（4 对，用于效应量）**：

| 对 | 组成 | 相邻性 |
|---|---|---|
| P1 | R01(V13) ↔ R02(V14) | 相邻 |
| P2 | R04(V13) ↔ R03(V14) | 相邻 |
| P3 | R06(V13) ↔ R05(V14) | 相邻 |
| P4 | R07(V13) ↔ R08(V14) | 相邻 |

**同臂相邻对（2 对，用于自校准噪声底，真值恒为 0）**：

| 对 | 组成 |
|---|---|
| N1 | R02(V14) ↔ R03(V14) |
| N2 | R06(V13) ↔ R07(V13) |

平衡性自证（必须在报告中复算并列出）：
V13 占位 {1,4,6,7} 均值 4.5；V14 占位 {2,3,5,8} 均值 4.5 ⇒ **任何对轮序单调的漂移（时间、对象数、
compaction 债）一阶完全抵消**。每个 4 轮 block 内各臂各 2 轮，block 内也平衡。

### 3.2 Phase 划分与 ITEMS 分组

分组的目的是让多个廉价项共享一次 mount/reset/warmup 开销，同时保证两臂的分组与项内顺序**完全相同**。

| Phase | `ITEMS` | 每轮墙钟（估） | 8 轮小计（估） | 排空要求 |
|---|---|---:|---:|---|
| **P0** | 兼容性门（无 fio） | — | ~10 min | — |
| **P1** | `seqread mseqread randread` | ~13 min | ~1.8 h | 无（读项不产生对象） |
| **P2** | `randrw seqwrite` | ~24 min | ~3.2 h | 每个 block 起点（R01 前、R05 前）排空 |
| **P3** | `randwrite` | ~18 min | ~2.4 h | 无（覆盖写，gc 可回收） |
| **P4** | `mseqwrite`（**条件执行**） | ~22 min | ~2.9 h | **每轮**排空 |

- **第一夜 = P0 + P1 + P2 + P3**，估计 7.4 h + 前置约 0.5 h ≈ **8 h**。20:00 起，次日 04:00 前结束。
- **第二夜 = P4**，仅在 P1–P3 全部得出 `非劣` 或 `不可判` 时执行；若 P1–P3 已出现材料性退步，
  结论已成立，**不执行 P4**，直接出报告（省一夜）。

⚑ **S01｜时长校准**：R01 完成后立即把该轮实测墙钟写入 `timing.tsv` 并与上表对比。
若 P1 单轮 >20 min、P2 单轮 >35 min 或 P3 单轮 >26 min，说明估算失真，
**立即 STOP 并回传 `timing.tsv`**，不要抱着"跑到哪算哪"的心态继续（缺臂即整 phase 无效）。

---

## 四、目录、命名与产物布局

```text
RUN_ROOT=/tmp/production/opencode-u141b-<RUN_ID>      # RUN_ID=$(date +%Y%m%d-%H%M%S)
  ├─ MATRIX_AUTHORIZED.tsv        # 冻结的 32 行（4 phase × 8 轮）phase/round/arm/binary_md5/items
  ├─ timing.tsv                   # 每轮 begin/end epoch 与墙钟
  ├─ incidents.tsv                # append-only，任何异常/偏离，动作前后各一条
  ├─ objects.tsv                   # 每轮 pre/post 的 objects/stored/max_avail
  ├─ fingerprint/
  │    ├─ frozen-manifest.tsv     # §2.1 全部冻结项的 md5/mtime/size，R01 前生成
  │    ├─ mount-<PH>-R<nn>-pre.txt   # 挂载后立刻采
  │    ├─ mount-<PH>-R<nn>-post.txt  # 卸载前立刻采
  │    └─ frozen-verify-final.tsv
  ├─ assets/asset-<PH>-R<nn>.tsv  # 384 文件 path/size/mtime（每轮 pre）
  ├─ v4/<LABEL>/                  # 每轮从 /tmp/opencode-fullbaseline-v4/<LABEL>/ 完整拷回
  ├─ rounds-u141b.tsv             # 从 V4 的 rounds.tsv 过滤出本 RUN 的行
  └─ closure/                     # 最终指纹核对、SHA256SUMS、归档
```

LABEL 命名（⛔ 严格照此，报告与复算脚本依赖它）：

```text
U141B-<PHASE>-R<nn>-<ARM>        例：U141B-P1-R01-V13 / U141B-P3-R08-V14
```

⚑ `RESULTS=/tmp/opencode-fullbaseline-v4` 在 V4 `:33` 是硬编码、**不可环境覆盖**；
`LAYOUT_JOBS=128` 在 `:47` 同理。不要试图改，按上表把产物**拷回** `RUN_ROOT/v4/` 即可。

---

## 五、阶段 0 与阶段 I：离线 Gate 0、前置归一化与冻结

### 5.0 阶段 0：离线 Gate 0（零环境接触；未过 ⛔ 禁止 SSH 到 157）

⚑ **为什么加这一节。** 03-19→03-22c 的复盘显示：约 30 个缺陷是在集群上、用一整轮 180 s arm
才发现的，而**它们全部是纯 bash/解析缺陷，一个 fixture 就能覆盖**。清单（必须逐条被 fixture 覆盖）：

| 已知缺陷类别 | 历史出处 | fixture 必须证明 |
|---|---|---|
| `pgrep -f` 匹配到多个 PID（`mount -d` 父子进程） | 03-20B-R2 第 1 次 | 能在 2 个 PID 的伪造 `/proc` 下正确取到**全部** mount pid，且**不**用 `head -1` |
| `stat -c '%n\t%i'` 不解释 `\t` | 03-20B-R2 第 2 次 | 资产清单必须是真制表符分隔，384 行可被 `awk -F'\t'` 正确切分 |
| `ssh` 在 `while read` 内吞掉 fd 0 | 03-20B-R2 第 3 次 | 逐轮循环里调用 ssh 后仍能读到**全部** 32 行矩阵 |
| `sudo` 才能读 root 进程的 `/proc/<pid>/{stat,environ,exe}` | 03-20B-R2 第 4 次 | 无权限时必须 STOP，⛔ 不许静默留空 |
| `local a=$1 b="$a"` 前向引用 + `set -u` | 03-20B-R1 / R2 第 5 次 | 全部 `local` 单变量一行；`bash -u -n` 通过 |
| `echo \| tee` 在 `set -e -o pipefail` 下 SIGPIPE 退出 | 03-20B | 日志函数不含管道 |
| `rados df` 列偏移（`892 GiB` 占两列） | 03-19 / U141 | 只用 `ceph df --format=json` + python3；fixture 喂入真实 JSON 与被截断 JSON |
| `bc` 不支持科学计数法 | 03-20A/B | 全部数值比较用 `awk` |
| `find /home` 权限错误触发 `set -e` | 03-20A | 相关调用带 `\|\| true` |
| 覆盖率把 metric **行数**当 scrape 数 | 03-20B-R1 | 按唯一 epoch 与半开窗口计数，fixture 含边界秒 |
| **fio 实际 I/O 起点用了 fork 时刻（错 58 s）** | 03-20B-R2 | 见下 5.0.2，**这一条权重最高** |
| 部分创建后无完整 destroy plan | 03-22 | drain 失败时保留现场并 STOP |

**Gate 0 交付物**：`gate0/` 目录 + 一行 `U141B_GATE0: PASS`。
Gate 0 ⛔ 不执行 SSH、sudo、mount、fio、ceph、juicefs 任何一条。失败只许改脚本并重跑 Gate 0。

#### 5.0.1 被 fixture 覆盖的对象

⚑ **本节已按实际实现回填（2026-08-28，Gate 0 已 PASS）。**
`scripts/FULLBASELINE/debug/` 下四个新文件 + 一份声明（⚑ 都是本任务新写的，**不是** V4，V4 冻结不动）：

```text
u141b-gate0-offline.sh          离线 Gate 0：静态扫描 + 缺陷类覆盖 + 三个自测编排（不碰环境）
u141b-driver.sh                 32 轮循环、切臂、指纹采集、drain、逐轮硬门、incidents 账本
u141b-collect.sh                单轮轮前/轮后采集（对象数、资产清单、mount 指纹、S10-S12 门）
u141b-analyze.py                per-job BW 重采样 + 正式窗 + W1–W4 + CV + 配对效应 + 噪声底
u141b-defect-applicability.tsv  32 条缺陷类的处置声明（见下）
```

前四者必须先过 `bash -n` / `bash -u -n` / `python3 ast` / `shellcheck`（有则跑），再过下面两个自测。

**⚑ 静态红线扫描只放在 Gate 0 里，不放在被扫脚本内部。**
原因是实测踩到的坑：脚本无法用"存在自己体内的禁用词清单"扫描自己——清单本身必然命中。
Gate 0 的扫描集固定为 `{driver, collect, analyze}`，**明确排除自身**；
并且**先剥离注释再匹配**（一行"⛔ 禁 rm -rf / -uz / -D"的说明性注释不是对该规则的违反）。

**⚑ 缺陷类必须逐条声明处置，不能只数"引用了几条"。**
`u141b-defect-applicability.tsv` 把 32 条缺陷类各归入三档，Gate 0 逐条校验：

| 处置 | 条数 | Gate 0 的校验 |
|---|---:|---|
| `ENFORCED_IN_IMPL` | 14 | 该缺陷号必须在 driver/collect/analyze 中被就地引用，且 `evidence` 字段非空 |
| `ENFORCED_IN_GATE0` | 7 | 该缺陷号必须在 Gate 0 中被引用（静态扫描或冻结纪律） |
| `NOT_APPLICABLE` | 11 | 必须给出 `na_reason`；且 CRIT/HIGH 若被声明不适用，⛔ 不得同时在实现里引用 |

22 条 CRIT/HIGH 必须全部落在上述三档之一，缺一即 Gate 0 FAIL。
不适用的 11 条集中在"本任务没有的机制"：metrics/iostat/PSI 采集、120 s sampler 预检、
远端 sampler 收尾、OSD perf key、临时本地 FS 容量、seed/clone 合同、finalize legacy 数组。

#### 5.0.2 ⭐ 分析器必须先在已有真实数据上自证（零环境成本）

157 上已经存在 08-25 `V141R` / `V141P` 两个全量对的**全部 per-job BW 日志**，位于
`/tmp/opencode-fullbaseline-v4/V141R/*/` 与 `V141P/*/`，而它们的 fio 汇总值是**已知答案**
（例：`V141P` randwrite r1/r2/r3 = 2754/2726/2679，randread = 5571/5569/5605）。

因此 `u141b-analyze.py` 必须先做这件事，**不需要跑任何新负载**：

1. 把这些目录拷到本地 `gate0/fixture-v141/`（只读拷贝，⛔ 不改原目录）；
2. 用分析器算每个 item 的正式窗 mean/median；
3. **对读项（seqread/mseqread/randread）与 seqwrite**，正式窗 median 与 fio 汇总值
   偏差必须 **≤2%** —— 这些项没有明显轮内衰减，两者本应接近；
4. **对 randwrite/randrw**，允许偏差较大（存在衰减），但必须同时输出 W1–W4 且
   **W1 > W4**、`W4/W1 ∈ (0,1]`，并打印实际 I/O 起点与 fio 完成时刻之差；
5. **起点敏感性检查**：把实际 I/O 起点人为 ±1 s、+58 s 各算一遍。
   ±1 s 结果变化必须 <1%；**+58 s 必须显著改变 W1–W4**（这正是 03-20B-R2 踩的坑）。
   若 +58 s 结果几乎不变，说明窗口逻辑没生效，Gate 0 FAIL。

⚑ 这一条是整个 Gate 0 里性价比最高的：**用已经花过钱买到的数据，验证还没花钱的分析器。**

**⚑ 实测结果（2026-08-28，`V141P` 21 个轮目录，只读副本）：`U141B_ANALYZER_FIXTURE: PASS`，
24 项检查 + 起点敏感性全过。它当场抓出了三个真 bug，全部已修：**

| # | fixture 抓到的问题 | 真因 | 修法 |
|---|---|---|---|
| 1 | randrw 正式窗中位比 summary 低 **50%** | randrw 的 per-job 日志把**读写两向交织在同一文件**（第 3 列 `ddir`），而重采样器的 `prev_ms` 单调假设把同一秒的第二个方向当成"区间倒退"直接丢弃，正好丢掉一半 | 按 `ddir` 拆向、每方向独立 `prev_ms`；**逐向对各自的 summary 行核对**，并加断言：报出的值若等于 READ+WRITE 之和即 FAIL（⛔ randrw 两向不得相加） |
| 2 | mseqwrite 偏差 `+6.59%` / `−6.74%` 被判 FAIL | 把 mseqwrite 归进 2% 容差的"低衰减"档是错的——它实测逐秒 CV `12%--13%`、`W4/W1` 可 >1 | 改三档：STRICT（seqread/mseqread/randread/seqwrite，2%）、MODERATE（mseqwrite，8%）、DECAY（randwrite/randrw，改断言 `W1>W4` 且 `W4/W1∈(0,1]`） |
| 3 | `+58 s` 只移动窗口 `1.44%`，判"窗口逻辑失效" | **判定代码自身的 truthiness bug**：位移后 W1 无样本，`window_stats` 返回 `mean=None`，而 `if w1b and w1s` 把 `None`/`0.0` 当成"没动"，恰好放过最强信号；且探针按字母序选中了平坦的 randrw，使该门形同虚设 | 位移后窗口无样本记为 **100% 位移**；探针改为自动选**衰减最强**的项。修后探针选中 randwrite（W1 `3947` → W4 `1440`），`+58 s` 位移 **100%**、正式窗均值变 `+28.1%` |

第 3 条尤其值得记下：**这正是 03-20B-R2 那个 58 秒错位的同型缺陷，而它第一次出现在"用来检测该缺陷的检查代码"里。**
⇒ 结论不是"多写门"，而是**门必须自己也被真实数据验证过一次**。

#### 5.0.3 驱动脚本自测（合成 fixture，不连环境）

| 自测 | 必须的行为 |
|---|---|
| 32 行矩阵解析 | 顺序恒为 `V13 V14 V14 V13 V14 V13 V13 V14`；V13/V14 占位均值都必须算出 4.5，否则 FAIL |
| 切臂解析（S09b） | 伪造 PATH 让 `juicefs` 解析到错误位置 → 必须 STOP |
| 指纹 md5 不符 | 伪造 exe md5 → S10 必须 FAIL 且不继续下一轮 |
| 缺 per-job 日志 | 只放 127 个 `*_bw.*.log` → S14 必须 FAIL |
| 对象数解析 | 喂 `objects=5310000` → S09 必须触发 drain；喂字面 `GiB` → 必须 FAIL 而非当 0 |
| drain 不收敛 | 20 次轮询后仍 >2.5M → 必须 `DRAIN_FAIL` + STOP，⛔ 不许继续 |
| 卸载失败 | 模拟 `fusermount -u` 非零 → 必须保留现场 STOP，⛔ 不得回退到 `-z`/`kill` |
| V4 rc≠0 | 模拟 rc=1 → 该 phase 记 `EVIDENCE_INVALID` 并 STOP |
| `incidents.tsv` | 任何 STOP 前后各写一条；append-only，⛔ 不许改写历史行 |

#### 5.0.4 阶段 0 的三条纪律

1. **R01 开始后脚本一个字节都不许改。** 若必须改，当前 phase 记 `EVIDENCE_INVALID`，
   重跑 Gate 0，**从该 phase 的 R01 重新开始**。⛔ 禁止同 phase 热修后按正常签收
   （首次 03-22c 正是因此整 RUN 作废）。
2. **⛔ 脚本内不得内嵌任何口令。** 口令只从执行 shell 的环境变量读取。
   Gate 0 必须 grep 自身脚本，发现明文口令即 FAIL。
   （既有例外：`/tmp/FULLBASELINE_V4.sh:37` 已内嵌口令，V4 冻结不改，
   但**本任务新写的三个脚本不许重犯**，并在报告"既有风险"节登记 V4 这一项。）
3. **Gate 0 产物随最终归档一起交付**，含三个脚本全文与 md5、fixture 输入与输出、
   V141 自证的偏差表。

### 5.1 环境现状（已由 opencode 于 2026-08-28 14:44 只读确认，仍须复核）

| 项 | 现状 | 处置 |
|---|---|---|
| Ceph | `HEALTH_OK`，6/6 OSD，`juicefs-data` **2.43M objects / 594 GiB** | ✅ 已在基线，无需排空 |
| `/mnt/juicefs` 当前挂载 | **`/tmp/juicefs-1.4.1-patched`**（PID 2777261/2777318，`CEPH_CONF=/tmp/t141-msgr8.conf`，`max_read=262144`），自 08-25 起 | ⚠️ 必须优雅卸载，见 S03 |
| 四个二进制 | md5 全部符合 §2.2 与历史记录 | ✅ |
| 四个 shim | 指向正确 | ✅ |
| `/tmp/t141-msgr8.conf` | `86351c58848c7e4caaa1bbeccb211730` | ✅ |
| `/tmp/FULLBASELINE_V4.sh` | `4198ea2676ba56744a3cd5eba17a5eab` | ✅ |
| t64/t65/t66 残留 | mount 0 个 | ✅ 03-22c 已闭环 |

### 5.2 前置步骤

```bash
RUN_ID=$(date +%Y%m%d-%H%M%S)
RUN_ROOT=/tmp/production/opencode-u141b-${RUN_ID}
mkdir -p ${RUN_ROOT}/{fingerprint,assets,v4,closure}
```

1. **S02｜串行门**：确认 03-22c 已完全 teardown —— `mount | grep -cE 't6[456]'` 为 0、
   无 `pd-server|tikv-server` 临时端口（12379/30160）监听、`losetup -l` 中无 `t6*` backing、
   `pgrep -a fio` 为空。任一不满足 → **STOP**。
   ⛔ U141b 与任何 t6x RUN 绝不并行（共用 6 OSD 与同一 100GbE，且会互相触发 foreign-fio 门）。

2. **S03｜优雅卸载现有 1.4.1 挂载**：
   ```bash
   fusermount -u /mnt/juicefs || sudo umount /mnt/juicefs
   ```
   ⛔ 禁 `-z`/`-l`/`kill`。卸载失败 → **STOP 保留现场**（历史上多次用 kill mount PID 绕过，这次不许）。
   卸载后确认 `mount | grep -c juice` 为 0。

3. **S04｜冻结 manifest**：生成 `fingerprint/frozen-manifest.tsv`，逐行含 §2.1 每一项的
   md5/size/mtime，以及 `/tmp/juicefs-*` 四个二进制、四个 shim 的 readlink。

4. **S05｜文件资产门**：临时挂 V13，核对
   `read_test.*.0`/`rw_test.*.0`/`storage_test.*.0` **各恰 128 个、每个恰 1073741824 字节**，
   且 `read_test.*.0` 的 mtime 仍为 `2026-08-04 17:06`。
   任一不符 → **STOP**（read_test 被重写会使 03-17f 读侧锚点失效）。
   同时确认 `test_dir/seqread/seqread.0.0`、`mseqread`、`seqwrite`、`mseqwrite` 四个子目录存在。

5. **S06｜对象基线**：三次 `ceph df --format=json` 采样（间隔 10 s），
   要求 `objects` 三次 spread ≤4096 且 ≤**2,500,000**。写入 `objects.tsv` 作为 `OBJ_BASE`。
   超过 2.50M 时先执行 §5.3 排空；排空后仍超 → **STOP**。

6. **S07｜P0 兼容性门**（这是升级决策的独立组成部分，不是热身）：
   ```
   ① PATH=V14 → juicefs mount → juicefs status ${META} > p0-status-v14.json → 记录 Setting/UUID/BlockSize/
      Compression/TrashDays/format 相关全部字段 → 优雅卸载
   ② PATH=V13 → juicefs mount → juicefs status ${META} > p0-status-v13.json → 同样记录 → 优雅卸载
   ③ 再次 PATH=V14 挂载/卸载一次（验证 V13 挂过之后 V14 仍可挂）
   ```
   判据：三次挂载全部成功；`p0-status-v13.json` 与 `p0-status-v14.json` 的
   `UUID / BlockSize / Compression / TrashDays / Storage / Bucket` 完全一致。
   若 V14 挂载后 V13 无法挂载，或 Setting 出现不可逆字段变化 → 记 `ROLLBACK_BLOCKED`，
   **仍继续跑性能矩阵**（性能数据有独立价值），但最终结论强制为 `REPLACE_REJECTED`。
   卸载后确认 `mount | grep -c juice` 为 0。

7. **S08｜冻结矩阵**：写 `MATRIX_AUTHORIZED.tsv`（32 行）。R01 开始后 ⛔ 禁止修改本文件、
   禁止修改任何脚本、禁止改顺序。

### 5.3 排空过程（`drain`，仅 P2 block 起点与 P4 每轮使用）

排空**固定用 V13** 执行，使其成为常量：

```bash
export PATH=/tmp/t53-bin-new:$PATH
juicefs mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K "${META}" /mnt/juicefs
rm -f /mnt/juicefs/test_dir/seqwrite/seqwrite.*.0
rm -f /mnt/juicefs/test_dir/mseqwrite/mseqwrite.*.0     # 仅 P4 需要
fusermount -u /mnt/juicefs
juicefs gc --delete --threads 32 "${META}" 2>&1 | tail -5
# 轮询：每 30 s 采一次 objects，最多 20 次
```

判据：`objects ≤ 2,500,000` 且连续两次采样差 ≤4096 ⇒ `DRAIN_PASS`。
20 次仍不达标 → 记 `DRAIN_FAIL` 并 **STOP**（不要"带病继续"，U141 就是这么废掉的）。
⚑ `seqwrite`/`mseqwrite` 的载荷文件删掉后由 fio 自行重建，V4 的非 layout 路径只检查
`storage_test.0.0`/`read_test.0.0`/`rw_test.0.0`/`seqread/seqread.0.0` 四个，删这两个目录内容是安全的。

---

## 六、阶段 II：单轮执行模板（32 轮全部照此，不得简化）

以下为**一轮**的完整流程。`PH`∈{P1,P2,P3,P4}，`nn`∈{01..08}，`ARM`∈{V13,V14}，
`SHIM` 为 `/tmp/t53-bin-new`（V13）或 `/tmp/t141p-bin`（V14），`ITEMS` 按 §3.2。

### 6.1 轮前

```bash
LABEL=U141B-${PH}-R${nn}-${ARM}
echo -e "$(date +%s)\t${LABEL}\tBEGIN" >> ${RUN_ROOT}/timing.tsv
# 对象数 pre（三次采样）
# 文件资产 pre → assets/asset-${PH}-R${nn}.tsv（384 行 path/size/mtime）
# Ceph health + PG primary map
```

⚑ **S09｜轮前对象门**：pre `objects` 必须 ≤ **3,110,000**。超过 → 立即 `drain`；
排空后仍超 → **STOP**。⛔ 本任务**没有 SOFT-PASS**，U141 里"SOFT-PASS 也算通过"这一条已废除。

### 6.2 执行

```bash
export PATH="${SHIM}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CEPH_CONF=/tmp/t141-msgr8.conf

# ⚑ S09b 切臂自证：必须在启动 V4 之前确认解析到本臂二进制
resolved=$(command -v juicefs)
[ "${resolved}" = "${SHIM}/juicefs" ] || { echo "ARM_RESOLVE_FAIL ${resolved}"; exit 1; }
md5sum "$(readlink -f "${resolved}")" | tee -a ${RUN_ROOT}/fingerprint/arm-resolve-${PH}-R${nn}.txt
# 该 md5 必须等于本臂 §2.2 的 md5，否则 STOP

ITEMS="${ITEMS}" OBJ_GATE=1 \
  bash /tmp/FULLBASELINE_V4.sh "${LABEL}" 180 1 --remount \
  > ${RUN_ROOT}/v4-${LABEL}.stdout.log 2>&1
echo "rc=$?" >> ${RUN_ROOT}/v4-${LABEL}.stdout.log
```

⛔ 不要用 `env -i`：V4 `:37` 的 `SSHPASS_CMD` 虽然自带口令、不依赖外部变量，但脚本其它位置
仍依赖常规环境（`HOME`/`USER`/locale）。只 `export PATH` 与 `CEPH_CONF` 即可，
并且必须保证 `PATH` 里 shim 在最前、且 `/usr/local/bin/juicefs`（错版本
`bdd182cf2cd43be657cb4ec0b5a6a048`）永远不会被解析到 —— 这正是 S09b 的作用。

⚑ 附带记录一项既有安全问题（本任务不修，V4 冻结）：`/tmp/FULLBASELINE_V4.sh:37`
把 SSH 口令明文写在脚本里。它已随多个历史归档一起分发。首次 03-22c 因同类问题
（编排器内嵌口令）被判无效，本项应在 U141b 报告的"既有风险"一节单独登记，
并建议后续轮换该凭据、改由执行 shell 注入。

三个必须理解的点：

1. **`OBJ_GATE=1` 是强制的。** V4 `:918/:929/:940/:953` 每个写项循环体最后一句是
   `[ "${OBJ_GATE}" = "1" ] && obj_gate ...`；`OBJ_GATE=0` 时该 `&&` 列表返回 1 ⇒ 函数返回 1 ⇒
   在 `:1352` 触发 `set -e`，脚本会在最后一轮 cleanup 之后、`summary()` 之前退出（rc=1）。
   设成 1 即消除。
2. **`--remount` 是必须的**，它让 V4 用当前 PATH 的 `juicefs` 重新挂载 —— 这正是切臂的实现方式。
3. **`REPEAT=1`（第三个位置参数）**。`RUNTIME`/`REPEAT` 在 V4 里**只认位置参数** `$2`/`$3`，
   环境变量无效。

### 6.3 轮后（顺序不可颠倒）

```bash
# ① 挂载指纹 —— 必须在卸载之前，这是 U141 缺失的关键证据
for p in $(pgrep -f 'juicefs.*mount'); do
  echo "pid=$p exe_md5=$(sudo md5sum /proc/$p/exe | awk '{print $1}')"
  echo "  starttime=$(awk '{print $22}' /proc/$p/stat)"
  echo "  cmdline=$(sudo tr '\0' ' ' < /proc/$p/cmdline)"
  echo "  ceph_conf=$(sudo tr '\0' '\n' < /proc/$p/environ | grep ^CEPH_CONF=)"
done > ${RUN_ROOT}/fingerprint/mount-${PH}-R${nn}-post.txt
mount | grep juice >> ${RUN_ROOT}/fingerprint/mount-${PH}-R${nn}-post.txt

# ② 对象数 post（三次采样）→ objects.tsv
# ③ 拷回全部产物
cp -a /tmp/opencode-fullbaseline-v4/${LABEL} ${RUN_ROOT}/v4/
grep -P "^${LABEL}\t" /tmp/opencode-fullbaseline-v4/rounds.tsv >> ${RUN_ROOT}/rounds-u141b.tsv
# ④ 优雅卸载
fusermount -u /mnt/juicefs || sudo umount /mnt/juicefs
echo -e "$(date +%s)\t${LABEL}\tEND" >> ${RUN_ROOT}/timing.tsv
```

### 6.4 逐轮硬门（任一失败 → 该 phase 记 `EVIDENCE_INVALID`，STOP，⛔ 禁止补样）

| Gate | 检查 | 条件 |
|---|---|---|
| **S10** | `exe_md5` | 该轮**所有** `juicefs.*mount` 进程的 `/proc/<pid>/exe` md5 必须等于本臂 §2.2 的 md5 |
| **S11** | `CEPH_CONF` | 每个 mount 进程 environ 必须含 `CEPH_CONF=/tmp/t141-msgr8.conf` |
| **S12** | `max_read` | `mount` 输出必须含 `max_read=262144` |
| **S13** | fio 有效性 | `rounds.tsv` 该轮 status 必须为 `VALID`；本轮所有 item 均无 `INVALID.txt` |
| **S14** | per-job BW 日志 | randread/randrw/randwrite 各 **128** 个 `*_bw.*.log`；seqread/seqwrite 各 1 个；mseqread/mseqwrite 各 16 个 |
| **S15** | 对象数 | pre ≤3,110,000；post − pre 记录在案（不设上限，但必须有数值，不得是字面 `GiB`） |
| **S16** | 文件资产 | 384 个文件数量与大小与 S05 一致；`read_test.*` mtime 不变 |
| **S17** | Ceph | 全程 `HEALTH_OK`；PG `nonclean=0`；primary map 恒为 `[0:6 1:6 2:5 3:6 4:5 5:4]` |
| **S18** | 冻结项 | 系统 ceph.conf、msgr conf、V4 脚本三个 md5 不变 |
| **S19** | 卸载 | 优雅卸载成功且 `mount \| grep -c juice` 为 0 |

⚑ **S20｜性能端点不是证据门**：CV、W4/W1、带宽绝对值**再差也不删样本**，
它们是正式比较结果。这是 03-22b 用 CV 当证据门导致整 RUN 无法回答稳定性问题的直接教训
（见 `03-22b-...-20260827.md` §6）。

---

## 七、离线复算口径（opencode 执行；GLM 只交原始数据，⛔ 不得自行下结论）

### 7.1 带宽主口径

⛔ **不采用 fio summary 作为主口径**（历史上多次因此得出错误结论：03-19 §4.2 的 24–26% vs
真实 10–13%、03-20A 的 2939 vs 正式窗 2828）。

主口径固定为：

1. 对每个 item 的全部 per-job BW 日志，按**实际 timed-I/O 起点**对齐（起点 =
   fio 报告的完成时刻 − `run=` 实际毫秒数；⛔ 不得用 fork 时刻，03-20B-R2 曾因此错位 58 秒）；
2. 日志是 interval-average（`--log_avg_msec=1000`），按区间与自然秒的**重叠时长加权重采样**到 1 s；
3. 逐秒把该 item 的全部 job 求和，只保留当秒 job 数齐全的样本；
4. 正式窗 = `[15,175)`；报 mean / median / 秒级 CV / P10 / P90；
5. randwrite 与 randrw 额外报 W1`[15,55)` / W2`[55,95)` / W3`[95,135)` / W4`[135,175)` 与 `W4/W1`。

### 7.2 效应量与噪声底

对每个 item：

```text
跨臂效应：  D_k = BW(V14 轮) / BW(V13 轮) − 1        k = P1..P4
效应量  ：  D_med = median(D_1..D_4)
噪声底  ：  ε = max( |N1|, |N2| )                    N1 = R03/R02 − 1, N2 = R07/R06 − 1
判定边界：  M = max( 3.0%, 2 × ε )
```

⚑ 噪声底用**同臂相邻对**估计，这是本设计的核心：N1、N2 的真值恒为 0，
所以 |N1|、|N2| 直接量化"同一臂、相邻两轮"的不可归因波动。
若 `ε ≥ 3.0%`，说明该 item 在本设计下分辨力不足，**必须**标记 `RESOLUTION_INSUFFICIENT`，
只报 D_med 与 M 作为上界，⛔ 不得宣告"等价"或"非劣"。

### 7.3 逐项判定（预注册，⛔ 不得事后改）

| 条件 | 该项判定 |
|---|---|
| `D_med ≥ −M` 且 4 对中 ≥3 对 `D_k ≥ −M` 且 `ε < 3.0%` | **NON_INFERIOR** |
| `D_med < −M` 且 4 对中 ≥3 对同为负 | **MATERIAL_REGRESSION**（报 D_med 与逐对值） |
| `ε ≥ 3.0%` | **RESOLUTION_INSUFFICIENT** |
| 其余（方向不足 3/4） | **INCONCLUSIVE** |

### 7.4 总判定

| 条件 | 结论 |
|---|---|
| 七项全部 `NON_INFERIOR`，且 P0 兼容性门通过 | **`REPLACE_APPROVED`** |
| 任一项 `MATERIAL_REGRESSION` | **`REPLACE_REJECTED`**（列明项、幅度、逐对值） |
| 无退步但存在 `RESOLUTION_INSUFFICIENT`/`INCONCLUSIVE` | **`REPLACE_NOT_PROVEN`**（列明哪几项未闭合、所需增量样本） |
| P0 出现 `ROLLBACK_BLOCKED` | 强制 **`REPLACE_REJECTED`**，无论性能如何 |
| 任一非性能硬门失败 | **`EVIDENCE_INVALID`** |

### 7.5 只报不判的旁证

- 各项对 03-17f 七项（1449/5366/5544/1870/1570/4676/2707）的偏差 —— **跨批，仅供追溯，不入判定**；
- `meta/写op`、meta `Write` 延迟、transaction 计数（从 V4 的 `jfs-stats-pre/post.txt` 差分）；
- 恒等式自检 `在飞 meta ≡ 4 × BW(MiB/s) × 延迟(s) × (meta/写op)`；
- randwrite 的 W4/W1 与 03-19/03-20/03-22c 历史区间（0.36–0.44 生产 / 0.88–0.99 fresh 临时集群）对比；
- 距 6250 MiB/s 的缺口。

---

## 八、失败处理与红线

1. 任何硬门失败：**停止当前 phase、保留现场**（不卸载、不删目录、不清 sampler），
   在 `incidents.tsv` 记动作前后各一条，回传后由 opencode 判定。⛔ 禁止换 RUN_ID 重来、
   禁止同 RUN 热改脚本、禁止补样替换。
2. ⛔ 禁 `pkill`/`killall`/`fuser -k`/模式 kill；⛔ 禁 `fusermount -uz`、`umount -l`、
   `losetup -D`、`rm -rf`；⛔ 禁 kill mount PID。这四条在 03-19/03-20A/03-20B/首次 03-22c
   都被违反过，本任务视为红线。
3. ⛔ 禁 reboot/shutdown/systemctl 改生产服务；⛔ 禁写 `/dev/nvme*`、`/mnt/jfs-tikv`、
   `/opt`、`/etc`、`/var/lib/ceph`。
4. ⛔ 禁 `ceph osd pool delete/create`、禁改 CRUSH/PG/pool 参数、禁 `ceph config set`。
5. 允许的 sudo 写操作**全集**：三节点 `echo 3 | sudo tee /proc/sys/vm/drop_caches`（V4 内部）、
   `sudo ceph tell osd.N compact`（V4 `compact_cooldown` 内部）。此外只有只读 sudo
   （`ceph health/df/osd ls/osd dump/pg dump/tell ... perf dump`、`md5sum /proc/<pid>/exe`、
   `cat /proc/<pid>/cmdline|environ`）。不在此列的 sudo 写操作一律禁止。
6. 脚本实现层 bug 可修，但必须：停止当前 phase、在 `incidents.tsv` 说明 diff 与原因、
   重新生成指纹、**从该 phase 的 R01 重跑**。⛔ 不得在已开始的 phase 中静默换脚本。
7. 长跑期间按 `LONG-RUNNING-TEST-SKILL.md` 每 10–30 min 检查：当前 mount PID、
   `v4-*.stdout.log` 尾部、Ceph health、objects、`MemAvailable`、无 foreign fio。
8. `/tmp` 持久化：R01 前把 `/tmp/juicefs-03-8`、`/tmp/juicefs-1.4.1-ceph`、
   `/tmp/juicefs-1.4.1-patched`、`/tmp/t141-msgr8.conf` 连同 md5 复制到
   `${RUN_ROOT}/closure/binaries/`，防 `/tmp` 清理导致 1.4.1 二进制需重新编译。

---

## 九、交付物

结果根目录：`${RUN_ROOT}`。归档：`/tmp/production/opencode-u141b-<RUN_ID>.tar.gz` + `.sha256`，
并 `scp` 回 `/home/lilingfeng/tmp/production/`。

必须交付（缺任一项按 `EVIDENCE_INVALID` 处理）：

1. `MATRIX_AUTHORIZED.tsv`、`timing.tsv`、`incidents.tsv`、`objects.tsv`、`rounds-u141b.tsv`；
2. `fingerprint/frozen-manifest.tsv` + 32 组 `mount-*-post.txt` + `frozen-verify-final.tsv`；
3. `assets/` 32 份 384 行资产清单；
4. `v4/` 32 个 LABEL 目录**完整**内容（fio.txt、全部 `*_bw.*.log`、jfs-stats-pre/post、
   mount-cmd.txt、pg-summary、hit-rate、nic.txt、gear.txt）；
5. P0 的 `p0-status-v13.json` / `p0-status-v14.json` 与三次挂载日志；
6. 每次 `drain` 的前后对象数与 `gc --delete` 原文输出；
7. `closure/`：最终冻结项核对、生产 PD/TiKV 指纹、Ceph health/PG、二进制副本、
   `SHA256SUMS` 自校验全 PASS；
8. 内层 `SHA256SUMS` 与外层 `.sha256` 都必须自校验通过。

⚑ **GLM 的交付边界**：只交原始数据 + 硬门 PASS/FAIL 清单 + `incidents.tsv`。
⛔ **不要**在报告里写效应量、不要写"非劣/等价/退步"、不要算 CV/中位数、不要挑轮次。
全部统计由 opencode 从原始 per-job 日志复算（历史上 GLM/DeepSeek 的算术多次出错：
03-19 的 24–26%、03-20A 的"字段不存在"、03-22c 首次的 GC 数字与"D1 降低 NVMe await"）。

回传节奏（减少往返，不降低准确性）：

| 批次 | 内容 | 停下等审核？ |
|---|---|---|
| 批 0 | **Gate 0**：三个脚本全文+md5、fixture 输出、V141 自证偏差表、起点敏感性三算 | **是**，opencode 审完才许 SSH |
| 批 1 | 阶段 I 全部（S02–S08）+ P0 兼容性结果 + R01 实测 `timing.tsv` | **是**，校时长 + 核 P0 |
| 批 2 | P1 八轮 + P2 八轮（含逐轮硬门表、objects.tsv、指纹） | **是** |
| 批 3 | P3 八轮 + 归档 + `closure/` | **是**，出前三 phase 判定 |
| 批 4 | （条件）P4 八轮 + 最终归档 | 是 |

**phase 内部不要停**：一个 phase 的 8 轮必须连续跑完（除硬门失败），
中途停下重挂/等指令会引入新的时间偏置，正好破坏轮级交错的全部意义。
**phase 之间必须停**：一个 phase 废掉不该拖累下一个，而且 P1/P2 的结果会决定 P4 是否需要跑。

---

## 十、通用注意事项（逐项复核后在报告中打勾）

1. 所有 fio 保留全部 per-job `*_bw.*.log`；按时间戳整秒对齐求和。
   ⛔ 禁单文件乘 job 数、⛔ 禁用 fio 汇总均值代替正式窗。
2. `REPEAT` 概念在本任务是 **8 个独立轮/phase**，不是同 mount 重跑；
   报全部点、逐对比值、同臂对噪声底，⛔ 不挑轮。
3. 每轮都是 `--remount` 新挂载实例。新挂载首个写轮的 `.stats` pre 计数器缺失属正常，
   记 `pre=0` 并标 `r1*`。
4. 写项后 `aggressive_cleanup`（V4 `:589-601`）需 8–12 min，属预期，不要以为卡死。
5. `obj_gate` 的 `SOFT-PASS` 语义在本任务**作废**：一切以 S09/S15 的数值门为准。
6. `pool_sample` 必须用 `ceph df --format=json` + python3 解析。
   ⛔ 禁 `rados df` 列切分（`892 GiB` 占两列，03-19 因此让 8M 硬门从未生效、
   U141 因此把 5.31M 解析成 `1.3`）。
7. `commands.sh` 记录实际执行的全部命令（含 PATH、env、位置参数），口令除外。
8. 报告每个数字必须标出来源文件与字段名；TiKV/Ceph metric 名先实查再写，⛔ 禁凭印象。
9. 测试后对照全部 skill 做合规自查：清理方式、compact 三指标、health 证据、
   BW §8.3、sudo 授权、无生产状态变化；任一不符显式说明对结论的影响。

### 最终红线一句话

本任务可以丢掉的是 `test_dir` 下 `seqwrite/`、`mseqwrite/` 的载荷文件和本 RUN 的 COW 垃圾对象；
**绝不能碰**的是 `read_test.*`/`rw_test.*`/`storage_test.*` 这 384 个文件资产、
生产 PD/TiKV/Ceph 的任何配置或服务、系统 `ceph.conf`、`/tmp/FULLBASELINE_V4.sh`，
以及任何无法由指纹文件精确证明归属的 PID 或挂载。
