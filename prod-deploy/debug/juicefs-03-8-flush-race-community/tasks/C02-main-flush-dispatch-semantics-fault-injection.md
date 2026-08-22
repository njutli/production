# C02：main FlushTo 补派发语义、故障注入与候选收敛

> 面向执行方：GLM  
> 方案与结果复核：Codex  
> 日期：2026-08-17  
> 性质：开发机隔离源码单元测试；不占 03 阶段性能任务编号  
> 基座：JuiceFS main 固定提交 `edabf9c24601510476e7453abff177f4aaca07ac`  
> 主工具链：Go 1.25.7  
> 兼容工具链：Go 1.26.0  
> 工作根目录：`/home/lilingfeng/tmp`；禁止使用根级 `/tmp/`  
> 重要：本任务不挂载 JuiceFS，不连接 Redis/Ceph/TiKV，不运行 fio，不改现有源码仓库，不 commit、不 push、不创建 issue/PR。

---

## ⚑ 计划线

~~~text
C01 首次执行
  └─ 被 Redis、mockey、/tmp tmpfs 等非目标依赖阻塞
  ↓
C01-R1 固定 main + 双工具链确定性测试
  ├─ 技术结论：main 稳定漏派发，A/B 均覆盖最小行为
  └─ 审计结论：commands/xtrace 不完整，记为 TECHNICAL PASS / AUDIT NON-COMPLIANT
  ↓
★ C02（你在这里）
  ├─ 修复完整性：完整块、多块、FlushTo 失败
  ├─ stock 兼容性：异步非阻塞、非 EIO 不额外重试
  ├─ 故障状态机：EIO、ENOSPC、freeze、Abort/Finish
  └─ 候选并发/race + 完整执行审计
  ↓
  ├─ B 全门通过：进入 C03 社区补丁整理与上游 CI 设计
  ├─ 仅 A 核心通过：保留自维护路线，先做 A 风险专项
  └─ 两者不闭合：停止，不进入性能、长稳或社区流程
~~~

一句话：用 stock main 的既有语义作为兼容性对照，在确定性故障注入下判断 A/B 是否既修复漏派发，又没有引入不可接受的阻塞、重试、错误吞没或重复派发。

---

## 〇、背景与 C01-R1 承接

### 0.1 C01-R1 已经证明什么

C01-R1 原始报告：

~~~text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C01-R1-execution-20260816-232401.md
~~~

Codex 对归档做只读复核后，技术证据支持以下事实：

1. 固定 main 提交在 Go 1.25.7 与 Go 1.26.0 下，stock 正向测试各 10/10 命中 `C01_MISSED_DISPATCH`；
2. A-sync 与 B-async-catchup 的正向、负控、`count=100`、`-race count=20` 和纯内存回归均通过；
3. 三臂 HEAD、测试资产、最终 diff 和路径白名单闭合；
4. 因此可以确认“问题在该 main 提交上存在，A/B 都覆盖最小复现”。

但 C01-R1 不能记为无保留 PASS：

- `commands.sh` 未包含后半段实际测试、补丁应用、审计和归档命令；
- `shell-xtrace.log` 只覆盖初始化、clone 和早期工具链动作；
- 执行曾写根级 `/tmp/`，报告却把对应合规项标为 YES；
- B 补丁 hunk header 写成 `+93,14`，实际通过 `git apply --recount` 才应用；正确值是 `+93,13`。

所以 C02 的正式前置状态固定写为：

~~~text
C01-R1 = TECHNICAL PASS / AUDIT NON-COMPLIANT
~~~

C02 不为补齐审计而重跑 C01-R1；它使用全新 OUT，并修复执行留痕方法。

### 0.2 为什么不能直接进入性能或社区提交

C01-R1 只覆盖“完整块首写发生在 ID 就绪前”这一条 happy-path。它没有回答：

- A 把 `NewSlice` 移到 `fileWriter` 锁内同步执行后，元数据调用阻塞时是否会阻塞首次写；
- A 在同步 `NewSlice` 返回非零时再启动原异步路径，是否会改变原有调用次数和错误语义；
- B 在异步 ID 就绪后调用 `FlushTo` 失败时，错误是否被可靠锁存并传播；
- ID 获取失败、重试、freeze 与显式收尾交错时，是否重复 `FlushTo`、`Finish` 或 `Abort`；
- 多个独立 slice 并发时是否存在 data race 或遗漏派发。

这些问题不闭合，无法形成社区可维护补丁，也不应把生产性能结果外推为源码质量已经合格。

### 0.3 C02 的候选定位

- **A-sync**：现有自维护补丁。它已经有 v1.3.1 性能证据，但在 main 上改变了 `NewSlice` 的异步边界；C02 将把这种变化量化为行为事实。
- **B-async-catchup**：保持 `go s.prepareID(...)`，只在 ID 就绪后补派发。它更接近最小上游修复，但必须通过错误、freeze、重复派发和 race 门禁。
- **S-stock**：既是缺陷负控，也是“原有异步/错误语义”的兼容性对照；不能只把它当作一个必然失败臂。

---

## 一、目标、唯一门禁与非目标

### 1.1 Q1：修复完整性

A/B 必须在以下路径正确补派发：

1. 单个完整 block 在 ID 延迟就绪后派发一次；
2. 单次写入跨越多个 block 时，以最新 `slen` 派发一次；
3. catch-up `FlushTo` 返回错误时，调用方或 slice 状态至少有一处可观察到 `EIO`，不得静默成功。

S-stock 在上述三项按预注册标识失败，用来证明测试确实击中缺陷，而不是“所有臂都绿”的弱测试。

### 1.2 Q2：原有兼容语义

以 S-stock 为行为 oracle，检查：

1. `NewSlice` 被确定性阻塞时，首次 `WriteAt` 仍能在释放元数据调用前发生；
2. 首次 `NewSlice` 返回非 `EIO` 错误时，在显式 flush/freeze 前不自动发起第二次 `NewSlice`；
3. ID 已经就绪后，partial→full 的第二次续写仍只派发一次。

根据源码静态分析，A 预计在前两项出现预注册差异；这两项是 **A 的候选指纹**，不是基础设施失败。B 必须与 stock 一致。

### 1.3 Q3：故障与收尾状态机

三臂均必须满足：

- 首次 `NewSlice=EIO`、随后成功时，freeze 收尾成功，最终恰好一次 `Finish`、零次 `Abort`；
- 永久 `ENOSPC` 时，slice 保留 `ENOSPC`，恰好一次 `Abort`、零次 `Finish`；
- slice 已经 `freezed` 后 ID 才就绪时，catch-up 不调用 `FlushTo`，由 `Finish` 唯一收尾。

### 1.4 Q4：候选并发与 race

A/B 各自在 32 个独立 slice 并发写入时必须：

- 每个 writer 获得非零 ID；
- 每个完整块恰好一次 `FlushTo(blockSize)`；
- 无错误、无遗漏、无重复；
- 普通重复和 `-race` 重复均通过，race 日志没有 `DATA RACE`。

### 1.5 唯一推进门：B 是否成为社区首选候选

只有同时满足以下条件，C02 才允许输出 `PASS-B-COMMUNITY-CANDIDATE`：

1. 两个工具链的 stock 缺陷负控及兼容对照全部符合预注册结果；
2. B 的全部十项测试、`count=100` 和 `-race count=20` 全部通过；
3. B 最终 diff 与附录 B 完全一致，且没有 `--recount`、手工改 hunk 或其他源码变化；
4. A 的结果完整保留，无论是否符合预期；
5. 执行审计、文件校验和归档全部合规。

