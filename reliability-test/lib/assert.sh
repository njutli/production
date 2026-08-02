#!/bin/bash
# lib/assert.sh — TAP 断言库
#
# 输出 TAP 13 格式，plan 行在末尾输出（中途 abort 不产生 plan 不匹配）。
# 轮询断言使用函数引用（非字符串命令），避免 eval 风险。
# 所有断言即使 FAIL 也继续执行（不中断），recover() 由用例保证。

# Auto-load config if not already loaded
if [ -z "${RELIABILITY_CONFIG_LOADED:-}" ]; then
    _assert_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${_assert_dir}/../config/env.sh"
fi

# Counters
_ASSERT_COUNT=0
_ASSERT_PASS=0
_ASSERT_FAIL=0


# ============================================================
# 内部函数
# ============================================================

_assert_pass() {
    local desc=$1 detail=${2:-}
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    _ASSERT_PASS=$((_ASSERT_PASS + 1))
    if [ -n "$detail" ]; then
        echo "ok ${_ASSERT_COUNT} - ${desc} (${detail})"
    else
        echo "ok ${_ASSERT_COUNT} - ${desc}"
    fi
}

_assert_fail() {
    local desc=$1 detail=${2:-}
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
    if [ -n "$detail" ]; then
        echo "not ok ${_ASSERT_COUNT} - ${desc} # ${detail}"
    else
        echo "not ok ${_ASSERT_COUNT} - ${desc}"
    fi

    # setup 阶段断言失败 → 中止，跳过后续步骤，执行清理后退出
    # 通过检查调用栈中是否有 setup 函数来判断当前阶段
    local fn
    for fn in "${FUNCNAME[@]:1}"; do
        if [[ "$fn" == setup ]]; then
            echo "# ABORT: setup 阶段断言失败（not ok ${_ASSERT_COUNT}），跳过 inject/check/recover/after"
            trap 'stop_io_load 2>/dev/null || true; tap_plan_end' EXIT
            exit 1
        fi
    done
}


# ============================================================
# 输出控制
# ============================================================

tap_plan_start() {
    local id=$1 name=$2 desc=${3:-}
    _ASSERT_COUNT=0
    _ASSERT_PASS=0
    _ASSERT_FAIL=0
    _TAP_PLAN_END_DONE=""
    echo "TAP version 13"
    echo "# ${id}: ${name}"
    [ -n "$desc" ] && echo "# ${desc}"
}

tap_plan_end() {
    # 防止重复调用（setup abort 的 EXIT trap 也会调 tap_plan_end）
    [ -n "${_TAP_PLAN_END_DONE:-}" ] && return
    _TAP_PLAN_END_DONE=1

    echo "1..${_ASSERT_COUNT}"
    local result="PASS"
    [ "$_ASSERT_FAIL" -gt 0 ] && result="FAIL"
    echo "# Result: ${result} (${_ASSERT_PASS}/${_ASSERT_COUNT})"

    # 有断言失败时以非零退出，让 run.sh 正确判定结果
    if [ "$_ASSERT_FAIL" -gt 0 ]; then
        trap - EXIT
        exit 1
    fi
}

tap_skip() {
    local reason=$1
    echo "1..0 # SKIP ${reason}"
    echo "# Result: SKIP (${reason})"
}


# ============================================================
# 基本断言
# ============================================================

assert_eq() {
    local actual=$1 expected=$2 desc=$3
    if [ "$actual" = "$expected" ]; then
        _assert_pass "$desc"
    else
        _assert_fail "$desc" "actual='${actual}' expected='${expected}'"
    fi
}

assert_ne() {
    local actual=$1 unexpected=$2 desc=$3
    if [ "$actual" != "$unexpected" ]; then
        _assert_pass "$desc"
    else
        _assert_fail "$desc" "actual='${actual}' should not be '${unexpected}'"
    fi
}

assert_lt() {
    local actual=$1 threshold=$2 desc=$3
    if [ "$actual" -lt "$threshold" ] 2>/dev/null; then
        _assert_pass "$desc" "actual=${actual} < ${threshold}"
    else
        _assert_fail "$desc" "actual=${actual} >= ${threshold}"
    fi
}

assert_gt() {
    local actual=$1 threshold=$2 desc=$3
    if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
        _assert_pass "$desc" "actual=${actual} > ${threshold}"
    else
        _assert_fail "$desc" "actual=${actual} <= ${threshold}"
    fi
}

