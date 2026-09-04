#!/usr/bin/env bash
# Offline v2 integration for 04-1/R1. No ssh/sudo/ceph/juicefs/fio calls.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
DRIVER="$SCRIPT_DIR/s04r1-driver.sh"
OUT=${R1_MOCK_OUT:-$(mktemp -d /tmp/s04r1-v2-mock.XXXXXX)}

make_inventory() {
  local dir=$1; mkdir -p "$dir"
  python3 - "$dir" <<'PY'
import json,sys
from pathlib import Path
r=Path(sys.argv[1]); osds=list(range(6)); rows=[]; hist=[6,6,5,6,5,4]
n=0
for o,c in enumerate(hist):
 for _ in range(c): rows.append({'pgid':f'3.{n:x}','primary':o,'up':osds,'acting':osds}); n+=1
(r/'ceph-version.txt').write_text('ceph version 17.2.8 quincy\n')
(r/'ceph-status.json').write_text(json.dumps({'fsid':'fixture','health':{'status':'HEALTH_OK'}}))
(r/'ceph-health.json').write_text(json.dumps({'status':'HEALTH_OK','checks':{}}))
(r/'ceph-df.json').write_text(json.dumps({'stats':{'total_avail_bytes':10**13},'pools':[]}))
(r/'pool-detail.json').write_text(json.dumps([{'pool':3,'pool_name':'juicefs-data','pg_num':32,'pg_placement_num':32,'type':3,'fast_read':True}]))
(r/'osd-dump.json').write_text(json.dumps({'epoch':99,'pool_max':3,'pools':[{'pool':3,'pool_name':'juicefs-data'}]}))
(r/'osd-tree.json').write_text(json.dumps({'nodes':[{'id':i,'status':'up','reweight':1} for i in osds]}))
(r/'crush-dump.json').write_text(json.dumps({
 'devices':[{'id':i,'name':f'osd.{i}'} for i in osds],
 'rules':[{'rule_id':0,'rule_name':'replicated_rule','type':1,'steps':[]},
          {'rule_id':1,'rule_name':'juicefs-data','type':3,'steps':[
            {'op':'take','item':-1,'item_name':'default'},
            {'op':'choose_indep','num':0,'type':'osd'},{'op':'emit'}]}]}))
all_rows=rows+[{'pgid':'1.0','primary':0,'up':[0,1,2],'acting':[0,1,2]}]
(r/'pg-all-pools.json').write_text(json.dumps({'pg_stats':all_rows}))
(r/'ec-profile.txt').write_text('k=4\nm=2\ncrush-failure-domain=osd\n')
(r/'ceph-features.txt').write_text('quincy fixture\n'); (r/'ceph-help.txt').write_text('pool create|get|set\n')
(r/'osdmaptool-help.txt').write_text('usage: osdmaptool --test-map-pgs-dump\n')
(r/'osdmap.bin').write_bytes(b'fixture-osdmap'); (r/'crush-map.bin').write_bytes(b'fixture-crush')
(r/'auth-readonly.json').write_text(json.dumps([{'entity':'client.juicefs','caps':{'mon':'profile rados'}}]))
(r/'runtime-inventory.txt').write_text('system_ceph_conf_sha256\tfixture\n')
PY
}

make_map() {
  local path=$1 pid=$2 pg=$3 mode=$4; python3 - "$path" "$pid" "$pg" "$mode" <<'PY'
import json,sys
out,pid,pg,mode=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),sys.argv[4]; osds=list(range(6))
if pg==32: hist=[6,6,5,6,5,4]
elif mode=='pass': hist=[11,11,11,11,10,10]
else: hist=[pg,0,0,0,0,0]
rows=[]; n=0
for o,c in enumerate(hist):
 for _ in range(c): rows.append({'pgid':f'{pid}.{n:x}','primary':o,'up':osds,'acting':osds}); n+=1
json.dump({'pool_id':pid,'pg_num':pg,'pg_stats':rows},open(out,'w'),indent=2)
PY
}

make_ack() {
  local run=$1 root="/tmp/production/opencode-04-1-$1"
  printf 'path\tsha256\tread_epoch\tidentity\n' >"$root/methodology-ack.tsv"
  for rel in skills/EVIDENCE-INTEGRITY-SKILL.md skills/fixtures/known-defect-classes.tsv \
    skills/TESTING-GUIDE.md skills/test-commands-reference.md skills/LONG-RUNNING-TEST-SKILL.md \
    doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md; do
    printf '%s\t%s\t%s\tmock-v2\n' "$rel" "$(sha256sum "$ROOT/$rel" | awk '{print $1}')" "$(date +%s)" >>"$root/methodology-ack.tsv"
  done
}

