#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

MODE=${1:-}; RUN_ID=${2:-}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=/tmp/production/opencode-04tmp3i-$RUN_ID
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REF=/mnt/juicefs
ASSET_REL=/test_dir/seqread/seqread.0.0
ASSET=$REF$ASSET_REL
CACHE_PARENT=/mnt/jfs-cache
BACKING_ROOT=$CACHE_PARENT/jfs-04tmp3i-$RUN_ID
BACKING=$BACKING_ROOT/t64.img
CACHE_MNT=/tmp/jfs-04tmp3i-cache-$RUN_ID
CACHE_DIR=$CACHE_MNT/cache
CEPH_CONF=$ROOT/inventory/ceph-msgr8.conf
EXPECTED_UID=1002; EXPECTED_GID=1002
BACKING_BYTES=68719476736

die(){ printf 'E_04TMP3I\t%s\n' "$*" >&2; exit 42; }
record(){ printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }
valid(){
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_run_id
  [[ $ROOT == "/tmp/production/opencode-04tmp3i-$RUN_ID" && $ROOT != / && $ROOT != *..* ]] || die unsafe_root
  [[ $BACKING_ROOT == "/mnt/jfs-cache/jfs-04tmp3i-$RUN_ID" && $BACKING == "$BACKING_ROOT/t64.img" ]] || die unsafe_backing
  [[ $CACHE_MNT == "/tmp/jfs-04tmp3i-cache-$RUN_ID" && $CACHE_MNT != /tmp ]] || die unsafe_cache_mount
  [[ ! -L $ROOT && ! -L $BACKING_ROOT && ! -L $CACHE_MNT ]] || die symlink_scope
}
matrix(){ cat <<'EOF'
cell	arm	max_readahead	warm_s	formal_s	purpose
LOCAL1	LOCAL	-	0	60	loop-ext4-direct
A1	A	8M	60	60	anchor-pre
B1	B	32M	60	60	ra32-confirm-1
B2	B	32M	60	60	ra32-confirm-2
A2	A	8M	60	60	anchor-post
EOF
}
cell_fields(){
  local cell=$1
  case $cell in A1) RA=8M; PORT=9581;; B1) RA=32M; PORT=9582;; B2) RA=32M; PORT=9583;; A2) RA=8M; PORT=9584;; *) die invalid_cell;; esac
  CELL_ROOT=$ROOT/cells/$cell; JFS_MNT=/tmp/jfs-04tmp3i-mnt-$RUN_ID-$cell
  [[ $JFS_MNT == "/tmp/jfs-04tmp3i-mnt-$RUN_ID-$cell" && $JFS_MNT != /tmp ]] || die unsafe_jfs_mount
  [[ ! -L $CELL_ROOT && ! -L $JFS_MNT ]] || die symlink_cell
}
asset_fingerprint(){
  local base=$1 out=$2 p
  p=$base$ASSET_REL
  [[ -f $p && ! -L $p && $(stat -c %s "$p") == 34359738368 ]] || die asset_identity
  printf 'path\tinode\tbytes\tblocks\tmtime\thead_sha256\ttail_sha256\n' >"$out"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ASSET_REL" "$(stat -c %i "$p")" "$(stat -c %s "$p")" "$(stat -c %b "$p")" "$(stat -c %Y "$p")" "$(head -c 1048576 "$p"|sha256sum|awk '{print $1}')" "$(tail -c 1048576 "$p"|sha256sum|awk '{print $1}')" >>"$out"
}
health(){
  local out=$1; mkdir -m 0700 -p "$out"
  mountpoint -q "$REF" || die reference_mount_absent
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$out/ceph-status.json" || die ceph_status
  python3 - "$out/ceph-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); o=d.get('osdmap',{}).get('osdmap',d.get('osdmap',{}))
if any(o.get(k)!=6 for k in ('num_osds','num_up_osds','num_in_osds')): raise SystemExit('OSD identity')
states=[str(x.get('state_name','')) for x in d.get('pgmap',{}).get('pgs_by_state',[])]
if not states or any(s != 'active+clean' for s in states): raise SystemExit('PG not exactly active+clean')
if any(any(x in s for x in ('recover','backfill','degraded','peering','incomplete')) for s in states): raise SystemExit('PG recovery state')
if d.get('health',{}).get('status') != 'HEALTH_OK': raise SystemExit('Ceph health')
PY
}
loop_backing(){
  local loop=$1 name=${1##*/} v
  [[ $loop =~ ^/dev/loop[0-9]+$ && -r /sys/block/$name/loop/backing_file ]] || return 1
  v=$(<"/sys/block/$name/loop/backing_file"); [[ $v == /* && $v != / && $v != *..* ]] || return 1
  realpath -e "$v"
}
verify_loop(){
  local loop=$1 expected actual matches
  expected=$(realpath -e "$BACKING") || die backing_realpath
  actual=$(loop_backing "$loop") || die loop_backing_unavailable
  [[ $actual == "$expected" ]] || die loop_backing_mismatch
  matches=$(sudo losetup -j "$BACKING" | awk -F: '{print $1}')
  [[ $matches == "$loop" ]] || die loop_mapping_not_unique
}
mount_pid_gate(){
  local pre=$1
  python3 - "$JFS" "$pre" <<'PY'
import os,sys
exe=os.path.realpath(sys.argv[1]); old={int(x) for x in open(sys.argv[2]) if x.strip().isdigit()}; rows=[]
for p in os.listdir('/proc'):
 if not p.isdigit() or int(p) in old: continue
 try:
  if os.path.realpath('/proc/'+p+'/exe')!=exe: continue
  st=open('/proc/'+p+'/stat').read().split(); cmd=open('/proc/'+p+'/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace').strip()
  rows.append((int(p),int(st[3]),int(st[21]),cmd))
 except (OSError,ValueError): pass
ids={r[0] for r in rows}; workers=[r for r in rows if r[1] in ids]
if len(rows)!=2 or len(workers)!=1: raise SystemExit('mount PID topology '+repr(rows))
print('pid\tppid\tstarttime\tselected_worker\tcmdline')
for r in sorted(rows): print(r[0],r[1],r[2],int(r[0]==workers[0][0]),r[3],sep='\t')
PY
}
jfs_gone(){
  local pf=$1
  python3 - "$JFS" "$pf" <<'PY'
import csv,os,sys
exe=os.path.realpath(sys.argv[1])
for r in csv.DictReader(open(sys.argv[2]),delimiter='\t'):
 try:
  if os.path.realpath('/proc/'+r['pid']+'/exe')==exe and open('/proc/'+r['pid']+'/stat').read().split()[21]==r['starttime']: raise SystemExit(1)
 except OSError: pass
PY
}
metric(){ awk -v n="$2" '$1 ~ ("^" n "($|\\{)"){s+=$NF;f=1}END{if(f)printf "%.0f",s;else print "NA"}' "$1"; }

cmd_inventory(){
  valid; [[ ! -e $ROOT && ! -e $BACKING_ROOT && ! -e $CACHE_MNT ]] || die task_scope_exists
  mkdir -m 0700 -p "$ROOT"/{inventory,plans,cells,closure,scripts}; printf '#!/usr/bin/env bash\n# 04-tmp3i actual commands\n' >"$ROOT/commands.sh"
  printf 'epoch_ns\tcell\tevent\tdetail\n' >"$ROOT/incidents.tsv"
  printf 'epoch_iso\tstate\n%s\tINVENTORY_STARTED\n' "$(date -Iseconds)" >"$ROOT/run-state.tsv"
  command -v fio >"$ROOT/inventory/fio-path.txt"; fio --version >"$ROOT/inventory/fio-version.txt"
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die juicefs_identity
  [[ -f /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_identity
  sha256sum /etc/ceph/ceph.conf >"$ROOT/inventory/ceph-conf-source.sha256"
  cp /etc/ceph/ceph.conf "$CEPH_CONF"; printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
  CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$ROOT/inventory/volume-status.json"
  python3 - "$ROOT/inventory/volume-status.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('Setting') or {}
if s.get('Name')!='juicefs-prod' or str(s.get('BlockSize')) not in {'256','256K','262144'} or not s.get('UUID'): raise SystemExit('volume identity')
PY
  asset_fingerprint "$REF" "$ROOT/inventory/asset.tsv"; health "$ROOT/inventory/health"
  [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT && $(findmnt -rn -T "$CACHE_PARENT" -o FSTYPE) == ext4 ]] || die cache_parent
  findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$ROOT/inventory/cache-parent.freeze"
  ps -eo pid=,ppid=,lstart=,comm=,args= | awk 'tolower($0) ~ /weka|kube|containerd|dockerd/' >"$ROOT/inventory/protected-processes.tsv"
  df -B1 "$CACHE_PARENT" >"$ROOT/inventory/cache-df.tsv"
  [[ $(df -B1 --output=avail "$CACHE_PARENT"|awk 'NR==2{print $1}') -ge 103079215104 ]] || die cache_space_below_96GiB
  if pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1; then die foreign_fio; fi
  ss -lntp >"$ROOT/inventory/listeners.tsv" 2>&1 || :
  for p in 9581 9582 9583 9584; do ! awk -v p=":$p" '$4 ~ p"$"{f=1}END{exit f?0:1}' "$ROOT/inventory/listeners.tsv" || die metrics_port_busy_$p; done
  local nic; nic=$(ip route get 10.3.1.6 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  [[ -n $nic && -r /sys/class/net/$nic/statistics/rx_bytes ]] || die ceph_nic
  printf '%s\n' "$nic" >"$ROOT/inventory/ceph-data-nic.txt"
  cp "$0" "$SELF_DIR/t04tmp3i-cached-sync-read-analyze.py" "$SELF_DIR/t04tmp3i-cached-sync-read-gate0-offline.sh" "$ROOT/scripts/"
  matrix >"$ROOT/plans/matrix.tsv"; printf 'INVENTORY_PASS\n' >"$ROOT/inventory/PASS"
  printf '%s\tINVENTORY_PASS\n' "$(date -Iseconds)" >>"$ROOT/run-state.tsv"
  printf '04TMP3I_INVENTORY_PASS root=%s\n' "$ROOT"
}
cmd_plan(){
  valid; [[ -f $ROOT/inventory/PASS ]] || die inventory_required
  cat >"$ROOT/plans/sudo-contract.txt" <<EOF
# Exact privileged surface on 157; placeholders resolve only after unique loop attachment.
sudo install -d -m 0700 -o 1002 -g 1002 $BACKING_ROOT
sudo losetup --find --show --nooverlap $BACKING
sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 <verified-/dev/loopN>
sudo mount -o noatime,nodiscard <verified-/dev/loopN> $CACHE_MNT
sudo chown 1002:1002 $CACHE_MNT
sudo umount $CACHE_MNT
sudo losetup -d <same-verified-/dev/loopN>
sudo rmdir $BACKING_ROOT
EOF
  printf '%s\n' 'No Ceph/scrub/pool/PG/CRUSH/compact/GC/drop_caches/service/network/kernel mutation.' >"$ROOT/plans/exclusions.txt"
  sha256sum "$ROOT/scripts/t04tmp3i-cached-sync-read-run.sh" "$ROOT/scripts/t04tmp3i-cached-sync-read-analyze.py" "$ROOT/scripts/t04tmp3i-cached-sync-read-gate0-offline.sh" >"$ROOT/plans/scripts.sha256"
  printf 'PLAN_PASS\n' >"$ROOT/plans/PASS"; printf '04TMP3I_PLAN_PASS\n'
}
create_storage(){
  [[ ! -e $BACKING_ROOT && ! -e $CACHE_MNT ]] || die storage_scope_exists
  [[ $(findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS) == $(<"$ROOT/inventory/cache-parent.freeze") ]] || die cache_parent_drift
  record sudo install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" "$BACKING_ROOT"
  sudo install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" "$BACKING_ROOT"
  record fallocate -l 64G -- "$BACKING"; fallocate -l 64G -- "$BACKING"
  [[ $(stat -c %s "$BACKING") -eq $BACKING_BYTES && $(($(stat -c %b "$BACKING")*512)) -ge $((BACKING_BYTES*95/100)) ]] || die backing_allocation
  local loop; record sudo losetup --find --show --nooverlap "$BACKING"; loop=$(sudo losetup --find --show --nooverlap "$BACKING")
  [[ $loop =~ ^/dev/loop[0-9]+$ ]] || die invalid_loop; printf 'loop\t%s\nbacking_dev\t%s\nbacking_inode\t%s\n' "$loop" "$(stat -c %d "$BACKING")" "$(stat -c %i "$BACKING")" >"$ROOT/storage.tsv"
  verify_loop "$loop"; record sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop"
  sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop" >"$ROOT/closure/mkfs.stdout" 2>"$ROOT/closure/mkfs.stderr"
  mkdir -m 0700 "$CACHE_MNT"; record sudo mount -o noatime,nodiscard "$loop" "$CACHE_MNT"; sudo mount -o noatime,nodiscard "$loop" "$CACHE_MNT"
  record sudo chown "$EXPECTED_UID:$EXPECTED_GID" "$CACHE_MNT"; sudo chown "$EXPECTED_UID:$EXPECTED_GID" "$CACHE_MNT"
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$loop" ]] || die cache_mount_source
  findmnt -rn -M "$CACHE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS,UUID >"$ROOT/closure/cache-findmnt.tsv"
}
run_local1(){
  local out=$ROOT/cells/LOCAL1 p=$CACHE_MNT/local1.bin; mkdir -m 0700 -p "$out/bw"
  [[ ! -e $p ]] || die local1_exists
  local -a w=(fio --name=LOCAL1-write --filename="$p" --rw=write --bs=20M --size=10G --direct=1 --ioengine=psync --iodepth=1 --numjobs=1 --end_fsync=1 --output-format=json+ --output="$out/write.json")
  record "${w[@]}"; timeout 300 "${w[@]}"; [[ $(stat -c %s "$p") -eq 10737418240 && $(($(stat -c %b "$p")*512)) -ge 10200547328 ]] || die local1_allocation
  local -a r=(fio --name=LOCAL1 --filename="$p" --rw=read --bs=20M --size=10G --direct=1 --ioengine=psync --iodepth=1 --numjobs=1 --runtime=60 --time_based --group_reporting --write_bw_log="$out/bw/LOCAL1" --log_avg_msec=1000 --output-format=json+ --output="$out/fio.json")
  record "${r[@]}"; timeout 180 "${r[@]}"; record unlink -- "$p"; unlink -- "$p"; [[ ! -e $p ]] || die local1_remains
  record sleep 60; sleep 60; printf 'LOCAL1_PASS\n' >"$out/PASS"
}
mount_cell(){
  local cell=$1; cell_fields "$cell"; mkdir -m 0700 -p "$CELL_ROOT" "$JFS_MNT"
  : >"$CELL_ROOT/pids-pre.txt"; for p in /proc/[0-9]*; do [[ -e $p/exe && $(realpath "$p/exe" 2>/dev/null) == "$JFS" ]] && basename "$p" >>"$CELL_ROOT/pids-pre.txt" || :; done
  local -a cmd=("$JFS" mount -d --max-fuse-io 1M --max-readahead "$RA" --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-dir "$CACHE_DIR" --cache-size 32768 --free-space-ratio 0.20 --writeback --metrics "127.0.0.1:$PORT" --log "$CELL_ROOT/juicefs.log" "$META" "$JFS_MNT")
  record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"; CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$CELL_ROOT/mount.stdout" 2>"$CELL_ROOT/mount.stderr"
  for _ in $(seq 1 120); do mountpoint -q "$JFS_MNT" && break; sleep 1; done; mountpoint -q "$JFS_MNT" || die mount_timeout_$cell
  mount_pid_gate "$CELL_ROOT/pids-pre.txt" >"$CELL_ROOT/mount-process.tsv" || die mount_pid_$cell
  findmnt -rn -M "$JFS_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$CELL_ROOT/findmnt.tsv"
  for _ in $(seq 1 20); do curl -fsS --max-time 3 "http://127.0.0.1:$PORT/metrics" >"$CELL_ROOT/metrics-mounted.txt" 2>/dev/null && break; sleep 1; done
  grep -Fq "mp=\"$JFS_MNT\"" "$CELL_ROOT/metrics-mounted.txt" || die metrics_identity_$cell
  local worker threads; worker=$(awk -F '\t' '$4==1{print $1}' "$CELL_ROOT/mount-process.tsv"); threads=$(grep -l '^msgr-worker' /proc/"$worker"/task/*/comm 2>/dev/null|wc -l || :)
  [[ $threads -eq 8 ]] || die msgr_workers_$cell; printf 'worker\t%s\nthreads\t%s\nreadahead\t%s\n' "$worker" "$threads" "$RA" >"$CELL_ROOT/mount-identity.tsv"
  asset_fingerprint "$JFS_MNT" "$CELL_ROOT/asset-pre.tsv"; cmp -s "$ROOT/inventory/asset.tsv" "$CELL_ROOT/asset-pre.tsv" || die asset_pre_drift_$cell
}
run_cell(){
  local cell=$1; cell_fields "$cell"; health "$CELL_ROOT/health-pre"
  local f=$JFS_MNT$ASSET_REL nic; nic=$(<"$ROOT/inventory/ceph-data-nic.txt")
  local -a warm=(fio --name="$cell-warm" --filename="$f" --rw=read --bs=20M --size=10G --direct=1 --ioengine=psync --iodepth=1 --numjobs=1 --runtime=60 --time_based --group_reporting --output-format=json+ --output="$CELL_ROOT/warm.json")
  record "${warm[@]}"; timeout 180 "${warm[@]}"
  curl -fsS --max-time 5 "http://127.0.0.1:$PORT/metrics" >"$CELL_ROOT/metrics-pre.txt"; cat "/sys/class/net/$nic/statistics/rx_bytes" >"$CELL_ROOT/rx-pre.txt"
  mkdir -m 0700 "$CELL_ROOT/bw"; local -a formal=(fio --name="$cell" --filename="$f" --rw=read --bs=20M --size=10G --direct=1 --ioengine=psync --iodepth=1 --numjobs=1 --runtime=60 --time_based --group_reporting --write_bw_log="$CELL_ROOT/bw/$cell" --log_avg_msec=1000 --output-format=json+ --output="$CELL_ROOT/fio.json")
  record "${formal[@]}"; timeout 180 "${formal[@]}"; cat "/sys/class/net/$nic/statistics/rx_bytes" >"$CELL_ROOT/rx-post.txt"; curl -fsS --max-time 5 "http://127.0.0.1:$PORT/metrics" >"$CELL_ROOT/metrics-post.txt"
  awk 'NR==FNR{a=$1;next}{print $1-a}' "$CELL_ROOT/rx-pre.txt" "$CELL_ROOT/rx-post.txt" >"$CELL_ROOT/ceph-rx-bytes.txt"
  asset_fingerprint "$JFS_MNT" "$CELL_ROOT/asset-post.tsv"; cmp -s "$ROOT/inventory/asset.tsv" "$CELL_ROOT/asset-post.tsv" || die asset_post_drift_$cell
  health "$CELL_ROOT/health-post"; printf 'CELL_PASS\n' >"$CELL_ROOT/PASS"
}
unmount_cell(){
  local cell=$1; cell_fields "$cell"; record "$JFS" umount "$JFS_MNT"; "$JFS" umount "$JFS_MNT" >"$CELL_ROOT/umount.stdout" 2>"$CELL_ROOT/umount.stderr"
  for _ in $(seq 1 180); do ! mountpoint -q "$JFS_MNT" && break; sleep 1; done; ! mountpoint -q "$JFS_MNT" || die mount_remains_$cell
  for _ in $(seq 1 60); do jfs_gone "$CELL_ROOT/mount-process.tsv" && break; sleep 1; done; jfs_gone "$CELL_ROOT/mount-process.tsv" || die process_remains_$cell
  [[ -z $(find "$JFS_MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die mount_dir_not_empty_$cell; rmdir "$JFS_MNT"
}
cleanup_storage(){
  local loop dev ino; loop=$(awk -F '\t' '$1=="loop"{print $2}' "$ROOT/storage.tsv"); dev=$(awk -F '\t' '$1=="backing_dev"{print $2}' "$ROOT/storage.tsv"); ino=$(awk -F '\t' '$1=="backing_inode"{print $2}' "$ROOT/storage.tsv")
  [[ $(stat -c %d "$BACKING") == "$dev" && $(stat -c %i "$BACKING") == "$ino" && $(stat -c %s "$BACKING") -eq $BACKING_BYTES ]] || die backing_identity_drift
  verify_loop "$loop"; [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$loop" ]] || die cleanup_mount_source
  [[ -d $CACHE_DIR && ! -L $CACHE_DIR && $CACHE_DIR == "$CACHE_MNT/cache" ]] || die cache_dir_identity
  record find "$CACHE_DIR" -xdev -depth -delete; find "$CACHE_DIR" -xdev -depth -delete
  [[ ! -e $CACHE_DIR ]] || die cache_dir_remains
  record sudo umount "$CACHE_MNT"; sudo umount "$CACHE_MNT"; ! mountpoint -q "$CACHE_MNT" || die cache_mount_remains
  verify_loop "$loop"; record sudo losetup -d "$loop"; sudo losetup -d "$loop"; [[ -z $(sudo losetup -j "$BACKING") ]] || die loop_remains
  [[ -z $(find "$CACHE_MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die underlying_mountpoint_not_empty; rmdir "$CACHE_MNT"
  record unlink -- "$BACKING"; unlink -- "$BACKING"; [[ -z $(find "$BACKING_ROOT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die backing_root_not_empty
  record sudo rmdir "$BACKING_ROOT"; sudo rmdir "$BACKING_ROOT"; printf 'STORAGE_CLOSED\n' >"$ROOT/closure/STORAGE_CLOSED"
}
cmd_execute(){
  valid; [[ ${T04TMP3I_ACK:-} == I_ACK_04TMP3I_RUN_$RUN_ID ]] || die exact_ack_required
  [[ -f $ROOT/plans/PASS ]] || die plan_required; sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift
  cmp -s "$0" "$ROOT/scripts/t04tmp3i-cached-sync-read-run.sh" || die runtime_runner_drift
  cmp -s "$SELF_DIR/t04tmp3i-cached-sync-read-analyze.py" "$ROOT/scripts/t04tmp3i-cached-sync-read-analyze.py" || die runtime_analyzer_drift
  printf '%s\tEXECUTE_STARTED\n' "$(date -Iseconds)" >>"$ROOT/run-state.tsv"
  [[ ! -e $BACKING_ROOT && ! -e $CACHE_MNT ]] || die preexisting_storage
  health "$ROOT/closure/health-pre"; asset_fingerprint "$REF" "$ROOT/closure/asset-pre.tsv"; cmp -s "$ROOT/inventory/asset.tsv" "$ROOT/closure/asset-pre.tsv" || die initial_asset_drift
  create_storage; run_local1
  mkdir -m 0700 "$CACHE_DIR"
  local cell; for cell in A1 B1 B2 A2; do mount_cell "$cell"; run_cell "$cell"; unmount_cell "$cell"; done
  asset_fingerprint "$REF" "$ROOT/closure/asset-post.tsv"; cmp -s "$ROOT/inventory/asset.tsv" "$ROOT/closure/asset-post.tsv" || die final_asset_drift
  local analysis_rc; set +e; python3 "$ROOT/scripts/t04tmp3i-cached-sync-read-analyze.py" run "$ROOT" >"$ROOT/final-analysis.json"; analysis_rc=$?; set -e
  cleanup_storage; health "$ROOT/closure/health-post"
  (( analysis_rc == 0 )) || die analyzer_rejected_evidence
  printf 'EXECUTE_PASS\n' >"$ROOT/EXECUTE_PASS"; printf '04TMP3I_EXECUTE_PASS\n'
  printf '%s\tEXECUTE_PASS\n' "$(date -Iseconds)" >>"$ROOT/run-state.tsv"
}
cmd_bundle(){
  valid; [[ -f $ROOT/EXECUTE_PASS && -f $ROOT/closure/STORAGE_CLOSED ]] || die closure_required
  local manifest=$ROOT/manifest.sha256 archive=/tmp/production/04tmp3i-$RUN_ID-evidence.tar
  (cd "$ROOT" && find . -type f ! -name manifest.sha256 -print0|sort -z|xargs -0 sha256sum) >"$manifest"
  tar -C /tmp/production -cf "$archive" "opencode-04tmp3i-$RUN_ID"; sha256sum "$archive" >"$archive.sha256"; printf 'BUNDLE_PASS\t%s\n' "$archive"
}
cmd_inspect(){ valid; findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS | grep -F "04tmp3i-$RUN_ID" || :; sudo losetup -j "$BACKING" || :; pgrep -af "jfs-04tmp3i-mnt-$RUN_ID" || :; }
cmd_self_test(){ valid; matrix | awk -F '\t' 'NR==2&&$1=="LOCAL1"{x=1} NR==3&&$1=="A1"&&$3=="8M"{a=1} NR==4&&$1=="B1"&&$3=="32M"{b=1} NR==5&&$1=="B2"&&$3=="32M"{c=1} NR==6&&$1=="A2"&&$3=="8M"{d=1} END{exit !(x&&a&&b&&c&&d)}'; printf '04TMP3I_RUNNER_SELFTEST_PASS\n'; }
case $MODE in inventory) cmd_inventory;; plan) cmd_plan;; execute) cmd_execute;; bundle) cmd_bundle;; inspect) cmd_inspect;; self-test) cmd_self_test;; print-matrix) matrix;; *) printf 'usage: %s inventory|plan|execute|bundle|inspect|self-test|print-matrix RUN_ID\n' "$0" >&2; exit 2;; esac
