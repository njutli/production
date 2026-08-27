#!/usr/bin/env bash
# Remote fixed-schema sampler for 03-20B-R2.
# Runs on a TiKV node.  It never changes remote state.
set -euo pipefail
export LC_ALL=C

die() {
  printf 'E_REMOTE_SAMPLER\t%s\n' "$*" >&2
  exit 42
}

parse_iostat() {
  awk '
    function fatal(msg) { print "E_IOSTAT_SCHEMA\t" msg > "/dev/stderr"; exit 42 }
    /^Device/ {
      delete col
      for (i = 1; i <= NF; i++) {
        name = $i
        sub(/:$/, "", name)
        col[name] = i
      }
      rk = col["rkB/s"] ? col["rkB/s"] : col["rKB/s"]
      wk = col["wkB/s"] ? col["wkB/s"] : col["wKB/s"]
      ra = col["r_await"]
      wa = col["w_await"]
      aq = col["aqu-sz"] ? col["aqu-sz"] : col["avgqu-sz"]
      ut = col["%util"]
      if (!rk || !wk || !ra || !wa || !aq || !ut)
        fatal("required column missing")
      have_schema = 1
      next
    }
    have_schema && NF > 1 && $1 !~ /^(avg-cpu|Linux)$/ {
      if (NF < ut) fatal("short data row")
      printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", systime(), $1, $rk, $wk, $ra, $wa, $aq, $ut
      fflush()
      rows++
    }
    END {
      if (!have_schema) fatal("Device header not found")
      if (!rows) fatal("no device rows")
    }
  '
}

psi_total() {
  local file=$1 class=$2
  awk -v want="$class" '
    $1 == want {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^total=/) {
          sub(/^total=/, "", $i)
          if ($i ~ /^[0-9]+$/) { print $i; found=1; exit }
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

sample_host() {
  local tikv_pid=$1
  [[ "$tikv_pid" =~ ^[0-9]+$ ]] || die "invalid tikv pid"
  sudo test -r "/proc/$tikv_pid/stat" || die "tikv proc files unreadable"

  local next ts now delay cpu_line io_some io_full cpu_some
  local pid_utime pid_stime pid_start read_bytes write_bytes load1
  next=$(date +%s)
  while :; do
    ts=$(date +%s)
    cpu_line=$(awk '/^cpu /{for(i=2;i<=11;i++) printf "%s%s",$i,(i==11?ORS:OFS); exit}' /proc/stat) || die "proc stat"
    [[ $(awk '{print NF}' <<<"$cpu_line") -eq 10 ]] || die "proc stat field count"
    cpu_line=${cpu_line// /$'\t'}
    io_some=$(psi_total /proc/pressure/io some) || die "io some PSI"
    io_full=$(psi_total /proc/pressure/io full) || die "io full PSI"
    cpu_some=$(psi_total /proc/pressure/cpu some) || die "cpu some PSI"
    read -r pid_utime pid_stime pid_start < <(sudo awk '{print $14,$15,$22}' "/proc/$tikv_pid/stat") || die "tikv stat"
    read_bytes=$(sudo awk '$1=="read_bytes:"{print $2}' "/proc/$tikv_pid/io") || die "tikv read_bytes"
    write_bytes=$(sudo awk '$1=="write_bytes:"{print $2}' "/proc/$tikv_pid/io") || die "tikv write_bytes"
    load1=$(awk '{print $1}' /proc/loadavg) || die "loadavg"
    [[ "$io_some $io_full $cpu_some $pid_utime $pid_stime $pid_start $read_bytes $write_bytes" != *-* ]] || die "negative field"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ts" "$cpu_line" "$io_some" "$io_full" "$cpu_some" \
      "$pid_utime" "$pid_stime" "$pid_start" "$read_bytes" "$write_bytes" "$load1"

    next=$((next + 1))
    now=$(date +%s)
    if (( next > now )); then
      delay=$((next - now))
      sleep "$delay"
    else
      next=$now
    fi
  done
}

self_test() {
  local got
  got=$(
    printf '%s\n' \
      'Linux 5.15 host 08/23/26 x86_64' \
      'Device r/s rkB/s rrqm/s %rrqm r_await rareq-sz w/s wkB/s wrqm/s %wrqm w_await wareq-sz d/s dkB/s drqm/s %drqm d_await dareq-sz f/s f_await aqu-sz %util' \
      'nvme1n1 1 4 0 0 0.10 4 100 409600 0 0 8.50 4096 0 0 0 0 0 0 2 1.20 17.25 99.50' \
      | parse_iostat
  )
  awk -F '\t' '
    NF != 8 { exit 1 }
    $2 != "nvme1n1" || $3 != 4 || $4 != 409600 || $5 != 0.10 ||
    $6 != 8.50 || $7 != 17.25 || $8 != 99.50 { exit 1 }
  ' <<<"$got" || die "iostat header mapping self-test"

  if printf '%s\n' 'Device r/s wkB/s w_await %util' 'nvme1n1 1 4 1 90' \
      | parse_iostat >/dev/null 2>&1; then
    die "missing-column fixture unexpectedly passed"
  fi
  echo 't61 remote sampler self-test: PASS'
}

mode=${1:-}
case "$mode" in
  --self-test)
    self_test
    ;;
  --parse-iostat)
    parse_iostat
    ;;
  device)
    shift
    (( $# > 0 )) || die "device list empty"
    stdbuf -oL iostat -y -x -d 1 "$@" 2>&1 | parse_iostat
    ;;
  host)
    shift
    sample_host "${1:-}"
    ;;
  *)
    die "usage: $0 {device DEV...|host PID|--self-test|--parse-iostat}"
    ;;
esac
