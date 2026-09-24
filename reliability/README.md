# JuiceFS + TiKV + Ceph 可靠性验证框架

> 对 JuiceFS+TiKV+Ceph 集群做可靠性验证和可维护性测试。
> 与 `prod-deploy/` 的性能调优并行推进（同一物理集群，时间切片复用）。
> 覆盖故障容错、运维恢复及长时间读写稳定性。

## 设计原则

**用例导向**——每个功能点对应一个可执行的测试用例，有明确的故障注入→检查→恢复流程，输出 TAP 格式结果，通过检查输出判定 PASS/FAIL。

长期稳定性用例不要求注入故障，流程为“固定数据集→持续/周期负载→停写排空→内容校验”。既检查服务是否存活，也检查性能、容量和后台回收能否长期收敛；不能用人工清理后的恢复替代原生自动回收通过。

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

## 长时间读写与空间回收稳定性（LT）

**状态：192.168.11.12 环境已完成 LT-002 的 2 小时筛查；后续写入长测暂因 Ceph 池容量门阻断。** 本轮 LT 只在客户端 `192.168.11.12`、存储节点 `.11/.13/.14` 执行，不操作 157/150～152。普通 `run.sh all` 故意不包含 LT，避免误启动2～72小时负载。

`env/cluster-192.168.11.env`提供本轮客户端`.12`、存储节点`.11/.13/.14`的独立契约。运行前必须显式加载配置，不能把环境参数写回公共默认值：

```bash
set -a
source ./env/cluster-192.168.11.env
set +a
./cases/LT-002-fixed-dataset-overwrite-convergence.sh plan 20260921-120000 randrw256k
```

该配置使用`/data/reliability-lt-results`保存结果、动态OSD集合`0,2,3,4,5,6`，并通过`lib/ceph-readonly-sudo.sh`的命令白名单执行只读Ceph采样。包装器拒绝任何不在白名单内的Ceph命令，不授予测试负载sudo权限。由于该集群为1GbE/HDD，结果只能用于长期正确性、空间收敛和资源漂移判断，不能替代100GbE/NVMe性能签收。

### 为什么必须补测

短时性能测试和故障恢复通过，不代表固定数据集持续覆盖写不会耗尽空间。05-3b曾观察到：16个文件逻辑总量仅64 GiB，却保留约4.83 TiB历史slice引用；定向JuiceFS合并释放约4.76 TiB、约1997万个对象后，每OSD DB空闲从约5 GiB恢复到约18 GiB。单个64 MiB文件低速覆盖也出现约96倍的采样空间放大和自动回收周期，停写后的有限观察窗内仍有大量历史引用。这既不能简单称为“自动回收完全失效”，也不能用一次主动回收成功证明长期风险已解决。这里的DB是Ceph OSD BlueStore/RocksDB DB；TiKV是另一层元数据引擎，两者必须分开记录。既有证据位于 `/mnt/c/SunRise/test/05-3b/`。

### 用例与递进时长

| 编号 | 可执行profile | 主要回答的问题 |
|---|---|---|
| LT-001 | `seqread`、`randread` | 固定只读文件长期运行时，带宽/尾延迟、内存、线程和连接是否漂移 |
| **LT-002（优先）** | `seqwrite16m`、`randwrite256k`、`randrw256k` | 逻辑数据不增长时，slice、对象、TiKV及OSD DB是否形成可接受周期上界 |
| LT-003 | `seqwrite16m`、`randwrite256k`、`randrw256k` | 重复“突发覆盖写→空闲恢复”后，各轮低谷是否持续抬高；默认第3轮后停止访问后半文件，观察冷文件历史是否回收 |
| LT-004 | `compact-randread` | 对精确文件做获批compact时，空间释放、在线读影响和恢复代价；脚本不自动执行全卷GC删除 |

先做2小时安全筛查，再对候选负载累计24小时，最后只对拟交付组合做72小时验证；不是每个参数点都跑72小时。LT-002的256K randrw与16M多流顺序覆盖写必须分RUN记账，并记录累计写入量相对于固定逻辑容量的实际覆盖遍数。至少经历3个可辨识增长—回收周期后，才可初步判断周期上界；2小时只签收安全筛查，不能证明长期上界。

冻结实际文件集、BlockSize、FUSE、jobs/QD、读写比例、写入速率、缓存及删除策略。正式长测段不重建数据集、不增加文件、不截短文件来制造“回收”，也不把不同BS的峰值全速负载与相同业务速率混为一谈。达到停止线即结束，不为凑时长扩大空间或降低写速率后拼接成成功。

### 执行接口

四个入口共用 `lib/long_term.sh`，接口相同。以下示例只用于192.168.11.12客户端上的代码副本；默认 `plan` 只读，`prepare/start/stop` 均需精确ACK：

```bash
# 离线检查（本机执行，不连接集群）
./test-long-term.sh

# 192.168.11.12：先加载上述环境配置，再计划并显式创建独占固定数据集
./cases/LT-002-fixed-dataset-overwrite-convergence.sh plan 20260921-120000 randrw256k
LT_PREPARE_ACK=I_ACK_LT_PREPARE_20260921-120000 \
  ./cases/LT-002-fixed-dataset-overwrite-convergence.sh prepare 20260921-120000 randrw256k

# 192.168.11.12：内置nohup控制器，终端断开后继续；状态查询不会改环境
LT_EXECUTE_ACK=I_ACK_LT_002_20260921-120000 \
  ./cases/LT-002-fixed-dataset-overwrite-convergence.sh start 20260921-120000 randrw256k
./cases/LT-002-fixed-dataset-overwrite-convergence.sh status 20260921-120000 randrw256k

# WSL：完成后持久化；不会删除远端证据或测试数据
./collect-long-term.sh LT-002 20260921-120000
```

