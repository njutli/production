#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077

# Offline modes are safe by construction.  The online phase is inert unless
# all frozen-file hashes and the four explicit authorization tokens match.
MODE=${1:-}
RUN_ID=${2:-}
PLAN_OUT=${T065_PLAN_OUT:-/tmp/t06-5-plan-${RUN_ID}}

# Reuse the executed 06-1 implementation instead of copying its recovery,
# samplers, fio jobs, drain, readback and scrub ownership machinery.  Only
# function definitions and assignments before its dispatch are evaluated.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LEGACY=$SCRIPT_DIR/t06-1-randrw-cache-driver.sh
LEGACY_SHA256=4a0d104322fbe9d7b790842866d242133082a358f0f3b1acb799bac593be1336
LEGACY_PREFIX=$(python3 - "$LEGACY" "$LEGACY_SHA256" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1]); b=p.read_bytes()
if hashlib.sha256(b).hexdigest()!=sys.argv[2]: raise SystemExit('legacy_dependency_drift')
boundary=b'\ncase $MODE in\n'
if b.count(boundary)!=1: raise SystemExit('legacy_dispatch_boundary')
print(b.split(boundary)[0].decode())
PY
) || exit 42
eval "$LEGACY_PREFIX"
unset LEGACY_PREFIX
eval "$(declare -f recovery_gate | sed '1s/recovery_gate/legacy_recovery_gate/')"

# Restore 06-5 identities overwritten by the frozen prefix.
MODE=${1:-}
RUN_ID=${2:-}
ROOT=/tmp/production/opencode-06-5-$RUN_ID
PLAN_OUT=${T065_PLAN_OUT:-/tmp/t06-5-plan-${RUN_ID}}
ANALYZER=$SCRIPT_DIR/t06-5-randrw-cache-analyze.py
LEGACY_ANALYZER=$SCRIPT_DIR/t06-1-randrw-analyze.py
GATE0=$SCRIPT_DIR/t06-5-gate0-offline.sh

die() { printf 'T065_DRIVER_FAIL\t%s\n' "$*" >&2; exit 42; }
valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == /tmp/production/opencode-06-5-$RUN_ID && $ROOT != / && ! -L $ROOT ]] || die unsafe_result_root
}

matrix_rows() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    1 C1 C 0 0 \
    2 R1 R 98304 0 \
    3 W1 W 98304 1 \
    4 W2 W 98304 1 \
    5 R2 R 98304 0 \
    6 C2 C 0 0
}
matrix_order() { matrix_rows | awk -F '\t' '{print $2}' | paste -sd, -; }

recovery_labels() {
  printf '%s\n' canary C1-post R1-post W1-post W2-post R2-post C2-post
}

