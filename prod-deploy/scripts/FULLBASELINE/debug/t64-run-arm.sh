#!/usr/bin/env bash
# Run exactly one 03-22 B256 arm. It never creates/destroys a cluster, device, or volume.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t64-common.sh"

RUN_ID=${1:-}
CLUSTER=${2:-}
INSTANCE=${3:-}
t64_check_run_id "$RUN_ID"
t64_check_cluster "$CLUSTER"
t64_check_instance "$INSTANCE"
IS_CANARY=0
if [[ "$INSTANCE" == ARM-CANARY-A || "$INSTANCE" == ARM-CANARY-A2 ]]; then
  IS_CANARY=1
  [[ "$CLUSTER" == A ]] || t64_die 'arm canary is restricted to cluster A'
  [[ -z ${T64_FIO_AUTH:-} ]] || t64_die 'formal T64_FIO_AUTH is forbidden for arm canary'
  [[ ${T64_ARM_CANARY_AUTH:-} == "03-22-arm-canary-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_ARM_CANARY_AUTH=03-22-arm-canary-${RUN_ID}-${INSTANCE}-${CLUSTER}"
else
  [[ "$INSTANCE" =~ ^R0[1-8]$ ]] || t64_die 'formal arm requires R01..R08'
  [[ -z ${T64_ARM_CANARY_AUTH:-} ]] || t64_die 'canary authorization is forbidden for formal arm'
  [[ ${T64_FIO_AUTH:-} == "03-22-fio-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_FIO_AUTH=03-22-fio-${RUN_ID}-${INSTANCE}-${CLUSTER}"
fi
t64_make_ssh_array
t64_require_tools fio setsid sshpass ssh scp python3 curl

OUT="/tmp/production/opencode-t3.22-${RUN_ID}/instances/${INSTANCE}"
ARM="$OUT/arm"
MNT="/tmp/jfs-t64-${RUN_ID}-mnt-${INSTANCE}"
TEST_DIR="$MNT/test_dir"
REMOTE_DIR="/tmp/jfs-t64-${RUN_ID}-scripts"
[[ -s "$OUT/READY_FOR_FIO" && -s "$OUT/LAYOUT_PASS" && -s "$OUT/volume.tsv" ]] || t64_die 'prepare/layout/volume gate missing'
if (( IS_CANARY == 0 )); then
  [[ -s "$OUT/CLONE_PASS" && $(awk -F '\t' '$1=="state_origin"{print $2}' "$OUT/volume.tsv") == restored-seed ]] ||
    t64_die 'formal arm requires a restored-seed clone state'
fi
[[ ! -e "$ARM" ]] || t64_die "arm directory already exists: $ARM"
mountpoint -q "$MNT" || t64_die 'test mount missing'
! pgrep -x fio >/dev/null || t64_die 'foreign fio exists on client'
mkdir -p "$ARM/bw" "$OUT/samplers"
if (( IS_CANARY == 1 )); then
  printf 'NONFORMAL_ARM_CANARY\n' > "$OUT/NONFORMAL_CANARY"
fi

[[ $(t64_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || t64_die 'frozen ABBA/BAAB order mismatch'

# Prove the layout identity immediately before the arm.
find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
  -printf '%p\t%s\t%i\n' | sort > "$ARM/layout-pre.tsv"
cmp -s "$OUT/layout-files.tsv" "$ARM/layout-pre.tsv" || t64_die 'layout identity changed before fio'
if (( IS_CANARY == 0 )); then
  find "$MNT/seed_layout" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$ARM/seed-source-pre.tsv"
  cmp -s "$OUT/seed-source-files.tsv" "$ARM/seed-source-pre.tsv" || t64_die 'immutable seed source changed before fio'
  python3 - "$MNT/seed_layout" "$(t64_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" > "$ARM/seed-source-anchors-pre.tsv" <<'PY'
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
  cmp -s "$(t64_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" "$ARM/seed-source-anchors-pre.tsv" || t64_die 'immutable seed source content changed before fio'
fi
cp "$OUT/jobfiles/B0.fio" "$ARM/B0.fio"

# Upload the read-only sampler, then start five bounded sampler processes.
for node in "${T64_NODES[@]}"; do
  "${T64_SCP[@]}" "$SCRIPT_DIR/t64-common.sh" "$SCRIPT_DIR/t64-sampler.sh" "$node:$REMOTE_DIR/"
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
  [[ "$pgid" == "$pid" ]] || t64_die "sampler lacks private PGID: $name"
  SAMPLE_NAMES+=("$name"); SAMPLE_PIDS+=("$pid")
}

for node in "${T64_NODES[@]}"; do
  start_sampler "$node" "${T64_SSH[@]}" "$node" \
    "bash '$REMOTE_DIR/t64-sampler.sh' node '$RUN_ID' '$CLUSTER' '$INSTANCE' '/tmp/jfs-t64-${RUN_ID}-${INSTANCE}-${node}-sampler' 300 '$node'"
done
start_sampler metrics bash "$SCRIPT_DIR/t64-sampler.sh" metrics "$RUN_ID" "$CLUSTER" "$INSTANCE" "$OUT/samplers/metrics" 300
start_sampler client bash "$SCRIPT_DIR/t64-sampler.sh" client "$RUN_ID" "$CLUSTER" "$INSTANCE" "$OUT/samplers/client" 300
sleep 15
for pid in "${SAMPLE_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || t64_die "sampler died in pre-window: $pid"; done

printf '%s\tlaunch\n' "$(date +%s.%N)" > "$ARM/phase.tsv"
printf 'fio %q --write_bw_log=%q\n' "$ARM/B0.fio" "$ARM/bw/${INSTANCE}" >> "$OUT/commands.sh"
setsid fio "$ARM/B0.fio" --write_bw_log="$ARM/bw/${INSTANCE}" > "$ARM/fio.stdout" 2> "$ARM/fio.stderr" &
FIO_PID=$!
FIO_PGID=$(ps -o pgid= -p "$FIO_PID" | tr -d ' ')
[[ "$FIO_PGID" == "$FIO_PID" ]] || t64_die 'fio lacks private PGID'
printf '%s\n' "$FIO_PID" > "$ARM/fio.pid"
printf '%s\n' "$FIO_PGID" > "$ARM/fio.pgid"

SAMPLER_FAILED=0
while kill -0 "$FIO_PID" 2>/dev/null; do
  sleep 2
  for pid in "${SAMPLE_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then SAMPLER_FAILED=1; fi
  done
  if (( SAMPLER_FAILED == 1 )); then
    printf '%s\tsamper_failed\n' "$(date +%s.%N)" >> "$ARM/phase.tsv"
    kill -INT -- "-$FIO_PGID" 2>/dev/null || true
    break
  fi
done
set +e
wait "$FIO_PID"; FIO_RC=$?
set -e
FIO_END_EPOCH=$(date +%s.%N)
printf '%s\n' "$FIO_RC" > "$ARM/fio.rc"
printf '%s\tend\trc=%s\n' "$FIO_END_EPOCH" "$FIO_RC" >> "$ARM/phase.tsv"
(( FIO_RC == 0 && SAMPLER_FAILED == 0 )) || t64_die "arm failed: fio=$FIO_RC sampler=$SAMPLER_FAILED"

# fio 3.28 buffers per-job BW logs and creates them only at process exit, so
# an in-run nonempty-file watcher can never observe the I/O onset. Derive it
# after completion from each log's flush mtime minus its last relative time;
# the analyzer requires 256 estimates with a tightly bounded spread.
python3 "$SCRIPT_DIR/t64-analyze-arm.py" --derive-io-start "$OUT"

# Samplers have a fixed 300s lifetime to cover the observed ~58s fio worker startup delay.
for i in "${!SAMPLE_PIDS[@]}"; do
  set +e
  wait "${SAMPLE_PIDS[$i]}"; rc=$?
  set -e
  printf '%s\n' "$rc" > "$OUT/samplers/${SAMPLE_NAMES[$i]}/launcher.rc"
  (( rc == 0 )) || t64_die "sampler ${SAMPLE_NAMES[$i]} rc=$rc"
  [[ ! -s "$OUT/samplers/${SAMPLE_NAMES[$i]}/launcher.stderr" ]] || t64_die "sampler ${SAMPLE_NAMES[$i]} stderr is nonempty"
  case "${SAMPLE_NAMES[$i]}" in
    10.20.1.*)
      "${T64_SCP[@]}" "${SAMPLE_NAMES[$i]}:/tmp/jfs-t64-${RUN_ID}-${INSTANCE}-${SAMPLE_NAMES[$i]}-sampler/node-meta.txt" \
        "${SAMPLE_NAMES[$i]}:/tmp/jfs-t64-${RUN_ID}-${INSTANCE}-${SAMPLE_NAMES[$i]}-sampler/node-samples.txt" \
        "$OUT/samplers/${SAMPLE_NAMES[$i]}/"
      ;;
  esac
done

find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
  -printf '%p\t%s\t%i\n' | sort > "$ARM/layout-post.tsv"
cmp -s "$ARM/layout-pre.tsv" "$ARM/layout-post.tsv" || t64_die 'layout identity changed after fio'
if (( IS_CANARY == 0 )); then
  find "$MNT/seed_layout" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$ARM/seed-source-post.tsv"
  cmp -s "$ARM/seed-source-pre.tsv" "$ARM/seed-source-post.tsv" || t64_die 'immutable seed source changed during fio'
  python3 - "$MNT/seed_layout" "$(t64_seed_dir "$RUN_ID" formal)/seed-content-anchors.tsv" > "$ARM/seed-source-anchors-post.tsv" <<'PY'
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
  cmp -s "$ARM/seed-source-anchors-pre.tsv" "$ARM/seed-source-anchors-post.tsv" || t64_die 'immutable seed source content changed during fio'
fi
python3 "$SCRIPT_DIR/t64-analyze-arm.py" "$OUT" | tee "$OUT/arm-analysis.stdout"
if (( IS_CANARY == 1 )); then
  printf 'ARM_CANARY_PASS instance=%s cluster=%s evidence=NONFORMAL\n' "$INSTANCE" "$CLUSTER"
else
  printf 'ARM_PASS instance=%s cluster=%s\n' "$INSTANCE" "$CLUSTER"
fi
