# JuiceFS 管理门户当前部署验收摘要

> 截止日期：2026-09-14
>
> 用途：替代预检、staging、canary 和失败回滚等过程性报告，保留当前有效结论与故障经验。

## 1. 阶段签收索引

| 阶段 | 裁决 | 保留证据 |
|---|---|---|
| T05 基础服务 | PASS | `T05-BASE-DEPLOYMENT-SIGNOFF-20260910.md` |
| T06 指标接入 | PASS | `T06-PROMETHEUS-INTEGRATION-SIGNOFF-20260910.md` |
| T07 实时管理 MVP | PASS | `T07-LIVE-MVP-SIGNOFF-20260910.md` |
| T08 认证、RBAC、HTTPS | PASS | `T08-AUTH-RBAC-HTTPS-SIGNOFF-20260910.md` |
| T09 业务目录快照 | PASS | `T09-BUSINESS-NAMESPACE-DEPLOYMENT-FINAL-SIGNOFF-20260911.md` |
| T10 低扰动与故障隔离 | PASS | `T10-LOW-IMPACT-AND-FAILURE-ISOLATION-FINAL-SIGNOFF-20260911.md` |
| T11 试运行 | PASS；62小时39分内752/752样本通过 | `T11-LONG-TERM-TRIAL-FINAL-SIGNOFF-20260914.md` |
| T12 带宽趋势 | PASS | `T12-BANDWIDTH-TREND-FINAL-SIGNOFF-20260914.md` |

## 2. 当前有效运行合同

- Portal、Prometheus、Grafana 位于 152；157 仅运行 JuiceFS metrics 转发器；150～152 运行只读主机/NVMe 采集。
- 14 个 Prometheus targets 覆盖 Portal/Prometheus、JuiceFS、PD/TiKV、Ceph 和节点指标；NVMe 清单覆盖 12 个控制器。
- Portal HTTPS 仅允许 157 和 152，Prometheus/Grafana 不对外暴露。
- 全部新增服务保持 `disabled/static`，没有设置开机自启。
- Portal 和 Prometheus 故障只影响管理可见性，不影响数据面；数据源异常必须显示 stale/error。
- T09 页面只读 SQLite；目录采集失败保留上一代，不把失败表示为 0。

## 3. 已吸收的部署故障经验

以下结论仍是现行配置的必要依据，原过程报告不再单独保留：

1. 152 的 JuiceFS 控制挂载既要访问 TiKV `10.20.1.150～152:2379`，也要访问 Ceph client/public 网络 `10.3.1.6～8`；只开放 TiKV 地址会导致挂载进程无法完成数据引擎初始化。
2. Ceph 认证使用业务 Pool 所需的 `client.juicefs` keyring；不得为门户部署 `client.admin`。
3. systemd 249 中 `RestrictAddressFamilies`、`LockPersonality`会间接带来 `NoNewPrivileges`，使 setuid `fusermount`失效；该冲突只在 `juicefs-namespace-mount.service` 内做最小修正，不放宽其他服务。
4. `ConditionPathIsMountPoint`不能可靠识别该 FUSE 挂载，collector 以 `findmnt -M`做精确挂载条件判断。
5. JuiceFS `summary`会以 `O_RDWR`打开虚拟 `.control`；因此控制挂载不能设置内核只读标志。只读性由专用账户、无 `allow_other/allow_root`、固定命令、Portal 路径隔离和只读 SQLite API 共同保证。
6. JuiceFS 1.4.1 的 `summary --entries`单层最多 100；完整汇总有效，具名明细必须表达为 top 100 加“其余项（聚合）”。
7. `--atime-mode noatime`是 JuiceFS 元数据行为参数，不是 `findmnt`中可见的通用挂载选项，验收不能错误断言后者。
8. `/usr/bin/fusermount3`的符号链接显示 `0777`不代表实际 helper 权限；必须解析目标文件并核对 setuid 位。

## 4. 证据保留原则

本目录只长期保留阶段最终签收和本摘要。原有受版本管理的预检、传输、canary、失败尝试与回滚报告仍可从 Git 历史恢复；原始运行数据继续保存在 `/mnt/c/SunRise/test/juicefs-cluster-portal/`，不把大量原始输出复制回仓库。
