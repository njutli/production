# U01：JuiceFS latest main 最小洁净回放与社区候选复核

> 执行方：GLM　｜　计划/复核方：Codex　｜　编写日期：2026-08-18
> 性质：C03 以 `R5-HARNESS-BLOCKED` 结束后的独立轻量阶段；不是 C03-R6
> 范围：WSL 本地临时目录、官方 GitHub 匿名只读访问、本轮隔离 Redis
> 禁止：SSH/157、fio、mount、Ceph/TiKV、生产目录、sudo、commit/push/fork/issue/PR/comment
> 重要：本任务书本身不授予执行权限；须取得 §3.2 的本轮明确授权后才能执行

---

## 计划线

```text
C01
  └─ frozen main 的 ID-ready 漏派发行为已确定性复现
C02
  └─ B 的完整/部分块、错误、freeze、重试和并发语义已有技术旁证
C03
  └─ 技术结论收敛；自定义证据 harness 未收敛，CLOSED-BLOCKED
★ U01（你在这里）
  ├─ 冻结执行时官方 latest main
  ├─ stock 三项判别 → 判断问题仍存在或上游已修复
  ├─ 若仍存在：B 最小 apply、测试、质量门和 fresh replay
  └─ 若已修复：定位候选官方 commit，不再叠加 B
U01 经 Codex 复核
  ├─ 可继续 → 更新社区草稿并由用户决定是否授权社区写操作
  └─ 漂移/失败 → 分析官方变化或保留内部 patch，不伪造 PR-ready
```

一句话：用最小、可人工复核的原生命令链回答“执行时 latest main 是否仍有目标
行为，以及 B 是否能在同一 commit 上以两文件 patch 洁净纠正它”。

---

## 〇、背景与证据边界

### 0.1 可以承接的事实

1. 最后完成技术验证的官方 main commit 为
   `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`。
2. 该 commit 上 stock 的 U1/U3 呈现目标失败、U2 通过；B 的三项、count/race、
   C02 十项、完整 `pkg/vfs`、lint/build 原始日志提供了技术旁证。
3. 当前归档的 writer-only B patch、社区三项测试和 C02 十项测试已经固定哈希。
4. C03-R5 没有运行 formal patch test；其失败是 harness 实现问题，不是 B 的新失败。

### 0.2 不能继承的声明

- 不继承 R3/R4 的 `PASS-B-PR-READY-LOCAL`、24/24 gate 或 archive integrity；
- 不假定 2026-08-18 执行时 latest main 仍等于 `53835e24`；
- 不假定历史两文件 patch 能原样应用到 latest main；
- 不把本地 PASS 写成 GitHub CI、维护者认可或社区已修复；
- 不在本任务中证明 v1.3 的真实 Ceph randwrite 性能。

### 0.3 为什么不继续 R5

本轮不实现独立 oracle、37 个合成 fixture、24 gate、finalizer 或多重 archive
协议。结论只依赖：固定输入、frozen commit、实际源码 diff、每条原生命令、完整
stdout/stderr、rc sidecar 和一次 fresh replay。GLM 可以整理索引，但索引不能替代
原始日志；最终判定由 Codex人工复核。

---

## 一、唯一问题、分支和允许终态

### 1.1 唯一主问题

> 在执行时冻结的官方 latest main 上，stock 是否仍出现 U1/U3 目标失败、U2 通过；
> 若仍存在，B 是否只改 `pkg/vfs/writer.go`，并与社区测试组成可标准 apply/replay
> 的至多两文件候选，使三项、必要压力、C02 语义和最小本地质量门通过？通常 patch
> 包含 writer+test 两文件；若 upstream 已逐字节包含固定测试，则只需提交 writer。

### 1.2 允许终态

```text
PASS-B-LATEST-MAIN-MINIMAL
UPSTREAM-ALREADY-FIXED
UPSTREAM-ORACLE-DRIFT
B-PATCH-DRIFT
B-TECHNICAL-FAIL
BLOCKED-AUTH-OR-NETWORK
BLOCKED-TOOLCHAIN-OR-REDIS
U01-NON-COMPLIANT
```

