# 04-6b任务书：端到端容量账与残余调优方向收口

## 日期与状态

> 日期：2026-09-04
>
> 面向：GLM执行；GPT复算与裁决
>
> 状态：`TASKBOOK_READY / SCRIPTS_NOT_READY / ENVIRONMENT_NOT_AUTHORIZED`
>
> 承接：04-6、U141d、04-tmp3、04-1b正式报告。

```text
EVIDENCE_LEVEL=L1_SCREEN
OFFLINE_COMPONENT=L0_CAPACITY_LEDGER
SCREEN_SOURCE=04-6/U141d/04-tmp3/04-1b持久raw + 本RUN五端点ABBA与一次randrw状态回环
SCREEN_CONTINUE=任一候选两次配对均提升>=5%且机制同向；立即收口并新开05做L2
SCREEN_STOP=候选未出现一致材料信号；只签“当前筛选无升级价值”，不签数学无效
SCREEN_HOLD=身份/健康/恢复失败，或决定阶段裁决的容量字段仍不可测
FORMAL_MATRIX=NONE；04-6b不产出参数正式效应量或生产交付结论
ESTIMATED_WALL_CLOCK=离线准备<=90min；环境通常8--12h；12h后不启动新cell，另留2h强制收口

MINIMUM_DECISION_SET=七项容量账 + R8/F1/U300各一个ABBA + randrw一个状态回环
STOP_AFTER_ANSWER=首次发现材料候选即停止后续性能phase；不补全量基线、不现场扩参
MAX_PREP_BUDGET=90min
MAX_EXECUTION_BUDGET=12h性能与必要恢复 + 2h只用于restore/卸载/证据收口

EVIDENCE_ROOT=/mnt/c/SunRise/test/04-6b/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04-6b-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=恢复本RUN持有的scrub flags；graceful卸载任务mount；按manifest逐文件删除任务专属mseqwrite资产并回到O0；既有seqwrite/randrw/只读资产按路径、inode、大小保护；关闭共享GC/compact状态
```

一句话：**把“盘很忙、暂时想不到参数”升级为逐层容量账，同时只筛选尚未真正排除的三个低风险
参数和一个randrw状态缺口；有信号才把高成本正式验证交给05阶段。**

---

## 一、为什么还需要04-6b

04-6已经得到有价值的容量曲线，但还不能直接向领导表述“当前方案几乎无调优空间”：

1. `%util=100`只表示设备一直有请求，不等于带宽或IOPS达到硬件上限；必须把逻辑带宽、对象请求、
   Ceph操作、EC放大、物理盘流量、完成率和排队延迟闭成一张账。
2. 04-6 mseqwrite高并发为`3853.67 MiB/s`，但同binary/交付参数的U141d已有可信
   `4933.11 MiB/s`。不能选择低RUN冒充架构上限。
3. 04-tmp3在不同大块语义下发现`max-readahead=8M`读信号和`max-fuse-io=1M`写信号；它们不能
   外推到七项原始语义，但值得各做一次最小同口径筛选。
4. 04-6 randrw的`64→128→64`低档回落约`8.2%`，且TiKV pending compaction/NVMe等待未回到
   初始状态。必须先区分并发服务平台和运行状态债务。

本任务不尝试证明数学意义上的“所有参数都绝对无效”。它只支持以下有边界的项目结论：

> 在当前硬件、EC4+2/6 OSD、三节点TiKV、exact patched v1.4.1、`cache-size=0`、原七项fio语义，
> 且不改代码、硬件、拓扑、缓存与持久性语义的范围内，端到端容量账已经闭合，剩余可生产参数均未
> 出现值得升级的`>=5%`信号，因此继续盲扫在线参数的预期收益很低。

缓存/writeback和04-1b PG Primary均衡仍须列为“改变路径语义或增加运维成本的技术候选”，不能写成
不存在；它们不属于本任务的当前交付参数。

---

## 二、目标、范围与固定条件

### 2.1 必须回答

唯一阶段裁决问题是：**当前限定架构与原七项语义下，是否仍存在值得进入05正式验证的可生产旋钮；若
不存在，端到端容量与服务墙证据是否足以关闭04阶段。**以下四项都是该裁决所需的组成证据：

