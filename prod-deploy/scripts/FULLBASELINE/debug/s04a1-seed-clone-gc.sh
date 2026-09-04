#!/usr/bin/env bash
set -euo pipefail
RUN=${2:-}; [[ ${RUN:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] || exit 42
[[ ${1:-} == plan ]] || { echo NOT_READY >&2; exit 42; }
printf 'PLAN_ONLY seed-layout-once clone-per-arm GC-check-before-delete binary=/tmp/juicefs-1.4.1-patched md5=24fae0852051c80ca571cb2f20275d46 run=%s\n' "$RUN"
