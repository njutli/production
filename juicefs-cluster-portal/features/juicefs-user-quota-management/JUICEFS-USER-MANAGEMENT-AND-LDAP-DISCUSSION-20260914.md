# JuiceFS 用户管理与 LDAP 讨论记录

> 日期：2026-09-14  
> 状态：讨论记录，尚未形成实施方案  
> 当前集群：150～152为Ceph、TiKV/PD存储节点，152同时部署管理门户，157为业务客户端和JuiceFS挂载节点

## 一、需要区分的三类身份

当前方案不能把“用户”笼统地视为同一种对象，应区分：

| 身份 | 作用 | 示例 |
|---|---|---|
| Linux/LDAP数据用户 | 决定文件访问时的UID/GID | `alice -> 10001:10001` |
| Portal用户 | 决定能在网页中查看或管理什么 | `ADMIN`、`USER` |
| 存储组件身份 | JuiceFS挂载、quota-controller连接TiKV/Ceph所用的服务身份 | `jfsportal`、TiKV TLS证书、CephX key |

三者可以建立关联，但不应合并成同一套凭据。Portal ADMIN不必是Linux root，LDAP用户也不必拥有Portal账号。

## 二、JuiceFS如何识别用户

JuiceFS的POSIX权限判断基于数字UID/GID，不是用户名。目录元数据例如：

```text
/users/alice
owner UID = 10001
owner GID = 10001
mode      = 0700
```

客户端进程访问该目录时，Linux VFS/FUSE将进程的数字UID、GID和附加组传给JuiceFS。只要请求进程的UID是`10001`，JuiceFS就把它视为目录所有者，不会判断这个UID在本机显示为`alice`还是其他名字。

因此，若客户端A的alice和客户端B的bob都使用UID 10001：

- alice和bob都会被视为目录所有者；
- `0700`和POSIX ACL无法区分二者；
- 基于UID的配额会把二者统计为同一个用户；
- 用户隔离失效。

所有访问同一JuiceFS的客户端必须采用一致且不冲突的UID/GID分配。

## 三、本地用户和LDAP用户的区别

### 3.1 本地用户

本地用户通过类似命令在某一台客户端创建：

```bash
useradd -u 10002 bob
```

身份信息分别保存在本机：

```text
/etc/passwd
/etc/shadow
/etc/group
```

其他客户端不会自动知道该用户。要让同一个用户在多台客户端保持一致，管理员必须在每台机器上显式创建相同用户名、UID、GID和用户组。

### 3.2 LDAP用户

LDAP用户在中央目录服务中创建一次，例如：

```text
uid: alice
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/alice
loginShell: /bin/bash
memberOf: jfs-users
```

接入LDAP的Linux客户端通过SSSD查询这条记录，不需要再在每台机器执行`useradd alice`。客户端本地的`/etc/passwd`中通常没有alice，但Linux统一用户查询仍能看到：

```bash
getent passwd alice
id alice
```

预期所有客户端均返回同一个`10001:10001`。

### 3.3 对比

| 项目 | 本地用户 | LDAP用户 |
|---|---|---|
| 创建位置 | 每台客户端分别创建 | LDAP中创建一次 |
| 身份保存位置 | 本机`/etc/passwd`等文件 | LDAP目录数据库 |
| 密码验证 | 本机`/etc/shadow` | LDAP认证服务 |
| Linux查询路径 | NSS `files` | NSS `sss` -> SSSD -> LDAP |
| 多客户端一致性 | 依赖人工控制 | 共同查询同一权威记录 |
| 禁用或改组 | 每台机器分别操作 | LDAP集中操作 |
| LDAP断开时 | 不受影响 | 新登录依赖SSSD缓存策略 |
| Home/数据目录 | `useradd`可选创建本地Home | 需要PAM或管理员/provisioner另行创建 |
| 登录后的内核身份 | 数字UID/GID | 数字UID/GID |

用户登录完成后，Linux内核和JuiceFS不再区分其身份来自本地文件还是LDAP；两者都会变成进程上的数字UID/GID。

## 四、LDAP在Linux客户端中的工作方式

客户端可配置：

```text
/etc/nsswitch.conf

passwd: files sss
group:  files sss
```

用户查询流程：

```text
程序查询alice
  -> NSS
  -> 先查本机files
  -> 未找到后查SSSD
  -> SSSD查询本地缓存
  -> 缓存缺失或过期时访问LDAP
  -> 返回alice的UID/GID和组信息
```

用户登录流程：

```text
alice电脑
  -> SSH到157
  -> sshd/PAM
  -> 157上的SSSD
  -> LDAP验证密码和登录权限
  -> Linux以UID 10001、GID 10001启动alice进程
```

SSSD会缓存身份数据；LDAP不会在每次系统调用或每次文件读写时被访问。

## 五、结合当前集群的讨论部署形态

如果没有现成企业LDAP/AD，在现有机器资源约束下可以讨论如下形态：

```text
150：OpenLDAP主节点，保存权威用户目录
151：OpenLDAP副本，提供查询和故障切换
152：Portal、用户管理控制器、quota-controller
157：业务客户端、JuiceFS挂载、SSSD
未来客户端：JuiceFS挂载、SSSD
```

此处只是讨论口径，并非已经批准的部署计划。若公司已有LDAP或AD，应优先接入现有身份源。

