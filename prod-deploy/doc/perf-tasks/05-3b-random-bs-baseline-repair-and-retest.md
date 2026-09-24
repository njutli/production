# 05-3b：随机读写BS曲线的配置纠偏与重测

> 日期：2026-09-20—21；状态：`READ_VALID_L1 / WRITE_RANGE_ONLY_STATE_DRIFTED / FINAL_CLEANUP_COMPLETE`（[报告](../perf-report/05-3b-random-bs-baseline-repair-and-retest-20260920.md)：读12格已完成并签收；最终写RUN的4K两重复点差25.82%，超过预注册10%门，停止后续写批，不跨RUN补点；精确维护、scrub恢复及本地证据归档已闭环）。
> 面向：执行方采集，审核方从raw复算；承接[05-3报告](../perf-report/05-3-random-read-write-block-size-curves-20260918.md)及其RUN `20260918-163841`。
> 上位：[05阶段计划](../perf-analysis/05-block-size-adaptive-performance-comparison-plan.md)。执行遵守 `skills/SYSTEM-SAFETY-SKILL.md`、`EVIDENCE-INTEGRITY-SKILL.md`、`TESTING-GUIDE.md`、`test-commands-reference.md`、[任务书指南](TASK-BOOK-AUTHORING-GUIDE.md) §二.13—23及[生命周期规范](TEST-DATA-LIFECYCLE-POLICY.md)。

```text
05-3/4/5 原数据保留，配置与证据缺口已识别
  → 05-3b【本任务】：共用修正 → 健康恢复门 → 随机读写重测
     ├─ 完整：形成正确基线下的曲线
     └─ 状态不可控：保留范围，停止该写分支
  → 05-4b：单流顺序曲线与16M写候选复核
  → 05-5b：多流顺序曲线重测 → 05-6汇总
```

一句话：用正确的8线程客户端配置补齐随机纯读、纯写各BS数据，并防止写历史被误当成BS效应。

## 〇、为什么另开补测

05-3/4/5的实际命令均使用系统 `/etc/ceph/ceph.conf`，归档SHA256均为 `8dd48e578af8d0981c8d80c9764b4731c15fc5b7b4d3c7b7929cd27386c52944`；2026-09-20只读复核文件未变，`ceph-conf`及 `ceph config get client.admin ms_async_op_threads`均返回3。05计划要求的是私有配置8。历史私有8线程配置SHA256为 `c1e917e23b2888511aaffd55a2fb0697e8e3c9814180ea858eda500bc27bed48`，删除其追加的client段后正好得到上述系统配置哈希。

原05-3还存在两个独立问题：4M读日志首条出现在22—26秒，积分仅约87%；随机写256K首尾从2667.2降至486.3 MiB/s，伴随TiKV待压缩量和Ceph对象积累。前者须先查采集/时间语义，后者须改变测试组织，不能只换配置后原样跑满。

```text
EVIDENCE_LEVEL=L1_SCREEN（描述性曲线；非生产长期保证）
SCREEN_SOURCE=原05-3原始证据及2026-09-20配置复核
MINIMUM_DECISION_SET=读六档正反12格；写五个C-X-X-C小批次，C为256K，X覆盖其他五档
SCREEN_CONTINUE=每批身份/健康/采集有效且状态恢复；性能漂移只决定是否继续，不能删除低值
SCREEN_STOP=状态恢复失败、健康/容量异常或预算耗尽即停止相应分支
FORMAL_MATRIX=本任务不自动升级L2、不改变交付配置
STOP_AFTER_ANSWER=六档数据及状态限制交付后停止，不展开额外参数扫描
MAX_PREP_BUDGET=共用修正约1—2小时；两次确定性脚本失败则负责人直接修复
ESTIMATED_WALL_CLOCK=读36分钟+写60分钟+读采集canary3分钟；门禁/被动恢复后约2.5—4小时
MAX_EXECUTION_BUDGET=3小时决策预算；另含最多30分钟有界自然DB回收观察；到时停止探测并交付部分结果，不无限等待
EVIDENCE_ROOT=/mnt/c/SunRise/test/05-3b/<RUN_ID>
REMOTE_RESULT_ROOT=/mnt/jfs-cache/05-3b-evidence-20260920-092512（本RUN已获用户批准的专属日志目录；默认模板仍为/tmp/production/opencode-05-3b-<RUN_ID>）
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=仅恢复本任务私有挂载/进程和拥有的scrub flags；保留固定文件/卷/pool
```

