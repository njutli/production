#!/usr/bin/env bash
# State-driven Ceph scrub pause/restore control for U141d.
#
# Mutating commands are intentionally separated from the performance driver:
#   inspect <LEASE_ID>                         read-only
#   plan-pause <LEASE_ID>                      read-only
#   pause <LEASE_ID> <FSID> I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
#   verify-paused <LEASE_ID>                   read-only
#   plan-restore <LEASE_ID>                    read-only
#   restore <LEASE_ID>                         restores only owned flags
#   verify-restored <LEASE_ID>                 read-only
#   state-path <LEASE_ID>                      read-only
#   --self-test                                offline only
set -euo pipefail
export LC_ALL=C

STATE_DIR=${U141D_SCRUB_STATE_DIR:-/tmp/production}
QUIET_TIMEOUT=${U141D_SCRUB_QUIET_TIMEOUT:-180}
QUIET_POLL=${U141D_SCRUB_QUIET_POLL:-5}
ACK=I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
OWNED_FLAGS=(noscrub nodeep-scrub)

die() { printf 'U141D_SCRUB_CONTROL_FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

validate_lease() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*-phase-(a|b)$ ]] \
    || die "invalid lease id (expected <RUN_ID>-phase-a|b): ${1:-missing}"
}

state_path() {
  validate_lease "$1"
  printf '%s/u141d-scrub-control-%s.tsv\n' "$STATE_DIR" "$1"
}

ceph_read() {
  timeout 20 ceph "$@"
}

ceph_write() {
  timeout 20 sudo ceph "$@"
}

normalize_flags_json() {
  python3 -c '
import json, sys
d=json.load(sys.stdin)
v=d.get("flags", [])
if isinstance(v, str):
    xs=[x for x in v.replace("nodeep_scrub", "nodeep-scrub").split(",") if x]
elif isinstance(v, list):
    xs=[str(x).replace("nodeep_scrub", "nodeep-scrub") for x in v]
else:
    raise SystemExit("unsupported flags type: %r" % type(v).__name__)
print(",".join(sorted(set(xs))))
'
}

normalize_flags_text() {
  python3 -c '
import sys
xs=[]
for x in sys.stdin.read().strip().split(","):
    x=x.strip().replace("nodeep_scrub", "nodeep-scrub")
    if x: xs.append(x)
print(",".join(sorted(set(xs))))
'
}

current_fsid() { ceph_read fsid 2>/dev/null | tr -d '[:space:]'; }
current_flags() { ceph_read osd dump --format json 2>/dev/null | normalize_flags_json; }

flag_present() {
  local list=$1 flag=$2
  [[ ,$list, == *,$flag,* ]]
}

expected_paused_flags() {
  local pre=$1
  printf '%s\n' "${pre:+$pre,}noscrub,nodeep-scrub" | normalize_flags_text
}

health_info() {
  ceph_read health detail --format json 2>/dev/null | python3 -c '
import json, sys
d=json.load(sys.stdin)
status=str(d.get("status", "MISSING"))
checks=d.get("checks", {})
if not isinstance(checks, dict):
    raise SystemExit("health checks is not an object")
print(status + "\t" + ",".join(sorted(checks)))
'
}

osd_info() {
  ceph_read osd stat --format json 2>/dev/null | python3 -c '
import json, sys
d=json.load(sys.stdin)
keys=("num_osds","num_up_osds","num_in_osds")
if any(not isinstance(d.get(k), int) for k in keys):
    raise SystemExit("missing numeric OSD counts")
print("%d\t%d\t%d" % tuple(d[k] for k in keys))
'
}

