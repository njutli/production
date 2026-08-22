# C03-R1：最新 main 社区候选全门禁洁净重跑

> 面向执行方：GLM  
> 方案与结果复核：Codex  
> 日期：2026-08-17  
> 性质：C03 社区就绪验证的纠偏重跑；不占 03 阶段性能任务编号  
> 上游：执行时从 `https://github.com/juicedata/juicefs` 重新冻结最新 `main`  
> 主工具链：Go 1.25.7  
> 兼容工具链：本机 Go 1.26.0  
> 工作根：`/home/lilingfeng/tmp`；禁止使用根级 `/tmp/`  
> 核心原则：全新 input、全新 OUT、全新 clone/cache；所有硬门必须真实执行并参与最终状态。  
> 禁止：复用 C03 测试结果、修改旧 OUT、commit、push、fork、创建/评论 issue 或 PR、性能测试和生产操作。

---

## ⚑ 计划线

~~~text
C01-R1
  └─ 固定 main 上证明漏派发；A/B 覆盖最小行为
  ↓
C02
  └─ B 保留异步语义并通过故障、freeze、并发与 race；成为社区候选
  ↓
C03
  ├─ 技术证据：最新 main 仍受影响，B 全部核心矩阵通过
  ├─ 有效资产：最终两文件 patch 可干净回放
  └─ 无效状态：lint=PENDING，却错误输出 PR-ready；runner/audit/交付不闭合
  ↓
★ C03-R1（你在这里）
  ├─ 重新冻结执行时最新 main
  ├─ 用不可变 runner 完整重跑四臂与本地 CI
  ├─ 实跑官方 v2.6 系列全仓 lint
  ├─ 修复全门参与、anchor、自审计和失败留存
  └─ 补齐 Redis、build、查重与草稿证据
  ↓
  ├─ PASS-B-PR-READY-LOCAL：交 Codex 复核，之后才可决定 issue/PR
  ├─ UPSTREAM-ALREADY-FIXED：停止 B，定位修复并转 backport 分析
  └─ DRIFT/FAIL/NON-COMPLIANT：停止，禁止社区写操作
~~~

一句话：不接受 C03 的错误 PASS，用一次可审计的完整重跑证明“最新 main 仍受影响、B 能修复、全部本地社区门禁真实为绿”。

---

## 〇、背景与 C03 正式裁定

### 0.1 C03 原始执行

原始报告：

~~~text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-execution-20260817-100609.md
~~~

原始证据：

~~~text
/home/lilingfeng/tmp/juicefs-c03-20260817-100609
/home/lilingfeng/tmp/juicefs-c03-20260817-100609-artifacts.tar.gz
~~~

archive SHA256 已由 Codex 复核为：

~~~text
838d2f14a48020c5389e16acc453b4eb0083420607892d2ac41c7526e4f33cfa
~~~

### 0.2 C03 可以承接的技术事实

C03 在冻结的官方 main `a617e1b016967137de5bdf099cb8b8415cb1d06d` 上留下了有效技术证据：

1. stock U1/U3 在双工具链下确定性失败，U2 通过；
2. B 社区三项在双工具链下各自精确通过 `count=100` 和 `-race count=20`；
3. C02 十项语义测试在双工具链下各自精确通过 `count=100` 和 `-race count=20`；
4. 双工具链完整 `pkg/vfs` 通过；
5. B/R 两路径 diff 一致，最终 patch 能标准 apply；
6. 最终社区 patch SHA256 为：

~~~text
1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9
~~~

这些事实说明 B 值得继续推进，但 **C03-R1 不得直接复用其 PASS 结果**；全部通过项必须在本轮新 OUT 中重新产生。

### 0.3 C03 为什么不能记 PR-ready

Codex 正式裁定：

~~~text
C03-REVIEWED = TECHNICAL PASS-B / PR-READINESS BLOCKED / AUDIT NON-COMPLIANT
~~~

必须修正的问题：

1. `B_lint=PENDING`，但 final status 错写为 `PASS-B-PR-READY-LOCAL`；
2. runner 把若干 gate 默认或硬编码为 YES，最终状态没有检查 lint、tidy、vet、build、search 等全部硬门；
3. runner 在两次失败后原地修改，旧 OUT 未完整保留，pre-run adaptations 未指名历史失败；
4. anchor 检查匹配了检查命令自身，`PACKAGE` 在真正发生前即可被判存在；
5. GitHub 查询缺 status/header/timestamp 和本地历史查重；
6. Redis 缺 inspect/log/销毁证明；
7. build 缺 `version` 输出和产物 SHA256；
8. Q-semantic 缺十项单项执行；
9. PR 草稿列出了实际未运行的 lint。

C03-R1 是洁净重跑，不是给 C03 OUT 填文件。禁止修改或补写 C03 的任何 OUT、archive、input 和原始报告。

### 0.4 必须保留且只读的历史路径

以下均为历史证据，只读、禁止清理、移动、改名或补文件：

~~~text
/home/lilingfeng/tmp/juicefs-c03-input-20260817-082552
/home/lilingfeng/tmp/juicefs-c03-20260817-082905
/home/lilingfeng/tmp/juicefs-c03-20260817-084643
/home/lilingfeng/tmp/juicefs-c03-20260817-100609
/home/lilingfeng/tmp/juicefs-c03-20260817-100609-artifacts.tar.gz
/home/lilingfeng/tmp/juicefs-c03-20260817-100609-artifacts.tar.gz.sha256
~~~

其中两个早期 OUT 当前只剩 cache 的事实也要写入本轮 `pre-run-adaptations.md`，不得伪称它们是完整失败证据。

---

## 一、目标、分支与唯一通过状态

### 1.1 Q0：执行时最新 main 是否仍受影响

