#!/bin/bash
# 临时测试脚本：验证 io_load.sh 各函数
# 使用 mock（不连接集群，不影响性能测试）
# 用法：bash test-io-load.sh

cd "$(dirname "$0")" || exit 1
source config/env.sh

PASS=0; FAIL=0
ok()   { echo "  ok  - $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

# ============================================================
# Mock ssh_to_client：捕获命令，返回预设值
# ============================================================
CALLS=()
_MOCK_FIO_JSON=''

ssh_to_client() {
    local cmd="$*"
    CALLS+=("$cmd")

    # 模拟不同命令的返回值
    case "$cmd" in
        pgrep*) echo "12345" ;;
        kill*INT*) ;;        # 模拟 SIGINT 成功
        kill*KILL*) ;;       # 模拟 SIGKILL 成功
        "kill -0"*) echo "no" ;;  # 进程已退出
        *result*) echo "$_MOCK_FIO_JSON" ;;        # sed/cat result file
        *baseline*) echo "$_MOCK_FIO_BASELINE_JSON" ;;  # sed/cat baseline file
        rm*) ;;              # 清理命令，无需输出
        mkdir*) ;;
    esac
}

source lib/io_load.sh 2>/dev/null

# Mock fio JSON 输出（randread，128 jobs）
_MOCK_FIO_JSON='{"jobs":[{"read":{"bw":307200,"total_ios":150000,"clat_ns":{"percentile":{"99.000000":5000000}}},"write":{"bw":0,"total_ios":0},"total_io_errors":1500}]}'
_MOCK_FIO_BASELINE_JSON='{"jobs":[{"read":{"bw":409600,"total_ios":100000,"clat_ns":{"percentile":{"99.000000":3200000}}},"write":{"bw":0,"total_ios":0},"total_io_errors":0}]}'

echo "=========================================="
echo " io_load.sh mock 测试"
echo "=========================================="

# ============================================================
# 1. start_io_load — 命令构造
# ============================================================
echo ""
echo "--- 1. start_io_load 命令构造 ---"

CALLS=()
start_io_load randread 256k 128 >/dev/null 2>&1

# start_io_load 调用序列：
#   1) mkdir
#   2) fio prep（预创建，仅 read 类型）
#   3) nohup fio（后台启动）
#   4) pgrep（在 $(...) 子 shell 中，CALLS 不记录）
# 父 shell 只看到 3 次
[ "${#CALLS[@]}" = 3 ] && ok "start_io_load: ${#CALLS[@]} 次调用 (expected 3)" || fail "start_io_load: ${#CALLS[@]} 次调用"

# 验证 fio 命令参数
# 注意：io_load.sh 用反斜杠续行，合并后 fio 和 --directory 间有多个空格
# 不能用 glob *"fio --directory"*（只匹配单空格），改用 grep
fio_cmd=""
for c in "${CALLS[@]}"; do
    echo "$c" | grep -q "fio.*--directory" && fio_cmd="$c"
done
[ -n "$fio_cmd" ] && ok "start_io_load: 含 fio 命令" || fail "start_io_load: 不含 fio 命令"

echo "$fio_cmd" | grep -q "rw=randread" && ok "start_io_load: rw=randread" || fail "rw"
echo "$fio_cmd" | grep -q "bs=256k" && ok "start_io_load: bs=256k" || fail "bs"
echo "$fio_cmd" | grep -q "numjobs=128" && ok "start_io_load: numjobs=128" || fail "numjobs"
echo "$fio_cmd" | grep -q "ioengine=libaio" && ok "start_io_load: ioengine=libaio" || fail "ioengine"
echo "$fio_cmd" | grep -q "iodepth=128" && ok "start_io_load: iodepth=128" || fail "iodepth"
echo "$fio_cmd" | grep -q "direct=1" && ok "start_io_load: direct=1" || fail "direct"
echo "$fio_cmd" | grep -q "time_based" && ok "start_io_load: time_based" || fail "time_based"
echo "$fio_cmd" | grep -q "runtime=999999" && ok "start_io_load: runtime=999999" || fail "runtime"
echo "$fio_cmd" | grep -q "output-format=json" && ok "start_io_load: output-format=json" || fail "output-format"
echo "$fio_cmd" | grep -q "nohup" && ok "start_io_load: nohup (防 SSH 关闭后死)" || fail "nohup"
echo "$fio_cmd" | grep -q "group_reporting" && ok "start_io_load: group_reporting" || fail "group_reporting"

