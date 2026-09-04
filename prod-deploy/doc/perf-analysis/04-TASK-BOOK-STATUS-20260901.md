# 04阶段任务书现状

## 快照信息

```text
SNAPSHOT_DATE=2026-09-04
SCOPE=04阶段主线任务书、条件任务书和临时专项任务书
STATUS_SOURCE_PRIORITY=最新执行证据 > 任务书当前状态 > 04阶段计划书执行台账
CURRENT_ACTIVE_TASK=NONE；04-tmp3b RUN 20260904-132417已结束、持久化并关闭环境
NEXT_PREPARATION=无自动性能测试；04-tmp2f与04-6b继续等待决策，不由04-tmp3b自动触发补样
```

本文只记录任务书当前进度、依赖和下一动作，不替代各任务书的实验合同，也不授予环境执行权限。
若本文与最新原始执行证据冲突，以最新执行证据为准。

---

## 一、整体状态一览

### ✅ 已完成（13项）

| 工作线 | 任务书 | 当前状态 | 完成日期 | 预估时长 | 已有成果 | 尚缺内容 | 结论 |
|---|---|---|---|---|---|---|---|
| U1 版本锁定 | `u141b-*` + `u141d-*` | ✅ **已完成** | 2026-08-31 | 剩余`0` | `REPLACE_APPROVED`；锁定 exact patched v1.4.1，MD5 `24fae085...`；stock v1.4.1继续排除 | 无 | patched v1.4.1 七项均未检测到材料性退步，正式替代 v1.3.1 作为交付基线；社区原版 v1.4.1 因 randwrite 崩塌（~551 MiB/s）排除 |
| 临时调优：randrw readahead | `04-tmp-randrw-readahead-residual-tuning.md` | ✅ **全部完成；生命周期已关闭** | 2026-09-01 | 剩余`0`；Phase II约`10.5 h`（12 cell，avg `52.5 min/cell`，对象排水主导；fio仅约`7 min/cell`） | RUN `20260831-231629`完成12/12 cell；READ/WRITE效应`+1.62%/+1.64%`，CI上界`+3.21%/+3.28%`均低于5% | 无 | 关闭预读对 randrw 收益仅 +1.6%，远低于 5% 材料线；保持默认 readahead |
| 临时备选：本地读缓存 | `04-tmp2-juicefs-local-read-cache-stability-canary.md` | ✅ **已完成；生命周期已关闭** | 2026-09-02 | 剩余`0` | RUN `20260902-133433`四轮+POST-A通过；A=`3713.56`、B=`36490.02 MiB/s`，热集机制信号强 | 缓存合同未闭合：R02仍填充`19.51 GiB`，热点在页缓存而非NVMe | 签 `CACHE_SCREEN_EVIDENCE_INVALID`；热集信号强但不交付固定生产配置 |
| 临时备选：读写缓存容量曲线 | `04-tmp2b-juicefs-read-write-cache-capacity-curve.md` | ✅ **已终止并关闭；证据INVALID** | 2026-09-03 | 剩余`0`；完成6个读点及1个写点后安全终止 | 六个读点轮内稳态；mseqread=`3104/3293/3437`，randread=`3892/2645/3815 MiB/s`；读曲线不单调 | `randwrite-c16`排空残留112 blocks/29.36 MB并持续ENOENT | 签 `CACHE_CAPACITY_CURVE_INVALID`；writeback 生产决策以04-tmp2e为准 |
| 临时订正：randread缓存驻留 | `04-tmp2c-randread-cache-residency-curve.md` | ✅ **已完成；工程机制确认；环境关闭** | 2026-09-03 | 剩余`0`；7个只读cell约`37 min` | C16/C32命中`95.83%/~100%`，约`34.5 GiB/s`，Ceph RX降至`~0` | 预注册drops硬门使正式曲线INVALID | 确认"热集近全驻留才有材料收益"；不交付固定容量 |
| 临时订正：交付配置读缓存曲线 | `04-tmp2d-production-aligned-read-cache-curve.md` | ✅ **已完成；14/14有效；环境关闭** | 2026-09-03 | 剩余`0`；实际约`2.5 h` | A0漂移`0.87%/0.16%`；C200 mseqread/randread=`34.83/36.53 GiB/s` | 生产最小全驻留余量位于100%--200%之间 | 读缓存有稳定材料级收益：75%缓存带宽+173%/+233%；带宽随缓存超线性增长，75%为拐点 |
| 临时订正：writeback容量曲线 | `04-tmp2e-writeback-capacity-curve.md` | ✅ **W16硬失败；环境已关闭；条件性交付** | 2026-09-03 | 剩余`0`；修正容量W16约`50 min`，失败恢复约`30 min` | 16 GiB backing实际Available`15.53 GiB`；前90秒约`2770.80 MiB/s`；900秒后残留`2 blocks` | 无；W32--W128按早停合同取消 | `W16_WRITEBACK_DRAIN_FAILURE`否决W16容量档，不否决突发吸收；条件性生产增强 |
| 临时对标：竞品大块单流 | `04-tmp3-competitor-large-block-sequential-benchmark.md` | ✅ **RUN `20260904-095827`已完成；12/12有效；环境关闭** | 2026-09-04 | 剩余`0`；本L1已结束，不自动执行L2 | R读臂`2614.08 MiB/s`(+65.27%)；F写臂`+10.60%`，方向一致 | 可选L2须另立任务 | 四个竞品披露目标均未达；R是强L1信号，F写具确认资格；不覆盖256K七项基线 |
| 临时对标：竞品I/O路径对齐 | `04-tmp3b-competitor-large-block-io-path-alignment.md` | ✅ **RUN `20260904-132417`完成；环境关闭** | 2026-09-04 | 剩余`0` | RA32双配对`+9.74%/+13.80%`，未过选择门；async约`0%`；B4读相对B256为`-34.13%/-33.47%` | 写ABBA因首格持久性硬门取消 | 保持RA8/async off/256K；写前台值仅工程观察，不签目标或BlockSize效应 |
| R1a PG自然布局 | `04-1-randread-pg-layout-feasibility-and-isolated-pool-ab.md` | ✅ **已结束；环境收口；BLOCKED** | 2026-09-01 | 剩余`0` | RUN `20260901-125124`完成32→64→128：`I_primary=1.3125→1.21875→1.21875`；测试Pool/rule已删除 | 无；结论并入04-1b | CRUSH分裂PG不改变primary比例；`R1_FEASIBILITY_BLOCKED` |
| R1b 同池Primary工程对照 | `04-1b-randread-explicit-primary-steering-ab.md` | ✅ **已完成；生命周期已关闭** | 2026-09-02 | 剩余`0` | N=`3467/3438`、S=`3920/3929 MiB/s`，提升`+13.67%`，但仅达6250的`62.79%`；证据`558/558 OK` | 缺`I_op`和严格同挂载八轮正式效应 | `R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET`；作为新Pool架构候选保留 |
| Z0 阶段收尾 | `04-6-stage04-final-capacity-and-tuning-exit-decision.md` | ✅ **RUN `20260903-214003`完成；环境与证据闭合** | 2026-09-03 | 剩余`0` | 9/9 cell通过；mseqwrite=`SERVICE_PLATEAU_IDENTIFIED`（六OSD盘P50均100%）；mseqread仍`PARTIAL_SCALING`，randrw漂移约`8.2%` | mseqread/randrw未闭合；后续诊断由04-6b承担 | 未发现新可交付旋钮；签`STAGE04_CONTINUE_DIAGNOSIS`；mseqwrite仅当前范围内闭合 |
| A1 fresh归因 | `04-2-hcl-native-vs-nested-attribution.md` | ✅ **已完成；生产与证据生命周期已关闭** | 2026-09-02 | 剩余`0`；RUN `20260902-160000`完成H0/H1与C/L八臂 | C/L效应`-4.54%`、`epsilon=8.45%`；H漂移`96.70%` | 无必做补测 | `A1_CL_RESOLUTION_INSUFFICIENT`；nested-loop非主要瓶颈，fresh收益不可固化 |
| M1 写架构审计 | `04-4-metadata-transaction-options.md` | ✅ **已完成** | 2026-08-30 | 剩余`0` | 报告签`M1_SINGLE_OPTION_ONLY`；仅O1"同inode跨chunk metadata batch"具材料上界 | 无 | 唯一候选metadata batch（T2 conditional）；保留结论，不进入原型 |

