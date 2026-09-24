#!/bin/bash
# Common engine for competitor filesystem block-size sweeps.
# Do not invoke directly: use one of fio-{seqread,seqwrite,mseqread,mseqwrite,
# randread,randwrite}-bs-sweep.sh.
#
# Safety contract:
# - no sudo, drop_caches, mount/umount, kill, service/device operation or deletion;
# - layout and measured run are separate commands;
# - run never creates or repairs data files;
# - existing result paths and partial data sets are refused, never overwritten.

set -euo pipefail

PROFILE="${PROFILE:-}"
ENTRY_SCRIPT="${ENTRY_SCRIPT:-$0}"
TEST_DIR="${TEST_DIR:-/mnt/data04/perf_test}"
RUNTIME="${RUNTIME:-180}"
CELL_COOLDOWN="${CELL_COOLDOWN:-30}"
FREE_SPACE_RESERVE="${FREE_SPACE_RESERVE:-10G}"
CREATE_DATASET="${CREATE_DATASET:-0}"
ALLOW_NONCOMPARABLE="${ALLOW_NONCOMPARABLE:-0}"
ALLOW_ROOT_FS="${ALLOW_ROOT_FS:-0}"
FORMAL_START="${FORMAL_START:-15}"
FORMAL_STOP="${FORMAL_STOP:-175}"
ANCHOR_DRIFT_MAX="${ANCHOR_DRIFT_MAX:-10}"
POSITION_DRIFT_MAX="${POSITION_DRIFT_MAX:-10}"
CLIENT_CACHE_CONFIG="${CLIENT_CACHE_CONFIG:-UNDECLARED}"

FROZEN_RUNTIME=180
FROZEN_FORMAL_START=15
FROZEN_FORMAL_STOP=175
COMPARABLE=1
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
    [[ "$path" != / && "$path" != /tmp && "$path" != /mnt ]] || \
        die "${label} is too broad: ${path}"
}

size_bytes() {
    numfmt --from=iec "$1"
}

epoch_ns() {
    date +%s%N
}

foreign_fio_gate() {
    if pgrep -x fio >/dev/null 2>&1; then
        pgrep -af fio >&2 || true
        die "another fio process is running"
    fi
}

require_commands() {
    local command_name
    for command_name in fio numfmt findmnt find stat awk sed grep tee sha256sum \
        python3 cp pgrep df wc sort xargs hostname uname date realpath; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "required command missing: ${command_name}"
    done
}

