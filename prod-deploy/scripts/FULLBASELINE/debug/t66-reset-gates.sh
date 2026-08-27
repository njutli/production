#!/usr/bin/env bash
# Ceph/TiKV stability gates for one 03-22c arm. No cluster or volume lifecycle here.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
t66_check_run_id "$RUN_ID"
t66_check_cluster "$CLUSTER"
t66_check_instance "$INSTANCE"
[[ "$INSTANCE" != SMOKE-* ]] || t66_die 'smoke instances do not run reset gates'
if [[ "$ACTION" == post-abort-final-destroy ]]; then
  [[ ${T66_ABORT_RESET_AUTH:-} == "03-22c-abort-reset-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t66_die "set exact T66_ABORT_RESET_AUTH=03-22c-abort-reset-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  [[ -z ${T66_RESET_AUTH:-} ]] || t66_die 'normal reset authorization is forbidden for abort cleanup'
else
  [[ ${T66_RESET_AUTH:-} == "03-22c-reset-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t66_die "set exact T66_RESET_AUTH=03-22c-reset-${RUN_ID}-${INSTANCE}-${CLUSTER}"
fi

OUT="/tmp/production/opencode-t3.22c-${RUN_ID}/instances/${INSTANCE}"
if [[ "$ACTION" == post-abort-final-destroy ]]; then
  t66_record_authorization "$RUN_ID" "reset-$ACTION-$INSTANCE" "$T66_ABORT_RESET_AUTH"
else
  t66_record_authorization "$RUN_ID" "reset-$ACTION-$INSTANCE" "$T66_RESET_AUTH"
fi
RESET="$OUT/reset-$ACTION"
META=$(t66_meta_url "$RUN_ID" "$INSTANCE")
PRIVATE_CONF="$OUT/ceph-t66.conf"
FLAVOR=''
SEED_DIR=''
case "$INSTANCE" in
  SEED-CANARY|SEED-FORMAL|RESTORE-CANARY-B1c|RESTORE-CANARY-D1|RESTORE-PREFLIGHT-B1c|RESTORE-PREFLIGHT-D1|ARM-CANARY-B1c|ARM-CANARY-D1|GC-CANARY|GC-PREFLIGHT|GC-ARM-CANARY|G0[1-8]|R0[1-8])
    FLAVOR=$(t66_seed_flavor "$INSTANCE")
    SEED_DIR=$(t66_seed_dir "$RUN_ID" "$FLAVOR")
    ;;
esac
[[ ! -e "$RESET" ]] || t66_die "reset output already exists; preserve first attempt: $RESET"
mkdir -p "$RESET"
t66_require_tools "$T66_JUICEFS_BIN" python3 curl sudo sshpass ssh
t66_make_ssh_array
export CEPH_CONF="$PRIVATE_CONF"

[[ $(sudo ceph health) == HEALTH_OK ]] || t66_die 'Ceph health is not HEALTH_OK'
! pgrep -x fio >/dev/null || t66_die 'foreign fio exists on client'
for node in "${T66_NODES[@]}"; do
  ! "${T66_SSH[@]}" "$node" 'pgrep -x fio' >/dev/null 2>&1 || t66_die "foreign fio exists on $node"
  mem_kib=$("${T66_SSH[@]}" "$node" "awk '/^MemAvailable:/{print \$2}' /proc/meminfo")
  [[ "$mem_kib" =~ ^[0-9]+$ ]] && (( mem_kib >= 67108864 )) ||
    t66_die "MemAvailable below 64GiB on $node: ${mem_kib:-invalid}KiB"
done

pool_objects() {
  sudo ceph df --format=json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=next((x for x in d["pools"] if x["name"]=="juicefs-data"),None)
assert p is not None
s=p["stats"]; print("%s\t%s\t%s" % (s["objects"],s["stored"],s["bytes_used"]))'
}

osd_values() {
  python3 - "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
found={}
def walk(x,path=()):
    if isinstance(x,dict):
        for k,v in x.items():
            if k in ("compact_running","compact_queue_len") and isinstance(v,(int,float)):
                found.setdefault(k,[]).append((path+(k,),v))
            if k=="kv_sync_lat" and isinstance(v,dict) and isinstance(v.get("avgtime"),(int,float)):
                found.setdefault(k,[]).append((path+(k,"avgtime"),v["avgtime"]))
            walk(v,path+(k,))
    elif isinstance(x,list):
        for i,v in enumerate(x): walk(v,path+(str(i),))
walk(d)
for k in ("compact_running","compact_queue_len","kv_sync_lat"):
    vals=found.get(k,[])
    if len(vals)!=1: raise SystemExit(f"{k}: expected one value, got {vals}")
print("\t".join(str(found[k][0][1]) for k in ("compact_running","compact_queue_len","kv_sync_lat")))
PY
}

cooldown_once() {
  local label=$1 osd json vals running queued kv ok=1
  while read -r osd; do
    json="$RESET/osd-${osd}-$(date +%s%N).json"
    sudo ceph tell "osd.$osd" perf dump > "$json"
    vals=$(osd_values "$json") || return 1
    IFS=$'\t' read -r running queued kv <<< "$vals"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$label" "$osd" "$running" "$queued" "$kv" >> "$RESET/osd-cooldown.tsv"
    [[ "$running" == 0 && "$queued" == 0 ]] || ok=0
    awk -v v="$kv" 'BEGIN{exit !(v>=0 && v<0.002)}' || ok=0
  done < "$RESET/osd-ids.txt"
  (( ok == 1 ))
}

compact_and_wait() {
  local label=$1 osd deadline=$((SECONDS+600))
  while read -r osd; do
    printf 'sudo ceph tell osd.%q compact\n' "$osd" >> "$OUT/commands.sh"
    sudo ceph tell "osd.$osd" compact >/dev/null
  done < "$RESET/osd-ids.txt"
  sleep 5
  while (( SECONDS < deadline )); do
    if cooldown_once "$label"; then return 0; fi
    sleep 5
  done
  return 1
}

pending_total() {
  curl -fsS --connect-timeout 3 --max-time 8 "http://$1:${T66_TIKV_STATUS_PORT}/metrics" |
    awk '/^tikv_engine_pending_compaction_bytes\{/{sum+=$2;found=1} END{if(!found)exit 1;printf "%.0f\n",sum}'
}

tikv_idle_gate() {
  local consecutive=0 deadline=$((SECONDS+900)) node value all_zero
  while (( SECONDS < deadline )); do
    all_zero=1
    for node in "${T66_NODES[@]}"; do
      value=$(pending_total "$node") || return 1
      printf '%s\t%s\t%s\n' "$(date +%s)" "$node" "$value" >> "$RESET/tikv-pending.tsv"
      (( value == 0 )) || all_zero=0
    done
    if (( all_zero == 1 )); then consecutive=$((consecutive+1)); else consecutive=0; fi
    (( consecutive >= 3 )) && return 0
    sleep 10
  done
  return 1
}

nvme_quiet_gate() {
  local node pid rc=0 evidence summary
  declare -a pids=()
  for node in "${T66_NODES[@]}"; do
    "${T66_SSH[@]}" "$node" 'set -euo pipefail
printf "epoch\twrites_completed\tsectors_written\tinflight\n"
for ((i=0;i<=60;i++)); do
  read -r w s f < <(awk '\''{print $5,$7,$9}'\'' /sys/block/nvme1n1/stat)
  printf "%s\t%s\t%s\t%s\n" "$(date +%s)" "$w" "$s" "$f"
  ((i==60)) || sleep 1
done' > "$RESET/nvme-${node}.tsv" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  ((rc==0)) || return 1
  for node in "${T66_NODES[@]}"; do
    evidence="$RESET/nvme-${node}.tsv"
    summary="$evidence.summary"
    t66_nvme_quiet_evidence_ok "$evidence" > "$summary" || return 1
  done
}

mapfile -t OSD_IDS < <(sudo ceph osd ls)
(( ${#OSD_IDS[@]} == 6 )) || t66_die "expected frozen six OSDs, got ${#OSD_IDS[@]}"
printf '%s\n' "${OSD_IDS[@]}" > "$RESET/osd-ids.txt"
sudo ceph osd dump > "$RESET/osd-dump.txt"

case "$ACTION" in
  prepare)
    [[ -s "$OUT/LAYOUT_PASS" && -s "$OUT/volume.tsv" ]] || t66_die 'layout or mounted volume state missing'
    pool_objects > "$RESET/pool-before.tsv"
    compact_and_wait pre-gc || t66_die 'pre-GC OSD cooldown failed'
    printf '%q gc --compact %q\n' "$T66_JUICEFS_BIN" "$META" >> "$OUT/commands.sh"
    "$T66_JUICEFS_BIN" gc --compact "$META" > "$RESET/juicefs-gc.log" 2>&1 || t66_die 'temporary-volume gc --compact failed'
    compact_and_wait post-gc || t66_die 'post-GC OSD cooldown failed'
    tikv_idle_gate || t66_die 'temporary TiKV pending compaction did not reach three consecutive zeros'
    nvme_quiet_gate || t66_die 'underlying NVMe did not meet the frozen bounded-idle profile in the final 30s of a 60s gate'
    [[ $(sudo ceph health) == HEALTH_OK ]] || t66_die 'Ceph changed after quiet period'
    pool_objects > "$RESET/pool-ready.tsv"
    printf '%s\n' "$(date +%s)" > "$OUT/READY_FOR_FIO"
    printf 'PREPARE_PASS instance=%s (no global drop_caches was executed)\n' "$INSTANCE"
    ;;
  post-destroy)
    [[ -s "$OUT/volume.destroyed.tsv" && ! -e "$OUT/volume.tsv" ]] || t66_die 'volume destroy evidence missing'
    compact_and_wait post-destroy || t66_die 'post-destroy OSD cooldown failed'
    pool_objects > "$RESET/pool-post-1.tsv"; sleep 15
    pool_objects > "$RESET/pool-post-2.tsv"; sleep 15
    pool_objects > "$RESET/pool-post-3.tsv"
    python3 - "$OUT/pool-pre-format.tsv" "$RESET/pool-post-1.tsv" "$RESET/pool-post-2.tsv" "$RESET/pool-post-3.tsv" <<'PY'
import sys
def obj(p): return int(open(p).read().split()[0])
base=obj(sys.argv[1]); vals=[obj(x) for x in sys.argv[2:]]
assert max(vals)-min(vals) <= 4096, (base,vals)
assert all(abs(x-base) <= 8192 for x in vals), (base,vals)
print("pool_return_pass",base,vals)
PY
    printf '%s\n' "$(date +%s)" > "$OUT/POST_DESTROY_PASS"
    printf 'POST_DESTROY_PASS instance=%s\n' "$INSTANCE"
    ;;
  seed-return)
    [[ "$INSTANCE" == GC-CANARY || "$INSTANCE" == GC-PREFLIGHT || "$INSTANCE" == GC-ARM-CANARY || "$INSTANCE" =~ ^G0[1-8]$ ]] ||
      t66_die 'seed-return requires a dedicated GC instance'
    [[ -s "$SEED_DIR/pool-seed.tsv" && -s "$SEED_DIR/gc-baseline.tsv" ]] || t66_die 'seed baselines missing'
    if [[ "$INSTANCE" == GC-PREFLIGHT ]]; then
      [[ -s "$OUT/GC_INSPECT_PASS" && $(awk -F '\t' '$1=="leaked"{print $2}' "$OUT/gc-inspect.tsv") == 0 ]] ||
        t66_die 'GC-PREFLIGHT requires a zero-leak inspect result'
    else
      [[ -s "$OUT/GC_DELETE_PASS" && -s "$OUT/gc-postcheck.tsv" ]] || t66_die 'GC delete/postcheck evidence missing'
    fi
    compact_and_wait seed-return || t66_die 'post-GC OSD cooldown failed'
    pool_objects > "$RESET/pool-return-1.tsv"; sleep 15
    pool_objects > "$RESET/pool-return-2.tsv"; sleep 15
    pool_objects > "$RESET/pool-return-3.tsv"
    python3 - "$SEED_DIR/pool-seed.tsv" "$RESET/pool-return-1.tsv" "$RESET/pool-return-2.tsv" "$RESET/pool-return-3.tsv" <<'PY'
import sys
def row(p): return tuple(map(int, open(p).read().split()))
base=row(sys.argv[1]); vals=[row(x) for x in sys.argv[2:]]
objects=[x[0] for x in vals]
assert max(objects)-min(objects) <= 4096, (base, vals)
assert all(abs(x[0]-base[0]) <= 8192 for x in vals), (base, vals)
print("seed_pool_return_pass", base, vals)
PY
    printf '%s\n' "$(date +%s)" > "$OUT/SEED_RETURN_PASS"
    printf 'SEED_RETURN_PASS instance=%s\n' "$INSTANCE"
    ;;
  post-final-destroy)
    [[ "$INSTANCE" == GC-CANARY || "$INSTANCE" == G08 ]] || t66_die 'post-final-destroy requires GC-CANARY or G08'
    [[ -s "$SEED_DIR/seed.destroyed.tsv" && -s "$SEED_DIR/pool-pre-format.tsv" ]] || t66_die 'seed destroy/pre-format evidence missing'
    compact_and_wait final-destroy || t66_die 'post-destroy OSD cooldown failed'
    pool_objects > "$RESET/pool-final-1.tsv"; sleep 15
    pool_objects > "$RESET/pool-final-2.tsv"; sleep 15
    pool_objects > "$RESET/pool-final-3.tsv"
    python3 - "$SEED_DIR/pool-pre-format.tsv" "$RESET/pool-final-1.tsv" "$RESET/pool-final-2.tsv" "$RESET/pool-final-3.tsv" <<'PY'
import sys
def obj(p): return int(open(p).read().split()[0])
base=obj(sys.argv[1]); vals=[obj(x) for x in sys.argv[2:]]
assert max(vals)-min(vals) <= 4096, (base, vals)
assert all(abs(x-base) <= 8192 for x in vals), (base, vals)
print("final_pool_return_pass", base, vals)
PY
    printf '%s\n' "$(date +%s)" > "$OUT/POST_FINAL_DESTROY_PASS"
    printf 'POST_FINAL_DESTROY_PASS instance=%s\n' "$INSTANCE"
    ;;
  post-abort-final-destroy)
    [[ "$INSTANCE" =~ ^G0[1-7]$ ]] || t66_die 'post-abort-final-destroy requires an early G01..G07 cleanup instance'
    [[ -s "$OUT/ABORT_SEED_DESTROY_PASS" && -s "$SEED_DIR/seed.destroyed.tsv" &&
       $(awk -F '\t' '$1=="mode"{print $2}' "$SEED_DIR/seed.destroyed.tsv") == abort-invalid-run &&
       $(awk -F '\t' '$1=="gc_instance"{print $2}' "$SEED_DIR/seed.destroyed.tsv") == "$INSTANCE" &&
       -s "$SEED_DIR/pool-pre-format.tsv" ]] ||
      t66_die 'abort seed destroy evidence or pre-format baseline missing'
    compact_and_wait abort-final-destroy || t66_die 'post-abort-destroy OSD cooldown failed'
    pool_objects > "$RESET/pool-abort-final-1.tsv"; sleep 15
    pool_objects > "$RESET/pool-abort-final-2.tsv"; sleep 15
    pool_objects > "$RESET/pool-abort-final-3.tsv"
    python3 - "$SEED_DIR/pool-pre-format.tsv" "$RESET/pool-abort-final-1.tsv" "$RESET/pool-abort-final-2.tsv" "$RESET/pool-abort-final-3.tsv" <<'PY'
import sys
def obj(p): return int(open(p).read().split()[0])
base=obj(sys.argv[1]); vals=[obj(x) for x in sys.argv[2:]]
assert max(vals)-min(vals) <= 4096, (base, vals)
assert all(abs(x-base) <= 8192 for x in vals), (base, vals)
print("abort_final_pool_return_pass", base, vals)
PY
    printf '%s\n' "$(date +%s)" > "$OUT/POST_ABORT_FINAL_DESTROY_PASS"
    printf 'POST_ABORT_FINAL_DESTROY_PASS instance=%s evidence=INVALID\n' "$INSTANCE"
    ;;
  *) t66_die 'usage: t66-reset-gates.sh prepare|post-destroy|seed-return|post-final-destroy|post-abort-final-destroy RUN_ID B1c|D1 INSTANCE';;
esac
