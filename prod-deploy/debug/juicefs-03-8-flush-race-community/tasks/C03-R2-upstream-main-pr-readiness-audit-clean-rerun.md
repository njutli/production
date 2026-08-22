# C03-R2：最新 main 社区候选证据链洁净重跑

> 面向执行方：GLM  
> 方案与结果复核：Codex  
> 日期：2026-08-17  
> 性质：C03-R1 审计不合规后的完整洁净重跑；不占 03 阶段性能任务编号  
> 上游：执行时从 `https://github.com/juicedata/juicefs` 重新冻结最新 `main`  
> 主工具链：Go 1.25.7  
> 兼容工具链：本机 Go 1.26.0  
> 工作根：`/home/lilingfeng/tmp`；禁止使用根级 `/tmp/`  
> 核心原则：全新 input、OUT、clone、cache 和工具；执行 runner 必须与校验、归档 runner 是同一个字节流。  
> 禁止：修改或补写任何旧证据、复用旧 PASS、性能测试、生产操作及任何社区写操作。

---

## ⚑ 计划线与本轮唯一任务

~~~text
C01-R1 / C02
  └─ 确定性复现 + 异步 catch-up 候选 + 十项语义/故障/race 覆盖
  ↓
C03
  └─ 技术 PASS；lint 与审计链未闭合
  ↓
C03-R1
  ├─ 技术结果再次全绿，lint/完整 vfs/build 均有有效旁证
  └─ runner 来源错链、若干 gate 非机械判定、archive manifest 不闭合
  ↓
★ C03-R2（你在这里）
  ├─ 动态自定位并冻结唯一执行 runner
  ├─ 在执行时最新 main 上完整重跑 S/B/Q/R
  ├─ 所有 rc、PASS 次数、生命周期和源码守卫机械判定
  ├─ 生成可从归档自身校验的证据包
  └─ 只在 24+1 个硬门全绿时输出 PASS-B-PR-READY-LOCAL
  ↓
  ├─ PASS：交 Codex 做重复性与代码审阅，然后由用户决定 issue/PR
  ├─ UPSTREAM-ALREADY-FIXED：停止 B，转上游修复/backport 分析
  └─ DRIFT/FAIL/NON-COMPLIANT：停止，不进入社区流程
~~~

本轮不是增加新补丁，也不是给 R1 补文件。唯一任务是：在不改变 B 语义和测试资产的前提下，重新产生一条可唯一追溯、可机械复核、可独立解包校验的完整证据链。

---

## 〇、C03-R1 正式复核结论

### 0.1 R1 原始报告与证据

~~~text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R1-execution-20260817-140452.md
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-140452
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-140452-artifacts.tar.gz
~~~

固定参考值：

| 项 | SHA256 |
|---|---|
| C03-R1 任务书 | `1a9e3e46276051d77f6cb61c03bd76fefc5d89e5ac4092187bcb7d347d7ee1df` |
| C03-R1 原始报告 | `92ba37a94f88b98a9d1e036f4230e2465d932bb15d0f404544522984d17c077b` |
| C03-R1 archive | `fa5f17a053feacd1684b405e760ed9ff1e34cfd50ba5e2fb28c3c312710dd0b9` |
| R1 attempt 1 runner | `5499d50a2884d287e6a64202743e9fcbef962338698528c214df122864a13b69` |
| R1 attempt 2 runner | `206cb3390a85f6fad4a8d4cfb0e8a25fff7b72249ce5865f8b36f50657ea8feb` |
| R1 attempt 3 runner | `12c9101bda8914d22f2595eb270699413aea73d881e4c65b19407aa63d9266df` |

### 0.2 R1 可以承接的技术旁证

Codex 对 R1 OUT 做了只读复核，确认以下日志事实真实存在：

1. frozen main `a617e1b016967137de5bdf099cb8b8415cb1d06d` 上，stock U1/U3 稳定命中指定失败，U2 通过；
2. B 社区三项在双工具链下每项精确 `100/100`，race 每项精确 `20/20`；
3. Q 十项在双工具链下每项精确 `100/100`，race 每项精确 `20/20`；
4. 未发现 DATA RACE、panic、timeout 或 no-tests；
5. 双工具链完整 `pkg/vfs`、vet、tidy、Linux/lite build 均有通过日志；
6. golangci-lint v2.6.2 实际运行并输出 `0 issues.`；
7. 最终两文件 patch SHA256 仍为 `1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9`。

这些结果提高了 B 正确的置信度，但只能作为 R2 的历史旁证，禁止复制其 log、rc、cache、src、tools、build 或 gate 作为 R2 结果。

### 0.3 R1 为什么仍不能进入下一阶段

Codex 正式裁定：

~~~text
C03-R1-REVIEWED = TECHNICAL PASS-B / PR-READINESS BLOCKED / AUDIT NON-COMPLIANT
~~~

R2 必须关闭以下缺陷：

1. attempt 2/3 runner 的 `C03_R1_INPUT` 仍硬编码 attempt 1 input；R1 OUT 校验、复制和归档的是 attempt 1 runner，不是报告声称执行的 attempt 3 runner；
2. `commands.sh` 和报告 runner SHA 因此都指向 attempt 1，执行来源无法由 archive 唯一还原；
3. 三个 input 中出现运行期 `runner.pid`/`runner-stdout.log`，破坏“input 冻结后不写入”的边界；
4. B/Q 的 count100/race gate 只检查进程 rc，没有机械检查每个测试的精确 PASS 次数；
5. `git diff --check ... || true`、path guard 后记录 `$?`，得到的是 `true` 的 0；
6. lint gate 未纳入 version rc 和 lint 前后源码一致性；Redis gate 未纳入 inspect/log 的真实 rc；
7. SOURCE 与 C02/C03/R1 历史路径缺少 before/after 清单比对；
8. R1 archive 的 `SHA256SUMS` 包含 archive 中不存在的四个 build，同时 archive 内有两个文件不在 manifest；
9. `sha256-check.rc` 在 `set -e` 后取 `$?`，不是 `sha256sum -c` 的真实 rc；
10. `runtime-adaptations.md` 只有 “Runner started”，归档的 pre-run 文件也不是 attempt 3 的完整修复记录；
11. `required_members` 只检查三个文件名，不能证明归档覆盖全部要求证据；
12. GitHub 搜索成功不等于已判定“不重复”；R1 明确把最终判重留给 Codex。

任务书规定技术测试全绿不能豁免 `NON-COMPLIANT`。因此 R2 必须全新重跑，禁止事后修补 R1 OUT/archive/report。

### 0.4 历史证据保护范围

至少保护以下路径；执行前后必须做递归类型/大小/mtime 清单并逐字节比较：

