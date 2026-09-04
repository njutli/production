# 04-tmp3 任务书：竞品大块单流顺序口径（精简 L1 筛选）

## 状态与授权

| 字段 | 冻结值 |
|---|---|
| 日期/实验号 | 2026-09-03 / `TMP-H3C-BIGSEQ1`（不占正式04-N） |
| 执行角色 | Luna按phase执行；GPT独立复算与签收 |
| 当前状态 | `COMPLETED / VALIDATED_L1_SCREEN / ENVIRONMENT_CLOSED`；RUN `20260904-095827` |
| 唯一权威根 | `/mnt/c/SunRise/test/04-tmp3/<RUN_ID>/` |
| 专用脚本 | `t04tmp3-executor.sh`、`t04tmp3-screen-driver.sh`（仅概要）、`t04tmp3-screen-analyze.py`、`u141d-scrub-control.sh`（scrub唯一权威）、`t04tmp3-gate0-offline.sh` |
| 运行前提 | 04-6完成且恢复锚通过；用户已批准本任务读/写phase各自state-driven scrub pause/restore |

方法论与约束来源：`TASK-BOOK-AUTHORING-GUIDE.md`、`TEST-DATA-LIFECYCLE-POLICY.md`、
`skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`，以及本任务引用的
`TESTING-GUIDE.md`、`test-commands-reference.md`、`LONG-RUNNING-TEST-SKILL.md`。

```text
U141d/04-6：完成且恢复锚通过
  ↓ 04-tmp3 L0 Gate 0（纯离线）已通过
Phase I：只读 inventory/private-msgr8 与 scrub lease plan → `prepare-assets` 非 sudo，先归一化冻结 O0、再预置90GiB资产并归一化冻结 O1 → 资产/清理计划（已通过）
  ├─ 未通过 → HOLD，修订后重新 Gate 0
  └─ 通过 + 用户授权 → Phase II-R/W 各一个独立 L1 phase
Phase II-R：A/F/R/R/F/A，读fio与读辅助cp（已通过）
Phase II-W：A/F/W/W/F/A，写fio与写辅助cp（已通过）
  ├─ 无材料信号/门失败 → STOP，只报L1工程观察
  └─ 有材料信号 → 停止，另立任务/另授权才可L2
每个phase：O1前后对象门 → `u141d-scrub-control.sh` state-driven restore → recovery/证据门 → 第二方审核
主线：不得把16M/20M结果回填256K七项；本任务无自动L2扩张
```

一句话：在现有256K卷和专属资产上，以最小、平衡的A/F/R/W L1筛选复现竞品四条命令；只在
独立授权的新任务中考虑L2，测试后以精确清理和恢复锚决定能否回主线。

## 〇、背景、目标与硬边界

竞品只公布命令和目标值，没有公布硬件、缓存、JuiceFS/META/Ceph环境，因此本任务只报告
“已披露命令口径下达到/未达到”，不宣称严格同条件领先。竞品目标按十进制解释，同时列出MiB/s：

| 项 | 原命令 | 目标 |
|---|---|---:|
| cp读 | `time cp /mnt/epc/20Gfile /tmp/` | 2 GB/s = 1907.35 MiB/s |
| cp写 | `time cp /tmp/20Gfile /mnt/epc/` | 2 GB/s = 1907.35 MiB/s |
| fio读 | `fio --name=seq_read --filename=/mnt/epc/testfile1 --size=10G --bs=20M --rw=read --direct=1 --numjobs=1 --runtime=60 --time_based --group_reporting` | 5.4 GB/s = 5149.84 MiB/s |
| fio写 | `fio --name=seq_write --filename=/mnt/epc/testfile1 --size=10G --bs=16M --rw=write --direct=1 --numjobs=1 --runtime=120 --time_based --group_reporting` | 3.2 GB/s = 3051.76 MiB/s |

唯一正式问题：当前交付臂A与有限候选臂能否在本RUN的L1筛选中给出升级价值信号，并在写phase后
闭合恢复。L1不产生正式效应量，不签等价/非劣/替代。

明确不做：不format、不destroy、不建删pool、不改PG/CRUSH/OSD/TiKV/内核/网络、不重启或停止服务、
不碰既有V4资产、不修改256K卷格式、不使用旧的含缓存清理/递归删除/模式kill路径。

