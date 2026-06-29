#!/bin/bash
# Test cache effectiveness and read-ahead amplification with pure randread.
#
# The leadership's randrw + create_on_open spec makes reads pathological (4 MB/s),
# so it can't evaluate cache effectiveness. This script uses pure randread on
# pre-written data to answer:
#   1. Does JuiceFS cache help for repeated reads? (G1 vs G2)
#   2. Is the 2.5x NIC amplification caused by read-ahead/prefetch? (G1 vs G3)
#   3. Does cache help when read-ahead is disabled? (G3 vs G4)
#
# Each group: fresh_volume (destroy+format+mount) -> prefill (seq write) -> REPEAT x randread
# NIC RX/TX sampled per run to compute amplification = NIC_RX / effective_read
#
# Usage:  bash tests/bench-cache-randread.sh
# Env:
#   REPEAT      per-group repeats            (default 3)
#   CACHE_SIZE  warm-group cache MB          (default 10240 = 10G)
#   CACHE_DIR   cache directory on local SSD (default /data/jfsCache)
#   BSZ         JuiceFS block-size           (default 256K)
#   RUNTIME     fio runtime seconds          (default 60)
#   FILE_SIZE   per-file size for randread   (default 128M)
#   NR_FILES    files per fio job            (default 1)
set -uo pipefail
cd /home/turboai/production
source config.sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null

REPEAT="${REPEAT:-3}"
CACHE_SIZE="${CACHE_SIZE:-10240}"
CACHE_DIR="${CACHE_DIR:-/data/jfsCache}"
BSZ="${BSZ:-256K}"
RUNTIME="${RUNTIME:-60}"
FILE_SIZE="${FILE_SIZE:-128M}"
NR_FILES="${NR_FILES:-1}"
NIC="${NIC:-eno1}"

FS="jfs-randread"
META="tikv://${TIKV_SERVER}:2379/${FS}"
POOL="juicefs-data"
MP="/mnt/juicefs"
RES="${PWD}/results"
TS=$(date +%Y%m%d-%H%M%S)
OUT="${RES}/cache-randread-${TS}.txt"
mkdir -p "${RES}"

log(){ echo "$@" >> "${OUT}"; echo "$@" >&2; }

# bw_val: extract numeric MB/s from fio output (handles MB/s, MiB/s, kB/s, KiB/s)
bw_val(){
  local line label file
  label="$1"; file="$2"
  line=$(grep -E "${label}: bw=" "$file" | head -1)
  # Try MB/s first
  local val
  val=$(echo "$line" | grep -oE '\([0-9.]+MB/s\)' | head -1 | tr -d '()' | sed 's/MB\/s//')
  # Try MiB/s
  if [ -z "$val" ]; then
    val=$(echo "$line" | grep -oE '\([0-9.]+MiB/s\)' | head -1 | tr -d '()' | sed 's/MiB\/s//')
  fi
  # Try kB/s and convert
  if [ -z "$val" ]; then
    local kb
    kb=$(echo "$line" | grep -oE '\([0-9.]+kB/s\)' | head -1 | tr -d '()' | sed 's/kB\/s//')
    if [ -n "$kb" ]; then
      val=$(awk "BEGIN{printf \"%.1f\", ${kb}/1024}")
    fi
  fi
  # Try KiB/s and convert
  if [ -z "$val" ]; then
    local kib
    kib=$(echo "$line" | grep -oE '\([0-9.]+KiB/s\)' | head -1 | tr -d '()' | sed 's/KiB\/s//')
    if [ -n "$kib" ]; then
      val=$(awk "BEGIN{printf \"%.1f\", ${kib}/1024}")
    fi
  fi
  echo "${val:-0}"
}

nic_bytes(){
  awk -v n="${NIC}" '$1 ~ n":" {gsub(/:/," "); print $2, $10}' /proc/net/dev
}

clean(){
  pkill -9 fio 2>/dev/null || true
  fusermount -uz "${MP}" 2>/dev/null || sudo umount -l "${MP}" 2>/dev/null || true
  sleep 3
}