# 验证 read 测试含 prep（预创建文件，--rw=write）
found_prep=0
for c in "${CALLS[@]}"; do
    echo "$c" | grep -q "fio.*--rw=write" && found_prep=1
done
[ "$found_prep" = 1 ] && ok "start_io_load: randread 含 prep 预创建" || fail "randread 应含 prep"

# 验证 PID 获取
[ "$_IO_FIO_PID" = "12345" ] && ok "start_io_load: PID = 12345" || fail "PID: $_IO_FIO_PID"

# ============================================================
# 2. start_io_load — 单 job 用 psync
# ============================================================
echo ""
echo "--- 2. start_io_load 单 job ---"

CALLS=()
start_io_load seqread 4M 1 >/dev/null 2>&1

fio_cmd2=""
for c in "${CALLS[@]}"; do
    echo "$c" | grep -q "fio.*--directory" && fio_cmd2="$c"
done
echo "$fio_cmd2" | grep -q "ioengine=psync" && ok "单 job: ioengine=psync" || fail "单 job 应 psync"
echo "$fio_cmd2" | grep -q "iodepth=1" && ok "单 job: iodepth=1" || fail "单 job 应 iodepth=1"

# ============================================================
# 3. start_io_load — write 不含 prep
# ============================================================
echo ""
echo "--- 3. start_io_load write 不含 prep ---"

CALLS=()
start_io_load randwrite 256k 128 >/dev/null 2>&1

found_prep=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"--name=prep"* ]] && found_prep=1
done
[ "$found_prep" = 0 ] && ok "randwrite: 不含 prep（fio 自创建）" || fail "randwrite 不应含 prep"

# 验证含 create_on_open
fio_cmd3=""
for c in "${CALLS[@]}"; do
    echo "$c" | grep -q "fio.*--directory" && fio_cmd3="$c"
done
echo "$fio_cmd3" | grep -q "create_on_open=1" && ok "randwrite: 含 create_on_open=1" || fail "randwrite 应含 create_on_open"

# ============================================================
# 4. start_io_load — 未知 type
# ============================================================
echo ""
echo "--- 4. start_io_load 未知 type ---"

CALLS=()
start_io_load invalid 256k 128 2>/dev/null
[ "${#CALLS[@]}" = 0 ] && ok "未知 type: 不产生调用" || fail "未知 type 应不产生调用"

# ============================================================
# 5. stop_io_load — 停止 + 收集
# ============================================================
echo ""
echo "--- 5. stop_io_load ---"

# 先 start
CALLS=()
start_io_load randread 256k 128 >/dev/null 2>&1
CALLS=()
_IO_FIO_JSON=""
stop_io_load >/dev/null 2>&1

# stop_io_load 调用序列：
#   1) kill -INT（前台，CALLS 记录）
#   2) kill -0 检查存活（在 $(...) 子 shell 中，不记录）
#   3) cat result（在 $(...) 子 shell 中，不记录）
# 父 shell 只看到 1 次
[ "${#CALLS[@]}" -ge 1 ] && ok "stop_io_load: ${#CALLS[@]} 次调用 (前台部分)" || fail "stop_io_load: ${#CALLS[@]} 次调用"

# 验证含 SIGINT
found_sigint=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"kill -INT"* ]] && found_sigint=1
done
[ "$found_sigint" = 1 ] && ok "stop_io_load: 发 SIGINT" || fail "stop_io_load: 应发 SIGINT"

