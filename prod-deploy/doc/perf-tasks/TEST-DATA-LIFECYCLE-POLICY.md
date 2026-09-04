# 测试数据生命周期规范（Test Data Lifecycle Policy）

## 版本与适用范围

> 生效日期：2026-09-01  
> 适用范围：`prod-deploy` 下所有性能测试、离线 Gate、inventory、可行性探针、正式矩阵、
> 独立复算和事故调查产生的证据文件。  
> 权威入口：`doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.6、§二.21。

本规范解决两个问题：

1. 测试证据不能因157、集群、`/tmp`或WSL重启而丢失；
2. 已过期、重复或无效的数据不能因“失败即保留现场”而无限堆积。

本规范**不授权**删除或修改 JuiceFS 卷、Ceph pool/对象、TiKV namespace、挂载、进程、
loop/tmpfs/块设备、系统目录、服务或 Ceph 全局 flags。这些属于环境资产，必须由具体任务书
另行定义状态所有权、精确计划、ACK、恢复和残留检查。

---

## 一、基本原则

1. **一个 RUN，一个权威根**：每个 RUN 在本地只有一个权威持久化目录；其他目录都是源端、
   暂存、复算工作区或可清理副本。
2. **原始证据不可改写**：进入 manifest 的 raw 文件、实际脚本和命令记录不得覆盖；重试使用
   新 RUN_ID，或在同一 RUN 内使用预先定义且可区分的 attempt 目录。
3. **公共证据一次、轮次证据增量**：不为每个 cell 重复复制整套 inventory、脚本和配置。
4. **先持久化、后清理**：远端或临时源的最后一份证据，在本地副本完成完整性核验前不得删除。
5. **先归因、后压缩失败现场**：失败时先停止并保留；根因关闭后只保留能复核事故的最小充分证据。
6. **保留的是信息，不是副本数量**：同一内容长期保留多份，不会增加证据强度。
7. **事件驱动，不按日期盲删**：清理由持久化、审核、事故关闭和阶段签收触发；年龄只能用于提示，
   不能替代状态判断。
8. **删除必须可证明没有越界**：所有清理都要有精确对象清单、唯一保留副本和事后盘点。

---

## 二、资产分类

### 2.1 证据文件（本规范直接管理）

| 类别 | 典型内容 | 默认处理 |
|---|---|---|
| `COMMON` | inventory、环境基线、实际脚本、binary/config身份、方法论ACK | 每RUN只保存一次 |
| `RAW_CELL` | fio全文、per-job bw log、sampler、cell前后门、时间戳 | 按cell增量保存，正式有效RUN长期保留 |
| `INCIDENT` | incident账本、失败命令、stderr、现场快照、根因证据 | 未关闭时完整保留；关闭后压缩为事故包 |
| `DERIVED` | CSV、图表、统计模型输出、复算结果 | 可再生；保留最终签收版本，删除重复中间版 |
| `REPORT` | 阶段回传、正式报告、审核记录、裁决 | 长期保留最终版本 |
| `TRANSIENT` | rsync/scp暂存、解压目录、排序缓存、临时fixture输出 | 完成核验或复算后清理 |
| `ARCHIVE` | 不可变原始归档、manifest、归档校验 | 作为长期原始真值，避免再留等价副本 |

### 2.2 环境资产（本规范不直接管理）

以下内容即使名称中包含同一 RUN_ID，也不得跟随证据目录一起清理：

- JuiceFS volume、文件数据集、metadata namespace；
- Ceph pool、RADOS对象、CephX身份、CRUSH/PG属性；
- PD/TiKV集群及其数据、WAL、Raft、KV路径；
- mount、进程、PID文件、端口；
- tmpfs、loop、块设备、文件系统挂载；
- scrub flags、系统配置、服务状态。

任务书必须把 `EVIDENCE_CLEANUP` 与 `ENVIRONMENT_ASSET_CLEANUP` 写成两个独立阶段。
证据已清不代表环境已恢复；环境已销毁也不代表证据已持久化。

---

## 三、权威目录与目录结构

### 3.1 唯一权威根

```text
/mnt/c/SunRise/test/<TASK>/<RUN_ID>/
```

- `<TASK>`使用任务号或稳定任务名，例如`04-1`、`04-tmp`、`u141d`；
- `<RUN_ID>`必须唯一且不可为空；
- `/tmp`、远端`/tmp`、`/tmp/production`和157上的结果目录只允许作为执行源或暂存区；
- 同一RUN不得再建立第二个被称为“最终”“final”“complete”的平行权威根。

### 3.2 推荐结构

```text
<EVIDENCE_ROOT>/
├── run-state.tsv
├── common/
│   ├── inventory/
│   ├── env/
│   ├── scripts/
│   └── commands.sh
├── cells/
│   ├── W01/
│   └── R01/
├── incidents/
├── derived/
├── reports/
├── manifest.sha256
├── persistence.tsv
├── retention.tsv
└── purge-audit.tsv
```

目录可以按任务特点精简，但语义必须保持：公共证据不能被每个cell重复嵌套；raw、incident、
derived和report必须可区分。

### 3.3 禁止的复制形态

- 每完成一个cell就把整个RUN目录重新复制到新的phase目录；
- 最终目录内嵌`phase-i/完整RUN`、`phase-ii/完整RUN`等递归快照；
- 长期同时保留相同内容的源目录、同步暂存目录、展开目录和多个tar包；
- 用覆盖式同步修改已经登记进manifest的raw文件；
- 使用`rsync --delete`把本地目录强制变成远端镜像。

---

## 四、RUN状态与处置状态

性能有效性、RUN生命周期和各副本处置是三个互补维度，禁止把它们混成一个“PASS/FAIL”。

### 4.1 有效性状态 `VALIDITY_STATE`

沿用证据方法论：

| 状态 | 含义 |
|---|---|
| `ACTIVE` | 仍在执行，尚未裁决 |
| `VALID` | 非性能门和矩阵合同完整，可进入正式效应量 |
| `EVIDENCE_INVALID` | 非性能门失败或缺臂，只能作工程观察 |
| `RESOLUTION_INSUFFICIENT` | 证据完整但分辨率不足 |
| `INCONCLUSIVE` | 证据完整但方向不足 |

### 4.2 生命周期状态 `LIFECYCLE_STATE`

```text
ACTIVE
  → PERSISTING
  → PERSISTED
  → REVIEWED
  → RETENTION_DECIDED
  → CLOSED
