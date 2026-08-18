# C01-R1：修订后的 main 漏派发确定性复现与双工具链候选验证

> 面向执行方：GLM  
> 方案与结果复核：Codex  
> 日期：2026-08-16  
> 性质：开发机隔离单元测试；不占 03 阶段性能任务编号  
> 基座：JuiceFS main 固定提交 edabf9c24601510476e7453abff177f4aaca07ac  
> 主工具链：Go 1.25.7  
> 兼容工具链：本机固定 Go 1.26.0  
> 工作根目录：/home/lilingfeng/tmp；严禁再次使用 /tmp  
> 重要：不挂载 JuiceFS，不连接 Redis/Ceph/TiKV，不运行 fio，不修改依赖，不提交或推送社区。

---

## ⚑ 计划线

~~~
C01 首次执行
  ├─ 三臂固定 main 提交成功
  └─ 全包基线被环境依赖阻塞
       ├─ pkg/vfs 全量测试硬编码访问 Redis，与“禁止 Redis”冲突
       ├─ pkg/chunk 测试依赖 mockey，在本机 Go 1.26 下链接失败
       └─ /tmp tmpfs 空间不足
  ↓
★ C01-R1（你在这里）
  ├─ 工作区、Go 缓存和编译临时目录全部迁到磁盘
  ├─ 主工具链对齐上游单测环境：Go 1.25.7
  ├─ Go 1.26 只跑与本问题相关的兼容矩阵
  ├─ 基线改为 pkg/vfs 编译门禁 + 明确的纯内存测试白名单
  ├─ stock main 确定性复现
  ├─ A：当前同步 NewSlice 补丁
  └─ B：异步 ID 就绪后补派发候选
  ↓
Codex 分析原始结果
  ├─ 证据不闭合：修测试或补丁，禁止进入性能验证
  └─ 证据闭合：编写下一份故障注入/完整性任务书
~~~

一句话：排除与目标无关的 Redis、mockey 和 tmpfs 干扰，在 Go 1.25.7 与 Go 1.26.0 下，用同一套确定性测试证明 main 的源码行为，并验证 A/B 两种修法。

---

## 〇、为什么需要 R1

### 0.1 首次执行的有效结论

首次执行报告：

~~~
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C01-baseline-block-20260816.md
~~~

该次执行只证明：

1. 三臂均能固定到 edabf9c24601510476e7453abff177f4aaca07ac；
2. 原 C01 的全包基线门禁不适用于“无外部服务”的源码级任务；
3. 本机 /tmp 不适合作为 JuiceFS 三臂构建目录；
4. 没有注入测试、没有应用补丁，因此没有得到任何 main 缺陷或补丁有效性结论。

R1 是一次全新执行。禁止把首次执行的 rc、缓存、源码 clone 或日志混入 R1。

### 0.2 原门禁为何无效

原命令同时运行 pkg/vfs 与 pkg/chunk 的全部测试：

- pkg/vfs 的既有测试包含 redis://127.0.0.1:6379，用例失败时还可能通过 log.Fatalf 终止整个测试进程；
- pkg/chunk 的 disk_cache_test.go 引入 mockey，其测试二进制在本机 Go 1.26.0 下无法链接；
- C01 新增测试位于 pkg/vfs，使用纯内存 fake，不运行 pkg/chunk 的测试代码，也不需要 Redis。

因此 R1 把“目标包能否编译并运行相关测试”和“整个项目在完整 CI 服务环境下能否全量通过”分开。前者属于本任务；后者放到后续社区质量任务。

### 0.3 工具链口径

- go.mod 声明 go 1.25.0，Go 1.25 是最低工具链，不允许降到 Go 1.23；
- 固定提交的 Makefile 使用 Go 1.25.7 构建镜像，因此 R1 主门禁固定到 go1.25.7；
- 本机已有 go1.26.0，R1 用它补充定向兼容证据；
- 禁止升级 mockey，禁止修改 go.mod/go.sum，禁止为了全量测试启动 Redis。

---

## 一、目标与非目标

### 1.1 主判定 Q1：main 是否存在漏派发

在两个工具链下分别执行十次独立的 stock 正向测试。每一次必须：

- go test 退出码非 0；
- 日志恰好出现一次 C01_MISSED_DISPATCH；
- 失败不是编译错误、panic、超时或其他测试错误。

十次全部符合，才能判定对应工具链下 stock main 稳定复现 missed dispatch。

### 1.2 主判定 Q2：当前同步补丁是否覆盖问题

A-sync 在两个工具链下必须全部满足：

- 正向测试 PASS；
- 半块写负控 PASS；
- 两个测试合跑 count=100 PASS；
- 两个测试 race count=20 PASS，且日志没有 DATA RACE；
- 既有纯内存回归白名单 PASS。

### 1.3 主判定 Q3：异步补派发候选是否覆盖问题

B-async-catchup 使用与 A 完全相同的判据。C01-R1 不根据偏好选 A 或 B，只产生可比较的事实。

### 1.4 源码与审计判定 Q4

- 三臂 HEAD 必须始终等于固定 main commit；
- 三臂测试文件必须逐字节一致；
- S-stock 只允许新增 writer_flush_test.go；
- A/B 只允许修改 writer.go 并新增 writer_flush_test.go；
- go.mod、go.sum、vendor 和其他源码不得变化；
- 所有命令、日志、rc、diff、工具链信息必须归档。

### 1.5 本任务明确不做

- 不运行 pkg/vfs 全量测试；
- 不运行 pkg/chunk 的任何测试；
- 不启动或访问 Redis；
- 不挂载 JuiceFS；
- 不访问 Ceph、TiKV、S3 或其他后端；
- 不运行 fio、benchmark、soak；
- 不修改 v1.3.1；
- 不修改依赖版本；
- 不创建 GitHub issue/PR，不 commit，不 push；
- 不把源码级 PASS 外推为宏观吞吐问题已修复。

---

## 二、固定量、矩阵与数据源

### 2.1 固定量

