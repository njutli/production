# 环境变更记录（2026-06，硬件升级 + node1 重装）

> 本文记录 2026-06 的硬件/拓扑变化，以及对部署工程的影响。
> 它**更新**了 `01-measured-data.md` / `02-bottleneck-analysis.md` 里
> 关于"node1/node2 是 100Mb/s 网卡"的结论——该瓶颈已不存在。

---

## 一、变更内容

### 1. 网络全部升级到千兆（核心变化）

重新实测（`/sys/class/net/<nic>/speed` + `ethtool`）：

| 节点 | IP | 默认网卡 | 当前速率 | 旧记录 |
|------|-----|---------|---------|--------|
| ceph-node1 | 192.168.11.11 | eno1 | **1000Mb/s** | 100Mb/s |
| ceph-node2 | 192.168.11.13 | eno1 | **1000Mb/s** | 100Mb/s（**记录有误**，复核为千兆） |
| ceph-node3 | 192.168.11.14 | eno1 | 1000Mb/s | 1000Mb/s |
| tikv-node  | 192.168.11.12 | —    | 1000Mb/s | 1000Mb/s |

> 结论：`02-bottleneck-analysis.md` 里"node1/node2 = 100Mb/s 是头号瓶颈"
> 已**不再成立**。三台 Ceph 节点现在都是千兆。
> 注意：node2 之前被记成百兆，本次复核确认它一直/现在是千兆。

预期影响：后端理论上限从 ~10~12 MB/s 提升到单链路千兆 ~118 MB/s，
EC 4+2 写放大后估算 ~60~90 MB/s（详见 02 文档"网卡升级后"一节）。

### 2. ceph-node1（192.168.11.11）重装系统

- 系统盘变化：**系统现在装在 sda**（LVM，root 在 `ubuntu-vg/ubuntu-lv`，~98G 根分区），
  之前是反着的（系统在 sdb、OSD 用 sda）。
- **sdb（953G）空出来**，作为本节点唯一的 OSD 数据盘。
- 因此 `config.sh` 的 `CEPH_OSD_DEVICES` 从 `(/dev/sda /dev/sdb /dev/sdb)`
  改为 **`(/dev/sdb /dev/sdb /dev/sdb)`**（三节点统一用 sdb，不再有反转特例）。
- 根分区容量：node1 ~98G、node3 ~147G、**node2 仍仅 20G（剩 2G）**。
  → RGW 仍只放在磁盘充裕的节点（node1 + node3），node2 不放 RGW/避免撑爆。

### 3. 部署工程改动（已改，未提交）

- `config.sh`：`CEPH_OSD_DEVICES` → 全 `/dev/sdb`，更新容量注释。
- `deploy-ceph.sh`：RGW 从单点 `ceph-node1` 改为 `ceph-node1,ceph-node3`
  （千兆后多 RGW 才有意义），结束语 endpoint 同步为 node1 + node3。

---

## 二、node1 能直接加回集群吗？

**不能直接加回，但也不需要重装整套集群——只需把 node1 作为"换过盘的主机"
重新纳管，再重建它的 2 个 OSD。**

### 现状（从存活节点 node2/node3 实测）

集群 `073f28e0-...` 仍在线，quorum 在 node2+node3：

```
mon: 3 daemons, quorum ceph-node2,ceph-node3, out of quorum: ceph-node1
osd: 6 osds: 4 up, 4 in        # osd.0 / osd.1 (node1) down+out
health: HEALTH_WARN
  - 1 hosts fail cephadm check        # node1 重装后旧 root SSH key 失效
  - mon ceph-node1 down
  - Degraded/undersized PGs           # EC 分片少了 node1 的 2 个 OSD
orch host ls: ceph-node1  192.168.11.11  _admin  Offline
osd tree:     osd.0/osd.1 在 host ceph-node1 下，STATUS=down
```

### 为什么不能"直接"加回

