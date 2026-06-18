#!/bin/bash
# Read-amplification verification: same 4MB-block ceph volume, pure randread at
# multiple bs (256k / 1M / 4M). If bandwidth rises monotonically with bs,
# read amplification is confirmed as the bottleneck.
# Each randread runs with juicefs stats captured to compare object-layer throughput.
set -uo pipefail
cd /home/turboai/production
source config.sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

LOG=/tmp/opencode/bs-sweep.log
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

FS="jfs-bssweep"
META="tikv://192.168.11.12:2379/${FS}"
POOL="juicefs-data"
MP="/mnt/juicefs"
LAYOUT_NUMJOBS=32          # 32 jobs x 1G = 32G working set
FSZ="1G"
RES="${PWD}/results"
TS=$(date +%Y%m%d-%H%M%S)
SUM="${RES}/bs-sweep-${TS}.txt"
log(){ echo "$@" | tee -a "${SUM}"; }

clean(){
  pkill -9 fio 2>/dev/null||true
  fusermount -uz "${MP}" 2>/dev/null|| sudo umount -l "${MP}" 2>/dev/null||true
  sleep 3
}
drop_caches(){ sync||true; sudo sh -c 'echo 3 >/proc/sys/vm/drop_caches' 2>/dev/null||true; find /var/jfsCache -type f -path '*raw*' -delete 2>/dev/null||true; }

log "=== BS SWEEP (read amplification test) $(date) ==="
log "volume=${FS} block-size=4M(default) pool=${POOL} layout=${LAYOUT_NUMJOBS}x${FSZ}"
clean

# fresh volume
U=$(juicefs status "${META}" 2>/dev/null|grep -o '"UUID": "[^"]*"'|cut -d'"' -f4||true)
[ -n "${U}" ] && juicefs destroy "${META}" "${U}" --yes 2>/dev/null|tail -1||true
ssh 192.168.11.11 "sudo cephadm shell -- radosgw-admin bucket rm --bucket=${FS} --purge-objects" 2>/dev/null|tail -1||true
sleep 5

log ">>> format (block-size=4M default)"
juicefs format --storage ceph --bucket "ceph://${POOL}" \
    --access-key ceph --secret-key client.juicefs \
    --trash-days 0 "${META}" "${FS}" 2>&1|tail -2|tee -a "${SUM}"
sudo mkdir -p "${MP}"; sudo chown "$(whoami):$(whoami)" "${MP}" 2>/dev/null||true
juicefs mount -d --cache-size 0 "${META}" "${MP}" 2>&1|tail -1|tee -a "${SUM}"
sleep 3
mountpoint -q "${MP}" || { log "FATAL mount"; exit 1; }
mkdir -p "${MP}/test_dir"

log ">>> layout ${LAYOUT_NUMJOBS}x${FSZ}"
fio --directory="${MP}/test_dir" --name=storage_test --filesize="${FSZ}" --size="${FSZ}" \
    --bs=4M --rw=write --numjobs="${LAYOUT_NUMJOBS}" --fallocate=none \
    --group_reporting --end_fsync=1 2>&1|grep -E "WRITE:"|tee -a "${SUM}"

run_bs(){  # $1=bs
  local bs="$1"
  drop_caches
  local rr="${RES}/bs-sweep-${TS}-randread-${bs}.txt"
  local st="${RES}/bs-sweep-${TS}-stats-${bs}.txt"
  juicefs stats "${MP}" -l 1 --interval 1 --count 65 > "${st}" 2>&1 &
  local sp=$!
  fio --directory="${MP}/test_dir" --name=storage_test --filesize="${FSZ}" --size="${FSZ}" \
      --bs="${bs}" --rw=randread --ioengine=libaio --iodepth=128 --numjobs="${LAYOUT_NUMJOBS}" \
      --direct=1 --fallocate=none --group_reporting --time_based --runtime=60s > "${rr}" 2>&1
  wait "${sp}" 2>/dev/null||true
  local bw; bw=$(grep -E "READ: bw=" "${rr}"|head -1)
  # avg object get throughput from stats (col 'get' under object) — rough mean of non-zero
  log "bs=${bs} -> ${bw}"
}

log ""
log "########## randread bs sweep (256k / 1M / 4M) ##########"
run_bs 256k
run_bs 1M
run_bs 4M

log ""
log ">>> cleanup"
clean
sleep 65
U=$(juicefs status "${META}" 2>/dev/null|grep -o '"UUID": "[^"]*"'|cut -d'"' -f4||true)
[ -n "${U}" ] && juicefs destroy "${META}" "${U}" --yes 2>&1|tail -1|tee -a "${SUM}"||true
log "=== BS SWEEP DONE $(date) ==="
echo "=== BSSWEEP DONE exit=0 ==="
