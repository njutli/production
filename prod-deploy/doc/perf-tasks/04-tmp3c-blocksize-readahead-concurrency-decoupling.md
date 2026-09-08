# 04-tmp3c 任务书：BlockSize 与 readahead 对象并发解耦

## 状态与最小执行合同

| 字段 | 冻结值 |
|---|---|
| 日期/实验号 | 2026-09-04 / `TMP-H3C-BIGSEQ3`（不占正式 04-N） |
| 当前状态 | `COMPLETED_L1 / RUN 20260904-165911 / ENVIRONMENT_CLOSED` |
| 证据等级 | `L1_SCREEN`；只回答机制和是否值得继续，不直接修改生产配置 |
| 前置证据 | 04-tmp3b RUN `20260904-132417`；B256/RA8约`2500.81 MiB/s`，B4/RA8约`1654.46 MiB/s` |
| 唯一权威证据根 | `/mnt/c/SunRise/test/04-tmp3c/<RUN_ID>/` |
| 157临时结果根 | `/tmp/production/opencode-04tmp3c-<RUN_ID>/` |
| 预计时长 | 离线准备不超过60分钟；环境执行、持久化和恢复合计约`1.5--2.5 h`、上限`3 h` |
| 环境清理 | 两个临时volume按META和UUID精确destroy；禁止删除/重建Ceph pool |

```text
EVIDENCE_LEVEL=L1_SCREEN
MINIMUM_DECISION_SET=B256/RA8双锚 + 同一B4卷RA8/RA32单个ABBA，共6个60秒读cell
STOP_AFTER_ANSWER=判清B4下降是否由对象并发坍缩造成后立即停止；不测写、不扩七项、不现场增加RA64/B16
MAX_PREP_BUDGET=60min
MAX_EXECUTION_BUDGET=3h（含持久化和环境恢复）
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3c/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp3c-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=证据持久化后，按独立plan和ACK精确umount/destroy两个临时volume；当前卷、pool和业务挂载不变
```

执行前必须通读 `TASK-BOOK-AUTHORING-GUIDE.md`、`TEST-DATA-LIFECYCLE-POLICY.md`、
`skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`、
`skills/TESTING-GUIDE.md`（§1.3/§2.2/§3）和`skills/test-commands-reference.md`（§8.3）。

```text
04-tmp3b：B4/RA8下降约34%，但RA8只容纳2个4MiB对象
  → 04-tmp3c（你在这里）：B4卷内RA8/RA32解耦，再用B256/RA8夹住环境漂移
       ├─ RA32提高并发且恢复带宽 → 原B4负结论被推翻，进入04-tmp3d测对象层屋顶
       └─ RA32无材料改善 → 4MiB在已测窗口无升级价值，仍进入04-tmp3d定位Ceph屋顶
  → 04-tmp3d：绕过FUSE/元数据测对象大小×并发服务曲线
       └─ 后端有足够余量时，才允许设计04-tmp3e
```

一句话：**在同一个B4卷内只改变readahead，确认04-tmp3b的B4下降究竟是4MiB GET本身太慢，
还是固定8MiB窗口把在途对象从约11.5个压到了约2.3个。**

## 一、背景与唯一问题

04-tmp3b把B256和B4都固定为`--max-readahead 8M`。这在字节数上相同，但分别只覆盖：

```text
B256：8MiB / 256KiB = 32 blocks，源码maxRequests约65
B4：  8MiB / 4MiB   =  2 blocks，源码maxRequests约5
```

实测B4的GET从256KiB增至约4MiB后，单GET时延由约`1.15 ms`升至`5.59 ms`，但每请求有效
传输率反而由约`217 MiB/s`升至`716 MiB/s`；带宽下降的直接伴随量是在途GET由约`11.5`降至
`2.3`。此外，JuiceFS未显式设置时使用`readahead=8×BlockSize`，B4默认应为32MiB。

因此04-tmp3b只证明`B4+RA8`较慢，不能证明4MiB BlockSize本身没有价值。本任务唯一要回答：

> **把B4恢复到默认比例的RA32后，对象在途量和20MiB单流读带宽是否材料性恢复，并能否达到或
> 超过同窗B256/RA8锚点？**

不回答生产是否改为B4；format BlockSize不可在线修改，任何候选还需要随机I/O回归和正式L2。

## 二、固定条件、矩阵和裁决

### 2.1 固定条件

- 二进制：`/tmp/juicefs-1.4.1-patched`，期望MD5
  `24fae0852051c80ca571cb2f20275d46`；不符即停。
- 后端：现有TiKV endpoints和`juicefs-data` pool不变；只新建两个带RUN_ID的临时volume/对象前缀，
  不创建、删除或改配pool，不改PG/CRUSH/OSD/TiKV/网络/内核。
- volume：B256=`--block-size 256K`，B4=`--block-size 4M`；除Name、UUID、对象前缀和BlockSize外，
  Setting逐项相同且均不得等于`juicefs-prod`。
- 两卷各只layout一次同内容、非稀疏的10GiB读资产；fsync、卸载重挂后冻结size与抽样hash。
- layout不进入性能结果；完成后按`TESTING-GUIDE`检查OSD/TiKV compaction三指标并等待全绿、
  pool对象数稳定和PG quiet，再冻结共同起点。若确需主动compact，须先列出实际状态变更命令另行授权。
- 公共挂载参数：`--max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300
  --cache-size 0`，`async_dio=off`，使用RUN私有`ms_async_op_threads=8`；只允许RA变化。
- fio：`rw=read, bs=20M, size=10G, runtime=60, time_based, ioengine=psync, iodepth=1,
  direct=1, numjobs=1`；保存JSON、stdout和1秒bw log。
