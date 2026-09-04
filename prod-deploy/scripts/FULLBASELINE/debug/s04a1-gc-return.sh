#!/usr/bin/env bash
# Inspect and, with a separate exact authorization, delete only objects leaked relative to a frozen seed dump.
# The current metadata cluster must be a fresh, unmounted seed restore dedicated to GC.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/s04a1-runtime-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
s04a1_check_run_id "$RUN_ID"
s04a1_check_cluster "$CLUSTER"
s04a1_check_instance "$INSTANCE"
case "$INSTANCE" in GC-CANARY|GC-PREFLIGHT|GC-ARM-CANARY|GC-ARM-CANARY-C|GC-ARM-CANARY-L|G0[1-8]) ;; *) s04a1_die 'GC script requires a dedicated GC instance';; esac
[[ $(s04a1_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || s04a1_die 'GC instance/storage arm mismatch'

FLAVOR=$(s04a1_seed_flavor "$INSTANCE")
ROOT="/tmp/production/opencode-04-2-${RUN_ID}"
OUT="$ROOT/instances/$INSTANCE"
SEED_DIR=$(s04a1_seed_dir "$RUN_ID" "$FLAVOR")
RESTORE_STATE="$OUT/restore.tsv"
PRIVATE_CONF="$OUT/ceph-s04a1.conf"
META=$(s04a1_meta_url "$RUN_ID" "$INSTANCE")
VOLUME=$(s04a1_seed_name "$RUN_ID" "$FLAVOR")
MNT="/tmp/jfs-s04a1-${RUN_ID}-mnt-${INSTANCE}"
s04a1_assert_abs_scoped_path "$MNT" "$RUN_ID"
s04a1_require_tools "$S04A1_JUICEFS_BIN" curl python3 sha256sum mountpoint pgrep

record_cmd() {
  local arg
  for arg in "$@"; do printf '%q ' "$arg" >> "$OUT/commands.sh"; done
  printf '\n' >> "$OUT/commands.sh"
}

prior_instance() {
  case "$INSTANCE" in
    GC-CANARY) printf RESTORE-CANARY-C;;
    GC-PREFLIGHT) printf RESTORE-PREFLIGHT-L;;
    GC-ARM-CANARY|GC-ARM-CANARY-L) printf ARM-CANARY-L;;
    GC-ARM-CANARY-C) printf ARM-CANARY-C;;
    G0[1-8]) printf 'R%s' "${INSTANCE#G}";;
  esac
}

verify_cluster() {
  local node
  for node in "${S04A1_NODES[@]}"; do
    curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${S04A1_TIKV_STATUS_PORT}/config" >/dev/null ||
      s04a1_die "temporary TiKV unavailable: $node"
  done
  s04a1_ceph_health_test_ok || s04a1_die 'Ceph health is outside the approved test/scrub state'
}

pool_objects() {
  sudo ceph df --format=json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=next(x for x in d["pools"] if x["name"]=="juicefs-data"); s=p["stats"]
print("%s\t%s\t%s"%(s["objects"],s["stored"],s["bytes_used"]))'
}

verify_gc_identity() {
  [[ -s "$RESTORE_STATE" && -s "$SEED_DIR/SEED_BUNDLE_PASS" && ! -e "$OUT/volume.tsv" ]] ||
    s04a1_die 'GC restore/seed state invalid or a mount state exists'
  ! mountpoint -q "$MNT" || s04a1_die 'GC instance must never be mounted'
  if pgrep -af -- "$S04A1_JUICEFS_BIN" 2>/dev/null | awk -v token="jfs-s04a1-${RUN_ID}" '$0 ~ / mount / && index($0,token)>0{found=1} END{exit !found}'; then
    s04a1_die 'another RUN_ID-scoped JuiceFS mount process is active'
  fi
  verify_cluster
  export CEPH_CONF="$PRIVATE_CONF"
  "$S04A1_JUICEFS_BIN" status "$META" > "$OUT/status-gc-identity.json"
  local identity uuid name
  identity=$(s04a1_status_identity "$OUT/status-gc-identity.json") || s04a1_die 'invalid GC restore identity'
  IFS=$'\t' read -r uuid name <<< "$identity"
  [[ "$uuid" == "$(awk -F '\t' '$1=="uuid"{print $2}' "$SEED_DIR/seed.tsv")" && "$name" == "$VOLUME" ]] ||
    s04a1_die 'GC restore UUID/name differs from frozen seed'
  s04a1_status_has_zero_sessions "$OUT/status-gc-identity.json" || s04a1_die 'GC restore has a live session'
  local prior epoch now
  prior=$(prior_instance)
  [[ -s "$ROOT/instances/$prior/UMOUNT_EPOCH" ]] || s04a1_die "prior instance lacks UMOUNT_EPOCH: $prior"
  epoch=$(<"$ROOT/instances/$prior/UMOUNT_EPOCH"); now=$(date +%s)
  (( now - epoch >= 65 )) || s04a1_die "prior session TTL not elapsed; retry after $((65-now+epoch)) seconds"
}

