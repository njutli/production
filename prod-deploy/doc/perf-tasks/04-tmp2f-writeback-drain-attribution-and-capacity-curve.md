# 04-tmp2f：writeback排空失败归因与有效容量曲线

> 日期：2026-09-04
> 状态：`PLANNED / NOT_AUTHORIZED / SCRIPTS_NOT_READY`
> 范围：本文件只制定任务，不授权执行、部署或sudo操作。
> 承接：04-tmp2e已证明16 GiB档排空失败，但尚未正式签署文件级根因结论，也未形成有效容量曲线。

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=既有W16失败证据与旧20GiB生命周期旁证
SCREEN_CONTINUE=离线根因证据闭合且环境/恢复计划通过Gate0后执行容量矩阵
SCREEN_STOP=数据、业务、Ceph、恢复、设备所有权或证据完整性异常
FORMAL_MATRIX=NONE（每容量只测一次，仅形成工程容量曲线和观测安全点，不计算CI或正式效应量）
```

## 一、目标与边界

本任务只回答两个问题：

1. **为什么排空失败**：确认04-tmp2e的两个长期残留文件是否由缓存文件系统逼近满盘后，
   `rawstaging → raw` hardlink发生`ENOSPC`并脱离原daemon正常处理链造成；
2. **多大容量才有效**：在固定的180秒、128并发randwrite压力下，测出缓存实际可用容量与峰值积压、
   排空时间、前台带宽及“含排空时间的有效带宽”之间的关系，并找出本负载下首个观测安全点。

本任务不重复证明writeback相对无缓存的收益，不运行randrw，不做新layout，不寻找通用生产容量公式。
一次测试通过只能得到“当前负载下的观测安全点”；若要用于生产，仍需另做业务占空比canary。

## 二、已有证据与根因签署

### 2.1 已有事实

04-tmp2e RUN `20260903-181523`（16 GiB backing）已有完整证据：

- 挂载后实际Available为`15.53 GiB`，staging峰值`15.22 GiB`，占`97.96%`；
- fio写入约`432.22 GiB`且128 job均成功；
- 日志包含约`135.8万`条受控的空间不足直传回退、`4156`条真实`ENOSPC`，以及仅有的两次
  `stage@disk_cache.go:804` hardlink ENOSPC；
- 原挂载等待900秒后仍残留两个`rawstaging`文件，共`524288 B`；
- 两个残留文件名与上述两条hardlink ENOSPC日志中的源文件名**逐一完全相同**；
- 使用同一cache-dir恢复挂载后两条残留路径消失且抽读通过，但现有采样不能证明这两个文件各自被
  上传；无论如何不得据此追认原挂载排空成功。

旧RUN `20260903-171855`实际是20 GiB backing：实际Available约`19.50 GiB`、staging峰值约
`19.10 GiB`。它同样出现约`135.8万`条正常直传回退，但没有真实ENOSPC或hardlink失败，并在
70秒内排空。该RUN只能作为历史生命周期旁证，不登记为本任务的新测工程容量点。

### 2.2 离线归因任务

执行环境测试前，使用上述已有原始文件生成一张文件级事件表，每行至少包含：

```text
residual_path | residual_size | hardlink_source | hardlink_target | timestamp | errno | log_site
```

同时复核以下计数：排空超时后的残留文件数、`disk_cache.go:804` hardlink ENOSPC数、二者文件名的
双向差集，以及W16/W20的普通直传回退和真实ENOSPC计数。不得只引用报告摘要。

再按本次二进制对应源码版本只读追踪一次失败分支：确认hardlink返回ENOSPC后该文件是否进入常驻
上传/重试队列、原daemon是否会再次扫描它，以及恢复挂载为何能够重新发现并处理它；记录文件、函数和
commit，不改源码。源码只能解释机制，文件级运行证据负责确认本次事件。

只有同时满足以下条件，才签署：

```text
ROOT_CAUSE=ENOSPC_HARDLINK_LIFECYCLE_CAUSE_CONFIRMED
```

- 两个集合均恰好为2，且文件名双向差集为空；
- hardlink失败发生在排空超时前，原挂载没有自行清除这两个文件；
- 恢复挂载后两条残留路径消失且数据仍可读；
- 20 GiB旁证表明“大量正常直传回退”本身不足以导致残留。

若任一条件不成立，则记`ROOT_CAUSE=INCONCLUSIVE`，保留矛盾，不为补结论而再次运行16 GiB危险点。

该证据支持的精确表述是：**16 GiB缓存文件系统接近满盘时，并发写入越过空间保护余量，导致两个
已生成的rawstaging文件在进入raw缓存队列的hardlink步骤收到ENOSPC；它们未被原daemon继续处理，
因而造成排空超时。** 它不等于“所有直传回退都会排空失败”。

## 三、容量曲线

### 3.1 固定条件

- JuiceFS：当前交付的exact patched v1.4.1，执行前冻结MD5/SHA256；
- Ceph客户端：沿用04-tmp2e的RUN私有`ms_async_op_threads=8`配置，禁止改变集群全局同名参数；
- mount公共参数：`--writeback --cache-size 1 --free-space-ratio 0.20 --max-uploads 150
  --max-fuse-io 256K`，默认readahead/prefetch，不设置`upload-delay`；
- fio：randwrite，128 job，256 KiB，iodepth 128，180秒，固定seed，与
  `FULLBASELINE_V4_U141D.sh`口径一致；
- 数据：只覆盖现有`storage_test.*.0`共128×1 GiB；`allow_file_create=0`、
  `create_on_open=0`，禁止layout和创建缺失文件；
- backing：157现有原生ext4 `/mnt/jfs-cache`上的RUN专属普通文件，经动态loop挂载为独立ext4；
  任一时刻只存在一个cell；
- 不执行全局`drop_caches`，不触碰`/mnt/juicefs`参考挂载、WekaIO或K8s。

### 3.2 最小矩阵

| Cell | backing名义容量 | 作用 |
|---|---:|---|
| W20 | 20 GiB | 新测历史canary附近的首个可能安全点 |
| W32 | 32 GiB | 低容量安全点 |
| W64 | 64 GiB | 中容量点 |
| W128 | 128 GiB | 高容量点及本任务上界 |

固定顺序`W20 → W32 → W64 → W128`，每档只跑一次。仅当`W64`仍排空失败而`W128`通过时，
增加一次`W96`以缩小边界；其他情况不补中间点、不重复整套矩阵。

W20/W32失败仍是有效的容量下界信息：完成只读取证、安全恢复和环境归零后继续更大容量。只有发生
数据读取错误、非容量型upload错误、恢复失败、未知路径/设备、业务或Ceph异常时，才立即停止。

历史16 GiB失败点纳入最终图表作为下界，但不重跑；历史20 GiB只作旁证，新W20才是本任务的新测
工程曲线点。

### 3.3 每点判定

正常的`space not enough ... upload it directly`是容量回压机制，不单独判失败；必须与真正的
`ENOSPC`、hardlink/upload错误分开计数。

| 判定 | 条件 |
|---|---|
| `LIFECYCLE_FAIL` | 900秒内未连续两次确认metrics与rawstaging文件同时归零，或恢复/抽读失败 |
| `LIFECYCLE_PASS_TIGHT` | 严格排空且抽读通过，但出现容量型ENOSPC或hardlink异常 |
| `OBSERVED_SAFE_POINT` | 严格排空、抽读通过，且无真实ENOSPC、hardlink或upload错误 |
| `INVALID_AND_STOP` | fio I/O错误、`uploadStagingFile`/非容量型upload错误、数据错误或环境硬门失败 |

曲线中的“首个有效容量”定义为最小的`OBSERVED_SAFE_POINT`。不设置缺乏数据依据的80%占用硬阈值；
报告实际峰值占比和最小剩余空间，让后续生产canary据此另加安全裕量。

每个容量点至少保存并复算：

```text
actual_available_bytes
peak_staging_bytes / peak_staging_ratio / minimum_observed_free_bytes
foreground_mean / median / CV / W1-W4
drain_seconds_to_95pct / 99pct / strict_zero
effective_bw = fio_written_bytes / (fio_runtime + strict_drain_seconds)
direct_fallback / real_ENOSPC / hardlink_error / upload_error counts
```

`actual_available_bytes`取cache ext4挂载且JuiceFS cache初始化完成后、fio启动前的`statvfs Available`；
从fio前10秒开始至严格排空或900秒超时，每秒采一次`statvfs Available`与staging状态，曲线使用其中
最小值作为`minimum_observed_free_bytes`。`drain_seconds_to_95pct/99pct`均从fio实际结束时刻起算，
分别表示staging bytes首次降至“fio结束瞬间积压”的5%/1%所需时间；若结束瞬间为零，两者均记0。

排空失败点的`effective_bw`记为不可计算，不能以恢复挂载后的归零替代。这里的`effective_bw`表示本次
逻辑写入从前台开始到writeback排空完成的摊销带宽，不声称等于Ceph物理写入带宽。

## 四、最简执行流程

### Phase 0：离线准备与一次审批停点

1. 完成§2.2文件级离线归因；
2. 复用`t04tmp2e-writeback-{run,recovery,analyze,gate0-offline}`，只做以下必要修改：
   - 增加W20/W32/W64/W128及条件W96；
   - 排空超时作为“容量点失败”进入只读取证和既有恢复流程，而非直接丢失后续曲线；
   - 分开统计普通直传回退、真实ENOSPC、hardlink和upload错误；
   - 在fio前、运行期和排空期每秒采集`statvfs Available`；
   - 使用新的04-tmp2f命名空间和持久化目录。
3. 不新建通用编排框架；离线脚本准备超过60分钟仍未通过时停止，先报告阻塞；
4. Gate 0至少覆盖：非法容量、部分state、排空超时、安全恢复、条件W96及精确loop所有权；
5. 回传脚本SHA256、只读inventory以及将要执行的全部sudo命令和精确目标。

**停点1：** 用户审核并授权后才可进入Phase 1。任务书本身不构成授权。

### Phase 1：一次授权后的连续容量矩阵

1. 冻结binary、META/UUID、资产清单、Ceph配置和起点对象数；
2. 为避免长矩阵被随机scrub污染，Phase 1以一次性设置`noscrub+nodeep-scrub`为执行前提：必须在
   停点1列为独立Ceph全局写操作并获得授权，整段只设置一次，收口或异常时优先恢复；health门只可
   豁免由这两个精确flag单独导致的预期WARN，任何其他WARN仍立即停止。未获授权则本次不执行，不能
   以“重叠cell无效”边跑边丢弃；
3. 连续执行W20/W32/W64/W128，并只按§3.2规则决定是否追加W96；
4. 每个cell必须先完成：原挂载排空判定、抽读、优雅卸载、按backing反查并精确detach唯一loop、
   精确删除RUN专属backing、对象数回到容差、OSD compaction cooldown；然后才能开始下一cell；
5. 若排空失败，先保存残留文件和同期日志等只读现场，再使用04-tmp2e已验证的同cache-dir恢复挂载
   机制完成安全收口；恢复只用于保护数据与环境，不改变原cell的FAIL判定。

Phase 1内允许执行者按预注册分支连续完成，不逐cell暂停。不得临时修改容量、ratio、runtime、数据集、
判据或扩大到128 GiB以上。

### Phase 2：复算、报告与收口

1. 独立复算每个点及历史W16下界，产出容量—峰值积压、容量—排空时间、容量—前台带宽、容量—
   有效带宽四张表或图；
2. 恢复scrub lease和所有环境资产，确认无任务mount、loop、backing、进程或未知残留；
3. 证据持久化、SHA256和清单核对通过后，生成正式报告；
4. GPT审核后再决定是否把首个安全点升级为生产canary候选，本任务不直接改交付配置。

**停点2：** 回传完整证据、环境收口及结论，任务结束。

预计墙钟：离线准备不超过`1小时`；四个新测点通常`6--10小时`，触发W96时不超过`12小时`。

## 五、交付物与裁决

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2f/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2f-<RUN_ID>
EVIDENCE_RETENTION=FORMAL
REMOTE_CLEANUP=AFTER_REVIEW
```

