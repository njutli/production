# 框架完整设计（按阶段逐步合入 README）

> 本文件记录 reliability 框架的完整设计，包括安全机制、高级功能、全部用例目录、容错矩阵分析等。
> README 中只保留了 P0 用例和最小框架。本文件内容随实现进度逐步合入 README。
>
> 合入原则：某个功能实现完成并验证后，将对应章节从本文件移入 README。

---

## 一、框架高级功能

### 1.5 框架级前置检查（pre-flight gate）

跑任何用例前，运行 `precheck.sh` 做全局环境验证，**全部通过才允许执行**。
所有检查经 `_run`（三层 SSH 跳板）路由到对应节点执行，编排机（WSL）上不假设存在任何集群 CLI：

| 检查项 | 命令（执行位置） | 预期 |
|--------|------|------|
| 集群健康 | `_run ${CEPH_PRIMARY} "sudo cephadm shell -- ceph health"` | HEALTH_OK |
| 所有 OSD | 同上 `ceph osd tree` | 6/6 全部 up + in |
| MON quorum | 同上 `ceph quorum_status` | 3/3 成员 |
| PD 健康 | `_run <tikv节点> "curl -s http://127.0.0.1:2379/pd/api/v1/health"` | 3 PD 均 `"health":true` |
| TiKV store | 同上 `/pd/api/v1/stores` | 3 store 均 Up |
| JuiceFS 挂载 | `ssh_to_client "juicefs status ${JUICEFS_METADATA_URL}"` + `mountpoint` | mount 正常 |
| 节点 SSH 可达 | `_run <ip> true` | 全部可达 |
| 必要工具 | 远端检查：`which fio`（157）、`which curl jq`（slave） | 全部存在 |
| 时钟同步 | 各节点 `timedatectl` + 与编排机时钟比对 | NTP 同步，偏差 < 1s |
| 残留故障 | 各节点：台账目录为空、无 netem qdisc、无遗留 iptables DROP、存储服务全部 active | 无残留 |
| WekaIO 健康 | `ssh_to_client "weka status"` | 正常；异常则禁止注入 |
| 网络口径 | `ceph config get mon public_network` | 记录当前口径 |

```bash
./precheck.sh          # 跑全部检查，输出 TAP 格式
./precheck.sh --quick  # 只查 ceph health + OSD up + 台账为空
```

### 1.6 用例间健康门禁

上一个用例执行完（无论 PASS/FAIL），切到下一个用例前，框架自动执行快速健康检查（`precheck.sh --quick`）。非 OK → 暂停：

- 交互模式（默认）：输出告警并等待人工确认（`read -r`）
- 非交互模式（`--non-interactive`，CI 场景）：门禁失败直接中止、非零退出码退出

### 1.7 recover() 幂等性

recover() 必须幂等——即使故障未成功注入，recover() 也不得有副作用：

```bash
recover() {
    # ✅ start 对已 up 的 OSD 无副作用
    start_osd "$TARGET_OSD"
    # ❌ umount tmpfs 再 mount 对未卸载的目录有副作用
}
```

不可逆故障（如 `simulate_tmpfs_loss`）的 recover() 跳过恢复，输出告警。

### 1.8 全局用例超时

每个用例声明 `EXPECTED_DURATION`（秒），框架设定超时（`EXPECTED_DURATION × GLOBAL_CASE_TIMEOUT_MULTIPLIER`）：
```bash
timeout "$(( EXPECTED_DURATION * GLOBAL_CASE_TIMEOUT_MULTIPLIER ))" bash "${case_script}" || {
    echo "# ⚑ CASE_TIMEOUT: 超时，强制 teardown"
    teardown
    return 1
}
```

### 1.9 信号处理（Ctrl+C 安全退出）

```bash
trap 'teardown; exit 130' SIGINT SIGTERM
```
即使 trap 失效（编排机断电/断网），目标节点上的 dead-man switch（§1.12）会兜底自动回滚。

### 1.10 重试机制

```bash
./run.sh FT-001 --retry 2     # 失败后最多重试 2 次
./run.sh all --retry 1        # 每个 FAIL 用例重试 1 次
```
仅对 FAIL 用例重跑（SKIP 和 PASS 不重试）。

### 1.11 dry-run 模式

不注入故障，仅校验脚本语法（`bash -n`）+ 环境连通性 + 断言参数格式：
```bash
./run.sh FT-001 --dry-run
./run.sh all --dry-run
```

