# C01：main 首个整块写漏派发的确定性复现与候选修法筛选

> 面向执行方：GLM  
> 方案与结果复核：Codex  
> 日期：2026-08-16  
> 性质：开发机隔离单元测试；不占 03 阶段性能任务编号  
> 基座：JuiceFS main 固定提交 edabf9c24601510476e7453abff177f4aaca07ac  
> 现有生产补丁：patch/juicefs-flush-race-fix-main.patch  
> 结果目录：执行时新建 /tmp/juicefs-c01-YYYYmmdd-HHMMSS；禁止复用旧目录  
> 重要：本任务只执行源码级、单元级验证，不挂载 JuiceFS，不连接 Ceph/TiKV，不运行 fio，不提交或推送社区。

---

## ⚑ 计划线

~~~
03-8：v1.3.1 同步 ID 补丁恢复 randwrite，但缺少单元测试与系统 QA
  ↓
main 源码核对：异步 prepareID + id>0 守卫仍存在
  ↓
现有 main 性能数据：当前补丁未改善宏观塌态，不能直接对外宣称已修
  ↓
★ C01（你在这里）
  ├─ stock main：确定性证明首个整块写在 ID 就绪后仍未补发 FlushTo
  ├─ A：验证当前“同步 NewSlice”补丁
  └─ B：验证“保留异步分配、ID 就绪后补派发”的候选补丁
  ↓
Codex 独立分析 C01 原始结果并选择候选
  ├─ 证据不闭合：修测试或补丁，禁止进入性能测试
  └─ 证据闭合：编写 C02（v1.3.1/main 同会话交错性能验证）
  ↓
C03 完整性/故障注入 → C04 soak → 社区 issue/PR 或内部长期维护
~~~

一句话：在完全隔离、无外部存储的条件下，把 main 上的“漏派发”变成一个稳定失败的单元测试，并验证两种修法谁能在不引入明显回归的前提下让测试通过。

---

## 〇、背景与问题定义

### 0.1 本任务只回答源码行为，不回答宏观吞吐

当前问题必须分成两层：

1. 源码层：新 slice 创建后由 goroutine 异步执行 prepareID；fileWriter.Write 持有同一把文件锁调用 writeChunk 和 sliceWriter.write，因此 prepareID 在首笔写结束前无法取得文件锁。若首笔写恰好填满一个 block，s.id 在 id>0 检查点确定为 0，FlushTo 被跳过。异步 ID 随后虽然就绪，现有代码也不会补发已经错过的 FlushTo。
2. 系统层：这个漏派发是否会在某个具体环境中引起缓冲节流和约 550 MiB/s 塌态。该问题依赖后端排水、对象数和环境状态，不属于 C01。

C01 成功只能证明“main 存在确定性的 missed dispatch，候选补丁消除了它”；不能据此声称“main 的宏观性能塌态已解决”。宏观结论只能由后续 C02 给出。

### 0.2 为什么不继续把它称为 Go data race

s.id 的访问受 fileWriter.Mutex 保护；首写检查为 0 不是调度概率事件，而是锁顺序决定的确定结果。面向上游更准确的表述是：

- missed flush dispatch；
- ordering bug；
- full-block first write is not dispatched after the asynchronously allocated slice ID becomes ready。

任务日志和报告禁止使用“偶现 data race”“可能读到 0”等模糊措辞。

### 0.3 两个候选

- A，同步 ID：沿用当前补丁，在 writeChunk 中同步调用 NewSlice，然后执行首写。优点是直接；风险是每当 4096 个预分配 ID 耗尽时，元数据往返会发生在文件锁内。
- B，异步补派发：保留现有异步 NewSlice；prepareID 设置 writer ID 后，在同一文件锁内检查已有完整 block，若存在则补调用 FlushTo。该方案不把元数据往返搬入写路径，更接近现有上游设计。

