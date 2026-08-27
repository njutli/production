#!/usr/bin/env bash
# t56-gen-jobfiles.sh: Generate and validate 4 fio jobfiles for 03-19
# Usage: bash t56-gen-jobfiles.sh <output_dir>
set -euo pipefail

OUT="${1:-/tmp/t56-jobfiles}"
mkdir -p "$OUT"
TEST_DIR="/mnt/juicefs/test_dir"

# P0: storage_test even + rw_test even (128 files)
# P1: storage_test odd + rw_test odd (128 files)
gen_p_list() {
  local prefix=$1 odd_or_even=$2
  local i
  if [[ "$odd_or_even" == "even" ]]; then
    for ((i=0; i<128; i+=2)); do echo "${TEST_DIR}/${prefix}.${i}.0"; done
  else
    for ((i=1; i<128; i+=2)); do echo "${TEST_DIR}/${prefix}.${i}.0"; done
  fi
}

# Build P0 and P1 arrays
mapfile -t P0 < <(gen_p_list storage_test even; gen_p_list rw_test even)
mapfile -t P1 < <(gen_p_list storage_test odd; gen_p_list rw_test odd)

LOW_OFFSET=0
HIGH_OFFSET=536870912   # 512*1024*1024
HALF_SIZE=536870912     # 512M

gen_jobfile() {
  local outfile=$1 low_files_var=$2 high_files_var=$3 low_offset=$4 high_offset=$5
  local i slot filename offset seed
  local n=${#P0[@]}  # 128

  cat > "$outfile" << 'GLOBAL'
[global]
rw=randwrite
bs=256k
ioengine=libaio
direct=1
fallocate=none
time_based=1
runtime=180
group_reporting=1
allow_file_create=0
create_on_open=0
iodepth=64
log_avg_msec=1000
per_job_logs=1
randrepeat=1
allrandrepeat=1
GLOBAL

  # Low half: slots 0-127
  eval "local -a low_files=(\"\${${low_files_var}[@]}\")"
  for ((i=0; i<128; i++)); do
    filename="${low_files[$i]}"
    seed=$((i + 1))
    cat >> "$outfile" << EOF

[slot$(printf '%03d' $i)]
filename=$filename
offset=$low_offset
size=$HALF_SIZE
randseed=$seed
EOF
  done

  # High half: slots 128-255
  eval "local -a high_files=(\"\${${high_files_var}[@]}\")"
  for ((i=0; i<128; i++)); do
    slot=$((i + 128))
    filename="${high_files[$i]}"
    seed=$((slot + 1))
    cat >> "$outfile" << EOF

[slot$(printf '%03d' $slot)]
filename=$filename
offset=$high_offset
size=$HALF_SIZE
randseed=$seed
EOF
  done
}

# R0: P0 low + P0 high (128 inode, 2 job/inode)
gen_jobfile "$OUT/R0.fio" P0 P0 $LOW_OFFSET $HIGH_OFFSET

# B0: P0 low + P1 high (256 inode, 1 job/inode)
gen_jobfile "$OUT/B0.fio" P0 P1 $LOW_OFFSET $HIGH_OFFSET

# R1: P1 low + P1 high (128 inode, 2 job/inode)
gen_jobfile "$OUT/R1.fio" P1 P1 $LOW_OFFSET $HIGH_OFFSET

# B1: P1 low + P0 high (256 inode, 1 job/inode)
gen_jobfile "$OUT/B1.fio" P1 P0 $LOW_OFFSET $HIGH_OFFSET

echo "Generated 4 jobfiles in $OUT"
md5sum "$OUT"/*.fio