### ⏳ 待准备（2项）

| 工作线 | 任务书 | 当前状态 | 预估时长 | 已有成果 | 尚缺内容 | 结论 |
|---|---|---|---|---|---|---|
| 临时订正：writeback排空归因 | `04-tmp2f-writeback-drain-attribution-and-capacity-curve.md` | ⏳ **任务书PLANNED；脚本未准备；未授权** | 离线根因+容量矩阵`3--5 h` | W16失败证据（2残留文件与2条hardlink ENOSPC匹配）；旧20GiB 70秒排空旁证 | 离线根因事件表、容量矩阵脚本/Gate、loop/ext4 sudo计划 | 先闭合文件级根因，再测32/64/96/128GiB找首个观测安全点 |
| Z0b 端到端容量账与残余调优收口 | `04-6b-end-to-end-capacity-and-residual-tuning-closure.md` | ⏳ **任务书READY；脚本未准备；未授权** | 离线准备≤`90 min`；环境`8--12 h`+`2 h`收口 | 承接04-6/U141d/04-tmp3/04-1b持久raw | 七项容量账+R8/F1/U300各一个ABBA+randrw状态回环脚本/Gate | 首次发现材料候选即停止；不补全量基线、不现场扩参 |

### ⏸ 已挂起（2项）

| 工作线 | 任务书 | 当前状态 | 预估时长 | 已有成果 | 尚缺内容 | 结论 |
|---|---|---|---|---|---|---|
| A2a 元数据规模 | `04-3a-metadata-state-scale-sweep.md` | ⏸ **已挂起；架构研究；不准备脚本** | 复活后由Phase F重新标定 | 已冻结逻辑元数据规模联合效应设计 | 即使归因成功也不能直接形成当前生产配置 | 仅在生产规模相关退化或扩容/namespace拆分立项时复活 |
| A2b region因果 | `04-3b-fixed-scale-region-causality.md` | ⏸ **已建挂起记录；前置条件不成立** | 复活后重新冻结最小矩阵 | 保留固定逻辑规模、只改region的因果边界 | A2a材料信号+独立操纵+架构投资需求 | 仅在全部复活条件成立时修订 |

