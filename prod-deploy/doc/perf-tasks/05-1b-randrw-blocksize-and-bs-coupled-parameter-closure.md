# 05-1b任务书：randrw卷BlockSize与BS联动参数收尾

> 日期：2026-09-14
>
> 面向：执行方采集原始证据，GPT独立复算与裁决
>
> 状态：`COMPLETED / VALID_WITH_LIMITS / ENVIRONMENT_CLOSED`（2026-09-15 订正：L组B4M候选改判
> `NET_GAIN_UNPROVEN`，净收益转由`05-2` Phase V三臂判定；见
> `doc/perf-report/audit-05-1-05-1b-bs-data-usability-and-comparison-20260915.md` §四）
>
> 上位计划：`doc/perf-analysis/05-block-size-adaptive-performance-comparison-plan.md`
>
> 承接报告：`doc/perf-report/05-1-randrw-block-size-sweep-and-adaptive-tuning-20260914.md`
>
> 本任务报告：`doc/perf-report/05-1b-randrw-blocksize-and-bs-coupled-parameter-closure-20260914.md`

```text
05-1：B256标准BS曲线有效；1M下FUSE1M有L1信号
  ↓
05-1b：补齐此前跳过的卷BlockSize和必要联动参数  ← 你在这里
  ├─ 小BS：FUSE64代表筛选；fresh B64与fresh B256比较
  ├─ 1M：fresh B1M与fresh B256比较，均用FUSE1M
  └─ 4M：fresh B4M与fresh B256比较，均用FUSE1M
       ├─ 无材料信号 → 保留有效曲线数值，不登记候选
       └─ 有材料信号 → 保留数值并登记对应BS专用候选；另授权L2
后续：05-2上传并发/缓冲闸门 → 05-3纯随机读写 → 05-4/05-5顺序项 → 05-6汇总（2026-09-15编号顺延）
```

一句话：**不重跑05-1，只用同轮fresh对照补齐B64/B1M/B4M，并在证据明确触顶时最多追加一个联动旋钮。**

> 最终结果：A组回退FUSE256K；M组B1M保留`+28.34%～+40.70%`强工程信号；L组确认
> B4M需要buffer1024，正式同轮相对B256提升`+17.94%～+18.80%`；S组B64在4/16/64 KiB
> 均无材料性正收益。所有临时卷和scrub lease已恢复，任务关闭。

### 0.1 2026-09-14执行后修订（优先于后文冲突的停止条款）

05阶段的目标是交付JuiceFS与有方在不同fio BS下的完整可比曲线，不是只筛选有收益的调优点。
因此：

1. `收益<5%`只用于判断是否登记候选，**不得用于跳过或删除已规定的BS数据**；
2. S组必须补齐4K/16K/64K的B256与B64两位置数据；为避免已知scrub随机污染长矩阵，
   先用既有状态驱动工具生成`noscrub+nodeep-scrub`精确设置/恢复计划，另经用户授权后执行，必须在RUN结束恢复原flag；
3. L组的B4M低值不得按“性能差即淘汰”关闭。低完成率下1秒bw log可能为空，因此L补测使用未平均的聚合完成日志，
   按完成时间、方向和实际IO字节重建秒级带宽；
4. 先用一轮诊断RUN在同一B4M卷上最小比较`buffer-size=300/1024MiB`，随后销毁诊断RUN；正式L组另起fresh RUN，
   两臂均使用获选buffer，避免buffer与BlockSize共线。若1024不能解除约30秒周期停顿，正式L组仍记录B4M低值，
   再以B1M/FUSE1M作为4MiB fio的适配候选，因为内核FUSE实际请求上限为1MiB；
5. 补测只复用现有format/layout/cell/GC/destroy组件，不重写编排器，不扩大fio的jobs/QD/runtime矩阵。

### 0.2 2026-09-15最终执行签收

1. 诊断RUN `20260914-221613`证明B4M/buffer300的完成集中在正式窗之后；buffer1024恢复到约
   `1996/2006 MiB/s`，因此正式L组两臂共同使用buffer1024，只隔离BlockSize变量。
2. 正式RUN `20260914-225012`中，B4M相对B256两组READ/WRITE效应均为
   `+17.94%～+18.80%`，同臂漂移不超过0.69%；登记为4 MiB randrw专用卷L1候选。
