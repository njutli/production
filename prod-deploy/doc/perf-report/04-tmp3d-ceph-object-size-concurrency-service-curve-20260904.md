# 04-tmp3d Ceph对象大小×并发服务曲线报告

## 一、裁决

| 字段 | 结果 |
|---|---|
| RUN_ID | `20260904-173955` |
| VERDICT | `OBJECT_BACKEND_HEADROOM_CONFIRMED` |
| VALIDITY_STATE | `VALID_L1_SCREEN` |
| 环境状态 | 本RUN RADOS namespace已归零；Ceph `HEALTH_OK`，97 PG全部`active+clean`，6/6 OSD up/in |
| 权威证据 | `/mnt/c/SunRise/test/04-tmp3d/20260904-173955/` |
| 证据manifest | 源端456项与本地最终460项全部校验通过；`manifest.final.sha256`的SHA256=`fa81207dfc3648a6aa071e3bb27c96c48ab05d353218c80f0cf5a330b2cd7b45` |

**直接结论：Ceph对象层不是当前大块顺序读的带宽屋顶。** 绕过JuiceFS、TiKV、VFS和FUSE后，
4 MiB对象在QD8达到`5403.20 MiB/s`，越过竞品`5149.84 MiB/s`；QD16达到
`6659.20 MiB/s`，越过项目`6250 MiB/s`目标。04-tmp3c的B4/RA32仅约`2921.87 MiB/s`，
剩余差距主要位于JuiceFS Reader/FUSE/请求生成与并发维持路径，应触发04-tmp3e最小定位。

本结论只说明对象后端存在余量，不把`rados bench`绝对值当作JuiceFS生产带宽，也不据此直接交付
B4/RA32。

## 二、测试合同

- 发起端：157；Ceph Quincy `17.2.9`；pool=`juicefs-data`；身份=`client.juicefs`。
- 隔离：唯一namespace=`04tmp3d-20260904-173955`，不挂载或修改JuiceFS卷，不连接TiKV。
- 配置：RUN私有`ceph.conf`，`ms_async_op_threads=8`；不改Ceph全局配置。
- 数据集：256 KiB对象`131072`个、4 MiB对象`8192`个，各精确32 GiB且各只seed一次。
- 矩阵：两种对象大小分别按QD=`1/2/4/8/16/32/1回环`；每点25秒，末15秒为稳定窗。
- `rados bench`输出中的`MB/sec`实际按`bytes/2^20/s`计算，报告统一记为MiB/s。
- 全程没有sudo、drop_caches、compact、scrub flag、pool/PG/CRUSH、服务、网络或内核修改。

Canary先生成一个4 KiB数据对象和一个run marker，再按唯一run-name清除，namespace从2项回到0；
由此才进入正式矩阵。

## 三、结果

### 3.1 服务曲线

| 对象大小 | QD | 稳定窗均值 MiB/s | 中位数 MiB/s | 秒级CV | 平均延迟 |
|---|---:|---:|---:|---:|---:|
| 256 KiB | 1 | 307.70 | 308.00 | 1.61% | 0.816 ms |
| 256 KiB | 2 | 647.93 | 648.75 | 1.64% | 0.779 ms |
| 256 KiB | 4 | 1327.10 | 1322.75 | 1.07% | 0.763 ms |
| 256 KiB | 8 | 2484.85 | 2510.25 | 2.68% | 0.812 ms |
| 256 KiB | 16 | 3834.28 | 3845.00 | 0.70% | 1.040 ms |
| 256 KiB | 32 | 4623.60 | 4654.25 | 1.42% | 1.722 ms |
| 256 KiB | 1回环 | 384.58 | 385.50 | 1.59% | 0.651 ms |
| 4 MiB | 1 | 828.53 | 828.00 | 1.38% | 4.931 ms |
| 4 MiB | 2 | 1787.73 | 1800.00 | 1.75% | 4.572 ms |
| 4 MiB | 4 | 3373.60 | 3372.00 | 1.38% | 4.769 ms |
| 4 MiB | 8 | **5403.20** | **5408.00** | 1.44% | 5.911 ms |
| 4 MiB | 16 | **6659.20** | **6684.00** | 3.63% | 9.580 ms |
| 4 MiB | 32 | 6434.40 | 6448.00 | 5.64% | 20.082 ms |
| 4 MiB | 1回环 | 973.60 | 972.00 | 0.54% | 4.132 ms |

