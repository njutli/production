#!/bin/bash
set -euo pipefail
export LC_ALL=C

# 128JOB-SHRUNK-CACHE.sh — 128-job + 缓存缩到 0% 后的灵敏度验证
# 前提：osd_memory_target=2GB 已注入、bigfile.0.0 (128G) 存在

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"; TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"; RESULTS="/tmp/opencode-fullbaseline-v3"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

LABEL="${1:-T5}"; RUNTIME=180; REPEAT=3

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in "${SLAVES[@]}"; do ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; done
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

compact_cooldown() {
    local osd_list; osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${osd_list}; do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    for i in $(seq 1 60); do
        local all_done=true
        for osd in ${osd_list}; do
            read -r r q < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c 'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
            [ "$r" = "0" ] || all_done=false; [ "$q" = "0" ] || all_done=false
        done
        $all_done && break; sleep 5
    done
    log "  compact done"
}

collect_hitrate() {
    local tag="$1"; local outdir="$2"
    local osd_list; osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    local hb=0 mb=0
    for osd in ${osd_list}; do
        read -r h m _ _ < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);b=d.get("bluestore",{});print(int(b.get("buffer_hit_bytes",0)),int(b.get("buffer_miss_bytes",0)),0,0)' 2>/dev/null || echo "0 0 0 0")
        hb=$((hb+h)); mb=$((mb+m))
    done
    echo "${tag} ts=$(date +%s) hit_bytes=${hb} miss_bytes=${mb}" >> "${outdir}/hit-rate.txt"
}

run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS}/${LABEL}/${label}"; mkdir -p "${subdir}"; rm -f "${subdir}/hit-rate.txt"
    drop_caches
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) > "${subdir}/nic.txt" & local npid=$!
    collect_hitrate "pre" "${subdir}"
    log "  fio ${label}..."
    fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 2>&1 | tee "${subdir}/fio.txt" || true
    collect_hitrate "post" "${subdir}"
    local hr
    hr=$(python3 - "${subdir}/hit-rate.txt" 2>/dev/null <<'EOF' || echo N/A
import sys
L=[l.strip() for l in open(sys.argv[1]) if l.strip()]
p=q=None
for l in L:
    if l.startswith("pre "): p=l
    if l.startswith("post "): q=l
if not p or not q: sys.exit(0)
def pa(l):
    d={}
    for x in l.split()[1:]:
        k,v=x.split("=",1);d[k]=int(v)
    return d
pd,qd=pa(p),pa(q)
dh=qd["hit_bytes"]-pd["hit_bytes"]; dm=qd["miss_bytes"]-pd["miss_bytes"]
print("hit_rate=%.2f%%" % (dh/(dh+dm)*100) if (dh+dm)>0 else "hit_rate=N/A")
EOF
    )
    kill $npid 2>/dev/null; wait $npid 2>/dev/null
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null; rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null
    local bw; bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
    log "  ${label}: BW=${bw:-N/A} MiB/s  ${hr}"
}

remount_jfs() {
    local opts="$1"; log "  remount（${opts}）"
    fusermount -u "${MNT}" 2>/dev/null; pkill -f 'juicefs.*mount' 2>/dev/null; sleep 5
    for t in 1 2 3; do juicefs mount -d ${opts} "${META}" "${MNT}" 2>&1 | tail -1; sleep 3; mount | grep -q juice && break; sleep 10; done
    mount | grep -q juice || { log "FATAL"; exit 1; }; mkdir -p "${TEST_DIR}"
}

warmup() {
    log "  warmup: 顺序读 128G"
    for f in ${TEST_DIR}/bigfile*; do [ -f "$f" ] && dd if="$f" of=/dev/null bs=4M 2>/dev/null; done
    log "  warmup done"; compact_cooldown; drop_caches
}

log "=== 128JOB-SHRUNK-CACHE label=${LABEL} ==="
log "=== 128-job + osd_memory_target=2GB → 稳定且敏感？ ==="

# 确认缓存配置
log "memory_target: $(sudo ceph tell osd.0 config get osd_memory_target 2>/dev/null)"
[ -f "${TEST_DIR}/bigfile.0.0" ] || { log "FATAL: layout missing"; exit 1; }

# ra-default
log "=== ${LABEL}: ra-default (128-job) ==="
remount_jfs "--max-uploads 150 --cache-size 0"
warmup
for r in $(seq 1 "${REPEAT}"); do
    run_fio "randread128-${LABEL}-default-r${r}" --name=bigfile --directory="${TEST_DIR}" \
        --filesize=128G --size=128G --bs=256k --rw=randread \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=${RUNTIME}
done

# ra0
log "=== ${LABEL}: ra0 (128-job) ==="
remount_jfs "--max-uploads 150 --cache-size 0 --max-readahead 0"
warmup
for r in $(seq 1 "${REPEAT}"); do
    run_fio "randread128-${LABEL}-ra0-r${r}" --name=bigfile --directory="${TEST_DIR}" \
        --filesize=128G --size=128G --bs=256k --rw=randread \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=${RUNTIME}
done

# 汇总
log "=== 汇总 ${LABEL} ==="
for c in default ra0; do
    local line="  ${c}:"
    for r in $(seq 1 "${REPEAT}"); do
        local bw; bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/randread128-${LABEL}-${c}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
        line="${line} r${r}=${bw:-NA}"
    done
    log "${line}"
done

python3 2>/dev/null <<'PYEOF' || true
import statistics,os,re
def get_vals(c):
    v=[]
    for r in range(1,${REPEAT}+1):
        f="${RESULTS}/${LABEL}/randread128-${LABEL}-%s-r%d/fio.txt"%(c,r)
        if os.path.exists(f):
            m=re.search(r'bw=([0-9.]+)MiB',open(f).read())
            if m: v.append(float(m.group(1)))
    return v
d=get_vals('default'); r=get_vals('ra0')
if d and r:
    dm=statistics.median(d); rm=statistics.median(r)
    print(f"  default median={dm:.0f} ra0 median={rm:.0f} ratio={rm/dm:.2f}x (V2 128-job=1.72x)")
    for c,v in [('default',d),('ra0',r)]:
        if len(v)>1:
            cv=statistics.stdev(v)/statistics.mean(v)*100
            md=statistics.median(v)
            mx=max(abs(x-md) for x in v)/md*100
            print(f"  {c}: CV={cv:.1f}% max_dev={mx:.1f}%" + (" ✅ 稳定" if cv<3 and mx<5 else " ❌ 不稳"))
    ratio=rm/dm
    print("  ✅ 敏感" if ratio>1.1 else "  ❌ 不敏感")
PYEOF
log "=== ${LABEL} DONE ==="
