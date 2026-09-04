#!/usr/bin/env bash
# Offline Gate 0 for 04-1 v2. This file must never connect to an environment.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
TASK="$ROOT/doc/perf-tasks/04-1-randread-pg-layout-feasibility-and-isolated-pool-ab.md"
OUT=${R1_GATE0_OUT:-$(mktemp -d /tmp/s04r1-v2-gate.XXXXXX)}
mkdir -p "$OUT"; FAIL=0
pass(){ printf '[PASS]\t%s\n' "$*"; }
fail(){ printf '[FAIL]\t%s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
FILES=(s04r1-inventory.sh s04r1-map-analyze.py s04r1-analyze.py
       s04r1-osd-sampler.sh u141d-scrub-control.sh s04r1-driver.sh
       s04r1-gate0-offline.sh s04r1-mock-integration.sh)
printf 'R1_V2_GATE0_BEGIN\t%s\tout=%s\n' "$(date -Is)" "$OUT"
for f in "${FILES[@]}"; do check "present $f" test -s "$SCRIPT_DIR/$f"; done
check 'task book present' test -s "$TASK"
for f in s04r1-inventory.sh s04r1-driver.sh s04r1-gate0-offline.sh s04r1-mock-integration.sh; do
  check "bash -n $f" bash -n "$SCRIPT_DIR/$f"
  check "bash -u -n $f" bash -u -n "$SCRIPT_DIR/$f"
done
check 'map analyzer compiles' python3 -m py_compile "$SCRIPT_DIR/s04r1-map-analyze.py"
check 'performance analyzer compiles' python3 -m py_compile "$SCRIPT_DIR/s04r1-analyze.py"
cat "$SCRIPT_DIR/s04r1-inventory.sh" "$SCRIPT_DIR/s04r1-driver.sh" \
    "$SCRIPT_DIR/s04r1-mock-integration.sh" >"$OUT/source-scan.txt"
for p in 'sshpass[[:space:]]+-p' 'rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*f' 'losetup[[:space:]]+-D' 'pkill|killall|fuser[[:space:]]+-k' 'systemctl[[:space:]]+(stop|restart)'; do
  if grep -nEq "$p" "$OUT/source-scan.txt"; then fail "forbidden pattern $p"; else pass "absent $p"; fi
done
check 'inventory has no mutation' bash -c "! grep -nE 'osd pool (create|delete|set)|auth (get-or-create|del)|config set|primary-affinity|pg-upmap' '$SCRIPT_DIR/s04r1-inventory.sh'"
check 'production reference pool is fixed' grep -Fq 'POOL_A=juicefs-data' "$SCRIPT_DIR/s04r1-driver.sh"
check 'v2 command names are explicit' bash -c "grep -q 'plan-register-empty' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'register-empty' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'adopt-registered-empty' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'evaluate-layout' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'plan-adjust' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'adjust-verify' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'legacy mutation commands are not dispatchable' bash -c "! grep -qE '^  (phase-ii|phase-iii-plan|phase-iv-create)\)' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'data/performance commands are not dispatchable' bash -c "! grep -qE '^  (phase-v-layout|phase-v-warmup|phase-vi-formal|close-preserve)\)' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'register is 32 PG and autoscale off' bash -c "grep -q 'pool create \$POOL_B 32 32' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'pg_autoscale_mode off' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'register ACK is exact' grep -Fq 'I_ACK_R1_REGISTER_EMPTY_${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'adopt ACK is exact' grep -Fq 'I_ACK_R1_ADOPT_REGISTERED_EMPTY_${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'Quincy pool_id schema is accepted' grep -Fq "x[0].get('pool',x[0].get('pool_id'))" "$SCRIPT_DIR/s04r1-driver.sh"
check 'pool-created CRUSH rule is validated semantically' bash -c "grep -Fq \"extra==({brule} if brule!=arule else set())\" '$SCRIPT_DIR/s04r1-driver.sh' && grep -Fq \"semantic(rules1[brule])==semantic(rules1[arule])\" '$SCRIPT_DIR/s04r1-driver.sh'"
check 'current CRUSH dump is collected for empty-pool verification' grep -Fq 'crush-dump-after-adopt.json' "$SCRIPT_DIR/s04r1-driver.sh"
check 'adjust ACK is exact' grep -Fq 'I_ACK_R1_ADJUST_${RUN_ID}_${next}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'reference pool id is immutable' grep -Fq "'pool','pool_id','pg_num'" "$SCRIPT_DIR/s04r1-driver.sh"
check 'candidate pool contract is complete' bash -c "grep -q \"erasure_code_profile.*ec-prod\" '$SCRIPT_DIR/s04r1-driver.sh' && grep -q \"pg_autoscale_mode.*off\" '$SCRIPT_DIR/s04r1-driver.sh' && grep -q \"application_metadata\" '$SCRIPT_DIR/s04r1-driver.sh'"
check 'actual OSDMap epoch and SHA are archived' bash -c "grep -q 'archive_osdmap_identity' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'osdmap_epoch' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'PG dump and OSDMap epoch are closed in one window' bash -c "grep -q 'require_same_osdmap_epoch' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'osd getmap \"\$map_epoch\"' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'no auth before selected map' python3 - "$SCRIPT_DIR/s04r1-driver.sh" <<'PY'
import sys
s=open(sys.argv[1]).read(); reg=s.index('cmd_register_empty()'); eva=s.index('cmd_evaluate_layout()'); auth=s.index('auth get-or-create')
assert reg < auth and eva < auth
PY
check 'actual-only analyzer mode exists' grep -Fq -- '--actual-only' "$SCRIPT_DIR/s04r1-map-analyze.py"
check 'synthetic candidate path is rejected' bash -c "grep -q 'synthetic candidates are forbidden' '$SCRIPT_DIR/s04r1-map-analyze.py'"
check 'pool delete/recreate absent from dispatchable v2 path' bash -c "! grep -nE '^ *sudo +ceph +osd +pool +delete' '$SCRIPT_DIR/s04r1-driver.sh'"

# --- 04-1b R1B assertions ---
check 'r1b command names present' bash -c "grep -q 'r1b-init' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'r1b-plan-create-pool' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'r1b-plan-upmap' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'r1b-evaluate-structure' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b pool name uses jfs-r1b prefix' grep -Fq 'POOL_B_R1B="jfs-r1b-${RUN_ID}"' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b result root uses 04-1b' grep -Fq 'opencode-04-1b-${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b upmap planner mode exists' grep -Fq -- '--plan-upmap-mode' "$SCRIPT_DIR/s04r1-map-analyze.py"
check 'r1b target histogram is pre-registered' grep -Fq '0:10,1:11,2:11,3:10,4:11,5:11' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b state markers use R1B prefix' bash -c "grep -q 'R1B_INIT_COMPLETE' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'R1B_PLAN_UPMAP_COMPLETE' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'R1B_EVALUATE_STRUCTURE_COMPLETE' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b commands do not touch R1 state markers' bash -c "! grep -nE 'r1b.*\\b(INIT_COMPLETE|POOL_REGISTERED|MAP_FROZEN|PHASE_I_COMPLETE)\\b' '$SCRIPT_DIR/s04r1-driver.sh' | grep -v 'R1B_'"
check 'r1b upmap only reorders acting set' grep -Fq 'set(c["old_acting"])==set(c["new_acting"])' "$SCRIPT_DIR/s04r1-mock-integration.sh"
check 'r1b no primary-affinity in driver' bash -c "! grep -nE 'primary-affinity' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b no ceph config set in r1b section' bash -c "! grep -nE 'ceph config set' '$SCRIPT_DIR/s04r1-driver.sh' | grep -v 'mon_allow_pool_delete'"
check 'r1b-phase-i command exists' grep -Fq 'r1b-phase-i' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-init rejects existing root' grep -Fq "R1B RUN root already exists" "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-plan-create-pool requires phase-i' bash -c "grep -A2 'cmd_r1b_plan_create_pool' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'R1B_PHASE_I_COMPLETE'"
check 'r1b-evaluate checks plan SHA' grep -Fq 'upmap-plan SHA mismatch' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-create-pool command exists' grep -Fq 'cmd_r1b_create_pool' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b create wait matches exact RUN pool' bash -c "! sed -n '/cmd_r1b_create_pool()/,/cmd_r1b_adopt_created_pool()/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'startswith(\"jfs-r1b-\")'"
check 'r1b partial create adoption is exact and ACKed' bash -c "grep -q 'cmd_r1b_adopt_created_pool' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'I_ACK_R1B_ADOPT_CREATED_POOL_\${RUN_ID}' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'exact created-pool adoption contract failed' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-create-pool ACK is exact' grep -Fq 'I_ACK_R1B_CREATE_POOL_${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-create-pool verifies plan SHA' grep -Fq 'plan SHA mismatch' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-create-pool controls balancer' bash -c "grep -q 'balancer off' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'balancer on' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-create-pool saves natural mapping' grep -Fq 'registered-map.json' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-apply-upmap command exists' grep -Fq 'cmd_r1b_apply_upmap' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-apply-upmap ACK is exact' grep -Fq 'I_ACK_R1B_APPLY_UPMAP_${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-apply-upmap checks balancer lease' grep -Fq 'R1B_BALANCER_LEASE_OWNED' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-apply-upmap partial failure rollback' bash -c "grep -q 'PARTIAL_FAILURE' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'applied-upmap-pgs' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b Quincy override rows accept dict schema' bash -c "test \"\$(grep -c 'isinstance(entry,dict).*entry.get(\"pgid\"' '$SCRIPT_DIR/s04r1-driver.sh')\" -ge 4"
check 'r1b override parsing has no unsafe direct positional row access' bash -c "! grep -qE 'pg=str\((entry|e)\[0\]\) if' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-rollback-upmap command exists' grep -Fq 'cmd_r1b_rollback_upmap' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-plan-primary-toggle exists' grep -Fq 'cmd_r1b_plan_primary_toggle' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-canary-primary-toggle exists' grep -Fq 'cmd_r1b_canary_primary_toggle' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-canary ACK is exact' grep -Fq 'I_ACK_R1B_PRIMARY_TEMP_CANARY_${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-canary verifies plan SHA' grep -Fq 'primary-toggle plan SHA mismatch' "$SCRIPT_DIR/s04r1-driver.sh"
check 'reject executable primary-temp -1' bash -c "! grep -nE 'primary-temp.* -1' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-canary N target is dynamic not hardcoded' bash -c "! grep -nE '0:11.*1:9.*2:12.*3:12.*4:10.*5:10' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-canary S target is dynamic not hardcoded' bash -c "! grep -nE 'target=.0:10.*1:11.*2:11.*3:10.*4:11.*5:11' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-canary reads registered-map for N' grep -Fq 'registered-map.json' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-canary reads steered-map for S' grep -Fq 'steered-map.json' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-canary clear uses steered_primary' grep -Fq 'steered_primary' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-plan-data-l1 exists' grep -Fq 'cmd_r1b_plan_data_l1' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-plan-data-l1 generates frozen plan' grep -Fq 'plan-data-l1.txt' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b layout v2 plan is independently frozen' bash -c "grep -q 'cmd_r1b_plan_layout_v2' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'layout-v2-contract.tsv' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'plan-layout-v2.sha256' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b layout plan does not depend on unfinished L1 plan' bash -c "! sed -n '/cmd_r1b_plan_layout_v2()/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'R1B_PLAN_DATA_L1_COMPLETE'"
check 'r1b layout validates exact frozen upmap set dynamically' bash -c "grep -q 'b_um==expected' '$SCRIPT_DIR/s04r1-driver.sh' && ! grep -q 'expected 4 upmap' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-layout-once exists' grep -Fq 'cmd_r1b_layout_once' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-l1-screen exists' grep -Fq 'cmd_r1b_l1_screen' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-layout-once ACK is exact' grep -Fq 'I_ACK_R1B_LAYOUT_${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b real layout requires DRY_RUN_ONLY=0' python3 - "$SCRIPT_DIR/s04r1-driver.sh" <<'PY'
import sys
s=open(sys.argv[1]).read(); part=s[s.index('cmd_r1b_layout_once()'):s.index('cmd_r1b_l1_screen()')]
assert 'require_real_ceph' in part and "mock layout requires DRY_RUN_ONLY=1" in part
PY
check 'r1b-l1-screen ACK is exact' grep -Fq 'I_ACK_R1B_L1_${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-layout-once writes DATA_PLANE_STARTED' grep -Fq 'DATA_PLANE_STARTED' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-layout refuses DATA_PLANE_STARTED replay' bash -c "sed -n '/cmd_r1b_layout_once()/,/cmd_r1b_l1_screen()/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'r1b_no DATA_PLANE_STARTED'"
check 'r1b format has bounded timeout' bash -c "sed -n '/cmd_r1b_layout_once()/,/cmd_r1b_l1_screen()/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'timeout --signal=TERM --kill-after=30s 300s'"
check 'r1b-layout-once writes LAYOUT_STARTED' grep -Fq 'LAYOUT_STARTED' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-layout-once uses md5sum not sha256' grep -Fq 'md5sum' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-layout uses deployed JuiceFS CephX cap contract' bash -c "sed -n '/cmd_r1b_layout_once()/,/cmd_r1b_l1_screen()/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q \"mon 'allow r'\" && sed -n '/cmd_r1b_layout_once()/,/cmd_r1b_l1_screen()/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'allow class-read object_prefix rbd_directory_pool, allow rwx pool='"
check 'r1b layout uses run-scoped CEPH_CONF and read canary' bash -c "grep -q 'ceph-r1b.conf' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'rados-auth-canary' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'CEPH_CONF=\$ceph_conf_b' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-layout-once uses mount -d' grep -Fq 'mount -d' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-layout-once uses read_test file pattern' grep -Fq 'read_test' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-layout uses shared exact tree validator' bash -c "grep -q '_r1b_validate_layout_tree' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'st.st_size != 1073741824' '$SCRIPT_DIR/s04r1-driver.sh' && grep -q '\$mnt_b/test_dir' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b mount identity uses proc topology, not broad pgrep' bash -c "grep -q '_r1b_capture_mount_identity' '$SCRIPT_DIR/s04r1-driver.sh' && ! sed -n '/cmd_r1b_layout_once()/,/cmd_r1b_l1_screen()/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'pgrep -f'"
check 'r1b layout has state-driven failure trap' bash -c "grep -q \"trap '_r1b_layout_exit\" '$SCRIPT_DIR/s04r1-driver.sh' && grep -q 'DATA_PLANE_FAILED' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b stability verifies objects and stored' grep -Fq "pair_now" "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-layout-once writes LAYOUT_FAILED on failure' grep -Fq 'LAYOUT_FAILED' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-l1-screen uses r1b-manipulation analyzer' grep -Fq 'r1b-manipulation' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-l1-screen S/S no OSDMap writes' bash -c "grep -q 'no OSDMap writes' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'r1b-adopt-layout-ro-mount exists' grep -Fq 'cmd_r1b_adopt_layout_ro_mount' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-adopt-layout ACK is exact' grep -Fq 'I_ACK_R1B_ADOPT_LAYOUT_RO_${RUN_ID}' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-adopt-layout requires LAYOUT_FAILED' bash -c "grep -A5 'cmd_r1b_adopt_layout_ro_mount' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'LAYOUT_FAILED'"
check 'r1b-adopt-layout uses --read-only not -o ro' grep -Fq '\-\-read-only' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-adopt-layout writes ADOPTED not ONCE_PASS' bash -c "grep -A50 'cmd_r1b_adopt_layout_ro_mount' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'R1B_LAYOUT_ADOPTED_PASS' && ! grep -q 'R1B_LAYOUT_ONCE_PASS' <(grep -A50 'cmd_r1b_adopt_layout_ro_mount' '$SCRIPT_DIR/s04r1-driver.sh')"
check 'no TODO in r1b-l1-screen' bash -c "! sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -qi 'TODO'"
check 'no PENDING_REAL_IOP in driver' bash -c "! grep -q 'PENDING_REAL_IOP' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'no direct scrub set/unset in r1b-l1' bash -c "! sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -qE 'ceph osd (set|unset) (no|nodeep)'"
check 'r1b-manipulation analyzer subcommand exists' grep -Fq 'r1b-manipulation' "$SCRIPT_DIR/s04r1-analyze.py"
check 'r1b-manipulation validates 4 rounds' grep -Fq 'required_rounds' "$SCRIPT_DIR/s04r1-analyze.py"
check 'r1b-l1 uses round_sampler_start/close' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'round_sampler_start'"
check 'r1b-l1 uses scrub_pause/restore not direct' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'scrub_pause'"
check 'r1b-l1 calls r1b-manipulation analyzer' grep -Fq 'r1b-manipulation' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-l1 compares objects/stored not just prints' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'objects changed'"
check 'r1b-l1 W03 epoch comparison' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'epoch_before'"
check 'r1b-l1 verifies 4 rounds before analysis' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'missing.*osd-analysis.json'"
check 'r1b-l1 fio version hard check' grep -Fq 'fio-3.28' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b-l1 128 file hard check before fio' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'file_count.*128'"
check 'r1b-l1 trap writes FATAL not || true' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -q 'FATAL'"
check 'r1b-l1 uses EXIT cleanup for die/exit paths' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -Fq \"trap '_r1b_l1_exit\""
check 'r1b-l1 rebinds shared helpers to 04-1b state' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -Fq 'SCRUB_STATE_DIR=\"\$R1B_STATE/scrub-leases\"'"
check 'r1b-l1 protects 157 from global page-cache eviction' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -Fq 'R1_SKIP_LOCAL_DROP_CACHES=1'"
check 'r1b bandwidth-only closure skips unavailable sampler' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -Fq 'R1B_L1_BW_ONLY'"
check 'r1b bandwidth-only closure resumes frozen W01' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -Fq 'R1B_L1_RESUME_AFTER_W01'"
check 'r1b bandwidth-only closure emits summary' grep -Fq 'l1-bandwidth-only.json' "$SCRIPT_DIR/s04r1-driver.sh"
check 'r1b wait-clean accepts only the shared strict paused-health contract' bash -c "sed -n '/_r1b_wait_clean()/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -Fq 'check_health_json'"
check 'r1b wait-clean has no contradictory HEALTH_OK-only gate' bash -c "! sed -n '/_r1b_wait_clean()/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -Fq 'hstatus == HEALTH_OK'"
check 'r1b-l1 checks per-host sampler evidence' bash -c "sed -n '/cmd_r1b_l1_screen/,/^}/p' '$SCRIPT_DIR/s04r1-driver.sh' | grep -Fq 'osd-\$host_suffix/SAMPLER_PASS'"
check 'r1b-l1 real entry is signed in' grep -Fq 'r1b-l1-screen) cmd_r1b_l1_screen ;;' "$SCRIPT_DIR/s04r1-driver.sh"
check 'sampler accepts 04-1b scope' grep -Fq 'opencode-04-1b' "$SCRIPT_DIR/s04r1-osd-sampler.sh"
check 'sampler does not recursive copy raw' bash -c "! grep -n 'scp.*-r.*raw' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'sampler saves schema not all raw' grep -Fq 'schema-' "$SCRIPT_DIR/s04r1-osd-sampler.sh"
check 'round_sampler_start accepts R1_SAMPLER_RESULT_ROOT' grep -Fq 'R1_SAMPLER_RESULT_ROOT' "$SCRIPT_DIR/s04r1-driver.sh"
check 'no r1b-execute-layout-l1 stub die' bash -c "! grep -q 'not yet.*implemented' '$SCRIPT_DIR/s04r1-driver.sh'"
check 'gate records both task books' bash -c "grep -q '04-1-randread' '$SCRIPT_DIR/s04r1-gate0-offline.sh' && grep -q '04-1b-randread' '$SCRIPT_DIR/s04r1-gate0-offline.sh'"

# R1B planner negative tests
python3 - "$SCRIPT_DIR" "$OUT" <<'PY'
import json,sys,subprocess
from pathlib import Path
script=sys.argv[1]; out=Path(sys.argv[2]); osds=[0,1,2,3,4,5]
neg=out/"r1b-planner-neg"; neg.mkdir(exist_ok=True)
def run_planner(mapfile):
  return subprocess.run([sys.executable,script+"/s04r1-map-analyze.py","--plan-upmap-mode",
    "--registered-map",str(mapfile),"--output",str(neg/"out.json"),
    "--target","0:10,1:11,2:11,3:10,4:11,5:11"],capture_output=True)
# Foreign pool_id in PGID
rows=[]
for i in range(64):
  o=i%6; rows.append({"pgid":f"5.{i:x}","primary":o,"up":osds,"acting":osds})
json.dump({"pool_id":4,"pg_num":64,"pg_stats":rows},open(neg/"foreign-pool.json","w"))
# Duplicate PGID
rows2=[]
for i in range(64):
  o=i%6; rows2.append({"pgid":"4.0","primary":o,"up":osds,"acting":osds})
json.dump({"pool_id":4,"pg_num":64,"pg_stats":rows2},open(neg/"dup-pgid.json","w"))
# primary != acting[0]
rows3=[]
for i in range(64):
  o=i%6; act=list(osds); rows3.append({"pgid":f"4.{i:x}","primary":5,"up":osds,"acting":act})
json.dump({"pool_id":4,"pg_num":64,"pg_stats":rows3},open(neg/"primary-mismatch.json","w"))
# up != acting (existing override)
rows4=[]
for i in range(64):
  o=i%6; act=list(osds); rows4.append({"pgid":f"4.{i:x}","primary":act[0],"up":[1,0,2,3,4,5],"acting":act})
json.dump({"pool_id":4,"pg_num":64,"pg_stats":rows4},open(neg/"existing-override.json","w"))
# Target sum != 64
for bad in ["foreign-pool","dup-pgid","primary-mismatch","existing-override"]:
  r=run_planner(neg/(bad+".json"))
  if r.returncode==0: print(f"E_R1B_GATE\tplanner accepted bad input: {bad}",file=sys.stderr); sys.exit(42)
# Already at target: should return 0 upmap
rows5=[]; n=0
for o,c in enumerate([10,11,11,10,11,11]):
  for _ in range(c):
    act=list(osds); act.remove(o); act.insert(0,o)
    rows5.append({"pgid":f"4.{n:x}","primary":o,"up":list(act),"acting":list(act)}); n+=1
json.dump({"pool_id":4,"pg_num":64,"pg_stats":rows5},open(neg/"already-target.json","w"))
r=run_planner(neg/"already-target.json")
if r.returncode!=0: print("E_R1B_GATE\tplanner rejected already-at-target map",file=sys.stderr); sys.exit(42)
d=json.load(open(neg/"out.json"))
assert d["upmap_count"]==0, f"expected 0 upmap at target, got {d['upmap_count']}"
PY

check 'r1b-l1 plan has no hardcoded old PG IDs' bash -c "! grep -nE '5\.(33|34|35|3d)' '$SCRIPT_DIR/s04r1-driver.sh' | grep -v '#\|comment\|04-1\|pool_id=5'"
if env R1_MOCK_OUT="$OUT/mock-l1" bash "$SCRIPT_DIR/s04r1-mock-integration.sh" 2>&1 | grep -q 'R1B_L1_MOCK_TESTS_PASS'; then pass 'r1b-l1 mock tests pass'; else fail 'r1b-l1 mock tests pass'; fi
_mock_out=$(env R1_MOCK_OUT="$OUT/mock" bash "$SCRIPT_DIR/s04r1-mock-integration.sh" 2>&1 || true)
if echo "$_mock_out" | grep -q 'R1_V2_MOCK_INTEGRATION_PASS'; then pass 'mock ladder lifecycle'; else fail 'mock ladder lifecycle'; fi
check 'driver unknown command fails closed' bash -c "! DRY_RUN_ONLY=1 '$SCRIPT_DIR/s04r1-driver.sh' unknown 20990101-010101 >/dev/null 2>&1"
check 'driver defaults dry-run' grep -Fq 'DRY_RUN_ONLY=${DRY_RUN_ONLY:-1}' "$SCRIPT_DIR/s04r1-driver.sh"
printf 'failures\t%s\nverdict\t%s\nr1b_phase0_verdict\t%s\n' "$FAIL" \
  "$([[ $FAIL -eq 0 ]] && echo R1_V2_GATE0_PASS || echo R1_V2_GATE0_FAIL)" \
  "$([[ $FAIL -eq 0 ]] && echo R1B_PHASE0_GATE0_PASS || echo R1B_PHASE0_GATE0_FAIL)" >"$OUT/gate-verdict.tsv"
sha256sum "${FILES[@]/#/$SCRIPT_DIR/}" "$TASK" "$ROOT/doc/perf-tasks/04-1b-randread-explicit-primary-steering-ab.md" >"$OUT/input-sha256.tsv"
if (( FAIL )); then printf 'R1_V2_GATE0_FAIL\t%s\tout=%s\n' "$FAIL" "$OUT"; exit 1; fi
printf 'R1_V2_GATE0_PASS\tout=%s\nR1B_PHASE0_GATE0_PASS\tout=%s\n' "$OUT" "$OUT"