run_case() {
  local run=$1 mode=$2; local inv="$OUT/inv-$run"; make_inventory "$inv"
  mkdir -p "$OUT/layout-$run"; make_map "$OUT/layout-$run/layout-64.json" 4 64 "$mode"; make_map "$OUT/layout-$run/layout-128.json" 4 128 blocked
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" init "$run"; make_ack "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_FIXTURE_DIR="$inv" bash "$DRIVER" phase-i "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" plan-register-empty "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" register-empty "$run"
  ! DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" register-empty "$run" >/dev/null 2>&1
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" evaluate-layout "$run" 32
  ! DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" evaluate-layout "$run" 32 >/dev/null 2>&1
  ! DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" plan-adjust "$run" 32 128 >/dev/null 2>&1
  ! DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" plan-adjust "$run" 64 32 >/dev/null 2>&1
  if [[ $mode == pass ]]; then
    DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" plan-adjust "$run" 32 64
    ! DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_LAYOUT_DIR="$OUT/layout-$run" bash "$DRIVER" adjust-verify "$run" 64 64 >/dev/null 2>&1
    DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_LAYOUT_DIR="$OUT/layout-$run" bash "$DRIVER" adjust-verify "$run" 32 64
    DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" evaluate-layout "$run" 64
    [[ -f /tmp/production/opencode-04-1-$run/state/PG_SELECTION_COMPLETE ]]
    ! [[ -f /tmp/production/opencode-04-1-$run/state/NEXT_PG_NUM ]]
    ! DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" plan-adjust "$run" 64 128 >/dev/null 2>&1
    ! DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" phase-v-layout "$run" >/dev/null 2>&1
  else
    DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" plan-adjust "$run" 32 64
    ! DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_LAYOUT_DIR="$OUT/layout-$run" bash "$DRIVER" adjust-verify "$run" 64 64 >/dev/null 2>&1
    DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_LAYOUT_DIR="$OUT/layout-$run" bash "$DRIVER" adjust-verify "$run" 32 64
    DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" evaluate-layout "$run" 64
    DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" plan-adjust "$run" 64 128
    DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_LAYOUT_DIR="$OUT/layout-$run" bash "$DRIVER" adjust-verify "$run" 64 128
    DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" evaluate-layout "$run" 128
    grep -Fxq R1_FEASIBILITY_BLOCKED "/tmp/production/opencode-04-1-$run/state/FEASIBILITY_VERDICT"
    ! DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" phase-v-layout "$run" >/dev/null 2>&1
  fi
}

run_adopt_case() {
  local run=$1 inv="$OUT/inv-$1" map="$OUT/adopt-$1.json"; make_inventory "$inv"; make_map "$map" 4 32 blocked
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" init "$run"; make_ack "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_FIXTURE_DIR="$inv" bash "$DRIVER" phase-i "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" plan-register-empty "$run"
  ! DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$map" \
    bash "$DRIVER" adopt-registered-empty "$run" >/dev/null 2>&1
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$map" \
    R1_ADOPT_REGISTERED_ACK="I_ACK_R1_ADOPT_REGISTERED_EMPTY_${run}" \
    bash "$DRIVER" adopt-registered-empty "$run"
  [[ -f /tmp/production/opencode-04-1-$run/state/POOL_REGISTERED ]]
  [[ -f /tmp/production/opencode-04-1-$run/state/MAP_FROZEN ]]
  ! DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$map" \
    R1_ADOPT_REGISTERED_ACK="I_ACK_R1_ADOPT_REGISTERED_EMPTY_${run}" \
    bash "$DRIVER" adopt-registered-empty "$run" >/dev/null 2>&1
}

suffix=$(date +%N); run_case "20990601-${suffix:0:6}" pass
suffix=$(date +%N); run_case "20990602-${suffix:0:6}" blocked
suffix=$(date +%N); run_adopt_case "20990603-${suffix:0:6}"

# --- 04-1b R1B mock scenarios ---
make_r1b_maps() {
  local dir=$1 pid=$2
  python3 - "$dir" "$pid" <<'PY'
import json,sys
from pathlib import Path
d=Path(sys.argv[1]); pid=int(sys.argv[2]); osds=[0,1,2,3,4,5]
def mk_pg(pid,n,primary,osds):
  act=list(osds); act.remove(primary); act.insert(0,primary)
  return {"pgid":f"{pid}.{n:x}","primary":primary,"up":list(act),"acting":list(act)}
# Natural 64 PG with known imbalance: {0:10,1:8,2:12,3:10,4:13,5:11}
nat_hist=[10,8,12,10,13,11]
rows=[]; n=0
for o,c in enumerate(nat_hist):
  for _ in range(c):
    rows.append(mk_pg(pid,n,o,osds)); n+=1
json.dump({"pool_id":pid,"pg_num":64,"pg_stats":rows},open(d/"registered-natural.json","w"),indent=2)
# Steered 64 PG with target: {0:10,1:11,2:11,3:10,4:11,5:11}
tgt_hist=[10,11,11,10,11,11]
rows2=[]; n=0
for o,c in enumerate(tgt_hist):
  for _ in range(c):
    rows2.append(mk_pg(pid,n,o,osds)); n+=1
json.dump({"pool_id":pid,"pg_num":64,"pg_stats":rows2},open(d/"steered-target.json","w"),indent=2)
# Blocked: histogram doesn't match target
blk_hist=[12,10,10,10,12,10]
rows3=[]; n=0
for o,c in enumerate(blk_hist):
  for _ in range(c):
    rows3.append(mk_pg(pid,n,o,osds)); n+=1
json.dump({"pool_id":pid,"pg_num":64,"pg_stats":rows3},open(d/"steered-blocked.json","w"),indent=2)
PY
}

