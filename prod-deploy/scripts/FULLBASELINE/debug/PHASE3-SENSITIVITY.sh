#!/bin/bash
set -euo pipefail
export LC_ALL=C

# PHASE3-SENSITIVITY.sh — 缩缓存后灵敏度验证（Phase 3 独立版）
# 前提：bluestore_cache_size 已设、OSD 已重启、bigfile.0.0 (128G) 已存在

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/opencode-fullbaseline-v3"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

LABEL="${1:-T3}"
RUNTIME=180
REPEAT=5
LAYOUT_SIZE="128G"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    local ok_count=0
    for ip in "${SLAVES[@]}"; do
        if ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; then
            ok_count=$((ok_count+1))
        fi
    done
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

compact_cooldown() {
    local osd_list
    osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${osd_list}; do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    for i in $(seq 1 60); do
        local all_done=true
        for osd in ${osd_list}; do
            local running queued
            read -r running queued < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
                'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
            [ "$running" = "0" ] || all_done=false
            [ "$queued" = "0" ] || all_done=false
        done
        $all_done && break
        sleep 5
    done
    log "  compact done"
}

deterministic_warmup() {
    log "  warmup: 顺序读 ${LAYOUT_SIZE} bigfile"
    for f in ${TEST_DIR}/bigfile*; do
        [ -f "$f" ] || continue
        dd if="$f" of=/dev/null bs=4M 2>/dev/null
    done
    log "  warmup done"
    compact_cooldown
    drop_caches
}

remount_jfs() {
    local opts="$1"
    log "  remount（${opts}）"
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    for try in 1 2 3; do
        juicefs mount -d ${opts} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: remount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

collect_hitrate() {
    local tag="$1"; local outdir="$2"
    local osd_list; osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    local hb=0 mb=0 oh=0 om=0
    for osd in ${osd_list}; do
        read -r h m o_h o_m < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c '
import sys,json; d=json.load(sys.stdin); b=d.get("bluestore",{})
print(int(b.get("buffer_hit_bytes",0)),int(b.get("buffer_miss_bytes",0)),int(b.get("onode_hits",0)),int(b.get("onode_misses",0)))
' 2>/dev/null || echo "0 0 0 0")
        hb=$((hb+h)); mb=$((mb+m)); oh=$((oh+o_h)); om=$((om+o_m))
    done
    echo "${tag} ts=$(date +%s) hit_bytes=${hb} miss_bytes=${mb} onode_hits=${oh} onode_misses=${om}" >> "${outdir}/hit-rate.txt"
}

run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS}/${LABEL}/${label}"
    mkdir -p "${subdir}"; rm -f "${subdir}/hit-rate.txt" 2>/dev/null
    drop_caches
    collect_hitrate "pre" "${subdir}"
    log "  fio ${label}..."
    fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" || true
    collect_hitrate "post" "${subdir}"
    local hitrate
    hitrate=$(python3 - "${subdir}/hit-rate.txt" <<'PYEOF' 2>/dev/null || echo "N/A"
import sys
lines=[l.strip() for l in open(sys.argv[1]) if l.strip()]
pre=post=None
for l in lines:
    if l.startswith("pre "): pre=l
    if l.startswith("post "): post=l
if not pre or not post: sys.exit(0)
def parse(l):
    d={}
    for p in l.split()[1:]:
        k,v=p.split("=",1); d[k]=int(v)
    return d
pd,ps=parse(pre),parse(post)
dh=ps["hit_bytes"]-pd["hit_bytes"]; dm=ps["miss_bytes"]-pd["miss_bytes"]
print(f"hit_rate={dh/(dh+dm)*100:.2f}%" if (dh+dm)>0 else "hit_rate=N/A")
PYEOF
    )
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    local bw
    bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
    log "  ${label}: BW=${bw:-N/A} MiB/s  ${hitrate}"
}

log "============================================"
log "=== PHASE3-SENSITIVITY label=${LABEL} ==="
log "=== 缓存 256MB, 单进程 128G randread ==="
log "=== ra-default vs ra0 灵敏度验证 ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
log "bluestore_cache_size: $(sudo ceph config get osd bluestore_cache_size 2>/dev/null)"
[ -f "${TEST_DIR}/bigfile.0.0" ] && log "layout: ✅ $(ls -lh ${TEST_DIR}/bigfile.0.0 | awk '{print $5}')" || { log "FATAL: layout missing"; exit 1; }

# ra-default
log "=== ${LABEL}: ra-default ==="
remount_jfs "--max-uploads 150 --cache-size 0"
deterministic_warmup
for r in $(seq 1 "${REPEAT}"); do
    run_fio "randread-${LABEL}-default-r${r}" --name=bigfile --directory="${TEST_DIR}" \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=1 \
        --direct=1 --fallocate=none --openfiles=1 \
        --group_reporting --time_based --runtime=${RUNTIME}
done

# ra0
log "=== ${LABEL}: ra0 ==="
remount_jfs "--max-uploads 150 --cache-size 0 --max-readahead 0"
deterministic_warmup
for r in $(seq 1 "${REPEAT}"); do
    run_fio "randread-${LABEL}-ra0-r${r}" --name=bigfile --directory="${TEST_DIR}" \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=1 \
        --direct=1 --fallocate=none --openfiles=1 \
        --group_reporting --time_based --runtime=${RUNTIME}
done

# 汇总
log "=== 汇总 ${LABEL} ==="
for config in default ra0; do
    local line="  ${config}:"
    for r in $(seq 1 "${REPEAT}"); do
        local bw
        bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/randread-${LABEL}-${config}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
        line="${line} r${r}=${bw:-NA}"
    done
    log "${line}"
done

python3 -c "
import statistics,os,re
def get_med(config):
    vals=[]
    for r in range(1,${REPEAT}+1):
        f='${RESULTS}/${LABEL}/randread-${LABEL}-%s-r%d/fio.txt'%(config,r)
        if os.path.exists(f):
            m=re.search(r'bw=([0-9.]+)MiB',open(f).read())
            if m: vals.append(float(m.group(1)))
    return statistics.median(vals) if vals else 0, vals

d_med,d_vals=get_med('default')
r_med,r_vals=get_med('ra0')
print(f'  default median={d_med:.0f} MiB/s  ra0 median={r_med:.0f} MiB/s')
if d_med>0:
    ratio=r_med/d_med
    print(f'  ra0/default={ratio:.2f}x  (已知 128-job=1.72x)')
    if ratio>1.1: print('  ✅ 敏感：ra0 > default')
    elif ratio<0.9: print('  ✅ 敏感：ra0 < default')
    else: print('  ❌ 不敏感：测不出差异')
for config,vals in [('default',d_vals),('ra0',r_vals)]:
    if len(vals)>1:
        cv=statistics.stdev(vals)/statistics.mean(vals)*100
        med=statistics.median(vals)
        max_dev=max(abs(v-med) for v in vals)/med*100
        print(f'  {config}: CV={cv:.1f}% max_dev={max_dev:.1f}%' + (' ✅ 稳定' if cv<3 and max_dev<5 else ' ❌ 不稳'))
" 2>/dev/null

log "=== ${LABEL} DONE ==="
log "恢复: sudo ceph config set osd bluestore_cache_size 0 + 重启 OSD"
