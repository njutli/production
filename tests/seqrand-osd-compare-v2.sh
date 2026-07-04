#!/bin/bash
# ============================================================
# seqrand-osd-compare-v2 重测脚本
# 口径：nj=128, 256K, direct=1, cache-size=0, 128G layout(复用)
# 输出：results/seqrand-osd-compare-v2-20260629/
# ============================================================
set -euo pipefail

OUTDIR=/home/turboai/production/results/seqrand-osd-compare-v2-20260629
mkdir -p "$OUTDIR"
LOGFILE="$OUTDIR/test-script.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== $(date) ==="
echo "Script: $0"
echo "Output: $OUTDIR"

# ====== drop function with verification ======
drop_all() {
  echo ""
  echo "[$(date +%H:%M:%S)] DROP START"
  echo -n "[client] "; sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo "OK" || { echo "client drop FAILED"; return 1; }

  for h in 192.168.11.11 192.168.11.13 192.168.11.14; do
    echo -n "[$h] "
    result=$(ssh -o ConnectTimeout=10 $h 'sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo OK' 2>&1) || { echo "$h SSH FAILED: $result"; return 1; }
    echo "$result"
  done
  echo "[$(date +%H:%M:%S)] DROP DONE"
  sleep 2
}

# ====== OSD collection (before/after delta) ======
collect_osd_before() {
  local tag="$1"
  for osd in 0 1; do
    ssh ceph-node1 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-before.json" 2>/dev/null
  done
  for osd in 2 3; do
    ssh ceph-node2 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-before.json" 2>/dev/null
  done
  for osd in 4 5; do
    ssh ceph-node3 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-before.json" 2>/dev/null
  done
  # Verify
  for osd in 0 1 2 3 4 5; do
    local f="$OUTDIR/${tag}-osd${osd}-before.json"
    [ -s "$f" ] || { echo "OSD$osd before EMPTY"; return 1; }
  done
}

collect_osd_after() {
  local tag="$1"
  for osd in 0 1; do
    ssh ceph-node1 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-after.json" 2>/dev/null
  done
  for osd in 2 3; do
    ssh ceph-node2 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-after.json" 2>/dev/null
  done
  for osd in 4 5; do
    ssh ceph-node3 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-after.json" 2>/dev/null
  done
  # Verify
  for osd in 0 1 2 3 4 5; do
    local f="$OUTDIR/${tag}-osd${osd}-after.json"
    [ -s "$f" ] || { echo "OSD$osd after EMPTY"; return 1; }
  done
}

report_osd_delta() {
  local tag="$1"
  echo ""
  echo "=== OSD delta: $tag ==="
  echo "osd|Δops|avg_lat_ms|node"
  for osd in 0 1 2 3 4 5; do
    local cb=$(grep avgcount "$OUTDIR/${tag}-osd${osd}-before.json" | head -1 | grep -oP '[0-9]+')
    local sb=$(grep '"sum"' "$OUTDIR/${tag}-osd${osd}-before.json" | head -1 | grep -oP '[0-9]+\.[0-9]+')
    local ca=$(grep avgcount "$OUTDIR/${tag}-osd${osd}-after.json" | head -1 | grep -oP '[0-9]+')
    local sa=$(grep '"sum"' "$OUTDIR/${tag}-osd${osd}-after.json" | head -1 | grep -oP '[0-9]+\.[0-9]+')
    local dc=$((ca - cb))
    local avg=$(echo "scale=1; ($sa - $sb) / $dc * 1000" | bc 2>/dev/null || echo "NA")
    case $osd in 0|1) node="node1";; 2|3) node="node2";; 4|5) node="node3";; esac
    printf "%-4s|%-5s|%-9s|%s\n" "$osd" "$dc" "$avg" "$node"
  done
}

# ====== fio runner with NIC RX ======
run_randread() {
  local tag="$1" nj="${2:-128}"
  local f="$OUTDIR/${tag}.txt"
  local rx_before=$(grep eno1 /proc/net/dev | awk '{print $2}')

  timeout 180 fio --directory=/mnt/juicefs/test_dir --name=storage_test \
      --filesize=1G --size=1G --bs=256k --rw=randread \
      --ioengine=libaio --iodepth=128 --numjobs=$nj --direct=1 \
      --fallocate=none --openfiles=100 --create_serialize=0 \
      --group_reporting --time_based --runtime=60s \
      > "$f" 2>&1

  local rx_after=$(grep eno1 /proc/net/dev | awk '{print $2}')
  local rx_delta=$((rx_after - rx_before))
  local bw=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$f")
  local io=$(grep -oP 'io=\K[0-9]+(?=MiB)' "$f" | head -1)
  local ratio=$(echo "scale=2; $rx_delta / ($io * 1048576)" | bc 2>/dev/null || echo "NA")
  echo "  ${tag}: BW=${bw} MiB/s, io=${io}MiB, NIC_RX=$(echo "scale=0; $rx_delta/1048576" | bc)MiB, NIC/FIO=${ratio}"
}

