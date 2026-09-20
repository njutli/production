#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# Minimal 05-1 driver.  Plan generation is offline; online phases require
# explicit ACKs.  There is no cache/loop/volume lifecycle in this file.
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANALYZER="$DIR/t05-1-randrw-analyze.py"
TASKBOOK="$DIR/../../../doc/perf-tasks/05-1-randrw-block-size-sweep-and-adaptive-tuning.md"
META=${T051_META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
JFS=${T051_JFS:-/tmp/juicefs-1.4.1-patched}; REF=${T051_REF:-/mnt/juicefs}
FIO=${T051_FIO:-fio}; METRICS=${T051_METRICS:-127.0.0.1:9568}
GC_TIMEOUT_SECONDS=${T051_GC_TIMEOUT_SECONDS:-1800}
JFS_MD5=24fae0852051c80ca571cb2f20275d46
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
MODE=${1:-}; RUN_ID=${2:-}; ROOT=/tmp/production/opencode-05-1-$RUN_ID
CEPH_CONF=${T051_CEPH_CONF:-$ROOT/inventory/ceph.conf}

die() { printf 'T051_DRIVER_FAIL\t%s\n' "$*" >&2; exit 42; }
valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == /tmp/production/opencode-05-1-$RUN_ID && $ROOT != / && ! -L $ROOT ]] || die unsafe_root
  if [[ -e $ROOT ]]; then
    [[ -d $ROOT && $(stat -Lc %a "$ROOT") == 700 && $(stat -Lc %u "$ROOT") == $(id -u) ]] || die root_identity
  fi
}
phase_a_order() { printf '%s\n' S01 S02 S03 S04 S05 S06 S07 S08 S09 S10 S11 S12; }
phase_a_bs() {
  case "$1" in S01|S12) printf '256K\n';; S02|S11) printf '4K\n';; S03|S10) printf '16K\n';;
    S04|S09) printf '64K\n';; S05|S08) printf '1M\n';; S06|S07) printf '4M\n';; *) die invalid_phase_a_cell;; esac
}
phase_b_order() { printf '%s\n' '1M-C1' '1M-T1' '1M-T2' '1M-C2'; }
phase_b_4m_order() { printf '%s\n' '4M-C1' '4M-T1' '4M-T2' '4M-C2'; }

write_plans() {
  printf 'position\tcell\tbs\tconfig\tfuse\tformal_window\n' >"$ROOT/plans/phase-a-matrix.tsv"
  local n=0 cell bs config fuse
  while read -r cell; do
    n=$((n+1)); bs=$(phase_a_bs "$cell")
    printf '%s\t%s\t%s\tC\t256K\t[15,175)\n' "$n" "$cell" "$bs" >>"$ROOT/plans/phase-a-matrix.tsv"
  done < <(phase_a_order)
  printf 'position\tcell\tbs\tconfig\tfuse\tformal_window\n' >"$ROOT/plans/phase-b-matrix.tsv"
  n=0
  while read -r cell; do
    n=$((n+1)); bs=${cell%%-*}; config=${cell#*-}; fuse=256K
    case $config in C1|C2) config=C;; T1|T2) config=T; fuse=1M;; *) die invalid_phase_b_plan;; esac
    printf '%s\t%s\t%s\t%s\t%s\t[15,175)\n' "$n" "$cell" "$bs" "$config" "$fuse" >>"$ROOT/plans/phase-b-matrix.tsv"
  done < <(phase_b_order)
  while read -r cell; do
    n=$((n+1)); bs=${cell%%-*}; config=${cell#*-}; fuse=256K
    case $config in C1|C2) config=C;; T1|T2) config=T; fuse=1M;; *) die invalid_phase_b_plan;; esac
    printf '%s\t%s\t%s\t%s\t%s\t[15,175)\n' "$n" "$cell" "$bs" "$config" "$fuse" >>"$ROOT/plans/phase-b-matrix.tsv"
  done < <(phase_b_4m_order)
  cat >"$ROOT/plans/privileged-recovery-plan.tsv" <<'EOF'
