# === 步骤0+1：初始化 ===
set -uo pipefail
umask 077

RUN_ID=$(date +%Y%m%d-%H%M%S)
OUT_PARENT=/home/lilingfeng/tmp
OUT=$OUT_PARENT/juicefs-c01-r1-$RUN_ID
SOURCE=/home/lilingfeng/project/juicefs
MAIN_COMMIT=edabf9c24601510476e7453abff177f4aaca07ac
SYNC_PATCH=/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/patch/juicefs-flush-race-fix-main.patch
TASKBOOK=/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C01-R1-main-deterministic-flush-dispatch.md

mkdir -p "$OUT_PARENT"
FREE_KB=$(df -Pk "$OUT_PARENT" | awk 'NR == 2 {print $4}')
test "$FREE_KB" -ge 20971520 || exit 10

mkdir -p "$OUT"/{assets,cache/go-build-125,cache/go-build-126,cache/go-mod,cache/go-tmp,diffs,logs,meta,rc,src}
: > "$OUT/commands.sh"
chmod 600 "$OUT/commands.sh"
: > "$OUT/meta/dependency-adaptations.txt"
printf '%s\n' "$OUT" > "$OUT/meta/out-path.txt"
printf '%s\n' "$FREE_KB" > "$OUT/meta/free-kb-before.txt"
cp "$TASKBOOK" "$OUT/meta/taskbook.snapshot.md"

exec 19>>"$OUT/logs/shell-xtrace.log"
export BASH_XTRACEFD=19
PS4='+C01-R1 '
set -x

# === 步骤2：三臂独立 clone ===
for ARM in S-stock A-sync B-async-catchup; do
  git clone --no-hardlinks --no-checkout "$SOURCE" "$OUT/src/$ARM" \
    > "$OUT/logs/clone-$ARM.log" 2>&1 || exit 11
  git -C "$OUT/src/$ARM" cat-file -e "$MAIN_COMMIT^{commit}" \
    >> "$OUT/logs/clone-$ARM.log" 2>&1 || exit 12
  git -C "$OUT/src/$ARM" checkout --detach "$MAIN_COMMIT" \
    >> "$OUT/logs/clone-$ARM.log" 2>&1 || exit 13
  HEAD_NOW=$(git -C "$OUT/src/$ARM" rev-parse HEAD) || exit 14
  printf '%s\t%s\n' "$ARM" "$HEAD_NOW" >> "$OUT/meta/arm-heads-before.tsv"
  git -C "$OUT/src/$ARM" status --porcelain \
    > "$OUT/meta/$ARM-status-before.txt"
done

awk -v want="$MAIN_COMMIT" '$2 != want {bad=1} END{exit bad}' \
  "$OUT/meta/arm-heads-before.tsv" || exit 15

for ARM in S-stock A-sync B-async-catchup; do
  test ! -s "$OUT/meta/$ARM-status-before.txt" || exit 16
done

# === 步骤3：固定工具链和隔离缓存 ===
export GOPROXY=https://goproxy.cn,direct
export GOMODCACHE="$OUT/cache/go-mod"
export GOTMPDIR="$OUT/cache/go-tmp"

env GOTOOLCHAIN=go1.25.7 GOCACHE="$OUT/cache/go-build-125" \
  go version > "$OUT/meta/go125-version.txt" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/toolchain-go125.rc"

env GOTOOLCHAIN=go1.25.7 GOCACHE="$OUT/cache/go-build-125" \
  go env GOOS GOARCH GOVERSION GOTOOLCHAIN GOPROXY GOMODCACHE GOCACHE GOTMPDIR CGO_ENABLED CC \
  > "$OUT/meta/go125-env.txt" 2>&1

env GOTOOLCHAIN=local GOCACHE="$OUT/cache/go-build-126" \
  go version > "$OUT/meta/go126-version.txt" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/toolchain-go126.rc"

env GOTOOLCHAIN=local GOCACHE="$OUT/cache/go-build-126" \
  go env GOOS GOARCH GOVERSION GOTOOLCHAIN GOPROXY GOMODCACHE GOCACHE GOTMPDIR CGO_ENABLED CC \
  > "$OUT/meta/go126-env.txt" 2>&1

test "$(cat "$OUT/rc/toolchain-go125.rc")" -eq 0 || exit 20
test "$(cat "$OUT/rc/toolchain-go126.rc")" -eq 0 || exit 21
grep -q '^go version go1\.25\.7 linux/amd64$' "$OUT/meta/go125-version.txt" || exit 22
grep -q '^go version go1\.26\.0 linux/amd64$' "$OUT/meta/go126-version.txt" || exit 23

cd "$OUT/src/S-stock"

env GOTOOLCHAIN=go1.25.7 GOCACHE="$OUT/cache/go-build-125" \
  go mod download > "$OUT/logs/go125-go-mod-download.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/go125-go-mod-download.rc"

env GOTOOLCHAIN=local GOCACHE="$OUT/cache/go-build-126" \
  go mod download > "$OUT/logs/go126-go-mod-download.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/go126-go-mod-download.rc"

test "$(cat "$OUT/rc/go125-go-mod-download.rc")" -eq 0 || exit 24
test "$(cat "$OUT/rc/go126-go-mod-download.rc")" -eq 0 || exit 25

for ARM in S-stock A-sync B-async-catchup; do
  git -C "$OUT/src/$ARM" status --porcelain \
    > "$OUT/meta/$ARM-status-after-download.txt"
  test ! -s "$OUT/meta/$ARM-status-after-download.txt" || exit 26
done
