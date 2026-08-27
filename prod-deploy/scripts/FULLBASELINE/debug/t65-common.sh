#!/usr/bin/env bash
# Shared constants and guards for 03-22b.  This file performs no mutation.
set -euo pipefail
export LC_ALL=C

T65_NODES=(10.20.1.150 10.20.1.151 10.20.1.152)
T65_PD_CLIENT_PORT=12379
T65_PD_PEER_PORT=12380
T65_TIKV_PORT=30160
T65_TIKV_STATUS_PORT=30180
T65_JUICEFS_BIN=/tmp/juicefs-03-8
T65_JUICEFS_MD5=de93563f11a5ff3bd94dd25a4e0283b1
T65_POOL=juicefs-data

t65_die() {
  printf 'E_T65\t%s\n' "$*" >&2
  exit 42
}

t65_check_run_id() {
  [[ ${1:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] ||
    t65_die 'RUN_ID must be YYYYMMDD-HHMMSS'
}

t65_check_cluster() {
  [[ ${1:-} == A1 || ${1:-} == B1 ]] || t65_die 'CLUSTER must be A1 or B1'
}

t65_check_instance() {
  [[ ${1:-} =~ ^(SMOKE-(A1|B1)|ARM-CANARY-(A1|B1)|SEED-(CANARY|FORMAL)|RESTORE-(CANARY|PREFLIGHT)-(A1|B1)|GC-(CANARY|PREFLIGHT|ARM-CANARY)|G0[1-8]|R0[1-8])$ ]] ||
    t65_die 'INSTANCE is outside the frozen 03-22b lifecycle set'
}

t65_expected_cluster() {
  case ${1:-} in
    SMOKE-A1|ARM-CANARY-A1|SEED-CANARY|SEED-FORMAL|RESTORE-CANARY-A1|RESTORE-PREFLIGHT-A1|GC-CANARY|GC-PREFLIGHT|GC-ARM-CANARY|G0[1-8]|R01|R04|R06|R07) printf A1;;
    SMOKE-B1|ARM-CANARY-B1|RESTORE-CANARY-B1|RESTORE-PREFLIGHT-B1|R02|R03|R05|R08) printf B1;;
    *) t65_die "no frozen cluster mapping for instance: ${1:-EMPTY}";;
  esac
}

t65_is_formal_arm() {
  [[ ${1:-} =~ ^R0[1-8]$ ]]
}

t65_seed_flavor() {
  case ${1:-} in
    SEED-CANARY|RESTORE-CANARY-A1|RESTORE-CANARY-B1|GC-CANARY) printf canary;;
    SEED-FORMAL|RESTORE-PREFLIGHT-A1|RESTORE-PREFLIGHT-B1|ARM-CANARY-A1|ARM-CANARY-B1|GC-PREFLIGHT|GC-ARM-CANARY|G0[1-8]|R0[1-8]) printf formal;;
    *) t65_die "instance has no seed flavor: ${1:-EMPTY}";;
  esac
}

t65_seed_name() {
  local run_id=$1 flavor=$2
  case "$flavor" in
    canary) printf 'jfs-t65-%s-seed-canary' "$run_id";;
    formal) printf 'jfs-t65-%s-seed' "$run_id";;
    *) t65_die "invalid seed flavor: $flavor";;
  esac
}

t65_seed_dir() {
  local run_id=$1 flavor=$2
  case "$flavor" in canary|formal) ;; *) t65_die "invalid seed flavor: $flavor";; esac
  printf '/tmp/production/opencode-t3.22b-%s/seeds/%s' "$run_id" "$flavor"
}

