# Ceph 部署问题排查记录

## 环境

- **集群版本**: Ceph 17.2.8 (Quincy)，cephadm + podman 容器化部署
- **节点**: 3 台 Ubuntu 22.04，用户 `turboai`，通过 `sudo` 提权
- **拓扑**: 1 TiKV + 3 Ceph，Ceph 节点 IP: 192.168.11.11 / 13 / 14

---

## 问题 1: apt-get update 因第三方源失效失败

### 现象
```
W: Failed to fetch https://repo.saltproject.io/salt/py3/ubuntu/22.04/amd64/latest/dists/jammy/InRelease
E: The repository 'https://repo.saltproject.io/...' no longer has a Release file.
```
脚本中 `set -e` 导致 `apt-get update` 失败后直接退出。

### 原因
机器上配置了第三方 apt 源（saltstack、docker-ce 等），这些源已失效。`apt-get update` 一次性刷新所有源，任一个失败则整体失败。但脚本需要的包（chrony、gdisk 等）来自 Ubuntu 主源，主源是好的。

### 解决
`apt-get update` 加 `|| true` 容忍第三方源失败，但 `apt-get install` 包安装失败必须退出（这是真正的错误）。

### 代码变更
```bash
# 修复前
apt-get update -qq

# 修复后
apt-get update -qq || echo "  (apt update had errors, continuing)"

# 包安装保持严格
DEBIAN_FRONTEND=noninteractive apt-get install -y chrony || { echo "ERROR"; exit 1; }
```
**区分 update 失败和 install 失败**：前者可能是第三方源问题，后者是网络/源真的不可用。

---

## 问题 2: chrony 安装与 systemd-timesyncd 冲突

### 现象
```
chrony : Conflicts: time-daemon
systemd-timesyncd : Conflicts: time-daemon
E: Unmet dependencies.
```

### 原因
Ubuntu 22.04 默认运行 `systemd-timesyncd`（提供 SNTP 时间同步）。chrony 和 systemd-timesyncd 都声明 `Conflicts: time-daemon`，互斥，不能同时安装。脚本强制装 chrony 会报 unmet dependencies。

### 解决
先检查 `systemd-timesyncd` 是否已活跃。如果是，跳过 chrony 安装——它已经提供了足够的时间同步（秒级精度足够 RAFT/Paxos）。

### 代码变更
```bash
# 先检查 systemd-timesyncd
if systemctl is-active systemd-timesyncd &>/dev/null; then
    echo "  systemd-timesyncd already active."
elif ! command -v chronyd &>/dev/null; then
    apt-get install -y chrony || apt-get install -y ntp || { exit 1; }
fi
```
**教训**: 不要假设目标机器的软件栈是空的，先检查已有服务。

---

## 问题 3: apt 缓存过期导致 404

### 现象
```
Err:1 http://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy-updates/main amd64 libavahi-common-data
  404  Not Found
```

### 原因
清华镜像站已轮转清理旧版本 deb 包，但机器本地 apt 索引未刷新。`apt-get update` 被 `|| true` 吞掉后，`apt-get install` 拿着过期 URL 去下载旧包 → 404。

**关键区别**: 手动执行 `apt-get update` 能成功，脚本里失败，因为脚本用 `-qq 2>/dev/null` 隐藏了错误输出。

### 解决
去掉 `2>/dev/null`，让 apt 错误直接打印，便于排查。真正无法安装时（网络不通）由后面的 `|| { exit 1; }` 拦截。

### 教训
`2>/dev/null` 在调试阶段是最危险的静默——不要吞掉 stderr。`-qq` 已经够安静了。

---

## 问题 4: linux-headers 破损拖累所有 apt 操作

### 现象
```
linux-headers-5.15.0-164-generic : Depends: linux-headers-5.15.0-164 but it is not going to be installed
E: Unmet dependencies. Try 'apt --fix-broken install'
```

### 原因
`linux-headers-5.15.0-164-generic` 处于半安装状态（依赖的 `linux-headers-5.15.0-164` 未成功安装），导致**所有**后续 `apt-get install` 都报 unmet dependencies。

