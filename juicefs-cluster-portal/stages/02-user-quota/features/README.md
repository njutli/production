# Features

本目录管理第二阶段各特性的需求、调研、设计、实现与验收材料。返回[第二阶段入口](../README.md)或[总体开发计划](../../../DEVELOPMENT-ROADMAP.md)。

## 特性索引

- [JuiceFS 用户与配额管理](juicefs-user-quota-management/README.md)
  - [路线A：LDAP统一用户管理实施与注意事项](juicefs-user-quota-management/JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md)：本期身份路线及后续Portal开发的持续更新依据；不开发客户端助手。
  - [配额管理功能开发计划](juicefs-user-quota-management/JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)：本期采用LDAP统一业务账号（路线A），新增功能待实施。
- [JuiceFS 多客户端账号映射（历史备选，本期不实施）](juicefs-user-id-mapping/JUICEFS-USER-ID-MAPPING-DEVELOPMENT-PLAN-20260921.md)
  - [路线B：按用户名与组名自动映射](juicefs-user-id-mapping/JUICEFS-NAME-AUTO-MAPPING-DEVELOPMENT-PLAN-20260922.md)
  - [路线C：按客户端显式映射](juicefs-user-id-mapping/JUICEFS-USER-ID-MAPPING-DEVELOPMENT-PLAN-20260921.md)
