# JuiceFS 测试结果总表（持续更新）

> 口径：冷态基线（cache=0 / 无 writeback）+ 双口径测试，256K block，单客户端。
> 每完成一项测试追加一行；详细分析见同目录 `NN-*.md`。

## 双口径验收线

| 口径 | 分母（网卡线速） | 50% 线 | 数据面 |
|------|:---:|:---:|------|
| A 不限速（100GbE TCP） | 12500 MiB/s | 6250 | enp139s0f0np0 + enp139s0f1np1 |
| B 千兆限速（eno12409 TBF 1Gbps） | ~118 MiB/s | 59 | eno12409 + tc tbf |

## 一、不限速口径（100GbE TCP，冷态 cache=0）

| 日期 | 配置 | seqread | seqwrite | mseqread | mseqwrite | randread | randwrite | randrw R | randrw W | 备注 |
|------|------|---------|----------|----------|-----------|----------|-----------|----------|----------|------|
| _待测_ | 3 TiKV + 6 OSD EC 4+2 + cache=0 | — | — | — | — | — | — | — | — | 部署后填入 |

## 二、千兆限速口径（eno12409 TBF 1Gbps，冷态 cache=0）

| 日期 | 配置 | seqread | seqwrite | mseqread | mseqwrite | randread | randwrite | randrw R | randrw W | 备注 |
|------|------|---------|----------|----------|-----------|----------|-----------|----------|----------|------|
| _待测_ | 同上 + Ceph 切 10GbE + TBF 1Gbps | — | — | — | — | — | — | — | — | 限速测试后填入 |

> 多流项 >100% 属正常：3 节点各走 1gbit，聚合上限 ≈ 3×118=354 MiB/s。

## 三、之前 1Gbps 环境对照（冷态，MiB/s）

> 来源：`doc/perf-analysis/results-table.md`。千兆单网环境，验收线 59。

| seqread | seqwrite | mseqread | mseqwrite | randread | randwrite | randrw R/W | 验收(59) |
|---------|----------|----------|-----------|----------|-----------|-----------|:---:|
| 77.7✅ | 50.8 | 110✅ | 41.5 | 33.6 | 29.0 | 15.1/14.7 | 2/7 达标 |
