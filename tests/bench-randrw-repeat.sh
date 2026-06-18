#!/bin/bash
# Repeat the randrw acceptance-caliber test N times on a fresh ceph volume of a
# given block-size, to rule out run-to-run variance. randrw verbatim spec
# (256k, iodepth=128, numjobs=128, direct=1, time_based 60s, --create_on_open).
# Usage: bench-randrw-repeat.sh <block-size e.g. 256K|4M> <N>
set -uo pipefail
cd /home/turboai/production
source config.sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

BSZ="${1:?usage: bench-randrw-repeat.sh <block-size> <N>}"
N="${2:?usage: bench-randrw-repeat.sh <block-size> <N>}"
FS="jfs-rrw"
META="tikv://192.168.11.12:2379/${FS}"
POOL="juicefs-data"
MP="/mnt/juicefs"
RES="${PWD}/results"
TS=$(date +%Y%m%d-%H%M%S)
SUM="${RES}/randrw-repeat-${BSZ}-${TS}.txt"
log(){ echo "$@" | tee -a "${SUM}"; }

clean(){ pkill -9 fio 2>/dev/null||true; fusermount -uz "${MP}" 2>/dev/null|| sudo umount -l "${MP}" 2>/dev/null||true; sleep 3; }
drop_caches(){ sync||true; sudo sh -c 'echo 3 >/proc/sys/vm/drop_caches' 2>/dev/null||true; find /var/jfsCache -type f -path '*raw*' -delete 2>/dev/null||true; }

fresh(){
  clean; sleep 60
  local u; u=$(juicefs status "${META}" 2>/dev/null|grep -o '"UUID": "[^"]*"'|cut -d'"' -f4||true)
  [ -n "${u}" ] && juicefs destroy "${META}" "${u}" --yes 2>&1|tail -1||true
  ssh 192.168.11.11 "sudo cephadm shell -- radosgw-admin bucket rm --bucket=${FS} --purge-objects" 2>/dev/null|tail -1||true
  sleep 5
  juicefs format --storage ceph --bucket "ceph://${POOL}" --access-key ceph --secret-key client.juicefs \
      --block-size "${BSZ}" --trash-days 0 "${META}" "${FS}" 2>&1|grep -E "BlockSize"|tee -a "${SUM}"
  sudo mkdir -p "${MP}"; sudo chown "$(whoami):$(whoami)" "${MP}" 2>/dev/null||true
  juicefs mount -d --cache-size 0 "${META}" "${MP}" 2>&1|tail -1
  sleep 3; mountpoint -q "${MP}"||{ log "FATAL mount"; exit 1; }
}

randrw_once(){  # $1 = run index ; verbatim acceptance spec
  rm -rf "${MP}/test_dir"; mkdir -p "${MP}/test_dir"; drop_caches
  local out="${RES}/randrw-repeat-${BSZ}-${TS}-run${1}.txt"
  fio --directory="${MP}/test_dir" --name=storage_test --nrfiles=100 --filesize=1G --size=1G \
      --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
      --fallocate=none --create_on_open=1 --openfiles=100 --group_reporting \
      --time_based --runtime=60s > "${out}" 2>&1
  local r w; r=$(grep -E "READ: bw=" "${out}"|head -1|sed 's/^ *//'); w=$(grep -E "WRITE: bw=" "${out}"|head -1|sed 's/^ *//')
  log "run${1}:  ${r}   |   ${w}"
}

log "=== randrw repeat (block-size=${BSZ}, N=${N}) $(date) ==="
log "verbatim spec: 256k randrw iodepth=128 numjobs=128 direct=1 time_based 60s, cache-size 0"
fresh
for i in $(seq 1 "${N}"); do randrw_once "$i"; done
log ""
log ">>> cleanup"
clean; sleep 60
u=$(juicefs status "${META}" 2>/dev/null|grep -o '"UUID": "[^"]*"'|cut -d'"' -f4||true)
[ -n "${u}" ] && juicefs destroy "${META}" "${u}" --yes 2>&1|tail -1||true
log "=== randrw repeat DONE $(date) ==="
echo "=== RANDRW-REPEAT DONE bs=${BSZ} exit=0 ==="
