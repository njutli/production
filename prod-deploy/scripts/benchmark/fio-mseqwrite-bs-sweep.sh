#!/bin/bash
# Competitor mseqwrite BS sweep: 16 jobs, psync/QD1, 16 x 4 GiB files, end_fsync.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROFILE=mseqwrite ENTRY_SCRIPT="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
exec "${SCRIPT_DIR}/fio-bs-sweep-common.sh" "$@"
