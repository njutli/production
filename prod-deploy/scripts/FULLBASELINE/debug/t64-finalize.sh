#!/usr/bin/env bash
# Read-only remote evidence collection and local archive for 03-22.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t64-common.sh"
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
TASK_BASENAME=03-22-tikv-ram-block-storage-isolation-ab.md
TASK_DOC=${T64_TASK_DOC:-}
if [[ -z "$TASK_DOC" ]]; then
  if [[ -s "$REPO_ROOT/doc/perf-tasks/$TASK_BASENAME" ]]; then
    TASK_DOC="$REPO_ROOT/doc/perf-tasks/$TASK_BASENAME"
  elif [[ -s "$SCRIPT_DIR/$TASK_BASENAME" ]]; then
    TASK_DOC="$SCRIPT_DIR/$TASK_BASENAME"
  else
    t64_die "task document is unavailable; place $TASK_BASENAME beside the scripts or set T64_TASK_DOC"
  fi
fi
[[ -s "$TASK_DOC" ]] || t64_die "invalid T64_TASK_DOC: $TASK_DOC"

RUN_ID=${1:-}
MODE=${2:-normal}
t64_check_run_id "$RUN_ID"
case "$MODE" in
  normal|invalid) ;;
  *) t64_die 'usage: t64-finalize.sh RUN_ID normal|invalid';;
esac
t64_make_ssh_array
t64_require_tools sshpass ssh scp sha256sum tar python3
OUT="/tmp/production/opencode-t3.22-${RUN_ID}"
ARCHIVE="/tmp/production/opencode-t3.22-${RUN_ID}.tar.gz"
[[ -d "$OUT" && ! -e "$ARCHIVE" ]] || t64_die 'OUT missing or archive already exists'
SEED_DIR=$(t64_seed_dir "$RUN_ID" formal)
[[ -s "$SEED_DIR/SEED_BUNDLE_PASS" && -s "$SEED_DIR/formal-clone-contract.tsv" &&
   -s "$SEED_DIR/seed.destroyed.tsv" ]] ||
  t64_die 'formal seed/clone/destroy evidence is incomplete'

tsv_value() {
  local file=$1 key=$2
  awk -F '\t' -v key="$key" '$1==key{value=$2; count++} END{if(count==1) print value; else exit 1}' "$file"
}

declare -a REMOTE_INSTANCES=(SEED-FORMAL RESTORE-PREFLIGHT GC-PREFLIGHT)
if [[ "$MODE" == normal ]]; then
  [[ ! -e "$OUT/RUN_INVALID.tsv" && -s "$OUT/instances/G08/POST_FINAL_DESTROY_PASS" ]] ||
    t64_die 'normal finalize requires G08 completion and forbids RUN_INVALID.tsv'
  [[ $(tsv_value "$SEED_DIR/seed.destroyed.tsv" instance) == G08 ]] ||
    t64_die 'normal finalize requires a G08 seed destroy audit'
  for instance in R01 R02 R03 R04 R05 R06 R07 R08; do
    [[ -s "$OUT/instances/$instance/arm-analysis.json" && -s "$OUT/instances/$instance/UMOUNT_EPOCH" ]] ||
      t64_die "formal arm evidence incomplete: $instance"
    REMOTE_INSTANCES+=("$instance")
  done
  for instance in G01 G02 G03 G04 G05 G06 G07 G08; do
    [[ -s "$OUT/instances/$instance/GC_DELETE_PASS" && -s "$OUT/instances/$instance/SEED_RETURN_PASS" ]] ||
      t64_die "formal GC evidence incomplete: $instance"
    REMOTE_INSTANCES+=("$instance")
  done
