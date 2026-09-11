#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
"$ROOT/tests/offline-gate.sh"

scripts=(
  "$ROOT/deploy/scripts/t09-prepare-staging.sh"
  "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
  "$ROOT/deploy/scripts/t09-readonly-verify.sh"
  "$ROOT/deploy/scripts/t09-update-namespace.sh"
  "$ROOT/deploy/scripts/t09-rollback-namespace.sh"
)
units=(
  "$ROOT/deploy/systemd/juicefs-namespace-mount.service"
  "$ROOT/deploy/systemd/juicefs-namespace-collector.service"
  "$ROOT/deploy/systemd/juicefs-namespace-collector.timer"
  "$ROOT/deploy/systemd/juicefs-portal-t09-namespace.conf"
)
for path in "${scripts[@]}" "${units[@]}" "$ROOT/configs/namespace-roots.prod.json" "$ROOT/deploy/templates/namespace.env"; do
  [[ -f "$path" ]] || { printf 'missing T09 asset: %s\n' "$path" >&2; exit 1; }
done
for script in "${scripts[@]}"; do bash -n "$script"; done
python3 -m json.tool "$ROOT/configs/namespace-roots.prod.json" >/dev/null
grep -Fq 'tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod' "$ROOT/deploy/templates/namespace.env"

mount_unit=${units[0]}
collector_unit=${units[1]}
timer_unit=${units[2]}
portal_dropin=${units[3]}
grep -Fq -- 'mount --atime-mode noatime --cache-size 0 --backup-meta 0 --max-fuse-io 256K --log /dev/stderr' "$mount_unit"
! grep -Fq -- '--read-only' "$mount_unit"
! grep -Eq -- '(^|[[:space:]])-o[[:space:]]+(allow_other|allow_root)|--allow-other|--allow-root' "$mount_unit"
grep -Fq 'DeviceAllow=/dev/fuse rw' "$mount_unit"
! grep -Eq '^(PrivateTmp|PrivateMounts|ProtectSystem|NoNewPrivileges|RestrictAddressFamilies|LockPersonality)=' "$mount_unit"
for address in \
  10.20.1.150/32 10.20.1.151/32 10.20.1.152/32 \
  10.3.1.6/32 10.3.1.7/32 10.3.1.8/32; do
  grep -Fxq "IPAddressAllow=$address" "$mount_unit"
done
! grep -Fq 'IPAddressAllow=10.3.2.' "$mount_unit"
grep -Fq "stat -Lc '%a %U:%G'" "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq "== '4755 root:root'" "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq 'fa2dc1bb00be297004cfa4fc82dab3a6d568042736f7eb5b6fd8de49804db2d1' "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq 'for host in 10.3.1.6 10.3.1.7 10.3.1.8; do' "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq '/dev/tcp/$host/3300' "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq 'runuser -u jfsportal -- test -r /etc/ceph/ceph.conf' "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq 'ceph auth get client.juicefs' "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq '/etc/ceph/ceph.client.juicefs.keyring' "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq 'install -o root -g jfsportal -m 0640 "$keyring_temp" /etc/ceph/ceph.client.juicefs.keyring' "$ROOT/deploy/scripts/t09-update-namespace.sh"
grep -Fq 'rollback stopped: client.juicefs keyring changed after install' "$ROOT/deploy/scripts/t09-rollback-namespace.sh"
grep -Fq "== '640 root:jfsportal'" "$ROOT/deploy/scripts/t09-readonly-verify.sh"
! rg -n 'client[.]admin[.]keyring.*(install|cp|chown|chmod)|(--name|auth get)[[:space:]]+client[.]admin' "${scripts[@]}" "${units[@]}"
grep -Fq 'MemoryMax=192M' "$collector_unit"
grep -Fq -- '-allow-writable-roots' "$collector_unit"
grep -Fq 'ReadWritePaths=/var/lib/juicefs-portal/portal /var/lib/juicefs-portal/namespace-mount' "$collector_unit"
grep -Fq 'maxSummaryEntries      = 100' "$ROOT/api/internal/namespacecollector/collector.go"
grep -Fq 'maxSummaryRowsPerRoot  = 10000' "$ROOT/api/internal/namespacecollector/collector.go"
grep -Fxq 'ExecCondition=/usr/bin/findmnt -rn -M /var/lib/juicefs-portal/namespace-mount' "$collector_unit"
! grep -Fq 'ConditionPathIsMountPoint=' "$collector_unit"
grep -Fq 'collector did not create namespace database' "$ROOT/deploy/scripts/t09-update-namespace.sh"
grep -Fq 'OnUnitActiveSec=60s' "$timer_unit"
grep -Fxq 'InaccessiblePaths=/var/lib/juicefs-portal/namespace-mount' "$portal_dropin"
grep -Fq 'systemctl show juicefs-portal.service -p InaccessiblePaths --value' "$ROOT/deploy/scripts/t09-readonly-verify.sh"
grep -Fq '/etc/systemd/system/juicefs-portal.service.d/50-t09-namespace.conf' "$ROOT/deploy/scripts/t09-readonly-preflight.sh"
grep -Fq 'portal-t09-namespace.sha256' "$ROOT/deploy/scripts/t09-rollback-namespace.sh"
for unit in "$mount_unit" "$timer_unit"; do ! grep -Fq '[Install]' "$unit"; done
! rg -n 'systemctl[[:space:]]+enable|umount[[:space:]].*-[lf]|rm[[:space:]]+-rf|mkfs|losetup|reboot|shutdown|ceph[[:space:]]+(config|osd|orch)|juicefs[[:space:]]+destroy' "${scripts[@]}" "${units[@]}"

if command -v systemd-analyze >/dev/null; then
  verify_output=$(systemd-analyze verify "${units[@]}" 2>&1) || verify_rc=$?
  verify_rc=${verify_rc:-0}
  if [[ $verify_rc -ne 0 ]]; then
    unexpected=$(grep -Ev '^(Failed to (turn off SO_PASSRIGHTS|enable SO_PASSCRED)|juicefs-namespace-(mount|collector)[.]service: Command /opt/juicefs-portal/bin/(juicefs-ro|juicefs-namespace-collector) is not executable:)' <<<"$verify_output" || true)
    [[ -z "$unexpected" ]] || { printf '%s\n' "$verify_output" >&2; exit "$verify_rc"; }
    printf 'T09_SYSTEMD_VERIFY_LIMITED reason=local_runtime_or_target_binary_unavailable\n'
  fi
fi
printf 'T09_OFFLINE_GATE_PASS scripts=%s units=%s no_boot_enable=true\n' "${#scripts[@]}" "${#units[@]}"
