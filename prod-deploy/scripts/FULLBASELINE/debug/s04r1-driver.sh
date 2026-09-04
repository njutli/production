#!/usr/bin/env bash
# State-driven orchestrator for 04-1/R1. Defaults to dry-run and fails closed.
#
# §8.4 scrub control: Phase V (W01-W04) uses <RUN_ID>-phase-a lease;
# Phase VI (R01-R08) uses <RUN_ID>-phase-b lease. Each round verifies
# paused state before fio; all failure paths restore scrub before
# evidence closure. u141d-scrub-control.sh is reused via R1_SCRUB_STATE_DIR.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
INVENTORY_SCRIPT="$SCRIPT_DIR/s04r1-inventory.sh"
MAP_ANALYZER="$SCRIPT_DIR/s04r1-map-analyze.py"
ANALYZER="$SCRIPT_DIR/s04r1-analyze.py"
SAMPLER="$SCRIPT_DIR/s04r1-osd-sampler.sh"
TASK="$ROOT/doc/perf-tasks/04-1-randread-pg-layout-feasibility-and-isolated-pool-ab.md"
TASK_R1B="$ROOT/doc/perf-tasks/04-1b-randread-explicit-primary-steering-ab.md"
REAL_OSD_FIXTURE="$ROOT/skills/fixtures/s04r1-osd-perf-quincy.json"
SCRUB_CONTROL="$SCRIPT_DIR/u141d-scrub-control.sh"

COMMAND=${1:-}
RUN_ID=${2:-}
DRY_RUN_ONLY=${DRY_RUN_ONLY:-1}
MOCK=${R1_MOCK:-0}
RESULT_ROOT=${R1_RESULT_ROOT:-/tmp/production/opencode-04-1-${RUN_ID}}
STATE="$RESULT_ROOT/state"
SCRUB_STATE_DIR="$STATE/scrub-leases"
POOL_A=juicefs-data
POOL_B="jfs-r1-${RUN_ID}"
AUTH_B="client.jfs-r1-${RUN_ID}"
KEYRING_B="/tmp/jfs-r1-${RUN_ID}.ceph.keyring"
MNT_A="/tmp/jfs-r1-${RUN_ID}-a"
MNT_B="/tmp/jfs-r1-${RUN_ID}-b"
META_A=${R1_META_A:-}
META_B=${R1_META_B:-}
JFS=${R1_JUICEFS_BIN:-}
SSH_USER=${R1_SSH_USER:-sunrise}
SSH_PASSWORD=${R1_SSH_PASSWORD:-}
OSD_HOSTS=${R1_OSD_HOSTS:-10.20.1.150,10.20.1.151,10.20.1.152}
R1_SCRUB_FSID=${R1_SCRUB_FSID:-}

ACTIVE_LEASE=""
LEASE_A="${RUN_ID}-phase-a"
LEASE_B="${RUN_ID}-phase-b"
ACTIVE_SAMPLER_LABEL=""
ACTIVE_SAMPLER_HOSTS=""

die() { printf 'E_R1_DRIVER\t%s\n' "$*" >&2; exit 42; }
log() { printf 'R1\t%s\t%s\n' "$(date -Is)" "$*"; }
marker() { printf '%s\t%s\n' "$1" "$(date +%s)" >"$STATE/$1"; }
need_marker() { [[ -f $STATE/$1 ]] || die "missing state marker $1"; }
no_marker() { [[ ! -e $STATE/$1 ]] || die "state marker already exists $1"; }
append_phase() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" "${3:-0}" >>"$RESULT_ROOT/phase-status.tsv"; }
incident() { printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >>"$RESULT_ROOT/incidents.tsv"; }

# --- scrub control helpers (§8.4) ---
# §2: Mock state semantics align with real controller:
#   pause refuses overwrite, restore appends (never rm), verify checks
#   last status line. §3: all calls logged to scrub_call_log.tsv.
# §5: R1_SCRUB_ACK required before any mutation (never hardcoded).

FIO_CALL_COUNT=0
scrub_log_call() {
  local action=$1 lease=$2 result=$3 detail=${4:-}
  mkdir -p "$STATE"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$action" "$lease" "$result" "$detail" \
    >> "$STATE/scrub_call_log.tsv"
}

check_health_json() {
  local file=$1 phase=$2 label=$3
  python3 - "$file" "$phase" "$label" <<'PY'
import json, sys
file, phase, label = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(file))
status = str(d.get("status", "MISSING"))
checks = d.get("checks", {})
if not isinstance(checks, dict):
    raise SystemExit(f"health checks is not an object ({phase} {label})")
if status == "HEALTH_OK" and not checks:
    sys.exit(0)
if status == "HEALTH_WARN" and set(checks.keys()) == {"OSDMAP_FLAGS"}:
    sys.exit(0)
raise SystemExit(f"health {phase} failed: status={status} checks={sorted(checks.keys())} label={label}")
PY
}

scrub_cmd() {
  if [[ $MOCK == 1 ]]; then return 0; fi
  U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" "$@"
}

scrub_verify_paused() {
  local lease=$1
  if [[ $MOCK == 1 ]]; then
    local state_file="$SCRUB_STATE_DIR/u141d-scrub-control-${lease}.tsv"
    [[ -f $state_file ]] \
      || { scrub_log_call verify_paused "$lease" fail "state file missing"; \
           die "scrub lease $lease not paused (mock: state file missing)"; }
    local status
    status=$(awk -F'\t' '$1=="status"{v=$3} END{print v}' "$state_file")
    [[ $status == mocked-paused || $status == paused ]] \
      || { scrub_log_call verify_paused "$lease" fail "status=$status"; \
           die "scrub lease $lease not paused (mock: status=${status:-missing})"; }
    scrub_log_call verify_paused "$lease" pass "status=$status"
    return 0
  fi
  scrub_cmd verify-paused "$lease" \
    || die "scrub verify-paused failed for lease=$lease (no fio allowed without valid pause)"
}

scrub_pause() {
  local lease=$1 fsid=$2
  mkdir -p "$SCRUB_STATE_DIR"
  # §5: Require explicit R1_SCRUB_ACK before any Ceph mutation
  [[ -n ${R1_SCRUB_ACK:-} ]] \
    || die "R1_SCRUB_ACK is required before scrub pause (lease=$lease)"
  [[ $R1_SCRUB_ACK == "I_ACK_GLOBAL_CEPH_SCRUB_PAUSE" ]] \
    || die "R1_SCRUB_ACK mismatch; expected I_ACK_GLOBAL_CEPH_SCRUB_PAUSE (lease=$lease)"
  if [[ $MOCK == 1 ]]; then
    local state_file="$SCRUB_STATE_DIR/u141d-scrub-control-${lease}.tsv"
    # §2: Refuse to overwrite existing state file
    [[ ! -e $state_file ]] \
      || { scrub_log_call pause "$lease" fail "state file exists"; \
           die "scrub state already exists for lease=$lease (mock)"; }
    printf 'meta\tlease\t%s\nmeta\tfsid\t%s\nstatus\t%s\tmocked-paused\n' "$lease" "$fsid" "$(date +%s)" \
      > "$state_file"
    scrub_log_call pause "$lease" pass "fsid=$fsid"
    return 0
  fi
  scrub_cmd pause "$lease" "$fsid" "$R1_SCRUB_ACK" \
    || die "scrub pause failed for lease=$lease"
  scrub_cmd verify-paused "$lease" \
    || die "scrub verify-paused failed for lease=$lease after pause"
}

scrub_restore() {
  local lease=$1
  if [[ $MOCK == 1 ]]; then
    local state_file="$SCRUB_STATE_DIR/u141d-scrub-control-${lease}.tsv"
    [[ -f $state_file ]] \
      || { scrub_log_call restore "$lease" fail "state file missing"; \
           die "scrub state file missing for restore (mock): lease=$lease"; }
    # §3: failpoint restore_fail
    if [[ ${R1_FAILPOINT:-} == restore_fail ]]; then
      scrub_log_call restore "$lease" fail "R1_FAILPOINT=restore_fail"
      die "scrub restore failed (mock failpoint): lease=$lease"
    fi
    # §2: Append restored line, never rm
    printf 'status\t%s\trestored\n' "$(date +%s)" >> "$state_file"
    scrub_log_call restore "$lease" pass
    scrub_verify_restored "$lease"
    return 0
  fi
  scrub_cmd plan-restore "$lease" 2>/dev/null || true
  scrub_cmd restore "$lease" \
    || die "scrub restore failed for lease=$lease (state-driven restore failure is a safety event)"
  scrub_cmd verify-restored "$lease" \
    || die "scrub verify-restored failed for lease=$lease"
}

scrub_verify_restored() {
  local lease=$1
  if [[ $MOCK == 1 ]]; then
    local state_file="$SCRUB_STATE_DIR/u141d-scrub-control-${lease}.tsv"
    [[ -f $state_file ]] \
      || { scrub_log_call verify_restored "$lease" fail "state file missing"; \
           die "scrub state file missing for verify-restored (mock): lease=$lease"; }
    local status
    status=$(awk -F'\t' '$1=="status"{v=$3} END{print v}' "$state_file")
    # §3: failpoint verify_restored_fail
    if [[ ${R1_FAILPOINT:-} == verify_restored_fail ]]; then
      scrub_log_call verify_restored "$lease" fail "R1_FAILPOINT=verify_restored_fail"
      die "scrub verify-restored failed (mock failpoint): lease=$lease status=$status"
    fi
    [[ $status == restored ]] \
      || { scrub_log_call verify_restored "$lease" fail "status=$status"; \
           die "scrub not restored (mock): lease=$lease status=${status:-missing}"; }
    scrub_log_call verify_restored "$lease" pass "status=$status"
    return 0
  fi
  scrub_cmd verify-restored "$lease" \
    || die "scrub verify-restored failed for lease=$lease"
}

scrub_ensure_restored() {
  local lease=$1
  local state_file="$SCRUB_STATE_DIR/u141d-scrub-control-${lease}.tsv"
  if [[ ! -f $state_file ]]; then return 0; fi
  local status
  status=$(awk -F'\t' '$1=="status"{v=$3} END{print v}' "$state_file" 2>/dev/null || true)
  if [[ $status == restored ]]; then return 0; fi
  scrub_restore "$lease"
}

scrub_current_fsid() {
  if [[ $MOCK == 1 ]]; then printf 'mock-fsid\n'; return 0; fi
  scrub_cmd inspect "$LEASE_A" 2>/dev/null | awk -F= '/^FSID=/{print $2}' || true
}

check_scope() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die 'RUN_ID must be YYYYMMDD-HHMMSS'
  [[ $RESULT_ROOT == "/tmp/production/opencode-04-1-$RUN_ID" ]] || die 'RESULT_ROOT outside exact scope'
  [[ $POOL_B == "jfs-r1-$RUN_ID" && $MNT_A == "/tmp/jfs-r1-$RUN_ID-a" && $MNT_B == "/tmp/jfs-r1-$RUN_ID-b" ]] || die 'scope derivation failed'
  [[ $KEYRING_B == "/tmp/jfs-r1-${RUN_ID}.ceph.keyring" ]] || die 'keyring scope derivation failed'
  [[ ! -L $RESULT_ROOT && ! -L $MNT_A && ! -L $MNT_B && ! -L $KEYRING_B ]] || die 'symlink scope rejected'
}

init_root() {
  mkdir -p "$RESULT_ROOT" "$STATE"
  [[ -f $RESULT_ROOT/phase-status.tsv ]] || printf 'phase\tstate\tepoch\trc\n' >"$RESULT_ROOT/phase-status.tsv"
  [[ -f $RESULT_ROOT/incidents.tsv ]] || printf 'epoch\tseverity\taction\tdetail\n' >"$RESULT_ROOT/incidents.tsv"
}

check_methodology_ack() {
  local ack="$RESULT_ROOT/methodology-ack.tsv"
  [[ -f $ack ]] || die 'missing methodology-ack.tsv'
  python3 - "$ack" "$ROOT" <<'PY'
import hashlib,sys
from pathlib import Path
ack=Path(sys.argv[1]); root=Path(sys.argv[2])
required=['skills/EVIDENCE-INTEGRITY-SKILL.md','skills/fixtures/known-defect-classes.tsv',
 'skills/TESTING-GUIDE.md','skills/test-commands-reference.md',
 'skills/LONG-RUNNING-TEST-SKILL.md','doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md']
rows={}
for line in ack.read_text().splitlines():
 if not line or line.startswith('path\t'): continue
 p,sha,epoch,identity=line.split('\t')
 rows[p]=(sha,epoch,identity)
for rel in required:
 if rel not in rows: raise SystemExit('missing methodology ACK: '+rel)
 sha=hashlib.sha256((root/rel).read_bytes()).hexdigest()
 if rows[rel][0]!=sha or not rows[rel][1].isdigit() or not rows[rel][2]:
  raise SystemExit('invalid methodology ACK: '+rel)
PY
}

require_real_contract() {
  [[ $DRY_RUN_ONLY == 0 ]] || die 'real state mutation/run disabled by DRY_RUN_ONLY=1'
  [[ -n $JFS && -x $JFS ]] || die 'R1_JUICEFS_BIN missing/not executable'
  [[ -n $META_A && $META_A == tikv://*/* ]] || die 'R1_META_A missing/invalid'
  [[ -n $META_B && $META_B == tikv://*"/jfs-r1-$RUN_ID-b" ]] || die 'R1_META_B missing/not scoped'
  [[ -n $SSH_PASSWORD ]] || die 'R1_SSH_PASSWORD must be supplied through environment'
  command -v sshpass >/dev/null; command -v ssh >/dev/null; command -v scp >/dev/null
}

verify_frozen_invariants() {
  local tag=$1 dir="$STATE/fingerprint-$1"
  mkdir -p "$dir"
  sudo ceph osd pool ls detail --format json >"$dir/pools.json"
  sudo ceph osd dump --format json >"$dir/osd-dump.json"
  sudo ceph osd getcrushmap -o "$dir/crush-map.bin" >/dev/null
  "$JFS" status "$META_A" >"$dir/volume-a-status.json"
  if [[ -f /etc/ceph/ceph.conf ]]; then sha256sum /etc/ceph/ceph.conf | awk '{print $1}' >"$dir/system-ceph-conf.sha256"; else printf 'ABSENT\n' >"$dir/system-ceph-conf.sha256"; fi
  python3 - "$RESULT_ROOT/inventory/pool-a.json" "$dir/pools.json" \
    "$RESULT_ROOT/inventory/osd-dump.json" "$dir/osd-dump.json" \
    "$RESULT_ROOT/inventory/crush-map.bin" "$dir/crush-map.bin" \
    "$RESULT_ROOT/inventory/runtime-inventory.txt" "$dir/system-ceph-conf.sha256" <<'PY'
import hashlib,json,sys
from pathlib import Path
pa,pools,od0,od1,cr0,cr1,runtime,conf=map(Path,sys.argv[1:])
expected=json.load(open(pa)); current=json.load(open(pools))
if isinstance(current,dict): current=current.get('pools',current.get('pool_list',[]))
rows=[p for p in current if p.get('pool_name',p.get('name'))=='juicefs-data']
assert len(rows)==1
keys=('pool','pool_name','type','size','min_size','crush_rule','object_hash','pg_num',
      'pg_placement_num','erasure_code_profile','fast_read','flags','flags_names')
for k in keys:
 if k in expected or k in rows[0]: assert expected.get(k)==rows[0].get(k), (k,expected.get(k),rows[0].get(k))
old=json.load(open(od0)); new=json.load(open(od1))
def up_from(d):
 return {int(x['osd']):int(x.get('up_from',-1)) for x in d.get('osds',[]) if int(x.get('osd',-1))>=0}
assert up_from(old)==up_from(new), (up_from(old),up_from(new))
assert hashlib.sha256(cr0.read_bytes()).digest()==hashlib.sha256(cr1.read_bytes()).digest()
want='ABSENT'
for line in runtime.read_text().splitlines():
 if line.startswith('system_ceph_conf_sha256\t'): want=line.split('\t',1)[1]
assert conf.read_text().strip()==want, (want,conf.read_text().strip())
PY
  if [[ -d $STATE/fingerprint-pre-create ]]; then
    python3 - "$STATE/fingerprint-pre-create/volume-a-status.json" "$dir/volume-a-status.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])).get('Setting',{}); b=json.load(open(sys.argv[2])).get('Setting',{})
for k in ('UUID','Name','Storage','Bucket','BlockSize'):
 if k in a or k in b: assert a.get(k)==b.get(k), (k,a.get(k),b.get(k))
PY
  fi
}

ssh_cmd() {
  local host=$1; shift
  SSHPASS=$SSH_PASSWORD sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=10 "$SSH_USER@$host" "$@" </dev/null
}
scp_to() {
  local src=$1 host=$2 dst=$3
  SSHPASS=$SSH_PASSWORD sshpass -e scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$src" "$SSH_USER@$host:$dst"
}
scp_from_dir() {
  local host=$1 src=$2 dst=$3
  mkdir -p "$dst"
  SSHPASS=$SSH_PASSWORD sshpass -e scp -qr -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@$host:$src/." "$dst/"
}

round_sampler_start() {
  local label=$1 host remote_script remote_out started=""
  local result_root="${R1_SAMPLER_RESULT_ROOT:-$RESULT_ROOT}"
  [[ -z $ACTIVE_SAMPLER_LABEL ]] || {
    scrub_log_call sampler_start "$label" fail "already-active=$ACTIVE_SAMPLER_LABEL"
    return 1
  }
  ACTIVE_SAMPLER_LABEL=$label
  ACTIVE_SAMPLER_HOSTS=""
  if [[ $MOCK == 1 ]]; then
    ACTIVE_SAMPLER_HOSTS=mock
    scrub_log_call sampler_start "$label" pass mock
    return 0
  fi
  IFS=',' read -ra hosts <<<"$OSD_HOSTS"
  for host in "${hosts[@]}"; do
    remote_script="/tmp/s04r1-osd-sampler-${RUN_ID}.sh"
    remote_out="${result_root}/sampler-$label"
    if ! scp_to "$SAMPLER" "$host" "$remote_script"; then
      scrub_log_call sampler_start "$label" fail "scp host=$host started=${started:-none}"
      return 1
    fi
    # Once the remote start command is attempted, treat the host as potentially
    # active even if SSH loses the reply; the EXIT trap must try the exact stop path.
    started="${started:+$started,}$host"
    ACTIVE_SAMPLER_HOSTS=$started
    if ! ssh_cmd "$host" "test ! -e '$remote_out'; mkdir -p '$remote_out'; chmod 700 '$remote_script'; nohup setsid bash -c 'set +e; env DRY_RUN_ONLY=0 bash \"$remote_script\" \"$RUN_ID\" \"$remote_out\" 420 >\"$remote_out/console.txt\" 2>&1; rc=\$?; printf \"%s\\n\" \"\$rc\" >\"$remote_out/process.rc\"' </dev/null >/dev/null 2>&1 &"; then
      scrub_log_call sampler_start "$label" fail "ssh host=$host started=${started:-none}"
      return 1
    fi
  done
  scrub_log_call sampler_start "$label" pass "hosts=$ACTIVE_SAMPLER_HOSTS"
}

round_sampler_close() {
  local label=$1 out=$2 host remote_out ok process_rc rc=0
  local result_root="${R1_SAMPLER_RESULT_ROOT:-$RESULT_ROOT}"
  [[ $ACTIVE_SAMPLER_LABEL == "$label" ]] || {
    scrub_log_call sampler_close "$label" fail "active=${ACTIVE_SAMPLER_LABEL:-none}"
    return 1
  }
  if [[ $MOCK == 1 ]]; then
    if [[ ${R1_FAILPOINT:-} == sampler_close_fail ]]; then
      scrub_log_call sampler_close "$label" fail "R1_FAILPOINT=sampler_close_fail"
      return 1
    fi
    scrub_log_call sampler_close "$label" pass mock
    ACTIVE_SAMPLER_LABEL=""
    ACTIVE_SAMPLER_HOSTS=""
    return 0
  fi

  IFS=',' read -ra hosts <<<"$ACTIVE_SAMPLER_HOSTS"
  for host in "${hosts[@]}"; do
    [[ -n $host ]] || continue
    remote_out="${result_root}/sampler-$label"
    ssh_cmd "$host" "touch '$remote_out/STOP_REQUEST'" || rc=1
  done
  for host in "${hosts[@]}"; do
    [[ -n $host ]] || continue
    remote_out="${result_root}/sampler-$label"
    ok=0
    for _ in $(seq 1 60); do
      if ssh_cmd "$host" "test -f '$remote_out/SAMPLER_PASS' -a -f '$remote_out/process.rc'"; then
        ok=1
        break
      fi
      sleep 1
    done
    if (( ok != 1 )); then rc=1; continue; fi
    process_rc=$(ssh_cmd "$host" "cat '$remote_out/process.rc'" 2>/dev/null) || { rc=1; continue; }
    [[ $process_rc == 0 ]] || rc=1
    scp_from_dir "$host" "$remote_out" "$out/osd-${host##*.}" || rc=1
  done
  if (( rc == 0 )); then
    scrub_log_call sampler_close "$label" pass "hosts=$ACTIVE_SAMPLER_HOSTS"
    ACTIVE_SAMPLER_LABEL=""
    ACTIVE_SAMPLER_HOSTS=""
  else
    scrub_log_call sampler_close "$label" fail "hosts=${ACTIVE_SAMPLER_HOSTS:-none}"
  fi
  return "$rc"
}

cmd_init() {
  check_scope; [[ ! -e $RESULT_ROOT ]] || die 'RUN root already exists'
  init_root
  append_phase init START
  # v2 Gate signs only the inventory + empty-pool feasibility ladder.  The
  # existing data/performance helpers are deliberately excluded until a
  # selected structural layout justifies a separate Gate.
  sha256sum "$TASK" "$INVENTORY_SCRIPT" "$MAP_ANALYZER" "$0" >"$RESULT_ROOT/input-sha256.txt"
  marker INIT_COMPLETE; append_phase init PASS
  log "INIT_PASS root=$RESULT_ROOT"
}

cmd_phase_i() {
  check_scope; init_root; need_marker INIT_COMPLETE; no_marker PHASE_I_COMPLETE; check_methodology_ack
  append_phase phase-i START
  R1_RESULT_ROOT="$RESULT_ROOT" DRY_RUN_ONLY="$DRY_RUN_ONLY" R1_FIXTURE_DIR="${R1_FIXTURE_DIR:-}" \
    R1_READONLY_ACK="${R1_READONLY_ACK:-}" bash "$INVENTORY_SCRIPT" "$RUN_ID"
  marker PHASE_I_COMPLETE; append_phase phase-i PASS; log PHASE_I_PASS
}

# v2 registration/PG-ladder state machine.  Data/performance helpers later in
# this file remain non-dispatchable until a post-SELECTED Gate is signed.
contract_value() { awk -F '\t' -v k="$1" '$1==k{v=$2} END{print v}' "$STATE/contract.tsv"; }

require_real_ceph() {
  [[ $DRY_RUN_ONLY == 0 ]] || die 'real Ceph mutation disabled by DRY_RUN_ONLY=1'
  command -v sudo >/dev/null || die 'sudo missing'
  command -v ceph >/dev/null || die 'ceph missing'
}

verify_empty_b_and_reference() {
  local pool_file=$1 df_file=$2 osd_file=$3 crush_dump_file=$4 expected_id=$5 expected_pg=$6
  python3 - "$RESULT_ROOT/inventory/pool-detail.json" "$pool_file" "$df_file" \
    "$RESULT_ROOT/inventory/osd-dump.json" "$osd_file" \
    "$RESULT_ROOT/inventory/crush-dump.json" "$crush_dump_file" \
    "$POOL_A" "$POOL_B" "$expected_id" "$expected_pg" <<'PY'
import json,sys
old,new,df,osd0,osd1,crush0,crush1,ref,cand,expected_id,expected_pg=sys.argv[1:]
def rows(d):
    if isinstance(d,list): return d
    return d.get('pools',d.get('pool_list',[]))
a=[x for x in rows(json.load(open(old))) if x.get('pool_name',x.get('name'))==ref]
b=[x for x in rows(json.load(open(new))) if x.get('pool_name',x.get('name'))==ref]
assert len(a)==len(b)==1
for key in ('pool','pool_id','pg_num','pg_placement_num','type','size','min_size','crush_rule','fast_read','flags','flags_names'):
    if key in a[0] or key in b[0]: assert a[0].get(key)==b[0].get(key),(key,a[0],b[0])
c=[x for x in rows(json.load(open(new))) if x.get('pool_name',x.get('name'))==cand]
assert len(c)==1
bid=int(c[0].get('pool',c[0].get('pool_id',-1))); assert bid==int(expected_id),(bid,expected_id)
assert int(c[0].get('pg_num',-1))==int(expected_pg)
assert int(c[0].get('pg_placement_num',-1))==int(expected_pg)
assert c[0].get('pg_autoscale_mode')=='off'
assert int(c[0].get('type',-1))==3 and c[0].get('erasure_code_profile')=='ec-prod'
assert c[0].get('erasure_code_profile')==a[0].get('erasure_code_profile')
assert c[0].get('fast_read') is True
assert 'ec_overwrites' in str(c[0].get('flags_names',''))
apps=c[0].get('application_metadata',{})
assert 'juicefs' in apps
drows=rows(json.load(open(df)))
dpool=[x for x in drows if x.get('name',x.get('pool_name'))==cand]
assert len(dpool)==1
did=int(dpool[0].get('id',dpool[0].get('pool',dpool[0].get('pool_id',-1))))
assert did==int(expected_id),(did,expected_id)
stats=dpool[0].get('stats',dpool[0]); assert float(stats.get('objects',0))==0
before=json.load(open(osd0)); after=json.load(open(osd1))
def up_from(d):
    return {int(x['osd']):int(x.get('up_from',-1)) for x in d.get('osds',[]) if int(x.get('osd',-1))>=0}
assert up_from(before)==up_from(after),(up_from(before),up_from(after))
# Creating an EC pool may add one pool-named rule even when its placement
# semantics equal the reference rule.  Preserve every old rule and all
# non-rule CRUSH content; allow only that one semantically equivalent rule.
cr0=json.load(open(crush0)); cr1=json.load(open(crush1))
rules0={int(x['rule_id']):x for x in cr0.get('rules',[])}
rules1={int(x['rule_id']):x for x in cr1.get('rules',[])}
arule=int(a[0].get('crush_rule',-1)); brule=int(c[0].get('crush_rule',-1))
assert arule in rules0 and arule in rules1 and brule in rules1,(arule,brule,rules0,rules1)
for rid,row in rules0.items(): assert rules1.get(rid)==row,(rid,row,rules1.get(rid))
extra=set(rules1)-set(rules0); assert extra==({brule} if brule!=arule else set()),extra
def semantic(rule): return {k:v for k,v in rule.items() if k not in ('rule_id','rule_name','ruleset')}
assert semantic(rules1[brule])==semantic(rules1[arule]),(rules1[arule],rules1[brule])
base0={k:v for k,v in cr0.items() if k!='rules'}
base1={k:v for k,v in cr1.items() if k!='rules'}
assert base0==base1
PY
}

archive_osdmap_identity() {
  local dump_file=$1 osdmap_file=$2 crush_file=$3 pgmap_file=$4 output=$5
  local epoch
  epoch=$(python3 - "$dump_file" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); e=d.get('epoch')
assert isinstance(e,int) and e>0
print(e)
PY
)
  {
    printf 'osdmap_epoch\t%s\n' "$epoch"
    sha256sum "$osdmap_file" "$crush_file" "$pgmap_file"
  } >"$output"
}

require_same_osdmap_epoch() {
  local before=$1 after=$2
  python3 - "$before" "$after" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])).get('epoch')
b=json.load(open(sys.argv[2])).get('epoch')
assert isinstance(a,int) and a>0 and a==b,(a,b)
print(a)
PY
}