| 项 | 固定值 |
|---|---|
| 源仓库 | /home/lilingfeng/project/juicefs |
| main commit | edabf9c24601510476e7453abff177f4aaca07ac |
| A 补丁 | patch/juicefs-flush-race-fix-main.patch |
| R1 任务书 | tasks/C01-R1-main-deterministic-flush-dispatch.md |
| 工作根目录 | /home/lilingfeng/tmp |
| 主工具链 | go1.25.7 |
| 兼容工具链 | 本机 local，必须精确为 go1.26.0 |
| GOPROXY 首选 | https://goproxy.cn,direct |
| 测试包 | 仅 ./pkg/vfs |
| stock 正向重复 | 十次独立进程 |
| A/B 普通重复 | count=100 |
| A/B race 重复 | count=20 |

### 2.2 三臂

| 臂 | 变更 | 正向 | 负控 | 既有回归 |
|---|---|---:|---:|---:|
| S-stock | 测试文件，不改 writer.go | 十次均预期 FAIL + 指定标识 | PASS | 注入前 PASS |
| A-sync | 当前同步 ID 补丁 + 测试 | PASS | PASS | PASS |
| B-async-catchup | 附录 B + 测试 | PASS | PASS | PASS |

### 2.3 两个工具链

| 标签 | GOTOOLCHAIN | 定位 | 是否为通过条件 |
|---|---|---|---:|
| go125 | go1.25.7 | 对齐项目最低版本和上游单测环境 | 是 |
| go126 | local，且 GOVERSION=go1.26.0 | 当前 main 的新工具链定向兼容 | 是 |

两个工具链执行完全相同的 C01 正向、负控、重复、race 和纯内存回归。pkg/chunk 的 Go 1.26 mockey 失败不在矩阵内。

### 2.4 唯一数据源

| 判据 | 数据源 |
|---|---|
| 工具链固定 | meta/go125-env.txt、meta/go126-env.txt、rc/toolchain-*.rc |
| HEAD 固定 | meta/arm-heads-before.tsv、meta/arm-heads-after.tsv |
| 无 TestMain | logs/static-vfs-testmain.log、rc/static-vfs-testmain.rc |
| 无测试名冲突 | logs/static-test-name-conflict.log、对应 rc |
| 基线可编译 | logs/TOOL-S-stock-baseline-compile.log、对应 rc |
| 纯内存基线 | logs/TOOL-S-stock-baseline-memory.log、对应 rc |
| stock 复现 | meta/TOOL-S-stock-positive-repeat10.tsv 和十份日志 |
| stock 负控 | logs/TOOL-S-stock-negative-count20.log |
| A/B 正向负控 | logs/TOOL-ARM-positive.log、negative.log |
| 普通重复 | logs/TOOL-ARM-targeted-count100.log |
| race | logs/TOOL-ARM-race-count20.log |
| 既有回归 | logs/TOOL-ARM-memory-regression.log |
| 变更白名单 | meta/ARM-changed-paths.txt、logs/ARM-path-guard.log |
| 完整 diff | diffs/ARM-full.diff |
| 实际命令 | commands.sh 与 logs/shell-xtrace.log |
| 汇总 | summary.tsv |
| 文件完整性 | SHA256SUMS、archive 的独立 sha256 |

---

## 三、安全与执行规则

### 3.1 全新 OUT

必须创建：

~~~
/home/lilingfeng/tmp/juicefs-c01-r1-YYYYmmdd-HHMMSS
~~~

禁止使用或修改：

~~~
/tmp/juicefs-c01-20260816-220647
/home/lilingfeng/tmp/c01-gocache
/home/lilingfeng/tmp/c01-gotmp
~~~

旧 OUT 只作为历史证据保留。R1 不从旧 OUT 复制源码、测试文件、构建缓存或结果。

### 3.2 命令记录

commands.sh 必须是实际命令的追加式账本，不得用“第一次尝试”“已复制缓存”等注释代替真实命令。

执行规则：

1. 每个命令块在执行前原样追加到 commands.sh；
2. 临时环境适配命令也必须先追加再执行；
3. 同时启用 Bash xtrace，写入 logs/shell-xtrace.log；
4. 禁止把令牌、密码或私有凭据写入两份记录；
5. 最终打包前先追加最终打包命令，再冻结 commands.sh 和 xtrace。

### 3.3 失败处理

- 工具链、依赖、固定提交、静态门禁或未注入基线失败：立即停止测试动作，转到步骤 13 做阻塞归档；
- stock 正向复现不符合预期：停止，不测试已经在隔离臂中应用的候选补丁；
- stock 门禁符合预期后，A/B 矩阵中的失败只记录，不自行改代码、改等待时间或降低次数；
- 主工具链矩阵不通过时，不运行兼容工具链矩阵；
- 任何失败都不得复用同一日志覆盖原始输出；
- 若是命令被外部中断而非测试返回，停止并新建 OUT；禁止在同一 OUT 伪装成首次执行。

---

## 四、执行步骤

### 步骤 0：通读与 preflight

执行前完整阅读：

1. 本任务书；
2. C01 首次阻塞报告；
3. TASK-BOOK-AUTHORING-GUIDE 的 §二.8、§二.9、§二.11、§二.12；
4. prod-deploy/skills/SYSTEM-SAFETY-SKILL.md；
5. debug 包的 docs/SUMMARY.md。

通读后先完成步骤 1 的 OUT 初始化，再在运行步骤 2 前把以下确认写入 meta/preflight.txt：

- 理解首次执行没有产生缺陷或补丁结论；
- 理解 R1 不跑全量 pkg/vfs 和任何 pkg/chunk 测试；
- 理解禁止 Redis、fio、mount、Ceph、TiKV；
- 理解不能改固定提交、附录 A/B 或重复次数；
- 理解工作区不得放在 /tmp；
- 理解 Go 1.25.7 和 Go 1.26.0 都是通过条件；
- 理解 GLM 只交付原始事实，不选择 A/B。

### 步骤 1：建立磁盘工作区并检查容量

参考命令：

~~~bash
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
~~~

要求：

- 至少 20 GiB 可用空间；
- 不执行 rm、git clean 或清理旧 OUT；
- 初始化命令在 commands.sh 创建后必须补录；
- 后续命令在同一个 Bash 会话中执行。commands.sh 是追加式账本，不得在其自身路径上直接执行；需要重放时先复制到另一路径，避免初始化命令把账本自身截断。

### 步骤 2：建立三个独立 clone

~~~bash
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

