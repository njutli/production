# JuiceFS 集群只读管理门户实施计划

> 文档状态：初稿
> 创建日期：2026-09-10
> 实施目录：`/home/lilingfeng/demo/production/juicefs-cluster-portal`
> 当前范围：方案设计，不执行部署、不修改现有集群

## 1. 建设目标

为当前 JuiceFS + TiKV/PD + Ceph 集群建设统一、自动刷新的只读管理界面，集中展示：

- JuiceFS 卷、客户端和实时读写状态；
- TiKV/PD、Ceph、主机、网络和磁盘健康状态；
- 集群组件拓扑及组件到主机、磁盘、网络的映射；
- 逻辑容量、物理容量、文件数、inode 和配额用量；
- 文件及目录的基本只读信息；
- 当前告警和历史趋势。

系统只提供查看能力，不提供文件修改、服务启停、磁盘操作或集群配置变更能力。

## 2. 当前部署基线

当前设计以仓库中的实际部署配置为准：

- `10.20.1.150`、`10.20.1.151`、`10.20.1.152`：三节点 PD + TiKV；
- 每节点 `nvme1n1` 挂载到 `/mnt/jfs-tikv`，承载 TiKV 数据；
- 三节点同时承载 Ceph MON/MGR/OSD；
- 每节点 `nvme2n1`、`nvme3n1` 各承载一个 OSD，共 6 个 OSD；
- Ceph 数据池为 `juicefs-data`，EC 4+2，failure domain 为 OSD；
- Ceph public 网络为 `10.3.1.0/24`，cluster 网络为 `10.3.2.0/24`；
- `10.20.1.157` 为主要 JuiceFS FUSE 客户端；
- 当前 Ceph bootstrap 显式使用了 `--skip-dashboard` 和 `--skip-monitoring-stack`，尚无统一监控平台。

对应配置来源：

- `prod-deploy/config.sh`
- `prod-deploy/scripts/deploy-ceph.sh`
- `prod-deploy/scripts/deploy-tikv.sh`

## 3. 总体架构

### 3.1 部署节点决策

中央监控和统一门户选定部署在 `10.20.1.152（ceph-node3）` 的系统盘上。

2026-09-10 只读盘点结果：

| 节点 | CPU/负载 | 可用内存 | 系统盘可用 | PD角色 | Ceph MGR进程 | 结论 |
|---|---|---:|---:|---|---|---|
| 150 | 96核，load约16.6，存在大量wekanode活跃进程 | 约741 GiB | 约728 GiB | 当前Leader | 有 | 不选 |
| 151 | 128核，load约0.02 | 约817 GiB | 约802 GiB | Follower | 有 | 次选 |
| 152 | 128核，load约0.01 | 约817 GiB | 约744 GiB | Follower | 无 | **选定** |

152后续可能因PD选举成为Leader，因此仍必须使用systemd/cgroup限制管理服务资源。门户故障或152离线只允许影响监控可见性，不能影响JuiceFS、TiKV/PD或Ceph数据服务。

```text
用户浏览器
    │ HTTPS
    ▼
Nginx / 统一认证入口
    │
    ├── Portal UI
    │     ├── 普通用户：文件、目录、授权范围用量
    │     └── 管理员：全部页面
    │
    ├── Portal API
    │     ├── RBAC
    │     ├── 拓扑聚合
    │     ├── 磁盘清单
    │     ├── 用量聚合
    │     └── 只读 Namespace API
    │
    ├── Grafana
    │     └── Prometheus
    │           ├── JuiceFS 客户端 metrics
    │           ├── PD/TiKV metrics
    │           ├── Ceph mgr metrics
    │           ├── Node Exporter
    │           └── SMART/NVMe metrics
    │
    └── JuiceFS 专用只读挂载
          └── 文件和目录查询
```

### 3.2 推荐组件

| 组件 | 推荐实现 | 职责 |
|---|---|---|
| 统一入口 | Nginx | HTTPS、反向代理、安全头和访问日志 |
| Portal UI | Vue 或 React | 页面、拓扑图、文件浏览及自动刷新 |
| Portal API | Go | RBAC、数据聚合、目录隔离和缓存 |
| 时序数据库 | Prometheus | 实时指标和短中期历史数据 |
| 图表 | Grafana | JuiceFS、TiKV、Ceph、节点和磁盘图表 |
| 告警 | Alertmanager | 只通知，不执行自动修复 |
| 配置数据库 | PostgreSQL；MVP 可用 SQLite | 用户、角色、授权路径和门户配置 |
| 主机指标 | Node Exporter | CPU、内存、网络、文件系统和块设备指标 |
| 磁盘健康 | smartctl/NVMe Exporter | 温度、寿命、介质错误和异常关机信息 |

