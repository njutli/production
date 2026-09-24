# 157 原 JuiceFS 挂载配置恢复记录（2026-09-23）

用户纠正长稳测试目标应为 **192.168.11～14**，157/150～152不是本轮长稳执行环境。此前误在157将 `/mnt/juicefs` 的 Ceph客户端有效 worker 数由原来的3调整为8；未在该环境启动 fio 或写入长稳测试文件。用户随后明确授权恢复157原挂载配置。本记录如实保留误操作与回滚证据，不把157检查纳入192集群的长稳结论。

恢复前在157只读核对：主机 `oneasia-c1-cpu-node10`、用户 UID1002、挂载 `/mnt/juicefs`、卷UUID `e1b69ea9-0e3d-427d-bea9-8765928afa66`、BlockSize256K、二进制MD5 `24fae0852051c80ca571cb2f20275d46`、FUSE `max_read=262144`、worker8；无 fio、`fuser -m` 未发现使用者，JuiceFS staging/上传为0，Ceph `HEALTH_OK`。查询原系统Ceph有效配置 `ms_async_op_threads=3`。恢复脚本通过语法及危险命令扫描，远端SHA256 `6ac087969f02f4f591549e2a9d7dc96664b9517a2f2a61f41a27ed70cc3add48`；首次只读计划因误用`ceph-conf --lookup`（未显式设置该项时退出1）而拒绝，改为已验证的`ceph config get`后只读计划通过。**在计划门通过前未卸载。**

执行时间约09:23:43～09:23:50 ICT；仅在157非sudo执行：

```text
/tmp/juicefs-1.4.1-patched umount --flush /mnt/juicefs
env -u CEPH_CONF /tmp/juicefs-1.4.1-patched mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod /mnt/juicefs
```

`RESTORE_PASS`，新进程PID 2439086（父进程、0 worker）/2439121（工作进程、3 worker）。09:24 ICT再核对 `RESTORE_VERIFY_PASS`、原卷与FUSE参数、Ceph `HEALTH_OK`/6 OSD up-in/97 PG active+clean、PD中的3个TiKV store均Up；157无fio，Weka进程17个、kubelet进程1个仍在运行。审计日志 `/home/sunrise/lt-restore-157-original-20260923.audit.log`。

恢复的是**运行配置**，不是进程PID、内存缓存等瞬态状态；重挂存在约数秒挂载切换，现有证据只能确认后续服务运行，不能证明对业务完全没有瞬时影响。此前加入的私有配置、脚本和日志仍作为审计证据保留，不再被当前挂载引用；本次未删除它们，也未执行sudo、重启/改动Ceph、TiKV、Weka或K8s。157及150～152不再用于本轮长稳测试。