verify_pre_register() {
  local pool_file=$1 health_file=$2 osd_file=$3 crush_file=$4 expected_id=$5
  python3 - "$RESULT_ROOT/inventory/pool-detail.json" "$pool_file" "$health_file" \
    "$RESULT_ROOT/inventory/osd-dump.json" "$osd_file" \
    "$RESULT_ROOT/inventory/crush-map.bin" "$crush_file" "$POOL_A" "$POOL_B" "$expected_id" <<'PY'
import hashlib,json,sys
old,new,health,osd0,osd1,crush0,crush1,ref,cand,expected=sys.argv[1:]
def rows(d):
    return d if isinstance(d,list) else d.get('pools',d.get('pool_list',[]))
a=[x for x in rows(json.load(open(old))) if x.get('pool_name',x.get('name'))==ref]
now=rows(json.load(open(new)))
b=[x for x in now if x.get('pool_name',x.get('name'))==ref]
assert len(a)==len(b)==1
assert not [x for x in now if x.get('pool_name',x.get('name'))==cand]
for key in ('pool','pool_id','pg_num','pg_placement_num','type','size','min_size','crush_rule','fast_read','flags','flags_names'):
    if key in a[0] or key in b[0]: assert a[0].get(key)==b[0].get(key),(key,a[0],b[0])
h=json.load(open(health)); assert h.get('status',h.get('health',{}).get('status'))=='HEALTH_OK'
before=json.load(open(osd0)); after=json.load(open(osd1))
def up_from(d):
    return {int(x['osd']):int(x.get('up_from',-1)) for x in d.get('osds',[]) if int(x.get('osd',-1))>=0}
assert up_from(before)==up_from(after),(up_from(before),up_from(after))
assert hashlib.sha256(open(crush0,'rb').read()).digest()==hashlib.sha256(open(crush1,'rb').read()).digest()
ids=[int(x.get('pool',x.get('pool_id'))) for x in after.get('pools',[])]
pool_max=int(after.get('pool_max',max(ids)))
assert max(max(ids),pool_max)+1==int(expected),(ids,pool_max,expected)
PY
}

registered_map_for_current() {
  local pg=${1:-32}
  if (( pg == 32 )); then printf '%s\n' "$RESULT_ROOT/mapping/registered-map.json"; else
    printf '%s\n' "$RESULT_ROOT/mapping/registered-map-${pg}.json"
  fi
}

cmd_plan_register_empty() {
  check_scope; init_root; need_marker PHASE_I_COMPLETE; no_marker PLAN_REGISTER_EMPTY_COMPLETE
  mkdir -p "$RESULT_ROOT/plans" "$RESULT_ROOT/mapping"
  local pool_id
  pool_id=$(python3 - "$RESULT_ROOT/inventory/osd-dump.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=[int(x.get('pool',x.get('pool_id'))) for x in d.get('pools',[])]
if not ids: raise SystemExit('no pool ids in frozen osd dump')
candidate=max(ids)+1; explicit=d.get('pool_max')
if explicit is not None and int(explicit)>max(ids): candidate=int(explicit)+1
print(candidate)
PY
)
  printf 'run_id\t%s\npool_a\t%s\npool_b\t%s\nexpected_pool_id\t%s\ninitial_pg_num\t32\ncurrent_pg_num\t32\n' \
    "$RUN_ID" "$POOL_A" "$POOL_B" "$pool_id" >"$STATE/contract.tsv"
  cat >"$RESULT_ROOT/plans/plan-register-empty.txt" <<EOF
# Exactly one registration; no auth, volume, mount, layout, data or delete.
sudo ceph osd pool create $POOL_B 32 32 erasure ec-prod
sudo ceph osd pool set $POOL_B pg_autoscale_mode off
sudo ceph osd pool set $POOL_B allow_ec_overwrites true
sudo ceph osd pool set $POOL_B fast_read true
sudo ceph osd pool application enable $POOL_B juicefs
EOF
  cp "$RESULT_ROOT/plans/plan-register-empty.txt" "$RESULT_ROOT/plans/sudo-writes-register-empty.txt"
  sha256sum "$RESULT_ROOT/plans/"*.txt >"$RESULT_ROOT/plans/sha256.txt"
  marker PLAN_REGISTER_EMPTY_COMPLETE; append_phase plan-register-empty PASS
  log "PLAN_REGISTER_EMPTY_PASS pool_id=$pool_id pg_num=32"
}

cmd_register_empty() {
  check_scope; init_root; need_marker PLAN_REGISTER_EMPTY_COMPLETE; no_marker POOL_REGISTERED
  local expected_id; expected_id=$(contract_value expected_pool_id)
  if [[ $MOCK == 1 ]]; then
    [[ $DRY_RUN_ONLY == 1 ]] || die 'mock register requires dry-run'
    mkdir -p "$RESULT_ROOT/mapping"
    python3 - "$RESULT_ROOT/mapping/registered-map.json" "$expected_id" <<'PY'
import json,sys
out,pid=sys.argv[1:]; hist=[6,6,5,6,5,4]; rows=[]; n=0
for osd,count in enumerate(hist):
  for _ in range(count):
    rows.append({'pgid':f'{pid}.{n:x}','primary':osd,'up':[0,1,2,3,4,5],'acting':[0,1,2,3,4,5]}); n+=1
json.dump({'pool_id':int(pid),'pg_num':32,'pg_stats':rows,'source':'mock-register'},open(out,'w'),indent=2)
PY
  else
    require_real_ceph
    [[ ${R1_REGISTER_EMPTY_ACK:-} == "I_ACK_R1_REGISTER_EMPTY_${RUN_ID}" ]] || die 'missing exact register-empty ACK'
    [[ $(contract_value initial_pg_num) == 32 ]] || die 'initial PG contract is not 32'
    sudo ceph osd pool ls detail --format json >"$STATE/pools-pre-register.json"
    sudo ceph health --format json >"$STATE/health-pre-register.json"
    sudo ceph osd dump --format json >"$STATE/osd-dump-pre-register.json"
    sudo ceph osd getcrushmap -o "$STATE/crush-pre-register.bin" >/dev/null
    verify_pre_register "$STATE/pools-pre-register.json" "$STATE/health-pre-register.json" \
      "$STATE/osd-dump-pre-register.json" "$STATE/crush-pre-register.bin" "$expected_id"
    sudo ceph osd pool create "$POOL_B" 32 32 erasure ec-prod
    sudo ceph osd pool set "$POOL_B" pg_autoscale_mode off
    sudo ceph osd pool set "$POOL_B" allow_ec_overwrites true
    sudo ceph osd pool set "$POOL_B" fast_read true
    sudo ceph osd pool application enable "$POOL_B" juicefs
    sudo ceph osd pool ls detail --format json >"$STATE/pools-after-register.json"
    local actual_id
    actual_id=$(python3 - "$STATE/pools-after-register.json" "$POOL_B" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); name=sys.argv[2]; rows=d if isinstance(d,list) else d.get('pools',[])
x=[p for p in rows if p.get('pool_name',p.get('name'))==name]
assert len(x)==1; print(x[0].get('pool',x[0].get('pool_id')))
PY
)
    [[ $actual_id == "$expected_id" ]] || die 'R1_REGISTERED_POOL_ID_MISMATCH'
    mkdir -p "$RESULT_ROOT/mapping"
    local ready=0
    for _ in $(seq 1 120); do
      sudo ceph health --format json >"$STATE/health-registered.json"
      sudo ceph pg dump pgs_brief --format json >"$STATE/pg-registered.json"
      if python3 - "$STATE/health-registered.json" "$STATE/pg-registered.json" "$actual_id" <<'PY'
import json,sys
h=json.load(open(sys.argv[1])); d=json.load(open(sys.argv[2])); pid=sys.argv[3]
rows=d.get('pg_stats',d.get('pg_map',{}).get('pg_stats',[])); rows=[r for r in rows if str(r.get('pgid','')).split('.',1)[0]==pid]
assert h.get('status',h.get('health',{}).get('status'))=='HEALTH_OK'
assert len(rows)==32 and all(str(r.get('state',''))=='active+clean' for r in rows)
PY
      then ready=1; break; fi
      sleep 5
    done
    (( ready == 1 )) || die 'registered pool did not become HEALTH_OK/32 active+clean in 600s'
    sudo ceph osd dump --format json >"$STATE/osd-dump-freeze-before-register.json"
    sudo ceph pg dump pgs_brief --format json >"$STATE/pg-registered.json"
    sudo ceph osd dump --format json >"$STATE/osd-dump-after-register.json"
    local map_epoch
    map_epoch=$(require_same_osdmap_epoch "$STATE/osd-dump-freeze-before-register.json" \
      "$STATE/osd-dump-after-register.json")
    sudo ceph df detail --format json >"$STATE/df-after-register.json"
    sudo ceph osd getcrushmap -o "$STATE/crush-after-register.bin" >/dev/null
    sudo ceph osd crush dump --format json >"$STATE/crush-dump-after-register.json"
    verify_empty_b_and_reference "$STATE/pools-after-register.json" "$STATE/df-after-register.json" \
      "$STATE/osd-dump-after-register.json" "$STATE/crush-dump-after-register.json" "$expected_id" 32
    python3 - "$STATE/pg-registered.json" "$actual_id" "$RESULT_ROOT/mapping/registered-map.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; rows=d.get('pg_stats',d.get('pg_map',{}).get('pg_stats',[]))
rows=[r for r in rows if str(r.get('pgid','')).split('.',1)[0]==pid]
assert len(rows)==32
json.dump({'pool_id':int(pid),'pg_stats':rows},open(sys.argv[3],'w'),indent=2,sort_keys=True)
PY
    sudo ceph osd getmap "$map_epoch" -o "$RESULT_ROOT/mapping/osdmap-registered.bin" >/dev/null
    archive_osdmap_identity "$STATE/osd-dump-after-register.json" \
      "$RESULT_ROOT/mapping/osdmap-registered.bin" "$STATE/crush-after-register.bin" \
      "$RESULT_ROOT/mapping/registered-map.json" "$RESULT_ROOT/mapping/osdmap-registered.meta.tsv"
  fi
  sha256sum "$RESULT_ROOT/mapping/registered-map.json" >"$RESULT_ROOT/mapping/registered-map.sha256"
  [[ ! -e "$RESULT_ROOT/state/POOL_REGISTERED" ]] || die 'pool registration marker already exists'
  marker POOL_REGISTERED; marker MAP_FROZEN; append_phase register-empty PASS
  log "REGISTER_EMPTY_PASS pool_id=$expected_id pg_num=32"
}

# Recovery-only path for an already-created, still-empty candidate pool when
# register-empty completed its five Ceph mutations but failed before writing
# local state markers.  It never creates or changes a pool.
cmd_adopt_registered_empty() {
  check_scope; init_root; need_marker PLAN_REGISTER_EMPTY_COMPLETE; no_marker POOL_REGISTERED
  local expected_id; expected_id=$(contract_value expected_pool_id)
  [[ ${R1_ADOPT_REGISTERED_ACK:-} == "I_ACK_R1_ADOPT_REGISTERED_EMPTY_${RUN_ID}" ]] ||
    die 'missing exact adopt-registered-empty ACK'
  mkdir -p "$RESULT_ROOT/mapping"
  if [[ $MOCK == 1 ]]; then
    [[ $DRY_RUN_ONLY == 1 ]] || die 'mock adopt requires dry-run'
    [[ -n ${R1_MOCK_REGISTERED_MAP:-} && -f $R1_MOCK_REGISTERED_MAP && ! -L $R1_MOCK_REGISTERED_MAP ]] ||
      die 'mock registered map missing/invalid'
    cp "$R1_MOCK_REGISTERED_MAP" "$RESULT_ROOT/mapping/registered-map.json"
  else
    require_real_ceph
    sudo ceph osd pool ls detail --format json >"$STATE/pools-adopt-register.json"
    local actual_id
    actual_id=$(python3 - "$STATE/pools-adopt-register.json" "$POOL_B" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); name=sys.argv[2]; rows=d if isinstance(d,list) else d.get('pools',[])
x=[p for p in rows if p.get('pool_name',p.get('name'))==name]
assert len(x)==1; print(x[0].get('pool',x[0].get('pool_id')))
PY
)
    [[ $actual_id == "$expected_id" ]] || die 'R1_ADOPTED_POOL_ID_MISMATCH'
    local ready=0
    for _ in $(seq 1 120); do
      sudo ceph health --format json >"$STATE/health-adopt-register.json"
      sudo ceph pg dump pgs_brief --format json >"$STATE/pg-adopt-register.json"
      if python3 - "$STATE/health-adopt-register.json" "$STATE/pg-adopt-register.json" "$actual_id" <<'PY'
import json,sys
h=json.load(open(sys.argv[1])); d=json.load(open(sys.argv[2])); pid=sys.argv[3]
rows=d.get('pg_stats',d.get('pg_map',{}).get('pg_stats',[])); rows=[r for r in rows if str(r.get('pgid','')).split('.',1)[0]==pid]
assert h.get('status',h.get('health',{}).get('status'))=='HEALTH_OK'
assert len(rows)==32 and all(str(r.get('state',''))=='active+clean' for r in rows)
PY
      then ready=1; break; fi
      sleep 5
    done
    (( ready == 1 )) || die 'adopted pool did not become HEALTH_OK/32 active+clean in 600s'
    sudo ceph osd dump --format json >"$STATE/osd-dump-freeze-before-adopt.json"
    sudo ceph pg dump pgs_brief --format json >"$STATE/pg-adopt-register.json"
    sudo ceph osd dump --format json >"$STATE/osd-dump-after-adopt.json"
    local map_epoch
    map_epoch=$(require_same_osdmap_epoch "$STATE/osd-dump-freeze-before-adopt.json" \
      "$STATE/osd-dump-after-adopt.json")
    sudo ceph df detail --format json >"$STATE/df-after-adopt.json"
    sudo ceph osd getcrushmap -o "$STATE/crush-after-adopt.bin" >/dev/null
    sudo ceph osd crush dump --format json >"$STATE/crush-dump-after-adopt.json"
    verify_empty_b_and_reference "$STATE/pools-adopt-register.json" "$STATE/df-after-adopt.json" \
      "$STATE/osd-dump-after-adopt.json" "$STATE/crush-dump-after-adopt.json" "$expected_id" 32
    python3 - "$STATE/pg-adopt-register.json" "$actual_id" "$RESULT_ROOT/mapping/registered-map.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; rows=d.get('pg_stats',d.get('pg_map',{}).get('pg_stats',[]))
rows=[r for r in rows if str(r.get('pgid','')).split('.',1)[0]==pid]
assert len(rows)==32
json.dump({'pool_id':int(pid),'pg_stats':rows},open(sys.argv[3],'w'),indent=2,sort_keys=True)
PY
    sudo ceph osd getmap "$map_epoch" -o "$RESULT_ROOT/mapping/osdmap-registered.bin" >/dev/null
    archive_osdmap_identity "$STATE/osd-dump-after-adopt.json" \
      "$RESULT_ROOT/mapping/osdmap-registered.bin" "$STATE/crush-after-adopt.bin" \
      "$RESULT_ROOT/mapping/registered-map.json" "$RESULT_ROOT/mapping/osdmap-registered.meta.tsv"
  fi
  sha256sum "$RESULT_ROOT/mapping/registered-map.json" >"$RESULT_ROOT/mapping/registered-map.sha256"
  marker POOL_REGISTERED; marker MAP_FROZEN; append_phase adopt-registered-empty PASS
  log "ADOPT_REGISTERED_EMPTY_PASS pool_id=$expected_id pg_num=32"
}

cmd_evaluate_layout() {
  check_scope; init_root; need_marker MAP_FROZEN
  local pg=${1:-$(contract_value current_pg_num)} map; map=$(registered_map_for_current "$pg")
  [[ $pg == "$(contract_value current_pg_num)" ]] || die 'requested PG is not current actual PG'
  no_marker "EVALUATE_${pg}_COMPLETE"
  [[ -f $map && ! -L $map ]] || die "registered map missing for pg=$pg"
  python3 "$MAP_ANALYZER" --inventory "$RESULT_ROOT/inventory" \
    --registered-map "$map" --actual-only --output "$RESULT_ROOT/mapping/actual-${pg}.json" \
    | tee "$RESULT_ROOT/mapping/evaluate-${pg}.console.txt"
  local verdict; verdict=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$RESULT_ROOT/mapping/actual-${pg}.json")
  printf '%s\n' "$verdict" >"$STATE/EVALUATE_${pg}_VERDICT"
  marker "EVALUATE_${pg}_COMPLETE"
  if [[ $verdict == SELECTED ]]; then
    cp "$map" "$RESULT_ROOT/mapping/selected-map.json"
    printf 'selected_pg_num\t%s\n' "$pg" >>"$STATE/contract.tsv"
    rm -f "$STATE/NEXT_PG_NUM"
    printf '%s\n' R1_ACTUAL_LAYOUT_SELECTED >"$STATE/FEASIBILITY_VERDICT"
    marker PG_SELECTION_COMPLETE; marker FEASIBILITY_COMPLETE
    append_phase evaluate-layout SELECTED; log "EVALUATE_LAYOUT_SELECTED pg=$pg"
  elif [[ $verdict == NEXT_REQUIRED ]]; then
    (( pg < 128 )) || die 'unexpected continuation at pg=128'
    printf '%s\n' "$((pg*2))" >"$STATE/NEXT_PG_NUM"
    append_phase evaluate-layout NEXT_REQUIRED; log "EVALUATE_LAYOUT_NEXT_REQUIRED current_pg=$pg next_pg=$((pg*2))"
  else
    [[ $verdict == BLOCKED ]] || die "unexpected evaluate verdict=$verdict"
    printf '%s\n' R1_FEASIBILITY_BLOCKED >"$STATE/FEASIBILITY_VERDICT"
    marker FEASIBILITY_COMPLETE; append_phase evaluate-layout BLOCKED; log "EVALUATE_LAYOUT_BLOCKED pg=$pg"
  fi
}

cmd_plan_adjust() {
  check_scope; init_root; need_marker MAP_FROZEN; [[ -f "$STATE/NEXT_PG_NUM" ]] || die 'NEXT_REQUIRED marker missing'
  [[ ! -f "$STATE/PG_SELECTION_COMPLETE" ]] || die 'selected layout is final; further PG adjustment forbidden'
  local cur=${1:-$(contract_value current_pg_num)} next=${2:-$(cat "$STATE/NEXT_PG_NUM" 2>/dev/null || true)}
  [[ $cur == 32 || $cur == 64 ]] || die 'adjust source must be 32 or 64'
  [[ $next == $((cur*2)) && $next -le 128 ]] || die 'adjust target must be next monotonic PG value'
  [[ $cur == "$(contract_value current_pg_num)" ]] || die 'plan source differs from current actual PG'
  [[ $next == "$(cat "$STATE/NEXT_PG_NUM")" ]] || die 'plan target differs from evaluated next PG'
  no_marker "PLAN_ADJUST_${next}_COMPLETE"; mkdir -p "$RESULT_ROOT/plans"
  cat >"$RESULT_ROOT/plans/plan-adjust-${next}.txt" <<EOF
# Same empty pool only; no pool create/delete and no auth/volume/data.
sudo ceph osd pool set $POOL_B pg_num $next
# wait until pool-detail reports pg_num=$next before changing placement count
sudo ceph osd pool set $POOL_B pgp_num $next
EOF
  sha256sum "$RESULT_ROOT/plans/plan-adjust-${next}.txt" >"$RESULT_ROOT/plans/plan-adjust-${next}.sha256"
  marker "PLAN_ADJUST_${next}_COMPLETE"; append_phase plan-adjust PASS; log "PLAN_ADJUST_PASS from=$cur to=$next"
}

