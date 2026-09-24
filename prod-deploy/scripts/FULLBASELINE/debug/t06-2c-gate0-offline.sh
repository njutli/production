#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077

RUN_ID=${1:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROD_DEPLOY=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
SOURCE_ARCHIVE=${T062C_SOURCE_ARCHIVE:-/mnt/c/SunRise/test/06-2/20260916-091446/build/juicefs-v1.4.1-b-catchup-source.tar.gz}
SOURCE_SHA256=a3265ff95e68dc08d53afe3e755b063516e0403f53a5dd04248118b8b9c97451
PATCH=$PROD_DEPLOY/debug/06-2c-eager-freeze/eager-freeze.patch
SDK_ROOT=${T062C_SDK_ROOT:-/home/lilingfeng/tmp/juicefs-v01-r1-20260818-001227/librados-sdk/usr}
OUT=${2:-/tmp/production/opencode-06-2c-offline-$RUN_ID}

die() { printf 'T062C_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_run_id
case $OUT in
  "/tmp/production/opencode-06-2c-offline-$RUN_ID"|"/mnt/c/SunRise/test/06-2c/$RUN_ID/offline") ;;
  *) die unsafe_output_root ;;
esac
[[ ! -e $OUT && ! -L $OUT ]] || die output_exists_or_symlink
[[ -f $SOURCE_ARCHIVE && ! -L $SOURCE_ARCHIVE ]] || die source_archive_missing_or_symlink
[[ -f $PATCH && ! -L $PATCH ]] || die patch_missing_or_symlink
[[ -d $SDK_ROOT/include && -d $SDK_ROOT/lib/x86_64-linux-gnu ]] || die ceph_sdk_missing
[[ $(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}') == "$SOURCE_SHA256" ]] || die source_archive_sha_mismatch

mkdir -m 0700 -p "$(dirname -- "$OUT")"
mkdir -m 0700 "$OUT"
WORK=$(mktemp -d /tmp/t06-2c-gate0.XXXXXX)
cleanup() {
  case ${WORK:-} in
    /tmp/t06-2c-gate0.*) [[ -d $WORK && ! -L $WORK ]] && rm -rf -- "$WORK" ;;
  esac
}
trap cleanup EXIT
mkdir -m 0700 "$WORK/source-c" "$WORK/source-t" "$WORK/bin" "$WORK/gocache" "$WORK/gotmp"
tar -xzf "$SOURCE_ARCHIVE" -C "$WORK/source-c"
tar -xzf "$SOURCE_ARCHIVE" -C "$WORK/source-t"

(cd "$WORK/source-t" && git apply --check "$PATCH" && git apply "$PATCH") \
  >"$OUT/patch-apply.stdout" 2>"$OUT/patch-apply.stderr"
gofmt -w "$WORK/source-t/pkg/vfs/writer.go" "$WORK/source-t/pkg/vfs/vfs.go" \
  "$WORK/source-t/cmd/flags.go" "$WORK/source-t/cmd/mount.go" \
  "$WORK/source-t/pkg/vfs/writer_eager_freeze_test.go"

go_env=(GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOCACHE="$WORK/gocache" GOTMPDIR="$WORK/gotmp")
(cd "$WORK/source-t" && env "${go_env[@]}" go test ./pkg/vfs \
  -run '^TestExperimentalEagerFreeze' -count=1 -timeout=10m) \
  >"$OUT/eager-tests.stdout" 2>"$OUT/eager-tests.stderr"
(cd "$WORK/source-t" && env "${go_env[@]}" go test -race ./pkg/vfs \
  -run '^TestExperimentalEagerFreeze' -count=1 -timeout=10m) \
  >"$OUT/eager-race.stdout" 2>"$OUT/eager-race.stderr"
(cd "$WORK/source-t" && env "${go_env[@]}" go test ./pkg/vfs \
  -run '^(TestVFSBasic|TestVFSIO|TestFill)$' -count=1 -timeout=10m) \
  >"$OUT/relevant-vfs.stdout" 2>"$OUT/relevant-vfs.stderr"
(cd "$WORK/source-t" && env "${go_env[@]}" go test ./cmd -run '^$' -count=1 -timeout=10m) \
  >"$OUT/cmd-compile.stdout" 2>"$OUT/cmd-compile.stderr"

ldflags='-X github.com/juicedata/juicefs/pkg/version.revision=0b90c7d -X github.com/juicedata/juicefs/pkg/version.revisionDate=2026-07-30 -s -w'
for arm in c t; do
  (cd "$WORK/source-$arm" && env "${go_env[@]}" CGO_ENABLED=1 \
    CGO_CFLAGS="-I$SDK_ROOT/include" CGO_LDFLAGS="-L$SDK_ROOT/lib/x86_64-linux-gnu" \
    go build -buildvcs=false -tags ceph -gcflags='' -ldflags="$ldflags" \
    -o "$WORK/bin/juicefs-06-2c-$arm" .) \
    >"$OUT/build-$arm.stdout" 2>"$OUT/build-$arm.stderr"
done

set +e
"$WORK/bin/juicefs-06-2c-c" mount --experimental-eager-freeze \
  >"$OUT/c-flag.stdout" 2>"$OUT/c-flag.stderr"
c_rc=$?
"$WORK/bin/juicefs-06-2c-t" mount --experimental-eager-freeze \
  >"$OUT/t-flag.stdout" 2>"$OUT/t-flag.stderr"
t_rc=$?
set -e
[[ $c_rc -ne 0 && $t_rc -ne 0 ]] || die flag_probe_unexpected_rc
grep -Fq 'unknown option: "--experimental-eager-freeze"' "$OUT/c-flag.stderr" || die control_accepted_experimental_flag
grep -Fq 'This command requires at least 2 arguments' "$OUT/t-flag.stdout" || die treatment_rejected_experimental_flag
! grep -Eq 'unknown option|flag provided but not defined' "$OUT/t-flag.stderr" || die treatment_flag_parse_failure

cp -- "$PATCH" "$OUT/eager-freeze.patch"
cp -- "$0" "$OUT/t06-2c-gate0-offline.sh"
{
  printf 'field\tvalue\n'
  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'source_archive\t%s\n' "$SOURCE_ARCHIVE"
  printf 'source_archive_sha256\t%s\n' "$SOURCE_SHA256"
  printf 'patch_sha256\t%s\n' "$(sha256sum "$PATCH" | awk '{print $1}')"
  printf 'go_version\t%s\n' "$(go version)"
  for arm in c t; do
    bin="$WORK/bin/juicefs-06-2c-$arm"
    cp -- "$bin" "$OUT/juicefs-06-2c-$arm"
    printf '%s_sha256\t%s\n' "$arm" "$(sha256sum "$bin" | awk '{print $1}')"
    printf '%s_md5\t%s\n' "$arm" "$(md5sum "$bin" | awk '{print $1}')"
    printf '%s_version\t%s\n' "$arm" "$($bin version 2>&1)"
  done
} >"$OUT/identity.tsv"

{
  printf 'check\tstatus\tnote\n'
  printf 'source_identity\tPASS\tsha256 matched frozen authority\n'
  printf 'patch_apply\tPASS\tfresh authority tree\n'
  printf 'trigger_boundary_tests\tPASS\tdefault-off global-aligned cross-chunk partial misaligned growing known-content pre-read-commit\n'
  printf 'race_tests\tPASS\tcandidate-specific tests\n'
  printf 'related_vfs_tests\tPASS\tTestVFSBasic TestVFSIO TestFill\n'
  printf 'cmd_compile\tPASS\tflag wiring compiles\n'
  printf 'ceph_build_ct\tPASS\tsame toolchain tags and ldflags\n'
  printf 'full_vfs_suite\tNOT_RUN_ENV_BLOCKED\trequires local Redis/socket access; not reported PASS\n'
  printf 'environment_access\tNOT_RUN\tGate 0 is offline only\n'
  printf 'production_candidate\tNO\tinvestigation binaries only\n'
} >"$OUT/verdict.tsv"

{
  printf '# Commands executed by t06-2c-gate0-offline.sh\n'
  printf 'sha256sum %q\n' "$SOURCE_ARCHIVE"
  printf 'git apply --check %q && git apply %q\n' "$PATCH" "$PATCH"
  printf "go test ./pkg/vfs -run '^TestExperimentalEagerFreeze' -count=1\n"
  printf "go test -race ./pkg/vfs -run '^TestExperimentalEagerFreeze' -count=1\n"
  printf "go test ./pkg/vfs -run '^(TestVFSBasic|TestVFSIO|TestFill)$' -count=1\n"
  printf "go test ./cmd -run '^$' -count=1\n"
  printf 'go build -buildvcs=false -tags ceph <same frozen ldflags> # C and T\n'
} >"$OUT/commands.sh"

if grep -nEi '(password|passwd|secret)[[:space:]]*=' "$0" "$PATCH" >"$OUT/secret-scan.txt"; then
  die possible_cleartext_secret
fi
if grep -nE 'sudo[[:space:]]+(reboot|shutdown|halt|poweroff|systemctl|rm|chown|chmod|dd|wipefs|lvremove|lvcreate|umount)|(^|[[:space:]])(reboot|shutdown|halt|poweroff)([[:space:]]|$)' \
  "$0" >"$OUT/dangerous-command-scan.txt"; then
  die dangerous_command_present
fi
printf 'NO_MATCH\n' >"$OUT/secret-scan.txt"
printf 'NO_MATCH\n' >"$OUT/dangerous-command-scan.txt"
(cd "$OUT" && find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum >manifest.sha256)
printf 'T062C_GATE0_PASS\trun_id=%s\tout=%s\n' "$RUN_ID" "$OUT"