Grafana 作为门户内部的图表能力使用，不直接暴露给普通用户。门户后端必须独立校验每个 API 的权限，不能只依靠隐藏菜单。

## 4. 页面设计

### 4.1 普通用户页面

普通用户只显示“文件浏览”和“用量”两个菜单。

#### 文件浏览

展示：

- 当前路径和面包屑导航；
- 文件或目录名称、类型和逻辑大小；
- 所有者、用户组、权限和修改时间；
- 目录的浅层子项数量；
- 分页结果及本次读取时间。

约束：

- 只允许访问账户绑定的一个或多个授权根目录；
- 默认不提供文件内容预览或下载；
- 每页最多 100～200 项；
- 只自动刷新当前打开的目录，不递归刷新整棵目录树；
- 禁止上传、创建、删除、重命名、chmod、chown 和移动操作。

#### 用量

展示：

- 用户、UID/GID 或授权目录已用容量；
- 文件和目录数量、inode 使用量；
- 配额、剩余容量和使用率；
- 最近 24 小时、7 天和 30 天变化趋势；
- 数据增长速率和预计容量耗尽时间；
- 垃圾箱占用（若启用且能取得可靠统计）。

### 4.2 管理员页面

管理员包含普通用户页面，并增加以下页面。

#### 总览

- JuiceFS 卷状态和在线客户端数；
- JuiceFS 逻辑读/写带宽；
- Ceph 后端物理读/写带宽；
- 节点网卡读/写带宽；
- TiKV 元数据 QPS 和关键延迟；
- 逻辑容量、Ceph Pool 用量和 Ceph Raw 用量；
- PD、TiKV、MON、MGR、OSD 和 PG 健康状态；
- 当前告警及各数据源最后更新时间。

客户端逻辑带宽、Ceph 物理带宽和网卡带宽必须分开展示。缓存命中或 writeback 开启时三者可能明显不同，禁止合并为一个“集群带宽”。

#### 集群拓扑

```text
JuiceFS 客户端 157
 ├── 元数据请求 → PD 150/151/152
 │                  └── TiKV 150/151/152
 └── 数据请求   → Ceph MON/MGR
                    └── EC 4+2 Pool
                       ├── OSD.0/1 → 150 nvme2/3
                       ├── OSD.2/3 → 151 nvme2/3
                       └── OSD.4/5 → 152 nvme2/3
```

拓扑节点状态：

- 绿色：正常；
- 黄色：可用但有告警；
- 红色：服务或设备异常；
- 灰色：数据超过两个采集周期未更新。

点击组件显示主机、IP、版本、PID、启动时间、上下游关系、当前吞吐、延迟、磁盘和网卡映射。

拓扑必须由实时信息和静态部署清单共同生成，不能只显示静态配置。需要识别 MGR 主备切换、PD Leader 变化、TiKV Store Down、OSD 状态变化和客户端上下线。

#### 磁盘

按“节点 → 物理盘 → 文件系统/LVM → 服务”展示：

- 设备名、型号、序列号和固件；
- 总容量、已用、可用和挂载点；
- PCIe 地址、NUMA 节点；
- 当前读写带宽、IOPS、延迟、队列深度和利用率；
- 温度、寿命、Media Error、Unsafe Shutdown；
- TiKV 或 OSD 用途；
- Ceph OSD block、DB、WAL 映射；
- DB/WAL 当前是否位于 tmpfs。

#### JuiceFS 客户端

- 主机、IP、挂载点、版本、会话 ID 和在线状态；
- 挂载启动时间和主要挂载参数；
- FUSE IOPS、带宽和延迟；
- 元数据操作 QPS 和延迟；
- 对象 GET/PUT 带宽、请求数和延迟；
- 缓存容量、命中率、淘汰和 drop；
- writeback 暂存量、上传速率和积压；
- 客户端 CPU、内存和网络状态。

#### TiKV/PD

PD：

- 成员、Leader、quorum；
- Store Up/Down；
- Region 和 Leader 分布；
- 调度状态、热点 Store 和热点 Region；
- 心跳和时钟异常。

TiKV：

- Scheduler、prewrite 和 commit 延迟；
- Raft propose、commit、apply 和 WAL 延迟；
- RocksDB 各 CF 容量；
- L0 文件数、pending compaction bytes；
- compaction 读写速率和 write stall；
- CPU、内存、磁盘、网络和磁盘余量。

#### Ceph

- HEALTH_OK/WARN/ERR；
- MON quorum 和 MGR 主备；
- OSD up/in；
- PG 状态；
- Pool 逻辑用量、Raw 用量和 EC 放大；
- 集群与各 OSD 的吞吐、IOPS、延迟和队列；
- recovery、backfill 和 scrub 状态；
- OSD 与物理盘映射；
- public/cluster 网络流量；
- 容量水位及预测耗尽时间。