### 1.12 编排器故障自保（dead-man switch + 状态台账）★

编排链路为 WSL → HK ECS → 157 → slaves 三层 SSH（走公网跳板）。若编排机在 inject() 之后、recover() 之前断网，集群将永久停留在故障态。

**① dead-man switch**：每次注入前，先在目标节点预置 systemd transient timer 自动回滚，recover() 成功后注销。编排机失联的最坏结果 = 集群 `DEADMAN_TTL_S`（默认 600s）后自愈：

```bash
inject_with_deadman() {
    local node=$1; shift
    local revert_cmd=$1; shift
    _run "${node}" "sudo systemd-run --unit=reliability-deadman-${TEST_ID} \
        --on-active=${DEADMAN_TTL_S} ${revert_cmd}"
    ledger_add "${TEST_ID}" "${node}" "${revert_cmd}"
    "$@"
}

cancel_deadman() {
    local node=$1
    _run "${node}" "sudo systemctl stop reliability-deadman-${TEST_ID}.timer" 2>/dev/null || true
    ledger_remove "${TEST_ID}"
}
```

**② 状态台账**：每个被注入节点落盘 `/var/tmp/reliability-ledger/<case-id>.env`，记录注入对象、回滚命令、时间戳。驱动 `precheck.sh`（台账非空 → FAIL）和 `run.sh --cleanup-all`（按台账逐节点回滚）。

**③ 长用例**：超过 10min 的用例（OPS 类）必须在 tmux/screen 中启动。

### 1.13 故障注入安全边界（完整版）★

#### 1.13.1 注入目标分层

| 层 | 目标节点 | 允许的注入手段 | 典型用例 |
|----|---------|--------------|---------|
| **存储节点（150-152）** | 150/151/152 | 进程级（stop/kill OSD/MON/TiKV/PD）、iptables 端口级 DROP | FT-001~009, OPS-001 |
| **存储节点网络** | 150/151/152 的 eno12409 | `tc netem`（仅限速口径下） | — |
| **客户端（157）** | 157 | **仅** kill JuiceFS FUSE 进程 | FT-010 |

#### 1.13.2 禁止操作（全局红线）

| 禁止操作 | 原因 |
|---------|------|
| `iptables` on 10.20.1.0/24 | 管理网承载 SSH 生命线 |
| `iptables` 整网段 DROP | 仅允许端口级 + 指定对端 IP |

> 故障注入原语（stop_osd / stop_tikv / crash_node_storage 等）按服务名精确操作。
> 存储节点 100GbE 上允许 `tc netem`（模拟 Ceph 网络降级，per-node 粒度，影响该节点 2 个 OSD 的 public/cluster 流量）。

#### 1.13.3 net_partition() 内置 guard

```bash
net_partition() {
    local src=$1 dst=$2
    case "${src}|${dst}" in
        *10.20.1.*)
            echo "not ok - net_partition: 拒绝操作管理网段 10.20.1.0/24"
            return 1 ;;
    esac
    # 仅按端口 + 对端 IP 安装规则
}
```

#### 1.13.4 WekaIO 护栏

precheck 检查 WekaIO 健康。check_during 阶段验证 WekaIO 未受影响——若波及则立即 FAIL + forensics 取证。

### 1.14 数据完整性验证（框架级钩子）★

可用性断言不能证明数据**正确**。degraded EC 写 + recovery 期间的静默损坏，必须靠显式校验捕获：

```bash
create_verify_dataset [size_gib]   # setup 中：fio --verify=sha256 写入校验数据集
verify_dataset                      # check_after 中：fio --verify_only 读回，0 mismatch 才算 ok
integrity_check                    # 写负载用例追加：PG scrub 0 inconsistent + juicefs fsck + gc 审计
```

### 1.15 执行互斥（与性能调优时间切片）

reliability 与 prod-deploy 性能测试共用同一物理集群，靠时间切片隔离。`run.sh` 启动时在 157 落锁文件 `/tmp/reliability.lock`：
- 锁已存在 → 拒绝启动
- 套件结束 / `--cleanup-all` → 自动释放
- 性能测试脚本侧遵守同一约定

### 1.16 判定规则（完整版）

