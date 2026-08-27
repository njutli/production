#!/usr/bin/env bash
# Shared constants and guards for 03-22.  This file performs no mutation.
set -euo pipefail
export LC_ALL=C

T64_NODES=(10.20.1.150 10.20.1.151 10.20.1.152)
T64_PD_CLIENT_PORT=12379
T64_PD_PEER_PORT=12380
T64_TIKV_PORT=30160
T64_TIKV_STATUS_PORT=30180
T64_JUICEFS_BIN=/tmp/juicefs-03-8
T64_JUICEFS_MD5=de93563f11a5ff3bd94dd25a4e0283b1
T64_POOL=juicefs-data

t64_die() {
  printf 'E_T64\t%s\n' "$*" >&2
  exit 42
}

t64_check_run_id() {
  [[ ${1:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] ||
    t64_die 'RUN_ID must be YYYYMMDD-HHMMSS'
}

t64_check_cluster() {
  [[ ${1:-} == A || ${1:-} == B ]] || t64_die 'CLUSTER must be A or B'
}

t64_check_instance() {
  [[ ${1:-} =~ ^(SMOKE-[AB]2?|LAYOUT-CANARY-A|ARM-CANARY-A2?|SEED-(CANARY|FORMAL)|RESTORE-(CANARY|PREFLIGHT)|GC-(CANARY|PREFLIGHT)|G0[1-8]|R0[1-8])$ ]] ||
    t64_die 'INSTANCE is outside the frozen 03-22 lifecycle set'
}

t64_expected_cluster() {
  case ${1:-} in
    SMOKE-A|SMOKE-A2|LAYOUT-CANARY-A|ARM-CANARY-A|ARM-CANARY-A2|SEED-CANARY|SEED-FORMAL|RESTORE-CANARY|RESTORE-PREFLIGHT|GC-CANARY|GC-PREFLIGHT|G0[1-8]|R01|R04|R06|R07) printf A;;
    SMOKE-B|SMOKE-B2|R02|R03|R05|R08) printf B;;
    *) t64_die "no frozen cluster mapping for instance: ${1:-EMPTY}";;
  esac
}

t64_is_formal_arm() {
  [[ ${1:-} =~ ^R0[1-8]$ ]]
}

t64_seed_flavor() {
  case ${1:-} in
    SEED-CANARY|RESTORE-CANARY|GC-CANARY) printf canary;;
    SEED-FORMAL|RESTORE-PREFLIGHT|GC-PREFLIGHT|G0[1-8]|R0[1-8]) printf formal;;
    *) t64_die "instance has no seed flavor: ${1:-EMPTY}";;
  esac
}

t64_seed_name() {
  local run_id=$1 flavor=$2
  case "$flavor" in
    canary) printf 'jfs-t64-%s-seed-canary' "$run_id";;
    formal) printf 'jfs-t64-%s-seed' "$run_id";;
    *) t64_die "invalid seed flavor: $flavor";;
  esac
}

t64_seed_dir() {
  local run_id=$1 flavor=$2
  case "$flavor" in canary|formal) ;; *) t64_die "invalid seed flavor: $flavor";; esac
  printf '/tmp/production/opencode-t3.22-%s/seeds/%s' "$run_id" "$flavor"
}

t64_proc_ppid() {
  local pid=${1:-}
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
  awk '{
    line=$0
    sub(/^[0-9]+ \(/,"",line)
    if (!match(line,/\) [^)]*$/)) exit 1
    rest=substr(line,RSTART+2)
    n=split(rest,f,/[[:space:]]+/)
    if (n<2 || f[2] !~ /^[0-9]+$/) exit 1
    print f[2]
  }' "/proc/$pid/stat"
}

# Input is newline-separated "PID<TAB>PPID" pairs. A JuiceFS `mount -d`
# daemon may retain both a parent and its worker child; the worker is the
# candidate whose PPID is another candidate. A single-process implementation
# is also accepted, while all ambiguous topologies are rejected.
t64_select_child_pid() {
  local pairs=${1:-} pid ppid selected='' total=0 children=0
  local -A present=()
  [[ -n "$pairs" ]] || t64_die 'no mount PID candidate'
  while IFS=$'\t' read -r pid ppid; do
    [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ ]] || t64_die 'invalid PID/PPID candidate row'
    [[ ! ${present[$pid]+exists} ]] || t64_die "duplicate PID candidate: $pid"
    present[$pid]=1
    total=$((total + 1))
  done <<< "$pairs"
  (( total >= 1 )) || t64_die 'no mount PID candidate'
  if (( total == 1 )); then
    printf '%s\n' "${!present[@]}"
    return
  fi
  while IFS=$'\t' read -r pid ppid; do
    if [[ ${present[$ppid]+exists} ]]; then
      selected=$pid
      children=$((children + 1))
    fi
  done <<< "$pairs"
  (( children == 1 )) || t64_die "ambiguous mount PID topology: candidates=$total children=$children"
  printf '%s\n' "$selected"
}

