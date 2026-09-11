#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:?usage: t04-build-portal.sh ABSOLUTE_EMPTY_OUTPUT_DIR}
[[ "$OUT" == /* ]] || { printf 'output must be absolute\n' >&2; exit 2; }
[[ ! -e "$OUT" ]] || { printf 'output already exists: %s\n' "$OUT" >&2; exit 2; }

export GOCACHE=${GOCACHE:-/tmp/juicefs-cluster-portal-go-cache}
install -d -m 0755 "$OUT/bin" "$OUT/web" "$OUT/fixtures"
(
  cd "$ROOT/api"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$OUT/bin/juicefs-portal" ./cmd/portal
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$OUT/bin/portal-userctl" ./cmd/portal-userctl
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$OUT/bin/juicefs-namespace-collector" ./cmd/namespace-collector
)
install -m 0644 "$ROOT/web/index.html" "$ROOT/web/styles.css" "$ROOT/web/app.js" "$OUT/web/"
install -m 0644 "$ROOT"/fixtures/*.json "$OUT/fixtures/"
(
  cd "$OUT"
  find bin web fixtures -type f -print0 | sort -z | xargs -0 sha256sum >portal-manifest.sha256
)
printf 'PORTAL_BUILD_PASS output=%s\n' "$OUT"