### ❌ 已废弃（1项）

| 工作线 | 任务书 | 当前状态 | 预估时长 | 已有成果 | 尚缺内容 | 结论 |
|---|---|---|---|---|---|---|
| M2 写架构原型 | `04-5-metadata-transaction-batching-prototype.md` | 🗑️ **已废弃；不执行** | 剩余`0` | 历史设计与阶段门保留供参考 | 无 | 即使原型有效也无法在当前周期直接生产化；停止投入 |

**时长校准依据**：04-tmp Phase II 实测（RUN `20260831-231629`，12 cell randrw）总执行约 `10.5 h`（16h lease 内），平均 `52.5 min/cell`，其中 fio 仅约 `7 min/cell`，对象排水（Ceph GC 回收写后对象）主导耗时——首轮 `5.5 min`，后续 `48--53 min/cell`；randread 正式 cell 无对象排水。Phase I（preflight+plan）+ Gate 0 + 后处理（manifest/archive/ALL_DONE）合计约 `20--30 min`。上表已据此将写含排水的任务从纯 fio 估时校准为含排水实测值，并将 randread 为主的任务下调排水开销。

---

## 二、04-1与04-1b当前边界

### 2.1 04-1已经回答的问题

RUN `20260901-125124`在同一空Pool上完成实际PG梯子：

```text
32 PG  I_primary=1.3125
64 PG  I_primary=1.21875
128 PG I_primary=1.21875
VERDICT=R1_FEASIBILITY_BLOCKED
```

64→128时primary直方图同比翻倍，说明**只增加PG数不能改变当前CRUSH产生的primary比例**。
空测试Pool、专属rule已精确删除，`mon_allow_pool_delete=false`已恢复，参考Pool未变，Ceph
`HEALTH_OK`。04-1不再执行；其结论不得扩大为“显式primary控制也不可行”。

### 2.2 为什么增加04-1b

原04-1把测试参考`juicefs-data`误称为生产Pool，并以此禁止所有显式映射。现场其实是纯测试集群。
同时，Quincy现场没有`pg-upmap-primary`，但支持`osd pg-upmap`；后者可以在新Pool仍为空时，
保持每个PG的六个acting成员不变而调整顺序，将64 PG primary分布控制到理论最优。

04-1b最终RUN `20260901-194644`在空Pool应用5条pool/PG级upmap并只layout一次，随后用
`primary-temp`在同一Pool/UUID/文件集上切换N/S。自然态直方图
`{0:10,1:15,2:11,3:11,4:8,5:9}`（`I_primary=1.40625`），均衡态为
`{0:10,1:11,2:11,3:10,4:11,5:11}`（`1.03125`）。N=`3467/3438`、S=`3920/3929 MiB/s`，
描述性差`+13.67%`；方向强但均衡态仍未达到6250。

