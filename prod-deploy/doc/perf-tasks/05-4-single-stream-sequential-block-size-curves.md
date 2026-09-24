# 05-4 任务书：单流顺序读写 BS 曲线与专用挂载筛选

> **2026-09-20追溯更新：** 实际执行遗漏本页要求的私有8线程配置，原“已完成”仅代表旧矩阵已执行；正确基线的重测及完整16M适配对照由[05-4b](05-4b-single-stream-bs-baseline-retest.md)承接，旧数值及原始证据保留。

> 状态：已完成；标准21格与16 MiB写入FUSE1M筛选已收口，见[正式报告](../perf-report/05-4-single-stream-sequential-block-size-curves-20260920.md)。  
> 上位计划：[05阶段计划](../perf-analysis/05-block-size-adaptive-performance-comparison-plan.md)；前序：[05-3报告](../perf-report/05-3-random-read-write-block-size-curves-20260918.md)。  
> 执行前遵守 `skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`、`skills/TESTING-GUIDE.md`、`doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` 和 `TEST-DATA-LIFECYCLE-POLICY.md`。

## 一、只回答什么问题

在现有 JuiceFS 1.4.1、B256卷和通用挂载配置下，`seqread`、`seqwrite` 的单流同步带宽如何随 fio BS 从64K变化到16M？若大 BS 有明确收益空间，是否值得使用**顺序负载专用**挂载参数？只采集 JuiceFS；有方的已归档数据留给05-6按相同 fio 命令核对，不能直接把不同负载口径相减。

```text
EVIDENCE_LEVEL=L1_SCREEN
MINIMUM_DECISION_SET=读5档正反各一次；写先做3格漂移探针，探针通过再补齐5档正反位置
STOP_AFTER_ANSWER=写探针或后续同BS锚点漂移>10%即停写矩阵；适配无材料信号即停参数筛选
MAX_PREP_BUDGET=约1小时；复用现有身份、fio采集和分析组件，不建新编排平台
MAX_EXECUTION_BUDGET=约4小时（fio纯负载约63分钟；另含门禁、fsync和恢复）

EVIDENCE_ROOT=/mnt/c/SunRise/test/05-4/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-05-4-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
ENVIRONMENT_ASSET_CLEANUP=仅精确收口本RUN私有挂载/进程并恢复本RUN改动的全局状态；不删除现有卷与测试文件
```

05-3写侧同配置256K从`2667.2`降至`486.3 MiB/s`（−81.8%），伴随对象数与TiKV待压缩量累积。它**不证明**05-4顺序写也会同样漂移，但足以要求先用短探针决定是否继续。读阶段先跑，避免写阶段改变其后端起点。

## 二、固定合同与开跑门

| 项 | 冻结内容 |
|---|---|
| 节点与二进制 | 157；`/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`。开跑时重新核验主机、可执行文件、Ceph FSID、META、卷UUID和BlockSize。 |
| 卷与挂载 | 既有`juicefs-prod`，`BlockSize=256K`；通用臂`--max-fuse-io 256K --max-uploads 150 --max-downloads 200 --buffer-size 300 --cache-size 0`，默认readahead、writeback关闭；同一私有`CEPH_CONF`（`ms_async_op_threads=8`）。先核对实际生效参数，不能仅凭计划字符串认定。 |
| 数据资产 | 复用已存在的`/test_dir/seqread/seqread.0.0`与`/test_dir/seqwrite/seqwrite.0.0`，各准确32GiB、不同inode；读文件全程只读，写文件仅允许覆盖写。只读核对真实挂载来源、inode、大小及非符号链接。资产不符则停，不自动layout。 |
| fio共同项 | `numjobs=1`、`ioengine=psync`、`iodepth=1`、`direct=1`、`size=32G`、`time_based=1`、`runtime=180`、`refill_buffers=1`；固定文件路径并禁止自动创建、截短及额外预分配。除了`rw`、`bs`和写侧`end_fsync`，不改变原V4单流口径。 |
| 读/写差别 | `seqread: rw=read`；`seqwrite: rw=write,end_fsync=1`。fio的timed-I/O带宽与末尾fsync耗时分别记录；不得把fsync造成的额外墙钟误算成180秒窗口带宽。 |
| BS档 | `64K,256K,1M,4M,16M`；原七项规格点分别是读256K、写4M。20M读仅作为未来匹配公开命令的独立附加点，**不**混入主曲线或自动执行。 |

执行前冻结并展示每档实际fio命令、当前挂载命令/身份、文件清单及一份只读健康计划。157上的WekaIO、K8s和其他业务资源不能因本任务受影响；有foreign fio、Ceph/PG异常、容量或客户端余量不足时不开跑。不得运行原`FULLBASELINE_V4_U141D.sh`的整套layout、`drop_caches`、GC或主动compact；**只复用其上述fio负载口径**。

## 三、矩阵和提前停点

### A. 纯读：10格

```text
256K → 64K → 1M → 4M → 16M → 16M → 4M → 1M → 64K → 256K
```