这个状态只表示“B 具备进入社区补丁整理与更完整 CI 的资格”，不表示已经可以提交 PR。

### 1.6 本任务明确不做

- 不运行 fio、benchmark 或宏观性能对比；
- 不挂载 JuiceFS，不访问 Redis、Ceph、TiKV、S3；
- 不运行 `pkg/vfs` 全量测试或 `pkg/chunk` 测试；
- 不修改 v1.3.1 或生产二进制；
- 不运行 ≥8h soak；
- 不做数据完整性 fio verify；
- 不 fetch 漂移的 main，不升级依赖，不修改 `go.mod/go.sum`；
- 不 commit、push、创建 GitHub issue/PR 或联系社区维护者；
- 不由 GLM 选择 A/B；GLM 只执行预注册矩阵并交付机械门禁结果。

---

## 二、固定量、三臂与预注册矩阵

### 2.1 固定量

| 项 | 固定值 |
|---|---|
| 源 Git 对象库 | `/home/lilingfeng/project/juicefs` |
| main commit | `edabf9c24601510476e7453abff177f4aaca07ac` |
| A 原始补丁 | `patch/juicefs-flush-race-fix-main.patch` |
| A 补丁 SHA256 | `d6ed8146852e76ce8d3ad82707b4637720b919c5c9e8e15152e76c4a40f6e4d1` |
| B 补丁 | 本任务书附录 B，修正 hunk 为 `+93,13` |
| B 补丁 SHA256 | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` |
| C02 测试资产 | 本任务书附录 A，文件名 `pkg/vfs/writer_flush_c02_test.go` |
| C02 测试资产 SHA256 | gofmt 后 `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` |
| 工作根目录 | `/home/lilingfeng/tmp` |
| 主工具链 | `GOTOOLCHAIN=go1.25.7` |
| 兼容工具链 | `GOTOOLCHAIN=local`，必须精确为 `go1.26.0` |
| 测试包 | 仅 `./pkg/vfs` |
| blockSize | `256 << 10` |
| 预期失败独立重复 | 10 个独立 `go test` 进程 |
| 候选普通重复 | `-count=100` |
| 候选 race 重复 | `-race -count=20` |

### 2.2 三臂

| 臂 | writer.go 变化 | 用途 |
|---|---|---|
| S-stock | 无 | 缺陷负控 + 原行为 oracle |
| A-sync | 固定 A patch | 当前自维护候选与比较臂 |
| B-async-catchup | 附录 B | 社区首选候选门禁臂 |

三臂使用同一个测试文件，逐字节一致。禁止为不同臂写条件编译、环境变量分支或不同断言。

### 2.3 十项测试与预注册结果

结果含义：`PASS` = `go test rc=0`；`FAIL(marker)` = `rc!=0`、恰好一个指定 marker、恰好一个目标测试失败，且没有 build/panic/timeout/race 错误；`N/R` = 该臂不运行此项。

| ID | 测试函数 | S-stock | A-sync | B-async-catchup |
|---|---|---|---|---|
| R1 | `TestC02FullBlockDispatchAfterDelayedID` | `FAIL(C02_MISSED_DISPATCH)` | PASS | PASS |
| R2 | `TestC02MultiBlockDispatchUsesLatestLength` | `FAIL(C02_MISSED_MULTI_DISPATCH)` | PASS | PASS |
| R3 | `TestC02FlushToFailureIsObservable` | `FAIL(C02_SWALLOWED_FLUSH_ERROR)` | PASS | PASS |
| C1 | `TestC02PartialThenFullAfterIDDispatchesOnce` | PASS | PASS | PASS |
| C2 | `TestC02DelayedNewSliceDoesNotBlockWriteAt` | PASS | `FAIL(C02_BLOCKING_REGRESSION)` | PASS |
| C3 | `TestC02NonEIONewSliceDoesNotRetryBeforeFlush` | PASS | `FAIL(C02_EXTRA_NEWSLICE_ATTEMPT)` | PASS |
| F1 | `TestC02TransientEIORecoversOnFreeze` | PASS | PASS | PASS |
| F2 | `TestC02PermanentENOSPCAbortsFrozenSlice` | PASS | PASS | PASS |
| F3 | `TestC02FrozenSliceSkipsCatchupFlush` | PASS | PASS | PASS |
| K1 | `TestC02ConcurrentIndependentFullBlocks` | N/R | PASS | PASS |

任何与表格不符的结果都记 `expectation_matched=NO`。禁止看到结果后修改预期表。

### 2.4 重复与 race 矩阵

每个工具链分别运行：

1. 上表所有适用单项各一次；
2. S-stock 的 R1/R2/R3 各 10 个独立进程，全部必须按指定 marker 失败；
3. A-sync 的 C2/C3 各 10 个独立进程，全部必须按指定 marker 失败；
4. A-sync 的预期通过集合 `R1|R2|R3|C1|F1|F2|F3|K1`：`count=100`；
5. A-sync 同一通过集合：`-race count=20`；
6. B-async-catchup 全十项：`count=100`；
7. B-async-catchup 全十项：`-race count=20`。

禁止把预期失败测试放进候选 PASS 聚合命令后再笼统接受非零退出码；每个预期失败必须独立记录和机械验真。

### 2.5 每条判据的数据源

| 判据 | 唯一数据源 |
|---|---|
| 工具链 | `meta/go125-version.txt`、`meta/go126-version.txt`、对应 rc |
| 固定 HEAD | `meta/arm-heads-before.tsv`、`meta/arm-heads-after.tsv` |
| 单项结果 | `logs/TOOL-ARM-ID.log`、`rc/TOOL-ARM-ID.rc` |
| 预期失败 10 次 | `meta/TOOL-ARM-ID-repeat10.tsv` 与十份独立日志/rc |
| 普通 count=100 | `logs/TOOL-ARM-pass-count100.log` 与 PASS 行计数审计 |
| race count=20 | `logs/TOOL-ARM-pass-race-count20.log`、rc、`DATA RACE` 搜索 |
| 机械预期矩阵 | `meta/expected-results.tsv` |
| 逐项机械结果 | `meta/results.raw.tsv` |
| 候选门 | `candidate-gates.tsv` |
| 测试资产一致 | `meta/test-asset-hashes.tsv`、`cmp` rc |
| 补丁一致 | `diffs/ARM-writer.diff`、补丁 asset、apply rc |
| 路径白名单 | `meta/ARM-changed-paths.txt` 与 guard rc |
| 实际执行 | `assets/run-c02.sh`、`commands.sh`、`logs/shell-xtrace.log` |
| xtrace 覆盖 | `meta/xtrace-anchors.expected`、`logs/xtrace-anchor-guard.log` |
| 完整性 | `SHA256SUMS`、archive SHA256 |

---

## 三、安全、授权与失败处理

### 3.1 新 OUT 与临时目录

必须新建：

~~~text
/home/lilingfeng/tmp/juicefs-c02-YYYYmmdd-HHMMSS
~~~

必须同时设置：

~~~bash
export TMPDIR="$OUT/cache/os-tmp"
export GOTMPDIR="$OUT/cache/go-tmp"
export GOCACHE="$OUT/cache/go-build-TOOL"
export GOMODCACHE="$OUT/cache/go-mod"
~~~

“禁止 `/tmp`”指禁止任何以 `/tmp/` 开头的路径；`/home/lilingfeng/tmp/` 是允许的磁盘工作根。测试后用 `find`/xtrace 审计实际路径。

禁止读取或复用 C01/C01-R1 的 clone、测试文件、GOCACHE、GOMODCACHE 或结果作为 C02 输入。C01-R1 报告只用于背景，不作为本轮测试数据。

### 3.2 唯一执行入口：不可变 runner

本轮禁止在交互 shell 中逐条手跑测试。GLM 必须先在输入目录生成：

~~~text
/home/lilingfeng/tmp/juicefs-c02-input-YYYYmmdd-HHMMSS/
  run-c02.sh
  writer_flush_c02_test.go
  async-catchup-main.patch
~~~

然后：

1. 对三个输入文件执行 `sha256sum`，保存为 `input.sha256`；
2. `bash -n run-c02.sh`；
3. runner 启动后把自身与两个输入资产复制到 `$OUT/assets/`；
4. 后续 clone、工具链、补丁、测试、门禁、校验、归档全部由这一个 runner 完成；
5. runner 内部从 OUT 创建完成后立即开启 `BASH_XTRACEFD`，直至归档前关闭；
6. `commands.sh` 必须记录实际 runner 绝对路径、完整参数、输入 SHA256 和全部环境覆盖；
7. 不允许 runner 执行中途手工补跑。若 runner 缺命令，当前 OUT 记 `NON-COMPLIANT`，修 runner 后换全新 OUT。

这一规则用于消除 C01-R1“函数文件存在、但实际调用未进入 commands/xtrace”的审计缺口。

### 3.3 可自主适配与禁止擅动

允许自主适配，但必须通过 runner 参数或环境变量预先记录：

- GOPROXY/证书路径；
- 命令超时上限；
- 纯日志采集增强；
- 路径拼写、shell 兼容或不改变实验变量的 runner bug。

禁止擅动：

- fixed commit、三臂、补丁逻辑或测试源码；
- 测试名称、预期矩阵、marker、等待窗口、次数；
- Go 版本、`-race`、`GOFLAGS=-mod=readonly`；
- 外部服务禁令和路径白名单；
- 为让结果变绿而增加 sleep、忽略 rc、减少 count 或删除失败项。

如确实必须改上述变量才能继续，停止并回报 `BLOCKED`，等待 Codex 修改任务书。

### 3.4 失败处理

- clone、固定提交、工具链、依赖、编译或测试资产注入失败：停止测试，执行 partial 归档；
- S-stock 不符合预注册结果：停止 A/B 重复和 race，保留单项矩阵，状态 `TEST-ORACLE-FAIL`；
- B 任一单项失败：仍完成 A 已授权的单项，但不运行 B 的 count/race，状态 `B-CANDIDATE-FAIL`；
- A 出现表外失败：完整记录；不修改 A；
- 任何 panic、timeout、build failed 或 DATA RACE 都是非预期失败，不能用 marker 解释；
- 命令被外部中断时，不在同一 OUT 续跑，partial 归档后新建 OUT；
- 所有退出路径都必须触发 runner 的 trap，写入 `meta/final-status.txt`、`meta/failure-step.txt` 并生成 partial archive。

---

## 四、执行步骤

### 步骤 0：通读与 preflight

执行前完整阅读：

1. 本任务书；
2. C01-R1 原始报告；
3. C01-R1 任务书 §3.2、§5、§6、§7；
4. `prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.8、§二.9、§二.11；
5. `prod-deploy/skills/SYSTEM-SAFETY-SKILL.md`；
6. `docs/SUMMARY.md`，但不得把其中旧的“放弃上游”判断当作 C02 预设结论。

