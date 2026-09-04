#!/usr/bin/env bash
# Exact RUN-scoped cache cleanup.  inspect/plan are read-only; destroy needs
# both a valid state file and I_ACK_04TMP2_CLEANUP_<RUN_ID>.
set -euo pipefail
export LC_ALL=C

RUN_ID=${RUN_ID:-}
RESULT_ROOT=${RESULT_ROOT:-/tmp/production/opencode-04tmp2-$RUN_ID}
CACHE_PARENT=${CACHE_PARENT:-/mnt/jfs-cache}
CACHE_DIR=${CACHE_DIR:-$CACHE_PARENT/jfs-04tmp2-$RUN_ID}
STATE=${STATE:-$RESULT_ROOT/run-state.tsv}

die() { printf 'T04TMP2_CLEANUP_FAIL: %s\n' "$*" >&2; exit 1; }
[[ $RUN_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid RUN_ID'
[[ $RUN_ID != *..* && $RUN_ID != *\** && $RUN_ID != */* ]] || die 'unsafe RUN_ID'
EXPECTED="$CACHE_PARENT/jfs-04tmp2-$RUN_ID"
[[ $CACHE_DIR == "$EXPECTED" ]] || die "cache path is not exact RUN path: $CACHE_DIR"
[[ $CACHE_DIR != / && $CACHE_DIR != *..* && $CACHE_DIR != *\** && $CACHE_DIR != *' '* ]] || die 'unsafe cache path'
[[ $CACHE_PARENT != / && $CACHE_PARENT != *..* && $CACHE_PARENT != *\** ]] || die 'unsafe cache parent'

latest() {
  local key=$1
  [[ -s $STATE ]] || die "missing state: $STATE"
  awk -F '\t' -v k="$key" '$1==k{v=$2} END{if(v!="") print v; else exit 1}' "$STATE"
}
verify_state() {
  [[ -f $STATE && ! -L $STATE ]] || die 'state is missing or symlink'
  [[ $(latest run_id) == "$RUN_ID" ]] || die 'state RUN_ID mismatch'
  [[ $(latest cache_dir) == "$CACHE_DIR" ]] || die 'state cache_dir mismatch'
  local status; status=$(latest status) || die 'state has no status'
  [[ $status != DESTROYED && $status != DESTROYING ]] || die "unsafe repeated/partial cleanup state: $status"
  printf '%s\n' "$status"
}
verify_target() {
  [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT ]] || die 'cache parent missing or symlink'
  [[ -d $CACHE_DIR && ! -L $CACHE_DIR ]] || die 'RUN cache directory missing or symlink'
  [[ $(realpath -- "$CACHE_PARENT") == "$CACHE_PARENT" ]] || die 'cache parent realpath changed'
  [[ $(realpath -- "$CACHE_DIR") == "$CACHE_DIR" ]] || die 'cache realpath changed'
}

cmd_inspect() {
  verify_state >/dev/null
  if [[ ! -e $CACHE_DIR ]]; then
    printf 'T04TMP2_CLEANUP_INSPECT\tmissing-target\t%s\n' "$CACHE_DIR"
    return 0
  fi
  verify_target
  printf 'T04TMP2_CLEANUP_INSPECT\tstatus=%s\ttarget=%s\n' "$(latest status)" "$CACHE_DIR"
  find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -print | sort
}

cmd_plan() {
  verify_state >/dev/null
  verify_target
  printf 'T04TMP2_CLEANUP_PLAN\trun_id=%s\ttarget=%s\n' "$RUN_ID" "$CACHE_DIR"
  find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -print | sort
  printf 'action=destroy-only-after-review-and-exact-ACK\n'
}

cmd_destroy() {
  verify_state >/dev/null
  verify_target
  local expected="I_ACK_04TMP2_CLEANUP_${RUN_ID}"
  [[ ${T04TMP2_ACK:-} == "$expected" ]] || die "missing T04TMP2_ACK=$expected"
  [[ ${T04TMP2_CLEANUP_CONFIRM:-} == "$CACHE_DIR" ]] || die 'cleanup confirmation must equal exact cache path'
  printf 'status\tDESTROYING\n' >>"$STATE"
  # This Python block is intentionally bounded to the exact RUN directory.
  # It does not follow symlinks and refuses to remove the parent itself.
  python3 - "$CACHE_DIR" "$CACHE_PARENT" <<'PY'
import os, sys
target, parent = map(os.path.realpath, sys.argv[1:])
expected = os.path.join(parent, os.path.basename(target))
if target == "/" or target != expected or not target.startswith(parent + os.sep):
    raise SystemExit("cleanup target escaped exact parent")
for root, dirs, files in os.walk(target, topdown=False, followlinks=False):
    for name in files + dirs:
        path = os.path.join(root, name)
        if os.path.islink(path) or os.path.isfile(path):
            os.unlink(path)
        elif os.path.isdir(path):
            os.rmdir(path)
        else:
            raise SystemExit("unknown cache entry: %s" % path)
os.rmdir(target)
PY
  printf 'status\tDESTROYED\n' >>"$STATE"
  printf 'T04TMP2_CLEANUP_DESTROY_PASS\ttarget=%s\n' "$CACHE_DIR"
}

case ${1:-} in
  inspect) cmd_inspect ;;
  plan) cmd_plan ;;
  destroy) cmd_destroy ;;
  *) printf 'usage: %s {inspect|plan|destroy}\n' "$0"; exit 1 ;;
esac
