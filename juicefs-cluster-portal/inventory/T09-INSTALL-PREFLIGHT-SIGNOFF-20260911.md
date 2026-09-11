# T09业务卷目录快照安装前只读签收

> 时间：2026-09-11
> 裁决：`T09_READONLY_PREFLIGHT_PASS`
> 节点：`10.20.1.152（ceph-node3）`

## 执行结果

已获批并执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t09-20260911-133252/scripts/t09-readonly-preflight.sh /tmp/jfsportal-t09-20260911-133252
```

返回：

```text
T09_READONLY_PREFLIGHT_PASS host=ceph-node3 mem_available_kib=857535040 disk_available_bytes=795367632896
```

预检确认：

- 28项staging完整SHA通过，JuiceFS MD5及v1.4.1版本匹配；动态库无missing；
- T08 Portal、三份Web资产和Portal unit的固定SHA未漂移；
- Portal、Prometheus、Grafana均为active/disabled；
- `/dev/fuse`和fusermount可用，150～152的2379端口可达；
- 现有USER账户合同正确且尚未绑定`juicefs-prod-root`，Portal环境尚未配置namespace DB；
- T09二进制、配置、unit、数据库和挂载目标均不存在，没有覆盖未知现场；
- PD/TiKV进程及`/mnt/jfs-tikv`、`/mnt/dbwal`业务挂载存在；
- 可用内存约818 GiB，系统盘可用约741 GiB，远高于最低门限。

本步骤只读取受保护配置和系统状态，没有安装文件、启动或重启服务，也没有修改业务、集群或开机启动状态。

## 下一步

经用户单独批准后执行唯一更新命令。脚本将备份当前Portal受管文件，安装专用只读挂载与collector，完成一次采集和RBAC验收；任一步失败自动执行精确回滚。