## 5. 实时刷新策略

“实时”定义为页面自动刷新并显示数据年龄，而不是对所有数据每秒执行一次昂贵查询。

| 数据 | 后端采集周期 | 页面更新周期 | 最大正常数据年龄 |
|---|---:|---:|---:|
| JuiceFS 当前带宽 | 5 秒 | 5 秒 | 10 秒 |
| 客户端 CPU、内存、网络 | 10 秒 | 5 秒 | 20 秒 |
| TiKV/PD 指标 | 15 秒 | 5 秒读取缓存 | 30 秒 |
| Ceph 吞吐、OSD 和 PG | 15 秒 | 5 秒读取缓存 | 30 秒 |
| 主机磁盘 I/O | 10 秒 | 5 秒 | 20 秒 |
| 组件拓扑 | 30 秒 | 10 秒 | 60 秒 |
| 总容量、inode 和文件数 | 30 秒 | 10 秒 | 60 秒 |
| 当前目录 | 进入时查询，停留时 10 秒 | 自动 | 20 秒 |
| SMART/NVMe 健康 | 60～300 秒 | 30 秒 | 10 分钟 |

前端使用 SSE 或 WebSocket 接收变化。每个卡片必须展示采集时间和状态；数据超过两个周期未更新时显示“过期”，不得以 0 或健康状态代替缺失数据。

## 6. 权限模型

### 6.1 角色矩阵

| 能力 | 普通用户 | 管理员 |
|---|---:|---:|
| 登录 | 是 | 是 |
| 浏览授权目录 | 是 | 是 |
| 查看自身或授权目录用量 | 是 | 是 |
| 查看全卷用量 | 否 | 是 |
| 查看实时带宽 | 否 | 是 |
| 查看客户端 | 否 | 是 |
| 查看拓扑 | 否 | 是 |
| 查看 TiKV/PD | 否 | 是 |
| 查看 Ceph | 否 | 是 |
| 查看磁盘 | 否 | 是 |
| 查看全部告警 | 否 | 是 |
| 修改文件或集群 | 否 | 否 |

### 6.2 API 权限

```text
/api/v1/files/**             USER, ADMIN
/api/v1/usage/me             USER, ADMIN
/api/v1/admin/overview       ADMIN
/api/v1/admin/topology       ADMIN
/api/v1/admin/disks          ADMIN
/api/v1/admin/juicefs        ADMIN
/api/v1/admin/tikv           ADMIN
/api/v1/admin/ceph           ADMIN
/api/v1/admin/alerts         ADMIN
```

后端必须执行权限检查。即使普通用户手工构造管理员 API 请求，也必须返回 `403`。

### 6.3 目录隔离

每个普通用户账户绑定：

- 一个或多个授权根目录；
- 对应 UID/GID；
- 是否显示所有者、用户组和权限字段。

Namespace API 必须：

- 使用专用 JuiceFS 只读挂载；
- 标准化路径并拒绝 `..` 越界；
- 防止符号链接跳出授权根目录；
- 不向浏览器暴露 META URL、TiKV 地址或 Ceph 凭据；
- 默认不提供内容下载；
- 记录登录、目录访问和权限拒绝审计日志。

认证优先接入现有 LDAP/AD/OIDC；没有统一身份源时，MVP 使用本地账户，密码采用 Argon2id 哈希。

## 7. 数据源设计

### 7.1 JuiceFS

- 从每个挂载客户端的 Prometheus `/metrics` 采集运行指标；
- 定期运行只读 `juicefs status` 获取卷和会话状态；
- 文件及目录查询只通过专用只读挂载；
- 禁止直接查询或解析 TiKV 内部键值结构。

### 7.2 TiKV/PD

- 采集 PD `:2379/metrics`；
- 采集三节点 TiKV `:20180/metrics`；
- 使用 PD 只读 HTTP API 获取 member、store、region 和热点信息；
- 指标与 API 仅在管理网络开放，普通用户网络不可直接访问。

### 7.3 Ceph

- 在 Quincy 版本启用 mgr Prometheus 模块；
- 创建仅具备 `mon allow r`、`mgr allow r` 的监控 CephX 身份；
- 主要状态和性能数据从 Prometheus 获取；
- 如果确需拓扑补充，可使用 Ceph Dashboard REST API 的只读账户；
- 门户不得保存 Ceph 管理员 keyring。

### 7.4 主机和磁盘

- Node Exporter 提供主机、网络、文件系统和块设备计数器；
- SMART/NVMe Exporter 只执行预定义的只读健康查询；
- 设备用途和服务映射由实时发现结果与版本化静态清单共同维护；
- 页面请求不得直接触发 SSH 或 sudo。

## 8. 用量口径

界面必须同时区分：