正式报告：`doc/perf-report/04-1b-randread-explicit-primary-steering-ab-20260902.md`。W01与W02--W04
之间挂载实例发生变化，且OSD sampler未取得实际`op_r`，所以签“生产候选工程信号”而非可直接上线的
正式效应。测试Pool、volume、upmap、CephX和临时资产均已删除，全局状态与业务指纹恢复。

---

## 三、已经完成性能签收的04-tmp

任务书：`04-tmp-randrw-readahead-residual-tuning.md`。

目的：只改变是否显式设置`max-readahead=0`，确认randrw相对交付配置是否存在可固化的剩余收益。

正式结果：

```text
doc/perf-report/04-tmp-randrw-readahead-residual-tuning-20260901.md
RUN_ID=20260831-231629
VERDICT=RW_RA_INCONCLUSIVE
ENGINEERING_DECISION=KEEP_DEFAULT_READAHEAD; MATERIAL_5PCT_BENEFIT_EXCLUDED
```

结果与处置：

- W01--W04和R01--R08共12/12 cell通过，正式八轮全部非性能硬门通过；
- READ效应`+1.6246%`、95% CI`[+0.0399%, +3.2094%]`；WRITE效应`+1.6447%`、
  95% CI`[+0.0088%, +3.2806%]`；
- 冻结状态机因“CI刚好不跨0但又低于5%”输出`RW_RA_INCONCLUSIVE`；区间已经排除5%材料收益，
  工程上保持默认readahead并关闭该参数方向；
- 原始zstd归档已持久化，SHA256=`5e5953e5...`；GPT复核manifest `7839/7839 OK`并从per-job
  raw独立复算；
- scrub、环境资产和证据生命周期均已闭合；本地/远端去重共释放`188,713,518`字节；
- 旧RUN `20260831-203458`根因已经关闭，由最终有效RUN证明修复；只保留最小事故包和排水归因。

---

## 四、暂存专项任务书

| 任务书 | 状态 | 预估时长 | 做什么 | 启动条件 | 当前优先级 |
|---|---|---|---|---|---|
| `04-tmp2-juicefs-local-read-cache-stability-canary.md` | ✅ `COMPLETED / CACHE_SCREEN_EVIDENCE_INVALID / ENVIRONMENT_CLOSED` | 剩余`0` | cache=0/64GiB、固定32GiB热窗口、128 job的单个ABBA L1 screen | 已完成，不再启动 | **已关闭**；强热集信号仅作工程观察，不升级L2 |
| `04-tmp2b-juicefs-read-write-cache-capacity-curve.md` | ✅ `COMPLETED / CACHE_CAPACITY_CURVE_INVALID / ENVIRONMENT_CLOSED` | 剩余`0` | 读缓存+writeback同时开启，测16/32/64 GiB共享容量对四个重点项的曲线 | 已完成6个有效读点；首个写点触发staging排空硬失败，按合同终止并安全恢复 | **已关闭**；不补齐剩余写点，不交付组合缓存档位 |
| `04-tmp2c-randread-cache-residency-curve.md` | ✅ `COMPLETED / ENGINEERING_SIGNAL_CONFIRMED / ENVIRONMENT_CLOSED` | 剩余`0` | 修正inode容量合同，以16 GiB热集测0%--200%读缓存驻留曲线 | C16/C32近全命中并达到约35.3k MiB/s（34.5 GiB/s）；预注册drops门使正式曲线INVALID | **已关闭**；确认读缓存机制但不交付固定生产容量；本项不提供writeback证据，后续决策见04-tmp2e |
| `04-tmp2d-production-aligned-read-cache-curve.md` | ✅ `COMPLETED / READ_CACHE_CURVE_COMPLETE / ENVIRONMENT_CLOSED` | 剩余`0` | 用正确交付配置测mseqread/randread原生工作集25%--200%缓存曲线 | 14/14最终有效；C200全命中，约34.83/36.53 GiB/s；A0漂移<1% | **已关闭**；生产容量只建议按热集+开销留余量，不直接照搬2倍档 |
| `04-tmp2e-writeback-capacity-curve.md` | ✅ `W16_WRITEBACK_DRAIN_FAILURE / ENVIRONMENT_CLOSED / CONDITIONAL_PRODUCTION_PROFILE` | 剩余`0` | 修正容量后验证writeback前台与排空语义 | 前90秒约`2770.80 MiB/s`；W16在900秒门残留2 blocks，恢复清零并安全收口 | **已关闭**；不继续更大容量或randrw；W16不采用，有充足本地空间的低占空比独占写客户端条件性启用writeback |
| `04-tmp3-competitor-large-block-sequential-benchmark.md` | ✅ `COMPLETED / VALIDATED_L1_SCREEN / ENVIRONMENT_CLOSED` | 剩余`0` | 按竞品披露的cp与16M/20M单流fio口径测当前配置，并筛选有限的大块适配参数 | RUN `20260904-095827` 12/12 cell通过；R读`+65.27%`，F写`+10.60%`，W对F无增量 | **已关闭**；只保留可选精简L2候选，不覆盖256K七项基线 |
| `04-tmp3b-competitor-large-block-io-path-alignment.md` | ✅ `COMPLETED_L1 / WRITE_INVALID / ENVIRONMENT_CLOSED` | 剩余`0` | 现有卷筛RA/async；fresh B256/B4检验format BlockSize | RA32未过双配对门、async无收益、B4读下降约34%；首个B256写重挂不可见，写分支按硬门停止 | **已关闭**；保持RA8/async off/256K，不覆盖七项基线 |

