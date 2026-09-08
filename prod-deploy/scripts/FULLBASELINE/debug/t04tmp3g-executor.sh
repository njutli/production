#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 04-tmp3g 157-side executor; no SSH client. Evidence is bundled for /mnt/c copy.
# DEFECT-D01 DEFECT-D04 DEFECT-D05 DEFECT-D06 DEFECT-D08 DEFECT-D12 DEFECT-D16
# DEFECT-D17 DEFECT-D19 DEFECT-D21 DEFECT-D22 DEFECT-D23 DEFECT-D25 DEFECT-D26
# DEFECT-D27 DEFECT-D28 DEFECT-D29 DEFECT-D30 DEFECT-D31 DEFECT-D32
MODE="${1:-}"; RUN_ID="${2:-}"
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANALYZER=$SELF_DIR/t04tmp3g-analyze.py
SCRUB=$SELF_DIR/u141d-scrub-control.sh
JFS=/tmp/juicefs-1.4.1-patched
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REF=/mnt/juicefs
ROOT="/tmp/production/opencode-04tmp3g-$RUN_ID"
ASSET_ROOT="$REF/test_dir/04tmp3g-$RUN_ID"
CEPH_CONF="$ROOT/inventory/ceph-msgr8.conf"
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
JFS_MD5=24fae0852051c80ca571cb2f20275d46
STATE_DIR="$ROOT/scrub"
METRICS_ADDR=127.0.0.1:19657
ACTIVE_LEASE=
ACTIVE_MNT=
O0=
O1=
EXECUTOR=$(readlink -f "$SELF_DIR/t04tmp3g-executor.sh")

die(){ printf 'T04TMP3G_EXECUTOR_FAIL\t%s\n' "$*" >&2; exit 42; }
for name in T04TMP3G_JFS T04TMP3G_META T04TMP3G_REFERENCE_MNT; do
  [[ -z ${!name+x} ]] || die "environment override rejected: $name"
