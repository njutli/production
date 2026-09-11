# T09凭据修复版更新失败与FUSE阻断归因

> 时间：2026-09-11  
> RUN：`20260911-144710`  
> 裁决：`T09_UPDATE_ATTEMPT3_ROLLBACK_PASS`；网络和Ceph凭据已通过，剩余阻断收敛到systemd上下文中的FUSE提权。

## 证据

mount日志依次出现：

```text
Data use ceph://juicefs-data/juicefs-prod/
Create read-only session OK with version: 1.4.1+unknown
Mounting volume juicefs-prod at "/var/lib/juicefs-portal/namespace-mount" ...
/usr/bin/fusermount3: mount failed: Operation not permitted
```

这证明TiKV、Ceph网络、`client.juicefs`认证及只读session均已成功。失败的helper journal元数据仍为`_UID=998`、`_GID=998`、`_CAP_EFFECTIVE=0`；实际helper是`root:root 4755`，根文件系统非`nosuid`，`/dev/fuse`为`0666`，`jfsportal`拥有并可写挂载点，SELinux上下文为`unconfined`。

脚本随后自动回滚：本轮keyring已按SHA精确删除，Portal恢复`active/disabled,NRestarts=0`，T09挂载和资产无残留，PD/TiKV PID及业务挂载未变。

## 下一步

用一次执行后自动回收的瞬时systemd探针，读取与mount unit相同安全属性下的`NoNewPrivs`、seccomp和能力边界；该探针不挂载、不访问业务数据、不安装文件。根据结果再决定是缩减冲突的unit硬化项，还是继续验证UBIP helper对专用用户的限制。