```

| 状态 | 最低条件 |
|---|---|
| `ACTIVE` | RUN正在执行；远端和本地都可能变化 |
| `PERSISTING` | 正在增量回传；尚不可清理最后一份源证据 |
| `PERSISTED` | §六完整性门通过，存在唯一权威副本 |
| `REVIEWED` | 第二方已完成证据/事故审核并记录结论 |
| `RETENTION_DECIDED` | 每份远端和本地副本均已有明确处置决定 |
| `CLOSED` | 报告、索引、保留物、处置状态和必要审计均完成 |

`VALIDITY_STATE=EVIDENCE_INVALID`不等于可立即删除；只有事故根因关闭并满足保留规则后，
相应完整副本才能标为`PURGE_ELIGIBLE`。

### 4.3 副本处置状态

远端和本地状态分别记录，避免`PRESERVE`或无远端任务无法走到`CLOSED`：

```text
REMOTE_STATUS=ACTIVE|PURGE_ELIGIBLE|PURGED|PRESERVED|NONE
LOCAL_STATUS=ACTIVE|COMPACTION_ELIGIBLE|COMPACTED|PRESERVED
INCIDENT_STATUS=NONE|OPEN|RESOLVED
```

进入`CLOSED`时，`REMOTE_STATUS`必须是`PURGED/PRESERVED/NONE`之一，`LOCAL_STATUS`必须是
`COMPACTED/PRESERVED`之一，且`INCIDENT_STATUS`不能是`OPEN`。`PRESERVED`必须写明理由和
下一检查点，不能用来逃避收口。

### 4.4 状态记录

`run-state.tsv`应追加记录，不覆盖历史转换，至少包含：

```text
epoch_iso	run_id	validity_state	lifecycle_state	remote_status	local_status	incident_status	reason	evidence_root	actor
```

生命周期状态只能前进；副本处置状态按实际分支更新。发现旧状态错误时追加订正行并解释，
不得改写原行。

---

## 五、任务书必须预注册的字段

每份任务书前两页必须包含：

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/<TASK>/<RUN_ID>
REMOTE_RESULT_ROOT=<精确绝对路径；无远端结果则NONE>
EVIDENCE_RETENTION=FORMAL|SCREEN|INCIDENT|TRANSIENT
REMOTE_CLEANUP=AFTER_PERSISTENCE_PASS|AFTER_REVIEW|PRESERVE
LOCAL_COMPACTION=AFTER_REVIEW|AFTER_STAGE_CLOSE|PRESERVE
ENVIRONMENT_ASSET_CLEANUP=<独立阶段和授权；不得引用EVIDENCE规则代替>
```

