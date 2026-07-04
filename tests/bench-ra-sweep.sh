#!/bin/bash
# ============================================================
# RA Sweep 轻量测试：仅 seqread + randread 3轮，冷态 cache=0
# 每个 ra 值测试前 drop OSD page cache + 客户端 page cache
# 复用已有 128G 布局，不 destroy/format/layout
# ============================================================
# 用法: bench-ra-sweep.sh <ra_value>
#   ra_value: 1 / 2 / 4 / 8
# ============================================================
set -uo pipefail

RA="${1:?usage: $0 ra_value}"

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
SEQ_DIR="${MNT}/seq_dir"
CACHE_DIR="/data/jfsCache"
TS="$(date +%Y%m%d-%H%M%S)"
PARENT="results/patched-v1.3.1-retest-20260702/ra-sweep"
MOUNT_OPTS="--cache-size 0 --max-readahead ${RA}"
OUTDIR="${PARENT}/ra-${RA}"
OUT="${OUTDIR}/summary.md"

mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "RA Sweep ra=${RA} ${TS}"
log "============================================================"
log "## 口径:"
log "  block-size=256K, cache=0, max-readahead=${RA} MiB"
log "  seqread: 1次 (无 direct=1，与历史一致); randread: 3轮"
log "  复用已有 128G 布局，不 destroy/format/layout"
log ""

# ---- OSD cache drop ----
log "## Drop OSD page cache"
for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
  sshpass -p "TurboAi@303" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    turboai@$ip "echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null" 2>/dev/null \
    && log "  $ip cache dropped" || log "  $ip FAILED"
done

# ---- 环境快照 ----
{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
  echo "### ceph osd tree"
  sudo ceph osd tree 2>&1
  echo "### juicefs version"
  juicefs --version 2>&1
  echo "### mount opts: ${MOUNT_OPTS}"
} > "${OUTDIR}/env-snapshot.txt" 2>&1
log "  env snapshot saved"

# ---- 挂载 ----
log "## 挂载"
juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true
sleep 3
juicefs mount -d ${MOUNT_OPTS} "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
sleep 3
mountpoint -q "$MNT" || { log "FATAL: mount failed"; exit 1; }
log "  mount OK"

# ---- 工具函数 ----
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){
  local val unit
  val=$(grep -oP "$2: bw=\K[0-9.]+" "$1" | head -1)
  unit=$(grep -oP "$2: bw=[0-9.]+\K[a-zA-Z]+/s" "$1" | head -1)
  if [ -z "$val" ]; then echo ""; return; fi
  if [ "$unit" = "KiB/s" ]; then
    awk "BEGIN{printf \"%.1f\", $val/1024}"
  else
    echo "$val"
  fi
}
rxget(){ grep eno1 /proc/net/dev | sed 's/:/ /' | awk '{print $2}'; }

# ---- 顺序读 ----
log ""
log "## 顺序读 (bs=256K, 无 direct=1)"
mkdir -p "$SEQ_DIR"
check_ceph_health "before seqread prep"
rm -rf "$SEQ_DIR"/*
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
log "### seqread prep (write 4G)"
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=4G >/dev/null 2>&1
wait_fio

check_ceph_health "before seqread"
SR_OF="${OUTDIR}/seqread.txt"
echo "# seqread: rw=read bs=256K size=4G (no direct=1)" > "$SR_OF"
echo "# mount: ${MOUNT_OPTS}" >> "$SR_OF"
echo "# date: $(date)" >> "$SR_OF"
rx0=$(rxget)
fio --name=seqread --directory="$SEQ_DIR" --rw=read --refill_buffers --bs=256K --size=4G >> "$SR_OF" 2>&1
rx1=$(rxget)
rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
sr=$(bwget "$SR_OF" READ)
log "  seqread: READ=${sr:-NA} NIC_RX=${rxmb}"
wait_fio
rm -rf "$SEQ_DIR"

# ---- 随机读 3轮 ----
log ""
log "## 随机读 (3轮, bs=256K, 128jobs, iodepth=128, direct=1, runtime=60s)"
for i in 1 2 3; do
  check_ceph_health "before randread r${i}"
  RR_OF="${OUTDIR}/randread-r${i}.txt"
  echo "# randread round ${i}: bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$RR_OF"
  echo "# mount: ${MOUNT_OPTS}" >> "$RR_OF"
  echo "# date: $(date)" >> "$RR_OF"
  rx0=$(rxget)
  fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime=60s >> "$RR_OF" 2>&1
  rx1=$(rxget)
  rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  rr=$(bwget "$RR_OF" READ)
  log "  randread r${i}: READ=${rr:-NA} NIC_RX=${rxmb}"
  wait_fio
done

# ---- 收尾 ----
{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
} > "${OUTDIR}/ceph-status-after.txt" 2>&1

log ""
log "DONE"

# ---- commands.sh ----
cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# Commands: ra-sweep ra=${RA} (patched v1.3.1)
# binary: /usr/local/bin/juicefs (patched, v1.3.1+2025-12-02.e0032b2a)

# drop OSD cache (all Ceph nodes)
for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
  sshpass -p "TurboAi@303" ssh turboai@\$ip "echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null"
done

# mount
juicefs mount -d --cache-size 0 --max-readahead ${RA} tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# sequential read (no direct=1)
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G

# random read (3 rounds)
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
CMDEOF
chmod +x "${OUTDIR}/commands.sh"

log "  commands.sh generated"