inspect_gc() {
  [[ ! -e "$OUT/GC_INSPECT_PASS" && ! -e "$OUT/GC_DELETE_PASS" ]] || s04a1_die 'GC inspect/delete evidence already exists'
  verify_gc_identity
  export CEPH_CONF="$PRIVATE_CONF"
  pool_objects > "$OUT/pool-pre-gc.tsv"
  record_cmd env JFS_GC_SKIPPEDTIME=0 "CEPH_CONF=$PRIVATE_CONF" "$S04A1_JUICEFS_BIN" gc "$META"
  JFS_GC_SKIPPEDTIME=0 "$S04A1_JUICEFS_BIN" gc "$META" > "$OUT/gc-inspect.log" 2>&1
  s04a1_gc_summary "$OUT/gc-inspect.log" > "$OUT/gc-inspect.tsv"
  local key value
  for key in pending delslices delfiles skipped; do
    value=$(awk -F '\t' -v k="$key" '$1==k{print $2}' "$OUT/gc-inspect.tsv")
    [[ "$value" == 0 ]] || s04a1_die "GC inspect $key=$value, expected 0"
  done
  { printf 'MODE=PLAN_ONLY\nrun_id=%s\ninstance=%s\nmeta=%s\nvolume=%s\nuuid=%s\n' \
      "$RUN_ID" "$INSTANCE" "$META" "$VOLUME" "$(awk -F '\t' '$1=="uuid"{print $2}' "$RESTORE_STATE")"
    printf 'JFS_GC_SKIPPEDTIME=0 CEPH_CONF=%q %q gc --delete --threads 50 %q\n' "$PRIVATE_CONF" "$S04A1_JUICEFS_BIN" "$META"
  } > "$OUT/gc-delete.plan"
  printf '%s\n' "$(date +%s)" > "$OUT/GC_INSPECT_PASS"
  printf 'GC_INSPECT_PASS instance=%s leaked=%s valid=%s plan=%s\n' "$INSTANCE" \
    "$(awk -F '\t' '$1=="leaked"{print $2}' "$OUT/gc-inspect.tsv")" \
    "$(awk -F '\t' '$1=="valid"{print $2}' "$OUT/gc-inspect.tsv")" "$OUT/gc-delete.plan"
}