pg_info() {
  ceph_read pg dump pgs_brief 2>/dev/null | awk '
    $1 ~ /^[0-9]+\.[0-9a-fA-F]+$/ {
      total++
      states[$2]++
      if ($2 != "active+clean") nonclean++
      if ($2 ~ /(^|\+)scrubbing(\+|$)/ || $2 ~ /(^|\+)deep(\+|$)/) scrub++
    }
    END {
      detail=""
      for (s in states) detail=detail (detail==""?"":",") s ":" states[s]
      printf "%d\t%d\t%d\t%s\n", total+0, nonclean+0, scrub+0, detail
    }'
}

state_value() {
  local file=$1 type=$2 key=$3
  awk -F'\t' -v t="$type" -v k="$key" '$1==t && $2==k{v=$3} END{print v}' "$file"
}

last_status() {
  awk -F'\t' '$1=="status"{v=$3} END{print v}' "$1"
}

audit() {
  local file=$1 action=$2 rc=$3 detail=$4
  printf 'event\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$action" "$rc" "$detail" >> "$file" \
    || die "cannot append audit to $file"
}

live_snapshot() {
  local fsid flags health status checks osds up ins pgs nonclean scrub states
  fsid=$(current_fsid) || die "cannot read Ceph FSID"
  flags=$(current_flags) || die "cannot parse Ceph OSD flags"
  health=$(health_info) || die "cannot parse Ceph health JSON"
  IFS=$'\t' read -r status checks <<<"$health"
  IFS=$'\t' read -r osds up ins < <(osd_info) || die "cannot parse Ceph OSD counts"
  IFS=$'\t' read -r pgs nonclean scrub states < <(pg_info) || die "cannot parse Ceph PG states"
  printf 'FSID=%s\nFLAGS=%s\nHEALTH_STATUS=%s\nHEALTH_CHECK_KEYS=%s\n' \
    "$fsid" "${flags:-none}" "$status" "${checks:-none}"
  printf 'OSDS=%s UP=%s IN=%s\nPGS=%s NONCLEAN=%s SCRUBBING=%s STATES=%s\n' \
    "$osds" "$up" "$ins" "$pgs" "$nonclean" "$scrub" "${states:-none}"
}

require_clean_unpaused() {
  local flags health status checks osds up ins pgs nonclean scrub states
  flags=$(current_flags) || die "cannot parse Ceph OSD flags"
  ! flag_present "$flags" noscrub || die "pre-existing noscrub is outside this lease"
  ! flag_present "$flags" nodeep-scrub || die "pre-existing nodeep-scrub is outside this lease"
  health=$(health_info) || die "cannot parse Ceph health JSON"
  IFS=$'\t' read -r status checks <<<"$health"
  [[ $status == HEALTH_OK && -z $checks ]] \
    || die "pre-pause health is not exact HEALTH_OK/no-checks: status=$status checks=${checks:-none}"
  IFS=$'\t' read -r osds up ins < <(osd_info) || die "cannot parse Ceph OSD counts"
  (( osds > 0 && osds == up && osds == ins )) \
    || die "OSDs are not all up/in: total=$osds up=$up in=$ins"
  IFS=$'\t' read -r pgs nonclean scrub states < <(pg_info) || die "cannot parse Ceph PG states"
  (( pgs > 0 && nonclean == 0 && scrub == 0 )) \
    || die "PGs not quiescent before pause: pgs=$pgs nonclean=$nonclean scrub=$scrub states=$states"
}

require_paused_health() {
  local health status checks osds up ins
  health=$(health_info) || die "cannot parse Ceph health JSON"
  IFS=$'\t' read -r status checks <<<"$health"
  if [[ $status == HEALTH_OK && -z $checks ]]; then
    :
  elif [[ $status == HEALTH_WARN && $checks == OSDMAP_FLAGS ]]; then
    :
  else
    die "paused health has unexpected checks: status=$status checks=${checks:-none}"
  fi
  IFS=$'\t' read -r osds up ins < <(osd_info) || die "cannot parse Ceph OSD counts"
  (( osds > 0 && osds == up && osds == ins )) \
    || die "OSDs are not all up/in while paused: total=$osds up=$up in=$ins"
}

