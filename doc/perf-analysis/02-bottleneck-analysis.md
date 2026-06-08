# 瓶颈分析与优化方向（基于 2026-06-08 实测）

> 本文是对 `doc/performance-tuning.md`（deepseek 给出的初版调优指南）的纠偏。
> 原指南的瓶颈分析方向是错的，实测数据（见 `01-measured-data.md`）证明了这一点。

---

## 一、决定性发现

### 发现 1：真正的瓶颈是网络，不是 TiKV / PD / RocksDB

`rados bench` 直接压 Ceph EC 后端（完全绕过 JuiceFS、TiKV、PD、FUSE）：

- 写 **9.87 MB/s**，读 11.65 MB/s，平均延迟 **15~18 秒**。

既然绕过了 JuiceFS 元数据层后端依然只有 ~10 MB/s，说明：

> 瓶颈百分之百在 Ceph 数据路径，与 TiKV/PD/RocksDB/FUSE 完全无关。

原指南把"PD 时间戳延迟 30-200ms"、"TiKV block-cache 仅 128MB"当主因，
方向完全错误——这也解释了为什么 tier1(sysctl)/tier2(tikv)/tier3(ceph) 三轮调优都没效果。

### 发现 2：根因是 ceph-node1/node2 网卡只有 100Mb/s

- node1、node2：100Mb/s ≈ **12.5 MB/s**
- node3、tikv：1000Mb/s
- RGW 部署在 node1（100Mb/s）上，所有 S3 流量挤这一个口。
- rados bench 带宽抖动到 0、延迟十几秒 = 网络拥塞/丢包特征。

裸盘随机写能到 420 MiB/s，证明**盘不慢，是网络把后端拖死了**。

### 发现 3：之前"JuiceFS 客户端调优有效"是假象

tier4 加了 `--writeback --cache-size`，官方单线程顺序基准跳到
READ 1367 MiB/s / WRITE 372 MiB/s。但这是在测**本地缓存盘**：

- `--writeback`：写只落本地 `/var/jfsCache` 就返回，没等 S3 确认。
- 单文件顺序读第二遍命中本地缓存。

用户的真实负载（`--direct=1` 随机 128 并发）下缓存基本失效，
所以只看到 38.8 MiB/s，且一旦缓存写满会跌回 ~10 MB/s 的后端真值。

> 结论：客户端调优"有效"只是把数据藏进本地缓存，没真正打到后端。

---

## 二、理论上限计算

### 当前硬件（网卡不变）

- node1/node2 网口 100Mb/s = **12.5 MB/s** 线速，是绝对天花板。
- EC 4+2 写入需把分片传到分布于各节点的 6 个 OSD，
  最慢链路（100Mb/s）决定整体。
- 即使把 RGW 挪到 1000Mb/s 的 node3，分片仍要写到 node1/node2 的
  100Mb/s 网口 → 依旧被拖死。

> **当前网卡下的实际上限 ≈ 10~12 MB/s。rados bench 的 9.87 MB/s 已接近上限。
> 不动网卡，任何软件调优都无意义。**

### 网卡升级到千兆后（三台都 1000Mb/s）

- 单链路千兆 ≈ 118 MB/s。
- EC 4+2 写放大系数 (k+m)/k = 6/4 = 1.5，且 HDD 随机写有读改写放大。
- 估算后端 EC 写 **~60~90 MB/s**（顺序好、随机偏低）。
- HDD + EC 随机小写仍是限制项，要更高需改副本池或上 SSD。

### 若再改 3 副本池（replicated，size=3）

- 副本写放大 = 3，但避免 EC 编码/读改写，HDD 上随机写更友好。
- 前提：**必须先有千兆网络**，否则副本反而放大网络流量、更慢。

---

## 三、优化方向（按收益排序）

### 第一优先级：修复网络（唯一真正重要的事）

1. 排查 node1/node2 为何只协商到 100Mb/s（多为**网线劣质/老旧**或
   **交换机端口限速**；千兆网卡跑 100Mb/s 基本是物理层问题）：
   ```bash
   sudo ethtool eth0 | grep -A20 "Supported link modes"
   sudo ethtool -s eth0 speed 1000 duplex full autoneg on
   ```
2. 换六类及以上网线 + 千兆交换机端口，把三台拉到 1000Mb/s。
3. 预期：后端从 ~10 MB/s 提升到 ~60~90 MB/s。

### 第二优先级：多 RGW + 负载均衡（网络修好后）

- 当前仅 node1 一个 RGW。在 3 节点各部署一个 RGW，前置 HAProxy，
  JuiceFS 指向 LB，分摊 128 并发流量。
- 原指南把这条放在"第六级"，应提前到网络之后第一位。

### 第三优先级：EC → 3 副本（HDD 随机写优化）

- HDD 上 EC 4+2 随机小写读改写放大严重。
- 测试阶段对比 replicated size=3 池，随机写通常明显更好。
- **务必在千兆网络就绪后再试**，否则副本流量放大会更慢。

### 可选：JuiceFS 客户端真正有用的参数

- `--max-uploads`（提高并发上传 S3）、`--buffer-size`。
- 顺序读大文件场景可用 `--prefetch`、`--cache-size`。
- 验收测试如要反映真实后端能力，**去掉 `--writeback`**。

### 明确不要再做的事（原指南的无效项）

- ❌ TiKV block-cache / RocksDB 调优（元数据量极小，已被 rados bench 证伪）
- ❌ swap / THP / sysctl 系统调优（碰不到 100Mb/s 网络瓶颈）
- ❌ 依赖 `--writeback` 制造的客户端缓存"提速"

---

## 四、正确的瓶颈分析方法论（纠正原指南）

原指南的延迟分解把 PD get_timestamp（30-200ms）列为主因，且诊断命令
全压在 TiKV/RocksDB 指标上——方向错误。正确方法是**自底向上逐层隔离**：

1. **裸盘基准**：`fio --direct=1` 在 OSD 同类盘上跑，确认介质能力。
2. **网络基准**：`ethtool` 看协商速率 + `iperf3` 实测节点间带宽。
3. **后端基准**：`rados bench` 直压数据池，绕过 JuiceFS/TiKV。
4. **端到端**：JuiceFS fio（去掉 writeback），与第 3 步对比看 JuiceFS 开销。

只有当某一层基准明显低于硬件能力时，才针对那一层调优。
**先量化上限，再定目标，最后调优**——而不是盲目套用通用调优清单。

参考排查脚本：`doc/perf-analysis/diag.sh`
