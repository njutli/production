# T06 节点150采集器canary签收

> 时间：2026-09-10  
> 裁决：`T06_NODE150_CANARY_PASS`  
> 范围：仅`10.20.1.150（ceph-node1）`。

## 执行结果

- staging完整SHA和危险命令扫描通过后，执行了用户批准的三条sudo命令。
- 新建`jfsnode`系统用户/组，UID/GID均为998。
- Node Exporter `1.12.1`启动成功，主PID为`1131032`，`NRestarts=0`。
- NVMe oneshot执行成功，`ExecMainStatus=0`；生成`nvme.prom`，权限为`0644 root:jfsnode`，包含4个控制器的完整样本。
- NVMe温度、available spare、percentage used、media errors、unsafe shutdowns和critical warning均可解析；本次4个控制器的info和温度样本数量均为4。
- 5分钟NVMe timer为active但disabled；Node Exporter同样为active但disabled，没有设置开机自启。

## 资源与连通性

- Node Exporter `MemoryCurrent=12038144`字节，约11.5 MiB；`TasksCurrent=4`。
- cgroup限制：CPU 20%单核、内存128 MiB、IOWeight 10。
- 从152抓取`http://10.20.1.150:9100/metrics`返回HTTP 200，约144 KiB，耗时约17.8 ms。
- 输出包含主机、磁盘IO和4个NVMe控制器指标。

## 业务保护检查

- PD PID `2898123`、TiKV PID `392870`保持运行。
- `/mnt/jfs-tikv`和`/mnt/dbwal`保持挂载。
- 没有重启或修改PD、TiKV、Ceph、JuiceFS和任何业务挂载。
- 151、152和157尚未安装或启动T06采集服务。
