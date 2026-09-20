#!/bin/bash
# fio-randrw-bs-sweep.sh — 竞品文件系统 randrw 不同 BS 对比测试
#
# 基于 fio-7item-test.sh 的 randrw 口径，并与 05-1 JuiceFS 标准曲线保持相同矩阵：
#   256K-A → 4K → 16K → 64K → 1M → 4M
#   → 4M → 1M → 64K → 16K → 4K → 256K-B
#
# 2026-09-15 修订（依据 doc/deploy-log/review-05-1-05-1b-audit-and-05-2-20260915.md）：
#   1. 双栏统计：每格同时输出 fio 180s summary 与「实际 timed-I/O 起点 + 重叠加权自然秒」
#      的 [15,175) 正式窗、W1~W4、W4/W1、秒级 CV；
#   2. 精确时间锚：每格落盘 fio-start-epoch-ns.txt / fio-end-epoch-ns.txt，
#      正式窗起点按「fio 完成时刻 − JSON 实际 runtime」复算，登记起点只作交叉检查；
#   3. 漂移裁决：summary.tsv 不再无条件把两个位置平均成单值，改为输出正反位置原始值、
#      位置漂移、首尾 256K 锚漂移与 POINT_USABLE / RANGE_ONLY / MATRIX_DRIFTED；
#   4. 正式负载守卫：runtime/numjobs/iodepth/size 等被改动时标 NOT_COMPARABLE；
#   5. 资产证据：每格落盘 assets-before.tsv / assets-after.tsv（名称+类型+精确字节数）；
#   6. layout 与正式测试分离：建集走独立子命令 layout，且 CREATE_DATASET 默认 0；
#   7. 收尾容错：汇总阶段不再能中止一个已跑完的矩阵；
#   8. --self-test 覆盖分析器（含起点敏感性）与裁决逻辑。
#   9. T-D/D4 补正：未来运行必须显式申报客户端缓存配置，并记录
#      CPU、MemTotal、NIC 与完整挂载选项；历史 RUN 无法由本修订追溯补齐。
#
# 脚本不执行 sudo、drop_caches、mount/卸载、进程终止或数据清理。测试数据只允许是
# TEST_DIR 下精确命名的 rw_test.0.0 ... rw_test.127.0；若完全不存在则拒绝正式运行，
# 请先执行 layout 子命令。结果目录已存在时拒绝覆盖。
#
# 用法（两段式，必须分开执行）：
#   # 第一段：只建数据集并校验，完成后退出
#   TEST_DIR=/mnt/competitor/perf_test CREATE_DATASET=1 \
#   CLIENT_CACHE_CONFIG='vendor-client-cache=<exact deployed value>' \
#   RESULTS=/tmp/fio-randrw-bs-results ./fio-randrw-bs-sweep.sh layout
#
#   # 第二段：正式 12 格矩阵（建议与第一段间隔一段静置时间）
#   TEST_DIR=/mnt/competitor/perf_test \
#   CLIENT_CACHE_CONFIG='vendor-client-cache=<exact deployed value>' \
#   RESULTS=/tmp/fio-randrw-bs-results ./fio-randrw-bs-sweep.sh run
#
#   ./fio-randrw-bs-sweep.sh --self-test
#
# 可调环境变量：
#   TEST_DIR=/mnt/data04/perf_test
#   RESULTS=/tmp/fio-randrw-bs-results   # layout 段写入 ${RESULTS}-layout
#   RUNTIME=180            # 冻结值；改动即 NOT_COMPARABLE
#   SIZE_RND=1G            # 冻结值；改动即 NOT_COMPARABLE
#   NJOBS=128              # 冻结值；改动即 NOT_COMPARABLE
#   IODEPTH=128            # 冻结值；改动即 NOT_COMPARABLE
#   CELL_COOLDOWN=30
#   FREE_SPACE_RESERVE=10G # 创建数据后仍须保留的空间
#   CREATE_DATASET=0       # 仅 layout 子命令使用；1 才允许创建
#   ALLOW_NONCOMPARABLE=0  # 1 才允许在改动冻结负载后继续（结果标 NOT_COMPARABLE）
#   ALLOW_ROOT_FS=0        # 仅明确确认测试根文件系统时才可设为 1
#   FORMAL_START=15        # 冻结值；改动即 NOT_COMPARABLE（仅供离线冒烟自测）
#   FORMAL_STOP=175        # 冻结值；改动即 NOT_COMPARABLE（仅供离线冒烟自测）
#   ANCHOR_DRIFT_MAX=10    # 首尾 256K 锚漂移阈值（%）
#   POSITION_DRIFT_MAX=10  # 同 BS 正反位置漂移阈值（%）
#   CLIENT_CACHE_CONFIG='hpfs cache: ...' # 必填；记录客户端自身缓存配置/状态

set -euo pipefail

TEST_DIR="${TEST_DIR:-/mnt/data04/perf_test}"
RESULTS="${RESULTS:-/tmp/fio-randrw-bs-results}"
RUNTIME="${RUNTIME:-180}"
SIZE_RND="${SIZE_RND:-1G}"
NJOBS="${NJOBS:-128}"
IODEPTH="${IODEPTH:-128}"
CELL_COOLDOWN="${CELL_COOLDOWN:-30}"
FREE_SPACE_RESERVE="${FREE_SPACE_RESERVE:-10G}"
CREATE_DATASET="${CREATE_DATASET:-0}"
ALLOW_NONCOMPARABLE="${ALLOW_NONCOMPARABLE:-0}"
ALLOW_ROOT_FS="${ALLOW_ROOT_FS:-0}"
ANCHOR_DRIFT_MAX="${ANCHOR_DRIFT_MAX:-10}"
POSITION_DRIFT_MAX="${POSITION_DRIFT_MAX:-10}"
CLIENT_CACHE_CONFIG="${CLIENT_CACHE_CONFIG:-UNDECLARED}"

# 与 05-1 JuiceFS 侧逐字一致的冻结负载；任一被改动即不可用于正式对比
FROZEN_RUNTIME=180
FROZEN_SIZE_RND=1G
FROZEN_NJOBS=128
FROZEN_IODEPTH=128
COMPARABLE=1
FROZEN_FORMAL_START=15
FROZEN_FORMAL_STOP=175
# 正式窗同属冻结口径；仅为离线冒烟自测可覆盖，覆盖后一律标 NOT_COMPARABLE
FORMAL_START="${FORMAL_START:-15}"
FORMAL_STOP="${FORMAL_STOP:-175}"

