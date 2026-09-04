# 04-6任务书：多流容量曲线闭环与04阶段最终裁决

## 日期与状态

> 日期：2026-09-03
>
> 状态：`TASKBOOK_READY / SCRIPTS_GATE0_PASS / ENVIRONMENT_AUTHORIZED_20260903`
>
> 定位：04阶段最后一份主线任务书；只做诊断，不在本任务内试新参数。

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=03-17d/03-17e/03-19已闭合曲线 + 本RUN三组最小并发回环
ITEM_STATES=ACTIONABLE_TUNING_FOUND | ARCHITECTURE_LIMITED_IN_TESTED_RANGE | INCONCLUSIVE_CONTINUE_DIAGNOSIS
STAGE_DECISIONS=STAGE04_CLOSE_OPEN_STAGE05 | STAGE04_CLOSE_ARCHITECTURE_LIMITED_IN_TESTED_RANGE | STAGE04_CONTINUE_DIAGNOSIS
SCREEN_CONTINUE=发现一个满足§六全部条件的可生产调优候选，关闭04并新开05
SCREEN_STOP=所有项目均闭合到当前语义下的架构/服务率墙，且不存在未排除的相关生产旋钮
SCREEN_HOLD=任一关键项目仍为部分扩展、机制指标不足或存在尚未验证的相关旋钮
FORMAL_MATRIX=NONE_IN_04-6；05阶段按唯一候选另行冻结因果矩阵
ESTIMATED_WALL_CLOCK=脚本与离线Gate≤90min；环境执行通常6--8h、硬上限10h

MINIMUM_DECISION_SET=mseqread 8→16→8、mseqwrite 8→16→8、randrw 64→128→64；不动态补性能点
STOP_AFTER_ANSWER=三组曲线和机制归因完成后立即作三态裁决；不追加参数臂、不重跑全量基线
MAX_PREP_BUDGET=90min
MAX_EXECUTION_BUDGET=10h（含写后对象回归与最终恢复）

EVIDENCE_ROOT=/mnt/c/SunRise/test/04-6/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04-6-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_PERSISTENCE_PASS
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=不新建卷/pool/全量layout；W组一次性seed的16×4GiB文件须精确删除并回到pre-seed对象起点
```

---

## 一、唯一问题与结论边界

本任务只回答：

> 在当前硬件、拓扑、exact patched v1.4.1、无本地缓存和原验收语义下，现有证据较弱的多流项目
> 是已经受当前架构/共享服务率限制，还是暴露出一个**位置明确、可由现有生产配置低风险改变、
> 预期材料收益不少于5%**的新瓶颈？若两者均无法由证据闭合，必须明确保留为证据不足。

04-6不是“证明所有项目都达到数学架构极限”。它要证明的是：在当前硬件、拓扑、实现、无缓存
和固定测试语义下，剩余缺口能否由现有安全配置弥补。最终只允许以下三态之一：

| 裁决 | 条件 | 后续动作 |
|---|---|---|
| `STAGE04_CLOSE_OPEN_STAGE05` | 至少一个候选满足§六全部条件 | 04结束；新建05阶段，只验证最高优先级候选 |
| `STAGE04_CLOSE_ARCHITECTURE_LIMITED_IN_TESTED_RANGE` | 所有未达标项目均完成§六的架构闭环，且没有可生产候选 | 04结束；记录只有代码、硬件、拓扑、缓存或测试语义变化才能继续提升 |
| `STAGE04_CONTINUE_DIAGNOSIS` | 任一影响裁决的组仍为部分扩展、漂移超门、机制缺失或存在未排除旋钮 | 不得宣告调优结束；只允许另立一个最小定点诊断 |

阶段级裁决顺序固定为：

```text
if 任一项目 == ACTIONABLE_TUNING_FOUND:
    STAGE04_CLOSE_OPEN_STAGE05
elif 所有未达标项目 == ARCHITECTURE_LIMITED_IN_TESTED_RANGE:
    STAGE04_CLOSE_ARCHITECTURE_LIMITED_IN_TESTED_RANGE
