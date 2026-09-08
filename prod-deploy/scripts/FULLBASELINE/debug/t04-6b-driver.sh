#!/usr/bin/env bash
# 04-6b Phase-0/L1 driver.  Inventory and Phase A are executable on the target
# after the independent authorization stop; this turn only runs offline checks.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANALYZER=$SCRIPT_DIR/t04-6b-capacity-analyze.py
RUN_ID=${2:-}
EVIDENCE_ROOT=${T046B_EVIDENCE_ROOT:-/mnt/c/SunRise/test/04-6b/$RUN_ID}
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
REFERENCE_MNT=/mnt/juicefs
TASK_MOUNT="/tmp/jfs-t046b-$RUN_ID-<CELL>"
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
SCRUB_CONTROL=$SCRIPT_DIR/u141d-scrub-control.sh
REMOTE_ROOT=/tmp/production/opencode-04-6b-$RUN_ID
CEPH_CONF=$REMOTE_ROOT/inventory/ceph-msgr8.conf
LEASE=$RUN_ID-phase-a
FIO=${T046B_FIO:-fio}
EXPECTED_OSDS=(0 1 2 3 4 5)
EXPECTED_FSID=f8137e5a-8af2-11f1-aa1c-4df480fc234d

die(){ printf 'T046B_FAIL\t%s\n' "$*" >&2; exit 2; }
valid_run(){ [[ $1 =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID; }
usage(){ cat >&2 <<'EOF'
usage:
  t04-6b-driver.sh offline-gate RUN_ID
  t04-6b-driver.sh inventory-plan RUN_ID
  t04-6b-driver.sh inventory RUN_ID
  t04-6b-driver.sh phase-a RUN_ID ACK
  t04-6b-driver.sh phase-plan RUN_ID PHASE
  t04-6b-driver.sh phase-b RUN_ID ACK
  t04-6b-driver.sh --self-test
EOF
  exit 2
}

offline_gate(){
  local run=$1 out
  valid_run "$run"; out=${T046B_GATE_ROOT:-/tmp/t046b-gate-$run}
  [[ $out == /tmp/t046b-gate-* || $out == /mnt/c/SunRise/test/04-6b/* ]] || die unsafe_gate_root
  mkdir -m 0700 -p "$out"
  bash -n "$0"; bash -u -n "$0"
  PYTHONPYCACHEPREFIX="$out/pycache" python3 -m py_compile "$ANALYZER"
  python3 "$ANALYZER" self-test >"$out/analyzer-self-test.txt"
  grep -Fq T046_CAPACITY_ANALYZER_SELF_TEST_PASS "$out/analyzer-self-test.txt" || die analyzer_self_test
  # Scan only executable command forms; quoted scan expressions are harmless.
  if grep -nE '(^|[;&|])[[:space:]]*(sudo|ssh|scp|systemctl|reboot|pkill|killall|fuser|drop_caches)' "$0" | grep -v 'grep -nE' | grep -vE 'timeout 60 sudo ceph tell "osd\.\$osd" compact'; then
    die forbidden_operational_command
  fi
  if grep -nE '(^|[;&|])[[:space:]]*sudo' "$0" | grep -vE 'timeout 60 sudo ceph tell "osd\.\$osd" compact' | grep -v 'grep -nE'; then die unexpected_sudo_surface; fi
  if grep -nE 'rm[[:space:]]+-r|umount[[:space:]]+-[lf]|pool[[:space:]]+(create|delete)|juicefs[[:space:]]+(format|destroy)|/dev/(nvme|sd|md)[[:alnum:]]*' "$0"; then
    die forbidden_scope_or_destructive_command
  fi
  grep -Fq '24fae0852051c80ca571cb2f20275d46' "$0" || die binary_pin_missing
  grep -Fq '/mnt/juicefs' "$0" || die protected_reference_missing
  grep -Fq 'TASK_MOUNT="/tmp/jfs-t046b-$RUN_ID-<CELL>"' "$0" || die task_mount_template_missing
  grep -Fq 'JuiceFS:juicefs-prod' "$0" || die source_identity_missing
  grep -Fq '86351c58848c7e4caaa1bbeccb211730' "$0" || die ceph_conf_pin_missing
  grep -Fq 'mount-process.tsv' "$0" || die worker_evidence_missing
  grep -Fq 'juicefs.stats' "$0" || die juicefs_stats_contract_missing
  grep -Fq 'osd-$osd.json' "$0" || die osd_perf_contract_missing
  grep -Fq 'set +e' "$0" || die fio_rc_contract_missing
  grep -Fq 'seqread.0.0' "$0" || die seqread_asset_contract_missing
  grep -Fq 'mseqread.*.0' "$0" || die mseqread_asset_contract_missing
  grep -Fq 'phase-a-verdict.json' "$0" || die phase_a_analyzer_missing
  grep -Fq 'worker-threads.tsv' "$0" || die thread_sidecar_missing
  grep -Fq 'T046B_PHASE_A_ANALYZE_PASS' "$ANALYZER" || die phase_a_analyzer_entry_missing
  grep -Fq 'NOT_MEASURED' "$ANALYZER" || die missing_unknown_policy
  grep -Fq 'R01-SR' "$0" || die phase_a_matrix_missing
  grep -Fq 'R04-MSR' "$0" || die phase_a_abba_missing
  grep -Fq 'W04-SW' "$0" || die phase_b_matrix_missing
  grep -Fq 'phase-b-verdict.json' "$0" || die phase_b_analyzer_missing
  grep -Fq '04-6b-phase-b' "$0" || die phase_b_lease_missing
  grep -Fq 'T046B_PHASE_B_ANALYZE_PASS' "$ANALYZER" || die phase_b_analyzer_entry_missing
  grep -Fq -- '--threads 32' "$0" || die phase_b_gc_threads_missing
  grep -Fq 'compact-audit.tsv' "$0" || die phase_b_compact_audit_missing
  grep -Fq '97' "$0" || die phase_b_pg_contract_missing
  grep -Fq 'phase_b_full_clean "$pbr" PRE NONE' "$0" || die phase_b_pre_clean_missing
  grep -Fq 'phase_b_full_clean "$pbr" SEED NONE' "$0" || die phase_b_seed_clean_missing
  grep -Fq 'phase_b_verify_compact_budget' "$0" || die phase_b_compact_budget_missing
  grep -Fq 'phase_b_phase_a_recheck' "$0" || die phase_b_recheck_missing
  grep -Fq -- '--time_based' "$0" || die formal_window_contract_missing
  grep -Fq -- '--runtime=180' "$0" || die runtime_contract_missing
  grep -Fq 'verify-paused' "$0" || die scrub_restore_interface_missing
  grep -Fq 'graceful_umount' "$0" || die graceful_umount_missing
  grep -Fq 'business_identity' "$0" || die business_identity_missing
  sha256sum "$0" "$ANALYZER" >"$out/input-sha256.tsv"
  printf 'T046B_GATE0_L0_PASS\t%s\n' "$out"
}

inventory_plan(){
  local run=$1 root
  valid_run "$run"; root=${T046B_EVIDENCE_ROOT:-/mnt/c/SunRise/test/04-6b/$run}
  [[ $root == /mnt/c/SunRise/test/04-6b/$run ]] || die unsafe_evidence_root
  mkdir -m 0700 -p "$root/plans" "$root/common" "$root/derived"
  cat >"$root/plans/inventory-readonly.tsv" <<EOF
field	contract	state_change
binary	$JFS md5=$JFS_MD5	NONE
reference	$REFERENCE_MNT identity/PID/starttime/exe	NONE
health	Ceph HEALTH_OK; 6/6 OSD up/in; PG active+clean	NONE
assets	seqread/seqwrite/randrw path,inode,size frozen	NONE
capacity	pool objects/stored, six OSD, TiKV endpoints and NIC	NONE
scrub	inspect only; no pause in L0	NONE
EOF
  cat >"$root/plans/phase-contract.txt" <<'EOF'
04-6b L0: no environment execution.
Phase A R8: four mounts, SR/MSR ABBA.
Phase B F1: four mounts, SW/MSW ABBA.
Phase C U300: four mounts, mseqwrite ABBA.
Phase D: M01/M02/M03 randrw state loop.
No format, destroy, pool operation, cache/writeback, or drop_caches.
EOF
  python3 "$ANALYZER" ledger --output "$root/derived/capacity-ledger.tsv" --source "L0 explicit source map"
  printf 'T046B_INVENTORY_PLAN_ONLY\t%s\n' "$root"
}

business_identity(){
  local out=$1 status
  mkdir -m 0700 -p "$out"
  mountpoint -q "$REFERENCE_MNT" || die business_mount_absent
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REFERENCE_MNT fuse.juicefs" "$out/reference-mount.tsv" || die business_mount_identity
  env CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$out/current-status.json"
  python3 - "$out/current-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get("Setting",d)
if s.get("Name") != "juicefs-prod" or not s.get("UUID"):
    raise SystemExit("current volume identity mismatch")
open(sys.argv[1]+".identity", "w").write("name\t%s\nuuid\t%s\n" % (s["Name"], s["UUID"]))
PY
  find "$REFERENCE_MNT/test_dir" -maxdepth 2 -type f -printf '%p\t%i\t%s\t%T@\n' | sort >"$out/protected-assets.tsv"
  [[ -s $out/protected-assets.tsv ]] || die protected_assets_missing
  python3 - "$REFERENCE_MNT" "$out/read-assets-sample-sha256.tsv" <<'PY'
import hashlib, os, sys
root=sys.argv[1]
paths=[os.path.join(root,'test_dir/seqread/seqread.0.0')]
paths += [os.path.join(root,f'test_dir/mseqread/mseqread.{i}.0') for i in range(16)]
with open(sys.argv[2],'w') as out:
    out.write('path\tinode\tsize\tmtime_ns\tfirst_1m_sha256\tlast_1m_sha256\n')
    for path in paths:
        st=os.stat(path, follow_symlinks=False)
        if not os.path.isfile(path) or os.path.islink(path):
            raise SystemExit('read asset is not a regular non-symlink file: '+path)
        with open(path,'rb',buffering=0) as f:
            first=f.read(min(1<<20, st.st_size))
            f.seek(max(0,st.st_size-(1<<20)))
            last=f.read(min(1<<20, st.st_size))
        out.write('%s\t%d\t%d\t%d\t%s\t%s\n' % (
            path,st.st_ino,st.st_size,st.st_mtime_ns,
            hashlib.sha256(first).hexdigest(),hashlib.sha256(last).hexdigest()))
PY
  python3 - "$REFERENCE_MNT" "$out/reference-process.tsv" "$JFS_MD5" <<'PY'
import hashlib, os, pathlib, sys
mount=sys.argv[1]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        raw=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace').strip()
        exe=os.path.realpath(p/'exe')
        digest=hashlib.md5(open(p/'exe','rb').read()).hexdigest()
        if mount not in raw or digest != sys.argv[3]: continue
        stat=(p/'stat').read_text().split()
        rows.append((int(p.name),stat[3],stat[21],digest,exe,raw))
    except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit('reference mount process identity missing')
with open(sys.argv[2],'w') as out:
    out.write('pid\tppid\tstarttime\texe_md5\texe\tcmdline\n')
    for row in sorted(rows): out.write('\t'.join(map(str,row))+'\n')
PY
}

foreign_fio_gate(){
  python3 - <<'PY'
import pathlib
bad=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if (p/'comm').read_text().strip() == 'fio': bad.append(p.name)
    except OSError: pass
if bad: raise SystemExit('foreign fio exists: '+','.join(bad))
PY
}

health_snapshot(){
  local out=$1 mode=${2:-unpaused}
  mkdir -m 0700 -p "$out"
  env CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$out/ceph-status.json" || die ceph_status
  env CEPH_CONF="$CEPH_CONF" ceph osd stat --format json >"$out/osd-stat.json" || die osd_status
  python3 - "$out/ceph-status.json" "$mode" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get('health',{})
mode=sys.argv[2]; checks=set(h.get('checks') or {})
if not ((mode == 'paused' and ((h.get('status') == 'HEALTH_OK' and not checks) or (h.get('status') == 'HEALTH_WARN' and checks == {'OSDMAP_FLAGS'}))) or (mode == 'unpaused' and h.get('status') == 'HEALTH_OK' and not checks)):
    raise SystemExit('Ceph health is not clean')
pg=d.get('pgmap',{}).get('pgs_by_state',[])
if not pg or any(x.get('state_name') != 'active+clean' for x in pg):
    raise SystemExit('PGs are not active+clean')
PY
  python3 - "$out/osd-stat.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));
if any(int(d.get(k, -1)) != 6 for k in ('num_osds','num_up_osds','num_in_osds')):
    raise SystemExit('six-OSD health gate failed')
PY
}

inventory_remote(){
  local run=$1 root
  valid_run "$run"; root=${T046B_REMOTE_ROOT:-$REMOTE_ROOT}
  [[ $root == /tmp/production/opencode-04-6b-$run ]] || die unsafe_remote_root
  mkdir -m 0700 -p "$root/inventory" "$root/plans"
  CEPH_CONF="$root/inventory/ceph-msgr8.conf"
  if [[ ! -e $CEPH_CONF ]]; then
    cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
    printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
  fi
  [[ -r $CEPH_CONF && ! -L $CEPH_CONF && $(md5sum "$CEPH_CONF" | awk '{print $1}') == 86351c58848c7e4caaa1bbeccb211730 ]] || die private_ceph_conf_identity
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die JuiceFS_identity
  command -v ceph >/dev/null || die ceph_missing
  command -v fio >/dev/null || die fio_missing
  business_identity "$root/inventory"
  health_snapshot "$root/inventory/health"
  command -v ip >"$root/inventory/ip-path.txt"
  ip route get 10.3.1.6 >"$root/inventory/ceph-route.txt"
  nic=$(awk '{for(i=1;i<=NF;i++) if($i=="dev" && i<NF){print $(i+1); exit}}' "$root/inventory/ceph-route.txt")
  [[ $nic =~ ^[A-Za-z0-9_.:-]+$ && -r /sys/class/net/$nic/statistics/rx_bytes ]] || die exact_nic_unavailable
  printf '%s\n' "$nic" >"$root/inventory/nic.txt"
  cat >"$root/plans/scrub-interface.txt" <<EOF
SCRUB_MODE=PAUSED_CONTROLLED
controller=$SCRUB_CONTROL
lease=$LEASE
pause requires external I_ACK_GLOBAL_CEPH_SCRUB_PAUSE and exact FSID
failure/closure calls controller restore then verify-restored
EOF
  printf 'INVENTORY_PASS\n' >"$root/inventory/PASS"
  printf 'T046B_INVENTORY_PASS\t%s\n' "$root"
}

graceful_umount(){
  local mnt=$1 out=$2 i
  [[ -n $mnt && $mnt == /tmp/jfs-t046b-$RUN_ID-* && -d $mnt ]] || die unsafe_umount_target
  if mountpoint -q "$mnt"; then
    "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr" || die umount_failed
    for i in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
    mountpoint -q "$mnt" && die mount_remains
  fi
  [[ ! -f "$out/mount-process.tsv" ]] || python3 - "$JFS" "$out/mount-process.tsv" <<'PY'
import os,sys,time
exe=os.path.realpath(sys.argv[1])
identities=[]
for line in open(sys.argv[2]):
    if line.startswith('pid\t'): continue
    fields=line.rstrip('\n').split('\t')
    if len(fields) >= 3: identities.append((fields[0],fields[2]))
def remains(pid,start):
    try:
        return os.path.realpath('/proc/'+pid+'/exe') == exe and open('/proc/'+pid+'/stat').read().split()[21] == start
    except OSError:
        return False
for _ in range(60):
    live=[(pid,start) for pid,start in identities if remains(pid,start)]
    if not live: break
    time.sleep(.5)
else:
    raise SystemExit('mount process remains: '+','.join(pid for pid,_ in live))
PY
  if grep -nEi 'ceph_assert|SIGABRT|SIGSEGV|panic|fatal|core dumped|Aborted' "$out"/../*/juicefs-mount.log "$out"/umount.stderr 2>/dev/null; then die mount_log_assertion; fi
  [[ -z $(find "$mnt" -mindepth 1 -maxdepth 1 -print -quit) ]] || die mount_dir_not_empty
  if command -v ss >/dev/null && ss -ltnH | awk '$4 ~ /(^|:)9568$/{found=1} END{exit found?0:1}'; then die metrics_port_remains; fi
  rmdir "$mnt" || die mount_dir_remove_failed
}

scrub_pause(){
  local root=$1 fsid
  [[ ${T046B_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die scrub_ack_missing
  fsid=$(env CEPH_CONF="$CEPH_CONF" ceph fsid) || die ceph_fsid
  U141D_SCRUB_STATE_DIR="$root/state" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" pause "$LEASE" "$fsid" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$root/state/scrub-pause.log" 2>&1 || die scrub_pause_failed
  U141D_SCRUB_STATE_DIR="$root/state" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" verify-paused "$LEASE" >>"$root/state/scrub-pause.log" 2>&1 || die scrub_verify_failed
}

scrub_restore(){
  local root=$1
  [[ -f $root/state/u141d-scrub-control-$LEASE.tsv ]] || return 0
  U141D_SCRUB_STATE_DIR="$root/state" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" restore "$LEASE" >"$root/state/scrub-restore.log" 2>&1 || return 1
  U141D_SCRUB_STATE_DIR="$root/state" U141D_CEPH_CONF="$CEPH_CONF" \
    bash "$SCRUB_CONTROL" verify-restored "$LEASE" >>"$root/state/scrub-restore.log" 2>&1
}

mount_a(){
  local root=$1 label=$2 ra=$3 mode=${4:-ro} fuse=${5:-256K} mnt log
  mnt=/tmp/jfs-t046b-$RUN_ID-$label
  log=$root/mounts/$label/juicefs-mount.log
  [[ $mode == ro || $mode == rw ]] || die invalid_mount_mode
  local -a cmd=("$JFS" mount -d --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 --max-fuse-io "$fuse" --metrics 127.0.0.1:9568 --log "$log")
  [[ $mode == ro ]] && cmd+=(--read-only)
  [[ $ra == 8 ]] && cmd+=(--max-readahead 8M)
  [[ ! -e $mnt && ! -L $mnt ]] || die mount_path_exists
  if command -v ss >/dev/null && ss -ltnH | awk '$4 ~ /(^|:)9568$/{found=1} END{exit found?0:1}'; then die metrics_port_in_use; fi
  mkdir -m 0700 -p "$root/mounts/$label"; mkdir -m 0700 "$mnt"
  printf '%q ' env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}" "$META" "$mnt" >>"$root/commands.sh"; printf '\n' >>"$root/commands.sh"
  env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" "$META" "$mnt" >"$root/mounts/$label/mount.stdout" 2>"$root/mounts/$label/mount.stderr" || die mount_failed_$label
  for i in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout_$label
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$root/mounts/$label/findmnt.tsv"
  grep -Fq "JuiceFS:juicefs-prod $mnt fuse.juicefs" "$root/mounts/$label/findmnt.tsv" || die mount_identity_$label
  [[ -f $log ]] || die mount_log_missing_$label
  python3 - "$JFS" "$log" "$root/mounts/$label/mount-process.tsv" "$root/mounts/$label/mount-state.tsv" <<'PY'
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
if not rows: raise SystemExit('mount process identity missing')
with open(sys.argv[3],'w') as f:
    f.write('pid\tppid\tstarttime\texe_md5\tcmdline\n')
    for row in sorted(rows,key=lambda x:int(x[0])): f.write('\t'.join(row)+'\n')
pids={r[0] for r in rows}; workers=[r for r in rows if r[1] in pids]
if len(workers) != 1: raise SystemExit('unique child worker not found')
w=workers[0]
with open(sys.argv[4],'w') as f:
    f.write(f'worker_pid\t{w[0]}\nworker_starttime\t{w[2]}\nworker_exe_md5\t{w[3]}\n')
PY
  curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:9568/metrics >"$root/mounts/$label/metrics-mounted.prom" || die metrics_endpoint_missing_$label
  grep -Fq 'vol_name="juicefs-prod"' "$root/mounts/$label/metrics-mounted.prom" || die metrics_identity_$label
  printf '%s\n' "$mnt" >"$root/mounts/$label/mountpoint.txt"
}

mechanism_snapshot(){
  local out=$1 mnt=$2 state=$3 worker nic host osd tid
  mkdir -m 0700 -p "$out/ceph-osd" "$out/tikv"
  cat "$mnt/.stats" >"$out/juicefs.stats" || die juicefs_stats_missing
  worker=$(awk -F '\t' '$1=="worker_pid"{print $2}' "$state")
  nic=$(<"$REMOTE_ROOT/inventory/nic.txt")
  [[ $worker =~ ^[0-9]+$ && -r /proc/$worker/stat && -r /sys/class/net/$nic/statistics/rx_bytes ]] || die sidecar_identity_missing
  printf 'pid\tutime_ticks\tstime_ticks\trss_kib\tthreads\tnic\trx_bytes\ttx_bytes\n' >"$out/client.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$worker" "$(awk '{print $14}' /proc/$worker/stat)" "$(awk '{print $15}' /proc/$worker/stat)" "$(awk '/^VmRSS:/{print $2}' /proc/$worker/status)" "$(awk '/^Threads:/{print $2}' /proc/$worker/status)" "$nic" "$(cat /sys/class/net/$nic/statistics/rx_bytes)" "$(cat /sys/class/net/$nic/statistics/tx_bytes)" >>"$out/client.tsv"
  printf 'tid\tcomm\tutime_ticks\tstime_ticks\n' >"$out/worker-threads.tsv"
  for tid in /proc/$worker/task/[0-9]*; do
    [[ -r $tid/stat ]] || continue
    printf '%s\t%s\t%s\t%s\n' "${tid##*/}" "$(awk '{print $2}' "$tid/stat" | tr -d '()')" "$(awk '{print $14}' "$tid/stat")" "$(awk '{print $15}' "$tid/stat")" >>"$out/worker-threads.tsv"
  done
  for osd in 0 1 2 3 4 5; do
    env CEPH_CONF="$CEPH_CONF" timeout 20 ceph tell "osd.$osd" perf dump >"$out/ceph-osd/osd-$osd.json" || die osd_perf_missing
  done
  for host in 10.20.1.150 10.20.1.151 10.20.1.152; do
    curl -fsS --connect-timeout 3 --max-time 5 "http://$host:20180/metrics" >"$out/tikv/$host.metrics" || die tikv_metrics_missing
  done
}

run_endpoint(){
  local root=$1 mount_label=$2 label=$3 kind=$4 mnt=$5 out dir bs size jobs
  out=$root/cells/$label
  mkdir -m 0700 -p "$out/bwlog"
  if [[ $kind == seqread ]]; then
    dir="$mnt/test_dir/seqread"; bs=256k; size=32G; jobs=1
    [[ -f "$dir/seqread.0.0" && ! -L "$dir/seqread.0.0" && $(stat -c %s "$dir/seqread.0.0") == 34359738368 ]] || die seqread_asset_contract_$label
  else
    dir="$mnt/test_dir/mseqread"; bs=256k; size=4G; jobs=16
    [[ -d $dir && ! -L $dir ]] || die mseqread_asset_dir_$label
    for i in $(seq 0 15); do
      [[ -f "$dir/mseqread.$i.0" && ! -L "$dir/mseqread.$i.0" && $(stat -c %s "$dir/mseqread.$i.0") == 4294967296 ]] || die mseqread_asset_contract_$label
    done
  fi
  health_snapshot "$out/health-pre" paused
  mechanism_snapshot "$out/pre-mechanism" "$mnt" "$root/mounts/$mount_label/mount-state.tsv"
  local start_ns=$(date +%s%N); printf '%s\n' "$start_ns" >"$out/fio-start-ns.txt"
  local fio_rc; local -a fio_cmd
  if [[ $kind == seqread ]]; then
    fio_cmd=("$FIO" --name="$label" --directory="$dir" --filename=seqread.0.0 --rw=read --bs="$bs" --size="$size" --numjobs="$jobs" --ioengine=psync --iodepth=1 --direct=1 --allow_file_create=0 --refill_buffers --time_based --runtime=180 --group_reporting --per_job_logs=1 --output-format=json --output="$out/fio.json" --write_bw_log="$out/bwlog/$label" --log_avg_msec=1000)
  else
    fio_cmd=("$FIO" --name="$label" --directory="$dir" --filename_format='mseqread.$jobnum.0' --rw=read --bs="$bs" --size="$size" --numjobs="$jobs" --ioengine=psync --iodepth=1 --direct=1 --allow_file_create=0 --refill_buffers --time_based --runtime=180 --group_reporting --per_job_logs=1 --output-format=json --output="$out/fio.json" --write_bw_log="$out/bwlog/$label" --log_avg_msec=1000)
  fi
  printf '%q ' timeout 300 "${fio_cmd[@]}" >>"$root/commands.sh"; printf '\n' >>"$root/commands.sh"
  set +e
  timeout 300 "${fio_cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"
  fio_rc=$?; set -e; printf '%s\n' "$fio_rc" >"$out/fio.rc"; (( fio_rc == 0 )) || die fio_failed_$label
  date +%s%N >"$out/fio-end-ns.txt"
  mechanism_snapshot "$out/post-mechanism" "$mnt" "$root/mounts/$mount_label/mount-state.tsv"
  health_snapshot "$out/health-post" paused
  printf 'ENDPOINT_PASS\t%s\n' "$label" >"$out/PASS"
}

phase_a(){
  local run=$1 ack=$2 root=${T046B_REMOTE_ROOT:-$REMOTE_ROOT} active=0 active_mnt= active_out=
  valid_run "$run"; [[ $ack == I_ACK_04_6B_PHASE_A_$run ]] || die phase_a_ack_missing
  [[ $root == /tmp/production/opencode-04-6b-$run && -f $root/inventory/PASS ]] || die inventory_required
  [[ -r $CEPH_CONF && -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die runtime_identity_missing
  mkdir -m 0700 -p "$root/state" "$root/mounts" "$root/cells"; : >"$root/commands.sh"
  printf 'cell\torder\tarm\tendpoint\tworkload\tra\tformal_window\n' >"$root/plans/phase-a-matrix.tsv"
  printf 'R01\t1\tA\tR01-SR\tseqread\tdefault\t[15,175)\nR01\t2\tA\tR01-MSR\tmseqread\tdefault\t[15,175)\nR02\t1\tR8\tR02-MSR\tmseqread\t8M\t[15,175)\nR02\t2\tR8\tR02-SR\tseqread\t8M\t[15,175)\nR03\t1\tR8\tR03-SR\tseqread\t8M\t[15,175)\nR03\t2\tR8\tR03-MSR\tmseqread\t8M\t[15,175)\nR04\t1\tA\tR04-MSR\tmseqread\tdefault\t[15,175)\nR04\t2\tA\tR04-SR\tseqread\tdefault\t[15,175)\n' >>"$root/plans/phase-a-matrix.tsv"
  phase_a_exit(){ local x=$?; scrub_restore "$root" || x=70; if (( active )) && [[ -d $active_mnt ]]; then graceful_umount "$active_mnt" "$active_out" || x=70; fi; exit "$x"; }
  trap phase_a_exit EXIT
  foreign_fio_gate; business_identity "$root/inventory-pre"; scrub_pause "$root"; health_snapshot "$root/health-pre" paused
  local mount_label ra ep kind mnt
  for mount_label in R01 R02 R03 R04; do
    [[ $mount_label == R02 || $mount_label == R03 ]] && ra=8 || ra=0
    mnt=/tmp/jfs-t046b-$run-$mount_label; active_mnt=$mnt; active_out="$root/mounts/$mount_label"; active=1
    mount_a "$root" "$mount_label" "$ra"
    if [[ $mount_label == R01 ]]; then
      run_endpoint "$root" "$mount_label" R01-SR seqread "$mnt"; run_endpoint "$root" "$mount_label" R01-MSR mseqread "$mnt"
    elif [[ $mount_label == R02 ]]; then
      run_endpoint "$root" "$mount_label" R02-MSR mseqread "$mnt"; run_endpoint "$root" "$mount_label" R02-SR seqread "$mnt"
    elif [[ $mount_label == R03 ]]; then
      run_endpoint "$root" "$mount_label" R03-SR seqread "$mnt"; run_endpoint "$root" "$mount_label" R03-MSR mseqread "$mnt"
    else
      run_endpoint "$root" "$mount_label" R04-MSR mseqread "$mnt"; run_endpoint "$root" "$mount_label" R04-SR seqread "$mnt"
    fi
    graceful_umount "$mnt" "$root/mounts/$mount_label"; active=0; active_mnt=; active_out=
  done
  scrub_restore "$root" || die scrub_restore_failed
  trap - EXIT; health_snapshot "$root/health-post"; business_identity "$root/inventory-post"
  cmp -s "$root/inventory-pre/reference-mount.tsv" "$root/inventory-post/reference-mount.tsv" || die business_mount_drift
  cmp -s "$root/inventory-pre/current-status.json.identity" "$root/inventory-post/current-status.json.identity" || die business_volume_drift
  cmp -s "$root/inventory-pre/protected-assets.tsv" "$root/inventory-post/protected-assets.tsv" || die protected_assets_drift
  cmp -s "$root/inventory-pre/read-assets-sample-sha256.tsv" "$root/inventory-post/read-assets-sample-sha256.tsv" || die read_assets_drift
  cmp -s "$root/inventory-pre/reference-process.tsv" "$root/inventory-post/reference-process.tsv" || die business_process_drift
  python3 "$ANALYZER" phase-a --root "$root" --output "$root/derived/phase-a-verdict.json" || die phase_a_analysis_failed
  printf 'PHASE_A_PASS\n' >"$root/PHASE_A_PASS"
  printf 'T046B_PHASE_A_PASS\t%s\n' "$root"
}

phase_b_pool_stats(){
  local out
  out=$1
  env CEPH_CONF="$CEPH_CONF" ceph df detail --format json >"$out.json" || die phase_b_pool_stats
  python3 - "$out.json" "$out" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); p=next((x for x in d.get('pools',[]) if x.get('name')=='juicefs-data'),None)
if not p: raise SystemExit('juicefs-data pool missing')
s=p.get('stats',p); o=s.get('objects',s.get('stored',0)); b=s.get('bytes_used',0)
open(sys.argv[2],'w').write('pool\tobjects\tbytes_used\njuicefs-data\t%s\t%s\n'%(o,b))
PY
}

phase_b_gc(){
  local root label out
  root=$1; label=$2; out="$root/recovery/$label-gc"
  [[ $label =~ ^(PRE|SEED|W0[1-4]|CLEANUP)$ ]] || die phase_b_gc_label
  mkdir -m 0700 -p "$out"
  printf '%q ' env "CEPH_CONF=$CEPH_CONF" JFS_GC_SKIPPEDTIME=0 timeout 1800 "$JFS" gc --compact --delete --threads 32 "$META" >"$out/command.sh"; printf '\n' >>"$out/command.sh"
  env CEPH_CONF="$CEPH_CONF" JFS_GC_SKIPPEDTIME=0 timeout 1800 "$JFS" gc --compact --delete --threads 32 "$META" >"$out/stdout" 2>"$out/stderr" || die phase_b_gc_failed_$label
}

phase_b_osd_perf_values(){
  python3 - "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); found={}
def walk(x):
    if isinstance(x,dict):
        for k,v in x.items():
            if k in ('compact_running','compact_queue_len') and isinstance(v,(int,float)): found.setdefault(k,[]).append(v)
            walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(d)
for k in ('compact_running','compact_queue_len'):
    if len(found.get(k,[])) != 1: raise SystemExit(k+' unavailable or duplicated')
print(found['compact_running'][0],found['compact_queue_len'][0])
PY
}

phase_b_pending_total(){
  curl -fsS --connect-timeout 3 --max-time 8 "http://$1:20180/metrics" | awk '$1 ~ /^tikv_engine_pending_compaction_bytes(\{|$)/ {sum+=$2; found=1} END {if(!found) exit 1; printf "%.0f\n",sum}'
}

phase_b_health_97(){
  local status=$1 total
  total=$(python3 - "$status/ceph-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); print(sum(int(x.get('count',0)) for x in d.get('pgmap',{}).get('pgs_by_state',[])))
PY
)
  [[ $total == 97 ]] || die phase_b_pg_count_$total
}

phase_b_wait_quiet(){
  local root label target out deadline round=0 consecutive=0 previous_objects= previous_stored= objects stored bytes osd json vals running queue endpoint pending all_idle target_ok obj_file
  root=$1; label=$2; target=$3; out="$root/recovery/$label-quiet"; deadline=$((SECONDS+1800)); mkdir -m 0700 -p "$out/raw"; printf 'epoch\tround\tosd\tcompact_running\tcompact_queue_len\n' >"$out/osd.tsv"; printf 'epoch\tround\tendpoint\tpending_compaction_bytes\n' >"$out/tikv.tsv"; printf 'epoch\tround\tobjects\tstored\tbytes_used\ttarget\tstable_count\n' >"$out/pool.tsv"
  while (( SECONDS < deadline )); do
    round=$((round+1)); all_idle=1
    health_snapshot "$out/health-$round" paused; phase_b_health_97 "$out/health-$round"
    for osd in "${EXPECTED_OSDS[@]}"; do json="$out/raw/osd-$osd-$round.json"; timeout 20 env CEPH_CONF="$CEPH_CONF" ceph tell "osd.$osd" perf dump >"$json" || die phase_b_osd_perf_poll; vals=$(phase_b_osd_perf_values "$json") || die phase_b_osd_perf_unavailable; read -r running queue <<<"$vals"; printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$osd" "$running" "$queue" >>"$out/osd.tsv"; [[ $running == 0 && $queue == 0 ]] || all_idle=0; done
    for endpoint in 10.20.1.150 10.20.1.151 10.20.1.152; do pending=$(phase_b_pending_total "$endpoint") || die phase_b_tikv_pending_unavailable; printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$endpoint" "$pending" >>"$out/tikv.tsv"; [[ $pending == 0 ]] || all_idle=0; done
    obj_file="$out/pool-$round"; phase_b_pool_stats "$obj_file"; read -r objects bytes < <(awk -F '\t' 'NR==2{print $2,$3}' "$obj_file"); stored=$bytes
    target_ok=1; if [[ $target != NONE ]]; then [[ $target =~ ^[0-9]+$ ]] || die phase_b_invalid_target; (( objects >= target-8192 && objects <= target+8192 )) || target_ok=0; fi
    if [[ $objects == "$previous_objects" && $stored == "$previous_stored" && $all_idle == 1 && $target_ok == 1 ]]; then consecutive=$((consecutive+1)); elif (( all_idle == 1 && target_ok == 1 )); then consecutive=1; else consecutive=0; fi
    previous_objects=$objects; previous_stored=$stored; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$objects" "$stored" "$bytes" "$target" "$consecutive" >>"$out/pool.tsv"
    if (( consecutive >= 3 )); then printf '%s\t%s\t%s\n' "$objects" "$stored" "$bytes" >"$out/final-pool.tsv"; printf 'QUIET_PASS\t%s\tobjects=%s\tstored=%s\n' "$label" "$objects" "$stored" >"$out/PASS"; return 0; fi
    sleep 10
  done
  die phase_b_quiet_timeout_$label
}

phase_b_compact_once(){
  local root label osd before_count rc
  root=$1; label=$2; [[ $label =~ ^(SEED|W0[1-3])$ ]] || die phase_b_compact_label; [[ -f "$root/compact-audit.tsv" ]] || printf 'record_type\tepoch\tcell\tosd\trc\n' >"$root/compact-audit.tsv"
  for osd in "${EXPECTED_OSDS[@]}"; do before_count=$(awk -F '\t' -v c="$label" -v o="$osd" '$1=="attempt"&&$3==c&&$4==o{n++} END{print n+0}' "$root/compact-audit.tsv"); (( before_count == 0 )) || die phase_b_compact_duplicate; [[ $(env CEPH_CONF="$CEPH_CONF" ceph fsid | tr -d '[:space:]') == "$EXPECTED_FSID" ]] || die phase_b_fsid_drift; printf 'attempt\t%s\t%s\t%s\n' "$(date +%s)" "$label" "$osd" >>"$root/compact-audit.tsv"; set +e; timeout 60 sudo ceph tell "osd.$osd" compact >"$root/compact-$label-osd-$osd.log" 2>&1; rc=$?; set -e; printf 'result\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$label" "$osd" "$rc" >>"$root/compact-audit.tsv"; (( rc == 0 )) || die phase_b_compact_failed; done
}

phase_b_full_clean(){
  local root label target
  root=$1; label=$2; target=$3; phase_b_gc "$root" "$label"; if [[ $label =~ ^(SEED|W0[1-3])$ ]]; then phase_b_compact_once "$root" "$label"; fi; phase_b_wait_quiet "$root" "$label" "$target"
}

phase_b_verify_compact_budget(){
  local root=$1 attempts per label osd
  [[ -f "$root/compact-audit.tsv" ]] || die phase_b_compact_audit_missing
  attempts=$(awk -F '\t' '$1=="attempt"{n++} END{print n+0}' "$root/compact-audit.tsv"); (( attempts == 24 )) || die phase_b_compact_budget
  for osd in "${EXPECTED_OSDS[@]}"; do per=$(awk -F '\t' -v o="$osd" '$1=="attempt"&&$4==o{n++} END{print n+0}' "$root/compact-audit.tsv"); (( per == 4 )) || die phase_b_compact_per_osd; done
  for label in SEED W01 W02 W03; do for osd in "${EXPECTED_OSDS[@]}"; do [[ $(awk -F '\t' -v c="$label" -v o="$osd" '$1=="attempt"&&$3==c&&$4==o{n++} END{print n+0}' "$root/compact-audit.tsv") == 1 ]] || die phase_b_compact_matrix; done; done
}

phase_b_manifest(){
  local mnt out dir p name i
  mnt=$1; out=$2; dir="$mnt/test_dir/04-6b-$RUN_ID/mseqwrite"; [[ -d $dir && ! -L $dir ]] || die phase_b_mseqwrite_dir; : >"$out"
  for i in $(seq 0 15); do name="mseqwrite.$i.0"; p="$dir/$name"; [[ -f $p && ! -L $p && $(stat -c %s "$p") == 4294967296 ]] || die phase_b_mseqwrite_asset_$i; printf '%s\t%s\t%s\t%s\n' "$name" "$(stat -c %i "$p")" "$(stat -c %s "$p")" "$(stat -c %Y "$p")" >>"$out"; done
  sha256sum "$out" >"$out.sha256"
}

phase_b_seqwrite_manifest(){
  local mnt out dir p
  mnt=$1; out=$2; dir="$mnt/test_dir/04-6b-$RUN_ID/seqwrite"; p="$dir/seqwrite.0.0"
  [[ -f $p && ! -L $p && $(stat -c %s "$p") == 34359738368 ]] || die phase_b_seqwrite_asset
  printf 'seqwrite.0.0\t%s\t%s\t%s\n' "$(stat -c %i "$p")" "$(stat -c %s "$p")" "$(stat -c %Y "$p")" >"$out"
  sha256sum "$out" >"$out.sha256"
}

phase_b_write_endpoint(){
  local root mount_label label kind mnt fuse out dir bs size jobs filename
  root=$1; mount_label=$2; label=$3; kind=$4; mnt=$5; fuse=$6; out="$root/cells/$label"; mkdir -m 0700 -p "$out/bwlog"
  if [[ $kind == seqwrite ]]; then dir="$mnt/test_dir/04-6b-$RUN_ID/seqwrite"; bs=4M; size=32G; jobs=1; filename=seqwrite.0.0; [[ -f "$dir/$filename" && ! -L "$dir/$filename" && $(stat -c %s "$dir/$filename") == 34359738368 ]] || die phase_b_seqwrite_asset_contract_$label
  else dir="$mnt/test_dir/04-6b-$RUN_ID/mseqwrite"; bs=4M; size=4G; jobs=16; filename=; phase_b_manifest "$mnt" "$out/mseqwrite-manifest.tsv"; fi
  health_snapshot "$out/health-pre" paused; mechanism_snapshot "$out/pre-mechanism" "$mnt" "$root/mounts/$mount_label/mount-state.tsv"
  local -a fio_cmd=("$FIO" --name="$label" --directory="$dir" --rw=write --bs="$bs" --size="$size" --numjobs="$jobs" --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=0 --refill_buffers --time_based --runtime=180 --group_reporting --per_job_logs=1 --output-format=json --output="$out/fio.json" --write_bw_log="$out/bwlog/$label" --log_avg_msec=1000)
  if [[ $kind == seqwrite ]]; then fio_cmd+=(--filename="$filename"); else fio_cmd+=(--filename_format='mseqwrite.$jobnum.0'); fi
  printf '%q ' timeout 300 "${fio_cmd[@]}" >>"$root/commands.sh"; printf '\n' >>"$root/commands.sh"; local fio_rc; set +e; timeout 300 "${fio_cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; fio_rc=$?; set -e; printf '%s\n' "$fio_rc" >"$out/fio.rc"; ((fio_rc==0)) || die phase_b_fio_failed_$label
  date +%s%N >"$out/fio-end-ns.txt"; mechanism_snapshot "$out/post-mechanism" "$mnt" "$root/mounts/$mount_label/mount-state.tsv"; health_snapshot "$out/health-post" paused
  [[ $kind != seqwrite || $(stat -c %s "$dir/$filename") == 34359738368 ]] || die phase_b_seqwrite_size_drift_$label; printf 'ENDPOINT_PASS\t%s\tfuse=%s\tioengine=psync\tiodepth=1\n' "$label" "$fuse" >"$out/PASS"
}

phase_b_cleanup_assets(){
  local root mnt dir manifest count name p ino size mtime seqdir seqmanifest
  phase_b_verify_compact_budget "$1"
  root=$1; mnt=$2; dir="$mnt/test_dir/04-6b-$RUN_ID/mseqwrite"; manifest="$root/seed/mseqwrite-manifest.tsv"; count=0; [[ -f $manifest && -f "$manifest.sha256" ]] || die phase_b_manifest_missing; (cd "$(dirname "$manifest")" && sha256sum -c "$(basename "$manifest").sha256") >/dev/null || die phase_b_manifest_hash
  while IFS=$'\t' read -r name ino size mtime; do [[ $name =~ ^mseqwrite\.(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15)\.0$ ]] || die phase_b_manifest_path; p="$dir/$name"; [[ -f $p && ! -L $p && $(stat -c %i "$p") == "$ino" && $(stat -c %s "$p") == "$size" ]] || die phase_b_manifest_drift; unlink -- "$p" || die phase_b_unlink_failed; count=$((count+1)); done <"$manifest"
  (( count == 16 )) || die phase_b_manifest_count
  rmdir -- "$dir" || die phase_b_asset_dir_not_empty
  seqdir="$mnt/test_dir/04-6b-$RUN_ID/seqwrite"; seqmanifest="$root/seed/seqwrite-manifest.tsv"
  [[ -f $seqmanifest && -f "$seqmanifest.sha256" ]] || die phase_b_seqwrite_manifest_missing
  (cd "$(dirname "$seqmanifest")" && sha256sum -c "$(basename "$seqmanifest").sha256") >/dev/null || die phase_b_seqwrite_manifest_hash
  IFS=$'\t' read -r name ino size mtime <"$seqmanifest"; [[ $name == seqwrite.0.0 ]] || die phase_b_seqwrite_manifest_path; p="$seqdir/$name"
  [[ -f $p && ! -L $p && $(stat -c %i "$p") == "$ino" && $(stat -c %s "$p") == "$size" ]] || die phase_b_seqwrite_manifest_drift
  unlink -- "$p" || die phase_b_seqwrite_unlink_failed; rmdir -- "$seqdir" || die phase_b_seqwrite_dir_not_empty
  rmdir -- "${dir%/*}" || die phase_b_asset_parent_not_empty
}

phase_b(){
  local run ack root old_lease active active_mnt active_out mount_label kind ep fuse scrub_done attempt
  run=$1; ack=$2; root=${T046B_REMOTE_ROOT:-$REMOTE_ROOT}; old_lease=$LEASE; active=0; active_mnt=; active_out=; scrub_done=0; attempt=${T046B_PHASE_B_ATTEMPT:-1}; valid_run "$run"; [[ $ack == I_ACK_04_6B_PHASE_B_$run ]] || die phase_b_ack_missing; [[ $attempt =~ ^[1-9][0-9]*$ ]] || die phase_b_invalid_attempt
  [[ $root == /tmp/production/opencode-04-6b-$run && -f $root/inventory/PASS ]] || die phase_b_inventory_required; [[ -r $CEPH_CONF && -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die phase_b_runtime_identity
  local pbr
  if [[ $attempt == 1 ]]; then pbr="$root/phase-b"; LEASE="${run}-04-6b-phase-b"; else pbr="$root/phase-b-attempt$attempt"; LEASE="${run}-04-6b-a${attempt}-phase-b"; fi
  [[ ! -e $pbr/RUN_STARTED ]] || die phase_b_automatic_resume_refused; mkdir -m 0700 -p "$pbr/seed" "$pbr/recovery" "$pbr/mounts" "$pbr/cells" "$pbr/state"; printf '%s\n' "$attempt" >"$pbr/RUN_STARTED"; : >"$pbr/commands.sh"
  printf 'cell\tarm\torder\tendpoint\tworkload\tfuse\twindow\nW01\tA\t1\tW01-SW\tseqwrite\t256K\t[15,175)\nW01\tA\t2\tW01-MSW\tmseqwrite\t256K\t[15,175)\nW02\tF1\t1\tW02-MSW\tmseqwrite\t1M\t[15,175)\nW02\tF1\t2\tW02-SW\tseqwrite\t1M\t[15,175)\nW03\tF1\t1\tW03-SW\tseqwrite\t1M\t[15,175)\nW03\tF1\t2\tW03-MSW\tmseqwrite\t1M\t[15,175)\nW04\tA\t1\tW04-MSW\tmseqwrite\t256K\t[15,175)\nW04\tA\t2\tW04-SW\tseqwrite\t256K\t[15,175)\n' >"$pbr/phase-b-matrix.tsv"
  phase_b_exit(){ local x=$?; if (( ! scrub_done )); then scrub_restore "$pbr" || x=70; fi; if ((active)) && [[ -d $active_mnt ]]; then graceful_umount "$active_mnt" "$active_out" || x=70; fi; LEASE=$old_lease; exit "$x"; }; trap phase_b_exit EXIT
  foreign_fio_gate; business_identity "$pbr/inventory-pre"
  python3 "$ANALYZER" phase-a --root "$root" --output "$pbr/phase-a-recheck.json" >"$pbr/phase-a-recheck.stdout" || die phase_b_phase_a_recheck
  python3 - "$pbr/phase-a-recheck.json" <<'PY' || die phase_b_r8_candidate
import json,sys
d=json.load(open(sys.argv[1]));
if len(d.get('cells',[])) != 8: raise SystemExit('Phase A cell count is not 8')
if any('CANDIDATE' in str(x.get('screen','')) for x in d.get('pairs',[])): raise SystemExit('R8 candidate remains')
PY
  scrub_pause "$pbr"; health_snapshot "$pbr/health-pre-paused" paused; phase_b_full_clean "$pbr" PRE NONE
  if (( attempt < 3 )); then
    phase_b_pool_stats "$pbr/recovery/O0-before"
    active_mnt=/tmp/jfs-t046b-$run-SEED; active_out="$pbr/mounts/SEED"; active=1; mount_a "$pbr" SEED 0 rw 256K; [[ ! -e "$active_mnt/test_dir/04-6b-$run/mseqwrite" && ! -L "$active_mnt/test_dir/04-6b-$run/mseqwrite" ]] || die phase_b_seed_path_exists; mkdir -m 0700 -p "$active_mnt/test_dir/04-6b-$run/mseqwrite"
    local -a seed_cmd=("$FIO" --name=seed --directory="$active_mnt/test_dir/04-6b-$run/mseqwrite" --filename_format='mseqwrite.$jobnum.0' --rw=write --bs=4M --size=4G --numjobs=16 --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --output-format=json --output="$pbr/seed/fio.json"); local src; printf '%q ' timeout 900 "${seed_cmd[@]}" >>"$pbr/commands.sh"; printf '\n' >>"$pbr/commands.sh"; set +e; timeout 900 "${seed_cmd[@]}" >"$pbr/seed/fio.stdout" 2>"$pbr/seed/fio.stderr"; src=$?; set -e; printf '%s\n' "$src" >"$pbr/seed/fio.rc"; ((src==0)) || die phase_b_seed_failed
    python3 - "$pbr/seed/fio.json" <<'PY' || die phase_b_seed_fio_contract
import json,sys
d=json.load(open(sys.argv[1])); jobs=d.get('jobs',[])
if len(jobs)!=16 or any(int(j.get('error',-1))!=0 for j in jobs): raise SystemExit('seed must contain 16 successful jobs')
if any(int(j.get('write',{}).get('io_bytes',0)) < 4294967296 for j in jobs): raise SystemExit('seed job did not write 4GiB')
PY
    phase_b_manifest "$active_mnt" "$pbr/seed/mseqwrite-manifest.tsv"
  else
    local prior="$root/phase-b-attempt2" prior_attempts prior_results
    [[ $attempt -ge 3 && -f "$prior/RUN_STARTED" && ! -e "$prior/PHASE_B_PASS" && -f "$prior/seed/mseqwrite-manifest.tsv" && -f "$prior/seed/mseqwrite-manifest.tsv.sha256" && -f "$prior/compact-audit.tsv" && -f "$prior/recovery/O0-before" ]] || die phase_b_attempt3_adoption_contract
    (cd "$prior/seed" && sha256sum -c mseqwrite-manifest.tsv.sha256) >/dev/null || die phase_b_attempt3_prior_manifest_hash
    prior_attempts=$(awk -F '\t' '$1=="attempt"&&$3=="SEED"{n++} END{print n+0}' "$prior/compact-audit.tsv"); prior_results=$(awk -F '\t' '$1=="result"&&$3=="SEED"&&$5==0{n++} END{print n+0}' "$prior/compact-audit.tsv")
    (( prior_attempts == 6 && prior_results == 6 )) || die phase_b_attempt3_prior_compact_contract
    cp "$prior/recovery/O0-before" "$pbr/recovery/O0-before"; cp "$prior/recovery/O0-before.json" "$pbr/recovery/O0-before.json"
    active_mnt=/tmp/jfs-t046b-$run-SEED; active_out="$pbr/mounts/SEED"; active=1; mount_a "$pbr" SEED 0 rw 256K
    phase_b_manifest "$active_mnt" "$pbr/seed/mseqwrite-manifest.tsv"; cmp -s "$prior/seed/mseqwrite-manifest.tsv" "$pbr/seed/mseqwrite-manifest.tsv" || die phase_b_attempt3_prior_manifest_drift
    [[ ! -e "$active_mnt/test_dir/04-6b-$run/seqwrite" && ! -L "$active_mnt/test_dir/04-6b-$run/seqwrite" ]] || die phase_b_attempt3_seqwrite_path_exists
    mkdir -m 0700 -p "$active_mnt/test_dir/04-6b-$run/seqwrite"
    local -a seq_seed_cmd=("$FIO" --name=seqwrite --directory="$active_mnt/test_dir/04-6b-$run/seqwrite" --rw=write --bs=4M --size=32G --numjobs=1 --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --output-format=json --output="$pbr/seed/seqwrite-fio.json"); local seq_src; printf '%q ' timeout 900 "${seq_seed_cmd[@]}" >>"$pbr/commands.sh"; printf '\n' >>"$pbr/commands.sh"; set +e; timeout 900 "${seq_seed_cmd[@]}" >"$pbr/seed/seqwrite-fio.stdout" 2>"$pbr/seed/seqwrite-fio.stderr"; seq_src=$?; set -e; printf '%s\n' "$seq_src" >"$pbr/seed/seqwrite-fio.rc"; ((seq_src==0)) || die phase_b_seqwrite_seed_failed
    python3 - "$pbr/seed/seqwrite-fio.json" <<'PY' || die phase_b_seqwrite_seed_fio_contract
import json,sys
d=json.load(open(sys.argv[1])); jobs=d.get('jobs',[])
if len(jobs)!=1 or int(jobs[0].get('error',-1))!=0: raise SystemExit('seqwrite seed must contain one successful job')
if int(jobs[0].get('write',{}).get('io_bytes',0)) < 34359738368: raise SystemExit('seqwrite seed did not write 32GiB')
PY
    phase_b_seqwrite_manifest "$active_mnt" "$pbr/seed/seqwrite-manifest.tsv"
  fi
  graceful_umount "$active_mnt" "$active_out"; active=0; active_mnt=; active_out=
  if (( attempt < 3 )); then
    phase_b_full_clean "$pbr" SEED NONE
  else
    phase_b_gc "$pbr" SEED; cp "$root/phase-b-attempt2/compact-audit.tsv" "$pbr/compact-audit.tsv"; printf 'SEED compact adopted from phase-b-attempt2; no additional SEED compact issued, preserving the approved four-per-OSD total budget.\n' >"$pbr/seed/compact-provenance.txt"; phase_b_wait_quiet "$pbr" SEED NONE
  fi
  phase_b_pool_stats "$pbr/recovery/O1-after-seed"
  for mount_label in W01 W02 W03 W04; do [[ $mount_label == W02 || $mount_label == W03 ]] && fuse=1M || fuse=256K; active_mnt=/tmp/jfs-t046b-$run-$mount_label; active_out="$pbr/mounts/$mount_label"; active=1; mount_a "$pbr" "$mount_label" 0 rw "$fuse"; case $mount_label in W01) run_b_order=(W01-SW:seqwrite W01-MSW:mseqwrite);; W02) run_b_order=(W02-MSW:mseqwrite W02-SW:seqwrite);; W03) run_b_order=(W03-SW:seqwrite W03-MSW:mseqwrite);; W04) run_b_order=(W04-MSW:mseqwrite W04-SW:seqwrite);; esac; for ep in "${run_b_order[@]}"; do kind=${ep#*:}; ep=${ep%%:*}; phase_b_write_endpoint "$pbr" "$mount_label" "$ep" "$kind" "$active_mnt" "$fuse"; done; graceful_umount "$active_mnt" "$active_out"; active=0; active_mnt=; active_out=; phase_b_full_clean "$pbr" "$mount_label" "$(awk -F '\t' 'NR==2{print $2}' "$pbr/recovery/O1-after-seed")"; done
  phase_b_verify_compact_budget "$pbr"
  python3 "$ANALYZER" phase-b --root "$pbr" --output "$pbr/phase-b-verdict.json" || die phase_b_analysis_failed
  if python3 - "$pbr/phase-b-verdict.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); raise SystemExit(0 if any('CANDIDATE' in str(x.get('screen','')) for x in d.get('pairs',[])) else 1)
PY
  then
    active_mnt=/tmp/jfs-t046b-$run-CLEANUP; active_out="$pbr/mounts/CLEANUP"; active=1; mount_a "$pbr" CLEANUP 0 rw 256K
    phase_b_cleanup_assets "$pbr" "$active_mnt"; graceful_umount "$active_mnt" "$active_out"; active=0; active_mnt=; active_out=
    phase_b_gc "$pbr" CLEANUP; phase_b_wait_quiet "$pbr" CLEANUP "$(awk -F '\t' 'NR==2{print $2}' "$pbr/recovery/O0-before")"
    printf 'CANDIDATE_ASSETS_CLEANED\n' >"$pbr/CANDIDATE_ASSETS_CLEANED"
  else
    printf 'ASSETS_RETAINED_FOR_PHASE_C\n' >"$pbr/ASSETS_RETAINED_FOR_PHASE_C"
  fi
  scrub_restore "$pbr" || die phase_b_scrub_restore; scrub_done=1; health_snapshot "$pbr/health-post" unpaused
  business_identity "$pbr/inventory-post"; cmp -s "$pbr/inventory-pre/reference-mount.tsv" "$pbr/inventory-post/reference-mount.tsv" || die phase_b_business_mount_drift; cmp -s "$pbr/inventory-pre/current-status.json.identity" "$pbr/inventory-post/current-status.json.identity" || die phase_b_business_volume_drift; cmp -s "$pbr/inventory-pre/reference-process.tsv" "$pbr/inventory-post/reference-process.tsv" || die phase_b_business_process_drift; cmp -s "$pbr/inventory-pre/read-assets-sample-sha256.tsv" "$pbr/inventory-post/read-assets-sample-sha256.tsv" || die phase_b_read_assets_drift
  cut -f1-3 "$pbr/inventory-pre/protected-assets.tsv" >"$pbr/inventory-pre/protected-assets-path-inode-size.tsv"; cut -f1-3 "$pbr/inventory-post/protected-assets.tsv" >"$pbr/inventory-post/protected-assets-path-inode-size.tsv"; cmp -s "$pbr/inventory-pre/protected-assets-path-inode-size.tsv" "$pbr/inventory-post/protected-assets-path-inode-size.tsv" || die phase_b_protected_assets_identity_drift
  printf 'PHASE_B_PASS\n' >"$pbr/PHASE_B_PASS"; trap - EXIT; LEASE=$old_lease; printf 'T046B_PHASE_B_PASS\t%s\n' "$pbr"
}

phase_plan(){
  valid_run "$1"
  case ${2:-} in A) printf 'T046B_PHASE_A_READY\tRUN=%s\tentry=phase-a\n' "$1";; B) printf 'T046B_PHASE_B_READY\tRUN=%s\tentry=phase-b\n' "$1";; C|D) printf 'T046B_PHASE_NOT_IMPLEMENTED\tRUN=%s\tPHASE=%s\trc=42\n' "$1" "$2"; return 42;; *) die invalid_phase;; esac
}

self_test(){ valid_run 20260904-224411; python3 "$ANALYZER" self-test; printf 'T046B_DRIVER_SELF_TEST_PASS\n'; }

case ${1:-} in
  offline-gate) [[ $# -eq 2 ]] || usage; offline_gate "$2";;
  inventory-plan) [[ $# -eq 2 ]] || usage; inventory_plan "$2";;
  inventory) [[ $# -eq 2 ]] || usage; inventory_remote "$2";;
  phase-a) [[ $# -eq 3 ]] || usage; phase_a "$2" "$3";;
  phase-b) [[ $# -eq 3 ]] || usage; phase_b "$2" "$3";;
  phase-plan) [[ $# -eq 3 ]] || usage; phase_plan "$2" "$3";;
  --self-test) [[ $# -eq 1 ]] || usage; self_test;;
  *) usage;;
esac