BS_VALUES=(4K 16K 64K 256K 1M 4M)
MATRIX=(
    "256K-A:256K"
    "4K-1:4K"
    "16K-1:16K"
    "64K-1:64K"
    "1M-1:1M"
    "4M-1:4M"
    "4M-2:4M"
    "1M-2:1M"
    "64K-2:64K"
    "16K-2:16K"
    "4K-2:4K"
    "256K-B:256K"
)

OUTDIR=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${OUTDIR}/test.log"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

validate_abs_path() {
    local label="$1" path="$2"
    [[ -n "$path" ]] || die "${label} is empty"
    [[ "$path" == /* ]] || die "${label} must be absolute: ${path}"
    [[ "$path" != "/" ]] || die "${label} must not be /"
    [[ "$path" != "/tmp" && "$path" != "/mnt" ]] || die "${label} is too broad: ${path}"
}

require_commands() {
    local cmd
    for cmd in fio numfmt findmnt find stat awk sed grep tee sha256sum python3 cp \
        pgrep df wc sort xargs hostname uname date; do
        command -v "$cmd" >/dev/null 2>&1 || die "required command missing: ${cmd}"
    done
}

foreign_fio_gate() {
    if pgrep -x fio >/dev/null 2>&1; then
        pgrep -af fio >&2 || true
        die "another fio process is running"
    fi
}

size_bytes() {
    numfmt --from=iec "$1"
}

epoch_ns() {
    date +%s%N
}

# ---------------------------------------------------------------- 冻结负载守卫
comparability_guard() {
    local drift=0 reason=""
    [[ "$RUNTIME" == "$FROZEN_RUNTIME" ]] || { drift=1; reason="${reason}runtime=${RUNTIME} "; }
    [[ "$SIZE_RND" == "$FROZEN_SIZE_RND" ]] || { drift=1; reason="${reason}size=${SIZE_RND} "; }
    [[ "$NJOBS" == "$FROZEN_NJOBS" ]] || { drift=1; reason="${reason}numjobs=${NJOBS} "; }
    [[ "$IODEPTH" == "$FROZEN_IODEPTH" ]] || { drift=1; reason="${reason}iodepth=${IODEPTH} "; }
    [[ "$FORMAL_START" == "$FROZEN_FORMAL_START" ]] || { drift=1; reason="${reason}formal_start=${FORMAL_START} "; }
    [[ "$FORMAL_STOP" == "$FROZEN_FORMAL_STOP" ]] || { drift=1; reason="${reason}formal_stop=${FORMAL_STOP} "; }
    if [[ "$CLIENT_CACHE_CONFIG" == "UNDECLARED" ]]; then
        drift=1
        reason="${reason}client_cache_config=UNDECLARED "
    fi
    if (( drift == 1 )); then
        COMPARABLE=0
        [[ "$ALLOW_NONCOMPARABLE" == 1 ]] || \
            die "frozen comparison load changed (${reason}); set ALLOW_NONCOMPARABLE=1 to proceed with NOT_COMPARABLE results"
    fi
}

# 这些文件只做只读能力快照，不探测或修改网络配置。客户端自身的缓存
# 参数可能不会出现在 findmnt 中，所以由 CLIENT_CACHE_CONFIG 强制显式申报。
record_client_resources() {
    local base iface value
    if command -v lscpu >/dev/null 2>&1; then
        lscpu >"${OUTDIR}/lscpu.txt"
    else
        cp /proc/cpuinfo "${OUTDIR}/cpuinfo.txt"
    fi

    printf 'iface\taddress\toperstate\tspeed_mbps\tduplex\tmtu\n' >"${OUTDIR}/network-interfaces.tsv"
    for base in /sys/class/net/*; do
        [[ -d "$base" ]] || continue
        iface="${base##*/}"
        printf '%s' "$iface" >>"${OUTDIR}/network-interfaces.tsv"
        for value in address operstate speed duplex mtu; do
            if [[ -r "${base}/${value}" ]]; then
                printf '\t%s' "$(<"${base}/${value}")" >>"${OUTDIR}/network-interfaces.tsv"
            else
                printf '\tNA' >>"${OUTDIR}/network-interfaces.tsv"
            fi
        done
        printf '\n' >>"${OUTDIR}/network-interfaces.tsv"
    done

    if command -v ip >/dev/null 2>&1; then
        ip -brief address >"${OUTDIR}/network-addresses.txt" 2>&1 || \
            printf 'ip -brief address failed\n' >"${OUTDIR}/network-addresses.txt"
    else
        printf 'ip command unavailable\n' >"${OUTDIR}/network-addresses.txt"
    fi

    : >"${OUTDIR}/ethtool.txt"
    if command -v ethtool >/dev/null 2>&1; then
        for base in /sys/class/net/*; do
            iface="${base##*/}"
            [[ "$iface" == lo ]] && continue
            printf '### %s\n' "$iface" >>"${OUTDIR}/ethtool.txt"
            ethtool "$iface" >>"${OUTDIR}/ethtool.txt" 2>&1 || true
        done
    else
        printf 'ethtool unavailable\n' >"${OUTDIR}/ethtool.txt"
    fi
}

# ---------------------------------------------------------------- 数据集与资产
dataset_count() {
    find "$TEST_DIR" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '.' | wc -c
}

verify_dataset() {
    local expected_size actual count i file
    expected_size="$(size_bytes "$SIZE_RND")"
    count="$(dataset_count)"
    [[ "$count" -eq "$NJOBS" ]] || die "rw_test expects ${NJOBS} files, found ${count}"
    for ((i=0; i<NJOBS; i++)); do
        file="${TEST_DIR}/rw_test.${i}.0"
        [[ -f "$file" && ! -L "$file" ]] || die "missing or non-regular dataset file: ${file}"
        actual="$(stat -c %s "$file")"
        [[ "$actual" -eq "$expected_size" ]] || \
            die "dataset size mismatch: ${file} actual=${actual} expected=${expected_size}"
    done
}

# 资产清单：名称 + 类型 + 精确字节数，供事后独立审计（不只是运行期校验）
write_asset_manifest() {
    local target="$1" i file
    printf 'name\ttype\tbytes\n' >"$target"
    for ((i=0; i<NJOBS; i++)); do
        file="${TEST_DIR}/rw_test.${i}.0"
        printf '%s\t%s\t%s\n' \
            "rw_test.${i}.0" \
            "$(stat -c %F "$file" | sed 's/ /_/g')" \
            "$(stat -c %s "$file")" >>"$target"
    done
}