awk -v want="$MAIN_COMMIT" '$2 != want {bad=1} END {exit bad}' \
  "$OUT/meta/arm-heads-before.tsv" || exit 15

for ARM in S-stock A-sync B-async-catchup; do
  test ! -s "$OUT/meta/$ARM-status-before.txt" || exit 16
done
~~~

不得 fetch origin/main，不得使用 SOURCE 当前 HEAD，也不得复用 C01 的 clone。

### 步骤 3：固定工具链和隔离缓存

~~~bash
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
~~~

Go 1.25.7 可由当前 go 命令通过 GOPROXY 下载到隔离 GOMODCACHE。允许在下载失败时切换 GOPROXY 或证书配置；禁止：

- 安装 Go 1.23；
- 修改系统 GOROOT；
- 使用 sudo；
- 修改 go.mod/go.sum；
- 复制旧 C01 或全局 GOCACHE/GOMODCACHE；
- 把工具链版本改成“可用的任意版本”。

依赖下载：

~~~bash
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
~~~

### 步骤 4：静态门禁与无外部服务基线

先证明目标包没有 TestMain，也没有同名测试：

~~~bash
cd "$OUT/src/S-stock"

git grep -n 'func TestMain' -- 'pkg/vfs/*_test.go' \
  > "$OUT/logs/static-vfs-testmain.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/static-vfs-testmain.rc"
test "$RC" -eq 1 || exit 30

git grep -n -E 'TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady|TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady' \
  -- 'pkg/vfs/*_test.go' > "$OUT/logs/static-test-name-conflict.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/static-test-name-conflict.rc"
test "$RC" -eq 1 || exit 31

git grep -n 'redis://127.0.0.1:6379' -- 'pkg/vfs/*_test.go' \
  > "$OUT/meta/excluded-vfs-redis-tests.txt" 2>&1 || true
git grep -n 'bytedance/mockey' -- 'pkg/chunk/*_test.go' \
  > "$OUT/meta/excluded-chunk-mockey-tests.txt" 2>&1 || true
~~~

初始化机械结果表和测试函数：

~~~bash
printf 'toolchain\tarm\ttest\trc\texpected\tlog\texpectation_matched\n' \
  > "$OUT/meta/test-results.raw.tsv"

run_zero_test() {
  local tool_label=$1
  local toolchain=$2
  local build_cache=$3
  local arm=$4
  local test_id=$5
  shift 5

  local log_rel=logs/$tool_label-$arm-$test_id.log
  local log_abs=$OUT/$log_rel

  (
    cd "$OUT/src/$arm" || exit 98
    env GOTOOLCHAIN="$toolchain" GOCACHE="$build_cache" GOFLAGS=-mod=readonly \
      go test "$@"
  ) > "$log_abs" 2>&1
  local rc=$?
  local matched=NO
  test "$rc" -eq 0 && matched=YES

  printf '%s\n' "$rc" > "$OUT/rc/$tool_label-$arm-$test_id.rc"
  printf '%s\t%s\t%s\t%s\t0\t%s\t%s\n' \
    "$tool_label" "$arm" "$test_id" "$rc" "$log_rel" "$matched" \
    >> "$OUT/meta/test-results.raw.tsv"
}
~~~

基线白名单：

~~~bash
BASELINE_RE='^(TestSmode|TestEntryString|TestError|TestVFSIO)$'

run_zero_test go125 go1.25.7 "$OUT/cache/go-build-125" \
  S-stock baseline-compile \
  ./pkg/vfs -run '^$' -count=1 -timeout=5m
run_zero_test go125 go1.25.7 "$OUT/cache/go-build-125" \
  S-stock baseline-memory \
  ./pkg/vfs -run "$BASELINE_RE" -count=1 -v -timeout=10m

run_zero_test go126 local "$OUT/cache/go-build-126" \
  S-stock baseline-compile \
  ./pkg/vfs -run '^$' -count=1 -timeout=5m
run_zero_test go126 local "$OUT/cache/go-build-126" \
  S-stock baseline-memory \
  ./pkg/vfs -run "$BASELINE_RE" -count=1 -v -timeout=10m

for RCFILE in \
  "$OUT/rc/go125-S-stock-baseline-compile.rc" \
  "$OUT/rc/go125-S-stock-baseline-memory.rc" \
  "$OUT/rc/go126-S-stock-baseline-compile.rc" \
  "$OUT/rc/go126-S-stock-baseline-memory.rc"; do
  test "$(cat "$RCFILE")" -eq 0 || exit 32
done

for TOOL_LABEL in go125 go126; do
  BASELINE_SELECTION_RC=0
  for TEST_NAME in TestSmode TestEntryString TestError TestVFSIO; do
    PASS_COUNT=$(grep -c -- "--- PASS: $TEST_NAME" \
      "$OUT/logs/$TOOL_LABEL-S-stock-baseline-memory.log" || true)
    test "$PASS_COUNT" -eq 1 || BASELINE_SELECTION_RC=1
  done
  printf '%s\n' "$BASELINE_SELECTION_RC" \
    > "$OUT/rc/$TOOL_LABEL-S-stock-baseline-memory-selection.rc"
  BASELINE_MATCHED=NO
  test "$BASELINE_SELECTION_RC" -eq 0 && BASELINE_MATCHED=YES
  printf '%s\tS-stock\tbaseline-memory-selection\t%s\t0\t%s\t%s\n' \
    "$TOOL_LABEL" "$BASELINE_SELECTION_RC" \
    "logs/$TOOL_LABEL-S-stock-baseline-memory.log" "$BASELINE_MATCHED" \
    >> "$OUT/meta/test-results.raw.tsv"
  test "$BASELINE_SELECTION_RC" -eq 0 || exit 33
done
~~~

解释：

- run '^$' 编译 pkg/vfs 的生产代码和既有测试文件，但不运行测试函数；
- 白名单中的 TestVFSIO 使用 memkv 与 memory object store；其余三个为纯函数测试；
- 不允许加入 TestReaddirCache、TestVFSReadDirSort、TestReadDirBatch 或 TestReaddir；
- 不允许把 pkg/chunk 加回命令。

### 步骤 5：注入确定性测试

将附录 A 逐字保存到：

~~~
$OUT/assets/writer_flush_test.go
~~~

然后：