load_profile() {
    case "$PROFILE" in
        randread)
            DIRECTION=read; RW_MODE=randread; JOB_NAME=read_test
            DATASET_SUBDIR=""; FILE_SIZE="${SIZE_RND:-1G}"
            NUMJOBS="${NJOBS_RND:-128}"; IODEPTH="${IODEPTH_RND:-128}"
            IOENGINE=libaio; REFILL=0; END_FSYNC=0
            FROZEN_SIZE=1G; FROZEN_NUMJOBS=128; FROZEN_IODEPTH=128
            BS_VALUES=(4K 16K 64K 256K 1M 4M)
            MATRIX=(256K-A:256K 4K-1:4K 16K-1:16K 64K-1:64K 1M-1:1M 4M-1:4M
                    4M-2:4M 1M-2:1M 64K-2:64K 16K-2:16K 4K-2:4K 256K-B:256K)
            ;;
        randwrite)
            DIRECTION=write; RW_MODE=randwrite; JOB_NAME=storage_test
            DATASET_SUBDIR=""; FILE_SIZE="${SIZE_RND:-1G}"
            NUMJOBS="${NJOBS_RND:-128}"; IODEPTH="${IODEPTH_RND:-128}"
            IOENGINE=libaio; REFILL=0; END_FSYNC=0
            FROZEN_SIZE=1G; FROZEN_NUMJOBS=128; FROZEN_IODEPTH=128
            BS_VALUES=(4K 16K 64K 256K 1M 4M)
            MATRIX=(256K-A:256K 4K-1:4K 16K-1:16K 64K-1:64K 1M-1:1M 4M-1:4M
                    4M-2:4M 1M-2:1M 64K-2:64K 16K-2:16K 4K-2:4K 256K-B:256K)
            ;;
        seqread)
            DIRECTION=read; RW_MODE=read; JOB_NAME=seqread
            DATASET_SUBDIR=seqread; FILE_SIZE="${SIZE_SEQ_SINGLE:-32G}"
            NUMJOBS=1; IODEPTH=1; IOENGINE=psync; REFILL=1; END_FSYNC=0
            FROZEN_SIZE=32G; FROZEN_NUMJOBS=1; FROZEN_IODEPTH=1
            BS_VALUES=(64K 256K 1M 4M 16M)
            MATRIX=(256K-A:256K 64K-1:64K 1M-1:1M 4M-1:4M 16M-1:16M
                    16M-2:16M 4M-2:4M 1M-2:1M 64K-2:64K 256K-B:256K)
            ;;
        seqwrite)
            DIRECTION=write; RW_MODE=write; JOB_NAME=seqwrite
            DATASET_SUBDIR=seqwrite; FILE_SIZE="${SIZE_SEQ_SINGLE:-32G}"
            NUMJOBS=1; IODEPTH=1; IOENGINE=psync; REFILL=1; END_FSYNC=1
            FROZEN_SIZE=32G; FROZEN_NUMJOBS=1; FROZEN_IODEPTH=1
            BS_VALUES=(64K 256K 1M 4M 16M)
            MATRIX=(256K-A:256K 64K-1:64K 1M-1:1M 4M-1:4M 16M-1:16M
                    16M-2:16M 4M-2:4M 1M-2:1M 64K-2:64K 256K-B:256K)
            ;;
        mseqread)
            DIRECTION=read; RW_MODE=read; JOB_NAME=mseqread
            DATASET_SUBDIR=mseqread; FILE_SIZE="${SIZE_SEQ_MULTI:-4G}"
            NUMJOBS="${NJOBS_SEQ:-16}"; IODEPTH=1
            IOENGINE=psync; REFILL=1; END_FSYNC=0
            FROZEN_SIZE=4G; FROZEN_NUMJOBS=16; FROZEN_IODEPTH=1
            BS_VALUES=(64K 256K 1M 4M 16M)
            MATRIX=(256K-A:256K 64K-1:64K 1M-1:1M 4M-1:4M 16M-1:16M
                    16M-2:16M 4M-2:4M 1M-2:1M 64K-2:64K 256K-B:256K)
            ;;
        mseqwrite)
            DIRECTION=write; RW_MODE=write; JOB_NAME=mseqwrite
            DATASET_SUBDIR=mseqwrite; FILE_SIZE="${SIZE_SEQ_MULTI:-4G}"
            NUMJOBS="${NJOBS_SEQ:-16}"; IODEPTH=1
            IOENGINE=psync; REFILL=1; END_FSYNC=1
            FROZEN_SIZE=4G; FROZEN_NUMJOBS=16; FROZEN_IODEPTH=1
            BS_VALUES=(64K 256K 1M 4M 16M)
            MATRIX=(256K-A:256K 64K-1:64K 1M-1:1M 4M-1:4M 16M-1:16M
                    16M-2:16M 4M-2:4M 1M-2:1M 64K-2:64K 256K-B:256K)
            ;;
        *) die "unsupported PROFILE=${PROFILE:-empty}" ;;
    esac

    TEST_DIR="${TEST_DIR%/}"
    if [[ -n "$DATASET_SUBDIR" ]]; then
        DATASET_DIR="${TEST_DIR}/${DATASET_SUBDIR}"
    else
        DATASET_DIR="$TEST_DIR"
    fi
    RESULTS="${RESULTS:-/tmp/fio-${PROFILE}-bs-results}"
}

comparability_guard() {
    local changed=0 reason=""
    [[ "$RUNTIME" == "$FROZEN_RUNTIME" ]] || { changed=1; reason+="runtime=${RUNTIME} "; }
    [[ "$FILE_SIZE" == "$FROZEN_SIZE" ]] || { changed=1; reason+="filesize=${FILE_SIZE} "; }
    [[ "$NUMJOBS" == "$FROZEN_NUMJOBS" ]] || { changed=1; reason+="numjobs=${NUMJOBS} "; }
    [[ "$IODEPTH" == "$FROZEN_IODEPTH" ]] || { changed=1; reason+="iodepth=${IODEPTH} "; }
    [[ "$FORMAL_START" == "$FROZEN_FORMAL_START" ]] || { changed=1; reason+="formal_start=${FORMAL_START} "; }
    [[ "$FORMAL_STOP" == "$FROZEN_FORMAL_STOP" ]] || { changed=1; reason+="formal_stop=${FORMAL_STOP} "; }
    if [[ "$CLIENT_CACHE_CONFIG" == UNDECLARED ]]; then
        changed=1
        reason+="client_cache_config=UNDECLARED "
    fi
    if (( changed == 1 )); then
        COMPARABLE=0
        [[ "$ALLOW_NONCOMPARABLE" == 1 ]] || \
            die "frozen comparison load changed (${reason}); set ALLOW_NONCOMPARABLE=1 only for explicitly non-comparable diagnostics"
    fi
}

dataset_count() {
    [[ -d "$DATASET_DIR" ]] || { printf '0\n'; return; }
    find "$DATASET_DIR" -maxdepth 1 -type f -name "${JOB_NAME}.*.0" -printf '.' | wc -c
}

verify_dataset() {
    local expected actual count index file
    expected="$(size_bytes "$FILE_SIZE")"
    count="$(dataset_count)"
    [[ "$count" -eq "$NUMJOBS" ]] || \
        die "${JOB_NAME} expects ${NUMJOBS} files, found ${count}"
    for ((index=0; index<NUMJOBS; index++)); do
        file="${DATASET_DIR}/${JOB_NAME}.${index}.0"
        [[ -f "$file" && ! -L "$file" ]] || \
            die "missing, non-regular or symlink dataset file: ${file}"
        actual="$(stat -c %s "$file")"
        [[ "$actual" -eq "$expected" ]] || \
            die "dataset size mismatch: ${file} actual=${actual} expected=${expected}"
    done
}