3. B64相对B256：16 KiB仅约`+1.2%～+1.7%`，64 KiB为负；原矩阵4 KiB漂移过大后只追加
   一次最小`C1→T1→T2→C2`，两组均为负、均值约`-4.3%`。保持B256，不再补样。
4. S长矩阵和4 KiB收尾分别使用独立scrub lease；`noscrub/nodeep-scrub`均已按原flag恢复。
   L/S临时卷按精确UUID销毁，Ceph最终`HEALTH_OK`、6/6 OSD、97/97 PG active+clean。
5. 权威正式补测包位于`/mnt/c/SunRise/test/05-1b/20260914-225012/final/`，SHA256为
   `8ef69d78f6464abb02dc91ca32c1e0c8f75286c8d8ca9b2dab86ce3df84132c4`。任务完成，禁止继续
   扩大05-1b矩阵；后续执行05阶段其他I/O模型。

## 〇、最小决策与生命周期合同

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=05-1有效Phase A/B；04-tmp、04-tmp3c、04-7、04-8机制证据
SCREEN_CONTINUE=READ/WRITE两方向、两位置配对均同向且最小增益>=5%，机制方向不冲突
SCREEN_STOP=只在非性能硬门失败时停止环境执行；增益<5%或性能差不得中止规定BS曲线
FORMAL_MATRIX=候选获批后另执行CTTC-TCCT，不在本任务自动升级
ESTIMATED_WALL_CLOCK=离线准备<=1h；环境执行约5--8h，其中纯fio约1.3h，其余为layout/GC/cooldown

MINIMUM_DECISION_SET=1个FUSE64代表筛选+3组fresh BlockSize配对；条件联动最多1个CTTC
STOP_AFTER_ANSWER=三组BlockSize有结论且环境恢复即停止；不扫中间BlockSize、不自动跑七项
MAX_PREP_BUDGET=复用t05-1与t04tmp3c组件，脚本修改和Gate 0合计<=90min
MAX_EXECUTION_BUDGET=未经新授权只执行必做L1且<=8h；条件联动和L2均在阶段边界停

EVIDENCE_ROOT=/mnt/c/SunRise/test/05-1b/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-05-1b-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=每组临时卷单独计划、授权并按META+Name+UUID精确destroy
```

- `COMMON`：inventory、实际脚本、二进制和配置身份、format/layout/destroy计划、`commands.sh`，每RUN只保存一次。
- `RAW_CELL`：fio JSON+、秒级聚合bw log；L低完成率cell使用聚合完成日志（历史高速率cell可保留128份per-job log）、实际I/O起止、
  挂载身份、指标和健康门，按cell增量保存。
- 最低复算输入：fio JSON+、完整聚合bw或完成日志、实际结束时刻与runtime、矩阵、实际脚本、mount/volume身份。
- 身份、健康、I/O错误、日志或sampler覆盖失败时，`INCIDENT_STATUS=OPEN`；未归因前不清理相应现场。
- 环境资产与证据文件分开收口；证据持久化不授权卸载、destroy或删除数据。

## 一、背景、目标与边界

### 1.1 为什么补做

05-1固定现有`BlockSize=256K`得到有效标准曲线，并确认：

- fio `bs=1M`时，`max-fuse-io 256K→1M`的最小双向效应为`+16.40%`；
- fio `bs=4M`时，同一变化第二位置只剩约`+3%`；
- 05-1随后以成本为由跳过了卷BlockSize，因而只完成FUSE层适配，没有完成原计划要求的按BS适配。

本任务保留05-1全部有效结果，只补它没有回答的部分。不得把fresh临时卷结果与历史`juicefs-prod`
直接相减；每个候选必须与**同一组、同一时段、相同数据合同的fresh B256**比较。

### 1.2 唯一主问题

在固定`128 job × iodepth 128、libaio、50/50 randrw、无本地缓存和writeback`的条件下，
将卷BlockSize适配为B64/B1M/B4M，能否相对同轮fresh B256取得至少5%的READ、WRITE双向材料收益？

附带问题只用于选择下一步，不单独扩展矩阵：

1. 小BS把FUSE上限从256K降到64K是否有代表性收益；
2. 默认预读、300MiB客户端buffer、上传/下载并发或Ceph objecter在途限制是否明确触顶；
3. 若触顶，哪一个旋钮最值得追加一次最小筛选。

### 1.3 明确不回答

- 不重跑05-1标准曲线或1M/4M FUSE256/FUSE1M矩阵；
- 不改变fio `numjobs/iodepth/ioengine/runtime`来制造更高峰值；
- 不测试读缓存、writeback、`writeback_cache`或`async_dio`；
- 不修改现有卷BlockSize，不新建/删除Ceph pool，不修改TiKV/OSD全局配置；
- L1结果不能直接改通用生产基线，候选L2和七项兼容性另行授权。

## 二、固定口径与分层矩阵

### 2.1 fio合同

沿用05-1，不得改变除`bs`和测试路径之外的字段：

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
log_avg_msec=1000
per_job_logs=1（历史/高速率默认）；补测RUN使用0。S组生成1秒聚合bw日志；L组以`log_avg_msec=0`
生成单一聚合完成日志，并按其中的时间、方向和实际IO字节复算。
```