~~~bash
gofmt -w "$OUT/assets/writer_flush_test.go"
sha256sum "$OUT/assets/writer_flush_test.go" \
  > "$OUT/meta/test-asset.sha256"

for ARM in S-stock A-sync B-async-catchup; do
  cp "$OUT/assets/writer_flush_test.go" \
    "$OUT/src/$ARM/pkg/vfs/writer_flush_test.go"
  gofmt -w "$OUT/src/$ARM/pkg/vfs/writer_flush_test.go"
  cmp -s "$OUT/assets/writer_flush_test.go" \
    "$OUT/src/$ARM/pkg/vfs/writer_flush_test.go" || exit 40
  git -C "$OUT/src/$ARM" add -N pkg/vfs/writer_flush_test.go
done
~~~

git add -N 只允许在隔离 clone 中登记 intent-to-add，使 git diff 能看到测试文件。禁止普通 git add、commit 或 push。

禁止修改附录 A 的：

- blockSize；
- fake meta/writer/store；
- dummy frozen slice；
- 2 秒 ID 等待；
- 1 秒正向派发等待；
- 250ms 负控窗口；
- 100ms 重复派发窗口；
- C01_MISSED_DISPATCH；
- FlushTo 次数和 offset 断言。

### 步骤 6：应用候选补丁

A-sync：

~~~bash
cd "$OUT/src/A-sync"
git apply --check "$SYNC_PATCH" \
  > "$OUT/logs/A-sync-apply-check.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/A-sync-apply-check.rc"
test "$RC" -eq 0 || exit 41

git apply "$SYNC_PATCH" > "$OUT/logs/A-sync-apply.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/A-sync-apply.rc"
test "$RC" -eq 0 || exit 42
gofmt -w pkg/vfs/writer.go pkg/vfs/writer_flush_test.go
~~~

只使用 A patch 的 writer.go 代码 hunk。patch 说明中关于 #6311 的旧归因不得写入 R1 结论。

B-async-catchup：

将附录 B 逐字保存为：

~~~
$OUT/assets/async-catchup-main.patch
~~~

然后：

~~~bash
cd "$OUT/src/B-async-catchup"
git apply --check "$OUT/assets/async-catchup-main.patch" \
  > "$OUT/logs/B-async-catchup-apply-check.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/B-async-catchup-apply-check.rc"
test "$RC" -eq 0 || exit 43

git apply "$OUT/assets/async-catchup-main.patch" \
  > "$OUT/logs/B-async-catchup-apply.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/B-async-catchup-apply.rc"
test "$RC" -eq 0 || exit 44
gofmt -w pkg/vfs/writer.go pkg/vfs/writer_flush_test.go
~~~

禁止 GLM 修改 B 的锁范围、freezed 条件、完整 block 条件、错误处理或日志。

### 步骤 7：定义 stock 复现与候选矩阵函数

~~~bash
run_stock_repro() {
  local tool_label=$1
  local toolchain=$2
  local build_cache=$3
  local details=$OUT/meta/$tool_label-S-stock-positive-repeat10.tsv
  local aggregate=0

  printf 'iteration\trc\tmarker_count\ttest_fail_count\tforbidden_error\texpectation_matched\tlog\n' \
    > "$details"

  for iteration in 01 02 03 04 05 06 07 08 09 10; do
    local log_rel=logs/$tool_label-S-stock-positive-$iteration.log
    local log_abs=$OUT/$log_rel

    (
      cd "$OUT/src/S-stock" || exit 98
      env GOTOOLCHAIN="$toolchain" GOCACHE="$build_cache" GOFLAGS=-mod=readonly \
        go test ./pkg/vfs \
          -run '^TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady$' \
          -count=1 -v -timeout=2m
    ) > "$log_abs" 2>&1
    local rc=$?
    local marker_count
    marker_count=$(grep -c 'C01_MISSED_DISPATCH' "$log_abs" || true)
    local test_fail_count
    test_fail_count=$(grep -c -- \
      '--- FAIL: TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady' \
      "$log_abs" || true)
    local forbidden_error=NO
    if grep -Eq '\[build failed\]|panic:|fatal error:|test timed out|DATA RACE' \
      "$log_abs"; then
      forbidden_error=YES
    fi
    local matched=NO

    if test "$rc" -ne 0 \
      && test "$marker_count" -eq 1 \
      && test "$test_fail_count" -eq 1 \
      && test "$forbidden_error" = NO; then
      matched=YES
    else
      aggregate=1
    fi

    printf '%s\n' "$rc" \
      > "$OUT/rc/$tool_label-S-stock-positive-$iteration.rc"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$iteration" "$rc" "$marker_count" "$test_fail_count" \
      "$forbidden_error" "$matched" "$log_rel" \
      >> "$details"
  done

  printf '%s\n' "$aggregate" \
    > "$OUT/rc/$tool_label-S-stock-positive-repeat10-expectation.rc"
  local matched=NO
  test "$aggregate" -eq 0 && matched=YES
  printf '%s\tS-stock\tpositive-repeat10-expectation\t%s\t0\t%s\t%s\n' \
    "$tool_label" "$aggregate" \
    "meta/$tool_label-S-stock-positive-repeat10.tsv" "$matched" \
    >> "$OUT/meta/test-results.raw.tsv"
}

run_candidate_matrix() {
  local tool_label=$1
  local toolchain=$2
  local build_cache=$3

  for ARM in A-sync B-async-catchup; do
    run_zero_test "$tool_label" "$toolchain" "$build_cache" \
      "$ARM" positive \
      ./pkg/vfs \
      -run '^TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady$' \
      -count=1 -v -timeout=2m

    run_zero_test "$tool_label" "$toolchain" "$build_cache" \
      "$ARM" negative \
      ./pkg/vfs \
      -run '^TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady$' \
      -count=1 -v -timeout=2m

    run_zero_test "$tool_label" "$toolchain" "$build_cache" \
      "$ARM" targeted-count100 \
      ./pkg/vfs \
      -run '^(TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady|TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady)$' \
      -count=100 -v -timeout=10m

    run_zero_test "$tool_label" "$toolchain" "$build_cache" \
      "$ARM" memory-regression \
      ./pkg/vfs -run "$BASELINE_RE" -count=1 -v -timeout=10m

    run_zero_test "$tool_label" "$toolchain" "$build_cache" \
      "$ARM" race-count20 \
      -race ./pkg/vfs \
      -run '^(TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady|TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady)$' \
      -count=20 -v -timeout=10m
  done
}

