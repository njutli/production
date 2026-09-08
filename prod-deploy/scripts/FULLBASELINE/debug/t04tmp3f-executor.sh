#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXECUTOR=$(readlink -f -- "${BASH_SOURCE[0]}")
ANALYZER="$SELF_DIR/t04tmp3f-analyze.py"
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REF=/mnt/juicefs
ASSET_REL=/test_dir/seqread/seqread.0.0
ASSET="$REF$ASSET_REL"
REMOTE_PARENT=/tmp/production
PERSIST_PARENT=/mnt/c/SunRise/test/04-tmp3f
CEPH_ROUTE_TARGET=10.3.1.6
RUN_ID=${2:-}
ROOT="$REMOTE_PARENT/opencode-04tmp3f-$RUN_ID"
CEPH_CONF="$ROOT/inventory/ceph-msgr8.conf"
ACTIVE_MOUNT=
ACTIVE_MOUNT_OUT=
ACTIVE_SAMPLER=
ACTIVE_STOP=

die() { printf 'T04TMP3F_FAIL\t%s\n' "$*" >&2; exit 42; }
usage() {
  printf '%s\n' \
    'usage: t04tmp3f-executor.sh inventory-plan RUN_ID' \
    '       t04tmp3f-executor.sh run-r RUN_ID I_ACK_04TMP3F_RUN_R_RUN_ID' \
    '       t04tmp3f-executor.sh bundle RUN_ID' \
    '       t04tmp3f-executor.sh --print-matrix' \
    '       t04tmp3f-executor.sh --self-test' >&2
  exit 2
}
valid_scope() {
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ "$ROOT" == "$REMOTE_PARENT/opencode-04tmp3f-$RUN_ID" && "$ROOT" != / && "$ROOT" != *..* ]] || die unsafe_root
  [[ ! -L "$ROOT" ]] || die root_symlink
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing_tool_$1"; }
record() {
  printf '#' >>"$ROOT/commands.sh"
  printf ' %q' "$@" >>"$ROOT/commands.sh"
  printf '\n' >>"$ROOT/commands.sh"
}
state() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tGPT_LUNA\n' \
    "$(date -Ins)" "$RUN_ID" "$1" "$2" "$3" "$4" "$5" "$6" "$PERSIST_PARENT/$RUN_ID" >>"$ROOT/run-state.tsv"
}
incident() { printf '%s\t%s\t%s\n' "$(date -Ins)" "$1" "$2" >>"$ROOT/incidents.tsv"; }
fixed_binary() {
  [[ -x "$JFS" && ! -L "$JFS" ]] || die binary_missing
  [[ "$(md5sum "$JFS" | awk '{print $1}')" == "$JFS_MD5" ]] || die binary_md5_drift
}
prepare_ceph_conf() {
  CEPH_CONF="$ROOT/inventory/ceph-msgr8.conf"
  if [[ ! -f "$CEPH_CONF" ]]; then
    [[ -r /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_missing
    cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
    printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
    sha256sum "$CEPH_CONF" >"$ROOT/inventory/ceph-msgr8.conf.sha256"
  else
    sha256sum -c "$ROOT/inventory/ceph-msgr8.conf.sha256" >/dev/null || die ceph_conf_drift
  fi
  grep -Fqx $'\tms_async_op_threads = 8' "$CEPH_CONF" || die ceph_conf_threads_missing
  export CEPH_CONF
}

matrix() {
  printf '%s\n' \
    $'cell\tgroup\tarm\tbs\tmax_readahead\tmax_fuse_io\tport' \
    $'A01\tG1\tA\t256K\t8M\t256K\t19671' \
    $'A02\tG1\tA\t20M\t8M\t256K\t19671' \
    $'B01\tG2\tB\t20M\t32M\t256K\t19672' \
    $'C01\tG3\tC\t256K\t32M\t1M\t19673' \
    $'C02\tG3\tC\t20M\t32M\t1M\t19673' \
    $'C03\tG4\tC\t20M\t32M\t1M\t19674' \
    $'C04\tG4\tC\t256K\t32M\t1M\t19674' \
    $'B02\tG5\tB\t20M\t32M\t256K\t19675' \
    $'A03\tG6\tA\t20M\t8M\t256K\t19676' \
    $'A04\tG6\tA\t256K\t8M\t256K\t19676'
}

health_gate() {
  local tag=$1 out="$ROOT/snapshots/$1"
  mkdir -m 0700 -p "$out"
  record env "CEPH_CONF=$CEPH_CONF" ceph -s --format json
  timeout 30 env CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$out/status.json"
  record env "CEPH_CONF=$CEPH_CONF" ceph osd stat --format json
  timeout 30 env CEPH_CONF="$CEPH_CONF" ceph osd stat --format json >"$out/osd-stat.json"
  record env "CEPH_CONF=$CEPH_CONF" ceph pg dump pgs_brief
  timeout 30 env CEPH_CONF="$CEPH_CONF" ceph pg dump pgs_brief >"$out/pgs.txt"
  python3 - "$out/status.json" "$out/osd-stat.json" "$out/pgs.txt" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2]))
