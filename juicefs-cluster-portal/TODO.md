# JuiceFS 集群只读管理门户 TODO

> 执行方式：一次只推进一个步骤；每步完成后更新本文、保存证据、总结并暂停，等待用户确认下一步。
> 目标部署节点：`10.20.1.152（ceph-node3）`
> 当前阶段：T09、T10已完成；下一步进入T11的24小时管理员试运行和正式交付。

## 状态说明

- `TODO`：尚未开始
- `IN_PROGRESS`：当前执行步骤
- `DONE`：已完成并签收
- `DEFERRED`：用户明确延期，不阻断其他步骤
- `BLOCKED`：存在阻断，未擅自绕过

## 总清单

| ID | 状态 | 工作 | 是否改变集群状态 | 完成标准 |
|---|---|---|---|---|
| T00 | DONE | 选择中央管理节点 | 否 | 选定152并记录三节点对比依据 |
| T01 | DONE | 152只读部署预检与接口盘点 | 否 | 系统、端口、依赖、磁盘、指标可达性和安全边界有证据 |
| T02 | DONE | 冻结监控MVP需求、指标白名单和数据模型 | 否 | 管理监控页面字段、指标、API和刷新SLA冻结 |
| T03 | DONE | 建立本地项目骨架和fixture测试 | 仅本地文件 | API、Web、配置和测试目录可离线运行 |
| T04 | DONE | 编写152部署配置、systemd和sudo计划 | 仅本地文件 | 脚本离线检查通过，sudo完整命令待审批 |
| T05 | DONE | 在152部署受限的Prometheus/Grafana/Portal基础服务 | 是 | 服务受cgroup限制且仅本机loopback可达 |
| T06 | DONE | 接入JuiceFS、PD/TiKV、Ceph、主机和磁盘指标 | 是 | 各源自动刷新并正确处理过期数据 |
| T07 | DONE | 完成管理员总览、磁盘和动态拓扑MVP | 是 | 管理员能查看全部集群实时信息 |
| T08 | DONE | 完成认证及USER/ADMIN后端RBAC | 是 | 越权请求返回403，Grafana/Prometheus不直暴露 |
| T09 | DONE | 完成三级目录空间快照和用户用量 | 是 | 总量完整、每目录top 100及聚合项已在152业务卷签收，Portal只读SQLite |
| T10 | DONE | 低扰动、安全和故障验收 | 是，但不改业务配置 | Portal/Prometheus故障隔离、stale语义、14 targets恢复及业务不变均已签收 |
| T11 | TODO | 24小时管理员试运行及正式交付 | 是 | 无业务影响，文档、备份和运维说明齐全 |

## T00完成记录

- 完成时间：2026-09-10
- 结果：选定`10.20.1.152`。
- 原因：152当前为PD Follower、无Ceph MGR进程、128核load约0.01、可用内存约817 GiB、系统盘可用约744 GiB。
- 对照：150为PD Leader且有大量wekanode活跃进程；151运行Ceph MGR。
- 状态变更：无，只执行只读查询。

## T01执行范围

只读采集：

1. 152操作系统、内核、CPU、内存、cgroup和时区；
2. 系统盘、挂载、inode和目标路径父目录；
3. 已安装的运行时、开发工具和监控组件；
4. 当前监听端口和潜在端口冲突；
5. 152到JuiceFS、PD/TiKV和Ceph指标端点的可达性；
6. 现有服务进程和资源基线；
7. 确认不使用TiKV、Ceph OSD、DB/WAL或JuiceFS业务存储；
8. 输出`inventory/T01-READONLY-PREFLIGHT-20260910.md`。

禁止：安装软件、创建系统目录、修改防火墙、启用Ceph模块、启动服务、挂载JuiceFS、sudo写操作。

## T01完成记录

- 完成时间：2026-09-10
- 裁决：`T01_PASS`
- 证据：`inventory/T01-READONLY-PREFLIGHT-20260910.md`
- 状态变更：无；仅执行本机和远程只读查询。
- 关键结果：152系统盘、资源和端口满足部署要求；PD/TiKV端点可直接采集。
- 待处理差距：Ceph Prometheus未启用，150～152无Node Exporter，157 JuiceFS metrics仅监听localhost。
- 已冻结安全决策：不重挂157；后续用本地轻量转发；所有门户数据只写152系统盘。
- 下一步：T02，等待用户确认后开始。

## 2026-09-10范围调整

- 用户明确要求暂缓文件和目录查询。
- T09改为`DEFERRED`，不阻断T02～T08及监控管理面交付。
- 当前MVP不创建JuiceFS只读浏览挂载、不实现Namespace API、不执行目录轮询。
- 普通用户的目录和分目录用量页面随T09一并延期；管理员仍可查看全卷逻辑用量和Ceph物理用量。

## T02执行范围

本步只冻结管理员监控MVP，不操作集群：

1. 管理员页面及必需字段；
2. JuiceFS、PD/TiKV、Ceph、主机和磁盘指标白名单；
3. 拓扑、节点、组件、磁盘、容量、客户端和告警的数据模型；
4. 只读API路径、ADMIN权限边界、数据新鲜度和刷新SLA；
5. 文件/目录、授权路径和普通用户接口明确延期到T09。

