# 04-tmp3g任务书：竞品16MiB异步写QD曲线与达标确认

> 状态：`PLANNED / SCRIPTS_READY / GATE0_PASS / NOT_AUTHORIZED`  
> 性质：竞品公开口径的能力补测，不直接产生七项生产配置变更。

## 一、最小决策合同

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=04-tmp3同步写有效2616.09MiB/s；04-tmp3b曾观3163.45MiB/s但持久性门失败，禁止进入效应量
SCREEN_CONTINUE=完成QD1/2/4/8曲线并重复QD8，不追加其他参数
SCREEN_STOP=两个QD8完成后立即裁决；未达标也不扫QD16/更大buffer/writeback
FORMAL_MATRIX=S01-C08A-C01-C02-C04-C08B-S02
ESTIMATED_WALL_CLOCK=纯fio约11min；资产准备、状态门、持久性复核和收口合计1.5--3h
MINIMUM_DECISION_SET=同RUN同步首尾锚+异步QD1/2/4/8+两个QD8达标确认
STOP_AFTER_ANSWER=true
MAX_PREP_BUDGET=60min
MAX_EXECUTION_BUDGET=3h
```

唯一问题：在文件、`bs=16M`、单 job、顺序写、后端和本地缓存条件不变时，
将应用提交方式从同步 `psync/QD1` 改为 `async_dio + libaio/QD1/2/4/8`，能否使两次
QD8 写带宽都超过竞品披露的 `3.2 GB/s`（`3051.76 MiB/s`），并通过写后重挂证明
数据已持久化。

本任务不得预设“必然超过”。如未越线，必须如实签署未达标并停止，不得为获得漂亮数据临时
改参数、删样本或补跑。

## 二、已有证据与任务边界

| 项目 | 已有结果 | 本任务处理 |
|---|---:|---|
| 竞品 fio 16MiB单流写 | `3051.76 MiB/s` | 绝对达标线 |
| JuiceFS同步有效值 | `2616.09 MiB/s` | 只作历史旁证；本RUN补同窗锚 |
| JuiceFS无效高点 | `3163.45 MiB/s` | 重挂持久性门失败，禁止引用为达标数据 |
| JuiceFS异步读 | `5277.79 MiB/s`，比竞品读高`2.48%` | 已闭合，不重测 |

本任务完成后，若写侧达标，可形成“fio大块读写在异步多请求模式下均观测到超过
竞品披露值”的结论。但两项 `cp` 不支持通过 fio I/O 引擎进行同类调整，仍只有
`0.996/0.986 GB/s`，因此不得写成“竞品四项全部超过”。

## 三、固定条件

- 发起端固定 157；JuiceFS 二进制固定 `/tmp/juicefs-1.4.1-patched`，执行前核对 MD5
  `24fae0852051c80ca571cb2f20275d46`。
- 复用当前 B256 `juicefs-prod` 卷和同一 Ceph/TiKV 后端；禁止 format、新建卷、新建 pool、
  relayout 或修改 BlockSize，避免 fresh 集群/卷成为混杂变量。
- 仅使用任务专属相对目录 `test_dir/04-tmp3g-<RUN_ID>/`；每个 cell 使用一个独立、预先
  创建并校验为 10GiB 的非稀疏文件，禁止改写已有七项或 04-tmp3 资产。
- 共同挂载参数：`--max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300
  --cache-size 0`，writeback 关闭，RUN 私有 Ceph 配置使用 `ms_async_op_threads=8`。
- S 锚挂载显式 `async_dio=off`；C 曲线在同一个挂载进程中显式 `-o async_dio`，期间
  只改 fio `iodepth`。
- 同步锚与QD8确认点完整对齐竞品命令：

```text
rw=write bs=16M size=10G direct=1 numjobs=1 runtime=120 time_based group_reporting
```

  S 使用 `ioengine=psync iodepth=1`；C 使用 `ioengine=libaio`。曲线QD1/2/4运行 60s，
  QD8两次均运行 120s。每格增加唯一带宽日志与 JSON，不增加 `end_fsync`、writeback
  或本地缓存，不改变竞品前台写口径之外的变量。
- 157、150--152禁止 `drop_caches`，禁止修改内核、网卡、服务、TiKV、Ceph pool/PG/CRUSH/OSD
  配置，禁止强制卸载和宽范围删除。

## 四、最小矩阵与执行顺序

| Cell | 挂载语义 | fio引擎 | QD | 时长 | 用途 |
|---|---|---|---:|---:|---|
| S01 | `async_dio=off` | psync | 1 | 120s | 竞品原命令同窗首锚 |
| C08A | `async_dio=on` | libaio | 8 | 120s | 达标确认1，前置以减少累积状态影响 |
| C01 | `async_dio=on` | libaio | 1 | 60s | QD曲线 |
| C02 | `async_dio=on` | libaio | 2 | 60s | QD曲线 |
| C04 | `async_dio=on` | libaio | 4 | 60s | QD曲线 |
| C08B | `async_dio=on` | libaio | 8 | 120s | 达标确认2，后置检查累积状态后仍能越线 |
| S02 | `async_dio=off` | psync | 1 | 120s | 竞品原命令同窗尾锚 |

不得临时改序、重用文件、删格或因中间带宽补格。C08A--C08B 共用一个挂载进程，
以 PID/starttime/exe 确认没有跨挂载实例噪声。每格 fio 退出后等待上传/本地写缓冲回到基线，
再进入下一格；单格排空上限 300s，超时即停，不在运行中修改排空标准。

为避免频繁全局恢复本身成为噪声，性能矩阵内不执行 OSD compact或每格 JuiceFS GC。
S01/S02、C08A/C08B 分别作为首尾状态回环；若同类锚点漂移超过 `8%`，RUN 证据无效，
不使用中间点宣称越线。

## 五、有效性、统计与裁决

### 5.1 最小真值集

每格仅保留以下必需证据：

- fio JSON/stdout/stderr、唯一 1s per-job bw log、完整实际命令、rc 和 fio error；
- actual timed-I/O start/end，120s格主窗 `[10,110)`，60s格主窗 `[10,50)`；
- binary/META/UUID、mount options、PID/starttime/exe、cell专属路径/inode/size；
- cell前后 Ceph health/PG/OSD up-in、JuiceFS PUT/upload/buffer/error、157 CPU和Ceph数据网卡吞吐；
- 排空耗时和状态，以及性能阶段结束后的重挂文件大小与首尾 1MiB hash。

主带宽同时报告 fio JSON summary 和正式窗重叠加权均值；两者都只使用当前 cell 原始
数据。输出 mean/median/CV/P10/P90、四窗、clat mean/p99；CV是结果，不是删样本门。

### 5.2 非性能硬门

任一项失败则 `EVIDENCE_INVALID`并停止：

1. binary/META/UUID/mount/PID/资产/fio命令与冻结合同不符；
2. fio rc/error、bw log覆盖、采样时间线或文件精确大小失败；
3. Ceph非 `HEALTH_OK`、OSD非6/6 up-in、PG出现recovery/backfill/degraded/incomplete，或正式窗与scrub重叠；
4. 排空超时、JuiceFS/FUSE/OSD/TiKV出现I/O error、panic、assert或fatal；
5. S01/S02或C08A/C08B主窗带宽漂移超过`8%`；
6. 矩阵后优雅卸载、重挂检查任一cell文件失败，或已有业务卷/资产指纹发生非本任务变化。

### 5.3 唯一性能裁决

- `WRITE_ASYNC_TARGET_CONFIRMED`：C08A、C08B 的 fio summary **和**正式窗均值均
  `>=3051.76 MiB/s`，且所有非性能硬门通过。报告写明两次实测值、超出百分比和排空耗时。
- `WRITE_ASYNC_TARGET_NOT_MET`：RUN有效，但C08A/C08B任一组的任一主口径低于目标。
- `EVIDENCE_INVALID`：非性能硬门失败。只报工程观察，禁止使用高点声称超过竞品。

无论哪个结果都立即停止，不扫 QD16、`buffer-size`、`max-uploads`、writeback、缓存或源码参数。

## 六、执行阶段与授权

### Phase 0：最小脚本与离线 Gate 0

只新建/修改一个executor、一个analyzer和一个Gate；优先复用：

- `t04tmp3-executor.sh`的B256身份、专属资产、写后排空、重挂和精确清理组件；
- `t04tmp3e-executor.sh`的 `async_dio`、`libaio/QD`、PID拓扑和采样组件；
- `u141d-scrub-control.sh`作为scrub状态唯一权威实现。

禁止复制出新编排框架。Gate 0 只检查本次改变的QD矩阵、fio写方向、独立文件、
`async_dio` 身份、达标裁决、重挂持久性和禁止命令。Gate未通过前禁止SSH、mount、fio或
任何环境变更。

### Phase I：只读 inventory 与完整计划

核对二进制、META/UUID、B256、业务挂载/资产指纹、Ceph/PG/OSD、无foreign fio、空间和历史
04-tmp3环境已收口；输出七格fio、scrub pause/restore、资产准备、卸载/重挂和最终精确清理
命令全文。本阶段不挂载、不创建文件、不跑fio、不修改scrub flags。

### Phase II：资产准备与性能矩阵

获得对 Phase I 完整计划的授权后，一次性预置七个独立文件，完成非稀疏/大小/hash门并等待
环境稳定。正式矩阵前若需暂停scrub，必须复用权威脚本的plan/state/lease，将全部sudo写命令交用户
批准后才可执行。授权后七格连续完成，不逐格停顿。

任何成功、失败或中止路径都必须先按state/lease恢复scrub原状态，再进行证据和资产收口。

### Phase III：持久性、证据与环境收口

1. 优雅卸载所有任务mount，确认worker退出；重挂同一META/UUID，逐文件复核size和首尾hash；
2. 生成资产精确manifest和cleanup plan；只在独立ACK后逐文件unlink，禁止glob、宽范围递归删除；
3. 资产准备前后不主动执行GC；精确删除全部RUN资产后执行一次
   `juicefs gc --compact --delete --threads 32`使对象/元数据回到预注册锚。该命令因作用于共享卷，
   必须在Phase I列出并以独立GC ACK授权；禁止临时增加OSD compact；
4. 恢复业务卷指纹、Ceph `HEALTH_OK`、6/6 OSD up-in、PG全active+clean，无任务mount/fio/文件残留；
5. raw、实际脚本、`commands.sh`、incident、derived和报告进入唯一权威持久化根，完成manifest/
   SHA256/文件数/字节数/可读性核验后，才可按精确清单清理远端临时证据。

## 七、安全、证据与生命周期

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3g/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp3g-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=Phase III独立精确plan/ACK；不得沿用证据清理授权
```

