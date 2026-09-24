# JuiceFS 集群管理门户状态与待办

> 更新时间：2026-09-22
>
> 三个大阶段的目标与范围见[总体开发计划](DEVELOPMENT-ROADMAP.md)；第一阶段验收依据见[部署验收摘要](stages/01-readonly-monitoring/inventory/CURRENT-DEPLOYMENT-ACCEPTANCE-SUMMARY-20260914.md)。

## 当前推进

- 第二阶段：[总开发计划](stages/02-user-quota/USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)已编写，按S2-0～S2-5实施，粗估12～22人日。下一步S2-0核对版本/最小配额接口、LDAP产品与ID规划、后端认证及挂载差异；尚未开始开发或环境实施。配置细节见[路线A实施说明](stages/02-user-quota/features/juicefs-user-quota-management/JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md)，功能细节见[配额计划](stages/02-user-quota/features/juicefs-user-quota-management/JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)。
- 第二阶段已补齐数据生命周期设计：预览24小时、终态详情180天、审计730天，未决保护、旧操作防重放、有界备份及恢复授权核对纳入S2-2/S2-4；当前仅完成设计，待开发和验收。
- 第二阶段先以一台获准客户端、两个LDAP业务用户完成本期功能及安全验收；不默认改动157现有业务挂载，也不把WSL或152作为第二客户端。跨客户端身份、共享文件及配额共同生效由第三阶段验收。
- 第三阶段：[部署方案](stages/03-deployment/CUSTOMER-DEPLOYMENT-DESIGN-20260922.md)与[开发计划书](stages/03-deployment/CUSTOMER-DEPLOYMENT-DEVELOPMENT-PLAN-20260922.md)已编写。下一步确认D0的OS/版本、持久化模板和LDAP依赖，完成最小兼容验证；尚未开发或上环境执行。
- 用户计划为第三阶段另行提供三台空白服务节点及两台空白客户端；资源交付后核对主机、持久化磁盘和网络，再执行从零部署及双客户端联合验收。

## 第一阶段已完成

| ID | 功能 | 状态 |
|---|---|---|
| T00～T04 | 节点选择、边界冻结、本地骨架和部署准备 | DONE |
| T05 | 152 基础 Portal/Prometheus/Grafana 环境 | DONE |
| T06 | JuiceFS、PD/TiKV、Ceph、主机、NVMe 指标接入 | DONE |
| T07 | 真实数据管理员门户与动态拓扑 | DONE |
| T08 | 本地账户、ADMIN/USER RBAC、HTTPS | DONE |
| T09 | 业务卷三级递归用量、top 100+聚合、SQLite 异步快照 | DONE |
| T10 | 资源约束、低扰动和 Portal/Prometheus 故障隔离 | DONE |
| T11-A | 前 2 小时连续试运行，25/25 样本通过 | DONE |
| T11-B | 62小时39分长期试运行，752/752样本通过并完成归档 | DONE |
| T12 | JuiceFS/Ceph 读写带宽趋势曲线 | DONE |

## 第一阶段交付与运维事项

| 优先级 | 工作 | 完成条件 |
|---|---|---|
| P1 | 运维交付 | 固化人工启停、健康检查、备份和精确回滚步骤；继续保持不自启，除非用户另行批准 |
| P1 | 凭据收口 | 管理员确认已接收初始密码后，经单独批准删除 bootstrap 明文文件 |
| P2 | TLS | 具备组织 CA 后替换自签名证书 |
| P2 | Portal登录身份源 | 是否用LDAP/OIDC替换或补充Portal本地账号纳入第二阶段讨论；业务文件用户采用LDAP已确定，两项分别设计 |
| P2 | 告警通知 | 在保持只读和故障隔离的前提下接入外部通知渠道 |

## 第一阶段范围之外

以下为第一阶段的范围边界；后续阶段按[总体开发计划](DEVELOPMENT-ROADMAP.md)及专题方案确定功能范围。

- 完整文件清单、搜索、mtime、内容预览和下载；
- 集群启停、配置修改、扩缩容、数据操作或自动修复；
- 门户高可用和跨节点自动故障转移。
