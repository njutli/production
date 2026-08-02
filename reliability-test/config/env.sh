#!/bin/bash
# reliability-test/config/env.sh
# 集群连接 + 阈值配置
#
# config.sh 已包含 SSH 函数 + 全部集群变量（3 TiKV + 3 PD 拓扑）。
# 此文件只需 source config.sh + 添加 reliability 阈值。

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export LC_ALL=C

# 从 production/config.sh 继承集群配置
source "${_SCRIPT_DIR}/../../config.sh"

# --- Reliability 阈值 ---
ASSERT_CEPH_HEALTH_TIMEOUT=120
ASSERT_PG_RECOVER_TIMEOUT=300
ASSERT_IO_LAT_P99_THRESHOLD_US=50000
ASSERT_IO_SUCCESS_RATE_MIN=100
GLOBAL_CASE_TIMEOUT_MULTIPLIER=3

# 管理网段前缀（net_partition 安全 guard 用）
MGMT_NETWORK_PREFIX="${MGMT_NETWORK_PREFIX:-192.168.11}"

# --- 结果归档 ---
RESULTS_DIR="${_SCRIPT_DIR}/../results"

# 标记已加载
RELIABILITY_CONFIG_LOADED=1