还必须回答：

1. 哪些是RUN级公共证据，哪些是逐cell增量证据；
2. 哪些raw是独立复算的最低输入；
3. 哪些异常会把`INCIDENT_STATUS`切换为`OPEN`；
4. 什么事件触发持久化、远端清理、本地压缩和最终关闭；
5. 若任务中止，保留现场的范围以及解除保留的条件；
6. 谁负责第二方审核，报告中在哪里记录生命周期状态。

旧任务书若缺少这些字段，执行前必须在执行计划或阶段指令中补齐；不得根据习惯临时决定。

---

## 六、采集、增量回传与持久化门

### 6.1 采集边界

- `COMMON`每RUN只采集和回传一次；只有实际发生变化才新增带时间戳的差分证据；
- `RAW_CELL`只写入自己的`cells/<CELL_ID>/`，不得带入其他cell目录；
- `commands.sh`记录实际执行命令，秘密值必须脱敏；
- `incidents.tsv`必须append-only，即使没有事故也保留表头；
- 失败重试不能覆盖失败证据；使用新RUN或明确attempt目录。

### 6.2 增量回传

阶段内允许增量回传新文件，但不得因此宣布`PERSISTENCE_PASS`。增量回传应满足：

1. 目标位于唯一`EVIDENCE_ROOT`；
2. 已存在且已登记的raw文件内容不变；
3. 公共证据不随每个cell重复复制；
4. 回传失败可以重传同一文件，但必须以最终SHA256闭合；
5. 远端源在完整持久化门通过前仍是受保护副本。

### 6.3 `PERSISTENCE_PASS`硬门

同时满足以下条件才允许写`PERSISTENCE_PASS`：

1. 预注册必需目录与文件齐全；
2. raw、实际执行脚本、`commands.sh`、`incidents.tsv`和阶段报告齐全；
3. 预注册复制范围内的源端与本地文件清单闭合；本地新增的报告/分析不要求在源端存在；
   明确排除的易变运行文件须列入说明，不能静默遗漏；
4. 源端和本地SHA256逐文件一致；
5. 文件数与总字节数核对一致；
6. manifest使用相对路径，不包含秘密；manifest本身以及仍会追加的`run-state.tsv`、
   `persistence.tsv`、`retention.tsv`、`purge-audit.tsv`不纳入其自身覆盖范围，收口时另存这些账本的校验值；
7. 需要归档时，归档可列目录、可完整读取且归档自身SHA256已保存；
8. `persistence.tsv`记录源、目标、时间、文件数、字节数、manifest SHA和结论；
9. 权威副本所在文件系统空间足够，且不是`/tmp`；
10. 第二方可仅使用权威副本完成独立复算或事故复核。

任一条件失败均保持`PERSISTING`，禁止清理最后一份源证据。

---

## 七、保留等级与压缩规则

| `EVIDENCE_RETENTION` | 适用对象 | 长期保留 | 可清理 |
|---|---|---|---|
| `FORMAL` | 有效正式矩阵、交付裁决 | 不可变原始归档、manifest、实际脚本、命令、最终分析和报告 | 暂存、重复展开树、可再生中间输出 |
| `SCREEN` | L1筛选、可行性实验 | 最小可复算raw、公共身份、结论和最终Gate | 重复sidecar、被替代中间Gate、重复归档 |
| `INCIDENT` | 未关闭或有方法学价值的故障 | 事故账本、关键stdout/stderr、现场快照、触发脚本、根因与修复验证 | 根因关闭后与事故无关的重复全量数据 |
| `TRANSIENT` | 同步、解压、排序、临时生成 | 通常不长期保留 | 完成对应核验后清理 |

### 7.1 正式有效RUN

