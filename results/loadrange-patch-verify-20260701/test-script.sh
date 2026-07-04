#!/bin/bash
# V1: patched loadRange condition - randread + seqread verification
# Compare with readahead-sweep-glm-20260630 baseline (ra=0)
set -euo pipefail

JUICEFS=/tmp/juicefs-patched-clean
OUTDIR=/home/turboai/production/results/loadrange-patch-verify-20260701
mkdir -p "$OUTDIR"
LOGFILE="$OUTDIR/test-script.log"
exec > >(tee -a "$LOGFILE") 2>&1

NIC_IF=eno1
FIO_DIR=/mnt/juicefs/test_dir
WORKLOADS=("randread" "seqread")
ROUNDS=3

OSD_HOST_0=192.168.11.11
OSD_HOST_2=192.168.11.13
OSD_HOST_4=192.168.11.14

drop_all() {
  echo "[$(date +%H:%M:%S)] DROP ALL"
  echo -n "  client(.12): "
  sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo "OK" || { echo "FAIL"; return 1; }
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    echo -n "  osd($ip): "
    ssh -o ConnectTimeout=10 "$ip" 'sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo OK' || { echo "FAIL"; return 1; }
  done
  sleep 3
  echo "  DROP COMPLETE"
}

mount_juicefs() {
  local mount_log="$OUTDIR/mount.log"
  echo "[$(date +%H:%M:%S)] MOUNT (patched, cache=0, ra=0)"
  sudo fusermount -uz /mnt/juicefs 2>/dev/null; sleep 2
  pgrep -x juicefs >/dev/null 2>&1 && { echo "FATAL: juicefs still running"; return 1; }
  $JUICEFS mount -d --cache-size 0 --max-readahead 0 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs 2>&1 | tee "$mount_log" | tail -1
  sleep 3
  grep -q 'writeback and prefetch will be disabled' "$mount_log" || { echo "FATAL: cache=0 not confirmed"; return 1; }
  echo "  MOUNT OK"
  local nfiles
  nfiles=$(ls $FIO_DIR/storage_test.* 2>/dev/null | wc -l)
  echo "  FILES: $nfiles (expect 128)"
  [ "$nfiles" -eq 128 ] || { echo "FATAL: expected 128 files"; return 1; }
}

collect_osd_json() {
  local tag="$1" suffix="$2"
  local host
  for osd in 0 1 2 3 4 5; do
    case $osd in
      0|1) host=$OSD_HOST_0 ;;
      2|3) host=$OSD_HOST_2 ;;
      4|5) host=$OSD_HOST_4 ;;
    esac
    local outfile="$OUTDIR/${tag}-osd${osd}-${suffix}.json"
    ssh -o ConnectTimeout=10 "$host" "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd 2>/dev/null" > "$outfile" 2>/dev/null
    [ -s "$outfile" ] || { echo "FATAL: OSD$osd $suffix empty"; return 1; }
    grep -q '"op_r"' "$outfile" || { echo "FATAL: OSD$osd $suffix missing op_r"; return 1; }
  done
  echo "  OSD $suffix: 6/6 OK"
}

get_nic_rx() {
  grep "$NIC_IF" /proc/net/dev | awk '{print $2}'
}

