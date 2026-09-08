# 04-tmp3i：缓存命中单流读RA32与本地介质收尾

> 日期：2026-09-06
> 状态：`COMPLETED / VALID / ENVIRONMENT_CLOSED`
> 面向执行方：GPT+Luna；本任务书不授权sudo、mount、fio或环境写操作。
> 承接：04-tmp3h RUN `20260906-172359`。

```text
04-tmp3f：无缓存同步读确认RA32有约12%--15%收益，最佳仍未达竞品
04-tmp3h：T32--T128正式读均为100% block-cache命中，但仅约2.8GiB/s
        ↓
04-tmp3i：T64下只补RA32 ABBA与一次同盘本地直读       ← 你在这里
        ├─ RA32两次越线 → 登记“热缓存同步读候选”，另行做七项回归
        └─ RA32仍未越线 → 关闭缓存容量/RA参数竞品收尾线
```

一句话目标：确认最佳已知`max-readahead=32M`能否使100%缓存命中的20MiB同步单流读达到
竞品`5149.84 MiB/s`，并用同一loop/ext4的本地直读判断约2.8GiB/s是否来自缓存介质本身。

## 一、为什么只补这一点

04-tmp3h已经证明32--128GiB扩容没有趋势，故不重跑四档、cp或写测试。其正式挂载使用
`max-fuse-io=1M`，但没有显式使用04-tmp3f已经发现的RA32候选，因此“最佳已知缓存配置仍未达标”
尚差一个控制点。本任务只补该缺口。

这里的“100%命中”严格指`juicefs_blockcache_hit_bytes`占本次请求字节约100%、miss增量为0；
它不是本地NVMe带宽。介质参照只作分层解释，不参与竞品通过判定。

## 二、最小决策合同

```text
EVIDENCE_LEVEL=L1_SCREEN
UNIQUE_DECISION=RA32下两次有效正式读是否都达到5149.84MiB/s
SECONDARY_EVIDENCE=同一T64 loop/ext4上的20MiB/psync/QD1/direct本地直读能力
MATRIX=LOCAL1 -> A1 -> B1 -> B2 -> A2
A=沿用04-tmp3h挂载参数，并显式固定--max-readahead 8M
B=在A上只把--max-readahead从8M改为32M
STOP_AFTER_ANSWER=true
NO_EXPANSION=不扫RA64、缓存容量、QD、异步、cp、写、BlockSize或其他挂载参数
MAX_PREP_BUDGET=45min
MAX_EXECUTION_BUDGET=75min（纯测量约11min，其余为重挂、状态门和精确收口）
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3i/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp3i-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=精确删除本RUN缓存/LOCAL1文件、卸载并detach唯一T64 loop、删除唯一backing
```

## 三、冻结条件和矩阵

### 3.1 固定环境

- JuiceFS固定patched 1.4.1，MD5 `24fae0852051c80ca571cb2f20275d46`；复用既有B256
  `juicefs-prod`及RUN私有`ms_async_op_threads=8`配置。
- 发起端固定157；只创建一个64GiB fully allocated backing file、一个动态解析且反查匹配的loop、
  一个普通inode密度ext4。禁止sparse、裸盘和`-T largefile`。
- JuiceFS缓存固定同一个空cache-dir，`--cache-size 32768 --free-space-ratio 0.20 --writeback
  --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300`。正式阶段没有写负载，
  `writeback`仅用于保持04-tmp3h配置身份。
- 复用既有只读资产`/test_dir/seqread/seqread.0.0`的前10GiB；执行前后核对既有32GiB文件的
  inode、size、blocks及首尾hash，整个任务禁止创建、扩容、改写或删除任何JuiceFS数据文件。
- 不执行layout、format、destroy、pool/PG/CRUSH变更、OSD compact、全局`drop_caches`或scrub flag变更。
  本任务正式窗应为100%本地缓存命中，没有理由改变Ceph全局scrub状态。

### 3.2 唯一fio口径

```text
rw=read
bs=20M
size=10G
direct=1
numjobs=1
runtime=60
time_based
group_reporting
ioengine=psync（显式记录）
iodepth=1
```

每个A/B cell均先按同一命令固定预热60秒，再正式运行60秒；保存JSON及唯一1秒bw log。
四个cell分别使用独立挂载实例，顺序固定`A1→B1→B2→A2`，但复用同一cache-dir中的已缓存
只读块。每次正式窗必须重新用指标差值证明hit ratio `>=99.5%`且miss ratio `<=0.5%`。
同时记录发起端Ceph数据网卡RX差值；正式读窗`Ceph_RX/fio_read_bytes<=1%`，作为未回源的简单
旁证。该旁证失败属于缓存驻留合同失败，不得仅凭block-cache hit计数继续下结论。

| Cell | readahead | 用途 |
|---|---|---|
| LOCAL1 | 不涉及JuiceFS | 同一loop/ext4中10GiB临时文件，20MiB/psync/QD1/direct读60秒 |
| A1 | `8M`（显式） | 04-tmp3h默认值的确定性首锚 |
| B1 | `32M` | RA32确认1 |
| B2 | `32M` | RA32确认2，独立挂载实例 |
| A2 | `8M`（显式） | 04-tmp3h默认值的确定性尾锚 |

LOCAL1文件必须在JuiceFS cache-dir建立和预热之前创建、读取并精确删除；等待60秒后再开始A1，
不得让LOCAL1文件占用缓存预算。LOCAL1只回答同一loop/ext4直接读取是否具备目标量级，不把它当作
JuiceFS缓存文件路径的等价测量。

