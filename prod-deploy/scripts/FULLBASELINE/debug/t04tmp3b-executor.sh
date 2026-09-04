#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 04-tmp3b Phase 0/I + Step 1 + Step 2 read/write paths.  Write execution has
# a separate exact ACK; scrub is delegated to the existing lease controller,
# while terminal destroy remains plan-only in this file.
# No nested SSH and no embedded sudo.  Scrub writes are delegated to the
# existing state-driven controller after its separate lease acknowledgement.
# DEFECT-D01 DEFECT-D02 DEFECT-D03 DEFECT-D04 DEFECT-D05 DEFECT-D06
# DEFECT-D12 DEFECT-D16 DEFECT-D17 DEFECT-D18 DEFECT-D19 DEFECT-D21
# DEFECT-D22 DEFECT-D23 DEFECT-D25 DEFECT-D26 DEFECT-D27 DEFECT-D28
# DEFECT-D29 DEFECT-D30 DEFECT-D31

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXECUTOR=$(readlink -f -- "${BASH_SOURCE[0]}")
ANALYZER="$SELF_DIR/t04tmp3b-analyze.py"
SCRUB="$SELF_DIR/u141d-scrub-control.sh"
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
NAME=juicefs-prod
REF=/mnt/juicefs
ASSET="$REF/test_dir/seqread/seqread.0.0"
ASSET_REL=/test_dir/seqread/seqread.0.0
REMOTE_PARENT=/tmp/production
TASK_ROOT=/mnt/c/SunRise/test/04-tmp3b
METRICS_ADDR=127.0.0.1:19657
# The data path is Ceph, not TiKV.  Freeze one monitor address only to select
# the routed Ceph-facing NIC; this command does not contact that address.
CEPH_ROUTE_TARGET=10.3.1.6
RUN_ID=${2:-}
ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"
ACTIVE_LEASE=
ACTIVE_SAMPLER_PID=
ACTIVE_SAMPLER_STOP=
SELECTED_RA=8M
SELECTED_ASYNC=off
STEP2_ID=

load_step2_id() {
  [[ -f "$ROOT/plans/step2-id.txt" ]] || die step2_id_missing
  STEP2_ID=$(tr -d '[:space:]' <"$ROOT/plans/step2-id.txt")
  [[ "$STEP2_ID" =~ ^${RUN_ID}-s2r[0-9]+$ ]] || die step2_id_invalid
}
temp_meta() { [[ -n "$STEP2_ID" ]] || load_step2_id; printf '%s/%s-%s\n' "${META%/*}" "$STEP2_ID" "$1"; }
temp_name() { [[ -n "$STEP2_ID" ]] || load_step2_id; printf '%s-%s\n' "$STEP2_ID" "$1"; }
temp_mnt() { [[ -n "$STEP2_ID" ]] || load_step2_id; printf '/tmp/jfs-04tmp3b-mnt-%s-%s\n' "$STEP2_ID" "$1"; }
temp_out() { [[ -n "$STEP2_ID" ]] || load_step2_id; printf '%s/step2/%s/%s\n' "$ROOT" "$STEP2_ID" "$1"; }

