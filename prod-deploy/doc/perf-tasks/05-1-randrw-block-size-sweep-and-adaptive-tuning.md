# 05-1任务书：randrw不同BS性能曲线与JuiceFS适配调优

> 日期：2026-09-14
>
> 面向：执行方采集原始证据，GPT复算与裁决
>
> 状态：`PLANNED / SCRIPTS_NOT_READY / NO_ENVIRONMENT_AUTHORITY`
>
> 上位计划：`doc/perf-analysis/05-block-size-adaptive-performance-comparison-plan.md`

```text
04阶段：exact patched v1.4.1与B256/FUSE256/msgr8通用基线已锁定
  ↓
05-1 Phase A：当前配置只改fio bs，得到randrw标准曲线  ← 你在这里
  ├─ 曲线/状态门失败 → 停止，归因后新RUN
  └─ 有效 → Phase B只对1M/4M筛选FUSE1M
                 ├─ 无材料信号 → 保持现有挂载参数，任务收口
                 └─ 有材料信号 → 用户审核后Phase C验证一个卷BlockSize候选
                                      ├─ 无材料信号 → 收口
                                      └─ 有材料信号 → 另授权L2正式确认
后续：05-2随机纯读/纯写 → 05-3/05-4顺序项 → 05-5导入有方结果汇总
```

一句话：先测“应用BS本身”，再逐层测“FUSE适配”和“卷BlockSize适配”，不把三者混成一个组合收益。

## 〇、最小决策合同

```text
EVIDENCE_LEVEL=L1_SCREEN；材料候选经人工批准后才能升级L2_FORMAL
SCREEN_SOURCE=现有B256/256K randrw基线与04-tmp、04-7、04-8历史证据
SCREEN_CONTINUE=两方向同向且较小方向增益>=5%，并超过同RUN漂移
SCREEN_STOP=未达5%、方向冲突、机制不支持或出现不可消除的状态漂移
FORMAL_MATRIX=C T T C | T C C T；不自动执行
ESTIMATED_WALL_CLOCK=Phase A约1.5--2.5h；Phase B约1.5--2.5h；可选Phase C约2--4h

MINIMUM_DECISION_SET=6档BS正反向各1点+首尾256K锚；1M/4M各一个F256/F1M ABBA；最多一个卷BlockSize候选CTTC
STOP_AFTER_ANSWER=某层无材料信号即停止该层；不扩BS、不补漂亮样本、不自动跑七项
MAX_PREP_BUDGET=复用既有挂载/采集/分析组件，新增参数化与离线Gate合计<=90min
MAX_EXECUTION_BUDGET=未经新授权只执行Phase A+B且<=5h；Phase C与L2分别停点授权

EVIDENCE_ROOT=/mnt/c/SunRise/test/05-1/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-05-1-<RUN_ID>
EVIDENCE_RETENTION=SCREEN；升级L2后对应RUN改为FORMAL
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=任务mount graceful卸载；可选临时卷按META+Name+UUID精确destroy；既有rw_test不删除
```

## 一、唯一目标与允许回答的问题

唯一主问题：**在固定的128 job、libaio、iodepth 128、50/50 randrw语义下，应用BS变化后，JuiceFS每个方向的带宽如何变化；针对特定BS调整FUSE请求上限或卷BlockSize，能否取得至少5%的双向材料收益？**

允许回答：

1. 当前交付配置在`4K/16K/64K/256K/1M/4M`的端到端曲线；
2. FUSE1M对1M和4M randrw是否有升级价值；
3. 最多一个匹配卷BlockSize候选相对fresh B256是否有升级价值；
4. 后续与有方同命令结果逐方向比较所需的JuiceFS数据。

明确不回答：有方环境执行、所有可能参数的全局最优、缓存/writeback收益、硬件单因素优劣，以及L1点能否直接成为生产配置。

## 二、固定负载与身份

### 2.1 fio合同

除`bs`外以下参数逐字固定：

```text
rw=randrw
rwmixread=50
ioengine=libaio
iodepth=128
numjobs=128
filesize=1G
size=1G
direct=1
fallocate=none
allow_file_create=0
openfiles=128
time_based=1
runtime=180
group_reporting=1
randrepeat=1
```

数据集为128个已完整写入、每个1 GiB的任务测试文件。Phase A/B优先复用已验证的现有`rw_test`固定资产；禁止自动补文件、自动修大小或轮间layout。若资产不存在或被foreign fio占用，停止而不是现场重建。

每个cell必须输出JSON+、fio全文和128份per-job 1秒bw log。randrw READ/WRITE分别统计，不使用两向合计作为通过条件。

### 2.2 JuiceFS固定身份