gate_candidate_matrix() {
  local tool_label=$1
  local bad=0

  for ARM in A-sync B-async-catchup; do
    for TEST_ID in positive negative targeted-count100 memory-regression race-count20; do
      local rc_file=$OUT/rc/$tool_label-$ARM-$TEST_ID.rc
      if ! test -f "$rc_file" || ! test "$(cat "$rc_file")" -eq 0; then
        bad=1
      fi
    done

    if grep -q 'DATA RACE' \
      "$OUT/logs/$tool_label-$ARM-race-count20.log"; then
      bad=1
    fi

    if ! test "$(grep -c -- '--- PASS: TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady' \
      "$OUT/logs/$tool_label-$ARM-positive.log" || true)" -eq 1; then
      bad=1
    fi
    if ! test "$(grep -c -- '--- PASS: TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady' \
      "$OUT/logs/$tool_label-$ARM-negative.log" || true)" -eq 1; then
      bad=1
    fi
    if ! test "$(grep -c -- '--- PASS: TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady' \
      "$OUT/logs/$tool_label-$ARM-targeted-count100.log" || true)" -eq 100; then
      bad=1
    fi
    if ! test "$(grep -c -- '--- PASS: TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady' \
      "$OUT/logs/$tool_label-$ARM-targeted-count100.log" || true)" -eq 100; then
      bad=1
    fi
    if ! test "$(grep -c -- '--- PASS: TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady' \
      "$OUT/logs/$tool_label-$ARM-race-count20.log" || true)" -eq 20; then
      bad=1
    fi
    if ! test "$(grep -c -- '--- PASS: TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady' \
      "$OUT/logs/$tool_label-$ARM-race-count20.log" || true)" -eq 20; then
      bad=1
    fi
    for TEST_NAME in TestSmode TestEntryString TestError TestVFSIO; do
      if ! test "$(grep -c -- "--- PASS: $TEST_NAME" \
        "$OUT/logs/$tool_label-$ARM-memory-regression.log" || true)" -eq 1; then
        bad=1
      fi
    done
  done

  printf '%s\n' "$bad" \
    > "$OUT/rc/$tool_label-candidate-matrix-expectation.rc"
  local matched=NO
  test "$bad" -eq 0 && matched=YES
  printf '%s\tmatrix\tcandidate-matrix-expectation\t%s\t0\t%s\t%s\n' \
    "$tool_label" "$bad" \
    "rc/$tool_label-candidate-matrix-expectation.rc" "$matched" \
    >> "$OUT/meta/test-results.raw.tsv"
  return "$bad"
}
~~~

不得自行编辑这些函数。每次 go test 都产生独立日志和 rc；禁止用管道掩盖 go test 的退出码。

### 步骤 8：执行 Go 1.25.7 主矩阵

先运行 stock：

~~~bash
run_stock_repro go125 go1.25.7 "$OUT/cache/go-build-125"
test "$(cat "$OUT/rc/go125-S-stock-positive-repeat10-expectation.rc")" -eq 0 \
  || exit 50

run_zero_test go125 go1.25.7 "$OUT/cache/go-build-125" \
  S-stock negative-count20 \
  ./pkg/vfs \
  -run '^TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady$' \
  -count=20 -v -timeout=2m
test "$(cat "$OUT/rc/go125-S-stock-negative-count20.rc")" -eq 0 \
  || exit 51
NEGATIVE_PASS_COUNT=$(grep -c -- \
  '--- PASS: TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady' \
  "$OUT/logs/go125-S-stock-negative-count20.log" || true)
NEGATIVE_SELECTION_RC=1
test "$NEGATIVE_PASS_COUNT" -eq 20 && NEGATIVE_SELECTION_RC=0
printf '%s\n' "$NEGATIVE_SELECTION_RC" \
  > "$OUT/rc/go125-S-stock-negative-count20-selection.rc"
NEGATIVE_MATCHED=NO
test "$NEGATIVE_SELECTION_RC" -eq 0 && NEGATIVE_MATCHED=YES
printf 'go125\tS-stock\tnegative-count20-selection\t%s\t0\t%s\t%s\n' \
  "$NEGATIVE_SELECTION_RC" "logs/go125-S-stock-negative-count20.log" \
  "$NEGATIVE_MATCHED" >> "$OUT/meta/test-results.raw.tsv"
test "$NEGATIVE_SELECTION_RC" -eq 0 || exit 51
~~~

只有上述门禁全部符合预期，才能执行：

~~~bash
run_candidate_matrix go125 go1.25.7 "$OUT/cache/go-build-125"
gate_candidate_matrix go125
RC=$?
test "$RC" -eq 0 || exit 52
~~~

若 A/B 任一测试失败，保留两臂已经完成的所有日志，禁止调整补丁或测试后重跑。

### 步骤 9：执行 Go 1.26.0 兼容矩阵

只有 Go 1.25.7 主矩阵完整通过，才运行：

~~~bash
run_stock_repro go126 local "$OUT/cache/go-build-126"
test "$(cat "$OUT/rc/go126-S-stock-positive-repeat10-expectation.rc")" -eq 0 \
  || exit 60

run_zero_test go126 local "$OUT/cache/go-build-126" \
  S-stock negative-count20 \
  ./pkg/vfs \
  -run '^TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady$' \
  -count=20 -v -timeout=2m
test "$(cat "$OUT/rc/go126-S-stock-negative-count20.rc")" -eq 0 \
  || exit 61
NEGATIVE_PASS_COUNT=$(grep -c -- \
  '--- PASS: TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady' \
  "$OUT/logs/go126-S-stock-negative-count20.log" || true)
NEGATIVE_SELECTION_RC=1
test "$NEGATIVE_PASS_COUNT" -eq 20 && NEGATIVE_SELECTION_RC=0
printf '%s\n' "$NEGATIVE_SELECTION_RC" \
  > "$OUT/rc/go126-S-stock-negative-count20-selection.rc"
