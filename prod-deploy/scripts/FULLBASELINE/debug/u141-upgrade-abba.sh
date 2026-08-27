#!/usr/bin/env bash
# u141-upgrade-abba.sh: patched v1.3.1 vs patched v1.4.1 ABBA non-inferiority
set -euo pipefail

RUN_ID="${1:-$(date +%Y%m%d-%H%M%S)}"
OUT=/tmp/opencode-fullbaseline-v4
ARCHIVE_DIR=~/tmp/production

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; }

# Block definitions: LABEL ARM BIN_DIR BIN_MD5
declare -a BLOCKS=("UP1A A /tmp/t53-bin-new de93563f11a5ff3bd94dd25a4e0283b1" "UP2B B /tmp/t141p-bin 24fae0852051c80ca571cb2f20275d46" "UP3B B /tmp/t141p-bin 24fae0852051c80ca571cb2f20275d46" "UP4A A /tmp/t53-bin-new de93563f11a5ff3bd94dd25a4e0283b1")

CEPH_CONF=/tmp/t141-msgr8.conf
SYS_CONF=/etc/ceph/ceph.conf
V4=/tmp/FULLBASELINE_V4.sh
STOPS="$OUT/STOPS.md"
: > "$STOPS"

record_stop() { local n=$1; shift; echo "- **S$n**: $(date '+%F %T') $*" | tee -a "$STOPS"; }

# ===== Phase 0: Preserve existing V4 results =====
log "=== Phase 0: Preserve existing V4 results ==="
# Unmount any existing mount
for pid in $(pgrep -f "juicefs.*juicefs-prod" 2>/dev/null || true); do
  kill "$pid" 2>/dev/null || true
done
sleep 5
umount -l /mnt/juicefs 2>/dev/null || true
sleep 2
mountpoint -q /mnt/juicefs && { log "FATAL: cannot unmount"; exit 1; } || log "mount clean"

# Preserve
cp -a "$OUT" "/tmp/opencode-fullbaseline-v4.pre-u141-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
tar czf "$ARCHIVE_DIR/opencode-t141-preserve.tar.gz" -C /tmp "opencode-fullbaseline-v4.pre-u141-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
md5sum "$ARCHIVE_DIR/opencode-t141-preserve.tar.gz" 2>/dev/null || true
log "T141 series preserved"

# Batch head invariants
{
  echo "=== Batch Head Invariants ==="
  echo "date=$(date '+%F %T %z')"
  echo "hostname=$(hostname)"
  echo "nproc=$(nproc)"
  echo "juicefs-03-8 md5=$(md5sum /tmp/juicefs-03-8 | awk '{print $1}')"
  echo "juicefs-1.4.1-patched md5=$(md5sum /tmp/juicefs-1.4.1-patched | awk '{print $1}')"
  echo "t53-bin-new shim=$(readlink -f /tmp/t53-bin-new/juicefs)"
  echo "t141p-bin shim=$(readlink -f /tmp/t141p-bin/juicefs)"
  echo "t141-msgr8.conf md5=$(md5sum $CEPH_CONF | awk '{print $1}')"
  echo "ceph.conf md5=$(md5sum $SYS_CONF | awk '{print $1}')"
  echo "V4 md5=$(md5sum $V4 | awk '{print $1}')"
  echo "ceph config dump md5=$(sudo ceph config dump 2>/dev/null | md5sum | awk '{print $1}')"
  echo "health=$(sudo ceph health 2>/dev/null)"
  echo "osd_stat=$(sudo ceph osd stat 2>/dev/null)"
  echo "df_root=$(df -h / | tail -1)"
} > "$OUT/invariants-batch-head.txt"
log "Batch head invariants saved"