~~~text
/home/lilingfeng/tmp/juicefs-c03-input-20260817-082552
/home/lilingfeng/tmp/juicefs-c03-20260817-082905
/home/lilingfeng/tmp/juicefs-c03-20260817-084643
/home/lilingfeng/tmp/juicefs-c03-20260817-100609
/home/lilingfeng/tmp/juicefs-c03-20260817-100609-artifacts.tar.gz
/home/lilingfeng/tmp/juicefs-c03-20260817-100609-artifacts.tar.gz.sha256
/home/lilingfeng/tmp/juicefs-c03-r1-input-20260817-111907
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-112439
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-131615
/home/lilingfeng/tmp/juicefs-c03-r1-input-20260817-131459
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-140452
/home/lilingfeng/tmp/juicefs-c03-r1-input-20260817-140321
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-112439-partial-artifacts.tar.gz
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-131615-artifacts.tar.gz
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-131615-artifacts.tar.gz.sha256
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-131615-artifacts.tar.gz.integrity.tsv
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-131615-artifacts.tar.gz.final-status.txt
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-140452-artifacts.tar.gz
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-140452-artifacts.tar.gz.sha256
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-140452-artifacts.tar.gz.integrity.tsv
/home/lilingfeng/tmp/juicefs-c03-r1-20260817-140452-artifacts.tar.gz.final-status.txt
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C02-main-flush-dispatch-semantics-fault-injection.md
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C03-upstream-main-community-ci-readiness.md
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C03-R1-upstream-main-community-ci-clean-rerun.md
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C02-execution-20260817-015425.md
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-execution-20260817-100609.md
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R1-execution-20260817-140452.md
~~~

若某个列出的路径执行前已不存在，只记录 `MISSING_BEFORE`，不得创建它；若执行后状态变化，`source_asset_guards=NO`。

---

## 一、目标、分支与状态机

### 1.1 Q0：执行时最新官方 main 是否仍受影响

从官方 remote 稳定冻结一个精确 `UPSTREAM_COMMIT`：

| 观察 | 状态 | 动作 |
|---|---|---|
| U1/U3 指定 marker FAIL，U2 PASS | `UPSTREAM-AFFECTED` | 继续 S/B/Q/R 完整矩阵 |
| U1/U2/U3 均 PASS，且源码存在等价 catch-up | `UPSTREAM-ALREADY-FIXED` | 禁止应用 B；保存可能修复提交后早停 |
| 测试表现与上述两类不一致 | `UPSTREAM-ORACLE-DRIFT` | 早停，交 Codex |
| B 无法标准 apply 或 writer 语义变化 | `B-PATCH-DRIFT` | 早停；禁止 GLM 自行 rebase |
| 官方 Go/lint/build 口径变化 | `CI-MATRIX-DRIFT` | 早停；禁止替换工具版本 |
| C02 base 不再是 main 祖先 | `UPSTREAM-HISTORY-DIVERGED` | 早停 |

### 1.2 Q1：B 是否完整修复且不改变既定语义

必须重新证明：

- stock 正控红、负控绿；
- B 社区三项单项、count100、race20 全绿且次数精确；
- Q 十项单项、count100、race20 全绿且次数精确；
- 双工具链完整 `pkg/vfs` 全绿；
- B/R patch 和源码逐字节一致；
- B 保留异步 `NewSlice`、partial/frozen/error/non-EIO/并发语义。

### 1.3 Q2：本地社区门禁是否闭合

必须实际执行并纳入 gate：

- gofmt、license、`git diff --check`；
- 双工具链 tidy 且 go.mod/go.sum 不变；
- 双工具链 `go vet ./pkg/vfs`；
- frozen main 官方口径的 golangci-lint v2.6 系列全仓 lint；
- 双工具链 Linux/lite build、version rc、revision、文件 hash 和复制一致性；
- Redis 完整生命周期；
- GitHub 只读搜索和本地 history 搜索。

### 1.4 Q3：执行证据能否独立还原

必须同时证明：

- 实际执行 runner、input manifest、OUT 归档 runner 三者 hash 相同；
- input 全程无新增、删除、内容或 stat 变化；
- 所有命令 rc 在命令结束后立即捕获；
- 所有 gate 由明确证据机械计算且只解析一次；
- archive 解包后，成员集合与 manifest 完全一致，内部 SHA 校验通过；
- SOURCE 和历史证据前后未变。

### 1.5 唯一成功状态

只有 24 个 candidate gate 全部 `YES`，且 archive integrity 终态门全部 `YES`，才允许外部终态 sidecar 写：

~~~text
PASS-B-PR-READY-LOCAL
~~~

该状态仅表示“可交 Codex 做重复性与代码审阅”。它不表示 GitHub Actions 已运行，不授权 GLM 创建 issue/PR，也不保证社区会接受方案。

### 1.6 明确不做

- 不运行 fio、benchmark、性能 AB、mount、fio verify 或 soak；
- 不访问生产 Redis/Ceph/TiKV/S3，不修改生产部署和二进制；
- 不修改 v1.3.1 或生产 patch；
- 不执行完整多服务 `make test.pkg`；
- 不使用 sudo，不安装系统包；
- 不执行 Windows/Ceph/FDB build；
- 不 commit、push、fork、创建分支或 tag；
- 不创建、评论、编辑或关闭 issue/PR；
- 不使用 GitHub token、cookie、Authorization header；
- 不删除任何 C03/C03-R1/R2 失败现场。

---

## 二、固定输入、动态量、测试矩阵与硬门

### 2.1 固定资产

