# 05-5b：多流顺序BS曲线的配置与容量纠偏重测

> 日期：2026-09-20；状态：`READ_VALID_L1 / WRITE_VALID_L1_CONDITIONAL_MAINTENANCE_START`；正式读RUN `20260920-145000`、写侧canary `20260920-164200`、正式写RUN `20260920-170000`均已收口并通过raw独立复算。旧RUN `20260920-133000`首格fio成功但分析器文件名引用错误退出，保留证据并正常恢复；修正runtime依赖检查后以新RUN重跑，不拼接首格。原“完整phase需88.899 GiB/OSD”的累计容量预算已由获批的逐格精确维护协议取代，写11格已完成；该结果只代表统一维护起点，不代表无人工维护的长期稳态。
> 承接[05-5报告](../perf-report/05-5-multistream-sequential-block-size-curves-20260920.md)，原RUN `20260920-072228`；执行方采集、审核方从raw复算。

```text
05-3b共用修正与随机曲线 → 05-4b单流曲线
  → 05-5b【本任务】：8线程配置下多流读10格、写11格
     ├─ 完整且状态可解释：交付五档曲线
     └─ 健康/容量/漂移失败：记录部分结果，停止
  → 05-6：汇总新曲线、受限项及已有竞品证据
```

一句话：在读门与写门分别满足、且正确客户端配置下重测多流BS曲线，不拼接溢出前后的写数据；读侧不等待randwrite完成。

## 〇、背景与依赖

原读矩阵10格完整，但实际为系统3线程配置，不能代表要求的8线程基线；约2.9 GiB/s的平台不证明正确配置或整个架构无余量。原写9格fio成功，其中第9格 `256K-B` 的post health触发 `BLUEFS_SPILLOVER`，因此是“8格健康边界通过+1格受污染观察+2格未执行”，不能称9个健康有效格。

