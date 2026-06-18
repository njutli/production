#!/bin/bash
# block-size verification: build fresh ceph volumes with different --block-size
# (256K / 512K / 1M / 4M-default), then run the SPEC 256k randread on each.
# If small block-size removes the 16x read amplification, 256k randread should
# rise sharply at block-size=256K (request size == block size, 1:1).
# This is the production-relevant test (spec bs=256k is fixed; we tune the volume).
set -uo pipefail
cd /home/turboai/production
source config.sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

LOG=/tmp/opencode/blocksize-sweep.log
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

FS="jfs-bs"
META="tikv://192.168.11.12:2379/${FS}"
POOL="juicefs-data"
MP="/mnt/juicefs"
LAYOUT_NUMJOBS=32
FSZ="1G"
RES="${PWD}/results"
TS=$(date +%Y%m%d-%H%M%S)
SUM="${RES}/blocksize-sweep-${TS}.txt"
log(){ echo "$@" | tee -a "${SUM}"; }

clean(){
  pkill -9 fio 2>/dev/null||true
  fusermount -uz "${MP}" 2>/dev/null|| sudo umount -l "${MP}" 2>/dev/null||true
  sleep 3
}
drop_caches(){ sync||true; sudo sh -c 'echo 3 >/proc/sys/vm/drop_caches' 2>/dev/null||true; find /var/jfsCache -type f -path '*raw*' -delete 2>/dev/null||true; }

destroy_fresh(){
  clean
  sleep 60
  local u; u=$(juicefs status "${META}" 2>/dev/null|grep -o '"UUID": "[^"]*"'|cut -d'"' -f4||true)
  [ -n "${u}" ] && juicefs destroy "${META}" "${u}" --yes 2>&1|tail -1||true
  ssh 192.168.11.11 "sudo cephadm shell -- radosgw-admin bucket rm --bucket=${FS} --purge-objects" 2>/dev/null|tail -1||true
  sleep 5
}

run_one(){  # $1=block-size (e.g. 256K)
  local bsz="$1"
  log ""
  log "########## block-size=${bsz} ##########"
  destroy_fresh
  log ">>> format --block-size ${bsz}"
  juicefs format --storage ceph --bucket "ceph://${POOL}" \
      --access-key ceph --secret-key client.juicefs \
      --block-size "${bsz}" --trash-days 0 "${META}" "${FS}" 2>&1 | grep -E "BlockSize|format@" | tee -a "${SUM}"
  sudo mkdir -p "${MP}"; sudo chown "$(whoami):$(whoami)" "${MP}" 2>/dev/null||true
  juicefs mount -d --cache-size 0 "${META}" "${MP}" 2>&1|tail -1
  sleep 3
  mountpoint -q "${MP}" || { log "FATAL mount bs=${bsz}"; return; }
  mkdir -p "${MP}/test_dir"
  log ">>> layout ${LAYOUT_NUMJOBS}x${FSZ}"
  fio --directory="${MP}/test_dir" --name=storage_test --filesize="${FSZ}" --size="${FSZ}" \
      --bs=4M --rw=write --numjobs="${LAYOUT_NUMJOBS}" --fallocate=none \
      --group_reporting --end_fsync=1 2>&1|grep -E "WRITE:"|tee -a "${SUM}"
  drop_caches
  local rr="${RES}/blocksize-sweep-${TS}-randread-bs${bsz}.txt"
  local st="${RES}/blocksize-sweep-${TS}-stats-bs${bsz}.txt"
  juicefs stats "${MP}" -l 1 --interval 1 --count 65 > "${st}" 2>&1 &
  local sp=$!
  # SPEC randread: bs=256k always (production caliber); only the VOLUME block-size varies
  fio --directory="${MP}/test_dir" --name=storage_test --filesize="${FSZ}" --size="${FSZ}" \
      --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs="${LAYOUT_NUMJOBS}" \
      --direct=1 --fallocate=none --group_reporting --time_based --runtime=60s > "${rr}" 2>&1
  wait "${sp}" 2>/dev/null||true
  local bw; bw=$(grep -E "READ: bw=" "${rr}"|head -1)
  log "block-size=${bsz}, spec 256k randread -> ${bw}"
}

log "=== BLOCK-SIZE SWEEP (spec 256k randread) $(date) ==="
log "pool=${POOL} layout=${LAYOUT_NUMJOBS}x${FSZ}, randread bs=256k(spec), cache-size 0"
run_one 256K
run_one 512K
run_one 1M
run_one 4M

log ""
log ">>> final cleanup"
destroy_fresh
log "=== BLOCK-SIZE SWEEP DONE $(date) ==="
echo "=== BLOCKSIZE DONE exit=0 ==="