run_r1b_case() {
  local run=$1; local maps="$OUT/r1b-$run"; mkdir -p "$maps"; make_r1b_maps "$maps" 4
  local inv="$OUT/inv-r1b-$run"; make_inventory "$inv"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" r1b-init "$run"
  make_ack_r1b "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_FIXTURE_DIR="$inv" R1_READONLY_ACK=I_ACK_R1_READONLY_INVENTORY \
    bash "$DRIVER" r1b-phase-i "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" r1b-plan-create-pool "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$maps/registered-natural.json" \
    bash "$DRIVER" r1b-create-pool "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$maps/registered-natural.json" \
    bash "$DRIVER" r1b-plan-upmap "$run"
  # Derive steered map by applying plan to natural map (not a separate fixture)
  python3 - "$maps/registered-natural.json" "/tmp/production/opencode-04-1b-$run/plans/upmap-plan.json" "$maps/steered-derived.json" <<'PY'
import json,sys,copy
nat=json.load(open(sys.argv[1])); plan=json.load(open(sys.argv[2])); out=sys.argv[3]
steered=copy.deepcopy(nat)
for u in plan["upmap_commands"]:
  for pg in steered["pg_stats"]:
    if pg["pgid"]==u["pgid"]:
      pg["up"]=u["new_acting"]; pg["acting"]=u["new_acting"]; pg["primary"]=u["new_primary"]
json.dump(steered,open(out,"w"),indent=2)
PY
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$maps/registered-natural.json" \
    R1_MOCK_STEERED_MAP="$maps/steered-derived.json" \
    R1B_APPLY_UPMAP_ACK="I_ACK_R1B_APPLY_UPMAP_${run}" \
    bash "$DRIVER" r1b-apply-upmap "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 \
    bash "$DRIVER" r1b-plan-primary-toggle "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 \
    R1B_PRIMARY_TEMP_CANARY_ACK="I_ACK_R1B_PRIMARY_TEMP_CANARY_${run}" \
    bash "$DRIVER" r1b-canary-primary-toggle "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 \
    bash "$DRIVER" r1b-plan-data-l1 "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 \
    bash "$DRIVER" r1b-plan-layout-v2 "$run"
  # Layout entry point - normal path
  DRY_RUN_ONLY=1 R1_MOCK=1 \
    R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run}" \
    bash "$DRIVER" r1b-layout-once "$run"
  [[ -f /tmp/production/opencode-04-1b-$run/state/R1B_LAYOUT_ONCE_PASS ]]
  [[ -f /tmp/production/opencode-04-1b-$run/state/DATA_PLANE_STARTED ]]
  [[ -f /tmp/production/opencode-04-1b-$run/state/LAYOUT_STARTED ]]
  # Duplicate: must reject
  if DRY_RUN_ONLY=1 R1_MOCK=1 \
    R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run}" \
    bash "$DRIVER" r1b-layout-once "$run" >/dev/null 2>&1; then
    printf 'E_R1B_MOCK\tduplicate layout should fail\n' >&2; exit 42
  fi
  # Missing ACK: no DATA_PLANE_STARTED
  if DRY_RUN_ONLY=1 R1_MOCK=1 \
    bash "$DRIVER" r1b-layout-once "20990606-${run:6}" >/dev/null 2>&1; then
    printf 'E_R1B_MOCK\tmissing ACK should fail\n' >&2; exit 42
  fi
  if [[ -f /tmp/production/opencode-04-1b-20990606-${run:6}/state/DATA_PLANE_STARTED ]]; then
    printf 'E_R1B_MOCK\tDATA_PLANE_STARTED should not exist without ACK\n' >&2; exit 42
  fi
  # 127 files: LAYOUT_FAILED
  suffix2=$(date +%N); run2="20990608-${suffix2:0:6}"
  _setup_layout_state "$run2" "$maps"
  _out=$(DRY_RUN_ONLY=1 R1_MOCK=1 R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run2}" R1_MOCK_LAYOUT_FILES=127 bash "$DRIVER" r1b-layout-once "$run2" 2>&1) || true
  echo "$_out" | grep -q LAYOUT_FAILED || { printf 'E_R1B_MOCK\t127 files should produce LAYOUT_FAILED\n' >&2; exit 42; }
  [[ -f /tmp/production/opencode-04-1b-$run2/state/LAYOUT_FAILED ]]
  # 512MiB file: LAYOUT_FAILED
  suffix3=$(date +%N); run3="20990609-${suffix3:0:6}"
  _setup_layout_state "$run3" "$maps"
  _out=$(DRY_RUN_ONLY=1 R1_MOCK=1 R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run3}" R1_MOCK_BAD_FILE_SIZE=1 bash "$DRIVER" r1b-layout-once "$run3" 2>&1) || true
  echo "$_out" | grep -q LAYOUT_FAILED || { printf 'E_R1B_MOCK\t512MiB file should produce LAYOUT_FAILED\n' >&2; exit 42; }
  [[ -f /tmp/production/opencode-04-1b-$run3/state/LAYOUT_FAILED ]]
  # Extra prefix file: LAYOUT_FAILED
  suffix4=$(date +%N); run4="20990610-${suffix4:0:6}"
  _setup_layout_state "$run4" "$maps"
  _out=$(DRY_RUN_ONLY=1 R1_MOCK=1 R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run4}" R1_MOCK_EXTRA_PREFIX_FILE=1 bash "$DRIVER" r1b-layout-once "$run4" 2>&1) || true
  echo "$_out" | grep -q LAYOUT_FAILED || { printf 'E_R1B_MOCK\textra prefix file should produce LAYOUT_FAILED\n' >&2; exit 42; }
  [[ -f /tmp/production/opencode-04-1b-$run4/state/LAYOUT_FAILED ]]
  # fio mid-failure: LAYOUT_FAILED
  suffix5=$(date +%N); run5="20990611-${suffix5:0:6}"
  _setup_layout_state "$run5" "$maps"
  _out=$(DRY_RUN_ONLY=1 R1_MOCK=1 R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run5}" R1_MOCK_FAIL_AT=fio_fail bash "$DRIVER" r1b-layout-once "$run5" 2>&1) || true
  echo "$_out" | grep -q LAYOUT_FAILED || { printf 'E_R1B_MOCK\tfio fail should produce LAYOUT_FAILED\n' >&2; exit 42; }
  [[ -f /tmp/production/opencode-04-1b-$run5/state/LAYOUT_FAILED ]]
  # RO mount fail: LAYOUT_FAILED
  suffix6=$(date +%N); run6="20990612-${suffix6:0:6}"
  _setup_layout_state "$run6" "$maps"
  _out=$(DRY_RUN_ONLY=1 R1_MOCK=1 R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run6}" R1_MOCK_FAIL_AT=ro_mount_fail bash "$DRIVER" r1b-layout-once "$run6" 2>&1) || true
  echo "$_out" | grep -q LAYOUT_FAILED || { printf 'E_R1B_MOCK\tRO mount fail should produce LAYOUT_FAILED\n' >&2; exit 42; }
  [[ -f /tmp/production/opencode-04-1b-$run6/state/LAYOUT_FAILED ]]
  # META exists: reject before first write
  suffix7=$(date +%N); run7="20990613-${suffix7:0:6}"
  _setup_layout_state "$run7" "$maps"
  touch "/tmp/production/opencode-04-1b-$run7/state/mock-meta-exists"
  if DRY_RUN_ONLY=1 R1_MOCK=1 R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run7}" \
    bash "$DRIVER" r1b-layout-once "$run7" >/dev/null 2>&1; then
    printf 'E_R1B_MOCK\tMETA exists should reject\n' >&2; exit 42
  fi
  if [[ -f /tmp/production/opencode-04-1b-$run7/state/DATA_PLANE_STARTED ]]; then
    printf 'E_R1B_MOCK\tDATA_PLANE_STARTED should not exist\n' >&2; exit 42
  fi
  # Stability must reject zero objects and fewer than three stable samples.
  suffix8=$(date +%N); run8="20990614-${suffix8:0:6}"
  _setup_layout_state "$run8" "$maps"
  ! DRY_RUN_ONLY=1 R1_MOCK=1 R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run8}" \
    R1_MOCK_FAIL_AT=stab_zero bash "$DRIVER" r1b-layout-once "$run8" >/dev/null 2>&1
  [[ -f /tmp/production/opencode-04-1b-$run8/state/LAYOUT_FAILED ]]
  suffix9=$(date +%N); run9="20990615-${suffix9:0:6}"
  _setup_layout_state "$run9" "$maps"
  ! DRY_RUN_ONLY=1 R1_MOCK=1 R1B_LAYOUT_ACK="I_ACK_R1B_LAYOUT_${run9}" \
    R1_MOCK_FAIL_AT=stab_short bash "$DRIVER" r1b-layout-once "$run9" >/dev/null 2>&1
  [[ -f /tmp/production/opencode-04-1b-$run9/state/LAYOUT_FAILED ]]
    R1_MOCK_STEERED_MAP="$maps/steered-derived.json" \
    bash "$DRIVER" r1b-evaluate-structure "$run"
  grep -Fxq R1B_STRUCTURE_PASS "/tmp/production/opencode-04-1b-$run/state/R1B_STRUCTURE_VERDICT"
  # Verify apply/rollback command format: full pgid, not pool_id + hex
  python3 - "/tmp/production/opencode-04-1b-$run/plans/upmap-plan.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["upmap_commands"]:
  cmd=c["command"]
  assert "pg-upmap 4." in cmd, f"command missing full pgid: {cmd}"
  parts=cmd.split()
  pgid=parts[parts.index("pg-upmap")+1]
  assert "." in pgid, f"pgid has no dot: {pgid}"