C01 不凭偏好选方案，只收集确定性单测、现有测试和 race 检查结果。最终选择由 Codex 在结果返回后作出。

### 0.4 上游历史约束

执行者只需记录，不得自行据此改代码：

- #4694 曾尝试更早准备 slice ID，以稳定写缓冲；
- #4720 回退该变化；
- #4710 修复 s.writer 并发访问导致的 panic；
- #4721 将 prepareID 移到新 slice 创建处，形成当前结构。

因此，任何候选都必须验证：无重复 FlushTo、无 s.writer 并发、无 race、无 panic。禁止只看一个正向测试通过就下结论。

---

## 一、目标、问题与非目标

### 1.1 唯一主判定 Q1

在固定 main 提交 edabf9c2 上，新增的确定性正向测试必须满足：

- stock：稳定 FAIL，且失败标识精确包含 C01_MISSED_DISPATCH；
- A 同步 ID：PASS；
- B 异步补派发：PASS。

只有三项同时成立，才能判“main 上的源码问题存在，且 A/B 均覆盖该源码行为”。

### 1.2 次判定 Q2

负控“半个 block 写”必须在 stock/A/B 三臂全部 PASS，且在 ID 就绪后 250ms 内没有 FlushTo。它用于证明补丁没有把不完整 block 错误提前上传。

### 1.3 次判定 Q3

A/B 必须同时满足：

- 新增两个测试合跑 PASS；
- go test ./pkg/vfs ./pkg/chunk PASS；
- targeted go test -race 重复 20 次 PASS；
- git diff --check PASS。

stock 的原始包测试也必须在注入 C01 测试前 PASS，用于排除基座本身不可测试。

### 1.4 本任务明确不做

- 不运行 fio、benchmark 或 soak；
- 不挂载任何 JuiceFS 卷；
- 不访问 Ceph、TiKV、Redis、S3 或其他服务；
- 不修改 v1.3.1；
- 不比较吞吐、延迟或内存；
- 不创建 GitHub issue/PR，不 git push；
- 不修改现有 patch、README、SUMMARY、VERIFICATION 或生产文档；
- 不把 C01 PASS 解读为 main 宏观性能修复。

---

## 二、固定基座、矩阵与判据

### 2.1 固定量

| 项 | 固定值 |
|---|---|
| 源仓库 | /home/lilingfeng/project/juicefs |
| main 提交 | edabf9c24601510476e7453abff177f4aaca07ac |
| 当前同步补丁 | /home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/patch/juicefs-flush-race-fix-main.patch |
| 任务书 | /home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C01-main-deterministic-flush-dispatch.md |
| 工作区 | 每臂独立 clone 到本次 OUT/src/ 下 |
| Go 缓存 | 本次 OUT/cache/ 下；禁止写全局 module/build cache |
| 测试包 | ./pkg/vfs 与 ./pkg/chunk |
| 重复次数 | 普通 targeted 100 次；race targeted 20 次 |

固定提交不存在、源仓库脏状态无法只读访问、或同步补丁不能 apply --check 时，立即停止，不允许换提交继续。

### 2.2 三臂矩阵

| 臂 | 源码 | 正向测试预期 | 负控预期 | 完整包/race |
|---|---|---:|---:|---:|
| S-stock | edabf9c2 + C01 测试 | FAIL，C01_MISSED_DISPATCH | PASS | 注入前原始包须 PASS |
| A-sync | edabf9c2 + 当前同步 ID 补丁 + C01 测试 | PASS | PASS | PASS |
| B-async-catchup | edabf9c2 + 附录 B 补派发补丁 + C01 测试 | PASS | PASS | PASS |

禁止把 stock 的预期 FAIL 当成任务失败；它是正向缺陷复现。stock 若 PASS 才是证据异常。

### 2.3 每条判据的数据来源