die() { printf 'T04TMP3B_EXECUTOR_FAIL\t%s\n' "$*" >&2; exit 42; }
usage() {
  cat >&2 <<'EOF'
usage: t04tmp3b-executor.sh inventory-plan RUN_ID
       t04tmp3b-executor.sh step1-read RUN_ID I_ACK_04TMP3B_STEP1_READ_RUN_ID
       t04tmp3b-executor.sh step2-plan RUN_ID
       t04tmp3b-executor.sh step2-create-canary RUN_ID I_ACK_04TMP3B_STEP2_CREATE_CANARY_RUN_ID
       t04tmp3b-executor.sh step2-read RUN_ID I_ACK_04TMP3B_STEP2_READ_RUN_ID
       t04tmp3b-executor.sh step2-write RUN_ID I_ACK_04TMP3B_STEP2_WRITE_RUN_ID
       t04tmp3b-executor.sh step2-write RUN_ID I_ACK_04TMP3B_STEP2_WRITE_EXECUTE_RUN_ID
       t04tmp3b-executor.sh cleanup-plan RUN_ID
       t04tmp3b-executor.sh bundle RUN_ID
       t04tmp3b-executor.sh --self-test
EOF
  exit 2
}
valid_run() { [[ ${1:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID; }
valid_scope() {
  valid_run "$RUN_ID"
  [[ "$ROOT" == "$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID" && "$ROOT" != / && "$ROOT" != *..* ]] || die unsafe_root
  [[ ! -L "$ROOT" ]] || die root_symlink
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
reject_overrides() {
  local n
  for n in T04TMP3B_JFS T04TMP3B_META T04TMP3B_ROOT T04TMP3B_TASK_ROOT; do
    [[ -z ${!n+x} ]] || die "environment override rejected: $n"
  done
}
record() {
  [[ -f "$ROOT/commands.sh" ]] || : >"$ROOT/commands.sh"
  printf '#' >>"$ROOT/commands.sh"
  printf ' %q' "$@" >>"$ROOT/commands.sh"
  printf '\n' >>"$ROOT/commands.sh"
}
state() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tGPT\n' \
    "$(date -Is)" "$RUN_ID" "$1" "$2" "$3" "$4" "$5" "$6" "$TASK_ROOT/$RUN_ID" >>"$ROOT/run-state.tsv"
}
incident() { printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >>"$ROOT/incidents.tsv"; }
fixed_binary() {
  [[ -x "$JFS" && ! -L "$JFS" ]] || die binary_missing
  [[ "$(md5sum "$JFS" | awk '{print $1}')" == "$JFS_MD5" ]] || die binary_md5_drift
}
ceph_read() { timeout 20 env CEPH_CONF="${CEPH_CONF:-}" ceph "$@"; }
scrub_run() { env CEPH_CONF="${CEPH_CONF:-}" U141D_SCRUB_STATE_DIR="$ROOT/scrub" "$SCRUB" "$@"; }
prepare_ceph_conf() {
  CEPH_CONF="$ROOT/inventory/ceph.conf"
  if [[ ! -f "$CEPH_CONF" ]]; then
    [[ -r /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_missing
    cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
    printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
    sha256sum "$CEPH_CONF" >"$ROOT/inventory/ceph.conf.sha256"
  else
    sha256sum -c "$ROOT/inventory/ceph.conf.sha256" >/dev/null || die ceph_conf_drift
  fi
  [[ -r "$CEPH_CONF" && ! -L "$CEPH_CONF" ]] || die ceph_conf_invalid
  grep -Fqx $'\tms_async_op_threads = 8' "$CEPH_CONF" || die ceph_conf_msgr8_missing
  export CEPH_CONF
}

health_gate() {
  local tag=$1 mode=${2:-unpaused} out="$ROOT/health-$1"
  mkdir -m 0700 -p "$out"
  ceph_read -s --format json >"$out/status.json"
  ceph_read osd stat --format json >"$out/osd-stat.json"
  ceph_read pg dump pgs_brief >"$out/pgs.txt"
  python3 - "$out/status.json" "$out/osd-stat.json" "$out/pgs.txt" "$mode" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2]))
h=s.get('health',{}); mode=sys.argv[4]; checks=set((h.get('checks') or {}).keys())
if mode == 'paused':
    if not ((h.get('status') == 'HEALTH_OK' and not checks) or (h.get('status') == 'HEALTH_WARN' and checks == {'OSDMAP_FLAGS'})): raise SystemExit('paused health gate failed')
elif h.get('status') != 'HEALTH_OK' or checks: raise SystemExit('health gate failed')
if len({o.get(k) for k in ('num_osds','num_up_osds','num_in_osds')}) != 1: raise SystemExit('OSD gate failed')
states=[]
for line in open(sys.argv[3]):
    f=line.split()
    if f and f[0][:1].isdigit() and len(f)>1: states.append(f[1])
if not states or any(x != 'active+clean' for x in states): raise SystemExit('PG gate failed')
PY
}
write_contract() {
  mkdir -m 0700 -p "$ROOT"/{common,inventory,plans,cells,incidents,derived,scrub,closure}
  printf 'epoch_iso\trun_id\tvalidity_state\tlifecycle_state\tremote_status\tlocal_status\tincident_status\treason\tevidence_root\tactor\n' >"$ROOT/run-state.tsv"
  printf 'epoch\ttype\tdetail\n' >"$ROOT/incidents.tsv"
  printf '#!/usr/bin/env bash\n# 04-tmp3b command audit; secret values are redacted.\n' >"$ROOT/commands.sh"
  printf 'key\tvalue\nevidence_level\tL1_SCREEN\nevidence_root\t%s\nremote_result_root\t%s\nevidence_retention\tSCREEN\nremote_cleanup\tAFTER_REVIEW\nlocal_compaction\tAFTER_REVIEW\nenvironment_asset_cleanup\tindependent exact plan and ACK\n' "$TASK_ROOT/$RUN_ID" "$ROOT" >"$ROOT/common/contract.tsv"
  state ACTIVE ACTIVE ACTIVE PRESERVED NONE L0_PLAN
}
inventory_plan() {
  valid_scope; [[ ! -e "$ROOT" ]] || die root_exists
  for x in ceph curl fio findmnt ip mountpoint md5sum sha256sum stat readlink ss timeout python3; do need "$x"; done
  fixed_binary; write_contract; prepare_ceph_conf
  mkdir -m 0700 -p "$ROOT/inventory"
  hostname -f >"$ROOT/inventory/hostname.txt"; date -Ins >"$ROOT/inventory/time.txt"; uname -a >"$ROOT/inventory/uname.txt"; fio --version >"$ROOT/inventory/fio-version.txt"; "$JFS" --version >"$ROOT/inventory/juicefs-version.txt" 2>&1
  md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"; sha256sum "$JFS" >"$ROOT/inventory/juicefs.sha256"; ceph_read fsid >"$ROOT/inventory/ceph-fsid.txt"; ceph_read -s --format json >"$ROOT/inventory/ceph-health.json"; ceph_read osd stat --format json >"$ROOT/inventory/osd-stat.json"; ceph_read osd ls >"$ROOT/inventory/osd-ids.txt"; health_gate inventory
  ip route get "$CEPH_ROUTE_TARGET" >"$ROOT/inventory/route-to-ceph.txt"
  awk '{for(i=1;i<=NF;i++) if($i=="dev" && i<NF){print $(i+1); exit}}' "$ROOT/inventory/route-to-ceph.txt" >"$ROOT/inventory/nic.txt"
  [[ $(<"$ROOT/inventory/nic.txt") =~ ^[A-Za-z0-9_.:-]+$ && -r /sys/class/net/$(<"$ROOT/inventory/nic.txt")/statistics/rx_bytes ]] || die exact_nic_unavailable
  [[ -d "$REF" && ! -L "$REF" ]] || die current_mount_missing; mountpoint -q "$REF" || die current_mount_missing; findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/current-mount.tsv"
  grep -Fq "JuiceFS:$NAME $REF fuse.juicefs" "$ROOT/inventory/current-mount.tsv" || die current_mount_identity_mismatch
  [[ -f "$ASSET" && ! -L "$ASSET" ]] || die seqread_asset_missing
  [[ $(stat -c %s "$ASSET") == 34359738368 ]] || die seqread_asset_not_32GiB
  printf 'realpath\t%s\ninode\t%s\nbytes\t%s\nmtime\t%s\nhead_sha256\t%s\ntail_sha256\t%s\n' "$(readlink -f "$ASSET")" "$(stat -c %i "$ASSET")" "$(stat -c %s "$ASSET")" "$(stat -c %Y "$ASSET")" "$(head -c 1048576 "$ASSET" | sha256sum | awk '{print $1}')" "$(tail -c 1048576 "$ASSET" | sha256sum | awk '{print $1}')" >"$ROOT/inventory/seqread-asset.tsv"
  timeout 30 "$JFS" status "$META" >"$ROOT/inventory/current-status.json"
  python3 - "$ROOT/inventory/current-status.json" "$NAME" >"$ROOT/inventory/current-uuid.txt" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get('Setting') or {}
name=s.get('Name') or d.get('Name'); uuid=s.get('UUID') or d.get('UUID'); block=s.get('BlockSize') or d.get('BlockSize')
if name != sys.argv[2] or not isinstance(uuid,str) or not uuid or str(block) not in ('256','256K','262144'): raise SystemExit('current volume identity incomplete')
print(uuid)
PY
  if findmnt -rn -o TARGET | awk '$1 ~ /^\/tmp\/jfs-04tmp3b-/ {bad=1} END{exit bad+0}'; then :; else die residual_tmp3b_mount; fi
  if python3 - <<'PY'
import pathlib
bad=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if (p/'comm').read_text().strip() == 'fio': bad.append(p.name)
    except OSError: pass
raise SystemExit(1 if bad else 0)
PY
  then :; else die foreign_fio_exists; fi
  ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)19657$' && die metrics_port_in_use || :
  printf 'phase\tlease\tfsid\towned_flags\nSTEP1\t%s-phase-a\t%s\tnoscrub,nodeep-scrub\n' "$RUN_ID" "$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt")" >"$ROOT/plans/scrub-contract.tsv"; scrub_run plan-pause "$RUN_ID-phase-a" >"$ROOT/plans/scrub-plan.txt" 2>&1
  printf 'step\tcell\tarm\tworkload\truntime_s\n' >"$ROOT/plans/matrix.tsv"
  local i arm; i=0
  for arm in ra8 ra16 ra32 ra32 ra16 ra8; do i=$((i+1)); printf 'RA\tR%02d\t%s\tread20m\t60\n' "$i" "$arm" >>"$ROOT/plans/matrix.tsv"; done
  for arm in off on on off; do i=$((i+1)); printf 'ASYNC\tA%02d\t%s\tread20m\t60\n' "$((i-6))" "$arm" >>"$ROOT/plans/matrix.tsv"; done
  sha256sum "$EXECUTOR" "$ANALYZER" "$SCRUB" >"$ROOT/plans/runtime-scripts.sha256"; printf 'INVENTORY_PLAN_PASS\n' >"$ROOT/inventory/PASS"; state ACTIVE PERSISTING ACTIVE PRESERVED NONE INVENTORY_PLAN; printf 'T04TMP3B_INVENTORY_PLAN_PASS\t%s\n' "$ROOT"
}
mount_read() {
  local cell=$1 arm=$2 out="$ROOT/cells/$cell" mnt="/tmp/jfs-04tmp3b-$RUN_ID-$cell"; [[ ! -e "$mnt" && ! -L "$mnt" ]] || die mount_path_exists; mkdir -m 0700 "$mnt"; mkdir -m 0700 -p "$out/bwlog"
  local log="$out/juicefs-mount.log"
  local -a cmd=("$JFS" mount -d --log "$log" --metrics "$METRICS_ADDR" --read-only --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0)
  case "$arm" in ra8) cmd+=(--max-readahead 8M);; ra16) cmd+=(--max-readahead 16M);; ra32) cmd+=(--max-readahead 32M);; async-off|async-on) cmd+=(--max-readahead "$SELECTED_RA"); [[ "$arm" == async-on ]] && cmd+=(-o async_dio);; *) die bad_read_arm;; esac
  cmd+=("$META" "$mnt"); record env "CEPH_CONF=${CEPH_CONF:-}" "${cmd[@]}"; timeout 180 env CEPH_CONF="${CEPH_CONF:-}" "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr" || die mount_failed; for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done; mountpoint -q "$mnt" || die mount_timeout
  printf '%s\n' "$mnt" >"$out/mount-path.txt"
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/findmnt.tsv"
  grep -Fq "JuiceFS:$NAME $mnt fuse.juicefs" "$out/findmnt.tsv" || die mount_identity_mismatch
  python3 - "$JFS" "$log" "$out/mount-process.tsv" "$out/mount-state.tsv" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); log=sys.argv[2]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if log not in cmd: continue
        st=(p/'stat').read_text().split()
        rows.append((p.name,st[3],st[21],hashlib.md5(open(p/'exe','rb').read()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit('mount process identity missing')
with open(sys.argv[3],'w') as f:
    f.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for row in sorted(rows,key=lambda x:int(x[0])): f.write('\t'.join(row)+'\n')
pids={r[0] for r in rows}; workers=[r for r in rows if r[1] in pids]
if len(workers) != 1: raise SystemExit('unique child worker not found')
w=workers[0]
with open(sys.argv[4],'w') as f:
    f.write(f'worker_pid\t{w[0]}\nworker_starttime\t{w[2]}\nworker_exe_md5\t{w[3]}\n')
PY
  local mounted_asset="$mnt$ASSET_REL"
  [[ -f "$mounted_asset" && ! -L "$mounted_asset" && $(stat -c %s "$mounted_asset") == 34359738368 ]] || die mounted_asset_identity
  printf 'inode\t%s\nbytes\t%s\nmtime\t%s\nhead_sha256\t%s\ntail_sha256\t%s\n' \
    "$(stat -c %i "$mounted_asset")" "$(stat -c %s "$mounted_asset")" "$(stat -c %Y "$mounted_asset")" \
    "$(head -c 1048576 "$mounted_asset" | sha256sum | awk '{print $1}')" \
    "$(tail -c 1048576 "$mounted_asset" | sha256sum | awk '{print $1}')" >"$out/mounted-asset.tsv"
  for key in inode bytes mtime head_sha256 tail_sha256; do
    [[ $(awk -F '\t' -v k="$key" '$1==k{print $2}' "$out/mounted-asset.tsv") == \
       $(awk -F '\t' -v k="$key" '$1==k{print $2}' "$ROOT/inventory/seqread-asset.tsv") ]] || die "mounted_asset_${key}_drift"
  done
  # Use a real command rather than shell output redirection: when opening the
  # target itself fails, Bash reports the error before a later stderr
  # redirection is installed and the EROFS evidence file stays empty.
  local probe="$mnt/.04tmp3b-ro-probe-$RUN_ID-$cell"; set +e; touch -- "$probe" 2>"$out/ro-probe.err"; local rc=$?; set -e; (( rc != 0 )) || die ro_probe_accepted; grep -Eq 'EROFS|Read-only file system' "$out/ro-probe.err" || die ro_probe_not_EROFS; [[ ! -e "$probe" ]] || die ro_probe_residue
  curl -fsS --connect-timeout 2 --max-time 5 "http://$METRICS_ADDR/metrics" >"$out/metrics-mounted.prom" || die metrics_endpoint_missing
  grep -Fq 'vol_name="juicefs-prod"' "$out/metrics-mounted.prom" || die metrics_volume_identity
}
scan_logs() { local out=$1; if grep -nEi 'ceph_assert|SIGABRT|SIGSEGV|panic|fatal|core dumped|Aborted' "$out"/mount.stdout "$out"/mount.stderr "$out"/juicefs-mount.log "$out"/umount.stdout "$out"/umount.stderr 2>/dev/null; then incident FATAL_LOG "$out"; die fatal_log; fi; }
processes_gone() {
  local file=$1
  python3 - "$file" <<'PY'
import csv,os,sys
for row in csv.DictReader(open(sys.argv[1]),delimiter='\t'):
    try:
        if open('/proc/'+row['pid']+'/stat').read().split()[21] == row['starttime']: raise SystemExit(1)
    except OSError: pass
PY
}
graceful_umount() {
  local cell=$1 out="$ROOT/cells/$cell" mnt; mnt=$(<"$out/mount-path.txt"); record env "CEPH_CONF=${CEPH_CONF:-}" "$JFS" umount "$mnt"; timeout 180 env CEPH_CONF="${CEPH_CONF:-}" "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr" || die graceful_umount_failed; for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done; mountpoint -q "$mnt" && die mount_remains; for _ in $(seq 1 60); do processes_gone "$out/mount-process.tsv" && break; sleep 1; done; processes_gone "$out/mount-process.tsv" || die mount_processes_remain; scan_logs "$out"; [[ -d "$mnt" && ! -L "$mnt" ]] || die mount_dir_missing; rmdir "$mnt"
  local _port_gone=0
  for _ in $(seq 1 30); do
    if ! ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)19657$'; then _port_gone=1; break; fi
    sleep 1
  done
  (( _port_gone == 1 )) || die metrics_port_remains
}

step2_ack() {
  local stage=$1 supplied=$2
  [[ "$supplied" == "I_ACK_04TMP3B_${stage}_$RUN_ID" ]] || die "invalid_step2_ack_$stage"
}

step2_preflight() {
  valid_scope
  load_step2_id
  [[ -f "$ROOT/inventory/PASS" && -f "$ROOT/STEP1_READ_PASS" ]] || die step1_required
  [[ -f "$ROOT/plans/step2-decision.txt" ]] || die step2_decision_missing
  grep -Fxq 'BLOCKSIZE_TEST_JUSTIFIED' "$ROOT/plans/step2-decision.txt" || die step2_not_justified
  fixed_binary
  [[ -f "$ROOT/plans/step2-runtime-scripts.sha256" ]] || die step2_runtime_plan_missing
  (cd / && sha256sum -c "$ROOT/plans/step2-runtime-scripts.sha256") >/dev/null || die step2_runtime_script_drift
  [[ -f "$ROOT/plans/step2-plan-contract.sha256" ]] || die step2_plan_contract_missing
  (cd / && sha256sum -c "$ROOT/plans/step2-plan-contract.sha256") >/dev/null || die step2_plan_contract_drift
  if python3 - <<'PY'
import pathlib
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if (p/'comm').read_text().strip() == 'fio': raise SystemExit(1)
    except OSError: pass
PY
  then :; else die foreign_fio_exists; fi
  if findmnt -rn -o TARGET | awk '$1 ~ /^\/tmp\/jfs-04tmp3b-mnt-/ {bad=1} END{exit bad+0}'; then :; else die residual_step2_mount; fi
  prepare_ceph_conf
  verify_current_fingerprint
}

format_settings_guard() {
  local status="$ROOT/inventory/current-status.json"
  [[ -r "$status" && ! -L "$status" ]] || die current_status_missing
  python3 - "$status" <<'PY'
import json, sys
s=(json.load(open(sys.argv[1])).get('Setting') or {})
required={'Name':'juicefs-prod','Storage':'ceph','Bucket':'ceph://juicefs-data',
          'AccessKey':'ceph','Compression':'none','TrashDays':0,'DirStats':True,
          'MinClientVersion':'1.1.0-A','EnableACL':False,'KeyEncrypted':True}
for k,v in required.items():
    if s.get(k) != v: raise SystemExit('current format setting mismatch: '+k)
PY
}

pool_stats() {
  ceph_read df detail --format json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=[x for x in d.get("pools",[]) if x.get("name")=="juicefs-data"]
assert len(p)==1
s=p[0]["stats"]
print("objects\t%s\nstored\t%s\nbytes_used\t%s\nmax_avail\t%s" %
      (s["objects"],s["stored"],s["bytes_used"],s["max_avail"]))'
}

step2_plan() {
  valid_scope
  [[ -f "$ROOT/STEP1_READ_PASS" && -f "$ROOT/inventory/current-status.json" ]] || die step1_required
  prepare_ceph_conf; fixed_binary; verify_current_fingerprint; health_gate STEP2-PLAN unpaused
  format_settings_guard
  STEP2_ID="$RUN_ID-s2r2"
  printf '%s\n' "$STEP2_ID" >"$ROOT/plans/step2-id.txt"
  if [[ -s "$ROOT/cells/STEP2-b256/format.stderr" ]] && \
     ! grep -Fq 'STEP2_CREATE_ATTEMPT1_INVALID_UNSUPPORTED_CLI' "$ROOT/incidents.tsv"; then
    incident STEP2_CREATE_ATTEMPT1_INVALID_UNSUPPORTED_CLI 'format rejected --dir-stats before namespace creation; no object or mount change'
  fi
  printf 'BLOCKSIZE_TEST_JUSTIFIED\n' >"$ROOT/plans/step2-decision.txt"
  printf 'off\n' >"$ROOT/plans/selected-async.txt"
  pool_stats >"$ROOT/plans/step2-pool-pre.tsv"
  python3 - "$ROOT/plans/step2-pool-pre.tsv" <<'PY'
import sys
d={x.split('\t',1)[0]:int(x.split('\t',1)[1]) for x in open(sys.argv[1]) if '\t' in x}
if d.get('max_avail',0) < 64*1024**3: raise SystemExit('less than 64GiB pool headroom')
PY
  : >"$ROOT/plans/step2-format-plan.txt"
  local arm block meta name
  for arm in b256 b4; do
    [[ "$arm" == b256 ]] && block=256K || block=4M
    meta=$(temp_meta "$arm"); name=$(temp_name "$arm")
    printf 'CEPH_CONF=%q %q format --no-update --storage ceph --bucket ceph://juicefs-data --access-key ceph --secret-key client.juicefs --block-size %q --compress none --trash-days 0 %q %q\n' \
      "$CEPH_CONF" "$JFS" "$block" "$meta" "$name" >>"$ROOT/plans/step2-format-plan.txt"
  done
  printf 'phase\tlease\tfsid\towned_flags\nSTEP2_READ\t%s-step2read-phase-a\t%s\tnoscrub,nodeep-scrub\n' \
    "$RUN_ID" "$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt")" >"$ROOT/plans/step2-scrub-contract.tsv"
  scrub_run plan-pause "$RUN_ID-step2read-phase-a" >"$ROOT/plans/step2-scrub-plan.txt" 2>&1
  sha256sum "$EXECUTOR" "$ANALYZER" "$SCRUB" >"$ROOT/plans/step2-runtime-scripts.sha256"
  sha256sum "$ROOT/plans/step2-decision.txt" "$ROOT/plans/step2-id.txt" "$ROOT/plans/selected-ra.txt" \
    "$ROOT/plans/selected-async.txt" "$ROOT/plans/step2-format-plan.txt" \
    "$ROOT/plans/step2-scrub-contract.tsv" "$ROOT/plans/step2-pool-pre.tsv" \
    >"$ROOT/plans/step2-plan-contract.sha256"
  printf 'STEP2_PLAN_PASS\n'
}

