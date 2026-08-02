# prod-deploy-h3c — 新华三对比调优工作目录

## 定位

本目录跟踪记录与新华三（H3C）存储方案的对比调优工作。与 `prod-deploy` 在**同一套物理环境**上测试，共享相同的硬件、网络、Ceph/TiKV 集群，但测试方式和对比维度不同。

## 背景：prod-deploy 与 H3C 口径的差异

prod-deploy 的配置基于 **256K randrw, 128 jobs** 的存储规格调优：

```
fio --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1
```

H3C 的 4 项测试口径完全不同——**全顺序、大块、单线程**：

| 维度 | prod-deploy (256K randrw) | H3C (20M/16M seq) |
|------|--------------------------|-------------------|
| I/O 模式 | 随机 | 顺序 |
| 块大小 | 256K | 16M-20M |
| 并发 | 128 jobs × iodepth 128 | 1 job |
| 读放大敏感度 | 高（256K → 16K 半块 = 16×） | 低（顺序对齐，无半块读） |
| 预读 | 有害（2.02× 投机放大） | 有益（顺序预取加速） |
| FUSE dispatch 数 | 256K I/O / 128K dispatch = 2 次 | 20M I/O / 128K dispatch = 160 次 |

**核心矛盾**：当前配置为"小块随机高并发"优化，而 H3C 测试是"大块顺序单线程"——两个方向的优化策略几乎相反。

### H3C 性能目标

| # | 测试项 | H3C 性能 | 命令 |
|---|--------|---------|------|
| 1 | cp 读 | **2 GB/s** | `time cp /mnt/epc/20Gfile /mnt/jfs-cache/` |
| 2 | cp 写 | **2 GB/s** | `time cp /mnt/jfs-cache/20Gfile /mnt/epc/` |
| 3 | fio 顺序读 | **5.4 GB/s** | `fio --bs=20M --rw=read --direct=1 --numjobs=1 --runtime=60` |
| 4 | fio 顺序写 | **3.2 GB/s** | `fio --bs=16M --rw=write --direct=1 --numjobs=1 --runtime=120` |

### 历史调优经验要点

> 来源：`production/` 全系列（1Gbps 测试环境 → 100GbE 生产环境）+ `prod-deploy/`

| 经验 | 对 H3C 的启示 |
|------|---------------|
| block-size 4M→256K 时"顺序读写不降反略升" | 反向 256K→4M 对顺序应不差，风险低 |
| --max-readahead 0 对 seqread -33% | H3C 顺序读必须开预读，且需增大到 8M |
| --max-uploads 150 使 seqwrite +23% | 保持 150 |
| max-fuse-io sweep：随机读 256K 最优、**大块顺序 1M 最优**（mseqwrite 2265→4279 = +89%），1M 是 kernel 5.15 FUSE 硬上限 | H3C 是大块顺序 → 设 **1M**（非随机口径的 256K）；须 mount 后验证 `/sys/fs/fuse/connections/<id>/max_read` 已生效 |
| --buffer-size 1024 配合 max-fuse-io 1M 读写双赢 | 设 1024 |
| --buffer-size 2048 对随机读有害 | 不盲目调大 |
| writeback 报假高带宽（本地 SSD 速度） | 冷态先测，writeback 后续再考虑 |
| v1.4 单客户端反而 -3.3% | 当前 1.3.1+ 版本正确 |
| CephFS 读比 JuiceFS 快 3.6×（无 FUSE 税） | 读是 FUSE 结构性劣势，写 JuiceFS 更优（绕 EC RMW） |
| seqread 单流不满速（NIC 93% 未撞墙） | 与 H3C fio seq_read 直接关联，根因是 FUSE dispatch 串行延迟 |

## 与 prod-deploy 的关系

| 维度 | prod-deploy | prod-deploy-h3c |
|------|-------------|-----------------|
| 环境 | 共享（4 节点 + 157 客户端） | 共享 |
| Ceph/TiKV 集群 | 共享（同一套） | 共享 |
| 部署脚本 | 原版 | 照搬（相同环境） |
| Skills | 9 项全量基线口径 | **4 项 H3C 对比口径**（重写） |
| 测试项 | seqread/seqwrite/mseqread/mseqwrite/layout/randread/randwrite/randrw/rados bench | cp 读 / cp 写 / fio 顺序读 / fio 顺序写 |
| 限速测试 | 含（config-limit.sh + limit-bandwidth.sh） | **不含**（已移除） |
| 挂载点 | /mnt/juicefs | /mnt/epc（`EPC_MOUNT_POINT`） |
| 测试结果 | 独立 | 独立 |

