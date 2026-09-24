# T09业务卷三级目录快照最终签收

> 时间：2026-09-11  
> RUN：`20260911-165833`  
> 裁决：`T09_BUSINESS_NAMESPACE_DEPLOYMENT_PASS`

## 1. 交付结果

152已接入业务卷三级目录用量快照，冻结能力为：

- 授权根和已展示目录的递归容量、文件数、目录数覆盖全部后代；
- 根以下最多三级，每个目录展示按递归容量排序的top 100直接子项；
- 超过100项的部分显示为`其余项（聚合）`，容量和计数有效，但不提供逐项名称；
- USER只能查看绑定root，ADMIN可查看全部root；页面/API只读SQLite，不在用户请求中运行`du`或JuiceFS命令。

完整逐项文件清单、文件属性、内容预览和下载不属于T09。

## 2. 更新与自动验收

经用户批准在`10.20.1.152`执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t09-20260911-165833/scripts/t09-update-namespace.sh /tmp/jfsportal-t09-20260911-165833
```

结果：

```text
T09_READONLY_VERIFY_PASS root=juicefs-prod-root freshness=fresh user_admin=403 anonymous=401 write=405 services_not_enabled=true
T09_UPDATE_PASS backup=/var/lib/juicefs-portal/t09-backup-20260911-165833 rollback=/var/lib/juicefs-portal/t09-backup-20260911-165833/t09-rollback-namespace.sh services_not_enabled=true
```

Portal、Prometheus和Grafana均为`active/disabled`；namespace mount和timer为`active/static`，collector为按timer运行后退出的`inactive/static`。没有设置任何开机自启。

## 3. 真实业务快照证据

独立只读审计得到：

```text
root=juicefs-prod-root
generation=3
logical_bytes=518617337856
file_count=404
dir_count=9
status=ready
kinds=[('aggregate', 1), ('directory', 6), ('file', 114)]
visible_rows=121
aggregate_sample=[('/test_dir/...', 308163911680, 287, 2)]
```

这证明真实业务树同时满足“全量总计”和“top 100+其余项聚合”合同：`/test_dir/...`代表未具名展示的287个文件和2个目录，并非数据丢失。

timer随后连续完成多代快照，日志间隔约60秒，每轮collector约1秒内退出；页面读取SQLite，不同步触发采集。

## 4. 安全与低扰动验收

- 专用控制挂载为`fuse.juicefs rw`，不含`allow_other/allow_root`；`summary`固定为`depth=3, topN=100`；
- mount命令使用JuiceFS参数`--atime-mode noatime`、`--cache-size 0`和`--backup-meta 0`；
- Portal service运行时`InaccessiblePaths`包含控制挂载，进入Portal的mount namespace检查返回不可见；
- namespace mount当前约57 MiB内存、27个任务、`NRestarts=0`；collector累计CPU约82 ms且每轮退出；
- Portal约147 MiB内存、40个任务、`NRestarts=0`，均低于systemd上限；
- Ceph为`HEALTH_OK`，`juicefs-data`显示`nothing is going on`；
- PD PID `1589960`、TiKV PID `2088516`保持不变；`/mnt/jfs-tikv`和`/mnt/dbwal`保持原挂载；
- 没有修改PD、TiKV、Ceph配置、157业务挂载、块设备或网络配置。

## 5. 运维边界

- 正常刷新目标为60秒，页面以180秒作为新鲜度上限；采集失败保留上一代快照并显示失败/过期，不显示为0；
- 单root及API响应最多10,000个可见行，超过时拒绝替换快照；
- `summary`不提供mtime，页面不承诺文件或目录修改时间；
- 回滚资产保留在`/var/lib/juicefs-portal/t09-backup-20260911-165833`，未经单独批准不删除；
- 需要撤回时只能使用该目录中的精确回滚脚本，并须重新提交sudo审批。