1. 七项各自的目标需求、最高可信值、逐层放大、实测服务能力、推导屋顶和目标缺口是多少；
2. 原七项语义下，R8、F1、U300是否出现一致的`>=5%`升级信号；
3. mseqread的完成服务中心能否由既有raw或本RUN最小机制证据定位；
4. randrw清洁起点下是否仍出现并发服务平台，8.2%回落是否得到状态债务的受控支持。

### 2.2 明确不做

- 不重跑七项全量baseline，不重测已闭合的randread/randwrite；
- 不扫参数梯子，不测试R8/F1/U300之外的新参数，不因结果不好临时加轮；
- 不新建、format或destroy卷/pool，不改PG、CRUSH、Primary、OSD/TiKV配置或拓扑；
- 不测试缓存/writeback，不改源码，不做裸盘fio/rados破坏性压测；
- 不把L1观察写成正式效应量；有候选后由05另写L2任务书。

### 2.3 固定条件

| 项 | 冻结值 |
|---|---|
| JuiceFS | `/tmp/juicefs-1.4.1-patched`；期望MD5 `24fae0852051c80ca571cb2f20275d46`，开跑前实探 |
| 基座A | `--max-fuse-io 256K --max-uploads 150 --cache-size 0`，默认readahead |
| Ceph客户端 | 任务私有`ms_async_op_threads=8`；期望配置MD5 `86351c58848c7e4caaa1bbeccb211730` |
| 后端 | 当前6 OSD、EC4+2；三节点TiKV现有拓扑及持久性语义不变 |
| 目标 | 每一读/写方向`6250 MiB/s`；randrw读写分别验收，禁止相加 |
| 正式窗 | 180秒fio实际I/O起点后的`[15,175)`；1秒per-job log重采样 |
| 现有挂载 | `/mnt/juicefs`保持PID/starttime/命令和业务活动不变 |
| 任务挂载 | 只用`/tmp/jfs-t046b-<RUN_ID>-<CELL>`，核META/UUID/exe/PID/starttime |
| 页缓存 | 157及150--152均禁止全局`drop_caches`；各臂对称 |

读测试复用既有seqread/mseqread资产；seqwrite和randrw复用既有测试专用文件。Phase I冻结路径、inode、
大小和文件集合；只读资产再冻结mtime与抽样hash。写负载允许内容/mtime变化，但不得删除、重命名、
改变大小或触碰非测试文件；须先证明没有foreign opener。

mseqwrite一律使用卷内全新的任务专属相对路径
`test_dir/04-6b-<RUN_ID>/mseqwrite/`，不得复用、混入或部分复用既有文件。seed前冻结对象锚`O0`，再按
manifest一次性创建16×4GiB文件；seed不进性能结果，恢复稳定后冻结含资产锚`O1`。Phase B/C每个性能
cell开始前对象数须回到`O1±8192`且PG全active+clean；实际目录必须写入每条B/C命令和manifest。
Phase C结束或B候选早停时，按manifest逐个删除16个文件及精确空目录，经GC与自然idle回到`O0±8192`。
禁止glob、递归删除和用其他文件补齐数量。

---

## 三、七项端到端容量账

### 3.1 计算规则

串行或固定在途路径：

```text
B_max = Q × S / L
```

多级流水线：

```text
logical_roof = min_i(C_i / a_i)
target_demand_i = target_logical_rate × a_i
```

`Q`必须是同窗实际在途量，不能用配置上限；`C_i`是组件完成服务能力，`a_i`是请求数或物理字节
放大。认定服务平台必须同时看到：输入并发/在途增加、完成率不再同比增长、队列或延迟上升、上游
CPU/NIC仍有余量。单独的`%util=100`只能作忙碌佐证。

`capacity-ledger.tsv`每个方向一行，至少包含：

```text
item,direction,semantics,target_MiB_s,target_logical_iops,
best_credible_MiB_s,best_evidence,gap_factor,
fuse_amp,object_amp,ceph_op_amp,tikv_txn_amp,physical_byte_amp,
measured_component_cap,cap_evidence_class,implied_logical_roof,target_to_roof,
queue_or_latency_evidence,client_headroom,remaining_knob,verdict,scope
```

`cap_evidence_class`只允许：