文件名固定为`test_dir/rw_test.$jobnum.0`。每个卷必须先完成一次真实数据layout，随后验证
`128个文件 × 1,073,741,824字节`；禁止稀疏文件、`create_on_open`、轮间layout或自动补文件。

### 2.2 固定软件和公共挂载条件

| 项 | 固定值 |
|---|---|
| JuiceFS | `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46` |
| Ceph客户端 | RUN私有conf，`ms_async_op_threads=8`；它跟OSD连接数而非fio bs联动 |
| mount公共项 | `--max-uploads 150 --max-downloads 200 --buffer-size 300 --cache-size 0`，writeback关闭 |
| readahead | 默认口径；随机负载不套用顺序读RA32 |
| FUSE | 64K档按阶段A裁决；1M/4M均为1M，内核5.15的FUSE请求上限不超过1MiB |
| Ceph | 现有6 OSD、EC4+2和同一数据pool；不新建pool、不改CRUSH/PG |

`ms_async_op_threads`继续保持8：它的交付规则是`>=OSD数据连接数×1.33`，不是按bs缩放。

### 2.3 阶段A：小BS的FUSE64代表筛选

只在既有B256固定`rw_test`资产上测试`fio bs=64K`：

```text
C: --max-fuse-io 256K
T: --max-fuse-io 64K
顺序: C1 → T1 → T2 → C2
```

选择64K而不继续扫4K/16K上限的理由：三档的实际应用请求都不超过64K，FUSE64不会拆包；
64K又是三档中吞吐和客户端压力最高的代表点。若FUSE64未过5%门，停止下调FUSE，不再扫
4K/16K；若通过，它只登记为小BS专用候选，不外推为通用挂载。

阶段A不参与后续BlockSize因果效应。阶段B的两臂必须使用**完全相同**的FUSE参数：

- 阶段A通过：B64组两臂均用FUSE64；
- 阶段A未通过：B64组两臂均用FUSE256。

### 2.4 阶段B：三组fresh BlockSize配对

每组独立执行完整生命周期，前一组destroy和恢复通过后才能创建下一组。不得复用一只B256对照
跨三组测试，因为它会比候选卷多承受写入和GC，形成历史状态不对称。

| 组 | fio bs | 对照 | 候选 | 两臂共同FUSE | BS序列 |
|---|---|---|---|---|---|
| S | 4K/16K/64K | fresh B256-S | fresh B64 | 阶段A获选值 | 见下方平衡序列 |
| M | 1M | fresh B256-M | fresh B1M | 1M | `C1→T1→T2→C2` |
| L | 4M | fresh B256-L | fresh B4M | 1M | `C1→T1→T2→C2` |

S组为避免按BS顺序与臂共线，固定执行：

```text
C-4K → C-16K → C-64K → T-4K → T-16K → T-64K
→ T-64K → T-16K → T-4K → C-64K → C-16K → C-4K
```

每个BS的C/T位置均值相同；不得根据中途成绩改变顺序。M/L组各保持两个挂载实例不变完成CTTC，
每格记录PID/starttime/exe，避免把重复fio误当独立挂载。

执行顺序固定为`M→L→S`：优先回答已有FUSE材料信号的1M，B64高对象数布局最后执行。
任何一组无材料信号只关闭该组，不阻止后续组；非性能硬门失败则停止整个RUN。

