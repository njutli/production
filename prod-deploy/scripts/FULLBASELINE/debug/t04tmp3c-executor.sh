#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 04-tmp3c: minimal read-only causal matrix on two private temporary volumes.
# It intentionally contains no privileged or cluster-control path.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXECUTOR=$(readlink -f -- "${BASH_SOURCE[0]}")
ANALYZER="$SELF_DIR/t04tmp3c-analyze.py"
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
NAME=juicefs-prod
REF=/mnt/juicefs
ASSET_REL=/test_dir/seqread/seqread.0.0
CURRENT_ASSET="$REF$ASSET_REL"
REMOTE_PARENT=/tmp/production
TASK_ROOT=/mnt/c/SunRise/test/04-tmp3c
METRICS_ADDR=127.0.0.1:19657
CEPH_ROUTE_TARGET=10.3.1.6
RUN_ID=${2:-}
ROOT="$REMOTE_PARENT/opencode-04tmp3c-$RUN_ID"
CEPH_CONF=
ACTIVE_SAMPLER_PID=
ACTIVE_SAMPLER_STOP=

die() { printf 'T04TMP3C_EXECUTOR_FAIL\t%s\n' "$*" >&2; exit 42; }
usage() {
  printf '%s\n' \
    'usage: t04tmp3c-executor.sh inventory-plan RUN_ID' \
    '       t04tmp3c-executor.sh create-layout RUN_ID I_ACK_04TMP3C_CREATE_LAYOUT_RUN_ID' \
    '       t04tmp3c-executor.sh read6 RUN_ID I_ACK_04TMP3C_READ6_RUN_ID' \
    '       t04tmp3c-executor.sh cleanup-plan RUN_ID' \
    '       t04tmp3c-executor.sh cleanup RUN_ID I_ACK_04TMP3C_CLEANUP_RUN_ID' \
    '       t04tmp3c-executor.sh --self-test' >&2
  exit 2
}
valid_scope() {
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ "$ROOT" == "$REMOTE_PARENT/opencode-04tmp3c-$RUN_ID" && "$ROOT" != / && "$ROOT" != *..* ]] || die unsafe_root
  [[ ! -L "$ROOT" ]] || die root_symlink
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing_tool_$1"; }
fixed_binary() {
  [[ -x "$JFS" && ! -L "$JFS" ]] || die binary_missing
  [[ "$(md5sum "$JFS" | awk '{print $1}')" == "$JFS_MD5" ]] || die binary_md5_drift
}
record() {
  [[ -f "$ROOT/commands.sh" ]] || : >"$ROOT/commands.sh"
  printf '#' >>"$ROOT/commands.sh"
  printf ' %q' "$@" >>"$ROOT/commands.sh"
  printf '\n' >>"$ROOT/commands.sh"
}
incident() { printf '%s\t%s\t%s\n' "$(date -Ins)" "$1" "$2" >>"$ROOT/incidents.tsv"; }
ack() {
  local stage=$1 supplied=$2
  [[ "$supplied" == "I_ACK_04TMP3C_${stage}_$RUN_ID" ]] || die "invalid_ACK_$stage"
}
matrix() {
  printf '%s\n' \
    $'cell\tarm\tblock_size\treadahead' \
    $'C01\tb256\t256K\t8M' \
    $'C02\tb4\t4M\t8M' \
    $'C03\tb4\t4M\t32M' \
    $'C04\tb4\t4M\t32M' \
    $'C05\tb4\t4M\t8M' \
    $'C06\tb256\t256K\t8M'
}
temp_meta() { printf '%s/%s-%s\n' "${META%/*}" "$RUN_ID" "$1"; }
temp_name() { printf '%s-%s\n' "$RUN_ID" "$1"; }
temp_mnt() { printf '/tmp/jfs-04tmp3c-%s-%s\n' "$RUN_ID" "$1"; }
cell_out() { printf '%s/cells/%s\n' "$ROOT" "$1"; }
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
  grep -Fqx $'\tms_async_op_threads = 8' "$CEPH_CONF" || die ceph_conf_msgr8_missing
  export CEPH_CONF
}
ceph_read() { timeout 30 env CEPH_CONF="$CEPH_CONF" ceph "$@"; }
health_gate() {
  local tag=$1 out
  out="$ROOT/health-$tag"
  mkdir -m 0700 -p "$out"
  ceph_read -s --format json >"$out/status.json"
  ceph_read osd stat --format json >"$out/osd-stat.json"
  ceph_read pg dump pgs_brief >"$out/pgs.txt"
  python3 - "$out/status.json" "$out/osd-stat.json" "$out/pgs.txt" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2]))