## T02完成记录

- 完成时间：2026-09-10
- 裁决：`T02_PASS`
- 状态变更：无；仅新增本地设计文件。
- 范围合同：`docs/MONITORING-MVP-V1-SCOPE.md`
- 指标合同：`docs/METRICS-WHITELIST-V1.md`
- 数据模型及刷新SLA：`docs/DATA-MODEL-AND-REFRESH-V1.md`
- API合同：`api/openapi-v1.yaml`，共12个只读路径，当前业务接口仅允许`ADMIN`。
- 延期项：文件/目录浏览、授权路径用量、Namespace API、专用只读挂载和普通用户门户统一归入T09。
- 下一步：T03，本地建立项目骨架和fixture测试；等待用户确认后开始。

## T03完成记录

- 完成时间：2026-09-10
- 裁决：`T03_PASS`
- 证据：`inventory/T03-LOCAL-SKELETON-SIGNOFF-20260910.md`
- API：Go标准库实现12个只读路径，具备ADMIN鉴权、USER拒绝、指标白名单和新鲜度响应。
- Web：管理员总览首屏可展示逻辑/物理吞吐、组件健康、动态拓扑和节点状态。
- 测试：`go test`、`go vet`、JSON/JavaScript/OpenAPI检查及本机HTTP冒烟全部通过。
- 状态变更：无；fixture服务仅在本机loopback短暂启动，验证后已停止。
- 延期边界：未实现任何文件、目录、授权路径或Namespace功能。
- 下一步：T04，编写152部署配置、systemd/cgroup和完整sudo计划；等待用户确认后开始。

## T04完成记录

- 完成时间：2026-09-10
- 裁决：`T04_PASS`
- 证据：`inventory/T04-DEPLOYMENT-PREPARATION-SIGNOFF-20260910.md`
- 部署及sudo计划：`docs/T04-DEPLOYMENT-DESIGN-AND-SUDO-PLAN.md`
- 最小形态：Portal、Prometheus、Grafana三个原生systemd服务，全部只监听152 loopback。
- 安全收敛：T05不使用Podman/Docker、不安装Nginx、不开放管理网端口、不接入集群指标。
- 资源限制：0.5/2/0.5核，1/6/1 GiB，统一低IO权重；TSDB为14天且30 GB先到为准。
- 供应链：Prometheus `3.13.2`、Grafana OSS `13.2.1`，T05须验证官方SHA及staging全量SHA。
- 状态变更：无；没有上传、安装或启动远端服务。
- 下一步：T05，先执行152只读预检和staging复核，再请求安装阶段sudo批准。

## T05安装前进展

- 时间：2026-09-10 17:14 CST。
- 状态：`T05_PREINSTALL_PASS`，尚未执行sudo、安装或启动服务。
- 供应链：Prometheus `3.13.2`与Grafana OSS `13.2.1`官方包SHA256匹配。
- staging：`/tmp/jfsportal-t05-20260910-165333`已上传152，全量`13388`项SHA256校验通过。
- 152预检：主机、系统盘、内存、目标目录、端口和业务挂载检查通过；PD/TiKV PID保持存在。
- 证据：`inventory/T05-PREINSTALL-SIGNOFF-20260910.md`。
- 下一步：审批并执行“安装但不启动”的唯一sudo命令；完成后复核文件、权限、unit和业务指纹，再单独审批启动。

## T05安装进展

- 时间：2026-09-10 17:17 CST。
- 结果：`T05_INSTALL_BASE_PASS services_not_started=true`。
- 三个服务均为`inactive/disabled`，端口`3000/8080/9090`均未监听。
- cgroup合同已被systemd识别：Prometheus `2 CPU/6 GiB`；Grafana、Portal各`0.5 CPU/1 GiB`；三者`IOWeight=10`。
- 三个已安装unit的SHA256与staging一致。
- PD PID `1589960`、TiKV PID `2088516`未变，`/mnt/jfs-tikv`与`/mnt/dbwal`挂载未变。
- 用户决定：T05只进入调试运行，不enable服务。
- 下一步：只启动三个服务，随后立即执行只读健康、监听、资源和业务指纹验收。

## T05完成记录

- 完成时间：2026-09-10。
- 裁决：`T05_PASS`；证据：`inventory/T05-BASE-DEPLOYMENT-SIGNOFF-20260910.md`。
- Prometheus `3.13.2`、Grafana OSS `13.2.1`和Portal均在152正常运行，重启次数均为0。
- 仅监听`127.0.0.1:9090/3000/8080`，未开放管理网或公网端口。
- 三个服务均保持`disabled`；遵照用户决定不设置开机启动，仅作为当前调试进程运行。
- 资源上限生效，验收时内存约为Prometheus `27 MiB`、Grafana `214 MiB`、Portal `3.5 MiB`。
- PD/TiKV PID和业务挂载保持不变。
- 下一步：T06接入各指标源；开始前等待用户确认，并逐项审批Ceph mgr模块、node exporter和157轻量转发涉及的状态变更。

## T06离线准备进展