if (s.get('health') or {}).get('status') != 'HEALTH_OK': raise SystemExit('health_not_ok')
if (o.get('num_osds'),o.get('num_up_osds'),o.get('num_in_osds')) != (6,6,6): raise SystemExit('osd_not_6_6_6')
states=[]
for line in open(sys.argv[3]):
    f=line.split()
    if f and f[0][:1].isdigit() and len(f)>1: states.append(f[1])
# Exact equality also rejects active+clean+scrubbing/deep, recovery and backfill.
if not states or any(x != 'active+clean' for x in states): raise SystemExit('pg_not_clean_or_background_work')
PY
}

asset_fingerprint() {
  local file=$1 out=$2
  [[ -f "$file" && ! -L "$file" && "$(stat -c %s "$file")" == 34359738368 ]] || die asset_contract
  printf 'bytes\t%s\ninode\t%s\nmtime\t%s\nhead_sha256\t%s\ntail_sha256\t%s\n' \
    "$(stat -c %s "$file")" "$(stat -c %i "$file")" "$(stat -c %Y "$file")" \
    "$(head -c 1048576 "$file" | sha256sum | awk '{print $1}')" \
    "$(tail -c 1048576 "$file" | sha256sum | awk '{print $1}')" >"$out"
}
current_processes() {
  python3 - "$JFS" "$REF" "$META" "$1" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); mnt,meta,out=sys.argv[2:]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if ' mount ' not in cmd or mnt not in cmd or meta not in cmd: continue
        st=(p/'stat').read_text().split(); rows.append((int(p.name),int(st[3]),int(st[21]),hashlib.md5(open(p/'exe','rb').read()).hexdigest()))
    except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit('business_mount_process_missing')
with open(out,'w') as f:
    f.write('pid\tppid\tstarttime\texe_md5\n')
    for row in sorted(rows): f.write('\t'.join(map(str,row))+'\n')
PY
}
current_snapshot() {
  local tag=$1 out="$ROOT/identity/$1"
  mkdir -m 0700 -p "$out"
  mountpoint -q "$REF" || die business_mount_missing
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/mount.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REF fuse.juicefs" "$out/mount.tsv" || die business_mount_identity
  asset_fingerprint "$ASSET" "$out/asset.tsv"
  record env "CEPH_CONF=$CEPH_CONF" "$JFS" status "$META"
  timeout 30 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$out/status.json"
  python3 - "$out/status.json" >"$out/status.tsv" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('Setting') or {}
if s.get('Name')!='juicefs-prod' or not s.get('UUID'): raise SystemExit('business_volume_identity')
print('name\t'+s['Name']); print('uuid\t'+s['UUID']); print('block_size\t'+str(s.get('BlockSize')))
PY
  grep -Eq $'block_size\t(256|256K|262144)$' "$out/status.tsv" || die business_block_not_256K
  current_processes "$out/processes.tsv"
}
verify_current() {
  current_snapshot post
  local f
  for f in mount.tsv asset.tsv status.tsv processes.tsv; do
    cmp -s "$ROOT/identity/pre/$f" "$ROOT/identity/post/$f" || die "business_${f}_drift"
  done
}

