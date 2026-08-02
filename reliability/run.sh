#!/bin/bash
# run.sh — 测试编排器
#
# 用法：
#   ./run.sh FT-001                # 单个用例
#   ./run.sh all                   # 全部用例（严格串行）
#   ./run.sh FT                     # 所有容错类（FT 前缀）
#   ./run.sh P0                     # 所有 P0 优先级
#   ./run.sh --quick-check          # 仅前置检查
#   ./run.sh --summary <timestamp>  # 查看结果汇总
#
# 选项：
#   --non-interactive   非交互模式（门禁失败直接退出）
#   --retry N           FAIL 用例重试 N 次
#   --dry-run           仅语法检查 + 环境校验

cd "$(dirname "$0")" || exit 1
source config/env.sh
source lib/cluster.sh

SCRIPT_DIR="$(pwd)"
CASES_DIR="${SCRIPT_DIR}/cases"
RESULTS_DIR="${SCRIPT_DIR}/results"
LIB_DIR="${SCRIPT_DIR}/lib"

NON_INTERACTIVE=false
RETRY=0
DRY_RUN=false

# ============================================================
# 函数（在参数解析之前定义，以便 --help 可调用）
# ============================================================

usage() {
    cat <<'EOF'
用法: ./run.sh <target> [options]

target:
  FT-001       单个用例
  all          全部用例
  FT|HA|MON|OPS|DG  按前缀筛选
  P0|P1|P2    按优先级筛选

options:
  --non-interactive  非交互模式
  --retry N          FAIL 重试 N 次
  --dry-run          仅语法检查
  --quick-check      仅前置检查
  --summary <ts>     查看结果汇总
EOF
}

# ============================================================
# 参数解析
# ============================================================
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --retry)           RETRY="${2:-1}"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --quick-check)     bash precheck.sh; exit $? ;;
        --summary)         show_summary "$2"; exit 0 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 TARGET="$1"; shift ;;
    esac
done

[ -z "$TARGET" ] && { usage; exit 1; }

# ============================================================
# 函数（续）
# ============================================================

# 从用例脚本头部提取优先级
get_case_priority() {
    local script=$1
    # 扫描注释行中的 P0/P1/P2
    # 用例文件名约定：cases/FT-001-*.sh（P0 在 README 中定义）
    # 简化：从 README 表格映射
    local id=$(basename "$script" | grep -oP '^[A-Z]+-\d+')
    case "$id" in
        FT-001|FT-002|FT-003|FT-004|FT-005|OPS-001) echo "P0" ;;
        *) echo "P1" ;;
    esac
}

# 从用例脚本提取 EXPECTED_DURATION
get_case_duration() {
    local script=$1
    grep -m1 'EXPECTED_DURATION=' "$script" 2>/dev/null | cut -d= -f2 || echo 300
}

