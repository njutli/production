# T09挂载成功、采集器条件阻断与修复版预检签收

> 时间：2026-09-11  
> 失败RUN：`20260911-150908`  
> 修复RUN：`20260911-154510`  
> 裁决：FUSE挂载修复已生效；采集器启动条件已完成最小修正，新RUN只读预检通过，尚未执行状态变更。

## RUN 150908结果

- 专用挂载已经成功完成Ceph初始化、创建只读session并出现`juicefs-prod is ready`，证明前一轮移除mount unit中`RestrictAddressFamilies`和`LockPersonality`的修复有效。
- 更新脚本以`findmnt`确认挂载后启动采集器，但systemd把`ConditionPathIsMountPoint=/var/lib/juicefs-portal/namespace-mount`判为不满足并跳过oneshot；SQLite未生成，Portal因`namespace.db`不存在而退出。
- 更新脚本触发精确自动回滚：timer和挂载已停止，只读挂载正常卸载，动态安装的`client.juicefs` keyring按SHA删除，Portal恢复为`active/disabled,NRestarts=0`。
- 回滚后无T09挂载及运行资产；PD/TiKV PID仍为`1589960/2088516`，`/mnt/jfs-tikv`和`/mnt/dbwal`指纹未变。

## 最小修正

- collector unit以`ExecCondition=/usr/bin/findmnt -rn -M /var/lib/juicefs-portal/namespace-mount`替代systemd 249未能识别本次FUSE挂载的`ConditionPathIsMountPoint=`。
- 保留`Requisite/After=juicefs-namespace-mount.service`；挂载不存在时oneshot仍会被跳过，不会用空目录覆盖上一份有效快照。
- 更新脚本在首次collector返回后强制检查`namespace.db`为非空文件；只有成功生成数据库才启动timer和重启Portal。
- 离线Gate增加上述两项运行契约，并移除一个会被注释文本误命中的旧`NoNewPrivileges`检查。

## 修复版门禁

- RUN `20260911-154510`的28项清单SHA为`58d7e73c3073a5011ae77d073df31001fa881ea0c1b2a5738ed1d36ddb88ad67`，本地、157和152一致。
- JuiceFS文件大小为`127933776 bytes`，MD5为`24fae0852051c80ca571cb2f20275d46`。
- 因跨机SFTP会在文件仍落盘时提前返回，本轮改用单归档传输，并以归档大小稳定、归档SHA和解包后28项SHA三重校验；两个不完整的中间RUN均判无效且未部署。
- 152 root只读preflight返回`T09_READONLY_PREFLIGHT_PASS`；可用内存`857603812 KiB`，目标文件系统余量`794416287744 bytes`。

## 下一步

等待用户批准在152执行修复RUN的唯一update命令；执行后验证首次SQLite、两个刷新周期、API/RBAC、静态未enable状态、资源占用及业务指纹。