record_command() {
    local arg
    for arg in "$@"; do
        printf '%q ' "$arg" >>"${OUTDIR}/commands.sh"
    done
    printf '\n' >>"${OUTDIR}/commands.sh"
}

create_dataset() {
    local count expected_size required_bytes available_bytes reserve_bytes
    count="$(dataset_count)"
    if [[ "$count" -eq "$NJOBS" ]]; then
        verify_dataset
        write_asset_manifest "${OUTDIR}/assets-layout.tsv"
        log "DATASET_REUSE_PASS files=${NJOBS} size=${SIZE_RND}"
        return
    fi
    [[ "$count" -eq 0 ]] || die "partial rw_test dataset found (${count}/${NJOBS}); refusing repair"
    [[ "$CREATE_DATASET" == 1 ]] || die "rw_test dataset absent and CREATE_DATASET=0"

    expected_size="$(size_bytes "$SIZE_RND")"
    required_bytes=$((expected_size * NJOBS))
    reserve_bytes="$(size_bytes "$FREE_SPACE_RESERVE")"
    available_bytes="$(df --output=avail -B1 "$TEST_DIR" | awk 'NR==2 {print $1}')"
    [[ "$available_bytes" =~ ^[0-9]+$ ]] || die "cannot determine free space"
    (( available_bytes >= required_bytes + reserve_bytes )) || \
        die "insufficient free space: available=${available_bytes} required_with_reserve=$((required_bytes + reserve_bytes))"

    log "DATASET_CREATE_START files=${NJOBS} size=${SIZE_RND} bs=4M"
    record_command fio --name=rw_test --directory="$TEST_DIR" \
        --filesize="$SIZE_RND" --size="$SIZE_RND" --bs=4M --rw=write \
        --numjobs="$NJOBS" --fallocate=none --direct=1 --ioengine=libaio \
        --iodepth="$IODEPTH" --group_reporting --end_fsync=1
    fio --name=rw_test --directory="$TEST_DIR" \
        --filesize="$SIZE_RND" --size="$SIZE_RND" --bs=4M --rw=write \
        --numjobs="$NJOBS" --fallocate=none --direct=1 --ioengine=libaio \
        --iodepth="$IODEPTH" --group_reporting --end_fsync=1 \
        --output="${OUTDIR}/layout-fio.json" --output-format=json+
    verify_dataset
    write_asset_manifest "${OUTDIR}/assets-layout.tsv"
    log "DATASET_CREATE_PASS files=${NJOBS} size=${SIZE_RND}"
}

# ---------------------------------------------------------------- 双栏统计分析器
# 输入：cell 目录（fio.json、bw/randrw_bw.*.log、fio-end-epoch-ns.txt）
# 输出：key<TAB>value 到 stdout，并由调用方写入 cell-stats.tsv
# 规则：起点 = fio 完成时刻 − JSON 实际 runtime；逐秒日志按与自然秒的重叠时长加权摊分后
#       对全部 job 求和；正式窗 [15,175)；⛔ 不把第 N 行当第 N 秒。
cell_stats() {
    local cell_dir="$1" expected_jobs="$2" formal_start="$3" formal_stop="$4" end_override="${5:-}"
    python3 - "$cell_dir" "$expected_jobs" "$formal_start" "$formal_stop" "$end_override" <<'PY'
import csv
import glob
import json
import math
import os
import statistics
import sys

cell, expected_jobs, formal_start, formal_stop, end_override = sys.argv[1:6]
expected_jobs = int(expected_jobs)
formal_start = float(formal_start)
formal_stop = float(formal_stop)


def fail(message):
    raise SystemExit("cell_stats: %s" % message)


with open(os.path.join(cell, "fio.json"), encoding="utf-8") as handle:
    data = json.load(handle)
jobs = data.get("jobs")
if not isinstance(jobs, list) or not jobs:
    fail("invalid fio jobs")
if any(int(job.get("error", -1)) != 0 for job in jobs):
    fail("fio job error")

runtimes = [float(job.get(d, {}).get("runtime", 0.0)) for job in jobs for d in ("read", "write")]
runtimes = [value for value in runtimes if value > 0]
if not runtimes:
    fail("directional runtime missing")
runtime_s = max(runtimes) / 1000.0

if end_override:
    end_ns = int(end_override)
else:
    with open(os.path.join(cell, "fio-end-epoch-ns.txt"), encoding="utf-8") as handle:
        end_ns = int(handle.read().strip())
start_ns = end_ns - int(runtime_s * 1_000_000_000)
stated_delta = ""
stated_path = os.path.join(cell, "fio-start-epoch-ns.txt")
if os.path.isfile(stated_path):
    with open(stated_path, encoding="utf-8") as handle:
        stated_delta = "%.3f" % ((start_ns - int(handle.read().strip())) / 1e9)


def summary_bytes(name):
    total = 0.0
    for job in jobs:
        total += float(job.get(name, {}).get("io_bytes", 0.0))
    return total


def summary_field(name, field):
    return sum(float(job.get(name, {}).get(field, 0.0)) for job in jobs)


def clat(name, field):
    values = []
    for job in jobs:
        node = job.get(name, {}).get("clat_ns", {})
        if field == "mean":
            values.append(float(node.get("mean", 0.0)) / 1000.0)
        else:
            values.append(float(node.get("percentile", {}).get(field, 0.0)) / 1000.0)
    return max(values) if values else 0.0


paths = sorted(glob.glob(os.path.join(cell, "bw", "randrw_bw.*.log")))
if not paths:
    single = os.path.join(cell, "bw", "randrw_bw.log")
    if os.path.isfile(single):
        paths = [single]
if not paths:
    fail("bandwidth logs missing")
if len(paths) not in (1, expected_jobs):
    fail("expected %d per-job logs, found %d" % (expected_jobs, len(paths)))

seconds = int(math.ceil(runtime_s))
bins = {0: [0.0] * seconds, 1: [0.0] * seconds}
seen = set()
for path in paths:
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.reader(handle):
            if not row or not row[0].strip():
                continue
            if len(row) < 3:
                fail("short row in %s" % os.path.basename(path))
            end = float(row[0]) / 1000.0
            value = float(row[1]) / 1024.0          # KiB/s -> MiB/s
            direction = int(row[2])
            if direction not in (0, 1):
                fail("invalid direction in %s" % os.path.basename(path))
            seen.add(direction)
            begin = max(0.0, end - 1.0)
            for second in range(int(math.floor(begin)), int(math.ceil(end))):
                if second >= seconds:
                    break
                overlap = min(end, runtime_s, second + 1.0) - max(begin, float(second))
                if overlap > 0:
                    bins[direction][second] += value * overlap
if seen != {0, 1}:
    fail("logs lack READ or WRITE rows")


def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


out = [
    ("comparable_load_runtime_s", "%.3f" % runtime_s),
    ("actual_io_start_epoch_ns", str(start_ns)),
    ("fio_end_epoch_ns", str(end_ns)),
    ("stated_minus_actual_start_s", stated_delta),
    ("bw_log_files", str(len(paths))),
    ("formal_window", "[%g,%g)" % (formal_start, formal_stop)),
]
for direction, label in ((0, "read"), (1, "write")):
    total = summary_bytes(label)
    out.append(("%s_summary_MiB_s" % label, "%.6f" % (total / runtime_s / 1048576.0)))
    out.append(("%s_iops" % label, "%.6f" % summary_field(label, "iops")))
    out.append(("%s_clat_mean_us" % label, "%.6f" % clat(label, "mean")))
    out.append(("%s_clat_p95_us" % label, "%.6f" % clat(label, "95.000000")))
    out.append(("%s_clat_p99_us" % label, "%.6f" % clat(label, "99.000000")))
    window = [bins[direction][s] for s in range(int(formal_start), int(formal_stop))
              if s < seconds]
    expected_window = int(formal_stop) - int(formal_start)
    if len(window) < int(expected_window * 0.9):
        fail("formal coverage too sparse for %s: %d/%d" % (label, len(window), expected_window))
    mean = statistics.mean(window)
    quarters = []
    span = (int(formal_stop) - int(formal_start)) // 4
    for index in range(4):
        chunk = window[index * span:(index + 1) * span]
        quarters.append(statistics.mean(chunk) if chunk else 0.0)
    out.append(("%s_formal_MiB_s" % label, "%.6f" % mean))
    out.append(("%s_formal_median_MiB_s" % label, "%.6f" % statistics.median(window)))
    out.append(("%s_formal_cv" % label,
                "%.6f" % (statistics.pstdev(window) / mean if mean else float("inf"))))
    out.append(("%s_formal_p10_MiB_s" % label, "%.6f" % percentile(window, 0.10)))
    out.append(("%s_formal_p90_MiB_s" % label, "%.6f" % percentile(window, 0.90)))
    for index, value in enumerate(quarters, start=1):
        out.append(("%s_W%d_MiB_s" % (label, index), "%.6f" % value))
    out.append(("%s_W4_W1" % label,
                "%.6f" % (quarters[3] / quarters[0] if quarters[0] else float("inf"))))
    integrated = sum(bins[direction])
    expected = total / 1048576.0
    out.append(("%s_log_vs_io_bytes_pct" % label,
                "%.6f" % ((integrated / expected - 1.0) * 100.0 if expected else float("nan"))))

for key, value in out:
    print("%s\t%s" % (key, value))
PY
}

