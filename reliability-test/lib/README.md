# 共享库（lib/）

> 所有用例通过 `source` 引入共享库。全部集群操作经 `_run`（三层 SSH 跳板）路由到对应节点执行。

## assert.sh — TAP 断言库

```bash
# 基本断言
assert_eq    <actual> <expected> <desc>
assert_ne    <actual> <unexpected> <desc>
assert_lt    <actual> <threshold> <desc>
assert_gt    <actual> <threshold> <desc>
assert_match <actual> <pattern> <desc>

# 轮询断言（等待条件成立，超时则 FAIL）
# 参数为函数引用，非字符串命令（避免 eval 风险）
assert_wait_eq    <func> <args...> <expected> <timeout> <desc>
assert_wait_match <func> <args...> <pattern> <timeout> <desc>
assert_wait_lt    <func> <args...> <threshold> <timeout> <desc>

# 组合断言（基于 cluster.sh/io_load.sh 封装，用例直接调用）
assert_ceph_health <expected> <desc>                # 轮询 ceph health 直至期望值
assert_pg_state_contains <substr> <timeout> <desc>  # PG 状态包含子串
assert_io_success_rate <min_pct> <desc>             # I/O 成功率下限
assert_fio_lat_p99_lt <threshold_us> <desc>         # fio P99 延迟上限

# 输出控制
tap_plan_start <id> <name> <desc>   # 用例开始
tap_plan_end                        # 末尾输出 plan 行 1..N
tap_skip <reason>                   # 输出 SKIP
```

调用示例：
```bash
assert_wait_eq get_ceph_health "HEALTH_OK" 60 "集群恢复 HEALTH_OK"
assert_wait_lt get_io_lat_p99 50000 30 "P99 < 50ms"
```

## cluster.sh — 集群状态查询

> ceph 命令用 `cephadm shell`，PD/TiKV 用 REST API（环境无 pd-ctl），juicefs 经 `ssh_to_client`。

```bash
get_ceph_health          # → "HEALTH_OK" / "HEALTH_WARN" / "HEALTH_ERR"
get_pg_states            # → "active+clean" / "active+degraded" / ...
get_osd_status <id>      # → "up" / "down"
get_osd_count_up         # → 6
list_osd_ids             # → "0 1 2 3 4 5"
pick_random_osd          # → 随机 OSD id
pick_osd_on_node <ip>    # → 指定节点上的 OSD id
get_osd_node <id>        # → OSD 所在节点 IP
ensure_osd_up <id>       # teardown 兜底（幂等）
get_quorum_count         # → MON quorum 成员数
get_pd_health            # → PD 集群健康
get_tikv_stores          # → TiKV store 列表
get_tikv_leader          # → 当前 Raft leader store
get_juicefs_status       # → JuiceFS 挂载状态
```

## fault_inject.sh — 故障注入原语

> **安全边界**：故障注入目标是存储节点（150-152），模拟后端集群故障。客户端 157 是观测点，不是注入目标。
>
> | 禁止操作 | 原因 |
> |---------|------|
> | `iptables` on 10.20.1.0/24（管理网） | SSH 生命线，DROP 即失联 |
> | `iptables` 整网段 DROP | 仅允许端口级 + 指定对端 IP 的精确规则 |

```bash
# OSD
stop_osd <id> / start_osd <id>      # ceph orch daemon stop/start
out_osd <id> / in_osd <id>          # ceph osd out/in

# TiKV / PD / MON
stop_tikv <ip> / start_tikv <ip>
stop_pd <ip> / start_pd <ip>
stop_mon <id> / start_mon <id>

# 节点级
stop_node_storage <ip>              # systemctl stop 全部存储服务（优雅）
start_node_storage <ip>
crash_node_storage <ip>             # SIGKILL 全部存储进程（模拟宕机）
restart_node_storage <ip>           # 从 crash 恢复

# 网络
net_partition <src_ip> <dst_ip> <ports...>  # iptables 端口级 DROP
net_partition_clear <ip>
```

> 完整原语（含 throttle、clock_skew、fill_disk、simulate_tmpfs_loss 等）见 `framework-design.md` §五。

## io_load.sh — I/O 负载生成

```bash
start_io_load <type> <bs> <jobs>   # 后台启动 fio（randread/randwrite/randrw/seqread/seqwrite）
stop_io_load                        # 停止 + 采集结果
get_io_success_rate                 # → 0-100
get_io_lat_p99                      # → 微秒
get_io_bw                           # → MiB/s
capture_io_baseline                 # 采集故障前基线
```

## metrics.sh — 指标采集

```bash
# 快照模式
snapshot_ceph_perf / snapshot_ceph_status / snapshot_juicefs_stats / snapshot_nic / snapshot_iostat

# 连续采集模式（MON/DG 类用例）
start_monitoring [interval_s]        # 后台连续采集（默认 1s）
stop_monitoring                      # 停止，返回文件路径
get_metric_change_time <metric> <threshold>  # 回溯时序，找首次超阈值时间戳
```

> 完整设计（连续采集 CSV 格式、检测延迟计算示例等）见 `framework-design.md` §六。