action	status	command	why
ceph_compact	PLAN_ONLY	sudo ceph tell osd.<registered-id> compact	cooldown; operator must review
scrub_pause	PLAN_ONLY	sudo ceph osd set noscrub; sudo ceph osd set nodeep-scrub	optional controlled benchmark only
scrub_restore	PLAN_ONLY	sudo ceph osd unset nodeep-scrub; sudo ceph osd unset noscrub	restore exact prior flags
format_layout_destroy	NOT_USED	NONE	05-1 reuses existing dataset and volume
EOF
  cat >"$ROOT/plans/readonly-command-plan.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
PLAN: hostname
PLAN: id
PLAN: md5sum /tmp/juicefs-1.4.1-patched
PLAN: /tmp/juicefs-1.4.1-patched version
PLAN: /tmp/juicefs-1.4.1-patched status tikv://<frozen-meta>
PLAN: findmnt -rn -M /mnt/juicefs
PLAN: ceph -s -f json
PLAN: ceph osd stat -f json
PLAN: ceph df -f json
PLAN: pgrep -a -x fio
EOF
  chmod 0700 "$ROOT/plans/readonly-command-plan.sh"
}

inventory_plan() {
  valid_run; [[ ! -e "$ROOT" ]] || die result_exists
  mkdir -m 0700 "$ROOT"
  mkdir -m 0700 "$ROOT/plans" "$ROOT/inventory" "$ROOT/cells"
  write_plans
  printf 'RUN_ID\t%s\nVALIDITY_STATE\tACTIVE\nLIFECYCLE_STATE\tACTIVE\n' "$RUN_ID" >"$ROOT/run-state.tsv"
  printf 'epoch_ns\tcell\tevent\n' >"$ROOT/incidents.tsv"
  printf '%s\n' 'RUNNER_STATUS=PLAN_ONLY' 'ONLINE_ENTRY=ACK_REQUIRED' \
    'PRIVILEGED_ACTIONS=PLAN_ONLY' 'DATASET_POLICY=REUSE_EXISTING_128x1GiB_rw_test' \
    'NO_FORMAT_LAYOUT_DESTROY=TRUE' >"$ROOT/plans/status.txt"
  sha256sum "$0" "$ANALYZER" "$TASKBOOK" >"$ROOT/plans/input-sha256.tsv"
  printf 'INVENTORY_PLAN_PASS\troot=%s\tno_environment_contact=true\n' "$ROOT"
}

offline_self_test() {
  local a b expected_a expected_b cell
  expected_a='S01 S02 S03 S04 S05 S06 S07 S08 S09 S10 S11 S12'
  expected_b='1M-C1 1M-T1 1M-T2 1M-C2'
  a=$(phase_a_order | paste -sd' ' -); b=$(phase_b_order | paste -sd' ' -)
  [[ $a == "$expected_a" && $b == "$expected_b" ]] || die matrix_order
  [[ $(phase_a_order | wc -l) -eq 12 && $(phase_a_order | sort -u | wc -l) -eq 12 ]] || die matrix_count
  [[ $(phase_b_order | wc -l) -eq 4 && $(phase_b_order | sort -u | wc -l) -eq 4 ]] || die matrix_count
  [[ $(phase_b_4m_order | wc -l) -eq 4 && $(phase_b_4m_order | sort -u | wc -l) -eq 4 ]] || die matrix_count
  for cell in 4K 16K 64K 256K 1M 4M; do grep -Fq "$cell" "$0" || die bs_contract_$cell; done
  for cell in 'rwmixread=50' 'ioengine=libaio' 'iodepth=128' 'numjobs=128' \
    'direct=1' 'fallocate=none' 'allow_file_create=0' 'openfiles=128' \
    'runtime=180' 'group_reporting=1' 'write_bw_log' 'log_avg_msec=1000' \
    '--max-fuse-io' '--max-uploads 150' '--cache-size 0'; do
    grep -Fq -- "$cell" "$0" || die contract_$cell
  done
  grep -Fq 'I_ACK_05_1_ONLINE_' "$0" || die online_ack_guard
  grep -Fq 'I_ACK_05_1_CLEAN_' "$0" || die clean_ack_guard
  printf 'T051_DRIVER_OFFLINE_SELF_TEST_PASS\tphase_a=12_unique\tphase_b=8_unique\tprivileged=plan_only\n'
}

