# 06-2b：range-flush 通知修复、正确性补证与突发性能验证

> 日期：2026-09-16；面向 GPT 负责设计/审核、执行方交原始证据。
>
> 状态：`PLANNED / OFFLINE_PREP_REQUIRED / ENVIRONMENT_NOT_AUTHORIZED`。本文件不是开跑授权。
>
> 承接：06-2 报告及 `/mnt/c/SunRise/test/06-2/20260916-091446/`。不追认、不拼接其无效性能样本。
>
> 范围：调查构建，`NOT_FOR_PRODUCTION`；与 06-3 配置筛选独立，环境负载必须串行。
> 2026-09-20承接边界：约21.7%历史缓存组合收益的复现/归因由06-3§七的`CACHE-BURST-21P7`单独跟踪。
> 本任务即使完成、失败或发现源码收益，也不关闭该项；两线不能互相替代。此次仅补文档，仍不授权执行。
>
> 规范：`TASK-BOOK-AUTHORING-GUIDE.md`、`TEST-DATA-LIFECYCLE-POLICY.md`；
> `skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`。

```text
06-1   缓存+writeback有前段加速，原合同未形成候选
06-2   scope缩小，但观测扰动/证据失效，不能否定优化方向
  ↓
06-2b  你在这里：修通知与范围问题 → 正确性门 → 无重仪表同轮比较
       ├─ 正确性失败：停止环境性能测试
       ├─ 无清晰收益：记录当前条件下无升级依据，收口
       └─ 有收益：登记调查候选；交付/上游合入另行决策
06-3   原六格已结束；§七继续跟踪约21.7%历史收益，尚未授权
```

一句话：**修正旧实现的可疑等待，不以错误实现的负向结果否定方向，用同源、低扰动对照回答修正版是否提高完整测试期间的平均带宽。**

## 〇、最小决策与预算

```text
EVIDENCE_LEVEL=L0_OFFLINE -> L1_SCREEN
SCREEN_SOURCE=06-2冻结源码/补丁、通知缺口与既有性能报告
MINIMUM_DECISION_SET=确定性回归+同工具链C/T构建+H0,C1,T1,T2,C2,H1
SCREEN_CONTINUE=正确性通过；两方向两对均超过本RUN材料线；无重建基座回归掩盖收益
SCREEN_STOP=正确性失败/证据不完整/无清晰收益/状态不可比；不扫U300或追加好看样本
FORMAL_MATRIX=本任务不自动升级L2；后续交付验证另行审批
ESTIMATED_WALL_CLOCK=离线修复/回归3--5h；环境语义smoke及六格2--3h；恢复异常另报
MAX_PREP_BUDGET=5h；超时先缩减工程方案，不搭新框架
MAX_EXECUTION_BUDGET=3h；达到预算停止新增负载，安全恢复不因预算中止
STOP_AFTER_ANSWER=六格及独立复核完成即收口；不自动扩到其他BS/七项/上游PR
EVIDENCE_ROOT=/mnt/c/SunRise/test/06-2b/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-06-2b-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=排空后卸载本任务挂载；隔离语义卷/缓存目录分别按精确计划审批
```

## 一、为什么补测、要修什么

源码依据统一为旧 RUN 的 `build/juicefs-v1.4.1-b-catchup-source.tar.gz`，
不是 `/mnt/c/SunRise/github/juicefs` 的 dirty 主干。行号以下均指归档源码。

1. `pkg/vfs/writer.go:232--235` 只有 `s.growing` 才通知 `commitcond`；旧
   `range-flush.patch` 却用它等待所有目标 slice，每100ms超时重查。固定大小覆盖写可能已提交，
   waiter仍靠超时返回。历史100ms直方图与此吻合，**需确定性回归证明，不先声明全部性能损失均由此造成**。
2. `rangeScope` 对已提交、已移出队列的 `dep` 仍扫描其 chunk，可能误纳入后续无关 slices。
   本轮同时检查并修正这条范围放大路径，不扩大到写缓冲供读等新架构。
