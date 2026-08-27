# 03-21 测试报告：TiKV 存储隔离与扩展可行性只读盘点

## 日期：2026-08-24

---

## 1. 测试概述

回答一个问题：三个 TiKV 主机当前是否存在能够与 `/dev/nvme1n1` 物理隔离的健康 spare NVMe；若没有，本地介质隔离是否必须升级为新增/替换硬件或扩展 TiKV 节点。

方法：纯只读盘点，0 个 fio arm、0 个性能探针、0 次状态变更。SSH 到三 TiKV 节点执行只读系统查询（lsblk/findmnt/df/blkid/nvme-cli/lspci/TiKV config+metrics），从 PD HTTP API 采集 stores/config/hotspot。所有文件只写到 157 本地。

**结果：`COLLECTION_COMPLETE_ANALYSIS_PENDING`。数据完整采集，等待 GPT 离线分析。**

## 2. 测试环境

| 项 | 值 |
|---|---|
| 采集端 | 157 |
| TiKV 节点 | 10.20.1.150 / 10.20.1.151 / 10.20.1.152 |
| 工作负载 | 0 |
| 配套脚本 | `t63-tikv-storage-topology-inventory.sh`（md5 `5f092126...`） |
| 授权 | `T63_USER_AUTH=03-21-read-only-inventory` |

## 3. 执行结果

| 指标 | 值 |
|---|---|
| RUN_ID | 20260824-070324 |
| 退出状态 | COLLECTION_COMPLETE_ANALYSIS_PENDING |
| 执行时间 | <1 分钟 |
| INVALID.txt | 不存在 |
| SHA256SUMS | 生成并自校验 |
| archive SHA-256 | `4fd270b7...` |

## 4. 采集内容清单

### 4.1 三节点（nodes/10.20.1.150/151/152）

每节点包含：

| 文件 | 说明 |
|---|---|
| `process-pre.txt` / `process-post.txt` | TiKV PID/starttime/exe md5/cmdline 前后对比 |
| `system.txt` | hostname/kernel/uptime/CPU/mem |
| `lsblk.json` | 全块设备树（JSON，含所有 loop/nvme/dm） |
| `findmnt.json` | 全挂载点（JSON） |
| `df.txt` | 文件系统使用 |
| `blkid.txt` | 块设备标识 |
| `storage-paths.txt` | KV/Raft/WAL 路径及 leaf 解析 |
| `nvme-sysfs.txt` | NVMe sysfs 属性（model/serial/firmware/PCIe/NUMA/queue） |
| `nvme-cli.txt` | `nvme list/smart-log/id-ctrl/id-ns`（JSON） |
| `lspci-vv.txt` | NVMe PCIe 详细信息 |
| `tikv-config-pre.json` / `tikv-config-post.json` | TiKV 配置前后对比 |
| `tikv-metrics.prom.gz` | 完整 TiKV metrics |

### 4.2 PD（pd/）

| 文件 | 说明 |
|---|---|
| `health.json` | PD 健康状态 |
| `stores.json` | Store 列表（id/address/state/region_count/leader_count/capacity/available） |
| `config.json` | PD 配置 |
| `hotspot-regions-write.json` | 写热点 region |
| `hotspot-stores.json` | 热点 store |

### 4.3 已知关键事实

- NVMe 设备型号：`Dell DC NVMe CD8 U.2 960GB`（KIOXIA OEM），firmware `2.0.1`
- 当前工作盘：`/dev/nvme1n1`（三节点 KV/Raft/WAL 共享）
- 三节点 NVMe PCIe 路径、NUMA、SMART 原始数据已采集
- PD stores 分布已采集
- TiKV pre/post process/config 一致性已验证

## 5. sudo 操作清单

全部为只读系统查询，零写入、零状态变更：

| 操作 | 性质 | 位置 |
|---|---|---|
| `sudo nvme list/smart-log/id-ctrl/id-ns` | 只读 NVMe 查询 | 三 TiKV 节点 |
| `sudo blkid` | 只读块设备标识 | 三 TiKV 节点 |
| `sudo lspci -Dvv` | 只读 PCI 设备列表 | 三 TiKV 节点 |
| `sudo cat /proc/$pid/cmdline` 等 | 只读 TiKV 进程信息 | 三 TiKV 节点 |

无 mount/umount、无 mkfs/wipefs、无 config 修改、无 restart/kill、无 drop_caches/compact/GC。

## 6. 证据位置

| 文件 | 位置 |
|---|---|
| Archive | `/home/lilingfeng/tmp/production/opencode-t3.21-20260824-070324.tar.gz`（SHA-256 `4fd270b7...`，433KB） |
| 157 产物 | `/tmp/production/opencode-t3.21-20260824-070324.tar.gz` + `.sha256` |
| 配套脚本 | `scripts/FULLBASELINE/debug/t63-tikv-storage-topology-inventory.sh` |
| 离线复算脚本 | `scripts/FULLBASELINE/debug/t62-r2-offline-attribution.py` |
| 任务书 | `doc/perf-tasks/03-21-tikv-storage-isolation-feasibility-inventory.md` |

