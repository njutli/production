# 环境适配清单

> 本文记录 prod-deploy 的逐项配置状态。
> 环境：4 机（157 client + 150-152 TiKV+Ceph 共置）/ 100GbE 双网 / 每节点 3 NVMe。

---

## ✅ 已落地项

### §一 TiKV：单节点单副本 → 3 节点 3 副本 — **已完成**

| 项 | 状态 | 说明 |
|----|------|------|
| `config.sh` TIKV_SERVERS | ✅ | 3 节点数组 (150/151/152) |
| `config.sh` PD_ENDPOINTS | ✅ | 3 端点逗号分隔 |
| `config.sh` TIKV_MAX_REPLICAS | ✅ | =3 |
| `scripts/config/tikv/pd.toml` | ✅ | 单模板 + `__INITIAL_CLUSTER__` 占位，deploy 时注入 3 peer |
| `scripts/config/tikv/tikv.toml` | ✅ | 单模板 + `__PD_ENDPOINTS_TOML__` 占位 |
| `scripts/deploy-tikv.sh` | ✅ | 循环 3 节点远程部署 |
| PD + TiKV 共置 | ✅ | 与 Ceph 节点共置（150-152），nvme1n1 → /mnt/jfs-tikv |

### §二 节点数与拓扑 — **已完成**

4 机 = 1 client(157) + 3 TiKV+Ceph 共置(150-152)。无额外机。

### §三 Ceph EC profile — **已完成**

| 项 | 值 | 状态 |
|----|-----|------|
| EC | 4+2（6 物理盘，不切 LV） | ✅ |
| failure-domain | `osd`（3 节点 6 OSD） | ✅ |
| OSD | 每节点 2 物理盘（nvme2n1 + nvme3n1）= 6 OSD | ✅ 1 盘 1 OSD，不切 LV |

### §四 网络 — **已完成**

| 项 | 值 | 状态 |
|----|-----|------|
| public_network | 10.3.1.0/24（enp139s0f0np0, 100GbE） | ✅ |
| cluster_network | 10.3.2.0/24（enp139s0f1np1, 100GbE） | ✅ |
| MTU | 4200（100GbE 已有，不设不改） | ✅ |
| 限速网络 | eno12409（10.114.1.0/24, 10GbE 独立） | ✅ |

### §五 DB/WAL — **tmpfs 内存盘（测试专用）**

nvme1n1 已分配给 TiKV，无剩余物理 NVMe 做 DB/WAL。采用 **tmpfs 内存盘 + loop device** 方案：
- 每 OSD 在 tmpfs 上创建 40G DB 文件 + 10G WAL 文件，用 `losetup` 包装为 block device
- `ceph-volume lvm create --data <data_disk> --block.db <loop_dev> --block.wal <loop_dev>`
- I/O 隔离效果等价独立物理 NVMe（DB/WAL 走内存，DATA 走物理盘）
- ⚠️ **断电即丢**：节点重启后 tmpfs 清空，OSD 无法启动。测试环境可接受（重建 OSD 即可）
- **生产环境应替换为独立物理 NVMe**（持久化），架构其余部分不变

| 项 | 值 | 状态 |
|----|-----|------|
| DB 大小 | 40G / OSD | ✅ |
| WAL 大小 | 10G / OSD | ✅ |
| tmpfs 挂载 | /mnt/dbwal, size=200G | ✅ |
| loop device | losetup 包装 tmpfs 文件 | ✅ |
| ceph-volume | lvm create --block.db --block.wal | ✅ |

### §六 cache / writeback 缓存盘 — **条件性**

157 的 nvme1n1(894G) 可做 cache-dir（非 OSD 盘，满足"不与 OSD 共盘"要求）。
- 冷态基线：`--cache-size 0`
- 暖态增强：`--cache-dir /mnt/jfs-cache --cache-size 102400`（按需开）
- writeback：突发写负载时开（staging 空间由 `--free-space-ratio` 控制）

### §七 验收口径 — **双口径**

| 口径 | 分母 | 50% 线 | 用途 |
|------|------|--------|------|
| 100GbE 不限速 | 12500 MiB/s | 6250 | 暴露后端真实能力 |
| 千兆限速（eno12409 TBF 1Gbps） | ~118 MiB/s | 59 | 千兆场景模拟 |

### §八~§十 单点/硬编码 — **已清理**

| 项 | 状态 |
|----|------|
| SSH_USER | ✅ sunrise（非 turboai） |
| SSH 方式 | ✅ 三层跳板（ssh_to_client/ssh_to_slave/scp_to） |
| OSD 期望 | ✅ 6（由 CEPH_OSD_DEVICES_PER_NODE 算） |
| deploy-tikv.sh 模式 | ✅ "3-replica (max-replicas=3)" |
| deploy-ceph.sh 标题 | ✅ 4 机集群环境 |
| JUICEFS_CLIENT | ✅ 10.20.1.157（非 TiKV 节点） |

### §十一 TESTING-GUIDE 适配 — **待落地**

| 项 | 状态 | 说明 |
|----|------|------|
| §11.1 测试 runner keyring | ✅ | deploy-ceph.sh Step 6 已将 ceph.conf + keyring 分发到 157 |
| §11.2 NIC 名 | ✅ | config.sh 已填 PUBLIC_NIC=enp139s0f0np0 / CLUSTER_NIC=enp139s0f1np1 |
| §11.3 OSD 设备名 | ✅ | config.sh CEPH_OSD_DEVICES_PER_NODE=(nvme2n1 nvme3n1) |
| §11.4 可靠性阈值 | ✅ | 双口径（100GbE=6250 / 千兆=59） |
| §11.5 cache 目录 | ✅ | config.sh JUICEFS_CACHE_DIR=/mnt/jfs-cache |
| §11.6 health-check 库 | ✅ | 已同步到 scripts/tests/lib/ |
| §11.7 layout 大小 | 待定 | 按 100GbE 放大（见下） |
| §11.8 暖态 cache-size | ✅ | config.sh JUICEFS_CACHE_SIZE_MB（冷态=0） |
| §11.9 OSD 数量 | ✅ | 动态枚举，非硬编码 6 |

---

## 待办项

### 1. layout 工作集大小（100GbE 缩放）

测试环境 128G layout（128 jobs × 1G）在 100GbE 下可能需要放大（确保 > 暖态 cache-size 且冷态真冷）。部署后根据实际 cache-size 调整。

### 2. bench-full.sh 测试脚本

需适配 bench-full.sh：
- mount 点 /mnt/juicefs
- drop_all_caches 保留（客户端 157 + 3 storage 节点）
- fio 参数完全对齐（bs=256K, direct=1, 128 jobs, etc.）

### 3. 限速测试的 OSD 重启验证

`limit-bandwidth.sh` 切换网络后需重启 OSD+MON，需验证：
- 所有 OSD 在新网络（10.114.1.0/24）上 rebind 成功
- JuiceFS client（157）能通过新 mon_host 连接
- 切回 100GbE 后服务正常恢复

### 4. 157 内核参数不调（红线确认）

157 保持系统默认（保护 WekaIO+K8s）：
- THP: madvise（默认，不设 never）
- dirty_ratio: 20（默认，不设 10）
- read_ahead: 默认（不设 4096）
- tune-servers.sh 仅在 150-152 执行，157 不执行

---

> 调整过程与真盘复测结果记录到 `doc/deploy-log/`（对标上层 `doc/perf-analysis/`）。
