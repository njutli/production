#!/usr/bin/env bash
# Shared constants and guards for 04-2.  This file performs no mutation.
set -euo pipefail
export LC_ALL=C

S04A1_NODES=(10.20.1.150 10.20.1.151 10.20.1.152)
S04A1_PD_CLIENT_PORT=12379
S04A1_PD_PEER_PORT=12380
S04A1_TIKV_PORT=30160
S04A1_TIKV_STATUS_PORT=30180
S04A1_JUICEFS_BIN=/tmp/juicefs-1.4.1-patched
S04A1_JUICEFS_MD5=24fae0852051c80ca571cb2f20275d46
S04A1_POOL=juicefs-data

s04a1_die() {
  printf 'E_S04A1\t%s\n' "$*" >&2
  exit 42
}

s04a1_check_run_id() {
  [[ ${1:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] ||
    s04a1_die 'RUN_ID must be YYYYMMDD-HHMMSS'
}

s04a1_check_cluster() {
  [[ ${1:-} == C || ${1:-} == L ]] || s04a1_die 'CLUSTER must be C or L'
}

s04a1_check_instance() {
  [[ ${1:-} =~ ^(SMOKE-(C|L)|ARM-CANARY-(C|L)|SEED-(CANARY|FORMAL)|RESTORE-(CANARY|PREFLIGHT)-(C|L)|GC-(CANARY|PREFLIGHT|ARM-CANARY(-(C|L))?)|G0[1-8]|R0[1-8])$ ]] ||
    s04a1_die 'INSTANCE is outside the frozen 04-2 lifecycle set'
}

s04a1_expected_cluster() {
  case ${1:-} in
    SMOKE-C|ARM-CANARY-C|SEED-CANARY|SEED-FORMAL|RESTORE-CANARY-C|RESTORE-PREFLIGHT-C|GC-CANARY|GC-PREFLIGHT|GC-ARM-CANARY|GC-ARM-CANARY-C|G01|G04|G06|G07|R01|R04|R06|R07) printf C;;
    SMOKE-L|ARM-CANARY-L|RESTORE-CANARY-L|RESTORE-PREFLIGHT-L|GC-ARM-CANARY-L|G02|G03|G05|G08|R02|R03|R05|R08) printf L;;
    *) s04a1_die "no frozen cluster mapping for instance: ${1:-EMPTY}";;
  esac
}

s04a1_is_formal_arm() {
  [[ ${1:-} =~ ^R0[1-8]$ ]]
}

s04a1_seed_flavor() {
  case ${1:-} in
    SEED-CANARY|RESTORE-CANARY-C|RESTORE-CANARY-L|GC-CANARY) printf canary;;
    SEED-FORMAL|RESTORE-PREFLIGHT-C|RESTORE-PREFLIGHT-L|ARM-CANARY-C|ARM-CANARY-L|GC-PREFLIGHT|GC-ARM-CANARY|GC-ARM-CANARY-C|GC-ARM-CANARY-L|G0[1-8]|R0[1-8]) printf formal;;
    *) s04a1_die "instance has no seed flavor: ${1:-EMPTY}";;
  esac
}

s04a1_seed_name() {
  local run_id=$1 flavor=$2
  case "$flavor" in
    canary) printf 'jfs-s04a1-%s-seed-canary' "$run_id";;
    formal) printf 'jfs-s04a1-%s-seed' "$run_id";;
    *) s04a1_die "invalid seed flavor: $flavor";;
  esac
}

s04a1_seed_dir() {
  local run_id=$1 flavor=$2
  case "$flavor" in canary|formal) ;; *) s04a1_die "invalid seed flavor: $flavor";; esac
  printf '/tmp/production/opencode-04-2-%s/seeds/%s' "$run_id" "$flavor"
}

s04a1_proc_ppid() {
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
s04a1_filter_scoped_process_rows() {
  local token=${1:-} excluded=${2:-} ignore_literal=${3:-}
  [[ -n "$token" ]] || s04a1_die 'empty scoped-process token'
  awk -v token="$token" -v excluded="$excluded" -v ignore="$ignore_literal" '
    {
      pid=$1; line=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/,"",line)
      if(index(line,token)>0 && index(excluded," " pid " ")==0 && (ignore==""||index(line,ignore)==0)) print pid "\t" line
    }'
}