write_plan() {
  local out=$1
  [[ $out == /* && $out != / && ! -e $out && ! -L $out ]] || die unsafe_or_existing_plan_output
  mkdir -m 0700 -p "$out"
  {
    printf 'position\tcell\tarm\tcache_mib\twriteback\n'
    matrix_rows
  } >"$out/matrix.tsv"
  {
    printf 'ordinal\tlabel\twhen\tmaximum\taction_on_failure\n'
    printf '1\tcanary\tbefore-C1\t1\tSTOP_NO_FIO\n'
    printf '2\tC1-post\tbetween-C1-R1\t1\tSTOP_NO_NEXT_CELL\n'
    printf '3\tR1-post\tbetween-R1-W1\t1\tSTOP_NO_NEXT_CELL\n'
    printf '4\tW1-post\tbetween-W1-W2\t1\tSTOP_NO_NEXT_CELL\n'
    printf '5\tW2-post\tbetween-W2-R2\t1\tSTOP_NO_NEXT_CELL\n'
    printf '6\tR2-post\tbetween-R2-C2\t1\tSTOP_NO_NEXT_CELL\n'
    printf '7\tC2-post\tafter-C2\t1\tSTOP_CLOSEOUT\n'
  } >"$out/recovery-contract.tsv"
  cat >"$out/maintenance-contract.tsv" <<'EOF'
step	class	approval	guard
inventory	READ_ONLY	NONE	all registered sessions and owners known
pause-shared-sessions	ENVIRONMENT_WRITE	USER_ONCE_PRE_PHASE	157 main mount idle; portal namespace mount stopped, exact identities recorded
scrub-control	GLOBAL_CEPH_WRITE	USER_EXPLICIT	state-owned flags only; restore in all exits
gc-compact-delete	EXISTING_VOLUME_WRITE	USER_BATCH_MAX7	frozen binary/META/UUID; no automatic retry; runs only after scrub pause
private-mount	PRIVATE_MOUNT_WRITE	USER_BATCH_SIX	exact RUN mountpoint, no lazy/forced unmount
fio-existing-assets	EXISTING_FILE_WRITE	USER_BATCH_SIX	128 fixed 1GiB files, create/layout/format forbidden
writeback-drain	READ_AND_STATE_GATE	NONE	W staging/uploading/rawstaging zero for 3 samples
closeout	READ_ONLY_THEN_EXACT_CLEANUP	USER_PER_PATH	persist evidence before any evidence cleanup
EOF
  cat >"$out/workload-contract.tsv" <<'EOF'
field	value	source
rw	randrw	task-06-5-3.2
rwmixread	50	task-06-5-3.2
bs	256K	task-06-5-3.2
ioengine	libaio	task-06-5-3.2
iodepth	128	task-06-5-3.2
numjobs	128	task-06-5-3.2
direct	1	task-06-5-3.2
runtime	180	task-06-5-3.2
assets	128x1GiB-existing	 task-06-5-3.2
warmup	60s-symmetric	 task-06-5-3.1
EOF
  cat >"$out/lifecycle-order.tsv" <<'EOF'
order	action	must_precede
10	writeback-drain	formal-unmount
20	formal-unmount	cache0-readback-mount
30	cache0-readback	cache0-readback-unmount
40	cache0-readback-unmount	recovery-contract
50	recovery-contract	next-cell
60	persistence-check	evidence-cleanup
EOF
  cat >"$out/safety-contract.tsv" <<'EOF'
rule	status
remote-or-environment-action-in-offline-driver	FORBIDDEN
ssh-sudo-mount-fio-juicefs-in-offline-driver	FORBIDDEN
automatic-GC-retry	FORBIDDEN
OSD-TiKV-compact-drop-caches-global-sync	FORBIDDEN
pool-PG-CRUSH-format-layout-destroy	FORBIDDEN
forced-or-lazy-unmount-pattern-kill	FORBIDDEN
W-unmount-before-three-zero-drain	FORBIDDEN
shared-session-pause-without-user-ACK	FORBIDDEN
EOF
  printf '06-5 offline plan\nrun_id=%s\nrecovery_max=7\nrecovery_policy=one-canary-plus-five-between-plus-one-closeout\n' "$RUN_ID" >"$out/plan.txt"
  sha256sum "$out"/* >"$out/plan.sha256"
}

offline_self_test() {
  valid_run
  [[ $(matrix_rows | wc -l) -eq 6 ]] || die matrix_count
  [[ $(matrix_order) == C1,R1,W1,W2,R2,C2 ]] || die matrix_order
  [[ $(matrix_rows | awk -F '\t' '$3=="C"&&$4==0&&$5==0{n++}END{print n+0}') -eq 2 ]] || die control_contract
  [[ $(matrix_rows | awk -F '\t' '$3=="R"&&$4==98304&&$5==0{n++}END{print n+0}') -eq 2 ]] || die read_cache_contract
  [[ $(matrix_rows | awk -F '\t' '$3=="W"&&$4==98304&&$5==1{n++}END{print n+0}') -eq 2 ]] || die writeback_contract
  [[ $(recovery_labels | wc -l) -eq 7 ]] || die recovery_count
  [[ $(recovery_labels | paste -sd, -) == canary,C1-post,R1-post,W1-post,W2-post,R2-post,C2-post ]] || die recovery_order
  [[ $PLAN_OUT == /* && $PLAN_OUT != / ]] || die plan_path
  [[ $(type -t legacy_recovery_gate) == function ]] || die legacy_recovery_missing
  printf 'T065_DRIVER_SELF_TEST_PASS\tmatrix=%s\trecovery_max=7\tonline_mode_guarded=PASS\n' "$(matrix_order)"
}

require_online_ack() {
  valid_run
  [[ ${T065_EXECUTE_ACK:-} == I_ACK_06_5_PHASE_$RUN_ID ]] || die execute_ack_missing
  [[ ${T065_PATH_ACK:-} == I_ACK_06_5_CACHE_PATHS_$RUN_ID ]] || die path_ack_missing
  [[ ${T065_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die scrub_ack_missing
  [[ ${T065_MAINTENANCE_ACK:-} == I_ACK_06_5_PORTAL_PAUSED_$RUN_ID ]] || die maintenance_ack_missing
  [[ -r ${T065_CACHE_CONTRACT:-} && ! -L ${T065_CACHE_CONTRACT:-/nonexistent} ]] || die approved_path_contract_missing
  local kind file expected
  for kind in DRIVER ANALYZER LEGACY_ANALYZER GATE0 SCRUB CONTRACT PORTAL; do
    case $kind in
      DRIVER) file=$0;; ANALYZER) file=$ANALYZER;; GATE0) file=$GATE0;; SCRUB) file=$SCRUB;;
      LEGACY_ANALYZER) file=$LEGACY_ANALYZER;;
      CONTRACT) file=$T065_CACHE_CONTRACT;; PORTAL) file=$SCRIPT_DIR/t06-5-portal-maintenance.sh;;
    esac
    expected=T065_${kind}_SHA256; expected=${!expected:-}
    [[ $expected =~ ^[0-9a-f]{64}$ && -f $file && ! -L $file ]] || die frozen_dependency_missing_$kind
    [[ $(sha256sum "$file" | awk '{print $1}') == "$expected" ]] || die frozen_dependency_drift_$kind
  done
  T061_CACHE_CONTRACT=$T065_CACHE_CONTRACT
  T061_CEPH_FSID=${T065_CEPH_FSID:?}
}

cache_dirs_for_cell() {
  local cell=$1 parent child joined=
  [[ $cell =~ ^[RW][12]$ ]] || die invalid_cache_cell
  while IFS= read -r parent; do
    [[ -n $parent ]] || continue
    validate_parent "$parent"
    child=$parent/jfs-06-5-$RUN_ID-$cell
    [[ $child == "$parent/jfs-06-5-$RUN_ID-$cell" && ! -L $child ]] || die unsafe_cache_child
    [[ -z $joined ]] && joined=$child || joined=$joined:$child
  done < <(approved_parents)
  [[ -n $joined ]] || die no_approved_cache_parent
  printf '%s\n' "$joined"
}

create_cache_dirs() {
  local cell=$1 joined=$2 dir parent
  IFS=: read -r -a paths <<<"$joined"
  for dir in "${paths[@]}"; do
    parent=${dir%/*}; validate_parent "$parent"
    [[ $dir == "$parent/jfs-06-5-$RUN_ID-$cell" && ! -e $dir && ! -L $dir ]] || die cache_dir_precondition
    event CACHE_CREATE_PRE "$dir"; mkdir -m 0700 -- "$dir"
    [[ -d $dir && ! -L $dir && -z $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || die cache_dir_not_empty
    event CACHE_CREATE_POST "$dir"
  done
}

cleanup_cache_dirs() {
  local cell=$1 joined=$2 dir parent
  IFS=: read -r -a paths <<<"$joined"
  for dir in "${paths[@]}"; do
    parent=${dir%/*}; validate_parent "$parent"
    [[ $dir == "$parent/jfs-06-5-$RUN_ID-$cell" && -d $dir && ! -L $dir ]] || die cleanup_scope
    [[ -f $ROOT/cells/$cell/UNMOUNTED_formal && -f $ROOT/cells/$cell/UNMOUNTED_verify ]] || die cleanup_before_unmount
    event CACHE_CLEANUP_PRE "$dir"
    find "$dir" -xdev -depth -mindepth 1 -delete
    rmdir -- "$dir"
    event CACHE_CLEANUP_POST "$dir"
  done
}

mount_private() {
  local cell=$1 arm=$2 tag=$3 mnt=$4 metrics=$5 dirs=$6
  local cell_root=$ROOT/cells/$cell before=$ROOT/cells/$cell/pids-$tag.before
  local -a cmd
  [[ $cell =~ ^[CRW][12]$ && ( $tag == formal || $tag == verify ) ]] || die mount_identity_args
  local expected=/tmp/jfs-06-5-$RUN_ID-$cell
  [[ $tag == formal ]] || expected+=-verify
  [[ $mnt == "$expected" && $mnt != / && ! -e $mnt && ! -L $mnt ]] || die unsafe_private_mount
  mkdir -m 0700 -- "$mnt"
  capture_preexisting_pids "$before"
  cmd=("$JFS" mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 --max-downloads 200 --metrics "$metrics" --log "$cell_root/juicefs-$tag.log")
  case $arm in
    C) [[ -z $dirs ]] || die control_cache_dir; cmd+=(--cache-size 0);;
    R) [[ -n $dirs ]] || die cache_dir_required; cmd+=(--cache-dir "$dirs" --cache-size "$CACHE_MIB" --free-space-ratio 0.20);;
    W) [[ -n $dirs ]] || die cache_dir_required; cmd+=(--cache-dir "$dirs" --cache-size "$CACHE_MIB" --free-space-ratio 0.20 --writeback);;
    *) die invalid_arm;;
  esac
  cmd+=("$META" "$mnt")
  log_cmd env CEPH_CONF="$CEPH_CONF" "${cmd[@]}"
  env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$cell_root/mount-$tag.stdout" 2>"$cell_root/mount-$tag.stderr"
  for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$cell_root/findmnt-$tag.tsv"
  grep -Fq "JuiceFS:juicefs-prod $mnt fuse.juicefs" "$cell_root/findmnt-$tag.tsv" || die mount_identity
  mount_pid_gate "$before" "$cell_root/mount-process-$tag.tsv" "$cell_root/juicefs-$tag.log"
}

graceful_umount() {
  local cell=$1
  local tag=$2
  local mnt=$3
  local expected=/tmp/jfs-06-5-$RUN_ID-$cell
  [[ $tag == formal ]] || expected+=-verify
  [[ $mnt == "$expected" && ! -L $mnt ]] || die umount_scope
  local process_file=$ROOT/cells/$cell/mount-process-$tag.tsv
  log_cmd timeout 300 "$JFS" umount "$mnt"
  timeout 300 "$JFS" umount "$mnt" >"$ROOT/cells/$cell/umount-$tag.stdout" 2>"$ROOT/cells/$cell/umount-$tag.stderr" || die umount_failed
  for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && die mount_remains
  for _ in $(seq 1 60); do processes_gone "$process_file" && break; sleep 1; done
  processes_gone "$process_file" || die mount_process_remains
  rmdir -- "$mnt" || die mount_dir_not_empty
  : >"$ROOT/cells/$cell/UNMOUNTED_$tag"
}

shared_session_gate() {
  local tag=$1
  local out=$ROOT/maintenance/session-$tag.json
  local tmp=$ROOT/maintenance/session-$tag.stderr
  mkdir -m 0700 -p "$ROOT/maintenance"
  "$JFS" status "$META" >"$out" 2>"$tmp" || die volume_status_failed
  python3 - "$out" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get('Sessions') or []
bad=[x for x in s if x.get('MountPoint')!='/mnt/juicefs']
if bad: raise SystemExit('unexpected_shared_sessions:'+repr([(x.get('HostName'),x.get('MountPoint'),x.get('ProcessID')) for x in bad]))
if len(s)!=1: raise SystemExit('expected_exactly_one_idle_main_session:'+repr([(x.get('HostName'),x.get('MountPoint'),x.get('ProcessID')) for x in s]))
PY
  python3 - <<'PY'
import os,pathlib
prefix='/mnt/juicefs'
bad=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
 try:
  links=[p/'cwd',p/'root',*list((p/'fd').glob('*'))]
  for q in links:
   try:t=os.readlink(q)
   except OSError:continue
   if t==prefix or t.startswith(prefix+'/'):bad.append((p.name,str(q.name),t))
 except OSError:pass
if bad:raise SystemExit('main_mount_in_use:'+repr(bad[:20]))
PY
}

recovery_gate() {
  shared_session_gate "$1-pre"
  legacy_recovery_gate "$1"
  shared_session_gate "$1-post"
}

run_cell() {
  local pos=$1 cell=$2 arm=$3 cache_mib=$4 writeback=$5
  local cell_root=$ROOT/cells/$cell mnt=/tmp/jfs-06-5-$RUN_ID-$cell
  local verify_mnt=/tmp/jfs-06-5-$RUN_ID-$cell-verify metrics=127.0.0.1:$((METRICS_BASE+pos)) dirs=
  [[ ! -e $cell_root ]] || die cell_already_exists
  mkdir -m 0700 -p "$cell_root"
  if [[ $arm != C ]]; then dirs=$(cache_dirs_for_cell "$cell"); create_cache_dirs "$cell" "$dirs"; fi
  printf 'cell\t%s\narm\t%s\ncache_mib\t%s\nwriteback\t%s\ncache_dirs\t%s\n' "$cell" "$arm" "$cache_mib" "$writeback" "${dirs:-NONE}" >"$cell_root/state.tsv"
  verify_assets "$REF" "$cell_root/assets-before.tsv"; health_gate "$cell_root/health-before"
  mount_private "$cell" "$arm" formal "$mnt" "$metrics" "$dirs"; verify_assets "$mnt" "$cell_root/assets-mounted.tsv"
  run_warmup "$cell" "$mnt"; start_samplers "$cell" "$metrics" "$dirs"; run_formal "$cell" "$mnt"; stop_samplers
  if (( FORMAL_RC != 0 )); then event FIO_FAIL_PRESERVE_MOUNT "$cell:rc=$FORMAL_RC"; return "$FORMAL_RC"; fi
  if [[ $arm == W ]]; then drain_writeback "$cell" "$metrics" "$dirs" || return $?; else printf '0\n' >"$cell_root/drain-seconds.txt"; printf 'NOT_APPLICABLE_NO_WRITEBACK\n' >"$cell_root/drain.tsv"; fi
  graceful_umount "$cell" formal "$mnt"
  mount_private "$cell" C verify "$verify_mnt" "$metrics" ""; readback_verify "$cell" "$verify_mnt"; graceful_umount "$cell" verify "$verify_mnt"
  recovery_gate "$cell-post"
  verify_assets "$REF" "$cell_root/assets-after.tsv"; cmp -s "$cell_root/assets-before.tsv" "$cell_root/assets-after.tsv" || die assets_changed
  health_gate "$cell_root/health-after"
  if [[ -n $dirs ]]; then cleanup_cache_dirs "$cell" "$dirs"; fi
  printf 'CELL_RAW_PASS\n' >"$cell_root/PASS"
}

phase_065() {
  require_online_ack
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die juicefs_identity
  [[ -x $SCRUB && -x $ANALYZER && -x $GATE0 ]] || die script_dependency
  [[ -d /tmp/production && ! -e $ROOT ]] || die result_root_precondition
  T061_CACHE_CONTRACT=$T065_CACHE_CONTRACT
  mkdir -m 0700 -p "$ROOT/cells" "$ROOT/recovery" "$ROOT/gate0" "$ROOT/maintenance"
  printf 'epoch_ns\tkind\tdetail\n' >"$ROOT/incidents.tsv"; : >"$ROOT/commands.sh"
  cp -- "$T065_CACHE_CONTRACT" "$ROOT/gate0/cache-path-contract.tsv"; T061_CACHE_CONTRACT=$ROOT/gate0/cache-path-contract.tsv
  sha256sum "$0" "$LEGACY" "$ANALYZER" "$LEGACY_ANALYZER" "$GATE0" "$SCRUB" "$SCRIPT_DIR/t06-5-portal-maintenance.sh" >"$ROOT/gate0/scripts.sha256"
  verify_assets "$REF" "$ROOT/gate0/assets-start.tsv"; shared_session_gate phase-start
  restore_scrub_on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n $ACTIVE_SAMPLER_STOP ]]; then : >"$ACTIVE_SAMPLER_STOP.done"; fi
    if [[ -n $ACTIVE_SAMPLER_PID ]]; then wait "$ACTIVE_SAMPLER_PID" 2>/dev/null || true; fi
    if [[ -n $ACTIVE_IOSTAT_PID ]]; then kill -TERM "$ACTIVE_IOSTAT_PID" 2>/dev/null || true; wait "$ACTIVE_IOSTAT_PID" 2>/dev/null || true; fi
    if (( SCRUB_ACTIVE )); then
      env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" restore "$SCRUB_LEASE" >"$ROOT/scrub-restore-on-exit.txt" 2>&1 || { printf 'SCRUB_RESTORE_FAILED\n' >"$ROOT/STOP-SCRUB-RESTORE-FAILED"; rc=46; }
    fi
    exit "$rc"
  }
  trap restore_scrub_on_exit EXIT INT TERM
  # Keep the frozen scrub helper's validated lease grammar; state is already
  # isolated below this RUN's result root.
  SCRUB_LEASE=$RUN_ID-phase-a; SCRUB_ACTIVE=1
  env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" pause "$SCRUB_LEASE" "$T061_CEPH_FSID" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$ROOT/scrub-pause.txt"
  recovery_gate canary
  while IFS=$'\t' read -r pos cell arm cache_mib writeback; do run_cell "$pos" "$cell" "$arm" "$cache_mib" "$writeback"; done < <(matrix_rows)
  env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" restore "$SCRUB_LEASE" >"$ROOT/scrub-restore.txt"
  SCRUB_ACTIVE=0; trap - EXIT INT TERM
  shared_session_gate phase-end; health_gate "$ROOT/health-final"; verify_assets "$REF" "$ROOT/gate0/assets-end.tsv"
  cmp -s "$ROOT/gate0/assets-start.tsv" "$ROOT/gate0/assets-end.tsv" || die final_assets_changed
  printf 'PHASE_RAW_PASS\n' >"$ROOT/PHASE_PASS"
}

case $MODE in
  --self-test) valid_run; offline_self_test ;;
  plan) valid_run; write_plan "$PLAN_OUT"; printf 'T065_PLAN_ONLY_PASS\troot=%s\n' "$PLAN_OUT" ;;
  phase) phase_065 ;;
  *) printf 'usage: %s --self-test|plan|phase RUN_ID\n' "$0" >&2; exit 2 ;;
esac