3. 增长写才可能生成跨chunk依赖。固定文件覆盖写的依赖计数为零符合源码机制，不能单凭零值判闭包失效。
4. 旧计时遗漏 `h.Rlock` 前等待；所谓 lock-hold 时间又包含条件等待期间的解锁时间。
   不复用这两个量解释串行瓶颈，不再把并发等待和/墙钟并集代入 Amdahl。

**唯一性能问题**：修正版相对同源无调查仪表 baseline，能否提高256K randrw完整180秒负载的平均R/W？
修复正确性是前置条件；修复成功不等于性能有效，性能无收益也不等于整个randrw没有空间。

## 二、构建、正确性与负载合同

### 2.1 构建身份

| 标识 | 定义 | 用途 |
|---|---|---|
| H | 历史交付二进制，预期MD5 `24fae0852051c80ca571cb2f20275d46`，开跑前核实 | 防止只赢退化的重建基座 |
| C | 官方v1.4.1 `0b90c7db5a929ae6adc5faad948d108efd2c99f9` + 精确B-catchup，无旧调查仪表 | 因果对照 |
| T | C + 修正后的range-flush及必要通知/范围修复 | 唯一行为变量 |

复用旧溯源材料，不重做全仓考古；C/T同源码基座、Go工具链、依赖、构建参数，记录完整命令、
patch、SHA256/MD5/BuildID。不能从带仪表源码直接构建后声称“无仪表”。
测试注入、逐请求计时、全量accesslog和trace不得进入性能构建；新增诊断须分开运行。
H不可取得时停在就绪审查，不偷偷把C标成交付版；兼容性smoke不能证明性能等价。

### 2.2 必须补齐的定向回归

| 用例 | 断言，不以严苛耗时阈值代替 |
|---|---|
| 非增长覆盖写通知 | barrier确认waiter登记，再放行真实提交；虚拟超时未触发时因完成通知返回；旧补丁失败、修正版通过 |
| 通知竞态 | 提交早于waiter登记、多waiter、虚假唤醒、错误/取消/超时均不漏通知、不错误成功、不死锁 |
| 真实增长依赖 | 经实际写路径生成跨chunk多级依赖，目标读等待完整依赖与FIFO前缀，读回内容正确 |
| 范围排除 | 无依赖覆盖写不冻结无关chunk；依赖已提交且移出队列时不纳入其活跃无关后缀 |
| API语义 | 同/多handle、重叠/跨chunk读写、EOF/截断、fsync/close/copy_file_range保留原有正确性 |

测试须记录依赖生成、实际选中/冻结集合、提交顺序、读回期望，不仅检查人工构造集合。
宽松watchdog只防死锁；禁止把100ms改为1ms作为修复，也禁止删除读前一致性保障。
原 `Flush/FlushAll/Close/fsync/Truncate/CopyFileRange` 全量语义不能被范围化。
不要求跑与改动无关且依赖缺失的全套后端测试；但缺依赖/工具链失败不得写PASS，
必须落实上述直接相关回归。需要真实FUSE时仅用获准的隔离临时语义卷，不碰共享测试资产。

### 2.3 性能合同

复用06-1已冻结job：既有B256卷、128×1GiB完整非稀疏 `rw_test` 文件，
`randrw/rwmixread=50/bs=256K/libaio/numjobs=128/iodepth=128/direct=1/time_based/runtime=180`，
`fallocate=none/allow_file_create=0`、相同文件映射、`randrepeat=1/randseed=20260915`。
公共挂载为FUSE256K、buffer300、U150、max-downloads200、96GiB读缓存、writeback开、
upload-delay=0、free-space-ratio=0.20；不加cache-large-write/partial-only等新变量。
该缓存组合是机制复验基座，**不是06-1已经验证的最优配置**。

顺序 `H0 → C1 → T1 → T2 → C2 → H1`。核心C/T为ABBA，H只判断重建基座与真实交付件的差异。
三种构建的平均轮序位置均为3.5；这只抵消线性轮序偏差，不代表状态自动相同。
每格同样60秒纯读预热；预热结束还须过下节脏页/暂存恢复门，不能直接沿用06-1不对称起点。

