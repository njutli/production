# T05：基础服务安装前签收

> 时间：2026-09-10 17:14 CST  
> 节点：`10.20.1.152（ceph-node3）`  
> 裁决：`T05_PREINSTALL_PASS`  
> 状态变更：仅向152唯一`/tmp`目录上传staging；未执行sudo，未安装或启动服务

## 1. 供应链与本地检查

| 项目 | 结果 |
|---|---|
| Prometheus | `3.13.2`，官方包SHA256 `0e8c4d46101bd025ea8265e377d2caabc57f488fc1be1c367f37db69ea41be6f` |
| Grafana OSS | `13.2.1`，官方包SHA256 `849b3f17a0a318a2f1a681b663e9feb4e4fc7f70d43bb0b4ea07cd34b1987462` |
| Prometheus配置 | `promtool check config`通过 |
| Portal | Linux amd64静态二进制，Go测试和离线Gate通过 |
| staging | 本地全量SHA256通过，共`13388`项；约`1.62 GB` |

首次启动就绪检测已由固定5秒改为最多60秒轮询，避免Grafana首次初始化较慢造成误判；这项修改已通过bash语法和离线Gate检查。

## 2. 上传边界

- RUN_ID：`20260910-165333`；
- 152路径：`/tmp/jfsportal-t05-20260910-165333`；
- 经157仅作SSH字节流转发，157不落盘；
- 未覆盖既有目录，未写业务挂载；
- 152全量`SHA256SUMS`复核：`REMOTE_SHA256_PASS files=13388`。

## 3. 152只读预检结果

| 检查项 | 结果 |
|---|---|
| 主机 | `ceph-node3` |
| 根文件系统 | `/dev/nvme0n1p2` |
| 根盘可用 | `797663260672 B` |
| MemAvailable | `857654104 KiB` |
| 目标目录 | `/opt/juicefs-portal`、`/etc/juicefs-portal`、`/var/lib/juicefs-portal`、`/var/log/juicefs-portal`均不存在 |
| 目标端口 | `3000/8080/9090`均空闲 |
| TiKV数据盘 | `/dev/nvme1n1`仍挂载于`/mnt/jfs-tikv` |
| Ceph DB/WAL | `tmpfs`仍挂载于`/mnt/dbwal` |
| Portal unit | 当前为`0`个 |
| 业务进程 | `pd-server PID=1589960`，`tikv-server PID=2088516` |

## 4. 待审批操作

第一检查点只安装、不启动：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t05-20260910-165333/scripts/t05-install-base.sh /tmp/jfsportal-t05-20260910-165333
```

该脚本仅创建`jfsportal`系统用户/组、门户专属`/opt`、`/etc`、`/var/lib`、`/var/log`目录，安装三个unit、生成本地密钥并执行`systemctl daemon-reload`；不会启动或enable服务，不会操作Ceph、PD、TiKV、JuiceFS、挂载、设备、防火墙、apt或容器。

安装成功后先做只读复核，再单独请求启动阶段sudo授权。

## 2. 安装结果

- 命令返回：`T05_INSTALL_BASE_PASS services_not_started=true`。
- `juicefs-prometheus.service`、`juicefs-grafana.service`、`juicefs-portal.service`均为`inactive/disabled`。
- `3000/8080/9090`均未监听。
- systemd读取到的限制：Prometheus `CPUQuota=2s`、`MemoryMax=6 GiB`；Grafana和Portal各`CPUQuota=500ms`、`MemoryMax=1 GiB`；三者`IOWeight=10`。
- `/opt/juicefs-portal`为`root:root 0755`；`/etc/juicefs-portal`为`root:jfsportal 0750`；两个状态目录为`jfsportal:jfsportal 0750`。
- 三个已安装unit的SHA256与staging完全一致。
- PD/TiKV PID及`/mnt/jfs-tikv`、`/mnt/dbwal`挂载与安装前一致。

当前停点安全：程序和配置已落盘，但没有新进程、监听端口或开机启动项。