- 时间：2026-09-10 18:07 CST。
- 只读盘点：`T06_INVENTORY_PASS`，证据为`inventory/T06-READONLY-INVENTORY-20260910.md`。
- 离线实现：`T06_OFFLINE_GATE_PASS`，证据为`inventory/T06-OFFLINE-PREPARATION-SIGNOFF-20260910.md`。
- 执行计划：`docs/T06-METRICS-INTEGRATION-AND-SUDO-PLAN.md`。
- 已就绪：157只读metrics转发器、150～152 Node Exporter/NVMe collector、Prometheus白名单配置、安装/验收/自动回滚脚本。
- 当前远端状态：未上传T06 staging，未安装或启动新增服务，未启用Ceph模块，未重启Prometheus。
- 下一步：用户确认后只上传并逐节点执行只读preflight；随后先单独审批150 canary的三条sudo写命令。

## T06 staging分发进展

- 时间：2026-09-10。
- 裁决：`T06_STAGING_DISTRIBUTION_PASS`，证据为`inventory/T06-STAGING-DISTRIBUTION-SIGNOFF-20260910.md`。
- `/tmp/jfsportal-t06-20260910-181003`已分发到157及150～152，四个远端副本完整SHA、文件数、主机名和执行权限均通过。
- 状态变更仅为各节点`/tmp`新增约29 MiB临时文件；无sudo、无安装、无服务状态变化。
- 下一步：执行四节点安装前只读preflight；通过后单独审批150 canary的安装与当前会话启动命令。

## T06节点150 canary进展

- 时间：2026-09-10。
- 安装前只读检查：`T06_INSTALL_PREFLIGHT_PASS`，证据为`inventory/T06-INSTALL-PREFLIGHT-SIGNOFF-20260910.md`。
- 150 canary：`T06_NODE150_CANARY_PASS`，证据为`inventory/T06-NODE150-CANARY-SIGNOFF-20260910.md`。
- Node Exporter及NVMe timer当前运行但保持disabled；Node Exporter约11.5 MiB内存、0次重启，从152抓取约17.8 ms。
- NVMe只读采集成功，4个控制器指标完整；PD/TiKV和业务挂载正常。
- 下一步：审批并逐节点执行151、152相同的三条安装/启动命令；151完整验收后才进入152。

## T06安装前检查进展

- 时间：2026-09-10。
- 裁决：`T06_INSTALL_PREFLIGHT_PASS`，证据为`inventory/T06-INSTALL-PREFLIGHT-SIGNOFF-20260910.md`。
- 157及150～152的主机/IP、端口、用户、目标文件、工具、设备、容量和业务指纹检查均通过。
- 152现有Prometheus配置与unit和T05回滚基线SHA完全一致。
- 下一步：仅执行150 canary的安装与当前会话启动；验收通过后才进入151。

## T06三节点主机与NVMe采集完成

- 时间：2026-09-10。
- 裁决：`T06_NODE151_152_PASS`，证据为`inventory/T06-NODE151-152-SIGNOFF-20260910.md`。
- 150～152的Node Exporter和NVMe timer全部active且disabled；每节点4个NVMe样本，Node Exporter重启次数均为0。
- 从152抓取三个`9100`端点均返回HTTP 200，单次约16～17 ms。
- 三节点PD/TiKV、业务挂载及152原有Portal/Grafana/Prometheus均正常。
- 下一步：审批并仅在157安装和启动只读metrics forwarder；不修改或重启JuiceFS挂载。

## T06客户端157指标转发完成

- 时间：2026-09-10。
- 裁决：`T06_CLIENT157_FORWARDER_PASS`，证据为`inventory/T06-CLIENT157-FORWARDER-SIGNOFF-20260910.md`。
- 转发器active且disabled，约3.7 MiB内存、0次重启；从152抓取约100 KiB指标耗时约3.8 ms。
- 来源IP白名单有效，151无法访问；JuiceFS PID及157原有Node Exporter保持正常。
- 下一步：在Ceph mgr节点执行只读module/config/active状态盘点，随后冻结并单独审批最小Ceph Prometheus启用命令。

## T06 Ceph指标源只读盘点

- 时间：2026-09-10。
- 裁决：`T06_CEPH_READONLY_INVENTORY_PASS`，证据为`inventory/T06-CEPH-READONLY-INVENTORY-20260910.md`。
- Ceph为`HEALTH_OK`，150 active MGR、151 standby MGR，6个OSD全部up/in，97个PG全部active+clean。
- Prometheus模块可用但未启用；默认`[::]:9283`可兼容IPv4，只需`module enable`，无需`config set`。
- 下一步：单独审批启用命令及失败时的disable回退命令；启用后先只读验收Ceph健康、端点和指标名。

## T06 Ceph metrics启用完成

- 时间：2026-09-10。
- 裁决：`T06_CEPH_METRICS_PASS`，证据为`inventory/T06-CEPH-METRICS-SIGNOFF-20260910.md`。
- Ceph仍为`HEALTH_OK`；150 active端点约149 KiB/1.6 ms，151 standby端点HTTP 200且当前为空。
- 健康、MGR、OSD、PG、pool容量与I/O指标均已实测签收，并更新`docs/METRICS-WHITELIST-V1.md`。
- 下一步：审批152 Prometheus T06配置切换；脚本会先备份T05基线，失败时自动回滚，仅重启Prometheus自身。