- `SPEC_HARD_LIMIT`：规格或设备硬上限；
- `MEASURED_SERVICE_WALL`：输入增加、完成率平台且排队/延迟上升；
- `SERIAL_PATH_BOUND_IN_TESTED_IMPLEMENTATION`：固定在途量下的端到端周期约束；
- `MEASURED_LOWER_BOUND_ONLY`：只说明曾达到该值，不能当上限；
- `NOT_MEASURED`。

只有前三类能在本任务限定范围内支撑“目标超过当前路径屋顶”；`MEASURED_LOWER_BOUND_ONLY`不能反过来
当上限。

字段不适用写`NA`，缺原始证据写`NOT_MEASURED`，上下界写`LOWER_BOUND/UPPER_BOUND`并附方法。
决定阶段裁决的服务上限若仍为`NOT_MEASURED`，对应项目只能记证据不足。

### 3.2 必须从raw复核的锚点

- seqread：`1432.9 MiB/s`，每256KiB有效输出周期约`174.5 µs`；目标周期约`40 µs`；
- seqwrite：`1555.0 MiB/s`，每4MiB约`2.57 ms`；目标约`0.64 ms`；
- mseqread：04-6的`8→16→8`为`4384→4687→4393 MiB/s`，加倍并发只增约`6.8%`，但限制组件
  尚未闭合；
- mseqwrite：04-6 W02为`3853.67 MiB/s`，最高可信同口径状态锚为U141d `4933.11 MiB/s`，两者
  必须并列为状态容量带，不能平均或只选低值；
- mseqwrite W02逐层约为：JuiceFS PUT `3850.3 MiB/s`→OSD `op_w_in_bytes 3850.7 MiB/s`→
  BlueStore `write_big_bytes 5776.0 MiB/s`→六盘iostat `5793.6 MiB/s`，对应EC最低约`1.5×`；
- W02正式窗16个uploading采样均为`150.0`（达到上限），Little定律隐含平均在途约`149.8`；平均PUT
  约256KiB、JuiceFS PUT平均延迟约`9.72 ms`，与`Q×S/L≈3850 MiB/s`闭合；OSD op_w平均延迟约
  `7.57 ms`，两层不得混用。目标在Q=150时需
  PUT周期约`6.00 ms`；保持W02周期则需Q约243，按U141d高状态隐含约7.60ms周期则需Q约190；
  目标的EC4+2物理写最低需求为`9375 MiB/s`；
- randrw M02为`1756.77/1757.03 MiB/s`，每向到目标约需`3.56×`。目标层需求须同时按M01清洁锚
  和M02同窗放大投影并列：前者约GET/PUT `28.5K/28.1K qps`、Ceph op_r/op_w
  `57.1K/28.1K qps`、六盘联合物理读/写`5.7/10.1 GiB/s`；后者约
  `29.37K/28.93K`、`58.84K/32.92K`和`7.47/10.54 GiB/s`。这些是目标需求投影，不是实测目标值；
- randwrite：正式状态约`10.3K--12.7K` meta Write/s，目标逻辑256KiB写约`25K/s`；另有单次
  post-GC 60秒`15.9K/s`瞬时观测峰值，但它不是正式fresh arm或容量上界，台账标
  `OBSERVATION_ONLY/NOT_MEASURED_UPPER_BOUND`。换算必须列`meta Write/FUSE write`放大；
- randread：04-1b Primary均衡`+13.67%`只登记为特定测试Pool工程信号；无八轮矩阵、缺同窗op_r，
  不纳入当前可维护生产基线。

每个数字必须在`source-map.tsv`记录`source_path、field、window、formula`。历史最高可信值与本RUN
不同时并列报告，不得挑RUN。

---

## 四、最小执行矩阵

Phase A→B→C→D依次执行。任一phase出现材料候选，先恢复scrub和任务mount、持久化证据，再停止后续
性能phase并转05；不得为了“跑完整”继续。

### Phase A：R8及mseqread机制

唯一变量：A只增加`--max-readahead 8M`，`max-fuse-io`仍为256K。四个独立mount：