- 所有断言 `ok` → **PASS**
- 任一 `not ok` → **FAIL**，但继续执行（采集完整信息）
- `recover()` 始终执行
- **SKIP**：前置条件不满足（网络口径不符、上游用例 FAIL）时，输出 `ok 0 # SKIP <原因>`，不参与重试
- **依赖传递**：`DEPENDS_ON` 声明的上游 FAIL/SKIP → 下游默认 SKIP；可声明 `RUN_EVEN_IF_DEP_FAILED=1` 覆盖

### 1.17 JSONL 双写

每条断言同时落 TAP 行和一行 JSONL 到 `result.jsonl`（CI 消费）：
```json
{"case":"FT-001","seq":5,"result":"ok","desc":"P99 < 50ms","actual":32,"threshold":50,"ts":1752774010}
```

### 1.18 FAIL 自动取证（forensics.sh）

首个 `not ok` 时由 assert.sh 触发一次（幂等），归档到 `results/<ts>/<case>/forensics/`：
```bash
collect_forensics() {
    # ceph: status / osd tree / pg dump / dump_ops_in_flight / ceph report
    # tikv/pd: tikv.log / pd.log 尾部 500 行
    # juicefs: 客户端日志尾部 + juicefs status
    # 系统: dmesg -T 尾部、journalctl --since "case start"
}
```

---

## 二、完整用例目录

> P0 已在 README 中。P1/P2/P3 在此，按批次合入。

### FT — 故障容错验证（完整）

| ID | 名称 | 故障注入 | 关键断言 | 优先级 | 时长 |
|----|------|---------|---------|:---:|:---:|
| FT-001 | single-osd-down | 停 1 OSD | fault 期间 I/O 100% 不中断、PG degraded、恢复后 PG clean + 恢复时间 < 300s | **P0** | 6min |
| FT-002 | disk-fault | dmsetup suspend 挂起数据 dm 设备 | I/O 不中断（EC 容忍）、PG degraded、移除故障后数据完整 | **P0** | 8min |
| FT-003 | single-node-crash | crash_node_storage（2 OSD + 1 MON + 1 TiKV + 1 PD） | 数据面+元数据面同时故障转移、I/O stall < 35s | **P0** | 10min |
| FT-004 | tikv-single-down | 停 1 TiKV | 元数据操作可完成、Raft leader 切换 | **P0** | 6min |
| FT-005 | tikv-two-down | 停 2 TiKV | 元数据操作阻塞、恢复后无感继续 | **P0** | 5min |
| FT-006 | single-mon-down | 停 1 MON（仍保持 quorum） | 集群可操作 | P1 | 4min |
| FT-007 | two-mon-down | 停 2 MON（丢失 quorum） | 集群不可操作、已有 I/O 可继续 | P1 | 4min |
| FT-008 | single-pd-down | 停 1 PD | TiKV 读写不受影响、PD leader 切换 | P1 | 5min |
| FT-009 | two-pd-down | 停 2 PD（丢 quorum） | PD 管理面冻结、TiKV 仍可服务（本地 cache）、新元数据操作可发起 | P1 | 5min |
| FT-010 | juicefs-fuse-crash | kill FUSE 进程 | mount 不可用、重启后数据完整 | P1 | 3min |

### HA — 自动恢复验证

（已合并入 FT-001，FT-001 的 I/O 全程运行覆盖 fault + recovery 两个阶段）

### MON — 监控告警验证

（已删除——Ceph/JuiceFS 自带成熟的故障检测，无需重复验证厂商核心功能。

### OPS — 运维操作验证

| ID | 名称 | 操作 | 关键断言 | 优先级 | 时长 |
|----|------|------|---------|:---:|:---:|
| OPS-001 | disk-replacement | 磁盘故障→tmpfs 备用盘替代→对另一盘注入故障验证 | 备用盘加入集群并生效、I/O 无错误、fsck 无损坏 | **P0** | ~20min* |
| OPS-002 | rolling-node-reboot | 逐节点 reboot（含单节点 tmpfs 丢失重建验证） | tmpfs 丢失=OSD 重建、逐节点可重复 | P1 | ~3×单节点* |

> \* 重建类时长与预置数据量强相关，统一灌入 `PRELOAD_GIB=500` 校准。

### DG — 性能退化量化

> FT 验证"是否中断"，DG 验证"退化多少"。基线有效性双保险：现场采基线 + 断言基线 ≥ 历史参考 × 0.8。

