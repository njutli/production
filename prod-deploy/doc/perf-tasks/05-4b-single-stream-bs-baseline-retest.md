# 05-4b：单流顺序BS曲线与16M写候选纠偏复测

> 日期：2026-09-20；状态：`COMPLETE / READ_VALID_L1 / WRITE_VALID_L1_CONDITIONAL_MAINTENANCE_START / FUSE1M_L1_SCREEN_CONTINUE`；读RUN `20260920-133000`、标准写RUN `20260920-185100`、候选RUN `20260920-212500`均完成，完整原始包已持久化且独立复核通过，环境恢复。  
> 承接[05-4报告](../perf-report/05-4-single-stream-sequential-block-size-curves-20260920.md)：标准RUN `20260919-220327`，适配RUN `20260919-234336/235824`。执行方采集、审核方独立复算。

```text
05-3b：配置/采集共用修正、环境恢复与随机曲线
  → 05-4b【本任务】：正确基线单流曲线 → 完整16M写候选对照
     ├─ 稳定且候选有信号：登记专用挂载L1候选
     └─ 漂移/无材料信号：保留范围，停止该分支
  → 05-5b多流曲线 → 05-6统一对比
```

一句话：补齐正确8线程配置下的单流五档读写数据，复核16M写FUSE1M候选，不扩大调参范围。

## 〇、范围与共用依赖

原标准21格的数据完整性较好，但实际使用系统3线程配置；适配的 `+7.08%/+8.08%` 同样来自该背景，并以scrub结束后的另一次C2补格组合。旧值保留为历史观测，不能改标签当作8线程值。

