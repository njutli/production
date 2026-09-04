#!/usr/bin/env bash
# 04-tmp3 L1 planner.  This file only creates a local plan and renders
# commands for an already-authorised operator; it never connects to a node.
# DEFECT-D01 DEFECT-D04 DEFECT-D05 DEFECT-D06 DEFECT-D08 DEFECT-D16
# DEFECT-D19 DEFECT-D21 DEFECT-D22 DEFECT-D23 DEFECT-D25 DEFECT-D26
# DEFECT-D27 DEFECT-D28 DEFECT-D29 DEFECT-D30 DEFECT-D31 DEFECT-D32
set -euo pipefail
export LC_ALL=C

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TASK_ROOT=/mnt/c/SunRise/test/04-tmp3
ANALYZER=$SELF_DIR/t04tmp3-screen-analyze.py

die() { printf 'T04TMP3_DRIVER_FAIL\t%s\n' "$*" >&2; exit 2; }
[[ -z ${T04TMP3_TASK_ROOT+x} ]] || die 'environment override rejected: T04TMP3_TASK_ROOT'
valid_run() { [[ ${1:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "invalid RUN_ID"; }
safe_root() {
  local root
  root=$(readlink -m -- "$1")
  [[ $root == "$TASK_ROOT"/* ]] || die "root outside task root: $root"
  [[ ! -L $root ]] || die "symlink root rejected: $root"
  printf '%s\n' "$root"
}

usage() {
  cat >&2 <<'EOF'
usage: t04tmp3-screen-driver.sh plan RUN_ID [EVIDENCE_ROOT]
       t04tmp3-screen-driver.sh commands RUN_ID [EVIDENCE_ROOT]
EOF
  exit 2
}

write_plan() {
  local run_id=$1 root=$2
  mkdir -p "$root"/{common,cells,screen}
  printf 'epoch_iso\trun_id\tvalidity_state\tlifecycle_state\tremote_status\tlocal_status\tincident_status\treason\tevidence_root\tactor\n' >"$root/run-state.tsv"
  printf '%s\t%s\tACTIVE\tACTIVE\tNONE\tPRESERVED\tNONE\tL0 plan only\t%s\tGPT\n' "$(date -Is)" "$run_id" "$root" >>"$root/run-state.tsv"
  printf 'key\tvalue\nrun_id\t%s\nevidence_level\tL1_SCREEN\nremote_result_root\tNONE\nremote_asset_root\t/mnt/juicefs/test_dir/04tmp3-%s\nlocal_scratch\t/mnt/jfs-cache/04tmp3/jfs-04tmp3-%s\ncache_semantics\tcache-size=0,direct=1\ncache_flush_scope\tNONE-157-150-152\ncleanup\texact-manifest-files-only\nstate_mutations\tFORBIDDEN\nl2\tNO-AUTOMATIC-EXPANSION\n' "$run_id" "$run_id" "$run_id" >"$root/common/contract.tsv"
  printf 'cell\tarm\tworkload\truntime_s\tcommand_class\tstatus\n' >"$root/screen/matrix.tsv"
  local cell arm workload runtime
  for cell in R01 R02 R03 R04 R05 R06; do
    case $cell in
      R01) arm=A;; R02) arm=F;; R03) arm=R;; R04) arm=R;; R05) arm=F;; R06) arm=A;;
    esac
    printf '%s\t%s\tseq_read\t60\tfio-read\tPLANNED\n' "$cell" "$arm" >>"$root/screen/matrix.tsv"
  done
  for cell in W01 W02 W03 W04 W05 W06; do
    case $cell in
      W01) arm=A;; W02) arm=F;; W03) arm=W;; W04) arm=W;; W05) arm=F;; W06) arm=A;;
    esac
    printf '%s\t%s\tseq_write\t120\tfio-write\tPLANNED\n' "$cell" "$arm" >>"$root/screen/matrix.tsv"
  done
  cat >"$root/common/assets.tsv" <<EOF
asset_class\trelative_path\tbytes\townership\tprecondition\tcleanup
local_source\tscratch/20Gfile\t21474836480\t04tmp3\tnon-sparse,stable\texact-file
remote_read\tread/20Gfile\t21474836480\t04tmp3\tRUN root only\texact-file
remote_read\tread/testfile1\t10737418240\t04tmp3\tRUN root only\texact-file
remote_write\twrite/<CELL>/testfile1\t10737418240\t04tmp3\tpreallocated,unique\texact-file
remote_cp_write\tcp-write/<CELL>/20Gfile\t21474836480\t04tmp3\tdestination-absent\texact-file
EOF
  printf 'A\t--max-fuse-io 256K\tDELIVER\nF\t--max-fuse-io 1M\tFUSE1M\nR\t--max-fuse-io 1M --max-readahead 8M\tREAD-RA8M\nW\t--max-fuse-io 1M --buffer-size 1024\tWRITE-TUNED\n' >"$root/common/arms.tsv"
  commands "$run_id" "$root" >"$root/common/commands.sh"
  chmod 600 "$root/run-state.tsv" "$root/common"/* "$root/screen"/*
}

commands() {
  local run_id=$1 root=$2
  local arm="$root/common/arms.tsv"
  {
    printf '# 04-tmp3 overview only; do not execute rendered lines.\n'
    printf '# The authoritative commands, expanded per cell and arm mount, are in t04tmp3-executor.sh.\n'
    printf '# run_id=%s; executor performs full read A-F-R-R-F-A and write A-F-W-W-F-A.\n' "$run_id"
    printf '# matrix (plan metadata)\n'; cat "$root/screen/matrix.tsv"
    printf '# arms\n'; cat "$arm"
  }
}

plan() {
  local run_id=$1 root
  valid_run "$run_id"
  root=$(safe_root "${2:-$TASK_ROOT/$run_id}")
  [[ ! -e $root ]] || die "root already exists: $root"
  [[ -f $ANALYZER ]] || die "analyzer missing: $ANALYZER"
  mkdir -p "$root"
  write_plan "$run_id" "$root"
  sha256sum "$SELF_DIR/t04tmp3-screen-driver.sh" "$ANALYZER" "$root/common"/* "$root/screen/matrix.tsv" >"$root/common/input-sha256.tsv"
  printf 'T04TMP3_PLAN_PASS\t%s\n' "$root"
}

[[ $# -ge 2 ]] || usage
case $1 in
  plan) [[ $# -le 3 ]] || usage; plan "$2" "${3:-$TASK_ROOT/$2}" ;;
  commands) [[ $# -le 3 ]] || usage; valid_run "$2"; commands "$2" "$(safe_root "${3:-$TASK_ROOT/$2}")" ;;
  *) usage ;;
esac