write_asset_manifest() {
    local target="$1" index file
    printf 'name\ttype\tbytes\tinode\n' >"$target"
    for ((index=0; index<NUMJOBS; index++)); do
        file="${DATASET_DIR}/${JOB_NAME}.${index}.0"
        printf '%s\t%s\t%s\t%s\n' \
            "${JOB_NAME}.${index}.0" \
            "$(stat -c %F "$file" | sed 's/ /_/g')" \
            "$(stat -c %s "$file")" \
            "$(stat -c %i "$file")" >>"$target"
    done
}

record_command() {
    local argument
    for argument in "$@"; do
        printf '%q ' "$argument" >>"${OUTDIR}/commands.sh"
    done
    printf '\n' >>"${OUTDIR}/commands.sh"
}

build_fio_args() {
    local bs="$1" log_prefix="$2" output_file="$3"
    FIO_ARGS=(
        fio "--name=${JOB_NAME}" "--directory=${DATASET_DIR}"
        "--filename_format=${JOB_NAME}.\$jobnum.0"
        "--filesize=${FILE_SIZE}" "--size=${FILE_SIZE}" "--bs=${bs}"
        "--rw=${RW_MODE}" "--ioengine=${IOENGINE}" "--iodepth=${IODEPTH}"
        "--numjobs=${NUMJOBS}" --direct=1 --fallocate=none --allow_file_create=0
        "--openfiles=${NUMJOBS}" --group_reporting --time_based "--runtime=${RUNTIME}"
        --randrepeat=1 "--write_bw_log=${log_prefix}" --log_avg_msec=1000
        --per_job_logs=1 "--output=${output_file}" --output-format=json+
    )
    (( REFILL == 1 )) && FIO_ARGS+=(--refill_buffers)
    (( END_FSYNC == 1 )) && FIO_ARGS+=(--end_fsync=1)
    # An optional false condition above must not become the function status under set -e.
    return 0
}

create_dataset() {
    local count expected required available reserve
    if [[ ! -e "$DATASET_DIR" ]]; then
        mkdir -p "$DATASET_DIR"
    fi
    [[ -d "$DATASET_DIR" && ! -L "$DATASET_DIR" ]] || \
        die "dataset directory must be a real directory: ${DATASET_DIR}"
    count="$(dataset_count)"
    if [[ "$count" -eq "$NUMJOBS" ]]; then
        verify_dataset
        write_asset_manifest "${OUTDIR}/assets-layout.tsv"
        log "DATASET_REUSE_PASS profile=${PROFILE} files=${NUMJOBS} size=${FILE_SIZE}"
        return
    fi
    [[ "$count" -eq 0 ]] || \
        die "partial ${JOB_NAME} dataset found (${count}/${NUMJOBS}); refusing repair"
    [[ "$CREATE_DATASET" == 1 ]] || \
        die "dataset absent and CREATE_DATASET=0"

    expected="$(size_bytes "$FILE_SIZE")"
    required=$((expected * NUMJOBS))
    reserve="$(size_bytes "$FREE_SPACE_RESERVE")"
    available="$(df --output=avail -B1 "$DATASET_DIR" | awk 'NR==2 {print $1}')"
    [[ "$available" =~ ^[0-9]+$ ]] || die "cannot determine free space"
    (( available >= required + reserve )) || \
        die "insufficient free space: available=${available} required_with_reserve=$((required + reserve))"

    local -a layout_args=(
        fio "--name=${JOB_NAME}" "--directory=${DATASET_DIR}"
        "--filename_format=${JOB_NAME}.\$jobnum.0"
        "--filesize=${FILE_SIZE}" "--size=${FILE_SIZE}" --bs=4M --rw=write
        "--numjobs=${NUMJOBS}" --fallocate=none --direct=1 --ioengine=libaio
        --iodepth=128 --group_reporting --end_fsync=1
        "--output=${OUTDIR}/layout-fio.json" --output-format=json+
    )
    log "DATASET_CREATE_START profile=${PROFILE} files=${NUMJOBS} size=${FILE_SIZE}"
    record_command "${layout_args[@]}"
    "${layout_args[@]}"
    verify_dataset
    write_asset_manifest "${OUTDIR}/assets-layout.tsv"
    log "DATASET_CREATE_PASS profile=${PROFILE}"
}

