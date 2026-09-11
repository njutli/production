# T09业务卷目录快照首次更新失败与回滚签收

> 时间：2026-09-11
> 裁决：`T09_UPDATE_ATTEMPT1_ROLLBACK_PASS`；部署未生效，等待只读日志归因。

## 结果

获批的RUN更新命令先通过内置二次preflight，随后专用只读挂载在60秒内没有出现，脚本按硬门退出并自动调用精确回滚：

```text
T09_UPDATE_FAIL rc=1; invoking exact rollback
T09_ROLLBACK_PASS backup=/var/lib/juicefs-portal/t09-backup-20260911-133252 portal_restored=true business_unchanged=true
```

回滚后的独立非sudo复核确认：

- Portal、Prometheus、Grafana均为`active/disabled`且`NRestarts=0`；
- 两个T09二进制、两个配置、三个unit、SQLite和专用挂载全部不存在；
- Portal已恢复T08版本；
- PD/TiKV PID仍为`1589960/2088516`；
- `/mnt/jfs-tikv`仍为`/dev/nvme1n1` ext4，`/mnt/dbwal`仍为tmpfs。

## 已确认现象与权限误判更正

root只读journal显示：JuiceFS mount进程已启动，但60秒内没有形成FUSE挂载；回滚在`12:41:55（UTC+7）`对未成功形成的挂载执行普通卸载时返回`fusermount: ... Operation not permitted`。该错误只证明卸载操作无有效挂载可处理，不能单独归因为helper权限。

进一步对比确认157和152结构完全相同：`/usr/bin/fusermount3`是UBIP创建的符号链接，符号链接按Linux语义显示`lrwxrwxrwx`；两端实际目标均为`/opt/ubip/ubipower-access-1.3.0/bin/fusermount3`、`root:root 4755`，SHA256均为`fa2dc1bb00be297004cfa4fc82dab3a6d568042736f7eb5b6fd8de49804db2d1`。因此“0777导致失败”的结论撤回，禁止执行此前拟议的chmod。

## 下一步

后续只读归因已经确认根因不在FUSE helper：业务卷使用`Storage=ceph`、`Bucket=ceph://juicefs-data`，挂载在读取TiKV元数据后还必须直连Ceph public/client网络；首次部署的mount unit设置了`IPAddressDeny=any`，却只放行三台TiKV的`10.20.1.x`地址，遗漏Ceph MON/OSD所在的`10.3.1.6～8`，因此进程能够启动但RADOS数据面初始化被systemd网络沙箱阻断，60秒内不能形成挂载。

最小修复是只增加`10.3.1.6/32`、`10.3.1.7/32`、`10.3.1.8/32`，不放行Ceph内部复制使用的`10.3.2.0/24`；同时在root只读preflight中增加三个MON v2端口和`jfsportal`读取`ceph.conf`的检查。修复仅完成本地离线验证后才生成新RUN，旧RUN均不得重试。