s04a1_scoped_runtime_process_rows() {
  local token=${1:-} ignore_literal=${2:-} cursor=${BASHPID:-$$} parent excluded pid args
  [[ -n "$token" ]] || s04a1_die 'empty scoped-process token'
  excluded=" $cursor "
  while (( cursor > 1 )); do
    parent=$(s04a1_proc_ppid "$cursor") || break
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
s04a1_select_child_pid() {
  local pairs=${1:-} pid ppid selected='' total=0 children=0
  local -A present=()
  [[ -n "$pairs" ]] || s04a1_die 'no mount PID candidate'
  while IFS=$'\t' read -r pid ppid; do
    [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ ]] || s04a1_die 'invalid PID/PPID candidate row'
    [[ ! ${present[$pid]+exists} ]] || s04a1_die "duplicate PID candidate: $pid"
    present[$pid]=1
    total=$((total + 1))
  done <<< "$pairs"
  (( total >= 1 )) || s04a1_die 'no mount PID candidate'
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
  (( children == 1 )) || s04a1_die "ambiguous mount PID topology: candidates=$total children=$children"
  printf '%s\n' "$selected"
}

s04a1_nul_file_has_exact_arg() {
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

s04a1_status_identity() {
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

s04a1_status_has_zero_sessions() {
  local file=${1:-}
  [[ -s "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("Sessions")
assert isinstance(s, list) and len(s) == 0, s
PY
}

s04a1_gc_summary() {
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

s04a1_cluster_lower() {
  case "$1" in C) printf c;; L) printf l;; *) s04a1_die 'invalid cluster';; esac
}

s04a1_node_suffix() {
  case "$1" in
    10.20.1.150) printf 150;;
    10.20.1.151) printf 151;;
    10.20.1.152) printf 152;;
    *) s04a1_die "unexpected node: $1";;
  esac
}