`ceph`、`tikv`、`jfsportal`、`root`等系统和服务账号继续保留为本地账号，避免集群服务启动依赖LDAP。LDAP主要管理需要跨客户端访问JuiceFS的普通业务用户。

## 六、用户开户请求链

目标自动化流程可描述为：

```text
管理员浏览器
  -> HTTPS请求到Portal（152）
  -> Portal验证ADMIN角色
  -> 用户管理控制器（152）分配全局唯一UID/GID
  -> 通过LDAPS写入LDAP主节点（150）
  -> LDAP-150复制到LDAP-151
```

LDAP中创建用户后，157及其他接入SSSD的客户端无需创建同名本地账号，即可通过`getent`识别用户。

UID/GID分配器在写入前必须检查：

- 用户名未被使用；
- UID未被本地账号或LDAP账号使用；
- GID未被本地组或LDAP组使用；
- 用户目录未绑定给其他身份。

## 七、JuiceFS目录创建请求链

LDAP只创建身份，不自动创建`/home/alice`或`/mnt/juicefs/users/alice`。目录必须由管理员或受控provisioner创建。

初期可由157上的root执行：

```bash
mkdir /mnt/juicefs/users/alice
chown 10001:10001 /mnt/juicefs/users/alice
chmod 0700 /mnt/juicefs/users/alice
```

请求流向：

```text
157上的管理员进程
  -> Linux VFS/FUSE
  -> 157上的JuiceFS挂载进程
  -> TiKV/PD（150～152）保存目录、所有者和权限元数据
```

未来若由Portal自动开户，应使用独立且受控的写管理入口，不复用152现有的只读统计挂载。

`/users`顶层目录应由root所有，普通用户不能在其中创建、删除或重命名一级用户目录。

## 八、用户访问文件时的请求链

alice登录157并访问文件：

```text
alice进程（UID 10001）
  -> 157 Linux VFS/FUSE
  -> 157 JuiceFS挂载进程
  -> TiKV/PD（150～152）：元数据和权限检查
  -> Ceph OSD（150～152）：实际文件数据读写
```

LDAP不参与上述文件I/O链路。即使LDAP短暂不可用：

- 已登录用户的进程仍持有数字UID/GID；
- 已有JuiceFS挂载和文件I/O继续工作；
- JuiceFS配额继续由客户端和TiKV执行；
- 新登录是否成功取决于SSSD缓存策略；
- 新开户、密码修改和未缓存用户登录需要LDAP恢复。

## 九、本地UID冲突的处理原则

若客户端B已有：

```text
本地bob -> UID 10001
LDAP alice -> UID 10001
```

LDAP不会自动修复冲突。`passwd: files sss`的查询顺序也只能决定先返回哪条名称记录，不能消除两个用户共享数字UID的事实。

接入LDAP前必须：

1. 盘点每台客户端的本地用户和组；
2. 为LDAP业务用户预留独立UID/GID范围；
3. 将冲突的本地用户迁移到新ID；
4. 在精确限定的数据范围内迁移已有文件所有权；
5. 验证无残留后再允许LDAP用户登录。

禁止对系统根目录或不受控路径进行全局递归`chown`。

## 十、Portal用户的两种选择

### 10.1 Portal账号保持独立

```text
LDAP：Linux/文件用户
Portal本地账号：网页用户
Portal映射：portal_user_id -> LDAP uid -> UID/GID -> JuiceFS目录
```

该方式对当前Portal改动较小，适合作为第一阶段。

### 10.2 Portal也使用LDAP认证

```text
jfs-portal-admins LDAP组 -> Portal ADMIN
jfs-portal-users LDAP组  -> Portal USER
```

该方式可以统一账号和密码，但需要增加LDAP登录、组到角色映射、失效与故障策略等安全验收。可以在Linux身份与配额流程稳定后再考虑。

## 十一、LDAP不能解决的问题

LDAP解决的是用户身份集中管理和UID/GID一致性，不能单独解决：

- 普通用户绕过Portal直接运行`juicefs quota`；
- TiKV当前连接缺少管理级RBAC；
- 客户端root冒充任意UID；
- 不可信客户端上的强多租户隔离。

完整安全边界仍需包括：

```text
LDAP/统一UID注册表
  -> 保证跨客户端身份一致

Portal RBAC + quota-controller
  -> 限定谁能设置哪些目录的配额

TiKV TLS、凭据保护和进程级网络隔离
  -> 防止绕过Portal直接访问元数据引擎
```

若用户拥有客户端root权限，LDAP和目录`0700`均不能阻止其切换为其他UID。此类环境需要受控NFSv4/Kerberos、SMB/AD网关或独立卷等更强的服务端身份边界。

## 十二、当前讨论结论

1. LDAP用户通常不写入各客户端的`/etc/passwd`，但通过SSSD/NSS仍是Linux认可的真实用户；
2. LDAP用户和本地用户登录后都会变成数字UID/GID，JuiceFS不区分身份来源；
3. LDAP中创建一次用户即可供所有已接入客户端查询，无需逐机`useradd`；
4. LDAP无法容忍本地UID/GID冲突，接入前必须盘点和迁移；
5. LDAP只负责人的身份，不参与每次JuiceFS文件I/O，也不替代配额控制面和TiKV安全隔离；
6. 当前更适合先保持Portal账号独立，再评估是否与LDAP统一认证；
7. 本文只记录讨论结果，具体服务器、软件、端口、证书、备份和回滚设计应在后续实施方案中冻结。
