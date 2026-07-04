#!/bin/bash
# ============================================================
# seqrand-osd-compare-FINAL 完整测试
# 所有数据来自同一次冷态 run
# ============================================================
set -euo pipefail

OUTDIR=/home/turboai/production/results/seqrand-osd-compare-final-20260629
mkdir -p "$OUTDIR"
LOGFILE="$OUTDIR/test-script.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== $(date) ==="
echo "Script: $0"
echo "Output: $OUTDIR"

# ====== 0. Setup ======
sudo fusermount -uz /mnt/juicefs 2>/dev/null; sleep 2
juicefs mount -d --cache-size 0 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs 2>&1 | tee "$OUTDIR/mount.log" | tail -1
sleep 3
grep -q 'writeback and prefetch will be disabled' "$OUTDIR/mount.log" || { echo "FATAL: cache=0 not confirmed"; exit 1; }
echo "MOUNT: cache=0 confirmed"
echo "FILES: $(ls /mnt/juicefs/test_dir/storage_test.* 2>/dev/null | wc -l)"

# ====== Functions ======
drop_all() {
  echo "[$(date +%H:%M:%S)] DROP"
  echo -n "  client "; sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo "OK" || { echo "FAIL"; return 1; }
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    echo -n "  $ip "
    ssh -o ConnectTimeout=10 $ip 'sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo OK' || { echo "FAIL"; return 1; }
  done
  sleep 2
}

# Set historic_ops threshold (one time)
setup_historic_ops() {
  for osd in 0 1 2 3 4 5; do
    case $osd in
      0|1) host=192.168.11.11 ;; 2|3) host=192.168.11.13 ;; 4|5) host=192.168.11.14 ;;
    esac
    ssh $host "sudo cephadm shell -- ceph daemon osd.$osd config set osd_op_history_size 200" 2>/dev/null
    ssh $host "sudo cephadm shell -- ceph daemon osd.$osd config set osd_op_history_duration 600" 2>/dev/null
  done
}

collect_osd_json() {
  local tag="$1" suffix="$2"
  for osd in 0 1; do
    ssh 192.168.11.11 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-${suffix}.json" 2>/dev/null
  done
  for osd in 2 3; do
    ssh 192.168.11.13 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-${suffix}.json" 2>/dev/null
  done
  for osd in 4 5; do
    ssh 192.168.11.14 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-${suffix}.json" 2>/dev/null
  done
  for osd in 0 1 2 3 4 5; do
    [ -s "$OUTDIR/${tag}-osd${osd}-${suffix}.json" ] || { echo "OSD$osd $suffix EMPTY"; return 1; }
  done
}

report_osd_delta() {
  local tag="$1"
  echo "osd|Δops|avg_ms|node"
  for osd in 0 1 2 3 4 5; do
    local cb=$(grep avgcount "$OUTDIR/${tag}-osd${osd}-before.json" | head -1 | grep -oP '[0-9]+')
    local sb=$(grep '"sum"' "$OUTDIR/${tag}-osd${osd}-before.json" | head -1 | grep -oP '[0-9]+\.[0-9]+')
    local ca=$(grep avgcount "$OUTDIR/${tag}-osd${osd}-after.json" | head -1 | grep -oP '[0-9]+')
    local sa=$(grep '"sum"' "$OUTDIR/${tag}-osd${osd}-after.json" | head -1 | grep -oP '[0-9]+\.[0-9]+')
    local dc=$((ca - cb))
    local avg=$(echo "scale=4; a=($sa - $sb) * 1000 / $dc; scale=1; a/1" | bc 2>/dev/null || echo "NA")
    case $osd in 0|1) node="node1";; 2|3) node="node2";; 4|5) node="node3";; esac
    printf "%-4s|%-5s|%-6s|%s\n" "$osd" "$dc" "$avg" "$node"
  done
}

