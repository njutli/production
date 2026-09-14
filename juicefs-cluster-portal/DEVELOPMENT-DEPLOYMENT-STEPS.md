# JuiceFS 集群只读管理门户开发与部署说明

> 当前部署：`10.20.1.152（ceph-node3）`
>
> 适用范围：后续功能开发、静态资源或服务更新、健康验收与回滚
>
> 安全原则：所有远端写操作遵守仓库 `skills/SYSTEM-SAFETY-SKILL.md`；sudo 命令必须逐项另行审批

## 1. 代码和配置

| 目录 | 内容 |
|---|---|
| `api/` | Go Portal、metrics forwarder、namespace collector、用户管理及 OpenAPI |
| `web/` | 无前端构建依赖的 HTML/CSS/JavaScript |
| `configs/` | 不含凭据的配置样例与 namespace root 清单 |
| `deploy/systemd/` | Portal、Prometheus、Grafana、exporter、collector 的 unit 模板 |
| `deploy/prometheus/` | Prometheus 白名单采集配置 |
| `deploy/scripts/` | 分阶段准备、更新、验证和回滚脚本 |
| `fixtures/` | 本地演示数据，不可用于生产判断 |
| `tests/` | 总离线 Gate |
| `docs/` | 当前有效范围、指标、数据模型和目录快照合同 |
| `inventory/` | 当前部署的最终签收证据 |

## 2. 本地开发与离线验收

```bash
make test
make run
```

`make test`必须在任何上传前通过。涉及前端时额外执行`node --check web/app.js`；涉及shell时对变更脚本执行`bash -n`；涉及Go代码时执行`go test ./...`和`go vet ./...`。

本地`make run`只监听`127.0.0.1:8080`并使用脱敏fixture。不得把真实密码、Ceph keyring、META URL或主机私有数据写入fixture和Git。

## 3. 当前部署组成

152系统盘上的主要位置：

```text
/opt/juicefs-portal/             程序和静态资源
/etc/juicefs-portal/             配置与root-only凭据
/var/lib/juicefs-portal/
├── prometheus/                  TSDB，14天/30 GiB双上限
├── grafana/
├── portal/                      用户配置和namespace.db
└── tXX-backup-<RUN>/            每次更新的精确回滚副本
```

主要unit：

- 152：`juicefs-portal`、`juicefs-prometheus`、`juicefs-grafana`、`juicefs-namespace-mount`、`juicefs-namespace-collector.timer`；
- 150～152：`juicefs-node-exporter`、`juicefs-nvme-collector.timer`；
- 157：`juicefs-metrics-forwarder`。

所有新增unit当前均为`disabled/static`，不得在普通更新中设置开机自启。Prometheus与Grafana只监听loopback；Portal的8443仅允许157与152自身。

## 4. 更新流程

1. 明确本次只修改哪些文件、unit和接口；不顺带清理旧备份或扩大权限。
2. 本地完成测试，生成唯一RUN目录和文件SHA256清单。
3. 先做目标节点只读preflight：磁盘空间、服务/PID、端口、目标文件、业务挂载和Ceph健康。
4. 列出完整sudo命令、节点和路径，经用户批准后才执行。
5. 更新前把被替换文件复制到该RUN专用备份目录；更新失败只按该备份精确恢复。
6. 只重启确实需要重启的管理unit。纯静态资源更新优先直接替换，不重启Portal。
7. 更新后执行功能、权限、数据新鲜度、资源上限、`NRestarts`和业务指纹验收。
8. 形成一份最终签收；preflight、传输和失败尝试不再各建长期文档，其必要结论合并入最终签收。

禁止把PD/TiKV、Ceph OSD、JuiceFS业务挂载、NVMe设备或业务数据操作混入门户更新。

## 5. 运行检查

日常只读检查至少覆盖：

- Portal HTTPS健康、ADMIN/USER/匿名权限边界；
- Prometheus targets数量与样本年龄；
- Portal、Prometheus、Grafana和采集unit状态及`NRestarts`；
- T09 SQLite generation、ready/stale状态和180秒年龄上限；
- Ceph健康、PD/TiKV PID、`/mnt/jfs-tikv`、`/mnt/dbwal`和157业务挂载指纹；
- 152系统盘余量及管理组件资源使用。

发生数据源故障时允许门户显示stale/error，不允许为恢复页面而自动修改或重启数据面。

## 6. T09目录快照特殊边界

- Portal不接触控制挂载，只以SQLite `query_only`方式读快照；
- collector固定60秒运行，使用`findmnt -M`确认挂载；失败保留上一代；
- 控制挂载技术上为rw，但不含`allow_other/allow_root`，使用`--atime-mode noatime --cache-size 0 --backup-meta 0`；
- 每目录只展示top 100具名直接子项和“其余项（聚合）”，递归总量仍完整；
- 用户请求不得触发`du`、递归扫描、JuiceFS命令、SSH或sudo。

详细合同见`docs/T09-DIRECTORY-SNAPSHOT-DESIGN.md`。

## 7. 回滚和文档

任何回滚都必须使用对应RUN备份中的精确脚本，并重新提交sudo审批；禁止通配删除、递归改属主或从不明备份恢复。回滚后重复完整只读验收。

当前功能与访问方式见`CURRENT-STAGE-SYSTEM-OVERVIEW-20260914.md`；部署裁决见`inventory/CURRENT-DEPLOYMENT-ACCEPTANCE-SUMMARY-20260914.md`；未完成事项见`TODO.md`。
