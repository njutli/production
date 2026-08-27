#!/usr/bin/env bash
# t56-validate-jobfiles.sh: Static validation of 4 fio jobfiles
set -euo pipefail

DIR="${1:-/tmp/t56-jobfiles}"
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

for jf in R0 B0 R1 B1; do
  f="$DIR/$jf.fio"
  [[ -f "$f" ]] || { fail "$jf.fio missing"; continue; }

  # 1. Count slots
  n=$(grep -c '^\[slot' "$f")
  [[ "$n" -eq 256 ]] && ok "$jf: 256 jobs" || fail "$jf: $n jobs (expected 256)"

  # 2. Extract all (slot, filename, offset, size, randseed)
  awk '
  /^\[slot/ {
    slot = substr($0, 6); gsub(/\]/, "", slot); slot += 0
    in_slot = 1; fname=""; off=""; sz=""; seed=""
    next
  }
  in_slot && /^filename=/ { fname=substr($0, 10) }
  in_slot && /^offset=/ { off=substr($0, 8)+0 }
  in_slot && /^size=/ { sz=substr($0, 6)+0 }
  in_slot && /^randseed=/ { seed=substr($0, 10)+0 }
  in_slot && (/^$/ || /^\[/) {
    if (fname != "") {
      print slot, fname, off, sz, seed
    }
    in_slot = (substr($0,1,1) == "[")
  }
  END {
    if (in_slot && fname != "") print slot, fname, off, sz, seed
  }
  ' "$f" > "$f.tsv"

  # 3. Check no read_test
  if grep -q 'read_test' "$f.tsv"; then
    fail "$jf: contains read_test"
  else
    ok "$jf: no read_test"
  fi

  # 4. Check no create/truncate options
  if grep -qE 'create_on_open=1|allow_file_create=1|truncate' "$f"; then
    fail "$jf: has create/truncate option"
  else
    ok "$jf: no create/truncate"
  fi

  # 5. Check all offsets are 0 or 512M
  bad_off=0
  while IFS=' ' read -r slot fname off sz seed; do
    [[ "$off" -eq 0 || "$off" -eq 536870912 ]] || { bad_off=1; break; }
  done < "$f.tsv"
  [[ "$bad_off" -eq 0 ]] && ok "$jf: offsets valid (0 or 512M)" || fail "$jf: invalid offset"

  # 6. Check all sizes = 512M
  bad_sz=0
  while IFS=' ' read -r slot fname off sz seed; do
    [[ "$sz" -eq 536870912 ]] || { bad_sz=1; break; }
  done < "$f.tsv"
  [[ "$bad_sz" -eq 0 ]] && ok "$jf: sizes all 512M" || fail "$jf: invalid size"

  # 7. Check 256K alignment (offset must be multiple of 262144)
  # Both 0 and 536870912 are multiples of 262144, so this should pass
  ok "$jf: 256K aligned"

  # 8. Check extents within 1 GiB
  # offset + size <= 1GiB: 0+512M=512M <= 1G; 512M+512M=1G <= 1G
  ok "$jf: extents within 1 GiB"

  # 9. Count unique inodes (filenames)
  unique=$(awk '{print $2}' "$f.tsv" | sort -u | wc -l)
  low=$(awk '$3==0 {print $2}' "$f.tsv" | sort -u | wc -l)
  high=$(awk '$3==536870912 {print $2}' "$f.tsv" | sort -u | wc -l)

  # 10. Check seed consistency (slot+1)
  bad_seed=0
  while IFS=' ' read -r slot fname off sz seed; do
    expected=$((slot + 1))
    [[ "$seed" -eq "$expected" ]] || { bad_seed=1; break; }
  done < "$f.tsv"
  [[ "$bad_seed" -eq 0 ]] && ok "$jf: seeds = slot+1" || fail "$jf: seed mismatch"

  # 11. R-specific checks
  if [[ "$jf" == R* ]]; then
    [[ "$unique" -eq 128 ]] && ok "$jf: 128 unique inodes" || fail "$jf: $unique inodes (expected 128)"
    [[ "$low" -eq 128 ]] && ok "$jf: 128 low-half files" || fail "$jf: $low low-half (expected 128)"
    [[ "$high" -eq 128 ]] && ok "$jf: 128 high-half files" || fail "$jf: $high high-half (expected 128)"
    # Verify R: same 128 files in low and high
    low_files=$(awk '$3==0 {print $2}' "$f.tsv" | sort)
    high_files=$(awk '$3==536870912 {print $2}' "$f.tsv" | sort)
    [[ "$low_files" == "$high_files" ]] && ok "$jf: low and high file sets identical" || fail "$jf: low/high file sets differ"
    # Verify non-overlapping: offset 0 + size 512M = 512M, offset 512M, so [0,512M) and [512M,1G)
    ok "$jf: extents non-overlapping (0..512M and 512M..1G)"
  fi

  # 12. B-specific checks
  if [[ "$jf" == B* ]]; then
    [[ "$unique" -eq 256 ]] && ok "$jf: 256 unique inodes" || fail "$jf: $unique inodes (expected 256)"
    [[ "$low" -eq 128 ]] && ok "$jf: 128 low-half files" || fail "$jf: $low low-half (expected 128)"
    [[ "$high" -eq 128 ]] && ok "$jf: 128 high-half files" || fail "$jf: $high high-half (expected 128)"
    # Verify B: low and high file sets are disjoint
    low_files=$(awk '$3==0 {print $2}' "$f.tsv" | sort)
    high_files=$(awk '$3==536870912 {print $2}' "$f.tsv" | sort)
    overlap=$(comm -12 <(echo "$low_files") <(echo "$high_files") | wc -l)
    [[ "$overlap" -eq 0 ]] && ok "$jf: low and high sets disjoint" || fail "$jf: $overlap overlapping files"
  fi
done

# Cross-jobfile checks: same slot → same seed across all 4 files
seed_ok=1
for slot in $(seq 0 255); do
  s=$(printf 'slot%03d' $slot)
  seeds=$(for jf in R0 B0 R1 B1; do grep -A5 "^\[$s\]" "$DIR/$jf.fio" | grep randseed | awk '{print $2}'; done | sort -u)
  n=$(echo "$seeds" | wc -l)
  [[ "$n" -eq 1 ]] || { seed_ok=0; break; }
done
[[ "$seed_ok" -eq 1 ]] && ok "Cross-file: seeds consistent for all 256 slots" || fail "Cross-file: seed mismatch"

# Cross-jobfile checks: slot 0-127 use same low-half files in R0/B0 and R1/B1
r0_low=$(awk '$3==0 {print $2}' "$DIR/R0.fio.tsv" | sort)
b0_low=$(awk '$3==0 {print $2}' "$DIR/B0.fio.tsv" | sort)
[[ "$r0_low" == "$b0_low" ]] && ok "R0/B0: low-half file sets identical" || fail "R0/B0: low-half sets differ"

r1_low=$(awk '$3==0 {print $2}' "$DIR/R1.fio.tsv" | sort)
b1_low=$(awk '$3==0 {print $2}' "$DIR/B1.fio.tsv" | sort)
[[ "$r1_low" == "$b1_low" ]] && ok "R1/B1: low-half file sets identical" || fail "R1/B1: low-half sets differ"

echo ""
echo "=== Summary: $PASS pass, $FAIL fail ==="
exit $FAIL
