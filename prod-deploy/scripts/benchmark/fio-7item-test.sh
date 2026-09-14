#!/bin/bash
# fio-7item-test.sh — 通用 7 项 fio 基线测试
# 口径与 JuiceFS FULLBASELINE_V4.sh 一致
# 可用于任何 POSIX 文件系统（JuiceFS/WekaIO/ext4/NFS 等）
#
# 七项执行顺序与 FULLBASELINE_V4.sh 一致：
# seqread, mseqread, randread, randrw, seqwrite, mseqwrite, randwrite
# 三组独立文件集避免读写交叉污染：
#   storage_test.*  — randwrite 覆盖写
#   read_test.*     — randread 专用（永不被写覆盖）
#   rw_test.*       — randrw 专用
#
# 顺序单流 size 默认 32G；多流每 job 默认 4G（与 V4 一致）
#
# 用法:
#   ./fio-7item-test.sh all                  # 顺序跑全部 7 项
#   ./fio-7item-test.sh seqread randread     # 只跑指定项（可多个，按给定顺序）
#   ./fio-7item-test.sh list                # 列出可选项
#
# 可用环境变量:
#   TEST_DIR          测试目录        (默认 /mnt/data04/perf_test)
#   RESULTS           结果目录        (默认 /tmp/fio-7item-results)
#   RUNTIME           time_based 秒数 (默认 180)
#   REPEAT            每项轮数       (默认 3)
#   SIZE_SEQ_SINGLE   单流项 size    (默认 32G)
#   SIZE_SEQ_MULTI    多流每job size (默认 4G)
#   NJOBS_SEQ         多流 numjobs    (默认 16)
#   SIZE_RND          随机项 filesize(默认 1G)
#   NJOBS_RND         随机项 numjobs (默认 128)
#   DROP_CACHES       必须为 0；全局 drop_caches 已禁止
#                      （脚本内通过 direct=1 + cache=0 保证冷态，
#                       如需额外 drop_caches 由调用方在脚本外手动执行）
#
# 本地冒烟示例:
#   TEST_DIR=/tmp/smoke/data RESULTS=/tmp/smoke/results \
#   RUNTIME=3 REPEAT=2 SIZE_SEQ_SINGLE=32M SIZE_SEQ_MULTI=32M \
#   NJOBS_SEQ=2 NJOBS_RND=4 \
#   ./fio-7item-test.sh all

set -euo pipefail

TEST_DIR="${TEST_DIR:-/mnt/data04/perf_test}"
RESULTS="${RESULTS:-/tmp/fio-7item-results}"
RUNTIME="${RUNTIME:-180}"
REPEAT="${REPEAT:-3}"
SIZE_SEQ_SINGLE="${SIZE_SEQ_SINGLE:-32G}"
SIZE_SEQ_MULTI="${SIZE_SEQ_MULTI:-4G}"
NJOBS_SEQ="${NJOBS_SEQ:-16}"
SIZE_RND="${SIZE_RND:-1G}"
NJOBS_RND="${NJOBS_RND:-128}"
DROP_CACHES="${DROP_CACHES:-0}"

ITEMS_ALL="seqread mseqread randread randrw seqwrite mseqwrite randwrite"
FIO_RC=0

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

drop_caches() {
    if [ "${DROP_CACHES}" != "0" ]; then
        log "ERROR: global drop_caches is intentionally disabled by this script"
        exit 2
    fi
}

size_bytes() {
    numfmt --from=iec "$1"
}

# verify_file_set <directory> <job name> <job count> <size>
verify_file_set() {
    local dir="$1" name="$2" jobs="$3" size="$4"
    local expected actual count i file
    expected="$(size_bytes "${size}")"
    count="$(find "${dir}" -maxdepth 1 -type f -name "${name}.*.0" -printf '.' | wc -c)"
    if [ "${count}" -ne "${jobs}" ]; then
        log "ERROR: ${name} expects ${jobs} files, found ${count}; refusing measured I/O"
        return 1
    fi
    for ((i=0; i<jobs; i++)); do
        file="${dir}/${name}.${i}.0"
        if [ ! -f "${file}" ]; then
            log "ERROR: missing expected file: ${file}"
            return 1
        fi
        actual="$(stat -c %s "${file}")"
        if [ "${actual}" -ne "${expected}" ]; then
            log "ERROR: invalid size: ${file} actual=${actual} expected=${expected}"
            return 1
        fi
    done
    log "DATASET_VERIFY_PASS name=${name} files=${jobs} size=${size}"
}

