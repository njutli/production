# T08 本地认证、RBAC与HTTPS实施计划

## 1. 目标与范围

T08把当前“手工输入Bearer token”的调试方式替换为可用的本地登录，并由后端强制执行`USER`/`ADMIN`权限。当前资料没有LDAP、AD或OIDC身份源，因此本阶段使用本地账户；以后接入统一身份源时只替换认证入口，不改变管理员API的RBAC边界。

文件/目录浏览和授权路径用量仍为T09延期项。因此USER账户本阶段可以登录、查看自己的身份和安全退出，但没有集群监控权限；即使直接构造管理员请求也必须返回403。

## 2. 冻结设计

| 项目 | 设计 |
|---|---|
| 本地账户 | 初始`admin`和`user`各一个；密码使用48位十六进制随机值 |
| 密码存储 | Argon2id，64 MiB、3次迭代、并行度2、16字节随机salt、32字节输出 |
| 会话 | HMAC-SHA256签名、8小时有效、服务重启后仍可验证 |
| Cookie | `HttpOnly; Secure; SameSite=Strict; Path=/` |
| 暴力破解限制 | 同一来源5分钟内失败5次后阻断5分钟；Argon2同时校验最多2个 |
| 浏览器入口 | 通过157 SSH隧道映射后的`https://localhost:8443/` |
| 健康入口 | 保留`http://127.0.0.1:8080/api/v1/health`供本机验收 |
| TLS | 在152生成带152/ceph-node3及SSH隧道localhost SAN的397天自签名证书；私钥不离开152 |
| 网络边界 | Portal TLS只监听152管理IP；systemd仅放行loopback、152自身验收及157外部来源；Prometheus/Grafana仍为loopback，不修改UFW |
| 审计 | systemd journal记录服务异常；密码、Cookie、Bearer token和bootstrap内容不进入报告 |

自签名证书可以保证SSH隧道内的TLS会话和Secure Cookie正常工作，但浏览器默认不会信任。T08签收时记录证书SHA256指纹；正式消除浏览器告警需在T11换成组织内部CA签发证书，或由管理员核对指纹后导入该证书。T08不擅自安装企业CA。外部访问使用`ssh -L 8443:10.20.1.152:8443 thailand`，不需要本机直接登录152。

## 3. API和页面行为

- `POST /api/v1/session`：仅接收小于4 KiB的JSON用户名/密码，成功后设置会话Cookie。
- 开启Secure Cookie后，明文HTTP登录返回426；loopback HTTP只保留健康检查和Bearer自动验收。
- `DELETE /api/v1/session`：清除会话Cookie。
- `GET /api/v1/me`：返回当前subject、role和会话过期时间。
- `/api/v1/admin/**`：只有ADMIN后端放行；未登录返回401，USER返回403。
- 除登录/退出外仍禁止POST/PUT/PATCH/DELETE，不增加任何集群或文件写接口。
- 页面启动时先恢复会话；未登录显示登录页，ADMIN显示八个实时页面，USER只显示T09延期提示。

## 4. 凭据与文件权限

全部文件只放152系统盘：

```text
/etc/juicefs-portal/users.json                    root:jfsportal 0640
/etc/juicefs-portal/session-secret                root:jfsportal 0640
/etc/juicefs-portal/tls.key                       root:jfsportal 0640
/etc/juicefs-portal/tls.crt                       root:root      0644
/etc/juicefs-portal/bootstrap-credentials.txt     root:root      0600
```

`bootstrap-credentials.txt`只用于首次把随机密码交给用户，不打印到工具输出、日志、测试证据或Git。用户取走后应在单独批准下删除该精确文件；账户文件只含密码哈希。

## 5. 执行与回滚

离线Gate、staging上传及只读preflight均不需要sudo。安装阶段只执行一个受限脚本：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t08-RUN_ID/scripts/t08-update-auth.sh /tmp/jfsportal-t08-RUN_ID
```

脚本展开动作只有：

1. 核对主机、T07已安装文件固定SHA、服务disabled状态、8443未占用及T08目标文件不存在；
2. 备份Portal二进制、Web、环境文件和unit到`/var/lib/juicefs-portal/t08-backup-RUN_ID`；
3. 安装新Portal、`portal-userctl`、Web和Portal unit；
4. 生成本地账户、会话密钥及TLS证书，并设置上述精确权限；
5. 只执行`systemctl daemon-reload`和`systemctl restart juicefs-portal.service`；
6. 验证ADMIN=200、USER访问管理员API=403、匿名=401、非认证写操作=405、TLS安全头、业务PID和挂载；
7. 任一失败恢复T07文件、删除本次精确创建的T08文件，并只重启Portal。

不会重启Prometheus、Grafana或任何业务服务，不会enable服务，不会修改防火墙、Ceph、PD/TiKV、JuiceFS、NVMe和业务路径。

## 6. 完成标准

- 两种账户均能通过HTTPS登录且`/me`角色正确；
- ADMIN八页API均为实时Prometheus数据；USER直接构造管理员请求稳定返回403；
- 无效/篡改/过期Cookie返回401，登录限流生效；
- Prometheus和Grafana仍只监听loopback；Portal仅新增152管理IP上的TLS 8443，外部来源只接受157，同时允许152访问自身地址完成健康验收；
- 三个管理服务仍为`active/disabled`且无异常重启；
- PD/TiKV PID、业务挂载和Ceph指标健康状态不变。