temp_status() {
  local arm=$1 meta name out status current uuid
  meta=$(temp_meta "$arm"); name=$(temp_name "$arm"); out=$(temp_out "$arm"); mkdir -m 0700 -p "$out"
  status="$out/status.json"
  timeout 30 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$status" 2>"$out/status.stderr" || die "temp_status_failed_$arm"
  current="$ROOT/inventory/current-status.json"
  uuid=$(python3 - "$status" "$current" "$name" "$arm" <<'PY'
import json,sys
t=(json.load(open(sys.argv[1])).get('Setting') or {})
c=(json.load(open(sys.argv[2])).get('Setting') or {})
name,arm=sys.argv[3:]
if t.get('Name') != name: raise SystemExit('temp Name mismatch')
if t.get('Name') == c.get('Name') or t.get('UUID') == c.get('UUID'): raise SystemExit('temp identity collision')
sizes={'b256':{'256','256K','262144'},'b4':{'4096','4M','4194304'}}
if str(t.get('BlockSize')) not in sizes[arm]: raise SystemExit('temp BlockSize mismatch')
for k in ('Storage','Bucket','Compression','TrashDays','DirStats','MinClientVersion','EnableACL','EncryptAlgo','KeyEncrypted'):
    if k in c and t.get(k) != c.get(k): raise SystemExit('temp Setting mismatch: '+k)
if t.get('AccessKey') != 'ceph': raise SystemExit('temp access key mismatch')
if t.get('SecretKey') not in ('client.juicefs','removed',None): raise SystemExit('temp secret reference mismatch')
u=t.get('UUID')
if not isinstance(u,str) or not u: raise SystemExit('temp UUID missing')
print(u)
PY
  )
  printf 'arm\t%s\nmeta\t%s\nname\t%s\nuuid\t%s\nblock_size\t%s\n' "$arm" "$meta" "$name" "$uuid" "$([[ $arm == b256 ]] && echo 256K || echo 4M)" >"$out/identity.tsv"
}

format_one() {
  local arm=$1 block meta name out
  case "$arm" in b256) block=256K;; b4) block=4M;; *) die bad_temp_arm;; esac
  meta=$(temp_meta "$arm"); name=$(temp_name "$arm"); out=$(temp_out "$arm"); mkdir -m 0700 -p "$out"
  [[ ! -e "$out/PASS" && ! -e "$out/status.json" ]] || die temp_format_reuse
  if timeout 20 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$out/preexisting-status.json" 2>"$out/preexisting-status.stderr"; then
    die temp_meta_exists
  fi
  local -a cmd=("$JFS" format --no-update --storage ceph --bucket ceph://juicefs-data --access-key ceph --secret-key client.juicefs --block-size "$block" --compress none --trash-days 0)
  cmd+=("$meta" "$name")
  record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$out/format.stdout" 2>"$out/format.stderr" || die "format_failed_$arm"
  temp_status "$arm"
  printf 'FORMAT_PASS\t%s\n' "$arm" >"$out/PASS"
}

