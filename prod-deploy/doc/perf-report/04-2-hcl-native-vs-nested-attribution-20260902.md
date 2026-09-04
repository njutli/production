# 04-2 H/C/L 原生 ext4 与 nested-loop 归因报告

```text
RUN_ID=20260902-160000
VERDICT=A1_CL_RESOLUTION_INSUFFICIENT
H_ANCHOR_STATUS=HISTORICAL_ANCHOR_RESOLUTION_INSUFFICIENT
EVIDENCE_STATUS=EVIDENCE_VALID
PRODUCTION_RESTORE=SIGNED
ARCHIVE_SHA256=24ee6606b0390fa1837109b18e3e10b452f52019d5fb7f60cb64b786443d6fd2
```

## 一、结论

本次在同一维护窗口内完成 `H0 → C/L 八臂 → H1`，八个 C/L arm 均通过身份、
seed/clone/GC、fio、sampler、容量和环境恢复硬门。

- fresh 原生 ext4（C）调整均值为 `4121.22 MiB/s`，fresh nested-loop/ext4（L）为
  `3933.97 MiB/s`；冻结 OLS 模型得到 L 相对 C `-4.54%`，双侧 95% CI
  `[-12.45%, +3.37%]`。
- 同臂噪声底 `epsilon=8.45%`，工程分辨阈值 `M=16.90%`；效应 CI 半宽
  `7.91 pp > 5 pp`。因此当前矩阵无法分辨 nested-loop 是否存在稳定性能损失，正式判定为
  `A1_CL_RESOLUTION_INSUFFICIENT`，不能写成“nested-loop 等价”或“确认损失 4.54%”。
- H0/H1 为 `4072.58/1417.99 MiB/s`，端点漂移 `D_H=96.70%`，超过 10% 红线。
  历史环境与 fresh C 的组合差不可归因，也不能用本 RUN 固化此前观察到的 fresh 收益。
- 本任务没有得到可直接交付生产的新配置。它得到的有效结论是：在当前噪声下，
  `同一 NVMe 原生 ext4` 与 `同盘 backing + loop/ext4` 的差异小于可可靠分辨范围；若业务必须
  对这个差异作决策，需要先降低轮间状态漂移，而不是继续增加同类 arm。

## 二、实验变量与执行合同

| 臂 | TiKV 状态 | 数据路径 | 与另一 fresh 臂的区别 |
|---|---|---|---|
| H0/H1 | 原生产 TiKV | `/dev/nvme1n1` 上原生 ext4 | 维护窗口前后历史锚点 |
| C | 每 arm fresh PD/TiKV | `/mnt/jfs-tikv` 原生 ext4 临时目录 | 无额外块层 |
| L | 每 arm fresh PD/TiKV | 同一 `/mnt/jfs-tikv` 上 128 GiB backing + loop/ext4 | 仅增加 nested-loop/ext4 |

正式顺序冻结为 `C L L C | L C C L`。所有 fresh arm 使用同一 immutable seed，
在 clone 上执行 `randwrite, bs=256 KiB, 256 jobs, iodepth=64, runtime=180s`；正式统计窗固定
为实际 I/O 起点后的 `[15,175)`。每 arm 后执行 GC、seed-return 和本地 TiKV 状态清空，R08
后销毁 seed。H0/H1 覆写生产测试目录中既有 256 个 1 GiB 测试文件，不创建或删除文件。

## 三、正式结果

| arm | 臂 | mean MiB/s | CV | W4/W1 | 6250达成率 | 硬门 |
|---|:---:|---:|---:|---:|---:|:---:|
| R01 | C | 4113.93 | 18.53% | 0.780 | 65.82% | PASS |
| R02 | L | 3906.50 | 14.16% | 1.063 | 62.50% | PASS |
| R03 | L | 4112.24 | 18.60% | 0.791 | 65.80% | PASS |
| R04 | C | 4156.51 | 16.59% | 0.781 | 66.50% | PASS |
| R05 | L | 3863.16 | 13.96% | 0.968 | 61.81% | PASS |
| R06 | C | 3865.31 | 10.00% | 0.902 | 61.84% | PASS |
| R07 | C | 4206.43 | 17.19% | 0.736 | 67.30% | PASS |
| R08 | L | 3711.28 | 14.72% | 1.069 | 59.38% | PASS |

描述性汇总：C/L 原始均值为 `4085.54/3898.30 MiB/s`；CV 均值为
`15.57%/15.36%`，W4/W1 均值为 `0.800/0.973`。L 的尾段比值并未一致变差，说明不能把
均值差直接解释为额外块层稳定损失。