collect_historic_ops() {
  local tag="$1"
  for osd in 0 1; do
    ssh 192.168.11.11 "sudo cephadm shell -- ceph daemon osd.$osd dump_historic_ops 2>/dev/null | head -500" > "$OUTDIR/${tag}-osd${osd}-historic.txt" 2>/dev/null
  done
  for osd in 2 3; do
    ssh 192.168.11.13 "sudo cephadm shell -- ceph daemon osd.$osd dump_historic_ops 2>/dev/null | head -500" > "$OUTDIR/${tag}-osd${osd}-historic.txt" 2>/dev/null
  done
  for osd in 4 5; do
    ssh 192.168.11.14 "sudo cephadm shell -- ceph daemon osd.$osd dump_historic_ops 2>/dev/null | head -500" > "$OUTDIR/${tag}-osd${osd}-historic.txt" 2>/dev/null
  done
}

run_fio_base() {
  local tag="$1" rw="$2" nj="$3" rt="${4:-60}"
  local f="$OUTDIR/${tag}.txt"
  local rx_before=$(grep eno1 /proc/net/dev | awk '{print $2}')
  timeout 240 fio --directory=/mnt/juicefs/test_dir --name=storage_test \
      --filesize=1G --size=1G --bs=256k --rw=$rw \
      --ioengine=libaio --iodepth=128 --numjobs=$nj --direct=1 \
      --fallocate=none --openfiles=100 --create_serialize=0 \
      --group_reporting --time_based --runtime=${rt}s > "$f" 2>&1
  local rx_after=$(grep eno1 /proc/net/dev | awk '{print $2}')
  local rx_delta=$((rx_after - rx_before))
  local bw=$(grep -oP "${rw^^}: bw=\K[0-9.]+(?=MiB/s)" "$f" | head -1)
  local io_mb=$(grep -oP 'io=\K[0-9]+(?=MiB)' "$f" | head -1)
  local ratio=$(echo "scale=2; $rx_delta / ($io_mb * 1048576)" | bc 2>/dev/null || echo "NA")
  echo "  $tag BW=${bw} io=${io_mb}MiB RX=${rx_delta} NIC/FIO=${ratio}"
}

# ====== 0b. Setup historic_ops ======
echo ""
echo "=== Setup historic_ops threshold ==="
setup_historic_ops
echo "Done"

# ====== 1. Baseline bandwidth run (NO strace) ======
echo ""
echo "============================================"
echo " STEP 1: Baseline bandwidth (no strace)"
echo "============================================"

echo ""
echo ">> randread 3 rounds"
for i in 1 2 3; do
  drop_all || exit 1
  run_fio_base "baseline-randread-r${i}" "randread" 128
done

echo ""
echo ">> seqread"
drop_all || exit 1
run_fio_base "baseline-seqread" "read" 128

echo ""
echo ">> numjobs sweep"
for nj in 8 32 64 256; do
  drop_all || exit 1
  run_fio_base "baseline-nj${nj}" "randread" $nj
done

# ====== 2. Measurement run A: randread (WITH strace + OSD) ======
echo ""
echo "============================================"
echo " STEP 2: Run A - randread full collection"
echo "============================================"

drop_all || exit 1

# Identify Ceph FDs
CEPH_PID=$(ps aux | grep '[/]usr/local/bin/juicefs' | awk '{print $2}' | head -1)
echo "Ceph PID: $CEPH_PID"
sudo ss -tnp 2>/dev/null | grep "pid=$CEPH_PID" | grep -E ':680[0-9]' | while read line; do
  fd=$(echo "$line" | grep -oP 'fd=\K[0-9]+')
  addr=$(echo "$line" | awk '{print $5}')
  echo "  FD $fd -> $addr"
done | sort -t' ' -k2 -n > "$OUTDIR/fd-map-randread.txt"
cat "$OUTDIR/fd-map-randread.txt"

# OSD before
collect_osd_json "runA" "before" || { echo "OSD before FAILED"; exit 1; }

# Start strace
sudo strace -f -e trace=read -p $CEPH_PID -o "$OUTDIR/strace-randread.log" 2>/dev/null &
STRACE_PID=$!
sleep 2

# NIC before + fio
rx_before=$(grep eno1 /proc/net/dev | awk '{print $2}')
timeout 240 fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
    --fallocate=none --openfiles=100 --create_serialize=0 \
    --group_reporting --time_based --runtime=60s \
    > "$OUTDIR/runA-fio.txt" 2>&1