for c in d["rollback_commands"]:
  cmd=c["command"]
  assert "rm-pg-upmap 4." in cmd, f"rollback missing full pgid: {cmd}"
for c in d["upmap_commands"]:
  assert set(c["old_acting"])==set(c["new_acting"]), "acting members changed"
  assert c["new_acting"][0]==c["new_primary"], "primary not first"
  assert c["new_primary"]!=c["old_primary"], "no-op upmap"
assert d["upmap_count"]>0
assert d["I_primary_steered"]<=1.05+1e-12
tgt={0:10,1:11,2:11,3:10,4:11,5:11}
actual={int(k):v for k,v in d["steered_histogram"].items()}
assert all(actual[o]==tgt[o] for o in tgt)
PY
}

run_r1b_blocked_case() {
  local run=$1; local maps="$OUT/r1b-blk-$run"; mkdir -p "$maps"; make_r1b_maps "$maps" 4
  local inv="$OUT/inv-r1b-blk-$run"; make_inventory "$inv"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" r1b-init "$run"
  make_ack_r1b "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_FIXTURE_DIR="$inv" R1_READONLY_ACK=I_ACK_R1_READONLY_INVENTORY \
    bash "$DRIVER" r1b-phase-i "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" r1b-plan-create-pool "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$maps/registered-natural.json" \
    bash "$DRIVER" r1b-create-pool "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$maps/registered-natural.json" \
    bash "$DRIVER" r1b-plan-upmap "$run"
  DRY_RUN_ONLY=1 R1_MOCK=1 R1_MOCK_REGISTERED_MAP="$maps/registered-natural.json" \
    R1_MOCK_STEERED_MAP="$maps/steered-blocked.json" \
    bash "$DRIVER" r1b-evaluate-structure "$run"
  grep -Fxq R1B_STRUCTURE_BLOCKED "/tmp/production/opencode-04-1b-$run/state/R1B_STRUCTURE_VERDICT"
}