04-tmp2至04-tmp2d均已完成并关闭环境。04-tmp2d已用交付配置形成有效读缓存容量曲线；
04-tmp2e已用修正后的16 GiB W16重验并复现staging排空硬失败；环境已关闭，不再展开容量曲线。
该硬失败否决W16容量档，但前段突发吸收和旧20 GiB canary排空支持writeback作为有充足本地空间时的
条件性生产增强；不改变无缓存基线。
04-tmp3与04-tmp3b均已结束并关闭环境。04-tmp3b没有筛出可升级的参数：RA32未过门、async无收益、
4 MiB BlockSize使单流读下降约34%；写侧因首格重挂可见性硬门失效，不补样、不进入L2。

---

## 五、依赖关系和建议顺序

```text
04-tmp 已全部完成并关闭生命周期
  → 04-1 已结束：单纯32→64→128 PG不能自然均衡primary
  → 04-1b 已结束：同池primary均衡产生+13.67%工程信号，但3924.5<6250
       → 新Pool生产候选；测试映射不可复制，已有Pool不可直接在线套用
  → 04-tmp2 已结束：热集缓存机制信号强，但缓存合同失败，不升级L2
       → 04-tmp2b 已结束：读点仅为描述性观察，writeback staging排空硬失败
       → 04-tmp2c 已结束：修正容量后确认近全驻留读缓存约34.5 GiB/s；不交付固定档位
  → 04-6 已执行待分析：mseqwrite服务平台已离线补证；因mseqread部分扩展/randrw漂移签STAGE04_CONTINUE_DIAGNOSIS
       → 04-tmp3 已完成：大块direct读R臂为强L1信号，写F臂具确认资格，不补写04-6的架构裁决
```

04-2已完成，04-3a/04-3b架构研究挂起；04-tmp2系列中只剩04-tmp2f待决策，04-tmp3与04-tmp3b均已完成并关闭。
04-6已执行待分析，签`STAGE04_CONTINUE_DIAGNOSIS`，后续mseqread/randrw诊断另立最小任务，不重跑04-6矩阵。

---

## 六、任务书成熟度和剩余工作量