runner 必须把以下逐条写入 `meta/preflight.txt`：

- 已理解 C01-R1 的正式状态是 `TECHNICAL PASS / AUDIT NON-COMPLIANT`；
- 已理解 C02 不重跑性能、不访问任何外部服务；
- 已理解 stock 同时承担缺陷负控和兼容 oracle；
- 已理解 A 的 C2/C3 是预注册候选差异，不可删除；
- 已理解 B 是唯一社区候选推进门，但 GLM 不做方案选择；
- 已理解任何手工补跑都会使当前 OUT 审计失效；
- 已确认根级 `/tmp/`、SOURCE 工作树和生产路径都不可写。

### 步骤 1：生成并冻结输入资产

将附录 A、附录 B 逐字保存为输入目录中的对应文件。附录 A 允许且必须运行一次 `gofmt -w`；gofmt 后即冻结，三臂只能复制该文件。

冻结前必须核验：测试文件 gofmt 后 SHA256 与 §2.1 一致，B patch SHA256 与 §2.1 一致；任一不一致立即停止，不得自行“修到能跑”。

runner 必须满足：

~~~bash
set -Eeuo pipefail
umask 077

test -f "$C02_INPUT/writer_flush_c02_test.go"
test -f "$C02_INPUT/async-catchup-main.patch"
test -f "$C02_INPUT/run-c02.sh"
bash -n "$C02_INPUT/run-c02.sh"
sha256sum -c "$C02_INPUT/input.sha256"
~~~

输入哈希失败不得继续。禁止从旧 OUT 复制 C01 测试或 B patch。

### 步骤 2：建立 OUT、开启 xtrace、记录 runner

runner 至少创建：

~~~text
$OUT/
  assets/
  cache/{go-build-125,go-build-126,go-mod,go-tmp,os-tmp}/
  diffs/
  logs/
  meta/
  rc/
  src/{S-stock,A-sync,B-async-catchup}/
  commands.sh
~~~

要求磁盘可用空间至少 20 GiB。创建 OUT 后立即：

~~~bash
exec 19>>"$OUT/logs/shell-xtrace.log"
export BASH_XTRACEFD=19
PS4='+C02 ${BASH_SOURCE##*/}:${LINENO}: '
set -x
printf '%s\n' 'C02_ANCHOR:INIT'
~~~

runner、测试资产、A patch、B patch、任务书快照和 `input.sha256` 全部复制到 `assets/` 或 `meta/`。`commands.sh` 记录的是唯一 runner 调用，不得伪造为逐条人工命令。

### 步骤 3：三个独立 clone 与固定 HEAD

三个 clone 均从本地 Git 对象库建立，禁止 fetch：

~~~bash
printf '%s\n' 'C02_ANCHOR:CLONE'
for ARM in S-stock A-sync B-async-catchup; do
  git clone --no-hardlinks --no-checkout "$SOURCE" "$OUT/src/$ARM"
  git -C "$OUT/src/$ARM" cat-file -e "$MAIN_COMMIT^{commit}"
  git -C "$OUT/src/$ARM" checkout --detach "$MAIN_COMMIT"
  git -C "$OUT/src/$ARM" rev-parse HEAD
  git -C "$OUT/src/$ARM" status --porcelain
done
~~~

三臂 `status-before` 必须为空，HEAD 必须逐字等于 fixed commit。本地 SOURCE 当前分支、HEAD 和未提交修改均不得成为输入。

### 步骤 4：固定工具链、缓存和无外部服务基线

设置：

~~~bash
export GOPROXY="${C02_GOPROXY:-https://goproxy.cn,direct}"
export GOMODCACHE="$OUT/cache/go-mod"
export GOTMPDIR="$OUT/cache/go-tmp"
export TMPDIR="$OUT/cache/os-tmp"
export GOFLAGS=-mod=readonly
~~~