### 3.2 曲线判读

- 256 KiB的QD16→32仍增加`20.59%`，QD32只到`4623.60 MiB/s`，本尺寸在当前矩阵内尚未闭合；
  继续加QD不是本任务必需，因为4 MiB尺寸已经回答目标可达性。
- 4 MiB的QD8已达到竞品线，QD16达到项目目标；QD16→32反而下降`3.38%`且延迟约翻倍，
  对象层的有效工作点在QD8--16，不需要继续扩大QD。
- 4 MiB QD8/QD16分别比04-tmp3c最佳JuiceFS点高`84.92%/127.91%`。
- 最高点客户端网络约`6.70 GiB/s`，rados进程约`2.4`个CPU核，均未先触及100GbE或整机CPU上限。

### 3.3 与04-tmp3c的闭合关系

04-tmp3c中B4/RA32只有约`4.54--4.59`个实际在途GET，带宽约`2.90 GiB/s`；直接对象曲线在
QD4为`3373.60 MiB/s`、QD8为`5403.20 MiB/s`。这说明提高BlockSize和名义readahead虽然恢复了
部分并发，但JuiceFS尚未稳定地产生达到目标所需的约8个4 MiB对象请求。下一步应在不改对象后端的
情况下定位Reader/FUSE队列为何只维持约4.6个在途GET，而不是继续盲调Ceph参数。

## 四、有效性与边界

- 14/14点rc=0、stderr为空；34组健康快照均为`HEALTH_OK`，97 PG全部`active+clean`。
- fio不参与本任务；每点保留rados逐秒原始输出、完整命令、客户端PID/CPU/RSS/NIC采样及OSD/磁盘快照。
- 256 KiB与4 MiB的QD1回环分别比首点高`24.99%/17.51%`，表明固定32 GiB对象集存在读热化。
  因此低QD首尾值不能用于精细的冷态效应量；但04-tmp3c同样反复读取固定资产，而本RUN在真实
  Ceph网络链路上直接传输了5.4--6.7 GiB/s，故“对象层能够越过两条目标线”的可达性结论不受推翻。
- OSD/磁盘快照不构成完整同窗资源平台归因；本RUN也不需要据此点名具体OSD瓶颈，因为预注册的
  第一裁决分支已经由对象吞吐越线满足。

## 五、清理与证据索引

- 清理前manifest：`closure/cleanup-manifest.tsv`，`139266`行，SHA256=
  `e4422cef2b6a21d87964d3c6d0093747a1c0b3434de1ada863f7fef1ca43a4a9`。
- 精确清理结果：b256 run删除`131072`个对象，b4 run删除`8192`个对象；两个run marker同步清除，
  `closure/namespace-after.tsv`为空。
- 原始点值：`cells/<size>-QD*/stdout`与`analysis.json`；seed合同：`cells/b256-SEED/`、
  `cells/b4-SEED/`；命令：`commands.sh`；生命周期：`run-state.tsv`与`incidents.tsv`。
- 唯一事故是正式矩阵前按canary校准rados单位并补seed完整性门；正式数据开始后脚本未改动。
- 157上的本RUN证据目录和bootstrap目录在本地最终manifest通过后已精确删除；远端副本不可恢复，
  本地权威证据完整保留，审计见`remote-purge-audit.tsv`。

## 六、下一步

触发04-tmp3e，但只做最小定位：在同一B4数据资产和对象后端不变的条件下，观察提高Reader/FUSE侧
有效对象并发是否能把在途GET从约4.6推向8，并同步检查CPU、FUSE队列和对象GET。如果无法产生更多
在途请求，则形成上层架构限制；若可以且带宽继续增长，再补随机/写和七项回归，之后才讨论B4配置交付。
