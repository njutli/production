# 04-tmp3d 任务书：Ceph对象大小×并发服务曲线

## 状态与最小执行合同

| 字段 | 冻结值 |
|---|---|
| 日期/实验号 | 2026-09-04 / `TMP-H3C-OBJECT-CURVE`（不占正式 04-N） |
| 当前状态 | `COMPLETED_L1 / OBJECT_BACKEND_HEADROOM_CONFIRMED / ENVIRONMENT_CLOSED`；RUN `20260904-173955` |
| 证据等级 | `L1_SCREEN`；数据路径定位，不产生生产配置 |
| 前置关系 | 读取04-tmp3c结论后执行；无论其有无信号，本任务都可回答对象层屋顶 |
| 唯一权威证据根 | `/mnt/c/SunRise/test/04-tmp3d/<RUN_ID>/` |
| 157临时结果根 | `/tmp/production/opencode-04tmp3d-<RUN_ID>/` |
| 预计时长 | 离线准备不超过60分钟；环境测试与恢复约`1.5--2.5 h`、上限`3 h` |
| 环境清理 | 只删除本RUN、当前cell、唯一RADOS namespace内按manifest登记的对象；禁止删pool |

```text
EVIDENCE_LEVEL=L1_SCREEN
MINIMUM_DECISION_SET=256KiB和4MiB对象，各测QD=1/2/4/8/16/32的直接读服务曲线；写入只作读资产seed和PUT旁证
STOP_AFTER_ANSWER=定位对象层是否达到5149.84/6250MiB/s及所需QD后立即停止；不默认增加1MiB/16MiB
MAX_PREP_BUDGET=60min
MAX_EXECUTION_BUDGET=3h（含持久化和精确对象清理）
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3d/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp3d-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=只清本RUN唯一namespace内manifest对象；清理前后列对象并核对，pool/volume/META均不变
```

执行前必须通读 `TASK-BOOK-AUTHORING-GUIDE.md`、`TEST-DATA-LIFECYCLE-POLICY.md`、
`skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`和
`skills/TESTING-GUIDE.md`（§1.3/§2.2/§3）。

```text
04-tmp3c：判清B4下降是否由readahead对象并发坍缩造成
  → 04-tmp3d（你在这里）：绕过fio/FUSE/元数据，直接测Ceph对象读服务曲线
       ├─ 对象层达到目标、JuiceFS未达到 → 上层流水线有余量，允许编写04-tmp3e
       ├─ 对象层也低于目标且已到平台 → Ceph/librados/OSD数据路径是当前屋顶
       └─ 曲线未到平台或证据不闭合 → 只补一个判别点或签分辨力不足，不扩全矩阵
```

一句话：**用同一客户端、同一Ceph pool和同一librados链路，绕过JuiceFS元数据与FUSE，直接回答
“对象层本身能否达到竞品5.4GB/s或网卡半速，以及需要多少在途对象”。**

## 一、背景与唯一问题

04-tmp3b读raw可用Little定律闭合：B256/RA8约`11.5`个在途256KiB GET、约`2500.81 MiB/s`；
B4/RA8约`2.3`个在途4MiB GET、约`1654.46 MiB/s`。达到竞品`5149.84 MiB/s`，按当时延迟约需
24个256KiB GET或7.2个4MiB GET。客户端CPU和100GbE均未饱和，但该证据无法区分：

1. JuiceFS Reader/FUSE没有生成足够并发；
2. librados/Ceph/OSD在更高并发下本身就到平台。

本任务唯一问题是：**绕过JuiceFS元数据、VFS和FUSE后，Ceph对象读服务曲线的吞吐平台在哪里，
达到目标需要的对象大小与QD是多少？**

## 二、工具、隔离和矩阵

### 2.1 工具选择门

优先复用157现有Ceph客户端和04-tmp3b的RUN私有`ceph.conf`，用`rados bench`或等价的现成
librados工具；不得为了本任务修改JuiceFS/Ceph源码。离线Gate 0和只读capability probe必须先确认：

- 工具支持明确的对象大小、线程/QD、run-name以及唯一RADOS namespace；
- 写、读、列举和cleanup都能被限制在该namespace；
- 1个小对象canary可由清理前后列表证明精确删除，pool其他namespace对象数和当前卷不变。

若现场工具不能同时保证**固定namespace、可复算吞吐、精确清理**，签`TOOLING_BLOCKED`并停止，
不得退化为在默认namespace里按模糊前缀批量删除。`juicefs objbench`会自动生成纳秒前缀，只有执行器
能提前/实时记录该前缀并在中断后精确枚举时才可采用；不能依赖正常退出时的自动删除作为唯一恢复手段。

### 2.2 固定隔离

- pool只使用现有测试数据pool `juicefs-data`，禁止create/delete/改配；每个RUN使用
  `04tmp3d-<RUN_ID>`唯一RADOS namespace，每个size使用唯一run-name。
- 使用与JuiceFS Ceph插件相同的cluster/user、认证材料和RUN私有`ms_async_op_threads=8`；实际身份、
  ceph.conf和二进制版本必须记录。
- 不挂载、format或destroy JuiceFS volume，不连接TiKV，不接触`juicefs-prod`对象命名空间。
- 不执行drop_caches，不设置scrub flags；出现scrub/recovery/backfill重叠就停止，避免把全局状态改动
  引入一个短L1任务。
- 每种对象大小只seed一次，读QD曲线复用该固定对象集；每点至少覆盖15秒稳定窗且数据集至少能让
  QD32持续工作，不用几百毫秒结果外推屋顶。
