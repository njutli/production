#!/bin/bash
set -euo pipefail

# ============================================================
# OSD Deploy Script (run as root on target node)
#
# Creates 1 OSD: DATA on physical disk, DB/WAL on tmpfs loop.
# Called by deploy-ceph.sh via: sudo bash deploy-osd.sh <args>
#
# Usage: sudo bash deploy-osd.sh <dev> <osd_seq> <dbwal_mnt> <db_size> <wal_size> <tmpfs_size>
# ============================================================

DEV="$1"
OSD_SEQ="$2"
DBWAL_MNT="$3"
DB_SIZE="$4"
WAL_SIZE="$5"
TMPFS_SIZE="$6"

# Ensure tmpfs mounted
mountpoint -q "${DBWAL_MNT}" 2>/dev/null || {
    mkdir -p "${DBWAL_MNT}"
    mount -t tmpfs -o size="${TMPFS_SIZE}" tmpfs "${DBWAL_MNT}"
}

# Create DB + WAL files on tmpfs
db_file="${DBWAL_MNT}/db-osd${OSD_SEQ}.img"
wal_file="${DBWAL_MNT}/wal-osd${OSD_SEQ}.img"
echo "  DB file: ${db_file} (${DB_SIZE})"
echo "  WAL file: ${wal_file} (${WAL_SIZE})"
rm -f "${db_file}" "${wal_file}"
truncate -s "${DB_SIZE}" "${db_file}"
truncate -s "${WAL_SIZE}" "${wal_file}"

# Create loop devices
db_dev="$(losetup -f --show "${db_file}")"
wal_dev="$(losetup -f --show "${wal_file}")"
echo "  DB loop: ${db_dev}"
echo "  WAL loop: ${wal_dev}"

# Create LVM for DATA (ceph-volume lvm requires data as LV)
vg_name="ceph-vg-osd${OSD_SEQ}"
pvcreate -ff -y "${DEV}" 2>/dev/null || true
vgcreate "${vg_name}" "${DEV}" 2>/dev/null || true
lvremove -f "${vg_name}" 2>/dev/null || true
lvcreate -l 100%FREE -n osd "${vg_name}"
data_lv="/dev/${vg_name}/osd"

# Deploy OSD: DATA on physical disk, DB/WAL on tmpfs loop
echo "  ceph-volume lvm create: data=${data_lv} db=${db_dev} wal=${wal_dev}"
cephadm shell \
    -m /var/lib/ceph/bootstrap-osd:/var/lib/ceph/bootstrap-osd \
    -m /dev:/dev \
    -m /run/lvm:/run/lvm \
    -m /run/lock/lvm:/run/lock/lvm \
    -m /run/udev:/run/udev \
    -m /sys:/sys \
    -- ceph-volume lvm create --bluestore \
    --data "${data_lv}" \
    --block.db "${db_dev}" \
    --block.wal "${wal_dev}" 2>&1 | grep -iE 'created|success|osd|error|fail' || echo '  (check output)'

echo "  OSD #${OSD_SEQ} deployed."