# ===== Phase 1-4: ABBA blocks =====
for block_def in "${BLOCKS[@]}"; do
  read -r LBL ARM BIN_DIR BIN_MD5 <<< "$block_def"
  BIN_PATH=$(readlink -f "$BIN_DIR/juicefs")

  log "=== Block $LBL (arm=$ARM bin=$BIN_PATH) ==="
  BLOCK_START=$(date +%s)

  # Step 1: Unmount if needed
  if mountpoint -q /mnt/juicefs; then
    "$BIN_PATH" umount --flush /mnt/juicefs 2>/dev/null || umount -l /mnt/juicefs 2>/dev/null || true
    sleep 10
  fi
  mountpoint -q /mnt/juicefs && { record_stop 0 "$LBL: cannot unmount"; log "SKIP $LBL"; continue; }

  # Step 2: Invariants check
  {
    echo "=== $LBL Invariants ==="
    echo "bin_md5_actual=$(md5sum "$BIN_PATH" | awk '{print $1}')"
    echo "bin_md5_expected=$BIN_MD5"
    echo "shim=$(readlink -f "$BIN_DIR/juicefs")"
    echo "ceph_conf_md5=$(md5sum $CEPH_CONF | awk '{print $1}')"
    echo "sys_conf_md5=$(md5sum $SYS_CONF | awk '{print $1}')"
    echo "v4_md5=$(md5sum $V4 | awk '{print $1}')"
    echo "health=$(sudo ceph health 2>/dev/null)"
    echo "osd_up=$(sudo ceph osd stat 2>/dev/null)"
  } > "$OUT/invariants-$LBL.txt"

  actual_md5=$(md5sum "$BIN_PATH" | awk '{print $1}')
  if [[ "$actual_md5" != "$BIN_MD5" ]]; then
    record_stop 8 "$LBL: binary md5 mismatch: $actual_md5 != $BIN_MD5"
    log "FATAL S8: binary mismatch"
    exit 1
  fi
  log "  invariants OK"

  # Step 3: File asset gate (done after V4 mounts, as a post-check)
  # V4 will fail if files are missing, so this is supplementary evidence

  # Step 4: Run V4
  log "  starting V4 ($LBL, 4 items × 2 rounds)"
  env PATH="${BIN_DIR}:${PATH}" \
      CEPH_CONF="$CEPH_CONF" \
      ITEMS="randread randrw randwrite mseqwrite" \
      OBJ_GATE=1 \
      OBJ_TARGET=2500000 \
      OBJ_GC_PASSES=2 \
      OBJ_MAX=8000000 \
      JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K" \
      bash "$V4" "$LBL" 180 2 > "$OUT/v4-$LBL.stdout.log" 2>&1 || true
  v4_rc=$?
  log "  V4 $LBL done rc=$v4_rc"

  # Step 3b: File asset gate (post-V4, if mount still alive or from V4's records)
  if mountpoint -q /mnt/juicefs; then
    {
      echo -e "path\tinode\tsize\tmtime"
      for stem in storage_test read_test rw_test; do
        for f in /mnt/juicefs/test_dir/${stem}.*.0; do
          [[ -f "$f" ]] || continue
          printf "%s\t%s\t%s\t%s\n" "$f" "$(stat -c %i "$f")" "$(stat -c %s "$f")" "$(stat -c %Y "$f")"
        done
      done
    } | sort > "$OUT/filecount-$LBL.tsv"
  else
    echo "mount not active, filecount skipped" > "$OUT/filecount-$LBL.tsv"
  fi

  # Step 5: Mount fingerprint (collected during fio, but we do post-hoc if mount still alive)
  # V4 with SKIP_REMOUNT=0 will have unmounted at the end, so check if still mounted
  if mountpoint -q /mnt/juicefs; then
    MPID=$(pgrep -f "juicefs.*juicefs-prod" | head -1)
    if [[ -n "$MPID" ]]; then
      {
        echo "pid=$MPID"
        echo "exe=$(readlink -f /proc/$MPID/exe 2>/dev/null)"
        echo "exe_md5=$(md5sum /proc/$MPID/exe 2>/dev/null | awk '{print $1}')"
        tr '\0' '\n' < /proc/$MPID/environ 2>/dev/null | grep -E '^(CEPH_CONF|PATH)='
        echo "msgr_workers=$(cat /proc/$MPID/task/*/comm 2>/dev/null | grep -c '^msgr-worker' || echo 0)"
        grep " /mnt/juicefs " /proc/mounts
      } > "$OUT/mountproc-$LBL.txt"
      log "  mount fingerprint saved"
    fi
  else
    # Mount already gone - check V4's jfs-instance file
    if [[ -f "$OUT/jfs-instance-$LBL.txt" ]]; then
      cp "$OUT/jfs-instance-$LBL.txt" "$OUT/mountproc-$LBL.txt"
      log "  mount fingerprint from jfs-instance (post-hoc)"
    else
      echo "mount fingerprint unavailable - V4 unmounted and no jfs-instance" > "$OUT/mountproc-$LBL.txt"
      record_stop 9 "$LBL: mount fingerprint unavailable"
    fi
  fi

  # Step 6: Archive block
  tar czf "$ARCHIVE_DIR/u141-$LBL.tar.gz" -C /tmp/opencode-fullbaseline-v4 \
    "$LBL" "rounds.tsv" "test.log" "obj-gate-$LBL.tsv" \
    "invariants-$LBL.txt" "filecount-$LBL.tsv" "mountproc-$LBL.txt" \
    "jfs-instance-$LBL.txt" "cache-config-check-$LBL.txt" 2>/dev/null || true
  md5sum "$ARCHIVE_DIR/u141-$LBL.tar.gz" 2>/dev/null || true
  log "  $LBL archived"

  # Step 7: Round directory completeness
  expected_dirs=6  # randread r1-r2, randrw r1-r2, randwrite r1-r2
  actual_dirs=$(find "$OUT/$LBL" -maxdepth 1 -type d -name "*-r*" 2>/dev/null | wc -l)
  if [[ "$actual_dirs" -lt "$expected_dirs" ]]; then
    record_stop 20 "$LBL: only $actual_dirs/$expected_dirs round dirs"
  else
    log "  round dirs OK ($actual_dirs)"
  fi

  # Check wall clock
  BLOCK_END=$(date +%s)
  BLOCK_DUR=$(( (BLOCK_END - BLOCK_START) / 60 ))
  log "  $LBL took ${BLOCK_DUR}min"
  if [[ $BLOCK_DUR -gt 110 ]]; then
    record_stop 23 "$LBL: wall clock ${BLOCK_DUR}min > 110min"
  fi