| 项 | 固定值 |
|---|---|
| 官方 remote | `https://github.com/juicedata/juicefs` |
| 只读 SOURCE | `/home/lilingfeng/project/juicefs`；只可作为对象种子 |
| C02 base | `edabf9c24601510476e7453abff177f4aaca07ac` |
| C03/R1 参考 main | `a617e1b016967137de5bdf099cb8b8415cb1d06d`；不得冒充执行时最新 main |
| B 生产 patch SHA256 | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` |
| 社区测试 SHA256 | `bce85ad4abf92a47074849a544aaa756963fb44a1839619bbc71c5d7ce1fe9bc` |
| C02 内部测试 SHA256 | `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` |
| 参考社区 patch SHA256 | `1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9` |
| 主工具链 | `GOTOOLCHAIN=go1.25.7` |
| 兼容工具链 | `GOTOOLCHAIN=local`，必须精确为 Go 1.26.0 |
| Redis | `redis:7.2-alpine`，执行时记录 image ID 和 RepoDigest |
| 工作根 | `/home/lilingfeng/tmp` |

三个固定资产只能从下列 C03 只读路径复制：

~~~text
/home/lilingfeng/tmp/juicefs-c03-20260817-100609/assets/writer_flush_test.go
/home/lilingfeng/tmp/juicefs-c03-20260817-100609/assets/writer_flush_c02_test.go
/home/lilingfeng/tmp/juicefs-c03-20260817-100609/assets/async-catchup-main.patch
~~~

复制后必须先校验固定 SHA；不匹配立即停止，不得从 R1 OUT 任选一个“看起来一样”的版本替代。

### 2.2 R2 input 精确成员

新 input 命名：

~~~text
/home/lilingfeng/tmp/juicefs-c03-r2-input-YYYYmmdd-HHMMSS/
~~~

只能包含以下文件，不得在运行时加入 PID、stdout 或临时文件：

~~~text
launch-c03-r2.sh
run-c03-r2.sh
taskbook.md
writer_flush_test.go
writer_flush_c02_test.go
async-catchup-main.patch
pre-run-adaptations.md
runner-static-review.txt
anchors.expected
forbidden-runtime-patterns.txt
community-secret-patterns.txt
protected-paths.txt
input.expected-files
input.stat.tsv
input.sha256
~~~

要求：

1. `input.expected-files` 与目录普通文件 basename 排序后精确相等；
2. `input.sha256` 覆盖除自身外的全部文件；
3. 先把除 manifest 外的业务输入设为最终只读 mode，再生成 `input.stat.tsv`；该表记录这些文件的 mode、uid、gid、size、mtime_ns，但不记录自身和稍后生成的 `input.sha256`；
4. 生成 manifest 后再把 `input.stat.tsv`、`input.sha256` 和目录设为不可写；
5. launcher 启动时间晚于最后一个 input 文件 mtime，runner 只能由该 launcher 随后启动；
6. 启动器 stdout、PID、rc 和 launch log 必须写在 input 外部。

### 2.3 执行时动态冻结量

源码测试前必须落盘：

| 量 | 数据源 |
|---|---|
| runner realpath/hash/input root | `meta/executed-runner.tsv` |
| input 启动/结束校验 | `meta/input-check-{start,end}.*` |
| main 前后 ref/FETCH_HEAD | `meta/upstream-freeze-attempts.tsv`、`meta/ls-remote-*` |
| commit show/祖先/距离 | `meta/upstream-*` |
| writer blob/history/diff | `meta/upstream-writer-*`、`diffs/` |
| 官方 Go/lint/build 口径 | `meta/upstream-policy/`、`meta/upstream-ci-matrix.tsv` |
| Go 工具链 | `meta/TOOL-go-version.txt`、`meta/TOOL-go-env.txt` |
| lint 版本与二进制 | `meta/lint-*` |
| Redis image/container | `meta/redis-*`、`logs/redis-*` |
| SOURCE/history 保护 | `meta/protected-{before,after}.tsv` |

冻结 main 后不得再次 fetch。remote 在冻结窗口变化时，最多进行三个有编号的 freeze attempt；每次保留 ref、时间、rc 和日志，最终只能选一个三点一致的 commit。

### 2.4 四臂

| 臂 | 内容 | 唯一允许变化 |
|---|---|---|
| S-oracle | frozen main + 社区测试 | `pkg/vfs/writer_flush_test.go` |
| B-candidate | frozen main + B + 社区测试 | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |
| Q-semantic | frozen main + B + C02 内部测试 | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_c02_test.go` |
| R-replay | frozen main + 本轮导出 patch | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |

全部使用独立 `git clone --no-hardlinks`、独立 index 和独立 GOCACHE。禁止 worktree、hardlink、复制旧 clone 或复制构建缓存。

### 2.5 社区三项矩阵

| ID | 测试 | S-oracle | B/R |
|---|---|---|---|
| U1 | `TestFullBlockDispatchedWhenSliceIDBecomesReady` | 指定 marker FAIL | PASS |
| U2 | `TestPartialBlockNotDispatchedWhenSliceIDBecomesReady` | PASS | PASS |
| U3 | `TestFlushErrorRecordedWhenSliceIDBecomesReady` | 指定 marker FAIL | PASS |

stock 指定 marker：

~~~text
U1: full block was not dispatched after slice ID became ready
U3: full block with injected flush error was not dispatched
~~~

矩阵：

- S：双工具链 U1/U2/U3 单项；U1/U3 再各跑 10 个独立进程；
- B：双工具链三项单项、三项合跑 count100、三项合跑 race count20；
- R：双工具链三项单项、三项合跑 count20。

### 2.6 C02 十项语义矩阵

~~~text
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
~~~

双工具链分别运行：十项单项各一次、十项合跑 count100、十项合跑 race count20。

### 2.7 精确计数结果表

runner 必须生成下列 TSV；gate 只能从这些 TSV 计算，不能只看 `go test` rc：

~~~text
meta/stock-results.tsv
meta/community-results.tsv
meta/semantic-results.tsv
meta/replay-results.tsv
~~~

统一字段至少为：

~~~text
arm tool mode test expected_rc actual_rc expected_run expected_pass actual_run actual_pass marker_count bad_marker_count status log
~~~

精确行数与期望：

| 表/模式 | 数据行 | 每行期望 |
|---|---:|---|
| stock single | 6 | U1/U3 rc 非零且 marker=1；U2 rc=0/PASS=1 |
| stock repeat10 | 40 | 每个独立进程对应一行，rc 非零、marker=1 |
| B single | 6 | run=1、pass=1、rc=0 |
| B count100 | 6 | run=100、pass=100、rc=0 |
| B race20 | 6 | run=20、pass=20、rc=0、bad=0 |
| Q single | 20 | run=1、pass=1、rc=0 |
| Q count100 | 20 | run=100、pass=100、rc=0 |
| Q race20 | 20 | run=20、pass=20、rc=0、bad=0 |
| R single | 6 | run=1、pass=1、rc=0 |
| R count20 | 6 | run=20、pass=20、rc=0 |

bad marker 至少覆盖：DATA RACE、panic、test timed out、no tests to run、build failed、unexpected package FAIL。stock 的预期目标 FAIL 只能由指定 marker 白名单解释，其他 FAIL 一律 bad。

### 2.8 Candidate required gates

`candidate-gates.tsv` 必须且只能含以下 24 项，顺序固定：

~~~text
input_integrity
upstream_freeze
upstream_policy_ci
upstream_stock_oracle
B_standard_apply
B_community_single
B_community_count100
B_community_race20
Q_semantic_single
Q_semantic_count100
Q_semantic_race20
B_full_vfs
redis_lifecycle
B_gofmt_diff_license
B_tidy
B_vet
B_lint
B_linux_build
B_lite_build
patch_replay
community_search
community_drafts_secret_scan
source_asset_guards
execution_audit
~~~

archive integrity 是第 25 个终态门，必须在 archive 建成后于 archive 外计算，不得放进 `candidate-gates.tsv`。

官方 Windows/Ceph/FDB build 和 GitHub Actions 固定写入 `deferred-checks.tsv` 为 `NOT_RUN_BY_DESIGN`，不得混入 required gates。

---

## 三、不可变执行与 runner 实现硬约束

### 3.1 唯一 launcher/runner 与禁止硬编码 input 路径

