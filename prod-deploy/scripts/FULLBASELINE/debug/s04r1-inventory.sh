#!/usr/bin/env bash
# Phase-I read-only inventory for 04-1/R1. Run on the Ceph client/admin host.
# No Ceph, JuiceFS, mount, process, service, or filesystem state is mutated.
set -euo pipefail
export LC_ALL=C

RUN_ID=${1:-}
DRY_RUN_ONLY=${DRY_RUN_ONLY:-1}
READONLY_ACK=${R1_READONLY_ACK:-}
FIXTURE_DIR=${R1_FIXTURE_DIR:-}
POOL_A=${R1_POOL_A:-juicefs-data}
RESULT_ROOT=${R1_RESULT_ROOT:-/tmp/production/opencode-04-1-${RUN_ID}}
INVENTORY="$RESULT_ROOT/inventory"
HELP_SELFTEST=${R1_INVENTORY_HELP_SELFTEST:-0}

die() { printf 'E_R1_INVENTORY\t%s\n' "$*" >&2; exit 42; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
run_ro() {
  local out=$1
  shift
  printf '%q ' "$@" >>"$INVENTORY/commands.sh"
  printf '> %q\n' "$out" >>"$INVENTORY/commands.sh"
  "$@" >"$out"
}

# Quincy osdmaptool prints valid --help text but returns 1.  This exception is
# deliberately limited to this one probe: preserve stdout, stderr and rc, then
# require both the known rc contract and recognizable non-empty help content.
run_osdmaptool_help_ro() {
  local out=$1 rc=0
  shift
  printf '%q ' "$@" >>"$INVENTORY/commands.sh"
  printf '> %q 2> %q\n' "$out.stdout" "$out.stderr" >>"$INVENTORY/commands.sh"
  set +e
  "$@" >"$out.stdout" 2>"$out.stderr"
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$out.rc"
  cat "$out.stdout" "$out.stderr" >"$out"
  [[ $rc == 0 || $rc == 1 ]] || die "osdmaptool --help unexpected rc=$rc"
  [[ -s $out ]] || die 'osdmaptool --help produced no text'
  grep -Eiq '(^|[[:space:]/])osdmaptool([[:space:]:]|$)|usage:.*osdmaptool' "$out" ||
    die 'osdmaptool --help content is not recognizable'
}

# Gate-only dynamic contract probe.  A 2099 RUN_ID and DRY_RUN_ONLY=1 are both
# mandatory so this path cannot mark a real Phase-I run complete via the driver.
if [[ $HELP_SELFTEST == 1 ]]; then
  [[ $DRY_RUN_ONLY == 1 && $RUN_ID =~ ^2099[0-9]{4}-[0-9]{6}$ ]] ||
    die 'help self-test requires DRY_RUN_ONLY=1 and reserved 2099 RUN_ID'
  [[ $RESULT_ROOT == "/tmp/production/opencode-04-1-$RUN_ID" ]] ||
    die 'help self-test root outside exact RUN scope'
  mkdir -p "$INVENTORY"
  printf '#!/usr/bin/env bash\n# osdmaptool help contract self-test\n' >"$INVENTORY/commands.sh"
  run_osdmaptool_help_ro "$INVENTORY/osdmaptool-help.txt" osdmaptool --help
  printf 'INVENTORY_OSDMAPTOOL_HELP_SELFTEST_PASS rc=%s root=%s\n' \
    "$(<"$INVENTORY/osdmaptool-help.txt.rc")" "$INVENTORY"
  exit 0
fi

[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die 'RUN_ID must be YYYYMMDD-HHMMSS'
[[ $RESULT_ROOT == "/tmp/production/opencode-04-1-$RUN_ID" || $RESULT_ROOT == "/tmp/production/opencode-04-1b-$RUN_ID" ]] || die 'RESULT_ROOT outside exact RUN scope'
[[ ! -L $RESULT_ROOT ]] || die 'RESULT_ROOT must not be a symlink'
[[ $POOL_A == juicefs-data ]] || die 'production pool name is frozen as juicefs-data'
[[ ! -e $INVENTORY/INVENTORY_PASS ]] || die 'inventory already completed for this RUN_ID'
mkdir -p "$INVENTORY"
printf '#!/usr/bin/env bash\n# read-only commands; generated %s\n' "$(date -Is)" >"$INVENTORY/commands.sh"

if [[ -n $FIXTURE_DIR ]]; then
  [[ $DRY_RUN_ONLY == 1 ]] || die 'fixture inventory requires DRY_RUN_ONLY=1'
  [[ -d $FIXTURE_DIR && ! -L $FIXTURE_DIR ]] || die 'invalid fixture directory'
  while IFS= read -r -d '' file; do
    rel=${file#"$FIXTURE_DIR/"}
    [[ $rel != */* ]] || die "fixture must be flat: $rel"
    [[ -f $file && ! -L $file ]] || die "invalid fixture member: $rel"
    cp -- "$file" "$INVENTORY/$rel"
  done < <(find "$FIXTURE_DIR" -mindepth 1 -maxdepth 1 -type f -print0)
  printf 'fixture\t%s\n' "$FIXTURE_DIR" >"$INVENTORY/source.tsv"
else
  [[ $DRY_RUN_ONLY == 0 ]] || die 'real inventory disabled: set DRY_RUN_ONLY=0 after Gate 0'
  [[ $READONLY_ACK == I_ACK_R1_READONLY_INVENTORY ]] || die 'missing exact read-only ACK'
  require sudo; require ceph; require python3; require sha256sum; require findmnt

  run_ro "$INVENTORY/ceph-version.txt" sudo ceph version
  run_ro "$INVENTORY/ceph-status.json" sudo ceph status --format json
  run_ro "$INVENTORY/ceph-health.json" sudo ceph health detail --format json
  run_ro "$INVENTORY/ceph-df.json" sudo ceph df detail --format json
  run_ro "$INVENTORY/pool-detail.json" sudo ceph osd pool ls detail --format json
  run_ro "$INVENTORY/osd-dump.json" sudo ceph osd dump --format json
  run_ro "$INVENTORY/osd-tree.json" sudo ceph osd tree --format json
  run_ro "$INVENTORY/crush-dump.json" sudo ceph osd crush dump --format json
  run_ro "$INVENTORY/pg-all-pools.json" sudo ceph pg dump pgs_brief --format json
  run_ro "$INVENTORY/ec-profile.txt" sudo ceph osd erasure-code-profile get ec-prod
  run_ro "$INVENTORY/ceph-features.txt" sudo ceph features
  run_ro "$INVENTORY/ceph-help.txt" sudo ceph --help
  run_osdmaptool_help_ro "$INVENTORY/osdmaptool-help.txt" osdmaptool --help
  printf '%q ' sudo ceph osd getmap -o "$INVENTORY/osdmap.bin" >>"$INVENTORY/commands.sh"
  printf '\n' >>"$INVENTORY/commands.sh"
  sudo ceph osd getmap -o "$INVENTORY/osdmap.bin" >/dev/null
  printf '%q ' sudo ceph osd getcrushmap -o "$INVENTORY/crush-map.bin" >>"$INVENTORY/commands.sh"
  printf '\n' >>"$INVENTORY/commands.sh"
  sudo ceph osd getcrushmap -o "$INVENTORY/crush-map.bin" >/dev/null

  # auth ls includes keys; only the sanitizer may consume stdout and only entity/caps reach disk.
  printf '%s\n' 'sudo ceph auth ls --format json | python3 <redactor> > auth-readonly.json' >>"$INVENTORY/commands.sh"
  set +e
  sudo ceph auth ls --format json 2>"$INVENTORY/auth-readonly.stderr" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); out=[]
for x in d.get("auth_dump", d if isinstance(d,list) else []):
 out.append({"entity":x.get("entity"),"caps":x.get("caps",{})})
json.dump(out,sys.stdout,indent=2,sort_keys=True); print()' >"$INVENTORY/auth-readonly.json"
  pipe_rc=("${PIPESTATUS[@]}")
  set -e
  [[ ${pipe_rc[0]} == 0 && ${pipe_rc[1]} == 0 ]] || die "auth redaction pipeline failed rc=${pipe_rc[*]}"

  {
    printf 'epoch\t%s\n' "$(date +%s)"
    printf 'hostname\t%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'system_ceph_conf_sha256\t'
    if [[ -f /etc/ceph/ceph.conf ]]; then sha256sum /etc/ceph/ceph.conf | awk '{print $1}'; else printf 'ABSENT\n'; fi
    findmnt -rn -M /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true
    ps -eo pid=,ppid=,comm=,args= | awk '$3=="fio" || $0 ~ /jfs-t6[456]|opencode-04-1/{print}'
  } >"$INVENTORY/runtime-inventory.txt"
fi

python3 - "$INVENTORY" "$POOL_A" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); pool_name=sys.argv[2]
required=['ceph-version.txt','ceph-status.json','ceph-health.json','ceph-df.json',
          'pool-detail.json','osd-dump.json','osd-tree.json','crush-dump.json',
          'pg-all-pools.json','ec-profile.txt','ceph-features.txt','ceph-help.txt',
          'osdmaptool-help.txt','osdmap.bin','crush-map.bin','auth-readonly.json',
          'runtime-inventory.txt']
missing=[x for x in required if not (root/x).is_file() or (root/x).stat().st_size==0]
if missing: raise SystemExit('missing/nonempty inventory files: '+','.join(missing))
pools=json.loads((root/'pool-detail.json').read_text())
if isinstance(pools,dict): pools=pools.get('pools', pools.get('pool_list', []))
matches=[p for p in pools if p.get('pool_name',p.get('name'))==pool_name]
if len(matches)!=1: raise SystemExit(f'pool {pool_name}: expected one row, got {len(matches)}')
pool=matches[0]; pool_id=int(pool.get('pool',pool.get('pool_id')))
pg=json.loads((root/'pg-all-pools.json').read_text())
rows=pg.get('pg_stats',pg.get('pg_map',{}).get('pg_stats',[]))
single=[r for r in rows if str(r.get('pgid','')).split('.',1)[0]==str(pool_id)]
if not single: raise SystemExit(f'no PG rows for pool id {pool_id}')
(root/'pg-single-pool.json').write_text(json.dumps({'pool_id':pool_id,'pool_name':pool_name,'pg_stats':single},indent=2,sort_keys=True)+'\n')
(root/'pool-a.json').write_text(json.dumps(pool,indent=2,sort_keys=True)+'\n')
(root/'inventory-contract.tsv').write_text(
    f'pool_name\t{pool_name}\npool_id\t{pool_id}\nsingle_pool_pgs\t{len(single)}\nall_pool_pgs\t{len(rows)}\n')
PY

(
  cd "$INVENTORY"
  find . -maxdepth 1 -type f ! -name 'manifest.sha256' ! -name 'INVENTORY_PASS' -print0 |
    sort -z | xargs -0 sha256sum >manifest.sha256
)
printf 'INVENTORY_PASS\t%s\t%s\n' "$RUN_ID" "$(date +%s)" >"$INVENTORY/INVENTORY_PASS"
printf 'INVENTORY_PASS run_id=%s root=%s\n' "$RUN_ID" "$INVENTORY"