cmd_adjust_verify() {
  check_scope; init_root; local cur=${1:-$(contract_value current_pg_num)} next=${2:-$(cat "$STATE/NEXT_PG_NUM" 2>/dev/null || true)}
  need_marker "PLAN_ADJUST_${next}_COMPLETE"; no_marker "ADJUST_VERIFY_${next}_COMPLETE"
  [[ $cur == "$(contract_value current_pg_num)" ]] || die 'adjust source differs from current actual PG'
  [[ $next == "$(cat "$STATE/NEXT_PG_NUM")" ]] || die 'adjust target differs from evaluated next PG'
  [[ $next == $((cur*2)) && $next -le 128 ]] || die 'adjust verify target must be next monotonic PG value'
  if [[ $MOCK == 1 ]]; then
    [[ $DRY_RUN_ONLY == 1 ]] || die 'mock adjust requires dry-run'
    [[ -n ${R1_MOCK_LAYOUT_DIR:-} && -f "$R1_MOCK_LAYOUT_DIR/layout-${next}.json" ]] || die 'mock actual layout fixture missing'
    cp "$R1_MOCK_LAYOUT_DIR/layout-${next}.json" "$RESULT_ROOT/mapping/registered-map-${next}.json"
  else
    require_real_ceph
    [[ ${R1_ADJUST_ACK:-} == "I_ACK_R1_ADJUST_${RUN_ID}_${next}" ]] || die 'missing exact adjust ACK'
    sudo ceph osd pool ls detail --format json >"$STATE/pools-pre-adjust-${next}.json"
    sudo ceph df detail --format json >"$STATE/df-pre-adjust-${next}.json"
    sudo ceph osd dump --format json >"$STATE/osd-dump-pre-adjust-${next}.json"
    sudo ceph osd getcrushmap -o "$STATE/crush-pre-adjust-${next}.bin" >/dev/null
    sudo ceph osd crush dump --format json >"$STATE/crush-dump-pre-adjust-${next}.json"
    verify_empty_b_and_reference "$STATE/pools-pre-adjust-${next}.json" "$STATE/df-pre-adjust-${next}.json" \
      "$STATE/osd-dump-pre-adjust-${next}.json" "$STATE/crush-dump-pre-adjust-${next}.json" \
      "$(contract_value expected_pool_id)" "$cur"
    sudo ceph osd pool set "$POOL_B" pg_num "$next"
    local pgnum_ready=0
    for _ in $(seq 1 120); do
      sudo ceph osd pool ls detail --format json >"$STATE/pools-pgnum-${next}.json"
      if python3 - "$STATE/pools-pgnum-${next}.json" "$POOL_B" "$next" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); rows=d if isinstance(d,list) else d.get('pools',[])
x=[p for p in rows if p.get('pool_name',p.get('name'))==sys.argv[2]]
assert len(x)==1 and int(x[0].get('pg_num',-1))==int(sys.argv[3])
PY
      then pgnum_ready=1; break; fi
      sleep 5
    done
    (( pgnum_ready == 1 )) || die "pool pg_num did not reach $next in 600s; pgp_num not changed"
    sudo ceph osd pool set "$POOL_B" pgp_num "$next"
    local actual_id; actual_id=$(contract_value expected_pool_id)
    local ready=0
    for _ in $(seq 1 240); do
      sudo ceph health --format json >"$STATE/health-adjust-${next}.json"
      sudo ceph pg dump pgs_brief --format json >"$STATE/pg-adjust-${next}.json"
      if python3 - "$STATE/health-adjust-${next}.json" "$STATE/pg-adjust-${next}.json" "$actual_id" "$next" <<'PY'
import json,sys
h=json.load(open(sys.argv[1])); d=json.load(open(sys.argv[2])); pid=sys.argv[3]; n=int(sys.argv[4])
rows=d.get('pg_stats',d.get('pg_map',{}).get('pg_stats',[])); rows=[r for r in rows if str(r.get('pgid','')).split('.',1)[0]==pid]
assert h.get('status',h.get('health',{}).get('status'))=='HEALTH_OK'
assert len(rows)==n and all(str(r.get('state',''))=='active+clean' for r in rows)
PY
      then ready=1; break; fi
      sleep 5
    done
    (( ready == 1 )) || die "adjusted pool did not become HEALTH_OK/$next active+clean in 1200s"
    sudo ceph osd dump --format json >"$STATE/osd-dump-freeze-before-adjust-${next}.json"
    sudo ceph pg dump pgs_brief --format json >"$STATE/pg-adjust-${next}.json"
    sudo ceph osd dump --format json >"$STATE/osd-dump-after-adjust-${next}.json"
    local map_epoch
    map_epoch=$(require_same_osdmap_epoch "$STATE/osd-dump-freeze-before-adjust-${next}.json" \
      "$STATE/osd-dump-after-adjust-${next}.json")
    sudo ceph osd pool ls detail --format json >"$STATE/pools-after-adjust-${next}.json"
    sudo ceph df detail --format json >"$STATE/df-after-adjust-${next}.json"
    sudo ceph osd getcrushmap -o "$STATE/crush-after-adjust-${next}.bin" >/dev/null
    sudo ceph osd crush dump --format json >"$STATE/crush-dump-after-adjust-${next}.json"
    verify_empty_b_and_reference "$STATE/pools-after-adjust-${next}.json" "$STATE/df-after-adjust-${next}.json" \
      "$STATE/osd-dump-after-adjust-${next}.json" "$STATE/crush-dump-after-adjust-${next}.json" "$actual_id" "$next"
    python3 - "$STATE/pg-adjust-${next}.json" "$actual_id" "$RESULT_ROOT/mapping/registered-map-${next}.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; rows=d.get('pg_stats',d.get('pg_map',{}).get('pg_stats',[])); rows=[r for r in rows if str(r.get('pgid','')).split('.',1)[0]==pid]
assert len(rows)==int(sys.argv[3].split('registered-map-')[-1].split('.')[0])
json.dump({'pool_id':int(pid),'pg_stats':rows},open(sys.argv[3],'w'),indent=2,sort_keys=True)
PY
    sudo ceph osd getmap "$map_epoch" -o "$RESULT_ROOT/mapping/osdmap-registered-${next}.bin" >/dev/null
    archive_osdmap_identity "$STATE/osd-dump-after-adjust-${next}.json" \
      "$RESULT_ROOT/mapping/osdmap-registered-${next}.bin" "$STATE/crush-after-adjust-${next}.bin" \
      "$RESULT_ROOT/mapping/registered-map-${next}.json" \
      "$RESULT_ROOT/mapping/osdmap-registered-${next}.meta.tsv"
  fi
  sha256sum "$(registered_map_for_current "$next")" >"$RESULT_ROOT/mapping/registered-map-${next}.sha256"
  printf 'current_pg_num\t%s\n' "$next" >>"$STATE/contract.tsv"
  rm -f "$STATE/NEXT_PG_NUM"
  marker "ADJUST_VERIFY_${next}_COMPLETE"; append_phase adjust-verify PASS; log "ADJUST_VERIFY_PASS pg=$next"
}

mount_identity() {
  local meta=$1 mnt=$2 arm=$3
  "$JFS" status "$meta" >"$STATE/status-$arm.json"
  python3 - "$STATE/status-$arm.json" "$arm" >"$STATE/uuid-$arm.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get('Setting',{})
u=s.get('UUID'); n=s.get('Name')
if not u: raise SystemExit('Setting.UUID missing')
print('arm\tuuid\tname'); print(sys.argv[2],u,n,sep='\t')
PY
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$STATE/findmnt-$arm.txt"
  python3 - "$mnt" "$JFS" >"$STATE/mount-processes-$arm.tsv" <<'PY'
import hashlib,os,sys
mnt=sys.argv[1]; expected=os.path.realpath(sys.argv[2]); rows=[]
for p in os.listdir('/proc'):
 if not p.isdigit(): continue
 try:
  raw=open(f'/proc/{p}/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace')
  exe=os.path.realpath(f'/proc/{p}/exe')
  stat=open(f'/proc/{p}/stat').read().split(); ppid=int(stat[3]); start=int(stat[21])
 except (OSError,ValueError): continue
 if mnt in raw and exe==expected: rows.append((int(p),ppid,start,exe,raw))
if not rows: raise SystemExit('no exact mount process candidates')
print('pid\tppid\tstarttime\texe\tcmdline')
for r in sorted(rows): print(*r,sep='\t')
PY
}

graceful_umount() {
  local meta=$1 mnt=$2
  "$JFS" umount "$mnt"
  for _ in $(seq 1 180); do mountpoint -q "$mnt" || return 0; sleep 1; done
  die "graceful umount timeout: $mnt"
}

cmd_phase_v_layout() {
  check_scope; init_root; need_marker PHASE_IV_COMPLETE; no_marker PHASE_V_LAYOUT_COMPLETE
  if [[ $MOCK == 1 ]]; then
    [[ $DRY_RUN_ONLY == 1 ]] || die 'mock layout requires dry-run'
    mkdir -p "$RESULT_ROOT/layout"
    python3 - "$RESULT_ROOT/layout/files.tsv" <<'PY'
import sys
with open(sys.argv[1],'w') as f:
 for i in range(128): f.write(f'read_test.{i}.0\t1073741824\t{1000+i}\t1.0\n')
PY
    marker PHASE_V_LAYOUT_COMPLETE; append_phase phase-v-layout PASS; log PHASE_V_LAYOUT_MOCK_PASS
    return 0
  fi
  require_real_contract
  [[ ${R1_LAYOUT_ACK:-} == "I_ACK_R1_LAYOUT_${RUN_ID}" ]] || die 'missing exact layout ACK'
  [[ -f "$RESULT_ROOT/mapping/selected-map.json" ]] || die 'selected structural map missing'
  [[ ! -e $KEYRING_B ]] || die 'scoped keyring path already exists'
  # Auth/volume are deliberately deferred until the PG ladder has passed.
  sudo ceph auth get-or-create "$AUTH_B" mon 'profile rados' osd "allow rwx pool=$POOL_B" -o "$KEYRING_B"
  sudo chown "$(id -u):$(id -g)" "$KEYRING_B"; chmod 600 "$KEYRING_B"
  sha256sum "$KEYRING_B" >"$STATE/keyring-b.sha256"
  mkdir -p "$MNT_A" "$MNT_B" "$RESULT_ROOT/layout/bw"
  CEPH_ARGS="--keyring $KEYRING_B" "$JFS" format --storage ceph --bucket "ceph://$POOL_B" \
    --access-key ceph --secret-key "$AUTH_B" --block-size 256K --trash-days 0 "$META_B" "$POOL_B"
  CEPH_ARGS="--keyring $KEYRING_B" "$JFS" mount -d --max-fuse-io 256K --max-uploads 150 --cache-size 0 "$META_B" "$MNT_B"
  mkdir -p "$MNT_B/test_dir"
  fio --directory="$MNT_B/test_dir" --name=read_test --filesize=1G --size=1G --bs=4M --rw=write \
    --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 \
    --write_bw_log="$RESULT_ROOT/layout/bw/layout" --log_avg_msec=1000 >"$RESULT_ROOT/layout/fio.txt"
  find "$MNT_B/test_dir" -maxdepth 1 -type f -name 'read_test.*.0' -printf '%f\t%s\t%i\t%T@\n' | sort >"$RESULT_ROOT/layout/files.tsv"
  python3 - "$RESULT_ROOT/layout/files.tsv" <<'PY'
import sys
r=[x.split('\t') for x in open(sys.argv[1]) if x.strip()]
assert len(r)==128, len(r); assert all(int(x[1])==1073741824 for x in r)
PY
  graceful_umount "$META_B" "$MNT_B"
  CEPH_ARGS="--keyring $KEYRING_B" "$JFS" mount -d --max-fuse-io 256K --max-uploads 150 --cache-size 0 -o ro "$META_B" "$MNT_B"
  "$JFS" mount -d --max-fuse-io 256K --max-uploads 150 --cache-size 0 -o ro "$META_A" "$MNT_A"
  mount_identity "$META_A" "$MNT_A" A; mount_identity "$META_B" "$MNT_B" B
  marker PHASE_V_LAYOUT_COMPLETE; append_phase phase-v-layout PASS; log PHASE_V_LAYOUT_PASS
}

drop_caches_all() {
  if [[ ${R1_SKIP_LOCAL_DROP_CACHES:-0} != 1 ]]; then
    sync; printf '3\n' | sudo tee /proc/sys/vm/drop_caches >/dev/null
  else
    log 'LOCAL_DROP_CACHES_SKIPPED: protect 157 co-located services'
  fi
  IFS=',' read -ra hosts <<<"$OSD_HOSTS"
  for host in "${hosts[@]}"; do ssh_cmd "$host" "sync; printf '3\\n' | sudo tee /proc/sys/vm/drop_caches >/dev/null"; done
  sleep 20
}

run_round() {
  local label=$1 arm=$2 mode=$3
  local mnt=$MNT_A
  [[ $arm == B ]] && mnt=$MNT_B
  local out="$RESULT_ROOT/$mode/$label"
  [[ ! -e $out ]] || die "round output exists: $label"
  mkdir -p "$out/bw"

  # §8.4: verify scrub paused before any fio
  [[ -n $ACTIVE_LEASE ]] || die "no active scrub lease; refuse fio for $label"

  # §3: failpoint lease_lose — delete state file before first fio verify
  if [[ $MOCK == 1 && ${R1_FAILPOINT:-} == lease_lose ]]; then
    rm -f "$SCRUB_STATE_DIR/u141d-scrub-control-${ACTIVE_LEASE}.tsv"
  fi

  scrub_verify_paused "$ACTIVE_LEASE"

  if [[ $MOCK == 1 ]]; then
    # Match the real ordering: strict pre-health → sampler start → fio.
    printf '{"status":"HEALTH_OK","checks":{}}\n' >"$out/health-pre.json"
    check_health_json "$out/health-pre.json" pre "$label"
    round_sampler_start "$label" \
      || { incident ERROR "round-$label" 'mock sampler start failed'; die "sampler start failed label=$label"; }

    # §3: track fio call count (increment when fio would be called)
    : $(( ++FIO_CALL_COUNT ))
    printf '%s\n' "$FIO_CALL_COUNT" > "$STATE/fio_call_count"

    # §3: failpoint round_fail_<LABEL> — fio returns rc=1
    if [[ ${R1_FAILPOINT:-} == round_fail_$label ]]; then
      incident ERROR "round-$label" "fio failed (mock failpoint rc=1)"
      die "fio failed label=$label rc=1 (mock failpoint)"
    fi

    # Generate mock fio/bw data
    printf 'mock round %s\n' "$label" >"$out/fio.txt"
    printf 'READ: bw=6000MiB/s\nrun=180000-180000msec\n' >>"$out/fio.txt"
    mkdir -p "$out/bw"
    for j in $(seq 1 128); do : > "$out/bw/read_test_bw.${j}.log"; done
    printf '%s\n' "$(date +%s%N)" >"$out/fio-start-ns.txt"
    printf '%s\n' "$(date +%s%N)" >"$out/fio-end-ns.txt"

    round_sampler_close "$label" "$out" \
      || { incident ERROR "round-$label" 'mock sampler close failed'; die "sampler close failed label=$label"; }

    # §1: Generate mock analysis JSON so phase commands can call analyzers
    if [[ $mode == warmup ]]; then
      local mock_iop
      case "$label" in
        W01) mock_iop=1.13;; W02) mock_iop=1.02;; W03) mock_iop=1.03;; W04) mock_iop=1.12;; *) mock_iop=1.05;;
      esac
      printf '{"osd":{"I_op":%s}}\n' "$mock_iop" >"$out/osd-analysis.json"
    else
      local mock_bw
      case "$label" in
        R01) mock_bw=5510;; R02) mock_bw=6255;; R03) mock_bw=6270;; R04) mock_bw=5500;;
        R05) mock_bw=6240;; R06) mock_bw=5520;; R07) mock_bw=5515;; R08) mock_bw=6260;;
        *) mock_bw=5800;;
      esac
      printf '{"bandwidth":{"mean_MiBs":%s},"osd":{"I_op":1.03}}\n' "$mock_bw" >"$out/round-analysis.json"
    fi

    # §4: JSON health fixtures (post)
    printf '{"status":"HEALTH_OK","checks":{}}\n' >"$out/health-post.json"
    check_health_json "$out/health-post.json" post "$label"

    # §3: failpoint post_verify_fail — corrupt state before post-fio verify
    if [[ ${R1_FAILPOINT:-} == post_verify_fail ]]; then
      printf 'status\t%s\tcorrupted\n' "$(date +%s)" >> "$SCRUB_STATE_DIR/u141d-scrub-control-${ACTIVE_LEASE}.tsv"
    fi

    # §8.4: verify still paused after fio (§1: mock goes through real control flow)
    scrub_verify_paused "$ACTIVE_LEASE"
    return 0
  fi

  # §4: Health JSON strict parsing (pre-fio)
  sudo ceph health detail --format json >"$out/health-pre.json"
  check_health_json "$out/health-pre.json" pre "$label"
  drop_caches_all
  round_sampler_start "$label" \
    || { incident ERROR "round-$label" 'sampler start failed'; die "sampler start failed label=$label"; }
  sleep 5
  printf '%s\n' "$(date +%s%N)" >"$out/fio-start-ns.txt"
  set +e
  fio --directory="$mnt/test_dir" --name=read_test --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
    --allow_file_create=0 --readonly --group_reporting --time_based --runtime=180 \
    --write_bw_log="$out/bw/read_test" --log_avg_msec=1000 >"$out/fio.txt" 2>"$out/fio.stderr"
  fio_rc=$?
  set -e
  printf '%s\n' "$(date +%s%N)" >"$out/fio-end-ns.txt"
  if (( fio_rc != 0 )); then
    incident ERROR "round-$label" "fio failed rc=$fio_rc; sampler closure delegated to EXIT trap"
    die "fio failed label=$label rc=$fio_rc"
  fi
  sleep 5
  round_sampler_close "$label" "$out" \
    || { incident ERROR "round-$label" 'sampler close/copy failed'; die "sampler close failed label=$label"; }
  if [[ $mode == warmup ]]; then
    python3 "$ANALYZER" osd --round-dir "$out" --output "$out/osd-analysis.json" >"$out/analyzer-console.txt"
  else
    python3 "$ANALYZER" round --round-dir "$out" --output "$out/round-analysis.json" >"$out/analyzer-console.txt"
  fi
  # §4: Health JSON strict parsing (post-fio)
  sudo ceph health detail --format json >"$out/health-post.json"
  check_health_json "$out/health-post.json" post "$label"

  # §8.4: verify still paused after fio
  scrub_verify_paused "$ACTIVE_LEASE"
}

cmd_phase_v_warmup() {
  check_scope; init_root; need_marker PHASE_V_LAYOUT_COMPLETE; no_marker PHASE_V_COMPLETE
  if [[ $MOCK == 1 ]]; then
    # §1: Mock goes through real control flow: pause → verify → rounds → restore
    mkdir -p "$SCRUB_STATE_DIR"
    FIO_CALL_COUNT=0; printf '0\n' > "$STATE/fio_call_count"
    scrub_pause "$LEASE_A" "mock-fsid"
    ACTIVE_LEASE="$LEASE_A"
    mkdir -p "$RESULT_ROOT/warmup"
    # §1: Call run_round instead of directly generating JSON
    run_round W01 A warmup; run_round W02 B warmup; run_round W03 B warmup; run_round W04 A warmup
    python3 "$ANALYZER" manipulation --inputs "$RESULT_ROOT"/warmup/W0{1,2,3,4}/osd-analysis.json \
      --output "$RESULT_ROOT/warmup/manipulation.json" >"$RESULT_ROOT/warmup/manipulation-console.txt"
    verdict=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$RESULT_ROOT/warmup/manipulation.json")
    printf '%s\n' "$verdict" >"$STATE/MANIPULATION_VERDICT"
    # §8.4: restore phase-a lease before returning to caller (no scrub pause during human review)
    scrub_restore "$LEASE_A"
    ACTIVE_LEASE=""
    marker PHASE_V_COMPLETE; append_phase phase-v PASS; log "PHASE_V_MOCK_PASS verdict=$verdict"
    return 0
  fi
  require_real_contract
  [[ ${R1_WARMUP_ACK:-} == "I_ACK_R1_WARMUP_${RUN_ID}" ]] || die 'missing warmup ACK'
  # §8.4: pause phase-a lease for W01-W04
  local fsid=${R1_SCRUB_FSID:-$(sudo ceph fsid 2>/dev/null | tr -d '[:space:]')}
  [[ -n $fsid ]] || die 'cannot determine Ceph FSID for scrub pause'
  scrub_pause "$LEASE_A" "$fsid"
  ACTIVE_LEASE="$LEASE_A"
  mkdir -p "$RESULT_ROOT/warmup"
  run_round W01 A warmup; run_round W02 B warmup; run_round W03 B warmup; run_round W04 A warmup
  python3 "$ANALYZER" manipulation --inputs "$RESULT_ROOT"/warmup/W0{1,2,3,4}/osd-analysis.json \
    --output "$RESULT_ROOT/warmup/manipulation.json" | tee "$RESULT_ROOT/warmup/manipulation-console.txt"
  verdict=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$RESULT_ROOT/warmup/manipulation.json")
  printf '%s\n' "$verdict" >"$STATE/MANIPULATION_VERDICT"
  # §8.4: restore phase-a lease before returning to caller (no scrub pause during human review)
  scrub_restore "$LEASE_A"
  ACTIVE_LEASE=""
  marker PHASE_V_COMPLETE; append_phase phase-v PASS; log "PHASE_V_PASS verdict=$verdict"
}

cmd_phase_vi() {
  check_scope; init_root; need_marker PHASE_V_COMPLETE; no_marker PHASE_VI_COMPLETE
  [[ $(<"$STATE/MANIPULATION_VERDICT") == R1_MANIPULATION_PASS ]] || die 'manipulation did not pass'
  if [[ $MOCK == 1 ]]; then
    # §1: Mock goes through real control flow: pause → verify → rounds → restore
    mkdir -p "$SCRUB_STATE_DIR"
    FIO_CALL_COUNT=0; printf '0\n' > "$STATE/fio_call_count"
    scrub_pause "$LEASE_B" "mock-fsid"
    ACTIVE_LEASE="$LEASE_B"
    mkdir -p "$RESULT_ROOT/formal"
    # §1: Call run_round instead of directly generating JSON
    arms=(A B B A B A A B)
    for i in $(seq 1 8); do printf -v label 'R%02d' "$i"; run_round "$label" "${arms[i-1]}" formal; done
    scrub_restore "$LEASE_B"
    ACTIVE_LEASE=""
    marker PHASE_VI_COMPLETE; append_phase phase-vi PASS; log PHASE_VI_MOCK_PASS
    return 0
  fi
  require_real_contract
  [[ ${R1_FORMAL_ACK:-} == "I_ACK_R1_FORMAL_${RUN_ID}" ]] || die 'missing formal ACK'
  # §8.4: pause phase-b lease for R01-R08 (distinct from phase-a)
  local fsid=${R1_SCRUB_FSID:-$(sudo ceph fsid 2>/dev/null | tr -d '[:space:]')}
  [[ -n $fsid ]] || die 'cannot determine Ceph FSID for scrub pause'
  scrub_pause "$LEASE_B" "$fsid"
  ACTIVE_LEASE="$LEASE_B"
  mkdir -p "$RESULT_ROOT/formal"
  arms=(A B B A B A A B)
  for i in $(seq 1 8); do printf -v label 'R%02d' "$i"; run_round "$label" "${arms[i-1]}" formal; done
  # §8.4: restore phase-b lease
  scrub_restore "$LEASE_B"
  ACTIVE_LEASE=""
  marker PHASE_VI_COMPLETE; append_phase phase-vi PASS; log PHASE_VI_PASS
}

cmd_close() {
  check_scope; init_root; need_marker PHASE_V_COMPLETE; no_marker CLOSURE_COMPLETE
  if [[ $MOCK == 1 ]]; then
    (
      cd "$RESULT_ROOT"
      find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum >manifest.sha256
    )
    marker CLOSURE_COMPLETE; append_phase closure PASS; log CLOSURE_MOCK_PASS_PRESERVE
    return 0
  fi
  require_real_contract
  mount_identity "$META_A" "$MNT_A" A-close; mount_identity "$META_B" "$MNT_B" B-close
  graceful_umount "$META_B" "$MNT_B"; graceful_umount "$META_A" "$MNT_A"
  sudo ceph status --format json >"$RESULT_ROOT/ceph-status-final.json"
  sudo ceph osd pool ls detail --format json >"$RESULT_ROOT/pools-final.json"
  marker CLOSURE_COMPLETE; append_phase closure PASS
  (
    cd "$RESULT_ROOT"
    find . -type f ! -name manifest.sha256 ! -name archive.tar.zst ! -name archive.sha256 -print0 |
      sort -z | xargs -0 sha256sum >manifest.sha256
  )
  command -v zstd >/dev/null || die 'zstd required for archive'
  archive="/tmp/production/opencode-04-1-${RUN_ID}.archive.tar.zst"
  [[ ! -e $archive && ! -e $archive.sha256 ]] || die 'archive output already exists'
  tar -C /tmp/production -cf - "opencode-04-1-${RUN_ID}" | zstd -T0 -q -o "$archive"
  sha256sum "$archive" >"$archive.sha256"
  printf 'ALL_DONE\t%s\tarchive=%s\n' "$(date +%s)" "$archive" >"$RESULT_ROOT/ALL_DONE"
  log CLOSURE_PASS_PRESERVE
}