done

# ===== Phase 5: Batch tail =====
log "=== Phase 5: Batch tail ==="
# Unmount
for pid in $(pgrep -f "juicefs.*juicefs-prod" 2>/dev/null || true); do
  kill "$pid" 2>/dev/null || true
done
sleep 5
umount -l /mnt/juicefs 2>/dev/null || true

# Tail invariants
{
  echo "=== Batch Tail Invariants ==="
  echo "date=$(date '+%F %T %z')"
  echo "juicefs-03-8 md5=$(md5sum /tmp/juicefs-03-8 | awk '{print $1}')"
  echo "juicefs-1.4.1-patched md5=$(md5sum /tmp/juicefs-1.4.1-patched | awk '{print $1}')"
  echo "t141-msgr8.conf md5=$(md5sum $CEPH_CONF | awk '{print $1}')"
  echo "ceph.conf md5=$(md5sum $SYS_CONF | awk '{print $1}')"
  echo "V4 md5=$(md5sum $V4 | awk '{print $1}')"
  echo "health=$(sudo ceph health 2>/dev/null)"
  echo "pool_objects=$(sudo ceph df 2>/dev/null | grep juicefs-data | awk '{print $4}')"
  echo "pool_stored=$(sudo ceph df 2>/dev/null | grep juicefs-data | awk '{print $2}')"
} > "$OUT/invariants-batch-tail.txt"

# Diff
diff "$OUT/invariants-batch-head.txt" "$OUT/invariants-batch-tail.txt" > "$OUT/invariants-diff.txt" 2>/dev/null || true

