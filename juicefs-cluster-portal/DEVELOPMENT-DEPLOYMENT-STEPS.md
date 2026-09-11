# JuiceFS 集群只读管理门户开发部署步骤

> 目标节点：`10.20.1.152（ceph-node3）`
> 约束：只读管理面；数据和指标不落入 TiKV、Ceph OSD、DB/WAL 或 JuiceFS 业务路径
> 当前范围：管理员监控MVP及T09“三级递归总量完整、每个目录top 100大项”均已部署；Portal只能读取SQLite快照，完整文件明细浏览仍延期。

## 1. 阶段0：冻结边界与只读盘点

1. 记录150～152及157的主机名、IP、CPU、内存、系统盘和时区。
2. 记录PD成员及Leader、TiKV Store、Ceph MON/MGR/OSD、OSD到物理盘的映射。
3. 记录JuiceFS卷、客户端、挂载点、版本和metrics端点。
4. 核对152系统盘可用空间，并确认目标目录不位于：
   - `/mnt/jfs-tikv`；
   - `/mnt/dbwal`；
   - `nvme1n1/nvme2n1/nvme3n1`；
   - JuiceFS或Ceph Pool。
5. 冻结第一版指标白名单、端口、刷新周期和页面字段。
6. 输出`inventory/`、`topology.json`、`metrics-catalog.md`和端口表。

本阶段只读，不安装软件、不修改防火墙、不启用Ceph模块。

## 2. 阶段1：本地开发骨架

在本目录建立：

```text
juicefs-cluster-portal/
├── api/                    # Go Portal API
├── web/                    # Vue/React UI
├── deploy/
│   ├── systemd/
│   ├── nginx/
│   ├── prometheus/
│   └── grafana/
├── dashboards/             # 版本化Grafana dashboard
├── configs/                # 无凭据模板
├── fixtures/               # 脱敏只读样本
├── tests/
├── inventory/
└── docs/
```

开发顺序：

1. 定义普通用户和管理员的API权限矩阵。
2. 定义Prometheus、PD、Ceph和Namespace适配器接口。
3. 用脱敏fixture开发，不直接在集群上反复调试。
4. 先实现管理员总览、节点和磁盘静态页面。
5. 再实现动态拓扑、历史图表和告警。
6. 最后实现普通用户目录浏览及用量页面。
7. 完成单元测试、路径越界测试和权限测试后才上传152。

## 3. 阶段2：152基础运行环境

在152系统盘建立专用目录。T04决定采用分段部署：T05先只启动loopback基础服务；外部HTTPS入口推迟到T08认证完成时开放。

```text
/opt/juicefs-portal/              # 程序与只读静态资源
/etc/juicefs-portal/              # 配置；凭据权限0600
/var/lib/juicefs-portal/
├── prometheus/                   # TSDB，按30 GiB封顶
├── grafana/
└── portal/                       # 用户/RBAC配置
/var/log/juicefs-portal/          # 有轮转和容量上限
```

创建专用系统账户`jfsportal`，不加入sudo组，不授予业务目录写权限。

建议内部监听：

| 服务 | 地址 | 外部是否直接可见 |
|---|---|---|
| Portal API | `127.0.0.1:8080` | 否 |
| Grafana | `127.0.0.1:3000` | 否 |
| Prometheus | `127.0.0.1:9090` | 否 |

T05～T08不安装Nginx；T08只在152管理IP开放TLS 8443，systemd除loopback和152自身健康验收外只允许157外部来源，用户经现有`thailand` SSH隧道访问。可信证书与更广管理网入口留到T11正式交付前单独审批。

systemd/cgroup上限：

| 服务 | CPUQuota | MemoryMax |
|---|---:|---:|
| Prometheus | 200% | 6 GiB |
| Grafana | 50% | 1 GiB |
| Portal API/UI | 50% | 1 GiB |
| Nginx | 20% | 256 MiB |

所有服务配置低I/O权重、`Nice=10`、日志轮转和自动重启；Prometheus同时设置`14d`与`30GB`保留上限，先达到者生效。

## 4. 阶段3：指标接入

### 4.1 JuiceFS

1. 盘点每个生产挂载现有metrics监听地址。
2. 已能从管理网访问时由Prometheus直接抓取。
3. 仅监听localhost时，优先部署轻量本地转发/remote-write agent；禁止为了监控直接重挂业务卷。
4. 标签至少包含client、hostname、mountpoint、volume和version。
5. 先接入逻辑读写带宽、IOPS、延迟、meta、GET/PUT、cache和writeback指标。

### 4.2 PD/TiKV

1. 接入PD `:2379/metrics`和只读API。
2. 接入三节点TiKV `:20180/metrics`。
3. 初始抓取周期15～30秒。
4. 只保留任务需要的指标系列，避免无边界TSDB增长。
5. 管理门户不保存或展示META URL中的敏感信息。

