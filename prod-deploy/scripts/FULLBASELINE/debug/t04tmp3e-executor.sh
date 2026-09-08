#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 04-tmp3e: one private B4 volume, one immutable read asset, no sudo.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXECUTOR=$(readlink -f -- "${BASH_SOURCE[0]}")
ANALYZER="$SELF_DIR/t04tmp3e-analyze.py"
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META_BASE=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
CURRENT_REF=/mnt/juicefs
CURRENT_ASSET="$CURRENT_REF/test_dir/seqread/seqread.0.0"
ASSET_REL=/test_dir/seqread/seqread.0.0
REMOTE_PARENT=/tmp/production
LOCAL_PARENT=/mnt/c/SunRise/test/04-tmp3e
METRICS_ADDR=127.0.0.1:19657
CEPH_ROUTE_TARGET=10.3.1.6
RUN_ID=${2:-}
ROOT= TMP_META= TMP_NAME= TMP_MNT= CEPH_CONF= ACTIVE_STOP= ACTIVE_SAMPLER=

die() { printf 'T04TMP3E_EXECUTOR_FAIL\t%s\n' "$*" >&2; exit 42; }
usage() {
  printf '%s\n' \
    'usage: t04tmp3e-executor.sh inventory-plan RUN_ID' \
    '       t04tmp3e-executor.sh prepare RUN_ID I_ACK_04TMP3E_PREPARE_RUN_ID' \
    '       t04tmp3e-executor.sh phase-a RUN_ID I_ACK_04TMP3E_PHASE_A_RUN_ID' \
    '       t04tmp3e-executor.sh phase-b RUN_ID I_ACK_04TMP3E_PHASE_B_RUN_ID' \
    '       t04tmp3e-executor.sh cleanup-plan RUN_ID' \
    '       t04tmp3e-executor.sh cleanup RUN_ID I_ACK_04TMP3E_CLEANUP_RUN_ID' \
    '       t04tmp3e-executor.sh gate0 | --self-test' >&2
  exit 2
}
scope() {
  ROOT="$REMOTE_PARENT/opencode-04tmp3e-$RUN_ID"
  TMP_META="${META_BASE%/*}/$RUN_ID-b4"
  TMP_NAME="$RUN_ID-b4"
  TMP_MNT="/tmp/jfs-04tmp3e-$RUN_ID-b4"
}
valid_scope() {
  scope
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ "$ROOT" == "$REMOTE_PARENT/opencode-04tmp3e-$RUN_ID" && "$ROOT" != / && "$ROOT" != *..* ]] || die unsafe_root
  [[ "$TMP_META" == "${META_BASE%/*}/$RUN_ID-b4" && "$TMP_NAME" == "$RUN_ID-b4" ]] || die unsafe_volume
  [[ "$TMP_MNT" == "/tmp/jfs-04tmp3e-$RUN_ID-b4" ]] || die unsafe_mount
  [[ ! -L "$ROOT" && ! -L "$TMP_MNT" ]] || die symlink_scope
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing_tool_$1"; }
fixed_binary() {
  [[ -x "$JFS" && ! -L "$JFS" ]] || die binary_missing
  [[ "$(md5sum "$JFS" | awk '{print $1}')" == "$JFS_MD5" ]] || die binary_md5_drift
}
ack() { [[ "$2" == "I_ACK_04TMP3E_$1_$RUN_ID" ]] || die "invalid_ACK_$1"; }
record() {
  [[ -f "$ROOT/commands.sh" ]] || : >"$ROOT/commands.sh"
  printf '#' >>"$ROOT/commands.sh"; printf ' %q' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"
}
incident() { printf '%s\t%s\t%s\n' "$(date -Ins)" "$1" "$2" >>"$ROOT/incidents.tsv"; }
mark() { mkdir -p "$(dirname -- "$ROOT/$1")"; printf '%s\n' "$(date -Ins)" >"$ROOT/$1"; }

