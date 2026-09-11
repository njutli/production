# T09 fusermount权限误判更正与staging失效记录

> 时间：2026-09-11
> 裁决：`T09_FUSERMOUNT_PERMISSION_CORRECTION`；RUN `20260911-134851`禁止执行。

## 更正

152使用UTC+7。首次更新的root journal显示JuiceFS mount进程启动后未形成FUSE挂载，60秒硬门触发回滚；对未形成的挂载执行普通卸载返回：

```text
fusermount: failed to unmount /var/lib/juicefs-portal/namespace-mount: Operation not permitted
```

最初把`stat`显示的`0777`误当成实际helper权限，这是错误的。`/usr/bin/fusermount3`是UBIP创建的符号链接，Linux符号链接固定显示`lrwxrwxrwx`且其权限位不参与访问控制；`readlink -f`后的真实文件在157和152均为`root:root 4755`，SHA256同为`fa2dc1bb00be297004cfa4fc82dab3a6d568042736f7eb5b6fd8de49804db2d1`。157在相同结构下能够正常运行FUSE。

`dpkg -V fuse3`的mode提示来自UBIP用符号链接替代package路径，并不说明真实helper失去setuid。此前提出的`chmod 4755 /bin/fusermount3`不会修复问题，且不应执行。

## RUN失效

- RUN：`20260911-134851`；
- 路径：三端均为`/tmp/jfsportal-t09-20260911-134851`；
- 清单28项，SHA256SUMS SHA为`0fc1024605c5c280b9f9831406b87b032851e1507ddf4c27d0e8d70da1b04fa2`；
- 相对首次RUN只改变preflight及清单，其他27项SHA未变；
- 该RUN的preflight错误要求`dpkg -V fuse3`无输出，在当前UBIP结构下必然失败；
- 因合同错误，RUN `20260911-134851`标记为`EVIDENCE_INVALID_PREFLIGHT_CONTRACT`，即使三端SHA完整也禁止执行。

## 下一步

真实helper校验已完成修正。后续只读检查确认业务卷的数据引擎是Ceph，而首次mount unit的`IPAddressDeny=any`只放行TiKV地址，没有放行Ceph public/client地址；这才是挂载进程启动后长期不就绪的直接原因。详情及最小修复边界见`T09-MOUNT-NETWORK-ROOTCAUSE-SIGNOFF-20260911.md`。