这些状态均不等于社区已经提交。`PASS-B-LATEST-MAIN-MINIMAL` 只表示材料可以交给
Codex 做最终代码、日志和草稿复核。

### 1.3 分支公式

```text
stock = U1 FAIL(唯一 marker) + U2 PASS + U3 FAIL(唯一 marker)
  => TARGET-BEHAVIOR-PRESENT
  => 才允许应用/移植 B

stock = U1/U2/U3 全 PASS，且源码/history 找到等价修复
  => UPSTREAM-ALREADY-FIXED
  => 禁止再应用 B

stock 为其它组合、测试超时/竞态不稳定、测试 API 无法作等价适配
  => UPSTREAM-ORACLE-DRIFT

TARGET-BEHAVIOR-PRESENT + B/replay 全部满足 §6
  => PASS-B-LATEST-MAIN-MINIMAL
```

---

## 二、固定输入、哈希与目录

### 2.1 权威输入

根目录：

```text
ROOT=/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community
MATERIALS=$ROOT/community-materials
```

| 资产 | 固定路径 | SHA256 | 用途 |
|---|---|---|---|
| writer-only B | `$MATERIALS/candidate/async-catchup-main.patch` | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` | latest main 候选输入 |
| 社区三项测试 | `$MATERIALS/tests/writer_flush_test.go` | `bce85ad4abf92a47074849a544aaa756963fb44a1839619bbc71c5d7ce1fe9bc` | stock/B/replay 判别 |
| C02 十项测试 | `$MATERIALS/tests/writer_flush_c02_test.go` | `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` | B 内部语义旁证 |
| 历史两文件候选 | `$MATERIALS/candidate/community-candidate.patch` | `1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9` | 只作 diff 参考，不直接当 latest patch |
| 归档说明 | `$MATERIALS/README.md` | 执行时实算 | 证据边界 |
| 本任务书 | `$ROOT/tasks/U01-latest-main-minimal-clean-replay.md` | 执行时实算 | 权威要求 |

任一固定业务资产缺失或哈希不符，停止为 `U01-NON-COMPLIANT`；禁止从聊天记录、
旧 OUT 或任务书附录手抄替代。

### 2.2 官方来源与只读 seed

```text
OFFICIAL_URL=https://github.com/juicedata/juicefs
READONLY_SEED=/home/lilingfeng/project/juicefs
HISTORICAL_MAIN=53835e2481f45cba159cdbcc1ce0f1fc576e3f1a
```

`READONLY_SEED` 只能用于读取已有 Git object、status 和历史参考；禁止在其中 fetch、
checkout、apply、gofmt、build 或 test。所有网络 fetch 和工作树写入都在本轮 `/tmp`
目录进行。

### 2.3 本轮唯一目录

```text
RUN_ID=YYYYmmdd-HHMMSS
CTRL=/home/lilingfeng/tmp/juicefs-u01-control-$RUN_ID
INPUT=/home/lilingfeng/tmp/juicefs-u01-input-$RUN_ID
OUT=/home/lilingfeng/tmp/juicefs-u01-$RUN_ID
ARCHIVE=/home/lilingfeng/tmp/juicefs-u01-$RUN_ID-artifacts.tar.gz
REPORT=$ROOT/report/U01-execution-$RUN_ID.md
```

上述路径启动前必须全部不存在。若冲突，生成新 RUN_ID；禁止删除、覆盖或续写未知
目录。源码 arm 固定为：

```text
$OUT/src/F-fetch
$OUT/src/S-stock
$OUT/src/B-candidate
$OUT/src/Q-semantic
$OUT/src/R-replay
```

### 2.4 冻结后允许改动的源码路径

| arm | 允许的 changed/untracked path |
|---|---|
| S-stock | `pkg/vfs/writer_flush_test.go` |
| B-candidate | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |
| Q-semantic | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_c02_test.go` |
| R-replay | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |

