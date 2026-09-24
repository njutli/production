# JuiceFS Cluster Portal

这是部署在 `10.20.1.152` 的 JuiceFS 集群只读管理门户。当前已接入 JuiceFS、PD/TiKV、Ceph、主机、NVMe、客户端和三级目录用量，并提供 HTTPS、ADMIN/USER 权限隔离、实时状态、数据过期提示及带宽趋势曲线。

平台按三个大阶段推进：第一阶段只读监控已完成；第二阶段用户管理与配额管理总开发计划已编写，待实施；第三阶段面向客户提供的主服务节点开发快速部署能力。总体安排见[总体开发计划](DEVELOPMENT-ROADMAP.md)。

系统功能、架构、安全边界、刷新周期、访问方式和已知限制统一见：

- [当前阶段系统功能说明](stages/01-readonly-monitoring/CURRENT-STAGE-SYSTEM-OVERVIEW-20260914.md)
- [平台架构与子模块流程图](docs/PORTAL-ARCHITECTURE-AND-FLOWS-20260922.md)
- [当前部署验收摘要](stages/01-readonly-monitoring/inventory/CURRENT-DEPLOYMENT-ACCEPTANCE-SUMMARY-20260914.md)
- [开发部署步骤](docs/DEVELOPMENT-DEPLOYMENT-STEPS.md)
- [当前任务状态](TODO.md)
- [功能专题与开发计划](stages/02-user-quota/features/README.md)

## 快速访问

```bash
ssh -F /home/lilingfeng/.ssh/config -N -T \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:8443:10.20.1.152:8443 thailand
```

打开 `https://localhost:8443/`。当前使用自签名证书；账户凭据只保存在 152 的 root-only 文件中，不进入代码仓库。

## 本地验证

```bash
make test
make run
```

本地 fixture 仅用于开发演示，打开 `http://127.0.0.1:8080`。

## 按开发阶段查阅

| 阶段入口 | 内容 | 状态 |
|---|---|---|
| [01：只读监控](stages/01-readonly-monitoring/README.md) | 功能介绍、范围与指标设计、部署验收 | 已完成 |
| [02：用户与配额管理](stages/02-user-quota/README.md) | 总开发计划、LDAP路线A、配额专题及历史备选 | 计划已编写，待S2-0 |
| [03：客户现场快速部署](stages/03-deployment/README.md) | 部署方案、D0～D6开发计划及验收安排 | 草案已编写，待开发 |

```text
juicefs-cluster-portal/
├── README.md                    项目入口
├── DEVELOPMENT-ROADMAP.md       三阶段总体计划
├── TODO.md                      当前状态与待办
├── stages/
│   ├── 01-readonly-monitoring/  第一阶段：功能说明、docs、inventory
│   ├── 02-user-quota/           第二阶段：总开发计划及features专题材料
│   └── 03-deployment/           第三阶段：部署方案与开发计划
├── docs/                       跨阶段开发与现有环境更新说明
├── api/                        共享后端与接口定义
├── web/                        共享前端
├── configs/                    配置样例
├── dashboards/                 监控面板定义
├── deploy/                     部署脚本与服务模板
├── fixtures/                   本地演示数据
├── tests/                      离线检查
└── Makefile                    统一开发入口
```

阶段目录只归类文档，不复制或拆分应用代码。各阶段继续复用同一套代码、配置和部署资产；本文中的本地命令均在Portal根目录执行。
