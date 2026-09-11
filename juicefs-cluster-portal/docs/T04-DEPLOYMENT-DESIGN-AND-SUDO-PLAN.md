# T04：152基础服务部署设计与sudo计划

> 状态：`READY_FOR_APPROVAL`
> 本阶段只生成和检查本地文件，未在152执行任何命令。

## 1. 最小部署决策

T05先部署三个仅监听152 loopback的基础服务：

| 服务 | 地址 | CPU上限 | 内存上限 | 数据位置 |
|---|---|---:|---:|---|
| Portal API/UI | `127.0.0.1:8080` | 0.5核 | 1 GiB | 程序只读；状态目录在系统盘 |
| Prometheus | `127.0.0.1:9090` | 2核 | 6 GiB | 系统盘，14天且30 GB先到为准 |
| Grafana | `127.0.0.1:3000` | 0.5核 | 1 GiB | 系统盘 |

T05不安装Nginx、不开放管理网端口、不启用Ceph mgr模块、不部署exporter。管理员外部HTTPS入口和正式认证放在T08，T07以前只通过SSH端口转发验收页面。

这样可以先证明服务可运行和资源隔离有效，同时避免在认证完成前暴露Prometheus、Grafana或默认token。

Portal生产配置使用`PORTAL_MODE=live`。在T06真实adapter接入前，`/health`可用，但监控业务接口返回`503`，不会把fixture数据显示成生产数据。

## 2. 软件与供应链

- Portal：从当前仓库源码以`CGO_ENABLED=0`构建Linux amd64静态二进制；
- Prometheus：固定`3.13.2`（3.13 LTS分支）；
- Grafana OSS：固定`13.2.1`；
- 不使用152上的Podman/Docker，避免与Ceph容器运行时发生管理面耦合；
- 下载只在本地完成，必须来自官方发布地址，按官方SHA256核对后才进入staging；
- staging再生成覆盖全部文件的`SHA256SUMS`，152安装脚本先执行`sha256sum -c`。

版本依据：[Prometheus 3.13为支持至2027-07-31的LTS分支](https://prometheus.io/docs/introduction/release-cycle/)；[Grafana 13.2.1为2026-09-02发布的安全/修复版本](https://github.com/grafana/grafana/releases/tag/v13.2.1)。T05执行前仍需核对官方release页面和资产校验值。

## 3. 目录和服务边界

仅创建：

```text
/opt/juicefs-portal/             root:root，程序和静态资源只读
/etc/juicefs-portal/             root:jfsportal，配置和密钥
/var/lib/juicefs-portal/         jfsportal:jfsportal，状态和TSDB
/var/log/juicefs-portal/         jfsportal:jfsportal，Grafana日志
/etc/systemd/system/juicefs-{portal,prometheus,grafana}.service
```

严禁触碰：`/mnt/jfs-tikv`、`/mnt/dbwal`、`/dev/nvme1n1`～`nvme3n1`、Ceph容器、PD/TiKV进程和157的JuiceFS挂载。

三个systemd unit均启用`NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateDevices`、CPU/内存/IO限制和loopback网络白名单。

## 4. T05执行分段

### A. 非sudo只读预检

在152运行：

```bash
bash /tmp/jfsportal-t05-<RUN_ID>/scripts/t05-node-preflight.sh
```

必须确认主机为`ceph-node3`、目标目录不存在、3000/8080/9090空闲、root仍为系统盘，且TiKV和DB/WAL挂载保持原状。

### B. 上传staging

只上传到唯一目录`/tmp/jfsportal-t05-<RUN_ID>`，不覆盖现有目录。此步不需要sudo。

### C. 安装但不启动

待用户审批后，仅执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t05-<RUN_ID>/scripts/t05-install-base.sh /tmp/jfsportal-t05-<RUN_ID>
```

脚本展开后的sudo写操作全集：

1. 仅在不存在时创建系统组和无登录shell的`jfsportal`账户；
2. `install -d`创建第3节列出的四棵专用目录；
3. 将已验SHA256的Portal/Prometheus/Grafana资产复制到`/opt/juicefs-portal`；
4. 将Prometheus/Grafana配置复制到`/etc/juicefs-portal`；
5. 用`openssl rand`生成Portal两个随机token、Grafana管理员密码和secret key，密钥文件为`root:jfsportal 0640`且不打印明文；
6. 只安装三个`juicefs-*` systemd unit；
7. 执行`systemctl daemon-reload`；
8. **不启动、不enable任何服务**。

脚本在目标目录已存在、主机名不符、staging越界/符号链接、文件缺失或SHA不符时立即退出，不执行覆盖安装。

### D. 启动与本机健康检查

安装证据审核通过后，另行审批并执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t05-<RUN_ID>/scripts/t05-activate-base.sh
```

准确动作只有：依次启动Prometheus、Grafana、Portal，并从loopback执行健康检查。根据用户2026-09-10的决定，T05为调试运行，不enable任何服务；WSL或节点重启后需人工重新启动。脚本不操作任何现有服务。

### E. 非sudo验收

```bash
bash /tmp/jfsportal-t05-<RUN_ID>/scripts/t05-readonly-verify.sh
```

检查PID、cgroup限制、三个loopback健康端点、监听地址以及业务挂载指纹。

## 5. 停止/回退命令

如果任一步出现异常，用户单独审批后只停止本项目服务：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t05-<RUN_ID>/scripts/t05-deactivate-base.sh
```

它只执行：

```bash
systemctl disable --now juicefs-portal.service juicefs-grafana.service juicefs-prometheus.service
```

程序、配置和TSDB全部保留供检查；不删除目录、不卸载设备、不操作生产进程。

## 6. 当前授权状态

- T04：仅本地准备，已授权并执行；
- T05只读预检、上传、安装和调试启动已于2026-09-10完成；三个服务保持`disabled`；
- T05停止命令尚未执行；
- 任何apt/dpkg、容器、网络、防火墙、Ceph、TiKV、PD、挂载和设备操作：不在本计划内。
