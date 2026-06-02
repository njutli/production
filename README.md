# JuiceFS + TiKV + Ceph RGW — Production (4 Machines)

## 架构

```
                       JuiceFS Client
                  (FUSE mount, shared with TiKV or Ceph machine)
                       │
          ┌────────────┼────────────┐
          ▼                         ▼
   Metadata (TiKV)           Data (Ceph RGW S3)
   ┌──────────────┐          ┌──────────────────────────┐
   │ 1 × PD+TiKV  │          │ 3 × Ceph MON+MGR+OSD+RGW │
   │ single-replica│          │ EC 4+2, osd-level domain │
   │              │          │ 1 OSD per server          │
   └──────────────┘          └──────────────────────────┘
    192.168.11.12             192.168.11.11 / .13 / .14
```

| 机器 | IP（示例） | 角色 | 配置建议 |
|------|-----------|------|---------|
| tikv-node | 192.168.11.12 | PD + TiKV (单实例) | 4C/8G/50G+ SSD |
| ceph-node1 | 192.168.11.11 | MON + MGR + RGW + OSD | 4C/8G/专用 OSD 裸盘 |
| ceph-node2 | 192.168.11.13 | MON + MGR + RGW + OSD | 4C/8G/专用 OSD 裸盘 |
| ceph-node3 | 192.168.11.14 | MON + MGR + OSD | 4C/8G/专用 OSD 裸盘 |

所有机器统一使用 **turboai** 用户，特权操作用 `sudo`。
Ceph 内部 cephadm 通信仍需 root SSH（脚本自动配置）。

## 设计决策

### 为什么 TiKV 单节点、单副本

- 4 台机器的约束下，TiKV 只能分到 1 台
- 单机上跑 3 副本是无意义的：机器宕机所有副本一起丢，且 PD 会因 `max-replicas=3` 持续报警
- 配置 `max-replicas=1`，PD 不再期望副本冗余，集群状态为 healthy
- 额外收益：无 Raft 日志复制开销，元数据写入延迟更低（省去 2 次网络 RTT）

### 客户端放置策略

为减少性能测试干扰，根据测试类型选择客户端位置：

| 测试场景 | 客户端放在 | 原理 |
|---------|-----------|------|
| **数据密集**（大文件读写） | tikv-node | TiKV 在数据路径上负载极轻，瓶颈在 Ceph OSD 的网络 I/O — 不受客户端干扰 |
| **元数据密集**（海量 stat/create） | ceph-node | Ceph OSD 线程会和 JuiceFS FUSE + TiKV 请求争 CPU，但方向明确 — 成绩差说明 Ceph 机器不够 |

使用方法：运行 `deploy-juicefs.sh` 前编辑 `config.sh` 中的 `JUICEFS_CLIENT`，将脚本复制到对应机器执行。

### Ceph 配置

- **MON**: 3 节点（仲裁，必须奇数）
- **OSD**: 每节点 1 个裸盘，`deploy-ceph.sh` 自动用 `sgdisk` 将每块盘平分为 2 个分区 → 3 机 × 2 分区 = 6 OSD
- **EC 4+2**: 6 个 OSD 正好满足 6 个 chunk 的需求，`failure-domain=osd`（容忍任意 2 个 OSD 故障）

## 快速开始

### 0. 配置 SSH 免密登录

```bash
# 生成密钥 + 分发到所有 Ceph 机器（输入各机器密码一次）
bash production/setup-ssh-keys.sh
```

### 1. 准备所有服务器

每台机器上执行（setup-ssh-keys.sh 完成后即可远程执行 Ceph 节点）：

```bash
# TiKV 服务器（本机 192.168.11.12，空闲盘 /dev/sdb 953G）
sudo bash production/prepare-servers.sh tikv /dev/sdb

# Ceph 服务器 × 3（NOPASSWD sudo 由 prepare-servers.sh 自动配置）
for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    scp -i ~/.ssh/id_ed25519 production/prepare-servers.sh turboai@${ip}:/tmp/
    ssh -i ~/.ssh/id_ed25519 turboai@${ip} 'sudo bash /tmp/prepare-servers.sh ceph'
done
```

