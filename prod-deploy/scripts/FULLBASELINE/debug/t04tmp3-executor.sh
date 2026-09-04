#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 04-tmp3 157-side executor; no SSH client. Evidence is bundled for /mnt/c copy.
# DEFECT-D01 DEFECT-D04 DEFECT-D05 DEFECT-D06 DEFECT-D08 DEFECT-D12 DEFECT-D16
# DEFECT-D17 DEFECT-D19 DEFECT-D21 DEFECT-D22 DEFECT-D23 DEFECT-D25 DEFECT-D26
# DEFECT-D27 DEFECT-D28 DEFECT-D29 DEFECT-D30 DEFECT-D31 DEFECT-D32
MODE="${1:-}"; RUN_ID="${2:-}"
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRIVER=$SELF_DIR/t04tmp3-screen-driver.sh
ANALYZER=$SELF_DIR/t04tmp3-screen-analyze.py
SCRUB=$SELF_DIR/u141d-scrub-control.sh
JFS=/tmp/juicefs-1.4.1-patched
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REF=/mnt/juicefs
SCRATCH_PARENT=/mnt/jfs-cache/04tmp3
ROOT="/tmp/production/opencode-04tmp3-$RUN_ID"
ASSET_ROOT="$REF/test_dir/04tmp3-$RUN_ID"
SCRATCH="$SCRATCH_PARENT/jfs-04tmp3-$RUN_ID"
CEPH_CONF="$ROOT/inventory/ceph-msgr8.conf"
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
JFS_MD5=24fae0852051c80ca571cb2f20275d46
STATE_DIR="$ROOT/scrub"
ACTIVE_LEASE=
ACTIVE_MNT=
O0=
O1=
EXECUTOR=$(readlink -f "$SELF_DIR/t04tmp3-executor.sh")

die(){ printf 'T04TMP3_EXECUTOR_FAIL\t%s\n' "$*" >&2; exit 42; }
for name in T04TMP3_JFS T04TMP3_META T04TMP3_REFERENCE_MNT T04TMP3_SCRATCH_PARENT; do
  [[ -z ${!name+x} ]] || die "environment override rejected: $name"
