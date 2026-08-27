#!/usr/bin/env bash
set -euo pipefail

BIN=/tmp/juicefs-03-8
BIN_MD5=de93563f11a5ff3bd94dd25a4e0283b1
META='tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod'
MNT=/mnt/juicefs
TEST_DIR=/mnt/juicefs/test_dir
MOUNT_OPTS='--max-uploads 150 --cache-size 0 --max-fuse-io 256K'
SYS_CONF=/etc/ceph/ceph.conf
PRIVATE_CONF=/tmp/t57-msgr8.conf

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; }

# msgr=8 private conf
cp "$SYS_CONF" "$PRIVATE_CONF"
printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
export CEPH_CONF="$PRIVATE_CONF"

# unmount if any
fuser -k "$MNT" 2>/dev/null || true
sleep 1
umount -l "$MNT" 2>/dev/null || true
sleep 1

# mount
"$BIN" mount -d $MOUNT_OPTS "$META" "$MNT" >> /tmp/t57-mount.log 2>&1
sleep 10
mountpoint -q "$MNT" || { log "STOP mount failed"; exit 6; }

PID=$(pgrep -f "juicefs-03-8.*juicefs-prod" | head -1)
_proc_ceph_conf=$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | awk -F= '$1=="CEPH_CONF"{print $2}')
[[ -n "$_proc_ceph_conf" && "$(grep -c 'ms_async_op_threads = 8' "$_proc_ceph_conf" 2>/dev/null || echo 0)" -eq 1 ]] || { log "STOP msgr!=8"; exit 6; }
log "mount OK pid=$PID msgr=8"

# verify files
for n in 128 64 32; do
  cnt=$(find "$TEST_DIR" -maxdepth 1 -type f -name "storage_test.*.0" 2>/dev/null | wc -l)
  [[ "$cnt" -ge 128 ]] || { log "STOP layout files=$cnt < 128"; exit 6; }
done
log "layout OK (128 files)"

# jfs stats helper
grab_stats() {
  local label=$1
  local out=$2
  curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E 'juicefs_meta_ops_(duration_seconds_Write|total_Write)|juicefs_transaction_durations_histogram_seconds_(sum|total)' > "$out"
}

run_fio() {
  local nj=$1
  local label=$2
  local outdir=/tmp/t57-${label}
  mkdir -p "$outdir"

  log "$label: fio numjobs=$nj starting"
  grab_stats "${label}-pre" "$outdir/stats-pre.txt"

  fio --directory="$TEST_DIR" --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 \
    --numjobs=$nj --direct=1 --fallocate=none --openfiles=$nj \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="$outdir/bw" --log_avg_msec=1000 \
    > "$outdir/fio.txt" 2>&1

  grab_stats "${label}-post" "$outdir/stats-post.txt"

  local bw=$(grep -oP 'WRITE: bw=\K[0-9]+MiB' "$outdir/fio.txt" | head -1)
  log "$label: fio done BW=$bw numjobs=$nj"
}

# drop caches between runs
drop_caches() {
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
    sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$ip" 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
  done
}

# compact
"$BIN" gc --compact 2>/dev/null || true
sleep 5

# Run 1: numjobs=64
drop_caches
sleep 2
run_fio 64 nj64
drop_caches
sleep 2

# Run 2: numjobs=32
run_fio 32 nj32

# unmount
fuser -k "$MNT" 2>/dev/null || true
sleep 1
umount -l "$MNT" 2>/dev/null || true
log "T57 DONE"
