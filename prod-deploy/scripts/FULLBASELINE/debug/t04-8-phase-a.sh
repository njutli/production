#!/usr/bin/env bash
# 04-8 target-local executor (Phase A + minimal Phase B).
#
# This file is prepared offline and is not invoked by Gate 0.  It deliberately
# contains no sudo, SSH, force-unmount, kill, format, destroy, or broad delete.
# The operator must copy it to the target and invoke one phase at a time after
# the independent authorization stop.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
JFS=${T048_JFS:-/tmp/juicefs-1.4.1-patched}
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=${T048_META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
CEPH_CONF=${T048_CEPH_CONF:-}
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
REFERENCE_MNT=${T048_REFERENCE_MNT:-/mnt/juicefs}
RUN_ID=${2:-}
REMOTE_ROOT=${T048_REMOTE_ROOT:-}
FIO=${T048_FIO:-fio}
SCRUB_CONTROL="$SCRIPT_DIR/u141d-scrub-control.sh"
ANALYZER="$SCRIPT_DIR/t04-8-analyze.py"
SCRUB_PAUSED=0
HEALTH_MODE=unpaused

die() { printf 'T048_EXEC_FAIL\t%s\n' "$*" >&2; exit 2; }
valid_run() { [[ ${1:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID; }
set_run() {
  local run=$1
  valid_run "$run"
  REMOTE_ROOT=${REMOTE_ROOT:-/tmp/production/opencode-04-8-$run}
  [[ "$REMOTE_ROOT" == "/tmp/production/opencode-04-8-$run" ]] || die unsafe_remote_root
  [[ "$REMOTE_ROOT" != *" "* ]] || die unsafe_remote_root_chars
}
root_file() { printf '%s/%s' "$REMOTE_ROOT" "$1"; }
safe_mnt() {
  local mnt=$1
  [[ "$mnt" == "/tmp/jfs-t048-$RUN_ID-"* ]] || die unsafe_mount_path
  [[ "$mnt" != *" "* && "$mnt" != "/" && ! -L "$mnt" ]] || die unsafe_mount_path
}
record_cmd() { printf '%q ' "$@" >>"$(root_file commands.sh)"; printf '\n' >>"$(root_file commands.sh)"; }
sha_file() { sha256sum "$1" >"$1.sha256"; }

usage() {
  cat >&2 <<'EOF'
usage:
  t04-8-phase-a.sh plan RUN_ID
  t04-8-phase-a.sh scrub-plan RUN_ID
  t04-8-phase-a.sh scrub-pause RUN_ID FSID I_ACK_04_8_SCRUB_<RUN_ID>
  t04-8-phase-a.sh scrub-restore RUN_ID I_ACK_04_8_SCRUB_RESTORE_<RUN_ID>
  t04-8-phase-a.sh scrub-pause-b RUN_ID FSID I_ACK_04_8_PHASE_B_<RUN_ID>
  t04-8-phase-a.sh scrub-restore-b RUN_ID I_ACK_04_8_PHASE_B_RESTORE_<RUN_ID>
  t04-8-phase-a.sh inventory RUN_ID
  t04-8-phase-a.sh phase-a RUN_ID I_ACK_04_8_PHASE_A_<RUN_ID>
  t04-8-phase-a.sh phase-b RUN_ID I_ACK_04_8_PHASE_B_<RUN_ID>
  t04-8-phase-a.sh closure RUN_ID
  t04-8-phase-a.sh cleanup-plan RUN_ID
  t04-8-phase-a.sh cleanup RUN_ID I_ACK_04_8_ASSET_CLEANUP_<RUN_ID>
EOF
  exit 2
}

plan() {
  local run=$1
  set_run "$run"
  mkdir -m 0700 -p "$REMOTE_ROOT/plan" "$REMOTE_ROOT/common" "$REMOTE_ROOT/cells" "$REMOTE_ROOT/closure"
  cat >"$REMOTE_ROOT/plan/phase-a-matrix.tsv" <<'EOF'
cell	position	arm	fuse	formal_endpoint	pair
S01	1	A	256K	S01-seqwrite	P1-baseline
S02	2	B	1M	S02-seqwrite	P1-candidate
S03	3	B	1M	S03-seqwrite	P2-candidate
S04	4	A	256K	S04-seqwrite	P2-baseline
S05	5	B	1M	S05-seqwrite	P3-candidate
S06	6	A	256K	S06-seqwrite	P3-baseline
S07	7	A	256K	S07-seqwrite	P4-baseline
S08	8	B	1M	S08-seqwrite	P4-candidate
EOF
  cat >"$REMOTE_ROOT/plan/sudo-write-plan.tsv" <<'EOF'
operation	node	command	default_phase	ack
none	157/150-152	NO_PRIVILEGED_WRITE_IN_PHASE_A_EXECUTOR	Phase A	NOT_REQUIRED
EOF
  cat >"$REMOTE_ROOT/plan/phase-a-contract.txt" <<EOF
RUN_ID=$run
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
VARIABLE_A=--max-fuse-io 256K
VARIABLE_B=--max-fuse-io 1M
COMMON=--max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0; default readahead
FORMAL_WINDOW=[15,175)
MOUNT_ROOT=/tmp/jfs-t048-$run-SXX
NO_FORMAT=1
NO_DESTROY=1
NO_SUDO=1
EOF
  printf 'PLAN_PASS\t%s\n' "$REMOTE_ROOT" >"$REMOTE_ROOT/plan/PASS"
  sha_file "$REMOTE_ROOT/plan/phase-a-matrix.tsv"
  sha_file "$REMOTE_ROOT/plan/sudo-write-plan.tsv"
  printf 'T048_PLAN_PASS\t%s\n' "$REMOTE_ROOT"
}

scrub_plan() {
  local run=$1
  set_run "$run"
  mkdir -m 0700 -p "$REMOTE_ROOT/plan" "$REMOTE_ROOT/state"
  cat >"$REMOTE_ROOT/plan/scrub-write-plan.tsv" <<'EOF'
operation	node	exact_command	ack
pause	Ceph admin target	sudo ceph osd set noscrub	I_ACK_04_8_SCRUB_<RUN_ID>
pause	Ceph admin target	sudo ceph osd set nodeep-scrub	I_ACK_04_8_SCRUB_<RUN_ID>
restore	Ceph admin target	sudo ceph osd unset nodeep-scrub	I_ACK_04_8_SCRUB_RESTORE_<RUN_ID>
restore	Ceph admin target	sudo ceph osd unset noscrub	I_ACK_04_8_SCRUB_RESTORE_<RUN_ID>
pause-b	Ceph admin target	sudo ceph osd set noscrub	I_ACK_04_8_PHASE_B_<RUN_ID>
pause-b	Ceph admin target	sudo ceph osd set nodeep-scrub	I_ACK_04_8_PHASE_B_<RUN_ID>
restore-b	Ceph admin target	sudo ceph osd unset nodeep-scrub	I_ACK_04_8_PHASE_B_RESTORE_<RUN_ID>
restore-b	Ceph admin target	sudo ceph osd unset noscrub	I_ACK_04_8_PHASE_B_RESTORE_<RUN_ID>
EOF
  sed -i "s/<RUN_ID>/$run/g" "$REMOTE_ROOT/plan/scrub-write-plan.tsv"
  printf 'SCRUB_PLAN_PASS\t%s\n' "$REMOTE_ROOT/plan/scrub-write-plan.tsv"
}

scrub_pause() {
  local run=$1 fsid=$2 ack=$3
  set_run "$run"
  [[ "$ack" == "I_ACK_04_8_SCRUB_$run" ]] || die scrub_pause_ack_missing
  [[ "$fsid" =~ ^[0-9a-f-]{36}$ ]] || die scrub_fsid_invalid
  [[ -x "$SCRUB_CONTROL" && ! -L "$SCRUB_CONTROL" ]] || die scrub_control_missing
  [[ -f "$REMOTE_ROOT/common/inventory/PASS" ]] || die scrub_inventory_required
  CEPH_CONF=${CEPH_CONF:-$REMOTE_ROOT/common/ceph-msgr8.conf}
  [[ -r "$CEPH_CONF" && "$(md5sum "$CEPH_CONF" | awk '{print $1}')" == "$CEPH_CONF_MD5" ]] || die scrub_ceph_conf_identity
  [[ -f "$REMOTE_ROOT/plan/scrub-write-plan.tsv" ]] || die scrub_plan_required
  U141D_SCRUB_STATE_DIR="$REMOTE_ROOT/state" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" pause "$run-phase-a" "$fsid" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$REMOTE_ROOT/state/scrub-pause.log" 2>&1
  U141D_SCRUB_STATE_DIR="$REMOTE_ROOT/state" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" verify-paused "$run-phase-a" >>"$REMOTE_ROOT/state/scrub-pause.log" 2>&1
  printf 'SCRUB_PAUSE_PASS\n' >"$REMOTE_ROOT/state/SCRUB_PAUSED"
}

scrub_pause_lease() {
  local run=$1 phase=$2 fsid=$3 ack=$4 lease state_dir
  lease="${run}-phase-${phase,,}"
  set_run "$run"
  [[ "$ack" == "I_ACK_04_8_PHASE_${phase^^}_$run" ]] || die "scrub_${phase}_pause_ack_missing"
  [[ "$fsid" =~ ^[0-9a-f-]{36}$ ]] || die scrub_fsid_invalid
  [[ -f "$REMOTE_ROOT/common/inventory/PASS" ]] || die scrub_inventory_required
  CEPH_CONF=${CEPH_CONF:-$REMOTE_ROOT/common/ceph-msgr8.conf}
  [[ -r "$CEPH_CONF" && "$(md5sum "$CEPH_CONF" | awk '{print $1}')" == "$CEPH_CONF_MD5" ]] || die scrub_ceph_conf_identity
  [[ -f "$REMOTE_ROOT/plan/scrub-write-plan.tsv" ]] || die scrub_plan_required
  state_dir="$REMOTE_ROOT/state-${phase,,}"
  mkdir -m 0700 -p "$state_dir"
  U141D_SCRUB_STATE_DIR="$state_dir" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" pause "$lease" "$fsid" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$state_dir/scrub-pause.log" 2>&1
  U141D_SCRUB_STATE_DIR="$state_dir" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" verify-paused "$lease" >>"$state_dir/scrub-pause.log" 2>&1
  printf 'SCRUB_PAUSED_%s\n' "$phase" >"$state_dir/SCRUB_PAUSED_${phase}"
}

scrub_restore() {
  local run=$1 ack=${2:-}
  set_run "$run"
  [[ -f "$REMOTE_ROOT/state/SCRUB_PAUSED" ]] || return 0
  [[ "$ack" == "I_ACK_04_8_SCRUB_RESTORE_$run" || ${T048_INTERNAL_RESTORE:-0} == 1 ]] || die scrub_restore_ack_missing
  CEPH_CONF=${CEPH_CONF:-$REMOTE_ROOT/common/ceph-msgr8.conf}
  [[ -r "$CEPH_CONF" && "$(md5sum "$CEPH_CONF" | awk '{print $1}')" == "$CEPH_CONF_MD5" ]] || die scrub_restore_ceph_conf_identity
  U141D_SCRUB_STATE_DIR="$REMOTE_ROOT/state" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" restore "$run-phase-a" >"$REMOTE_ROOT/state/scrub-restore.log" 2>&1
  U141D_SCRUB_STATE_DIR="$REMOTE_ROOT/state" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" verify-restored "$run-phase-a" >>"$REMOTE_ROOT/state/scrub-restore.log" 2>&1
  printf 'SCRUB_RESTORED\n' >"$REMOTE_ROOT/state/SCRUB_RESTORED"
  rm -f -- "$REMOTE_ROOT/state/SCRUB_PAUSED"
}

scrub_restore_lease() {
  local run=$1 phase=$2 ack=${3:-} lease state_dir
  lease="${run}-phase-${phase,,}"
  set_run "$run"
  state_dir="$REMOTE_ROOT/state-${phase,,}"
  [[ -f "$state_dir/SCRUB_PAUSED_${phase}" ]] || return 0
  [[ "$ack" == "I_ACK_04_8_PHASE_${phase^^}_RESTORE_$run" || ${T048_INTERNAL_RESTORE:-0} == 1 ]] || die "scrub_${phase}_restore_ack_missing"
  CEPH_CONF=${CEPH_CONF:-$REMOTE_ROOT/common/ceph-msgr8.conf}
  [[ -r "$CEPH_CONF" && "$(md5sum "$CEPH_CONF" | awk '{print $1}')" == "$CEPH_CONF_MD5" ]] || die scrub_restore_ceph_conf_identity
  U141D_SCRUB_STATE_DIR="$state_dir" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" restore "$lease" >"$state_dir/scrub-restore.log" 2>&1
  U141D_SCRUB_STATE_DIR="$state_dir" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" verify-restored "$lease" >>"$state_dir/scrub-restore.log" 2>&1
  printf 'SCRUB_RESTORED_%s\n' "$phase" >"$state_dir/SCRUB_RESTORED_${phase}"
  rm -f -- "$state_dir/SCRUB_PAUSED_${phase}"
}

scrub_pause_b() { scrub_pause_lease "$1" B "$2" "$3"; }
scrub_restore_b() { scrub_restore_lease "$1" B "$2"; }

inventory() {
  local run=$1 out
  set_run "$run"
  [[ -f "$REMOTE_ROOT/plan/PASS" ]] || die plan_required
  out="$REMOTE_ROOT/common/inventory"
  mkdir -m 0700 -p "$out"
  [[ -x "$JFS" && ! -L "$JFS" ]] || die juicefs_binary_missing
  [[ "$(md5sum "$JFS" | awk '{print $1}')" == "$JFS_MD5" ]] || die juicefs_binary_md5
  [[ -x "$(command -v "$FIO" || true)" ]] || die fio_missing
  if [[ -z "$CEPH_CONF" ]]; then
    CEPH_CONF="$REMOTE_ROOT/common/ceph-msgr8.conf"
    if [[ ! -e "$CEPH_CONF" ]]; then
      [[ -f /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_source_missing
      cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
      printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
    fi
  fi
  [[ -r "$CEPH_CONF" && ! -L "$CEPH_CONF" ]] || die ceph_conf_missing
  [[ "$(md5sum "$CEPH_CONF" | awk '{print $1}')" == "$CEPH_CONF_MD5" ]] || die ceph_conf_md5
  mountpoint -q "$REFERENCE_MNT" || die reference_mount_missing
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REFERENCE_MNT fuse.juicefs" "$out/reference-mount.tsv" || die reference_identity
  python3 - "$JFS" "$REFERENCE_MNT" "$out/reference-process.tsv" <<'PY'
import hashlib, os, pathlib, sys
exe=os.path.realpath(sys.argv[1]); mount=sys.argv[2]; rows=[]
for path in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(path/'exe') != exe: continue
        cmd=(path/'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
        if mount not in cmd: continue
        stat=(path/'stat').read_text().split()
        rows.append((int(path.name), int(stat[3]), stat[21], hashlib.md5(open(path/'exe','rb').read()).hexdigest(), cmd))
    except (OSError, ValueError, IndexError):
        continue
if not rows: raise SystemExit('reference process identity missing')
with open(sys.argv[3], 'w') as stream:
    stream.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for row in sorted(rows): stream.write('\t'.join(map(str, row))+'\n')
PY
  env CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$out/juicefs-status.json"
  env CEPH_CONF="$CEPH_CONF" ceph fsid >"$out/ceph-fsid.txt"
  env CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$out/ceph-status.json"
  env CEPH_CONF="$CEPH_CONF" ceph osd stat --format json >"$out/osd-stat.json"
  python3 - "$out/juicefs-status.json" "$out/ceph-status.json" "$out/osd-stat.json" <<'PY'
import json, sys
volume=json.load(open(sys.argv[1])); setting=volume.get("Setting", volume)
if setting.get("Name") != "juicefs-prod" or not setting.get("UUID"):
    raise SystemExit("JuiceFS volume identity mismatch")
health=json.load(open(sys.argv[2]))
if health.get("health", {}).get("status") != "HEALTH_OK":
    raise SystemExit("Ceph is not HEALTH_OK")
osd=json.load(open(sys.argv[3]))
if any(int(osd.get(k, -1)) != 6 for k in ("num_osds", "num_up_osds", "num_in_osds")):
    raise SystemExit("six-OSD identity/health gate failed")
PY
  pgrep -x fio >"$out/foreign-fio.tsv" 2>/dev/null && die foreign_fio_present || :
  find "$REFERENCE_MNT/test_dir" -maxdepth 2 -type f -printf '%p\t%i\t%s\t%T@\n' | sort >"$out/protected-assets.tsv"
  [[ -s "$out/protected-assets.tsv" ]] || die protected_assets_missing
  if [[ -e "$REFERENCE_MNT/test_dir/04-8-$run" ]]; then
    fuser -v "$REFERENCE_MNT/test_dir/04-8-$run" >"$out/task-path-foreign-opener.tsv" 2>&1 || :
    die stale_task_path_exists
  fi
  printf 'PATH_ABSENT_NO_FOREIGN_OPENER\n' >"$out/task-path-foreign-opener.tsv"
  pool_snapshot "$REMOTE_ROOT/common/inventory/pool-before.tsv"
  tikv_pending_snapshot "$REMOTE_ROOT/common/inventory/tikv-pending"
  printf 'JFS_MD5\t%s\nCEPH_CONF_MD5\t%s\nREFERENCE_MNT\t%s\nMETA\t%s\n' "$JFS_MD5" "$CEPH_CONF_MD5" "$REFERENCE_MNT" "$META" >"$out/inventory.tsv"
  printf 'INVENTORY_PASS\n' >"$out/PASS"
  (cd "$out" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) >"$out/SHA256SUMS"
  printf 'T048_INVENTORY_PASS\t%s\n' "$out"
}

record_mount_identity() {
  local mnt=$1 out=$2 log=$3
  safe_mnt "$mnt"
  python3 - "$JFS" "$mnt" "$log" "$out/mount-process.tsv" <<'PY'
import hashlib, os, pathlib, sys
exe=os.path.realpath(sys.argv[1]); mount=sys.argv[2]; log=sys.argv[3]; rows=[]
for path in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(path/'exe') != exe: continue
        raw=(path/'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
        if mount not in raw and log not in raw: continue
        stat=(path/'stat').read_text().split()
        digest=hashlib.md5(open(path/'exe','rb').read()).hexdigest()
        rows.append((int(path.name), int(stat[3]), stat[21], digest, raw))
    except (OSError, ValueError, IndexError):
        continue
if not rows: raise SystemExit('mount process identity missing')
from pathlib import Path
output = Path(sys.argv[4])
with output.open('w') as stream:
    stream.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for row in sorted(rows): stream.write('\t'.join(map(str,row))+'\n')
pids={row[0] for row in rows}; workers=[row for row in rows if row[1] in pids]
if len(workers) != 1: raise SystemExit('unique child worker not found')
worker=workers[0]
with output.with_name('mount-state.tsv').open('w') as stream:
    stream.write('worker_pid\t%d\nworker_starttime\t%s\nworker_exe_md5\t%s\n' %
                 (worker[0], worker[2], worker[3]))
PY
}

health_before() {
  local out=$1 mode=${2:-$HEALTH_MODE}
  mkdir -m 0700 -p "$out"
  env CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$out/ceph-status.json" || die ceph_status
  env CEPH_CONF="$CEPH_CONF" ceph osd stat --format json >"$out/osd-stat.json" || die osd_status
  python3 - "$out/ceph-status.json" "$out/osd-stat.json" "$mode" <<'PY'
import json, sys
health=json.load(open(sys.argv[1]))
mode=sys.argv[3]
status=health.get("health", {}).get("status")
checks=set((health.get("health", {}).get("checks") or {}).keys())
if not ((mode == "paused" and status == "HEALTH_WARN" and checks == {"OSDMAP_FLAGS"}) or
        (mode == "unpaused" and status == "HEALTH_OK" and not checks)):
    raise SystemExit("Ceph is not HEALTH_OK before fio")
pg=health.get("pgmap", {}).get("pgs_by_state", [])
if not pg or any(x.get("state_name") != "active+clean" for x in pg):
    raise SystemExit("PGs are not active+clean before fio")
osd=json.load(open(sys.argv[2]))
if any(int(osd.get(k, -1)) != 6 for k in ("num_osds", "num_up_osds", "num_in_osds")):
    raise SystemExit("six-OSD gate failed before fio")
PY
}

mount_cell() {
  local run=$1 cell=$2 fuse=$3 root="$REMOTE_ROOT/cells/$2" mnt="/tmp/jfs-t048-$RUN_ID-$2" port
  if [[ "$cell" == CLEANUP ]]; then
    port=9968
  elif [[ "$cell" == PREP ]]; then
    port=9768
  elif [[ "$cell" =~ ^S[0-9]+$ ]]; then
    port=$((9568 + 10#${cell#S}))
  elif [[ "$cell" =~ ^C[0-9]+$ ]]; then
    port=$((9668 + 10#${cell#C}))
  else
    die invalid_mount_cell_$cell
  fi
  safe_mnt "$mnt"
  [[ ! -e "$mnt" && ! -L "$mnt" ]] || die mount_path_exists_$cell
  mkdir -m 0700 -p "$root" "$REMOTE_ROOT/mounts/$cell" "$mnt"
  if ss -ltnH 2>/dev/null | awk -v p=":$port" '$4 ~ p"$"{found=1} END{exit found?0:1}'; then die metrics_port_in_use_$cell; fi
  local log="$REMOTE_ROOT/mounts/$cell/juicefs-mount.log"
  local -a cmd=(env "CEPH_CONF=$CEPH_CONF" "$JFS" mount -d --max-downloads 200 --max-uploads 150
    --buffer-size 300 --cache-size 0 --max-fuse-io "$fuse" --metrics "127.0.0.1:$port" --log "$log" "$META" "$mnt")
  printf '%q ' "${cmd[@]}" >>"$REMOTE_ROOT/commands.sh"; printf '\n' >>"$REMOTE_ROOT/commands.sh"
  "${cmd[@]}" >"$root/mount.stdout" 2>"$root/mount.stderr"
  for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout_$cell
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$root/findmnt.tsv"
  grep -Fq "JuiceFS:juicefs-prod $mnt fuse.juicefs" "$root/findmnt.tsv" || die mount_identity_$cell
  record_mount_identity "$mnt" "$root" "$log"
  curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/metrics" >"$root/metrics.prom" || die metrics_missing_$cell
  printf '%s\n' "$port" >"$root/metrics-port.txt"
  printf '%s\n' "$mnt" >"$root/mountpoint.txt"
}

verify_asset_set() {
  local dir=$1 prefix=$2 count=$3 size=$4
  python3 - "$dir" "$prefix" "$count" "$size" <<'PY'
import os, pathlib, sys
root=pathlib.Path(sys.argv[1]); prefix=sys.argv[2]; count=int(sys.argv[3]); size=int(sys.argv[4])
expected={f"{prefix}.{i}.0" for i in range(count)}
actual={p.name for p in root.glob(f"{prefix}.*.0")}
if actual != expected:
    raise SystemExit(f"asset names mismatch for {root}/{prefix}: missing={sorted(expected-actual)[:3]} extra={sorted(actual-expected)[:3]}")
for name in sorted(expected):
    path=root/name
    if path.is_symlink() or not path.is_file() or path.stat().st_size != size:
        raise SystemExit(f"asset contract mismatch: {path}")
PY
}

prepare_phase_b_assets() {
  local mnt=$1 dir="$1/test_dir/04-8-$RUN_ID/mseqwrite" out="$REMOTE_ROOT/phase-b-seed" rc
  mkdir -m 0700 -p "$dir" "$out"
  if ! verify_asset_set "$dir" mseqwrite 16 4294967296 2>/dev/null; then
    [[ -z $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || die phase_b_seed_partial_assets
    health_before "$out/health-pre" paused
    local -a cmd=(timeout 1800 "$FIO" --name=mseqwrite --directory="$dir" --filename_format='mseqwrite.$jobnum.0'
      --rw=write --bs=4M --size=4G --numjobs=16 --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1)
    record_cmd "${cmd[@]}"
    set +e; "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; set -e
    printf '%s\n' "$rc" >"$out/fio.rc"
    ((rc == 0)) || die phase_b_seed_fio_failed
    health_before "$out/health-post" paused
  fi
  verify_asset_set "$mnt/test_dir/seqread" seqread 1 34359738368
  verify_asset_set "$mnt/test_dir/mseqread" mseqread 16 4294967296
  verify_asset_set "$mnt/test_dir" read_test 128 1073741824
  verify_asset_set "$mnt/test_dir" storage_test 128 1073741824
  verify_asset_set "$mnt/test_dir" rw_test 128 1073741824
  verify_asset_set "$dir" mseqwrite 16 4294967296
  find "$dir" -maxdepth 1 -type f -name 'mseqwrite.*.0' -printf '%f\t%i\t%s\t%T@\n' | sort -V >"$out/mseqwrite-manifest.tsv"
  sha_file "$out/mseqwrite-manifest.tsv"
  printf 'PHASE_B_ASSET_PASS\n' >"$out/PASS"
}

metrics_snapshot() {
  local out=$1 mnt=$2 port=$3
  mkdir -m 0700 -p "$out"
  cat "$mnt/.stats" >"$out/juicefs.stats" || die metrics_snapshot_failed
  curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/metrics" >"$out/metrics.prom" || die raw_metrics_snapshot_failed
  printf '%s\n' "$port" >"$out/metrics-port.txt"
  grep -Eq '^juicefs_(fuse|object_request)_' "$out/juicefs.stats" || die metrics_contract_missing
}

osd_snapshot() {
  local out=$1 osd
  mkdir -m 0700 -p "$out/ceph-osd"
  for osd in 0 1 2 3 4 5; do
    env CEPH_CONF="$CEPH_CONF" timeout 20 ceph tell "osd.$osd" perf dump >"$out/ceph-osd/osd-$osd.json" || die osd_perf_missing
  done
}

pool_snapshot() {
  local out=$1
  env CEPH_CONF="$CEPH_CONF" ceph df detail --format json >"$out.ceph-df.json" || die pool_stats_missing
  python3 - "$out.ceph-df.json" "$out" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
pool=next((item for item in data.get("pools", []) if item.get("name") == "juicefs-data"), None)
if pool is None:
    raise SystemExit("juicefs-data pool missing")
stats=pool.get("stats", {})
objects=stats.get("objects")
bytes_used=stats.get("bytes_used", stats.get("stored"))
if not isinstance(objects, (int, float)) or not isinstance(bytes_used, (int, float)):
    raise SystemExit("pool object counters missing")
open(sys.argv[2], "w").write("pool\tobjects\tbytes_used\njuicefs-data\t%d\t%d\n" % (objects, bytes_used))
PY
}

tikv_pending_snapshot() {
  local out=$1 host
  mkdir -m 0700 -p "$out"
  for host in 10.20.1.150 10.20.1.151 10.20.1.152; do
    curl -fsS --connect-timeout 3 --max-time 8 "http://$host:20180/metrics" >"$out/$host.prom" || die tikv_metrics_missing
    grep -Eq '^tikv_engine_pending_compaction_bytes(\{|[[:space:]])' "$out/$host.prom" || die tikv_pending_metric_missing_$host
  done
  awk '$1 ~ /^tikv_engine_pending_compaction_bytes(\{|$)/ {sum += $2} END {printf "%.0f\n", sum+0}' "$out"/*.prom >"$out/total-pending-bytes.txt"
}

recovery_gate() {
  local label=$1 target=$2
  local out="$REMOTE_ROOT/recovery/$label" baseline pending objects consecutive=0 round=0
  mkdir -m 0700 -p "$out"
  baseline=$(<"$REMOTE_ROOT/common/inventory/tikv-pending/total-pending-bytes.txt")
  [[ "$baseline" =~ ^[0-9]+$ && "$target" =~ ^[0-9]+$ ]] || die recovery_anchor_invalid
  printf 'round\tobjects\tpending_bytes\tpg_recovery_gate\twithin_anchor\tpass\n' >"$out/gate.tsv"
  local deadline=$((SECONDS+900))
  while ((SECONDS < deadline)); do
    round=$((round+1)); local health="$out/health-$round" snap="$out/pool-$round" pend="$out/tikv-$round"
    health_before "$health"
    pool_snapshot "$snap"
    tikv_pending_snapshot "$pend"
    objects=$(awk -F '\t' 'NR==2{print $2}' "$snap")
    pending=$(<"$pend/total-pending-bytes.txt")
    local recovery_idle=1 within=0 pass=0
    python3 - "$health/ceph-status.json" "$objects" "$target" "$pending" "$baseline" <<'PY' || recovery_idle=0
import json, sys
health=json.load(open(sys.argv[1])); pg=health.get("pgmap", {}).get("pgs_by_state", [])
if not pg or any("active+clean" != x.get("state_name") for x in pg): raise SystemExit(1)
status=health.get("pgmap", {})
for key in ("recovering_bytes_per_sec", "recovering_objects_per_sec", "recovering_keys_per_sec"):
    if float(status.get(key, 0) or 0) != 0: raise SystemExit(1)
objects, target, pending, baseline = map(int, sys.argv[2:])
if not target - 8192 <= objects <= target + 8192: raise SystemExit(1)
if pending > max(baseline * 1.25, 64 * 1024 * 1024): raise SystemExit(1)
PY
    [[ "$objects" =~ ^[0-9]+$ && "$target" =~ ^[0-9]+$ && "$objects" -ge $((target-8192)) && "$objects" -le $((target+8192)) ]] && within=1
    if ((recovery_idle == 1 && within == 1)); then consecutive=$((consecutive+1)); else consecutive=0; fi
    ((consecutive >= 3)) && pass=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$round" "$objects" "$pending" "$recovery_idle" "$within" "$pass" >>"$out/gate.tsv"
    if ((pass == 1)); then printf 'RECOVERY_PASS\ttarget=%s\tobjects=%s\tpending=%s\n' "$target" "$objects" "$pending" >"$out/PASS"; return 0; fi
    sleep 10
  done
  die recovery_timeout_$label
}

gc_after_write() {
  local cell=$1 out="$REMOTE_ROOT/recovery/$cell/gc"
  mkdir -m 0700 -p "$out"
  local -a cmd=(env "CEPH_CONF=$CEPH_CONF" JFS_GC_SKIPPEDTIME=0 timeout 1800
    "$JFS" gc --compact --delete --threads 32 "$META")
  printf '%q ' "${cmd[@]}" >>"$REMOTE_ROOT/commands.sh"; printf '\n' >>"$REMOTE_ROOT/commands.sh"
  set +e; "${cmd[@]}" >"$out/stdout.log" 2>"$out/stderr.log"; local rc=$?; set -e
  printf '%s\n' "$rc" >"$out/rc"
  ((rc == 0)) || die gc_after_write_failed_$cell
  printf 'GC_AFTER_WRITE_PASS\t%s\n' "$cell" >"$out/PASS"
}

fio_detector() {
  local cell=$1 mnt=$2 out="$REMOTE_ROOT/cells/$cell-detector"; mkdir -m 0700 -p "$out/bwlog"
  health_before "$out/health-pre"
  local port; port=$(<"$REMOTE_ROOT/cells/$cell/metrics-port.txt")
  metrics_snapshot "$out/pre-mechanism" "$mnt" "$port"
  for i in $(seq 0 15); do
    [[ -f "$mnt/test_dir/mseqread/mseqread.$i.0" && ! -L "$mnt/test_dir/mseqread/mseqread.$i.0" ]] || die detector_asset_$i
  done
  local -a cmd=(timeout 300 "$FIO" --name="$cell-detector" --directory="$mnt/test_dir/mseqread"
    --filename_format='mseqread.$jobnum.0' --rw=read --bs=256k --size=4G --numjobs=16
    --ioengine=psync --iodepth=1 --direct=1 --time_based --runtime=180 --group_reporting
    --per_job_logs=1 --output-format=json --output="$out/fio.json"
    --write_bw_log="$out/bwlog/detector" --log_avg_msec=1000)
  printf '%q ' "${cmd[@]}" >>"$REMOTE_ROOT/commands.sh"; printf '\n' >>"$REMOTE_ROOT/commands.sh"
  set +e; "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; local rc=$?; set -e
  printf '%s\n' "$rc" >"$out/fio.rc"; date +%s%N >"$out/fio-end-ns.txt"; ((rc == 0)) || die detector_fio_failed_$cell
  metrics_snapshot "$out/post-mechanism" "$mnt" "$port"
  python3 "$SCRIPT_DIR/t04-8-analyze.py" metrics "$out/pre-mechanism/juicefs.stats" "$out/post-mechanism/juicefs.stats" "$out/metrics-delta.json" --mode detector || die detector_metrics_gate_$cell
  health_before "$out/health-post"
}

fio_seqwrite() {
  local cell=$1 mnt=$2 out="$REMOTE_ROOT/cells/$cell-seqwrite" file="$mnt/test_dir/04-8-$RUN_ID/seqwrite/seqwrite.0.0"
  [[ -f "$file" && ! -L "$file" && $(stat -c %s "$file") == 34359738368 ]] || die seqwrite_asset_contract_$cell
  mkdir -m 0700 -p "$out/bwlog"
  fuser -v "$file" >"$out/foreign-opener.tsv" 2>&1 || :
  if fuser -s "$file"; then die task_write_foreign_opener_$cell; fi
  health_before "$out/health-pre"
  local port; port=$(<"$REMOTE_ROOT/cells/$cell/metrics-port.txt")
  metrics_snapshot "$out/pre-mechanism" "$mnt" "$port"
  osd_snapshot "$out/pre-mechanism"
  local -a cmd=(timeout 300 "$FIO" --name="$cell-seqwrite" --filename="$file" --rw=write --bs=4M --size=32G
    --numjobs=1 --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=0
    --time_based --runtime=180 --group_reporting --per_job_logs=1 --output-format=json --output="$out/fio.json"
    --write_bw_log="$out/bwlog/seqwrite" --log_avg_msec=1000)
  printf '%q ' "${cmd[@]}" >>"$REMOTE_ROOT/commands.sh"; printf '\n' >>"$REMOTE_ROOT/commands.sh"
  set +e; "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; local rc=$?; set -e
  printf '%s\n' "$rc" >"$out/fio.rc"; date +%s%N >"$out/fio-end-ns.txt"; ((rc == 0)) || die seqwrite_fio_failed_$cell
  metrics_snapshot "$out/post-mechanism" "$mnt" "$port"
  osd_snapshot "$out/post-mechanism"
  python3 "$SCRIPT_DIR/t04-8-analyze.py" metrics "$out/pre-mechanism/juicefs.stats" "$out/post-mechanism/juicefs.stats" "$out/metrics-delta.json" --mode seqwrite || die seqwrite_metrics_missing_$cell
  health_before "$out/health-post"
  [[ $(stat -c %s "$file") == 34359738368 ]] || die seqwrite_size_drift_$cell
  printf 'ENDPOINT_PASS\t%s\n' "$cell-seqwrite" >"$out/PASS"
}

phase_b_workload() {
  local cell=$1 workload=$2 mnt=$3 out="$REMOTE_ROOT/cells/$cell-$workload"
  local port dir name rw bs size jobs engine depth rc
  local -a extra cmd
  mkdir -m 0700 -p "$out/bwlog"
  port=$(<"$REMOTE_ROOT/cells/$cell/metrics-port.txt")
  health_before "$out/health-pre" paused
  case "$workload" in
    seqread) dir="$mnt/test_dir/seqread"; name=seqread; rw=read; bs=256k; size=32G; jobs=1; engine=psync; depth=1; extra=(--readonly --refill_buffers) ;;
    mseqread) dir="$mnt/test_dir/mseqread"; name=mseqread; rw=read; bs=256k; size=4G; jobs=16; engine=psync; depth=1; extra=(--readonly --refill_buffers) ;;
    mseqwrite) dir="$mnt/test_dir/04-8-$RUN_ID/mseqwrite"; name=mseqwrite; rw=write; bs=4M; size=4G; jobs=16; engine=psync; depth=1; extra=(--refill_buffers --end_fsync=1) ;;
    randread) dir="$mnt/test_dir"; name=read_test; rw=randread; bs=256k; size=1G; jobs=128; engine=libaio; depth=128; extra=(--readonly --filesize=1G --fallocate=none --openfiles=128 --randrepeat=1 --randseed=20260907) ;;
    randwrite) dir="$mnt/test_dir"; name=storage_test; rw=randwrite; bs=256k; size=1G; jobs=128; engine=libaio; depth=128; extra=(--filesize=1G --fallocate=none --openfiles=128 --randrepeat=1 --randseed=20260907) ;;
    randrw) dir="$mnt/test_dir"; name=rw_test; rw=randrw; bs=256k; size=1G; jobs=128; engine=libaio; depth=128; extra=(--filesize=1G --fallocate=none --openfiles=128 --rwmixread=50 --randrepeat=1 --randseed=20260907) ;;
    *) die "phase_b_unknown_workload_$workload" ;;
  esac
  [[ -d "$dir" && ! -L "$dir" ]] || die "phase_b_asset_directory_$workload"
  if [[ "$workload" == mseqread ]]; then
    metrics_snapshot "$out/pre-mechanism" "$mnt" "$port"
  fi
  cmd=(timeout 300 "$FIO" --name="$name" --directory="$dir" --filename_format="$name.\$jobnum.0"
    --rw="$rw" --bs="$bs" --size="$size" --numjobs="$jobs" --ioengine="$engine" --iodepth="$depth"
    --direct=1 --allow_file_create=0 --time_based --runtime=180 --group_reporting --per_job_logs=1
    --output-format=json --output="$out/fio.json" --write_bw_log="$out/bwlog/$name" --log_avg_msec=1000)
  cmd+=("${extra[@]}")
  printf '%q ' "${cmd[@]}" >>"$REMOTE_ROOT/commands.sh"; printf '\n' >>"$REMOTE_ROOT/commands.sh"
  set +e
  "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$out/fio.rc"
  date +%s%N >"$out/fio-end-ns.txt"
  ((rc == 0)) || die "phase_b_fio_failed_${cell}_${workload}"
  if [[ "$workload" == mseqread ]]; then
    metrics_snapshot "$out/post-mechanism" "$mnt" "$port"
    python3 "$ANALYZER" metrics "$out/pre-mechanism/juicefs.stats" "$out/post-mechanism/juicefs.stats" "$out/metrics-delta.json" --mode detector || die "phase_b_detector_failed_$cell"
  fi
  health_before "$out/health-post" paused
  printf 'ENDPOINT_PASS\t%s\n' "$cell-$workload" >"$out/PASS"
}

phase_b() {
  local run=$1 ack=$2
  set_run "$run"
  [[ "$ack" == "I_ACK_04_8_PHASE_B_$run" ]] || die phase_b_ack_missing
  [[ -f "$REMOTE_ROOT/PHASE_A_PASS" ]] || die phase_a_required
  [[ -f "$REMOTE_ROOT/plan/PASS" && -f "$REMOTE_ROOT/common/inventory/PASS" ]] || die inventory_required
  [[ -f "$REMOTE_ROOT/seed/pool-O1.tsv" ]] || die phase_a_object_anchor_missing
  [[ ! -e "$REMOTE_ROOT/PHASE_B_STARTED" ]] || die automatic_resume_refused
  CEPH_CONF=${CEPH_CONF:-$REMOTE_ROOT/common/ceph-msgr8.conf}
  [[ -r "$CEPH_CONF" && "$(md5sum "$CEPH_CONF" | awk '{print $1}')" == "$CEPH_CONF_MD5" ]] || die phase_b_ceph_conf_identity
  [[ -x "$JFS" && "$(md5sum "$JFS" | awk '{print $1}')" == "$JFS_MD5" ]] || die runtime_binary_identity
  [[ -f "$REMOTE_ROOT/state-b/SCRUB_PAUSED_B" ]] || die phase_b_scrub_pause_required
  phase_b_exit() {
    local rc=$?
    if ((rc != 0)); then
      printf '%s\tPHASE_B_EXIT\tUNKNOWN\trc=%s;现场保留\n' "$(date +%s)" "$rc" >>"$REMOTE_ROOT/incidents.tsv"
    fi
    if [[ -f "$REMOTE_ROOT/state-b/SCRUB_PAUSED_B" ]]; then
      T048_INTERNAL_RESTORE=1 scrub_restore_lease "$run" B || rc=70
    fi
    trap - EXIT
    exit "$rc"
  }
  trap phase_b_exit EXIT
  mkdir -m 0700 -p "$REMOTE_ROOT/mounts" "$REMOTE_ROOT/cells" "$REMOTE_ROOT/state-b" "$REMOTE_ROOT/derived"
  printf '%s\n' "$run" >"$REMOTE_ROOT/PHASE_B_STARTED"
  printf 'cell\tarm\tposition\tworkload\tfuse\tformal_window\n' >"$REMOTE_ROOT/plan/phase-b-matrix.tsv"
  local cell arm fuse mnt workload O1
  O1=$(awk -F '\t' 'NR==2{print $2}' "$REMOTE_ROOT/seed/pool-O1.tsv")
  [[ "$O1" =~ ^[0-9]+$ ]] || die phase_a_object_anchor_invalid
  local -a cells=(C01 C02 C03 C04)
  local -a workloads=(mseqread seqread randread mseqwrite randwrite randrw)
  HEALTH_MODE=paused
  mount_cell "$run" PREP 256K
  prepare_phase_b_assets "/tmp/jfs-t048-$run-PREP"
  graceful_umount PREP
  sleep 65
  pool_snapshot "$REMOTE_ROOT/phase-b-seed/pool-O1B.tsv"
  O1=$(awk -F '\t' 'NR==2{print $2}' "$REMOTE_ROOT/phase-b-seed/pool-O1B.tsv")
  recovery_gate phase-b-seed "$O1"
  for cell in "${cells[@]}"; do
    if [[ "$cell" == C01 || "$cell" == C04 ]]; then arm=A; fuse=256K; else arm=B; fuse=1M; fi
    for workload in "${workloads[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\t[15,175)\n' "$cell" "$arm" "${cell#C}" "$workload" "$fuse" >>"$REMOTE_ROOT/plan/phase-b-matrix.tsv"
    done
    mount_cell "$run" "$cell" "$fuse"
    mnt="/tmp/jfs-t048-$run-$cell"
    for workload in "${workloads[@]}"; do
      phase_b_workload "$cell" "$workload" "$mnt"
      case "$workload" in
        mseqwrite|randwrite|randrw)
          gc_after_write "$cell-$workload"
          recovery_gate "$cell-$workload" "$O1"
          ;;
      esac
    done
    graceful_umount "$cell"
  done
  python3 "$ANALYZER" phase-b "$REMOTE_ROOT" "$REMOTE_ROOT/derived/phase-b.json" || die phase_b_analysis_failed
  scrub_restore_lease "$run" B "I_ACK_04_8_PHASE_B_RESTORE_$run"
  printf 'PHASE_B_PASS\n' >"$REMOTE_ROOT/PHASE_B_PASS"
  sha256sum "$REMOTE_ROOT/commands.sh" >"$REMOTE_ROOT/commands.sha256"
  trap - EXIT
  printf 'T048_PHASE_B_PASS\t%s\n' "$REMOTE_ROOT"
}

graceful_umount() {
  local cell=$1 mnt="/tmp/jfs-t048-$RUN_ID-$1" out="$REMOTE_ROOT/cells/$1"
  safe_mnt "$mnt"
  if mountpoint -q "$mnt"; then
    printf '%q ' "$JFS" umount "$mnt" >>"$REMOTE_ROOT/commands.sh"; printf '\n' >>"$REMOTE_ROOT/commands.sh"
    "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr" || die umount_failed_$cell
    for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
    mountpoint -q "$mnt" && die mount_remains_$cell
  fi
  if [[ -d "$mnt" ]]; then
    [[ -z $(find "$mnt" -mindepth 1 -maxdepth 1 -print -quit) ]] || die mount_dir_not_empty_$cell
    rmdir -- "$mnt" || die mount_dir_remove_failed_$cell
  fi
  [[ ! -e "$mnt" ]] || die mount_path_remains_$cell
}

prepare_seed() {
  local mnt=$1 dir="$mnt/test_dir/04-8-$RUN_ID/seqwrite" file="$mnt/test_dir/04-8-$RUN_ID/seqwrite/seqwrite.0.0"
  mkdir -m 0700 -p "$dir"
  if [[ -e "$file" ]]; then
    [[ ! -L "$file" && $(stat -c %s "$file") == 34359738368 ]] || die existing_seed_contract
  else
    health_before "$REMOTE_ROOT/seed/health-pre"
    local -a cmd=(timeout 1800 "$FIO" --name=04-8-seed --filename="$file" --rw=write --bs=4M --size=32G
      --numjobs=1 --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1)
    printf '%q ' "${cmd[@]}" >>"$REMOTE_ROOT/commands.sh"; printf '\n' >>"$REMOTE_ROOT/commands.sh"
    set +e; "${cmd[@]}" >"$REMOTE_ROOT/seed/fio.stdout" 2>"$REMOTE_ROOT/seed/fio.stderr"; local rc=$?; set -e
    ((rc == 0)) || die seed_fio_failed
    health_before "$REMOTE_ROOT/seed/health-post"
  fi
  [[ -f "$file" && ! -L "$file" && $(stat -c %s "$file") == 34359738368 ]] || die seed_contract
  printf 'seqwrite.0.0\t%s\t%s\t%s\n' "$(stat -c %i "$file")" "$(stat -c %s "$file")" "$(stat -c %Y "$file")" >"$REMOTE_ROOT/seed/seqwrite-manifest.tsv"
  sha_file "$REMOTE_ROOT/seed/seqwrite-manifest.tsv"
}

phase_a() {
  local run=$1 ack=$2
  set_run "$run"
  [[ "$ack" == "I_ACK_04_8_PHASE_A_$run" ]] || die phase_a_ack_missing
  [[ -f "$REMOTE_ROOT/plan/PASS" && -f "$REMOTE_ROOT/common/inventory/PASS" ]] || die inventory_required
  CEPH_CONF=${CEPH_CONF:-$REMOTE_ROOT/common/ceph-msgr8.conf}
  [[ -r "$CEPH_CONF" && "$(md5sum "$CEPH_CONF" | awk '{print $1}')" == "$CEPH_CONF_MD5" ]] || die phase_a_ceph_conf_identity
  [[ -x "$JFS" && "$(md5sum "$JFS" | awk '{print $1}')" == "$JFS_MD5" ]] || die runtime_binary_identity
  [[ ! -e "$REMOTE_ROOT/RUN_STARTED" ]] || die automatic_resume_refused
  mkdir -m 0700 -p "$REMOTE_ROOT/seed" "$REMOTE_ROOT/mounts" "$REMOTE_ROOT/cells"
  : >"$REMOTE_ROOT/commands.sh"
  printf 'epoch\tevent\tcell\tdetail\n' >"$REMOTE_ROOT/incidents.tsv"
  INCIDENTS_FILE="$REMOTE_ROOT/incidents.tsv"
  if [[ -f "$REMOTE_ROOT/state/SCRUB_PAUSED" ]]; then HEALTH_MODE=paused; else HEALTH_MODE=unpaused; fi
  phase_a_exit() {
    local rc=$?
    if ((rc != 0)) && [[ -f "$REMOTE_ROOT/incidents.tsv" ]]; then
      printf '%s\tEXECUTOR_EXIT\tUNKNOWN\trc=%s;现场保留\n' "$(date +%s)" "$rc" >>"$REMOTE_ROOT/incidents.tsv"
    fi
    if [[ -f "$REMOTE_ROOT/state/SCRUB_PAUSED" ]]; then
      T048_INTERNAL_RESTORE=1 scrub_restore "$run" || rc=70
    fi
    trap - EXIT
    exit "$rc"
  }
  trap phase_a_exit EXIT
  printf '%s\n' "$run" >"$REMOTE_ROOT/RUN_STARTED"
  local cells=(S01 S02 S03 S04 S05 S06 S07 S08) fuse cell mnt O1
  for cell in "${cells[@]}"; do
    [[ "$cell" == S02 || "$cell" == S03 || "$cell" == S05 || "$cell" == S08 ]] && fuse=1M || fuse=256K
    mount_cell "$run" "$cell" "$fuse"
    mnt="/tmp/jfs-t048-$run-$cell"
    if [[ "$cell" == S01 ]]; then
      prepare_seed "$mnt"
      sleep 65
      pool_snapshot "$REMOTE_ROOT/seed/pool-O1.tsv"
      O1=$(awk -F '\t' 'NR==2{print $2}' "$REMOTE_ROOT/seed/pool-O1.tsv")
      recovery_gate seed "$O1"
    fi
    fio_detector "$cell" "$mnt"
    fio_seqwrite "$cell" "$mnt"
    gc_after_write "$cell"
    recovery_gate "$cell" "$O1"
    graceful_umount "$cell"
    # Read-only health/recovery observation; no compact or scrub mutation is hidden here.
    env CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$REMOTE_ROOT/cells/$cell/ceph-after.json" || die ceph_after_$cell
    sha_file "$REMOTE_ROOT/cells/$cell-seqwrite/fio.json"
  done
  if [[ -f "$REMOTE_ROOT/state/SCRUB_PAUSED" ]]; then
    T048_INTERNAL_RESTORE=1 scrub_restore "$run" || die scrub_restore_failed
  fi
  printf 'PHASE_A_EXECUTION_PASS\n' >"$REMOTE_ROOT/PHASE_A_PASS"
  sha256sum "$REMOTE_ROOT/commands.sh" >"$REMOTE_ROOT/commands.sha256"
  trap - EXIT
  printf 'T048_PHASE_A_PASS\t%s\n' "$REMOTE_ROOT"
}

closure() {
  local run=$1
  set_run "$run"
  [[ -f "$REMOTE_ROOT/PHASE_A_PASS" ]] || die phase_a_required
  if findmnt -rn -o TARGET | awk -v p="/tmp/jfs-t048-$run-" '$0 ~ "^"p {found=1} END{exit found?0:1}'; then
    die task_mount_still_present
  fi
  mountpoint -q "$REFERENCE_MNT" || die reference_mount_lost
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$REMOTE_ROOT/closure/reference-mount-final.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REFERENCE_MNT fuse.juicefs" "$REMOTE_ROOT/closure/reference-mount-final.tsv" || die reference_identity_final
  if [[ -f "$REMOTE_ROOT/cleanup/PASS" && ! -e "$REFERENCE_MNT/test_dir/04-8-$run" ]]; then
    printf 'ENVIRONMENT_ASSET_STATUS=CLOSED\nTASK_ASSET_CLEANUP=PASS\n' >"$REMOTE_ROOT/closure/status.tsv"
  else
    printf 'ENVIRONMENT_ASSET_STATUS=OPEN\nTASK_ASSET_CLEANUP=NOT_EXECUTED\n' >"$REMOTE_ROOT/closure/status.tsv"
  fi
  printf 'PHASE_A_CLOSURE_PASS\n' >"$REMOTE_ROOT/closure/PASS"
  sha256sum "$REMOTE_ROOT/closure/status.tsv" >"$REMOTE_ROOT/closure/status.sha256"
  printf 'T048_CLOSURE_PASS\t%s\n' "$REMOTE_ROOT"
}

cleanup_plan() {
  local run=$1 manifest mseq_manifest
  set_run "$run"
  manifest="$REMOTE_ROOT/seed/seqwrite-manifest.tsv"
  [[ -f "$manifest" && -f "$manifest.sha256" ]] || die cleanup_manifest_missing
  (cd "$(dirname "$manifest")" && sha256sum -c "$(basename "$manifest").sha256") >/dev/null || die cleanup_manifest_hash
  mkdir -m 0700 -p "$REMOTE_ROOT/cleanup"
  awk -F '\t' -v root="/test_dir/04-8-$run/seqwrite" 'NR==1{print "relative_path\tinode\tsize\tmtime\n" root "/" $1 "\t" $2 "\t" $3 "\t" $4}' "$manifest" >"$REMOTE_ROOT/cleanup/plan.tsv"
  mseq_manifest="$REMOTE_ROOT/phase-b-seed/mseqwrite-manifest.tsv"
  if [[ -f "$mseq_manifest" ]]; then
    [[ -f "$mseq_manifest.sha256" ]] || die cleanup_mseq_manifest_hash_missing
    (cd "$(dirname "$mseq_manifest")" && sha256sum -c "$(basename "$mseq_manifest").sha256") >/dev/null || die cleanup_mseq_manifest_hash
    awk -F '\t' -v root="/test_dir/04-8-$run/mseqwrite" '{print root "/" $1 "\t" $2 "\t" $3 "\t" $4}' "$mseq_manifest" >>"$REMOTE_ROOT/cleanup/plan.tsv"
  fi
  printf 'CLEANUP_PLAN_PASS\t%s\n' "$REMOTE_ROOT/cleanup/plan.tsv"
}

reference_identity_snapshot() {
  local out=$1
  mkdir -m 0700 -p "$out"
  mountpoint -q "$REFERENCE_MNT" || die reference_mount_missing
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REFERENCE_MNT fuse.juicefs" "$out/reference-mount.tsv" || die reference_identity
  python3 - "$JFS" "$REFERENCE_MNT" "$out/reference-process.tsv" <<'PY'
import hashlib, pathlib, sys
exe=pathlib.Path(sys.argv[1]).resolve(); mount=sys.argv[2]; rows=[]
for path in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if pathlib.Path(path/'exe').resolve() != exe: continue
        cmd=(path/'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
        if mount not in cmd: continue
        stat=(path/'stat').read_text().split()
        rows.append((int(path.name), int(stat[3]), stat[21], hashlib.md5((path/'exe').read_bytes()).hexdigest(), cmd))
    except (OSError, ValueError, IndexError):
        continue
if not rows: raise SystemExit('reference process identity missing')
with open(sys.argv[3], 'w') as stream:
    stream.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for row in sorted(rows): stream.write('\t'.join(map(str, row))+'\n')
PY
}

cleanup_assets() {
  local run=$1 ack=$2 rel ino size mtime file cleanup_mnt task_root
  set_run "$run"
  [[ "$ack" == "I_ACK_04_8_ASSET_CLEANUP_$run" ]] || die cleanup_ack_missing
  cleanup_plan "$run" >/dev/null
  mkdir -m 0700 -p "$REMOTE_ROOT/cleanup"
  reference_identity_snapshot "$REMOTE_ROOT/cleanup/reference-before"
  mount_cell "$run" CLEANUP 256K
  cleanup_mnt="/tmp/jfs-t048-$RUN_ID-CLEANUP"
  task_root="$cleanup_mnt/test_dir/04-8-$run"
  while IFS=$'\t' read -r rel ino size mtime; do
    [[ "$rel" == relative_path ]] && continue
    [[ "$rel" == "/test_dir/04-8-$run/seqwrite/seqwrite.0.0" || "$rel" =~ ^/test_dir/04-8-$run/mseqwrite/mseqwrite\.[0-9]+\.0$ ]] || die cleanup_path_guard
    file="$cleanup_mnt$rel"
    [[ ! -L "$file" && -f "$file" ]] || die cleanup_file_missing
    [[ "$(stat -c %i "$file")" == "$ino" && "$(stat -c %s "$file")" == "$size" ]] || die cleanup_file_drift
    unlink -- "$file"
  done <"$REMOTE_ROOT/cleanup/plan.tsv"
  rmdir -- "$task_root/seqwrite"
  [[ ! -d "$task_root/mseqwrite" ]] || rmdir -- "$task_root/mseqwrite"
  rmdir -- "$task_root"
  graceful_umount CLEANUP
  reference_identity_snapshot "$REMOTE_ROOT/cleanup/reference-after"
  cmp -s "$REMOTE_ROOT/cleanup/reference-before/reference-mount.tsv" "$REMOTE_ROOT/cleanup/reference-after/reference-mount.tsv" || die reference_mount_changed
  cmp -s "$REMOTE_ROOT/cleanup/reference-before/reference-process.tsv" "$REMOTE_ROOT/cleanup/reference-after/reference-process.tsv" || die reference_process_changed
  printf 'TASK_ASSET_CLEANUP_PASS\n' >"$REMOTE_ROOT/cleanup/PASS"
  printf 'T048_CLEANUP_PASS\t%s\n' "$REMOTE_ROOT/cleanup"
}

[[ $# -ge 2 ]] || usage
case "$1" in
  plan) plan "$2" ;;
  scrub-plan) scrub_plan "$2" ;;
  scrub-pause) [[ $# == 4 ]] || usage; scrub_pause "$2" "$3" "$4" ;;
  scrub-restore) [[ $# == 3 ]] || usage; scrub_restore "$2" "$3" ;;
  scrub-pause-b) [[ $# == 4 ]] || usage; scrub_pause_b "$2" "$3" "$4" ;;
  scrub-restore-b) [[ $# == 3 ]] || usage; scrub_restore_b "$2" "$3" ;;
  inventory) inventory "$2" ;;
  phase-a) [[ $# == 3 ]] || usage; phase_a "$2" "$3" ;;
  phase-b) [[ $# == 3 ]] || usage; phase_b "$2" "$3" ;;
  closure) closure "$2" ;;
  cleanup-plan) cleanup_plan "$2" ;;
  cleanup) [[ $# == 3 ]] || usage; cleanup_assets "$2" "$3" ;;
  *) usage ;;
esac