run_seqread() {
  local f="$OUTDIR/seqread-128j.txt"
  local rx_before=$(grep eno1 /proc/net/dev | awk '{print $2}')

  timeout 180 fio --directory=/mnt/juicefs/test_dir --name=storage_test \
      --filesize=1G --size=1G --bs=256k --rw=read \
      --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
      --fallocate=none --openfiles=100 --create_serialize=0 \
      --group_reporting --time_based --runtime=60s \
      > "$f" 2>&1

  local rx_after=$(grep eno1 /proc/net/dev | awk '{print $2}')
  local rx_delta=$((rx_after - rx_before))
  local bw=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$f")
  local io=$(grep -oP 'io=\K[0-9]+(?=MiB)' "$f" | head -1)
  local ratio=$(echo "scale=2; $rx_delta / ($io * 1048576)" | bc 2>/dev/null || echo "NA")
  echo "  seqread: BW=${bw} MiB/s, io=${io}MiB, NIC_RX=$(echo "scale=0; $rx_delta/1048576" | bc)MiB, NIC/FIO=${ratio}"
}

# ====== MAIN ======
echo ""
echo "============================================"
echo " MOUNT: --cache-size 0 (cache=0 confirmed)"
echo " LAYOUT: 128×1G (reused from repro-09)"
echo " FILES: $(ls /mnt/juicefs/test_dir/storage_test.* 2>/dev/null | wc -l)"
echo "============================================"

# ---- Randread 3 rounds ----
echo ""
echo "======== STEP: randread 3 rounds ========"
for i in 1 2 3; do
  echo ""
  echo ">> Round $i"
  drop_all || { echo "DROP FAILED at round $i"; exit 1; }
  run_randread "randread-r${i}"
done

# ---- Seqread ----
echo ""
echo "======== STEP: seqread (direct=1, 128j) ========"
drop_all || { echo "DROP FAILED at seqread"; exit 1; }
run_seqread

# ---- Numjobs sweep ----
echo ""
echo "======== STEP: numjobs sweep ========"
for nj in 8 32 64 256; do
  echo ""
  echo ">> nj=$nj"
  drop_all || { echo "DROP FAILED at nj=$nj"; exit 1; }
  run_randread "randread-nj${nj}" $nj
done

# ---- OSD delta (full fio window) ----
echo ""
echo "======== STEP: OSD delta ========"
drop_all || { echo "DROP FAILED at OSD delta"; exit 1; }
collect_osd_before "osd-delta" || { echo "OSD before FAILED"; exit 1; }

echo "Starting randread for OSD collection..."
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
    --fallocate=none --openfiles=100 --create_serialize=0 \
    --group_reporting --time_based --runtime=60s \
    > "$OUTDIR/osd-delta-fio.txt" 2>&1 &
FIO_PID=$!
sleep 2

echo "fio PID=$FIO_PID, waiting 58s..."
sleep 56
# Collect during fio (before fio ends)
collect_osd_after "osd-delta" || { echo "OSD after FAILED"; exit 1; }
wait $FIO_PID 2>/dev/null
report_osd_delta "osd-delta"

# ---- Summary ----
echo ""
echo "============================================"
echo " DONE $(date)"
echo " Output: $OUTDIR"
echo "============================================"
ls -lh "$OUTDIR/"

# Write env info
echo "juicefs=$(juicefs version 2>&1 | head -1)" > "$OUTDIR/env.txt"
echo "layout=128x1G (reused from repro-09)" >> "$OUTDIR/env.txt"
echo "mount=--cache-size 0" >> "$OUTDIR/env.txt"
echo "block-size=256K" >> "$OUTDIR/env.txt"
echo "pool=juicefs-data (EC 4+2)" >> "$OUTDIR/env.txt"
echo "date=$(date -Iseconds)" >> "$OUTDIR/env.txt"