## T06完成记录

- 完成时间：2026-09-10。
- 裁决：`T06_PASS`；证据为`inventory/T06-PROMETHEUS-INTEGRATION-SIGNOFF-20260910.md`。
- 中央Prometheus跨多个采集周期连续验收通过：12个必需目标全部在线，Ceph两个目标可达，三节点共12个NVMe控制器齐全。
- 当前约20,438条活跃时序，其中JuiceFS 160、PD 779、TiKV 13,299、主机4,722、Ceph 574；白名单基数受控。
- 所有新增服务均保持active/disabled且没有设置开机自启；Ceph为HEALTH_OK，业务PD/TiKV/JuiceFS进程和挂载未变。
- 缺失数据保留Prometheus原生`up`和时间戳，Portal的`STALE/UNAVAILABLE`呈现归入T07，低扰动故障注入验收归入T10。
- 下一步：T07，将现有Portal从fixture切换为Prometheus实时只读适配器，完成管理员总览、磁盘和动态拓扑MVP；等待用户确认后开始。

## T07离线准备进展

- 时间：2026-09-10。
- 裁决：`T07_OFFLINE_PREPARATION_PASS`；证据为`inventory/T07-OFFLINE-PREPARATION-SIGNOFF-20260910.md`。
- 已实现Prometheus live adapter、失联缓存降级和八个可点击的管理员页面；fixture/live测试、Go/JavaScript检查及Prometheus配置检查通过。
- 磁盘页覆盖150～152共12块NVMe，拓扑可动态识别PD Leader、MGR Active、TiKV/OSD和磁盘状态。
- staging为`/tmp/jfsportal-t07-20260910-200500`，19项、6.7 MiB；尚未上传或修改远端。
- 下一步：用户明确批准T07 staging上传后，只写157/152的`/tmp`并进行SHA与只读preflight；sudo更新仍需另行批准。

## T07 staging分发与安装前检查进展

- 时间：2026-09-10。
- 裁决：`T07_STAGING_PREFLIGHT_PASS`；证据为`inventory/T07-STAGING-DISTRIBUTION-AND-PREFLIGHT-SIGNOFF-20260910.md`。
- `/tmp/jfsportal-t07-20260910-200500`已由本地上传157并转发152；本地、157和152的19项清单文件均通过SHA256校验。
- 152端shell语法及Prometheus配置检查通过；T06的12个必需采集目标和Ceph目标保持健康。
- Portal、Prometheus、Grafana均为`active/disabled`且仅监听loopback；PD/TiKV PID及`/mnt/jfs-tikv`、`/mnt/dbwal`挂载正常。
- 当前Prometheus配置因普通用户无读取权限，未绕过权限；更新脚本将在root上下文先核对T06固定SHA，不匹配即停止。
- 下一步：单独审批并执行唯一sudo更新命令；它只备份及替换Portal/Prometheus受管文件、重启Portal与Prometheus，并在失败时自动回滚。

## T07完成记录

- 完成时间：2026-09-10。
- 裁决：`T07_PASS`；证据为`inventory/T07-LIVE-MVP-SIGNOFF-20260910.md`。
- 管理员门户已切换到Prometheus实时只读数据源，八个页面均可点击并通过API验收；拓扑可动态显示PD Leader，磁盘页覆盖三节点12块NVMe。
- 首次更新因Prometheus重启后的30秒自采窗口尚未完成而自动回滚；修复仅增加最多90秒的目标就绪等待，第二次更新完整通过。
- 独立复核显示14个targets在线、无down target、PD Leader数为1、Ceph健康值为0、12块NVMe指标齐全。
- Portal、Prometheus、Grafana保持`active/disabled`，重启次数均为0；PD/TiKV PID和业务挂载未变。
- 下一步：T08认证及USER/ADMIN后端RBAC；开始前等待用户确认。

## T08执行范围

- 使用152本地账户，不假设不存在的LDAP/AD/OIDC；密码仅保存Argon2id哈希。
- 浏览器使用8小时、HttpOnly、Secure、SameSite=Strict的签名会话Cookie，不再要求手工粘贴Bearer token。
- ADMIN可访问现有八个实时只读页面；USER可以登录，但T09恢复前无业务数据页面，直接访问管理员API必须返回403。
- 保留随机Bearer token仅供root侧自动验收；不在页面、日志或报告中暴露。
- Portal保留`127.0.0.1:8080`健康口，在`10.20.1.152:8443`提供HTTPS；systemd除loopback和152自身验收外只允许157外部来源，供现有`thailand`单条SSH隧道访问；Prometheus和Grafana继续只监听loopback。
- 不安装Nginx、不修改防火墙、不enable服务，不操作PD、TiKV、Ceph OSD、JuiceFS挂载和业务数据。
- 详细设计与sudo边界：`docs/T08-AUTH-RBAC-AND-HTTPS-PLAN.md`。

## T08离线准备进展

