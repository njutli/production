#!/bin/bash
set -euo pipefail
OUTDIR=/home/turboai/production/results/readahead-sweep-20260630
LOGFILE="$OUTDIR/sweep.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== $(date) ==="

drop_all() {
  echo "[$(date +%H:%M:%S)] DROP"
  echo -n "  client "; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo "OK" || { echo "FAIL"; return 1; }
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    echo -n "  $ip "; ssh -o ConnectTimeout=10 $ip 'sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo OK' || { echo "FAIL"; return 1; }
  done
  sleep 2
}

collect_osd() {
  local tag="$1" suffix="$2"
  for osd in 0 1; do ssh 192.168.11.11 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-${suffix}.json" 2>/dev/null; done
  for osd in 2 3; do ssh 192.168.11.13 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-${suffix}.json" 2>/dev/null; done
  for osd in 4 5; do ssh 192.168.11.14 "sudo cephadm shell -- ceph daemon osd.$osd perf dump osd" > "$OUTDIR/${tag}-osd${osd}-${suffix}.json" 2>/dev/null; done
  for osd in 0 1 2 3 4 5; do [ -s "$OUTDIR/${tag}-osd${osd}-${suffix}.json" ] || { echo "OSD$osd $suffix EMPTY"; return 1; }; done
}

run_fio() {
  local tag="$1" rw="$2" nj="$3"
  local f="$OUTDIR/${tag}.txt"
  drop_all || exit 1
  
  # OSD before
  collect_osd "$tag" "before" || exit 1
  
  local rx_before=$(grep eno1 /proc/net/dev | awk '{print $2}')
  timeout 240 fio --directory=/mnt/juicefs/test_dir --name=storage_test \
      --filesize=1G --size=1G --bs=256k --rw=${rw} \
      --ioengine=libaio --iodepth=128 --numjobs=${nj} --direct=1 \
      --fallocate=none --openfiles=100 --create_serialize=0 \
      --group_reporting --time_based --runtime=60s > "$f" 2>&1
  
  # OSD after (during drain)
  sleep 2
  collect_osd "$tag" "after" || exit 1
  
  local rx_after=$(grep eno1 /proc/net/dev | awk '{print $2}')
  local rx_delta=$((rx_after - rx_before))
  local IO=$(grep -oP 'io=\K[0-9]+(?=MiB)' "$f" | head -1)
  
  if [ "$rw" = "randrw" ]; then
    local bw_r=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$f" | head -1)
    local bw_w=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=MiB/s)' "$f" | head -1)
    echo "  $tag RW=${bw_r}/${bw_w} io=${IO}MiB RX=$(echo "scale=0; $rx_delta/1048576" | bc)MiB"
  else
    local bw=$(grep -oP "${rw^^}: bw=\K[0-9.]+(?=MiB/s)" "$f" | head -1)
    [ -z "$bw" ] && bw=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$f" | head -1)
    [ -z "$bw" ] && bw=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=MiB/s)' "$f" | head -1)
    echo "  $tag BW=${bw} io=${IO}MiB RX=$(echo "scale=0; $rx_delta/1048576" | bc)MiB"
  fi
}

# Main sweep
for RA in default 8 4 1 0; do
  echo ""; echo "========================================"; echo " RA=$RA"; echo "========================================"
  
  # Remount with new ra (skip for default = current mount)
  if [ "$RA" != "default" ]; then
    sudo fusermount -uz /mnt/juicefs 2>/dev/null; sleep 2
    juicefs mount -d --cache-size 0 --max-readahead $RA tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs 2>&1 | tail -1
    sleep 3
  fi
  mountpoint -q /mnt/juicefs || { echo "MOUNT FAIL"; exit 1; }
  
  LABEL="ra${RA}"
  for rw in randread randwrite randrw; do
    for i in 1 2 3; do
      run_fio "${LABEL}-${rw}-r${i}" "$rw" 128
    done
  done
done

echo ""; echo "=== DONE $(date) ==="