### 2.5 临时卷与layout合同

每组只允许同时存在两只任务卷，使用RUN和组名隔离：

```text
META namespace: jfs-05-1b-<RUN_ID>-<GROUP>-c|t
Volume Name:    jfs-05-1b-<RUN_ID>-<GROUP>-c|t
Mount path:     /tmp/jfs-05-1b-<RUN_ID>-<GROUP>-c|t
```

- 两卷使用相同Ceph pool、压缩方式、trash-days和凭据，仅Name/META/UUID与BlockSize不同；
- layout逐卷串行，使用实际写入生成128×1GiB，不使用`truncate`冒充数据；
- layout后完成JuiceFS GC、Ceph/OSD compact cooldown和TiKV pending-compaction三点归零；
- 两卷均通过文件数、精确字节数和抽样可读检查后才能开始矩阵；
- 每组开始前记录pool剩余容量，按两卷256GiB逻辑数据、EC4+2约384GiB基础物理量外加临时版本余量估算；
- 不允许使用`juicefs format --force`，不允许与既有Name/META重名。

### 2.6 阶段C：条件联动旋钮，最多一个

阶段B全部完成后暂停，由GPT从原始证据选择**至多一个**下列候选；无触发即取消阶段C：

| 触发条件 | 来源与算法 | 唯一候选变化 |
|---|---|---|
| 读放大 | `juicefs_object_request_data_bytes{method="GET"}`差分 ÷ fio JSON `read.io_bytes`，任一有效臂`>1.20` | 同一候选卷默认readahead vs `--max-readahead 0` |
| buffer压力 | 正式窗`juicefs_used_buffer_size_bytes`P95 `>240MiB`（300MiB的80%） | `--buffer-size 300→1024` |
| 上传连接压力 | 正式窗`juicefs_object_request_uploading`P95 `>120`（150的80%） | `--max-uploads 150→300` |
| 下载连接压力 | GET count/s × GET mean latency推算Little在途量`>160`（200的80%） | `--max-downloads 200→400` |
| objecter字节/ops压力 | 先只读核对实际默认值；GET/PUT Little在途和平均对象尺寸推算值超过对应限制80% | RUN私有conf只提高命中的一个限制 |

优先级为“超过限制比例最高者”，相同则按表格自上而下。矩阵为同一卷、同一BS的`C→T→T→C`；
只改一个参数。执行方不得自行叠加两个旋钮，也不得把性能低本身解释为“触顶”。

`async_dio+max_background`不进入本任务：04-7已观察到randrw带宽下降约11%--13%，且二者必须成组
修改，当前没有足够信号承担额外系统级变量。缓存/writeback另属缓存专项。

## 三、有效性、性能裁决与证据来源

### 3.1 非性能硬门

以下任一失败使相关组`EVIDENCE_INVALID`并立即停止，不得用性能好坏删样：

| 硬门 | 原始来源 |
|---|---|
| 二进制、META、Name、UUID、BlockSize、mount参数和PID身份正确 | `common/identity/*`、`cells/*/mount-state.tsv`、status JSON |
| 两卷文件均为128×1GiB，fio未创建新文件 | `layout-manifest.tsv`、cell前后`assets.tsv` |
| fio rc/error为0、实际runtime约180s | `formal/fio.rc`、`formal/fio.json` |
| READ/WRITE聚合日志完整；历史cell可保留128份per-job日志 | `formal/bw/randrw_bw.log`、L组`randrw_clat.log`或历史`randrw_bw.*.log` |
| sampler覆盖正式窗，无反向计数器跳变 | `juicefs-metrics.tsv`、`sampler-status.tsv` |
| Ceph为HEALTH_OK；S补测暂停scrub时只额外允许OSDMAP_FLAGS，且6/6 OSD up/in、PG active+clean | 每格`health-pre/post.json`、`osd-stat.json`、`pg-state.tsv` |
| 无foreign fio、空间不足、I/O error或任务外挂载变化 | `foreign-fio.tsv`、`df.tsv`、fio/log、环境快照 |

首轮保持scrub原状态并已观察到正式窗重叠。补测S长矩阵必须先用既有状态驱动工具生成计划，
经单独授权设置`noscrub+nodeep-scrub`；S组完成后立即按原状态恢复并验收。除这两个flag外不得修改Ceph全局配置。