| Cell | 臂 | 同mount独立端点（执行顺序） |
|---|---|---|
| R01 | A | `R01-SR` seqread → `R01-MSR` mseqread |
| R02 | R8 | `R02-MSR` mseqread → `R02-SR` seqread |
| R03 | R8 | `R03-SR` seqread → `R03-MSR` mseqread |
| R04 | A | `R04-MSR` mseqread → `R04-SR` seqread |

fio逐字沿用V4：seqread=`read,bs=256k,size=32G,numjobs=1,psync,iodepth=1,direct=1`；
mseqread=`read,bs=256k,size=4G,numjobs=16,psync,iodepth=1,direct=1`；均180秒time_based。

`max-readahead`会改变旧读探针，禁止ns/B detect-and-replace或按性能重挂。逐mount记录ns/B、
active-worker数/均衡度和挂载序位，只作协变量。报告历史最坏`-30%`档位敏感性，但L1只决定是否升级，
不借压力测试签正式无效。

Phase 0优先从04-6 frozen raw补mseqread服务中心。若仍缺决定性字段且R8没有候选信号，只允许追加一个
基座A机制mount上的`N8→N16→N8`（各180秒），采FUSE/buffer、GET、messenger/OSD内存读完成率及
排队。只有同时满足以下条件，才可签`MSEQREAD_SERVICE_WALL_IN_TESTED_RANGE`：两次N8锚的逻辑带宽
及主完成率差异均`<=3%`；N16相对两次N8均值的逻辑带宽增幅`<=20%`，且至少一个明确命名的候选服务
中心完成率增幅`<=20%`、对应延迟或队列P50/P95升至`>=1.5×`。同时须排除其他先到顶项：157总CPU
低于可用CPU容量的80%、JuiceFS进程CPU低于其cpuset容量的80%、任一方向NIC低于100GbE线速的80%，
CPU/memory/io PSI avg10均`<10%`；若候选本身是FUSE/worker，则只排除其上游资源。单独`%util=100`不
得通过此门。仍无法定位就签`INCONCLUSIVE_COMPONENT`，不再扫并发点。

### Phase B：F1在原4MiB写语义下的筛选

唯一变量：`--max-fuse-io 256K→1M`；uploads=150、cache=0、默认readahead。四个独立mount：

| Cell | 臂 | 同mount独立端点（执行顺序） |
|---|---|---|
| W01 | A | `W01-SW` seqwrite → `W01-MSW` mseqwrite |
| W02 | F1 | `W02-MSW` mseqwrite → `W02-SW` seqwrite |
| W03 | F1 | `W03-SW` seqwrite → `W03-MSW` mseqwrite |
| W04 | A | `W04-MSW` mseqwrite → `W04-SW` seqwrite |

seqwrite沿用V4：`write,bs=4M,size=32G,numjobs=1,psync,iodepth=1,direct=1,end_fsync=1,
time_based,runtime=180s`；mseqwrite为相同参数、`size=4G,numjobs=16`。block内两项之间只采快照，
完整恢复放在block末。每个子端点使用独立raw/log目录，禁止把同cell两项当重复样本。记录挂载档位
协变量但不重挂删样。

任一写项出现材料信号，只取得“F1候选”资格；05必须补另一写项以及randwrite/randrw非劣门后才可
考虑交付。

### Phase C：U300上传槽位筛选

唯一变量：`--max-uploads 150→300`；其他参数保持A。四个独立mount，顺序
`U01(U150)→U02(U300)→U03(U300)→U04(U150)`；每cell只跑V4 mseqwrite 180秒，每个端点使用
独立raw/log目录。

除带宽外强制保存uploading、PUT完成率/延迟、OSD op_w完成率/延迟、BlueStore物理写和六盘iostat。
机制阈值冻结为：

- U150 uploading P95 `<135`且达到135的时间占比`<5%`：150槽位未绑定；
- 若U150已绑定，U300的uploading P95须同时提高`>=10%`且绝对增加`>=15`才算释放槽位；
- 槽位释放后，若逻辑带宽、PUT和OSD op_w完成率提升均`<3%`，同时PUT/OSD延迟或队列P95至少一项
  增加`>=10%`：支持“后端服务率而非上传槽位限制”。

本phase不制造fresh/old生命周期对照。U150两个样本与04-6、U141d并列成状态容量带，不为复现漂亮
档位追加轮次。