require_state_identity() {
  local lease=$1 file=$2 fsid live
  [[ -f $file ]] || die "state file missing: $file"
  [[ $(state_value "$file" meta lease) == "$lease" ]] || die "state lease mismatch"
  fsid=$(state_value "$file" meta fsid)
  live=$(current_fsid) || die "cannot read live FSID"
  [[ -n $fsid && $live == "$fsid" ]] || die "Ceph FSID mismatch state=$fsid live=$live"
}

verify_paused_internal() {
  local lease=$1 file pre expected live pgs nonclean scrub states status
  file=$(state_path "$lease")
  require_state_identity "$lease" "$file"
  status=$(last_status "$file")
  [[ $status == paused ]] || die "lease is not paused: status=${status:-missing}"
  pre=$(state_value "$file" pre flags)
  expected=$(expected_paused_flags "$pre")
  live=$(current_flags) || die "cannot parse live flags"
  [[ $live == "$expected" ]] \
    || die "paused flags drifted: expected=$expected live=${live:-none}"
  require_paused_health
  IFS=$'\t' read -r pgs nonclean scrub states < <(pg_info) || die "cannot parse PG states"
  (( pgs > 0 && nonclean == 0 && scrub == 0 )) \
    || die "paused PGs not quiescent: pgs=$pgs nonclean=$nonclean scrub=$scrub states=$states"
  printf 'SCRUB_PAUSE_VERIFY_PASS lease=%s state=%s flags=%s pgs=%s\n' \
    "$lease" "$file" "$live" "$pgs"
}

cmd_inspect() {
  local lease=$1 file
  file=$(state_path "$lease")
  printf 'LEASE=%s\nSTATE_FILE=%s\nSTATE_PRESENT=%s\n' \
    "$lease" "$file" "$([[ -f $file ]] && echo yes || echo no)"
  [[ ! -f $file ]] || sed -n '1,200p' "$file"
  live_snapshot
}

cmd_plan_pause() {
  local lease=$1 file fsid
  file=$(state_path "$lease")
  [[ ! -e $file ]] || die "state already exists; refuse a second pause lease: $file"
  require_clean_unpaused
  fsid=$(current_fsid)
  live_snapshot
  printf 'PLAN_PAUSE_PASS lease=%s\n' "$lease"
  printf 'EXECUTE: %q pause %q %q %q\n' "$0" "$lease" "$fsid" "$ACK"
  printf 'ROLLBACK: %q restore %q\n' "$0" "$lease"
}

rollback_pause_failure() {
  local file=$1 flag live rc=0
  for flag in nodeep-scrub noscrub; do
    live=$(current_flags 2>/dev/null || true)
    if flag_present "$live" "$flag"; then
      if ceph_write osd unset "$flag"; then
        audit "$file" "rollback-unset-$flag" 0 success
      else
        audit "$file" "rollback-unset-$flag" 1 failed || true
        rc=1
      fi
    fi
  done
  return "$rc"
}

