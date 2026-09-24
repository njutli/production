# JuiceFS多客户端用户ID映射子调研

> 调研日期：2026-09-20；补充日期：2026-09-21（多客户端root与本地/集中账号生命周期）
>
> 对象：JuiceFS社区版 + TiKV + Ceph；150～152为存储节点，152兼任Portal节点，157及后续机器为客户端。
>
> 状态：官方资料、上游源码及本地历史记录调研；未连接集群、未修改账号或挂载、未进行兼容性及性能实测。
>
> 关联：[用户管理与配额管理主报告](USER-AND-QUOTA-MANAGEMENT-RESEARCH-20260914.md)，本报告细化其中跨客户端UID/GID冲突处理，供后续选型使用。

> 后续决定（2026-09-22）：本期无需兼容已有业务账号，已选路线A。最新实施及Portal集成依据见[LDAP统一用户管理实施与注意事项](JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md)；本文继续保留原理和历史取舍，其中映射优先等旧建议不代表本期开发方向。

## 一、结论与适用范围

**LDAP/AD适合统一身份管理；idmapped mount适合在特定挂载点转换数字身份。二者解决不同问题，可以组合，不能相互替代。**

对于“保留新客户端已有UID/GID和业务运行方式，同时访问已有JuiceFS文件”的要求，当前没有核实到可直接为现有JuiceFS 1.4.1挂载打开的通用映射开关。主要结论如下：

| 方向 | 能解决什么 | 当前判断 |
|---|---|---|
| LDAP/AD + SSSD | 集中分配身份、组关系及登录权限，使新会话取得一致UID/GID | 成熟的身份管理方向，但单独不能转换已有进程访问JuiceFS时的身份 |
| Linux idmapped mount | 保留进程身份和磁盘owner，只在特定挂载视图中转换UID/GID | 与目标最贴近；FUSE已有内核支持，但核查的JuiceFS/go-fuse版本未启用，需客户端适配及内核条件支持 |
| 受控user namespace中运行JuiceFS与业务 | 在独立执行环境内使用规范ID，宿主机原账号保持不变 | 不增加网络网关；适合能够调整启动方式的业务，值得做小规模兼容验证 |
| JuiceFS客户端内实现显式ID映射 | 在现有FUSE入口完成本机ID与共享卷ID双向转换 | 适合必须保持宿主原生应用使用方式的长期需求；属于源码研发，尚无现成生产实现 |
| bindfs本地映射层 | 对目录视图中的owner及部分创建/改属主操作做映射 | 有现成实现，但增加一层FUSE，并存在ACL、代理身份和配额语义边界；不作为高性能主方案 |
| SSSD覆盖、FreeIPA ID Views、独立业务账号、Hadoop SDK | 分别解决身份视图、工作负载身份或特定SDK访问问题 | 仅适合对应场景，不能当作通用原生挂载映射 |

本次按用户要求排除NFS/SMB数据网关、JuiceFS商业版，以及仅靠`root-squash`/`all-squash`合并身份的方案。**不把修改已有用户UID/GID作为默认接入手段。**

上述可用性判断的依据分别见第三至第六节；“值得验证”表示有机制或源码依据，不表示已通过当前环境验收。

## 二、需要解决的具体冲突

### 2.1 统一使用一个例子

本报告把共享卷元数据中代表同一人的固定UID/GID称为“规范ID”。这是设计用语，并不是JuiceFS另建了一套账号。假设现状如下，示例数字不可直接用于部署：

| 人员 | 共享卷规范UID/GID | 客户端A本地UID/GID | 客户端B已有UID/GID |
|---|---|---|---|
| Alice | `10001:10001` | `10001:10001` | `20001:20001` |
| Bob | `10002:10002` | `10002:10002` | `10001:10001` |

目标是：B上的Alice继续以20001运行现有业务，访问共享卷时对应10001；B上的Bob保留10001，但访问共享卷时对应10002，不能被当成Alice。共享卷既有文件owner也保持不变。