每次prepare会把实际入口、公共引擎和分析器冻结到RUN证据中，并在写入数据集前执行一次完整容量门。每小时独立生成fio JSON，60秒采集客户端、JuiceFS、TiKV、Ceph及三台存储节点资源；DB空闲、slow device、Ceph余量、内存、健康/PG任一越过冻结停止线即只停止本RUN fio并保留现场。成功和失败闭环都会生成SHA256清单，可用同一收集脚本持久化；数据集不会自动删除。

默认绝对带宽/P99值只是2小时安全门，不是业务SLO。超过2小时的RUN在prepare前必须显式设置 `LT_SLO_FROZEN=1`，同时给出并冻结 `LT_MIN_READ_BW_MIB`、`LT_MIN_WRITE_BW_MIB` 与 `LT_MAX_P99_US`；未冻结不得形成24/72小时通过结论。

### 必采信息与判定

| 维度 | 实现与判定原则 |
|---|---|
| 用户I/O | 完整fio命令/版本/退出码、分方向字节、每小时带宽与P95/P99、秒级带宽日志最长空洞及错误；不用全程均值掩盖后半程退化 |
| 数据正确性 | 独占文件、每writer独立文件，prepare写入CRC32C校验头，排空后全文件集verify-only；仅inode/大小或fio rc=0不算完整性通过；维护前后另做静止内容校验 |
| JuiceFS/TiKV | 低开销Prometheus连续记录缓存/staging/上传、TiKV引擎容量、pending compaction和事务延迟；写用例排空末点要求staging及上传中请求归零；在声明检查点直接dump精确子目录元数据，并离线区分原始历史slice与当前可见slice |
| Ceph容量 | pool对象数、stored、EC后raw used/max available分别记录；每OSD记录DB free、slow/spillover、compaction、数据盘free/utilization，不只看六盘合计 |
| 主机资源 | 客户端与三台存储节点CPU、RSS/MemAvailable、线程/FD、PSI与iostat；HEALTH_OK不等价于业务无影响 |
| 空间收敛 | 比较相同周期位置的峰/低谷、停写恢复时间、slice放大及DB变化；峰值有界且低谷不持续抬高才支持收敛 |

直接元数据dump只在无fio的声明检查点运行，单线程、低优先级、限定精确子目录；不使用可能经 `Meta.Read` 触发自动合并的 `juicefs info` 作为原生回收采样器。dump本身仍有查询成本，因此不做60秒高频扫描，默认每6个负载窗口及起止点采集。

开跑前冻结业务绝对门槛和相对首窗门槛、每OSD DB/数据盘/内存安全底线、最大slice空间放大、停写排空时间和总时长。任何内容校验错误、I/O错误、不可接受停顿、容量/内存安全线、BLUEFS_SPILLOVER或业务影响均立即停止本任务新负载并保留证据；数据缺失和环境条件不具备标为证据阻断，不与产品故障混记。

### 模式、证据和判定

- **原生模式（LT-001～003）**：不插入手动compact、GC删除、重启、扩容、删卷或重新layout，也不自动重试失败窗口；容量不足或持续退化如实失败。
- **维护模式（LT-004）**：只允许清单中精确文件的单线程 `juicefs compact`，需要额外 `LT_MAINTENANCE_ACK=I_ACK_LT004_COMPACT_<RUN_ID>`；全卷GC删除仍需独立任务书和授权。
- scrub/deep-scrub必须保持正常启用；检测到 `noscrub/nodeep-scrub` 直接拒绝开跑，并在正常巡检发生的时段保留性能证据。
- 写用例在布局阶段写入fio CRC32C校验头，正式覆盖写保持同一校验格式；停写排空后对完整固定文件集 `verify_only`。每个writer使用独立文件，不存在交叠写者歧义。
- 权威结果持久化到 `/mnt/c/SunRise/test/reliability/<run-id>/<case-id>/`，包含冻结配置/脚本、实际命令、每小时fio、60秒监控、完整校验、分析结果和SHA256 manifest。
- 报告分别给出“数据正确性、性能长期稳定、容量长期收敛、维护代价”。原生模式被容量守卫停止后，即使随后维护救回也仍是原生FAIL。

当前测试环境DB/WAL在tmpfs上，因此LT通过不能证明生产断电耐久性；LT不叠加节点重启/掉电。远端证据与数据处置遵守 `prod-deploy/doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`，收集脚本不自动清理任何远端资产。

LT与性能矩阵、故障注入互斥，且本实现不授权全卷GC、删pool、OSD停启、设备写入、全局drop_caches或sudo变更。长期可靠性观察自然积累和维护代价；短时调优则控制比较双方起点，二者不能复用同一轮间清理口径。02阶段R4/R5已有“合并后写性能恢复、独立读数据基本稳定”的证据，而删卷重灌/OSD重启会改变布局并引入明显波动，不能把这些操作统称为清理后随意穿插。

## 相关文档

| 内容 | 位置 |
|------|------|
| 共享库函数签名 | `lib/README.md` |
| 用例清单 + 模板 + FT-002 详细规格 | `cases/README.md` |
| 框架完整设计（高级功能 + 全部用例 + 容错矩阵） | `framework-design.md` |
| 集群架构与部署 | `prod-deploy/README.md` |
| 集群配置 | `prod-deploy/config.sh` |
| 集群重建脚本 | `prod-deploy/scripts/rebuild-osds.sh` |
