# 04-tmp3c BlockSize 与 readahead 对象并发解耦报告

## 一、结论

正式 RUN `20260904-165911` 签：

```text
READAHEAD_OBJECT_CONCURRENCY_CAUSAL_SIGNAL
```

在同一个 4 MiB BlockSize 临时卷内，仅将 `max-readahead` 从 8 MiB 提高到 32 MiB：

- 两组相邻配对带宽分别提高 `73.60%` 和 `77.55%`；
- Little 定律估算的在途 GET 分别从 `2.34→4.54`、`2.33→4.59`，约翻倍；
- GET 大小保持约 4 MiB，错误数没有恶化；
- 两侧 B256/RA8 锚点漂移只有 `-1.56%`，不能解释上述增益。

因此，04-tmp3b 的“B4/RA8 比 B256/RA8 慢约 34%”不是 4 MiB 对象本身的负效应，主要是固定
8 MiB readahead 将可用对象并发压缩到约 2 个所致。B4/RA32 平均约 `2899.37 MiB/s`，又比本 RUN
B256/RA8 平均值高 `12.50%`，应登记为后续 L2 候选；但最佳 `2921.87 MiB/s` 仍只有竞品
`5149.84 MiB/s` 的 `56.74%`，不能据此交付生产，也不能停止对象层瓶颈定位。

## 二、执行合同

| 项目 | 固定值 |
|---|---|
| JuiceFS | patched v1.4.1，MD5 `24fae0852051c80ca571cb2f20275d46` |
| 后端 | 现有 TiKV endpoints、`juicefs-data` pool；仅创建两个 RUN 私有 volume |
| 临时卷 | B256=`256 KiB` BlockSize；B4=`4 MiB` BlockSize |
| 数据 | 每卷一次性写入同内容、非稀疏 10 GiB 资产，卸载重挂后校验 size/inode/mtime/首尾哈希 |
| 公共挂载 | `max-fuse-io=1M`、`max-downloads=200`、`max-uploads=150`、`buffer-size=300`、`cache-size=0`、`async_dio=off`、RUN 私有 `ms_async_op_threads=8` |
| fio | `read/20M/10G/60s/time_based/psync/iodepth=1/direct=1/numjobs=1` |
| 正式窗 | 实际 I/O 起点后的 `[10,50)s`，1 秒日志按区间重叠加权 |

矩阵为 `B256/RA8 → B4/RA8 → B4/RA32 → B4/RA32 → B4/RA8 → B256/RA8`。除
BlockSize 对照和 B4 卷内 readahead 外不改变其他变量，不执行 `drop_caches`、scrub 控制、active
compact、pool/PG/OSD、网络、内核或服务操作，全程无 sudo。

## 三、正式结果

| Cell | 参数 | mean / median MiB/s | CV | 四个 10 秒窗 MiB/s |
|---|---|---:|---:|---:|
| C01 | B256/RA8 | `2597.39 / 2590.00` | `2.24%` | `2614.5 / 2588.3 / 2586.3 / 2600.5` |
| C02 | B4/RA8 | `1657.17 / 1660.00` | `1.74%` | `1658.2 / 1658.2 / 1650.2 / 1662.2` |
| C03 | B4/RA32 | `2876.86 / 2861.43` | `4.06%` | `2784.3 / 2800.3 / 2950.3 / 2972.6` |
| C04 | B4/RA32 | `2921.87 / 2920.00` | `3.78%` | `2934.3 / 2850.3 / 2948.6 / 2954.3` |
| C05 | B4/RA8 | `1645.66 / 1640.00` | `1.75%` | `1618.2 / 1650.2 / 1654.2 / 1660.2` |
| C06 | B256/RA8 | `2556.89 / 2580.00` | `3.50%` | `2608.5 / 2560.3 / 2548.5 / 2510.3` |

| 配对 | mean 效应 | median 效应 | 裁决 |
|---|---:|---:|---|
| C03 / C02 | `+73.60%` | `+72.38%` | 超过预注册 `10%` 门 |
| C04 / C05 | `+77.55%` | `+78.05%` | 超过预注册 `10%` 门 |
| C06 / C01 | `-1.56%` | `-0.39%` | 环境锚漂移很小 |

B4/RA32 的两点分别比两个 B256/RA8 锚点高 `10.76%--14.27%`，满足任务书的 L2 候选登记条件。

## 四、机制证据

