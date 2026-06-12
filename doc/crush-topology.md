# Ceph CRUSH 拓扑概念说明

## 核心概念

| 概念 | 是什么 | 类比 |
|------|--------|------|
| **OSD** | 存数据的进程/守护线程，一个管一块盘 | 仓库里一个货架 |
| **Pool** | 数据存储的逻辑分区，定义冗余方式和分布规则 | 逻辑卷/目录 |
| **Bucket** | CRUSH 拓扑层级中的容器，表达物理拓扑关系 | 文件系统中的目录 |
| **Root** | 顶层 bucket，CRUSH 查找起点 | 根目录 `/` |
| **Host** | 主机级 bucket，位于 root 之下 | 子目录 |
| **CRUSH Rule** | 数据分布策略：从哪个 root 开始、按什么粒度选 OSD | 挂载点或路径规则 |

## 本集群的 CRUSH 拓扑

```
default root (现有 SSD 集群)
├─ ceph-node1 (host bucket) ← 物理主机
│    ├─ osd.0 ← /dev/sdb SSD, 通过 PERC H730 RAID 卡
│    └─ osd.1 ← /dev/sdb SSD, 同上
├─ ceph-node2 (host bucket)
│    ├─ osd.2 ← /dev/sdb SSD
│    └─ osd.3 ← /dev/sdb SSD
└─ ceph-node3 (host bucket)
     ├─ osd.4 ← /dev/sdb SSD
     └─ osd.5 ← /dev/sdb SSD

ramdisk-root (测试用，内存盘集群，待建)
├─ ceph-node1-ram (host bucket)
│    ├─ osd.6 ← /dev/ram0, 纯内存
│    └─ osd.7 ← /dev/ram1, 纯内存
├─ ceph-node2-ram (host bucket)
│    ├─ osd.8 ← /dev/ram0, 纯内存
│    └─ osd.9 ← /dev/ram1, 纯内存
└─ ceph-node3-ram (host bucket)
     ├─ osd.10 ← /dev/ram0, 纯内存
     └─ osd.11 ← /dev/ram1, 纯内存
```

## Pool 与 CRUSH Rule 的关系

```
default.rgw.buckets.data 池
  └─ CRUSH Rule: 从 "default root" 找 OSD
       └─ 数据只会落在 osd.0~5（SSD）

test-ram-ec 池 (待建)
  └─ CRUSH Rule: 从 "ramdisk-root" 找 OSD
       └─ 数据只会落在 osd.6~11（内存盘）
```

两个池的 OSD 集合**完全不相交**，互不干扰。

## EC 数据分布示例

EC 4+2 写一个对象时：数据拆成 4 个分片 + 2 个校验分片 = 6 个分片，
CRUSH 从对应 root 下选 6 个 OSD（每 host 最多选 2 个，failure-domain=host）。

```
对象 X (4MB) → 分片0→osd.0 (SSD)
             → 分片1→osd.2 (SSD)
             → 分片2→osd.4 (SSD)
             → 分片3→osd.1 (SSD)
             → 校验0→osd.3 (SSD)
             → 校验1→osd.5 (SSD)

对象 Y (4MB) → 分片0→osd.6 (RAM)    ← 走 ramdisk-root
             → 分片1→osd.8 (RAM)
             → 分片2→osd.10(RAM)
             → 分片3→osd.7 (RAM)
             → 校验0→osd.9 (RAM)
             → 校验1→osd.11(RAM)
```

