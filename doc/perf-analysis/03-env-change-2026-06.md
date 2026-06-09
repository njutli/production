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
3. node1 上 ceph 相关软件、容器镜像都随系统一起没了，需重新准备。

### 推荐做法：纳管主机 + 重建 OSD（不动 node2/node3，不重装集群）

> 关键：**复用现有集群**，只修复 node1。整套重跑 `deploy-ceph.sh`
> 会尝试重新 bootstrap，对已有集群是危险/多余的。
>
> 下面 `<surv>` = 任一存活的 admin 节点（node2=192.168.11.13 或
> node3=192.168.11.14，二者都有 `_admin` 标签）。

#### 步骤 0：恢复 turboai 免密（已完成）

```bash
# 重装后 node1 主机密钥变了，先清旧 known_hosts 再重新分发 key
ssh-keygen -R 192.168.11.11
ssh-copy-id -i ~/.ssh/id_ed25519.pub turboai@192.168.11.11
```

#### 步骤 1：在 node1 上做与 deploy-ceph.sh「Step 1」等价的完整准备

> ⚠️ 只装 podman/cephadm **不够**。重装节点要恢复到和其他 Ceph 节点
> 一致的状态，下面每一项都不能少（与 `deploy-ceph.sh` Step 1 对齐）。

```bash
ssh turboai@192.168.11.11 '
  set -e
  # (a) 主机名——必须改，且要在 orch 操作之前。cephadm 用 hostname 作为
  #     orch host 标识；不改会被注册成另一台主机，导致重复/错乱。
  sudo hostnamectl set-hostname ceph-node1

  sudo apt-get update -qq || true

  # (b) podman（容器运行时，cephadm 依赖）
  command -v podman || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman

  # (c) 磁盘分区工具（步骤 4 建 LVM/抹盘要用 sgdisk/parted）
  command -v sgdisk || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk parted

  # (d) 停用 docker（与 podman 抢 socket，cephadm 要求 podman）
  sudo systemctl disable --now docker docker.socket 2>/dev/null || true

  # (e) cephadm + ceph-common + radosgw
  #     ceph-common 提供本地 ceph 命令；node1 还要跑 RGW，必须装 radosgw。
  command -v cephadm || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cephadm ceph-common radosgw

  # (f) Ubuntu 24.04(noble) 的 cephadm podman 版本检测 bug 补丁
  #     （若重装成 24.04，不打这个补丁后续容器操作会报 RuntimeError）
  if grep -q "24\.04\|noble" /etc/os-release; then
    sudo sed -i "s/raise RuntimeError.*get_version.*first/return (0, 0, 0)/" \
      /usr/lib/python3/dist-packages/cephadmlib/container_engines.py 2>/dev/null || true
  fi

  # (g) 开启 root SSH 登录——关键！光把公钥塞进 authorized_keys 不够，
  #     sshd 不允许 root 登录的话 mgr 照样连不上，host 仍是 Offline。
  sudo sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
  sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh
'
```

> (h) 预拉 Ceph 容器镜像单独拿出来做，见下方「步骤 1.5」——
> **不要写死 `:v19`**，必须用集群当前实际镜像，否则版本不一致。

#### 步骤 1.5：预拉与集群一致的 Ceph 容器镜像

> ⚠️ 常见坑：写死 `quay.io/ceph/ceph:v19` 是**错的**——本集群跑的是
> **17.2.8 (Quincy)**，拉 v19(Reef/Squid) 既慢又用不上。
> cephadm 默认用 `@sha256:` 摘要锁定镜像，**用摘要拉最保险**（版本号无所谓）。
> 这步可选：即便跳过，cephadm 在 node1 起容器时也会自动拉；预拉只是
> 避免首次起容器卡在下载。

```bash
# 1) 在存活节点查出集群当前镜像摘要 + 确认版本
ssh turboai@<surv> "sudo ceph version && sudo ceph versions"   # 看版本是否统一
IMG=$(ssh turboai@<surv> "sudo ceph config get mgr container_image")
echo "cluster image: ${IMG}"   # 形如 quay.io/ceph/ceph@sha256:a0f373...
```

```bash
# 2a) 网络好：直接在 node1 按摘要拉（和集群 100% 一致），失败就重试
#     podman 拉取不续传，但已下完的层会缓存复用，多试几次通常能成
ssh turboai@192.168.11.11 "
  for i in 1 2 3 4 5; do sudo podman pull '${IMG}' && break; echo retry \$i; sleep 5; done
"
```

