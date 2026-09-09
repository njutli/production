# 04-8任务书：`--max-fuse-io=1M`正式效果验证

## 日期与状态

> 日期：2026-09-08
> 面向：执行代理采集证据；GPT独立复算与裁决
> 状态：`COMPLETED / VALID / STOP_REGRESSION / ENVIRONMENT_CLOSED`
> 承接：04-6b中F1筛选信号；本任务承载原计划的后续正式验证，不再重复新建同类任务。

> 正式RUN `20260909-115749`：Phase A确认seqwrite几何配对收益`+14.31%`；Phase B因
> mseqread `INCONCLUSIVE`、randwrite `REGRESSION`否决通用生产基线。详见
> `doc/perf-report/04-8-max-fuse-io-1m-formal-validation-20260909.md`。

```text
EVIDENCE_LEVEL=L2_FORMAL
SCREEN_SOURCE=04-6b有效RUN中seqwrite两组配对+7.13%/+14.81%，mseqwrite方向不一致
SCREEN_CONTINUE=Phase A确认seqwrite正收益后，才进入Phase B七项兼容性补齐
SCREEN_STOP=Phase A未确认正收益；立即停止性能矩阵并安全收口
FORMAL_MATRIX=Phase A: ABBA-BAAB八个独立mount；Phase B: ABBA四个独立mount
ESTIMATED_WALL_CLOCK=Phase A约3--5h；若通过，Phase B再约4--7h；总计上限12h，另留2h收口
MINIMUM_DECISION_SET=Phase A四组seqwrite配对；通过后补齐其余六项的非劣证据
STOP_AFTER_ANSWER=YES；不扫更多参数、不追加美化轮次、不重跑FULLBASELINE
MAX_PREP_BUDGET=90min
MAX_EXECUTION_BUDGET=12h性能与必要恢复 + 2h仅用于恢复、卸载和证据持久化
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-8/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04-8-<RUN_ID>
EVIDENCE_RETENTION=FORMAL
REMOTE_CLEANUP=AFTER_PERSISTENCE_PASS
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=恢复本RUN持有的scrub flags；graceful卸载任务mount；精确删除本任务写资产并核对象数回归；既有测试资产和/mnt/juicefs不变
```

一句话目标：**只改变`--max-fuse-io 256K→1M`，确认04-6b观察到的seqwrite约`+10.90%`
收益能否复现，并确认其余六项不存在不可接受退化。**

```text
04-6b L1候选（seqwrite几何配对效应+10.90%）
  |
  v
Phase A：8 mount正式确认seqwrite
  |-- 无确认收益/证据失效 --> STOP + 安全收口
  `-- 确认正收益
          |
          v
Phase B：4 mount检查其余六项非劣
  |-- 任一明确退化 --> 不交付1M
  `-- 全部通过 --> 进入生产灰度候选，不在本任务直接改生产
```

---

## 一、依据与边界

### 1.1 为什么做

04-6b在原始4 MiB、单流同步seqwrite语义下得到：

- 两组`1M/256K`配对带宽效应分别为`+7.13%`和`+14.81%`，几何配对效应`+10.90%`；
- FUSE平均写请求由约`256 KiB`变为约`1024 KiB`；
- 两组PUT及OSD `op_w`完成率随带宽同向提高，而OSD平均写延迟仅增加约`1.20%/2.05%`。

这些证据足以把`1M`升级为候选，但不足以直接交付：04-6b是L1筛选，且mseqwrite两组仅
`+6.28%/-1.41%`，方向不一致。本任务只补足正式收益和兼容性证据。

历史03-6在`bs=256KiB`读负载中观察到`1M`并未把实际FUSE请求扩大到1 MiB；这说明收益受应用I/O
语义约束，不能把seqwrite收益外推到其他项目，也不构成否定本任务的依据。

### 1.2 本任务能下什么结论

- `F1_PRODUCTION_CANARY_CANDIDATE`：seqwrite正式正收益成立，其他六项通过非劣门，环境完整恢复；
- `STOP_NO_CONFIRMED_GAIN`：04-6b信号未在正式矩阵复现；
- `STOP_REGRESSION`：其他项目出现明确且可重复退化；
- `RESOLUTION_INSUFFICIENT`：环境噪声超过本任务识别能力；
- `EVIDENCE_INVALID`：身份、健康、数据集、窗口或生命周期硬门失败。