任何数据库、WAL、临时测试文件或其它源码路径出现，均先保存现场并判
`U01-NON-COMPLIANT`，不得用 `.gitignore` 掩盖；唯一例外是 §9 事前登记的 upstream
full-vfs SQLite 副作用和 Makefile 构建产物，二者必须采证后只清理本轮精确文件，
最终 guard 中不得残留。

---

## 三、权限、安全和自主修复边界

### 3.1 任务书不授权执行

未获得用户明确授权时，只能读取本任务书、归档和旧报告；不得创建本轮 `/tmp`
目录、fetch/clone、下载 Go module/toolchain、启动 Docker 或运行 Go 命令。

### 3.2 建议的精确授权原文

GLM 必须从用户消息中取得与下列范围等价的明确授权，并把原文逐字保存到
`$CTRL/authorization.txt` 后计算 SHA256：

> 我授权执行 U01 任务书；仅限 WSL 本地新建的
> `/home/lilingfeng/tmp/juicefs-u01-*`，允许匿名只读访问官方 JuiceFS GitHub、下载
> 本轮 Go module/toolchain，并允许启动/检查/停止名称和 label 都含 RUN_ID 的隔离
> Redis 容器；禁止 SSH/157、sudo、fio、mount、Ceph/TiKV、系统安装、修改只读 seed、
> 删除旧现场以及任何 commit/push/fork/issue/PR/comment 社区写操作。

授权缺项时不得自行补全权限，状态为 `BLOCKED-AUTH-OR-NETWORK`。

### 3.3 可自主修复

在不改变测试语义和控制变量的前提下，GLM 可自行处理并记录：

- `/tmp` 路径、shell quoting、日志命名、动态 RUN_ID；
- 官方网络瞬时失败：最多两次有界重试，每次保存 rc 和日志；
- Go module/cache 位置适配，不修改 `go.mod/go.sum`；
- Redis 本轮容器的启动等待和清理；
- B patch 仅因上下文偏移导致的 context-only port，必须满足 §5.3。

### 3.4 必须停止的变化

- 为通过测试而改测试名、断言、marker、timeout 或次数；
- 改 B 的条件、`FlushTo` 参数、错误映射或异步边界；
- 修改 upstream `go.mod/go.sum`、跳过 full `pkg/vfs`、使用未知 Redis；
- latest writer 状态机已实质变化，需要重新设计修复；
- 需要 sudo、SSH、生产服务、系统包安装或社区写操作。

---

## 四、测试矩阵与原始证据口径

### 4.1 三项名称与 stock marker

```text
U1=TestFullBlockDispatchedWhenSliceIDBecomesReady
U2=TestPartialBlockNotDispatchedWhenSliceIDBecomesReady
U3=TestFlushErrorRecordedWhenSliceIDBecomesReady
U1_MARKER="full block was not dispatched after slice ID became ready"
U3_MARKER="full block with injected flush error was not dispatched"
```

stock 的 U1/U3 必须各运行 10 个独立 `go test -count=1` 进程；每个 rc 非零、目标
marker 精确一次，且没有 panic、DATA RACE、timeout、build error 或其它失败类别。
U2 单次 rc=0、目标测试精确一个 PASS。

### 4.2 B 与 replay 矩阵

C02 的十个目标名称固定为：

```text
TestC02FullBlockDispatchAfterDelayedID
TestC02MultiBlockDispatchUsesLatestLength
TestC02FlushToFailureIsObservable
TestC02PartialThenFullAfterIDDispatchesOnce
TestC02DelayedNewSliceDoesNotBlockWriteAt
TestC02NonEIONewSliceDoesNotRetryBeforeFlush
TestC02TransientEIORecoversOnFreeze
TestC02PermanentENOSPCAbortsFrozenSlice
TestC02FrozenSliceSkipsCatchupFlush
TestC02ConcurrentIndependentFullBlocks
```

执行前从固定文件机械提取 `^func TestC02` 并证明集合与上表精确相等；合并 regex 必须
由这十个完整名称锚定，禁止使用宽泛 `TestC02.*` 吞入未来新增测试。

