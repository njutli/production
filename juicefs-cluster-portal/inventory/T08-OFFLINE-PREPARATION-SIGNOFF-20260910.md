# T08 认证与RBAC离线准备签收

> 时间：2026-09-10  
> 裁决：`T08_OFFLINE_PREPARATION_PASS`  
> 远端状态变更：无。

## 完成内容

- 本地账户文件与Argon2id密码校验；参数为64 MiB、3次迭代、并行度2。
- 8小时HMAC-SHA256签名会话，Cookie为`HttpOnly; Secure; SameSite=Strict`。
- 同一来源5次失败后的5分钟登录阻断，以及最多2个并行Argon2校验槽。
- ADMIN/USER后端强制RBAC；Bearer token仅保留给root侧自动验收，并改为常量时间比较。
- 登录、会话恢复、退出和普通用户延期提示页面；前端不再包含默认token输入框。
- Portal双监听能力：loopback HTTP健康口及管理网HTTPS 8443；Prometheus/Grafana配置未改变。
- CSP、HSTS、DENY frame、no-referrer及浏览器权限限制响应头。
- `portal-userctl`一次性生成账户哈希、会话密钥及root-only bootstrap凭据。
- 单一远端更新脚本、自动回滚及root侧只读RBAC验收脚本。

## 离线验证

- `go test -count=1 ./...`通过，包括ADMIN登录、USER 403、Cookie篡改/过期、限流、退出和写方法拒绝测试。
- `go vet ./...`、`node --check web/app.js`、OpenAPI解析和shell语法检查通过。
- `portal-userctl`临时输出只含ADMIN/USER两个Argon2id哈希，三个输出文件初始权限均为0600。
- 本机临时TLS端到端冒烟通过：ADMIN登录200且可访问管理员API，USER登录200但管理员API为403；临时服务、Cookie和凭据随后已清理。
- `T08_OFFLINE_GATE_PASS`。

## 首次 Staging

- 路径：`/tmp/jfsportal-t08-20260910-230425`。
- 清单文件：20项；大小约12 MiB。
- `SHA256SUMS`：`aed9070932572303e62e4da7484f65d313127f1d0d0d9e99ae46785e4dbb3c2b`。
- Portal：`9a21615c1ad3c9abb14763c21ea9e219a2ed17fadf3338e02aec3d4232bad189`。
- `portal-userctl`：`5d65e9f44d7625c41072ed84ec86781ecfcd0b85caf5a87bfa9f7bfc1dd63616`。
- 更新脚本：`d9525f8ca1b87709cacdf50c48fc86ae91d24bd45e99b21bf84cdd7a57fb11a9`。
- Portal unit：`725bafff5c6d749d783879473763fa26612f5c5c81096989933be3b3301f43ce`（后续实机发现缺少152自身访问许可，已被修复版取代）。
- 完整`sha256sum -c SHA256SUMS`通过；内容扫描未发现真实密码、Cookie、TLS私钥或生产token。

## 已确认的152前置状态

- `10.20.1.152:443`与`:8443`均未监听；152没有Nginx或Caddy，存在OpenSSL。
- UFW为`active/enabled`；T08不修改其规则，Portal TLS只监听152管理IP；systemd除loopback和152自身验收外仅允许157外部来源，并将在部署后从157验证可达性。
- 当前T07 Portal二进制、Web及unit SHA已冻结为更新脚本的防覆盖前置条件。
- `portal-userctl`、users、session-secret及TLS文件均不存在。
- T08不安装新代理、不修改防火墙，不enable或操作业务服务。

## 下一步

首次更新及回滚见`inventory/T08-UPDATE-ATTEMPT1-ROLLBACK-SIGNOFF-20260910.md`。修复后的staging `/tmp/jfsportal-t08-20260910-232451`已完成远端分发与只读preflight，见`inventory/T08-REPAIRED-STAGING-PREFLIGHT-SIGNOFF-20260910.md`；下一步单独审批新RUN的唯一sudo更新脚本。

## 修复后 Staging

- 路径：`/tmp/jfsportal-t08-20260910-232451`，清单20项、约12 MiB。
- `SHA256SUMS`：`cf624108668ea539da3b0ec483262e61ac3de52f8fd6b368733c6b59cadd4c16`。
- Portal及`portal-userctl`未变；更新脚本未变。
- Portal unit：`80d6808ca151c2cc946ab31d320c8daeb4270555847022db929e5737e8594c5f`。
- 唯一功能差异：增加`IPAddressAllow=10.20.1.152/32`；不扩大外部来源范围。
- 完整`go test`、`go vet`、前端/OpenAPI/shell检查及`T08_OFFLINE_GATE_PASS`均通过。