### 解决
```bash
sudo apt --fix-broken install
```
脚本中在 podman 安装失败时自动尝试 `apt --fix-broken install` 然后重试。

---

## 问题 5: root 账户被锁导致 cephadm SSH 失败

### 现象
```
root@localhost: Permission denied (publickey,password).
```
`ceph orch device zap` 和 `daemon add osd` 全部报 `Device path not found`。

### 排查
```bash
sudo passwd -S root
# root L 09/11/2024 0 99999 7 -1
```
`L` 表示 locked——账户被密码策略锁定。Ubuntu 默认锁定 root，SSH 不接受任何认证（包括密钥）。

### 原因
`PermitRootLogin yes` 只是允许 SSH 尝试 root 认证，但锁定的账户会被 pam 直接拒绝。cephadm 的所有节点间操作都走 root SSH，必须解锁。

### 解决
```bash
sudo passwd -u root   # 解锁 root 账户
```
脚本 Step 0 已加入自动检测和解锁。

---

## 问题 6: cephadm 私钥不在标准路径

### 现象
手动 `sudo ssh root@localhost` 返回 `Permission denied`，即使 `authorized_keys` 里有正确的公钥。

### 原因
cephadm bootstrap 生成的 SSH 密钥对（`ceph.pub` + 私钥）存储方式特殊：
- **公钥**: `/etc/ceph/ceph.pub`
- **私钥**: 存在于 cephadm 的 config-key 存储中（`mgr/cephadm/ssh_identity_key`），不在 `/root/.ssh/id_rsa`

所以`sudo ssh root@localhost` 不走 cephadm 的密钥，而 `/root/.ssh/` 里没有对应的私钥，认证失败。

### 解决
从集群 config-key 中提取私钥并部署到标准位置：
```bash
ceph config-key get mgr/cephadm/ssh_identity_key | sudo tee /root/.ssh/id_rsa
sudo chmod 600 /root/.ssh/id_rsa
```
**教训**: cephadm 不是通过标准的 `/root/.ssh/id_rsa` 管理密钥，而是内部 config-key store。排查 SSH 问题时要先理解密钥的实际存储路径。

---

## 问题 7: ceph orch device ls 为空 / 分区不被识别

### 现象
```
$ ceph orch device ls
（空输出）
$ ceph orch device zap ceph-node1 /dev/sda1 --force
Error EINVAL: Device path '/dev/sda1' not found on host 'ceph-node1'
```

### 原因
cephadm 的设备扫描器维护了一个缓存。在新创建的 GPT 分区上，扫描器没有触发刷新，数据库中没有任何设备记录。`orch device zap` 必须看到设备在数据库中才能操作。

### 解决
**最终方案**: 放弃分区 + `device zap` 路线，改用 `ceph orch daemon add osd` 直接传整盘。内部 ceph-volume 会自己做 LVM 划分。

**尝试过但失败的路线**:
- `ceph orch device ls --refresh` — 不生效
- `ceph orch device zap` + `ceph orch daemon add osd` — zap 失败
- `ceph-volume raw prepare --bluestore --data /dev/sda1` — bootstrap-osd keyring 不可见
- OSD service spec 指定 `method: raw` — Quincy 不支持，仍走 lvm batch

**教训**: cephadm 的 device scanner 在 Quincy 版本上不够可靠。直接走整盘 LVM 模式是最稳的选择。不要尝试绕过 orchestrator 手动调用 ceph-volume——keyring 和 ceph.conf 的挂载路径在不同部署方式下完全不同。

---

## 问题 8: MON 因根盘空间不足无法启动

### 现象
```
ceph-mon: error: monitor data filesystem reached concerning levels of
          available storage space (available: 3% 646 MiB)
systemd: Main process exited, code=exited, status=28/n/a
```
MON 容器反复创建、崩溃、被 systemd 重启、再崩溃，最终 `Start request repeated too quickly`。

### 排查
```bash
df -h /   # 看根盘剩余空间
# ceph-node2: 20G 总容量, 仅 647MB 可用 (3%)
```

