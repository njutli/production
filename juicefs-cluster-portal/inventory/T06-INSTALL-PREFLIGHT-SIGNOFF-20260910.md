# T06 安装前只读检查签收

> 时间：2026-09-10  
> 裁决：`T06_INSTALL_PREFLIGHT_PASS`  
> 状态变更：无。

## 157

- 主机名和管理IP为`oneasia-c1-cpu-node10 / 10.20.1.157`。
- JuiceFS metrics `127.0.0.1:9567`和已有Node Exporter `*:9100`正常；计划端口`9633`空闲。
- `jfsmetrics`用户/组、目标二进制和unit均不存在，无命名冲突。
- JuiceFS 1.4.1挂载的两个父子进程仍在运行，没有执行重挂或配置修改。
- 系统盘剩余约20 GiB，满足小型转发器安装需求。

## 150～152

- 主机名和IP一一匹配：`ceph-node1/.150`、`ceph-node2/.151`、`ceph-node3/.152`。
- 三节点`jfsnode`用户/组、Node Exporter/NVMe collector文件和unit均不存在，`9100`均空闲。
- 三节点均具备`/usr/sbin/nvme`、`/usr/bin/python3`及`/dev/nvme0`～`/dev/nvme3`四个控制器设备。
- PD、TiKV进程均存在；`/mnt/jfs-tikv`和`/mnt/dbwal`挂载均存在。
- 三节点可用内存约758～837 GiB，系统盘空间充足。

## 152 T05基线

- Portal、Grafana、Prometheus仍为active且disabled。
- `/etc/juicefs-portal/prometheus/prometheus.yml` SHA256为`595127085e72ed54a07def85fc4c4df7d8af37d079aa655db1ffdc7569b1561e`。
- `/etc/systemd/system/juicefs-prometheus.service` SHA256为`4409717e6550d5bd55cc71dcc90c3e11eb256d7747619d958621d4a739211ac1`。
- 两项均与staging携带的T05回滚基线完全一致，后续Prometheus切换具备确定的前置状态。

## 下一步边界

- 先只在150执行canary安装和当前会话启动；资源上限、9100指标、4个SMART样本、disabled状态、PD/TiKV和业务挂载全部验收通过后，才考虑151。