特别红线：157及150-152禁止任何全局页缓存清理；本任务所有脚本不执行该动作。`direct=1`、
`cache-size=0`作为共同合同，跳过全局清理并在每臂记录。不能用缓存清理替代冷态证明。

## 一、测试合同与最小矩阵

### 1.1 固定身份与专属资产

- 二进制固定 `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`；以inventory复核。
- 复用既有卷但只在专属目录 `/mnt/juicefs/test_dir/04tmp3-<RUN_ID>/` 写入；不format。
- 读资产：`read/20Gfile`=21,474,836,480 bytes、`read/testfile1`=10,737,418,240 bytes，pre/post path/inode/size/mtime/抽样hash不变。
- 写资产：每个W cell独立的预置10GiB `write/<CELL>/testfile1`；cp写目标为每cell独立且起跑前不存在。
- 本地20GiB源只允许`/mnt/jfs-cache/04tmp3/jfs-04tmp3-<RUN_ID>`；稳定父目录`/mnt/jfs-cache/04tmp3`须一次性精确创建为`1002:1002 0700`，RUN子目录由普通用户创建/清理；不得使用`/tmp`或BeeGFS目录。
- 证据唯一持久化根为 `/mnt/c/SunRise/test/04-tmp3/<RUN_ID>/`；远端结果根为`NONE`或精确临时路径，不能把远端作为唯一副本。

### 1.2 命令与挂载臂

fio核心参数逐项冻结；只增加`--write_bw_log=<unique-prefix> --log_avg_msec=1000 --output=<unique-output> --output-format=json+`，不加iodepth/ioengine/线程数。
必须保留全部per-job log，fio summary只作兼容旁证；主值按实际I/O起点、区间重叠加权自然秒和四窗计算。

共同参数：同一二进制/META/UUID、`--max-uploads 150 --cache-size 0`、无writeback、block-size=256K。

| 臂 | 额外挂载参数 | L1用途 |
|---|---|---|
| A | `--max-fuse-io 256K` | 当前交付对照 |
| F | `--max-fuse-io 1M` | FUSE拆分候选 |
| R | `--max-fuse-io 1M --max-readahead 8M` | 读探索候选；判档器不假定免疫 |
| W | `--max-fuse-io 1M --buffer-size 1024` | 写探索候选 |

### 1.3 L1唯一矩阵与升级/停止

当前证据级别是`L1_SCREEN`，只跑两个独立phase：读 `A→F→R→R→F→A`，写 `A→F→W→W→F→A`。
每臂一个fio cell（读60s、写120s），A基线与候选各做一次辅助cp（R01/R04、W01/W04）；不自动扩充L2。

预注册裁决规则（只用于排期）：候选两组与头/尾A方向均为正，平均材料信号至少5%，合同/身份/
日志/health/恢复门全过，且无反向CPU/延迟/后端信号，才记`SCREEN_CONTINUE`。R另需超过43%压力线；
否则`SCREEN_STOP`或探索性观察。无论何种信号，都必须停在phase边界，GPT审核后另立L2任务；
不把L1点并入正式效应量、不因性能差删样本、不补样、不改顺序。

## 二、统计、门与scrub控制

### 2.1 最小真值集

每cell保存完整fio文本/JSON、全部per-job bw log、commands、身份指纹、health/容量/挂载/采样门、
`incidents.tsv`和SHA256。实际起点=`fio完成时刻−job_runtime`，禁止用fork/登记起点；正式窗读`[10,50)`、
写`[10,110)`，各输出mean/median/CV/P10/P50/P90和W1-W4/W4-W1。读写方向分开，绝不乘jobs或挑MAX。

### 2.2 状态门

身份（binary/META/UUID/mount/PID/starttime/exe）、资产（path/inode/size/mtime/hash）、fio合同、
per-job覆盖、I/O error、health/PG/容量、挂载唯一性、清理/恢复均必须通过。非性能的资产准备允许PG仅额外带`+scrubbing`/`+deep`标签；正式读写phase仍要求全部精确`active+clean`，例行巡检不能进入性能窗口。高写后记录pre→peak→delete→
GC/compact/cooldown，且`compact_running=0`、`compact_queue_len=0`、`kv_sync_lat`全绿；未闭合则`DOWNSTREAM_HOLD`。
失败现场先保留，不lazy/force卸载、不杀进程；同RUN不得热改脚本。

### 2.3 scrub是独立phase状态