MON 默认要求 `mon_data_avail_crit = 5`（5% 空闲空间）。ceph-node2 只有 3%，不满足。

### 尝试的解决路径

**1) `ceph config set mon mon_data_avail_crit 1`** — 无效
原因是 MON 进程在**启动阶段**检查空间，还没连接集群读到 config。必须写在 `ceph.conf` 里。

**2) 直接改 ceph-node2 的 `/etc/ceph/ceph.conf`** — 无效
cephadm 部署 MON 时会用自己生成的 config，不读 `/etc/ceph/ceph.conf`。

**3) 最终方案**: 从 MON quorum 中移除 ceph-node2
```bash
ceph orch daemon rm mon.ceph-node2 --force
ceph orch apply mon --placement="ceph-node1,ceph-node3"
```
2 个 MON 足够满足 Paxos 多数派。ceph-node2 继续运行 OSD 和 MGR。

### 脚本改进
Step 0 增加了自动检测：扫描每个节点的根盘空闲空间，< 2GB 的节点自动排除出 MON placement。

**教训**: 部署前应检查所有节点的根盘空间。MON 数据库会随着集群规模增长而增大，20G 根盘在生产环境是不够的。

---

## 问题 9: EC 4+2 与 3 个 OSD 不兼容

### 现象
```
pg 1.0 is creating+incomplete, acting [1,2,NONE,NONE,0,NONE]
(reducing pool default.rgw.buckets.data min_size from 5 may help)
```
PG 永远卡在 `creating+incomplete`，6 个 acting 位中有 3 个 `NONE`。

### 原因
EC 4+2 需要 6 个 OSD 来存放 6 个 chunk（4 data + 2 parity）。集群只有 3 个 OSD，CRUSH 找不到足够的位置放置所有 chunk。

### 解决
改为 EC 2+1（k=2, m=1，共 3 chunks），恰好匹配 3 个 OSD：
```
config.sh: CEPH_EC_K=2 CEPH_EC_M=1
池删除重建:
  ceph config set mon mon_allow_pool_delete true
  ceph osd pool delete default.rgw.buckets.data default.rgw.buckets.data --yes-i-really-really-mean-it
  ceph osd pool create default.rgw.buckets.data erasure ec-prod
```

### 关键约束
**EC 纠删码的硬性要求**: `OSD 数量 ≥ k + m`。部署前必须确认物理磁盘数、分区数、或 osds_per_device 参数能否满足 EC 宽度。

---

## 问题 10: RGW daemon 在 MON 故障时持续 error

### 现象
```
rgw.myrgw.ceph-node1.yestjz  ceph-node1  *:80  error
rgw.myrgw.ceph-node2.gvuuyp  ceph-node2  *:80  error
```

### 原因
RGW 依赖 MON quorum 获取集群状态和认证信息。ceph-node2 的 MON 反复崩溃，RGW 容器虽在运行但无法完成初始化。

### 解决
MON quorum 恢复后，删除旧 RGW 并重建：
```bash
ceph orch rm rgw.myrgw
ceph orch apply rgw myrgw --port=8000 --placement='ceph-node1'
```
同时改变端口为 8000（默认 80），与 JuiceFS 连接配置对齐。

---

## 总结: 部署流程中的关键检查点

| 阶段 | 检查项 | 方法 |
|------|--------|------|
| 部署前 | root 账户是否解锁 | `passwd -S root`，不应含 `L` |
| 部署前 | 各节点根盘剩余空间 | `df -h /`，MON 节点至少需要 2GB+ |
| 部署前 | apt 源是否可用 | `apt-get update` 看有没有 404/Connection refused |
| 部署前 | 时间同步是否激活 | `systemctl is-active systemd-timesyncd` 或 `chronyd` |
| 部署中 | root SSH 是否通 | `ceph orch host ls` 确认所有节点在线 |
| 部署中 | OSD 数量是否 ≥ k+m | `ceph osd stat` |
| 部署后 | 集群 HEALTH_OK | `ceph health` |
| 部署后 | RGW 端口是否正确 | `ceph orch ps --daemon-type rgw` |