NEGATIVE_MATCHED=NO
test "$NEGATIVE_SELECTION_RC" -eq 0 && NEGATIVE_MATCHED=YES
printf 'go126\tS-stock\tnegative-count20-selection\t%s\t0\t%s\t%s\n' \
  "$NEGATIVE_SELECTION_RC" "logs/go126-S-stock-negative-count20.log" \
  "$NEGATIVE_MATCHED" >> "$OUT/meta/test-results.raw.tsv"
test "$NEGATIVE_SELECTION_RC" -eq 0 || exit 61

run_candidate_matrix go126 local "$OUT/cache/go-build-126"
gate_candidate_matrix go126
RC=$?
test "$RC" -eq 0 || exit 62
~~~

Go 1.26 下禁止运行 pkg/chunk。已知 mockey 链接问题与本矩阵无关。

### 步骤 10：核验源码、HEAD 与白名单

~~~bash
for ARM in S-stock A-sync B-async-catchup; do
  cd "$OUT/src/$ARM"

  git status --short > "$OUT/meta/$ARM-status-after.txt"
  git rev-parse HEAD \
    | awk -v arm="$ARM" '{print arm \"\t\" $1}' \
    >> "$OUT/meta/arm-heads-after.tsv"
  git diff --stat > "$OUT/meta/$ARM-diff-stat.txt"
  git diff --full-index > "$OUT/diffs/$ARM-full.diff"
  git diff -- pkg/vfs/writer.go > "$OUT/diffs/$ARM-writer.diff"
  git diff --check > "$OUT/diffs/$ARM-diffcheck.log" 2>&1
  RC=$?
  printf '%s\n' "$RC" > "$OUT/rc/$ARM-diffcheck.rc"

  case "$ARM" in
    S-stock)
      printf '%s\n' pkg/vfs/writer_flush_test.go \
        > "$OUT/meta/$ARM-expected-paths.txt"
      ;;
    A-sync|B-async-catchup)
      printf '%s\n' pkg/vfs/writer.go pkg/vfs/writer_flush_test.go \
        > "$OUT/meta/$ARM-expected-paths.txt"
      ;;
  esac

  LC_ALL=C sort -o "$OUT/meta/$ARM-expected-paths.txt" \
    "$OUT/meta/$ARM-expected-paths.txt"
  git diff --name-only | LC_ALL=C sort \
    > "$OUT/meta/$ARM-changed-paths.txt"
  diff -u "$OUT/meta/$ARM-expected-paths.txt" \
    "$OUT/meta/$ARM-changed-paths.txt" \
    > "$OUT/logs/$ARM-path-guard.log" 2>&1
  RC=$?
  printf '%s\n' "$RC" > "$OUT/rc/$ARM-path-guard.rc"

  cmp "$OUT/assets/writer_flush_test.go" \
    "$OUT/src/$ARM/pkg/vfs/writer_flush_test.go" \
    > "$OUT/logs/$ARM-test-asset-identical.log" 2>&1
  RC=$?
  printf '%s\n' "$RC" > "$OUT/rc/$ARM-test-asset-identical.rc"
done

awk -v want="$MAIN_COMMIT" '$2 != want {bad=1} END {exit bad}' \
  "$OUT/meta/arm-heads-after.tsv" || exit 70

for ARM in S-stock A-sync B-async-catchup; do
  test "$(cat "$OUT/rc/$ARM-diffcheck.rc")" -eq 0 || exit 71
  test "$(cat "$OUT/rc/$ARM-path-guard.rc")" -eq 0 || exit 72
  test "$(cat "$OUT/rc/$ARM-test-asset-identical.rc")" -eq 0 || exit 73
done
~~~

并把源码门禁机械写入结果表：

~~~bash
record_source_gate() {
  local arm=$1
  local test_id=$2
  local rc_file=$3
  local log_rel=$4
  local rc
  rc=$(cat "$rc_file")
  local matched=NO
  test "$rc" -eq 0 && matched=YES
  printf 'source\t%s\t%s\t%s\t0\t%s\t%s\n' \
    "$arm" "$test_id" "$rc" "$log_rel" "$matched" \
    >> "$OUT/meta/test-results.raw.tsv"
}

for ARM in S-stock A-sync B-async-catchup; do
  record_source_gate "$ARM" diffcheck \
    "$OUT/rc/$ARM-diffcheck.rc" "diffs/$ARM-diffcheck.log"
  record_source_gate "$ARM" path-guard \
    "$OUT/rc/$ARM-path-guard.rc" "logs/$ARM-path-guard.log"
  record_source_gate "$ARM" test-asset-identical \
    "$OUT/rc/$ARM-test-asset-identical.rc" \
    "logs/$ARM-test-asset-identical.log"
done
~~~

### 步骤 11：生成并校验 summary.tsv

~~~bash
cp "$OUT/meta/test-results.raw.tsv" "$OUT/summary.tsv"

awk -F '\t' '
  NR == 1 {
    if ($0 != "toolchain\tarm\ttest\trc\texpected\tlog\texpectation_matched") {
      bad=1
    }
    next
  }
  NF != 7 {bad=1}
  $7 != "YES" {bad=1}
  END {exit bad}
' "$OUT/summary.tsv"
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/summary-gate.rc"
test "$RC" -eq 0 || exit 80
~~~

禁止手抄或事后修改 summary.tsv。任何 expectation_matched=NO 都意味着 C01-R1 不通过。

### 步骤 12：合规自查

在 meta/compliance-post.md 逐条回答并给出证据路径：

1. 是否使用了全新磁盘 OUT，且未写 /tmp；
2. 是否只使用固定 main commit；
3. 是否精确使用 Go 1.25.7 和 Go 1.26.0；
4. 是否未复制旧 C01 或全局 Go 缓存；
5. 是否未启动/访问 Redis；
6. 是否未运行 pkg/vfs 全量测试和任何 pkg/chunk 测试；
7. 是否未运行 fio、mount、Ceph、TiKV、sudo；
8. 是否未改 go.mod/go.sum 或其他越界文件；
9. 是否未改附录 A/B、次数、等待窗口和断言；
10. commands.sh 是否包含真实命令而非注释摘要；
11. shell-xtrace.log 是否覆盖打包前的实际执行；
12. 是否未 commit、push 或创建社区 issue；
13. 是否所有失败和环境适配均保留；
14. 是否会保留 OUT、archive 和 archive.sha256 供 Codex 复核。

