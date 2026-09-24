# 05-5 任务书：多流顺序读写BS曲线与并发平台收口

> **2026-09-20追溯更新：** 实际执行遗漏私有8线程配置，写第9格又触发post-health告警；不能签“正确基线读侧完成/9个健康写格”。[05-5b](05-5b-multistream-bs-baseline-and-capacity-retest.md)承接读写完整重测，不在本页原矩阵补最后两格。

> 状态：已执行；`mseqread` 10/10格完成，`mseqwrite`因`BLUEFS_SPILLOVER`在9/11格后安全停止，记为`WRITE_PARTIAL_INFRASTRUCTURE_BLOCKED`。详见[05-5报告](../perf-report/05-5-multistream-sequential-block-size-curves-20260920.md)。  
> 上位计划：[05阶段计划](../perf-analysis/05-block-size-adaptive-performance-comparison-plan.md)；前序：[05-4报告](../perf-report/05-4-single-stream-sequential-block-size-curves-20260920.md)。  
> 本任务书不授权sudo或Ceph全局状态修改；scrub暂停须展示精确计划后单独授权。

## 一、只回答什么问题

在当前通用交付配置下，固定16个同步顺序流时，`mseqread/mseqwrite`带宽如何随fio BS从64 KiB变化到16 MiB；曲线在哪一档进入平台？结合04-6已经完成的`8→16→8`并发曲线，给出“继续增大BS或并发是否仍有明显收益”的收口结论。

```text
EVIDENCE_LEVEL=L1_CURVE
MINIMUM_DECISION_SET=读5档正反各一次；写先3格稳定性探针，通过后补齐五档正反位置
STOP_AFTER_ANSWER=同BS位置漂移或写探针漂移>10%则停止尚未运行的同方向格，只报告范围
MAX_EXECUTION_BUDGET=3.5小时（fio纯负载约63分钟）

EVIDENCE_ROOT=/mnt/c/SunRise/test/05-5/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-05-5-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
```

本任务不重复04-6的并发数扫描：04-6已测得256 KiB mseqread `8→16→8 = 4384→4687→4393 MiB/s`，加倍并发仅增约6.8%；4 MiB mseqwrite为`4064→3854→4090 MiB/s`，16流反降约5.5%，六块OSD数据盘正式窗P50 util均100%。05-5只检查这些规格点在本RUN是否落入可解释范围，并补齐BS横轴。

## 二、冻结合同

| 项 | 内容 |
|---|---|
| 节点/二进制 | 157；`/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46` |
| 卷/挂载 | 既有`juicefs-prod`、BlockSize=256 KiB；私有挂载固定`--max-fuse-io 256K --max-uploads 150 --max-downloads 200 --buffer-size 300 --cache-size 0`，私有Ceph配置`ms_async_op_threads=8` |
| fio共同项 | `numjobs=16,ioengine=psync,iodepth=1,direct=1,size=4G,time_based=1,runtime=180,refill_buffers=1,group_reporting=1,allow_file_create=0` |
| 读/写 | `mseqread: rw=read`；`mseqwrite: rw=write,end_fsync=1` |
| BS | `64K,256K,1M,4M,16M` |
| 固定资产 | `/test_dir/mseqread/mseqread.{0..15}.0`与`/test_dir/mseqwrite/mseqwrite.{0..15}.0`，每个恰为4 GiB；读写目录、inode集合互不相同 |

只读inventory必须核验主机、二进制、META/卷UUID/BlockSize、Ceph FSID、6/6 OSD、97/97 PG、容量、foreign fio、Weka/K8s指纹以及两组资产的16个文件、大小、inode。资产不符即停；不得自动layout。若仅mseqwrite资产缺失，另列“精确创建16×4 GiB固定测试文件”的命令和影响，等用户单独批准；不得触碰mseqread、seq/rw_test或其他目录。

## 三、最小矩阵

### 3.1 mseqread：10格

```text
256K-A → 64K-1 → 1M-1 → 4M-1 → 16M-1
→ 16M-2 → 4M-2 → 1M-2 → 64K-2 → 256K-B
```

读阶段只读固定资产，不预热、不重建、不改挂载。同BS两个位置漂移`>10%`时，该档只报范围；首尾256 KiB锚漂移`>10%`时停止后续适配判断，但保留已完成曲线。

### 3.2 mseqwrite：3格探针后最多8格

```text
探针：4M-A → 64K-A → 4M-B
通过后：256K-A → 1M-A → 16M-A → 16M-B
         → 1M-B → 256K-B → 64K-B → 4M-C
```