必须重新访问官方 remote，稳定冻结一个精确 `UPSTREAM_COMMIT`，不能沿用 C03 的 `a617e1b0` 作为“最新”。

| 结果 | 状态 | 动作 |
|---|---|---|
| stock U1/U3 按预期失败，U2 通过 | `UPSTREAM-AFFECTED` | 继续 B 四臂验证 |
| stock U1/U3 通过且源码已有等价修复 | `UPSTREAM-ALREADY-FIXED` | 停止应用 B，定位上游提交并 partial archive |
| 测试、源码或 CI 口径混合漂移 | `UPSTREAM-ORACLE-DRIFT` / `CI-MATRIX-DRIFT` | 停止，交 Codex |
| C02 base 不再是 main 祖先 | `UPSTREAM-HISTORY-DIVERGED` | 停止 |

### 1.2 Q1：B 是否在最新 main 上完整修复

必须重新证明：

- stock 社区正控红、负控绿；
- B 社区三项单项、`count=100`、race20 全绿；
- C02 十项逐项、`count=100`、race20 全绿；
- 完整 `pkg/vfs` 双工具链全绿；
- R-replay 从最新 main 干净标准回放并复验。

### 1.3 Q2：社区本地 CI 是否真实闭合

必须实际执行并保留 rc/log：

- gofmt、license、`git diff --check`；
- 双工具链 `go mod tidy`，命令 rc=0 且 go.mod/go.sum hash 不变；
- 双工具链 `go vet ./pkg/vfs`；
- 官方 `verify.yml` 指定的 golangci-lint v2.6 系列、Go 1.25.7、仓库根全仓运行；
- 双工具链 Linux 与 lite build、版本输出和产物 SHA256。

lint 下载或安装失败只能得到 `LINT-INFRA-BLOCKED`；lint rc 非零只能得到 `LINT-FAIL`。**不存在 `PENDING` 仍 PASS 的分支。**

### 1.4 Q3：社区前置资料是否闭合

必须完成：

- 六组匿名 GitHub issue/PR 查询的请求、HTTP status、rate-limit headers、完整 JSON 和时间戳；
- 冻结仓库的本地 Git history 搜索；
- 候选 URL/标题/状态/更新时间表；
- issue、PR、commit message 草稿；
- 草稿只列本轮真实为 YES 的测试，不得预写 lint 已通过；
- 最终 patch 与草稿的内部信息/凭据扫描。

GLM 只汇总候选，不判断是否重复；重复性结论由 Codex 作出。

### 1.5 Q4：执行链是否可审计

必须证明：

- runner 在首次启动前已冻结；
- runner 运行后没有原地修改 input；
- 任一失败重试都使用新 input 与新 OUT，旧证据完整保留；
- 所有 gate 从 `NOT_RUN` 开始，由具体证据计算，禁止默认 YES；
- 所有要求的 gate 都参与最终状态；
- anchor 使用独立事件文件精确比对，不靠 grep xtrace 字符串；
- forbidden 审计模式不出现在审计命令参数中，不发生自匹配。

### 1.6 唯一通过状态：`PASS-B-PR-READY-LOCAL`

只有 §2.7 的 24 个 required gate 都精确为 `YES`，并且随后独立完成 archive integrity 终态门，才允许写：

~~~text
PASS-B-PR-READY-LOCAL
~~~

候选的 pre-archive 状态必须由 `candidate-gates.tsv` 机械计算，禁止先赋 PASS 再遗漏式降级。推荐判定形态：

~~~bash
if awk -F '\t' 'NR > 1 && $2 != "YES" { bad=1 } END { exit bad }' \
  "$OUT/candidate-gates.tsv"; then
  PREARCHIVE_STATUS=ALL-REQUIRED-GATES-YES
else
  PREARCHIVE_STATUS=NOT-PR-READY
fi
~~~

只有 archive 创建、外部 SHA256 重算和 `tar -tzf` 校验也成功后，runner 才在 archive 外写最终 sidecar `PASS-B-PR-READY-LOCAL`。这样避免让 archive 内的文件声明“包含自身的 archive 已校验”这一循环依赖。

该状态仍只表示“可交 Codex/用户决定是否先创建 issue”；不代表 GitHub Actions 已运行，也不授权 GLM 写社区。

### 1.7 明确不做

- 不运行 fio、benchmark、吞吐 AB、数据完整性 fio verify 或 soak；
- 不挂载 JuiceFS，不访问生产 Redis/Ceph/TiKV/S3；
- 不修改 v1.3.1、生产二进制或生产部署；
- 不运行完整 `make test.pkg` 的多服务矩阵；
- 不安装系统包，不使用 sudo；
- 不运行 Windows/Ceph/FDB build；
- 不 commit、不 push、不创建分支/fork；
- 不创建、评论、关闭 issue/PR；
- 不签 CLA；
- 不把本地门禁写成官方 GitHub CI PASS。

---

## 二、固定输入、动态冻结量、四臂与数据源

### 2.1 固定输入

