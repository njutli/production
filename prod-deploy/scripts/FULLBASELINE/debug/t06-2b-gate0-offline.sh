#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

MODE=${1:-}
EXPECTED_SOURCE_SHA=a3265ff95e68dc08d53afe3e755b063516e0403f53a5dd04248118b8b9c97451
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
DEPLOY_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)
PATCH_DIR="$DEPLOY_ROOT/debug/06-2b-range-flush"

die() {
  printf 'T062B_GATE0_FAIL\t%s\n' "$*" >&2
  exit 42
}

if [[ $MODE == --self-test ]]; then
  bash -n "$0"
  grep -Fq 'range-flush-repair.patch' "$0"
  grep -Fq 'fixture-old-notify.patch' "$0"
  grep -Fq 'fixture-old-scope.patch' "$0"
  grep -Fq 'TestRangeFlushFixedOverwriteCommitNotification' "$0"
  grep -Fq 'TestRangeScopeDependencyClosureAndCommittedExclusion/committed-dependency-removed-from-queue' "$0"
  ! grep -Eq 'ssh|scp|sudo|fio|fusermount|umount|reboot|shutdown|halt|poweroff|pkill|killall|fuser[[:space:]]+-k|rm[[:space:]]+-' "$0"
  printf 'T062B_GATE0_SELF_TEST_PASS\n'
  exit 0
fi

[[ $MODE == run ]] || die 'usage: t06-2b-gate0-offline.sh run SOURCE_ARCHIVE WORK_ROOT [SDK_ROOT]'
SOURCE_ARCHIVE=${2:-}
WORK_ROOT=${3:-}
SDK_ROOT=${4:-/home/lilingfeng/tmp/juicefs-v01-r1-20260818-001227/librados-sdk/usr}
GOCACHE_ROOT=${T062B_GOCACHE:-/tmp/t06-2b-go-build-cache}