# 收集匹配的用例
collect_cases() {
    local target=$1
    local cases=()

    if [ "$target" = "all" ]; then
        for f in "${CASES_DIR}"/FT-*.sh "${CASES_DIR}"/HA-*.sh \
                 "${CASES_DIR}"/MON-*.sh "${CASES_DIR}"/OPS-*.sh "${CASES_DIR}"/DG-*.sh; do
            [ -f "$f" ] && cases+=("$f")
        done
    elif echo "$target" | grep -qP '^(FT|HA|MON|OPS|DG)$'; then
        for f in "${CASES_DIR}/${target}"-*.sh; do
            [ -f "$f" ] && cases+=("$f")
        done
    elif echo "$target" | grep -qP '^P[0-3]$'; then
        for f in "${CASES_DIR}"/*.sh; do
            [ -f "$f" ] || continue
            local pri=$(get_case_priority "$f")
            [ "$pri" = "$target" ] && cases+=("$f")
        done
    else
        # 单个用例 ID（如 FT-001）
        for f in "${CASES_DIR}/${target}"-*.sh; do
            [ -f "$f" ] && cases+=("$f")
        done
    fi

    # 排序：按文件名
    printf '%s\n' "${cases[@]}" | sort | tr '\n' ' '
}

# dry-run：语法检查
dry_run() {
    local cases=($1)
    local ok=0; local fail=0
    echo "# DRY-RUN: ${#cases[@]} cases"
    for f in "${cases[@]}"; do
        if bash -n "$f" 2>/dev/null; then
            echo "  ok  - $(basename "$f")"
            ok=$((ok + 1))
        else
            echo "  FAIL - $(basename "$f") (syntax error)"
            fail=$((fail + 1))
        fi
    done
    echo "# DRY-RUN: ${ok}/${#cases[@]} pass syntax"
    [ "$fail" = 0 ]
}

# 健康门禁
health_gate() {
    if [ "$NON_INTERACTIVE" = true ]; then
        if ! bash precheck.sh --quick >/dev/null 2>&1; then
            echo "# ⚑ 集群健康异常（非交互模式），套件中止"
            exit 2
        fi
    else
        if ! bash precheck.sh --quick >/dev/null 2>&1; then
            echo "# ⚑ 集群健康异常，测试套件暂停。修复后按回车继续。"
            read -r
        fi
    fi
}

# 运行单个用例
run_case() {
    local script=$1
    local case_id=$(basename "$script" .sh)
    local duration=$(get_case_duration "$script")
    local timeout_s=$(( duration * GLOBAL_CASE_TIMEOUT_MULTIPLIER ))
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local result_dir="${RESULTS_DIR}/${timestamp}/${case_id}"
    mkdir -p "$result_dir"

    echo ""
    echo "=========================================="
    echo " 运行: ${case_id}"
    echo " 预估: ${duration}s  超时: ${timeout_s}s"
    echo "=========================================="

    # 用例前：采集集群快照
    echo "--- 集群快照采集 ---"
    local snap_file
    snap_file=$(capture_cluster_snapshot 2>/dev/null)
    if [ -n "$snap_file" ] && [ -f "$snap_file" ]; then
        echo "  快照: ${snap_file}"
        echo "  OSD=$(get_osd_count_up 2>/dev/null)  PG=$(get_pg_states 2>/dev/null | head -c 20)  quorum=$(get_quorum_count 2>/dev/null)"
    else
        echo "  WARNING: 快照采集失败，跳过校验"
    fi

    local output_file="${result_dir}/output.log"
    local tap_file="${result_dir}/result.tap"
    local rc=1

    # 运行用例，捕获输出
    LIB_DIR="$LIB_DIR" timeout "$timeout_s" bash "$script" 2>&1 | tee "$output_file"
    rc=${PIPESTATUS[0]}

    # 提取 TAP 结果到单独文件
    grep -E '^(ok|not ok|1\.\.|# Result:)' "$output_file" > "$tap_file" 2>/dev/null || true

    # 判断结果
    local result="FAIL"
    if [ "$rc" = 0 ]; then
        result="PASS"
    elif [ "$rc" = 124 ]; then
        result="TIMEOUT"
    fi

    echo ""
    echo " 结果: ${result} (rc=${rc})"

    # 用例后：校验集群状态是否恢复
    if [ -n "$snap_file" ] && [ -f "$snap_file" ]; then
        echo "--- 集群状态校验 ---"
        _SNAPSHOT_FILE="$snap_file"
        if verify_cluster_snapshot 2>&1; then
            echo "  ok  集群状态恢复（与快照一致）"
        else
            echo "  ⚑ 集群状态异常（用例可能破坏了集群）"
            result="${result}+CLUSTER_BROKEN"
        fi
        remove_cluster_snapshot
    fi

    # 重试
    if [ "$result" = "FAIL" ] || [ "$result" = "TIMEOUT" ]; then
        local retry_count=0
        while [ "$retry_count" -lt "$RETRY" ]; do
            retry_count=$((retry_count + 1))
            echo " 重试 ${retry_count}/${RETRY}..."
            LIB_DIR="$LIB_DIR" timeout "$timeout_s" bash "$script" 2>&1 | tee -a "$output_file"
            rc=${PIPESTATUS[0]}
            [ "$rc" = 0 ] && { result="PASS (retry ${retry_count})"; break; }
        done
    fi

    echo "${case_id}: ${result}"
    echo "${case_id}|${result}" >> "${RESULTS_DIR}/${timestamp}/summary.txt"
}

# 显示汇总
show_summary() {
    local ts=$1
    local summary_file="${RESULTS_DIR}/${ts}/summary.txt"
    if [ ! -f "$summary_file" ]; then
        echo "未找到结果: ${summary_file}"
        exit 1
    fi

    local total=0 pass=0 fail=0
    echo "# Summary: ${ts}"
    while IFS='|' read -r case result; do
        total=$((total + 1))
        case "$result" in
            PASS*) pass=$((pass + 1)); echo "  ok   - ${case}" ;;
            *)     fail=$((fail + 1)); echo "  not ok - ${case} (${result})" ;;
        esac
    done < "$summary_file"
    echo "1..${total}"
    echo "# Total: ${total}  Pass: ${pass}  Fail: ${fail}"
}

# ============================================================
# 主流程
# ============================================================

# 收集用例
CASES_STR=$(collect_cases "$TARGET")
CASES=($CASES_STR)

if [ ${#CASES[@]} -eq 0 ]; then
    echo "未找到匹配的用例: $TARGET"
    echo "可用用例:"
    ls "${CASES_DIR}"/*.sh 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
    exit 1
fi

echo "目标: ${TARGET}  用例数: ${#CASES[@]}"

# Dry-run
if [ "$DRY_RUN" = true ]; then
    dry_run "$CASES_STR"
    exit $?
fi

# 前置检查
echo "前置检查..."
if ! bash precheck.sh 2>&1; then
    echo "前置检查失败，中止。"
    exit 1
fi

# 运行用例（严格串行）
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "${RESULTS_DIR}/${TIMESTAMP}"

for script in "${CASES[@]}"; do
    # 用例间健康门禁
    if [ "$script" != "${CASES[0]}" ]; then
        health_gate
    fi

    # 运行
    LIB_DIR="$LIB_DIR" run_case "$script"
done

echo ""
echo "=========================================="
echo " 套件完成: ${TIMESTAMP}"
echo "=========================================="
show_summary "$TIMESTAMP"
