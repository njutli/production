# Ceph 密钥详解（CephX keyring + cephadm SSH 密钥）

> 适用集群：本工程 3 节点 cephadm + podman 部署（Ceph 17.2.8 Quincy）。
> 写作动机：node1 重装后重新纳管时，常混淆"为什么只配 SSH 公钥、不配 keyring"。
> 本文讲清 Ceph 里**两套完全不同的密钥**：用途、格式、部署时机、谁自动谁手动。

---

## 一、先记住：Ceph 有两套独立的密钥

很多人把它们混为一谈，其实机制完全不同：

| | **CephX keyring** | **cephadm SSH 密钥** |
|---|---|---|
| 解决什么 | **数据面认证**：组件之间互信（谁能读写集群） | **管理面登录**：cephadm 怎么 SSH 进主机干活 |
| 形态 | Ceph 自有格式（entity + key + caps） | 普通的 SSH 密钥对（id_rsa / authorized_keys） |
| 协议 | Ceph messenger（v2:3300 / v1:6789 等） | SSH（22 端口） |
| 存放 | `/etc/ceph/*.keyring`、容器内 `/var/lib/ceph/...` | 私钥在集群 config-key；公钥在各主机 `/root/.ssh/authorized_keys` |
| 谁管理 | cephadm + MON 自动管理 | cephadm 生成，公钥需分发到主机 root |

> 一句话：**CephX 管"谁能访问集群数据"，SSH 密钥管"cephadm 怎么登进主机部署容器"。**

---

## 二、第一套：CephX keyring（数据面认证）

### 2.1 它是什么

CephX 是 Ceph 内置的认证系统（类 Kerberos 的共享密钥机制）。集群里**每一个身份**
（entity）都有一个 keyring，包含三部分：

```
osd.0
    key: AQDxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx==   # 共享密钥（base64）
    caps: [mon] allow profile osd                       # 能力(capability)：对 mon 的权限
    caps: [osd] allow *                                 # 对 osd 的权限
    caps: [mgr] allow profile osd                       # 对 mgr 的权限
```

- **entity 名**：`<type>.<id>`，如 `osd.0`、`mon.ceph-node2`、`mgr.ceph-node2.xxx`、
  `client.admin`、`client.bootstrap-osd`。
- **key**：共享密钥，双方用它互相认证。
- **caps**：该身份对各子系统（mon/osd/mgr/mds）的权限范围。

### 2.2 集群里典型的 entity 分类

用 `ceph auth ls` 可以列全部。本工程里大致有：

| entity | 作用 | 谁在用 |
|--------|------|--------|
| `client.admin` | **最高权限**，管理员执行 `ceph` 命令的凭证（mon/osd/mgr/mds 全 `allow *`） | 你 / 部署脚本 |
| `mon.` | MON 守护进程身份 | 每个 MON 容器 |
| `osd.0` … `osd.5` | 每个 OSD 的身份（`allow profile osd`） | 每个 OSD 容器 |
| `mgr.<host>.xxx` | MGR 守护进程身份 | active/standby MGR |
| `client.bootstrap-osd` 等 | 部署阶段创建对应守护进程用的"引导"凭证 | cephadm/ceph-volume |
| `client.rgw.*` | RGW 守护进程身份 | RGW 容器 |
| `client.juicefs`（S3 用户） | 这是 **RGW 的 S3 用户**，不是 CephX，见 2.5 | JuiceFS |

### 2.3 keyring 又分两小类（部署时机不同——重点）

#### (a) 守护进程自己的 keyring（MON/OSD/MGR/RGW）

- **由 cephadm 在部署该守护进程时自动生成并注入容器**，放在容器内
  `/var/lib/ceph/<fsid>/<daemon>/keyring`。
- 全程**不需要人工干预**。`ceph orch daemon add osd ...` 部署 OSD 时，
  ceph-volume 会向 MON 申请创建 `osd.N` 的 auth 条目并写入对应 keyring。
- 删除守护进程（如 `ceph osd purge osd.0`）会**连带删除它的 auth 条目**。

#### (b) admin client keyring（`ceph.client.admin.keyring`）

- 在 **`cephadm bootstrap` 时生成**，是 `client.admin` 这个 entity 的 keyring。
- 配合 `ceph.conf` 一起，构成"在这台机器上能跑 `ceph` 命令"的凭证。
- **分发方式：`_admin` 标签自动分发**。凡是带 `_admin` 标签的主机，cephadm 会
  自动把 `/etc/ceph/ceph.conf` + `/etc/ceph/ceph.client.admin.keyring` 推过去。
  本工程三台 Ceph 节点都打了 `_admin`，所以都能直接 `sudo ceph -s`。

```bash
# 查看哪些主机带 _admin（会自动收到 admin keyring）
ceph orch host ls
# 查看 admin keyring 内容
sudo cat /etc/ceph/ceph.client.admin.keyring
```

### 2.4 常用 CephX 命令

```bash
ceph auth ls                       # 列出所有 entity 及其 key/caps
ceph auth get client.admin         # 查看某个 entity
ceph auth get-or-create osd.9 \    # 手动创建（一般不用，cephadm 会做）
    mon 'allow profile osd' osd 'allow *' mgr 'allow profile osd'
ceph auth caps <entity> ...        # 修改权限
ceph auth del osd.9                # 删除（osd purge 已包含此步）
ceph auth export > all.keyring     # 备份所有 keyring
```