| 判据 | 唯一数据源 | 读取方式 |
|---|---|---|
| 固定提交正确 | meta/source-refs.txt | 每臂 git rev-parse HEAD 必须等于完整 main SHA |
| 原始基座健康 | logs/S-stock-baseline-packages.log + 对应 rc 文件 | go test ./pkg/vfs ./pkg/chunk 的退出码为 0 |
| stock 正向复现 | logs/S-stock-positive.log | 退出码非 0，且包含 C01_MISSED_DISPATCH |
| 三臂负控 | logs/ARM-negative.log | 退出码均为 0 |
| A/B 修复正向 | logs/A-sync-positive.log、logs/B-async-catchup-positive.log | 退出码均为 0 |
| 普通重复稳定 | logs/ARM-targeted-count100.log | A/B 退出码均为 0 |
| race | logs/ARM-race-count20.log | A/B 退出码均为 0，且不得出现 DATA RACE |
| 包级回归 | logs/ARM-packages.log | A/B 退出码均为 0 |
| 变更范围 | meta/ARM-changed-paths.txt、logs/ARM-path-guard.log、diffs/ARM-full.diff | 与每臂白名单精确相等，path-guard rc=0，diff --check rc=0 |
| 文件完整性 | SHA256SUMS、logs/sha256-check.log、rc/sha256-check.rc | sha256sum -c 返回 0 |

GLM 只记录上述原始结果，不写“哪个方案最终更好”。方案选择属于结果分析。

### 2.4 通过条件

C01 总体可进入 Codex 复核的最低条件：

1. S-stock 原始包基线 PASS；
2. S-stock 正向测试按预期 FAIL，错误标识正确；
3. S-stock 负控 PASS；
4. A-sync 与 B-async-catchup 的正向、负控、100 次普通重复、20 次 race、包级测试全部 PASS；
5. 三臂提交一致，diff 范围无越界，产物校验通过。

任一项不满足，GLM 不得自行修正判据或继续做性能测试，只交付现状。

---

## 三、执行步骤

### 步骤 0：测试前通读并书面确认

执行前阅读：

1. 本任务书全文；
2. prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md 的 §二.8、§二.9、§二.11、§二.12；
3. prod-deploy/skills/SYSTEM-SAFETY-SKILL.md；
4. debug 包的 docs/SUMMARY.md，仅用于了解现有结论，不得把其结论写成 C01 测试结果。

在 OUT/meta/preflight.txt 逐条写明：

- 已理解 C01 不运行生产测试；
- 已理解 stock 正向 FAIL 是预期；
- 已理解不能修改固定提交、测试语义和候选补丁；
- 已理解任何需要改变变量的问题都必须停止回报；
- 已理解不清理或覆盖现有 /tmp/juicefs-* 工作树。

没有 preflight.txt 不得执行后续步骤。

### 步骤 1：建立全新隔离目录

参考命令如下，RUN_ID 和 OUT 必须是本次新值：

~~~bash
set -uo pipefail

RUN_ID=$(date +%Y%m%d-%H%M%S)
OUT=/tmp/juicefs-c01-$RUN_ID
SOURCE=/home/lilingfeng/project/juicefs
MAIN_COMMIT=edabf9c24601510476e7453abff177f4aaca07ac
SYNC_PATCH=/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/patch/juicefs-flush-race-fix-main.patch
TASKBOOK=/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C01-main-deterministic-flush-dispatch.md

mkdir -p "$OUT"/{assets,cache/go-build,cache/go-mod,diffs,logs,meta,rc,src}
: > "$OUT/commands.sh"
chmod 600 "$OUT/commands.sh"
printf '%s\n' "$OUT" > "$OUT/meta/out-path.txt"
cp "$TASKBOOK" "$OUT/meta/taskbook.snapshot.md"

git -C "$SOURCE" cat-file -e "$MAIN_COMMIT^{commit}"
printf 'source=%s\nmain_commit=%s\nsync_patch=%s\n' \
  "$SOURCE" "$MAIN_COMMIT" "$SYNC_PATCH" > "$OUT/meta/source-refs.txt"
