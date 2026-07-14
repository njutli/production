# 新集群 Ceph 部署调试记录

> 环境：prod-deploy 4 机集群（150-152 slave + 157 client）
> Ceph 17.2.8 (Quincy), cephadm 管理的容器化部署
> OSD 部署方式：`cephadm ceph-volume --keyring` + tmpfs DB/WAL (loop + LVM LV)

---

## 已解决的问题

### 1. `ceph-volume` 命令未安装

**现象**：deploy-ceph.sh Step 4 执行 `ceph-volume lvm create` 时报 `command not found`

**原因**：Ubuntu 22.04 的 `ceph-common` 包不含 `ceph-volume`，它在 `ceph-osd` 包里

**修复**：deploy-ceph.sh Step 1 加装 `ceph-osd` 包：
```bash
command -v ceph-volume &>/dev/null || sudo apt-get install -y ceph-osd
```

### 2. mount/truncate/losetup 缺少 sudo

**现象**：`_run` 以 sunrise 用户执行，`mount`/`truncate`/`losetup` 报 Permission denied

**原因**：deploy-ceph.sh Step 4 的 `_run` 块内部分命令缺 `sudo` 前缀（与 deploy-tikv.sh 同类问题）

**修复**：给 `mountpoint`/`mkdir`/`mount`/`truncate`/`losetup`/`pvcreate`/`vgcreate`/`lvcreate` 等命令加 `sudo`

### 3. 裸 `ceph-volume` 导致 stray daemon 警告

**现象**：OSD 以宿主机 systemd 服务运行，cephadm 报 `HEALTH_WARN: stray daemon(s) not managed by cephadm`

**原因**：脚本用 `ceph-volume lvm create`（宿主机），而非 `cephadm ceph-volume`（容器）。老集群用 `cephadm ceph-volume`，OSD 是 cephadm 管理的容器

**修复**：改为 `cephadm ceph-volume --keyring /var/lib/ceph/bootstrap-osd/ceph.keyring lvm create`

### 4. bootstrap-osd keyring 不在 cephadm 容器内

**现象**：`cephadm ceph-volume` 报 `unable to find a keyring on /var/lib/ceph/bootstrap-osd/ceph.keyring`

**原因**：cephadm bootstrap 把 keyring 存在 `/var/lib/ceph/<fsid>/` 而非传统的 `/var/lib/ceph/bootstrap-osd/`。`cephadm ceph-volume` 容器只挂载 `<fsid>/crash`，不挂载 `bootstrap-osd/`

**修复**：deploy-ceph.sh 新增 Step 3b，从 Ceph auth DB 提取 keyring 放到 `/var/lib/ceph/bootstrap-osd/ceph.keyring`，通过 `--keyring` 参数传给 `cephadm ceph-volume`

### 5. loop 设备无 PARTUUID

**现象**：`cephadm ceph-volume` 报 `blkid could not detect a PARTUUID for device: /dev/loopN`

**原因**：裸 loop 设备没有分区表，`ceph-volume` 要求 `--block.db`/`--block.wal` 设备有 PARTUUID

**修复**：在 loop 设备上建 LVM LV（PV → VG → LV），用 LV 路径代替裸 loop 设备。LVM LV 有自己的 UUID，无需 PARTUUID。这与老集群做法一致

### 6. ceph-osd --mkfs 报 Permission denied

**现象**：`ceph-osd --mkfs` 在 cephadm 容器内报 `block.db open got: (13) Permission denied`

**原因**：
- 宿主机 `ceph` 用户 UID=64045，容器内 `ceph` 用户 UID=167（老集群两者都是 167）
- `ceph-volume` 只 `chown -h` 符号链接，实际设备 `/dev/dm-N` 仍是 `root:disk` (660)
- `ceph-osd` 以 `--setuser ceph --setgroup ceph`（UID 167）运行后，无 `disk` 组权限，打不开设备

**修复**：在所有 slave 节点添加 udev 规则 `/etc/udev/rules.d/99-dm-permissions.rules`：
```
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="dm-*", MODE="0666"
```
应纳入 `prepare-servers.sh` slave 角色中

---

## 已解决的问题（续）

### 7. OSD 创建后被 zap（回滚）

**现象**：`cephadm ceph-volume` 输出 `ceph-volume lvm prepare successful`，但紧接着 LV 被删除、OSD 被 zap，最终报 `RuntimeError`

**根因**：`cephadm ceph-volume` 只是在容器里跑 ceph-volume 命令，产生的 OSD 是宿主机 systemd 服务（`ceph-osd@0`），不是 cephadm 容器。宿主机 ceph.conf 缺少 `public_network`，OSD 找不到网络接口，连不上 MON，`systemctl start ceph-osd@0` 失败，ceph-volume 触发 zap 回滚。