delete_gc() {
  [[ "$INSTANCE" != GC-PREFLIGHT ]] || s04a1_die 'GC-PREFLIGHT is check-only because it creates no data objects'
  [[ ${S04A1_GC_DELETE_AUTH:-} == "04-2-gc-delete-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_GC_DELETE_AUTH=04-2-gc-delete-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" gc-delete "$S04A1_GC_DELETE_AUTH"
  [[ -s "$OUT/GC_INSPECT_PASS" && -s "$OUT/gc-inspect.tsv" && ! -e "$OUT/GC_DELETE_PASS" ]] ||
    s04a1_die 'GC inspect gate missing or delete already executed'
  local leaked
  leaked=$(awk -F '\t' '$1=="leaked"{print $2}' "$OUT/gc-inspect.tsv")
  [[ "$leaked" =~ ^[0-9]+$ && "$leaked" -gt 0 ]] || s04a1_die 'destructive GC requires a positive inspected leaked-object count'
  verify_gc_identity
  export CEPH_CONF="$PRIVATE_CONF"
  record_cmd env JFS_GC_SKIPPEDTIME=0 "CEPH_CONF=$PRIVATE_CONF" "$S04A1_JUICEFS_BIN" gc --delete --threads 50 "$META"
  JFS_GC_SKIPPEDTIME=0 "$S04A1_JUICEFS_BIN" gc --delete --threads 50 "$META" > "$OUT/gc-delete.log" 2>&1
  s04a1_gc_summary "$OUT/gc-delete.log" > "$OUT/gc-delete.tsv"
  JFS_GC_SKIPPEDTIME=0 "$S04A1_JUICEFS_BIN" gc "$META" > "$OUT/gc-postcheck.log" 2>&1
  s04a1_gc_summary "$OUT/gc-postcheck.log" > "$OUT/gc-postcheck.tsv"
  local key value base_value post_value
  for key in pending leaked delslices delfiles skipped; do
    value=$(awk -F '\t' -v k="$key" '$1==k{print $2}' "$OUT/gc-postcheck.tsv")
    [[ "$value" == 0 ]] || s04a1_die "post-GC $key=$value, expected 0"
  done
  for key in valid compacted; do
    base_value=$(awk -F '\t' -v k="$key" '$1==k{print $2}' "$SEED_DIR/gc-baseline.tsv")
    post_value=$(awk -F '\t' -v k="$key" '$1==k{print $2}' "$OUT/gc-postcheck.tsv")
    [[ "$post_value" == "$base_value" ]] || s04a1_die "post-GC $key differs from seed: seed=$base_value post=$post_value"
  done
  pool_objects > "$OUT/pool-post-gc-immediate.tsv"
  printf '%s\n' "$(date +%s)" > "$OUT/GC_DELETE_PASS"
  printf 'GC_DELETE_PASS instance=%s inspected_leaked=%s post_leaked=0\n' "$INSTANCE" "$leaked"
}

final_destroy() {
  [[ "$INSTANCE" == GC-CANARY || "$INSTANCE" == G08 ]] || s04a1_die 'seed destroy is allowed only after canary GC or G08'
  [[ ${S04A1_SEED_DESTROY_AUTH:-} == "04-2-seed-destroy-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_SEED_DESTROY_AUTH=04-2-seed-destroy-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" seed-destroy "$S04A1_SEED_DESTROY_AUTH"
  [[ -s "$OUT/GC_DELETE_PASS" && -s "$OUT/SEED_RETURN_PASS" && ! -e "$SEED_DIR/seed.destroyed.tsv" ]] ||
    s04a1_die 'GC delete/seed return gate missing or seed already destroyed'
  verify_gc_identity
  export CEPH_CONF="$PRIVATE_CONF"
  local uuid
  uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$RESTORE_STATE")
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$S04A1_JUICEFS_BIN" destroy "$META" "$uuid" --yes
  "$S04A1_JUICEFS_BIN" destroy "$META" "$uuid" --yes > "$OUT/seed-destroy.log" 2>&1
  printf 'destroy_epoch\t%s\ninstance\t%s\nmeta\t%s\nvolume_name\t%s\nuuid\t%s\n' \
    "$(date +%s)" "$INSTANCE" "$META" "$VOLUME" "$uuid" > "$SEED_DIR/seed.destroyed.tsv"
  printf 'SEED_DESTROY_PASS instance=%s uuid=%s\n' "$INSTANCE" "$uuid"
}

abort_final_destroy() {
  [[ "$INSTANCE" =~ ^G0[1-7]$ ]] || s04a1_die 'abort-final-destroy requires an early G01..G07 cleanup instance'
  [[ ${S04A1_ABORT_SEED_DESTROY_AUTH:-} == "04-2-abort-seed-destroy-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_ABORT_SEED_DESTROY_AUTH=04-2-abort-seed-destroy-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" abort-seed-destroy "$S04A1_ABORT_SEED_DESTROY_AUTH"
  [[ -z ${S04A1_SEED_DESTROY_AUTH:-} ]] || s04a1_die 'normal seed-destroy authorization is forbidden for abort cleanup'
  [[ -s "$OUT/GC_DELETE_PASS" && -s "$OUT/SEED_RETURN_PASS" && -s "$OUT/gc-postcheck.tsv" &&
     ! -e "$SEED_DIR/seed.destroyed.tsv" && ! -e "$OUT/ABORT_SEED_DESTROY_PASS" ]] ||
    s04a1_die 'abort seed destroy requires GC delete/seed return and an undestroyed seed'

  local prior phase uuid
  prior=$(prior_instance)
  phase="$ROOT/instances/$prior/arm/phase.tsv"
  [[ -s "$phase" && ! -e "$ROOT/instances/$prior/arm-analysis.json" ]] ||
    s04a1_die 'abort seed destroy requires a failed prior formal arm'
  grep -Fq $'\tsamper_failed' "$phase" || s04a1_die 'prior arm lacks the preserved sampler-timeout failure marker'
  [[ -s "$ROOT/instances/$prior/UMOUNT_EPOCH" ]] || s04a1_die 'prior failed arm lacks an umount epoch'
  for key in pending leaked delslices delfiles skipped compacted; do
    [[ $(awk -F '\t' -v k="$key" '$1==k{print $2}' "$OUT/gc-postcheck.tsv") == 0 ]] ||
      s04a1_die "abort cleanup post-GC $key is not zero"
  done
  [[ $(awk -F '\t' '$1=="valid"{print $2}' "$OUT/gc-postcheck.tsv") == \
     "$(awk -F '\t' '$1=="valid"{print $2}' "$SEED_DIR/gc-baseline.tsv")" ]] ||
    s04a1_die 'abort cleanup valid count differs from seed baseline'
  (cd "$SEED_DIR" && sha256sum -c seed-meta.sha256 >/dev/null) || s04a1_die 'seed dump SHA mismatch before abort destroy'
  (cd "$SEED_DIR" && sha256sum -c formal-clone-contract.sha256 >/dev/null) ||
    s04a1_die 'formal clone contract SHA mismatch before abort destroy'
  verify_gc_identity
  export CEPH_CONF="$PRIVATE_CONF"
  pool_objects > "$OUT/pool-pre-abort-seed-destroy.tsv"
  uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$RESTORE_STATE")
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$S04A1_JUICEFS_BIN" destroy "$META" "$uuid" --yes
  "$S04A1_JUICEFS_BIN" destroy "$META" "$uuid" --yes > "$OUT/abort-seed-destroy.log" 2>&1
  printf 'destroy_epoch\t%s\nmode\tabort-invalid-run\nfailed_instance\t%s\ngc_instance\t%s\nmeta\t%s\nvolume_name\t%s\nuuid\t%s\n' \
    "$(date +%s)" "$prior" "$INSTANCE" "$META" "$VOLUME" "$uuid" > "$SEED_DIR/seed.destroyed.tsv"
  printf 'classification\tEVIDENCE_INVALID\nfailed_instance\t%s\ngc_instance\t%s\nreason\tformal-arm-sampler-timeout-after-local-storage-capacity-exhaustion\n' \
    "$prior" "$INSTANCE" > "$ROOT/RUN_INVALID.tsv"
  printf '%s\n' "$(date +%s)" > "$OUT/ABORT_SEED_DESTROY_PASS"
  printf 'ABORT_SEED_DESTROY_PASS instance=%s failed_instance=%s uuid=%s evidence=INVALID\n' \
    "$INSTANCE" "$prior" "$uuid"
}

case "$ACTION" in
  inspect) inspect_gc;;
  delete) delete_gc;;
  final-destroy) final_destroy;;
  abort-final-destroy) abort_final_destroy;;
  *) s04a1_die 'usage: s04a1-gc-return.sh inspect|delete|final-destroy|abort-final-destroy RUN_ID C GC-CANARY|GC-PREFLIGHT|GC-ARM-CANARY|G01..G08';;
esac
