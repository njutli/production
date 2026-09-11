# T09网络修复版安装前只读预检签收

> 时间：2026-09-11  
> RUN：`20260911-141910`  
> 裁决：`T09_NETWORK_FIX_READONLY_PREFLIGHT_PASS`；没有安装、启动、重启或enable任何对象。

## 结果

152执行新RUN的root只读preflight返回：

```text
T09_READONLY_PREFLIGHT_PASS host=ceph-node3 mem_available_kib=857618128 disk_available_bytes=795005353984
```

预检同时确认：

- 新RUN 28项SHA完整；
- 现有Portal、Prometheus和Grafana仍为`active/disabled`，T08固定资产未漂移；
- 真实`fusermount3` helper为批准的`root:root 4755`和固定SHA；
- 三台TiKV `10.20.1.150～152:2379`均可达；
- 三个Ceph MON public/client地址`10.3.1.6～8:3300`均可达；
- `jfsportal`身份可以读取`/etc/ceph/ceph.conf`；
- T09目标文件、unit、SQLite和专用挂载均不存在；
- PD、TiKV及`/mnt/jfs-tikv`、`/mnt/dbwal`业务指纹存在。

## 下一步

下一步是唯一的状态变更命令，须获得用户明确授权后执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t09-20260911-141910/scripts/t09-update-namespace.sh /tmp/jfsportal-t09-20260911-141910
```

它只安装T09受管资产、启动static专用只读挂载/collector/timer并重启Portal；不enable服务，不修改PD、TiKV、Ceph、网络配置或157业务挂载。失败时自动按精确备份回滚。
