#!/bin/bash
set -euo pipefail
export LC_ALL=C
# BUFFER-OFF-TEST.sh — bluestore_default_buffered_read=false 下 128-job 灵敏度验证
# 与 T6（osd_memory_target=2GB）对比，验证是否同样稳定且敏感
LABEL="${1:-BO}"; RUNTIME=180; REPEAT=3
TEST_DIR="/mnt/juicefs/test_dir"; BW_LOG_DIR="/tmp/jfs-bw"; RESULTS="/tmp/opencode-fullbaseline-v3"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"
NIC_IF="enp139s0f0np0"
mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }
drop_caches() { sync;echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null;for ip in "${SLAVES[@]}";do ${SSHPASS_CMD}@${ip} 'sync;echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null' 2>/dev/null||true;done;rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null||true; }
compact_cooldown() { local ol;ol=$(sudo ceph osd ls 2>/dev/null|tr '\n' ' ');for osd in ${ol};do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null||true;done;for i in $(seq 1 60);do local ad=true;for osd in ${ol};do local r q;read -r r q < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null|python3 -c 'import sys,json;x=json.load(sys.stdin).get("rocksdb",{});print(x.get("compact_running",1),x.get("compact_queue_len",1))' 2>/dev/null||echo "1 1");[ "$r" = "0" ]||ad=false;[ "$q" = "0" ]||ad=false;done;$ad&&break;sleep 5;done;log "  compact done"; }
collect_hitrate() { local tag="$1" outdir="$2";local ol;ol=$(sudo ceph osd ls 2>/dev/null|tr '\n' ' ');local hb=0 mb=0;for osd in ${ol};do read -r h m _ < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null|python3 -c 'import sys,json;b=json.load(sys.stdin).get("bluestore",{});print(int(b.get("buffer_hit_bytes",0)),int(b.get("buffer_miss_bytes",0)),0)' 2>/dev/null||echo "0 0 0");hb=$((hb+h));mb=$((mb+m));done;echo "${tag} hit_bytes=${hb} miss_bytes=${mb}">>"${outdir}/hit-rate.txt"; }
run_fio() { local label="$1";shift;local sd="${RESULTS}/${LABEL}/${label}";mkdir -p "${sd}";rm -f "${sd}/hit-rate.txt";drop_caches;(while true;do echo "$(date +%s)|$(cat /proc/net/dev|grep ${NIC_IF})";sleep 1;done)>"${sd}/nic.txt"&local np=$!;collect_hitrate "pre" "${sd}";log "  fio ${label}...";fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 2>&1|tee "${sd}/fio.txt"||true;collect_hitrate "post" "${sd}";local bw;bw=$(grep -oE 'bw=[0-9.]+MiB' "${sd}/fio.txt" 2>/dev/null|head -1|grep -oE '[0-9.]+'||true);kill ${np} 2>/dev/null||true;wait ${np} 2>/dev/null||true;cp ${BW_LOG_DIR}/*_bw.*.log "${sd}/" 2>/dev/null||true;rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null||true;log "  ${label}: BW=${bw:-N/A} MiB/s"; }

log "=== BUFFER-OFF label=${LABEL} (bluestore_default_buffered_read=false) ==="

# warmup
log "  warmup"
for f in ${TEST_DIR}/storage_test.*.0; do dd if="$f" of=/dev/null bs=4M 2>/dev/null; done
compact_cooldown; drop_caches

# default
log "=== ${LABEL}: default ==="
for r in $(seq 1 ${REPEAT}); do
    run_fio "randread-${LABEL}-default-r${r}" --directory="${TEST_DIR}" --name=storage_test \
        --filesize=1G --size=1G --bs=256k --rw=randread \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=${RUNTIME}
done

# remount ra0
log "=== remount ra0 ==="
fusermount -u /mnt/juicefs 2>/dev/null; pkill -f 'juicefs.*mount' 2>/dev/null; sleep 5
juicefs mount -d --max-uploads 150 --cache-size 0 --max-readahead 0 tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod /mnt/juicefs 2>&1 | tail -1
sleep 3; mkdir -p "${TEST_DIR}"

# warmup
log "  warmup ra0"
for f in ${TEST_DIR}/storage_test.*.0; do dd if="$f" of=/dev/null bs=4M 2>/dev/null; done
compact_cooldown; drop_caches

# ra0
log "=== ${LABEL}: ra0 ==="
for r in $(seq 1 ${REPEAT}); do
    run_fio "randread-${LABEL}-ra0-r${r}" --directory="${TEST_DIR}" --name=storage_test \
        --filesize=1G --size=1G --bs=256k --rw=randread \
        --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=${RUNTIME}
done

# summary
log "=== Summary ${LABEL} ==="
python3 2>/dev/null <<'PYEOF' || true
import statistics,os,re
def get_vals(c):
    v=[]
    for r in range(1,4):
        f="/tmp/opencode-fullbaseline-v3/%s/randread-%s-%s-r%d/fio.txt"%("${LABEL}","${LABEL}",c,r)
        if os.path.exists(f):
            m=re.search(r'bw=([0-9.]+)MiB',open(f).read())
            if m: v.append(float(m.group(1)))
    return v
d=get_vals('default'); r=get_vals('ra0')
if d: print(f"  default: {[int(x) for x in d]} median={statistics.median(d):.0f}")
if r: print(f"  ra0: {[int(x) for x in r]} median={statistics.median(r):.0f}")
if d and r:
    dm=statistics.median(d);rm=statistics.median(r)
    print(f"  ratio={rm/dm:.2f}x (T6 osd_memory_target=2GB: 1.96x)")
    for c,v in [('default',d),('ra0',r)]:
        if len(v)>1:
            cv=statistics.stdev(v)/statistics.mean(v)*100
            md=statistics.median(v)
            mx=max(abs(x-md) for x in v)/md*100
            print(f"  {c}: CV={cv:.1f}% max_dev={mx:.1f}%" + (" ✅" if cv<3 and mx<5 else " ❌"))
PYEOF
log "=== ${LABEL} DONE ==="