launcher 与 runner 都必须从自身解析 input。runner 参考形态：

~~~bash
RUNNER_REAL=$(readlink -f -- "${BASH_SOURCE[0]}")
INPUT_DIR=$(dirname -- "$RUNNER_REAL")
test "$(basename -- "$RUNNER_REAL")" = run-c03-r2.sh
~~~

runner 中禁止出现任何带时间戳的 `juicefs-c03-r2-input-*` 绝对路径变量，也禁止引用 R1 input。必须在起始阶段保存并机械验证：

~~~text
executed_launcher_realpath
executed_launcher_sha256
executed_runner_realpath
executed_runner_sha256
input_manifest_launcher_sha256
input_manifest_runner_sha256
archived_launcher_sha256
archived_runner_sha256
launcher_cmp_rc
runner_cmp_rc
~~~

launcher 的三份 hash/runner 的三份 hash 必须各自一致，两个 cmp 都必须为 0；否则 `input_integrity=NO` 且最终 `NON-COMPLIANT`。

### 3.2 RUN_ID、OUT 和前台启动

启动前由 GLM 生成唯一 `RUN_ID=YYYYmmdd-HHMMSS`，并确认以下路径都不存在：

~~~text
/home/lilingfeng/tmp/juicefs-c03-r2-$RUN_ID
/home/lilingfeng/tmp/juicefs-c03-r2-$RUN_ID-artifacts.tar.gz
/home/lilingfeng/tmp/juicefs-c03-r2-$RUN_ID.launch.log
~~~

唯一入口是冻结的 `launch-c03-r2.sh`。launcher 只接受一个 RUN_ID 参数，动态定位同目录 runner，严格验证格式，并据此派生 OUT/archive/launch 路径。它以前台方式在 `if` 中调用 runner，把 stdout/stderr 写到 input 外部的 launch log，并立即捕获 runner 真 rc；禁止管道吞 rc，禁止向 input 写 PID 或 log。

runner 在 OUT 中写 `commands.sh`、完整 xtrace 和逐命令日志，但只能写 archive candidate/provisional 状态，不能预写最终 PASS。runner 退出后，launcher 写外部 `.runner.rc`、launch log SHA，并把这两项加入 terminal integrity；只有 runner rc=0 且 runner 产出的全部 integrity 项为 YES，launcher 才写最终 `.final-status.txt`。

### 3.3 input 起止双检

runner 开始时与所有工作结束、PACKAGE 前各执行一次：

1. 实际文件名集合与 `input.expected-files` 精确比较；
2. 从 input 根运行 `sha256sum -c input.sha256` 并立即保存真实 rc；
3. 另存 `input.sha256` 和 `input.stat.tsv` 自身的启动 SHA，结束时逐字节比较；
4. 按 `input.stat.tsv` 重建 stat 清单并 `cmp`；
5. 确认 input 内无可写普通文件、无新目录、PID、stdout、swap、tmp；
6. 将全部 input 文件复制到 `OUT/assets/input/`，比较文件集合与逐文件 hash；
7. 特别比较 `$RUNNER_REAL` 与归档 runner。

`input_integrity` 只能在结束双检后解析一次，不能在启动检查通过时提前写 YES。

### 3.4 runner 静态审查

冻结 input 前，`runner-static-review.txt` 必须包含命令、输出摘要和 rc，而不是只写 YES。至少验证：

1. `bash -n` rc=0；
2. 启用 `set -Eeuo pipefail` 和 `umask 077`；
3. launcher/runner 都由 `${BASH_SOURCE[0]}` 动态解析 input，无旧 input 或时间戳 input 硬编码；
4. 所有 24 gate 初始化为 `NOT_RUN`，没有默认 PASS；
5. gate 名单、顺序、数量与 §2.8 精确一致；
6. gate 只能从 `NOT_RUN` 解析一次为 YES/NO，二次解析立即 fatal；
7. 测试 gate 包含逐测试 run/PASS 精确计数，不只检查 rc；
8. 所有 rc 由 `if command; then rc=0; else rc=$?; fi` 或等价形式立即捕获；
9. 不存在 `command || true` 后记录 `$?` 的模式；
10. lint gate 检查 query/install/version/run rc、版本、binary SHA 和源码前后一致；
11. Redis gate 检查 pull/run/PONG/inspect/log/stop/gone 的独立 rc；
12. build gate 检查 make/version/copy/hash/revision；
13. SOURCE/history before/after guard 存在；
14. archive manifest 不包含被排除的 src/cache/tools/builds；
15. archive 外解包校验与成员覆盖检查存在；
16. launcher 正确捕获 runner rc，且 runner 不能在退出前写最终 PASS；
17. 无 sudo、生产命令、commit/push、GitHub 写 API、prune、`rm -rf`；
18. `input.sha256` 自检通过，三个固定资产 hash 正确；
19. `pre-run-adaptations.md` 包含 R1 三个 runner 精确 SHA 和全部缺陷。

静态审查发现任何问题时不得启动 runner；修改后重新生成全新 input、manifest 和 review。

### 3.5 rc 捕获规范

推荐统一 helper：

~~~bash
if command ... >"$log" 2>&1; then
  rc=0
else
  rc=$?
fi
printf '%s\n' "$rc" >"$rc_file"
~~~

helper 不得向启用 errexit 的调用者返回测试 rc；可把 rc 写入只读结果变量或文件并自身返回 0。预期失败也必须用同一规则捕获。

以下写法一律禁止：

~~~bash
command ... || true
printf '%s\n' "$?" > command.rc
~~~

搜索无命中、diff 不同、容器不存在等“非零也是数据”的命令，同样必须捕获原始 rc，再由明确判据解释。

### 3.6 gate 状态模型

使用固定顺序数组和关联数组：

- 初始化时保存 `meta/candidate-gates.initial.tsv`，24 项全部 `NOT_RUN`；
- `resolve_gate NAME YES|NO EVIDENCE` 只允许调用一次；
- 每项记录解析次数、解析时间和证据路径；
- 正常完整分支结束时必须 24 行、24 个唯一名称、24 次解析、无未知项；
- 任何 `NO/NOT_RUN/PENDING/SKIP/N/A` 都不得进入 PASS；
- `candidate-gates.tsv` 只在所有 candidate evidence 冻结后一次性输出；
- final status 必须遍历全表，不得写“步骤走到末尾即 PASS”。

### 3.7 anchors 与 xtrace

`anchors.expected` 固定为：

~~~text
C03R2_ANCHOR:INIT
C03R2_ANCHOR:PROTECT_SNAPSHOT
C03R2_ANCHOR:FETCH
C03R2_ANCHOR:STOCK_ORACLE
C03R2_ANCHOR:APPLY_B
C03R2_ANCHOR:SEMANTIC
C03R2_ANCHOR:FULL_VFS
C03R2_ANCHOR:LINT_BUILD
C03R2_ANCHOR:REPLAY
C03R2_ANCHOR:COMMUNITY_SEARCH
C03R2_ANCHOR:SOURCE_GUARD
C03R2_ANCHOR:AUDIT
C03R2_ANCHOR:PACKAGE
~~~