- seed不进入读结果；seed后必须等PG全`active+clean`、对象数稳定且OSD compaction/恢复状态满足
  `TESTING-GUIDE`再开读曲线。需要主动compact时先列实际命令并取得独立授权。

### 2.3 最小矩阵

```text
对象大小：256KiB、4MiB
读QD：    1、2、4、8、16、32
顺序：    每个size从低QD升到高QD，再以QD=1复测一次回环锚
```

seed写只记录PUT吞吐/平均时延，**不作为完整写服务曲线**。1MiB和16MiB不是默认矩阵：

- 只有256KiB与4MiB的曲线交叉位置无法判断时，允许追加1MiB一个尺寸；
- 只有4MiB在QD32仍明显增长、04-tmp3c也显示B4有材料收益时，才另行申请16MiB；
- 任何追加都必须先在阶段裁决点说明缺少哪一个判别信息，不得现场顺手扫参。

每个点保存工具原始输出、实际起止时间、总字节/对象数、吞吐、平均/尾延迟、错误数，并同步采集：

- 157 CPU、RSS、线程、Ceph数据网卡吞吐；
- 六OSD的op_r/s、op_r字节/s、apply/commit延迟、CPU；
- 六块OSD数据盘的吞吐、IOPS、util和await；
- PG状态及每个测试对象实际primary分布的最小充分证据。

### 2.4 预注册裁决

以两条参考线判读：竞品读`5149.84 MiB/s`、项目目标`6250 MiB/s`。

1. 直接对象层达到参考线，而04-tmp3c最佳JuiceFS点明显低于对象层：签
   `OBJECT_BACKEND_HEADROOM_CONFIRMED`；差额位于JuiceFS Reader/FUSE/请求生成路径，允许编写
   04-tmp3e。
2. 输入QD继续增加，但对象层吞吐增幅连续两档均`<5%`、延迟/队列增加且客户端CPU/NIC仍有余量，
   平台低于参考线：签`CEPH_OBJECT_SERVICE_PLATEAU_IDENTIFIED`；后续应定位librados、OSD primary、
   OSD内存/盘或EC路径，不再盲调fio bs/readahead。
3. 只有客户端CPU或网卡先饱和：按实际组件签`CLIENT_CPU_LIMITED`或`NETWORK_LIMITED`。
4. QD32仍增长且未触及资源上限：签`CURVE_NOT_CLOSED`；最多按上面的条件补一个尺寸或一个QD，不把
   L1扩成无边界扫参。

## 三、执行阶段与授权

### 阶段0：离线Gate 0与只读计划

复用现有inventory/sidecar/分析组件；新脚本只负责唯一namespace、seed/read/cleanup和曲线汇总。
Gate静态拒绝：空RUN_ID/namespace、默认namespace、pool管理命令、通配或递归删除、`rados cppool/rmpool/
purge`、sudo写、系统/服务/网络/内核修改。先输出全部实际命令，不连接环境。

### 阶段1：capability与cleanup canary停点

只读探测工具help/version和pool身份；随后在唯一namespace写1个小对象、列举、按精确对象名删除并证明
namespace归零。该canary及正式seed都是环境写操作，须在计划审核后取得一次明确ACK。失败就停止，
不得运行正式曲线。

### 阶段2：正式曲线连续执行

获ACK后允许连续完成两个size的seed、读曲线、回环锚、分析和证据增量持久化，不逐QD停。任一
health、身份、错误、采集或回环漂移硬门失败就停；禁止删除未持久化的最后一份事故证据。

### 阶段3：精确清理与报告

清理前从namespace实际列表生成对象manifest，逐项核对均属于本RUN；按经过canary证明的精确方式
删除，并确认namespace归零、pool其他对象与当前业务卷指纹未变。清理环境资产仍需独立plan/ACK。

## 四、通用注意事项与红线

- 本任务会直接向Ceph写临时对象，但不使用sudo；**非sudo不等于可越过环境资产授权**。
- 禁止删除/创建pool、修改PG/CRUSH/primary、设置Ceph config/flags、重启OSD或清全局缓存。
- 正式点使用实际I/O起点、固定稳定窗和同窗sidecar；不得拿工具初始化/cleanup时间计算吞吐。
- 禁止默认namespace、空namespace、模糊前缀删除、通配符、递归删除和未核对对象集合的cleanup。
- 157上的WekaIO/K8s/md0、现有`/mnt/juicefs`、网络和内核是保护区；不得以直接对象测试为由改动。
- 只用L1说明“是否存在后端余量/平台”；工具模型与JuiceFS对象命名不同，不能把绝对值直接写成
  JuiceFS生产性能。
- 脚本bug可在不改变矩阵/对象身份/清理边界时修复并记录；改变工具、尺寸、QD或清理方式必须停。
- raw、实际脚本、`commands.sh`、namespace对象清单和manifest持久化后，才允许清理远端证据。
- 测试后按skill逐项复核健康、原始吞吐、采样覆盖、对象归零、业务指纹和生命周期状态。

## 五、交付物

- `doc/perf-report/04-tmp3d-ceph-object-size-concurrency-service-curve-<DATE>.md`
- `/mnt/c/SunRise/test/04-tmp3d/<RUN_ID>/`中的原始工具输出、sidecar、曲线、commands、实际脚本、
  namespace对象manifest、清理审计和总manifest
- `doc/deploy-log/results-table.md`中的数据路径归因结论
- 若且仅若签`OBJECT_BACKEND_HEADROOM_CONFIRMED`，提出04-tmp3e最小矩阵；否则不编写其脚本
