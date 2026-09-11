# T08首次更新失败与回滚签收

> 时间：2026-09-10 23:15 CST  
> 裁决：`T08_ATTEMPT1_ROLLBACK_PASS`  
> 业务影响：无。

## 现象与根因

- 已批准脚本使用首次staging `/tmp/jfsportal-t08-20260910-230425`执行。
- Portal重启后，loopback HTTP短暂拒绝后恢复；`10.20.1.152:8443`已监听，但152本机对该地址的TLS健康请求持续超时。
- 原unit设置`IPAddressDeny=any`，只放行loopback和`10.20.1.157/32`；152访问自身管理IP时来源为`10.20.1.152`，因此被systemd IP过滤拒绝。
- 这是验收网络合同缺项，不是Portal认证、TLS或业务集群故障。

## 自动回滚结果

- 更新脚本未返回PASS，并按设计恢复T07 Portal二进制、Web、环境和unit，删除本次新建的userctl、账户、会话密钥、bootstrap凭据和TLS文件。
- 回滚后二进制、三项Web文件和unit五项SHA与T07冻结值完全一致。
- Portal健康接口恢复`{"mode":"live","status":"ok"}`；Portal、Prometheus、Grafana仍为`active/disabled`且`NRestarts=0`。
- PD PID=`1589960`、TiKV PID=`2088516`未变；`/mnt/jfs-tikv`和`/mnt/dbwal`挂载未变。
- 未操作Prometheus、Grafana、PD、TiKV、Ceph、JuiceFS、NVMe或业务数据。

## 最小修复

- Portal unit只增加`IPAddressAllow=10.20.1.152/32`，用于152访问自身TLS地址完成健康与RBAC验收。
- loopback许可和157唯一外部来源许可保持不变，不放行整个管理网段，不修改UFW。
- 修复版staging `/tmp/jfsportal-t08-20260910-232451`已通过离线Gate；因载荷发生修改，尚未在未重新获批的情况下上传远端。
