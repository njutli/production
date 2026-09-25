# 05-3c：randwrite 不同 BS 的工程趋势补测

> 状态：**COMPLETED_DESCRIPTIVE_ONLY（2026-09-25）**。RUN `20260924-225547` 六格完成，安全与证据门通过，但256K前后锚漂移127.92%，不能形成稳态BS性能曲线；详见[05-3c报告](../perf-report/05-3c-randwrite-bs-trend-completion-20260925.md)。未占用157的 `/mnt/jfs-cache`，远端本RUN暂存已在权威归档核验后精确清理。本文保留原预注册执行合同及历史准备记录。

```text
05-3b：4K 两次相差 25.82%，按当时 10% 漂移门停止
05-6：五项 BS 曲线完成；randwrite 只剩 4K 范围、256K 控制点
  → 05-3c【本任务】：一次低成本同配置补测，给出 randwrite 的 BS 趋势
     ├─ 安全/容量/身份/证据门通过：交付每档观测值与波动范围
     └─ 安全/容量/身份/证据门失败：停止，交付已取得的部分结果
后续：不自动升级正式因果验证，不修改生产配置
```

一句话：补齐 **16K、64K、1M、4M** 的 randwrite 带宽观察值，允许性能波动，但不允许以波动为由筛掉慢值。

## 〇、背景与唯一问题

05-3b 的 4K 重复值为 `15.367/11.853 MiB/s`，差异 `25.82%`；先前规则要求差异不超过 10%，所以没有继续测 16K、64K、1M、4M。现在仅需向用户展示大致的 BS—带宽关系；**不要求**证明每个相邻 BS 的精确收益、长期稳态或最优配置。改变的只是**性能漂移裁决**：带宽、CV、首尾衰减和重复差异全部记录，不再触发提前停测。身份、健康、容量、fio 错误及原始证据门不得放松。

```text
EVIDENCE_LEVEL=L1_SCREEN
RESULT_SCOPE=DESCRIPTIVE_TREND_ONLY
SCREEN_SOURCE=05-3b 同二进制/同卷的 4K 范围与 256K 控制点，仅作历史旁证
MINIMUM_DECISION_SET=本 RUN 256K 前锚 + 16K/64K/1M/4M 各 1 格 + 256K 后锚
SCREEN_CONTINUE=安全与容量门持续通过时跑完预定六格；性能漂移只作结果，不作停测门
SCREEN_STOP=身份错误、fio I/O 错误、health/容量越界、证据无法判读或用户给定时限到达
FORMAL_MATRIX=无；如以后需精确 BS 效应，另立正式任务
STOP_AFTER_ANSWER=六格或安全门停止后立即收口；不追加重复、参数扫描或新 layout
MAX_PREP_BUDGET=复用既有脚本/分析器，离线核对原则上 ≤1 小时
MAX_EXECUTION_BUDGET=六格 fio 约 18 分钟；连同准入、采样和必要恢复以 2 小时为决策预算；超时交付部分结果，不为了凑齐继续负载
ESTIMATED_WALL_CLOCK=约 1–2 小时；如现状需要经批准的精确文件维护，维护时间另计且可停止不测
EVIDENCE_ROOT=/mnt/c/SunRise/test/05-3c/<RUN_ID>/
REMOTE_RESULT_ROOT=/tmp/production/05-3c-<RUN_ID>/（须先核对空间；不得作为唯一副本；禁止占用 `/mnt/jfs-cache`）
EVIDENCE_RETENTION=SCREEN；原始 fio、命令、身份、健康/容量快照与裁决须保留
REMOTE_CLEANUP=AFTER_PERSISTENCE_PASS；在本地权威副本SHA/条目数/可读性核验、事故关闭后，精确清理本RUN的远端暂存，不需再等阶段报告签收
ENVIRONMENT_ASSET_CLEANUP=仅精确卸载本任务私有挂载、恢复本任务获批改变的 flags；不删除测试文件/卷/pool
```

## 一、测试口径