精确核验：

~~~text
go version go1.25.7 linux/amd64
go version go1.26.0 linux/amd64
~~~

仅在 S-stock 执行依赖下载。随后在两个工具链下分别运行：

~~~bash
go test ./pkg/vfs -run '^$' -count=1 -timeout=5m
go test ./pkg/vfs \
  -run '^(TestSmode|TestEntryString|TestError|TestVFSIO)$' \
  -count=1 -v -timeout=10m
~~~

四个白名单测试必须各出现一次 PASS。禁止加入 Redis 测试或 `pkg/chunk`。

### 步骤 5：注入同一测试资产并应用 A/B

复制测试资产：

~~~bash
printf '%s\n' 'C02_ANCHOR:ASSET'
for ARM in S-stock A-sync B-async-catchup; do
  cp "$OUT/assets/writer_flush_c02_test.go" \
    "$OUT/src/$ARM/pkg/vfs/writer_flush_c02_test.go"
  cmp "$OUT/assets/writer_flush_c02_test.go" \
    "$OUT/src/$ARM/pkg/vfs/writer_flush_c02_test.go"
  git -C "$OUT/src/$ARM" add -N pkg/vfs/writer_flush_c02_test.go
done
~~~

A：

~~~bash
printf '%s\n' 'C02_ANCHOR:APPLY_A'
sha256sum "$OUT/assets/juicefs-flush-race-fix-main.patch"
git -C "$OUT/src/A-sync" apply --check \
  "$OUT/assets/juicefs-flush-race-fix-main.patch"
git -C "$OUT/src/A-sync" apply \
  "$OUT/assets/juicefs-flush-race-fix-main.patch"
~~~

A patch SHA256 必须与 §2.1 一致。

B：

~~~bash
printf '%s\n' 'C02_ANCHOR:APPLY_B'
git -C "$OUT/src/B-async-catchup" apply --check \
  "$OUT/assets/async-catchup-main.patch"
git -C "$OUT/src/B-async-catchup" apply \
  "$OUT/assets/async-catchup-main.patch"
~~~

**禁止使用 `git apply --recount`。** 如果附录 B 不能用普通 `--check` 和 `apply`，立即 BLOCKED；不得手工改 patch。

应用后仅对 `writer.go` 和测试文件运行 gofmt。三臂测试文件再次 `cmp`；A/B `writer.go` 分别保存完整 diff。

### 步骤 6：生成预注册表并定义机械执行函数

runner 在任何目标测试前写死 `meta/expected-results.tsv`，至少包含：

~~~text
test_id  test_name  arm  expected_rc_class  expected_marker
~~~

内容必须与 §2.3 完全一致，禁止根据测试结果生成。

执行函数必须保证：

1. 每次 `go test` 独立日志、独立 rc；
2. 不使用会掩盖退出码的管道；
3. 每次都显式传 `GOTOOLCHAIN`、`GOCACHE`、`GOMODCACHE`、`GOTMPDIR`、`TMPDIR`、`GOFLAGS=-mod=readonly`；
4. 单项命令固定为：

~~~bash
go test ./pkg/vfs -run "^${TEST_NAME}$" -count=1 -v -timeout=2m
~~~

5. PASS 验真：rc=0，目标 `--- PASS:` 恰好一次；
6. 预期 FAIL 验真：rc 非零，marker 恰好一次，目标 `--- FAIL:` 恰好一次；
7. 所有日志都搜索禁止模式：

~~~text
[build failed]
panic:
fatal error:
test timed out
DATA RACE
~~~

8. 每项把 `actual_rc`、marker 数、目标 PASS/FAIL 数、forbidden 数和 `expectation_matched` 追加到 `meta/results.raw.tsv`。

### 步骤 7：先跑 stock oracle，再跑 A/B 单项

每个工具链必须严格按以下顺序：

1. S-stock 的 C1/C2/C3/F1/F2/F3；
2. S-stock 的 R1/R2/R3；
3. 机械检查全部符合 §2.3；
4. A-sync 十项适用测试；
5. B-async-catchup 十项；
6. 机械生成当前工具链单项 gate。

xtrace 中必须出现：

~~~text
C02_ANCHOR:TEST_go125
C02_ANCHOR:TEST_go126
~~~

stock oracle 不闭合时，不得继续重复/race。A 的 C2/C3 非零只有在 marker、次数和无 forbidden 全部符合时才算“预注册差异已确认”。

### 步骤 8：预期失败重复、候选 count 与 race

#### 8.1 十次独立预期失败

以下每一格都创建 `01..10` 十份日志和 rc：

| 工具链 | 臂 | ID |
|---|---|---|
| go125/go126 | S-stock | R1、R2、R3 |
| go125/go126 | A-sync | C2、C3 |

每份必须独立验 marker，汇总到 `meta/TOOL-ARM-ID-repeat10.tsv`。禁止用一次 `-count=10` 替代十个进程。

#### 8.2 A 的预期通过集合

~~~bash
A_PASS_RE='^(TestC02FullBlockDispatchAfterDelayedID|TestC02MultiBlockDispatchUsesLatestLength|TestC02FlushToFailureIsObservable|TestC02PartialThenFullAfterIDDispatchesOnce|TestC02TransientEIORecoversOnFreeze|TestC02PermanentENOSPCAbortsFrozenSlice|TestC02FrozenSliceSkipsCatchupFlush|TestC02ConcurrentIndependentFullBlocks)$'

go test ./pkg/vfs -run "$A_PASS_RE" -count=100 -v -timeout=15m
go test -race ./pkg/vfs -run "$A_PASS_RE" -count=20 -v -timeout=20m
~~~

普通日志中八个测试各恰好 100 个 PASS；race 日志中各恰好 20 个 PASS，且无 `DATA RACE`。

#### 8.3 B 的完整集合

~~~bash
B_ALL_RE='^TestC02(FullBlockDispatchAfterDelayedID|MultiBlockDispatchUsesLatestLength|FlushToFailureIsObservable|PartialThenFullAfterIDDispatchesOnce|DelayedNewSliceDoesNotBlockWriteAt|NonEIONewSliceDoesNotRetryBeforeFlush|TransientEIORecoversOnFreeze|PermanentENOSPCAbortsFrozenSlice|FrozenSliceSkipsCatchupFlush|ConcurrentIndependentFullBlocks)$'

go test ./pkg/vfs -run "$B_ALL_RE" -count=100 -v -timeout=20m
go test -race ./pkg/vfs -run "$B_ALL_RE" -count=20 -v -timeout=25m
~~~

普通日志中十个测试各恰好 100 个 PASS；race 日志中各恰好 20 个 PASS，且无 `DATA RACE`。

### 步骤 9：源码、HEAD、路径和测试资产门禁

runner 先记录：

~~~bash
printf '%s\n' 'C02_ANCHOR:SOURCE_GUARD'
~~~

每臂保存：

~~~bash
git status --short
git rev-parse HEAD
git diff --stat
git diff --full-index
git diff --check
git diff --name-only
sha256sum pkg/vfs/writer_flush_c02_test.go
~~~

路径白名单：

| 臂 | 唯一允许路径 |
|---|---|
| S-stock | `pkg/vfs/writer_flush_c02_test.go` |
| A-sync | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_c02_test.go` |
| B-async-catchup | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_c02_test.go` |