即使得到候选结论，也只允许建议后续生产灰度；本任务不得直接修改现有交付挂载或生产配置。

### 1.3 明确不做

- 不测试readahead、cache、writeback、async_dio、buffer-size、uploads或其他参数组合；
- 不新建、format或destroy卷/pool，不改PG、CRUSH、TiKV、OSD或网络拓扑；
- 不重新layout既有128 GiB测试集，不因数据不好临时增加轮次；
- 不运行FULLBASELINE，不追求七项都提升；
- 不把不同版本、不同数据集或历史最高值混入本RUN正式效应量。

---

## 二、固定变量与唯一变量

| 项 | 固定值 |
|---|---|
| JuiceFS | `/tmp/juicefs-1.4.1-patched`；期望MD5 `24fae0852051c80ca571cb2f20275d46`，执行前实探 |
| META | `tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod`；禁止使用2379以外端口 |
| 后端 | 当前三节点TiKV、6 OSD、EC4+2及现有持久性语义不变 |
| Ceph客户端 | 从目标节点只读复制`/etc/ceph/ceph.conf`并追加任务私有`ms_async_op_threads=8`；期望MD5 `86351c58848c7e4caaa1bbeccb211730` |
| 公共挂载参数 | `--max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0`，默认readahead；其余逐字一致 |
| A臂 | `--max-fuse-io 256K` |
| B臂 | `--max-fuse-io 1M` |
| 正式窗 | fio实际I/O起点后的`[15,175)`；180秒time_based；1秒per-job日志 |
| 目标 | 各读/写方向`6250 MiB/s`；randrw读写分别报告，禁止相加 |
| 参考挂载 | `/mnt/juicefs`全程只读核验并保持PID/starttime/命令不变 |
| 任务挂载 | 仅`/tmp/jfs-t048-<RUN_ID>-<CELL>`；每个cell独立挂载和卸载 |
| 页缓存 | 157及150--152禁止全局`drop_caches`；两臂对称 |

唯一实验变量是`max-fuse-io`。若任何其他挂载参数、binary、Ceph配置、数据集、恢复口径或采样方式
发生变化，该对样本不得进入效应量。

---

## 三、数据集与稳定性控制

### 3.1 数据资产

1. 读项目复用既有固定资产；Phase I冻结路径、inode、大小、mtime和抽样hash。
2. randwrite/randrw只使用已确认的测试专属固定文件集；允许覆盖写，不得删除、重命名或改变大小。
3. seqwrite与mseqwrite若既有合同不满足要求，只允许在本任务私有目录一次性创建：
   - seqwrite：`1 × 32 GiB`；
   - mseqwrite：`16 × 4 GiB`。
4. 任务写资产只创建一次，恢复稳定后冻结为`O1`；A/B各轮复用同一inode集合，禁止逐轮layout。
5. 收口时仅按manifest逐文件删除任务私有资产，禁止glob、递归删除或触碰既有测试数据。

### 3.2 mount-tier稳定性检测

`max-fuse-io`是挂载级变量，正式样本必须来自独立mount。每个mount在性能项前运行既有签收的
mseqread探针，并计算FUSE per-byte latency：

```text
fuse_ns_per_byte = fuse_read_duration_ns / fuse_read_bytes
```

- 使用任务指南冻结的校准中位数`3.287 ns/B`；仅当高于该值`10%`（即慢于
  `3.616 ns/B`）才标记`BAD_TIER`，更低延迟不属于坏tier；
- A/B完全对称地检测和处理，禁止按带宽高低删样；
- 每个位置最多允许两个带唯一标签的替代mount；仍不合格则签`RESOLUTION_INSUFFICIENT`并收口；
- 正式报告必须同时披露总mount数、被拒mount数、原因及拒绝率。

探针的mseqread原始结果同时可用于Phase B的mseqread非劣判断；不得另造一套选择口径。

### 3.3 恢复门

- 开始前及每个写端点后必须满足：PG全`active+clean`、Ceph health符合冻结合同、无恢复/回填、
  对象数回到`O1±8192`、TiKV关键pending/compaction状态回到冻结带；
