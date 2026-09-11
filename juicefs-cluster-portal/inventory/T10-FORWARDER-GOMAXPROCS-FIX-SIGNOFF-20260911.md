# T10 metrics forwarder线程修复签收

> 时间：2026-09-11 07:12 CST  
> 裁决：`T10_FORWARDER_FIX_PASS`  
> 状态变更：只替换并重启157的`juicefs-metrics-forwarder.service`。

## 执行

- staging `/tmp/jfsportal-t10-20260911-070908`在157通过完整SHA和shell语法检查。
- 安装前unit SHA为`e700699e8587ada74c23faea157f1f33e7c7ced256a81774b46d3980ddbd3767`，与冻结值一致。
- 获批脚本只增加`Environment=GOMAXPROCS=1`，保留`CPUQuota=10%`、`MemoryMax=64M`、`IOWeight=10`和`TasksMax=32`。
- 回滚备份：`/var/lib/juicefs-portal/juicefs-metrics-forwarder.service.t10-20260911-070908.bak`。

## 即时验收

- 脚本返回`T10_FORWARDER_FIX_PASS tasks=3 ... enabled=false`；修复前线程数为32，修复后为3。
- 脚本在重启前后核对157的JuiceFS挂载进程PID集合及`/mnt/juicefs`完整`findmnt`结果，均未变化。
- 152直接抓取`http://10.20.1.157:9633/metrics`成功。
- Prometheus查询`up{job="juicefs-client"}=1`。
- 152 PD PID=`1589960`、TiKV PID=`2088516`，`/mnt/jfs-tikv`和`/mnt/dbwal`挂载未变。
- 未操作Portal、Prometheus、Grafana、PD/TiKV、Ceph、NVMe、JuiceFS挂载或业务数据。

## 延时复核

SSH链路恢复后执行了延时只读复核，不重复更新或重启服务：

- 157 forwarder仍为`active/disabled`，主PID为`3145953`，`NRestarts=0`、`TasksCurrent=3/32`、内存约5.6 MiB，运行环境包含`GOMAXPROCS=1`；
- 152 Portal健康接口正常，Prometheus `sum(up)=14`，`ceph_health_status=0`；Portal、Prometheus、Grafana均为`active/disabled`且`NRestarts=0`；
- 152 PD/TiKV PID仍为`1589960/2088516`，`/mnt/jfs-tikv`及`/mnt/dbwal`挂载未变。

因此即时与延时证据一致，线程修复正式签收。
