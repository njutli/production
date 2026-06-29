#!/bin/bash
# ============================================================
# 基线重测第二轮：验证第一轮结果
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="results/baseline-rerun2-20260625"
OUT="${OUTDIR}/summary.txt"
mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "基线重测第二轮（验证） ${TS}"
log "============================================================"
log ""
log "## 口径: STORAGE=ceph, block-size 256K, cache-size 0, client drop_caches, 随机项 REPEAT=3"
log ""

# 环境快照
{
  echo "### ceph health"
  sudo ceph health 2>&1
  echo "### ceph osd tree"
  sudo ceph osd tree 2>&1
  echo "### ceph df"
  sudo ceph df 2>&1
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

log "## 挂载"
juicefs umount "$MNT" 2>/dev/null || true; sleep 2
juicefs mount -d --cache-size 0 "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
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
  echo "# mount: --cache-size 0" >> "$of"
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

run_rand(){
  local name="$1" rw="$2" round="$3"
  local of="${OUTDIR}/${name}-r${round}.txt"
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  check_ceph_health "before ${name} r${round}"
  echo "# ${name} round ${round}: rw=${rw} bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
  echo "# mount: --cache-size 0" >> "$of"
  echo "# date: $(date)" >> "$of"
  fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw="$rw" --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime=60s >> "$of" 2>&1
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name} r${round}: READ=${rd:-NA} WRITE=${wr:-NA}"
  wait_fio
}

log ""
log "## 顺序测试"
mkdir -p "$DIR"
log "### seqread prep (write 4G)"
check_ceph_health "before seqread prep"
rm -rf "$DIR"/*
fio --name=prep --directory="$DIR" --rw=write --refill_buffers --bs=4M --size=4G >/dev/null 2>&1; wait_fio

run_seq "seqread" read 4M 4G 1 0
run_seq "seqwrite" write 4M 4G 1 1
run_seq "multi-seqread" read 4M 4G 16 0
run_seq "multi-seqwrite" write 4M 4G 16 1

log ""
log "## 布局 (128 jobs x 1G = 128G)"
check_ceph_health "before layout"
rm -rf "$DIR"/*
mkdir -p "$DIR"
echo "# layout: 128 jobs x 1G, bs=4M, rw=write, end_fsync=1" > "${OUTDIR}/layout.txt"
echo "# date: $(date)" >> "${OUTDIR}/layout.txt"
fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 \
    >> "${OUTDIR}/layout.txt" 2>&1
lw=$(bwget "${OUTDIR}/layout.txt" WRITE)
log "  layout: WRITE=${lw:-NA}"
wait_fio

log ""
log "## 随机测试 (REPEAT=3)"
for i in 1 2 3; do
  log "### Round ${i}"
  run_rand "randread" randread "$i"
  run_rand "randwrite" randwrite "$i"
  run_rand "randrw" randrw "$i"
done

log ""
log "DONE"