| 项 | 固定值 |
|---|---|
| 官方 remote | `https://github.com/juicedata/juicefs` |
| 只读 SOURCE | `/home/lilingfeng/project/juicefs`，仅作为 Git 对象种子 |
| C02 base | `edabf9c24601510476e7453abff177f4aaca07ac` |
| C03 参考 commit | `a617e1b016967137de5bdf099cb8b8415cb1d06d`；仅作对照，不作最新 main |
| B 生产 patch SHA256 | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` |
| 社区测试 SHA256 | `bce85ad4abf92a47074849a544aaa756963fb44a1839619bbc71c5d7ce1fe9bc` |
| C02 内部测试 SHA256 | `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` |
| C03 最终 patch 参考 SHA256 | `1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9` |
| Go 主工具链 | `GOTOOLCHAIN=go1.25.7` |
| Go 兼容工具链 | `GOTOOLCHAIN=local`，必须为 `go1.26.0` |
| lint | 冻结 main 的 `verify.yml` 必须仍指定 `v2.6` 系列 |
| Redis | `redis:7.2-alpine`，执行时冻结 image ID/RepoDigest |
| 工作根 | `/home/lilingfeng/tmp` |

允许从 C03 最终 OUT 的 `assets/` 复制三个固定输入文件，但复制后必须核验上述 SHA256。禁止直接把 C03 的源码 clone、cache、日志、rc 或 `community-candidate.patch` 当本轮测试结果。

若最新 main 的 `pkg/vfs/writer.go` 基础 blob 与 C03 相同，本轮最终 patch 应与参考 SHA 一致；若基础 blob 已变化但 B 仍标准 apply，允许最终 patch SHA 改变，但必须保存 base diff 并由 Codex 复核。

### 2.2 执行时动态冻结量

所有量必须在源码测试前落盘：

| 量 | 唯一数据源 |
|---|---|
| main commit、前后 ls-remote | `meta/upstream-commit.txt`、`meta/ls-remote-{before,after}.txt` |
| commit 时间、标题、parents | `meta/upstream-commit-show.txt` |
| 与 C02/C03 的距离与祖先关系 | `meta/upstream-distance.txt`、`meta/upstream-ancestry.tsv` |
| writer.go base blob/diff/log | `meta/upstream-writer-*.txt`、`diffs/C03-to-upstream-writer.diff` |
| go directive、CI Go matrix、lint 系列 | `meta/upstream-ci-matrix.tsv` |
| 官方政策文件快照/hash | `meta/upstream-policy/`、`meta/upstream-policy-hashes.txt` |
| lint module 版本 | `meta/lint-version-selection.txt` |
| Redis image identity | `meta/redis-image.txt` |

冻结后不得再次 fetch。若 ls-remote 在冻结窗口发生变化，最多重建 freeze 两次；所有尝试都记录，最终只能使用一个稳定 commit。

### 2.3 四臂

| 臂 | 内容 | 允许变化 |
|---|---|---|
| S-oracle | 最新 main + 社区测试 | `pkg/vfs/writer_flush_test.go` |
| B-candidate | 最新 main + B + 社区测试 | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |
| Q-semantic | 最新 main + B + C02 内部测试 | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_c02_test.go` |
| R-replay | 最新 main + 本轮导出的最终 patch | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |

四臂必须是独立 `--no-hardlinks` clone，独立 index；禁止 worktree、复制构建产物或共享 GOCACHE。

### 2.4 社区测试预注册矩阵

| ID | 测试 | S-oracle | B-candidate/R-replay |
|---|---|---|---|
| U1 | `TestFullBlockDispatchedWhenSliceIDBecomesReady` | 指定 marker FAIL | PASS |
| U2 | `TestPartialBlockNotDispatchedWhenSliceIDBecomesReady` | PASS | PASS |
| U3 | `TestFlushErrorRecordedWhenSliceIDBecomesReady` | 指定 marker FAIL | PASS |

S 的 U1/U3：双工具链各 10 个独立进程，全部必须唯一命中预注册失败信息。B：双工具链单项、三项 `count=100`、三项 `-race count=20`。R：双工具链单项与 `count=20`。

### 2.5 C02 十项语义矩阵

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

双工具链分别执行：十项单项各一次、十项 `count=100`、十项 `-race count=20`。每项 PASS 行数必须精确为 1/100/20，且无 `DATA RACE`、panic、timeout、build failure 或 no-tests warning。

### 2.6 唯一数据源

| 判据 | 数据源 |
|---|---|
| 输入不可变 | `input.sha256`、`meta/input-check.log`、runner SHA |
| upstream freeze/CI | `meta/upstream-*`、`logs/fetch-*` |
| stock oracle | `meta/upstream-state-gate.tsv`、S 日志/rc/repeat TSV |
| B 社区矩阵 | `meta/community-results.tsv`、B 日志/rc/count TSV |
| Q 语义矩阵 | `meta/semantic-results.tsv`、Q 日志/rc/count TSV |
| 完整 vfs | `logs/TOOL-B-full-vfs.log`、rc、Redis lifecycle 证据 |
| tidy/vet/lint/build | 对应 logs/rc/hash/version 文件 |
| patch/replay | `artifacts/community-candidate.patch`、SHA、R diff/test |
| 查重 | `community-search/` 的 query/request/header/body/status 与本地 history |
| 草稿/脱敏 | `drafts/`、`logs/community-artifact-secret-scan.log` |
| 源码守卫 | 四臂 HEAD/status/diff/path/hash guard |
| 执行审计 | frozen runner、commands、xtrace、anchors、forbidden/adaptations |
| 完整性 | `SHA256SUMS`、sha check、archive、archive.sha256 |

### 2.7 Required gates

`candidate-gates.tsv` 必须且只能包含以下 required gates，全部必须为 `YES`：

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

以上共 24 个 candidate required gates。禁止 `PENDING`、`SKIP`、`N/A`。archive integrity 是第 25 个 **终态门**，写在 archive 外部 sidecar，不写入 `candidate-gates.tsv`，以避免自引用。官方 Windows/Ceph/FDB build 和 GitHub Actions 写入单独的 `deferred-checks.tsv`，状态固定为 `NOT_RUN_BY_DESIGN`，不得混入 required gates。

---

## 三、输入冻结、runner 与安全边界

### 3.1 全新 input 与 OUT

命名：