| 项 | 固定值 |
|---|---|
| binary | `/tmp/juicefs-1.4.1-patched`，MD5必须为`24fae0852051c80ca571cb2f20275d46` |
| 当前对照卷 | Name、META、UUID现场只读冻结；BlockSize必须为256 KiB |
| 对照挂载 | `--max-fuse-io 256K --max-uploads 150 --cache-size 0`，writeback关闭，默认readahead |
| Ceph客户端 | 私有`ceph.conf`，`ms_async_op_threads=8` |
| 客户端 | 157；禁止全局drop_caches，禁止碰WekaIO/K8s/md0/网络/内核 |
| 后端 | 现有6 OSD EC4+2与三节点TiKV；不改配置、不重启 |

## 三、Phase A：只改变fio BS的标准曲线

固定次序为：

```text
256K-A → 4K → 16K → 64K → 1M → 4M → 4M → 1M → 64K → 16K → 4K → 256K-B
```

每个BS获得一个早期点和一个后期点，256K提供首尾漂移锚。整段使用同一挂载、同一数据集，不重挂、不layout、不改变任何JuiceFS参数。

Phase A开始前完成一次既有标准full-clean门；cell之间只检查health、foreign fio、I/O error和必要的TiKV/OSD状态，不主动compact或改变环境。Phase结束后再做写后恢复。这样避免恢复动作与BS档位共线；正反向次序用于量化运行状态累计。

有效性规则：

- 首尾256K任一方向漂移`>10%`，Phase A记`RESOLUTION_INSUFFICIENT`；
- 同一BS两个方向位置点任一方向差异`>10%`，该BS只作范围，不给精确均值；
- 正式窗与历史一致，为实际timed-I/O起点后的`[15,175)`；按全部per-job log时间对齐求和、自然秒重叠加权；
- 不因CV或性能高低删样，不在同RUN补第三点。

## 四、Phase B：大BS的FUSE适配

仅测试`bs=1M`和`bs=4M`。卷仍为现有B256，唯一变量为：

```text
C: --max-fuse-io 256K
T: --max-fuse-io 1M
```

其他挂载参数、fio合同和数据资产完全一致。每个BS独立执行`C→T→T→C`；两个BS之间完成必要的full-clean恢复。04-8已确认FUSE1M不能作为七项通用配置，但该结论不排除它成为大BS randrw专用参数。

通过门：两次配对的READ、WRITE均同向，且四个方向效应中的最小值`>=5%`；fio错误、FUSE请求尺寸、JuiceFS GET/PUT及Ceph完成率不得显示反向机制。未通过即停止，不扫描512K、2M或更多FUSE值。

本阶段不测试RA32。它在04-tmp3c提升的是低并发顺序读对象在途量，而128×128 randrw已经提供大量应用并发，直接套用可能只增加无效预读。若默认readahead下观测到GET/有效读字节放大显著高于1.2，才允许另立一个RA0最小筛选，不在本RUN热加。

## 五、Phase C：一个卷BlockSize适配候选（可选、单独授权）

Phase A/B审核后最多选择一个`BS*`：

1. 从`64K/1M/4M`中选择相对256K最具业务价值、且Phase B/机制证据表明仍受对象或FUSE粒度影响的一档；
2. 若没有明确候选，Phase C取消；
3. 匹配规则为`Volume BlockSize=BS*`，同时建立fresh B256对照卷。小于64K的fio BS不进入本阶段，因为JuiceFS卷BlockSize最小为64K。

两卷必须使用本RUN独立META/Name/UUID、同一Ceph pool和等价的128×1 GiB完整数据集；先完成一次layout及统一cooldown，再固定挂载参数。比较矩阵为`B256→B*→B*→B256`。不得把fresh B*与历史生产B256直接相减，也不得把FUSE变化与卷BlockSize变化放在同一个效应中。

Phase C前必须回传：

- 两条format完整命令、卷名/META、挂载路径和destroy计划；
- pool可用容量及本任务最大逻辑/物理占用估算；
- 所有sudo写操作扫描结果。默认本阶段不需要sudo写操作；如出现必须单独列出并获用户确认。

Phase C只签L1升级价值。达到5%双向材料门后暂停，由GPT决定是否用`C T T C | T C C T`补L2；不得自动升级。

## 六、最小采集与分析

### 6.1 CORE（缺失则RUN无效）

- binary、META、Name、UUID、Volume BlockSize、挂载PID/starttime/exe和完整参数；
- fio完整命令、rc、JSON+、全文、128份per-job bw log及实际I/O起止时间；
- cell前后Ceph health、OSD up/in、逐PG状态、foreign fio、挂载唯一性；
- 任务数据路径、128个inode/size清单；临时卷另含layout manifest；
- `commands.sh`、实际脚本SHA256、`incidents.tsv`和证据manifest。

### 6.2 MECHANISM（用于解释，不单独判无效）

- fio READ/WRITE MiB/s、IOPS、clat mean/P95/P99；
- FUSE平均请求尺寸/请求率；
- JuiceFS对象GET/PUT字节、qps、平均延迟及有效字节放大；
- TiKV事务/写入qps与延迟、pending compaction；
- Ceph op_r/op_w qps、字节率和延迟；157 JuiceFS进程CPU、双向NIC。