else:
    STAGE04_CONTINUE_DIAGNOSIS
```

`STAGE04_CLOSE_ARCHITECTURE_LIMITED_IN_TESTED_RANGE`只能表述为“当前硬件、拓扑、实现、测试语义和
已测并发范围内，相关服务平台已经闭合且现有安全旋钮已排除”，不得扩大成跨架构的数学绝对上限。
不能只因为“暂时想不到参数”就签该状态；只存在源码、硬件、拓扑、缓存/持久性语义或测试并发变化
方向时，才可闭合并登记到阶段外TODO。

---

## 二、为什么只补这三组

已有证据不再重跑：

| 项目 | 已有闭环证据 | 本任务处置 |
|---|---|---|
| seqread | 单流`psync/iodepth=1`目标需要约`40 µs/256KiB`，当前有效输出周期约`174.5 µs`；无预读观测周期约`1.46 ms` | 不重跑；作为固定语义下端到端延迟强约束，但现有数据不是逐层延迟分解，不宣称数学下界 |
| randread | 64→128并发仅`+10.4%`，延迟近线性上升；双挂载也收敛到约`6.1 GiB/s` | 不重跑；当前Ceph/OSD服务墙已闭合 |
| randwrite | 128→256 inode主口径仅约`+10%--13%`，TiKV同步事务延迟及compaction debt同步上升 | 不重跑；当前TiKV共享服务墙已闭合 |
| seqwrite | 单流仅约`1555 MiB/s`，而16流约`4933 MiB/s`；已知聚合后端高于单流，但限制层未完全归因 | 用mseqwrite 8↔16曲线补充，不单独增加一轮写测试 |
| mseqread | 16流约`5259.6 MiB/s`，且约93%命中客户端buffer；后端墙不能由当前点直接推出 | 补8↔16；若仍由buffer主导，归因对象只能是客户端/FUSE/buffer路径，不能写成Ceph后端墙 |
| mseqwrite | 只有16流端点，缺并发扩展效率 | 补8↔16 |
| randrw | 只有128-job端点及ra0负结果，缺半并发到原并发的服务曲线 | 补64↔128 |

`04-2/04-3a/04-3b`用于拆分fresh、元数据规模与region因素，本身不产生现成生产参数；
`04-tmp2b`改变为缓存/writeback方案；`04-tmp3`改变为竞品大块口径。它们均不阻塞04-6的无缓存调优
裁决，保留为按业务需求触发的阶段外专项。

---

## 三、固定条件与最小矩阵

### 3.1 固定条件

- binary：`/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`；
- mount：`--max-fuse-io 256K --max-uploads 150 --cache-size 0`，默认readahead；
- Ceph客户端私有配置：`ms_async_op_threads=8`，MD5固定为`86351c58848c7e4caaa1bbeccb211730`；
  系统`ceph.conf`不得修改；
- 复用当前`rw_test` 128×1GiB和`mseqread` 16×4GiB固定资产；**不format、不跑全量layout、不建卷、
  不建pool、不改PG**；
- Phase I实探确认既有`/mnt/juicefs`只有3个`msgr-worker`，不满足交付基线，因此**保持该挂载不动**，
  使用上述私有配置把同一META/UUID非特权地第二次挂载到`/tmp/jfs-t046-<RUN_ID>`；同一专属mount
  PID/starttime/exe/META/UUID完成全矩阵，末尾只做graceful umount并精确`rmdir`；若身份无法确认则停止；
- 本任务不在157或150--152任何节点执行全局`drop_caches`；它不能重置OSD/TiKV内部状态，且会额外扰动
  同机业务。以`direct=1 + cache-size=0`、完全对称cell和低并发回环检查漂移；
- phase内可按既有`s04/u141d`合同临时设置`noscrub + nodeep-scrub`，但必须先单独列出写命令并获用户
  授权，使用状态所有权文件，矩阵后立即精确恢复；未获授权则不得开长矩阵。

### 3.2 三组最小回环

| 组 | 顺序 | fio语义 | 文件资产 |
|---|---|---|---|
| R：mseqread | `R01=N8 → R02=N16 → R03=N8` | `read, bs=256k, psync, iodepth=1, direct=1, allow_file_create=0, runtime=180s` | 既有`mseqread.0.0...15.0` |
| W：mseqwrite | `W01=N8 → W02=N16 → W03=N8` | `write, bs=4M, psync, iodepth=1, end_fsync=1, direct=1, allow_file_create=0, runtime=180s` | 本任务一次性seed的`mseqwrite.0.0...15.0` |
| M：randrw | `M01=N64 → M02=N128 → M03=N64` | `randrw, bs=256k, libaio, iodepth=128, direct=1, allow_file_create=0, runtime=180s` | 既有`rw_test.0.0...127.0` |

文件映射冻结为：N8固定使用编号0--7，N16固定使用0--15；N64固定使用0--63，N128固定使用0--127。
每个cell必须在命令证据中展开实际文件清单/编号、挂载实例和完整fio参数；randrw必须保存并分别判读
READ与WRITE方向，不能使用两向相加值。

禁止动态加轮。只有非性能门失败时允许**至多一次**针对失败门的修复RUN；性能不好、CV高、方向不漂亮
均不是补样理由。写cell之间使用本任务冻结的同一“JuiceFS compact+delete、逐OSD compact、对象回归”
恢复语义；总墙钟达到
10小时仍未完成时停止；已完成组独立保留，未闭合组记`INCONCLUSIVE_CONTINUE_DIAGNOSIS`，不继续堆轮次。

### 3.3 mseqwrite一次性seed与恢复

U141d的正式收尾会清空`test_dir/mseqwrite`，因此不得再假设16个写文件已经存在。Phase I若确认该目录
精确为空，则在R组结束、W组开始前只执行一次V4 prep语义：

```bash
fio --name=mseqwrite --directory=/mnt/juicefs/test_dir/mseqwrite/ \
  --rw=write --bs=4M --size=4G --numjobs=16 --direct=1 --group_reporting