## 执行收口附录（2026-09-20，supersedes conflicting execution clauses below）

### 写侧批次维护最终合同（2026-09-20，supersedes本附录及后文冲突条款）

用户已批准以受控维护起点完成剩余randwrite曲线。首次写格前及每个完整`C_before→X1→X2→C_after`四格批次后，只对128个精确的`/mnt/juicefs/test_dir/storage_test.{0..127}.0`文件逐个执行`juicefs compact --threads 1 <exact-file>`；不得递归compact、执行GC、删除/重建文件、重新layout、改卷/pool或停启服务。维护与fio严格互斥，路径、inode、大小及mtime须保持。单格canary失败于过严的写尾日志精确门，原始fio rc0；经下述有界尾差合同复算后正式窗可测，并以独立scrub租约补做写后维护，完整闭环。

每次维护后连续三个30秒样本须满足受控健康状态、6/6 OSD up/in、slow=0、RocksDB compact队列为0、对象数三点跨度≤8192和最小DB空闲≥17 GiB；每格开跑前仍要求最小DB空闲≥17 GiB，格内保持2 GiB停止线。canary单格使pool对象增加2,304,762、stored增加562.531 GiB，最小DB空闲仅下降1.623 GiB；写后维护2113秒后对象数精确回到起点，stored差−21.6 MiB，DB空闲回到35.61 GiB，过程中最低33.09 GiB。按四格线性包络仍远高于停止线，因此正式20格恢复为原预注册五个`C-X-X-C`批次、批末维护；任一格容量/健康失败或批末恢复失败即停止，不以扩容、重启或降低门槛继续。

逐文件安全采样频率不得降低。为避免六个独立OSD只读查询串行等待成为主要耗时，正式RUN前可将同一次快照内的`osd.0..5 perf dump`改为固定六worker有界并发；`ceph -s/osd dump/df`仍串行，每条查询独立30秒超时，任一失败、缺失或重复均使快照失败。只有在无fio/compact且不改scrub状态的串行/并发只读计时canary证明规范化JSON语义一致、原有健康/DB/slow/queue门全部通过后才可启用；否则回退串行实现。该优化只缩短证据采集等待，不改变维护范围、频率、负载或阈值。

五个`C-X-X-C`批次按原顺序和漂移门执行；每批从同一维护合同起点出发，`C_before/C_after`量化批内状态漂移，`X1/X2`量化同BS位置差。结果统一标记`CONDITIONAL_BATCH_MAINTENANCE_START`，只代表受控批次起点下的180秒性能；任一预注册漂移>10%即保留全部值并停止后续批次。报告须同时列维护时长、回收对象/stored和DB恢复幅度，不宣称该曲线等同无人工维护的长期生产稳态。

本附录只补充后续执行顺序，不改写本页已完成的05-3b读侧、既有randrw结果或报告中的历史状态。批准的收口顺序为：

1. 在任何正式比较批次前，只做一次定向维护：从已知的16M顺序写资产开始，即既有`mseqwrite` 16个4 GiB文件（64 GiB逻辑内容、报告§8记录的约4.83 TiB slice引用）。范围仅限这些明确文件；不碰读资产，不递归删除pool/volume内容，不改变文件逻辑内容或inode。维护不得与任何正式比较批次重叠。
2. 维护完成后，最多观察30分钟有界的自然DB回收；在健康、读容量和被动静默门通过后，先完成05-4b与05-5b的20个READ cells。05-3b randwrite未完成本身不得阻断这20个读格，但任何健康、读容量或被动静默失败都必须阻断。
3. 随后按冻结合同执行05-3b randwrite的20格（五个`C-X-X-C`批次）、05-4b write的11格、05-5b write的11格；05-4b的16M/FUSE1M候选仅在其预注册条件满足时执行4格。已完成的05-3b读12格与既有randrw数据均保留，不回跑或拼接替换。
4. 本轮容量决策预算为3小时；自然回收观察另设最多30分钟上限。必须重新校准写前容量预算，把报告§9已观察到的暂态DB分配峰值计入transient reserve，不能通过降低既有容量门或把当前余量当作充足来放行。预算内仍不足即停止探测，提交DB扩容方案；扩容、迁移DB、停启OSD或其他服务变更均需另行明确批准，本附录不授予这些操作。
5. 不在正式比较批次内compact，也不逐cell自动重置或恢复。若确有批准的inter-batch维护，必须使用统一、预先声明的协议并建立新的state epoch；报告中只能将其标为conditional-maintenance start，不能跨不同状态epoch声称精确BS效应。

