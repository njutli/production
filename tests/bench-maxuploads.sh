#!/bin/bash
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
OUTDIR="results/maxuploads150-20260626"
OUT="${OUTDIR}/summary.txt"
mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "--max-uploads=150 对照测试 $(date +%Y%m%d-%H%M%S)"
log "============================================================"
log "## 口径: STORAGE=ceph, block-size 256K, cache-size 0, --max-uploads=150"
log "## 目标: 对照默认 --max-uploads=20 的 seqwrite/multi-seqwrite"

{
  echo "### ceph health"
  sudo ceph health 2>&1
  echo "### ceph osd tree"
  sudo ceph osd tree 2>&1
} > "${OUTDIR}/ceph-status.txt" 2>&1

log "## 格式化卷"
juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
sleep 5
UUID=$(juicefs status "$META" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
if [ -n "$UUID" ]; then
  juicefs destroy --yes "$META" "$UUID" 2>&1 | tee "${OUTDIR}/destroy.log" || true
fi
sleep 65

unset ACCESS_KEY SECRET_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
juicefs format \
  --storage ceph \
  --bucket ceph://juicefs-data \
  --access-key ceph \
  --secret-key client.juicefs \
  --block-size 256K \
  --trash-days 0 \
  "$META" juicefs-prod 2>&1 | tee "${OUTDIR}/format.log"

log "## 挂载 (--max-uploads=150)"
juicefs umount "$MNT" 2>/dev/null || true; sleep 2
juicefs mount -d --cache-size 0 --max-uploads 150 "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
sleep 3
mountpoint -q "$MNT" || { log "FATAL: mount failed"; exit 1; }
log "  mount OK"

wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){ grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || true; }

run_seq(){
  local name="$1" rw="$2" bs="$3" size="$4" nj="$5" fsync="$6"
  local of="${OUTDIR}/${name}.txt"
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  check_ceph_health "before ${name}"
  echo "# ${name}: rw=${rw} bs=${bs} size=${size} numjobs=${nj} fsync=${fsync}" > "$of"
  echo "# mount: --cache-size 0 --max-uploads 150" >> "$of"
  echo "# date: $(date)" >> "$of"
  local args="--name=${name} --directory=${DIR} --rw=${rw} --refill_buffers --bs=${bs} --size=${size}"
  [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
  [ "$fsync" = "1" ] && args="$args --end_fsync=1"
  fio $args >> "$of" 2>&1
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name}: READ=${rd:-NA} WRITE=${wr:-NA}"
  wait_fio
}

log ""
log "## 顺序写测试"
mkdir -p "$DIR"

log "### seqwrite prep (write 4G for read baseline)"
check_ceph_health "before prep"
rm -rf "$DIR"/*
fio --name=prep --directory="$DIR" --rw=write --refill_buffers --bs=4M --size=4G >/dev/null 2>&1; wait_fio

run_seq "seqwrite" write 4M 4G 1 1
run_seq "multi-seqwrite" write 4M 4G 16 1

log ""
log "DONE"