- 长矩阵经用户单独授权后可临时设置`noscrub + nodeep-scrub`，必须使用已有状态驱动脚本保存原值并
  精确恢复；例行scrub被暂停不等于忽略异常PG；
- 允许复用既有JuiceFS GC和逐OSD compact恢复合同，但不得为追求漂亮数据无限等待或反复compact；
- 单次恢复超过冻结上限，停止新性能cell并进入收口，不临时放宽门限。

每个detector必须在同一mount、同一metrics端口保存pre/post快照，并计算FUSE read duration与bytes
差值及`ns/B`；按`<=3.616 ns/B`机械判门，失败不得进入正式样本。该门只排除异常慢mount，
不因低延迟拒绝样本。seqwrite同样保存pre/post，至少
可复算FUSE write平均请求大小、PUT完成数和平均延迟；另保存复用04-6b格式的6个OSD `perf dump`。
JuiceFS新挂载可能不输出零值累计计数器：仅允许pre快照缺失且post存在的已知累计指标按`0`处理；
post缺失、计数回退或未知指标缺失仍是硬失败。
inventory除findmnt外必须冻结`/mnt/juicefs`参考挂载的PID、starttime、exe MD5/命令行，并检查任务写
路径没有foreign opener。

seed后以及每个seqwrite后执行固定恢复门：记录`juicefs-data` pool对象数锚`O1`、PG状态、Ceph
recovery/backfill字段和三节点TiKV pending compaction；连续3次、间隔10秒回到对象`O1±8192`、
PG active+clean、无recovery/backfill且pending不高于冻结带才继续，最长15分钟。Phase A默认不做
OSD compact；若恢复门超时，停止并保留现场，不自行放宽门限。

---

## 四、Phase A：seqwrite正式收益

### 4.1 矩阵

采用8个独立mount的`ABBA-BAAB`顺序，消除线性时间漂移且两臂平均位置相同：

| 位置 | Cell | 臂 | 正式项目 |
|---:|---|---|---|
| 1 | S01 | A/256K | detector → seqwrite |
| 2 | S02 | B/1M | detector → seqwrite |
| 3 | S03 | B/1M | detector → seqwrite |
| 4 | S04 | A/256K | detector → seqwrite |
| 5 | S05 | B/1M | detector → seqwrite |
| 6 | S06 | A/256K | detector → seqwrite |
| 7 | S07 | A/256K | detector → seqwrite |
| 8 | S08 | B/1M | detector → seqwrite |

seqwrite逐字沿用V4：

```text
rw=write, bs=4M, size=32G, numjobs=1, ioengine=psync, iodepth=1,
direct=1, end_fsync=1, time_based=1, runtime=180
```

四个预注册配对按相邻反向关系固定，禁止事后重配：

```text
P1=S02/S01, P2=S03/S04, P3=S05/S06, P4=S08/S07
```

### 4.2 指标与裁决

主指标是正式窗有效带宽，按per-job日志用实际重叠秒加权复算；fio summary只作旁证。同步保存：

- FUSE write请求数、字节数、平均请求大小和duration；
- JuiceFS PUT完成率与延迟；
- Ceph/OSD `op_w`完成率、延迟及物理写放大；
- 157 CPU、NIC、PSI以及后端健康快照。

同臂相邻位置`S02/S03`和`S06/S07`用于估计轮内噪声`epsilon`，定义：

```text
M = max(5%, 2 × epsilon)
```

只有同时满足下列条件，Phase A才签`SEQWRITE_GAIN_CONFIRMED`：

1. 8个接受样本全部通过非性能硬门；
2. 四个配对效应方向全部为正；
3. 几何配对效应`>= M`，且配对log效应双侧95% CI下界`>0`；
4. B臂FUSE平均写请求接近1 MiB，且PUT/OSD完成率与带宽同向；
5. 没有错误、挂载生命周期异常或OSD平均写延迟`>=10%`的材料退化。

OSD平均写延迟门按四个配对合并后的两臂累计`latency_sum/op_w`比较；各配对仍逐一披露，
用于生产灰度观察，但不以单个配对替代全臂材料退化判据。该指标必须与OSD完成率一起解释，
因为B臂若提高服务率，排队延迟可能随实际负载同步上升。