只采已有低开销指标，不为本任务开发新的全栈采样平台。只有发生异常时才追加DIAGNOSTIC证据。

### 6.3 输出表

每个BS输出：

```text
bs,config,read_MiB_s,write_MiB_s,read_iops,write_iops,
read_clat_p95,write_clat_p95,position_pair_spread,
fuse_req_size,get_put_amp,tikv_state,ceph_state,verdict
```

另生成三张图：BS—READ带宽、BS—WRITE带宽、BS—P95延迟；横轴为log2。后续导入有方值时，按方向计算`JuiceFS/有方`百分比。

## 七、执行步骤与停点

### 阶段0：离线Gate 0

1. 测试前通读`SYSTEM-SAFETY-SKILL.md`、`TASK-BOOK-AUTHORING-GUIDE.md`、`TEST-DATA-LIFECYCLE-POLICY.md`和证据方法规范。
2. 优先参数化复用已签收的randrw执行、挂载和分析组件；禁止复制一套新编排框架。
3. Gate只验证本任务新增的BS列表、正反序列、F256/F1M变量守卫、READ/WRITE方向解析、128份日志覆盖、身份和危险命令扫描。
4. Gate通过后回传实际脚本SHA、预计命令、远端/本地路径和sudo写命令全集；未获环境授权不得连接执行。

### 阶段1：Phase A+B连续执行

获得授权后，执行方可连续完成inventory、Phase A、恢复、Phase B、最终恢复、增量持久化和原始证据清单，不逐cell停。任一身份、health、foreign fio、I/O error或日志覆盖硬门失败立即停止并保留最小现场。

执行方只交原始数据、逐门PASS/FAIL和incident，不计算正式效应、不挑轮。GPT独立复算后决定关闭任务或是否授权Phase C。

### 阶段2：可选Phase C与最终收口

只有Phase A/B审核选出`BS*`并完成临时卷/容量/destroy计划审核后才可执行。Phase C结束无论性能如何，都先graceful卸载，再按精确META+Name+UUID计划销毁临时卷，最后验证业务卷、业务挂载、Ceph和TiKV指纹未变。

测试后按上述skill复核实际命令、控制变量、正式窗、原始证据、环境恢复和生命周期状态。

## 八、通用注意事项与安全红线

- 不运行归档通用脚本的`clean`入口；不使用glob、父目录递归删除、`rm -rf`、force/lazy umount或模式kill。
- 不全局drop_caches，不改内核、网络、IRQ、NUMA、WekaIO、K8s、md0、OSD/TiKV配置，不停止或重启业务服务。
- Phase A/B不新建数据、不改文件集合；randrw允许覆盖内容，但禁止删除、重命名和自动修复文件。
- L1默认保持Ceph scrub原状态并记录正式窗重叠；不得自主设置`noscrub/nodeep-scrub`。若L2需暂停，必须用既有状态驱动控制脚本、单独列命令并获授权，结束后优先恢复。
- 任何sudo写操作、临时卷format/layout/destroy及证据外环境清理都必须先给出精确计划和目标；证据清理授权不能代替环境资产授权。
- 新增或复用的shell入口必须`set -euo pipefail`，不得包含明文口令、重启命令或修改JuiceFS源码/二进制；执行前扫描其直接调用链中的sudo写和破坏性命令。
- 挂载和进程按已登记的PID/starttime/exe/UUID做状态驱动清理，先graceful unmount再处理进程；禁止按名称批量kill。
- Ceph必须满足预注册health/PG门，高强度写后完成对象回归及TiKV/OSD compaction cooldown；恢复不完整时禁止进入下游测试。
- raw一经manifest登记不得覆盖；远端证据只有在唯一持久副本通过SHA、文件数、字节数和可读性核验后才可精确清理。
- 失败时先停、记录incident并保留必要现场；脚本bug可在不改变量时离线修复，但同RUN不得热改后继续冒充有效数据。

## 九、交付物

- 权威证据：`/mnt/c/SunRise/test/05-1/<RUN_ID>/`；公共证据一份、cell增量保存；
- 正式报告：`doc/perf-report/05-1-randrw-block-size-sweep-and-adaptive-tuning-<DATE>.md`；
- 更新：`doc/deploy-log/results-table.md`及05阶段计划状态；
- 生命周期：源端与本地SHA、文件数、字节数和归档可读性全部通过后才能清远端临时副本；L1长期保留最小可复算raw，若升级L2则保留完整不可变正式归档。

任务完成线：标准BS曲线有效、适配候选已按规则停止或升级、环境恢复、唯一证据真值可复算，并明确给出“保持B256通用基线”或“哪一BS/参数值得正式确认”的有限结论。