cmd_inspect() {
  check_scope; init_root
  printf 'run_id\t%s\nroot\t%s\npool_b\t%s\nmnt_a\t%s\nmnt_b\t%s\n' "$RUN_ID" "$RESULT_ROOT" "$POOL_B" "$MNT_A" "$MNT_B"
  find "$STATE" -maxdepth 1 -type f -printf '%f\n' | sort
}

check_scope

# §8.4: trap ensures scrub restore before any evidence closure on abnormal exit
# §3: must NOT swallow restore failure with || true — record the failure
r1_scrub_trap() {
  local sampler_rc=0 restore_rc=0 sampler_mode=formal
  if [[ -n $ACTIVE_SAMPLER_LABEL ]]; then
    [[ $ACTIVE_SAMPLER_LABEL == W* ]] && sampler_mode=warmup
    incident FATAL sampler_trap "active sampler $ACTIVE_SAMPLER_LABEL at exit; attempting exact close"
    round_sampler_close "$ACTIVE_SAMPLER_LABEL" "$RESULT_ROOT/$sampler_mode/$ACTIVE_SAMPLER_LABEL" \
      >/dev/null 2>&1 || sampler_rc=$?
    if [[ $sampler_rc -ne 0 ]]; then
      incident FATAL sampler_trap "sampler close FAILED rc=$sampler_rc label=$ACTIVE_SAMPLER_LABEL"
      printf 'TRAP_SAMPLER_CLOSE_FAILED\t%s\t%s\n' "$(date -Is)" "$ACTIVE_SAMPLER_LABEL" >&2
    fi
  fi
  if [[ -n $ACTIVE_LEASE ]]; then
    incident FATAL scrub_trap "active lease $ACTIVE_LEASE at exit; attempting restore"
    ( scrub_restore "$ACTIVE_LEASE" ) >/dev/null 2>&1 || restore_rc=$?
    if [[ $restore_rc -ne 0 ]]; then
      incident FATAL scrub_trap "restore FAILED rc=$restore_rc for lease=$ACTIVE_LEASE"
      printf 'TRAP_RESTORE_FAILED\t%s\t%s\n' "$(date -Is)" "$ACTIVE_LEASE" >&2
    fi
    ACTIVE_LEASE=""
  fi
}

# --- R1B: explicit primary steering (04-1b) ---
R1B_RESULT_ROOT=${R1B_RESULT_ROOT:-/tmp/production/opencode-04-1b-${RUN_ID}}
R1B_STATE="$R1B_RESULT_ROOT/state"
POOL_B_R1B="jfs-r1b-${RUN_ID}"
R1B_TARGET="0:10,1:11,2:11,3:10,4:11,5:11"

r1b_marker() { printf '%s\t%s\n' "$1" "$(date +%s)" >"$R1B_STATE/$1"; }
r1b_need() { [[ -f $R1B_STATE/$1 ]] || die "missing R1B marker $1"; }
r1b_no() { [[ ! -e $R1B_STATE/$1 ]] || die "R1B marker already exists $1"; }
r1b_append() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" "${3:-0}" >>"$R1B_RESULT_ROOT/phase-status.tsv"; }

cmd_r1b_init() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die 'RUN_ID must be YYYYMMDD-HHMMSS'
  [[ $R1B_RESULT_ROOT == "/tmp/production/opencode-04-1b-$RUN_ID" ]] || die 'R1B RESULT_ROOT outside scope'
  [[ ! -e $R1B_RESULT_ROOT ]] || die 'R1B RUN root already exists'
  r1b_no R1B_INIT_COMPLETE
  mkdir -p "$R1B_RESULT_ROOT" "$R1B_STATE"
  [[ -f $R1B_RESULT_ROOT/phase-status.tsv ]] || printf 'phase\tstate\tepoch\trc\n' >"$R1B_RESULT_ROOT/phase-status.tsv"
  [[ -f $R1B_RESULT_ROOT/incidents.tsv ]] || printf 'epoch\tseverity\taction\tdetail\n' >"$R1B_RESULT_ROOT/incidents.tsv"
  sha256sum "$TASK_R1B" "$INVENTORY_SCRIPT" "$MAP_ANALYZER" "$0" >"$R1B_RESULT_ROOT/input-sha256.txt"
  r1b_marker R1B_INIT_COMPLETE; r1b_append r1b-init PASS
  log "R1B_INIT_PASS root=$R1B_RESULT_ROOT"
}

