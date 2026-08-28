#!/usr/bin/env bash
# u141b-collect.sh -- per-round pre/post evidence collection for U141b.
#
# Implements the collection half of the task book §6.1/§6.3 and the hard gates
# S09..S19.  Every subcommand is read-only with respect to the cluster except
# `drain`, which is a separate script concern and NOT implemented here.
#
# Usage:
#   u141b-collect.sh objects <out.tsv> <tag>          three ceph df samples
#   u141b-collect.sh assets  <out.tsv>                384-file manifest (needs mount)
#   u141b-collect.sh mount   <out.txt>                mount fingerprints (BEFORE umount)
#   u141b-collect.sh frozen  <out.tsv>                frozen-object manifest
#   u141b-collect.sh ceph    <out.txt>                health + PG primary map
#   u141b-collect.sh resolve <shim> <expect_md5> <out.txt>   S09b arm self-proof
#   u141b-collect.sh --self-test                      offline fixture mode
#
# ⛔ No fusermount -uz / umount -l / losetup -D / rm -rf / pattern kill anywhere.
set -euo pipefail
export LC_ALL=C

MNT=${MNT:-/mnt/juicefs}
TEST_DIR=${TEST_DIR:-${MNT}/test_dir}
META=${META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
V4=${V4:-/tmp/FULLBASELINE_V4.sh}
MSGR_CONF=${MSGR_CONF:-/tmp/t141-msgr8.conf}
SYS_CEPH_CONF=${SYS_CEPH_CONF:-/etc/ceph/ceph.conf}

# frozen expectations (task book §2.1 / §2.2)
EXP_V4_MD5=4198ea2676ba56744a3cd5eba17a5eab
EXP_MSGR_MD5=86351c58848c7e4caaa1bbeccb211730
EXP_SYSCEPH_MD5=5b6be34179a64e0a5f9c6d3a9690041f
EXP_V13_MD5=de93563f11a5ff3bd94dd25a4e0283b1
EXP_V14_MD5=24fae0852051c80ca571cb2f20275d46
ASSET_SIZE=1073741824
ASSET_COUNT=128
READ_TEST_MTIME_PREFIX=${READ_TEST_MTIME_PREFIX:-2026-08-04 17:06}

die() { echo "COLLECT_FAIL: $*" >&2; exit 1; }
note() { echo "[collect] $*" >&2; }

# ------------------------------------------------------------------ helpers

pool_json() {
  sudo ceph df --format=json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
p = [x for x in d["pools"] if x["name"] == "juicefs-data"][0]["stats"]
# D09: never column-split "892 GiB"; always JSON.
print("%d\t%d\t%d" % (p["objects"], p["stored"], p["max_avail"]))
'
}

# ------------------------------------------------------------------ objects

cmd_objects() {
  local out=$1
  local tag=$2
  [[ -f $out ]] || printf 'ts\ttag\tsample\tobjects\tstored\tmax_avail\n' > "$out"
  local i line objs=()
  for i in 1 2 3; do
    line=$(pool_json) || die "ceph df JSON parse failed (tag=$tag sample=$i)"
    [[ -n $line ]] || die "empty ceph df result (tag=$tag sample=$i)"
    # D09 guard: must be pure integers, never a literal unit like GiB
    awk -F'\t' 'NF!=3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ {exit 1}' <<<"$line" \
      || die "non-numeric pool sample '$line' (tag=$tag) -- refuse to treat as 0"
    printf '%s\t%s\t%d\t%s\n' "$(date +%s)" "$tag" "$i" "$line" >> "$out"
    objs+=("$(cut -f1 <<<"$line")")
    [[ $i -lt 3 ]] && sleep 10
  done
  local min=${objs[0]}
  local max=${objs[0]}
  local o
  for o in "${objs[@]}"; do
    (( o < min )) && min=$o
    (( o > max )) && max=$o
  done
  echo "OBJECTS tag=$tag min=$min max=$max spread=$((max - min))"
}

# ------------------------------------------------------------------ assets

cmd_assets() {
  # D29: assert the exact byte size of every asset -- 'file exists' is not enough
  # D30: paired with cmd_mount, which takes ALL juicefs mount pids (parent+child)
  local out=$1
  mountpoint -q "$MNT" || die "assets: $MNT not mounted"
  : > "$out"
  printf 'path\tsize\tmtime_epoch\tmtime_human\n' >> "$out"
  local base n bad=0
  for base in read_test rw_test storage_test; do
    n=0
    while IFS= read -r f; do
      # D02: build TSV with printf, never stat -c '%n\t%i'
      printf '%s\t%s\t%s\t%s\n' \
        "$f" "$(stat -c %s "$f")" "$(stat -c %Y "$f")" "$(stat -c %y "$f")" >> "$out"
      [[ $(stat -c %s "$f") == "$ASSET_SIZE" ]] || { echo "BADSIZE $f" >&2; bad=1; }
      n=$((n + 1))
    done < <(ls -1 "${TEST_DIR}/${base}."*.0 2>/dev/null | sort)
    echo "ASSET $base count=$n expect=$ASSET_COUNT"
    [[ $n -eq $ASSET_COUNT ]] || { echo "BADCOUNT $base=$n" >&2; bad=1; }
  done
  local rt
  rt=$(stat -c %y "${TEST_DIR}/read_test.0.0" 2>/dev/null || echo NA)
  echo "ASSET read_test.0.0 mtime=$rt expect_prefix=$READ_TEST_MTIME_PREFIX"
  [[ $rt == "${READ_TEST_MTIME_PREFIX}"* ]] \
    || { echo "READ_TEST_MTIME_CHANGED $rt" >&2; bad=1; }
  local d
  for d in seqread mseqread seqwrite mseqwrite; do
    [[ -d "${TEST_DIR}/${d}" ]] || { echo "MISSING_DIR $d" >&2; bad=1; }
  done
  [[ $bad -eq 0 ]] || die "asset gate S05/S16 failed (see BADSIZE/BADCOUNT above)"
  echo "ASSETS_PASS"
}

# ------------------------------------------------------------------ mount fp

cmd_mount() {
  local out=$1
  : > "$out"
  {
    echo "# collected $(date -Is) epoch=$(date +%s)"
    mount | grep -F juice || echo "(no juicefs mount)"
  } >> "$out"

  # D04/D30: mount -d forks parent+child; take ALL pids, never head -1
  local pids p exe st cl cc n=0
  mapfile -t pids < <(pgrep -f 'juicefs.*mount' || true)
  for p in "${pids[@]}"; do
    [[ -n $p ]] || continue
    # D05: root-owned /proc needs sudo; never leave a blank field
    exe=$(sudo md5sum "/proc/$p/exe" 2>/dev/null | awk '{print $1}') \
      || die "cannot read /proc/$p/exe (need sudo) -- refuse to leave blank"
    [[ -n $exe ]] || die "empty exe md5 for pid $p"
    st=$(awk '{print $22}' "/proc/$p/stat" 2>/dev/null || echo NA)
    cl=$(sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || echo NA)
    cc=$(sudo tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep '^CEPH_CONF=' || echo "CEPH_CONF=(unset)")
    printf 'pid=%s\texe_md5=%s\tstarttime=%s\t%s\tcmdline=%s\n' \
      "$p" "$exe" "$st" "$cc" "$cl" >> "$out"
    n=$((n + 1))
  done
  echo "MOUNT_PIDS=$n"
  [[ $n -ge 1 ]] || die "no juicefs mount process found (S10)"
}

cmd_gate_mount() {
  local fp=$1
  local expect=$2
  [[ -f $fp ]] || die "gate_mount: missing $fp"
  local bad=0
  local line
  # S10: EVERY mount pid must be the expected binary
  while IFS= read -r line; do
    [[ $line == pid=* ]] || continue
    grep -q "exe_md5=${expect}" <<<"$line" || { echo "S10_FAIL $line" >&2; bad=1; }
    grep -q "CEPH_CONF=${MSGR_CONF}" <<<"$line" || { echo "S11_FAIL $line" >&2; bad=1; }
  done < "$fp"
  grep -q 'max_read=262144' "$fp" || { echo "S12_FAIL no max_read=262144" >&2; bad=1; }
  [[ $bad -eq 0 ]] || die "mount gates S10/S11/S12 failed"
  echo "MOUNT_GATES_PASS expect=$expect"
}

# ------------------------------------------------------------------ frozen

cmd_frozen() {
  local out=$1
  printf 'object\tmd5\tstatus\n' > "$out"
  local f exp got
  while read -r f exp; do
    [[ -n ${f:-} ]] || continue
    if [[ -e $f ]]; then
      got=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
    else
      got=MISSING
    fi
    printf '%s\t%s\t%s\n' "$f" "$got" \
      "$([[ $got == "$exp" ]] && echo OK || echo MISMATCH)" >> "$out"
  done <<EOF
$V4 $EXP_V4_MD5
$MSGR_CONF $EXP_MSGR_MD5
$SYS_CEPH_CONF $EXP_SYSCEPH_MD5
/tmp/juicefs-03-8 $EXP_V13_MD5
/tmp/juicefs-1.4.1-patched $EXP_V14_MD5
EOF
  local s
  for s in /tmp/t53-bin-new /tmp/t141p-bin /tmp/t141-bin /tmp/t53-bin-old; do
    printf '%s\t%s\t%s\n' "$s/juicefs" \
      "$(readlink -f "$s/juicefs" 2>/dev/null || echo MISSING)" INFO >> "$out"
  done
  if grep -q MISMATCH "$out"; then
    grep MISMATCH "$out" >&2
    die "frozen-object gate S04/S18 failed"
  fi
  echo "FROZEN_PASS"
}

# ------------------------------------------------------------------ ceph

cmd_ceph() {
  local out=$1
  {
    echo "# $(date -Is) epoch=$(date +%s)"
    echo "health: $(sudo ceph health 2>/dev/null || echo ERROR)"
    echo "osd_stat: $(sudo ceph osd stat 2>/dev/null || echo ERROR)"
    sudo ceph pg dump pgs_brief 2>/dev/null | python3 -c '
import sys, collections
prim = collections.Counter(); nonclean = 0; total = 0
for line in sys.stdin:
    f = line.split()
    if len(f) < 5 or "." not in f[0]:
        continue
    total += 1
    if f[1] != "active+clean":
        nonclean += 1
    try:
        prim[int(f[-2] if f[-2].isdigit() else f[-1])] += 1
    except ValueError:
        pass
print("pg_count=%d nonclean=%d" % (total, nonclean))
print("primary=[%s]" % " ".join("%d:%d" % (k, prim[k]) for k in sorted(prim)))
' 2>/dev/null || echo "pg parse failed"
  } > "$out"
  local h
  h=$(awk -F': ' '/^health:/{print $2}' "$out")
  # D31: accept both HEALTH_OK and "HEALTH OK"
  [[ $h == HEALTH_OK || $h == "HEALTH OK" ]] || die "S17 ceph health=$h"
  grep -q 'nonclean=0' "$out" || die "S17 PG not all active+clean"
  echo "CEPH_PASS health=$h"
}

# ------------------------------------------------------------------ resolve

cmd_resolve() {
  local shim=$1
  local expect=$2
  local out=$3
  local resolved real got
  resolved=$(PATH="${shim}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    command -v juicefs || true)
  [[ -n $resolved ]] || die "S09b: juicefs not resolvable via $shim"
  [[ $resolved == "${shim}/juicefs" ]] \
    || die "S09b: juicefs resolved to '$resolved', expected ${shim}/juicefs"
  real=$(readlink -f "$resolved")
  got=$(md5sum "$real" | awk '{print $1}')
  printf 'shim=%s\nresolved=%s\nreal=%s\nmd5=%s\nexpect=%s\n' \
    "$shim" "$resolved" "$real" "$got" "$expect" | tee "$out"
  [[ $got == "$expect" ]] || die "S09b: md5 $got != expected $expect"
  echo "ARM_RESOLVE_PASS"
}

# ------------------------------------------------------------------ selftest

self_test() {
  local fails=()
  ck() { if eval "$2"; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; fails+=("$1"); fi; }

  # NOTE: static red-line / forbidden-token scanning deliberately lives in
  # u141b-gate0.sh, NOT here.  A script cannot grep itself for a forbidden
  # token list that is stored inside itself -- the list always matches.
  # gate0 scans the other scripts and excludes itself from the scan set.

  echo "=== objects parser rejects non-numeric (D09) ==="
  local t rc
  t=$(mktemp)
  set +e
  awk -F'\t' 'NF!=3 || $1 !~ /^[0-9]+$/ {exit 1}' <<<"1.3	3	26" >/dev/null 2>&1
  rc=$?
  set -e
  ck "literal 'GiB'-style row rejected" "[[ $rc -ne 0 ]]"
  set +e
  awk -F'\t' 'NF!=3 || $1 !~ /^[0-9]+$/ {exit 1}' <<<"2434664	638352687104	28542710579200" >/dev/null 2>&1
  rc=$?
  set -e
  ck "valid numeric row accepted" "[[ $rc -eq 0 ]]"
  rm -f "$t"

  echo "=== mount gate fixture (S10/S11/S12) ==="
  local fp
  fp=$(mktemp)
  {
    echo "JuiceFS:juicefs-prod on /mnt/juicefs type fuse.juicefs (rw,max_read=262144)"
    echo "pid=111	exe_md5=${EXP_V14_MD5}	starttime=1	CEPH_CONF=${MSGR_CONF}	cmdline=x"
    echo "pid=222	exe_md5=${EXP_V14_MD5}	starttime=2	CEPH_CONF=${MSGR_CONF}	cmdline=x"
  } > "$fp"
  set +e
  ( cmd_gate_mount "$fp" "$EXP_V14_MD5" ) >/dev/null 2>&1
  rc=$?
  set -e
  ck "matching arm passes" "[[ $rc -eq 0 ]]"
  set +e
  ( cmd_gate_mount "$fp" "$EXP_V13_MD5" ) >/dev/null 2>&1
  rc=$?
  set -e
  ck "wrong arm md5 fails (S10)" "[[ $rc -ne 0 ]]"
  # one pid on the wrong binary must still fail -- head -1 would have hidden it
  sed -i '3s/exe_md5=[a-f0-9]*/exe_md5=deadbeefdeadbeefdeadbeefdeadbeef/' "$fp"
  set +e
  ( cmd_gate_mount "$fp" "$EXP_V14_MD5" ) >/dev/null 2>&1
  rc=$?
  set -e
  ck "second pid on wrong binary fails (D04)" "[[ $rc -ne 0 ]]"
  # missing max_read
  grep -v max_read "$fp" > "${fp}.2"
  set +e
  ( cmd_gate_mount "${fp}.2" "$EXP_V14_MD5" ) >/dev/null 2>&1
  rc=$?
  set -e
  ck "missing max_read fails (S12)" "[[ $rc -ne 0 ]]"
  rm -f "$fp" "${fp}.2"

  echo
  if [[ ${#fails[@]} -gt 0 ]]; then
    echo "U141B_COLLECT_SELFTEST: FAIL -> ${fails[*]}"
    return 1
  fi
  echo "U141B_COLLECT_SELFTEST: PASS"
}

# ------------------------------------------------------------------ dispatch

case "${1:-}" in
  --self-test) self_test ;;
  objects)     shift; cmd_objects "$@" ;;
  assets)      shift; cmd_assets "$@" ;;
  mount)       shift; cmd_mount "$@" ;;
  gate-mount)  shift; cmd_gate_mount "$@" ;;
  frozen)      shift; cmd_frozen "$@" ;;
  ceph)        shift; cmd_ceph "$@" ;;
  resolve)     shift; cmd_resolve "$@" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