`record_anchor` 每次只向 `meta/anchors.actual` 追加一次。完成所有工作与审计后记录 PACKAGE，关闭 xtrace，再用 `cmp` 和行数/唯一性三重检查。禁止 grep xtrace 推断 anchor。

### 3.8 adaptations 与失败重试

`pre-run-adaptations.md` 必须明确记录 C03、C03-R1 三次 attempt 的 input、OUT、失败步骤、旧/新 runner SHA、修改内容和本轮设计修复。

`runtime-adaptations.tsv` 初始化为：

~~~text
timestamp\ttype\tdetail\tevidence
<start>\tNONE_AFTER_START\tno runtime adaptation yet\t-
~~~

发生预注册重试时删除 NONE 行并逐项追加真实事件。禁止写 “runner started” 冒充 adaptation。

若 R2 runner 自身有 bug、需要修改控制变量或出现未预注册适配：

1. 当前 OUT 立即以明确失败状态结束；
2. trap 只清理本轮 Redis，生成 partial archive；
3. 不补跑、不改当前 input/OUT；
4. 新建带新时间戳的 input 和 OUT；
5. pre-run 文件列出旧/新 runner 精确 SHA；
6. 所有旧 input、OUT、partial archive 完整保留。

### 3.9 Docker 与安全边界

- 先证明宿主 loopback 6379 未监听；占用即早停；
- 只管理 name 和 label 都含本轮 RUN_ID 的精确 container ID；
- 使用 `--rm`、loopback 端口、tmpfs data、非 privileged、非 host network、无宿主 bind；
- trap 只能 stop 已登记的本轮 container ID；
- 禁止 stop/kill/rm 其他容器，禁止 prune；
- 禁止已有 Redis、flushdb、flushall；
- 禁止 sudo、mount、fio、Ceph/TiKV/S3 和生产路径写入。

---

## 四、执行步骤

### 步骤 0：阅读、输入制作与静态门

完整阅读：

1. 本任务书；
2. C03-R1 任务书和原始报告；
3. C03/C02 报告及已有 Codex 复核结论；
4. `prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` 中安全、失败保留和证据唯一性要求；
5. `prod-deploy/skills/SYSTEM-SAFETY-SKILL.md`；
6. frozen main 的 CONTRIBUTING、Go/lint/unit/build workflow、`.golangci.yml`、go.mod 和 Makefile。

从 §2.1 固定路径复制资产，制作 §2.2 的全新 input，完成 §3.4 静态审查后冻结。不得先启动再补 review 或 adaptations。

### 步骤 1：前台启动、唯一 runner 与起始 input 门

按 §3.2 使用唯一 launcher 前台启动。runner 首先：

1. 解析自己的 realpath 与 INPUT_DIR；
2. 验证 launcher/runner 来源，以及 RUN_ID、OUT/archive/launch 路径此前不存在；
3. 创建唯一 OUT 和固定目录结构；
4. 完成 input start 双检并复制 input 到 `assets/input/`；
5. 写 `meta/executed-chain.tsv` 和 `commands.sh`；
6. 初始化 24 个 NOT_RUN gate；
7. 建立只处理本轮 Redis 的 trap；
8. 打开 xtrace，记录 INIT。

任一 runner/input hash 不一致立即 `NON-COMPLIANT`，不得继续测试。

### 步骤 2：SOURCE 与历史路径 before 快照

记录 PROTECT_SNAPSHOT anchor。对 SOURCE 保存：

~~~text
HEAD
git status --porcelain=v2 --untracked-files=all
git remote -v
git config --local --list --show-origin
refs/heads 与 refs/remotes 摘要
根目录关键文件 stat
~~~

对 `protected-paths.txt` 每一路径递归生成稳定 TSV：path、type、mode、uid、gid、size、mtime_ns、link_target。排序保存为 `meta/protected-before.tsv` 并计算 SHA256。

只记录 mtime，不记录 atime，避免读取造成自变化。不得用 SOURCE 直接 fetch；后续网络操作全部在隔离 clone。

### 步骤 3：稳定冻结官方 main 与政策口径

使用 SOURCE 创建不含 hardlink 的隔离 fetch clone，将隔离 clone origin 设为官方 URL。每次 freeze attempt 保存：

1. 开始时间；
2. fetch 前 `ls-remote refs/heads/main` 与 rc；
3. `git fetch --no-tags origin main` log/rc；
4. FETCH_HEAD；
5. fetch 后 `ls-remote` 与 rc；
6. 三个 commit 是否一致。

不一致时最多重建隔离 fetch clone再试两次，禁止在同一 clone 叠加不明状态。稳定后记录 commit show、parents、时间、title、C02/C03 ancestry/distance、writer.go blob 与路径 history。

冻结以下官方文件及 SHA：

~~~text
CONTRIBUTING.md
.github/workflows/verify.yml
.github/workflows/unittests.yml
.github/actions/build/action.yml
.golangci.yml
go.mod
go.sum
Makefile
~~~

机械解析 Go directive、CI Go matrix、lint 系列和 build 命令。若不再是预注册的 Go 1.25/1.26 与 lint v2.6 口径，状态 `CI-MATRIX-DRIFT`，不得自行换版本继续。

### 步骤 4：建立四臂、工具链与静态冲突门

从 frozen commit 创建四个独立 no-hardlinks clone，全部 detached 到同一 commit，保存 before HEAD/status/object alternates 状态。

检查：

- 社区/C02 测试文件路径和所有测试/helper 名不存在冲突；
- latest writer.go 与 C03 reference diff、blob 和相关历史；
- B patch 仅预期修改 writer.go；
- 两工具链版本精确；
- 每工具链独立空 GOCACHE，本轮共享但初始为空的 GOMODCACHE；
- baseline compile 与既有四项小基线双工具链通过。

冲突、工具链或 baseline 失败均早停，不得改测试名或换版本。

### 步骤 5：S-oracle 与 upstream 分支

将固定社区测试注入 S 并再次核验 SHA。双工具链执行 §2.5 S 矩阵，所有命令各自保存 log/rc。

生成 46 行 `stock-results.tsv`，机械检查：

- U2 两行均唯一 PASS；
- U1/U3 四个 single 和 40 个 repeat 均为预期非零 rc；
- 每个 U1/U3 日志指定 marker 精确出现一次；
- 没有其他失败类别；
- 重复测试确实是 40 个独立 `go test` 进程，而不是单进程 count10。

由表计算 upstream 状态。若已修复，必须同时保存源码等价逻辑和 `git log -S/-G` 候选；之后早停，禁止应用 B。

### 步骤 6：B 标准 apply 与社区矩阵

