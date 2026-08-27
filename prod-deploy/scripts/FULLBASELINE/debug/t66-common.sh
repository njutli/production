#!/usr/bin/env bash
# Shared constants and guards for 03-22c.  This file performs no mutation.
set -euo pipefail
export LC_ALL=C

T66_NODES=(10.20.1.150 10.20.1.151 10.20.1.152)
T66_PD_CLIENT_PORT=12379
T66_PD_PEER_PORT=12380
T66_TIKV_PORT=30160
T66_TIKV_STATUS_PORT=30180
T66_JUICEFS_BIN=/tmp/juicefs-03-8
T66_JUICEFS_MD5=de93563f11a5ff3bd94dd25a4e0283b1
T66_POOL=juicefs-data

t66_die() {
  printf 'E_T66\t%s\n' "$*" >&2
  exit 42
}

t66_check_run_id() {
  [[ ${1:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] ||
    t66_die 'RUN_ID must be YYYYMMDD-HHMMSS'
}

t66_check_cluster() {
  [[ ${1:-} == B1c || ${1:-} == D1 ]] || t66_die 'CLUSTER must be B1c or D1'
}

t66_check_instance() {
  [[ ${1:-} =~ ^(SMOKE-(B1c|D1)|ARM-CANARY-(B1c|D1)|SEED-(CANARY|FORMAL)|RESTORE-(CANARY|PREFLIGHT)-(B1c|D1)|GC-(CANARY|PREFLIGHT|ARM-CANARY)|G0[1-8]|R0[1-8])$ ]] ||
    t66_die 'INSTANCE is outside the frozen 03-22c lifecycle set'
}

t66_expected_cluster() {
  case ${1:-} in
    SMOKE-B1c|ARM-CANARY-B1c|SEED-CANARY|SEED-FORMAL|RESTORE-CANARY-B1c|RESTORE-PREFLIGHT-B1c|GC-CANARY|GC-PREFLIGHT|GC-ARM-CANARY|G0[1-8]|R01|R04|R06|R07) printf B1c;;
    SMOKE-D1|ARM-CANARY-D1|RESTORE-CANARY-D1|RESTORE-PREFLIGHT-D1|R02|R03|R05|R08) printf D1;;
    *) t66_die "no frozen cluster mapping for instance: ${1:-EMPTY}";;
  esac
}

t66_is_formal_arm() {
  [[ ${1:-} =~ ^R0[1-8]$ ]]
}

t66_seed_flavor() {
  case ${1:-} in
    SEED-CANARY|RESTORE-CANARY-B1c|RESTORE-CANARY-D1|GC-CANARY) printf canary;;
    SEED-FORMAL|RESTORE-PREFLIGHT-B1c|RESTORE-PREFLIGHT-D1|ARM-CANARY-B1c|ARM-CANARY-D1|GC-PREFLIGHT|GC-ARM-CANARY|G0[1-8]|R0[1-8]) printf formal;;
    *) t66_die "instance has no seed flavor: ${1:-EMPTY}";;
  esac
}

t66_seed_name() {
  local run_id=$1 flavor=$2
  case "$flavor" in
    canary) printf 'jfs-t66-%s-seed-canary' "$run_id";;
    formal) printf 'jfs-t66-%s-seed' "$run_id";;
    *) t66_die "invalid seed flavor: $flavor";;
  esac
}

t66_seed_dir() {
  local run_id=$1 flavor=$2
  case "$flavor" in canary|formal) ;; *) t66_die "invalid seed flavor: $flavor";; esac
  printf '/tmp/production/opencode-t3.22c-%s/seeds/%s' "$run_id" "$flavor"
}

t66_proc_ppid() {
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
t66_filter_scoped_process_rows() {
  local token=${1:-} excluded=${2:-} ignore_literal=${3:-}
  [[ -n "$token" ]] || t66_die 'empty scoped-process token'
  awk -v token="$token" -v excluded="$excluded" -v ignore="$ignore_literal" '
    {
      pid=$1; line=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/,"",line)
      if(index(line,token)>0 && index(excluded," " pid " ")==0 && (ignore==""||index(line,ignore)==0)) print pid "\t" line
    }'
}

