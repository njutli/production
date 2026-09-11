# T10阶段A低扰动与安全只读盘点

> 时间：2026-09-11  
> 裁决：`T10_PHASE_A_CONDITIONAL_PASS`  
> 状态变更：无；仅执行普通只读查询及sudo只读日志/容量查询。

## 1. 资源短窗

两次cgroup计数器采样间隔因逐节点SSH顺序约为31～39秒，所得CPU为近似单核占用：

| 节点/服务 | CPU占单核 | 内存 |
|---|---:|---:|
| 152 Portal | 约0.001% | 约10 MiB |
| 152 Prometheus | 约0.53% | 约364 MiB |
| 152 Grafana | 约0.33% | 约200 MiB |
| 152 Node Exporter | 约0.26% | 约10 MiB |
| 150 Node Exporter | 约0.28% | 约21 MiB |
| 151 Node Exporter | 约0.27% | 约12 MiB |
| 157 metrics forwarder | 约0.03% | 约11 MiB |

- 152上述四个常驻服务合计约584 MiB；加上既有管理组件余量后仍低于T10的1 GiB目标。
- 所有受管服务保持`active/disabled`，152 Portal/Prometheus/Grafana/Node Exporter以及150/151 Node Exporter均`NRestarts=0`。
- CPUQuota、MemoryMax和IOWeight合同均已由systemd加载；没有观测到业务盘I/O写入来自Portal或Node Exporter。

## 2. 数据保留和健康

- Prometheus启动参数包含`--storage.tsdb.retention.time=14d`及`--storage.tsdb.retention.size=30GB`。
- 运行时指标`prometheus_tsdb_retention_limit_bytes=32212254720`，确认30 GiB限制实际生效。
- 当前TSDB为`262458162`字节，约250 MiB；禁止为了验收人为填满30 GiB系统盘，实际回收留到T11观察。
- Prometheus查询得到`sum(up)=14`、`count(up)=14`，即14/14 targets在线；`ceph_health_status=0`。

## 3. 安全与隔离现状

- T08已验证ADMIN 200、USER越权403、匿名401、非授权写方法405。
- 157可访问Portal HTTPS，151访问8443超时；外部来源限制有效。
- Portal与Prometheus不存在被PD/TiKV/CEPH/JuiceFS依赖的systemd关系；停止管理面不会按依赖传播到业务组件。
- T09文件/目录功能仍延期，因此路径穿越和目录越权不在本阶段制造虚假验收结论。

## 4. 阻断缺陷：forwarder线程上限

- 157 `juicefs-metrics-forwarder.service`当前为active/disabled、约11 MiB、约0.03%单核，但`NRestarts=6`、`TasksCurrent=32`、`TasksMax=32`。
- root只读日志明确记录：`runtime: failed to create new OS thread (have 33 already; errno=11)`和`fatal error: newosproc`。
- 根因是157有128个CPU，Go运行时默认按宿主核数创建调度/GC线程，而该轻量服务被限制为最多32个task；不是JuiceFS metrics源、网络或业务进程故障。
- 正确修复是设置`GOMAXPROCS=1`，与`CPUQuota=10%`一致；不应放宽TasksMax或资源上限。

## 5. 已完成的离线准备

- 修改`deploy/systemd/juicefs-metrics-forwarder.service`，仅新增`Environment=GOMAXPROCS=1`。
- 修复/回滚脚本：`deploy/scripts/t10-fix-forwarder-gomaxprocs.sh`；无删除、递归权限修改、重启/关机、业务服务或设备操作。
- staging：`/tmp/jfsportal-t10-20260911-070908`，只含脚本和unit两项。
- `SHA256SUMS`：`db170dbc355a2d34d63f1b4467a4f42c3d6ac95633117c29336658b19478197b`。
- 脚本SHA：`2d96cf512c56e535f0ebdd7bf2deb81fe2bb65cf4a70a91627ade8b016784a7d`。
- unit SHA：`f4076539a07b6defdf9121729f6fab0e0482b5d6b7f1006737be32bb4086e96d`。
- 安装前冻结的157现有unit SHA为`e700699e8587ada74c23faea157f1f33e7c7ced256a81774b46d3980ddbd3767`；不匹配即拒绝执行。

## 6. 下一变更门

先上传staging到157的`/tmp`并校验，然后执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t10-20260911-070908/scripts/t10-fix-forwarder-gomaxprocs.sh /tmp/jfsportal-t10-20260911-070908
```

脚本内部写操作仅为：创建精确备份目录、备份并替换单个forwarder unit、`systemctl daemon-reload`、重启`juicefs-metrics-forwarder.service`；失败时恢复该unit并再次重启forwarder。不会操作或重启JuiceFS挂载进程、PD/TiKV、Ceph、Portal、Prometheus、Grafana、NVMe和业务数据。