仅 `UPSTREAM-AFFECTED` 继续。依次执行并捕获真实 rc：

~~~text
git apply --check async-catchup-main.patch
git apply async-catchup-main.patch
gofmt writer.go
复制并核验 writer_flush_test.go
git diff --check
~~~

禁止 `--recount`、`--3way`、`--reject`、patch 工具自动修复或手工编辑。

双工具链运行 B 全矩阵。生成 `community-results.tsv`，必须精确满足 6/6/6 行和 1/100/20 次门；每个日志的 `=== RUN` 与 `--- PASS:` 都要按目标测试分别计数。rc=0 但次数不对仍为 NO。

### 步骤 7：Q 十项语义矩阵

Q 独立标准应用同一 B，复制固定 C02 测试并核验 SHA。禁止忽略 apply/check rc。

双工具链完成十项单项、count100、race20，生成 `semantic-results.tsv`，精确满足 20/20/20 行和 1/100/20 次门。C02 内部测试只能存在于 Q，不得进入 B、R 或最终 patch。

### 步骤 8：完整 pkg/vfs 与 Redis 生命周期

保存 Docker version/context。执行 Redis image pull/inspect，并分别捕获真实 rc；冻结 image ID/RepoDigest。

每个工具链使用独立新容器，生成 `meta/redis-lifecycle.tsv`，至少包含：

~~~text
tool step expected_rc actual_rc content_check status evidence
~~~

步骤必须覆盖：port-free、run、ID/name/label、PONG 有界轮询、pre-test inspect、pre-test logs、网络/privileged/bind/tmpfs 检查、完整 vfs、post-test logs、stop、预期 inspect 不存在、docker ps 不存在、port-free-after。

inspect/log 即使文件非空也必须 rc=0；不能用 `|| true` 代替。完整 vfs 日志必须 rc=0、有最终 package PASS、无 panic/timeout/no-tests/DATA RACE。

任一步失败：对应 gate=NO，仍执行精确容器清理和证据封存，但禁止挑选重跑。

### 步骤 9：gofmt、license、diff、tidy、vet

在 B-candidate：

1. gofmt diff rc=0 且输出空；
2. 测试文件 license header 与固定资产一致；
3. `git diff --check` 真实 rc=0；
4. 最终两个允许路径内容/hash 正确；
5. 双工具链分别运行 tidy，命令 rc=0，go.mod/go.sum 前后 SHA 完全一致；
6. 每次 tidy 后 status 与之前一致；
7. 双工具链 `go vet ./pkg/vfs` rc=0。

所有 diff/cmp 都必须保存原始 rc。不得以空 log 替代 rc，也不得在一个工具链改变文件后继续第二个工具链掩盖变化。

### 步骤 10：官方 v2.6 系列全仓 lint

从 frozen policy 解析 lint 系列；保存 `go list -m -versions` 的真实 rc 和原文，选择最高稳定 `v2.6.x`。只安装到 `$OUT/tools/bin`。

`B_lint=YES` 必须同时满足：

- version query rc=0；
- 选择结果精确匹配 `^v2\.6\.[0-9]+$`；
- install rc=0；
- version command rc=0，输出版本与选择一致；
- binary 与 `.golangci.yml` SHA 已保存；
- 从仓库根、Go 1.25.7 运行全仓 `golangci-lint run` rc=0；
- lint 前后 HEAD、status、tracked diff、go.mod/go.sum hash 全部一致；
- lint log 无 timeout、panic 或隐藏错误。

任何一项失败都不得写 B_lint YES。网络/安装问题为 `LINT-INFRA-BLOCKED`，实际 finding 为 `LINT-FAIL`。

### 步骤 11：双工具链 Linux/lite build

每个工具链依次执行并独立捕获：

~~~text
make -B juicefs
./juicefs version
sha256sum ./juicefs
copy to builds/TOOL/juicefs
cmp/hash source and copy
make -B juicefs.lite
./juicefs.lite version
sha256sum ./juicefs.lite
copy to builds/TOOL/juicefs.lite
cmp/hash source and copy
~~~

build gate 不仅检查 make rc，还要检查 version rc=0、输出含 frozen commit revision、文件非空可执行、hash 存在且复制一致。四个大二进制留在 OUT，不进入 archive；archive 只含版本、size、hash 和 retained path 表。

### 步骤 12：最终 patch 与 R-replay

导出前机械确认：

- B HEAD 等于 frozen commit；
- changed paths 精确为 writer.go 与社区测试；
- go.mod/go.sum/vendor 不变；
- 社区测试 hash 正确；
- Q 内部测试不在 B。

最终 patch 只含：

~~~text
pkg/vfs/writer.go
pkg/vfs/writer_flush_test.go
~~~

R 必须在导出前保持全净，然后执行标准 apply check/apply。要求 B/R full diff、writer.go、测试、changed paths 逐字节一致。双工具链完成 R 单项和 count20，生成 6+6 行 replay 表并验证精确次数。

若 frozen writer base blob 与 C03/R1 相同，最终 patch SHA 必须等于参考 `1050e94f...`；否则只能在标准 apply 成功且保存 base diff 后交 Codex，GLM 不得自行解释为等价。

### 步骤 13：只读社区查重

重新执行六组匿名查询：

~~~text
repo:juicedata/juicefs is:issue prepareID FlushTo
repo:juicedata/juicefs is:pr prepareID FlushTo
repo:juicedata/juicefs is:issue "slice ID" writer flush
repo:juicedata/juicefs is:pr "full block" FlushTo
repo:juicedata/juicefs is:issue random write flush block
repo:juicedata/juicefs is:pr random write flush block
~~~

每组保存 request、started-at、headers、HTTP status、body JSON、curl rc 和 JSON validation。要求匿名、HTTP 200、curl rc=0、rate-limit header 存在、JSON 可解析且字段完整。

同时保存 frozen repo 的 path log、`git log -S/-G/--grep`。生成 candidates.tsv 和 `duplicate-review-status.txt=DEFERRED_TO_CODEX`。

`community_search=YES` 只表示证据采集成功，绝不能写成“已证明无重复”。

### 步骤 14：社区草稿与真实性/脱敏门

生成 issue、PR、commit-message 草稿，填入真实 frozen commit、工具链和本轮实际 gate，不留“提交时再填”一类占位项。

草稿必须明确：

- main 上观察的是具体漏派发行为；
- B 保留异步 NewSlice，只在 ID 到达后补派发完整 block；
- partial/frozen/error 等边界；
- 实际运行的本地测试；
- GitHub Actions/Windows/Ceph/FDB 尚未运行；
- 不把该行为夸大为所有随机写性能或数据损坏的唯一原因。

使用独立冻结的 `community-secret-patterns.txt` 扫描最终 patch、社区测试和三份草稿。扫描命令捕获真实 rc，并区分“无命中 rc=1”与执行错误。任何内部路径、IP、凭据、项目代号或模型名称命中均为 NO；禁止在同一 OUT 静默修改后重扫。

