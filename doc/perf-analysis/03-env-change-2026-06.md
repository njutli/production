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
  接下来重点转向**多 RGW 负载均衡**（02 文档第二优先级）。
- ❌ **EC→3 副本（02 文档第三优先级）不再考虑**：存储规格硬性要求
  EC 4+2、空间利用率 ≥60%。EC 4+2 利用率 = k/(k+m) = 4/6 ≈ **66.7%**，
  满足要求；任何多副本方案（size=3 利用率仅 33%）一律排除。

---

## 四、RGW 实例数：2 个 vs 3 个

### 结论先行

> **建议先用 node1 + node3 两个 RGW，前置 LB。**
> 加 node2 凑成 3 个 RGW，**理论上限更高，但当前 node2 有部署障碍**，
> 且能否带来实际收益取决于瓶颈是否真在 RGW 这一层——需先压测确认。

### 多 RGW 与 LB 是同一个优化项（不可拆开）

- LB（负载均衡器，如 HAProxy/LVS）只有在有多个 RGW 时才有意义；
- 多 RGW 也**必须**有 LB 才能发挥作用：JuiceFS 只能配一个 S3 地址，
  若直接指向某个 RGW，所有流量压在那一个上，其余 RGW 闲置 = 白部署。
- 所以"部署多 RGW"和"部署 LB + 把 `RGW_ENDPOINT` 指向 LB"必须一起做。
- **工程现状（缺口）**：
  - `deploy-ceph.sh` 只部署 RGW，**没有任何 LB 实现**；
  - `config.sh` 的 `RGW_ENDPOINT` 写死单点 `http://${CEPH_SERVERS[0]}:8000`。
  - 即便 RGW 已部署到 node1+node3，JuiceFS 现在也只连 node1，第二个 RGW
    吃不到流量。**上多 RGW 前，必须先补 LB 部署并改 `RGW_ENDPOINT`。**


### 3 个为什么"理论上"更快

- RGW 是 S3 流量的入口与编解码点。JuiceFS 128 并发打到单个 RGW 时，
  单进程的 CPU / 连接处理 / 到 OSD 的出口带宽都可能成为瓶颈。
- 3 个 RGW 分散在 3 台千兆节点 → 聚合入口带宽 ~3×118MB/s，
  且每台本地 RGW 直接就近写本机 OSD，跨节点流量更均衡。
- 因此**当 RGW/网络是瓶颈**时，3 > 2 > 1，基本线性。

### 但当前有两个前提要先满足

1. **node2 的部署障碍（磁盘）**：
   - node2 根分区 `/dev/sda2` 仅 **20G，已用 94%，剩 ~1.3G**，
     RGW 容器/日志会迅速撑爆，MON 也已告警 `low on available space`。
   - 物理盘 sda 是 480G，但仅划了 20G 给根分区，且分区表异常
     （`parted` 显示 `Partition Table: unknown`），**原地扩容有风险**。
   - 内存没问题（220G）。所以 node2 上 RGW 的唯一阻碍是**根盘空间**。
   - 解决路径（任选）：
     a. 重新规划 node2 系统盘分区 / 扩根分区到 sda 剩余空间；
     b. 把 RGW 的数据目录/容器存储指到一块有空间的盘；
     c. 维持现状，不在 node2 放 RGW。

2. **瓶颈是否真在 RGW**：千兆环境下，瓶颈可能转移到 HDD + EC 4+2 的
   读改写（02 文档已指出 HDD 上 EC 随机小写放大严重）。若瓶颈在 OSD 盘，
   加第 3 个 RGW 收益有限。**必须用 `rados bench`（绕过 RGW）对比
   端到端 S3 压测**，判断 RGW 是不是限制项，再决定值不值得为 node2 扩盘。

### 落地建议

1. 部署 node1 + node3 两个 RGW，**同时**部署 LB（HAProxy/LVS）指向这两个
   RGW，并把 `config.sh` 的 `RGW_ENDPOINT` 改成 LB 地址，再跑基准。
   （工程当前无 LB、`RGW_ENDPOINT` 写死单点，这两处需先补齐。）
2. 对照 `rados bench`（后端裸能力）与 S3 端到端：
   - 若 S3 明显低于后端裸能力 → RGW 是瓶颈 → 值得给 node2 扩盘上第 3 个 RGW
     （LB 后端再加一个即可）。
   - 若两者接近 → 瓶颈在 OSD/EC → 第 3 个 RGW 收益不大，优先级降低。