make_ack_r1b() {
  local run=$1 root="/tmp/production/opencode-04-1b-$1"
  printf 'path\tsha256\tread_epoch\tidentity\n' >"$root/methodology-ack.tsv"
  for rel in skills/EVIDENCE-INTEGRITY-SKILL.md skills/fixtures/known-defect-classes.tsv \
    skills/TESTING-GUIDE.md skills/test-commands-reference.md skills/LONG-RUNNING-TEST-SKILL.md \
    doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md; do
    printf '%s\t%s\t%s\tmock-r1b\n' "$rel" "$(sha256sum "$ROOT/$rel" | awk '{print $1}')" "$(date +%s)" >>"$root/methodology-ack.tsv"
  done
}

_setup_layout_state() {
  local run=$1 maps=$2 root="/tmp/production/opencode-04-1b-$1"
  mkdir -p "$root/state" "$root/plans"
  make_ack_r1b "$run"
  for m in R1B_INIT_COMPLETE R1B_PHASE_I_COMPLETE R1B_PLAN_CREATE_POOL_COMPLETE R1B_POOL_CREATED \
    R1B_PLAN_UPMAP_COMPLETE R1B_UPMAP_APPLIED R1B_BALANCER_LEASE_OWNED R1B_EVALUATE_STRUCTURE_COMPLETE \
    R1B_PLAN_PRIMARY_TOGGLE_COMPLETE R1B_PRIMARY_TOGGLE_CANARY_DONE R1B_PLAN_DATA_L1_COMPLETE; do
    printf '%s\t%s\n' "$m" "$(date +%s)" >"$root/state/$m"
  done
  cp -- "$maps/registered-natural.json" "$root/state/registered-map.json"
  cp -- "$maps/steered-derived.json" "$root/state/steered-map.json" 2>/dev/null || true
  # Create minimal plans
  printf '{"pool_id":5,"pg_num":64,"upmap_count":3,"upmap_commands":[],"rollback_commands":[],"steered_histogram":{"0":10,"1":11,"2":11,"3":10,"4":11,"5":11},"I_primary_steered":1.03125}\n' >"$root/plans/upmap-plan.json"
  printf 'toggle_count\t3\n' >"$root/plans/primary-toggle-plan.json"
  sha256sum "$root/plans/upmap-plan.json" >"$root/plans/upmap-plan.sha256"
  sha256sum "$root/plans/primary-toggle-plan.json" >"$root/plans/primary-toggle.sha256"
  printf 'phase\tstate\tepoch\trc\n' >"$root/phase-status.tsv"
  printf 'epoch\tseverity\taction\tdetail\n' >"$root/incidents.tsv"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" r1b-plan-layout-v2 "$run"
}

