#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:?usage: t06-prepare-staging.sh ABSOLUTE_NEW_OUTPUT_DIR NODE_EXPORTER_TGZ}
NODE_TGZ=${2:?missing node_exporter archive}
# shellcheck disable=SC1091
source "$ROOT/deploy/versions.env"

[[ "$OUT" == /* && ! -e "$OUT" ]] || { printf 'output must be a new absolute path\n' >&2; exit 2; }
[[ -f "$NODE_TGZ" && ! -L "$NODE_TGZ" ]] || { printf 'invalid node_exporter archive\n' >&2; exit 2; }
printf '%s  %s\n' "$NODE_EXPORTER_LINUX_AMD64_SHA256" "$NODE_TGZ" | sha256sum -c -
if tar -tzf "$NODE_TGZ" | awk -F/ '$1=="" {bad=1} {for(i=1;i<=NF;i++) if($i=="..") bad=1} END {exit !bad}'; then
  printf 'unsafe archive member\n' >&2
  exit 1
fi

work=$(mktemp -d /tmp/jfsportal-t06-stage.XXXXXX)
cleanup() {
  [[ "$work" == /tmp/jfsportal-t06-stage.* ]] && rm -rf -- "$work"
}
trap cleanup EXIT

install -d -m 0755 "$OUT/payload/bin" "$OUT/config" "$OUT/systemd" "$OUT/baseline" "$OUT/scripts" "$work/node"
tar -xzf "$NODE_TGZ" --no-same-owner --no-same-permissions -C "$work/node"
node_bin=$(find "$work/node" -type f -name node_exporter -perm -u+x -print -quit)
[[ -n "$node_bin" ]] || { printf 'node_exporter binary not found\n' >&2; exit 1; }
"$node_bin" --version 2>&1 | grep -Fq "version $NODE_EXPORTER_VERSION"
install -m 0755 "$node_bin" "$OUT/payload/bin/node_exporter"
"$ROOT/deploy/scripts/t06-build-forwarder.sh" "$OUT/payload/bin/juicefs-metrics-forwarder"
install -m 0755 "$ROOT/deploy/scripts/collect-nvme-metrics" "$OUT/payload/bin/collect-nvme-metrics"

install -m 0644 "$ROOT/deploy/prometheus/prometheus-t06.yml" "$OUT/config/prometheus.yml"
install -m 0644 "$ROOT/deploy/prometheus/prometheus.yml" "$OUT/baseline/prometheus-t05.yml"
install -m 0644 "$ROOT/deploy/baseline/juicefs-prometheus-t05.service" "$OUT/baseline/juicefs-prometheus-t05.service"
install -m 0644 "$ROOT/deploy/systemd/juicefs-prometheus.service" "$OUT/systemd/juicefs-prometheus.service"
install -m 0644 "$ROOT/deploy/systemd/juicefs-node-exporter.service" "$OUT/systemd/juicefs-node-exporter.service"
install -m 0644 "$ROOT/deploy/systemd/juicefs-nvme-collector.service" "$OUT/systemd/juicefs-nvme-collector.service"
install -m 0644 "$ROOT/deploy/systemd/juicefs-nvme-collector.timer" "$OUT/systemd/juicefs-nvme-collector.timer"
install -m 0644 "$ROOT/deploy/systemd/juicefs-metrics-forwarder.service" "$OUT/systemd/juicefs-metrics-forwarder.service"
install -m 0755 "$ROOT"/deploy/scripts/t06-{install-node-observability,install-client-forwarder,update-prometheus,node-readonly-verify,forwarder-readonly-verify,readonly-verify,ceph-readonly-inventory}.sh "$OUT/scripts/"

(
  cd "$OUT"
  find payload config systemd baseline scripts -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
printf 'T06_STAGING_PASS output=%s\n' "$OUT"