| arm | single | count | race | full/quality |
|---|---|---|---|---|
| B-candidate | U1/U2/U3 各一次 | 三项 `-count=100` | 三项 `-race -count=20` | full `pkg/vfs`、gofmt、diff-check、vet、build |
| Q-semantic | C02 十项各一次 | 十项合并 `-count=20` | 十项合并 `-race -count=5` | 只作内部语义门 |
| R-replay | U1/U2/U3 各一次 | 三项 `-count=20` | N/A | 与 B 两文件 diff 逐字一致 |

所有 B/Q/R 命令必须 rc=0，锚定目标测试的 PASS 数与预期次数相等，FAIL=0，且全文
不存在 `DATA RACE`、panic、timeout、`no tests to run`。因此 Q 的预期 PASS 总数分别
为 single=10、count20=200、race5=50。

### 4.3 工具链

先从 frozen main 的 `go.mod`、`go env GOTOOLCHAIN` 和官方 workflow 读取实际要求。
主门只使用执行时 upstream 支持的一套工具链，不预先伪定 Go 版本；记录完整
`go version`、`go env` 和 toolchain 下载日志。若本机无法取得兼容工具链且两次有界
重试仍失败，状态 `BLOCKED-TOOLCHAIN-OR-REDIS`，禁止改 go.mod 规避。

所有 Go test/vet/build 默认使用只读 module 口径（如 `GOFLAGS=-mod=readonly`）；若
upstream workflow 明确使用 vendor，则照其官方模式执行并记录。任何模式都不允许
修改 `go.mod/go.sum`。

### 4.4 简单结果索引，不作 oracle

`$OUT/results.tsv` 精确 12 列：

```text
arm	toolchain	mode	test	expected_outcome	actual_rc	pass_count	fail_count	marker_count	log	sha256	matched
```

- `expected_outcome` 只能是 `PASS` 或 `FAIL_WITH_MARKER`；
- `matched` 只能是 YES/NO；
- `log` 必须是 OUT 内存在且非空的相对路径；
- 每条命令另存 `.rc`；日志不截断、不 grep 后替代原文；
- 表只是导航，Codex 以 raw log/rc 为准。

另生成 `raw-evidence.tsv`：`path,size,sha256,command_id`，覆盖所有测试日志、rc、
patch、diff 和环境文件。

---

## 五、执行步骤

### 步骤 0：通读规则并写 preflight 声明

完整阅读并在 `$CTRL/preflight-review.md` 逐项确认：

1. 本任务书；
2. `community-materials/README.md` 与 `SOURCE-MANIFEST.tsv`；
3. `report/C03-R5-attempt3-execution-20260818-104714.md` 的 Codex 裁定；
4. `prod-deploy/skills/SYSTEM-SAFETY-SKILL.md`；
5. `prod-deploy/skills/LONG-RUNNING-TEST-SKILL.md`；
6. `prod-deploy/skills/TESTING-GUIDE.md` 中与日志、授权、失败保留相关的规则；
7. frozen main 自带 `CONTRIBUTING.md`、go.mod、Makefile 和 unit-test workflow。

明确写出：本轮 fio/drop_caches/layout/cooldown/性能统计均为 N/A，因为 U01 是纯本地
Go 回放；N/A 不能被误写成已通过。

### 步骤 1：授权、环境与输入冻结

1. 保存授权原文及 SHA；记录北京时间、hostname、CPU/内存/磁盘、git/Go/Docker
   版本和只读 seed status。
2. 创建 CTRL/INPUT，复制四项固定业务资产、本任务书和归档说明。
3. 对 INPUT 每个普通文件保存来源、size、mode、mtime_ns、SHA256；冻结为只读。
4. INPUT 之后只读；任一 hash 变化停止。
5. 初始化 `controller-state.tsv`，字段至少为 time/phase/status/action/evidence/next。

### 步骤 2：冻结官方 latest main