## 7. GPT 独立复核与正式分支判定（2026-08-24）

### 7.1 结论先行

03-21 采集有效，正式分支为 **`NO_LOCAL_SPARE`**。

三台 TiKV 主机各有 4 块物理 NVMe，但没有任何一块同时满足“物理独立、未被其他系统占用、健康、容量足够”四项条件：`nvme0n1` 是系统盘，`nvme1n1` 是当前 TiKV 盘，`nvme2n1` 和 `nvme3n1` 均为正在使用的 Ceph BlueStore OSD。后两块盘虽然没有普通文件系统挂载点，却不是 spare device。

因此，当前硬件拓扑不具备在三节点上对称实施 TiKV WAL/Raft/KV 物理介质隔离的条件。03-21 不需要补跑；下一步也不应再次运行 B256 或继续调局部参数，而应先在“新增三节点对称专用介质”和“按当前拓扑完成架构闭环”之间做工程决策。

### 7.2 证据包有效性与采集稳定性

独立复核使用：

```text
/home/lilingfeng/tmp/production/opencode-t3.21-20260824-070324.tar.gz
sha256 = 4fd270b72b35e36bdbfb34ab9645b3b6efca92ae1404b2f5acc430a2b27101f7
```

外层 SHA-256 与 `.sha256` 一致；解包后 `SHA256SUMS` 为 **100/100 PASS**。`INVALID.txt` 不存在，`result.txt` 为 `COLLECTION_COMPLETE_ANALYSIS_PENDING`。三节点所有必需采集文件存在，stderr 均为空；157 本地及三节点 `foreign-fio.txt` 均为空。

三节点 TiKV 的 PID/starttime/exe/cmdline pre/post 完全一致，配置 pre/post 完全一致。采集期间没有 TiKV 重启、配置漂移或 fio 干扰。因此 S00--S04 均通过，现有证据足以作正式分支判断，不应降级为 `INVENTORY_INCOMPLETE`。

### 7.3 三节点设备归属

| 节点 | 系统盘 | TiKV 盘 | Ceph OSD 盘 | 合格 spare |
|---|---|---|---|---|
| 10.20.1.150 | `nvme0n1` / `15B0A0J4TSTJ` | `nvme1n1` / `15B0A0J1TSTJ` | `nvme2n1` / `24504D89B71A` / OSD 1；`nvme3n1` / `24504D89B6F6` / OSD 2 | 0 |
| 10.20.1.151 | `nvme0n1` / `15B0A0J3TSTJ` | `nvme1n1` / `15B0A0JNTSTJ` | `nvme2n1` / `24504D89B5CA` / OSD 3；`nvme3n1` / `24504D89B53E` / OSD 4 | 0 |
| 10.20.1.152 | `nvme0n1` / `15B0A1WCTSTJ` | `nvme1n1` / `15B0A1KHTSTJ` | `nvme2n1` / `24504D89B5CB` / OSD 5；`nvme3n1` / `24504D89B5A6` / OSD 6 | 0 |

逐类判断如下：

- `nvme0n1`（Dell CD8 960GB）包含 EFI 与根文件系统，属于操作系统，不能作为 TiKV 隔离盘。
- `nvme1n1`（Dell CD8 960GB）以 ext4 挂载到 `/mnt/jfs-tikv`。三节点的 `storage.data-dir`、`rocksdb.wal-dir` 和 `raft-engine.dir` 全部解析到该盘，正是需要解除内部争用的当前工作盘，不能作为独立候选。
- `nvme2n1`、`nvme3n1`（Dell 7500 7.68TB）均为 `LVM2_member`，其下存在活动的 `ceph_bluestore` OSD 逻辑卷。`lsblk` 的“未挂载”只表示 BlueStore 不走普通文件系统挂载，不表示设备空闲。
- 四块 NVMe 在每台机器上分别落到独立的 PCIe controller path（末端分别为 `c9:00.0`、`ca:00.0`、`cb:00.0`、`cc:00.0`），物理独立性本身成立；候选失败的原因是全部已有明确所有者，而不是控制器路径不明。

12 块 NVMe 的 SMART 快照均为 `critical_warning=0`、`avail_spare=100`、`media_errors=0`、`num_err_log_entries=0`，`percent_used=0%--3%`。这说明现有盘没有快照可见的健康淘汰信号，但**健康不等于空闲**，不能覆盖设备所有权门。

### 7.4 TiKV 容量与分布不是当前可利用的解法

