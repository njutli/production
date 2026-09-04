#!/usr/bin/env bash
# State-driven 04-tmp randrw max-readahead A/B driver. Default: offline/dry-run.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
TASK="$ROOT/doc/perf-tasks/04-tmp-randrw-readahead-residual-tuning.md"
ANALYZER="$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py"
SAMPLER="$SCRIPT_DIR/s04tmp-randrw-ra-sampler.sh"
SCRUB_CONTROL="$SCRIPT_DIR/u141d-scrub-control.sh"

COMMAND=${1:-}
RUN_ID=${2:-}
DRY_RUN_ONLY=${DRY_RUN_ONLY:-1}
MOCK=${S04TMP_MOCK:-0}
RESULT_ROOT=${S04TMP_RESULT_ROOT:-/tmp/production/opencode-04-tmp-randrw-ra-${RUN_ID}}
STATE="$RESULT_ROOT/state"
INVENTORY="$RESULT_ROOT/inventory"
POOL=${S04TMP_POOL:-juicefs-data}
META=${S04TMP_META:-}
JFS=${S04TMP_JUICEFS_BIN:-}
CEPH_CONF_PRIVATE=${S04TMP_CEPH_CONF:-}
MAIN_MNT=${S04TMP_MAIN_MNT:-/mnt/juicefs}
MAIN_TEST_DIR="$MAIN_MNT/test_dir"
SSH_USER=${S04TMP_SSH_USER:-sunrise}
SSH_PASSWORD=${S04TMP_SSH_PASSWORD:-}
OSD_HOSTS=${S04TMP_OSD_HOSTS:-10.20.1.150,10.20.1.151,10.20.1.152}
SCRUB_LEASE="S04TMP-${RUN_ID}-phase-a"
SCRUB_STATE_DIR="$STATE/scrub-lease"
OBJ_TOL=8192
OBJ_POLL_MAX=${S04TMP_OBJ_POLL_MAX:-150}
OBJ_POLL_SLEEP=${S04TMP_OBJ_POLL_SLEEP:-30}
MAX_LEASE_SECONDS=57600  # 16h scrub lease wall clock budget
COMPACT_POLL_MAX=${S04TMP_COMPACT_POLL_MAX:-60}
COMPACT_POLL_SLEEP=${S04TMP_COMPACT_POLL_SLEEP:-5}
MOUNT_COMMON=(--max-uploads 150 --cache-size 0 --max-fuse-io 256K)
W_ARMS=(A B B A); W_SEEDS=(40901 40901 40902 40902)
R_ARMS=(A B B A B A A B); R_SEEDS=(41001 41001 41002 41002 41003 41003 41004 41004)
SCRUB_ACTIVE=0

die() { incident FATAL "$*" || true; printf 'E_S04TMP_DRIVER\t%s\n' "$*" >&2; exit 42; }
log() { printf 'S04TMP\t%s\t%s\n' "$(date -Is)" "$*"; }
incident() {
  local severity=$1; shift
  [[ -d ${RESULT_ROOT:-/nonexistent} ]] || return 0
  [[ -f $RESULT_ROOT/incidents.tsv ]] || printf 'epoch\tseverity\tdetail\n' >"$RESULT_ROOT/incidents.tsv"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$severity" "$*" >>"$RESULT_ROOT/incidents.tsv"
}
marker() { printf '%s\t%s\n' "$1" "$(date +%s)" >"$STATE/$1"; }
need_marker() { [[ -f $STATE/$1 ]] || die "missing marker $1"; }
no_marker() { [[ ! -e $STATE/$1 ]] || die "marker already exists $1"; }
phase() { printf '%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" >>"$RESULT_ROOT/phase-status.tsv"; }

check_scope() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die 'RUN_ID must be YYYYMMDD-HHMMSS'
  [[ $RESULT_ROOT == "/tmp/production/opencode-04-tmp-randrw-ra-$RUN_ID" ]] || die 'result root outside exact RUN scope'
  [[ $POOL == juicefs-data && $MAIN_MNT == /mnt/juicefs ]] || die 'production pool/main mount contract changed'
  [[ $SCRUB_STATE_DIR == "$RESULT_ROOT/state/scrub-lease" ]] || die 'scrub state scope changed'
  [[ ! -L $RESULT_ROOT && ! -L $MAIN_MNT ]] || die 'symlink scope rejected'
}

init_root() {
  mkdir -p "$RESULT_ROOT" "$STATE"
  [[ -f $RESULT_ROOT/phase-status.tsv ]] || printf 'phase\tstate\tepoch\n' >"$RESULT_ROOT/phase-status.tsv"
  [[ -f $RESULT_ROOT/incidents.tsv ]] || printf 'epoch\tseverity\tdetail\n' >"$RESULT_ROOT/incidents.tsv"
  [[ -f $RESULT_ROOT/commands.sh ]] || printf '#!/usr/bin/env bash\n# generated command audit; secrets redacted\n' >"$RESULT_ROOT/commands.sh"
}

