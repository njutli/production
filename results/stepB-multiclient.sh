#!/bin/bash
# ============================================================
# Step B: Multi-client randread aggregation @ ra=0
# 3 clients: tikv(.12) / node1(.11) / node2(.13)
# Task: verify if ra=0 breaks the ~51 ceiling (default ra)
# ============================================================
set -euo pipefail

OUTDIR=/home/turboai/production/results/readahead-sweep-glm-20260630/stepB-multiclient
mkdir -p "$OUTDIR"
LOGFILE="$OUTDIR/stepB.log"
exec > >(tee -a "$LOGFILE") 2>&1

CLIENTS=("192.168.11.12" "192.168.11.11" "192.168.11.13")
CLIENT_NAMES=("tikv" "node1" "node2")
ROUNDS=3
RA_VALUE=0

# ============================================================
# Functions
# ============================================================

drop_all_multiclient() {
  echo "[$(date +%H:%M:%S)] DROP ALL (clients + OSD)"
  # Drop on all 4 unique nodes
  for ip in 192.168.11.12 192.168.11.11 192.168.11.13 192.168.11.14; do
    echo -n "  $ip: "
    if [ "$ip" = "192.168.11.12" ]; then
      sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo "OK" || { echo "FAIL"; return 1; }
    else
      ssh -o ConnectTimeout=10 "$ip" 'sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo OK' || { echo "FAIL"; return 1; }
    fi
  done
  sleep 3
  echo "  DROP COMPLETE"
}

mount_client() {
  local ip="$1" name="$2"
  local mount_log="$OUTDIR/mount-${name}.log"
  echo "[$(date +%H:%M:%S)] MOUNT $name ($ip) ra=$RA_VALUE"
  if [ "$ip" = "192.168.11.12" ]; then
    sudo fusermount -uz /mnt/juicefs 2>/dev/null; sleep 2
    juicefs mount -d --cache-size 0 --max-readahead $RA_VALUE tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs 2>&1 | tee "$mount_log" | tail -1
  else
    ssh -o ConnectTimeout=10 "$ip" "sudo fusermount -uz /mnt/juicefs 2>/dev/null; sleep 2; juicefs mount -d --cache-size 0 --max-readahead $RA_VALUE tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs 2>&1" | tee "$mount_log" | tail -1
  fi
  sleep 3
  grep -q 'writeback and prefetch will be disabled' "$mount_log" || { echo "FATAL: cache=0 not confirmed on $name"; return 1; }
  echo "  $name MOUNT OK (cache=0, ra=$RA_VALUE)"
}

run_fio_on_client() {
  local ip="$1" name="$2" outfile="$3"
  local cmd="fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
    --fallocate=none --openfiles=100 --create_serialize=0 \
    --group_reporting --time_based --runtime=60s"
  if [ "$ip" = "192.168.11.12" ]; then
    timeout 120 bash -c "$cmd" > "$outfile" 2>&1 &
  else
    ssh -n -o ConnectTimeout=10 "$ip" "timeout 120 $cmd" > "$outfile" 2>&1 &
  fi
}

# ============================================================
# Main
# ============================================================
echo "============================================"
echo " Step B: Multi-client randread @ ra=$RA_VALUE"
echo " $(date)"
echo "============================================"
echo "Clients: ${CLIENT_NAMES[*]}"
echo "Rounds: $ROUNDS"
echo ""

# 0. Fix timezone on node2
echo "=== Fix timezone on node2 (.13) ==="
ssh -o ConnectTimeout=10 192.168.11.13 "sudo timedatectl set-timezone Asia/Shanghai && timedatectl | grep 'Time zone'" || echo "WARNING: timezone fix failed"
echo ""

# 1. Mount all clients
for i in 0 1 2; do
  mount_client "${CLIENTS[$i]}" "${CLIENT_NAMES[$i]}" || { echo "MOUNT FAILED for ${CLIENT_NAMES[$i]}"; exit 1; }
done

# 2. Verify files
echo "Files: $(ls /mnt/juicefs/test_dir/storage_test.* 2>/dev/null | wc -l) (expect 128)"
echo ""

# 3. Run rounds
for round in $(seq 1 $ROUNDS); do
  echo ""
  echo "============================================"
  echo " Round $round"
  echo "============================================"

  # Drop all
  drop_all_multiclient || { echo "DROP FAILED"; exit 1; }

  # Start fio on all 3 clients simultaneously
  echo "[$(date +%H:%M:%S)] START FIO on all 3 clients"
  for i in 0 1 2; do
    outfile="$OUTDIR/p${round}-${CLIENT_NAMES[$i]}.txt"
    run_fio_on_client "${CLIENTS[$i]}" "${CLIENT_NAMES[$i]}" "$outfile"
  done

  # Wait for all to finish
  echo "[$(date +%H:%M:%S)] Waiting for all fio to finish..."
  wait
  echo "[$(date +%H:%M:%S)] All fio done"

  # Parse results
  echo ""
  echo "--- Round $round results ---"
  total_bw=0
  for i in 0 1 2; do
    name="${CLIENT_NAMES[$i]}"
    outfile="$OUTDIR/p${round}-${name}.txt"
    bw=$(grep -oP 'READ:.*bw=\K[0-9.]+(?=MiB/s)' "$outfile" | head -1)
    io=$(grep -oP 'READ:.*io=\K[0-9]+(?=MiB)' "$outfile" | head -1)
    echo "  $name: BW=${bw:-NA} MiB/s  io=${io:-NA} MiB"
    if [ -n "$bw" ]; then
      total_bw=$(echo "$total_bw + $bw" | bc)
    fi
  done
  echo "  AGGREGATION: ${total_bw} MiB/s"

done

# 4. Summary
echo ""
echo "============================================"
echo " Step B Summary"
echo "============================================"
echo ""
echo "round | tikv | node1 | node2 | aggregation"
echo "------|------|-------|-------|------------"
for round in $(seq 1 $ROUNDS); do
  vals=""
  total=0
  for name in tikv node1 node2; do
    outfile="$OUTDIR/p${round}-${name}.txt"
    bw=$(grep -oP 'READ:.*bw=\K[0-9.]+(?=MiB/s)' "$outfile" | head -1)
    vals="$vals ${bw:-NA}"
    if [ -n "$bw" ]; then
      total=$(echo "$total + $bw" | bc)
    fi
  done
  echo "$round |$vals | $total"
done

echo ""
echo "Default ra ceiling (deepseek): P1=33.8 P2=50.7 P3=51.3"
echo "ra=0 single client: 51.8 MiB/s"
echo ""

echo "============================================"
echo " Step B DONE $(date)"
echo "============================================"
ls -lh "$OUTDIR/"
