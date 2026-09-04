#!/usr/bin/env bash
# 04-6 minimal driver.  It plans the frozen nine-cell screen and can execute
# one cell on an already prepared mount.  It deliberately owns no Ceph state:
# no sudo, mount, cleanup, scrub flag, or cache operation is present here.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANALYZER=${T046_ANALYZER:-$SCRIPT_DIR/t04-6-capacity-analyze.py}
RUN_ID=${2:-}
EVIDENCE_ROOT=${T046_EVIDENCE_ROOT:-/mnt/c/SunRise/test/04-6/${RUN_ID}}
TEST_DIR=${T046_TEST_DIR:-/mnt/juicefs/test_dir}
FIO=${T046_FIO:-fio}
RUNTIME=${T046_RUNTIME:-180}

die() { printf 'T046_DRIVER_FAIL\t%s\n' "$*" >&2; exit 2; }
[[ -x $ANALYZER || -f $ANALYZER ]] || die "analyzer missing: $ANALYZER"

usage() {
  cat >&2 <<'EOF'
usage: t04-6-capacity-driver.sh plan RUN_ID [ROOT]
       t04-6-capacity-driver.sh run-cell RUN_ID CELL [ROOT]
       t04-6-capacity-driver.sh seed-mseqwrite RUN_ID [ROOT]
       t04-6-capacity-driver.sh cleanup-mseqwrite RUN_ID [ROOT]
       t04-6-capacity-driver.sh cleanup-partial-mseqwrite RUN_ID [ROOT]
EOF
  exit 2
}