- 所有远程操作必须遵守 `skills/SYSTEM-SAFETY-SKILL.md`。运行前扫描executor及子脚本中的sudo写、
  reboot/shutdown、宽删除、强制卸载和服务命令；任何sudo写操作须列全文并经用户批准。
- 禁止影响157上WekaIO、K8s或其他业务；发现资源冲突、foreign fio或业务指纹异常立即停止。
- `COMMON`每RUN只保存一份，cell只增量保存raw，不重复拷贝前序目录。原始证据进manifest后
  不得改写；重试使用新RUN_ID或明确attempt目录。
- 任务报告必须记录 `RUN_ID/VALIDITY_STATE/LIFECYCLE_STATE/EVIDENCE_ROOT/MANIFEST_PATH/
  PERSISTENCE_STATUS/REMOTE_STATUS/LOCAL_STATUS/INCIDENT_STATUS/ENVIRONMENT_ASSET_STATUS`。
- 未归因事故保持 `INCIDENT_STATUS=OPEN`，禁止自动卸载或清理关键现场；根因闭合后只保留最小
  事故包。无效RUN不得进入超越竞品的结论。

## 八、交付与表达边界

1. 新建 `doc/perf-report/04-tmp3g-competitor-large-block-async-write-closure-<DATE>.md`；
2. 在 `results-table.md` 登记同步锚、QD曲线、两次QD8、持久性和唯一裁决；
3. 更新 04-tmp3 四项对比表，同时列“竞品原命令”与“异步多请求诊断”，不得混成同一语义；
4. 只有 `WRITE_ASYNC_TARGET_CONFIRMED` 才可写：

   > 在文件、块大小、单job和顺序写方向不变的情况下，JuiceFS改用
   > `async_dio + libaio/QD8`后，两次有效16MiB写均超过竞品披露的3.2GB/s；
   > 该结果体现了异步多请求对后端吞吐余量的释放，不等于原同步单流命令达标。

## 九、修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-06 | 初版：仅补16MiB异步写QD1/2/4/8曲线和两次QD8达标确认；复用已签收组件，不扩参数矩阵。 |
| 2026-09-06 | executor/analyzer/Gate 0就绪并通过纯离线检查；未连接环境、未授权执行。 |
