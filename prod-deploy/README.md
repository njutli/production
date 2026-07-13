# JuiceFS + TiKV + Ceph — 测试环境部署（prod-deploy）

> 4 机集群部署 JuiceFS（TiKV 元数据 + Ceph RADOS 数据），进行性能测试。
> 数据路径已去 RGW：JuiceFS 用 `--storage ceph` 直连 RADOS（librados），不部署 RGW、不需 LB（依据 `08_1`：去 RGW 后随机写 +71%）。

## 一、集群拓扑

| 机器 | 内网 IP | 角色 | 磁盘 | WekaIO |
|------|---------|------|------|--------|
| 157 (client) | 10.20.1.157 | JuiceFS client + cache | nvme1n1(894G ext4) → /mnt/jfs-cache | wekanode + wekafs /mnt/data04 |
| 150 (slave1) | 10.20.1.150 | TiKV+PD + 2 Ceph OSD | nvme1n1(894G) → TiKV / nvme2n1+nvme3n1(7T×2) → OSD | weka agent |
| 151 (slave2) | 10.20.1.151 | 同上 | 同上 | 无 |
| 152 (slave3) | 10.20.1.152 | 同上 | 同上 | weka agent |

### 架构图

```
                     JuiceFS Client (157)
                     FUSE mount /mnt/juicefs
                     ┌───────────────────────────────┐
                     │  cache on nvme1n1 (条件性)     │
                     │  --storage ceph (librados)     │
                     └──────┬──────────┬─────────────┘
                            │          │
                     metadata│   data   │ (RADOS direct)
                            │          │
                     ┌──────▼──┐  ┌───▼──────────────────────────┐
                     │ TiKV    │  │ Ceph EC 4+2                    │
                     │ 3 nodes │  │ 3 nodes × 2 OSD = 6            │
                     │ PD 3    │  │ DATA: nvme2n1 + nvme3n1 (7T×2)│
                     │ Raft 3  │  │ DB/WAL: tmpfs (内存盘) ⚠️      │
                     └─────────┘  │ allow_ec_overwrites=true       │
                                  └────────────────────────────────┘
                       150 / 151 / 152 (co-located)
```

> ⚠️ **DB/WAL 使用 tmpfs（内存盘）**：因 nvme1n1 已分配给 TiKV，无剩余物理 NVMe 做 DB/WAL。
> 当前用 tmpfs 代替——I/O 隔离效果等价独立 NVMe，但**断电即丢**，节点重启后 OSD 无法启动。
> 测试环境可接受（重建 OSD 即可），不影响 JuiceFS 逻辑正确性。

## 二、网络

| 接口 | 速率 | 网段 | 用途 | WekaIO 共用? |
|------|------|------|------|:---:|
| enp139s0f0np0 | 100GbE | 10.3.1.0/24 | Ceph public network（client→OSD） | ✅ RDMA 共用 |
| enp139s0f1np1 | 100GbE | 10.3.2.0/24 | Ceph cluster network（OSD 间 EC） | ✅ RDMA 共用 |
| eno12409 | 10GbE | 10.114.1.0/24 | **限速测试**（TBF 1Gbps 模拟千兆） | ❌ 独立 |
| eno12399 | 10GbE | 10.20.1.0/24 | 管理网 + SSH 跳板链路 | — |

> MTU 不设：100GbE 已 4200，10GbE 1500（默认）。不通过脚本改 MTU（红线：不动 100GbE 网卡）。

## 三、安全红线（贯穿所有操作）

| 层级 | 可否动 | 原因 |
|------|:---:|------|
| slave(150-152) 内核参数 | ✅ | 无业务，纯测试 |
| Ceph/TiKV 应用层参数 | ✅ | 纯测试集群 |
| eno12409 上的 tc tbf 限速 | ✅ | 独立 10GbE 网卡 |
| 157 内核参数（THP/dirty/read_ahead） | ❌ | WekaIO + K8s 在跑 |
| 100GbE 网卡/驱动/RoCE QoS | ❌ | 与 WekaIO 物理共用 |
| md0 / /mnt/data01-04 / /opt/weka | ❌ | WekaIO 业务路径 |

## 四、JuiceFS 挂载参数

### 4.1 配置分层

