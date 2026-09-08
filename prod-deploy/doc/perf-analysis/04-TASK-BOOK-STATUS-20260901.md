# 04阶段任务书现状

## 快照信息

```text
SNAPSHOT_DATE=2026-09-08
SCOPE=04阶段主线任务书、条件任务书和临时专项任务书
STATUS_SOURCE_PRIORITY=最新执行证据 > 任务书当前状态 > 04阶段计划书执行台账
CURRENT_ACTIVE_TASK=无；04-7在线A-B-B-A已完成并签STOP_NEGATIVE
NEXT_PREPARATION=04阶段不再扩测async_dio；已登记候选统一转05回归
```

本文只记录任务书当前进度、依赖和下一动作，不替代各任务书的实验合同，也不授予环境执行权限。
若本文与最新原始执行证据冲突，以最新执行证据为准。

---

## 一、整体状态一览

### ✅ 已完成（15项）

| 工作线 | 任务书 | 当前状态 | 完成日期 | 预估时长 | 已有成果 | 尚缺内容 | 结论 |
|---|---|---|---|---|---|---|---|
| U1 版本锁定 | `u141b-*` + `u141d-*` | ✅ **已完成** | 2026-08-31 | 剩余`0` | `REPLACE_APPROVED`；锁定 exact patched v1.4.1，MD5 `24fae085...`；stock v1.4.1继续排除 | 无 | patched v1.4.1 七项均未检测到材料性退步，正式替代 v1.3.1 作为交付基线；社区原版 v1.4.1 因 randwrite 崩塌（~551 MiB/s）排除 |
| 临时调优：randrw readahead | `04-tmp-randrw-readahead-residual-tuning.md` | ✅ **全部完成；生命周期已关闭** | 2026-09-01 | 剩余`0`；Phase II约`10.5 h`（12 cell，avg `52.5 min/cell`，对象排水主导；fio仅约`7 min/cell`） | RUN `20260831-231629`完成12/12 cell；READ/WRITE效应`+1.62%/+1.64%`，CI上界`+3.21%/+3.28%`均低于5% | 无 | 关闭预读对 randrw 收益仅 +1.6%，远低于 5% 材料线；保持默认 readahead |
| 临时备选：本地读缓存 | `04-tmp2-juicefs-local-read-cache-stability-canary.md` | ✅ **已完成；生命周期已关闭** | 2026-09-02 | 剩余`0` | RUN `20260902-133433`四轮+POST-A通过；A=`3713.56`、B=`36490.02 MiB/s`，热集机制信号强 | 缓存合同未闭合：R02仍填充`19.51 GiB`，热点在页缓存而非NVMe | 签 `CACHE_SCREEN_EVIDENCE_INVALID`；热集信号强但不交付固定生产配置 |
| 临时备选：读写缓存容量曲线 | `04-tmp2b-juicefs-read-write-cache-capacity-curve.md` | ✅ **已终止并关闭；证据INVALID** | 2026-09-03 | 剩余`0`；完成6个读点及1个写点后安全终止 | 六个读点轮内稳态；mseqread=`3104/3293/3437`，randread=`3892/2645/3815 MiB/s`；读曲线不单调 | `randwrite-c16`排空残留112 blocks/29.36 MB并持续ENOENT | 签 `CACHE_CAPACITY_CURVE_INVALID`；writeback 生产决策以04-tmp2e为准 |
| 临时订正：randread缓存驻留 | `04-tmp2c-randread-cache-residency-curve.md` | ✅ **已完成；工程机制确认；环境关闭** | 2026-09-03 | 剩余`0`；7个只读cell约`37 min` | C16/C32命中`95.83%/~100%`，约`34.5 GiB/s`，Ceph RX降至`~0` | 预注册drops硬门使正式曲线INVALID | 确认"热集近全驻留才有材料收益"；不交付固定容量 |
| 临时订正：交付配置读缓存曲线 | `04-tmp2d-production-aligned-read-cache-curve.md` | ✅ **已完成；14/14有效；环境关闭** | 2026-09-03 | 剩余`0`；实际约`2.5 h` | A0漂移`0.87%/0.16%`；C200 mseqread/randread=`34.83/36.53 GiB/s` | 生产最小全驻留余量位于100%--200%之间 | 读缓存有稳定材料级收益：75%缓存带宽+173%/+233%；带宽随缓存超线性增长，75%为拐点 |
| 临时订正：writeback容量曲线 | `04-tmp2e-writeback-capacity-curve.md` | ✅ **W16硬失败；环境已关闭；条件性交付** | 2026-09-03 | 剩余`0`；修正容量W16约`50 min`，失败恢复约`30 min` | 16 GiB backing实际Available`15.53 GiB`；前90秒约`2770.80 MiB/s`；900秒后残留`2 blocks` | 无；W32--W128按早停合同取消 | `W16_WRITEBACK_DRAIN_FAILURE`否决W16容量档，不否决突发吸收；条件性生产增强 |
| 临时订正：writeback前台容量曲线 | `04-tmp2g-writeback-foreground-bandwidth-capacity-curve.md` | ✅ **已完成；环境关闭；证据持久化** | 2026-09-05 | 实际约`2.5 h`，五格及逐格恢复 | fio active-I/O相对W20锚：W32/W64/W128=`+25.33%/+45.69%/+46.92%` | 墙钟主口径受W64额外25.65s前台开销影响而不单调 | active-I/O容量信号确认，约64GiB后平台；墙钟曲线`RESOLUTION_INSUFFICIENT` |
| 临时对标：竞品大块单流 | `04-tmp3-competitor-large-block-sequential-benchmark.md` | ✅ **RUN `20260904-095827`已完成；12/12有效；环境关闭** | 2026-09-04 | 剩余`0`；本L1已结束，不自动执行L2 | R读臂`2614.08 MiB/s`(+65.27%)；F写臂`+10.60%`，方向一致 | 可选L2须另立任务 | 四个竞品披露目标均未达；R是强L1信号，F写具确认资格；不覆盖256K七项基线 |
| 临时对标：竞品I/O路径对齐 | `04-tmp3b-competitor-large-block-io-path-alignment.md` | ✅ **RUN `20260904-132417`完成；环境关闭；归因已复审订正** | 2026-09-04 | 剩余`0` | RA32双配对`+9.74%/+13.80%`；async约`0%`；B4/RA8较B256/RA8低约34%，但GET在途量约`11.5→2.3` | B4固定RA8同时改变对象并发；S2W01恢复流程缺阶段标记 | 04-tmp3c已证明B4下降主要是RA8并发不足；S2W01是恢复误判；04-tmp3d已确认对象层有余量 |
| R1a PG自然布局 | `04-1-randread-pg-layout-feasibility-and-isolated-pool-ab.md` | ✅ **已结束；环境收口；BLOCKED** | 2026-09-01 | 剩余`0` | RUN `20260901-125124`完成32→64→128：`I_primary=1.3125→1.21875→1.21875`；测试Pool/rule已删除 | 无；结论并入04-1b | CRUSH分裂PG不改变primary比例；`R1_FEASIBILITY_BLOCKED` |
| R1b 同池Primary工程对照 | `04-1b-randread-explicit-primary-steering-ab.md` | ✅ **已完成；生命周期已关闭** | 2026-09-02 | 剩余`0` | N=`3467/3438`、S=`3920/3929 MiB/s`，提升`+13.67%`，但仅达6250的`62.79%`；证据`558/558 OK` | 缺`I_op`和严格同挂载八轮正式效应 | `R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET`；作为新Pool架构候选保留 |
| Z0 阶段收尾 | `04-6-stage04-final-capacity-and-tuning-exit-decision.md` | ✅ **RUN `20260903-214003`完成；环境与证据闭合** | 2026-09-03 | 剩余`0` | 9/9 cell通过；mseqwrite=`SERVICE_PLATEAU_IDENTIFIED`（六OSD盘P50均100%）；mseqread仍`PARTIAL_SCALING`，randrw漂移约`8.2%` | mseqread/randrw未闭合；后续诊断由04-6b承担 | 未发现新可交付旋钮；签`STAGE04_CONTINUE_DIAGNOSIS`；mseqwrite仅当前范围内闭合 |
| A1 fresh归因 | `04-2-hcl-native-vs-nested-attribution.md` | ✅ **已完成；生产与证据生命周期已关闭** | 2026-09-02 | 剩余`0`；RUN `20260902-160000`完成H0/H1与C/L八臂 | C/L效应`-4.54%`、`epsilon=8.45%`；H漂移`96.70%` | 无必做补测 | `A1_CL_RESOLUTION_INSUFFICIENT`；nested-loop非主要瓶颈，fresh收益不可固化 |
| M1 写架构审计 | `04-4-metadata-transaction-options.md` | ✅ **已完成** | 2026-08-30 | 剩余`0` | 报告签`M1_SINGLE_OPTION_ONLY`；仅O1"同inode跨chunk metadata batch"具材料上界 | 无 | 唯一候选metadata batch（T2 conditional）；保留结论，不进入原型 |

