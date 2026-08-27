#!/usr/bin/env bash
# Read-only environment closure verification plus local evidence archive.
# It never stops/starts services, unmounts, detaches loops, or deletes data.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
TASK_BASENAME=03-22b-tikv-nvme-backed-storage-attribution.md
TASK_DOC=${T65_TASK_DOC:-$REPO_ROOT/doc/perf-tasks/$TASK_BASENAME}

RUN_ID=${1:-}; MODE=${2:-normal}
t65_check_run_id "$RUN_ID"; case "$MODE" in normal|invalid) ;; *) t65_die 'mode must be normal or invalid';; esac
[[ -s "$TASK_DOC" ]] || t65_die "task document unavailable: $TASK_DOC"
t65_make_ssh_array; t65_require_tools sshpass ssh scp sha256sum tar python3 curl
ROOT="/tmp/production/opencode-t3.22b-${RUN_ID}"
ARCHIVE="/tmp/production/opencode-t3.22b-${RUN_ID}.tar.gz"
SEED_DIR=$(t65_seed_dir "$RUN_ID" formal)
[[ -d "$ROOT" && ! -e "$ARCHIVE" ]] || t65_die 'run root missing or archive already exists'

if [[ "$MODE" == normal ]]; then
  [[ ! -e "$ROOT/RUN_INVALID.tsv" && -s "$ROOT/instances/G08/POST_FINAL_DESTROY_PASS" ]] || t65_die 'normal completion markers missing'
  for instance in R01 R02 R03 R04 R05 R06 R07 R08; do
    [[ -s "$ROOT/instances/$instance/arm-analysis.json" && -s "$ROOT/instances/$instance/UMOUNT_EPOCH" ]] || t65_die "formal arm incomplete: $instance"
  done
  for instance in G01 G02 G03 G04 G05 G06 G07 G08; do
    [[ -s "$ROOT/instances/$instance/GC_DELETE_PASS" && -s "$ROOT/instances/$instance/SEED_RETURN_PASS" ]] || t65_die "formal GC incomplete: $instance"
  done
  mkdir -p "$ROOT/analysis"
  python3 "$SCRIPT_DIR/t65-analyze.py" --matrix "$ROOT" > "$ROOT/analysis/matrix-analysis.stdout"
else
  [[ -s "$ROOT/RUN_INVALID.tsv" ]] || t65_die 'invalid completion requires RUN_INVALID.tsv'
  classification=$(t65_state_value "$ROOT/RUN_INVALID.tsv" classification)
  failed=$(t65_state_value "$ROOT/RUN_INVALID.tsv" failed_instance)
  reason=$(t65_state_value "$ROOT/RUN_INVALID.tsv" reason)
  [[ "$classification" == EVIDENCE_INVALID && "$failed" =~ ^R0[1-8]$ && -n "$reason" ]] || t65_die 'malformed invalid-run identity'
  [[ -s "$ROOT/closure/INVALID_CLOSURE_PASS" ]] || t65_die 'invalid-run closure marker missing'
fi
[[ -s "$SEED_DIR/seed.destroyed.tsv" ]] || t65_die 'final seed destroy audit missing'

FINAL="$ROOT/closure/finalize"
mkdir -p "$FINAL/remote" "$ROOT/provenance"
cp "$SCRIPT_DIR"/t65-* "$ROOT/provenance/"
cp "$TASK_DOC" "$ROOT/provenance/$TASK_BASENAME"
printf 'mode\t%s\nrun_id\t%s\nfinalize_epoch\t%s\n' "$MODE" "$RUN_ID" "$(date +%s)" > "$FINAL/mode.tsv"

for node in "${T65_NODES[@]}"; do
  mkdir -p "$FINAL/remote/$node"
  "${T65_SSH[@]}" "$node" bash -s -- "$RUN_ID" "$node" > "$FINAL/remote/$node/closure.txt" <<'REMOTE'
set -euo pipefail
run=$1; node=$2
[[ $(systemctl is-active pd) == active && $(systemctl is-active tikv) == active ]]
read -r source target fstype < <(findmnt -rn -M /mnt/jfs-tikv -o SOURCE,TARGET,FSTYPE)
uuid=$(findmnt -rn -M /mnt/jfs-tikv -o UUID)
[[ "$source" == /dev/nvme1n1 && "$target" == /mnt/jfs-tikv && "$fstype" == ext4 && -n "$uuid" ]]
if findmnt -rn -o TARGET | awk -v p="/mnt/jfs-t65-${run}" '$1==p||index($1,p"/")==1{found=1} END{exit !found}'; then exit 42; fi
if sudo losetup -l -n -O BACK-FILE | awk -v p="/mnt/jfs-tikv/jfs-t65-${run}-backing/" 'index($1,p)==1{found=1} END{exit !found}'; then exit 42; fi
if ps -eo args= | grep -F -- "jfs-t65-${run}" | grep -v -F -- 'grep -F' | grep -q .; then exit 42; fi
[[ ! -e "/mnt/jfs-t65-${run}" && ! -e "/mnt/jfs-tikv/jfs-t65-${run}-backing" ]]
shopt -s nullglob
storage_audits=()
legacy_audit="/tmp/jfs-t65-${run}-storage.destroyed.tsv"
# A legacy fixed-name audit exists only on nodes that ran the early canary
# lifecycle.  Do not turn an absent optional audit into a literal array item;
# do retain any symlink (including a dangling one) so the identity checks below
# reject it instead of silently ignoring suspicious evidence.
if [[ -e "$legacy_audit" || -L "$legacy_audit" ]]; then
  storage_audits+=("$legacy_audit")