cell_stats() {
    local cell_dir="$1" expected_jobs="$2" formal_start="$3" formal_stop="$4"
    python3 - "$cell_dir" "$expected_jobs" "$formal_start" "$formal_stop" \
        "$DIRECTION" "$PROFILE" <<'PY'
import csv
import glob
import json
import math
import os
import statistics
import sys

cell, expected_jobs, formal_start, formal_stop, direction, profile = sys.argv[1:7]
expected_jobs = int(expected_jobs)
formal_start = float(formal_start)
formal_stop = float(formal_stop)
direction_id = 0 if direction == "read" else 1

def fail(message):
    raise SystemExit("cell_stats: %s" % message)

with open(os.path.join(cell, "fio.json"), encoding="utf-8") as handle:
    data = json.load(handle)
jobs = data.get("jobs")
if not isinstance(jobs, list) or not jobs:
    fail("invalid fio jobs")
if any(int(job.get("error", -1)) != 0 for job in jobs):
    fail("fio job error")

runtimes = [float(job.get(direction, {}).get("runtime", 0.0)) for job in jobs]
runtimes = [value for value in runtimes if value > 0]
if not runtimes:
    fail("directional runtime missing")
runtime_s = max(runtimes) / 1000.0
with open(os.path.join(cell, "fio-end-epoch-ns.txt"), encoding="utf-8") as handle:
    end_ns = int(handle.read().strip())
start_ns = end_ns - int(runtime_s * 1_000_000_000)
with open(os.path.join(cell, "fio-start-epoch-ns.txt"), encoding="utf-8") as handle:
    stated_ns = int(handle.read().strip())

def summary_field(field):
    return sum(float(job.get(direction, {}).get(field, 0.0)) for job in jobs)

def clat(field):
    values = []
    for job in jobs:
        node = job.get(direction, {}).get("clat_ns", {})
        if field == "mean":
            values.append(float(node.get("mean", 0.0)) / 1000.0)
        else:
            values.append(float(node.get("percentile", {}).get(field, 0.0)) / 1000.0)
    return max(values) if values else 0.0

paths = sorted(glob.glob(os.path.join(cell, "bw", "%s_bw.*.log" % profile)))
single = os.path.join(cell, "bw", "%s_bw.log" % profile)
if not paths and os.path.isfile(single):
    paths = [single]
if len(paths) not in (1, expected_jobs):
    fail("expected 1 or %d bandwidth logs, found %d" % (expected_jobs, len(paths)))

seconds = int(math.ceil(runtime_s))
bins = [0.0] * seconds
seen = set()
for path in paths:
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.reader(handle):
            if not row or not row[0].strip():
                continue
            if len(row) < 3:
                fail("short row in %s" % os.path.basename(path))
            end = float(row[0]) / 1000.0
            value = float(row[1]) / 1024.0
            row_direction = int(row[2])
            seen.add(row_direction)
            if row_direction != direction_id:
                continue
            begin = max(0.0, end - 1.0)
            for second in range(int(math.floor(begin)), int(math.ceil(end))):
                if second >= seconds:
                    break
                overlap = min(end, runtime_s, second + 1.0) - max(begin, float(second))
                if overlap > 0:
                    bins[second] += value * overlap
if direction_id not in seen:
    fail("bandwidth logs lack expected direction")

start = int(formal_start)
stop = int(formal_stop)
window = [bins[second] for second in range(start, stop) if second < seconds]
if len(window) != stop - start:
    fail("formal window coverage incomplete: %d/%d" % (len(window), stop - start))

def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)

total = summary_field("io_bytes")
mean = statistics.mean(window)
span = (stop - start) // 4
quarters = [statistics.mean(window[index * span:(index + 1) * span]) for index in range(4)]
integrated = sum(bins)
expected = total / 1048576.0
values = [
    ("runtime_s", runtime_s),
    ("actual_io_start_epoch_ns", start_ns),
    ("fio_end_epoch_ns", end_ns),
    ("stated_minus_actual_start_s", (start_ns - stated_ns) / 1e9),
    ("bw_log_files", len(paths)),
    ("summary_MiB_s", total / runtime_s / 1048576.0),
    ("formal_MiB_s", mean),
    ("formal_median_MiB_s", statistics.median(window)),
    ("formal_cv", statistics.pstdev(window) / mean if mean else float("inf")),
    ("formal_p10_MiB_s", percentile(window, 0.10)),
    ("formal_p90_MiB_s", percentile(window, 0.90)),
    ("W1_MiB_s", quarters[0]),
    ("W2_MiB_s", quarters[1]),
    ("W3_MiB_s", quarters[2]),
    ("W4_MiB_s", quarters[3]),
    ("W4_W1", quarters[3] / quarters[0] if quarters[0] else float("inf")),
    ("iops", summary_field("iops")),
    ("clat_mean_us", clat("mean")),
    ("clat_p95_us", clat("95.000000")),
    ("clat_p99_us", clat("99.000000")),
    ("log_vs_io_bytes_pct", (integrated / expected - 1.0) * 100.0 if expected else float("nan")),
]
for key, value in values:
    if isinstance(value, float):
        print("%s\t%.6f" % (key, value))
    else:
        print("%s\t%s" % (key, value))
PY
}

stat_value() {
    local file="$1" key="$2"
    awk -F '\t' -v key="$key" '$1 == key {print $2; found=1} END {if (!found) exit 3}' "$file"
}

