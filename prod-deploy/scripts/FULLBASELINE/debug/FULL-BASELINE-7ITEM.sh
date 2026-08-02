#!/bin/bash
set -euo pipefail
export LC_ALL=C

# FULL-BASELINE-7ITEM.sh — 128-job + 缩缓存 全 7 项基线
# 前提：osd_memory_target=2GB 已注入、JuiceFS 已挂载

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"; TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"; RESULTS="/tmp/opencode-fullbaseline-v3"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"
NIC_IF="enp139s0f0np0"

LABEL="${1:-B7}"; RUNTIME=180; REPEAT=3
LAYOUT_SIZE="1G"; LAYOUT_JOBS=128; SEQ_SIZE="32G"; MSEQ_JOBS=16; MSEQ_SIZE="4G"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

drop_caches() { sync;echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null;for ip in "${SLAVES[@]}";do ${SSHPASS_CMD}@${ip} 'sync;echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null' 2>/dev/null||true;done;rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null||true; }
compact_cooldown() { local ol;ol=$(sudo ceph osd ls 2>/dev/null|tr '\n' ' ');for osd in ${ol};do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null||true;done;for i in $(seq 1 60);do local ad=true;for osd in ${ol};do local r q;read -r r q < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null|python3 -c 'import sys,json;x=json.load(sys.stdin).get("rocksdb",{});print(x.get("compact_running",1),x.get("compact_queue_len",1))' 2>/dev/null||echo "1 1");[ "$r" = "0" ]||ad=false;[ "$q" = "0" ]||ad=false;done;$ad&&break;sleep 5;done;log "  compact done"; }
aggressive_cleanup() { compact_cooldown;sleep 30;compact_cooldown;drop_caches; }

collect_hitrate() { local tag="$1" outdir="$2";local ol;ol=$(sudo ceph osd ls 2>/dev/null|tr '\n' ' ');local hb=0 mb=0;for osd in ${ol};do read -r h m _ < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null|python3 -c 'import sys,json;b=json.load(sys.stdin).get("bluestore",{});print(int(b.get("buffer_hit_bytes",0)),int(b.get("buffer_miss_bytes",0)),0)' 2>/dev/null||echo "0 0 0");hb=$((hb+h));mb=$((mb+m));done;echo "${tag} hit_bytes=${hb} miss_bytes=${mb}">>"${outdir}/hit-rate.txt"; }

run_fio() { local label="$1";shift;local sd="${RESULTS}/${LABEL}/${label}";mkdir -p "${sd}";rm -f "${sd}/hit-rate.txt";drop_caches;(while true;do echo "$(date +%s)|$(cat /proc/net/dev|grep ${NIC_IF})";sleep 1;done)>"${sd}/nic.txt"&local np=$!;collect_hitrate "pre" "${sd}";log "  fio ${label}...";fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 2>&1|tee "${sd}/fio.txt"||true;collect_hitrate "post" "${sd}";local bw;bw=$(grep -oE 'bw=[0-9.]+MiB' "${sd}/fio.txt" 2>/dev/null|head -1|grep -oE '[0-9.]+'||true);kill ${np} 2>/dev/null||true;wait ${np} 2>/dev/null||true;cp ${BW_LOG_DIR}/*_bw.*.log "${sd}/" 2>/dev/null||true;rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null||true;log "  ${label}: BW=${bw:-N/A} MiB/s"; }

# ===== Phase 0: Layout =====
log "=== Phase 0: Layout ==="
mkdir -p "${TEST_DIR}/seqread" "${TEST_DIR}/seqwrite" "${TEST_DIR}/mseqread" "${TEST_DIR}/mseqwrite"
log "  layout: ${LAYOUT_JOBS}x${LAYOUT_SIZE}"
fio --directory="${TEST_DIR}" --name=storage_test --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write --numjobs=${LAYOUT_JOBS} --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
log "  seqread prep ${SEQ_SIZE}"
fio --name=seqread --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=${SEQ_SIZE} --direct=1 >/dev/null 2>&1
log "  seqwrite prep ${SEQ_SIZE}"
fio --name=seqwrite --directory="${TEST_DIR}/seqwrite/" --rw=write --bs=4M --size=${SEQ_SIZE} --direct=1 >/dev/null 2>&1
log "  mseqread prep ${MSEQ_JOBS}x${MSEQ_SIZE}"
fio --name=mseqread --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --direct=1 >/dev/null 2>&1
log "  mseqwrite prep ${MSEQ_JOBS}x${MSEQ_SIZE}"
fio --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" --rw=write --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --direct=1 >/dev/null 2>&1
compact_cooldown
drop_caches
log "  layout done"

# ===== 7 Items =====
log "=== ${LABEL}: 7 items (128-job + shrunk cache) ==="

log "--- seqread (1 job) ---"
for r in $(seq 1 ${REPEAT}); do run_fio "seqread-${LABEL}-r${r}" --name=seqread --directory="${TEST_DIR}/seqread/" --rw=read --refill_buffers --bs=256k --size=${SEQ_SIZE} --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=${RUNTIME}; done

log "--- mseqread (16 jobs) ---"
for r in $(seq 1 ${REPEAT}); do run_fio "mseqread-${LABEL}-r${r}" --name=mseqread --directory="${TEST_DIR}/mseqread/" --rw=read --refill_buffers --bs=256k --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=${RUNTIME}; done

log "--- randread (128 jobs) ---"
for r in $(seq 1 ${REPEAT}); do run_fio "randread-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} --group_reporting --time_based --runtime=${RUNTIME}; done

log "--- randrw (128 jobs) ---"
for r in $(seq 1 ${REPEAT}); do run_fio "randrw-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} --group_reporting --time_based --runtime=${RUNTIME}; aggressive_cleanup; done

log "--- seqwrite (1 job) ---"
for r in $(seq 1 ${REPEAT}); do run_fio "seqwrite-${LABEL}-r${r}" --name=seqwrite --directory="${TEST_DIR}/seqwrite/" --rw=write --refill_buffers --bs=4M --size=${SEQ_SIZE} --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=${RUNTIME}; compact_cooldown; done

log "--- mseqwrite (16 jobs) ---"
for r in $(seq 1 ${REPEAT}); do run_fio "mseqwrite-${LABEL}-r${r}" --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" --rw=write --refill_buffers --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=${RUNTIME}; compact_cooldown; done
aggressive_cleanup

log "--- randwrite (128 jobs) ---"
for r in $(seq 1 ${REPEAT}); do run_fio "randwrite-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} --group_reporting --time_based --runtime=${RUNTIME}; aggressive_cleanup; done

# ===== Summary =====
log "=== Summary ${LABEL} ==="
for item in seqread mseqread randread randrw seqwrite mseqwrite randwrite; do
    local line="  ${item}:"
    for r in $(seq 1 ${REPEAT}); do
        local bw;bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/${item}-${LABEL}-r${r}/fio.txt" 2>/dev/null|head -1|grep -oE '[0-9.]+'||true)
        line="${line} r${r}=${bw:-NA}"
    done
    log "${line}"
done
log "=== ${LABEL} DONE ==="
