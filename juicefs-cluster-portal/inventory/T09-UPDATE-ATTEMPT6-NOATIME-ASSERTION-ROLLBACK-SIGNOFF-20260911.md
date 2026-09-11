# T09第六次更新无效noatime断言与回滚签收

> 时间：2026-09-11  
> 失败RUN：`20260911-164826`  
> 裁决：`T09_UPDATE_ATTEMPT6_INVALID_VERIFY_ASSERTION_ROLLBACK_PASS`

## 1. 执行结果

经批准在152执行RUN update。内置preflight、专用挂载及collector均已通过，日志明确记录：

```text
Start to get summary of 1, depth=3, topN=100
namespace snapshot updated for 1 root(s)
```

随后运行态验收失败并触发自动回滚：

```text
T09_UPDATE_FAIL rc=1; invoking exact rollback
T09_ROLLBACK_PASS backup=/var/lib/juicefs-portal/t09-backup-20260911-164826 portal_restored=true business_unchanged=true
```

## 2. 根因

验收脚本错误地要求`findmnt`必须显示`noatime`。实际命令中的`--atime-mode noatime`是JuiceFS元数据atime策略，不是传给内核FUSE的mount flag；现场`findmnt`正确显示`rw,...,relatime`，因此这条断言不成立。

该失败不是summary、top 100合同、SQLite、Portal或集群故障。collector已成功完成一次真实业务卷采集。

## 3. 收口与修复

- 自动回滚后Portal恢复`active/disabled`，Prometheus和Grafana保持`active/disabled`；
- 专用控制挂载、collector及T09受管资产均已撤回；
- PD/TiKV PID和`/mnt/jfs-tikv`、`/mnt/dbwal`由回滚脚本逐项核对未变；
- 仅删除无效的`findmnt noatime`断言，继续硬检mount命令包含`--atime-mode noatime`；
- 失败RUN禁止复用。

修复后新RUN为`20260911-165833`，29项`SHA256SUMS`摘要为`ed080520bd97ca9e7af33bac16f989e0cda71c089b8105ec601f7a594528bb51`。本地、157、152一致，152只读preflight再次通过；正式update仍需按新RUN重新审批。