并核验：

- 三臂 HEAD 仍是 fixed commit；
- 三臂测试资产 SHA256 完全相同；
- `go.mod`、`go.sum`、vendor 和其他源码均未变化；
- B writer diff 只包含附录 B 的七行新增逻辑；
- B 保留原 `go s.prepareID(meta.Background(), false)`；
- B 条件必须同时包含 `s.id > 0`、`!s.freezed`、`s.slen >= blockSize`；
- B `FlushTo` 错误必须写入 `s.err = syscall.EIO`；
- A/B 均不得出现测试专用分支或 C02 标识进入生产代码。

### 步骤 10：生成 candidate-gates.tsv

禁止只生成一个“全部 PASS”。必须至少包含：

~~~text
gate                           go125  go126  overall  evidence
stock_oracle                   ...    ...    ...      ...
A_repair_and_fault             ...    ...    ...      ...
A_stock_compatibility          ...    ...    ...      ...
B_repair                       ...    ...    ...      ...
B_stock_compatibility          ...    ...    ...      ...
B_fault_and_freeze             ...    ...    ...      ...
B_count100                     ...    ...    ...      ...
B_race20                       ...    ...    ...      ...
source_and_asset_guards        ...    ...    ...      ...
execution_audit                ...    ...    ...      ...
~~~

`A_stock_compatibility` 在 C2/C3 精确命中预注册差异时写 `KNOWN-DEVIATION`，不是伪装成 PASS。B 的任一功能 gate 不得写 `KNOWN-DEVIATION`。

### 步骤 11：执行审计门禁

runner 先记录：

~~~bash
printf '%s\n' 'C02_ANCHOR:AUDIT'
~~~

runner 在测试和源码门禁结束后，打包前检查：

1. `assets/run-c02.sh` SHA256 与输入冻结值一致；
2. `commands.sh` 包含唯一真实 runner 调用、全部参数与环境覆盖；
3. `shell-xtrace.log` 包含以下所有 anchor：

~~~text
C02_ANCHOR:INIT
C02_ANCHOR:CLONE
C02_ANCHOR:ASSET
C02_ANCHOR:APPLY_A
C02_ANCHOR:APPLY_B
C02_ANCHOR:TEST_go125
C02_ANCHOR:TEST_go126
C02_ANCHOR:SOURCE_GUARD
C02_ANCHOR:AUDIT
C02_ANCHOR:PACKAGE
~~~

4. xtrace 中能找到所有单项测试名、`-count=100`、`-race` 和 `-count=20` 的实际调用；
5. xtrace/commands 中不存在根级 `/tmp/`、`git apply --recount`、`git fetch`、`sudo`、`fio`、`mount`、`redis`、`ceph` 或 `tikv` 执行动作；文档路径中的文字不作为命中，检查实际命令字段；
6. `meta/dependency-adaptations.txt` 逐条记录所有失败尝试和适配；无适配时文件必须写 `NONE`；
7. 所有 rc 文件都有对应日志，所有 expected row 都有 actual row；
8. 任何人工命令或 runner 外补跑均显式记 `NON-COMPLIANT`。

把逐项回答与证据路径写入 `meta/compliance-post.md`。任一否项不得输出任何 PASS 状态。

### 步骤 12：冻结、SHA256、partial/final 归档

runner 必须在 xtrace 尚开启时先打印：

~~~bash
printf '%s\n' 'C02_ANCHOR:PACKAGE'
~~~

随后完成最终元数据写入，再关闭 xtrace。归档规则：

- archive 包含 `assets diffs logs meta rc commands.sh summary.tsv candidate-gates.tsv SHA256SUMS`；
- archive 不包含 `src` 和 `cache`；
- OUT 中的 `src` 和 `cache` 保留到 Codex 复核完成；
- `SHA256SUMS` 覆盖所有入 archive 的普通文件，但不覆盖自身；
- `sha256sum -c SHA256SUMS` 必须 rc=0；
- archive 另生成 `<archive>.sha256`；
- 失败 trap 也必须生成带 `partial` 标识的 archive，不能只留散落 OUT。

建议路径：

~~~text
/home/lilingfeng/tmp/juicefs-c02-YYYYmmdd-HHMMSS-artifacts.tar.gz
~~~

---

## 五、状态判定与后续分支

### 5.1 `PASS-B-COMMUNITY-CANDIDATE`

必须全部满足：

1. stock oracle 在两个工具链完全符合预注册矩阵；
2. A 所有结果均被完整执行和记录；
3. B 十项单测全部 PASS；
4. B count100 与 race20 在两个工具链全部 PASS；
5. race 无 `DATA RACE`；
6. B diff、HEAD、测试资产、路径白名单全部通过；
7. 审计与归档无否项。

允许结论：

> 在固定 main commit 和两个指定 Go 工具链下，B 在保留 stock 的异步非阻塞与非 EIO 单次尝试语义的同时，覆盖完整块/多块漏派发，并在 FlushTo 错误、EIO、ENOSPC、freeze 与并发 race 矩阵中通过。B 可进入社区补丁整理和上游完整 CI 设计。

不得写“已经达到 PR 合并质量”或“宏观性能已在 main 修复”。

### 5.2 `PASS-A-CORE / B-CANDIDATE-FAIL`

仅当 A 的 repair/fault/race 全通过而 B 有功能失败时使用。结论必须同时写明 A 的 C2/C3 是否确认了：

- 元数据延迟会阻塞首次 WriteAt；
- 非 EIO 首次失败会在 flush 前额外调用一次 NewSlice。

此分支只允许进入 A 自维护风险评估，不进入社区提交。

### 5.3 `TEST-ORACLE-FAIL`

stock 未按预注册矩阵执行，说明测试实现、补丁隔离或固定源码有问题。停止，不评价 A/B。

### 5.4 `CANDIDATES-FAIL`

A/B 均出现 repair、错误传播、freeze 或 race 表外失败。停止，不进入性能、长稳和社区流程。

### 5.5 `NON-COMPLIANT` / `BLOCKED`

- 技术测试可能完成，但执行审计任一否项：`NON-COMPLIANT`；
- 工具链、依赖、源码或固定输入无法建立：`BLOCKED`。

这两个状态均不能作为下一阶段输入。

---

## 六、GLM 交付物

GLM 必须交付：

1. OUT、archive、archive.sha256 的绝对路径；
2. archive SHA256；
3. `meta/preflight.txt`；
4. 两个工具链 version/env 全文；
5. `arm-heads-before.tsv` 与 `arm-heads-after.tsv`；
6. `meta/expected-results.tsv` 全文；
7. `meta/results.raw.tsv` 与 `summary.tsv` 全文；
8. `candidate-gates.tsv` 全文；
9. 五组预期失败 repeat10 TSV 及全部 100 份日志/rc（每个工具链 50 份）；
10. A/B 的 count100、race20 日志和 PASS 数量审计；
11. 所有单项日志和 rc；
12. 三臂 status、diff-stat、完整 diff、writer diff、changed paths；
13. 测试资产和补丁 SHA256；
14. `commands.sh`、完整 `shell-xtrace.log`、xtrace anchor guard；
15. `dependency-adaptations.txt` 与 `compliance-post.md`；
16. 所有非零、预期外、panic、timeout、build 或 race 日志全文；
17. OUT/src 和 OUT/cache 保留声明。