- 在阶段最终报告签收前保留完整权威树；
- 签收后长期保留一份不可变原始归档及manifest、实际脚本、命令、分析和报告；
- 为方便复算展开的raw目录属于工作副本，复算结束并核对输出后可以清理；
- 若项目要求随时免解压复核，可以保留展开树，但不得再保留第二个等价展开副本。

### 7.2 已归因无效RUN

以下条件全部满足后，可从完整保留降为事故包：

1. `VALIDITY_STATE=EVIDENCE_INVALID`的具体门和影响已记录；
2. 根因已确认，不再依赖完整现场继续定位；
3. 关键日志、实际脚本、commands、incident账本和环境身份已经封装；
4. 修复后的离线Gate通过；若问题只能在线暴露，还须有替代RUN证明修复；
5. 无效数据未进入正式效应量；
6. 第二方审核同意进入`PURGE_ELIGIBLE`。

长期事故包至少保留：`incident-summary.md`、`incidents.tsv`、触发失败的原始片段、实际脚本及SHA、
修复版本及验证证据、原完整manifest和清理审计。不得只留一句“脚本bug”。

### 7.3 Gate/mock迭代

- 最终PASS版本及其完整断言必须保留；
- 具有新缺陷类别或解释修复必要性的代表性失败证据保留；
- 仅重复同一已知错误的中间迭代，在最终PASS和事故摘要闭合后可清理；
- 不得为每次一行修复永久保留整套fixture副本。

### 7.4 未关闭事故

`INCIDENT_STATUS=OPEN`期间：

- 禁止自动卸载、删除目录、清sampler或销毁环境资产；
- 禁止清理能证明根因的远端和本地证据；
- 可以只读盘点和增量持久化；
- 根因关闭后必须显式追加状态转换，不能依靠“后来跑通了”自动视为关闭。

---

## 八、远端临时证据清理

### 8.1 允许进入远端清理的条件

必须同时满足：

1. `LIFECYCLE_STATE`至少为`PERSISTED`；
2. `REMOTE_CLEANUP`不是`PRESERVE`；
3. 若为`AFTER_REVIEW`，第二方审核已经完成；
4. `INCIDENT_STATUS`不是`OPEN`；
5. 清理目标只包含本任务证据文件，不包含环境资产；
6. 已生成精确清理清单并确认本地唯一保留副本可读。

### 8.2 清理清单最低字段

```text
run_id	asset_class	exact_absolute_path	bytes	manifest_sha256	retained_copy	reason
```

清单必须冻结并进入权威根。目标路径必须满足：

- 精确落在任务预注册的`REMOTE_RESULT_ROOT`内；
- RUN_ID非空且与state、manifest和路径一致；
- 不是`/`、`/tmp`、`/tmp/production`、用户HOME、工作区根或其父目录；
- 不是符号链接，也不通过符号链接逃出范围；
- 不含通配符、未展开变量、命令替换或依赖当前目录的相对路径。

禁止使用`rm -rf /tmp/production/*`、按前缀批量删历史RUN、`find ... -delete`、
`rsync --delete`等宽作用域方式。即使目录属于测试，也必须逐RUN清理。

### 8.3 清理后审计

清理完成后必须记录：

- 清单中每个目标是否消失；
- 预注册保留路径、其他RUN和环境资产是否仍存在；
- 实际释放空间；
- 命令返回码与执行身份；
- 权威副本manifest再次核验结果。

全部通过后才可把`REMOTE_STATUS`标记为`PURGED`。部分失败不得扩大范围重试，应保留审计并
重新生成精确计划。

---

## 九、本地压缩与清理

### 9.1 可及时清理的内容

满足对应阶段门后，应在同一阶段收口中处理，不拖到磁盘告警后：

- 已通过持久化核验的下载/同步暂存目录；
- 已完成独立复算且输出已核对的临时解压目录；
- 内容完全相同的重复归档或重复展开树；
- 被最终PASS替代且没有新增缺陷信息的Gate/mock迭代；
- 已归因无效RUN中未进入事故包的重复raw和无关sidecar；
- 可由保留raw和冻结分析器确定性再生的临时排序、缓存和草图。

### 9.2 本地永远不能只剩的内容

以下任一形态都不能成为唯一证据：