cmd_pause() {
  local lease=$1 expected_fsid=$2 ack=$3 file live_fsid pre tmp flag i
  [[ $ack == "$ACK" ]] || die "pause requires exact acknowledgement token $ACK"
  file=$(state_path "$lease")
  [[ ! -e $file ]] || die "state already exists: $file"
  live_fsid=$(current_fsid) || die "cannot read Ceph FSID"
  [[ $live_fsid == "$expected_fsid" ]] \
    || die "FSID approval mismatch expected=$expected_fsid live=$live_fsid"
  require_clean_unpaused
  pre=$(current_flags)
  mkdir -p "$STATE_DIR"
  umask 077
  tmp="${file}.new.$$"
  {
    printf 'meta\tlease\t%s\n' "$lease"
    printf 'meta\tfsid\t%s\n' "$live_fsid"
    printf 'meta\tcreated_epoch\t%s\n' "$(date +%s)"
    printf 'pre\tflags\t%s\n' "$pre"
    printf 'intent\tadd\tnoscrub\n'
    printf 'intent\tadd\tnodeep-scrub\n'
    printf 'status\t%s\tarming\n' "$(date +%s)"
  } > "$tmp"
  mv -T "$tmp" "$file"

  for flag in noscrub nodeep-scrub; do
    audit "$file" "set-$flag-begin" 0 requested
    if ceph_write osd set "$flag"; then
      audit "$file" "set-$flag-end" 0 success
    else
      audit "$file" "set-$flag-end" 1 failed || true
      rollback_pause_failure "$file" \
        || die "set $flag failed and rollback was incomplete; urgent manual review state=$file"
      printf 'status\t%s\tpause-failed-rolled-back\n' "$(date +%s)" >> "$file"
      die "set $flag failed; owned flags rolled back"
    fi
  done

  for ((i=0; i<=QUIET_TIMEOUT; i+=QUIET_POLL)); do
    if (
      local expected live pgs nonclean scrub states
      expected=$(expected_paused_flags "$pre")
      live=$(current_flags)
      [[ $live == "$expected" ]]
      require_paused_health
      IFS=$'\t' read -r pgs nonclean scrub states < <(pg_info)
      (( pgs > 0 && nonclean == 0 && scrub == 0 ))
    ); then
      printf 'status\t%s\tpaused\n' "$(date +%s)" >> "$file"
      audit "$file" pause-complete 0 "quiet_wait_s=$i"
      verify_paused_internal "$lease"
      return 0
    fi
    (( i < QUIET_TIMEOUT )) || break
    sleep "$QUIET_POLL"
  done
  audit "$file" pause-quiescence-timeout 1 "timeout_s=$QUIET_TIMEOUT" || true
  rollback_pause_failure "$file" \
    || die "pause did not become quiescent and rollback was incomplete; urgent manual review state=$file"
  printf 'status\t%s\tpause-failed-rolled-back\n' "$(date +%s)" >> "$file"
  die "pause flags set but PG/health did not quiesce within ${QUIET_TIMEOUT}s; rolled back"
}