assert_match() {
    local actual=$1 pattern=$2 desc=$3
    # ^ 开头 → 正则匹配（如 ^HEALTH_(OK|WARN)）
    # 否则 → 固定字符串匹配（如 active+clean，+ 不被当正则量词）
    if [[ "$pattern" == ^* ]]; then
        echo "$actual" | grep -qE "$pattern"
    else
        echo "$actual" | grep -qF "$pattern"
    fi
    if [ $? -eq 0 ]; then
        _assert_pass "$desc"
    else
        _assert_fail "$desc" "actual='${actual}' !~ /${pattern}/"
    fi
}


# ============================================================
# 轮询断言（等待条件成立，超时则 FAIL）
# 最后 3 个参数固定为 expected/pattern/threshold, timeout, desc
# 其余参数为 func + func_args（函数引用，非 eval）
# ============================================================

# assert_wait_eq <func> [func_args...] <expected> <timeout> <desc>
# timeout 单位为墙钟秒（非迭代次数）。函数调用本身可能耗时 5-15s，不额外 sleep。
assert_wait_eq() {
    [ $# -lt 4 ] && { _assert_fail "assert_wait_eq: needs >= 4 args" "got $# args"; return 1; }
    local desc="${@:$#:1}"
    local timeout="${@:$(( $# - 1 )):1}"
    local expected="${@:$(( $# - 2 )):1}"
    local func_and_args=("${@:1:$(( $# - 3 ))}")

    local _start=$(date +%s) _elapsed _result
    while true; do
        _elapsed=$(($(date +%s) - _start))
        [ "$_elapsed" -gt "$timeout" ] && break
        _result=$("${func_and_args[@]}" 2>/dev/null)
        if [ "$_result" = "$expected" ]; then
            _assert_pass "$desc" "actual='${_result}' waited=${_elapsed}s"
            return 0
        fi
    done
    _assert_fail "$desc" "actual='${_result}' expected='${expected}' timeout=${timeout}s"
    return 1
}

# assert_wait_ne <func> [func_args...] <unexpected> <timeout> <desc>
assert_wait_ne() {
    [ $# -lt 4 ] && { _assert_fail "assert_wait_ne: needs >= 4 args" "got $# args"; return 1; }
    local desc="${@:$#:1}"
    local timeout="${@:$(( $# - 1 )):1}"
    local unexpected="${@:$(( $# - 2 )):1}"
    local func_and_args=("${@:1:$(( $# - 3 ))}")

    local _start=$(date +%s) _elapsed _result
    while true; do
        _elapsed=$(($(date +%s) - _start))
        [ "$_elapsed" -gt "$timeout" ] && break
        _result=$("${func_and_args[@]}" 2>/dev/null)
        if [ "$_result" != "$unexpected" ] && [ -n "$_result" ]; then
            _assert_pass "$desc" "actual='${_result}' != '${unexpected}' waited=${_elapsed}s"
            return 0
        fi
    done
    _assert_fail "$desc" "actual='${_result}' still == '${unexpected}' timeout=${timeout}s"
    return 1
}

# assert_wait_match <func> [func_args...] <pattern> <timeout> <desc>
assert_wait_match() {
    [ $# -lt 4 ] && { _assert_fail "assert_wait_match: needs >= 4 args" "got $# args"; return 1; }
    local desc="${@:$#:1}"
    local timeout="${@:$(( $# - 1 )):1}"
    local pattern="${@:$(( $# - 2 )):1}"
    local func_and_args=("${@:1:$(( $# - 3 ))}")

    local _start=$(date +%s) _elapsed _result _match
    while true; do
        _elapsed=$(($(date +%s) - _start))
        [ "$_elapsed" -gt "$timeout" ] && break
        _result=$("${func_and_args[@]}" 2>/dev/null)
        # ^ 开头 → 正则匹配，否则 → 固定字符串匹配（避免 + 被当 ERE 量词）
        if [[ "$pattern" == ^* ]]; then
            echo "$_result" | grep -qE "$pattern" && _match=0 || _match=1
        else
            echo "$_result" | grep -qF "$pattern" && _match=0 || _match=1
        fi
        if [ "$_match" = 0 ]; then
            _assert_pass "$desc" "actual='${_result}' =~ /${pattern}/ waited=${_elapsed}s"
            return 0
        fi
    done
    _assert_fail "$desc" "actual='${_result}' !~ /${pattern}/ timeout=${timeout}s"
    return 1
}

# assert_wait_lt <func> [func_args...] <threshold> <timeout> <desc>
assert_wait_lt() {
    [ $# -lt 4 ] && { _assert_fail "assert_wait_lt: needs >= 4 args" "got $# args"; return 1; }
    local desc="${@:$#:1}"
    local timeout="${@:$(( $# - 1 )):1}"
    local threshold="${@:$(( $# - 2 )):1}"
    local func_and_args=("${@:1:$(( $# - 3 ))}")

    local _start=$(date +%s) _elapsed _result
    while true; do
        _elapsed=$(($(date +%s) - _start))
        [ "$_elapsed" -gt "$timeout" ] && break
        _result=$("${func_and_args[@]}" 2>/dev/null)
        if [ "$_result" -lt "$threshold" ] 2>/dev/null; then
            _assert_pass "$desc" "actual=${_result} < ${threshold} waited=${_elapsed}s"
            return 0
        fi
    done
    _assert_fail "$desc" "actual=${_result} >= ${threshold} timeout=${timeout}s"
    return 1
}


# ============================================================
# 组合断言（基于 cluster.sh 封装）
# ============================================================

# assert_ceph_health <expected> <desc>
# 轮询 ceph health 直至期望值，默认超时 120s
assert_ceph_health() {
    local expected=$1 desc=$2
    assert_wait_eq get_ceph_health "$expected" "${ASSERT_CEPH_HEALTH_TIMEOUT:-120}" "$desc"
}

# assert_pg_state_contains <substr> <timeout> <desc>
# 轮询 PG 状态直至包含子串
assert_pg_state_contains() {
    local substr=$1 timeout=$2 desc=$3
    assert_wait_match get_pg_states "$substr" "$timeout" "$desc"
}

# assert_io_success_rate <min_pct> <desc>
# 依赖 io_load.sh 的 get_io_success_rate
assert_io_success_rate() {
    local min_pct=$1 desc=$2
    if ! command -v get_io_success_rate &>/dev/null; then
        _assert_fail "$desc" "get_io_success_rate not available (source io_load.sh)"
        return 1
    fi
    local rate
    rate=$(get_io_success_rate 2>/dev/null)
    if [ -n "$rate" ] && [ "$rate" -ge "$min_pct" ] 2>/dev/null; then
        _assert_pass "$desc" "actual=${rate}%"
    else
        _assert_fail "$desc" "actual=${rate:-N/A}% expected>=${min_pct}%"
    fi
}

# assert_fio_lat_p99_lt <threshold_us> <desc>
# 依赖 io_load.sh 的 get_io_lat_p99
assert_fio_lat_p99_lt() {
    local threshold=$1 desc=$2
    if ! command -v get_io_lat_p99 &>/dev/null; then
        _assert_fail "$desc" "get_io_lat_p99 not available (source io_load.sh)"
        return 1
    fi
    local lat
    lat=$(get_io_lat_p99 2>/dev/null)
    if [ -n "$lat" ] && [ "$lat" -lt "$threshold" ] 2>/dev/null; then
        _assert_pass "$desc" "actual=${lat}us < ${threshold}us"
    else
        _assert_fail "$desc" "actual=${lat:-N/A}us >= ${threshold}us"
    fi
}

# assert_fio_lat_max_lt <threshold_us> <desc>
# 检测故障期间是否有单个 IO 被长时间阻塞（P99 可能漏检少量阻塞）
# lat=0 表示无 fio JSON 数据（fio 被 SIGKILL 或无 IO 完成），视为失败
assert_fio_lat_max_lt() {
    local threshold=$1 desc=$2
    if ! command -v get_io_lat_max &>/dev/null; then
        _assert_fail "$desc" "get_io_lat_max not available (source io_load.sh)"
        return 1
    fi
    local lat
    lat=$(get_io_lat_max 2>/dev/null)
    if [ -n "$lat" ] && [ "$lat" -gt 0 ] && [ "$lat" -lt "$threshold" ] 2>/dev/null; then
        _assert_pass "$desc" "actual=${lat}us < ${threshold}us"
    else
        _assert_fail "$desc" "actual=${lat:-N/A}us >= ${threshold}us (or no data)"
    fi
}