完整引用[05-3b §一三个补测任务共用的开跑合同](05-3b-random-bs-baseline-repair-and-retest.md#一三个补测任务共用的开跑合同)，包括8线程实际生效、日志验证、BlueFS修复依赖/容量预算、身份、scrub及恢复。不得只补原缺少的 `64K-B/4M-C`。05-3b randwrite或05-4b write未完成不阻塞本任务读侧；但任何健康、读容量、后台静默或写阶段容量门未恢复均分别阻断对应阶段。DB处置方案在05-3b前置阶段统一落实，不在这里再建第二套修复流程。

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=05-5原始观测和配置/容量缺口；04-6并发结果仅为历史先验
MINIMUM_DECISION_SET=读五档正反10格；写3格探针通过后续8格
SCREEN_CONTINUE=正确配置/健康/容量/采集通过；写锚及同BS位置漂移≤10%
SCREEN_STOP=任一健康/容量异常立即停止；漂移超线停止对应写分支，不删除已测低值
FORMAL_MATRIX=不自动追加并发扫描或L2
STOP_AFTER_ANSWER=交付正确配置的五档曲线及限制，不追加调参矩阵
MAX_PREP_BUDGET=复用共用修正，专属离线检查约30分钟
ESTIMATED_WALL_CLOCK=纯fio63分钟，含检查/恢复约1.5—2.5小时
MAX_EXECUTION_BUDGET=3小时，不含独立环境修复
EVIDENCE_ROOT=/mnt/c/SunRise/test/05-5b/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-05-5b-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=本任务私有挂载/进程与拥有的scrub flags；16×4GiB读写文件继续保留
```

## 执行收口附录（2026-09-20，supersedes conflicting execution clauses below）

### 写侧逐格维护修订（2026-09-20，supersedes本附录中“不要逐cell自动重置”）

用户已批准用统一维护起点完成剩余写曲线，不扩容BlueFS DB。写侧改为：首次写格前及每个180秒写格后，仅对16个精确的`mseqwrite.{0..15}.0`文件依次执行`juicefs compact --threads 1 <exact-file>`；禁止目录递归compact、GC、文件删除、重新layout、卷/pool操作、服务停启和sudo写操作。维护不得与fio重叠，并保持文件路径、inode、长度及mtime不变。

每次维护后须连续三个30秒采样满足：HEALTH_OK（或仅本phase拥有的`noscrub/nodeep-scrub`告警）、6/6 OSD up/in、slow=0、RocksDB compact队列为0、pool对象数三点跨度不超过8192，且六OSD最小DB空闲不少于17 GiB。写格内保持2 GiB停止线；任何格后无法恢复17 GiB、出现spillover/其他健康告警或文件身份变化，立即停止剩余矩阵，不以重启、扩容或降低门槛补救。

先以`4M-A`做一次完整`维护→恢复门→180秒fio→维护→恢复门`闭环；仅闭环通过才允许用同一协议批量执行余下10格。正式结果统一标记为`CONDITIONAL_MAINTENANCE_START`，解释为“从标准化维护起点得到的180秒曲线”，不外推为无维护时的长期持续性能。维护耗时、对象回收量和DB恢复量作为运维成本同时报告。

本任务读侧不等待05-3b randwrite或05-4b write完成：在05-3b附录批准的单次定向维护及最多30分钟有界自然DB回收观察完成后，健康、读容量和被动静默门通过即可先执行本任务10个READ cells；与05-4b合计先完成20个读格。读格不得与维护重叠。

随后才执行本任务11个WRITE cells。写前容量预算必须重新校准并计入报告§9暂态DB分配峰值的transient reserve，不能降低既有容量门；不足即停止并提交需另行明确批准的DB扩容方案。不要在正式比较批次内compact或逐cell自动重置；任何批准的inter-batch维护须统一预声明并建立新的state epoch，报告为conditional-maintenance start，不跨epoch给出精确BS效应。

本任务可使用的维护范围仅限已知16M顺序写资产（64 GiB逻辑内容、约4.83 TiB slice引用）；不碰读资产、不递归删除pool/volume内容，并保持逻辑内容和inode。本轮总决策预算为3小时；自然DB回收观察另设最多30分钟上限。

## 一、负载与矩阵

正确基线为B256卷、FUSE256K、uploads150/downloads200/buffer300/cache0、私有 `ms_async_op_threads=8`；节点157、binary/UUID/FSID同05-3b。

资产为既有 `/test_dir/mseqread/mseqread.{0..15}.0` 与 `/test_dir/mseqwrite/mseqwrite.{0..15}.0`，各16个4 GiB文件、互不相同。原05-5已创建的写资产复用；不重建、截短、重新layout。

fio固定 `numjobs=16, psync, iodepth=1, direct=1, size=4G, runtime=180, time_based, refill_buffers, group_reporting=1, allow_file_create=0, per_job_logs=1`。读 `rw=read`，写 `rw=write,end_fsync=1`；每格保留16份bw日志。使用固定 `filename_format=mseqread.$jobnum.0` 或 `mseqwrite.$jobnum.0`，在真正执行的命令中核验美元符号没有被shell提前展开。

| 方向 | 顺序 |
|---|---|
| 读，10格 | `256K-A → 64K-1 → 1M-1 → 4M-1 → 16M-1 → 16M-2 → 4M-2 → 1M-2 → 64K-2 → 256K-B` |
| 写探针，3格 | `4M-A → 64K-A → 4M-B` |
| 写续跑，8格 | `256K-A → 1M-A → 16M-A → 16M-B → 1M-B → 256K-B → 64K-B → 4M-C` |

每方向同一私有挂载，先读后写。写前/后按05-3b被动恢复要求检查；矩阵中不主动清理。探针及后续重复的停止线统一使用正式窗 `D=|a-b|/((a+b)/2)>10%`；任一写同BS对或4M锚对超线停止后续写格。超过停止线的已有数值仍保存并报范围，不以性能差判为采集无效。

## 二、最低证据与结论边界

- 完整命令、配置与worker身份；JSON、16份逐job日志、rc/error、可信时间轴/真实runtime；每格前后pool objects/stored、DB/slow空间及TiKV pending、完整health/PG状态；格内轻量健康采样沿用共用组件。
- `group_reporting=1`的单个聚合job合法，结合 `numjobs=16`和16份日志核验。JSON clat P95/P99是**聚合分位数**，不能再标“16个job各分位数最大值”；不为改字段名称重做fio。
- 正式窗 `[15,175)`、四窗/W4/W1/CV与summary并列；相同BS保留所有位置、均值和漂移。日志覆盖/积分失败则正式窗unknown，summary不能替代缺失窗。
- 只判断“本RUN固定16流下BS曲线是否平坦”。04-6的8/16流旧结果不得替代当前并发证据；本次不重新扫描并发，也不据旧OSD util宣称本RUN达到硬件极限。
- 与原05-5绝对值差异只作已知配置/状态变动下的描述；若要定量归因3→8线程需另作同窗对照，本任务不为解释旧错误额外加臂。
- 出现告警的当前格必须单列，不能因fio成功加入健康均值。新矩阵只使用本次匹配配置/状态的证据；不跨DB修复边界拼接。

## 三、执行与交付

1. **步骤0：** 通读05-3b所引安全/证据skill及指南§二.13—23，确认本任务路径、指标和停止条件。
2. **阶段0：** 共用Gate复用；专属验证16文件映射、16日志+单聚合job、分位数命名、正式窗探针判据及post-health失败归类。不复制一套新框架。
3. **阶段1：** 确认前任务环境恢复、无foreign fio、DB余量预算与正确worker身份；冻结命令、scrub plan和授权引用后批量执行读与写。只在新权限/改变量/健康容量异常处停。
4. **末步：** 按skill复核合规，精确恢复本任务状态；持久化和独立复算一次后写 `doc/perf-report/05-5b-multistream-bs-baseline-and-capacity-retest-<YYYYMMDD>.md`，更新05计划/results-table并进入05-6汇总。

状态四态、非性能门与性能端点区分、生命周期合同同05-3b。新增事故写入append-only记录；公共证据每RUN一份、轮次增量，SHA/文件数/字节数核验后才清远端临时证据。发生阻断可交付部分报告，不以完善格式或清重复文件拖延性能裁决。

**红线：** 保护157 WekaIO/K8s和系统；不改全局配置、服务、设备、pool/卷，不全局drop_caches、不执行未列明的GC/compact或重建资产；无强制卸载、模式kill和宽作用域删除。仅可在正式比较批次外执行05-3b附录明确的定向写资产维护，不碰读资产或递归删pool/volume内容。扩容、迁移DB、停启服务仍受独立方案和授权约束，证据生命周期不授权销毁测试文件。