t64_nul_file_has_exact_arg() {
  local file=${1:-} expected=${2:-}
  [[ -r "$file" && -n "$expected" ]] || return 1
  python3 - "$file" "$expected" <<'PY'
from pathlib import Path
import os, sys
data = Path(sys.argv[1]).read_bytes()
expected = os.fsencode(sys.argv[2])
body = data.rstrip(b"\0")
if b"\0" in body:
    args = body.split(b"\0")
    ok = expected in args
else:
    # Some JuiceFS/Go daemon workers rewrite argv into one process-title
    # string. Fallback is safe only for the no-whitespace META/MNT tokens used
    # here; it remains exact-token matching, never substring matching.
    if any(c in expected for c in b" \t\r\n\v\f"):
        ok = False
    else:
        ok = expected in body.split()
raise SystemExit(0 if ok else 1)
PY
}

t64_status_identity() {
  local file=${1:-}
  [[ -s "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
s = d.get("Setting")
assert isinstance(s, dict), d
uuid = s.get("UUID")
name = s.get("Name")
assert isinstance(uuid, str) and re.fullmatch(r"[0-9a-f-]{16,}", uuid), s
assert isinstance(name, str) and name, s
print(f"{uuid}\t{name}")
PY
}

t64_status_has_zero_sessions() {
  local file=${1:-}
  [[ -s "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("Sessions")
assert isinstance(s, list) and len(s) == 0, s
PY
}

t64_gc_summary() {
  local file=${1:-}
  [[ -s "$file" ]] || return 1
  python3 - "$file" <<'PY'
import re, sys
s = open(sys.argv[1], errors="replace").read()
p = re.compile(
    r"scanned (\d+) objects, (\d+) valid, (\d+) pending delete \((\d+) bytes\), "
    r"(\d+) compacted \((\d+) bytes\), (\d+) leaked \((\d+) bytes\), "
    r"(\d+) delslices \((\d+) bytes\), (\d+) delfiles \((\d+) bytes\), "
    r"(\d+) skipped \((\d+) bytes\)")
m = p.search(s)
assert m, "JuiceFS gc summary line not found"
keys = ("scanned", "valid", "pending", "pending_bytes", "compacted",
        "compacted_bytes", "leaked", "leaked_bytes", "delslices",
        "delslices_bytes", "delfiles", "delfiles_bytes", "skipped",
        "skipped_bytes")
for key, value in zip(keys, m.groups()):
    print(f"{key}\t{value}")
PY
}

t64_cluster_lower() {
  case "$1" in A) printf a;; B) printf b;; *) t64_die 'invalid cluster';; esac
}

t64_node_suffix() {
  case "$1" in
    10.20.1.150) printf 150;;
    10.20.1.151) printf 151;;
    10.20.1.152) printf 152;;
    *) t64_die "unexpected node: $1";;
  esac
}

t64_assert_abs_scoped_path() {
  local path=${1:-} run_id=${2:-}
  [[ -n "$path" && "$path" == /* && "$path" != / ]] ||
    t64_die "unsafe path: ${path:-EMPTY}"
  case "$path" in
    /mnt/jfs-t64-"$run_id"-*|/tmp/jfs-t64-"$run_id"-*) ;;
    *) t64_die "path outside t64 RUN_ID scope: $path";;
  esac
}

t64_require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || t64_die "missing tool: $tool"
  done
}

t64_require_ssh_password() {
  [[ -n ${T64_SSH_PASSWORD:-} ]] ||
    t64_die 'set T64_SSH_PASSWORD in the executor shell; the scripts contain no password'
  export SSHPASS=$T64_SSH_PASSWORD
}

t64_make_ssh_array() {
  t64_require_ssh_password
  T64_SSH=(sshpass -e ssh
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o BatchMode=no
    -o ConnectTimeout=8
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2)
  T64_SCP=(sshpass -e scp
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o BatchMode=no
    -o ConnectTimeout=8)
}

t64_meta_url() {
  local run_id=$1 instance=$2
  printf 'tikv://10.20.1.150:%s,10.20.1.151:%s,10.20.1.152:%s/jfs-t64-%s-%s' \
    "$T64_PD_CLIENT_PORT" "$T64_PD_CLIENT_PORT" "$T64_PD_CLIENT_PORT" \
    "$run_id" "${instance,,}"
}