三块 TiKV 文件系统容量均为 879.1 GiB，文件系统已用约 42.43--42.47 GiB、可用约 791.94--791.99 GiB；PD 报告的 store used size 为 15.42/17.53/17.54 GiB。现状不是空间容量不足，而是 R2 已识别出的同步前台 I/O 与后台 compaction 共用同一物理介质时的延迟和队列余量不足。

PD 快照中三个 store 均为 `Up`、`slow_score=1`，三个 PD member 均健康；各 store 的 `region_count` 都是 2485，leader 数为 832/822/831，最大差 10，仅约为均值的 1.21%。因此没有明显的现存 region/leader 倾斜可以通过一次 rebalance 消除。空载采集时 hotspot rate 为 0，只能说明盘点时没有业务负载，不能用于否定 R2 在 B256 负载下观察到的共享盘瓶颈。

### 7.5 为什么不能直接借用两块 Ceph 盘

把 `nvme2n1` 或 `nvme3n1` 划给 TiKV 不属于“使用 spare”，而是回收在用 Ceph OSD，至少会引入 OSD out/rebalance、数据迁移、容量与故障域变化。它同时改变 JuiceFS 对象数据面和 TiKV 元数据面，破坏本阶段要求的单变量与稳定 reset，无法确认收益究竟来自 TiKV 隔离还是 Ceph 拓扑变化。

在现有 OSD 上划分分区或逻辑卷给 TiKV 也不构成物理隔离：TiKV 和 Ceph 仍共享同一设备的队列、介质和尾延迟。系统盘同理会把元数据延迟与 OS/container I/O 及系统故障域绑定。因此三类已用设备都不能作为稳定性可解释的生产方案。

### 7.6 与 03-20B-R2 结论的关系

03-21 没有重新证明性能瓶颈，而是回答 R2 留下的“现有硬件能否落地介质隔离”问题。两轮证据组合后的结论为：

1. R2 的成功 arm 虽因协议和时间轴问题正式为 `EVIDENCE_INVALID`，但校正数据仍显示正式窗 2880.44 MiB/s，仅为 6250 MiB/s 目标的 46.09%，且 `W4/W1=0.368`、CV=44.50%；三节点真实 W1 起就已有 94.27%--99.47% device util 和深队列。
2. KV SST、RocksDB WAL 和 Raft Engine 当前在三节点都共用各自唯一的 `nvme1n1`；前台同步提交延迟与后台 compaction I/O 相互争用的机制证据已经足够强。
3. 03-21 进一步证明三节点没有未占用的第二介质可做对称隔离。也就是说，这条瓶颈在当前部署中不能通过“换一个现成目录”或再调 worker/uploader/inode 参数解决。

所以，应停止在当前拓扑上重复 B256 和进行同类局部调参。继续增加客户端压力只会放大队列、compaction 债和运行间波动，不能验证一项新的可行调优手段。

### 7.7 下一步及其原因

下一步是架构/资源决策，不是新的性能 arm：

**路径 A：允许新增硬件。** 优先在三台现有 TiKV 主机上各增加一块型号、固件、容量和耐久等级一致，具备断电保护且 PCIe 路径独立的低尾延迟 NVMe。随后单独编写迁移设计，评估把 `rocksdb.wal-dir` 与 `raft-engine.dir` 迁到专用介质、KV SST 保留在当前 `nvme1n1` 的方案；迁移必须三节点对称、逐节点滚动、带容量/耐久规划、数据校验和明确回滚。新增单块盘或只改一两个节点不能形成生产闭环。若现有主机没有可用槽位，则备选是建设资源规格一致的专用 TiKV 节点组并迁移/重分布，而不是只增加一个异构节点。

该设计只代表“具备验证条件”，不保证达到 6250 MiB/s。完成介质变更并恢复稳定基线后，才应新立任务复测 B256：修正 fio 实际 timed-I/O 起点、保证全窗口覆盖、沿用稳定 reset，并同时观察新旧两类介质的 util/await/queue、TiKV WAL/Raft/transaction 延迟和正式 BW/CV。

**路径 B：不能新增或替换硬件。** 直接形成 03 阶段架构闭环：当前三副本 TiKV 在每节点只有一块专用盘，前台同步提交和后台 LSM compaction 无法物理隔离；现有参数调优未达到目标且已触及共享介质延迟墙。此时应把“当前硬件拓扑下无法通过已验证的参数手段稳定达到 6250 MiB/s”写入阶段结论，并列出达到目标所需的专用介质/节点资源，不再消耗环境运行重复 arm。

无论选择哪条路径，都不得把现有 Ceph OSD 或系统盘当作 spare，也不得在未单独授权的任务中执行 OSD 下线、分区、格式化、挂载、TiKV 配置修改、数据迁移或服务重启。