# Ensure a file set exists without deleting or silently repairing partial data.
ensure_file_set() {
    local dir="$1" name="$2" jobs="$3" size="$4"
    local matches
    mkdir -p "${dir}"
    matches="$(find "${dir}" -maxdepth 1 -type f -name "${name}.*.0" -printf '.' | wc -c)"
    if [ "${matches}" -eq 0 ]; then
        log "prepare: ${name} ${jobs}x${size}"
        fio --name="${name}" --directory="${dir}" \
            --filesize="${size}" --size="${size}" --bs=4M --rw=write \
            --numjobs="${jobs}" --fallocate=none --direct=1 \
            --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 \
            >/dev/null 2>&1
    fi
    verify_file_set "${dir}" "${name}" "${jobs}" "${size}"
}

fio_bw_summary() {
    local output="$1"
    grep -E '^[[:space:]]*(READ|WRITE):' "${output}" \
        | sed -E 's/^[[:space:]]*(READ|WRITE):.*bw=([^, ]+).*/\1 bw=\2/' \
        | paste -sd ';' -
}

# run_fio <label> <fio args...>
run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS}/${label}"
    if [ -e "${subdir}" ]; then
        log "ERROR: result path already exists: ${subdir}; archive or remove it explicitly"
        exit 2
    fi
    mkdir -p "${subdir}"
    drop_caches
    uptime > "${subdir}/load.txt"
    log ">>> ${label} start ($(grep -oE 'load average.*' "${subdir}/load.txt"))"
    set +e
    fio "$@" --write_bw_log="${subdir}/${label}" --log_avg_msec=1000 \
        > "${subdir}/fio.txt" 2>&1
    FIO_RC=$?
    set -e
    if [ ${FIO_RC} -ne 0 ]; then
        log "ERROR: ${label} fio rc=${FIO_RC}, stopping"
        exit ${FIO_RC}
    fi
    local bw
    bw="$(fio_bw_summary "${subdir}/fio.txt")"
    log "<<< ${label} done  ${bw:-BW not parsed}"
}

# ===== Layout: three independent file sets =====
layout_all() {
    log "--- layout: 3 file sets (${NJOBS_RND}x${SIZE_RND} each) ---"
    for name in storage_test read_test rw_test; do
        ensure_file_set "${TEST_DIR}" "${name}" "${NJOBS_RND}" "${SIZE_RND}"
    done
    log "--- layout done ---"
}

# ===== 7 items =====

item_seqread() {
    ensure_file_set "${TEST_DIR}/seqread" seqread 1 "${SIZE_SEQ_SINGLE}"
    local r
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqread-r${r}" \
            --name=seqread --directory="${TEST_DIR}/seqread/" \
            --rw=read --refill_buffers --bs=256k --size="${SIZE_SEQ_SINGLE}" \
            --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime="${RUNTIME}"
    done
}

item_mseqread() {
    ensure_file_set "${TEST_DIR}/mseqread" mseqread "${NJOBS_SEQ}" "${SIZE_SEQ_MULTI}"
    local r
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqread-r${r}" \
            --name=mseqread --directory="${TEST_DIR}/mseqread/" \
            --rw=read --refill_buffers --bs=256k --size="${SIZE_SEQ_MULTI}" --numjobs="${NJOBS_SEQ}" --group_reporting \
            --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime="${RUNTIME}"
    done
}

item_seqwrite() {
    ensure_file_set "${TEST_DIR}/seqwrite" seqwrite 1 "${SIZE_SEQ_SINGLE}"
    local r
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqwrite-r${r}" \
            --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
            --rw=write --refill_buffers --bs=4M --size="${SIZE_SEQ_SINGLE}" --end_fsync=1 \
            --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime="${RUNTIME}"
    done
}

item_mseqwrite() {
    ensure_file_set "${TEST_DIR}/mseqwrite" mseqwrite "${NJOBS_SEQ}" "${SIZE_SEQ_MULTI}"
    local r
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqwrite-r${r}" \
            --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" \
            --rw=write --refill_buffers --bs=4M --size="${SIZE_SEQ_MULTI}" --numjobs="${NJOBS_SEQ}" --end_fsync=1 --group_reporting \
            --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime="${RUNTIME}"
    done
}

