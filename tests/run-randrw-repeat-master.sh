#!/bin/bash
set -uo pipefail
cd /home/turboai/production
LOG=/tmp/opencode/randrw-repeat-master.log
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1
echo "=== RANDRW REPEAT MASTER START $(date) ==="
set +e
bash tests/bench-randrw-repeat.sh 4M 5;   echo "rc4M=$?"
bash tests/bench-randrw-repeat.sh 256K 5; echo "rc256K=$?"
set -e
echo "=== RANDRW REPEAT MASTER DONE $(date) ==="