t65_proc_ppid() {
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

# Filter `ps -eo pid=,args=` rows by a literal run token while excluding only
# the caller's PID ancestry.  This avoids a script rejecting itself merely
# because its scoped bundle path contains the run token, without hiding a
# concurrent sampler/cluster/volume script from the quiescence gate.
t65_filter_scoped_process_rows() {
  local token=${1:-} excluded=${2:-} ignore_literal=${3:-}
  [[ -n "$token" ]] || t65_die 'empty scoped-process token'
  awk -v token="$token" -v excluded="$excluded" -v ignore="$ignore_literal" '
    {
      pid=$1; line=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/,"",line)
      if(index(line,token)>0 && index(excluded," " pid " ")==0 && (ignore==""||index(line,ignore)==0)) print pid "\t" line
    }'
}

t65_scoped_runtime_process_rows() {
  local token=${1:-} ignore_literal=${2:-} cursor=${BASHPID:-$$} parent excluded pid args
  [[ -n "$token" ]] || t65_die 'empty scoped-process token'
  excluded=" $cursor "
  while (( cursor > 1 )); do
    parent=$(t65_proc_ppid "$cursor") || break
    [[ "$parent" =~ ^[0-9]+$ && "$parent" -ge 1 ]] || break
    [[ "$excluded" != *" $parent "* ]] || break
    excluded+="$parent "
    cursor=$parent
  done
  while read -r pid args; do
    [[ "$excluded" == *" $pid "* ]] && continue
    [[ -n "$ignore_literal" && "$args" == *"$ignore_literal"* ]] && continue
    [[ "$args" == *"$token"* ]] && printf '%s\t%s\n' "$pid" "$args"
  done < <(ps -eo pid=,args=)
  # "No matching runtime process" is a successful empty result.  Do not leak
  # the final conditional's status into command substitution under `set -e`.
  return 0
}

# Input is newline-separated "PID<TAB>PPID" pairs. A JuiceFS `mount -d`
# daemon may retain both a parent and its worker child; the worker is the
# candidate whose PPID is another candidate. A single-process implementation
# is also accepted, while all ambiguous topologies are rejected.
t65_select_child_pid() {
  local pairs=${1:-} pid ppid selected='' total=0 children=0
  local -A present=()
  [[ -n "$pairs" ]] || t65_die 'no mount PID candidate'
  while IFS=$'\t' read -r pid ppid; do
    [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ ]] || t65_die 'invalid PID/PPID candidate row'
    [[ ! ${present[$pid]+exists} ]] || t65_die "duplicate PID candidate: $pid"
    present[$pid]=1
    total=$((total + 1))
  done <<< "$pairs"
  (( total >= 1 )) || t65_die 'no mount PID candidate'
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
  (( children == 1 )) || t65_die "ambiguous mount PID topology: candidates=$total children=$children"
  printf '%s\n' "$selected"
}

t65_nul_file_has_exact_arg() {
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

t65_status_identity() {
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

t65_status_has_zero_sessions() {
  local file=${1:-}
  [[ -s "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("Sessions")
assert isinstance(s, list) and len(s) == 0, s
PY
}

t65_gc_summary() {
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

t65_cluster_lower() {
  case "$1" in A1) printf a1;; B1) printf b1;; *) t65_die 'invalid cluster';; esac
}

t65_node_suffix() {
  case "$1" in
    10.20.1.150) printf 150;;
    10.20.1.151) printf 151;;
    10.20.1.152) printf 152;;
    *) t65_die "unexpected node: $1";;
  esac
}