git -C "$SOURCE" status --short --branch >> "$OUT/meta/source-refs.txt"
git -C "$SOURCE" show -s --format='%H%n%aI%n%s' "$MAIN_COMMIT" >> "$OUT/meta/source-refs.txt"

go version > "$OUT/meta/go-env.txt" 2>&1
go env GOOS GOARCH GOVERSION GOPROXY GOTOOLCHAIN >> "$OUT/meta/go-env.txt" 2>&1
uname -a > "$OUT/meta/uname.txt"
~~~

不要执行 rm -rf，不要复用固定目录名，不要修改 SOURCE。commands.sh 是强制交付物：从创建 OUT 开始，把每条实际执行的完整命令（包括失败、重试和环境适配命令）按执行顺序写入该文件；首段初始化命令须在创建文件后补录。commands.sh 只记命令，不粘贴 stdout/stderr，也不得写入口令、令牌等秘密。

### 步骤 2：创建三个完全独立的 clone

~~~bash
for ARM in S-stock A-sync B-async-catchup; do
  git clone --no-hardlinks --no-checkout "$SOURCE" "$OUT/src/$ARM" \
    > "$OUT/logs/clone-$ARM.log" 2>&1 || exit 11
  git -C "$OUT/src/$ARM" cat-file -e "$MAIN_COMMIT^{commit}" \
    >> "$OUT/logs/clone-$ARM.log" 2>&1 || exit 12
  git -C "$OUT/src/$ARM" checkout --detach "$MAIN_COMMIT" \
    >> "$OUT/logs/clone-$ARM.log" 2>&1 || exit 13
  HEAD_NOW=$(git -C "$OUT/src/$ARM" rev-parse HEAD) || exit 14
  printf '%s\t%s\n' "$ARM" "$HEAD_NOW" >> "$OUT/meta/arm-heads.tsv"
done
~~~

这里刻意使用本地 clone 中已经复制的对象并直接核验固定 commit，不依赖 clone 后的默认分支，也不把 origin/main 当作执行时可漂移的目标。cat-file 或 checkout 任一步失败都必须停止；禁止改成当前 HEAD。

门禁：

~~~bash
awk -v want="$MAIN_COMMIT" '$2 != want {bad=1} END{exit bad}' "$OUT/meta/arm-heads.tsv"
~~~

门禁失败立即停止。禁止用 origin/main 或最新 HEAD 替换固定提交。

### 步骤 3：设置隔离 Go 缓存并验证原始基座

~~~bash
export GOCACHE="$OUT/cache/go-build"
export GOMODCACHE="$OUT/cache/go-mod"
export GOTOOLCHAIN=local

cd "$OUT/src/S-stock"
go mod download > "$OUT/logs/go-mod-download.log" 2>&1
MOD_RC=$?
printf '%s\n' "$MOD_RC" > "$OUT/rc/go-mod-download.rc"

go test ./pkg/vfs ./pkg/chunk -count=1 \
  > "$OUT/logs/S-stock-baseline-packages.log" 2>&1
BASE_RC=$?
printf '%s\n' "$BASE_RC" > "$OUT/rc/S-stock-baseline-packages.rc"
~~~

要求 BASE_RC=0。若依赖下载失败：

- 允许调整 GOPROXY、证书路径或网络代理；
- 允许重新执行 go mod download；
- 禁止修改 go.mod、go.sum 或源码来绕过依赖；
- 修复过程全部追加到 meta/dependency-adaptations.txt。

若原始基座测试仍不能通过，停止 C01，不注入测试，不应用候选补丁。

### 步骤 4：创建确定性测试文件

将附录 A 的内容逐字保存为：

~~~
$OUT/assets/writer_flush_test.go
~~~

然后执行：

~~~bash
gofmt -w "$OUT/assets/writer_flush_test.go"
sha256sum "$OUT/assets/writer_flush_test.go" > "$OUT/meta/test-asset.sha256"