stat_value() {
    local file="$1" key="$2"
    awk -F '\t' -v k="$key" '$1 == k { print $2; found=1 } END { if (!found) exit 3 }' "$file"
}

# ---------------------------------------------------------------- 单格执行
run_cell() {
    local position="$1" label="$2" bs="$3" cell_dir rc stats
    cell_dir="${OUTDIR}/cells/${position}-${label}"
    [[ ! -e "$cell_dir" ]] || die "cell path already exists: ${cell_dir}"
    mkdir -p "${cell_dir}/bw"
    foreign_fio_gate

    uptime >"${cell_dir}/load-pre.txt"
    df -h "$TEST_DIR" >"${cell_dir}/df-pre.txt"
    findmnt -T "$TEST_DIR" -o SOURCE,TARGET,FSTYPE,OPTIONS >"${cell_dir}/findmnt.txt"
    write_asset_manifest "${cell_dir}/assets-before.tsv"
    log ">>> position=${position} cell=${label} bs=${bs}"

    record_command fio --name=rw_test --directory="$TEST_DIR" \
        --filesize="$SIZE_RND" --size="$SIZE_RND" --bs="$bs" \
        --rw=randrw --rwmixread=50 --ioengine=libaio --iodepth="$IODEPTH" \
        --numjobs="$NJOBS" --direct=1 --fallocate=none --allow_file_create=0 \
        --openfiles="$NJOBS" --group_reporting --time_based --runtime="$RUNTIME" \
        --randrepeat=1 --write_bw_log="${cell_dir}/bw/randrw" \
        --log_avg_msec=1000 --per_job_logs=1 --output="${cell_dir}/fio.json" \
        --output-format=json+

    epoch_ns >"${cell_dir}/fio-start-epoch-ns.txt"
    set +e
    fio --name=rw_test --directory="$TEST_DIR" \
        --filesize="$SIZE_RND" --size="$SIZE_RND" --bs="$bs" \
        --rw=randrw --rwmixread=50 --ioengine=libaio --iodepth="$IODEPTH" \
        --numjobs="$NJOBS" --direct=1 --fallocate=none --allow_file_create=0 \
        --openfiles="$NJOBS" --group_reporting --time_based --runtime="$RUNTIME" \
        --randrepeat=1 --write_bw_log="${cell_dir}/bw/randrw" \
        --log_avg_msec=1000 --per_job_logs=1 \
        --output="${cell_dir}/fio.json" --output-format=json+
    rc=$?
    set -e
    epoch_ns >"${cell_dir}/fio-end-epoch-ns.txt"
    printf '%s\n' "$rc" >"${cell_dir}/fio.rc"
    [[ "$rc" -eq 0 ]] || die "fio failed at ${label}, rc=${rc}"

    cell_stats "$cell_dir" "$NJOBS" "$FORMAL_START" "$FORMAL_STOP" \
        >"${cell_dir}/cell-stats.tsv" || die "cell_stats failed at ${label}"

    stats="${cell_dir}/cell-stats.tsv"
    printf '%s\t%s\t%s' "$position" "$label" "$bs" >>"${OUTDIR}/results.tsv"
    local key
    for key in read_summary_MiB_s write_summary_MiB_s \
        read_formal_MiB_s write_formal_MiB_s \
        read_formal_cv write_formal_cv read_W4_W1 write_W4_W1 \
        read_iops write_iops read_clat_mean_us write_clat_mean_us \
        read_clat_p95_us write_clat_p95_us read_clat_p99_us write_clat_p99_us \
        read_log_vs_io_bytes_pct stated_minus_actual_start_s; do
        printf '\t%s' "$(stat_value "$stats" "$key")" >>"${OUTDIR}/results.tsv"
    done
    printf '\n' >>"${OUTDIR}/results.tsv"

    uptime >"${cell_dir}/load-post.txt"
    df -h "$TEST_DIR" >"${cell_dir}/df-post.txt"
    write_asset_manifest "${cell_dir}/assets-after.tsv"
    verify_dataset
    log "<<< ${label} PASS summary_READ=$(stat_value "$stats" read_summary_MiB_s) formal_READ=$(stat_value "$stats" read_formal_MiB_s) MiB/s"
}

