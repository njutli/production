# 方向 B2：全内存盘集群排除 RAID 卡/SSD 影响

> 目标：用内存盘（brd）完全替代物理磁盘，在纯 RAM 上跑 Ceph EC 4+2，
> 排除 RAID 控制器和 SSD 本身是否为瓶颈。
>
> **状态：方案分析，待执行。**

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

新 OSD 创建后会自动归属到对应主机名下（ceph-node1/2/3）。通过 **device class**
隔离，不创建独立的 host bucket：

```
default root
├─ ceph-node1
│    ├─ osd.0 (SSD)  ← class hdd（RAID 虚拟盘障眼法）
│    ├─ osd.1 (SSD)  ← class hdd
│    ├─ osd.6 (RAM)  ← class ram ← 新创建后用 crush set-device-class 改
│    └─ osd.7 (RAM)  ← class ram
├─ ceph-node2
│    ├─ osd.2 (SSD)  ← class hdd
│    ├─ osd.3 (SSD)  ← class hdd
│    ├─ osd.8 (RAM)  ← class ram
│    └─ osd.9 (RAM)  ← class ram
└─ ceph-node3
     ├─ osd.4 (SSD)  ← class hdd
     ├─ osd.5 (SSD)  ← class hdd
     ├─ osd.10(RAM)  ← class ram
     └─ osd.11(RAM)  ← class ram
```

新 EC 池的 CRUSH rule 限定 `device class = ram`，**完全不触及 SSD OSD**。

### 预期对比

| 指标 | SSD（PERC H730） | 纯内存盘 | 差距含义 |
|------|-----------------|---------|---------|
| Ceph EC 写带宽 | 106 MB/s | ? | 若大幅提升 → RAID 卡是瓶颈 |
| Ceph EC 写带宽 | 106 MB/s | ≈106 | 若持平 → 瓶颈在 Ceph/EC 协议/网络 |

---

## 操作步骤

### 一、每节点创建 brd 设备

```bash
# 在 ceph-node1, ceph-node2, ceph-node3 上各执行：
# 25 GiB = 26214400 KB，每节点 2 个，共加载 2 个设备

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

# 查看新 OSD ID
sudo cephadm shell -- ceph osd tree
# 预期：新增 osd.6~11，均显示在各自 host 下，class=hdd
```

### 三、用 device class 隔离新 OSD

```bash
# 假设新 OSD ID 为 6,7,8,9,10,11

# 给新 OSD 打上 "ram" 设备类别标签
for id in 6 7 8 9 10 11; do
  sudo cephadm shell -- ceph osd crush set-device-class ram osd.${id}
done

# 验证
sudo cephadm shell -- ceph osd tree
# 预期：osd.6~11 的 CLASS 列显示 ram
```

### 四、创建仅用 ram 设备的 EC 规则并建池

```bash
# 创建限定 device class=ram 的 EC profile
sudo cephadm shell -- ceph osd erasure-code-profile set ec-ram \
  k=4 m=2 crush-device-class=ram

# 获取新 profile 对应的 CRUSH rule 名称
# （Ceph 自动生成，名称格式通常为 ec-ram_rule）
sudo cephadm shell -- ceph osd erasure-code-profile get ec-ram 2>/dev/null
# 记下 crush-failure-domain=osd, crush-device-class=ram

# 直接创建池（Ceph 自动创建对应的 CRUSH rule）
sudo cephadm shell -- ceph osd pool create test-ram-ec erasure ec-ram
sudo cephadm shell -- ceph osd pool set test-ram-ec pg_num 128
sudo cephadm shell -- ceph osd pool set test-ram-ec pgp_num 128
sudo cephadm shell -- ceph osd pool application enable test-ram-ec rados

# 验证 CRUSH rule
sudo cephadm shell -- ceph osd crush rule ls
# 应有 ec-ram_rule
```

### 五、跑 rados bench

```bash
sudo cephadm shell -- rados bench -p test-ram-ec 60 write -t 64 --no-cleanup
```

### 六、清理

```bash
# 删除测试池
sudo cephadm shell -- ceph osd pool delete test-ram-ec test-ram-ec --yes-i-really-really-mean-it

# 删除 EC profile
sudo cephadm shell -- ceph osd erasure-code-profile rm ec-ram

# 销毁 ramdisk OSD
for id in 6 7 8 9 10 11; do
  sudo cephadm shell -- ceph orch daemon rm osd.${id} --force
  sudo cephadm shell -- ceph osd purge ${id} --yes-i-really-mean-it
done

# 每节点卸载 brd 并释放内存
# 在 ceph-node1/2/3 上各执行：
sudo modprobe -r brd
```

### 七、结果对比

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
3. **device class 隔离**：新 OSD 留在原有 host bucket 下，仅通过 class=ram 过滤
4. **新 pool 的 PG 只落在 class=ram 的 OSD 上**，不影响现有 pool
5. **不需要创建独立的 host bucket**（ceph-node1-ram 等），避免与 cephadm 主机名管理冲突