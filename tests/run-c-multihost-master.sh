#!/bin/bash
# Serial master for the multi-host C test (single process, no watchdog).
# Launch with:
#   setsid bash tests/run-c-multihost-master.sh < /dev/null > /tmp/opencode/c-multihost-master.log 2>&1 & disown
set -uo pipefail
cd /home/turboai/production
LOG=/tmp/opencode/c-multihost-master.log
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
clean_env() {
    pkill -9 fio 2>/dev/null || true
    ${SSH} turboai@192.168.11.11 'pkill -9 fio 2>/dev/null || true' 2>/dev/null || true
    for mp in /mnt/juicefs; do
        fusermount -uz "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
    done
    ${SSH} turboai@192.168.11.11 'fusermount -uz /mnt/juicefs 2>/dev/null || sudo umount -l /mnt/juicefs 2>/dev/null || true' 2>/dev/null || true
    sleep 3
}

echo "=== C-MULTIHOST MASTER START $(date) ==="
clean_env
echo "=== STEP1 multi-host C (256K) START $(date) ==="
bash tests/bench-c-multihost.sh c256k
echo "=== STEP1 multi-host C END $(date) rc=$? ==="
clean_env
echo "=== C-MULTIHOST MASTER DONE $(date) ==="