s04a1_assert_abs_scoped_path() {
  local path=${1:-} run_id=${2:-}
  [[ -n "$path" && "$path" == /* && "$path" != / ]] ||
    s04a1_die "unsafe path: ${path:-EMPTY}"
  case "$path" in
    /mnt/jfs-s04a1-"$run_id"|/mnt/jfs-s04a1-"$run_id"/*|\
    /mnt/jfs-tikv/jfs-s04a1-"$run_id"-l-backing|/mnt/jfs-tikv/jfs-s04a1-"$run_id"-l-backing/*|\
    /mnt/jfs-tikv/jfs-s04a1-"$run_id"-c-*-1[5][0-2]|\
    /mnt/jfs-tikv/jfs-s04a1-"$run_id"-c-*-1[5][0-2]/*|\
    /tmp/jfs-s04a1-"$run_id"-*|/tmp/production/opencode-04-2-"$run_id"|/tmp/production/opencode-04-2-"$run_id"/*) ;;
    *) s04a1_die "path outside s04a1 RUN_ID scope: $path";;
  esac
}

s04a1_assert_realpath_exact() {
  local path=${1:-} expected=${2:-} actual
  [[ -n "$path" && -n "$expected" ]] || s04a1_die 'empty path identity'
  actual=$(realpath -m -- "$path")
  [[ "$actual" == "$expected" ]] ||
    s04a1_die "path identity mismatch: input=$path actual=$actual expected=$expected"
  [[ ! -L "$path" ]] || s04a1_die "symlink is forbidden: $path"
}

s04a1_assert_no_production_overlap() {
  local candidate=${1:-} protected
  [[ -n "$candidate" ]] || s04a1_die 'empty candidate path'
  case "$candidate" in
    /mnt/jfs-tikv/jfs-s04a1-*-l-backing|/mnt/jfs-tikv/jfs-s04a1-*-l-backing/*|\
    /mnt/jfs-tikv/jfs-s04a1-*-c-*-1[5][0-2]|/mnt/jfs-tikv/jfs-s04a1-*-c-*-1[5][0-2]/*|\
    /mnt/jfs-s04a1-*|/mnt/jfs-s04a1-*/*|/tmp/jfs-s04a1-*|/tmp/jfs-s04a1-*/*) ;;
    *) s04a1_die "candidate is outside s04a1 data scopes: $candidate";;
  esac
  for protected in /mnt/jfs-tikv/data /mnt/jfs-tikv/wal /mnt/jfs-tikv/raft /opt/tikv /opt/pd /etc/systemd /var/lib/ceph; do
    [[ "$candidate" != "$protected" && "$candidate" != "$protected"/* &&
       "$protected" != "$candidate"/* ]] || s04a1_die "production path overlap: candidate=$candidate protected=$protected"
  done
}

s04a1_state_value() {
  local file=${1:-} key=${2:-}
  [[ -s "$file" && -n "$key" ]] || return 1
  awk -F '\t' -v key="$key" '$1==key{v=$2;n++} END{if(n==1)print v;else exit 1}' "$file"
}

s04a1_check_auth() {
  local actual=${1:-} expected=${2:-}
  [[ -n "$expected" && "$actual" == "$expected" ]] ||
    s04a1_die "authorization token mismatch; expected=$expected"
}

# Resolve argv[0] from an already captured command line.  Some production
# hosts deny an unprivileged readlink of /proc/PID/exe even though cmdline and
# the executable itself are readable.  Never allow that restriction to turn
# an empty executable/hash into an accepted production fingerprint.
s04a1_exe_from_cmdline() {
  local cmd=${1:-} arg resolved
  arg=${cmd%%[[:space:]]*}
  [[ -n "$arg" && "$arg" == /* && -f "$arg" && -r "$arg" && -x "$arg" ]] ||
    s04a1_die 'cannot resolve an absolute readable executable from production cmdline'
  resolved=$(readlink -f -- "$arg")
  [[ -n "$resolved" && "$resolved" == /* && -f "$resolved" && -r "$resolved" && -x "$resolved" ]] ||
    s04a1_die 'production executable canonical path is invalid'
  printf '%s\n' "$resolved"
}

s04a1_require_absent() {
  [[ -n ${1:-} && ! -e "$1" ]] || s04a1_die "path/state must be absent: ${1:-EMPTY}"
}

s04a1_record_authorization() {
  local run=${1:-} phase=${2:-} token=${3:-} ledger=${S04A1_AUTH_LEDGER:-/tmp/jfs-s04a1-${1:-INVALID}-authorization-ledger.tsv}
  s04a1_check_run_id "$run"; [[ -n "$phase" && -n "$token" ]] || s04a1_die 'cannot record empty authorization'
  s04a1_assert_abs_scoped_path "$ledger" "$run"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(hostname -f 2>/dev/null || hostname)" "$phase" "$token" "${BASH_SOURCE[1]:-unknown}" >> "$ledger"
}

s04a1_assert_allocated_file() {
  local file=${1:-} expected_bytes=${2:-} logical allocated du_actual du_apparent min_alloc
  [[ -f "$file" && ! -L "$file" && "$expected_bytes" =~ ^[0-9]+$ ]] ||
    s04a1_die "invalid allocated-file check: $file"
  logical=$(stat -Lc '%s' -- "$file")
  allocated=$(( $(stat -Lc '%b' -- "$file") * 512 ))
  du_actual=$(du -L -- "$file" | awk '{print $1}')
  du_apparent=$(du -L --apparent-size -- "$file" | awk '{print $1}')
  min_alloc=$((expected_bytes - 16 * 1024 * 1024))
  [[ "$logical" -eq "$expected_bytes" && "$du_apparent" -eq "$expected_bytes" && "$allocated" -ge "$min_alloc" && "$du_actual" -ge "$min_alloc" ]] ||
    s04a1_die "sparse/allocation mismatch: file=$file logical=$logical stat_allocated=$allocated du_actual=$du_actual apparent=$du_apparent expected=$expected_bytes"
  printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$logical" "$allocated" "$du_actual" "$du_apparent"
}

s04a1_capacity_pre_ok() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 768*1024*1024*1024 )); }
s04a1_capacity_post_ok() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 512*1024*1024*1024 )); }
s04a1_b_logs_margin_ok() {
  [[ ${1:-} =~ ^[0-9]+$ && ${2:-} =~ ^[0-9]+$ ]] &&
    (( $1 >= 28*1024*1024*1024 && 2*($2+1024*1024*1024) <= $1 ))
}
s04a1_baseline_within_256m() {
  local d
  [[ ${1:-} =~ ^[0-9]+$ && ${2:-} =~ ^[0-9]+$ ]] || return 1
  d=$(($1-$2)); ((d<0)) && d=$((-d)); ((d<=256*1024*1024))
}

# A mounted ext4-on-loop over the long-running NVMe can show tiny journal or
# kernel writeback increments without foreground I/O.  Define a bounded idle
# profile instead of requiring the device counters to remain exactly frozen.
# Evidence is one header plus 61 one-second samples; only the final 30-second
# window is judged, with strict volume, spike, and inflight ceilings.
s04a1_nvme_quiet_evidence_ok() {
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
s04a1_validate_storage_contract_rows() {
  local file=${1:-} run=${2:-} node=${3:-} root mroot
  root="/mnt/jfs-tikv/jfs-s04a1-${run}-backing"; mroot="/mnt/jfs-s04a1-${run}"
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

s04a1_validate_storage_partial_rows() {
  local file=${1:-} run=${2:-} node=${3:-} root mroot
  root="/mnt/jfs-tikv/jfs-s04a1-${run}-backing"; mroot="/mnt/jfs-s04a1-${run}"
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

s04a1_validate_activation_contract_rows() {
  local file=${1:-} run=${2:-} arm=${3:-} instance=${4:-} node=${5:-} mroot backing quiet_prefix pd_source
  [[ -s "$file" ]] || return 1
  mroot="/mnt/jfs-s04a1-${run}"; backing="/mnt/jfs-tikv/jfs-s04a1-${run}-backing"
  quiet_prefix="/tmp/jfs-s04a1-${run}-${arm}-${instance}-${node}-nvme-quiet-"
  pd_source="s04a1-pd-${run}-${instance,,}"
  [[ $(s04a1_state_value "$file" meta) == "$run" &&
     $(s04a1_state_value "$file" node) == "$node" &&
     $(s04a1_state_value "$file" arm) == "$arm" &&
     $(s04a1_state_value "$file" instance) == "$instance" &&
     $(s04a1_state_value "$file" mount_root) == "$mroot" ]] || return 1
  awk -F '\t' -v arm="$arm" -v mroot="$mroot" -v backing="$backing" -v quiet_prefix="$quiet_prefix" -v pd_source="$pd_source" '
    function allowed(r){return (arm=="C"&&r=="shared")||(arm=="L"&&(r=="kv"||r=="logs"))}
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
      if(arm=="C")roles_ok=(loops["shared"]==1&&fs["shared"]==1&&length(loops)==1&&length(fs)==1)
      else if(arm=="L")roles_ok=(loops["kv"]==1&&loops["logs"]==1&&fs["kv"]==1&&fs["logs"]==1&&length(loops)==2&&length(fs)==2)
      else roles_ok=0
      for(r in loops)if(fs_loop[r]!=loop_for[r])bad=1
      if(quiet_summary_path!=quiet_path".summary")bad=1
      exit bad||!roles_ok||pd!=1||quiet_rows!=1||quiet_summary_rows!=1||epochs!=1
    }' "$file"
}

s04a1_validate_activation_partial_rows() {
  local file=${1:-} run=${2:-} arm=${3:-} instance=${4:-} node=${5:-}
  [[ -s "$file" ]] || return 1
  [[ $(awk -F '\t' '$1=="meta"{print $2}' "$file") == "$run" &&
     $(awk -F '\t' '$1=="node"{print $2}' "$file") == "$node" &&
     $(awk -F '\t' '$1=="arm"{print $2}' "$file") == "$arm" &&
     $(awk -F '\t' '$1=="instance"{print $2}' "$file") == "$instance" ]] || return 1
  awk -F '\t' -v arm="$arm" '
    $1=="loop"{
      if($3!~/^\/dev\/loop[0-9]+$/||seen_loop[$3]++||role[$2]++)bad=1
      if(arm=="C"&&$2!="shared")bad=1
      if(arm=="L"&&$2!="kv"&&$2!="logs")bad=1
    }
    END{exit bad}' "$file"
}

s04a1_require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || s04a1_die "missing tool: $tool"
  done
}

# Accept an exact healthy cluster, or the single HEALTH_WARN produced by the
# task-owned noscrub+nodeep-scrub lease.  The caller must separately verify the
# lease state before/after each formal block; all other warning keys fail.
s04a1_ceph_health_test_ok() {
  local health status checks flags
  health=$(sudo ceph health detail --format json) || return 1
  IFS=$'\t' read -r status checks < <(printf '%s\n' "$health" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("%s\t%s" % (d.get("status", ""), ",".join(sorted(d.get("checks", {}))) or "none"))
') || return 1
  if [[ $status == HEALTH_OK && $checks == none ]]; then return 0; fi
  [[ $status == HEALTH_WARN && $checks == OSDMAP_FLAGS ]] || return 1
  flags=$(sudo ceph osd dump --format json | python3 -c '
import json,sys
v=json.load(sys.stdin).get("flags", [])
if isinstance(v,str): xs=v.split(",")
elif isinstance(v,list): xs=[str(x) for x in v]
else: raise SystemExit(1)
print(",".join(sorted({x.strip().replace("nodeep_scrub","nodeep-scrub") for x in xs if x.strip()})))
') || return 1
  [[ ,$flags, == *,noscrub,* && ,$flags, == *,nodeep-scrub,* ]]
}

s04a1_make_ssh_array() {
  S04A1_SSH=(ssh
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2)
  S04A1_SCP=(scp
    -o BatchMode=yes
    -o ConnectTimeout=8)
}

s04a1_meta_url() {
  local run_id=$1 instance=$2
  printf 'tikv://10.20.1.150:%s,10.20.1.151:%s,10.20.1.152:%s/jfs-s04a1-%s-%s' \
    "$S04A1_PD_CLIENT_PORT" "$S04A1_PD_CLIENT_PORT" "$S04A1_PD_CLIENT_PORT" \
    "$run_id" "${instance,,}"
}
