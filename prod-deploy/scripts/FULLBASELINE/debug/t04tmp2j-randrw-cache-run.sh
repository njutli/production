#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
MODE=${1:-}; RUN_ID=${2:-}; CELL=${3:-}
ROOT=/tmp/production/opencode-04tmp2j-$RUN_ID
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REF=/mnt/juicefs; CACHE_PARENT=/mnt/jfs-cache
CACHE_ROOT=$CACHE_PARENT/jfs-04tmp2j-$RUN_ID
CEPH_CONF=$ROOT/inventory/ceph.conf
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
METRICS_ADDR=127.0.0.1:9568
SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SCRUB_CONTROL=$SELF_DIR/u141d-scrub-control.sh
ANALYZER=$SELF_DIR/t04tmp2j-randrw-cache-analyze.py
die(){ printf 'E_04TMP2J\\t%s\\n' "$*" >&2; exit 42; }
valid_run(){
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == /tmp/production/opencode-04tmp2j-$RUN_ID && $ROOT != / && ! -L $ROOT ]] || die unsafe_result_root
  [[ $CACHE_ROOT == /mnt/jfs-cache/jfs-04tmp2j-$RUN_ID && $CACHE_ROOT != / && ! -L $CACHE_ROOT ]] || die unsafe_cache_root
  if [[ -e $ROOT ]]; then [[ -d $ROOT && $(stat -Lc %u "$ROOT") == 1002 && $(stat -Lc %g "$ROOT") == 1002 && $(stat -Lc %a "$ROOT") == 700 ]] || die root_identity; fi
}
cell_spec(){
  case $CELL in
    A0-pre|A0-mid|A0-post) CACHE_MIB=0; CACHE_DIR= ;;
    C32) CACHE_MIB=32768; CACHE_DIR=$CACHE_ROOT/cache-C32 ;;
    C64) CACHE_MIB=65536; CACHE_DIR=$CACHE_ROOT/cache-C64 ;;
    C96) CACHE_MIB=98304; CACHE_DIR=$CACHE_ROOT/cache-C96 ;;
    C128) CACHE_MIB=131072; CACHE_DIR=$CACHE_ROOT/cache-C128 ;;
    C256) CACHE_MIB=262144; CACHE_DIR=$CACHE_ROOT/cache-C256 ;;
    *) die "invalid cell: $CELL" ;;
  esac
  JFS_MNT=/tmp/jfs-04tmp2j-mnt-$RUN_ID-$CELL; CELL_ROOT=$ROOT/cells/$CELL
  [[ $JFS_MNT == /tmp/jfs-04tmp2j-mnt-$RUN_ID-$CELL && $JFS_MNT != / && ! -L $JFS_MNT ]] || die unsafe_mount_path
  [[ $CELL_ROOT == $ROOT/cells/$CELL && $CELL_ROOT != / ]] || die unsafe_cell_path
  [[ -z $CACHE_DIR || $CACHE_DIR == $CACHE_ROOT/cache-$CELL ]] || die unsafe_cache_path
}
matrix(){ printf '%s\\n' A0-pre C32 C128 C64 A0-mid C256 C96 A0-post; }
log_cmd(){ printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\\n' >>"$ROOT/commands.sh"; }
metric(){ awk -v n="$2" '$1 ~ ("^" n "($|\\\\{)") {s+=$(NF);f=1} END{if(f)printf "%.0f",s;else print "NA"}' <<<"$1"; }
metrics_ok(){ local t=$1 n; for n in juicefs_blockcache_bytes juicefs_blockcache_blocks juicefs_blockcache_hits juicefs_blockcache_miss juicefs_blockcache_hit_bytes juicefs_blockcache_miss_bytes juicefs_blockcache_write_bytes juicefs_blockcache_evicts juicefs_blockcache_drops; do [[ $(metric "$t" "$n") != NA ]] || die "metric_missing:$n"; done; }
assets(){
  local out=$1 base=$2; [[ -d $base/test_dir && ! -L $base/test_dir ]] || die assets_dir_missing
  find "$base/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\\t%i\\t%s\\n' | sort -V >"$out"
  [[ $(wc -l <"$out") == 128 ]] || die asset_count
  awk -F '\\t' '$3 != 1073741824 {bad=1} END{exit bad}' "$out" || die asset_size
}
ceph_nic(){ ip route get 10.3.1.6 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
health(){
  local out=$1; mountpoint -q "$REF" || die reference_mount_missing
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  for h in 10.20.1.150 10.20.1.151 10.20.1.152; do curl -fsS --connect-timeout 3 --max-time 5 http://$h:20180/metrics >/dev/null || die tikv_metrics; done
  CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$out/ceph-status.json" || die ceph_status
  python3 - "$out/ceph-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if d.get('health',{}).get('status')!='HEALTH_OK': raise SystemExit('HEALTH_NOT_OK')
p=d.get('pgmap',{}).get('pgs_by_state',[])
if not p or any(x.get('state_name')!='active+clean' for x in p): raise SystemExit('PG_NOT_CLEAN')
PY
  local nic=$(ceph_nic); [[ -n $nic && -r /sys/class/net/$nic/statistics/rx_bytes ]] || die ceph_nic_missing
  printf '%s\\n' "$nic" >"$out/ceph-data-nic.txt"
}
mount_pid_gate(){
  python3 - "$JFS" "$CELL_ROOT/pids-pre.txt" "$CACHE_DIR" "$CACHE_MIB" "$METRICS_ADDR" <<'PY'
import os,sys
exe,old,cache,tier,metrics=sys.argv[1:]; exe=os.path.realpath(exe); old={int(x) for x in open(old) if x.strip().isdigit()}; rows=[]
for p in os.listdir('/proc'):
    if not p.isdigit() or int(p) in old: continue
    try:
        if os.path.realpath('/proc/'+p+'/exe')!=exe: continue
        cmd=open('/proc/'+p+'/cmdline','rb').read().replace(b'\\0',b' ').decode(errors='replace').strip()
        st=open('/proc/'+p+'/stat').read().split(); rows.append((int(p),int(st[3]),int(st[21]),cmd))
    except (OSError,ValueError): pass
if len(rows)!=2: raise SystemExit(f'parent/worker count: {rows}')
ids={x[0] for x in rows}; w=[x for x in rows if x[1] in ids]
if len(w)!=1: raise SystemExit(f'parent/worker topology: {rows}')
req=['--max-uploads 150','--max-fuse-io 256K',f'--metrics {metrics}']
req += [f'--cache-dir {cache}',f'--cache-size {tier}','--free-space-ratio 0.20'] if cache else ['--cache-size 0']
if any(x in w[0][3] for x in ('--writeback','--prefetch','--max-readahead')): raise SystemExit('forbidden mount option')
if [x for x in req if x not in w[0][3]]: raise SystemExit('mount argv contract')
print('pid\\tppid\\tstarttime\\tselected_worker\\tcmdline')
for x in sorted(rows): print(*x[:3],int(x[0]==w[0][0]),x[3],sep='\\t')
PY
}
process_gone(){
  python3 - "$JFS" "$CELL_ROOT/mount-process.tsv" <<'PY'
import csv,os,sys
exe=os.path.realpath(sys.argv[1])
for r in csv.DictReader(open(sys.argv[2]),delimiter='\\t'):
 try:
  if os.path.realpath('/proc/'+r['pid']+'/exe')==exe and open('/proc/'+r['pid']+'/stat').read().split()[21]==r['starttime']: raise SystemExit(1)
 except OSError: pass
PY
}
snapshot(){
  local label=$1 t; t=$(curl -fsS --max-time 5 http://$METRICS_ADDR/metrics) || die metrics_fetch; metrics_ok "$t"; printf '%s\\n' "$t" >"$CELL_ROOT/metrics-$label.txt"
  if [[ -n $CACHE_DIR ]]; then find "$CACHE_DIR" -xdev -type f -printf '%s\\n' 2>/dev/null | awk '{n++;s+=$1}END{printf "files=%d\\tbytes=%d\\n",n+0,s+0}' >"$CELL_ROOT/cache-usage-$label.tsv"; else printf 'files=0\\tbytes=0\\n' >"$CELL_ROOT/cache-usage-$label.tsv"; fi
}
sampler(){
  local stop=$1 out=$2 nic=$3 t; printf 'epoch_ns\\tdf_used\\tdf_avail\\trx_bytes\\ttx_bytes\\tcache_bytes\\tcache_blocks\\thit_bytes\\tmiss_bytes\\tevicts\\tdrops\\n' >"$out"
  while [[ ! -e $stop ]]; do t=$(curl -fsS --max-time 5 http://$METRICS_ADDR/metrics || true); printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$(date +%s%N)" "$(df -B1 --output=used "$CACHE_PARENT"|awk 'NR==2{print $1}')" "$(df -B1 --output=avail "$CACHE_PARENT"|awk 'NR==2{print $1}')" "$(cat /sys/class/net/$nic/statistics/rx_bytes)" "$(cat /sys/class/net/$nic/statistics/tx_bytes)" "$(metric "$t" juicefs_blockcache_bytes)" "$(metric "$t" juicefs_blockcache_blocks)" "$(metric "$t" juicefs_blockcache_hit_bytes)" "$(metric "$t" juicefs_blockcache_miss_bytes)" "$(metric "$t" juicefs_blockcache_evicts)" "$(metric "$t" juicefs_blockcache_drops)" >>"$out"; sleep 1; done
}
write_job(){
  local out=$1 logdir=$2
  printf '%s\\n' '[global]' 'ioengine=libaio' 'iodepth=128' 'direct=1' 'bs=256K' 'rw=randrw' 'rwmixread=50' 'size=1G' 'numjobs=128' 'openfiles=128' 'allow_file_create=0' 'create_on_open=0' 'fallocate=none' 'time_based=1' 'runtime=180' 'randrepeat=1' 'randseed=20260907' 'group_reporting=0' "write_bw_log=$logdir/bw/randrw" 'per_job_logs=1' 'log_avg_msec=1000' "filename_format=$JFS_MNT/test_dir/rw_test.\\\$jobnum.0" '[job]' >"$out"
}
run_fio(){
  local out=$1 ro=${2:-}; mkdir -m 0700 -p "$out/bw"; write_job "$out/fio.job" "$out"; local -a c=(fio "$out/fio.job" --output="$out/fio.json" --output-format=json); [[ -n $ro ]] && c=(fio --readonly "$out/fio.job" --output="$out/fio.json" --output-format=json); log_cmd "${c[@]}"; date +%s%N >"$out/fio-start-ns.txt"; set +e; "${c[@]}"; local rc=$?; date +%s%N >"$out/fio-end-epoch-ns.txt"; set -e; printf '%s\\n' "$rc" >"$out/fio.rc"; ((rc==0)) || return "$rc"; [[ $(find "$out/bw" -maxdepth 1 -type f -name 'randrw_bw.*.log'|wc -l) == 128 ]] || die bw_log_count; python3 - "$out/fio.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); j=d.get('jobs',[])
if len(j)!=128 or any(int(x.get('error',-1))!=0 for x in j): raise SystemExit('fio contract')
PY
}
mount_jfs(){
  mkdir -m 0700 "$JFS_MNT"; : >"$CELL_ROOT/pids-pre.txt"; for p in /proc/[0-9]*; do [[ -e $p/exe && $(realpath "$p/exe" 2>/dev/null)=="$JFS" ]] && basename "$p" >>"$CELL_ROOT/pids-pre.txt" || true; done
  local -a c=($JFS mount -d --max-uploads 150 --max-fuse-io 256K); if [[ -n $CACHE_DIR ]]; then [[ -d $CACHE_DIR && ! -L $CACHE_DIR ]] || die cache_dir_missing; [[ -z $(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] || die cache_not_empty; c+=(--cache-dir "$CACHE_DIR" --cache-size "$CACHE_MIB" --free-space-ratio 0.20); else c+=(--cache-size 0); fi; c+=(--metrics "$METRICS_ADDR" "$META" "$JFS_MNT"); log_cmd env "CEPH_CONF=$CEPH_CONF" "${c[@]}"; CEPH_CONF="$CEPH_CONF" "${c[@]}" >"$CELL_ROOT/mount.stdout" 2>"$CELL_ROOT/mount.stderr"; for _ in $(seq 1 120); do mountpoint -q "$JFS_MNT" && break; sleep 1; done; mountpoint -q "$JFS_MNT" || die mount_timeout; findmnt -rn -M "$JFS_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$CELL_ROOT/jfs-findmnt.tsv"; grep -Fq "JuiceFS:juicefs-prod $JFS_MNT fuse.juicefs" "$CELL_ROOT/jfs-findmnt.tsv" || die mount_identity; mount_pid_gate >"$CELL_ROOT/mount-process.tsv" || die mount_process_identity
}
umount_jfs(){
  log_cmd "$JFS" umount "$JFS_MNT"; "$JFS" umount "$JFS_MNT" >"$CELL_ROOT/umount.stdout" 2>"$CELL_ROOT/umount.stderr" || die umount_failed; for _ in $(seq 1 180); do ! mountpoint -q "$JFS_MNT" && break; sleep 1; done; mountpoint -q "$JFS_MNT" && die mount_remains; for _ in $(seq 1 60); do process_gone && break; sleep 1; done; process_gone || die process_remains; rmdir "$JFS_MNT"
}
cleanup_cache(){
  [[ -z $CACHE_DIR ]] && return 0; [[ -d $CACHE_DIR && $CACHE_DIR == $CACHE_ROOT/cache-$CELL && ! -L $CACHE_DIR ]] || die cleanup_cache_path; [[ -z $(findmnt -rn -M "$CACHE_DIR" -o TARGET 2>/dev/null) ]] || die cache_is_mount; find "$CACHE_DIR" -xdev -depth -mindepth 1 -delete; [[ -z $(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] || die cache_not_empty; rmdir "$CACHE_DIR"
}
run_cell(){
  valid_run; cell_spec; [[ ${T04TMP2J_ACK:-} == I_ACK_04TMP2J_$RUN_ID ]] || die ack_missing; [[ -f $ROOT/plans/PASS ]] || die plan_missing; sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift; [[ ! -e $CELL_ROOT ]] || die cell_exists; mkdir -m 0700 -p "$CELL_ROOT/health-pre" "$CELL_ROOT/health-post"; pgrep -a -x fio >"$CELL_ROOT/foreign-fio.tsv" 2>&1 && die foreign_fio || true; health "$CELL_ROOT/health-pre"; [[ $(findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS) == $(<"$ROOT/inventory/cache-parent.freeze") ]] || die cache_parent_drift; if [[ -n $CACHE_DIR ]]; then [[ -d $CACHE_ROOT && ! -L $CACHE_ROOT ]] || die cache_root_missing; mkdir -m 0700 "$CACHE_DIR"; fi; printf 'cell\\t%s\\ncache_mib\\t%s\\njfs_mount\\t%s\\n' "$CELL" "$CACHE_MIB" "$JFS_MNT" >"$CELL_ROOT/state.tsv"; assets "$CELL_ROOT/assets-pre.tsv" "$REF"; mount_jfs; snapshot mounted; if [[ -n $CACHE_DIR ]]; then run_fio "$CELL_ROOT/warmup" readonly; snapshot warmed; fi; local nic=$(<"$CELL_ROOT/health-pre/ceph-data-nic.txt") stop=$CELL_ROOT/sampler.stop sp fio_rc sampler_rc; sampler "$stop" "$CELL_ROOT/runtime.tsv" "$nic" & sp=$!; if run_fio "$CELL_ROOT/formal"; then fio_rc=0; else fio_rc=$?; fi; : >"$stop"; wait "$sp" && sampler_rc=0 || sampler_rc=$?; printf '%s\\n' "$sampler_rc" >"$CELL_ROOT/sampler.rc"; ((fio_rc==0 && sampler_rc==0)) || die fio_sampler_failed; grep -Eq $'\\tNA(\\t|$)' "$CELL_ROOT/runtime.tsv" && die sampler_metric_missing || true; snapshot formal; assets "$CELL_ROOT/assets-post.tsv" "$JFS_MNT"; cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post.tsv" || die asset_identity_drift; health "$CELL_ROOT/health-post"; umount_jfs; cleanup_cache; printf 'CELL_PASS\\t%s\\n' "$CELL" >"$CELL_ROOT/PASS"
}
inventory(){
  valid_run; [[ ! -e $ROOT ]] || die result_exists; [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT ]] || die cache_parent_missing; mkdir -p "$ROOT" "$ROOT/inventory" "$ROOT/plans" "$ROOT/cells"; chmod 700 "$ROOT"; [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die jfs_identity; mkdir -p "$ROOT/inventory"; cp /etc/ceph/ceph.conf "$CEPH_CONF"; printf '\\n[client]\\n\\tms_async_op_threads = 8\\n' >>"$CEPH_CONF"; [[ $(md5sum "$CEPH_CONF"|awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die ceph_conf_identity; "$JFS" version >"$ROOT/inventory/juicefs-version.txt"; findmnt -rn -M "$REF" >"$ROOT/inventory/reference-mount.tsv"; assets "$ROOT/inventory/assets.tsv" "$REF"; findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$ROOT/inventory/cache-parent.freeze"; [[ $(findmnt -rn -T "$CACHE_PARENT" -o FSTYPE) == ext4 ]] || die cache_not_ext4; df -B1 "$CACHE_PARENT" >"$ROOT/inventory/cache-df.tsv"; df -i "$CACHE_PARENT" >"$ROOT/inventory/cache-dfi.tsv"; ceph_nic >"$ROOT/inventory/ceph-data-nic.txt"; ceph -s --format json >"$ROOT/inventory/ceph-status.json"; printf 'INVENTORY_PASS\\n' >"$ROOT/inventory/PASS"
}
plan(){
  valid_run; [[ -f $ROOT/inventory/PASS ]] || die inventory_missing; printf 'cell\\tcache_mib\\tcache_fraction\\tcache_dir\\nA0-pre\\t0\\t0\\tNONE\\nC32\\t32768\\t0.25\\tRUN/cache-C32\\nC128\\t131072\\t1.00\\tRUN/cache-C128\\nC64\\t65536\\t0.50\\tRUN/cache-C64\\nA0-mid\\t0\\t0\\tNONE\\nC256\\t262144\\t2.00\\tRUN/cache-C256\\nC96\\t98304\\t0.75\\tRUN/cache-C96\\nA0-post\\t0\\t0\\tNONE\\n' >"$ROOT/plans/cells.tsv"; matrix|paste -sd, - >"$ROOT/plans/matrix-order.txt"; cat >"$ROOT/plans/sudo-contract.txt" <<EOF
sudo ceph -c $CEPH_CONF --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set noscrub
sudo ceph -c $CEPH_CONF --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set nodeep-scrub
sudo install -d -m 0700 -o 1002 -g 1002 $CACHE_ROOT
sudo rmdir $CACHE_ROOT
sudo ceph -c $CEPH_CONF --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset nodeep-scrub
sudo ceph -c $CEPH_CONF --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset noscrub
EOF
  sha256sum "$0" "$ANALYZER" "$SELF_DIR/t04tmp2j-randrw-cache-gate0-offline.sh" "$SCRUB_CONTROL" >"$ROOT/plans/scripts.sha256"; printf 'PLAN_PASS\\n' >"$ROOT/plans/PASS"
}
execute_all(){
  valid_run; [[ ${T04TMP2J_ACK:-} == I_ACK_04TMP2J_$RUN_ID ]] || die ack_missing; [[ -f $ROOT/plans/PASS ]] || die plan_missing; mkdir -p "$ROOT"; : >"$ROOT/commands.sh"; local scrub=0; trap 'rc=$?; if ((scrub)); then restore_scrub || printf "SCRUB_RESTORE_FAIL\\n" >"$ROOT/INCIDENT-SCRUB-RESTORE"; fi; exit $rc' EXIT; pause_scrub; scrub=1; for CELL in $(matrix); do run_cell; done; restore_scrub; scrub=0; health "$ROOT/health-post"; printf 'EXECUTE_PASS\\n' >"$ROOT/PASS"; trap - EXIT
}
pause_scrub(){ mkdir -m 0700 -p "$ROOT/scrub"; U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$ROOT/scrub" bash "$SCRUB_CONTROL" pause "$RUN_ID" "$(<"$ROOT/inventory/fsid.txt")" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE; U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$ROOT/scrub" bash "$SCRUB_CONTROL" verify-paused "$RUN_ID" >"$ROOT/scrub/verify-paused.txt"; }
restore_scrub(){ U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$ROOT/scrub" bash "$SCRUB_CONTROL" restore "$RUN_ID" >"$ROOT/scrub/restore.txt"; U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$ROOT/scrub" bash "$SCRUB_CONTROL" verify-restored "$RUN_ID" >"$ROOT/scrub/verify-restored.txt"; }
offline_self_test(){ valid_run; local n=0 c; for c in $(matrix); do CELL=$c; cell_spec; n=$((n+1)); done; [[ $n == 8 ]] || die matrix_contract; grep -Fq 'rw=randrw' "$0"; grep -Fq 'rwmixread=50' "$0"; grep -Fq 'log_avg_msec=1000' "$0"; printf '04TMP2J_OFFLINE_SELF_TEST_PASS cells=%s\\n' "$n"; }
case $MODE in inventory) inventory ;; plan) plan ;; run-cell) run_cell ;; execute-all) execute_all ;; offline-self-test) offline_self_test ;; inspect-cell) valid_run; cell_spec; printf 'CELL=%s\\nMOUNT=%s\\nCACHE=%s\\n' "$CELL" "$JFS_MNT" "${CACHE_DIR:-NONE}" ;; *) printf 'usage: %s inventory|plan|run-cell|execute-all|offline-self-test|inspect-cell RUN_ID [CELL]\\n' "$0"; exit 2 ;; esac
