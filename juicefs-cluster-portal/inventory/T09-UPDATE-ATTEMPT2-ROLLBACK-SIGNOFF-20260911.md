# T09网络修复版更新失败与回滚签收

> 时间：2026-09-11  
> RUN：`20260911-141910`  
> 裁决：`T09_UPDATE_ATTEMPT2_ROLLBACK_PASS`；网络阻断解除，更新因缺少Ceph业务凭据失败并完整回滚。

## 结果

内置preflight通过后，mount进程读取TiKV元数据并进入Ceph数据引擎初始化，journal返回：

```text
object storage: Can't connect to cluster ceph: rados: ret=-13, Permission denied
```

152只有`/etc/ceph/ceph.client.admin.keyring`且为`root:root 0600`，不存在业务卷设置引用的`/etc/ceph/ceph.client.juicefs.keyring`。157现有业务挂载则使用该keyring，其权限为`mon allow r`及`juicefs-data`池读写。

脚本在60秒硬门后自动回滚并返回`T09_ROLLBACK_PASS`。独立复核确认Portal为`active/disabled,NRestarts=0`，T09挂载、unit、二进制、配置和SQLite均未残留；PD/TiKV PID仍为`1589960/2088516`，`/mnt/jfs-tikv`及`/mnt/dbwal`未变。

## 裁决

- 地址修复有效：错误从连接阻断推进为Ceph明确的权限拒绝；
- 不允许使用或放宽`client.admin`；
- 后续只安装已有的池级`client.juicefs`凭据，并纳入精确回滚。
