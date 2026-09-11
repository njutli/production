# T08修复版staging分发与安装前检查签收

> 时间：2026-09-10 23:36 CST  
> 裁决：`T08_REPAIRED_STAGING_PREFLIGHT_PASS`  
> 远端状态变更：仅在157和152的`/tmp`新增staging；无sudo、无服务重启。

## 分发完整性

- 修复版staging：`/tmp/jfsportal-t08-20260910-232451`，约12 MiB，清单20项。
- 本地`SHA256SUMS`为`cf624108668ea539da3b0ec483262e61ac3de52f8fd6b368733c6b59cadd4c16`。
- 首次本地到157的传输连接中断，SHA门准确发现4项缺失及1项二进制损坏；只补传这5项后，157完整20项校验通过。
- 在157通过完整SHA以前没有向152转发；转发前确认152无同名目录。
- 152完整SHA及两个shell脚本的`bash -n`均通过。

## 修复内容与边界

- Portal二进制、`portal-userctl`和更新脚本与首次staging相同。
- Portal unit SHA为`80d6808ca151c2cc946ab31d320c8daeb4270555847022db929e5737e8594c5f`。
- 唯一功能差异是新增`IPAddressAllow=10.20.1.152/32`，供152本机访问自身TLS监听完成验收；外部来源仍仅157，不放行管理网段，不修改UFW。

## 152安装前状态

- T07 Portal二进制、三项Web文件和unit五项SHA均与冻结值一致。
- `juicefs-portal`、`juicefs-prometheus`、`juicefs-grafana`均为`active/disabled`。
- 8443未监听；新RUN的userctl、账户、会话密钥、bootstrap凭据、TLS文件和备份路径均不存在。
- PD PID=`1589960`、TiKV PID=`2088516`；`/mnt/jfs-tikv`与`/mnt/dbwal`挂载正常。

## 待审批命令

```bash
sudo /usr/bin/bash /tmp/jfsportal-t08-20260910-232451/scripts/t08-update-auth.sh /tmp/jfsportal-t08-20260910-232451
```

脚本只更新Portal受管文件并重启Portal，失败自动恢复T07；不重启Prometheus、Grafana或任何业务服务。
