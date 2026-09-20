#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
# 05-2 minimal driver. Phase A, mandatory B1, and gated B2 only.
MODE=$1
RUN_ID=$2
REMOTE_PARENT=/tmp/production
ROOT=$REMOTE_PARENT/opencode-05-2-$RUN_ID
OUT=/tmp/t05-2-plan-$RUN_ID
if [[ -n ${T052_PLAN_OUT-} ]]; then OUT=$T052_PLAN_OUT; fi
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
JFS=/tmp/juicefs-1.4.1-patched
FIO=fio
REF=/mnt/juicefs
METRICS=
CEPH_CONF=/etc/ceph/ceph.conf
JFS_MD5=24fae0852051c80ca571cb2f20275d46
GC_TIMEOUT_SECONDS=1800
ACTIVE_SAMPLER_PID=
ACTIVE_SAMPLER_STOP=
die() { printf 'T052_DRIVER_FAIL\t%s\n' "$*" >&2; exit 42; }
valid_run() { [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID; [[ $ROOT == "$REMOTE_PARENT/opencode-05-2-$RUN_ID" && $ROOT != / && ! -L $ROOT ]] || die unsafe_root; }
require_online_ack() { [[ ${T052_EXECUTE_ACK-} == I_ACK_05_2_ONLINE_$RUN_ID ]] || die online_ack_missing; [[ ${T052_CLEAN_STATE_ACK-} == I_ACK_05_2_CLEAN_$RUN_ID ]] || die clean_state_ack_missing; valid_run; }
log_cmd() { printf '%q ' "$@" >>$ROOT/commands.sh; printf '\n' >>$ROOT/commands.sh; }
event() { printf '%s\t%s\t%s\n' "$(date +%s%N)" "$1" "$2" >>$ROOT/incidents.tsv; }
phase_a_rows() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 1 C1 1M C 150 1M 300 EFFECT 2 T1 1M T 300 1M 300 EFFECT 3 T2 1M T 300 1M 300 EFFECT 4 C2 1M C 150 1M 300 EFFECT; }
phase_b1_rows() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 1 B1 256K C 150 256K 300 EXCLUDED; }
phase_b2_rows() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 1 B2-C1 256K C 150 256K 300 EFFECT 2 B2-T1 256K T 300 256K 300 EFFECT 3 B2-T2 256K T 300 256K 300 EFFECT 4 B2-C2 256K C 150 256K 300 EFFECT; }
fixture_mount_rows() { phase_a_rows | while IFS=$'\t' read -r pos cell bs arm uploads fuse buffer scope; do printf 'MOUNT_FIXTURE\t%s\t%s\t%s\t%s\n' "$cell" "$uploads" "$fuse" "$buffer"; done; }
write_plans() {
  local d; d=$1; mkdir -m 0700 -p "$d"
  printf 'position\tcell\tbs\tarm\tmax_uploads\tfuse\tbuffer_mib\teffect_scope\n' >$d/phase-a-matrix.tsv; phase_a_rows >>$d/phase-a-matrix.tsv
  printf 'position\tcell\tbs\tarm\tmax_uploads\tfuse\tbuffer_mib\teffect_scope\n' >$d/phase-b1-matrix.tsv; phase_b1_rows >>$d/phase-b1-matrix.tsv
  printf 'position\tcell\tbs\tarm\tmax_uploads\tfuse\tbuffer_mib\teffect_scope\n' >$d/phase-b2-matrix.tsv; phase_b2_rows >>$d/phase-b2-matrix.tsv
  cat >$d/recovery-plan.tsv <<'EOF'
action	status	precise_plan
gc	PLAN_ONLY	juicefs gc --compact --delete --threads 32 <META>; no layout/format/destroy
objects-stored	PLAN_ONLY	passively wait for juicefs-data objects/stored stability
tikv-pending	PLAN_ONLY	three nodes pending-compaction=0 for 3 consecutive samples
health	PLAN_ONLY	Ceph health OK and all PGs active+clean
EOF
  cat >$d/scrub-plan.tsv <<'EOF'
phase	action	status	command
A	pause	REQUIRES_G0_APPROVAL	u141d-scrub-control.sh pause <RUN_ID>-phase-a <INVENTORY_FSID> I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
A	restore	MANDATORY	u141d-scrub-control.sh restore <RUN_ID>-phase-a
B1	pause	REQUIRES_G0_APPROVAL	u141d-scrub-control.sh pause <RUN_ID>-phase-b <INVENTORY_FSID> I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
B1	restore	MANDATORY	u141d-scrub-control.sh restore <RUN_ID>-phase-b
EOF
  cat >$d/compact-plan.tsv <<'EOF'
scope	status	maximum	precise_commands
Phase-A	DISABLED_PENDING_SEPARATE_APPROVAL	one per OSD (6 total)	ceph tell osd.0 compact; ceph tell osd.1 compact; ceph tell osd.2 compact; ceph tell osd.3 compact; ceph tell osd.4 compact; ceph tell osd.5 compact
Phase-B1	DISABLED_PENDING_SEPARATE_APPROVAL	one per OSD (6 total)	ceph tell osd.0 compact; ceph tell osd.1 compact; ceph tell osd.2 compact; ceph tell osd.3 compact; ceph tell osd.4 compact; ceph tell osd.5 compact
EOF
  cat >$d/write-operations.tsv <<'EOF'
operation	scope	purpose
juicefs-mount	RUN-private /tmp/jfs-05-2-<RUN_ID>-<CELL>	apply the registered per-cell mount parameters
fio-randrw	existing /test_dir/rw_test.0.0..127.0	180s overwrite only; no file creation
juicefs-umount	RUN-private mount only	close each cell
juicefs-gc	existing juicefs-prod volume	return the same volume to the registered recovery gate
ceph-osd-set-noscrub	global Ceph flag during each Phase only	remove scheduled scrub as a noise source; exact state-driven restore
ceph-osd-set-nodeep-scrub	global Ceph flag during each Phase only	remove scheduled deep-scrub as a noise source; exact state-driven restore
EOF
  printf '# readonly command plan; no commands executed\n' >$d/readonly-command-plan.sh; chmod 0700 $d/readonly-command-plan.sh
}
verify_assets() {
  local path out; path=$1; out=$2; [[ -d $path/test_dir && ! -L $path/test_dir ]] || die asset_dir
  find -P "$path/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$out"
  [[ $(wc -l <"$out") -eq 128 ]] || die asset_count; awk -F '\t' '$3 != 1073741824 {bad=1} END{exit bad}' "$out" || die asset_size
}
mount_identity() {
  local mount out uploads fuse buffer meta; mount=$1; out=$2; uploads=$3; fuse=$4; buffer=$5; meta=$6
  findmnt -rn -M $mount -o SOURCE,TARGET,FSTYPE,OPTIONS >$out/findmnt.tsv
  grep -Fq "JuiceFS:juicefs-prod $mount fuse.juicefs" $out/findmnt.tsv || die mount_identity
  grep -Fq "Meta address: $meta" $out/juicefs.log || die mount_meta_log_identity
  python3 - "$JFS" "$uploads" "$fuse" "$buffer" "$METRICS" "$out/juicefs.log" >$out/mount-process.tsv <<'PY'
import hashlib, pathlib, os, sys
exe=os.path.realpath(sys.argv[1])
need=("--max-uploads "+sys.argv[2], "--max-fuse-io "+sys.argv[3],
      "--buffer-size "+sys.argv[4], "--cache-size 0", "--max-downloads 200",
      "--metrics "+sys.argv[5], "--log "+sys.argv[6])
rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if os.path.realpath(p/'exe') != exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace').strip()
        if any(x not in cmd for x in need): continue
        st=(p/'stat').read_text().split()
        rows.append((int(p.name),int(st[3]),int(st[21]),hashlib.md5((p/'exe').read_bytes()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError): pass
workers=[row[0] for row in rows if row[1] in {item[0] for item in rows}]
if len(rows)!=2 or len(workers)!=1:
    raise SystemExit('mount parent/worker identity is not unique')
print('pid\tppid\tstarttime_ticks\texe_md5\tis_worker\tcmdline')
for row in sorted(rows): print(*row[:4], 'yes' if row[0] in workers else 'no', row[4], sep='\t')
PY
}
health_gate() {
  local tag out; tag=$1; out=$ROOT/health-$1; mkdir -m 0700 -p "$out"
  ceph --conf $CEPH_CONF -s -f json >$out/status.json || die health_$tag
  ceph --conf $CEPH_CONF osd stat -f json >$out/osd-stat.json || die osd_$tag
  ceph --conf $CEPH_CONF pg dump pgs_brief >$out/pgs.txt || die pg_$tag
  python3 - $out/status.json $out/osd-stat.json $out/pgs.txt <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2])); h=s.get('health') or {}