**核心认知**：`cephadm ceph-volume` ≠ 用 cephadm 管理 OSD。它只是在容器里执行 ceph-volume 命令，产生的 OSD 是宿主机进程。这与老集群不一致（老集群用 `ceph orch daemon add osd`，OSD 是 cephadm 容器）。

**修复**：改用 `ceph orch daemon add osd` 部署 OSD，通过 `data_devices`/`db_devices`/`wal_devices` 参数指定 DATA/DB/WAL 的 LV 路径。`ceph orch` 内部调用 cephadm 创建容器化 OSD，HEALTH_OK 无 stray daemon。

```bash
ceph orch daemon add osd ceph-node1:data_devices=/dev/ceph-vg-osd1/osd,db_devices=/dev/ceph-vg-db1/osd-db,wal_devices=/dev/ceph-vg-wal1/osd-wal
```

Ceph 文档确认 `ceph orch` 支持此语法：https://docs.ceph.com/en/quincy/cephadm/services/osd/

### 8. Step 5 EC pool 创建失败（OSD 未稳定）

**现象**：deploy-ceph.sh Step 5 在 OSD 刚部署后立即创建 EC pool，pool 创建失败

**根因**：OSD 刚启动还未完全注册到 MON，pool 创建时 MON 找不到足够的 OSD

**修复**：手动补建 pool 即可成功。脚本中 Step 4 和 Step 5 之间应增加等待时间或重试逻辑（待优化）

### 9. MON 绑定在管理网，cluster_network 未生效

**现象**：
- MON 在 10.20.1.x（管理网 eno12399），OSD 在 10.3.1.x（100GbE public）
- `cluster_network` 未在 mon 级别设置，OSD 的 cluster 地址也绑在 public 网段
- EC 取片/recovery 流量与客户端流量挤在同一块 100GbE 网卡上
- `limit-bandwidth.sh` 切网段时 MON 不迁移（IP 在 monmap 里固死），导致 HEALTH_ERR

**根因**：
1. `config.sh` 的 `CEPH_PRIMARY=10.20.1.150`（管理网 IP），deploy-ceph.sh Step 2 用 `--mon-ip ${CEPH_PRIMARY}` bootstrap，导致 MON 绑在管理网
2. Step 2b 只设 `global` 级别的 `public_network`/`cluster_network`，但 cephadm bootstrap 会自动设 `mon` 级别的 `public_network`（= MON IP 所在网段），`mon` 级别覆盖 `global` 级别
3. `limit-bandwidth.sh` 也只改 `global` 级别，无法覆盖 `mon` 级别的固化值

**修复**（体现在部署脚本中，不绕过脚本改环境）：
1. `config.sh`：新增 `CEPH_MON_IPS` 映射表（管理网 IP → 100GbE IP），新增 `CEPH_PRIMARY_MON_IP` 变量
2. `deploy-ceph.sh` Step 2：`--mon-ip ${CEPH_PRIMARY_MON_IP}`（用 100GbE IP bootstrap）
3. `deploy-ceph.sh` Step 2b：显式设 `mon` 级别 `public_network`/`cluster_network`，覆盖 bootstrap 的默认值
4. `limit-bandwidth.sh` apply/remove：都设 `mon` 级别；remove 时用 `CEPH_MON_IPS` 恢复 MON IP 到 100GbE 网段

---

## 最终方案

deploy-ceph.sh Step 4 改为：
1. 在宿主机准备 DATA/DB/WAL 三个 LV（NVMe → LV for DATA，tmpfs → loop → LV for DB/WAL）
2. 用 `ceph orch daemon add osd hostname:data_devices=<data_lv>,db_devices=<db_lv>,wal_devices=<wal_lv>` 一步部署
3. OSD 由 cephadm 容器管理，DB/WAL 在 tmpfs 上，HEALTH_OK

prepare-servers.sh slave 角色加 udev 规则（device mapper 设备权限）：
```
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="dm-*", MODE="0666"
```

## 验证结果

- 6 OSD 全部 UP（cephadm 容器，非宿主机进程）
- HEALTH_OK（无 stray daemon）
- block.db / block.wal 在 tmpfs LV 上
- block (DATA) 在 NVMe LV 上
- test-ceph.sh 7/7 PASS

---

## 调试环境清理

调试过程中在 150-152 上产生了大量孤儿 loop 设备（指向已删除的 tmpfs 文件），需清理：
```bash
# 每台 slave 上执行
for lo in $(losetup -a | awk -F: '{print $1}'); do losetup -d $lo 2>/dev/null; done
```