### 2.5 ⚠️ 别和 RGW 的 S3 凭证搞混

`client.juicefs` 在 `radosgw-admin user info` 里看到的 **access_key/secret_key**
是 **RGW 层的 S3 用户凭证**（给 JuiceFS 走 S3 协议用），保存在
`.credentials/rgw-juicefs.env`。它**不是 CephX keyring**，是另一套东西：

| | CephX keyring | RGW S3 凭证 |
|---|---|---|
| 协议层 | Ceph 原生 messenger | S3 / HTTP |
| 创建 | `ceph auth ...` | `radosgw-admin user create ...` |
| 使用者 | Ceph 内部组件、`ceph` 命令 | S3 客户端（JuiceFS、aws cli） |

---

## 三、第二套：cephadm SSH 密钥（管理面登录）

### 3.1 它是什么 / 为什么需要

cephadm（运行在 **active MGR** 内）管理集群的方式，就是**以 root 身份 SSH 登录到
每台主机**，再调用 podman/systemd 去部署/删除容器、抹盘、采集状态。它用的是一对
**普通 SSH 密钥**：

```
active MGR (cephadm)                                  各主机
  ├─ 私钥：存在集群 config-key 里
  │   key = mgr/cephadm/ssh_identity_key
  │                                          ──SSH root──►  /root/.ssh/authorized_keys
  └─ ceph cephadm get-pub-key 可导出公钥                      ↑ 装的就是这个公钥
```

- **私钥**：不落地在 `/root/.ssh`，而是存在集群配置里（`ceph config-key`）。
- **公钥**：必须装到**每台被管理主机的 `/root/.ssh/authorized_keys`**。
- 登录用户是 **root**（要管 systemd/podman/抹盘等高权限操作，不走 sudo）。

### 3.2 为什么放在 SSH 目录、且是 root 的

- 它**就是一个 SSH 公钥**，sshd 只认 `~/.ssh/authorized_keys`，放别处无效。
- cephadm 默认用 root 登录，所以放 **root 的** authorized_keys，不是 turboai 的。
- 还需 sshd 允许 root 登录（`PermitRootLogin yes`）——**两个条件缺一不可**：
  1. `/root/.ssh/authorized_keys` 里有 cephadm 公钥；
  2. sshd 允许 root 用 publickey 登录。
  少任何一个，`ceph orch host ls` 里该主机就是 `Offline` / `1 hosts fail cephadm check`。

### 3.3 常用命令

```bash
ceph cephadm get-pub-key                       # 导出 cephadm 的 SSH 公钥
ceph config-key get mgr/cephadm/ssh_identity_key   # 导出私钥（极少用）
ceph cephadm get-user                          # 查看 cephadm SSH 登录用的用户（默认 root）
ceph orch host ls                              # 看各主机 STATUS（Offline = SSH 不通）
```

### 3.4 与 turboai 免密的区别

本工程里其实有**两条 SSH 通道**，别搞混：

| 通道 | 登录用户 | 公钥放哪 | 谁用 |
|------|---------|---------|------|
| 部署/运维通道 | `turboai` | `~turboai/.ssh/authorized_keys` | 你 / 部署脚本（`ssh-copy-id` 配的） |
| cephadm 管理通道 | `root` | `/root/.ssh/authorized_keys` | active MGR 自动管理集群 |

---

## 四、放到一起看：node1 重装后各密钥怎么恢复

这正是 `perf-analysis/03-env-change-2026-06.md` 里 node1 纳管步骤背后的密钥逻辑：

| 密钥 | node1 重装后状态 | 怎么恢复 | 要手动吗 |
|------|-----------------|---------|---------|
| 守护进程 keyring（MON/OSD/RGW） | 随旧系统一起没了 | cephadm 重建 MON/OSD/RGW 时**自动生成新的** | ❌ 自动 |
| 旧 osd.0/osd.1 的 auth 条目 | 仍残留在集群里（孤儿） | `ceph osd purge` 时**连带删除** | ✅ 执行 purge |
| admin keyring + ceph.conf | `/etc/ceph/` 被清空 | node1 仍带 `_admin` 标签，纳管恢复后**自动推回** | ❌ 自动（纳管成功后） |
| **cephadm SSH 公钥** | `/root/.ssh/authorized_keys` 被清空 | **必须手动**把 `ceph cephadm get-pub-key` 装回 node1 的 root | ✅ **唯一要手动的密钥** |

> 结论：node1 纳管步骤里**唯一需要手动处理的密钥就是 cephadm 的 SSH 公钥**
> （03 文档步骤 2）。其余 CephX 密钥全由 cephadm/`_admin` 标签自动恢复——
> 这就是为什么纳管步骤里只配 SSH 公钥、不手动配任何 keyring。

---

## 五、速查

```bash
# —— CephX（数据面）——
ceph auth ls                         # 所有 entity + key + caps
ceph auth get client.admin           # admin 凭证
sudo cat /etc/ceph/ceph.client.admin.keyring

# —— cephadm SSH（管理面）——
ceph cephadm get-pub-key             # cephadm 公钥（装到主机 root）
ceph orch host ls                    # 主机 SSH 连通性（Offline = 通道断）

# —— RGW S3 用户（应用面，非 CephX）——
sudo radosgw-admin user info --uid=juicefs
```
