# 06-5 任务书：randrw 缓存＋writeback 历史收益来源确认

> 日期：2026-09-21  
> 状态：`EXECUTION_COMPLETE / COMBINED_SIGNAL_REPRODUCED / RESOLUTION_INSUFFICIENT / PAUSED_INCONCLUSIVE`  
> 证据等级：`L1_SCREEN`；只确认历史约 21.7% 增幅的主要来源与适用条件，不直接签生产配置。  
> 上位计划：[06阶段计划](../perf-analysis/06-randrw-cache-and-write-path-tuning-plan.md)；
> 前置评估：[06阶段收口恢复可行性](../perf-analysis/06-CLOSEOUT-RECOVERY-FEASIBILITY-20260921.md)。  
> 本任务是该未决收益的**唯一后续执行入口**；原[06-3任务书§七](06-3-randrw-cache-admission-and-burst-performance-screen.md#七本周主线一217观察收益复现与来源确认2026-09-21)仅保留历史合同和已执行结果，不得与本任务并行或另行补格。  
> 必须遵守：`skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`、
> `skills/TESTING-GUIDE.md`、[任务书指导](TASK-BOOK-AUTHORING-GUIDE.md)和
> [数据生命周期规范](TEST-DATA-LIFECYCLE-POLICY.md)。  
> **本文只定义任务，不授权停止服务、卸载、GC/compact、修改 Ceph flags、挂载或运行 fio。**

> 2026-09-21已完成正式RUN `20260921-182559`。六格、7次恢复、排空、读回、环境恢复与证据持久化
> 全部通过；W/C两组约`+20.7%～+21.2%`，但R臂漂移约`7.55%`超过预注册分辨率门，来源裁决保持
> `PAUSED_INCONCLUSIVE`。正式报告见
> [06-5报告](../perf-report/06-5-randrw-cache-writeback-benefit-source-attribution-20260921.md)。

```text
06-1   96GiB缓存＋writeback完整180秒观察增幅约21.7%，但起始Dirty和运行状态不对称
06-3   同配置ABBA未复现；无缓存臂首尾下降约34.5%，起点/携带效应使因果不可判
只读评估  当前对象数约为06-1归一起点3.06倍，portal也挂载同一juicefs-prod卷
   ↓
06-5   你在这里：维护窗口内统一恢复起点，以C-R-W-W-R-C一次拆清主要来源
   ├─ 恢复或业务隔离失败：停止，不跑fio
   ├─ 六格噪声/漂移过大：PAUSED_INCONCLUSIVE，不补漂亮样本
   ├─ W/C无可重复收益：历史增幅仅保留为状态依赖信号，不登记配置收益
   └─ W/C复现：用R/C、W/R判断读缓存与writeback各自贡献
07阶段 新容量、新buffer或新源码优化；不在本任务内展开
```

一句话：**在同一共享卷、同一数据集和逐格一致的恢复合同下，只用一个三臂六格矩阵判断历史
21.7%增幅是读缓存、writeback/脏页暂存，还是不可复现的运行状态差异。**

## 〇、最小决策合同

```text
PRIMARY_QUESTION=统一恢复起点后，96GiB缓存+writeback的完整180秒randrw增幅能否复现，主要来自哪条路径
MINIMUM_DECISION_SET=一次恢复canary + C1/R1/W1/W2/R2/C2六格，不追加容量档或源码分支
STOP_AFTER_ANSWER=六格足以裁决即停止；无材料信号、恢复失败或噪声过大均不补样
MAX_PREP_BUDGET=2h；只参数化复用06-1恢复和06-3采集/分析组件，不新建编排框架
MAX_EXECUTION_BUDGET=一个维护窗口，目标4--6h；安全排空、恢复共享会话不受该预算截断
EVIDENCE_ROOT=/mnt/c/SunRise/test/06-5/<RUN_ID>/
REMOTE_RESULT_ROOT=/tmp/production/opencode-06-5-<RUN_ID>
EVIDENCE_RETENTION=FORMAL
EVIDENCE_PURPOSE=ATTRIBUTION
REMOTE_CLEANUP=AFTER_PERSISTENCE_AND_REVIEW
ENVIRONMENT_ASSET_CLEANUP=恢复本任务暂停的会话/scrub状态；固定测试资产保留
```

## 一、背景与唯一目标

06-1 的同轮组合臂相对无缓存臂，全程完成字节/实际时长口径约为读 `+21.73%`、写 `+21.68%`；
但处理臂起始 Dirty 不对称，前段高带宽与宿主脏页吸收高度一致。06-3 后续同配置复验中，处理臂
自身稳定，无缓存臂却从约 `629/631` 降至 `412/413 MiB/s`，两组配对异号，不能确认配置因果。

当前共享卷对象数约 `6.12M`，而06-1逐格恢复后的参考水位约 `2.00M`；仅等待 TiKV
pending-compaction 回零不能还原对象/slice历史。与此同时，157测试挂载和ceph-node3 portal挂载
都使用 `juicefs-prod`，因此全卷恢复只能在明确维护窗口内进行。

本任务的**唯一目标**是确认历史约21.7%增幅的主要来源，候选限定为：

1. `R/C`：96GiB普通块缓存路径带来的读命中收益（包括该配置实际启用的预取行为）；
2. `W/R`：开启writeback后，本地staging和宿主脏页吸收带来的额外前台收益；
3. 若统一恢复后`W/C`不能重复，则历史数值主要是状态/携带效应下的条件性信号，而不是可固化配置收益。

本任务不承诺把历史增幅按百分比精确分摊，也不区分宿主页缓存与NVMe介质的每个微观贡献；设备读写、
Dirty和缓存计数只用于限定主要服务路径。若需要逐请求源码归因，转07阶段另立任务，不能在本RUN加profile。

## 二、前置维护与授权边界

### 2.1 维护窗口成立条件

进入任何写操作前必须完成只读 inventory，并逐一确认：

- `juicefs-prod`全部已注册会话、主机、挂载点及用途；157 `/mnt/juicefs`和portal namespace会话必须
  有明确负责人、暂停方式和恢复方式；发现未知会话或无法停写的客户端即停止。
- 无fio、layout、portal扫描写入、其他基准或共享卷写任务；Ceph无恢复/回填，OSD全部up/in，PG全部
  active+clean。
- 三节点TiKV、Ceph pool、128×1GiB固定`rw_test`数据集、交付二进制MD5、META/UUID均与合同一致。
- 全卷恢复期间，portal对该卷的功能可暂时不可用；若业务要求不中断，则本任务不能执行。

“维护窗口”不是整套集群重启，也不授权破坏集群；它只表示共享卷客户端停止写入并接受全卷GC带来的
负载和短时功能暂停。禁止重启主机、PD、TiKV、OSD、网络、Weka或K8s。

### 2.2 必须单独列出并获得用户批准的写操作

离线 Gate 0 后先生成**精确计划**，至少包括：

1. portal及157测试挂载的精确暂停/恢复命令、服务/PID/挂载身份；不得猜服务名或用模式kill。
2. 冻结的JuiceFS二进制、META和卷身份下，全卷 `juicefs gc --compact --delete --threads 32 <META>`
   的实际命令、超时、最大执行次数和每次作用点。计划上限为：初始canary一次、六格间/后恢复最多六次；
   任何重试必须先停下说明，不能自动无限重跑。
3. 若选择暂停scrub，列出原flags、`noscrub/nodeep-scrub`设置和精确恢复命令；这是Ceph全局状态变更。
4. 私有测试挂载、缓存目录和结果目录的精确白名单；写入只能落在批准路径。

计划必须扫描全部调用脚本中的sudo写操作、重启/关机、递归删除、设备写和服务停启，并把匹配行完整
回传。以上命令未经用户逐条确认不得执行。**主动OSD compact、TiKV compact、drop_caches、全局sync、
format、layout、destroy、pool/PG/CRUSH修改不属于本任务默认许可**；恢复canary失败时只报告，不临时加做。

## 三、固定矩阵与控制变量

### 3.1 三个臂

| 臂 | 普通块缓存 | writeback | cache-large-write | 用途 |
|---|---:|---|---|---|
| C | `cache-size=0` | 关 | 关 | 无客户端缓存对照 |
| R | `cache-size=98304 MiB` | 关 | 关 | 只测普通块缓存路径 |
| W | `cache-size=98304 MiB` | 开 | 关 | 在同缓存预算上测writeback增量 |

`cache-size`是普通块缓存管理目标，不是独立只读分区；W臂的staging不计入96GiB预算，须另外通过空间门。
三个臂共用同一交付二进制、META、B256卷、数据集、原生NVMe/ext4私有缓存根、FUSE256K、buffer300、
max-uploads150、max-downloads200和60秒对称预热。`max-readahead`沿用并记录06-1实际值，不得在本RUN
另行调参；因此R/C严格称“普通缓存路径贡献”，只有确认预取为0时才可缩写成“纯读缓存贡献”。不得引入
loop、CLW、buffer2048或新源码构建。

### 3.2 fio合同

- `randrw` 50/50、`bs=256K`、`ioengine=libaio`、`iodepth=128`、`numjobs=128`、`direct=1`；
- 128×1GiB既有`rw_test`文件，禁止create-on-open、format和layout；
- 正式负载180秒，固定与06-1相同seed；R/W分开报告；
- 主值为完整完成字节除以读写较长的实际runtime；另报W1--W4、P10/P50/P90和CV，用于区分全程收益与
  前段暂存收益，不因后段变慢删除样本。

### 3.3 唯一矩阵

按 `C1 → R1 → W1 → W2 → R2 → C2` 连续执行。每格前都必须由同一恢复合同建立起点：

1. 前一格writeback严格排空、独立cache=0挂载抽样读回、优雅卸载；
2. 执行同一全卷JuiceFS GC/compact；
3. 等pool objects/stored连续三点稳定、三节点TiKV pending-compaction连续三点为0、Ceph clean、无scrub/
   recovery流量、客户端Dirty/Writeback进入冻结阈值；
4. 保存起点快照后才允许下一格挂载、预热和fio。

恢复过程本身是潜在携带效应，因此命令、次数和门值必须六格一致；不得看到性能后改变threads、等待时长
或补做OSD compact。初始canary若不能把对象数拉回稳定存活水位，或一次恢复超时/健康异常，即停止整个
矩阵，不以当前状态勉强开跑。

## 四、证据与预注册裁决

### 4.1 最小真值集

每格只采回答主问题必需的轻量证据：

- fio JSON/全文、128份per-job bw日志、shell/fio实际起止、rc和I/O错误；
- 实际挂载命令、binary MD5、META/UUID、PID/starttime、findmnt、固定资产前后身份；
- JuiceFS hit/miss bytes、cache writes/drops/evicts、GET/PUT次数和字节、uploading mean/P95/max、
  staging占用/错误/排空时间；
- 宿主Dirty/Writeback、缓存设备读写吞吐/await/aqu-sz、df和内存；
- pool objects/stored、Ceph健康/PG/OSD状态、TiKV pending-compaction与事务延迟。

不启用trace、pprof或逐请求重型日志。若命中高而缓存设备读近零，结论必须写“宿主页缓存供给的本地缓存
路径”，不得宣称NVMe介质读性能。缓存报告必须给出`drops/(drops+writes)`和`evicts/writes`。

### 4.2 效应计算

R/W两个方向分别计算，禁止相加：

- 普通缓存路径贡献：`R1/C1 - 1`、`R2/C2 - 1`；
- writeback增量：`W1/R1 - 1`、`W2/R2 - 1`；
- 组合复现：`W1/C1 - 1`、`W2/C2 - 1`；
- 本RUN噪声 `ε` 取C、R、W各自第二次/第一次变化绝对值的最大值，材料线
  `M=max(5%, 2ε)`。

这是L1来源筛选，不把六格写成精确置信区间。只有两组位置比较在读、写两个方向均同向且达到M，才记
对应路径有材料贡献；一正一负或小于M均不得挑均值宣布收益。

### 4.3 来源判定

| 数据形态 | 允许结论 |
|---|---|
| `W/C`重复为正，`R/C`重复为正，`W/R`无材料增量 | 主要来自普通缓存读命中；writeback未提供可分辨增量 |
| `W/C`重复为正，`W/R`重复为正 | writeback/staging与脏页吸收提供额外前台收益；结合Dirty、staging和四窗说明是突发还是全程 |
| `W/C`重复为正，但R/C与W/R均低于分辨率 | 组合/交互收益存在，单项来源分辨率不足，不强行分摊 |
| 三臂同臂稳定，`W/C`无重复材料收益 | 历史21.7%不是当前归一合同下可复现的配置收益，主要保留为运行状态依赖信号 |
| 任一臂漂移超过门、恢复不对称或证据缺失 | `PAUSED_INCONCLUSIVE`；不能用这批否定历史收益，也不补样 |

若W臂只有W1显著高、W4回落且Dirty/staging明显增长，允许结论为“有限180秒突发吸收收益”；用户已明确
完整180秒平均提高即有价值，因此不以非稳态自动否决，但必须并列排空时间、易失数据风险与远端持久化
能力，不能把前台完成带宽称为Ceph落盘带宽。

## 五、执行步骤与停点

- [x] **步骤0：通读并确认规范。** 执行方记录关键红线ACK，尤其是共享卷、157业务保护、sudo逐条授权、
  writeback先排空后卸载和证据生命周期。
- [x] **阶段0A：最小离线适配与Gate 0。** 复用`t06-1-randrw-cache-driver.sh`的全卷恢复函数、
  `t06-3-randrw-cache-driver.sh`的三臂采集/排空/身份守卫及既有分析器；只新增六格配置表和来源计算。
  不复制整套驱动。自测覆盖矩阵顺序、臂参数、GC次数上限、失败即停、W臂排空和恢复门。
- [x] **阶段0B：只读inventory和精确计划。** 远端写操作数必须为0；生成会话清单、维护影响、恢复canary、
  六格执行、失败恢复、sudo写全集和空间预算。
- [x] **停点1（必须由用户决定）：** 审核Gate 0与计划，并分别批准共享会话暂停/恢复、全卷GC次数上限、
  scrub控制、缓存路径和正式六格。没有批准即保持`PLANNED`。
- [x] **阶段1：维护窗口与恢复canary。** 暂停获准会话/写任务，核对卷静止；只执行一次恢复canary并等待
  恢复门。canary失败立即恢复已暂停状态并结束，不跑fio。
- [x] **阶段2：六格连续执行。** canary通过后按§3.3完整运行，阶段内部不逐格停；任何健康、安全、身份、
  空间、排空或恢复门失败即保留现场并停止，不修改合同继续。
- [x] **阶段3：恢复与持久化。** 恢复scrub和所有本任务暂停的会话，确认portal/测试挂载状态、Ceph健康、
  无fio/sampler/私有挂载/缓存残留；权威证据持久化并校验后再按精确清单清远端临时副本。
- [x] **停点2：第二方独立复算与裁决。** 只基于raw计算C/R/W三类效应和来源结论；不追加样本。
- [x] **末步：按全部skill复核合规。** 更新同编号报告、results-table、06阶段计划与状态表。

## 六、交付物与生命周期

```text
/mnt/c/SunRise/test/06-5/<RUN_ID>/
├── common/                 实际脚本、SHA、binary/META/UUID、commands.sh、contract
├── inventory/              会话、业务、卷、Ceph/TiKV、容量与只读现场
├── maintenance/            暂停/恢复计划、用户ACK、前后状态、scrub lease
├── recovery/<tag>/         GC原始输出、objects/stored、TiKV和健康恢复序列
├── cells/{C1,R1,W1,W2,R2,C2}/
│   ├── fio.json formal/bw/*.log
│   └── metrics/ iostat/ meminfo/ identity/ drain/ readback/
├── analysis/               独立复算输入、结果和版本
├── incidents.tsv           append-only
├── lifecycle/              manifest、persistence、retention、purge-audit
└── report.md
```

- 正式报告：`doc/perf-report/06-5-randrw-cache-writeback-benefit-source-attribution-<日期>.md`；
- 真值同步：`doc/deploy-log/results-table.md`、06阶段计划和06阶段状态；
- 公共证据每RUN只复制一次，cell只增量保存；原始raw不可覆盖；失败重试使用新RUN_ID；
- 本地权威根完成manifest、SHA、文件数和字节数核验前，不删除远端最后一份证据；
- 证据清理不授权删除卷、pool对象、TiKV数据、挂载、进程、设备或固定数据集。

## 七、通用注意事项与红线

1. **统计真值**：实际I/O起点、完整完成字节/实际runtime和全部per-job日志为主；fio summary仅旁证；
   R/W分报，所有轮次照报，禁止删慢样本或跨RUN拼效应。
2. **固定资产**：只使用既有B256卷与128×1GiB数据集，不create-on-open、不layout、不format、不destroy；
   各格前后核对文件数、大小、卷UUID和二进制身份。
3. **缓存口径**：不执行157全局drop_caches，不清其他业务页缓存；三臂采用同一预热和起点门，并记录
   Dirty/Writeback。direct=1只绕应用页缓存，不绕JuiceFS缓存及其宿主页缓存。
4. **writeback安全**：W格必须先等待已注册staging/uploading及私有rawstaging连续三点为零，再优雅
   卸载；超时保留挂载和现场，禁止强制/懒卸载和清缓存目录。
5. **读回边界**：每格使用独立cache=0挂载抽样读回，只能证明远端可读/无EIO，不能声称内容正确性。
6. **健康与scrub**：每格fio前检查Ceph；scrub只在获批维护窗口内暂停并精确恢复。只有由本任务设置的
   `noscrub/nodeep-scrub`可作为唯一预期WARN，其他WARN立即停止。
7. **安全**：保护157 Weka/K8s、portal及其他业务；不动md0、网卡、内核、Weka路径，不重启任何节点/
   服务，不使用宽作用域`rm -rf`、递归chown、模式kill、`losetup -D`或未批准路径。
8. **sudo和全局写**：运行脚本前扫描其全部调用链；sudo写、服务停启、Ceph flags和全卷GC必须列出
   完整命令、节点和目标，由用户逐条确认；多节点破坏性操作禁止并行。
9. **异常处理**：性能开跑后不得热改脚本、参数、恢复门或统计规则；失败先保留现场。确定性工程bug只可
   离线修复并用新RUN整套重跑一次，原RUN标`EVIDENCE_INVALID`且不得进入效应。
10. **精简闭环**：仅一个恢复canary和一个六格矩阵；不做容量曲线、buffer扫描、源码构建、竞品测试或
    七项回归。达到来源裁决即结束，不为更漂亮数值追加轮次。

## 八、完成线

- [x] Gate 0、只读inventory、维护/GC/scrub/挂载精确计划完成；
- [x] 用户对全部共享/全局写操作明确授权；
- [x] 恢复canary通过，六格均从同一恢复合同起跑；
- [x] 六格fio、机制证据、排空、独立读回及环境恢复全部有效；
- [x] 第二方给出`W/C`、`R/C`、`W/R`两组位置效应、`ε`、`M`和来源裁决；
- [x] portal及原有挂载/服务恢复，Ceph HEALTH_OK，无任务进程、挂载、缓存目录或scrub flag残留；
- [x] 唯一权威证据通过持久化校验，正式报告、results-table和06阶段文档同步。

最终状态只允许以下之一：

- `RESOLVED_CACHE_PATH`：组合收益复现，主要来自普通缓存路径；
- `RESOLVED_WRITEBACK_BURST`：组合收益复现，writeback/脏页暂存有独立材料贡献；
- `RESOLVED_INTERACTION_ONLY`：组合收益复现，但单项低于本RUN分辨率；
- `RESOLVED_STATE_DEPENDENT_NO_DELIVERABLE`：归一起点下组合收益不复现，历史21.7%不再作为配置收益；
- `PAUSED_INCONCLUSIVE`：恢复、漂移、噪声、安全或证据问题仍阻止归因。
