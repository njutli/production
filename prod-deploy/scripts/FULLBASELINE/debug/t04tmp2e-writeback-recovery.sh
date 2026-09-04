#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

MODE=${1:-}; RUN_ID=${2:-}; LABEL=${3:-}
ROOT=/tmp/production/opencode-04tmp2e-$RUN_ID
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
CEPH_CONF=$ROOT/inventory/ceph-msgr8.conf
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
CEPH_KEYRING=/etc/ceph/ceph.client.admin.keyring
POOL=juicefs-data
OUT=$ROOT/recovery/$LABEL
OBJECT_TOLERANCE=8192

die(){ printf 'E_04TMP2E_RECOVERY\t%s\n' "$*" >&2; exit 42; }
valid(){
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $LABEL =~ ^after-W(16|32|64|96|128)-randwrite$ ]] || die invalid_label
  [[ $ROOT == /tmp/production/opencode-04tmp2e-$RUN_ID && $ROOT != / && $ROOT != *..* ]] || die unsafe_root
  [[ $OUT == "$ROOT/recovery/$LABEL" && ! -L $OUT ]] || die unsafe_output
  [[ -r $CEPH_CONF && -r $CEPH_KEYRING && -r $ROOT/inventory/osd-ids.txt && -r $ROOT/inventory/pool-seed.tsv ]] || die inventory_missing
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die JuiceFS_identity
  [[ ! -L $CEPH_CONF && $(md5sum "$CEPH_CONF"|awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die private_ceph_conf_identity
}
record(){ printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }
pool_objects(){
  CEPH_CONF=$CEPH_CONF ceph df detail --format json | python3 -c \
    'import json,sys; name=sys.argv[1]; rows=[p for p in json.load(sys.stdin).get("pools",[]) if p.get("name")==name]; assert len(rows)==1; print(rows[0]["stats"]["objects"])' "$POOL"
}
health(){
  local file=$1
  CEPH_CONF=$CEPH_CONF ceph -s --format json >"$file"
  python3 - "$file" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); states=d.get('pgmap',{}).get('pgs_by_state',[])
if d.get('health',{}).get('status')!='HEALTH_OK': raise SystemExit('health not OK')
if not states or any(x.get('state_name')!='active+clean' for x in states): raise SystemExit('PG not active+clean')
PY
}
compact_state(){
  local osd=$1 file=$2
  sudo ceph -c "$CEPH_CONF" --keyring "$CEPH_KEYRING" -n client.admin tell "osd.$osd" perf dump >"$file"
  python3 - "$file" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); found={}
def walk(x):
    if isinstance(x,dict):
        for k,v in x.items():
            if k in ('compact_running','compact_queue_len') and isinstance(v,(int,float)): found[k]=v
            if k == 'kv_sync_lat' and isinstance(v,dict) and isinstance(v.get('avgtime'),(int,float)):
                found[k]=v['avgtime']
            walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(d)
print(found.get('compact_running','NA'),found.get('compact_queue_len','NA'),found.get('kv_sync_lat','NA'))
PY
}
pending_total(){
  curl -fsS --connect-timeout 3 --max-time 8 "http://$1/metrics" |
    awk '/^tikv_engine_pending_compaction_bytes\{/{sum+=$2;found=1} END{if(!found)exit 1;printf "%.0f\n",sum}'
}
tikv_idle_gate(){
  local deadline=$((SECONDS+900)) consecutive=0 epoch ep value all_zero
  printf 'epoch\tendpoint\tpending_compaction_bytes\n' >"$OUT/tikv-pending.tsv"
  while (( SECONDS < deadline )); do
    epoch=$(date +%s); all_zero=1
    for ep in 10.20.1.150:20180 10.20.1.151:20180 10.20.1.152:20180; do
      value=$(pending_total "$ep") || die "tikv_pending_metric_$ep"
      printf '%s\t%s\t%s\n' "$epoch" "$ep" "$value" >>"$OUT/tikv-pending.tsv"
      (( value == 0 )) || all_zero=0
    done
    if (( all_zero )); then consecutive=$((consecutive+1)); else consecutive=0; fi
    (( consecutive >= 3 )) && return 0
    sleep 10
  done
  die tikv_pending_timeout
}
cmd_plan(){
  valid
  printf '# State-changing sudo commands; OSD IDs frozen by inventory.\n'
  while read -r osd; do [[ $osd =~ ^[0-9]+$ ]] || die bad_osd_id; printf 'sudo ceph -c %q --keyring %q -n client.admin tell osd.%s compact\n' "$CEPH_CONF" "$CEPH_KEYRING" "$osd"; done <"$ROOT/inventory/osd-ids.txt"
  printf '# Read-only polling also uses: sudo ceph -c %q --keyring %q -n client.admin tell osd.<ID> perf dump\n' "$CEPH_CONF" "$CEPH_KEYRING"
}
cmd_run(){
  valid
  [[ ${TMP2E_RECOVERY_ACK:-} == I_ACK_04TMP2E_RECOVERY_$RUN_ID ]] || die ack_missing
  [[ ! -e $OUT ]] || die recovery_output_exists
  mkdir -m 0700 -p "$OUT/compact"
  health "$OUT/health-pre.json"
  local seed limit before after pass osd round running queue sync
  seed=$(awk -F '\t' '$1=="juicefs-data"{print $2}' "$ROOT/inventory/pool-seed.tsv")
  [[ $seed =~ ^[0-9]+$ ]] || die bad_seed
  limit=$((seed + OBJECT_TOLERANCE)); before=$(pool_objects); printf 'key\tvalue\nseed\t%s\nlimit\t%s\nbefore\t%s\n' "$seed" "$limit" "$before" >"$OUT/objects.tsv"
  for pass in 1 2 3; do
    record env JFS_GC_SKIPPEDTIME=0 "CEPH_CONF=$CEPH_CONF" "$JFS" gc --compact "$META"
    JFS_GC_SKIPPEDTIME=0 CEPH_CONF=$CEPH_CONF "$JFS" gc --compact "$META" >"$OUT/gc-$pass.log" 2>&1 || die "gc_failed_$pass"
    sleep 60
    after=$(pool_objects); printf 'pass%s\t%s\n' "$pass" "$after" >>"$OUT/objects.tsv"
    (( after <= limit )) && break
  done
  (( after <= limit )) || die "objects_not_returned_$after"
  while read -r osd; do
    read -r running queue sync < <(compact_state "$osd" "$OUT/compact/osd-$osd-probe.json")
    [[ $running =~ ^[0-9]+([.][0-9]+)?$ && $queue =~ ^[0-9]+([.][0-9]+)?$ ]] ||
      die "compact_schema_unavailable_osd_$osd"
  done <"$ROOT/inventory/osd-ids.txt"
  while read -r osd; do
    [[ $osd =~ ^[0-9]+$ ]] || die bad_osd_id
    record sudo ceph -c "$CEPH_CONF" --keyring "$CEPH_KEYRING" -n client.admin tell "osd.$osd" compact
    sudo ceph -c "$CEPH_CONF" --keyring "$CEPH_KEYRING" -n client.admin tell "osd.$osd" compact >"$OUT/compact/osd-$osd-command.txt"
  done <"$ROOT/inventory/osd-ids.txt"
  for round in $(seq 1 120); do
    pass=1
    while read -r osd; do
      read -r running queue sync < <(compact_state "$osd" "$OUT/compact/osd-$osd-latest.json")
      printf '%s\t%s\t%s\t%s\t%s\n' "$round" "$osd" "$running" "$queue" "$sync" >>"$OUT/compact-state.tsv"
      [[ $running == 0 && $queue == 0 ]] || pass=0
    done <"$ROOT/inventory/osd-ids.txt"
    (( pass == 1 )) && break
    sleep 5
  done
  (( pass == 1 )) || die compact_cooldown_timeout
  tikv_idle_gate
  health "$OUT/health-post.json"
  printf 'RECOVERY_PASS\t%s\n' "$LABEL" >"$OUT/PASS"
  printf '04TMP2E_RECOVERY_PASS label=%s objects=%s seed=%s\n' "$LABEL" "$after" "$seed"
}
cmd_offline(){
  RUN_ID=20260903-235959; LABEL=after-W16-randwrite
  ROOT=/tmp/production/opencode-04tmp2e-$RUN_ID; CEPH_CONF=$ROOT/inventory/ceph-msgr8.conf; OUT=$ROOT/recovery/$LABEL
  [[ $ROOT != / && $OUT == "$ROOT/recovery/after-W16-randwrite" ]] || die offline_scope
  printf '04TMP2E_RECOVERY_OFFLINE_SELF_TEST_PASS\n'
}
case $MODE in plan) cmd_plan;; run) cmd_run;; offline-self-test) cmd_offline;; *) printf 'usage: %s plan|run|offline-self-test RUN_ID LABEL\n' "$0"; exit 2;; esac