- 固定现有 1.4.1 patched 二进制（05-3b 身份 MD5 `24fae0852051c80ca571cb2f20275d46`）、B256 `juicefs-prod` 卷、原有 128 个各 1 GiB 的 `/test_dir/storage_test.{0..127}.0` 覆盖写资产；开跑前重新核对实际 binary、卷 UUID、pool FSID、文件 inode/大小。**不新建卷、不 layout、不改文件集合**。
- 复用 05-3b 已签收的私有 Ceph `ms_async_op_threads=8` 配置并验证它在实际 JuiceFS worker 上生效；客户端挂载参数保持 `--max-fuse-io 256K --max-uploads 150 --max-downloads 200 --buffer-size 300 --cache-size 0`，writeback 关、预读默认、`direct=1`。不动 `/mnt/juicefs` 主挂载，使用独立私有挂载。
- 复用 05-3b fio 形状：`randwrite`、`libaio`、`numjobs=128`、`iodepth=128`、每 job `filesize=size=1G`、`time_based`、`runtime=180`、`group_reporting`、`fallocate=none`、`allow_file_create=0`、`openfiles=128`、`randrepeat=1`。只切换 `bs`；不得为大 BS 顺手改卷 `BlockSize`、FUSE IO、uploads 或其他参数，否则失去同配置趋势口径。
- 顺序固定为 **256K 前锚 → 16K → 64K → 1M → 4M → 256K 后锚**。前后锚用于量化这段运行的状态变化，**不作为性能放行门**。05-3b 的 4K 两点不重跑；最终图表将其明确标为“历史独立 RUN 的工程范围”，不能伪装为本 RUN 同窗六档曲线。若确需同 RUN 的完整六档曲线，须另行决定是否增加 4K，不能执行中临时改矩阵。
- 主值复用 05-3b 的 `[15,175)` 正式窗和已修正的逐 IO 完成日志/JSON 有界尾差合同，保存 128 份 per-job 原始日志、fio JSON、完整命令与返回码；同时报 fio 全程均值作旁证。每档列 `MiB/s`、CV、四个 40 秒窗、`W4/W1`、错误数，前后锚列出相差百分比。**不挑最高轮、不删除衰减段、不按 10% 差异中止，也不把起伏解释为 BS 的因果效应。**若采样无法复算，只标记该点 `EVIDENCE_INVALID`，不填估算值。

## 二、执行与停点

1. **步骤 0：** 通读上列 skill 和任务书指南；核对系统安全、health/compact/capacity、原始日志与统计窗要求。先检查所复用脚本及其调用链有无 sudo 写操作、重启、删卷、全局 drop_caches、隐式维护；列出精确命令和节点，经用户单独确认后才可执行。本任务书本身**不授予** sudo/全局 Ceph 写操作。
2. **开跑前安全门（唯一预定人工停点）：** 只读确认157业务不受测试资源竞争影响、Ceph OSD/PG/health、无进行中的 scrub 干扰、DB 与数据盘容量、TiKV/OSD compact backlog、资产身份和本地证据空间。写入一个简短容量计划：以上轮 256K 实测对象/DB 增量为参考，但不能假定其他 BS 相同；逐格设止损，任一容量接近下限或出现 BlueFS spillover/slow ops 就停。若需要先暂停 `noscrub/nodeep-scrub`，必须采用已签收的 lease 机制、先确认原状态并**单独申请授权**，失败时精确恢复。若当前起点不能安全承受首格，不运行 fio。
3. **离线最小核对：** 尽量复用 05-3b 的 fio 驱动、采样器和分析器，不新写框架；只检查 BS 切换确实进入实际命令、顺序/文件路径正确、日志仍能覆盖正式窗、旧的 10% 性能停门不会意外阻断本任务，以及 health/容量门仍会阻断。若必须修改脚本，保存补丁与哈希并先通过这几项离线 Gate；不在现场边跑边改。配置/脚本身份冻结后再开跑。
4. **连续执行六格：** 每格前 `check_ceph_health` 与容量/compact 状态检查，每格后记录 fio、对象数/存储量、DB 空闲、健康和队列；必要的被动等待仅为满足安全门，时长及状态写入记录。**不在六格之间主动 GC、compact、清卷、重新 layout 或重新挂载**，避免给 BS 顺序引入另一变量；如不维护就无法满足下一格安全门，停止并交付部分结果，不自行扩大维护权限。性能下降或前后锚显著漂移仍保留数据并继续，除非触发非性能安全门。
5. **恢复与签收：** 停负载，精确卸载私有挂载，恢复本任务实际设置的 scrub flags；确认 157 共置业务、Ceph/TiKV、主挂载与测试资产无异常。若写后对象/DB 债务需要主动维护，只能先生成精确文件范围和命令计划，**另请批准**；未获批准时标记 `POSTRUN_DEBT_PRESERVED`，不以破坏性清理换取“完成”。把本 RUN 新证据一次性持久化到指定目录，核对 SHA256、条目数、归档可读性；不重复搬运 05-3b 旧整树。上述持久化通过且事故关闭后，按数据生命周期规范生成精确清单，仅清理 `/tmp/production/05-3c-<RUN_ID>`，核对其他05/06 RUN不变并记录释放空间；不得清理测试文件、卷、pool或其他人的目录。
6. **末步：** 对照 skill 做合规自查；在 `doc/perf-report/05-3c-randwrite-bs-trend-completion-<YYYYMMDD>.md` 出具短报告，说明各 BS 值、状态顺序与前后锚漂移，并以新增记录更新 results-table。更新 05-6/周报时只新增“描述性趋势补测”栏，不覆盖 05-3b 的停止裁决或把本轮结果提升为正式可交付效应。