| Cell | GET 均值 | GET 平均时延 | Little 在途量 |
|---|---:|---:|---:|
| C01 B256/RA8 | `256.0 KiB` | `1.148 ms` | `11.93` |
| C02 B4/RA8 | `3.999 MiB` | `5.653 ms` | `2.34` |
| C03 B4/RA32 | `3.999 MiB` | `6.312 ms` | `4.54` |
| C04 B4/RA32 | `3.998 MiB` | `6.279 ms` | `4.59` |
| C05 B4/RA8 | `3.999 MiB` | `5.652 ms` | `2.33` |
| C06 B256/RA8 | `256.0 KiB` | `1.150 ms` | `11.76` |

RA32 没有降低单次 4 MiB GET 时延，时延反而从约 `5.65 ms` 升到 `6.28--6.31 ms`；收益来自
允许更多大对象请求重叠，使在途量约翻倍。请求数降低后单 GET 平均时延升高并不矛盾：4 MiB 请求
服务时间本来就高于 256 KiB 请求，而且 RA32 提高并发后增加了对象层排队；总带宽仍因并行度提升而
增长。该结果直接订正了“增大 BlockSize 无收益”的过强解释。

## 五、证据有效性与事故记录

- 6/6 fio 均 `error=0`，实际 runtime 为 `60001--60011 ms`，写字节为 0，读字节超过 10 GiB，
  证明 `time_based` 循环读确实执行；fio 3.28 的 JSON 不保留该 flag，实际命令由 `commands.sh` 固定。
- 每格客户端 sidecar 59 个采样点、JuiceFS metrics 941 行；GET 字节、次数、累计时延使用精确
  `method="GET"` label，并在正式窗边界取相邻计数器快照。
- 12 个 cell 前后健康门均为 `HEALTH_OK`、PG 全 `active+clean`；layout 后六 OSD 的
  `compact_queue_len/compact_running` 均为 0，未执行 active compact。
- 当前 `juicefs-prod` 的 UUID、Setting、业务挂载 PID/starttime、32 GiB 资产 inode/size/mtime/
  首尾哈希在执行前后完全一致；六格 EROFS 探针均通过。
- 前置 RUN `20260904-165124` 的 C01 fio 成功，但首版分析器错误要求 JSON 必须显式出现
  `time_based` 字段，已标 `EVIDENCE_INVALID`，其性能值不进入本报告；证据先持久化后，两个临时卷
  已精确销毁。修复只放宽 JSON 表现形式，仍要求实际命令审计、约 60 秒 runtime 和读量超过 size。
- GPT 与 Luna 分别从 raw 独立复算，正式数字一致；唯一差异为 Python 浮点打印末位，不影响结果。

## 六、环境恢复和证据索引

- 正式 RUN 两个临时卷 UUID：B256=`8ed6c240-c4b2-48c3-afac-04d7944cc4e6`，
  B4=`c6979b1b-b320-4b7f-8e2a-7906375d123c`；按 META+Name+UUID 二次核对后精确 destroy。
- destroy 后两个 META 的 status 均返回非零；无本 RUN 挂载或进程；`/mnt/juicefs` 正常，Ceph
  `HEALTH_OK`。
- 权威证据根：`/mnt/c/SunRise/test/04-tmp3c/20260904-165911/`；322 项 manifest 全部校验通过，
  manifest SHA256=`01f4bc30c6ce7d56cead77ff8d97dabede4f49d471687a52fce071ed06ddc93e`。
- 正式 raw：`raw/cells/C01--C06/`；每格 `fio.json`、`bwlog/`、`juicefs-metrics.tsv`、
  `client-sidecar.tsv`、`analysis.json` 和健康门均保留。
- 无效前置 RUN：`/mnt/c/SunRise/test/04-tmp3c/20260904-165124/invalid-run/`，仅作解析事故审计。

## 七、下一步

04-tmp3c 到此关闭，不增加 RA64、B16 或写测试。下一步执行 04-tmp3d，绕过 FUSE/TiKV，以
256 KiB/4 MiB 对象和 QD 曲线确认 Ceph/librados 后端屋顶：

1. 若对象层能达到竞品目标且显著高于 JuiceFS 的约 `2.9 GiB/s`，再触发 04-tmp3e 定位
   FUSE/Reader 请求生成上限；
2. 若对象层在所需 QD 已到平台且仍低于目标，则瓶颈落在 librados/Ceph/OSD 路径，取消 04-tmp3e；
3. B4/RA32 只有在后端余量成立并完成随机 I/O、写路径和七项回归后，才可能成为生产配置；当前
   256 KiB 七项交付基线不变。
