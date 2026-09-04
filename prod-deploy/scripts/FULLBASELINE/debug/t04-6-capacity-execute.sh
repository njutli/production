#!/usr/bin/env bash
# Minimal state-driven executor for the frozen 04-6 nine-cell matrix.
# It reuses juicefs-prod through one RUN-scoped second mount.  It never formats
# or destroys a volume, changes a pool/PG/service setting, or performs a forced
# unmount.  On failure it restores only this RUN's scrub lease and preserves the
# remaining mount/data/evidence for explicit inspection.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

MODE=${1:-}
RUN_ID=${2:-}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRIVER=$SELF_DIR/t04-6-capacity-driver.sh
SAMPLER=$SELF_DIR/t04-6-capacity-sampler.sh
ANALYZER=$SELF_DIR/t04-6-capacity-analyze.py
SCRUB_CONTROL=$SELF_DIR/u141d-scrub-control.sh

ROOT=/tmp/production/opencode-04-6-$RUN_ID
MNT=/tmp/jfs-t046-$RUN_ID
REFERENCE_MNT=/mnt/juicefs
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
POOL=juicefs-data
EXPECTED_FSID=f8137e5a-8af2-11f1-aa1c-4df480fc234d
EXPECTED_OSDS=(0 1 2 3 4 5)
CEPH_CONF=$ROOT/inventory/ceph-msgr8.conf
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
LEASE=$RUN_ID-phase-a
STATE_DIR=$ROOT/state
EXEC_DIR=$ROOT/execute
STATE=$EXEC_DIR/state.tsv
COMMANDS=$ROOT/commands.sh
INCIDENTS=$EXEC_DIR/incidents.tsv
PHASES=$EXEC_DIR/phases.tsv
OBJECT_TOLERANCE=8192
QUIET_TIMEOUT=${T046_QUIET_TIMEOUT:-1800}
SAMPLE_DURATION=${T046_SAMPLE_DURATION:-240}
CEPH_NIC=${T046_NIC:-enp139s0f0np0}

die() { printf 'T046_EXECUTE_FAIL\t%s\n' "$*" >&2; exit 42; }

usage() {
  cat >&2 <<'EOF'
usage: t04-6-capacity-execute.sh inventory-plan RUN_ID
       t04-6-capacity-execute.sh run RUN_ID
       t04-6-capacity-execute.sh inspect RUN_ID
       t04-6-capacity-execute.sh --self-test
EOF
  exit 2
}

valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "invalid RUN_ID: ${RUN_ID:-missing}"
  [[ $ROOT == "/tmp/production/opencode-04-6-$RUN_ID" && $ROOT != / && $ROOT != *..* ]] || die 'unsafe ROOT'
  [[ $MNT == "/tmp/jfs-t046-$RUN_ID" && $MNT != / && $MNT != *..* ]] || die 'unsafe MNT'
  [[ ! -L $ROOT && ! -L $MNT ]] || die 'symlinked RUN path refused'
}

record() {
  [[ -e $COMMANDS ]] || die 'commands audit is unavailable'
  printf '%q ' "$@" >>"$COMMANDS"
  printf '\n' >>"$COMMANDS"
}

phase() {
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "${3:-none}" >>"$PHASES"
}

incident() {
  [[ -n ${INCIDENTS:-} && -d ${EXEC_DIR:-/nonexistent} ]] || return 0
  printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "${2:-none}" >>"$INCIDENTS" || true
}

require_tools() {
  local tool
  for tool in bash ceph curl findmnt fio ip md5sum mountpoint python3 sha256sum sudo timeout; do
    command -v "$tool" >/dev/null || die "required tool missing: $tool"
  done
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die 'JuiceFS binary identity mismatch'
  for tool in "$DRIVER" "$SAMPLER" "$ANALYZER" "$SCRUB_CONTROL"; do
    [[ -s $tool && ! -L $tool ]] || die "script missing/symlinked: $tool"
  done
}

