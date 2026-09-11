#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t10-fix-forwarder-gomaxprocs.sh /tmp/jfsportal-t10-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == oneasia-c1-cpu-node10 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t10-* && -d "$STAGING" && ! -L "$STAGING" ]] || {
  printf 'invalid staging\n' >&2
  exit 1
}

cd "$STAGING"
sha256sum -c SHA256SUMS >/dev/null
unit=$STAGING/systemd/juicefs-metrics-forwarder.service
target=/etc/systemd/system/juicefs-metrics-forwarder.service
expected_old=e700699e8587ada74c23faea157f1f33e7c7ced256a81774b46d3980ddbd3767
[[ -f "$unit" && ! -L "$unit" && -f "$target" && ! -L "$target" ]]
[[ $(sha256sum "$target" | awk '{print $1}') == "$expected_old" ]] || {
  printf 'installed unit drifted\n' >&2
  exit 1
}
grep -Fxq 'Environment=GOMAXPROCS=1' "$unit"
grep -Fxq 'TasksMax=32' "$unit"
[[ $(systemctl is-enabled juicefs-metrics-forwarder.service 2>/dev/null || true) == disabled ]]
systemctl is-active --quiet juicefs-metrics-forwarder.service

mount_before=$(findmnt -rn /mnt/juicefs)
juicefs_before=$(pgrep -f '^/tmp/juicefs-1[.]4[.]1-patched mount -d .* /mnt/juicefs$' | sort -n)
[[ -n "$mount_before" && -n "$juicefs_before" ]]

run_id=${STAGING##*/jfsportal-t10-}
backup_dir=/var/lib/juicefs-portal
backup=$backup_dir/juicefs-metrics-forwarder.service.t10-$run_id.bak
[[ ! -e "$backup" ]]
[[ ! -e "$backup_dir" || -d "$backup_dir" && ! -L "$backup_dir" ]]
install -d -o root -g root -m 0755 "$backup_dir"
install -o root -g root -m 0644 "$target" "$backup"

rollback() {
  local rc=$?
  trap - ERR
  printf 'T10_FORWARDER_FIX_FAIL rc=%s; restoring unit\n' "$rc" >&2
  install -o root -g root -m 0644 "$backup" "$target"
  systemctl daemon-reload
  systemctl restart juicefs-metrics-forwarder.service || true
  exit "$rc"
}
trap rollback ERR

install -o root -g root -m 0644 "$unit" "$target"
systemctl daemon-reload
systemctl restart juicefs-metrics-forwarder.service
sleep 2
systemctl is-active --quiet juicefs-metrics-forwarder.service
[[ $(systemctl is-enabled juicefs-metrics-forwarder.service 2>/dev/null || true) == disabled ]]
systemctl show juicefs-metrics-forwarder.service -p Environment --value | tr ' ' '\n' | grep -Fxq GOMAXPROCS=1
tasks=$(systemctl show juicefs-metrics-forwarder.service -p TasksCurrent --value)
[[ "$tasks" =~ ^[0-9]+$ && "$tasks" -le 16 ]]
[[ $(systemctl show juicefs-metrics-forwarder.service -p NRestarts --value) == 0 ]]
curl -fsS --connect-timeout 2 --max-time 8 http://127.0.0.1:9567/metrics >/dev/null
[[ $(findmnt -rn /mnt/juicefs) == "$mount_before" ]]
[[ $(pgrep -f '^/tmp/juicefs-1[.]4[.]1-patched mount -d .* /mnt/juicefs$' | sort -n) == "$juicefs_before" ]]

trap - ERR
printf 'T10_FORWARDER_FIX_PASS tasks=%s backup=%s enabled=false\n' "$tasks" "$backup"