- 不执行`drop_caches`，不暂停scrub；若scrub/recovery/backfill与正式窗重叠，对应cell无效并停止，
  不在同一RUN补样。

### 2.2 最小矩阵

```text
C01 B256/RA8
C02 B4/RA8
C03 B4/RA32
C04 B4/RA32
C05 B4/RA8
C06 B256/RA8
```

C02--C05在同一B4 volume上构成单个RA8/RA32 ABBA；C01/C06只用于夹住环境漂移和提供同窗B256
工程锚，不扩成第二套矩阵。历史04-tmp3b raw只作复现旁证，不替代本RUN锚点。

每个cell至少输出：

- 正式窗mean/median/CV、四窗、fio clat mean/p99；
- FUSE read次数/字节；GET次数/字节/累计时延及错误数；
- `avg_get_size`、`avg_get_latency`以及Little定律推算
  `inflight = throughput × avg_get_latency / avg_get_size`；
- 157 CPU/RSS/thread、Ceph数据网卡吞吐；每cell前后记录Ceph health、PG状态和OSD up/in状态；
- 元数据操作总量/速率，只用于证明其数量级是否足以主导稳态，不另生分支。

本任务是L1最小因果筛查，不做六OSD逐秒perf/CPU/块设备全剖析：这些采集成本高、可能扰动短窗口，且
不影响“同一B4卷只改RA是否恢复在途GET和带宽”的裁决。若需定位对象层服务屋顶，统一在04-tmp3d
采集六OSD的op_r、延迟、CPU、util/await，避免在本任务重复建设仪表。

### 2.3 预注册裁决

1. 两个RA32相对相邻RA8均提升`>=10%`，且GET在途量同向提高、错误率不恶化：签
   `READAHEAD_OBJECT_CONCURRENCY_CAUSAL_SIGNAL`，明确撤销“B4本身无读收益”的旧强结论。
2. RA32相对RA8不足`5%`或方向相反：签`B4_RA32_NO_MATERIAL_RECOVERY`；只说明在B4默认比例窗口
   下未恢复，不外推到所有BlockSize/RA组合。
3. `5%--10%`或两配对方向不一致：签`RESOLUTION_INSUFFICIENT`，不补轮；直接由04-tmp3d的对象层
   曲线决定是否值得再测RA64/B16。
4. B4/RA32相对两侧B256/RA8均提升`>=10%`且机制同向：登记为L2候选；未达到竞品
   `5149.84 MiB/s`仍须明确写“未达目标”。
5. 达到答案即停止。RA64、B16、写测试和随机回归都不是本RUN自动扩展项。

## 三、执行与安全边界

### 阶段0：离线Gate 0与计划停点

1. 通读上述skill；优先复用04-tmp3b的inventory、临时卷、挂载、采集、分析和清理组件，只对新矩阵
   与新判据补Gate。
2. Gate必须静态证明：无`sudo`写、无reboot/service/网络/内核操作、无pool create/delete、无
   force/lazy umount、无通配符/递归删除，volume Name/META/UUID/前缀和当前卷完全隔离。
3. 只读inventory后生成format、layout和destroy的完整实际命令及精确目标。**在format/layout和最终
   destroy前各需一次环境资产ACK；证据清理授权不能代替。**

### 阶段1：连续执行

获得ACK后允许执行方连续完成：创建两卷、生命周期canary、各一次layout、quiet门、6个读cell、
离线分析和增量持久化；不要逐cell停。任一身份/健康/fio/日志/采集硬门失败立即停并保留最小现场。

### 阶段2：审核、恢复与报告

第二方先从raw独立复算，再按精确META+UUID计划destroy临时卷。必须证明当前卷UUID、业务挂载PID/
starttime、32GiB既有资产指纹、pool和Ceph健康未变；环境恢复后写正式报告并更新results-table。

## 四、通用注意事项与红线

- 数据统计、稳定性、挂载档位压力测试、证据完整性和生命周期统一遵循
  `TASK-BOOK-AUTHORING-GUIDE.md`及`TEST-DATA-LIFECYCLE-POLICY.md`；不得挑轮或把L1写成正式效应。
- 157的WekaIO/K8s/md0、现有`/mnt/juicefs`、网络、内核和系统页缓存均不可触碰。
- 不设置`noscrub/nodeep-scrub`；Ceph必须`HEALTH_OK`、PG全`active+clean`、无恢复/回填。
- layout后的compact/cooldown、每cell前health门和实际I/O起点后的重叠加权正式窗不得因L1而省略。
- format不等于清理；最终只能对本RUN登记的临时META执行`juicefs destroy META UUID --yes`。
- 禁止`ceph osd pool delete/create`、OSD/TiKV restart、`kill -9`、lazy/force umount、递归删除和
  未核对路径/UUID的清理。
- 实现性脚本bug可在不改变变量时修复并留incident；改变矩阵、RA、BlockSize、资产或清理方式必须停。
- 原始证据、实际脚本、`commands.sh`和manifest进入唯一持久根后才允许清远端临时证据。
- 测试后必须按skill复核：实际命令、正式窗、所有raw、非性能门、临时资产清理及业务指纹全部闭合。

## 五、交付物

- `doc/perf-report/04-tmp3c-blocksize-readahead-concurrency-decoupling-<DATE>.md`
- `/mnt/c/SunRise/test/04-tmp3c/<RUN_ID>/`中的raw、derived、commands、实际脚本、manifest和生命周期账
- `doc/deploy-log/results-table.md`中的L1机制结论
- 对04-tmp3b报告中BlockSize结论的显式订正；不得静默覆盖旧实验事实