每档两个位置；首尾256K同时是原规格点和状态锚。同一读阶段保持卷、文件、挂载及参数不变，不额外预热、重建资产或改缓存。若首尾锚点或某档正反位置差异`>10%`，对应曲线仅报观测区间和漂移，不挑较高点作“最佳配置”。

### B. 纯写：先3格探针，合格才连续补齐

```text
探针：4M-A → 64K-A → 4M-B
通过后：256K-A → 1M-A → 16M-A → 16M-B → 1M-B → 256K-B → 64K-B → 4M-C
```

探针和续跑属于**同一RUN、同一既有文件、同一挂载**；无须重新layout或“清理到fresh”。比较`4M-A/B`的timed-I/O带宽与末尾fsync，记录每格前后Ceph对象数/stored、TiKV pending-compaction、OSD/PG健康及scrub重叠。漂移统一定义为`|B-A| / ((A+B)/2)`；`4M-A/B`带宽漂移`>10%`、fio超时/报错、fsync异常拖长或后端健康/业务门失败：**停止写矩阵**，保留探针及环境收口证据；不得继续跑满档位后以BS解释差异。探针通过后，执行方可一次跑完剩余8格；每格检查非性能安全门，若后续同BS两位置或`4M-C`相对前两锚点漂移`>10%`，停止尚未运行的写格。若写曲线最终仍漂移，报告哪些档位只有范围；需要可归因的同起点逐BS对照时另立设计，不在本RUN主动GC/compact或重测挑值。

两阶段之间重新检查环境起点；若读阶段后无法通过写前健康门，读结果可独立交付，写阶段暂停。读写使用不同资产，不以“写后再读”混淆效应。

## 四、可选专用挂载：只在标准曲线可解释时触发

1. 先从标准曲线及已有04-8、04-tmp3系列报告判断有无材料空间。4M `seqwrite`的FUSE1M专用收益已有正式证据，**不在此机械重做**；本任务只关注新BS点是否需要专用参数。16M等大块点若写侧已漂移，不启动适配。
2. 每方向最多选择**一个**大BS点，采用同文件同卷的`C→T→T→C`短配对，每格仍为180秒；只改变**一个**参数。写侧优先筛选`--max-fuse-io 256K→1M`；读侧先按实际FUSE请求拆分和现有证据选择`--max-fuse-io 256K→1M`或默认readahead→显式`8M`之一，不在一组内同时改变两项。是否启动及所选点/参数须在看适配数据前写入记录。
3. 两个配对效应同向、较小增益`≥5%`且超过同臂位置漂移，机制指标方向一致，才记`L1_SCREEN_CONTINUE`；否则停，不扫其他BS或`buffer/uploads/BlockSize`。L1只给专用配置候选；若要修改通用交付配置，另做原七项与256K规格点非劣回归。

## 五、证据、判读和安全收口

- 每格保存完整fio JSON/文本、单job秒级`--write_bw_log`日志（`--log_avg_msec=1000`）、实际命令、命令`rc/error`、fio实际timed-I/O起止和墙钟时间。按实际I/O起点算`[15,175)`正式窗、W1–W4/CV；另列 fio 180秒summary，不交叉比较。若日志覆盖/字节积分不可信，标`UNKNOWN/REVIEW`，保留summary但不伪造正式窗；补报IOPS、平均及P95/P99完成时延。
- 标准曲线列出各BS两个原始位置值、范围和同BS漂移；适配只列预注册配对。带宽低不是无效理由；身份、资产、fio错误、健康/资源越界或日志缺失才触发对应有效性降级。05-6跨系统比较仅限双方相同的fio参数和同统计栏；有方环境不可补测的档位保留`NOT_COMPARABLE`。
- 默认不改Ceph scrub flags；若长矩阵需要临时`noscrub/nodeep-scrub`，先只读输出原flags、FSID、正在运行的scrub及**精确sudo写命令**，另请用户授权；只在阶段边界切换，由既有状态驱动助手恢复本任务新增的flags并验证。未授权时保持原状，逐格记录scrub重叠，不边跑边切口径。
- 禁止全局`drop_caches`、设备/文件系统格式化、pool或卷删除、服务重启、宽作用域kill/`rm -rf`。任何脚本先离线扫描sudo写、危险命令、精确路径和无意自动创建；只针对改动路径做Gate 0。执行方可连续完成已授权阶段，仅在全局状态授权、探针失败或专用适配取舍处停。
- 先恢复本RUN拥有的挂载/进程和全局状态，再做证据收口。公共证据每RUN一份、轮次增量保存到`EVIDENCE_ROOT`；生成manifest并核对`PERSISTENCE_PASS`后才可按精确清单清理远端临时副本。测试文件、卷与其他环境资产不随证据清理。报告写入`doc/perf-report/05-4-single-stream-sequential-block-size-curves-<YYYYMMDD>.md`，列明有效性、停点、原始数据根、环境及证据生命周期状态。