### 近期完成（7项）

| 工作线 | 任务书 | 当前状态 | 预估时长 | 已有成果 | 尚缺内容 | 结论 |
|---|---|---|---|---|---|---|
| 临时订正：BlockSize×RA解耦 | `04-tmp3c-blocksize-readahead-concurrency-decoupling.md` | ✅ **RUN `20260904-165911`完成；环境关闭** | 实际环境执行约`20 min`，另有脚本修复和证据回传 | B4/RA32较相邻RA8提升`73.60%/77.55%`；在途GET约`2.33→4.54--4.59` | 6/6 cell、双锚、机制指标和恢复门通过 | 原B4下降主要是RA8对象并发不足；B4/RA32登记L2候选；后续04-tmp3d已确认对象层有余量 |
| 临时归因：Ceph对象服务曲线 | `04-tmp3d-ceph-object-size-concurrency-service-curve.md` | ✅ **RUN `20260904-173955`完成；环境关闭** | 实际约`25 min`环境执行，另含离线准备与证据回传 | 4MiB QD8=`5403.20`、QD16=`6659.20 MiB/s` | 14/14点、唯一namespace canary及精确清理通过 | `OBJECT_BACKEND_HEADROOM_CONFIRMED`；对象层不是当前大块读屋顶 |
| 条件归因：FUSE/VFS流水线 | `04-tmp3e-juicefs-reader-fuse-request-generation-boundary.md` | ✅ **RUN `20260904-184259`完成；环境关闭** | 实际环境约`30 min`，另含离线准备/修复/证据回传 | libaio QD1→8为`1975→5278 MiB/s`，GET在途`4.32→15.07`；RA64双配对`0%/+8.82%` | 10/10 cell、首尾锚、机制指标和UUID清理闭合 | `APPLICATION_QD_SCALABLE`；对象余量可由应用并发利用，RA64不登记为生产优化 |
| 临时订正：writeback排空归因 | `04-tmp2f-writeback-drain-attribution-and-capacity-curve.md` | ✅ **RUN `20260904-195053`完成；环境恢复；本地复算PASS** | 实际约`2.5 h`，含两次离线脚本修复和四档恢复 | 文件级根因确认；W20/W32/W64严格排空`82/100/355s`，W128在900s超时 | 仅剩报告审核后的远端证据清理，不影响结论 | `OBSERVED_MIN_SAFE_POINT=19.502GiB`；32GiB建议作为业务canary起点；128GiB不满足900s生命周期门 |
| 条件缓存：randrw共享预算 | `04-tmp2h-randrw-shared-cache-budget-allocation.md` | ✅ **28/28 cell完成；证据INVALID；环境关闭** | 最终RUN约`5.5 h`，另含前序脚本修复 | fio双方向与生命周期完整；R约`+1.3%--+9.0%`、W active-I/O约`+3.4%--+5.1%`；全部P点下降`7.7%--68.9%` | R/P runtime采样被同步目录遍历拖慢，可能同时形成配置相关干扰，不能正式归因 | `EVIDENCE_INVALID/NO_DECISION`；收尾见04-tmp2i |
| Z0b 端到端容量账与残余调优收口 | `04-6b-end-to-end-capacity-and-residual-tuning-closure.md` | ✅ **RUN `20260905-070441`完成；环境与证据闭合** | 剩余`0`；按首次候选即停，执行Phase A+B | R8对seqread/mseqread效应`+3.88%/+4.28%`均停止；F1对seqwrite两配对`+7.13%/+14.81%`且机制同向 | Phase C U300与Phase D randrw按合同取消；F1生产裁决转05 | `STAGE04_CLOSE_OPEN_STAGE05`；`max-fuse-io=1M`仅为seqwrite L1候选，不直接改生产配置 |
| 临时收口：竞品大块同步单流读 | `04-tmp3f-competitor-large-block-final-closure.md` | ✅ **RUN `20260905-125702`完成；环境与证据闭合** | 实际10个只读cell约`25 min`，另含证据复核 | fio bs、RA32、FUSE1M三方向均有L1信号；组合平均`2897.12`、最佳`2963.95 MiB/s` | 生产裁决须在05补七项非劣回归 | 最佳仅为竞品线`57.55%`；同步大块参数搜索关闭，后续只做04-tmp3g/3h两项能力补测 |