prepare_ceph_conf() {
  CEPH_CONF="$ROOT/inventory/ceph.conf"
  if [[ ! -f "$CEPH_CONF" ]]; then
    [[ -r /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_missing
    cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
    printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
    sha256sum "$CEPH_CONF" >"$ROOT/inventory/ceph.conf.sha256"
  else sha256sum -c "$ROOT/inventory/ceph.conf.sha256" >/dev/null || die ceph_conf_drift; fi
  grep -Fqx $'\tms_async_op_threads = 8' "$CEPH_CONF" || die ceph_conf_msgr8_missing
  export CEPH_CONF
}
ceph_read() { timeout 30 env CEPH_CONF="$CEPH_CONF" ceph "$@"; }
health_gate() {
  local tag=$1 out="$ROOT/health-$1"; mkdir -m 0700 -p "$out"
  ceph_read -s --format json >"$out/status.json"
  ceph_read osd stat --format json >"$out/osd-stat.json"
  ceph_read pg dump pgs_brief >"$out/pgs.txt"
  python3 - "$out/status.json" "$out/osd-stat.json" "$out/pgs.txt" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2]))
if (s.get('health') or {}).get('status') != 'HEALTH_OK': raise SystemExit('health not OK')
if len({o.get(k) for k in ('num_osds','num_up_osds','num_in_osds')}) != 1: raise SystemExit('OSDs not all up/in')
states=[]
for line in open(sys.argv[3]):
    f=line.split()
    if f and f[0][:1].isdigit() and len(f)>1: states.append(f[1])
if not states or any(x != 'active+clean' for x in states): raise SystemExit('PGs not all active+clean')
PY
}
status_identity() {
  local meta=$1 expected=$2 prefix=$3
  timeout 30 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$prefix.json"
  python3 - "$prefix.json" "$expected" >"$prefix.tsv" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('Setting') or {}
if s.get('Name') != sys.argv[2] or not s.get('UUID'): raise SystemExit('volume identity mismatch')
print('name\t'+str(s['Name'])); print('uuid\t'+str(s['UUID'])); print('block_size\t'+str(s.get('BlockSize')))
PY
}
assert_unformatted() {
  local meta=$1 stdout=$2 stderr=$3 rc
  set +e; timeout 20 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$stdout" 2>"$stderr"; rc=$?; set -e
  (( rc != 0 )) || die volume_already_formatted
  grep -Fq 'database is not formatted' "$stderr" || die status_failed_without_not_formatted_proof
}
asset_fingerprint() {
  local file=$1 out=$2; [[ -f "$file" && ! -L "$file" ]] || die asset_missing
  printf 'bytes\t%s\ninode\t%s\nmtime\t%s\nhead_sha256\t%s\ntail_sha256\t%s\n' \
    "$(stat -c %s "$file")" "$(stat -c %i "$file")" "$(stat -c %Y "$file")" \
    "$(head -c 1048576 "$file" | sha256sum | awk '{print $1}')" \
    "$(tail -c 1048576 "$file" | sha256sum | awk '{print $1}')" >"$out"
}
current_processes() {
  python3 - "$JFS" "$CURRENT_REF" "$META_BASE" "$1" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); mnt,meta,out=sys.argv[2:]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if ' mount ' not in cmd or mnt not in cmd or meta not in cmd: continue
        st=(p/'stat').read_text().split(); rows.append((int(p.name),int(st[3]),int(st[21]),hashlib.md5(open(p/'exe','rb').read()).hexdigest()))
    except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit('current mount process missing')
with open(out,'w') as f:
    f.write('pid\tppid\tstarttime\texe_md5\n')
    for row in sorted(rows): f.write('\t'.join(map(str,row))+'\n')