探针的4M A/B正式窗漂移`>10%`、fio/fsync异常、容量/健康门失败即停止写矩阵。通过后同一挂载连续执行余下8格；任一同BS位置或4M锚漂移`>10%`，停止尚未运行的写格。禁止为了“恢复高值”在格间layout、GC、compact、drop_caches或重启服务。

写阶段每格前后采集Ceph pool objects/stored/raw available、三节点TiKV pending compaction和PG状态，并在每格前后执行容量硬门。raw available低于15 TiB、任一OSD容量使用率达到80%，或任何非性能健康门失败，立即停止并安全卸载，不以完成矩阵为优先。objects/stored与pending compaction用于事后识别异常累计；本任务不为它们额外插入30分钟等待、GC或compact，发现持续单向增长时降级该段因果解释。

## 四、参数筛选边界

本任务**不新增挂载参数臂**：

- 04-6b中RA8对mseqread只有约`+4.28%`，未过材料线；
- FUSE1M对mseqwrite两组效应`+6.28%/-1.41%`，方向不一致；
- 04-6已完成8/16流并发平台判断。

因此05-5只形成通用配置BS曲线。若出现无法由既有平台解释的新拐点，只记录为05-6的机制缺口，不在本RUN临时追加参数、numjobs或卷BlockSize。

## 五、scrub、授权和阶段边界

05-4在约15分钟内两次被例行scrub严格门中止；05-5是约63分钟的正式矩阵，因此默认方案是在**读、写两个phase边界分别**使用既有状态驱动控制器暂停并恢复`noscrub/nodeep-scrub`。执行前必须先只读输出：原flags、FSID、正在运行的scrub、租约文件、以下精确sudo写面及回滚：

```text
sudo ceph osd set noscrub
sudo ceph osd set nodeep-scrub
# phase结束/失败，只撤销本RUN新增的flag：
sudo ceph osd unset nodeep-scrub
sudo ceph osd unset noscrub
```

用户未单独批准时不得执行上述命令，也不得以放宽PG状态匹配代替控制；只能暂停在plan阶段。正式phase要求同时提供性能ACK和`I_ACK_GLOBAL_CEPH_SCRUB_PAUSE`，runner才会调用既有控制器执行pause；每个phase无论成功、失败或中断，均由同一runner的EXIT闭环按lease执行`plan-restore → restore → verify-restored`，恢复失败则返回硬错误并保留精确恢复指针，禁止进入下一phase。

## 六、采集、判读与交付

- 每格保存fio JSON、16份per-job带宽日志、rc/error、实际timed-I/O起止、末尾fsync墙钟、完整命令及挂载PID/starttime/exe/cmdline。
- 正式窗统一为实际I/O起点后的`[15,175)`；报告fio summary、正式窗均值、W1--W4、CV、P10/P90、IOPS、完成延迟均值及“16个job各自P95/P99的最大值”（不冒充聚合分位数）。日志缺失/积分不闭合则正式窗记`UNKNOWN/REVIEW`，不伪造。
- 同BS漂移使用`|B-A|/((A+B)/2)`；曲线只回答BS关系。与04-6跨RUN只比较范围和方向，不生成伪精确效应。
- mseqread若4--16 MiB增益<5%，登记读侧BS平台；mseqwrite若BS增加而带宽不再提高、同时OSD完成率不增且磁盘util/延迟符合04-6平台方向，登记既有写服务平台得到再次旁证。否则只报曲线，不强行闭合组件。
- 正式报告写入`doc/perf-report/05-5-multistream-sequential-block-size-curves-<YYYYMMDD>.md`，更新05计划和results-table；不因没有新调优候选而追加测试。

## 七、安全与生命周期

- 禁止修改生产挂载、Weka/K8s、网络/内核/md0、OSD/TiKV服务、pool/PG/CRUSH；禁止宽作用域kill和递归删除。
- 只创建本RUN私有挂载与证据目录。固定测试文件不随证据清理；若经独立授权新建mseqwrite资产，其后续保留/删除另行决定。
- 成功或普通失败路径都先对本RUN精确私有挂载执行graceful umount；卸载失败时保留恢复指针并禁止继续。随后验证无fio、无私有挂载、scrub flags恢复及Ceph/PG/TiKV最终健康，再将证据增量复制到持久根；逐文件checksum无差异后才可精确清理远端临时证据。
- 脚本必须复用05-4的身份门、挂载门、正式窗分析和恢复标记；只增加16-job固定文件映射、16份日志校验、容量门及scrub lease编排，不新建通用框架。