若`epsilon>=5%`，直接标记分辨率不足；不得用扩大非劣边界的方式制造通过。Phase A不通过即停止，
不执行Phase B。

---

## 五、Phase B：其余六项非劣检查

仅在Phase A通过后执行。采用4个独立mount的`A-B-B-A`，每臂2个样本；这是兼容性门，不用于宣称
这些项目获得正收益。

| Cell | 臂 | 固定执行顺序 |
|---|---|---|
| C01 | A/256K | mseqread探针 → seqread → randread → mseqwrite → randwrite → randrw |
| C02 | B/1M | 同上 |
| C03 | B/1M | 同上 |
| C04 | A/256K | 同上 |

fio语义逐字沿用V4：

| 项目 | rw | bs | size × jobs | engine/QD | 其他 |
|---|---|---:|---:|---|---|
| seqread | read | 256K | 32G × 1 | psync/1 | direct=1 |
| mseqread | read | 256K | 4G × 16 | psync/1 | direct=1；采用mount探针数据 |
| randread | randread | 256K | 1G × 128 | libaio/128 | direct=1 |
| mseqwrite | write | 4M | 4G × 16 | psync/1 | direct=1,end_fsync=1 |
| randwrite | randwrite | 256K | 1G × 128 | libaio/128 | direct=1 |
| randrw | randrw | 256K | 1G × 128 | libaio/128 | rwmixread=50,direct=1 |

全部为180秒time_based，正式窗仍为`[15,175)`。写/混合项目之间必须经过第三节的固定恢复门；不得因
同mount复用而跳过恢复。randrw读、写方向分别裁决。

配对固定为`C02/C01`与`C03/C04`。每个方向的非劣边界为`-5%`：

- 两组配对均`>=-5%`：`NON_INFERIOR`；
- 任一组`<-10%`，或两组均`<-5%`：`REGRESSION`；
- 其余情况：`INCONCLUSIVE`，不得批准候选，也不在本任务追加轮次。

Phase A的seqwrite和mseqread证据与Phase B六项合并，形成七项兼容性结论。任何方向出现
`REGRESSION`或`INCONCLUSIVE`，本任务均不建议把1M写入生产基线。

---

## 六、执行阶段与停止点

### Phase 0：离线准备与Gate 0

执行代理首先完整阅读并声明遵守：

- `skills/SYSTEM-SAFETY-SKILL.md`；
- `skills/EVIDENCE-INTEGRITY-SKILL.md`；
- `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`；
- `doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`。

脚本优先复用04-6b已签收的挂载身份、fio、采样、恢复和清理组件；当前已准备
`scripts/FULLBASELINE/debug/t04-8-analyze.py`（只读离线分析器）和
`scripts/FULLBASELINE/debug/t04-8-gate0-offline.sh`（只读Gate 0）；实际环境执行编排器仍须在
Gate 0通过后再补齐，不得以未完成脚本连接环境。
任何新增/修改脚本必须先完成`bash -n`、危险词扫描、dry-run/plan检查、路径作用域、PID/starttime、
UUID、manifest和停止分支离线Gate 0。Gate 0未通过时禁止SSH执行。

当前离线配套文件为：`scripts/FULLBASELINE/debug/t04-8-gate0-offline.sh`、
`t04-8-analyze.py`和`t04-8-phase-a.sh`。后者是目标节点上的Phase A/B执行器，支持
`plan/inventory/phase-a/phase-b/closure`，并另有显式的`scrub-plan/scrub-pause*/scrub-restore*`和
`cleanup-plan/cleanup`入口。它不含其他sudo写操作，若未来
恢复合同需要OSD compact，必须另行生成计划并取得授权，不能在脚本内隐含执行。

执行器在每个detector和seqwrite前后抓取同一metrics端口；正式RUN经授权暂停scrub，
只能先运行`scrub-plan`，再由用户审核`sudo ceph osd set noscrub`、`sudo ceph osd set nodeep-scrub`
以及对应的`unset`恢复命令后运行ACK门控入口。

### Phase I：只读inventory与写操作plan

只读确认binary、META/UUID、参考挂载、数据manifest、Ceph/TiKV健康、对象锚、空间、foreign opener和
证据目录。输出未来所有sudo写命令的完整命令、节点、目标和逆操作，暂停等待用户授权。

### Phase II：Phase A

