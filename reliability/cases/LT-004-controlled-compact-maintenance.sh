#!/usr/bin/env bash
# LT-004: approved exact-file JuiceFS compact while a read workload is active.
# Full-volume destructive GC is intentionally not automated by this case.
set -euo pipefail
LT_CASE_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
source "$(dirname -- "$LT_CASE_SCRIPT")/../lib/long_term.sh"
lt_case_main LT-004 "$@"
