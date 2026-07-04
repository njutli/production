#!/bin/bash
# ============================================================
# 暖态 mu=150 全量测试（patched v1.3.1）
# cache=100G, mu=150, 先预热再测, rand 5轮
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
SEQ_DIR="${MNT}/seq_dir"
CACHE_DIR="/data/jfsCache"
TS="$(date +%Y%m%d-%H%M%S)"
PARENT="results/patched-v1.3.1-retest-20260702"
MOUNT_OPTS="--cache-size 102400 --cache-dir $CACHE_DIR --max-uploads 150"
OUTDIR="${PARENT}/full-bs256k-warm-mu150-full"
OUT="${OUTDIR}/summary.md"

mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "暖态 mu=150 全量测试 ${TS}（patched v1.3.1，预热+5轮）"
log "============================================================"
log "## 口径:"
log "  block-size=256K, cache=100G, max-uploads=150"
log "  seq: 1次; rand: 5轮"
log "  先预热（读 128G test_dir 填充 cache），再正式测"
log "  复用冷态布局，不 destroy/format/layout"
log ""

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

# ---- 挂载 ----
log "## 挂载"
juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true
sleep 3
rm -rf "$CACHE_DIR"/* 2>/dev/null || true
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

run_seq(){
  local name="$1" rw="$2" nj="$3" fsync="$4"
  local of="${OUTDIR}/${name}.txt"
  check_ceph_health "before ${name}"
  echo "# ${name}: rw=${rw} bs=256K size=4G numjobs=${nj} fsync=${fsync}" > "$of"
  echo "# mount: ${MOUNT_OPTS}" >> "$of"
  echo "# date: $(date)" >> "$of"
  local args="--name=${name} --directory=${SEQ_DIR} --rw=${rw} --refill_buffers --bs=256K --size=4G"
  [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
  [ "$fsync" = "1" ] && args="$args --end_fsync=1"
  local rx0; rx0=$(rxget)
  fio $args >> "$of" 2>&1
  local rx1; rx1=$(rxget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name}: READ=${rd:-NA} WRITE=${wr:-NA} NIC_RX=${rxmb}"
  wait_fio
}

run_rand(){
  local name="$1" rw="$2" round="$3"
  local of="${OUTDIR}/${name}-r${round}.txt"
  check_ceph_health "before ${name} r${round}"
  echo "# ${name} round ${round}: rw=${rw} bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
  echo "# mount: ${MOUNT_OPTS}" >> "$of"
  echo "# date: $(date)" >> "$of"
  local rx0; rx0=$(rxget)
  fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw="$rw" --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime=60s >> "$of" 2>&1
  local rx1; rx1=$(rxget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name} r${round}: READ=${rd:-NA} WRITE=${wr:-NA} NIC_RX=${rxmb}"
  wait_fio
}

# ---- 预热 ----
log ""
log "## 预热（读 128G test_dir 填充 cache）"
check_ceph_health "before preheat"
PREHEAT_OF="${OUTDIR}/preheat.txt"
echo "# preheat: read 128G test_dir, bs=4M, 128jobs" > "$PREHEAT_OF"
echo "# date: $(date)" >> "$PREHEAT_OF"
fio --directory="$DIR" --name=preheat --filesize=1G --size=1G \
    --bs=4M --rw=read --numjobs=128 --fallocate=none --group_reporting \
    >> "$PREHEAT_OF" 2>&1
ph=$(bwget "$PREHEAT_OF" READ)
log "  preheat: READ=${ph:-NA}"
wait_fio
log "  预热完成"

# ---- 顺序测试 ----
log ""
log "## 顺序测试 (bs=256K)"
mkdir -p "$SEQ_DIR"
log "### seqread prep (write 4G)"
check_ceph_health "before seqread prep"
rm -rf "$SEQ_DIR"/*
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=4G >/dev/null 2>&1; wait_fio

run_seq "seqread" read 1 0
run_seq "seqwrite" write 1 1
run_seq "multi-seqread" read 16 0
run_seq "multi-seqwrite" write 16 1
rm -rf "$SEQ_DIR"

# ---- 随机测试 5轮 ----
log ""
log "## 随机测试 (5轮, bs=256K, 128jobs, iodepth=128, direct=1, runtime=60s)"
for i in 1 2 3 4 5; do
  log "### Round ${i}"
  run_rand "randread" randread "$i"
  run_rand "randwrite" randwrite "$i"
  run_rand "randrw" randrw "$i"
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
# Commands: warm-mu150-full (patched v1.3.1)
# binary: /usr/local/bin/juicefs (patched, v1.3.1+2025-12-02.e0032b2a)

# mount
juicefs mount -d --cache-size 102400 --cache-dir /data/jfsCache --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# preheat
fio --directory=/mnt/juicefs/test_dir --name=preheat --filesize=1G --size=1G --bs=4M --rw=read --numjobs=128 --fallocate=none --group_reporting

# sequential tests (bs=256K)
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1

# random tests (bs=256K, 5 rounds)
# ... (repeated 5 times)
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
CMDEOF
chmod +x "${OUTDIR}/commands.sh"

log "  commands.sh generated"