run_cell() {
    local position="$1" label="$2" bs="$3" cell_dir rc stats key
    cell_dir="${OUTDIR}/cells/${position}-${label}"
    [[ ! -e "$cell_dir" ]] || die "cell path already exists: ${cell_dir}"
    mkdir -p "${cell_dir}/bw"
    foreign_fio_gate
    uptime >"${cell_dir}/load-pre.txt"
    df -h "$TEST_DIR" >"${cell_dir}/df-pre.txt"
    findmnt -T "$TEST_DIR" -o SOURCE,TARGET,FSTYPE,OPTIONS >"${cell_dir}/findmnt.txt"
    write_asset_manifest "${cell_dir}/assets-before.tsv"
    build_fio_args "$bs" "${cell_dir}/bw/${PROFILE}" "${cell_dir}/fio.json"
    record_command "${FIO_ARGS[@]}"
    log ">>> position=${position} cell=${label} bs=${bs} profile=${PROFILE}"
    epoch_ns >"${cell_dir}/fio-start-epoch-ns.txt"
    set +e
    "${FIO_ARGS[@]}"
    rc=$?
    set -e
    epoch_ns >"${cell_dir}/fio-end-epoch-ns.txt"
    printf '%s\n' "$rc" >"${cell_dir}/fio.rc"
    [[ "$rc" -eq 0 ]] || die "fio failed at ${label}, rc=${rc}"
    cell_stats "$cell_dir" "$NUMJOBS" "$FORMAL_START" "$FORMAL_STOP" \
        >"${cell_dir}/cell-stats.tsv" || die "cell_stats failed at ${label}"
    stats="${cell_dir}/cell-stats.tsv"
    printf '%s\t%s\t%s' "$position" "$label" "$bs" >>"${OUTDIR}/results.tsv"
    for key in summary_MiB_s formal_MiB_s formal_cv W4_W1 iops \
        clat_mean_us clat_p95_us clat_p99_us log_vs_io_bytes_pct stated_minus_actual_start_s; do
        printf '\t%s' "$(stat_value "$stats" "$key")" >>"${OUTDIR}/results.tsv"
    done
    printf '\n' >>"${OUTDIR}/results.tsv"
    uptime >"${cell_dir}/load-post.txt"
    df -h "$TEST_DIR" >"${cell_dir}/df-post.txt"
    write_asset_manifest "${cell_dir}/assets-after.tsv"
    verify_dataset
    log "<<< ${label} PASS summary=$(stat_value "$stats" summary_MiB_s) formal=$(stat_value "$stats" formal_MiB_s) MiB/s"
}

write_summary() {
    python3 - "$OUTDIR" "$ANCHOR_DRIFT_MAX" "$POSITION_DRIFT_MAX" "$COMPARABLE" \
        "${BS_VALUES[@]}" <<'PY'
import csv
import os
import sys

outdir, anchor_max, position_max, comparable = sys.argv[1:5]
bs_values = sys.argv[5:]
anchor_max = float(anchor_max)
position_max = float(position_max)
comparable = comparable == "1"
with open(os.path.join(outdir, "results.tsv"), newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))

def number(row, key):
    try:
        return float(row[key])
    except (TypeError, ValueError, KeyError):
        return None

def drift(first, last):
    if first in (None, 0) or last is None:
        return None
    return (last / first - 1.0) * 100.0

anchor_a = next((row for row in rows if row["cell"] == "256K-A"), None)
anchor_b = next((row for row in rows if row["cell"] == "256K-B"), None)
anchor_values = []
matrix_verdict = "MATRIX_ANCHOR_MISSING"
if anchor_a and anchor_b:
    for stat in ("summary", "formal"):
        key = "%s_MiB_s" % stat
        first, last = number(anchor_a, key), number(anchor_b, key)
        delta = drift(first, last)
        anchor_values.append((stat, first, last, delta))
    worst = max(value[3] for value in anchor_values if value[3] is not None)
    matrix_verdict = "MATRIX_DRIFTED" if worst > anchor_max else "MATRIX_STABLE"

with open(os.path.join(outdir, "anchors.tsv"), "w", encoding="utf-8") as handle:
    handle.write("stat\t256K_A_MiB_s\t256K_B_MiB_s\tanchor_drift_pct\n")
    for stat, first, last, delta in anchor_values:
        handle.write("%s\t%.6f\t%.6f\t%.6f\n" % (stat, first, last, delta))

missing = []
with open(os.path.join(outdir, "summary.tsv"), "w", encoding="utf-8") as handle:
    handle.write("bs\tstat\tpoints\tpos1_MiB_s\tpos2_MiB_s\tposition_drift_pct"
                 "\trange_MiB_s\tverdict\tcomparable\n")
    for bs in bs_values:
        cells = [row for row in rows if row["bs"] == bs]
        if len(cells) != 2:
            missing.append(bs)
            handle.write("%s\tNA\t%d\t\t\t\t\tMISSING\t%s\n" %
                         (bs, len(cells), "YES" if comparable else "NOT_COMPARABLE"))
            continue
        for stat in ("summary", "formal"):
            key = "%s_MiB_s" % stat
            first, last = number(cells[0], key), number(cells[1], key)
            delta = drift(first, last)
            if matrix_verdict == "MATRIX_DRIFTED":
                verdict = "MATRIX_DRIFTED"
            elif delta is None or delta > position_max:
                verdict = "RANGE_ONLY"
            else:
                verdict = "POINT_USABLE"
            handle.write("%s\t%s\t2\t%.6f\t%.6f\t%.6f\t%.6f--%.6f\t%s\t%s\n" %
                         (bs, stat, first, last, delta, min(first, last), max(first, last),
                          verdict, "YES" if comparable else "NOT_COMPARABLE"))

