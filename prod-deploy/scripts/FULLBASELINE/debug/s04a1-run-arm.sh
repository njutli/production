#!/usr/bin/env bash
# Run exactly one 04-2 B256 arm. It never creates/destroys a cluster, device, or volume.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/s04a1-runtime-common.sh"

RUN_ID=${1:-}
CLUSTER=${2:-}
INSTANCE=${3:-}
s04a1_check_run_id "$RUN_ID"
s04a1_check_cluster "$CLUSTER"
s04a1_check_instance "$INSTANCE"
IS_CANARY=0
if [[ "$INSTANCE" == ARM-CANARY-C || "$INSTANCE" == ARM-CANARY-L ]]; then
  IS_CANARY=1
  [[ $(s04a1_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || s04a1_die 'arm canary arm mapping mismatch'
  [[ -z ${S04A1_FIO_AUTH:-} ]] || s04a1_die 'formal S04A1_FIO_AUTH is forbidden for arm canary'
  [[ ${S04A1_ARM_CANARY_AUTH:-} == "04-2-arm-canary-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_ARM_CANARY_AUTH=04-2-arm-canary-${RUN_ID}-${INSTANCE}-${CLUSTER}"
else
  [[ "$INSTANCE" =~ ^R0[1-8]$ ]] || s04a1_die 'formal arm requires R01..R08'
  [[ -z ${S04A1_ARM_CANARY_AUTH:-} ]] || s04a1_die 'canary authorization is forbidden for formal arm'
  [[ ${S04A1_FIO_AUTH:-} == "04-2-fio-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_FIO_AUTH=04-2-fio-${RUN_ID}-${INSTANCE}-${CLUSTER}"
fi
s04a1_make_ssh_array
s04a1_require_tools fio setsid ssh scp python3 curl sha256sum

OUT="/tmp/production/opencode-04-2-${RUN_ID}/instances/${INSTANCE}"
STORAGE_INSTANCE=${S04A1_STORAGE_INSTANCE:-$INSTANCE}
s04a1_check_instance "$STORAGE_INSTANCE"
[[ $STORAGE_INSTANCE =~ ^R0[1-8]$ && $(s04a1_expected_cluster "$STORAGE_INSTANCE") == "$CLUSTER" ]] || s04a1_die 'invalid storage instance binding'
if (( IS_CANARY == 1 )); then s04a1_record_authorization "$RUN_ID" "fio-canary-$INSTANCE" "$S04A1_ARM_CANARY_AUTH"; else s04a1_record_authorization "$RUN_ID" "fio-formal-$INSTANCE" "$S04A1_FIO_AUTH"; fi
ARM="$OUT/arm"
MNT="/tmp/jfs-s04a1-${RUN_ID}-mnt-${INSTANCE}"
TEST_DIR="$MNT/test_dir"
REMOTE_DIR="/tmp/jfs-s04a1-${RUN_ID}-scripts"
[[ -s "$OUT/READY_FOR_FIO" && -s "$OUT/LAYOUT_PASS" && -s "$OUT/volume.tsv" ]] || s04a1_die 'prepare/layout/volume gate missing'
if (( IS_CANARY == 0 )); then
  [[ -s "$OUT/CLONE_PASS" && $(awk -F '\t' '$1=="state_origin"{print $2}' "$OUT/volume.tsv") == restored-seed ]] ||
    s04a1_die 'formal arm requires a restored-seed clone state'
fi
[[ ! -e "$ARM" ]] || s04a1_die "arm directory already exists: $ARM"
mountpoint -q "$MNT" || s04a1_die 'test mount missing'
! pgrep -x fio >/dev/null || s04a1_die 'foreign fio exists on client'
ready_epoch=$(<"$OUT/READY_FOR_FIO"); [[ "$ready_epoch" =~ ^[0-9]+$ ]] || s04a1_die 'invalid READY_FOR_FIO epoch'
(( $(date +%s)-ready_epoch <= 600 )) || s04a1_die 'READY_FOR_FIO is older than 600s; rerun the authorized prepare gate'
s04a1_ceph_health_test_ok || s04a1_die 'Ceph health is outside the approved test/scrub state immediately before arm'
for node in "${S04A1_NODES[@]}"; do
  [[ $("${S04A1_SSH[@]}" "$node" 'systemctl is-active tikv 2>/dev/null || true') != active ]] || s04a1_die "production tikv active before fio: $node"
done
curl -fsS --connect-timeout 3 --max-time 10 "http://10.20.1.150:${S04A1_PD_CLIENT_PORT}/pd/api/v1/stores" | python3 -c '
import json,sys
s=json.load(sys.stdin).get("stores",[])
assert len(s)==3 and all(x.get("store",{}).get("state_name")=="Up" for x in s)' || s04a1_die 'temporary stores are not all Up immediately before arm'
mkdir -p "$ARM/bw" "$OUT/samplers"
if (( IS_CANARY == 1 )); then
  printf 'NONFORMAL_ARM_CANARY\n' > "$OUT/NONFORMAL_CANARY"
fi

[[ $(s04a1_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || s04a1_die 'frozen ABBA/BAAB order mismatch'

# Prove the layout identity immediately before the arm.
find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
  -printf '%p\t%s\t%i\n' | sort > "$ARM/layout-pre.tsv"
cmp -s "$OUT/layout-files.tsv" "$ARM/layout-pre.tsv" || s04a1_die 'layout identity changed before fio'
if (( IS_CANARY == 0 )); then
  find "$MNT/seed_layout" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$ARM/seed-source-pre.tsv"
  cmp -s "$OUT/seed-source-files.tsv" "$ARM/seed-source-pre.tsv" || s04a1_die 'immutable seed source changed before fio'
  python3 - "$MNT/seed_layout" "$(s04a1_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" > "$ARM/seed-source-anchors-pre.tsv" <<'PY'
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
  cmp -s "$(s04a1_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" "$ARM/seed-source-anchors-pre.tsv" || s04a1_die 'immutable seed source content changed before fio'
fi
cp "$OUT/jobfiles/B0.fio" "$ARM/B0.fio"

# Verify the frozen remote sampler bundle, then start five bounded samplers.
for node in "${S04A1_NODES[@]}"; do
  for helper in s04a1-runtime-common.sh s04a1-sampler.sh; do
    local_sha=$(sha256sum "$SCRIPT_DIR/$helper" | awk '{print $1}')
    remote_sha=$("${S04A1_SSH[@]}" "$node" "sha256sum '$REMOTE_DIR/$helper'" | awk '{print $1}')
    [[ "$local_sha" == "$remote_sha" ]] || s04a1_die "remote sampler SHA mismatch: node=$node file=$helper"
  done
done

declare -a SAMPLE_NAMES=() SAMPLE_PIDS=()
start_sampler() {
  local name=$1
  shift
  mkdir -p "$OUT/samplers/$name"
  setsid "$@" > "$OUT/samplers/$name/launcher.stdout" 2> "$OUT/samplers/$name/launcher.stderr" &
  local pid=$! pgid
  sleep 0.2
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  [[ "$pgid" == "$pid" ]] || s04a1_die "sampler lacks private PGID: $name"
  SAMPLE_NAMES+=("$name"); SAMPLE_PIDS+=("$pid")
}

for node in "${S04A1_NODES[@]}"; do
  start_sampler "$node" "${S04A1_SSH[@]}" "$node" \
    "export S04A1_STORAGE_INSTANCE='$STORAGE_INSTANCE'; bash '$REMOTE_DIR/s04a1-sampler.sh' node '$RUN_ID' '$CLUSTER' '$INSTANCE' '/tmp/jfs-s04a1-${RUN_ID}-${INSTANCE}-${node}-sampler' '/tmp/jfs-s04a1-${RUN_ID}-${INSTANCE}-${node}-sampler/control.stop' 900 '$node'"
done
start_sampler metrics bash "$SCRIPT_DIR/s04a1-sampler.sh" metrics "$RUN_ID" "$CLUSTER" "$INSTANCE" "$OUT/samplers/metrics" "$OUT/samplers/metrics/control.stop" 900
start_sampler client bash "$SCRIPT_DIR/s04a1-sampler.sh" client "$RUN_ID" "$CLUSTER" "$INSTANCE" "$OUT/samplers/client" "$OUT/samplers/client/control.stop" 900
sleep 15
PREWINDOW_FAILED=0
for pid in "${SAMPLE_PIDS[@]}"; do
  kill -0 "$pid" 2>/dev/null || PREWINDOW_FAILED=1
done
if (( PREWINDOW_FAILED == 1 )); then
  printf 'epoch\t%s\nreason\tsampler-prewindow-failure\nfio_started\tno\n' \
    "$(date +%s)" > "$OUT/PREWINDOW_ABORT.tsv"
  # Stop the surviving samplers through their scoped control files before
  # failing closed.  This prevents a pre-window bug from leaving background
  # collectors alive while preserving every failed-attempt artifact.
  for node in "${S04A1_NODES[@]}"; do
    "${S04A1_SSH[@]}" "$node" "printf '%s\\n' 'prewindow-failed-$(date +%s)' > '/tmp/jfs-s04a1-${RUN_ID}-${INSTANCE}-${node}-sampler/control.stop'"
  done
  printf '%s\n' "prewindow-failed-$(date +%s)" > "$OUT/samplers/metrics/control.stop"
  printf '%s\n' "prewindow-failed-$(date +%s)" > "$OUT/samplers/client/control.stop"
  for pid in "${SAMPLE_PIDS[@]}"; do
    set +e; wait "$pid"; set -e
  done
  s04a1_die 'one or more samplers died in pre-window; fio was not started'
fi

printf '%s\tlaunch\n' "$(date +%s.%N)" > "$ARM/phase.tsv"
printf 'fio %q --write_bw_log=%q\n' "$ARM/B0.fio" "$ARM/bw/${INSTANCE}" >> "$OUT/commands.sh"
setsid fio "$ARM/B0.fio" --write_bw_log="$ARM/bw/${INSTANCE}" > "$ARM/fio.stdout" 2> "$ARM/fio.stderr" &
FIO_PID=$!
FIO_PGID=$(ps -o pgid= -p "$FIO_PID" | tr -d ' ')
[[ "$FIO_PGID" == "$FIO_PID" ]] || s04a1_die 'fio lacks private PGID'
printf '%s\n' "$FIO_PID" > "$ARM/fio.pid"
printf '%s\n' "$FIO_PGID" > "$ARM/fio.pgid"

SAMPLER_FAILED=0
CAPACITY_ABORT=0
FIO_TIMEOUT=0
WATCHDOG_DEADLINE=$((SECONDS+900))
while kill -0 "$FIO_PID" 2>/dev/null; do
  sleep 2
  for i in "${!SAMPLE_PIDS[@]}"; do
    if ! kill -0 "${SAMPLE_PIDS[$i]}" 2>/dev/null; then SAMPLER_FAILED=1; fi
    if grep -Fq 'CAPACITY_SAFETY_ABORT' "$OUT/samplers/${SAMPLE_NAMES[$i]}/launcher.stdout" 2>/dev/null; then CAPACITY_ABORT=1; fi
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
  if (( SECONDS >= WATCHDOG_DEADLINE )); then
    FIO_TIMEOUT=1
    printf '%s\tFIO_WATCHDOG_TIMEOUT\n' "$(date +%s.%N)" >> "$ARM/phase.tsv"
    kill -TERM -- "-$FIO_PGID" 2>/dev/null || true
    break
  fi
done
FIO_STUCK=0
if (( SAMPLER_FAILED || CAPACITY_ABORT || FIO_TIMEOUT )) && kill -0 "$FIO_PID" 2>/dev/null; then
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
if (( FIO_RC == 0 && SAMPLER_FAILED == 0 && CAPACITY_ABORT == 0 && FIO_TIMEOUT == 0 )); then
  sleep 30
fi

# Stop samplers through their exact scoped control files. This is process
# supervision only; it does not unmount, destroy, or alter cluster/storage state.
for node in "${S04A1_NODES[@]}"; do
  "${S04A1_SSH[@]}" "$node" "printf '%s\\n' 'fio-exit-$(date +%s)' > '/tmp/jfs-s04a1-${RUN_ID}-${INSTANCE}-${node}-sampler/control.stop'"
done
printf '%s\n' "fio-exit-$(date +%s)" > "$OUT/samplers/metrics/control.stop"
printf '%s\n' "fio-exit-$(date +%s)" > "$OUT/samplers/client/control.stop"

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
      for artifact in node-meta.txt node-samples.txt sampler-status.tsv tikv-capacity-errors.txt CAPACITY_SAFETY_ABORT; do
        if "${S04A1_SSH[@]}" "${SAMPLE_NAMES[$i]}" "test -e '/tmp/jfs-s04a1-${RUN_ID}-${INSTANCE}-${SAMPLE_NAMES[$i]}-sampler/$artifact'"; then
          "${S04A1_SCP[@]}" "${SAMPLE_NAMES[$i]}:/tmp/jfs-s04a1-${RUN_ID}-${INSTANCE}-${SAMPLE_NAMES[$i]}-sampler/$artifact" "$OUT/samplers/${SAMPLE_NAMES[$i]}/" || SAMPLER_POST_FAILED=1
        fi
      done
      ;;
  esac
done

(( FIO_RC == 0 && FIO_STUCK == 0 && SAMPLER_FAILED == 0 && SAMPLER_POST_FAILED == 0 && CAPACITY_ABORT == 0 && FIO_TIMEOUT == 0 )) ||
  s04a1_die "arm failed: fio=$FIO_RC fio_stuck=$FIO_STUCK sampler_crash=$SAMPLER_FAILED sampler_post=$SAMPLER_POST_FAILED capacity_abort=$CAPACITY_ABORT fio_timeout=$FIO_TIMEOUT"

# fio 3.28 buffers per-job BW logs and creates them only at process exit. Only
# a normal arm reaches the estimator; failed arms keep raw evidence untouched.
python3 "$SCRIPT_DIR/t65-analyze.py" --derive-io-start "$OUT"

find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
  -printf '%p\t%s\t%i\n' | sort > "$ARM/layout-post.tsv"
cmp -s "$ARM/layout-pre.tsv" "$ARM/layout-post.tsv" || s04a1_die 'layout identity changed after fio'
if (( IS_CANARY == 0 )); then
  find "$MNT/seed_layout" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$ARM/seed-source-post.tsv"
  cmp -s "$ARM/seed-source-pre.tsv" "$ARM/seed-source-post.tsv" || s04a1_die 'immutable seed source changed during fio'
  python3 - "$MNT/seed_layout" "$(s04a1_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" > "$ARM/seed-source-anchors-post.tsv" <<'PY'
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
  cmp -s "$ARM/seed-source-anchors-pre.tsv" "$ARM/seed-source-anchors-post.tsv" || s04a1_die 'immutable seed source content changed during fio'
fi
python3 "$SCRIPT_DIR/s04a1-analyze.py" --arm "$OUT" "$INSTANCE" | tee "$OUT/arm-analysis.stdout"
if (( IS_CANARY == 1 )); then
  printf 'ARM_CANARY_PASS instance=%s cluster=%s evidence=NONFORMAL\n' "$INSTANCE" "$CLUSTER"
else
  printf 'ARM_PASS instance=%s cluster=%s\n' "$INSTANCE" "$CLUSTER"
fi
