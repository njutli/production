#!/usr/bin/env bash
# u141b-gate0-offline.sh -- offline Gate 0 for U141b.
#
# ⛔ Runs NO ssh, sudo, mount, losetup, mkfs, ceph, juicefs or fio.
#    Gate 0 must pass before the executor is allowed to touch 157 at all.
#
# Per skills/EVIDENCE-INTEGRITY-SKILL.md §5 this script performs FOUR things:
#   1. static checks on the target scripts (syntax, set -u, forbidden tokens, secrets)
#   2. per-defect-class coverage assertions against
#      skills/fixtures/known-defect-classes.tsv (CRIT/HIGH must be fully covered)
#   3. analyzer self-proof on a historical archive with known answers  (§5.0.2)
#   4. driver / collector synthetic fixture self-tests                 (§5.0.3)
#
# The forbidden-token list lives HERE and the scan set deliberately EXCLUDES this
# file: a script cannot grep itself for a token list stored inside itself.
#
# Usage:
#   u141b-gate0-offline.sh                       静态 + fixture（无历史归档时）
#   u141b-gate0-offline.sh <archive_round_dir>   追加 §5.0.2 分析器自证
set -euo pipefail
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

DRIVER="$SCRIPT_DIR/u141b-driver.sh"
COLLECT="$SCRIPT_DIR/u141b-collect.sh"
ANALYZE="$SCRIPT_DIR/u141b-analyze.py"
DEFECTS="$ROOT/skills/fixtures/known-defect-classes.tsv"
APPLIC="$SCRIPT_DIR/u141b-defect-applicability.tsv"
TASK="$ROOT/doc/perf-tasks/u141b-juicefs-141-replace-131-decision.md"
SKILL="$ROOT/skills/EVIDENCE-INTEGRITY-SKILL.md"

FIXTURE_DIR=${1:-}
OUT=${U141B_GATE0_OUT:-/tmp/u141b-gate0}
mkdir -p "$OUT"

