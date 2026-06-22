#!/bin/bash
# Compare cache=0 (cold baseline) vs cache=N (AI warm steady-state)
# using the verbatim acceptance-spec randrw command (leadership's fio params).
#
# Background: all prior tests hardcoded --cache-size 0 (disabling JuiceFS read
# cache) to get "cold truth".  But leadership's fio spec only requires
# --direct=1 (bypass kernel page cache); it never asked to disable JuiceFS
# application-level cache.  AI training reads the same data repeatedly, so
# cache hits are real gains, not "hallucination".  This script checks whether
# the default JuiceFS cache makes the [spec] randrw pass 59 MB/s.
#
# Each group: fresh_volume (destroy+format+mount) -> REPEAT x spec randrw.
# Before every run: drop_caches (kernel + JuiceFS cache dir) for cold start.
# Within-run "self-warming" (randrw writes data that later reads may hit) is
# NOT suppressed — that is exactly what we want to measure.
#
# Usage:  bash tests/bench-cache-compare.sh
# Env:
#   REPEAT      per-group repeats            (default 3)
#   CACHE_SIZE  warm-group cache MB          (default 10240 = 10G)
#   CACHE_DIR   cache directory on local SSD (default /data/jfsCache)
#   BSZ         JuiceFS block-size           (default 256K)
#   RUNTIME     fio runtime seconds          (default 60)
set -uo pipefail
cd /home/turboai/production
source config.sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null

REPEAT="${REPEAT:-3}"
CACHE_SIZE="${CACHE_SIZE:-10240}"
CACHE_DIR="${CACHE_DIR:-/data/jfsCache}"
BSZ="${BSZ:-256K}"
RUNTIME="${RUNTIME:-60}"

FS="jfs-cachecmp"
META="tikv://${TIKV_SERVER}:2379/${FS}"
POOL="juicefs-data"
MP="/mnt/juicefs"
RES="${PWD}/results"
TS=$(date +%Y%m%d-%H%M%S)
OUT="${RES}/cache-compare-${TS}.txt"
mkdir -p "${RES}"

# log goes to file + stderr (never stdout, so $( ) capture stays clean)
log(){ echo "$@" >> "${OUT}"; echo "$@" >&2; }

# --- helpers ---

# bw_val: extract numeric MB/s from fio output  $1=READ|WRITE  $2=file
bw_val(){
  grep -E "$1: bw=" "$2" | head -1 \
    | grep -oE '\([0-9.]+MB/s\)' | head -1 | tr -d '()' | sed 's/MB\/s//'
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

# fresh: destroy old volume -> format new -> mount with given cache opts
# $1 = juicefs mount opts (e.g. "--cache-size 0" or "--cache-size 10240 --cache-dir /data/jfsCache")
fresh(){
  local opts="$1"
  clean; sleep 60   # wait for session expiry before destroy
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

# spec_randrw: leadership's verbatim fio spec (randrw + create_on_open)
# $1 = label ; prints "READ_VAL WRITE_VAL" to stdout (captured by caller)
spec_randrw(){
  rm -rf "${MP}/test_dir"; mkdir -p "${MP}/test_dir"; drop_caches
  local out="${RES}/cache-compare-${TS}-$1.txt"
  fio --directory="${MP}/test_dir" \
      --name=storage_test \
      --nrfiles=100 \
      --filesize=1G \
      --size=1G \
      --bs=256k \
      --rw=randrw \
      --ioengine=libaio \
      --iodepth=128 \
      --numjobs=128 \
      --direct=1 \
      --fallocate=none \
      --create_on_open=1 \
      --openfiles=100 \
      --group_reporting \
      --time_based \
      --runtime=${RUNTIME}s > "${out}" 2>&1
  local r w
  r=$(bw_val READ  "${out}")
  w=$(bw_val WRITE "${out}")
  log "  $1:  READ=${r:-N/A}MB/s  WRITE=${w:-N/A}MB/s  (raw: ${out})"
  echo "${r:-0} ${w:-0}"
}

# ============================================================
log "============================================================"
log "Cache Compare: cache=0 (cold) vs cache=${CACHE_SIZE}MB (warm)"
log "Date: $(date)"
log "STORAGE=ceph  pool=${POOL}  block-size=${BSZ}  REPEAT=${REPEAT}  runtime=${RUNTIME}s"
log "fio: verbatim spec — 256k randrw iodepth=128 numjobs=128 direct=1 create_on_open=1"
log "cache-dir=${CACHE_DIR}  target=59 MB/s (gigabit half-speed)"
log "============================================================"

# --- Group 1: cache=0 (cold baseline, same as all prior tests) ---
log ""
log "########## Group 1: cache=0 (cold baseline) ##########"
fresh "--cache-size 0"
G1_FILE="${OUT}.g1"; : > "${G1_FILE}"
for i in $(seq 1 "${REPEAT}"); do
  spec_randrw "g1r${i}" >> "${G1_FILE}"
done

# --- Group 2: with cache (AI warm steady-state) ---
log ""
log "########## Group 2: cache=${CACHE_SIZE}MB (warm steady-state) ##########"
fresh "--cache-size ${CACHE_SIZE} --cache-dir ${CACHE_DIR}"
G2_FILE="${OUT}.g2"; : > "${G2_FILE}"
for i in $(seq 1 "${REPEAT}"); do
  spec_randrw "g2r${i}" >> "${G2_FILE}"
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
log "Group 1 (cache=0 — cold baseline, same as all prior tests):"
awk 'NF{printf "  run%d: READ=%6.1f MB/s  WRITE=%6.1f MB/s\n",NR,$1,$2; rs+=$1; ws+=$2; n++}
     END{if(n>0)printf "  ── AVG:    READ=%6.1f MB/s  WRITE=%6.1f MB/s  (n=%d) ──\n",rs/n,ws/n,n}' \
     "${G1_FILE}" | tee -a "${OUT}"
log ""
log "Group 2 (cache=${CACHE_SIZE}MB — warm steady-state, AI training scenario):"
awk 'NF{printf "  run%d: READ=%6.1f MB/s  WRITE=%6.1f MB/s\n",NR,$1,$2; rs+=$1; ws+=$2; n++}
     END{if(n>0)printf "  ── AVG:    READ=%6.1f MB/s  WRITE=%6.1f MB/s  (n=%d) ──\n",rs/n,ws/n,n}' \
     "${G2_FILE}" | tee -a "${OUT}"
log ""
log "Target: 59 MB/s (single-client, gigabit half-speed)"
log "DONE  full log: ${OUT}"
echo "=== CACHE-COMPARE DONE exit=0 ==="