[[ $SOURCE_ARCHIVE == /* && -f $SOURCE_ARCHIVE && ! -L $SOURCE_ARCHIVE ]] || die invalid_source_archive
[[ $WORK_ROOT == /tmp/opencode-06-2b-* && $WORK_ROOT != /tmp/opencode-06-2b- && ! -e $WORK_ROOT ]] || die invalid_or_existing_work_root
[[ -f $PATCH_DIR/range-flush-repair.patch && ! -L $PATCH_DIR/range-flush-repair.patch ]] || die missing_repair_patch
[[ -f $PATCH_DIR/fixture-old-notify.patch && ! -L $PATCH_DIR/fixture-old-notify.patch ]] || die missing_notify_fixture
[[ -f $PATCH_DIR/fixture-old-scope.patch && ! -L $PATCH_DIR/fixture-old-scope.patch ]] || die missing_scope_fixture
[[ -f $SDK_ROOT/include/rados/librados.h ]] || die missing_librados_header
[[ -e $SDK_ROOT/lib/x86_64-linux-gnu/librados.so ]] || die missing_librados_link_stub
[[ $GOCACHE_ROOT == /tmp/* && $GOCACHE_ROOT != /tmp && ! -L $GOCACHE_ROOT ]] || die invalid_gocache_root

actual_source_sha=$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')
[[ $actual_source_sha == "$EXPECTED_SOURCE_SHA" ]] || die source_archive_sha_mismatch

mkdir -m 0700 "$WORK_ROOT"
tar -tvzf "$SOURCE_ARCHIVE" >"$WORK_ROOT/archive-list.txt"
awk 'substr($1,1,1)!="-" && substr($1,1,1)!="d" && substr($1,1,1)!="l" {print; bad=1} END{exit bad}' \
  "$WORK_ROOT/archive-list.txt" >"$WORK_ROOT/archive-special.txt" || die archive_special_entry
tar -tzf "$SOURCE_ARCHIVE" | awk '/^\// || /(^|\/)\.\.($|\/)/ {print; bad=1} END{exit bad}' \
  >"$WORK_ROOT/archive-unsafe-paths.txt" || die archive_unsafe_path

mkdir -m 0700 "$WORK_ROOT/source-c"
tar -xzf "$SOURCE_ARCHIVE" -C "$WORK_ROOT/source-c"
cp -a "$WORK_ROOT/source-c" "$WORK_ROOT/source-t"
patch -d "$WORK_ROOT/source-t" -p1 --forward --batch <"$PATCH_DIR/range-flush-repair.patch" \
  >"$WORK_ROOT/repair-apply.stdout" 2>"$WORK_ROOT/repair-apply.stderr"
cp -a "$WORK_ROOT/source-t" "$WORK_ROOT/source-old-notify"
cp -a "$WORK_ROOT/source-t" "$WORK_ROOT/source-old-scope"
patch -d "$WORK_ROOT/source-old-notify" -p1 --forward --batch <"$PATCH_DIR/fixture-old-notify.patch" \
  >"$WORK_ROOT/old-notify-apply.stdout" 2>"$WORK_ROOT/old-notify-apply.stderr"
patch -d "$WORK_ROOT/source-old-scope" -p1 --forward --batch <"$PATCH_DIR/fixture-old-scope.patch" \
  >"$WORK_ROOT/old-scope-apply.stdout" 2>"$WORK_ROOT/old-scope-apply.stderr"

if find "$WORK_ROOT/source-t/pkg/vfs" -maxdepth 1 -type f \( -name 'writer.go' -o -name 'vfs.go' -o -name 'writer_range_test.go' \) \
    -print0 | xargs -0 gofmt -d >"$WORK_ROOT/gofmt.diff"; then
  [[ ! -s $WORK_ROOT/gofmt.diff ]] || die gofmt_diff
else
  die gofmt_failed
fi

python3 - "$WORK_ROOT/source-t/pkg/vfs/vfs.go" <<'PY' >"$WORK_ROOT/semantic-static.txt"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
def body(name, next_name):
    m = re.search(rf"func \(v \*VFS\) {name}\b(.*?)(?=\nfunc \(v \*VFS\) {next_name}\b)", text, re.S)
    if not m:
        raise SystemExit(f"missing function boundary: {name}->{next_name}")
    return m.group(1)
read = body("Read", "Write")
truncate = body("Truncate", "Fallocate")
copy_range = body("CopyFileRange", "Flush")
if "v.writer.FlushRange(ctx, ino, off, uint64(size))" not in read:
    raise SystemExit("Read does not use exact range flush")
if "v.writer.Flush(ctx, ino)" not in truncate:
    raise SystemExit("Truncate lost whole-inode flush")
if copy_range.count("v.writer.Flush(ctx,") < 2:
    raise SystemExit("CopyFileRange lost full flushes")
print("READ_RANGE_FLUSH_PASS")
print("TRUNCATE_FULL_FLUSH_PASS")
print("COPY_FILE_RANGE_FULL_FLUSH_PASS")
PY

mkdir -m 0700 -p "$GOCACHE_ROOT"
mkdir -m 0700 "$WORK_ROOT/gotmp" "$WORK_ROOT/negative" "$WORK_ROOT/bin"
go_env=(GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOCACHE="$GOCACHE_ROOT" GOTMPDIR="$WORK_ROOT/gotmp")

set +e
(cd "$WORK_ROOT/source-old-notify" && env "${go_env[@]}" go test ./pkg/vfs \
  -run '^TestRangeFlushFixedOverwriteCommitNotification$' -count=1 -timeout=30s) \
  >"$WORK_ROOT/negative/old-notify.stdout" 2>"$WORK_ROOT/negative/old-notify.stderr"
notify_rc=$?
(cd "$WORK_ROOT/source-old-scope" && env "${go_env[@]}" go test ./pkg/vfs \
  -run '^TestRangeScopeDependencyClosureAndCommittedExclusion/committed-dependency-removed-from-queue$' -count=1 -timeout=30s) \
  >"$WORK_ROOT/negative/old-scope.stdout" 2>"$WORK_ROOT/negative/old-scope.stderr"
scope_rc=$?
set -e
[[ $notify_rc -ne 0 ]] || die old_notify_fixture_unexpected_pass
[[ $scope_rc -ne 0 ]] || die old_scope_fixture_unexpected_pass
grep -Fq 'non-growing overwrite commit did not wake range waiter' "$WORK_ROOT/negative/old-notify.stdout" || die wrong_notify_failure
grep -Fq 'committed dependency triggered full fallback' "$WORK_ROOT/negative/old-scope.stdout" || die wrong_scope_failure

(cd "$WORK_ROOT/source-t" && env "${go_env[@]}" go test ./pkg/vfs \
  -run '^(TestVFSBasic|TestVFSIO|TestFill|TestRange.*)$' -count=1 -timeout=10m) \
  >"$WORK_ROOT/relevant-tests.stdout" 2>"$WORK_ROOT/relevant-tests.stderr"
(cd "$WORK_ROOT/source-t" && env "${go_env[@]}" go test -race ./pkg/vfs \
  -run '^TestRange.*$' -count=1 -timeout=10m) \
  >"$WORK_ROOT/race-tests.stdout" 2>"$WORK_ROOT/race-tests.stderr"

ldflags='-X github.com/juicedata/juicefs/pkg/version.revision=0b90c7d -X github.com/juicedata/juicefs/pkg/version.revisionDate=2026-07-30 -s -w'
for arm in c t; do
  (cd "$WORK_ROOT/source-$arm" && env "${go_env[@]}" CGO_ENABLED=1 \
    CGO_CFLAGS="-I$SDK_ROOT/include" CGO_LDFLAGS="-L$SDK_ROOT/lib/x86_64-linux-gnu" \
    go build -buildvcs=false -tags ceph -gcflags='' -ldflags="$ldflags" \
    -o "$WORK_ROOT/bin/juicefs-06-2b-$arm" .) \
    >"$WORK_ROOT/build-$arm.stdout" 2>"$WORK_ROOT/build-$arm.stderr"
done

{
  printf 'field\tvalue\n'
  printf 'source_archive_sha256\t%s\n' "$actual_source_sha"
  printf 'go_version\t%s\n' "$(go version)"
  printf 'gocache_root\t%s\n' "$GOCACHE_ROOT"
  printf 'repair_patch_sha256\t%s\n' "$(sha256sum "$PATCH_DIR/range-flush-repair.patch" | awk '{print $1}')"
  for arm in c t; do
    bin="$WORK_ROOT/bin/juicefs-06-2b-$arm"
    printf '%s_sha256\t%s\n' "$arm" "$(sha256sum "$bin" | awk '{print $1}')"
    printf '%s_md5\t%s\n' "$arm" "$(md5sum "$bin" | awk '{print $1}')"
    printf '%s_version\t%s\n' "$arm" "$($bin version 2>&1)"
  done
} >"$WORK_ROOT/identity.tsv"

{
  printf 'gate\tstatus\n'
  printf 'archive_safety\tPASS\n'
  printf 'patch_apply\tPASS\n'
  printf 'semantic_static\tPASS\n'
  printf 'old_notify_negative\tPASS\n'
  printf 'old_scope_negative\tPASS\n'
  printf 'relevant_regression\tPASS\n'
  printf 'race_regression\tPASS\n'
  printf 'same_toolchain_build\tPASS\n'
  printf 'environment_access\tNOT_RUN\n'
} >"$WORK_ROOT/gate.tsv"

(cd "$WORK_ROOT" && find . -type f ! -path './gotmp/*' ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
(cd "$WORK_ROOT" && sha256sum -c SHA256SUMS >/dev/null)
printf 'T062B_GATE0_OFFLINE_PASS\troot=%s\n' "$WORK_ROOT"