## 测试项

| # | 测试项 | 命令 | 说明 |
|---|--------|------|------|
| 1 | cp 读 | `time cp /mnt/epc/20Gfile /mnt/jfs-cache/` | 文件级顺序读（20G，本地端走 nvme1n1，非 /tmp） |
| 2 | cp 写 | `time cp /mnt/jfs-cache/20Gfile /mnt/epc/` | 文件级顺序写（20G） |
| 3 | fio 顺序读 | `fio --bs=20M --rw=read --direct=1 --numjobs=1 --runtime=60 --time_based --group_reporting` | 块级顺序读（10G） |
| 4 | fio 顺序写 | `fio --bs=16M --rw=write --direct=1 --numjobs=1 --runtime=120 --time_based --group_reporting` | 块级顺序写（10G） |

## 目录结构

```
prod-deploy-h3c/
├── config.sh              # 环境配置（含 EPC_MOUNT_POINT=/mnt/epc）
├── .gitignore
├── scripts/
│   ├── config/tikv/       # TiKV 配置文件
│   ├── deploy-ceph.sh     # Ceph 部署脚本
│   ├── deploy-juicefs.sh  # JuiceFS 部署脚本
│   ├── deploy-tikv.sh     # TiKV 部署脚本
│   ├── rebuild-osds.sh    # OSD 重建脚本
│   ├── prepare-*.sh       # 服务器准备脚本
│   ├── setup-ssh-keys.sh  # SSH 密钥配置
│   ├── test-ceph.sh       # Ceph 测试脚本
│   ├── test-tikv.sh       # TiKV 测试脚本
│   ├── tune-servers.sh    # 服务器调优脚本
│   └── tests/
│       ├── h3c-4item-test.sh   # H3C 4 项测试主脚本
│       └── lib/
│           └── ceph-health-check.sh  # 健康检查库
├── skills/                 # 测试方法论 skill（H3C 口径重写，测试过程遵守）
│   ├── TESTING-GUIDE.md
│   ├── baseline-reproduction-skill.md
│   ├── test-commands-reference.md
│   └── LONG-RUNNING-TEST-SKILL.md
├── pre-skills/             # 前置一次性操作（非测试过程反复做）
│   └── cluster-rebuild-skill.md   # 指针页 → prod-deploy 的 stable-rebuild-skill / cluster-rebuild-skill（重建/恢复口径共用）
├── doc/
│   ├── perf-report/       # 对比测试报告
│   ├── perf-tasks/        # 对比测试任务书
│   ├── perf-analysis/     # 分析文档（01-h3c-tuning-plan.md）
│   └── deploy-log/        # 部署日志
├── report/                # 汇总报告
├── results/               # 测试结果数据
└── debug/                 # 调试信息
```

## 用法

```bash
# 单轮测试
bash scripts/tests/h3c-4item-test.sh

# 3 轮取中位数
bash scripts/tests/h3c-4item-test.sh --repeat 3 --label h3c-baseline

# 自定义标签（如调优对比）
bash scripts/tests/h3c-4item-test.sh --repeat 5 --label h3c-tuning-buf1024
```

## 环境概要

- **节点**：157（客户端/JuiceFS FUSE）、150/151/152（存储节点：Ceph OSD + TiKV）
- **网络**：100GbE 双网卡（public 10.3.1.0/24 + cluster 10.3.2.0/24，MTU 4200）
- **Ceph**：17.2.8 quincy，EC4+2，6 OSD（nvme2n1 + nvme3n1），DB/WAL 在 tmpfs
- **TiKV**：3 节点 3 副本（nvme1n1）
- **JuiceFS**：1.3.1+2025-12-02.e0032b2，direct RADOS（无 RGW）
- **挂载点**：/mnt/epc（`EPC_MOUNT_POINT`，H3C 对比口径）

详细配置见 `config.sh`。
