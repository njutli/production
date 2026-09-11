#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:?usage: t08-prepare-staging.sh /tmp/jfsportal-t08-RUN_ID}
[[ "$OUT" == /tmp/jfsportal-t08-* ]] || { printf 'output outside approved scope\n' >&2; exit 2; }
[[ ! -e "$OUT" ]] || { printf 'output exists: %s\n' "$OUT" >&2; exit 2; }

"$ROOT/deploy/t08-offline-gate.sh"
install -d -m 0755 "$OUT/config" "$OUT/scripts" "$OUT/systemd"
"$ROOT/deploy/scripts/t04-build-portal.sh" "$OUT/payload"
install -m 0644 "$ROOT/deploy/templates/portal.env" "$OUT/config/portal.env.template"
install -m 0644 "$ROOT/deploy/systemd/juicefs-portal.service" "$OUT/systemd/juicefs-portal.service"
install -m 0755 "$ROOT/deploy/scripts/t08-update-auth.sh" "$OUT/scripts/"
install -m 0755 "$ROOT/deploy/scripts/t08-readonly-verify.sh" "$OUT/scripts/"
(
  cd "$OUT"
  find config payload scripts systemd -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
printf 'T08_STAGING_PASS output=%s files=%s\n' "$OUT" "$(wc -l <"$OUT/SHA256SUMS")"