正式多臂phase可暂停`noscrub + nodeep-scrub`，但只按独立且复用的`u141d-scrub-control.sh`的
`plan-pause/pause/restore`状态控制，并单独授权精确FSID/lease；`t04tmp3-scrub-state.sh`仅为历史
概要渲染器，不是执行入口。inventory、资产准备、Gate0不改flags。设置后必须确认唯一允许的
`OSDMAP_FLAGS` WARN、OSD up/in、PG active+clean、无运行scrub；phase成功/失败/中止均先restore并验证原状态，
最长4h，读写不得共用lease，不得轮间切换。executor不直接调用sudo；scrub controller是唯一Ceph变更入口，只执行用户已批准、由state约束的精确pause/restore命令。

### 2.4 sudo调用预算建议

executor及只读采集的sudo写调用数为0；只读health/status不计写调用。若用户批准每个读/写phase独立scrub lease，
建议精确预算为每phase 4次：set `noscrub`、set `nodeep-scrub`、unset `noscrub`、unset `nodeep-scrub`，
两phase合计8次。若pre-state已有任一flag，必须在phase计划中扣除对应unset，禁止无条件恢复；除该账本外
不建议任何Ceph写调用。资产创建和删除均由executor在本RUN精确路径内逐文件执行并写入manifest，不涉及sudo或宽路径删除。

## 三、执行步骤与停点

### 阶段0：离线Gate0（本地，禁止连接环境）

- [ ] 步骤0：测试前通读并确认上述全部skill的关键点，完成合规映射。
- [ ] 运行`t04tmp3-gate0-offline.sh`：bash -n/bash -u -n、Python compile/self-test、executor self-test、相关known-defect逐条断言、密钥扫描、危险操作扫描、driver/scrub计划fixture。
- [ ] 仅验证合成fixture：缺per-job log、错误起点、错单位/缺字段、资产大小错误、同label重试、scrub部分状态、恢复失败均应FAIL。
- [ ] 通过后冻结脚本全文/hash；Gate0失败只能修改后重跑Gate0，不能连接环境。

**停点0：**回传五个脚本清单、SHA256、Gate全文、sudo预算和Phase I计划；未通过不得SSH/sudo/mount/fio/ceph/juicefs。

### 阶段I：只读inventory与计划（需独立授权后才进入）

在157复制依赖后，先用精确`I_ACK_04TMP3_PHASE1_<RUN_ID>`运行`inventory-plan`。该入口只读确认04-6恢复锚、无遗留测试mount/fio/lease、binary/META/UUID/参考挂载和scratch容量，生成本RUN private `ceph-msgr8.conf`、scrub计划及sudo清单，并冻结脚本hash；它不得创建测试资产、挂载、执行fio/cp或改变flags。随后用精确`I_ACK_04TMP3_PREPARE_<RUN_ID>`运行`prepare-assets`（非sudo）：combined GC+quiet冻结O0，在固定RUN scratch创建真实非稀疏20GiB源，经A臂挂载预置90GiB专属读/写资产并逐文件校验精确大小/抽样hash，最后combined GC+quiet冻结O1。再运行`cleanup-plan`只读复核本RUN资产manifest。

### 阶段II-R/W：各一个L1性能phase（phase内连续执行）

开跑前按批准的scrub plan建立phase lease；读phase只准备/冻结专属读资产，写phase只使用预置独立写资产。
每cell前执行health/PG/容量/compact门，157及150-152不做全局缓存清理；每cell后保存raw与状态。
写cell覆盖各自的10GiB预置fio文件，该文件保留至整个RUN最终cleanup；本cell只即时精确删除临时cp目标，再执行combined `gc --compact --delete --threads 32`/quiet清除历史版本并核对回O1±8192后才进下一cell。phase结束无论成败
优先restore scrub，再持久化证据和更新run-state；不在中途等待第二方，避免破坏平衡。

**停点II-R / II-W：**回传该phase raw、commands、逐门PASS/FAIL、incidents、scrub audit、对象/compaction/
资产变化和恢复结果；GPT独立复算，只产生`SCREEN_CONTINUE/SCREEN_STOP/EVIDENCE_INVALID`，不自动开L2。

### 最后一步：测试后skill合规复核

对照作者指南、生命周期、安全与证据skill逐条复核：无全局缓存清理、无format/destroy/pool/PG/服务操作、
无宽范围清理/模式kill、scrub state-driven恢复、写后compact三指标全绿、所有数字可追溯、生命周期已持久化。