1. 在全新 `F-fetch` 中使用 official URL；不修改只读 seed。
2. 保存 fetch 前 `git ls-remote ... refs/heads/main`、clone/fetch 全文和 rc。
3. checkout detached `origin/main`，保存 HEAD、commit show、parents、commit time/title。
4. 再次 ls-remote；若远端 head 在窗口内变化，只允许新建 fetch attempt 再试一次。
5. 最终冻结一个明确 commit，保存 `LATEST_MAIN` 和所有 upstream policy 文件哈希。
6. 保存 `HISTORICAL_MAIN..LATEST_MAIN -- pkg/vfs/writer.go` 的 log/diff/stat，以及
   `git log -S`/`-G` 对 `prepareID`、`SetID`、`FlushTo` 的只读历史搜索。

网络连续失败、official URL/branch 不可验证或 commit 不能读取，停止为
`BLOCKED-AUTH-OR-NETWORK`。

### 步骤 3：创建洁净 arms 与源码守卫

从 frozen object 创建 S/B/Q/R 四个独立 clone/worktree，全部 detached 到同一
`LATEST_MAIN`，禁止 hardlink 工作文件。每臂 before/after 保存：

- HEAD、remote、`git status --porcelain=v2 --untracked-files=all`；
- `pkg/vfs/writer.go` blob SHA；
- changed + untracked path 并集；
- `git diff --binary --full-index` 与 `git diff --check` rc。

先检查三个社区测试名、helper/type/const 名及 C02 十项是否与 latest main 冲突：

- 若 upstream 已存在的 `pkg/vfs/writer_flush_test.go` 与固定测试逐字节相同，记录其
  blob/引入 commit，不再覆盖或重复注入；后续 stock 直接运行 upstream 自带三项；
- 若同名测试/helper 已存在但内容不完全相同，或目标路径已有其它内容，不得覆盖、
  重命名或弱化断言，记录为 `UPSTREAM-ORACLE-DRIFT`；
- 无冲突时才按后续步骤注入固定文件。

这样可以识别“测试已被 upstream 原样接纳”的情形，同时避免把名字相同但语义不同的
测试误当作等价修复。C02 文件若发生冲突也使用相同的“逐字节相同则复用，否则停止”
规则，但 C02 仍只作为内部语义门，不进入社区候选。

### 步骤 4：S-stock 判别

若 frozen main 尚无相同 test blob，只向 S 注入固定 `writer_flush_test.go`；复制后
SHA 必须仍为 `bce85a...`，gofmt 后必须无变化。若已由 upstream 原样包含，则记录其
tracked blob 后直接使用。按 §4.1 运行：

1. baseline compile；
2. U2 single；
3. U1 十个独立进程；
4. U3 十个独立进程。

每个进程单独 log/rc，不允许用一个 `go test -count=10` 冒充独立进程。生成结果行后
立即验证 12 个物理列、日志存在和 SHA。

### 步骤 5：上游分支判定

- 若 stock 精确符合历史目标模式，写 `TARGET-BEHAVIOR-PRESENT`，继续步骤 6。
- 若三项全部稳定 PASS：在 S 上补跑三项 `-count=100` 和 `-race -count=20`，保存
  latest writer diff、候选官方 commit、commit patch 和 ancestry；满足后终态
  `UPSTREAM-ALREADY-FIXED`，禁止应用 B。
- 若为其它组合：保存完整日志和源码差异，终态 `UPSTREAM-ORACLE-DRIFT`；禁止通过
  修改测试继续。

### 步骤 6：B apply 或严格 context-only port

先在 B 上执行固定 writer-only patch 的 `git apply --check`。

- rc=0：标准 apply，并保存两个 rc。
- rc!=0：比较 latest writer 与历史 base。仅当控制流和五条 B 语义都未改变、失败
  纯属行号/上下文变化时，允许生成一次 `async-catchup-latest.patch`：
  1. 保留异步 `go s.prepareID(...)`；
  2. 在真实 writer `SetID(s.id)` 后执行；
  3. 条件仍为正 ID、非 frozen、`slen >= blockSize`；
  4. `FlushTo(int(s.slen))`；
  5. FlushTo error 仍映射 `s.err = syscall.EIO`；
  6. production 只改 `pkg/vfs/writer.go`。