item_randread() {
    verify_file_set "${TEST_DIR}" read_test "${NJOBS_RND}" "${SIZE_RND}"
    local r
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randread-r${r}" \
            --directory="${TEST_DIR}" --name=read_test \
            --filesize="${SIZE_RND}" --size="${SIZE_RND}" \
            --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs="${NJOBS_RND}" \
            --direct=1 --fallocate=none --allow_file_create=0 --openfiles="${NJOBS_RND}" \
            --group_reporting --time_based --runtime="${RUNTIME}"
    done
}

item_randwrite() {
    verify_file_set "${TEST_DIR}" storage_test "${NJOBS_RND}" "${SIZE_RND}"
    local r
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randwrite-r${r}" \
            --directory="${TEST_DIR}" --name=storage_test \
            --filesize="${SIZE_RND}" --size="${SIZE_RND}" \
            --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs="${NJOBS_RND}" \
            --direct=1 --fallocate=none --allow_file_create=0 --openfiles="${NJOBS_RND}" \
            --group_reporting --time_based --runtime="${RUNTIME}"
    done
}

item_randrw() {
    verify_file_set "${TEST_DIR}" rw_test "${NJOBS_RND}" "${SIZE_RND}"
    local r
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randrw-r${r}" \
            --directory="${TEST_DIR}" --name=rw_test \
            --filesize="${SIZE_RND}" --size="${SIZE_RND}" \
            --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs="${NJOBS_RND}" \
            --direct=1 --fallocate=none --allow_file_create=0 --openfiles="${NJOBS_RND}" \
            --group_reporting --time_based --runtime="${RUNTIME}"
    done
}

summary() {
    log "===== Summary (fio summary bw) ====="
    local d bw
    for d in "${RESULTS}"/*/; do
        [ -f "${d}fio.txt" ] || continue
        bw="$(fio_bw_summary "${d}fio.txt")"
        printf '  %-22s %s\n' "$(basename "${d}")" "${bw:-NA}" | tee -a "${RESULTS}/test.log"
    done
}

# ===== Entry =====
case "${1:-}" in
    ""|list) echo "Available: ${ITEMS_ALL}  (or all)"; echo "  clean          # remove all test data and results"; exit 0 ;;
    clean)
        echo "Cleaning TEST_DIR=${TEST_DIR} and RESULTS=${RESULTS} ..."
        find "${TEST_DIR}" -mindepth 1 -delete 2>/dev/null || true
        rm -rf "${RESULTS}" 2>/dev/null || true
        echo "Done."
        exit 0
        ;;
    all) SEL="${ITEMS_ALL}" ;;
    *)   SEL="$*" ;;
esac

if ! command -v fio >/dev/null || ! command -v numfmt >/dev/null; then
    echo "ERROR: fio and numfmt are required" >&2
    exit 1
fi

if [ "${DROP_CACHES}" != "0" ]; then
    echo "ERROR: DROP_CACHES must remain 0; global cache clearing is forbidden" >&2
    exit 2
fi

if ! mkdir -p "${TEST_DIR}" "${RESULTS}" 2>/dev/null || [ ! -w "${TEST_DIR}" ] || [ ! -w "${RESULTS}" ]; then
    echo "ERROR: TEST_DIR not usable: ${TEST_DIR}" >&2
    exit 1
fi

log "===== 7-item test start: [${SEL}] ====="
log "Params: TEST_DIR=${TEST_DIR} RUNTIME=${RUNTIME}s REPEAT=${REPEAT} SEQ_SINGLE=${SIZE_SEQ_SINGLE} SEQ_MULTI=${SIZE_SEQ_MULTI}x${NJOBS_SEQ} SIZE_RND=${SIZE_RND}x${NJOBS_RND} DROP_CACHES=${DROP_CACHES}"

# run layout once before any random item
need_layout=0
for it in ${SEL}; do
    case "${it}" in
        randread|randwrite|randrw) need_layout=1 ;;
    esac
done
if [ ${need_layout} -eq 1 ]; then
    layout_all
fi

for it in ${SEL}; do
    case " ${ITEMS_ALL} " in
        *" ${it} "*) log "===== Item: ${it} ====="; "item_${it}" ;;
        *) echo "ERROR: unknown item: ${it} (available: ${ITEMS_ALL})" >&2; exit 1 ;;
    esac
done
summary
log "===== Done. Results: ${RESULTS} ====="