### 2. 部署 TiKV

```bash
bash production/deploy-tikv.sh
```

验证：
```bash
curl http://192.168.11.12:2379/pd/api/v1/health
# → {"health": true}

curl http://192.168.11.12:2379/pd/api/v1/stores
# → 1 个 store 正常注册
```

### 3. 部署 Ceph

```bash
bash production/deploy-ceph.sh
```

验证：
```bash
ssh turboai@192.168.11.11 'sudo cephadm shell -- ceph status'
ssh turboai@192.168.11.11 'sudo cephadm shell -- ceph osd tree'
```

### 4. 性能调优

每台机器执行（部署完成后）：

```bash
# TiKV 机器
sudo bash production/tune-servers.sh tikv
sudo systemctl restart pd tikv   # 仅 fd limits 需要重启

# Ceph 机器
sudo bash production/tune-servers.sh ceph
# swap/THP/sysctl/I/O scheduler 即时生效，fd limits 需重启 OSD
```

### 5. 部署 JuiceFS

```bash
# 测试数据密集型 → 客户端在 tikv-node
# 修改 config.sh: JUICEFS_CLIENT="${TIKV_SERVER}"
bash production/deploy-juicefs.sh format
bash production/deploy-juicefs.sh mount
bash production/deploy-juicefs.sh test

# 测试元数据密集型 → 客户端切换到 ceph-node1
# 修改 config.sh: JUICEFS_CLIENT="${CEPH_SERVERS[0]}"
# 再将 deploy-juicefs.sh 复制到 ceph-node1 执行
```

## 与 WSL2 Demo 的关键差异

| Demo | 生产（4 机） |
|------|-------------|
| 3 TiKV + 3 Ceph (6 VM) | 1 TiKV + 3 Ceph (4 物理机) |
| Raft 三副本 | 单副本 (max-replicas=1) |
| PD Raft 选举等待 15s | 无，单节点秒启动 |
| QEMU VM + cloud-init | 物理机 systemd |
| 双网桥 br0/br1 + socat 代理 | 单物理网络 |
| 每 VM 2 个 OSD (qcow2 盘) | 每机 1 盘 → 2 分区 → 6 OSD |
| EC 4+2, 6 OSD → 容量利用率 66% | 同 EC 4+2, 6 OSD |

## 目录结构

```
production/
├── README.md
├── setup-ssh-keys.sh          # 生成密钥 + 分发到所有机器（首次运行）
├── config.sh                  # 全局配置（改 IP 即可）
├── config/tikv/
│   ├── pd1.toml               # 单节点 PD（max-replicas=1）
│   ├── tikv1.toml             # 单节点 TiKV
│   └── topology.yaml
├── prepare-servers.sh         # 服务器初始化（每台手动执行，不含调优）
├── setup-ssh-keys.sh          # 生成密钥 + 分发到所有机器（首次运行）
├── deploy-tikv.sh             # 部署 1 台 TiKV
├── deploy-ceph.sh             # 部署 3 台 Ceph
├── tune-servers.sh            # 性能调优（部署后执行：swap/THP/sysctl/IO/limits）
└── deploy-juicefs.sh          # JuiceFS 客户端（format/mount/test）
```

## 日常管理

```bash
# TiKV
ssh turboai@192.168.11.12 sudo systemctl status pd tikv
ssh turboai@192.168.11.12 sudo journalctl -u tikv -f
curl http://192.168.11.12:2379/pd/api/v1/health

# Ceph
ssh turboai@192.168.11.11 'sudo cephadm shell -- ceph status'
ssh turboai@192.168.11.11 'sudo cephadm shell -- ceph osd tree'
ssh turboai@192.168.11.11 'sudo radosgw-admin user info --uid=juicefs'

# JuiceFS
juicefs status tikv://192.168.11.12:2379/juicefs-prod
df -h /mnt/juicefs
```
