# T05：152基础服务部署签收

> 完成时间：2026-09-10  
> 节点：`10.20.1.152（ceph-node3）`  
> 裁决：`T05_PASS`  
> 运行方式：仅当前调试态，三个服务均为`disabled`

## 1. 部署结果

| 服务 | 版本/模式 | PID | 监听 | 重启次数 |
|---|---|---:|---|---:|
| Prometheus | `3.13.2` | `1012237` | `127.0.0.1:9090` | 0 |
| Grafana OSS | `13.2.1` | `1012313` | `127.0.0.1:3000` | 0 |
| Portal | `live` | `1012669` | `127.0.0.1:8080` | 0 |

健康检查全部通过：Prometheus ready、Grafana database ok、Portal返回`{"mode":"live","status":"ok"}`。

## 2. 资源和安全边界

- Prometheus：`CPUQuota=2 CPU`、`MemoryMax=6 GiB`、`IOWeight=10`；验收时内存约`27 MiB`。
- Grafana：`CPUQuota=0.5 CPU`、`MemoryMax=1 GiB`、`IOWeight=10`；验收时内存约`214 MiB`。
- Portal：`CPUQuota=0.5 CPU`、`MemoryMax=1 GiB`、`IOWeight=10`；验收时内存约`3.5 MiB`。
- 三个服务都使用`jfsportal`非特权账号及systemd沙箱，只允许loopback网络。
- 未安装Nginx，未开放防火墙或管理网端口；当前需通过SSH端口转发查看。
- 根据用户决定，没有执行`systemctl enable`，节点重启后不会自动启动。
- 152 staging中的启动脚本已同步为不含`systemctl enable`的版本，脚本SHA256为`da0e90034ac7dd02fcf7bab48e5613e75fe7c72958848029af43c5e655302414`；重建后的`13388`项清单复核通过。

## 3. 业务无扰动证据

- PD PID：安装前后均为`1589960`。
- TiKV PID：安装前后均为`2088516`。
- `/mnt/jfs-tikv`仍为`/dev/nvme1n1`的原ext4挂载。
- `/mnt/dbwal`仍为原200 GiB tmpfs挂载。
- 没有操作Ceph、PD、TiKV、JuiceFS挂载、设备、容器或防火墙。

## 4. 当前能力边界

T05只证明基础服务、安全限制和调试入口可用。Portal处于`live`模式，真实监控adapter尚未接入；除健康接口外的业务接口会返回503，防止把fixture误当成集群数据。真实JuiceFS、PD/TiKV、Ceph、主机和磁盘指标在T06接入。

## 5. 查看方式

三个端口没有对管理网开放，应通过SSH转发后访问。由于本机密钥不能直接登录152，可先从本机转发到157，再由157转发到152；T06/T08会将这一过程收敛为统一入口。