| ID | 名称 | 故障注入 | 关键断言 | 优先级 | 时长 |
|----|------|---------|---------|:---:|:---:|
| DG-001 | osd-down-throughput-degradation | 停 1 OSD | fault + recovery 全程吞吐 ≥ 基线×70%、P99 < 基线×3 | P1 | 8min |
| DG-002 | tikv-down-metadata-latency | 停 1 TiKV | 元数据 P99 < 基线 × 3 | P1 | 7min |

---

## 三、FT-002 详细规格

### 3.1 架构上下文

每个 slave 节点 co-located 4 类服务，宕机时全部同时失效：

| 组件 | 数量 | 宕机时影响 |
|------|------|-----------|
| Ceph OSD | 2 | PG degraded（EC 容错极限：6→4，k=4 刚好可读） |
| Ceph MON | 1 | quorum 3→2（仍可操作，冗余度为零） |
| TiKV | 1 | 若 leader 在此 → Raft 选举，元数据 stall ~5-10s |
| PD | 1 | 若 PD leader 在此 → PD 选举，TiKV 有本地缓存可续读 |

**联合效应**：数据 I/O 和元数据 I/O 同时受影响。FT-001 只影响数据面，FT-007 只影响元数据面——FT-002 验证两者同时故障转移时是否存在交互放大。

### 3.2 关键指标采集

| 指标 | 采集方法 | 用途 |
|------|---------|------|
| T_detect_tikv | monitoring 时序：TiKV leader 首次变更 − T0 | 元数据面检测延迟 |
| T_detect_ceph | monitoring 时序：OSD count 6→4 − T0 | 数据面检测延迟 |
| T_recover_io | I/O BW 恢复至基线 50% − T0 | 客户端 I/O 恢复时间 |
| T_full_recover | HEALTH_OK 恢复 − RECOVER_TIME | 集群完全恢复时间 |
| Max P99 during fault | fio bw_log 逐秒 P99 最大值 | 故障期间最差延迟 |
| I/O stall duration | I/O BW = 0 的持续秒数 | 客户端不可用窗口 |

### 3.3 与相关用例的关系

| 用例 | 验证什么 | 与 FT-002 的关系 |
|------|---------|-----------------|
| FT-001 | OSD 进程停止 → 仅数据面 | FT-003 的子集 |
| FT-004 | 单 TiKV down → 仅元数据面 | FT-003 的子集 |
| FT-003 | 节点宕机 → 数据+元数据同时 | 联合验证交互放大 |
| FT-005 | 2 TiKV down → 元数据面超容错 | FT-003 是容错内，FT-005 是容错外 |
| OPS-002 | 逐节点 reboot | 节点重启（tmpfs 丢失=OSD 重建），比 FT-003 更严重 |
| FT-001 | OSD 停止→恢复 | I/O 全程量化（fault + recovery） |
| FT-004 | 单 TiKV down → 仅元数据面 | FT-003 的子集 |

---

## 四、架构容错矩阵

### 4.1 Ceph EC 4+2

```
k=4 m=2, failure_domain=osd, 6 OSD across 3 nodes

故障 OSD 数 | 数据可读 | 数据可写 | PG 状态            | HEALTH
-----------|---------|---------|--------------------|--------
  0        | ✅      | ✅      | active+clean       | OK
  1        | ✅      | ✅      | active+degraded    | WARN
  2        | ✅      | ✅(受限)| active+degraded    | WARN
  3        | ❌(部分)| ❌      | incomplete/degraded | ERR
```

> **零 spare 重建能力**：6 OSD 恰好满足 EC 4+2 的 6 chunk 放置，每个 PG 占满全部 OSD，CRUSH 没有第 7 个 OSD 可重映射。任何 OSD 永久丢失 → PG 永久 degraded 直到人工补盘。本集群对永久盘故障无自愈能力（可用性不受影响，冗余度不恢复）——OPS-001 验证换盘重建。

### 4.2 TiKV Raft 3

```
3 TiKV, max-replicas=3, Raft majority=2

故障 TiKV 数 | 元数据可读 | 元数据可写 | 说明
-------------|-----------|-----------|-----
  0          | ✅        | ✅        | 正常
  1          | ✅        | ✅        | Raft 自动切换 leader
  2          | ❌        | ❌        | 无 majority，JuiceFS 元数据不可用
```

### 4.2a Ceph MON Quorum