FAILS=()
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS+=("$*"); }
ck()   { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "###############################################################"
echo "# U141b Gate 0 (offline)   $(date -Is)"
echo "###############################################################"

# --------------------------------------------------------- 0. presence

echo
echo "=== 0. required files ==="
for f in "$DRIVER" "$COLLECT" "$ANALYZE" "$DEFECTS" "$APPLIC" "$TASK" "$SKILL"; do
  if [[ -f $f ]]; then ok "present $(basename "$f")"; else bad "MISSING $f"; fi
done
[[ ${#FAILS[@]} -eq 0 ]] || { echo; echo "U141B_GATE0: FAIL (missing files)"; exit 1; }

# --------------------------------------------------------- 1. static

echo
echo "=== 1. static checks (syntax / set -u / shellcheck) ==="
for s in "$DRIVER" "$COLLECT"; do
  ck "bash -n $(basename "$s")"    "bash -n '$s'"
  ck "bash -u -n $(basename "$s")" "bash -u -n '$s'"
done
ck "python ast parse u141b-analyze.py" \
   "python3 -c \"import ast,sys;ast.parse(open('$ANALYZE').read())\""
if command -v shellcheck >/dev/null 2>&1; then
  for s in "$DRIVER" "$COLLECT"; do
    if shellcheck -S error "$s" > "$OUT/shellcheck-$(basename "$s").txt" 2>&1; then
      ok "shellcheck(-S error) $(basename "$s")"
    else
      bad "shellcheck errors in $(basename "$s") -> $OUT/shellcheck-$(basename "$s").txt"
    fi
  done
else
  echo "  [SKIP] shellcheck not installed"
fi

echo
echo "=== 1b. forbidden tokens in the SCAN SET (this file excluded) ==="
SCAN=("$DRIVER" "$COLLECT" "$ANALYZE")
# Comments are stripped before matching: a line documenting a prohibition is not
# a violation of it.  (Without this, collect.sh's own "no rm -rf / -uz / -D"
# banner tripped every rule -- the same self-reference trap that made a script
# grepping itself for a token list stored inside itself always fail.)
strip_comments() {
  sed -e 's/[[:space:]]*#.*$//' "$1"
}
# name<TAB>ERE ; kept here, not in the scanned scripts (self-reference trap)
FORBIDDEN=$(cat <<'PAT'
D26 recursive force remove	rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f|rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r
D26 lazy fuse unmount	fusermount[[:space:]]+-[a-z]*z
D26 lazy/force umount	umount[[:space:]]+(-l|--lazy|-f|--force)
D26 bulk loop detach	losetup[[:space:]]+-D
D26 pattern kill	pkill|killall|fuser[[:space:]]+-k
D25 plaintext ssh password	sshpass[[:space:]]+-p
D25 hardcoded password var	(PASSWORD|PASSWD|SECRET)=[^$"'[:space:]]
D09 rados df column split	rados[[:space:]]+df
D04 pgrep then head -1	pgrep[[:space:]]+-f[^|]*\|[[:space:]]*head[[:space:]]+-1
D10 bc for float compare	\|[[:space:]]*bc
D06 multi-var local	^[[:space:]]*local[[:space:]]+[A-Za-z_]+=[^[:space:]]+[[:space:]]+([A-Za-z_]+=|[A-Za-z_]+[[:space:]]*$)
D07 echo pipe tee append	echo[^|]*\|[[:space:]]*tee[[:space:]]+-a
D08 ssh inside while-read without fd3	while[[:space:]].*read.*;[[:space:]]*do[^\n]*ssh
PAT
)
while IFS=$'\t' read -r name pat; do
  [[ -n ${name:-} ]] || continue
  hit=0
  for s in "${SCAN[@]}"; do
    if strip_comments "$s" | grep -nEq -- "$pat" 2>/dev/null; then
      echo "        $(basename "$s"): $(strip_comments "$s" | grep -nE -- "$pat" | head -3)"
      hit=1
    fi
  done
  if [[ $hit -eq 0 ]]; then ok "$name absent"; else bad "$name PRESENT"; fi
done <<<"$FORBIDDEN"

echo
echo "=== 1c. required positive patterns ==="
ck "D20 driver passes OBJ_GATE=1 to V4"        "grep -q 'OBJ_GATE=1' '$DRIVER'"
ck "REPEAT is the 3rd positional arg (=1)"     "grep -qE '\"\\\$V4\" \"\\\$label\" 180 1' '$DRIVER'"
ck "D05 collector uses sudo for /proc exe"     "grep -q 'sudo md5sum \"/proc' '$COLLECT'"
ck "D09 pool sampling via ceph df --format=json" "grep -q 'ceph df --format=json' '$COLLECT'"
ck "D01 analyzer derives start from done-run"  "grep -q 'done_epoch - run_ms' '$ANALYZE'"
ck "graceful umount has no lazy fallback"      "! grep -A6 'graceful_umount()' '$DRIVER' | grep -qE 'umount[[:space:]]+-l|-uz'"
ck "task book references the skill"            "grep -q 'EVIDENCE-INTEGRITY-SKILL' '$TASK'"

# --------------------------------------------------------- 2. defect classes

echo
echo "=== 2. known-defect-class coverage vs applicability declaration ==="
if python3 - "$DEFECTS" "$APPLIC" "$OUT/coverage.tsv" "$DRIVER" "$COLLECT" "$ANALYZE" "$0" <<'PY'
import sys

defects, applic, outp = sys.argv[1], sys.argv[2], sys.argv[3]
impl_srcs, gate0_src = sys.argv[4:7], sys.argv[7]
impl_blob = "\n".join(open(p, errors="replace").read() for p in impl_srcs)
gate0_blob = open(gate0_src, errors="replace").read()

rows = [l.rstrip("\n").split("\t") for l in open(defects)][1:]
rows = [r for r in rows if len(r) >= 7]
app = {}
for l in list(open(applic))[1:]:
    f = l.rstrip("\n").split("\t")
    if len(f) >= 4:
        app[f[0]] = {"disposition": f[1], "evidence": f[2], "na_reason": f[3]}

VALID = {"ENFORCED_IN_IMPL", "ENFORCED_IN_GATE0", "NOT_APPLICABLE"}
problems, tally = [], {k: 0 for k in VALID}

with open(outp, "w") as fh:
    fh.write("id\tseverity\tclass\tdisposition\tcited\tstatus\n")
    for r in rows:
        did, sev, cls = r[0], r[1], r[2]
        a = app.get(did)
        if a is None:
            problems.append("%s(%s): missing from applicability declaration" % (did, sev))
            fh.write("%s\t%s\t%s\t-\t-\tUNDECLARED\n" % (did, sev, cls))
            continue
        disp = a["disposition"]
        if disp not in VALID:
            problems.append("%s: invalid disposition %r" % (did, disp))
            fh.write("%s\t%s\t%s\t%s\t-\tBAD_DISPOSITION\n" % (did, sev, cls, disp))
            continue
        tally[disp] += 1

        status, cited = "OK", "-"
        if disp == "ENFORCED_IN_IMPL":
            cited = "yes" if did in impl_blob else "no"
            if cited == "no":
                status = "NOT_CITED_IN_IMPL"
                problems.append("%s(%s,%s): declared ENFORCED_IN_IMPL but the id is "
                                "not cited in driver/collect/analyze" % (did, sev, cls))
            if not a["evidence"]:
                status = "NO_EVIDENCE"
                problems.append("%s: ENFORCED_IN_IMPL with empty evidence field" % did)
        elif disp == "ENFORCED_IN_GATE0":
            cited = "yes" if did in gate0_blob else "no"
            if cited == "no":
                status = "NOT_CITED_IN_GATE0"
                problems.append("%s(%s,%s): declared ENFORCED_IN_GATE0 but the id is "
                                "not cited in gate0" % (did, sev, cls))
        else:  # NOT_APPLICABLE
            if not a["na_reason"]:
                status = "NO_REASON"
                problems.append("%s(%s): NOT_APPLICABLE without a reason" % (did, sev))
            elif sev in ("CRIT", "HIGH") and did in impl_blob:
                status = "NA_BUT_CITED"
                problems.append("%s: declared NOT_APPLICABLE yet cited in the "
                                "implementation -- pick one" % did)
        fh.write("%s\t%s\t%s\t%s\t%s\t%s\n" % (did, sev, cls, disp, cited, status))

extra = sorted(set(app) - {r[0] for r in rows})
if extra:
    problems.append("applicability declares unknown ids: %s" % ", ".join(extra))

crit = [r for r in rows if r[1] in ("CRIT", "HIGH")]
print("  defect classes: %d  (CRIT/HIGH %d)" % (len(rows), len(crit)))
print("  dispositions: " + "  ".join("%s=%d" % (k, tally[k]) for k in sorted(tally)))
print("  coverage table -> %s" % outp)
if problems:
    print("  [FAIL] %d problem(s):" % len(problems))
    for p in problems:
        print("      - %s" % p)
    sys.exit(1)
print("  [PASS] every defect class has a declared disposition; every CRIT/HIGH is")
print("         either cited in the implementation, enforced by gate0, or")
print("         explicitly declared not-applicable with a reason")
PY
then :; else bad "defect-class applicability/coverage"; fi

# --------------------------------------------------------- 3. analyzer

echo
echo "=== 3. analyzer self-test (synthetic) ==="
if python3 "$ANALYZE" selftest > "$OUT/analyze-selftest.txt" 2>&1; then
  ok "u141b-analyze.py selftest"
  tail -1 "$OUT/analyze-selftest.txt"
else
  bad "u141b-analyze.py selftest -> $OUT/analyze-selftest.txt"
  tail -20 "$OUT/analyze-selftest.txt"
fi

echo
echo "=== 3b. analyzer self-proof on a historical archive (§5.0.2) ==="
if [[ -z $FIXTURE_DIR ]]; then
  echo "  [WARN] no archive given."
  echo "         Gate 0 is INCOMPLETE until this is run against real data, e.g.:"
  echo "           cp -a /tmp/opencode-fullbaseline-v4/V141P $OUT/fixture-v141p"
  echo "           bash $0 $OUT/fixture-v141p"
  echo "         (read-only copy; the source archive must not be modified)"
  FAILS+=("analyzer self-proof on historical archive not yet run")
elif [[ ! -d $FIXTURE_DIR ]]; then
  bad "archive dir not found: $FIXTURE_DIR"
else
  if python3 "$ANALYZE" fixture "$FIXTURE_DIR" --tol 2.0 \
        > "$OUT/analyze-fixture.txt" 2>&1; then
    ok "analyzer self-proof on $FIXTURE_DIR"
    grep -E 'U141B_ANALYZER_FIXTURE|\+58s max window shift|actual I/O start' \
      "$OUT/analyze-fixture.txt" || true
  else
    bad "analyzer self-proof FAILED -> $OUT/analyze-fixture.txt"
    tail -25 "$OUT/analyze-fixture.txt"
  fi
fi

# --------------------------------------------------------- 4. fixtures

echo
echo "=== 4. driver / collector synthetic fixtures (§5.0.3) ==="
for pair in "collector:$COLLECT" "driver:$DRIVER"; do
  nm=${pair%%:*}; sc=${pair#*:}
  if bash "$sc" --self-test > "$OUT/$nm-selftest.txt" 2>&1; then
    ok "$nm self-test"
    tail -1 "$OUT/$nm-selftest.txt"
  else
    bad "$nm self-test -> $OUT/$nm-selftest.txt"
    tail -25 "$OUT/$nm-selftest.txt"
  fi
done

# --------------------------------------------------------- 5. provenance

echo
echo "=== 5. provenance (frozen after Gate 0 passes) ==="
md5sum "$DRIVER" "$COLLECT" "$ANALYZE" "$0" | tee "$OUT/provenance.md5"
echo "  task book:  $(md5sum "$TASK" | awk '{print $1}')"
echo "  defect tsv: $(md5sum "$DEFECTS" | awk '{print $1}')"
echo "  applicability: $(md5sum "$APPLIC" | awk '{print $1}')"

# --------------------------------------------------------- verdict

echo
echo "###############################################################"
if [[ ${#FAILS[@]} -gt 0 ]]; then
  echo "U141B_GATE0: FAIL (${#FAILS[@]} problem(s))"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  echo
  echo "⛔ Gate 0 has NOT passed. Do not ssh to 157. Fix the scripts and rerun."
  exit 1
fi
echo "U141B_GATE0: PASS"
echo
echo "D27 protocol freeze: the md5 list above IS the frozen provenance record."
echo "Scripts are now FROZEN. After the first formal round starts, changing any"
echo "byte requires: mark the phase EVIDENCE_INVALID -> rerun Gate 0 -> restart"
echo "that phase from its first round.  ⛔ No same-phase hot fix, no RUN_ID reuse,"
echo "⛔ no re-sampling to replace a failed round (D27)."
echo "###############################################################"
