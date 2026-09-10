# T01：152只读部署预检与接口盘点

> 执行时间：2026-09-10 12:19～12:21（Asia/Bangkok）
> 目标节点：`10.20.1.152（ceph-node3）`
> 结论：`PASS`
> 状态变更：无

## 1. 结论

152可以承载轻量单实例管理面，未发现需要更换节点的阻断项：

- 当前是PD Follower，且没有Ceph MGR进程；
- 128个逻辑CPU，load约`0.16/0.07/0.02`；
- 可用内存约`817 GiB`；
- 系统盘约`745 GiB`可用，inode使用率约`1%`；
- systemd使用cgroup v2，CPU和内存accounting已开启，可以对管理服务执行硬限额；
- 计划使用的`443/8080/9090/3000/9100/9283/9567/9633`端口当前均无冲突；
- 系统盘、TiKV盘、Ceph OSD盘和DB/WAL tmpfs边界清楚。

管理面必须部署在152系统盘`nvme0n1p2`，禁止把任何程序数据、TSDB或日志放入`/mnt/jfs-tikv`、`/mnt/dbwal`或OSD设备。

## 2. 系统与资源

| 项目 | 结果 |
|---|---|
| 主机 | `ceph-node3` / `10.20.1.152` |
| OS | Ubuntu 22.04.5 LTS |
| 内核 | `5.15.0-153-generic` |
| CPU | 128逻辑CPU，2 socket，2 NUMA node |
| 内存 | 1.0 TiB总量，约817 GiB available，无swap |
| 运行时间 | 77天以上 |
| 时区 | Asia/Bangkok |
| NTP | 已同步 |
| cgroup | cgroup v2 |
| systemd | 249，CPU/Memory accounting已启用 |

采样时主机总体空闲约100%，系统盘`nvme0n1`瞬时util约`0.8%`。节点仍运行TiKV、PD、Ceph MON和两个OSD，因此管理服务必须遵守已规划的CPU、内存和I/O上限。

## 3. 存储边界

| 路径/设备 | 来源 | 用途 | 门户是否允许写入 |
|---|---|---|---:|
| `/` | `/dev/nvme0n1p2` ext4 | 系统盘 | 是，仅专属受限目录 |
| `/var/lib/containers/storage/overlay` | `nvme0n1p2` | Podman容器存储 | 可用，但必须限额 |
| `/mnt/jfs-tikv` | `/dev/nvme1n1` ext4 | TiKV数据 | **禁止** |
| `/mnt/dbwal` | 200 GiB tmpfs | Ceph OSD DB/WAL | **禁止** |
| `/dev/nvme2n1` | 7 TiB LVM/BlueStore | OSD.5数据 | **禁止** |
| `/dev/nvme3n1` | 7 TiB LVM/BlueStore | OSD.4数据 | **禁止** |

当前root Podman中存在MON、crash、OSD.4和OSD.5四个Ceph容器。门户部署不得修改、重启或复用这些容器。

## 4. 本机软件与端口

已存在：

- Podman `3.4.4`；
- Docker `29.1.3`；
- Python `3.10.12`；
- curl、git。

未安装：

- Prometheus；
- Grafana；
- Nginx；
- Node Exporter；
- SMART exporter；
- Go、Node.js、npm、jq。

因此采用“WSL本地构建静态后端和前端资产，152只运行构建产物或固定容器镜像”的方式；不在152安装开发工具链。

候选监听端口当前均无占用：`443`、`3000`、`8080`、`9090`、`9100`、`9283`、`9567`、`9633`。

## 5. 指标和API可达性

从152发起一次只读HTTP探测：

| 数据源 | 端点 | 结果 | 单次响应体量 |
|---|---|---|---:|
| PD metrics | 150:2379 | HTTP 200 | 510,051 B |
| PD metrics | 151:2379 | HTTP 200 | 270,550 B |
| PD metrics | 152:2379 | HTTP 200 | 270,598 B |
| TiKV metrics | 150:20180 | HTTP 200 | 1,489,398 B |
| TiKV metrics | 151:20180 | HTTP 200 | 1,524,197 B |
| TiKV metrics | 152:20180 | HTTP 200 | 1,524,338 B |
| PD Leader API | 150:2379 | HTTP 200 | 164 B |
| PD Stores API | 150:2379 | HTTP 200 | 3,850 B |
| JuiceFS metrics | 157:9567，从152访问 | connection refused | — |
| Ceph mgr metrics | 三节点:9283 | connection refused | — |
| Node Exporter | 150～152:9100 | connection refused | — |
| Node Exporter | 157:9100 | HTTP 200 | 335,468 B |

结论：

1. PD/TiKV可以由152直接采集。
2. Ceph mgr Prometheus模块当前没有启用，后续需要单独sudo审批。
3. 150～152尚未部署Node Exporter；157已有Node Exporter。
4. 157生产JuiceFS挂载的metrics仅监听`127.0.0.1:9567`。在157本机探测为HTTP 200，响应约102 KiB。
5. 禁止为开放metrics而重挂157生产卷；后续使用只读本地转发或remote-write agent。

## 6. 157生产挂载只读核验

| 项目 | 结果 |
|---|---|
| 挂载 | `JuiceFS:juicefs-prod` → `/mnt/juicefs` |
| 类型 | `fuse.juicefs` |
| 版本 | `/tmp/juicefs-1.4.1-patched` |
| max-uploads | 150 |
| cache-size | 0 |
| max-fuse-io | 256K |
| metrics | `127.0.0.1:9567`，HTTP 200 |

本次仅读取findmnt、进程和metrics状态，没有重挂、发送信号或修改157上的任何配置。

## 7. 后续约束

- 152所有管理数据必须落在系统盘专属目录，并设置30 GiB Prometheus容量上限。
- Prometheus、Grafana、Portal和Nginx必须使用systemd/cgroup资源限制。
- 第一版不启用完整Ceph Dashboard。
- 157通过轻量本地转发暴露JuiceFS metrics，不能改变生产挂载。
- TiKV/PD默认15～30秒采集；Ceph不得低于15秒。
- 目录浏览在后续阶段才建立，只读、分页、限流且禁止递归扫描。
- 页面请求不得执行SSH、sudo、smartctl或Ceph/TiKV命令。

## 8. T01裁决

`T01_PASS`：152部署条件满足，可以进入T02“冻结MVP需求、指标白名单和数据模型”。进入T02前等待用户确认。