- 时间：2026-09-10。
- 裁决：`T08_OFFLINE_PREPARATION_PASS`；证据为`inventory/T08-OFFLINE-PREPARATION-SIGNOFF-20260910.md`。
- 已实现本地账户、Argon2id密码、8小时签名Cookie、登录限流、ADMIN/USER后端RBAC、登录页面和Portal内置HTTPS。
- 单元测试、Go vet、JavaScript/OpenAPI、shell语法、凭据生成器权限及本机TLS登录/RBAC冒烟均通过。
- 首次staging `/tmp/jfsportal-t08-20260910-230425`已通过157转发至152并完成只读preflight；证据为`inventory/T08-STAGING-DISTRIBUTION-AND-PREFLIGHT-SIGNOFF-20260910.md`。
- 首次sudo更新因unit未放行152访问自身管理IP，导致本机TLS健康检查超时；脚本按设计自动恢复T07并删除新认证/TLS文件。Portal恢复健康，PD/TiKV PID和业务挂载未变；证据为`inventory/T08-UPDATE-ATTEMPT1-ROLLBACK-SIGNOFF-20260910.md`。
- 最小修复只新增`IPAddressAllow=10.20.1.152/32`供152自身验收；外部来源仍仅157。修复后的`/tmp/jfsportal-t08-20260910-232451`已通过完整离线Gate，20项、约12 MiB。
- 修复版staging已上传157并转发152，两端完整SHA及152 shell检查通过；首次上传断链产生的缺失/损坏项被SHA门阻断并精确补传，未把不完整副本转发152。证据为`inventory/T08-REPAIRED-STAGING-PREFLIGHT-SIGNOFF-20260910.md`。
- 152仍是完整T07状态：五项冻结SHA匹配，8443空闲，新RUN目标路径均不存在；三项管理服务、PD/TiKV PID和业务挂载正常。
- 当时下一步（现已完成）：审批并执行`sudo /usr/bin/bash /tmp/jfsportal-t08-20260910-232451/scripts/t08-update-auth.sh /tmp/jfsportal-t08-20260910-232451`；执行结果见下节。

## T08完成记录

- 完成时间：2026-09-10。
- 裁决：`T08_PASS`；证据为`inventory/T08-AUTH-RBAC-HTTPS-SIGNOFF-20260910.md`。
- 修复版更新返回PASS：ADMIN登录和管理员API为200，USER访问管理员API为403，匿名为401，非授权写方法为405。
- Portal同时保留loopback HTTP健康口并在`10.20.1.152:8443`提供HTTPS；157实测可达，151实测超时，外部来源限制生效。
- Portal、Prometheus、Grafana均为`active/disabled`且`NRestarts=0`；Prometheus和Grafana仍只监听loopback。
- PD/TiKV PID保持`1589960/2088516`，`/mnt/jfs-tikv`和`/mnt/dbwal`挂载未变。
- bootstrap明文凭据只保存在152的root-only文件，尚未读取到报告或工具输出；用户接收后需另行批准删除。
- 当时下一步（状态已变化）：T09当时延期并先进入T10；T09现已由用户恢复，当前进展见后文“T09恢复及DirStats验证”。

## T10阶段A只读盘点

- 时间：2026-09-11；裁决：`T10_PHASE_A_CONDITIONAL_PASS`，证据为`inventory/T10-PHASE-A-READONLY-INVENTORY-20260911.md`。
- 约31～39秒短窗内，152 Portal/Prometheus/Grafana/Node Exporter分别约占单核`0.001%/0.53%/0.33%/0.26%`；150、151 Node Exporter约`0.28%/0.27%`，均低于1%。
- 152四个常驻管理服务合计内存约584 MiB；业务节点exporter及157 forwarder单项均低于32 MiB。Prometheus TSDB约250 MiB，运行时确认30 GiB限制生效。
- 14/14 targets在线，Ceph健康值为0；T08 HTTPS、RBAC和来源IP边界保持有效。
- 发现157 forwarder发生6次自动重启：128核Go默认调度与`TasksMax=32`冲突，第33线程创建失败；当前线程数也恰为32，必须先修复再做故障注入。
- 最小修复仅为forwarder unit增加`GOMAXPROCS=1`，不放宽CPU/内存/IO/线程上限；两文件staging `/tmp/jfsportal-t10-20260911-070908`通过SHA及安全扫描后已获批执行。
- 修复脚本返回`T10_FORWARDER_FIX_PASS`：重启后`TasksCurrent=3`、`NRestarts=0`、服务仍disabled；脚本确认157 JuiceFS PID与`/mnt/juicefs`挂载未变。152随后直接抓取metrics成功，Prometheus目标`up=1`，152业务PID和挂载未变。
- SSH恢复后的延时只读复核通过：157 forwarder为`active/disabled`、`NRestarts=0`、`TasksCurrent=3/32`、约5.6 MiB；152仍为14/14 targets、Ceph健康值0，管理服务及业务指纹均正常。证据为`inventory/T10-FORWARDER-GOMAXPROCS-FIX-SIGNOFF-20260911.md`。
- 阶段C离线签收通过：本地staging `/tmp/jfsportal-t10-20260911-091149`仅含最小故障隔离脚本，语法、SHA、固定unit指纹、异常恢复和危险操作审计通过；证据为`inventory/T10-PHASE-C-OFFLINE-PREPARATION-20260911.md`。
- T09上线后旧RUN已失效。替代RUN `20260911-172534`增加namespace mount PID/挂载、timer、SQLite新鲜度及Portal路径隔离硬门，三端SHA和152只读预检通过；Prometheus为14/14、Ceph `HEALTH_OK`、业务PID未变。证据为`inventory/T10-PHASE-C-T09-BASELINE-PREFLIGHT-SIGNOFF-20260911.md`。
- 下一步：经用户批准后在152执行新RUN唯一故障隔离命令，顺序短暂停止/恢复Portal和Prometheus；不操作T09、PD/TiKV/Ceph或157。
- RUN `20260911-172534`返回`T10_FAILURE_ISOLATION_PASS`：Portal停止窗口仅管理入口不可达，Prometheus停止窗口Portal返回stale/error，恢复后14/14 targets在线。独立复核确认T09 generation 24仍ready、Portal路径隔离有效、Ceph `HEALTH_OK`、业务PID/挂载不变；157 forwarder保持3 tasks和`NRestarts=0`。T10完成，证据为`inventory/T10-LOW-IMPACT-AND-FAILURE-ISOLATION-FINAL-SIGNOFF-20260911.md`。
- forwarder及完整管理面连续24小时观察合并到T11，避免重复等待。下一步开始T11管理员试运行。

