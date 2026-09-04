#!/usr/bin/env bash
# Generate the frozen 256-inode B0 randwrite jobfile and its matching 128GiB extent prefill.
set -euo pipefail
export LC_ALL=C

OUT=${1:-}
TEST_DIR=${2:-}
[[ "$OUT" == /tmp/production/* && "$TEST_DIR" =~ ^/tmp/jfs-s04a1-[0-9]{8}-[0-9]{6}-mnt-(R0[1-8]|ARM-CANARY-(C|L)|SEED-FORMAL|RESTORE-(CANARY|PREFLIGHT)-(C|L))/(test_dir|seed_layout)$ ]] || {
  printf 'E_S04A1\tunsafe output or test directory\n' >&2
  exit 42
}
mkdir -p "$OUT"

files() {
  local stem=$1 parity=$2 i
  for ((i=parity; i<128; i+=2)); do
    printf '%s/%s.%s.0\n' "$TEST_DIR" "$stem" "$i"
  done
}
mapfile -t P0 < <(files storage_test 0; files rw_test 0)
mapfile -t P1 < <(files storage_test 1; files rw_test 1)
(( ${#P0[@]} == 128 && ${#P1[@]} == 128 )) || exit 42

emit_global() {
  local rw=$1
  printf '%s\n' '[global]' "rw=$rw" 'bs=256k' 'ioengine=libaio' 'direct=1' \
    'fallocate=none' 'group_reporting=1' 'iodepth=64' 'log_avg_msec=1000' \
    'per_job_logs=1'
}

emit_slots() {
  local file=$1 mode=$2 i slot name offset seed
  for ((i=0; i<128; i++)); do
    slot=$i; name=${P0[$i]}; offset=0; seed=$((slot+1))
    printf '\n[slot%03d]\nfilename=%s\nfilesize=1073741824\noffset=%s\nsize=536870912\nrandseed=%s\n' \
      "$slot" "$name" "$offset" "$seed" >> "$file"
  done
  for ((i=0; i<128; i++)); do
    slot=$((i+128)); name=${P1[$i]}; offset=536870912; seed=$((slot+1))
    printf '\n[slot%03d]\nfilename=%s\nfilesize=1073741824\noffset=%s\nsize=536870912\nrandseed=%s\n' \
      "$slot" "$name" "$offset" "$seed" >> "$file"
  done
}

emit_global write > "$OUT/layout-B0.fio"
printf '%s\n' 'allow_file_create=1' 'create_on_open=1' 'end_fsync=1' >> "$OUT/layout-B0.fio"
emit_slots "$OUT/layout-B0.fio" layout

emit_global randwrite > "$OUT/B0.fio"
printf '%s\n' 'time_based=1' 'runtime=180' 'allow_file_create=0' 'create_on_open=0' \
  'randrepeat=1' 'allrandrepeat=1' >> "$OUT/B0.fio"
emit_slots "$OUT/B0.fio" randwrite

python3 - "$OUT" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1]); root=sys.argv[2]
for name in ("layout-B0.fio","B0.fio"):
    s=(out/name).read_text()
    assert s.count("\n[slot") == 256
    assert s.count("\nfilename=") == 256
    assert s.count("\nrandseed=") == 256
    assert "read_test" not in s
    assert all(line.removeprefix("filename=").startswith(root+"/") for line in s.splitlines() if line.startswith("filename="))
b=(out/"B0.fio").read_text()
assert "allow_file_create=0" in b and "create_on_open=0" in b and "runtime=180" in b
assert "allow_file_create=1" not in b
PY
sha256sum "$OUT/layout-B0.fio" "$OUT/B0.fio"