把每条旧/新代码映射写入 `port-adaptations.tsv`。任一语义需重新设计或多改 production
路径，停止为 `B-PATCH-DRIFT`；不得让 GLM自行发明新修复。

若 frozen main 尚无固定社区测试，向 B 注入该文件；若 §3 已证明 upstream blob 完全
相同则直接使用，不重复写入。gofmt 后 test 必须逐字不变，path guard 只能落在
writer.go + test 的允许集合。

### 步骤 7：B 定向、压力与 race

严格执行 §4.2 B 三组矩阵。要求：

- single 三项各 1 PASS；
- count100 精确 300 个目标 PASS；
- race20 精确 60 个目标 PASS，无 DATA RACE；
- 所有 rc=0、无额外 FAIL、panic、timeout 或 no-tests。

任何失败保存现场，状态 `B-TECHNICAL-FAIL`；不得挑选重跑。仅纯网络/module 下载在
测试进程启动前失败可有界重试一次，并保存旧 attempt。

### 步骤 8：Q-semantic 内部语义门

Q 从相同 frozen main 只应用与 B 完全相同的 writer patch，再注入固定 C02 test。
运行十项 single、合并 count20、合并 race5。检查十个名称各自次数，不只看包 rc。

如 C02 test 因 latest API 漂移不能原样编译，允许的适配仅限 fake interface/harness
签名，不得改变测试场景、断言、等待或 production code；适配文件另存并做逐项 diff。
无法证明纯接口适配则 `UPSTREAM-ORACLE-DRIFT`。

### 步骤 9：隔离 Redis、完整 vfs 和最小质量门

1. 确认 `127.0.0.1:6379` 无 listener；占用时停止，禁止使用/清理/杀掉现有服务。
2. 只创建名称与 label 都含 U01 RUN_ID 的 `redis:7.2-alpine` 容器，仅绑定 loopback
   6379，无 host network、privileged、宿主 bind mount。
3. 保存 run rc、CID、image ID/RepoDigest、inspect、PONG、logs、stop/remove 和
   gone 证据。trap 只能操作已登记 CID。
4. full test 前保存 B 的完整 tracked/untracked 快照；在 B 上运行 upstream 实际支持
   工具链的 `go test ./pkg/vfs -count=1`。已知 upstream test 可能在 `pkg/vfs` 生成
   名为 `?_journal=WAL&_timeout=5000&cache=shared` 的 SQLite 临时文件；它不属于候选
   源码。若本轮确实新生成，仅允许在确认 before 不存在、路径是 B clone 内普通文件且
   非 symlink 后，保存相对路径、stat、size、SHA256、file/magic 和 after-status，再
   删除这个**精确文件**并保存 gone 证据。不得 glob、不得删除同名既存文件；出现其它
   新副作用一律 `U01-NON-COMPLIANT`。
5. 运行
   `gofmt -d pkg/vfs/writer.go pkg/vfs/writer_flush_test.go`（输出必须为空）、
   `git diff --check` 和 `go vet ./pkg/vfs`。
6. 运行 upstream Makefile 的标准 Linux `make juicefs`。该 target 会在 B 源码根生成
   `juicefs`：build 前必须证明它不存在；build 后保存 stat/SHA256/file/version，随后
   只删除这个精确的本轮 build 产物并保存 gone。禁止把它写入候选 diff 或证据 archive，
   也禁止在 source guard 中静默忽略。
7. 再次检查 go.mod/go.sum hash、changed+untracked 并集和 `git diff --check`；只允许
   §2.4 的候选路径，两个登记副作用都必须为 gone。
8. full test 结束后停止本轮 Redis，并用精确 name/label 查不到容器证明清理完成。

Redis/工具链无法在授权范围内闭合，状态 `BLOCKED-TOOLCHAIN-OR-REDIS`；不得跳过
full vfs 后写 PASS。

### 步骤 10：生成最新两文件 patch 与 R-replay

1. B path guard 的允许集合仍只有 `writer.go` 和 `writer_flush_test.go`。
2. 从 frozen `LATEST_MAIN` 生成：

```text
$OUT/artifacts/community-candidate-latest.patch
```

