# 04-tmp2 任务书：JuiceFS 本地读缓存最小稳定收益 canary

## 日期：2026-09-02

> 实验编号：`TMP-CACHE1`，不占正式 `04-N` 编号。
>
> 面向：GPT 制定合同、审核与复算；Luna 编写/执行脚本并提交原始证据。
>
> 当前状态：`COMPLETED / CACHE_SCREEN_EVIDENCE_INVALID / ENVIRONMENT_CLOSED`。
>
> 最终报告：`doc/perf-report/04-tmp2-juicefs-local-read-cache-stability-canary-20260902.md`；
> RUN `20260902-133433`。32 GiB 热集出现强机制信号，但 R02 正式窗仍填充缓存且热点主要由
> Linux 页缓存承载，未形成可交付的 NVMe 缓存稳定收益；不补跑、不升级 L2。
>
> 方法论：执行前必须通读 `skills/SYSTEM-SAFETY-SKILL.md`、
> `skills/EVIDENCE-INTEGRITY-SKILL.md`、`skills/TESTING-GUIDE.md`、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` 和
> `doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`。

```text
EVIDENCE_LEVEL=L1_SCREEN
MINIMUM_DECISION_SET=同一既有数据集上的A(cache=0)/B(cache=64GiB且固定32GiB热窗口全暖)单个ABBA
STOP_AFTER_ANSWER=无明确稳定材料信号即关闭；本RUN不追加容量点、八轮L2、randrw或writeback
MAX_PREP_BUDGET=60min；超时先删非决策功能，不继续扩建框架
MAX_EXECUTION_BUDGET=2h（不含事故现场人工审核）
SCREEN_MATRIX=R01-A,R02-B,R03-B,R04-A
SCREEN_UPGRADE=仅当命中合同通过且收益超过动态材料线，另行审核是否开展192GiB全工作集L2
CACHE_MEDIUM=157本地独立NVMe；Phase I只读核验，禁止tmpfs/RAM盘
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=按RUN专属cache state和单独授权精确清理
```

---

## 计划线

```text
04-1b：已完成并收口
  ↓
04-tmp2 Phase 0：最小脚本 + 离线 Gate 0              ✓
  ↓
Phase I：只读 inventory + mount/scrub/cache目录计划
  ↓（GPT审核；涉及sudo写操作时由用户按完整命令授权）
Phase II：一次确定性预热 + ABBA四轮只读screen
  ├─ 无材料信号/机制门失败：恢复环境并关闭方向
  ├─ 明确信号但噪声过大：只记工程观察，不自动补轮
  └─ 稳定材料信号：恢复环境后再决定是否升级192GiB全工作集L2
  ↓
Phase III：恢复scrub、精确清缓存目录、cache=0恢复锚、持久化
  ↓