~~~text
/home/lilingfeng/tmp/juicefs-c03-r1-input-YYYYmmdd-HHMMSS/
/home/lilingfeng/tmp/juicefs-c03-r1-YYYYmmdd-HHMMSS/
~~~

input 至少包含：

~~~text
run-c03-r1.sh
taskbook.md
writer_flush_test.go
writer_flush_c02_test.go
async-catchup-main.patch
pre-run-adaptations.md
anchors.expected
forbidden-patterns.txt
runner-static-review.txt
input.sha256
~~~

`input.sha256` 覆盖除自身外的全部输入。生成后 input 只读；runner 启动时间必须晚于全部输入的最终 mtime。

禁止从 C03/C02 或任何失败 R1 OUT 复制 cache、src、tools、logs、rc 和生成 patch。本轮至少预留 35 GiB。

### 3.2 runner 首次启动前静态门

在冻结 input 前完成并写入 `runner-static-review.txt`：

1. `bash -n run-c03-r1.sh` rc=0；
2. runner 包含 lint 版本选择、安装、`version`、SHA 和实际 `golangci-lint run`；
3. 所有 gate 初值为 `NOT_RUN` 或 `NO`，没有 `gate=YES` 的默认赋值；
4. final status 通过遍历整个 `candidate-gates.tsv` 计算；
5. 没有 `PENDING` 可通往 PASS 的代码；
6. tidy、curl、Docker ping/inspect/log/stop 均捕获真实 rc；
7. Q 十项单项循环存在；
8. build 的 version/hash 采集存在；
9. anchor 比对读取 `meta/anchors.actual`，不 grep xtrace 里的 anchor 文本；
10. forbidden 审计通过 `rg -f assets/forbidden-patterns.txt` 或等价外置模式执行，命令行本身不含禁止模式；
11. runner 不含 `rm -rf`、prune、commit、push、GitHub 写 API；
12. `input.sha256` 自校验通过。

### 3.3 不可变 runner 与失败重试纪律

首次启动后：

- 禁止修改该 input 中任何文件；
- 禁止在同一 OUT 手工补跑；
- runner bug、未预注册的网络适配或控制变量问题都必须先让当前 OUT 结束并 partial archive；runner 内已冻结的有限重试策略可按任务书执行；
- 若可在不改控制变量的前提下修 runner，创建 **全新 input 目录和全新 OUT**；
- 新 input 的 `pre-run-adaptations.md` 必须指名旧 input、旧 OUT、失败步骤、原 runner SHA、新 runner SHA 和修改原因；
- 旧 input/OUT/partial archive 必须完整保留。

未满足任一条，本次状态直接 `NON-COMPLIANT`，不得靠结果全绿豁免。

### 3.4 runner 错误处理

使用：

~~~bash
set -Eeuo pipefail
umask 077
~~~

预期失败测试必须放在显式捕获函数的 `if ...; then rc=0; else rc=$?; fi` 中；禁止为了容纳 stock FAIL 全局关闭 `-e`。任何非预期失败不得被裸 `|| true` 吞掉。

允许 `|| true` 的唯一类型是“结果本来就是数据”的只读搜索，但仍必须紧接着保存真实 curl/git/grep rc，并由 gate 解释。不得先 `|| true` 再把 `$?` 记成 0。

### 3.5 anchor 设计

`anchors.expected` 固定为：

~~~text
C03R1_ANCHOR:INIT
C03R1_ANCHOR:FETCH
C03R1_ANCHOR:STOCK_ORACLE
C03R1_ANCHOR:APPLY_B
C03R1_ANCHOR:SEMANTIC
C03R1_ANCHOR:FULL_VFS
C03R1_ANCHOR:LINT_BUILD
C03R1_ANCHOR:REPLAY
C03R1_ANCHOR:COMMUNITY_SEARCH
C03R1_ANCHOR:SOURCE_GUARD
C03R1_ANCHOR:AUDIT
C03R1_ANCHOR:PACKAGE
~~~

runner 的 `record_anchor` 每次同时打印并追加一行到 `meta/anchors.actual`。收尾必须用 `cmp` 精确比对 expected/actual，确保顺序正确、每项恰好一次。禁止通过 `grep shell-xtrace.log` 判断 anchor，因为 expected 字符串和检查命令本身会污染结果。

### 3.6 网络与社区权限

允许：官方 remote 的 `ls-remote/fetch`、Go module/toolchain/lint 下载、匿名 GitHub Search GET、Redis image pull。

禁止：

- 使用 GitHub token、cookie 或 Authorization header；
- POST/PATCH/PUT/DELETE GitHub API；
- commit、push、fork、创建/评论/关闭 issue/PR；
- fetch PR head 或运行搜索结果中的代码；
- 修改 SOURCE remote/config/ref。

### 3.7 Docker/Redis 边界

- 先证明宿主 `127.0.0.1:6379` 未监听；占用即 `REDIS-PORT-BLOCKED`；
- 只管理 label 和 container name 均含本轮 RUN_ID 的容器；
- `--rm`、非 privileged、非 host network、无宿主 volume、只绑定 loopback；
- trap 只 stop 已登记的精确 container ID；
- 禁止 kill/stop/remove 其他容器，禁止任何 prune；
- 禁止使用已有 Redis，禁止 flushdb/flushall。

---

## 四、执行步骤

### 步骤 0：通读与 preflight

完整阅读：