```

该prep不进入性能结果。创建后必须确认`mseqwrite.0.0`至`mseqwrite.15.0`各为`4294967296` bytes，
并确认mseqread、rw_test清单未变。为避免time-based覆盖写留下大量pending-delete对象，使后续cell从
不同物理状态起跑，正式R组前先对既有卷执行一次
`juicefs gc --compact --delete --threads 32`并冻结归一化对象起点`O0`；seed后再执行一次相同归一化，
直至六OSD `compact_running=0`且`compact_queue_len=0`、三TiKV pending compaction连续三次为0、
Ceph objects/stored连续三次稳定，才冻结W组对象起点`O1`。PRE/seed阶段均不得触发额外OSD compact；
若30分钟内不能回稳则停止。该归一化会改变测试资产的物理对象组织，但不改变路径、inode、大小和内容；
因此本任务只对归一化后的同RUN容量曲线负责，不把绝对值与归一化前历史值混作同口径效应量。

W01/W02后保留这16个文件，通过同一
`juicefs gc --compact --delete --threads 32`、已批准的逐OSD compact和对象稳定门回到`O1±8192`。
W03后按manifest逐个删除这16个精确路径，再运行一次有完整日志的
`juicefs gc --delete --threads 32`、本cell已批准的逐OSD compact和回稳门，回到pre-seed对象起点
`O0±8192`后才允许进入M组。禁止glob删除、目录递归删除或触碰mseqread/rw_test。

M01--M03每轮覆盖写后也使用上述compact+delete归一化，回到`O0±8192`才进入下一cell；M01/M02
各执行一次逐OSD compact，终末M03不再触发无下游样本需要的强制OSD compact，只以自然idle门收口。
仅做`gc --compact`而不带`--delete`不能作为对象回归手段：20260903首次执行已证实
其会留下约188.7万pending-delete对象并使对象数稳定偏离锚点；该RUN已安全中止、恢复scrub并精确清理。

---

## 四、最小证据与有效性门

### 4.1 每个cell必须保存

1. fio原始输出、per-job带宽/1秒clat均值log、实际timed-I/O起点及`[15,175)`正式窗；
2. 带宽、P50/P95/P99完成延迟、秒级CV、W1--W4及`W4/W1`；
3. 157客户端CPU/run queue、NIC吞吐、JuiceFS `.stats` 前后差分；至少包括buffer命中/未命中、
   GET/PUT服务量、实际在飞请求或可替代队列指标；
4. 六OSD吞吐/操作数、CPU、块设备util/await和可取得的op latency；
5. 写组额外保存TiKV scheduler/prewrite/storage async/Raft sync、pending compaction、CPU与NVMe指标；
6. cell前后Ceph health/PG、fio外来进程、binary/META/UUID/mount PID身份和对象数。

采集现有可访问接口即可，禁止为了补一个sidecar修改OSD/TiKV配置、重启服务或触碰admin socket权限。
机制指标缺失不删除性能样本，但该组只能记`INCONCLUSIVE_CONTINUE_DIAGNOSIS`：既不能据此打开05阶段，
也不能签“架构受限”。

### 4.2 只有以下非性能条件能判样本无效

- 身份、文件数量/大小或命令语义不一致；
- fio非零退出、I/O error、per-job log不全或采样覆盖不足；
- 正式I/O窗与scrub/recovery/backfill/foreign fio重叠；
- Ceph/PG或TiKV健康异常；
- 写前起点或写后对象/compaction恢复合同失败。
- mseqwrite seed文件数量/大小、固定文件映射、`O0/O1`或最终精确删除回归合同失败。

带宽、延迟、CV和`W4/W1`无论多差都是结果，不得作为删样门。

### 4.3 每个项目的固定闭环字段

最终结果表必须逐项填写，不能只写一段笼统瓶颈描述：

```text
理论线性增量及目标所需服务量
实测增量、scale_ratio与scale_eff
P50/P95/P99延迟变化
同窗共享组件、完成服务率与排队指标
该组件是否满足饱和定义
已测试/排除的现有生产旋钮及证据索引
若继续提升必须改变的代码、硬件、拓扑、缓存或测试语义
```

带宽、服务率、队列和资源指标按`[15,175)`同窗计算。fio原生P50/P95/P99是整轮180秒汇总，
不是严格裁剪后的同窗分位数；其跨cell比值只作近似佐证，并与正式窗clat均值log交叉检查。
若架构判定依赖恰好跨过`1.60×`阈值（上下10%以内），必须记为证据不足，不得冒充同窗分位数。

一个组件只有在上述同窗指标与整轮延迟佐证同时满足以下条件，才记为“饱和”：

1. 高并发相对低并发的**完成服务率**增长不超过15%，而对应P50延迟或队列指标增长至少1.60倍；
2. 存在该组件自身的硬证据：设备util或CPU/worker占用正式窗P50达到90%，或完成服务率复现历史已闭合
   上限的±10%；
3. 前后低并发锚点方向一致，且健康、身份、scrub/recovery和外来负载门均通过。

若缺少组件完成率/排队指标，不得拿“CPU较高”“某盘较忙”等相关性替代。mseqread若客户端buffer命中
占主导（命中占比≥80%），只允许归因客户端/FUSE/buffer服务路径；除非另有后端GET服务率证据，禁止
把它写成Ceph/OSD架构墙。

---

## 五、容量曲线判读

对每组先核低并发回环漂移：

```text
anchor_drift = abs(BW_low_after / BW_low_before - 1)
scale_ratio  = BW_high / mean(BW_low_before, BW_low_after)
scale_eff    = scale_ratio / 2
lat_ratio    = P50_clat_high / mean(P50_clat_low_before, P50_clat_low_after)
```

- `anchor_drift≤5%`：曲线可解释；大于5%记`INCONCLUSIVE_DRIFT`，不补性能轮；
- `scale_ratio≥1.60`（效率≥80%）：记`SCALABLE_AT_TESTED_RANGE`，说明共享服务尚未在该区间形成硬平台；
- `scale_ratio≤1.15`且`lat_ratio≥1.60`，并有同窗共享组件饱和证据：记`SERVICE_PLATEAU_IDENTIFIED`；
- 其余记`PARTIAL_SCALING`，按同窗资源指标描述限制位置，不强行贴“架构极限”标签。

项目状态按以下规则映射：

- `SERVICE_PLATEAU_IDENTIFIED`且满足§六架构闭环门：`ARCHITECTURE_LIMITED_IN_TESTED_RANGE`；
- 找到满足§六候选硬门的现有旋钮：`ACTIONABLE_TUNING_FOUND`；它仍是待05因果A/B验证的候选假设；
- `SCALABLE_AT_TESTED_RANGE`、`PARTIAL_SCALING`、`INCONCLUSIVE_DRIFT`或机制缺失：
  `INCONCLUSIVE_CONTINUE_DIAGNOSIS`。

5%漂移门是为了不让基线噪声淹没§六的5%候选材料线，不是正式置信区间。04-6的单次容量差不能当作
参数效果量；进入05后必须另做单变量因果矩阵。这些阈值只对已测并发区间有效，也不改变6250 MiB/s
的原验收线。randrw读、写分别计算，不得相加后宣称达标。

---

## 六、项目与阶段裁决硬门

### 6.1 打开05：存在可生产候选

“看到某资源忙”不等于“发现可优化瓶颈”。只有同一个候选同时满足以下五项，才能记
`ACTIONABLE_TUNING_FOUND`并签`STAGE04_CLOSE_OPEN_STAGE05`：

1. **位置明确**：同窗曲线与机制指标共同指向一个具体组件/队列，而不是笼统的“系统忙”；
2. **存在旋钮**：exact patched v1.4.1或现有Ceph/TiKV/OS中有一个明确、单变量、可回滚的配置；
3. **可生产**：不改代码、硬件、集群拓扑、fio并发、I/O大小、缓存/持久性语义，不关闭正确性保护；
4. **材料上界**：依据容量差、排队占比或可释放服务率，保守预期收益`≥5%`，并说明该上界与候选旋钮
   的单变量因果链；只看到CPU或队列较高不算；
5. **未被排除**：不是03/04已验证无材料收益的readahead、max-uploads、compaction worker/限速、同盘逻辑
   分离、继续加inode、主动清理等方向。

该状态只是“值得验证的候选假设”，不等于参数收益已成立。若有多个候选，只选预计收益最高且风险最低
的一个进入05，其他登记备选；05另写因果任务书，不自动取得环境执行权。04-6不得现场顺手试参数。

### 6.2 关闭04：当前测试范围内架构受限

一个未达标项目必须同时满足以下条件，才可记`ARCHITECTURE_LIMITED_IN_TESTED_RANGE`：

1. 容量曲线、延迟和§4.3同窗指标识别出具体服务平台；
2. 将平台完成率与6250 MiB/s目标并列，量化仍缺多少服务量或需要多短的单请求周期；
3. “旋钮排除账本”覆盖与该组件相关的所有现有低风险配置，并逐项引用历史实验、负结果或不足5%上界；
4. 不存在尚未测试且可能达到5%的现有生产旋钮；继续提升只能改变源码、硬件、集群/PG拓扑、缓存或
   持久性/测试语义；
5. 结论明确限定在当前硬件、拓扑、实现、测试语义和本任务已测并发区间。

报告中的旋钮排除账本至少包含：`项目 / 平台组件 / 旋钮 / 证据索引 / 已测效果或排除理由 / 剩余架构方向`。
mseqread若由客户端buffer主导，可以闭合的是客户端路径；不得借此闭合Ceph后端。

### 6.3 必须继续诊断

以下任一情况均记`INCONCLUSIVE_CONTINUE_DIAGNOSIS`，不能用“未发现参数”替代“架构受限”：

- `SCALABLE_AT_TESTED_RANGE`、`PARTIAL_SCALING`、锚点漂移大于5%或机制指标缺失；
- 只有资源相关性，无法确认服务平台或排除相关生产旋钮；
- 候选收益上界可能达到5%，但位置、因果链或生产安全性尚未闭合；
- mseqread由客户端buffer主导，却试图据此判断Ceph后端上限。

此状态只允许另立一个针对缺口的最小诊断，不得把04-6扩成现场参数探索。

---

## 七、执行阶段与停点

### Phase 0：离线准备

- 复用`FULLBASELINE_V4.sh`的fio命令、身份门、对象回归和现有sampler；只新增`numjobs`参数入口、
  三组固定顺序和容量曲线分析；
- 用历史raw验证实际I/O窗口、低/高并发文件选择、读写方向拆分、§4.3饱和判读和三态裁决；
- 建立旋钮排除账本fixture；分析器只计算曲线和门，不替GPT作阶段裁决；
- Gate只覆盖本次新增路径及安全扫描，预算90分钟；连续两次确定性脚本bug则负责人直接缩减/修复，
  不得继续环境试错。

### Phase I：只读inventory与唯一授权停点

执行方只读核对身份、资产、健康、无其他RUN，并输出：

- 实际将执行的9条fio命令；
- RUN专属第二挂载与最终graceful umount完整命令；既有`/mnt/juicefs`的PID/starttime必须始终不变；
- PRE/seed及W01/W02/M01--M03的`gc --compact --delete --threads 32`归一化、mseqwrite一次性seed、
  16条最终精确删除、W03的`gc --delete`和`O0/O1`回归计划；
- scrub pause/restore及写后OSD compact的完整sudo命令：必须展开Ceph FSID、配置/凭据路径、逐个OSD ID、
  RUN lease与状态文件，禁止通配符；
- 写后恢复调用的既有脚本及哈希；若包含非sudo但会修改外部状态的`juicefs gc --compact`，也必须单列；
- 预计证据路径和10小时deadline。

此处获批后，Phase II内部连续执行，不逐cell停报。出现红线、身份变化、服务异常或恢复失败立即保留现场。

预计变更性sudo表面仅限下列命令，执行位置均为157，且live FSID必须等于
`f8137e5a-8af2-11f1-aa1c-4df480fc234d`、live OSD集合必须精确等于`0,1,2,3,4,5`：

```bash
# 仅由state-driven scrub controller执行；各最多一次，预计持续6--8h、硬上限10h
sudo ceph osd set noscrub
sudo ceph osd set nodeep-scrub