check_run_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid RUN_ID"; }
check_root() {
  local root
  root=$(readlink -m -- "$1")
  case $root in
    /mnt/c/SunRise/test/04-6/*|/tmp/production/opencode-04-6-*) ;;
    /tmp/t046-gate0.*) [[ ${T046_OFFLINE_FIXTURE:-0} == 1 ]] || die "offline root without fixture mode: $root" ;;
    *) die "root outside exact local/remote 04-6 scope: $root" ;;
  esac
  [[ ! -L $root ]] || die "symlink root rejected: $root"
  printf '%s\n' "$root"
}

check_test_dir() {
  local run_id=$1 resolved expected_mount
  resolved=$(readlink -m -- "$TEST_DIR")
  if [[ ${T046_OFFLINE_FIXTURE:-0} != 1 ]]; then
    expected_mount="/tmp/jfs-t046-$run_id"
    [[ $resolved == "$expected_mount/test_dir" ]] || die "live TEST_DIR must be RUN-scoped: $resolved"
    [[ -d $expected_mount && ! -L $expected_mount ]] || die 'live JuiceFS mount path missing or symlinked'
    [[ $(findmnt -rn -T "$expected_mount" -o TARGET,FSTYPE 2>/dev/null) == "$expected_mount fuse.juicefs" ]] ||
      die 'RUN-scoped path is not the exact JuiceFS mount'
  fi
  [[ ! -L $resolved ]] || die "TEST_DIR symlink rejected: $resolved"
}

cell_spec() {
  case $1 in
    R01) printf 'R\tmseqread\t8\tread\t256k\tpsync\t1\t1\tmseqread\t0\t7\n' ;;
    R02) printf 'R\tmseqread\t16\tread\t256k\tpsync\t1\t1\tmseqread\t0\t15\n' ;;
    R03) printf 'R\tmseqread\t8\tread\t256k\tpsync\t1\t1\tmseqread\t0\t7\n' ;;
    W01) printf 'W\tmseqwrite\t8\twrite\t4M\tpsync\t1\t1\tmseqwrite\t0\t7\n' ;;
    W02) printf 'W\tmseqwrite\t16\twrite\t4M\tpsync\t1\t1\tmseqwrite\t0\t15\n' ;;
    W03) printf 'W\tmseqwrite\t8\twrite\t4M\tpsync\t1\t1\tmseqwrite\t0\t7\n' ;;
    M01) printf 'M\trandrw\t64\trandrw\t256k\tlibaio\t128\t1\trw_test\t0\t63\n' ;;
    M02) printf 'M\trandrw\t128\trandrw\t256k\tlibaio\t128\t1\trw_test\t0\t127\n' ;;
    M03) printf 'M\trandrw\t64\trandrw\t256k\tlibaio\t128\t1\trw_test\t0\t63\n' ;;
    *) return 1 ;;
  esac
}

previous_cell() {
  case $1 in
    R01) printf '\n' ;; R02) printf 'R01\n' ;; R03) printf 'R02\n' ;;
    W01) printf 'R03\n' ;; W02) printf 'W01\n' ;; W03) printf 'W02\n' ;;
    M01) printf 'W03\n' ;; M02) printf 'M01\n' ;; M03) printf 'M02\n' ;;
    *) return 1 ;;
  esac
}

item_directory() {
  case $1 in
    mseqread|mseqwrite) printf '%s/%s\n' "$TEST_DIR" "$1" ;;
    randrw) printf '%s\n' "$TEST_DIR" ;;
    *) die "unknown item directory: $1" ;;
  esac
}

item_size_args() {
  case $1 in
    mseqread|mseqwrite) printf '%s\n' '--size=4G' '--refill_buffers' ;;
    randrw) printf '%s\n' '--filesize=1G' '--size=1G' '--fallocate=none' ;;
    *) die "unknown item size contract: $1" ;;
  esac
}

asset_manifest() {
  local item=$1 first=$2 last=$3 size=$4 dir name i
  dir=$TEST_DIR
  [[ $item == mseqread ]] && dir=$TEST_DIR/mseqread
  for ((i=first; i<=last; i++)); do
    name="$item.$i.0"
    [[ -f $dir/$name && ! -L $dir/$name ]] || die "asset missing/symlinked: $dir/$name"
    [[ $(stat -c %s -- "$dir/$name") == "$size" ]] || die "asset size mismatch: $dir/$name"
    printf '%s\t%s\n' "$name" "$size"
  done
}

write_plan() {
  local run_id=$1 root=$2 plan cell kind jobs rw bs engine depth direct prefix first last data_dir
  plan=$root/plan
  mkdir -p "$plan" "$root/cells"
  printf 'cell\tgroup\titem\tnumjobs\trw\tbs\tioengine\tiodepth\tdirect\tfile_prefix\tfirst\tlast\n' >"$plan/matrix.tsv"
  for cell in R01 R02 R03 W01 W02 W03 M01 M02 M03; do
    IFS=$'\t' read -r group kind jobs rw bs engine depth direct prefix first last < <(cell_spec "$cell")
    data_dir=$(item_directory "$kind")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$cell" "$group" "$kind" "$jobs" "$rw" "$bs" "$engine" "$depth" "$direct" "$prefix" "$first" "$last" >>"$plan/matrix.tsv"
    mkdir -p "$root/cells/$cell/bw" "$root/cells/$cell/lat"
    {
      printf 'cell=%s group=%s item=%s numjobs=%s rw=%s bs=%s ioengine=%s iodepth=%s direct=%s\n' \
        "$cell" "$group" "$kind" "$jobs" "$rw" "$bs" "$engine" "$depth" "$direct"
      printf 'files='; seq -s, "$first" "$last" | sed "s/[0-9]*/$prefix.&.0/g"; printf '\n'
      printf '%q ' "$FIO" --directory="$data_dir" --name="$prefix" \
        --filename_format="$prefix.\$jobnum.0" --rw="$rw" --bs="$bs" --numjobs="$jobs" \
        --ioengine="$engine" --iodepth="$depth" --direct=1 --allow_file_create=0 \
        $(item_size_args "$kind") \
        --time_based --runtime="$RUNTIME" --group_reporting --per_job_logs=1 \
        --write_bw_log="$root/cells/$cell/bw/$prefix" \
        --write_lat_log="$root/cells/$cell/lat/$prefix" --log_avg_msec=1000
      [[ $kind == randrw ]] && printf '%q ' --openfiles="$jobs"
      [[ $kind == mseqwrite ]] && printf '%q ' --end_fsync=1
      printf '\n'
    } >"$root/cells/$cell/command.txt"
    printf 'cell=%s\tstatus=PLANNED\n' "$cell" >"$root/cells/$cell/meta.tsv"
  done
  cat >"$root/plan/contract.tsv" <<EOF