restore_precheck() {
  local lease=$1 file=$2 pre=$3 live=$4 flag
  require_state_identity "$lease" "$file"
  for flag in ${pre//,/ }; do
    [[ -z $flag ]] || flag_present "$live" "$flag" \
      || die "pre-existing flag disappeared; refuse ownership-blind restore: $flag"
  done
  local allowed
  allowed=$(expected_paused_flags "$pre")
  for flag in ${live//,/ }; do
    [[ -z $flag ]] || flag_present "$allowed" "$flag" \
      || die "unexpected flag appeared; refuse restore: $flag live=$live allowed=$allowed"
  done
}

cmd_plan_restore() {
  local lease=$1 file pre live flag
  file=$(state_path "$lease")
  require_state_identity "$lease" "$file"
  pre=$(state_value "$file" pre flags)
  live=$(current_flags)
  restore_precheck "$lease" "$file" "$pre" "$live"
  printf 'PLAN_RESTORE_PASS lease=%s state=%s pre_flags=%s live_flags=%s\n' \
    "$lease" "$file" "${pre:-none}" "${live:-none}"
  for flag in nodeep-scrub noscrub; do
    flag_present "$live" "$flag" && printf 'EXECUTE: sudo ceph osd unset %q\n' "$flag"
  done
  printf 'CONTROL: %q restore %q\n' "$0" "$lease"
}

cmd_restore() {
  local lease=$1 file pre live flag final status
  file=$(state_path "$lease")
  require_state_identity "$lease" "$file"
  pre=$(state_value "$file" pre flags)
  live=$(current_flags)
  restore_precheck "$lease" "$file" "$pre" "$live"
  status=$(last_status "$file")
  if [[ $status == restored && $live == "$pre" ]]; then
    printf 'SCRUB_RESTORE_PASS lease=%s state=%s already_restored=1\n' "$lease" "$file"
    return 0
  fi
  for flag in nodeep-scrub noscrub; do
    live=$(current_flags)
    if flag_present "$live" "$flag"; then
      audit "$file" "unset-$flag-begin" 0 requested
      if ceph_write osd unset "$flag"; then
        audit "$file" "unset-$flag-end" 0 success
      else
        audit "$file" "unset-$flag-end" 1 failed || true
        die "failed to restore $flag; rerun state-driven restore after inspection"
      fi
    fi
  done
  final=$(current_flags)
  [[ $final == "$pre" ]] \
    || die "restore verification failed expected=${pre:-none} live=${final:-none}"
  printf 'status\t%s\trestored\n' "$(date +%s)" >> "$file"
  audit "$file" restore-complete 0 "flags=${final:-none}"
  printf 'SCRUB_RESTORE_PASS lease=%s state=%s flags=%s\n' \
    "$lease" "$file" "${final:-none}"
  live_snapshot
}

cmd_verify_restored() {
  local lease=$1 file pre live
  file=$(state_path "$lease")
  require_state_identity "$lease" "$file"
  [[ $(last_status "$file") == restored ]] || die "state does not end in restored"
  pre=$(state_value "$file" pre flags)
  live=$(current_flags)
  [[ $live == "$pre" ]] || die "restored flags drifted expected=${pre:-none} live=${live:-none}"
  printf 'SCRUB_RESTORE_VERIFY_PASS lease=%s state=%s flags=%s\n' \
    "$lease" "$file" "${live:-none}"
  live_snapshot
}

self_test() {
  local td rc state
  td=$(mktemp -d /tmp/u141d-scrub-selftest.XXXXXX)
  STATE_DIR="$td/state"
  mkdir -p "$STATE_DIR"
  printf '\n' > "$td/flags"
  printf 'clean\n' > "$td/pg"
  printf '0\n' > "$td/fail-nodeep"

  ceph_read() {
    local first=${1:-}; shift || true
    case "$first $*" in
      "fsid ") printf 'mock-fsid\n' ;;
      "osd dump --format json")
        python3 - "$td/flags" <<'PY'
import json,sys
print(json.dumps({"flags":open(sys.argv[1]).read().strip()}))
PY
        ;;
      "health detail --format json")
        if grep -Eq 'noscrub|nodeep-scrub' "$td/flags"; then
          printf '{"status":"HEALTH_WARN","checks":{"OSDMAP_FLAGS":{"summary":{"message":"noscrub,nodeep-scrub flag(s) set"}}}}\n'
        else
          printf '{"status":"HEALTH_OK","checks":{}}\n'
        fi
        ;;
      "osd stat --format json") printf '{"num_osds":6,"num_up_osds":6,"num_in_osds":6}\n' ;;
      "pg dump pgs_brief")
        printf 'PG_STAT STATE UP UP_PRIMARY ACTING ACTING_PRIMARY\n'
        if grep -q scrub "$td/pg"; then
          printf '3.0 active+clean+scrubbing [0,1,2] 0 [0,1,2] 0\n'
        else
          printf '3.0 active+clean [0,1,2] 0 [0,1,2] 0\n'
        fi
        ;;
      "osd set noscrub")
        printf 'noscrub\n' >> "$td/flags"
        tr '\n' ',' < "$td/flags" | normalize_flags_text > "$td/flags.new"
        mv "$td/flags.new" "$td/flags"
        ;;
      "osd set nodeep-scrub")
        [[ $(<"$td/fail-nodeep") == 0 ]] || return 7
        printf '%s,nodeep-scrub\n' "$(<"$td/flags")" | normalize_flags_text > "$td/flags.new"
        mv "$td/flags.new" "$td/flags"
        ;;
      "osd unset noscrub"|"osd unset nodeep-scrub")
        local target=${2:-}
        python3 - "$td/flags" "$target" > "$td/flags.new" <<'PY'