1. 本任务书；
2. C03 任务书、C03 原始报告和本任务 §0 的正式裁定；
3. C02 报告中 Codex 后续复核；
4. `prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.8、§二.9、§二.11；
5. `prod-deploy/skills/SYSTEM-SAFETY-SKILL.md`；
6. 冻结 main 的 CONTRIBUTING、verify、unittests、build action、`.golangci.yml`、go.mod、Makefile。

`pre-run-adaptations.md` 必须至少记载 C03 的 lint omission、gate omission、anchor self-match、两次旧 OUT 不完整、runner 原地修改和缺失交付物。若本轮 runner 编写阶段又有失败尝试，也一并记录。

### 步骤 1：冻结 input、初始化 OUT 与 xtrace

完成 §3.1/§3.2 后才允许启动 runner。runner 首先：

1. 创建唯一 OUT；
2. 建立 `assets artifacts builds cache community-search diffs drafts logs meta rc services src tools`；
3. 复制全部冻结输入；
4. 校验 input SHA，保存 log/rc；
5. 写 `commands.sh`，包含唯一 runner 调用及无密钥环境覆盖；
6. 开启 xtrace 到 `logs/shell-xtrace.log`；
7. `record_anchor C03R1_ANCHOR:INIT`；
8. 安装仅清理本轮 Redis container ID 的主 shell trap。

OUT 创建后 runner 外的任何测试/patch/build 命令都会使该 OUT `NON-COMPLIANT`。

### 步骤 2：稳定冻结官方 main 与政策口径

用 SOURCE 建立隔离 `upstream-fetch` clone，把 **隔离 clone** 的 origin 设为官方 URL；不得改 SOURCE。

依次保存：

1. fetch 前 `ls-remote refs/heads/main`；
2. `git fetch --no-tags origin main` 日志与 rc；
3. fetch 后 `ls-remote`；
4. `FETCH_HEAD`；
5. 前后 ref、FETCH_HEAD 三者一致性；
6. commit show、C02/C03 ancestry 和 distance。

若前后 remote ref 不一致，记录本次 freeze attempt 并最多重试两次。最终必须三者一致。

从冻结 commit 保存：

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

机械解析并要求：go directive 仍为 1.25 系、verify build matrix 仍含 1.25/1.26、lint 仍指定 v2.6 系列。任何漂移停止，禁止 GLM 自行选新版工具链。

### 步骤 3：建立四臂与静态冲突门

从 frozen upstream clone 建立四个独立 clone，全部 detach 到同一个 `UPSTREAM_COMMIT`。保存 before HEAD/status。

保存：

- C03 reference→latest 的 `writer.go` diff；
- latest `writer.go` blob SHA；
- `prepareID/write/FlushTo/SetID` 上下文；
- C02 base 之后 `writer.go` 的 path log 和 `-S` history；
- 社区测试文件、三个测试名和全部 helper 名的冲突搜索。

存在文件/符号冲突即 `TEST-ASSET-CONFLICT`；禁止重命名测试后继续。

### 步骤 4：双工具链与基线门

每个工具链使用独立 GOCACHE，共享本轮空 GOMODCACHE，不得复制旧缓存。固定并保存完整 `go env`。

在未注入测试的 S-oracle 上执行：

~~~bash
go test ./pkg/vfs -run '^$' -count=1
go test ./pkg/vfs -run '^(TestSmode|TestEntryString|TestError|TestVFSIO)$' -count=1 -v
~~~

两工具链均必须通过。mod download 的每次尝试都保存独立 log/rc；成功前的失败进入 runtime adaptations。

### 步骤 5：S-oracle 判定

注入固定社区测试并核验 SHA。双工具链分别：

1. U2 单项 PASS；
2. U1/U3 单项按精确 marker FAIL；
3. U1/U3 各 10 个独立进程，全部相同 FAIL；
4. 每份失败日志只能有一个目标 FAIL/marker；
5. 无 build、panic、timeout、fatal 或 race 类错误。

runner 生成 `meta/upstream-state-gate.tsv` 与 repeat TSV，并由它们计算 upstream 分支。禁止把 `upstream_stock_oracle` 默认设 YES。

如果 stock 已修复，保存源码和可能提交证据后停止，禁止继续 B。

### 步骤 6：B 标准 apply 与社区矩阵

仅 `UPSTREAM-AFFECTED` 继续。B-candidate 必须：

~~~bash
git apply --check "$OUT/assets/async-catchup-main.patch"
git apply "$OUT/assets/async-catchup-main.patch"
~~~

两条命令都保存 rc=0。禁止 `--recount`、3-way、reject 或手工编辑。复制社区测试后核验 hash/gofmt。

双工具链分别执行：

- U1/U2/U3 单项各一次；
- 三项 `count=100`；
- 三项 `-race count=20`；
- 精确计数每项 1/100/20；
- 无 no-tests、FAIL、panic、timeout 或 DATA RACE。

### 步骤 7：Q-semantic 完整语义矩阵

Q-semantic 标准 apply 同一 B，复制固定 C02 测试。双工具链分别：

1. 十项逐项单独执行；
2. 十项合跑 `count=100`；
3. 十项合跑 `-race count=20`；
4. 每项精确 PASS 1/100/20；
5. no-tests、panic、timeout、FAIL、DATA RACE 计数均为 0。

内部测试不得进入 B-candidate、R-replay 或最终 patch。

### 步骤 8：完整 pkg/vfs 与 Redis 生命周期

先冻结 Docker version/context 和 Redis image identity。每个工具链使用一个全新容器：

1. 记录创建命令、container ID/name/label；
2. 轮询 `redis-cli ping`，必须在固定尝试数内得到 PONG，保存每次 rc；
3. 测试前保存 `docker inspect`，机械确认：loopback 6379、非 privileged、非 host network、无宿主 bind、label 正确；
4. 在 B-candidate 执行 `go test ./pkg/vfs -count=1 -v -timeout=15m`；
5. 保存完整 Redis log 和测试日志/rc；
6. stop 精确 container ID；
7. 保存 stop rc，并用 inspect/`docker ps -a --filter` 证明 `--rm` 后不存在；
8. 第二工具链重新创建，不复用数据。

任一生命周期证据缺失，`redis_lifecycle=NO`。完整包失败不允许挑选重跑。

### 步骤 9：gofmt、tidy 与 vet

在 B-candidate：

- `gofmt -d` 对两条最终路径必须为空；
- license header 存在；
- `git diff --check` rc=0；
- 社区测试 SHA 精确匹配；
- 双工具链依次运行 `go mod tidy`，每次捕获真实 rc=0，前后 go.mod/go.sum hash 相同；
- tidy 任一失败或文件变化立即停止，不运行下一个工具链掩盖结果；
- 双工具链 `go vet ./pkg/vfs` rc=0。

禁止 `go mod tidy ... || true` 后只比较 hash。

### 步骤 10：官方 v2.6 系列全仓 lint

从冻结 `verify.yml` 解析 lint 系列，不得从任务书硬猜。保存 module 版本查询原文，筛选并选择最高稳定 `v2.6.x`，要求匹配：

~~~text
^v2\.6\.[0-9]+$
~~~

只安装到 `$OUT/tools/bin`：

~~~bash
GOBIN="$OUT/tools/bin" GOTOOLCHAIN=go1.25.7 \
  go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@"$LINT_VERSION"
~~~

必须保存：

- 版本查询 log/rc；
- 选定版本与理由；
- install log/rc；
- `golangci-lint version` log/rc；
- 二进制 SHA256；
- `.golangci.yml` SHA256；
- lint 前后 HEAD/status。

使用 Go 1.25.7，从 B-candidate 仓库根执行官方等价命令：

~~~bash
"$OUT/tools/bin/golangci-lint" run
~~~

不得只 lint `pkg/vfs` 或新文件后宣称官方 lint 通过。rc=0 且源码无变化才设置 `B_lint=YES`。安装失败、网络失败、timeout 和 lint finding 都不能豁免。

### 步骤 11：双工具链 Linux/lite build

每个工具链依次执行：

~~~bash
make -B juicefs
./juicefs version
sha256sum ./juicefs
make -B juicefs.lite
./juicefs.lite version
sha256sum ./juicefs.lite
~~~

保存每条命令独立 rc/log、版本和 hash。下一工具链覆盖产物前，把二进制复制到 `builds/TOOL/` 供 Codex 复核；builds 不进入压缩 archive，但保留在 OUT。

版本输出必须包含冻结 commit 的 revision。Windows/Ceph/FDB 写入 deferred，不得伪称本地通过。

### 步骤 12：最终 patch 与干净 replay

导出前要求 B-candidate HEAD 正确、路径正确、test hash 正确、go.mod/go.sum/vendor 未变化。

只导出：

~~~text
pkg/vfs/writer.go
pkg/vfs/writer_flush_test.go
~~~

R-replay 在此之前必须全净。标准 `git apply --check` + `git apply`，保存 rc。要求：

- R/B 两路径 diff 逐字节一致；
- writer.go 内容一致；
- 社区测试一致；
- 双工具链 U1/U2/U3 单项 PASS；
- 双工具链三项 `count=20`，每项精确 20；
- `git diff --check`、HEAD、路径 guard 全通过。

记录最终 patch SHA；若 latest 的 writer base blob 与 C03 相同，还必须等于 C03 参考 patch SHA。

### 步骤 13：只读社区查重

至少执行 C03 的六组查询：

~~~text
repo:juicedata/juicefs is:issue prepareID FlushTo
repo:juicedata/juicefs is:pr prepareID FlushTo
repo:juicedata/juicefs is:issue "slice ID" writer flush
repo:juicedata/juicefs is:pr "full block" FlushTo
repo:juicedata/juicefs is:issue random write flush block
repo:juicedata/juicefs is:pr random write flush block
~~~

每组单独保存：

~~~text
query-N.request.txt
query-N.started-at.txt
query-N.headers.txt
query-N.http-status.txt
query-N.body.json
query-N.curl.rc
query-N.validation.txt
~~~

curl 必须保存真实 rc 和 HTTP status；禁止 `|| true` 后记录伪 0。要求 HTTP 200、JSON 可解析、`total_count` 与 `items` 字段存在。headers 必须含 rate-limit 信息；请求匿名且不得记录凭据。

同时对 frozen repository 保存 `git log --grep`、`git log -S`、目标路径历史和关键词搜索。生成 `community-search/candidates.tsv`，列 URL、number、issue/PR、state、title、updated_at、命中 query；不得下重复性结论。

### 步骤 14：草稿与真实性门

生成 issue、PR、commit-message 草稿。必须填入本轮 `UPSTREAM_COMMIT` 和真实工具链。

PR Tests 段由 `candidate-gates.tsv` 生成：只有 gate=YES 才允许列为已通过。lint 未通过时不得出现 “golangci-lint passed”；但此时整体本来也不能 PR-ready。

草稿必须明确：

- stock main 的确定性源码行为；
- B 保留异步 NewSlice；
- 本地已运行哪些门；
- GitHub Actions 尚未运行；
- 不把缺陷夸大为所有性能问题或数据损坏的唯一原因。

对最终 patch、测试和三个草稿做内部路径/IP/凭据/项目代号/模型名称扫描。保存原始扫描 log；任何命中 `community_drafts_secret_scan=NO`，禁止静默改后继续同一 OUT。

### 步骤 15：源码与资产守卫

`record_anchor C03R1_ANCHOR:SOURCE_GUARD`，保存四臂 after HEAD/status/full diff/diff-stat/changed paths。

必须机械验证：

- 四臂 HEAD 都等于 `UPSTREAM_COMMIT`；
- 变化路径精确等于 §2.3；
- B/R 测试文件逐字一致；
- B/Q/R writer.go 一致；
- B/R 两路径 diff 一致；
- Q 内部测试不在最终 patch；
- go.mod/go.sum/vendor 无变化；
- SOURCE 的 HEAD/status/remote 与 preflight 快照一致；
- C02/C03 历史路径的 mtime/size 清单与 preflight 一致。

### 步骤 16：全门计算、审计与归档

#### 16.1 gate 计算

所有 gate 初值必须是 `NOT_RUN`。每个 gate 由 §2.6 指名文件计算后写成 YES/NO，不得从“步骤走到了”推定 YES。

特别要求：

- `community_search` 检查六组 curl rc、HTTP 200、JSON validation、headers 和 candidates；
- `B_lint` 检查安装/version/SHA/lint rc 和前后源码状态；
- `redis_lifecycle` 检查两容器的 inspect/log/PONG/stop/不存在证明；
- `execution_audit` 不能在自身检查完成前写 YES；
- archive integrity 不得预写到 candidate gates；只能在 archive 建成后写外部终态 sidecar。

#### 16.2 forbidden 审计

禁止模式放在冻结的 `assets/forbidden-patterns.txt`，审计命令只引用文件名，不在 xtrace 参数中展开模式。至少覆盖：

- 根级 `/tmp/` 写入；
- sudo、fio、mount、Ceph、TiKV、S3、生产 Redis；
- commit、push、fork、GitHub 写 API、issue/PR 写命令；
- `git apply --recount/--3way/--reject`；
- 非本轮 container ID 的 stop/kill/rm/prune；
- 修改历史 OUT 或 SOURCE。

保存 `forbidden-raw.log` 和经明确 allowlist 解释后的 `forbidden-real.log`。任何 real 命中即 `execution_audit=NO`。不得按“看起来没事”豁免。

#### 16.3 anchor 与 adaptations

先 `record_anchor C03R1_ANCHOR:AUDIT` 完成审计，再 `record_anchor C03R1_ANCHOR:PACKAGE`，关闭 xtrace。随后：

- `cmp anchors.expected anchors.actual` rc=0；
- 两者行数都精确为 12；
- pre-run/runtime adaptations 非空且内容与日志一致；
- 不允许只写 “runner started” 冒充 runtime adaptations；没有运行期适配必须写 `NONE_AFTER_START`。

#### 16.4 final status 与 archive

先生成 24 个 required gate 的完整 `candidate-gates.tsv`，使用 §1.6 的全表算法得到 `meta/prearchive-status.txt`。任何 NO/NOT_RUN/PENDING/SKIP 都必须得到 `NOT-PR-READY`。

然后按以下顺序执行，禁止循环声明：

1. 生成并校验 `SHA256SUMS`；
2. archive 内包含 `candidate-gates.tsv` 与 `meta/prearchive-status.txt`，但不包含尚未发生的 archive PASS 声明；
3. 创建 archive 和外部 `.sha256`；
4. 从 archive 外重新计算 SHA256 并与 `.sha256` 比较；
5. 执行 `tar -tzf`，并检查要求的顶层证据均存在；
6. 写外部 `<archive>.integrity.tsv`，包含 sha256_match、tar_readable、required_members 三项，全部 YES 才算 archive integrity 通过；
7. 只有 prearchive status 为 `ALL-REQUIRED-GATES-YES` 且 integrity 三项全 YES，才写外部 `<archive>.final-status.txt` 为 `PASS-B-PR-READY-LOCAL`；否则写具体失败状态。

最终报告同时引用 archive 内的 24 gate 表和两个外部终态 sidecar。

archive 包含：

~~~text
assets artifacts community-search diffs drafts logs meta rc services
commands.sh summary.tsv candidate-gates.tsv deferred-checks.tsv SHA256SUMS
~~~

不打包 src/cache/tools/builds 大文件，但全部保留在 OUT 直到 Codex 复核结束。任一早停分支也要生成 partial archive，禁止删除现场。

---

## 五、状态判定

### 5.1 `PASS-B-PR-READY-LOCAL`

仅当 24 个 candidate required gates 全 YES，且 archive integrity 终态门全 YES。允许结论：

> 在执行时冻结的官方 main commit 上，stock 社区回归测试确定性证明完整 block 在异步 slice ID 就绪后未补派发；B 保留异步语义并修复该行为。最终两文件 patch 可从干净 clone 标准回放，并通过双工具链社区/语义/race/完整 pkg/vfs、Redis 生命周期、tidy、vet、官方 v2.6 系列 lint、Linux/lite build、本地查重与完整审计。该候选可交 Codex 和用户决定是否先创建 issue；GitHub 官方 CI 尚未运行。

### 5.2 `UPSTREAM-ALREADY-FIXED`

必须同时有 stock 测试转绿、源码等价逻辑和可能修复提交证据。禁止继续应用 B。下一步分析该官方修复对 v1.3.1 的 backport。

### 5.3 `B-PATCH-DRIFT` / `CI-MATRIX-DRIFT`

标准 apply 失败或官方 Go/lint/CI 口径变化。保存差异，等待 Codex 重写计划；GLM 不得自行 rebase 或换工具版本。

### 5.4 `LINT-INFRA-BLOCKED` / `LINT-FAIL`

- 下载/安装/网络导致无法运行：INFRA-BLOCKED；
- lint 实际发现问题或 timeout：LINT-FAIL。

两者均不得 PR-ready，也不得把 lint 留给官方 CI 后继续。

### 5.5 `FULL-VFS-FAIL` / `BUILD-FAIL` / `SEARCH-BLOCKED`

保留完整失败，不挑选重跑。修复 runner/基础设施后必须新 input + 新 OUT。

### 5.6 `NON-COMPLIANT`

包括但不限于：runner 原地修改、旧 OUT 未保留、手工补跑、gate 硬编码、anchor/forbidden 自匹配、历史路径被改、adaptations 不实。技术测试全绿也不能豁免。

---

## 六、GLM 交付物

报告落点：

~~~text
prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R1-execution-YYYYmmdd-HHMMSS.md
~~~

报告必须逐项提供：

1. input/OUT/archive/archive.sha256 的绝对路径和 SHA；
2. frozen upstream commit、ls-remote 前后、FETCH_HEAD、commit show、祖先/距离；
3. 官方政策/CI 文件快照、解析结果与 hash；
4. 三个固定输入与 runner/taskbook/input SHA；
5. stock 单项与 40 份 repeat 原始日志/TSV；
6. B 单项、count100、race20 的精确 PASS 计数；
7. Q 十项单项、count100、race20 的精确 PASS 计数；
8. 双工具链完整 pkg/vfs；
9. 两个 Redis 容器的 image/run/PONG/inspect/log/stop/不存在证明；
10. gofmt/license/diff/tidy/vet 全证据；
11. lint 版本查询、安装、version、binary SHA、全仓 log/rc；
12. 双工具链四个 build、版本与产物 SHA；
13. 最终 patch、SHA、B/R diff cmp 和 replay 测试；
14. 六组 GitHub 请求的 request/time/header/status/body/rc/validation；
15. 本地 Git history 与 candidates.tsv；
16. 三份草稿和真实性/脱敏扫描；
17. 四臂和 SOURCE/history before/after 守卫；
18. `candidate-gates.tsv` 24 个 gate 全文与全表计算命令；
19. `deferred-checks.tsv`；
20. runner、commands、完整 xtrace、anchors exact cmp、forbidden raw/real；
21. pre-run/runtime adaptations 全文及所有失败 input/OUT 列表；
22. SHA256SUMS 校验、archive 列表/hash、integrity 与 final-status 外部 sidecar；
23. `src/cache/tools/builds` 保留声明；
24. 明确声明未执行任何社区写操作。

GLM 不得自行决定提交、不创建下一任务、不删除任何 OUT。

---

## 七、红线汇总

1. 禁止修改 SOURCE、C02/C03 input/OUT/archive/report。
2. 禁止复用旧 src/cache/tools/log/rc 或旧 PASS 作为本轮结果。
3. runner 首次启动后禁止原地修改；修复必须新 input + 新 OUT。
4. 禁止删除或只保留失败 OUT 的 cache。
5. 禁止 gate 默认 YES、硬编码 YES 或漏门 PASS。
6. `B_lint` 不是 YES 时绝对禁止 PR-ready。
7. 禁止 anchor/forbidden 审计匹配检查命令自身。
8. 禁止 `|| true` 伪造 curl/tidy/Docker/测试 rc。
9. 禁止 patch recount、3-way、reject、手工 rebase。
10. 禁止修改测试名、断言、等待窗口、次数和固定资产。
11. 禁止接触已有 6379 服务或非本任务容器，禁止 prune。
12. 禁止根级 `/tmp/`、sudo、系统包安装。
13. 禁止 fio、mount、生产 Redis/Ceph/TiKV/S3 和性能测试。
14. 禁止 commit、push、fork、issue/PR 写操作和 GitHub 写 API。
15. 禁止草稿声称未运行的测试已通过。
16. 禁止把内部 C02 测试纳入最终 patch。
17. 禁止最终 patch 超出 writer.go 与 writer_flush_test.go。
18. 任一控制变量、官方 CI 口径或源码接口需要变化，停止等待 Codex。

---

## 附录 A：固定资产来源

本任务不重新定义测试语义。三个输入从以下只读路径复制：

~~~text
/home/lilingfeng/tmp/juicefs-c03-20260817-100609/assets/writer_flush_test.go
/home/lilingfeng/tmp/juicefs-c03-20260817-100609/assets/writer_flush_c02_test.go
/home/lilingfeng/tmp/juicefs-c03-20260817-100609/assets/async-catchup-main.patch
~~~

复制后只接受 §2.1 的 SHA256。也可从 C03/C02 任务书附录逐字提取，但不得混用不同来源后修改内容。

对应任务书：

~~~text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C03-upstream-main-community-ci-readiness.md
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C02-main-flush-dispatch-semantics-fault-injection.md
~~~

## 附录 B：B 生产补丁语义冻结

唯一允许的生产变化是：在 `prepareID` 把非零 slice ID 设置给 writer 后，如果 slice 未 frozen 且已包含至少一个完整 block，则对当前 `slen` 做一次 catch-up `FlushTo`；失败锁存为 `syscall.EIO`。

禁止改变：

- `NewSlice` 的异步边界；
- 非 EIO 的重试次数；
- frozen slice 的收尾路径；
- `FlushTo` 阈值和 offset；
- 错误类型；
- 锁边界。

任何需要语义重写的 upstream 漂移都不是 GLM 自主适配范围。

## 附录 C：C03 已知搜索候选

C03 的六组查询曾返回以下非零候选，C03-R1 必须重新搜索并保留，不得直接判重复或不重复：

~~~text
issue #1250  I/O Error when minio io depay 1s
issue #6398  Would it be feasible to reduce the scope of the openfile lock...
issue #5038  Data corruption: zeroes are sometimes written instead of the actual data
issue #6049  Bad DIO write performance when mount with option async_dio
PR    #7202  fuse: experimental write-path FUSE passthrough (WIP)
PR    #2160  translate io_processing.md
~~~

标题相似度不是结论；Codex 将根据 body、源码路径、因果和修复内容作最终判重。
