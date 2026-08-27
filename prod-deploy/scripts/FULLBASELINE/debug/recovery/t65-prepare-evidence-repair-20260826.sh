#!/usr/bin/env bash
# One-shot evidence adjudication for the SEED-CANARY prepare attempt whose
# old reset script used an incorrect absolute-zero NVMe gate.  This script
# never reruns compaction/GC, touches a mount, or changes cluster/storage state.
set -euo pipefail
export LC_ALL=C

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}

EXPECTED_RUN=20260826-164047
EXPECTED_CLUSTER=A1
EXPECTED_INSTANCE=SEED-CANARY
COMMON=/tmp/t65-scripts/t65-common.sh
COMMON_SHA=97e3b84d60415b47a12ed3e590db841058f01d4d0660a4ac8961d9439be60355
ACTIVE_MANIFEST_SHA=1b94a139821355070740e4a19dcfc77e683b89fc9daa49a23d4f1f51659cfaa3
VOLUME_SHA=9d819696f91f64b6592716288754c976a27fa79fabe1c25f8e968587f8f0cc01
LAYOUT_SHA=dbad7d5f30047e00569094fbaed26384e53a73cf356794da2bfabcb2ccd132b3
LAYOUT_MANIFEST_SHA=9bd56fe7b0ca244548aaf8ad75386fab2406025e5adb4063a5a6663472a68800
ANCHORS_SHA=8f32365849050fde11a89dbbbecd0895543a4b0d657797d86cfcc3cc67ee6a03
SOURCE_ANCHOR=c314e532e3c416a5ab66666e88faa15b11e2b9db6a2a72a9954291c27ba3e6dd

die() { printf 'E_T65_REPAIR\t%s\n' "$*" >&2; exit 42; }
sha() { sha256sum -- "$1" | awk '{print $1}'; }

if [[ "$ACTION" == --offline-self-test ]]; then
  [[ "$EXPECTED_RUN" =~ ^[0-9]{8}-[0-9]{6}$ ]]
  [[ "$EXPECTED_CLUSTER" == A1 && "$EXPECTED_INSTANCE" == SEED-CANARY ]]
  printf 'OFFLINE_SELF_TEST_PASS\n'
  exit 0
fi

[[ "$ACTION" == inspect || "$ACTION" == recover ]] || die 'usage: inspect|recover RUN_ID A1 SEED-CANARY'
[[ "$RUN_ID" == "$EXPECTED_RUN" && "$CLUSTER" == "$EXPECTED_CLUSTER" && "$INSTANCE" == "$EXPECTED_INSTANCE" ]] ||
  die 'this one-shot repair is scoped only to the frozen SEED-CANARY attempt'
[[ -f "$COMMON" && $(sha "$COMMON") == "$COMMON_SHA" ]] || die 'active common script identity mismatch'
[[ -f /tmp/t65-scripts/t65-manifest.sha256 && $(sha /tmp/t65-scripts/t65-manifest.sha256) == "$ACTIVE_MANIFEST_SHA" ]] ||
  die 'active bundle manifest identity mismatch; hot-resync is forbidden'
# shellcheck source=/dev/null
source "$COMMON"

ROOT="/tmp/production/opencode-t3.22b-${RUN_ID}"
OUT="$ROOT/instances/$INSTANCE"
RESET="$OUT/reset-prepare"
REPAIR="$OUT/prepare-evidence-repair"
MNT="/tmp/jfs-t65-${RUN_ID}-mnt-${INSTANCE}"
SOURCE="$MNT/seed_layout/canary.bin"
STATE="$OUT/volume.tsv"
LEDGER="/tmp/jfs-t65-${RUN_ID}-authorization-ledger.tsv"
export CEPH_CONF="$OUT/ceph-t65.conf"

[[ -d "$RESET" && $(find "$RESET" -maxdepth 1 -type f | wc -l) -eq 21 ]] || die 'frozen reset evidence set is not the expected 21 files'
[[ ! -e "$OUT/READY_FOR_FIO" && ! -e "$RESET/pool-ready.tsv" && ! -e "$OUT/PREPARE_PASS" ]] ||
  die 'a prepare success marker already exists'