### 3.2 主性能口径

- 以fio实际结束时刻减JSON中实际runtime得到timed-I/O起点，打印与脚本登记起点的差值；
- interval log按时间重叠加权到自然秒，再逐秒求和；补测优先使用单一聚合日志，避免低IOPS被逐job整数日志截成0；
- 正式窗为实际起点后`[15,175)`，分别输出mean/median/CV/P10/P90和四个40秒子窗；
- READ、WRITE分开报告，fio summary只作旁证；
- 每个BS以位置相邻的`C1↔T1`和`C2↔T2`计算两组百分比效应。

L1材料门：两组配对的READ、WRITE四个效应全部同向，最小值`>=5%`，并且对象大小、FUSE拆分、
读放大或在途量至少有一项与机制解释一致。性能端点再差也不删除样本。

若两位置方向不一致，记`INCONCLUSIVE`；若同臂位置漂移或同RUN噪声底已经达到5%，记
`RESOLUTION_INSUFFICIENT`。L1只决定是否值得L2，不签“可生产”“等价”或“确定无效”。

### 3.3 最小机制指标

每格只采以下低开销指标，不预建全栈诊断平台：

- FUSE READ/WRITE次数、总字节和总时延；
- 对象GET/PUT次数、字节、总时延、错误及`object_request_uploading`；
- `used_buffer_size_bytes`、进程CPU/RSS、157 NIC收发；
- fio READ/WRITE带宽、IOPS、clat mean/P95/P99；
- TiKV meta Read/Write qps/延迟和三节点pending compaction；
- Ceph pool bytes/ops/latency、六OSD利用率与时延。

异常时才追加日志、pprof或更细sidecar；不得为本任务开发新的长期采集服务。

## 四、执行步骤与授权停点

### 阶段0：离线Gate 0

1. **测试前通读并确认**：`skills/SYSTEM-SAFETY-SKILL.md`、`skills/TESTING-GUIDE.md`§1.3/§2.2/§3、
   `skills/test-commands-reference.md`§8.3、`skills/EVIDENCE-INTEGRITY-SKILL.md`及
   `TEST-DATA-LIFECYCLE-POLICY.md`。
2. 只复用并参数化：`t05-1-randrw-driver.sh`/analyzer的fio与正式窗逻辑，
   `t04tmp3c-executor.sh`的临时卷身份、挂载和精确destroy逻辑；禁止复制成新编排框架。
3. Gate只覆盖新增路径：64K FUSE生效、B64/B1M/B4M format渲染、128×1GiB layout、平衡矩阵、
   两挂载PID守卫、条件旋钮只能选一个、UUID精确destroy及危险命令扫描。
4. 分析器在05-1有效归档上重放，必须复现已签收正式窗数字并通过起点`±1s/+58s`敏感性检查。
5. Gate检查脚本无明文口令、无`rm -rf`、无pool delete/create、无强制/懒卸载、无模式kill和sudo写。

**停点G0**：回传Gate结果、实际脚本SHA、完整format/layout/destroy计划、容量估算和全部写操作；
用户未授权前禁止format、mount、fio、GC或destroy。本任务预期无sudo写操作。

### 阶段1：inventory、阶段A及三组BlockSize L1

获得一次明确授权后，执行方可在预算内连续完成：

1. 只读inventory及任务外服务/挂载/进程指纹；
2. 阶段A FUSE64代表筛选；
3. 按`M→L→S`逐组执行“create→layout→cooldown→CTTC/平衡矩阵→恢复→精确destroy→恢复”；
4. 每组结束增量持久化新证据，不重复复制COMMON或前组整树；
5. 任一非性能硬门失败立即停止，保留最小必要现场并写`incidents.tsv`。

任务卷format/layout/destroy虽不使用sudo，仍属于环境状态变更，只能执行G0已列明并获授权的精确计划。
不得因脚本不适配而改变META、卷数、BlockSize、测试顺序、pool或清理方式。

**停点G1**：三组原始证据持久化后暂停。执行方只交原始数据、硬门PASS/FAIL和incident；
不算正式效应、不挑轮次、不自主执行阶段C或L2。GPT独立复算并决定是否存在阶段C触发。

### 阶段2：可选一个条件旋钮与收口

