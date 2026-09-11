# T06 Ceph Prometheus模块只读盘点

> 时间：2026-09-10  
> 裁决：`T06_CEPH_READONLY_INVENTORY_PASS`  
> 状态变更：无，仅执行Ceph只读命令。

## 集群现状

- FSID：`f8137e5a-8af2-11f1-aa1c-4df480fc234d`。
- Ceph版本：v17容器，MGR daemon报告`17.2.8`。
- 健康状态：`HEALTH_OK`。
- MON：3个，quorum为`ceph-node1/2/3`。
- MGR：`ceph-node1.ypjxtz` active，`ceph-node2.xkjasi` standby。
- OSD：6个，全部up/in。
- PG：97个，全部`active+clean`。

## Prometheus模块

- 当前启用模块中不包含`prometheus`。
- `ceph mgr services`返回空对象，150/151/152的`9283`均未监听。
- Prometheus模块可运行，默认`server_addr=::`、`server_port=9283`。
- `/proc/sys/net/ipv6/bindv6only=0`，默认IPv6通配监听可接受IPv4连接，因此无需先修改监听地址。

## 最小变更

只需在150执行：

```bash
sudo /usr/sbin/cephadm shell -- ceph mgr module enable prometheus
```

该命令不重启MGR、MON或OSD，但会把模块启用状态持久化到Ceph配置。若端点、资源或健康验收失败，回退命令为：

```bash
sudo /usr/sbin/cephadm shell -- ceph mgr module disable prometheus
```

不执行`ceph config set`，不启用Ceph Dashboard。

