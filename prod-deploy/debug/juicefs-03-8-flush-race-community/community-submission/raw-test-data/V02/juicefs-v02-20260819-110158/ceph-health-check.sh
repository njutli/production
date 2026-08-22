# ============================================================
# ceph-health-check.sh — 集群健康检查库（Production）
# ============================================================
# 生产版（从上层 tests/lib/ceph-health-check.sh 同步）：
#   - 逻辑原样保留（环境无关：只调 `sudo ceph health/detail`）
#   - 前置条件：运行节点须有 ceph CLI + admin keyring（/etc/ceph/ceph.conf
#     + /etc/ceph/ceph.client.admin.keyring）。生产用 cephadm 部署，admin
#     keyring 默认只在 PRIMARY 节点；测试 runner 非 PRIMARY 时需先拷贝
#     （见 deploy-juicefs.sh 的 client.juicefs keyring 分发，admin 同理）。
#
# 用法：在测试脚本中 source 本文件，然后在每个 fio 跑前调用：
#
#   source tests/lib/ceph-health-check.sh
#   check_ceph_health "before seqread"
#   fio ...
#
# 行为：
#   - 检查 ceph health，如果是非性能影响的告警（如时钟漂移），忽略
#   - 如果是性能影响的告警（BlueFS stall, OSD down, PG degraded 等）：
#     - 打印告警和当前 health detail
#     - 轮询等待最多 WAIT_SEC 秒（默认 120s），每 15s 检查一次
#     - 超时后仍然非 OK 则 abort 整个测试脚本
#   - 如果 HEALTH_OK 则正常继续
# ============================================================

# 非性能影响的告警关键字（忽略这些告警）
HEALTH_IGNORE_PATTERNS="MON_CLOCK_SKEW\|clock skew\|mon clock\|too few PGs\|pool too few pgs"

# 提取性能影响的健康问题
# 返回 0 = 有性能影响的问题, 1 = 只有可忽略的问题或完全 OK
has_perf_health_issue(){
  local detail
  detail=$(sudo ceph health detail 2>&1)
  # 过滤掉可忽略的告警行
  local filtered
  filtered=$(echo "$detail" | grep -v "$HEALTH_IGNORE_PATTERNS" | grep -v '^HEALTH_OK' | grep -v '^$')
  if [ -n "$filtered" ]; then
    return 0
  else
    return 1
  fi
}

# 健康检查：非 OK 则等待，超时 abort
# 参数 $1: 检查点描述（如 before randread r3）
check_ceph_health(){
  local label="${1:-unknown}"
  local wait_sec=${CEPH_HEALTH_WAIT_SEC:-120}
  local poll_interval=15
  local elapsed=0

  local health
  health=$(sudo ceph health 2>&1 | head -1)

  if [ "$health" = "HEALTH_OK" ]; then
    echo "  [health-check] OK — ${label}"
    return 0
  fi

  # 非 OK，检查是否只有可忽略的告警
  if ! has_perf_health_issue; then
    echo "  [health-check] OK (ignoring non-perf warnings) — ${label}: $health"
    return 0
  fi

  # 有性能影响的告警，打印详情
  echo "  [health-check] WARN: ceph health is '$health' — ${label}"
  echo "  [health-check] health detail:"
  sudo ceph health detail 2>&1 | head -20 | sed 's/^/    /'

  # 轮询等待恢复
  echo "  [health-check] waiting up to ${wait_sec}s for recovery..."
  while [ "$elapsed" -lt "$wait_sec" ]; do
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
    health=$(sudo ceph health 2>&1 | head -1)
    if [ "$health" = "HEALTH_OK" ] || ! has_perf_health_issue; then
      echo "  [health-check] RECOVERED after ${elapsed}s — ${label}"
      return 0
    fi
    echo "  [health-check] still '$health' after ${elapsed}s..."
  done

  # 超时，abort
  echo "  [health-check] FATAL: ceph health still non-OK after ${wait_sec}s — ABORTING TEST"
  echo "  [health-check] full health detail:"
  sudo ceph health detail 2>&1 | sed 's/^/    /'
  echo "  [health-check] osd tree:"
  sudo ceph osd tree 2>&1 | sed 's/^/    /'
  exit 1
}

# 快速检查：只检查不等待，返回 0=OK / 1=非OK
# 参数 $1: 检查点描述
check_ceph_health_quick(){
  local label="${1:-unknown}"
  local health
  health=$(sudo ceph health 2>&1 | head -1)
  if [ "$health" = "HEALTH_OK" ] || ! has_perf_health_issue; then
    echo "  [health-check] OK — ${label}"
    return 0
  else
    echo "  [health-check] WARN: '$health' — ${label}"
    return 1
  fi
}