drop_caches(){
  sync || true
  sudo sh -c 'echo 3 >/proc/sys/vm/drop_caches' 2>/dev/null || true
  [ -d "${CACHE_DIR}" ] && find "${CACHE_DIR}" -type f -path '*raw*' -delete 2>/dev/null || true
}

# fresh: destroy old volume -> format new -> mount with given opts
fresh(){
  local opts="$1"
  clean; sleep 60
  local u; u=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
  [ -n "${u}" ] && juicefs destroy "${META}" "${u}" --yes 2>&1 | tail -1 || true
  sleep 5
  juicefs format --storage ceph --bucket "ceph://${POOL}" \
      --access-key ceph --secret-key client.juicefs \
      --block-size "${BSZ}" --trash-days 0 "${META}" "${FS}" 2>&1 \
      | grep -E "BlockSize|OK" | tee -a "${OUT}"
  if [ ! -d "${CACHE_DIR}" ]; then
    sudo mkdir -p "${CACHE_DIR}"
    sudo chown "$(whoami):$(whoami)" "${CACHE_DIR}" 2>/dev/null || true
  fi
  sudo mkdir -p "${MP}"; sudo chown "$(whoami):$(whoami)" "${MP}" 2>/dev/null || true
  juicefs mount -d ${opts} "${META}" "${MP}" 2>&1 | tail -1 | tee -a "${OUT}"
  sleep 3
  mountpoint -q "${MP}" || { log "FATAL: mount failed"; exit 1; }
}

# prefill: sequential write to create test files (same name/numjobs as randread)
prefill(){
  log ">>> Prefilling 128 files x ${FILE_SIZE} (seq write)..."
  mkdir -p "${MP}/test_dir"
  fio --directory="${MP}/test_dir" \
      --name=storage_test \
      --nrfiles="${NR_FILES}" \
      --filesize="${FILE_SIZE}" \
      --size="${FILE_SIZE}" \
      --bs=4M \
      --rw=write \
      --ioengine=libaio \
      --iodepth=4 \
      --numjobs=128 \
      --direct=1 \
      --fallocate=none \
      --group_reporting > "${RES}/cache-randread-${TS}-prefill-${1}.txt" 2>&1
  log ">>> Prefill done."
}

