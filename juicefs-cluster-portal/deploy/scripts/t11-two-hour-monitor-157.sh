#!/usr/bin/env bash
set -euo pipefail

RUN_DIR=${1:?usage: t11-two-hour-monitor-157.sh /tmp/jfsportal-t11-RUN_ID two-hour|continuous}
MODE=${2:-two-hour}
[[ $(hostname -s) == oneasia-c1-cpu-node10 ]]
[[ "$RUN_DIR" == /tmp/jfsportal-t11-* && -d "$RUN_DIR" && ! -L "$RUN_DIR" ]]
[[ -x "$RUN_DIR/t11-readonly-sample-152.sh" && ! -L "$RUN_DIR/t11-readonly-sample-152.sh" ]]
[[ "$MODE" == two-hour || "$MODE" == continuous ]]

log=$RUN_DIR/monitor.log
index=$RUN_DIR/samples.tsv
status=$RUN_DIR/final-status.txt
[[ ! -e "$log" && ! -e "$index" && ! -e "$status" ]]
printf 'sample\tepoch\trc\n' >"$index"

jfs_mount_before=$(findmnt -rn -M /mnt/juicefs)
[[ -n "$jfs_mount_before" ]]
failure_count=0
sample=0

sample_once() {
  local tasks
  printf '=== sample=%s epoch=%s ===\n' "$sample" "$epoch"
  [[ $(systemctl is-active juicefs-metrics-forwarder.service) == active ]] || return
  [[ $(systemctl is-enabled juicefs-metrics-forwarder.service 2>/dev/null || true) == disabled ]] || return
  [[ $(systemctl show juicefs-metrics-forwarder.service -p NRestarts --value) == 0 ]] || return
  tasks=$(systemctl show juicefs-metrics-forwarder.service -p TasksCurrent --value)
  [[ "$tasks" =~ ^[0-9]+$ && "$tasks" -le 32 ]] || return
  [[ $(findmnt -rn -M /mnt/juicefs) == "$jfs_mount_before" ]] || return
  timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=10 sunrise@10.20.1.152 \
    /usr/bin/bash /tmp/jfsportal-t11-monitor/t11-readonly-sample-152.sh || return
  printf 'SAMPLE_PASS sample=%s tasks=%s\n' "$sample" "$tasks"
}

while :; do
  epoch=$(date +%s)
  if sample_once >>"$log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\t%s\t%s\n' "$sample" "$epoch" "$rc" | tee -a "$index"
  if [[ $rc -ne 0 ]]; then
    failure_count=$((failure_count + 1))
  fi
  if [[ "$MODE" == two-hour && $sample -ge 24 ]]; then
    break
  fi
  if [[ $(stat -c '%s' "$log") -ge 16777216 ]]; then
    printf 'T11_MONITOR_STOP reason=log_size_cap failures=%s epoch=%s\n' "$failure_count" "$(date +%s)" | tee "$status"
    exit 2
  fi
  sample=$((sample + 1))
  for minute in 1 2 3 4 5; do
    sleep 60
    printf 'T11_MONITOR_HEARTBEAT mode=%s next_sample=%s wait_minute=%s epoch=%s\n' \
      "$MODE" "$sample" "$minute" "$(date +%s)"
  done
done

if [[ $failure_count -eq 0 ]]; then
  printf 'T11_TWO_HOUR_MONITOR_PASS samples=25 failures=0 completed_epoch=%s\n' "$(date +%s)" | tee "$status"
else
  printf 'T11_TWO_HOUR_MONITOR_FAIL samples=25 failures=%s completed_epoch=%s\n' "$failure_count" "$(date +%s)" | tee "$status"
  exit 1
fi