mount_temp() {
  local arm=$1 cell=$2 mode=$3 out="$ROOT/cells/$2" mnt log meta name
  meta=$(temp_meta "$arm"); name=$(temp_name "$arm"); mnt=$(temp_mnt "$arm"); log="$out/juicefs-mount.log"
  [[ ! -e "$mnt" && ! -L "$mnt" ]] || die temp_mount_path_exists
  mkdir -m 0700 -p "$out" "$mnt"
  local -a cmd=("$JFS" mount -d --log "$log" --metrics "$METRICS_ADDR" --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 --max-readahead "$SELECTED_RA")
  [[ "$mode" == ro ]] && cmd+=(--read-only)
  [[ "$SELECTED_ASYNC" == on ]] && cmd+=(-o async_dio)
  cmd+=("$meta" "$mnt")
  record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr" || die "temp_mount_failed_$arm"
  for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die temp_mount_timeout
  printf '%s\n' "$mnt" >"$out/mount-path.txt"
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/findmnt.tsv"
  grep -Fq "JuiceFS:$name $mnt fuse.juicefs" "$out/findmnt.tsv" || die temp_mount_identity
  python3 - "$JFS" "$log" "$out/mount-process.tsv" "$out/mount-state.tsv" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); log=sys.argv[2]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if log not in cmd: continue
        st=(p/'stat').read_text().split(); rows.append((p.name,st[3],st[21],hashlib.md5(open(p/'exe','rb').read()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit('temp mount process identity missing')
pids={r[0] for r in rows}; workers=[r for r in rows if r[1] in pids]
if len(workers) != 1: raise SystemExit('temp unique child worker missing')
with open(sys.argv[3],'w') as f:
    f.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for r in sorted(rows,key=lambda x:int(x[0])): f.write('\t'.join(r)+'\n')
w=workers[0]
with open(sys.argv[4],'w') as f:
    f.write(f'worker_pid\t{w[0]}\nworker_starttime\t{w[2]}\nworker_exe_md5\t{w[3]}\n')
PY
  curl -fsS --connect-timeout 2 --max-time 5 "http://$METRICS_ADDR/metrics" >"$out/metrics-mounted.prom" || die temp_metrics_missing
  grep -Fq "vol_name=\"$name\"" "$out/metrics-mounted.prom" || die temp_metrics_identity
  grep -Fq "Data use ceph://juicefs-data/$name/" "$log" || die temp_data_prefix_identity
  grep -Fq 'Data use ceph://juicefs-data/juicefs-prod/' "$log" && die current_data_prefix_reused || :
}

canary_one() {
  local arm=$1 cell="CANARY-$1" out="$ROOT/cells/CANARY-$1" mnt file digest size
  mkdir -m 0700 -p "$out"; mount_temp "$arm" "$cell" rw; mnt=$(<"$out/mount-path.txt")
  mkdir -m 0700 -p "$mnt/step2-canary"; file="$mnt/step2-canary/canary-$RUN_ID-$arm"
  [[ ! -e "$file" && ! -L "$file" ]] || die canary_exists
  record fio --name=step2_canary --filename="$file" --rw=write --bs=1M --size=4M --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1
  timeout 120 fio --name=step2_canary --filename="$file" --rw=write --bs=1M --size=4M --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 >"$out/canary.stdout" 2>"$out/canary.stderr" || die canary_write_failed
  size=$(stat -c %s "$file"); digest=$(sha256sum "$file" | awk '{print $1}'); printf 'bytes\t%s\nsha256\t%s\n' "$size" "$digest" >"$out/canary-fingerprint.tsv"
  graceful_umount "$cell"
  mount_temp "$arm" "$cell-remount" rw; mnt=$(<"$ROOT/cells/$cell-remount/mount-path.txt"); file="$mnt/step2-canary/canary-$RUN_ID-$arm"
  [[ $(stat -c %s "$file") == "$size" ]] || die canary_size_drift
  [[ $(sha256sum "$file" | awk '{print $1}') == "$digest" ]] || die canary_hash_drift
  unlink -- "$file"; rmdir "$mnt/step2-canary"; graceful_umount "$cell-remount"; scan_logs "$out"; scan_logs "$ROOT/cells/$cell-remount"
  printf 'CANARY_PASS\t%s\n' "$arm" >"$out/PASS"
}

prepare_temp_read_asset() {
  local arm=$1 cell="PREP-$1" out="$ROOT/cells/PREP-$1" mnt file digest
  mkdir -m 0700 -p "$out"; mount_temp "$arm" "$cell" rw; mnt=$(<"$out/mount-path.txt"); mkdir -m 0700 -p "$(dirname "$mnt$ASSET_REL")"
  file="$mnt$ASSET_REL"; [[ ! -e "$file" && ! -L "$file" ]] || die temp_read_asset_exists
  record fio --name=step2_prepare_read --filename="$file" --rw=write --bs=16M --size=10G --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --buffer_pattern=0x5a
  timeout 300 fio --name=step2_prepare_read --filename="$file" --rw=write --bs=16M --size=10G --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --buffer_pattern=0x5a >"$out/prepare.stdout" 2>"$out/prepare.stderr" || die temp_read_asset_prepare_failed
  [[ $(stat -c %s "$file") == 10737418240 ]] || die temp_read_asset_size
  digest="$(head -c 1048576 "$file" | sha256sum | awk '{print $1}')/$(tail -c 1048576 "$file" | sha256sum | awk '{print $1}')"; printf 'bytes\t10737418240\nsample_sha256\t%s\n' "$digest" >"$ROOT/step2-assets-$arm.tsv"; graceful_umount "$cell"
  mount_temp "$arm" "$cell-remount" ro; mnt=$(<"$ROOT/cells/$cell-remount/mount-path.txt"); file="$mnt$ASSET_REL"
  [[ $(stat -c %s "$file") == 10737418240 ]] || die temp_read_asset_remount_size
  [[ "$(head -c 1048576 "$file" | sha256sum | awk '{print $1}')/$(tail -c 1048576 "$file" | sha256sum | awk '{print $1}')" == "$digest" ]] || die temp_read_asset_remount_hash
  graceful_umount "$cell-remount"; printf 'READ_ASSET_PASS\t%s\n' "$arm" >>"$ROOT/step2-assets.tsv"
}

step2_create_canary() {
  local supplied=$1
  step2_ack STEP2_CREATE_CANARY "$supplied"; step2_preflight; format_settings_guard; health_gate STEP2-CREATE-pre unpaused
  mkdir -m 0700 -p "$ROOT/step2" "$ROOT/cells"; SELECTED_RA=$(tr -d '[:space:]' <"$ROOT/plans/selected-ra.txt")
  SELECTED_ASYNC=off; [[ -f "$ROOT/plans/selected-async.txt" ]] && SELECTED_ASYNC=$(tr -d '[:space:]' <"$ROOT/plans/selected-async.txt")
  [[ "$SELECTED_RA" =~ ^(8M|16M|32M)$ && "$SELECTED_ASYNC" =~ ^(off|on)$ ]] || die selected_read_mode_invalid
  format_one b256; format_one b4; canary_one b256; canary_one b4; prepare_temp_read_asset b256; prepare_temp_read_asset b4
  cmp -s "$ROOT/step2-assets-b256.tsv" "$ROOT/step2-assets-b4.tsv" || die temp_read_assets_differ
  pool_stats >"$ROOT/plans/step2-pool-post-create.tsv"; health_gate STEP2-CREATE-post unpaused; verify_current_fingerprint; printf 'STEP2_CREATE_CANARY_PASS\n' >"$ROOT/STEP2_CREATE_CANARY_PASS"; state ACTIVE PERSISTING ACTIVE PRESERVED NONE STEP2_CREATE_CANARY
}

step2_read_phase() {
  local supplied=$1 i=0 arm cell mnt
  step2_ack STEP2_READ "$supplied"; step2_preflight; [[ -f "$ROOT/STEP2_CREATE_CANARY_PASS" ]] || die step2_create_required
  SELECTED_RA=$(tr -d '[:space:]' <"$ROOT/plans/selected-ra.txt"); SELECTED_ASYNC=off; [[ -f "$ROOT/plans/selected-async.txt" ]] && SELECTED_ASYNC=$(tr -d '[:space:]' <"$ROOT/plans/selected-async.txt")
  ACTIVE_LEASE="$RUN_ID-step2read-phase-a"; trap on_exit EXIT TERM INT HUP
  scrub_run pause "$ACTIVE_LEASE" "$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt")" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$ROOT/scrub/$ACTIVE_LEASE-pause.log" 2>&1
  scrub_run verify-paused "$ACTIVE_LEASE" >>"$ROOT/scrub/$ACTIVE_LEASE-pause.log" 2>&1
  for arm in b256 b4 b4 b256; do i=$((i+1)); cell=$(printf 'S2R%02d' "$i"); mkdir -m 0700 -p "$ROOT/cells/$cell"; health_gate "$cell-pre" paused; mount_temp "$arm" "$cell" ro; mnt=$(<"$ROOT/cells/$cell/mount-path.txt"); fio_cell "$cell" "$mnt"; graceful_umount "$cell"; health_gate "$cell-post" paused; done
  scrub_run restore "$ACTIVE_LEASE" >"$ROOT/scrub/$ACTIVE_LEASE-restore.log" 2>&1; scrub_run verify-restored "$ACTIVE_LEASE" >>"$ROOT/scrub/$ACTIVE_LEASE-restore.log" 2>&1; ACTIVE_LEASE=; health_gate STEP2-restored unpaused; verify_current_fingerprint
  printf 'STEP2_READ_PASS\n' >"$ROOT/STEP2_READ_PASS"; state ACTIVE PERSISTING ACTIVE PRESERVED NONE STEP2_READ
}

step2_write_preflight() {
  valid_scope; load_step2_id
  [[ -f "$ROOT/inventory/PASS" && -f "$ROOT/STEP1_READ_PASS" && -f "$ROOT/STEP2_CREATE_CANARY_PASS" ]] || die step2_write_phase_prerequisite
  [[ -f "$ROOT/plans/step2-plan-contract.sha256" ]] || die step2_plan_contract_missing
  (cd / && sha256sum -c "$ROOT/plans/step2-plan-contract.sha256") >/dev/null || die step2_plan_contract_drift
  fixed_binary
  if python3 - <<'PY'
import pathlib
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if (p/'comm').read_text().strip() == 'fio': raise SystemExit(1)
    except OSError: pass
PY
  then :; else die foreign_fio_exists; fi
  if findmnt -rn -o TARGET | awk '$1 ~ /^\/tmp\/jfs-04tmp3b-mnt-/ {bad=1} END{exit bad+0}'; then :; else die residual_step2_mount; fi
  prepare_ceph_conf; format_settings_guard; verify_current_fingerprint
  local arm
  for arm in b256 b4; do
    temp_status "$arm"
    [[ -f "$(temp_out "$arm")/identity.tsv" ]] || die write_temp_identity_missing
    [[ -f "$ROOT/step2-assets-$arm.tsv" ]] || die write_temp_asset_missing
    grep -Fqx $'bytes\t10737418240' "$ROOT/step2-assets-$arm.tsv" || die write_temp_asset_size
  done
  cmp -s "$ROOT/step2-assets-b256.tsv" "$ROOT/step2-assets-b4.tsv" || die write_temp_assets_differ
}

write_path() { printf '%s/test_dir/step2-write/%s/%s/payload\n' "$(temp_mnt "$1")" "$RUN_ID" "$2"; }

write_plan_step2() {
  local out="$ROOT/plans/step2-write-plan.tsv" arm cell meta name path uuid
  if [[ -e "$out" || -L "$out" ]]; then
    [[ -f "$out" && ! -L "$out" && -f "$out.sha256" ]] || die write_plan_existing_invalid
    sha256sum -c "$out.sha256" >/dev/null || die write_plan_existing_drift
    printf 'STEP2_WRITE_PLAN_REUSED\t%s\n' "$out"
    return
  fi
  mkdir -m 0700 -p "$ROOT/plans"
  printf 'cell\tarm\tmeta\tname\tuuid\tpath\tworkload\tstate\n' >"$out"
  local i=0
  for arm in b256 b4 b4 b256; do
    i=$((i+1)); cell=$(printf 'S2W%02d' "$i"); meta=$(temp_meta "$arm"); name=$(temp_name "$arm")
    uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$(temp_out "$arm")/identity.tsv")
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die write_plan_uuid_missing
    path=$(write_path "$arm" "$cell")
    printf '%s\t%s\t%s\t%s\t%s\t%s\twrite16m\tPRE_REGISTERED\n' "$cell" "$arm" "$meta" "$name" "$uuid" "$path" >>"$out"
    printf 'unlink_cmd\t%s\t unlink -- %q\n' "$cell" "$path" >>"$out"
    printf 'gc_cmd\t%s\tenv JFS_GC_SKIPPEDTIME=0 CEPH_CONF=%q %s gc --delete --threads 32 %q\n' "$cell" "$CEPH_CONF" "$JFS" "$meta" >>"$out"
  done
  for arm in b256 b4; do
    meta=$(temp_meta "$arm"); name=$(temp_name "$arm")
    uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$(temp_out "$arm")/identity.tsv")
    printf 'gc_cmd\t%s\tenv JFS_GC_SKIPPEDTIME=0 CEPH_CONF=%q %s gc --delete --threads 32 %q\n' "$arm" "$CEPH_CONF" "$JFS" "$meta" >>"$out"
    printf 'destroy_cmd\t%s\tenv CEPH_CONF=%q %s destroy %q %q\n' "$arm" "$CEPH_CONF" "$JFS" "$meta" "$uuid" >>"$out"
  done
  {
    printf 'approval\tWRITE_EXECUTE\tI_ACK_04TMP3B_STEP2_WRITE_EXECUTE_%s\n' "$RUN_ID"
    printf 'scrub_cmd\t01\texternal-lease-required\tceph osd set noscrub\n'
    printf 'scrub_cmd\t02\texternal-lease-required\tceph osd set nodeep-scrub\n'
    printf 'scrub_cmd\t03\texternal-lease-required\tceph osd unset nodeep-scrub\n'
    printf 'scrub_cmd\t04\texternal-lease-required\tceph osd unset noscrub\n'
    printf 'drain\tcontract\t300s\tbuffer-baseline-plus-minus-1MiB;uploading=0;PUT-DELETE-stable-3x5s\n'
    printf 'delete\tper-cell\texact-path-only\tunlink-then-rmdir-empty-registered-parent\n'
    printf 'gc\tper-cell\tgc-delete-on-temp-meta-only\tpool-return-to-step2-create-anchor\n'
    printf 'destroy\tterminal\texternal-independent-authorization\tstatus-uuid-guard-then-destroy\n'
  } >>"$out"
  sha256sum "$out" >"$out.sha256"
  printf 'bytes_tolerance\t67108864\nobjects_tolerance\t100\n' >"$ROOT/plans/step2-write-pool-tolerance.tsv"
  sha256sum "$ROOT/plans/step2-write-pool-tolerance.tsv" >"$ROOT/plans/step2-write-pool-tolerance.tsv.sha256"
  printf 'STEP2_WRITE_PLAN_ONLY\t%s\n' "$out"
}

drain_snapshot() {
  local out=$1 prom="$out/.drain-metrics.prom" val
  curl -fsS --connect-timeout 2 --max-time 5 "http://$METRICS_ADDR/metrics" >"$prom" || return 1
  python3 - "$prom" >"$out/drain-current.tsv" <<'PY'
import re,sys
buf=up=putc=puts=delc=dels=None
for line in open(sys.argv[1]):
    if not line or line.startswith('#') or ' ' not in line: continue
    name,raw=line.rsplit(None,1)
    try: value=float(raw)
    except ValueError: continue
    if name.startswith('juicefs_used_buffer_size_bytes{'): buf=value
    elif name.startswith('juicefs_object_request_uploading{'): up=value
    elif 'durations_histogram_seconds_count{' in name and 'method="PUT"' in name: putc=value
    elif 'durations_histogram_seconds_sum{' in name and 'method="PUT"' in name: puts=value
    elif 'durations_histogram_seconds_count{' in name and 'method="DELETE"' in name: delc=value
    elif 'durations_histogram_seconds_sum{' in name and 'method="DELETE"' in name: dels=value
if buf is None or up is None: raise SystemExit(2)
putc = 0.0 if putc is None else putc; puts = 0.0 if puts is None else puts
delc = 0.0 if delc is None else delc; dels = 0.0 if dels is None else dels
print(f'buffer\t{buf}\nuploading\t{up}\nput_count\t{putc}\nput_sum\t{puts}\ndelete_count\t{delc}\ndelete_sum\t{dels}')
PY
  rm -f -- "$prom"
}

drain_write() {
  local cell=$1 out="$ROOT/cells/$cell" baseline current previous= stable=0 started=$SECONDS
  [[ -r "$out/drain-baseline-pre.tsv" ]] || die write_drain_baseline_missing
  baseline=$(awk -F '\t' '$1=="buffer"{print $2}' "$out/drain-baseline-pre.tsv")
  drain_snapshot "$out" || die write_drain_metrics_missing
  printf 'buffer_baseline\t%s\n' "$baseline" >"$out/drain-baseline.tsv"
  while (( SECONDS - started < 300 )); do
    sleep 5
    drain_snapshot "$out" || die write_drain_metrics_missing
    current=$(awk -F '\t' '$1=="buffer"{print $2}' "$out/drain-current.tsv")
    local uploading=$(awk -F '\t' '$1=="uploading"{print $2}' "$out/drain-current.tsv")
    local low=$(( ${baseline%.*} - 1048576 )); local high=$(( ${baseline%.*} + 1048576 ))
    if awk -v b="$current" -v lo="$low" -v hi="$high" 'BEGIN{exit !(b>=lo && b<=hi)}' &&
       awk -v u="$uploading" 'BEGIN{exit !(u==0)}' &&
       { [[ -z "$previous" ]] || cmp -s "$out/drain-current.tsv" "$out/drain-previous.tsv"; }; then
      stable=$((stable+1))
    else
      stable=0
    fi
    cp -- "$out/drain-current.tsv" "$out/drain-previous.tsv"; previous=1
    (( stable >= 3 )) && { printf 'DRAIN_PASS\tseconds\t%s\n' "$((SECONDS-started))" >"$out/drain-pass.tsv"; return; }
  done
  die write_drain_timeout
}

pool_return_guard() {
  local post=$1 ref="$ROOT/plans/step2-pool-post-create.tsv" tol="$ROOT/plans/step2-write-pool-tolerance.tsv"
  [[ -r "$ref" && -r "$tol" ]] || die write_pool_anchor_missing
  local started=$SECONDS
  while (( SECONDS - started < 180 )); do
    pool_stats >"$post"
    if python3 - "$ref" "$post" "$tol" <<'PY'
import sys
def read(p):
    return {k:int(v) for k,v in (x.rstrip().split('\t',1) for x in open(p) if '\t' in x)}
a,b,t=read(sys.argv[1]),read(sys.argv[2]),read(sys.argv[3])
if abs(b.get('objects',0)-a.get('objects',0)) > t.get('objects_tolerance',0): raise SystemExit('write pool object tolerance exceeded')
for k in ('stored','bytes_used'):
    if abs(b.get(k,0)-a.get(k,0)) > t.get('bytes_tolerance',0): raise SystemExit('write pool byte tolerance exceeded: '+k)
PY
    then return 0; fi
    sleep 5
  done
  die write_pool_return_timeout
}

write_cell() {
  local arm=$1 cell=$2 out="$ROOT/cells/$cell" mnt file size digest rc sampler_rc stop="$ROOT/cells/$cell/STOP_SAMPLER"
  mkdir -m 0700 -p "$out" "$out/bwlog"; mount_temp "$arm" "$cell" rw; mnt=$(<"$out/mount-path.txt"); file=$(write_path "$arm" "$cell")
  mkdir -m 0700 -p "$(dirname "$file")"; [[ ! -e "$file" && ! -L "$file" ]] || die write_path_preexisting
  drain_snapshot "$out" || die write_baseline_metrics_missing
  mv -- "$out/drain-current.tsv" "$out/drain-baseline-pre.tsv"
  rm -f -- "$stop"; sample_cell "$cell" "$stop" >"$out/sampler.stdout" 2>"$out/sampler.stderr" & local sampler_pid=$!
  ACTIVE_SAMPLER_PID=$sampler_pid; ACTIVE_SAMPLER_STOP=$stop
  local registered=$(date +%s%N); printf '%s\n' "$registered" >"$out/fio-registered-start-ns.txt"
  local process_start=$(date +%s%N); printf '%s\n' "$process_start" >"$out/fio-process-start-ns.txt"
  local -a cmd=(fio --name=write16m --filename="$file" --rw=write --bs=16M --size=10G --runtime=120 --time_based --ioengine=psync --iodepth=1 --direct=1 --numjobs=1 --allow_file_create=1 --group_reporting --write_bw_log="$out/bwlog/$cell" --log_avg_msec=1000 --output="$out/fio.json" --output-format=json+ --buffer_pattern=0x5a)
  record "${cmd[@]}"; set +e; timeout 360 "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; local completion=$(date +%s%N); : >"$stop"; wait "$sampler_pid"; sampler_rc=$?; ACTIVE_SAMPLER_PID=; ACTIVE_SAMPLER_STOP=; set -e
  printf '%s\n' "$completion" >"$out/fio-completion-ns.txt"; printf '%s\n' "$rc" >"$out/fio.rc"; printf '%s\n' "$sampler_rc" >"$out/sampler.rc"
  (( rc == 0 )) || die write_fio_failed; (( sampler_rc == 0 )) || die write_sampler_failed
  python3 "$ANALYZER" cell "$out" write16m --expected-file "$file" >"$out/analysis.json"
  drain_write "$cell"; size=$(stat -c %s "$file"); [[ "$size" == 10737418240 ]] || die write_size_before_umount
  digest=$(sha256sum "$file" | awk '{print $1}'); printf 'bytes\t%s\nsha256\t%s\npath\t%s\n' "$size" "$digest" "$file" >"$out/write-fingerprint.tsv"
  graceful_umount "$cell"
  mount_temp "$arm" "$cell-remount" rw; mnt=$(<"$ROOT/cells/$cell-remount/mount-path.txt"); file=$(write_path "$arm" "$cell")
  [[ $(stat -c %s "$file") == "$size" ]] || die write_remount_size
  [[ $(sha256sum "$file" | awk '{print $1}') == "$digest" ]] || die write_remount_hash
  unlink -- "$file"; rmdir "$(dirname "$file")" 2>/dev/null || true; rmdir "$(dirname "$(dirname "$file")")" 2>/dev/null || true
  graceful_umount "$cell-remount"; scan_logs "$out"; scan_logs "$ROOT/cells/$cell-remount"
  local meta=$(temp_meta "$arm"); record env JFS_GC_SKIPPEDTIME=0 "CEPH_CONF=$CEPH_CONF" timeout 1800 "$JFS" gc --delete --threads 32 "$meta"; timeout 1800 env JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" "$JFS" gc --delete --threads 32 "$meta" >"$out/gc-delete.stdout" 2>"$out/gc-delete.stderr" || die write_gc_failed
  pool_return_guard "$out/pool-post-gc.tsv"; printf 'WRITE_PASS\t%s\n' "$arm" >"$out/PASS"
}

resume_s2w01() {
  local supplied=$1 cell=S2W01 arm=b256 out="$ROOT/cells/S2W01" mnt file size digest meta
  [[ "$supplied" == "I_ACK_04TMP3B_STEP2_WRITE_RESUME_S2W01_$RUN_ID" ]] || die invalid_write_resume_ack
  valid_scope; load_step2_id; fixed_binary; prepare_ceph_conf
  [[ -f "$ROOT/STEP2_CREATE_CANARY_PASS" && -f "$ROOT/plans/step2-plan-contract.sha256" ]] || die write_resume_prerequisite
  (cd / && sha256sum -c "$ROOT/plans/step2-plan-contract.sha256") >/dev/null || die step2_plan_contract_drift
  verify_current_fingerprint; health_gate S2W01-RECOVERY-pre unpaused
  [[ -d "$out" && ! -L "$out" && ! -e "$out/PASS" && ! -e "$out/gc-delete.stdout" ]] || die write_resume_cell_state
  [[ $(<"$out/fio.rc") == 0 && $(<"$out/sampler.rc") == 0 && -s "$out/analysis.json" ]] || die write_resume_fio_evidence
  python3 - "$out/analysis.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get('workload') == 'write16m' and d.get('runtime_ms',0) >= 118000
PY
  mnt=$(<"$out/mount-path.txt"); [[ "$mnt" == "$(temp_mnt b256)" ]] || die write_resume_mount_path
  if mountpoint -q "$mnt"; then
    [[ ! -L "$mnt" ]] || die write_resume_mount_symlink
    grep -Fq "JuiceFS:$(temp_name b256) $mnt fuse.juicefs" < <(findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS) || die write_resume_mount_identity
    file=$(write_path "$arm" "$cell"); [[ -f "$file" && ! -L "$file" && $(stat -c %s "$file") == 10737418240 ]] || die write_resume_payload
    drain_write "$cell"; size=$(stat -c %s "$file"); digest=$(sha256sum "$file" | awk '{print $1}')
    printf 'bytes\t%s\nsha256\t%s\npath\t%s\n' "$size" "$digest" "$file" >"$out/write-fingerprint.tsv"
    graceful_umount "$cell"
  else
    [[ ! -e "$mnt" && -s "$out/drain-pass.tsv" && -s "$out/write-fingerprint.tsv" ]] || die write_resume_unmounted_stage_invalid
    size=$(awk -F '\t' '$1=="bytes"{print $2}' "$out/write-fingerprint.tsv")
    digest=$(awk -F '\t' '$1=="sha256"{print $2}' "$out/write-fingerprint.tsv")
    [[ "$size" == 10737418240 && "$digest" =~ ^[0-9a-f]{64}$ ]] || die write_resume_fingerprint_invalid
  fi
  mount_temp "$arm" "$cell-remount" rw; file=$(write_path "$arm" "$cell")
  [[ $(stat -c %s "$file") == "$size" ]] || die write_remount_size
  [[ $(sha256sum "$file" | awk '{print $1}') == "$digest" ]] || die write_remount_hash
  unlink -- "$file"; rmdir "$(dirname "$file")" 2>/dev/null || true; rmdir "$(dirname "$(dirname "$file")")" 2>/dev/null || true
  graceful_umount "$cell-remount"; scan_logs "$out"; scan_logs "$ROOT/cells/$cell-remount"
  meta=$(temp_meta "$arm"); record env JFS_GC_SKIPPEDTIME=0 "CEPH_CONF=$CEPH_CONF" timeout 1800 "$JFS" gc --delete --threads 32 "$meta"
  timeout 1800 env JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" "$JFS" gc --delete --threads 32 "$meta" >"$out/gc-delete.stdout" 2>"$out/gc-delete.stderr" || die write_gc_failed
  pool_return_guard "$out/pool-post-gc.tsv"; health_gate S2W01-RECOVERY-post unpaused; verify_current_fingerprint
  printf 'WRITE_PASS_RECOVERED\t%s\n' "$arm" >"$out/PASS"
  printf 'S2W01_RECOVERY_PASS\n' >"$ROOT/S2W01_RECOVERY_PASS"
}

step2_write() {
  local supplied=$1
  [[ "$supplied" == "I_ACK_04TMP3B_STEP2_WRITE_$RUN_ID" ||
     "$supplied" == "I_ACK_04TMP3B_STEP2_WRITE_EXECUTE_$RUN_ID" ]] || die invalid_step2_ack
  step2_write_preflight
  if [[ "$supplied" == "I_ACK_04TMP3B_STEP2_WRITE_$RUN_ID" ]]; then
    write_plan_step2
    sha256sum "$EXECUTOR" "$ANALYZER" "$SCRUB" >"$ROOT/plans/step2-write-runtime-scripts.sha256"
    printf 'STEP2_WRITE_NOT_AUTHORIZED_PLAN_ONLY\n' >&2; exit 42
  fi
  [[ "$supplied" == "I_ACK_04TMP3B_STEP2_WRITE_EXECUTE_$RUN_ID" ]] || die write_execute_ack_required
  [[ -f "$ROOT/plans/step2-write-plan.tsv" && -f "$ROOT/plans/step2-write-plan.tsv.sha256" ]] || die write_plan_required
  sha256sum -c "$ROOT/plans/step2-write-plan.tsv.sha256" >/dev/null || die write_plan_drift
  [[ -f "$ROOT/plans/step2-write-pool-tolerance.tsv.sha256" ]] || die write_tolerance_plan_required
  sha256sum -c "$ROOT/plans/step2-write-pool-tolerance.tsv.sha256" >/dev/null || die write_tolerance_plan_drift
  [[ -f "$ROOT/plans/step2-write-runtime-scripts.sha256" ]] || die write_runtime_plan_required
  (cd / && sha256sum -c "$ROOT/plans/step2-write-runtime-scripts.sha256") >/dev/null || die write_runtime_script_drift
  ACTIVE_LEASE="$RUN_ID-step2write-retry2-phase-a"; trap on_exit EXIT TERM INT HUP
  scrub_run pause "$ACTIVE_LEASE" "$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt")" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$ROOT/scrub/$ACTIVE_LEASE-pause.log" 2>&1
  scrub_run verify-paused "$ACTIVE_LEASE" >>"$ROOT/scrub/$ACTIVE_LEASE-pause.log" 2>&1
  local arm cell i=0; for arm in b256 b4 b4 b256; do
    i=$((i+1)); cell=$(printf 'S2W%02d' "$i")
    if [[ "$cell" == S2W01 && -f "$ROOT/S2W01_RECOVERY_PASS" && -f "$ROOT/cells/$cell/PASS" ]]; then
      grep -Fqx $'WRITE_PASS_RECOVERED\tb256' "$ROOT/cells/$cell/PASS" || die write_recovery_marker_invalid
      continue
    fi
    [[ ! -e "$ROOT/cells/$cell/PASS" ]] || die unexpected_preexisting_write_cell
    health_gate "$cell-pre" paused; write_cell "$arm" "$cell"; health_gate "$cell-post" paused
  done
  scrub_run restore "$ACTIVE_LEASE" >"$ROOT/scrub/$ACTIVE_LEASE-restore.log" 2>&1
  scrub_run verify-restored "$ACTIVE_LEASE" >>"$ROOT/scrub/$ACTIVE_LEASE-restore.log" 2>&1
  ACTIVE_LEASE=; health_gate STEP2-WRITE-restored unpaused; verify_current_fingerprint
  printf 'STEP2_WRITE_PASS\n' >"$ROOT/STEP2_WRITE_PASS"; state ACTIVE PERSISTING ACTIVE PRESERVED NONE STEP2_WRITE
}

