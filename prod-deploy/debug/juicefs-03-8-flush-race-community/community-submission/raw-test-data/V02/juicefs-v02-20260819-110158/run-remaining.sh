#!/bin/bash
set -euo pipefail
OUT=/tmp/juicefs-v02-20260819-110158
RUN_ID=20260819-110158

# Run remaining 4 positions sequentially
for pos in A 2 2 A A 3 3 A B 3 3 B S 3 3 S; do
    read arm block position binary_arm <<< $pos
    bin=/tmp/juicefs-v02-${RUN_ID}-${binary_arm}
    label=${arm}${position}
    echo "=== Starting $label at $(date) ==="
    bash $OUT/run-position.sh $arm $block $position $bin
    echo "=== Completed $label at $(date) ==="
done

echo "ALL_REMAINING_DONE $(date)" > $OUT/runs/remaining-done.txt
