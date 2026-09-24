# LDAP产品选型调研：JuiceFS业务用户统一身份

> 日期：2026-09-23。状态：新建身份服务选定389 Directory Server；目标操作系统、部署节点及版本待核对，尚未部署。
> 范围：第二阶段路线A的业务用户身份；不替代Portal登录认证、TiKV/Ceph接入认证或JuiceFS配额管理。
> 选型边界：当前服务节点和客户端均为Linux；只比较可自行部署的开源身份服务，不纳入商业闭源产品。

## 一、结论

**新建身份服务选用389 Directory Server（389 DS），在两个不同服务节点部署。** 本项目当前需要统一UID/GID和组、业务账号认证及停用，并在任一身份服务节点故障后继续提供在线查询与新登录。389 DS已有密码策略、账号停用和双节点多供应者复制能力；客户端SSSD配置两个服务端地址以实现故障切换，无须为这些需求引入FreeIPA的Kerberos、集中主机策略等额外组件。[389 DS功能](https://www.port389.org/docs/389ds/FAQ/features.html)、[复制与高可用](https://www.port389.org/docs/389ds/FAQ/faq.html)、[SSSD服务发现](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_authentication_and_authorization_in_rhel/assembly_additional-configuration-for-identity-and-authentication-providers_configuring-authentication-and-authorization-in-rhel)。

这个决定针对**新建**身份服务；若客户已有可维护的目录系统，可另行评估接入，不默认再建一套。FreeIPA保留为需求扩大时的备选，而不是本项目的默认首选。389 DS的复制是异步的：刚开户、改密或停用而尚未复制的变更，遇到原节点故障可能暂时不能在另一节点生效。因此“双节点可继续认证”不等于“最新管理操作强一致或零延迟生效”；正式验收须分别验证复制、客户端切换、未缓存用户登录和管理变更传播。[389 DS复制说明](https://www.port389.org/docs/389ds/FAQ/faq.html)。

目标OS/版本、两个服务节点、资源预算、DNS与证书仍在S2-0核对；这些是部署参数，不再把LDAP产品重新开放选型。隔离环境的单实例只能用于早期功能验证，不能代替正式双节点验收。

## 二、项目需要身份系统完成什么

| 需求 | 判定口径 |
|---|---|
| 统一业务身份 | Alice在所有获准客户端得到相同的UID、主GID及附加组；新业务账号从统一来源建立，不逐台`useradd`。 |
| 可控开户与停用 | 运维能管理账号和组，规划不与本地系统账号冲突的数字ID范围；停用、缓存与已有会话的生效边界可验证。 |
| 客户端接入 | 每台业务客户端通过本机SSSD/NSS/PAM解析身份、认证登录并执行登录授权；LDAP服务端不运行在每台客户端。[SSSD架构](https://sssd.io/docs/architecture.html)。 |
| 可用性与恢复 | 两个不同服务节点均可在线查询和认证；任一节点故障后，客户端切换到另一个节点完成未缓存用户的新登录。另有应急本地登录、备份和副本恢复策略；不将缓存命中误写成服务端高可用。 |
| 与存储边界分离 | LDAP身份不自动给普通用户TiKV证书、Ceph keyring、挂载控制权或配额修改权；这些仍按第二阶段安全方案单独控制。 |

第三阶段计划另行使用**三台空白服务节点和两台空白客户端**做从零部署及跨客户端验收。三台服务节点是存储与Portal的计划资源，**其中只需在经资源核对的两个不同节点部署389 DS**；具体节点和共置影响由S2-0及D0核对。

## 三、候选产品比较

这里的“LDAP”是目录访问协议，FreeIPA、389 Directory Server、OpenLDAP才是本次比较的具体产品。三者均为开源软件，不是限制用户数或副本数的商业试用版；使用、修改及再分发仍须遵守各自许可证。[FreeIPA许可证](https://www.freeipa.org/page/License)、[389 Directory Server开源说明](https://www.port389.org/docs/389ds/FAQ/faq.html)、[OpenLDAP许可证](https://www.openldap.org/software/release/license.html)。下表的运维成本和适配度是针对本项目的判断，不是产品通用性能排名。

| 候选 | 官方机制与本项目适配 | 本项目主要代价 | 判断 |
|---|---|---|---|
| **FreeIPA** | 以389 Directory Server保存身份，另集成Kerberos、主机登录策略、集中sudo规则和Web/CLI管理；DNS/CA可按部署方式选用，SSSD有专门的IPA接入能力。[架构](https://www.freeipa.org/About.html)、[客户端](https://www.freeipa.org/page/Client)。 | 组件、资源与运维面比单独389 DS多；需规划域名/DNS、时间同步、证书及副本。 | 当前不选；以后确需集中主机策略、Kerberos单点认证等再评估。 |
| **389 Directory Server** | 独立LDAP目录服务，支持访问控制、密码策略、账号停用及多供应者复制；有管理工具。[官方功能](https://www.port389.org/docs/389ds/FAQ/features.html)、[官方首页](https://www.port389.org/)。 | 需规划UID/GID分配、双节点复制、客户端SSSD故障切换和账号管理流程；还需自行管理NSS证书库中的服务器证书签发、导入、到期预警和双节点轮流续证；不自带FreeIPA式集中主机策略。[NSS证书库](https://www.port389.org/docs/389ds/FAQ/faq.html)、[续证流程](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html/securing_red_hat_directory_server/assembly_renewing-a-tls-certificate_securing-rhds)。 | **本项目新建身份服务的选定产品**。 |
| **OpenLDAP** | 通用LDAP服务器，支持细粒度访问控制、多种复制拓扑及密码策略等overlay；也能保存统一UID/GID、支持双节点故障切换。[访问控制](https://www.openldap.org/doc/admin26/access-control.html)、[复制](https://www.openldap.org/doc/admin26/replication.html)、[overlay](https://www.openldap.org/doc/admin26/overlays.html)。 | 需按项目需求组合账号策略、唯一ID分配、开户/停用流程及管理工具；可定制性高，但实施和维护责任更多由项目承担。 | 不作为当前首选；适合客户已有成熟OpenLDAP运维体系，或需要深度定制目录服务的场景。 |

FreeIPA本身使用389 Directory Server作目录后端；“不用FreeIPA”不等于389 DS缺少复制或基础账号管理能力。两者也不应为同一批业务用户并行建立两套身份库。[FreeIPA目录服务说明](https://www.freeipa.org/page/Directory_Server)。

### 389 DS与OpenLDAP的进一步比较

| 比较点 | 389 DS | OpenLDAP | 本项目判断 |
|---|---|---|---|
| 账号及数字ID管理 | 提供密码策略、账号停用等现成能力；可配置DNA插件，在多供应者环境分配UID/GID。[功能](https://www.port389.org/docs/389ds/FAQ/features.html)、[DNA插件](https://www.port389.org/docs/389ds/design/dna-plugin.html)。 | 可保存同样的账号、UID/GID及组信息，也有密码策略等overlay；唯一ID分配和账号生命周期流程需选择并配置适合的工具或规则。[overlay](https://www.openldap.org/doc/admin26/overlays.html)。 | 两者都能满足身份数据需求；389 DS所需功能的组合工作较少。DNA也必须正确规划范围，不能代替本地ID冲突检查。 |
| 双节点可用性 | 支持多供应者复制，两节点可配置为均能受理查询及管理写入；复制仍是异步的。[功能](https://www.port389.org/docs/389ds/FAQ/features.html)。 | 支持多供应者复制；也可用mirror mode配合外部前端，在故障时切换写入节点。[复制](https://www.openldap.org/doc/admin26/replication.html)。 | **不能断言389 DS天生可用性更高**。两者都可实现单节点故障后继续在线登录；389 DS更适合当前希望降低双节点实施复杂度的取舍，实际可用性取决于复制、SSSD切换和故障演练。 |
| 配置与证书 | 管理功能较集中；TLS服务器证书需导入并维护NSS证书库，续证由本项目负责。[389 DS FAQ](https://www.port389.org/docs/389ds/FAQ/faq.html)。 | 模块化配置、复制拓扑选择较多；TLS可直接配置PEM证书和密钥，同样要自行负责签发、续证和客户端信任。[TLS](https://www.openldap.org/doc/admin26/tls.html)。 | OpenLDAP在配置与集成方式上更灵活；389 DS在本项目所需账号管理上更省组合工作，但证书管理并非零成本。 |

因此，本项目继续选用**389 DS**：优势是现有账号管理能力与目标双节点方案更契合、预计实施和维护工作更少，而不是OpenLDAP缺少统一身份或高可用能力，也不是389 DS有经过实测证明的更高故障可用率。若客户已经稳定运行OpenLDAP，应先评估接入现有身份源，不应仅因本项目默认选型而另建389 DS。

## 四、针对本项目的关键取舍

### 4.1 UID/GID唯一性与跨客户端一致性

本项目使用389 DS保存`uidNumber/gidNumber`和组关系，建立业务ID保留范围；双节点开户要使用经验证的唯一ID分配流程，不能让两个节点各自随意指定相同数字ID。389 DS提供面向多供应者复制的DNA ID分配插件，但其范围规划与唯一性仍需在S2-0核验。[389 DS DNA插件](https://www.port389.org/docs/389ds/design/dna-plugin.html)。目录服务也不会自动扫描每台客户端的本地账号，因此仍需检查本地root、系统服务账号、容器映射和后续本地开户规则；客户端必须以同一身份策略接入。

核对两台客户端实际得到的UID/GID及附加组一致，不能仅因两台客户端都能查到用户名就认定数字身份一致。

### 4.2 登录授权与文件权限不是同一件事

389 DS负责身份与认证；本期客户端登录准入由SSSD/PAM配置并验证，不要求服务端集中维护“用户×主机×登录服务”的策略。若以后大量客户端需要按组集中控制谁能通过SSH登录哪类主机，FreeIPA的HBAC更合适。[FreeIPA HBAC规则](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_idm_users_groups_hosts_and_access_control_rules/configuring-host-based-access-control-rules_managing-users-groups-hosts)。无论使用哪种身份产品，挂载后文件能否读写仍由进程UID/GID、JuiceFS POSIX权限/ACL和配额决定；Portal的ADMIN/USER账号目前仍独立。

### 4.3 试点与正式部署的实例数

- **第二阶段**：一台获准客户端、两个真实业务账号先验证身份、目录权限和配额；若需新建身份服务，可在批准的隔离环境先用一个实例验证功能。不得为了满足试点而直接修改157正在运行的登录/挂载链路。
- **正式身份服务**：389 DS固定部署在两个不同服务节点，配置复制及客户端SSSD故障切换；第二阶段在获准环境完成单节点故障下的在线认证验证。第三阶段用两台新客户端补齐跨主机UID/GID、共享文件及配额验收，并复核复制状态、备份恢复与客户端实际切换行为。具体节点、共置方式和资源上限待OS及机器资源核对后定。复制不免除备份。[389 DS高可用](https://www.port389.org/docs/389ds/FAQ/faq.html)。

389 DS节点故障时，SSSD缓存可能支持部分既有身份解析或离线登录，但新用户、组变更和停用传播不能靠缓存保证；必须在实际配置下验证切换到剩余在线节点。[SSSD介绍](https://sssd.io/docs/introduction.html)。

### 4.4 与TiKV/Ceph证书和配额权限的关系

身份目录只回答“业务进程是谁、能否登录客户端”。TiKV/PD mTLS、CephX keyring、可信挂载进程以及`quota-controller`管理权限仍是独立安全边界；389 DS的TLS及复制不会替代TiKV/Ceph的接入认证。普通LDAP用户不应取得存储后端凭据或配额管理入口。具体边界继续以[第二阶段总开发计划](../../USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)为准。

### 4.5 LDAP连接、管理身份与TLS边界

客户端SSSD先连接389 DS并完成TLS握手，再以LDAP身份执行绑定（bind）和查询。若关闭匿名查询，SSSD需用仅有必要读取权限的专用查询账号绑定，取得业务用户的UID/GID和组信息；用户登录时，再用该用户的LDAP账号密码完成认证。开户、停用等写操作则使用另行授权的LDAP管理身份，不能使用查询账号。389 DS默认允许匿名读取，也默认不强制加密绑定；正式部署须确定匿名访问策略，要求认证操作使用TLS，并让SSSD严格校验服务器证书。[SSSD查询绑定](https://sssd.io/docs/quick-start.html)、[匿名访问](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html/securing_red_hat_directory_server/assembly_disabling-anonymous-binds_securing-rhds)、[强制安全绑定](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html/securing_red_hat_directory_server/requiring-ldaps-or-starttls-for-encrypted-connections_securing-rhds)。

`cn=Directory Manager`是实例安装时设立的高权限LDAP身份，不等于Linux `root`；远程客户端上的root不会因为是root而自动获得LDAP管理权限。本机LDAP服务节点的root可以控制实例配置并重置管理密码，因此两台LDAP服务节点的root都属于高信任运维边界；获准人员也可用LDAP授权的受限管理账号远程开户，不必逐次由最初部署节点的root操作。本机LDAPI自动绑定若被启用，还可能将本机root直接映射到LDAP管理身份，须单独核对其配置。[管理密码及重置](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html/user_management_and_authentication/assembly_changing-the-directory-manager-password)、[LDAPI自动绑定](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html/configuration_and_schema_reference/assembly_core-server-configuration-attributes_config-schema-reference-title)。

LDAP连接**暂按单向TLS加LDAP账号密码设计，尚未确认是否要求客户端证书**：客户端验证LDAP服务器证书，389 DS通过LDAP绑定验证查询或登录身份。若安全要求提升为“没有客户端证书，即使知道有效账号密码也不能接入LDAP”，则需另行决定启用双向TLS并承担客户端证书分发、保护和续期工作。此选择与已规划的PD/TiKV双向TLS相互独立。两台LDAP服务器应各持有匹配其连接名称的有效服务器证书；同一CA续签时轮流更新、验证SSSD故障切换，CA轮换时先更新客户端信任。[389 DS TLS方式](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html/securing_red_hat_directory_server/assembly_enabling-tls-encrypted-connections-to-directory-server_securing-rhds)、[服务器续证](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html/securing_red_hat_directory_server/assembly_renewing-a-tls-certificate_securing-rhds)。

## 五、选型决定与待核验项

**产品结论：新建身份服务使用389 DS，正式部署两个不同节点。** S2-0继续核对：① 服务端与客户端OS/版本及389 DS制品；② 是否已有可复用目录及接入边界；③ 两个节点的资源、DNS、证书签发/续期及LDAP单向或双向TLS的最终安全要求；④ 业务UID/GID范围、双节点开户流程与本地冲突检查；⑤ 查询账号与管理账号权限、匿名访问和加密绑定策略；⑥ 复制延迟、SSSD切换、未缓存用户新登录及故障恢复。上述事项用于确定实施参数和验收，不再将FreeIPA作为默认候选重新选型。

若以后明确需要集中主机登录策略、Kerberos单点认证、集中sudo规则，或要求身份产品集成证书签发与自动续期能力，再单独评估FreeIPA。389 DS现阶段就需要服务器证书生命周期管理；是否改变产品须另行决策，不能把FreeIPA的集成能力当作389 DS的无成本功能开关。[FreeIPA客户端能力](https://www.freeipa.org/page/Client)、[FreeIPA架构](https://www.freeipa.org/About.html)。

本报告只作产品选型，不授权安装目录服务、修改PAM/SSSD、开通端口或分发凭据。试点与正式部署分别按[路线A实施说明](JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md)和[第三阶段部署计划](../../../03-deployment/CUSTOMER-DEPLOYMENT-DEVELOPMENT-PLAN-20260922.md)执行。