```
3 MON, quorum=2

故障 MON 数 | 集群可操作 | 已有 I/O | 说明
-----------|-----------|---------|-----
  0        | ✅        | ✅      | 正常
  1        | ✅        | ✅      | 仍有 quorum
  2        | ❌        | ✅      | 丢失 quorum，管理面不可操作，已有 OSD I/O 继续
```

### 4.2b PD

```
3 PD, Raft quorum=2

故障 PD 数 | TiKV 读写 | PD 操作 | 说明
-----------|----------|--------|-----
  0        | ✅       | ✅     | 正常
  1        | ✅       | ✅     | PD leader 自动切换
  2        | ✅(缓存) | ❌     | quorum 丢失，TiKV 缓存续读，region split 失败
```

### 4.3 联合容错

| 场景 | Ceph | TiKV | 数据面 | 元数据面 | 客户端 |
|------|------|------|--------|---------|--------|
| 1 OSD down | 1 down | 无影响 | ✅ | ✅ | 无感知 |
| 1 节点 down | 2 down | 1 down | ✅ 极限容忍 | ✅ Raft 容忍 | 短暂抖动 |
| 1 节点 + 1 节点 1 OSD | 3 down | 1 down | ❌ 超出 EC | ✅ | 数据不可读 |
| 2 节点 down | 4 down | 2 down | ❌ | ❌ | 完全不可用 |

**宕机检测时间线**：

| 组件 | 检测机制 | 预期延迟 | JuiceFS 影响 |
|------|---------|---------|-------------|
| PD | Raft election-timeout=3s | ~5s | PD leader 切换 |
| TiKV | Raft election_timeout≈10s | ~10s | 元数据操作先恢复 |
| Ceph OSD | osd_heartbeat_grace≈20s | ~20-30s | 数据 I/O 后恢复 |
| Ceph MON | Paxos lease 超时 | ~15-30s | quorum 收缩 3→2 |

> 元数据恢复（~10s）快于数据恢复（~30s）。I/O stall 窗口 ≈ 30s，FT-002 断言 P99 < 35s 的依据。

### 4.4 tmpfs 风险

| 维度 | 测试环境 | 生产要求 |
|------|---------|---------|
| DB/WAL 介质 | tmpfs（断电丢） | 独立物理 NVMe |
| 断电后果 | OSD 无法启动 | OSD 自动恢复 |
| 恢复方式 | 手动重建 OSD | 无需干预 |

> 节点重启导致 tmpfs 丢失=每节点 2 OSD 走重建路径（OPS-002）。

---

## 五、完整 fault_inject.sh 原语

```bash
# 框架封装（用例入口）
inject_with_deadman <node> <revert_cmd> <inject_cmd...>   # dead-man + 台账 + 注入
cancel_deadman <node>                                     # 注销定时器 + 台账
ledger_add / ledger_remove / ledger_list / ledger_check_empty

# 慢盘注入
throttle_osd_io <id> <read_bps> <write_bps>   # cgroup v2 io.max（可逆）
unthrottle_osd_io <id>

# 网络
net_degrade <delay_ms> <loss_pct>             # tc netem，仅 eno12409
net_degrade_clear

# 时钟
inject_clock_skew <ip> <offset_ms>   # chronyd 偏移（可逆）
clear_clock_skew <ip>

# 磁盘
fill_disk <ip> <mount> <pct>         # fallocate 填充（可逆）
clear_disk_fill <ip> <mount>

# 破坏性操作
simulate_tmpfs_loss <ip>           # ☠ 不可逆，需重建
stop_juicefs_fuse <ip>             # kill FUSE（可逆）
restart_juicefs_fuse <ip>

# 破坏性操作确认：FAULT_INJECT_FORCE=1 跳过确认；非交互模式未置 force → SKIP
```

---

## 六、完整 metrics.sh

```bash
# 快照模式
snapshot_ceph_perf / snapshot_ceph_status / snapshot_juicefs_stats / snapshot_nic / snapshot_iostat

# 连续采集模式（MON/DG 类用例）
start_monitoring [interval_s]        # 后台连续采集（默认 1s）
stop_monitoring                      # 停止，返回文件路径
get_metric_change_time <metric> <threshold>  # 回溯时序，找首次超阈值时间戳

# CSV 格式：
# epoch_seconds,osd_0_up,osd_1_up,...,pg_degraded_count,health_status
# 1752774000,1,1,...,0,HEALTH_OK
# 1752774001,1,0,...,3,HEALTH_WARN
```