method_ack() {
  local ack="$RESULT_ROOT/methodology-ack.tsv"
  [[ -f $ack ]] || die 'methodology-ack.tsv missing'
  python3 - "$ack" "$ROOT" <<'PY'
import hashlib,sys
from pathlib import Path
ack=Path(sys.argv[1]); root=Path(sys.argv[2])
required=['skills/EVIDENCE-INTEGRITY-SKILL.md','skills/fixtures/known-defect-classes.tsv',
 'skills/TUNING-SKILL.md','skills/TESTING-GUIDE.md','skills/test-commands-reference.md',
 'skills/LONG-RUNNING-TEST-SKILL.md','skills/SYSTEM-SAFETY-SKILL.md',
 'skills/baseline-reproduction-skill.md','doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md']
rows={}
for line in ack.read_text().splitlines():
 if not line or line.startswith('path\t'): continue
 p,sha,epoch,identity=line.split('\t'); rows[p]=(sha,epoch,identity)
for rel in required:
 if rel not in rows: raise SystemExit('missing methodology ACK: '+rel)
 if rows[rel][0]!=hashlib.sha256((root/rel).read_bytes()).hexdigest() or not rows[rel][1].isdigit() or not rows[rel][2]:
  raise SystemExit('invalid methodology ACK: '+rel)
PY
}

require_inputs() {
  [[ -n $JFS && -x $JFS ]] || die 'S04TMP_JUICEFS_BIN missing/not executable'
  [[ -n $META && $META == tikv://*/* ]] || die 'S04TMP_META missing/invalid'
  [[ -n $CEPH_CONF_PRIVATE && -f $CEPH_CONF_PRIVATE && ! -L $CEPH_CONF_PRIVATE ]] || die 'private CEPH_CONF missing/invalid'
  grep -Eq 'ms_async_op_threads[[:space:]]*=[[:space:]]*8' "$CEPH_CONF_PRIVATE" || die 'private CEPH_CONF lacks ms_async_op_threads=8'
}

require_real() {
  [[ $DRY_RUN_ONLY == 0 ]] || die 'real execution disabled by DRY_RUN_ONLY=1'
  require_inputs
  [[ -n $SSH_PASSWORD ]] || die 'S04TMP_SSH_PASSWORD must be supplied through environment'
  command -v sshpass >/dev/null; command -v ssh >/dev/null; command -v fio >/dev/null; command -v zstd >/dev/null
}

ssh_cmd() {
  local host=$1; shift
  SSHPASS=$SSH_PASSWORD sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=10 "$SSH_USER@$host" "$@" </dev/null
}

inventory_fixture() {
  local source=${S04TMP_FIXTURE_DIR:-}
  [[ -d $source && ! -L $source ]] || die 'mock fixture directory invalid'
  while IFS= read -r -d '' file; do cp -- "$file" "$INVENTORY/${file##*/}"; done \
    < <(find "$source" -mindepth 1 -maxdepth 1 -type f -print0)
}

record_assets() {
  local root=$1
  local output=$2
  {
    printf 'name\tsize\tinode\tmtime\n'
    find "$root" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%s\t%i\t%T@\n' | sort -V
  } >"$output"
}

cmd_init() {
  check_scope; [[ ! -e $RESULT_ROOT ]] || die 'RUN_ID/result root already exists'
  init_root; phase init START
  sha256sum "$TASK" "$0" "$ANALYZER" "$SAMPLER" "$SCRUB_CONTROL" >"$RESULT_ROOT/input-sha256.txt"
  marker INIT_COMPLETE; phase init PASS; log "INIT_PASS root=$RESULT_ROOT"
}

cmd_phase_i() {
  local verdict
  check_scope; init_root; need_marker INIT_COMPLETE; no_marker PHASE_I_COMPLETE; method_ack
  phase phase-i START; mkdir -p "$INVENTORY" "$RESULT_ROOT/plans"
  if [[ $MOCK == 1 ]]; then
    [[ $DRY_RUN_ONLY == 1 ]] || die 'mock inventory requires dry-run'
    inventory_fixture
  else
    [[ $DRY_RUN_ONLY == 0 && ${S04TMP_READONLY_ACK:-} == I_ACK_S04TMP_READONLY_INVENTORY ]] || die 'read-only inventory ACK missing'
    require_inputs
    verdict=${S04TMP_U1_VERDICT:-}
    case $verdict in REPLACE_APPROVED|REPLACE_REJECTED|REPLACE_NOT_PROVEN) ;; *) die 'U1 verdict not final; 04-tmp remains HOLD' ;; esac
    if [[ $verdict != REPLACE_APPROVED ]]; then
      [[ $(md5sum "$JFS" | awk '{print $1}') == de93563f11a5ff3bd94dd25a4e0283b1 ]] || die 'non-approved replacement requires frozen v1.3 binary'
    fi
    "$JFS" version >"$INVENTORY/juicefs-version.txt"
    md5sum "$JFS" >"$INVENTORY/juicefs-md5.txt"; sha256sum "$CEPH_CONF_PRIVATE" >"$INVENTORY/private-ceph-conf.sha256"
    if [[ -f /etc/ceph/ceph.conf ]]; then md5sum /etc/ceph/ceph.conf >"$INVENTORY/system-ceph-conf.md5"; else printf 'ABSENT\n' >"$INVENTORY/system-ceph-conf.md5"; fi
    CEPH_CONF="$CEPH_CONF_PRIVATE" "$JFS" status "$META" >"$INVENTORY/volume-status.json"
    findmnt -rn -M "$MAIN_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$INVENTORY/main-mount.txt"
    record_assets "$MAIN_TEST_DIR" "$INVENTORY/assets.tsv"
    sudo ceph fsid >"$INVENTORY/ceph-fsid.txt"
    sudo ceph health detail --format json >"$INVENTORY/ceph-health.json"
    sudo ceph status --format json >"$INVENTORY/ceph-status.json"
    sudo ceph osd dump --format json >"$INVENTORY/osd-dump.json"
    sudo ceph osd stat --format json >"$INVENTORY/osd-stat.json"
    sudo ceph pg dump pgs_brief --format json >"$INVENTORY/pg.json"
    sudo ceph osd pool ls detail --format json >"$INVENTORY/pools.json"
    sudo ceph df detail --format json >"$INVENTORY/df.json"
    ps -eo pid=,ppid=,comm=,args= >"$INVENTORY/processes.txt"
    findmnt -rn -t fuse.juicefs,fuse,ext4,tmpfs >"$INVENTORY/mounts.txt" || true
    free -b >"$INVENTORY/memory.txt"; df -B1 /tmp >"$INVENTORY/archive-space.txt"
    printf 'u1_verdict\t%s\nepoch\t%s\n' "$verdict" "$(date +%s)" >"$INVENTORY/contract.tsv"
  fi
  python3 "$ANALYZER" assets --input "$INVENTORY/assets.tsv" --output "$INVENTORY/assets-contract.json" >"$INVENTORY/assets-validator.txt"
  python3 - "$INVENTORY/volume-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get('Setting',{})
assert s.get('UUID') and s.get('Name')
PY
  (
    cd "$INVENTORY"; find . -maxdepth 1 -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum >manifest.sha256
  )
  marker PHASE_I_COMPLETE; phase phase-i PASS; log PHASE_I_PASS
}