cleanup_plan_step2() {
  valid_scope; [[ -f "$ROOT/STEP2_CREATE_CANARY_PASS" ]] || die step2_create_required
  mkdir -m 0700 -p "$ROOT/closure"; local out="$ROOT/closure/step2-cleanup-plan.tsv"
  printf 'arm\tmeta\tname\tuuid\tmount\tprefix\n' >"$out"
  local arm meta name uuid current
  current=$(tr -d '[:space:]' <"$ROOT/inventory/current-uuid.txt")
  for arm in b256 b4; do
    meta=$(temp_meta "$arm"); name=$(temp_name "$arm"); [[ -f "$(temp_out "$arm")/identity.tsv" ]] || die temp_identity_missing
    uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$(temp_out "$arm")/identity.tsv")
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ && "$uuid" != "$current" ]] || die temp_uuid_invalid
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$arm" "$meta" "$name" "$uuid" "$(temp_mnt "$arm")" "$name" >>"$out"
  done
  sha256sum "$out" >"$out.sha256"; printf 'CLEANUP_PLAN_PASS\t%s\n' "$out"
}

cleanup_step2_pending() {
  printf 'STEP2_CLEANUP_NOT_IMPLEMENTED_NO_GC_DESTROY\n' >&2
  exit 42
}
sample_cell() {
  local cell=$1 out="$ROOT/cells/$cell" stop=$2 worker start nic epoch tmp
  worker=$(awk -F '\t' '$1=="worker_pid"{print $2}' "$out/mount-state.tsv")
  start=$(awk -F '\t' '$1=="worker_starttime"{print $2}' "$out/mount-state.tsv")
  nic=$(<"$ROOT/inventory/nic.txt")
  printf 'epoch_ns\tpid\tstarttime_ticks\tutime_ticks\tstime_ticks\trss_pages\tthreads\tload1\trunnable\tblocked\trx_bytes\ttx_bytes\n' >"$out/client-sidecar.tsv"
  printf 'epoch_ns\tmetric\tvalue\n' >"$out/juicefs-metrics.tsv"
  while [[ ! -e "$stop" ]]; do
    [[ -r /proc/$worker/stat && $(awk '{print $22}' /proc/"$worker"/stat) == "$start" ]] || return 42
    epoch=$(date +%s%N)
    python3 - "$worker" "$start" "$epoch" "$nic" >>"$out/client-sidecar.tsv" <<'PY'
import pathlib,sys
pid,start,epoch,nic=sys.argv[1:]
st=pathlib.Path('/proc',pid,'stat').read_text().split()
status=pathlib.Path('/proc',pid,'status').read_text().splitlines()
threads=next(x.split()[1] for x in status if x.startswith('Threads:'))
load=pathlib.Path('/proc/loadavg').read_text().split()
blocked=next(x.split()[1] for x in pathlib.Path('/proc/stat').read_text().splitlines() if x.startswith('procs_blocked '))
rx=pathlib.Path('/sys/class/net',nic,'statistics/rx_bytes').read_text().strip()
tx=pathlib.Path('/sys/class/net',nic,'statistics/tx_bytes').read_text().strip()
print(epoch,pid,start,st[13],st[14],st[23],threads,load[0],load[3].split('/')[0],blocked,rx,tx,sep='\t')
PY
    tmp="$out/.metrics-$epoch.tmp"
    if curl -fsS --connect-timeout 2 --max-time 5 "http://$METRICS_ADDR/metrics" >"$tmp"; then
      # JuiceFS 1.4 exposes operation names as labels (for example
      # object_request_data_bytes{method="GET"}), not as metric-name suffixes.
      awk -v e="$epoch" '$1 ~ /^(juicefs_fuse_ops_total|juicefs_fuse_(read|written)_size_bytes_(sum|count)|juicefs_object_request_(durations_histogram_seconds_(sum|count)|data_bytes|errors|uploading)|juicefs_used_(read_)?buffer_size_bytes|juicefs_process_cpu_seconds_total)(\{|$)/ {print e"\t"$1"\t"$2}' "$tmp" >>"$out/juicefs-metrics.tsv"
      rm -f -- "$tmp"
    else
      rm -f -- "$tmp"; return 43
    fi
    sleep 1
  done
}
fio_cell() {
  local cell=$1 mnt=$2 out="$ROOT/cells/$cell" file="$mnt$ASSET_REL" registered completion rc sampler_rc stop="$ROOT/cells/$cell/STOP_SAMPLER"
  mkdir -m 0700 -p "$out/bwlog"; [[ -f "$file" && ! -L "$file" ]] || die cell_asset_missing
  rm -f -- "$stop"; sample_cell "$cell" "$stop" >"$out/sampler.stdout" 2>"$out/sampler.stderr" & local sampler_pid=$!; ACTIVE_SAMPLER_PID=$sampler_pid; ACTIVE_SAMPLER_STOP=$stop
  registered=$(date +%s%N); printf '%s\n' "$registered" >"$out/fio-registered-start-ns.txt"
  local -a cmd=(fio --name=read20m --filename="$file" --rw=read --bs=20M --size=10G --runtime=60 --time_based --ioengine=psync --iodepth=1 --direct=1 --numjobs=1 --allow_file_create=0 --group_reporting --write_bw_log="$out/bwlog/$cell" --log_avg_msec=1000 --output="$out/fio.json" --output-format=json+)
  record "${cmd[@]}"; set +e; timeout 240 "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; completion=$(date +%s%N); : >"$stop"; wait "$sampler_pid"; sampler_rc=$?; ACTIVE_SAMPLER_PID=; ACTIVE_SAMPLER_STOP=; set -e
  printf '%s\n' "$completion" >"$out/fio-completion-ns.txt"; printf '%s\n' "$rc" >"$out/fio.rc"; printf '%s\n' "$sampler_rc" >"$out/sampler.rc"
  (( rc == 0 )) || die fio_failed; (( sampler_rc == 0 )) || die sampler_failed
  [[ $(find "$out/bwlog" -maxdepth 1 -type f -name '*_bw.*.log' | wc -l) == 1 ]] || die bwlog_missing
  [[ $(awk 'END{print NR-1}' "$out/client-sidecar.tsv") -ge 38 ]] || die client_sidecar_coverage
  [[ $(awk 'NR>1{a[$1]=1} END{print length(a)}' "$out/juicefs-metrics.tsv") -ge 38 ]] || die juicefs_metrics_coverage
  python3 "$ANALYZER" cell "$out" read20m --expected-file "$file" >"$out/analysis.json"
  python3 - "$out/analysis.json" "$out/client-sidecar.tsv" "$out/juicefs-metrics.tsv" >"$out/sidecar-coverage.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); start=d['actual_start_ns']+10_000_000_000; end=d['actual_start_ns']+50_000_000_000
result={}
for label,path in [('client',sys.argv[2]),('juicefs',sys.argv[3])]:
    epochs=sorted({int(x.split('\t',1)[0]) for x in open(path).read().splitlines()[1:] if x})
    inside=[x for x in epochs if start <= x <= end]
    gaps=[(b-a)/1e9 for a,b in zip(inside,inside[1:])]
    ok=len(inside) >= 38 and inside[0] <= start+2_000_000_000 and inside[-1] >= end-2_000_000_000 and (max(gaps,default=0)<=3.0)
    result[label]={'samples':len(inside),'first_offset_s':(inside[0]-start)/1e9 if inside else None,'last_short_s':(end-inside[-1])/1e9 if inside else None,'max_gap_s':max(gaps,default=None),'pass':ok}
    if not ok: raise SystemExit(label+' sidecar formal-window coverage failed')
metrics=[x.rstrip('\n').split('\t',2) for x in open(sys.argv[3]).readlines()[1:] if x.strip()]
formal=[(int(e),name,float(value)) for e,name,value in metrics if start <= int(e) <= end]
required={
 'fuse_read_ops': lambda n: n.startswith('juicefs_fuse_ops_total{') and 'method="read"' in n,
 'fuse_read_bytes': lambda n: n.startswith('juicefs_fuse_read_size_bytes_sum{'),
 'fuse_read_count': lambda n: n.startswith('juicefs_fuse_read_size_bytes_count{'),
 'object_get_bytes': lambda n: n.startswith('juicefs_object_request_data_bytes{') and 'method="GET"' in n,
 'object_get_duration_sum': lambda n: n.startswith('juicefs_object_request_durations_histogram_seconds_sum{') and 'method="GET"' in n,
 'object_get_duration_count': lambda n: n.startswith('juicefs_object_request_durations_histogram_seconds_count{') and 'method="GET"' in n,
 'object_errors': lambda n: n.startswith('juicefs_object_request_errors{'),
 'object_uploading': lambda n: n.startswith('juicefs_object_request_uploading{'),
 'used_buffer': lambda n: n.startswith('juicefs_used_buffer_size_bytes{'),
 'used_read_buffer': lambda n: n.startswith('juicefs_used_read_buffer_size_bytes{'),
}
presence={k:len({e for e,n,_ in formal if test(n)}) for k,test in required.items()}
result['mechanism_metric_samples']=presence
if any(v < 38 for v in presence.values()): raise SystemExit('mechanism metric formal-window coverage failed: '+repr(presence))
print(json.dumps(result,sort_keys=True))
PY
}
select_ra() {
  python3 - "$ROOT" <<'PY' >"$ROOT/plans/selected-ra.txt"
import json,sys
from pathlib import Path
r=Path(sys.argv[1]); vals={}
for arm,cells in (("8M",("R01","R06")),("16M",("R02","R05")),("32M",("R03","R04"))):
    try: vals[arm]=[json.loads((r/'cells'/c/'analysis.json').read_text())['formal_median_MiBs'] for c in cells]
    except (FileNotFoundError,KeyError,TypeError): raise SystemExit('missing RA analysis')
base=vals['8M']; candidates=[]
for arm in ('8M','16M','32M'):
    if all(v/b >= 1.10 for v,b in zip(vals[arm],base)): candidates.append(arm)
if not candidates: print('8M')
else:
    best=max(max(vals[x]) for x in candidates); print(min((x for x in candidates if best/max(vals[x]) <= 1.05), key=lambda x: int(x[:-1])))
PY
  SELECTED_RA=$(<"$ROOT/plans/selected-ra.txt"); SELECTED_RA="${SELECTED_RA}"
}
verify_current_fingerprint() {
  mountpoint -q "$REF" || die current_mount_lost
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/current-mount-post.tsv"
  cmp -s "$ROOT/inventory/current-mount.tsv" "$ROOT/inventory/current-mount-post.tsv" || die current_mount_drift
  printf 'realpath\t%s\ninode\t%s\nbytes\t%s\nmtime\t%s\nhead_sha256\t%s\ntail_sha256\t%s\n' "$(readlink -f "$ASSET")" "$(stat -c %i "$ASSET")" "$(stat -c %s "$ASSET")" "$(stat -c %Y "$ASSET")" "$(head -c 1048576 "$ASSET" | sha256sum | awk '{print $1}')" "$(tail -c 1048576 "$ASSET" | sha256sum | awk '{print $1}')" >"$ROOT/inventory/seqread-asset-post.tsv"
  cmp -s "$ROOT/inventory/seqread-asset.tsv" "$ROOT/inventory/seqread-asset-post.tsv" || die current_asset_drift
  timeout 30 "$JFS" status "$META" >"$ROOT/inventory/current-status-post.json"
  python3 - "$ROOT/inventory/current-status.json" "$ROOT/inventory/current-status-post.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])).get('Setting') or {}
b=json.load(open(sys.argv[2])).get('Setting') or {}
if a != b: raise SystemExit('current volume Setting drift')
PY
}
step1_read() {
  local supplied=$1; [[ "$supplied" == "I_ACK_04TMP3B_STEP1_READ_$RUN_ID" ]] || die invalid_step1_ack; valid_scope; [[ -f "$ROOT/inventory/PASS" ]] || die inventory_required; fixed_binary
  (cd / && sha256sum -c "$ROOT/plans/runtime-scripts.sha256") >/dev/null || die runtime_script_drift
  if python3 - <<'PY'
import pathlib
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if (p/'comm').read_text().strip() == 'fio': raise SystemExit(1)
    except OSError: pass
PY
  then :; else die foreign_fio_exists; fi
  if findmnt -rn -o TARGET | awk '$1 ~ /^\/tmp\/jfs-04tmp3b-/ {bad=1} END{exit bad+0}'; then :; else die residual_tmp3b_mount; fi
  prepare_ceph_conf; health_gate STEP1-pre unpaused; ACTIVE_LEASE="$RUN_ID-phase-a"; trap on_exit EXIT TERM INT HUP; scrub_run pause "$ACTIVE_LEASE" "$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt")" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$ROOT/scrub/$ACTIVE_LEASE-pause.log" 2>&1; scrub_run verify-paused "$ACTIVE_LEASE" >>"$ROOT/scrub/$ACTIVE_LEASE-pause.log" 2>&1
  local i=0 arm cell mnt; for arm in ra8 ra16 ra32 ra32 ra16 ra8; do i=$((i+1)); cell=$(printf 'R%02d' "$i"); mkdir -m 0700 -p "$ROOT/cells/$cell"; health_gate "$cell-pre" paused; mount_read "$cell" "$arm"; mnt=$(<"$ROOT/cells/$cell/mount-path.txt"); fio_cell "$cell" "$mnt"; graceful_umount "$cell"; health_gate "$cell-post" paused; done
  select_ra; i=0; for arm in async-off async-on async-on async-off; do i=$((i+1)); cell=$(printf 'A%02d' "$i"); mkdir -m 0700 -p "$ROOT/cells/$cell"; health_gate "$cell-pre" paused; mount_read "$cell" "$arm"; mnt=$(<"$ROOT/cells/$cell/mount-path.txt"); fio_cell "$cell" "$mnt"; graceful_umount "$cell"; health_gate "$cell-post" paused; done
  scrub_run restore "$ACTIVE_LEASE" >"$ROOT/scrub/$ACTIVE_LEASE-restore.log" 2>&1; scrub_run verify-restored "$ACTIVE_LEASE" >>"$ROOT/scrub/$ACTIVE_LEASE-restore.log" 2>&1; ACTIVE_LEASE=; health_gate STEP1-restored unpaused; verify_current_fingerprint; printf 'STEP1_READ_PASS\n' >"$ROOT/STEP1_READ_PASS"; state ACTIVE PERSISTING ACTIVE PRESERVED NONE STEP1_READ
}
# Failure preserves the scene: do not unmount, delete, or destroy here.
on_exit() { local rc=$? restore_rc=0; trap - EXIT TERM INT HUP; set +e; if [[ -n ${ACTIVE_SAMPLER_STOP:-} ]]; then : >"$ACTIVE_SAMPLER_STOP"; fi; if [[ -n ${ACTIVE_SAMPLER_PID:-} ]]; then wait "$ACTIVE_SAMPLER_PID" || true; fi; if [[ -n "${ACTIVE_LEASE:-}" ]]; then scrub_run restore "$ACTIVE_LEASE" >>"$ROOT/scrub/$ACTIVE_LEASE-restore.log" 2>&1 || restore_rc=$?; (( restore_rc == 0 )) && scrub_run verify-restored "$ACTIVE_LEASE" >>"$ROOT/scrub/$ACTIVE_LEASE-restore.log" 2>&1 || restore_rc=$?; fi; (( restore_rc == 0 )) || rc=97; exit "$rc"; }
step2_pending() { local supplied=$1 stage=$2; [[ "$supplied" == "I_ACK_04TMP3B_${stage}_$RUN_ID" ]] || die invalid_step2_ack; printf 'STEP2_NOT_IMPLEMENTED_PENDING_STEP1_DECISION\n' >&2; exit 42; }
bundle() { valid_scope; [[ -d "$ROOT" ]] || die root_missing; mkdir -m 0700 -p "$ROOT/closure"; local tarball="$REMOTE_PARENT/04tmp3b-$RUN_ID-evidence.tar"; [[ ! -e "$tarball" && ! -L "$tarball" ]] || die bundle_exists; (cd "$ROOT" && find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum) >"$ROOT/closure/manifest.sha256"; sha256sum "$ROOT/closure/manifest.sha256" >"$ROOT/closure/manifest.sha256.digest"; tar -C "$REMOTE_PARENT" -cf "$tarball" "opencode-04tmp3b-$RUN_ID"; sha256sum "$tarball" >"$tarball.sha256"; printf 'BUNDLE_PASS\t%s\n' "$tarball"; }
self_test() { RUN_ID=20260904-000000; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; valid_scope; [[ "$(tmp_name 2>/dev/null || true)" == "" ]] || :; [[ "$ROOT" != / && "$ROOT" != *..* ]]; ( [[ "I_ACK_04TMP3B_STEP1_READ_$RUN_ID" == "I_ACK_04TMP3B_STEP1_READ_$RUN_ID" ]] ); printf 'T04TMP3B_EXECUTOR_SELFTEST_PASS\n'; }
tmp_name() { return 1; }

reject_overrides
if [[ ${1:-} == --self-test ]]; then self_test; exit 0; fi
MODE=${1:-}; [[ -n "$MODE" ]] || usage
case "$MODE" in
  inventory-plan) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; inventory_plan;;
  step1-read) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; step1_read "$3";;
  step2-plan) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; step2_plan;;
  step2-create-canary) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; step2_create_canary "$3";;
  step2-read) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; step2_read_phase "$3";;
  step2-write) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; step2_write "$3";;
  step2-write-resume-s2w01) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; resume_s2w01 "$3";;
  cleanup-plan) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; cleanup_plan_step2;;
  cleanup) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; cleanup_step2_pending;;
  bundle) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3b-$RUN_ID"; bundle;;
  *) usage;;
esac