## T09恢复及DirStats验证

- 用户已恢复T09并冻结首项需求：快速查询三级以内文件/目录及目录递归空间；页面只查SQLite快照，不同步运行`du`。
- 阶段A只读预检于2026-09-11完成，裁决`T09_DIRSTATS_PHASE_A_PASS`；业务卷已启用`DirStats`，临时META和路径未占用，集群处于空闲、全健康状态。
- 计划与证据：`docs/T09-DIRSTATS-SCALABILITY-TEST-PLAN.md`、`inventory/T09-DIRSTATS-PHASE-A-READONLY-SIGNOFF-20260911.md`。
- 阶段B 1万文件canary通过：fast约0.05～0.06秒、strict约0.09秒、`du`约0.79～0.80秒；fast/strict结果一致，Ceph对象与容量、业务指纹和TiKV pending compaction均未变化。证据为`inventory/T09-DIRSTATS-PHASE-B-10K-SIGNOFF-20260911.md`。
- 阶段B2正确性canary通过：grow、shrink、跨目录rename、hardlink和unlink共7步，fast/strict对根及两个子目录的结果均在第一次观测时与独立4 KiB对齐清单精确一致；原1万文件树、业务指纹、Ceph对象和容量均未变化。证据为`inventory/T09-DIRSTATS-PHASE-B2-CORRECTNESS-SIGNOFF-20260911.md`。
- 阶段C 10万文件通过：fast保持约0.05秒，strict约0.18秒，`du`约22秒；fast/strict统计一致，Ceph对象与容量、业务指纹和TiKV pending compaction均未变化。证据为`inventory/T09-DIRSTATS-PHASE-C-100K-SIGNOFF-20260911.md`。
- 阶段C已足以决定后台DirStats汇总、SQLite快照和前端只查快照的架构；建议跳过约需30分钟创建且只增加一个曲线点的100万档。临时卷UUID=`80a2a0da-d98a-4b47-a97a-2da488c4d1ba`及挂载继续保留，等待用户确认进入T09实现，不自动清理。
- 用户已确认进入下一步，阶段D 100万文件跳过。T09本地SQLite/API/USER与ADMIN页面实现通过：USER授权root返回200，越权root和ADMIN API均403，写方法405，SQLite连接为query-only且查询命中三级树索引。证据为`inventory/T09-DIRECTORY-SNAPSHOT-OFFLINE-SIGNOFF-20260911.md`。
- 本轮未上传或修改远端。下一步实现后台快照采集器，先在本地目录及现有T09临时卷验证generation事务切换、失败保留旧快照、60秒刷新和资源上限；通过后再提交152只读挂载及timer的sudo计划。
- T09采集器本地及157独立临时卷验证通过：10万文件/1111目录采集0.08～0.09秒，Max RSS约97～101 MiB；generation成功切换，故障时旧快照完整保留，恢复后回到ready；真实SQLite被Portal只读API正确消费。证据为`inventory/T09-NAMESPACE-COLLECTOR-INTEGRATION-SIGNOFF-20260911.md`。
- 本轮没有sudo或业务状态变更。下一步冻结152专用只读挂载、collector service/timer、USER root授权、Portal升级和回滚的最小方案，离线Gate通过后再提交完整sudo命令审批。
- 157本轮新增的`collector-validation`临时目录已在证据持久化后按精确文件清单删除；T09临时卷及10万文件树继续保留，等待最终E阶段按UUID三重校验清理。

## T09业务卷部署离线准备完成