for ARM in S-stock A-sync B-async-catchup; do
  cp "$OUT/assets/writer_flush_test.go" "$OUT/src/$ARM/pkg/vfs/writer_flush_test.go"
  gofmt -w "$OUT/src/$ARM/pkg/vfs/writer_flush_test.go"
  git -C "$OUT/src/$ARM" add -N pkg/vfs/writer_flush_test.go
done
~~~

git add -N 仅在隔离 clone 的索引中登记 intent-to-add，使后续 git diff 能审计这个未跟踪测试文件；不得执行普通 git add、commit 或 push。

禁止修改测试中的：

- blockSize；
- 2 秒 ID 等待；
- 1 秒正向 FlushTo 等待；
- 250ms 负控窗口；
- C01_MISSED_DISPATCH 错误标识；
- dummy slice 设计；
- “只允许一次 FlushTo”检查。

如测试不能编译，停止并交付编译错误；不得弱化测试。

### 步骤 5：应用 A 同步补丁

~~~bash
cd "$OUT/src/A-sync"
git apply --check "$SYNC_PATCH" > "$OUT/logs/A-sync-apply-check.log" 2>&1
APPLY_CHECK_RC=$?
printf '%s\n' "$APPLY_CHECK_RC" > "$OUT/rc/A-sync-apply-check.rc"
[ "$APPLY_CHECK_RC" -eq 0 ] || exit 20

git apply "$SYNC_PATCH" > "$OUT/logs/A-sync-apply.log" 2>&1
gofmt -w pkg/vfs/writer.go pkg/vfs/writer_flush_test.go
git diff --check > "$OUT/diffs/A-sync.diffcheck.log" 2>&1
printf '%s\n' "$?" > "$OUT/rc/A-sync-diffcheck.rc"
git diff -- pkg/vfs/writer.go pkg/vfs/writer_flush_test.go > "$OUT/diffs/A-sync.diff"
~~~

注意：SYNC_PATCH 的提交说明里含有已经被后续证据推翻的 #6311 归因。本任务只应用其 writer.go 代码 hunk，禁止引用 patch 说明作为结论。

### 步骤 6：应用 B 异步补派发补丁

将附录 B 逐字保存为：

~~~
$OUT/assets/async-catchup-main.patch
~~~

然后：

~~~bash
cd "$OUT/src/B-async-catchup"
git apply --check "$OUT/assets/async-catchup-main.patch" \
  > "$OUT/logs/B-async-catchup-apply-check.log" 2>&1
APPLY_CHECK_RC=$?
printf '%s\n' "$APPLY_CHECK_RC" > "$OUT/rc/B-async-catchup-apply-check.rc"
[ "$APPLY_CHECK_RC" -eq 0 ] || exit 21

git apply "$OUT/assets/async-catchup-main.patch" \
  > "$OUT/logs/B-async-catchup-apply.log" 2>&1
gofmt -w pkg/vfs/writer.go pkg/vfs/writer_flush_test.go
git diff --check > "$OUT/diffs/B-async-catchup.diffcheck.log" 2>&1
printf '%s\n' "$?" > "$OUT/rc/B-async-catchup-diffcheck.rc"
git diff -- pkg/vfs/writer.go pkg/vfs/writer_flush_test.go \
  > "$OUT/diffs/B-async-catchup.diff"
~~~

禁止 GLM 自行修改 B 的错误处理、锁范围、freezed 条件或 FlushTo 条件。

### 步骤 7：运行 stock 的确定性复现和负控

不要使用 set -e；正向测试预期非零。

~~~bash
cd "$OUT/src/S-stock"

go test ./pkg/vfs \
  -run '^TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady$' \
  -count=1 -v > "$OUT/logs/S-stock-positive.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/S-stock-positive.rc"

go test ./pkg/vfs \
  -run '^TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady$' \
  -count=1 -v > "$OUT/logs/S-stock-negative.log" 2>&1
