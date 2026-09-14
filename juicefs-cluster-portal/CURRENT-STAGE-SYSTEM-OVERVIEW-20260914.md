# JuiceFS 集群只读管理门户阶段功能说明

> 状态：当前阶段基本可用
>
> 截止日期：2026-09-14
>
> 中央部署节点：`10.20.1.152（ceph-node3）`
>
> 原则：管理面只读、低扰动；管理面故障不得影响 JuiceFS、TiKV/PD、Ceph 和 157 上的业务

## 1. 当前结论

门户已经完成从本地演示到真实集群接入，可集中查看 JuiceFS、TiKV/PD、Ceph、主机、NVMe、客户端和目录用量状态，并具备 HTTPS、本地账户、ADMIN/USER 权限隔离、数据过期提示及带宽历史曲线。

当前适合作为集群只读管理与排障入口。它不提供集群控制、文件写入、完整文件浏览或内容下载，也未配置开机自启。

## 2. 部署结构

```text
150～152 Node Exporter / NVMe Collector ─┐
150～152 PD、TiKV、Ceph metrics ─────────┼─> 152 Prometheus ─> 152 Portal API/UI :8443
157 JuiceFS metrics -> 轻量只读转发器 ──┘                       │
                                                               ├─> ADMIN 页面
152 JuiceFS专用控制挂载 -> 目录采集器 -> SQLite快照 ───────────└─> USER/ADMIN 用量页面
```

- 152 承载 Portal、Prometheus、Grafana、目录快照采集器和 SQLite；这些数据均位于系统盘专用目录，不写入 TiKV、Ceph OSD 或 JuiceFS 业务路径。
- 157 仅运行轻量 metrics 转发器，不重挂、不重启业务 JuiceFS。
- 150～152 的主机与 NVMe 采集器只读采集；Prometheus 和 Grafana 只监听 152 loopback。
- Portal 对外只开放 152 的 HTTPS `8443`，当前仅允许 157 和 152 自身访问。

## 3. 已实现功能

### 3.1 ADMIN 管理员

| 页面 | 当前能力 |
|---|---|
| 总览 | 集群健康、组件摘要、容量、客户端状态、实时带宽、告警和数据年龄 |
| 带宽趋势 | JuiceFS 逻辑读/写、Ceph `juicefs-data` 物理读/写；支持 15 分钟、1 小时、6 小时、24 小时窗口 |
| 拓扑 | client → JuiceFS volume → PD/TiKV，以及 client → Ceph pool → OSD → 物理盘 |
| 节点与磁盘 | 150～152 和 157 的节点状态、网络；150～152 共 12 块 NVMe 的型号、用途、健康和 I/O |
| JuiceFS 客户端 | 在线状态、版本、挂载与逻辑 I/O 指标 |
| TiKV/PD | PD Leader、成员和 TiKV Store 状态及指标 |
| Ceph | MON/MGR/OSD/PG、容量、Pool I/O、健康与告警 |
| 用量 | 业务卷递归总容量、文件数、目录数，以及三级目录内的大项 |
| 告警 | 数据源或组件异常、过期与恢复状态；只提示，不自动修复 |

### 3.2 USER 普通用户

- 只能查看账户绑定的授权目录用量；不能访问管理员 API 或其他 root。
- 可查看授权 root 的递归总容量、文件数、目录数，以及最多三级目录结构。
- 每个目录显示递归用量最大的 100 个直接子项；其余项目合并为“其余项（聚合）”，总容量和计数仍完整。
- 当前不提供完整文件清单、mtime、文件内容预览或下载。

## 4. 数据实时性

| 数据 | 后端采集 | 页面刷新/查询 | 过期判定 |
|---|---:|---:|---:|
| JuiceFS、主机、网络和磁盘 I/O | 10 秒 | 5 秒 | 25 秒 |
| PD/TiKV、Ceph | 15 秒 | 5 秒 | 35 秒 |
| 拓扑与容量聚合 | 30 秒 | 10 秒 | 70 秒 |
| SMART/NVMe 健康 | 5 分钟 | 30 秒 | 11 分钟 |
| 三级目录用量快照 | 60 秒 | 30 秒 | 180 秒 |
| 四条带宽趋势 | 复用 Prometheus 历史样本 | 30 秒 | 随对应指标 |

任何失联或过期数据都显示 `stale/unavailable`，不会伪装成 0 或健康。Portal 页面请求只读取 Prometheus 或 SQLite，不临时执行 SSH、`ceph`、`smartctl`、`du` 或 JuiceFS CLI。

## 5. 目录用量实现与限制

