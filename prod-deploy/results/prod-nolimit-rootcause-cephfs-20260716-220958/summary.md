# 01-4 根因定位 + CephFS 对照 Summary

## 任务信息
- 任务书：`doc/perf-tasks/01-4-rootcause-and-cephfs-control-task-book.md`
- 执行日期：2026-07-16
- 结果目录：`results/prod-nolimit-rootcause-cephfs-20260716-220958/`
- 远端数据：157:`/tmp/scalability-results/01-4-pprof/` + `01-4-cephfs/`

## 步骤1：pprof 热点分析（C1/C2/C3 判定）

**pprof → C1（FUSE /dev/fuse dispatch 模型）为主要根因**

| 调用路径 | cum% | 分类 |
|----------|------|------|
| fuse.Server.loop | 31.51% | C1 FUSE 主循环 |
| └ fuse.Server.write → writev → /dev/fuse | 17.54% | C1 写回内核 |
| └ cephReader.Read → rados.IOContext.Read | 16.03% | C2 从 RADOS 读 |
| runtime.cgocall | 21.98% | C1+C2 cgo 开销 |
| Syscall6 | 18.98% | C1+C2 系统调用 |
| futex + Mutex.Lock | 2.30% | C3 锁（次要） |

- 锁竞争仅 2.3%，非瓶颈；goroutine 分布均匀，无单点锁死
- **客户端无对应旋钮** → 跳过步骤2，进入步骤3

## 步骤2：跳过（C1 判定，无客户端参数可调）

## 步骤3：CephFS 内核态对照

### 部署
- MDS: cephfs.ceph-node1 (up:active)
- Pools: cephfs_metadata (replicated) + cephfs_data_ec (EC4+2) + cephfs_data_rep (replicated)
- Mount: `mount -t ceph` 内核态客户端

### randread 对照

| 口径 | CephFS EC | CephFS Rep | JuiceFS ra0 | EC/JuiceFS | Rep/JuiceFS |
|------|-----------|------------|-------------|------------|-------------|
| S0 (16384) | 4608 | 6718 | 2876 | 1.60× | **2.34×** |
| D2 (128) | 4614 | — | 1833 | 2.52× | — |

- CephFS S0 ≈ D2（4608≈4614）→ **无 CPU 封顶**（对比 JuiceFS S0>>D2 受 6 核限制）
- CephFS Rep 6718 > 6250 验收线 → 单客户端可达标
- EC 解码开销：Rep 6718 vs EC 4608 = 1.46×（EC 读需 4 片 + 解码）

### randrw 对照（D2 = 16×8 = 128，验收口径）

| 口径 | CephFS EC R | CephFS EC W | CephFS Rep R | CephFS Rep W | JuiceFS R | JuiceFS W |
|------|-------------|-------------|--------------|--------------|-----------|-----------|
| median | 1498 | 1498 | 2392 | 2392 | 460 | 460 |

- R/W = 1:1 均衡（全口径一致）
- CephFS EC 合计 2996 vs JuiceFS 919 = 3.26×
- CephFS Rep 合计 4784 vs JuiceFS 919 = 5.20×
- EC 写未崩（ec_overwrites 有效，R/W 均衡）

### 判定（对照 §3.2 判读表）

| 现象 | 判定 |
|------|------|
| CephFS randread **显著 > 2876**（EC 4608, Rep 6718） | ✅ 反证：根因确是 FUSE 用户态方案（C1 坐实） |
| CephFS + EC 写未崩（R/W 均衡） | EC overwrite 对 CephFS 可用 |
| CephFS 无 CPU 封顶（S0≈D2） | 内核态无用户态 dispatch 瓶颈 |

## 结论

**根因 = C1（FUSE /dev/fuse dispatch 模型）**
- pprof 证实：31.5% CPU 在 FUSE 主循环，17.5% 在 writev 写回 /dev/fuse
- CephFS 对照证实：同后端、同口径，内核态获 1.60-5.20× 带宽提升
- 客户端无调优空间（步骤2 跳过）

**是否换栈由用户拍板**（附 CephFS vs JuiceFS 同口径数据）