1. **重装后旧的 cephadm root SSH 公钥没了**，mgr 连不上 node1
   （`1 hosts fail cephadm check` / host `Offline`）。
2. **原来的 OSD 盘已被抹掉**：旧 OSD 在原 sda 上，重装后系统占了 sda、
   数据盘换成 sdb，osd.0/osd.1 的 BlueStore 数据**不复存在**。
   这两个 OSD 只能**删掉重建**，无法原样拉起。
3. node1 上没有 ceph 软件（podman/cephadm/容器镜像都随系统一起没了）。

### 推荐做法：纳管主机 + 重建 OSD（不动 node2/node3，不重装集群）

> 关键：**复用现有集群**，只修复 node1。整套重跑 `deploy-ceph.sh`
> 会尝试重新 bootstrap，对已有集群是危险/多余的。

步骤（在控制机执行，PRIMARY 指向存活的 node2 或 node3）：

```bash
# 0) 已完成：重新分发 turboai SSH key 到重装后的 node1
#    （ssh-copy-id turboai@192.168.11.11）

# 1) 在 node1 上装好 podman/cephadm（可复用 deploy-ceph.sh Step 1 的逻辑，
#    或手动 apt 安装），并设置 hostname=ceph-node1

# 2) 把现役集群的 cephadm 公钥重新装到 node1 的 root（重装后丢了）
ssh turboai@<node2> "sudo cephadm shell -- ceph cephadm get-pub-key" > /tmp/ceph.pub
ssh turboai@192.168.11.11 "sudo mkdir -p /root/.ssh && \
  sudo tee /root/.ssh/authorized_keys < /tmp/ceph.pub && \
  sudo chmod 600 /root/.ssh/authorized_keys"

# 3) 先把旧的、已不存在的 OSD 清出 CRUSH（彻底移除 osd.0 / osd.1）
ssh turboai@<node2> "sudo cephadm shell -- bash -c '
  for id in 0 1; do
    ceph osd out osd.\$id || true
    ceph osd purge osd.\$id --yes-i-really-mean-it || true
  done'"

# 4) 让 orchestrator 重新纳管 node1（host 已存在，刷新连接即可）
ssh turboai@<node2> "sudo cephadm shell -- ceph orch host set-addr ceph-node1 192.168.11.11"
#    确认 STATUS 不再是 Offline：
ssh turboai@<node2> "sudo cephadm shell -- ceph orch host ls"

# 5) 在 node1 的 sdb 上重建 2 个 OSD（与 deploy-ceph.sh Step 4 同法：
#    PV→VG→2×LV，再 ceph orch daemon add osd）
#    抹盘前务必确认 sdb 不是系统盘（重装后系统在 sda，sdb 安全）：
ssh turboai@192.168.11.11 "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE /dev/sdb"

# 6) 等待回填(backfill)完成，健康恢复 HEALTH_OK：
ssh turboai@<node2> "sudo cephadm shell -- ceph -s"
```

完成后：6 个 OSD 全部 up/in、EC PG 重新补齐、node1 MON 回到 quorum。

### 一句话回答

> node1 **不能直接 up 回来**（盘抹了、SSH key 没了），
> 但**只需重新纳管并重建它的 2 个 OSD**即可，
> **不必重装整个 Ceph 集群**——node2/node3 的数据和 quorum 都还在。

---

## 三、对原瓶颈结论的修订

- ✅ 网络瓶颈（100Mb/s）**已消除**，三台 Ceph 节点均千兆。
- ⏭ 现在应重跑 `diag.sh` 的网络/后端基准（`iperf3` + `rados bench`），
  用千兆环境下的新数据替换 `01-measured-data.md` 里 9.87 MB/s 的旧值。
- ⏭ 02 文档"优化方向"里的第一优先级（修网络）已落地，
  接下来重点转向**多 RGW 负载均衡**与（必要时）**EC→3 副本**。