Phase B结束后保留任务mseqwrite资产供Phase C复用；若B提前发现候选则立即精确删除。Phase C无论
结果如何都在收口时按manifest逐个删除这16个文件并完成对象回归，之后才允许进入Phase D。

### Phase D：randrw状态回环

固定一个A mount，不改参数；fio逐字沿用04-6 M组：
`randrw,bs=256k,libaio,iodepth=128,direct=1,time_based,runtime=180s`。

| Cell | 并发 | 起点 | 用途 |
|---|---:|---|---|
| C1 | 64 | `FULL_CLEAN` | 前清洁低档锚 |
| H | 128 | `FULL_CLEAN` | 原验收并发/债务产生器 |
| D | 64 | `FAST_OBJECT_RECOVERED` | 对象回归但运行债务保留 |
| C2 | 64 | `FULL_CLEAN` | 后清洁低档锚 |

固定状态流为
`PRE_FULL_CLEAN→C1→FULL_CLEAN→H→FAST_OBJECT_RECOVERY→D→FULL_CLEAN→C2→FINAL_RECOVERY`；
终末恢复不再为下游样本主动触发OSD compact，只做GC、对象回归和自然idle收口。

进入C1前冻结本phase对象锚`D_OBASE`及300秒PRE P95。`FAST_OBJECT_RECOVERY`只要求对象数回到
`D_OBASE±8192`、PG全active+clean且不再单调变化，明确不等待TiKV pending回落，也不执行主动OSD
compact。H后只有满足以下预注册条件才标`DIRTY_AFTER_H`：至少两个TiKV节点各自满足
`scheduler pending>=256MiB`或`engine pending>=4GiB`，并且这些节点中至少一个还满足compaction flow
`>=max(2×PRE P95,32MiB/s)`、NVMe await `>=max(2×PRE P95,2ms)`或aqu-sz
`>=max(2×PRE P95,0.20)`三者之一。否则标`POST_H_STATE_NOT_DIRTY`，它是证据缺口，不得解释成状态
债务不存在。

本phase只有一个受控周期。04-6 `M01→M02→M03`作为“高负载后低档同向回落”的独立历史观察；本RUN
补保留债务/清除债务干预。两者同向时最多签
`SUPPORTED_IN_ONE_CONTROLLED_CYCLE_WITH_HISTORICAL_REPLICATION`，不得写成普遍因果效应量。

READ和WRITE分别判定：

1. C1/C2带宽、对应GET或PUT/FUSE放大差异均`<=3%`，清洁锚才有效；
2. 已取得`DIRTY_AFTER_H`时，D相对`mean(C1,C2)`下降`>=5%`，至少两个TiKV节点pending/compaction/
   NVMe队列同向恶化，且C2回到C1的`±3%`，对应方向签
   `STATE_DEBT_SUPPORTED_IN_ONE_CONTROLLED_CYCLE`；若D在均值`±3%`内且C2有效，签
   `STATE_DEBT_NOT_SUPPORTED_WITH_DIRTY_STATE`；落在二者之间或C2不回归则签`INCONCLUSIVE_STATE`；
3. H相对清洁低档并发加倍时，READ和WRITE须分别满足：逻辑带宽及对应完成服务率增长均`<=20%`；
   明确命名的候选服务中心P50/P95延迟或队列升至`>=1.5×`；该中心完成率达到历史同口径上限的
   `±10%`，或设备持续忙碌且物理吞吐/IOPS增长也`<=20%`。同时157总CPU低于可用容量80%、JuiceFS
   进程CPU低于其cpuset容量80%、任一方向NIC低于100GbE线速80%，CPU/memory/io PSI avg10均
   `<10%`，才签`RANDRW_SERVICE_WALL_IN_TESTED_RANGE`。单独`%util=100`不得通过。

若高负载后未形成预注册dirty状态，D保留并标`POST_H_STATE_NOT_DIRTY`，不补压、不加第五个cell。

---

## 五、统一判据与恢复合同

### 5.1 L1候选判据

每个子端点必须有独立raw/log目录，按以下冻结公式计算带宽配对，禁止把同cell的两种workload当作
重复样本：