```bash
# 2b) 外网不稳（如拉到一半 unexpected EOF）：从 node2/node3 内网离线传，
#     完全不碰外网，走千兆内网最稳
ssh turboai@<surv>           "sudo podman save '${IMG}' -o /tmp/ceph-img.tar"
scp turboai@<surv>:/tmp/ceph-img.tar /tmp/ceph-img.tar
scp /tmp/ceph-img.tar        turboai@192.168.11.11:/tmp/ceph-img.tar
ssh turboai@192.168.11.11    "sudo podman load -i /tmp/ceph-img.tar"
# 若 save 用摘要报错，先在 <surv> 上 `sudo podman images | grep ceph`
# 看本地实际的 REPOSITORY:TAG/<none>，用本地引用来 save。
```

#### 步骤 2：把现役集群的 cephadm 公钥装到 node1 的 root

```bash
ssh turboai@<surv> "sudo cephadm shell -- ceph cephadm get-pub-key" > /tmp/ceph.pub
scp /tmp/ceph.pub turboai@192.168.11.11:/tmp/ceph.pub
ssh turboai@192.168.11.11 '
  sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
  sudo cp /tmp/ceph.pub /root/.ssh/authorized_keys
  sudo chmod 600 /root/.ssh/authorized_keys
  sudo chown -R root:root /root/.ssh
'
```

#### 步骤 3：清除已不存在的旧 OSD（osd.0 / osd.1）

> `purge` 会一并清掉 auth、crush 条目，不必再单独 auth del / crush remove。
>
> ⚠️ 转义坑：下面**经控制机 SSH 远程执行**的写法里 `\$id` 的反斜杠是给外层
> shell 用的，传到远端正好是 `$id`。**若你已登录到节点本地直接执行，
> 必须去掉反斜杠**（用 `$id`），否则 Ceph 会收到字面字符串 `$id` 而报
> `Expected option value to be integer, got '$id'`。

```bash
# (A) 在控制机经 SSH 远程执行（注意 \$id）
ssh turboai@<surv> "sudo cephadm shell -- bash -c '
  for id in 0 1; do
    ceph osd out osd.\$id || true
    ceph osd purge osd.\$id --yes-i-really-mean-it || true
  done'"
```

```bash
# (B) 已登录到节点本地直接执行（用 $id，不要反斜杠）
sudo cephadm shell -- bash -c '
  for id in 0 1; do
    ceph osd out osd.$id || true
    ceph osd purge osd.$id --yes-i-really-mean-it || true
  done'

# 或最省心：两条写死，不用循环，本地/远程都不踩转义坑
sudo cephadm shell -- bash -c '
  ceph osd out osd.0; ceph osd purge osd.0 --yes-i-really-mean-it
  ceph osd out osd.1; ceph osd purge osd.1 --yes-i-really-mean-it'
```

#### 步骤 4：让 orchestrator 重新连上 node1

```bash
# host 条目还在（只是 Offline），刷新地址触发重新连接即可，不要重复 host add
ssh turboai@<surv> "sudo cephadm shell -- ceph orch host set-addr ceph-node1 192.168.11.11"

# 等几十秒后确认 STATUS 不再是 Offline（cephadm check 通过）
ssh turboai@<surv> "sudo cephadm shell -- ceph orch host ls"
```

> 注意：node1 带 `_admin`/在 MON placement 内，纳管成功后 cephadm 会
> **自动在 node1 重新拉起 MON**——node1 根盘 98G 充足，没有 node2 的
> 空间问题，MON 会自动回到 quorum，无需手动操作。

#### 步骤 5：在 node1 的 sdb 上重建 2 个 OSD

```bash
# 先确认 sdb 不是系统盘（重装后系统在 sda，sdb 安全），且无残留 LVM
ssh turboai@192.168.11.11 "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE /dev/sdb"

# 与 deploy-ceph.sh Step 4 同法：抹盘 → PV → VG(ceph-vg-ceph-node1)
# → 2×LV(osd0/osd1) → ceph orch daemon add osd ceph-node1:/dev/<vg>/<lv>
```

#### 步骤 6：等待回填并确认健康

```bash
ssh turboai@<surv> "sudo cephadm shell -- ceph -s"
# 期望：6 osds: 6 up, 6 in；PG 回填完成后 HEALTH_OK
```

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

