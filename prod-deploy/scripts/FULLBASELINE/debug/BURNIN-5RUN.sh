#!/bin/bash
set -euo pipefail
export LC_ALL=C

# BURNIN-5RUN.sh — V3.9 档2: SNIA burn-in 稳态可复现性验证（5 次独立 Run）
# 配置: autotune=true, osd_memory_target=350GiB（生产配置）
# 每次 Run: warmup → 10 轮 randread 128-job → 取稳态中位数
# Run 间: 重启全部 OSD（全新起点）

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/opencode-fullbaseline-v3/BURNIN"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"
FSID="f8137e5a-8af2-11f1-aa1c-4df480fc234d"
NUM_RUNS=5
ROUNDS=10
RUNTIME=180

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in "${SLAVES[@]}"; do ${SSHPASS_CMD}@${ip} 'sync;echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null' 2>/dev/null || true; done
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

compact_cooldown() {
    local ol; ol=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${ol}; do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    for i in $(seq 1 60); do
        local ad=true
        for osd in ${ol}; do
            local r q
            read -r r q < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c 'import sys,json;x=json.load(sys.stdin).get("rocksdb",{});print(x.get("compact_running",1),x.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
            [ "$r" = "0" ] || ad=false; [ "$q" = "0" ] || ad=false
        done
        $ad && break; sleep 5
    done
    log "  compact done"
}

collect_hitrate() {
    local tag="$1" outdir="$2"
    local ol; ol=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    local hb=0 mb=0
    for osd in ${ol}; do
        read -r h m _ < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c 'import sys,json;b=json.load(sys.stdin).get("bluestore",{});print(int(b.get("buffer_hit_bytes",0)),int(b.get("buffer_miss_bytes",0)),0)' 2>/dev/null || echo "0 0 0")
        hb=$((hb+h)); mb=$((mb+m))
    done
    echo "${tag} hit_bytes=${hb} miss_bytes=${mb}" >> "${outdir}/hit-rate.txt"
}

restart_osds() {
    log "  restarting OSDs..."
    # Node 150: osd.0, osd.1
    ${SSHPASS_CMD}@10.20.1.150 'sudo systemctl restart ceph-'${FSID}'@osd.0.service ceph-'${FSID}'@osd.1.service 2>&1' || true
    # Node 151: osd.2, osd.3
    ${SSHPASS_CMD}@10.20.1.151 'sudo systemctl restart ceph-'${FSID}'@osd.2.service ceph-'${FSID}'@osd.3.service 2>&1' || true
    # Node 152: osd.4, osd.5
    ${SSHPASS_CMD}@10.20.1.152 'sudo systemctl restart ceph-'${FSID}'@osd.4.service ceph-'${FSID}'@osd.5.service 2>&1' || true
    # Wait for recovery
    for i in $(seq 1 60); do
        local h; h=$(sudo ceph health 2>/dev/null)
        echo "$h" | grep -q "HEALTH_OK" && break
        sleep 5
    done
    log "  OSDs restarted: $(sudo ceph health 2>/dev/null)"
    compact_cooldown
    drop_caches
}

