#!/usr/bin/env bash
set -euo pipefail

BACKUP=${1:?usage: t09-rollback-namespace.sh /var/lib/juicefs-portal/t09-backup-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$BACKUP" == /var/lib/juicefs-portal/t09-backup-* && -d "$BACKUP" && ! -L "$BACKUP" ]] || { printf 'invalid backup\n' >&2; exit 1; }
for file in juicefs-portal users.json portal.env index.html styles.css app.js pd.pid tikv.pid jfs-tikv.findmnt dbwal.findmnt; do
  [[ -f "$BACKUP/$file" && ! -L "$BACKUP/$file" ]] || { printf 'invalid backup file: %s\n' "$file" >&2; exit 1; }
done
keyring_target=/etc/ceph/ceph.client.juicefs.keyring
keyring_marker=$BACKUP/ceph.client.juicefs.keyring.sha256
portal_dropin=/etc/systemd/system/juicefs-portal.service.d/50-t09-namespace.conf
portal_dropin_marker=$BACKUP/portal-t09-namespace.sha256
if [[ -f "$keyring_marker" && ! -L "$keyring_marker" ]]; then
  expected_keyring_sha=$(<"$keyring_marker")
  [[ "$expected_keyring_sha" =~ ^[0-9a-f]{64}$ ]] || { printf 'invalid keyring marker\n' >&2; exit 1; }
  if [[ -e "$keyring_target" || -L "$keyring_target" ]]; then
    [[ -f "$keyring_target" && ! -L "$keyring_target" ]] || { printf 'refuse unexpected keyring target\n' >&2; exit 1; }
    [[ $(sha256sum "$keyring_target" | awk '{print $1}') == "$expected_keyring_sha" ]] || {
      printf 'rollback stopped: client.juicefs keyring changed after install\n' >&2
      exit 1
    }
  fi
fi
if [[ -f "$portal_dropin_marker" && ! -L "$portal_dropin_marker" ]]; then
  expected_dropin_sha=$(<"$portal_dropin_marker")
  [[ "$expected_dropin_sha" =~ ^[0-9a-f]{64}$ ]] || { printf 'invalid Portal drop-in marker\n' >&2; exit 1; }
  if [[ -e "$portal_dropin" || -L "$portal_dropin" ]]; then
    [[ -f "$portal_dropin" && ! -L "$portal_dropin" ]] || { printf 'refuse unexpected Portal drop-in target\n' >&2; exit 1; }
    [[ $(sha256sum "$portal_dropin" | awk '{print $1}') == "$expected_dropin_sha" ]] || {
      printf 'rollback stopped: Portal T09 drop-in changed after install\n' >&2
      exit 1
    }
  fi
fi

systemctl stop juicefs-namespace-collector.timer 2>/dev/null || true
systemctl stop juicefs-namespace-collector.service 2>/dev/null || true
systemctl stop juicefs-namespace-mount.service 2>/dev/null || true
if findmnt -rn /var/lib/juicefs-portal/namespace-mount >/dev/null 2>&1; then
  printf 'rollback stopped: namespace mount is still active; no installed files were removed\n' >&2
  exit 1
fi

systemctl stop juicefs-portal.service
install -o root -g root -m 0755 "$BACKUP/juicefs-portal" /opt/juicefs-portal/bin/juicefs-portal
install -o root -g root -m 0644 "$BACKUP/index.html" "$BACKUP/styles.css" "$BACKUP/app.js" /opt/juicefs-portal/web/
install -o root -g jfsportal -m 0640 "$BACKUP/users.json" /etc/juicefs-portal/users.json
install -o root -g jfsportal -m 0640 "$BACKUP/portal.env" /etc/juicefs-portal/portal.env
rm -f -- /var/lib/juicefs-portal/portal/namespace.db /var/lib/juicefs-portal/portal/namespace.db-shm /var/lib/juicefs-portal/portal/namespace.db-wal
rm -f -- /opt/juicefs-portal/bin/juicefs-ro /opt/juicefs-portal/bin/juicefs-namespace-collector
if [[ -f "$keyring_marker" ]]; then
  rm -f -- "$keyring_target" "$BACKUP/ceph.client.juicefs.keyring.new"
fi
rm -f -- /etc/juicefs-portal/namespace.env /etc/juicefs-portal/namespace-roots.json
rm -f -- /etc/systemd/system/juicefs-namespace-mount.service /etc/systemd/system/juicefs-namespace-collector.service /etc/systemd/system/juicefs-namespace-collector.timer
if [[ -f "$portal_dropin_marker" ]]; then
  rm -f -- "$portal_dropin"
  rmdir -- /etc/systemd/system/juicefs-portal.service.d 2>/dev/null || true
fi
systemctl daemon-reload
systemctl restart juicefs-portal.service
for _ in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8080/api/v1/health >/dev/null && break
  sleep 1
done
curl -fsS --max-time 5 http://127.0.0.1:8080/api/v1/health >/dev/null
cmp -s "$BACKUP/pd.pid" <(pgrep -xo pd-server)
cmp -s "$BACKUP/tikv.pid" <(pgrep -xo tikv-server)
cmp -s "$BACKUP/jfs-tikv.findmnt" <(findmnt -rn /mnt/jfs-tikv)
cmp -s "$BACKUP/dbwal.findmnt" <(findmnt -rn /mnt/dbwal)
printf 'T09_ROLLBACK_PASS backup=%s portal_restored=true business_unchanged=true\n' "$BACKUP"
