# T09业务卷只读目录快照staging分发签收

> 时间：2026-09-11 13:29～13:39 CST
> 裁决：`T09_STAGING_DISTRIBUTION_PASS`
> 现场影响：仅向157和152的RUN私有`/tmp`写入staging；无sudo、无服务或业务状态变更。

## Staging

- RUN ID：`20260911-133252`；
- 三端路径：`/tmp/jfsportal-t09-20260911-133252`；
- 清单：28项，目录总字节数`152938421`；
- `SHA256SUMS` SHA256：`d69432d0652141d54fb100fb5830e6b09fc50cc72447593e6451fa4ddfeaaedd`，本地、157、152一致；
- `juicefs-ro` MD5：`24fae0852051c80ca571cb2f20275d46`，版本输出`1.4.1+unknown`，与批准的patched build一致；
- 152端完整`sha256sum -c`及全部staged shell脚本`bash -n`通过。

## 只读现场复核

- 152主机名为`ceph-node3`；
- Portal、Prometheus、Grafana均为`active/disabled`；
- `/mnt/jfs-tikv`仍为`/dev/nvme1n1`上的ext4；
- `/mnt/dbwal`仍为tmpfs；
- 本阶段没有启动专用挂载、collector或timer，也没有重启任何服务。

## 下一步

执行唯一root只读预检：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t09-20260911-133252/scripts/t09-readonly-preflight.sh /tmp/jfsportal-t09-20260911-133252
```

该命令只读取受保护的Portal配置、用户合同、二进制依赖、端口、资源余量及业务指纹，不安装文件、不启动服务。只有返回`T09_READONLY_PREFLIGHT_PASS`后，才提交更新命令审批。