else
  INVALID="$OUT/RUN_INVALID.tsv"
  [[ -s "$INVALID" ]] || t64_die 'invalid finalize requires RUN_INVALID.tsv'
  classification=$(tsv_value "$INVALID" classification)
  failed_instance=$(tsv_value "$INVALID" failed_instance)
  gc_instance=$(tsv_value "$INVALID" gc_instance)
  reason=$(tsv_value "$INVALID" reason)
  [[ "$classification" == EVIDENCE_INVALID && "$failed_instance" =~ ^R0[1-7]$ &&
     "$gc_instance" =~ ^G0[1-7]$ && -n "$reason" ]] ||
    t64_die 'invalid-run identity is malformed'
  expected_gc="G${failed_instance#R}"
  [[ "$gc_instance" == "$expected_gc" ]] ||
    t64_die "failed arm/GC mismatch: failed=$failed_instance gc=$gc_instance"
  [[ $(tsv_value "$SEED_DIR/seed.destroyed.tsv" mode) == abort-invalid-run &&
     $(tsv_value "$SEED_DIR/seed.destroyed.tsv" failed_instance) == "$failed_instance" &&
     $(tsv_value "$SEED_DIR/seed.destroyed.tsv" gc_instance) == "$gc_instance" ]] ||
    t64_die 'abort seed destroy audit does not match RUN_INVALID.tsv'
  [[ -s "$OUT/instances/$gc_instance/GC_DELETE_PASS" &&
     -s "$OUT/instances/$gc_instance/SEED_RETURN_PASS" &&
     -s "$OUT/instances/$gc_instance/ABORT_SEED_DESTROY_PASS" &&
     -s "$OUT/instances/$gc_instance/POST_ABORT_FINAL_DESTROY_PASS" &&
     -s "$OUT/instances/$gc_instance/gc-postcheck.tsv" ]] ||
    t64_die "abort cleanup evidence incomplete: $gc_instance"
  failed_num=$((10#${failed_instance#R}))
  for ((i=1; i<failed_num; i++)); do
    printf -v instance 'R%02d' "$i"
    [[ -s "$OUT/instances/$instance/arm-analysis.json" && -s "$OUT/instances/$instance/UMOUNT_EPOCH" ]] ||
      t64_die "completed pre-failure arm evidence incomplete: $instance"
    REMOTE_INSTANCES+=("$instance")
  done
  [[ -s "$OUT/instances/$failed_instance/arm/phase.tsv" &&
     -s "$OUT/instances/$failed_instance/UMOUNT_EPOCH" &&
     ! -e "$OUT/instances/$failed_instance/arm-analysis.json" ]] ||
    t64_die "failed arm evidence boundary is invalid: $failed_instance"
  grep -Fq $'\tsamper_failed' "$OUT/instances/$failed_instance/arm/phase.tsv" ||
    t64_die "failed arm lacks preserved sampler failure marker: $failed_instance"
  REMOTE_INSTANCES+=("$failed_instance")
  for ((i=failed_num+1; i<=8; i++)); do
    printf -v instance 'R%02d' "$i"
    [[ ! -e "$OUT/instances/$instance/arm" && ! -e "$OUT/instances/$instance/arm-analysis.json" ]] ||
      t64_die "post-failure formal arm was started: $instance"
  done
  for ((i=1; i<=failed_num; i++)); do
    printf -v instance 'G%02d' "$i"
    [[ -s "$OUT/instances/$instance/GC_DELETE_PASS" && -s "$OUT/instances/$instance/SEED_RETURN_PASS" ]] ||
      t64_die "pre-failure/abort GC evidence incomplete: $instance"
    REMOTE_INSTANCES+=("$instance")
  done
fi
mkdir -p "$OUT/final/remote"
mkdir -p "$OUT/provenance"
cp "$SCRIPT_DIR"/t64-* "$OUT/provenance/"
cp "$TASK_DOC" "$OUT/provenance/$TASK_BASENAME"
printf 'mode\t%s\nrun_id\t%s\n' "$MODE" "$RUN_ID" > "$OUT/final/finalize-mode.tsv"

for node in "${T64_NODES[@]}"; do
  "${T64_SSH[@]}" "$node" 'set -euo pipefail
if ps -eo pid=,comm=,args= | awk '\''($2=="pd-server" || $2=="tikv-server") && $0 ~ /\/tmp\/jfs-t64-/{found=1} END{exit !found}'\''; then exit 42; fi
if findmnt -rn -o TARGET | awk '\''$1 ~ /^\/mnt\/jfs-t64-/{found=1} END{exit !found}'\''; then exit 42; fi
if sudo losetup -l -n -O BACK-FILE | awk '\''$1 ~ /^\/mnt\/jfs-t64-/{found=1} END{exit !found}'\''; then exit 42; fi
for svc in pd-server tikv-server; do
  ps -eo pid=,comm= | awk -v s="$svc" '\''$2==s{print $1}'\'' | while read -r pid; do
    printf "%s\t%s\t%s\t%s\n" "$svc" "$pid" "$(awk '\''{print $22}'\'' /proc/$pid/stat)" "$(readlink -f /proc/$pid/exe)"
  done
done
systemctl is-active pd tikv
findmnt -rn -M /mnt/jfs-tikv -o SOURCE,TARGET,FSTYPE,OPTIONS
sha256sum /opt/pd/conf/pd.toml /opt/tikv/conf/tikv.toml' \
    > "$OUT/final/production-${node}-post.txt"
  cmp -s "$OUT/orchestration/production-${node}-pre.txt" "$OUT/final/production-${node}-post.txt" ||
    t64_die "production fingerprint changed on $node"
  mkdir -p "$OUT/final/remote/$node"
  for cluster in a b; do
    "${T64_SCP[@]}" "$node:/tmp/jfs-t64-${RUN_ID}-${cluster}-storage.destroyed.tsv" \
      "$OUT/final/remote/$node/" || t64_die "missing destroy audit $node/$cluster"
  done
  for instance in "${REMOTE_INSTANCES[@]}"; do
    cluster=$(t64_expected_cluster "$instance" | tr 'AB' 'ab')
    "${T64_SCP[@]}" -r "$node:/tmp/jfs-t64-${RUN_ID}-${instance}-${cluster}" \
      "$OUT/final/remote/$node/" || t64_die "missing instance evidence $node/$instance"
  done
  # Smoke evidence belongs to the retired pre-formal RUN_ID. The optional arm
  # canary is local/nonformal, but collect its remote process evidence when it
  # exists without making it a formal completion requirement.
  for canary in ARM-CANARY-A ARM-CANARY-A2 SEED-CANARY RESTORE-CANARY GC-CANARY; do
    if "${T64_SSH[@]}" "$node" "test -d '/tmp/jfs-t64-${RUN_ID}-${canary}-a'"; then
      "${T64_SCP[@]}" -r "$node:/tmp/jfs-t64-${RUN_ID}-${canary}-a" \
        "$OUT/final/remote/$node/"
    fi
  done
done

[[ $(sudo ceph health) == HEALTH_OK ]] || t64_die 'final Ceph health is not HEALTH_OK'
sudo ceph -s > "$OUT/final/ceph-s.txt"
sudo ceph df --format=json > "$OUT/final/ceph-df.json"
(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)
tar -C "$(dirname "$OUT")" -czf "$ARCHIVE" "$(basename "$OUT")"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
printf 'FINALIZE_PASS mode=%s archive=%s\n' "$MODE" "$ARCHIVE"