第 9 项计数说明：每个工具链有 S 的 R1/R2/R3 三组和 A 的 C2/C3 两组，共五组 ×10；两个工具链共 100 份独立预期失败日志。

报告保存为：

~~~text
prod-deploy/debug/juicefs-03-8-flush-race-community/report/C02-execution-YYYYmmdd-HHMMSS.md
~~~

建议模板：

~~~markdown
# C02 GLM 原始执行报告

- OUT：
- archive：
- archive sha256：
- fixed main：
- go125：
- go126：
- runner sha256：
- 起止时间：
- 状态：

## expected-results.tsv
## summary.tsv
## candidate-gates.tsv
## stock oracle
## A-sync
## B-async-catchup
## count100 and race20
## source and asset guards
## execution audit
## adaptations and unexpected results
~~~

报告只陈述机械事实，不选择候选，不创建下一任务，不进入性能测试。

---

## 七、红线汇总

1. 禁止写根级 `/tmp/`；所有临时目录必须显式指向 `$OUT/cache`。
2. 禁止删除、覆盖或复用 C01/C01-R1 OUT。
3. 禁止 `rm -rf`、`git reset --hard`、`git clean`、`git checkout --`。
4. 禁止修改 `/home/lilingfeng/project/juicefs` 或任何现有 worktree。
5. 禁止 fetch、漂移 main、换 commit、换工具链。
6. 禁止修改 go.mod、go.sum、vendor 或依赖版本。
7. 禁止 Redis、Ceph、TiKV、S3、mount、fio、sudo、drop_caches、OSD/pool 操作。
8. 禁止运行 pkg/vfs 全量测试和任何 pkg/chunk 测试。
9. 禁止修改附录 A/B、预期矩阵、marker、等待窗口或次数。
10. 禁止 `git apply --recount`；B 必须由修正后的标准 patch 直接应用。
11. 禁止把预期失败笼统视为 PASS；必须验证唯一 marker 和唯一目标失败。
12. 禁止把 A 的已知兼容差异隐去或改写为普通 PASS。
13. 禁止 runner 外手工补跑或用注释摘要替代实际执行证据。
14. 禁止 commit、push、issue、PR 或任何外部社区动作。
15. 任一越权、表外适配或审计否项，立即停止并如实标记。

---

## 附录 A：`writer_flush_c02_test.go`

以下内容必须逐字保存并执行一次 gofmt；三臂复制 gofmt 后的同一文件。

