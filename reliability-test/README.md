# JuiceFS + TiKV + Ceph 可靠性验证框架

> 对 JuiceFS+TiKV+Ceph 集群做可靠性验证和可维护性测试。
> 与 `prod-deploy/` 的性能调优并行推进（同一物理集群，时间切片复用）。

## 设计原则

**用例导向**——每个功能点对应一个可执行的测试用例，有明确的故障注入→检查→恢复流程，输出 TAP 格式结果，通过检查输出判定 PASS/FAIL。

## 目录结构

```
reliability/
├── README.md                # 本文件
├── framework-design.md     # 框架完整设计（高级功能 + 全部用例目录 + 容错矩阵）
├── run.sh                   # 测试编排器
├── config/env.sh            # 集群连接 + 阈值配置
├── lib/                     # 共享库（详见 lib/README.md）
├── cases/                   # 测试用例（详见 cases/README.md）
└── results/                 # 结果归档（按时间戳）
```

## 运行方式

```bash
# 前置检查
./precheck.sh          # 集群健康 + OSD/MON/TiKV/PD + SSH + JuiceFS mount
./precheck.sh --quick  # 快速版

# 运行用例
./run.sh FT-001        # 单个用例
./run.sh all           # 全部用例（严格串行）
./run.sh FT            # 所有容错类
./run.sh P0            # 所有 P0 优先级
```

结果归档到 `results/<timestamp>/<case-id>/`（含完整日志 + TAP 结果）。

## 配置

```bash
# config/env.sh
source "${SCRIPT_DIR}/../../prod-deploy/config.sh"   # 继承集群配置（IP/SSH/网络）

# 阈值
ASSERT_PG_RECOVER_TIMEOUT=300
ASSERT_IO_LAT_P99_THRESHOLD_US=50000
ASSERT_IO_SUCCESS_RATE_MIN=100
GLOBAL_CASE_TIMEOUT_MULTIPLIER=3
```

> 完整配置项见 `framework-design.md`。

## 相关文档

| 内容 | 位置 |
|------|------|
| 共享库函数签名 | `lib/README.md` |
| 用例清单 + 模板 + FT-002 详细规格 | `cases/README.md` |
| 框架完整设计（高级功能 + 全部用例 + 容错矩阵） | `framework-design.md` |
| 集群架构与部署 | `prod-deploy/README.md` |
| 集群配置 | `prod-deploy/config.sh` |
| 集群重建脚本 | `prod-deploy/scripts/rebuild-osds.sh` |
