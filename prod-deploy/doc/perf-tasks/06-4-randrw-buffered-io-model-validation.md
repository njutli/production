# 06-4：randrw缓冲I/O（direct=0）独立模型验证

> 日期：2026-09-21；设计/审核：GPT，执行方在授权时确定。
> 状态：`COMPLETED / VALID_SCREEN / SCREEN_STOP / NO_CANDIDATE`。RUN `20260921-152622`已完成四格测试及安全闭环；正式结果见[06-4报告](../perf-report/06-4-randrw-buffered-io-model-validation-20260921.md)。
> 承接：[06阶段计划§十](../perf-analysis/06-randrw-cache-and-write-path-tuning-plan.md#十后续工作双主线与06-42026-09-21当前有效入口)、[架构问答](../perf-analysis/06-RANDRW-ARCHITECTURE-QA-20260918.md)、[06阶段状态](../perf-analysis/06-STAGE-STATUS-20260917.md)。历史归档仅复用资产身份、脚本组件和统计实现，不充当本轮性能对照。
> 规范：[任务书指导](TASK-BOOK-AUTHORING-GUIDE.md)、[数据生命周期](TEST-DATA-LIFECYCLE-POLICY.md)，以及`skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`。

```text
06-1/06-3  direct=1下缓存组合有观察信号，来源仍待确认
06-3§七   本周主线一：确认原组合收益，不被本任务替代
06-2b     本周主线二：源码修复及正确性/性能验证
   ↓ 独立应用模型；环境负载不得重叠
06-4      你在这里：相同挂载参数、每格新挂载、相同预热，direct=1/0四轮对照
          ├─ 有材料信号：记录缓冲I/O能力与资源代价
          ├─ 无信号/起点不可比：限定结论后停止，不扫更多参数
          └─ 需要产品对比：有方同direct=0合同另批补测
```

一句话：**验证应用允许使用内核页缓存时，当前256K randrw的全程读写带宽及实际请求路径变化；不将换I/O模型冒充原规格配置调优。**

## 〇、最小决策与预算

```text
EVIDENCE_LEVEL=L0_OFFLINE -> L1_SCREEN
SCREEN_SOURCE=06架构问答的页缓存假设；06-3现成资产/采集/统计组件
MINIMUM_DECISION_SET=同批、同挂载参数、每格新私有挂载的D1/B1/B2/D2；D为direct=1，B为direct=0
SCREEN_CONTINUE=完整R/W配对重复同向且超过本批材料线；仅登记模型候选，不自动交付
SCREEN_STOP=安全或证据失败、起点不可比、方向/分辨率不足；不追加高值样本
FORMAL_MATRIX=首批仅四轮；不自动扩BS/缓存容量/ioengine或竞品环境
MAX_PREP_BUDGET=1h目标；不足先缩减/复用，不搭新平台
MAX_EXECUTION_BUDGET=2h；安全排空与恢复不因预算中断
ESTIMATED_WALL_CLOCK=4×(60s预热+180s负载)=16min纯负载，含检查/恢复/审核约1--2h
STOP_AFTER_ANSWER=回答本模型当前表现即收口，竞品补测独立审批，不因此保留远端挂载
EVIDENCE_ROOT=/mnt/c/SunRise/test/06-4/<RUN_ID>/
REMOTE_RESULT_ROOT=/tmp/production/opencode-06-4-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=同步/排空后仅卸载本任务私有挂载，恢复自己拥有的scrub变化；不删固定数据集
```

## 一、问题、边界与解释

**主问题：固定预热和现有资源条件下，将direct=1改为direct=0，能否重复提高完整randrw平均R/W？**
辅助记录FUSE请求、对象流量、元数据及内存变化，用于解释是否减少了进入JuiceFS的请求；机制未采齐只限制解释，不抹去真实带宽。

- `direct=0`允许内核文件页缓存，并非启用JuiceFS磁盘读缓存、`--writeback`或FUSE的`-o writeback_cache`；首批后三者均不开。
- 固定128GiB数据集可能小于客户机内存，必须实测并记录MemTotal/MemAvailable。允许得到“宿主页缓存参与的整机性能”，不得称为Ceph持续吞吐或NVMe介质速率。
- 能减少读到VFS的次数，不代表进入VFS后的读不再flush；当前代码中，只要该inode仍有脏slice，
  读前whole-inode flush就会等待相关数据上传及元数据提交。`direct=0`只可能减少进入该路径的次数，
  不改变这项一致性语义；本批不修改任何读写一致性逻辑。
- 旧状态/问答中的“只横向、不做ABBA”原意是禁止混用direct=1历史口径。本任务明确采用**新RUN内的应用模型对照**，两侧共同固定预热和`invalidate=0`；可以说明本批模型变化，不能并入旧06任务效应或与有方历史direct=1算产品胜负。
- 预热为固定60秒，不宣称128GiB全热或100%命中；开关文件时内核/FUSE可能使缓存失效，观察实际行为，不为追求高值擅加keep-cache等参数。

## 二、固定合同与最小矩阵

### 2.1 两侧共同项

| 项目 | 合同 |
|---|---|
| 客户端 | 157；交付JuiceFS 1.4.1，预期MD5 `24fae0852051c80ca571cb2f20275d46`，现场重新核实；不使用调查构建 |
| 卷/文件 | 既有B256测试卷；`<私有挂载>/test_dir/rw_test.0.0`至`rw_test.127.0`，128×1GiB完整文件；验证UUID/META、inode/size/历史layout，不新建/截断/layout |
| 私有挂载 | 每格分别使用`/tmp/jfs-06-4-<RUN_ID>-<D1|B1|B2|D2>`；挂载参数完全相同，不动既有`/mnt/juicefs`。每格新挂载用于清除上一格FUSE页缓存的继承，不执行宿主全局`drop_caches` |
| 挂载配置 | 复用06-3的C配置：max-fuse-io=256K、buffer-size=300、max-uploads=150、max-downloads=200、cache-size=0；WB/CLW关，无`-o writeback_cache`和强制`direct_io` |
| fio固定参数 | randrw、rwmixread=50、bs=256K、ioengine=libaio、numjobs=128、iodepth=128、filesize=1G、size=1G、time_based=1、runtime=180、group_reporting=1 |
| 文件/随机合同 | filename_format=`<私有挂载>/test_dir/rw_test.$jobnum.0`、openfiles=128、allow_file_create=0、fallocate=none、randrepeat=1、randseed=20260915 |
| 缓存/确认语义 | **两侧均显式`invalidate=0`**、不启用pre_read/ramp_time；无O_SYNC、无周期fsync、end_fsync=0；写后针对这128个文件的同步另行计时，不并入前台主值 |
| 原始输出 | 实际完整job/命令、fio JSON及全文、rc、runtime、128份bw日志；per_job_logs=1、log_avg_msec=1000；如沿用lat日志则两侧相同 |

fio默认`invalidate=true`可能使预热失效，因此两侧显式关闭。libaio在缓冲I/O下可能不能实现设定队列深度；必须保留JSON `iodepth_level`及submit/complete/latency字段，不以设置128声称实际128，也不因此自动换io_uring。[fio官方说明](https://fio.readthedocs.io/en/latest/fio_doc.html)

### 2.2 四轮顺序与预热

| 顺序 | 标识 | direct | 定位 |
|---|---|---:|---|
| 1 | D1 | 1 | 当前直接I/O对照 |
| 2 | B1 | 0 | 缓冲I/O第一次 |
| 3 | B2 | 0 | 缓冲I/O第二次 |
| 4 | D2 | 1 | 当前直接I/O末尾对照 |

每轮正式负载前，均在该格新建的私有挂载、同一128文件上跑60秒`randread/direct=0/invalidate=0`，其余几何与种子同上，结果独立保留；不计入主值、不清全局页缓存。四格使用相同挂载命令；新挂载只复位本任务FUSE页缓存，不能声称清除了宿主、服务端或Ceph状态。
预热后核对健康及起点Dirty/Writeback，保存预热耗时、字节和FUSE计数；不得为了候选臂更热追加预热。
首次负载前120秒安静期冻结基线；每轮预热后及写后恢复均要求`Dirty≤基线P95+8GiB`、`Writeback≤基线P95+1GiB`连续30秒，并核对本挂载已注册的上传/缓冲指标无待完成写。未注册指标记NA，不能以宿主脏页较低代替定向fsync成功；这些门仅约束起点/恢复，不限制正式窗正常吸收。
轮后同步/恢复完成再进入下一轮。相同预热并不保证缓存内容完全相同，DIO写造成的失效属于模型行为；记录起点及轮内变化，不宣称复原了全部历史状态。

## 三、统计、证据与停止规则

### 3.1 性能端点

沿用06-3§二.1的全程口径：从`cells/<标识>/formal/fio.json`读取单group的`read.io_bytes`、`write.io_bytes`，共同分母为两方向`runtime`最大值/1000；换算MiB/s，不能再乘128或固定除180。
保留实际timed-I/O起止、启动差、0～180秒四个45秒分段及完成尾部；按重叠加权处理每job日志。稀疏日志不能用下一行速率填满空档；分窗无法可靠复算记未知，完整JSON主值另行审计。
本节显式覆盖旧指南的“只取160秒窗/summary仅旁证”；不裁慢尾，不因带宽/CV差删除结果。

逐方向报告`B1/D1−1`、`B2/D2−1`、各轮绝对值与组均值。沿用L1规则：
`ε=max(abs(D2/D1−1),abs(B2/B1−1))`，`M=max(5%,2ε)`；两对R/W均同向且达到各方向M才有升级价值。
这是本批材料线，不是置信区间；明显漂移时限制归因，不用ABBA声称已消除非线性状态差异。只赢低对照不等于可交付。

主值是应用前台平均R/W；事后定向fsync/排空及再次可用间隔单列，不将其称为完整持久化性能测试。
若前台值超过网络带宽，先对账RAM/FUSE/后端字节；有页缓存服务时可以是真实整机结果，不机械判假，也不宣称网络被突破。

### 3.2 最小证据分级

| 类别 | 来源/字段与用途 |
|---|---|
| CORE：必须 | 实际job、fio JSON/全文/128日志/rc/起止、卷/文件/挂载身份、health、df、内存/安全状态、定向同步结果及恢复记录 |
| MECHANISM：解释路径 | 复用约1秒轻量`.prom`和主机采样：FUSE读写次数/字节/延时，GET/PUT次数/字节，TiKV事务延时及pending-compaction，CPU/NIC、MemAvailable/Cached/Dirty/Writeback/swap |
| DIAGNOSTIC：按需 | 元数据成为主要嫌疑时再查region/事务尾延迟；本批不默认trace、pprof、源码逐请求计时或递归每秒扫描 |

指标名在inventory中实查，未注册记NA。FUSE字节可能包含预读/请求拆分，**不得直接用`1−FUSE读字节/fio读字节`声称精确页缓存命中率**；比较同窗请求变化并保留解释限制。
不把整个宿主Cached/Dirty都归于测试，也不将缓存命中等同于本地NVMe读取。

非性能门（身份、错误、完整主值、必要原始证据、安全/健康）与性能端点分开。状态沿用`VALID / EVIDENCE_INVALID / RESOLUTION_INSUFFICIENT / INCONCLUSIVE`；L1的VALID不等于生产签收。
缺臂/工程故障保留原始值和incident，不能补轮替换、换名拼接或开跑后换统计规则；机制指标缺失只限制对应机制解释。

## 四、执行步骤与安全

1. **步骤0：通读规范。** 重点核对SYSTEM-SAFETY§一/§二、TESTING-GUIDE§1.3/2.2/3、test-commands-reference§8/9、基线复现和长跑规范；本任务明确覆盖全局drop_caches、主动GC/compact、固定160秒主值和挑挂载重试模板。
2. **阶段0：最小离线适配及Gate。** 复用06-3已验证的资产/挂载/health/采集组件和`u141d-scrub-control.sh`，不改旧冻结证据。Gate覆盖direct开关、共同invalidate=0、四格同参数但各自新挂载、预热/正式日志分离、定向同步范围与失败不卸载，扫描明文凭据及sudo/全局操作。
3. **只读inventory和开跑前唯一安全审批。** 核实无其他测试负载、业务窗口、固定资产、FUSE缓存语义、MemTotal/MemAvailable、NUMA/CPU及fio版本；只记录，不修改内核/网络。将每个新增/sudo/全局动作、业务保护线、结果及挂载精确路径交审核，获准后方可运行。
4. **获准后连续执行四轮。** 若当前fio/kernel缓冲路径支持情况未知，可在批准计划中安排一次≤15秒、≤4个既有文件的兼容探针，不作性能样本；之后恢复起点。四轮不逐轮求批，不与06-3/06-2b或其他压测同时运行，不暗中换ioengine、缓存预算或预热。
5. **写后恢复与一次性裁决。** fio结束后保持挂载，按冻结的128文件清单逐文件fsync，记录rc/耗时，再确认客户端上传/缓冲及宿主Dirty/后端健康回到约定恢复门；不会把WB关闭时staging=0当成全部排空证明。不运行全局sync/syncfs；不同步业务文件。恢复后下一轮或最终优雅卸载，抽样直接读回仅证明可读，不冒充内容校验。
6. **末步：规范复核、状态恢复及持久化。** 恢复自己拥有的scrub变化并记录健康；独立复算主值，形成一个报告和一次生命周期收口，不因未有收益追加无关检查。

业务保护必须在计划中落实：128GiB热集之外保留业务内存和I/O余量，不能把全部MemAvailable当可用预算。预检至少256GiB MemAvailable、运行低于128GiB或出现swap-in/out/OOM即安全停止；若业务需要更高保护线，以更高值为准。记录现有业务CPU/I/O/延时或运维批准的独占窗口；业务出现异常即停止本任务负载，不以“业务进程仍在”宣称没有性能影响。
每次起点/排空最多等待15分钟，超时停止新负载、保留挂载及证据并上报，不强制卸载。停止由本任务登记的fio PID/starttime精确处理，不匹配名称杀进程，挂载继续完成在途写。
scrub采用单批受控暂停，仅在单独获准后由已有state控制器执行，先等正在进行的巡检结束；唯一health例外为该状态拥有的`OSDMAP_FLAGS`，其他WARN/异常PG不放行。预计窗口≤2h，恢复失败优先处理。
默认不GC、不主动compact、不重建集群；发现积压按06-3§7.2另批精确恢复，不执行旧脚本隐含的全卷动作。

## 五、竞品补测和交付

首批只测JuiceFS，得到模型结果即可关闭本批；有方不可用不阻塞本批，不在本任务中自动登录或改动其环境。
需要横向结论时另批同256K、50/50、128×1GiB、libaio/128jobs/QD128、direct=0、invalidate=0、60秒同种子预热和180秒的合同，记录客户端MemTotal/MemAvailable/CPU/NIC、实际队列深度、挂载/缓存/写确认语义及硬件差异。只比较同模型完整R/W，不能拿旧direct=1值或不同预热结果充当同条件数据。
不扫描六档BS、不默认打开JuiceFS读缓存/WB或内核writeback_cache；有新方向时先审核，不在本批叠加。

报告落点：`doc/perf-report/06-4-randrw-buffered-io-model-validation-<日期>.md`，更新阶段计划和results-table的**独立模型**栏，不覆盖direct=1基线。
一张表列D1/B1/B2/D2完整R/W、实际QD、FUSE/对象流量、RAM/Dirty及恢复代价；说明预热程度和适用范围、剩余未知即可。
公共身份/脚本/命令每RUN一份，cell仅增量raw；manifest/SHA、文件集合及可读性核验后才清远端证据。报告记录有效性、生命周期、incident、环境资产状态及唯一持久化路径，失败先保留后按精确清单收尾。

## 六、通用注意事项与红线

遵循GUIDE§二.1～23和生命周期规范：固定资产/身份、单位与R/W分列、实际起点、全部原始日志、同批对照、非性能门分离、离线Gate、冻结脚本、独立复核、授权及scrub所有权、增量持久化和精确清理。
本任务为L1模型筛选，不套用旧6分钟挂载判档、反复重挂挑样、全局冷态净化或每轮主动compact；完整时段口径及资源来源解释优先于旧稳态模板。失败停止新增负载但保留安全排空能力，已拥有的全局状态优先恢复。

**禁止影响157的Weka/K8s及其他业务；不动md0、网卡/RoCE、内核参数、服务或既有挂载，不重启。**
不改Ceph/PG/TiKV配置，不format/destroy卷、不删原数据文件，不建loop/tmpfs或缓存盘。sudo写必须逐条列目标和命令获确认，禁止嵌套SSH变量拼破坏命令、宽域删除、模式kill、懒/强卸载。
工程bug可在控制变量不变时离线修复并记incident；性能开始后必须中止受影响阶段，未经审核不得换RUN补样。文档计划不是环境执行授权。