## 三、全程端点、状态控制和裁决

### 3.1 主端点（用户2026-09-16确认的突发口径）

主值为**实际完整timed-I/O期间的完成字节/实际时长**，不是最快窗口、不是 `[15,175)`。
单个 `group_reporting` 组读取 `formal/fio.json` 的 `read.io_bytes/write.io_bytes`，
共同分母取该组读写 `runtime` 最大值（毫秒转秒）；组汇总不得再乘128，
也不得使用可能累加128个job时长的顶层 `job_runtime`。
以实际I/O起止、fio全文与128份per-job日志核对；实际180秒负载的完成拖尾必须计入分母，
不能固定除180，也不把启动、预热、事后staging排空混入分母。异常超时保留并单列，不能裁去慢尾。

保留重叠加权秒级曲线、`[0,180)`四个45秒分窗和180秒后的完成尾部；旧160秒值只作历史对照。
CV高、W4/W1低、排空较长**不是删除样本或否定突发收益的理由**。日志稀疏须区分真实无完成I/O
与采集丢失，禁止只保留128 job都有完成记录的高速秒；未能确认的区间标未知，不填零伪造。
详细字节积分/误差规则沿用新任务06-3 §二.1。旧统计skill中“summary只能旁证”在本任务由
上述完整时段端点明确覆盖；原始日志、实际起点、方向拆分和独立复算不省略。

### 3.2 起点与安全（必须先完成只读计划）

- 每格使用独立空缓存子目录、相同预热；预热后staging/pending/uploading均归零。
  从安静期记录宿主Dirty/Writeback基线；预热后恢复至 `Dirty ≤ 安静期P95+8GiB`、
  `Writeback ≤ 安静期P95+1GiB`，持续30秒。它们是起点可比门，不限制正式窗内正常缓存吸收。
  共置业务使基线无法解释时停下评审，禁止全局drop_caches、sync或改dirty内核参数。
- 每格前后记录对象数、TiKV延迟/compaction、OSD三指标、健康、缓存空间及业务指纹。
  默认被动cooldown，不自动跑共享卷GC/OSD compact，更不重启/重建集群；需主动恢复时先列
  精确范围和影响另行授权。等待不能被写成“已恢复相同RocksDB历史状态”。
- 起点恢复最多等待15分钟；超时不继续负载，不为获得好基线反复重挂。正式过程中触及
  容量/内存安全线仅停止本任务负载，保持挂载上传；安全线按现有设备余量在开跑前计划中冻结。
- 缓存仅使用经重新核实并批准的 `/mnt/jfs-cache/04tmp3/<本RUN子目录>`；排除md0/Weka/系统盘。
  `cache-size=96GiB`不限制rawstaging，空间预算须单列暂存、读缓存、文件系统预留和停止余量。
- scrub采用phase内受控暂停方案，须单独批准并精确恢复；已有运行的scrub必须先结束。
  除纯`OSDMAP_FLAGS`预期例外外，任何其他health异常不放行。默认禁止主动OSD compact。

### 3.3 判定

非性能门：身份/构建、正确性、完整字节/时长证据、fio与对象错误、空间/内存、健康和安全收口。
关键观测缺失只能限制相应归因；不得用“机制指标没有按预期改善”反向认定真实带宽无效。

对每方向算 `T1/C1-1`、`T2/C2-1`；
`ε=max(|C2/C1-1|,|T2/T1-1|)`，`M=max(5%,2ε)`，均取本RUN数据。
四个方向/位置效应均为正且不小于相应M，记 `SCREEN_CONTINUE`；否则保留逐值，
按方向不足/分辨率不足/无升级价值结束，不宣称普遍无效。ε≥5%仍须标记细效应分辨率不足；
不能把明显大于2ε的筛选信号抹去，也不能据此宣称精确生产效应。
另报H0/H1与C/T的完整平均值；若C明显低于H且T只恢复到H，不能称交付配置已获净收益。