with open(os.path.join(outdir, "verdict.tsv"), "w", encoding="utf-8") as handle:
    handle.write("key\tvalue\n")
    handle.write("matrix_verdict\t%s\n" % matrix_verdict)
    handle.write("anchor_drift_max_pct\t%.6f\n" % anchor_max)
    handle.write("position_drift_max_pct\t%.6f\n" % position_max)
    handle.write("comparable\t%s\n" % ("YES" if comparable else "NOT_COMPARABLE"))
    handle.write("missing_bs\t%s\n" % (",".join(missing) if missing else "NONE"))
    handle.write("cells\t%d\n" % len(rows))
if missing:
    raise SystemExit(3)
PY
}

record_client_resources() {
    local base iface value
    if command -v lscpu >/dev/null 2>&1; then
        lscpu >"${OUTDIR}/lscpu.txt"
    else
        cp /proc/cpuinfo "${OUTDIR}/cpuinfo.txt"
    fi
    printf 'iface\taddress\toperstate\tspeed_mbps\tduplex\tmtu\n' \
        >"${OUTDIR}/network-interfaces.tsv"
    for base in /sys/class/net/*; do
        [[ -d "$base" ]] || continue
        iface="${base##*/}"
        printf '%s' "$iface" >>"${OUTDIR}/network-interfaces.tsv"
        for value in address operstate speed duplex mtu; do
            [[ -r "${base}/${value}" ]] && \
                printf '\t%s' "$(<"${base}/${value}")" >>"${OUTDIR}/network-interfaces.tsv" || \
                printf '\tNA' >>"${OUTDIR}/network-interfaces.tsv"
        done
        printf '\n' >>"${OUTDIR}/network-interfaces.tsv"
    done
    if command -v ip >/dev/null 2>&1; then
        ip -brief address >"${OUTDIR}/network-addresses.txt" 2>&1 || true
    fi
}

