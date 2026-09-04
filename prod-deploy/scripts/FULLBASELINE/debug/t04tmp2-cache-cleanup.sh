#!/usr/bin/env bash
# Exact, state-driven cache directory inspection and cleanup for 04-tmp2.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

MODE=${1:-}
RUN_ID=${2:-}
DRY_RUN_ONLY=${TMP2_DRY_RUN_ONLY:-1}
FIXTURE=${TMP2_FIXTURE:-0}
CACHE_PARENT=${TMP2_CACHE_PARENT:-/mnt/jfs-cache}
ROOT=${TMP2_RESULT_ROOT:-/tmp/production/opencode-04tmp2-$RUN_ID}
STATE="$ROOT/state/cache.tsv"
PLAN="$ROOT/plans/cache-destroy.tsv"

die() { printf 'E_TMP2_CLEANUP\t%s\n' "$*" >&2; exit 42; }
usage() { printf 'usage: %s offline-self-test|inspect|plan|destroy RUN_ID\n' "${0##*/}"; }

validate() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "invalid RUN_ID"
  [[ $ROOT == "/tmp/production/opencode-04tmp2-$RUN_ID" && -d $ROOT && ! -L $ROOT ]] \
    || die "result root outside exact RUN scope"
  [[ -f $STATE && ! -L $STATE ]] || die "cache state missing or symlink"
  grep -Fqx $'run_id\t'"$RUN_ID" "$STATE" || die "state RUN_ID mismatch"
  local recorded expected
  recorded=$(awk -F'\t' '$1=="cache_root"{v=$2} END{print v}' "$STATE")
  expected="$CACHE_PARENT/jfs-04tmp2-$RUN_ID"
  [[ -n $recorded && $recorded == "$expected" && $recorded != / && $recorded != *'..'* && $recorded != *'*'* && $recorded != *'?'* ]] \
    || die "unsafe/mismatched cache root: $recorded"
  printf '%s\n' "$recorded"
}

assert_tree_safe() {
  local target=$1 report=$2
  python3 - "$target" "$report" <<'PY'
import os,stat,sys
root,report=sys.argv[1:]
if not os.path.isdir(root) or os.path.islink(root): raise SystemExit('root missing/not-directory/symlink')
root=os.path.realpath(root); dev=os.lstat(root).st_dev; rows=[]
for base,dirs,files in os.walk(root,topdown=True,followlinks=False):
    st=os.lstat(base)
    if stat.S_ISLNK(st.st_mode) or st.st_dev!=dev: raise SystemExit(f'unsafe directory: {base}')
    for name in dirs+files:
        path=os.path.join(base,name); st=os.lstat(path)
        if stat.S_ISLNK(st.st_mode): raise SystemExit(f'symlink forbidden: {path}')
        if st.st_dev!=dev: raise SystemExit(f'cross-device entry forbidden: {path}')
        kind='d' if stat.S_ISDIR(st.st_mode) else 'f' if stat.S_ISREG(st.st_mode) else 'other'
        if kind=='other': raise SystemExit(f'special entry forbidden: {path}')
        rows.append((kind,os.path.relpath(path,root),st.st_size,st.st_ino,st.st_dev))
with open(report,'w') as f:
    f.write('kind\tpath\tbytes\tinode\tdev\n')
    for row in sorted(rows): f.write('\t'.join(map(str,row))+'\n')
PY
}

assert_no_users_or_mounts() {
  local target=$1 out=$2
  mkdir -p "$out"
  if findmnt -R "$target" >"$out/findmnt.txt" 2>&1; then
    [[ ! -s $out/findmnt.txt ]] || die "mount exists below cache root"
  fi
  if command -v lsof >/dev/null; then
    set +e; timeout 60 lsof +D "$target" >"$out/lsof.txt" 2>"$out/lsof.stderr"; local rc=$?; set -e
    if (( rc == 0 )) && [[ -s $out/lsof.txt ]]; then die "open file exists below cache root"; fi
    (( rc == 0 || rc == 1 || rc == 124 )) || die "lsof failed rc=$rc"
    (( rc != 124 )) || die "lsof timed out; cannot prove no open files"
  else
    die "lsof required for cleanup safety"
  fi
}

cmd_inspect() {
  local target; target=$(validate)
  mkdir -p "$ROOT/cleanup-inspect"
  if [[ ! -e $target ]]; then
    printf 'CACHE_ABSENT\t%s\n' "$target" | tee "$ROOT/cleanup-inspect/status.tsv"
    return 0
  fi
  [[ ! -L $target && $(realpath -- "$target") == "$target" ]] || die "cache root realpath mismatch"
  local expected_dev actual_dev
  expected_dev=$(awk -F'\t' '$1=="root_dev"{v=$2} END{print v}' "$STATE")
  actual_dev=$(stat -Lc %d "$target")
  [[ -n $expected_dev && $actual_dev == "$expected_dev" ]] || die "cache root device drift"
  assert_tree_safe "$target" "$ROOT/cleanup-inspect/tree.tsv"
  assert_no_users_or_mounts "$target" "$ROOT/cleanup-inspect"
  printf 'CACHE_INSPECT_PASS\t%s\tdev=%s\n' "$target" "$actual_dev" | tee "$ROOT/cleanup-inspect/status.tsv"
}