key	value
run_id	$run_id
matrix	R01,R02,R03,W01,W02,W03,M01,M02,M03
formal_window_s	[15,175)
low_high_anchor	R/W:8->16->8; M:64->128->64
cache_semantics	cache-size=0,direct=1
cache_reset	DISALLOWED
privileged_operations	NONE_IN_DRIVER;EXTERNAL_ORCHESTRATOR_PER_TASKBOOK
remote_result_root	$root
mseqwrite_seed	one-time-only,16x4GiB,owned-by-04-6
mseqwrite_cleanup	exact-files-only,after-W03-or-abort,object-regression-required
pre_and_between_cell_gc	EXTERNAL_JUICEFS_GC_COMPACT_DELETE_TO_NORMALIZED_BASELINE
post_cleanup_gc	REQUIRED_EXTERNAL_JUICEFS_GC_DELETE_TO_OBJECT_BASELINE
EOF
  cat >"$root/plan/mseqwrite-seed.commands" <<EOF
# Run once before W01; never relayout between W01/W02/W03.
$FIO --directory=$TEST_DIR/mseqwrite --name=mseqwrite-seed --filename_format=mseqwrite.\$jobnum.0 --rw=write --bs=4M --size=4G --numjobs=16 --ioengine=psync --iodepth=1 --direct=1 --group_reporting
# After W03 (or an abort), record object count, remove only mseqwrite.0.0 .. mseqwrite.15.0,
# then run the separately authorized JuiceFS gc --delete back to the captured O0 object baseline.
EOF
  {
    printf '#!/usr/bin/env bash\n# frozen 04-6 command audit; no secrets\n'
    cat "$root/plan/matrix.tsv"
  } >"$root/commands.sh"
  chmod 600 "$root/commands.sh" "$root/plan"/contract.tsv "$root/plan"/matrix.tsv "$root"/cells/*/command.txt
}

plan() {
  local run_id=$1 root
  check_run_id "$run_id"
  root=$(check_root "${2:-$EVIDENCE_ROOT}")
  [[ ! -e $root ]] || die "root already exists; use a new RUN_ID"
  mkdir -p "$root"
  write_plan "$run_id" "$root"
  sha256sum "$0" "$ANALYZER" "$root/plan"/* "$root"/cells/*/command.txt >"$root/plan/input-sha256.tsv"
  printf 'T046_PLAN_PASS\t%s\n' "$root"
}

run_cell() {
  local run_id=$1 cell=$2 root spec group kind jobs rw bs engine depth direct prefix first last dir data_dir fio_rc prev tmp
  check_run_id "$run_id"; [[ $cell =~ ^[RWM]0[1-3]$ ]] || die "invalid cell"
  root=$(check_root "${3:-$EVIDENCE_ROOT}"); dir="$root/cells/$cell"
  [[ -f $dir/command.txt ]] || die "cell is not planned: $cell"
  [[ $(cat "$dir/meta.tsv") == $'cell='"$cell"$'\tstatus=PLANNED' ]] || die "cell is not in one-shot PLANNED state: $cell"
  prev=$(previous_cell "$cell")
  [[ -z $prev || $(cat "$root/cells/$prev/meta.tsv") == $'cell='"$prev"$'\tstatus=RAW_CAPTURED' ]] ||
    die "previous cell is not complete: $prev"
  [[ $cell != W01 || -s $root/seed/contract.tsv ]] || die 'W01 requires completed owned seed'
  [[ $cell != M01 || -s $root/seed/cleanup.tsv ]] || die 'M01 requires owned seed cleanup evidence'
  [[ ${T046_EXECUTE_ACK:-} == I_ACK_04_6_CELL_EXECUTION ]] || die "execution ACK missing"
  check_test_dir "$run_id"
  IFS=$'\t' read -r group kind jobs rw bs engine depth direct prefix first last < <(cell_spec "$cell")
  data_dir=$(item_directory "$kind")
  [[ -d $data_dir ]] || die "prepared test directory missing: $data_dir"
  [[ -f $root/commands.sh ]] || printf '#!/usr/bin/env bash\n# frozen 04-6 command audit; no secrets\n' >"$root/commands.sh"
  tmp="$dir/meta.tsv.running.$$"
  printf 'cell=%s\tstatus=RUNNING\tstart_ns=%s\n' "$cell" "$(date +%s%N)" >"$tmp"
  mv -T -- "$tmp" "$dir/meta.tsv"
  printf '# %s\n' "$cell" >>"$root/commands.sh"
  cmd=("$FIO" --directory="$data_dir" --name="$prefix" --filename_format="$prefix.\$jobnum.0"
    --rw="$rw" --bs="$bs" --numjobs="$jobs" --ioengine="$engine" --iodepth="$depth" --direct=1
    --allow_file_create=0 --time_based --runtime="$RUNTIME" --group_reporting --per_job_logs=1
    --write_bw_log="$dir/bw/$prefix" --write_lat_log="$dir/lat/$prefix" --log_avg_msec=1000)
  mapfile -t size_args < <(item_size_args "$kind")
  cmd+=("${size_args[@]}")
  [[ $kind == randrw ]] && cmd+=(--openfiles="$jobs")
  [[ $kind == mseqwrite ]] && cmd+=(--end_fsync=1)
  printf '%q ' "${cmd[@]}" >>"$root/commands.sh"; printf '\n' >>"$root/commands.sh"
  set +e
  (cd "$dir"; timeout "$((RUNTIME + 120))" "${cmd[@]}" >fio.txt 2>&1)
  fio_rc=$?
  set -e
  date +%s%N >"$dir/fio-end-ns.txt"
  printf '%s\n' "$fio_rc" >"$dir/fio.rc"
  if (( fio_rc != 0 )); then
    printf 'cell=%s\tstatus=FAILED\tfio_rc=%s\n' "$cell" "$fio_rc" >"$dir/meta.tsv"
    die "fio failed cell=$cell rc=$fio_rc"
  fi
  if ! grep -Eq '^Run status group|^[[:space:]]*(READ|WRITE):' "$dir/fio.txt"; then
    printf 'cell=%s\tstatus=FAILED\treason=fio_summary_missing\n' "$cell" >"$dir/meta.tsv"
    die "fio summary missing cell=$cell"
  fi
  if ! python3 "$ANALYZER" fio-latency "$dir/fio.txt" --item "$kind" --output "$dir/latency.tsv"; then
    printf 'cell=%s\tstatus=FAILED\treason=latency_parse\n' "$cell" >"$dir/meta.tsv"
    die "latency parse failed cell=$cell"
  fi
  [[ $(find "$dir/lat" -maxdepth 1 -type f -name '*_clat.*.log' | wc -l) -eq $jobs ]] ||
    die "per-job clat log count mismatch cell=$cell"
  printf 'cell=%s\tstatus=RAW_CAPTURED\n' "$cell" >"$dir/meta.tsv"
  printf 'T046_CELL_PASS\t%s\n' "$cell"
}