cmd_r1b_phase_i() {
  r1b_need R1B_INIT_COMPLETE; r1b_no R1B_PHASE_I_COMPLETE
  local ack="$R1B_RESULT_ROOT/methodology-ack.tsv"
  [[ -f $ack ]] || die 'missing R1B methodology-ack.tsv'
  python3 - "$ack" "$ROOT" <<'PY'
import hashlib,sys
from pathlib import Path
ack=Path(sys.argv[1]); root=Path(sys.argv[2])
required=['skills/EVIDENCE-INTEGRITY-SKILL.md','skills/fixtures/known-defect-classes.tsv',
 'skills/TESTING-GUIDE.md','skills/test-commands-reference.md',
 'skills/LONG-RUNNING-TEST-SKILL.md','doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md']
rows={}
for line in ack.read_text().splitlines():
 if not line or line.startswith('path\t'): continue
 p,sha,epoch,identity=line.split('\t')
 rows[p]=(sha,epoch,identity)
for rel in required:
 if rel not in rows: raise SystemExit('missing methodology ACK: '+rel)
 sha=hashlib.sha256((root/rel).read_bytes()).hexdigest()
 if rows[rel][0]!=sha or not rows[rel][1].isdigit() or not rows[rel][2]:
  raise SystemExit('invalid methodology ACK: '+rel)
PY
  r1b_append r1b-phase-i START
  if [[ $MOCK == 1 ]]; then
    local inv="${R1_FIXTURE_DIR:-}"
    [[ -d $inv ]] || die 'mock requires R1_FIXTURE_DIR for inventory'
    mkdir -p "$R1B_RESULT_ROOT/inventory"
    cp -- "$inv"/* "$R1B_RESULT_ROOT/inventory/"
  else
    require_real_ceph
    [[ ${R1_READONLY_ACK:-} == I_ACK_R1_READONLY_INVENTORY ]] || die 'missing exact read-only ACK'
    R1_RESULT_ROOT="$R1B_RESULT_ROOT" DRY_RUN_ONLY=0 R1_READONLY_ACK=I_ACK_R1_READONLY_INVENTORY \
      bash "$INVENTORY_SCRIPT" "$RUN_ID"
    sudo ceph balancer status >"$R1B_RESULT_ROOT/inventory/balancer-status.txt" 2>/dev/null || true
    sudo ceph config get mon mon_allow_pool_delete >"$R1B_RESULT_ROOT/inventory/mon-allow-pool-delete.txt" 2>/dev/null || true
  fi
  r1b_marker R1B_PHASE_I_COMPLETE; r1b_append r1b-phase-i PASS
  log "R1B_PHASE_I_PASS"
}

cmd_r1b_create_pool() {
  r1b_need R1B_PLAN_CREATE_POOL_COMPLETE; r1b_no R1B_POOL_CREATED
  local plan_file="$R1B_RESULT_ROOT/plans/plan-create-steered-pool.txt"
  local plan_sha="$R1B_RESULT_ROOT/plans/plan-create-steered-pool.sha256"
  [[ -f $plan_file && ! -L $plan_file ]] || die 'plan file missing'
  [[ -f $plan_sha ]] || die 'plan SHA missing'
  ( cd "$R1B_RESULT_ROOT/plans" && sha256sum -c plan-create-steered-pool.sha256 >/dev/null 2>&1 ) || die 'plan SHA mismatch'
  if [[ $MOCK == 1 ]]; then
    [[ -n ${R1_MOCK_REGISTERED_MAP:-} && -f $R1_MOCK_REGISTERED_MAP ]] || die 'mock requires R1_MOCK_REGISTERED_MAP'
    mkdir -p "$R1B_STATE" "$R1B_RESULT_ROOT/mapping"
    cp -- "$R1_MOCK_REGISTERED_MAP" "$R1B_STATE/registered-map.json"
    r1b_marker R1B_BALANCER_LEASE_OWNED
    r1b_marker R1B_POOL_CREATED; r1b_append r1b-create-pool PASS
    log "R1B_CREATE_POOL_PASS (mock) pool=$POOL_B_R1B pg_num=64"
    return 0
  fi
  require_real_ceph
  [[ ${R1B_CREATE_POOL_ACK:-} == "I_ACK_R1B_CREATE_POOL_${RUN_ID}" ]] || die 'missing exact R1B create-pool ACK'
  # Pre-execution checks
  sudo ceph health --format json >"$R1B_STATE/health-pre-create.json"
  python3 - "$R1B_STATE/health-pre-create.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1]))
assert h.get("status")=="HEALTH_OK", f"health not OK: {h.get('status')}"
PY
  sudo ceph osd stat >"$R1B_STATE/osd-stat-pre-create.txt"
  grep -q '6 up' "$R1B_STATE/osd-stat-pre-create.txt" || die 'not 6 OSD up'
  ! sudo ceph health detail 2>/dev/null | grep -iE 'recovery|backfill|degraded' || die 'recovery/backfill active'
  ! sudo ceph osd pool ls | grep -q "$POOL_B_R1B" || die 'B pool already exists'
  # Check no existing upmap/temp for this pool
  sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-pre-create.json"
  python3 - "$R1B_STATE/osd-dump-pre-create.json" "$POOL_B_R1B" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pool_name=sys.argv[2]
# B must not exist
pools=d.get("pools",[])
assert not any(p.get("pool_name")==pool_name for p in pools), f"pool {pool_name} exists"
# Check no existing upmap/pg_temp for non-existent pool (always true)
PY
  # Balancer control: save state, turn off
  sudo ceph balancer status >"$R1B_STATE/balancer-pre-create.txt" 2>/dev/null || true
  local balancer_active
  balancer_active=$(python3 -c "import json;print(json.load(open('$R1B_STATE/balancer-pre-create.txt')).get('active',True))" 2>/dev/null || echo "True")
  if [[ $balancer_active == "True" ]]; then
    sudo ceph balancer off
    sleep 2
    local balancer_after
    balancer_after=$(sudo ceph balancer status 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('active',True))" 2>/dev/null || echo "True")
    [[ $balancer_after == "False" ]] || { sudo ceph balancer on 2>/dev/null || true; die 'failed to disable balancer'; }
    r1b_marker R1B_BALANCER_LEASE_OWNED
    log "R1B_BALANCER_OFF active=false mode preserved"
  else
    log "R1B_BALANCER_ALREADY_OFF"
  fi
  # Trap: restore balancer on any failure
  trap 'sudo ceph balancer on 2>/dev/null || true; log "TRAP: balancer restored on"' ERR
  # Execute pool creation from plan
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    log "EXEC: $line"
    eval "$line" || { trap - ERR; sudo ceph balancer on 2>/dev/null || true; die "pool creation command failed: $line"; }
  done <"$plan_file"
  # Wait for 64/64 active+clean
  local ready=0
  for _ in $(seq 1 120); do
    sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-post-create.json" 2>/dev/null
    sudo ceph osd pool ls detail --format json >"$R1B_STATE/pools-wait-create.json" 2>/dev/null
    if python3 - "$R1B_STATE/pg-post-create.json" "$R1B_STATE/pools-wait-create.json" "$POOL_B_R1B" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
rows=d.get("pg_stats",d.get("pg_map",{}).get("pg_stats",[]))
pools=json.load(open(sys.argv[2])); name=sys.argv[3]
b=[p for p in (pools if isinstance(pools,list) else pools.get("pools",[])) if p.get("pool_name","")==name]
assert len(b)==1
pid=str(b[0].get("pool_id",b[0].get("pool",-1)))
pgs=[r for r in rows if str(r.get("pgid","")).split(".")[0]==pid]
assert len(pgs)==64 and all("active+clean" in str(r.get("state","")) for r in pgs)
PY
    then ready=1; break; fi
    sleep 5
  done
  (( ready == 1 )) || { trap - ERR; [[ $balancer_active != True ]] || sudo ceph balancer on 2>/dev/null || true; die 'B pool did not reach 64/64 active+clean in 600s'; }
  # Verify B empty, A unchanged, save natural mapping
  sudo ceph osd pool ls detail --format json >"$R1B_STATE/pools-post-create.json"
  sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-post-create.json"
  sudo ceph df detail --format json >"$R1B_STATE/df-post-create.json"
  sudo ceph osd getcrushmap -o "$R1B_STATE/crush-post-create.bin" >/dev/null
  local b_pool_id
  b_pool_id=$(python3 - "$R1B_STATE/pools-post-create.json" "$POOL_B_R1B" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); name=sys.argv[2]
rows=d if isinstance(d,list) else d.get("pools",[])
x=[p for p in rows if p.get("pool_name")==name]
assert len(x)==1; print(x[0].get("pool_id",x[0].get("pool",-1)))
PY
)
  # Verify B objects=0
  python3 - "$R1B_STATE/df-post-create.json" "$POOL_B_R1B" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); name=sys.argv[2]
for p in d.get("pools",[]):
  if p.get("name")==name:
    s=p.get("stats",{})
    assert int(s.get("objects",0))==0 and int(s.get("stored",0))==0, f"B not empty: objects={s.get('objects')} stored={s.get('stored')}"
    sys.exit(0)
raise SystemExit(f"B pool {name} not found in df")
PY
  # Save natural mapping in same OSDMap window
  mkdir -p "$R1B_RESULT_ROOT/mapping"
  sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-natural.json" 2>/dev/null
  python3 - "$R1B_STATE/pg-natural.json" "$b_pool_id" "$R1B_STATE/registered-map.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; out=sys.argv[3]
rows=d.get("pg_stats",d.get("pg_map",{}).get("pg_stats",[]))
rows=[r for r in rows if str(r.get("pgid","")).split(".",1)[0]==pid]
assert len(rows)==64, f"expected 64 PG, got {len(rows)}"
json.dump({"pool_id":int(pid),"pg_num":64,"pg_stats":rows},open(out,"w"),indent=2,sort_keys=True)
PY
  sha256sum "$R1B_STATE/registered-map.json" >"$R1B_RESULT_ROOT/mapping/registered-map.sha256"
  # Disable trap, balancer stays off for this phase
  trap - ERR
  r1b_marker R1B_POOL_CREATED; r1b_append r1b-create-pool PASS
  log "R1B_CREATE_POOL_PASS pool=$POOL_B_R1B pool_id=$b_pool_id pg_num=64 balancer=off"
}

# Adopt only this RUN's exact empty pool after create-pool completed its five
# planned writes but failed before freezing the post-create marker.
cmd_r1b_adopt_created_pool() {
  r1b_need R1B_PLAN_CREATE_POOL_COMPLETE; r1b_no R1B_POOL_CREATED
  [[ ${R1B_ADOPT_CREATED_POOL_ACK:-} == "I_ACK_R1B_ADOPT_CREATED_POOL_${RUN_ID}" ]] || die 'missing exact R1B adopt-created-pool ACK'
  require_real_ceph
  [[ ! -e $R1B_STATE/registered-map.json ]] || die 'registered map already exists; adoption is not applicable'
  [[ ! -e $R1B_STATE/DATA_PLANE_STARTED && ! -e $R1B_STATE/LAYOUT_STARTED ]] || die 'data plane already started'
  local plan_file="$R1B_RESULT_ROOT/plans/plan-create-steered-pool.txt"
  [[ -f $plan_file && ! -L $plan_file ]] || die 'create plan missing'
  ( cd "$R1B_RESULT_ROOT/plans" && sha256sum -c plan-create-steered-pool.sha256 >/dev/null 2>&1 ) || die 'create plan SHA mismatch'

  sudo ceph health --format json >"$R1B_STATE/health-pre-adopt-created.json"
  sudo ceph osd stat --format json >"$R1B_STATE/osd-stat-pre-adopt-created.json"
  sudo ceph osd pool ls detail --format json >"$R1B_STATE/pools-adopt-created.json"
  sudo ceph df detail --format json >"$R1B_STATE/df-adopt-created.json"
  sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-adopt-created.json"
  sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-adopt-created.json" 2>/dev/null
  local b_pool_id
  b_pool_id=$(python3 - "$R1B_STATE/health-pre-adopt-created.json" "$R1B_STATE/osd-stat-pre-adopt-created.json" \
    "$R1B_STATE/pools-adopt-created.json" "$R1B_STATE/df-adopt-created.json" \
    "$R1B_STATE/osd-dump-adopt-created.json" "$R1B_STATE/pg-adopt-created.json" "$POOL_B_R1B" <<'PY'
import json,sys
h,os,pl,df,od,pg,name=sys.argv[1:]
assert json.load(open(h)).get('status')=='HEALTH_OK'
o=json.load(open(os)); assert int(o.get('num_osds',-1))==6 and int(o.get('num_up_osds',-1))==6 and int(o.get('num_in_osds',-1))==6
p=json.load(open(pl)); rows=p if isinstance(p,list) else p.get('pools',[])
x=[r for r in rows if r.get('pool_name')==name]; assert len(x)==1
r=x[0]; pid=int(r.get('pool_id',r.get('pool',-1)))
assert int(r.get('pg_num',-1))==64 and int(r.get('pg_placement_num',-1))==64
assert int(r.get('type',-1))==3 and r.get('erasure_code_profile')=='ec-prod'
assert r.get('pg_autoscale_mode')=='off' and r.get('fast_read') is True
assert 'ec_overwrites' in str(r.get('flags_names','')), f"allow_ec_overwrites missing: {r.get('flags_names')}"
apps=r.get('application_metadata',{}); assert isinstance(apps,dict) and 'juicefs' in apps
d=json.load(open(df)); z=[q for q in d.get('pools',[]) if q.get('name')==name]; assert len(z)==1
s=z[0].get('stats',{}); assert int(s.get('objects',-1))==0 and int(s.get('stored',-1))==0
dump=json.load(open(od)); pfx=str(pid)+'.'
assert not [q for q in dump.get('pg_upmap',[]) if isinstance(q,dict) and str(q.get('pgid','')).startswith(pfx)]
pt=dump.get('primary_temp',[])
assert not [q for q in pt if (str(q).startswith(pfx) if isinstance(q,str) else str(q.get('pgid','')).startswith(pfx) if isinstance(q,dict) else False)]
g=json.load(open(pg)); prs=g.get('pg_stats',g.get('pg_map',{}).get('pg_stats',[]))
prs=[q for q in prs if str(q.get('pgid','')).split('.',1)[0]==str(pid)]
assert len(prs)==64 and all('active+clean' in str(q.get('state','')) for q in prs)
print(pid)
PY
) || die 'exact created-pool adoption contract failed'

  sudo ceph balancer status >"$R1B_STATE/balancer-pre-adopt-created.json"
  local active
  active=$(python3 -c "import json;print(json.load(open('$R1B_STATE/balancer-pre-adopt-created.json')).get('active',True))")
  if [[ $active == True ]]; then
    sudo ceph balancer off
  else
    [[ ${R1B_BALANCER_OFF_TRANSFER_ACK:-} == "I_ACK_R1B_BALANCER_OFF_TRANSFER_${RUN_ID}" ]] || die 'balancer already off; missing exact lease-transfer ACK'
  fi
  [[ $(sudo ceph balancer status | python3 -c 'import json,sys;print(json.load(sys.stdin).get("active",True))') == False ]] || die 'balancer is not off after adoption'
  r1b_marker R1B_BALANCER_LEASE_OWNED

  python3 - "$R1B_STATE/pg-adopt-created.json" "$b_pool_id" "$R1B_STATE/registered-map.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; out=sys.argv[3]
rows=d.get('pg_stats',d.get('pg_map',{}).get('pg_stats',[]))
rows=[r for r in rows if str(r.get('pgid','')).split('.',1)[0]==pid]
assert len(rows)==64
json.dump({'pool_id':int(pid),'pg_num':64,'pg_stats':rows},open(out,'w'),indent=2,sort_keys=True)
PY
  mkdir -p "$R1B_RESULT_ROOT/mapping"
  sha256sum "$R1B_STATE/registered-map.json" >"$R1B_RESULT_ROOT/mapping/registered-map.sha256"
  r1b_marker R1B_POOL_CREATED; r1b_append r1b-adopt-created-pool PASS
  log "R1B_ADOPT_CREATED_POOL_PASS pool=$POOL_B_R1B pool_id=$b_pool_id"
}

cmd_r1b_plan_create_pool() {
  r1b_need R1B_INIT_COMPLETE
  r1b_need R1B_PHASE_I_COMPLETE
  r1b_no R1B_PLAN_CREATE_POOL_COMPLETE
  mkdir -p "$R1B_RESULT_ROOT/plans" "$R1B_RESULT_ROOT/state"
  cat >"$R1B_RESULT_ROOT/plans/plan-create-steered-pool.txt" <<EOF
# Create one empty 64-PG EC pool; no auth, volume, mount, layout or data.
sudo ceph osd pool create $POOL_B_R1B 64 64 erasure ec-prod
sudo ceph osd pool set $POOL_B_R1B pg_autoscale_mode off
sudo ceph osd pool set $POOL_B_R1B allow_ec_overwrites true
sudo ceph osd pool set $POOL_B_R1B fast_read true
sudo ceph osd pool application enable $POOL_B_R1B juicefs
EOF
  sha256sum "$R1B_RESULT_ROOT/plans/plan-create-steered-pool.txt" >"$R1B_RESULT_ROOT/plans/plan-create-steered-pool.sha256"
  printf 'pool_b\t%s\npg_num\t64\ntarget_histogram\t%s\n' "$POOL_B_R1B" "$R1B_TARGET" >"$R1B_STATE/r1b-contract.tsv"
  r1b_marker R1B_PLAN_CREATE_POOL_COMPLETE; r1b_append r1b-plan-create-pool PASS
  log "R1B_PLAN_CREATE_POOL_PASS pool=$POOL_B_R1B pg_num=64"
}

cmd_r1b_plan_upmap() {
  r1b_need R1B_PLAN_CREATE_POOL_COMPLETE; r1b_no R1B_PLAN_UPMAP_COMPLETE
  mkdir -p "$R1B_RESULT_ROOT/plans"
  local map_path
  if [[ $MOCK == 1 ]]; then
    map_path="${R1_MOCK_REGISTERED_MAP:-}"
    [[ -n $map_path && -f $map_path && ! -L $map_path ]] || die 'mock requires R1_MOCK_REGISTERED_MAP'
  else
    map_path="$R1B_STATE/registered-map.json"
    [[ -f $map_path && ! -L $map_path ]] || die 'registered-map.json not found; create pool first'
  fi
  python3 "$MAP_ANALYZER" --plan-upmap-mode \
    --registered-map "$map_path" \
    --output "$R1B_RESULT_ROOT/plans/upmap-plan.json" \
    --target "$R1B_TARGET"
  python3 - "$R1B_RESULT_ROOT/plans/upmap-plan.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
base=sys.argv[1].rsplit('.',1)[0]
with open(base+'.apply.txt','w') as f:
  f.write('# pg-upmap apply plan; only on empty B pool\n')
  for c in d['upmap_commands']: f.write(c['command']+'\n')
with open(base+'.rollback.txt','w') as f:
  f.write('# pg-upmap rollback; only remove this RUN overrides\n')
  for c in d['rollback_commands']: f.write(c['command']+'\n')
PY
  sha256sum "$R1B_RESULT_ROOT/plans/"upmap-plan.{json,apply.txt,rollback.txt} >"$R1B_RESULT_ROOT/plans/upmap-plan.sha256"
  r1b_marker R1B_PLAN_UPMAP_COMPLETE; r1b_append r1b-plan-upmap PASS
  log "R1B_PLAN_UPMAP_PASS count=$(python3 -c "import json;print(json.load(open('$R1B_RESULT_ROOT/plans/upmap-plan.json'))['upmap_count'])")"
}

cmd_r1b_evaluate_structure() {
  r1b_need R1B_PLAN_UPMAP_COMPLETE; r1b_no R1B_EVALUATE_STRUCTURE_COMPLETE
  local natural_path steered_path plan_path sha_path
  plan_path="$R1B_RESULT_ROOT/plans/upmap-plan.json"
  sha_path="$R1B_RESULT_ROOT/plans/upmap-plan.sha256"
  [[ -f $plan_path && ! -L $plan_path ]] || die 'upmap-plan.json not found'
  [[ -f $sha_path ]] || die 'upmap-plan.sha256 not found'
  # Verify plan was not tampered after generation
  ( cd "$R1B_RESULT_ROOT/plans" && sha256sum -c upmap-plan.sha256 >/dev/null 2>&1 ) || die 'upmap-plan SHA mismatch; plan tampered'
  if [[ $MOCK == 1 ]]; then
    natural_path="${R1_MOCK_REGISTERED_MAP:-}"
    steered_path="${R1_MOCK_STEERED_MAP:-}"
    [[ -n $natural_path && -f $natural_path ]] || die 'mock requires R1_MOCK_REGISTERED_MAP'
    [[ -n $steered_path && -f $steered_path ]] || die 'mock requires R1_MOCK_STEERED_MAP'
  else
    natural_path="$R1B_STATE/registered-map.json"
    steered_path="$R1B_STATE/steered-map.json"
    [[ -f $natural_path ]] || die 'registered-map.json not found; create pool first'
    [[ -f $steered_path ]] || die 'steered-map.json not found; apply upmap first'
  fi
  local verdict
  if python3 "$MAP_ANALYZER" --verify-steered-mode \
    --natural-map "$natural_path" --plan "$plan_path" \
    --steered-map "$steered_path" \
    --output "$R1B_RESULT_ROOT/structure-eval.json" \
    --target "$R1B_TARGET" 2>"$R1B_RESULT_ROOT/structure-eval.stderr"; then
    verdict=R1B_STRUCTURE_PASS
  else
    verdict=R1B_STRUCTURE_BLOCKED
    cp "$R1B_RESULT_ROOT/structure-eval.json" "$R1B_STATE/r1b-structure-blocked.json" 2>/dev/null || true
  fi
  printf '%s\n' "$verdict" >"$R1B_STATE/R1B_STRUCTURE_VERDICT"
  r1b_marker R1B_EVALUATE_STRUCTURE_COMPLETE; r1b_append r1b-evaluate-structure "$verdict"
  log "R1B_EVALUATE_STRUCTURE $verdict"
}

cmd_r1b_apply_upmap() {
  r1b_need R1B_POOL_CREATED; r1b_need R1B_PLAN_UPMAP_COMPLETE
  r1b_need R1B_BALANCER_LEASE_OWNED; r1b_no R1B_UPMAP_APPLIED
  [[ ${R1B_APPLY_UPMAP_ACK:-} == "I_ACK_R1B_APPLY_UPMAP_${RUN_ID}" ]] || die 'missing exact R1B apply-upmap ACK'
  local plan_path="$R1B_RESULT_ROOT/plans/upmap-plan.json"
  local sha_path="$R1B_RESULT_ROOT/plans/upmap-plan.sha256"
  [[ -f $plan_path ]] || die 'upmap-plan.json missing'
  [[ -f $sha_path ]] || die 'upmap-plan.sha256 missing'
  ( cd "$R1B_RESULT_ROOT/plans" && sha256sum -c upmap-plan.sha256 >/dev/null 2>&1 ) || die 'upmap-plan SHA mismatch'
  local applied_list="$R1B_STATE/applied-upmap-pgs.tsv"
  : >"$applied_list"
  if [[ $MOCK == 1 ]]; then
    local steered="${R1_MOCK_STEERED_MAP:-}"
    [[ -n $steered && -f $steered ]] || die 'mock requires R1_MOCK_STEERED_MAP'
    mkdir -p "$R1B_STATE" "$R1B_RESULT_ROOT/mapping"
    cp -- "$steered" "$R1B_STATE/steered-map.json"
    python3 - "$plan_path" "$applied_list" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["upmap_commands"]:
  print(c["pgid"], file=open(sys.argv[2],"a"))
PY
    r1b_marker R1B_UPMAP_APPLIED; r1b_append r1b-apply-upmap PASS
    log "R1B_APPLY_UPMAP_PASS (mock)"
    return 0
  fi
  require_real_ceph
  # Pre-checks
  sudo ceph health --format json >"$R1B_STATE/health-pre-apply.json"
  python3 - "$R1B_STATE/health-pre-apply.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1]))
assert h.get("status")=="HEALTH_OK", f"health: {h.get('status')}"
PY
  ! sudo ceph health detail 2>/dev/null | grep -iE 'recovery|backfill|degraded' || die 'recovery active'
  # Verify B pool exists, empty, 64 clean
  local b_pool_id
  b_pool_id=$(contract_r1b_pool_id)
  # Verify no existing upmap for B PGs
  sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-pre-apply.json"
  python3 - "$R1B_STATE/osd-dump-pre-apply.json" "$b_pool_id" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
def pgid(entry):
  if isinstance(entry,dict): return str(entry.get("pgid",entry.get("pg", "")))
  if isinstance(entry,(list,tuple)) and entry: return str(entry[0])
  if isinstance(entry,str): return entry
  return ""
pg_upmap=d.get("pg_upmap",{})
if isinstance(pg_upmap,dict):
  for pg in pg_upmap:
    if str(pg).split(".",1)[0]==str(pid): raise SystemExit(f"existing pg_upmap for B pool: {pg}")
elif isinstance(pg_upmap,list):
  for entry in pg_upmap:
    pg=pgid(entry)
    if pg.split(".",1)[0]==str(pid): raise SystemExit(f"existing pg_upmap for B pool: {pg}")
pg_temp=d.get("pg_temp",{})
if isinstance(pg_temp,dict):
  for pg in pg_temp:
    if str(pg).split(".",1)[0]==str(pid): raise SystemExit(f"existing pg_temp for B pool: {pg}")
elif isinstance(pg_temp,list):
  for entry in pg_temp:
    pg=pgid(entry)
    if pg.split(".",1)[0]==str(pid): raise SystemExit(f"existing pg_temp for B pool: {pg}")
PY
  # Read apply plan and execute each command
  local cmds
  cmds=$(python3 - "$plan_path" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["upmap_commands"]: print(c["command"])
PY
)
  local failed=0
  while IFS= read -r cmd; do
    [[ -z $cmd ]] && continue
    log "EXEC: $cmd"
    if eval "$cmd"; then
      local pgid
      pgid=$(echo "$cmd" | grep -oP 'pg-upmap \K\S+')
      printf '%s\n' "$pgid" >>"$applied_list"
      log "APPLIED: $pgid"
    else
      log "FAILED: $cmd"
      failed=1
      break
    fi
  done <<<"$cmds"
  if [[ $failed == 1 ]]; then
    log "PARTIAL_FAILURE: rolling back applied PGs"
    while IFS= read -r pgid; do
      [[ -z $pgid ]] && continue
      log "ROLLBACK: sudo ceph osd rm-pg-upmap $pgid"
      sudo ceph osd rm-pg-upmap "$pgid" || log "ROLLBACK_FAILED: $pgid"
    done <"$applied_list"
    # Wait for clean
    for _ in $(seq 1 60); do sudo ceph health >/dev/null 2>&1 && break; sleep 5; done
    die 'r1b-apply-upmap partial failure; rolled back applied PGs'
  fi
  # Wait for HEALTH_OK + 64/64 active+clean
  local ready=0
  for _ in $(seq 1 120); do
    sudo ceph health >/dev/null 2>&1 || { sleep 5; continue; }
    sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-post-apply.json" 2>/dev/null
    if python3 - "$R1B_STATE/pg-post-apply.json" "$b_pool_id" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
rows=d.get("pg_stats",d.get("pg_map",{}).get("pg_stats",[]))
pgs=[r for r in rows if str(r.get("pgid","")).split(".")[0]==pid]
assert len(pgs)==64 and all("active+clean" in str(r.get("state","")) for r in pgs)
PY
    then ready=1; break; fi
    sleep 5
  done
  (( ready == 1 )) || die 'B pool did not stabilize after upmap'
  # Capture steered-map.json in same OSDMap epoch
  mkdir -p "$R1B_RESULT_ROOT/mapping"
  sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-steered.json" 2>/dev/null
  python3 - "$R1B_STATE/pg-steered.json" "$b_pool_id" "$R1B_STATE/steered-map.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; out=sys.argv[3]
rows=d.get("pg_stats",d.get("pg_map",{}).get("pg_stats",[]))
rows=[r for r in rows if str(r.get("pgid","")).split(".",1)[0]==pid]
assert len(rows)==64, f"expected 64 PG, got {len(rows)}"
json.dump({"pool_id":int(pid),"pg_num":64,"pg_stats":rows},open(out,"w"),indent=2,sort_keys=True)
PY
  r1b_marker R1B_UPMAP_APPLIED; r1b_append r1b-apply-upmap PASS
  log "R1B_APPLY_UPMAP_PASS count=$(wc -l <"$applied_list" | tr -d ' ')"
}

cmd_r1b_rollback_upmap() {
  r1b_need R1B_UPMAP_APPLIED; r1b_no R1B_UPMAP_ROLLED_BACK
  local applied_list="$R1B_STATE/applied-upmap-pgs.tsv"
  [[ -f $applied_list ]] || die 'applied-upmap-pgs.tsv missing'
  if [[ $MOCK == 1 ]]; then
    r1b_marker R1B_UPMAP_ROLLED_BACK; r1b_append r1b-rollback-upmap PASS
    log "R1B_ROLLBACK_UPMAP_PASS (mock)"
    return 0
  fi
  require_real_ceph
  while IFS= read -r pgid; do
    [[ -z $pgid ]] && continue
    log "ROLLBACK: sudo ceph osd rm-pg-upmap $pgid"
    sudo ceph osd rm-pg-upmap "$pgid" || log "ROLLBACK_FAILED: $pgid"
  done <"$applied_list"
  for _ in $(seq 1 120); do
    sudo ceph health >/dev/null 2>&1 || { sleep 5; continue; }
    break
  done
  r1b_marker R1B_UPMAP_ROLLED_BACK; r1b_append r1b-rollback-upmap PASS
  log "R1B_ROLLBACK_UPMAP_PASS"
}

contract_r1b_pool_id() {
  python3 - "$R1B_STATE/registered-map.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); print(d.get("pool_id",-1))
PY
}

cmd_r1b_plan_primary_toggle() {
  r1b_need R1B_UPMAP_APPLIED; r1b_no R1B_PLAN_PRIMARY_TOGGLE_COMPLETE
  local nat_path="$R1B_STATE/registered-map.json"
  local st_path="$R1B_STATE/steered-map.json"
  local plan_dir="$R1B_RESULT_ROOT/plans"
  mkdir -p "$plan_dir"
  [[ -f $nat_path ]] || die 'registered-map.json missing'
  [[ -f $st_path ]] || die 'steered-map.json missing'
  python3 - "$nat_path" "$st_path" "$plan_dir" "$POOL_B_R1B" <<'PY'
import json,sys,hashlib
nat=json.load(open(sys.argv[1])); st=json.load(open(sys.argv[2]))
plan_dir=sys.argv[3]; pool_name=sys.argv[4]
nat_rows={str(r.get("pgid","")):r for r in nat.get("pg_stats",[])}
st_rows={str(r.get("pgid","")):r for r in st.get("pg_stats",[])}
# Find PGs where primary differs (these have pg-upmap)
toggle_pgs=[]
for pgid in sorted(nat_rows):
  nat_p=int(nat_rows[pgid].get("primary",nat_rows[pgid].get("acting",[0])[0]))
  st_p=int(st_rows[pgid].get("primary",st_rows[pgid].get("acting",[0])[0]))
  if nat_p!=st_p:
    toggle_pgs.append({"pgid":pgid,"natural_primary":nat_p,"steered_primary":st_p})
assert len(toggle_pgs)>0, "no PGs with different primary found"
# N apply: primary-temp to natural primary
n_cmds=[f"sudo ceph osd primary-temp {p['pgid']} {p['natural_primary']}" for p in toggle_pgs]
# S clear: primary-temp set to steered primary (Ceph auto-removes no-op)
s_clears=[f"sudo ceph osd primary-temp {p['pgid']} {p['steered_primary']}" for p in toggle_pgs]
plan={
  "pool_name":pool_name, "toggle_count":len(toggle_pgs),
  "toggle_pgs":[{"pgid":p["pgid"],"natural_primary":p["natural_primary"],
                 "steered_primary":p["steered_primary"]} for p in toggle_pgs],
  "n_apply_commands":[{"pgid":p["pgid"],"command":c} for p,c in zip(toggle_pgs,n_cmds)],
  "s_clear_commands":[{"pgid":p["pgid"],"command":c} for p,c in zip(toggle_pgs,s_clears)],
}
json.dump(plan,open(f"{plan_dir}/primary-toggle-plan.json","w"),indent=2,sort_keys=True)
with open(f"{plan_dir}/primary-toggle-n-apply.txt","w") as f:
  for c in n_cmds: f.write(c+"\n")
with open(f"{plan_dir}/primary-toggle-s-clear.txt","w") as f:
  for c in s_clears: f.write(c+"\n")
import os; os.chdir(plan_dir)
for fn in ["primary-toggle-plan.json","primary-toggle-n-apply.txt","primary-toggle-s-clear.txt"]:
  hashlib.sha256(open(fn,"rb").read()).hexdigest()
with open("primary-toggle.sha256","w") as f:
  import subprocess
  subprocess.run(["sha256sum","primary-toggle-plan.json","primary-toggle-n-apply.txt","primary-toggle-s-clear.txt"],stdout=f)
PY
  r1b_marker R1B_PLAN_PRIMARY_TOGGLE_COMPLETE; r1b_append r1b-plan-primary-toggle PASS
  log "R1B_PLAN_PRIMARY_TOGGLE_PASS count=$(python3 -c "import json;print(json.load(open('$R1B_RESULT_ROOT/plans/primary-toggle-plan.json'))['toggle_count'])")"
}

cmd_r1b_canary_primary_toggle() {
  r1b_need R1B_PLAN_PRIMARY_TOGGLE_COMPLETE; r1b_no R1B_PRIMARY_TOGGLE_CANARY_DONE
  [[ ${R1B_PRIMARY_TEMP_CANARY_ACK:-} == "I_ACK_R1B_PRIMARY_TEMP_CANARY_${RUN_ID}" ]] || die 'missing exact R1B primary-temp canary ACK'
  local plan_path="$R1B_RESULT_ROOT/plans/primary-toggle-plan.json"
  local sha_path="$R1B_RESULT_ROOT/plans/primary-toggle.sha256"
  [[ -f $plan_path ]] || die 'primary-toggle-plan.json missing'
  [[ -f $sha_path ]] || die 'primary-toggle.sha256 missing'
  ( cd "$R1B_RESULT_ROOT/plans" && sha256sum -c primary-toggle.sha256 >/dev/null 2>&1 ) || die 'primary-toggle plan SHA mismatch'
  if [[ $MOCK == 1 ]]; then
    r1b_marker R1B_PRIMARY_TOGGLE_CANARY_DONE; r1b_append r1b-canary-primary-toggle PASS
    log "R1B_PRIMARY_TOGGLE_CANARY_PASS (mock)"
    return 0
  fi
  require_real_ceph
  local b_pool_id; b_pool_id=$(contract_r1b_pool_id)
  # Pre-checks
  sudo ceph health >/dev/null 2>&1 || die 'health not OK'
  ! sudo ceph health detail 2>/dev/null | grep -iE 'recovery|backfill|degraded' || die 'recovery active'
  # Verify B has no existing primary_temp
  sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-pre-canary.json"
  python3 - "$R1B_STATE/osd-dump-pre-canary.json" "$b_pool_id" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
def pgid(entry):
  if isinstance(entry,dict): return str(entry.get("pgid",entry.get("pg", "")))
  if isinstance(entry,(list,tuple)) and entry: return str(entry[0])
  if isinstance(entry,str): return entry
  return ""
pt=d.get("primary_temp",{})
if isinstance(pt,dict):
  for pg in pt:
    if str(pg).split(".",1)[0]==str(pid): raise SystemExit(f"existing primary_temp for B: {pg}")
elif isinstance(pt,list):
  for e in pt:
    pg=pgid(e)
    if pg.split(".",1)[0]==str(pid): raise SystemExit(f"existing primary_temp for B: {pg}")
PY
  local applied_n="$R1B_STATE/applied-n-pgs.tsv"
  : >"$applied_n"
  # Step 1: Verify S baseline
  log "CANARY_STEP1: verify S baseline"
  # Step 2: Apply 4 N primary-temp
  local n_cmds
  n_cmds=$(python3 - "$plan_path" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["n_apply_commands"]: print(c["command"])
PY
)
  while IFS= read -r cmd; do
    [[ -z $cmd ]] && continue
    log "EXEC: $cmd"
    if eval "$cmd"; then
      local pgid; pgid=$(echo "$cmd" | grep -oP 'primary-temp \K\S+')
      printf '%s\n' "$pgid" >>"$applied_n"
      log "N_APPLIED: $pgid"
    else
      log "N_FAILED: $cmd"
      # Rollback: set applied PGs back to steered_primary (auto-removes primary_temp)
      while IFS= read -r pgid; do
        [[ -z $pgid ]] && continue
        local steered_p
        steered_p=$(python3 - "$plan_path" "$pgid" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pgid=sys.argv[2]
for t in d.get("toggle_pgs",[]):
  if t["pgid"]==pgid: print(t["steered_primary"]); break
PY
)
        sudo ceph osd primary-temp "$pgid" "$steered_p" 2>/dev/null || true
      done <"$applied_n"
      die 'N apply failed; rolled back'
    fi
  done <<<"$n_cmds"
  # Wait for clean
  _r1b_wait_clean "$b_pool_id"
  log "CANARY_STEP2: N applied, verifying"
  # Step 3: Verify N histogram
  sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-n-state.json" 2>/dev/null
  # Dynamic target from registered-map.json
  python3 - "$R1B_STATE/pg-n-state.json" "$b_pool_id" "$R1B_STATE/registered-map.json" <<'PY'
import json,sys
from collections import Counter
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
rows=d.get("pg_stats",d.get("pg_map",{}).get("pg_stats",[]))
pgs=[r for r in rows if str(r.get("pgid","")).split(".")[0]==pid]
assert len(pgs)==64
prim=Counter()
for r in pgs:
  p=r.get("primary",r.get("acting_primary"))
  if p is None: p=r.get("acting",[0])[0]
  prim[int(p)]+=1
# Dynamic N target from registered-map.json
nat=json.load(open(sys.argv[3]))
nat_rows=[r for r in nat.get("pg_stats",nat.get("pg_map",{}).get("pg_stats",[])) if str(r.get("pgid","")).split(".")[0]==str(pid)]
assert len(nat_rows)==64, f"registered-map PG count {len(nat_rows)} != 64"
osds=set()
for r in nat_rows:
  act=[int(x) for x in r.get("acting",r.get("up",[]))]
  osds.update(act)
assert osds=={0,1,2,3,4,5}, f"registered-map OSD set {osds} != 0..5"
nat_prim=Counter()
for r in nat_rows:
  p=r.get("primary",r.get("acting_primary",r.get("acting",[0])[0]))
  nat_prim[int(p)]+=1
n_target={o:nat_prim[o] for o in range(6)}
actual={o:prim[o] for o in range(6)}
assert actual==n_target, f"N histogram mismatch: {actual} != {n_target}"
print("N_HISTOGRAM_PASS")
PY
  log "CANARY_STEP3: N verified"
  # Step 4: Clear 4 primary-temp
  local s_cmds
  s_cmds=$(python3 - "$plan_path" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["s_clear_commands"]: print(c["command"])
PY
)
  while IFS= read -r cmd; do
    [[ -z $cmd ]] && continue
    log "EXEC: $cmd"
    eval "$cmd" || log "S_CLEAR_WARN: $cmd"
  done <<<"$s_cmds"
  _r1b_wait_clean "$b_pool_id"
  log "CANARY_STEP4: S cleared, verifying"
  # Step 5: Verify S restored, no primary_temp residue
  sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-post-canary.json"
  python3 - "$R1B_STATE/osd-dump-post-canary.json" "$b_pool_id" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
def pgid(entry):
  if isinstance(entry,dict): return str(entry.get("pgid",entry.get("pg", "")))
  if isinstance(entry,(list,tuple)) and entry: return str(entry[0])
  if isinstance(entry,str): return entry
  return ""
pt=d.get("primary_temp",{})
residual=[]
if isinstance(pt,dict):
  for pg in pt:
    if str(pg).split(".",1)[0]==str(pid): residual.append(pg)
elif isinstance(pt,list):
  for e in pt:
    pg=pgid(e)
    if pg.split(".",1)[0]==str(pid): residual.append(pg)
assert not residual, f"primary_temp residue: {residual}"
print("NO_RESIDUE_PASS")
PY
  sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-s-restored.json" 2>/dev/null
  python3 - "$R1B_STATE/pg-s-restored.json" "$b_pool_id" "$R1B_STATE/steered-map.json" <<'PY'
import json,sys
from collections import Counter
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
rows=d.get("pg_stats",d.get("pg_map",{}).get("pg_stats",[]))
pgs=[r for r in rows if str(r.get("pgid","")).split(".")[0]==pid]
assert len(pgs)==64
prim=Counter()
for r in pgs:
  p=r.get("primary",r.get("acting_primary"))
  if p is None: p=r.get("acting",[0])[0]
  prim[int(p)]+=1
# Dynamic S target from steered-map.json
st=json.load(open(sys.argv[3]))
st_rows=[r for r in st.get("pg_stats",st.get("pg_map",{}).get("pg_stats",[])) if str(r.get("pgid","")).split(".")[0]==str(pid)]
assert len(st_rows)==64, f"steered-map PG count {len(st_rows)} != 64"
osds=set()
for r in st_rows:
  act=[int(x) for x in r.get("acting",r.get("up",[]))]
  osds.update(act)
assert osds=={0,1,2,3,4,5}, f"steered-map OSD set {osds} != 0..5"
st_prim=Counter()
for r in st_rows:
  p=r.get("primary",r.get("acting_primary",r.get("acting",[0])[0]))
  st_prim[int(p)]+=1
s_target={o:st_prim[o] for o in range(6)}
actual={o:prim[o] for o in range(6)}
assert actual==s_target, f"S restored histogram mismatch: {actual} != {s_target}"
print("S_RESTORED_PASS")
PY
  r1b_marker R1B_PRIMARY_TOGGLE_CANARY_DONE; r1b_append r1b-canary-primary-toggle PASS
  log "R1B_PRIMARY_TOGGLE_CANARY_PASS"
}

_r1b_wait_clean() {
  local pid=$1 consecutive=0
  for _ in $(seq 1 120); do
    # During the owned scrub-pause lease, HEALTH_WARN is valid only when the
    # sole check is OSDMAP_FLAGS. Reuse the same strict validator as rounds.
    sudo ceph health detail --format json >"$R1B_STATE/health-wait.json" 2>/dev/null \
      || { consecutive=0; sleep 10; continue; }
    check_health_json "$R1B_STATE/health-wait.json" wait r1b-clean \
      || { consecutive=0; sleep 10; continue; }
    # No recovery/backfill/degraded
    sudo ceph health detail 2>/dev/null | grep -iE 'recovery|backfill|degraded' && { consecutive=0; sleep 10; continue; }
    # B PGs 64/64 active+clean
    sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-wait.json" 2>/dev/null
    if python3 - "$R1B_STATE/pg-wait.json" "$pid" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
rows=d.get("pg_stats",d.get("pg_map",{}).get("pg_stats",[]))
pgs=[r for r in rows if str(r.get("pgid","")).split(".")[0]==pid]
assert len(pgs)==64 and all("active+clean" in str(r.get("state","")) for r in pgs)
PY
    then
      consecutive=$((consecutive+1))
      [[ $consecutive -ge 2 ]] && return 0
      sleep 10
    else
      consecutive=0
      sleep 10
    fi
  done
  die "B pool did not stabilize (2 consecutive clean samples) in 1200s"
}

cmd_r1b_plan_data_l1() {
  r1b_need R1B_PRIMARY_TOGGLE_CANARY_DONE; r1b_no R1B_PLAN_DATA_L1_COMPLETE
  mkdir -p "$R1B_RESULT_ROOT/plans"
  local pid; pid=$(contract_r1b_pool_id)
  local toggle_plan="$R1B_RESULT_ROOT/plans/primary-toggle-plan.json"
  local n_cmds s_cmds toggle_count
  [[ -f $toggle_plan ]] || die 'primary-toggle-plan.json missing for L1 plan'
  n_cmds=$(python3 -c "import json;d=json.load(open('$toggle_plan'));print(len(d.get('n_apply_commands',[])))")
  s_cmds=$(python3 -c "import json;d=json.load(open('$toggle_plan'));print(len(d.get('s_clear_commands',[])))")
  toggle_count=$n_cmds
  # Dynamic plan: render from frozen toggle plan, no hardcoded PG IDs
  cat >"$R1B_RESULT_ROOT/plans/plan-data-l1.txt" <<EOF
# Dynamic L1 execution plan for 04-1b RUN ${RUN_ID}. NOT executable without exact ACK.
# Rendered from frozen primary-toggle-plan.json (${toggle_count} toggle PGs).
# pool_id=${pid} pool_name=${POOL_B_R1B}
# Precondition: R1B_LAYOUT_ADOPTED_PASS or R1B_LAYOUT_ONCE_PASS; B RO mount active;
# 5 frozen pg_upmap; no primary_temp; balancer off; scrub flags clean.

## Phase A: Pre-L1 verification (read-only)
# A1: Verify health OK, 6/6 OSD, 64/64 clean, no recovery
# A2: Verify B RO mount PID/starttime/cmdline(--read-only)/UUID frozen
# A3: Verify 5 frozen pg_upmap exact, primary_temp=[], objects/stored frozen
# A4: Clock sync check (4 nodes, ≤100ms)

## Phase B: Scrub lease and W01-W04
# B1: scrub_pause via u141d-scrub-control.sh lease=${RUN_ID}-phase-a
# B2: verify-paused
# B3: Drop caches (client + 150/151/152, 20s wait)
# W01=N: Apply ${toggle_count} primary-temp from frozen n-apply.txt → wait 2x clean → verify N hist dynamic → fio 180s → sampler → OSD analysis
# W02=S: Apply ${toggle_count} primary-temp from frozen s-clear.txt → wait → verify S hist → fio → sampler → analysis
# W03=S: Verify already S (NO OSDMap writes, epoch before==after) → fio → sampler → analysis
# W04=N: Same as W01
# Each round: fio-3.28, randread/256k/128jobs/iodepth128/direct=1/180s/readonly/allow_file_create=0
# Each round: 128 bw logs, fio-start/end ns, health pre/post, OSDMap epoch

## Phase C: Post-W cleanup (state-driven, all steps attempted)
# C1: Clear primary_temp to S (frozen s-clear.txt)
# C2: Verify S hist dynamic, primary_temp=[], 5 upmap, objects/stored, mount UUID/PID, health
# C3: scrub_restore via u141d-scrub-control.sh + verify
# C4: Verify 4 rounds: SAMPLER_PASS/process.rc=0/fio rc=0/128 bw/osd-analysis.json per round
# C5: R1B manipulation analysis via s04r1-analyze.py r1b-manipulation
# C6: Write R1B_L1_SCREEN_DONE only if all above pass

## Failure closure (set +e, all steps attempted, FATAL on any failure)
# F1: Close active sampler (exact label), record rc
# F2: Clear primary_temp to S, record rc
# F3: Verify S state, record rc
# F4: scrub_restore + verify, record rc
# F5: Write R1B_L1_FATAL and incidents if any step failed; exit non-zero
EOF
  sha256sum "$R1B_RESULT_ROOT/plans/plan-data-l1.txt" >"$R1B_RESULT_ROOT/plans/plan-data-l1.sha256"
  cat >"$R1B_RESULT_ROOT/plans/plan-data-l1-rollback.txt" <<EOF
# L1 rollback plan (state-driven, set +e, all steps attempted)
# 1. Close exact active sampler by label, record rc
# 2. Clear primary_temp to S via frozen s-clear.txt, record rc
# 3. Verify S hist/primary_temp=[], record rc
# 4. scrub_restore via u141d-scrub-control.sh + verify, record rc
# 5. Write R1B_L1_FATAL if any step failed; exit non-zero
# 6. Preserve B pool/upmap/layout; do NOT delete pool/auth/volume/upmap
EOF
  sha256sum "$R1B_RESULT_ROOT/plans/plan-data-l1-rollback.txt" >>"$R1B_RESULT_ROOT/plans/plan-data-l1.sha256"
  r1b_marker R1B_PLAN_DATA_L1_COMPLETE; r1b_append r1b-plan-data-l1 PASS
  log "R1B_PLAN_DATA_L1_PASS toggle_count=${toggle_count}"
}

# Freeze the one-time layout contract separately from the unfinished L1
# performance plan.  This command only writes evidence under RESULT_ROOT.
cmd_r1b_plan_layout_v2() {
  r1b_need R1B_PRIMARY_TOGGLE_CANARY_DONE
  r1b_no R1B_PLAN_LAYOUT_V2_COMPLETE
  mkdir -p "$R1B_RESULT_ROOT/plans"
  local pool_id task_sha driver_sha
  pool_id=$(contract_r1b_pool_id)
  task_sha=$(sha256sum "$TASK_R1B" | awk '{print $1}')
  driver_sha=$(sha256sum "$0" | awk '{print $1}')
  cat >"$R1B_RESULT_ROOT/plans/plan-layout-v2.txt" <<EOF
# 04-1b one-time layout v2; requires I_ACK_R1B_LAYOUT_${RUN_ID}.
# Precondition: B id=${pool_id}, name=${POOL_B_R1B}, 64 PG, empty, the exact
# frozen pg_upmap plan applied, no B primary_temp, balancer lease retained.
# Writes: one B CephX identity, one fresh JuiceFS META namespace and exactly
# test_dir/read_test.0.0 ... test_dir/read_test.127.0 (1 GiB each).
# Lifecycle: format -> RW mount -> fio -> exact manifest -> graceful umount
# -> RO mount -> exact manifest -> three stable Ceph samples.
# Failure: mark DATA_PLANE_FAILED or LAYOUT_FAILED and gracefully unmount
# only this run's exact mount. Never delete pool/auth/META/data.
EOF
  cat >"$R1B_RESULT_ROOT/plans/plan-layout-v2-rollback.txt" <<EOF
# Failure closure: exact graceful umount when this run owns the mount; record
# stage/rc; preserve ${POOL_B_R1B}, pg_upmap, auth, META and written data.
# A failed run is evidence-only and must not be retried.
EOF
  printf 'field\tvalue\nrun_id\t%s\npool_name\t%s\npool_id\t%s\ntask_sha256\t%s\ndriver_sha256\t%s\njuicefs_md5\t%s\n' \
    "$RUN_ID" "$POOL_B_R1B" "$pool_id" "$task_sha" "$driver_sha" \
    '24fae0852051c80ca571cb2f20275d46' \
    >"$R1B_RESULT_ROOT/plans/layout-v2-contract.tsv"
  ( cd "$R1B_RESULT_ROOT/plans" && sha256sum plan-layout-v2.txt \
      plan-layout-v2-rollback.txt layout-v2-contract.tsv >plan-layout-v2.sha256 )
  r1b_marker R1B_PLAN_LAYOUT_V2_COMPLETE
  r1b_append r1b-plan-layout-v2 PASS
  log "R1B_PLAN_LAYOUT_V2_PASS pool_id=$pool_id"
}

_r1b_validate_layout_tree() {
  local mount_dir=$1 manifest=$2
  python3 - "$mount_dir/test_dir" "$manifest" <<'PY'
import sys
from pathlib import Path
d=Path(sys.argv[1]); out=Path(sys.argv[2])
if not d.is_dir() or d.is_symlink(): raise SystemExit(f"layout directory invalid: {d}")
expected={f"read_test.{i}.0" for i in range(128)}
actual={p.name for p in d.iterdir() if p.name.startswith("read_test.")}
if actual != expected:
    raise SystemExit(f"layout names mismatch count={len(actual)} missing={sorted(expected-actual)[:8]} extra={sorted(actual-expected)[:8]}")
rows=[]
for name in sorted(expected,key=lambda x:int(x.split('.')[1])):
    p=d/name
    if p.is_symlink() or not p.is_file(): raise SystemExit(f"not a regular file: {p}")
    st=p.stat()
    if st.st_size != 1073741824: raise SystemExit(f"file size mismatch: {p}={st.st_size}")
    rows.append(f"{name}\t{st.st_size}\t{st.st_ino}\t{st.st_mtime_ns}\n")
out.write_text("name\tsize\tinode\tmtime_ns\n"+''.join(rows))
PY
}

_r1b_capture_mount_identity() {
  local binary=$1 meta=$2 mount_dir=$3 expected_uuid=$4 mode=$5 out=$6
  local status_file="$out.status.json" findmnt_file="$out.findmnt.tsv"
  "$binary" status "$meta" >"$status_file" 2>/dev/null || return 1
  python3 - "$status_file" "$expected_uuid" <<'PY'
import json,sys
got=json.load(open(sys.argv[1])).get('Setting',{}).get('UUID','')
assert got==sys.argv[2], f"mount UUID mismatch: {got} != {sys.argv[2]}"
PY
  findmnt -rn -M "$mount_dir" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$findmnt_file" || return 1
  python3 - "$binary" "$meta" "$mount_dir" "$mode" "$findmnt_file" "$out" <<'PY'
import os,sys
from pathlib import Path
binary,meta,mnt,mode,fm,out=sys.argv[1:]
fields=Path(fm).read_text().strip().split(None,3)
if len(fields)!=4 or fields[1]!=mnt: raise SystemExit(f"unexpected findmnt identity: {fields}")
if mode not in set(fields[3].split(',')): raise SystemExit(f"mount mode {mode} absent: {fields[3]}")
want=os.path.realpath(binary); rows=[]
for proc in Path('/proc').iterdir():
    if not proc.name.isdigit(): continue
    try:
        raw=(proc/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace').strip()
        exe=os.path.realpath(os.readlink(proc/'exe'))
        stat=(proc/'stat').read_text(); tail=stat[stat.rfind(')')+2:].split()
        ppid=int(tail[1]); starttime=tail[19]
    except (OSError,ValueError,IndexError): continue
    if exe==want and meta in raw and mnt in raw: rows.append((int(proc.name),ppid,starttime,exe,raw))
ids={r[0] for r in rows}; workers=[r for r in rows if r[1] in ids]
if len(workers)!=1: raise SystemExit(f"expected one parent-child worker, candidates={[(r[0],r[1]) for r in rows]}")
w=workers[0]
with open(out,'w') as f:
    f.write('role\tpid\tppid\tstarttime\texe\tcmdline\n')
    for r in sorted(rows): f.write(('worker' if r[0]==w[0] else 'parent')+'\t'+'\t'.join(map(str,r))+'\n')
print(w[0])
PY
}

cmd_r1b_layout_once() {
  r1b_need R1B_PLAN_LAYOUT_V2_COMPLETE
  r1b_no R1B_LAYOUT_ONCE_PASS; r1b_no DATA_PLANE_STARTED
  r1b_no DATA_PLANE_FAILED; r1b_no LAYOUT_FAILED
  [[ ${R1B_LAYOUT_ACK:-} == "I_ACK_R1B_LAYOUT_${RUN_ID}" ]] || die 'missing exact R1B layout ACK'
  if [[ $MOCK == 1 ]]; then
    [[ $DRY_RUN_ONLY == 1 ]] || die 'mock layout requires DRY_RUN_ONLY=1'
  else
    require_real_ceph
  fi
  local binary="/tmp/juicefs-1.4.1-patched"
  local meta_b="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/jfs-r1b-${RUN_ID}-b"
  local auth_b="client.jfs-r1b-${RUN_ID}"
  local keyring_b="/tmp/jfs-r1b-${RUN_ID}.ceph.keyring"
  local mnt_b="/tmp/jfs-r1b-${RUN_ID}-mnt"
  local b_pid_pool; b_pid_pool=$(contract_r1b_pool_id)
  local fail_at="${R1_MOCK_FAIL_AT:-}"

  local plan_dir="$R1B_RESULT_ROOT/plans" contract="$R1B_RESULT_ROOT/plans/layout-v2-contract.tsv"
  [[ -f $contract && ! -L $contract && -f $plan_dir/plan-layout-v2.sha256 ]] || die 'layout v2 contract missing'
  ( cd "$plan_dir" && sha256sum -c plan-layout-v2.sha256 >/dev/null 2>&1 ) || die 'layout v2 plan SHA mismatch'
  python3 - "$contract" "$RUN_ID" "$POOL_B_R1B" "$b_pid_pool" "$TASK_R1B" "$0" <<'PY'
import hashlib,sys
p,run,pool,pid,task,driver=sys.argv[1:]
rows={}
for line in open(p):
    k,_,v=line.rstrip('\n').partition('\t'); rows[k]=v
def sha(path): return hashlib.sha256(open(path,'rb').read()).hexdigest()
assert rows.get('run_id')==run
assert rows.get('pool_name')==pool and rows.get('pool_id')==pid
assert rows.get('task_sha256')==sha(task), 'task changed after layout plan'
assert rows.get('driver_sha256')==sha(driver), 'driver changed after layout plan'
assert rows.get('juicefs_md5')=='24fae0852051c80ca571cb2f20275d46'
PY

  # === Pre-write checks (all before DATA_PLANE_STARTED) ===
  # Health
  if [[ $MOCK != 1 ]]; then
    sudo ceph health --format json >"$R1B_STATE/health-pre-layout.json" 2>/dev/null
    python3 - "$R1B_STATE/health-pre-layout.json" <<'PY'
import json,sys; h=json.load(open(sys.argv[1])); assert h.get("status")=="HEALTH_OK", f"health: {h.get('status')}"
PY
    ! sudo ceph health detail 2>/dev/null | grep -iE 'recovery|backfill|degraded' || die 'recovery active'
    # Binary MD5
    local bin_md5; bin_md5=$(md5sum "$binary" | awk '{print $1}')
    [[ $bin_md5 == "24fae0852051c80ca571cb2f20275d46" ]] || die "binary MD5 mismatch: $bin_md5"
    # B pool, S state, exact frozen upmap set, balancer lease
    r1b_need R1B_BALANCER_LEASE_OWNED
    sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-pre-layout.json" 2>/dev/null
    python3 - "$R1B_STATE/osd-dump-pre-layout.json" "$b_pid_pool" "$R1B_RESULT_ROOT/plans/upmap-plan.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; plan=json.load(open(sys.argv[3]))
def pgid(entry):
  if isinstance(entry,dict): return str(entry.get("pgid",entry.get("pg", "")))
  if isinstance(entry,(list,tuple)) and entry: return str(entry[0])
  if isinstance(entry,str): return entry
  return ""
pt=d.get("primary_temp",[])
b_pt=[pgid(x) for x in pt if pgid(x).startswith(pid+".")] if isinstance(pt,list) else [str(k) for k in pt if str(k).startswith(pid+".")] if isinstance(pt,dict) else []
assert not b_pt, f"primary_temp not empty for B: {b_pt}"
um=d.get("pg_upmap",[])
b_um={pgid(x) for x in um if pgid(x).startswith(pid+".")} if isinstance(um,list) else {str(k) for k in um if str(k).startswith(pid+".")} if isinstance(um,dict) else set()
expected={str(c.get("pgid","")) for c in plan.get("upmap_commands",[])}
assert expected and b_um==expected, f"upmap set mismatch: actual={sorted(b_um)} expected={sorted(expected)}"
osds=d.get('osds',[])
assert len(osds)==6 and all(int(x.get('up',0))==1 and int(x.get('in',0))==1 for x in osds), 'OSDs not 6/6 up+in'
PY
    sudo ceph balancer status >"$R1B_STATE/balancer-pre-layout.json" 2>/dev/null
    python3 - "$R1B_STATE/balancer-pre-layout.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); assert d.get('active') is False, 'balancer must remain off'
PY
    sudo ceph df detail --format json >"$R1B_STATE/ceph-df-pre-layout.json" 2>/dev/null
    python3 - "$R1B_STATE/ceph-df-pre-layout.json" "$POOL_B_R1B" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); rows=[p for p in d.get('pools',[]) if p.get('name')==sys.argv[2]]
assert len(rows)==1, 'candidate pool missing/duplicated'
s=rows[0].get('stats',{}); assert int(s.get('objects',-1))==0 and int(s.get('stored',-1))==0, f"B not empty: {s}"
PY
    # Capacity
    local avail; avail=$(sudo ceph df --format json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('stats',{}).get('total_avail_bytes',0))")
    [[ $avail -gt 549755813888 ]] || die "insufficient capacity: $avail bytes"
  fi
  # META/auth/keyring/mount must not exist (before any write)
  [[ ! -e $keyring_b ]] || die 'keyring already exists'
  [[ ! -e $mnt_b ]] || die 'mount dir exists'
  if [[ $MOCK != 1 ]]; then
    "$binary" status "$meta_b" >/dev/null 2>&1 && die 'META namespace already exists'
    ! sudo ceph auth ls 2>/dev/null | grep -q "$auth_b" || die 'auth already exists'
  else
    [[ ! -e "$R1B_STATE/mock-meta-exists" ]] || die 'META namespace already exists'
    [[ ! -e "$R1B_STATE/mock-auth-exists" ]] || die 'auth already exists'
  fi

  # Write DATA_PLANE_STARTED before any environment write
  r1b_marker DATA_PLANE_STARTED
  mkdir -p "$R1B_STATE" "$R1B_RESULT_ROOT/layout"
  local layout_done=0 mount_owned=0 layout_stage=auth
  _r1b_layout_exit() {
    local rc=$1
    trap - EXIT INT TERM
    set +e
    if (( layout_done == 0 )); then
      printf 'stage\t%s\nrc\t%s\nepoch\t%s\n' "$layout_stage" "$rc" "$(date +%s)" >"$R1B_STATE/layout-failure-stage.tsv"
      if [[ -f $R1B_STATE/LAYOUT_STARTED ]]; then
        r1b_marker LAYOUT_FAILED; log "LAYOUT_FAILED stage=$layout_stage rc=$rc"
      else
        r1b_marker DATA_PLANE_FAILED; log "DATA_PLANE_FAILED stage=$layout_stage rc=$rc"
      fi
      if (( mount_owned == 1 )) && [[ $MOCK != 1 ]] && findmnt -rn -M "$mnt_b" >/dev/null 2>&1; then
        "$binary" umount "$mnt_b" >>"$R1B_STATE/failure-umount.log" 2>&1
      fi
    fi
    exit "$rc"
  }
  trap '_r1b_layout_exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # === A1: Auth ===
  if [[ $MOCK == 1 ]]; then
    echo "mock-keyring-content" > "$keyring_b"
    [[ "$fail_at" != "auth_exists" ]] || { rm -f "$keyring_b"; die 'mock: auth exists'; }
  else
    sudo ceph auth get-or-create "$auth_b" mon 'allow r' \
      osd "allow class-read object_prefix rbd_directory_pool, allow rwx pool=$POOL_B_R1B" -o "$keyring_b"
    sudo chown "$(id -u):$(id -g)" "$keyring_b"; chmod 600 "$keyring_b"
    # Verify live caps
    sudo ceph auth get "$auth_b" 2>/dev/null | grep -q 'allow r' || die 'auth mon caps verification failed'
    sudo ceph auth get "$auth_b" 2>/dev/null | grep -q "allow class-read object_prefix rbd_directory_pool, allow rwx pool=$POOL_B_R1B" || die 'auth osd caps verification failed'
  fi

  # Use a run-scoped Ceph configuration; do not install credentials in /etc.
  local ceph_conf_b="$R1B_STATE/ceph-r1b.conf"
  if [[ $MOCK != 1 ]]; then
    cp /etc/ceph/ceph.conf "$ceph_conf_b"
    printf '\n[%s]\n\tkeyring = %s\n' "$auth_b" "$keyring_b" >>"$ceph_conf_b"
    chmod 600 "$ceph_conf_b"
    export CEPH_CONF="$ceph_conf_b"
    timeout --signal=TERM --kill-after=5s 30s rados --name "$auth_b" \
      --pool "$POOL_B_R1B" ls >"$R1B_STATE/rados-auth-canary.stdout" \
      2>"$R1B_STATE/rados-auth-canary.stderr" || die 'B CephX read canary failed'
    [[ ! -s $R1B_STATE/rados-auth-canary.stdout ]] || die 'B pool ceased to be empty during auth canary'
  fi

  # === A2: Format ===
  layout_stage=format
  if [[ $MOCK == 1 ]]; then
    printf '{"Setting":{"UUID":"mock-uuid-%s","Name":"jfs-r1b-%s","Bucket":"ceph://%s"}}\n' "$RUN_ID" "$RUN_ID" "$POOL_B_R1B" > "$R1B_STATE/b-status-post-format.json"
  else
    local format_rc
    set +e
    timeout --signal=TERM --kill-after=30s 300s env "CEPH_CONF=$ceph_conf_b" \
      "$binary" format --storage ceph --bucket "ceph://$POOL_B_R1B" \
      --access-key ceph --secret-key "$auth_b" --block-size 256K --trash-days 0 "$meta_b" "jfs-r1b-$RUN_ID" 2>&1 | tee "$R1B_STATE/format-output.txt"
    format_rc=${PIPESTATUS[0]}
    set -e
    [[ $format_rc -eq 0 ]] || die "JuiceFS format failed/timed out rc=$format_rc"
    "$binary" status "$meta_b" > "$R1B_STATE/b-status-post-format.json" 2>/dev/null
  fi
  local b_uuid; b_uuid=$(python3 -c "import json;print(json.load(open('$R1B_STATE/b-status-post-format.json')).get('Setting',{}).get('UUID',''))" 2>/dev/null || echo "")
  [[ -n $b_uuid ]] || die 'format did not produce UUID'
  python3 - "$R1B_STATE/b-status-post-format.json" "$POOL_B_R1B" "$RUN_ID" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('Setting',{})
assert s.get('Name')==f'jfs-r1b-{sys.argv[3]}', f"unexpected Name: {s.get('Name')}"
assert s.get('Bucket')==f'ceph://{sys.argv[2]}', f"unexpected Bucket: {s.get('Bucket')}"
PY
  printf '%s\n' "$b_uuid" > "$R1B_STATE/b-uuid.txt"

  # === A3: RW mount ===
  layout_stage=rw-mount
  mkdir -p "$mnt_b"
  if [[ $MOCK == 1 ]]; then
    : # mock: no real mount
  else
    CEPH_CONF="$ceph_conf_b" "$binary" mount -d --max-fuse-io 256K --max-uploads 150 --cache-size 0 "$meta_b" "$mnt_b"
    sleep 3
  fi
  # Mount identity freeze (RW)
  local rw_pid
  if [[ $MOCK == 1 ]]; then
    rw_pid=$$
    printf 'role\tpid\tppid\tstarttime\texe\tcmdline\nworker\t%s\t%s\t0\tmock\tmock\n' "$$" "$PPID" >"$R1B_STATE/b-rw-identity.tsv"
  else
    rw_pid=$(_r1b_capture_mount_identity "$binary" "$meta_b" "$mnt_b" "$b_uuid" rw "$R1B_STATE/b-rw-identity.tsv") || die 'B RW mount identity failed'
  fi
  mount_owned=1
  mkdir -p "$mnt_b/test_dir"

  # === A4: LAYOUT_STARTED + layout fio ===
  layout_stage=layout
  r1b_marker LAYOUT_STARTED
  if [[ $MOCK == 1 ]]; then
    # Create mock layout files
    local nfiles="${R1_MOCK_LAYOUT_FILES:-128}"
    local bad_size="${R1_MOCK_BAD_FILE_SIZE:-}"
    local extra_prefix="${R1_MOCK_EXTRA_PREFIX_FILE:-}"
    for i in $(seq 0 $((nfiles-1))); do
      if [[ -n $bad_size && $i -eq 50 ]]; then
        truncate -s 536870912 "$mnt_b/test_dir/read_test.$i.0"
      else
        truncate -s 1073741824 "$mnt_b/test_dir/read_test.$i.0"
      fi
    done
    [[ -z $extra_prefix ]] || touch "$mnt_b/test_dir/read_test.extra.0"
    echo "mock fio rc=0" > "$R1B_STATE/layout-fio-output.txt"
    [[ "$fail_at" != "fio_fail" ]] || { log "LAYOUT_FAILED"; r1b_marker LAYOUT_FAILED; die 'mock: fio failed'; }
  else
    fio --directory="$mnt_b/test_dir" --name=read_test --filesize=1G --size=1G --bs=4M --rw=write \
      --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 \
      --group_reporting --end_fsync=1 --write_bw_log="$R1B_STATE/layout" --log_avg_msec=1000 \
      >"$R1B_STATE/layout-fio-output.txt" 2>&1 || { log "LAYOUT_FAILED"; r1b_marker LAYOUT_FAILED; die 'layout fio failed'; }
  fi

  # === A5: File contract verification ===
  _r1b_validate_layout_tree "$mnt_b" "$R1B_STATE/layout-manifest-rw.tsv" || die 'layout file contract failed'

  # === A6: Graceful umount ===
  layout_stage=rw-umount
  if [[ $MOCK == 1 ]]; then
    : # backing data remains visible to the simulated RO remount
  else
    "$binary" umount "$mnt_b"; sleep 5
  fi
  mount_owned=0
  [[ "$fail_at" != "ro_mount_fail" ]] || { log "LAYOUT_FAILED"; r1b_marker LAYOUT_FAILED; die 'mock: RO mount failed'; }

  # === A7: RO mount ===
  layout_stage=ro-mount
  if [[ $MOCK == 1 ]]; then
    : # mock: no real mount
  else
    CEPH_CONF="$ceph_conf_b" "$binary" mount -d --max-fuse-io 256K --max-uploads 150 --cache-size 0 -o ro "$meta_b" "$mnt_b"
    sleep 3
  fi
  # RO identity freeze
  local ro_pid
  if [[ $MOCK == 1 ]]; then
    ro_pid=$$
    printf 'role\tpid\tppid\tstarttime\texe\tcmdline\nworker\t%s\t%s\t0\tmock\tmock\n' "$$" "$PPID" >"$R1B_STATE/b-ro-identity.tsv"
  else
    ro_pid=$(_r1b_capture_mount_identity "$binary" "$meta_b" "$mnt_b" "$b_uuid" ro "$R1B_STATE/b-ro-identity.tsv") || die 'B RO mount identity failed'
  fi
  mount_owned=1
  _r1b_validate_layout_tree "$mnt_b" "$R1B_STATE/layout-manifest-ro.tsv" || die 'RO layout file contract failed'
  cut -f1-2 "$R1B_STATE/layout-manifest-rw.tsv" >"$R1B_STATE/layout-rw-name-size.tsv"
  cut -f1-2 "$R1B_STATE/layout-manifest-ro.tsv" >"$R1B_STATE/layout-ro-name-size.tsv"
  cmp -s "$R1B_STATE/layout-rw-name-size.tsv" "$R1B_STATE/layout-ro-name-size.tsv" || die 'RW/RO layout manifest mismatch'

  # === A8: Stabilization gate ===
  layout_stage=stabilization
  local stab_ok=0 stab_pair_prev=""
  for _ in $(seq 1 60); do
    if [[ $MOCK == 1 ]]; then
      [[ "$fail_at" != "stab_zero" ]] || { log "LAYOUT_FAILED"; r1b_marker LAYOUT_FAILED; die 'mock: objects=0'; }
      [[ "$fail_at" != "stab_short" ]] || { stab_ok=2; break; }  # skip 3-sample for short test
      stab_ok=3; break
    else
      local health_status
      health_status=$(sudo ceph health --format json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
      [[ $health_status == HEALTH_OK ]] || { stab_ok=0; sleep 10; continue; }
      sudo ceph health detail 2>/dev/null | grep -iE 'recovery|backfill' && { stab_ok=0; sleep 10; continue; }
      local pair_now; pair_now=$(sudo ceph df detail --format json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);r=[p for p in d.get('pools',[]) if p.get('name')=='$POOL_B_R1B'];assert len(r)==1;s=r[0].get('stats',{});print(str(int(s.get('objects',0)))+':'+str(int(s.get('stored',0))))" 2>/dev/null || echo '0:0')
      [[ ${pair_now%%:*} -gt 0 && ${pair_now##*:} -gt 0 ]] || { stab_ok=0; sleep 30; continue; }
      printf '%s\t%s\t%s\n' "$(date +%s)" "${pair_now%%:*}" "${pair_now##*:}" >>"$R1B_STATE/layout-stability.tsv"
      if [[ "$pair_now" == "$stab_pair_prev" ]]; then
        stab_ok=$((stab_ok+1)); [[ $stab_ok -ge 3 ]] && break
      else
        stab_ok=1; stab_pair_prev="$pair_now"
      fi
      sleep 30
    fi
  done
  [[ $stab_ok -ge 3 ]] || { log "LAYOUT_FAILED"; r1b_marker LAYOUT_FAILED; die 'stabilization gate failed'; }

  # === A9: Post-success verification ===
  if [[ $MOCK != 1 ]]; then
    # A fingerprint unchanged
    sudo ceph osd pool ls detail --format json 2>/dev/null | python3 -c "
import json,sys;d=json.load(sys.stdin);rows=d if isinstance(d,list) else d.get('pools',[])
a=[p for p in rows if p.get('pool_name')=='juicefs-data']
assert len(a)==1;assert a[0].get('pool_id')==3;assert a[0].get('pg_num')==32" || die 'A fingerprint changed'
    # primary_temp empty, frozen upmap retained, balancer off
    sudo ceph osd dump --format json 2>/dev/null | python3 -c "
import json,sys;d=json.load(sys.stdin);pt=d.get('primary_temp',[])
def pgid(x):
  return str(x.get('pgid',x.get('pg',''))) if isinstance(x,dict) else str(x[0]) if isinstance(x,(list,tuple)) and x else x if isinstance(x,str) else ''
rows=[pgid(x) for x in pt] if isinstance(pt,list) else [str(k) for k in pt] if isinstance(pt,dict) else []
assert not [x for x in rows if x.startswith('$b_pid_pool.')], 'primary_temp residue'" || die 'primary_temp check failed'
    sudo ceph balancer status 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);assert not d.get('active')" || die 'balancer not off'
  fi

  layout_done=1
  trap - EXIT INT TERM
  r1b_marker R1B_LAYOUT_ONCE_PASS; r1b_append r1b-layout-once PASS
  log "R1B_LAYOUT_ONCE_PASS uuid=$b_uuid"
}

cmd_r1b_l1_screen() {
  local bw_only=${R1B_L1_BW_ONLY:-0}
  local resume_after_w01=${R1B_L1_RESUME_AFTER_W01:-0}
  [[ $bw_only == 0 || $bw_only == 1 ]] || die 'R1B_L1_BW_ONLY must be 0 or 1'
  [[ $resume_after_w01 == 0 || $resume_after_w01 == 1 ]] || die 'R1B_L1_RESUME_AFTER_W01 must be 0 or 1'
  [[ $resume_after_w01 == 0 || $bw_only == 1 ]] || die 'resume-after-W01 is allowed only in bandwidth-only mode'
  r1b_need R1B_PLAN_DATA_L1_COMPLETE
  if [[ ! -f $R1B_STATE/R1B_LAYOUT_ONCE_PASS && ! -f $R1B_STATE/R1B_LAYOUT_ADOPTED_PASS ]]; then
    die 'missing layout marker (R1B_LAYOUT_ONCE_PASS or R1B_LAYOUT_ADOPTED_PASS)'
  fi
  r1b_no R1B_L1_SCREEN_DONE
  [[ ${R1B_L1_ACK:-} == "I_ACK_R1B_L1_${RUN_ID}" ]] || die 'missing exact R1B L1 ACK'
  [[ ${R1_SCRUB_ACK:-} == "I_ACK_GLOBAL_CEPH_SCRUB_PAUSE" ]] || die 'missing exact global scrub pause ACK'
  local b_pool_id; b_pool_id=$(contract_r1b_pool_id)
  local plan_path="$R1B_RESULT_ROOT/plans/primary-toggle-plan.json"
  local sha_path="$R1B_RESULT_ROOT/plans/primary-toggle.sha256"
  [[ -f $plan_path ]] || die 'primary-toggle-plan.json missing'
  [[ -f $sha_path ]] || die 'primary-toggle.sha256 missing'
  ( cd "$R1B_RESULT_ROOT/plans" && sha256sum -c primary-toggle.sha256 >/dev/null 2>&1 ) || die 'primary-toggle plan SHA mismatch'
  [[ -f $R1B_RESULT_ROOT/plans/plan-data-l1.sha256 ]] || die 'plan-data-l1.sha256 missing'
  ( cd "$R1B_RESULT_ROOT/plans" && sha256sum -c plan-data-l1.sha256 >/dev/null 2>&1 ) || die 'L1 execution/rollback plan SHA mismatch'

  # All shared helpers must write into the 04-1b run, never the superseded
  # 04-1 result root.  Rebind before scrub/sampler/incident handling.
  RESULT_ROOT=$R1B_RESULT_ROOT
  STATE=$R1B_STATE
  SCRUB_STATE_DIR="$R1B_STATE/scrub-leases"

  # Worker identity from adopted identity or live proc
  local b_mount_pid
  if [[ -f $R1B_STATE/b-ro-adopted-identity.tsv ]]; then
    b_mount_pid=$(awk -F'\t' '/^ro_pid/{print $2}' "$R1B_STATE/b-ro-adopted-identity.tsv")
  elif [[ -f $R1B_STATE/b-ro-identity.tsv ]]; then
    b_mount_pid=$(awk -F'\t' '/^ro_pid/{print $2}' "$R1B_STATE/b-ro-identity.tsv")
  else
    b_mount_pid=$(pgrep -f "jfs-r1b-${RUN_ID}" 2>/dev/null | head -1 || true)
  fi
  [[ -n $b_mount_pid ]] || die 'cannot determine B mount PID'
  kill -0 "$b_mount_pid" 2>/dev/null || die "B mount PID $b_mount_pid not running"
  # Verify cmdline contains --read-only (skip in mock)
  if [[ $MOCK != 1 ]]; then
    cat /proc/$b_mount_pid/cmdline 2>/dev/null | tr '\0' ' ' | grep -q '\-\-read-only' || die 'B mount cmdline does not contain --read-only'
  fi
  local b_mnt="/tmp/jfs-r1b-${RUN_ID}-mnt"

  # Set R1B-aware sampler result root
  export R1_SAMPLER_RESULT_ROOT="$R1B_RESULT_ROOT"
  # The workload is direct=1 with JuiceFS cache disabled.  Do not evict the
  # page cache of unrelated Weka/K8s/business processes co-located on 157.
  export R1_SKIP_LOCAL_DROP_CACHES=1

  if [[ $MOCK == 1 ]]; then
    mkdir -p "$R1B_STATE" "$R1B_RESULT_ROOT/warmup" "$SCRUB_STATE_DIR"
    FIO_CALL_COUNT=0
    # Mock scrub lease: use real scrub_pause, no || true
    scrub_pause "${RUN_ID}-phase-a" "mock-fsid"
    ACTIVE_LEASE="${RUN_ID}-phase-a"
    local rounds=(W01:N W02:S W03:S W04:N)
    for entry in "${rounds[@]}"; do
      local round="${entry%%:*}" cond="${entry##*:}"
      local rdir="$R1B_RESULT_ROOT/warmup/$round"
      mkdir -p "$rdir/bw"
      printf '%s\t%s\n' "$round" "$cond" >"$rdir/condition.tsv"
      scrub_verify_paused "$ACTIVE_LEASE"
      round_sampler_start "$round" || die "mock sampler start failed $round"
      : $(( ++FIO_CALL_COUNT ))
      # Check failpoint: fio fail at W02
      if [[ -n ${R1B_FAILPOINT:-} && "$round" == "$R1B_FAILPOINT" ]]; then
        incident ERROR "round-$round" "fio failed (failpoint)"
        # Unified cleanup: close sampler, clear S, restore scrub
        round_sampler_close "$round" "$rdir"
        scrub_log_call primary_temp_clear "$round" pass mock
        scrub_restore "$ACTIVE_LEASE"; ACTIVE_LEASE=""
        die "fio failpoint triggered at $round (fio_count=$FIO_CALL_COUNT)"
      fi
      printf 'mock round %s\nREAD: bw=6000MiB/s\nrun=180000-180000msec\n' "$round" >"$rdir/fio.txt"
      for j in $(seq 1 128); do : > "$rdir/bw/read_test_bw.${j}.log"; done
      printf '%s\n' "$(date +%s%N)" >"$rdir/fio-start-ns.txt"
      printf '%s\n' "$(date +%s%N)" >"$rdir/fio-end-ns.txt"
      local mock_iop; case "$round" in W01) mock_iop=1.13;; W02) mock_iop=1.02;; W03) mock_iop=1.03;; W04) mock_iop=1.12;; esac
      printf '{"osd":{"I_op":%s}}\n' "$mock_iop" >"$rdir/osd-analysis.json"
      printf '{"status":"HEALTH_OK","checks":{}}\n' >"$rdir/health-pre.json"
      printf '{"status":"HEALTH_OK","checks":{}}\n' >"$rdir/health-post.json"
      # Check failpoint: sampler close fail
      if [[ -n ${R1B_FAILPOINT_SAMPLER_CLOSE:-} && "$round" == "$R1B_FAILPOINT_SAMPLER_CLOSE" ]]; then
        # Simulate close failure
        printf 'FATAL\tsampler_close_failed\t%s\n' "$round" >>"$R1B_STATE/incidents.tsv"
        r1b_marker R1B_L1_FATAL
        scrub_log_call primary_temp_clear "$round" pass mock
        scrub_restore "$ACTIVE_LEASE"; ACTIVE_LEASE=""
        die "sampler close failpoint at $round"
      fi
      round_sampler_close "$round" "$rdir"
      scrub_verify_paused "$ACTIVE_LEASE"
    done
    # R1B analyzer via real path (no direct JSON write)
    python3 "$ANALYZER" r1b-manipulation \
      --inputs "$R1B_RESULT_ROOT"/warmup/W0{1,2,3,4}/osd-analysis.json \
      --output "$R1B_RESULT_ROOT/warmup/l1-analysis.json" >"$R1B_RESULT_ROOT/warmup/l1-analyzer-console.txt"
    # Check failpoint: scrub restore fail
    if [[ -n ${R1B_FAILPOINT_SCRUB_RESTORE:-} ]]; then
      printf 'FATAL\tscrub_restore_failed\t%s\n' "$ACTIVE_LEASE" >>"$R1B_STATE/incidents.tsv"
      r1b_marker R1B_L1_FATAL
      ACTIVE_LEASE=""
      die "scrub restore failpoint triggered"
    fi
    scrub_restore "$ACTIVE_LEASE"
    ACTIVE_LEASE=""
    # Check failpoint: missing W03 input
    if [[ -n ${R1B_FAILPOINT_MISSING_W03:-} ]]; then
      rm -f "$R1B_RESULT_ROOT/warmup/W03/osd-analysis.json"
      if python3 "$ANALYZER" r1b-manipulation \
        --inputs "$R1B_RESULT_ROOT"/warmup/W0{1,2,4}/osd-analysis.json \
        --output "$R1B_RESULT_ROOT/warmup/l1-analysis-fail.json" 2>/dev/null; then
        die "analyzer should reject missing W03"
      fi
      log "R1B_L1 analyzer correctly rejected missing W03"
      r1b_append r1b-l1-screen FAIL
      return 0
    fi
    r1b_marker R1B_L1_SCREEN_DONE; r1b_append r1b-l1-screen PASS
    log "R1B_L1_SCREEN_PASS (mock)"
    return 0
  fi

  require_real_ceph
  [[ -n $SSH_PASSWORD ]] || die 'R1_SSH_PASSWORD is required for OSD samplers and cache drop'
  command -v sshpass >/dev/null || die 'sshpass missing'
  command -v fio >/dev/null || die 'fio missing'
  [[ -x /tmp/juicefs-1.4.1-patched ]] || die 'frozen JuiceFS binary missing/not executable'
  # Pre-checks
  sudo ceph health --format json >"$R1B_STATE/health-pre-l1.json"
  python3 - "$R1B_STATE/health-pre-l1.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1])); assert h.get("status")=="HEALTH_OK"
PY
  ! sudo ceph health detail 2>/dev/null | grep -iE 'recovery|backfill|degraded' || die 'recovery active'
  # Verify S state
  sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-pre-l1.json"
  python3 - "$R1B_STATE/osd-dump-pre-l1.json" "$b_pool_id" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
pt=d.get("primary_temp",[])
b_pt=[str(x.get("pgid","")) for x in pt if isinstance(x,dict) and str(x.get("pgid","")).startswith(pid+".")] if isinstance(pt,list) else []
assert not b_pt, f"primary_temp not empty: {b_pt}"
PY

  # Scrub lease via u141d-scrub-control.sh
  local fsid; fsid=$(sudo ceph fsid 2>/dev/null | tr -d '[:space:]')
  [[ -n $fsid ]] || die 'cannot determine Ceph FSID'
  local lease="${RUN_ID}-phase-a"
  # The scrub controller deliberately accepts only phase-a|b leases and
  # forbids reusing an audited state file. Attempt 2 consumed phase-a, so the
  # one-shot bandwidth closure uses the still-valid phase-b slot.
  [[ $bw_only == 1 ]] && lease="${RUN_ID}-phase-b"
  scrub_pause "$lease" "$fsid"
  ACTIVE_LEASE="$lease"

  # Restore without calling die/exit so failure cleanup can attempt every step.
  _r1b_l1_restore_noexit() {
    local restore_lease=$1
    U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" plan-restore "$restore_lease" &&
      U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" restore "$restore_lease" &&
      U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" verify-restored "$restore_lease"
  }

  # EXIT, not ERR: die() uses exit and therefore does not trigger an ERR trap.
  # On every abnormal exit attempt sampler close, S restore and scrub restore.
  local l1_done=0
  _r1b_l1_exit() {
    local original_rc=$1 trap_rc=0 cmd
    trap - EXIT INT TERM
    set +e
    # F1: Close active sampler
    if [[ -n $ACTIVE_SAMPLER_LABEL ]]; then
      round_sampler_close "$ACTIVE_SAMPLER_LABEL" "$R1B_RESULT_ROOT/warmup/$ACTIVE_SAMPLER_LABEL"
      if [[ $? -ne 0 ]]; then
        printf 'FATAL\tsampler_close_failed\t%s\n' "$ACTIVE_SAMPLER_LABEL" >>"$R1B_STATE/incidents.tsv"
        trap_rc=1
      fi
    fi
    # F2: Clear primary_temp to S
    while IFS= read -r cmd; do
      [[ -z $cmd ]] && continue
      if ! eval "$cmd"; then
        printf 'FATAL\tprimary_temp_clear_failed\t%s\n' "$cmd" >>"$R1B_STATE/incidents.tsv"
        trap_rc=1
      fi
    done <"$R1B_RESULT_ROOT/plans/primary-toggle-s-clear.txt"
    # F3: Verify no candidate-pool primary_temp remains.
    sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-failure-close.json" 2>/dev/null
    python3 - "$R1B_STATE/osd-dump-failure-close.json" "$b_pool_id" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]
def pgid(x):
  if isinstance(x,dict): return str(x.get('pgid',x.get('pg','')))
  if isinstance(x,(list,tuple)) and x: return str(x[0])
  return str(x) if isinstance(x,str) else ''
pt=d.get('primary_temp',[])
rows=[pgid(x) for x in pt] if isinstance(pt,list) else [str(x) for x in pt] if isinstance(pt,dict) else []
assert not [x for x in rows if x.startswith(pid+'.')]
PY
    if [[ $? -ne 0 ]]; then
      printf 'FATAL\tprimary_temp_verify_failed\tpool_id=%s\n' "$b_pool_id" >>"$R1B_STATE/incidents.tsv"
      trap_rc=1
    fi
    # F4: scrub_restore
    if [[ -n $ACTIVE_LEASE ]]; then
      if ! _r1b_l1_restore_noexit "$ACTIVE_LEASE" >>"$R1B_STATE/scrub-restore-failure.log" 2>&1; then
        printf 'FATAL\tscrub_restore_failed\t%s\n' "$ACTIVE_LEASE" >>"$R1B_STATE/incidents.tsv"
        trap_rc=1
      fi
      ACTIVE_LEASE=""
    fi
    # F5: Every abnormal exit is fatal even when rollback succeeds.
    r1b_marker R1B_L1_FATAL
    printf 'FATAL\tl1_abnormal_exit\toriginal_rc=%s cleanup_rc=%s\n' "$original_rc" "$trap_rc" >>"$R1B_STATE/incidents.tsv"
    (( original_rc != 0 )) || original_rc=42
    exit "$original_rc"
  }
  trap '_r1b_l1_exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  mkdir -p "$R1B_RESULT_ROOT/warmup"
  FIO_CALL_COUNT=0

  # Clock sync check (4 nodes, ≤100ms)
  local max_offset=0 t157; t157=$(date +%s%3N)
  for host in $(echo "$OSD_HOSTS" | tr ',' ' '); do
    local t_before t_after t_mid
    t_before=$(date +%s%3N)
    local thost; thost=$(ssh_cmd "$host" "date +%s%3N" 2>/dev/null) || die "cannot reach $host for clock check"
    t_after=$(date +%s%3N)
    t_mid=$(( (t_before + t_after) / 2 ))
    local offset=$(( t_mid - thost )); [[ $offset -lt 0 ]] && offset=$(( -offset ))
    printf 'clock\t%s\t157_mid=%s\tremote=%s\toffset=%sms\n' "$host" "$t_mid" "$thost" "$offset" >>"$R1B_STATE/clock-sync.tsv"
    [[ $offset -le 100 ]] || die "clock offset ${offset}ms > 100ms for $host"
    [[ $offset -gt $max_offset ]] && max_offset=$offset
  done
  log "R1B_L1: clock sync OK max_offset=${max_offset}ms"

  # Layout frozen values for per-round comparison
  local frozen_objects frozen_stored
  frozen_objects=$(sudo ceph df --format json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);[print(p.get('stats',{}).get('objects',0)) for p in d.get('pools',[]) if p.get('name')=='$POOL_B_R1B']")
  frozen_stored=$(sudo ceph df --format json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);[print(p.get('stats',{}).get('stored',0)) for p in d.get('pools',[]) if p.get('name')=='$POOL_B_R1B']")
  log "R1B_L1: frozen objects=$frozen_objects stored=$frozen_stored"

  local rounds=(W01:N W02:S W03:S W04:N)
  if [[ $resume_after_w01 == 1 ]]; then
    local prior_w01="$R1B_RESULT_ROOT/warmup/W01"
    [[ -f $prior_w01/fio.txt && -f $prior_w01/fio.rc && $(<"$prior_w01/fio.rc") == 0 ]] \
      || die 'resume requested but prior W01 fio evidence is missing/nonzero'
    [[ $(find "$prior_w01/bw" -name '*.log' 2>/dev/null | wc -l) -eq 128 ]] \
      || die 'resume requested but prior W01 bw logs are incomplete'
    rounds=(W02:S W03:S W04:N)
    FIO_CALL_COUNT=1
    log 'R1B_L1: bandwidth-only resume accepts frozen W01 and runs W02..W04'
  fi

  for entry in "${rounds[@]}"; do
    local round="${entry%%:*}" cond="${entry##*:}"
    local rdir="$R1B_RESULT_ROOT/warmup/$round"
    mkdir -p "$rdir/bw"
    printf '%s\t%s\n' "$round" "$cond" >"$rdir/condition.tsv"
    log "R1B_L1 $round=$cond"

    # N/S condition switch
    if [[ $cond == N ]]; then
      while IFS= read -r cmd; do
        [[ -z $cmd ]] && continue
        eval "$cmd" || die "N apply failed in $round: $cmd"
      done <"$R1B_RESULT_ROOT/plans/primary-toggle-n-apply.txt"
    elif [[ $round == W03 ]]; then
      # W03 S→S: save epoch before, verify no OSDMap writes
      local epoch_before
      epoch_before=$(sudo ceph osd dump --format json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('epoch',''))")
      printf '%s\n' "$epoch_before" >"$rdir/epoch-before.txt"
    else
      while IFS= read -r cmd; do
        [[ -z $cmd ]] && continue
        eval "$cmd" || log "S_CLEAR_WARN: $cmd"
      done <"$R1B_RESULT_ROOT/plans/primary-toggle-s-clear.txt"
    fi

    _r1b_wait_clean "$b_pool_id"

    # Verify condition histogram dynamically
    sudo ceph pg dump pgs_brief --format json >"$rdir/pg-state.json" 2>/dev/null
    python3 - "$rdir/pg-state.json" "$b_pool_id" "$cond" "$R1B_STATE/registered-map.json" "$R1B_STATE/steered-map.json" <<'PY'
import json,sys
from collections import Counter
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; cond=sys.argv[3]; nat_f=sys.argv[4]; st_f=sys.argv[5]
rows=d.get("pg_stats",d.get("pg_map",{}).get("pg_stats",[]))
pgs=[r for r in rows if str(r.get("pgid","")).split(".")[0]==pid]
assert len(pgs)==64
prim=Counter()
for r in pgs:
  p=r.get("primary",r.get("acting_primary"))
  if p is None: p=r.get("acting",[0])[0]
  prim[int(p)]+=1
def _hist(f):
  m=json.load(open(f)); rs=[r for r in m.get("pg_stats",[]) if str(r.get("pgid","")).split(".")[0]==str(pid)]
  assert len(rs)==64
  return {o:sum(1 for r in rs if int(r.get("primary",r.get("acting_primary",r.get("acting",[0])[0])))==o) for o in range(6)}
actual={o:prim[o] for o in range(6)}
if cond=="N":
  target=_hist(nat_f); assert actual==target, f"N hist mismatch: {actual} != {target}"
elif cond=="S":
  target=_hist(st_f); assert actual==target, f"S hist mismatch: {actual} != {target}"
PY

    # Per-round pre-checks
    sudo ceph health detail --format json >"$rdir/health-pre.json"
    check_health_json "$rdir/health-pre.json" pre "$round"
    # Compare objects/stored (not just print)
    local cur_objects cur_stored
    cur_objects=$(sudo ceph df --format json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);[print(p.get('stats',{}).get('objects',0)) for p in d.get('pools',[]) if p.get('name')=='$POOL_B_R1B']")
    cur_stored=$(sudo ceph df --format json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);[print(p.get('stats',{}).get('stored',0)) for p in d.get('pools',[]) if p.get('name')=='$POOL_B_R1B']")
    [[ "$cur_objects" == "$frozen_objects" ]] || die "$round: objects changed: $cur_objects != $frozen_objects"
    [[ "$cur_stored" == "$frozen_stored" ]] || die "$round: stored changed: $cur_stored != $frozen_stored"

    drop_caches_all
    scrub_verify_paused "$ACTIVE_LEASE"

    # fio version + 128 file hard check
    local fio_ver; fio_ver=$(fio --version 2>/dev/null)
    [[ "$fio_ver" == "fio-3.28" ]] || die "fio version mismatch: $fio_ver"
    local file_count; file_count=$(find "$b_mnt/test_dir" -maxdepth 1 -name 'read_test.*.0' -size 1073741824c | wc -l)
    [[ $file_count -eq 128 ]] || die "$round: file count=$file_count, expected 128"

    # The bandwidth-only closure path is intentionally sampler-free.  The
    # local admin-socket collector is unavailable on these containerized OSD
    # nodes; repairing that auxiliary mechanism is outside this screening run.
    if [[ $bw_only == 0 ]]; then
      round_sampler_start "$round" || { incident ERROR "round-$round" 'sampler start failed'; die "sampler start failed label=$round"; }
      sleep 5
    fi
    printf '%s\n' "$(date +%s%N)" >"$rdir/fio-start-ns.txt"
    : $(( ++FIO_CALL_COUNT ))
    printf '%s\n' "$FIO_CALL_COUNT" >"$R1B_STATE/fio_call_count"
    set +e
    fio --directory="$b_mnt/test_dir" --name=read_test --filesize=1G --size=1G --bs=256k --rw=randread \
      --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
      --allow_file_create=0 --readonly --group_reporting --time_based --runtime=180 \
      --write_bw_log="$rdir/bw/read_test" --log_avg_msec=1000 >"$rdir/fio.txt" 2>"$rdir/fio.stderr"
    local fio_rc=$?
    set -e
    printf '%s\n' "$fio_rc" >"$rdir/fio.rc"
    printf '%s\n' "$(date +%s%N)" >"$rdir/fio-end-ns.txt"
    if [[ $fio_rc -ne 0 ]]; then
      incident ERROR "round-$round" "fio failed rc=$fio_rc"
      # Close a sampler only when this mode actually started one; the EXIT
      # trap remains responsible for all condition/scrub restoration.
      if [[ $bw_only == 0 ]]; then
        round_sampler_close "$round" "$rdir"
      fi
      die "fio failed label=$round rc=$fio_rc"
    fi
    if [[ $bw_only == 0 ]]; then
      sleep 5
      round_sampler_close "$round" "$rdir" || { incident ERROR "round-$round" 'sampler close failed'; die "sampler close failed label=$round"; }

      # OSD analysis
      python3 "$ANALYZER" osd --round-dir "$rdir" --output "$rdir/osd-analysis.json" >"$rdir/analyzer-console.txt"
    fi

    # Per-round post-checks
    sudo ceph health detail --format json >"$rdir/health-post.json"
    check_health_json "$rdir/health-post.json" post "$round"
    scrub_verify_paused "$ACTIVE_LEASE"

    # W03 epoch comparison
    if [[ $round == W03 ]]; then
      local epoch_after
      epoch_after=$(sudo ceph osd dump --format json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('epoch',''))")
      printf '%s\n' "$epoch_after" >"$rdir/epoch-after.txt"
      [[ "$epoch_after" == "$epoch_before" ]] || die "W03: OSDMap epoch changed: $epoch_before → $epoch_after"
    fi
  done

  # Restore S
  while IFS= read -r cmd; do
    [[ -z $cmd ]] && continue
    eval "$cmd" || die "post-L1 S clear failed: $cmd"
  done <"$R1B_RESULT_ROOT/plans/primary-toggle-s-clear.txt"
  _r1b_wait_clean "$b_pool_id"

  if ! _r1b_l1_restore_noexit "$ACTIVE_LEASE" >"$R1B_STATE/scrub-restore-success.log" 2>&1; then
    printf 'FATAL\tscrub_restore_failed_post\t%s\n' "$lease" >>"$R1B_STATE/incidents.tsv"
    die 'scrub restore failed'
  fi
  ACTIVE_LEASE=""

  # Final live-state closure: S condition, frozen upmap, immutable data and mount.
  sudo ceph osd dump --format json >"$R1B_STATE/osd-dump-post-l1.json" 2>/dev/null
  python3 - "$R1B_STATE/osd-dump-post-l1.json" "$b_pool_id" "$R1B_RESULT_ROOT/plans/upmap-plan.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=sys.argv[2]; plan=json.load(open(sys.argv[3]))
def pgid(x):
  if isinstance(x,dict): return str(x.get('pgid',x.get('pg','')))
  if isinstance(x,(list,tuple)) and x: return str(x[0])
  return str(x) if isinstance(x,str) else ''
pt=d.get('primary_temp',[])
pts=[pgid(x) for x in pt] if isinstance(pt,list) else [str(x) for x in pt] if isinstance(pt,dict) else []
assert not [x for x in pts if x.startswith(pid+'.')], pts
um=d.get('pg_upmap',[])
ums={pgid(x) for x in um if pgid(x).startswith(pid+'.')} if isinstance(um,list) else {str(x) for x in um if str(x).startswith(pid+'.')} if isinstance(um,dict) else set()
expected={str(x.get('pgid','')) for x in plan.get('upmap_commands',[])}
assert expected and ums==expected, (sorted(ums),sorted(expected))
PY
  sudo ceph pg dump pgs_brief --format json >"$R1B_STATE/pg-state-post-l1.json" 2>/dev/null
  python3 - "$R1B_STATE/pg-state-post-l1.json" "$b_pool_id" "$R1B_STATE/steered-map.json" <<'PY'
import json,sys
from collections import Counter
def rows(path,pid):
  d=json.load(open(path)); xs=d.get('pg_stats',d.get('pg_map',{}).get('pg_stats',[]))
  return [x for x in xs if str(x.get('pgid','')).split('.',1)[0]==str(pid)]
def primary(x): return int(x.get('primary',x.get('acting_primary',x.get('acting',[0])[0])))
actual=rows(sys.argv[1],sys.argv[2]); frozen=rows(sys.argv[3],sys.argv[2])
assert len(actual)==len(frozen)==64
assert Counter(map(primary,actual))==Counter(map(primary,frozen))
assert all('active+clean' in str(x.get('state','active+clean')) for x in actual)
PY
  local final_objects final_stored
  final_objects=$(sudo ceph df --format json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);[print(p.get('stats',{}).get('objects',0)) for p in d.get('pools',[]) if p.get('name')=='$POOL_B_R1B']")
  final_stored=$(sudo ceph df --format json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);[print(p.get('stats',{}).get('stored',0)) for p in d.get('pools',[]) if p.get('name')=='$POOL_B_R1B']")
  [[ $final_objects == "$frozen_objects" && $final_stored == "$frozen_stored" ]] || die 'candidate data changed during L1'
  kill -0 "$b_mount_pid" 2>/dev/null || die 'B mount PID changed/stopped during L1'
  if [[ -f $R1B_STATE/b-ro-adopted-identity.tsv ]]; then
    local frozen_start live_start
    frozen_start=$(awk -F'\t' '/^ro_start/{print $2}' "$R1B_STATE/b-ro-adopted-identity.tsv" | sed 's/^ *//;s/ *$//')
    live_start=$(ps -o lstart= -p "$b_mount_pid" 2>/dev/null | sed 's/^ *//;s/ *$//')
    [[ -n $frozen_start && $live_start == "$frozen_start" ]] || die 'B mount PID starttime changed during L1'
  fi
  local meta_b="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/jfs-r1b-${RUN_ID}-b"
  cat "/proc/$b_mount_pid/cmdline" 2>/dev/null | tr '\0' ' ' | grep -Fq -- "$meta_b" || die 'B mount META identity changed during L1'
  local live_uuid frozen_uuid
  frozen_uuid=$(cat "$R1B_STATE/b-uuid.txt")
  live_uuid=$(/tmp/juicefs-1.4.1-patched status "$meta_b" 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('Setting',{}).get('UUID',''))")
  [[ -n $live_uuid && $live_uuid == "$frozen_uuid" ]] || die 'B volume UUID changed during L1'
  local health_ok=0
  for _ in $(seq 1 12); do
    sudo ceph health detail --format json >"$R1B_STATE/health-post-l1.json" 2>/dev/null
    if python3 - "$R1B_STATE/health-post-l1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d.get('status')=='HEALTH_OK' and not d.get('checks',{})
PY
    then health_ok=1; break; fi
    sleep 5
  done
  [[ $health_ok -eq 1 ]] || die 'post-L1 Ceph health did not return to exact HEALTH_OK'

  # Verify all 4 rounds exist before analysis
  for r in W01 W02 W03 W04; do
    local f="$R1B_RESULT_ROOT/warmup/$r/osd-analysis.json"
    [[ -f "$R1B_RESULT_ROOT/warmup/$r/fio.txt" ]] || die "missing $r/fio.txt"
    [[ $(cat "$R1B_RESULT_ROOT/warmup/$r/fio.rc") == 0 ]] || die "$r fio.rc missing/nonzero"
    if [[ $bw_only == 0 ]]; then
      [[ -f $f ]] || die "missing $r/osd-analysis.json; cannot analyze"
      local host_suffix
      for host_suffix in 150 151 152; do
        local osd_dir="$R1B_RESULT_ROOT/warmup/$r/osd-$host_suffix"
        [[ -f $osd_dir/SAMPLER_PASS ]] || die "missing $r/osd-$host_suffix/SAMPLER_PASS"
        [[ -f $osd_dir/process.rc && $(cat "$osd_dir/process.rc") == 0 ]] || die "$r/osd-$host_suffix process.rc missing/nonzero"
        [[ -s $osd_dir/osd-perf.tsv && -s $osd_dir/heartbeat.tsv ]] || die "$r/osd-$host_suffix sampler TSV missing/empty"
        compgen -G "$osd_dir/schema-osd-*.json" >/dev/null || die "$r/osd-$host_suffix schema evidence missing"
      done
    fi
    local bw_count; bw_count=$(find "$R1B_RESULT_ROOT/warmup/$r/bw" -name '*.log' | wc -l)
    [[ $bw_count -eq 128 ]] || die "$r: bw log count=$bw_count, expected 128"
  done

  if [[ $bw_only == 1 ]]; then
    python3 - "$R1B_RESULT_ROOT/warmup" <<'PY'
import json,re,statistics,sys
from pathlib import Path
root=Path(sys.argv[1]); values={}
for r in ('W01','W02','W03','W04'):
    text=(root/r/'fio.txt').read_text(errors='replace')
    m=re.search(r'READ:.*?BW=([0-9.]+)([KMG]iB)/s',text)
    if not m: raise SystemExit(f'missing READ BW in {r}/fio.txt')
    v=float(m.group(1)); unit=m.group(2)
    v *= {'KiB':1/1024,'MiB':1,'GiB':1024}[unit]
    values[r]=v
n=statistics.mean([values['W01'],values['W04']])
s=statistics.mean([values['W02'],values['W03']])
result={'scope':'bandwidth-only-screen','round_MiBs':values,
        'N_mean_MiBs':n,'S_mean_MiBs':s,'S_minus_N_pct':(s/n-1)*100,
        'N_pair_spread_pct':abs(values['W01']-values['W04'])/n*100,
        'S_pair_spread_pct':abs(values['W02']-values['W03'])/s*100,
        'mechanism_I_op':'not_measured'}
(root/'l1-bandwidth-only.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
print(json.dumps(result,sort_keys=True))
PY
    r1b_marker R1B_L1_BW_ONLY_DONE
    r1b_append r1b-l1-bandwidth-only PASS
  else
    # R1B manipulation analysis via real analyzer
    python3 "$ANALYZER" r1b-manipulation \
      --inputs "$R1B_RESULT_ROOT"/warmup/W0{1,2,3,4}/osd-analysis.json \
      --output "$R1B_RESULT_ROOT/warmup/l1-analysis.json" >"$R1B_RESULT_ROOT/warmup/l1-analyzer-console.txt"
    r1b_marker R1B_L1_SCREEN_DONE
    r1b_append r1b-l1-screen PASS
  fi

  l1_done=1
  trap - EXIT INT TERM
  if [[ $bw_only == 1 ]]; then
    log "R1B_L1_BW_ONLY_PASS"
  else
    log "R1B_L1_SCREEN_PASS"
  fi
}

cmd_r1b_adopt_layout_ro_mount() {
  r1b_need LAYOUT_FAILED; r1b_no R1B_LAYOUT_ADOPTED_PASS
  [[ ${R1B_ADOPT_LAYOUT_RO_ACK:-} == "I_ACK_R1B_ADOPT_LAYOUT_RO_${RUN_ID}" ]] || die 'missing exact R1B adopt-layout-ro ACK'
  if [[ $MOCK == 1 ]]; then
    r1b_marker R1B_LAYOUT_ADOPTED_PASS; r1b_append r1b-adopt-layout-ro-mount PASS
    log "R1B_LAYOUT_ADOPTED_PASS (mock)"
    return 0
  fi
  require_real_ceph
  local binary="/tmp/juicefs-1.4.1-patched"
  local meta_b="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/jfs-r1b-${RUN_ID}-b"
  local keyring_b="/tmp/jfs-r1b-${RUN_ID}.ceph.keyring"
  local mnt_b="/tmp/jfs-r1b-${RUN_ID}-mnt"
  local b_uuid_file="$R1B_STATE/b-uuid.txt"
  local rw_manifest="$R1B_STATE/layout-manifest-rw.tsv"
  # Pre-checks
  [[ -f $b_uuid_file ]] || die 'b-uuid.txt missing'
  local frozen_uuid; frozen_uuid=$(cat "$b_uuid_file")
  [[ -f $rw_manifest ]] || die 'layout-manifest.txt missing'
  # Verify failure stage is ro-mount
  local stage_file="$R1B_STATE/layout-failure-stage.tsv"
  if [[ -f $stage_file ]]; then
    grep -qi 'ro-mount\|ro.mount' "$stage_file" || die 'LAYOUT_FAILED stage is not ro-mount'
  else
    die 'layout-failure-stage.tsv missing; cannot verify failure stage'
  fi
  # Verify current mount exists and is rw (the failed RO mount)
  mount | grep -q "$mnt_b" || die 'no current mount found'
  findmnt -rn -M "$mnt_b" -o OPTIONS | grep -q '\bro\b' && die 'current mount is already ro (unexpected)'
  # Lock current mount identity
  local old_pids
  old_pids=$(pgrep -f "jfs-r1b-${RUN_ID}" | tr '\n' ' ')
  [[ -n $old_pids ]] || die 'no mount processes found'
  log "R1B_ADOPT: current mount PIDs: $old_pids"
  # Step 1: Graceful umount
  "$binary" umount "$mnt_b" 2>&1 | tee "$R1B_STATE/adopt-umount-output.txt"
  sleep 5
  ! mount | grep -q "$mnt_b" || die 'umount failed: mount still exists'
  local remaining_pids
  remaining_pids=$(pgrep -f "jfs-r1b-${RUN_ID}" 2>/dev/null | tr '\n' ' ' || true)
  [[ -z $remaining_pids ]] || die "umount failed: processes still running: $remaining_pids"
  log "R1B_ADOPT: umount successful"
  # Step 2: Remount with --read-only
  CEPH_ARGS="--keyring $keyring_b" "$binary" mount -d --max-fuse-io 256K --max-uploads 150 --cache-size 0 --read-only "$meta_b" "$mnt_b"
  sleep 3
  # Step 3: Verify RO mount
  local new_pids
  new_pids=$(pgrep -f "jfs-r1b-${RUN_ID}" 2>/dev/null | head -1 || true)
  [[ -n $new_pids ]] || die 'RO remount failed: no process'
  mount | grep -q "$mnt_b" || die 'RO remount failed: not in mount table'
  # JuiceFS --read-only doesn't produce 'ro' in FUSE findmnt options; verify by write test
  local ro_test_file="$mnt_b/.r1b_ro_test_$$"
  if echo "test" > "$ro_test_file" 2>/dev/null; then
    find "$ro_test_file" -delete 2>/dev/null || true
    die 'RO remount failed: mount is writable (write test succeeded)'
  fi
  log "R1B_ADOPT: RO verified by write test (write rejected)"
  log "R1B_ADOPT: RO remount successful, PID=$new_pids"
  # Step 4: Freeze new identity
  printf 'ro_pid\t%s\nro_start\t%s\n' "$new_pids" "$(ps -o lstart= -p "$new_pids" 2>/dev/null)" >"$R1B_STATE/b-ro-adopted-identity.tsv"
  # Step 5: Verify UUID
  "$binary" status "$meta_b" >"$R1B_STATE/b-status-post-adopt.json" 2>/dev/null
  local live_uuid; live_uuid=$(python3 -c "import json;print(json.load(open('$R1B_STATE/b-status-post-adopt.json')).get('Setting',{}).get('UUID',''))")
  [[ "$live_uuid" == "$frozen_uuid" ]] || die "UUID mismatch: live=$live_uuid frozen=$frozen_uuid"
  # Step 6: Verify 128 files name/size (read-only, no write)
  local ro_file_count
  ro_file_count=$(find "$mnt_b" -maxdepth 2 -name 'read_test.*.0' -size 1073741824c | wc -l)
  [[ $ro_file_count -eq 128 ]] || die "RO manifest file count=$ro_file_count, expected 128"
  # Compare with RW manifest
  local rw_count; rw_count=$(tail -n+2 "$rw_manifest" | wc -l)
  [[ $rw_count -eq 128 ]] || die "RW manifest count=$rw_count"
  log "R1B_ADOPT: 128 files verified, UUID=$live_uuid"
  # Step 7: Verify objects/stored stable (3 samples)
  local obj_prev=""
  for _ in $(seq 1 3); do
    local obj_now
    obj_now=$(sudo ceph df --format json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);[print(p.get('stats',{}).get('objects',0),p.get('stats',{}).get('stored',0)) for p in d.get('pools',[]) if p.get('name')=='$POOL_B_R1B']")
    [[ -n "$obj_prev" ]] && [[ "$obj_now" == "$obj_prev" ]] || obj_prev="$obj_now"
    sleep 30
  done
  [[ -n "$obj_prev" && "$obj_prev" != "0 0" ]] || die 'objects/stored unstable or zero'
  # Verify control plane unchanged
  sudo ceph health >/dev/null 2>&1 || die 'health not OK'
  sudo ceph osd dump --format json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
um=[x for x in d.get('pg_upmap',[]) if isinstance(x,dict) and str(x.get('pgid','')).startswith('$(contract_r1b_pool_id).')]
assert len(um)==5, f'upmap count {len(um)} != 5'
pt=d.get('primary_temp',[])
assert not pt or all(not str(x).startswith('$(contract_r1b_pool_id).') for x in pt if isinstance(x,str)), 'primary_temp residue'
" || die 'control plane check failed'
  sudo ceph balancer status 2>/dev/null | python3 -c "import json,sys;assert not json.load(sys.stdin).get('active')" || die 'balancer not off'
  # Write adopt marker (do NOT delete LAYOUT_FAILED)
  r1b_marker R1B_LAYOUT_ADOPTED_PASS; r1b_append r1b-adopt-layout-ro-mount PASS
  log "R1B_LAYOUT_ADOPTED_PASS uuid=$live_uuid pid=$new_pids"
}

case $COMMAND in
  init) cmd_init ;;
  phase-i) cmd_phase_i ;;
  plan-register-empty) cmd_plan_register_empty ;;
  register-empty) cmd_register_empty ;;
  adopt-registered-empty) cmd_adopt_registered_empty ;;
  evaluate-layout) cmd_evaluate_layout "${3:-}" ;;
  plan-adjust) cmd_plan_adjust "${3:-}" "${4:-}" ;;
  adjust-verify) cmd_adjust_verify "${3:-}" "${4:-}" ;;
  inspect) cmd_inspect ;;
  r1b-init) cmd_r1b_init ;;
  r1b-phase-i) cmd_r1b_phase_i ;;
  r1b-plan-create-pool) cmd_r1b_plan_create_pool ;;
  r1b-create-pool) cmd_r1b_create_pool ;;
  r1b-adopt-created-pool) cmd_r1b_adopt_created_pool ;;
  r1b-plan-upmap) cmd_r1b_plan_upmap ;;
  r1b-apply-upmap) cmd_r1b_apply_upmap ;;
  r1b-rollback-upmap) cmd_r1b_rollback_upmap ;;
  r1b-plan-primary-toggle) cmd_r1b_plan_primary_toggle ;;
  r1b-canary-primary-toggle) cmd_r1b_canary_primary_toggle ;;
  r1b-plan-data-l1) cmd_r1b_plan_data_l1 ;;
  r1b-plan-layout-v2) cmd_r1b_plan_layout_v2 ;;
  r1b-layout-once) cmd_r1b_layout_once ;;
  r1b-adopt-layout-ro-mount) cmd_r1b_adopt_layout_ro_mount ;;
  r1b-l1-screen) cmd_r1b_l1_screen ;;
  r1b-evaluate-structure) cmd_r1b_evaluate_structure ;;
  *) die 'usage: ...|r1b-adopt-layout-ro-mount|...' ;;
esac