t66_scoped_runtime_process_rows() {
  local token=${1:-} ignore_literal=${2:-} cursor=${BASHPID:-$$} parent excluded pid args
  [[ -n "$token" ]] || t66_die 'empty scoped-process token'
  excluded=" $cursor "
  while (( cursor > 1 )); do
    parent=$(t66_proc_ppid "$cursor") || break
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
t66_select_child_pid() {
  local pairs=${1:-} pid ppid selected='' total=0 children=0
  local -A present=()
  [[ -n "$pairs" ]] || t66_die 'no mount PID candidate'
  while IFS=$'\t' read -r pid ppid; do
    [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ ]] || t66_die 'invalid PID/PPID candidate row'
    [[ ! ${present[$pid]+exists} ]] || t66_die "duplicate PID candidate: $pid"
    present[$pid]=1
    total=$((total + 1))
  done <<< "$pairs"
  (( total >= 1 )) || t66_die 'no mount PID candidate'
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
  (( children == 1 )) || t66_die "ambiguous mount PID topology: candidates=$total children=$children"
  printf '%s\n' "$selected"
}

t66_nul_file_has_exact_arg() {
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

t66_status_identity() {
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

t66_status_has_zero_sessions() {
  local file=${1:-}
  [[ -s "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("Sessions")
assert isinstance(s, list) and len(s) == 0, s
PY
}

t66_gc_summary() {
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

t66_cluster_lower() {
  case "$1" in B1c) printf b1c;; D1) printf d1;; *) t66_die 'invalid cluster';; esac
}

t66_node_suffix() {
  case "$1" in
    10.20.1.150) printf 150;;
    10.20.1.151) printf 151;;
    10.20.1.152) printf 152;;
    *) t66_die "unexpected node: $1";;
  esac
}