### 近期收口补证（6项）

| 工作线 | 任务书 | 当前状态 | 预估时长 | 要回答的问题 | 下一步 | 结论边界 |
|---|---|---|---|---|---|---|
| 条件缓存收尾：采样干扰消除 | `04-tmp2i-randrw-cache-sampler-interference-closure.md` | ✅ **RUN `20260906-201646`完成；VALID；环境闭合** | 实际约`2.5 h`，5格及逐格恢复 | 修复采样器后P25相对插值A0仍下降`16.88%`；旧/新P25仅差`-5.44%` | 无；P50/P75按预注册早停取消 | `NO_MATERIAL_MIXED_CACHE_CANDIDATE`；共享配额线关闭，纯读/纯writeback既有结论保留 |
| 竞品补测：16MiB异步写 | `04-tmp3g-competitor-large-block-async-write-closure.md` | ✅ **RUN `20260906-165126`完成；VALID；环境闭合** | 实际约`0.5 h`（不含脚本修复） | QD1/2/4=`1349.73/1154.20/1100.98`，QD8=`957.90/997.27 MiB/s` | `WRITE_ASYNC_TARGET_NOT_MET`，停止扩QD | 写侧async_dio从QD1即显著退化；04-tmp3e异步读收益不能外推到写 |
| 竞品缓存：原四命令全越线容量 | `04-tmp3h-competitor-four-command-client-cache-capacity.md` | ✅ **RUN `20260906-172359`完成；环境闭合** | 实际约`1.5 h`（含两次安全续跑修复） | 四档100%缓存命中，fio读仍仅`2744--2803 MiB/s`；fio写最佳`2866 MiB/s` | 无；cp同盘端点数值不作竞品比较 | `NO_VERIFIED_CACHE_BUDGET_LE_128G`；容量不是同步单流读限制，停止扩容 |
| 竞品缓存：RA32同步单流读最终收口 | `04-tmp3i-cached-sync-read-ra32-final-closure.md` | ✅ **RUN `20260906-222839`完成；VALID；环境闭合** | 正式RUN约`12 min`，另含离线准备和证据复核 | RA32两次=`3556.86/3670.35 MiB/s`，100%命中且Ceph RX约`0.003%`；同loop本地=`6846.36 MiB/s` | 无 | `BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET`；RA32仅比RA8高`4.89%`，缓存容量/RA同步收尾线关闭 |
| 条件缓存补证：randrw纯读缓存容量曲线 | `04-tmp2j-randrw-read-cache-capacity-curve-retest.md` | ✅ **RUN `20260907-155057`完成；VALID；环境闭合** | 正式矩阵约`80 min`，另含离线准备与证据持久化 | 五档效应`+5.62%/+3.95%/+9.82%/+11.07%/+14.84%`；A0漂移`5.03%` | 无；96 GiB按预注册规则为最小平台档 | `READ_CACHE_96G_L1_CANARY_CANDIDATE`；不重开writeback/混合配额线 |
| 条件归因：randrw缓存同步停顿/async_dio | `04-7-randrw-cache-stall-attribution-and-async-dio-screen.md` | ✅ **RUN `20260908-095000`完成；VALID；环境闭合** | 在线约`45 min`，另含离线准备与证据复核 | B/A两配对方向均值`-11.45%/-13.03%`；同步无记录负担下降`75.53%/100%`，但总延迟上升`12.83%/14.85%` | 无 | `STOP_NEGATIVE`；确认同步DIO路径参与停顿，但`async_dio`以吞吐退化换平滑，不进入生产 |

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
| `04-tmp2g-writeback-foreground-bandwidth-capacity-curve.md` | ✅ `COMPLETED / ACTIVE_IO_SIGNAL / WALL_RESOLUTION_INSUFFICIENT / ENVIRONMENT_CLOSED` | 实际约`2.5 h` | 固定每格总写入128GiB，测W20A/W32/W64/W128/W20B前台带宽 | 五格均安全排空；active-I/O为`2734/3311/3849/3882/2550 MiB/s` | **已关闭**；确认容量收益约64GiB后平台，整命令墙钟受W64启动开销影响不单调 |
| `04-tmp3-competitor-large-block-sequential-benchmark.md` | ✅ `COMPLETED / VALIDATED_L1_SCREEN / ENVIRONMENT_CLOSED` | 剩余`0` | 按竞品披露的cp与16M/20M单流fio口径测当前配置，并筛选有限的大块适配参数 | RUN `20260904-095827` 12/12 cell通过；R读`+65.27%`，F写`+10.60%`，W对F无增量 | **已关闭**；只保留可选精简L2候选，不覆盖256K七项基线 |
| `04-tmp3b-competitor-large-block-io-path-alignment.md` | ✅ `COMPLETED_L1 / ATTRIBUTION_CORRECTED / ENVIRONMENT_CLOSED` | 剩余`0` | 现有卷筛RA/async；fresh B256/B4初步比较 | B4/RA8读下降约34%，但对象在途量约`11.5→2.3`；S2W01第一次恢复已校验并unlink，后因端口迟退失败 | **已关闭但旧强结论撤销**；不能否定B4，不能称写持久性失败；续见04-tmp3c/3d |
| `04-tmp3c-blocksize-readahead-concurrency-decoupling.md` | ✅ `COMPLETED_L1 / ENVIRONMENT_CLOSED` | 剩余`0` | 同一B4卷做RA8/RA32 ABBA，并由B256/RA8双锚夹住漂移 | 两配对带宽`+73.60%/+77.55%`，在途GET约翻倍；锚漂移`-1.56%` | **因果闭合**；B4/RA32进入L2候选，生产配置暂不变 |
| `04-tmp3d-ceph-object-size-concurrency-service-curve.md` | ✅ `COMPLETED_L1 / ENVIRONMENT_CLOSED` | 剩余`0` | 绕过TiKV/FUSE，以唯一RADOS namespace测256KiB/4MiB×QD1--32 | 4MiB QD8/16=`5403/6659 MiB/s` | `OBJECT_BACKEND_HEADROOM_CONFIRMED`；触发04-tmp3e |
| `04-tmp3e-juicefs-reader-fuse-request-generation-boundary.md` | ✅ `COMPLETED_L1 / ENVIRONMENT_CLOSED` | 剩余`0` | 后端余量下比较psync与libaio QD1--8，并筛RA64 | QD8=`5277.79 MiB/s`、在途GET=`15.07`；RA64无一致材料收益 | 异步QD可越过竞品线；同步单流受请求生成并发限制，RA64不交付 |
| `04-tmp3f-competitor-large-block-final-closure.md` | ✅ `COMPLETED / VALID / ENVIRONMENT_CLOSED` | 剩余`0` | 在既有B256只读资产上解耦fio bs、RA32和FUSE1M | 三方向双配对均为L1信号；组合平均`2897.12`、最佳`2963.95 MiB/s` | 最佳仅达竞品线`57.55%`；同步参数方向不再扩测，异步写与缓存能力分别转04-tmp3g/3h |
| `04-tmp2h-randrw-shared-cache-budget-allocation.md` | ✅ `COMPLETED / EVIDENCE_INVALID / NO_DECISION / ENVIRONMENT_CLOSED` | 最终RUN约`5.5 h` | 分离读缓存、writeback及二者共享预算三步，寻找各总空间档位下randrw最佳安全配置 | 28/28 cell完成；runtime采样硬门失败；全部P点显著低于A0 | **已关闭**；不登记共享配额候选，不为负向筛选立即重跑 |
| `04-tmp2i-randrw-cache-sampler-interference-closure.md` | ✅ `COMPLETED / VALID / NO_MATERIAL_MIXED_CACHE_CANDIDATE / ENVIRONMENT_CLOSED` | 实际约`2.5 h` | 去掉采样器配置相关干扰，以T128最少5格判断共享缓存是否值得升级 | 5/5 cell通过；P25 `-16.88%`、R `+12.32%`、W `+5.45%`；A0漂移`6.88%` | 共享配额线关闭；P50/P75按合同取消，不扩大矩阵 |
| `04-tmp2j-randrw-read-cache-capacity-curve-retest.md` | ✅ `COMPLETED / VALID / CURVE_COMPLETE / ENVIRONMENT_CLOSED` | 正式矩阵约`80 min` | 用低干扰采样器重测randrw纯读缓存32/64/96/128/256GiB有效曲线 | 五档效应`+5.62%/+3.95%/+9.82%/+11.07%/+14.84%`；A0漂移`5.03%` | 96GiB为128GiB热集的最小平台L1 canary候选；无缓存基线不变 |
| `04-7-randrw-cache-stall-attribution-and-async-dio-screen.md` | ✅ `COMPLETED / VALID / STOP_NEGATIVE / ENVIRONMENT_CLOSED` | 在线约`45 min` | 在P25合同下只改`async_dio`执行A-B-B-A，判断同步停顿能否转化为生产收益 | 同步无记录显著减少，但两配对带宽下降`11.45%/13.03%`、总延迟增加`12.83%/14.85%` | 候选关闭；不启用`async_dio`，不追加L2或容量/QD矩阵 |
| `04-tmp3g-competitor-large-block-async-write-closure.md` | ✅ `COMPLETED / VALID / ENVIRONMENT_CLOSED` | 剩余`0` | 补齐16MiB单job `libaio` QD1/2/4/8写曲线及同步锚 | 两次QD8仅`957.90/997.27 MiB/s`，同步双锚平均`2578.69 MiB/s` | `WRITE_ASYNC_TARGET_NOT_MET`；关闭异步写QD方向，不影响异步读既有结论 |
| `04-tmp3h-competitor-four-command-client-cache-capacity.md` | ✅ `COMPLETED / NEGATIVE_FIO_BOUND / ENVIRONMENT_CLOSED` | 剩余`0` | 原四条竞品命令不变，测32/64/96/128GiB缓存预算下全部越线的最小已验证档 | 四档fio读均100%命中但仅`2744--2803 MiB/s`，写最佳`2866 MiB/s` | `NO_VERIFIED_CACHE_BUDGET_LE_128G`；cp同盘结果只作工程观察 |
| `04-tmp3i-cached-sync-read-ra32-final-closure.md` | ✅ `COMPLETED / VALID / ENVIRONMENT_CLOSED` | 剩余`0` | 在T64下用RA8/RA32 ABBA补齐热缓存同步单流最佳已知参数，并测同loop本地直读 | RA32平均`3613.61 MiB/s`、比RA8高`4.89%`；本地直读`6846.36 MiB/s` | `BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET`；目标差`29.83%`，同步单流缓存参数搜索关闭 |