suffix=$(date +%N); run_r1b_case "20990604-${suffix:0:6}"
suffix=$(date +%N); run_r1b_blocked_case "20990605-${suffix:0:6}"

# Analyzer must reject malformed or out-of-contract actual maps.
NEG_INV="$OUT/inv-negative"; NEG="$OUT/analyzer-negative"; mkdir -p "$NEG"; make_inventory "$NEG_INV"
make_map "$NEG/good.json" 4 64 pass
python3 - "$NEG" <<'PY'
import copy,json,sys
from pathlib import Path
r=Path(sys.argv[1]); good=json.load(open(r/'good.json'))
d=copy.deepcopy(good); d['pg_stats'][0]['pgid']='5.0'; json.dump(d,open(r/'foreign.json','w'))
d=copy.deepcopy(good); d['pg_stats'][1]['pgid']=d['pg_stats'][0]['pgid']; json.dump(d,open(r/'duplicate.json','w'))
d=copy.deepcopy(good); d['pg_stats'][0]['primary']=99; json.dump(d,open(r/'primary-outside.json','w'))
d=copy.deepcopy(good)
for row in d['pg_stats']:
 row['up']=row['acting']=[0,1,2,3,4]; row['primary']%=5
json.dump(d,open(r/'five-osd.json','w'))
rows=[]
for i in range(96):
 o=i%6; rows.append({'pgid':f'4.{i:x}','primary':o,'up':[0,1,2,3,4,5],'acting':[0,1,2,3,4,5]})
json.dump({'pool_id':4,'pg_num':96,'pg_stats':rows},open(r/'pg96.json','w'))
PY
for bad in foreign duplicate primary-outside five-osd pg96; do
  if python3 "$SCRIPT_DIR/s04r1-map-analyze.py" --inventory "$NEG_INV" \
      --registered-map "$NEG/$bad.json" --actual-only --output "$NEG/$bad.out.json" >/dev/null 2>&1; then
    printf 'E_R1_MOCK\tanalyzer accepted invalid map: %s\n' "$bad" >&2; exit 42
  fi
done

# --- R1B negative tests: upmap planner must reject bad maps ---
python3 - "$OUT" "$SCRIPT_DIR" <<'PY'
import json,sys,subprocess
from pathlib import Path
out=Path(sys.argv[1]); script=sys.argv[2]; osds=[0,1,2,3,4,5]
neg=out/"r1b-negative"; neg.mkdir(exist_ok=True)
# Good 64 PG
rows=[]; n=0
for o,c in enumerate([10,8,12,10,13,11]):
  for _ in range(c):
    act=list(osds); act.remove(o); act.insert(0,o)
    rows.append({"pgid":f"4.{n:x}","primary":o,"up":list(act),"acting":list(act)}); n+=1
json.dump({"pool_id":4,"pg_num":64,"pg_stats":rows},open(neg/"good.json","w"))
# 32 PG (wrong count)
rows2=[]; n=0
for o,c in enumerate([6,6,5,6,5,4]):
  for _ in range(c): rows2.append({"pgid":f"4.{n:x}","primary":o,"up":osds,"acting":osds}); n+=1
json.dump({"pool_id":4,"pg_num":32,"pg_stats":rows2},open(neg/"pg32.json","w"))
# 5 OSDs
rows3=[]
for i in range(64):
  o=i%6; act=[0,1,2,3,4,5][:5]; rows3.append({"pgid":f"4.{i:x}","primary":o,"up":act,"acting":act})
json.dump({"pool_id":4,"pg_num":64,"pg_stats":rows3},open(neg/"five-osd-r1b.json","w"))
# Acting set missing an OSD
rows4=[]
for i in range(64):
  o=i%6; act=[0,1,2,3,4,5]; rows4.append({"pgid":f"4.{i:x}","primary":o,"up":act,"acting":act})
