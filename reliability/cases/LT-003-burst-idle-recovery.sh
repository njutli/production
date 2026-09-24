#!/usr/bin/env bash
# LT-003: repeat bounded write bursts and idle recovery on the same dataset.
set -euo pipefail
LT_CASE_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
source "$(dirname -- "$LT_CASE_SCRIPT")/../lib/long_term.sh"
lt_case_main LT-003 "$@"