正式结论：CACHE_SCREEN_EVIDENCE_INVALID；环境已关闭，不升级L2
```

一句话任务：不新建 layout、不修改 JuiceFS 数据，只在现有 128 个文件的固定 32 GiB 热窗口上，
用一个 64 GiB 本地 NVMe 缓存验证“全命中本地缓存”相对 `cache-size=0` 是否存在明显且稳定的
randread 收益，并证明所有本任务状态可恢复。

---

## 一、为什么这样测

早期缓存测试出现过明显提升，但当时 100 GiB 缓存小于 128 GiB 工作集，正式轮同时经历填充和
淘汰，带宽随轮次单调上升，不能证明固定缓存状态下的稳定收益。当前无缓存 randread 已约
`5544 MiB/s`，本地单盘 NVMe 也可能低于 Ceph 聚合读能力，因此必须重新做同窗 A/B。

本轮只做低成本筛选，不直接做原任务书的 192 GiB/八轮正式矩阵：

- 继续使用现有 `read_test.0.0`～`read_test.127.0`，每个文件只访问固定前 256 MiB；
- 128 inode、128 job、256 KiB I/O 和总并发均保持不变；
- 热窗口总量为 32 GiB，64 GiB 缓存提供足够余量，避免淘汰成为变量；
- A/B 访问完全相同的文件和范围；B 在正式轮前一次性预热，正式轮不得继续兼任预热；
- 若这个理想全命中窗口都没有明确收益，就没有必要为全量 192 GiB 实验投入更多时间。

该结论只回答“本地读缓存方向是否值得升级”，不能直接作为生产缓存容量建议，也不能替换无缓存
交付基线。

---

## 二、唯一问题、变量和判据

### 2.1 唯一问题

在相同二进制、卷、文件、热窗口、fio 参数和近似后端起点下，稳定全暖的 64 GiB 本地读缓存是否
能给 randread 带来超过本批次噪声底的至少 5% 收益？

### 2.2 冻结变量

| 项 | A / NOCACHE | B / WARM-CACHE |
|---|---|---|
| mount | `--read-only --cache-size 0 --prefetch 0` | `--read-only --cache-size 65536 --cache-dir <RUN_DIR> --free-space-ratio 0.2 --prefetch 0` |
| 共同参数 | `--max-fuse-io 256K --max-uploads 150`，同一 META/CEPH_CONF/binary；均不传 `--max-readahead`，保持当前交付默认值 | 同左 |
| fio | 全局 `--readonly`；`randread, bs=256k, numjobs=128, iodepth=128, direct=1, runtime=180s` | 同左 |
| 数据范围 | 每个既有 1 GiB 文件固定 offset 0、size 256 MiB | 同左 |

正式顺序：`R01-A(seed=41001), R02-B(seed=41001), R03-B(seed=41002), R04-A(seed=41002)`。
两组相邻跨臂比较使用相同 randseed。每个 cell 使用独立挂载进程；B 两轮复用同一个已预热缓存
目录，但不得重新 warmup。任一时刻只有一个测试挂载和一个 fio。

driver 必须生成一份冻结 jobfile，显式写出 128 个 job section，每个 section 只绑定一个既有文件；
禁止依赖默认 filename 展开。全局合同如下：

```text
fio --readonly <jobfile>

[global]
rw=randread
bs=256k
offset=0
size=256M
ioengine=libaio
iodepth=128
direct=1
fallocate=none
allow_file_create=0
create_on_open=0
time_based=1
runtime=180