收口依据仅采用报告§8—9的已记录事实：64 MiB微型验证289遍累计18.0625 GiB，两个自动回收周期由96→9、95→8；末态94 slices/5.875 GiB在5分钟内未变；一次暂态DB分配峰值使osd.0余量到3.516 GiB，约2分钟后回到5.325 GiB。它支持保留transient reserve，不构成生产autoGC已解决的结论。

## 一、三个补测任务共用的开跑合同

05-4b/05-5b直接引用本节，已通过的共用离线检查不机械重做；每任务仍核对实际部署脚本与配置哈希。

1. **先修正配置注入。** 复用已有私有 `ceph-msgr8.conf` 生成方式及已验证的进程识别方法；不修改系统ceph.conf或全局配置。冻结完整配置及SHA，在实际JuiceFS worker上核对 `CEPH_CONF`、PID/starttime/exe和8个 `msgr-worker`（不能检查守护父进程替代worker）。运行前、每格边界及收尾核验；不能只检查命令字符串。
2. **先修正仪表。** 复用 `t05-3-randrw-*`、`t05-4-seq-*`、`t05-5-mseq-*` 与 `u141d-scrub-control.sh`，只改配置、生效核验、缺口采集和批次编排，不新建通用框架。旧RUN中的脚本副本及raw不可改写。离线核对fio 3.28的日志起点/区间语义；禁止把首条晚到的记录随意铺回0秒、把缺口补零，或把shell返回时间减runtime标成精确job起点。多job聚合用各job可信时间轴；绝对时间对齐不确定须显式记录误差。
3. **离线Gate只覆盖实质缺陷。** 至少检验：默认3配置不能通过8线程合同；读到父进程/worker缺失会失败；1/16/128-job日志与group_reporting JSON兼容；22—26秒晚起、长缺口、尾部fsync、健康告警会正确降级；已知健康格复算不变。分析器的全窗积分与JSON字节差默认≤5%；超出先解释语义，不能调阈值使样本通过。修复后先做一次4M randread、180秒只读采集canary，单列为仪表验证，不拼入正式曲线；同类失败最多两次，之后停下离线处理。
4. **BlueFS恢复与定向维护是共同依赖，但不扩大授权。** 05-5收尾及前次只读检查有 `BLUEFS_SPILLOVER`：osd.4的40 GiB DB满、溢出约70 MiB；本次09:25复查已自然恢复HEALTH_OK、slow=0，但各DB仅余约5 GiB。按“执行收口附录”只允许对明确的16M顺序写资产做一次定向compact，且必须在正式比较批次之外完成；不碰读资产、不递归删pool/volume内容。扩容/迁移DB、停启服务、其他GC/compact或删除资产仍须另列精确目标及影响并另行确认。维护后仍须通过健康、读容量和被动静默门；未恢复不得启动相应负载。
5. **容量不能只看数据盘。** 恢复后须同时证明无spillover和足够DB余量；根据已有增长数据冻结每OSD DB开跑余量、停止阈值与本批写入预算，写入 `capacity-plan.tsv`（来源、公式、数值必须齐全），未冻结则写阶段仍未就绪。沿用数据盘raw available≥15 TiB、单OSD使用率<80%守卫。每格前后查DB与数据盘容量，格内复用轻量健康采样（约10秒）；任何新增健康告警/容量越界停止尚未执行的负载。发生告警的当前格即使fio rc=0也单列受污染观察，不能算健康有效格。
6. **固定身份与资产。** 客户端157，binary `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`；既有B256卷 `juicefs-prod`，UUID `e1b69ea9-0e3d-427d-bea9-8765928afa66`，Ceph FSID `f8137e5a-8af2-11f1-aa1c-4df480fc234d`。三份任务共同使用 `--max-fuse-io 256K --max-uploads 150 --max-downloads 200 --buffer-size 300 --cache-size 0`，writeback关、预读默认。私有挂载位于 `/tmp/jfs-<TASK>-<RUN_ID>-<direction>`。不动 `/mnt/juicefs` 的既有挂载；资产路径/inode/大小不符即停，不自动layout。
7. **scrub与收尾。** 三任务各读/写phase使用既有lease助手临时暂停 `noscrub/nodeep-scrub`，保存精确plan、原flags和已有授权引用；授权未覆盖则在一次批量开跑前补齐，不逐格询问。仅允许由这两个flag造成的 `OSDMAP_FLAGS` 例外，其他WARN一律阻断；已有scrub须结束。正常/失败均先停止本任务负载、精确graceful卸载私有挂载、按lease恢复本任务新增flag，随后保存证据；禁止强卸载和按模式kill。恢复失败优先处理，不进入下一任务。
8. **以附录顺序为边界。** 已完成05-3b读侧与既有randrw结果保持不变；定向维护和有界恢复后，先做05-4b/05-5b共20个读格，再做05-3b randwrite20格、05-4b write11格、05-5b write11格及条件式16M/FUSE1M四格。单项因统计分辨率不足可记录受限结果后进入下一任务；相应健康、DB容量或状态门未恢复则阻断写阶段，不阻断已满足读门的读阶段。修复/新尝试使用新RUN并保留旧记录，不跨RUN替换好值。

