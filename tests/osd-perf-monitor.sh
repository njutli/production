#!/bin/bash
# OSD perf monitor - runs locally on each OSD node
# Usage: osd-perf-monitor.sh <osd_id> <output_file>
OSD_ID="$1"
OUTFILE="$2"
FSID="073f28e0-5fe0-11f1-8ce6-7369ee2be5a1"
ASOK="/var/run/ceph/${FSID}/ceph-osd.${OSD_ID}.asok"

if [ ! -S "$ASOK" ]; then
  echo "ERROR: admin socket not found at $ASOK" >> "$OUTFILE"
  exit 1
fi

# test sudo access
if ! sudo -n ceph --admin-daemon "$ASOK" perf dump >/dev/null 2>&1; then
  echo "ERROR: sudo not available or socket not accessible" >> "$OUTFILE"
  exit 1
fi

while true; do
  echo "=== $(date +%s) $(date) ===" >> "$OUTFILE"
  sudo -n ceph --admin-daemon "$ASOK" perf dump >> "$OUTFILE" 2>&1
  echo "" >> "$OUTFILE"
  sleep 5
done