只有GPT指明“哪个组、哪个BS、哪个触发指标、唯一参数值”并经用户授权后，才执行阶段C的一个CTTC。
随后无论性能如何都完成：任务挂载graceful卸载、临时卷精确destroy、JuiceFS GC、OSD/TiKV恢复门、
任务外指纹对比、证据持久化与生命周期盘点。

最后按上述skill逐项复核：未删建pool、未动157红线、无任务挂载/进程/卷残留、每次写后恢复完整、
实际统计口径正确、唯一权威证据可复算。任一恢复失败优先按安全事件处理，不得先写性能结论。

## 五、交付物

```text
/mnt/c/SunRise/test/05-1b/<RUN_ID>/
├── run-state.tsv
├── common/{inventory,identity,plans,scripts,commands.sh}
├── groups/{M,L,S}/
│   ├── layout/
│   ├── cells/
│   └── closure/
├── incidents/
├── derived/
├── manifest.sha256
├── persistence.tsv
└── retention.tsv
```

- 正式报告：`doc/perf-report/05-1b-randrw-blocksize-and-bs-coupled-parameter-closure-<DATE>.md`；
- 更新：`doc/deploy-log/results-table.md`和05阶段计划书；
- 报告必须列出`VALIDITY_STATE/LIFECYCLE_STATE/EVIDENCE_ROOT/MANIFEST_PATH/REMOTE_STATUS/`
  `LOCAL_STATUS/INCIDENT_STATUS/ENVIRONMENT_ASSET_STATUS`；
- L1长期保留最小可复算raw、实际脚本/命令、身份、最终分析和报告；审核后精确清理远端RUN目录及
  重复暂存/解压副本，不得清理其他RUN或环境资产。

## 六、通用注意事项与安全红线

1. 统计严格使用实际I/O起点、重叠加权自然秒和全部per-job日志；randrw两向分开，不用summary主判。
2. `direct=1+cache=0`下禁止在157执行全局`drop_caches`；两臂保持同口径。
3. fresh卷必须先真实layout；禁止空洞、`create_on_open`、轮间relayout或文件大小自动修复。
4. 每次fio前检查health，写后执行卷GC并等待Ceph/OSD/TiKV恢复；不得用OSD restart代替恢复。
5. 首轮保留scrub并已证明可污染长矩阵；补测RUN按§0.1生成
   `noscrub/nodeep-scrub`精确设置/恢复计划，只有获得用户对这两个Ceph flag的单独授权后才能执行。
6. 禁止修改157内核、网卡、RoCE、IRQ/NUMA、md0、WekaIO、K8s及任务外路径或进程。
7. 禁止`ceph osd pool delete/create`、`format --force`、强制/懒卸载、模式kill、宽作用域递归删除。
8. 所有环境资产按RUN/META/Name/UUID/PID/starttime精确拥有和恢复；变量为空、相对路径、根路径或
   身份不符立即拒绝。禁止在嵌套SSH命令中传递破坏性路径变量。
9. 任何sudo写操作必须先列出完整命令、节点和目标并获用户确认；本任务默认不需要sudo写。
10. 脚本bug、只读采集和不改变量的路径适配可自主修复并记incident；改变矩阵、判据、卷、pool、
    BlockSize、FUSE、readahead、buffer或Ceph参数前必须停止报告。
11. 失败RUN禁止热改后续跑、补样替换或与有效RUN拼接；根因关闭后才能按生命周期规范压缩事故证据。
12. COMMON每RUN一次、cell增量回传；源/本地SHA、文件数、字节数、归档可读性通过前不得清远端。
13. 任务结束只保留一份权威原始真值；证据文件清理与卷/挂载/进程等环境清理必须分开授权和审计。
14. 先回答主问题再完善工程；任何未触发的条件分支不写脚本、不运行，不为漂亮CI扩大矩阵。

## 七、完成线

同时满足以下条件才能关闭05-1b：

- 阶段A和B按预注册矩阵得到有效或明确受限的L1结果；
- 4K/16K/64K/1M/4M均给出“B256标准值、已测适配值、有限裁决”，256K沿用05-1；
- 条件参数被明确记为“未触发/已筛选/转后续”，没有悬空的自动测试；
- 所有任务卷、挂载和进程精确收口，Ceph/TiKV及任务外指纹恢复；
- 原始证据已持久化并可独立复算，报告和results-table完成更新。