require_online_ack() {
  [[ ${T051_EXECUTE_ACK:-} == I_ACK_05_1_ONLINE_$RUN_ID ]] || die online_ack_missing
  [[ ${T051_CLEAN_STATE_ACK:-} == I_ACK_05_1_CLEAN_$RUN_ID ]] || die clean_state_ack_missing
  valid_run
}
log_command() { printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }
record_event() { printf '%s\t%s\t%s\n' "$(date +%s%N)" "$1" "$2" >>"$ROOT/incidents.tsv"; }

online_inventory() {
  mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/cells"
  [[ -r /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_missing
  cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
  chmod 0600 "$CEPH_CONF"
  [[ $(md5sum "$CEPH_CONF" | awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die ceph_conf_identity
  [[ -x "$JFS" && ! -L "$JFS" ]] || die juicefs_missing
  [[ $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die juicefs_identity
  md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"
  sha256sum "$JFS" >"$ROOT/inventory/juicefs.sha256"
  "$JFS" version >"$ROOT/inventory/juicefs-version.txt"
  env CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$ROOT/inventory/volume-status.json" || die volume_status
  python3 - "$ROOT/inventory/volume-status.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); s=d.get("Setting", d)
if s.get("Name") != "juicefs-prod" or not s.get("UUID") or int(s.get("BlockSize", -1)) != 256:
    raise SystemExit("JuiceFS volume Name/UUID/BlockSize contract failed")
PY
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/reference-mount.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REF fuse.juicefs" "$ROOT/inventory/reference-mount.tsv" || die reference_mount
  env CEPH_CONF="$CEPH_CONF" ceph fsid >"$ROOT/inventory/fsid.txt" || die ceph_fsid
  env CEPH_CONF="$CEPH_CONF" ceph osd stat -f json >"$ROOT/inventory/osd-stat.json" || die osd_stat
  env CEPH_CONF="$CEPH_CONF" ceph df -f json >"$ROOT/inventory/ceph-df.json" || die ceph_df
  pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1 && die foreign_fio || :
  find "$REF/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$ROOT/inventory/assets.tsv"
  [[ $(wc -l <"$ROOT/inventory/assets.tsv") -eq 128 ]] || die asset_count
  awk -F '\t' '$3 != 1073741824 {bad=1} END {exit bad}' "$ROOT/inventory/assets.tsv" || die asset_size
  mount_pid_identity "$REF" "$ROOT/inventory/reference-mount-process.tsv" || die reference_process_identity
  for required in '--max-fuse-io 256K' '--max-uploads 150' '--cache-size 0'; do
    grep -Fq -- "$required" "$ROOT/inventory/reference-mount-process.tsv" || die reference_mount_contract
  done
}

check_health() {
  local label=$1
  local out="$ROOT/health-$1"
  mkdir -m 0700 -p "$out"
  env CEPH_CONF="$CEPH_CONF" ceph -s -f json >"$out/ceph-status.json" || die ceph_status_$label
  python3 - "$out/ceph-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("health",{})
if h.get("status") != "HEALTH_OK" or h.get("checks"):
    raise SystemExit("health is not HEALTH_OK")
pgs=d.get("pgmap",{}).get("pgs_by_state",[])
if not pgs or any(p.get("state_name") != "active+clean" for p in pgs):
    raise SystemExit("PG is not active+clean")
o=d.get("osdmap",{})
keys=("num_osds","num_up_osds","num_in_osds")
if any(not isinstance(o.get(k),int) for k in keys) or o["num_osds"] <= 0:
    raise SystemExit("OSD counters are missing or invalid")
if o["num_up_osds"] != o["num_osds"] or o["num_in_osds"] != o["num_osds"]:
    raise SystemExit("OSDs are not fully up/in")
PY
}

pre_cell_recovery() {
  local cell=$1
  local out="$ROOT/cells/$cell/recovery-pre"
  local i recovery_pass=0
  mkdir -m 0700 -p "$out"
  [[ $GC_TIMEOUT_SECONDS =~ ^[0-9]+$ && $GC_TIMEOUT_SECONDS -ge 60 && $GC_TIMEOUT_SECONDS -le 3600 ]] \
    || die invalid_gc_timeout
  log_command env JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" timeout "$GC_TIMEOUT_SECONDS" \
    "$JFS" gc --compact --delete --threads 32 "$META"
  set +e
  env JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" timeout "$GC_TIMEOUT_SECONDS" \
    "$JFS" gc --compact --delete --threads 32 "$META" >"$out/gc.txt" 2>"$out/gc.stderr"
  local gc_rc=$?
  set -e
  printf '%s\n' "$gc_rc" >"$out/gc.rc"
  (( gc_rc == 0 )) || die gc_failed_$cell
  printf 'sample\tobjects\tstored\tpending_150\tpending_151\tpending_152\n' >"$out/readonly-gates.tsv"
  for i in $(seq 1 180); do
    check_health "recovery-$cell-$i"
    env CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$out/juicefs-status-$i.json" || die recovery_status_$cell
    python3 - "$ROOT/inventory/volume-status.json" "$out/juicefs-status-$i.json" <<'PY'
import json,sys
reference=json.load(open(sys.argv[1])).get("Setting",{})
current=json.load(open(sys.argv[2])).get("Setting",{})
for key in ("Name","UUID","BlockSize"):
    if key not in reference or key not in current or current[key] != reference[key]:
        raise SystemExit("JuiceFS volume identity changed: "+key)
PY
    env CEPH_CONF="$CEPH_CONF" ceph df -f json >"$out/ceph-df-$i.json" || die recovery_ceph_df_$cell
    for host in 10.20.1.150 10.20.1.151 10.20.1.152; do
      curl -fsS --connect-timeout 3 --max-time 5 "http://$host:20180/metrics" \
        | awk '$1~/^tikv_engine_pending_compaction_bytes(\{|$)/{print}' \
        >"$out/tikv-$i-$host.pending" || die recovery_tikv_metrics_$cell
      [[ -s "$out/tikv-$i-$host.pending" ]] || die recovery_tikv_metric_missing_$cell
    done
    local pending_150 pending_151 pending_152
    pending_150=$(awk '$1~/^tikv_engine_pending_compaction_bytes(\{|$)/{v=$2;if(v!~/^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/||v+0<0)bad=1;else{s+=v;n=1}}END{if(!n||bad)exit 1;printf "%.0f",s}' \
      "$out/tikv-$i-10.20.1.150.pending") || die recovery_tikv_pending_150_$cell
    pending_151=$(awk '$1~/^tikv_engine_pending_compaction_bytes(\{|$)/{v=$2;if(v!~/^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/||v+0<0)bad=1;else{s+=v;n=1}}END{if(!n||bad)exit 1;printf "%.0f",s}' \
      "$out/tikv-$i-10.20.1.151.pending") || die recovery_tikv_pending_151_$cell
    pending_152=$(awk '$1~/^tikv_engine_pending_compaction_bytes(\{|$)/{v=$2;if(v!~/^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/||v+0<0)bad=1;else{s+=v;n=1}}END{if(!n||bad)exit 1;printf "%.0f",s}' \
      "$out/tikv-$i-10.20.1.152.pending") || die recovery_tikv_pending_152_$cell
    python3 - "$out/ceph-df-$i.json" "$i" "$pending_150" "$pending_151" "$pending_152" \
      >>"$out/readonly-gates.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pools=[p for p in d.get("pools",[]) if p.get("name")=="juicefs-data"]
if len(pools)!=1: raise SystemExit("juicefs-data pool missing")
s=pools[0].get("stats",{})
if any(not isinstance(s.get(k),(int,float)) or s[k] < 0 for k in ("objects","stored")):
    raise SystemExit("juicefs-data objects/stored missing or invalid")
print(sys.argv[2],int(s["objects"]),int(s["stored"]),*sys.argv[3:6],sep="\t")
PY
    if (( i >= 3 )) && tail -n 3 "$out/readonly-gates.tsv" | \
      awk 'NR==1{o=$2;lo=hi=$3} {n++;if($2!=o)bad=1;if($3<lo)lo=$3;if($3>hi)hi=$3;if($4!=0||$5!=0||$6!=0)bad=1} END{if(n!=3||hi-lo>16777216)bad=1;exit bad}'; then
      recovery_pass=1
      break
    fi
    sleep 10
  done
  (( recovery_pass == 1 )) || die recovery_state_not_stable_$cell
  printf 'RECOVERY_GATE_PASS\n' >"$out/PASS"
}

mount_pid_identity() {
  local mount=$1
  local out=$2
  local marker=${3:-$mount}
  python3 - "$JFS" "$mount" "$marker" >"$out" <<'PY'
import os,sys
exe=os.path.realpath(sys.argv[1]); mount=sys.argv[2]; marker=sys.argv[3]; rows=[]
for item in os.listdir('/proc'):
    if not item.isdigit(): continue
    try:
        if os.path.realpath('/proc/'+item+'/exe') != exe: continue
        argv=open('/proc/'+item+'/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace')
        if marker not in argv: continue
        stat=open('/proc/'+item+'/stat').read().split()
        rows.append((int(item),int(stat[3]),int(stat[21]),argv.strip()))
    except (OSError,ValueError): pass
if len(rows) != 2 or not any(a[1] == b[0] for a in rows for b in rows):
    raise SystemExit('missing unique JuiceFS parent/worker pair')
print('pid\tppid\tstarttime\tcmdline')
for row in sorted(rows): print(*row,sep='\t')
PY
}

mount_cell() {
  local cell=$1
  local fuse=$2
  CELL_ROOT="$ROOT/cells/$cell"; MNT="/tmp/jfs-05-1-$RUN_ID-$cell"
  [[ $cell =~ ^[A-Za-z0-9._-]+$ && $MNT != / && ! -L "$MNT" ]] || die unsafe_mount_path
  [[ ! -e "$MNT" ]] || die mount_exists_$cell
  mkdir -m 0700 -p "$CELL_ROOT" "$MNT"
  local -a cmd=(env "CEPH_CONF=$CEPH_CONF" "$JFS" mount -d --max-uploads 150
    --max-fuse-io "$fuse" --cache-size 0 --metrics "$METRICS"
    --log "$CELL_ROOT/juicefs.log" "$META" "$MNT")
  log_command "${cmd[@]}"
  "${cmd[@]}" >"$CELL_ROOT/mount.stdout" 2>"$CELL_ROOT/mount.stderr"
  for _ in $(seq 1 120); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || die mount_failed_$cell
  findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$CELL_ROOT/findmnt.tsv"
  grep -Fq "JuiceFS:juicefs-prod $MNT fuse.juicefs" "$CELL_ROOT/findmnt.tsv" || die mount_identity_$cell
  mount_pid_identity "$MNT" "$CELL_ROOT/mount-process.tsv" "$CELL_ROOT/juicefs.log" || die process_identity_$cell
  printf 'fuse\t%s\nmount\t%s\n' "$fuse" "$MNT" >"$CELL_ROOT/mount-state.tsv"
}

graceful_umount() {
  log_command "$JFS" umount "$MNT"
  "$JFS" umount "$MNT" >"$CELL_ROOT/umount.stdout" 2>"$CELL_ROOT/umount.stderr" || die graceful_umount_failed
  for _ in $(seq 1 180); do mountpoint -q "$MNT" || break; sleep 1; done
  mountpoint -q "$MNT" && die mount_still_present
  rmdir -- "$MNT" || die mount_directory_not_empty
  printf 'GRACEFUL_UMOUNT_PASS\n' >"$CELL_ROOT/umount.pass"
}

sample_metrics() {
  local label=$1
  local output="$CELL_ROOT/metrics-$1.prom"
  if curl -fsS --max-time 5 "http://$METRICS/metrics" >"$output"; then
    printf 'METRICS_PASS\n' >"$CELL_ROOT/metrics-$label.status"
  else
    printf 'METRICS_MISSING\n' >"$CELL_ROOT/metrics-$label.status"
    return 1
  fi
}

run_fio_cell() {
  local cell=$1
  local bs=$2
  local path=$3
  local out job rc
  CELL_ROOT="$ROOT/cells/$cell"; out="$CELL_ROOT/formal"; mkdir -m 0700 -p "$out/bw"
  job="$out/fio.job"
  cat >"$job" <<EOF
[global]
ioengine=libaio
iodepth=128
numjobs=128
rw=randrw
rwmixread=50
bs=$bs
filesize=1G
size=1G
direct=1
fallocate=none
allow_file_create=0
openfiles=128
time_based=1
runtime=180
group_reporting=1
randrepeat=1
write_bw_log=$out/bw/randrw
log_avg_msec=1000
per_job_logs=1
filename_format=$path/test_dir/rw_test.\$jobnum.0
[job]
EOF
  printf '%s\n' "$bs" >"$CELL_ROOT/bs.txt"
  log_command "$FIO" "$job" --output="$out/fio.json" --output-format=json
  date +%s%N >"$out/fio-start-epoch-ns.txt"
  set +e; "$FIO" "$job" --output="$out/fio.json" --output-format=json; rc=$?; set -e
  date +%s%N >"$out/fio-end-epoch-ns.txt"; printf '%s\n' "$rc" >"$out/fio.rc"
  (( rc == 0 )) || die fio_failed_$cell
  [[ $(find "$out/bw" -maxdepth 1 -type f -name 'randrw_bw.*.log' | wc -l) -eq 128 ]] || die bw_log_count_$cell
  printf 'FIO_RAW_PASS\n' >"$out/PASS"
}

run_phase_a_cell() {
  local cell=$1
  local bs; bs=$(phase_a_bs "$cell")
  CELL_ROOT="$ROOT/cells/$cell"; [[ ! -e "$CELL_ROOT" ]] || die cell_exists_$cell
  mkdir -m 0700 -p "$CELL_ROOT"; record_event "$cell" START
  pgrep -a -x fio >"$CELL_ROOT/foreign-fio.tsv" 2>&1 && die foreign_fio_$cell || :
  pre_cell_recovery "$cell"; check_health "pre-$cell"
  sample_metrics pre || printf 'METRICS_MISSING_ALLOWED_PHASE_A\n' >"$CELL_ROOT/metrics-pre-note"
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$CELL_ROOT/reference-mount.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REF fuse.juicefs" "$CELL_ROOT/reference-mount.tsv" || die reference_lost_$cell
  run_fio_cell "$cell" "$bs" "$REF"
  check_health "post-$cell"
  sample_metrics post || printf 'METRICS_MISSING_ALLOWED_PHASE_A\n' >"$CELL_ROOT/metrics-post-note"
  record_event "$cell" RAW_PASS
}

run_phase_b_cell() {
  local cell=$1
  local bs=${cell%%-*}
  local suffix=${cell#*-}
  local config
  local fuse=256K
  case $suffix in C1|C2) config=C;; T1|T2) config=T;; *) die invalid_phase_b_cell;; esac
  [[ $config == T ]] && fuse=1M
  [[ ! -e "$ROOT/cells/$cell" ]] || die cell_exists_$cell
  CELL_ROOT="$ROOT/cells/$cell"; mkdir -m 0700 -p "$CELL_ROOT"; record_event "$cell" START
  pre_cell_recovery "$cell"; mount_cell "$cell" "$fuse"
  pgrep -a -x fio >"$CELL_ROOT/foreign-fio.tsv" 2>&1 && die foreign_fio_$cell || :
  check_health "pre-$cell"
  sample_metrics pre || die metrics_pre_$cell
  run_fio_cell "$cell" "$bs" "$MNT"
  check_health "post-$cell"
  sample_metrics post || die metrics_post_$cell
  graceful_umount; record_event "$cell" RAW_PASS
}

phase_a() {
  require_online_ack; [[ ! -e "$ROOT/PHASE_A_PASS" ]] || die phase_a_already_complete
  mkdir -m 0700 -p "$ROOT"; : >"$ROOT/commands.sh"; online_inventory
  check_health pre-phase-a
  while IFS=$'\t' read -r position cell bs config fuse window; do
    [[ $position == position ]] && continue
    run_phase_a_cell "$cell"
  done <"$ROOT/plans/phase-a-matrix.tsv"
  check_health post-phase-a; printf 'PHASE_A_PASS\n' >"$ROOT/PHASE_A_PASS"
}

ensure_phase_a_source() {
  [[ ! -e "$ROOT/PHASE_A_PASS" ]] || return 0
  local source=${T051_PHASE_A_EVIDENCE_ROOT:-}
  [[ $source =~ ^/tmp/production/opencode-05-1-[0-9]{8}-[0-9]{6}$ && -d $source && ! -L $source ]] \
    || die external_phase_a_source_invalid
  [[ -f "$source/PHASE_A_PASS" && -f "$source/phase-a-analysis-final.json" && \
     -f "$source/phase-a-decision.tsv" ]] || die external_phase_a_evidence_missing
  python3 - "$source/phase-a-analysis-final.json" "$source/phase-a-decision.tsv" <<'PY'
import csv,json,sys
analysis=json.load(open(sys.argv[1]))
if analysis.get("RUN_VALIDITY_STATE") != "ACTIVE" or analysis.get("errors") or len(analysis.get("cells",[])) != 12:
    raise SystemExit("external Phase A analysis is invalid")
rows=list(csv.DictReader(open(sys.argv[2]),delimiter="\t"))
anchor=[r for r in rows if r.get("bs")=="256K"]
if len(anchor)!=1 or anchor[0].get("verdict")!="PASS":
    raise SystemExit("external Phase A anchor did not pass")
PY
  printf 'source_root\t%s\nanalysis_sha256\t%s\ndecision_sha256\t%s\n' "$source" \
    "$(sha256sum "$source/phase-a-analysis-final.json" | awk '{print $1}')" \
    "$(sha256sum "$source/phase-a-decision.tsv" | awk '{print $1}')" \
    >"$ROOT/PHASE_A_EXTERNAL_ACCEPTED.tsv"
}

phase_b_for() {
  local target=$1
  local mark=$2
  require_online_ack
  ensure_phase_a_source
  [[ -f "$ROOT/inventory/ceph.conf" ]] || online_inventory
  [[ ! -e "$ROOT/$mark" ]] || die phase_b_already_complete
  if [[ $target == 4M ]]; then
    [[ -f "$ROOT/PHASE_B_1M_PASS" ]] || die phase_b_1m_required
    [[ ${T051_BETWEEN_BS_ACK:-} == I_ACK_05_1_BETWEEN_BS_$RUN_ID ]] || die between_bs_ack_missing
  fi
  check_health "pre-phase-b-$target"
  local order="$ROOT/plans/phase-b-matrix.tsv"
  while IFS=$'\t' read -r position cell bs config fuse window; do
    [[ $position == position || $bs != "$target" ]] && continue
    run_phase_b_cell "$cell"
  done <"$order"
  check_health "post-phase-b-$target"; printf '%s\n' "$mark" >"$ROOT/$mark"
}

bundle() {
  valid_run; [[ -d "$ROOT" ]] || die root_missing
  mkdir -m 0700 -p "$ROOT/bundle"
  find "$ROOT" -type f ! -path "$ROOT/bundle/*" -print0 | sort -z | xargs -0 sha256sum >"$ROOT/bundle/SHA256SUMS"
  printf 'BUNDLE_PLAN_ONLY\troot=%s\n' "$ROOT"
}

closure() {
  valid_run; [[ -d "$ROOT" ]] || die root_missing
  printf 'CLOSURE_PLAN_ONLY\tgraceful_umount_and_external_recovery_review_required\n'
}

case "$MODE" in
  offline-self-test) offline_self_test ;;
  inventory-plan) inventory_plan ;;
  phase-a) phase_a ;;
  phase-b-1m) phase_b_for 1M PHASE_B_1M_PASS ;;
  phase-b-4m) phase_b_for 4M PHASE_B_4M_PASS ;;
  bundle) bundle ;;
  closure) closure ;;
  *) printf 'usage: %s offline-self-test|inventory-plan|phase-a|phase-b-1m|phase-b-4m|bundle|closure RUN_ID\n' "$0" >&2; exit 2 ;;
esac