### 步骤 15：四臂、SOURCE、历史与 input 结束守卫

记录 SOURCE_GUARD anchor。机械验证：

- 四臂 HEAD 全等于 frozen commit；
- before/after HEAD 与 status 关系符合预注册变化；
- 每臂 changed paths 精确匹配 §2.4；
- 所有 `git diff --check` 真实 rc=0；
- B/R writer.go、社区测试、full diff 逐字节一致；
- B/Q/R writer.go 一致；
- Q 内部测试不进入最终 patch；
- go.mod/go.sum/vendor 无变化；
- 固定测试资产在每臂 hash 正确；
- SOURCE HEAD/status/remotes/config/refs 与 before 精确一致；
- `protected-after.tsv` 与 before 精确一致；
- input 文件集合、SHA、stat、权限和 archived copy 与 start 精确一致。

每个 diff/cmp 都保存自身真实 rc。所有条件共同决定 `source_asset_guards` 与 `input_integrity`。

### 步骤 16：执行审计、全门计算与候选冻结

先记录 AUDIT anchor，完成：

1. runtime forbidden audit；
2. adaptations 真实性；
3. commands/xtrace/runner 来源检查；
4. 结果 TSV 行数、唯一性和状态复算；
5. 24 gate 名单/解析次数检查；
6. 所有 evidence 路径存在性、文件类型和非空规则检查；
7. 无旧 OUT/cache/src/tools/build 被引用为本轮结果；
8. 无社区写操作；
9. 无生产、fio、mount、sudo、prune 或越界 Docker 操作。

forbidden pattern 必须从外置文件读取，命令行不展开模式。禁止通过删除所有匹配审计命令的行来宽泛放行；任何 allowlist 必须按精确命令结构预注册并写入说明。

完成审计后记录 PACKAGE anchor并关闭 xtrace。再执行 anchors 的 exact cmp、13 行计数和唯一性检查。之后解析 `execution_audit`，一次性输出 `candidate-gates.tsv`。

全表算法必须同时检查：

- 表头精确；
- 数据行精确为 24；
- 名称、顺序与固定清单一致；
- 每项唯一且解析次数为 1；
- status 只能 YES/NO；
- 24 项全部 YES 才写 `meta/prearchive-status.txt=ALL-REQUIRED-GATES-YES`。

---

## 五、可自校验 archive 协议

### 5.1 payload 边界

archive 只包含已冻结的小型证据：

~~~text
assets/
artifacts/
community-search/
diffs/
drafts/
logs/
meta/
rc/
services/
commands.sh
summary.tsv
candidate-gates.tsv
deferred-checks.tsv
SHA256SUMS
~~~

明确排除：

~~~text
src/
cache/
tools/
builds/
launch log
archive integrity/final-status sidecars
archive verify extraction directory
~~~

tools/builds/src/cache 必须留在 OUT 供 Codex 复核，但 `SHA256SUMS` 不得列出 archive 不包含的文件。另生成并归档 `meta/retained-large-files.tsv`，记录其绝对路径、size 和 SHA（目录只记录 inventory hash）。

### 5.2 生成顺序

严格按以下顺序：

1. 完成除 `meta/archive-members.expected` 和 `SHA256SUMS` 外的所有 payload 文件；关闭 xtrace；
2. 根据固定 payload 边界生成 `meta/archive-members.expected`，成员表必须把自身和稍后生成的 `SHA256SUMS` 也列为普通文件；从此不再修改其他 payload；
3. 对成员期望表中除 `SHA256SUMS` 自身以外的每个普通文件生成相对路径 SHA；
4. 验证 manifest 路径集合精确等于“成员期望集合减去 SHA256SUMS”，并确认实际 OUT 文件集合一致；
5. 从 OUT 根运行 `sha256sum -c SHA256SUMS`，将 log/rc 写到 archive 外部 sidecar；
6. 创建 archive；
7. 写 archive `.sha256`；
8. 从 archive 外重新计算 SHA 并比较；
9. `tar -tzf` 保存外部 listing 和真实 rc；
10. 解包到全新 `/home/lilingfeng/tmp/juicefs-c03-r2-verify-$RUN_ID/`；
11. 从解包根运行 `sha256sum -c SHA256SUMS`；
12. 比较解包普通文件集合：除 `SHA256SUMS` 外必须与 manifest 精确一致，且不得出现 src/cache/tools/builds；
13. 检查所有要求的顶层和关键证据存在；
14. runner 写外部 provisional integrity 与 candidate status，但不写最终 PASS；
15. runner 退出后，launcher 捕获真实 runner rc、冻结 launch log SHA，补齐 integrity，并写 final-status sidecar。

manifest check 的 rc 必须在命令后立即捕获，禁止在 `set -e` 后读取 `$?`。archive 建成后不得修改 archive 内任何成员；所有验证输出都留在外部 sidecar。

### 5.3 第 25 个终态门

外部 `<archive>.integrity.tsv` 至少包含：

~~~text
archive_sha256_match
tar_readable
member_set_exact
manifest_coverage_exact
manifest_check_before_archive
manifest_check_after_extract
forbidden_large_members_absent
required_evidence_present
runner_exit_rc_zero
launch_log_sha_recorded
~~~

十项全部 YES 才算第 25 门通过。随后由 launcher 判定：

- prearchive 24 项全 YES 且 integrity 全 YES：外部 `.final-status.txt` 写 `PASS-B-PR-READY-LOCAL`；
- 否则写具体失败状态，绝不把 `NOT-PR-READY` 改成 PASS。

archive verify 目录和全部外部 sidecar 保留到 Codex 复核结束；GLM 不得清理。

---

## 六、状态判定

### 6.1 `PASS-B-PR-READY-LOCAL`

仅当 24+1 门全部通过。允许结论：

> 在执行时冻结的官方 main commit 上，stock 确定性证明完整 block 在异步 slice ID 就绪后未补派发；B 在保留异步语义的同时修复该行为。最终两文件 patch 可从干净 clone 标准回放，并通过双工具链社区/语义/race/完整 pkg/vfs、Redis 生命周期、gofmt/tidy/vet、官方本地 lint、Linux/lite build和完整证据链审计。该候选可交 Codex 判断重复性和代码风险；官方 GitHub CI 尚未运行。

### 6.2 `UPSTREAM-ALREADY-FIXED`

必须同时满足 stock 三项转绿、源码存在等价修复、历史中有可能提交。禁止应用 B。下一步由 Codex 分析官方修复能否回合 v1.3。

### 6.3 `B-PATCH-DRIFT` / `CI-MATRIX-DRIFT` / `UPSTREAM-ORACLE-DRIFT`

保存完整差异并早停。GLM 不得改 patch、测试、工具链、次数或判据。

### 6.4 `LINT-INFRA-BLOCKED` / `LINT-FAIL`

