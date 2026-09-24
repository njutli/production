# 用户管理与配额管理方案调研

> 调研起始日期：2026-09-14；第十一节方案更新：2026-09-22。
> 范围：当前JuiceFS + TiKV + Ceph架构，以及Weka、有方数据和公开资料较完整的商用/开源分布式文件系统
> 目的：为现有 JuiceFS + TiKV + Ceph 管理门户增加用户目录和配额管理能力提供设计依据

跨客户端UID/GID冲突的专项分析见[用户ID映射子调研](USER-ID-MAPPING-SUBRESEARCH-20260920.md)：详细区分LDAP/AD身份统一、Linux idmapped mount、受控user namespace及其他候选，并说明当前JuiceFS版本的限制。该调研不包含环境变更或实测验收。

会议已确定本期采用路线A：业务用户统一通过LDAP管理，不处理已有业务账号迁移或客户端ID映射。配额功能的开发范围、实施步骤与验收见[配额管理功能开发计划](JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)。[名称自动映射计划（B）](../juicefs-user-id-mapping/JUICEFS-NAME-AUTO-MAPPING-DEVELOPMENT-PLAN-20260922.md)与[显式映射计划（C）](../juicefs-user-id-mapping/JUICEFS-USER-ID-MAPPING-DEVELOPMENT-PLAN-20260921.md)保留为历史备选，只有后续需要兼容已有账号时再评估，不属于本期开发或验收依赖。

路线A的具体注意事项、待确认配置及后续讨论统一维护在[LDAP统一用户管理实施与注意事项](JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md)。暂不开发客户端助手。LDAP原生接入无需自研映射；未来Portal若直接开户、停用和改组，仍需另行开发受限管理接口，不等同于当前计划中的只读身份登记。

**现有Portal平台简介**

前期已自研JuiceFS集群管理门户（Portal），完成基础开发、真实集群接入和阶段验收，中央服务部署在152节点。平台将原先分散在JuiceFS、PD/TiKV、Ceph及各主机上的状态汇总到网页，便于集中查看集群运行情况和排查问题。

已实现的功能包括集群健康与组件拓扑、容量用量、节点及磁盘状态、客户端状态、实时读写带宽及历史曲线，以及三级目录用量统计。平台支持HTTPS登录和ADMIN/USER角色区分：管理员查看全部管理信息，普通账号按绑定范围查看目录用量；目录明细采用top 100加其余项聚合，不是完整文件浏览器。

当前平台是**只读查询门户**，不参与业务文件I/O，尚不提供配额设置、Linux用户创建或集群配置修改。本次调研旨在已有平台上拟定用户目录与配额管理扩展，**扩展方案仍为暂定，未定稿或开发部署**。现有能力及验收依据见[阶段系统功能说明](../../../01-readonly-monitoring/CURRENT-STAGE-SYSTEM-OVERVIEW-20260914.md)和[部署验收摘要](../../../01-readonly-monitoring/inventory/CURRENT-DEPLOYMENT-ACCEPTANCE-SUMMARY-20260914.md)；多用户扩展前仍需补齐第十一节列出的权限与安全边界。

## 一、结论摘要

成熟存储系统通常把以下三类身份或对象分开管理：

1. **管理面账号**：用于登录 GUI、CLI 或 API，通过 RBAC 区分集群管理员、租户管理员、只读用户和普通用户；
2. **数据面身份**：用于访问文件，POSIX 场景通常是数字 UID/GID，SMB 场景通常是 AD SID；
3. **配额对象**：可以是组织、文件系统、目录、用户、组、项目、qtree 或 fileset。

比较时应分别核对管理操作权限、客户端接入条件、文件身份和配额统计边界。跨客户端的POSIX访问最终需要一致的有效数字身份，可通过统一UID/GID或产品支持的身份映射实现；配额修改权限和超限执行的安全边界则需按产品分别判断。

对当前项目最重要的结论是：

- Weka 通过管理用户、Token 和 RBAC 将普通挂载用户与配额管理员分离；
- CephFS 进一步把普通 `rw` 与设置布局/配额所需的 `p` capability 分离；
- BeeGFS、IBM Storage Scale 等方案都明确要求跨节点保持 UID/GID 一致；Storage Scale还把客户端节点准入与文件用户身份分开，且其GUI和原生管理API使用不同的管理账号与授权配置；
- JuiceFS 1.4.1同时具备文件系统、目录、UID和GID硬配额，其中目录配额与本项目“一名用户一个专属目录”的需求直接匹配；
- JuiceFS社区版的`juicefs quota`直接连接元数据引擎，当前没有与Weka等价的服务端配额RBAC。

各方案的“对本项目的借鉴”是基于各节产品机制和官方资料形成的设计建议，具体实施方案汇总在第十一节；这些建议不表示当前Portal或JuiceFS社区版已经具备相应能力。

## 二、Weka

> - **用户管理：** 一个Weka管理员预先创建逻辑文件系统和Regular用户；Regular用户登录取得Token，客户端root/systemd使用Token完成挂载。多台客户端挂载同一文件系统后看到同一命名空间，同一Linux用户必须在各客户端保持相同UID、主GID和附加组，才能持续以同一身份访问文件。
> - **配额管理：** 同一个Weka管理员对用户或项目专属目录设置目录配额，Linux用户只受POSIX权限和目录配额约束，不参与配额修改。

**示例：Alice从两台客户端使用Weka**

1. 创建集群时，Weka自动生成首个Cluster Admin `admin`，首次登录后修改初始密码；
2. `admin`创建逻辑文件系统`project1`，再创建用于挂载的Regular用户`project1-mounter`；
3. Linux管理员或LDAP在客户端A、B上建立同一个`alice=10001:10001`，这与Weka Regular用户是两套身份；
4. `project1-mounter`在客户端取得Token，客户端root/systemd分别把`project1`挂到`/mnt/project1`；
5. Alice从任一客户端读写时都以UID 10001访问同一命名空间，Weka管理员再为`/users/alice`设置目录配额。

### 2.1 用户与角色

Weka 中需要区分两套彼此独立的身份：

1. **Weka 管理身份**：登录 Weka GUI、CLI 或 API，决定能否管理集群、创建文件系统、设置配额或取得挂载认证；
2. **Linux/POSIX 数据身份**：挂载完成后，由发起文件操作的进程携带数字 UID/GID，决定能否访问具体文件和目录。

Weka 内置管理用户体系，并支持本地账号、LDAP 和 Active Directory。管理员也是 Weka 管理用户的一种角色；一个集群可以有多个 Cluster Admin 或 Organization Admin，并非只能保留一个全局管理员。

创建Weka集群时，系统会自动生成默认内部用户`admin`，角色为Cluster Admin；初始密码可在建集群时指定，并应在首次登录时更换。后续由已认证的Cluster Admin通过`weka user add <username> clusteradmin`创建其他Cluster Admin，或将已有Weka用户的角色调整为`clusteradmin`；集群应始终保留至少一个内部Cluster Admin作为管理入口。

主要角色包括：

| 角色 | 主要权限 |
|---|---|
| Cluster Admin | 集群、硬件、用户、配置和性能等全局管理 |
| Organization Admin | 管理所属组织内的文件系统、用户和配额 |
| Read-only | 通过 GUI、CLI、API 查看信息但不能修改配置 |
| Regular | 获取认证 Token 并执行挂载相关操作，不能执行一般管理命令 |
| CSI / S3 | 面向特定服务的受限角色 |

Weka CLI 登录后生成认证 Token，管理命令由集群根据账号角色授权。Regular 用户主要用于登录并取得挂载认证 Token，没有 GUI 访问和一般管理权限。该 Token 表示“这个 Weka 用户是否有资格挂载”，不等于挂载后文件操作使用的 Linux UID/GID。

需要特别说明：当前 Weka 4.4 文档中，创建本地用户时可填写的 POSIX UID/GID 是 S3 角色的可选属性，不能据此认为普通 Regular 用户会自动映射为同名 Linux 用户。Weka 管理用户与 Linux 用户可以同名，但两者仍是分别创建、分别认证的身份。

官方依据：