# randread: pure random read with NIC sampling
# $1 = label ; prints "READ NIC_RX AMPL" to stdout
randread(){
  local label="$1"
  drop_caches
  local out="${RES}/cache-randread-${TS}-${label}.txt"

  local s e srx stx erx etx
  s=$(nic_bytes); srx=${s% *}; stx=${s#* }
  fio --directory="${MP}/test_dir" \
      --name=storage_test \
      --nrfiles="${NR_FILES}" \
      --filesize="${FILE_SIZE}" \
      --size="${FILE_SIZE}" \
      --bs=256k \
      --rw=randread \
      --ioengine=libaio \
      --iodepth=128 \
      --numjobs=128 \
      --direct=1 \
      --fallocate=none \
      --group_reporting \
      --time_based \
      --runtime=${RUNTIME}s > "${out}" 2>&1
  e=$(nic_bytes); erx=${e% *}; etx=${e#* }

  local r rxmb txmb ampl
  r=$(bw_val READ "${out}")
  rxmb=$(awk "BEGIN{printf \"%.1f\", (${erx}-${srx})/1048576/${RUNTIME}}")
  txmb=$(awk "BEGIN{printf \"%.1f\", (${etx}-${stx})/1048576/${RUNTIME}}")
  ampl=$(awk "BEGIN{ if(${r}+0>0) printf \"%.2f\", ${rxmb}/${r}; else print \"n/a\" }")

  log "  ${label}:  READ=${r}MB/s  NIC_RX=${rxmb}MB/s  NIC_TX=${txmb}MB/s  ampl=${ampl}x  (raw: ${out})"
  echo "${r} ${rxmb} ${ampl}"
}

# ============================================================
log "============================================================"
log "Cache + Readahead randread test"
log "Date: $(date)"
log "STORAGE=ceph  pool=${POOL}  block-size=${BSZ}  REPEAT=${REPEAT}  runtime=${RUNTIME}s"
log "fio: 256k randread iodepth=128 numjobs=128 direct=1 (pure read, no create_on_open)"
log "data: ${NR_FILES} files x ${FILE_SIZE}  cache-dir=${CACHE_DIR}  nic=${NIC}"
log "target: 59 MB/s (gigabit half-speed)  L1 baseline: 112.7 MB/s (ampl=1.04x)"
log "============================================================"

# --- Group 1: cache=0, default readahead ---
log ""
log "########## Group 1: cache=0, default readahead/prefetch ##########"
fresh "--cache-size 0"
prefill "g1"
G1_FILE="${OUT}.g1"; : > "${G1_FILE}"
for i in $(seq 1 "${REPEAT}"); do
  randread "g1r${i}" >> "${G1_FILE}"
done

# --- Group 2: cache=10G, default readahead ---
log ""
log "########## Group 2: cache=${CACHE_SIZE}MB, default readahead/prefetch ##########"
fresh "--cache-size ${CACHE_SIZE} --cache-dir ${CACHE_DIR}"
prefill "g2"
G2_FILE="${OUT}.g2"; : > "${G2_FILE}"
for i in $(seq 1 "${REPEAT}"); do
  randread "g2r${i}" >> "${G2_FILE}"
done

# --- Group 3: cache=0, no readahead/prefetch ---
log ""
log "########## Group 3: cache=0, --max-readahead=0 --prefetch=0 ##########"
fresh "--cache-size 0 --max-readahead 0 --prefetch 0"
prefill "g3"
G3_FILE="${OUT}.g3"; : > "${G3_FILE}"
for i in $(seq 1 "${REPEAT}"); do
  randread "g3r${i}" >> "${G3_FILE}"
done

# --- Group 4: cache=10G, no readahead/prefetch ---
log ""
log "########## Group 4: cache=${CACHE_SIZE}MB, --max-readahead=0 --prefetch=0 ##########"
fresh "--cache-size ${CACHE_SIZE} --cache-dir ${CACHE_DIR} --max-readahead 0 --prefetch 0"
prefill "g4"
G4_FILE="${OUT}.g4"; : > "${G4_FILE}"
for i in $(seq 1 "${REPEAT}"); do
  randread "g4r${i}" >> "${G4_FILE}"
done

# --- cleanup ---
log ""
log ">>> cleanup"
clean; sleep 60
u=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
[ -n "${u}" ] && juicefs destroy "${META}" "${u}" --yes 2>&1 | tail -1 || true

# --- summary ---
log ""
log "============================================================"
log "SUMMARY"
log "============================================================"
for g in 1 2 3 4; do
  file="${OUT}.g${g}"
  label=""
  case $g in
    1) label="cache=0, default readahead";;
    2) label="cache=${CACHE_SIZE}MB, default readahead";;
    3) label="cache=0, --max-readahead=0 --prefetch=0";;
    4) label="cache=${CACHE_SIZE}MB, --max-readahead=0 --prefetch=0";;
  esac
  log ""
  log "Group ${g} (${label}):"
  awk 'NF{printf "  run%d: READ=%6.1f MB/s  NIC_RX=%6.1f MB/s  ampl=%sx\n",NR,$1,$2,$3; rs+=$1; rx+=$2; n++}
       END{if(n>0)printf "  ── AVG:    READ=%6.1f MB/s  NIC_RX=%6.1f MB/s  ampl=%.2fx  (n=%d) ──\n",rs/n,rx/n,rx/rs,n}' \
       "${file}" | tee -a "${OUT}"
done

log ""
log "Target: 59 MB/s (single-client, gigabit half-speed)"
log "L1 baseline: 112.7 MB/s (bare RADOS 256K rand, ampl=1.04x)"
log "DONE  full log: ${OUT}"
echo "=== CACHE-RANDREAD DONE exit=0 ==="