# Generate u141-cells.tsv
{
  echo -e "block\tlabel\tarm\tbinary_md5\titem\tround\tbw_mibs\thit_rate\td_meta_ops_Write\td_meta_dur_Write_s\td_fuse_ops_write\td_txn_total\tobj_post\tstored_post\tpg_primary\tfio_rc\tmount_pid\tmsgr_workers"
  for lbl in UP1A UP2B UP3B UP4A; do
    arm="A"; [[ "$lbl" == UP2B || "$lbl" == UP3B ]] && arm="B"
    bin_md5="de93563f11a5ff3bd94dd25a4e0283b1"
    [[ "$arm" == "B" ]] && bin_md5="24fae0852051c80ca571cb2f20275d46"
    # Parse rounds.tsv for this label
    grep "^$lbl" "$OUT/rounds.tsv" 2>/dev/null | while IFS=$'\t' read -r label round bw hit status pg_gate pg gear; do
      [[ -n "$round" ]] || continue
      # Extract item and round number
      item=$(echo "$round" | sed "s/${label}-//; s/-r[0-9]//")
      rnd=$(echo "$round" | grep -oP 'r\K[0-9]')
      [[ -z "$rnd" ]] && rnd=1
      # Try to get meta counters from jfs-stats
      meta_ops=""; meta_dur=""; fuse_ops=""; txn_total=""
      stats_pre="$OUT/$lbl/$round/jfs-stats-pre.txt"
      stats_post="$OUT/$lbl/$round/jfs-stats-post.txt"
      if [[ -f "$stats_post" ]]; then
        meta_ops=$(grep 'juicefs_meta_ops_total_Write' "$stats_post" 2>/dev/null | awk '{print $2}')
        meta_dur=$(grep 'juicefs_meta_ops_duration_seconds_Write' "$stats_post" 2>/dev/null | awk '{print $2}')
        fuse_ops=$(grep 'juicefs_fuse_ops_total_write' "$stats_post" 2>/dev/null | awk '{print $2}')
        txn_total=$(grep 'juicefs_transaction_durations_histogram_seconds_total' "$stats_post" 2>/dev/null | awk '{print $2}')
        if [[ -f "$stats_pre" ]]; then
          pre_meta_ops=$(grep 'juicefs_meta_ops_total_Write' "$stats_pre" 2>/dev/null | awk '{print $2}')
          pre_meta_dur=$(grep 'juicefs_meta_ops_duration_seconds_Write' "$stats_pre" 2>/dev/null | awk '{print $2}')
          pre_fuse_ops=$(grep 'juicefs_fuse_ops_total_write' "$stats_pre" 2>/dev/null | awk '{print $2}')
          pre_txn_total=$(grep 'juicefs_transaction_durations_histogram_seconds_total' "$stats_pre" 2>/dev/null | awk '{print $2}')
          [[ -n "$pre_meta_ops" && "$pre_meta_ops" =~ ^[0-9]+$ ]] && meta_ops=$((meta_ops - pre_meta_ops))
          [[ -n "$pre_meta_dur" && "$pre_meta_dur" =~ ^[0-9.]+$ ]] && meta_dur=$(echo "$meta_dur - $pre_meta_dur" | bc 2>/dev/null || echo "$meta_dur")
          [[ -n "$pre_fuse_ops" && "$pre_fuse_ops" =~ ^[0-9]+$ ]] && fuse_ops=$((fuse_ops - pre_fuse_ops))
          [[ -n "$pre_txn_total" && "$pre_txn_total" =~ ^[0-9]+$ ]] && txn_total=$((txn_total - pre_txn_total))
        fi
      fi
      # Obj gate
      obj_post=""; stored_post=""
      if [[ -f "$OUT/obj-gate-$lbl.tsv" ]]; then
        obj_post=$(grep "$round" "$OUT/obj-gate-$lbl.tsv" 2>/dev/null | awk -F'\t' '{print $4}')
        stored_post=$(grep "$round" "$OUT/obj-gate-$lbl.tsv" 2>/dev/null | awk -F'\t' '{print $5}')
      fi
      # PG primary
      pg_primary=$(echo "$pg" | grep -oP 'primary=\[\K[^\]]+')
      # Fio rc
      fio_rc=0
      [[ "$status" == "VALID" ]] || fio_rc=1
      # Mount pid and msgr
      mount_pid=""; msgr_workers=""
      if [[ -f "$OUT/mountproc-$lbl.txt" ]]; then
        mount_pid=$(grep '^pid=' "$OUT/mountproc-$lbl.txt" | cut -d= -f2)
        msgr_workers=$(grep 'msgr_workers=' "$OUT/mountproc-$lbl.txt" | cut -d= -f2)
      fi
      printf "%s\t%s\t%s\t%s\t%s\tr%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$lbl" "$lbl" "$arm" "$bin_md5" "$item" "$rnd" "$bw" "$hit" \
        "${meta_ops:-NA}" "${meta_dur:-NA}" "${fuse_ops:-NA}" "${txn_total:-NA}" \
        "${obj_post:-NA}" "${stored_post:-NA}" "$pg_primary" "$fio_rc" "${mount_pid:-NA}" "${msgr_workers:-NA}"
    done
  done
} > "$OUT/u141-cells.tsv"

# Pool tail
{
  echo "date=$(date '+%F %T %z')"
  sudo ceph df 2>/dev/null | grep juicefs-data
} > "$OUT/pool-tail.txt"

# Final archive
tar czf "$ARCHIVE_DIR/opencode-u141.tar.gz" -C /tmp/opencode-fullbaseline-v4 \
  UP1A UP2B UP3B UP4A rounds.tsv test.log \
  invariants-batch-head.txt invariants-batch-tail.txt invariants-diff.txt \
  u141-cells.tsv pool-tail.txt STOPS.md \
  obj-gate-UP*.tsv filecount-UP*.tsv mountproc-UP*.txt invariants-UP*.txt \
  jfs-instance-UP*.txt cache-config-check-UP*.txt 2>/dev/null || true
md5sum "$ARCHIVE_DIR/opencode-u141.tar.gz" 2>/dev/null

log "=== U141 DONE ==="
log "archive=$ARCHIVE_DIR/opencode-u141.tar.gz"
log "stops=$(wc -l < "$STOPS" 2>/dev/null || echo 0)"