seed_mseqwrite() {
  local run_id=$1 root dir count mseq_count rw_count
  check_run_id "$run_id"; root=$(check_root "${2:-$EVIDENCE_ROOT}")
  [[ ${T046_EXECUTE_ACK:-} == I_ACK_04_6_MSEQWRITE_SEED ]] || die "seed ACK missing"
  check_test_dir "$run_id"
  dir="$TEST_DIR/mseqwrite"; [[ -d $dir ]] || die "mseqwrite directory missing"
  [[ ! -L $dir && -d $TEST_DIR/mseqread && ! -L $TEST_DIR/mseqread ]] || die "protected peer directory missing/symlinked"
  [[ $(find "$dir" -mindepth 1 -maxdepth 1 | wc -l) -eq 0 ]] || die "seed requires completely empty mseqwrite"
  mkdir -p "$root/seed"
  printf 'file\tsize\n' >"$root/seed/protected-before.tsv"
  asset_manifest mseqread 0 15 4294967296 >>"$root/seed/protected-before.tsv"
  asset_manifest rw_test 0 127 1073741824 >>"$root/seed/protected-before.tsv"
  mseq_count=16; rw_count=128
  printf 'run_id\t%s\ntest_dir\t%s\nstatus\tARMED\n' \
    "$run_id" "$(readlink -m -- "$TEST_DIR")" >"$root/seed/intent.tsv"
  printf 'seed_file\n' >"$root/seed/intent-targets.tsv"
  printf 'mseqwrite.%s.0\n' {0..15} >>"$root/seed/intent-targets.tsv"
  "$FIO" --directory="$dir" --name=mseqwrite-seed --filename_format='mseqwrite.$jobnum.0' \
    --rw=write --bs=4M --size=4G --numjobs=16 --ioengine=psync --iodepth=1 --direct=1 --group_reporting \
    >"$root/seed/fio.txt" 2>&1
  count=$(find "$dir" -maxdepth 1 -type f -name 'mseqwrite.*.0' | wc -l)
  [[ $count -eq 16 ]] || die "seed produced $count files, expected 16"
  printf 'seed_file\tsize\n' >"$root/seed/assets.tsv"
  find "$dir" -maxdepth 1 -type f -name 'mseqwrite.*.0' -printf '%f\t%s\n' | sort -V >>"$root/seed/assets.tsv"
  awk 'NR>1 && $2 != 4294967296 {bad=1} END {exit bad}' "$root/seed/assets.tsv" || die 'seed files are not 4GiB'
  printf 'file\tsize\n' >"$root/seed/protected-after.tsv"
  asset_manifest mseqread 0 15 4294967296 >>"$root/seed/protected-after.tsv"
  asset_manifest rw_test 0 127 1073741824 >>"$root/seed/protected-after.tsv"
  cmp -s "$root/seed/protected-before.tsv" "$root/seed/protected-after.tsv" || die 'protected asset manifest changed during seed'
  printf 'run_id\t%s\ntest_dir\t%s\nseed_complete\t%s\nprotected_mseqread_count\t%s\nprotected_rw_test_count\t%s\n' \
    "$run_id" "$(readlink -m -- "$TEST_DIR")" "$(date +%s)" "$mseq_count" "$rw_count" >"$root/seed/contract.tsv"
  printf 'T046_SEED_PASS\t%s\n' "$root/seed"
}