# OSD after (during drain)
sleep 2
collect_osd_json "runA" "after" || { echo "OSD after FAILED"; exit 1; }

rx_after=$(grep eno1 /proc/net/dev | awk '{print $2}')
sudo kill $STRACE_PID 2>/dev/null; sleep 3

# Report
rx_delta=$((rx_after - rx_before))
bw=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$OUTDIR/runA-fio.txt" | head -1)
echo "  runA randread BW=${bw} RX=$(echo "scale=0; $rx_delta/1048576" | bc)MiB"
echo "  strace: $(wc -l < "$OUTDIR/strace-randread.log") lines ($(ls -lh "$OUTDIR/strace-randread.log" | awk '{print $5}'))"

echo ""
echo ">> runA OSD delta"
report_osd_delta "runA"

# Historic ops (immediately after fio)
echo ""
echo ">> runA historic_ops"
collect_historic_ops "runA"
for osd in 0 1 2 3 4 5; do
  sz=$(stat -c%s "$OUTDIR/runA-osd${osd}-historic.txt" 2>/dev/null || echo 0)
  echo "  osd${osd}: $sz bytes"
done

# ====== 3. Measurement run B: seqread (WITH strace + OSD) ======
echo ""
echo "============================================"
echo " STEP 3: Run B - seqread full collection"
echo "============================================"

drop_all || exit 1

# Re-check FDs (may have changed)
CEPH_PID=$(ps aux | grep '[/]usr/local/bin/juicefs' | awk '{print $2}' | head -1)
sudo ss -tnp 2>/dev/null | grep "pid=$CEPH_PID" | grep -E ':680[0-9]' | while read line; do
  fd=$(echo "$line" | grep -oP 'fd=\K[0-9]+')
  addr=$(echo "$line" | awk '{print $5}')
  echo "  FD $fd -> $addr"
done | sort -t' ' -k2 -n > "$OUTDIR/fd-map-seqread.txt"

collect_osd_json "runB" "before" || exit 1

sudo strace -f -e trace=read -p $CEPH_PID -o "$OUTDIR/strace-seqread.log" 2>/dev/null &
STRACE_PID=$!
sleep 2

rx_before=$(grep eno1 /proc/net/dev | awk '{print $2}')
timeout 240 fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=read \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
    --fallocate=none --openfiles=100 --create_serialize=0 \
    --group_reporting --time_based --runtime=60s \
    > "$OUTDIR/runB-fio.txt" 2>&1

sleep 2
collect_osd_json "runB" "after" || exit 1

rx_after=$(grep eno1 /proc/net/dev | awk '{print $2}')
sudo kill $STRACE_PID 2>/dev/null; sleep 3

rx_delta=$((rx_after - rx_before))
bw=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$OUTDIR/runB-fio.txt" | head -1)
echo "  runB seqread BW=${bw} RX=$(echo "scale=0; $rx_delta/1048576" | bc)MiB"
echo "  strace: $(wc -l < "$OUTDIR/strace-seqread.log") lines ($(ls -lh "$OUTDIR/strace-seqread.log" | awk '{print $5}'))"

echo ""
echo ">> runB OSD delta"
report_osd_delta "runB"

# Historic ops
echo ""
echo ">> runB historic_ops"
collect_historic_ops "runB"
for osd in 0 1 2 3 4 5; do
  sz=$(stat -c%s "$OUTDIR/runB-osd${osd}-historic.txt" 2>/dev/null || echo 0)
  echo "  osd${osd}: $sz bytes"
done

# ====== Save env ======
echo "juicefs=$(juicefs version 2>&1 | head -1)" > "$OUTDIR/env.txt"
echo "layout=128x1G (reused)" >> "$OUTDIR/env.txt"
echo "mount=--cache-size 0" >> "$OUTDIR/env.txt"
echo "block-size=256K" >> "$OUTDIR/env.txt"
echo "date=$(date -Iseconds)" >> "$OUTDIR/env.txt"

echo ""
echo "============================================"
echo " DONE $(date)"
echo "============================================"
ls -lh "$OUTDIR/"