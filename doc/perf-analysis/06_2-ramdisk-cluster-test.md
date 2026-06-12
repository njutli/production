# 方向 B2：全内存盘集群排除 RAID 卡/SSD 影响

> 目标：用内存盘（brd）完全替代物理磁盘，在纯 RAM 上跑 Ceph EC 4+2，
> 排除 RAID 控制器和 SSD 本身是否为瓶颈。
>
> **状态：✅ 环境已建好，待测试。**

---

## 可行性分析

### 内存容量

| 节点 | 可用内存 | 每节点需分配 | 余量 |
|------|---------|------------|------|
| ceph-node1 | 246 GiB | 50 GiB | 充足 |
| ceph-node2 | 215 GiB | 50 GiB | 充足 |
| ceph-node3 | 245 GiB | 50 GiB | 充足 |

100 GiB 可用数据 × EC 4+2（效率 4/6）→ 150 GiB 裸容量 → 6 OSD × **25 GiB** → 每节点 2 OSD = **50 GiB**。

### 技术路线

使用内核 **brd** 模块创建真正的 RAM 块设备（非 tmpfs 文件），天然支持 O_DIRECT，
无需 loop 设备中转。

```
brd 模块 → /dev/ram0~ram1（每节点 2 个 × 3 节点 = 6 个）
         → ceph orch daemon add osd → 6 个新 OSD
         → device class "ram" 隔离 → 新 EC 池 → rados bench
```

### 与现有 OSD 隔离

通过 **device class** 隔离。新 OSD 创建后 cephadm 自动标记为 `ssd`，
需先 `rm-device-class` 再设为 `ram`。

```
default root
├─ ceph-node1
│    ├─ osd.0 (hdd)  ← 实为 SSD，PERC H730
│    ├─ osd.1 (hdd)  ← 同上
│    ├─ osd.6 (ram)  ← /dev/ram0, 25 GiB 内存盘
│    └─ osd.7 (ram)  ← /dev/ram1, 25 GiB 内存盘
├─ ceph-node2
│    ├─ osd.2 (hdd)
│    ├─ osd.3 (hdd)
│    ├─ osd.8 (ram)
│    └─ osd.9 (ram)
└─ ceph-node3
     ├─ osd.4 (hdd)
     ├─ osd.5 (hdd)
     ├─ osd.10(ram)
     └─ osd.11(ram)
```

CRUSH rule 限定 `take default class ram → choose_indep type osd`，
**完全不触及 SSD OSD**。

### 预期对比 → 实测结论

| 指标 | SSD (PERC H730) | 纯内存盘 (brd) | 结论 |
|------|----------------|---------------|------|
| Ceph EC 写带宽 | 106 MB/s | **106.6 MB/s**（实测） | **无提升，RAID 卡非瓶颈** |
| Ceph EC 写带宽 | 106 MB/s | ≈106 | 瓶颈在 Ceph/EC 协议/网络/软件栈 |

---

## 已验证操作步骤

### ⚠️ 关键踩坑

1. **brd 盘被 cephadm 标记为 `ssd`，直接 `set-device-class ram` 会报 `EBUSY`，
   必须先 `rm-device-class` 再设置**
2. **`crush-failure-domain=host` 不适用**：EC 4+2 需要 6 个 failure domain，
   但只有 3 台主机有 ram 设备 → 分片放不下。**必须用 `crush-failure-domain=osd`**
3. **`ceph osd erasure-code-profile set` 中的 `crush-failure-domain=osd` 不会自动
   生成正确的 CRUSH rule**，须用 `ceph osd crush rule create-erasure` 显式创建
4. **创建 OSD 时 cephadm 容器可能残留**，失败后需 `podman rm -f` 强杀再重试
5. **pg_num 从 128→64 降低**，减少 PG 创建开销（测试池无需 128 PG）

### 一、每节点创建 brd 设备

```bash
# 在 ceph-node1, ceph-node2, ceph-node3 上各执行：
# 25 GiB = 26214400 KB

sudo modprobe -r brd
sudo modprobe brd rd_nr=2 rd_size=26214400

# 验证
lsblk /dev/ram0 /dev/ram1
# 预期：25G 块设备
```

### 二、创建 6 个基于内存盘的 OSD

```bash
# 从 ceph-node1（admin 节点）执行
sudo cephadm shell -- ceph orch daemon add osd ceph-node1:/dev/ram0
sudo cephadm shell -- ceph orch daemon add osd ceph-node1:/dev/ram1
sudo cephadm shell -- ceph orch daemon add osd ceph-node2:/dev/ram0
sudo cephadm shell -- ceph orch daemon add osd ceph-node2:/dev/ram1
sudo cephadm shell -- ceph orch daemon add osd ceph-node3:/dev/ram0
sudo cephadm shell -- ceph orch daemon add osd ceph-node3:/dev/ram1
```