cleanup_mseqwrite() {
  local run_id=$1 root count recorded_run recorded_dir expected actual
  check_run_id "$run_id"; root=$(check_root "${2:-$EVIDENCE_ROOT}")
  [[ ${T046_EXECUTE_ACK:-} == I_ACK_04_6_MSEQWRITE_CLEANUP ]] || die "cleanup ACK missing"
  check_test_dir "$run_id"
  [[ -d $TEST_DIR/mseqwrite ]] || die "mseqwrite directory missing"
  [[ ! -L $TEST_DIR/mseqwrite ]] || die 'mseqwrite directory symlink rejected'
  [[ -s $root/plan/contract.tsv && -s $root/seed/intent.tsv && -s $root/seed/intent-targets.tsv &&
     -s $root/seed/contract.tsv && -s $root/seed/assets.tsv ]] ||
    die 'owned plan/seed evidence missing'
  [[ $(awk -F '\t' '$1=="run_id"{print $2}' "$root/plan/contract.tsv") == "$run_id" ]] ||
    die 'plan RUN_ID ownership mismatch'
  recorded_run=$(awk -F '\t' '$1=="run_id"{print $2}' "$root/seed/contract.tsv")
  recorded_dir=$(awk -F '\t' '$1=="test_dir"{print $2}' "$root/seed/contract.tsv")
  [[ $recorded_run == "$run_id" && $recorded_dir == "$(readlink -m -- "$TEST_DIR")" ]] ||
    die 'seed ownership mismatch'
  expected=$(printf 'mseqwrite.%s.0\n' {0..15})
  actual=$(tail -n +2 "$root/seed/assets.tsv" | cut -f1)
  [[ $actual == "$expected" ]] || die 'seed manifest is not the exact owned 0..15 set'
  while IFS=$'\t' read -r name size; do
    [[ $name == seed_file ]] && continue
    [[ $name =~ ^mseqwrite\.([0-9]|1[0-5])\.0$ && $size == 4294967296 ]] || die 'invalid seed manifest row'
    [[ -f $TEST_DIR/mseqwrite/$name && ! -L $TEST_DIR/mseqwrite/$name ]] || die "owned seed file missing/symlinked: $name"
    [[ $(stat -c %s -- "$TEST_DIR/mseqwrite/$name") == 4294967296 ]] || die "owned seed size drift: $name"
  done <"$root/seed/assets.tsv"
  count=$(find "$TEST_DIR/mseqwrite" -maxdepth 1 -type f -name 'mseqwrite.*.0' | wc -l)
  [[ $count -eq 16 ]] || die "refuse cleanup: expected exactly 16 seed files, got $count"
  [[ $(find "$TEST_DIR/mseqwrite" -mindepth 1 -maxdepth 1 | wc -l) -eq 16 ]] ||
    die 'refuse cleanup: mseqwrite contains non-manifest entries'
  rm -f "$TEST_DIR/mseqwrite"/mseqwrite.{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}.0
  [[ $(find "$TEST_DIR/mseqwrite" -maxdepth 1 -type f -name 'mseqwrite.*.0' | wc -l) -eq 0 ]] || die 'seed cleanup incomplete'
  printf 'cleanup_complete\t%s\nobject_regression\tREQUIRED_EXTERNAL_GATE\ngc_delete\tREQUIRED_EXTERNAL_TO_OBJECT_BASELINE\n' "$(date +%s)" >"$root/seed/cleanup.tsv"
  printf 'T046_CLEANUP_PASS\t%s\n' "$root/seed"
}