通常包含上述两文件；若 §3 已证明 fixed test 是 frozen main 的相同 tracked blob，则
patch 只包含 `writer.go`，并在 meta 中引用 upstream test blob/commit。保存 SHA、stat
和 `git diff --check`。
3. 在完全洁净 R clone 上标准 `git apply --check` + `git apply`，保存 rc。
4. 比较 B/R 的候选路径字节、diff 和 changed/untracked path；必须完全一致。
5. R 执行三项 single 和合并 count20；全部 rc=0、精确 PASS。

历史 patch SHA 只有 writer base blob 未变时才可能仍为 `1050e94...`。SHA 改变本身
不是失败，但必须由 latest base/context 的可解释差异产生。

### 步骤 11：源码收尾与最小社区说明

保存四臂最终 HEAD/status、go.mod/go.sum hash、所有 changed/untracked path。禁止在
源码树留下测试数据库、WAL 或构建产物；§9 的两个临时副作用必须同时保留生成证据与
gone 证据，不能用最终洁净状态掩盖它们曾经出现。

在 OUT 生成而不覆盖归档草稿：

- `draft-update-notes.md`：latest commit、stock/B 分支、实际测试和未运行项；
- `community-claim.txt`：只使用本轮实际支持的最小措辞；
- 明确写“GitHub Actions NOT RUN；未授权社区写入”。

不执行社区写 API；匿名查重留给提交决策阶段，不作为 U01 PASS 门。

### 步骤 12：简单归档与报告

1. 建立唯一 `$OUT/archive-root/`，按相同相对路径复制 frozen input、logs、rc、meta、
   diffs、最终 patch、results/raw-evidence、commands/adaptations、draft 和 transient
   side-effect 证据；禁止放入 `src/` clone、`.git`、Go/module cache、Redis data、构建
   binary、token 或 secret。
2. `raw-evidence.tsv` 的每个 path 在原 OUT 与 archive-root 中都必须存在，size/SHA
   匹配；archive-root 不得漏掉任何支撑判定的 raw log/rc。
3. 在 archive-root 内生成覆盖其中全部普通证据文件的 `SHA256SUMS`（不自包含），并
   实际 `sha256sum -c`，保存检查输出和 rc。
4. tar 只从 archive-root 根创建一次；`tar -tzf` 可读，去掉 `./` 后 member 无重复、
   无绝对路径或 `..`。
5. 保存 archive SHA；不制作复杂 finalizer/oracle，不写自证 `PR-ready`。
6. 写 `$REPORT`，包含全部 attempt、终态、frozen commit、分支、矩阵、raw 路径、
   未运行项和安全声明。

### 步骤 13：测试后 skill 合规复核

报告必须逐项写：

- 未使用 SSH/sudo/fio/mount/Ceph/TiKV/生产 Redis；
- 未修改只读 seed、历史证据或 community-materials 固定输入；
- 只管理并清理本轮 Redis；未 prune、未触碰未知容器；
- 未执行 commit/push/fork/issue/PR/comment；
- fio、drop_caches、layout、compact cooldown、稳态中位数均为 N/A，并说明原因；
- 所有失败/重试现场均保留，没有用报告文字补缺失证据。

---

## 六、`PASS-B-LATEST-MAIN-MINIMAL` 精确准入

以下全部成立才可使用该状态：

1. official main 冻结稳定，commit/来源/历史可复核；
2. stock 精确为 U1/U3 十个独立预期失败、U2 通过，无其它失败类别；
3. B production diff 只改 writer.go，五条语义保持；
4. B 三项 single/count100/race20 全部精确通过；
5. Q 十项 single/count20/race5 全部精确通过；
6. 隔离 Redis 生命周期闭合，B 完整 `pkg/vfs` 通过；
7. gofmt、diff-check、vet、标准 Linux build 通过，go.mod/go.sum 未变；
8. latest 至多两文件 patch 在全新 R 上标准 apply，B/R diff 一致，R single/count20
   通过；若 test 已 upstream 自带，blob/commit 证据完整；