inventory_plan() {
  valid_scope
  [[ ! -e "$ROOT" ]] || die root_exists
  local tool
  for tool in awk ceph cmp curl find findmnt fio grep head ip md5sum mountpoint pgrep python3 readlink seq sha256sum sleep ss stat tail tar timeout touch wc; do need "$tool"; done
  fixed_binary
  mkdir -m 0700 -p "$ROOT"/{identity,inventory,plans,cells,mounts,snapshots,closure,scripts}
  printf '#!/usr/bin/env bash\n# Actual commands; no credentials.\n' >"$ROOT/commands.sh"
  printf 'epoch\ttype\tdetail\n' >"$ROOT/incidents.tsv"
  printf 'epoch_iso\trun_id\tvalidity_state\tlifecycle_state\tremote_status\tlocal_status\tincident_status\treason\tevidence_root\tactor\n' >"$ROOT/run-state.tsv"
  hostname -f >"$ROOT/inventory/hostname.txt"; date -Ins >"$ROOT/inventory/time.txt"
  "$JFS" --version >"$ROOT/inventory/juicefs-version.txt" 2>&1; fio --version >"$ROOT/inventory/fio-version.txt"
  md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"
  prepare_ceph_conf
  record env "CEPH_CONF=$CEPH_CONF" ceph fsid
  timeout 30 env CEPH_CONF="$CEPH_CONF" ceph fsid >"$ROOT/inventory/ceph-fsid.txt"
  ip route get "$CEPH_ROUTE_TARGET" >"$ROOT/inventory/ceph-route.txt"
  awk '{for(i=1;i<=NF;i++)if($i=="dev"&&i<NF){print $(i+1);exit}}' "$ROOT/inventory/ceph-route.txt" >"$ROOT/inventory/nic.txt"
  [[ "$(<"$ROOT/inventory/nic.txt")" =~ ^[A-Za-z0-9_.:-]+$ ]] || die nic_missing
  pgrep -x fio >"$ROOT/inventory/foreign-fio.txt" && die foreign_fio || :
  findmnt -rn -o TARGET | grep -Eq "^/tmp/jfs-04tmp3f-$RUN_ID-" && die residual_run_mount || :
  current_snapshot pre; health_gate inventory
  matrix >"$ROOT/plans/matrix.tsv"
  cat >"$ROOT/plans/safety.tsv" <<EOF
mode\tread-only
volume\tjuicefs-prod
asset\t$ASSET_REL
environment_mutation\tread-only sessions and load only
privileged_mutation\tNONE
EOF
  cp -- "$EXECUTOR" "$ANALYZER" "$ROOT/scripts/"
  sha256sum "$EXECUTOR" "$ANALYZER" >"$ROOT/plans/runtime-scripts.sha256"
  (cd "$ROOT/scripts" && sha256sum "$(basename "$EXECUTOR")" "$(basename "$ANALYZER")") >"$ROOT/scripts/SHA256SUMS"
  state ACTIVE ACTIVE PRESERVED ACTIVE NONE INVENTORY_PASS
  printf 'T04TMP3F_INVENTORY_PLAN_PASS\troot=%s\n' "$ROOT"
}

