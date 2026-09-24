# JuiceFS 用户与配额管理

本目录用于管理 JuiceFS 用户管理、目录隔离、配额控制及其安全边界等新特性的需求、调研、设计、实施与验收文档。

当前决定（2026-09-22）：采用路线A，业务用户统一经LDAP管理；配额功能待开发。路线B/C仅作为兼容已有账号的历史备选保留。

路线A的后续讨论、配置注意点和验证发现集中维护在下面的路线A文档中；影响配额或Portal接口与权限的决定，同时同步主报告及配额计划。暂不开发客户端助手。

## 文档索引

- [LDAP产品选型调研（2026-09-23）](LDAP-PRODUCT-SELECTION-RESEARCH-20260923.md)：比较FreeIPA、389 Directory Server、OpenLDAP三种开源Linux身份服务，记录首选条件、部署边界和待核验项。
- [路线A：LDAP统一用户管理实施与注意事项（2026-09-22）](JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md)：本期实施与Portal集成依据，记录身份范围、root、开户/停用、缓存、待确认配置和最小验证；持续更新。
- [用户管理与配额管理方案调研（2026-09-14）](USER-AND-QUOTA-MANAGEMENT-RESEARCH-20260914.md)
- [本项目方案（调研报告第十一节）](USER-AND-QUOTA-MANAGEMENT-RESEARCH-20260914.md#十一本项目用户管理与配额管理方案)：已选定LDAP身份路线，说明可信root、私有目录及152集中配额控制；新增功能尚未实施。
- [配额管理功能开发计划（2026-09-22）](JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md)：目录登记、原生配额、Portal集成、接入安全，以及一台获准客户端上两个LDAP用户的联合验收；两客户端一致性留到第三阶段，不开发身份映射。
- [历史路线B：名称自动映射开发计划（2026-09-22）](../juicefs-user-id-mapping/JUICEFS-NAME-AUTO-MAPPING-DEVELOPMENT-PLAN-20260922.md)：保留此前按名称生成配置及复用C转换核心的设计，本期不实施。
- [历史路线C：显式映射开发计划（2026-09-21）](../juicefs-user-id-mapping/JUICEFS-USER-ID-MAPPING-DEVELOPMENT-PLAN-20260921.md)：保留按客户端显式配置的设计，本期不实施。
- [JuiceFS 用户管理与 LDAP 讨论记录（2026-09-14）](JUICEFS-USER-MANAGEMENT-AND-LDAP-DISCUSSION-20260914.md)