## 四、交付物与生命周期

离线Gate产物落在`/mnt/c/SunRise/test/04-tmp3/<RUN_ID>/gate0/`；执行RUN最小结构为：
`run-state.tsv`、`common/`、`screen/{read,write}/`、`cells/`、`incidents.tsv`、`manifest.sha256`、
`scrub/`、`closure/`。不创建空的L2目录。脚本全文/hash和commands必须进入唯一权威根。

生命周期字段至少包含：`VALIDITY_STATE`、`LIFECYCLE_STATE`、`REMOTE_STATUS`、`LOCAL_STATUS`、
`INCIDENT_STATUS`、`EVIDENCE_ROOT`、`REMOTE_RESULT_ROOT`、`RETENTION_DECISION`。每个phase增量持久化；
本地唯一保留副本核验完成前不得清理远端源。清理只允许manifest逐字列出的本RUN文件和已核验为空的RUN目录，
不得使用递归宽路径或通配批量清理；环境资产清理与证据清理必须分开记录。执行入口按顺序为`inventory-plan`、`prepare-assets`、`read-phase`、`write-phase`、`cleanup-plan`、`cleanup`、`bundle`；每个阶段通过精确ACK启用，cleanup可在中途失败后执行，精确删除全RUN资产与scratch并combined GC/quiet回O0，bundle生成可复制到`/mnt/c/SunRise/test/04-tmp3/<RUN_ID>/`的tar及SHA256。

执行方只交原始证据与门；GPT第二方复算并在报告首屏写机器可读状态。results-table只新增独立竞品小节，
不得覆盖256K原口径。

## 五、通用注意事项（本任务固化）

1. Gate0未过禁止任何环境连接；正式矩阵开始后脚本字节冻结，变更即RUN无效并从phase首轮重来。
2. 统计用实际起点、interval-overlap、完整per-job、正式窗和四窗；summary只作兼容旁证，读写分开。
3. 每个方向至少平衡ABBA式L1顺序；禁止跨日终值相减、挑轮、乘jobs、补样、同label覆盖。
4. 固定真实预置资产；禁止洞文件、create-on-open、轮间relayout与被测变量共线。
5. 157及150-152禁止全局页缓存清理；不改WekaIO/K8s、内核、网卡、RoCE、md0；BeeGFS错峰。
6. 禁止format/destroy、pool delete/create、PG/CRUSH/OSD/TiKV变更、服务restart/stop、lazy/force卸载和模式kill。
7. 任何删除均为manifest精确绝对路径，非空/非根/非符号链接守卫；不使用宽glob、递归删除或旧危险脚本路径。
8. scrub暂停仅限独立phase lease、精确FSID、用户单独授权和state-driven restore；其他health WARN立即停。
9. 高写后必须记录峰值对象数并完成GC/compact/cooldown三指标门；恢复失败即`DOWNSTREAM_HOLD`。
10. 事件账本append-only，动作前后各一条；失败先保留现场，根因关闭后再按生命周期策略压缩证据。
11. 身份、资产、日志、容量、health、采样、清理、恢复是非性能有效门；性能端点不用于删样本。
12. 执行角色不算L2效应量、不宣布等价/收益；第二方复算必须使用冻结原始证据和脚本hash。

## 六、红线与修订记录

红线汇总：04-6未完成不得开跑；Gate0未通过不得接触环境；不碰V4/256K主线；不做157/150-152全局缓存
清理；不做format/destroy/pool/PG/服务变更；不自动L2；不跨phase共用scrub lease；不扩大清理范围；
恢复锚未通过不得继续任何性能任务。

| 日期 | 修订 |
|---|---|
| 2026-08-31 | 初版：竞品四命令、专属资产、A/F/W/R与写后恢复边界。 |
| 2026-09-03 | 按最新作者指南/生命周期/安全/证据规范精简为L0→L1；移除自动L2和多余sidecar；明确157及150-152不做全局缓存清理、phase独立scrub状态、专属资产精确清理、禁止破坏性Ceph/服务操作及sudo预算。 |
| 2026-09-04 | RUN `20260904-095827` 12/12 cell通过并完成持久化、独立复算和环境收口；R读臂为强L1信号，F写臂具最小确认资格，W无增量；不自动升级L2。 |