[read_test_000]
filename=<MOUNT>/test_dir/read_test.0.0
...
[read_test_127]
filename=<MOUNT>/test_dir/read_test.127.0
```

不传 `filesize`，避免把逻辑热窗口误写成文件尺寸合同；`offset=0 + size=256M`把每个 job 的
随机 I/O 限制在既有 1 GiB 文件的前 256 MiB。预热 jobfile 使用相同 128 个显式 filename、
`rw=read,time_based=0,size=256M`，恰好顺序读取 32 GiB 一次；禁止对整个目录执行
`juicefs warmup`。Gate fixture 不运行 fio，只验证 driver 生成的 128 个 job、路径集合、参数和
资产 manifest，并拒绝任何会创建文件或改变 size/mtime 的参数。正式执行仍额外使用 fio 全局
`--readonly` 安全门；jobfile 不写不存在的 `readonly=1` job option。

### 2.3 主指标

按实际 timed-I/O 起点和 per-job bw log 复算 `[15,175)`：

- 每轮 randread mean/median、秒级 CV、P10/P90、W1～W4 和 `W4/W1`；
- `A_mean=(R01+R04)/2`、`B_mean=(R02+R03)/2`；
- `effect=B_mean/A_mean-1`；
- `epsilon=max(|R04/R01-1|, |R03/R02-1|)`；
- 动态材料线 `M=max(5%,2*epsilon)`。

### 2.4 缓存命中合同

Phase I 优先发现最终 JuiceFS 二进制可用的精确 cache hit/miss 指标。若没有可直接审计的字段，
不因此扩建采集框架，可使用以下三源联合证明：

1. RUN 缓存目录物理占用稳定且没有 eviction/rawstaging；
2. B 正式窗本地 NVMe 有与 fio 读取量同量级的读流量；
3. B 正式窗 157 NIC/Ceph 读字节相对 fio 有效读字节不高于 10%。

三源不能闭合则命中合同失败，性能点只作工程观察。

### 2.5 L1 verdict

| 条件 | 结论 |
|---|---|
| 非性能门失败、缺 cell、命中合同失败 | `CACHE_SCREEN_EVIDENCE_INVALID` |
| `epsilon>=5%` | `CACHE_SCREEN_RESOLUTION_INSUFFICIENT`，不自动补轮 |
| `effect>=M`，两次 B 均高于相邻 A，B 的 `W4/W1` 在 `[0.95,1.05]` | `CACHE_SCREEN_MATERIAL_SIGNAL` |
| B 明显低于 A 超过 `M` | `CACHE_SCREEN_LOCAL_PATH_REGRESSION` |
| 其余 | `CACHE_SCREEN_NO_MATERIAL_SIGNAL` |

只有 `CACHE_SCREEN_MATERIAL_SIGNAL` 才讨论后续 192 GiB 全工作集 L2；本 RUN 不预建、不执行该矩阵。

---

## 三、数据、环境与安全合同

### 3.1 固定资产

- 二进制：`/tmp/juicefs-1.4.1-patched`，MD5
  `24fae0852051c80ca571cb2f20275d46`；
- META：`tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod`；
- 既有参考卷和 `/mnt/juicefs` 只作身份/资产来源，不在原挂载点直接测试；
- 测试挂载点只能是 `/tmp/jfs-04tmp2-<RUN_ID>-<LABEL>`；每次创建前要求路径不存在、realpath
  位于 `/tmp`、无 symlink/foreign fd，优雅卸载后仅删除该空目录；
- 测试前后保存 128 个文件的 path/inode/size/mtime/SHA256 清单；必须全部仍为 1 GiB；
- 禁止 format、destroy、layout、write/randwrite/randrw、truncate、fallocate、create_on_open。

旧无效 RUN 的 pool/auth/upmap 是 `KNOWN_EXCLUDED_ASSET`：本任务只记录指纹，不检查其内容、不修复、
不清理，也不把它纳入本任务 UNKNOWN 项。

### 3.2 缓存盘 Phase I 只读门

候选路径 `/mnt/jfs-cache` 只有在以下全部成立后才能使用：

1. `findmnt/lsblk/maj:min/PKNAME/WWN/serial/model` 证明它是独立顶层 NVMe；
2. 它不是 `/`、`/tmp`、md/dm/LVM、Ceph OSD、TiKV、WekaIO 或其他业务路径的上下游设备；
3. `lsof/fuser` 和目录清单没有 foreign 使用者；
4. 可用空间至少 256 GiB，inode 充足；
5. SMART 无 critical warning/media error，温度正常；
6. 连续 60 秒空闲采样无持续 foreign I/O。

若现场未安装 `nvme-cli/smartmontools`，本只读 canary 不为此安装软件；改用控制器
`state=live`、设备身份、60 秒空闲采样以及测试期 `fio/JuiceFS` 零错误作降级门，并在报告中把
SMART 记为未覆盖项。若同一空 ext4 还存在历史挂载别名，只在别名与候选路径的
`SOURCE/maj:min/dev/inode` 完全一致、别名目录同样仅含 `lost+found`、且无对应服务、进程、FD
或 I/O 时允许继续；整个 RUN 冻结两条挂载，任一状态变化立即停止。这不允许卸载或修改历史别名。

唯一可创建目录：`/mnt/jfs-cache/jfs-04tmp2-<RUN_ID>`。创建前必须验证 realpath、父挂载设备、
路径不存在且不是 symlink。未知文件、FD、设备关系或容量不足时立即停止，不清理、不换路径。

### 3.3 环境控制

- 157 上不得执行全局 `drop_caches`，不得改内核、NUMA/IRQ、网络、RoCE、md0、WekaIO/K8s；
- 本任务不重启 OSD/PD/TiKV，不 compact，不改 balancer/pool/upmap；
- 为避免随机 scrub 污染短矩阵，计划复用已签收的 `u141d-scrub-control.sh` 暂停
  `noscrub + nodeep-scrub`，但只在 Phase I 输出完整 plan、用户逐条授权后执行；
- pause 前要求 HEALTH_OK、PG active+clean、全部 OSD up/in；结束或失败都优先精确 restore；
- 除 scrub flags 外，任何 Ceph 状态变化均使本 RUN 停止。

### 3.4 禁止项

- 禁止 `rm -rf`、glob 清理、父目录递归、lazy/force umount、模式 kill、`pkill`、`killall`；
- 禁止 mkfs、fstrim、blkdiscard、nvme format/sanitize、挂载或卸载缓存物理盘本身；
- 禁止在嵌套 SSH 命令中传递可为空的路径变量；
- 任何 sudo 写命令必须先列出节点、完整命令、精确目标和恢复命令，经用户明确授权；
- 失败保留现场，只有安全恢复所需动作可以在新的 inspect/plan/授权后执行。

---

## 四、最小脚本集与离线 Gate 0

仅新增四个文件，并复用既有 scrub 控制器：

```text
scripts/FULLBASELINE/debug/t04tmp2-cache-run.sh
scripts/FULLBASELINE/debug/t04tmp2-cache-cleanup.sh
scripts/FULLBASELINE/debug/t04tmp2-cache-analyze.py
scripts/FULLBASELINE/debug/t04tmp2-cache-gate0-offline.sh
复用 scripts/FULLBASELINE/debug/u141d-scrub-control.sh
```

`run.sh` 用显式子命令区分 `inventory`、`plan`、`prepare`、`screen` 和 `post-anchor`；cleanup 只处理
缓存目录的 inspect/plan/destroy，避免性能脚本拥有删除能力。采样只保留与当前裁决直接相关的
fio/NIC/NVMe/cache/health 字段，不新建通用 sampler 平台。

Gate 0 只覆盖新增路径和会改变结论/系统安全的缺陷：

1. `bash -n`、Python compile、可用时 shellcheck，并对四个新增文件逐一做 whitespace/diff check
   （不得假设未跟踪文件会被普通 `git diff --check` 覆盖）；
2. 禁明文口令、禁 Gate 联网、禁实际 SSH/sudo/ceph/juicefs/fio；
3. A/B mount 必须含 `--read-only --prefetch 0`、均不得传 `--max-readahead`，fio 必须含全局
   `--readonly`；只允许 randread/read warmup，
   拒绝所有写/layout/format/destroy/writeback/rawstaging；
4. 固定 `cache-size=65536`、32 GiB 热窗口、128 文件/job、ABBA、runtime 和 mount 共同参数；
5. 缺文件、大小错误、symlink、PID/META/binary/CEPH_CONF 不匹配必须 fail closed；
6. 缓存路径守卫拒绝空值、`/`、父目录、`..`、glob、跨设备和 foreign fd；
7. cleanup 的 plan 与执行只接受 state 中登记的精确 RUN 根，重复/部分状态安全失败；
8. fio 128 份 bw log、实际 I/O 起点、正式窗和 A/B 统计用合成 fixture 自证；
9. 复用 scrub 控制器只跑其已存在的离线 self-test，不复制控制逻辑。

Gate PASS 后冻结 SHA256；正式 screen 开始后脚本不得热改。

---

## 五、执行阶段和停点

### Phase 0：离线准备

Luna 实现最小脚本和 fixture；GPT 审核任务合同、脚本、安全 grep、fixture 和 Gate 输出。禁止 SSH。

### Phase I：只读 inventory 与计划

Gate PASS 后，Luna 可连续完成以下只读工作并一次回传：

1. 核对 binary/version/MD5、META/UUID/Setting、当前挂载身份和 foreign fio/mount；
2. 核对 128 个文件资产及固定 32 GiB 热窗口；
3. 完成 §3.2 缓存盘 inventory；
4. 发现可用 cache 指标或冻结三源命中代理；
5. 输出实际 mount/warmup/fio 命令、缓存目录 create/cleanup plan；
6. 输出 scrub pause/restore 的完整 sudo 命令与状态所有权；
7. 保存脚本 SHA、风险摘要和环境指纹后暂停。

只读 inventory 不授权创建目录、mount、fio、sudo 写操作或清理。

### Phase II：一次预热与 ABBA screen

仅在 GPT 审核且用户授权精确状态变更后连续执行：

1. 创建并验证唯一 RUN 缓存目录；
2. B 挂载后，以 128 job 顺序只读每文件固定前 256 MiB，一次性填充 32 GiB 热窗口；
3. 卸载 PREP 挂载，验证缓存目录占用稳定、无 eviction/rawstaging；
4. 按 plan pause scrub，等待当前 scrub 退出；
5. 连续完成 `R01-A,R02-B,R03-B,R04-A`：独立挂载、身份门、采样、180 秒 fio、优雅卸载；
6. 性能差不得重跑；非性能门失败则记录 incident、保留现场并停止；
7. 矩阵结束立即 restore scrub 并验证。

### Phase III：恢复、清理与持久化

1. 确认无本任务 mount/fio/open fd，先把矩阵原始证据、实际脚本、commands 和 SHA256 增量同步到
   唯一持久化根并签 `MATRIX_PERSISTENCE_PASS`；
2. 运行 cleanup `inspect` 和 `plan`；用户审核精确目标后，删除 RUN 专属缓存内容和目录，
   不触碰父目录/foreign 文件；
3. 以 A 配置跑一次 180 秒 `POST-A` 恢复锚；其值与 R01/R04 均值偏差不超过
   `max(10%,2*epsilon)`，且资产/health/对象数一致，签 `DOWNSTREAM_RESUME_PASS`；
4. 增量同步原始证据至唯一持久化根，核对文件数、SHA256、实际脚本和 `commands.sh`；
5. GPT 独立复算并给出 L1 verdict；无材料信号时直接关闭，不追加容量点或正式矩阵。

阶段停点只有：Gate 后、Phase I 计划审核、sudo/目录清理授权、L1→L2 决策。阶段内部不逐小步停。

---

## 六、最小有效证据与生命周期

必须保存：

- binary/META/UUID/PID/starttime/exe/CEPH_CONF、mount 实际参数；
- 数据资产 pre/post 清单；
- cache 设备 inventory、目录 state、create/cleanup plan 和 audit；
- scrub state/audit；
- 每个 cell 的 fio JSON/stdout/stderr、128 份 bw log、实际命令、NIC/NVMe/cache/health 原始采样；
- `incidents.tsv`、冻结脚本、SHA256、Gate 输出、analyzer 输出和最终报告。

公共 inventory 每 RUN 只保存一次，cell 只增量保存自身数据；禁止反复复制整个远端树。
未归因失败现场不清。只有 `PERSISTENCE_PASS` 且审核完成后，才按精确清单清理远端临时证据。

最终交付：

- `doc/perf-report/04-tmp2-juicefs-local-read-cache-stability-canary-<DATE>.md`；
- `/mnt/c/SunRise/test/04-tmp2/<RUN_ID>/` 唯一权威证据；
- 只有后续 L2 确认可交付时才更新 results-table 的条件性缓存行；本 L1 不覆盖无缓存数据。

---

## 七、预计时长与后续

| 阶段 | 预计时长 |
|---|---:|
| Phase 0 最小脚本 + Gate | `<=60 min` |
| Phase I 只读 inventory/plan | `20--40 min` |
| Phase II 预热 + ABBA | `35--70 min` |
| Phase III 恢复锚、持久化和复算 | `30--60 min` |

若 L1 有稳定材料信号，后续才设计 192 GiB 缓存覆盖完整 128 GiB 工作集的 L2
`ABBA-BAAB`；容量/命中率曲线、randrw、writeback 均另立任务。若 L1 无信号或本地路径回退，
04-tmp2 到此关闭。