任一项为否，必须把结论标为 BLOCKED 或 NON-COMPLIANT，不得写 PASS。

### 步骤 13：冻结、校验与归档

执行前，先把本步骤的最终实际命令追加到 commands.sh。然后：

~~~bash
set +x
exec 19>&-

cd "$OUT"
ARCHIVE="$OUT_PARENT/$(basename "$OUT")-artifacts.tar.gz"
printf '%s\n' "$ARCHIVE" > "$OUT/meta/archive-path.txt"

{
  find assets diffs logs meta rc -type f -print0
  printf '%s\0' commands.sh summary.tsv
} | sort -z | xargs -0 sha256sum > SHA256SUMS

sha256sum -c SHA256SUMS > logs/sha256-check.log 2>&1
SHA_RC=$?
printf '%s\n' "$SHA_RC" > rc/sha256-check.rc
test "$SHA_RC" -eq 0 || exit 90

tar -C "$OUT" -czf "$ARCHIVE" \
  assets diffs logs meta rc commands.sh summary.tsv SHA256SUMS
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
~~~

规则：

- archive 不包含 src 与 cache；
- OUT/src 和 OUT/cache 必须保留到 Codex 复核完成；
- SHA256SUMS 不包含自身，也不包含随后生成的 sha256-check 日志和 rc；
- archive.sha256 覆盖最终归档整体；
- 禁止清理旧 C01 或本次 R1；
- 若在任何早期门禁停止，也要生成 partial summary、合规自查和阻塞归档。

---

## 五、通过条件与结果解释

### 5.1 C01-R1 PASS

必须同时满足：

1. 两个工具链版本精确匹配；
2. 两工具链基线 compile 与 memory 白名单全部 PASS；
3. 两工具链 stock 正向各十次均为指定预期失败；
4. 两工具链 stock 负控均 PASS；
5. A/B 在两工具链下的正向、负控、count=100、race count=20、memory regression 全部 PASS；
6. race 日志无 DATA RACE；
7. HEAD、测试资产、diff 和路径白名单全部通过；
8. summary.tsv 全部 YES；
9. 合规自查无否项；
10. 证据校验与 archive sha256 正确。

PASS 只允许写：

“在固定 main commit 的两个指定 Go 工具链下，确定性测试证明首个完整 block 在异步 slice ID 就绪后没有补派发；A 与 B 均覆盖该测试行为。”

不得写：

- main 宏观性能已经修复；
- A 或 B 已经具备合并条件；
- Go data race 已修复；
- 社区一定会接受补丁。

### 5.2 分支解释

| 结果 | 含义 | 下一步 |
|---|---|---|
| stock 不按预期失败 | 测试没有锁定假设或固定 main 行为不同 | 停止，Codex复核测试 |
| A PASS、B FAIL | 当前同步方案覆盖，B 逻辑不足 | 进入 A 专项错误注入设计 |
| A FAIL、B PASS | 当前补丁不能充分覆盖，B 值得继续 | 进入 B 专项错误注入设计 |
| A/B 均 PASS | 两种方案都覆盖最小行为 | Codex根据语义风险设计下一阶段 |
| 两者均 FAIL | 测试/补丁假设不闭合 | 停止，不做性能验证 |
| 仅 Go 1.26 FAIL | 新工具链兼容问题 | 独立定位，不归因于性能 |
| memory regression FAIL | 候选引入或暴露既有回归 | 停止，不进入社区流程 |

---

## 六、GLM 交付物

GLM 只交付原始事实，不选择方案。

必须回报：

1. OUT 绝对路径；
2. archive 和 archive.sha256 绝对路径；
3. archive SHA256；
4. 两个工具链 version/env 全文；
5. arm-heads-before.tsv 与 arm-heads-after.tsv；
6. summary.tsv 全文；
7. 两份 stock positive-repeat10.tsv；
8. 二十份 stock 正向日志；若完全一致仍不得省略；
9. 两工具链下 A/B 的 positive、negative、count100、race 和 memory regression 日志；
10. race 日志全文；
11. 三臂完整 diff、status、diff-stat、changed/expected paths；
12. commands.sh 与 shell-xtrace.log；
13. dependency-adaptations.txt；没有则明确写“无”；
14. compliance-post.md；
15. 所有非零或预期外日志全文。

报告建议保存为：

~~~
prod-deploy/debug/juicefs-03-8-flush-race-community/report/C01-R1-execution-YYYYmmdd-HHMMSS.md
~~~

模板：

~~~markdown
# C01-R1 GLM 原始执行报告

- OUT：
- archive：
- archive sha256：
- fixed main：
- go125：
- go126：
- 起止时间：
- 状态：PASS / BLOCKED / NON-COMPLIANT

## summary.tsv

## stock repeat10

## A/B targeted

## race

## memory regression

## source diff and guards

## environment adaptations

## compliance
~~~

禁止：

- 只回复“全部通过”；
- 把 stock 预期失败写成任务失败；
- 省略失败日志；
- 修改任务书后继续；
- 评价 A/B 哪个更好；
- 进入性能测试或社区提交。

---

## 七、红线

1. 禁止使用 /tmp 作为 R1 工作区、缓存或编译临时目录。
2. 禁止删除、覆盖或复用旧 C01 OUT。
3. 禁止 rm -rf、git reset --hard、git clean、git checkout --。
4. 禁止修改 SOURCE 或任何现有 worktree。
5. 禁止使用 Go 1.23 或任意未固定工具链。
6. 禁止修改 go.mod、go.sum、vendor 或依赖版本。
7. 禁止运行 pkg/vfs 全量测试和任何 pkg/chunk 测试。
8. 禁止启动或访问 Redis、Ceph、TiKV 和对象存储。
9. 禁止 fio、mount、drop_caches、sudo、OSD/pool 操作。
10. 禁止弱化附录 A 或修改附录 B。
11. 禁止以“让测试通过”为目的改等待时间、次数或断言。
12. 禁止 commit、push、issue、PR。
13. 禁止用注释摘要替代 commands.sh 中的真实命令。
14. 任何超出授权的环境变更立即停止并回报。

---