- 时间：2026-09-11；裁决：`T09_NAMESPACE_DEPLOYMENT_OFFLINE_PASS`，证据为`inventory/T09-NAMESPACE-DEPLOYMENT-OFFLINE-SIGNOFF-20260911.md`。
- 已冻结152专用只读挂载、60秒oneshot collector、SQLite、USER opaque root授权及Portal最小升级/回滚链路；三个新增unit均为static且脚本不执行enable。
- 只读挂载和collector分别限制为20% CPU、256/192 MiB内存及低I/O权重；禁止业务挂载、PD/TiKV、Ceph、块设备和Prometheus/Grafana变更。
- 5个脚本、3个unit及代码离线Gate通过；当前没有连接或修改远端，也尚未生成实际staging。
- 下一步：从157非sudo获取固定MD5的patched v1.4.1，生成/分发RUN staging；先执行root只读preflight，回传通过后再执行唯一更新命令。完整sudo边界见`docs/T09-NAMESPACE-DEPLOYMENT-AND-SUDO-PLAN.md`。

## T09 staging分发完成

- 时间：2026-09-11；裁决：`T09_STAGING_DISTRIBUTION_PASS`，证据为`inventory/T09-STAGING-DISTRIBUTION-SIGNOFF-20260911.md`。
- RUN为`20260911-133252`，28项、`152938421` bytes；本地、157和152的清单SHA均为`d69432d0652141d54fb100fb5830e6b09fc50cc72447593e6451fa4ddfeaaedd`。
- 三端`juicefs-ro` MD5均为批准值`24fae0852051c80ca571cb2f20275d46`；152完整清单和脚本语法通过。
- 本阶段只写两台远端的RUN私有`/tmp`，无sudo、无服务变更；152三个管理服务仍为`active/disabled`，两个业务存储挂载未变。
- 下一步：审批并执行该RUN的root只读preflight；PASS后再单独审批update，不跨门自动执行。

## T09安装前只读预检完成

- 时间：2026-09-11；裁决：`T09_READONLY_PREFLIGHT_PASS`，证据为`inventory/T09-INSTALL-PREFLIGHT-SIGNOFF-20260911.md`。
- 152的T08固定SHA、管理服务状态、USER合同、FUSE、patched v1.4.1依赖、三节点2379连通性、目标路径空闲及业务指纹全部通过。
- 可用内存`857535040 KiB`、系统盘余量`795367632896 bytes`；本步骤没有安装、启动、重启或enable任何对象。
- 下一步：单独审批并执行唯一T09 update命令；失败自动精确回滚，成功后再独立签收运行态和低扰动。

## T09首次更新失败并完整回滚

- 时间：2026-09-11；裁决：`T09_UPDATE_ATTEMPT1_ROLLBACK_PASS`，证据为`inventory/T09-UPDATE-ATTEMPT1-ROLLBACK-SIGNOFF-20260911.md`。
- update内置preflight通过，但专用只读挂载60秒内未出现，脚本停止并返回失败；自动回滚返回PASS。
- 回滚后T09二进制、配置、unit、SQLite和挂载均不存在；三个管理服务为`active/disabled,NRestarts=0`，PD/TiKV PID和业务挂载未变。
- root journal确认mount进程已启动但60秒内未形成FUSE挂载；对未形成挂载执行普通卸载返回`Operation not permitted`，但该信息不足以归因mount失败。
- 权限误判已更正：157/152的`fusermount3`均为UBIP符号链接，链接显示0777；实际目标均为`root:root 4755`且SHA相同。禁止执行此前拟议的chmod。

## T09 fusermount权限误判更正

- 时间：2026-09-11；裁决：`T09_FUSERMOUNT_PERMISSION_CORRECTION`，证据为`inventory/T09-FUSE-ROOTCAUSE-AND-REPAIRED-STAGING-20260911.md`。
- 157/152真实helper均为`root:root 4755`且SHA相同；0777只是符号链接显示，不能解释首次失败，chmod方案撤回。
- RUN `20260911-134851`因错误要求`dpkg -V fuse3`无输出而标记`EVIDENCE_INVALID_PREFLIGHT_CONTRACT`，禁止执行。
- 本地preflight已改为校验解析后的helper模式与固定SHA。下一步继续只读定位`jfsportal`身份下的日志和META/Ceph访问条件，不自动重试update。

## T09专用挂载网络与凭据阻断定位