- [Weka User management](https://docs.weka.io/4.4/operation-guide/user-management)
- [Weka Manage users using the CLI](https://docs.weka.io/operation-guide/user-management/user-management-1)
- [Weka LDAP/AD integration](https://docs.weka.io/4.4/operation-guide/user-management/user-management)

### 2.2 文件系统创建与挂载流程

在Weka中，客户端挂载的是管理员预先在Weka管理面创建的逻辑文件系统，不是由客户端在执行`mount`时临时创建的普通目录。下文沿用前述`project1`作为逻辑文件系统示例。它必须先由Cluster Admin或相应Organization Admin使用GUI或`weka fs add/create` CLI创建，并确定文件系统组、容量、所属组织以及是否要求挂载认证。Regular用户只能挂载已创建且获授权的文件系统，不能通过`mount`创建新文件系统。

完整流程是：

```text
Weka管理员
  ├── 创建逻辑文件系统project1并配置容量、组织和挂载认证策略
  └── 创建Regular用户project1-mounter
                │
                ├── Root organization
                │     ├── auth-required=no：无需Weka用户登录和Token
                │     └── auth-required=yes：授权Weka用户登录并取得Token
                │
                └── 非Root organization：始终要求授权Weka用户登录并取得该organization的Token
                                      │
Linux root/sudo/systemd/autofs挂载project1
                │
本地挂载点/mnt/project1
                │
Linux进程以自身UID/GID访问文件
```

Regular 角色提供 Weka 挂载认证能力，但不会赋予 Linux `mount(2)` 所需的系统权限。实际执行挂载通常仍需 root、受限 sudo、systemd 或 autofs；在受控环境中，也可以由管理员预先建立长期挂载，普通 Linux 用户直接使用该挂载点。

文件系统挂载认证先看文件系统所属的organization。`auth-required`开关**只对Root organization中的文件系统有效**：

- **Root organization，`auth-required=no`**：客户端不需要登录Weka用户，也不需要提供Token。只要客户端能够连通Weka后端、运行Weka客户端并以Linux root执行挂载，就可以直接挂载。Weka不会自动判断这台客户端是否“受信任”；若只允许指定客户端访问，必须另外使用存储网络隔离、防火墙或ACL限制客户端范围。
- **Root organization，`auth-required=yes`**：客户端必须先以获准挂载的Weka用户登录并取得Token，再由Linux root、systemd或受限sudo携带该Token执行挂载。没有有效Token的客户端即使网络可达并拥有本机root权限，也不能挂载。
- **非Root organization**：为保证租户间隔离，挂载始终需要身份认证和该organization对应的有效Token，不能通过把`auth-required`设为`no`来关闭认证。换言之，这些文件系统不由该开关决定是否认证。

`auth-required`只决定**挂载时是否验证Weka身份**，不决定挂载后的文件权限。文件系统挂载成功后，Alice等Linux用户仍以UID/GID、mode和ACL访问文件，不需要分别登录Weka。创建文件系统、管理用户和设置配额等GUI、CLI或API管理操作则属于另一类控制面认证，操作者必须登录Weka并具备相应的管理员角色。

两个客户端即使把同一个`project1`挂载到不同本地路径，看到的仍是同一套目录、文件和权限；如果挂载另一个由管理员预先创建的逻辑文件系统，则进入另一套命名空间。本地挂载路径只决定客户端从哪里进入，不决定数据属于哪个Weka文件系统。

官方依据：

- [Weka Manage filesystems using the CLI](https://docs.weka.io/4.4/weka-filesystems-and-object-stores/managing-filesystems/managing-filesystems-1)
- [Weka Mount filesystems](https://docs.weka.io/4.4/weka-filesystems-and-object-stores/mounting-filesystems)
- [Weka Run first IOs with a filesystem](https://docs.weka.io/4.4/getting-started-with-weka/performing-the-first-io)

### 2.3 配额

Weka 提供组织、文件系统和目录等层级的容量控制。目录配额支持软限制、硬限制、宽限期、默认子目录配额和嵌套配额。

Weka配额属于集群文件系统的服务端能力。CLI虽然可以通过客户端挂载路径指定目标目录，但命令只是把配额规则提交给Weka集群；初次设置时，集群侧`QUOTA_COLORING`后台任务扫描目录树并为其中的文件和目录关联quota ID，后续用量统计和硬限制由Weka集群统一维护和执行。客户端使用writecache时可能暂存少量尚未同步的数据，但同步到后端时仍必须满足集群配额。

目录配额是组织内的管理操作，官方文档明确由目标文件系统所属组织的 Organization Admin 设置。Regular 用户即使可以挂载文件系统并对目录读写，也不获得配额修改权限；Read-only 用户也不能修改。Cluster Admin 负责集群级管理，但不因此自动获得非 root organization 的数据和配额管理权。

执行配额命令同时有两道条件：

1. **Weka 管理面认证与授权**：CLI 使用登录后获得的 Token 识别 Weka 用户和角色，集群判断该身份是否可以管理目标组织的配额；
2. **POSIX 路径访问**：使用挂载路径设置配额时，运行命令的 Linux 用户还必须能访问目标目录；Weka 管理员身份不会自动绕过 POSIX 权限。若该 Linux 用户无法访问挂载目录，Weka 4.4 可使用 `--filesystem` 指定文件系统，并传入相对于文件系统根的目录路径。

一个完整的 CLI 认证和设置示例如下：

```bash
# 登录成功后把 Token 写入独立文件；密码应交互输入或由密钥系统注入
weka user login quota-admin --path /root/.weka/quota-admin-token.json

# 确认后续命令实际使用的 Weka 身份
WEKA_TOKEN=/root/.weka/quota-admin-token.json \
  weka user whoami

# 通过已挂载路径设置目录配额
WEKA_TOKEN=/root/.weka/quota-admin-token.json \
  weka fs quota set /mnt/project1/users/alice \
    --soft 90GiB --hard 100GiB --grace 7d --owner alice
```

`weka user login` 默认把 Token 保存到当前 Linux 用户的 `~/.weka/auth-token.json`，`--path` 可以改用独立文件，`WEKA_TOKEN` 用于指定某条命令使用哪个 Token。因此同一客户端可以同时保留多个 Weka 登录身份：

- 不同 Linux 用户各自使用自己的 `$HOME/.weka/auth-token.json`；
- 同一 Linux 用户通过不同 Token 文件和 `WEKA_TOKEN` 在多个终端或单条命令中切换身份；
- 如果多次登录都不指定 `--path`，后一次登录会替换该 Linux 用户的默认 Token，不适合多身份并存。

Token 只决定 Weka 管理命令和挂载认证的身份，不会改变挂载点内文件读写使用的 Linux UID/GID。Weka 同时提供配额 REST API 和 GUI，两者同样必须经过管理面认证和角色授权，不应将配额修改能力暴露给 Regular 用户。

官方依据：

- [Weka Quota management](https://docs.weka.io/4.1/fs/quota-management)
- [Weka 4.4 Quota management overview](https://docs.weka.io/4.4/weka-filesystems-and-object-stores/quota-management)
- [Weka Manage quotas using the GUI](https://docs.weka.io/5.0/weka-filesystems-and-object-stores/quota-management/manage-quotas-using-the-gui)
- [Weka Manage quotas using the CLI](https://docs.weka.io/4.4/weka-filesystems-and-object-stores/quota-management/quota-management)
- [Weka Manage users and login tokens using the CLI](https://docs.weka.io/operation-guide/user-management/user-management-1)
- [Weka REST API and equivalent CLI commands](https://docs.weka.io/4.3/getting-started-with-weka/weka-rest-api-and-equivalent-cli-commands)

### 2.4 POSIX身份一致性和访问控制

一个 Weka 文件系统挂载后，不同 Linux 用户可以进入同一挂载点，具体访问权限由 Weka 元数据中保存的 owner UID、group GID、mode 和 ACL 与当前进程的数字 UID/GID共同判断。Linux 用户名只是客户端对数字ID的本地显示名称。

因此，同一个 Linux 用户从多个客户端访问时，所有客户端必须使用相同的 UID、主 GID 和附加组 GID。仅保证用户名相同不够；反过来，即使用户名不同，只要数字 UID 相同，也会被 Weka 视为同一所有者。例如客户端A的`alice=10001:10001`与客户端B的`bob=10001:10001`会发生身份碰撞，`0700`和POSIX ACL不能将两者区分。

LDAP/AD可以作为统一身份源。Linux客户端通过SSSD/NSS查询集中记录，`id alice`可以正常返回，但LDAP用户不必写入每台机器的`/etc/passwd`。

不使用LDAP时，也可以维护受控的全局UID/GID台账，并使用Ansible等配置管理工具在每台客户端显式创建相同编号的本地账号。台账本身不会被`id`识别；只有账号记录实际同步到客户端的`/etc/passwd`、`/etc/group`等NSS数据源后，`id alice`和`getent passwd alice`才会正常返回。这些同步后的账号就是普通本地Linux用户，对内核和Weka而言与LDAP用户没有区别。

无LDAP时至少需要：

1. 划定统一的业务UID/GID范围并建立唯一分配台账；
2. 新建账号前检查所有客户端的用户名、UID和GID冲突；
3. 显式同步UID、主GID、附加组、登录方式及账号停用状态；
4. 新客户端接入前完成全量身份一致性检查；
5. 定期用`getent`和`id`核验各客户端结果。

Weka 的原生 POSIX 挂载以客户端提交的数字身份为准，因此所有客户端 root 必须可信。拥有 root 权限的人可以模拟任意 UID/GID；若客户端不属于同一可信管理域，需要改用 NFSv4/Kerberos、SMB/AD 网关或独立文件系统/租户边界。

Weka 还支持组织隔离、挂载认证、NFS Kerberos、POSIX/NFSv4 ACL，以及将客户端挂载操作与管理控制面请求分离的受限端口。

官方依据：

- [Weka Security overview](https://docs.weka.io/4.4/security)
- [Weka SMB user mapping](https://docs.weka.io/4.4/additional-protocols/smb-support)
- [Weka Mount filesystems](https://docs.weka.io/4.4/weka-filesystems-and-object-stores/mounting-filesystems)
- [Weka Organizations management](https://docs.weka.io/operation-guide/organizations)

### 2.5 对本项目的借鉴

1. **分别管理门户权限、客户端接入和文件身份。** Portal的ADMIN/USER决定谁能设置配额、谁能查看用量；TiKV/Ceph凭据决定挂载进程能否接入后端；Linux UID/GID决定文件访问权限。可以参考Weka分别维护这些关系：管理员创建Linux用户和专属目录后，在Portal登记；普通用户是否注册门户账号按需决定。
2. **把配额修改权与目录写权限分开。** 建议由Portal后端检查管理员权限，通过受控`quota-controller`执行设置并记录审计。Weka由集群验证管理请求；本项目要达到同样的分权目标，还必须限制普通用户直连TiKV，单独增加Portal登录或修改JuiceFS客户端命令不能防止绕过。
3. **以专属目录作为第一期交付对象。** 采用“用户目录＋POSIX权限＋容量/inode硬配额”，在Portal提供默认限额模板和用量告警。告警阈值可以由Portal实现，但应明确它是提醒策略，不等于JuiceFS原生支持Weka的软配额和宽限期。

## 三、有方数据

目前没有可供核验的有方数据官方用户管理与配额管理技术资料，因此本报告不对其实现方式作推断。

## 四、CephFS

> - **用户管理：** 一个Ceph管理员使用`client.admin`创建CephFS，并为不同客户端或用途创建彼此独立的受限CephX身份`client.<name>`，每个身份拥有自己的secret和keyring，客户端root/systemd据此挂载。多台客户端访问同一CephFS时，各自的CephX身份控制其能挂载的范围；Linux用户则必须在各客户端保持相同UID、主GID和附加组，才能被识别为同一文件用户。
> - **配额管理：** 同一个Ceph管理员通过持有`p` capability的受控挂载为用户或项目目录设置字节数/文件数配额，普通业务挂载只保留`r`/`rw`，不能修改配额。

**示例：Alice从157和另一台客户端使用CephFS**

1. `cephadm bootstrap`创建`client.admin`及管理员keyring；
2. 管理员创建`cephfs-prod`，再创建两个独立的受限CephX身份：供157使用的`client.node157`和供另一台客户端使用的`client.node158`；两个身份各自生成独立secret并保存为各自的keyring，权限都限制为只能访问`/users`；
3. 两台客户端的root/systemd使用各自keyring挂载同一个`cephfs-prod`，本地路径可以不同；
4. Linux管理员或LDAP在两台客户端都建立`alice=10001:10001`，管理员在CephFS中创建`/users/alice`并设为该UID/GID所有；
5. Alice从两端看到同一批文件；持有`p` capability的管理挂载为该目录设置字节数和文件数配额，普通挂载不能修改。

### 4.1 用户与访问管理

从实际使用和权限执行角度，CephFS可归纳为两层身份模型：

1. **CephX集群管理与客户端挂载身份**：包括`client.admin`和各种`client.<name>`，使用keyring认证，控制集群管理权限以及客户端能否挂载、能访问哪个文件系统或目录、以只读还是读写方式访问；
2. **Linux/POSIX文件用户**：挂载完成后，由进程的数字UID/GID、文件owner/group、mode和ACL判断具体用户能否访问文件。

#### 4.1.1 第一层：CephX管理员和客户端

使用`cephadm bootstrap`初始化集群时会创建高权限CephX身份`client.admin`及其管理员keyring。它不是Linux账号或网页登录用户，而是由受信任管理进程持有的集群管理凭据；通常保存在bootstrap节点和带有`_admin`标签的管理节点上。后续可以创建权限更小的管理身份，避免所有操作共享`client.admin`。

`cephadm bootstrap`同时建立的cephadm SSH密钥不属于用户管理。它是Ceph内部的基础设施编排凭据，由Active MGR中的cephadm模块用于登录各服务节点，部署、启停和升级MON、MGR、OSD、MDS等集群组件；它不代表存储管理员或文件用户，也不应分发给管理员终端、普通客户端或业务进程。用户管理只讨论下面的CephX管理/客户端身份和Linux/POSIX文件用户。

普通客户端不需要获得管理员keyring。管理员使用`ceph fs authorize`创建受限的`client.<name>`身份，为它生成独立secret并设置MON、MDS和OSD capability。例如`client.node157`可以只获得某个CephFS或某段目录的`r`/`rw`权限，也可以被限制来源网络；修改layout和quota还需要额外的`p` capability。

这一层的主体不是挂载点内的Linux用户，而是持有keyring的客户端进程、主机、挂载实例、应用或租户。为了便于撤销和审计，宜按客户端或用途分配独立CephX身份，而不是把一个keyring复制到所有机器。keyring可以由root、systemd或受限sudo交给内核CephFS客户端或`ceph-fuse`完成挂载。

#### 4.1.2 第二层：Linux/POSIX用户

同一个CephFS挂载点可以由多个Linux用户共同使用。CephX只认证“这个客户端挂载是否可信”，不会在每次文件访问时把Linux用户变成对应的`client.<name>`；CephFS官方也明确指出CephX不是面向每个人类用户的登录认证系统。

文件操作由客户端提交进程的数字UID、主GID和附加组，MDS再根据共享元数据中的POSIX owner/group、mode和ACL判断权限。因此同一用户从多个客户端访问时，所有客户端必须保持相同的UID/GID；同名但数字ID不同会失去应有权限，不同名但数字ID相同会被视为同一所有者。

Linux用户可以通过LDAP/AD统一解析，也可以由全局UID/GID台账加Ansible等工具同步成本地账号。用户登录客户端使用的是本地密码、SSH公钥、LDAP或其他PAM凭据，不使用CephX keyring作为个人登录密码。

#### 4.1.3 典型开通流程

```text
cephadm bootstrap
  └── 创建client.admin及管理员keyring
          │
          ├── 管理员创建CephFS
          ├── 创建用户/项目目录并设置POSIX权限
          └── 创建受限client.<name>及客户端keyring
                        │
              root/systemd在客户端完成挂载
                        │
              Linux用户登录并以UID/GID访问文件
```

因此，CephFS第一层可近似理解为以管理节点和客户端主机为主体，但更准确地说是以“持有keyring的进程或挂载实例”为主体；第二层才是具体Linux文件用户。管理员可以通过MDS capability限制客户端路径，对不可信客户端还可以配置`root_squash`，但拥有客户端root权限的人仍能模拟普通UID，因此直接挂载客户端总体上必须位于可信管理域。

### 4.2 配额机制

**CephFS可由一台受控管理主机使用含`p` capability的专用CephX身份建立管理挂载，统一设置所有目录的配额；配置由MDS集中保存并供各业务挂载客户端读取和协作执行，无需在每台客户端重复配置。**

CephFS 原生配额是目录树配额，可在任意目录上设置：

- `ceph.quota.max_bytes`：限制目录树中的字节数；
- `ceph.quota.max_files`：限制目录树中的文件数量。

配额通过目录上的CephFS虚拟扩展属性表示，可以嵌套设置。应用在客户端通过VFS提供的`setxattr(2)`、`getxattr(2)`接口设置或读取`ceph.quota.*`属性；kernel client或`ceph-fuse`把请求发送给MDS。扩展属性属于文件元数据的一部分，真正的持久化、查询和管理由CephFS MDS完成，并不是保存在客户端本地磁盘。子目录写入需要同时满足其自身及可见祖先目录的限制。CephFS没有对应的通用UID/GID用户和组配额，因此通常采用“用户专属目录+POSIX权限+目录配额”组合实现用户容量限制。

`p`是CephFS MDS capability中的附加权限标志，用来允许客户端修改文件或目录的layout和quota扩展属性；普通`r`或`rw`权限本身不包含这项管理能力。`p`标志授予的是CephX身份（例如`client.quota-admin`）的MDS capability，不是Linux用户、客户端主机或挂载点自身的属性。任何使用该CephX身份及其keyring建立的挂载都会在授权路径范围内继承`p`能力；挂载中的进程还需同时满足本地POSIX权限，才能修改layout或quota扩展属性。生产中应为普通业务挂载使用不含`p`的CephX身份，另建含`p`的管理CephX身份，只供受控管理客户端或配额服务建立独立管理挂载。不要让业务挂载与管理挂载共用含`p`的keyring，否则所有使用该keyring的挂载都可能获得修改配额的能力。

扩展属性是CephFS配额的配置接口，不代表配额必须分散到各业务客户端管理。对于任意普通目录，可以只在一台受控管理主机建立含`p` capability的专用管理挂载，由统一服务通过`setxattr(2)`设置所有目录配额；普通业务客户端只使用不含`p`的身份。若把用户或项目目录建模为CephFS subvolume，还可以通过MGR volumes模块的`ceph fs subvolume create --size`和`ceph fs subvolume resize`集中创建、调整配额，无需在业务客户端逐个执行`setfattr`。Ceph Dashboard也提供CephFS目录浏览和配额管理界面。因此CephFS可以集中管理配额，只是任意目录的底层表达仍然是MDS保存的`ceph.quota.*`虚拟扩展属性。

CephFS配额采用“VFS暴露扩展属性接口、MDS保存配额配置与相关元数据、挂载客户端协作执行”的方式：kernel client、`ceph-fuse`或`libcephfs`客户端取得quota inode及虚拟扩展属性后，在达到限制时停止本机写入。官方明确指出经过修改的恶意客户端可能绕过限制；路径受限挂载还必须能看到承载配额的目录inode，否则客户端可能无法执行祖先目录配额。因此它不能在完全不可信的直接挂载客户端环境中作为绝对安全边界。

官方依据：

- [Cephadm bootstrap与client.admin](https://docs.ceph.com/en/reef/cephadm/install/)
- [CephX User Management](https://docs.ceph.com/en/latest/rados/operations/user-management/)
- [CephFS Quotas](https://docs.ceph.com/en/latest/cephfs/quota/)
- [CephFS Client Capabilities](https://docs.ceph.com/en/reef/cephfs/client-auth/)

### 4.3 对本项目的借鉴

1. **集中设置配额，多客户端共同使用。** 可以借鉴CephFS的受控管理入口，在152上的独立管理服务中统一设置JuiceFS目录配额。JuiceFS的`quota`命令直接访问元数据引擎，不需要为了设置配额另建挂载；现有专用统计控制挂载继续承担查询职责，但其技术上可写，不应当作只读后端权限，具体隔离见11.2节。
2. **将“能读写文件、不能修改配额”作为权限验收目标。** CephFS通过CephX的MDS `p`权限区分这两类操作。本项目中的Ceph提供对象存储，JuiceFS配额保存在TiKV，因此不能把MDS的`p`权限或`ceph.quota.*`扩展属性直接用于本项目。应通过受控进程、凭据权限和网络隔离落实分权，并验证普通用户无法绕开Portal改限额。
3. **区分规则集中保存与实际生效。** 在一台管理主机设置后，要从两台业务客户端验证限额读取、超限拒绝和调整后的恢复。测试同时覆盖已有数据、嵌套目录和并发写入，确认客户端同步延迟；集中管理本身不代表可以防御持有后端凭据的不可信客户端root。

## 五、BeeGFS

> - **用户管理：** BeeGFS核心文件系统没有独立的Cluster Admin、Regular User等产品账号，只有节点连接认证和Linux/POSIX文件用户两套概念。management、metadata、storage服务和所有原生客户端共享同一个`conn.auth`；它只判断节点能否连接集群，不携带管理员、服务节点或客户端角色。普通Linux用户不读取密钥，只在挂载点内按UID/GID、mode和ACL访问文件。密钥默认仅允许节点root读取，因此任何持有该密钥且能连接management服务的节点root都具备发起管理命令的条件，所有服务节点和原生客户端的root都必须可信。
> - **配额管理：** BeeGFS不是按目录树设置配额，而是按“storage pool中的UID或GID”限制用量。storage pool只是若干数据storage target组成的逻辑资源池；新集群的全部target默认都在同一个default pool中，因此未划分多个pool时，可以把BeeGFS配额直观理解为“对某个UID或GID在整个默认数据池中的总用量进行限制”。划分多个pool后，同一UID或GID在每个pool中分别统计和限额。可限制的指标是数据空间和storage target上的chunk-file数量。

**示例：部署BeeGFS，并让Alice从两台客户端访问**

1. 部署运维人员使用各服务器的root权限，按节点角色分别安装和配置BeeGFS management、metadata、storage等服务；这些root账号是各Linux系统的本地账号，不是BeeGFS创建的管理员账号。
2. 初始化management服务时只生成一份随机共享密钥`conn.auth`，将内容完全相同的密钥文件分发到全部服务节点和获准接入的客户端，默认保存为`root:root 0400`。
3. 各服务进程使用这份密钥加入集群；客户端root也使用同一密钥启动客户端并挂载BeeGFS。没有密钥的节点不能连接，但集群无法根据这份密钥判断连接来自服务节点还是客户端。
4. 运维方可以规定只在指定管理终端运行`beegfs`写管理命令，并用本地账号、sudo和审计限制人员操作；但这是外部运维制度，不是BeeGFS内置角色控制。其他服务节点或客户端的root如果能够读取密钥、运行管理工具并访问management服务，BeeGFS不能仅凭`conn.auth`把它拒绝为“非管理员”。
5. 客户端A和客户端B通过LDAP，或通过同步的本地账号，都把Alice定义为`UID=10001、GID=10001`。Alice不读取`conn.auth`，而是登录客户端后访问已经挂载的目录。
6. Alice在任一客户端读写时，BeeGFS按调用进程提交的UID/GID 10001检查POSIX权限；两台客户端数字身份一致，因此看到相同的文件所有者和访问结果。
7. 假设集群只有default pool，受信任的root为UID 10001设置10 TiB空间配额，那么Alice在所有目录中、只要数据存放于default pool，都会合并计入这10 TiB；该规则不是只限制`/home/alice`目录。如果以后增加archive pool，则需为UID 10001在archive pool另设一条独立配额。

### 5.1 用户与访问管理

BeeGFS的用户和权限模型可以归纳为两层：

1. **集群控制层——连接集群和执行管理操作**：所有服务和客户端使用相同的`conn.auth`完成连接认证。密钥只能区分“持有密钥”和“没有密钥”的节点，不能区分management、metadata、storage、客户端或管理员身份。`conn.auth`默认是`root:root 0400`，因此通常只有每个持有密钥节点上的root能够直接使用它并执行写管理操作；如果将密钥改为`root:beegfs`并允许`beegfs`组读取，官方允许非root用户执行相应的查询类命令，非root访问通常是只读。这里的密钥认证和本机root/非root权限共同约束集群操作，但BeeGFS没有另一套产品账号来指定“只有某台机器上的root才是管理员”。
2. **文件访问层——普通用户读写文件**：Alice、Bob等普通Linux用户不需要、也不应读取`conn.auth`。他们只访问root预先建立的挂载点，权限由数字UID/GID、mode和ACL决定，配额也按UID或GID统计。

因此，把管理工具只安装在指定终端、限制sudo以及记录审计日志，可以规范管理流程并减少误操作，但不能构成抵御客户端root的BeeGFS内部安全边界：客户端root可以读取或复制密钥，也可以自行安装工具。原生BeeGFS服务节点和客户端的root必须全部属于可信管理域。如果某个客户端root不可信，仅靠`conn.auth`无法赋予该客户端“只能访问文件、不能管理集群”的身份；此时应通过NFS/SMB网关提供文件访问，避免向该客户端分发BeeGFS共享密钥，或者使用独立集群/安全域进行隔离。

最终文件用户身份来自Linux UID/GID。启用配额支持后，客户端把每次I/O调用者的UID/GID发送给服务端，因此所有客户端必须对同一用户使用相同UID、主GID和附加组。身份记录可以来自各节点同步的`/etc/passwd`和`/etc/group`，也可以来自LDAP等NSS身份源。BeeGFS management节点还必须能够枚举需要跟踪的UID/GID；若LDAP/SSSD不能完整枚举，可以改用明确的ID范围或受控ID清单文件。

### 5.2 配额机制

BeeGFS配额与Weka、CephFS的目录配额不同：**它不把某个目录树作为计量边界，而是把某个storage pool中属于特定UID或GID的数据作为计量边界。**

BeeGFS中的**storage target是存放文件数据片段的基本存储单元**。它通常是storage服务器上的一个专用目录，该目录背后由本地磁盘、RAID或NVMe设备上挂载的ext4、XFS、ZFS等文件系统提供空间。storage服务将这个目录以唯一target ID注册到BeeGFS；一个storage服务器可以提供一个或多个target。客户端看到的一个逻辑文件会按条带规则拆成chunk file，分布到一个或多个target中。

相关概念的关系如下：

```text
storage服务器（物理节点）
└─ 本地磁盘或RAID上的ext4/XFS/ZFS
   └─ storage target（BeeGFS注册的数据存储单元）
      └─ 保存逻辑文件的chunk file

storage pool = 若干storage target的逻辑集合
```

因此，storage target不是客户端看到的目录，也不等同于一块物理盘；它是BeeGFS把底层存储资源纳入集群并进行数据放置、用量统计和故障管理时使用的逻辑单元。

#### 5.2.1 一条配额规则限制什么

一条BeeGFS配额规则可以准确表示为：

```text
(storage pool, UID或GID) → 数据空间上限 + chunk-file数量上限
```

三个部分分别回答不同问题：

| 部分 | 含义 |
| --- | --- |
| UID或GID | 限制哪个Linux用户或用户组 |
| storage pool | 只统计该用户或组存放在这组storage target上的数据 |
| 空间、chunk-file数量 | 分别限制占用的数据容量和底层数据片段文件数量 |

例如，下面的规则表示“UID 10001在default pool中最多使用10 TiB”：

```text
(default pool, UID 10001) → 10 TiB
```

只要文件归UID 10001所有并存放在default pool，无论文件位于`/home/alice`、`/project-a`还是其他目录，空间都会合并计入这10 TiB。反过来，`/home/alice`中由UID 10002拥有的文件计入UID 10002，而不会因为路径位于Alice目录下就计入UID 10001。

#### 5.2.2 storage pool是什么

storage pool是BeeGFS对一组**数据storage target**的逻辑分组，不是客户端目录，也不是ext4、XFS或ZFS文件系统。文件的条带布局决定其数据写入哪个pool中的target；管理员也可以给目录设置默认pool，使该目录中新创建的文件优先存放到该pool，但这只是数据放置策略，不会把目录本身变成配额对象。

BeeGFS文件系统、storage pool和storage target的层级关系是：

```text
一个BeeGFS文件系统实例
└─ 一个统一的文件系统命名空间
   └─ 一个或多个storage pool
      └─ 每个pool包含一个或多个数据storage target
         └─ 每个target通常使用一个服务端本地文件系统保存chunk file
```

这里有三个限制：

- 新建BeeGFS实例时，全部数据storage target默认属于`default pool`；
- 一个storage target同一时间只能属于一个storage pool；
- storage pool只组织保存文件内容的数据target，不包含保存目录、文件名等信息的metadata target。

客户端挂载的是整个BeeGFS文件系统，而不是某个storage pool。一个挂载点可以访问存放在所有pool中的文件，文件或其父目录的布局配置决定新文件的数据进入哪个pool。pool不会自动表现为独立目录，也不能像独立文件系统那样单独挂载。

如果实例没有再划分其他pool，全部数据target会一直位于default pool，此时：

```text
某UID在default pool中的用量
≈ 该UID在整个BeeGFS文件系统中的数据总用量
```

因此，单pool环境可以把BeeGFS配额理解为“全文件系统范围的用户/组配额”。如果集群把NVMe target组成hot pool、HDD target组成archive pool，那么同一UID会形成两份相互独立的用量和配额：

```text
(hot pool, UID 10001)     → 单独统计和限额
(archive pool, UID 10001) → 单独统计和限额
```

pool自身的总容量不是某个用户的配额；它只是限定这条用户/组配额在哪一组物理数据资源内统计。

#### 5.2.3 用量如何统计和执行

ext4、XFS或ZFS只出现在BeeGFS配额的底层统计实现中，不是用户看到的配额范围：

1. 客户端在执行I/O时向BeeGFS提交调用者的UID/GID；
2. 文件数据按照条带布局写入所属storage pool中的一个或多个storage target；
3. 各storage target所在的底层ext4、XFS或ZFS统计不同UID/GID占用的数据块和chunk file；
4. BeeGFS management服务周期性收集各target的报告，并按storage pool和UID/GID汇总；
5. 启用quota enforcement后，management服务把超限状态通知metadata和storage服务，阻止该UID/GID继续创建或扩展文件。

这里的“inode限额”实际统计storage target上的数据chunk file，而不是客户端命名空间中的普通文件或目录数量。一个条带化的逻辑文件可能在多个target上形成多个chunk file，目录也不计入该指标。底层文件系统负责提供原始计数，最终配额规则仍由BeeGFS统一设置和执行，无需管理员逐个为用户配置ext4或XFS配额上限。

management服务按周期汇总和下发超限状态，因此用量显示和强制执行不是逐次I/O严格同步，可能存在短暂超额窗口；缩短更新周期可以减小窗口，但会增加管理查询开销。BeeGFS也允许只开启quota tracking观察用量，而暂不启用quota enforcement。

#### 5.2.4 与目录配额的区别

BeeGFS没有原生的任意目录树硬配额。给目录指定storage pool只是决定新文件的数据放置位置，并不等于给该目录设置容量上限。

项目目录可以采用“专属GID + 目录`setgid` + 该GID的pool配额”近似实现：目录中新文件继承项目GID，BeeGFS再限制该GID在指定pool中的总用量。但这仍是GID配额；同一GID在该pool其他目录中的文件也会一并计入，因此不具备Weka或CephFS那种以目录树为天然边界的语义。

如果必须按任意目录树统计，可使用Robinhood等工具定期扫描并保存结果，但这属于外部周期统计和策略执行，不是BeeGFS原生的同步目录硬配额。

配额设置、默认值和强制执行开关应由受信任的root控制。普通Linux用户不能因为拥有某个目录的写权限而修改BeeGFS配额；拥有原生客户端root权限的人则仍处于BeeGFS可信管理边界内。

官方依据：

- [BeeGFS Connection-based Authentication](https://doc.beegfs.io/latest/advanced_topics/authentication.html)
- [BeeGFS Quota](https://doc.beegfs.io/latest/advanced_topics/quota.html)
- [BeeGFS Storage Pools](https://doc.beegfs.io/latest/advanced_topics/storage_pools.html)
- [BeeGFS ACL and identity resolution](https://doc.beegfs.io/latest/advanced_topics/acl.html)

### 5.3 对本项目的借鉴

1. **先解决跨客户端数字身份一致性。** 采用统一UID/GID台账或LDAP，开通用户及接入新客户端前检查冲突，再用`id`、`getent`核验客户端实际解析结果。Portal中登记用户名和UID只是保存映射，不会自动配置客户端Linux账号。
2. **在页面上写清配额统计范围。** 第一期展示用户专属目录的用量；后续若增加UID/GID配额，应明确它统计卷内该所有者跨目录的总用量。BeeGFS的pool配额和chunk-file计数与JuiceFS目录、inode口径不同，不能照搬，也不能把Ceph Pool当作JuiceFS个人配额对象。
3. **明确原生客户端root的信任边界。** BeeGFS共享密钥模型说明：凭据一旦交给客户端root，限制管理CLI安装位置并不能限制其实际能力。本项目应把TiKV/Ceph凭据交给受控挂载服务，并限制普通用户读取；若必须防御客户端root，则另行选择带可靠身份认证的协议网关或服务端授权方案。

## 六、JuiceFS

> - **用户管理：** 当前项目采用的JuiceFS社区版由客户端root/systemd使用META URL直接连接元数据引擎，不提供商业版Web Console集中管理的客户端访问Token，也没有Weka式Cluster Admin和Regular User挂载账号模型。挂载点中的普通用户由数字UID/GID、mode和POSIX ACL识别；同一用户必须在所有客户端保持相同UID、主GID和附加组。
> - **配额管理：** 当前交付的JuiceFS 1.4.1支持文件系统总配额、目录配额、UID用户配额和GID组配额，均可对容量和inode设置硬限制。目录配额适合“一名用户对应一个专属目录”的使用方式；UID/GID配额可以跨目录限制同一所有者，必要时可与目录配额叠加。

JuiceFS使用“卷”表示一套独立的逻辑文件系统实例。创建卷时，存储管理员执行`juicefs format`，同时指定TiKV META URL、卷名称以及Ceph数据存储配置。格式化操作会在TiKV中保存卷名、唯一UUID、Ceph存储配置、块大小、配额等卷级配置；此后JuiceFS把文件和目录元数据写入该卷对应的TiKV元数据空间，并把文件内容切分为数据对象写入指定的Ceph Pool。这个卷不是TiKV或Ceph原生提供的卷：TiKV和Ceph分别只看到键值记录和对象，文件系统命名空间以及两者之间的对应关系由JuiceFS维护。下面的示例把新建的JuiceFS卷命名为`juicefs-prod`。

**示例：Alice从两台客户端使用`juicefs-prod`**

1. 存储管理员使用受控的TiKV和Ceph连接信息执行`juicefs format`创建`juicefs-prod`；TiKV保存卷配置以及文件名、目录、UID/GID、权限、配额等元数据，Ceph保存文件内容对象。
2. `juicefs format`只需在一台受控主机上执行一次。客户端A和客户端B安装兼容的JuiceFS客户端，能够访问同一TiKV META URL，并分别取得所需的TiKV TLS凭据（如已启用）及Ceph配置和keyring后，就可以把`juicefs-prod`分别挂载到本机目录；其他客户端不应重复执行`format`，两个挂载点会看到同一文件系统命名空间。
3. LDAP或统一账号台账在两台客户端都把Alice定义为`UID=10001、GID=10001`。管理员在JuiceFS中创建`/users/alice`，设置所有者、POSIX权限或ACL。
4. Alice不直接登录TiKV或Ceph，只从已经挂载的文件系统访问`/users/alice`；JuiceFS根据请求中的数字UID/GID检查文件权限。
5. 管理员为`/users/alice`设置100 GiB目录容量配额和inode上限。达到硬限制后，Alice继续写入该目录会收到`EDQUOT`；如还设置UID 10001配额，则目录规则和UID规则同时生效。

### 6.1 用户与访问管理

JuiceFS社区版自身没有独立的产品账号、挂载用户或用户管理体系。其原生文件用户只有一层：挂载点中的Alice、Bob等Linux用户以数字UID/GID访问文件，内核`default_permissions`检查和JuiceFS权限检查都依据文件owner、mode和ACL；root挂载默认允许本机其他用户使用挂载点。

JuiceFS挂载进程还必须使用META URL连接TiKV，并取得访问Ceph所需的配置和keyring，但这些属于TiKV和Ceph各自的后端接入机制，不是JuiceFS定义的“卷连接身份”，也不会在JuiceFS中形成管理员、普通用户等角色。社区版JuiceFS只是使用这些后端连接条件完成挂载和数据访问。

这里需要区分版本：JuiceFS商业版/云服务提供Web Console和客户端访问Token。管理员可以为一个文件系统创建多个Token，并分别限制来源IP、只读/追加/读写权限及允许挂载的子目录；客户端通过`juicefs auth`或`juicefs mount --token`完成认证。该Token属于卷级或挂载级接入凭据，不是Alice、Bob这样的POSIX文件用户，也不等同于Weka把Cluster Admin、Regular User和Token绑定在一起的用户角色体系。本项目当前使用社区版1.4.1，因此不具备这套商业版控制面。

JuiceFS不根据用户名判断文件所有者。若客户端A的Alice和客户端B的Bob都使用`UID=10001`，JuiceFS会把二者视为同一文件身份。因此所有客户端必须使用统一且不冲突的UID/GID，可通过LDAP/SSSD集中解析，也可通过集中台账和配置管理同步本地账号。

JuiceFS 1.2及以后版本支持POSIX ACL。启用ACL后，可以在owner/group/other之外为特定UID或GID设置更细权限；但ACL仍依据数字ID，不能解决不同客户端复用同一UID的问题。

### 6.2 配额机制

JuiceFS 1.4.1可使用四种配额范围：

| 配额范围 | 统计边界 | 适用场景 |
| --- | --- | --- |
| 文件系统总配额 | 整个JuiceFS卷 | 限制卷的总容量和总inode数 |
| 目录配额 | 指定目录及其子树 | 用户目录、项目目录或租户目录 |
| UID用户配额 | 卷内最终归该UID所有的文件和目录 | 限制一个Linux用户跨目录的总用量 |
| GID组配额 | 卷内最终归该GID所有的文件和目录 | 限制项目组或共享组的总用量 |

四类配额都可以限制容量和inode，并且是硬限制。文件系统总容量耗尽时返回`ENOSPC`；目录、UID或GID配额耗尽时返回`EDQUOT`。多个配额可以叠加，一次写入必须同时满足所有适用规则。

目录配额直接以路径对应的目录树为边界，并支持嵌套配额。例如：

```bash
juicefs quota set "$META_URL" --path /users/alice --capacity 100 --inodes 100000
```

这条规则只统计`/users/alice`子树，最符合“一个用户一个目录”的管理体验。使用`--subdir /users/alice`单独挂载该目录时，`df`还能显示该目录配额和剩余量；存在多级父目录配额时，客户端按适用规则计算可用空间。

UID和GID配额不看目录路径，而按文件最终保存的owner UID/GID跨目录统计：

```bash
juicefs quota set "$META_URL" --uid 10001 --capacity 100 --inodes 100000
juicefs quota set "$META_URL" --gid 20001 --capacity 500 --inodes 500000
```

当前交付的`juicefs-1.4.1-ceph`和`juicefs-1.4.1-patched`二进制已经通过只读`quota set --help`确认包含`--path`、`--uid`和`--gid`；旧1.3.1二进制只包含目录配额。因此正式使用UID/GID配额前，必须确保所有可写挂载均使用1.4.1兼容版本。

配额配置和计数保存在元数据引擎中，各挂载客户端缓存并周期同步用量。该机制能执行硬限制，但多客户端并发时显示值可能短暂滞后，客户端异常退出也可能造成计数不一致；应保留`juicefs quota check`检查以及受控的`--repair`修复流程。

### 6.3 TiKV、Ceph与原生管理边界

在当前`JuiceFS + TiKV + Ceph`架构中：

```text
JuiceFS客户端
├─ 解释文件、目录、UID/GID、权限和配额语义
├─ 通过TiKV读写这些元数据和配额状态
└─ 通过Ceph读写文件内容对象
```

TiKV只持久化JuiceFS元数据，不负责创建Linux用户，也不直接理解“管理员、Alice目录”等产品角色；Ceph只保存数据对象，同样不负责最终用户的目录权限或JuiceFS配额。用户管理和配额语义都在JuiceFS层完成。

需要特别注意：`juicefs quota`直接使用META URL连接元数据引擎，不要求本地存在挂载点。社区版原生机制没有与Weka管理RBAC或CephX capability等价的“配额管理员”角色；任何能够取得可写META URL和对应连接权限的进程都可能执行配额修改命令。JuiceFS原生部署需要依靠元数据凭据保护、网络隔离和受控的命令执行环境限制管理入口。

### 6.4 JuiceFS商业版的管理与访问机制

JuiceFS商业版将管理操作、客户端挂载和挂载后的文件访问分开处理：

1. **管理操作**：通过Web Console创建和管理文件系统、设置文件系统或目录配额。Console API使用独立的API密钥进行请求认证。商业版命令文档说明，配额通常直接在Web Console中管理，不建议用户从终端直接运行`juicefs quota`。公开资料没有明确给出“设置配额”对应的完整账号角色和权限矩阵，因此这里不推断其具体RBAC规则。
2. **客户端挂载**：客户端使用访问Token向商业版元数据服务认证。一个文件系统可以创建多个Token，分别限制来源IP、只读/追加/读写权限及允许挂载的子目录；监控API使用与挂载Token不同的API-only Token。访问Token代表一次客户端接入授权，不是挂载点内Linux用户的身份。
3. **文件访问**：文件系统挂载后，Alice、Bob等进程仍依据POSIX UID/GID、mode和ACL访问文件。客户端Token决定挂载点整体可获得的权限，POSIX权限再决定挂载点内各用户可以访问哪些文件。

与社区版客户端直接连接自选元数据引擎不同，商业版使用专有元数据服务，并由Web Console管理文件系统和客户端访问Token。两者都提供文件系统配额和POSIX文件权限，但管理与接入链路并不相同。

商业版还提供UID/GID Auto Map：根据用户名、组名映射为统一内部ID，再转换为各客户端本地的数字ID，因此同名用户在不同客户端的UID可以不同。实际使用需确认该功能的启用状态及各主机身份记录是否匹配；这不等于在客户端创建账号，也不能据此认为社区版具备相同能力。[官方说明：商业版UID/GID Auto Map](https://juicefs.com/docs/cloud/guide/guid_auto_map/)

官方依据：

- [JuiceFS Storage Quota](https://juicefs.com/docs/community/guide/quota/)
- [JuiceFS POSIX ACL](https://juicefs.com/docs/community/security/posix_acl/)
- [JuiceFS FUSE Mount Options](https://juicefs.com/docs/community/fuse_mount_options/)
- [JuiceFS Sync Accounts between Multiple Hosts](https://juicefs.com/docs/community/sync_accounts_between_multiple_hosts/)
- [JuiceFS Metadata Engine](https://juicefs.com/docs/community/databases_for_metadata/)
- [JuiceFS商业版客户端访问控制](https://juicefs.com/docs/cloud/acl/)
- [JuiceFS商业版Console API认证](https://juicefs.com/docs/cloud/reference/console_api/)
- [JuiceFS商业版命令与配额管理](https://juicefs.com/docs/cloud/reference/command_reference/)
- [JuiceFS商业版容量与配额](https://juicefs.com/docs/cloud/guide/quota/)

### 6.5 对本项目的借鉴

1. **直接复用社区版配额能力。** 第一期开通“一名用户一个目录”的目录硬配额，按需增加UID/GID跨目录限额。Portal负责登记、授权、展示和审计，限制及用量以JuiceFS元数据为准；SQLite可以保存查询缓存和操作记录，不应承担阻止超额写入的职责。[依据：JuiceFS配额机制](https://juicefs.com/docs/community/guide/quota/)
2. **沿用当前部署，补齐一个受控写入口。** 152上的配额服务调用JuiceFS原生元数据配额接口，与现有统计采集器分别配置权限；CLI与结构化接口的选择见11.7节。上线前验证当前1.4.1客户端的多端生效、并发超限和异常退出后的计数检查；页面显示采集时间，并区分“配置已写入”与客户端实际生效，避免把缓存显示当作即时执行状态。
3. **借鉴商业版按用途分配凭据。** 商业版分别管理Console、挂载Token和文件用户。本项目也应使Portal登录凭据、管理服务凭据、挂载服务凭据用途明确，普通文件用户继续使用Linux身份。若以后支持只读或限定子目录的客户端授权，需要由可信服务端验证；仅把Token检查编进社区版二进制，会被替换客户端绕过。[依据：商业版客户端访问控制](https://juicefs.com/docs/cloud/acl/)

## 七、Lustre

> - **用户管理：** Lustre没有Weka式独立的Regular挂载用户账号体系。客户端准入可由网络访问控制、NID/nodemap策略及可选的共享密钥或Kerberos认证控制；文件用户权限主要沿用Linux POSIX UID/GID和ACL。默认挂载流程不要求登录独立的Lustre用户；跨客户端应统一数字身份，或由服务端nodemap映射不同身份域的ID。nodemap还可将客户端root映射为低权限身份，并将未配置映射的UID/GID映射为指定身份或拒绝其访问。
> - **配额管理：** 集群运维人员在MGS配置授权策略，获准的受控客户端管理进程按UID、GID或project ID设置块和inode限额；project ID可用于跨多个用户的项目用量控制。

**示例：Alice从两个身份域使用Lustre**

1. 集群运维人员部署Lustre管理、元数据和对象存储服务，建立文件系统`lustrefs`；
2. 在客户端A、B安装Lustre客户端，确认LNet所选网络接口能连接MGS等服务；若默认选用的TCP接口已满足要求，无需额外配置LNet。两端root分别执行`mount -t lustre <MGS-NID>:/lustrefs /mnt/lustrefs`；Lustre不要求创建或登录独立的挂载用户，若启用额外认证则按相应机制配置凭据；
3. Alice在客户端A的UID/GID为`10001:10001`，在客户端B为`20001:20001`。运维人员按两组客户端的NID分别配置nodemap，使两侧Alice都映射为文件系统内的`50001:50001`；
4. Alice从两端访问时，文件权限和UID/GID配额都按映射后的身份判断；运维人员可为UID `50001`设置个人配额。若多人共同写项目数据，还可为项目文件设置并继承project ID `30001`，再为该ID设置整体配额。

### 7.1 用户与访问管理

Lustre的文件用户是客户端Linux进程提供的POSIX身份，不是独立创建的产品账号。集群管理则依赖受控的服务端配置和管理命令；普通用户获得目录写权限，并不等于获得管理命令或配额配置权限。

LNet是Lustre的节点间通信层，NID是类似`10.0.0.11@tcp`的网络标识。客户端安装Lustre、连通MGS等服务后，可由本机root执行挂载，不必取得Weka式挂载用户或Token。可用防火墙或交换机ACL限制能接入LNet的来源；若需要验证客户端持有凭据，可另外启用Lustre共享密钥或外部Kerberos认证。NID只表示网络端点，本身不是加密身份凭据。

#### Nodemap：跨客户端身份映射

管理员按客户端的NID范围建立nodemap，并为每组配置UID/GID映射。Lustre服务端据此把客户端提交的数字ID转换为文件系统内部统一的ID，再据此判断POSIX权限和统计配额。因此，客户端A的Alice可以是UID `10001`，客户端B的Alice可以是UID `20001`，只要两组映射都指向内部UID `50001`，便会被当作同一文件所有者和配额对象。映射关系由管理员明确维护；nodemap不会仅凭用户名自动判断两人是否同一人。

Nodemap还可把客户端root映射为低权限UID/GID，避免客户端root直接取得文件系统root权限；未配置映射的UID/GID可映射为指定身份，或通过`deny_unknown`拒绝访问。它也能按客户端组限定可挂载的子目录；较新版本的`deny_mount`还可限制新挂载，具体能力以部署版本为准。由于NID不是强身份认证，不能仅靠nodemap防止不可信客户端伪报UID。

### 7.2 配额机制

Lustre支持三类配额对象：

- user：按UID统计；
- group：按GID统计；
- project：按文件和目录携带的project ID统计，与文件所有者UID/GID独立；给目录设置继承属性后，新建子项可归入同一项目。

每类对象都可以限制存储块和inode，并支持soft limit、hard limit及grace period。超过soft limit后进入宽限期；宽限期结束仍未降到soft limit以下时，不再允许分配新块或inode。

Lustre通过Quota Master Target维护配额配置，Metadata/Object Storage Target参与分布式统计和执行。配额设置命令`lfs setquota`可以从已挂载文件系统的客户端发起，但不是任意客户端用户都能执行：集群运维人员先在MGS配置服务端nodemap策略，决定哪些客户端及其管理进程获准修改配额；受控客户端上的root在获授权后执行设置，服务端仍会检查权限。普通客户端用户可用`lfs quota`查询其可见的用量，不能自行提高限额。较新版本可用nodemap的`quota_ops`进一步控制配额修改权限；本机取得root身份本身不等于取得集群配额管理权。

project quota不是对任意路径字符串做实时递归统计，而是按文件和目录上的project ID计量。把一个共享目录树统一标为同一project ID并设置继承后，多名用户写入的项目数据可以计入同一配额；如果其中有未被标记的既有文件，不能仅凭目录路径推断它们已计入该项目。

官方依据：

- [Lustre Operations Manual](https://doc.lustre.org/lustre_manual.pdf)
- [Lustre UID/GID Mapping与nodemap](https://wiki.lustre.org/UID/GID_Mapping)
- [Lustre Project Quotas](https://wiki.lustre.org/Lustre_Project_Quotas)
- [Lustre客户端挂载流程](https://wiki.lustre.org/Mounting_a_Lustre_File_System_on_Client_Nodes)
- [Lustre共享密钥认证](https://wiki.lustre.org/Shared_Secret_Key_Authentication_And_Encryption)
- [Lustre nodemap配额操作权限](https://lustre.software/repos/master/?path=Documentation/man8/lctl-nodemap-modify.8)

### 7.3 对本项目的借鉴

1. **区分统一身份和身份映射两种路线。** Lustre的nodemap允许不同客户端的UID/GID映射为同一内部身份。本项目现阶段宜使用统一UID/GID；如果以后必须接入已有且编号冲突的用户体系，可借鉴其按可信客户端身份域维护映射的思路。但Portal保存映射表不会改变JuiceFS实际I/O身份，需要在文件访问链路中实现可靠转换。[依据：Lustre UID/GID映射](https://wiki.lustre.org/UID/GID_Mapping)
2. **共享项目用量与个人用量分别管理。** 可参考Lustre的project配额，将JuiceFS项目目录作为多人共享的配额对象，个人限制则按UID设置。当前目录配额已能满足普通项目子树的需求；跨多个无共同父目录的项目统计，不能仅靠新增Portal项目标签获得原生硬限制。
3. **把授权放在实际操作入口。** Lustre由服务端检查客户端配额管理操作，提示本项目应验证调用方能否实际修改限额。受控客户端root可承担运维职责，但若允许不可信root直接持有TiKV凭据，Portal角色配置无法形成同样的权限边界。

## 八、IBM Storage Scale

> - **用户管理：** 原生客户端场景分为集群管理与节点准入、文件访问两层。前一层有两套并行的管理入口：GUI及其Management API共用GUI账号和角色；原生REST API及`scalectl`使用另一套认证与RBAC。两套管理授权不自动互通；客户端节点身份又不同于管理账号。后一层依据POSIX UID/GID、权限和ACL决定挂载后谁能读写文件。
> - **配额管理：** 管理员按用户、组或fileset设置数据块和文件/inode的软、硬限额及宽限期；fileset配额限制整个显式创建的子树，与个人配额是不同对象。

**示例：Alice从两台原生客户端使用同一个文件系统**

1. 运维人员先在存储节点`scale1`上创建单节点集群，再在`scale2/3`安装软件、分别导入本机节点证书和私钥；随后由有权限的管理员执行`scalectl node add`，将`scale2/3`加入集群。以下以启用原生管理REST API、使用默认PAM认证为例：初始Linux账号`root`具有预置的`SecurityAdmin`管理角色；该角色用于集群管理，不是Alice的文件访问身份。
2. 假设`scale1/2/3`各有一块专用、空闲的1 TiB数据盘。集群管理员先核对磁盘不是系统盘、没有其他用途，再分别将它们定义为集群可识别的`nsd1/2/3`，并指定实际能访问各盘的NSD服务节点。NSD是对底层块设备的集群级命名和访问单位，不是磁盘上预先格式化的ext4目录；只有定义了NSD，还没有把磁盘分配给某个文件系统。
3. 管理员选择`nsd1`、`nsd2`创建文件系统`fs1`，例如将两块NSD归入同一个可存放数据和元数据的`system`存储池；`nsd3`暂不分配，之后可加入`fs1`或供另一个文件系统使用。`fs1`不会自动占用集群全部NSD，也不是直接从同一块NSD中只划出一半容量供它使用；通常按整块NSD分配。两块1 TiB NSD也不等于一定有2 TiB可供用户写入，元数据、日志和所选副本配置会占用空间。随后，管理员在`fs1`内创建名为`alice-home`的fileset：这是一个可单独设置配额等策略的文件集合，创建时虽有空的根目录，但尚未出现在用户可见的目录树中。管理员再将其根目录**链接**到`fs1`中的`/alice-home`路径；这里的“链接”是创建一个指向fileset根目录的特殊目录入口（junction），不是复制数据，也不是创建符号链接。客户端将`fs1`挂载到`/mnt/fs1`后，就会看到`/mnt/fs1/alice-home`这个目录。
4. 运维人员在`clientA`安装Storage Scale客户端，并在该节点本机导入节点证书、私钥和信任的CA链；已有集群中有权限的管理员再执行`scalectl node add`，将`clientA`作为client节点加入，并确认节点服务和状态正常。证书用于管理守护进程之间的安全通信；导入证书不会自动执行`node add`。节点间文件系统通信另受集群安全模式约束。
5. `clientA`上的root或以root权限运行的受控系统服务把`fs1`挂载到`/mnt/fs1`。Alice不需要Storage Scale GUI账号或挂载Token。运维人员为Alice配置Linux身份，例如UID/GID为`10001:10001`，并将`alice-home`设置为她有权访问的子树；Alice登录客户端后即可按文件权限读写。
6. Alice向`/mnt/fs1/alice-home/a.dat`写入时，客户端的Storage Scale进程按`fs1`的元数据和放置规则分配文件系统块；本例中数据块可在`system`池的`nsd1/2`之间分散，而不是整份文件固定落在某一块盘。本例的`clientA`不连接`nsd1/2`的底层块设备，因此通过对应的NSD服务节点访问数据；读取时按已记录的块位置取回数据。实际位置还取决于存储池策略、副本和故障组，不是每条用户I/O都机械地轮流发送到两块盘。
7. 运维人员按相同方式将`clientB`加入集群并挂载同一个`fs1`，且让Alice在`clientB`上仍解析为UID/GID `10001:10001`。这样她在两个挂载点看到同一命名空间，并以相同数字身份访问自己的文件；仅在两台机器上使用同名账号而UID/GID不同，并不能保证权限一致。
8. 集群管理员可为UID 10001设置个人配额，也可为`alice-home`设置整个fileset的配额。Alice的文件读写权限不会使她自动获得配额或集群配置修改权。GUI可另建管理员账号，但它不是上述原生客户端接入和文件访问流程的必需步骤。

### 8.1 用户与访问管理

上述原生客户端场景可按**集群管理与节点准入**、**文件访问**两层理解。第一层中的管理请求者和客户端节点也不是同一种身份。IBM提供两套管理入口，操作的是同一个集群，但账号与授权配置不自动互通：

| 管理入口 | 部署和身份来源 | 授权与典型用途 |
|---|---|---|
| **GUI及其Management API** | 运维人员在集群管理节点安装GUI服务。安装后需显式创建第一个GUI账号并赋予`SecurityAdmin`；后续GUI用户默认保存在GUI内部账号库，也可接入LDAP/AD。Management API复用GUI的后端和用户授权。 | GUI用户组授予`SecurityAdmin`、`StorageAdmin`、`Monitor`等角色，用于网页监控、日常配置管理，也可通过Management API执行获授权的管理操作。 |
| **原生REST API及`scalectl`** | 安装`gpfs.scaleapi`后由`scaleadmd`处理请求；默认以PAM认证Linux账号，也可配置LDAP、AD、OIDC或证书认证。初始`root`在**这套接口**中具有预置`SecurityAdmin`角色。 | 使用原生API自己的RBAC授权创建集群、添加节点、管理NSD、文件系统或fileset等操作，并可按资源细分权限；IBM将它定位为传统`mm*`管理命令的长期替代方向之一。 |

两边都有名为`SecurityAdmin`的角色，但**原生API中`root`的角色不会自动生成GUI账号或出现在GUI用户列表**，GUI管理员也不会自动获得`scalectl`权限。即使两边使用同一个LDAP验证用户名，授权仍须分别配置。传统`mm*`命令还有自己的执行权限要求，不能把它们视为受上述某一套RBAC全面约束。

**节点准入。** 原生客户端的接入流程是：安装软件、导入用于管理守护进程双向验证的证书和私钥、由有权限的管理员执行`node add`、检查节点运行状态，再挂载文件系统；文件系统数据通道另按集群安全模式认证。这决定的是哪台客户端节点能接入集群，不为Alice等文件用户创建账号或授予目录权限。

**POSIX文件用户。** Alice是在客户端操作系统登录并发起文件读写的用户，可以由各客户端的本地账号或统一身份服务（如LDAP/AD配合NSS）提供身份；她不必拥有Storage Scale GUI账号或原生API管理角色。挂载后的文件访问按进程的数字UID/GID、文件及目录的POSIX权限或ACL判断。若Alice要在`clientA`和`clientB`访问同一批文件，两台客户端必须将她解析为一致的UID/GID；仅用户名相同而数字ID不同，不能保证访问权限一致。集群管理员可设置文件所有者和目录权限，但管理账号、客户端节点身份与Alice的POSIX文件身份是不同层次。若改用NFS/SMB协议入口，则由协议网关处理发布、协议认证和身份映射，不走上述原生客户端节点加入流程。

### 8.2 配额机制

Storage Scale支持：

- user quota：限制某个UID；
- group quota：限制某个GID；
- fileset quota：限制一个fileset整体。

fileset是文件系统内部显式创建的管理对象，不是任意普通目录。“链接fileset”是把它的根目录通过特殊目录入口（junction）接入文件系统目录树；用户看到的是目录，管理员则可按整个fileset设置配额。独立fileset可拥有自己的inode空间，依赖型fileset则与上级共享inode空间。配额可限制数据块和文件/inode数量，具有soft limit、hard limit及grace period，也支持默认限额。

配额需先在文件系统级启用。管理员可用`mmsetquota`等管理命令或受支持的GUI/REST接口设置和查询；限制与用量保存在文件系统内部的用户、组、fileset配额文件中。普通文件用户不能仅凭数据访问权修改这些管理记录。需要注意，IBM文档说明root默认不受配额限制；若要求fileset配额也约束root，须另行启用相应配置。

官方依据：

- [Storage Scale GUI quota management](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=quotas-managing-quota-by-using-gui)
- [Storage Scale quota endpoints](https://www.ibm.com/docs/en/storage-scale/6.0.1?topic=endpoints-quota)
- [Storage Scale quota files](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=system-quota-files)
- [Storage Scale filesets and quotas](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=filesets-quotas)
- [Storage Scale fileset creation](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=filesets-creating-fileset)
- [Managing GPFS quotas](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=administering-managing-gpfs-quotas)
- [Storage Scale原生管理API RBAC](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=api-role-based-access-control)
- [Storage Scale GUI Management API与GUI授权关系](https://www.ibm.com/docs/en/storage-scale/6.0.1?topic=overview-storage-scale-management-api)
- [Storage Scale原生API与传统管理命令的定位](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=api-coexistence-mm-commands-cli)
- [Storage Scale原生管理API认证](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=api-authentication-storage-scale-native-rest)
- [Storage Scale原生管理API集群配置流程](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=configuring-storage-scale-native-rest-api)
- [Storage Scale节点身份](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=api-node-identities)
- [Storage Scale节点加入](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=command-scalectl-node)
- [Storage Scale NSD定义](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=command-scalectl-nsd)
- [Storage Scale底层设备与NSD](https://www.ibm.com/docs/en/storage-scale/6.0.1?topic=reference-mmcrnsd-command)
- [Storage Scale文件系统创建与挂载](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=command-scalectl-filesystem)
- [Storage Scale存储池与块分配](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=reference-mmadddisk-command)
- [Storage Scale客户端与NSD服务节点](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=overview-storage-scale-cluster-configurations)
- [Storage Scale集群安全模式](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=cluster-security-mode)
- [Storage Scale GUI账号与角色](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=administering-managing-gui-users)
- [Storage Scale GUI安装及首个账号创建](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=nodes-manually-installing-storage-scale-management-gui)
- [Storage Scale GUI与命令执行者审计](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=logs-audit-messages-cluster-configuration-changes)
- [Storage Scale文件访问身份](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=administering-managing-protocol-user-authentication)
- [Storage Scale GUI external authentication](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=users-configuring-external-authentication-gui)
- [Storage Scale authentication and ID mapping](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=considerations-authentication-id-mapping-file-access)

### 8.3 对本项目的借鉴

1. **统一我们自己的GUI与API授权。** Storage Scale两套管理入口需要分别配置账号和角色，容易造成权限理解偏差。本项目可以让Portal网页及其管理API共用一套账号、资源权限和审计；后端执行操作的服务账号单独保护，审计中记录实际发起请求的Portal用户，不能只记录Linux服务账号。
2. **把用户目录登记为有明确生命周期的资源。** 可以借鉴fileset的显式管理方式，在Portal中为用户目录记录所属JuiceFS卷、目录路径、UID/GID、配额和状态，并管理创建、绑定、调整和停用流程。当前仍使用JuiceFS原生目录，不需要实现Storage Scale的fileset或junction；目录改名、删除重建后应重新核对绑定关系。
3. **分别处理客户端停用和用户停用。** 客户端凭据、人员账号及其文件所有权是不同对象。建议分别记录客户端接入状态、Linux身份和可选Portal账号；删除Portal账号只应撤销门户访问，不能宣称已经撤销该用户在所有客户端的登录、挂载或文件访问权限。

## 九、NetApp ONTAP

> - **用户管理：** ONTAP在建集群时建立Cluster Admin；管理员创建数据SVM，并通过RBAC授权SVM管理员管理其资源。普通用户经SVM提供的NFS/SMB服务访问文件，身份分别来自UNIX UID/GID或Windows身份及其映射，不需要ONTAP管理账号。
> - **配额管理：** Cluster/SVM管理员在volume的quota policy中按用户、组或qtree设置容量和文件数限制，再激活规则；NFS/SMB文件用户不能凭数据访问权修改管理面配额。

**示例：Alice通过NFS和SMB使用ONTAP**

1. 运维人员完成ONTAP存储节点和磁盘的集群初始化；系统同时建立管理SVM及Cluster Admin账号`admin`。管理员把可用磁盘组织成local tier（CLI仍称aggregate），作为后续volume的底层容量来源。这是存储集群自身的管理流程，NFS/SMB客户端不加入ONTAP节点集群。
2. `admin`创建数据SVM`svm1`，配置后续提供文件服务所需的数据LIF，并准备DNS等网络信息；如果计划同时使用NFS和SMB，就为该SVM选择相应的数据协议。此时还没有创建示例中的数据卷`vol1`，也没有发布Alice的文件目录。`admin`可按需建立受限的SVM管理员账号；其管理权限由ONTAP RBAC决定，与Alice的文件访问身份无关。
3. 管理员从local tier的可用空间为`svm1`创建一个例如1 TiB的FlexVol volume`vol1`，并将它接入SVM命名空间的`/vol1`路径。这一步只是建立存放文件的数据卷；尚未配置客户端访问规则，Alice不能据此访问文件。
4. 管理员在`svm1`上创建并配置NFS服务器；如需SMB访问，再在AD域中创建该SVM的SMB服务器。这些是SVM的数据服务，服务就绪仍不等于客户端已获准访问`vol1`。
5. 管理员在`vol1`顶层创建qtree`alice-home`，其对外路径为`/vol1/alice-home`。qtree是volume内受ONTAP管理的子树，不是另一块磁盘或独立volume。管理员为它选择适合NFS/SMB共同访问的安全样式，并设置文件所有权及权限。
6. NFS侧，管理员为`vol1`（必要时为qtree）配置export policy，规定哪些客户端地址可访问、是否可写、采用`AUTH_SYS`还是Kerberos，以及如何处理客户端root。SMB侧，管理员建立指向`/vol1/alice-home`的share（例如`alice-home`），并设置share与文件权限。为使同一数据可由两种协议访问，还要配置SVM名称服务与Windows↔UNIX用户映射；仅用户名相同并不会自动视为同一身份。
7. 管理员在`svm1`的quota policy中为`vol1`的`alice-home` qtree设置例如500 GiB的tree硬配额；如需约束Alice在其中的个人用量，再设置该qtree内的user配额。将规则所在的策略分配给SVM后，对`vol1`执行`quota on`初始化，并用配额报告核对状态与用量。tree配额统计qtree内所有用户的数据，user配额只统计对应身份的数据。
8. 完成上述配置后，获准的Linux客户端通过SVM数据LIF挂载导出的`/vol1`，Alice进入挂载点下的`alice-home`目录；Windows客户端则使用AD账号连接`\\svm1\alice-home`。采用NFS `AUTH_SYS`时，Alice的文件身份是客户端提交的数字UID/GID，多台NFS客户端须保持这些数字ID一致；SMB侧的AD Alice经名称映射取得对应文件身份。两种入口访问的是同一批文件，同时受协议准入、文件权限和已启用的配额约束。Alice不需要ONTAP管理账号，也不能仅凭NFS/SMB文件访问权限修改quota policy。

**节点故障时的访问路径：** 客户端挂载的是数据SVM的LIF IP，而不是某台节点的固定IP。承载该LIF的节点故障后，若已正确配置HA接管和LIF故障转移，原LIF及其IP可迁至可用节点，幸存节点继续提供数据；客户端仍使用原IP和挂载路径，无需知道接管节点的新IP。网络会重新学习该IP对应的MAC，但切换期间I/O可能短暂停顿或重试，不能理解为严格的零延迟、零中断。

**对NFS客户端而言，首次挂载后就把服务端IP固定下来了，后续只会向这个IP发送请求。一般情况下，这个IP对应的服务端宕机后，服务就不可用了，这在集群存储的情况下是不可接受的。NetApp ONTAP通过特殊设计的IP分配和服务转移机制来保证客户端对故障无感。客户端看到的IP并不是物理机的IP，当NFS服务所在物理节点宕机后这个IP会被分给其他节点上的SVM，从而用同样的IP继续提供NFS服务。**

### 9.1 用户与访问管理

ONTAP建集群时自动创建Cluster Admin `admin`。Cluster Admin创建数据SVM，按需授权SVM管理员；SVM管理员可在分配的角色范围内管理所属SVM的volume、qtree、quota和NFS/SMB服务，而不获得整个集群权限。管理账号可以是本地账号，也可来自AD、LDAP等外部身份源；CLI、System Manager和REST API请求均受管理面认证与RBAC约束。

ONTAP数据服务主要由SVM的NFS/SMB入口提供。NFS访问通常使用UNIX UID/GID；传统AUTH_SYS模式下客户端提交数字身份，若需防止不可信客户端伪造身份，应采用Kerberos等更强认证并配置export policy和root squash。SMB使用Windows身份/SID及相应ACL。混合协议访问需由SVM的名称服务和name mapping把Windows与UNIX身份对应起来。无论通过哪种协议，文件用户身份与ONTAP管理账号都不是同一对象。

### 9.2 配额机制

先明确配额涉及的存储层级： **FlexVol和FlexGroup都是ONTAP的逻辑卷（volume），不是物理磁盘。** FlexVol建立在一个local tier（aggregate）上；FlexGroup由多个成员卷组成，成员可分布在不同local tier和节点上，但向NFS/SMB客户端呈现为一个卷，ONTAP在成员之间分布负载。上例中的`vol1`是FlexVol；如果需要跨多个底层存储资源扩展容量和吞吐，也可以使用FlexGroup。

**qtree是卷内由ONTAP管理的顶层子树**，在客户端看来是卷中的一个目录入口，不是另一块磁盘或独立卷。一个卷可以包含多个qtree，例如`vol1`下的`alice-home`和`bob-home`。管理员可以对整个卷内某个用户或组的用量设限，也可以对单个qtree内所有用户的总用量设限；两者的计量边界不同。

ONTAP在SVM的quota policy中，为指定FlexVol或FlexGroup卷配置以下三类配额目标：

- user：可按UNIX用户名/UID或Windows用户/SID限制；
- group：按UNIX组名/GID限制；
- qtree：限制整个qtree，不区分其中数据的所有者。

用户和组配额既可作用于整个volume，也可进一步限定到某个qtree。每类规则都可以设置磁盘容量、文件数量、soft limit、hard limit和告警threshold；还可以用default quota覆盖所有用户、组或qtree，再为特殊对象创建显式覆盖规则。

qtree不等于任意深度的普通目录。tree quota按该qtree内的全部文件计量，不区分owner；达到硬限额后，任何用户（包括root）都不能继续写入使其超限。同一qtree内还可设置用户或组配额。配额上限不等于容量预留：即使qtree限额尚未用尽，底层volume空间先耗尽时仍可能无法写入。

quota policy规则创建后需在volume上激活。首次`quota on`会初始化用量统计；修改已有规则时，部分变更可使用`quota resize`而无需重新初始化，其他变更仍需完整初始化。这里的hard limit会阻断超额操作，而soft limit和threshold主要触发告警，不像Lustre的宽限期机制那样在一段时间后自动转为阻断。管理员通过System Manager、CLI或REST API管理配额，普通NFS/SMB用户只访问文件数据。

官方依据：

- [ONTAP quota overview](https://docs.netapp.com/us-en/ontap/volumes/overview-quota-process-concept.html)
- [ONTAP tree quotas](https://docs.netapp.com/us-en/ontap/volumes/tree-quotas-concept.html)
- [ONTAP quota REST API](https://docs.netapp.com/us-en/ontap-restapi/storage_quota_endpoints.html)
- [ONTAP quota targets and types](https://docs.netapp.com/us-en/ontap/volumes/quota-targets-types-concept.html)
- [ONTAP hard、soft与threshold配额区别](https://docs.netapp.com/us-en/ontap/volumes/differences-hard-soft-threshold-quotas-concept.html)
- [ONTAP quota resize与重新初始化](https://docs.netapp.com/us-en/ontap/volumes/resizing-concept.html)
- [ONTAP管理员账号创建](https://docs.netapp.com/us-en/ontap/authentication/create-svm-user-accounts-task.html)
- [ONTAP administrator authentication and RBAC](https://docs.netapp.com/us-en/ontap/authentication/)
- [ONTAP NFS name services](https://docs.netapp.com/us-en/ontap/nfs-admin/ontap-name-services-concept.html)
- [ONTAP local tier与volume命名空间](https://docs.netapp.com/us-en/ontap/concepts/namespaces-junction-points-concept.html)
- [ONTAP FlexVol与FlexGroup卷定义](https://docs.netapp.com/us-en/ontap-restapi-991/manage_storage_volumes.html)
- [ONTAP FlexGroup成员卷与local tier](https://docs.netapp.com/us-en/ontap/flexgroup/create-task.html)
- [ONTAP qtree与卷的关系](https://docs.netapp.com/us-en/ontap/volumes/qtrees-partition-your-volumes-concept.html)
- [ONTAP qtree创建](https://docs.netapp.com/us-en/ontap/nfs-config/create-qtree-task.html)
- [ONTAP NFS export policy规则](https://docs.netapp.com/us-en/ontap/nfs-config/add-rule-export-policy-task.html)
- [ONTAP SMB share路径](https://docs.netapp.com/us-en/ontap/smb-config/requirements-create-share-concept.html)
- [ONTAP NFS/SMB身份映射](https://docs.netapp.com/us-en/ontap/nfs-admin/how-name-mappings-used-concept.html)
- [ONTAP quota policy启用流程](https://docs.netapp.com/us-en/ontap/volumes/setup-quotas-svm-task.html)
- [ONTAP NAS数据LIF故障转移](https://docs.netapp.com/us-en/ontap/concepts/path-failover-concept.html)
- [ONTAP HA节点接管](https://docs.netapp.com/us-en/ontap/high-availability/)
- [ONTAP LIF迁移时的GARP通告](https://kb.netapp.com/on-prem/ontap/da/NAS/NAS-KBs/Does_LIF_migration_trigger_GARP)

### 9.3 对本项目的借鉴

1. **让终端用户看到明确的目录容量边界。** 参考qtree的管理体验，在Portal展示“用户目录、限额、已用量、剩余额度和更新时间”；管理员可对用户目录应用默认配额模板。当前直接使用JuiceFS目录配额即可，不必引入FlexVol/FlexGroup或qtree对象；已有目录权限仍由POSIX规则控制。
2. **分开管理逻辑额度与物理余量。** ONTAP的qtree配额不代表预留空间。本项目也应分别展示JuiceFS逻辑限额和Ceph底层可用容量；设置额度时由管理员结合Ceph副本或纠删码开销、其他数据占用和安全余量决定。即使某用户尚未用尽额度，后端满载仍会导致写入失败；是否允许总额度超售应成为明确策略。[依据：ONTAP tree quota容量边界](https://docs.netapp.com/us-en/ontap/volumes/tree-quotas-concept.html)
3. **将协议网关保留为不可信客户端的接入选项。** ONTAP通过NFS/SMB服务提供文件访问，可供本项目在不分发TiKV/Ceph凭据时参考。若需要防止客户端root伪报UID，应同时评估Kerberos或SMB身份认证，不能仅放行IP后就认为用户身份可靠；网关引入后的性能和高可用性需单独验证。

## 十、方案对比

本节按“谁能管理、客户端怎么接入、文件用户怎么识别、配额限制什么”分别比较，归纳依据见各产品章节。JuiceFS社区版与商业版单独列出；有方资料不足，列为未确认；TiKV作为当前架构的元数据后端，在第十二节说明。

### 10.1 用户管理与客户端接入

管理账号、客户端凭据和Linux文件用户承担不同职责，不能因为它们都被称为“用户”，就认为创建其中一个会自动创建或授权另外两个。

| 方案 | 谁能管理集群或文件系统 | 客户端如何接入 | 多客户端文件用户如何识别 |
|---|---|---|---|
| Weka | 内置管理账号与角色；按集群/组织范围授权 | 授权Weka用户的Token；Root organization可按文件系统关闭挂载认证 | 原生访问按统一UID/GID及POSIX权限；Weka登录账号不代替文件用户 |
| 有方 | 未确认 | 挂载指导不足以确认完整准入机制 | 未确认 |
| CephFS | CephX身份及其capability；`client.admin`为高权限身份 | 使用获授权的CephX keyring，按文件系统、路径和读写能力限制 | 原生访问按统一UID/GID及POSIX权限；CephX身份不代替文件用户 |
| BeeGFS | 受控运维人员使用管理工具；共享`conn.auth`不提供人员角色划分 | 服务和原生客户端使用同一连接密钥，客户端root须可信 | 原生访问按统一UID/GID及POSIX权限 |
| JuiceFS社区版1.4.1（当前方案） | 没有原生产品管理员账号；管理命令依赖元数据后端访问权限 | 挂载进程满足TiKV及Ceph各自的连接、认证条件 | 按统一UID/GID及POSIX权限；Portal账号是本项目另建的管理身份 |
| JuiceFS商业版/云服务 | Console账号、API凭据；具体配额角色矩阵本文未确认 | 商业版元数据服务验证访问Token，可限制来源、模式和子目录 | POSIX身份；提供UID/GID Auto Map，可将同名用户/组映射为统一内部ID |
| Lustre | 运维人员管理服务端配置，配额操作另受服务端授权检查 | LNet连通及NID策略，可结合密钥/Kerberos认证 | 统一UID/GID，或通过服务端nodemap映射不同身份域 |
| IBM Storage Scale | GUI及Management API、原生REST API及`scalectl`各有管理授权；传统命令另有权限要求 | 原生客户端安装软件、配置节点通信认证，由管理员加入集群后挂载 | 原生访问按统一UID/GID及POSIX权限；管理账号、节点身份和文件用户分别管理 |
| NetApp ONTAP | Cluster/SVM管理账号，通过RBAC限制管理范围 | NFS export policy及协议认证，或SMB身份认证与共享权限；客户端不加入ONTAP节点集群 | NFS使用UNIX身份，SMB使用Windows SID；混合访问需配置身份映射 |

表中以各节介绍的主要接入方式为准；支持NFS/SMB网关的产品还需按相应协议判断身份。统一UID/GID可通过LDAP或同步本地账号实现；Lustre nodemap与商业版JuiceFS Auto Map说明“各客户端原始UID必须相同”并非所有产品的唯一选择，但映射方式、信任前提和启用条件各不相同。[商业版Auto Map官方依据](https://juicefs.com/docs/cloud/guide/guid_auto_map/)

### 10.2 配额对象、修改权限与执行方式

目录树、project ID、fileset和qtree代表不同的计量边界；按UID/GID统计时，也必须说明是整个文件系统、指定volume，还是指定storage pool。

| 方案 | 目录或资源配额范围 | UID/GID配额范围 | 谁能修改限额 | 超限执行及主要条件 |
|---|---|---|---|---|
| Weka | 组织、文件系统容量控制及目录树配额 | 本文未确认独立UID/GID配额 | 目标组织的授权配额管理员；Regular不能修改 | 集群维护配额并限制写入；已有目录需完成后台计量，writecache可能延迟暴露失败 |
| 有方 | 未确认 | 未确认 | 未确认 | 未确认 |
| CephFS | 任意目录树，可嵌套 | 无通用原生UID/GID配额 | 挂载使用的CephX身份须具备MDS `p`能力，操作者还需满足路径权限 | MDS保存配置，客户端协作执行；恶意客户端可绕过超限停止 |
| BeeGFS | 无原生任意目录树配额 | 同一UID/GID在每个storage pool中分别统计 | 通常为能够使用连接密钥和管理工具的受信任root | management周期汇总，由metadata/storage执行；存在统计和下发间隔 |
| JuiceFS社区版1.4.1（当前方案） | 整卷及目录树，可嵌套 | 同一UID/GID在卷内跨目录统计 | 当前TiKV方案中具备可写元数据访问能力的进程；没有配额专用管理员角色 | JuiceFS客户端按元数据配额执行并周期同步计数；依赖受控客户端和后端访问边界 |
| JuiceFS商业版/云服务 | 文件系统及目录配额 | 本文未确认 | 通过Console管理；完整角色矩阵本文未确认 | 提供原生配额功能；具体执行分工及对恶意客户端的边界本文未确认 |
| Lustre | project ID对应的文件集合，可用目录继承形成项目子树 | 按文件系统中的UID/GID统计 | 获服务端授权的客户端管理进程；不是任意客户端root | QMT维护配额，metadata/storage参与统计和执行；授权能力依部署版本和配置 |
| IBM Storage Scale | 显式创建的fileset | 可按整个文件系统或每个fileset分别限额 | 通过相应GUI/API/管理命令获授权的操作者 | 文件系统配额机制执行；root默认例外等条件需核对配置 |
| NetApp ONTAP | volume内的qtree子树，不是任意深度目录 | 可限定到指定volume或其中的qtree | 对目标资源具有配额管理权限的Cluster/SVM管理员 | ONTAP服务端执行；普通NFS/SMB文件访问不授予配额修改权 |

### 10.3 对当前方案选择的结论

1. **当前需求已有直接对应的配额能力。** 对“管理员在客户端创建Linux用户及专属目录，再从Portal统一设置限额”的流程，JuiceFS社区版1.4.1的目录容量/inode硬配额已能承载；需要跨目录限制个人或组总用量时，再叠加UID/GID配额。普通文件用户不必拥有Portal账号。
2. **最需要补齐的是管理权限和后端接入控制。** 可借鉴Weka、CephFS等方案，把普通文件读写与配额修改分别授权。当前TiKV/Ceph认证只能控制各自后端的接入，不能直接代替JuiceFS配额RBAC；受控管理服务还需配合凭据保护及网络限制，才能避免普通用户绕过Portal。
3. **后续架构投入由客户端信任条件决定。** 若业务客户端root由我方管理，可优先采用统一身份、受控挂载和集中配额管理；若需要允许不可信客户端root直接接入，则另行评估带可靠身份认证的协议网关或服务端元数据授权。第十一节据此展开实施建议。

## 十一、本项目用户管理与配额管理方案

本节保留完整目标方案，包含后续普通用户个人额度页、目录查看授权和个人三级统计。**第二阶段本期仅交付管理员侧用户/目录登记及配额管理**；上述三项已后置，具体开发和验收范围以[第二阶段总开发计划](../../USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)及[配额开发计划](JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)为准。其他已列本期功能不因这次收窄而后置。

**方案总览**

1. **用户管理分为两层，身份相互独立。** 客户端Linux用户层：业务账号统一通过LDAP创建和管理，同一用户在所有获准客户端使用相同UID/GID，直接按POSIX权限读写，不增加JuiceFS ID映射。root及系统服务账号仍在各主机本地管理。Portal账号层：ADMIN负责网页上的目录登记、配额设置等管理，USER只查看授权目录的用量。Linux用户不必拥有Portal账号；TiKV/Ceph凭据另用于后端接入，不是第三套文件用户。
2. **配额由Portal集中设置，由JuiceFS执行。** ADMIN提交请求后，Portal校验权限，交给拟部署在152的常驻配额服务；该服务直接访问TiKV设置规则、回读确认并记录审计，各客户端JuiceFS负责限制超额写入。配额设置不经过152现有的统计挂载，也不让Portal参与业务文件I/O。
3. **业务挂载基线降权root，但客户端root仍在可信范围。** 所有业务挂载使用`--root-squash=<冻结UID>:<冻结GID>`，防止root经正常业务入口误操作待交付目录；独立受控管理挂载保留UID 0能力，用于创建目录、`chown`和应急修复。Portal ADMIN和受控服务也属于各自授权范围内的可信操作者。客户端root能够控制挂载或读取后端凭据，因此仍可能绕过squash或Portal修改元数据和配额，本方案不把该参数宣称为抵御恶意root的安全边界。
4. **要限制的是普通Linux用户和Portal USER取得高级操作权限。** 网页后端检查管理权限；PD/TiKV拟启用强制客户端认证，私钥及Ceph凭据仅供可信挂载或相应服务读取，防止普通用户直连后端修改配额或元数据。仅隐藏按钮、仅按客户端IP放行均不够。若客户端root也不可信，则需另行设计服务端授权或协议网关，不能沿用本方案的信任前提。

### 11.1 暂定实现路线与适用范围

**暂定采用“管理员统一维护存储身份和用户目录，152上的Portal集中管理目录配额，可信JuiceFS挂载执行文件权限和配额”的总体方案。** 保持现有JuiceFS 1.4.1＋TiKV＋Ceph数据路径，增加管理功能，不让Portal参与每次文件读写。

**身份接入路线已确定为A，配额功能仍待开发和验收。** 本期场景无需兼容已有业务账号，业务统一使用LDAP账号；LDAP及其开户流程负责分配、维护唯一UID/GID，Portal只核对和引用这些身份，不再分配第二套存储ID。B、C的设计作为历史经验保留，不要求开发映射补丁、客户端映射配置或发布工具。运维准备用户目录，Portal ADMIN将目录登记为管理对象并按需设置限额；Portal账号按需开通。

| 事项 | 第一期暂定安排 | 后续扩展条件 |
|---|---|---|
| Linux用户与存储身份 | 已确定采用A：LDAP统一业务账号；LDAP UID/GID直接用于文件权限 | 将来需兼容已有账号时再评估历史路线B/C，本期不开发映射功能 |
| Portal账号 | 复用本地账号和ADMIN/USER两种角色；文件用户可没有Portal账号 | 按需增加企业统一登录，不改变文件UID/GID |
| 配额对象 | 现有卷内的一级用户目录，例如`/users/alice` | 共享项目目录、UID/GID跨目录配额另行增加 |
| 配额执行 | 复用JuiceFS原生目录容量和inode硬限制 | 不在SQLite或页面中自行实现超限拦截 |
| 管理服务部署 | 152增加一个独立`quota-controller`进程；157不增加配额服务 | Portal高可用或自动客户端开通另行规划 |
| 挂载与客户端信任 | 业务挂载强制`root-squash`到统一专用低权限ID；独立管理挂载不启用。客户端root及挂载服务仍由可信管理员控制 | 不可信客户端root场景适用11.13节，不能仅依靠客户端挂载参数 |

第一期所说的“普通用户不能自行提高配额”，针对的是没有sudo、Docker管理、特权容器、宿主机root或挂载服务控制权的文件用户。Portal服务、配额服务和集群运维人员属于可信管理范围。

Portal与配额服务分进程运行，使Portal不直接持有TiKV凭据，并将操作限制在规定接口内；但配额服务仍信任Portal传递的管理员身份，因此不能防止已控制Portal后端的攻击者利用这些接口提交配额修改。

### 11.2 现有系统可复用能力及必须调整的部分

下表分别说明现有实现、拟调整内容及其目的。“Portal账号”用于人员登录网页；“Linux服务账号”决定程序在152上以哪个系统用户运行，两者不是同一套账号。各项调整仍属暂定设计，尚未实施。

| 事项 | 现有实现 | 拟调整内容及原因 |
|---|---|---|
| 复用门户与监控能力 | 已有Portal网页、HTTPS登录、ADMIN/USER角色、密码哈希存储及目录统计展示。 | 在现有平台增加用户目录和配额管理；集群状态、磁盘及带宽等第一阶段监控功能保持不变。 |
| 普通账号的目录查看范围 | 账号配置中的`namespaceRoots`记录获准查看的目录树标识。现有部署将示例`user`账号绑定到整个业务卷根，因此它可以查看整卷统计；不是所有USER角色天然都有此权限。 | **后续增量：** 撤销普通账号的整卷授权，显式绑定个人目录；只展示经安全采集的个人额度及最多三级明细。第二阶段本期不向新业务用户分配示例整卷root，也不新增个人查看授权或采集；第一阶段现有监控保持回归。 |
| Portal账号管理 | 账号保存在本地配置文件中，服务启动时加载；现有账号工具仅支持初始化。 | 增加Portal账号新增、禁用、密码重置和经授权的ADMIN/USER角色调整，并让程序安全加载变更后的账号配置。这里不包括主机Linux账号的创建、删除或提权，这些仍由运维人员操作。 |
| 已登录会话失效 | 登录成功后，浏览器使用Cookie中的登录凭证继续访问。当前会检查凭证签名、有效期及已加载的账号状态，但仅重置密码不会自动使此前发出的Cookie失效。 | 为账号增加可更新的认证版本，登录凭证同时记录该版本；密码重置、禁用等安全变更后，旧版本凭证不再有效，要求重新登录。目的不是增加一种用户，而是避免旧登录状态继续被使用。 |
| 自动化接口令牌 | 现有Bearer Token是一串供脚本调用API的秘密令牌；持有有效管理员令牌的请求被识别为自动化ADMIN，不需要先通过网页账号密码登录，也不代表某个具体人员账号。 | 现有自动化令牌仅保留既有监控只读用途，不能访问新增的用户、目录、配额或审计读写接口。新增管理接口要求有效个人ADMIN会话，以明确记录操作者；这里不存在“新管理员”和“旧管理员”的身份区别。 |
| 服务使用的Linux账号 | 部署模板中的Portal、Prometheus/Grafana、统计挂载及采集器共同使用152上的Linux账号`jfsportal`。多个进程同属一个系统用户，难以仅靠文件所有者区分它们的访问权限。 | 拟让网页后端使用独占Linux账号`jfsweb`，统计挂载及采集器使用`jfsstats`，配额服务使用`jfsquota`；Prometheus/Grafana可暂保留原账号。配合文件权限和服务访问限制，禁止网页后端读取配额服务私钥、直接修改其管理数据；不改变人员登录Portal所用的账号。 |
| 现有SQLite统计库的访问权限 | SQLite把数据保存在152本地数据库文件中。采集器定期写入目录路径、容量、文件数量和采集时间，网页查询这些记录，避免每次访问都扫描文件系统。网页程序打开数据库时指定只读，但这只是该数据库访问句柄的限制，不等于Linux禁止该进程修改底层文件。 | 结合服务账号分离，限制数据库文件及所在目录的写权限：统计服务负责更新，网页后端只能读取发布的统计数据，不能直接改写、删除或替换文件。保留“后台采集、页面查库”的方式，不保存业务文件内容。 |
| 新增配额设置入口 | 现有Portal没有配额修改接口，也没有专门执行配额管理的服务。 | 拟在152增加后台常驻的配额服务。Portal检查ADMIN身份后提交请求；配额服务校验目录和额度，直接调用JuiceFS元数据接口设置TiKV中的规则并回读确认。它不经过统计挂载；各客户端JuiceFS仍负责实际拒绝超额写入。 |
| 新增SQLite存储管理库 | 现有目录统计库未记录受管目录身份、配额修改任务及审计过程。 | 本期由配额服务维护独立SQLite存储管理库，保存LDAP身份引用、已登记目录的卷UUID/inode/实际owner、配额和用量观测，以及修改人、修改前后额度、时间和结果；个人查看授权记录留待后续。它不分配LDAP UID/GID，也不替代文件权限。只有`jfsquota`直接读写数据库；Portal通过Unix Socket请求查询或执行。真正的owner、权限和配额规则仍在TiKV，修改SQLite记录本身不会改变文件访问权或限额。 |
| 配额页面的统计口径 | 现有`summary`目录统计用于展示空间占用和文件数量，不是配额查询接口，也没有提供配额上限及对应计数。 | 新增配额页通过JuiceFS原生配额接口读取上限及已用容量、inode数，按相同计量口径计算剩余额度；不直接套用现有目录统计字段。该项解决配额数字的来源和含义，与上面的目录查看权限调整分开处理。 |

现有代码依据：[认证实现](../../../../api/internal/portal/auth.go)、[路由与Bearer处理](../../../../api/internal/portal/server.go)、[目录授权与快照读取](../../../../api/internal/portal/namespace.go)、[控制挂载unit](../../../../deploy/systemd/juicefs-namespace-mount.service)、[部署目录范围](../../../../configs/namespace-roots.prod.json)。

### 11.3 角色、身份与权限

本节按账号所属系统说明权限，不把自然人、账号角色和服务程序放在同一类“操作者”中。自然人通过账号发起操作，程序以其运行时的Linux身份执行；同一个人可以分别持有Linux账号和Portal账号，两者的权限独立。

#### 11.3.1 Linux账号：主机操作、文件访问与进程运行

下面均为Linux账号；前两类供人员执行主机或文件操作，后三类是拟用于后台服务的专用账号，不供普通人员交互登录。

| Linux账号类别或示例 | 用途 | 权限范围与边界 |
|---|---|---|
| 主机管理账号：`root`或获准执行特定sudo命令的账号 | 供运维人员管理150～152及获准客户端上的账号、目录、挂载和服务 | 按所在主机及实际授权执行操作；业务挂载会把UID 0映射为专用低权限ID，只有受控管理挂载保留文件管理能力。客户端root仍可控制挂载或取得本机凭据，属于可信管理范围。Linux管理权限不自动产生Portal登录账号。 |
| LDAP业务账号：例如`alice`，UID/GID为`50001:50001` | 供业务人员登录获准客户端并通过JuiceFS挂载点读写文件 | 各客户端使用相同UID/GID及组关系，按POSIX权限访问并受配额限制；不得取得后端私钥或控制挂载服务。其Linux账号不自动成为Portal账号。 |
| `jfsweb`（拟新增） | 运行152上的Portal网页后端 | 读取允许展示的数据，通过受控接口提交管理请求；不直接持有TiKV凭据，也不直接改写存储管理库。 |
| `jfsstats`（拟新增） | 运行152上的专用统计挂载和目录采集器 | 持有统计挂载所需的后端访问凭据，执行目录统计并更新统计数据库；属于受控服务账号，不能交给普通业务用户使用。该名称表示目录统计服务账号，不是Linux namespace机制。 |
| `jfsquota`（拟新增） | 运行152上的配额管理服务 | 持有TiKV访问凭据，执行规定的配额管理操作并维护管理库和审计；不需要Ceph凭据。TiKV本身不会将该账号的凭据限制为“只能修改配额”，因此其进程和私钥必须受保护。 |

服务程序不是另一类用户。运维人员可以用root启动服务，但服务进程实际使用哪个Linux账号，由其运行配置决定；例如systemd配置`User=jfsquota`后，配额服务以`jfsquota`而非启动命令的root身份运行。业务客户端的JuiceFS挂载则由可信root或获准的专用服务账号运行，代普通业务用户连接后端，并按文件请求中的UID/GID检查权限。

#### 11.3.2 Portal账号：网页操作授权

ADMIN和USER是赋给Portal登录账号的角色，不是Linux账号名称，也不是自然人的身份。

| Portal账号所赋角色 | 暂定允许的网页操作 | 不因此获得的权限 |
|---|---|---|
| ADMIN | 本期登记存储用户及已有目录、设置或调整配额、查看管理记录，以及经授权的Portal账号管理；个人目录查看授权分配留待后续 | 不自动取得152或157的root权限，不直接获得TiKV/Ceph凭据，也不通过网页创建主机Linux账号。 |
| USER | 本期保留第一阶段既有只读监控；后续才按显式绑定目录查看个人额度、用量及经验证的三级明细 | 不能修改配额、查看其他用户目录或调用管理员接口；Portal查看授权不授予Linux文件读写权限。 |

例如，运维人员通过LDAP管理工具创建Alice的业务账号，在受控管理挂载上准备目录，再用自己的Portal ADMIN账号登记目录、设置额度。Alice在获准客户端使用LDAP账号`alice`读写文件；本期无需为她开通Portal账号。后续若开放个人网页查询，再单独开通Portal USER账号并绑定其目录。

管理员在网页提交请求时，Portal记录其个人登录账号；实际后端操作由相应Linux服务账号运行的程序执行。审计应保留这两者的区别，不能把所有配额变更都只记为`jfsquota`操作。

#### 11.3.3 账号关联与多客户端一致性

本期LDAP中的UID/GID就是文件系统使用的存储UID/GID，不存在另一套客户端到存储的数字映射。在受管身份域内，同一个UID跨客户端、跨JuiceFS卷代表同一个用户；同一个共享组的GID可以被多个用户使用，不能给每个用户的GID都加唯一约束。Portal保存经核对的LDAP身份引用，不重新开户或分配数字ID。

本期没有已有业务账号迁移，但仍需为LDAP业务账号预留非零UID/GID范围，避开root、系统及服务账号；客户端后续本地开户不得占用该范围。新客户端通过NSS/SSSD接入LDAP后，用`id`、`getent`及实际业务进程核验身份和组关系。LDAP不会自动盘点所有客户端，范围管理和冲突检查仍由运维负责。

第一期保留“一名Linux业务用户对应一个受管私有目录”的默认关系，Portal账号单独保存。个人Portal USER账号默认只授予其显式绑定的个人目录查看权；共享项目或额外委托查看必须由ADMIN明确授权，不能根据用户名相同、同GID或路径前缀自动推断。停用后的UID和资源记录保留，数据未移交前不回收编号。

#### 11.3.4 多客户端root的处理

- 各主机保留本地`root`（UID 0），不将root作为LDAP业务账号，也不修改主机上的UID 0。所有业务挂载必须通过JuiceFS `--root-squash`把经该挂载发出的UID 0请求映射到同一专用、禁止登录的低权限数字身份；参数值在部署前完成冲突检查并冻结。
- 所有获准客户端的root均由可信运维控制。UID相同不表示密码或SSH密钥必须相同；各主机单独管理登录权限，日常可使用个人运维账号加受控sudo保留操作记录。普通业务账号不得取得完整sudo或其他root等价权限。
- 业务挂载中的root按低权限身份检查，不能正常进入root拥有的0700待交付目录或执行任意`chown`。独立管理挂载不启用squash，仅供可信运维创建目录、交付owner和应急修复；152统计挂载不复用为管理挂载。
- `root-squash`是客户端挂载配置。root仍可去掉参数重挂载、让进程以其他UID运行或使用本机可读取的TiKV/Ceph凭据。因此LDAP和squash均不改变客户端root可信的架构前提；日常配额修改统一经Portal，root应急修改后核对并补录审计。

### 11.4 部署位置与请求流向

```text
管理员/普通用户浏览器
    └─ HTTPS :8443 → 152 Portal（jfsweb，拟新增）
                       ├─ 只读 → 原有监控接口、目录统计SQLite
                       └─ 配额查询／ADMIN管理请求／查看权限校验
                                      ↓ Unix Socket
                           152 quota-controller（jfsquota）
                              ├─ 读写 → 存储管理SQLite及操作审计
                              └─ JuiceFS元数据接口 → PD/TiKV 150～152

157及其他获准客户端
    └─ Linux用户 → 已受控的JuiceFS挂载
                        ├─ 元数据 → PD/TiKV 150～152
                        └─ 文件内容 → Ceph 150～152
```

暂定由Linux服务账号`jfsquota`运行配额管理服务，由`jfsstats`运行统计挂载和目录采集器，由Portal独占的`jfsweb`运行网页后端；Prometheus/Grafana可暂时继续使用原有服务账号，避免顺带重部署监控组件。`jfsweb`由网页后端独占，是Unix Socket根据对端UID识别Portal进程的前提，不能让其他进程以同一UID取得配额调用权。实施账号分离时还要同步调整文件所有权、目录权限和systemd访问范围，不能只修改unit中的`User`字段。

配额服务仅需访问TiKV元数据，不配置Ceph keyring，也不访问JuiceFS文件内容；但它仍是持有高权限元数据访问能力的可信服务。

存储管理数据库位于152系统盘的独立目录，例如`/var/lib/juicefs-quota/`；凭据位于独立受保护配置目录。`jfsquota`直接读写数据库，`jfsweb`对数据库文件和目录都没有访问权，只能通过本机Unix Socket调用规定接口。这样无需额外生成只读SQLite副本，也不需要处理副本切换和长期堆积。各类数据的权威来源、访问权限、备份和生命周期统一见11.8节。

不新增对外配额服务端口，不要求Portal持有157的SSH私钥，不由Portal执行`useradd`、`chmod`或任意远程命令。152上的Portal/配额服务停止只影响相应管理功能，已有客户端的数据I/O和已保存配额继续由存储系统处理；152整机故障还会影响同机PD/TiKV/Ceph，业务能否继续取决于当时的集群健康与冗余，不能作同样保证。

### 11.5 用户开通、使用与停用流程

成熟文件存储处理多客户端身份一致性通常采用以下三条路线。三者都仍需确认“不同机器上的账号是否属于同一个人”；区别在于确认后统一客户端身份、按名称自动生成内部映射，还是保存客户端范围内的显式映射。

| 路线 | 机制及既有账号处理 | 优点 | 缺点与适用限制 | 本项目位置 |
|---|---|---|---|---|
| A．统一客户端UID/GID | 通过LDAP/AD/NIS或配置管理，让同一用户在所有客户端使用同一数字身份。一般场景的既有账号冲突需要迁移或另建账号；本期部署没有这一兼容需求。 | 使用上游JuiceFS社区版和标准POSIX权限，不改数据路径代码；身份、登录和组关系可由成熟目录服务集中管理。 | LDAP/AD不会自动发现或修复各客户端的冲突，仍需预留ID范围、核验接入并约束后续本地开户。 | **已选定。** 本期统一经LDAP创建业务账号，流程见11.5.1节。 |
| B．按用户名/组名自动映射 | 以JuiceFS商业版UID/GID Auto Map为代表：同名用户和组映射为统一内部ID，挂载时再转换为本机UID/GID。本项目曾规划由名称登记和本机NSS解析生成映射，复用C的转换核心。 | 不必逐客户端手填每个数字ID映射，也不要求同一用户的本地UID/GID相同；对“名字一致、数字不同”的存量账号较友好。 | 同名账号必须确属同一人，同名组也需确认；不同名称不自动合并。社区版没有可直接开启的等价能力，自研仍需验证和维护，不能宣称与商业版完全一致。 | **历史备选，本期不实施。** 保留11.5.2节及[路线B开发计划](../juicefs-user-id-mapping/JUICEFS-NAME-AUTO-MAPPING-DEVELOPMENT-PLAN-20260922.md)；官方机制见6.4节。 |
| C．按客户端显式映射 | 以Lustre nodemap和本项目曾规划的能力为代表，按`client_id＋本地UID/GID`映射为统一存储UID/GID。既有账号、名称和数字ID可以保持不变；管理员明确登记同一人跨客户端的对应关系。 | 能处理“同一人跨机ID或名称不同”和“不同人跨机使用相同本地ID”，不要求迁移客户端既有账号。 | 需要可信客户端标识、映射发布、正反向权限验证及审计；需修改并长期维护JuiceFS源码，升级和撤销成本较高，也不能约束恶意客户端root。 | **历史备选，本期不实施。** 保留11.5.3节及对应开发计划，后续有存量账号兼容需求时再评估。 |

本期只执行路线A；B、C流程保留历史设计，**不要求LDAP用户再做客户端映射，也不为本期预建映射字段或发布工具**。以下Portal登记、配额服务及新增接口仍待开发，不代表已经上线。

#### 11.5.1 路线A：LDAP/AD统一存储账号

本节保留基本流程，实施注意点以[路线A文档](JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md)持续更新。当前流程使用目录系统的管理工具开户；后续Portal直接管理LDAP账号属于另一个待细化的集成层次，不通过客户端助手逐台创建本地账号。

**开通流程**

以LDAP业务账号`alice`、统一UID/GID为`50001:50001`为例，数字仅为示例：

1. **在LDAP创建业务账号。** 运维人员先预留避开root及系统服务账号的ID范围，通过LDAP管理工具创建`alice`，配置唯一UID、主GID、附加组和登录策略。ID由统一开户流程管理，Portal不另行分配。
2. **接入并核验客户端。** 各客户端root配置NSS/SSSD及登录授权，用`id`、`getent`和实际登录后的进程核验Alice均为`50001:50001`及正确附加组。不在各机`/etc/passwd`重复创建Alice；本地root及服务账号保持独立管理。
3. **按需登记Portal管理信息。** ADMIN通过拟新增的`POST /api/v1/admin/storage-users`选择LDAP中的Alice；`jfsweb`经152本机Unix Socket交给`jfsquota`，由后者通过受控只读LDAP查询核对账号、UID/GID后写入存储管理库。通过`PUT /api/v1/admin/storage-users/{id}/identity-status`记录客户端核验结果。不接受另填一组与LDAP不同的存储ID，也不通过该接口在LDAP开户。
4. **交付目录。** 按11.6.1节准备目录、按需登记和设置配额，然后把`/users/alice`交给Alice使用。需要网页查询时，另建Portal USER账号并显式授予目录查看权，不按用户名自动授权。

**使用流程**

Alice以LDAP账号`alice`登录获准客户端，或者由任务调度系统以该账号启动训练、推理进程。不同客户端上的进程均使用统一UID/GID，直接通过JuiceFS挂载访问；共享模型按组权限只读，个人目录按owner和权限读写，并受已配置的配额约束。业务容器或调度作业也须使用同一数字身份，不能另起一套不受管的UID。

访问限制依靠统一数字身份、目录权限/ACL及后端凭据保护落实。LDAP管理登录身份，不代替JuiceFS文件权限检查，也不阻止持有TiKV凭据的人直接修改元数据。

**新增客户端与账号变更**

新客户端先完成上述冲突检查和目录服务接入，核验身份、组关系及访问权限后，再开放受控挂载；后续本地开户也必须避开保留的存储ID范围。修改密码、登录策略或显示名不改变存储UID。统一存储UID/GID的变更会涉及文件owner及所有客户端，必须作为独立迁移处理。

**停用流程**

目录管理员通过LDAP管理工具禁用业务账号或撤销其获准登录范围；运维人员核查客户端认证缓存、已有会话、SSH密钥登录及运行中的任务。LDAP账号禁用不使既有进程和打开的文件立即失效，需要按业务确认停止任务并核验新的登录被拒绝。数据、配额和Portal账号按11.5.4节分别处理，不联动删除本地root或服务账号。

本期不实施已有业务账号迁移；若后续引入必须保留原账号的客户端，再重新评估下面的历史路线B/C。

#### 11.5.2 路线B：按用户名和组名自动生成映射

> 历史备选：以下为此前设计，本期采用路线A，不实施本节流程。

**保留各客户端的原账号和UID/GID，管理员确认同名身份后，由工具自动生成数字映射。** 本路线已制定[名称自动映射开发计划](../juicefs-user-id-mapping/JUICEFS-NAME-AUTO-MAPPING-DEVELOPMENT-PLAN-20260922.md)，尚未实现；借鉴商业版的使用效果，不直接使用其代码或承诺内部ID兼容。B与C共用JuiceFS双向映射核心，区别在于配置由名称解析生成，还是由管理员逐条登记。

**开通流程**

以A上的`alice`为UID 10001、B上的`alice`为UID 20001，两者属于同一人、统一存储UID为50001为例：

1. **确认名称与使用范围。** 运维核对各客户端的同名账号确属同一人，同名组确属同一业务组，并确定获准客户端名单。不同人同名时不合并；同一人使用不同名称时，首期改走C显式映射，不自动猜测。
2. **集中登记名称并分配存储ID。** 首期由运维使用拟开发的集中登记工具，保存用户名/组名、存储UID/GID及获准客户端范围；用户和组分别分配，已有存储ID继续沿用。后续Portal集成后由ADMIN维护这些记录，写入同一存储管理库，不新增另一套身份数据库。
3. **自动解析并生成本机配置。** 运维在获准客户端运行配置工具，通过Linux NSS身份查询接口，按名单读取本地或集中身份源中的用户名、组名及数字ID，核验重复、缺失和歧义。工具为A生成`10001 → 50001`、为B生成`20001 → 50001`；管理员不必逐台填写这些数字关系。失败时不生成可加载的残缺配置，也不把本地数字原样透传。
4. **部署、加载和验证。** 运维部署本机专属配置及定制JuiceFS，核对client_id、配置版本和实际加载结果。在受控入口验证同一人跨机访问、其他用户拒绝访问、文件owner正反向显示及组权限，通过后再开放业务。已有挂载变更按维护窗口停任务、排空并正常重挂载，不能仅改Portal记录。
5. **登记用户目录。** 身份准备完成后，按11.6.1节登记目录资源，按需设置配额和Portal查看授权。名称映射不自动创建业务目录，也不按同名关系创建或授权Portal账号。

**使用流程**

Alice仍用原Linux账号登录和启动任务。A上的JuiceFS把请求UID 10001转换为存储UID 50001，B把20001转换为同一个50001；文件元数据始终保存50001，查询时分别返回本机的10001或20001。B上的另一用户`charlie`即使使用本地UID 10001，也应按其独立登记转换为另一存储UID，不能因此访问Alice的私有文件。

名称只在配置生成和挂载前解析，业务IO只查询挂载进程内的数字映射，不逐次访问NSS、LDAP或Portal。主组和附加组分别转换，且仅使用进程实际持有的组，不因账号库新增组成员关系就给旧进程追加权限。模型共享、个人目录权限和卷接入仍单独配置。

**新增客户端、改名与停用**

- 新客户端先核对同名身份及允许范围，再自动生成配置；client_id、名称记录和存储ID持久保存，IP变化或正常重连不重新分配身份。
- 用户或组改名经确认后保留原存储ID；本地数字变化需重新生成并验证配置。删除账号后将同名或同号交给新人，必须先撤销原映射，不能让新人自动继承历史文件权限。
- 首期配置在挂载生命周期内固定，新增、调整及撤销都可能需要影响同挂载其他用户的维护窗口。停用时从允许范围移除身份，停止相关存储任务并更新所有获准客户端的挂载；完成拒绝访问验证后才确认撤销，不能仅删名称记录。
- 原Linux账号、文件和配额不会因停用映射而自动删除；已有数据也不会因启用名称映射自动转换owner。数据、配额和Portal账号按11.5.4节分别处理。

“自动”减少的是数字配置工作，不代替人员归属确认，也不限制可信客户端root。具体实现范围、未知owner和缓存权限检查、开发阶段及工作量以路线B开发计划为准。

#### 11.5.3 路线C：保留原有账号，按客户端显式映射

> 历史备选：以下为此前设计，本期采用路线A，不实施本节流程。

**以下展开路线C，需要先完成开发和验收，目前不能直接执行。** 它保留各客户端已有Linux账号和业务运行方式，由每台客户端上的定制JuiceFS加载本机专属映射，在FUSE边界完成本地UID/GID与卷内存储UID/GID的双向转换。映射不在Portal、TiKV或Ceph服务端执行，文件IO也不经过Portal。具体实现范围见[账号映射特性开发计划](../juicefs-user-id-mapping/JUICEFS-USER-ID-MAPPING-DEVELOPMENT-PLAN-20260921.md)；路线B自动生成同类配置，但不改变这里的IO转换位置。

```text
集中映射台账 → 为每台客户端生成配置 → 本机JuiceFS加载
                                            ↓
本地进程UID/GID → 内核通过FUSE请求传给JuiceFS → 定制JuiceFS映射为存储UID/GID并处理权限 → TiKV/Ceph读写
```

目标形态由Portal ADMIN维护集中台账；最小原型和受控试点阶段可以先用同一份受保护登记文件及离线工具生成配置，再由运维人工部署。各客户端不自行分配存储ID，也不互相同步映射。

**身份映射与卷授权的边界**

身份映射只回答“这个客户端上的本地用户对应哪个统一存储身份”。用户能够访问哪个JuiceFS卷及其中哪些目录，则由该卷是否在客户端受控挂载、后端接入凭据、挂载点权限以及卷内POSIX权限/ACL共同决定，不通过给同一用户分配不同存储UID来实现。卷UUID仍用于标识卷、目录、配额和挂载实例等资源，但不改变“存储UID 50001始终代表Alice”的身份含义。

**开通流程**

1. **登记受管客户端。** 首次纳管时为机器生成持久的`client_id`，用于关联其配置和审计；IP和主机名只作为可更新的联系信息。正常断线、重启和重挂载继续使用原记录和映射，不重新分配存储ID。重装、配置丢失或机器替换时由管理员确认恢复原记录还是建立新记录。`client_id`是管理标识，不随每次IO发送给TiKV，也不是能够防范可信root伪造的服务端身份凭据。
2. **确认人员与本地账号。** 运维人员核对各客户端上的账号实际属于谁，不根据用户名相同或UID相同自动合并。例如A上的Alice本地UID为10001、B上的Alice为20001，可以映射到同一存储UID 50001；B上的Charlie即使也使用本地UID 10001，仍应映射到另一个存储UID 60001。GID和附加组分别核对。
3. **集中分配存储身份。** 一个存储UID在当前受管身份域内只能代表一个用户；同一用户可从多台客户端映射到该UID，也可在多个JuiceFS卷中继续使用同一存储UID/GID。目标形态由Portal ADMIN登记`client_id＋本地UID/GID → 统一存储UID/GID`的关系，管理库通过唯一约束防止两个不同用户误用同一存储UID。卷UUID不进入身份映射键；数据库内部主键只关联目录、配额和审计，不参与文件权限判断。
4. **生成并部署本机配置。** 管理端从中央台账分别生成A、B的配置。所有客户端可以运行同一版本的定制JuiceFS，但加载的配置不同。身份配置至少绑定预期client_id、版本和UID/GID双向映射，由可信root部署到受保护目录；同一客户端获准挂载多个卷时可以复用同一套身份映射。映射模式默认拒绝未登记普通身份，不能把未找到的本地数字原样透传，也不能保留普通用户可访问的无映射原始挂载。
5. **加载并核验。** 首期映射在一次挂载生命周期内固定。运维暂停受影响任务并排空写入，正常卸载旧挂载、部署配置并重新挂载，然后分别核对进程实际加载的client_id、映射版本和配置哈希，以及挂载实际连接的卷。测试获准用户能访问、其他用户被拒绝、卷内真实owner正确、客户端显示owner正确、共享模型可读不可改，全部通过后再恢复业务。
6. **关联并交付用户目录。** 映射准备完成后，按11.6.1节单独登记目录资源、设置配额并核验；管理端使用存储UID核对真实owner，普通客户端看到转换后的本地UID。需要网页查询时再单独绑定Portal USER账号。

**使用流程**

Alice继续使用原来的本地账号、原UID/GID及任务启动方式。A上的Alice以本地UID 10001创建文件时，本机JuiceFS转换为存储UID 50001，卷内文件owner保存为50001；她在B上以本地UID 20001访问时，B上的JuiceFS同样转换为50001，因此获得同一用户的文件权限。若Alice还获准使用另一个JuiceFS卷，该卷中的Alice文件也保存owner 50001；能否进入该卷或目录仍由独立的卷接入和文件权限决定。查询属性时，B再把存储owner 50001显示成本地owner 20001。应用访问其他本地文件系统仍使用原身份。

客户端接入凭据只能说明该挂载获准连接后端，不能证明当前操作人是Alice。具体用户身份链是“Linux登录或任务启动得到本地UID/GID → 本机JuiceFS按已批准配置转换 → 使用存储UID/GID进行文件权限处理”。不同客户端上的同名、同号账号不会自动获得同一权限；同一客户端上的用户也不会被合并成一个身份。

目录配额仍作用于原JuiceFS目录，不由映射模块重新计算。配额服务直接访问元数据时使用存储ID，不把某台客户端显示的本地UID用于核对全局owner或设置UID配额。

**配置状态与访问生效**

Portal或集中工具分别记录以下状态，避免把管理记录误当作文件权限：

| 状态 | 含义 |
|---|---|
| 已登记 | 中央台账保存了拟修改关系，对现有挂载无影响 |
| 已部署 | 配置已到客户端磁盘，旧进程仍可能使用旧版本 |
| 已加载 | 新挂载已校验并加载配置，新规则从此开始影响访问 |
| 已验证 | 正向访问、越权拒绝、owner及版本均已核验，可按部署安排恢复业务 |

实际放行点是客户端JuiceFS加载映射后的权限处理，Portal状态字段本身不能允许或拒绝文件访问。若要求验证前用户不能手工访问，还需在本地保持挂载入口受限，验证后再开放。

**新增客户端与映射变更**

新客户端登记本地账号并从中央台账生成专属配置，经上述流程验证后接入；不要求已有UID与其他客户端一致。正常重连复用持久配置，不产生新的身份。若映射文件丢失且不能可靠恢复，应停止挂载，不能猜测映射或退回本地UID原样访问。

新增用户、改变组映射或撤销映射时，首期均需按维护窗口更新配置并重挂载，因此可能影响同一挂载上的其他用户。映射变化不会自动修改已写入文件的存储owner。不得为迁就一台机器直接更换存储ID或递归`chown`共享目录；替换回原版客户端也不能视作无影响回退。若本地账号删除后同一UID分给另一个人，必须先撤销旧映射，不能只看到数字相同就延续原权限。

**停用流程**

撤销某个用户在某台客户端的存储访问时，运维人员先停止其相关任务，删除该机对应映射，完成正常重挂载并验证未登记身份返回权限错误。全局停用需要覆盖所有已授权客户端；只要还有一台未完成，就不能标记为全局生效。原本地账号可以继续用于其他业务，不因撤销JuiceFS权限而禁用、删除或改号。

磁盘上的配置已修改但旧挂载仍运行时，访问权限尚未改变；lazy unmount及仍被引用的旧FUSE连接也不能作为撤销完成的依据。已打开文件、缓存与旧连接的行为必须在原型和回归中验证。若配置回退会重新授权刚被撤销的用户，就不能自动回退并宣称撤销成功。数据、配额和Portal账号按11.5.4节分别处理。

该方案仍信任客户端root：root可控制客户端程序、配置及后端凭据，不属于映射能够约束的普通用户。映射解决受管普通用户的跨客户端数字身份冲突，不会自动限制root设置配额，也不提供面向不可信客户端的服务端逐用户认证。

#### 11.5.4 各接入路线共用的停用、移交与核验要求

- **Portal账号与文件身份分别停用。** 撤销网页会话和查看授权不等于停止Linux登录或文件IO；反之，停用存储访问也不会自动撤销Portal查看授权，应按需求分别处理。
- **保留配额与数据。** 停用默认保留目录、配额、存储ID和审计。JuiceFS配额中的0通常表示不限额，不能用“额度设0”代替禁用用户；数据未移交前不回收存储ID。
- **移交或删除单独确认。** 先确认业务、备份及owner/权限调整，再撤销或重绑资源。删除目录、撤销配额、删除账号和回收ID不是同一动作，不提供一键级联删除。
- **身份核验覆盖实际访问范围。** 使用`allow_other`等多用户挂载时，需要覆盖能够到达挂载点的本地、集中及服务进程身份，保留正确的POSIX权限检查；不为开通用户放宽私有目录，不照搬152统计控制挂载的特殊配置。
- **名称变化不等于身份变化。** 修改Portal显示名不改owner。UID/GID迁移另行处理；目录改名或删除重建需重新核验卷UUID和inode，不能只因路径相同沿用旧绑定。
- **操作仍由获准运维执行。** Portal记录核验人、客户端、版本和停用结果，不越权创建Linux账号、结束157进程或重挂载。各接入路线都依赖可信挂载与后端凭据保护，不能在普通用户仍可绕过挂载直连未认证TiKV时宣称已具备完整隔离。

机制依据与替代路线见[用户ID映射子调研](USER-ID-MAPPING-SUBRESEARCH-20260920.md)；映射的实现范围、风险与分阶段验收分别见[路线B名称自动映射计划](../juicefs-user-id-mapping/JUICEFS-NAME-AUTO-MAPPING-DEVELOPMENT-PLAN-20260922.md)和[路线C显式映射计划](../juicefs-user-id-mapping/JUICEFS-USER-ID-MAPPING-DEVELOPMENT-PLAN-20260921.md)。

### 11.6 配额接入、规则、容量预算与统计口径

#### 11.6.1 目录资源登记与配额接入

第一期为固定卷中的一级用户目录设置容量和inode硬限额。**LDAP负责业务身份，POSIX负责文件访问，Portal负责集中管理目录配额；不依赖B/C映射开发。** 以LDAP账号`alice`（UID/GID `50001:50001`）、目录`/users/alice`和100 GiB为例：

1. **准备目录。** 可信运维人员在独立、未启用`root-squash`的受控JuiceFS管理挂载上，用root创建尚不存在的`/users/alice`，创建时即设为`root:root`、0700；父目录`/users`由运维管理，不允许业务用户创建、替换他人的目录。此时普通业务用户不能进入或写入；其他客户端的root通过基线业务挂载时也会被映射为专用低权限身份，不能访问或误操作该目录。只有受控管理挂载保留UID 0访问能力。已有目录只核对路径、owner、用量和配额，不自动改owner或搬数据。
2. **登记资源。** ADMIN在Portal选择已配置的卷和目录路径。`jfsquota`读取实际卷UUID、目录inode及owner，保存到存储管理库，将目录加入管理列表；owner是LDAP用户时显示相应用户名。对尚未交付的空目录，实际owner仍记为root，另记录拟交付的LDAP用户Alice，不提前把实际owner写成Alice。登记不创建目录、不改权限、不设置配额；数据库只保存管理记录，文件权限以JuiceFS元数据为准。
3. **设置配额。** ADMIN提交100 GiB及所需inode上限；`jfsquota`检查用量和预算，调用JuiceFS原生接口设置TiKV中的规则并回读确认。若要求目录首次使用即受限，失败或结果未确认前不交付给业务用户。明确选择暂不限额的目录可跳过此步。
4. **交付使用。** 新目录由可信运维人员将owner改为LDAP中的`50001:50001`，保持0700；已有目录保持经核对的owner。控制器重新读取同一卷、inode、实际owner及配额状态，更新登记记录并确认交付。POSIX权限变更才开放文件访问，Portal状态本身不控制文件IO；交付后的意外owner变化仍需人工复核。
5. **按需开通网页查询。** ADMIN将目录查看权授予指定Portal USER账号，只影响网页展示，不改变Linux文件权限。没有Portal账号不影响文件使用；各客户端JuiceFS按原生配额限制超额写入。

目录登记与配额设置相互独立：需要由Portal管理的目录，即使暂不限额，也可以登记；不需要Portal管理的目录无需登记，仍可正常使用。管理库记录的是Portal管理对象及查看授权，不替代POSIX权限，也不要求复制所有目录与用户的归属关系。

目录处理方式分为两种：

| 目录处理方式 | 当前状态 | 处理动作 |
|---|---|---|
| `new` | 新建空目录，root拥有、0700，尚未交付 | 需要初始配额时先确认配额，再改为LDAP用户拥有；不设配额时可直接交付 |
| `adopt_existing` | 目录已经存在并可能包含数据 | 核对owner、用量和已有配额；需要准确切换时暂停写入 |

既有目录owner与拟登记的LDAP用户不一致时，先确认归属，不以网页登记代替`chown`。新建空目录交付前的root owner是预期状态，必须与交付后的意外owner变化区分。业务挂载的`root-squash`用于防止正常入口上的root误操作，不能阻止可信root控制挂载配置或走管理入口。

#### 11.6.2 配额规则、容量预算与统计口径

| 项目 | 具体规则 |
|---|---|
| 管理范围 | 固定卷的`/users/<name>`一级目录；首期不管理卷根、回收站和任意嵌套目录 |
| 容量和inode | 页面以GiB和inode数输入；内部保存整数bytes和整数inode。inode包含文件和目录 |
| 设置与降低额度 | 首期只接受正值，不提供取消已有配额操作；不把0作为禁用用户。降低额度前刷新用量，拒绝低于观测用量的值；并发写入仍可能使设置后的用量超过新上限，要求精确切换时暂停写入 |
| 配额叠加 | 一次写入必须同时满足卷级配额、从卷根到目标路径的各级目录配额，以及文件最终owner对应的UID/GID配额；容量和inode也分别检查。不是简单取各配置上限中的最小数字，而是比较每项限制当时的剩余量，最先耗尽的限制先阻止写入。设置前读取并在页面列出这些同时生效的限制 |
| 逻辑分配预算 | 每个卷设置管理预算；受管目录容量上限之和默认不得超过预算。该预算不是Ceph物理空间预留 |
| 用量来源 | 容量和inode用量读取JuiceFS quota接口，不使用目录top 100、`du`或Ceph raw used替代 |
| 告警 | Portal按可配置阈值提醒，例如80%和90%；告警不改变JuiceFS硬配额 |

逻辑分配预算由管理员根据Ceph可用空间、存量数据和安全余量确定。Portal分别显示已分配额度、JuiceFS配额用量和Ceph后端余量；后端容量不足或数据过期时，暂停新增和增额操作。

例如，父目录`/users`配额为1 TiB、已经使用900 GiB，剩余124 GiB；子目录`/users/alice`配额为200 GiB、已经使用50 GiB，剩余150 GiB。Alice继续向子目录写入时，父子两级都会计数，因此当前最多只能再写约124 GiB，先触发父目录限制。反过来，如果父目录剩余500 GiB而Alice目录只剩20 GiB，则先触发Alice目录限制。即使子目录配置的总额度大于父目录也允许设置，但不能越过父目录当时仍可用的剩余额度。UID/GID、卷级配额和inode限额按同样原则参与约束。[JuiceFS官方嵌套配额说明](https://juicefs.com/docs/community/guide/quota/#nested-quota)

JuiceFS配额计数可能存在短暂延迟，删除、回收站、硬链接和跨目录移动也会影响用量。页面展示采集时间，不承诺字节级零超额；只有计数异常时才由运维执行深度检查或修复。[JuiceFS官方配额与计数说明](https://juicefs.com/docs/community/guide/quota/)

### 11.7 配额服务和API设计

`quota-controller`是运行在152的普通Go服务，通过Unix Socket接受Portal请求，核对连接进程身份，只执行登记、读取、设置配额、授权绑定和审计等固定动作。固定卷及元数据连接由root管理的配置提供；浏览器不得提交META URL、Ceph配置、可执行文件名或shell命令。

`quota-controller`内部增加一个很小的Go适配模块，直接复用与交付二进制同版本的JuiceFS源码`meta`包，只封装“读取目录属性、查询配额、设置配额和回读确认”等固定操作，并向控制器返回bytes、inode等精确整数及结构化错误。它不是新数据库、不是新的常驻代理，也不经过业务文件IO；作用只是让配额服务安全、稳定地调用JuiceFS已经实现的元数据逻辑，避免自行理解TiKV中的内部Key/Value格式。

当前候选源码中的`quota`命令本身也是调用`meta.HandleQuota`，但默认输出面向人工查看的表格。表格格式可能变化，容量显示还可能经过单位换算和四舍五入，不适合Portal做预算、并发版本比较及回读确认。因此首选上述同版本代码适配；若最终改为调用CLI，必须先证明交付版本能够提供精确、机器可解析且稳定的输出接口。首期不自行编码TiKV quota Key或Value。

这里的**受管目录记录ID（resource ID）**是Portal将一个目录纳入管理时，由存储管理库生成的内部唯一编号，例如`res-0001`。它关联该目录的卷UUID、逻辑路径、inode、实际owner和管理状态，供网页授权、配额任务及审计稳定引用；它不是JuiceFS inode、UID/GID、用户ID或访问凭据，也不赋予任何POSIX文件权限。目录删除后重新创建时，即使路径相同，inode已经变化，原resource ID也不能直接代表新目录，必须重新核对后才能继续管理。

读取和设置前，服务核对受管目录记录ID所对应的卷UUID、逻辑路径、目录类型、inode和owner状态，逐级拒绝符号链接及目录越界；不能只做字符串前缀判断。待交付新目录允许经登记的root owner，交付时核验其变为指定LDAP用户并更新实际owner记录；进入正常使用后若改名、删除重建或出现未登记的owner变化，标记`needs_review`并暂停写管理操作。

| 建议接口（均以`/api/v1`为前缀） | 权限与作用 |
|---|---|
| `GET/POST /admin/storage-users` | ADMIN选择已存在的LDAP业务账号；`jfsquota`通过受控只读LDAP查询核对并记录身份引用、用户名及UID/GID。不创建LDAP/Linux账号，不分配第二套ID，不保存用户登录密码 |
| `PUT /admin/storage-users/{id}/identity-status` | ADMIN登记获准客户端上的LDAP/NSS身份核验结果，记录核验人、范围、时间及摘要；不远程开户，不记录B/C映射版本 |
| `GET/POST /admin/storage-resources` | ADMIN登记已存在目录；保存真实卷UUID、路径、inode和实际owner，供展示及配额操作使用。待交付新目录另记录目标LDAP用户，登记不改变文件权限 |
| `POST /admin/storage-resources/{id}/quota-preview` | ADMIN核对当前额度、用量、预算及拟修改值；保存24小时有效的待确认操作，返回控制器生成的操作编号；不修改JuiceFS配额 |
| `PUT /admin/storage-resources/{id}/quota` | ADMIN确认已有操作编号，重新核对权限、有效期及真实值后受理；编号同时用于幂等去重，未知或已清理编号不得补建任务 |
| `PUT /admin/storage-resources/{id}/viewers` | **后续增量：** ADMIN显式授予或撤销Portal查看权；不改变POSIX权限 |
| `GET /admin/storage-operations/{id}` | ADMIN查看执行、回读和审计结果 |
| `GET /admin/storage-quotas` | **本期：** 个人ADMIN会话查询全部受管资源的原生额度与用量 |
| `GET /usage/quotas` | **后续增量：** 已登录USER只读自己获授权的资源 |
| 现有`GET /usage/roots`、`GET /usage/tree` | **本期：** 保留第一阶段监控用途，不给新业务用户分配整卷root；个人目录资源授权和采集为后续增量 |

新写路由应逐条放行，不能全局解除现有只读方法限制。写请求必须通过有效个人ADMIN会话、服务端授权、JSON字段白名单、请求大小限制及CSRF/Origin检查。旧`automation-admin`和`automation-user` Bearer凭据都不得调用这些写路由；以后确需自动化写入，再增加独立、可撤销、限定资源和动作的服务身份。

### 11.8 数据存储、权威数据源与操作状态

本方案不再为配额页面生成额外的只读SQLite副本。用户、目录资源与配额管理涉及**两个SQLite数据库**：现有目录统计库和新增存储管理库。Portal账号配置和TiKV中的JuiceFS元数据另有独立用途，不能把它们混称为同一个数据库。

#### 11.8.1 数据分别存在哪里

| 数据载体 | 保存内容 | 谁直接读写 | 权威范围与故障处理 |
|---|---|---|---|
| 现有目录统计SQLite | 授权目录的总用量、文件数、目录数、三级top 100明细、采集代次和时间 | `jfsstats`写入，`jfsweb`以文件权限和数据库连接双重只读方式查询 | 是Portal目录展示的数据源，不是配额规则或文件权限来源。丢失后可重新采集；采集失败保留上一代并标记过期 |
| 新增存储管理SQLite | LDAP身份引用、受管目录登记及实际owner观测、Portal查看授权、逻辑分配预算、配额观测、修改任务和审计 | 仅`jfsquota`直接读写；`jfsweb`无权打开数据库文件，只通过Unix Socket调用规定接口 | 是Portal管理记录、工作流和审计的数据源，不负责分配业务ID或执行文件权限。损坏时停止受保护网页查询及新变更，不影响TiKV中已存在的配额 |
| Portal账号配置文件 | Portal登录名、稳定账号ID、ADMIN/USER角色、密码哈希、禁用状态和认证版本 | root维护，Portal安全加载；账号管理工具按权限原子更新 | 是Portal登录认证的数据源，不创建Linux账号，也不保存文件内容或TiKV凭据 |
| TiKV中的JuiceFS元数据 | 实际配额上限、已用容量和inode计数，以及文件系统其他元数据 | 受控JuiceFS挂载和`jfsquota`通过JuiceFS元数据接口访问 | 是实际配额规则及配额计数的权威来源。管理库中的期望值只有写入TiKV并回读一致后才能标记为“配置已确认” |

LDAP另行保存业务账号及组关系，是本期业务身份的权威来源，不属于上述SQLite库；root及服务账号仍由各主机本地管理。存储管理库只引用已核对的LDAP身份，不能通过修改库内UID/GID改变用户的实际身份。LDAP查询不可用时，不新增或更换身份登记，不把未核实的浏览器输入当作真实身份；不因此删除既有目录或配额。

#### 11.8.2 存储管理库的数据模型

| 记录 | 最小字段及约束 |
|---|---|
| LDAP用户/组引用 | 内部主键、LDAP目录及条目引用、用户名、已核对的UID/GID与组关系、核验时间和状态。UID/GID来自LDAP，不在本库分配；同一LDAP身份不得重复登记，用户可共享GID。内部主键只关联管理记录 |
| 客户端身份核验 | 客户端名称、关联LDAP用户、实际NSS解析UID/GID与组关系、核验人、时间和结果；仅记录接入检查，不承载客户端到存储的映射或映射发布 |
| 卷 | 内部ID、真实JuiceFS UUID、配置引用、允许管理根、逻辑分配预算；数据库不保存可向Web返回的秘密 |
| 目录资源 | 受管目录记录ID（resource ID）、卷UUID、路径、inode、实际owner、可关联的LDAP身份及状态；待交付空目录另记目标LDAP用户，交付后回读更新实际owner。同卷活动路径及inode不得重复登记，不复制目录下全部文件的归属关系 |
| 查看授权 | Portal稳定账号ID与受管目录记录ID的显式关系；普通账号没有默认整卷权限 |
| 配额观测 | 每个资源仅保存最近一次成功读取的真实上限、用量和时间，以及最近错误/过期状态；与拟修改值分开保存，不按刷新次数追加历史 |
| 操作与审计 | 同一操作记录保存控制器生成的operation ID（兼作幂等键）、操作者、资源及卷/路径/inode摘要、旧值、新值、管理版本、理由、阶段、结果、回读值、预览有效期和终态时间；可清理的执行详情与审计摘要分字段保存，按11.8.5保留 |

账号密码继续由受保护的Portal账号配置文件管理，存储管理库只引用Portal稳定账号ID，避免再建一套密码库。补齐`portal-userctl`的新增、禁用、重置及角色调整功能，并支持安全重载。密码重置、角色变更及禁用提高`auth_version`，使旧会话失效；删除后同名重建的账号使用新的稳定ID，不能继承旧授权。

#### 11.8.3 查询路径、权限与一致性

- **目录统计查询：** Portal先通过`jfsquota`核对当前账号是否有权查看目标resource，再以只读方式查询现有目录统计SQLite。授权通过不代表目录快照一定可用；快照过期时显示旧值和采集时间，不显示为0。
- **配额及管理查询：** Portal通过Unix Socket请求`jfsquota`，由后者查询存储管理库并只返回允许展示的字段。Portal既不直接打开管理库，也不接触TiKV凭据。
- **授权撤销：** 撤销写入存储管理库后，新请求立即按新授权判断；不能使用过期目录统计数据恢复旧权限。控制器不可用时拒绝受保护的数据访问，已经返回给浏览器的数据无法追溯收回。
- **现有自动化令牌：** 没有个人resource绑定时不得继承示例账号的整卷查看权，也不得调用配额写接口。

目录统计库按完整采集代次查询，避免根记录与明细来自不同代。存储管理库中的关联修改采用SQLite事务；这只能保证本地管理记录一致，不能把TiKV提交与SQLite事务合并成一个跨数据库事务。

#### 11.8.4 配额调整及异常恢复

配额调整流程为：

```text
预览并保存待确认操作（24小时有效） → 确认已有操作编号并持久化受理状态
     → 核对当前真实值、存储管理库版本和预算 → 串行执行
     → 回读TiKV一致：配置已确认
     → 未调用后端即失败：失败
     → 已调用但超时/断连：结果待确认 → 回读并核对后记录最终结果
```

初期单worker串行处理变更。控制器在预览时生成不复用的操作编号，记录操作者、资源、拟修改值、理由及有效期；确认仅推进该已有记录，不允许通过提交未知编号创建任务。同编号同内容的已受理请求返回原任务，变更内容返回冲突；每次仍检查当前账号权限。执行前重新检查管理库版本、TiKV中的真实上限和逻辑分配预算，避免旧预览或Portal内两个管理员相互覆盖。管理库版本不是JuiceFS原生quota revision/CAS，不断变化的用量也不能当作上限修改版本。

单worker不能阻止外部root CLI在检查与设置之间修改同一配额。因此受管资源的日常变更统一经控制器；紧急CLI操作须先暂停该资源的管理任务，事后重新核对。对外返回“已确认”必须在TiKV回读一致且审计结果持久化后进行；服务重启后先核对未完成任务，不盲目重放或自动回滚所有配额。

#### 11.8.5 过期数据清理、空间与备份

首版由`jfsquota`在现有服务中完成存储管理库的定期清理，任务与审计共用一张操作表，不另建归档服务。下列为开发默认值，可由运维配置；S2-0核对152空间和预期规模，部署时记录最终取值。保留期限从明确的事件时间计算，页面查询、自动重试和例行刷新不能延长历史记录寿命。

| 数据 | 默认保留与清理规则 |
|---|---|
| 在用LDAP引用、目录登记、查看授权及当前管理版本 | 随资源使用保留，不按年龄删除。明确解除纳管后先撤销查看权、停止采集；停用记录满730天且无活动关联、未决任务或保留审计依赖后可清理。不能据此删除LDAP用户、JuiceFS目录或原生配额，也不回收UID/GID |
| 最新owner/配额观测、客户端身份核验结果 | 每个对象保存最新结果；查询失败保留上次成功值及时间，并更新错误状态。无界的逐次刷新历史不入库；解除纳管后清理对应观测 |
| 现有目录统计 | 复用collector的完整代次替换：新一代成功提交时删除该root旧明细，失败保留上一成功代并标记过期。解除纳管后按root精确清理，并防止仍在执行的旧采集重新发布；撤销某一查看者不等于解除纳管 |
| 未确认预览 | 24小时内可首次确认；到期失效并可删除，不占用配额预算。它尚未被受理，不属于必须保留的未决任务 |
| 已受理、执行中或结果待确认的任务 | 不因到期自动删除或强行改成失败；超过24小时未结束则提醒管理员核对。后端超时、提交后审计写失败，也按未决处理；保留恢复数据及预算占用 |
| 已确定终态的任务执行详情 | 自`terminal_at`起保留180天，之后清空详情字段；保留原请求的必要摘要、结果及去重所需信息 |
| 已确定终态的审计摘要与幂等记录 | 自同一`terminal_at`起保留730天，随后在无未决引用时分批删除。成功、已确认失败和确认未产生副作用的取消均可为终态；不能仅凭超时或点击取消进入此范围 |

审计摘要保留“谁、何时、目标、前后值、理由、结果”和判断重复请求所需的规范化内容/摘要；操作者或目录以后停用，不级联删除其保留期内的审计。目录登记、查看授权变更等其他管理审计也按730天保留；页面查询和周期采集不逐次生成操作审计。每个资源的当前状态、管理版本独立保存，不再为保留“最后一次修改”永久钉住一条旧任务。精简审计730天采用固定天数，不作为法律或合规留存承诺；未启用额外归档时，到期记录将无法在Portal查询。

**清理后的旧请求不会重新执行。** 正式提交只能确认服务端已经生成的操作编号。首次确认须在24小时有效期内；受理后重复提交仅返回原任务，不受预览有效期影响。过期、未知或已清理编号统一返回“操作不可再提交，请重新预览”，前端不得自动生成新操作并再次确认。操作编号不是授权凭据，重试和查询仍校验当前账号及资源权限。这使删除730天前的去重记录无需依赖永久保留幂等键。

**定期清理采用小批量事务。** 每24小时检查一次；停机错过时启动后补做一次，不按停机天数逐轮补跑。每批最多1000条、每次最多10批且总计不超过30秒，前台变更优先；锁忙或达到预算便结束，积压留到下一次并显示告警。删除时再次核对状态和期限，避免预览刚被确认却被并发清理。清理在本地完成，不调用TiKV删除配额；正常服务重启后可以继续执行。时钟未同步、明显跳变或回拨时暂停年龄清理并提示，待时间恢复后继续。

**时间保留与容量限制同时生效。** 每条执行详情最多16 KiB、审计及请求摘要最多4 KiB，超长输入在受理前拒绝，诊断输出截断并脱敏；未决任务最多100条、待确认预览最多1000条，到达限制拒绝新建但仍允许查询和核对已有任务。服务维护数据量及到期积压指标，不靠删除未决或未到期审计腾空间。

| 空间项目 | 首版默认控制 |
|---|---|
| 存储管理SQLite及其WAL/SHM | 规划上限2 GiB；达80%告警、90%暂停新管理变更及新预览，保留恢复和清理余量。监测实际文件字节，也检查复用空闲页的情况 |
| 所在系统盘可用空间 | 低于`max(5 GiB, 文件系统容量的5%)`时进入空间保护，暂停新增管理变更；已有任务仅在能够持久化记录时继续核对，不能保证写入则保留未知状态并告警 |
| 本服务独立诊断文件（如有） | 最多7天且合计256 MiB，先达到的限制生效；不重复落库完整请求或凭据，不修改其他服务的日志保留策略 |
| 本地一致性备份目录（含临时文件） | 最多8 GiB；每天最多一份，保留最近7份且不超过7天，任一限制先到则轮换较旧备份；保护最后一份验证成功的备份，例外时告警 |

上述容量是应用层准入阈值，不冒充文件系统硬配额：写入、备份前检查预计增量，正常运行监测实际占用；达到限制时告警并拒绝增加负担，不能通过删`-wal/-shm`或缩短审计期限恢复服务。阈值以下恢复且数据库检查通过后才重新接受管理变更。空间不足不删除业务文件、不把用量显示为0，TiKV已有配额继续生效。

**删除记录不保证SQLite文件立即缩小。** 空闲页可供后续写入复用；保持短事务，使用有时间预算的检查点，长读导致WAL无法回收时记录原因并处理本服务查询。首版不每天执行整库`VACUUM`；确需缩小时在维护窗口检查额外空间后处理，不在低空间下强行重建。依据：[SQLite空间回收](https://www.sqlite.org/lang_vacuum.html)、[WAL与检查点](https://www.sqlite.org/wal.html)。

**备份有界，恢复不能复活旧操作和旧权限。** 使用SQLite一致性备份API。生成前可先轮换多余的旧副本，为预计新文件留出空间，但始终保护最后一份验证成功的备份；新副本完成、校验并原子发布后，才可淘汰此前最后有效的副本。空间仍不足则跳过新备份并告警，避免达到8 GiB后永久停更且不处理可轮换副本。任何时刻最多一份在建备份；仅清理由本服务登记、创建进程已停止且超过24小时的失败临时文件。不得把单独复制主数据库文件当成运行中WAL数据库的完整备份。依据：[SQLite在线备份](https://www.sqlite.org/backup.html)。

恢复管理库后先关闭管理写和受保护的USER查询，作废恢复出的全部未确认预览；已受理任务逐项核对TiKV，不自动重放。开写前还要回读全部恢复的活动资源身份及真实配额，更新观测、重算预算，由管理员确认并补齐备份后新增/解除纳管等差异；不能只检查未决任务，因为备份后已完成的修改也可能缺失。无法核实的范围继续暂停管理，不自动扫描整卷重建台账；缺失的历史审计明确标记，不能根据当前额度编造历史。

恢复出的查看授权默认不生效，经可信管理员重新确认后才开放，避免恢复出备份后已撤销的权限；若同时恢复Portal账号配置，还须作废旧会话。按当前时间和原事件时间判断是否到期，不因恢复重新起算保留期。清理属于逻辑删除，旧备份还可能含已删除记录，随备份轮换退出；唯一有效备份超期时告警，不能宣称数据已经从所有副本中消失。本机备份用于本机数据恢复，不构成异地容灾；备份间隔内尚未备份的管理记录存在恢复缺口。

首版不自动把过期审计复制到另一套长期库，也不无限生成导出文件。有更长留存需求时，运维在到期前导出到受控位置并明确保留期限、容量和责任人。清理状态只保留最近执行时间、清理条数、最老到期记录及最近错误，日志按既有轮转策略处理，不为每条删除再创建一条永久审计。

### 11.9 页面、刷新与目录隐私

本期为ADMIN新增“存储用户”“目录与配额”“变更记录”页面：登记已有用户/目录，预览并提交额度调整，查看失败或待确认任务。后续增量才为USER提供个人额度页，展示本人授权目录的上限、配额用量、剩余额度、使用率、更新时间和状态；届时不得返回其他用户名称、目录、整卷用量或集群组件详情。

配额服务初期每60秒批量读取一次已登记资源的真实配额并更新存储管理库，管理员页面每30秒通过Unix Socket查询这些观测记录；修改后对目标资源立即回读并更新。普通GET请求不直接运行CLI或递归扫描；超过180秒未成功刷新时返回旧观测值并标记过期，不显示为0。后续实现个人目录查看授权时，权限变更需直接查询当前授权，不等待用量刷新周期。

现有目录统计不能直接当作逐文件POSIX鉴权：根目录`summary`得到的快照可能包含私有后代，而以统计账户直接访问Alice的0700目录又可能失败。因此：

1. 撤销普通用户的`juicefs-prod-root`授权；用户只能以自己的受管目录记录ID请求数据，服务端在查询条目前做授权。
2. 配额页面通过元数据quota计数提供用量，不为统计方便放宽用户目录0700，也不把不可读目录记为不存在或用量0。
3. 用户三级目录明细仅在独立资源范围的采集和返回权限均验证后开放；不能验证时显示“目录明细暂不可用”，额度和用量仍可正常展示。
4. 保留top 100及其余项聚合的说明。现有collector最多32个root、每root超时及整轮时间预算不适合直接塞入数百用户；先确定试点规模，再按预算分批采集，不增加无界递归扫描。

### 11.10 TiKV/Ceph接入安全与凭据部署

**第一期以可信挂载服务代普通用户访问后端。** 普通用户只有FUSE文件访问权；挂载进程仍必须持有TiKV/Ceph访问能力，不能笼统写成“客户端不持有凭据”。

- 挂载、统计和配额服务的配置、证书私钥及日志分别保护，普通用户不能通过文件、进程环境、调试接口或日志取得后端凭据。
- 网络访问控制须覆盖JuiceFS实际使用的PD客户端地址，以及PD返回的各TiKV Store对外服务地址：JuiceFS先连接PD获取Region路由，再直接连接相应Store读写元数据。这些地址通常是部署PD/TiKV的节点所通告的IP或主机名加端口，可能与最初写入META URL的PD地址不同。隔离需作用到普通进程，不能只按157整机IP放行；152 Web进程不应取得TiKV/Ceph直连能力。
- Ceph使用限于业务Pool和必要操作的CephX身份，不给业务挂载`client.admin`；普通文件用户不拿keyring。Ceph Pool权限不能进一步代表JuiceFS的某个个人目录权限。
- 目标环境从零部署时，在PD/TiKV首次启动前配置双向TLS，并按服务用途分发证书。不同证书有助于区分接入方，但TiKV不会因此把挂载证书变成“只能文件I/O、不能改quota”的细粒度身份。

**现有明文测试集群若要补开TLS，才涉及独立的后端迁移。** 迁移前盘点PD/TiKV互联、全部业务挂载、152统计/配额服务、监控和运维工具的连接方式，验证证书SAN/CN、更新与重连行为，再制定维护窗口及恢复方案；不能假定可无停机滚动切换。目标环境从零部署不需要这一步迁移，但同样需要验证证书轮换和撤销的实际效果：删除某台客户端上的证书文件不等于已撤销所有副本。

仅在现有测试集群迁移前，经过验收的网络命名空间/防火墙策略可作为阶段性隔离方案；必须证明普通进程无法直连PD、所有Store及其他旁路。目标环境从零部署按第三阶段计划启用mTLS，不采用这项过渡方案。

除直接运行`juicefs quota`外，还需针对实际交付二进制检查`.control`、`.jfs.control`、`.config`、ioctl/xattr、helper/socket及诊断接口。当前候选源码未发现FUSE直接修改quota的分支，但这不是已完成的环境安全验收；防护目标是普通用户不能获取凭据、提高上限或通过其他管理入口破坏限制。[TiKV安全配置](https://tikv.org/docs/dev/deploy/configure/security/)、[JuiceFS TiKV连接说明](https://juicefs.com/docs/community/databases_for_metadata/)、[CephX授权机制](https://docs.ceph.com/en/latest/rados/operations/user-management/)

### 11.11 故障处理与业务影响控制

| 情况 | 规定行为 |
|---|---|
| Portal/配额服务停止 | 已有文件访问和配额继续；新增和调整暂停，页面说明不可用 |
| TiKV故障 | 不执行新的管理修改；它本身也会影响JuiceFS元数据访问，不能承诺业务不受影响 |
| 设置超时但可能已提交 | 标记待确认，回读后决定状态；不自动重复创建目录、取消配额或改回旧值 |
| SQLite或审计无法写入 | 拒绝新变更；已在途任务恢复后核对，保留明确的审计缺口状态 |
| 目录统计库缺失、损坏或schema不兼容 | 目录明细页面显示不可用，不阻止整个Portal和其他监控页面启动；不把缺失数据表示为0 |
| 存储管理库缺失、损坏或schema不兼容 | 停止用户目录授权查询和新的配额变更；已有文件访问及TiKV中已保存的配额继续生效，Portal其他只读监控仍可用 |
| quota实际值被运维CLI改动 | 标记外部变更，要求管理员刷新并确认；不循环把它强制改回旧期望值 |
| 目录/inode/owner与登记不符 | 暂停该资源的修改和不确定的用户查看，等待人工核对 |
| 用户超限 | JuiceFS拒绝相应写入；提醒清理或申请增额，不自动清理文件 |

152新增服务先采用低并发、CPU约0.25核和内存512 MiB的资源上限作为验证起点，实测后调整；长时间初始统计单独限时排队。管理数据只写152系统盘专用目录，配置、存储管理库和审计按11.8节制定备份与保留策略；原始验收数据按项目约定保存至`/mnt/c/SunRise/test/`，凭据不进入报告或结果包。

启用配额管理功能不需要改JuiceFS缓存、bs、TiKV调优参数或Ceph数据布局。新功能自身故障时关闭写入口并恢复只读门户；不要自动删除已经设置的配额。保持现有不设置开机自启的部署约定，是否改变由后续运维部署安排决定。

### 11.12 实施顺序与最小验收

实施顺序与工时以[第二阶段总开发计划](../../USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md#五开发与实施顺序)的`S2-0～S2-5`为准；配额专题计划中的`Q0～Q4`是对应子任务，不另设一套`P0～P4`阶段。先确认交付版本、LDAP及后端认证的可行性，再并行开展接入准备和本地开发；随后用两个真实LDAP身份、一台获准客户端完成本阶段联合验收，最后在获准环境中小范围开通。两客户端联合验收留到第三阶段；模拟身份可用于本地开发，不能替代本阶段验收。

放行试点前至少确认：普通业务用户无法读取后端凭据或绕过Portal提高配额；业务挂载`root-squash`与独立管理挂载各司其职；容量和inode限额在一台获准客户端上生效，新增管理服务停止后原有业务I/O及已设配额仍有效；旧Bearer及USER不能访问新增管理接口；任务重试、数据库恢复和过期记录清理不会重复执行旧变更。跨客户端共同生效留到第三阶段，个人目录查看授权及其撤权验收留待后续。详细用例与证据要求直接采用[总计划的联合验收集](../../USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md#七最小联合验收集)及[配额专题计划的最小验收集](JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md#最小验收集)，不在本调研报告维护第三份清单。

第二阶段若在现有明文测试集群做试点，TLS迁移及挂载变更须另行制定窗口和恢复方案；第三阶段的目标集群从零部署时直接启用mTLS，不执行明文迁移。两阶段均需核对客户端凭据保护。账号、权限、unit、网络及TLS等环境变更执行前列出具体对象、操作及恢复方法；本调研报告不作为部署授权。个人目录三级明细是后续功能，不影响本期管理员查看原生配额用量。

### 11.13 不可信客户端与自研授权服务的定位

如果以后允许客户自行控制原生客户端root，本方案的“可信挂载代用户访问后端”前提不再成立。可将可信服务器挂载JuiceFS、再通过NFSv4/Kerberos或SMB提供访问列为安全备选，使不可信主机不持有TiKV/Ceph凭据；仅按来源IP放行的NFS、仅root-squash或仅使用不同挂载路径都不足以验证不可信客户端的用户身份。网关会使业务I/O经过客户端、网关及后端，并集中消耗网关的网络和CPU资源；对于本项目的大带宽训练负载和延迟敏感I/O，不能在未经测试时认为性能与客户端原生JuiceFS挂载相当。只有在同等I/O模型下验证带宽、延迟、并发扩展和网关故障恢复满足要求，才考虑采用该备选。

若必须保留直接FUSE挂载，则需要独立评估服务端元数据授权和可信配额执行。本地候选1.4.1源码显示，quota上限与用量放在同一条记录中，设置上限和普通I/O刷新用量都会修改该记录。因此在TiKV前简单禁止写某类Key会破坏正常I/O；只比较并保护上限字段，也不能防止恶意客户端伪报用量、篡改其他元数据或跳过客户端配额检查。

TiKV鉴权代理应改列为**安全边界尚未证明的预研候选**。要成立，至少需要覆盖PD发现及Store访问、事务重试、配额计数正确性、全部旁路和可信身份来源。提供高层文件元数据操作的服务可能更容易定义权限，但相当于新增关键路径组件，需要单独验证性能和高可用性；不能依据普通Token校验就承诺达到Weka或商业版JuiceFS的安全能力。

### 11.14 依据与实施前核验

路线A、第一期功能范围、JuiceFS交付版本和实施顺序已确定；这里仅记录试点环境的接入与安全核验。实施步骤见[第二阶段总开发计划](../../USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)。本方案的产品机制依据见第六、第十、第十二节及所附官方链接；现有Portal能力以本地代码和已归档部署记录为依据。

- **S2-1和S2-4核对接入行为：** 查明试点环境PD/TiKV的认证状态及Ceph凭据权限；用两个真实LDAP身份在一台获准客户端验证UID/GID、目录权限、配额和普通用户防绕过。跨客户端身份一致性及配额共同生效在第三阶段核对。管理预算、现有配额和owner按实际卷核对；个人目录三级明细不作为本期验收项。
- **S2-5核对试点变更：** 只有在现有明文测试集群实施认证切换时，才需要确定TLS维护窗口和恢复步骤。第三阶段从零部署的目标环境在首次启动时配置mTLS，无明文迁移步骤。

## 十二、当前架构补充：TiKV元数据后端

TiKV是分布式事务型键值数据库，不提供文件、目录、POSIX权限或文件系统配额等功能，因此不属于前述同类文件系统产品调研。本节只用于说明当前`JuiceFS + TiKV + Ceph`架构中的元数据后端及其安全边界。

> - **接入管理：** TiKV直接客户端API没有数据库用户名、密码、用户组和角色权限体系，并支持两种接入模式。未配置TLS证书时，安全连接被禁用，任何能够访问PD和TiKV服务端口的客户端都可以不提供用户名、密码、Token或证书而直接接入；启用TLS/mTLS后，CA（Certificate Authority，证书颁发机构）作为共同信任根，为PD、TiKV服务和应用客户端分别签发证书，服务端还可通过`cert-allowed-cn`限定允许连接的证书CN（Common Name，证书主题中的通用名称，用于标识该证书代表的服务或客户端）。证书模式可以认证应用客户端进程，但仍不能按证书身份分别授予RawKV（非事务键值接口）或TxnKV（支持多键ACID事务的键值接口）的只读、读写及指定Key前缀等细粒度权限。
> - **容量边界：** TiKV没有按客户端证书、用户名、Key前缀、目录、UID或GID设置存储容量配额的原生机制。TiKV提供的Store `capacity`、Region容量均衡、调度限速和I/O rate limit属于集群运行资源控制；其中`capacity`表示TiKV Store在服务端节点的数据目录中可使用的存储容量，供PD进行Region放置和容量调度，不是某个接入客户端在集群中可以使用的容量份额。其他限速参数控制的也是集群后台工作速率，而不是客户端配额。

### 12.1 在当前架构中的作用

当前方案由JuiceFS解释文件系统语义：JuiceFS使用TiKV TxnKV保存文件名、inode属性、UID/GID、权限、配额规则、用量计数和数据块索引等元数据，Ceph保存文件内容对象。TiKV只负责键值事务、复制和持久化，不理解这些Key代表文件、目录还是配额；文件用户与配额机制由JuiceFS定义。

TiKV提供两类键值访问接口：RawKV用于直接执行`Get`、`Put`、`Delete`、`Scan`等操作，不提供跨多个Key的完整ACID事务；TxnKV基于MVCC和分布式事务，可以把多个Key的修改作为一个事务提交或回滚。JuiceFS使用TxnKV原子维护相互关联的文件系统元数据。

### 12.2 接入认证

TiKV的直接访问主体是使用客户端库连接集群的应用进程。客户端先连接PD，获取事务时间戳、Region位置和TiKV Store地址，再直接向相应Store发起RawKV或TxnKV请求。

TiKV允许在不启用认证的情况下直接接入。`ca-path`、`cert-path`和`key-path`保持为空时，安全连接被禁用；能够访问PD和TiKV端口的客户端无需账号、密码、Token或证书即可发起请求。因此，这种模式只能部署在受控可信网络中，网络边界本身就是主要的接入控制。

需要验证接入方身份时，可以启用TLS保护网络传输，并通过mTLS验证通信双方：

- CA证书用于验证证书链；
- PD和每个TiKV服务分别持有服务端证书及私钥；
- 一个或多个应用客户端持有客户端证书及私钥；
- `cert-allowed-cn`可按证书Common Name建立连接白名单，留空时不执行CN白名单检查。

这种模式只能回答“哪个应用进程可以连接TiKV”。它不创建Linux/POSIX用户，也不提供面向直接TiKV API的数据库账号、组和角色管理；证书CN本身也不是RawKV/TxnKV权限策略。需要隔离不同应用时，除证书认证外还要结合独立集群或Key空间规划、凭据隔离和网络边界，由上层应用实现业务授权。

### 12.3 容量与配额边界

| TiKV机制 | 实际作用 | 是否为应用用户配额 |
| --- | --- | --- |
| Store `capacity` | 声明单个TiKV Store在服务端数据目录中可参与调度的容量 | 否 |
| PD容量均衡 | 根据Store空间在服务端节点之间调度Region副本 | 否 |
| Region/Leader/热点调度限制 | 控制副本和Leader移动的并发或速率 | 否 |
| TiKV I/O rate limit | 限制后台存储I/O对前台请求的影响 | 否 |
| PD后端`quota-backend-bytes` | 限制PD自身元信息数据库容量 | 否 |

这些机制不能原生表达“客户端A最多保存1 TiB”“某个Key前缀最多保存100 GiB”“UID 10001最多使用50 GiB”或“`/users/alice`目录最多使用20 GiB”。这些业务对象和限额必须由JuiceFS等上层系统定义、统计和执行。

**两个应用客户端访问TiKV的示例：**

1. 未配置CA、证书和私钥时，客户端A、B只要网络可达，就可以直接连接PD和TiKV，TiKV不会要求它们登录或出示凭据；
2. 启用mTLS时，集群运维人员建立CA，并为PD、TiKV服务以及客户端A、B分别签发证书；
3. TiKV可以判断连接证书是否可信，但不能为A、B分别定义只读、读写、不同Key范围或不同容量份额；
4. 即使某个TiKV Store配置了2 TiB `capacity`，该值也只是该服务端Store参与PD容量调度的上限，不代表客户端A获得2 TiB个人配额。

官方依据：

- [TiKV Architecture Overview](https://tikv.org/docs/5.1/reference/architecture/overview/)
- [TiKV Client APIs](https://tikv.org/docs/6.5/develop/clients/introduction/)
- [TiKV Security Configuration](https://tikv.org/docs/dev/deploy/configure/security/)
- [TiKV Scheduling](https://tikv.org/docs/5.1/reference/architecture/scheduling/)
- [TiKV Configuration](https://tikv.org/docs/7.1/deploy/configure/introduction/)

### 12.4 对本项目的借鉴

1. **把TiKV认证作为后端接入控制的基础。** 针对本报告记录的无认证连接模式，建议评估启用TLS/mTLS，为服务和获准挂载进程配置证书，并维护证书持有者、用途和更新流程。客户端加入仍需取得Ceph所需访问权限，两套后端认证应分别管理。[依据：TiKV安全配置](https://tikv.org/docs/dev/deploy/configure/security/)
2. **证书接入权限与配额管理权限分别解决。** 为挂载服务和配额服务发不同证书，有助于区分连接和控制凭据分发，但TiKV不会因此自动识别哪一方能修改JuiceFS配额。受控客户端场景可先采用第十一节的进程、凭据和网络隔离；需要防御不可信客户端root时，再评估理解JuiceFS操作语义的授权服务。
3. **后端容量指标用于运维，用户配额留在JuiceFS层。** TiKV Store容量反映元数据存储余量，Ceph容量反映数据后端余量，二者都不直接表示Alice的个人额度。Portal应分别展示这些指标，用户目录或UID/GID限额仍通过JuiceFS设置和统计。