若需诊断，仅在独立短探针中区分handle锁、writer锁、条件等待、元数据提交和实际读取；
probe不入性能样本。正式轮不强制新仪表、trace或Amdahl门；原生低频指标保持对称。

## 四、执行步骤与复用

- [ ] **步骤0**：执行前通读上述规范，以及 `TESTING-GUIDE.md` §1.3/2.2/3、
  `test-commands-reference.md` §8/9、`baseline-reproduction-skill.md` §2/3、长跑监控规范；
  确认本任务端点与“不自动共享GC/compact/drop_caches”是显式覆盖，不机械执行旧模板。
- [ ] **离线**：复用旧source archive、B-catchup、构建/P0脚本、`t06-2-gate3-semantic.sh`；
  修通知/范围并完成定向回归；复用 `t06-2-phase-a-coordinator.sh` 和 `t06-1` 采集/排空组件，
  只增加构建臂表与全程端点。不新建编排平台，不热改历史冻结脚本。
- [ ] **Gate 0**：新增路径语法/安全检查、旧补丁失败新补丁通过、完整字节统计/分组不重复、
  长尾不裁切、0完成与缺日志区分、排空失败不卸载、源码与二进制身份；新增缺陷记入fixture目录。
- [ ] **停点1**：只读inventory后回传精确计划，含六格预算、业务保护、缓存/语义卷、sudo写全集、
  scrub恢复与失败分支。用户确认后执行语义smoke及完整矩阵；矩阵内部不逐格请示。
- [ ] **停点2**：第二方复算结果；禁止自动扩参数或升级L2。
- [ ] **收口**：先保持挂载排空（连续三次确认rawstaging/pending为零），无缓存独立挂载抽样读回，
  再优雅卸载、核对健康/flags和固定资产、移除精确任务缓存及调查二进制；读回无EIO不等于内容校验。
- [ ] **末步**：skill合规自查、唯一证据持久化和一次性生命周期收口。无收益不追加无关验证。

## 五、交付、通用注意事项与红线

报告：`doc/perf-report/06-2b-randrw-range-flush-repair-and-burst-validation-<日期>.md`。
至少交source/patch/build身份、确定性回归、每格fio JSON/全文/128日志、秒级核心采样、实际命令、
起点/终态、排空/读回、append-only incidents、独立分析与manifest；公共文件一份、cell增量。
按 `TEST-DATA-LIFECYCLE-POLICY.md` 签收后才清远端证据；环境资产清理另列精确清单。
报告给出全部H/C/T数据、突发收益及其排空/资源代价，不把H历史绝对值当同轮对照；完成后更新results-table和阶段计划。
收口时同时引用阶段计划§十.1的`CACHE-BURST-21P7`当前状态；不得因为本任务结束而宣布缓存配置线
已穷尽或06阶段全部问题已解决，不把补丁收益与历史约21.7%观察增幅叠加。

通用注意事项引用GUIDE §二.1--23：单位MiB/s、R/W分报、固定资产、身份/实际命令、实际I/O起点、
对称预热、原始字节/日志、非性能门与性能端点分离、同轮平衡及漂移、脚本冻结、独立复核、
scrub所有权、增量持久化和精确清理全部保留。本任务只改上述明确声明的统计及恢复默认项；
不新增旧式6分钟挂载判档/挑挂载重试，不把无效RUN改名后拼接为有效样本。

红线：不影响157 Weka/K8s及其他业务；不碰既有 `/mnt/juicefs`；不重启、不动网卡/内核/md0；
不对共享卷format/layout/destroy，不改TiKV/Ceph/PG配置，不全局drop_caches；不直接读取未提交写缓冲。
sudo写操作须逐条确认；禁懒卸载、强卸载、模式kill和宽域删除。失败保留证据及未排空挂载，
已拥有的scrub状态仍优先精确恢复；不得为了收口删未上传数据。本轮新建任务书不构成任何执行授权。
