# 04-tmp3h任务书：竞品四命令的客户端缓存容量阈值

> 状态：`COMPLETED / NO_VERIFIED_CACHE_BUDGET_LE_128G / ENVIRONMENT_CLOSED`（RUN `20260906-172359`）
> 性质：条件性客户端缓存能力 canary；与 04-tmp3g 无前后依赖，但不得与其他性能测试并发执行。

> 执行边界：实际RUN中cp本地端点与cache backing同属`/dev/nvme1n1`，cp数值不具竞品可比性；
> 四档100%命中的fio direct读均显著低于目标，已单独构成“四项不能全过”的充分否定证据，故不为cp重跑。

## 一、最小决策合同

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=04-tmp2d读缓存曲线 + 04-tmp2f/2g writeback容量/排空曲线 + 04-tmp3竞品四命令
SCREEN_CONTINUE=按32→64→96→128GiB逐档执行；当前档首次四项均越线后仅补一次反序确认
SCREEN_STOP=首个两遍四项均越线的档位，或128GiB仍未通过，或安全/持久性门失败
FORMAL_MATRIX=各档一次FWD四命令；只对首个全越线档增加REV反序确认
ESTIMATED_WALL_CLOCK=首个通过档位为64GiB时约2--4h；扫至128GiB上限6--8h
MINIMUM_DECISION_SET=四档总物理预算+固定读缓存配额+同时开启writeback+原始四命令+最小通过档反序确认
STOP_AFTER_ANSWER=true
MAX_PREP_BUDGET=90min
MAX_EXECUTION_BUDGET=8h
```

唯一问题：在不改变竞品披露的四条前台命令时，客户端为 JuiceFS 提供多大的共享本地
缓存空间，可以让四项在两种执行顺序下都超过竞品披露值，同时写数据能在 900s 内
严格排空并通过重挂读回。

任务输出的是“当前固定分配策略下的最小已验证容量档”，不是连续参数空间的数学最小值。

## 二、结论语义和已有依据

### 2.1 允许声称的结论

只有某档位 FWD/REV 两遍都通过时，才可写：

> 在客户端提供实测可用空间不少于 X GiB、读数据经固定预热、开启 JuiceFS
> 读缓存和 writeback 的条件下，竞品公开的四条原始命令两遍均超过其披露值；
> 该结论为热读+前台写回口径，不等于无缓存或全数据已落 Ceph 的端到端性能。

必须同时报告 writeback 排空时间和含排空有效写带宽，不得只用 fio/cp 前台返回值宣称
持久化写能力超过竞品。

### 2.2 已有数据先验

- 04-tmp2d：读缓存名义100%热集容量时实测命中约`94%--95%`，读带宽约`29--35 GiB/s`；
  全驻留后约`35--37 GiB/s`，读侧越线具有强先验。
- 04-tmp2g：在另一固定128GiB写入模型中，writeback前台active-I/O于约32/64/128GiB档达
  `3311.08/3849.15/3881.53 MiB/s`；64GiB后趋于平台，但不能代替本任务的单流16MiB写。
- 04-tmp2f：大缓存会吸收更多脏数据并延长后台排空；容量越大不等于越安全。

## 三、共享缓存语义和固定配置

JuiceFS `raw/`读缓存和 `rawstaging/`写回暂存位于同一 `cache-dir` 文件系统，且可通过
hard link 共享 inode；不能把两者拆到两个文件系统。本任务使用一个容量受控的普通文件
→唯一loop→普通inode密度ext4，同时开启读缓存和writeback。

缓存物理档位按 backing 名义容量命名，正式横轴一律使用 ext4 创建后的 `df -B1 Available`：

| 档位 | backing名义容量 | `--cache-size`固定值 | 设计含义 |
|---|---:|---:|---|
| T32 | 32 GiB | 16384 MiB | 最低成本探测；读/写约各留一半 |
| T64 | 64 GiB | 32768 MiB | 容纳30GiB读资产并为写回留空间 |
| T96 | 96 GiB | 40960 MiB | 读资产+开销+写脏积压的中档 |
| T128 | 128 GiB | 40960 MiB | 读配额不再扩大，只增加writeback余量 |

backing 必须在 `/mnt/jfs-cache` 上完整分配，禁止 sparse overcommit；创建前宿主剩余空间必须至少为
当前档名义容量加 `64 GiB`。ext4 使用普通 inode 密度，禁止使用历史上导致 inode 不足的
`-T largefile`。任一时刻最多保留一个本RUN的loop/ext4档位。

该分配策略在看数据前冻结，不因某档读或写未越线就就地修改 `cache-size`。这是一组动态共享策略，
不是读写硬分区；总占用以 `df`为真值，`raw/rawstaging` 使用 inode 去重表解释，禁止直接将
两目录 `du` 相加。

共同挂载项：`/tmp/juicefs-1.4.1-patched`（MD5
`24fae0852051c80ca571cb2f20275d46`）、B256 `juicefs-prod`、RUN私有
`ms_async_op_threads=8`、`--max-fuse-io 1M --max-downloads 200 --max-uploads 150
--free-space-ratio 0.20 --writeback`，并按表设置 `--cache-size`。不启用 `async_dio`，不改原fio的
I/O引擎/QD，不使用 `drop_caches`。

## 四、四条原始命令和数据资产

### 4.1 竞品目标与命令合同

| 测试项 | 原始口径 | 超越线 |
|---|---|---:|
| cp单流读 | `time cp <JFS>/20Gfile <LOCAL>/` | `2.0 GB/s` |
| cp单流写 | `time cp <LOCAL>/20Gfile <JFS>/` | `2.0 GB/s` |
| fio单流读 | `read,size=10G,bs=20M,direct=1,numjobs=1,runtime=60,time_based,group_reporting` | `5.4 GB/s`=`5149.84 MiB/s` |
| fio单流写 | `write,size=10G,bs=16M,direct=1,numjobs=1,runtime=120,time_based,group_reporting` | `3.2 GB/s`=`3051.76 MiB/s` |

fio使用系统默认同步引擎/`iodepth=1`，只增加JSON、唯一per-job带宽日志和错误输出；禁止为越线
增加libaio、更大QD、`end_fsync`或改写运行时间。cp带宽用精确字节数除以`/usr/bin/time`墙钟，
按十进制GB/s与竞品比较。

### 4.2 资产

- JuiceFS内创建RUN专属20GiB cp读文件和10GiB fio读文件，一次创建后全RUN只读；
- 每个容量档为FWD/REV分别使用独立的cp写目标和fio写文件；没有REV时不预创建空REV资产；
- 本地20GiB cp源文件和cp读输出使用RUN专属精确路径，inventory必须保存`findmnt`、设备、容量
  和本地顺序读能力；若本地路径本身低于2GB/s，签`LOCAL_PATH_BLOCKED`并停止；
- 所有资产必须是非稀疏文件，冻结精确size/inode/path和首尾hash。本任务禁止复用或改写七项及
  04-tmp3历史资产。

### 4.3 固定预热

读结果明确定义为热缓存口径。每次正式cp读前完整顺序读一1次20GiB资产，每次正式fio读前
按同一fio读口径预热 60s；预热不进入性能结果，不延长、不重试。正式窗记录块缓存实测命中率、
Ceph数据网RX和cache gauge。

`cp` 是缓冲I/O，预热后可能同时命中Linux页缓存和JuiceFS磁盘缓存。本任务不做全局
`drop_caches`，因此cp结论是“热客户端缓存能力”，不得将cp速度单独归因于受控的磁盘容量。
fio `direct=1` 作为读磁盘缓存容量的主要对照。

## 五、逐档早停矩阵

按 T32→T64→T96→T128 串行。每档先使用一个新的空cache-dir创建固定挂载，不在档内修改挂载参数。

```text
FWD: cp-read → fio-read → cp-write → drain → fio-write → drain
```

- FWD任一项未越线，但数据、排空、重挂和环境门均通过：该档签`CAPACITY_NOT_SUFFICIENT`，精确收口后进下一档。
- FWD四项均越线：在同一档位、同一挂载参数下执行反序确认：

```text
REV: fio-write → drain → cp-write → drain → fio-read → cp-read
```

REV读项仍各执行固定预热。REV四项也全部越线则签`FOUR_COMMAND_CACHE_TARGET_CONFIRMED`并立即停，
不测更大档位。REV任一项未越线时，该档签`ORDER_SENSITIVE_NOT_CONFIRMED`，精确收口后进下一档。

每条前台命令期间以1秒轻量采样记录staging、cache、可用空间、网卡和宿主块设备计数器；不得在
正式窗递归扫描`rawstaging`。每条写命令后严格排空上限900s：JuiceFS staging metrics 与
`rawstaging`文件数/字节须连续两次（间隔10s）为0。任意ENOSPC/hardlink/upload异常、原daemon
900s未严格归零、数据读回失败或优雅卸载失败，
该档不得进入候选。容量型排空失败按04-tmp2f已验证的同cache-dir恢复流程取证；恢复成功只证明数据
可恢复，不追认该档通过。

## 六、带宽、容量和持久化口径

每个档位至少输出：

```text
backing nominal | ext4 initial Available | cache-size | free-space-ratio
cp read/write GB/s | fio read/write summary + formal-window MiB/s
read hit ratio | Ceph RX | raw gauge | staging peak | min free
cp/fio write drain seconds | effective durable write MiB/s
FWD/REV verdict | environment/lifecycle state
```

- cp主口径：`exact_bytes / time-real / 1e9`；必须另存time原文和文件大小。
- fio主口径：同时报fio JSON summary与实际I/O起点后的正式窗均值；读使用`[10,50)`，
  写使用`[10,110)`，两者都必须越线才算fio达标。
- 前台writeback带宽：fio/cp返回主口径；另报
  `effective_durable_write = exact_written_bytes / (实际I/O起点到严格排空的墙钟)`。
- 总物理占用取`df`；读/写角色占用使用metrics与inode去重表；同时报告最低空闲空间和
  direct-upload fallback。

## 七、有效性和裁决

### 7.1 非性能硬门

任一项失败则停止当前RUN，不能用已出现的高点声称越线：

1. binary/config/META/UUID/BlockSize/mount/PID/starttime/exe与冻结合同不符；
2. fio/cp rc或I/O error、per-job log/时间线缺失、资产size/hash/重挂读回失败；
3. Ceph非`HEALTH_OK`、OSD非6/6 up-in、PG出现recovery/backfill/degraded/incomplete，或正式窗与scrub重叠；
4. 未授权的sudo/全局状态变更、foreign fio、业务指纹漂移、loop/backing/路径所有权异常；
5. 非容量型JuiceFS/FUSE/cache/OSD/TiKV错误，或失败后本RUN拥有状态无法恢复。

容量不足导致的未越线、严格排空超时或ENOSPC是有效容量下界，不是可删样本；安全恢复后可进更大档。

### 7.2 唯一总裁决

- `FOUR_COMMAND_CACHE_TARGET_CONFIRMED`：某档FWD/REV的四项各两次都超过目标，写项都在900s内严格
  排空，重挂读回及所有非性能门通过。该档即“当前策略下最小已验证档”。
- `NO_VERIFIED_CACHE_BUDGET_LE_128G`：T128仍无法通过上述合同；不自动扩至256GiB。
- `EVIDENCE_INVALID`：非性能硬门失败；所有已有带宽只是工程观察。

## 八、执行阶段、授权和精简要求

### Phase 0：复用脚本+离线Gate

只准复用/小改 04-tmp3的四命令/资产组件、04-tmp2d的读预热和命中采集、04-tmp2g的
loop/writeback/排空/恢复组件以及 `u141d-scrub-control.sh`；最多新增一个executor、一个
analyzer和一个Gate，禁止新建编排框架。

Gate只验证四命令未被改动、四档与cache-size映射、FWD/REV早停、排空/恢复、路径/loop所有权、
目标单位和分析fixture。准备超过90min仍未通过，必须缩减而不是继续增加脚本层。

### Phase I：只读inventory和唯一授权停点

冻结业务指纹、二进制/META/UUID/B256、资产、Ceph/PG/OSD、空间、本地源/目标路径、现有loop/mount、
foreign fio、脚本SHA，并列出所有`sudo mount/losetup/mkfs/umount`、scrub pause/restore、专属资产创建/
精确删除、优雅JuiceFS卸载、排空恢复和最终GC计划。本阶段不改变状态。

其中本地源/目标根目录位于 root 所有的 `/mnt/jfs-cache`，计划必须明确列出对该RUN专属目录的
`sudo install -d -m 0700 -o 1002 -g 1002` 与最终空目录 `sudo rmdir`。

用户对计划一次授权后，Phase II 内可按预注册分支自主执行；只在安全边界变化、非容量异常或要扩大
到256GiB时停下。

### Phase II：逐档执行与环境恢复

每档固定流程：精确创建loop/ext4→空cache-dir→创建本档专属写资产→运行FWD→按结果运行REV或进下一档
→严格排空→优雅卸载→重挂读回→精确删除本档资产→一次共享卷GC及对象/状态回归→精确卸载ext4和detach唯一loop→
删除唯一backing和空目录。

性能窗若需暂偟scrub，只能复用权威state/lease脚本；无论成功、失败或中止，都先恢复本RUN拥有的
scrub原状态。矩阵内不执行OSD compact；每个已测档最多执行一次共享卷GC，最终读资产清理后再执行
一次，上限五次。Phase I必须列出精确命令并以独立GC ACK一次授权；不为“用完预算”主动compact。

### Phase III：独立复算和收口

依次生成容量档表、四项FWD/REV对比表、命中/占用/排空表及唯一裁决；如实列出cp页缓存边界、
前台与持久化写差异。完成证据持久化、环境资产恢复和生命周期后，任务才能关闭。

## 九、安全与生命周期

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3h/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp3h-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=逐档独立plan/state/ACK精确恢复loop/ext4/backing、scrub lease和RUN专属文件
```