preflight_common() {
    validate_abs_path TEST_DIR "$TEST_DIR"
    validate_abs_path RESULTS "$RESULTS"
    is_uint "$RUNTIME" || die "RUNTIME must be a positive integer"
    is_uint "$NUMJOBS" || die "NUMJOBS must be a positive integer"
    is_uint "$IODEPTH" || die "IODEPTH must be a positive integer"
    is_uint "$CELL_COOLDOWN" || die "CELL_COOLDOWN must be a positive integer"
    [[ "$FORMAL_START" =~ ^[0-9]+$ && "$FORMAL_STOP" =~ ^[0-9]+$ ]] || \
        die "formal window bounds must be integers"
    (( FORMAL_START < FORMAL_STOP && FORMAL_STOP <= RUNTIME )) || \
        die "formal window [${FORMAL_START},${FORMAL_STOP}) must fit runtime ${RUNTIME}"
    [[ "$CREATE_DATASET" == 0 || "$CREATE_DATASET" == 1 ]] || \
        die "CREATE_DATASET must be 0 or 1"
    [[ "$ALLOW_NONCOMPARABLE" == 0 || "$ALLOW_NONCOMPARABLE" == 1 ]] || \
        die "ALLOW_NONCOMPARABLE must be 0 or 1"
    [[ "$ALLOW_ROOT_FS" == 0 || "$ALLOW_ROOT_FS" == 1 ]] || \
        die "ALLOW_ROOT_FS must be 0 or 1"
    [[ "$CLIENT_CACHE_CONFIG" != *$'\t'* && "$CLIENT_CACHE_CONFIG" != *$'\n'* ]] || \
        die "CLIENT_CACHE_CONFIG must be a single line without tabs"
    require_commands
    comparability_guard
    foreign_fio_gate
    [[ -d "$TEST_DIR" && ! -L "$TEST_DIR" ]] || \
        die "TEST_DIR must be an existing real directory: ${TEST_DIR}"
    [[ -w "$TEST_DIR" ]] || die "TEST_DIR is not writable: ${TEST_DIR}"
    case "$DATASET_DIR" in
        "$TEST_DIR"|"$TEST_DIR"/*) ;;
        *) die "DATASET_DIR escapes TEST_DIR: ${DATASET_DIR}" ;;
    esac
    local mount_target
    mount_target="$(findmnt -T "$TEST_DIR" -n -o TARGET)"
    [[ -n "$mount_target" ]] || die "cannot resolve filesystem for TEST_DIR"
    [[ "$mount_target" != / || "$ALLOW_ROOT_FS" == 1 ]] || \
        die "TEST_DIR resolves to root filesystem; set ALLOW_ROOT_FS=1 only after explicit review"
    [[ ! -e "$OUTDIR" ]] || die "output directory already exists: ${OUTDIR}"
    mkdir -p "$OUTDIR"
    {
        printf 'key\tvalue\n'
        printf 'profile\t%s\n' "$PROFILE"
        printf 'direction\t%s\n' "$DIRECTION"
        printf 'test_dir\t%s\n' "$TEST_DIR"
        printf 'dataset_dir\t%s\n' "$DATASET_DIR"
        printf 'job_name\t%s\n' "$JOB_NAME"
        printf 'runtime_s\t%s\n' "$RUNTIME"
        printf 'filesize\t%s\n' "$FILE_SIZE"
        printf 'numjobs\t%s\n' "$NUMJOBS"
        printf 'iodepth\t%s\n' "$IODEPTH"
        printf 'ioengine\t%s\n' "$IOENGINE"
        printf 'formal_window\t[%s,%s)\n' "$FORMAL_START" "$FORMAL_STOP"
        printf 'comparable_load\t%s\n' "$([[ "$COMPARABLE" == 1 ]] && printf YES || printf NOT_COMPARABLE)"
        printf 'client_cache_config\t%s\n' "$CLIENT_CACHE_CONFIG"
        printf 'hostname\t%s\n' "$(hostname)"
        printf 'fio_version\t%s\n' "$(fio --version)"
        printf 'kernel\t%s\n' "$(uname -r)"
        printf 'memtotal_kib\t%s\n' "$(awk '$1 == "MemTotal:" {print $2}' /proc/meminfo)"
        printf 'cpu_logical_count\t%s\n' "$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo)"
        printf 'mount_source\t%s\n' "$(findmnt -T "$TEST_DIR" -n -o SOURCE)"
        printf 'mount_target\t%s\n' "$(findmnt -T "$TEST_DIR" -n -o TARGET)"
        printf 'mount_fstype\t%s\n' "$(findmnt -T "$TEST_DIR" -n -o FSTYPE)"
        printf 'mount_options\t%s\n' "$(findmnt -T "$TEST_DIR" -n -o OPTIONS)"
        printf 'engine_sha256\t%s\n' "$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
        printf 'entry_sha256\t%s\n' "$(sha256sum "$ENTRY_SCRIPT" | awk '{print $1}')"
    } >"${OUTDIR}/environment.tsv"
    record_client_resources
    findmnt -T "$TEST_DIR" -o SOURCE,TARGET,FSTYPE,OPTIONS >"${OUTDIR}/findmnt.txt"
    df -h "$TEST_DIR" >"${OUTDIR}/df-start.txt"
    printf '#!/bin/bash\n# Commands actually executed; values are shell-escaped.\n' \
        >"${OUTDIR}/commands.sh"
}

finalize() {
    df -h "$TEST_DIR" >"${OUTDIR}/df-end.txt"
    (
        cd "$OUTDIR"
        find . -type f ! -name SHA256SUMS -print0 | sort -z | \
            xargs -0 sha256sum >SHA256SUMS
    )
}

run_layout() {
    OUTDIR="${RESULTS%/}-layout"
    preflight_common
    log "BS_LAYOUT_START profile=${PROFILE} test_dir=${TEST_DIR}"
    create_dataset
    log "BS_LAYOUT_PASS profile=${PROFILE} outdir=${OUTDIR}"
    finalize
    printf 'Dataset ready. Run the measured matrix later with:\n'
    printf '  TEST_DIR=%q RESULTS=%q CLIENT_CACHE_CONFIG=%q %q run\n' \
        "$TEST_DIR" "$RESULTS" "$CLIENT_CACHE_CONFIG" "$ENTRY_SCRIPT"
}

run_matrix() {
    local position=0 entry label bs summary_status=0
    OUTDIR="$RESULTS"
    preflight_common
    [[ "$CREATE_DATASET" == 0 ]] || die "run requires CREATE_DATASET=0"
    [[ -d "$DATASET_DIR" && ! -L "$DATASET_DIR" ]] || \
        die "dataset directory missing or unsafe; run layout first"
    verify_dataset
    write_asset_manifest "${OUTDIR}/assets-start.tsv"
    printf 'position\tcell\tbs\tsummary_MiB_s\tformal_MiB_s\tformal_cv\tW4_W1\tiops\tclat_mean_us\tclat_p95_us\tclat_p99_us\tlog_vs_io_bytes_pct\tstated_minus_actual_start_s\n' \
        >"${OUTDIR}/results.tsv"
    log "BS_SWEEP_START profile=${PROFILE} test_dir=${TEST_DIR} results=${OUTDIR}"
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
        log "BS_SWEEP_PASS profile=${PROFILE} results=${OUTDIR}"
    else
        log "BS_SWEEP_INCOMPLETE profile=${PROFILE} status=${summary_status} results=${OUTDIR}"
    fi
    finalize
    printf '\nVerdict:\n'
    column -t -s $'\t' "${OUTDIR}/verdict.tsv" 2>/dev/null || \
        sed -n '1,20p' "${OUTDIR}/verdict.tsv"
    printf '\nSummary:\n'
    column -t -s $'\t' "${OUTDIR}/summary.tsv" 2>/dev/null || \
        sed -n '1,80p' "${OUTDIR}/summary.tsv"
    (( summary_status == 0 )) || return "$summary_status"
}

make_fixture_cell() {
    local dir="$1" jobs="$2" seconds=180 direction_id value total job second
    direction_id=0
    [[ "$DIRECTION" == write ]] && direction_id=1
    mkdir -p "${dir}/bw"
    for ((job=1; job<=jobs; job++)); do
        : >"${dir}/bw/${PROFILE}_bw.${job}.log"
        for ((second=1; second<=seconds; second++)); do
            value=1024
            printf '%d, %d, %d, 4096, 0\n' $((second * 1000)) "$value" "$direction_id" \
                >>"${dir}/bw/${PROFILE}_bw.${job}.log"
        done
    done
    total=$((seconds * 1048576 * jobs))
    python3 - "$dir" "$total" "$seconds" "$DIRECTION" <<'PY'
import json
import sys
path, total, seconds, direction = sys.argv[1:5]
node = {"runtime": int(seconds) * 1000, "io_bytes": int(total), "iops": 1.0,
        "clat_ns": {"mean": 1000.0,
                    "percentile": {"95.000000": 2000.0, "99.000000": 3000.0}}}
job = {"error": 0, direction: node}
with open(path + "/fio.json", "w", encoding="utf-8") as handle:
    json.dump({"jobs": [job]}, handle)
PY
    printf '%d\n' 1699999820000000000 >"${dir}/fio-start-epoch-ns.txt"
    printf '%d\n' 1700000000000000000 >"${dir}/fio-end-epoch-ns.txt"
}

self_test() {
    local expected_cells tmp cell mean entry bs count
    [[ "${MATRIX[0]}" == 256K-A:256K ]] || die "first anchor mismatch"
    [[ "${MATRIX[-1]}" == 256K-B:256K ]] || die "last anchor mismatch"
    if [[ "$PROFILE" == randread || "$PROFILE" == randwrite ]]; then
        expected_cells=12
    else
        expected_cells=10
    fi
    [[ "${#MATRIX[@]}" -eq "$expected_cells" ]] || die "matrix cell count mismatch"
    for bs in "${BS_VALUES[@]}"; do
        count=0
        for entry in "${MATRIX[@]}"; do
            [[ "${entry##*:}" == "$bs" ]] && count=$((count + 1))
        done
        [[ "$count" -eq 2 ]] || die "matrix repetition mismatch for ${bs}"
    done
    if grep -nE '(^|[[:space:]])sudo([[:space:]]|$)|/proc/sys/vm/drop_caches|rm[[:space:]]+-rf|reboot|shutdown|poweroff|wipefs|mkfs|umount|kill[[:space:]]' \
        "${BASH_SOURCE[0]}" "$ENTRY_SCRIPT" | grep -vE '^[^:]+:[0-9]+:#|no sudo|grep -nE' >/dev/null; then
        die "forbidden operation found"
    fi
    tmp="$(mktemp -d)"
    cell="${tmp}/cell"
    make_fixture_cell "$cell" 2
    cell_stats "$cell" 2 "$FORMAL_START" "$FORMAL_STOP" >"${tmp}/stats.tsv"
    mean="$(stat_value "${tmp}/stats.tsv" formal_MiB_s)"
    awk -v value="$mean" 'BEGIN {exit !(value > 1.99 && value < 2.01)}' || \
        die "formal analyzer mean mismatch: ${mean}"
    awk -v value="$(stat_value "${tmp}/stats.tsv" W4_W1)" \
        'BEGIN {exit !(value > 0.999 && value < 1.001)}' || die "W4/W1 mismatch"
    printf 'BS_SWEEP_SELF_TEST_PASS profile=%s cells=%s destructive_ops=0 analyzer=OK matrix=OK\n' \
        "$PROFILE" "$expected_cells"
    printf 'self-test scratch dir (safe to remove manually): %s\n' "$tmp"
}

usage() {
    printf 'Usage:\n' >&2
    printf '  TEST_DIR=/absolute/path CREATE_DATASET=1 CLIENT_CACHE_CONFIG=<value> %s layout\n' "$ENTRY_SCRIPT" >&2
    printf '  TEST_DIR=/absolute/path CLIENT_CACHE_CONFIG=<value> %s run\n' "$ENTRY_SCRIPT" >&2
    printf '  %s --self-test\n' "$ENTRY_SCRIPT" >&2
}

load_profile
case "${1:-}" in
    layout) run_layout ;;
    run) run_matrix ;;
    --self-test) self_test ;;
    *) usage; exit 2 ;;
esac
