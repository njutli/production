# 05-3 randread / randwrite BS曲线：执行记录

> **2026-09-20复核订正：`BASELINE_CONFIG_MISMATCH / RETEST_PLANNED`。** 本RUN实际使用系统 `ceph.conf`（归档SHA `8dd48e57…`），未注入05计划要求的 `ms_async_op_threads=8`；同哈希文件在只读复核中解析为3。下文数值保留为实际配置下的历史观测，不能作为8线程通用交付曲线。随机写状态漂移及4M日志缺口也未关闭，由[05-3b](../perf-tasks/05-3b-random-bs-baseline-repair-and-retest.md)承接；本订正优先于下文“当前通用配置”等原签收措辞，原始证据不改写。

> 原执行状态（受上述订正约束）：`STANDARD_MATRIX_EXECUTED / L1_PARTIAL_FORMAL_REVIEW`。正式 RUN `20260918-163841`：24/24格完成，读写两阶段及全局状态恢复均通过；第二方从原始文件独立复核数值一致。写侧BS因状态累计不能签收为单一因果曲线。

## 只读准备结果

- 准备RUN `20260918-172033`；157为 `oneasia-c1-cpu-node10`，当前无fio。现有 `/mnt/juicefs` 为 `JuiceFS:juicefs-prod`，没有变更它。
- JuiceFS二进制 `/tmp/juicefs-1.4.1-patched` 的MD5为 `24fae0852051c80ca571cb2f20275d46`；卷UUID为 `e1b69ea9-0e3d-427d-bea9-8765928afa66`，BlockSize=256 KiB。
- `read_test.{0..127}.0` 与 `storage_test.{0..127}.0` 各128个文件，均为1 GiB。Ceph FSID `f8137e5a-8af2-11f1-aa1c-4df480fc234d`，`HEALTH_OK`，6/6 OSD up/in，97/97 PG active+clean；`juicefs-data`池读写空闲，raw available约39.9 TiB。
- 客户端 `MemAvailable≈916 GiB`；抽样时96 CPU的空闲率约87%，三块主要网卡无显著业务流量；WekaIO进程仍运行。正式开跑时须重新检查这些条件。
- 离线Gate0通过；157上已用SHA256 `886873164adbf533394af0765f0935aa9ca14dae941e1fc8403cc6db917521b4`的runner重新通过只读preflight。该准备RUN只用于验证脚本与现场，不参与性能矩阵。
- 准备证据已增量持久化到 `/mnt/c/SunRise/test/05-3/20260918-172033/`，远端源位于 `/tmp/production/opencode-05-3-20260918-172033/`；两处均未清理。正式负载使用**新的RUN_ID**并冻结最终脚本SHA，不混用准备RUN的旧plan。

## 已授权的全局操作与正式进展

起点Ceph未设置 `noscrub`/`nodeep-scrub`。157上只读 `plan-pause` 确认FSID、原始flags、健康/PG与无正在运行的scrub。用户精确授权后，纯读和纯写两个phase各自执行一次：

```text
sudo ceph osd set noscrub
sudo ceph osd set nodeep-scrub
# phase结束或失败，按助手保存的原始状态，只撤销本任务新增的flags：
sudo ceph osd unset nodeep-scrub
sudo ceph osd unset noscrub
```

用户已明确授权上述精确命令。全局巡检每phase临时暂停，影响该Ceph集群所有pool的例行scrub调度；不属于生产配置。正式RUN已重新完成只读开跑门、新RUN的plan与脚本SHA核对。

- 纯读：`12/12`格 fio `rc=0`，每格128份逐job日志；phase `PASS`。私有挂载目录已消失，无fio进程；phase-a租约 `SCRUB_RESTORE_VERIFY_PASS`，flags恢复原值，Ceph `HEALTH_OK`、6/6 OSD up/in、97/97 PG active+clean，WekaIO进程83个。
- 纯写：157本地时间2026-09-18 17:18—18:09，`12/12`格 fio `rc=0`，每格128份逐job日志；phase `PASS`。私有挂载目录已消失，无fio进程；phase-b租约 `SCRUB_RESTORE_VERIFY_PASS`，flags恢复原值。
- 全流程最终：Ceph `HEALTH_OK`、6/6 OSD up/in、97/97 PG active+clean；WekaIO进程仍为83，`juicefs-data`池无活动IO，客户端`MemAvailable≈916 GiB`。没有执行GC、compact、drop_caches、volume/pool创建或删除。
- 两阶段的runner SHA256均为 `886873164adbf533394af0765f0935aa9ca14dae941e1fc8403cc6db917521b4`；scrub控制助手SHA256为 `9788c4484a087cf072ceebc00aa28c28561d77c1617f6ae7459699ef3ad028bb`。

## 六档结果：先给观测，不做跨状态因果归因