run_fio_with_collection() {
  local tag="$1" rw="$2"
  local fio_file="$OUTDIR/${tag}-fio.txt"
  local nic_file="$OUTDIR/${tag}-nic.txt"

  local rx_before
  rx_before=$(get_nic_rx)

  collect_osd_json "$tag" "before" || return 1

  echo "  [$(date +%H:%M:%S)] FIO START ($rw, 60s)"
  timeout 120 fio --directory=$FIO_DIR --name=storage_test \
      --filesize=1G --size=1G --bs=256k --rw="$rw" \
      --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
      --fallocate=none --openfiles=100 --create_serialize=0 \
      --group_reporting --time_based --runtime=60s > "$fio_file" 2>&1 &
  local fio_pid=$!

  sleep 50
  collect_osd_json "$tag" "after" || { kill $fio_pid 2>/dev/null; return 1; }

  wait $fio_pid
  local fio_rc=$?
  echo "  [$(date +%H:%M:%S)] FIO DONE (rc=$fio_rc)"

  local rx_after
  rx_after=$(get_nic_rx)
  local rx_delta=$((rx_after - rx_before))
  local rx_delta_mib
  rx_delta_mib=$(echo "scale=1; $rx_delta / 1048576" | bc)

  local read_bw write_bw read_io write_io
  read_bw=$(grep -oP 'READ:.*bw=\K[0-9.]+(?=MiB/s)' "$fio_file" | head -1)
  write_bw=$(grep -oP 'WRITE:.*bw=\K[0-9.]+(?=MiB/s)' "$fio_file" | head -1)
  read_io=$(grep -oP 'READ:.*io=\K[0-9]+(?=MiB)' "$fio_file" | head -1)
  write_io=$(grep -oP 'WRITE:.*io=\K[0-9]+(?=MiB)' "$fio_file" | head -1)

  if [ -z "$read_bw" ]; then
    read_bw=$(grep -oP 'READ:.*bw=\K[0-9.]+(?=GiB/s)' "$fio_file" | head -1)
    [ -n "$read_bw" ] && read_bw=$(echo "$read_bw * 1024" | bc)
  fi

  echo "  RESULT: read_bw=${read_bw:-NA} read_io=${read_io:-NA} write_bw=${write_bw:-NA} write_io=${write_io:-NA}"
  echo "  NIC: rx_delta=${rx_delta}B (${rx_delta_mib} MiB)"

  {
    echo "rx_before=$rx_before"
    echo "rx_after=$rx_after"
    echo "rx_delta=$rx_delta"
    echo "rx_delta_mib=$rx_delta_mib"
    echo "read_bw=${read_bw:-NA}"
    echo "read_io=${read_io:-NA}"
    echo "write_bw=${write_bw:-NA}"
    echo "write_io=${write_io:-NA}"
  } > "$nic_file"
}

# ============================================================
echo "============================================"
echo " V1: patched loadRange verify"
echo " Binary: $JUICEFS"
echo " $(date)"
echo "============================================"
echo "Workloads: ${WORKLOADS[*]}"
echo "Rounds: $ROUNDS"
echo ""

{
  $JUICEFS version 2>&1 | head -1
  echo "date=$(date -Iseconds)"
  echo "block-size=256K"
  echo "numjobs=128"
  echo "iodepth=128"
  echo "runtime=60s"
  echo "direct=1"
  echo "cache-size=0"
  echo "max-readahead=0"
  echo "nic=$NIC_IF"
  echo "osd_map: 0,1->.11; 2,3->.13; 4,5->.14"
  echo "patch: cached_store.go line 153 + !CacheEnabled()"
} > "$OUTDIR/env.txt"

while pgrep -x fio >/dev/null 2>&1; do
  echo "WARNING: fio still running, waiting..."
  sleep 5
done

mount_juicefs || { echo "MOUNT FAILED"; exit 1; }

for rw in "${WORKLOADS[@]}"; do
  echo ""
  echo "--- $rw ---"
  for round in $(seq 1 $ROUNDS); do
    echo ""
    echo "[$(date +%H:%M:%S)] rw=$rw round=$round"
    while pgrep -x fio >/dev/null 2>&1; do sleep 5; done
    drop_all || { echo "DROP FAILED"; exit 1; }
    run_fio_with_collection "patched-${rw}-r${round}" "$rw" || { echo "RUN FAILED"; continue; }
  done
done

echo ""
echo "============================================"
echo " Summary"
echo " $(date)"
echo "============================================"
echo ""
echo "rw | round | read_bw | read_io | rx_mib"
echo "---|---|---|---|---"
for rw in "${WORKLOADS[@]}"; do
  for round in $(seq 1 $ROUNDS); do
    tag="patched-${rw}-r${round}"
    nic_file="$OUTDIR/${tag}-nic.txt"
    if [ -f "$nic_file" ]; then
      read_bw=$(grep -oP 'read_bw=\K\S+' "$nic_file")
      read_io=$(grep -oP 'read_io=\K\S+' "$nic_file")
      rx_mib=$(grep -oP 'rx_delta_mib=\K\S+' "$nic_file")
      echo "$rw | $round | ${read_bw:-NA} | ${read_io:-NA} | ${rx_mib:-NA}"
    else
      echo "$rw | $round | MISSING | MISSING | MISSING"
    fi
  done
done

echo ""
echo "============================================"
echo " ALL DONE $(date)"
echo "============================================"
ls -lh "$OUTDIR/"
