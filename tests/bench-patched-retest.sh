#!/bin/bash
# ============================================================
# Patched v1.3.1 重测：bs=256K / block-size=256K
# 基于 bench-full-bs256k.sh，修改：父目录、暖态跳过layout、bwget修复KiB/s
# ============================================================
# 用法: bench-patched-retest.sh <tag> <mode> [mount_extra]
#   tag:  cold-cache0 / cold-cache0-ra0 / warm-cache100g / warm-cache100g-ra0 / warm-cache100g-mu150
#   mode: cold / warm
#   mount_extra: 额外挂载参数（如 --max-readahead 0 或 --max-uploads 150）
# ============================================================
set -uo pipefail

TAG="${1:?usage: $0 tag mode [mount_extra]}"
MODE="${2:?mode: cold or warm}"
MOUNT_EXTRA="${3:-}"

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
SEQ_DIR="${MNT}/seq_dir"
CACHE_DIR="/data/jfsCache"
TS="$(date +%Y%m%d-%H%M%S)"
PARENT_DIR="results/patched-v1.3.1-retest-20260702"

if [ "$MODE" = "cold" ]; then
    BASE_MOUNT="--cache-size 0"
    DO_FORMAT=1
    DO_DROP=1
    DO_LAYOUT=1
elif [ "$MODE" = "warm" ]; then
    BASE_MOUNT="--cache-size 102400 --cache-dir $CACHE_DIR"
    DO_FORMAT=0
    DO_DROP=0
    DO_LAYOUT=0
else
    echo "mode must be cold or warm"
    exit 1
fi

MOUNT_OPTS="$BASE_MOUNT $MOUNT_EXTRA"
OUTDIR="${PARENT_DIR}/full-bs256k-${TAG}-${TS}"
OUT="${OUTDIR}/summary.md"
mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "全量测试 ${TAG} ${TS}"
log "============================================================"
log "## 口径:"
log "  block-size=256K, fio seq bs=256K, fio rand bs=256K"
log "  mode=${MODE}, mount_opts=${MOUNT_OPTS}"
log "  seq: 1次; rand: 3轮"
log "  DO_FORMAT=${DO_FORMAT}, DO_LAYOUT=${DO_LAYOUT}"
log ""

{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
  echo "### ceph osd tree"
  sudo ceph osd tree 2>&1
  echo "### ceph df"
  sudo ceph df 2>&1
  echo "### client"
  uname -a
  free -h
  echo "### juicefs version"
  juicefs --version 2>&1
  echo "### fio version"
  fio --version 2>&1
} > "${OUTDIR}/env-snapshot.txt" 2>&1
log "  env snapshot -> ${OUTDIR}/env-snapshot.txt"

if [ "$DO_FORMAT" = "1" ]; then
    log "## 格式化卷"
    juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    sleep 5
    UUID=$(juicefs status "$META" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
    if [ -n "$UUID" ]; then
        juicefs destroy --yes "$META" "$UUID" 2>&1 | tee "${OUTDIR}/destroy.log" || true
    fi
    sleep 65

    juicefs format \
      --storage ceph \
      --bucket ceph://juicefs-data \
      --access-key ceph \
      --secret-key client.juicefs \
      --block-size 256K \
      --trash-days 0 \
      "$META" juicefs-prod 2>&1 | tee "${OUTDIR}/format.log"
fi

log "## 挂载"
juicefs umount "$MNT" 2>/dev/null || true; sleep 2
if [ "$MODE" = "warm" ]; then
    rm -rf "$CACHE_DIR"/* 2>/dev/null || true
fi
juicefs mount -d ${MOUNT_OPTS} "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
sleep 3
mountpoint -q "$MNT" || { log "FATAL: mount failed"; exit 1; }
log "  mount OK"

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
  if [ "$DO_DROP" = "1" ]; then
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  fi
  check_ceph_health "before ${name}"
  echo "# ${name}: rw=${rw} bs=256K size=4G numjobs=${nj} fsync=${fsync}" > "$of"
  echo "# mount: ${MOUNT_OPTS}" >> "$of"
  echo "# block-size: 256K, fio bs: 256K" >> "$of"
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
  if [ "$DO_DROP" = "1" ]; then
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  fi
  check_ceph_health "before ${name} r${round}"
  echo "# ${name} round ${round}: rw=${rw} bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
  echo "# mount: ${MOUNT_OPTS}" >> "$of"
  echo "# block-size: 256K, fio bs: 256K" >> "$of"
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

log ""
log "## 顺序测试 (bs=256K, block-size=256K)"
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

if [ "$DO_LAYOUT" = "1" ]; then
  log ""
  log "## 布局 (128 jobs x 1G = 128G, bs=4M)"
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

  log "## Layout cooldown: 等待 compaction 完成"
  sleep 120
  check_ceph_health "after layout cooldown"
else
  log ""
  log "## 布局: 跳过（暖态复用冷态布局）"
  log "  test_dir 已有 128G 数据"
fi

log ""
log "## 随机测试 (3轮, bs=256K, block-size=256K)"
for i in 1 2 3; do
  log "### Round ${i}"
  run_rand "randread" randread "$i"
  run_rand "randwrite" randwrite "$i"
  run_rand "randrw" randrw "$i"
done

{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
} > "${OUTDIR}/ceph-status-after.txt" 2>&1

log ""
log "DONE"

# commands.sh
if [ "$DO_LAYOUT" = "1" ]; then
LAYOUT_CMD="# layout (bs=4M, 128 jobs x 1G)
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1"
else
LAYOUT_CMD="# layout: 跳过（暖态复用冷态布局）"
fi

if [ "$DO_FORMAT" = "1" ]; then
FORMAT_CMD="# format (cold only)
juicefs format --storage ceph --bucket ceph://juicefs-data \\
  --access-key ceph --secret-key client.juicefs \\
  --block-size 256K --trash-days 0 \\
  tikv://192.168.11.12:2379/juicefs-prod juicefs-prod"
else
FORMAT_CMD="# format: 跳过（暖态复用冷态卷）"
fi

cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# Commands: full-bs256k ${TAG} (patched v1.3.1)
# binary: /usr/local/bin/juicefs (patched, v1.3.1+2025-12-02.e0032b2a)

${FORMAT_CMD}

# mount
juicefs mount -d ${MOUNT_OPTS} tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# sequential tests (bs=256K)
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1

${LAYOUT_CMD}

# random tests (bs=256K, 3 rounds)
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