本任务完整引用[05-3b §一三个补测任务共用的开跑合同](05-3b-random-bs-baseline-repair-and-retest.md#一三个补测任务共用的开跑合同)：正确私有配置及worker生效核验、日志语义、BlueFS与容量前置、固定身份、scrub所有权、安全恢复及生命周期。原05-3b写侧未完成本身不阻断本任务读侧；但本任务任何读/写阶段都须分别通过对应健康、容量和被动静默门。本任务不要求前序先取得理想带宽。

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=原05-4标准曲线与16M FUSE1M候选，仅作设计先验
MINIMUM_DECISION_SET=标准读10格、写11格；条件满足后16M写C1-T1-T2-C2四格
SCREEN_CONTINUE=正确配置、健康及日志通过；标准16M写两位置漂移≤10%才启动候选复核
SCREEN_STOP=安全/容量失败即停；位置漂移>10%停止对应写分支；候选无材料信号即收口
FORMAL_MATRIX=不自动升级L2或原七项非劣回归
STOP_AFTER_ANSWER=标准五档+候选取舍交付，不扩扫RA/buffer/uploads/卷BlockSize
MAX_PREP_BUDGET=复用共用修正，任务专属离线准备约30分钟
ESTIMATED_WALL_CLOCK=标准fio63分钟+候选12分钟；含检查/恢复约1.5—2.5小时
MAX_EXECUTION_BUDGET=3小时，不含独立环境修复
EVIDENCE_ROOT=/mnt/c/SunRise/test/05-4b/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-05-4b-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=仅任务私有挂载/进程及拥有的scrub flags；测试文件保留
```

## 执行收口附录（2026-09-20，supersedes conflicting execution clauses below）

### 写侧逐格维护修订（2026-09-20，supersedes本附录中“不要逐cell自动重置”）

用户已批准用与05-5b相同的标准化维护起点完成写曲线。首次写格前及每个180秒标准写格后，只对精确文件`/mnt/juicefs/test_dir/seqwrite/seqwrite.0.0`执行`juicefs compact --threads 1 <exact-file>`；不递归compact、不执行GC/删除/layout/卷池操作/服务停启或sudo写操作，且保持文件路径、inode、长度和mtime。

每次维护后连续三个30秒采样须满足：受控健康状态、6/6 OSD up/in、slow=0、RocksDB compact队列为0、对象数三点跨度≤8192且最小DB空闲≥17 GiB；格内2 GiB停止线保持。先做一个`4M-A`完整闭环，通过后才批量执行余下标准写格。结果标记`CONDITIONAL_MAINTENANCE_START`，维护耗时/回收量一并报告；若任一恢复门失败立即停止，不降低门槛。

16M/FUSE1M候选四格不自动随标准矩阵启动；只有标准11格完整、探针/位置漂移和容量恢复均通过后，再冻结同样的逐格维护协议与挂载切换顺序并单独执行。

本任务读侧不等待05-3b randwrite完成：在05-3b附录批准的单次定向维护及最多30分钟有界自然DB回收观察完成后，先执行本任务10个READ cells；与05-5b合计20个读格。启动读格的必要条件仍是健康、读容量和被动静默门通过，且不得与维护重叠。

随后才执行本任务11个WRITE cells。16M/FUSE1M候选为条件式4格，只有标准写矩阵、漂移和恢复门均满足才启动。不要在正式比较批次内compact或逐cell自动重置；若批准inter-batch维护，须使用统一预声明协议并建立新的state epoch，报告为conditional-maintenance start，不跨epoch给出精确BS效应。

本轮3小时为决策预算；自然DB回收观察另设最多30分钟上限。写前容量预算必须重新校准并计入报告§9暂态DB分配峰值的transient reserve，不能降低既有容量门；不足即停止并提交需另行明确批准的DB扩容方案。维护范围仅限已知16M顺序写资产，不碰读资产、不递归删除pool/volume内容，并保持逻辑内容和inode。

## 一、冻结负载与矩阵

正确基线为B256卷、FUSE256K、uploads150/downloads200/buffer300/cache0及私有 `ms_async_op_threads=8`，其余身份同05-3b。读文件 `/test_dir/seqread/seqread.0.0`，写文件 `/test_dir/seqwrite/seqwrite.0.0`，均准确32 GiB、不同inode；复用现有文件，不新建/截短。

fio沿用原05-4：`numjobs=1, psync, iodepth=1, direct=1, size=32G, time_based, runtime=180, refill_buffers, allow_file_create=0`；读 `rw=read`，写 `rw=write,end_fsync=1`。BS为 `64K/256K/1M/4M/16M`，完整JSON、1份bw日志、命令/rc/运行时间均保存。正式窗和含尾部同步的墙钟分列，不能把全部超时都解释为fsync；能从fio同步统计定位时再给fsync耗时。

| 方向 | 顺序 |
|---|---|
| 读，10格 | `256K-A → 64K-1 → 1M-1 → 4M-1 → 16M-1 → 16M-2 → 4M-2 → 1M-2 → 64K-2 → 256K-B` |
| 写探针，3格 | `4M-A → 64K-A → 4M-B` |
| 写续跑，8格 | `256K-A → 1M-A → 16M-A → 16M-B → 1M-B → 256K-B → 64K-B → 4M-C` |

每方向一个挂载，读先于写。写前/写后遵循05-3b的被动恢复检查；正式格之间不主动重置。停止线使用**正式窗** `D=|a-b|/((a+b)/2)`，不再由summary代替探针判据。探针4M前后D>10%、后续同BS重复或4M锚任一对D>10%，保留已测点并停止尚未执行的写格；读侧漂移超线只降级该档，不挑好值。每格检查健康/容量并记录后台状态。

## 二、16M写候选复核

标准写矩阵完整、16M两位置漂移≤10%且恢复通过后，在**一个预注册独立phase**内完成 `C1→T1→T2→C2`：C=FUSE256K，T=FUSE1M，仅此一项不同，四格均使用私有msgr8与同一32 GiB写文件，每格180秒。须重挂的臂保存worker身份，不按吞吐“筛好挂载”。

同时保留低扰动 `.stats` 的FUSE写请求大小计数前后差分，具体字段先从已存在指标核实；缺机制指标只限制候选归因，不伪造。计算 `e1=T1/C1-1`、`e2=T2/C2-1`、`epsilon=max(D(C1,C2),D(T1,T2))`、`M=max(5%,2epsilon)`；两效应同正且较小值≥M、请求粒度变化符合预期，记 `L1_SCREEN_CONTINUE`。否则登记无升级证据/分辨率不足，不宣称普遍无效。

任一格身份/健康/日志硬门失败，整组适配效应不签收；不从scrub之后或其他RUN抽一格补入。允许保留全部raw、修复原因后另作完整组，但本任务预算内最多一次完整新尝试。只有明确准备交付专用挂载时才另做L2/相关负载回归，此处不自动增加。

## 三、执行与交付

1. **步骤0：** 阅读05-3b引用的安全/证据skill、任务书指南§二.13—23和生命周期规范，确认具体口径。
2. **阶段0：** 复用共用Gate，任务专属只测1-job标准、四格适配及失败恢复路径；冻结部署脚本SHA，不能直接沿用旧配置默认值。
3. **阶段1：** 核验BlueFS/容量、身份/资产、8线程worker和scrub计划；批量执行读，再按探针执行写，条件满足才跑候选四格。阶段内不逐格请求指令。
4. **末步：** skill合规复核，恢复私有挂载和flags，增量持久化、SHA核验、独立复算，写 `doc/perf-report/05-4b-single-stream-bs-baseline-retest-<YYYYMMDD>.md` 并更新05计划/results-table。

报告逐BS列两个位置（4M写三锚）的summary、可信 `[15,175)` 正式窗、四子窗/CV、IOPS/clat及状态；候选四格完整来源必须可查。四态与非性能/性能门分离沿用05-3b；有限L1结果不能包装为生产非劣或架构上限。共用配置纠正后的新旧差异只作描述，不归因于线程数单因素。

**通用注意事项/红线：** 复用资产；不全局drop_caches、不执行未列明的GC/compact、不删建pool/卷、不改系统或服务、不影响157 Weka/K8s。仅可在正式比较批次外执行05-3b附录明确的定向写资产维护；不碰读资产或递归删pool/volume内容。新增sudo写或环境修复超出已有授权时先列具体方案；失败只恢复本任务拥有的状态，保留事故raw。证据每RUN唯一持久根、公共项一次、逐格增量，审核后才按精确清单清临时副本；证据清理不删除32 GiB测试文件。
