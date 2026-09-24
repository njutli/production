# 第二阶段：用户管理与配额管理

状态：总开发计划已编写，待S2-0核对和实施。业务文件用户已选定路线A，由LDAP统一管理；路线B/C保留为历史备选，本期不实施，暂不开发客户端本地用户管理助手。

| 材料 | 用途 |
|---|---|
| [平台架构与子模块流程图](../../docs/PORTAL-ARCHITECTURE-AND-FLOWS-20260922.md) | 服务进程和worker关系、LDAP接入、查询、配额修改、恢复及清理流程 |
| [第二阶段总开发计划](USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md) | 首版范围、S2-0～S2-5实施顺序、代码量、12～22人日估算及联合验收 |
| [用户与配额调研及总体方案](features/juicefs-user-quota-management/USER-AND-QUOTA-MANAGEMENT-RESEARCH-20260914.md) | 各产品机制、方案比较、本项目用户与配额设计 |
| [路线A实施与注意事项](features/juicefs-user-quota-management/JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md) | 统一身份、客户端接入、root处理及后续发现 |
| [配额管理开发计划](features/juicefs-user-quota-management/JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md) | Portal配额功能、控制服务、验证及交付 |
| [完整特性索引](features/README.md) | 专题材料及路线B/C历史开发计划 |

后续讨论直接更新相应专题，不在本索引重复详细方案。三个大阶段的关系见[总体开发计划](../../DEVELOPMENT-ROADMAP.md)，当前待办见[TODO](../../TODO.md)。