MON 用例检测延迟计算：
```bash
FAULT_TIME=$(date +%s)
inject
DETECT_TIME=$(get_metric_change_time "osd.${id}.status" "down")
DETECT_DELAY=$(( DETECT_TIME - FAULT_TIME ))
assert_lt "$DETECT_DELAY" 60 "监控 60s 内检测到 (actual=${DETECT_DELAY}s)"
```

---

## 七、高级运行方式

```bash
./run.sh all --retry 1              # 每个 FAIL 重试 1 次
./run.sh all --dry-run              # 仅语法 + 环境校验
./run.sh all --stop-on-failure      # 首个 FAIL 即停
./run.sh all --non-interactive      # CI 模式
./run.sh --cleanup-all              # 按台账回滚全部残留故障
./run.sh --summary <timestamp>      # 输出汇总
./cleanup.sh                         # 删除 7 天前 results/
```

用例依赖与执行顺序（严格串行）：
```bash
# DEPENDS_ON="FT-001"   # 声明依赖
# 上游 FAIL/SKIP → 下游默认 SKIP
# OPS-002 暂不执行（需 reboot 节点，影响大）
```

---

## 八、完整配置

```bash
# config/env.sh
source "${SCRIPT_DIR}/../../prod-deploy/config.sh"

# 阈值
ASSERT_CEPH_HEALTH_TIMEOUT=120
ASSERT_PG_RECOVER_TIMEOUT=300
ASSERT_IO_LAT_P99_THRESHOLD_US=50000
ASSERT_IO_SUCCESS_RATE_MIN=100
DETECTION_DELAY_MAX=60
DEGRADATION_THROUGHPUT_MIN_PCT=70
DG_BASELINE_MIN_RATIO=0.8
GLOBAL_CASE_TIMEOUT_MULTIPLIER=3

# 数据完整性
VERIFY_DATASET_GIB=10
PRELOAD_GIB=500

# 编排器自保
DEADMAN_TTL_S=600
LEDGER_DIR="/var/tmp/reliability-ledger"

# 结果归档
RESULTS_RETENTION_DAYS=7

# 运行模式
NON_INTERACTIVE=0
FAULT_INJECT_FORCE=0
```

启动时配置校验：必需变量非空 + SSH 可达 + 工具存在 + cephadm shell 可达 + PD API 可达。

---

## 九、生产环境迁移清单

| # | 差异项 | 测试环境 | 生产要求 | 优先级 | 对应用例 |
|---|--------|---------|---------|:---:|---------|
| 1 | DB/WAL 介质 | tmpfs | 独立物理 NVMe | P0 | FT-002, OPS-001 |
| 2 | 监控系统 | 无 | 完整监控+告警 | P0 | — |
| 3 | 自动恢复 | 手动重建 | 自动恢复+通知 | P0 | FT-001, OPS-001 |
| 4 | 备份策略 | 无 | 元数据定期备份 | P1 | —（TiKV Raft 3 副本保障） |
| 5 | OSD 数量与 spare | 6（零 spare 无自愈） | 按容量规划 + 预留 spare | P1 | OPS-001 |
| 6 | 网络冗余 | 单链路 | 双链路/bonding | P1 | FT-003 |
| 7 | 电源保护 | 无 UPS | UPS+优雅关机 | P1 | OPS-002 |
| 8 | EC profile | 4+2（极限容忍） | 按节点数调整 | P2 | FT-006 |

---

## 十、已解决 / 待讨论

**已解决**：
1. ✅ P0 先行：FT-001/002/003/004/005, OPS-0012. ✅ TAP + JSONL 双写
3. ✅ 阈值统一 config/env.sh
4. ✅ 同一集群时间切片复用（互斥锁）
5. ✅ MON 先连续采集验证检测能力
6. ✅ 网络注入用 iptables 端口级 + netem 仅 eno12409
7. ✅ DEPENDS_ON 用例级，全部严格串行
8. ✅ 重建类时长按 PRELOAD_GIB=500 校准
9. ✅ dead-man switch + 台账
10. ✅ FT-002 用 kill -9 模拟宕机（≠ systemctl stop 优雅停止）
11. ✅ 安全边界按注入目标分层，澄清 100GbE 禁止是存储节点的事

**待讨论**：
1. FT-017（clock-skew）是否值得验证？
2. WekaIO 侧指标是否需要故障期间持续采集？
3. ~~OPS-008（rolling-upgrade）~~ 已删除