```go
package vfs

import (
	"errors"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/juicedata/juicefs/pkg/chunk"
	"github.com/juicedata/juicefs/pkg/meta"
	"github.com/juicedata/juicefs/pkg/object"
	"github.com/juicedata/juicefs/pkg/utils"
)

const c02BlockSize = 256 << 10

type c02NewSliceStep struct {
	id      uint64
	errno   syscall.Errno
	release <-chan struct{}
}

type c02PlannedMeta struct {
	meta.Meta
	mu    sync.Mutex
	steps []c02NewSliceStep
	calls int
}

func newC02PlannedMeta(steps ...c02NewSliceStep) *c02PlannedMeta {
	return &c02PlannedMeta{steps: steps}
}

func (m *c02PlannedMeta) NewSlice(_ meta.Context, id *uint64) syscall.Errno {
	m.mu.Lock()
	call := m.calls
	m.calls++
	step := m.steps[len(m.steps)-1]
	if call < len(m.steps) {
		step = m.steps[call]
	}
	m.mu.Unlock()

	if step.release != nil {
		<-step.release
	}
	if step.errno == 0 {
		*id = step.id
	}
	return step.errno
}

func (m *c02PlannedMeta) Calls() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.calls
}

type c02RecordingWriter struct {
	mu          sync.Mutex
	id          uint64
	flushes     []int
	finishes    []int
	aborts      int
	flushErr    error
	finishErr   error
	writeAtOnce sync.Once
	writeAtCh   chan struct{}
}

func newC02RecordingWriter() *c02RecordingWriter {
	return &c02RecordingWriter{writeAtCh: make(chan struct{})}
}

func (w *c02RecordingWriter) WriteAt(p []byte, _ int64) (int, error) {
	w.writeAtOnce.Do(func() { close(w.writeAtCh) })
	return len(p), nil
}

func (w *c02RecordingWriter) ID() uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.id
}

func (w *c02RecordingWriter) SetID(id uint64) {
	w.mu.Lock()
	w.id = id
	w.mu.Unlock()
}

func (w *c02RecordingWriter) SetWriteback(bool) {}

func (w *c02RecordingWriter) FlushTo(offset int) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.flushes = append(w.flushes, offset)
	return w.flushErr
}

func (w *c02RecordingWriter) Finish(length int) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.finishes = append(w.finishes, length)
	return w.finishErr
}

func (w *c02RecordingWriter) Abort() {
	w.mu.Lock()
	w.aborts++
	w.mu.Unlock()
}

func (w *c02RecordingWriter) State() (uint64, []int, []int, int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.id, append([]int(nil), w.flushes...), append([]int(nil), w.finishes...), w.aborts
}

type c02ChunkStore struct {
	writer chunk.Writer
}

func (s *c02ChunkStore) NewReader(uint64, int) chunk.Reader { return nil }

func (s *c02ChunkStore) NewWriter(uint64, uint8) chunk.Writer { return s.writer }

func (s *c02ChunkStore) Remove(uint64, int) error { return nil }

func (s *c02ChunkStore) FillCache(uint64, uint32) error { return nil }

func (s *c02ChunkStore) EvictCache(uint64, uint32) error { return nil }

func (s *c02ChunkStore) CheckCache(uint64, uint32, func(bool, string, int)) error {
	return nil
}

func (s *c02ChunkStore) UsedMemory() int64 { return 0 }

func (s *c02ChunkStore) UpdateLimit(int64, int64) {}

func (s *c02ChunkStore) BlobStorage() object.ObjectStorage { return nil }

type c02Harness struct {
	f      *fileWriter
	c      *chunkWriter
	meta   *c02PlannedMeta
	writer *c02RecordingWriter
}

func newC02Harness(m *c02PlannedMeta, writer *c02RecordingWriter) *c02Harness {
	w := &dataWriter{
		m:         m,
		store:     &c02ChunkStore{writer: writer},
		blockSize: c02BlockSize,
	}
	f := &fileWriter{
		w:      w,
		inode:  2,
		chunks: make(map[uint32]*chunkWriter),
	}
	c := &chunkWriter{indx: 0, file: f}
	// The dummy non-overlapping slice prevents writeChunk from starting
	// commitThread; C02 tests the dispatch state machine in isolation.
	c.slices = []*sliceWriter{{
		chunk:   c,
		off:     8 * c02BlockSize,
		slen:    c02BlockSize,
		freezed: true,
	}}
	f.chunks[0] = c
	return &c02Harness{f: f, c: c, meta: m, writer: writer}
}

func (h *c02Harness) writeAsync(off uint32, data []byte) <-chan syscall.Errno {
	done := make(chan syscall.Errno, 1)
	go func() {
		h.f.Lock()
		st := h.f.writeChunk(meta.Background(), 0, off, data)
		h.f.Unlock()
		done <- st
	}()
	return done
}

func (h *c02Harness) newestSlice() *sliceWriter {
	h.f.Lock()
	defer h.f.Unlock()
	return h.c.slices[len(h.c.slices)-1]
}

func (h *c02Harness) setFreezed(s *sliceWriter) {
	h.f.Lock()
	s.freezed = true
	h.f.Unlock()
}

func (h *c02Harness) sliceErr(s *sliceWriter) syscall.Errno {
	h.f.Lock()
	defer h.f.Unlock()
	return s.err
}

func c02WaitFor(timeout time.Duration, condition func() bool) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return condition()
}

func c02WaitWrite(t *testing.T, done <-chan syscall.Errno) syscall.Errno {
	t.Helper()
	select {
	case st := <-done:
		return st
	case <-time.After(2 * time.Second):
		t.Fatal("writeChunk did not return")
		return syscall.EIO
	}
}

func c02WaitFlushData(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("flushData did not return")
	}
}

func c02AssertOneFlush(t *testing.T, writer *c02RecordingWriter, want int, marker string) {
	t.Helper()
	if !c02WaitFor(750*time.Millisecond, func() bool {
		_, flushes, _, _ := writer.State()
		return len(flushes) > 0
	}) {
		t.Fatalf("%s: FlushTo(%d) was not observed", marker, want)
	}
	time.Sleep(50 * time.Millisecond)
	_, flushes, _, _ := writer.State()
	if len(flushes) != 1 || flushes[0] != want {
		t.Fatalf("FlushTo calls = %v, want [%d]", flushes, want)
	}
}

func TestC02FullBlockDispatchAfterDelayedID(t *testing.T) {
	release := make(chan struct{})
	m := newC02PlannedMeta(c02NewSliceStep{id: 11, release: release})
	w := newC02RecordingWriter()
	h := newC02Harness(m, w)

	done := h.writeAsync(0, make([]byte, c02BlockSize))
	if !c02WaitFor(time.Second, func() bool { return m.Calls() == 1 }) {
		t.Fatal("NewSlice was not called")
	}
	close(release)
	if st := c02WaitWrite(t, done); st != 0 {
		t.Fatalf("writeChunk returned %s", st)
	}
	c02AssertOneFlush(t, w, c02BlockSize, "C02_MISSED_DISPATCH")
}

func TestC02MultiBlockDispatchUsesLatestLength(t *testing.T) {
	release := make(chan struct{})
	m := newC02PlannedMeta(c02NewSliceStep{id: 12, release: release})
	w := newC02RecordingWriter()
	h := newC02Harness(m, w)

	done := h.writeAsync(0, make([]byte, 2*c02BlockSize))
	if !c02WaitFor(time.Second, func() bool { return m.Calls() == 1 }) {
		t.Fatal("NewSlice was not called")
	}
	close(release)
	if st := c02WaitWrite(t, done); st != 0 {
		t.Fatalf("writeChunk returned %s", st)
	}
	c02AssertOneFlush(t, w, 2*c02BlockSize, "C02_MISSED_MULTI_DISPATCH")
}

func TestC02FlushToFailureIsObservable(t *testing.T) {
	release := make(chan struct{})
	m := newC02PlannedMeta(c02NewSliceStep{id: 13, release: release})
	w := newC02RecordingWriter()
	w.flushErr = errors.New("C02 injected FlushTo failure")
	h := newC02Harness(m, w)

	done := h.writeAsync(0, make([]byte, c02BlockSize))
	if !c02WaitFor(time.Second, func() bool { return m.Calls() == 1 }) {
		t.Fatal("NewSlice was not called")
	}
	close(release)
	writeErr := c02WaitWrite(t, done)
	s := h.newestSlice()
	_ = c02WaitFor(750*time.Millisecond, func() bool {
		_, flushes, _, _ := w.State()
		return len(flushes) > 0 || h.sliceErr(s) != 0
	})

	sliceErr := h.sliceErr(s)
	_, flushes, _, _ := w.State()
	if writeErr != syscall.EIO && sliceErr != syscall.EIO {
		t.Fatalf("C02_SWALLOWED_FLUSH_ERROR: write=%s slice=%s flushes=%v", writeErr, sliceErr, flushes)
	}
	if len(flushes) != 1 || flushes[0] != c02BlockSize {
		t.Fatalf("FlushTo calls = %v, want [%d]", flushes, c02BlockSize)
	}
}

func TestC02PartialThenFullAfterIDDispatchesOnce(t *testing.T) {
	release := make(chan struct{})
	m := newC02PlannedMeta(c02NewSliceStep{id: 14, release: release})
	w := newC02RecordingWriter()
	h := newC02Harness(m, w)

	first := h.writeAsync(0, make([]byte, c02BlockSize/2))
	if !c02WaitFor(time.Second, func() bool { return m.Calls() == 1 }) {
		t.Fatal("NewSlice was not called")
	}
	close(release)
	if st := c02WaitWrite(t, first); st != 0 {
		t.Fatalf("first writeChunk returned %s", st)
	}
	if !c02WaitFor(time.Second, func() bool { return w.ID() == 14 }) {
		t.Fatal("slice ID was not assigned")
	}

	second := h.writeAsync(c02BlockSize/2, make([]byte, c02BlockSize/2))
	if st := c02WaitWrite(t, second); st != 0 {
		t.Fatalf("second writeChunk returned %s", st)
	}
	c02AssertOneFlush(t, w, c02BlockSize, "C02_PARTIAL_FULL_MISSED")
}

func TestC02DelayedNewSliceDoesNotBlockWriteAt(t *testing.T) {
	release := make(chan struct{})
	m := newC02PlannedMeta(c02NewSliceStep{id: 15, release: release})
	w := newC02RecordingWriter()
	h := newC02Harness(m, w)

	done := h.writeAsync(0, make([]byte, c02BlockSize/2))
	if !c02WaitFor(time.Second, func() bool { return m.Calls() == 1 }) {
		t.Fatal("NewSlice was not called")
	}
	select {
	case <-w.writeAtCh:
		close(release)
	case <-time.After(500 * time.Millisecond):
		close(release)
		_ = c02WaitWrite(t, done)
		t.Fatal("C02_BLOCKING_REGRESSION: WriteAt did not run before delayed NewSlice was released")
	}
	if st := c02WaitWrite(t, done); st != 0 {
		t.Fatalf("writeChunk returned %s", st)
	}
	if !c02WaitFor(time.Second, func() bool { return w.ID() == 15 }) {
		t.Fatal("slice ID was not assigned")
	}
}

func TestC02NonEIONewSliceDoesNotRetryBeforeFlush(t *testing.T) {
	secondRelease := make(chan struct{})
	m := newC02PlannedMeta(
		c02NewSliceStep{errno: syscall.ENOSPC},
		c02NewSliceStep{errno: syscall.ENOSPC, release: secondRelease},
	)
	w := newC02RecordingWriter()
	h := newC02Harness(m, w)

	done := h.writeAsync(0, make([]byte, c02BlockSize/2))
	if st := c02WaitWrite(t, done); st != 0 {
		t.Fatalf("writeChunk returned %s", st)
	}
	if !c02WaitFor(time.Second, func() bool { return m.Calls() >= 1 }) {
		t.Fatal("NewSlice was not called")
	}
	if c02WaitFor(500*time.Millisecond, func() bool { return m.Calls() >= 2 }) {
		close(secondRelease)
		t.Fatal("C02_EXTRA_NEWSLICE_ATTEMPT: non-EIO NewSlice failure was retried before flush")
	}
}

func TestC02TransientEIORecoversOnFreeze(t *testing.T) {
	secondRelease := make(chan struct{})
	m := newC02PlannedMeta(
		c02NewSliceStep{errno: syscall.EIO},
		c02NewSliceStep{id: 21, release: secondRelease},
	)
	w := newC02RecordingWriter()
	h := newC02Harness(m, w)

	done := h.writeAsync(0, make([]byte, c02BlockSize))
	if st := c02WaitWrite(t, done); st != 0 {
		t.Fatalf("writeChunk returned %s", st)
	}
	if !c02WaitFor(time.Second, func() bool { return m.Calls() >= 1 }) {
		t.Fatal("first NewSlice was not called")
	}
	s := h.newestSlice()
	h.setFreezed(s)
	flushDone := make(chan struct{})
	go func() {
		s.flushData()
		close(flushDone)
	}()
	if !c02WaitFor(time.Second, func() bool { return m.Calls() >= 2 }) {
		t.Fatal("retry NewSlice was not called")
	}
	close(secondRelease)
	c02WaitFlushData(t, flushDone)

	id, flushes, finishes, aborts := w.State()
	if id != 21 || len(flushes) != 0 || len(finishes) != 1 || finishes[0] != c02BlockSize || aborts != 0 {
		t.Fatalf("state id=%d flushes=%v finishes=%v aborts=%d", id, flushes, finishes, aborts)
	}
	if err := h.sliceErr(s); err != 0 {
		t.Fatalf("slice err = %s, want success", err)
	}
}

func TestC02PermanentENOSPCAbortsFrozenSlice(t *testing.T) {
	m := newC02PlannedMeta(c02NewSliceStep{errno: syscall.ENOSPC})
	w := newC02RecordingWriter()
	h := newC02Harness(m, w)

	done := h.writeAsync(0, make([]byte, c02BlockSize))
	if st := c02WaitWrite(t, done); st != 0 {
		t.Fatalf("writeChunk returned %s", st)
	}
	s := h.newestSlice()
	if !c02WaitFor(time.Second, func() bool { return h.sliceErr(s) == syscall.ENOSPC }) {
		t.Fatalf("slice err = %s, want ENOSPC", h.sliceErr(s))
	}
	h.setFreezed(s)
	s.flushData()

	_, flushes, finishes, aborts := w.State()
	if len(flushes) != 0 || len(finishes) != 0 || aborts != 1 {
		t.Fatalf("flushes=%v finishes=%v aborts=%d, want 0/0/1", flushes, finishes, aborts)
	}
	if err := h.sliceErr(s); err != syscall.ENOSPC {
		t.Fatalf("slice err = %s, want ENOSPC", err)
	}
}

func TestC02FrozenSliceSkipsCatchupFlush(t *testing.T) {
	release := make(chan struct{})
	m := newC02PlannedMeta(c02NewSliceStep{id: 22, release: release})
	w := newC02RecordingWriter()
	h := newC02Harness(m, w)
	s := &sliceWriter{
		chunk:   h.c,
		slen:    c02BlockSize,
		freezed: true,
		writer:  w,
		notify:  utils.NewCond(&h.f.Mutex),
		started: time.Now(),
	}
	h.f.Lock()
	h.c.slices = append(h.c.slices, s)
	h.f.Unlock()

	prepareDone := make(chan struct{})
	go func() {
		s.prepareID(meta.Background(), false)
		close(prepareDone)
	}()
	if !c02WaitFor(time.Second, func() bool { return m.Calls() == 1 }) {
		t.Fatal("NewSlice was not called")
	}
	close(release)
	c02WaitFlushData(t, prepareDone)
	if _, flushes, _, _ := w.State(); len(flushes) != 0 {
		t.Fatalf("freezed slice catch-up called FlushTo: %v", flushes)
	}
	s.flushData()
	id, flushes, finishes, aborts := w.State()
	if id != 22 || len(flushes) != 0 || len(finishes) != 1 || finishes[0] != c02BlockSize || aborts != 0 {
		t.Fatalf("state id=%d flushes=%v finishes=%v aborts=%d", id, flushes, finishes, aborts)
	}
}

func TestC02ConcurrentIndependentFullBlocks(t *testing.T) {
	const workers = 32
	type worker struct {
		h    *c02Harness
		done <-chan syscall.Errno
	}
	items := make([]worker, workers)
	start := make(chan struct{})
	var wg sync.WaitGroup

	for i := 0; i < workers; i++ {
		m := newC02PlannedMeta(c02NewSliceStep{id: uint64(1000 + i)})
		w := newC02RecordingWriter()
		h := newC02Harness(m, w)
		result := make(chan syscall.Errno, 1)
		items[i] = worker{h: h, done: result}
		wg.Add(1)
		go func(h *c02Harness, result chan<- syscall.Errno) {
			defer wg.Done()
			<-start
			result <- <-h.writeAsync(0, make([]byte, c02BlockSize))
		}(h, result)
	}

	close(start)
	wg.Wait()
	for i, item := range items {
		if st := c02WaitWrite(t, item.done); st != 0 {
			t.Fatalf("worker %d writeChunk returned %s", i, st)
		}
		if !c02WaitFor(time.Second, func() bool {
			id, flushes, _, _ := item.h.writer.State()
			return id != 0 && len(flushes) == 1
		}) {
			id, flushes, _, _ := item.h.writer.State()
			t.Fatalf("worker %d id=%d flushes=%v", i, id, flushes)
		}
		id, flushes, _, _ := item.h.writer.State()
		if id != uint64(1000+i) || len(flushes) != 1 || flushes[0] != c02BlockSize {
			t.Fatalf("worker %d id=%d flushes=%v", i, id, flushes)
		}
	}
}
```