# 修复RUN在W01--W03、M01--M02后各一次；加上失效RUN已执行的W01，任务累计每OSD仍最多6次。
# 终末M03只做GC归一化和自然idle门，不再强制OSD compact。
sudo ceph tell osd.0 compact
sudo ceph tell osd.1 compact
sudo ceph tell osd.2 compact
sudo ceph tell osd.3 compact
sudo ceph tell osd.4 compact
sudo ceph tell osd.5 compact

# 仅由同一state owner恢复；各最多一次
sudo ceph osd unset nodeep-scrub
sudo ceph osd unset noscrub
```

若Phase I显示默认Ceph配置/凭据不能唯一解析上述FSID，必须把每条命令展开为带精确`-c`、`--keyring`
和`-n`的版本重新审核，不得自行替换。本清单不授权裸命令绕过状态控制器。

### Phase II：矩阵、恢复与交付

按PRE归一化并冻结O0→R→一次性seed归一化并冻结O1→W→精确删除seed并回到O0→M执行，
每个含写cell恢复起点后再继续。完成后先
恢复scrub lease和停止本RUN采集器，再做一次
业务指纹、Ceph health与残留核验。执行方只交raw、逐门清单和`incidents.tsv`，不计算效应量、不决定05。

GPT独立复算后产出：

- `doc/perf-report/04-6-stage04-final-capacity-and-tuning-exit-decision-<date>.md`；
- 更新`CURRENT-JUICEFS-PERFORMANCE-STATUS-*`、04计划书、04状态表及`results-table`；
- 按§一和§六签三态裁决：新建05任务书、签当前范围架构受限并结束04，或登记唯一最小诊断缺口。

---

## 八、安全与数据生命周期红线

1. 全程遵守`skills/SYSTEM-SAFETY-SKILL.md`；不得影响157上的WekaIO、K8s及其他业务；
2. 禁止reboot/shutdown、服务停启、OSD/TiKV重启、内核/网络/RoCE/md0修改；
   禁止在157及150--152执行全局`drop_caches`；
3. 禁止新建/删除pool、volume、namespace、全量layout，禁止写`/dev/nvme*`、`/mnt/jfs-tikv`、`/opt`、
   `/etc`、`/var/lib/ceph`；唯一允许的挂载生命周期是同一既有volume的
   `/tmp/jfs-t046-<RUN_ID>`非sudo第二挂载与graceful umount，禁止改动`/mnt/juicefs`；
4. 禁止`rm -rf`、递归chown/chmod、模式kill、`losetup -D`、lazy/forced unmount；
5. 所有sudo写操作必须在Phase I列出节点、完整命令与作用域并由用户一次性批准；只恢复本RUN拥有的状态；
6. 失败先保留现场和证据，不做猜测性清理；环境资产恢复与证据文件清理分开；
7. 157/集群与`/tmp`只作运行源，本地唯一权威根为`EVIDENCE_ROOT`；只增量同步，`PERSISTENCE_PASS`
   后才按精确清单清远端，禁止通配符、父目录递归和`rsync --delete`；
8. SCREEN长期只保留最小可复算raw、公共身份、实际脚本/命令、最终Gate、结论和事故摘要；不为无收益
   收尾反复复制或生成多份归档。

本任务不申请`sudo ceph config set`、`sudo ceph osd pool set`、`sudo systemctl`、`sudo podman restart`、
`sudo kill`、`sudo tee /proc/sys/vm/drop_caches`，也不申请任何sudo mount、loop、mkfs、pool或volume操作。
上述RUN专属非sudo第二挂载不得扩展作用域。除Phase I
精确展开并获批的scrub lease和逐OSD compact外，出现新的sudo需求必须停止并另行审核。

---

## 九、完成定义

04-6完成必须同时满足：

- 三组均有明确项目状态；非性能门失败、部分扩展或机制缺失必须诚实记为
  `INCONCLUSIVE_CONTINUE_DIAGNOSIS`；
- 复算能追溯到per-job raw与同窗机制指标；
- scrub/采集进程/临时证据和业务指纹全部收口；
- 报告逐项列出：理论与实测扩展、延迟变化、平台组件、饱和证据、已排除旋钮、架构方向和适用范围；
- 报告另列仍属未知的限制层、可生产候选清单及被排除理由；
- 最终只签§一的一种裁决，并立即停止04阶段继续“顺手试一项”。

---

## 十、修订记录

- 2026-09-03：将“有候选/无候选”二态改为三态；收紧锚点漂移门至5%；加入组件饱和、旋钮排除账本
  和架构结论适用范围；保持9-cell最小矩阵；禁止所有节点全局`drop_caches`并收紧sudo边界。
- 2026-09-03：首次RUN证明仅`gc --compact`不能删除覆盖写产生的pending对象；安全中止并收口后，
  将PRE/seed/每个保留文件的写cell统一冻结为`gc --compact --delete`归一化，W03仍为精确删文件后
  `gc --delete`；修复RUN取消终末M03后的强制OSD compact，使含失效RUN在内的任务累计仍不超过
  已批准的每OSD六次上限。