# ---------------------------------------------------------------- 汇总与漂移裁决
# ⛔ 本阶段不得中止一个已跑完的矩阵：缺 BS 只记 MISSING，退出码延后到最后返回。
write_summary() {
    local status=0
    python3 - "${OUTDIR}" "$ANCHOR_DRIFT_MAX" "$POSITION_DRIFT_MAX" "$COMPARABLE" \
        "${BS_VALUES[@]}" <<'PY' || status=$?
import csv
import os
import sys

outdir, anchor_max, position_max, comparable = sys.argv[1:5]
bs_values = sys.argv[5:]
anchor_max = float(anchor_max)
position_max = float(position_max)
comparable = comparable == "1"

rows = []
with open(os.path.join(outdir, "results.tsv"), newline="", encoding="utf-8") as handle:
    for row in csv.DictReader(handle, delimiter="\t"):
        rows.append(row)


def number(row, key):
    try:
        return float(row[key])
    except (TypeError, ValueError, KeyError):
        return None


def drift(first, last):
    if first in (None, 0) or last is None:
        return None
    return (last / first - 1.0) * 100.0


# 首尾 256K 锚：矩阵级状态漂移
anchor_a = next((r for r in rows if r["cell"] == "256K-A"), None)
anchor_b = next((r for r in rows if r["cell"] == "256K-B"), None)
matrix_verdict = "MATRIX_ANCHOR_MISSING"
anchor_lines = []
if anchor_a and anchor_b:
    worst = 0.0
    for stat in ("summary", "formal"):
        for label in ("read", "write"):
            key = "%s_%s_MiB_s" % (label, stat)
            value = drift(number(anchor_a, key), number(anchor_b, key))
            anchor_lines.append((stat, label, number(anchor_a, key),
                                 number(anchor_b, key), value))
            if value is not None:
                worst = max(worst, abs(value))
    matrix_verdict = "MATRIX_DRIFTED" if worst > anchor_max else "MATRIX_STABLE"

with open(os.path.join(outdir, "anchors.tsv"), "w", encoding="utf-8") as handle:
    handle.write("stat\tdirection\t256K_A_MiB_s\t256K_B_MiB_s\tanchor_drift_pct\n")
    for stat, label, first, last, value in anchor_lines:
        handle.write("%s\t%s\t%s\t%s\t%s\n" % (
            stat, label,
            "" if first is None else "%.6f" % first,
            "" if last is None else "%.6f" % last,
            "" if value is None else "%.6f" % value))

missing = []
with open(os.path.join(outdir, "summary.tsv"), "w", encoding="utf-8") as handle:
    handle.write("bs\tstat\tpoints\tread_pos1\tread_pos2\tread_drift_pct"
                 "\twrite_pos1\twrite_pos2\twrite_drift_pct\tread_range\twrite_range"
                 "\tverdict\tcomparable\n")
    for bs in bs_values:
        cells = [r for r in rows if r["bs"] == bs]
        if len(cells) < 2:
            missing.append(bs)
            handle.write("%s\tNA\t%d\t\t\t\t\t\t\t\t\tMISSING\t%s\n"
                         % (bs, len(cells), "YES" if comparable else "NOT_COMPARABLE"))
            continue
        for stat in ("summary", "formal"):
            read_key = "read_%s_MiB_s" % stat
            write_key = "write_%s_MiB_s" % stat
            r1, r2 = number(cells[0], read_key), number(cells[1], read_key)
            w1, w2 = number(cells[0], write_key), number(cells[1], write_key)
            rd, wd = drift(r1, r2), drift(w1, w2)
            worst = max(abs(rd or 0.0), abs(wd or 0.0))
            if matrix_verdict == "MATRIX_DRIFTED":
                verdict = "MATRIX_DRIFTED"
            elif worst > position_max:
                verdict = "RANGE_ONLY"
            else:
                verdict = "POINT_USABLE"
            handle.write("%s\t%s\t%d\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f"
                         "\t%.6f--%.6f\t%.6f--%.6f\t%s\t%s\n"
                         % (bs, stat, len(cells), r1, r2, rd, w1, w2, wd,
                            min(r1, r2), max(r1, r2), min(w1, w2), max(w1, w2),
                            verdict, "YES" if comparable else "NOT_COMPARABLE"))

with open(os.path.join(outdir, "verdict.tsv"), "w", encoding="utf-8") as handle:
    handle.write("key\tvalue\n")
    handle.write("matrix_verdict\t%s\n" % matrix_verdict)
    handle.write("anchor_drift_max_pct\t%.6f\n" % anchor_max)
    handle.write("position_drift_max_pct\t%.6f\n" % position_max)
    handle.write("comparable\t%s\n" % ("YES" if comparable else "NOT_COMPARABLE"))
    handle.write("missing_bs\t%s\n" % (",".join(missing) if missing else "NONE"))
    handle.write("cells\t%d\n" % len(rows))
    handle.write("comparison_rule\ttwo_column_same_sign_and_beyond_combined_noise\n")

if missing:
    raise SystemExit(3)
PY
    if (( status != 0 )); then
        log "SUMMARY_INCOMPLETE status=${status}（已保留全部 cell 与 results.tsv，见 verdict.tsv 的 missing_bs）"
    fi
    return "$status"
}