最低交付物：

- `root-cause/`：W16/W20原始日志计数、残留—hardlink文件级事件表、双向差集；
- `common/`：inventory、binary/config身份、实际脚本、SHA256、实际命令和sudo计划；
- `cells/`：fio JSON、逐秒bw、staging/df/rawstaging序列、daemon日志、排空/恢复/抽读证据；
- `derived/`：逐点CSV、四条容量曲线、判定表；
- `run-state.tsv`、`incidents.tsv`、manifest、持久化及清理账本；
- 正式报告：`doc/perf-report/04-tmp2f-writeback-drain-attribution-and-capacity-curve-<日期>.md`。

最终只允许如下结论：

```text
ROOT_CAUSE=ENOSPC_HARDLINK_LIFECYCLE_CAUSE_CONFIRMED | INCONCLUSIVE
CURVE=COMPLETE | PARTIAL | INVALID
CAPACITY=OBSERVED_MIN_SAFE_POINT:<actual GiB> | NO_SAFE_POINT_AT_OR_BELOW_128_GIB | INCONCLUSIVE
```

`CURVE=COMPLETE`要求W20/W32/W64/W128均得到可归类的容量结果；若出现“W64失败、W128通过”，还
必须完成W96。即使所有点均为容量型失败，也可记`COMPLETE + NO_SAFE_POINT_AT_OR_BELOW_128_GIB`。
环境、数据、恢复或证据异常的cell不能作为容量下界，任务只能记`PARTIAL`或`INVALID`。