write_mount_tokens() {
  local arm=$1
  local out=$2
  : >"$out"
  printf '%s\n' "$JFS" mount -d "${MOUNT_COMMON[@]}" >"$out"
  [[ $arm == B ]] && printf '%s\n' --max-readahead 0 >>"$out"
  printf '%s\n' '<META>' '<RUN_MOUNT>' >>"$out"
}

cmd_plan() {
  local i
  check_scope; init_root; need_marker PHASE_I_COMPLETE; no_marker PHASE_II_PLAN_COMPLETE
  phase phase-ii-plan START; mkdir -p "$RESULT_ROOT/plans" "$STATE/scrub-lease"
  write_mount_tokens A "$RESULT_ROOT/plans/mount-A.tokens"
  write_mount_tokens B "$RESULT_ROOT/plans/mount-B.tokens"
  python3 - "$RESULT_ROOT/plans/mount-A.tokens" "$RESULT_ROOT/plans/mount-B.tokens" <<'PY'
import sys
a=open(sys.argv[1]).read().splitlines(); b=open(sys.argv[2]).read().splitlines()
assert '--max-readahead' not in a and '--max-readahead' in b
x=list(b); i=x.index('--max-readahead'); assert x[i:i+2]==['--max-readahead','0']; del x[i:i+2]
assert x==a, (a,b)
PY
  cat >"$RESULT_ROOT/plans/fio.tokens" <<'EOF'
fio
--directory=<RUN_MOUNT>/test_dir
--name=rw_test
--filesize=1G
--size=1G
--bs=256k
--rw=randrw
--rwmixread=50
--ioengine=libaio
--iodepth=128
--numjobs=128
--direct=1
--fallocate=none
--openfiles=128
--time_based
--runtime=180
--randrepeat=1
--randseed=<FROZEN_PAIR_SEED>
--allow_file_create=0
--group_reporting
--log_avg_msec=1000
EOF
  printf 'kind\tindex\tarm\tlabel\trandseed\n' >"$RESULT_ROOT/plans/matrix.tsv"
  for i in $(seq 1 4); do printf 'warmup\t%02d\t%s\tW%02d\t%s\n' "$i" "${W_ARMS[i-1]}" "$i" "${W_SEEDS[i-1]}"; done >>"$RESULT_ROOT/plans/matrix.tsv"
  for i in $(seq 1 8); do printf 'formal\t%02d\t%s\tR%02d\t%s\n' "$i" "${R_ARMS[i-1]}" "$i" "${R_SEEDS[i-1]}"; done >>"$RESULT_ROOT/plans/matrix.tsv"
  cat >"$RESULT_ROOT/plans/sudo-writes.txt" <<EOF
sudo ceph osd set noscrub
sudo ceph osd set nodeep-scrub
sudo ceph tell osd.<0..5> compact
printf 3 | sudo tee /proc/sys/vm/drop_caches              # local 157
ssh ${SSH_USER}@<${OSD_HOSTS}> "printf 3 | sudo tee /proc/sys/vm/drop_caches"
sudo ceph osd unset nodeep-scrub                           # only if lease owns it
sudo ceph osd unset noscrub                                # only if lease owns it
EOF
  cat >"$RESULT_ROOT/plans/cleanup.txt" <<EOF
$JFS umount <RUN_MOUNT>
$JFS gc --compact <META>
sudo ceph tell osd.<0..5> compact
# No format/destroy/layout/pool create/delete/restart/force-lazy umount.
EOF
  U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" --self-test >"$RESULT_ROOT/plans/scrub-controller-selftest.txt"
  sha256sum "$RESULT_ROOT/plans/"* >"$RESULT_ROOT/plans/sha256.txt"
  mkdir -p "$RESULT_ROOT/scripts-executed"
  cp -- "$0" "$ANALYZER" "$SAMPLER" "$SCRUB_CONTROL" "$TASK" "$RESULT_ROOT/scripts-executed/"
  (
    cd "$RESULT_ROOT"
    sha256sum methodology-ack.tsv input-sha256.txt inventory/manifest.sha256 plans/sha256.txt scripts-executed/* >authorized-inputs.sha256
  )
  if [[ $MOCK != 1 ]]; then
    sha256sum "$JFS" "$CEPH_CONF_PRIVATE" >>"$RESULT_ROOT/authorized-inputs.sha256"
  fi
  marker PHASE_II_PLAN_COMPLETE; phase phase-ii-plan PASS; log PHASE_II_PLAN_PASS
}

object_count() {
  local out=$1
  sudo ceph df detail --format json >"$out"
  python3 "$ANALYZER" objects --input "$out" --pool "$POOL" --output "$out.objects.json" | awk -F= '/objects=/{print $2}'
}

verify_authorized_inputs() {
  (cd "$RESULT_ROOT"; sha256sum -c authorized-inputs.sha256 >/dev/null)
}

check_paused() {
  U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" verify-paused "$SCRUB_LEASE" >/dev/null
}

restore_scrub() {
  (( SCRUB_ACTIVE == 1 )) || return 0
  set +e
  U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" restore "$SCRUB_LEASE" >"$RESULT_ROOT/closure/scrub-restore.txt" 2>&1
  local rc=$?
  set -e
  (( rc == 0 )) || { incident SAFETY 'scrub restore failed'; return "$rc"; }
  U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" verify-restored "$SCRUB_LEASE" >>"$RESULT_ROOT/closure/scrub-restore.txt"
  SCRUB_ACTIVE=0
}

failure_trap() {
  local rc=$?
  (( rc == 0 )) && return 0
  incident FATAL "phase-ii unexpected exit rc=$rc; restoring scrub first"
  restore_scrub || true
  exit "$rc"
}

compact_cooldown() {
  local out=$1
  local poll osd raw ok
  mkdir -p "$out"
  mapfile -t osds < <(sudo ceph osd ls | awk '/^[0-9]+$/{print}')
  (( ${#osds[@]} == 6 )) || die 'compact contract requires exactly six OSDs'
  for osd in "${osds[@]}"; do timeout 30 sudo ceph tell "osd.$osd" compact >"$out/compact-$osd.txt" 2>&1 || die "compact request failed osd.$osd"; done
  for poll in $(seq 1 "$COMPACT_POLL_MAX"); do
    ok=1
    for osd in "${osds[@]}"; do
      raw="$out/perf-$poll-$osd.json"; timeout 15 sudo ceph tell "osd.$osd" perf dump >"$raw" || die "perf dump failed osd.$osd"
      python3 - "$raw" <<'PY' || ok=0
import json,sys
d=json.load(open(sys.argv[1])); r=d.get('rocksdb',{}); b=d.get('bluestore',{}).get('kv_sync_lat',{})
assert r.get('compact_running')==0 and r.get('compact_queue_len')==0
assert isinstance(b.get('avgtime'),(int,float)) and b['avgtime'] < .002
PY
    done
    (( ok == 1 )) && { printf 'COMPACT_COOLDOWN_PASS\t%s\n' "$poll" >"$out/PASS"; return 0; }
    sleep "$COMPACT_POLL_SLEEP"
  done
  die 'compact cooldown timed out'
}

drop_caches() {
  local host
  sync; printf '3\n' | sudo tee /proc/sys/vm/drop_caches >/dev/null
  IFS=',' read -ra hosts <<<"$OSD_HOSTS"
  for host in "${hosts[@]}"; do ssh_cmd "$host" "sync; printf '3\\n' | sudo tee /proc/sys/vm/drop_caches >/dev/null"; done
  sleep 20
}

mount_cell() {
  local arm=$1
  local label=$2
  local mnt=$3
  local out=$4
  local args=("${MOUNT_COMMON[@]}")
  [[ $arm == B ]] && args+=(--max-readahead 0)
  mkdir "$mnt"

  local conf_sha256 jfs_md5 meta_identity
  conf_sha256=$(sha256sum "$CEPH_CONF_PRIVATE" | awk '{print $1}')
  jfs_md5=$(md5sum "$JFS" | awk '{print $1}')
  meta_identity=$(echo "$META" | sed 's|://[^@]*@|://***@|; s|//[^/]*/|//***/|')
  { printf 'field\tvalue\n'
    printf 'ceph_conf_path\t%s\n' "$CEPH_CONF_PRIVATE"
    printf 'ceph_conf_sha256\t%s\n' "$conf_sha256"
    printf 'jfs_path\t%s\n' "$JFS"
    printf 'jfs_md5\t%s\n' "$jfs_md5"
    printf 'meta_identity\t%s\n' "$meta_identity"
    printf 'arm\t%s\n' "$arm"
    printf 'mount_path\t%s\n' "$mnt"
    printf 'tokens\t%s\n' "${args[*]}"
  } >"$out/mount-launch-contract.tsv"

  printf 'CEPH_CONF=<SHA256-FROZEN> %q mount -d' "$JFS" >>"$RESULT_ROOT/commands.sh"
  printf ' %q' "${args[@]}" '<META>' "$mnt" >>"$RESULT_ROOT/commands.sh"; printf '\n' >>"$RESULT_ROOT/commands.sh"
  CEPH_CONF="$CEPH_CONF_PRIVATE" "$JFS" mount -d "${args[@]}" "$META" "$mnt" >"$out/mount.txt" 2>&1
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/findmnt.txt"
  findmnt -rn -M "$mnt" -o OPTIONS >"$out/mount-options.txt"
  grep -Eq '(^|,)max_read=262144(,|$)' "$out/mount-options.txt" || die "$label mount lacks max_read=262144"
  CEPH_CONF="$CEPH_CONF_PRIVATE" "$JFS" status "$META" >"$out/status.json"
  python3 - "$mnt" "$JFS" "$CEPH_CONF_PRIVATE" "$arm" "$out/mount-processes.tsv" "$out/selected-worker.pid" <<'PY'
import hashlib,os,sys
mnt,exe,expected_conf,arm,out_mproc,out_pid=sys.argv[1:7]
expected=os.path.realpath(exe); rows=[]
for name in os.listdir('/proc'):
 if not name.isdigit(): continue
 try:
  raw=open('/proc/'+name+'/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace')
  env=open('/proc/'+name+'/environ','rb').read().split(b'\0')
  actual=os.path.realpath('/proc/'+name+'/exe'); stat=open('/proc/'+name+'/stat').read().split()
 except OSError: continue
 if mnt in raw and actual==expected:
  conf=[x.decode(errors='replace').split('=',1)[1] for x in env if x.startswith(b'CEPH_CONF=')]
  conf_present=1 if conf else 0
  rows.append((int(name),int(stat[3]),int(stat[21]),actual,hashlib.md5(open(actual,'rb').read()).hexdigest(),conf[0] if conf else '',conf_present,raw))
if not rows: raise SystemExit('no exact JuiceFS mount process')
ids={x[0] for x in rows}; workers=[x for x in rows if x[1] in ids]; selected=max(workers or rows,key=lambda x:x[2])
tokens=selected[-1].split()
if arm=='A' and '--max-readahead' in tokens: raise SystemExit('A unexpectedly contains max-readahead')
if arm=='B' and not any(tokens[i:i+2]==['--max-readahead','0'] for i in range(len(tokens)-1)):
 raise SystemExit('B lacks exact max-readahead 0')
with open(out_mproc,'w') as f:
 f.write('pid\tppid\tstarttime\texe\texe_md5\tceph_conf\tceph_conf_env_present\tselected_worker\tcmdline\n')
 for x in sorted(rows): f.write('\t'.join(map(str,x[:6]))+'\t'+str(x[6])+'\t'+('1' if x[0]==selected[0] else '0')+'\t'+x[7]+'\n')
with open(out_pid,'w') as f: f.write(str(selected[0])+'\n')
PY
  python3 - "$INVENTORY/volume-status.json" "$out/status.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])).get('Setting',{}); b=json.load(open(sys.argv[2])).get('Setting',{})
for key in ('UUID','Name','Storage','Bucket','BlockSize'):
 if key in a or key in b: assert a.get(key)==b.get(key), (key,a.get(key),b.get(key))
assert a.get('UUID')
PY
}

graceful_umount() {
  local mnt=$1
  local out=$2
  CEPH_CONF="$CEPH_CONF_PRIVATE" "$JFS" umount "$mnt" >"$out/umount.txt" 2>&1
  for _ in $(seq 1 180); do mountpoint -q "$mnt" || { rmdir "$mnt"; return 0; }; sleep 1; done
  die "graceful umount timeout $mnt"
}

asset_guard() {
  local root=$1
  local out=$2
  record_assets "$root" "$out"
  python3 "$ANALYZER" assets --input "$out" --output "$out.json" >/dev/null
  python3 - "$INVENTORY/assets.tsv" "$out" <<'PY'
import csv,sys
def load(p):
 with open(p,newline='') as f:return {r['name']:(r['size'],r['inode']) for r in csv.DictReader(f,delimiter='\t')}
assert load(sys.argv[1])==load(sys.argv[2])
PY
}

wait_object_seed() {
  local seed=$1
  local out=$2
  local low=$(( seed > OBJ_TOL ? seed-OBJ_TOL : 0 ))
  local high=$((seed+OBJ_TOL))
  local value poll epoch first_drop_epoch=""
  mkdir -p "$out"
  printf 'poll\tepoch\tobjects\tstored\n' >"$out/objects.tsv"
  for poll in $(seq 1 "$OBJ_POLL_MAX"); do
    epoch=$(date +%s)
    value=$(object_count "$out/df-$poll.json")
    local stored_val=$(python3 -c 'import json;print(json.load(open("'$out'/df-'$poll'.json.objects.json"))["stored"])' 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\n' "$poll" "$epoch" "$value" "$stored_val" >>"$out/objects.tsv"
    if [[ -z "$first_drop_epoch" && $value -ge $low && $value -le $high ]]; then
      first_drop_epoch="$epoch"
      printf 'FIRST_DROP\tpoll=%s\tepoch=%s\tvalue=%s\n' "$poll" "$epoch" "$value" >"$out/first-drop.txt"
    fi
    if (( poll >= 3 && value >= low && value <= high )); then
      if python3 - "$out" "$poll" "$low" "$high" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); poll=int(sys.argv[2]); low=int(sys.argv[3]); high=int(sys.argv[4]); rows=[]
for i in range(poll-2,poll+1): rows.append(json.load(open(root/f'df-{i}.json.objects.json')))
objects=[x['objects'] for x in rows]; stored=[x['stored'] for x in rows]
assert all(low<=x<=high for x in objects) and max(objects)-min(objects)<=32
assert max(stored)==min(stored)
PY
      then printf 'OBJECT_RETURN_PASS\t%s\t%s\tstable_samples=3\tfirst_drop_epoch=%s\tpass_epoch=%s\n' "$seed" "$value" "${first_drop_epoch:-unknown}" "$epoch" >"$out/PASS"; return 0; fi
    fi
    sleep "$OBJ_POLL_SLEEP"
  done
  die "objects did not return to seed=$seed tolerance=$OBJ_TOL after $OBJ_POLL_MAX polls ($((OBJ_POLL_MAX*OBJ_POLL_SLEEP))s)"
}

run_cell() {
  local kind=$1
  local label=$2
  local arm=$3
  local seed=$4
  local seed_objects=$5
  local out="$RESULT_ROOT/$kind/$label"
  local mnt="/tmp/jfs-s04tmp-${RUN_ID}-${label}"
  local worker sampler_out sampler_pid fio_rc sampler_rc current_objects
  [[ ! -e $out && ! -e $mnt ]] || die "cell path already exists label=$label"
  mkdir -p "$out/bw"; verify_authorized_inputs; check_paused
  sudo ceph health detail --format json >"$out/health-pre.json"
  current_objects=$(object_count "$out/df-pre.json")
  printf '%s\n' "$current_objects" >"$out/objects-pre.txt"
  (( current_objects >= seed_objects-OBJ_TOL && current_objects <= seed_objects+OBJ_TOL )) || die "pre-cell objects outside seed tolerance label=$label"
  asset_guard "$MAIN_TEST_DIR" "$out/assets-main-pre.tsv"
  mount_cell "$arm" "$label" "$mnt" "$out"
  worker=$(cat "$out/selected-worker.pid" 2>/dev/null || echo '')
  [[ -n "$worker" ]] || die "selected-worker.pid empty label=$label"
  [[ "$worker" =~ ^[0-9]+$ ]] || die "selected-worker.pid not numeric: '$worker' label=$label"
  kill -0 "$worker" 2>/dev/null || die "selected worker PID $worker not alive label=$label"
  asset_guard "$mnt/test_dir" "$out/assets-mounted-pre.tsv"
  drop_caches
  sampler_out="$out/sampler"; mkdir -p "$sampler_out"
  DRY_RUN_ONLY=0 bash "$SAMPLER" "$RUN_ID" "$sampler_out" 240 "$worker" >"$out/sampler-console.txt" 2>&1 & sampler_pid=$!
  printf '%s\n' "$sampler_pid" >"$out/sampler-pid.txt"; sleep 5
  printf '%s\n' "$(date +%s%N)" >"$out/fio-start-ns.txt"
  set +e
  printf 'fio --directory=%q --name=rw_test --filesize=1G --size=1G --bs=256k --rw=randrw --rwmixread=50 --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --time_based --runtime=180 --randrepeat=1 --randseed=%q --allow_file_create=0 --group_reporting --write_bw_log=%q --log_avg_msec=1000\n' \
    "$mnt/test_dir" "$seed" "$out/bw/rw_test" >>"$RESULT_ROOT/commands.sh"
  fio --directory="$mnt/test_dir" --name=rw_test --filesize=1G --size=1G --bs=256k --rw=randrw \
    --rwmixread=50 --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none \
    --openfiles=128 --time_based --runtime=180 --randrepeat=1 --randseed="$seed" \
    --allow_file_create=0 --group_reporting --write_bw_log="$out/bw/rw_test" --log_avg_msec=1000 \
    >"$out/fio.txt" 2>"$out/fio.stderr"
  fio_rc=$?
  set -e
  printf '%s\n' "$(date +%s%N)" >"$out/fio-end-ns.txt"
  touch "$sampler_out/STOP_REQUEST"
  set +e; wait "$sampler_pid"; sampler_rc=$?; set -e
  printf '%s\n' "$fio_rc" >"$out/fio.rc"; printf '%s\n' "$sampler_rc" >"$out/sampler.rc"
  (( fio_rc == 0 && sampler_rc == 0 )) || die "cell process failure label=$label fio=$fio_rc sampler=$sampler_rc"
  [[ -f $sampler_out/SAMPLER_PASS ]] || die "sampler PASS missing label=$label"
  python3 "$ANALYZER" sidecar --round-dir "$out" --output "$out/sidecar-contract.json" >"$out/sidecar-validator.txt"
  [[ $(find "$out/bw" -maxdepth 1 -type f -name '*_bw.*.log' | wc -l) -eq 128 ]] || die "bw log count !=128 label=$label"
  asset_guard "$mnt/test_dir" "$out/assets-mounted-post.tsv"
  graceful_umount "$mnt" "$out"
  printf '%q gc --compact %q\n' "$JFS" '<META>' >>"$RESULT_ROOT/commands.sh"
  CEPH_CONF="$CEPH_CONF_PRIVATE" "$JFS" gc --compact "$META" >"$out/gc.txt" 2>&1
  compact_cooldown "$out/compact"
  wait_object_seed "$seed_objects" "$out/object-return"
  check_paused; sudo ceph health detail --format json >"$out/health-post.json"
  printf 'CELL_PASS\t%s\t%s\t%s\t%s\n' "$label" "$arm" "$seed" "$(date +%s)" >"$out/CELL_PASS"
}

mock_execute() {
  mkdir -p "$RESULT_ROOT/warmup" "$RESULT_ROOT/formal" "$RESULT_ROOT/closure"
  for i in $(seq 1 4); do printf -v label 'W%02d' "$i"; mkdir "$RESULT_ROOT/warmup/$label"; printf 'CELL_PASS\t%s\n' "$label" >"$RESULT_ROOT/warmup/$label/CELL_PASS"; done
  for i in $(seq 1 8); do printf -v label 'R%02d' "$i"; mkdir "$RESULT_ROOT/formal/$label"; printf 'CELL_PASS\t%s\n' "$label" >"$RESULT_ROOT/formal/$label/CELL_PASS"; done
  printf 'SCRUB_RESTORE_PASS mock\n' >"$RESULT_ROOT/closure/scrub-restore.txt"
  marker PHASE_II_COMPLETE; phase phase-ii PASS; log PHASE_II_MOCK_PASS
}

cmd_execute() {
  local fsid seed archive i label
  check_scope; init_root; need_marker PHASE_II_PLAN_COMPLETE; no_marker PHASE_II_COMPLETE
  if [[ $MOCK == 1 ]]; then [[ $DRY_RUN_ONLY == 1 ]] || die 'mock execute requires dry-run'; mock_execute; return; fi
  require_real
  [[ ${S04TMP_PHASE2_ACK:-} == "I_ACK_S04TMP_PHASE2_${RUN_ID}" ]] || die 'exact Phase II ACK missing'
  [[ ${S04TMP_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die 'separate global scrub ACK missing'
  phase phase-ii START; mkdir -p "$RESULT_ROOT"/{warmup,formal,closure,snapshots/pre,snapshots/post}
  local lease_start_epoch; lease_start_epoch=$(date +%s)
  printf '%s\n' "$lease_start_epoch" >"$STATE/lease-start-epoch.txt"
  trap failure_trap EXIT
  verify_authorized_inputs
  sha256sum -c "$RESULT_ROOT/input-sha256.txt" >"$RESULT_ROOT/closure/input-verify.txt"
  fsid=$(<"$INVENTORY/ceph-fsid.txt")
  U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" pause "$SCRUB_LEASE" "$fsid" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$RESULT_ROOT/closure/scrub-pause.txt"
  SCRUB_ACTIVE=1; check_paused
  CEPH_CONF="$CEPH_CONF_PRIVATE" "$JFS" gc --compact "$META" >"$RESULT_ROOT/snapshots/pre/gc.txt" 2>&1
  compact_cooldown "$RESULT_ROOT/snapshots/pre/compact"
  seed=$(object_count "$RESULT_ROOT/snapshots/pre/df-seed.json")
  printf '%s\n' "$seed" >"$STATE/seed-objects.txt"
  wait_object_seed "$seed" "$RESULT_ROOT/snapshots/pre/object-stability"
  for i in $(seq 1 4); do
    printf -v label 'W%02d' "$i"
    local elapsed=$(( $(date +%s) - lease_start_epoch ))
    (( elapsed + 5400 <= MAX_LEASE_SECONDS )) || { incident FATAL "lease deadline: elapsed=${elapsed}s before $label"; die "lease wall clock approaching 16h before $label"; }
    run_cell warmup "$label" "${W_ARMS[i-1]}" "${W_SEEDS[i-1]}" "$seed"
  done
  for i in $(seq 1 8); do
    printf -v label 'R%02d' "$i"
    local elapsed=$(( $(date +%s) - lease_start_epoch ))
    (( elapsed + 5400 <= MAX_LEASE_SECONDS )) || { incident FATAL "lease deadline: elapsed=${elapsed}s before $label"; die "lease wall clock approaching 16h before $label"; }
    run_cell formal "$label" "${R_ARMS[i-1]}" "${R_SEEDS[i-1]}" "$seed"
  done
  restore_scrub
  sudo ceph health detail --format json >"$RESULT_ROOT/snapshots/post/health.json"
  asset_guard "$MAIN_TEST_DIR" "$RESULT_ROOT/snapshots/post/assets.tsv"
  marker PHASE_II_COMPLETE; phase phase-ii PASS
  (
    cd "$RESULT_ROOT"; find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum >manifest.sha256
  )
  archive="/tmp/production/opencode-04-tmp-randrw-ra-${RUN_ID}.archive.tar.zst"
  [[ ! -e $archive && ! -e $archive.sha256 ]] || die 'archive already exists'
  tar -C /tmp/production -cf - "opencode-04-tmp-randrw-ra-${RUN_ID}" | zstd -T0 -q -o "$archive"
  sha256sum "$archive" >"$archive.sha256"
  printf 'ALL_DONE\t%s\t%s\n' "$(date +%s)" "$archive" >"$RESULT_ROOT/ALL_DONE"
  trap - EXIT; log PHASE_II_PASS
}

cmd_recover_scrub() {
  check_scope; init_root
  [[ -d $SCRUB_STATE_DIR ]] || die 'scrub state directory missing'
  SCRUB_ACTIVE=1; restore_scrub; log SCRUB_RECOVERY_PASS
}

cmd_inspect() {
  check_scope; init_root
  printf 'run_id\t%s\nresult_root\t%s\nscrub_lease\t%s\n' "$RUN_ID" "$RESULT_ROOT" "$SCRUB_LEASE"
  find "$STATE" -maxdepth 2 -type f -printf '%P\n' | sort
}

check_scope
case $COMMAND in
  init) cmd_init ;;
  phase-i) cmd_phase_i ;;
  phase-ii-plan) cmd_plan ;;
  phase-ii-execute) cmd_execute ;;
  recover-scrub) cmd_recover_scrub ;;
  inspect) cmd_inspect ;;
  *) die 'usage: s04tmp-randrw-ra-driver.sh {init|phase-i|phase-ii-plan|phase-ii-execute|recover-scrub|inspect} RUN_ID' ;;
esac