04-tmp2至04-tmp2d均已完成并关闭环境。04-tmp2d已用交付配置形成有效读缓存容量曲线；
04-tmp2e已用修正后的16 GiB W16重验并复现staging排空硬失败；04-tmp2g随后用固定128GiB写量
完成20/32/64/128GiB五格订正，active-I/O容量信号确认且约64GiB后平台，环境已关闭。
该硬失败否决W16容量档，但前段突发吸收和旧20 GiB canary排空支持writeback作为有充足本地空间时的
条件性生产增强；不改变无缓存基线。
04-tmp3与04-tmp3b的原RUN均已结束并关闭环境，但后续源码和raw复审发现04-tmp3b的BlockSize比较
把RA固定为8MiB后，同时把B4可预读对象数压到2个；它只否定`B4+RA8`，不能否定B4。S2W01第一次
恢复已通过size/hash并由脚本主动unlink，随后因metrics端口迟退退出，第二次恢复缺阶段标记才误报
文件缺失，因此不构成持久性异常。04-tmp3c/3d是对这两个归因缺口的最小订正，不覆盖256KiB七项基线。

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
  → 04-6 已完成：mseqwrite服务平台已离线补证；因mseqread部分扩展/randrw漂移签STAGE04_CONTINUE_DIAGNOSIS
       → 04-tmp3 已完成：大块direct读R臂为强L1信号，写F臂具确认资格，不补写04-6的架构裁决
            → 04-tmp3b 已关闭但归因订正：B4/RA8混入对象并发变化；S2W01为恢复状态机误判
                 → 04-tmp3c 已完成：RA32恢复对象并发，B4/RA32成为L2候选
                      → 04-tmp3d 已完成：4MiB QD8/16越过竞品线/项目目标
                           → 04-tmp3e 已完成：异步QD可利用对象余量，RA64无一致材料收益
                                → 04-tmp3f 已完成：同步入口三项L1信号闭合，最佳仍只达竞品线57.55%，停止同步参数搜索
                                     ├→ 04-tmp3g 已完成：写侧async_dio随QD增加持续退化，未达竞品线并关闭
                                     └→ 04-tmp3h 已完成：四档100%读命中仍未过fio读线，容量方向关闭
                                          → 04-tmp3i 已完成：RA32热缓存仅3614MiB/s，同loop本地6846MiB/s，RA/容量方向最终关闭