下表均为 fio JSON 的全程 `io_bytes/runtime`，单位 MiB/s。A/B是同一BS在正向/反向序列中的两个位置；**不是不同配置臂**。`正式窗`是按128份1秒日志计算的`[15,175)`；`M/M`表示两位置均通过日志覆盖与字节积分检查，`U`为`UNKNOWN/REVIEW`，其形式上的窗口数值不得作为精确带宽使用。

| 项 | BS | fio A | fio B | B相对A | 正式窗状态 |
|---|---:|---:|---:|---:|---|
| randread | 4K | 241.4 | 237.8 | −1.5% | M/M |
| randread | 16K | 796.3 | 786.5 | −1.2% | M/M |
| randread | 64K | 2008.1 | 2010.1 | +0.1% | M/M |
| randread | 256K | 3197.2 | 3073.3 | −3.9% | M/M |
| randread | 1M | 1985.3 | 1941.1 | −2.2% | M/M |
| randread | 4M | 2814.2 | 2792.8 | −0.8% | U/U |
| randwrite | 4K | 17.7 | 7.8 | −56.2% | M/U |
| randwrite | 16K | 60.4 | 29.0 | −52.1% | M/U |
| randwrite | 64K | 159.6 | 128.7 | −19.3% | U/U |
| randwrite | 256K | 2667.2 | 486.3 | −81.8% | M/U |
| randwrite | 1M | 2664.8 | 2809.9 | +5.4% | U/U |
| randwrite | 4M | 4049.8 | 4020.5 | −0.7% | U/U |

可发布的纯读正式窗（A/B，MiB/s）依次为：4K `241.7/237.5`、16K `794.3/783.2`、64K `2005.9/1998.9`、256K `3197.1/3061.8`、1M `1985.4/1942.8`。两个4M读格的日志积分仅相当于fio字节数的`87.1%/87.0%`，只保留fio全程摘要，不把日志窗口当作精确值。两个4M写格的日志积分约`90.6%/90.5%`；多数后段写格还出现逐job长缺口，因此写侧不能用窗口均值掩盖不完整采样。fio报告的写侧runtime约`180.08—242.51s`，大于设定180s的格保留额外排空/完成时长，不能拿该summary冒充恰好180s的稳态均值。

## 稳定性和归因边界

- **读侧**：4K—1M的两位置摘要漂移在`−3.9%—+0.1%`，日志正式窗覆盖且积分一致，可作当前通用配置的L1 BS—带宽曲线；4M只有可重复的fio全程观测，正式窗口径需补证才可精确比较。
- **写侧**：首尾同配置256K从`2667.2→486.3 MiB/s`（`−81.8%`）；4K、16K、64K反向位置分别比前向低`56.2%`、`52.1%`、`19.3%`。这远大于可忽略波动；不能把不同位置拼接成只由BS决定的曲线。1M/4M两位置summary接近也不抵消其他档的状态漂移，且其正式窗仍为`UNKNOWN/REVIEW`。
- **伴随状态**：12个写格期间，TiKV三节点`kv/default`待压缩字节合计约`0→100.6 GiB`；Ceph `juicefs-data`对象数约`5.65→18.50百万`，stored约`1380.5→4036.5 GiB`。这些与带宽衰减同现，支持“写入历史/后台清理状态正在改变”的解释，但**没有控制变量证明**单独哪个指标造成了多少下降。禁止把本RUN首格当作长期可交付性能，也禁止把后格下降归因于BS本身。
- 本任务的可选FUSE1M筛选**未启动**：尚无实际FUSE请求拆分的机制证据，且写侧标准曲线未取得可归因的稳定起点；不能据本RUN登记新的挂载参数候选。若05阶段必须获得可比较的纯写BS效应，需另行设计相同起点/相同历史状态的逐BS对照，而非重跑同一连续矩阵或主动清理后挑好值。

## 证据与生命周期

正式原始证据保存在`/mnt/c/SunRise/test/05-3/20260918-163841/`；157源目录为`/tmp/production/opencode-05-3-20260918-163841/`，目前保留未清理。原RUN共`3646`个文件，复制后用`rsync -rcni --checksum --no-perms --no-times`逐文件核对无内容差异（Windows挂载权限/mtime差异不计）；另持久化两份scrub租约审计和四份实际执行脚本。`derived.json`由本地离线分析器从持久副本生成，状态`PARTIAL_FORMAL_REVIEW`、24格、解析错误0；其SHA256为`262abda81bea35375b11ac25aa46d1c31196964f594d9a08ca5c93b000a5b256`，对应分析器SHA256为`77f98a6e102260f196ddf9c67ccc4fa09bf0bbf6d1f78d6c2202cf7110925e0a`，分析器副本已同证据持久化。第二方未调用该分析器、直接从原始fio/日志/Ceph/TiKV文件重算，确认24格summary、正反漂移、正式窗降级名单、两租约恢复与后端状态变化；数值复核通过，不改变L1及写侧`RANGE_ONLY`裁决。所有24格fio `rc=0`、每格128份bw日志、资产前后清单一致、phase状态PASS，无`incidents.tsv`。