### 3.1 冻结 OLS 主效应

```text
BW_i = beta0 + betaL * I(L_i) + beta1 * x_i + beta2 * x_i^2 + error_i
x_i = round_i - 4.5

adjusted_mean_C = 4121.2188 MiB/s
adjusted_mean_L = 3933.9724 MiB/s
betaL          = -187.2465 MiB/s
betaL_95CI     = [-513.2486, +138.7557] MiB/s
effect_CL      = -4.5435%
effect_95CI    = [-12.4538%, +3.3669%]
CI_halfwidth   = 7.9103 pp
```

同臂噪声：

```text
R02/R03 spread = 5.1315%
R06/R07 spread = 8.4522%
epsilon        = 8.4522%
M=max(5%,2epsilon)=16.9045%
```

`epsilon >= 5%` 且 CI 半宽大于 5 pp，命中任务书最高优先级的分辨力不足规则。

### 3.2 H 锚点

| 锚点 | mean MiB/s | CV | W4/W1 |
|---|---:|---:|---:|
| H0 | 4072.58 | 25.74% | 0.524 |
| H1 | 1417.99 | 72.70% | 0.440 |

`H_center=2745.29 MiB/s`，`D_H=96.70%`。按预注册合同，H↔C 只能记为
`HISTORICAL_ANCHOR_RESOLUTION_INSUFFICIENT`；禁止签 fresh 收益点估计。H1 的下降是有效性能端点，
不是可删除异常值，但本任务没有把生产 TiKV/RocksDB 历史状态、生产数据规模和时间漂移拆成
独立变量，故不对下降来源作单因素解释。

## 四、执行事件与有效性

以下问题均发生在对应正式 fio 之前，失败尝试未产生正式样本：

1. 首次正式启动前，Ceph `noscrub/nodeep-scrub` 会形成仅含 `OSDMAP_FLAGS` 的
   `HEALTH_WARN`；运行时健康门修订为只接受任务自有租约造成的这一唯一 WARN，之后冻结脚本。
2. R02 的部分激活与部分 render 触发重入保护；未重做已成功步骤，只补齐缺失节点并归档旧
   render 目录。
3. L 臂在 151 上复用 loop 号后，`findmnt` 一度返回旧 UUID。实际 mount UUID 与
   `blkid` 一致，且临时集群尚未启动；保存 state 前后证据后只修正状态文件中的陈旧 UUID。
   R02/R03/R05/R08 均保留审计记录，未改文件系统内容或正式测试参数。

R01 开始后 25 个冻结脚本内容未改变；八臂顺序、统计窗、模型和判据均未改变。上述恢复未
触及性能样本，因此不构成任务书 §3.4 的非性能证据失效项。正式证据仍判定 `EVIDENCE_VALID`。

## 五、环境与证据闭环

- R01--R08 与 G01--G08 全部完成；G08 seed UUID
  `51d6163c-1277-4df9-9184-4e133384dc2c` 已最终销毁，pool 回到 pre-format 对象数
  `4735172`。
- 两个 C/L block 与 H0/H1 共四个 scrub lease 均已恢复；最终 Ceph `HEALTH_OK`、
  97 PG active+clean。
- 三节点临时 PD/TiKV、mount、loop、128 GiB backing 和临时目录均清除。
- 生产 TiKV 按 150→151→152 串行恢复，三 store 连续 3 次 Up；生产 PD 全程未停止；
  `/mnt/juicefs` 已按原参数重挂并通过 30 分钟、31 点恢复观察。
- `PRODUCTION_RESTORE_SIGNED.tsv` SHA256：
  `81fb8305a8824c802a4d37482ab2d59c04c81761a2b466737e7c7fde1671337f`。
- 持久原始归档：
  `/mnt/c/SunRise/test/04-2/20260902-160000/archive/opencode-04-2-20260902-160000.tar.gz`；
  SHA256：`24ee6606b0390fa1837109b18e3e10b452f52019d5fb7f60cb64b786443d6fd2`。

## 六、工程处置

1. 不把 nested-loop 当成已确认瓶颈，也不把它当成已证明无损；本轮不产生生产配置变更。
2. H 端点漂移说明生产历史状态在长维护窗口内仍可能发生大幅变化。若未来继续拆 fresh 来源，
   应优先设计短窗口、可回退的生产历史状态观测，而不是再扩大 C/L 矩阵。
3. 04-2 不阻塞 04-6 收尾；缓存专项 04-tmp2b改变存储语义，必须独立报告，不能用来补本任务
   的 C/L 分辨力。