PY
}
snapshot_current() {
  local tag=$1 dir="$ROOT/inventory/current-$1"; mkdir -m 0700 -p "$dir"
  mountpoint -q "$CURRENT_REF" || die current_mount_missing
  findmnt -rn -M "$CURRENT_REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$dir/mount.tsv"
  grep -Fq "JuiceFS:juicefs-prod $CURRENT_REF fuse.juicefs" "$dir/mount.tsv" || die current_mount_identity
  [[ "$(stat -c %s "$CURRENT_ASSET")" == 34359738368 ]] || die current_asset_size
  asset_fingerprint "$CURRENT_ASSET" "$dir/asset.tsv"; status_identity "$META_BASE" juicefs-prod "$dir/status"
  grep -Eq $'block_size\t(256|256K|262144)$' "$dir/status.tsv" || die current_block_size_not_256K
  current_processes "$dir/processes.tsv"
}
verify_current() {
  snapshot_current post
  local f; for f in mount.tsv asset.tsv status.tsv processes.tsv; do cmp -s "$ROOT/inventory/current-pre/$f" "$ROOT/inventory/current-post/$f" || die "current_${f}_drift"; done
}
matrix_plan() {
  printf '%s\n' \
    $'cell\tphase\tengine\tqd\truntime\tra\tasync_dio' \
    $'A01\tA\tpsync\t1\t60\t32M\ton' $'A02\tA\tlibaio\t1\t30\t32M\ton' \
    $'A03\tA\tlibaio\t2\t30\t32M\ton' $'A04\tA\tlibaio\t4\t30\t32M\ton' \
    $'A05\tA\tlibaio\t8\t30\t32M\ton' $'A06\tA\tpsync\t1\t60\t32M\ton' \
    $'B01\tB\tpsync\t1\t60\t32M\toff' $'B02\tB\tpsync\t1\t60\t64M\toff' \
    $'B03\tB\tpsync\t1\t60\t64M\toff' $'B04\tB\tpsync\t1\t60\t32M\toff'
}

inventory_plan() {
  valid_scope
  if [[ -e "$ROOT" ]]; then
    [[ -d "$ROOT" && ! -L "$ROOT" && -d "$ROOT/scripts" && ! -L "$ROOT/scripts" ]] || die unsafe_bootstrap_root
    [[ -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 ! -name scripts -print -quit)" ]] || die bootstrap_root_not_empty
  fi
  local x; for x in ceph cmp curl fio findmnt head ip md5sum mountpoint pgrep python3 sha256sum ss stat tail timeout; do need "$x"; done
  fixed_binary; mkdir -m 0700 -p "$ROOT"/{inventory,plans,cells,mounts,closure}
  printf 'epoch\ttype\tdetail\n' >"$ROOT/incidents.tsv"; printf '#!/usr/bin/env bash\n# Actual commands; credentials redacted.\n' >"$ROOT/commands.sh"
  prepare_ceph_conf; hostname -f >"$ROOT/inventory/hostname.txt"; date -Ins >"$ROOT/inventory/time.txt"
  "$JFS" --version >"$ROOT/inventory/juicefs-version.txt" 2>&1; fio --version >"$ROOT/inventory/fio-version.txt"; md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"
  ceph_read fsid >"$ROOT/inventory/ceph-fsid.txt"; ip route get "$CEPH_ROUTE_TARGET" >"$ROOT/inventory/ceph-route.txt"
  awk '{for(i=1;i<=NF;i++)if($i=="dev"&&i<NF){print $(i+1);exit}}' "$ROOT/inventory/ceph-route.txt" >"$ROOT/inventory/nic.txt"
  [[ "$(<"$ROOT/inventory/nic.txt")" =~ ^[A-Za-z0-9_.:-]+$ ]] || die nic_missing
  snapshot_current pre; health_gate inventory
  findmnt -rn -o TARGET | grep -Fqx "$TMP_MNT" && die residual_mount || :
  pgrep -x fio >"$ROOT/inventory/foreign-fio.txt" && die foreign_fio || :
  ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)19657$' && die metrics_port_in_use || :
  assert_unformatted "$TMP_META" "$ROOT/inventory/preexisting.json" "$ROOT/inventory/preexisting.stderr"
  matrix_plan >"$ROOT/plans/matrix.tsv"; printf 'meta\t%s\nname\t%s\nmount\t%s\n' "$TMP_META" "$TMP_NAME" "$TMP_MNT" >"$ROOT/plans/assets.tsv"
  sha256sum "$EXECUTOR" "$ANALYZER" >"$ROOT/plans/runtime-scripts.sha256"; mark INVENTORY_PLAN_PASS
  printf 'T04TMP3E_INVENTORY_PLAN_PASS\troot=%s\n' "$ROOT"
}