---

## 附录 B：修正后的 `async-catchup-main.patch`

本附录已经把 C01-R1 的错误 hunk 行数 `+93,14` 修正为 `+93,13`。必须能用普通 `git apply --check` 和 `git apply` 应用，禁止 `--recount`。

```diff
diff --git a/pkg/vfs/writer.go b/pkg/vfs/writer.go
--- a/pkg/vfs/writer.go
+++ b/pkg/vfs/writer.go
@@ -93,6 +93,13 @@ func (s *sliceWriter) prepareID(ctx meta.Context, retry bool) {
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
```

---

## 附录 C：runner 必备锚点和输出表头

runner 具体工程实现可由 GLM 完成，但以下字符串、表头和调用顺序不可修改。

### C.1 xtrace 锚点

~~~text
C02_ANCHOR:INIT
C02_ANCHOR:CLONE
C02_ANCHOR:ASSET
C02_ANCHOR:APPLY_A
C02_ANCHOR:APPLY_B
C02_ANCHOR:TEST_go125
C02_ANCHOR:TEST_go126
C02_ANCHOR:SOURCE_GUARD
C02_ANCHOR:AUDIT
C02_ANCHOR:PACKAGE
~~~

### C.2 results.raw.tsv

~~~text
toolchain	arm	test_id	test_name	actual_rc	expected_rc_class	marker_count	pass_count	fail_count	forbidden_count	log	expectation_matched
~~~

### C.3 repeat10.tsv

~~~text
iteration	actual_rc	marker_count	test_fail_count	forbidden_count	expectation_matched	log
~~~

### C.4 summary.tsv

`summary.tsv` 必须由 `results.raw.tsv` 机械复制或排序生成，不得手抄。所有预注册结果闭合时，`expectation_matched` 才能全部为 YES；这包含 stock/A 的指定预期失败，不代表所有 `go test` rc 都是 0。