for r in rows4[:3]: r["acting"]=[0,1,2,3,4]  # remove OSD 5
json.dump({"pool_id":4,"pg_num":64,"pg_stats":rows4},open(neg/"missing-acting.json","w"))

for bad in ["pg32","five-osd-r1b","missing-acting"]:
  r=subprocess.run([sys.executable,script+"/s04r1-map-analyze.py","--plan-upmap-mode",
    "--registered-map",str(neg/(bad+".json")),"--output",str(neg/(bad+".out.json")),
    "--target","0:10,1:11,2:11,3:10,4:11,5:11"],capture_output=True)
  if r.returncode==0:
    print(f"E_R1B_MOCK\tupmap planner accepted invalid map: {bad}",file=sys.stderr); sys.exit(42)
# Good map should succeed
r=subprocess.run([sys.executable,script+"/s04r1-map-analyze.py","--plan-upmap-mode",
  "--registered-map",str(neg/"good.json"),"--output",str(neg/"good.out.json"),
  "--target","0:10,1:11,2:11,3:10,4:11,5:11"],capture_output=True)
if r.returncode!=0:
  print(f"E_R1B_MOCK\tupmap planner rejected good map",file=sys.stderr); sys.exit(42)
d=json.load(open(neg/"good.out.json"))
assert d["upmap_count"]>0 and d["I_primary_steered"]<=1.05+1e-12
PY

printf 'R1_V2_MOCK_INTEGRATION_PASS\tout=%s\n' "$OUT"

# --- L1 dynamic mock tests ---

# Helper: set up minimal L1 state for a mock RUN
_setup_l1_state() {
  local run=$1 maps=$2 root="/tmp/production/opencode-04-1b-$1"
  _setup_layout_state "$run" "$maps"
  # Add layout markers
  printf 'R1B_LAYOUT_ADOPTED_PASS\t%s\n' "$(date +%s)" >"$root/state/R1B_LAYOUT_ADOPTED_PASS"
  # Add RO identity
  printf 'ro_pid\t%s\nro_start\t%s\n' "$$" "$(date)" >"$root/state/b-ro-adopted-identity.tsv"
  # Ensure toggle plans exist (from _setup_layout_state which copies maps)
  printf '{"toggle_count":3,"n_apply_commands":[{"command":"sudo ceph osd primary-temp 4.0 0"},{"command":"sudo ceph osd primary-temp 4.1 0"},{"command":"sudo ceph osd primary-temp 4.2 1"}],"s_clear_commands":[{"command":"sudo ceph osd primary-temp 4.0 1"},{"command":"sudo ceph osd primary-temp 4.1 1"},{"command":"sudo ceph osd primary-temp 4.2 0"}]}\n' >"$root/plans/primary-toggle-plan.json"
  printf 'sudo ceph osd primary-temp 4.0 0\nsudo ceph osd primary-temp 4.1 0\nsudo ceph osd primary-temp 4.2 1\n' >"$root/plans/primary-toggle-n-apply.txt"
  printf 'sudo ceph osd primary-temp 4.0 1\nsudo ceph osd primary-temp 4.1 1\nsudo ceph osd primary-temp 4.2 0\n' >"$root/plans/primary-toggle-s-clear.txt"
  sha256sum "$root/plans/primary-toggle-plan.json" >"$root/plans/primary-toggle.sha256"
  sha256sum "$root/plans/primary-toggle-n-apply.txt" "$root/plans/primary-toggle-s-clear.txt" >>"$root/plans/primary-toggle.sha256"
  rm -f "$root/state/R1B_PLAN_DATA_L1_COMPLETE"
  DRY_RUN_ONLY=1 R1_MOCK=1 bash "$DRIVER" r1b-plan-data-l1 "$run"
}

# L1 Test 1: Success N/S/S/N
suffix=$(date +%N); run_l1="20990620-${suffix:0:6}"
_l1_maps="$OUT/l1-maps-$run_l1"; mkdir -p "$_l1_maps"; make_r1b_maps "$_l1_maps" 4
_setup_l1_state "$run_l1" "$_l1_maps"
DRY_RUN_ONLY=1 R1_MOCK=1 \
  R1B_L1_ACK="I_ACK_R1B_L1_${run_l1}" \
  R1_SCRUB_ACK="I_ACK_GLOBAL_CEPH_SCRUB_PAUSE" \
  bash "$DRIVER" r1b-l1-screen "$run_l1" 2>&1 | grep -q "R1B_L1_SCREEN_PASS" || { printf 'E_L1_MOCK\tL1 success should pass\n' >&2; exit 42; }
[[ -f /tmp/production/opencode-04-1b-$run_l1/state/R1B_L1_SCREEN_DONE ]] || { printf 'E_L1_MOCK\tDONE marker missing\n' >&2; exit 42; }
[[ ! -f /tmp/production/opencode-04-1b-$run_l1/state/R1B_L1_FATAL ]] || { printf 'E_L1_MOCK\tFATAL should not exist on success\n' >&2; exit 42; }