仅修改用户名、Portal绑定或NSS查询顺序不能达到目标。普通Linux文件访问使用进程凭据中的数字身份；JuiceFS原生多客户端访问也要求这些数字具有一致含义。用户名主要服务于登录和显示。[Linux凭据机制](https://www.kernel.org/doc/html/latest/security/credentials.html)、[JuiceFS多主机账号同步](https://juicefs.com/docs/community/sync_accounts_between_multiple_hosts/)

### 2.2 映射必须覆盖两个方向

以B上的Alice为例，合格的实现需要同时保证：

- **访问与创建方向：** 本机20001按共享卷10001的身份接受权限检查；创建的新文件最终归属规范10001。
- **查询与管理文件属性方向：** 卷内10001在B的指定挂载视图中呈现为20001；`stat`、`chown`和ACL中的数字不能互相矛盾。
- **组关系：** 主GID、附加组和setgid目录继承一起验证；多个用户属于同一个业务组是正常关系，不能把共享GID当作用户身份重复。
- **配额：** 目录配额仍关联原目录；UID/GID配额应按卷内规范owner计量，Portal不能拿B上的本地20001直接替代规范10001。

不能只将文件显示成“归Alice所有”，却仍让访问请求携带错误的数字身份。也不能只映射Alice而让Bob的本地10001未经处理地继续对应共享卷10001。

本方案继续信任获准客户端的root。UID/GID转换用于隔离普通文件用户，不会限制已经持有TiKV凭据的root执行配额管理；该权限边界仍按主报告处理。

### 2.3 多客户端的root如何处理

**普通Linux主机的root账号UID均为0，主GID通常也为0；各机器仍分别保存自己的root账号配置和登录凭据。** GID 0本身不等于超级用户权限，也不应把容器内的UID 0一律当作宿主机root。[Linux账号格式与UID 0定义](https://man7.org/linux/man-pages/man5/passwd.5.html)、[Linux user namespace](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)

需要区分三个场景：

| 场景 | 相同的UID 0意味着什么 |
|---|---|
| 管理本机 | A的root管理A，B的root管理B。A上的root不能仅凭“自己也是UID 0”就通过SSH登录B，仍需满足B的认证和登录策略 |
| 访问同一JuiceFS卷 | 未做映射/squash等特殊处理时，两端root的文件请求都携带UID 0；仅凭文件owner中的0无法区分是哪台机器或哪位运维人员创建的文件 |
| 接入后端或集中目录 | UID 0本身不是TiKV、Ceph或LDAP/AD的管理凭据，接入取决于目标服务的实际策略；启用认证时需对应凭据与授权，未启用认证的TiKV也不是按Linux UID认人。可信客户端root通常能够读取本机挂载服务持有的后端凭据并控制该进程，因此拥有很强的实际操作能力 |

前两行分别依据[OpenSSH认证流程](https://man.openbsd.org/sshd)和[JuiceFS请求身份处理](https://github.com/juicedata/juicefs/blob/v1.4.1/pkg/fuse/context.go)；第三行是本项目现有凭据信任边界的说明。root的数字相同表示它在各主机具有相同的超级用户数字语义，并不表示所有机器共用一个登录账号；本项目另外约定信任获准客户端的root，不把它按普通用户冲突改号处理。若要追责，需要另记客户端和实际运维人员，不能只记录UID 0。

本项目的处理方向是：各客户端保留本地root及必要的应急运维入口，不把root统一成一个LDAP账号，不要求所有机器使用相同root密码。可按需让运维人员使用各自的实名账号登录，再依据该主机的sudo授权提权；LDAP/AD的目录管理权限与主机sudo权限分别授予，客户端root不会自动成为目录管理员。

**映射普通用户并不能防范恶意客户端root。** 已获后端访问权限的root能够改变本机映射、运行其他客户端或切换进程身份；`root-squash`可约束经该配置进入的root文件请求，但不能替代对客户端root和后端凭据的信任。当前方案不把“不可信root也能安全直接接入”列为已解决能力。

## 三、LDAP/AD + SSSD：统一身份来源

### 3.1 组件及请求流向

LDAP是访问目录记录的协议，OpenLDAP、389 Directory Server等提供目录服务；AD是微软的目录服务体系。SSSD运行在Linux客户端，为NSS身份查询和PAM登录认证等提供目录查询及缓存。FreeIPA将目录、Kerberos及主机管理等组合为一套集中身份系统。[SSSD官方介绍](https://sssd.io/docs/introduction.html)

采用这类方案时，流程可以是：

1. 身份管理员通过已有企业目录管理工具，或受控的LDAP/AD写接口，创建Alice及其组记录。
2. 157及其他获准客户端的NSS通过本机SSSD取得UID/GID；登录程序通过PAM完成认证与访问检查。
3. 登录成功后，操作系统以解析出的UID/GID和附加组启动用户进程。
4. 用户访问JuiceFS时继续走本机FUSE、TiKV和Ceph数据路径；LDAP服务器不转发文件内容。

这是本项目的部署设想。Portal是否进一步集成目录开户接口另行设计；当前Portal中的存储用户登记不会自动生成LDAP账号。

### 3.2 POSIX显式属性与AD算法映射

| 方式 | 目录和客户端如何决定UID/GID | 对存量JuiceFS的影响 |
|---|---|---|
| LDAP/FreeIPA显式POSIX属性 | 管理员为用户保存`uidNumber`、主组`gidNumber`，为组维护自己的`gidNumber`及成员 | 可将共享卷已有规范ID登记进去，便于保持owner不变 |
| AD显式POSIX属性 | AD记录中维护对应属性，SSSD使用`ldap_id_mapping = false`读取 | 适合需要对齐既有规范ID的场景；需核验属性完整性及跨域查询 |
| AD SID算法映射 | SSSD根据AD的SID及映射范围计算POSIX数字ID；启用时不使用显式`uidNumber/gidNumber`作为结果 | 自动计算值未必等于已有卷owner，不宜直接替换当前身份来源 |

SID是AD用于标识安全主体的标识符。这里的“ID mapping”表示SID转POSIX ID，不能理解为“访问本地磁盘用20001、访问JuiceFS用10001”。[RFC 2307 POSIX目录属性](https://datatracker.ietf.org/doc/html/rfc2307)、[SSSD AD接入说明](https://sssd.io/docs/ad/ad-provider.html)

算法映射还需统一域、范围和分配规则；多域区间冲突与发现顺序可能影响结果，修改范围参数也可能改变已有ID。当前已有共享文件owner，**优先评估显式POSIX属性**；如果选择算法方式，应先逐项比对存量owner和所有客户端的计算结果。[SSSD上游ID映射手册](https://github.com/SSSD/sssd/blob/master/src/man/include/ldap_id_mapping.xml)

### 3.3 为什么LDAP不能单独解决例子中的冲突

将LDAP中的Alice设为10001后，有以下结果：

- 若新登录的目录Alice使用10001，她能对应卷内Alice，但会与B上已有Bob的10001碰撞。
- B上原来以20001运行的Alice进程不会因为LDAP新增记录而自动变成10001。
- 若为了兼容本机，将目录Alice在B上解析为20001，她的原生文件请求仍是20001，仍不能自动对应卷内10001。

因此LDAP适合在开户和启动进程前统一数字身份；**它没有按挂载路径为同一个现有进程切换身份的功能**。这项判断由SSSD提供身份信息的机制与Linux进程凭据机制推导。[SSSD架构](https://sssd.io/docs/architecture.html)、[Linux凭据文档](https://www.kernel.org/doc/html/latest/security/credentials.html)

`passwd: files sss`或`sss files`改变的是查询来源顺序；`alice@domain`可消除名字歧义，都不能让两个相同内核UID变成不同的文件访问身份。`sss_override`及FreeIPA ID Views能覆盖指定客户端解析出的属性，仍属于主机身份视图，不是只对JuiceFS路径生效的转换器。[SSSD属性覆盖手册](https://github.com/SSSD/sssd/blob/master/src/man/sss_override.8.xml)、[Red Hat ID Views说明](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_idm_users_groups_hosts_and_access_control_rules/using-an-id-view-to-override-a-user-attribute-value-on-an-idm-client_managing-users-groups-hosts)

### 3.4 不影响既有业务的接入边界

对新机器或新业务账号，先盘点ID使用情况，分配不冲突的规范范围，再接入统一目录。对已经存在的账号及共享文件owner，保留其数字身份；有冲突的机器进入单独的映射或运行环境方案。

冲突检查不能仅依赖不带参数的`getent passwd`/`getent group`。SSSD通常关闭全量枚举，这类输出可能不包含全部目录账号。应组合权威目录清单、本机账号/组清单、按用户名和数字ID的定向查询，以及实际运行进程的身份信息；不为检查而默认开启昂贵的全量枚举。[SSSD排障说明](https://sssd.io/troubleshooting/basics.html)

还应检查容器的subordinate UID/GID范围，避免与拟用的规范范围重叠。SSSD的`min_id/max_id`只是过滤目录身份，不会阻止本地root创建相同数字的账号。ID分配规则必须覆盖后续开户和新客户端接入。[SSSD配置手册](https://github.com/SSSD/sssd/blob/master/src/man/sssd.conf.5.xml)

LDAP/AD不会自动盘点所有客户端的本地账号。即使集中目录内部已保证ID不重复，也不等于新分配的ID在各客户端上都未被占用。需要通过开户规则、客户端接入检查及预留范围共同保证；已有冲突仍单独处理。

### 3.5 部署、故障和性能

若已有企业AD/LDAP，优先接入现有服务。若确需自行建设，可评估150/151部署目录主节点和查询副本，152仍承担Portal职责；这只是候选部署位置，需先核对资源、DNS、证书及运维能力。目录读副本不会自动解决写入口切换，首期可保留单一受控写入口，故障时暂停开户或修改，避免引入额外的多主写入设计。[OpenLDAP复制机制](https://www.openldap.org/doc/admin26/replication.html)

SSSD支持主备发现和故障切换，也提供缓存；已缓存身份查询与按策略允许的离线登录可以继续，冷缓存、新用户及首次登录不在同一保证范围内。账号禁用和改组也不会立即撤销所有已运行进程的凭据。[SSSD故障切换手册](https://github.com/SSSD/sssd/blob/master/src/man/include/failover.xml)、[AD服务发现](https://sssd.io/docs/ad/ad-service-discovery.html)

对文件数据通路的影响主要是身份解析、登录、附加组查询及缓存未命中，并不新增文件转发跳数。不能据此承诺所有元数据操作绝无额外延迟；需验证实际客户端的组查询路径。关键系统和存储服务账号保留本地管理，避免将它们的启动依赖一并迁到目录服务。

### 3.6 不使用LDAP/AD：本地用户从创建到停用

这里讨论常见Linux本地账号和OpenSSH配置，不表示所有发行版只有这一种认证方式。**账号信息不是全部保存在“只有root能读的一个文件”里。**

| 文件或配置 | 保存/决定什么 | 通常的访问方式 |
|---|---|---|
| `/etc/passwd` | 用户名、UID、主GID、家目录、Shell等基本信息；密码字段通常为`x` | 普通用户通常可读，写入受保护；`ls`、`id`等需要解析名字与数字 |
| `/etc/group` | 本地组名、GID及成员信息 | 通常可读，写入受保护 |
| `/etc/shadow` | 本地密码哈希、密码期限和账号期限等 | 仅root及系统授权的特权组件可读；不是保存明文密码 |
| `~/.ssh/authorized_keys`或其他SSH信任配置 | SSH公钥/证书登录允许的凭据 | 按SSH策略管理；不属于本地密码哈希，也不一定仅root可维护 |
| NSS、PAM及`sshd`配置 | 从哪里查询身份、采用什么认证方式、是否允许登录 | 由受控运维配置，不是普通账号自己决定 |

依据：[passwd格式及权限](https://man7.org/linux/man-pages/man5/passwd.5.html)、[shadow格式及权限](https://man7.org/linux/man-pages/man5/shadow.5.html)、[OpenSSH公钥认证](https://man.openbsd.org/sshd)。

以运维人员在157上为Alice创建UID/GID `10001:10001`为例：

1. **创建账号。** 运维使用157上的root或获准sudo，通过`useradd`、`groupadd`等工具维护本地账号/组记录；按需创建家目录，再通过`passwd`设置密码，或配置SSH公钥。创建账号、设置密码、允许SSH登录不是同一操作。
2. **用户发起登录。** Alice从工作电脑执行`ssh alice@157`。请求到达157的`sshd`，不是发给JuiceFS或存储服务。
3. **查询身份。** `sshd`通过系统身份查询接口取得Alice的UID/GID等信息；在本地账号配置下，NSS从本地文件解析，找不到有效账号时不能仅凭一个密码完成登录。
4. **认证与登录许可。** 密码登录在常见Linux PAM配置下由`pam_unix`等验证本地密码；公钥登录由SSH机制验证私钥持有证明，不通过匹配`/etc/shadow`中的密码。还要满足账号有效期、SSH允许范围及相应访问规则。[Linux PAM本地认证模块](https://man7.org/linux/man-pages/man8/pam_unix.8.html)
5. **启动会话。** 认证和访问检查通过后，`sshd`的会话进程设置用户UID/GID、附加组和环境，再启动Shell或命令。以后文件访问使用这些进程凭据，不是每次IO都让`sshd`检查账号文件。[OpenSSH登录过程](https://man.openbsd.org/sshd)、[Linux进程凭据](https://man7.org/linux/man-pages/man7/credentials.7.html)
6. **停用或删除账号。** 运维先按实际认证方式禁止新登录；如果还需要立即停止访问，要另行处理已有SSH会话、后台作业、定时任务及其他凭据。之后再按流程删除本地账号记录、移交数据，不手工删一行就宣称完成用户注销。`userdel`通常也会检查是否仍有该用户的进程；删除账号不会自动处理所有文件系统中的遗留文件。[userdel行为](https://man7.org/linux/man-pages/man8/userdel.8.html)

尤其要区分**锁密码**和**停用账号**：密码锁定不一定封住公钥等其他登录方式，具体还取决于账号检查配置。删除名字也不会抹掉既有文件上的数字owner；如果立即把原UID分给别人，新用户可能继承旧数据权限。[shadow对密码锁定与其他登录方式的说明](https://man7.org/linux/man-pages/man5/shadow.5.html)

### 3.7 使用LDAP/AD：集中开户、客户端登录与停用

下面假设150提供目录/认证服务、157和客户端B已经配置好SSSD、NSS、PAM及SSH接入。**位置和账号均为流程示例，不是本项目已经部署了LDAP/AD。** AD场景中的150代表域控制器角色；不能把“在150部署一个OpenLDAP服务”等同于部署AD。

#### 3.7.1 新增普通用户：由有目录写权限的账号操作

1. **目录管理员先认证。** 管理员从管理工作站或受控节点使用目录管理工具登录，向目录服务提交请求。其权限来自目录授权，不因为发起机器的Linux UID是0就自动获得。
2. **在目录服务中创建Alice。** 登记登录名、组、UID/GID方案、家目录和Shell等属性。LDAP采用相应POSIX条目；AD创建域用户，并按第三节前文选择显式POSIX属性或SID算法映射。准备保留存量owner时，不能任意生成新数字。
3. **设置认证凭据和访问范围。** 初始化密码/其他认证方式，配置Alice获准登录哪些主机、是否属于允许SSH登录的组等。通用LDAP的用户条目存在不等于天然具有完整的主机登录控制，需由选定的SSSD访问策略等落实。[SSSD LDAP访问提供者配置](https://github.com/SSSD/sssd/blob/master/src/man/sssd-ldap.5.xml)
4. **客户端查询该记录。** 157和B以后通过SSSD查询目录或缓存获得Alice。通常无需在两台机器上分别执行`useradd alice`，也无需把目录账号复制到每台机器的`/etc/passwd`。家目录的实际创建/挂载另行配置，目录中的路径属性不是已创建的文件夹。

例如AD可通过管理界面或`New-ADUser`创建用户；OpenLDAP可通过经过认证的LDAP写接口添加条目，服务器按ACL决定能否写入。[Microsoft新建AD用户](https://learn.microsoft.com/en-us/powershell/module/activedirectory/new-aduser?view=windowsserver2025-ps)、[OpenLDAP访问控制](https://www.openldap.org/doc/admin26/access-control.html)

#### 3.7.2 用户通过SSH登录：请求仍先到目标客户端

以Alice输入密码登录157为例，流程如下：

1. **工作电脑 → 157的`sshd`：** 建立SSH连接并请求登录Alice；客户端主机157仍是这次登录的目标。
2. **157的`sshd` → NSS/本机SSSD → 150目录服务：** 查询Alice的UID/GID、组和账号信息；可命中157的SSSD缓存，不保证每次都发网络查询。
3. **157的PAM/SSSD → 150认证服务：** 验证用户身份。LDAP密码认证可通过受TLS保护的LDAP绑定验证；AD常见由SSSD通过Kerberos验证。服务器验证凭据，不能理解为157读取目录中的明文密码作比较。
4. **157执行登录访问检查：** 按配置检查账号状态、主机/组访问策略等；认证成功不等于自动允许登录所有接入该目录的机器。
5. **157的会话进程启动Shell：** 设置解析出的UID/GID和附加组，用户开始在157运行程序。这里产生的仍是Linux进程，而不是“在LDAP服务器上执行用户命令”。

依据：[SSSD组件和身份/认证服务](https://sssd.io/docs/architecture.html)、[SSSD接入AD](https://sssd.io/docs/ad/ad-provider.html)、[OpenLDAP认证与传输保护](https://www.openldap.org/doc/admin26/security.html)。

Alice改为登录B时，同一流程发生在B。若两端采用相同的身份解析规则，则新会话可取得一致数字ID；若保留了不同本地ID，则仍要由后文映射方案解决JuiceFS访问一致性。

如果采用SSH公钥登录，验证私钥持有证明仍由SSH机制完成，不能把它画成LDAP密码认证；公钥可以留在本地或经专门集成从集中来源查询。要使集中停用对这种登录也有效，必须把目录账号状态落实到SSH账号检查链。在Linux OpenSSH Portable中，启用`UsePAM`会让各类认证方式进入PAM账号/会话处理，但仍需配置正确的PAM模块和SSSD访问策略，仅设置这个开关不等于完成停用策略。[OpenSSH Portable的UsePAM定义](https://github.com/openssh/openssh-portable/blob/master/sshd_config.5)

#### 3.7.3 停用与删除：集中变更不是立即撤销所有访问

“用户注销”在本报告分为账号停用/删除，而不是用户主动执行`exit`退出一次登录。实施流程应是：

1. **目录管理员停用账号。** 在AD中可使用禁用账号操作，例如`Disable-ADAccount`；LDAP方案要按产品选择锁定/到期属性或登录许可策略，LDAP协议本身没有一个适用于所有产品的统一“停用字段”。[Microsoft禁用AD账号](https://learn.microsoft.com/en-us/powershell/module/activedirectory/disable-adaccount?view=windowsserver2025-ps)
2. **阻止后续登录。** 已接入且正确执行账号检查的客户端，在获得新状态后拒绝相应登录请求。必须考虑目录副本同步、SSSD身份/访问缓存、离线认证以及已有有效票据，不能承诺“点禁用后所有机器立即失效”。LDAP仅锁密码，也不能默认阻止SSH公钥登录；应覆盖实际启用的各类登录方式。[SSSD缓存及离线能力](https://sssd.io/docs/introduction.html)
3. **若要求立即停止使用，处理已有会话。** 由获准运维在各客户端确认并结束该用户的会话/作业、取消会自动重启的任务，按需要撤销其他访问凭据。目录服务器不会自动杀死157上已经运行的进程，既有进程和已打开文件也不靠每次查询目录状态来决定能否继续IO。[Linux进程凭据机制](https://man7.org/linux/man-pages/man7/credentials.7.html)
4. **保留数据及配额，完成移交。** 账号停用不删除JuiceFS目录，也不自动取消配额、修改owner或停用独立Portal账号。人员离场流程可以协调这些动作，但它们不是LDAP/AD原生的一次原子操作。
5. **最后删除目录记录或保留禁用记录。** 根据保留要求决定。不要因目录条目删除就立即复用其UID/GID；先处理遗留文件、ACL、任务及历史归属，避免新用户获得旧用户权限。

因此，相比本地账号，“新增/禁用的权威记录”从每台机器的账号文件转到集中目录，客户端按配置查询和执行；**文件权限执行仍在客户端/文件系统中，既有会话回收仍需落实到运行会话的机器。**

### 3.8 既有账号纳管与本项目的实际选择

只把本地Alice登记到LDAP而不改变客户端查询、认证或访问配置，不能称为已经接管了她的登录。真正迁移需将用户/组属性及认证配置接入目录，验证后处理本地同名记录和认证回退；密码迁移也应单独安排。保留原UID/GID可以保留文件的数字owner关系，但不是对所有业务兼容性的自动保证。

即使完成上述迁移，A上10001、B上20001的历史冲突也不会自动消失。当前若不需要统一Linux登录、密码和账号生命周期，**无需为了接入JuiceFS强制迁移已有账号或部署LDAP/AD**。本项目可以先维护规范身份及各客户端映射，集中认证作为后续可选项。

## 四、Linux idmapped mount：在挂载边界转换身份

### 4.1 功能与例子

idmapped mount为一个挂载视图指定UID/GID映射，内核在权限判断、属性呈现及相关操作中使用该映射。底层文件不需要逐个`chown`；同一个进程访问其他未映射路径时仍保留原身份。普通`mount --bind`仅改变路径入口，不自动附带身份转换。[Linux内核idmapping设计](https://www.kernel.org/doc/html/latest/filesystems/idmappings.html)

对第二节中的B客户端，期望视图为：

| 方向 | Alice | Bob |
|---|---|---|
| 卷内owner → B上的显示owner | `10001 → 20001` | `10002 → 10001` |
| B上的访问身份 → 卷内身份 | `20001 → 10001` | `10001 → 10002` |

这张表表达需求，**不是可直接写进`uid_map`或mount参数的语法**。实际配置涉及调用者、文件系统和挂载的身份域，转换方向必须通过创建文件、另一挂载读owner等行为验证。

### 4.2 当前JuiceFS不能直接启用的具体原因

需要同时满足内核、文件系统、用户态客户端三方面条件：

| 层次 | 核查结果 | 对本项目的意义 |
|---|---|---|
| 通用Linux VFS | Linux 5.12引入idmapped mount接口，底层文件系统还需实现支持 | 不能由“内核高于5.12”推出任意文件系统都能使用 |
| Linux FUSE | Linux v6.12已包含`FUSE_ALLOW_IDMAP`，协议7.41；内核要求用户态daemon协商支持并使用`default_permissions` | “FUSE永远不支持”不准确，但旧内核的普通FUSE支持也不够 |
| JuiceFS v1.4.1依赖 | 核查的`go.mod`将go-fuse替换为`juicedata/go-fuse`提交`b44a81936922`；其INIT回复没有协商该高位能力 | 仅给现有挂载追加`X-mount.idmap`不会补齐客户端支持 |
| 157历史环境 | 2026-07-24本地留存报告记录内核`5.15.0-170-generic` | 历史环境还存在内核门槛；本次未上机核实今天的版本或发行版回移补丁 |

依据：[mount_setattr接口](https://man7.org/linux/man-pages/man2/mount_setattr.2.html)、[Linux v6.12 FUSE协议定义](https://github.com/torvalds/linux/blob/v6.12/include/uapi/linux/fuse.h)、[FUSE初始化检查](https://github.com/torvalds/linux/blob/v6.12/fs/fuse/inode.c)、[JuiceFS v1.4.1 go.mod](https://github.com/juicedata/juicefs/blob/v1.4.1/go.mod)、[固定go-fuse提交的INIT实现](https://github.com/juicedata/go-fuse/blob/b44a81936922/fuse/opcode.go)、[157历史内核记录](../../../../../prod-deploy/doc/perf-report/02-2h-A-A2-A3-data-paused-20260724.md)。

当前项目交付二进制曾带性能补丁；上述是官方参考源码的判断，不能替代对实际二进制构建依赖的核验。本地[04-4源码审计报告](../../../../../prod-deploy/doc/perf-report/04-4-metadata-transaction-options-20260830.md)也区分了参考源码与精确二进制构建证明。

### 4.3 不能只在go-fuse里加一个能力位

Linux v6.12的`fuse_get_req`在启用这项能力后改变请求身份语义：创建inode等请求传递映射后的UID/GID，其他相关请求可能携带`FUSE_INVALID_UIDGID`。这与旧模式下普遍携带调用者数字身份不同。[Linux v6.12请求构造源码](https://github.com/torvalds/linux/blob/v6.12/fs/fuse/dev.c)

JuiceFS的`fuseContext`直接读取请求头的UID/GID，部分权限分支、squash行为和日志依赖这些值。因此即使默认权限主要由内核检查，适配仍须核对这些分支以及`setattr`、ACL和特殊控制接口；不能简单宣称开启标志后全部工作正常，也不能反过来断言普通操作必然全部失败。[JuiceFS v1.4.1身份上下文](https://github.com/juicedata/juicefs/blob/v1.4.1/pkg/fuse/context.go)、[FUSE操作入口](https://github.com/juicedata/juicefs/blob/v1.4.1/pkg/fuse/fuse.go)

所以该方向属于“内核能力已有、JuiceFS仍需适配”的研发候选。升级内核也可能影响157上的其他业务，应在独立验证环境先确认收益与兼容性。

### 4.4 数据路径、权限和配额影响

从设计上看，idmapped mount在VFS中完成数字转换，不新增网络服务，也不像bindfs额外增加一层用户态文件转发。具体CPU和延迟代价仍需实测，不能写成绝对零开销。

普通用户只应取得映射后的挂载入口；原始未映射挂载必须放在受控路径或私有mount namespace中。否则B上的Bob仍可能绕过映射，用本地10001访问原始卷中的Alice数据。

映射表应完整处理允许访问的用户、组及ACL身份，检测别名和重复目标；未映射身份如何处理需要明确，不能默认为安全。新映射上线与撤销还应考虑已经打开的文件、缓存和现有会话。首次实现宜固定挂载生命周期内的映射版本，变更时受控重新挂载。

目录配额沿用原inode，UID/GID配额与规范owner对齐。配额命令直连元数据时并不经过VFS挂载映射，因此管理端必须使用规范ID；该要求同样适用于后文其他映射路线。

## 五、user namespace：改变业务运行环境

### 5.1 与idmapped mount的区别

user namespace是Linux用户命名空间，可让进程在命名空间内看到不同的数字身份及能力范围。它不是主报告中的Linux服务账号名称，也不等同于文件系统路径映射。[Linux user_namespaces手册](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)

有两个容易混淆的方案：

| 做法 | 结果 |
|---|---|
| 在宿主机挂好JuiceFS，再把路径普通bind到容器 | 仅改变路径可见性；宿主FUSE连接收到的身份仍按原连接身份域解释，不能据容器内`id`输出推断已转换为卷内规范ID |
| 由运维建立UID/GID映射，在同一受控user namespace中启动JuiceFS挂载和业务进程 | FUSE连接按该user namespace转换请求及返回属性，有可能使卷内使用规范ID而宿主账号保持原值；需实测 |

后一种方式中，示例映射可表达为“命名空间内10001对应宿主20001”。Alice的宿主账号不变；业务在该命名空间中以10001运行，JuiceFS也在这个身份域中解释请求。FUSE的旧请求路径使用连接的`user_ns`做`from_kuid/from_kgid`转换，属性处理也使用对应转换。这是源码支持的候选思路，不等于当前JuiceFS部署已经支持该运行方式。[Linux FUSE请求实现](https://github.com/torvalds/linux/blob/v6.12/fs/fuse/dev.c)、[FUSE inode属性转换](https://github.com/torvalds/linux/blob/v6.12/fs/fuse/inode.c)

### 5.2 为什么不能直接服务所有宿主机进程

Linux FUSE在`allow_other`模式下检查请求者是否位于挂载对应的user namespace或其后代；普通宿主机进程位于祖先命名空间，不会因为能看到路径就自动获准访问。因此，不能把上述挂载简单搬回宿主目录，就宣称B上所有已有进程均可透明使用。[FUSE访问检查源码](https://github.com/torvalds/linux/blob/v6.12/fs/fuse/dir.c)、[内核FUSE说明](https://www.kernel.org/doc/html/latest/filesystems/fuse/fuse.html)

实际代价是需要受控地启动或迁移业务进程。命名空间中的账号解析、附加组、PID及`/proc`可见性、挂载传播、本地数据路径、GPU/设备访问也需对应配置。TiKV/Ceph连接仍由受保护的挂载服务持有，不能为方便映射把后端私钥交给普通用户。

“每用户独立挂载且关闭`allow_other`”存在更窄的挂载者身份检查路径，但它不是共享多用户挂载的通用替代；若挂载进程与普通用户共用宿主UID，还需重新证明凭据和进程隔离。本报告不将其列为默认方案。

### 5.3 适合什么场景

适合由任务调度器、systemd受控启动器或容器统一启动的新业务作业。它能保留主机原账号，并维持一层JuiceFS FUSE数据路径；无需新增NFS/SMB服务节点。

不适合要求任意宿主现有进程保持原运行方式、直接访问统一挂载点的场景。只把应用放进普通容器也不够，必须验证挂载创建时的身份域和请求实际进入JuiceFS时的ID。

## 六、其他可选路线

### 6.1 在JuiceFS客户端内部实现显式映射

如果“宿主机已有应用和ID都保持不变”是硬要求，可评估在社区版客户端现有FUSE边界实现映射。下述为本项目研发设计推论，**不是现有官方选项**。

运维为每台客户端分发一份受保护的映射表，例如B上的`local UID 20001 → canonical UID 10001`。请求进入JuiceFS时使用规范ID，属性回到内核前转换为本机ID；后端文件owner及配额始终使用规范ID。

| 必须覆盖的地方 | 原因 |
|---|---|
| 请求UID、主GID、附加组 | 对齐创建、权限检查及组权限 |
| `lookup/getattr/readdirplus`返回属性 | 内核本地权限检查需要正确的本地owner视图 |
| `chown/setattr`输入、新文件owner、setgid继承 | 不能只改请求头而留下属性载荷中的错误数字 |
| POSIX ACL、涉及ID的xattr/控制接口 | ACL用户与组也需要一致转换；未支持的接口应有明确行为 |
| 属性缓存与映射版本 | 不同视图不能混用已转换的属性，避免重复转换或旧授权残留 |
| quota与日志 | 内部统计按规范ID；日志可同时记录客户端ID、本地ID和规范ID |

这些检查点来自JuiceFS现有FUSE入口的职责及本项目需求。实现时应避免修改共享meta缓存中的原始属性，并以确定的映射表完成内存查找，不在每次IO时查询LDAP或Portal。[JuiceFS FUSE入口源码](https://github.com/juicedata/juicefs/blob/v1.4.1/pkg/fuse/fuse.go)

这条路线不增加网络跳数或第二个FUSE代理，理论上更贴近现有性能要求；代价是持续维护权限相关补丁及跨版本回归。目前不能给出完成时长或性能损失数字。仅改`newContext()`中的两个字段不足以交付。

### 6.2 bindfs：现成的本地转换层

bindfs的`--map`可将底层owner转换为另一UID/GID视图，并在创建、修改owner时进行相应反向处理，存在现成实现。[bindfs官方手册](https://bindfs.org/docs/bindfs.1.html)

用于JuiceFS时，应用请求先经过bindfs，再经过原JuiceFS挂载。它没有增加网络网关，但增加了一层FUSE服务、调度和文件转发；是否符合我们对随机IO及小IO延迟的要求需实测。

源码核查还显示，底层操作由bindfs进程执行，创建文件后再调整owner；不能认为原始调用者身份已原样送给JuiceFS。xattr路径也不能被默认当作完整的ACL ID翻译器。需检查配额计费、创建/chown失败、ACL和原始挂载绕过；未映射数字的保留行为可能造成身份别名。[bindfs上游源码](https://github.com/mpartel/bindfs/blob/master/src/bindfs.c)

因此可作为小范围功能验证或过渡工具，不列为本项目首选的高性能、多用户生产方案。

### 6.3 统一的专用业务账号与受控作业启动

对尚未使用JuiceFS的新任务，可以保留人的原登录账号，另用全局一致的业务执行UID启动访问存储的作业。主机原服务无需改号，也不增加文件IO协议层。

但它改变了作业身份，且规范UID在该主机上必须可安全使用；若规范10001已经被Bob占用，直接再建一个同UID账号并不能隔离。不同用户不能为省事共用一个业务UID。适用范围是可控制启动方式、没有冲突或已有独立身份域的业务。

### 6.4 Hadoop Java SDK的用户/组表

社区版Hadoop SDK支持`juicefs.users`、`juicefs.groups`等全局用户/组配置，可让使用该API的作业按统一规则解释用户名和ID。它适合已有Hadoop/Spark等SDK接入，不是任意POSIX程序的FUSE挂载映射功能；与原生挂载并存时仍需对齐规范ID和权限边界。[JuiceFS Hadoop SDK文档](https://juicefs.com/docs/community/hadoop_java_sdk/)

### 6.5 不作为映射方案的手段

- **仅增加ACL：** 将B的20001授予Alice目录，会同时授权其他客户端上数字20001代表的身份；没有客户端条件的全局ACL不能通用地表达逐主机映射。
- **仅做普通bind mount或mount namespace：** 可限制路径可见性，不能自动转换数字身份。
- **仅接入Kerberos：** 认证可以证明主体，但仍需将该主体对应到文件操作使用的数字ID；不会自动改写既有FUSE请求。
- **只改账号显示名、NSS顺序或Portal关联：** 不改变已有进程的文件访问凭据。

以上是根据前述身份与文件访问机制得出的适用性判断。

## 七、对当前方案的建议

### 7.1 分开确定“身份记录”与“执行映射”

身份记录可以由LDAP/AD或统一台账管理；执行映射必须落实到实际访问路径或业务执行环境。Portal保存映射关系本身不会产生转换效果。

如果采用映射，主报告的数据模型需在详细设计时区分：稳定人员ID、卷内规范UID/GID，以及各客户端本地UID/GID和映射版本。已有规范ID不能为适应单台机器而自动重编号；本地GID是否代表同一业务组应通过明确的组记录判断。

运维审批并部署映射，客户端普通用户无权把自己改成其他规范ID。受管原始挂载及TiKV/Ceph凭据继续受保护。映射解决文件用户身份一致性，配额修改仍由独立可信服务控制。

### 7.2 按业务约束选择

| 业务条件 | 建议方向 |
|---|---|
| 新客户端/新用户，能够统一数字身份 | 统一ID分配；规模扩大时接入LDAP/AD，优先对齐现有规范ID |
| 必须保留本地账号，但允许改变作业启动方式 | 优先验证同一受控user namespace内的JuiceFS挂载与业务进程 |
| 必须保留宿主原生进程及统一挂载使用方式 | 比较JuiceFS客户端显式映射研发与FUSE idmapped mount适配；两者均不属于现成配置 |
| 仅少量目录、对额外本地延迟可接受 | 可验证bindfs受限用途，不能据此批准完整多用户方案 |

**当前不建议为用户ID映射直接升级157内核或修改任何现有账号。** 先完成版本兼容性判断，再以最小验证决定是否值得研发。LDAP/AD可以成为未来统一身份的基础，但不能作为既有冲突已解决的验收依据。

## 八、后续最小验证建议

本节为可执行方向的设计，不是本次已经运行的测试。先验证身份与权限，再测性能，不复用长时间性能调优矩阵。

### 8.1 先确认兼容性，避免无效施工

读取目标客户端的内核及发行版版本、JuiceFS二进制哈希/版本/构建依赖、FUSE类型、当前权限选项、user namespace约束和挂载辅助程序版本。优先用`go version -m`等可读构建信息及对应源码核验go-fuse；无构建信息时明确记录缺口，不直接重编线上程序。

idmapped mount如已确定缺少FUSE能力协商，就停止“现成参数”尝试。ext4上的映射演示只能验证通用VFS机制，不能当作JuiceFS验收。独立验证环境可采用JuiceFS临时卷及测试身份，先通过功能测试，再按需接入隔离的TiKV/Ceph测试卷。

### 8.2 最小功能用例

| 验证点 | 必须观察到的结果 |
|---|---|
| 两客户端Alice使用不同本地UID | 都能访问同一私有目录；共享卷owner始终为规范Alice |
| B上Bob的本地UID恰等于规范Alice | Bob不能借数字碰撞读取Alice的0700目录 |
| 创建文件并从另一客户端检查 | 本地显示与各自主机身份一致，后端owner没有被改成本机临时ID |
| 主组、附加组、setgid、ACL | 共享组访问正确，非成员仍被拒绝；不能只验owner模式位 |
| 改owner、硬链接、重命名与既有文件 | 规则一致，不能通过遗漏操作绕过映射 |
| 目录与UID/GID配额 | 计数、超额拒绝及管理端查询对应正确的规范主体；不以字节级零超额作为本次映射承诺 |
| 无映射身份、原始入口及后端凭据 | 行为符合既定策略，普通用户不能绕过映射或取得配额修改权 |
| 重挂载、服务重启、映射变更 | 同一规范身份保持稳定，不丢映射、不继承其他人的权限 |

LDAP/AD另验证目录服务断开、冷/热缓存登录和改组后的旧进程行为。user namespace另验证业务实际运行身份、GPU/本地文件访问和附加组读取。只需覆盖最终选择的路线，不必对所有候选铺开测试。

### 8.3 性能与退出条件

在功能正确的候选中，选用同一小数据集比较原生挂载与映射后挂载的元数据操作延迟、随机小IO、现有randrw模型和CPU消耗。短窗口先确认是否有明显退化或新增FUSE瓶颈，有疑点再复测；不能在缺乏数据时给出固定百分比开销。

若候选必须改已有业务UID、开放原始卷给冲突用户、暴露元数据凭据，或只能正确显示owner而不能正确限制访问，应判为不满足当前需求并停止扩展。测试证据继续按项目规则保存在`/mnt/c/SunRise/test/`，正式结论与源码依据写回本目录。

## 九、资料范围与尚待确认项

文中的正式功能以官方文档和指定上游版本为依据；源码推导的候选已明确标注。bindfs和SSSD的`master`链接用于核查机制，后续实施应固定具体版本。

尚未实测或确认的事项包括：157当前运行内核及发行版回移情况、现有交付二进制的精确go-fuse依赖、user namespace方案在实际JuiceFS上的完整兼容性、idmapped mount适配工作量，以及各路线的性能损失。不能把这些空白写成“已经可用”或“已经不可行”。

本报告支持的决策是：先选择是否允许调整业务启动方式；允许时优先验证受控user namespace，不允许时将透明映射作为JuiceFS客户端研发项评估。LDAP/AD用于长期身份统一，不承担其本身不具备的按挂载路径转换功能。
