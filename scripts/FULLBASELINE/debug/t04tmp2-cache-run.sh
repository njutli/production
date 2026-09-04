#!/usr/bin/env bash
# 04-tmp2 L1 runner.  DRY_RUN=1 is the default; live modes require an exact
# per-action ACK and never infer a target from a shell glob or empty variable.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANALYZER="$SCRIPT_DIR/t04tmp2-cache-analyze.py"
SCRUB_CONTROL="$SCRIPT_DIR/u141d-scrub-control.sh"
DRY_RUN=${DRY_RUN:-1}
RUN_ID=${RUN_ID:-offline-self-test}
RESULT_ROOT=${RESULT_ROOT:-/tmp/production/opencode-04tmp2-$RUN_ID}
JFS=${JFS:-/tmp/juicefs-1.4.1-patched}
META=${META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
CEPH_CONF=${CEPH_CONF:-}
CACHE_PARENT=${CACHE_PARENT:-/mnt/jfs-cache}
CACHE_DIR=${CACHE_DIR:-$CACHE_PARENT/jfs-04tmp2-$RUN_ID}
DATA_DIR=${DATA_DIR:-}
STATE="$RESULT_ROOT/run-state.tsv"

die() { printf 'T04TMP2_RUN_FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
[[ $RUN_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid RUN_ID'
[[ $RUN_ID != *..* && $RUN_ID != *\** && $RUN_ID != */* ]] || die 'unsafe RUN_ID'

ensure_root() { mkdir -p -- "$RESULT_ROOT"; }
state_set() { ensure_root; printf '%s\t%s\n' "$1" "$2" >>"$STATE"; }
state_last() { [[ -s $STATE ]] || return 1; awk -F '\t' -v k="$1" '$1==k{v=$2} END{if(v!="") print v; else exit 1}' "$STATE"; }
require_ack() {
  local action=$1 expected="I_ACK_04TMP2_${action}_${RUN_ID}"
  (( DRY_RUN == 1 )) && return 0
  [[ ${T04TMP2_ACK:-} == "$expected" ]] || die "missing T04TMP2_ACK=$expected"
}
safe_absent() {
  local path=$1
  [[ -n $path && $path != / && $path != *..* && $path != *\** && $path != *' '* ]] || die "unsafe path: $path"
  [[ ! -e $path && ! -L $path ]] || die "path already exists or is symlink: $path"
}
run_cmd() {
  if (( DRY_RUN == 1 )); then
    printf 'DRY_RUN_CMD'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

mount_point_for() { printf '/tmp/jfs-04tmp2-%s-%s' "$RUN_ID" "$1"; }
mount_arm() {
  local arm=$1 mnt=$2 cache_size=0
  [[ $arm == B ]] && cache_size=65536
  [[ $mnt == /tmp/jfs-04tmp2-$RUN_ID-* ]] || die "mount path outside contract: $mnt"
  safe_absent "$mnt"
  mkdir -- "$mnt"
  local -a cmd=("$JFS" mount -d --read-only --max-fuse-io 256K --max-uploads 150 --prefetch 0 --cache-size "$cache_size")
  [[ $arm == B ]] && cmd+=(--cache-dir "$CACHE_DIR" --free-space-ratio 0.2)
  cmd+=("$META" "$mnt")
  if (( DRY_RUN == 1 )); then
    printf 'DRY_RUN_CMD'; printf ' %q' "${cmd[@]}"; printf '\n'
    return 0
  fi
  mkdir -- "$mnt"
  if [[ -n $CEPH_CONF ]]; then
    [[ $CEPH_CONF != *..* && $CEPH_CONF != *\** ]] || die 'unsafe CEPH_CONF path'
    if (( DRY_RUN == 1 )); then
      printf 'DRY_RUN_ENV CEPH_CONF=%q\n' "$CEPH_CONF"
      printf 'DRY_RUN_CMD'; printf ' %q' "${cmd[@]}"; printf '\n'
    else
      CEPH_CONF="$CEPH_CONF" "${cmd[@]}"
    fi
  else run_cmd "${cmd[@]}"; fi
}
unmount_arm() {
  local mnt=$1
  if (( DRY_RUN == 1 )); then
    printf 'DRY_RUN_CMD %q umount %q\n' "$JFS" "$mnt"
  else
    "$JFS" umount "$mnt"
    for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
    mountpoint -q "$mnt" && die "unmount timeout: $mnt"
  fi
  if (( DRY_RUN == 0 )); then rmdir -- "$mnt"; fi
}

write_jobfile() {
  local mnt=$1 output=$2 kind=$3 logbase=${4:-}
  local rw=read
  [[ $kind == formal ]] && rw=randread
  mkdir -p -- "$(dirname -- "$output")"
  {
    printf '[global]\n'
    printf 'rw=%s\nbs=256k\noffset=0\nsize=256M\n' "$rw"
    printf 'ioengine=libaio\niodepth=128\ndirect=1\nfallocate=none\n'
    printf 'allow_file_create=0\ncreate_on_open=0\n'
    [[ $kind == formal ]] && printf 'time_based=1\nruntime=180\n'
    [[ -n $logbase ]] && printf 'write_bw_log=%s\nlog_avg_msec=1000\n' "$logbase"
    for i in $(seq 0 127); do
      printf '\n[read_test_%03d]\nfilename=%s/test_dir/read_test.%d.0\n' "$i" "$mnt" "$i"
    done
  } >"$output"
}

write_plan() {
  local plan="$RESULT_ROOT/plan"
  mkdir -p -- "$plan/jobfiles"
  write_jobfile '<MOUNT>' "$plan/jobfiles/formal.fio" formal '<RUN_DIR>/bw/read_test'
  write_jobfile '<MOUNT>' "$plan/jobfiles/warmup.fio" warmup
  cat >"$plan/mount-contract.tsv" <<EOF
arm	cache_size_mib	cache_dir	read_only	prefetch	max_fuse_io	max_uploads
A	0	-	--read-only	0	256K	150
B	65536	<RUN_DIR>/cache	--read-only	0	256K	150
EOF
  cat >"$plan/matrix.tsv" <<'EOF'
cell	arm
R01-A	A
R02-B	B
R03-B	B
R04-A	A
EOF
  printf 'T04TMP2_PLAN_PASS\troot=%s\n' "$plan"
}

cmd_inventory() {
  ensure_root; require_ack READONLY
  if (( DRY_RUN == 1 )); then
    cat <<EOF
T04TMP2_INVENTORY_PLAN
binary=$JFS
meta=$META
cache_parent=$CACHE_PARENT
data_dir=${DATA_DIR:-<required-in-live-mode>}
read_only=filesystem-stat/findmnt/process-identity only
EOF
    return 0
  fi
  [[ -x $JFS ]] || die "binary missing: $JFS"
  [[ -n $DATA_DIR && -d $DATA_DIR ]] || die 'DATA_DIR is required in live inventory'
  mkdir -p -- "$RESULT_ROOT/inventory"
  md5sum "$JFS" >"$RESULT_ROOT/inventory/binary.md5"
  sha256sum "$JFS" >"$RESULT_ROOT/inventory/binary.sha256"
  findmnt -rn -M "$DATA_DIR" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$RESULT_ROOT/inventory/data-findmnt.txt"
  find "$DATA_DIR/test_dir" -maxdepth 1 -type f -name 'read_test.*.0' -printf '%f\t%i\t%s\t%T@\n' | sort >"$RESULT_ROOT/inventory/files.tsv"
  python3 - "$RESULT_ROOT/inventory/files.tsv" <<'PY'
import sys
rows=[x.rstrip('\n').split('\t') for x in open(sys.argv[1]) if x.strip()]
want={f'read_test.{i}.0' for i in range(128)}
if {x[0] for x in rows} != want or len(rows) != 128:
    raise SystemExit('expected exactly 128 read_test files')
if any(int(x[2]) != 1073741824 for x in rows):
    raise SystemExit('all read_test files must be 1GiB')
PY
  printf 'T04TMP2_INVENTORY_PASS\troot=%s\n' "$RESULT_ROOT/inventory"
}

cmd_plan() { ensure_root; write_plan; }

run_fio() {
  local cell=$1 jobfile=$2
  local out="$RESULT_ROOT/$cell"
  mkdir -p -- "$out/bw"
  printf '%s\n' "$(date +%s%N)" >"$out/fio-start-ns.txt"
  if (( DRY_RUN == 1 )); then
    printf 'DRY_RUN_CMD fio --readonly %q\n' "$jobfile"
    printf 'run=180000-180000msec\n' >"$out/fio.txt"
    printf '%s\n' "$(date +%s%N)" >"$out/fio-end-ns.txt"
  else
    set +e
    fio --readonly "$jobfile" >"$out/fio.txt" 2>"$out/fio.stderr"
    local rc=$?
    set -e
    printf '%s\n' "$(date +%s%N)" >"$out/fio-end-ns.txt"
    (( rc == 0 )) || die "fio failed for $cell rc=$rc"
  fi
}

cmd_prepare() {
  ensure_root; require_ack PREPARE; write_plan
  if (( DRY_RUN == 1 )); then
    printf 'T04TMP2_PREPARE_PLAN cache_dir=%s\n' "$CACHE_DIR"
    mount_arm B "$(mount_point_for PREP)"
    printf 'DRY_RUN_CMD fio --readonly %q\n' "$RESULT_ROOT/plan/jobfiles/warmup.fio"
    return 0
  fi
  [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT ]] || die 'cache parent is missing or symlink'
  safe_absent "$CACHE_DIR"
  mkdir -- "$CACHE_DIR"
  printf 'run_id\t%s\ncache_dir\t%s\nstatus\tCACHE_CREATED\n' "$RUN_ID" "$CACHE_DIR" >"$STATE"
  local mnt; mnt=$(mount_point_for PREP)
  mount_arm B "$mnt"
  write_jobfile "$mnt" "$RESULT_ROOT/plan/jobfiles/warmup-live.fio" warmup
  run_fio PREP "$RESULT_ROOT/plan/jobfiles/warmup-live.fio"
  unmount_arm "$mnt"
  state_set status CACHE_WARMED
  printf 'T04TMP2_PREPARE_PASS\tcache=%s\n' "$CACHE_DIR"
}

run_cell() {
  local cell=$1 arm=${cell#*-} mnt; mnt=$(mount_point_for "$cell")
  mount_arm "$arm" "$mnt"
  write_jobfile "$mnt" "$RESULT_ROOT/$cell/jobfile.fio" formal "$RESULT_ROOT/$cell/bw/read_test"
  run_fio "$cell" "$RESULT_ROOT/$cell/jobfile.fio"
  unmount_arm "$mnt"
}

cmd_screen() {
  ensure_root; require_ack SCREEN
  [[ $DRY_RUN == 1 || $(state_last status) == CACHE_WARMED ]] || die 'prepare state is not CACHE_WARMED'
  for cell in R01-A R02-B R03-B R04-A; do
    if (( DRY_RUN == 1 )); then
      printf 'T04TMP2_SCREEN_PLAN cell=%s\n' "$cell"
    else
      run_cell "$cell"
    fi
  done
  if (( DRY_RUN == 0 )); then
    python3 "$ANALYZER" screen --root "$RESULT_ROOT" --output "$RESULT_ROOT/screen-analysis.json"
    state_set status SCREEN_COMPLETE
  fi
  printf 'T04TMP2_SCREEN_%s\n' "$([[ $DRY_RUN == 1 ]] && echo PLAN || echo PASS)"
}

cmd_post_anchor() {
  ensure_root; require_ack POST_ANCHOR
  [[ $DRY_RUN == 1 || $(state_last status) == SCREEN_COMPLETE ]] || die 'screen is not complete'
  if (( DRY_RUN == 1 )); then
    printf 'T04TMP2_POST_ANCHOR_PLAN arm=A runtime=180s\n'
  else
    run_cell POST-A
    state_set status POST_ANCHOR_COMPLETE
    printf 'T04TMP2_POST_ANCHOR_PASS\n'
  fi
}

cmd_offline_self_test() {
  [[ $DRY_RUN == 1 ]] || die 'offline-self-test requires DRY_RUN=1'
  python3 "$ANALYZER" self-test
  "$SCRUB_CONTROL" --self-test
  local td; td=$(mktemp -d /tmp/t04tmp2-run-selftest.XXXXXX)
  RESULT_ROOT="$td/result" RUN_ID=SELFTEST DRY_RUN=1 "$0" plan >/dev/null
  python3 - "$td/result/plan/jobfiles/formal.fio" "$td/result/plan/jobfiles/warmup.fio" <<'PY'
import sys
for path in sys.argv[1:]:
    text=open(path).read()
    assert text.count('\n[read_test_') == 128, (path, text.count('\n[read_test_'))
    assert text.count('filename=<MOUNT>/test_dir/read_test.') == 128
    assert 'offset=0' in text and 'size=256M' in text
    assert 'allow_file_create=0' in text and 'create_on_open=0' in text
formal=open(sys.argv[1]).read(); warm=open(sys.argv[2]).read()
assert 'rw=randread' in formal and 'runtime=180' in formal
assert 'rw=read' in warm and 'time_based' not in warm
PY
  printf 'T04TMP2_RUN_SELFTEST: PASS\n'
}

usage() { printf 'usage: %s {offline-self-test|inventory|plan|prepare|screen|post-anchor}\n' "$0"; }
case ${1:-} in
  offline-self-test|inventory|plan|prepare|screen|post-anchor) "cmd_${1//-/_}" ;;
  *) usage; exit 1 ;;
esac