| 层 | 启用条件 | 配置 |
|----|---------|------|
| **基线（冷态）** | 所有节点，环境无关 | `--storage ceph` / `--block-size 256K` / `--max-uploads 150` / `--cache-size 0` / 无 writeback |
| **暖态增强（读缓存）** | 节点有非 OSD 数据盘的空闲空间 | `--cache-dir <非OSD盘>` / `--cache-size <N>` |
| **突发写增强（写缓存）** | 突发写负载 + 独立缓存盘 | `+ --writeback`（staging 落同一 `--cache-dir`） |

> 157 的 nvme1n1(894G) 可同时做 cache-dir（读缓存 + writeback staging 共用，空间由 `--cache-size` 和 `--free-space-ratio` 分别控制，详见 [JuiceFS 官方缓存文档](https://juicefs.com/docs/zh/community/guide/cache)）。

### 4.2 基线参数与调优依据

| 参数 | 值 | 调优依据 |
|------|-----|---------|
| `--storage` | `ceph`（直连 RADOS） | `08_1`：去 RGW 后随机写 +71% |
| `--block-size` | `256K` | `08_2`：默认 4MB 对 256K 随机读 ~16× 读放大 |
| `--max-uploads` | `150` | 演进报告 §四：顺序写 +23% |
| `--cache-size` | `0`（基线） | 冷态可复现、环境无关 |

## 五、Ceph / OSD 配置

| 项 | 值 | 依据 |
|----|-----|------|
| EC profile | k=4 m=2 | 6 OSD，容忍 2 盘故障 |
| failure-domain | `osd` | 3 节点 6 OSD，osd 级容错 |
| allow_ec_overwrites | `true` | JuiceFS 整对象写不触发 RMW |
| pg_num | 32 | 6 OSD 测试环境 |
| DB/WAL | tmpfs 内存盘（loop device） | ⚠️ 无剩余物理 NVMe；tmpfs 断电丢，重建即可 |
| 网络 | public=10.3.1.0/24 / cluster=10.3.2.0/24 | 双网 100GbE 分离 |

## 六、TiKV 配置

| 项 | 值 | 依据 |
|----|-----|------|
| 节点数 | 3（150/151/152） | Raft 3 副本，容忍 1 节点故障 |
| max-replicas | 3 | 3 节点 Raft majority=2 |
| PD | 3（每节点 1 个，奇数 Raft） | PD + TiKV 共置于 Ceph 节点 |
| 数据盘 | nvme1n1(894G ext4) → /mnt/jfs-tikv | 894G NVMe ext4 |

## 七、部署前检查清单

- [ ] 磁盘可用：157 的 nvme1n1 未挂载或可重新挂载
- [ ] 磁盘可用：150-152 的 nvme1n1 / nvme2n1 / nvme3n1 数据已清或可清
- [ ] 三层跳板 SSH 链路通畅（`bash scripts/setup-ssh-keys.sh`）
- [ ] 150-152 NOPASSWD sudo 已配
- [ ] eno12409 独立 10GbE 网卡可用（限速测试用）
- [ ] 100GbE 双网互通（10.3.1.0/24 + 10.3.2.0/24）

## 八、部署步骤

```bash
# 0. 验证 SSH 链路
bash scripts/setup-ssh-keys.sh

# 1. 准备所有服务器（挂载 nvme1n1、清理旧挂载、挂 tmpfs、装包）
bash scripts/prepare-all-servers.sh

# 2. 部署 TiKV 3 节点（PD + TiKV on 150-152）
bash scripts/deploy-tikv.sh

# 3. TiKV 冒烟测试（PD health + Go RawKV 读写删）
bash scripts/test-tikv.sh

# 4. 部署 Ceph 3 节点 6 OSD（EC 4+2，直连 RADOS，无 RGW，DB/WAL on tmpfs）
bash scripts/deploy-ceph.sh

# 5. Ceph 冒烟测试（MON/OSD/pool + 直连 RADOS 读写）
bash scripts/test-ceph.sh

# 6. 调优（仅 slave 150-152，157 不动）
# 逐台执行：
#   scp_to scripts/tune-servers.sh 10.20.1.150 /tmp/tune-servers.sh
#   ssh_to_slave 10.20.1.150 "sudo bash /tmp/tune-servers.sh"

# 7. 部署 JuiceFS 客户端（157，FUSE mount，直连 RADOS）
bash scripts/deploy-juicefs.sh format
bash scripts/deploy-juicefs.sh mount
bash scripts/deploy-juicefs.sh test     # 冒烟：写文件 → 读回 → 验证

# 8. 性能测试（不限速）
#    确认 Ceph 在 100GbE 网络 → 运行 bench-full.sh

# 9. 千兆限速测试
bash scripts/limit-bandwidth.sh apply    # Ceph 切 10GbE + TBF 1Gbps
#    运行 bench-full.sh
bash scripts/limit-bandwidth.sh remove    # 恢复 100GbE
```

## 九、限速测试切换

| 口径 | Ceph 网络 | TBF | JuiceFS 通信 |
|------|----------|-----|------------|
| **不限速** | public=10.3.1.0/24 / cluster=10.3.2.0/24（100GbE） | 无 | 100GbE TCP |
| **千兆限速** | public+cluster=10.114.1.0/24（eno12409） | TBF 1Gbps | 10GbE TCP（限速） |

切换方式（`limit-bandwidth.sh`）：
1. `ceph config set global public_network/cluster_network` → 切网段
2. `ceph orch restart mon/osd` → 重新绑定网卡
3. `tc tbf` on eno12409 → 限速
4. 更新 157 的 `/etc/ceph/ceph.conf` mon_host → 新 MON 地址

> **不在 100GbE RDMA 网卡上限速**（与 WekaIO 共用，红线）。

## 十、测试方法

### 双口径

| 口径 | 网络分母 | 50% 线 | 数据面 |
|------|----------|--------|--------|
| 不限速 | 12500 MiB/s | 6250 | 100GbE TCP（FUSE 用户态） |
| 千兆限速 | ~118 MiB/s | 59 | eno12409 TBF 1Gbps |

### fio 测试矩阵

| 测试项 | 参数 |
|--------|------|
| seqread | 1 job, bs=256K, direct=1 |
| seqwrite | 1 job, bs=256K, direct=1, end_fsync=1 |
| multi-seqread | 16 jobs, bs=256K |
| multi-seqwrite | 16 jobs, bs=256K, end_fsync=1 |
| layout | 128 jobs × 1G, bs=4M, end_fsync=1 |
| randread | 128 jobs, iodepth=128, bs=256K, 60s, 3 轮 |
| randwrite | 同上 |
| randrw | 同上 |
| bs sweep | randread at 64K/256K/1M, 3 轮 each |

### 冷态口径

- `--direct=1`（绕过 page cache）
- `--cache-size 0`（JuiceFS 基线冷态，无应用层缓存）
- 每项测前 `drop_all_caches`（客户端 157 + 全部 3 storage 节点）
- 随机项 3 轮取一致值

## 十一、目录结构

```
prod-deploy/
├── README.md                          # 本文件
├── config.sh                          # 集群配置（IP/跳板 SSH/3 节点 TiKV/6 OSD Ceph/双网）
├── scripts/
│   ├── setup-ssh-keys.sh             # 跳板 SSH 链路验证
│   ├── prepare-servers.sh            # 单机初始化（nvme1n1 挂载、清旧挂载、tmpfs、装包）
│   ├── prepare-all-servers.sh        # 一键编排（157 client + 150-152 slave）
│   ├── deploy-tikv.sh                # TiKV 3 节点部署（PD+TiKV, Raft 3 副本）
│   ├── deploy-ceph.sh                # Ceph 部署（6 OSD, EC 4+2, 直连 RADOS, 无 RGW）
│   ├── deploy-juicefs.sh             # JuiceFS 客户端（157, FUSE, 直连 RADOS）
│   ├── limit-bandwidth.sh            # 限速切换（Ceph 网络切换 + eno12409 TBF）
│   ├── test-tikv.sh                  # TiKV 冒烟（PD health + Go RawKV）
│   ├── test-ceph.sh                  # Ceph 冒烟（MON/OSD/pool + 直连 RADOS）
│   ├── tune-servers.sh               # 调优（仅 slave, 157 不动）
│   ├── config/tikv/{pd.toml,tikv.toml}  # TiKV 模板（__NODE_NAME__/__NODE_IP__ 占位）
│   └── tests/                         # Go 测试程序
├── skills/                            # 测试方法论
└── doc/
    ├── production-adjustments.md      # 调整清单
    └── deploy-log/                    # 部署调试记录
```