## 六、安全红线

1. 遵守`SYSTEM-SAFETY-SKILL.md`与`TEST-DATA-LIFECYCLE-POLICY.md`；157上的WekaIO、K8s、
   `/mnt/juicefs`、网卡、内核和非本RUN进程均为只读保护对象。
2. 所有特权及集群状态写必须在停点1逐条授权：仅包括RUN专属目录的`install`、`chown`、`mount`、
   `umount`和`rmdir`，经backing反查的唯一loop的`losetup/mkfs.ext4/detach`，一次任务所有权明确的Ceph
   `noscrub/nodeep-scrub`设置与恢复，以及既有精确OSD compact命令。禁止裸NVMe mkfs、批量detach、
   force/lazy umount、服务重启或其他Ceph配置写。
3. 脚本必须守卫RUN_ID、CELL、绝对路径、owner、非根目录和非符号链接；禁止宽作用域或递归
   `rm/chown/chmod`，禁止手工删除rawstaging残留。
4. 不得再次执行已知危险的16 GiB点，不得新增pool/卷/layout，不得全局`drop_caches`。
5. fio前后检查Ceph健康、OSD up/in、PG active+clean；写后确认compaction cooldown。业务、Ceph、
   数据读取、恢复或所有权校验异常时立即停止。
6. 原始证据成功持久化前不得清理远端最后一份；环境资产恢复优先于报告整理，恢复成功不得改写原
   cell的失败判定。