cmd_plan() {
  local target; target=$(validate)
  [[ -d $target ]] || die "cache root absent; nothing to plan"
  cmd_inspect >/dev/null
  local files dirs bytes dev
  files=$(awk -F'\t' '$1=="f"{n++} END{print n+0}' "$ROOT/cleanup-inspect/tree.tsv")
  dirs=$(awk -F'\t' '$1=="d"{n++} END{print n+0}' "$ROOT/cleanup-inspect/tree.tsv")
  bytes=$(awk -F'\t' '$1=="f"{n+=$3} END{printf "%.0f",n+0}' "$ROOT/cleanup-inspect/tree.tsv")
  dev=$(stat -Lc %d "$target")
  mkdir -p "$(dirname -- "$PLAN")"
  printf 'run_id\ttarget\tdev\tfiles\tdirs\tbytes\taction\n%s\t%s\t%s\t%s\t%s\t%s\texact-safe-walk-unlink-rmdir\n' \
    "$RUN_ID" "$target" "$dev" "$files" "$dirs" "$bytes" >"$PLAN"
  sha256sum "$PLAN" >"$PLAN.sha256"
  printf 'CACHE_DESTROY_PLAN_PASS target=%s files=%s dirs=%s bytes=%s\n' "$target" "$files" "$dirs" "$bytes"
}

safe_delete_tree() {
  local target=$1
  python3 - "$target" <<'PY'
import os,stat,sys
root=sys.argv[1]
if not os.path.isdir(root) or os.path.islink(root): raise SystemExit('unsafe root before delete')
root=os.path.realpath(root); dev=os.lstat(root).st_dev
items=[]
for base,dirs,files in os.walk(root,topdown=True,followlinks=False):
    for name in dirs+files:
        p=os.path.join(base,name); st=os.lstat(p)
        if stat.S_ISLNK(st.st_mode) or st.st_dev!=dev: raise SystemExit(f'unsafe entry before delete: {p}')
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)): raise SystemExit(f'special entry: {p}')
        items.append(p)
for p in sorted(items,key=lambda x:(x.count(os.sep),x),reverse=True):
    st=os.lstat(p)
    if stat.S_ISDIR(st.st_mode): os.rmdir(p)
    elif stat.S_ISREG(st.st_mode): os.unlink(p)
    else: raise SystemExit(f'entry changed type during delete: {p}')
os.rmdir(root)
PY
}

cmd_destroy() {
  local target; target=$(validate)
  [[ $DRY_RUN_ONLY == 0 ]] || die "destroy disabled by TMP2_DRY_RUN_ONLY=$DRY_RUN_ONLY"
  [[ ${TMP2_ACK:-} == "I_ACK_TMP2_CACHE_DESTROY_$RUN_ID" ]] || die "missing exact destroy ACK"
  [[ -f $ROOT/MATRIX_PERSISTENCE_PASS ]] || die "matrix evidence is not persisted"
  [[ -f $PLAN && -f $PLAN.sha256 ]] || die "destroy plan/hash missing"
  sha256sum -c "$PLAN.sha256" >/dev/null || die "destroy plan hash mismatch"
  cmd_inspect >/dev/null
  local plan_target plan_dev actual_dev
  plan_target=$(awk -F'\t' 'NR==2{print $2}' "$PLAN"); plan_dev=$(awk -F'\t' 'NR==2{print $3}' "$PLAN")
  actual_dev=$(stat -Lc %d "$target")
  [[ $plan_target == "$target" && $plan_dev == "$actual_dev" ]] || die "destroy target/device differs from plan"
  safe_delete_tree "$target"
  [[ ! -e $target ]] || die "cache root still exists after delete"
  printf 'destroy_epoch\t%s\nrun_id\t%s\ntarget\t%s\nplan_sha256\t%s\n' \
    "$(date +%s)" "$RUN_ID" "$target" "$(awk '{print $1}' "$PLAN.sha256")" >"$ROOT/cache-destroyed.tsv"
  printf 'CACHE_DESTROYED_PASS\n' >"$ROOT/CACHE_DESTROYED_PASS"
  printf 'CACHE_DESTROY_PASS target=%s\n' "$target"
}

cmd_self_test() {
  [[ $FIXTURE == 1 ]] || die "offline self-test requires TMP2_FIXTURE=1"
  local target="$CACHE_PARENT/jfs-04tmp2-$RUN_ID"
  mkdir -p "$ROOT/state" "$ROOT/plans" "$target/a/b"
  printf 'x\n' >"$target/a/f"; printf 'y\n' >"$target/a/b/g"
  printf 'run_id\t%s\ncache_root\t%s\ncache_parent\t%s\nroot_dev\t%s\nstatus\tPREPARED\n' \
    "$RUN_ID" "$target" "$CACHE_PARENT" "$(stat -Lc %d "$target")" >"$STATE"
  cmd_inspect >/dev/null; cmd_plan >/dev/null
  [[ -s $PLAN && -s $ROOT/cleanup-inspect/tree.tsv ]] || die "self-test did not produce plan/inventory"
  printf 'TMP2_CLEANUP_SELF_TEST_PASS\n'
}

case "$MODE" in
  offline-self-test) cmd_self_test ;;
  inspect) cmd_inspect ;;
  plan) cmd_plan ;;
  destroy) cmd_destroy ;;
  -h|--help|'') usage; [[ -n $MODE ]] || exit 2 ;;
  *) usage; die "unknown mode: $MODE" ;;
esac