cleanup_partial_mseqwrite() {
  local run_id=$1 root recorded_run recorded_dir name expected actual
  check_run_id "$run_id"; root=$(check_root "${2:-$EVIDENCE_ROOT}")
  [[ ${T046_EXECUTE_ACK:-} == I_ACK_04_6_MSEQWRITE_CLEANUP ]] || die "cleanup ACK missing"
  check_test_dir "$run_id"
  [[ -d $TEST_DIR/mseqwrite && ! -L $TEST_DIR/mseqwrite ]] || die 'mseqwrite directory missing/symlinked'
  [[ -s $root/plan/contract.tsv && -s $root/seed/intent.tsv && -s $root/seed/intent-targets.tsv ]] ||
    die 'owned partial-seed intent missing'
  [[ $(awk -F '\t' '$1=="run_id"{print $2}' "$root/plan/contract.tsv") == "$run_id" ]] ||
    die 'plan RUN_ID ownership mismatch'
  recorded_run=$(awk -F '\t' '$1=="run_id"{print $2}' "$root/seed/intent.tsv")
  recorded_dir=$(awk -F '\t' '$1=="test_dir"{print $2}' "$root/seed/intent.tsv")
  [[ $recorded_run == "$run_id" && $recorded_dir == "$(readlink -m -- "$TEST_DIR")" ]] ||
    die 'partial-seed ownership mismatch'
  expected=$(printf 'mseqwrite.%s.0\n' {0..15})
  actual=$(tail -n +2 "$root/seed/intent-targets.tsv")
  [[ $actual == "$expected" ]] || die 'partial-seed intent targets are not exact 0..15 set'
  while IFS= read -r name; do
    grep -Fxq -- "$name" "$root/seed/intent-targets.tsv" ||
      die "partial-seed directory contains an unknown entry: $name"
  done < <(find "$TEST_DIR/mseqwrite" -mindepth 1 -maxdepth 1 -printf '%f\n')
  while IFS= read -r name; do
    [[ $name == seed_file ]] && continue
    if [[ -e $TEST_DIR/mseqwrite/$name || -L $TEST_DIR/mseqwrite/$name ]]; then
      [[ -f $TEST_DIR/mseqwrite/$name && ! -L $TEST_DIR/mseqwrite/$name ]] ||
        die "partial-seed target is not a regular owned file: $name"
    fi
  done <"$root/seed/intent-targets.tsv"
  while IFS= read -r name; do
    [[ $name == seed_file ]] && continue
    [[ ! -e $TEST_DIR/mseqwrite/$name ]] || rm -f -- "$TEST_DIR/mseqwrite/$name"
  done <"$root/seed/intent-targets.tsv"
  [[ $(find "$TEST_DIR/mseqwrite" -mindepth 1 -maxdepth 1 | wc -l) -eq 0 ]] ||
    die 'partial-seed cleanup left unknown entries; preserve for review'
  printf 'partial_cleanup_complete\t%s\nobject_regression\tREQUIRED_EXTERNAL_GATE\n' \
    "$(date +%s)" >"$root/seed/partial-cleanup.tsv"
  printf 'T046_PARTIAL_CLEANUP_PASS\t%s\n' "$root/seed"
}

[[ $# -ge 2 ]] || usage
case $1 in
  plan) [[ $# -le 3 ]] || usage; plan "$2" "${3:-}" ;;
  run-cell) [[ $# -le 4 ]] || usage; [[ $# -eq 4 ]] || usage; run_cell "$2" "$3" "$4" ;;
  seed-mseqwrite) [[ $# -le 3 ]] || usage; seed_mseqwrite "$2" "${3:-}" ;;
  cleanup-mseqwrite) [[ $# -le 3 ]] || usage; cleanup_mseqwrite "$2" "${3:-}" ;;
  cleanup-partial-mseqwrite) [[ $# -le 3 ]] || usage; cleanup_partial_mseqwrite "$2" "${3:-}" ;;
  *) usage ;;
esac