mount_processes() {
  local log=$1 rows=$2 selected=$3
  python3 - "$JFS" "$log" "$rows" "$selected" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); marker=sys.argv[2]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if marker not in cmd: continue
        st=(p/'stat').read_text().split()
        rows.append((p.name,st[3],st[21],hashlib.md5(open(p/'exe','rb').read()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit('mount_process_missing')
with open(sys.argv[3],'w') as f:
    f.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for r in sorted(rows,key=lambda x:int(x[0])): f.write('\t'.join(r)+'\n')
pids={r[0] for r in rows}; workers=[r for r in rows if r[1] in pids]
if len(workers)!=1: raise SystemExit('unique_worker_missing')
w=workers[0]
with open(sys.argv[4],'w') as f: f.write('pid\tstarttime\texe_md5\n'+w[0]+'\t'+w[2]+'\t'+w[3]+'\n')
PY
}
processes_gone() {
  python3 - "$1" <<'PY'
import csv,sys
for r in csv.DictReader(open(sys.argv[1]),delimiter='\t'):
    try:
        if open('/proc/'+r['pid']+'/stat').read().split()[21] == r['starttime']: raise SystemExit(1)
    except OSError: pass
PY
}
mount_group() {
  local group=$1 arm=$2 ra=$3 fuse=$4 port=$5 out="$ROOT/mounts/$1" log mnt
  mnt="/tmp/jfs-04tmp3f-$RUN_ID-$group"; log="$out/mount.log"
  [[ ! -e "$mnt" && ! -L "$mnt" ]] || die "mount_path_exists_$group"
  ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)$port$" && die "metrics_port_busy_$port" || :
  mkdir -m 0700 -p "$out"; mkdir -m 0700 "$mnt"
  printf 'group\tarm\tmax_readahead\tmax_fuse_io\tport\tmeta\tmount\n%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$group" "$arm" "$ra" "$fuse" "$port" "$META" "$mnt" >"$out/mount-contract.tsv"
  local -a cmd=("$JFS" mount -d --read-only --log "$log" --metrics "127.0.0.1:$port" --max-fuse-io "$fuse" --max-readahead "$ra" --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 "$META" "$mnt")
  record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"; timeout 180 env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr" || die "mount_$group"
  local i
  for i in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die "mount_timeout_$group"
  ACTIVE_MOUNT=$mnt; ACTIVE_MOUNT_OUT=$out
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN >"$out/findmnt.tsv"
  grep -Fq "JuiceFS:juicefs-prod $mnt fuse.juicefs" "$out/findmnt.tsv" || die "mount_identity_$group"
  mount_processes "$log" "$out/mount-processes.tsv" "$out/selected-worker.tsv"
  curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/metrics" >"$out/metrics-mounted.prom" || die "metrics_missing_$group"
  grep -Fq 'vol_name="juicefs-prod"' "$out/metrics-mounted.prom" || die "metrics_identity_$group"
  local probe="$mnt/.04tmp3f-ro-$RUN_ID-$group" rc
  set +e; touch -- "$probe" 2>"$out/ro-probe.stderr"; rc=$?; set -e
  (( rc != 0 )) && [[ ! -e "$probe" ]] || die "readonly_probe_$group"
  asset_fingerprint "$mnt$ASSET_REL" "$out/asset.tsv"
  cmp -s "$ROOT/identity/pre/asset.tsv" "$out/asset.tsv" || die "mounted_asset_drift_$group"
}
graceful_unmount_active() {
  [[ -n "$ACTIVE_MOUNT" && -n "$ACTIVE_MOUNT_OUT" ]] || return 0
  local mnt=$ACTIVE_MOUNT out=$ACTIVE_MOUNT_OUT i rc=0
  if mountpoint -q "$mnt"; then
    record env "CEPH_CONF=$CEPH_CONF" "$JFS" umount "$mnt"
    timeout 180 env CEPH_CONF="$CEPH_CONF" "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr" || rc=$?
  fi
  for i in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && return 1
  for i in $(seq 1 60); do processes_gone "$out/mount-processes.tsv" && break; sleep 1; done
  processes_gone "$out/mount-processes.tsv" || return 1
  [[ -d "$mnt" && ! -L "$mnt" ]] || return 1
  rmdir -- "$mnt" || return 1
  ACTIVE_MOUNT=; ACTIVE_MOUNT_OUT=
  (( rc == 0 ))
}

sample_cell() {
  local out=$1 pid=$2 port=$3 stop=$4 nic=$5 epoch tmp
  printf 'epoch_ns\tmetric\tvalue\n' >"$out/juicefs-metrics.tsv"
  printf 'epoch_ns\tpid\tutime_ticks\tstime_ticks\trss_pages\tthreads\trx_bytes\ttx_bytes\n' >"$out/client-sidecar.tsv"
  printf 'epoch_ns\ttype\n' >"$out/sampler-errors.tsv"
  while [[ ! -e "$stop" ]]; do
    epoch=$(date +%s%N); tmp="$out/.metrics.$$"
    if curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/metrics" >"$tmp"; then
      awk -v e="$epoch" '!/^#/ && NF>=2 {print e "\t" $1 "\t" $2}' "$tmp" >>"$out/juicefs-metrics.tsv"
    else
      printf '%s\tmetrics_fetch_failed\n' "$epoch" >>"$out/sampler-errors.tsv"
    fi
    if [[ -r "/proc/$pid/stat" && -r "/proc/$pid/status" ]]; then
      read -r ut st rss < <(awk '{print $14,$15,$24}' "/proc/$pid/stat")
      th=$(awk '/^Threads:/{print $2}' "/proc/$pid/status")
      rx=$(<"/sys/class/net/$nic/statistics/rx_bytes"); tx=$(<"/sys/class/net/$nic/statistics/tx_bytes")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$pid" "$ut" "$st" "$rss" "$th" "$rx" "$tx" >>"$out/client-sidecar.tsv"
    else
      printf '%s\tworker_state_unavailable\n' "$epoch" >>"$out/sampler-errors.tsv"
    fi
    rm -f -- "$tmp"; sleep 1
  done
}
stop_sampler() {
  if [[ -n "$ACTIVE_STOP" ]]; then : >"$ACTIVE_STOP"; fi
  if [[ -n "$ACTIVE_SAMPLER" ]]; then wait "$ACTIVE_SAMPLER" 2>/dev/null || :; fi
  ACTIVE_STOP=; ACTIVE_SAMPLER=
}
run_cell() {
  local cell=$1 bs=$2 port=$3 out="$ROOT/cells/$1" pid nic rc
  mkdir -m 0700 -p "$out/bwlog"
  health_gate "$cell-pre"
  asset_fingerprint "$ACTIVE_MOUNT$ASSET_REL" "$out/asset-pre.tsv"
  cmp -s "$ROOT/identity/pre/asset.tsv" "$out/asset-pre.tsv" || die "asset_pre_$cell"
  pid=$(awk -F '\t' 'NR==2{print $1}' "$ACTIVE_MOUNT_OUT/selected-worker.tsv")
  nic=$(<"$ROOT/inventory/nic.txt")
  printf 'cell\t%s\nbs\t%s\nengine\tpsync\nqd\t1\nruntime_s\t60\nfilename\t%s\n' "$cell" "$bs" "$ACTIVE_MOUNT$ASSET_REL" >"$out/cell-contract.tsv"
  ACTIVE_STOP="$out/STOP_SAMPLER"; [[ ! -e "$ACTIVE_STOP" ]] || die "sampler_stop_exists_$cell"
  sample_cell "$out" "$pid" "$port" "$ACTIVE_STOP" "$nic" & ACTIVE_SAMPLER=$!
  sleep 2
  local -a cmd=(fio --name=read --filename="$ACTIVE_MOUNT$ASSET_REL" --rw=read --bs="$bs" --size=10G --runtime=60 --time_based --ioengine=psync --iodepth=1 --direct=1 --numjobs=1 --allow_file_create=0 --group_reporting --write_bw_log="$out/bwlog/$cell" --log_avg_msec=1000 --output="$out/fio.json" --output-format=json+)
  record "${cmd[@]}"; date +%s%N >"$out/invocation-ns.txt"
  set +e; timeout 90 "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; set -e
  date +%s%N >"$out/completion-ns.txt"; printf '%s\n' "$rc" >"$out/fio.rc"
  sleep 2; stop_sampler
  [[ "$(wc -l <"$out/sampler-errors.tsv")" == 1 ]] || die "sampler_error_$cell"
  (( rc == 0 )) || die "fio_rc_${cell}_$rc"
  python3 "$ANALYZER" cell "$out" >"$out/analysis.json" || die "analysis_$cell"
  asset_fingerprint "$ACTIVE_MOUNT$ASSET_REL" "$out/asset-post.tsv"
  cmp -s "$out/asset-pre.tsv" "$out/asset-post.tsv" || die "asset_post_$cell"
  health_gate "$cell-post"
}
run_group() {
  local group=$1 arm=$2 ra=$3 fuse=$4 port=$5; shift 5
  mount_group "$group" "$arm" "$ra" "$fuse" "$port"
  while (( $# )); do run_cell "$1" "$2" "$port"; shift 2; done
  graceful_unmount_active || die "unmount_$group"
  health_gate "$group-unmounted"
}
run_r() {
  valid_scope
  [[ ${3:-} == "I_ACK_04TMP3F_RUN_R_$RUN_ID" ]] || die invalid_RUN_R_ACK
  [[ -f "$ROOT/plans/matrix.tsv" ]] || die inventory_required
  (cd / && sha256sum -c "$ROOT/plans/runtime-scripts.sha256") >/dev/null || die runtime_script_drift
  fixed_binary
  prepare_ceph_conf
  pgrep -x fio >"$ROOT/inventory/foreign-fio-at-run.txt" && die foreign_fio || :
  local rc=0
  on_exit() {
    local x=$?
    trap - EXIT INT TERM HUP; set +e
    stop_sampler
    if [[ -n "$ACTIVE_MOUNT" ]]; then graceful_unmount_active || x=70; fi
    (( x == 0 )) || incident RUN_ABORT "rc=$x"
    exit "$x"
  }
  trap on_exit EXIT INT TERM HUP
  run_group G1 A 8M 256K 19671 A01 256K A02 20M
  run_group G2 B 32M 256K 19672 B01 20M
  run_group G3 C 32M 1M 19673 C01 256K C02 20M
  run_group G4 C 32M 1M 19674 C03 20M C04 256K
  run_group G5 B 32M 256K 19675 B02 20M
  run_group G6 A 8M 256K 19676 A03 20M A04 256K
  python3 "$ANALYZER" verdict "$ROOT" >"$ROOT/verdict.json" || die verdict
  verify_current; health_gate final
  state VALID PERSISTING PRESERVED ACTIVE NONE R_PASS
  printf '%s\n' "$(date -Ins)" >"$ROOT/R_PASS"
  trap - EXIT INT TERM HUP
  printf 'T04TMP3F_R_PASS\troot=%s\n' "$ROOT"
}
bundle() {
  valid_scope; [[ -f "$ROOT/R_PASS" && -f "$ROOT/verdict.json" ]] || die R_required
  local archive="$REMOTE_PARENT/04tmp3f-$RUN_ID-evidence.tar"
  [[ ! -e "$archive" && ! -L "$archive" ]] || die archive_exists
  (cd "$ROOT" && find . -type f ! -path './closure/manifest.sha256' -print0 | sort -z | xargs -0 sha256sum) >"$ROOT/closure/manifest.sha256"
  tar -C "$REMOTE_PARENT" -cf "$archive" "opencode-04tmp3f-$RUN_ID"
  sha256sum "$archive" >"$archive.sha256"
  state VALID PERSISTING PRESERVED ACTIVE NONE BUNDLE_PASS
  printf 'T04TMP3F_BUNDLE_PASS\tarchive=%s\n' "$archive"
}
self_test() {
  [[ "$(matrix | wc -l)" == 11 ]]
  grep -Fqx $'B01\tG2\tB\t20M\t32M\t256K\t19672' < <(matrix)
  grep -Fqx $'C02\tG3\tC\t20M\t32M\t1M\t19673' < <(matrix)
  RUN_ID=20260905-000000; ROOT="$REMOTE_PARENT/opencode-04tmp3f-$RUN_ID"; valid_scope
  printf 'T04TMP3F_EXECUTOR_SELFTEST_PASS\n'
}

case ${1:-} in
  inventory-plan) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3f-$RUN_ID"; inventory_plan;;
  run-r) [[ $# -eq 3 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3f-$RUN_ID"; run_r "$@";;
  bundle) [[ $# -eq 2 ]] || usage; RUN_ID=$2; ROOT="$REMOTE_PARENT/opencode-04tmp3f-$RUN_ID"; bundle;;
  --self-test) [[ $# -eq 1 ]] || usage; self_test;;
  --print-matrix) [[ $# -eq 1 ]] || usage; matrix;;
  *) usage;;
esac
