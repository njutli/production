# T09采集器真实启动与只读挂载阻断归因

> 时间：2026-09-11  
> RUN：`20260911-154510`  
> 裁决：`findmnt -M`条件修复有效，collector已真实执行；JuiceFS `summary`与内核只读FUSE挂载不兼容，更新自动完整回滚。

## 实际结果

- mount unit成功建立`JuiceFS:juicefs-prod fuse.juicefs ro`挂载并创建只读session；
- collector的`ExecCondition=/usr/bin/findmnt -rn -M ...`返回成功，证明上一轮“条件被跳过”问题已经修复；
- collector随后调用JuiceFS `summary`，命令以非零退出：

```text
entries should be less than 101
open controller: open /var/lib/juicefs-portal/namespace-mount/.control: read-only file system
```

- JuiceFS `summary`通过挂载内的虚拟`.control`文件交换请求和结果，CLI以`O_RDWR`打开该控制文件；内核只读FUSE挂载会在open阶段返回`EROFS`。这不是普通业务文件写入，但与`--read-only`挂载的内核语义冲突。
- collector使用的`--entries 10000`也不符合该版本CLI合同；JuiceFS会将单层top-N钳制到100。该参数必须订正，并且需要明确“top 100”与“三级全部目录”不是同一语义。

## 回滚与业务边界

- update捕获失败并执行精确自动回滚，返回`T09_ROLLBACK_PASS`；
- 专用挂载、timer、collector、动态keyring和SQLite均无残留，Portal恢复`active/disabled`；
- PD/TiKV PID保持`1589960/2088516`，`/mnt/jfs-tikv`和`/mnt/dbwal`指纹未变。

## 下一步决策点

不能继续复跑现有RUN。若坚持内核强制只读挂载，需要改造JuiceFS控制协议或改为直接读取元数据的采集实现；若采用最小工程方案，则使用152专用、非`allow_other`的控制挂载，以可信collector唯一执行`summary`，并通过service沙箱阻止Portal及其他普通用户访问或写入。后者的内核挂载标志为rw，虽采集命令逻辑只读，仍需用户明确接受这一安全边界后才能实施。