9. results/raw-evidence/log/rc/SHA 可人工复核，源码 path guards 闭合；
10. 没有越权、社区写入或隐瞒 attempt。

任一缺失不得降级措辞为“基本通过”。

---

## 七、交付物

```text
$CTRL/
  authorization.txt
  preflight-review.md
  controller-state.tsv
  environment/

$INPUT/
  taskbook.md
  async-catchup-main.patch
  writer_flush_test.go
  writer_flush_c02_test.go
  historical-community-candidate.patch
  source-manifest.tsv
  input.sha256

$OUT/
  assets/input/
  src/{F-fetch,S-stock,B-candidate,Q-semantic,R-replay}/
  artifacts/community-candidate-latest.patch
  artifacts/transient-side-effects/
  logs/
  rc/
  meta/
  diffs/
  redis/
  results.tsv
  raw-evidence.tsv
  commands.sh
  adaptations.tsv
  draft-update-notes.md
  community-claim.txt
  archive-root/
    SHA256SUMS

$ARCHIVE
$ARCHIVE.sha256
$REPORT
```

禁止把完整 `.git`、Go cache、module cache、二进制、Redis data、token 或 secret 打入
archive。源码工作树保留到 Codex复核，但 archive 只收小型证据。

---

## 八、通用注意事项

1. **原始优先**：报告数字必须指向具体 log/rc/hash；summary/results 不能替代 raw。
2. **失败保留**：测试启动后失败不得原地修改再覆盖；新 attempt 使用新子目录。
3. **输入不变**：固定测试断言、marker、timeout 和次数不可调整。
4. **source guard**：changed 与 untracked 并集必须检查，不能只看 tracked diff。
5. **外部状态**：GitHub main 和查重会变化；必须记录执行时 commit/时间，旧结论不
   自动延续。
6. **性能规则 N/A**：本任务没有 fio、卷、OSD 或性能数值；稳态带宽、drop caches、
   fresh volume、layout、destroy 和 cooldown 均不适用。
7. **授权分层**：工程性脚本/路径问题可修；改变代码语义、测试变量或权限范围前必须
   停止。
8. **凭据**：不得记录 token、cookie、认证 URL、私钥或完整敏感环境变量。
9. **进程清理**：只用精确 PID/CID 管理本轮进程；禁止 pkill/killall/prune。
10. **最终复核**：GLM 只交原始结果和机械状态；Codex复核后才讨论社区提交。

---

## 九、红线汇总

- 禁止把 U01 写成 C03-R6 或复活 R5 harness；
- 禁止修改 `/home/lilingfeng/project/juicefs` 和 community-materials 固定输入；
- 禁止使用 sudo、SSH、fio、mount、Ceph/TiKV、生产服务；
- 禁止使用已有 Redis/6379、停止未知容器或 Docker prune；
- 禁止弱化测试、挑选重跑、删失败日志或默认 PASS；
- 禁止扩大 production diff 超过 writer.go；最终社区 patch 只能是 writer+test 两文件，
  或在 upstream 已含相同 test 时为 writer 单文件；
- 禁止 commit/push/fork/tag/branch 到共享仓库或任何社区写 API；
- 禁止宣称 GitHub CI、真实 v1.3 性能或 PR-ready 已完成。

---

## 十、GLM 最终回复模板

```text
U01 状态：<允许终态之一>
RUN_ID / frozen latest main：
CTRL / INPUT / OUT / archive / report：
固定输入 SHA 核验：
stock：U1/U2/U3 实际结果、独立进程数、raw 路径：
upstream 分支：TARGET-BEHAVIOR-PRESENT / ALREADY-FIXED / ORACLE-DRIFT
B patch：原样 apply / context-only port / drift；最终 SHA：
B community single/count/race：
Q C02 single/count/race：
full pkg/vfs / Redis lifecycle / gofmt / vet / build：
R replay：apply rc、diff cmp、single/count：
所有 attempt、适配和未运行项：
安全与 skill 合规：
声明：未执行 SSH/fio/生产/社区写入，等待 Codex 从 raw log 复核。
```