if (s.get('health') or {}).get('status') != 'HEALTH_OK': raise SystemExit('Ceph health is not OK')
if len({o.get(k) for k in ('num_osds','num_up_osds','num_in_osds')}) != 1: raise SystemExit('OSDs not all up/in')
states=[]
for line in open(sys.argv[3]):
    f=line.split()
    if f and f[0][:1].isdigit() and len(f)>1: states.append(f[1])
if not states or any(x != 'active+clean' for x in states): raise SystemExit('PGs not quiet active+clean')
PY
}
current_mount_processes() {
  python3 - "$JFS" "$REF" "$META" "$1" <<'PY'
import hashlib,os,pathlib,sys
expected_exe=os.path.realpath(sys.argv[1]); mnt,meta,out=sys.argv[2:]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != expected_exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if ' mount ' not in cmd or mnt not in cmd or meta not in cmd: continue
        st=(p/'stat').read_text().split(); exe=os.path.realpath(p/'exe')
        md5=hashlib.md5(open(p/'exe','rb').read()).hexdigest()
        rows.append((int(p.name),int(st[3]),int(st[21]),exe,md5,cmd))
    except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit('current mount process missing')
with open(out,'w') as f:
    f.write('pid\tppid\tstarttime\texe\texe_md5\tcmdline\n')
    for r in sorted(rows): f.write('\t'.join(map(str,r))+'\n')
PY
}
asset_fingerprint() {
  local file=$1 out=$2
  [[ -f "$file" && ! -L "$file" ]] || die asset_missing
  printf 'bytes\t%s\ninode\t%s\nmtime\t%s\nhead_sha256\t%s\ntail_sha256\t%s\n' \
    "$(stat -c %s "$file")" "$(stat -c %i "$file")" "$(stat -c %Y "$file")" \
    "$(head -c 1048576 "$file" | sha256sum | awk '{print $1}')" \
    "$(tail -c 1048576 "$file" | sha256sum | awk '{print $1}')" >"$out"
}
status_identity() {
  local meta=$1 expected=$2 out=$3
  timeout 30 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$out.json"
  python3 - "$out.json" "$expected" >"$out.tsv" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('Setting') or {}
name=s.get('Name'); uuid=s.get('UUID'); block=s.get('BlockSize')
if name != sys.argv[2] or not isinstance(uuid,str) or not uuid: raise SystemExit('volume identity mismatch')
print('name\t'+name); print('uuid\t'+uuid); print('block_size\t'+str(block))
PY
}
snapshot_current() {
  local tag=$1 dir
  dir="$ROOT/inventory/current-$tag"
  mkdir -m 0700 -p "$dir"
  mountpoint -q "$REF" || die current_mount_missing
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$dir/mount.tsv"
  grep -Fq "JuiceFS:$NAME $REF fuse.juicefs" "$dir/mount.tsv" || die current_mount_identity
  [[ "$(stat -c %s "$CURRENT_ASSET")" == 34359738368 ]] || die current_asset_size
  asset_fingerprint "$CURRENT_ASSET" "$dir/asset.tsv"
  status_identity "$META" "$NAME" "$dir/status"
  current_mount_processes "$dir/processes.tsv"
}
verify_current_unchanged() {
  snapshot_current post
  for f in mount.tsv asset.tsv status.tsv processes.tsv; do
    cmp -s "$ROOT/inventory/current-pre/$f" "$ROOT/inventory/current-post/$f" || die "current_${f}_drift"
  done
}
inventory_plan() {
  valid_scope; [[ ! -e "$ROOT" ]] || die root_exists
  for x in ceph curl fio findmnt ip md5sum mountpoint pgrep python3 sha256sum ss stat timeout; do need "$x"; done
  fixed_binary
  mkdir -m 0700 -p "$ROOT"/{inventory,plans,cells,closure}
  printf 'epoch\ttype\tdetail\n' >"$ROOT/incidents.tsv"
  printf '#!/usr/bin/env bash\n# Commands actually executed; credentials are redacted.\n' >"$ROOT/commands.sh"
  prepare_ceph_conf
  hostname -f >"$ROOT/inventory/hostname.txt"; date -Ins >"$ROOT/inventory/time.txt"
  "$JFS" --version >"$ROOT/inventory/juicefs-version.txt" 2>&1; fio --version >"$ROOT/inventory/fio-version.txt"
  md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"
  ceph_read fsid >"$ROOT/inventory/ceph-fsid.txt"
  ip route get "$CEPH_ROUTE_TARGET" >"$ROOT/inventory/ceph-route.txt"
  awk '{for(i=1;i<=NF;i++)if($i=="dev"&&i<NF){print $(i+1);exit}}' "$ROOT/inventory/ceph-route.txt" >"$ROOT/inventory/nic.txt"
  [[ "$(<"$ROOT/inventory/nic.txt")" =~ ^[A-Za-z0-9_.:-]+$ ]] || die ceph_nic_missing
  snapshot_current pre; health_gate inventory
  if findmnt -rn -o TARGET | awk '$1 ~ /^\/tmp\/jfs-04tmp3c-/ {found=1} END{exit found?0:1}'; then die residual_tmp3c_mount; fi
  ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)19657$' && die metrics_port_in_use || :
  if pgrep -x fio >"$ROOT/inventory/foreign-fio.txt"; then die foreign_fio_exists; fi
  matrix >"$ROOT/plans/matrix.tsv"
  printf 'arm\tmeta\tname\tblock_size\n' >"$ROOT/plans/format-plan.tsv"
  local arm block
  for arm in b256 b4; do
    [[ "$arm" == b256 ]] && block=256K || block=4M
    printf '%s\t%s\t%s\t%s\n' "$arm" "$(temp_meta "$arm")" "$(temp_name "$arm")" "$block" >>"$ROOT/plans/format-plan.tsv"
  done
  sha256sum "$EXECUTOR" "$ANALYZER" >"$ROOT/plans/runtime-scripts.sha256"
  printf 'T04TMP3C_INVENTORY_PLAN_PASS\troot=%s\n' "$ROOT"
}
temp_identity() {
  local arm=$1 out=$2 expected allowed
  [[ "$arm" == b256 ]] && allowed=' 256 256K 262144 ' || allowed=' 4096 4M 4194304 '
  status_identity "$(temp_meta "$arm")" "$(temp_name "$arm")" "$out/status"
  expected=$(awk -F '\t' '$1=="block_size"{print $2}' "$out/status.tsv")
  [[ "$allowed" == *" $expected "* ]] || die "temp_block_size_$arm"
  cp -- "$out/status.tsv" "$out/identity.tsv"
}
format_one() {
  local arm=$1 block out; out=$(cell_out "CREATE-$arm"); [[ "$arm" == b256 ]] && block=256K || block=4M
  mkdir -m 0700 -p "$out"
  if timeout 20 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$(temp_meta "$arm")" >"$out/preexisting.json" 2>"$out/preexisting.stderr"; then die "temp_volume_preexists_$arm"; fi
  local -a cmd=("$JFS" format --no-update --storage ceph --bucket ceph://juicefs-data --access-key ceph --secret-key client.juicefs --block-size "$block" --compress none --trash-days 0 "$(temp_meta "$arm")" "$(temp_name "$arm")")
  record env "CEPH_CONF=$CEPH_CONF" "$JFS" format --no-update --storage ceph --bucket ceph://juicefs-data --access-key REDACTED --secret-key REDACTED --block-size "$block" --compress none --trash-days 0 "$(temp_meta "$arm")" "$(temp_name "$arm")"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$out/format.stdout" 2>"$out/format.stderr" || die "format_$arm"
  temp_identity "$arm" "$out"
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
mount_one() {
  local arm=$1 cell=$2 mode=$3 ra=$4 out mnt log expected
  out=$(cell_out "$cell"); mnt=$(temp_mnt "$arm"); log="$out/mount.log"; expected=$(temp_name "$arm")
  [[ ! -e "$mnt" && ! -L "$mnt" ]] || die mount_path_exists
  ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)19657$' && die metrics_port_in_use || :
  mkdir -m 0700 -p "$out/bwlog"; mkdir -m 0700 "$mnt"
  local -a cmd=("$JFS" mount -d --log "$log" --metrics "$METRICS_ADDR" --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 --max-readahead "$ra")
  [[ "$mode" == ro ]] && cmd+=(--read-only)
  cmd+=("$(temp_meta "$arm")" "$mnt")
  record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr" || die mount_failed
  for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout
  printf '%s\n' "$mnt" >"$out/mount-path.txt"
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/findmnt.tsv"
  grep -Fq "JuiceFS:$expected $mnt fuse.juicefs" "$out/findmnt.tsv" || die mount_identity
  python3 - "$JFS" "$log" "$out/mount-processes.tsv" "$out/mount-state.tsv" <<'PY'
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
if not rows: raise SystemExit('mount processes missing')
with open(sys.argv[3],'w') as f:
    f.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for row in sorted(rows,key=lambda x:int(x[0])): f.write('\t'.join(row)+'\n')
pids={r[0] for r in rows}; workers=[r for r in rows if r[1] in pids]
if len(workers) != 1: raise SystemExit('unique worker missing')
w=workers[0]
with open(sys.argv[4],'w') as f: f.write('worker_pid\t'+w[0]+'\nworker_starttime\t'+w[2]+'\nworker_exe_md5\t'+w[3]+'\n')
PY
  curl -fsS --connect-timeout 2 --max-time 5 "http://$METRICS_ADDR/metrics" >"$out/metrics-mounted.prom" || die metrics_endpoint
  grep -Fq "vol_name=\"$expected\"" "$out/metrics-mounted.prom" || die metrics_volume_identity
  if [[ "$mode" == ro ]]; then
    local probe="$mnt/.04tmp3c-ro-$RUN_ID-$cell" rc
    set +e; touch -- "$probe" 2>"$out/ro-probe.stderr"; rc=$?; set -e
    (( rc != 0 )) || die ro_probe_accepted
    grep -Eq 'EROFS|Read-only file system' "$out/ro-probe.stderr" || die ro_probe_not_EROFS
    [[ ! -e "$probe" ]] || die ro_probe_residue
  fi
}
scan_logs() {
  local out=$1
  if grep -nEi 'ceph_assert|SIGABRT|SIGSEGV|panic|fatal|core dumped|Aborted' "$out"/mount.stdout "$out"/mount.stderr "$out"/mount.log "$out"/umount.stdout "$out"/umount.stderr 2>/dev/null; then
    incident FATAL_LOG "$out"; die fatal_log
  fi
}
graceful_umount() {
  local cell=$1 out mnt; out=$(cell_out "$cell"); mnt=$(<"$out/mount-path.txt")
  record env "CEPH_CONF=$CEPH_CONF" "$JFS" umount "$mnt"
  timeout 180 env CEPH_CONF="$CEPH_CONF" "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr" || die graceful_umount
  for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && die mount_remains
  for _ in $(seq 1 60); do processes_gone "$out/mount-processes.tsv" && break; sleep 1; done
  processes_gone "$out/mount-processes.tsv" || die process_remains
  scan_logs "$out"
  [[ -d "$mnt" && ! -L "$mnt" ]] || die mount_dir_missing
  rmdir "$mnt"
  for _ in $(seq 1 30); do
    ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)19657$' || return 0
    sleep 1
  done
  die metrics_port_remains
}
seed_one() {
  local arm=$1 cell="SEED-$1" out mnt file verify verify_out
  out=$(cell_out "$cell"); mount_one "$arm" "$cell" rw 8M; mnt=$(temp_mnt "$arm"); file="$mnt$ASSET_REL"
  mkdir -p "$(dirname -- "$file")"
  local -a cmd=(fio --name=seed --filename="$file" --rw=write --bs=16M --size=10G --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --buffer_pattern=0x5a --output="$out/fio.json" --output-format=json+)
  record "${cmd[@]}"; timeout 600 "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr" || die "seed_$arm"
  python3 - "$out/fio.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))['jobs'][0]
if j.get('error') != 0 or (j.get('write') or {}).get('io_bytes') != 10*1024**3: raise SystemExit('seed fio invalid')
PY
  [[ "$(stat -c %s "$file")" == 10737418240 ]] || die seed_size
  asset_fingerprint "$file" "$out/asset-before.tsv"
  graceful_umount "$cell"
  verify="VERIFY-$arm"; verify_out=$(cell_out "$verify")
  mount_one "$arm" "$verify" ro 8M
  asset_fingerprint "$(temp_mnt "$arm")$ASSET_REL" "$verify_out/asset-after.tsv"
  cmp -s "$out/asset-before.tsv" "$verify_out/asset-after.tsv" || die "seed_remount_fingerprint_$arm"
  graceful_umount "$verify"
}
create_layout() {
  valid_scope; ack CREATE_LAYOUT "${3:-}"; [[ -f "$ROOT/plans/matrix.tsv" ]] || die inventory_required
  fixed_binary; prepare_ceph_conf; health_gate create-pre
  format_one b256; format_one b4; seed_one b256; seed_one b4
  health_gate create-post; verify_current_unchanged
  printf '%s\n' "$(date -Ins)" >"$ROOT/CREATE_LAYOUT_PASS"
  printf 'T04TMP3C_CREATE_LAYOUT_PASS\n'
}
sample_cell() {
  local cell=$1 stop=$2 out worker start nic epoch tmp
  out=$(cell_out "$cell"); worker=$(awk -F '\t' '$1=="worker_pid"{print $2}' "$out/mount-state.tsv"); start=$(awk -F '\t' '$1=="worker_starttime"{print $2}' "$out/mount-state.tsv"); nic=$(<"$ROOT/inventory/nic.txt")
  printf 'epoch_ns\tpid\tstarttime_ticks\tutime_ticks\tstime_ticks\trss_pages\tthreads\trx_bytes\ttx_bytes\n' >"$out/client-sidecar.tsv"
  printf 'epoch_ns\tmetric\tvalue\n' >"$out/juicefs-metrics.tsv"
  while [[ ! -e "$stop" ]]; do
    [[ -r "/proc/$worker/stat" && "$(awk '{print $22}' "/proc/$worker/stat")" == "$start" ]] || return 42
    epoch=$(date +%s%N)
    python3 - "$worker" "$epoch" "$nic" >>"$out/client-sidecar.tsv" <<'PY'
import pathlib,sys
pid,epoch,nic=sys.argv[1:]
st=pathlib.Path('/proc',pid,'stat').read_text().split(); status=pathlib.Path('/proc',pid,'status').read_text().splitlines()
threads=next(x.split()[1] for x in status if x.startswith('Threads:'))
rx=pathlib.Path('/sys/class/net',nic,'statistics/rx_bytes').read_text().strip(); tx=pathlib.Path('/sys/class/net',nic,'statistics/tx_bytes').read_text().strip()
print(epoch,pid,st[21],st[13],st[14],st[23],threads,rx,tx,sep='\t')
PY
    tmp="$out/.metrics-$epoch.tmp"
    curl -fsS --connect-timeout 2 --max-time 5 "http://$METRICS_ADDR/metrics" >"$tmp" || return 43
    awk -v e="$epoch" '$1 ~ /^(juicefs_fuse_ops_total|juicefs_fuse_(read|written)_size_bytes_(sum|count)|juicefs_object_request_(durations_histogram_seconds_(sum|count)|data_bytes|errors)|juicefs_process_cpu_seconds_total)(\{|$)/ {print e"\t"$1"\t"$2}' "$tmp" >>"$out/juicefs-metrics.tsv"
    rm -f -- "$tmp"; sleep 1
  done
}
validate_sidecar_coverage() {
  python3 - "$1/analysis.json" "$1/client-sidecar.tsv" "$1/juicefs-metrics.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); start=d['actual_start_ns']+10_000_000_000; end=d['actual_start_ns']+50_000_000_000
for label,path in [('client',sys.argv[2]),('juicefs',sys.argv[3])]:
    epochs=sorted({int(x.split('\t',1)[0]) for x in open(path).read().splitlines()[1:] if x})
    inside=[x for x in epochs if start-2_000_000_000 <= x <= end+2_000_000_000]
    gaps=[(b-a)/1e9 for a,b in zip(inside,inside[1:])]
    if len(inside)<38 or not inside or inside[0]>start+2_000_000_000 or inside[-1]<end-2_000_000_000 or max(gaps,default=0)>3: raise SystemExit(label+' coverage')
PY
}
read_cell() {
  local arm=$1 cell=$2 ra=$3 out mnt file stop sampler rc sampler_rc completion
  out=$(cell_out "$cell"); health_gate "$cell-pre"; mount_one "$arm" "$cell" ro "$ra"; mnt=$(temp_mnt "$arm"); file="$mnt$ASSET_REL"
  [[ -f "$file" && ! -L "$file" && "$(stat -c %s "$file")" == 10737418240 ]] || die cell_asset
  stop="$out/STOP_SAMPLER"; rm -f -- "$stop"; sample_cell "$cell" "$stop" >"$out/sampler.stdout" 2>"$out/sampler.stderr" & sampler=$!; ACTIVE_SAMPLER_PID=$sampler; ACTIVE_SAMPLER_STOP=$stop
  printf '%s\n' "$(date +%s%N)" >"$out/fio-registered-start-ns.txt"
  local -a cmd=(fio --name=read20m --filename="$file" --rw=read --bs=20M --size=10G --runtime=60 --time_based --ioengine=psync --iodepth=1 --direct=1 --numjobs=1 --allow_file_create=0 --group_reporting --write_bw_log="$out/bwlog/$cell" --log_avg_msec=1000 --output="$out/fio.json" --output-format=json+)
  record "${cmd[@]}"; set +e; timeout 240 "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; completion=$(date +%s%N); : >"$stop"; wait "$sampler"; sampler_rc=$?; set -e
  ACTIVE_SAMPLER_PID=; ACTIVE_SAMPLER_STOP=
  printf '%s\n' "$completion" >"$out/completion-ns.txt"; printf '%s\n' "$rc" >"$out/fio.rc"; printf '%s\n' "$sampler_rc" >"$out/sampler.rc"
  (( rc == 0 )) || die fio_failed; (( sampler_rc == 0 )) || die sampler_failed
  python3 "$ANALYZER" cell "$out" --expected-file "$file" >"$out/analysis.json"
  validate_sidecar_coverage "$out"
  graceful_umount "$cell"; health_gate "$cell-post"
}
read6() {
  valid_scope; ack READ6 "${3:-}"; [[ -f "$ROOT/CREATE_LAYOUT_PASS" ]] || die create_required
  fixed_binary; prepare_ceph_conf
  local cell arm block ra
  while IFS=$'\t' read -r cell arm block ra; do [[ "$cell" == cell ]] && continue; read_cell "$arm" "$cell" "$ra"; done <"$ROOT/plans/matrix.tsv"
  verify_current_unchanged; printf '%s\n' "$(date -Ins)" >"$ROOT/READ6_PASS"; printf 'T04TMP3C_READ6_PASS\n'
}
cleanup_plan() {
  valid_scope; [[ -f "$ROOT/CREATE_LAYOUT_PASS" ]] || die create_required; prepare_ceph_conf
  mkdir -m 0700 -p "$ROOT/closure"; printf 'arm\tmeta\tname\tuuid\n' >"$ROOT/closure/destroy-plan.tsv"
  local arm out uuid
  for arm in b256 b4; do
    out="$ROOT/closure/status-$arm"; status_identity "$(temp_meta "$arm")" "$(temp_name "$arm")" "$out"
    uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$out.tsv"); [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || die temp_uuid_invalid
    printf '%s\t%s\t%s\t%s\n' "$arm" "$(temp_meta "$arm")" "$(temp_name "$arm")" "$uuid" >>"$ROOT/closure/destroy-plan.tsv"
  done
  verify_current_unchanged; cat "$ROOT/closure/destroy-plan.tsv"; printf 'T04TMP3C_CLEANUP_PLAN_PASS\n'
}
cleanup() {
  valid_scope; ack CLEANUP "${3:-}"; [[ -f "$ROOT/closure/destroy-plan.tsv" ]] || die cleanup_plan_required; prepare_ceph_conf
  if findmnt -rn -o TARGET | awk -v r="$RUN_ID" '$1 ~ ("^/tmp/jfs-04tmp3c-" r "-") {found=1} END{exit found?0:1}'; then die temp_mount_remains; fi
  local arm meta name uuid now_uuid
  while IFS=$'\t' read -r arm meta name uuid; do
    [[ "$arm" == arm ]] && continue
    [[ "$meta" == "$(temp_meta "$arm")" && "$name" == "$(temp_name "$arm")" && "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || die cleanup_row_invalid
    status_identity "$meta" "$name" "$ROOT/closure/pre-destroy-$arm"
    now_uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$ROOT/closure/pre-destroy-$arm.tsv"); [[ "$now_uuid" == "$uuid" ]] || die cleanup_uuid_drift
    [[ "$uuid" != "$(awk -F '\t' '$1=="uuid"{print $2}' "$ROOT/inventory/current-pre/status.tsv")" ]] || die cleanup_current_uuid
    local -a cmd=("$JFS" destroy "$meta" "$uuid" --yes); record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"
    timeout 1800 env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$ROOT/closure/destroy-$arm.stdout" 2>"$ROOT/closure/destroy-$arm.stderr" || die "destroy_$arm"
    if timeout 20 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$meta" >"$ROOT/closure/post-destroy-$arm.json" 2>"$ROOT/closure/post-destroy-$arm.stderr"; then die "destroy_status_still_exists_$arm"; fi
  done <"$ROOT/closure/destroy-plan.tsv"
  verify_current_unchanged; health_gate cleanup-post; printf '%s\n' "$(date -Ins)" >"$ROOT/closure/CLEANUP_PASS"; printf 'T04TMP3C_CLEANUP_PASS\n'
}
self_test() {
  [[ "$(matrix | wc -l)" == 7 ]]
  grep -Fq $'C03\tb4\t4M\t32M' <(matrix); grep -Fq $'C06\tb256\t256K\t8M' <(matrix)
  RUN_ID=20260904-000000; ROOT="$REMOTE_PARENT/opencode-04tmp3c-$RUN_ID"
  [[ "$(temp_meta b4)" == "${META%/*}/20260904-000000-b4" ]]
  [[ "$(temp_mnt b256)" == /tmp/jfs-04tmp3c-20260904-000000-b256 ]]
  printf 'T04TMP3C_EXECUTOR_SELFTEST_PASS\n'
}
trap 'if [[ -n "$ACTIVE_SAMPLER_STOP" ]]; then : >"$ACTIVE_SAMPLER_STOP"; fi; if [[ -n "$ACTIVE_SAMPLER_PID" ]]; then wait "$ACTIVE_SAMPLER_PID" 2>/dev/null || :; fi' EXIT
case ${1:-} in
  inventory-plan) inventory_plan;;
  create-layout) create_layout "$@";;
  read6) read6 "$@";;
  cleanup-plan) cleanup_plan;;
  cleanup) cleanup "$@";;
  --self-test) self_test;;
  *) usage;;
esac
