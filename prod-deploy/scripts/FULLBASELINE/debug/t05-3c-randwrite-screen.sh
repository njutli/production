#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 05-3c six-cell descriptive randwrite screen, adapted from the frozen final
# 05-3b runner. No layout, compact, GC, restart, or performance drift stop.
# Scrub pause/restore is delegated to the separately approved lease helper.
MODE=${1:-}; RUN_ID=${2:-}; ACK=${3:-}; SCRUB_ACK=${4:-}
RUNNER_PATH=$(realpath -e -- "${BASH_SOURCE[0]}")
META=${T053C_META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
JFS=${T053C_JFS:-/tmp/juicefs-1.4.1-patched}; REF=${T053C_REF:-/mnt/juicefs}
EVIDENCE=${T053C_EVIDENCE_ROOT:-/tmp/production/05-3c-${RUN_ID}}
MOUNT_BASE=${T053C_MOUNT_BASE:-/tmp/jfs-05-3c-${RUN_ID}}
FIO=${T053C_FIO:-fio}; CEPH_CONF=${T053C_CEPH_CONF:-$EVIDENCE/inventory/ceph-msgr8.conf}
readonly CEPH_AUTH_ARGS=(--keyring /etc/ceph/ceph.client.admin.keyring -n client.admin)
WORKER_HELPER=${T053C_WORKER_HELPER:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/t05-baseline-guard.py}
SCRUB_CONTROL=${T053C_SCRUB_CONTROL:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/u141d-scrub-control.sh}
ANALYZER=${T053C_ANALYZER:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/t05-3b-randrw-analyze.py}
JFS_MD5=24fae0852051c80ca571cb2f20275d46; CEPH_CONF_SHA256=c1e917e23b2888511aaffd55a2fb0697e8e3c9814180ea858eda500bc27bed48
FILE_BYTES=1073741824; LAST_ERROR=unknown; ACTIVE_PHASE_OUT=; ACTIVE_MOUNT=; ACTIVE_LEASE=
CAPACITY_REQUIRE_PLAN=1
CAPACITY_BATCH=trend; WORKER_PID=; WORKER_STARTTIME=
ACTIVE_FIO_PID=; ACTIVE_FIO_START=
CAPACITY_START_CHECK=1
readonly WRITE_CELLS=(256K-before 16K-screen 64K-screen 1M-screen 4M-screen 256K-after)
trap 'exit 130' INT
trap 'exit 143' TERM

die() { LAST_ERROR=$*; printf 'T053C_RUNNER_FAIL\t%s\n' "$*" >&2; exit 42; }
valid_run() { [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID; }
safe_root() {
    [[ "$1" != / && ! -L "$1" ]] || die unsafe_root
    if [[ ${T053C_OFFLINE_GATE:-0} == 1 ]]; then
        [[ "$1" == /tmp/t05-3c-gate-*/evidence ]] || die unsafe_root
        [[ -d "$(dirname -- "$1")" && ! -L "$(dirname -- "$1")" ]] || die unsafe_gate_parent
    else
        [[ "$1" == "/tmp/production/05-3c-${RUN_ID}" ]] || die unsafe_root
        [[ -d /tmp/production && ! -L /tmp/production &&
           $(realpath -e /tmp/production) == /tmp/production ]] || die unsafe_parent
    fi
}
safe_mount() { [[ "$MOUNT_BASE" == "/tmp/jfs-05-3c-${RUN_ID}" ]] || die unsafe_mount_path; }
record() { local f=$1; shift; printf '%q ' "$@" >>"$f"; printf '\n' >>"$f"; }
on_exit() {
    local rc=$1; trap - EXIT
    if (( rc != 0 )) && [[ -n "$ACTIVE_PHASE_OUT" && -d "$ACTIVE_PHASE_OUT" ]]; then
        printf '%s\tFAIL\trc=%s\treason=%s\n' "$(date -Is)" "$rc" "$LAST_ERROR" >>"$EVIDENCE/incidents.tsv"
        printf 'FAIL\trc=%s\treason=%s\n' "$rc" "$LAST_ERROR" >"$ACTIVE_PHASE_OUT/phase-status.tsv"
        local still_running=0 current_start= n
        if [[ -n "$ACTIVE_FIO_PID" ]] && kill -0 "$ACTIVE_FIO_PID" 2>/dev/null; then
            current_start=$(awk '{print $22}' "/proc/$ACTIVE_FIO_PID/stat" 2>/dev/null || true)
            if [[ "$current_start" == "$ACTIVE_FIO_START" ]]; then
                kill -TERM "$ACTIVE_FIO_PID" 2>/dev/null || true
                for n in $(seq 1 30); do kill -0 "$ACTIVE_FIO_PID" 2>/dev/null || break; sleep 1; done
                if kill -0 "$ACTIVE_FIO_PID" 2>/dev/null; then still_running=1; else wait "$ACTIVE_FIO_PID" 2>/dev/null || true; fi
            else
                still_running=1
            fi
        fi
        if (( still_running )); then
            printf 'LOAD_RECOVERY_REQUIRED\tpid=%s\n' "$ACTIVE_FIO_PID" >"$ACTIVE_PHASE_OUT/load-recovery-required.tsv"; rc=70
        fi
        if (( ! still_running )) && [[ -n "$ACTIVE_MOUNT" ]] && findmnt -rn -M "$ACTIVE_MOUNT" >/dev/null 2>&1; then
            if timeout 300 "$JFS" umount "$ACTIVE_MOUNT" >"$ACTIVE_PHASE_OUT/exit-umount.stdout" 2>"$ACTIVE_PHASE_OUT/exit-umount.stderr" &&
               ! findmnt -rn -M "$ACTIVE_MOUNT" >/dev/null 2>&1; then
                rmdir "$ACTIVE_MOUNT" 2>/dev/null || true
            else
                printf 'MOUNT_RECOVERY_REQUIRED\t%s\n' "$ACTIVE_MOUNT" >"$ACTIVE_PHASE_OUT/mount-recovery-required.tsv"; rc=70
            fi
        fi
        if [[ -n "$ACTIVE_LEASE" ]] && ! restore_scrub "$ACTIVE_LEASE" "$ACTIVE_PHASE_OUT"; then
            printf 'SCRUB_RESTORE_REQUIRED\t%s\n' "$ACTIVE_LEASE" >"$ACTIVE_PHASE_OUT/scrub-recovery-required.tsv"; rc=70
        fi
    fi
    exit "$rc"
}

write_cells() { printf '%s\n' "${WRITE_CELLS[@]}"; }
cell_bs() { printf '%s\n' "${1%%-*}"; }
prefix_for() { [[ $1 == randwrite ]] || die unsupported_direction; printf storage_test; }

plan() {
    valid_run; safe_root "$EVIDENCE"; safe_mount; [[ ! -e "$EVIDENCE" ]] || die output_exists
    mkdir -m 0700 -p "$EVIDENCE"; : >"$EVIDENCE/commands-plan.sh"
    local old_analyzer; old_analyzer="$(dirname -- "$ANALYZER")/t05-3-randrw-analyze.py"
    local f; for f in "$RUNNER_PATH" "$WORKER_HELPER" "$SCRUB_CONTROL" "$ANALYZER" "$old_analyzer"; do
        [[ -f "$f" && ! -L "$f" ]] || die "script_dependency_missing_$f"
    done
    sha256sum "$RUNNER_PATH" "$WORKER_HELPER" "$SCRUB_CONTROL" "$ANALYZER" "$old_analyzer" >"$EVIDENCE/scripts.sha256"
    printf 'position\tcell\tbs\tprefix\n' >"$EVIDENCE/matrix.tsv"
    local c n=0; for c in "${WRITE_CELLS[@]}"; do n=$((n+1)); printf '%s\t%s\t%s\tstorage_test\n' "$n" "$c" "$(cell_bs "$c")" >>"$EVIDENCE/matrix.tsv"; done
    local -a cmd; local logarg
    record "$EVIDENCE/commands-plan.sh" "# private msgr8 config required: $CEPH_CONF"
    record "$EVIDENCE/commands-plan.sh" timeout 180 env "CEPH_CONF=$CEPH_CONF" "$JFS" mount -d --max-fuse-io 256K --max-uploads 150 --max-downloads 200 --buffer-size 300 --cache-size 0 "$META" "$MOUNT_BASE-randwrite"
    for c in "${WRITE_CELLS[@]}"; do
        logarg="$EVIDENCE/cells/randwrite-$c/bw/randwrite-$c"
        cmd=(env "CEPH_CONF=$CEPH_CONF" "$FIO" --directory="$MOUNT_BASE-randwrite/test_dir" --name="randwrite-$c" --filename_format='storage_test.$jobnum.0' --rw=randwrite --bs="$(cell_bs "$c")" --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --filesize=1G --size=1G --time_based --runtime=180 --group_reporting --allow_file_create=0 --fallocate=none --openfiles=128 --randrepeat=1 --per_job_logs=1 --write_bw_log="$logarg" --log_avg_msec=0 --output="$EVIDENCE/cells/randwrite-$c/fio.json" --output-format=json+)
        record "$EVIDENCE/commands-plan.sh" timeout 600 "${cmd[@]}"
    done
    record "$EVIDENCE/commands-plan.sh" timeout 300 "$JFS" umount "$MOUNT_BASE-randwrite"
    printf 'batch\tosd\tdb_start_free_bytes\tbatch_write_budget_bytes\tdb_growth_budget_bytes\tobserved_free_bytes\tdb_stop_free_bytes\tsource\tformula\n' >"$EVIDENCE/capacity-plan.template.tsv"
    local i; for i in 0 1 2 3 4 5; do printf 'trend\t%s\tFILL\tFILL\tFILL\tFILL\tFILL\tFILL\tFILL\n' "$i" >>"$EVIDENCE/capacity-plan.template.tsv"; done
    printf 'T053C_PLAN_ONLY_PASS\troot=%s\twrite_cells=6\n' "$EVIDENCE"
}

inventory_assets() {
    local prefix=$1 out="$EVIDENCE/inventory/${1}.tsv" candidate="$EVIDENCE/inventory/${1}.candidate.$$" file i
    [[ -d "$REF/test_dir" && ! -L "$REF/test_dir" ]] || die reference_missing
    mkdir -m 0700 -p "$EVIDENCE/inventory"; : >"$candidate"
    for i in $(seq 0 127); do file="$REF/test_dir/$prefix.$i.0"; [[ -f "$file" && ! -L "$file" ]] || die "${prefix}_file_$i"; printf '%s\t%s\t%s\n' "${file##*/}" "$(stat -c %i "$file")" "$(stat -c %s "$file")" >>"$candidate"; done
    awk -F '\t' '$3 != 1073741824 {bad=1} END{exit bad}' "$candidate" || die "${prefix}_size"
    if [[ -e "$out" ]]; then cmp -s "$out" "$candidate" || die "${prefix}_identity_changed"; rm -- "$candidate"; else mv -- "$candidate" "$out"; fi
}
reference_mount_gate() {
    mkdir -m 0700 -p "$EVIDENCE/inventory/reference"; findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$EVIDENCE/inventory/reference/findmnt.tsv" || die reference_not_mounted
    grep -Fq "JuiceFS:juicefs-prod $REF fuse.juicefs" "$EVIDENCE/inventory/reference/findmnt.tsv" || die reference_volume_identity
}

capacity_plan_gate() {
    local p="$EVIDENCE/capacity-plan.tsv"; [[ -f "$p" && ! -L "$p" ]] || die capacity_plan_missing
    python3 - "$p" "$CAPACITY_BATCH" <<'PY' || die capacity_plan_invalid
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t')); wanted=sys.argv[2]
if not rows: raise SystemExit('empty capacity plan')
if 'batch' not in rows[0]: raise SystemExit('capacity plan must be per-batch')
rows=[r for r in rows if r.get('batch')==wanted]
need={'batch','osd','db_start_free_bytes','batch_write_budget_bytes','db_growth_budget_bytes','observed_free_bytes','source','formula'}
if not rows or not need.issubset(rows[0]) or not ({'db_stop_free_bytes','db_stop_budget_bytes'} & set(rows[0])): raise SystemExit('missing capacity columns')
if len(rows)!=6 or {r.get('osd') for r in rows}!={str(i) for i in range(6)}: raise SystemExit('capacity plan must contain osd 0..5 exactly once')
for r in rows:
    keys=['db_start_free_bytes','batch_write_budget_bytes','db_growth_budget_bytes','observed_free_bytes'] + (['db_stop_free_bytes'] if 'db_stop_free_bytes' in r else ['db_stop_budget_bytes'])
    for k in keys:
        if not r.get(k) or not r[k].isdigit() or int(r[k]) <= 0: raise SystemExit('missing/nonpositive capacity field')
    if not r.get('source') or not r.get('formula'): raise SystemExit('missing capacity provenance')
    if int(r['db_start_free_bytes']) < int(r['db_stop_free_bytes']) + int(r['db_growth_budget_bytes']): raise SystemExit('start budget inconsistent')
    if int(r['observed_free_bytes']) < int(r['db_start_free_bytes']): raise SystemExit('observed DB free below planned start')
PY
}
capacity_gate() {
    local out=$1; mkdir -m 0700 -p "$out"
    timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" df -f json >"$out/ceph-df.json" || die ceph_df
    timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" osd df -f json >"$out/osd-df.json" || die ceph_osd_df
    local i; for i in $(seq 0 5); do timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" tell "osd.$i" perf dump >"$out/osd-$i-perf.json" || die "osd_${i}_perf"; done
    if (( CAPACITY_REQUIRE_PLAN == 0 )); then
        python3 - "$out/ceph-df.json" "$out/osd-df.json" "$out/db-capacity.tsv" "$out" <<'PY' || die read_capacity_gate
import json,sys
df,odf=json.load(open(sys.argv[1])),json.load(open(sys.argv[2])); avail=(df.get('stats') or {}).get('total_avail',(df.get('stats') or {}).get('total_avail_bytes'))
if not isinstance(avail,(int,float)) or avail < 15*1024**4: raise SystemExit('raw available below 15TiB')
nodes=odf.get('nodes') or []; out=open(sys.argv[3],'w'); out.write('osd\tdb_free_bytes\tslow_bytes\n')
if len(nodes)!=6 or {n.get('id') for n in nodes}!=set(range(6)): raise SystemExit('OSD capacity rows missing/duplicate')
for n in nodes:
    oid=int(n.get('id')); perf=json.load(open(f'{sys.argv[4]}/osd-{oid}-perf.json')); blue=perf.get('bluefs') or {}; rocks=perf.get('rocksdb') or {}
    if not all(isinstance(blue.get(k),(int,float)) for k in ('db_total_bytes','db_used_bytes','slow_used_bytes')): raise SystemExit('bluefs DB/slow field missing')
    val=blue['db_total_bytes']-blue['db_used_bytes']; slow=blue['slow_used_bytes']
    util=n.get('utilization')
    if val < 2*1024**3 or slow != 0 or not isinstance(util,(int,float)) or not 0 <= util < 80: raise SystemExit('read DB/slow/util capacity gate')
    out.write(f"{oid}\t{int(val)}\t{int(slow)}\n")
PY
        return
    fi
    capacity_plan_gate
    python3 - "$out/ceph-df.json" "$out/osd-df.json" "$EVIDENCE/capacity-plan.tsv" "$out/db-capacity.tsv" "$EVIDENCE/capacity-baseline.tsv" "$out" "$CAPACITY_START_CHECK" "$CAPACITY_BATCH" <<'PY' || die capacity_gate
import csv,json,os,sys
df,odf=map(lambda p:json.load(open(p)),sys.argv[1:3]); plan_rows=list(csv.DictReader(open(sys.argv[3]),delimiter='\t'))
start_check=int(sys.argv[7]); wanted=sys.argv[8]
if plan_rows and 'batch' in plan_rows[0]: plan_rows=[r for r in plan_rows if r.get('batch')==wanted]
plan={r['osd']:r for r in plan_rows}
avail=(df.get('stats') or {}).get('total_avail',(df.get('stats') or {}).get('total_avail_bytes'))
if not isinstance(avail,(int,float)) or avail < 15*1024**4: raise SystemExit('raw available below 15TiB')
nodes=odf.get('nodes') or []; seen=set(); out=open(sys.argv[4],'w'); out.write('osd\tdb_free_bytes\tstart_free_bytes\tstop_budget_bytes\tstop_floor_bytes\n')
for n in nodes:
    oid=str(n.get('id')); 
    if oid not in plan: continue
    util=n.get('utilization');
    if not isinstance(util,(int,float)) or not 0 <= util < 80: raise SystemExit('OSD utilization missing or >=80%')
    oid=int(n.get('id')); perf=json.load(open(f'{sys.argv[6]}/osd-{oid}-perf.json')); blue=perf.get('bluefs') or {}; rocks=perf.get('rocksdb') or {}
    if not all(isinstance(blue.get(k),(int,float)) for k in ('db_total_bytes','db_used_bytes','slow_used_bytes')): raise SystemExit('bluefs DB/slow field missing')
    val=blue['db_total_bytes']-blue['db_used_bytes']
    if blue['slow_used_bytes'] != 0: raise SystemExit('slow capacity gate')
    oid=str(oid); start=int(plan[oid]['db_start_free_bytes']); stop_free=int(plan[oid]['db_stop_free_bytes']) if plan[oid].get('db_stop_free_bytes') else None; budget=int(plan[oid]['db_stop_budget_bytes']) if plan[oid].get('db_stop_budget_bytes') else None
    observed=int(plan[oid]['observed_free_bytes']); growth=int(plan[oid]['db_growth_budget_bytes'])
    if start_check and val < start: raise SystemExit('DB batch startfree below plan for osd '+oid)
    if stop_free is None: raise SystemExit('explicit DB stop floor required')
    # The whole-run growth budget is a live stop line, not just plan prose.
    floor=max(stop_free, observed-growth)
    if val < floor: raise SystemExit('DB stop budget exhausted for osd '+oid)
    out.write(f'{oid}\t{int(val)}\t{start}\t{budget if budget is not None else ""}\t{floor}\n'); seen.add(oid)
if seen != set(plan) or seen != {str(i) for i in range(6)} or len(nodes)!=6: raise SystemExit('DB capacity absent/duplicate')
PY
}

health_gate() {
    local out=$1; mkdir -m 0700 -p "$out"
    timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" -s -f json >"$out/ceph-status.json" || die ceph_status
    timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" osd stat -f json >"$out/osd-stat.json" || die ceph_osd
    timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" pg dump pgs_brief -f json >"$out/pgs.json" || die ceph_pg
    timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" osd dump -f json >"$out/osd-dump.json" || die ceph_osd_dump
    python3 - "$out/ceph-status.json" "$out/osd-stat.json" "$out/pgs.json" "$out/osd-dump.json" <<'PY' || die health_gate
import json,sys
s,o,p,d=[json.load(open(x)) for x in sys.argv[1:]]; h=s.get('health') or {}; checks=set((h.get('checks') or {})); raw=d.get('flags') or []
flags={x.replace('_','-') for x in (raw.split(',') if isinstance(raw,str) else raw) if x}
forbidden={'noout','nodown','noup','noin','nobackfill','norebalance','norecover','pause','pauserd','pausewr'}
if not ((h.get('status')=='HEALTH_OK' and not checks and not (flags & forbidden)) or (h.get('status')=='HEALTH_WARN' and checks=={'OSDMAP_FLAGS'} and {'noscrub','nodeep-scrub'}.issubset(flags) and not (flags & forbidden))): raise SystemExit('health warning/error or unowned OSD flag')
if o.get('num_osds')!=6 or o.get('num_up_osds')!=6 or o.get('num_in_osds')!=6: raise SystemExit('OSD not 6/6')
rows=p.get('pg_stats');
if not isinstance(rows,list) or not rows or any(x.get('state')!='active+clean' for x in rows): raise SystemExit('PG not active+clean')
PY
}
state_snapshot() {
    local out=$1 host; mkdir -m 0700 -p "$out"
    timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" df -f json >"$out/ceph-df.json" || die ceph_df
    timeout 30 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" osd df -f json >"$out/osd-df.json" || die ceph_osd_df
    for host in 150 151 152; do curl -fsS --connect-timeout 2 --max-time 5 "http://10.20.1.$host:20180/metrics" >"$out/tikv-$host.prom" || die "tikv_metrics_$host"; done
}
log_space_gate() {
    local avail
    avail=$(df -Pk "$EVIDENCE" 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$avail" =~ ^[0-9]+$ ]] || die log_space_unreadable
    printf '%s\t%s\n' "$(date -Is)" "$avail" >>"$EVIDENCE/disk-free-kib.tsv"
    (( avail >= 20*1024*1024 )) || die log_space_below_20GiB
}
helper_call() {
    local action=$1 out=$2; [[ -f "$WORKER_HELPER" && ! -L "$WORKER_HELPER" ]] || die worker_helper_missing
    [[ "$action" == mount || "$action" == boundary ]] || die "worker_helper_unsupported_action_${action}"
    [[ -n "${ACTIVE_MOUNT:-}" ]] || die worker_mount_missing_for_helper
    local -a extra=(); [[ "$action" == boundary ]] && { [[ "$WORKER_PID" =~ ^[0-9]+$ ]] || die worker_pid_missing; extra=(--pid "$WORKER_PID"); }
    python3 "$WORKER_HELPER" --config "$CEPH_CONF" --juicefs-exe "$JFS" \
        --require-token "$ACTIVE_MOUNT" --require-token '--cache-size 0' "${extra[@]}" --output "$out" || die "worker_helper_${action}"
    if [[ "$action" == boundary ]]; then
        [[ $(awk -F '\t' 'NR==2{print $3}' "$out") == "$WORKER_STARTTIME" ]] || die worker_starttime_changed
    else
        WORKER_STARTTIME=$(awk -F '\t' 'NR==2{print $3}' "$out")
    fi
}

preflight() {
    local direction=$1; [[ "$direction" == randwrite ]] || die unsupported_direction; CAPACITY_REQUIRE_PLAN=1; valid_run; safe_root "$EVIDENCE"; safe_mount; log_space_gate; reference_mount_gate
    [[ -f "$EVIDENCE/scripts.sha256" && ! -L "$EVIDENCE/scripts.sha256" ]] || die frozen_scripts_missing
    sha256sum -c "$EVIDENCE/scripts.sha256" >"$EVIDENCE/scripts-check.tsv" || die frozen_scripts_changed
    inventory_assets storage_test
    pgrep -x fio >/dev/null 2>&1 && die foreign_fio
    [[ -x "$JFS" && ! -L "$JFS" && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die juicefs_identity
    # The companion guard validates the private config and actual child worker
    # after mount.  The runner never edits /etc/ceph/ceph.conf.
    [[ -f "$CEPH_CONF" && ! -L "$CEPH_CONF" ]] || die private_msgr8_conf_missing
    [[ $(sha256sum "$CEPH_CONF" | awk '{print $1}') == "$CEPH_CONF_SHA256" ]] || die private_msgr8_conf_hash
    grep -Eq 'ms_async_op_threads[[:space:]]*=[[:space:]]*8' "$CEPH_CONF" || die private_msgr8_conf_not_8
    mkdir -m 0700 -p "$EVIDENCE/inventory"; sha256sum "$CEPH_CONF" >"$EVIDENCE/inventory/ceph-msgr8.sha256"; "$FIO" --version >"$EVIDENCE/inventory/fio-version.txt" || die fio_identity
    timeout 30 "$JFS" status "$META" >"$EVIDENCE/inventory/volume-status.json" 2>"$EVIDENCE/inventory/volume-status.stderr" || die volume_status
    python3 - "$EVIDENCE/inventory/volume-status.json" <<'PY' || die volume_identity
import json,sys
s=(json.load(open(sys.argv[1])).get('Setting') or {})
if s.get('Name')!='juicefs-prod' or s.get('UUID')!='e1b69ea9-0e3d-427d-bea9-8765928afa66' or s.get('BlockSize')!=256: raise SystemExit(1)
PY
    [[ -r /etc/ceph/ceph.client.admin.keyring && ! -L /etc/ceph/ceph.client.admin.keyring ]] || die explicit_keyring_unavailable
    fsid=$(timeout 20 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" fsid) || die ceph_fsid; [[ "$fsid" == f8137e5a-8af2-11f1-aa1c-4df480fc234d ]] || die ceph_fsid_changed; printf 'fsid\t%s\n' "$fsid" >"$EVIDENCE/inventory/cluster-identity.tsv"
    local available; available=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo) || die memory_probe; [[ "$available" =~ ^[0-9]+$ ]] && (( available >= 134217728 )) || die memory_below_128GiB; printf 'mem_available_kib\t%s\n' "$available" >"$EVIDENCE/inventory/memory-preflight.tsv"
    [[ "$direction" == randwrite ]] && capacity_plan_gate; health_gate "$EVIDENCE/health-preflight"; capacity_gate "$EVIDENCE/health-preflight/capacity"
}

pause_scrub() {
    local phase=$1 out="$EVIDENCE/phase-$1" lease; [[ "$phase" == write ]] || die scrub_phase; lease="${RUN_ID}-write-phase-b"; local fsid
    [[ "$SCRUB_ACK" == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die scrub_ack_missing
    [[ -x "$SCRUB_CONTROL" && ! -L "$SCRUB_CONTROL" ]] || die scrub_control_missing; mkdir -m 0700 -p "$out" "$EVIDENCE/scrub"
    ACTIVE_LEASE=$lease
    fsid=$(timeout 20 ceph --conf "$CEPH_CONF" "${CEPH_AUTH_ARGS[@]}" fsid) || die ceph_fsid
    U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$EVIDENCE/scrub" "$SCRUB_CONTROL" inspect "$lease" >"$out/scrub-inspect.txt" || die scrub_inspect
    U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$EVIDENCE/scrub" "$SCRUB_CONTROL" plan-pause "$lease" >"$out/scrub-plan.txt" || die scrub_plan
    U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$EVIDENCE/scrub" "$SCRUB_CONTROL" pause "$lease" "$fsid" "$SCRUB_ACK" >"$out/scrub-pause.txt" || die scrub_pause
    U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$EVIDENCE/scrub" "$SCRUB_CONTROL" verify-paused "$lease" >"$out/scrub-verify.txt" || die scrub_verify
}
restore_scrub() {
    local lease=$1 out=$2; [[ -x "$SCRUB_CONTROL" ]] || return 1
    [[ -e "$EVIDENCE/scrub/u141d-scrub-control-$lease.tsv" ]] || return 0
    U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$EVIDENCE/scrub" "$SCRUB_CONTROL" plan-restore "$lease" >"$out/scrub-plan-restore.txt" 2>&1 || return 1
    U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$EVIDENCE/scrub" "$SCRUB_CONTROL" restore "$lease" >"$out/scrub-restore.txt" 2>&1 || return 1
    U141D_CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$EVIDENCE/scrub" "$SCRUB_CONTROL" verify-restored "$lease" >"$out/scrub-verify-restored.txt" 2>&1
}

mount_private() {
    local direction=$1 phase=$2; ACTIVE_MOUNT="$MOUNT_BASE-$direction"; local out="$EVIDENCE/phase-$phase"; mkdir -m 0700 -p "$out"; [[ ! -e "$ACTIVE_MOUNT" && ! -L "$ACTIVE_MOUNT" ]] || die private_mount_exists; mkdir -m 0700 "$ACTIVE_MOUNT"
    local -a cmd=(env "CEPH_CONF=$CEPH_CONF" "$JFS" mount -d --max-fuse-io 256K --max-uploads 150 --max-downloads 200 --buffer-size 300 --cache-size 0 "$META" "$ACTIVE_MOUNT")
    record "$EVIDENCE/commands.sh" timeout 180 "${cmd[@]}"; timeout 180 "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr" || die mount_failed
    findmnt -rn -M "$ACTIVE_MOUNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/findmnt.tsv" || die private_mount_missing; grep -Fq "JuiceFS:juicefs-prod $ACTIVE_MOUNT fuse.juicefs" "$out/findmnt.tsv" || die private_volume_identity
    helper_call mount "$out/mount-worker.tsv"; WORKER_PID=$(awk -F '\t' 'NR==2{print $1}' "$out/mount-worker.tsv"); [[ "$WORKER_PID" =~ ^[0-9]+$ ]] || die worker_pid_missing
}

passive_recovery() {
    local out="$EVIDENCE/recovery-$(date +%s%N)" i ok=0; mkdir -m 0700 -p "$out"
    for i in $(seq 1 30); do
        mkdir -m 0700 -p "$out/sample-$i"; log_space_gate; health_gate "$out/sample-$i/health" && capacity_gate "$out/sample-$i/capacity" && state_snapshot "$out/sample-$i/state" || die passive_recovery_gate
        if python3 - "$out/sample-$i/state" "$out/sample-$i/capacity" <<'PY'
import glob,json,re,sys
state,capacity=sys.argv[1:]
for host in ('150','151','152'):
    path=f'{state}/tikv-{host}.prom'; text=open(path).read(); vals=[]
    for line in text.splitlines():
        if not line.startswith('tikv_engine_pending_compaction_bytes{') or 'cf="default"' not in line or 'db="kv"' not in line: continue
        vals.append(float(line.split('}',1)[1].strip().split()[0]))
    if len(vals)!=1 or vals[0] != 0: raise SystemExit(1)
for path in glob.glob(f'{capacity}/osd-*-perf.json'):
    rocks=(json.load(open(path)).get('rocksdb') or {})
    if not isinstance(rocks.get('compact_running'),(int,float)) or not isinstance(rocks.get('compact_queue_len'),(int,float)): raise SystemExit(1)
    if rocks['compact_running'] != 0 or rocks['compact_queue_len'] != 0: raise SystemExit(1)
if len(glob.glob(f'{capacity}/osd-*-perf.json')) != 6: raise SystemExit(1)
PY
        then ok=$((ok+1)); else ok=0; fi
        (( ok >= 3 )) && { printf 'PASS\t%s\n' "$ok" >"$out/status.tsv"; return; }
        sleep 30
    done
    printf 'STOP\tpassive_recovery_timeout\n' >"$out/status.tsv"; die passive_recovery_timeout
}

sample_loop() {
    trap - EXIT INT TERM
    local pid=$1 out=$2 n=0; mkdir -m 0700 -p "$out"
    while kill -0 "$pid" 2>/dev/null; do
        [[ $(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true) == "$ACTIVE_FIO_START" ]] || return 1
        n=$((n+1)); mkdir -m 0700 -p "$out/$n"
        if ! ( log_space_gate ) || ! ( health_gate "$out/$n/health" ) || ! ( capacity_gate "$out/$n/capacity" ); then
            touch "$out/CONTAMINATED"
            if [[ $(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true) == "$ACTIVE_FIO_START" ]]; then kill -TERM "$pid" 2>/dev/null || true; fi
            return 1
        fi
        sleep 10
    done
    return 0
}

analyze_cell() {
    local direction=$1 cell=$2 out="$EVIDENCE/cells/$1-$2"; [[ -f "$ANALYZER" ]] || die analyzer_missing
    python3 "$ANALYZER" cell --cell "$out" --direction "$direction" --output "$out/derived.json" >"$out/analyzer.stdout" || die analyzer_failed
    python3 - "$out/derived.json" <<'PY' || die formal_window_not_measured
import json,sys
d=json.load(open(sys.argv[1])); f=d.get('formal') or d.get('result',{}).get('formal') or {}
if f.get('window_status') != 'MEASURED': raise SystemExit(1)
PY
}

run_cell() {
    local direction=$1 cell=$2 out="$EVIDENCE/cells/$1-$2" prefix bs rc pid sampler; [[ "$direction" == randwrite ]] || die unsupported_direction; bs=$(cell_bs "$cell"); prefix=$(prefix_for "$direction"); [[ ! -e "$out" && ! -L "$out" ]] || die cell_already_started; mkdir -m 0700 -p "$out/bw"; log_space_gate
    pgrep -x fio >/dev/null 2>&1 && die foreign_fio_during_phase
    health_gate "$out/health-pre"; capacity_gate "$out/health-pre/capacity"; state_snapshot "$out/state-pre"; helper_call boundary "$out/worker-boundary-pre.tsv"; printf '{"mode":"per_io_completion","numjobs":128,"bs_bytes":%s,"log_avg_msec":0,"formal_window_s":[15,175],"write_tail_guard_s":5,"write_tail_max_per_job":8,"write_tail_max_fraction":0.002}\n' "$(numfmt --from=iec "$bs")" >"$out/logging-contract.json"
    find "$ACTIVE_MOUNT/test_dir" -maxdepth 1 -type f -name "$prefix.*.0" -printf '%f\t%i\t%s\n' | sort -V >"$out/assets-before.tsv"; [[ $(wc -l <"$out/assets-before.tsv") -eq 128 ]] || die assets_missing; cmp -s "$EVIDENCE/inventory/${prefix}.tsv" "$out/assets-before.tsv" || die asset_identity_changed
    local -a cmd=(env "CEPH_CONF=$CEPH_CONF" "$FIO" --directory="$ACTIVE_MOUNT/test_dir" --name="$direction-$cell" --filename_format="$prefix.\$jobnum.0" --rw="$direction" --bs="$bs" --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --filesize=1G --size=1G --time_based --runtime=180 --group_reporting --allow_file_create=0 --fallocate=none --openfiles=128 --randrepeat=1 --per_job_logs=1 --write_bw_log="$out/bw/${direction}-${cell}" --log_avg_msec=0 --output="$out/fio.json" --output-format=json+)
    record "$EVIDENCE/commands.sh" timeout 600 "${cmd[@]}"; date +%s%N >"$out/fio-wrapper-start-epoch-ns.txt"; set +e; timeout 600 "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr" & pid=$!; set -e
    ACTIVE_FIO_PID=$pid; ACTIVE_FIO_START=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
    sample_loop "$pid" "$out/samples" & sampler=$!; set +e; wait "$pid"; rc=$?; wait "$sampler"; local src=$?; set -e; ACTIVE_FIO_PID=; ACTIVE_FIO_START=; date +%s%N >"$out/fio-end-epoch-ns.txt"; printf '%s\n' "$rc" >"$out/fio.rc"; (( rc == 0 && src == 0 )) || die "fio_or_sample_failed_${direction}_${cell}"; [[ $(find "$out/bw" -maxdepth 1 -type f -name '*.log' | wc -l) -eq 128 ]] || die per_job_logs_missing
    find "$ACTIVE_MOUNT/test_dir" -maxdepth 1 -type f -name "$prefix.*.0" -printf '%f\t%i\t%s\n' | sort -V >"$out/assets-after.tsv"; cmp -s "$out/assets-before.tsv" "$out/assets-after.tsv" || die asset_identity_changed
    health_gate "$out/health-post"; capacity_gate "$out/health-post/capacity"; state_snapshot "$out/state-post"; helper_call boundary "$out/worker-boundary-post.tsv"; analyze_cell "$direction" "$cell"
}

cell_bw() { python3 - "$EVIDENCE/cells/$1-$2/derived.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); f=d.get('formal') or {}; v=f.get('mean_MiB_s');
if not isinstance(v,(int,float)): raise SystemExit(1)
print(float(v))
PY
}
anchor_drift() {
    local before after; before=$(cell_bw randwrite 256K-before); after=$(cell_bw randwrite 256K-after)
    python3 - "$before" "$after" >"$EVIDENCE/anchor-drift.tsv" <<'PY'
import sys
a,b=map(float,sys.argv[1:]); d=abs(a-b)/((a+b)/2) if a+b else 1
print('before_MiB_s\tafter_MiB_s\tD_percent\tdecision')
print(f'{a:.6f}\t{b:.6f}\t{100*d:.4f}\tDESCRIPTIVE_ONLY')
PY
}

finish_phase() {
    local phase=$1; local out="$EVIDENCE/phase-$phase"; record "$EVIDENCE/commands.sh" timeout 300 "$JFS" umount "$ACTIVE_MOUNT"; timeout 300 "$JFS" umount "$ACTIVE_MOUNT" >"$out/umount.stdout" 2>"$out/umount.stderr" || die umount_failed; findmnt -rn -M "$ACTIVE_MOUNT" >/dev/null 2>&1 && die mount_still_present; rmdir "$ACTIVE_MOUNT" || die mount_dir_not_empty; ACTIVE_MOUNT=; printf 'PASS\t%s\n' "$(date -Is)" >"$out/phase-status.tsv"
}
run_write() {
    [[ ! -e "$EVIDENCE/phase-write" ]] || die phase_already_started
    [[ "$ACK" == I_ACK_05_3C_RANDWRITE_${RUN_ID} ]] || die ack_missing
    preflight randwrite
    mkdir -m 0700 -p "$EVIDENCE/cells" "$EVIDENCE/phase-write"
    ACTIVE_PHASE_OUT="$EVIDENCE/phase-write"; trap 'on_exit "$?"' EXIT
    pause_scrub write; mount_private randwrite write
    passive_recovery
    CAPACITY_START_CHECK=0
    local c; for c in "${WRITE_CELLS[@]}"; do run_cell randwrite "$c"; done
    anchor_drift
    finish_phase write
    restore_scrub "$ACTIVE_LEASE" "$ACTIVE_PHASE_OUT" || die scrub_restore_failed
    ACTIVE_LEASE=; ACTIVE_PHASE_OUT=; trap - EXIT
    printf 'T053C_RANDWRITE_SCREEN_PASS\troot=%s\tcells=6\tdecision=DESCRIPTIVE_ONLY\n' "$EVIDENCE"
}

inventory() {
    valid_run; safe_root "$EVIDENCE"; reference_mount_gate; inventory_assets storage_test
    printf 'T053C_INVENTORY_PASS\troot=%s\tassets=128\n' "$EVIDENCE"
}

case "$MODE" in
    plan) plan;;
    inventory) inventory;;
    preflight) preflight randwrite;;
    write-phase) run_write;;
    *) die 'usage: plan|inventory|preflight RUN_ID; write-phase RUN_ID I_ACK_05_3C_RANDWRITE_RUN_ID I_ACK_GLOBAL_CEPH_SCRUB_PAUSE';;
esac