在获得授权后执行8个mount。达到`SCREEN_STOP`、硬门失败或预算上限时，停止新cell并转Phase IV。

### Phase III：Phase B

仅凭GPT对Phase A原始证据独立复算后明确放行，才执行4个mount兼容性检查。

### Phase IV：恢复、持久化与报告

按顺序恢复scrub状态、graceful卸载、精确处理任务资产、核对象锚、核参考挂载/生产进程指纹，先将
raw、manifest、命令、校验和及恢复证据持久化到`EVIDENCE_ROOT`，通过
`PERSISTENCE_PASS`后才清理远端暂存。报告和聚合表不得替代raw。

---

## 七、安全授权边界

本任务书本身不授权任何环境写操作。预计无需创建loop、mkfs、新pool或新卷。未来若需要以下sudo，
必须在Phase I列出完整命令并由用户逐项批准：

- 临时设置及恢复Ceph `noscrub/nodeep-scrub`；
- 对明确OSD逐个执行既有恢复合同中的compact；
- 任何任务挂载清理中确实需要的精确权限操作。

无论是否获得一般授权，均禁止：

1. reboot、shutdown、systemctl stop/restart生产服务；
2. 修改网络、路由、防火墙、内核参数、NUMA/IRQ或设备调度器；
3. 对157或150--152执行全局`drop_caches`；
4. force/lazy unmount、kill非本RUN进程、批量pkill；
5. `rm -rf`、通配符删除、wipefs、直接写块设备或操作未核验loop；
6. format/destroy既有JuiceFS卷，或更改现有pool/PG/CRUSH/TiKV配置；
7. 修改、卸载或接管`/mnt/juicefs`参考挂载。

任何命令目标、PID/starttime、UUID、挂载源或设备映射无法精确验证时，停止执行并保留现场，只采只读
证据。性能失败不允许跳过安全收口。

---

## 八、证据合同与职责分工

每个cell至少保留：

```text
command.txt / fio.json / *_bw.*.log / mount-command.txt
mount-identity.tsv / detector.tsv / metrics-delta.json / ceph-health.before-after.txt
juicefs-metrics.raw / ceph-osd-metrics.raw / client-resource.raw
dataset-manifest.tsv / recovery-gate.tsv / sha256sum.txt
```

离线分析器约定Phase A的正式seqwrite目录为`cells/S01-seqwrite`至
`cells/S08-seqwrite`；Phase B目录为`cells/C01-<item>`至`cells/C04-<item>`。
detector原始证据单独保存在同cell的detector子目录，不得覆盖正式fio文件。

执行代理职责限于：执行冻结命令、保存raw、给出合同级PASS/FAIL、记录故障和完成安全恢复；不得自行
删除失败样本、修改阈值、补跑未授权轮次或宣布生产结论。

GPT职责：从raw独立重算窗口带宽、配对效应、噪声、95% CI、非劣裁决和机制闭环；对报告数字逐项
追溯到`source-map.tsv`。屏幕摘要、执行代理口述和聚合CSV均不能代替原始fio/metrics证据。

最终报告必须明确区分：

- 非性能有效性门：身份、健康、数据合同、采集、恢复和生命周期；
- 性能端点：带宽、延迟、完成率和效应量；
- 工程建议：维持256K、进入1M生产灰度候选，或证据不足。

---

## 九、任务结束前合规检查

- [x] 只改变`max-fuse-io`，A/B其他条件逐字一致；
- [x] Phase A通过并由GPT独立复算后才执行Phase B；
- [x] 没有按性能高低删样、替换样本或追加美化轮次；
- [x] 每个接受mount通过同一detector合同并披露拒绝率；
- [x] 既有layout未重建，任务资产受manifest约束且精确收口；
- [x] 用户批准的每项sudo均有原状态、执行证据和逆操作证据；
- [x] `/mnt/juicefs`、生产进程、Ceph/TiKV健康和对象锚均完成终态核验；
- [x] raw先持久化到`/mnt/c/SunRise/test/04-8/<RUN_ID>`并校验后才清远端；
- [x] 已逐项复核SYSTEM-SAFETY、EVIDENCE-INTEGRITY、编写指南和数据生命周期规范；
- [x] 报告没有把本任务结论越界写成已修改生产配置。