checks=h.get('checks') or {}
if not (h.get('status') == 'HEALTH_OK' and not checks) and not (h.get('status') == 'HEALTH_WARN' and set(checks) == {'OSDMAP_FLAGS'}): raise SystemExit('health_not_ok')
if any(o.get(k) != o.get('num_osds') for k in ('num_up_osds','num_in_osds')) or o.get('num_osds') != 6: raise SystemExit('osd_not_6_up_in')
states=[]
for line in open(sys.argv[3]):
    f=line.split()
    if f and f[0][:1].isdigit() and len(f)>1: states.append(f[1])
if not states or any(x != 'active+clean' for x in states): raise SystemExit('pg_not_clean')
PY
}
recovery_gate() {
  local tag out stable prev_o prev_s; tag=$1; out=$ROOT/cells/$tag/recovery; stable=0; prev_o=; prev_s=; mkdir -m 0700 -p "$out"
  log_cmd env CEPH_CONF=$CEPH_CONF timeout $GC_TIMEOUT_SECONDS $JFS gc --compact --delete --threads 32 $META
  timeout $GC_TIMEOUT_SECONDS env CEPH_CONF=$CEPH_CONF $JFS gc --compact --delete --threads 32 $META >$out/gc.txt 2>$out/gc.stderr || die gc_failed_$tag
  printf 'sample\tobjects\tstored\tpending_150\tpending_151\tpending_152\n' >$out/gates.tsv
  for i in $(seq 1 180); do
    ceph --conf $CEPH_CONF df -f json >$out/ceph-df-$i.json || die ceph_df_$tag
    read -r objects stored < <(python3 - $out/ceph-df-$i.json <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); p=[p for p in d.get('pools',[]) if p.get('name')=='juicefs-data']
if len(p)!=1: raise SystemExit('juicefs-data pool missing')
s=p[0].get('stats',{}); print(int(s['objects']),int(s['stored']))
PY
    ) || die pool_stats
    for host in 150 151 152; do curl -fsS --connect-timeout 3 --max-time 5 http://10.20.1.$host:20180/metrics >$out/tikv-$i-$host.prom || die tikv_metrics; done
    p1=$(awk '/^tikv_engine_pending_compaction_bytes(\{|$)/{s+=$2;n++}END{if(!n)exit 1;printf "%.0f",s}' $out/tikv-$i-150.prom) || die pending
    p2=$(awk '/^tikv_engine_pending_compaction_bytes(\{|$)/{s+=$2;n++}END{if(!n)exit 1;printf "%.0f",s}' $out/tikv-$i-151.prom) || die pending
    p3=$(awk '/^tikv_engine_pending_compaction_bytes(\{|$)/{s+=$2;n++}END{if(!n)exit 1;printf "%.0f",s}' $out/tikv-$i-152.prom) || die pending
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' $i $objects $stored $p1 $p2 $p3 >>$out/gates.tsv
    if [[ $p1 == 0 && $p2 == 0 && $p3 == 0 && -n $prev_o && $objects == $prev_o ]] && awk -v a=$stored -v b=$prev_s 'BEGIN{d=a-b;if(d<0)d=-d;exit d<=16777216?0:1}'; then stable=$((stable+1)); else stable=0; fi
    prev_o=$objects; prev_s=$stored
    (( stable >= 3 )) && { printf RECOVERY_GATE_PASS >$out/PASS; return; }; sleep 10
  done; die recovery_timeout
}
sample_metrics() { local cell phase; cell=$1; phase=$2; curl -fsS --max-time 5 http://$METRICS/metrics >$ROOT/cells/$cell/mechanism-$phase.prom || die metrics; }
sampler_stop() { local rc=0; [[ -n $ACTIVE_SAMPLER_STOP ]] && printf STOP >$ACTIVE_SAMPLER_STOP || :; if [[ -n $ACTIVE_SAMPLER_PID ]]; then wait $ACTIVE_SAMPLER_PID 2>/dev/null || rc=$?; fi; ACTIVE_SAMPLER_PID=; ACTIVE_SAMPLER_STOP=; return $rc; }
sampler_start() { local cell stop dir; cell=$1; stop=$ROOT/cells/$cell/sampler.stop; dir=$ROOT/cells/$cell/mechanism; mkdir -m 0700 -p "$dir"; : >"$stop"; ACTIVE_SAMPLER_STOP=$stop; ( while ! grep -Fqx STOP "$stop" 2>/dev/null; do local epoch; epoch=$(date +%s%N); curl -fsS --max-time 5 http://$METRICS/metrics >"$dir/$epoch.prom" || exit 1; sleep 1; done ) & ACTIVE_SAMPLER_PID=$!; }
mount_cell() {
  local cell uploads fuse buffer out mnt; cell=$1; uploads=$2; fuse=$3; buffer=$4; out=$ROOT/cells/$cell; mnt=/tmp/jfs-05-2-$RUN_ID-$cell
  [[ ! -e $mnt && $mnt != / && ! -L $mnt ]] || die unsafe_mount; mkdir -m 0700 -p $out $mnt
  [[ -n $METRICS ]] || die metrics_endpoint_unset
  if ss -H -ltn "sport = :${METRICS##*:}" | grep -q .; then die metrics_port_busy; fi
  log_cmd env CEPH_CONF=$CEPH_CONF $JFS mount -d --max-uploads $uploads --max-fuse-io $fuse --buffer-size $buffer --max-downloads 200 --cache-size 0 --metrics $METRICS --log $out/juicefs.log $META $mnt
  timeout 180 env CEPH_CONF=$CEPH_CONF $JFS mount -d --max-uploads $uploads --max-fuse-io $fuse --buffer-size $buffer --max-downloads 200 --cache-size 0 --metrics $METRICS --log $out/juicefs.log $META $mnt >$out/mount.stdout 2>$out/mount.stderr
  for _ in $(seq 1 120); do mountpoint -q $mnt && break; sleep 1; done; mountpoint -q $mnt || die mount_failed; mount_identity $mnt $out $uploads $fuse $buffer $META; printf '%s\n' $mnt >$out/mount.path
  for _ in $(seq 1 30); do curl -fsS --max-time 2 http://$METRICS/metrics >$out/metrics-ready.prom && return; sleep 1; done
  die metrics_not_ready
}
graceful_umount() { local cell=$1; local mnt; mnt=$(cat $ROOT/cells/$cell/mount.path); log_cmd timeout 300 $JFS umount $mnt; timeout 300 $JFS umount $mnt >$ROOT/cells/$cell/umount.stdout 2>$ROOT/cells/$cell/umount.stderr || die umount; for _ in $(seq 1 180); do mountpoint -q $mnt || break; sleep 1; done; mountpoint -q $mnt && die mount_still_present; rmdir $mnt; }
run_fio() {
  local cell bs path out rc sampler_rc; cell=$1; bs=$2; path=$3; out=$ROOT/cells/$cell/formal; mkdir -m 0700 -p $out/bw
  cat >$out/fio.job <<EOF
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
log_avg_msec=1000
per_job_logs=0
write_bw_log=$out/bw/randrw
filename_format=$path/test_dir/rw_test.\$jobnum.0
[job]
EOF
  log_cmd $FIO $out/fio.job --output=$out/fio.json --output-format=json+; date +%s%N >$out/fio-start-epoch-ns.txt
  set +e; timeout 240 $FIO $out/fio.job --output=$out/fio.json --output-format=json+; rc=$?; set -e; date +%s%N >$out/fio-end-epoch-ns.txt; set +e; sampler_stop; sampler_rc=$?; set -e; printf '%s\n' $rc >$out/fio.rc; printf '%s\n' $sampler_rc >$out/sampler.rc
  ((rc==0)) || die fio_failed; ((sampler_rc==0)) || die sampler_failed; [[ $(find $ROOT/cells/$cell/mechanism -type f -name '*.prom' | wc -l) -ge 30 ]] || die sampler_window_gap; [[ -s $out/fio.json ]] || die fio_json_missing
}
run_cell() {
  local pos cell bs arm uploads fuse buffer scope out path; pos=$1; cell=$2; bs=$3; arm=$4; uploads=$5; fuse=$6; buffer=$7; scope=$8; out=$ROOT/cells/$cell; path=$REF
  METRICS=127.0.0.1:$((19520 + pos))
  [[ ! -e $out ]] || die cell_exists; mkdir -m 0700 -p $out; printf '%s\n' $scope >$out/effect-scope.txt; printf '%s\t%s\t%s\t%s\t%s\t%s\n' $pos $cell $uploads $fuse $buffer $scope >$out/parameters.tsv; event $cell START
  health_gate pre-$cell; mount_cell $cell $uploads $fuse $buffer; path=$(cat $out/mount.path)
  verify_assets $path $out/assets-before.tsv; sample_metrics $cell pre; sampler_start $cell; run_fio $cell $bs $path; sample_metrics $cell post; verify_assets $path $out/assets-after.tsv; cmp -s $out/assets-before.tsv $out/assets-after.tsv || die assets_changed
  graceful_umount $cell; recovery_gate $cell-post; health_gate post-$cell; event $cell RAW_PASS
}
phase_a() {
  require_online_ack; [[ ! -e $ROOT/PHASE_A_PASS ]] || die phase_a_exists; mkdir -m 0700 -p $ROOT $ROOT/cells $ROOT/inventory; : >$ROOT/commands.sh
  verify_assets $REF $ROOT/inventory/assets.tsv; [[ -x $JFS && $(md5sum $JFS|awk '{print $1}') == $JFS_MD5 ]] || die juicefs_identity
  findmnt -rn -M $REF -o SOURCE,TARGET,FSTYPE,OPTIONS >$ROOT/inventory/reference-findmnt.tsv; grep -Fq "JuiceFS:juicefs-prod $REF fuse.juicefs" $ROOT/inventory/reference-findmnt.tsv || die reference_mount_identity
  recovery_gate A-initial
  phase_a_rows | while IFS=$'\t' read -r pos cell bs arm uploads fuse buffer scope; do run_cell $pos $cell $bs $arm $uploads $fuse $buffer $scope; done; printf PHASE_A_PASS >$ROOT/PHASE_A_PASS
}
phase_b1() {
  require_online_ack; [[ -f $ROOT/PHASE_A_PASS ]] || die phase_a_required; [[ ! -e $ROOT/PHASE_B1_PASS ]] || die phase_b1_exists
  recovery_gate B1-initial
  phase_b1_rows | while IFS=$'\t' read -r pos cell bs arm uploads fuse buffer scope; do run_cell $pos $cell $bs $arm $uploads $fuse $buffer $scope; done; printf PHASE_B1_PASS >$ROOT/PHASE_B1_PASS
}
phase_b2() {
  require_online_ack
  [[ ${T052_B2_GATE_ACK-} == I_ACK_05_2_B2_TRIGGERED_$RUN_ID ]] || die b2_gate_ack_missing
  [[ -f $ROOT/PHASE_B1_PASS ]] || die phase_b1_required
  [[ ! -e $ROOT/PHASE_B2_PASS ]] || die phase_b2_exists
  [[ -s $ROOT/analysis/B1-mechanism.json ]] || die b1_analysis_missing
  python3 - "$ROOT/analysis/B1-mechanism.json" <<'PY' || die b1_proximity_gate_not_triggered
import json,sys
rows=[x for x in json.load(open(sys.argv[1]))['cells'] if x['cell']=='B1']
raise SystemExit(0 if len(rows)==1 and rows[0]['uploading_p95'] >= 120 else 1)
PY
  phase_b2_rows | while IFS=$'\t' read -r pos cell bs arm uploads fuse buffer scope; do run_cell $pos $cell $bs $arm $uploads $fuse $buffer $scope; done
  printf PHASE_B2_PASS >$ROOT/PHASE_B2_PASS
}
offline_self_test() {
  [[ $(phase_a_rows | wc -l) -eq 4 && $(phase_b1_rows | wc -l) -eq 1 && $(phase_b2_rows | wc -l) -eq 4 ]] || die matrix_count
  [[ $(phase_a_rows | awk -F '\t' '$5==150&&$6=="1M"&&$7==300{n++}END{print n}') -eq 2 ]] || die phase_a_controls
  [[ $(phase_a_rows | awk -F '\t' '$5==300&&$6=="1M"&&$7==300{n++}END{print n}') -eq 2 ]] || die phase_a_treatments
  [[ $(phase_a_rows | awk -F '\t' '{print $2}' | paste -sd, -) == C1,T1,T2,C2 ]] || die phase_a_order
  [[ $(phase_b1_rows | awk -F '\t' '$3=="256K"&&$5==150&&$6=="256K"&&$7==300&&$8=="EXCLUDED"{n++}END{print n}') -eq 1 ]] || die b1_contract
  [[ $(fixture_mount_rows | wc -l) -eq 4 ]] || die mount_fixture_count
  [[ $(fixture_mount_rows | awk -F '\t' '$2=="C1"&&$3==150&&$4=="1M"&&$5==300{n++}END{print n}') -eq 1 ]] || die mount_fixture_c1
  [[ $(fixture_mount_rows | awk -F '\t' '$2=="T1"&&$3==300&&$4=="1M"&&$5==300{n++}END{print n}') -eq 1 ]] || die mount_fixture_t1
  [[ $(fixture_mount_rows | awk -F '\t' '$2=="T2"&&$3==300&&$4=="1M"&&$5==300{n++}END{print n}') -eq 1 ]] || die mount_fixture_t2
  [[ $(fixture_mount_rows | awk -F '\t' '$2=="C2"&&$3==150&&$4=="1M"&&$5==300{n++}END{print n}') -eq 1 ]] || die mount_fixture_c2
  fixture_mount_rows
  [[ $(phase_b2_rows | awk -F '\t' '{print $2}' | paste -sd, -) == B2-C1,B2-T1,B2-T2,B2-C2 ]] || die b2_order
  printf 'T052_DRIVER_SELF_TEST_PASS\tphase_a=4_unique\tphase_b1=1_excluded\tphase_b2=4_gated\tphase_c=absent\n'
}
bundle() { valid_run; [[ -d $ROOT ]] || die root_missing; mkdir -m 0700 -p $ROOT/bundle; find "$ROOT" -type f ! -path "$ROOT/bundle/*" -print0 | sort -z | xargs -0 sha256sum >$ROOT/bundle/SHA256SUMS; }
case $MODE in --self-test) offline_self_test;; plan) valid_run; write_plans $OUT; printf 'T052_PLAN_ONLY_PASS\troot=%s\n' $OUT;; phase-a) phase_a;; phase-b1) phase_b1;; phase-b2) phase_b2;; bundle) bundle;; *) printf 'usage: %s --self-test|plan|phase-a|phase-b1|phase-b2|bundle RUN_ID\n' "$0" >&2; exit 2;; esac
