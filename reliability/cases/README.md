# 测试用例（cases/）

> 用例按前缀分类：
>
> | 前缀 | 全称 | 含义 |
> |------|------|------|
> | **FT** | Fault Tolerance | 容错验证——验证故障期间数据可用、I/O 不中断 |
> | **OPS** | Operations | 运维操作——验证恢复/重建等运维流程可执行 |
> | **DG** | Degradation | 性能退化量化——验证故障期间吞吐退化幅度可控 |
>
> 所有用例严格串行——共享同一物理集群，故障域重叠，并行注入会互相污染断言。
> P1 用例见 `framework-design.md` §二。

---

## 一、P0 用例

### FT-001：单盘故障——OSD 进程异常

| 项 | 值 |
|----|-----|
| 故障注入 | `stop_osd <id>`（`ceph orch daemon stop`） |
| 关键断言 | fault 期间 I/O 100% 不中断、PG degraded、恢复后 PG clean + 恢复时间 < 300s |
| 预估时长 | 6min |

### FT-002：单盘故障——磁盘故障

| 项 | 值 |
|----|-----|
| 故障注入 | `dmsetup suspend`（挂起 OSD 数据 dm 设备，模拟磁盘 I/O 超时） |
| 关键断言 | I/O 不中断（EC 从剩余 chunk 读）、PG degraded、移除故障后数据完整 |
| 预估时长 | 8min |

### FT-003：节点宕机（2 OSD + 1 MON + 1 TiKV + 1 PD 同时失效）

| 项 | 值 |
|----|-----|
| 故障注入 | `crash_node_storage <ip>`（SIGKILL 全部存储进程，模拟真实宕机） |
| 关键断言 | 数据面+元数据面同时故障转移、I/O stall < 35s、成功率 100%、恢复后数据完整 |
| 预估时长 | 10min |

### FT-004：单 TiKV down（仅元数据面）

| 项 | 值 |
|----|-----|
| 故障注入 | `stop_tikv <ip>`（systemctl stop） |
| 关键断言 | 元数据操作可完成、Raft leader 切换、I/O 不中断 |
| 预估时长 | 6min |

### FT-005：双 TiKV down（元数据面完全不可用）

| 项 | 值 |
|----|-----|
| 故障注入 | 停 2/3 TiKV |
| 关键断言 | JuiceFS 元数据操作阻塞（无错误返回）、恢复后无感继续、无元数据损坏 |
| 预估时长 | 5min |

### OPS-001：磁盘故障换盘重建

| 项 | 值 |
|----|-----|
| 考察点 | 备用盘（tmpfs 模拟）能加入集群并发挥作用 |
| 验证方式 | 销毁 OSD A → tmpfs 备用盘替代 → 恢复后对另一盘 B 注入故障 → I/O 正常说明备用盘真正生效 |
| 预估时长 | ~20min |

---

## 二、P1 用例

### FT-006：单 MON down（仍保持 quorum）

| 项 | 值 |
|----|-----|
| 故障注入 | `stop_mon <ip>` |
| 关键断言 | 集群可操作、quorum 2/3 不受影响 |
| 预估时长 | 4min |

### FT-007：双 MON down（丢失 quorum）

| 项 | 值 |
|----|-----|
| 故障注入 | 停 2/3 MON |
| 关键断言 | 集群不可操作、已有 I/O 可继续但管理面不可用 |
| 预估时长 | 4min |

### FT-008：单 PD down

| 项 | 值 |
|----|-----|
| 故障注入 | `stop_pd <ip>` |
| 关键断言 | TiKV 读写不受影响、PD leader 自动切换 |
| 预估时长 | 5min |

### FT-009：双 PD down（PD quorum 丢失）

| 项 | 值 |
|----|-----|
| 故障注入 | 停 2/3 PD |
| 关键断言 | PD 管理面冻结、TiKV 仍可服务（本地 cache）、新元数据操作可发起 |
| 预估时长 | 5min |

### FT-010：JuiceFS FUSE crash

