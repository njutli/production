# 04-tmp3h竞品四命令客户端缓存容量收口报告

> 日期：2026-09-06
> RUN_ID：`20260906-172359`
> VALIDITY_STATE：`VALID_FOR_FIO_CAPACITY_STOP / CP_COMPARABILITY_INVALID`
> VERDICT：`NO_VERIFIED_CACHE_BUDGET_LE_128G`
> 环境：patched JuiceFS 1.4.1、B256 `juicefs-prod`、NVMe loop/ext4缓存、read cache + writeback。

## 一、结论

在32/64/96/128 GiB四档物理缓存中，20 MiB同步单流direct读均已达到`100%` JuiceFS缓存命中，
但正式窗带宽始终只有`2743.77--2802.85 MiB/s`，最佳仅为竞品`5149.84 MiB/s`线的`54.43%`。
缓存容量扩大没有趋势性收益，因此失败原因不是“缓存放不下”，继续增大容量也不能使原四命令全部越线。

16 MiB同步单流写的最佳正式窗为`2866.38 MiB/s`，达到竞品`3051.76 MiB/s`线的`93.93%`，仍未越线；
各档写回均在严格双零门下10秒排空。读项已在每档独立否定“四项全过”，所以按早停合同不执行REV，
也不扩至256 GiB。

本RUN的cp本地源/目标与cache backing同位于`/dev/nvme1n1`，使cp同时读写同一物理盘，不具备与竞品
`/tmp`端点的严格可比性。cp数值只保留为工程观察，不参与上述否定结论；否定结论仅依赖路径独立的
fio direct读在四档100%缓存命中时仍显著低于目标这一充分条件。

## 二、正式结果

共同挂载参数：`--max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300
--free-space-ratio 0.20 --writeback`；T32/T64/T96/T128的`--cache-size`分别为16/32/40/40 GiB。

| 档位 | cp读 GB/s* | fio读正式 MiB/s | 读命中率 | cp写 GB/s* | fio写正式 MiB/s | fio写含排空 MiB/s | 严格排空 |
|---|---:|---:|---:|---:|---:|---:|---:|
| T32 | 1.691 | 2802.85 | 100% | 0.846 | 2711.32 | 2479.34 | 10s |
| T64 | 1.708 | 2768.85 | 100% | 1.013 | **2866.38** | 2624.75 | 10s |
| T96 | 1.719 | 2743.77 | 100% | 1.044 | 2675.33 | 2442.57 | 10s |
| T128 | 1.679 | 2776.71 | 100% | 1.030 | 2863.04 | **2626.78** | 10s |

\* cp端点与缓存backing共用同一NVMe，存在确定的同盘读写竞争，仅为工程观察。

fio读CV为`2.18%--3.28%`，容量扩大后没有单调上升；fio写CV为`6.36%--7.44%`。正式写期间观测到的
staging峰值仅约`1.25--250.75 MiB`，表明当前单流写负载没有形成与32--128 GiB容量同量级的脏数据
积压；扩大缓存不能消除当前同步写路径的服务率上限。

## 三、机制边界与生产意义

- 读侧：100%命中已经隔离Ceph后端读取，剩余约2.75 GiB/s屋顶位于本地NVMe/loop/ext4、JuiceFS
  block cache、FUSE和同步QD1请求链路的组合；本RUN只证明“容量不是限制”，不把屋顶强归因到单一组件。
- 写侧：writeback可以吸收前段写入且四档均迅速排空，但容量从64增到128 GiB没有继续提高前台带宽；
  这与04-tmp2g“约64 GiB后平台”的方向一致。
- 本任务不否定读缓存和writeback的生产价值。它只说明：在当前客户端NVMe及原始同步单流命令下，
  不能靠扩大到128 GiB缓存同时超过竞品四条披露值。
- 若以后需要重测cp竞品口径，应把20 GiB本地源和目标放到与cache backing不同的设备或足够大的tmpfs；
  本任务无需为此重跑，因为fio读已构成“四项不可能全过”的充分否定证据。

## 四、执行修复与证据使用

执行期间发现并修复四个编排问题：root所有的本地目录缺少精确创建权限、buffered cp页缓存命中导致
JuiceFS缓存计数零增量被误拒、已恢复scrub lease不能复用、TiKV带标签指标正则多转义。所有问题均在
已批准路径和操作类型内修复；T32四条原始命令没有重跑，空分析文件被保留后仅使用原始fio/cp/metrics
复算，之后完成重挂读回和精确收口。T64--T128按修复后的冻结脚本执行。

## 五、环境与证据闭环

- 四档loop/ext4/backing均逐档精确销毁，RUN专属读写资产和本地目录已删除；
- 最终GC扫描`1,978,552`个对象，全部valid，pending/leaked/delslices/delfiles均为0；对象数回到
  `1,978,609`，与准备前O0完全一致；
- scrub flags恢复；无04-tmp3h mount、进程、loop、backing或本地目录残留；
- Ceph最终`HEALTH_OK`、6/6 OSD up/in、97 PG全`active+clean`；
- 最终证据：`/mnt/c/SunRise/test/04-tmp3h/20260906-172359/final/raw/04tmp3h-20260906-172359-evidence.tar`；
  SHA256=`6aaa4b6f8373e6a61c2e4cc66e9b839e317127b9cb58fbb060b4dfd74cf80b10`；归档内
  manifest独立复验`450/450 PASS`。

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3h/20260906-172359
MANIFEST_PATH=final归档内 manifest.sha256
PERSISTENCE_STATUS=PASS
REMOTE_STATUS=ARCHIVE_PRESENT_PENDING_REVIEW
LOCAL_STATUS=PRESERVED
INCIDENT_STATUS=RESOLVED_WITHOUT_T32_FIO_RERUN
ENVIRONMENT_ASSET_STATUS=CLOSED
```

## 六、后续

关闭“通过继续扩大客户端缓存容量使原竞品四命令全部越线”方向。保留现有读缓存、writeback条件性交付
结论；若目标改为提高大块同步单流读，应从本地缓存介质性能和同步请求链路入手，而不是继续扩容。