fi
storage_audits+=("/tmp/jfs-t65-${run}-storage.destroyed-"*.tsv)
(( ${#storage_audits[@]} >= 1 ))
for storage_audit in "${storage_audits[@]}"; do
  [[ -f "$storage_audit" && ! -L "$storage_audit" && -s "$storage_audit" ]]
  [[ $(basename "$storage_audit") =~ ^jfs-t65-${run}-storage\.destroyed(-[0-9a-f]{16})?\.tsv$ ]]
  printf 'storage_audit\t%s\n' "$storage_audit"
done
[[ -s "/tmp/jfs-t65-${run}-production-restored.tsv" ]]
printf 'node\t%s\nmount_source\t%s\nmount_target\t%s\nmount_fstype\t%s\nmount_uuid\t%s\n' "$node" "$source" "$target" "$fstype" "$uuid"
systemctl show pd tikv -p Id -p ActiveState -p SubState -p MainPID -p FragmentPath
sha256sum /opt/pd/conf/pd.toml /opt/tikv/conf/tikv.toml
printf 'REMOTE_CLOSURE_PASS\n'
REMOTE
  grep -q '^REMOTE_CLOSURE_PASS$' "$FINAL/remote/$node/closure.txt" || t65_die "remote closure failed: $node"
  "${T65_SCP[@]}" "$node:/tmp/jfs-t65-${RUN_ID}-production-restored.tsv" "$FINAL/remote/$node/"
  while IFS=$'\t' read -r kind remote_audit; do
    [[ "$kind" == storage_audit && "$remote_audit" =~ ^/tmp/jfs-t65-${RUN_ID}-storage\.destroyed(-[0-9a-f]{16})?\.tsv$ ]] ||
      t65_die "unsafe remote storage audit path: $node $remote_audit"
    "${T65_SCP[@]}" "$node:$remote_audit" "$FINAL/remote/$node/"
  done < <(awk -F '\t' '$1=="storage_audit"{print}' "$FINAL/remote/$node/closure.txt")
  if "${T65_SSH[@]}" "$node" "test -s '/tmp/jfs-t65-${RUN_ID}-authorization-ledger.tsv'"; then
    "${T65_SCP[@]}" "$node:/tmp/jfs-t65-${RUN_ID}-authorization-ledger.tsv" "$FINAL/remote/$node/"
  fi
done

if [[ -s "/tmp/jfs-t65-${RUN_ID}-authorization-ledger.tsv" ]]; then cp "/tmp/jfs-t65-${RUN_ID}-authorization-ledger.tsv" "$FINAL/client-authorization-ledger.tsv"; fi
printf 'source\tepoch\thost\tphase\ttoken\tscript\n' > "$ROOT/authorization-ledger.tsv"
if [[ -s "$FINAL/client-authorization-ledger.tsv" ]]; then awk -v s=client 'BEGIN{OFS="\t"}{print s,$0}' "$FINAL/client-authorization-ledger.tsv" >> "$ROOT/authorization-ledger.tsv"; fi
for node in "${T65_NODES[@]}"; do
  ledger="$FINAL/remote/$node/jfs-t65-${RUN_ID}-authorization-ledger.tsv"
  [[ ! -s "$ledger" ]] || awk -v s="$node" 'BEGIN{OFS="\t"}{print s,$0}' "$ledger" >> "$ROOT/authorization-ledger.tsv"
done

# Production PD global view must remain all-Up for three consecutive samples.
printf 'attempt\tepoch\tstores_up\n' > "$FINAL/production-stores.tsv"
stable=0; deadline=$((SECONDS+180)); attempt=0
while ((stable<3)); do
  attempt=$((attempt+1)); epoch=$(date +%s); json="$FINAL/production-stores-${attempt}.json"
  if curl -fsS --connect-timeout 3 --max-time 10 'http://10.20.1.150:2379/pd/api/v1/stores' > "$json" &&
    python3 - "$json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('stores',[])
assert len(s)==3 and all(x.get('store',{}).get('state_name')=='Up' for x in s)
PY
  then stable=$((stable+1)); up=1; else stable=0; up=0; fi
  printf '%s\t%s\t%s\n' "$attempt" "$epoch" "$up" >> "$FINAL/production-stores.tsv"
  ((stable>=3)) || { ((SECONDS<deadline)) || t65_die 'production store readiness timeout'; sleep 10; }
done

[[ $(sudo ceph health) == HEALTH_OK ]] || t65_die 'final Ceph health is not HEALTH_OK'
sudo ceph -s > "$FINAL/ceph-s.txt"; sudo ceph df --format=json > "$FINAL/ceph-df.json"
(
  cd "$ROOT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)
tar -C "$(dirname "$ROOT")" -czf "$ARCHIVE" "$(basename "$ROOT")"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
printf 'FINALIZE_PASS mode=%s archive=%s\n' "$MODE" "$ARCHIVE"