# L1 Test 2: Missing W03 input
suffix=$(date +%N); run_l1b="20990621-${suffix:0:6}"
_setup_l1_state "$run_l1b" "$_l1_maps"
DRY_RUN_ONLY=1 R1_MOCK=1 \
  R1B_L1_ACK="I_ACK_R1B_L1_${run_l1b}" \
  R1_SCRUB_ACK="I_ACK_GLOBAL_CEPH_SCRUB_PAUSE" \
  R1B_FAILPOINT_MISSING_W03=1 \
  bash "$DRIVER" r1b-l1-screen "$run_l1b" 2>&1 | grep -q "rejected missing W03" || { printf 'E_L1_MOCK\tmissing W03 should reject\n' >&2; exit 42; }
[[ ! -f /tmp/production/opencode-04-1b-$run_l1b/state/R1B_L1_SCREEN_DONE ]] || { printf 'E_L1_MOCK\tDONE should not exist on missing W03\n' >&2; exit 42; }

# L1 Test 3: W02 fio failpoint
suffix=$(date +%N); run_l1c="20990622-${suffix:0:6}"
_setup_l1_state "$run_l1c" "$_l1_maps"
_out=$(DRY_RUN_ONLY=1 R1_MOCK=1 R1B_L1_ACK="I_ACK_R1B_L1_${run_l1c}" R1_SCRUB_ACK="I_ACK_GLOBAL_CEPH_SCRUB_PAUSE" R1B_FAILPOINT=W02 bash "$DRIVER" r1b-l1-screen "$run_l1c" 2>&1) || true
echo "$_out" | grep -q "fio failpoint" || { printf 'E_L1_MOCK\tW02 fio failpoint should trigger\n' >&2; exit 42; }
echo "$_out" | grep -q "fio_count=2" || { printf 'E_L1_MOCK\tfio_count should be 2 at W02\n' >&2; exit 42; }
[[ ! -f /tmp/production/opencode-04-1b-$run_l1c/state/R1B_L1_SCREEN_DONE ]] || { printf 'E_L1_MOCK\tDONE should not exist on W02 fail\n' >&2; exit 42; }

# L1 Test 4: sampler close failpoint
suffix=$(date +%N); run_l1d="20990623-${suffix:0:6}"
_setup_l1_state "$run_l1d" "$_l1_maps"
_out=$(DRY_RUN_ONLY=1 R1_MOCK=1 R1B_L1_ACK="I_ACK_R1B_L1_${run_l1d}" R1_SCRUB_ACK="I_ACK_GLOBAL_CEPH_SCRUB_PAUSE" R1B_FAILPOINT_SAMPLER_CLOSE=W01 bash "$DRIVER" r1b-l1-screen "$run_l1d" 2>&1) || true
echo "$_out" | grep -q "sampler close failpoint" || { printf 'E_L1_MOCK\tsampler close failpoint should trigger\n' >&2; exit 42; }
[[ -f /tmp/production/opencode-04-1b-$run_l1d/state/R1B_L1_FATAL ]] || { printf 'E_L1_MOCK\tFATAL should exist on sampler close fail\n' >&2; exit 42; }
[[ ! -f /tmp/production/opencode-04-1b-$run_l1d/state/R1B_L1_SCREEN_DONE ]] || { printf 'E_L1_MOCK\tDONE should not exist on sampler close fail\n' >&2; exit 42; }

# L1 Test 5: scrub restore failpoint
suffix=$(date +%N); run_l1e="20990624-${suffix:0:6}"
_setup_l1_state "$run_l1e" "$_l1_maps"
_out=$(DRY_RUN_ONLY=1 R1_MOCK=1 R1B_L1_ACK="I_ACK_R1B_L1_${run_l1e}" R1_SCRUB_ACK="I_ACK_GLOBAL_CEPH_SCRUB_PAUSE" R1B_FAILPOINT_SCRUB_RESTORE=1 bash "$DRIVER" r1b-l1-screen "$run_l1e" 2>&1) || true
echo "$_out" | grep -q "scrub restore failpoint" || { printf 'E_L1_MOCK\tscrub restore failpoint should trigger\n' >&2; exit 42; }
[[ -f /tmp/production/opencode-04-1b-$run_l1e/state/R1B_L1_FATAL ]] || { printf 'E_L1_MOCK\tFATAL should exist on scrub restore fail\n' >&2; exit 42; }
[[ ! -f /tmp/production/opencode-04-1b-$run_l1e/state/R1B_L1_SCREEN_DONE ]] || { printf 'E_L1_MOCK\tDONE should not exist on scrub restore fail\n' >&2; exit 42; }

printf 'R1B_L1_MOCK_TESTS_PASS\n'