import sys
p,target=sys.argv[1:]
xs=[x for x in open(p).read().strip().split(',') if x and x != target]
print(','.join(sorted(set(xs))))
PY
        mv "$td/flags.new" "$td/flags"
        ;;
      *) printf 'mock ceph unsupported: %s %s\n' "$first" "$*" >&2; return 2 ;;
    esac
  }
  ceph_write() { ceph_read "$@"; }

  QUIET_TIMEOUT=2; QUIET_POLL=1
  cmd_plan_pause TEST-phase-a >/dev/null
  cmd_pause TEST-phase-a mock-fsid "$ACK" >/dev/null
  ( cmd_verify_restored TEST-phase-a ) >/dev/null 2>&1 \
    && die "selftest accepted paused state as restored"
  verify_paused_internal TEST-phase-a >/dev/null
  cmd_plan_restore TEST-phase-a >/dev/null
  cmd_restore TEST-phase-a >/dev/null
  cmd_verify_restored TEST-phase-a >/dev/null

  printf '\n' > "$td/flags"
  printf '1\n' > "$td/fail-nodeep"
  set +e
  ( cmd_pause ROLLBACK-phase-a mock-fsid "$ACK" ) >"$td/rollback.out" 2>&1
  rc=$?
  set -e
  (( rc != 0 )) || die "selftest expected injected pause failure"
  [[ -z $(current_flags) ]] || die "selftest rollback left a flag set"
  state=$(state_path ROLLBACK-phase-a)
  grep -q $'status\t.*\tpause-failed-rolled-back' "$state" \
    || die "selftest missing rollback status"

  printf '0\n' > "$td/fail-nodeep"
  cmd_pause DRIFT-phase-a mock-fsid "$ACK" >/dev/null
  printf '%s,noout\n' "$(<"$td/flags")" | normalize_flags_text > "$td/flags.new"
  mv "$td/flags.new" "$td/flags"
  set +e
  ( cmd_restore DRIFT-phase-a ) >"$td/drift.out" 2>&1
  rc=$?
  set -e
  (( rc != 0 )) || die "selftest restore ignored foreign flag drift"
  grep -q 'unexpected flag appeared' "$td/drift.out" || die "selftest missing drift reason"

  find "$td" -depth -delete
  printf 'U141D_SCRUB_CONTROL_SELFTEST: PASS\n'
}

usage() { sed -n '2,14p' "$0"; }

case "${1:-}" in
  inspect) shift; [[ $# -eq 1 ]] || die "inspect requires LEASE_ID"; validate_lease "$1"; cmd_inspect "$1" ;;
  plan-pause) shift; [[ $# -eq 1 ]] || die "plan-pause requires LEASE_ID"; validate_lease "$1"; cmd_plan_pause "$1" ;;
  pause) shift; [[ $# -eq 3 ]] || die "pause requires LEASE_ID FSID ACK"; validate_lease "$1"; cmd_pause "$1" "$2" "$3" ;;
  verify-paused) shift; [[ $# -eq 1 ]] || die "verify-paused requires LEASE_ID"; validate_lease "$1"; verify_paused_internal "$1" ;;
  plan-restore) shift; [[ $# -eq 1 ]] || die "plan-restore requires LEASE_ID"; validate_lease "$1"; cmd_plan_restore "$1" ;;
  restore) shift; [[ $# -eq 1 ]] || die "restore requires LEASE_ID"; validate_lease "$1"; cmd_restore "$1" ;;
  verify-restored) shift; [[ $# -eq 1 ]] || die "verify-restored requires LEASE_ID"; validate_lease "$1"; cmd_verify_restored "$1" ;;
  state-path) shift; [[ $# -eq 1 ]] || die "state-path requires LEASE_ID"; state_path "$1" ;;
  --self-test) self_test ;;
  *) usage; exit 1 ;;
esac
