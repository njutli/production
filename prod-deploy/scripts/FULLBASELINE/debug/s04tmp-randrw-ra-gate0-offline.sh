#!/usr/bin/env bash
# Offline Gate 0 for 04-tmp. This script must never call ssh/sudo/ceph/juicefs/fio.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
TASK="$ROOT/doc/perf-tasks/04-tmp-randrw-readahead-residual-tuning.md"
DEFECTS="$ROOT/skills/fixtures/known-defect-classes.tsv"
OSD_FIXTURE="$ROOT/skills/fixtures/s04tmp-osd-perf-quincy.json"
HISTORICAL_ARCHIVE=${S04TMP_HISTORICAL_ARCHIVE:-/tmp/u141d-run5-phase-a-evidence-20260830.tar.gz}
HISTORICAL_SHA256=150f988c70b61ef65fe5608b740e1370b8cbc86472c08b08db411a64acac1e2b
FILES=(s04tmp-randrw-ra-driver.sh s04tmp-randrw-ra-sampler.sh s04tmp-randrw-ra-analyze.py s04tmp-randrw-ra-gate0-offline.sh s04tmp-randrw-ra-mock-integration.sh)
OUT=${S04TMP_GATE0_OUT:-$(mktemp -d /tmp/s04tmp-gate0.XXXXXX)}
mkdir -p "$OUT"; FAIL=0
pass() { printf '[PASS]\t%s\n' "$*"; }
fail() { printf '[FAIL]\t%s\n' "$*"; FAIL=$((FAIL+1)); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
printf 'S04TMP_GATE0_BEGIN\t%s\tout=%s\n' "$(date -Is)" "$OUT"

for file in "${FILES[@]}"; do check "present $file" test -s "$SCRIPT_DIR/$file"; done
check 'task book present' test -s "$TASK"
check 'real historical OSD fixture present' test -s "$OSD_FIXTURE"
for file in s04tmp-randrw-ra-driver.sh s04tmp-randrw-ra-sampler.sh s04tmp-randrw-ra-gate0-offline.sh s04tmp-randrw-ra-mock-integration.sh; do
  check "bash -n $file" bash -n "$SCRIPT_DIR/$file"
  check "bash -u -n $file" bash -u -n "$SCRIPT_DIR/$file"
done
check 'Python compile' python3 -m py_compile "$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py"
if command -v shellcheck >/dev/null 2>&1; then
  for file in s04tmp-randrw-ra-driver.sh s04tmp-randrw-ra-sampler.sh s04tmp-randrw-ra-mock-integration.sh; do
    shellcheck -S error "$SCRIPT_DIR/$file" >"$OUT/shellcheck-$file.txt" 2>&1 && pass "shellcheck $file" || fail "shellcheck $file"
  done
else
  printf '[SKIP]\tshellcheck unavailable\n'
fi

cat "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh" "$SCRIPT_DIR/s04tmp-randrw-ra-sampler.sh" >"$OUT/runtime-source.txt"
for pattern in 'sshpass[[:space:]]+-p' '(PASSWORD|PASSWD)=[^$]' 'rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*f' \
  'fusermount[[:space:]]+-[A-Za-z]*z' 'umount[[:space:]]+(-l|--lazy|-f|--force)' \
  'losetup[[:space:]]+-D' 'pkill|killall|fuser[[:space:]]+-k' \
  'systemctl[[:space:]]+(stop|restart)|reboot|shutdown'; do
  if grep -nEq -- "$pattern" "$OUT/runtime-source.txt"; then fail "forbidden pattern $pattern"; else pass "absent $pattern"; fi
done
check 'no pool create/delete executable' bash -c "! grep -nE 'sudo +ceph +osd +pool +(create|delete)' '$OUT/runtime-source.txt'"
check 'no format/destroy executable' bash -c "! grep -nE '\"\$JFS\" +(format|destroy)' '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh'"
check 'no system ceph.conf write' bash -c "! grep -nE '(>|tee|sed +-i).*?/etc/ceph/ceph.conf' '$OUT/runtime-source.txt'"
check 'formal fio explicitly freezes shape' bash -c "grep -q -- '--rwmixread=50' '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh' && grep -q -- '--numjobs=128' '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh' && grep -q -- '--allow_file_create=0' '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh'"
check 'driver never computes formal effect' bash -c "! grep -q 'ANALYZER.*matrix' '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh'"
check 'wait rc is preserved' bash -c "! grep -nE 'wait .*\|\| true' '$OUT/runtime-source.txt'"
check 'no multi-local forward-reference declaration' bash -c "! grep -nE '^ *local +[A-Za-z_]+=[^ ]+ +[A-Za-z_]+=' '$OUT/runtime-source.txt'"
check 'remote drop caches uses sudo tee' grep -Fq "sudo tee /proc/sys/vm/drop_caches" "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'scrub state is RUN-scoped' grep -Fq 'SCRUB_STATE_DIR="$STATE/scrub-lease"' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'input manifest verified before mutation' grep -Fq 'sha256sum -c "$RESULT_ROOT/input-sha256.txt"' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'authorized run inputs verified before every cell' grep -Fq 'mkdir -p "$out/bw"; verify_authorized_inputs; check_paused' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'unknown command fails closed' bash -c "! DRY_RUN_ONLY=1 '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh' unknown 20990201-010101 >/dev/null 2>&1"
check 'empty RUN ID fails closed' bash -c "! DRY_RUN_ONLY=1 '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh' init '' >/dev/null 2>&1"
check 'real execution lacks ACK and fails closed' bash -c "rid=20990202-$(date +%N | cut -c1-6); DRY_RUN_ONLY=1 S04TMP_MOCK=1 '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh' init \"\$rid\" >/dev/null; ! DRY_RUN_ONLY=0 S04TMP_MOCK=0 '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh' phase-ii-execute \"\$rid\" >/dev/null 2>&1"

# New static checks for revised object-return and mount identity contracts
check 'OBJ_POLL_MAX default 150' grep -Fq 'OBJ_POLL_MAX=${S04TMP_OBJ_POLL_MAX:-150}' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'OBJ_POLL_SLEEP default 30' grep -Fq 'OBJ_POLL_SLEEP=${S04TMP_OBJ_POLL_SLEEP:-30}' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'MAX_LEASE_SECONDS 57600' grep -Fq 'MAX_LEASE_SECONDS=57600' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'no worker=$(mount_cell command substitution' bash -c "! grep -Fq 'worker=\$(mount_cell' '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh'"
check 'selected-worker.pid used' grep -Fq 'selected-worker.pid' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'mount-launch-contract.tsv generated' grep -Fq 'mount-launch-contract.tsv' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'lease deadline check before cells' grep -Fq 'MAX_LEASE_SECONDS )) ||' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'no active drain in object loop' bash -c "! grep -nE 'ceph (osd (set|unset)|tell.*compact)|drop_caches|juicefs gc' '$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh' | grep -v 'cmd_execute\\|run_cell\\|compact_cooldown\\|drop_caches()\\|object_count\\|object-return' || true"
check 'CEPH_CONF_ENV_PRESENT in mount-processes' grep -Fq 'ceph_conf_env_present' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
check 'first-drop recorded' grep -Fq 'FIRST_DROP' "$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"

# Mock: object-return at poll 99 PASS (zero sleep, high for 98 polls then in range)
MOCK_OBJ="$OUT/mock-obj-return"; mkdir -p "$MOCK_OBJ"
check 'mock object-return PASS at poll 99' python3 - "$MOCK_OBJ" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
seed=1978585; tol=8192; low=seed-tol; high=seed+tol
for i in range(1,100):
    obj=2099708 if i<96 else seed
    s=518663536640 if i>=96 else 550415433728
    (root/f'df-{i}.json').write_text(json.dumps({'pools':[{'name':'juicefs-data','stats':{'objects':obj,'stored':s}}]}))
    (root/f'df-{i}.json.objects.json').write_text(json.dumps({'objects':obj,'stored':s}))
rows=[json.load(open(root/f'df-{i}.json.objects.json')) for i in range(97,100)]
objs=[r['objects'] for r in rows]; storeds=[r['stored'] for r in rows]
assert all(low<=o<=high for o in objs) and max(objs)-min(objs)<=32 and max(storeds)==min(storeds)
PY

# Mock: object-return at poll 150 FAIL (all 150 polls high)
check 'mock object-return FAIL at poll 150' python3 - "$MOCK_OBJ" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
for i in range(1,151):
    (root/f'df-{i}.json').write_text(json.dumps({'pools':[{'name':'juicefs-data','stats':{'objects':2099708,'stored':550415433728}}]}))
    (root/f'df-{i}.json.objects.json').write_text(json.dumps({'objects':2099708,'stored':550415433728}))
seed=1978585; tol=8192; low=seed-tol; high=seed+tol
last3=[json.load(open(root/f'df-{i}.json.objects.json')) for i in range(148,151)]
objs=[r['objects'] for r in last3]
assert not all(low<=o<=high for o in objs), 'should not be in range at poll 150'
PY

# Mock: selected-worker.pid validation (empty, non-numeric, dead PID all rejected)
PID_TEST="$OUT/pid-validation"
mkdir -p "$PID_TEST"
printf '' >"$PID_TEST/empty.pid"
printf 'abc\n' >"$PID_TEST/nonnumeric.pid"
printf '999999999\n' >"$PID_TEST/dead.pid"
check 'empty selected-worker.pid rejected' bash -c "! [[ \$(cat '$PID_TEST/empty.pid' 2>/dev/null) =~ ^[0-9]+\$ ]]"
check 'non-numeric selected-worker.pid rejected' bash -c "! [[ \$(cat '$PID_TEST/nonnumeric.pid') =~ ^[0-9]+\$ ]]"
check 'dead PID rejected' bash -c "! kill -0 999999999 2>/dev/null"
check 'alive PID accepted' bash -c "kill -0 \$\$ 2>/dev/null"

# Assets: exact 128x1GiB, then 127/duplicate/512MiB rejection.
ASSET="$OUT/assets"; mkdir -p "$ASSET"
python3 - "$ASSET" <<'PY'
import sys
from pathlib import Path
r=Path(sys.argv[1]); rows=[f'rw_test.{i}.0\t1073741824\t{1000+i}\t1.0\n' for i in range(128)]
for name,data in [('good.tsv',rows),('short.tsv',rows[:-1]),('duplicate.tsv',rows[:-1]+[rows[0]]),('half.tsv',[rows[0].replace('1073741824','536870912')]+rows[1:])]:
 (r/name).write_text('name\tsize\tinode\tmtime\n'+''.join(data))
PY
check 'asset 128x1GiB accepted' python3 "$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py" assets --input "$ASSET/good.tsv" --output "$ASSET/good.json"
for bad in short duplicate half; do check "asset $bad rejected" bash -c "! python3 '$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py' assets --input '$ASSET/$bad.tsv' --output '$ASSET/$bad.json' >/dev/null 2>&1"; done

# Objects JSON: numeric/scientific notation and seed tolerance; missing/truncated reject.
printf '{"pools":[{"name":"juicefs-data","stats":{"objects":2.434679e6,"stored":123}}]}' >"$OUT/df-good.json"
printf '{"pools":[{"name":"juicefs-data","stats":{"stored":123}}]}' >"$OUT/df-missing.json"
check 'Ceph objects scientific JSON accepted within seed' python3 "$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py" objects --input "$OUT/df-good.json" --pool juicefs-data --seed 2434679 --tolerance 8192 --output "$OUT/objects.json"
check 'Ceph objects outside seed rejected' bash -c "! python3 '$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py' objects --input '$OUT/df-good.json' --pool juicefs-data --seed 2500000 --tolerance 8192 --output '$OUT/no.json' >/dev/null 2>&1"
check 'Ceph objects missing field rejected' bash -c "! python3 '$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py' objects --input '$OUT/df-missing.json' --pool juicefs-data --output '$OUT/no2.json' >/dev/null 2>&1"
printf '{"pools":[{"name":"juicefs-data","stats":{"objects":2434679}}]}' >"$OUT/df-missing-stored.json"
check 'Ceph stored missing field rejected' bash -c "! python3 '$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py' objects --input '$OUT/df-missing-stored.json' --pool juicefs-data --output '$OUT/no3.json' >/dev/null 2>&1"

# Historical OSD fixture strict fields and missing field rejection.
suffix=$(date +%N); SRUN="20990203-${suffix:0:6}"; SOUT="/tmp/production/opencode-04-tmp-randrw-ra-$SRUN/sampler-fixture"
check 'sampler parses exact historical OSD fields' env DRY_RUN_ONLY=1 S04TMP_OSD_FIXTURE="$OSD_FIXTURE" S04TMP_SAMPLE_INTERVAL=1 bash "$SCRIPT_DIR/s04tmp-randrw-ra-sampler.sh" "$SRUN" "$SOUT" 10 0
python3 - "$OSD_FIXTURE" "$OUT/osd-bad.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); del d['osd']['op_w_in_bytes']; json.dump(d,open(sys.argv[2],'w'))
PY
suffix=$(date +%N); BRUN="20990204-${suffix:0:6}"; BOUT="/tmp/production/opencode-04-tmp-randrw-ra-$BRUN/sampler-bad"
check 'sampler rejects missing OSD field' bash -c "! DRY_RUN_ONLY=1 S04TMP_OSD_FIXTURE='$OUT/osd-bad.json' S04TMP_SAMPLE_INTERVAL=1 bash '$SCRIPT_DIR/s04tmp-randrw-ra-sampler.sh' '$BRUN' '$BOUT' 10 0 >/dev/null 2>&1"

check 'scrub controller ownership/rollback self-test' env U141D_SCRUB_STATE_DIR="$OUT/scrub-state" bash "$SCRIPT_DIR/u141d-scrub-control.sh" --self-test

S04TMP_MOCK_OUT="$OUT/mock" check 'offline hold/full lifecycle and independent matrix' env S04TMP_MOCK_OUT="$OUT/mock" bash "$SCRIPT_DIR/s04tmp-randrw-ra-mock-integration.sh"
ANFIX="$OUT/mock/analysis-fixture"
# Add a deterministic sidecar around the real t0 encoded in synthetic R01.
python3 - "$ANFIX/R01" <<'PY'
import json,sys
from pathlib import Path
r=Path(sys.argv[1]); s=r/'sampler'; raw=s/'raw'; raw.mkdir(parents=True); (s/'SAMPLER_PASS').write_text('SAMPLER_PASS\n')
header='epoch_ns\tosd\top_r\top_r_out_bytes\top_r_lat_sum\top_r_lat_count\top_w\top_w_in_bytes\top_w_lat_sum\top_w_lat_count\tcompact_running\tcompact_queue_len\tkv_sync_sum\tkv_sync_count\n'
(s/'osd-perf.tsv').write_text(header); (s/'heartbeat.tsv').write_text('epoch_ns\trx_bytes\ttx_bytes\tproc_utime\tproc_stime\tproc_rss_pages\tosd_rows\n')
start=996_000_000_000
with (s/'osd-perf.tsv').open('a') as pf,(s/'heartbeat.tsv').open('a') as hf:
 for i in range(38):
  epoch=start+i*5_000_000_000; hf.write(f'{epoch}\t{i*100}\t{i*90}\t{i}\t{i}\t100\t6\n')
  (raw/f'health-{epoch}.json').write_text(json.dumps({'status':'HEALTH_WARN','checks':{'OSDMAP_FLAGS':{}}}))
  (raw/f'pg-{epoch}.json').write_text(json.dumps({'pg_stats':[{'pgid':'3.0','state':'active+clean'}]}))
  (raw/f'df-{epoch}.json').write_text('{}')
  for osd in range(6):
   base=i*1000+osd
   pf.write(f'{epoch}\t{osd}\t{base}\t{base*262144}\t{i*.1}\t{base}\t{base}\t{base*262144}\t{i*.2}\t{base}\t0\t0\t{i*.01}\t{base}\n')
PY
check 'sidecar actual-window/health/PG/counter contract' python3 "$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py" sidecar --round-dir "$ANFIX/R01" --output "$OUT/sidecar.json"
cp -a "$ANFIX/R01" "$OUT/sidecar-bad"
python3 - "$OUT/sidecar-bad/sampler/raw" <<'PY'
import json,sys
from pathlib import Path
p=sorted(Path(sys.argv[1]).glob('health-*.json'))[5]; d=json.load(open(p)); d['checks']['RECENT_CRASH']={}; p.write_text(json.dumps(d))
PY
check 'sidecar rejects additional health check' bash -c "! python3 '$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py' sidecar --round-dir '$OUT/sidecar-bad' --output '$OUT/no-sidecar.json' >/dev/null 2>&1"
check '127 bw logs rejected' bash -c "cp -a '$ANFIX/R01' '$OUT/r127'; rm -f '$OUT/r127/bw/rw_test_bw.128.log'; ! python3 '$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py' round --round-dir '$OUT/r127' --label R01 --arm A --randseed 41001 --output '$OUT/r127.json' >/dev/null 2>&1"
check 'mixed READ/WRITE actual-start and sensitivity' python3 - "$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py" "$ANFIX/R01/bw" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location('a',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a=m.mixed_logs(m.Path(sys.argv[2]),15); lo=m.mixed_logs(m.Path(sys.argv[2]),14); hi=m.mixed_logs(m.Path(sys.argv[2]),16); late=m.mixed_logs(m.Path(sys.argv[2]),73)
for d in ('read','write'):
 assert abs(lo[d]['mean_MiBs']/a[d]['mean_MiBs']-1)<.01 and abs(hi[d]['mean_MiBs']/a[d]['mean_MiBs']-1)<.01
 assert abs(late[d]['w4_w1']-a[d]['w4_w1'])>.10
assert a['read']['formal_n']==160 and a['write']['formal_n']==160
PY

# Recompute a trusted real U141d randrw archive, not only synthetic logs.
check 'trusted historical randrw archive SHA256' bash -c "[[ -f '$HISTORICAL_ARCHIVE' && \$(sha256sum '$HISTORICAL_ARCHIVE' | awk '{print \$1}') == '$HISTORICAL_SHA256' ]]"
HIST_PREFIX=production/opencode-u141d-20260830-122350/v4/U141D-20260830-122350-A-R01-V13/randrw-U141D-20260830-122350-A-R01-V13-r1
mkdir -p "$OUT/historical"
check 'extract exact trusted historical randrw member' tar -xzf "$HISTORICAL_ARCHIVE" -C "$OUT/historical" "$HIST_PREFIX"
check 'historical READ/WRITE split, formal window and four windows' python3 - "$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py" "$OUT/historical/$HIST_PREFIX" <<'PY'
import importlib.util,re,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('a',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p=Path(sys.argv[2]); out=m.mixed_logs(p); text=(p/'fio.txt').read_text()
summary=[float(x) for x in re.findall(r'^\s*(?:READ|WRITE): bw=(\d+(?:\.\d+)?)MiB/s',text,re.M)]
assert len(summary)==2
assert out['read']['formal_n']==out['write']['formal_n']==160
assert len(out['read']['windows_MiBs'])==len(out['write']['windows_MiBs'])==4
assert out['read']['mean_MiBs']>0 and out['write']['mean_MiBs']>0
assert abs(out['read']['mean_MiBs']-summary[0])>.1 and abs(out['write']['mean_MiBs']-summary[1])>.1
PY

# Known-defect disposition: all CRIT/HIGH rows must be covered or explicitly inapplicable.
cat >"$OUT/defect-disposition.tsv" <<'EOF'
id	disposition	reason
D01	COVERED	actual start=end-run and sensitivity fixture
D02	COVERED	overlap-weighted resampling fixture
D03	COVERED	verdict uses formal per-job logs only
D04	COVERED	all exact mount candidates recorded
D05	COVERED	unreadable candidates cannot produce selected identity; zero candidates fatal
D06	COVERED	bash nounset parse
D07	COVERED	no echo-tee logging pipeline
D08	COVERED	ssh stdin redirected
D09	COVERED	Ceph JSON objects parser fixtures
D10	COVERED	Python numeric comparisons include scientific notation
D11	COVERED	find scope is exact known-readable task directory
D12	NOT_APPLICABLE	no exposition parser
D13	NOT_APPLICABLE	no iostat parser
D14	NOT_APPLICABLE	no PSI parser
D15	NOT_APPLICABLE	no separate preflight time-window parser
D16	COVERED	fio-driven sampler stop and wait rc before manifest
D17	COVERED	wait rc preserved without or-true
D18	COVERED	real historical exact OSD path fixture
D19	COVERED	cell output/label reuse rejected
D20	NOT_APPLICABLE	FULLBASELINE V4 is not invoked
D21	COVERED	Phase-I archive/memory/capacity inventory
D22	COVERED	STOP_REQUEST plus finite watchdog and typed rc
D23	NOT_APPLICABLE	single namespace; inode identity frozen
D24	NOT_APPLICABLE	no optional legacy input
D25	COVERED	plaintext secret static scan
D26	COVERED	destructive command static scan
D27	COVERED	input manifest verified before Phase II and no hot resume
D28	COVERED	append-only incident ledger
D29	COVERED	asset size gate rejects 512MiB
D30	COVERED	all parent/child candidates and Setting.UUID
D31	COVERED	health JSON and osd stat JSON
D32	COVERED	local/remote sudo tee drop caches
EOF
check 'all CRIT/HIGH defect IDs dispositioned' python3 - "$DEFECTS" "$OUT/defect-disposition.tsv" <<'PY'
import csv,sys
with open(sys.argv[1],newline='') as f: need={r['id'] for r in csv.DictReader(f,delimiter='\t') if r['severity'] in ('CRIT','HIGH')}
with open(sys.argv[2],newline='') as f: rows=list(csv.DictReader(f,delimiter='\t'))
got=[r['id'] for r in rows]; assert len(got)==len(set(got)) and need.issubset(got)
PY

(
  cd "$ROOT"
  git diff --check -- doc/perf-tasks/04-tmp-randrw-readahead-residual-tuning.md \
    scripts/FULLBASELINE/debug/s04tmp-randrw-ra-driver.sh scripts/FULLBASELINE/debug/s04tmp-randrw-ra-sampler.sh \
    scripts/FULLBASELINE/debug/s04tmp-randrw-ra-analyze.py scripts/FULLBASELINE/debug/s04tmp-randrw-ra-gate0-offline.sh \
    scripts/FULLBASELINE/debug/s04tmp-randrw-ra-mock-integration.sh skills/fixtures/s04tmp-osd-perf-quincy.json
) && pass 'git diff --check' || fail 'git diff --check'
sha256sum "${FILES[@]/#/$SCRIPT_DIR/}" "$TASK" "$OSD_FIXTURE" "$SCRIPT_DIR/u141d-scrub-control.sh" >"$OUT/input-sha256.txt"
printf 'failures\t%s\n' "$FAIL" >"$OUT/summary.tsv"
if (( FAIL > 0 )); then printf 'S04TMP_GATE0_FAIL\t%s\tout=%s\n' "$FAIL" "$OUT"; exit 1; fi
printf 'S04TMP_GATE0_PASS\tout=%s\n' "$OUT"