- R8：对`*=SR、MSR`分别计算`P1=R02-*/R01-*-1`、`P2=R03-*/R04-*-1`；
- F1：对`*=SW、MSW`分别计算`P1=W02-*/W01-*-1`、`P2=W03-*/W04-*-1`；
- U300：计算`P1=U02/U01-1`、`P2=U03/U04-1`。

每个端点的描述性点估计为`sqrt((1+P1)(1+P2))-1`，同时报告基座两点、候选两点极差及挂载档位
协变量。

- `P1>=5%`且`P2>=5%`，完成率/放大/排队机制同向：`SCREEN_CONTINUE_OPEN_05`；
- 未满足：`SCREEN_STOP_NO_CONSISTENT_UPGRADE_SIGNAL`；
- 身份、健康、采集、起点或恢复失败：`EVIDENCE_INVALID`；
- mseqread组件仍不可定位：另记`INCONCLUSIVE_COMPONENT`。

不计算或伪造95% CI，不把四点L1写成“参数正式无收益”。性能低、CV高、W4/W1下降和候选无收益都是
结果，不能删样、换RUN挑好值或临时补轮。

### 5.2 写起点与恢复

Phase B、C、D在首次性能cell前达到初始FULL_CLEAN，并采连续300秒、1秒粒度idle PRE；metric/label
写入`source-map.tsv`。`FULL_CLEAN`是状态判据，不等于每次都必须执行主动compact；环境自然满足时
不得为了用完预算而compact。缺失/NaN不得按0。恢复门连续三次、间隔15秒同时满足：

- 对象数回到phase锚点`±8192`且不再单调变化，PG全active+clean；
- 六OSD `compact_running=0`且`compact_queue_len=0`；
- TiKV scheduler pending不高于`max(PRE P95×1.25,64MiB)`，engine pending不高于
  `max(PRE P95×1.25,1GiB)`，无新增stall/slowdown/rate-limit；
- 每节点compaction flow不高于`max(PRE P95×1.25,16MiB/s)`，TiKV NVMe await不高于
  `max(PRE P95×1.25,1ms)`，aqu-sz不高于`max(PRE P95×1.25,0.10)`。

FULL_CLEAN复用04-6已签收的`juicefs gc --compact --delete --threads 32`、对象回归、经授权逐OSD compact
及cooldown合同，最长60分钟；FAST只执行一次相同GC并等对象/PG回归，禁止主动OSD compact和等待
TiKV debt清零，最长20分钟。GC和主动OSD compact是共享卷/集群状态变更，Phase I必须列出精确命令、
次数和时点，获用户授权后才可执行。

主动OSD compact的时点和预算按边界唯一归属，不得重复计算：

- Phase B每OSD最多4次，只能用于seed后的初始门，以及W01、W02、W03之后；
- W04到Phase C的边界恢复计入Phase C初始门；Phase C每OSD最多4次，只能用于该初始门，以及U01、
  U02、U03之后；
- U04后的任务资产删除与Phase D边界恢复计入Phase D初始门；Phase D每OSD最多3次，只能用于该初始
  门、C1之后和D之后；H之后只允许FAST，不得compact；
- W04或U04后若候选早停，以及C2后的终末恢复，只做精确删除（如适用）、GC/对象回归和自然idle，
  不主动compact；若仍不满足最终健康门则如实收口并报告，不扩增授权。

任一恢复超时即停止该phase，不用非等价起点换进度，也不得因尚有额度而重复执行。

### 5.3 非性能有效性门

- binary/META/UUID/mount PID/starttime/exe及参数逐字一致，既有`/mnt/juicefs`身份不变；
- manifest、fio `rc=0/error=0`、全部per-job log和实际I/O窗齐全，采集覆盖`>=90%`；
- 正式窗无scrub/deep-scrub、recovery/backfill、foreign fio或异常业务负载；
- Ceph/PG、TiKV、NIC健康，写后与最终恢复合同通过。

任一失败则对应phase无效并停止，不允许降门继续。

---

## 六、阶段裁决

