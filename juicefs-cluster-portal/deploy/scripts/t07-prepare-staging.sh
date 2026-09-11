#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:?usage: t07-prepare-staging.sh /tmp/jfsportal-t07-RUN_ID}
PROMTOOL=${PROMTOOL:-/tmp/jfsportal-t05-20260910-165333/payload/bin/promtool}
[[ "$OUT" == /tmp/jfsportal-t07-* ]] || { printf 'output outside approved scope\n' >&2; exit 2; }
[[ ! -e "$OUT" ]] || { printf 'output exists: %s\n' "$OUT" >&2; exit 2; }

PROMTOOL="$PROMTOOL" "$ROOT/deploy/t07-offline-gate.sh"
install -d -m 0755 "$OUT/config" "$OUT/scripts"
"$ROOT/deploy/scripts/t04-build-portal.sh" "$OUT/payload"
install -m 0644 "$ROOT/deploy/prometheus/prometheus-t06.yml" "$OUT/config/prometheus.yml"
install -m 0755 "$ROOT/deploy/scripts/t07-update-live-portal.sh" "$OUT/scripts/"
install -m 0755 "$ROOT/deploy/scripts/t07-readonly-verify.sh" "$OUT/scripts/"
install -m 0755 "$ROOT/deploy/scripts/t06-readonly-verify.sh" "$OUT/scripts/"
(
  cd "$OUT"
  find config payload scripts -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
printf 'T07_STAGING_PASS output=%s files=%s\n' "$OUT" "$(wc -l <"$OUT/SHA256SUMS")"
