#!/bin/bash
# reliability/config/env.sh
# 集群连接 + 阈值配置

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 统一 locale，避免 SSH 转发 zh_CN.utf8 到远程节点报 warning
export LC_ALL=C

# 从 prod-deploy 继承集群配置（IP/SSH/disk/网络/ceph/tikv/juicefs）
source "${_SCRIPT_DIR}/../../prod-deploy/config.sh"

# --- Reliability 阈值 ---
ASSERT_CEPH_HEALTH_TIMEOUT=120
ASSERT_PG_RECOVER_TIMEOUT=300
ASSERT_IO_LAT_P99_THRESHOLD_US=50000
ASSERT_IO_SUCCESS_RATE_MIN=100
GLOBAL_CASE_TIMEOUT_MULTIPLIER=3

# --- 结果归档 ---
RESULTS_DIR="${_SCRIPT_DIR}/../results"

# 标记已加载
RELIABILITY_CONFIG_LOADED=1