```text
if 任一[R8-seqread,R8-mseqread,F1-seqwrite,F1-mseqwrite,U300-mseqwrite]
   == VALID+SCREEN_CONTINUE_OPEN_05:
    STAGE_DECISION=STAGE04_CLOSE_OPEN_STAGE05
elif 七项容量账无决定性NOT_MEASURED
     and 上述五个端点逐项均为VALID+SCREEN_STOP_NO_CONSISTENT_UPGRADE_SIGNAL
     and mseqread == MSEQREAD_SERVICE_WALL_IN_TESTED_RANGE
     and randrw READ、WRITE逐向均有有效清洁锚和RANDRW_SERVICE_WALL_IN_TESTED_RANGE
     and randrw READ、WRITE逐向的state_verdict均属于
         [STATE_DEBT_SUPPORTED_IN_ONE_CONTROLLED_CYCLE,
          STATE_DEBT_NOT_SUPPORTED_WITH_DIRTY_STATE]
     and 旋钮台账无UNKNOWN生产安全方向:
    STAGE_DECISION=STAGE04_CLOSE_NO_ACTIONABLE_PRODUCTION_KNOB_GE5_IN_SCREENED_SCOPE
else:
    STAGE_DECISION=STAGE04_CONTINUE_WITH_EXPLICIT_EVIDENCE_GAP
```

任一端点`EVIDENCE_INVALID`、`INCONCLUSIVE_COMPONENT`、`INCONCLUSIVE_STATE`或
`POST_H_STATE_NOT_DIRTY`都必须进入第三分支，禁止被phase汇总值吞掉。

“无UNKNOWN”要求每个旋钮都有：历史严格负证据、本任务L1无升级信号、telemetry证明上限未绑定，或明确
属于代码/硬件/拓扑/缓存/持久性语义变化之一。不得用“暂时没想到”填充。

第二分支只能表达“当前筛选范围继续投入参数调优性价比低”，不能写“数学上绝对无调优空间”。

---

## 七、执行、授权与停止点

### 阶段0：离线Gate 0

1. 通读`skills/SYSTEM-SAFETY-SKILL.md`、`skills/TESTING-GUIDE.md` §1.3/§2.2/§3、
   `skills/test-commands-reference.md` §8.3、`skills/EVIDENCE-INTEGRITY-SKILL.md`、
   `skills/LONG-RUNNING-TEST-SKILL.md`和本任务书，输出ACK。
2. 先从04-6/U141d/04-tmp3/04-1b持久raw生成容量账草案和`source-map.tsv`，复核§3.2全部数字；
   容量账若已回答某一在线phase的问题，可建议跳过，但须由GPT裁决，执行方不得自行删phase。
3. 脚本只复用`t04-6-capacity-*`、`t04tmp3-*`、`u141d-scrub-control.sh`和
   `FULLBASELINE/probe/env-snapshot.sh`；最多新增一个薄driver和一个容量账分析器。
4. Gate只覆盖新增路径、参数逐字合同、正式窗、读写分向、错误码、恢复所有权、明文口令、宽删除、
   reboot/service/network/kernel/block-device及全局drop_caches扫描。
5. 准备超过90分钟或连续两次确定性脚本bug时停止编码，由负责人删减/接管，不上环境试错。

**停点1：** GPT签收Gate 0和容量账草案后，才做只读inventory。

### 阶段I：只读inventory与一次授权计划

6. 只读核对157、150--152业务指纹、binary/META/UUID、挂载/文件资产、Ceph/TiKV健康、设备映射、
   外来负载和空间；不得mount、fio、GC或改flags。
7. 输出全部任务mount/umount、fio、seed/精确删除、GC、逐OSD compact、scrub pause/restore命令，
   以及每phase时限、失败恢复顺序和sudo清单。

**停点2（唯一环境授权停点）：** 用户审阅完整计划后一次性授权；未授权不得进入阶段II。

### 阶段II：连续执行与收口

8. A/B/C/D各建独立state-driven scrub lease，最长分别2/4/3/3小时。保存原flags，仅恢复本RUN拥有的
   变化；phase完成、失败或候选早停时先restore，再进入下一phase。不得把lease合成连续12小时暂停。
9. phase内部连续执行，不逐cell停报。机器只按§5输出`CONTINUE/STOP`；执行方不得改矩阵、阈值、资产
   或下架构结论。到12小时禁止启动新cell，剩余2小时只做恢复、卸载和证据收口。