均不得 PR-ready。禁止把 lint 留给 GitHub Actions 后继续。

### 6.5 `FULL-VFS-FAIL` / `BUILD-FAIL` / `SEARCH-BLOCKED`

保留失败现场，不挑选重跑。修复 runner/基础设施时必须新 input + 新 OUT。

### 6.6 `NON-COMPLIANT`

包括但不限于：

- 执行 runner 与 input/归档 runner 不一致；
- input 运行后新增 PID/log 或被改；
- 旧 input/OUT 被修改或复用；
- 同一 OUT 手工补跑；
- rc 被 `|| true` 覆盖；
- gate 只看步骤/rc、不看要求的精确语义；
- SOURCE/history 无 before/after 或发生变化；
- archive manifest 与成员不一致；
- adaptations、commands、runner SHA 不实；
- 社区/生产越界操作。

技术日志全绿也不能豁免。

---

## 七、GLM 报告交付物

报告落点：

~~~text
prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R2-execution-YYYYmmdd-HHMMSS.md
~~~

报告必须逐项给出：

1. input、RUN_ID、OUT、launch log、archive、verify dir 和所有 sidecar 绝对路径；
2. launcher/runner realpath，以及各自 executed/input/archived 三份 SHA/cmp；
3. input start/end/copy 文件集合、SHA、stat 和权限校验全文；
4. R1 三次 attempt 的 input/OUT/runner SHA 和 R2 修复映射；
5. frozen main、三点 freeze、commit show、ancestry/distance 和 writer history；
6. 官方 policy 文件、hash 和 CI 解析结果；
7. 双工具链 version/env/baseline；
8. stock 46 行表、原始日志和分支判定；
9. B 6+6+6 行表及每项精确 1/100/20 计数；
10. Q 20+20+20 行表及每项精确 1/100/20 计数；
11. 双工具链完整 pkg/vfs 和 Redis lifecycle 全表；
12. gofmt/license/diff/tidy/vet 全部真实 rc/hash；
13. lint query/install/version/run、binary/config SHA 和源码前后 cmp；
14. 四个 build 的 make/version/copy/hash/revision；
15. 最终 patch SHA、路径、B/R cmp 和 R 结果表；
16. 六组 GitHub 请求、本地 history、candidates 和 deferred duplicate 状态；
17. 三份草稿与真实性/脱敏扫描；
18. 四臂、SOURCE、protected history before/after 及 input 结束守卫；
19. 24 gate 初始表、解析次数表、最终全文和全表判定命令；
20. deferred checks；
21. commands、完整 xtrace、13 anchors exact cmp、forbidden raw/real；
22. pre-run/runtime adaptations 全文及所有 R2 失败现场；
23. archive payload、成员期望表、SHA256SUMS、解包校验和十项 integrity；
24. src/cache/tools/builds 留存位置及 inventory/hash；
25. 明确声明未运行性能/生产测试，未执行任何社区写操作；
26. 最终状态只能使用 §六定义的值。

报告不得只写“全绿”；所有表必须给精确数据或指向唯一证据文件。GLM 不得创建下一任务、删除现场或自行提交社区。

---

## 八、红线汇总

1. 禁止修改 C02/C03/C03-R1 的 input、OUT、archive、task、report。
2. 禁止复用旧 src/cache/tools/builds/log/rc/PASS。
3. 禁止 runner 硬编码任何带时间戳的 input 路径。
4. 禁止在冻结 input 中生成 stdout、PID、rc 或临时文件。
5. 禁止执行后修改同一 input/runner；修复必须新 input + 新 OUT。
6. 禁止同一 OUT 手工补跑、替换日志或修正 gate。
7. 禁止默认/hardcode YES、漏门 PASS、重复解析 gate。
8. 禁止只凭 go test rc 判 count/race；必须逐测试精确计数。
9. 禁止 `|| true` 后记录伪 rc。
10. 禁止 lint 未覆盖 version/source guard 却写 YES。
11. 禁止 Redis inspect/log/stop/gone 任一步缺证据却写 lifecycle YES。
12. 禁止 source/history guard 使用伪 0 或只看 changed-path 文本。
13. 禁止 SHA manifest 列出 archive 不含文件，或 archive 文件不受 manifest 覆盖。
14. 禁止归档后修改 payload，再沿用旧 SHA。
15. 禁止 `git apply --recount/--3way/--reject` 或手工 rebase。
16. 禁止改变测试名、断言、等待窗口、次数和固定资产。
17. 禁止最终 patch 超出 writer.go 与 writer_flush_test.go。
18. 禁止把 C02 内部测试提交到社区 patch。
19. 禁止根级 `/tmp/`、sudo、fio、mount、生产服务和 Docker prune。
20. 禁止 commit、push、fork、branch/tag 和 GitHub 写 API。
21. 禁止把搜索成功写成“不重复”，或把本地 PASS 写成官方 CI PASS。
22. 任何控制变量、源码接口或官方 CI 口径漂移，停止等待 Codex。

---

## 附录 A：B 语义冻结

唯一允许的生产变化仍是：在 `prepareID` 把非零 slice ID 设置给 writer 后，如果 slice 未 frozen 且已包含至少一个完整 block，则对当前 `slen` 做一次 catch-up `FlushTo`；失败锁存为 `syscall.EIO`。

禁止改变：

- `NewSlice` 的异步边界；
- 非 EIO 的重试次数；
- frozen slice 的收尾路径；
- `FlushTo` 阈值、offset 或错误类型；
- file-writer 锁边界；
- partial block 行为；
- commitThread 或 buffer 节流逻辑。

任何需要语义重写的 upstream 漂移都不是 GLM 自主适配范围。

## 附录 B：R1 已知搜索候选

R2 必须重新搜索并保留下列历史候选，不得按标题直接判重：

~~~text
issue #1250  I/O Error when minio io depay 1s
issue #6398  Would it be feasible to reduce the scope of the openfile lock...
issue #5038  Data corruption: zeroes are sometimes written instead of the actual data
issue #6049  Bad DIO write performance when mount with option async_dio
PR    #7202  fuse: experimental write-path FUSE passthrough (WIP)
PR    #2160  translate io_processing.md
~~~

GLM 只保留搜索证据；Codex 将根据复现条件、源码路径、因果和修复内容完成最终判重。

## 附录 C：R2 放行后的边界

若且仅若 R2 得到 `PASS-B-PR-READY-LOCAL`：

1. 不再继续做同类本地压力重跑；
2. Codex 先完成候选 issue/PR 重复性与 patch 代码审阅；
3. 用户明确授权后，才制定社区 issue/PR 提交流程；
4. GitHub Actions、维护者 review 和可能要求的扩展 CI 属于提交后的独立门；
5. 在社区合入前，v1.3 自研补丁仍按内部资产维护，不能把候选状态当成上游已修复。
