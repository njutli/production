#!/bin/bash
# ============================================================
# 顺序读写测试：fio bs=4M / block-size=4M，冷态/暖态
# ============================================================
# 用法: bench-seq-4m-bs4m.sh <tag> <mode> [mount_extra]
#   tag:  cold / warm
#   mode: cold / warm
#   mount_extra: 额外挂载参数
# ============================================================
set -uo pipefail

TAG="${1:?usage: $0 tag mode [mount_extra]}"
MODE="${2:?mode: cold or warm}"
MOUNT_EXTRA="${3:-}"

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
SEQ_DIR="${MNT}/seq_dir"
CACHE_DIR="/data/jfsCache"
TS="$(date +%Y%m%d-%H%M%S)"

if [ "$MODE" = "cold" ]; then
    BASE_MOUNT="--cache-size 0"
    DO_FORMAT=1
    DO_DROP=1
elif [ "$MODE" = "warm" ]; then
    BASE_MOUNT="--cache-size 102400 --cache-dir $CACHE_DIR"
    DO_FORMAT=0
    DO_DROP=0
else
    echo "mode must be cold or warm"
    exit 1
fi

MOUNT_OPTS="$BASE_MOUNT $MOUNT_EXTRA"
OUTDIR="results/seq-4m-bs4m-${TAG}-${TS}"
OUT="${OUTDIR}/summary.md"
mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "顺序读写测试 ${TAG} ${TS}"
log "============================================================"
log "## 口径:"
log "  block-size=4M, fio seq bs=4M"
log "  mode=${MODE}, mount_opts=${MOUNT_OPTS}"
log ""

{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
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
      --block-size 4M \
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
bwget(){ grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || true; }
rxget(){ grep eno1 /proc/net/dev | sed 's/:/ /' | awk '{print $2}'; }

run_seq(){
  local name="$1" rw="$2" nj="$3" fsync="$4"
  local of="${OUTDIR}/${name}.txt"
  if [ "$DO_DROP" = "1" ]; then
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  fi
  check_ceph_health "before ${name}"
  echo "# ${name}: rw=${rw} bs=4M size=4G numjobs=${nj} fsync=${fsync}" > "$of"
  echo "# mount: ${MOUNT_OPTS}" >> "$of"
  echo "# block-size: 4M, fio bs: 4M" >> "$of"
  echo "# date: $(date)" >> "$of"
  local args="--name=${name} --directory=${SEQ_DIR} --rw=${rw} --refill_buffers --bs=4M --size=4G"
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

log ""
log "## 顺序测试 (bs=4M, block-size=4M)"
mkdir -p "$SEQ_DIR"
log "### seqread prep (write 4G)"
check_ceph_health "before seqread prep"
rm -rf "$SEQ_DIR"/*
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=4M --size=4G >/dev/null 2>&1; wait_fio

run_seq "seqread" read 1 0
run_seq "seqwrite" write 1 1
run_seq "multi-seqread" read 16 0
run_seq "multi-seqwrite" write 16 1
rm -rf "$SEQ_DIR"

{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
} > "${OUTDIR}/ceph-status-after.txt" 2>&1

log ""
log "DONE"

cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# Commands: seq-4m-bs4m ${TAG}

# format (cold only)
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs \
  --block-size 4M --trash-days 0 \
  tikv://192.168.11.12:2379/juicefs-prod juicefs-prod

# mount
juicefs mount -d ${MOUNT_OPTS} tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# sequential tests (bs=4M)
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=4M --size=4G
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting --end_fsync=1
CMDEOF
chmod +x "${OUTDIR}/commands.sh"

log "  commands.sh generated"
