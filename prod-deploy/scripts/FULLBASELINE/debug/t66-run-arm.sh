#!/usr/bin/env bash
# Run exactly one 03-22c B256 arm. It never creates/destroys a cluster, device, or volume.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

RUN_ID=${1:-}
CLUSTER=${2:-}
INSTANCE=${3:-}
t66_check_run_id "$RUN_ID"
t66_check_cluster "$CLUSTER"
t66_check_instance "$INSTANCE"
IS_CANARY=0
if [[ "$INSTANCE" == ARM-CANARY-B1c || "$INSTANCE" == ARM-CANARY-D1 ]]; then
  IS_CANARY=1
  [[ $(t66_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || t66_die 'arm canary arm mapping mismatch'
  [[ -z ${T66_FIO_AUTH:-} ]] || t66_die 'formal T66_FIO_AUTH is forbidden for arm canary'
  [[ ${T66_ARM_CANARY_AUTH:-} == "03-22c-arm-canary-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t66_die "set exact T66_ARM_CANARY_AUTH=03-22c-arm-canary-${RUN_ID}-${INSTANCE}-${CLUSTER}"
else
  [[ "$INSTANCE" =~ ^R0[1-8]$ ]] || t66_die 'formal arm requires R01..R08'
  [[ -z ${T66_ARM_CANARY_AUTH:-} ]] || t66_die 'canary authorization is forbidden for formal arm'
  [[ ${T66_FIO_AUTH:-} == "03-22c-fio-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t66_die "set exact T66_FIO_AUTH=03-22c-fio-${RUN_ID}-${INSTANCE}-${CLUSTER}"
fi
t66_make_ssh_array
t66_require_tools fio setsid sshpass ssh scp python3 curl sha256sum

OUT="/tmp/production/opencode-t3.22c-${RUN_ID}/instances/${INSTANCE}"
if (( IS_CANARY == 1 )); then t66_record_authorization "$RUN_ID" "fio-canary-$INSTANCE" "$T66_ARM_CANARY_AUTH"; else t66_record_authorization "$RUN_ID" "fio-formal-$INSTANCE" "$T66_FIO_AUTH"; fi
ARM="$OUT/arm"
MNT="/tmp/jfs-t66-${RUN_ID}-mnt-${INSTANCE}"
TEST_DIR="$MNT/test_dir"
REMOTE_DIR="/tmp/jfs-t66-${RUN_ID}-scripts"
[[ -s "$OUT/READY_FOR_FIO" && -s "$OUT/LAYOUT_PASS" && -s "$OUT/volume.tsv" ]] || t66_die 'prepare/layout/volume gate missing'
if (( IS_CANARY == 0 )); then
  [[ -s "$OUT/CLONE_PASS" && $(awk -F '\t' '$1=="state_origin"{print $2}' "$OUT/volume.tsv") == restored-seed ]] ||
    t66_die 'formal arm requires a restored-seed clone state'
fi
[[ ! -e "$ARM" ]] || t66_die "arm directory already exists: $ARM"
mountpoint -q "$MNT" || t66_die 'test mount missing'
! pgrep -x fio >/dev/null || t66_die 'foreign fio exists on client'
ready_epoch=$(<"$OUT/READY_FOR_FIO"); [[ "$ready_epoch" =~ ^[0-9]+$ ]] || t66_die 'invalid READY_FOR_FIO epoch'
(( $(date +%s)-ready_epoch <= 600 )) || t66_die 'READY_FOR_FIO is older than 600s; rerun the authorized prepare gate'
[[ $(sudo ceph health) == HEALTH_OK ]] || t66_die 'Ceph is not HEALTH_OK immediately before arm'
for node in "${T66_NODES[@]}"; do
  [[ $("${T66_SSH[@]}" "$node" 'systemctl is-active tikv 2>/dev/null || true') != active ]] || t66_die "production tikv active before fio: $node"
done
curl -fsS --connect-timeout 3 --max-time 10 "http://10.20.1.150:${T66_PD_CLIENT_PORT}/pd/api/v1/stores" | python3 -c '
import json,sys
s=json.load(sys.stdin).get("stores",[])
assert len(s)==3 and all(x.get("store",{}).get("state_name")=="Up" for x in s)' || t66_die 'temporary stores are not all Up immediately before arm'
mkdir -p "$ARM/bw" "$OUT/samplers"
if (( IS_CANARY == 1 )); then
  printf 'NONFORMAL_ARM_CANARY\n' > "$OUT/NONFORMAL_CANARY"
fi

[[ $(t66_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || t66_die 'frozen ABBA/BAAB order mismatch'

if (( IS_CANARY == 0 )) && [[ "$CLUSTER" == D1 ]]; then
  CONTRACT="/tmp/production/opencode-t3.22c-${RUN_ID}/preflight/d1-logs-canary.tsv"
  [[ -s "$CONTRACT" ]] || t66_die 'D1 formal arm requires frozen D1 logs canary contract'
  peak=$(awk -F '\t' '$1=="peak_growth_bytes"{print $2}' "$CONTRACT")
  [[ "$peak" =~ ^[0-9]+$ ]] || t66_die 'invalid D1 logs canary peak'
  for node in "${T66_NODES[@]}"; do
    fresh=$("${T66_SSH[@]}" "$node" "awk -F '\\t' '\$1==\"fs\"&&\$2==\"logs\"{print \$6}' '/tmp/jfs-t66-${RUN_ID}-${CLUSTER}-${INSTANCE}-activation.tsv'")
    [[ "$fresh" =~ ^[0-9]+$ ]] || t66_die "missing D1 fresh logs free: $node"
    (( 2*(peak+1024*1024*1024) <= fresh )) || t66_die "D1 canary growth margin fails: node=$node peak=$peak fresh=$fresh"
  done
fi

# Prove the layout identity immediately before the arm.
find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
  -printf '%p\t%s\t%i\n' | sort > "$ARM/layout-pre.tsv"
cmp -s "$OUT/layout-files.tsv" "$ARM/layout-pre.tsv" || t66_die 'layout identity changed before fio'
if (( IS_CANARY == 0 )); then
  find "$MNT/seed_layout" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$ARM/seed-source-pre.tsv"
  cmp -s "$OUT/seed-source-files.tsv" "$ARM/seed-source-pre.tsv" || t66_die 'immutable seed source changed before fio'
  python3 - "$MNT/seed_layout" "$(t66_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" > "$ARM/seed-source-anchors-pre.tsv" <<'PY'
from pathlib import Path
import hashlib, sys
root=Path(sys.argv[1])
for raw in Path(sys.argv[2]).read_text().splitlines():
    name, off, _ = raw.split("\t")
    with (root/name).open("rb") as f:
        f.seek(int(off)); data=f.read(262144)
    assert len(data)==262144
    print(f"{name}\t{off}\t{hashlib.sha256(data).hexdigest()}")
PY
  cmp -s "$(t66_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" "$ARM/seed-source-anchors-pre.tsv" || t66_die 'immutable seed source content changed before fio'
fi
cp "$OUT/jobfiles/B0.fio" "$ARM/B0.fio"

# Verify the frozen remote sampler bundle, then start six bounded samplers.
for node in "${T66_NODES[@]}"; do
  for helper in t66-common.sh t66-sampler.sh; do
    local_sha=$(sha256sum "$SCRIPT_DIR/$helper" | awk '{print $1}')
    remote_sha=$("${T66_SSH[@]}" "$node" "sha256sum '$REMOTE_DIR/$helper'" | awk '{print $1}')
    [[ "$local_sha" == "$remote_sha" ]] || t66_die "remote sampler SHA mismatch: node=$node file=$helper"
  done
done

declare -a SAMPLE_NAMES=() SAMPLE_PIDS=()
stop_active_children() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [[ ${FIO_PID:-} =~ ^[0-9]+$ ]] && kill -0 "$FIO_PID" 2>/dev/null; then
    kill -TERM -- "-${FIO_PGID:-$FIO_PID}" 2>/dev/null
  fi
  for node in "${T66_NODES[@]}"; do
    "${T66_SSH[@]}" "$node" "d='/tmp/jfs-t66-${RUN_ID}-${INSTANCE}-${node}-sampler'; test ! -d \"\$d\" || printf '%s\\n' supervisor-exit > \"\$d/control.stop\"" >/dev/null 2>&1
  done
  for name in metrics client osd; do
    [[ ! -d "$OUT/samplers/$name" ]] || printf '%s\n' supervisor-exit > "$OUT/samplers/$name/control.stop"
  done
  for pid in "${SAMPLE_PIDS[@]}"; do wait "$pid" 2>/dev/null; done
  exit "$rc"
}
trap stop_active_children EXIT INT TERM

start_sampler() {
  local name=$1
  shift
  mkdir -p "$OUT/samplers/$name"
  setsid "$@" > "$OUT/samplers/$name/launcher.stdout" 2> "$OUT/samplers/$name/launcher.stderr" &
  local pid=$! pgid
  sleep 0.2
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  [[ "$pgid" == "$pid" ]] || t66_die "sampler lacks private PGID: $name"
  SAMPLE_NAMES+=("$name"); SAMPLE_PIDS+=("$pid")
}

for node in "${T66_NODES[@]}"; do
  start_sampler "$node" "${T66_SSH[@]}" "$node" \
    "bash '$REMOTE_DIR/t66-sampler.sh' node '$RUN_ID' '$CLUSTER' '$INSTANCE' '/tmp/jfs-t66-${RUN_ID}-${INSTANCE}-${node}-sampler' '/tmp/jfs-t66-${RUN_ID}-${INSTANCE}-${node}-sampler/control.stop' 900 '$node'"
done
start_sampler metrics bash "$SCRIPT_DIR/t66-sampler.sh" metrics "$RUN_ID" "$CLUSTER" "$INSTANCE" "$OUT/samplers/metrics" "$OUT/samplers/metrics/control.stop" 900
start_sampler client bash "$SCRIPT_DIR/t66-sampler.sh" client "$RUN_ID" "$CLUSTER" "$INSTANCE" "$OUT/samplers/client" "$OUT/samplers/client/control.stop" 900
start_sampler osd bash "$SCRIPT_DIR/t66-sampler.sh" osd "$RUN_ID" "$CLUSTER" "$INSTANCE" "$OUT/samplers/osd" "$OUT/samplers/osd/control.stop" 900
sleep 15
for pid in "${SAMPLE_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || t66_die "sampler died in pre-window: $pid"; done

printf '%s\tlaunch\n' "$(date +%s.%N)" > "$ARM/phase.tsv"
printf 'fio %q --write_bw_log=%q\n' "$ARM/B0.fio" "$ARM/bw/${INSTANCE}" >> "$OUT/commands.sh"
setsid fio "$ARM/B0.fio" --write_bw_log="$ARM/bw/${INSTANCE}" > "$ARM/fio.stdout" 2> "$ARM/fio.stderr" &
FIO_PID=$!
FIO_PGID=$(ps -o pgid= -p "$FIO_PID" | tr -d ' ')
[[ "$FIO_PGID" == "$FIO_PID" ]] || t66_die 'fio lacks private PGID'
printf '%s\n' "$FIO_PID" > "$ARM/fio.pid"
printf '%s\n' "$FIO_PGID" > "$ARM/fio.pgid"

SAMPLER_FAILED=0
CAPACITY_ABORT=0
MEMORY_ABORT=0
FIO_TIMEOUT=0
WATCHDOG_DEADLINE=$((SECONDS+900))
while kill -0 "$FIO_PID" 2>/dev/null; do
  sleep 2
  for i in "${!SAMPLE_PIDS[@]}"; do
    if ! kill -0 "${SAMPLE_PIDS[$i]}" 2>/dev/null; then SAMPLER_FAILED=1; fi
  done
  if (( SAMPLER_FAILED == 1 )); then
    printf '%s\tSAMPLER_CRASH\n' "$(date +%s.%N)" >> "$ARM/phase.tsv"
    kill -TERM -- "-$FIO_PGID" 2>/dev/null || true
    break
  fi
  if (( CAPACITY_ABORT == 1 )); then
    printf '%s\tCAPACITY_SAFETY_ABORT\n' "$(date +%s.%N)" >> "$ARM/phase.tsv"
    kill -TERM -- "-$FIO_PGID" 2>/dev/null || true
    break
  fi
  if (( MEMORY_ABORT == 1 )); then
    printf '%s\tMEMORY_SAFETY_ABORT\n' "$(date +%s.%N)" >> "$ARM/phase.tsv"
    kill -TERM -- "-$FIO_PGID" 2>/dev/null || true
    break
  fi
  if (( SECONDS >= WATCHDOG_DEADLINE )); then
    FIO_TIMEOUT=1
    printf '%s\tFIO_WATCHDOG_TIMEOUT\n' "$(date +%s.%N)" >> "$ARM/phase.tsv"
    kill -TERM -- "-$FIO_PGID" 2>/dev/null || true
    break
  fi
done
FIO_STUCK=0
if (( SAMPLER_FAILED || CAPACITY_ABORT || MEMORY_ABORT || FIO_TIMEOUT )) && kill -0 "$FIO_PID" 2>/dev/null; then
  TERM_DEADLINE=$((SECONDS+60))
  while kill -0 "$FIO_PID" 2>/dev/null && ((SECONDS<TERM_DEADLINE)); do sleep 1; done
fi
if kill -0 "$FIO_PID" 2>/dev/null; then
  FIO_STUCK=1; FIO_RC=124
  printf '%s\tFIO_TERM_STUCK\tno-SIGKILL-sent\n' "$(date +%s.%N)" >> "$ARM/phase.tsv"
else
  set +e; wait "$FIO_PID"; FIO_RC=$?; set -e
fi
FIO_END_EPOCH=$(date +%s.%N)
printf '%s\n' "$FIO_RC" > "$ARM/fio.rc"
printf '%s\tend\trc=%s\n' "$FIO_END_EPOCH" "$FIO_RC" >> "$ARM/phase.tsv"
if (( FIO_RC == 0 && SAMPLER_FAILED == 0 && CAPACITY_ABORT == 0 && MEMORY_ABORT == 0 && FIO_TIMEOUT == 0 )); then
  sleep 30
fi

# Stop samplers through their exact scoped control files. This is process
# supervision only; it does not unmount, destroy, or alter cluster/storage state.
for node in "${T66_NODES[@]}"; do
  "${T66_SSH[@]}" "$node" "printf '%s\\n' 'fio-exit-$(date +%s)' > '/tmp/jfs-t66-${RUN_ID}-${INSTANCE}-${node}-sampler/control.stop'"
done
printf '%s\n' "fio-exit-$(date +%s)" > "$OUT/samplers/metrics/control.stop"
printf '%s\n' "fio-exit-$(date +%s)" > "$OUT/samplers/client/control.stop"
printf '%s\n' "fio-exit-$(date +%s)" > "$OUT/samplers/osd/control.stop"

SAMPLER_POST_FAILED=0
for i in "${!SAMPLE_PIDS[@]}"; do
  set +e
  wait "${SAMPLE_PIDS[$i]}"; rc=$?
  set -e
  printf '%s\n' "$rc" > "$OUT/samplers/${SAMPLE_NAMES[$i]}/launcher.rc"
  (( rc == 0 )) || SAMPLER_POST_FAILED=1
  [[ ! -s "$OUT/samplers/${SAMPLE_NAMES[$i]}/launcher.stderr" ]] || SAMPLER_POST_FAILED=1
  case "${SAMPLE_NAMES[$i]}" in
    10.20.1.*)
      for artifact in node-meta.txt node-samples.txt sampler-status.tsv tikv-capacity-errors.txt nvme-smart-pre.json nvme-smart-post.json CAPACITY_SAFETY_ABORT MEMORY_SAFETY_ABORT; do
        if "${T66_SSH[@]}" "${SAMPLE_NAMES[$i]}" "test -e '/tmp/jfs-t66-${RUN_ID}-${INSTANCE}-${SAMPLE_NAMES[$i]}-sampler/$artifact'"; then
          "${T66_SCP[@]}" "${SAMPLE_NAMES[$i]}:/tmp/jfs-t66-${RUN_ID}-${INSTANCE}-${SAMPLE_NAMES[$i]}-sampler/$artifact" "$OUT/samplers/${SAMPLE_NAMES[$i]}/" || SAMPLER_POST_FAILED=1
        fi
      done
      [[ ! -s "$OUT/samplers/${SAMPLE_NAMES[$i]}/CAPACITY_SAFETY_ABORT" ]] || CAPACITY_ABORT=1
      [[ ! -s "$OUT/samplers/${SAMPLE_NAMES[$i]}/MEMORY_SAFETY_ABORT" ]] || MEMORY_ABORT=1
      ;;
  esac
done

(( FIO_RC == 0 && FIO_STUCK == 0 && SAMPLER_FAILED == 0 && SAMPLER_POST_FAILED == 0 && CAPACITY_ABORT == 0 && MEMORY_ABORT == 0 && FIO_TIMEOUT == 0 )) ||
  t66_die "arm failed: fio=$FIO_RC fio_stuck=$FIO_STUCK sampler_crash=$SAMPLER_FAILED sampler_post=$SAMPLER_POST_FAILED capacity_abort=$CAPACITY_ABORT memory_abort=$MEMORY_ABORT fio_timeout=$FIO_TIMEOUT"

# fio 3.28 buffers per-job BW logs and creates them only at process exit. Only
# a normal arm reaches the estimator; failed arms keep raw evidence untouched.
python3 "$SCRIPT_DIR/t66-analyze.py" --derive-io-start "$OUT"

find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
  -printf '%p\t%s\t%i\n' | sort > "$ARM/layout-post.tsv"
cmp -s "$ARM/layout-pre.tsv" "$ARM/layout-post.tsv" || t66_die 'layout identity changed after fio'
if (( IS_CANARY == 0 )); then
  find "$MNT/seed_layout" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$ARM/seed-source-post.tsv"
  cmp -s "$ARM/seed-source-pre.tsv" "$ARM/seed-source-post.tsv" || t66_die 'immutable seed source changed during fio'
  python3 - "$MNT/seed_layout" "$(t66_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" > "$ARM/seed-source-anchors-post.tsv" <<'PY'
from pathlib import Path
import hashlib, sys
root=Path(sys.argv[1])
for raw in Path(sys.argv[2]).read_text().splitlines():
    name, off, _ = raw.split("\t")
    with (root/name).open("rb") as f:
        f.seek(int(off)); data=f.read(262144)
    assert len(data)==262144
    print(f"{name}\t{off}\t{hashlib.sha256(data).hexdigest()}")
PY
  cmp -s "$ARM/seed-source-anchors-pre.tsv" "$ARM/seed-source-anchors-post.tsv" || t66_die 'immutable seed source content changed during fio'
fi
python3 "$SCRIPT_DIR/t66-analyze.py" "$OUT" | tee "$OUT/arm-analysis.stdout"
trap - EXIT INT TERM
if (( IS_CANARY == 1 )); then
  printf 'ARM_CANARY_PASS instance=%s cluster=%s evidence=NONFORMAL\n' "$INSTANCE" "$CLUSTER"
else
  printf 'ARM_PASS instance=%s cluster=%s\n' "$INSTANCE" "$CLUSTER"
fi