t66_assert_abs_scoped_path() {
  local path=${1:-} run_id=${2:-}
  [[ -n "$path" && "$path" == /* && "$path" != / ]] ||
    t66_die "unsafe path: ${path:-EMPTY}"
  case "$path" in
    /mnt/jfs-t66-"$run_id"|/mnt/jfs-t66-"$run_id"/*|/mnt/jfs-tikv/jfs-t66-"$run_id"-backing|/mnt/jfs-tikv/jfs-t66-"$run_id"-backing/*|/tmp/jfs-t66-"$run_id"-*|/tmp/production/opencode-t3.22c-"$run_id"|/tmp/production/opencode-t3.22c-"$run_id"/*) ;;
    *) t66_die "path outside t66 RUN_ID scope: $path";;
  esac
}

t66_assert_realpath_exact() {
  local path=${1:-} expected=${2:-} actual
  [[ -n "$path" && -n "$expected" ]] || t66_die 'empty path identity'
  actual=$(realpath -m -- "$path")
  [[ "$actual" == "$expected" ]] ||
    t66_die "path identity mismatch: input=$path actual=$actual expected=$expected"
  [[ ! -L "$path" ]] || t66_die "symlink is forbidden: $path"
}

t66_assert_no_production_overlap() {
  local candidate=${1:-} protected
  [[ -n "$candidate" ]] || t66_die 'empty candidate path'
  case "$candidate" in
    /mnt/jfs-tikv/jfs-t66-*-backing|/mnt/jfs-tikv/jfs-t66-*-backing/*|/mnt/jfs-t66-*|/mnt/jfs-t66-*/*|/tmp/jfs-t66-*|/tmp/jfs-t66-*/*) ;;
    *) t66_die "candidate is outside t66 data scopes: $candidate";;
  esac
  for protected in /mnt/jfs-tikv/data /mnt/jfs-tikv/wal /mnt/jfs-tikv/raft /opt/tikv /opt/pd /etc/systemd /var/lib/ceph; do
    [[ "$candidate" != "$protected" && "$candidate" != "$protected"/* &&
       "$protected" != "$candidate"/* ]] || t66_die "production path overlap: candidate=$candidate protected=$protected"
  done
}

t66_state_value() {
  local file=${1:-} key=${2:-}
  [[ -s "$file" && -n "$key" ]] || return 1
  awk -F '\t' -v key="$key" '$1==key{v=$2;n++} END{if(n==1)print v;else exit 1}' "$file"
}

t66_check_auth() {
  local actual=${1:-} expected=${2:-}
  [[ -n "$expected" && "$actual" == "$expected" ]] ||
    t66_die "authorization token mismatch; expected=$expected"
}

# Resolve argv[0] from an already captured command line.  Some production
# hosts deny an unprivileged readlink of /proc/PID/exe even though cmdline and
# the executable itself are readable.  Never allow that restriction to turn
# an empty executable/hash into an accepted production fingerprint.
t66_exe_from_cmdline() {
  local cmd=${1:-} arg resolved
  arg=${cmd%%[[:space:]]*}
  [[ -n "$arg" && "$arg" == /* && -f "$arg" && -r "$arg" && -x "$arg" ]] ||
    t66_die 'cannot resolve an absolute readable executable from production cmdline'
  resolved=$(readlink -f -- "$arg")
  [[ -n "$resolved" && "$resolved" == /* && -f "$resolved" && -r "$resolved" && -x "$resolved" ]] ||
    t66_die 'production executable canonical path is invalid'
  printf '%s\n' "$resolved"
}

t66_require_absent() {
  [[ -n ${1:-} && ! -e "$1" ]] || t66_die "path/state must be absent: ${1:-EMPTY}"
}

t66_record_authorization() {
  local run=${1:-} phase=${2:-} token=${3:-} ledger=${T66_AUTH_LEDGER:-/tmp/jfs-t66-${1:-INVALID}-authorization-ledger.tsv}
  t66_check_run_id "$run"; [[ -n "$phase" && -n "$token" ]] || t66_die 'cannot record empty authorization'
  t66_assert_abs_scoped_path "$ledger" "$run"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(hostname -f 2>/dev/null || hostname)" "$phase" "$token" "${BASH_SOURCE[1]:-unknown}" >> "$ledger"
}

t66_assert_allocated_file() {
  local file=${1:-} expected_bytes=${2:-} logical allocated du_actual du_apparent min_alloc
  [[ -f "$file" && ! -L "$file" && "$expected_bytes" =~ ^[0-9]+$ ]] ||
    t66_die "invalid allocated-file check: $file"
  logical=$(stat -Lc '%s' -- "$file")
  allocated=$(( $(stat -Lc '%b' -- "$file") * 512 ))
  du_actual=$(du -B1 -- "$file" | awk '{print $1}')
  du_apparent=$(du -B1 --apparent-size -- "$file" | awk '{print $1}')
  min_alloc=$((expected_bytes - 16 * 1024 * 1024))
  [[ "$logical" -eq "$expected_bytes" && "$du_apparent" -eq "$expected_bytes" && "$allocated" -ge "$min_alloc" && "$du_actual" -ge "$min_alloc" ]] ||
    t66_die "sparse/allocation mismatch: file=$file logical=$logical stat_allocated=$allocated du_actual=$du_actual apparent=$du_apparent expected=$expected_bytes"
  printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$logical" "$allocated" "$du_actual" "$du_apparent"
}

t66_capacity_pre_ok() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 768*1024*1024*1024 )); }
t66_capacity_post_ok() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 640*1024*1024*1024 )); }
t66_memory_pre_ok() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 128*1024*1024 )); }
t66_memory_runtime_ok() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 64*1024*1024 )); }
t66_b_logs_margin_ok() {
  [[ ${1:-} =~ ^[0-9]+$ && ${2:-} =~ ^[0-9]+$ ]] &&
    (( $1 >= 28*1024*1024*1024 && 2*($2+1024*1024*1024) <= $1 ))
}
t66_baseline_within_256m() {
  local d
  [[ ${1:-} =~ ^[0-9]+$ && ${2:-} =~ ^[0-9]+$ ]] || return 1
  d=$(($1-$2)); ((d<0)) && d=$((-d)); ((d<=256*1024*1024))
}

# A mounted ext4-on-loop over the long-running NVMe can show tiny journal or
# kernel writeback increments without foreground I/O.  Define a bounded idle
# profile instead of requiring the device counters to remain exactly frozen.
# Evidence is one header plus 61 one-second samples; only the final 30-second
# window is judged, with strict volume, spike, and inflight ceilings.
t66_nvme_quiet_evidence_ok() {
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
t66_validate_storage_contract_rows() {
  local file=${1:-} run=${2:-} node=${3:-} root mroot
  root="/mnt/jfs-tikv/jfs-t66-${run}-backing"; mroot="/mnt/jfs-t66-${run}"
  [[ -s "$file" ]] || return 1
  [[ $(awk -F '\t' '$1=="meta"{print $2}' "$file") == "$run" &&
     $(awk -F '\t' '$1=="node"{print $2}' "$file") == "$node" &&
     $(awk -F '\t' '$1=="backing_root"{print $2}' "$file") == "$root" &&
     $(awk -F '\t' '$1=="mount_root"{print $2}' "$file") == "$mroot" ]] || return 1
  awk -F '\t' -v r="$root" '
    $1=="allocated"{
      expected[$2]=($2=="kv"?103079215104:($2=="b1c-logs"?34359738368:0))
      path[$2]=r"/"($2=="kv"?"kv.img":"b1c-logs.img")
      if(expected[$2]==0||$3!=path[$2]||$4!=expected[$2]||$5!~/^[0-9]+$/||$6!~/^[0-9]+$/)bad=1
      seen[$2]++
    }
    END{exit bad||seen["kv"]!=1||seen["b1c-logs"]!=1}' "$file"
}

t66_validate_storage_partial_rows() {
  local file=${1:-} run=${2:-} node=${3:-} root mroot
  root="/mnt/jfs-tikv/jfs-t66-${run}-backing"; mroot="/mnt/jfs-t66-${run}"
  [[ -s "$file" ]] || return 1
  [[ $(awk -F '\t' '$1=="meta"{print $2}' "$file") == "$run" &&
     $(awk -F '\t' '$1=="node"{print $2}' "$file") == "$node" &&
     $(awk -F '\t' '$1=="backing_root"{print $2}' "$file") == "$root" &&
     $(awk -F '\t' '$1=="mount_root"{print $2}' "$file") == "$mroot" ]] || return 1
  awk -F '\t' -v r="$root" '
    $1=="file"{
      expected[$2]=($2=="kv"?103079215104:($2=="b1c-logs"?34359738368:0))
      path[$2]=r"/"($2=="kv"?"kv.img":"b1c-logs.img")
      if(expected[$2]==0||$3!=path[$2]||$4!=expected[$2]||$5!~/^[0-9]+$/||$6!~/^[0-9]+$/||seen[$2]++)bad=1
    }
    END{exit bad}' "$file"
}

t66_validate_activation_contract_rows() {
  local file=${1:-} run=${2:-} arm=${3:-} instance=${4:-} node=${5:-} mroot backing quiet_prefix pd_source
  [[ -s "$file" ]] || return 1
  mroot="/mnt/jfs-t66-${run}"; backing="/mnt/jfs-tikv/jfs-t66-${run}-backing"
  quiet_prefix="/tmp/jfs-t66-${run}-${arm}-${instance}-${node}-nvme-quiet-"
  pd_source="t66-pd-${run}-${instance,,}"
  [[ $(t66_state_value "$file" meta) == "$run" &&
     $(t66_state_value "$file" node) == "$node" &&
     $(t66_state_value "$file" arm) == "$arm" &&
     $(t66_state_value "$file" instance) == "$instance" &&
     $(t66_state_value "$file" mount_root) == "$mroot" ]] || return 1
  awk -F '\t' -v arm="$arm" -v instance="$instance" -v mroot="$mroot" -v backing="$backing" -v quiet_prefix="$quiet_prefix" -v pd_source="$pd_source" '
    function allowed(r){return r=="kv"||r=="logs"}
    function lower_arm(){return arm=="B1c"?"b1c":"d1"}
    function expected_backing(r){
      if(r=="kv")return backing"/kv.img"
      if(arm=="B1c")return backing"/b1c-logs.img"
      return mroot"/d1-"tolower(instance)"-logs-backing/t66-d1-logs.img"
    }
    function expected_mount(r){return mroot"/"lower_arm()"-"r}
    $1=="pd"{if(NF!=3||$2!=pd_source||$3!=mroot"/pd"||pd++)bad=1}
    $1=="memory_baseline"{if(NF!=5||$2!~/^[0-9]+$/||$3!~/^[0-9]+$/||$4!~/^[0-9]+$/||$5!~/^[0-9]+$/||memory++)bad=1}
    $1=="ram_logs"{
      if(NF!=4||arm!="D1"||$2!="t66-logs-" substr(pd_source,8)||
         $3!=mroot"/d1-"tolower(instance)"-logs-backing"||$4!="34359738368"||ram++)bad=1
    }
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
      roles_ok=(loops["kv"]==1&&loops["logs"]==1&&fs["kv"]==1&&fs["logs"]==1&&length(loops)==2&&length(fs)==2)
      for(r in loops)if(fs_loop[r]!=loop_for[r])bad=1
      if(quiet_summary_path!=quiet_path".summary")bad=1
      if(arm=="B1c"&&ram!=0)bad=1
      if(arm=="D1"&&ram!=1)bad=1
      exit bad||!roles_ok||pd!=1||memory!=1||quiet_rows!=1||quiet_summary_rows!=1||epochs!=1
    }' "$file"
}

t66_validate_activation_partial_rows() {
  local file=${1:-} run=${2:-} arm=${3:-} instance=${4:-} node=${5:-}
  [[ -s "$file" ]] || return 1
  [[ $(awk -F '\t' '$1=="meta"{print $2}' "$file") == "$run" &&
     $(awk -F '\t' '$1=="node"{print $2}' "$file") == "$node" &&
     $(awk -F '\t' '$1=="arm"{print $2}' "$file") == "$arm" &&
     $(awk -F '\t' '$1=="instance"{print $2}' "$file") == "$instance" ]] || return 1
  awk -F '\t' -v arm="$arm" '
    $1=="loop"{
      if($3!~/^\/dev\/loop[0-9]+$/||seen_loop[$3]++||role[$2]++)bad=1
      if($2!="kv"&&$2!="logs")bad=1
    }
    $1=="ram_logs"{if(arm!="D1"||ram++)bad=1}
    END{exit bad||(arm=="B1c"&&ram)}' "$file"
}

t66_incident_ledger() {
  local run=${1:-}; t66_check_run_id "$run"
  printf '/tmp/production/opencode-t3.22c-%s/control/incidents.tsv' "$run"
}

t66_record_incident() {
  local run=${1:-} phase=${2:-} instance=${3:-} severity=${4:-} symptom=${5:-} evidence=${6:-} action=${7:-} decision=${8:-}
  local ledger lock field seq
  t66_check_run_id "$run"
  [[ "$phase" =~ ^[A-Za-z0-9._-]+$ && "$instance" =~ ^[A-Za-z0-9._-]+$ && "$severity" =~ ^(INFO|WARN|ERROR|FATAL)$ ]] ||
    t66_die 'invalid incident identity fields'
  for field in "$symptom" "$evidence" "$action" "$decision"; do
    [[ -n "$field" && "$field" != *$'\t'* && "$field" != *$'\n'* ]] || t66_die 'incident fields must be nonempty single-line text'
  done
  ledger=$(t66_incident_ledger "$run"); lock="${ledger}.lock"
  mkdir -p "${ledger%/*}"
  exec 8>>"$lock"; flock -x 8
  if [[ ! -e "$ledger" ]]; then
    printf 'seq\tepoch_ns\thost\tphase\tinstance\tseverity\tsymptom\tevidence\taction\tdecision\tscript_sha256\n' > "$ledger"
  fi
  seq=$(awk 'END{print NR}' "$ledger")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$seq" "$(date +%s%N)" "$(hostname -f 2>/dev/null || hostname)" "$phase" "$instance" "$severity" \
    "$symptom" "$evidence" "$action" "$decision" "$(sha256sum "${BASH_SOURCE[1]}" | awk '{print $1}')" >> "$ledger"
  flock -u 8
}

t66_require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || t66_die "missing tool: $tool"
  done
}

t66_require_ssh_password() {
  [[ -n ${T66_SSH_PASSWORD:-} ]] ||
    t66_die 'set T66_SSH_PASSWORD in the executor shell; the scripts contain no password'
  export SSHPASS=$T66_SSH_PASSWORD
}

t66_make_ssh_array() {
  t66_require_ssh_password
  T66_SSH=(sshpass -e ssh
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o BatchMode=no
    -o ConnectTimeout=8
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2)
  T66_SCP=(sshpass -e scp
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o BatchMode=no
    -o ConnectTimeout=8)
}

t66_meta_url() {
  local run_id=$1 instance=$2
  printf 'tikv://10.20.1.150:%s,10.20.1.151:%s,10.20.1.152:%s/jfs-t66-%s-%s' \
    "$T66_PD_CLIENT_PORT" "$T66_PD_CLIENT_PORT" "$T66_PD_CLIENT_PORT" \
    "$run_id" "${instance,,}"
}