RC=$?
printf '%s\n' "$RC" > "$OUT/rc/S-stock-negative.rc"
~~~

立即门禁：

~~~bash
test "$(cat "$OUT/rc/S-stock-positive.rc")" -ne 0
grep -q 'C01_MISSED_DISPATCH' "$OUT/logs/S-stock-positive.log"
test "$(cat "$OUT/rc/S-stock-negative.rc")" -eq 0
~~~

任一门禁失败，停止任务，不运行 A/B 测试。原因：stock 行为没有被测试准确锁定。

### 步骤 8：运行 A/B 正向、负控与重复测试

对 A-sync 和 B-async-catchup 分别执行：

~~~bash
for ARM in A-sync B-async-catchup; do
  cd "$OUT/src/$ARM"

  go test ./pkg/vfs \
    -run '^TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady$' \
    -count=1 -v > "$OUT/logs/$ARM-positive.log" 2>&1
  printf '%s\n' "$?" > "$OUT/rc/$ARM-positive.rc"

  go test ./pkg/vfs \
    -run '^TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady$' \
    -count=1 -v > "$OUT/logs/$ARM-negative.log" 2>&1
  printf '%s\n' "$?" > "$OUT/rc/$ARM-negative.rc"

  go test ./pkg/vfs \
    -run '^(TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady|TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady)$' \
    -count=100 > "$OUT/logs/$ARM-targeted-count100.log" 2>&1
  printf '%s\n' "$?" > "$OUT/rc/$ARM-targeted-count100.rc"
done
~~~

每个 rc 必须为 0。任何非零只记录，不自行改代码重跑。

### 步骤 9：运行包级回归与 race

~~~bash
for ARM in A-sync B-async-catchup; do
  cd "$OUT/src/$ARM"

  go test ./pkg/vfs ./pkg/chunk -count=1 \
    > "$OUT/logs/$ARM-packages.log" 2>&1
  printf '%s\n' "$?" > "$OUT/rc/$ARM-packages.rc"

  go test -race ./pkg/vfs \
    -run '^(TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady|TestPartialBlockIsNotDispatchedWhenSliceIDBecomesReady)$' \
    -count=20 > "$OUT/logs/$ARM-race-count20.log" 2>&1
  printf '%s\n' "$?" > "$OUT/rc/$ARM-race-count20.rc"
done
~~~

若 race 构建不受当前 Go/CGO 环境支持，保留完整错误并停止；禁止改成“不跑 race 也算通过”。

### 步骤 10：核验变更范围

~~~bash
for ARM in S-stock A-sync B-async-catchup; do
  cd "$OUT/src/$ARM"
  git status --short > "$OUT/meta/$ARM-status.txt"
  git diff --stat > "$OUT/meta/$ARM-diff-stat.txt"
  git diff --check > "$OUT/diffs/$ARM.diffcheck.log" 2>&1
  printf '%s\n' "$?" > "$OUT/rc/$ARM-diffcheck.rc"
  git diff > "$OUT/diffs/$ARM-full.diff"

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
  printf '%s\n' "$?" > "$OUT/rc/$ARM-path-guard.rc"
done
~~~

允许的路径：

- S-stock：仅 pkg/vfs/writer_flush_test.go；
- A-sync：pkg/vfs/writer.go 与 pkg/vfs/writer_flush_test.go；
- B-async-catchup：pkg/vfs/writer.go 与 pkg/vfs/writer_flush_test.go。

三份 path-guard.rc 必须全部为 0。出现 go.mod、go.sum、vendor、其他源码或生成文件变化，或缺少任一预期文件，一律判变更越界。

### 步骤 11：生成原始结果表

生成 OUT/summary.tsv，表头固定为：

~~~
arm	test	rc	expected	log	expectation_matched
~~~

至少包含：