make_private_ceph_conf() {
  [[ -r /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die 'system ceph.conf unavailable'
  cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
  [[ $(md5sum "$CEPH_CONF" | awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die 'private ceph.conf MD5 mismatch'
}

require_private_ceph_conf() {
  [[ -r $CEPH_CONF && ! -L $CEPH_CONF ]] || die 'private ceph.conf missing/symlinked'
  [[ $(md5sum "$CEPH_CONF" | awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die 'private ceph.conf identity drift'
}

ceph_read() { CEPH_CONF="$CEPH_CONF" ceph "$@"; }

pool_stats() {
  ceph_read df detail --format json | python3 -c '
import json, sys
pool = sys.argv[1]
d = json.load(sys.stdin)
rows = [x for x in d.get("pools", []) if x.get("name") == pool]
if len(rows) != 1: raise SystemExit(f"pool {pool!r} is not unique")
s = rows[0].get("stats", {})
for key in ("objects", "stored", "bytes_used"):
    if not isinstance(s.get(key), int): raise SystemExit(f"missing integer pool stat: {key}")
print("{}\t{}\t{}".format(s["objects"], s["stored"], s["bytes_used"]))
' "$POOL"
}

health_gate() {
  local label=$1 expected=$2 fsid out
  out=$EXEC_DIR/health-$label
  mkdir -m 0700 -p "$out"
  fsid=$(ceph_read fsid | tr -d '[:space:]') || die "cannot read Ceph FSID ($label)"
  [[ $fsid == "$EXPECTED_FSID" ]] || die "Ceph FSID mismatch ($label): $fsid"
  printf '%s\n' "$fsid" >"$out/fsid.txt"
  ceph_read -s --format json >"$out/status.json" || die "cannot read Ceph status ($label)"
  ceph_read osd ls --format json >"$out/osd-ls.json" || die "cannot read OSD IDs ($label)"
  ceph_read osd dump --format json >"$out/osd-dump.json" || die "cannot read OSD flags ($label)"
  python3 - "$out/status.json" "$out/osd-ls.json" "$expected" <<'PY'
import json, sys
status_path, ids_path, mode = sys.argv[1:]
d = json.load(open(status_path))
ids = sorted(json.load(open(ids_path)))
if ids != list(range(6)):
    raise SystemExit(f"OSD identity mismatch: {ids}")
states = d.get("pgmap", {}).get("pgs_by_state", [])
if not states or any(x.get("state_name") != "active+clean" for x in states):
    raise SystemExit(f"PGs are not wholly active+clean: {states}")
health = d.get("health", {})
state = health.get("status")
checks = set((health.get("checks") or {}).keys())
if mode == "unpaused":
    if state != "HEALTH_OK" or checks:
        raise SystemExit(f"unexpected unpaused health: {state} {sorted(checks)}")
elif mode == "paused":
    if not ((state == "HEALTH_OK" and not checks) or
            (state == "HEALTH_WARN" and checks == {"OSDMAP_FLAGS"})):
        raise SystemExit(f"unexpected paused health: {state} {sorted(checks)}")
else:
    raise SystemExit(f"invalid health mode: {mode}")
PY
  printf 'HEALTH_GATE_PASS\t%s\t%s\n' "$label" "$expected" >"$out/PASS"
}

foreign_fio_gate() {
  local label=$1 out
  out=$EXEC_DIR/foreign-fio-$label.tsv
  printf 'pid\tstarttime\tcmdline\n' >"$out"
  python3 - "$out" <<'PY'
import os, pathlib, sys
out = sys.argv[1]
rows = []
for ent in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        comm = (ent/'comm').read_text().strip()
        exe = os.path.basename(os.path.realpath(ent/'exe'))
        if comm != 'fio' and exe != 'fio':
            continue
        st = (ent/'stat').read_text().split()
        cmd = (ent/'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').strip()
        rows.append((int(ent.name), st[21], cmd))
    except (OSError, ValueError, IndexError):
        pass
with open(out, 'a') as f:
    for row in sorted(rows):
        f.write(f"{row[0]}\t{row[1]}\t{row[2]}\n")
if rows:
    raise SystemExit(f"foreign fio processes exist: {[x[0] for x in rows]}")
PY
}

mount_process_snapshot() {
  local mnt=$1 out=$2
  python3 - "$JFS" "$META" "$mnt" "$out" "$EXEC_DIR/juicefs-mount.log" <<'PY'
import os, pathlib, sys
exe, meta, mnt, out, run_log = sys.argv[1:]
exe = os.path.realpath(exe)
rows = []
for ent in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(ent/'exe') != exe:
            continue
        raw = (ent/'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').strip()
        words = raw.split()
        # JuiceFS' Go daemon rewrites argv after -d.  On some builds the final
        # mountpoint is truncated in /proc/PID/cmdline, while the earlier,
        # RUN-unique --log argument remains intact.  For the dedicated RUN
        # mount accept only that exact log path as the fallback identity; the
        # protected reference mount still requires its exact mountpoint.
        mount_identity = mnt in words
        if mnt.startswith('/tmp/jfs-t046-'):
            mount_identity = mount_identity or run_log in words
        if meta not in words or not mount_identity or 'mount' not in words:
            continue
        st = (ent/'stat').read_text().split()
        rows.append((int(ent.name), int(st[3]), st[21], raw))
    except (OSError, ValueError, IndexError):
        pass
if len(rows) != 2:
    raise SystemExit(f"expected one daemon/worker pair for {mnt}, got {[r[:2] for r in rows]}")
pids = {r[0] for r in rows}
workers = [r for r in rows if r[1] in pids]
if len(workers) != 1:
    raise SystemExit(f"mount parent/worker topology invalid: {[r[:2] for r in rows]}")
with open(out, 'w') as f:
    f.write('pid\tppid\tstarttime\tselected_worker\tcmdline\n')
    for r in sorted(rows):
        f.write(f"{r[0]}\t{r[1]}\t{r[2]}\t{int(r[0] == workers[0][0])}\t{r[3]}\n")
PY
}

volume_uuid() {
  timeout 30 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" | python3 -c '
import json,sys
d=json.load(sys.stdin)
u=(d.get("Setting") or {}).get("UUID")
if not isinstance(u,str) or not u: raise SystemExit("volume UUID unavailable")
print(u)'
}

capture_business_fingerprint() {
  local out=$1
  mkdir -m 0700 -p "$out"
  mountpoint -q "$REFERENCE_MNT" || die 'reference mount is absent'
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-findmnt.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REFERENCE_MNT fuse.juicefs" "$out/reference-findmnt.tsv" || die 'reference mount identity mismatch'
  mount_process_snapshot "$REFERENCE_MNT" "$out/reference-process.tsv"
  volume_uuid >"$out/reference-uuid.txt"
  findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS | awk 'tolower($0) ~ /weka/' | sort >"$out/weka-mounts.tsv"
  python3 - "$out/protected-processes.tsv" <<'PY'
import os, pathlib, re, sys
rx = re.compile(r'^(kubelet|containerd|dockerd|weka[^ ]*)$')
rows=[]
for ent in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        comm=(ent/'comm').read_text().strip()
        if not rx.match(comm): continue
        st=(ent/'stat').read_text().split()
        rows.append((int(ent.name),st[21],comm,os.path.realpath(ent/'exe')))
    except (OSError,ValueError,IndexError): pass
with open(sys.argv[1],'w') as f:
    f.write('pid\tstarttime\tcomm\texe\n')
    for r in sorted(rows): f.write('\t'.join(map(str,r))+'\n')
PY
}

business_unchanged() {
  local label=$1 out
  out=$EXEC_DIR/business-$label
  capture_business_fingerprint "$out"
  for name in reference-findmnt.tsv reference-process.tsv reference-uuid.txt weka-mounts.tsv protected-processes.tsv; do
    cmp -s "$ROOT/inventory/business-pre/$name" "$out/$name" || die "business fingerprint changed: $name ($label)"
  done
}

asset_manifest() {
  local base=$1 out=$2
  [[ -d $base/test_dir/mseqread && ! -L $base/test_dir/mseqread ]] || die 'mseqread directory missing/symlinked'
  [[ -d $base/test_dir/mseqwrite && ! -L $base/test_dir/mseqwrite ]] || die 'mseqwrite directory missing/symlinked'
  printf 'asset\tname\tsize\n' >"$out"
  local i p
  for i in $(seq 0 15); do
    p=$base/test_dir/mseqread/mseqread.$i.0
    [[ -f $p && ! -L $p && $(stat -c %s -- "$p") == 4294967296 ]] || die "invalid mseqread asset: $p"
    printf 'mseqread\tmseqread.%s.0\t4294967296\n' "$i" >>"$out"
  done
  for i in $(seq 0 127); do
    p=$base/test_dir/rw_test.$i.0
    [[ -f $p && ! -L $p && $(stat -c %s -- "$p") == 1073741824 ]] || die "invalid rw_test asset: $p"
    printf 'rw_test\trw_test.%s.0\t1073741824\n' "$i" >>"$out"
  done
  [[ $(find "$base/test_dir/mseqread" -mindepth 1 -maxdepth 1 | wc -l) -eq 16 ]] || die 'mseqread directory has unexpected entries'
}

require_mseqwrite_empty() {
  local base=$1
  [[ -d $base/test_dir/mseqwrite && ! -L $base/test_dir/mseqwrite ]] || die 'mseqwrite directory missing/symlinked'
  [[ -z $(find "$base/test_dir/mseqwrite" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'mseqwrite must be exactly empty'
}

verify_scripts() {
  (cd / && sha256sum -c "$ROOT/plan/runtime-scripts.sha256") >/dev/null || die 'runtime script drift'
}

scrub_state_path() { printf '%s/u141d-scrub-control-%s.tsv\n' "$STATE_DIR" "$LEASE"; }

scrub_restore() {
  local state_file rc
  state_file=$(scrub_state_path)
  [[ -f $state_file ]] || return 0
  # Restoration takes precedence over audit persistence during an abort.  A
  # full/damaged commands file must never prevent release of the owned flags.
  if [[ -e $COMMANDS ]]; then
    printf 'env %q %q restore %q\n' "U141D_SCRUB_STATE_DIR=$STATE_DIR" "$SCRUB_CONTROL" "$LEASE" >>"$COMMANDS" \
      || incident SCRUB_RESTORE_AUDIT_FAILED "$COMMANDS"
  fi
  set +e
  U141D_SCRUB_STATE_DIR="$STATE_DIR" "$SCRUB_CONTROL" restore "$LEASE" >"$EXEC_DIR/scrub-restore.log" 2>&1
  rc=$?
  set -e
  if (( rc != 0 )); then
    incident SCRUB_RESTORE_FAILED "rc=$rc state=$state_file"
    return "$rc"
  fi
  if ! U141D_SCRUB_STATE_DIR="$STATE_DIR" "$SCRUB_CONTROL" verify-restored "$LEASE" >>"$EXEC_DIR/scrub-restore.log" 2>&1; then
    incident SCRUB_RESTORE_VERIFY_FAILED "state=$state_file"
    return 1
  fi
  printf 'scrub_restored\t%s\n' "$(date +%s)" >>"$STATE"
}

RUN_TRAP_ARMED=0
RUN_COMPLETED=0
on_exit() {
  local rc=$? restore_rc=0
  trap - EXIT INT TERM HUP
  if (( RUN_TRAP_ARMED == 1 && RUN_COMPLETED == 0 )); then
    incident EXECUTOR_ABORT "rc=$rc; evidence and RUN mount retained"
    scrub_restore || restore_rc=$?
  fi
  if (( restore_rc != 0 )); then
    printf 'T046_EMERGENCY\tscrub restore failed; inspect %s\n' "$(scrub_state_path)" >&2
    exit 97
  fi
  exit "$rc"
}

mount_second() {
  [[ ! -e $MNT ]] || die "RUN mount path already exists: $MNT"
  mkdir -m 0700 "$MNT"
  local log=$EXEC_DIR/juicefs-mount.log
  local -a cmd=("$JFS" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K --log "$log" "$META" "$MNT")
  record timeout 180 env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$EXEC_DIR/mount.stdout" 2>"$EXEC_DIR/mount.stderr" || die 'RUN-scoped JuiceFS mount failed'
  local i
  for i in $(seq 1 120); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || die 'RUN-scoped mount timeout'
  findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$EXEC_DIR/run-findmnt.tsv"
  grep -Fq "JuiceFS:juicefs-prod $MNT fuse.juicefs" "$EXEC_DIR/run-findmnt.tsv" || die 'RUN-scoped mount source mismatch'
  mount_process_snapshot "$MNT" "$EXEC_DIR/run-mount-process.tsv"
  local worker threads uuid
  worker=$(awk -F '\t' '$4==1{print $1}' "$EXEC_DIR/run-mount-process.tsv")
  [[ $worker =~ ^[0-9]+$ ]] || die 'RUN mount worker not selected'
  threads=$(grep -l '^msgr-worker' /proc/"$worker"/task/*/comm 2>/dev/null | wc -l || true)
  [[ $threads -eq 8 ]] || die "expected 8 msgr-worker threads, got $threads"
  uuid=$(volume_uuid)
  [[ $uuid == "$(<"$ROOT/inventory/business-pre/reference-uuid.txt")" ]] || die 'second mount volume UUID mismatch'
  printf 'run_id\t%s\nmnt\t%s\nworker_pid\t%s\nworker_starttime\t%s\nuuid\t%s\nceph_conf_md5\t%s\n' \
    "$RUN_ID" "$MNT" "$worker" "$(awk -F '\t' '$4==1{print $3}' "$EXEC_DIR/run-mount-process.tsv")" "$uuid" "$CEPH_CONF_MD5" >"$EXEC_DIR/mount-state.tsv"
}

verify_second_mount() {
  local worker start actual_start actual_exe uuid
  mountpoint -q "$MNT" || die 'RUN-scoped mount disappeared'
  [[ $(findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE) == "JuiceFS:juicefs-prod $MNT fuse.juicefs" ]] || die 'RUN mount identity drift'
  worker=$(awk -F '\t' '$1=="worker_pid"{print $2}' "$EXEC_DIR/mount-state.tsv")
  start=$(awk -F '\t' '$1=="worker_starttime"{print $2}' "$EXEC_DIR/mount-state.tsv")
  [[ -r /proc/$worker/stat ]] || die 'RUN mount worker disappeared'
  actual_start=$(awk '{print $22}' /proc/"$worker"/stat)
  actual_exe=$(readlink -f /proc/"$worker"/exe)
  [[ $actual_start == "$start" && $actual_exe == "$JFS" ]] || die 'RUN mount PID/starttime/exe drift'
  uuid=$(volume_uuid)
  [[ $uuid == "$(awk -F '\t' '$1=="uuid"{print $2}' "$EXEC_DIR/mount-state.tsv")" ]] || die 'RUN volume UUID drift'
}

processes_gone() {
  python3 - "$JFS" "$EXEC_DIR/run-mount-process.tsv" <<'PY'
import csv, os, sys
exe=os.path.realpath(sys.argv[1])
with open(sys.argv[2], newline='') as f: rows=list(csv.DictReader(f, delimiter='\t'))
for row in rows:
    pid=row['pid']
    try:
        if os.path.realpath('/proc/'+pid+'/exe') == exe and open('/proc/'+pid+'/stat').read().split()[21] == row['starttime']:
            raise SystemExit(1)
    except OSError: pass
PY
}

unmount_second() {
  verify_second_mount
  record timeout 180 "$JFS" umount "$MNT"
  timeout 180 "$JFS" umount "$MNT" >"$EXEC_DIR/umount.stdout" 2>"$EXEC_DIR/umount.stderr" || die 'graceful RUN unmount failed'
  local i
  for i in $(seq 1 180); do ! mountpoint -q "$MNT" && break; sleep 1; done
  ! mountpoint -q "$MNT" || die 'RUN mount remains after graceful unmount'
  for i in $(seq 1 60); do processes_gone && break; sleep 1; done
  processes_gone || die 'RUN mount processes remain after graceful unmount'
  [[ -d $MNT && ! -L $MNT && -z $(find "$MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'underlying RUN mount directory is not verified empty'
  rmdir "$MNT"
  printf 'mount_closed\t%s\n' "$(date +%s)" >>"$STATE"
}

run_cell() {
  local cell=$1 out sampler_out stop worker sampler_pid driver_rc sampler_rc
  out=$ROOT/cells/$cell
  sampler_out=$out/sampler
  stop=$sampler_out/STOP_REQUEST
  verify_second_mount
  health_gate "$cell-pre" paused
  U141D_SCRUB_STATE_DIR="$STATE_DIR" "$SCRUB_CONTROL" verify-paused "$LEASE" >"$out/scrub-pre.txt"
  foreign_fio_gate "$cell-pre"
  worker=$(awk -F '\t' '$1=="worker_pid"{print $2}' "$EXEC_DIR/mount-state.tsv")
  record env "CEPH_CONF=$CEPH_CONF" "T046_MOUNT_POINT=$MNT" "T046_NIC=$CEPH_NIC" "T046_TIKV_SSH_USER=sunrise" \
    "$SAMPLER" "$RUN_ID" "$cell" "$sampler_out" "$SAMPLE_DURATION" "$worker" "$stop"
  CEPH_CONF="$CEPH_CONF" T046_MOUNT_POINT="$MNT" T046_NIC="$CEPH_NIC" T046_TIKV_SSH_USER=sunrise \
    "$SAMPLER" "$RUN_ID" "$cell" "$sampler_out" "$SAMPLE_DURATION" "$worker" "$stop" \
    >"$out/sampler.stdout" 2>"$out/sampler.stderr" &
  sampler_pid=$!
  printf 'pid\t%s\nstarttime\t%s\n' "$sampler_pid" "$(awk '{print $22}' /proc/"$sampler_pid"/stat)" >"$out/sampler-process.tsv"
  local i
  for i in $(seq 1 30); do [[ -s $sampler_out/SAMPLER_STARTED ]] && break; kill -0 "$sampler_pid" 2>/dev/null || break; sleep 1; done
  [[ -s $sampler_out/SAMPLER_STARTED ]] || { wait "$sampler_pid" || true; die "sampler failed to start: $cell"; }
  set +e
  T046_TEST_DIR="$MNT/test_dir" T046_EXECUTE_ACK=I_ACK_04_6_CELL_EXECUTION \
    "$DRIVER" run-cell "$RUN_ID" "$cell" "$ROOT"
  driver_rc=$?
  : >"$stop"
  wait "$sampler_pid"
  sampler_rc=$?
  set -e
  printf 'driver_rc\t%s\nsampler_rc\t%s\n' "$driver_rc" "$sampler_rc" >"$out/runtime-rc.tsv"
  (( driver_rc == 0 )) || die "fio/driver failed: $cell rc=$driver_rc"
  (( sampler_rc == 0 )) || die "mechanism sampler failed: $cell rc=$sampler_rc"
  [[ -s $sampler_out/SAMPLER_PASS ]] || die "sampler PASS missing: $cell"
  health_gate "$cell-post" paused
  foreign_fio_gate "$cell-post"
  verify_second_mount
  printf 'cell_complete\t%s\t%s\n' "$cell" "$(date +%s)" >>"$STATE"
}

osd_perf_values() {
  python3 - "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); found={}
def walk(x):
    if isinstance(x,dict):
        for k,v in x.items():
            if k in ('compact_running','compact_queue_len') and isinstance(v,(int,float)):
                found.setdefault(k,[]).append(v)
            walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(d)
for k in ('compact_running','compact_queue_len'):
    vals=found.get(k,[])
    if len(vals)!=1: raise SystemExit(f'{k}: expected one value, got {vals}')
print(found['compact_running'][0],found['compact_queue_len'][0])
PY
}

pending_total() {
  curl -fsS --connect-timeout 3 --max-time 8 "http://$1:20180/metrics" | awk '
$1 ~ /^tikv_engine_pending_compaction_bytes(\{|$)/ {sum+=$2; found=1}
END {if(!found) exit 1; printf "%.0f\n",sum}'
}

wait_quiet() {
  local label=$1 target=$2 out deadline round=0 consecutive=0
  out=$EXEC_DIR/quiet-$label
  deadline=$((SECONDS+QUIET_TIMEOUT))
  local previous_objects= previous_stored= objects stored bytes osd json vals running queue endpoint pending all_idle target_ok
  mkdir -m 0700 -p "$out/raw"
  printf 'epoch\tround\tosd\tcompact_running\tcompact_queue_len\n' >"$out/osd.tsv"
  printf 'epoch\tround\tendpoint\tpending_compaction_bytes\n' >"$out/tikv.tsv"
  printf 'epoch\tround\tobjects\tstored\tbytes_used\ttarget\tstable_count\n' >"$out/pool.tsv"
  while (( SECONDS < deadline )); do
    round=$((round+1)); all_idle=1
    for osd in "${EXPECTED_OSDS[@]}"; do
      json=$out/raw/osd-$osd-latest.json
      timeout 20 env CEPH_CONF="$CEPH_CONF" ceph tell "osd.$osd" perf dump >"$json" || die "non-sudo OSD perf poll failed: $label osd.$osd"
      vals=$(osd_perf_values "$json") || die "OSD compact counters unavailable: $label osd.$osd"
      read -r running queue <<<"$vals"
      printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$osd" "$running" "$queue" >>"$out/osd.tsv"
      [[ $running == 0 && $queue == 0 ]] || all_idle=0
    done
    for endpoint in 10.20.1.150 10.20.1.151 10.20.1.152; do
      pending=$(pending_total "$endpoint") || die "TiKV pending metric unavailable: $endpoint"
      printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$endpoint" "$pending" >>"$out/tikv.tsv"
      [[ $pending == 0 ]] || all_idle=0
    done
    read -r objects stored bytes < <(pool_stats) || die "pool stats unavailable: $label"
    target_ok=1
    if [[ $target != NONE ]]; then
      [[ $target =~ ^[0-9]+$ ]] || die "invalid object target: $target"
      (( objects >= target - OBJECT_TOLERANCE && objects <= target + OBJECT_TOLERANCE )) || target_ok=0
    fi
    if [[ $objects == "$previous_objects" && $stored == "$previous_stored" && $all_idle == 1 && $target_ok == 1 ]]; then
      consecutive=$((consecutive+1))
    elif (( all_idle == 1 && target_ok == 1 )); then
      consecutive=1
    else
      consecutive=0
    fi
    previous_objects=$objects; previous_stored=$stored
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$objects" "$stored" "$bytes" "$target" "$consecutive" >>"$out/pool.tsv"
    if (( consecutive >= 3 )); then
      printf '%s\t%s\t%s\n' "$objects" "$stored" "$bytes" >"$out/final-pool.tsv"
      printf 'QUIET_PASS\t%s\tobjects=%s\tstored=%s\n' "$label" "$objects" "$stored" >"$out/PASS"
      return 0
    fi
    sleep 10
  done
  die "quiet/object return timeout: $label target=$target"
}

compact_once() {
  local cell=$1 osd before_count rc
  [[ $cell =~ ^(W0[1-3]|M0[1-2])$ ]] || die "compact not permitted for cell: $cell"
  for osd in "${EXPECTED_OSDS[@]}"; do
    before_count=$(awk -F '\t' -v c="$cell" -v o="$osd" '$1=="attempt"&&$3==c&&$4==o{n++} END{print n+0}' "$EXEC_DIR/compact-audit.tsv")
    (( before_count == 0 )) || die "compact retry/duplicate refused: $cell osd.$osd"
    [[ $(ceph_read fsid | tr -d '[:space:]') == "$EXPECTED_FSID" ]] || die 'FSID changed before compact'
    printf 'attempt\t%s\t%s\t%s\n' "$(date +%s)" "$cell" "$osd" >>"$EXEC_DIR/compact-audit.tsv"
    record timeout 60 sudo ceph tell "osd.$osd" compact
    set +e
    timeout 60 sudo ceph tell "osd.$osd" compact >"$EXEC_DIR/compact-$cell-osd-$osd.log" 2>&1
    rc=$?
    set -e
    printf 'result\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$cell" "$osd" "$rc" >>"$EXEC_DIR/compact-audit.tsv"
    (( rc == 0 )) || die "OSD compact command failed or timed out: $cell osd.$osd rc=$rc; do not retry"
  done
}

gc_normalize() {
  local label=$1 out
  [[ $label =~ ^(PRE|SEED|W0[12]|M0[1-3])$ ]] || die "invalid GC normalization label: $label"
  out=$EXEC_DIR/gc-$label-normalize.log
  record env JFS_GC_SKIPPEDTIME=0 "CEPH_CONF=$CEPH_CONF" timeout 1800 \
    "$JFS" gc --compact --delete --threads 32 "$META"
  JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" timeout 1800 \
    "$JFS" gc --compact --delete --threads 32 "$META" >"$out" 2>&1 \
    || die "JuiceFS gc normalization failed/timed out: $label"
}

gc_delete() {
  local out=$EXEC_DIR/gc-W03-delete.log
  record env JFS_GC_SKIPPEDTIME=0 "CEPH_CONF=$CEPH_CONF" timeout 1800 "$JFS" gc --delete --threads 32 "$META"
  JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" timeout 1800 "$JFS" gc --delete --threads 32 "$META" >"$out" 2>&1 || die 'JuiceFS gc --delete failed/timed out: W03'
}

restore_after_write_cell() {
  local cell=$1 target=$2
  case $cell in
    W01|W02|M01|M02|M03) gc_normalize "$cell" ;;
    W03)
      T046_TEST_DIR="$MNT/test_dir" T046_EXECUTE_ACK=I_ACK_04_6_MSEQWRITE_CLEANUP \
        "$DRIVER" cleanup-mseqwrite "$RUN_ID" "$ROOT"
      require_mseqwrite_empty "$MNT"
      gc_delete
      ;;
    *) die "invalid write recovery cell: $cell" ;;
  esac
  # M03 is the terminal measurement.  Its GC normalization and natural quiet
  # gate close the data/object state; omitting a post-measurement forced OSD
  # compact keeps the aggregate repair budget (including the invalid RUN's
  # W01) within the approved maximum of six calls per OSD.
  [[ $cell == M03 ]] || compact_once "$cell"
  wait_quiet "$cell" "$target"
  health_gate "$cell-recovered" paused
  U141D_SCRUB_STATE_DIR="$STATE_DIR" "$SCRUB_CONTROL" verify-paused "$LEASE" >"$ROOT/cells/$cell/scrub-recovered.txt"
}

verify_compact_budget() {
  python3 - "$EXEC_DIR/compact-audit.tsv" <<'PY'
import collections, csv, sys
rows=list(csv.reader(open(sys.argv[1]),delimiter='\t'))
attempt=[r for r in rows if r and r[0]=='attempt']
result=[r for r in rows if r and r[0]=='result']
expected={(c,str(o)) for c in ('W01','W02','W03','M01','M02') for o in range(6)}
seen={(r[2],r[3]) for r in attempt}
if len(attempt)!=30 or seen!=expected: raise SystemExit(f'compact attempts mismatch: {len(attempt)} {seen ^ expected}')
if len(result)!=30 or any(r[4]!='0' for r in result): raise SystemExit('compact result mismatch')
per=collections.Counter(r[3] for r in attempt)
if per != collections.Counter({str(i):5 for i in range(6)}): raise SystemExit(f'per-OSD compact budget mismatch: {per}')
print('COMPACT_BUDGET_PASS repair_attempts=30 repair_per_osd=5 aggregate_with_invalid_run_per_osd=6')
PY
}

write_plans() {
  mkdir -m 0700 -p "$ROOT/plans"
  {
    printf '# 157 only; exact state-changing sudo surface approved for 04-6.\n'
    printf 'sudo ceph osd set noscrub\n'
    printf 'sudo ceph osd set nodeep-scrub\n'
    local cell osd
    for cell in W01 W02 W03 M01 M02; do
      for osd in "${EXPECTED_OSDS[@]}"; do printf 'sudo ceph tell osd.%s compact # %s\n' "$osd" "$cell"; done
    done
    printf 'sudo ceph osd unset nodeep-scrub\n'
    printf 'sudo ceph osd unset noscrub\n'
  } >"$ROOT/plans/sudo-contract.txt"
  {
    printf 'R01 R02 R03\n'
    printf 'PRE: juicefs gc --compact --delete --threads 32; freeze normalized O0; no OSD compact\n'
    printf 'fio seed: mseqwrite.0.0 ... mseqwrite.15.0, each 4GiB; then the same GC normalization and freeze O1; no OSD compact\n'
    printf 'W01/W02: juicefs gc --compact --delete --threads 32\n'
    printf 'W03: exact owned 16-file cleanup; juicefs gc --delete --threads 32\n'
    printf 'M01/M02/M03: juicefs gc --compact --delete --threads 32 after each cell; M03 is terminal and has no forced OSD compact\n'
    printf 'W01/W02/W03/M01/M02: one compact command per exact OSD 0..5; M03 uses natural idle gate; repair plus invalid-W01 aggregate remains six per OSD\n'
  } >"$ROOT/plans/sequence.txt"
}

cmd_inventory_plan() {
  valid_run
  [[ ! -e $ROOT ]] || die "RUN root already exists: $ROOT"
  [[ ! -e $MNT ]] || die "RUN mount path already exists: $MNT"
  require_tools
  T046_TEST_DIR="$MNT/test_dir" T046_EVIDENCE_ROOT="$ROOT" "$DRIVER" plan "$RUN_ID" "$ROOT"
  mkdir -m 0700 -p "$ROOT/inventory" "$EXEC_DIR" "$STATE_DIR"
  printf 'epoch\tphase\tstatus\tdetail\n' >"$PHASES"
  printf 'epoch\ttype\tdetail\n' >"$INCIDENTS"
  printf 'record_type\tepoch\tcell\tosd_or_rc\trc_optional\n' >"$EXEC_DIR/compact-audit.tsv"
  make_private_ceph_conf
  require_private_ceph_conf
  health_gate inventory unpaused
  foreign_fio_gate inventory
  capture_business_fingerprint "$ROOT/inventory/business-pre"
  [[ -r /sys/class/net/$CEPH_NIC/statistics/rx_bytes ]] || die "frozen Ceph NIC missing: $CEPH_NIC"
  for endpoint in 10.3.1.6 10.3.1.7 10.3.1.8; do
    [[ $(ip route get "$endpoint" | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}') == "$CEPH_NIC" ]] || die "Ceph route does not use $CEPH_NIC: $endpoint"
  done
  printf '%s\n' "$CEPH_NIC" >"$ROOT/inventory/ceph-nic.txt"
  asset_manifest "$REFERENCE_MNT" "$ROOT/inventory/assets-protected.tsv"
  require_mseqwrite_empty "$REFERENCE_MNT"
  pool_stats >"$ROOT/inventory/pool-observed.tsv"
  write_plans
  U141D_SCRUB_STATE_DIR="$STATE_DIR" "$SCRUB_CONTROL" plan-pause "$LEASE" >"$ROOT/plans/scrub-plan.txt"
  sha256sum "$SELF_DIR/t04-6-capacity-execute.sh" "$DRIVER" "$SAMPLER" "$ANALYZER" "$SCRUB_CONTROL" >"$ROOT/plan/runtime-scripts.sha256"
  printf 'INVENTORY_PLAN_PASS\t%s\n' "$RUN_ID" >"$ROOT/inventory/PASS"
  phase PHASE_I PASS inventory-and-plans-frozen
  printf 'T046_INVENTORY_PLAN_PASS\troot=%s\n' "$ROOT"
}

cmd_run() {
  valid_run
  require_tools
  [[ ${T046_FULL_RUN_ACK:-} == "I_ACK_04_6_FULL_RUN_$RUN_ID" ]] || die 'exact full-run ACK missing'
  [[ -s $ROOT/inventory/PASS && -s $ROOT/plan/runtime-scripts.sha256 ]] || die 'Phase I inventory/plan PASS missing'
  [[ ! -e $EXEC_DIR/RUN_STARTED && ! -e $ROOT/FINAL_PASS ]] || die 'RUN already started/completed; automatic resume is forbidden'
  require_private_ceph_conf
  verify_scripts
  touch "$EXEC_DIR/RUN_STARTED"
  printf 'run_started\t%s\n' "$(date +%s)" >"$STATE"
  RUN_TRAP_ARMED=1
  trap on_exit EXIT INT TERM HUP
  business_unchanged run-pre
  asset_manifest "$REFERENCE_MNT" "$EXEC_DIR/assets-run-pre.tsv"
  cmp -s "$ROOT/inventory/assets-protected.tsv" "$EXEC_DIR/assets-run-pre.tsv" || die 'protected assets drifted before run'
  require_mseqwrite_empty "$REFERENCE_MNT"
  health_gate run-pre unpaused
  foreign_fio_gate run-pre
  mount_second
  asset_manifest "$MNT" "$EXEC_DIR/assets-second-mount.tsv"
  cmp -s "$ROOT/inventory/assets-protected.tsv" "$EXEC_DIR/assets-second-mount.tsv" || die 'second mount protected assets mismatch'
  require_mseqwrite_empty "$MNT"
  record env "U141D_SCRUB_STATE_DIR=$STATE_DIR" "$SCRUB_CONTROL" pause "$LEASE" "$EXPECTED_FSID" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
  U141D_SCRUB_STATE_DIR="$STATE_DIR" "$SCRUB_CONTROL" pause "$LEASE" "$EXPECTED_FSID" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE \
    >"$EXEC_DIR/scrub-pause.log" 2>&1
  U141D_SCRUB_STATE_DIR="$STATE_DIR" "$SCRUB_CONTROL" verify-paused "$LEASE" >>"$EXEC_DIR/scrub-pause.log" 2>&1
  health_gate paused paused
  phase PHASE_II START matrix

  local cell o0 o1
  gc_normalize PRE
  wait_quiet PRE NONE
  cp -- "$EXEC_DIR/quiet-PRE/final-pool.tsv" "$EXEC_DIR/O0.tsv"
  o0=$(cut -f1 "$EXEC_DIR/O0.tsv")
  [[ $o0 =~ ^[0-9]+$ ]] || die 'invalid normalized O0 object count'
  phase NORMALIZE PASS "compact-delete O0=$o0"

  for cell in R01 R02 R03; do run_cell "$cell"; done
  wait_quiet R-GROUP "$o0"
  phase R_GROUP PASS "O0=$o0"

  record env "T046_TEST_DIR=$MNT/test_dir" T046_EXECUTE_ACK=I_ACK_04_6_MSEQWRITE_SEED "$DRIVER" seed-mseqwrite "$RUN_ID" "$ROOT"
  T046_TEST_DIR="$MNT/test_dir" T046_EXECUTE_ACK=I_ACK_04_6_MSEQWRITE_SEED "$DRIVER" seed-mseqwrite "$RUN_ID" "$ROOT"
  gc_normalize SEED
  wait_quiet SEED NONE
  cp -- "$EXEC_DIR/quiet-SEED/final-pool.tsv" "$EXEC_DIR/O1.tsv"
  o1=$(cut -f1 "$EXEC_DIR/O1.tsv")
  [[ $o1 =~ ^[0-9]+$ ]] || die 'invalid O1 object count'
  phase SEED PASS "normalized-compact-delete-no-OSD-compact O1=$o1"

  for cell in W01 W02 W03; do
    run_cell "$cell"
    if [[ $cell == W03 ]]; then restore_after_write_cell "$cell" "$o0"; else restore_after_write_cell "$cell" "$o1"; fi
  done
  require_mseqwrite_empty "$MNT"
  phase W_GROUP PASS "returned_O0=$o0"

  for cell in M01 M02 M03; do run_cell "$cell"; restore_after_write_cell "$cell" "$o0"; done
  phase M_GROUP PASS "returned_O0=$o0"
  verify_compact_budget >"$EXEC_DIR/compact-budget.txt"

  scrub_restore
  health_gate restored unpaused
  unmount_second
  business_unchanged final
  asset_manifest "$REFERENCE_MNT" "$EXEC_DIR/assets-final.tsv"
  cmp -s "$ROOT/inventory/assets-protected.tsv" "$EXEC_DIR/assets-final.tsv" || die 'protected asset manifest changed'
  require_mseqwrite_empty "$REFERENCE_MNT"
  foreign_fio_gate final
  pool_stats >"$EXEC_DIR/pool-final.tsv"
  local final_objects
  final_objects=$(cut -f1 "$EXEC_DIR/pool-final.tsv")
  (( final_objects >= o0 - OBJECT_TOLERANCE && final_objects <= o0 + OBJECT_TOLERANCE )) || die "final object count outside O0 tolerance: O0=$o0 final=$final_objects"
  phase PHASE_II PASS full-matrix-and-recovery
  printf 'T046_FULL_RUN_PASS\trun_id=%s\tO0=%s\tO1=%s\tfinal=%s\n' "$RUN_ID" "$o0" "$o1" "$final_objects" >"$ROOT/FINAL_PASS"
  RUN_COMPLETED=1
  trap - EXIT INT TERM HUP
  printf 'T046_FULL_RUN_PASS\troot=%s\n' "$ROOT"
}

cmd_inspect() {
  valid_run
  printf 'ROOT=%s\nMNT=%s\n' "$ROOT" "$MNT"
  [[ ! -f $STATE ]] || sed -n '1,200p' "$STATE"
  [[ ! -f $INCIDENTS ]] || sed -n '1,200p' "$INCIDENTS"
  [[ ! -f $(scrub_state_path) ]] || sed -n '1,240p' "$(scrub_state_path)"
  findmnt -rn -M "$MNT" 2>/dev/null || true
  [[ ! -f $EXEC_DIR/mount-state.tsv ]] || sed -n '1,80p' "$EXEC_DIR/mount-state.tsv"
}

self_test() {
  local run=20990101-000000 root=/tmp/production/opencode-04-6-20990101-000000 mnt=/tmp/jfs-t046-20990101-000000
  [[ $root == /tmp/production/opencode-04-6-$run && $mnt == /tmp/jfs-t046-$run ]] || die 'scope fixture failed'
  [[ ${#EXPECTED_OSDS[@]} -eq 6 && ${EXPECTED_OSDS[*]} == '0 1 2 3 4 5' ]] || die 'OSD fixture failed'
  local cells=(W01 W02 W03 M01 M02)
  (( ${#cells[@]} * ${#EXPECTED_OSDS[@]} == 30 )) || die 'repair compact budget fixture failed'
  [[ $LEASE == "$RUN_ID-phase-a" ]] || die 'lease scope failed'
  printf 'T046_EXECUTOR_SELF_TEST_PASS\tmatrix=R3+W3+M3\trepair_compact_attempts=30\trepair_per_osd=5\taggregate_per_osd=6\n'
}

case $MODE in
  inventory-plan) [[ $# -eq 2 ]] || usage; cmd_inventory_plan ;;
  run) [[ $# -eq 2 ]] || usage; cmd_run ;;
  inspect) [[ $# -eq 2 ]] || usage; cmd_inspect ;;
  --self-test) [[ $# -eq 1 ]] || usage; self_test ;;
  *) usage ;;
esac
