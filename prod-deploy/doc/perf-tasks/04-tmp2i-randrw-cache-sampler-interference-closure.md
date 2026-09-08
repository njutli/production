# 04-tmp2i：randrw缓存采样干扰消除与共享策略收尾

> 日期：2026-09-06
> 状态：`COMPLETED / VALID / NO_MATERIAL_MIXED_CACHE_CANDIDATE / ENVIRONMENT_CLOSED`
> 正式RUN：`20260906-201646`；5/5 cell通过，P50/P75按预注册早停合同取消。
> 承接：04-tmp2h RUN `20260906-090701`完成28/28 cell和环境闭环，但正式窗内同步递归
> 扫描cache目录造成最长约31.4秒采样阻塞，证据签`EVIDENCE_INVALID/NO_DECISION`。

```text
04-tmp2d：纯读缓存已有正式容量收益
04-tmp2f/2g：纯writeback已有容量、排空和前台收益边界
04-tmp2h：五档三类策略均跑完，但采样器可能同时漏采并扰动缓存盘
        ↓
04-tmp2i：修复采样器，只在T128复核R/W/P25/P50/P75   ← 你在这里
        ├─ 无材料混合候选 → 关闭randrw共享缓存调优线，生产保持不变
        ├─ 出现材料候选   → 只登记L1候选，另立单点原生盘L2确认
        └─ 非性能门失败   → EVIDENCE_INVALID，停止并保留最小事故证据
```

一句话目标：去掉正式窗内递归目录扫描后，确认T128下读缓存与writeback同开是否仍没有
值得升级的randrw候选，并判断04-tmp2h的大幅负收益是否受到采样器干扰。

## 一、最小决策合同

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=04-tmp2h完整fio描述值 + 已闭合生命周期；不得把其无效P点当正式效应量
SCREEN_CONTINUE=任一P点相对配对A0有>=5%正收益、无单方向>=5%退步且生命周期安全时，另立单点L2
SCREEN_STOP=全部P点无材料收益，或明显落后A0/R/W，立即关闭共享缓存线；不扩其他容量档
FORMAL_MATRIX=NONE；出现候选后另立一个选定容量/比例的原生文件系统L2
MINIMUM_DECISION_SET=A0-pre + T128-{P25,R,W} + A0-post，共5格；P25初筛通过才补P50/P75，最多7格
STOP_AFTER_ANSWER=true；不重跑原28格，不追加容量、比例、时长或重复轮
MAX_PREP_BUDGET=60min
MAX_EXECUTION_BUDGET=2.5h（常规5格）；P25触发补测时最多4h（7格）
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2i/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2i-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=按cell精确卸载/detach唯一loop/删除唯一backing，并恢复本RUN scrub lease
```

本任务不是重新制作五档容量曲线。T128被选中是因为它等于热数据集名义容量，且04-tmp2h中
T128-P25是全部混合点里退步最小的一点（描述值`-7.68%`）。同档补齐三个P比例及R/W端点，
已经足以判断该方向是否值得继续投入；若仍无材料信号，不得因“其他容量也许不同”扩回28格。

## 二、冻结变量与矩阵

### 2.1 环境、资产和负载

- 固定当前patched JuiceFS v1.4.1、`juicefs-prod`、B256、交付私有Ceph配置
  `ms_async_op_threads=8`；执行前冻结binary MD5/SHA256、META、UUID、BlockSize和mount身份。
- 复用`test_dir/rw_test.0.0`至`rw_test.127.0`共128个既有1GiB文件；禁止layout、clone、
  format、destroy、fresh volume、文件创建或扩容。
- fio与04-tmp2h完全相同：`randrw/rwmixread=50/bs=256K/128 jobs/libaio/iodepth=128/
  direct=1/time_based/runtime=180/randrepeat=1/固定randseed`；每格先固定180秒randread预热。
- 挂载公共项固定`--max-fuse-io 256K --max-uploads 150 --free-space-ratio 0.20`；157禁止
  `drop_caches`，禁止修改WekaIO、K8s、内核、网络、服务及非本RUN进程。
- 不再使用跨RUN固定`3.287 ns/B ±10%`判定挂载好坏：04-tmp2h的有效锚已在`2.957--3.003 ns/B`，
  本任务首次尝试的三次独立挂载稳定在`2.902--2.932 ns/B`，固定参考会把稳定且更快的当前挂载误拒。
  本任务以同RUN A0-pre/post三方向漂移和mount身份作为可比性硬门，不额外运行mseqread探针。
- 缓存档固定一个fully allocated 128GiB普通文件→唯一loop→普通inode密度ext4；禁止sparse、
  `-T largefile`和裸盘设备。正式横轴记录ext4初始`df Available=U128`。

### 2.2 五格必测、两格条件补测

```text
A0-pre → T128-P25
  ├─ P25相对A0-pre的mean非负，且READ/WRITE均未退步超过5%：补T128-P50、T128-P75
  └─ 否则：不补比例点