# 验证读取了 JSON
[ -n "$_IO_FIO_JSON" ] && ok "stop_io_load: 收集到 JSON" || fail "stop_io_load: 未收集 JSON"

# 验证 PID 清空
[ -z "$_IO_FIO_PID" ] && ok "stop_io_load: PID 已清空" || fail "stop_io_load: PID 未清空"

# ============================================================
# 6. get_io_success_rate — JSON 解析
# ============================================================
echo ""
echo "--- 6. get_io_success_rate ---"

# mock JSON: 150000 total, 1500 errors → (150000-1500)*100/150000 = 99
rate=$(get_io_success_rate)
echo "  rate=$rate"
[ "$rate" = "99" ] && ok "success_rate = 99% (150000 ops, 1500 errs)" || fail "success_rate: expected 99, got $rate"

# ============================================================
# 7. get_io_lat_p99 — JSON 解析
# ============================================================
echo ""
echo "--- 7. get_io_lat_p99 ---"

# mock JSON: clat_ns 99th = 5000000 ns → 5000 us
p99=$(get_io_lat_p99)
echo "  p99=$p99 us"
[ "$p99" = "5000" ] && ok "lat_p99 = 5000us (5000000ns / 1000)" || fail "lat_p99: expected 5000, got $p99"

# ============================================================
# 8. get_io_bw — JSON 解析
# ============================================================
echo ""
echo "--- 8. get_io_bw ---"

# mock JSON: bw = 307200 KiB/s → 300 MiB/s
bw=$(get_io_bw)
echo "  bw=$bw MiB/s"
[ "$bw" = "300" ] && ok "bw = 300 MiB/s (307200 KiB / 1024)" || fail "bw: expected 300, got $bw"

# ============================================================
# 9. 空 JSON 时返回 0
# ============================================================
echo ""
echo "--- 9. 空 JSON 返回 0 ---"

_IO_FIO_JSON=""
[ "$(get_io_success_rate)" = "0" ] && ok "空 JSON: success_rate=0" || fail "空 JSON success_rate"
[ "$(get_io_lat_p99)" = "0" ] && ok "空 JSON: p99=0" || fail "空 JSON p99"
[ "$(get_io_bw)" = "0" ] && ok "空 JSON: bw=0" || fail "空 JSON bw"

# ============================================================
# 10. capture_io_baseline — 命令构造 + 解析
# ============================================================
echo ""
echo "--- 10. capture_io_baseline ---"

CALLS=()
capture_io_baseline >/dev/null 2>&1

# 验证 fio 命令含 runtime=10（短测试）
baseline_cmd=""
for c in "${CALLS[@]}"; do
    [[ "$c" == *"fio"* ]] && baseline_cmd="$c"
done
echo "$baseline_cmd" | grep -q "runtime=10" && ok "baseline: runtime=10s" || fail "baseline: 应 runtime=10"
echo "$baseline_cmd" | grep -q "output-format=json" && ok "baseline: output-format=json" || fail "baseline: 应 json"

# 验证基线值解析
# mock baseline: bw=409600 KiB → 400 MiB, p99=3200000 ns → 3200 us
echo "  baseline_bw=$_IO_BASELINE_BW baseline_p99=$_IO_BASELINE_P99"
[ "$_IO_BASELINE_BW" = "400" ] && ok "baseline: bw=400 MiB/s" || fail "baseline bw: $_IO_BASELINE_BW"
[ "$_IO_BASELINE_P99" = "3200" ] && ok "baseline: p99=3200us" || fail "baseline p99: $_IO_BASELINE_P99"

# get_baseline_bw
bw=$(get_baseline_bw)
[ "$bw" = "400" ] && ok "get_baseline_bw=400" || fail "get_baseline_bw: $bw"


echo ""
echo "=========================================="
echo " 结果: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" = 0 ] && echo "全部通过" || echo "有失败项，检查上方输出"
