#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
systemctl disable --now juicefs-portal.service juicefs-grafana.service juicefs-prometheus.service
printf 'T05_DEACTIVATE_BASE_PASS data_preserved=true\n'