remount_jfs() {
    log "  remounting JuiceFS (default readahead)"
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    juicefs mount -d --max-uploads 150 --cache-size 0 "${META}" "${MNT}" 2>&1 | tail -1
    sleep 3
    mount | grep -q juice || { log "FATAL: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

run_one() {
    local run_num="$1"
    local run_dir="${RESULTS}/Run${run_num}"
    mkdir -p "${run_dir}"

    log "=== Run${run_num} start ==="

    # Ensure JuiceFS mounted with default
    mount | grep -q juice || remount_jfs

    # Warmup
    log "  Run${run_num} warmup"
    for f in ${TEST_DIR}/storage_test.*.0; do
        [ -f "$f" ] && dd if="$f" of=/dev/null bs=4M 2>/dev/null
    done
    compact_cooldown
    drop_caches

    # 10 rounds
    for r in $(seq 1 ${ROUNDS}); do
        local subdir="${run_dir}/r${r}"
        mkdir -p "${subdir}"
        rm -f "${subdir}/hit-rate.txt"
        drop_caches
        ( while true; do echo "$(date +%s)|$(cat /proc/net/dev|grep ${NIC_IF})"; sleep 1; done ) > "${subdir}/nic.txt" & local npid=$!
        collect_hitrate "pre" "${subdir}"
        log "  Run${run_num} r${r}..."
        fio --directory="${TEST_DIR}" --name=storage_test \
            --filesize=1G --size=1G --bs=256k --rw=randread \
            --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
            --fallocate=none --openfiles=128 --group_reporting \
            --time_based --runtime=${RUNTIME} \
            --write_bw_log="${BW_LOG_DIR}/burnin-run${run_num}-r${r}" --log_avg_msec=1000 \
            2>&1 | tee "${subdir}/fio.txt" || true
        collect_hitrate "post" "${subdir}"
        kill ${npid} 2>/dev/null || true; wait ${npid} 2>/dev/null || true
        cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
        rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
        local bw; bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
        local hr; hr=$(python3 - "${subdir}/hit-rate.txt" <<'PYEOF' 2>/dev/null || echo "N/A"
import sys
L=[l.strip() for l in open(sys.argv[1]) if l.strip()]
p=q=None
for l in L:
    if l.startswith("pre "): p=l
    if l.startswith("post "): q=l
if not p or not q: sys.exit(0)
def pa(l):
    d={}
    for x in l.split()[1:]: k,v=x.split("=",1); d[k]=int(v)
    return d
pd,qd=pa(p),pa(q)
dh=qd["hit_bytes"]-pd["hit_bytes"]; dm=qd["miss_bytes"]-pd["miss_bytes"]
print("hit_rate=%.1f%%" % (dh/(dh+dm)*100) if (dh+dm)>0 else "hit_rate=N/A")
PYEOF
        )
        log "  Run${run_num} r${r}: BW=${bw:-N/A} MiB/s  ${hr}"
        echo "run${run_num} r${r} BW=${bw:-NA} ${hr}" >> "${RESULTS}/summary.txt"
    done

    # Compute steady-state value
    local val; val=$(python3 - "${run_dir}" <<'PYEOF' 2>/dev/null || echo "N/A"
import statistics, os, re, sys
vals=[]
for r in range(1,11):
    f=os.path.join(sys.argv[1], "r%d"%r, "fio.txt")
    if os.path.exists(f):
        m=re.search(r'bw=([0-9.]+)MiB', open(f).read())
        if m: vals.append(float(m.group(1)))
if len(vals)<5:
    print("N/A (only %d rounds)"%len(vals)); sys.exit(0)
# Find steady-state window: 5 consecutive rounds with max-min <= 20% of mean
for start in range(len(vals)-4):
    window=vals[start:start+5]
    mn=min(window); mx=max(window); mean=sum(window)/5
    if (mx-mn)/mean <= 0.20:
        med=statistics.median(window)
        # Check slope: (last - first) / first < 10%
        slope=abs(window[-1]-window[0])/window[0]
        if slope < 0.10:
            print("Value=%.0f window=r%d-r%d mean=%.0f max-min=%.1f%%" % (med, start+1, start+5, mean, (mx-mn)/mean*100))
            sys.exit(0)
# No window found, use last 5
window=vals[-5:]
med=statistics.median(window)
print("Value=%.0f (no steady window, last-5 median) max-min=%.1f%%" % (med, (max(window)-min(window))/(sum(window)/5)*100))
PYEOF
    )
    log "  Run${run_num} result: ${val}"
    echo "Run${run_num}: ${val}" >> "${RESULTS}/values.txt"

    log "=== Run${run_num} done ==="
}

# Main
log "=== BURNIN 5-Run validation start ==="
log "Config: autotune=true, osd_memory_target=350GiB, default readahead, 128x1G layout"

for run_num in $(seq 1 ${NUM_RUNS}); do
    run_one "${run_num}"
    if [ "${run_num}" -lt "${NUM_RUNS}" ]; then
        log "=== Restarting OSDs for Run${run_num} ==="
        restart_osds
    fi
done

# Final summary
log "=== Final Summary ==="
log "Values:"
cat "${RESULTS}/values.txt" 2>/dev/null

python3 - "${RESULTS}/values.txt" <<'PYEOF' 2>/dev/null || true
import sys, statistics
lines=[l.strip() for l in open(sys.argv[1]) if l.strip()]
vals=[]
for l in lines:
    # Extract Value=XXX from "RunN: Value=XXX ..."
    parts=l.split()
    for p in parts:
        if p.startswith("Value="):
            try: vals.append(float(p.split("=")[1]))
            except: pass
if len(vals)>=2:
    print("Values: %s" % vals)
    med=statistics.median(vals)
    mx=max(vals); mn=min(vals)
    cv=statistics.stdev(vals)/statistics.mean(vals)*100 if len(vals)>1 else 0
    spread=(mx-mn)/med*100
    print("Median=%.0f CV=%.1f%% spread=%.1f%% range=%.0f-%.0f" % (med, cv, spread, mn, mx))
    if spread < 5:
        print("VERDICT: ✅ burn-in effective (reproducible)")
    elif spread < 15:
        print("VERDICT: ⚠️ partially effective")
    else:
        print("VERDICT: ❌ burn-in ineffective (E6 required)")
PYEOF

log "=== BURNIN DONE ==="