### 三、用 device class 隔离新 OSD

```bash
# cephadm 自动标记为 ssd，必须先移除再设 ram
for id in 6 7 8 9 10 11; do
  sudo cephadm shell -- ceph osd crush rm-device-class osd.${id}
  sudo cephadm shell -- ceph osd crush set-device-class ram osd.${id}
done
```

### 四、创建 EC profile 并显式建 CRUSH rule

```bash
# 1) EC profile（同时指定 class 和 failure-domain=osd）
sudo cephadm shell -- ceph osd erasure-code-profile set ec-ram \
  k=4 m=2 crush-device-class=ram crush-failure-domain=osd

# 2) 显式创建 CRUSH rule（关键！不靠池自动生成）
sudo cephadm shell -- ceph osd crush rule create-erasure ec-ram-rule ec-ram

# 3) 验证 rule 正确性
sudo cephadm shell -- ceph osd crush rule dump ec-ram-rule
# 预期: "item_name": "default~ram", "type": "osd"
```

### 五、创建池

```bash
# 4) 创建池，显式指定 rule
sudo cephadm shell -- ceph osd pool create test-ram-ec erasure ec-ram ec-ram-rule
sudo cephadm shell -- ceph osd pool set test-ram-ec pg_num 64
sudo cephadm shell -- ceph osd pool set test-ram-ec pgp_num 64
sudo cephadm shell -- ceph osd pool application enable test-ram-ec rados
```

### 六、实测结果（2026-06-12）

```
Total time run:         60.8044
Total writes made:      1621
Write size:             4194304
Object size:            4194304
Bandwidth (MB/sec):     106.637
Stddev Bandwidth:       26.6909
Max bandwidth (MB/sec): 256
Min bandwidth (MB/sec): 0
Average IOPS:           26
Stddev IOPS:            6.67274
Max IOPS:               64
Min IOPS:               0
Average Latency(s):     2.35461
Stddev Latency(s):      0.918166
Max latency(s):         5.99939
Min latency(s):         0.0899462
```

| 指标 | SSD (PERC H730) | 纯内存盘 (brd) | 变化 |
|------|----------------|---------------|------|
| 带宽 | 106.4 MB/s | **106.6 MB/s** | +0.2% |
| 平均延迟 | 2.35s | **2.35s** | 持平 |
| IOPS | 26 | **26** | 持平 |

> **结论：RAID 卡和 SSD 都不是瓶颈。** 用比 SSD 快数量级的内存盘替换后，
> 吞吐完全不变。瓶颈在 Ceph/EC 协议/网络/软件栈。

### 七、清理

```bash
# 删除测试池
sudo cephadm shell -- ceph osd pool delete test-ram-ec test-ram-ec --yes-i-really-really-mean-it

# 删除 EC profile 和 rule
sudo cephadm shell -- ceph osd erasure-code-profile rm ec-ram
sudo cephadm shell -- ceph osd crush rule rm ec-ram-rule

# 销毁 ramdisk OSD
for id in 6 7 8 9 10 11; do
  sudo cephadm shell -- ceph orch daemon rm osd.${id} --force
  sudo cephadm shell -- ceph osd purge ${id} --yes-i-really-mean-it
done

# 每节点卸载 brd 并释放内存
sudo modprobe -r brd
```

### 八、结果对比

| 指标 | SSD (PERC H730) | 纯内存盘 (brd) | 结论 |
|------|----------------|---------------|------|
| 裸盘顺序写 | 178 MB/s | 远高于此 | 仅供参照 |
| Ceph EC rados bench | 106 MB/s | 待测 | |
| rados bench 延迟 | 2.35s | 待测 | |

> - 若纯内存盘也 ~106 MB/s → **RAID 卡和 SSD 都不是瓶颈，瓶颈在 Ceph/EC/网络/软件栈**
> - 若纯内存盘大幅提升（例如 200+ MB/s） → **RAID 卡是瓶颈**

### ⚠️ 风险提示

1. **brd 设备是纯 RAM，重启即消失**。不会损坏已有数据，但测试过程不能重启节点
2. **150 GiB RAM 占用**，三节点内存充足，不影响正常 OSD 运行
3. **pg_num=64**（降至 128 以下减少 PG 开销，测试池用 64 足够）
4. **CRUSH rule 使用了 `osd` 级 failure domain**，而非生产环境常用的 `host` 级。
   这意味着同一主机上的两个内存 OSD 可以承载同一对象的两个分片（降低故障隔离，但测试无妨）