### 离线准备与执行边界（2026-09-24历史记录；正式执行见末项）

- 六格驱动：`scripts/FULLBASELINE/debug/t05-3c-randwrite-screen.sh`；离线门：同目录 `t05-3c-gate0-offline.sh`。复用冻结的 05-3b 最终逐 IO 分析器、原 05-3 统计函数及 worker 身份门；三份依赖已按原 SHA 纳入工程。离线门已覆盖六格顺序、实际 fio 参数、分析器自测、错误执行令牌拒绝，以及无旧维护/10% 漂移停门。
- `plan <RUN_ID>` 只创建本 RUN 的 `matrix.tsv`、`commands-plan.sh`、`scripts.sha256` 和 `capacity-plan.template.tsv`；执行方须根据**现场只读容量快照**填写六行 `batch=trend` 的 `capacity-plan.tsv`，注明来源和保守增长公式。模板中的 `FILL` 不会通过 `preflight`；不得将 05-3b 某一 BS 的增长量直接当成所有 BS 的已知增长量。脚本首先核对脚本哈希、卷/文件身份、私有8线程配置、健康及容量。远端证据仅写入 `/tmp/production/05-3c-<RUN_ID>`；该目录隔离删除范围，**不隔离系统盘容量**。05-3b三格写原始证据未压缩约137 MB，30 GiB不是本任务实际日志需求。157共享系统盘在开跑前、每格前和每格运行中保持至少 **20 GiB可用**，每次采样记录 `disk-free-kib.tsv`；低于门槛或无法读取容量即停当前负载。运行中先查空间，再做较慢的集群采样。20 GiB是对共用系统盘的保守止损余量，不是预计日志大小，也不能代替Ceph/BlueFS独立容量门；本轮结束后持久化核验通过即及时精确清理本RUN远端暂存，不积累历史RUN。不得占用未来缓存测试所需的 `/mnt/jfs-cache`，不得为满足门槛清理其他人的目录。
- `write-phase <RUN_ID> I_ACK_05_3C_RANDWRITE_<RUN_ID> I_ACK_GLOBAL_CEPH_SCRUB_PAUSE` 只在**用户另行批准测试和 scrub 租约的 sudo 写操作**后使用。驱动通过已有 `u141d-scrub-control.sh` 暂停并恢复 `noscrub/nodeep-scrub`；除这两项获批 flag 外，不做 compact、GC、layout、清文件或其他全局配置修改。六格内每格前后及运行中检查健康/容量，安全门失败即停并保留部分 raw；带宽、CV 和锚漂移不会使它跳过慢格。
- `plan`/`preflight`/`write-phase` 应用同一冻结部署目录，避免脚本哈希不一致。远端证据仍是临时副本，按本文的持久化和精确清理合同处理；当前离线 Gate 通过不代表现场容量、scrub 授权或业务隔离已通过。
- 2026-09-24 旧门沿革：05-3b因逐IO日志和当时系统盘仅约20 GiB可用而设30 GiB固定门；该值没有基于05-3c六格日志量计算，现按用户要求改为20 GiB运行中系统余量门。本地新版 `bash -n`、离线Gate 0（含20 GiB边界正反例）和`git diff --check`通过；runner SHA256=`f50f58820b183c861b0e21948259709fa9f7cdcda9b5685f9eb5dbf0751c8854`，Gate 0 SHA256=`2a18b63439507e241cf12cb71d228da4e8733b4c18f1fae2ee4b3d58af684051`。157上04阶段旧暂存精确清理626项、约1.70 GB，审计见 `/mnt/c/SunRise/test/prune-04-stage-20260924.tsv`；随后又精确清理148项非05/06旧文件，剩余78项均为05/06，`/tmp/production`约842 MiB、`/tmp`可用约27.6 GiB。此前在 `/mnt/jfs-cache` 建证据目录的方案及其sudo请求**作废**，不得据此执行。旧部署脚本含30 GiB门，必须以新版脚本哈希重新离线核对与部署；现场/scrub授权仍须另行取得。
- 2026-09-24 RUN `20260924-225547`：157已同步新版两脚本并以相同SHA通过远端离线Gate 0；`plan`与128文件`inventory`通过，Ceph `HEALTH_OK`、6/6 OSD、六OSD BlueFS慢盘占用0且当前DB空闲约38 GiB，未运行preflight/fio/挂载/scrub sudo。私有8线程配置（仅含内部mon地址/FSID、无密钥）复制动作被安全审查拒绝；157既有同SHA源位于 `/mnt/jfs-cache/05-3b-evidence-20260920-092512/inventory/ceph-msgr8.conf`。在用户明确确认该配置的同机复制及四条全局scrub标志sudo写操作前，不得通过其它路径绕过；RUN现场保留。
- 2026-09-25 最终执行：用户明确批准后，仅在157同机复制上述既有配置并核对SHA；六格脚本返回PASS，scrub租约精确恢复、无fio/私有挂载残留、Ceph HEALTH_OK。原始证据归档至 `/mnt/c/SunRise/test/05-3c/20260924-225547/05-3c-20260924-225547-evidence.tar.gz`，SHA256 `ed98d17b16415b9a0fe34ef0a2c70bbfd723a999ff6582810f502dfc2810d9ba`、3173项、可读性复核PASS；归档排除私有Ceph配置。远端只删除本RUN目录与同名临时tar，`/tmp/production`顶层条目80→78，其他05/06条目未清理。结果仅为大漂移下的描述性观察，不改变05-3b裁决。

## 三、结果裁决与红线

预期结果为一张 `BS / 本 RUN 正式窗带宽 / CV / W4/W1 / 备注` 表；4K 单列 05-3b 历史范围，256K 两锚都列，其他档仅一格。只要同一 RUN 内核心身份和证据有效，即使 CV 或锚漂移很大，仍可回答“这些 BS 在本次条件下大约落在哪个量级”；**不得**据此计算精确相邻档收益、宣告单调关系或给出生产参数建议。若仅部分格通过安全门，就发布部分曲线和停止原因，不重复整轮。

禁止影响157上的 WekaIO/K8s/其他业务；禁止修改系统 Ceph 配置、内核、网卡、设备、主挂载、卷/pool、文件布局；禁止全局 drop_caches、未授权 sudo 写操作、强制卸载、宽作用域 kill/删除、扩容/停启服务。任何环境资产清理与性能测试授权相互独立。**安全、容量、身份及数据真实性门优先于“用户接受波动”。**