# ---------------------------------------------------------------- preflight
preflight_common() {
    validate_abs_path TEST_DIR "$TEST_DIR"
    validate_abs_path RESULTS "$RESULTS"
    is_uint "$RUNTIME" || die "RUNTIME must be a positive integer"
    is_uint "$NJOBS" || die "NJOBS must be a positive integer"
    is_uint "$IODEPTH" || die "IODEPTH must be a positive integer"
    is_uint "$CELL_COOLDOWN" || die "CELL_COOLDOWN must be a positive integer"
    [[ "$CREATE_DATASET" == 0 || "$CREATE_DATASET" == 1 ]] || die "CREATE_DATASET must be 0 or 1"
    [[ "$ALLOW_ROOT_FS" == 0 || "$ALLOW_ROOT_FS" == 1 ]] || die "ALLOW_ROOT_FS must be 0 or 1"
    [[ "$ALLOW_NONCOMPARABLE" == 0 || "$ALLOW_NONCOMPARABLE" == 1 ]] || \
        die "ALLOW_NONCOMPARABLE must be 0 or 1"
    [[ "$CLIENT_CACHE_CONFIG" != *$'\t'* && "$CLIENT_CACHE_CONFIG" != *$'\n'* ]] || \
        die "CLIENT_CACHE_CONFIG must be a single-line value without tabs"
    require_commands
    foreign_fio_gate
    comparability_guard

    [[ -d "$TEST_DIR" ]] || die "TEST_DIR does not exist: ${TEST_DIR}"
    local mount_target
    mount_target="$(findmnt -T "$TEST_DIR" -n -o TARGET)"
    [[ -n "$mount_target" ]] || die "cannot resolve filesystem for TEST_DIR"
    if [[ "$mount_target" == / && "$ALLOW_ROOT_FS" != 1 ]]; then
        die "TEST_DIR resolves to root filesystem; refusing unless ALLOW_ROOT_FS=1"
    fi
    [[ -w "$TEST_DIR" ]] || die "TEST_DIR is not writable: ${TEST_DIR}"
    [[ ! -e "$OUTDIR" ]] || die "output directory already exists: ${OUTDIR}"
    mkdir -p "$OUTDIR"

    {
        printf 'key\tvalue\n'
        printf 'test_dir\t%s\n' "$TEST_DIR"
        printf 'outdir\t%s\n' "$OUTDIR"
        printf 'runtime_s\t%s\n' "$RUNTIME"
        printf 'filesize\t%s\n' "$SIZE_RND"
        printf 'numjobs\t%s\n' "$NJOBS"
        printf 'iodepth\t%s\n' "$IODEPTH"
        printf 'cell_cooldown_s\t%s\n' "$CELL_COOLDOWN"
        printf 'free_space_reserve\t%s\n' "$FREE_SPACE_RESERVE"
        printf 'create_dataset\t%s\n' "$CREATE_DATASET"
        printf 'comparable_load\t%s\n' "$([[ "$COMPARABLE" == 1 ]] && printf 'YES' || printf 'NOT_COMPARABLE')"
        printf 'formal_window\t[%s,%s)\n' "$FORMAL_START" "$FORMAL_STOP"
        printf 'anchor_drift_max_pct\t%s\n' "$ANCHOR_DRIFT_MAX"
        printf 'position_drift_max_pct\t%s\n' "$POSITION_DRIFT_MAX"
        printf 'hostname\t%s\n' "$(hostname)"
        printf 'fio_version\t%s\n' "$(fio --version)"
        printf 'kernel\t%s\n' "$(uname -r)"
        printf 'memtotal_kib\t%s\n' "$(awk '$1 == "MemTotal:" {print $2}' /proc/meminfo)"
        printf 'cpu_logical_count\t%s\n' "$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo)"
        printf 'cpu_model\t%s\n' "$(awk -F: '$1 ~ /^model name[[:space:]]*$/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)"
        printf 'mount_source\t%s\n' "$(findmnt -T "$TEST_DIR" -n -o SOURCE)"
        printf 'mount_target\t%s\n' "$(findmnt -T "$TEST_DIR" -n -o TARGET)"
        printf 'mount_fstype\t%s\n' "$(findmnt -T "$TEST_DIR" -n -o FSTYPE)"
        printf 'mount_options\t%s\n' "$(findmnt -T "$TEST_DIR" -n -o OPTIONS)"
        printf 'client_cache_config\t%s\n' "$CLIENT_CACHE_CONFIG"
        printf 'script_sha256\t%s\n' "$(sha256sum "$0" | awk '{print $1}')"
    } >"${OUTDIR}/environment.tsv"
    record_client_resources
    findmnt -T "$TEST_DIR" -o SOURCE,TARGET,FSTYPE,OPTIONS >"${OUTDIR}/findmnt.txt"
    df -h "$TEST_DIR" >"${OUTDIR}/df-start.txt"
    printf '#!/bin/bash\n# Commands actually executed; values are shell-escaped.\n' >"${OUTDIR}/commands.sh"
}

finalize() {
    df -h "$TEST_DIR" >"${OUTDIR}/df-end.txt"
    # 清单使用相对路径，保证结果目录复制到持久化位置后仍可直接校验。
    # 调用方必须在 finalize 前完成所有写入；本函数返回后不得再改写 OUTDIR 内文件。
    (
        cd "$OUTDIR"
        find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
    )
}

# ---------------------------------------------------------------- 子命令
run_layout() {
    OUTDIR="${RESULTS%/}-layout"
    preflight_common
    log "RANDRW_BS_LAYOUT_START test_dir=${TEST_DIR} outdir=${OUTDIR}"
    create_dataset
    log "RANDRW_BS_LAYOUT_PASS outdir=${OUTDIR}"
    finalize
    printf '\n数据集已就绪并校验。请静置一段时间后，另起一次命令执行正式矩阵：\n'
    printf '  TEST_DIR=%q RESULTS=%q %q run\n' "$TEST_DIR" "$RESULTS" "$0"
}