## 二、固定负载与最小矩阵

完整fio形状沿用原05-3：`libaio, numjobs=128, iodepth=128, direct=1, filesize=size=1G, runtime=180, time_based, group_reporting, fallocate=none, allow_file_create=0, openfiles=128, randrepeat=1`。BS为 `4K/16K/64K/256K/1M/4M`；每格保存全部128份per-job bw日志及JSON、完整命令、rc、实际运行时长。

**2026-09-21执行前仪表订正（不改变上述IO模型）：** fio 3.28使用 `--log_avg_msec=0` 逐IO完成记录代替原1秒平均记录；按日志时间戳、方向、第四列实际完成字节重建每秒带宽，不能把第二列逐IO瞬时rate直接相加。读方向全部日志的完成次数和字节须分别与JSON `total_ios/io_bytes`精确相等。异步写可出现fio在180秒截止后排空的少量在途IO被JSON计数、但逐IO带宽日志已停止的尾差；只有同时满足以下条件才可将`[15,175)`正式窗标为可测：差额为完整BS整数倍、聚合缺失IO不超过`8×numjobs`且不超过JSON总IO的0.2%、全部尾差即使最坏落入正式窗也只改变均值不超过2 MiB/s（落入任一40秒窗不超过8 MiB/s），128份job日志均从不晚于15秒覆盖到正式窗结束的175秒。fio各job在名义180秒边界可有毫秒级退出抖动，不能以恰好180.000秒作为证据门；覆盖正式窗及上述绝对误差界才是结论所需条件。百分比是辅助防错门，绝对带宽误差才决定尾差是否会影响结论；分析必须逐格报告两个误差上界。job内部无完成区间是randwrite按inode排队可能产生的真实停顿，保留为稳定性指标，不再以固定5秒阈值误判为采样丢失。尾差条件任一不满足，或读方向存在任何差额，正式窗仍为`UNKNOWN/REVIEW`，不得补缺口。首条晚到但通过上述覆盖门，表示该job此前没有已记录完成；与旧平均日志首条晚到不可混同。每job以fio自身相对epoch分窗；shell开始/返回时间仅作外部边界，不宣称精确绝对IO起点。逐IO日志有额外内存/落盘开销，先用既定4M只读canary核实，保存日志量与运行资源，正式曲线各档采用同一采集方法；不能把与旧日志曲线的差值都归为线程收益。远端证据目录可用空间至少30 GiB，不足则停止，不自动清理他人文件。

- 读资产：`/test_dir/read_test.{0..127}.0`，各1 GiB，全程只读。
- 写资产：`/test_dir/storage_test.{0..127}.0`，各1 GiB，仅允许覆盖这些已核验文件。
- 读序列：`256K-A → 4K-1 → 16K-1 → 64K-1 → 1M-1 → 4M-1 → 4M-2 → 1M-2 → 64K-2 → 16K-2 → 4K-2 → 256K-B`，一个私有挂载完成。
- 写序列：固定X顺序 `4K → 16K → 64K → 1M → 4M`；每批 `C_before → X1 → X2 → C_after`，C均为256K，每格180秒，同一写挂载。第一批同时承担短稳定性试行，不另加一套预热/探针矩阵。256K报告全部锚点及范围，不能挑首锚或把10个锚伪装成独立重复。