10. 成功/早停时graceful卸载任务mount并按manifest清本任务mseqwrite；非性能门失败时先恢复全局flags，
    再保留任务局部现场供只读归因。恢复失败是安全事件，优先于性能证据。
11. COMMON每RUN只回传一次，cell仅增量回传。持久副本、manifest/SHA256、文件数和可读性全部通过后
    才清远端最后一份；GPT独立生成capacity/knob ledger、正式报告并更新计划/status/results-table。
12. 收口前再次按上述skills复核157业务保护、全局状态所有权、证据真实性和精确清理合规；复核未通过
    不得宣告任务完成。

---

## 八、sudo与系统安全

本任务当前**没有环境执行授权**。预计常规sudo写面仅为157上的状态驱动scrub控制：

```bash
sudo ceph osd set noscrub
sudo ceph osd set nodeep-scrub
sudo ceph osd unset noscrub
sudo ceph osd unset nodeep-scrub
```

原flags已存在时不得无条件unset。lease期间只允许health-check key=`OSDMAP_FLAGS`且内容仅为本RUN拥有
的上述flags；必须同时6/6 OSD up/in、全部PG active+clean，无scrubbing/deep/recovery/backfill/
peering/inconsistent/repair。其他WARN立即停止并restore。暂停巡检会延后潜在错误发现；restore后可能
集中补做scrub，必须等环境重新稳定再继续。

主动OSD compact若需要，Phase I须把osd.0--osd.5的精确命令、次数和时点单独列入授权；任务书本身不
预授权。禁止隐含sudo。

硬红线：

- 157上的WekaIO/K8s及其他业务必须持续运行；禁止改内核、网卡、RoCE、md0或WekaIO路径；
- 禁止reboot、service/systemctl restart/stop、模式kill、lazy/force umount、全局drop_caches；
- 禁止修改系统`ceph.conf`、Pool/PG/CRUSH/Primary、OSD/TiKV配置和块设备；
- 禁止pool create/delete、JuiceFS format/destroy、裸盘fio、`rm -rf`、通配符删除和递归清理；
- 身份、业务PID、健康、路径或恢复异常立即停止，保留证据并报告。

脚本解析/兼容和采集字段可自主修复，但须先记incident并重过变更路径Gate；改变变量、矩阵、资产、
清理或全局状态必须停止等待确认。

---

## 九、证据与完成定义

唯一权威目录：

```text
/mnt/c/SunRise/test/04-6b/<RUN_ID>/
├── run-state.tsv
├── common/{inventory,env,scripts,commands.sh,source-map.tsv}
├── cells/<CELL_ID>/
├── recovery/
├── incidents/incidents.tsv
├── derived/{capacity-ledger.tsv,knob-ledger.tsv,phase-verdicts.tsv}
├── reports/
├── manifest.sha256
├── persistence.tsv
└── retention.tsv
```

最低证据为fio原文/per-job log、实际脚本与命令、时间身份、JuiceFS/OSD/TiKV/iostat/NIC同窗raw、
health/恢复门和incident账本。原始文件进入manifest后不可覆盖；失败重试用新attempt目录或RUN_ID。
按`TEST-DATA-LIFECYCLE-POLICY.md`只保留一个长期原始真值，不反复搬运整树。

正式报告：

```text
doc/perf-report/04-6b-end-to-end-capacity-and-residual-tuning-closure-<DATE>.md
```

完成必须同时满足：

1. 七项容量账逐数字可追溯，使用最高可信同口径值，未把低RUN或100% util当硬上限；
2. 已执行phase的矩阵和非性能门完整，无动态补轮、性能删样或挑RUN；
3. 五个参数/workload端点各有独立有效的L1升级/停止状态，mseqread与randrw缺口按预注册数值边界
   裁决，任何invalid/inconclusive均未被汇总隐藏；
4. scrub、任务mount、任务文件、对象/健康和157业务指纹精确恢复；
5. 持久证据、manifest、实际命令、GPT复算和正式报告闭合。

## 十、修订记录

| 日期 | 修订 |
|---|---|
| 2026-09-04 | 初版：纠正以100% util和mseqwrite低RUN冒充硬上限的问题；建立七项容量账，最小筛选R8/F1/U300，并补randrw状态回环。按精简原则只做L0+L1，材料候选另开05。 |
