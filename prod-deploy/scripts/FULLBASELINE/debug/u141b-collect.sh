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
V4_BASE=${V4_BASE:-/tmp/FULLBASELINE_V4.sh}
MSGR_CONF=${MSGR_CONF:-/tmp/t141-msgr8.conf}
SYS_CEPH_CONF=${SYS_CEPH_CONF:-/etc/ceph/ceph.conf}
U141D_SCRUB_PAUSED=${U141D_SCRUB_PAUSED:-0}

# frozen expectations (task book §2.1 / §2.2)
EXP_V4_MD5_BASE=4198ea2676ba56744a3cd5eba17a5eab
EXP_V4_MD5_U141D=b79402c3ef1691dbf20eafd344f91c27
if [[ $U141D_SCRUB_PAUSED == 1 ]]; then
  EXP_V4_MD5=$EXP_V4_MD5_U141D
else
  EXP_V4_MD5=$EXP_V4_MD5_BASE
fi
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
  if [[ $U141D_SCRUB_PAUSED == 1 ]]; then
    f=$V4_BASE; exp=$EXP_V4_MD5_BASE
    if [[ -e $f ]]; then
      got=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
    else
      got=MISSING
    fi
    printf '%s\t%s\t%s\n' "$f" "$got" \
      "$([[ $got == "$exp" ]] && echo OK || echo MISMATCH)" >> "$out"
  fi
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

validate_ceph_snapshot() {
  local mode=$1 health_json=$2 osd_dump_json=$3 pgs_brief=$4
  [[ $mode == 0 || $mode == 1 ]] || die "invalid U141D_SCRUB_PAUSED=$mode (expected 0 or 1)"
  python3 - "$mode" "$health_json" "$osd_dump_json" "$pgs_brief" <<'PY'
import collections
import json
import re
import sys

mode, health_path, osd_path, pg_path = sys.argv[1:]
paused = mode == "1"
errors = []

with open(health_path, encoding="utf-8") as f:
    health = json.load(f)
with open(osd_path, encoding="utf-8") as f:
    osd_dump = json.load(f)

status = str(health.get("status", "MISSING"))
checks = health.get("checks", {})
if not isinstance(checks, dict):
    raise SystemExit("health checks is not an object")
check_keys = sorted(str(k) for k in checks)

raw_flags = osd_dump.get("flags", [])
if isinstance(raw_flags, str):
    flags = [x.strip() for x in raw_flags.split(",") if x.strip()]
elif isinstance(raw_flags, list):
    flags = [str(x).strip() for x in raw_flags if str(x).strip()]
else:
    raise SystemExit("unsupported OSD flags type: %s" % type(raw_flags).__name__)
flags = sorted(set(x.replace("nodeep_scrub", "nodeep-scrub") for x in flags))

osds = osd_dump.get("osds")
if not isinstance(osds, list) or not osds:
    errors.append("OSD dump has no osds array")
    osds = []
up = sum(1 for x in osds if x.get("up") == 1)
inside = sum(1 for x in osds if x.get("in") == 1)
if osds and (up != len(osds) or inside != len(osds)):
    errors.append("OSDs not all up/in: total=%d up=%d in=%d" % (len(osds), up, inside))

states = collections.Counter()
primaries = collections.Counter()
abnormal = []
with open(pg_path, encoding="utf-8", errors="replace") as f:
    for raw in f:
        fields = raw.split()
        if len(fields) < 2 or not re.fullmatch(r"[0-9]+\.[0-9a-fA-F]+", fields[0]):
            continue
        pgid, state = fields[0], fields[1]
        states[state] += 1
        if state != "active+clean":
            abnormal.append((pgid, state))
        if fields[-1].isdigit():
            primaries[int(fields[-1])] += 1

pg_count = sum(states.values())
scrubbing = sum(
    n for state, n in states.items()
    if "scrubbing" in state.split("+") or "deep" in state.split("+")
)
if pg_count <= 0:
    errors.append("no PG rows parsed")
if abnormal:
    errors.append("PGs not exact active+clean: count=%d" % len(abnormal))
if scrubbing:
    errors.append("active scrub/deep-scrub PGs=%d" % scrubbing)

if paused:
    missing = [x for x in ("noscrub", "nodeep-scrub") if x not in flags]
    if missing:
        errors.append("paused mode missing OSD flag(s): %s" % ",".join(missing))
    if not ((status == "HEALTH_OK" and not check_keys) or
            (status == "HEALTH_WARN" and check_keys == ["OSDMAP_FLAGS"])):
        errors.append("paused health must be HEALTH_OK/no-checks or HEALTH_WARN/OSDMAP_FLAGS-only")
else:
    if status != "HEALTH_OK" or check_keys:
        errors.append("strict health must be HEALTH_OK with no checks")

print("health: %s" % status)
print("health_check_keys=%s" % (",".join(check_keys) or "none"))
print("osd_flags=%s" % (",".join(flags) or "none"))
print("osd_count=%d up=%d in=%d" % (len(osds), up, inside))
print("pg_count=%d nonclean=%d scrubbing=%d" % (pg_count, len(abnormal), scrubbing))
print("pg_states=%s" % (",".join("%s:%d" % x for x in sorted(states.items())) or "none"))
print("primary=[%s]" % " ".join("%d:%d" % x for x in sorted(primaries.items())))
for pgid, state in abnormal:
    print("abnormal_pg=%s state=%s" % (pgid, state))
if errors:
    for error in errors:
        print("CEPH_SNAPSHOT_INVALID: " + error, file=sys.stderr)
    raise SystemExit(1)
PY
}