| 类别 | 任务书 | 说明 |
|---|---|---|
| ✅ 已完成 | U1、04-4 | 已有正式裁决，不应重开同一问题 |
| ✅ 已完成并关闭 | 04-tmp | 不再测试、不再追加收尾工作 |
| ✅ 已完成并关闭 | 04-1 | 32/64/128 PG梯子均未过门；环境已精确恢复；窄结论并入04-1b正式报告 |
| ✅ 已完成并关闭 | 04-1b | `+13.67%`工程信号但目标未达；证据与环境生命周期全部闭合，不再补测 |
| ✅ 已完成并关闭 | 04-tmp2 | 热集缓存工程信号强，但未形成可交付的NVMe稳定收益，不升级L2 |
| ✅ 已完成并关闭 | 04-tmp2b | 读曲线不可归因、writeback staging硬失败；该RUN不重跑且不交付组合缓存档位，当前writeback生产边界见04-tmp2e |
| ✅ 已完成并关闭 | 04-tmp2c | 订正inode限制并确认近全驻留读缓存机制收益；预注册drops门下正式曲线仍INVALID |
| ✅ 已完成并关闭 | 04-tmp2d | 14/14有效；C200全命中，mseqread/randread约34.83/36.53 GiB/s；环境资产关闭 |
| ✅ 已完成并关闭 | 04-tmp2e | W16 fio成功但staging在900秒后残留2 blocks；恢复挂载清零，环境闭环；取消其余容量点；生产决策为有充足本地空间时条件性启用writeback，W16不采用 |
| ⏳ 已写但脚本未准备 | 04-tmp2f | writeback排空归因与容量曲线；等待是否继续投入的决策 |
| ✅ 已完成并关闭 | 04-tmp3 | RUN `20260904-095827` 12/12有效；R读强L1信号，F写具确认资格，不自动升级L2 |
| ✅ 已完成并关闭 | 04-tmp3b | RUN `20260904-132417`；RA/async与B256/B4读问题已回答，写侧按持久性硬门停止；临时卷销毁且当前卷指纹不变 |
| 🔬 已执行待分析 | 04-6 | 9-cell与恢复闭合；mseqwrite=`SERVICE_PLATEAU_IDENTIFIED`，无新生产旋钮；mseqread/randrw未闭合，严格裁决`STAGE04_CONTINUE_DIAGNOSIS` |
| ✅ 已完成并关闭 | 04-2 | C/L效应低于当前分辨力；H锚点严重漂移；生产恢复已签收 |
| ❌ 已废弃 | 04-5 | 源码原型无法在当前交付周期内直接用于生产，不再执行 |

当前剩余工作量不能简单按“还有几份任务书”计算：

- 04-1b已结束；若决定生产化，只为目标新Pool另立变更/canary，不复用本任务RUN或映射；
- 04-6已执行待分析；frozen raw离线补证已闭合mseqwrite服务平台，但mseqread部分扩展和randrw状态债务仍不等于全部项目已证明数学架构上限；后两者仅在需要严格闭环时另立最小诊断；
- 04-2已完成；04-3a/04-3b即使归因成功也不能直接产生当前生产配置，现已挂起且不再占用准备或维护窗口；
- 04-5已废弃，原估被动插桩`4--7人日`、完整原型`17--30人日`的研发投入不再发生；
- 04-tmp2b已按写回硬门停止，04-tmp2c已完成机制订正，04-tmp2d已完成交付配置读缓存曲线；
  04-tmp2e已在W16排空硬失败后关闭，W16不采用但writeback纳入条件性生产增强；04-tmp2f计划
  闭合文件级排空根因并测容量矩阵，尚未准备脚本；04-tmp3已完成并关闭。

---

## 七、开跑前统一修订项

本状态文档之后尚未开跑的任务书，执行前须补齐
`doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`规定的最低字段：

```text
EVIDENCE_ROOT
REMOTE_RESULT_ROOT
EVIDENCE_RETENTION
REMOTE_CLEANUP
LOCAL_COMPACTION
ENVIRONMENT_ASSET_CLEANUP
```

同时执行以下原则：

1. RUN公共证据只复制一次，逐cell只增量回传；
2. 失败现场仅保留到归因、持久化和替代RUN验证完成，不永久堆积完整副本；
3. 证据文件清理与卷、pool、namespace、挂载和进程清理分开授权；
4. 阶段边界更新生命周期状态，RUN结束完成远端和本地副本收口；
5. L0/L1使用最小实现，不为生命周期规范额外制造重复归档和空目录。

---

## 八、需要同步回主计划书的状态

`04-metadata-architecture-and-layout-plan.md`已同步04-1的窄范围`R1_FEASIBILITY_BLOCKED`与04-1b
`R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET`结论。04-3a/04-3b已转为架构研究挂起；04-5已废弃并退出执行路线。
04-2已同步`A1_CL_RESOLUTION_INSUFFICIENT`与`HISTORICAL_ANCHOR_RESOLUTION_INSUFFICIENT`，
不再把A1列为待准备任务。04-6已执行待分析，签`STAGE04_CONTINUE_DIAGNOSIS`；04-tmp2系列全部关闭，
读缓存和writeback均形成有本地盘时的条件性生产增强。04-tmp3/04-tmp3b均已完成并关闭，其大块值
不覆盖256K七项基线；04-tmp3b没有新增可交付旋钮。