run_matrix() {
    local position=0 entry label bs count summary_status=0
    OUTDIR="$RESULTS"
    preflight_common
    log "RANDRW_BS_SWEEP_START test_dir=${TEST_DIR} results=${OUTDIR}"

    # 正式矩阵绝不建数据：layout 与正式测试必须分离
    count="$(dataset_count)"
    [[ "$count" -eq "$NJOBS" ]] || \
        die "dataset not ready (${count}/${NJOBS}); run the 'layout' subcommand first"
    verify_dataset
    write_asset_manifest "${OUTDIR}/assets-start.tsv"

    printf 'position\tcell\tbs\tread_summary_MiB_s\twrite_summary_MiB_s\tread_formal_MiB_s\twrite_formal_MiB_s\tread_formal_cv\twrite_formal_cv\tread_W4_W1\twrite_W4_W1\tread_iops\twrite_iops\tread_clat_mean_us\twrite_clat_mean_us\tread_clat_p95_us\twrite_clat_p95_us\tread_clat_p99_us\twrite_clat_p99_us\tread_log_vs_io_bytes_pct\tstated_minus_actual_start_s\n' \
        >"${OUTDIR}/results.tsv"

    for entry in "${MATRIX[@]}"; do
        position=$((position + 1))
        label="${entry%%:*}"
        bs="${entry##*:}"
        run_cell "$position" "$label" "$bs"
        if (( position < ${#MATRIX[@]} )); then
            log "cooldown ${CELL_COOLDOWN}s"
            sleep "$CELL_COOLDOWN"
        fi
    done

    write_asset_manifest "${OUTDIR}/assets-end.tsv"
    write_summary || summary_status=$?
    if (( summary_status == 0 )); then
        log "RANDRW_BS_SWEEP_PASS results=${OUTDIR}"
    else
        log "RANDRW_BS_SWEEP_INCOMPLETE summary_status=${summary_status} results=${OUTDIR}"
    fi
    finalize
    printf '\nVerdict:\n'
    column -t -s $'\t' "${OUTDIR}/verdict.tsv" 2>/dev/null || cat "${OUTDIR}/verdict.tsv"
    printf '\nSummary:\n'
    column -t -s $'\t' "${OUTDIR}/summary.tsv" 2>/dev/null || cat "${OUTDIR}/summary.tsv"
    (( summary_status == 0 )) || return "$summary_status"
}

# ---------------------------------------------------------------- 自测
# 覆盖：矩阵形状、危险操作扫描、分析器（含起点敏感性）、漂移裁决三态。
make_fixture_cell() {
    local dir="$1" jobs="$2" ramp_zero_s="$3" seconds=180
    mkdir -p "${dir}/bw"
    local read_mib=1 write_mib=1 job second value_r value_w total_r total_w
    total_r=0
    total_w=0
    for ((job=1; job<=jobs; job++)); do
        : >"${dir}/bw/randrw_bw.${job}.log"
        for ((second=1; second<=seconds; second++)); do
            if (( second <= ramp_zero_s )); then
                value_r=0
                value_w=0
            else
                value_r=$((read_mib * 1024))
                value_w=$((write_mib * 1024))
            fi
            printf '%d, %d, 0, 4096, 0\n' $((second * 1000)) "$value_r" >>"${dir}/bw/randrw_bw.${job}.log"
            printf '%d, %d, 1, 4096, 0\n' $((second * 1000)) "$value_w" >>"${dir}/bw/randrw_bw.${job}.log"
        done
    done
    total_r=$(( (seconds - ramp_zero_s) * read_mib * 1048576 * jobs ))
    total_w=$(( (seconds - ramp_zero_s) * write_mib * 1048576 * jobs ))
    python3 - "$dir" "$total_r" "$total_w" "$seconds" <<'PY'
import json
import sys

path, total_r, total_w, seconds = sys.argv[1:5]
job = {
    "error": 0,
    "read": {"runtime": int(seconds) * 1000, "io_bytes": int(total_r), "iops": 1.0,
             "clat_ns": {"mean": 1000.0, "percentile": {"95.000000": 2000.0,
                                                        "99.000000": 3000.0}}},
    "write": {"runtime": int(seconds) * 1000, "io_bytes": int(total_w), "iops": 1.0,
              "clat_ns": {"mean": 1000.0, "percentile": {"95.000000": 2000.0,
                                                         "99.000000": 3000.0}}},
}
with open("%s/fio.json" % path, "w", encoding="utf-8") as handle:
    json.dump({"jobs": [job]}, handle)
PY
    printf '%d\n' 1700000000000000000 >"${dir}/fio-end-epoch-ns.txt"
}

self_test() {
    [[ "${#MATRIX[@]}" -eq 12 ]] || die "matrix cell count mismatch"
    [[ "${MATRIX[0]}" == "256K-A:256K" ]] || die "first anchor mismatch"
    [[ "${MATRIX[11]}" == "256K-B:256K" ]] || die "last anchor mismatch"
    local bs count entry
    for bs in "${BS_VALUES[@]}"; do
        count=0
        for entry in "${MATRIX[@]}"; do
            [[ "${entry##*:}" == "$bs" ]] && count=$((count + 1))
        done
        [[ "$count" -eq 2 ]] || die "matrix repetition mismatch for ${bs}"
    done
    if grep -nE '(^|[[:space:]])sudo([[:space:]]|$)|drop_caches|rm[[:space:]]+-rf|reboot|shutdown|poweroff|wipefs|mkfs|umount|kill[[:space:]]' "$0" \
        | grep -vE '^([0-9]+:)?#|global drop_caches|sudo、drop_caches|rm -rf|grep -nE|grep -vE' >/dev/null; then
        die "forbidden operation found"
    fi
    if grep -nE 'CREATE_DATASET:[-]1' "$0" >/dev/null; then
        die "CREATE_DATASET must default to 0"
    fi

    local tmp cell out mean w4w1 shifted
    tmp="$(mktemp -d)"   # 只写临时目录，⛔ 本脚本不做任何递归删除；路径在结尾打印

    # A) 常量序列：正式窗均值 = jobs × 1 MiB/s，W4/W1 = 1，CV = 0
    cell="${tmp}/const"
    make_fixture_cell "$cell" 2 0
    out="$(cell_stats "$cell" 2 "$FORMAL_START" "$FORMAL_STOP")"
    printf '%s\n' "$out" >"${tmp}/const.tsv"
    mean="$(stat_value "${tmp}/const.tsv" read_formal_MiB_s)"
    w4w1="$(stat_value "${tmp}/const.tsv" read_W4_W1)"
    awk -v m="$mean" 'BEGIN { exit !(m > 1.99 && m < 2.01) }' || die "analyzer mean wrong: ${mean}"
    awk -v v="$w4w1" 'BEGIN { exit !(v > 0.999 && v < 1.001) }' || die "analyzer W4/W1 wrong: ${w4w1}"
    awk -v v="$(stat_value "${tmp}/const.tsv" read_formal_cv)" \
        'BEGIN { exit !(v < 1e-6) }' || die "analyzer CV wrong"
    awk -v v="$(stat_value "${tmp}/const.tsv" read_summary_MiB_s)" \
        'BEGIN { exit !(v > 1.99 && v < 2.01) }' || die "analyzer summary wrong"

    # B) 窗口边界：ramp 前 30 s 为零时，正式窗均值必须精确等于解析值
    #    (160 - 15) / 160 * 2 MiB/s = 1.8125 —— 可捕获窗口 off-by-one 与多 job 汇总错误
    cell="${tmp}/ramp"
    make_fixture_cell "$cell" 2 30
    out="$(cell_stats "$cell" 2 "$FORMAL_START" "$FORMAL_STOP")"
    printf '%s\n' "$out" >"${tmp}/ramp.tsv"
    mean="$(stat_value "${tmp}/ramp.tsv" read_formal_MiB_s)"
    awk -v m="$mean" 'BEGIN { exit !(m > 1.8120 && m < 1.8130) }' \
        || die "formal window boundary wrong: ${mean} (expected 1.8125)"

    # C) 起点交叉检查必须活着：正式窗按 fio 日志自身的相对时间分箱，
    #    epoch 锚点用于「登记起点 vs 实际起点」的交叉检查与外部采样器对齐；
    #    因此把结束锚点推后 58 s 时，stated_minus_actual_start_s 必须同步变化约 58 s。
    mean="$(stat_value "${tmp}/ramp.tsv" stated_minus_actual_start_s)"
    printf '%d\n' 1700000000000000000 >"${tmp}/ramp/fio-start-epoch-ns.txt"
    out="$(cell_stats "${tmp}/ramp" 2 "$FORMAL_START" "$FORMAL_STOP")"
    printf '%s\n' "$out" >"${tmp}/ramp-anchor.tsv"
    mean="$(stat_value "${tmp}/ramp-anchor.tsv" stated_minus_actual_start_s)"
    out="$(cell_stats "${tmp}/ramp" 2 "$FORMAL_START" "$FORMAL_STOP" 1700000058000000000)"
    printf '%s\n' "$out" >"${tmp}/ramp-anchor-shift.tsv"
    shifted="$(stat_value "${tmp}/ramp-anchor-shift.tsv" stated_minus_actual_start_s)"
    awk -v a="$mean" -v b="$shifted" \
        'BEGIN { d = b - a; exit !(d > 57.9 && d < 58.1) }' \
        || die "start-anchor cross-check dead: ${mean} vs ${shifted}"

    # D) 多 job 汇总：1 job 与 2 job 的正式窗均值必须成 1:2
    cell="${tmp}/one"
    make_fixture_cell "$cell" 1 0
    out="$(cell_stats "$cell" 1 "$FORMAL_START" "$FORMAL_STOP")"
    printf '%s\n' "$out" >"${tmp}/one.tsv"
    awk -v v="$(stat_value "${tmp}/one.tsv" read_formal_MiB_s)" \
        'BEGIN { exit !(v > 0.999 && v < 1.001) }' || die "per-job aggregation wrong"

    # E) 漂移裁决三态（各用独立子目录，避免任何删除操作）
    _selftest_verdict "${tmp}/v-point" 1000 1000 1000 1000 POINT_USABLE
    _selftest_verdict "${tmp}/v-range" 1000 1000 1000 800 RANGE_ONLY
    _selftest_verdict "${tmp}/v-matrix" 1000 800 1000 1000 MATRIX_DRIFTED

    printf 'RANDRW_BS_SWEEP_SELF_TEST_PASS cells=12 bs=4K,16K,64K,256K,1M,4M destructive_ops=0 analyzer=OK window=OK anchor=OK verdict=OK\n'
    printf 'self-test scratch dir (safe to remove manually): %s\n' "$tmp"
}

# 构造最小 results.tsv（只含 256K 锚与一个 4K 正反位置）并断言裁决
_selftest_verdict() {
    local dir="$1" anchor_a="$2" anchor_b="$3" bs_pos1="$4" bs_pos2="$5" expect="$6"
    local saved_outdir="$OUTDIR" saved_bs=("${BS_VALUES[@]}") got
    [[ ! -e "$dir" ]] || die "self-test scratch path already exists: ${dir}"
    mkdir -p "$dir"
    OUTDIR="$dir"
    BS_VALUES=(4K 256K)
    {
        printf 'position\tcell\tbs\tread_summary_MiB_s\twrite_summary_MiB_s\tread_formal_MiB_s\twrite_formal_MiB_s\n'
        printf '1\t256K-A\t256K\t%s\t%s\t%s\t%s\n' "$anchor_a" "$anchor_a" "$anchor_a" "$anchor_a"
        printf '2\t4K-1\t4K\t%s\t%s\t%s\t%s\n' "$bs_pos1" "$bs_pos1" "$bs_pos1" "$bs_pos1"
        printf '3\t4K-2\t4K\t%s\t%s\t%s\t%s\n' "$bs_pos2" "$bs_pos2" "$bs_pos2" "$bs_pos2"
        printf '4\t256K-B\t256K\t%s\t%s\t%s\t%s\n' "$anchor_b" "$anchor_b" "$anchor_b" "$anchor_b"
    } >"${dir}/results.tsv"
    : >"${dir}/test.log"
    write_summary >/dev/null
    got="$(awk -F '\t' '$1 == "4K" && $2 == "formal" { print $12 }' "${dir}/summary.tsv")"
    [[ "$got" == "$expect" ]] || die "verdict mismatch: expected ${expect}, got ${got}"
    OUTDIR="$saved_outdir"
    BS_VALUES=("${saved_bs[@]}")
}

case "${1:-}" in
    layout) run_layout ;;
    run) run_matrix ;;
    --self-test) self_test ;;
    *)
        printf 'Usage:\n' >&2
        printf '  TEST_DIR=/absolute/path [RESULTS=/tmp/fio-randrw-bs-results] CREATE_DATASET=1 %s layout\n' "$0" >&2
        printf '  TEST_DIR=/absolute/path [RESULTS=/tmp/fio-randrw-bs-results] %s run\n' "$0" >&2
        printf '  %s --self-test\n' "$0" >&2
        exit 2
        ;;
esac