cmd_ceph() {
  local out=$1
  local health_json="${out}.health.json"
  local osd_dump_json="${out}.osd-dump.json"
  local pgs_brief="${out}.pgs-brief.txt"
  local parser_stderr="${out}.validate.stderr"
  [[ $U141D_SCRUB_PAUSED == 0 || $U141D_SCRUB_PAUSED == 1 ]] \
    || die "invalid U141D_SCRUB_PAUSED=$U141D_SCRUB_PAUSED"
  sudo ceph health detail --format json > "$health_json" 2>/dev/null \
    || die "S17 cannot collect health JSON"
  sudo ceph osd dump --format json > "$osd_dump_json" 2>/dev/null \
    || die "S17 cannot collect OSD dump JSON"
  sudo ceph pg dump pgs_brief > "$pgs_brief" 2>/dev/null \
    || die "S17 cannot collect pgs_brief"
  printf '# %s epoch=%s scrub_paused=%s\n' \
    "$(date -Is)" "$(date +%s)" "$U141D_SCRUB_PAUSED" > "$out"
  if ! validate_ceph_snapshot "$U141D_SCRUB_PAUSED" \
       "$health_json" "$osd_dump_json" "$pgs_brief" >> "$out" 2> "$parser_stderr"; then
    cat "$parser_stderr" >&2
    die "S17 Ceph snapshot gate failed; raw sidecars preserved for exact attribution"
  fi
  rm -f "$parser_stderr"
  echo "CEPH_PASS mode=$([[ $U141D_SCRUB_PAUSED == 1 ]] && echo scrub-paused || echo strict)"
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

  echo "=== exact Ceph snapshot gate (S17) ==="
  local health osd pg parsed
  health=$(mktemp); osd=$(mktemp); pg=$(mktemp); parsed=$(mktemp)
  printf '{"status":"HEALTH_OK","checks":{}}\n' > "$health"
  printf '{"flags":"sortbitwise","osds":[{"osd":0,"up":1,"in":1},{"osd":1,"up":1,"in":1}]}\n' > "$osd"
  printf 'PG_STAT STATE UP UP_PRIMARY ACTING ACTING_PRIMARY\n3.0 active+clean [0,1] 0 [0,1] 0\n' > "$pg"
  set +e
  ( validate_ceph_snapshot 0 "$health" "$osd" "$pg" ) > "$parsed" 2>&1
  rc=$?
  set -e
  ck "strict HEALTH_OK fixture passes" "[[ $rc -eq 0 ]] && grep -q 'pg_count=1 nonclean=0 scrubbing=0' '$parsed'"

  printf '{"status":"HEALTH_WARN","checks":{"OSDMAP_FLAGS":{"summary":{"message":"flags set"}}}}\n' > "$health"
  printf '{"flags":"sortbitwise,noscrub,nodeep_scrub","osds":[{"osd":0,"up":1,"in":1},{"osd":1,"up":1,"in":1}]}\n' > "$osd"
  set +e
  ( validate_ceph_snapshot 1 "$health" "$osd" "$pg" ) > "$parsed" 2>&1
  rc=$?
  set -e
  ck "paused OSDMAP_FLAGS-only fixture passes" "[[ $rc -eq 0 ]] && grep -q 'health_check_keys=OSDMAP_FLAGS' '$parsed'"

  printf '{"status":"HEALTH_WARN","checks":{"OSDMAP_FLAGS":{},"OSD_DOWN":{}}}\n' > "$health"
  set +e
  ( validate_ceph_snapshot 1 "$health" "$osd" "$pg" ) > "$parsed" 2>&1
  rc=$?
  set -e
  ck "paused mode rejects an additional health check" "[[ $rc -ne 0 ]]"

  printf '{"status":"HEALTH_WARN","checks":{"OSDMAP_FLAGS":{}}}\n' > "$health"
  printf '{"flags":"sortbitwise,noscrub","osds":[{"osd":0,"up":1,"in":1},{"osd":1,"up":1,"in":1}]}\n' > "$osd"
  set +e
  ( validate_ceph_snapshot 1 "$health" "$osd" "$pg" ) > "$parsed" 2>&1
  rc=$?
  set -e
  ck "paused mode requires both scrub flags" "[[ $rc -ne 0 ]]"

  printf '{"flags":"sortbitwise,noscrub,nodeep-scrub","osds":[{"osd":0,"up":1,"in":1},{"osd":1,"up":1,"in":1}]}\n' > "$osd"
  printf 'PG_STAT STATE UP UP_PRIMARY ACTING ACTING_PRIMARY\n3.a active+clean+scrubbing [0,1] 0 [0,1] 0\n' > "$pg"
  set +e
  ( validate_ceph_snapshot 1 "$health" "$osd" "$pg" ) > "$parsed" 2>&1
  rc=$?
  set -e
  ck "active scrub is rejected with PG identity preserved" \
    "[[ $rc -ne 0 ]] && grep -q 'abnormal_pg=3.a state=active+clean+scrubbing' '$parsed'"
  rm -f "$health" "$osd" "$pg" "$parsed"

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
