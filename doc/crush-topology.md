# Ceph CRUSH 拓扑概念说明

## 核心概念

| 概念 | 是什么 | 类比 |
|------|--------|------|
| **OSD** | 存数据的进程，一个管一块盘 | 仓库里一个货架 |
| **Pool** | 数据存储的逻辑分区，定义冗余方式和分布规则 | 逻辑卷 |
| **Bucket** | CRUSH 拓扑层级中的容器，表达物理拓扑关系 | 文件系统中的目录 |
| **Root** | 顶层 bucket，CRUSH 查找起点 | 根目录 `/` |
| **Host** | 主机级 bucket，由 cephadm 按实际主机名管理（一台物理机只有一个） | 子目录 |
| **Device Class** | 设备的性能类别标签（hdd/ssd/nvme/自定义），存在 CRUSH 中但不在拓扑层级里 | 货架的标签/属性 |
| **CRUSH Rule** | 数据分布策略：从哪个 root 开始、按什么 class 和粒度选 OSD | 挂载路径加过滤条件 |

## 本集群的 CRUSH 拓扑

```
default root
├─ ceph-node1 (host bucket, 物理主机名)
│    ├─ osd.0 ← /dev/sdb SSD, class=hdd ✘（RAID 卡障眼法，实为 SSD）
│    ├─ osd.1 ← /dev/sdb SSD, class=hdd ✘
│    ├─ osd.6 ← /dev/ram0 内存盘, class=ram (待建)
│    └─ osd.7 ← /dev/ram1 内存盘, class=ram (待建)
├─ ceph-node2 (host bucket)
│    ├─ osd.2 ← /dev/sdb SSD, class=hdd ✘
│    ├─ osd.3 ← /dev/sdb SSD, class=hdd ✘
│    ├─ osd.8 ← /dev/ram0 内存盘, class=ram (待建)
│    └─ osd.9 ← /dev/ram1 内存盘, class=ram (待建)
└─ ceph-node3 (host bucket)
     ├─ osd.4 ← /dev/sdb SSD, class=hdd ✘
     ├─ osd.5 ← /dev/sdb SSD, class=hdd ✘
     ├─ osd.10 ← /dev/ram0 内存盘, class=ram (待建)
     └─ osd.11 ← /dev/ram1 内存盘, class=ram (待建)
```

> `osd.6~11` 和 `osd.0~5` 混在同一个 host bucket 下，通过 **device class（hdd vs ram）** 区分。
> 物理主机名就是 host bucket 名，不能也不需要在 CRUSH 中给同一台机器注册多个 host 名。

## Pool 与 CRUSH Rule 的关系

```
default.rgw.buckets.data 池
  └─ CRUSH Rule: class hdd
       └─ 数据落在 osd.0~5（SSD，被标记为 hdd class）

test-ram-ec 池 (待建)
  └─ CRUSH Rule: class ram
       └─ 数据落在 osd.6~11（内存盘）
```

两个池的 OSD 集合**完全不相交**（不同 device class），互不干扰。

## EC 数据分布示例

EC 4+2 写一个对象时：数据拆成 4 个分片 + 2 个校验分片 = 6 个分片，
CRUSH rule 限定 class + failure-domain=host 选 6 个 OSD。

```
对象 X (test-ram-ec 池)
  CRUSH: class=ram, failure-domain=host
  → 分片0→osd.6  (ceph-node1, ram)
  → 分片1→osd.8  (ceph-node2, ram)
  → 分片2→osd.10 (ceph-node3, ram)
  → 分片3→osd.7  (ceph-node1, ram)
  → 校验0→osd.9  (ceph-node2, ram)
  → 校验1→osd.11 (ceph-node3, ram)
```

## 为什么不需要 ceph-node1-ram 这样的名字

cephadm 按物理主机名自动管理 host bucket，`ceph orch daemon add osd ceph-node1:/dev/ram0`
创建 OSD 时会自动将它放在 `ceph-node1` host bucket 下。

如果手动创建一个叫 `ceph-node1-ram` 的 host bucket，cephadm 不知道这个名称对应哪台物理机，
也无法把 OSD 自动放入。所以**一台物理机在 CRUSH 中只有一个 host bucket**。

需要区分同类主机上的不同设备时，应使用 **device class**（标签属性）而非额外 host bucket。
