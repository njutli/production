# T08认证、RBAC与HTTPS正式签收

> 完成时间：2026-09-10 23:53 CST  
> 裁决：`T08_PASS`  
> 部署节点：`10.20.1.152（ceph-node3）`

## 执行结果

- 修复版命令返回`T08_UPDATE_PASS`，备份位于`/var/lib/juicefs-portal/t08-backup-20260910-232451`。
- 脚本内root验收返回：ADMIN登录及管理员API 200、USER访问管理员API 403、匿名访问401、非授权写方法405。
- 本地账户密码仅以Argon2id哈希保存在users文件；8小时HMAC签名Cookie启用`HttpOnly`、`Secure`和`SameSite=Strict`。
- 随机bootstrap明文密码仅在152的`/etc/juicefs-portal/bootstrap-credentials.txt`中以root-only权限保存，内容未进入输出、报告或Git。

## 独立只读复核

- 152 loopback健康接口返回`{"mode":"live","status":"ok"}`。
- 157访问`https://10.20.1.152:8443/api/v1/health`成功，匿名访问管理员API返回401。
- 151访问8443在3秒内超时；systemd网络限制实现“152自身验收及157唯一外部来源”，未放行整个管理网段，也未修改UFW。
- Portal、Prometheus、Grafana均为`active/running`、`disabled`、`NRestarts=0`。
- Prometheus与Grafana继续只监听loopback；Portal监听`127.0.0.1:8080`及`10.20.1.152:8443`。

## 安装指纹

| 对象 | SHA256 |
|---|---|
| Portal | `9a21615c1ad3c9abb14763c21ea9e219a2ed17fadf3338e02aec3d4232bad189` |
| `portal-userctl` | `5d65e9f44d7625c41072ed84ec86781ecfcd0b85caf5a87bfa9f7bfc1dd63616` |
| `index.html` | `9866628321973e85d6f673a478e90b70c7cba977ca55dcefbc08f1936434d0c9` |
| `styles.css` | `c89d76472798096e9d94deb35c7724d1cbbe183ad5148bf8bb63532040912af4` |
| `app.js` | `efc6cfeed574179575637e65f34431f0bd2bfcfac8e16888936e7494010c2aec` |
| Portal unit | `80d6808ca151c2cc946ab31d320c8daeb4270555847022db929e5737e8594c5f` |

## TLS证书

- Subject：`CN=ceph-node3`。
- 有效期：2026-09-10 15:51:06 UTC 至2027-10-12 15:51:06 UTC。
- SHA256指纹：`78:2A:A7:57:1D:74:FC:60:29:46:EC:DD:2E:7E:6B:74:C3:28:C9:17:63:20:7E:FF:15:6B:F1:46:CF:34:CD:F0`。
- 当前为自签名证书；用户经157 SSH隧道访问时应先核对指纹，组织CA替换留到T11。

## 业务安全闭环

- 更新只执行Portal受管文件替换、`systemctl daemon-reload`及Portal重启；未重启Prometheus、Grafana或业务服务。
- PD PID=`1589960`、TiKV PID=`2088516`保持不变。
- `/mnt/jfs-tikv`仍为`/dev/nvme1n1`上的ext4，`/mnt/dbwal`仍为tmpfs；未操作Ceph、JuiceFS、NVMe或业务数据。
- 首次失败已自动恢复T07，详见`T08-UPDATE-ATTEMPT1-ROLLBACK-SIGNOFF-20260910.md`；修复版执行成功，无待处理运行态异常。

## 用户后续动作

1. 建立`ssh -L 8443:10.20.1.152:8443 thailand`隧道并访问`https://localhost:8443/`。
2. 管理员在152上以sudo读取root-only bootstrap凭据，分别验证ADMIN与USER页面。
3. 确认凭据已安全保存后，另行批准删除`/etc/juicefs-portal/bootstrap-credentials.txt`。
4. T09继续延期；下一阶段为T10低扰动、安全和故障验收。
