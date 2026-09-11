# T06 指标接入与sudo执行计划

> 原则：逐节点、先安装后启动、每步只读验收；调试阶段全部保持`disabled`。下列写操作必须按阶段重新列出完整命令并取得用户确认后执行。

## 1. 架构

| 数据源 | 采集方式 | 周期 | 写入位置 |
|---|---|---:|---|
| 157 JuiceFS metrics | 受限Go转发器将localhost `9567`只读暴露给152的`9633` | 10 s | 无 |
| 157主机指标 | 复用现有Node Exporter `9100` | 10 s | 无 |
| 150～152主机指标 | 官方Node Exporter `1.12.1`，低基数collector | 10 s | 无 |
| 150～152 NVMe SMART | root oneshot写Node Exporter textfile | 5 min | 各节点系统盘上的单个`nvme.prom` |
| PD/TiKV | 直接抓取现有`2379/20180` metrics | 15 s | 无 |
| Ceph | mgr Prometheus模块`9283` | 15 s | 无 |
| Prometheus TSDB | 152中央Prometheus | 上述周期 | 152系统盘，14天/30 GB封顶 |

页面不会直接SSH、sudo、执行`ceph`/`nvme`或访问集群数据目录。

## 2. 低扰动与安全合同

- Node Exporter限制为20%单核、128 MiB、IOWeight 10，只启用CPU、内存、网络、文件系统、diskstats、textfile、time和uname。
- NVMe collector限制为20%单核、128 MiB、IOWeight 10，DevicePolicy关闭后仅给`/dev/nvme0`～`/dev/nvme3`读权限；任何控制器读取失败都保留上一份完整样本。
- 157转发器限制为10%单核、64 MiB，只接受152和localhost连接，只能访问loopback `9567/metrics`。
- Prometheus限制保持2核、6 GiB和IOWeight 10；按白名单在采集后丢弃无关series。
- 不触碰`/mnt/jfs-tikv`、`/mnt/dbwal`、任何NVMe namespace、Ceph OSD容器和现有PD/TiKV/JuiceFS进程。
- 不设置开机自启；任何脚本都不得出现`systemctl enable`。

## 3. 分阶段执行顺序

本地staging为`/tmp/jfsportal-t06-20260910-181003`。上传及三节点分发只写远端同名`/tmp`目录，先逐项SHA校验，不需要sudo。

### S1：150单节点canary

审批后按顺序执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t06-20260910-181003/scripts/t06-install-node-observability.sh /tmp/jfsportal-t06-20260910-181003 ceph-node1 10.20.1.150
sudo /bin/systemctl start juicefs-nvme-collector.service
sudo /bin/systemctl start juicefs-node-exporter.service juicefs-nvme-collector.timer
```

随后运行只读验收；必须确认`9100`、4个SMART样本、资源上限、disabled状态、PD/TiKV和业务挂载正常，才允许进入151。

### S2：151与152逐节点部署

151：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t06-20260910-181003/scripts/t06-install-node-observability.sh /tmp/jfsportal-t06-20260910-181003 ceph-node2 10.20.1.151
sudo /bin/systemctl start juicefs-nvme-collector.service
sudo /bin/systemctl start juicefs-node-exporter.service juicefs-nvme-collector.timer
```

152：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t06-20260910-181003/scripts/t06-install-node-observability.sh /tmp/jfsportal-t06-20260910-181003 ceph-node3 10.20.1.152
sudo /bin/systemctl start juicefs-nvme-collector.service
sudo /bin/systemctl start juicefs-node-exporter.service juicefs-nvme-collector.timer
```

151验收通过后才执行152。

### S3：157 JuiceFS只读转发

```bash
sudo /usr/bin/bash /tmp/jfsportal-t06-20260910-181003/scripts/t06-install-client-forwarder.sh /tmp/jfsportal-t06-20260910-181003
sudo /bin/systemctl start juicefs-metrics-forwarder.service
```

不修改或重启现有JuiceFS挂载；从152验证`10.20.1.157:9633/metrics`后收口。

### S4：Ceph mgr Prometheus

先只读运行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t06-20260910-181003/scripts/t06-ceph-readonly-inventory.sh
```

依据active mgr和module/config实际值再冻结写命令。预期最小命令只有：

```bash
sudo /usr/sbin/cephadm shell -- ceph mgr module enable prometheus
```

若默认地址/端口已可从152访问，不执行任何`ceph config set`；若不可达，暂停并另行审批精确配置命令。不启用Dashboard。

### S5：152切换Prometheus采集配置

所有上游验收通过后才执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t06-20260910-181003/scripts/t06-update-prometheus.sh /tmp/jfsportal-t06-20260910-181003
```

该脚本只备份/替换Prometheus配置和unit、执行`daemon-reload`并重启`juicefs-prometheus.service`；若失败会恢复T05文件并重新启动原Prometheus。不会改Portal/Grafana/PD/TiKV/Ceph OSD/JuiceFS。

## 4. 停止条件

任一阶段出现以下情况立即停止且保留现场：主机/IP/SHA不一致；目标文件或用户意外已存在；业务进程或挂载异常；Node Exporter/collector资源越界；SMART设备权限需要扩大到写；Ceph非健康；Prometheus回滚失败；任何服务意外变为enabled。

## 5. T06完成标准

- JuiceFS、PD、TiKV、Ceph、4个节点和12个NVMe控制器在Prometheus中按SLA自动刷新。
- 必需target全部up，Ceph至少一个mgr端点up，SMART样本每节点恰好4份。
- 断开单一端点时只表现为该对象stale/unavailable，不伪造0值。
- 所有新增服务保持disabled，资源限制生效，业务进程、挂载和Ceph健康不受影响。