mount_processes() {
  local log=$1 rows=$2 state=$3
  python3 - "$JFS" "$log" "$rows" "$state" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); log=sys.argv[2]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if log not in cmd: continue
        st=(p/'stat').read_text().split(); rows.append((p.name,st[3],st[21],hashlib.md5(open(p/'exe','rb').read()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit('mount process missing')
with open(sys.argv[3],'w') as f:
    f.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for r in sorted(rows,key=lambda x:int(x[0])): f.write('\t'.join(r)+'\n')
pids={r[0] for r in rows}; workers=[r for r in rows if r[1] in pids]
if len(workers)!=1: raise SystemExit('unique worker missing')
w=workers[0]
with open(sys.argv[4],'w') as f: f.write('worker_pid\t'+w[0]+'\nworker_starttime\t'+w[2]+'\nworker_exe_md5\t'+w[3]+'\n')
PY
}
processes_gone() {
  python3 - "$1" <<'PY'
import csv,sys
for row in csv.DictReader(open(sys.argv[1]),delimiter='\t'):
    try:
        if open('/proc/'+row['pid']+'/stat').read().split()[21] == row['starttime']: raise SystemExit(1)
    except OSError: pass
PY
}
mount_temp() {
  local tag=$1 ra=$2 async=$3 mode=$4 out="$ROOT/mounts/$1" log
  log="$out/mount.log"; [[ ! -e "$TMP_MNT" && ! -L "$TMP_MNT" ]] || die mount_path_exists
  mkdir -m 0700 -p "$out"; mkdir -m 0700 "$TMP_MNT"
  local -a cmd=("$JFS" mount -d --log "$log" --metrics "$METRICS_ADDR" --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 --max-readahead "$ra")
  [[ "$async" == on ]] && cmd+=(-o async_dio)
  [[ "$mode" == ro ]] && cmd+=(--read-only)
  cmd+=("$TMP_META" "$TMP_MNT")
  printf 'tag\tmax_readahead\tasync_dio\tmode\tmeta\tmount\n%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "$ra" "$async" "$mode" "$TMP_META" "$TMP_MNT" >"$out/mount-contract.tsv"
  record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"; timeout 180 env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr" || die "mount_$tag"
  local i; for i in $(seq 1 120); do mountpoint -q "$TMP_MNT" && break; sleep 1; done; mountpoint -q "$TMP_MNT" || die mount_timeout
  findmnt -rn -M "$TMP_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN >"$out/findmnt.tsv"
  grep -Fq "JuiceFS:$TMP_NAME $TMP_MNT fuse.juicefs" "$out/findmnt.tsv" || die mount_identity
  mount_processes "$log" "$out/mount-processes.tsv" "$out/mount-state.tsv"
  # CAP_ASYNC_DIO is a negotiated FUSE capability, absent from findmnt, while
  # the Go daemon rewrites/truncates argv after daemonization.  Preserve the
  # exact pre-exec input contract; fixed script SHA plus successful mount is the
  # auditable evidence.  Do not infer the capability from post-fork cmdline.
  grep -Fqx "$tag"$'\t'"$ra"$'\t'"$async"$'\t'"$mode"$'\t'"$TMP_META"$'\t'"$TMP_MNT" "$out/mount-contract.tsv" || die mount_contract_drift
  curl -fsS --connect-timeout 2 --max-time 5 "http://$METRICS_ADDR/metrics" >"$out/metrics-mounted.prom" || die metrics_missing
  grep -Fq "vol_name=\"$TMP_NAME\"" "$out/metrics-mounted.prom" || die metrics_identity
  if [[ "$mode" == ro ]]; then
    local probe="$TMP_MNT/.04tmp3e-ro-$RUN_ID-$tag" rc
    set +e; touch -- "$probe" 2>"$out/ro-probe.stderr"; rc=$?; set -e
    (( rc != 0 )) || die ro_probe_accepted; [[ ! -e "$probe" ]] || die ro_probe_residue
  fi
}
scan_mount_log() {
  local out=$1
  if grep -nEi 'ceph_assert|SIGABRT|SIGSEGV|panic|fatal|core dumped|Aborted' "$out"/mount.stdout "$out"/mount.stderr "$out"/mount.log "$out"/umount.stdout "$out"/umount.stderr 2>/dev/null; then incident FATAL_MOUNT_LOG "$out"; die fatal_mount_log; fi
}
umount_temp() {
  local tag=$1 out="$ROOT/mounts/$1"; record env "CEPH_CONF=$CEPH_CONF" "$JFS" umount "$TMP_MNT"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "$JFS" umount "$TMP_MNT" >"$out/umount.stdout" 2>"$out/umount.stderr" || die "umount_$tag"
  local i; for i in $(seq 1 180); do mountpoint -q "$TMP_MNT" || break; sleep 1; done; mountpoint -q "$TMP_MNT" && die mount_remains
  for i in $(seq 1 60); do processes_gone "$out/mount-processes.tsv" && break; sleep 1; done; processes_gone "$out/mount-processes.tsv" || die process_remains
  scan_mount_log "$out"; [[ -d "$TMP_MNT" && ! -L "$TMP_MNT" ]] || die mount_dir_missing; rmdir -- "$TMP_MNT"
  for i in $(seq 1 30); do ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)19657$' || return 0; sleep 1; done; die metrics_port_remains
}

prepare() {
  valid_scope; ack PREPARE "${3:-}"; [[ -f "$ROOT/INVENTORY_PLAN_PASS" ]] || die inventory_required
  fixed_binary; prepare_ceph_conf; health_gate prepare-pre; local out="$ROOT/cells/SEED"; mkdir -m 0700 -p "$out"
  local -a format=("$JFS" format --no-update --storage ceph --bucket ceph://juicefs-data --access-key ceph --secret-key client.juicefs --block-size 4M --compress none --trash-days 0 "$TMP_META" "$TMP_NAME")
  record env "CEPH_CONF=$CEPH_CONF" "$JFS" format --no-update --storage ceph --bucket ceph://juicefs-data --access-key REDACTED --secret-key REDACTED --block-size 4M --compress none --trash-days 0 "$TMP_META" "$TMP_NAME"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "${format[@]}" >"$out/format.stdout" 2>"$out/format.stderr" || die format
  status_identity "$TMP_META" "$TMP_NAME" "$out/status"; grep -Eq $'block_size\t(4096|4M|4194304)$' "$out/status.tsv" || die block_size_not_4M
  mount_temp SEED 32M off rw; mkdir -p "$TMP_MNT/test_dir/seqread"; local file="$TMP_MNT$ASSET_REL"
  local -a fio_cmd=(fio --name=seed --filename="$file" --rw=write --bs=16M --size=10G --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --buffer_pattern=0x5a --output="$out/fio.json" --output-format=json+)
  record "${fio_cmd[@]}"; timeout 600 "${fio_cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr" || die seed_fio
  [[ "$(stat -c %s "$file")" == 10737418240 ]] || die seed_size; asset_fingerprint "$file" "$out/asset-before.tsv"; umount_temp SEED
  mount_temp VERIFY 32M off ro; asset_fingerprint "$TMP_MNT$ASSET_REL" "$out/asset-after.tsv"; cmp -s "$out/asset-before.tsv" "$out/asset-after.tsv" || die seed_remount_drift; umount_temp VERIFY
  sleep 60; health_gate prepare-post; verify_current; mark PREPARE_PASS; printf 'T04TMP3E_PREPARE_PASS\n'
}

fuse_connection() {
  local out=$1 mm minor dir; mm=$(findmnt -rn -M "$TMP_MNT" -o MAJ:MIN 2>/dev/null || :); minor=${mm#*:}; dir="/sys/fs/fuse/connections/$minor"
  if [[ "$mm" =~ ^[0-9]+:[0-9]+$ && -d "$dir" && -r "$dir/waiting" ]]; then printf '%s\n' "$dir" >"$out"; else printf 'NA\n' >"$out"; fi
}
sample_cell() {
  local cell=$1 stop=$2 mount_state=$3 out="$ROOT/cells/$1" worker start nic epoch tmp conn
  worker=$(awk -F '\t' '$1=="worker_pid"{print $2}' "$mount_state"); start=$(awk -F '\t' '$1=="worker_starttime"{print $2}' "$mount_state"); nic=$(<"$ROOT/inventory/nic.txt")
  fuse_connection "$out/fuse-connection.txt"; conn=$(<"$out/fuse-connection.txt")
  printf 'epoch_ns\tpid\tstarttime_ticks\tutime_ticks\tstime_ticks\trss_pages\tthreads\trx_bytes\ttx_bytes\n' >"$out/client-sidecar.tsv"
  printf 'epoch_ns\tmetric\tvalue\n' >"$out/juicefs-metrics.tsv"; printf 'epoch_ns\twaiting\tmax_background\tcongestion_threshold\tmax_read\n' >"$out/fuse-sidecar.tsv"
  while [[ ! -e "$stop" ]]; do
    [[ -r "/proc/$worker/stat" && "$(awk '{print $22}' "/proc/$worker/stat")" == "$start" ]] || return 42
    epoch=$(date +%s%N)
    python3 - "$worker" "$epoch" "$nic" >>"$out/client-sidecar.tsv" <<'PY'
import pathlib,sys
pid,epoch,nic=sys.argv[1:]; st=pathlib.Path('/proc',pid,'stat').read_text().split(); status=pathlib.Path('/proc',pid,'status').read_text().splitlines()
threads=next(x.split()[1] for x in status if x.startswith('Threads:')); rx=pathlib.Path('/sys/class/net',nic,'statistics/rx_bytes').read_text().strip(); tx=pathlib.Path('/sys/class/net',nic,'statistics/tx_bytes').read_text().strip()
print(epoch,pid,st[21],st[13],st[14],st[23],threads,rx,tx,sep='\t')
PY
    tmp="$out/.metrics-$epoch.tmp"; curl -fsS --connect-timeout 2 --max-time 5 "http://$METRICS_ADDR/metrics" >"$tmp" || return 43
    awk -v e="$epoch" '$1 ~ /^(juicefs_fuse_ops_total|juicefs_fuse_read_size_bytes_(sum|count)|juicefs_fuse_ops_durations_seconds|juicefs_object_request_(durations_histogram_seconds_(sum|count)|data_bytes|errors)|juicefs_used_read_buffer_size_bytes|juicefs_process_cpu_seconds_total)(\{|$)/ {print e"\t"$1"\t"$2}' "$tmp" >>"$out/juicefs-metrics.tsv"; unlink -- "$tmp"
    if [[ "$conn" != NA && -r "$conn/waiting" ]]; then printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$(<"$conn/waiting")" "$(<"$conn/max_background")" "$(<"$conn/congestion_threshold")" "$(<"$conn/max_read")" >>"$out/fuse-sidecar.tsv"; else printf '%s\tNA\tNA\tNA\tNA\n' "$epoch" >>"$out/fuse-sidecar.tsv"; fi
    sleep 1
  done
}
validate_coverage() {
  python3 - "$1/analysis.json" "$1/client-sidecar.tsv" "$1/juicefs-metrics.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); start=d['formal_start_ns']; end=d['formal_end_ns']
for label,path in [('client',sys.argv[2]),('metrics',sys.argv[3])]:
    ep=sorted({int(x.split('\t',1)[0]) for x in open(path).read().splitlines()[1:] if x}); inside=[x for x in ep if start-2_000_000_000 <= x <= end+2_000_000_000]
    gaps=[(b-a)/1e9 for a,b in zip(inside,inside[1:])]
    if len(inside) < int((end-start)/1e9)-2 or max(gaps,default=0)>3: raise SystemExit(label+' coverage')
PY
}
run_cell() {
  local cell=$1 engine=$2 qd=$3 runtime=$4 mount_tag=$5 out="$ROOT/cells/$1" file="$TMP_MNT$ASSET_REL"
  mkdir -m 0700 -p "$out/bwlog"; [[ -f "$file" && ! -L "$file" && "$(stat -c %s "$file")" == 10737418240 ]] || die "asset_$cell"; health_gate "$cell-pre"
  local stop="$out/STOP_SAMPLER" sampler rc sampler_rc completion; [[ ! -e "$stop" ]] || unlink -- "$stop"
  sample_cell "$cell" "$stop" "$ROOT/mounts/$mount_tag/mount-state.tsv" >"$out/sampler.stdout" 2>"$out/sampler.stderr" & sampler=$!; ACTIVE_SAMPLER=$sampler; ACTIVE_STOP=$stop
  printf '%s\n' "$(date +%s%N)" >"$out/fio-registered-start-ns.txt"
  local -a cmd=(fio --name=read20m --filename="$file" --rw=read --bs=20M --size=10G --runtime="$runtime" --time_based --ioengine="$engine" --iodepth="$qd" --direct=1 --numjobs=1 --allow_file_create=0 --group_reporting --write_bw_log="$out/bwlog/$cell" --log_avg_msec=1000 --output="$out/fio.json" --output-format=json+)
  record "${cmd[@]}"; set +e; timeout "$((runtime+180))" "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; completion=$(date +%s%N); : >"$stop"; wait "$sampler"; sampler_rc=$?; set -e
  ACTIVE_SAMPLER=; ACTIVE_STOP=; printf '%s\n' "$completion" >"$out/completion-ns.txt"; printf '%s\n' "$rc" >"$out/fio.rc"; printf '%s\n' "$sampler_rc" >"$out/sampler.rc"
  (( rc == 0 && sampler_rc == 0 )) || die "cell_${cell}_rc"
  python3 "$ANALYZER" cell "$out" --expected-file "$file" --expected-engine "$engine" --expected-qd "$qd" --expected-runtime "$runtime" >"$out/analysis.json"
  validate_coverage "$out"; health_gate "$cell-post"
}
libaio_canary() {
  local out="$ROOT/cells/CANARY" file="$TMP_MNT$ASSET_REL" rc; mkdir -m 0700 -p "$out"
  local -a cmd=(fio --name=libaio-canary --filename="$file" --rw=read --bs=20M --size=1G --runtime=5 --time_based --ioengine=libaio --iodepth=1 --direct=1 --numjobs=1 --allow_file_create=0 --output="$out/fio.json" --output-format=json+)
  record "${cmd[@]}"; set +e; timeout 60 "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; set -e; printf '%s\n' "$rc" >"$out/fio.rc"; (( rc == 0 )) || die libaio_canary_rc
  python3 - "$out/fio.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))['jobs'][0]
if j.get('error') != 0 or (j.get('read') or {}).get('io_bytes',0) <= 1024**3: raise SystemExit('libaio canary invalid')
PY
  mark LIBAIO_CANARY_PASS
}
phase_a() {
  valid_scope; ack PHASE_A "${3:-}"; [[ -f "$ROOT/PREPARE_PASS" ]] || die prepare_required; fixed_binary; prepare_ceph_conf
  mount_temp PHASE-A 32M on ro; libaio_canary
  run_cell A01 psync 1 60 PHASE-A; run_cell A02 libaio 1 30 PHASE-A; run_cell A03 libaio 2 30 PHASE-A
  run_cell A04 libaio 4 30 PHASE-A; run_cell A05 libaio 8 30 PHASE-A; run_cell A06 psync 1 60 PHASE-A
  python3 "$ANALYZER" phase-a "$ROOT/cells" >"$ROOT/phase-a-summary.json"
  python3 - "$ROOT/phase-a-summary.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if not d.get('evidence_valid'): raise SystemExit('Phase A evidence invalid')
PY
  umount_temp PHASE-A; verify_current; mark PHASE_A_PASS; printf 'T04TMP3E_PHASE_A_PASS\n'
}
phase_b() {
  valid_scope; ack PHASE_B "${3:-}"; [[ -f "$ROOT/PHASE_A_PASS" ]] || die phase_a_required; fixed_binary; prepare_ceph_conf
  local cell phase engine qd runtime ra async
  while IFS=$'\t' read -r cell phase engine qd runtime ra async; do
    [[ "$cell" == cell || "$phase" != B ]] && continue
    mount_temp "$cell" "$ra" off ro; run_cell "$cell" "$engine" "$qd" "$runtime" "$cell"; umount_temp "$cell"
  done <"$ROOT/plans/matrix.tsv"
  python3 "$ANALYZER" phase-b "$ROOT/cells" >"$ROOT/phase-b-summary.json"
  verify_current; mark PHASE_B_PASS; printf 'T04TMP3E_PHASE_B_PASS\n'
}

cleanup_plan() {
  valid_scope; [[ -f "$ROOT/PREPARE_PASS" ]] || die prepare_required; prepare_ceph_conf
  mountpoint -q "$TMP_MNT" && die temp_mount_active
  status_identity "$TMP_META" "$TMP_NAME" "$ROOT/closure/pre-destroy"
  local uuid current_uuid; uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$ROOT/closure/pre-destroy.tsv"); current_uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$ROOT/inventory/current-pre/status.tsv")
  [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ && "$uuid" != "$current_uuid" ]] || die unsafe_destroy_uuid
  printf 'meta\tname\tuuid\n%s\t%s\t%s\n' "$TMP_META" "$TMP_NAME" "$uuid" >"$ROOT/closure/destroy-plan.tsv"
  verify_current; cat "$ROOT/closure/destroy-plan.tsv"; printf 'T04TMP3E_CLEANUP_PLAN_PASS\n'
}
cleanup() {
  valid_scope; ack CLEANUP "${3:-}"; [[ -f "$ROOT/closure/destroy-plan.tsv" ]] || die cleanup_plan_required; prepare_ceph_conf
  mountpoint -q "$TMP_MNT" && die temp_mount_active
  local meta name uuid now_uuid current_uuid; IFS=$'\t' read -r meta name uuid < <(sed -n '2p' "$ROOT/closure/destroy-plan.tsv")
  [[ "$meta" == "$TMP_META" && "$name" == "$TMP_NAME" && "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || die invalid_destroy_plan
  status_identity "$TMP_META" "$TMP_NAME" "$ROOT/closure/verify-destroy"; now_uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$ROOT/closure/verify-destroy.tsv"); current_uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$ROOT/inventory/current-pre/status.tsv")
  [[ "$now_uuid" == "$uuid" && "$uuid" != "$current_uuid" ]] || die destroy_identity_drift
  record env "CEPH_CONF=$CEPH_CONF" "$JFS" destroy "$TMP_META" "$uuid" --yes
  timeout 1800 env CEPH_CONF="$CEPH_CONF" "$JFS" destroy "$TMP_META" "$uuid" --yes >"$ROOT/closure/destroy.stdout" 2>"$ROOT/closure/destroy.stderr" || die destroy
  assert_unformatted "$TMP_META" "$ROOT/closure/post-destroy.json" "$ROOT/closure/post-destroy.stderr"
  verify_current; health_gate cleanup-post; mark closure/CLEANUP_PASS; printf 'T04TMP3E_CLEANUP_PASS\n'
}
self_test() {
  [[ "$(matrix_plan | wc -l)" == 11 ]]; grep -Fq $'A05\tA\tlibaio\t8\t30\t32M\ton' <(matrix_plan); grep -Fq $'B02\tB\tpsync\t1\t60\t64M\toff' <(matrix_plan)
  RUN_ID=20260904-000000; valid_scope; [[ "$ROOT" == /tmp/production/opencode-04tmp3e-20260904-000000 ]]; [[ "$TMP_META" == "${META_BASE%/*}/20260904-000000-b4" ]]
  printf 'T04TMP3E_EXECUTOR_SELFTEST_PASS\n'
}
gate0() {
  bash -n "$EXECUTOR"; python3 -m py_compile "$ANALYZER"; "$EXECUTOR" --self-test; python3 "$ANALYZER" self-test
  if grep -nE '(^|[[:space:]])sudo([[:space:]]|$)|reboot|shutdown|poweroff|halt|systemctl|drop_caches|ceph[[:space:]]+(config|osd[[:space:]]+(set|unset|pool)|tell.*compact)|rm[[:space:]]+-[rRfF]|umount[[:space:]]+-[lf]' "$EXECUTOR" | grep -v 'if grep -nE'; then die prohibited_token; fi
  grep -Fq '"$JFS" destroy "$TMP_META" "$uuid" --yes' "$EXECUTOR" || die exact_destroy_missing
  printf 'T04TMP3E_GATE0_PASS\n'
}
trap 'if [[ -n "$ACTIVE_STOP" ]]; then : >"$ACTIVE_STOP"; fi; if [[ -n "$ACTIVE_SAMPLER" ]]; then wait "$ACTIVE_SAMPLER" 2>/dev/null || :; fi' EXIT
case ${1:-} in
  inventory-plan) inventory_plan;; prepare) prepare "$@";; phase-a) phase_a "$@";; phase-b) phase_b "$@";;
  cleanup-plan) cleanup_plan;; cleanup) cleanup "$@";; gate0) gate0;; --self-test) self_test;; *) usage;;
esac