→ T128-R → T128-W → A0-post
```

| Cell | writeback | cache-size | 用途 |
|---|---|---:|---|
| A0-pre/post | 关 | `0` | 同RUN首尾噪声锚 |
| T128-R | 关 | `floor(U128/MiB)` | 全部偏读端点 |
| T128-W | 开 | `1 MiB` | 近似全部偏写端点 |
| T128-P25 | 开 | `floor(0.25×U128/MiB)` | 历史最有利混合点兼首格采样canary |
| T128-P50 | 开 | `floor(0.50×U128/MiB)` | 平衡混合点 |
| T128-P75 | 开 | `floor(0.75×U128/MiB)` | 偏读混合点 |

每个缓存cell都从新的空cache-dir开始并独立收口；不得从前一格继承热缓存。P25首格若修复后的
采样覆盖门失败，立即停止整个RUN；覆盖通过后阶段内部自主连续跑完，无逐格停点。P25补测判据只用于
节省P50/P75时间，最终效应仍用A0-pre/post线性插值裁决。

## 三、采样器唯一修复合同

04-tmp2h runner只允许做以下最小修改，禁止借机重写执行框架：

1. 正式窗1秒CORE sampler只采Prometheus累计指标、`statvfs`可用空间、时间戳和必要网卡/块设备
   计数；使用单调deadline，不以“采完再sleep 1”形成累积漂移。
2. 正式窗内禁止`find`、目录递归、`sort`、inode清单、Ceph/TiKV全量命令或其他可能随缓存规模
   增长的操作。Gate须对正式sampler函数做静态断言。
3. `raw/rawstaging`精确文件/inode快照只在正式fio前、fio后和严格排空后各做一次；它们不参与
   1秒覆盖门。排空阶段继续使用已验证的独立rawstaging扫描。
4. 每个正式窗要求：至少150/160个自然秒有CORE样本、首尾覆盖完整、最大相邻间隔`<=2.5s`、
   sampler rc=0；禁止插值补点或降低阈值。
5. 保存sampler自身PID/starttime及`/usr/bin/time -v`或等价轻量资源汇总，用于证明采集器没有
   形成可见CPU/I/O负载；该项只作机制旁证，不新增性能删样门。

Gate 0必须用04-tmp2h历史归档验证：旧runner应被“正式sampler含递归find”负fixture拒绝，
修复runner的合成180秒时间线应通过；分析器仍需正确拒绝稀疏采样，不得把04-tmp2h无效RUN改判有效。

## 四、有效性、统计和唯一裁决

### 4.1 最小真值与非性能门

- 主性能仍取fio JSON的READ/WRITE各方向总字节÷实际runtime，并保存128份per-job bw log、
  actual I/O起点、`[15,175)`重叠加权正式窗和W1--W4；READ、WRITE分开报告，
  `mean_direction=(READ+WRITE)/2`只用于候选排序。
- CORE sampler输出正式窗hit/miss、blockcache/staging、min-free；目录快照只报告前后角色占用。
- writeback格必须在900秒内由metrics与rawstaging连续两次严格归零，报告排空秒数和
  `effective_durable_write`；ENOSPC、hardlink/upload异常、排空失败均淘汰该格。
- 每格前后Ceph健康、OSD up/in、PG active+clean、资产name/inode/size、binary/META/UUID/PID/
  starttime/exe和mount参数必须一致。fio错误、采样覆盖不足、数据读回或恢复失败均令RUN
  `EVIDENCE_INVALID`，禁止用已出现带宽挑样。
- 三个写回混合格与W格都须完成写后GC/compaction状态返回；不得仅因fio结束进入下一格。

### 4.2 分辨力

```text
D_A0=max(READ/WRITE/mean_direction三指标的A0首尾相对漂移)
M=max(5%, D_A0)
```

- `D_A0>8%`：`RESOLUTION_INSUFFICIENT`，只报描述值；
- 各P点分别与按位置线性插值A0、R和W比较；第一名与第二名差`<M`只称候选平台；
- 平均提高但READ或WRITE任一方向相对A0退步`>=M`，只算Pareto取舍，不算无代价候选。

### 4.3 唯一业务裁决

- `MIXED_CACHE_CANDIDATE_REQUIRES_L2`：至少一个P点生命周期安全，相对A0的mean提升`>=M`，
  READ/WRITE均未退步`>=M`，并且性能不低于R/W最佳端点超过`M`。只登记一个最佳L1候选，
  不在本RUN追加轮次；后续另立原生文件系统L2。
- `NO_MATERIAL_MIXED_CACHE_CANDIDATE`：RUN有效，但无P点满足上述条件。结合04-tmp2h历史广度，
  关闭randrw共享缓存调优线，保持无缓存交付基线；不得扩大为“所有业务都不适合缓存”。
- `POST_REPAIR_DIFFERENCE_MATERIAL`：修复后任一P点相对04-tmp2h同配置描述值提高`>=10%`。
  这是跨RUN描述性标签，只说明修复前后存在材料差异；不能单独归因于采样器，也不自动等于生产候选。
- `EVIDENCE_INVALID/RESOLUTION_INSUFFICIENT`：按非性能门或A0漂移签署，不补样、不沿用旧RUN拼接。

## 五、执行阶段与停点

### Phase 0：最小脚本修复和离线Gate 0

1. 执行前通读`SYSTEM-SAFETY-SKILL.md`、`EVIDENCE-INTEGRITY-SKILL.md`、
   `TESTING-GUIDE.md`、`LONG-RUNNING-TEST-SKILL.md`、`test-commands-reference.md`和
   `TEST-DATA-LIFECYCLE-POLICY.md`。
2. 从`t04tmp2h-randrw-run.sh`、analyzer及Gate机械派生04-tmp2i版本，只修改sampler和5+2矩阵；最多保留
   一个runner、一个analyzer、一个Gate，禁止新编排框架。
3. 选择与sampler时间线、目录遍历、矩阵、路径/loop和scrub恢复相关的缺陷fixture；完成bash/
   Python静态检查、历史归档负fixture和合成正fixture。
4. Gate 0未通过，禁止SSH、sudo、mount、fio、Ceph或JuiceFS命令。

### Phase I：只读inventory、计划与唯一开跑授权停点

只读冻结环境、资产、空间、foreign fio、当前mount/loop、脚本SHA和Ceph/scrub原状态；输出全部
sudo写命令、精确路径、5+2格命令、失败恢复和清理计划。用户一次确认完整计划后，Phase II内部
自主跑完；只有安全边界变化、未知设备/路径、非本RUN业务异常时停下。

### Phase II：5+2格连续执行、复算和收口

1. 若获独立授权，在单个性能phase临时设置`noscrub+nodeep-scrub`；保存FSID、原flags和lease，
   任意退出路径先恢复本RUN拥有的flags。
2. 按注册顺序执行5格，并仅在P25初筛通过时补P50/P75；P25先过实际采样覆盖canary，之后不逐格汇报。
3. 第二方只用持久化raw独立复算；执行方只提交原始数据、逐门清单和append-only incidents，
   不挑点、不下效应结论。
4. 精确恢复scrub、mount、loop、backing和RUN资产，确认业务指纹、Ceph和PG恢复；完成唯一归档、
   SHA256、文件数、可读性及生命周期账本后再审阅远端清理计划。
5. 测试后对照上述skill复核：无pool删建、无强制卸载、无全局drop_caches、写后状态返回、
   scrub lease恢复、统计及证据生命周期均符合合同。

## 六、安全、证据与红线

- 任何sudo写、scrub全局flags、loop/mkfs/mount/umount/detach和环境资产删除，必须在Phase I列出
  完整命令、节点和精确目标并经用户确认；执行方不得自行扩大授权。
- loop必须反查唯一backing文件且路径匹配本RUN/T128后才允许mkfs或detach；禁止裸NVMe、
  `losetup -D`、force/lazy umount、宽`rm -rf`、递归chown/chmod、服务/网络/内核操作。
- 157上的WekaIO、K8s及其他业务属于保护区；发现资源冲突或foreign fio立即停止。
- 正式矩阵内不layout、不新建卷/pool、不热改脚本、不补样；失败保留最小现场并先恢复全局flags。
- COMMON每RUN只持久化一次，cell仅增量保存raw。原始raw、实际脚本、`commands.sh`、
  `incidents.tsv`、manifest和复算必须进入唯一`EVIDENCE_ROOT`；持久化校验前禁止清理源端。
- 证据清理与环境资产清理使用独立plan/ACK；禁止glob、未解析变量、父目录递归及跨RUN删除。

## 七、交付物

1. `doc/perf-report/04-tmp2i-randrw-cache-sampler-interference-closure-<DATE>.md`；
2. 实际5或7格READ/WRITE/mean、正式窗、采样覆盖、命中/占用、排空和有效耐久写表；
3. 04-tmp2h同配置描述值与本RUN的差异表，以及唯一业务裁决；
4. `results-table.md`和`04-TASK-BOOK-STATUS-20260901.md`更新；
5. 唯一持久化归档、实际脚本/命令、manifest、独立复算和环境/证据清理审计。

## 八、修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-06 | 初版：不重跑五档28格；只在T128用7格修复采样干扰并收尾共享缓存候选判断。 |
| 2026-09-06 | 精简执行：5格必测，P25出现非负且双方向无5%回退的信号时才补P50/P75；跨RUN差异改为非因果标签。 |
| 2026-09-06 | 首次执行在正式矩阵前被绝对ns/B门误拒：三次挂载稳定但比旧参考快10.8%--11.7%；删除该跨RUN绝对门，保留同RUN A0漂移门后使用新RUN。 |
| 2026-09-06 | RUN `20260906-192516` 本地/157 Gate 0与只读Phase I通过；脚本哈希一致，待Phase II sudo授权。 |
| 2026-09-06 | 正式RUN `20260906-201646`完成：采样覆盖修复有效，P25相对插值A0仍下降16.88%，纯R提高12.32%，纯W提高5.45%；签`NO_MATERIAL_MIXED_CACHE_CANDIDATE`并关闭环境。 |
