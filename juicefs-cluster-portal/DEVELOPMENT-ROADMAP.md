# JuiceFS 集群管理门户总体开发计划

> 更新日期：2026-09-22
>
> 本文统一记录平台的三个开发阶段、目标和范围。具体功能设计由对应专题文档承载，执行待办见[TODO](TODO.md)。阶段编号仅用于Portal开发，与`prod-deploy`中的性能调优阶段独立。

## 一、三个开发阶段

| 阶段 | 目标 | 主要内容 | 当前状态 |
|---|---|---|---|
| 第一阶段：只读监控 | 通过统一网页查看集群运行与用量 | 组件健康与拓扑、节点与磁盘、容量、实时带宽及趋势、三级目录用量、ADMIN/USER查看权限 | 功能开发与阶段验收已完成 |
| 第二阶段：用户管理与配额管理 | 统一业务用户身份，并通过Portal管理用户目录及配额 | LDAP统一身份接入与管理流程、Portal ADMIN登记用户目录并管理JuiceFS原生目录配额、管理操作权限与审计；普通用户个人额度页与目录查看授权后置 | 总开发计划已编写，待S2-0核对和实施 |
| 第三阶段：客户现场快速部署 | 在客户提供的主服务节点上，根据用户提供的所有节点信息完成快速部署 | 固定部署包、配置向导、环境预检、受控批量安装、断点恢复和验收交付 | 方案与开发计划草案已编写，待D0确认和开发 |

完整交付顺序为第一阶段 → 第二阶段 → 第三阶段。第三阶段通用配置、预检和执行骨架可提前开发；用户与配额的联合部署、验收依赖第二阶段形成可用成果。

阶段文档分别从[01只读监控](stages/01-readonly-monitoring/README.md)、[02用户与配额](stages/02-user-quota/README.md)、[03快速部署](stages/03-deployment/README.md)进入。

整体组件关系及子模块调用流程见[平台架构与流程图](docs/PORTAL-ARCHITECTURE-AND-FLOWS-20260922.md)，其中明确区分已实现能力与后续规划。

## 二、第一阶段：只读监控

已完成对JuiceFS、PD/TiKV、Ceph、主机和磁盘指标的接入，以及网页查询、目录统计、权限隔离和低扰动验收；当前中央部署节点为`10.20.1.152`。

- 功能与使用说明：[当前阶段系统功能说明](stages/01-readonly-monitoring/CURRENT-STAGE-SYSTEM-OVERVIEW-20260914.md)。
- 验收依据：[当前部署验收摘要](stages/01-readonly-monitoring/inventory/CURRENT-DEPLOYMENT-ACCEPTANCE-SUMMARY-20260914.md)。
- 后续运维事项继续在[TODO](TODO.md)中跟踪。

## 三、第二阶段：用户管理与配额管理

业务用户采用路线A，由LDAP统一管理，各客户端使用一致的UID/GID。Portal账号与业务文件身份分别管理；本阶段由ADMIN登记业务用户及目录，通过受控配额服务查询、设置和调整JuiceFS目录配额。普通用户个人额度页、目录查看授权及个人三级目录统计后置，第一阶段已有的USER只读监控保持不回归。

本阶段同时落实后端凭据保护、服务账号职责划分，以及业务挂载启用`root-squash`、独立管理挂载承担目录交付的配置要求。首版由运维经LDAP工具开户，Portal查询并登记已有LDAP用户；Portal直接开户、停用和改组作为后续独立增量，不纳入本次估算。

[第二阶段总开发计划](stages/02-user-quota/USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)统一编排S2-0～S2-5，复用配额专题Q0～Q4。开发、LDAP/后端认证准备和有限试点粗估12～22人日，不含审批与维护窗口等待；先完成最小接口及接入核对，再并行开展接入准备和功能开发。

| 事项 | 详细文档 |
|---|---|
| 总体范围、实施顺序、工作量与联合验收 | [第二阶段总开发计划](stages/02-user-quota/USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md) |
| 调研结论、整体方案与权限关系 | [用户管理与配额管理调研报告](stages/02-user-quota/features/juicefs-user-quota-management/USER-AND-QUOTA-MANAGEMENT-RESEARCH-20260914.md) |
| 路线A的账号规划、客户端接入及使用注意事项 | [LDAP统一用户管理实施说明](stages/02-user-quota/features/juicefs-user-quota-management/JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md) |
| 配额功能的开发、验证及交付安排 | [配额管理功能开发计划](stages/02-user-quota/features/juicefs-user-quota-management/JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md) |

路线B/C保留为已有账号冲突场景的历史备选；本期采用路线A，客户端本地用户管理助手暂不开发。

阶段完成以一台获准客户端上的两个LDAP用户身份与目录权限、管理员配额操作、后端凭据保护及权限验证通过为准；跨客户端一致性留到第三阶段，个人额度页和目录查看授权不作为本阶段验收条件。具体验收用例由上述专题计划维护。

## 四、第三阶段：客户现场快速部署

用户指定客户提供的一台主服务节点，并提供所有相关节点的信息，在该节点上发起快速部署，最终得到可使用的系统。

用户计划为第三阶段另行提供三台空白服务节点和两台空白客户端，作为从零部署及跨客户端身份、共享文件和配额联合验收环境；资源交付前不把现有集群节点或WSL视为这些新机器。

设计采用“固定版本部署包＋配置向导＋主节点受控执行器”：先检查节点、网络、磁盘、身份和依赖，生成变更计划，由可信运维批准后批量执行。运行期Portal不持有任意SSH或root执行权，不新增客户端常驻助手。

- [部署方案](stages/03-deployment/CUSTOMER-DEPLOYMENT-DESIGN-20260922.md)：定义首版新集群范围、持久化配置、LDAP与配额衔接、失败恢复和交付标准。
- [开发计划书](stages/03-deployment/CUSTOMER-DEPLOYMENT-DEVELOPMENT-PLAN-20260922.md)：按D0～D6推进，先验证高风险兼容点，再做CLI、组件部署和向导；第三阶段初估19～29人日，不含第二阶段未完成工作和客户环境准备。

首个OS/版本组合、Ceph持久化模板、LDAP来源和自启策略在D0冻结。当前仅完成设计，不据此修改现有集群或批准sudo操作。

现有[`deploy/`](deploy/)和[`prod-deploy/`](../prod-deploy/)中的配置及脚本可作为复用来源。现有152部署与更新经验是本阶段的参考，客户主服务节点由客户环境决定。

## 五、文档维护方式

- 本文负责三个大阶段的目标、范围、状态及专题索引；阶段变化首先更新本文。
- [README](README.md)提供项目入口，[TODO](TODO.md)记录当前待办。
- 各阶段材料归入`stages/`下对应目录；第二阶段的[features](stages/02-user-quota/features/README.md)保留功能专题结构，后续讨论产生的细节更新到对应专题。
- [开发与部署说明](docs/DEVELOPMENT-DEPLOYMENT-STEPS.md)记录现有环境的开发、服务更新及运维操作流程；第三阶段的快速部署产品设计由上述部署方案及开发计划承载。