- 执行前必须通读并遵守 `skills/SYSTEM-SAFETY-SKILL.md`；扫描executor及子脚本中全部sudo写、
  reboot/shutdown、服务、强制卸载、宽删除和设备操作，将完整命令和目标节点交用户批准。
- 特权写只允许RUN+档位精确路径、唯一backing/loop/ext4和scrub lease；禁止裸盘mkfs、`losetup -D`、
  force/lazy umount、递归`rm/chown/chmod`、卷/pool删除、服务/网络/内核修改和157全局`drop_caches`。
- 路径必须非空、绝对、非根、非符号链接并匹配`04tmp3h-<RUN_ID>-<TIER>`；loop必须反查backing唯一匹配后
  才可mkfs/detach，同一时刻最多一个本RUN loop。
- 禁止手工删除`rawstaging`；排空异常只走同cache-dir恢复路径。删除JuiceFS内资产必须使用冻结
  manifest逐项精确unlink，禁止glob和宽递归。
- COMMON每RUN只保存一份，cell仅增量保存raw。原始证据、实际脚本、`commands.sh`、incident和manifest
  必须先持久化到唯一权威根并通过SHA/文件数/字节数/可读性核验，才可精确清理远端证据。
- 未归因事故标`INCIDENT_STATUS=OPEN`并保留最小必需现场；不得为获得全越线结论覆盖失败raw或修改矩阵。

报告必须列出：

```text
RUN_ID / VALIDITY_STATE / LIFECYCLE_STATE / EVIDENCE_ROOT / MANIFEST_PATH
PERSISTENCE_STATUS / REMOTE_STATUS / LOCAL_STATUS / INCIDENT_STATUS / ENVIRONMENT_ASSET_STATUS
```

## 十、交付物

1. `doc/perf-report/04-tmp3h-competitor-four-command-client-cache-capacity-<DATE>.md`；
2. 四档容量表、最小已验证档、四项FWD/REV原始值和超出百分比；
3. 读命中/Ceph卸载、物理占用/min-free、writeback峰值/排空/有效持久化带宽表；
4. `results-table.md`中独立的“热客户端缓存竞品口径”小节，不覆盖无缓存交付基线；
5. 唯一权威证据、实际脚本/命令、manifest、持久化和精确清理审计。

## 十一、修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-06 | 初版：四档共享客户端缓存、原始四命令不变、逐档早停、首个全越线档FWD/REV确认。 |
| 2026-09-06 | runner/analyzer/Gate 0就绪并通过纯离线检查；排空超时作为容量下界后走同cache-dir恢复，未连接环境、未授权执行。 |