- 时间：2026-09-11；网络阻断证据为`inventory/T09-MOUNT-NETWORK-ROOTCAUSE-SIGNOFF-20260911.md`。
- 业务卷的数据引擎为Ceph；首次mount unit在`IPAddressDeny=any`下只放行了三台TiKV地址，遗漏Ceph MON/OSD public/client地址`10.3.1.6～8`，导致进程启动后RADOS初始化被阻断，60秒内不能形成挂载。
- 最小修复只放行`10.3.1.6/32`、`10.3.1.7/32`、`10.3.1.8/32`，不开放`10.3.2.0/24`，并在root只读preflight中增加MON端口和`ceph.conf`可读性门禁。
- 本地离线Gate及新RUN三端分发已完成：RUN `20260911-141910`的28项SHA在本地、157和152一致，证据为`inventory/T09-NETWORK-FIX-STAGING-DISTRIBUTION-SIGNOFF-20260911.md`。
- RUN `20260911-141910`重试已证明地址修复有效，但随后由Ceph返回`ret=-13 Permission denied`：152缺少业务卷引用的`client.juicefs` keyring；自动回滚完整通过，证据为`inventory/T09-UPDATE-ATTEMPT2-ROLLBACK-SIGNOFF-20260911.md`。
- 凭据修复版RUN `20260911-144710`已通过离线Gate、三端SHA及152 root只读preflight；只安装池级`client.juicefs`，不使用`client.admin`，证据为`inventory/T09-CEPH-CREDENTIAL-REPAIR-PREFLIGHT-SIGNOFF-20260911.md`。
- RUN `20260911-144710`重试确认Ceph认证和只读session成功，但setuid helper在systemd上下文中执行mount时仍为UID 998、有效能力0并返回`Operation not permitted`；自动回滚及keyring清理均通过，证据为`inventory/T09-UPDATE-ATTEMPT3-FUSE-BLOCKER-SIGNOFF-20260911.md`。
- 瞬时矩阵确认`RestrictAddressFamilies`和`LockPersonality`各自隐式启用`NoNewPrivileges=1`；IP过滤和`/dev/fuse`设备过滤均为0。修复版RUN `20260911-150908`仅移除冲突项，已通过离线Gate、三端SHA及152 root只读preflight，证据为`inventory/T09-NNP-MATRIX-AND-FINAL-PREFLIGHT-SIGNOFF-20260911.md`。
- RUN `20260911-150908`已证明专用只读FUSE挂载成功，但collector的`ConditionPathIsMountPoint=`被systemd 249判为不满足，SQLite未生成并触发完整自动回滚；PD/TiKV及业务挂载未变。
- collector现改用`findmnt -M`精确运行条件，update增加“首次SQLite必须非空”硬门；修复RUN `20260911-154510`已通过离线Gate、三端28项SHA和152 root只读preflight，等待唯一update命令审批。证据为`inventory/T09-UPDATE-ATTEMPT4-COLLECTOR-REPAIR-PREFLIGHT-SIGNOFF-20260911.md`。
- RUN `20260911-154510`执行后，`findmnt -M`条件通过且collector真实启动，但JuiceFS `summary`以`O_RDWR`打开虚拟`.control`，被内核只读FUSE挂载以`EROFS`拒绝；`--entries 10000`同时被CLI钳制到100。自动回滚完整通过，业务指纹未变，证据为`inventory/T09-UPDATE-ATTEMPT5-SUMMARY-READONLY-BLOCKER-SIGNOFF-20260911.md`。
- 用户已接受“三级总量完整、每个目录top 100大项+其余项聚合”的展示边界；超过top 100的逐项名称和完整文件清单不属于T09。
- collector已改为固定`summary --depth 3 --entries 100 --csv`，SQLite/API/UI支持`directory/file/aggregate`三类行；单root/API仍保留10,000行保护门，失败保留上一代快照。
- 专用控制挂载因`.control`协议采用内核rw，但固定JuiceFS参数`--atime-mode noatime`且无`allow_other/allow_root`；Portal通过独立systemd drop-in屏蔽挂载路径，仅固定命令collector可访问。旧RUN均禁止复跑。
- 修正后的代码、OpenAPI、页面、unit、更新/回滚脚本已通过本地Go测试、JavaScript语法检查和T09离线Gate。下一步生成新RUN staging、三端SHA核对和152只读preflight，随后再提交精确update命令审批。
- 修正RUN `20260911-164826`已完成本地、157、152三端29项SHA核对；152 root只读preflight返回PASS（可用内存`857602680 KiB`、系统盘余量`794154577920 bytes`）。当前未发生远端状态变更。证据为`inventory/T09-TOP100-CONTRACT-AND-REPAIRED-PREFLIGHT-SIGNOFF-20260911.md`。
- 下一步：经用户明确批准后，在152执行唯一update命令；成功后验收top 100/聚合行、Portal路径隔离、快照新鲜度、资源占用及业务指纹。
- RUN `20260911-164826`的update已获批执行：专用挂载成功、collector日志确认`depth=3, topN=100`且SQLite完成更新；随后运行态验收错误地要求`findmnt`出现`noatime`而失败，自动回滚返回`portal_restored=true business_unchanged=true`。`--atime-mode noatime`是JuiceFS元数据策略，不等于FUSE内核挂载选项；已删除无效断言，旧RUN禁止复用。
- 修复RUN `20260911-165833`已完成本地、157、152三端29项SHA核对，`SHA256SUMS`摘要为`ed080520bd97ca9e7af33bac16f989e0cda71c089b8105ec601f7a594528bb51`；152只读preflight再次PASS。下一步需按新RUN重新批准唯一update命令。
- RUN `20260911-165833`已获批并返回`T09_UPDATE_PASS`。真实业务快照为`518617337856 bytes / 404 files / 9 dirs`，包含114个具名文件、6个具名目录和1个聚合项；`/test_dir/...`汇总287个文件及2个目录。Portal mount namespace不可见控制挂载，timer连续按约60秒更新，Ceph `HEALTH_OK`且业务PID/挂载未变。T09正式闭环，证据为`inventory/T09-BUSINESS-NAMESPACE-DEPLOYMENT-FINAL-SIGNOFF-20260911.md`。