done
usage(){ cat >&2 <<'EOF'
usage: t04tmp3-executor.sh inventory-plan RUN_ID
       t04tmp3-executor.sh prepare-assets RUN_ID
       t04tmp3-executor.sh read-phase RUN_ID
       t04tmp3-executor.sh write-phase RUN_ID
       t04tmp3-executor.sh cleanup-plan RUN_ID
       t04tmp3-executor.sh cleanup RUN_ID
       t04tmp3-executor.sh bundle RUN_ID
       t04tmp3-executor.sh --self-test
EOF
exit 2; }
valid(){
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "invalid RUN_ID: $RUN_ID"
  [[ $ROOT == "/tmp/production/opencode-04tmp3-$RUN_ID" && $ROOT != / && $ROOT != *..* ]] || die unsafe_ROOT
  [[ $ASSET_ROOT == "$REF/test_dir/04tmp3-$RUN_ID" && $SCRATCH == "$SCRATCH_PARENT/jfs-04tmp3-$RUN_ID" ]] || die unsafe_scope
  [[ ! -L $ROOT && ! -L $ASSET_ROOT && ! -L $SCRATCH ]] || die symlink_scope
  [[ $(readlink -m "$ASSET_ROOT") == "$ASSET_ROOT" && $(readlink -m "$SCRATCH") == "$SCRATCH" ]] || die symlink_escape
}
need(){ command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
record(){ printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }
incident(){ printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >>"$ROOT/incidents.tsv" || true; }
state(){ printf '%s\t%s\tACTIVE\tACTIVE\tACTIVE\tPRESERVED\tNONE\t%s\t/mnt/c/SunRise/test/04-tmp3/%s\tGLM\n' "$(date -Is)" "$RUN_ID" "$*" "$RUN_ID" >>"$ROOT/run-state.tsv"; }
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
 ack PHASE1; valid; [[ ! -e "$ROOT" ]] || die root_exists; for x in ceph curl fio findmnt sha256sum cp timeout; do need "$x"; done
 mkdir -m 0700 -p "$ROOT"/{common,inventory,plans,cells,scrub,closure}; printf 'epoch_iso\trun_id\tvalidity_state\tlifecycle_state\tremote_status\tlocal_status\tincident_status\treason\tevidence_root\tactor\n' >"$ROOT/run-state.tsv"; printf 'epoch\ttype\tdetail\n' >"$ROOT/incidents.tsv"; printf '#!/usr/bin/env bash\n# 04-tmp3 actual command audit\n' >"$ROOT/commands.sh"; printf 'key\tvalue\nevidence_level\tL1_SCREEN\nevidence_root\t/mnt/c/SunRise/test/04-tmp3/%s\nremote_result_root\t%s\nevidence_retention\tSCREEN\nretention_decision\tSCREEN_KEEP_RAW_UNTIL_REVIEW\nremote_cleanup\tAFTER_PERSISTENCE_PASS\nlocal_compaction\tAFTER_REVIEW\nenvironment_asset_cleanup\tindependent exact manifest and ACK\npersistence_status\tPENDING_UNTIL_BUNDLE_COPIED\ncache_flush_scope\tNONE-157-150-152\n' "$RUN_ID" "$ROOT" >"$ROOT/common/contract.tsv"
 hostname -f >"$ROOT/inventory/hostname.txt"; date -Ins >"$ROOT/inventory/time.txt"; uname -a >"$ROOT/inventory/uname.txt"; fio --version >"$ROOT/inventory/fio-version.txt"; "$JFS" --version >"$ROOT/inventory/juicefs-version.txt" 2>&1
 make_private_ceph_conf; [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die jfs_identity; md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"; sha256sum "$JFS" >"$ROOT/inventory/juicefs.sha256"
 ceph_read fsid >"$ROOT/inventory/ceph-fsid.txt"; ceph_read -s --format json >"$ROOT/inventory/ceph-health.json"; ceph_read osd stat --format json >"$ROOT/inventory/osd-stat.json"; ceph_read osd ls >"$ROOT/inventory/osd-ids.txt"; health inventory unpaused
 timeout 30 "$JFS" status "$META" >"$ROOT/inventory/volume-status.json"; uuid >"$ROOT/inventory/volume-uuid.txt"; findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/reference-findmnt.tsv"; mountpoint -q "$REF" || die reference_mount_absent
 findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS >"$ROOT/inventory/residual-mounts.tsv" || :; if awk '$1 ~ /^\/tmp\/jfs-04tmp3-/ {print; bad=1} END{exit bad+0}' "$ROOT/inventory/residual-mounts.tsv"; then :; else die residual_tmp3_mount; fi
	 [[ -d "$SCRATCH_PARENT" && ! -L "$SCRATCH_PARENT" && -w "$SCRATCH_PARENT" && -x "$SCRATCH_PARENT" ]] || die scratch_parent_invalid; [[ $(stat -c %u:%g:%a "$SCRATCH_PARENT") == 1002:1002:700 ]] || die scratch_parent_identity; [[ ! -e "$SCRATCH" && ! -L "$SCRATCH" ]] || die scratch_run_path_exists; findmnt -T "$SCRATCH_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$ROOT/inventory/scratch-mount.tsv"; df -B1 "$SCRATCH_PARENT" >"$ROOT/inventory/scratch-df.txt"; local avail; avail=$(df -B1 --output=avail "$SCRATCH_PARENT"|awk 'NR==2{print $1}'); [[ $avail =~ ^[0-9]+$ && $avail -ge 53687091200 ]] || die "scratch free space below 50GiB: $avail"
 [[ ! -e "$ASSET_ROOT" && ! -L "$ASSET_ROOT" ]] || die asset_run_path_exists
 local fsid state_a state_b; fsid=$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt"); [[ $fsid =~ ^[[:xdigit:]-]+$ ]] || die invalid_fsid
 state_a=$(scrub_run state-path "$RUN_ID-phase-a"); state_b=$(scrub_run state-path "$RUN_ID-phase-b")
 printf 'phase\tlease\tfsid\tstate_file\towned_flags\tsudo_write_budget\nREAD\t%s-phase-a\t%s\t%s\tnoscrub,nodeep-scrub\t4 max\nWRITE\t%s-phase-b\t%s\t%s\tnoscrub,nodeep-scrub\t4 max\n' "$RUN_ID" "$fsid" "$state_a" "$RUN_ID" "$fsid" "$state_b" >"$ROOT/plans/scrub-contract.tsv"; printf 'sudo ceph osd set noscrub\nsudo ceph osd set nodeep-scrub\nsudo ceph osd unset nodeep-scrub\nsudo ceph osd unset noscrub\n' >"$ROOT/plans/sudo-contract.txt"; printf 'read\tA F R R F A\nwrite\tA F W W F A\n' >"$ROOT/plans/matrix.tsv"
 scrub_run plan-pause "$RUN_ID-phase-a" >"$ROOT/plans/read-scrub-plan.txt" 2>&1; scrub_run plan-pause "$RUN_ID-phase-b" >"$ROOT/plans/write-scrub-plan.txt" 2>&1
 sha256sum "$EXECUTOR" "$DRIVER" "$ANALYZER" "$SCRUB" >"$ROOT/plans/runtime-scripts.sha256"; printf 'INVENTORY_PLAN_PASS\n' >"$ROOT/inventory/PASS"; state 'Phase I inventory/plan'; printf 'T04TMP3_INVENTORY_PLAN_PASS\t%s\n' "$ROOT"
}
prepare_assets(){
 ack PREPARE; valid; [[ -d "$ROOT/inventory" && -f "$ROOT/inventory/PASS" ]] || die inventory_required; frozen; require_private_ceph_conf; [[ -d "$REF" && ! -L "$REF" ]] || die reference_mount_invalid; mountpoint -q "$REF" || die reference_mount_absent
 [[ -d "$SCRATCH_PARENT" && ! -L "$SCRATCH_PARENT" ]] || die scratch_parent_invalid; [[ ! -e "$SCRATCH" && ! -L "$SCRATCH" && ! -e "$ASSET_ROOT" && ! -L "$ASSET_ROOT" ]] || die prepare_scope_not_empty
	health PREPARE-pre preparing; foreign_fio PREPARE-pre; mkdir -m 0700 -p "$ROOT/prepare" "$ROOT/cells" "$SCRATCH"
 local source_rc source_alloc; record timeout 300 fio --name=prepare_local_source --filename="$SCRATCH/20Gfile" --rw=write --bs=16M --size=20G --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --output="$ROOT/prepare/local-source.fio.json" --output-format=json
 set +e; timeout 300 fio --name=prepare_local_source --filename="$SCRATCH/20Gfile" --rw=write --bs=16M --size=20G --ioengine=psync --iodepth=1 --direct=1 --end_fsync=1 --allow_file_create=1 --output="$ROOT/prepare/local-source.fio.json" --output-format=json; source_rc=$?; set -e; (( source_rc == 0 )) || die "local source creation failed rc=$source_rc"
 [[ -f "$SCRATCH/20Gfile" && ! -L "$SCRATCH/20Gfile" && $(stat -c %s "$SCRATCH/20Gfile") == 21474836480 ]] || die scratch_source_size; source_alloc=$(( $(stat -c %b "$SCRATCH/20Gfile") * 512 )); (( source_alloc >= 20401094656 )) || die "scratch source is sparse allocated=$source_alloc"
 combined_gc PRE; cooldown PRE NONE; O0=$(pool_objects); printf '%s\n' "$O0" >"$ROOT/inventory/O0.tsv"
 trap on_exit EXIT TERM INT HUP; mount_arm PREP A; local base; base="/tmp/jfs-04tmp3-$RUN_ID-PREP/test_dir/04tmp3-$RUN_ID"; mkdir -m 0700 -p "$base/read" "$base/write"
 prepare_file "$base/read/20Gfile" 20G read-20G
 prepare_file "$base/read/testfile1" 10G read-testfile1
 for p in W01 W02 W03 W04 W05 W06; do mkdir -m 0700 -p "$base/write/$p"; prepare_file "$base/write/$p/testfile1" 10G "write-$p"; done
	: >"$ROOT/prepare/assets-manifest.tsv"
	while IFS= read -r p; do [[ -f $p && ! -L $p ]] || die prepare_asset_missing; printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$(stat -c %s "$p")" "$(head -c 1048576 "$p"|sha256sum|awk '{print $1}')" "$(tail -c 1048576 "$p"|sha256sum|awk '{print $1}')" "SAMPLE" >>"$ROOT/prepare/assets-manifest.tsv"; done < <(asset_paths "$base")
	unmount_arm PREP; trap - EXIT; combined_gc POSTPREP; cooldown POSTPREP NONE; O1=$(pool_objects); printf '%s\n' "$O1" >"$ROOT/inventory/O1.tsv"; (( O1 > O0 )) || die "prepared object anchor did not increase O0=$O0 O1=$O1"; health PREPARE-post preparing; printf 'PREPARE_ASSETS_PASS\n' >"$ROOT/prepare/PASS"; state 'Phase I prepare-assets'; printf 'T04TMP3_PREPARE_ASSETS_PASS\t%s\n' "$ROOT"
}
cleanup_plan(){
	ensure; local out; out="$ROOT/closure/cleanup-manifest.tsv"; printf 'absolute_path\tasset_class\n' >"$out"
	while IFS= read -r p; do [[ -f $p && ! -L $p ]] && printf '%s\tRUN_PREPARED_ASSET\n' "$p" >>"$out"; done < <(asset_paths "$ASSET_ROOT")
 [[ -f "$SCRATCH/20Gfile" ]] && printf '%s\tRUN_LOCAL_SOURCE\n' "$SCRATCH/20Gfile" >>"$out"
 for c in R01 R04 W01 W04; do [[ -f "$SCRATCH/cp-read/$c/20Gfile" ]] && printf '%s\tRUN_CP_OUTPUT\n' "$SCRATCH/cp-read/$c/20Gfile" >>"$out"; [[ -f "$ASSET_ROOT/cp-write/$c/20Gfile" ]] && printf '%s\tRUN_CP_OUTPUT\n' "$ASSET_ROOT/cp-write/$c/20Gfile" >>"$out"; done
 sha256sum "$out" >"$out.sha256"; printf 'CLEANUP_PLAN_PASS\t%s\n' "$out"
}
cleanup(){
 valid; ack CLEANUP; mkdir -m 0700 -p "$ROOT/closure"; [[ -f "$ROOT/commands.sh" ]] || printf '#!/usr/bin/env bash\n' >"$ROOT/commands.sh"; [[ -f "$ROOT/inventory/ceph-fsid.txt" && -f "$ROOT/inventory/volume-uuid.txt" ]] || die cleanup_identity_missing; require_private_ceph_conf; [[ $(ceph_read fsid | tr -d '[:space:]') == "$(tr -d '[:space:]' <"$ROOT/inventory/ceph-fsid.txt")" ]] || die cleanup_fsid_drift; [[ $(uuid) == "$(<"$ROOT/inventory/volume-uuid.txt")" ]] || die cleanup_uuid_drift; if [[ -f "$ROOT/inventory/O0.tsv" ]]; then O0=$(<"$ROOT/inventory/O0.tsv"); else O0=; fi
 local mnt cell out lease sf
 for lease in "$RUN_ID-phase-a" "$RUN_ID-phase-b"; do sf=$(scrub_run state-path "$lease"); if [[ -f $sf ]]; then restore_lease "$lease" || die "cleanup scrub restore failed: $lease"; fi; done
 health CLEANUP-pre unpaused
	for cell in PREP R01 R02 R03 R04 R05 R06 W01 W02 W03 W04 W05 W06; do mnt="/tmp/jfs-04tmp3-$RUN_ID-$cell"; if mountpoint -q "$mnt"; then unmount_arm "$cell"; elif [[ -e $mnt ]]; then [[ -d $mnt && ! -L $mnt && -z $(find "$mnt" -mindepth 1 -maxdepth 1 -print -quit) ]] || die "unsafe residual mount directory: $mnt"; rmdir "$mnt"; fi; done
	mountpoint -q "$REF" || die cleanup_reference_mount_absent
	[[ $(findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS) == "$(<"$ROOT/inventory/reference-findmnt.tsv")" ]] || die cleanup_reference_mount_identity_drift
	out="$ROOT/closure/cleanup-manifest.tsv"; if [[ ! -f "$out" ]]; then printf 'absolute_path\tasset_class\n' >"$out"; while IFS= read -r p; do [[ -f $p && ! -L $p ]] && printf '%s\tRUN_PREPARED_ASSET\n' "$p" >>"$out"; done < <(asset_paths "$ASSET_ROOT"); [[ -f "$SCRATCH/20Gfile" ]] && printf '%s\tRUN_LOCAL_SOURCE\n' "$SCRATCH/20Gfile" >>"$out"; for cell in R01 R04 W01 W04; do [[ -f "$SCRATCH/cp-read/$cell/20Gfile" ]] && printf '%s\tRUN_CP_OUTPUT\n' "$SCRATCH/cp-read/$cell/20Gfile" >>"$out"; [[ -f "$ASSET_ROOT/cp-write/$cell/20Gfile" ]] && printf '%s\tRUN_CP_OUTPUT\n' "$ASSET_ROOT/cp-write/$cell/20Gfile" >>"$out"; done; sha256sum "$out" >"$out.sha256"; fi
 [[ -f "$out.sha256" ]] && sha256sum -c "$out.sha256" >/dev/null
 python3 - "$ROOT/closure/cleanup-manifest.tsv" "$RUN_ID" <<'PY'
import os,sys
run=sys.argv[2]
for row in open(sys.argv[1]).read().splitlines()[1:]:
 if not row: continue
 p=row.split("\t")[0]
 if not (p.startswith("/mnt/jfs-cache/04tmp3/jfs-04tmp3-") or p.startswith("/mnt/juicefs/test_dir/04tmp3-")) or os.path.islink(p): raise SystemExit("unsafe cleanup target: "+p)
 if not (p.startswith("/mnt/jfs-cache/04tmp3/jfs-04tmp3-"+run+"/") or p.startswith("/mnt/juicefs/test_dir/04tmp3-"+run+"/")): raise SystemExit("cleanup target run mismatch: "+p)
 if os.path.exists(p):
  if os.path.realpath(p)!=p: raise SystemExit("cleanup symlink escape: "+p)
  if not os.path.isfile(p): raise SystemExit("non-regular cleanup target: "+p)
  os.unlink(p)
PY
	if [[ $O0 =~ ^[0-9]+$ ]]; then combined_gc CLEANUP; cooldown CLEANUP "$O0"; elif [[ -e $ASSET_ROOT ]]; then die cleanup_O0_missing_with_remote_assets; fi
 for cell in W01 W02 W03 W04 W05 W06; do rmdir "$ASSET_ROOT/write/$cell" 2>/dev/null || :; done
 for cell in W01 W04; do rmdir "$ASSET_ROOT/cp-write/$cell" 2>/dev/null || :; done
 rmdir "$ASSET_ROOT/cp-write" 2>/dev/null || :; rmdir "$ASSET_ROOT/write" "$ASSET_ROOT/read" "$ASSET_ROOT" 2>/dev/null || :
 for cell in R01 R04; do rmdir "$SCRATCH/cp-read/$cell" 2>/dev/null || :; done
 rmdir "$SCRATCH/cp-read" "$SCRATCH" 2>/dev/null || :
 [[ ! -e $ASSET_ROOT && ! -e $SCRATCH ]] || die cleanup_run_paths_remain
 if findmnt -rn -o TARGET | awk '$1 ~ /^\/tmp\/jfs-04tmp3-/ {bad=1} END{exit bad+0}'; then :; else die cleanup_mount_remains; fi
 health CLEANUP-post unpaused; printf 'CLEANUP_PASS\n' >"$ROOT/closure/CLEANUP_PASS"; [[ -f "$ROOT/run-state.tsv" ]] && state CLEANUP_PASS
}
bundle(){
 ensure; [[ -f "$ROOT/closure/CLEANUP_PASS" ]] || die cleanup_required; local a; a="/tmp/production/04tmp3-$RUN_ID-evidence.tar"; [[ ! -e $a && ! -L $a ]] || die bundle_exists
 (cd "$ROOT" && find . -type f ! -name 'manifest.sha256' -print0 | sort -z | xargs -0 sha256sum) >"$ROOT/closure/manifest.sha256"; tar -C /tmp/production -cf "$a" "opencode-04tmp3-$RUN_ID"; sha256sum "$a" >"$a.sha256"; printf 'source\tsha256\ttarget\n%s\t%s\t/mnt/c/SunRise/test/04-tmp3/%s/\n' "$a" "$(awk '{print $1}' "$a.sha256")" "$RUN_ID" >"$ROOT/closure/copy-to-mnt-c.tsv"; printf 'BUNDLE_PASS\t%s\n' "$a"
}
 self_test(){
 local t
 t=$(mktemp -d /tmp/t04tmp3-executor-selftest.XXXXXX)
 RUN_ID=20260903-000000
 ROOT="/tmp/production/opencode-04tmp3-$RUN_ID"
 ASSET_ROOT="/mnt/juicefs/test_dir/04tmp3-$RUN_ID"
 SCRATCH="/mnt/jfs-cache/04tmp3/jfs-04tmp3-$RUN_ID"
 T04TMP3_ACK="I_ACK_04TMP3_PREPARE_$RUN_ID"; ack PREPARE; if (T04TMP3_ACK=bad ack PREPARE) 2>/dev/null; then die selftest_ack_not_strict; fi; [[ "$RUN_ID-phase-a" =~ ^[0-9]{8}-[0-9]{6}-phase-a$ && "$RUN_ID-phase-b" =~ ^[0-9]{8}-[0-9]{6}-phase-b$ ]] || die selftest_lease_shape
 [[ $ROOT != / && $ROOT != *..* && $ASSET_ROOT == /mnt/juicefs/test_dir/04tmp3-* ]] || die selftest_scope; printf 'read\tA F R R F A\nwrite\tA F W W F A\n' >"$t/matrix"; [[ $(wc -l <"$t/matrix") == 2 ]] || die selftest_matrix; python3 - "$t/matrix" <<'PY'
import os,sys
os.unlink(sys.argv[1])
PY
 rmdir "$t"; printf 'T04TMP3_EXECUTOR_SELFTEST_PASS\n'
}
ack(){
  local k expected; k="$1"; expected="I_ACK_04TMP3_${k}_${RUN_ID}"
  [[ "${T04TMP3_ACK:-}" == "$expected" ]] || die "required exact ACK: $expected"
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
 [[ $path == /tmp/jfs-04tmp3-"$RUN_ID"-PREP/test_dir/04tmp3-"$RUN_ID"/* && ! -e $path && ! -L $path ]] || die "unsafe/existing prepare target: $path"
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
	local base cell
	base="$1"
	printf '%s\n' "$base/read/20Gfile" "$base/read/testfile1"
	for cell in W01 W02 W03 W04 W05 W06; do printf '%s\n' "$base/write/$cell/testfile1"; done
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
if any(not isinstance(o.get(k),int) for k in ("num_osds","num_up_osds","num_in_osds")) or len({o[k] for k in ("num_osds","num_up_osds","num_in_osds")})!=1: raise SystemExit("OSDs not all up/in")
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
 local base out cell p rel; base="$1"; out="$2"; cell="${3:-}"; printf 'relative_path\tinode\tbytes\tmtime\thead_sha256\ttail_sha256\n' >"$out"
 for rel in read/20Gfile read/testfile1; do p="$base/$rel"; [[ -f $p && ! -L $p ]] || die "missing asset: $p"; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$(stat -c %i "$p")" "$(stat -c %s "$p")" "$(stat -c %Y "$p")" "$(head -c 1048576 "$p"|sha256sum|awk '{print $1}')" "$(tail -c 1048576 "$p"|sha256sum|awk '{print $1}')" >>"$out"; done
 if [[ -n $cell ]]; then p="$base/write/$cell/testfile1"; [[ -f $p && ! -L $p ]] || die "missing write asset: $p"; printf 'write/%s/testfile1\t%s\t%s\t%s\t%s\t%s\n' "$cell" "$(stat -c %i "$p")" "$(stat -c %s "$p")" "$(stat -c %Y "$p")" "$(head -c 1048576 "$p"|sha256sum|awk '{print $1}')" "$(tail -c 1048576 "$p"|sha256sum|awk '{print $1}')" >>"$out"; fi
 }

mount_arm(){
 local cell arm out mnt log; cell="$1"; arm="$2"; out="$ROOT/cells/$cell"; mnt="/tmp/jfs-04tmp3-$RUN_ID-$cell"; [[ ! -e $mnt && ! -L $mnt ]] || die mount_exists; mkdir -m 0700 "$mnt"; mkdir -m 0700 -p "$out/bwlog"; log="$out/juicefs-mount.log"; local -a cmd; cmd=("$JFS" mount -d --max-uploads 150 --cache-size 0)
 require_private_ceph_conf
 case "$arm" in A) cmd+=(--max-fuse-io 256K);; F) cmd+=(--max-fuse-io 1M);; R) cmd+=(--max-fuse-io 1M --max-readahead 8M);; W) cmd+=(--max-fuse-io 1M --buffer-size 1024);; *) die bad_arm;; esac
	cmd+=(--log "$log" "$META" "$mnt"); record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"; local -a envcmd; envcmd=(env "CEPH_CONF=$CEPH_CONF"); if ! timeout 180 "${envcmd[@]}" "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr"; then mountpoint -q "$mnt" && ACTIVE_MNT="$mnt"; die "mount failed: $cell"; fi
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
}
verify_arm(){
 local cell out mnt worker start actual threads
 cell="$1"; out="$ROOT/cells/$cell"; mnt="/tmp/jfs-04tmp3-$RUN_ID-$cell"
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
 local cell out mnt; cell="$1"; out="$ROOT/cells/$cell"; mnt="/tmp/jfs-04tmp3-$RUN_ID-$cell"; verify_arm "$cell"; record timeout 180 env "CEPH_CONF=$CEPH_CONF" "$JFS" umount "$mnt"; timeout 180 env CEPH_CONF="$CEPH_CONF" "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr" || die graceful_unmount_failed
 for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done; mountpoint -q "$mnt" && die mount_remains; for _ in $(seq 1 60); do arm_processes_gone "$cell" && break; sleep 1; done; arm_processes_gone "$cell" || die "mount processes remain: $cell"; [[ -d $mnt && ! -L $mnt && -z $(find "$mnt" -mindepth 1 -maxdepth 1 -print -quit) ]] || die mount_dir_not_empty; rmdir "$mnt"; ACTIVE_MNT=
}
fio_cell(){
 local cell work file runtime bs out prefix rw; cell="$1"; work="$2"; file="$3"; runtime="$4"; bs="$5"; out="$ROOT/cells/$cell"; prefix="$out/bwlog/$cell"; rw=read; [[ $work == seq_write ]] && rw=write; local -a cmd; cmd=(fio --name="$work" --filename="$file" --size=10G --bs="$bs" --rw="$rw" --direct=1 --numjobs=1 --allow_file_create=0 --runtime="$runtime" --time_based --group_reporting --write_bw_log="$prefix" --log_avg_msec=1000 --output="$out/fio.txt" --output-format=json+)
 local rc; record "${cmd[@]}"; set +e; timeout $((runtime+120)) "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; set -e; printf '%s\n' "$rc" >"$out/fio.rc"; date +%s%N >"$out/fio-end-ns.txt"; ((rc==0)) || die "fio failed cell=$cell rc=$rc"; [[ $(find "$out/bwlog" -maxdepth 1 -type f -name '*_bw.*.log'|wc -l) -eq 1 ]] || die "per-job log count failed: $cell"; python3 "$ANALYZER" cell "$out" "$work" --expected-file "$file" >"$out/analysis.json" || die "analyzer failed: $cell"
}
cp_read(){
 local cell base out dst parent inode; cell="$1"; base="$2"; out="$ROOT/cells/$cell"; dst="$SCRATCH/cp-read/$cell/20Gfile"; [[ ! -e $dst && ! -L $dst ]] || die cp_read_exists; parent=$(dirname "$dst"); [[ $(readlink -m "$parent") == "$parent" ]] || die cp_read_scope; mkdir -m 0700 -p "$parent"; record /usr/bin/time -v cp "$base/read/20Gfile" "$dst"; /usr/bin/time -v cp "$base/read/20Gfile" "$dst" >"$out/cp-read.stdout" 2>"$out/cp-read.time"; [[ $(stat -c %s "$dst") == 21474836480 ]] || die cp_read_size; inode=$(stat -c %i "$dst"); printf 'path\tbytes\tinode\n%s\t21474836480\t%s\n' "$dst" "$inode" >"$out/cp-read-output.tsv"; record unlink -- "$dst"; unlink -- "$dst"; rmdir "$parent"; rmdir "$SCRATCH/cp-read" 2>/dev/null || :
}
cp_write(){
 local cell base out dst parent inode; cell="$1"; base="$2"; out="$ROOT/cells/$cell"; dst="$base/cp-write/$cell/20Gfile"; [[ ! -e $dst && ! -L $dst ]] || die cp_write_exists; parent=$(dirname "$dst"); [[ $(readlink -m "$parent") == "$parent" ]] || die cp_write_scope; mkdir -m 0700 -p "$parent"; record /usr/bin/time -v cp "$SCRATCH/20Gfile" "$dst"; /usr/bin/time -v cp "$SCRATCH/20Gfile" "$dst" >"$out/cp-write.stdout" 2>"$out/cp-write.time"; [[ $(stat -c %s "$dst") == 21474836480 ]] || die cp_write_size; inode=$(stat -c %i "$dst"); printf 'path\tbytes\tinode\n%s\t21474836480\t%s\n' "$dst" "$inode" >"$out/cp-write-output.tsv"; record unlink -- "$dst"; unlink -- "$dst"; rmdir "$parent"; rmdir "$base/cp-write" 2>/dev/null || :
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
 local cell arm work out c before base file; cell="$1"; arm="$2"; work="$3"; out="$ROOT/cells/$cell"; [[ ! -e $out ]] || die cell_exists; mkdir -m 0700 -p "$out"; [[ $work == seq_write ]] && mkdir -m 0700 -p "$out/recovery"; frozen; health "$cell-pre" paused; foreign_fio "$cell-pre"; c=""; before=NONE; [[ $work == seq_write ]] && c="$cell"; [[ $work == seq_write ]] && before=$(pool_objects); printf 'objects_pre\t%s\n' "$before" >"$out/contract.tsv"
 mount_arm "$cell" "$arm"; base="/tmp/jfs-04tmp3-$RUN_ID-$cell/test_dir/04tmp3-$RUN_ID"; file="$base/read/testfile1"; [[ $work == seq_write ]] && file="$base/write/$cell/testfile1"; asset_snapshot "$base" "$out/assets-pre.tsv" "$c"; fio_cell "$cell" "$work" "$file" "$([[ $work == seq_read ]] && echo 60 || echo 120)" "$([[ $work == seq_read ]] && echo 20M || echo 16M)"
 [[ $cell == R01 || $cell == R04 ]] && cp_read "$cell" "$base"; [[ $cell == W01 || $cell == W04 ]] && cp_write "$cell" "$base"; asset_snapshot "$base" "$out/assets-post.tsv" "$c"; cmp -s <(sed -n '1,3p' "$out/assets-pre.tsv") <(sed -n '1,3p' "$out/assets-post.tsv") || die "read asset drift: $cell"; unmount_arm "$cell"
 if [[ $work == seq_write ]]; then local peak after low high; peak=$(pool_objects); printf 'objects_peak\t%s\n' "$peak" >>"$out/contract.tsv"; combined_gc "$cell"; cooldown "$cell" "$O1"; after=$(pool_objects); low=$((O1-8192)); (( low < 0 )) && low=0; high=$((O1+8192)); (( after >= low && after <= high )) || die "objects anchor drift O1=$O1 post=$after"; printf 'objects_post_gc\t%s\n' "$after" >>"$out/contract.tsv"; fi
 printf 'CELL_PASS\t%s\n' "$cell" >"$out/PASS"
}
restore_lease(){
 local lease sf rc; lease="$1"; sf=$(scrub_run state-path "$lease") || return 1; [[ -f $sf ]] || return 0; set +e; scrub_run restore "$lease" >"$ROOT/scrub/$lease-restore.log" 2>&1; rc=$?; set -e
 ((rc==0)) || { incident SCRUB_RESTORE_FAILED "lease=$lease rc=$rc"; return "$rc"; }; scrub_run verify-restored "$lease" >>"$ROOT/scrub/$lease-restore.log" 2>&1 || { incident SCRUB_RESTORE_VERIFY_FAILED "lease=$lease"; return 1; }; ACTIVE_LEASE=; state "RESTORED lease=$lease"
}
on_exit(){ local rc cell; rc=$?; trap - EXIT TERM INT HUP; set +e; if [[ -n "${ACTIVE_LEASE:-}" ]]; then restore_lease "$ACTIVE_LEASE" || rc=97; fi; if [[ -n "${ACTIVE_MNT:-}" ]]; then cell="${ACTIVE_MNT##*-}"; unmount_arm "$cell" || rc=98; fi; exit "$rc"; }
run_phase(){
 local kind lease fsid c a start end; kind="$1"; if [[ $kind == READ ]]; then lease="$RUN_ID-phase-a"; else lease="$RUN_ID-phase-b"; fi; ack "$kind"; ensure; frozen; health "$kind-pre" unpaused; foreign_fio "$kind-pre"; fsid=$(<"$ROOT/inventory/ceph-fsid.txt"); start=$(pool_objects); assert_anchor "$start" "$O1" "$kind-start"; printf '%s\n' "$start" >"$ROOT/$kind-objects-start.tsv"
 record env "CEPH_CONF=$CEPH_CONF" "U141D_SCRUB_STATE_DIR=$STATE_DIR" "$SCRUB" pause "$lease" "$fsid" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE; ACTIVE_LEASE="$lease"; trap on_exit EXIT TERM INT HUP; scrub_run pause "$lease" "$fsid" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$ROOT/scrub/$lease-pause.log" 2>&1; scrub_run verify-paused "$lease" >>"$ROOT/scrub/$lease-pause.log" 2>&1; health "$kind-paused" paused
 if [[ $kind == READ ]]; then
  for c in R01 R02 R03 R04 R05 R06; do case $c in R01|R06) a=A;; R02|R05) a=F;; *) a=R;; esac; run_cell "$c" "$a" seq_read; done
 else
  [[ -f "$ROOT/READ_PHASE_PASS" ]] || die read_phase_required
  for c in W01 W02 W03 W04 W05 W06; do case $c in W01|W06) a=A;; W02|W05) a=F;; *) a=W;; esac; run_cell "$c" "$a" seq_write; done
 fi
 restore_lease "$lease"; health "$kind-restored" unpaused; end=$(pool_objects); assert_anchor "$end" "$O1" "$kind-end"; printf '%s\n' "$end" >"$ROOT/$kind-objects-end.tsv"; printf '%s_PHASE_PASS\n' "$kind" >"$ROOT/${kind}_PHASE_PASS"; state "${kind}_PHASE_PASS"
}
if [[ "$MODE" == --self-test ]]; then self_test; exit 0; fi
case "$MODE" in
 prepare-assets) [[ $# -eq 2 ]] || usage; valid; prepare_assets ;;
 inventory-plan) [[ $# -eq 2 ]] || usage; valid; inventory ;;
 read-phase) [[ $# -eq 2 ]] || usage; valid; run_phase READ ;;
 write-phase) [[ $# -eq 2 ]] || usage; valid; run_phase WRITE ;;
 cleanup-plan) [[ $# -eq 2 ]] || usage; valid; cleanup_plan ;;
 cleanup) [[ $# -eq 2 ]] || usage; valid; cleanup ;;
 bundle) [[ $# -eq 2 ]] || usage; valid; bundle ;;
 *) usage ;;
esac
