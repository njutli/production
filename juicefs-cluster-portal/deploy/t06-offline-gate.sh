#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NODE_TGZ=${1:?usage: t06-offline-gate.sh NODE_EXPORTER_TGZ PROMTOOL}
PROMTOOL=${2:?missing promtool binary}
# shellcheck disable=SC1091
source "$ROOT/deploy/versions.env"
export GOCACHE=${GOCACHE:-/tmp/juicefs-cluster-portal-go-cache}

[[ -f "$NODE_TGZ" && ! -L "$NODE_TGZ" && -x "$PROMTOOL" ]] || { printf 'invalid offline dependency\n' >&2; exit 2; }
[[ $(sha256sum "$NODE_TGZ" | awk '{print $1}') == "$NODE_EXPORTER_LINUX_AMD64_SHA256" ]]

for script in "$ROOT/deploy/scripts/collect-nvme-metrics" "$ROOT"/deploy/scripts/t06-*.sh; do
  bash -n "$script"
done
if rg -n '^[[:space:]]*(sudo[[:space:]]+)?(reboot|shutdown|halt|poweroff)([[:space:]]|$)|chown[[:space:]]+-R|chmod[[:space:]]+-R|wipefs|dd[[:space:]].*of=/dev/' \
  "$ROOT/deploy/scripts/collect-nvme-metrics" "$ROOT"/deploy/scripts/t06-*.sh; then
  printf 'forbidden destructive command in T06 scripts\n' >&2
  exit 1
fi
if rg -n 'systemctl[[:space:]]+enable|systemctl[[:space:]]+reenable' "$ROOT"/deploy/scripts/t06-*.sh; then
  printf 'T06 must not enable services\n' >&2
  exit 1
fi

mapfile -d '' go_sources < <(find "$ROOT/api" -name '*.go' -type f -print0 | sort -z)
[[ -z $(gofmt -d "${go_sources[@]}") ]] || { printf 'Go sources are not formatted\n' >&2; exit 1; }
(
  cd "$ROOT/api"
  go test ./...
  go vet ./...
)

"$PROMTOOL" check config "$ROOT/deploy/prometheus/prometheus-t06.yml"
python3 - "$ROOT/deploy/scripts/collect-nvme-metrics" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "<<'PY'\n"
start = text.index(marker) + len(marker)
end = text.index("\nPY\n", start)
compile(text[start:end], sys.argv[1] + ":embedded-python", "exec")
PY

for unit in \
  "$ROOT/deploy/systemd/juicefs-node-exporter.service" \
  "$ROOT/deploy/systemd/juicefs-nvme-collector.service" \
  "$ROOT/deploy/systemd/juicefs-metrics-forwarder.service" \
  "$ROOT/deploy/systemd/juicefs-prometheus.service"; do
  grep -Fq 'IOWeight=10' "$unit"
  grep -Fq 'ProtectSystem=strict' "$unit"
  grep -Fq 'NoNewPrivileges=true' "$unit"
done
grep -Fq 'DevicePolicy=closed' "$ROOT/deploy/systemd/juicefs-nvme-collector.service"
grep -Eq '^DeviceAllow=/dev/nvme[0-3] r$' "$ROOT/deploy/systemd/juicefs-nvme-collector.service"
! grep -Eq '^DeviceAllow=.* [^r]+' "$ROOT/deploy/systemd/juicefs-nvme-collector.service"
grep -Fq 'IPAddressAllow=10.20.1.152/32' "$ROOT/deploy/systemd/juicefs-metrics-forwarder.service"
grep -Fq 'Environment=JFS_METRICS_UPSTREAM_URL=http://127.0.0.1:9567/metrics' "$ROOT/deploy/systemd/juicefs-metrics-forwarder.service"
grep -Fq 'Environment=GOMAXPROCS=1' "$ROOT/deploy/systemd/juicefs-metrics-forwarder.service"

stage=$(mktemp -d /tmp/jfsportal-t06-gate.XXXXXX)
cleanup() {
  [[ "$stage" == /tmp/jfsportal-t06-gate.* ]] && rm -rf -- "$stage"
}
trap cleanup EXIT
out=$stage/jfsportal-t06-offline
"$ROOT/deploy/scripts/t06-prepare-staging.sh" "$out" "$NODE_TGZ"
(
  cd "$out"
  sha256sum -c SHA256SUMS
)
"$out/payload/bin/node_exporter" --version 2>&1 | grep -Fq "version $NODE_EXPORTER_VERSION"
[[ -x "$out/payload/bin/juicefs-metrics-forwarder" ]]
[[ -x "$out/payload/bin/collect-nvme-metrics" ]]
printf 'T06_OFFLINE_GATE_PASS\n'