t65_assert_abs_scoped_path() {
  local path=${1:-} run_id=${2:-}
  [[ -n "$path" && "$path" == /* && "$path" != / ]] ||
    t65_die "unsafe path: ${path:-EMPTY}"
  case "$path" in
    /mnt/jfs-t65-"$run_id"|/mnt/jfs-t65-"$run_id"/*|/mnt/jfs-tikv/jfs-t65-"$run_id"-backing|/mnt/jfs-tikv/jfs-t65-"$run_id"-backing/*|/tmp/jfs-t65-"$run_id"-*|/tmp/production/opencode-t3.22b-"$run_id"|/tmp/production/opencode-t3.22b-"$run_id"/*) ;;
    *) t65_die "path outside t65 RUN_ID scope: $path";;
  esac
}

t65_assert_realpath_exact() {
  local path=${1:-} expected=${2:-} actual
  [[ -n "$path" && -n "$expected" ]] || t65_die 'empty path identity'
  actual=$(realpath -m -- "$path")
  [[ "$actual" == "$expected" ]] ||
    t65_die "path identity mismatch: input=$path actual=$actual expected=$expected"
  [[ ! -L "$path" ]] || t65_die "symlink is forbidden: $path"
}

t65_assert_no_production_overlap() {
  local candidate=${1:-} protected
  [[ -n "$candidate" ]] || t65_die 'empty candidate path'
  case "$candidate" in
    /mnt/jfs-tikv/jfs-t65-*-backing|/mnt/jfs-tikv/jfs-t65-*-backing/*|/mnt/jfs-t65-*|/mnt/jfs-t65-*/*|/tmp/jfs-t65-*|/tmp/jfs-t65-*/*) ;;
    *) t65_die "candidate is outside t65 data scopes: $candidate";;
  esac
  for protected in /mnt/jfs-tikv/data /mnt/jfs-tikv/wal /mnt/jfs-tikv/raft /opt/tikv /opt/pd /etc/systemd /var/lib/ceph; do
    [[ "$candidate" != "$protected" && "$candidate" != "$protected"/* &&
       "$protected" != "$candidate"/* ]] || t65_die "production path overlap: candidate=$candidate protected=$protected"
  done
}

t65_state_value() {
  local file=${1:-} key=${2:-}
  [[ -s "$file" && -n "$key" ]] || return 1
  awk -F '\t' -v key="$key" '$1==key{v=$2;n++} END{if(n==1)print v;else exit 1}' "$file"
}

t65_check_auth() {
  local actual=${1:-} expected=${2:-}
  [[ -n "$expected" && "$actual" == "$expected" ]] ||
    t65_die "authorization token mismatch; expected=$expected"
}

# Resolve argv[0] from an already captured command line.  Some production
# hosts deny an unprivileged readlink of /proc/PID/exe even though cmdline and
# the executable itself are readable.  Never allow that restriction to turn
# an empty executable/hash into an accepted production fingerprint.
t65_exe_from_cmdline() {
  local cmd=${1:-} arg resolved
  arg=${cmd%%[[:space:]]*}
  [[ -n "$arg" && "$arg" == /* && -f "$arg" && -r "$arg" && -x "$arg" ]] ||
    t65_die 'cannot resolve an absolute readable executable from production cmdline'
  resolved=$(readlink -f -- "$arg")
  [[ -n "$resolved" && "$resolved" == /* && -f "$resolved" && -r "$resolved" && -x "$resolved" ]] ||
    t65_die 'production executable canonical path is invalid'
  printf '%s\n' "$resolved"
}

t65_require_absent() {
  [[ -n ${1:-} && ! -e "$1" ]] || t65_die "path/state must be absent: ${1:-EMPTY}"
}

t65_record_authorization() {
  local run=${1:-} phase=${2:-} token=${3:-} ledger=${T65_AUTH_LEDGER:-/tmp/jfs-t65-${1:-INVALID}-authorization-ledger.tsv}
  t65_check_run_id "$run"; [[ -n "$phase" && -n "$token" ]] || t65_die 'cannot record empty authorization'
  t65_assert_abs_scoped_path "$ledger" "$run"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(hostname -f 2>/dev/null || hostname)" "$phase" "$token" "${BASH_SOURCE[1]:-unknown}" >> "$ledger"
}

t65_assert_allocated_file() {
  local file=${1:-} expected_bytes=${2:-} logical allocated du_actual du_apparent min_alloc
  [[ -f "$file" && ! -L "$file" && "$expected_bytes" =~ ^[0-9]+$ ]] ||
    t65_die "invalid allocated-file check: $file"
  logical=$(stat -Lc '%s' -- "$file")
  allocated=$(( $(stat -Lc '%b' -- "$file") * 512 ))
  du_actual=$(du -B1 -- "$file" | awk '{print $1}')
  du_apparent=$(du -B1 --apparent-size -- "$file" | awk '{print $1}')
  min_alloc=$((expected_bytes - 16 * 1024 * 1024))
  [[ "$logical" -eq "$expected_bytes" && "$du_apparent" -eq "$expected_bytes" && "$allocated" -ge "$min_alloc" && "$du_actual" -ge "$min_alloc" ]] ||
    t65_die "sparse/allocation mismatch: file=$file logical=$logical stat_allocated=$allocated du_actual=$du_actual apparent=$du_apparent expected=$expected_bytes"
  printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$logical" "$allocated" "$du_actual" "$du_apparent"
}

t65_capacity_pre_ok() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 768*1024*1024*1024 )); }
t65_capacity_post_ok() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 512*1024*1024*1024 )); }
t65_b_logs_margin_ok() {
  [[ ${1:-} =~ ^[0-9]+$ && ${2:-} =~ ^[0-9]+$ ]] &&
    (( $1 >= 28*1024*1024*1024 && 2*($2+1024*1024*1024) <= $1 ))
}
t65_baseline_within_256m() {
  local d
  [[ ${1:-} =~ ^[0-9]+$ && ${2:-} =~ ^[0-9]+$ ]] || return 1
  d=$(($1-$2)); ((d<0)) && d=$((-d)); ((d<=256*1024*1024))
}

# A mounted ext4-on-loop over the long-running NVMe can show tiny journal or
# kernel writeback increments without foreground I/O.  Define a bounded idle
# profile instead of requiring the device counters to remain exactly frozen.
# Evidence is one header plus 61 one-second samples; only the final 30-second
# window is judged, with strict volume, spike, and inflight ceilings.
t65_nvme_quiet_evidence_ok() {
  local file=${1:-}
  [[ -s "$file" ]] || return 1
  awk -F '\t' '
    NR==1{if($1!="epoch"||$2!="writes_completed"||$3!="sectors_written"||$4!="inflight")bad=1;next}
    {
      if($1!~/^[0-9]+$/||$2!~/^[0-9]+$/||$3!~/^[0-9]+$/||$4!~/^[0-9]+$/)bad=1
      if(data&&($1<=pe||$2<pw||$3<ps))bad=1
      if(NR>=32&&$4!=0)bad=1
      if(NR==32){e0=$1;w0=$2;s0=$3}
      if(NR>32){step=$3-ps;if(step>max_step)max_step=step}
      pe=$1;pw=$2;ps=$3;data++
    }
    END{
      dw=pw-w0;ds=ps-s0;duration=pe-e0
      if(NR!=62||duration<29||duration>45||dw>256||ds>8192||max_step>2048)bad=1
      if(bad)exit 1
      printf "QUIET_PROFILE_PASS\tduration_s=%d\tdelta_writes=%d\tdelta_sectors=%d\tdelta_bytes=%d\tmax_step_sectors=%d\n",duration,dw,ds,ds*512,max_step
    }' "$file"
}

# Text-only state contract validators are shared by runtime code and Gate 0.
# They never stat paths, inspect loops, or access the environment.
t65_validate_storage_contract_rows() {
  local file=${1:-} run=${2:-} node=${3:-} root mroot
  root="/mnt/jfs-tikv/jfs-t65-${run}-backing"; mroot="/mnt/jfs-t65-${run}"
  [[ -s "$file" ]] || return 1
  [[ $(awk -F '\t' '$1=="meta"{print $2}' "$file") == "$run" &&
     $(awk -F '\t' '$1=="node"{print $2}' "$file") == "$node" &&
     $(awk -F '\t' '$1=="backing_root"{print $2}' "$file") == "$root" &&
     $(awk -F '\t' '$1=="mount_root"{print $2}' "$file") == "$mroot" ]] || return 1
  awk -F '\t' -v r="$root" '
    $1=="allocated"{
      expected[$2]=($2=="a1-shared"?137438953472:($2=="b1-kv"?103079215104:($2=="b1-logs"?34359738368:0)))
      path[$2]=r"/"($2=="a1-shared"?"a1-shared.img":($2=="b1-kv"?"b1-kv.img":"b1-logs.img"))
      if(expected[$2]==0||$3!=path[$2]||$4!=expected[$2]||$5!~/^[0-9]+$/||$6!~/^[0-9]+$/)bad=1
      seen[$2]++
    }
    END{exit bad||seen["a1-shared"]!=1||seen["b1-kv"]!=1||seen["b1-logs"]!=1}' "$file"
}

t65_validate_storage_partial_rows() {
  local file=${1:-} run=${2:-} node=${3:-} root mroot
  root="/mnt/jfs-tikv/jfs-t65-${run}-backing"; mroot="/mnt/jfs-t65-${run}"
  [[ -s "$file" ]] || return 1
  [[ $(awk -F '\t' '$1=="meta"{print $2}' "$file") == "$run" &&
     $(awk -F '\t' '$1=="node"{print $2}' "$file") == "$node" &&
     $(awk -F '\t' '$1=="backing_root"{print $2}' "$file") == "$root" &&
     $(awk -F '\t' '$1=="mount_root"{print $2}' "$file") == "$mroot" ]] || return 1
  awk -F '\t' -v r="$root" '
    $1=="file"{
      expected[$2]=($2=="a1-shared"?137438953472:($2=="b1-kv"?103079215104:($2=="b1-logs"?34359738368:0)))
      path[$2]=r"/"($2=="a1-shared"?"a1-shared.img":($2=="b1-kv"?"b1-kv.img":"b1-logs.img"))
      if(expected[$2]==0||$3!=path[$2]||$4!=expected[$2]||$5!~/^[0-9]+$/||$6!~/^[0-9]+$/||seen[$2]++)bad=1
    }
    END{exit bad}' "$file"
}

t65_validate_activation_contract_rows() {
  local file=${1:-} run=${2:-} arm=${3:-} instance=${4:-} node=${5:-} mroot backing quiet_prefix pd_source
  [[ -s "$file" ]] || return 1
  mroot="/mnt/jfs-t65-${run}"; backing="/mnt/jfs-tikv/jfs-t65-${run}-backing"
  quiet_prefix="/tmp/jfs-t65-${run}-${arm}-${instance}-${node}-nvme-quiet-"
  pd_source="t65-pd-${run}-${instance,,}"
  [[ $(t65_state_value "$file" meta) == "$run" &&
     $(t65_state_value "$file" node) == "$node" &&
     $(t65_state_value "$file" arm) == "$arm" &&
     $(t65_state_value "$file" instance) == "$instance" &&
     $(t65_state_value "$file" mount_root) == "$mroot" ]] || return 1
  awk -F '\t' -v arm="$arm" -v mroot="$mroot" -v backing="$backing" -v quiet_prefix="$quiet_prefix" -v pd_source="$pd_source" '
    function allowed(r){return (arm=="A1"&&r=="shared")||(arm=="B1"&&(r=="kv"||r=="logs"))}
    function expected_backing(r){return backing"/"(r=="shared"?"a1-shared.img":(r=="kv"?"b1-kv.img":"b1-logs.img"))}
    function expected_mount(r){return mroot"/"(r=="shared"?"a1-shared":(r=="kv"?"b1-kv":"b1-logs"))}
    $1=="pd"{if(NF!=3||$2!=pd_source||$3!=mroot"/pd"||pd++)bad=1}
    $1=="loop"{
      if(NF!=6||!allowed($2)||$3!~/^\/dev\/loop[0-9]+$/||seen_loop[$3]++||loops[$2]++||
         $4!=expected_backing($2)||$5!=expected_mount($2)||$6!="attached")bad=1
      loop_for[$2]=$3
    }
    $1=="fs"{
      if(NF!=6||!allowed($2)||$3!~/^\/dev\/loop[0-9]+$/||length($4)!=36||$4!~/^[0-9A-Fa-f-]+$/||
         $5!~/^[0-9]+$/||$6!~/^[0-9]+$/||fs[$2]++)bad=1
      fs_loop[$2]=$3
    }
    $1=="quiet_evidence"{
      suffix=substr($2,length(quiet_prefix)+1); ident=substr(suffix,1,length(suffix)-4)
      if(NF!=2||index($2,quiet_prefix)!=1||substr(suffix,length(suffix)-3)!=".tsv"||length(ident)!=16||ident!~/^[0-9a-f]+$/||quiet_rows++)bad=1
      quiet_path=$2
    }
    $1=="quiet_summary"{if(NF!=2||quiet_summary_rows++)bad=1;quiet_summary_path=$2}
    $1=="activate_epoch"{if(NF!=2||$2!~/^[0-9]+$/||epochs++)bad=1}
    END{
      if(arm=="A1")roles_ok=(loops["shared"]==1&&fs["shared"]==1&&length(loops)==1&&length(fs)==1)
      else if(arm=="B1")roles_ok=(loops["kv"]==1&&loops["logs"]==1&&fs["kv"]==1&&fs["logs"]==1&&length(loops)==2&&length(fs)==2)
      else roles_ok=0
      for(r in loops)if(fs_loop[r]!=loop_for[r])bad=1
      if(quiet_summary_path!=quiet_path".summary")bad=1
      exit bad||!roles_ok||pd!=1||quiet_rows!=1||quiet_summary_rows!=1||epochs!=1
    }' "$file"
}

t65_validate_activation_partial_rows() {
  local file=${1:-} run=${2:-} arm=${3:-} instance=${4:-} node=${5:-}
  [[ -s "$file" ]] || return 1
  [[ $(awk -F '\t' '$1=="meta"{print $2}' "$file") == "$run" &&
     $(awk -F '\t' '$1=="node"{print $2}' "$file") == "$node" &&
     $(awk -F '\t' '$1=="arm"{print $2}' "$file") == "$arm" &&
     $(awk -F '\t' '$1=="instance"{print $2}' "$file") == "$instance" ]] || return 1
  awk -F '\t' -v arm="$arm" '
    $1=="loop"{
      if($3!~/^\/dev\/loop[0-9]+$/||seen_loop[$3]++||role[$2]++)bad=1
      if(arm=="A1"&&$2!="shared")bad=1
      if(arm=="B1"&&$2!="kv"&&$2!="logs")bad=1
    }
    END{exit bad}' "$file"
}

t65_require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || t65_die "missing tool: $tool"
  done
}

t65_require_ssh_password() {
  [[ -n ${T65_SSH_PASSWORD:-} ]] ||
    t65_die 'set T65_SSH_PASSWORD in the executor shell; the scripts contain no password'
  export SSHPASS=$T65_SSH_PASSWORD
}

t65_make_ssh_array() {
  t65_require_ssh_password
  T65_SSH=(sshpass -e ssh
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o BatchMode=no
    -o ConnectTimeout=8
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2)
  T65_SCP=(sshpass -e scp
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o BatchMode=no
    -o ConnectTimeout=8)
}

t65_meta_url() {
  local run_id=$1 instance=$2
  printf 'tikv://10.20.1.150:%s,10.20.1.151:%s,10.20.1.152:%s/jfs-t65-%s-%s' \
    "$T65_PD_CLIENT_PORT" "$T65_PD_CLIENT_PORT" "$T65_PD_CLIENT_PORT" \
    "$run_id" "${instance,,}"
}
