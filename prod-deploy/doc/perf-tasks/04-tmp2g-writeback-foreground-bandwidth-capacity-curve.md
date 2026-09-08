# 04-tmp2g：writeback前台带宽—容量订正曲线

> 日期：2026-09-05
> 状态：`COMPLETED / ACTIVE_IO_SIGNAL / WALL_RESOLUTION_INSUFFICIENT / ENVIRONMENT_CLOSED`
> 证据等级：`L1_SCREEN`；只订正04-tmp2f没有回答的前台性能问题。

```text
04-tmp2f：已闭合ENOSPC根因与排空安全性，但180秒内写入430--512GiB
  → 缓存相对128GiB逻辑数据集的比例，不等于相对本轮脏写量的比例
04-tmp2g：固定每格总写入128GiB，测W20/W32/W64/W128前台完成带宽  ← 当前
  → 有单调材料信号：登记writeback容量收益曲线
  → 无单调信号：保留“只延长突发、未提高全程均值”的窄结论
排空时间独立记录，不参与前台带宽裁决
```

## 一、唯一问题

在同一128×1GiB既有文件集上，每格固定覆盖写入总计128GiB时，writeback backing实际可用容量从
约20、32、64增加到128GiB，用户侧randwrite平均带宽是否随容量增加而提高。

本任务不重新归因04-tmp2f的ENOSPC，不测试randrw，不format JuiceFS、不layout、不创建或删除卷内
文件。缓存排空只负责安全恢复并单独报告，不与用户侧完成带宽合并。

## 二、冻结口径

- JuiceFS：exact patched v1.4.1，MD5 `24fae0852051c80ca571cb2f20275d46`；
- META/卷：现有`juicefs-prod`，只覆盖`test_dir/storage_test.0.0`至`.127.0`；开跑前冻结UUID和资产；
- fio：`randwrite`、128 jobs、每job固定`size=1G`、`filesize=1G`、`bs=256K`、`libaio`、
  `iodepth=128`、`direct=1`、固定seed；**禁止`time_based`和`runtime`**；
- mount：`--writeback --cache-size 1 --free-space-ratio 0.20 --max-uploads 150
  --max-fuse-io 256K`，RUN私有Ceph客户端`ms_async_op_threads=8`；
- backing：复用04-tmp2f在`/mnt/jfs-cache`上创建普通文件→唯一loop→ext4的方式；每次只存在一个cell；
- 不执行drop_caches，不改变业务挂载、系统Ceph配置、网卡、内核、WekaIO或K8s。

### 2.1 矩阵

```text
W20A → W32 → W64 → W128 → W20B
```

| Cell | 名义backing | 约占128GiB逻辑集 | 作用 |
|---|---:|---:|---|
| W20A | 20GiB | 15.6% | 首锚 |
| W32 | 32GiB | 25% | 容量点 |
| W64 | 64GiB | 50% | 容量点 |
| W128 | 128GiB | 100% | 容量上界 |
| W20B | 20GiB | 15.6% | 尾锚，约束跨格漂移 |

每格只测一次，不增加容量档、不补样、不挑值。每格完成排空、抽读、精确loop/backing清理、对象回归及
OSD/TiKV cooldown后再进入下一格。W20A/W20B用户侧平均带宽漂移绝对值大于8%则容量曲线记
`INCONCLUSIVE_DRIFT`，不得解释中间档差异。

### 2.2 主指标与裁决

主指标是固定128GiB从fio实际开始到128个job全部完成的用户侧平均带宽：

```text
foreground_MiBs = sum(job.write.io_bytes) / (fio_return_time - fio_launch_time)
```

fio JSON中的`elapsed`只作墙钟一致性复核；最大job runtime与墙钟的差额作为用户可见的非active-I/O
前台开销单列。主指标不含JSON校验、缓存排空或恢复时间。

同时从128份相对job启动的逐秒bw log输出active-I/O阶段四个等时间窗的平均带宽、首30秒/首60秒
累计平均、峰值staging、
最小空闲及direct fallback。严格排空秒数另列，禁止计算“含排空有效带宽”作为前台主指标。

- W32、W64、W128相对两侧W20锚均值形成非递减序列，且W128相对锚均值`>=10%`：
  `FOREGROUND_CAPACITY_SIGNAL`；
- W128相对锚均值`<5%`，且各点无材料改善：`NO_MATERIAL_FOREGROUND_SIGNAL`；
- 其他完整结果：`RESOLUTION_INSUFFICIENT`；
- 锚漂移、fio/资产/健康/恢复硬门失败：`INCONCLUSIVE_DRIFT`或`EVIDENCE_INVALID`。

单次L1只给方向和工程幅度，不直接改生产容量；若出现材料信号，再决定是否需要业务占空比canary。

## 三、最简执行流程

### Phase 0：离线Gate 0

复用04-tmp2f的run/recovery/scrub实现，只做任务命名、五格矩阵、固定128GiB fio合同及前台分析器的
必要修改。检查shell/Python语法、fixtures、危险命令、路径守卫和sudo表面；Gate未过不得SSH。

### Phase I：只读inventory、计划与授权停点

核对二进制、META/UUID、128文件、业务挂载、`/mnt/jfs-cache`空间、Ceph健康、外来fio/任务残留；
生成本RUN全部命令、脚本SHA和完整sudo计划。到此暂停，用户确认后才可执行状态写。

### Phase II：连续五格

用户一次授权后按冻结顺序连续执行；实现bug可修但当前RUN作废并换RUN_ID，控制变量不得自行修改。
容量型排空超时保留原cell性能值但先完成既有安全恢复；非容量型错误、数据错误或恢复失败立即停止。

### Phase III：复算与收口

Luna提交raw和逐门结果，GPT从持久raw独立复算；恢复scrub与全部RUN资产，生成报告并更新状态表。

## 四、证据与生命周期

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2g/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2g-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=逐cell精确卸载/detach/rmdir及最终scrub恢复；需单独sudo授权
```

最低raw：fio JSON、128份bw log、实际fio文件、容量/metrics逐秒序列、mount和loop身份、日志错误计数、
排空/抽读、每格前后health、对象/compact/TiKV cooldown、commands、实际脚本及manifest。

## 五、安全红线

1. 全程遵守`SYSTEM-SAFETY-SKILL.md`、`EVIDENCE-INTEGRITY-SKILL.md`和
   `TEST-DATA-LIFECYCLE-POLICY.md`；先离线Gate，后环境执行。
2. 所有sudo写操作必须在Phase I完整列出并由用户确认；禁止裸NVMe mkfs、批量loop detach、
   force/lazy umount、递归删除、服务重启、pool/volume删除或其他Ceph配置写。
3. 所有路径必须是本RUN固定前缀、非空、非根、非符号链接；loop必须由backing反查唯一匹配。
4. 只覆盖已冻结的128个既有文件；缺失、大小/身份变化时停止，禁止创建、layout或换数据集。
5. 失败先保留现场；证据持久化和SHA通过前不得删最后一份远端raw。
6. 测试前后按项目skill复核health、scrub lease、compact/TiKV cooldown、统计口径与环境残留。

## 六、修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-05 | 初版：将04-tmp2f的持续压力/排空问题与用户侧固定脏写量性能问题分离。 |
| 2026-09-05 | 离线签收：修复重复fio调用；主指标冻结为fio启动—返回墙钟；固定写量、时间sidecar与四类裁决fixtures通过。 |
| 2026-09-05 | 执行后口径修复：以JSON elapsed校验墙钟，最大job runtime仅用于拆出用户可见的非active-I/O开销；不修改raw。 |