1. JuiceFS 逻辑用量：用户文件长度、文件数和 inode；
2. Ceph Pool 用量：JuiceFS 对象在数据池中的存储量；
3. Ceph Raw 用量：包含 EC、BlueStore 和其他开销的物理使用量。

目录用量优先使用 JuiceFS 目录、UID/GID 配额计数。如果当前没有相应统计：

- 当前目录只计算分页结果和浅层信息；
- 递归统计转为低频后台异步任务；
- 禁止每次页面刷新运行全卷 `find`、`du` 或严格递归 `summary`；
- 大目录严格统计必须由管理员显式触发并标记进度；
- 页面标明统计时间和“实时估算/严格统计”口径。

## 9. 告警

首批告警包括：

- JuiceFS 挂载离线或 metrics 过期；
- writeback 长时间未排空；
- cache drop 持续增长；
- PD quorum 异常；
- TiKV Store Down；
- TiKV write stall 或 compaction debt 持续升高；
- Ceph HEALTH_WARN/ERR；
- OSD down/out；
- PG 非 active+clean；
- NVMe 温度、寿命或介质错误异常；
- TiKV/Ceph 盘可用容量低于 20% 和 10%；
- 任一关键采集源超过两个周期未更新。

告警只发送通知，不触发自动重启、配置修改或故障修复。

## 10. 部署与资源

推荐新建独立管理 VM，不部署在 TiKV/Ceph 节点，也不部署在承担性能负载的 157：

- 8 vCPU；
- 16～32 GiB 内存；
- 300～500 GiB 本地磁盘；
- 接入管理网络；
- 能访问 150～152 和所有 JuiceFS 客户端的监控端点；
- 不进入 Ceph 业务数据路径。

Prometheus 初始保留原始指标 30 天；长期趋势可保留 180 天降采样数据。禁止使用文件路径、文件名作为 Prometheus label，避免基数爆炸。

## 11. 对性能测试的保护

- Ceph Prometheus 采集周期不低于 15 秒；
- TiKV 完整 metrics 采集不高于每 15 秒一次；
- 目录查询按需、分页、限并发；
- SMART 健康查询不高频执行；
- 不在页面刷新时运行 SSH、sudo 或递归文件扫描；
- 提供“生产监控”和“性能测试低扰动”两个采集档位；
- 性能测试档可把 TiKV/Ceph采集降至 30 秒，同时继续保留健康告警；
- 上线前测量采集器在各业务节点的 CPU、内存、网络和磁盘开销。

## 12. 实施阶段

| 阶段 | 工作 | 预计时间 | 交付物 |
|---|---|---:|---|
| 0 | 只读盘点、冻结指标与拓扑 | 0.5～1 天 | inventory、指标字典、端口和权限表 |
| 1 | Prometheus/Grafana 和基础采集 | 1～2 天 | 管理员实时监控 MVP |
| 2 | 总览、磁盘和动态拓扑 | 1～2 天 | 管理员完整只读页面 |
| 3 | 统一认证和两级 RBAC | 1～2 天 | 用户、角色、API 鉴权 |
| 4 | 只读文件浏览和用量 | 1～2 天 | 普通用户页面 |
| 5 | 告警、安全和负载验收 | 1～2 天 | 生产验收报告和运维说明 |

可用 MVP 约需 4～6 人日；完成权限、安全、告警和运维闭环的生产版本约需 7～10 人日。

## 13. 验收标准

- 普通用户无法看到或调用任何管理员信息；
- 普通用户无法越过授权目录；
- 门户不存在文件和集群写操作；
- JuiceFS 带宽数据年龄不超过 10 秒；
- Ceph/TiKV 状态数据年龄不超过 30 秒；
- 集群拓扑与实际 member、store、daemon、OSD 一致；
- 每个 OSD 能准确关联物理 NVMe、节点和 DB/WAL；
- 采集失败必须显示“过期”，不能显示为健康或 0；
- 监控对业务节点平均 CPU 影响控制在 1%～2%以内；
- 监控流量低于管理网络容量的 1%；
- 文件浏览不触发全卷递归扫描；
- 所有凭据仅存放在服务端受限配置或凭据存储中；
- 完成普通用户越权、路径穿越、符号链接逃逸和管理员 API 访问测试。

## 14. 首选落地顺序

1. 先完成阶段 0，只读核实真实服务、磁盘、端口和指标；
2. 建立管理员 Prometheus/Grafana 总览；
3. 补充磁盘清单和动态组件拓扑；
4. 完成统一登录及普通用户/管理员 RBAC；
5. 最后接入只读文件浏览和用户用量；
6. 完成安全、低扰动和故障场景验收后再作为正式管理入口。

该顺序先复用现成指标得到大部分管理价值，再处理开发量和安全风险最高的目录浏览与用户隔离。