- 只有summary，没有per-job raw；
- 只有派生CSV/图表，没有来源manifest；
- 只有tar文件名，没有归档SHA和可读性验证；
- 只有报告，没有实际脚本、命令和环境身份；
- 只有远端路径，没有本地持久化副本；
- 只有无效点值，没有事故原因和有效性状态。

### 9.3 本地压缩完成门

清理后至少保留一套满足对应保留等级的证据，并完成：

1. 保留集合manifest复核；
2. 最终报告中的所有数字仍可追溯；
3. 正式RUN仍可从不可变归档独立复算；
4. 事故RUN仍可解释故障、影响和修复；
5. `retention.tsv`列出保留项、删除项和理由；
6. `purge-audit.tsv`记录执行结果和释放空间。

通过后把`LOCAL_STATUS`标记为`COMPACTED`。

### 9.4 最小实现原则

本规范用于减少重复和失控清理，不得反过来制造一套比测试更重的证据工程：

- L0/L1小任务可以不创建空目录；`run-state/retention/purge`记录可合并为一个小型TSV，
  只要字段语义齐全；
- 没有远端结果时写`REMOTE_RESULT_ROOT=NONE`、`REMOTE_STATUS=NONE`，不做虚假的源端核验；
- 没有发生清理时，`purge-audit`只需记录`NO_PURGE_REQUIRED`，不生成空归档；
- 不要求每个cell生成生命周期报告，phase边界增量同步、RUN边界核验即可；
- 小型Gate/mock若展开目录本身已是唯一权威副本，不必为了形式再生成内容相同的归档；
- 只有L2/L3正式RUN或预计目录较大时，才默认采用“不可变归档 + 临时解压复算”模式。

---

## 十、生命周期检查点

生命周期盘点是阶段动作，不是后台自动删除任务。

| 检查点 | 必做事项 |
|---|---|
| 每个phase结束 | 增量回传新证据；更新run-state；不复制旧phase整树 |
| RUN正常结束 | 完整持久化门；生成远端清理候选；等待所需审核 |
| RUN失败 | 标记有效性；保存incident；未归因前保持现场 |
| 根因关闭 | 形成事故包；判断失败RUN是否`PURGE_ELIGIBLE` |
| 替代RUN通过 | 清理被替代重复Gate/mock和已归因无效全量副本 |
| 第二方复算完成 | 清理复算解压/缓存；保留结果和来源manifest |
| 阶段最终报告签收 | 全量盘点历史RUN；关闭事故；远端清零或解释保留；本地压缩 |
| 下一个任务开跑前 | 检查前一任务是否遗留ACTIVE/INCIDENT、临时证据或环境资产 |

“测试命令跑完”不等于任务关闭。只有性能/机制报告、持久化、远端证据清理、本地压缩以及
独立的环境资产收口都完成，才能标记`CLOSED`。

---

## 十一、报告与审计要求

每份阶段或最终报告必须列出：

```text
RUN_ID
VALIDITY_STATE
LIFECYCLE_STATE
EVIDENCE_ROOT
MANIFEST_PATH
PERSISTENCE_STATUS
REMOTE_STATUS
LOCAL_STATUS
INCIDENT_STATUS
ENVIRONMENT_ASSET_STATUS
```

报告还应简要列出：

- 长期保留了什么、为什么；
- 删除了什么、释放多少空间；
- 哪些数据因事故未关闭而继续保留；
- 哪些环境资产仍在现场，以及它们受哪份独立计划约束；
- 下一次生命周期检查点是什么。

如果性能结论已经完成但生命周期未收口，报告状态只能写
`PERFORMANCE_COMPLETE_LIFECYCLE_OPEN`，不得写`ALL_DONE`。

---

## 十二、历史数据迁移

本规范生效前的历史目录不要求立即批量删除，避免在缺少manifest时误删。处理顺序为：

1. 只读盘点157、集群临时目录和`/mnt/c/SunRise/test`，按任务/RUN归组；
2. 标记权威副本、重复副本、有效RUN、无效RUN和未关闭事故；
3. 优先处理占用大且已经有正式报告/替代RUN的目录；
4. 对缺manifest但仍有引用价值的历史RUN，先补最小manifest和事故/结论摘要；
5. 生成清理清单，经审核后逐RUN处理；
6. 不因本规范生效而对未知目录做一次性批量删除。

后续新RUN必须从创建时就遵守本规范，不再把生命周期债务留到阶段结束后补做。