- S-stock baseline-packages/positive/negative/diffcheck/path-guard；
- A-sync positive/negative/targeted-count100/packages/race-count20/diffcheck/path-guard；
- B-async-catchup 同上。

expectation_matched 只能填 YES 或 NO，不填写原因分析。所有 rc 必须从 OUT/rc/*.rc 读取，禁止手抄。

### 步骤 12：测试后 skill 与任务合规自查

在 OUT/meta/compliance-post.md 逐条回答：

1. 是否只使用固定 main commit；
2. 是否未修改 SOURCE 和现有 worktree；
3. 是否未运行 fio、mount、Ceph/TiKV 命令；
4. 是否未执行 sudo、OSD restart、pool 操作或 drop_caches；
5. 是否未改 go.mod/go.sum；
6. 是否未改变附录 A/B 的语义；
7. 是否所有预期外错误均完整保留；
8. 是否未 git commit、push 或创建社区 issue；
9. commands.sh、summary.tsv、diff、日志和 rc 是否已齐备；
10. 是否会保留 OUT/src、OUT/cache 和最终证据归档供 Codex 复核。

任一项为否，必须写出具体文件、命令和对结论的影响。

### 步骤 13：打包与校验

合规自查完成后再打包，确保 compliance-post.md 进入校验清单和归档。只归档证据，不归档三份源码 clone 与 Go 缓存：

执行本步骤前，先把下面整个命令块按最终实际形式追加到 commands.sh，然后冻结 commands.sh 再执行。若本步骤发生重试，必须先追加重试命令，再从生成 SHA256SUMS 开始重新执行，保证 commands.sh 的最终内容参与校验和归档。

~~~bash
cd "$OUT"
ARCHIVE="/tmp/$(basename "$OUT")-artifacts.tar.gz"
printf '%s\n' "$ARCHIVE" > "$OUT/meta/archive-path.txt"

{
  find assets diffs logs meta rc -type f -print0
  printf '%s\0' commands.sh summary.tsv
} | sort -z | xargs -0 sha256sum > SHA256SUMS

sha256sum -c SHA256SUMS > logs/sha256-check.log 2>&1
SHA_RC=$?
printf '%s\n' "$SHA_RC" > rc/sha256-check.rc
[ "$SHA_RC" -eq 0 ] || exit 40

tar -C "$OUT" -czf "$ARCHIVE" \
  assets diffs logs meta rc commands.sh summary.tsv SHA256SUMS
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
~~~

SHA256SUMS 覆盖校验前已经存在的全部证据文件；它不自校验，也不包含随后生成的 logs/sha256-check.log 与 rc/sha256-check.rc。archive 的独立 .sha256 覆盖最终归档整体。禁止删除 OUT 或源码 clone；OUT/src 与 OUT/cache 保留到 Codex 完成复核，但不得塞入归档。

---

## 四、GLM 交付物

GLM 只交付原始事实，不下最终结论。

必须回报：

1. OUT 绝对路径；
2. artifacts.tar.gz 绝对路径及 SHA256；
3. summary.tsv 全文；
4. meta/arm-heads.tsv 全文；
5. 三个 positive/negative 日志全文；
6. A/B targeted-count100、packages、race-count20 的结尾至少 80 行；若失败则交完整日志；
7. diffs/A-sync.diff 与 diffs/B-async-catchup.diff 全文；
8. 三臂 status 与 diff-stat；
9. dependency-adaptations.txt，如没有则明确写“无”；
10. compliance-post.md 全文；
11. commands.sh、三臂 changed-paths/expected-paths 与 path-guard rc。

禁止：

- 只回复“测试通过”；
- 省略 stock 的预期失败日志；
- 把 stderr 丢弃；
- 将 A/B 评价为“推荐方案”；
- 进入 C02 或任何性能测试。

报告只需使用下列模板：

~~~markdown
# C01 GLM 原始执行报告

- OUT：
- archive：
- archive sha256：
- 固定 main commit：
- 执行起止时间：

## summary.tsv 全文

## arm-heads.tsv 全文

## targeted 日志

## package/race 日志

## diff 全文

## 环境适配与偏差

## 合规自查全文
~~~

C01 不更新 doc/deploy-log/results-table.md；归档入仓与结论同步由 Codex 复核后处理。

---

## 五、通用注意事项与适用性

### 5.1 数据统计口径

C01 无 fio 和带宽统计。唯一统计量是测试退出码、固定错误标识、重复次数和 race 输出；不得用“多数通过”代替 count=100/count=20 全部通过。

### 5.2 冷态净化

不适用。禁止 drop_caches，因为 C01 不测缓存或性能。

### 5.3 fresh volume 与写入数据

不适用。C01 不创建卷、不写对象存储。

### 5.4 后端干净态与 OSD compaction

不适用。禁止执行 Ceph health、compact、OSD 命令；它们不在 C01 授权范围内。

### 5.5 环境前置检查

仅核验本机、Go、Git、固定提交和依赖。禁止用生产环境健康状态作为继续/停止条件。

### 5.6 记录规范

所有实际命令、退出码、stdout/stderr、源码 diff 和环境适配必须落 OUT。预期失败也必须完整保存。

### 5.7 卷清理

不适用。禁止 destroy、format、pool delete/create。C01 唯一新增数据位于新建 OUT。

### 5.8 skill 合规自查

步骤 0 和步骤 12 强制执行。缺任一步，任务结果不进入分析。

### 5.9 分层授权

允许：

- 修复 GOPROXY、证书、只读路径和本次 OUT 权限；
- 在本次 OUT 内重新下载依赖；
- 增强日志记录，但不得改变测试时序。

禁止：

- 改固定 commit；
- 改测试等待窗口、blockSize、断言或错误标识；
- 改候选补丁逻辑；
- 修改 SOURCE、现有 worktree 或生产资料包；
- 以“让测试通过”为目的改测试。

需要改变上述变量时立即停止并报告。

### 5.10 挂载档位

不适用。C01 无 mount/remount，禁止运行 ns/B 探针。

### 5.11 判据来源

所有判据已在 §2.3 指名文件。报告中出现的每个 rc 必须能追溯到 OUT/rc；每个源码判断必须能追溯到 OUT/diffs。

### 5.12 环境快照

C01 使用 meta/go-env.txt、meta/uname.txt、meta/source-refs.txt、meta/arm-heads.tsv 替代生产 env-snapshot。不得运行生产 env-snapshot 脚本。

---

## 六、红线汇总

1. 禁止运行本任务书之外的实际性能、挂载或后端测试。
2. 禁止修改 /home/lilingfeng/project/juicefs 及任何现有 worktree。
3. 禁止复用或清空现有 /tmp/juicefs-* 目录；本次必须创建唯一 OUT。
4. 禁止 rm -rf、git reset --hard、git clean、git checkout -- 之类清理命令。
5. 禁止 sudo、Ceph/TiKV/OSD/pool 操作。
6. 禁止修改 go.mod、go.sum 或降低依赖版本。
7. 禁止改变固定 main commit。
8. 禁止弱化附录 A 的测试或自行修改附录 B。
9. 禁止把 stock 正向预期 FAIL 误报为任务失败。
10. 禁止把 C01 PASS 外推为 main 宏观性能修复。
11. 禁止 git commit、push、发 issue/PR。
12. 任何越界、编译障碍或预期外结果立即停止，保存原始材料并回报。

---

## 附录 A：确定性测试文件

文件名必须为 pkg/vfs/writer_flush_test.go，内容如下：

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

## 附录 B：B 异步补派发候选补丁

保存为 async-catchup-main.patch：

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

该补丁的意图仅为：ID 异步就绪时，在文件锁保护下补发之前因 id==0 错过的完整 block；若 slice 已 freezed，则由 flushData/Finish 负责，不在此重复派发。
