# 配置纠偏：157 JuiceFS Ceph 客户端 3→8 线程

执行时间：2026-09-23 08:54～09:01 ICT。用户授权重挂我们方案的 JuiceFS；**无 sudo 操作**，未重启 Ceph/TiKV/Weka/K8s。

## 前置与步骤

1. 精确核验 `/mnt/juicefs` 的 UUID `e1b69ea9-0e3d-427d-bea9-8765928afa66`、BlockSize256K、FUSE `max_read=262144`、原进程二进制MD5 `24fae0852051c80ca571cb2f20275d46`、原真实 worker=3；`fuser -m` 无使用者，staging/上传请求为0。
2. 将经过 SHA256 固定的私有 Ceph 配置复制到持久路径 `/home/sunrise/juicefs-ceph-msgr8.conf`（权限0600）；`ceph-conf`解析 `[client] ms_async_op_threads=8`。首次准备脚本末尾自调用因远端脚本未设可执行权限而报错，**复制本身成功**，随后用 `bash <脚本> verify` 独立复验 PASS；不把该脚本退出状态误记为一次完整通过。
3. 在独立 canary 挂载上使用该私有配置启动 JuiceFS，FUSE 256K、同一卷UUID；子进程观测到 `msgr-worker-0..7` 共8个，原挂载不变。Canary 首版因 JuiceFS 守护化后 `/proc/PID/environ` 未保留 `CEPH_CONF` 而产生假阴性，v2改为核验受控启动命令、固定配置SHA与**实际运行线程数**后通过。Canary无fio负载。
4. 重挂脚本 `plan`核对目标卷/路径/进程、原 worker=3、Ceph FSID及健康、无使用者、无未排空数据；独立恢复脚本先上传并出具精确计划。然后仅执行 `/tmp/juicefs-1.4.1-patched umount --flush /mnt/juicefs` 和带 `CEPH_CONF=/home/sunrise/juicefs-ceph-msgr8.conf` 的同参数 `mount -d`。脚本返回 `REMOUNT_VERIFY_PASS workers=8`，新 worker PID 2342573；审计文件为 `/home/sunrise/lt-remount-157-20260923.audit.log`。
5. 复核 `/mnt/juicefs`、Ceph `HEALTH_OK`、6/6 OSD、3个 TiKV store Up、Weka进程仍运行。独立canary挂载已优雅卸载；其目录和约4KiB日志保留作证据，没有删除。

## 结论和边界

项0的**实际运行配置差异已纠正**：在生产候选挂载上由3个变为8个 Ceph 异步 worker；二进制、卷和FUSE设置未变。未测任何性能或长稳结果，不能据此声称带宽/稳定性收益。下一步部署新版 LT 脚本，仅做只读 `plan` 和容量预算；确认业务窗口与停止线前不跑写入筛查。

JuiceFS 守护化后 `/proc/PID/environ` 不保留 `CEPH_CONF`，不能把该字段当作持续存在的必要条件。LT门改为固定配置路径/哈希和启动证据，同时核验实际8个 worker；若环境字段可读且与预期冲突，仍拒绝。