LOCAL1文件必须用顺序direct write完整写满并完成`end_fsync`后再测读，校验`stat`分配块不少于文件
大小的95%；禁止用`truncate`、sparse或仅有未写入extent的`fallocate`文件冒充介质读基线。

## 四、有效性和裁决

### 4.1 有效性门

- A/B实际命令除RA32外完全一致；binary、META、UUID、BlockSize、Ceph配置、cache-size、PID/
  starttime/exe及文件身份全部冻结。
- fio rc/error、运行时长、1秒日志覆盖、健康检查、cache指标和命中率全部通过；正式窗内不得出现
  JuiceFS/FUSE/Ceph/TiKV I/O error、panic或fatal。
- A1/A2正式窗漂移和B1/B2正式窗漂移均须`<=8%`；任一失败签`RESOLUTION_INSUFFICIENT`，不补跑。
- Ceph须保持6/6 OSD up/in、PG active+clean且无恢复；157不得存在foreign fio或受保护业务异常。
- 主性能同时报告fio summary与正式窗`[10,50)`重叠加权均值；不能挑较高口径。

同时报告A/B的fio IOPS、clat mean/p99，并校验：

```text
estimated_bw = 20MiB / clat_mean
```

它用于说明单请求延迟与带宽是否闭合，不作为删样或通过门。

### 4.2 唯一裁决

- `RA32_CACHED_SYNC_READ_TARGET_CONFIRMED`：B1、B2的summary和正式窗四个数均
  `>=5149.84 MiB/s`，且全部有效性门通过。只登记L1候选；改变生产配置前仍需七项非劣回归。
- `BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET`：RUN有效，但B1或B2任一主口径未达目标。
  关闭继续扩大缓存、RA或相邻挂载参数的竞品收尾方向。
- `RESOLUTION_INSUFFICIENT/EVIDENCE_INVALID`：分别对应漂移门或非性能门失败；禁止用局部高点下结论。

机制旁证单独报告，不改变主裁决：

- LOCAL1达到目标而B不达：支持约束位于JuiceFS缓存索引/FUSE/同步请求路径，而非本地介质吞吐；
- LOCAL1也不达：说明本次loop/ext4本地路径本身不足，不能把差额全部归因于JuiceFS；
- 不论哪种情况，均不得把LOCAL1外推为真实JuiceFS block-cache带宽。

## 五、执行阶段

### Phase 0：最小复用与离线Gate 0

1. 执行前通读`SYSTEM-SAFETY-SKILL.md`、`EVIDENCE-INTEGRITY-SKILL.md`、`TESTING-GUIDE.md`、
   `test-commands-reference.md`和`TEST-DATA-LIFECYCLE-POLICY.md`。
2. 复用04-tmp3h的inventory、T64 storage、mount身份、缓存指标、fio和cleanup组件，以及
   04-tmp3f的既有只读资产身份与20MiB psync/QD1组件；
   只保留一个runner、一个analyzer、一个Gate，禁止重写编排框架。
3. Gate只检查五格矩阵、A/B唯一变量、psync/QD1、命中率、Ceph RX旁证、既有资产只读合同、
   绝对目标、loop反查及禁止命令。
   Gate未通过不得连接环境。

### Phase I：只读inventory和唯一授权停点

只读核对环境、磁盘空间、foreign fio、现有mount/loop、文件路径、脚本SHA和业务指纹；输出全部
sudo命令、backing/loop/ext4计划、资产创建/删除和故障恢复计划。用户一次确认后，Phase II阶段内
连续完成，不逐cell停点；只有路径/设备不符、业务异常或安全边界变化才停止。

### Phase II：LOCAL1、ABBA、复算与精确收口

按固定顺序完成LOCAL1和四个JuiceFS cell，独立复算后只精确删除LOCAL1及本RUN缓存资产、优雅卸载
JuiceFS、卸载ext4、验证loop唯一backing后detach，并删除backing和空目录。由于不创建或删除
JuiceFS文件，本任务不执行共享卷GC、TiKV/OSD compact或任何对象清理。

证据持久化、manifest/SHA256/可读性核验完成前不得清理远端临时证据。最后按上述skill复核：未动
裸盘、pool/PG/CRUSH、业务服务、内核、网络、全局drop_caches或scrub flags；路径和设备均精确恢复。

## 六、安全红线与交付物

- 禁止`losetup -D`、强制/懒卸载、宽`rm -rf`、glob删除、递归chown/chmod及未解析变量；mkfs和detach
  前必须反查loop唯一对应本RUN的T64 backing。
- 禁止影响157上的WekaIO、K8s及其他业务；发现冲突立即停止并先保存最小证据。
- 所有原始fio、指标、实际命令、状态、incident、分析结果和manifest只进入唯一`EVIDENCE_ROOT`；
  COMMON只保存一次，cell只增量保存。
- 报告落点：`doc/perf-report/04-tmp3i-cached-sync-read-ra32-final-closure-<DATE>.md`；随后更新
  `results-table.md`与`04-TASK-BOOK-STATUS-20260901.md`。

## 七、修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-06 | 初版：仅补T64下RA32双确认、04-tmp3h配置双锚和一次同loop/ext4本地直读，不重跑四档或四命令。 |
| 2026-09-06 | 执行前精简：A/B显式RA8/RA32；复用既有32GiB只读资产前10GiB，删除新建文件与共享卷GC；增加Ceph RX不回源旁证；总执行预算下调至75分钟。 |