### 4.3 Ceph

1. 启用Quincy mgr Prometheus模块，端口仅允许管理网访问。
2. 创建`mon allow r`、`mgr allow r`的专用只读CephX身份。
3. 抓取周期固定15～30秒，不低于Ceph建议值。
4. 首版不启用完整Ceph Dashboard，减少资源和权限面。
5. 接入health、capacity、pool、OSD、PG、recovery、scrub和延迟指标。

### 4.4 主机与磁盘

1. 150～152和157部署受限Node Exporter。
2. 150～152部署只读SMART/NVMe采集，周期5分钟。
3. 组合Ceph占用指标、系统块设备指标和静态清单，生成OSD到NVMe映射。
4. 页面请求不允许触发SSH、sudo或smartctl命令。

## 5. 阶段4：管理员MVP

1. 建立统一总览：卷、客户端、PD/TiKV、Ceph、容量和告警。
2. 建立三类独立带宽：
   - JuiceFS客户端逻辑带宽；
   - Ceph后端物理带宽；
   - 节点网卡带宽。
3. 建立节点和磁盘页，显示磁盘用途、温度、寿命、吞吐和延迟。
4. 建立动态拓扑页，显示client→PD/TiKV及client→Ceph→OSD→disk关系。
5. 每个字段显示采集时间；超过两个周期即标记“过期”。
6. 管理员MVP签收后再进入文件浏览开发。

## 6. 阶段5：认证和RBAC

1. 有LDAP/AD/OIDC时优先接入统一身份源；否则先使用本地账户。
2. 建立`USER`和`ADMIN`两个角色。
3. 普通用户后端API只开放文件和个人/授权路径用量。
4. 管理员开放所有只读页面。
5. Grafana和Prometheus不直接对用户开放，由门户/Nginx代理。
6. 完成前端隐藏、后端403、直接构造请求和会话过期测试。

## 7. 阶段6：只读文件浏览和用量

> 状态：`IN_PROGRESS`。当前只实现授权根三级递归用量快照；文件明细浏览、内容预览和下载继续延期。

1. 在152建立专用JuiceFS控制挂载，不复用业务挂载；因`summary`控制请求需要打开`.control`，内核标志为rw，但禁止`allow_other/allow_root`并使用JuiceFS参数`--atime-mode noatime`。
2. 禁止内容预览、下载和全部写操作。
3. 每个用户绑定允许访问的根路径及UID/GID。
4. API执行路径规范化、`..`拒绝、符号链接逃逸防护和分页。
5. 每页最多200项、全局最多4个并发目录请求、单用户每秒最多5次。
6. 当前目录缓存5～10秒，只刷新打开目录。
7. 用量读取JuiceFS DirStats：总量覆盖全部后代，每个目录仅展示top 100直接子项和一个其余项聚合，不承诺完整文件清单。
8. 禁止页面刷新触发递归`find`、`du`或严格`summary`。

## 8. 阶段7：低扰动和安全验收

1. 对比监控关闭与开启时的空载CPU、内存、磁盘和网络。
2. 运行一个短时固定负载A/B，确认带宽影响小于1%、CV没有材料增加。
3. 验证Prometheus空间达到30GB后能自动回收。
4. 验证152成为PD Leader时管理服务仍受资源上限约束。
5. 验证Portal或Prometheus停止不影响JuiceFS、TiKV/PD和Ceph。
6. 验证节点、metrics或API失联后页面显示“过期”，不显示0或健康。
7. 完成目录越权、路径穿越、符号链接逃逸、API越权和凭据泄露检查。
8. 确认服务没有集群或文件写接口。

## 9. 阶段8：上线与运维

1. 先仅向管理员开放24小时观察。
2. 观察152系统CPU、system disk latency、TiKV/OSD延迟和metrics开销。
3. 无异常后开放普通用户文件和用量页面。
4. 每日把Grafana配置、门户账户/RBAC和告警规则备份到另一节点系统盘。
5. 单节点故障时允许门户不可用，但集群服务必须不受影响。
6. 性能测试期间使用固定低扰动档：TiKV/Ceph 30秒采集、暂停目录浏览；所有A/B臂保持同一监控状态。

## 10. 需要sudo审批的实施动作

实际部署前单独列出完整命令审批，预计仅包括：

- 在152创建系统账户、目录和systemd服务；
- 安装或放置Prometheus、Grafana、Nginx和exporter；
- 配置管理网防火墙端口；
- 启用Ceph mgr Prometheus模块并创建只读CephX身份；
- 在150～152/157安装和启动受限exporter；
- 创建152上的JuiceFS专用目录统计控制挂载服务。

任何磁盘格式化、LVM、loop、Ceph Pool修改、OSD操作、TiKV重启、生产挂载重挂和数据删除都不属于本方案授权范围。
