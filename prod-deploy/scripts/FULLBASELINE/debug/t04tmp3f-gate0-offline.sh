#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXEC="$DIR/t04tmp3f-executor.sh"
ANALYZER="$DIR/t04tmp3f-analyze.py"

[[ -s "$EXEC" && -s "$ANALYZER" ]] || { echo T04TMP3F_GATE0_FAIL_missing_input >&2; exit 42; }
bash -n "$EXEC"; bash -u -n "$EXEC"
PYTHONPYCACHEPREFIX=/tmp/t04tmp3f-pycache python3 -m py_compile "$ANALYZER"
"$EXEC" --self-test
python3 "$ANALYZER" self-test

# The matrix is six fixed mount groups.  B changes only readahead; C alone changes max-fuse-io.
for row in \
  $'A01\tG1\tA\t256K\t8M\t256K\t19671' $'A02\tG1\tA\t20M\t8M\t256K\t19671' \
  $'B01\tG2\tB\t20M\t32M\t256K\t19672' $'C01\tG3\tC\t256K\t32M\t1M\t19673' \
  $'C02\tG3\tC\t20M\t32M\t1M\t19673' $'C03\tG4\tC\t20M\t32M\t1M\t19674' \
  $'C04\tG4\tC\t256K\t32M\t1M\t19674' $'B02\tG5\tB\t20M\t32M\t256K\t19675' \
  $'A03\tG6\tA\t20M\t8M\t256K\t19676' $'A04\tG6\tA\t256K\t8M\t256K\t19676'; do
  grep -Fqx "$row" < <("$EXEC" --print-matrix)
done

for token in \
  'run_group G1 A 8M 256K 19671 A01 256K A02 20M' \
  'run_group G3 C 32M 1M 19673 C01 256K C02 20M' \
  'run_group G6 A 8M 256K 19676 A03 20M A04 256K' \
  'trap on_exit EXIT INT TERM HUP' 'graceful_unmount_active' 'health_gate "$cell-pre"' \
  'sample_cell "$out"' 'runtime-scripts.sha256' 'business_${f}_drift' 'verdict "$ROOT"'; do
  grep -Fq "$token" "$EXEC" || { printf 'T04TMP3F_GATE0_FAIL\tmissing=%s\n' "$token" >&2; exit 42; }
done

for token in 'APP_BS_A' 'APP_BS_C' 'RA32' 'MAX_FUSE_1M' 'ANCHORS' 'TARGET_MIB_S' \
             'formal_seconds' 'object_errors_delta' 'read_target_observed_twice_l1'; do
  grep -Fq "$token" "$ANALYZER" || { printf 'T04TMP3F_GATE0_FAIL\tmissing=%s\n' "$token" >&2; exit 42; }
done

# No privileged or data-mutating test path is permitted in this reduced task.
if grep -nEi '(^|[;&|])[[:space:]]*(sudo|ssh|scp|systemctl|reboot|shutdown|poweroff|halt|drop_caches)|juicefs[[:space:]]+(format|destroy)|rados|ceph[[:space:]]+(config|tell|osd[[:space:]]+(set|unset|pool))|fio[^\n]*--rw=(write|rand)|rm[[:space:]]+-[rR]|umount[[:space:]]+-[lf]' "$EXEC" "$ANALYZER"; then
  echo T04TMP3F_GATE0_FAIL_forbidden_operation >&2; exit 42
fi

if command -v shellcheck >/dev/null 2>&1; then shellcheck -x "$EXEC" "$0"; fi
sha256sum "$EXEC" "$ANALYZER" "$0"
printf 'T04TMP3F_GATE0_PASS\tread_only_10_cells\tno_sudo_no_data_mutation\n'