[[ ! -e "$REPAIR" ]] || die 'repair output already exists; preserve first attempt'
[[ $(sha "$STATE") == "$VOLUME_SHA" && $(sha "$OUT/LAYOUT_PASS") == "$LAYOUT_SHA" ]] || die 'volume or layout identity changed'
[[ $(sha "$OUT/seed-layout-relative.tsv") == "$LAYOUT_MANIFEST_SHA" ]] || die 'layout manifest changed'
[[ $(sha "$OUT/seed-content-anchors.tsv") == "$ANCHORS_SHA" ]] || die 'content anchors changed'

mountpoint -q "$MNT" || die 'seed mount is not active'
pid=$(awk -F '\t' '$1=="pid"{print $2}' "$STATE")
start=$(awk -F '\t' '$1=="starttime"{print $2}' "$STATE")
[[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" && $(awk '{print $22}' "/proc/$pid/stat") == "$start" ]] || die 'mount worker identity changed'
read -r inode size mtime < <(stat -Lc '%i %s %Y' "$SOURCE")
[[ "$inode" == 3 && "$size" == 33554432 && "$mtime" == 1787799995 ]] || die 'source file identity changed'
actual_anchor=$(dd if="$SOURCE" bs=262144 count=1 status=none | sha256sum | awk '{print $1}')
[[ "$actual_anchor" == "$SOURCE_ANCHOR" ]] || die 'source content anchor changed'

[[ $(sha "$RESET/osd-cooldown.tsv") == 13c671842bb1e7d64ab32003f498d12a67390c9b79025cc1d618ff7f9971028a ]] || die 'OSD cooldown evidence changed'
[[ $(sha "$RESET/juicefs-gc.log") == 918c0dc4fca631483c41ad1f74b87813bc19d1b6a8687028d1ea0840af1ddbca ]] || die 'GC evidence changed'
[[ $(sha "$RESET/tikv-pending.tsv") == 4dfb881bcce25a017bd7bcffbc03579ccec585417e2850164d381f081931486f ]] || die 'TiKV pending evidence changed'
[[ $(sha "$RESET/pool-before.tsv") == 15d3b0eb80dbc6d724c9e72009cdce8054e6b52f56dfe52b47eaa66eb5aad62f ]] || die 'pool-before evidence changed'
[[ $(sha "$RESET/osd-ids.txt") == 9d6093db34ed3db1834973eb10698ddb099971d39ac0e4707485d5f5aa5b0595 ]] || die 'OSD identity evidence changed'
awk -F '\t' '
  {n++; labels[$2]++; osds[$2 SUBSEP $3]++; if($4!=0||$5!=0||$6<0||$6>=0.002)bad=1}
  END{if(n!=12||labels["pre-gc"]!=6||labels["post-gc"]!=6)bad=1; for(k in osds)if(osds[k]!=1)bad=1; exit bad}' \
  "$RESET/osd-cooldown.tsv" || die 'OSD cooldown contract failed'
awk -F '\t' '
  {n++; nodes[$2]++; if($3!=0)bad=1}
  END{if(n!=9||nodes["10.20.1.150"]!=3||nodes["10.20.1.151"]!=3||nodes["10.20.1.152"]!=3)bad=1; exit bad}' \
  "$RESET/tikv-pending.tsv" || die 'TiKV pending contract failed'

declare -A RAW_SHA=(
  [10.20.1.150]=a37ae75ba330dead9e453918dc66e3e6529094bbcae360c3973a214d5471a542
  [10.20.1.151]=86cb8ea18dd2f7684157970533395e20802a1adfe22259d8c52181aa9d88e2c3
  [10.20.1.152]=f0ece41c7f578d30c35a8ecbc09fd8e3a0f906fb53de1bbfe93617958322b8c4
)
declare -a QUIET=()
for node in 10.20.1.150 10.20.1.151 10.20.1.152; do
  evidence="$RESET/nvme-${node}.tsv"
  [[ $(sha "$evidence") == "${RAW_SHA[$node]}" ]] || die "NVMe raw evidence changed: $node"
  summary=$(t65_nvme_quiet_evidence_ok "$evidence") || die "bounded NVMe parser rejected frozen evidence: $node"
  QUIET+=("$node"$'\t'"$summary")
done

[[ $(awk -F '\t' '$3=="reset-prepare-SEED-CANARY" && $4=="03-22b-reset-20260826-164047-SEED-CANARY-A1"{n++} END{print n+0}' "$LEDGER") == 1 ]] ||
  die 'authorization ledger does not contain exactly one original prepare attempt'
[[ $(sudo ceph health) == HEALTH_OK ]] || die 'Ceph is not HEALTH_OK'
for node in 10.20.1.150 10.20.1.151 10.20.1.152; do
  curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:30160/config" >/dev/null || die "temporary TiKV unavailable: $node"
done

printf 'PREPARE_REPAIR_INSPECT_PASS run=%s instance=%s cluster=%s\n' "$RUN_ID" "$INSTANCE" "$CLUSTER"
printf '%s\n' "${QUIET[@]}"
printf 'PLAN\twrite only %s evidence files, pool-ready.tsv, PREPARE_EVIDENCE_REPAIR_PASS and READY_FOR_FIO\n' "$REPAIR"
printf 'PLAN\tno compact, GC, fio, mount, umount, cluster, loop, backing-file or production-service action\n'
[[ "$ACTION" == inspect ]] && exit 0

EXPECTED_AUTH="03-22b-prepare-evidence-repair-${RUN_ID}-${INSTANCE}-${CLUSTER}"
[[ ${T65_PREPARE_REPAIR_AUTH:-} == "$EXPECTED_AUTH" ]] || die "set exact T65_PREPARE_REPAIR_AUTH=$EXPECTED_AUTH"
t65_record_authorization "$RUN_ID" prepare-evidence-repair "$T65_PREPARE_REPAIR_AUTH"
umask 077
mkdir "$REPAIR"
printf '%s\n' "${QUIET[@]}" > "$REPAIR/nvme-bounded-recalc.tsv"
(cd "$RESET" && find . -maxdepth 1 -type f -printf '%P\0' | sort -z | xargs -0 sha256sum --) > "$REPAIR/reset-prepare.sha256"
printf 'run\t%s\ncluster\t%s\ninstance\t%s\nactive_manifest_sha\t%s\ncommon_sha\t%s\nvolume_sha\t%s\nlayout_sha\t%s\nlayout_manifest_sha\t%s\nanchors_sha\t%s\nsource_inode\t%s\nsource_size\t%s\nsource_mtime\t%s\nsource_anchor\t%s\nceph_health\tHEALTH_OK\n' \
  "$RUN_ID" "$CLUSTER" "$INSTANCE" "$ACTIVE_MANIFEST_SHA" "$COMMON_SHA" "$VOLUME_SHA" "$LAYOUT_SHA" \
  "$LAYOUT_MANIFEST_SHA" "$ANCHORS_SHA" "$inode" "$size" "$mtime" "$actual_anchor" > "$REPAIR/contract.tsv"
sudo ceph df --format=json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=next((x for x in d["pools"] if x["name"]=="juicefs-data"),None)
assert p is not None
s=p["stats"]; print("%s\t%s\t%s"%(s["objects"],s["stored"],s["bytes_used"]))' > "$RESET/pool-ready.tsv"
(cd "$REPAIR" && sha256sum contract.tsv nvme-bounded-recalc.tsv reset-prepare.sha256) > "$REPAIR/repair-evidence.sha256"
printf '%s\tbounded-idle-contract\told-reset-absolute-zero-implementation-defect\n' "$(date +%s)" > "$OUT/PREPARE_EVIDENCE_REPAIR_PASS"
printf '%s\n' "$(date +%s)" > "$OUT/READY_FOR_FIO"
printf 'PREPARE_EVIDENCE_REPAIR_PASS instance=%s\n' "$INSTANCE"
