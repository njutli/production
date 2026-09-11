#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t09-readonly-preflight.sh /tmp/jfsportal-t09-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root to verify protected Portal state\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t09-* && -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging\n' >&2; exit 1; }
(
  cd "$STAGING"
  sha256sum -c SHA256SUMS >/dev/null
)

expected_portal=9a21615c1ad3c9abb14763c21ea9e219a2ed17fadf3338e02aec3d4232bad189
expected_index=9866628321973e85d6f673a478e90b70c7cba977ca55dcefbc08f1936434d0c9
expected_styles=c89d76472798096e9d94deb35c7724d1cbbe183ad5148bf8bb63532040912af4
expected_app=efc6cfeed574179575637e65f34431f0bd2bfcfac8e16888936e7494010c2aec
expected_unit=80d6808ca151c2cc946ab31d320c8daeb4270555847022db929e5737e8594c5f
[[ $(sha256sum /opt/juicefs-portal/bin/juicefs-portal | awk '{print $1}') == "$expected_portal" ]]
[[ $(sha256sum /opt/juicefs-portal/web/index.html | awk '{print $1}') == "$expected_index" ]]
[[ $(sha256sum /opt/juicefs-portal/web/styles.css | awk '{print $1}') == "$expected_styles" ]]
[[ $(sha256sum /opt/juicefs-portal/web/app.js | awk '{print $1}') == "$expected_app" ]]
[[ $(sha256sum /etc/systemd/system/juicefs-portal.service | awk '{print $1}') == "$expected_unit" ]]
for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  systemctl is-active --quiet "$service"
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == disabled ]]
done

[[ -c /dev/fuse ]]
fuse_helper=$(command -v fusermount3)
fuse_helper_target=$(readlink -f "$fuse_helper")
[[ -f "$fuse_helper_target" && ! -L "$fuse_helper_target" ]]
[[ $(stat -Lc '%a %U:%G' "$fuse_helper_target") == '4755 root:root' ]] || {
  printf 'resolved fusermount3 helper must be 4755 root:root\n' >&2
  exit 1
}
[[ $(sha256sum "$fuse_helper_target" | awk '{print $1}') == fa2dc1bb00be297004cfa4fc82dab3a6d568042736f7eb5b6fd8de49804db2d1 ]] || {
  printf 'resolved fusermount3 helper hash mismatch\n' >&2
  exit 1
}
[[ $(md5sum "$STAGING/payload/bin/juicefs-ro" | awk '{print $1}') == 24fae0852051c80ca571cb2f20275d46 ]]
"$STAGING/payload/bin/juicefs-ro" version 2>&1 | grep -Fq '1.4.1'
ldd_output=$(ldd "$STAGING/payload/bin/juicefs-ro" 2>&1 || true)
! grep -Fq 'not found' <<<"$ldd_output"

for host in 10.20.1.150 10.20.1.151 10.20.1.152; do
  timeout 3 bash -c ": >/dev/tcp/$host/2379"
done
for host in 10.3.1.6 10.3.1.7 10.3.1.8; do
  timeout 3 bash -c ": >/dev/tcp/$host/3300"
done
runuser -u jfsportal -- test -r /etc/ceph/ceph.conf
command -v ceph >/dev/null
client_auth=$(ceph auth get client.juicefs 2>/dev/null)
grep -Fxq '[client.juicefs]' <<<"$client_auth"
grep -Fxq 'caps mon = "allow r"' <<<"$(sed -E 's/^[[:space:]]+//' <<<"$client_auth")"
grep -Fxq 'caps osd = "allow class-read object_prefix rbd_directory_pool, allow rwx pool=juicefs-data"' <<<"$(sed -E 's/^[[:space:]]+//' <<<"$client_auth")"
unset client_auth
available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
available_bytes=$(df -PB1 /var/lib/juicefs-portal | awk 'NR==2 {print $4}')
[[ "$available_kib" =~ ^[0-9]+$ && "$available_kib" -ge 1048576 ]]
[[ "$available_bytes" =~ ^[0-9]+$ && "$available_bytes" -ge 2147483648 ]]

python3 - /etc/juicefs-portal/users.json <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
assert path.is_file() and not path.is_symlink()
document = json.loads(path.read_text())
users = [u for u in document.get("users", []) if u.get("username") == "user"]
assert document.get("version") == 1 and len(users) == 1 and users[0].get("role") == "USER"
assert "juicefs-prod-root" not in users[0].get("namespaceRoots", [])
PY
! grep -q '^PORTAL_NAMESPACE_DB=' /etc/juicefs-portal/portal.env

for path in \
  /opt/juicefs-portal/bin/juicefs-ro \
  /opt/juicefs-portal/bin/juicefs-namespace-collector \
  /etc/ceph/ceph.client.juicefs.keyring \
  /etc/juicefs-portal/namespace.env \
  /etc/juicefs-portal/namespace-roots.json \
  /etc/systemd/system/juicefs-namespace-mount.service \
  /etc/systemd/system/juicefs-namespace-collector.service \
  /etc/systemd/system/juicefs-namespace-collector.timer \
  /etc/systemd/system/juicefs-portal.service.d/50-t09-namespace.conf \
  /var/lib/juicefs-portal/portal/namespace.db; do
  [[ ! -e "$path" && ! -L "$path" ]] || { printf 'refuse existing T09 target: %s\n' "$path" >&2; exit 1; }
done
[[ -z $(findmnt -rn /var/lib/juicefs-portal/namespace-mount 2>/dev/null || true) ]]
pgrep -xo pd-server >/dev/null
pgrep -xo tikv-server >/dev/null
findmnt -rn /mnt/jfs-tikv >/dev/null
findmnt -rn /mnt/dbwal >/dev/null
printf 'T09_READONLY_PREFLIGHT_PASS host=ceph-node3 mem_available_kib=%s disk_available_bytes=%s\n' "$available_kib" "$available_bytes"
