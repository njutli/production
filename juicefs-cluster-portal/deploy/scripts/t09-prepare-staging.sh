#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:?usage: t09-prepare-staging.sh /tmp/jfsportal-t09-RUN_ID /absolute/path/to/juicefs-1.4.1-patched}
JUICEFS_BINARY=${2:?usage: t09-prepare-staging.sh /tmp/jfsportal-t09-RUN_ID /absolute/path/to/juicefs-1.4.1-patched}
[[ "$OUT" == /tmp/jfsportal-t09-* ]] || { printf 'output outside approved scope\n' >&2; exit 2; }
[[ ! -e "$OUT" ]] || { printf 'output exists: %s\n' "$OUT" >&2; exit 2; }
[[ "$JUICEFS_BINARY" == /* && -f "$JUICEFS_BINARY" && ! -L "$JUICEFS_BINARY" && -x "$JUICEFS_BINARY" ]] || {
  printf 'invalid JuiceFS binary\n' >&2
  exit 2
}
[[ $(md5sum "$JUICEFS_BINARY" | awk '{print $1}') == 24fae0852051c80ca571cb2f20275d46 ]] || {
  printf 'JuiceFS binary MD5 does not match the approved v1.4.1 patched build\n' >&2
  exit 2
}

"$ROOT/deploy/t09-offline-gate.sh"
install -d -m 0755 "$OUT/config" "$OUT/scripts" "$OUT/systemd"
"$ROOT/deploy/scripts/t04-build-portal.sh" "$OUT/payload"
install -m 0755 "$JUICEFS_BINARY" "$OUT/payload/bin/juicefs-ro"
install -m 0644 "$ROOT/configs/namespace-roots.prod.json" "$OUT/config/namespace-roots.json"
install -m 0640 "$ROOT/deploy/templates/namespace.env" "$OUT/config/namespace.env"
install -m 0644 "$ROOT/deploy/systemd/juicefs-namespace-mount.service" "$ROOT/deploy/systemd/juicefs-namespace-collector.service" "$ROOT/deploy/systemd/juicefs-namespace-collector.timer" "$ROOT/deploy/systemd/juicefs-portal-t09-namespace.conf" "$OUT/systemd/"
for script in t09-readonly-preflight.sh t09-readonly-verify.sh t09-update-namespace.sh t09-rollback-namespace.sh; do
  install -m 0755 "$ROOT/deploy/scripts/$script" "$OUT/scripts/"
done
(
  cd "$OUT"
  find config payload scripts systemd -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
printf 'T09_STAGING_PASS output=%s files=%s juicefs_md5=24fae0852051c80ca571cb2f20275d46\n' "$OUT" "$(wc -l <"$OUT/SHA256SUMS")"
