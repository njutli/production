#!/usr/bin/env bash
# t60-remote-host-sampler.sh - runs ON TiKV node via persistent SSH
# Usage: t60-remote-host-sampler.sh device <dev1> [dev2 ...]
#        t60-remote-host-sampler.sh host <tikv_pid>
# Output: one TSV line per second to stdout, pure numeric

set -euo pipefail
mode=$1; shift

case "$mode" in
  device)
    # Continuous iostat, parse to TSV
    iostat -y -x -d 1 "$@" 2>/dev/null | while IFS= read -r line; do
      # Skip empty lines and header lines (containing "Device" or "r/s")
      [[ -z "$line" ]] && continue
      echo "$line" | grep -qE '^(Device|avg-cpu)' && continue
      # Parse iostat -x output: Device rrqm/s wrqm/s r/s w/s rkB/s wkB/s avgrq-sz avgqu-sz await r_await w_await %util
      ts=$(date +%s)
      dev=$(echo "$line" | awk '{print $1}')
      rest=$(echo "$line" | awk '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14}')
      printf "%s\t%s\t%s\n" "$ts" "$dev" "$rest"
    done
    ;;
  host)
    tikv_pid=$1
    while true; do
      ts=$(date +%s)
      # /proc/stat first line (cpu aggregate)
      cpu=$(head -1 /proc/stat 2>/dev/null | tr -s ' ' | cut -d' ' -f2-11)
      # /proc/pressure/io total
      io_psi=$(grep '^total=' /proc/pressure/io 2>/dev/null | cut -d= -f2 || echo "-1")
      # /proc/pressure/cpu total
      cpu_psi=$(grep '^total=' /proc/pressure/cpu 2>/dev/null | cut -d= -f2 || echo "-1")
      # /proc/<pid>/io
      pid_io=$(cat /proc/$tikv_pid/io 2>/dev/null | tr -s ' ' | tr '\n' '\t' || echo "-1")
      # /proc/<pid>/stat fields 14-17 (utime stime cutime cstime) and 22 (starttime)
      pid_stat=$(awk '{print $14,$15,$16,$17,$22}' /proc/$tikv_pid/stat 2>/dev/null || echo "-1 -1 -1 -1 -1")
      # /proc/loadavg
      load=$(head -1 /proc/loadavg 2>/dev/null || echo "0 0 0")
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$ts" "$cpu" "$io_psi" "$cpu_psi" "$pid_io" "$pid_stat" "$load"
      sleep 1
    done
    ;;
esac