04-tmp2d/2g 已分别确认读缓存与writeback机制
  → 04-tmp2h 已关闭：28/28 cell完成，但R/P采样覆盖硬门失败；混合P点均显著退步，无生产候选
       → 04-tmp2i 已完成：T128五格确认P25仍退步16.88%，旧采样器不解释负收益，共享缓存线关闭
            → 04-tmp2j 已完成：纯读缓存五档有效曲线闭合，96GiB为128GiB热集的最小平台L1 canary候选
```

04-2已完成，04-3a/04-3b架构研究挂起。04-tmp2至04-tmp2h均已关闭；04-tmp2h因R/P缓存采样
覆盖不足签`EVIDENCE_INVALID/NO_DECISION`，其全部混合点虽显著退步但只能作为描述性筛选信号。
04-tmp2i已用T128五格排除采样器干扰：CORE采样最大间隔约1.03秒，P25仍下降16.88%，
故签`NO_MATERIAL_MIXED_CACHE_CANDIDATE`，P50/P75按早停合同取消，不重跑原28格。
04-tmp3至04-tmp3i环境均已关闭：同步参数搜索停止，异步写QD方向已证伪；04-tmp3h确认
32--128GiB容量不能令原四命令全部越线，04-tmp3i进一步确认RA32热缓存同步单流仍只达目标70.17%。
04-tmp2i也已独占执行并关闭环境。04-tmp2j随后完成8格有效重测：五档相对插值A0效应为
`+5.62%/+3.95%/+9.82%/+11.07%/+14.84%`，A0漂移`5.03%`，按合同登记96GiB最小平台；
这是有本地NVMe时的L1 canary候选，不直接替换无缓存基线。
04-6签`STAGE04_CONTINUE_DIAGNOSIS`，
后续mseqread/randrw诊断另立最小任务，不重跑04-6矩阵。

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
| ✅ 已完成并关闭 | 04-tmp2f | hardlink ENOSPC孤立rawstaging根因确认；W20/W32/W64通过，W128在900s超时；writeback维持条件性生产增强 |
| ✅ 已完成并关闭 | 04-tmp3 | RUN `20260904-095827` 12/12有效；R读强L1信号，F写具确认资格，不自动升级L2 |
| ✅ 已完成并关闭、归因已订正 | 04-tmp3b | RUN `20260904-132417`原始执行和环境已闭合；B4/RA8下降混入对象并发坍缩，S2W01是恢复状态机误判，故BlockSize/写持久性旧强结论撤销 |
| ✅ 已完成并关闭 | 04-tmp3c | RUN `20260904-165911`；B4/RA32两配对提升74%--78%，对象在途量约翻倍；当前生产配置不变 |
| ✅ 已完成并关闭 | 04-tmp3d | RUN `20260904-173955`；对象层4MiB QD8/16越过两条目标线；namespace归零 |
| ✅ 已完成并关闭 | 04-tmp3e | RUN `20260904-184259`；libaio QD8=`5277.79 MiB/s`越过竞品线，RA64双配对未过10%门 |
| ✅ 已完成并关闭 | 04-tmp3f | RUN `20260905-125702`；bs20M、RA32、FUSE1M均有一致L1信号，组合最佳`2963.95 MiB/s`但未达竞品线；同步参数搜索不再扩测 |
| ✅ 已完成并关闭、证据无效 | 04-tmp2h | RUN `20260906-090701` 28/28 cell与生命周期完成；采样器同步扫描导致R/P覆盖硬门失败；全部混合点相对A0下降7.68%--68.85%，不登记候选且不立即重跑 |
| ✅ 已完成并关闭 | 04-tmp2i | RUN `20260906-201646`五格有效；P25相对插值A0下降16.88%，R提高12.32%，W提高5.45%；共享读写缓存配额无候选 |
| ✅ 已完成并关闭 | 04-tmp2j | RUN `20260907-155057`八格有效；纯读缓存五档效应`+5.62%/+3.95%/+9.82%/+11.07%/+14.84%`；96GiB为最小平台L1 canary候选 |
| ✅ 已完成并关闭 | 04-7 | RUN `20260908-095000`四格有效；`async_dio`减少同步无记录区间但带宽材料退化`11.45%/13.03%`；签`STOP_NEGATIVE`，环境闭合 |
| ✅ 已完成并关闭 | 04-tmp3g | RUN `20260906-165126`；QD8两次仅`957.90/997.27 MiB/s`，`WRITE_ASYNC_TARGET_NOT_MET`；环境闭合 |
| ✅ 已完成并关闭 | 04-tmp3h | RUN `20260906-172359`；四档fio读100%命中仍仅`2744--2803 MiB/s`，`NO_VERIFIED_CACHE_BUDGET_LE_128G`；cp同盘数据不参与对标 |
| ✅ 已完成并关闭 | 04-tmp3i | RUN `20260906-222839`；RA32热缓存同步读平均`3613.61 MiB/s`，仅达竞品70.17%；同loop本地直读`6846.36 MiB/s`；环境闭合 |
| ✅ 已完成并关闭 | 04-6 | 9-cell与恢复闭合；mseqwrite=`SERVICE_PLATEAU_IDENTIFIED`，无新生产旋钮；mseqread/randrw未闭合，严格裁决`STAGE04_CONTINUE_DIAGNOSIS` |
| ✅ 已完成并关闭 | 04-2 | C/L效应低于当前分辨力；H锚点严重漂移；生产恢复已签收 |
| ❌ 已废弃 | 04-5 | 源码原型无法在当前交付周期内直接用于生产，不再执行 |

当前剩余工作量不能简单按“还有几份任务书”计算：

- 04-1b已结束；若决定生产化，只为目标新Pool另立变更/canary，不复用本任务RUN或映射；
- 04-6已完成；frozen raw离线补证已闭合mseqwrite服务平台，但mseqread部分扩展和randrw状态债务仍不等于全部项目已证明数学架构上限；后两者仅在需要严格闭环时另立最小诊断；
- 04-2已完成；04-3a/04-3b即使归因成功也不能直接产生当前生产配置，现已挂起且不再占用准备或维护窗口；
- 04-5已废弃，原估被动插桩`4--7人日`、完整原型`17--30人日`的研发投入不再发生；
- 04-tmp2b已按写回硬门停止，04-tmp2c已完成机制订正，04-tmp2d已完成交付配置读缓存曲线；
  04-tmp2e已在W16排空硬失败后关闭；04-tmp2f进一步确认其根因为hardlink ENOSPC后孤立
  rawstaging，并完成20/32/64/128GiB工程曲线：前三档通过、128GiB在900秒超时。04-tmp2h已完成
  28格但因R/P采样覆盖不足签证据无效；04-tmp2i已用T128五格排除采样干扰，P25仍下降16.88%，
  因此关闭共享配额线且不升级L2；既有writeback仍只作为独占文件、低占空比
  且受监控场景的条件性增强。
- 04-tmp3c已完成并订正B4/RA耦合；04-tmp3d确认对象后端具有目标余量并已关闭环境；
  04-tmp3e确认应用异步QD可利用该余量，RA64无一致材料收益；04-tmp3f进一步闭合同步入口的
  bs/RA/FUSE候选，最佳仍未达竞品线；04-tmp3g进一步确认写侧异步QD不能复用读侧收益并已关闭。
  04-tmp3h已确认32--128GiB缓存无法令原四命令全面越线；04-tmp3i又确认RA32无法关闭同步单流差距，
  不改变无缓存交付基线。

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
不再把A1列为待准备任务。04-6已完成并签`STAGE04_CONTINUE_DIAGNOSIS`。04-tmp2至04-tmp2h已关闭；
04-tmp2h因采样覆盖硬门签证据无效，04-tmp2i已用T128五格完成共享配额最终收尾；未登记
共享配额候选。04-tmp2j已用低干扰采样闭合纯读缓存五档曲线，并登记96GiB最小平台L1 canary；
读缓存和writeback仍只形成有本地盘时的条件性生产增强。04-tmp3/04-tmp3b的执行均已关闭且不覆盖
256KiB七项基线；04-tmp3b的B4与持久性旧强结论已撤销。04-tmp3c已确认B4需要匹配RA32恢复对象
并发，04-tmp3d已证明对象层能够越过两条目标线；04-tmp3e进一步证明应用异步QD4--8可调用这部分
余量，但RA64不是有效生产旋钮。04-tmp3f已停止同步大块参数搜索，04-tmp3g已证伪写侧异步QD；
04-tmp3h已完成并关闭容量扩展方向，不重新打开04主线，也不直接修改无缓存生产交付配置。