社区版 JuiceFS 1.4.1 的 DirStats 能快速返回完整递归汇总，但单层具名明细最多返回 top 100。当前采用异步快照：152 上的专用控制挂载每 60 秒运行一次固定 `summary`，原子写入 SQLite；用户请求只查数据库。

验证结果：10 万文件、1111 个目录时，DirStats fast 约 `0.05 s`，严格统计约 `0.18 s`，同步 `du` 约 `22 s`，且 fast/strict 汇总一致。因此当前设计能提供快速、完整的总量统计，但不能作为完整文件浏览器。

采集失败时保留上一代快照并标记过期；单 root 和单次响应最多 10,000 行，防止管理查询挤占业务资源。

## 6. 权限和安全边界

- 登录使用本地账户；密码保存为 Argon2id 哈希，会话 Cookie 为 `HttpOnly + Secure + SameSite=Strict`。
- ADMIN 能访问全部只读管理 API；USER 只能访问绑定目录；匿名请求返回 401，越权返回 403，非授权写方法返回 405。
- 时序 API 只接受固定语义指标 ID，不接受用户提交任意 PromQL。
- Portal、Prometheus、Grafana 和采集器由独立 systemd unit 与资源上限约束，但按用户要求均未设置开机自启。
- 目录 `summary` 的 `.control` 请求要求技术上的可写 FUSE 挂载；专用挂载不含 `allow_other/allow_root`，使用 `--atime-mode noatime --cache-size 0 --backup-meta 0`。Portal 自身被 systemd 路径隔离，无法访问该挂载，只能读取 SQLite。
- 专用挂载仅使用 Pool 级 `client.juicefs` 凭据，不使用 `client.admin`；网络只放行所需 TiKV 与 Ceph client/public 地址。
- Portal 或 Prometheus 停止只会降低管理可见性。故障隔离实测期间，PD/TiKV、Ceph、业务挂载及目录快照均未被改变。

## 7. 当前运行与验收状态

| 阶段 | 结果 |
|---|---|
| 基础部署 | Portal、Prometheus、Grafana 在 152 运行，均未启用开机自启 |
| 指标接入 | JuiceFS、PD/TiKV、Ceph、4 台主机和 12 块 NVMe 已接入；Prometheus 14/14 targets 在线 |
| 实时门户 | 8 个管理员页面接入真实数据，缺失数据降级为 stale/unavailable |
| 认证/RBAC/HTTPS | ADMIN/USER/匿名/写方法边界通过，8443 仅限 157/152 |
| 目录用量 | 真实业务卷快照、top 100+聚合、权限、资源上限和 60 秒更新通过 |
| 低扰动/故障隔离 | Portal/Prometheus 故障不会影响数据面，恢复后指标回到 fresh |
| 长期观察 | 62小时39分内752/752样本通过；记录器已停止，证据已持久化，T11正式签收完成 |
| 带宽趋势 | 四项曲线、四档时间窗口、30 秒刷新及权限边界通过，部署过程未重启服务 |

阶段最终验收索引见 `inventory/CURRENT-DEPLOYMENT-ACCEPTANCE-SUMMARY-20260914.md`。

## 8. 访问方式

本机建立 SSH 隧道：

```bash
ssh -F /home/lilingfeng/.ssh/config -N -T \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:8443:10.20.1.152:8443 thailand
```

浏览器访问 `https://localhost:8443/`。当前证书为自签名证书，SHA256 指纹：

```text
78:2A:A7:57:1D:74:FC:60:29:46:EC:DD:2E:7E:6B:74:C3:28:C9:17:63:20:7E:FF:15:6B:F1:46:CF:34:CD:F0
```

初始凭据只保存在 152 的 root-only 文件 `/etc/juicefs-portal/bootstrap-credentials.txt`，不得复制到 Git 或报告。

## 9. 尚未完成或不在当前范围

- 尚未设置开机自启；节点重启后的恢复仍需人工操作和验收。
- 组织 CA 证书、LDAP/OIDC、告警通知和高可用门户尚未实现。
- 完整文件浏览、搜索、属性、内容预览和下载不在当前范围。
- 当前系统是只读门户，不提供服务启停、配置修改、扩缩容或故障自动修复。

## 10. 权威文档

- 当前范围与页面字段：`docs/MONITORING-MVP-V1-SCOPE.md`
- 指标来源与白名单：`docs/METRICS-WHITELIST-V1.md`
- 数据模型与刷新 SLA：`docs/DATA-MODEL-AND-REFRESH-V1.md`
- 目录快照合同：`docs/T09-DIRECTORY-SNAPSHOT-DESIGN.md`
- API 合同：`api/openapi-v1.yaml`
- 开发部署步骤：`DEVELOPMENT-DEPLOYMENT-STEPS.md`
- 当前任务状态：`TODO.md`