| 项 | 值 |
|----|-----|
| 故障注入 | kill JuiceFS FUSE 进程 |
| 关键断言 | mount 不可用、已 fsync 数据完整、重启 FUSE 后恢复（未 fsync 数据按 POSIX 丢失） |
| 预估时长 | 3min |

### OPS-002：逐节点重启

| 项 | 值 |
|----|-----|
| 操作 | 逐节点 reboot（tmpfs 丢失 = 每节点 2 OSD 走重建路径） |
| 关键断言 | 重建流程逐节点可重复、重建后数据完整、单节点重建期间数据可用 |
| 预估时长 | ~3×单节点重建时长 |
| 状态 | ⚠️ 暂不执行（需 reboot 节点，影响大） |

### DG-001：OSD down 吞吐退化

| 项 | 值 |
|----|-----|
| 故障注入 | 停 1 OSD |
| 关键断言 | fault + recovery 全程吞吐 ≥ 基线×70%、P99 < 基线×3 |
| 预估时长 | 8min |

> **阈值依据**：EC 4+2 停 1 OSD，理论可用 5/6 chunk ≈ 83%，70% 留余量。
> P99 recovery 期间可能升高，3× 留余量。阈值为架构推算未实测，首次执行时记录实际退化值校准。

### DG-002：TiKV down 元数据延迟

| 项 | 值 |
|----|-----|
| 故障注入 | 停 1 TiKV |
| 关键断言 | 元数据操作 P95 延迟 < 基线 × 3 |
| 预估时长 | 7min |

> **阈值依据**：Raft leader 切换后新 leader 可能在不同节点，增加一次网络往返；
> 选举期间短暂阻塞。正常元数据延迟 ~5-10ms，3× = 15-30ms 覆盖选举后稳态。
> 阈值为架构推算未实测，首次执行时记录实际退化值，再据此校准。

---

## 三、用例模板

```bash
#!/bin/bash
# FT-001: single-osd-down
# 停 1 OSD，I/O 全程运行，验证 fault 期间不中断 + recovery 期间延迟/吞吐量化
# EXPECTED_DURATION=480

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-001"
TEST_NAME="single-osd-down"
EXPECTED_DURATION=480

trap 'stop_io_load; start_osd "$TARGET_OSD" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" "描述..."
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    TARGET_OSD=$(pick_random_osd)
    capture_io_baseline
    start_io_load randread 256K 128
    sleep 30
}

inject() {
    stop_osd "$TARGET_OSD"
}

check_during() {
    sleep 5
    assert_pg_state_contains "degraded" 30 "PG 进入 degraded"
    # 不停止 I/O——让它跑过 recovery 阶段
}

recover() {
    start_osd "$TARGET_OSD"
    # 等待 recovery 完成
    local elapsed=0
    while [ "$elapsed" -lt 300 ]; do
        get_pg_states 2>/dev/null | grep -q "active+clean" && break
        sleep 5; elapsed=$((elapsed + 5))
    done
    stop_io_load
}

check_after() {
    assert_pg_state_contains "active+clean" 10 "PG active+clean"
    assert_eq "$(get_osd_count_up)" "6" "6/6 OSD up"
    assert_io_success_rate 100 "I/O 成功率 100%"
    assert_fio_lat_p99_lt "$((_IO_BASELINE_P99 * 3))" "P99 < 3×基线"
    assert_gt "$(get_io_bw)" "$((_IO_BASELINE_BW * 70 / 100))" "吞吐 ≥ 基线 70%"
}

teardown() {
    stop_io_load
    ensure_osd_up "$TARGET_OSD"
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
```

> 模板说明：
> - `EXPECTED_DURATION`：预估执行时长（秒），框架据此设定超时
> - `capture_io_baseline` + `start_io_load`：采集基线后启动 I/O，I/O 全程运行覆盖 fault + recovery
> - `check_during` 不停止 I/O，`recover` 中等待 recovery 完成后停止 I/O，`check_after` 断言全程 I/O 表现
> - `recover()` 必须幂等（即使故障未成功注入也不得有副作用）
> - 所有断言即使 FAIL 也继续执行（采集完整信息），`recover()` 始终执行