done
usage(){ cat >&2 <<'EOF'
usage: t04tmp3g-executor.sh inventory-plan RUN_ID
       t04tmp3g-executor.sh prepare-assets RUN_ID
       t04tmp3g-executor.sh run-matrix RUN_ID
       t04tmp3g-executor.sh cleanup-plan RUN_ID
       t04tmp3g-executor.sh cleanup RUN_ID
       t04tmp3g-executor.sh bundle RUN_ID
       t04tmp3g-executor.sh --self-test
EOF
exit 2; }
valid(){
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "invalid RUN_ID: $RUN_ID"
  [[ $ROOT == "/tmp/production/opencode-04tmp3g-$RUN_ID" && $ROOT != / && $ROOT != *..* ]] || die unsafe_ROOT
  [[ $ASSET_ROOT == "$REF/test_dir/04tmp3g-$RUN_ID" ]] || die unsafe_scope
  [[ ! -L $ROOT && ! -L $ASSET_ROOT ]] || die symlink_scope
  [[ $(readlink -m "$ASSET_ROOT") == "$ASSET_ROOT" ]] || die symlink_escape
}
need(){ command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
record(){ printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }
metric_text(){ awk -v n="$2" '$1 ~ ("^" n "($|\\{)") {s+=$(NF);f=1} END{if(f)printf "%.0f",s;else print "NA"}' <<<"$1"; }
incident(){ printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >>"$ROOT/incidents.tsv" || true; }
state(){ printf '%s\t%s\tACTIVE\tACTIVE\tACTIVE\tPRESERVED\tNONE\t%s\t/mnt/c/SunRise/test/04-tmp3g/%s\tGLM\n' "$(date -Is)" "$RUN_ID" "$*" "$RUN_ID" >>"$ROOT/run-state.tsv"; }
scrub_run(){ env CEPH_CONF="$CEPH_CONF" U141D_SCRUB_STATE_DIR="$STATE_DIR" "$SCRUB" "$@"; }
make_private_ceph_conf(){
 [[ -r /etc/ceph/ceph.conf && ! -L /etc/ceph/ceph.conf ]] || die ceph_conf_unavailable
 cp -- /etc/ceph/ceph.conf "$CEPH_CONF"; printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
 [[ $(md5sum "$CEPH_CONF"|awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die ceph_conf_md5
 grep -Fqx $'\tms_async_op_threads = 8' "$CEPH_CONF" || die ceph_conf_threads
}
require_private_ceph_conf(){
 [[ -r "$CEPH_CONF" && ! -L "$CEPH_CONF" && $(md5sum "$CEPH_CONF"|awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die ceph_conf_drift
 grep -Fqx $'\tms_async_op_threads = 8' "$CEPH_CONF" || die ceph_conf_threads
}

inventory(){
 ack PHASE1; valid; [[ ! -e "$ROOT" ]] || die root_exists
 local x; for x in ceph curl fio findmnt sha256sum timeout ss ip; do need "$x"; done
 mkdir -m 0700 -p "$ROOT"/{common,inventory,plans,cells,scrub,closure,recovery}
 printf 'epoch_iso\trun_id\tvalidity_state\tlifecycle_state\tremote_status\tlocal_status\tincident_status\treason\tevidence_root\tactor\n' >"$ROOT/run-state.tsv"
 printf 'epoch\ttype\tdetail\n' >"$ROOT/incidents.tsv"; printf '#!/usr/bin/env bash\n# 04-tmp3g actual command audit\n' >"$ROOT/commands.sh"
 printf 'key\tvalue\nevidence_level\tL1_SCREEN\nevidence_root\t/mnt/c/SunRise/test/04-tmp3g/%s\nremote_result_root\t%s\nevidence_retention\tSCREEN\nremote_cleanup\tAFTER_PERSISTENCE_PASS\nlocal_compaction\tAFTER_REVIEW\nenvironment_asset_cleanup\tindependent exact manifest and ACK\n' "$RUN_ID" "$ROOT" >"$ROOT/common/contract.tsv"
 hostname -f >"$ROOT/inventory/hostname.txt"; date -Ins >"$ROOT/inventory/time.txt"; fio --version >"$ROOT/inventory/fio-version.txt"; "$JFS" --version >"$ROOT/inventory/juicefs-version.txt" 2>&1
 make_private_ceph_conf; [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die jfs_identity
 ceph_read fsid >"$ROOT/inventory/ceph-fsid.txt"; ceph_read osd ls >"$ROOT/inventory/osd-ids.txt"; health inventory unpaused
 timeout 30 "$JFS" status "$META" >"$ROOT/inventory/volume-status.json"; uuid >"$ROOT/inventory/volume-uuid.txt"
 python3 - "$ROOT/inventory/volume-status.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('Setting') or {}
if s.get('Name')!='juicefs-prod' or str(s.get('BlockSize')) not in {'256','256K','262144'}: raise SystemExit('B256 identity mismatch')
PY
 mountpoint -q "$REF" || die reference_mount_absent; findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/reference-findmnt.tsv"
 [[ $(df -B1 --output=avail "$REF"|awk 'NR==2{print $1}') -ge 85899345920 ]] || die reference_space_below_80GiB
 findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS >"$ROOT/inventory/residual-mounts.tsv" || :
 awk '$1 ~ /^\/tmp\/jfs-04tmp3g-/ {bad=1} END{exit bad+0}' "$ROOT/inventory/residual-mounts.tsv" || die residual_tmp3g_mount
 ! pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1 || die foreign_fio
 ! ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)19657$' || die metrics_port_in_use
 local nic; nic=$(ip route get 10.3.1.6 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
 [[ -n $nic && -r /sys/class/net/$nic/statistics/rx_bytes && -r /sys/class/net/$nic/statistics/tx_bytes ]] || die ceph_data_nic_unavailable
 printf '%s\n' "$nic" >"$ROOT/inventory/ceph-data-nic.txt"
 [[ ! -e "$ASSET_ROOT" && ! -L "$ASSET_ROOT" ]] || die asset_run_path_exists
 local fsid lease state_file; fsid=$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt"); lease="$RUN_ID-phase-a"; state_file=$(scrub_run state-path "$lease")
 [[ $fsid =~ ^[[:xdigit:]-]+$ ]] || die invalid_fsid
 printf 'phase\tlease\tfsid\tstate_file\towned_flags\tsudo_write_budget\tack\nMATRIX\t%s\t%s\t%s\tnoscrub,nodeep-scrub\t4 max\tI_ACK_GLOBAL_CEPH_SCRUB_PAUSE\n' "$lease" "$fsid" "$state_file" >"$ROOT/plans/scrub-contract.tsv"
 printf 'sudo ceph osd set noscrub\nsudo ceph osd set nodeep-scrub\nsudo ceph osd unset nodeep-scrub\nsudo ceph osd unset noscrub\n' >"$ROOT/plans/sudo-contract.txt"
 printf 'cell\tengine\tqd\truntime\tasync_dio\nS01\tpsync\t1\t120\toff\nC08A\tlibaio\t8\t120\ton\nC01\tlibaio\t1\t60\ton\nC02\tlibaio\t2\t60\ton\nC04\tlibaio\t4\t60\ton\nC08B\tlibaio\t8\t120\ton\nS02\tpsync\t1\t120\toff\n' >"$ROOT/plans/matrix.tsv"
 cat >"$ROOT/plans/mutation-contract.txt" <<EOF
# Complete non-sudo mutation plan; requires explicit approval before prepare-assets/run-matrix/cleanup.
# Shared-volume GC, exactly one invocation after exact asset deletion; requires an independent GC ACK:
JFS_GC_SKIPPEDTIME=0 CEPH_CONF=$CEPH_CONF timeout 1800 $JFS gc --compact --delete --threads 32 $META
# Create exactly seven 10GiB files below $ASSET_ROOT using fio write/16M/direct/end_fsync.
$JFS mount -d --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 $META /tmp/jfs-04tmp3g-$RUN_ID-PREP
fio --rw=write --bs=16M --size=10G --direct=1 --end_fsync=1 --filename=$ASSET_ROOT/<S01|C08A|C01|C02|C04|C08B|S02>.bin
# Mount scopes used by the matrix; common options are max-fuse-io=1M, downloads=200, uploads=150, buffer=300, cache=0.
$JFS mount -d --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 $META /tmp/jfs-04tmp3g-$RUN_ID-SYNC1
$JFS mount -d --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 -o async_dio $META /tmp/jfs-04tmp3g-$RUN_ID-C
$JFS mount -d --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 $META /tmp/jfs-04tmp3g-$RUN_ID-SYNC2
$JFS mount -d --read-only --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 $META /tmp/jfs-04tmp3g-$RUN_ID-VERIFY
# Seven fio commands are exactly the rows in matrix.tsv, each targeting its same-named 10GiB asset.
# Cleanup is exact unlink of only the seven manifest-listed files above, followed by rmdir $ASSET_ROOT.
EOF
 local plan_cell plan_engine plan_qd plan_runtime plan_async plan_tag
 while IFS=$'\t' read -r plan_cell plan_engine plan_qd plan_runtime plan_async; do
  [[ $plan_cell != cell ]] || continue
  if [[ $plan_cell == S01 ]]; then plan_tag=SYNC1; elif [[ $plan_cell == S02 ]]; then plan_tag=SYNC2; else plan_tag=C; fi
  printf 'fio --name=write16m --filename=/tmp/jfs-04tmp3g-%s-%s/test_dir/04tmp3g-%s/%s.bin --size=10G --bs=16M --rw=write --direct=1 --numjobs=1 --ioengine=%s --iodepth=%s --allow_file_create=0 --runtime=%s --time_based --group_reporting\n' \
    "$RUN_ID" "$plan_tag" "$RUN_ID" "$plan_cell" "$plan_engine" "$plan_qd" "$plan_runtime" >>"$ROOT/plans/mutation-contract.txt"
 done <"$ROOT/plans/matrix.tsv"
 sha256sum "$ROOT/plans/mutation-contract.txt" >"$ROOT/plans/mutation-contract.txt.sha256"
 scrub_run plan-pause "$lease" >"$ROOT/plans/scrub-plan.txt" 2>&1
 sha256sum "$EXECUTOR" "$ANALYZER" "$SCRUB" >"$ROOT/plans/runtime-scripts.sha256"
 printf 'INVENTORY_PLAN_PASS\n' >"$ROOT/inventory/PASS"; state 'Phase I inventory/plan'; printf 'T04TMP3G_INVENTORY_PLAN_PASS\t%s\n' "$ROOT"
}
prepare_assets(){
 ack PREPARE; valid; [[ -f "$ROOT/inventory/PASS" ]] || die inventory_required; frozen; require_private_ceph_conf
 sha256sum -c "$ROOT/plans/mutation-contract.txt.sha256" >/dev/null || die mutation_plan_drift
 mountpoint -q "$REF" || die reference_mount_absent; [[ ! -e "$ASSET_ROOT" && ! -L "$ASSET_ROOT" ]] || die prepare_scope_not_empty
 health PREPARE-pre preparing; foreign_fio PREPARE-pre; cooldown PRE NONE
 O0=$(pool_objects); printf '%s\n' "$O0" >"$ROOT/inventory/O0.tsv"
 trap on_exit EXIT TERM INT HUP; mkdir -m 0700 -p "$ROOT/prepare" "$ROOT/cells/PREP/bwlog"
 mount_arm PREP S; local base cell; base="/tmp/jfs-04tmp3g-$RUN_ID-PREP/test_dir/04tmp3g-$RUN_ID"; mkdir -m 0700 -p "$base"
 for cell in S01 C08A C01 C02 C04 C08B S02; do prepare_file "$base/$cell.bin" 10G "$cell"; done
 : >"$ROOT/prepare/assets-manifest.tsv"
 while IFS= read -r p; do [[ -f $p && ! -L $p ]] || die prepare_asset_missing; printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$(stat -c %s "$p")" "$(stat -c %b "$p")" "$(head -c 1048576 "$p"|sha256sum|awk '{print $1}')" "$(tail -c 1048576 "$p"|sha256sum|awk '{print $1}')" >>"$ROOT/prepare/assets-manifest.tsv"; done < <(asset_paths "$base")
 awk -F '\t' '$2!=10737418240 || $3*512<10200547328{bad=1} END{exit bad}' "$ROOT/prepare/assets-manifest.tsv" || die sparse_or_size_asset
 unmount_arm PREP; trap - EXIT; cooldown POSTPREP NONE
 O1=$(pool_objects); printf '%s\n' "$O1" >"$ROOT/inventory/O1.tsv"; (( O1 > O0 )) || die prepared_object_anchor_not_increased
 health PREPARE-post preparing; printf 'PREPARE_ASSETS_PASS\n' >"$ROOT/prepare/PASS"; state 'Phase II prepare-assets'; printf 'T04TMP3G_PREPARE_ASSETS_PASS\t%s\n' "$ROOT"
}
cleanup_plan(){
 ensure; local out="$ROOT/closure/cleanup-manifest.tsv"; printf 'absolute_path\tasset_class\n' >"$out"
 while IFS= read -r p; do [[ -f $p && ! -L $p ]] && printf '%s\tRUN_PREPARED_ASSET\n' "$p" >>"$out"; done < <(asset_paths "$ASSET_ROOT")
 sha256sum "$out" >"$out.sha256"; printf 'CLEANUP_PLAN_PASS\t%s\n' "$out"
}
cleanup(){
 valid; ack CLEANUP; mkdir -m 0700 -p "$ROOT/closure"
 sha256sum -c "$ROOT/plans/mutation-contract.txt.sha256" >/dev/null || die mutation_plan_drift
 [[ -f "$ROOT/inventory/ceph-fsid.txt" && -f "$ROOT/inventory/volume-uuid.txt" ]] || die cleanup_identity_missing; require_private_ceph_conf
 [[ $(ceph_read fsid|tr -d '[:space:]') == "$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt")" ]] || die cleanup_fsid_drift
 [[ $(uuid) == "$(<"$ROOT/inventory/volume-uuid.txt")" ]] || die cleanup_uuid_drift
 local lease="$RUN_ID-phase-a" sf tag out mnt; sf=$(scrub_run state-path "$lease"); [[ ! -f $sf ]] || restore_lease "$lease" || die cleanup_scrub_restore
 for tag in PREP SYNC1 C SYNC2 VERIFY; do mnt="/tmp/jfs-04tmp3g-$RUN_ID-$tag"; if mountpoint -q "$mnt"; then unmount_arm "$tag"; elif [[ -e $mnt ]]; then [[ -d $mnt && ! -L $mnt && -z $(find "$mnt" -mindepth 1 -maxdepth 1 -print -quit) ]] || die unsafe_residual_mount_dir; rmdir "$mnt"; fi; done
 health CLEANUP-pre unpaused; out="$ROOT/closure/cleanup-manifest.tsv"; [[ -f "$out" && -f "$out.sha256" ]] || die cleanup_plan_required; sha256sum -c "$out.sha256" >/dev/null || die cleanup_plan_drift
 python3 - "$out" "$ASSET_ROOT" <<'PY'
import os,sys
manifest,root=sys.argv[1:]
if root=='/' or not root.startswith('/mnt/juicefs/test_dir/04tmp3g-') or os.path.islink(root): raise SystemExit('unsafe asset root')
for line in open(manifest).read().splitlines()[1:]:
    if not line: continue
    path=line.split('\t')[0]
    if not path.startswith(root+'/') or os.path.realpath(path)!=path or os.path.islink(path): raise SystemExit('unsafe cleanup target '+path)
    if os.path.exists(path):
        if not os.path.isfile(path): raise SystemExit('cleanup target not regular')
        os.unlink(path)
PY
 rmdir "$ASSET_ROOT"; O0=$(<"$ROOT/inventory/O0.tsv")
 [[ ${T04TMP3G_GC_ACK:-} == "I_ACK_04TMP3G_SHARED_GC_$RUN_ID" ]] || die "required exact GC ACK: I_ACK_04TMP3G_SHARED_GC_$RUN_ID"
 combined_gc CLEANUP; cooldown CLEANUP "$O0"
 [[ ! -e "$ASSET_ROOT" ]] || die cleanup_asset_remains; mountpoint -q "$REF" || die reference_mount_absent
 [[ $(findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS) == "$(<"$ROOT/inventory/reference-findmnt.tsv")" ]] || die reference_mount_drift
 health CLEANUP-post unpaused; printf 'CLEANUP_PASS\n' >"$ROOT/closure/CLEANUP_PASS"; state CLEANUP_PASS
}
bundle(){
 ensure; [[ -f "$ROOT/closure/CLEANUP_PASS" ]] || die cleanup_required; local a; a="/tmp/production/04tmp3g-$RUN_ID-evidence.tar"; [[ ! -e $a && ! -L $a ]] || die bundle_exists
 (cd "$ROOT" && find . -type f ! -name 'manifest.sha256' -print0 | sort -z | xargs -0 sha256sum) >"$ROOT/closure/manifest.sha256"; tar -C /tmp/production -cf "$a" "opencode-04tmp3g-$RUN_ID"; sha256sum "$a" >"$a.sha256"; printf 'source\tsha256\ttarget\n%s\t%s\t/mnt/c/SunRise/test/04-tmp3g/%s/\n' "$a" "$(awk '{print $1}' "$a.sha256")" "$RUN_ID" >"$ROOT/closure/copy-to-mnt-c.tsv"; printf 'BUNDLE_PASS\t%s\n' "$a"
}
self_test(){
 local t; t=$(mktemp -d /tmp/t04tmp3g-executor-selftest.XXXXXX)
 RUN_ID=20260906-000000; ROOT="/tmp/production/opencode-04tmp3g-$RUN_ID"; ASSET_ROOT="/mnt/juicefs/test_dir/04tmp3g-$RUN_ID"
 T04TMP3G_ACK="I_ACK_04TMP3G_PREPARE_$RUN_ID"; ack PREPARE; if (T04TMP3G_ACK=bad ack PREPARE) 2>/dev/null; then die selftest_ack_not_strict; fi
 printf 'S01\nC08A\nC01\nC02\nC04\nC08B\nS02\n' >"$t/matrix"
 [[ $(wc -l <"$t/matrix") == 7 && $(sed -n '2p' "$t/matrix") == C08A && $(sed -n '6p' "$t/matrix") == C08B ]] || die selftest_matrix
 unlink "$t/matrix"; rmdir "$t"; printf 'T04TMP3G_EXECUTOR_SELFTEST_PASS\n'
}
ack(){
  local k expected; k="$1"; expected="I_ACK_04TMP3G_${k}_${RUN_ID}"
  [[ "${T04TMP3G_ACK:-}" == "$expected" ]] || die "required exact ACK: $expected"
}
ensure(){
  valid; [[ -d $ROOT && -f $ROOT/inventory/PASS && -f $ROOT/prepare/PASS && -f $ROOT/plans/runtime-scripts.sha256 && -f $ROOT/inventory/O0.tsv && -f $ROOT/inventory/O1.tsv ]] || die prepare_not_passed
  O0=$(<"$ROOT/inventory/O0.tsv"); O1=$(<"$ROOT/inventory/O1.tsv"); [[ $O0 =~ ^[0-9]+$ && $O1 =~ ^[0-9]+$ ]] || die invalid_object_anchor
  [[ -f $ROOT/commands.sh && -f $ROOT/incidents.tsv ]] || die audit_missing
}
frozen(){ (cd / && sha256sum -c "$ROOT/plans/runtime-scripts.sha256") >/dev/null || die script_drift; }
ceph_read(){ timeout 20 env CEPH_CONF="$CEPH_CONF" ceph "$@"; }
combined_gc(){
 local label out; label="$1"; out="$ROOT/recovery-$label-gc.log"; record env JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" timeout 1800 "$JFS" gc --compact --delete --threads 32 "$META"; JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" timeout 1800 "$JFS" gc --compact --delete --threads 32 "$META" >"$out" 2>&1 || die "combined gc failed: $label"
}
prepare_file(){
	local path size label rc out expected
	path="$1"; size="$2"; label="$3"; out="$ROOT/prepare/$label.fio.json"
	case "$size" in 10G) expected=10737418240;; 20G) expected=21474836480;; *) die "unsupported prepare size: $size";; esac
 [[ $path == /tmp/jfs-04tmp3g-"$RUN_ID"-PREP/test_dir/04tmp3g-"$RUN_ID"/* && ! -e $path && ! -L $path ]] || die "unsafe/existing prepare target: $path"
 record timeout 300 fio --name="prepare_$label" --filename="$path" --rw=write --bs=16M --size="$size" --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --output="$out" --output-format=json
 set +e
 timeout 300 fio --name="prepare_$label" --filename="$path" --rw=write --bs=16M --size="$size" --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --output="$out" --output-format=json
 rc=$?
 set -e
	(( rc == 0 )) || die "prepare fio failed label=$label rc=$rc"
	[[ -f $path && ! -L $path && $(stat -c %s "$path") == "$expected" ]] || die "prepared file size mismatch label=$label expected=$expected"
 python3 - "$out" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); rows=d.get('jobs')
if not isinstance(rows,list) or len(rows)!=1 or rows[0].get('error') != 0:
    raise SystemExit('prepare fio JSON error')
PY
}
asset_paths(){
 local base=$1 cell
 for cell in S01 C08A C01 C02 C04 C08B S02; do printf '%s\n' "$base/$cell.bin"; done
}
assert_anchor(){
 local actual anchor label low high; actual="$1"; anchor="$2"; label="$3"; low=$((anchor-8192)); (( low < 0 )) && low=0; high=$((anchor+8192)); [[ $actual =~ ^[0-9]+$ && $actual -ge $low && $actual -le $high ]] || die "object anchor drift label=$label anchor=$anchor actual=$actual"
}
uuid(){ timeout 30 env CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" | python3 -c 'import json,sys; d=json.load(sys.stdin); u=(d.get("Setting") or {}).get("UUID"); assert isinstance(u,str) and u; print(u)'; }
pool_stats(){ ceph_read df detail --format json | python3 -c 'import json,sys; p=[x for x in json.load(sys.stdin).get("pools",[]) if x.get("name")=="juicefs-data"]; assert len(p)==1; s=p[0]["stats"]; assert isinstance(s.get("objects"),int) and isinstance(s.get("stored"),int); print(s["objects"],s["stored"])'; }
pool_objects(){ pool_stats | awk '{print $1}'; }
health(){
 local tag mode out; tag="$1"; mode="$2"; out="$ROOT/health-$tag"; mkdir -m 0700 -p "$out"
 ceph_read -s --format json >"$out/status.json"; ceph_read osd stat --format json >"$out/osd-stat.json"
 python3 - "$out/status.json" "$out/osd-stat.json" "$mode" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2])); mode=sys.argv[3]
h=s.get("health",{}); st=h.get("status"); checks=set((h.get("checks") or {}).keys()); pg=s.get("pgmap",{}).get("pgs_by_state",[])
if not pg: raise SystemExit("PG state missing")
if mode == "preparing":
 allowed={"active","clean","scrubbing","deep"}
 if any(not {p for p in str(x.get("state_name","")).split("+") if p}.issubset(allowed) or not {"active","clean"}.issubset(set(str(x.get("state_name","")).split("+"))) for x in pg): raise SystemExit("PG has non-preparation state")
elif any(x.get("state_name")!="active+clean" for x in pg): raise SystemExit("PG not active+clean")
if any(o.get(k)!=6 for k in ("num_osds","num_up_osds","num_in_osds")): raise SystemExit("OSDs not exactly 6/6 up-in")
if mode=="unpaused" and (st!="HEALTH_OK" or checks): raise SystemExit(f"unpaused health={st} checks={checks}")
if mode=="preparing" and (st!="HEALTH_OK" or checks): raise SystemExit(f"preparing health={st} checks={checks}")
if mode=="paused" and not ((st=="HEALTH_OK" and not checks) or (st=="HEALTH_WARN" and checks=={"OSDMAP_FLAGS"})): raise SystemExit(f"paused health={st} checks={checks}")
PY
 printf 'PASS\t%s\t%s\n' "$tag" "$mode" >"$out/PASS"
}
foreign_fio(){
 local out; out="$ROOT/foreign-fio-$1.tsv"; printf 'pid\tstarttime\tcmdline\n' >"$out"
 python3 - "$out" <<'PY'
import pathlib,sys
rows=[]
for p in pathlib.Path("/proc").glob("[0-9]*"):
 try:
  if (p/"comm").read_text().strip()=="fio": rows.append((p.name,(p/"stat").read_text().split()[21],(p/"cmdline").read_bytes().replace(b"\0",b" ").decode(errors="replace")))
 except (OSError,ValueError,IndexError): pass
with open(sys.argv[1],"a") as f:
 for r in rows:f.write("\t".join(r)+"\n")
if rows: raise SystemExit("foreign fio exists")
PY
}
asset_snapshot(){
 local file=$1 out=$2
 [[ -f $file && ! -L $file && $(stat -c %s "$file") == 10737418240 ]] || die asset_identity
 printf 'path\tinode\tbytes\tmtime\thead_sha256\ttail_sha256\n%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$(stat -c %i "$file")" "$(stat -c %s "$file")" "$(stat -c %Y "$file")" "$(head -c 1048576 "$file"|sha256sum|awk '{print $1}')" "$(tail -c 1048576 "$file"|sha256sum|awk '{print $1}')" >"$out"
}

cell_snapshot(){
 local cell tag out nic text
 cell=$1; tag=$2; out="$ROOT/cells/$cell"
 nic=$(<"$ROOT/inventory/ceph-data-nic.txt")
 [[ -n $nic && -r /sys/class/net/$nic/statistics/rx_bytes && -r /sys/class/net/$nic/statistics/tx_bytes ]] || die "ceph_nic_drift_$cell"
 text=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || die "metrics_${cell}_${tag}"
 printf '%s\n' "$text" >"$out/metrics-$tag.txt"
 grep -Fq 'vol_name="juicefs-prod"' "$out/metrics-$tag.txt" || die "metrics_volume_${cell}_${tag}"
 {
  printf 'epoch_ns\tcpu_user\tcpu_nice\tcpu_system\tcpu_idle\tcpu_iowait\trx_bytes\ttx_bytes\n'
  read -r _ user nice system idle iowait _ < /proc/stat
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$user" "$nice" "$system" "$idle" "$iowait" \
    "$(<"/sys/class/net/$nic/statistics/rx_bytes")" "$(<"/sys/class/net/$nic/statistics/tx_bytes")"
 } >"$out/host-$tag.tsv"
}

mount_arm(){
 local cell arm out mnt log; cell="$1"; arm="$2"; out="$ROOT/cells/$cell"; mnt="/tmp/jfs-04tmp3g-$RUN_ID-$cell"; [[ ! -e $mnt && ! -L $mnt ]] || die mount_exists; mkdir -m 0700 "$mnt"; mkdir -m 0700 -p "$out/bwlog"; log="$out/juicefs-mount.log"; local -a cmd; cmd=("$JFS" mount -d --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0 --metrics "$METRICS_ADDR" --log "$log")
 require_private_ceph_conf
 case "$arm" in S) :;; C) cmd+=(-o async_dio);; V) cmd+=(--read-only);; *) die bad_arm;; esac
	cmd+=("$META" "$mnt"); record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"; local -a envcmd; envcmd=(env "CEPH_CONF=$CEPH_CONF"); if ! timeout 180 "${envcmd[@]}" "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr"; then mountpoint -q "$mnt" && ACTIVE_MNT="$mnt"; die "mount failed: $cell"; fi
 for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done; mountpoint -q "$mnt" || die mount_timeout; ACTIVE_MNT="$mnt"; findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/findmnt.tsv"; grep -Fq "JuiceFS:juicefs-prod $mnt fuse.juicefs" "$out/findmnt.tsv" || die mount_source_mismatch
 python3 - "$JFS" "$META" "$mnt" "$log" "$out/mount-process.tsv" <<'PY'
import hashlib,os,pathlib,sys
exe,meta,mnt,log,out=sys.argv[1:]; exe=os.path.realpath(exe); rows=[]
for p in pathlib.Path("/proc").glob("[0-9]*"):
 try:
  if os.path.realpath(p/"exe")!=exe: continue
  cmd=(p/"cmdline").read_bytes().replace(b"\0",b" ").decode(errors="replace")
  # JuiceFS rewrites its Go process title into the original argv buffer.  A
  # long arm can truncate the title inside META before the mount path, while
  # the unique per-RUN --log path (placed earlier) remains complete.
  if log not in cmd: continue
  st=(p/"stat").read_text().split(); rows.append((p.name,st[3],st[21],hashlib.md5(open(p/"exe","rb").read()).hexdigest(),cmd))
 except (OSError,ValueError,IndexError): pass
if not rows: raise SystemExit("no launch-scoped JuiceFS process")
with open(out,"w") as f:
 f.write("pid\tppid\tstarttime\texe_md5\tcmdline\n")
 for r in sorted(rows,key=lambda x:int(x[0])): f.write("\t".join(r)+"\n")
PY
 [[ $(awk 'NR>1{n++} END{print n+0}' "$out/mount-process.tsv") -ge 1 ]] || die mount_identity_missing; local worker threads; worker=$(python3 - "$out/mount-process.tsv" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t')); pids={r['pid'] for r in rows}
w=[r['pid'] for r in rows if r['ppid'] in pids]
print(w[0] if len(w)==1 else '')
PY
); [[ $worker =~ ^[0-9]+$ ]] || die worker_missing; threads=$(grep -l '^msgr-worker' /proc/"$worker"/task/*/comm 2>/dev/null|wc -l || true); [[ $threads == 8 ]] || die "msgr_worker_threads=$threads"; [[ $(readlink -f /proc/"$worker"/exe) == "$JFS" ]] || die worker_exe_drift; printf 'worker_pid\t%s\nworker_starttime\t%s\nworker_exe\t%s\nmsgr_worker_threads\t%s\n' "$worker" "$(awk '{print $22}' /proc/"$worker"/stat)" "$(readlink -f /proc/"$worker"/exe)" "$threads" >"$out/mount-state.tsv"; if [[ -f "$ROOT/inventory/volume-uuid.txt" ]]; then [[ $(uuid) == "$(<"$ROOT/inventory/volume-uuid.txt")" ]] || die volume_uuid_drift; fi
 case "$arm" in C) grep -Fq -- '-o async_dio' "$out/mount-process.tsv" || die async_dio_runtime_missing;; S|V) ! grep -Fq -- '-o async_dio' "$out/mount-process.tsv" || die async_dio_runtime_unexpected;; esac
 printf 'arm\t%s\nasync_dio\t%s\nworker_pid\t%s\nworker_starttime\t%s\n' "$arm" "$([[ $arm == C ]] && printf on || printf off)" "$worker" "$(awk '{print $22}' /proc/"$worker"/stat)" >"$out/mount-mode.tsv"
}
verify_arm(){
 local cell out mnt worker start actual threads
 cell="$1"; out="$ROOT/cells/$cell"; mnt="/tmp/jfs-04tmp3g-$RUN_ID-$cell"
 mountpoint -q "$mnt" || die "mount disappeared: $cell"
 [[ $(findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE) == "JuiceFS:juicefs-prod $mnt fuse.juicefs" ]] || die "mount identity drift: $cell"
 [[ -s "$out/mount-state.tsv" ]] || die "mount state missing: $cell"
 worker=$(awk -F '\t' '$1=="worker_pid"{print $2}' "$out/mount-state.tsv"); start=$(awk -F '\t' '$1=="worker_starttime"{print $2}' "$out/mount-state.tsv")
 [[ $worker =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && -r /proc/$worker/stat ]] || die "worker missing: $cell"
 actual=$(awk '{print $22}' /proc/"$worker"/stat); [[ $actual == "$start" && $(readlink -f /proc/"$worker"/exe) == "$JFS" ]] || die "worker identity drift: $cell"
 threads=$(grep -l '^msgr-worker' /proc/"$worker"/task/*/comm 2>/dev/null | wc -l || true); [[ $threads == 8 ]] || die "msgr worker drift: $cell threads=$threads"
}
arm_processes_gone(){
 local cell out
 cell="$1"; out="$ROOT/cells/$cell/mount-process.tsv"; [[ -s $out ]] || return 0
 python3 - "$JFS" "$out" <<'PY'
import csv,os,sys
exe=os.path.realpath(sys.argv[1]); rows=list(csv.DictReader(open(sys.argv[2]),delimiter='\t'))
for r in rows:
    try:
        if os.path.realpath('/proc/'+r['pid']+'/exe') == exe and open('/proc/'+r['pid']+'/stat').read().split()[21] == r['starttime']:
            raise SystemExit(1)
    except OSError:
        pass
PY
}
unmount_arm(){
 local cell out mnt; cell="$1"; out="$ROOT/cells/$cell"; mnt="/tmp/jfs-04tmp3g-$RUN_ID-$cell"; verify_arm "$cell"; record timeout 180 env "CEPH_CONF=$CEPH_CONF" "$JFS" umount "$mnt"; timeout 180 env CEPH_CONF="$CEPH_CONF" "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr" || die graceful_unmount_failed
 for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done; mountpoint -q "$mnt" && die mount_remains; for _ in $(seq 1 60); do arm_processes_gone "$cell" && break; sleep 1; done; arm_processes_gone "$cell" || die "mount processes remain: $cell"
 grep -Eai 'panic|assert|I/O error|fatal' "$out/juicefs-mount.log" >"$out/mount-log-errors.txt" || :
 [[ ! -s "$out/mount-log-errors.txt" ]] || die "mount_log_error_$cell"
 printf 'MOUNT_LOG_GATE_PASS\n' >"$out/mount-log-gate.PASS"
 [[ -d $mnt && ! -L $mnt && -z $(find "$mnt" -mindepth 1 -maxdepth 1 -print -quit) ]] || die mount_dir_not_empty; rmdir "$mnt"; ACTIVE_MNT=
}
fio_cell(){
 local cell engine qd runtime out file prefix
 cell=$1; engine=$2; qd=$3; runtime=$4
 out="$ROOT/cells/$cell"; file="$TMP_BASE/$cell.bin"; prefix="$ROOT/cells/$cell/bwlog/$cell"
 mkdir -m 0700 -p "$out/bwlog"
 local -a cmd=(fio --name=write16m --filename="$file" --size=10G --bs=16M --rw=write --direct=1 --numjobs=1 --ioengine="$engine" --iodepth="$qd" --allow_file_create=0 --runtime="$runtime" --time_based --group_reporting --write_bw_log="$prefix" --log_avg_msec=1000 --output="$out/fio.txt" --output-format=json+)
 printf '%s\n' "$(date +%s%N)" >"$out/fio-registered-start-ns.txt"; record "${cmd[@]}"
 local rc; set +e; timeout "$((runtime+120))" "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; set -e
 printf '%s\n' "$rc" >"$out/fio.rc"; date +%s%N >"$out/fio-end-ns.txt"; (( rc==0 )) || die "fio_failed_$cell"
 [[ $(find "$out/bwlog" -maxdepth 1 -type f -name '*_bw.*.log'|wc -l) -eq 1 ]] || die "bwlog_count_$cell"
 python3 "$ANALYZER" cell "$out" --expected-file "$file" --engine "$engine" --qd "$qd" --runtime "$runtime" >"$out/analysis.json" || die "analyzer_$cell"
}
wait_write_settle(){
 local cell=$1 start now zeros=0 text uploading; start=$(date +%s); printf 'epoch_ns\tuploading\n' >"$ROOT/cells/$cell/upload-drain.tsv"
 while :; do
  text=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || die metrics_unavailable
  uploading=$(metric_text "$text" juicefs_object_request_uploading); [[ $uploading != NA ]] || die uploading_metric_missing
  printf '%s\t%s\n' "$(date +%s%N)" "$uploading" >>"$ROOT/cells/$cell/upload-drain.tsv"
  [[ $uploading == 0 ]] && zeros=$((zeros+1)) || zeros=0; (( zeros >= 2 )) && return 0
  now=$(date +%s); (( now-start < 300 )) || die "upload_drain_timeout_$cell"; sleep 2
 done
}

pending(){ curl -fsS --connect-timeout 3 --max-time 8 "http://$1:20180/metrics"|awk '$1~/^tikv_engine_pending_compaction_bytes(\{|$)/{s+=$2;n=1}END{if(!n)exit 1;printf "%.0f\n",s}'; }
cooldown(){
 local cell target out osd run queue lat ep val ok obj stored low high previous_obj previous_stored stable; cell="$1"; target="${2:-NONE}"; out="$ROOT/recovery/$cell"; mkdir -m 0700 -p "$out/raw"; printf 'epoch\tround\tosd\tcompact_running\tcompact_queue_len\tkv_sync_lat\n' >"$out/osd.tsv"; printf 'epoch\tround\tendpoint\tpending\n' >"$out/tikv.tsv"; printf 'epoch\tround\tobjects\tstored\ttarget\tstable_count\n' >"$out/pool.tsv"; previous_obj=; previous_stored=; stable=0
 for round in $(seq 1 120); do ok=1
  for osd in $(cat "$ROOT/inventory/osd-ids.txt"); do
   ceph_read tell "osd.$osd" perf dump >"$out/raw/osd-$osd-$round.json"; read -r run queue lat < <(python3 - "$out/raw/osd-$osd-$round.json" <<'PY'
import json,math,sys
d=json.load(open(sys.argv[1])); f={}
def w(x):
 if isinstance(x,dict):
  for k,v in x.items():
   if k in ("compact_running","compact_queue_len") and isinstance(v,(int,float)): f[k]=v
   if k=="kv_sync_lat" and isinstance(v,dict) and isinstance(v.get("avgtime"),(int,float)): f["kv_sync_lat"]=v["avgtime"]
   w(v)
 elif isinstance(x,list):
  for v in x:w(v)
w(d)
if any(k not in f or not math.isfinite(float(f[k])) for k in ("compact_running","compact_queue_len","kv_sync_lat")): raise SystemExit("compact field missing")
print(f["compact_running"],f["compact_queue_len"],f["kv_sync_lat"])
PY
); printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$osd" "$run" "$queue" "$lat" >>"$out/osd.tsv"; [[ $run == 0 && $queue == 0 ]] || ok=0
  done
  for ep in 10.20.1.150 10.20.1.151 10.20.1.152; do val=$(pending "$ep") || die "pending metric unavailable: $ep"; printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$ep" "$val" >>"$out/tikv.tsv"; [[ $val == 0 ]] || ok=0; done
  read -r obj stored < <(pool_stats); if [[ $target != NONE ]]; then low=$((target-8192)); (( low < 0 )) && low=0; high=$((target+8192)); (( obj >= low && obj <= high )) || ok=0; fi
  if (( ok )) && [[ $obj == "$previous_obj" && $stored == "$previous_stored" ]]; then stable=$((stable+1)); elif (( ok )); then stable=1; else stable=0; fi
  previous_obj=$obj; previous_stored=$stored; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$round" "$obj" "$stored" "$target" "$stable" >>"$out/pool.tsv"
  (( stable >= 3 )) && { printf 'COOLDOWN_PASS\tobjects=%s\tstored=%s\n' "$obj" "$stored" >"$out/PASS"; return; }; sleep 10
 done
 die cooldown_timeout
}
run_cell(){
 local cell engine qd runtime mount_tag out file
 cell=$1; engine=$2; qd=$3; runtime=$4; mount_tag=$5
 out="$ROOT/cells/$cell"; file="$TMP_BASE/$cell.bin"
 [[ ! -e $out ]] || die "cell_exists_$cell"; mkdir -m 0700 -p "$out"; frozen; health "$cell-pre" paused; foreign_fio "$cell-pre"
 cp "$ROOT/cells/$mount_tag/mount-state.tsv" "$out/mount-state-ref.tsv"; cp "$ROOT/cells/$mount_tag/mount-mode.tsv" "$out/mount-mode-ref.tsv"
 asset_snapshot "$file" "$out/assets-pre.tsv"; cell_snapshot "$cell" pre; fio_cell "$cell" "$engine" "$qd" "$runtime"
 wait_write_settle "$cell"; cell_snapshot "$cell" post; health "$cell-post" paused
 asset_snapshot "$file" "$out/assets-post.tsv"; printf 'CELL_PASS\t%s\n' "$cell" >"$out/PASS"
}
verify_all_assets(){
 local cell now expected
 for cell in S01 C08A C01 C02 C04 C08B S02; do
  asset_snapshot "$TMP_BASE/$cell.bin" "$ROOT/cells/$cell/assets-remount.tsv"
  now=$(cut -f3,5,6 "$ROOT/cells/$cell/assets-remount.tsv"|tail -1); expected=$(cut -f3,5,6 "$ROOT/cells/$cell/assets-post.tsv"|tail -1)
 [[ $now == "$expected" ]] || die "remount_persistence_$cell"
 done
 [[ $(find "$TMP_BASE" -mindepth 1 -maxdepth 1 -type f -name '*.bin' | wc -l) -eq 7 ]] || die remount_asset_count
}

restore_lease(){
 local lease sf rc; lease="$1"; sf=$(scrub_run state-path "$lease") || return 1; [[ -f $sf ]] || return 0; set +e; scrub_run restore "$lease" >"$ROOT/scrub/$lease-restore.log" 2>&1; rc=$?; set -e
 ((rc==0)) || { incident SCRUB_RESTORE_FAILED "lease=$lease rc=$rc"; return "$rc"; }; scrub_run verify-restored "$lease" >>"$ROOT/scrub/$lease-restore.log" 2>&1 || { incident SCRUB_RESTORE_VERIFY_FAILED "lease=$lease"; return 1; }; ACTIVE_LEASE=; state "RESTORED lease=$lease"
}
on_exit(){ local rc cell; rc=$?; trap - EXIT TERM INT HUP; set +e; if [[ -n "${ACTIVE_LEASE:-}" ]]; then restore_lease "$ACTIVE_LEASE" || rc=97; fi; if [[ -n "${ACTIVE_MNT:-}" ]]; then cell="${ACTIVE_MNT##*-}"; unmount_arm "$cell" || rc=98; fi; exit "$rc"; }
run_phase(){
 ack MATRIX; ensure; frozen; health MATRIX-pre unpaused; foreign_fio MATRIX-pre
 sha256sum -c "$ROOT/plans/mutation-contract.txt.sha256" >/dev/null || die mutation_plan_drift
 [[ ${T04TMP3G_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die 'required scrub ACK: I_ACK_GLOBAL_CEPH_SCRUB_PAUSE'
 local lease="$RUN_ID-phase-a" fsid start end; fsid=$(<"$ROOT/inventory/ceph-fsid.txt"); start=$(pool_objects); assert_anchor "$start" "$O1" MATRIX-start
 record env "CEPH_CONF=$CEPH_CONF" "U141D_SCRUB_STATE_DIR=$STATE_DIR" "$SCRUB" pause "$lease" "$fsid" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
 ACTIVE_LEASE="$lease"; trap on_exit EXIT TERM INT HUP; scrub_run pause "$lease" "$fsid" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$ROOT/scrub/$lease-pause.log" 2>&1
 scrub_run verify-paused "$lease" >>"$ROOT/scrub/$lease-pause.log" 2>&1; health MATRIX-paused paused
 mkdir -m 0700 -p "$ROOT/cells/SYNC1/bwlog"; mount_arm SYNC1 S; TMP_BASE="/tmp/jfs-04tmp3g-$RUN_ID-SYNC1/test_dir/04tmp3g-$RUN_ID"; run_cell S01 psync 1 120 SYNC1; unmount_arm SYNC1
 mkdir -m 0700 -p "$ROOT/cells/C/bwlog"; mount_arm C C; TMP_BASE="/tmp/jfs-04tmp3g-$RUN_ID-C/test_dir/04tmp3g-$RUN_ID"
 run_cell C08A libaio 8 120 C; run_cell C01 libaio 1 60 C; run_cell C02 libaio 2 60 C; run_cell C04 libaio 4 60 C; run_cell C08B libaio 8 120 C; unmount_arm C
 mkdir -m 0700 -p "$ROOT/cells/SYNC2/bwlog"; mount_arm SYNC2 S; TMP_BASE="/tmp/jfs-04tmp3g-$RUN_ID-SYNC2/test_dir/04tmp3g-$RUN_ID"; run_cell S02 psync 1 120 SYNC2; unmount_arm SYNC2
 mkdir -m 0700 -p "$ROOT/cells/VERIFY/bwlog"; mount_arm VERIFY V; TMP_BASE="/tmp/jfs-04tmp3g-$RUN_ID-VERIFY/test_dir/04tmp3g-$RUN_ID"; verify_all_assets; unmount_arm VERIFY
 restore_lease "$lease"; trap - EXIT TERM INT HUP; health MATRIX-restored unpaused; end=$(pool_objects); printf '%s\n' "$end" >"$ROOT/MATRIX-objects-end.tsv"
 python3 "$ANALYZER" run "$ROOT" >"$ROOT/derived-summary.json" || die final_analyzer
 printf 'MATRIX_PASS\n' >"$ROOT/MATRIX_PHASE_PASS"; state MATRIX_PHASE_PASS
}

if [[ "$MODE" == --self-test ]]; then self_test; exit 0; fi
case "$MODE" in
 prepare-assets) [[ $# -eq 2 ]] || usage; valid; prepare_assets ;;
 inventory-plan) [[ $# -eq 2 ]] || usage; valid; inventory ;;
 run-matrix) [[ $# -eq 2 ]] || usage; valid; run_phase ;;
 cleanup-plan) [[ $# -eq 2 ]] || usage; valid; cleanup_plan ;;
 cleanup) [[ $# -eq 2 ]] || usage; valid; cleanup ;;
 bundle) [[ $# -eq 2 ]] || usage; valid; bundle ;;
 *) usage ;;
esac