写前及每批之间只做**被动恢复**：三次间隔30秒采集，TiKV三节点 `kv/default` pending合计回到0，OSD `compact_running/compact_queue_len`均为0，健康/容量通过；OSD `kv_sync_lat`保留为辅助量，不以未经标定的延时阈值筛掉慢样本。读取沿用现有已核实metrics/perf字段，缺字段不能当0。每批等待上限15分钟，超时停止该写方向；不得在比较批次内自动GC、compact、重挂或清卷。附录批准的单次定向维护只能在批次外、作为新的状态epoch执行。

每批后计算 `D(a,b)=|a-b|/((a+b)/2)`：若C前后、X1/X2，或本批C_before对首批C_before任一D>10%，保留全部值并停止后续写批，标 `STATE_DRIFTED/RANGE_ONLY`。10%是继续投入的停止线，不是“误差小于10%就证明状态相同”；即使通过也同时列对象数/stored及DB/TiKV状态，不能据锚点相近断言逻辑元数据规模完全相等。只允许在这些限制内给描述性曲线，不外推精确BS因果效应。

本次不自动做FUSE1M筛选。纠偏后如仍有1M读带宽明显下凹，记录FUSE请求大小、对象GET字节等已有低扰动指标，交由审核方决定是否值得另开单参数对照，不能临时添加负载臂。

## 三、执行、裁决与交付

1. **步骤0：** 通读上述skill，确认指南§二.13—23、系统安全红线及本文覆盖的任务特定口径；不机械套用旧模板的全局drop_caches、主动compact、fresh卷或按带宽筛挂载。
2. **阶段0：** 完成共用离线修正和Gate；把原三报告的配置订正置顶并串联新旧证据。离线工作不等待DB修复。
3. **阶段1：** 只读前置诊断、明确修复方案与权限；环境恢复后，冻结容量/身份/命令和scrub计划，执行一次只读采集canary并审核采集合同。
4. **阶段2：** 自动完成读矩阵；按冻结门执行写小批次。阶段内只在安全门失败、变量变更或预算耗尽时停，不逐格回传。
5. **末步：** 按skill复核执行合规；恢复环境，持久化一次，审核方从raw复算后写报告。状态漂移时可部分收口，不为凑完整继续消耗环境。

带宽主栏为可信时间轴的 `[15,175)` 正式窗（mean/median/CV/P10/P90及四个40秒窗、W4/W1）；旁栏是fio JSON各方向 `io_bytes/runtime`，注明实际runtime，不能一律称180秒。IOPS、平均/P95/P99 clat从JSON读出，group_reporting时明确为聚合分布。容量与漂移判据分别来源于 `capacity-plan.tsv`及原始快照、`derived/`对各cell正式窗的复算。日志覆盖、积分或时间轴不满足时只保留summary，正式窗 `UNKNOWN/REVIEW`，不得称该档已补齐。

身份/配置、健康/容量、fio错误、采集缺失为非性能门；BW/CV/延迟/位置漂移为性能端点。四态沿用指南：`VALID`（本合同完整、限定为L1）、`EVIDENCE_INVALID`、`RESOLUTION_INSUFFICIENT`、`INCONCLUSIVE`。旧3线程RUN不进入8线程新曲线，不以新旧差值声称线程收益。

报告：`doc/perf-report/05-3b-random-bs-baseline-repair-and-retest-<YYYYMMDD>.md`；更新05计划及results-table。公共身份/配置/脚本每RUN一份；逐cell只保存新增raw、健康/容量与状态快照，异常写append-only `incidents.tsv`。权威副本SHA/文件数/字节数闭合后才处理远端临时副本；不为本任务重复复制原三任务整树。无清理授权则记 `PRESERVED`及原因，不影响已回答的问题按部分结果交付。

**红线：** 保护157 WekaIO/K8s与系统、网卡、md0；禁止全局drop_caches、重启、格式化、删pool/卷、轮间layout、未列明的GC/compact、宽作用域删除/kill。仅允许附录明确的定向写资产维护，且不得触碰读资产或在比较批次内执行。证据清理不授权删除测试文件；扩容、迁移DB、停启服务等仍需独立具体计划和批准，不能由“允许补测”推导。
