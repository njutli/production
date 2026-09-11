#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:?usage: t06-build-forwarder.sh ABSOLUTE_NEW_OUTPUT_FILE}
[[ "$OUT" == /* && ! -e "$OUT" ]] || { printf 'output must be a new absolute path\n' >&2; exit 2; }

export GOCACHE=${GOCACHE:-/tmp/juicefs-cluster-portal-go-cache}
install -d -m 0755 "$(dirname -- "$OUT")"
(
  cd "$ROOT/api"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$OUT" ./cmd/metrics-forwarder
)
chmod 0755 "$OUT"
printf 'FORWARDER_BUILD_PASS output=%s sha256=%s\n' "$OUT" "$(sha256sum "$OUT" | awk '{print $1}')"
