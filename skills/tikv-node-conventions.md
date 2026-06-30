---
name: tikv-node-conventions
description: Use for ALL tasks involving file operations, cluster operations, or testing on the production environment. Defines the default remote host (tikv-node 192.168.11.12), SSH credentials, and base working directory /home/turboai/production. Use ONLY when operating on the production TiKV/Ceph/JuiceFS environment.
---

# tikv-node 生产环境操作规范

## 默认操作目标

**所有文件相关的操作** 默认在 **tikv-node** 上进行，除非有特殊说明。

| 属性       | 值                    |
| ---------- | --------------------- |
| 主机名     | tikv-node             |
| IP 地址    | 192.168.11.12         |
| 用户名     | turboai               |
| 密码       | TurboAi@303                |
| 基础目录   | /home/turboai/production |

## SSH 连接方式

使用 `sshpass` 进行非交互式 SSH 连接：

```bash
sshpass -p 'TurboAi@303' ssh -o StrictHostKeyChecking=no turboai@192.168.11.12 "<command>"
```

文件传输使用 `scp`：

```bash
sshpass -p 'TurboAi@303' scp -o StrictHostKeyChecking=no <local_file> turboai@192.168.11.12:/home/turboai/production/<path>
```

## 文件操作规范

1. **所有文件路径** 默认相对于 `/home/turboai/production/`（即 tikv-node 上的该目录）。
2. 读写文件、创建目录、编辑脚本等操作都在 tikv-node 上执行。
3. 除非用户明确指定本地路径或其他远程主机，否则一律使用 tikv-node。
4. 集群相关的测试也基于 tikv-node 执行。

## 文档编号规范

当用户提起**文档编号**（如"文档01"、"文档10_1"等）时，默认指向 `/home/turboai/production/doc/perf-analysis/` 目录下对应的 `.md` 文件。

例如：
- "文档01" → `doc/perf-analysis/01-measured-data.md`
- "文档10_1" → `doc/perf-analysis/10_1-v1.4-upgrade-test.md`

该目录是性能分析文档的集中存放点，包含测量数据、瓶颈分析、环境变更记录、优化总结等。

## 集群测试规范

- 测试脚本位于 `/home/turboai/production/tests/` 目录。
- 测试结果存放在 `/home/turboai/production/results/` 目录。
- 部署脚本位于 `/home/turboai/production/` 根目录（如 `deploy-ceph.sh`、`deploy-tikv.sh`、`deploy-juicefs.sh`）。
- 配置文件位于 `/home/turboai/production/config/` 目录。
- 日志文件位于 `/home/turboai/production/log/` 目录。
- 性能调优相关文件位于 `/home/turboai/production/tun/` 目录。

## 目录结构概览

```
/home/turboai/production/
├── README.md                  # 项目说明
├── deploy-ceph.sh             # Ceph 部署脚本
├── deploy-tikv.sh             # TiKV 部署脚本
├── deploy-juicefs.sh          # JuiceFS 部署脚本
├── deploy-lb.sh               # 负载均衡部署脚本
├── test-ceph.sh               # Ceph 测试脚本
├── test-tikv.sh               # TiKV 测试脚本
├── config.sh                  # 环境配置脚本
├── prepare-servers.sh         # 服务器准备脚本
├── prepare-all-servers.sh     # 批量服务器准备脚本
├── setup-ssh-keys.sh          # SSH 密钥配置脚本
├── tune-servers.sh            # 系统调优脚本
├── config/                    # 配置文件目录
│   ├── ceph/                  # Ceph 配置
│   └── tikv/                  # TiKV 配置
├── doc/                       # 文档目录
├── downloads/                 # 下载文件目录
├── log/                       # 日志目录
├── results/                   # 测试结果目录
├── skills/                    # Skill 文件目录
├── tests/                     # 测试脚本目录
│   └── lib/                   # 测试库（如健康检查库）
└── tun/                       # 调优配置目录
```

## 执行命令的注意事项

1. 使用 `sshpass` 时始终添加 `-o StrictHostKeyChecking=no` 避免主机密钥确认提示。
2. 远程命令中的路径应使用绝对路径（如 `/home/turboai/production/...`）。
3. 需要交互式操作的命令应避免直接通过 SSH 执行，改用非交互式替代方案。
4. 长时间运行的命令应加 `timeout` 或使用 `nohup` 后台运行。