## 附录 A：确定性测试文件

文件名必须为 pkg/vfs/writer_flush_test.go。内容见本任务书下方，必须逐字保存并 gofmt；不得从旧 OUT 复制。

~~~go
package vfs

import (
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/juicedata/juicefs/pkg/chunk"
	"github.com/juicedata/juicefs/pkg/meta"
	"github.com/juicedata/juicefs/pkg/object"
)

type c01DelayedNewSliceMeta struct {
	meta.Meta
	called  chan struct{}
	release chan struct{}
	once    sync.Once
}

func newC01DelayedNewSliceMeta() *c01DelayedNewSliceMeta {
	return &c01DelayedNewSliceMeta{
		called:  make(chan struct{}),
		release: make(chan struct{}),
	}
}

func (m *c01DelayedNewSliceMeta) NewSlice(_ meta.Context, id *uint64) syscall.Errno {
	m.once.Do(func() {
		close(m.called)
	})
	<-m.release
	*id = 1
	return 0
}

type c01RecordingWriter struct {
	mu      sync.Mutex
	id      uint64
	idSet   chan struct{}
	idOnce  sync.Once
	flushCh chan int
}

func newC01RecordingWriter() *c01RecordingWriter {
	return &c01RecordingWriter{
		idSet:   make(chan struct{}),
		flushCh: make(chan int, 4),
	}
}

func (w *c01RecordingWriter) WriteAt(p []byte, _ int64) (int, error) {
	return len(p), nil
}

func (w *c01RecordingWriter) ID() uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.id
}

func (w *c01RecordingWriter) SetID(id uint64) {
	w.mu.Lock()
	w.id = id
	w.mu.Unlock()
	w.idOnce.Do(func() {
		close(w.idSet)
	})
}

func (w *c01RecordingWriter) SetWriteback(bool) {}

func (w *c01RecordingWriter) FlushTo(offset int) error {
	w.flushCh <- offset
	return nil
}

func (w *c01RecordingWriter) Finish(int) error {
	return nil
}

func (w *c01RecordingWriter) Abort() {}

type c01ChunkStore struct {
	writer chunk.Writer
}

func (s *c01ChunkStore) NewReader(uint64, int) chunk.Reader {
	return nil
}

func (s *c01ChunkStore) NewWriter(uint64, uint8) chunk.Writer {
	return s.writer
}

func (s *c01ChunkStore) Remove(uint64, int) error {
	return nil
}

func (s *c01ChunkStore) FillCache(uint64, uint32) error {
	return nil
}

func (s *c01ChunkStore) EvictCache(uint64, uint32) error {
	return nil
}

func (s *c01ChunkStore) CheckCache(uint64, uint32, func(bool, string, int)) error {
	return nil
}

func (s *c01ChunkStore) UsedMemory() int64 {
	return 0
}

func (s *c01ChunkStore) UpdateLimit(int64, int64) {}

func (s *c01ChunkStore) BlobStorage() object.ObjectStorage {
	return nil
}

func c01WriteNewSlice(t *testing.T, size int) *c01RecordingWriter {
	t.Helper()

	const blockSize = 256 << 10
	m := newC01DelayedNewSliceMeta()
	writer := newC01RecordingWriter()
	w := &dataWriter{
		m:         m,
		store:     &c01ChunkStore{writer: writer},
		blockSize: blockSize,
	}
	f := &fileWriter{
		w:      w,
		inode:  2,
		chunks: make(map[uint32]*chunkWriter),
	}
	c := &chunkWriter{
		indx: 0,
		file: f,
	}
	c.slices = []*sliceWriter{
		{
			chunk:   c,
			off:     2 * blockSize,
			slen:    blockSize,
			freezed: true,
		},
	}
	f.chunks[0] = c

	go func() {
		<-m.called
		close(m.release)
	}()

	f.Lock()
	st := f.writeChunk(meta.Background(), 0, 0, make([]byte, size))
	f.Unlock()
	if st != 0 {
		t.Fatalf("writeChunk returned %s", st)
	}

	select {
	case <-writer.idSet:
	case <-time.After(2 * time.Second):
		t.Fatal("slice ID was not assigned")
	}
	return writer
}

func TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady(t *testing.T) {
	const blockSize = 256 << 10
	writer := c01WriteNewSlice(t, blockSize)

	select {
	case got := <-writer.flushCh:
		if got != blockSize {
			t.Fatalf("FlushTo offset = %d, want %d", got, blockSize)
		}
	case <-time.After(time.Second):
		t.Fatal("C01_MISSED_DISPATCH: full block was not dispatched after the slice ID became ready")
	}

	select {
	case got := <-writer.flushCh:
		t.Fatalf("duplicate FlushTo(%d)", got)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady(t *testing.T) {
	const blockSize = 256 << 10
	writer := c01WriteNewSlice(t, blockSize/2)

	select {
	case got := <-writer.flushCh:
		t.Fatalf("partial block unexpectedly dispatched with FlushTo(%d)", got)
	case <-time.After(250 * time.Millisecond):
	}
}
~~~

---

## 附录 B：异步补派发候选补丁

文件名必须为 async-catchup-main.patch。内容见本任务书下方，必须逐字保存；不得从旧 OUT 复制。

~~~diff
diff --git a/pkg/vfs/writer.go b/pkg/vfs/writer.go
--- a/pkg/vfs/writer.go
+++ b/pkg/vfs/writer.go
@@ -93,6 +93,14 @@ func (s *sliceWriter) prepareID(ctx meta.Context, retry bool) {
 	}
 	if s.writer != nil && s.writer.ID() == 0 {
 		s.writer.SetID(s.id)
+		if s.id > 0 && !s.freezed && int(s.slen) >= f.w.blockSize {
+			if err := s.writer.FlushTo(int(s.slen)); err != nil {
+				logger.Warnf("flush inode: %v chunk: %d after preparing slice ID: %s",
+					s.chunk.file.inode, s.id, err)
+				s.err = syscall.EIO
+			}
+		}
 	}
 	f.Unlock()
 }
~~~

该补丁的限定意图是：异步 ID 就绪时，在 fileWriter 锁保护下，补发之前因 id==0 错过的完整 block；若 slice 已 freezed，则由 flushData/Finish 负责，避免重复派发。
