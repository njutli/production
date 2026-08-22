# C03：最新上游 main 集成、社区回归测试与本地 CI 就绪验证

> 面向执行方：GLM  
> 方案与结果复核：Codex  
> 日期：2026-08-17  
> 性质：社区提交前的隔离源码验证；不占 03 阶段性能任务编号  
> 上游：`https://github.com/juicedata/juicefs` 的执行时 `main`，fetch 后冻结精确 commit  
> C02 基准提交：`edabf9c24601510476e7453abff177f4aaca07ac`  
> 工具链：Go 1.25.7 与 Go 1.26.0；若上游 CI 矩阵发生变化则停止，不自行改版本  
> 工作根目录：`/home/lilingfeng/tmp`；禁止使用根级 `/tmp/`  
> 允许的外部动作：只读 fetch/查询、必要时拉取并运行一次性 Redis 容器  
> 禁止：创建/评论 issue、创建 PR、commit、push、修改 fork、性能测试、生产部署。

---

## ⚑ 计划线

~~~text
C01-R1
  └─ 固定 main 上确定性证明漏派发，A/B 均覆盖最小行为
  ↓
C02
  ├─ B：修复、兼容、故障、freeze、并发与 race 全门通过
  ├─ A：确认同步阻塞与非 EIO 额外 NewSlice 尝试
  └─ Codex 复核：B 成为唯一社区候选；审计误报获有条件豁免
  ↓
★ C03（你在这里）
  ├─ 从官方远端重新冻结最新 main
  ├─ 先判定上游是否已自行修复
  ├─ 生成 B + 社区风格最小回归测试的最终 patch
  ├─ C02 全语义 QA、干净回放、完整 pkg/vfs、lint/build
  └─ 只读查重 + issue/PR 草稿，不执行社区写操作
  ↓
  ├─ PASS-B-PR-READY-LOCAL：交 Codex/用户决定 issue 与 PR
  ├─ UPSTREAM-ALREADY-FIXED：定位上游修复，转 backport 分析
  └─ DRIFT/FAIL/BLOCKED：停止，禁止提交社区
~~~

一句话：在执行时最新的官方 main 上，把 B 变成可干净回放、带最小回归测试、通过相关本地 CI 的社区候选，同时保留“上游已自行修复”这一优先分支。

---

## 〇、背景与前置裁定

### 0.1 C02 的正式承接状态

C02 原始报告：

~~~text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C02-execution-20260817-015425.md
~~~

Codex 对 C02 OUT、archive、SHA256、58 条结果、100 份预期失败日志、count/race 日志、源码 diff 和 4594 行 xtrace 做了只读复核，裁定：

~~~text
C02-REVIEWED = PASS-B-COMMUNITY-CANDIDATE / AUDIT WAIVER
~~~

依据：

1. B 在 Go 1.25.7/1.26.0 下十项单测、各 `count=100`、各 `-race count=20` 全部通过；
2. A 的同步阻塞和非 EIO 额外调用已经确定性确认，因此不再作为社区首选；
3. C02 的审计 NO 是 forbidden grep 匹配到审计命令自身；排除该行后没有真实禁令命令；
4. C02 仍有真实的文档缺口：`meta/dependency-adaptations.txt` 为空，而报告列了五项运行前 runner/网络适配。

C03 不改写 C02 的任何文件或归档。runner 必须把上述裁定和文档缺口写进本轮 `meta/preflight.txt`，并在本轮使用强制非空的适配记录文件。

### 0.2 为什么 C03 必须重新 fetch

C01/C02 固定的是 2026-08-14 的 main commit。社区提交必须基于执行时官方 `main`，不能假定：

- `writer.go` 上下文仍未变化；
- 上游没有在 C02 之后合入等价修复；
- `go.mod`、`verify.yml`、lint 版本和测试约定仍相同；
- C02 的 patch 能直接应用。

因此 C03 第一门不是“把 B 再跑一次”，而是先冻结远端 main 并重新判定问题是否存在。

### 0.3 官方贡献与 CI 口径

执行时必须从冻结的上游 commit 保存并阅读：

- `CONTRIBUTING.md`；
- `.github/workflows/verify.yml`；
- `.github/workflows/unittests.yml`；
- `.github/actions/build/action.yml`；
- `.golangci.yml`、`go.mod`、`Makefile`。

写任务书时，官方口径为：

- PR 应带单元测试、遵循 Go 风格、具有解释性 commit message；
- 通常先搜索现有 issue/PR，PR 应链接 issue；
- `verify.yml` 使用 Go 1.25/1.26，golangci-lint `v2.6`；
- `unittests.yml` 的 `test.pkg` 依赖大量服务，C03 不在开发机复刻全部服务，只运行受影响的完整 `pkg/vfs`，官方完整矩阵留给后续真实 PR CI。

若执行时这些事实改变，状态为 `CI-MATRIX-DRIFT`，停止并交 Codex 修订任务书。

---

## 一、目标、唯一推进门与非目标

### 1.1 Q0：执行时最新 main 是否仍有缺陷

从官方远端冻结 `UPSTREAM_COMMIT` 后，使用最终社区测试文件验证 stock：

- 完整 block 测试必须以指定信息失败；
- partial block 负控必须通过；
- catch-up FlushTo 错误测试必须以指定信息失败。

并检查 `writer.go` 是否仍是“异步 prepareID + write 时 `id>0` 才 FlushTo、ID 就绪后不补派发”的结构。

分支：

| 结果 | 状态 | 动作 |
|---|---|---|
| stock 两个正控按预期失败 | `UPSTREAM-AFFECTED` | 继续 B |
| stock 正控通过且源码已有等价逻辑 | `UPSTREAM-ALREADY-FIXED` | 停止 B，定位提交并归档 |
| 源码/测试呈混合或无法解释 | `UPSTREAM-ORACLE-DRIFT` | 停止，交 Codex |

### 1.2 Q1：最终社区 patch 是否自证修复

最终候选只允许包含：

~~~text
pkg/vfs/writer.go
pkg/vfs/writer_flush_test.go
~~~

社区测试必须同时满足：

1. 在 stock 上确定性红；
2. 在 B 上全部绿；
3. 测试文件有 JuiceFS license header；
4. 不含 C01/C02/C03、DeepSeek、内部路径、内部 IP、性能环境细节；
5. 测试名和失败信息能直接表达行为契约。

### 1.3 Q2：B 在最新 main 上是否保留 C02 全语义

把 C02 的完整十项内部测试资产原样移植到最新 main 的独立 QA 臂：

- 十项单测全部 PASS；
- 两工具链各 `count=100`；
- 两工具链各 `-race count=20`；
- 无 `DATA RACE`、panic、timeout 或 build failure。

内部 C02 测试不进入最终社区 patch。

### 1.4 Q3：受影响包与官方本地门禁

B 最终候选必须通过：

- Go 1.25.7 与 1.26.0 的完整 `go test ./pkg/vfs`；
- 仅任务创建的一次性 Redis，完整测试后销毁；
- 两工具链 `go vet ./pkg/vfs`；
- 两工具链 targeted race；
- `go mod tidy` 前后 go.mod/go.sum 不变；
- `gofmt`、`git diff --check`；
- 按冻结 `verify.yml` 的 golangci-lint v2.6 系列执行；
- 两工具链 `make -B juicefs` 与 `make -B juicefs.lite`。

### 1.5 Q4：社区查重和交付草稿

只读完成：

- GitHub issue 搜索；
- GitHub PR 搜索；
- 上游 Git 历史字符串/路径搜索；
- 生成 issue、PR、commit message 草稿；
- 草稿脱敏检查。

GLM 不判断搜索结果是否构成重复，只保存原始结果并标记候选 URL，交 Codex复核。

### 1.6 唯一推进状态：`PASS-B-PR-READY-LOCAL`

必须同时满足：

1. 最新 main 仍受影响；
2. B 原补丁无需语义重写即可标准 apply；
3. 社区测试 stock 红/B 绿；
4. C02 十项语义矩阵在最新 main 全绿；
5. patch 在干净 replay 臂标准 apply 并复验；
6. 完整 pkg/vfs、vet、lint、tidy、Linux/lite build 全绿；
7. 查重请求完成并归档；
8. 源码、资产、审计和 archive 全部合规。

该状态只允许交给 Codex 和用户决定是否创建 issue/PR；它不授权 GLM 执行社区写操作。

### 1.7 明确不做

- 不运行 fio、benchmark、吞吐 AB、数据完整性 fio verify 或 soak；
- 不挂载 JuiceFS，不访问生产 Redis/Ceph/TiKV/S3；
- 不修改 v1.3.1、生产二进制或生产部署；
- 不运行完整 `make test.pkg` 的多服务官方环境；
- 不安装系统包，不使用 sudo；
- 不 commit、不 push、不创建 fork 分支；
- 不创建、评论、关闭 issue/PR；
- 不签 CLA；
- 不把本地 PASS 写成 GitHub 官方 CI 已通过。

---

## 二、固定输入、动态冻结量与四臂

### 2.1 固定输入

| 项 | 固定值 |
|---|---|
| 官方 remote | `https://github.com/juicedata/juicefs` |
| 只读本地 SOURCE | `/home/lilingfeng/project/juicefs`；只作为对象种子，禁止修改 |
| C02 base | `edabf9c24601510476e7453abff177f4aaca07ac` |
| B patch SHA256 | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` |
| C02 内部测试 SHA256 | `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` |
| C03 社区测试 SHA256 | `bce85ad4abf92a47074849a544aaa756963fb44a1839619bbc71c5d7ce1fe9bc`（附录 A 经 gofmt 后） |
| Go 主工具链 | `go1.25.7` |
| Go 兼容工具链 | `local`，必须为 `go1.26.0` |
| lint 系列 | 冻结 `verify.yml` 必须仍为 `v2.6` |
| Redis | 一次性 Docker 容器，`redis:7.2-alpine`，执行时记录 image ID/digest |
| 工作根 | `/home/lilingfeng/tmp` |

### 2.2 执行时动态冻结量

以下必须在任何源码测试之前产生：

| 量 | 文件 |
|---|---|
| 远端 main commit | `meta/upstream-commit.txt` |
| fetch 前后 ls-remote | `meta/ls-remote-before.txt`、`ls-remote-after.txt` |
| commit 时间/标题/parents | `meta/upstream-commit-show.txt` |
| C02 base 到最新 main 距离 | `meta/upstream-distance.txt` |
| go.mod directive | `meta/upstream-go-directive.txt` |
| verify Go matrix/lint | `meta/upstream-ci-matrix.txt` |
| CONTRIBUTING/CI 文件 SHA256 | `meta/upstream-policy-hashes.txt` |
| Redis image identity | `meta/redis-image.txt` |

一旦 `UPSTREAM_COMMIT` 冻结，本轮所有臂只使用该 commit。禁止测试中再次 fetch 或把“最新”漂移到另一个 commit。

### 2.3 四臂

| 臂 | 内容 | 是否进入最终 patch |
|---|---|---:|
| S-oracle | 最新 main + 社区测试，writer.go 不改 | 否 |
| B-candidate | 最新 main + B + 社区测试 | 是 |
| Q-semantic | 最新 main + B + C02 十项内部测试 | 否 |
| R-replay | 最新 main + 从 B-candidate 导出的最终 patch | 用于证明可回放 |

四臂必须是独立 clone，不得使用 worktree 共享 index，不得复制编译产物。

### 2.4 路径白名单

| 臂 | 唯一允许的 Git 变化 |
|---|---|
| S-oracle | `pkg/vfs/writer_flush_test.go` |
| B-candidate | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |
| Q-semantic | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_c02_test.go` |
| R-replay | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |

### 2.5 社区测试预注册矩阵

| ID | 测试 | S-oracle | B-candidate | R-replay |
|---|---|---|---|---|
| U1 | `TestFullBlockDispatchedWhenSliceIDBecomesReady` | FAIL：`full block was not dispatched after slice ID became ready` | PASS | PASS |
| U2 | `TestPartialBlockNotDispatchedWhenSliceIDBecomesReady` | PASS | PASS | PASS |
| U3 | `TestFlushErrorRecordedWhenSliceIDBecomesReady` | FAIL：`full block with injected flush error was not dispatched` | PASS | PASS |

两个工具链均必须符合。S 的 U1/U3 各运行 10 个独立进程；B 的三项合跑 `count=100` 和 `-race count=20`。

### 2.6 Q-semantic 矩阵

使用 C02 B 臂的十项测试全集：

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

每工具链：单项全 PASS、`count=100` 全 PASS、`-race count=20` 全 PASS。

### 2.7 唯一数据源

| 判据 | 数据源 |
|---|---|
| 上游冻结 | `meta/upstream-*.txt`、fetch/ls-remote 日志 |
| stock 分支判定 | `meta/upstream-state-gate.tsv`、S 单项/repeat 日志 |
| 社区测试矩阵 | `meta/community-results.raw.tsv`、对应 logs/rc |
| C02 全语义 | `meta/semantic-results.tsv`、count/race 日志 |
| 完整 pkg/vfs | `logs/TOOL-B-full-vfs.log`、rc、Redis identity/log |
| vet/tidy/build/lint | 对应 `logs/`、`rc/`、hash/diff guard |
| 最终 patch | `artifacts/community-candidate.patch`、SHA256 |
| replay | R-replay apply/diff/test 日志 |
| 查重 | `community-search/*.json`、请求与时间戳 |
| 草稿 | `drafts/{issue,pr,commit-message}.md` |
| 脱敏 | `logs/community-artifact-secret-scan.log` |
| 执行审计 | runner、commands、xtrace、anchor/forbidden guard |
| 完整性 | `SHA256SUMS`、archive 与 archive.sha256 |

---

## 三、安全、网络、容器与授权边界

### 3.1 全新 OUT 与输入目录

必须创建：

~~~text
/home/lilingfeng/tmp/juicefs-c03-input-YYYYmmdd-HHMMSS/
/home/lilingfeng/tmp/juicefs-c03-YYYYmmdd-HHMMSS/
~~~

输入目录必须包含并冻结：

~~~text
run-c03.sh
writer_flush_test.go
writer_flush_c02_test.go
async-catchup-main.patch
pre-run-adaptations.md
input.sha256
~~~

`pre-run-adaptations.md` 必须存在且非空：没有适配写 `NONE`；runner 编写、依赖下载或前序失败尝试都必须记录。OUT 内另建 `meta/runtime-adaptations.md`，同样不得为空。

禁止复用 C02 的源码 clone、缓存和结果。允许从 C02 任务书或已验证 archive 提取 **B patch 与内部测试输入**，但只有 SHA256 精确匹配 §2.1 才能使用。

### 3.2 唯一 runner 与留痕

与 C02 相同，所有动作必须由冻结的 `run-c03.sh` 完成：

1. input SHA256 校验；
2. OUT 初始化后立即开启 xtrace；
3. fetch、clone、patch、测试、Docker、查询、打包全部进入 runner；
4. `commands.sh` 保存实际 runner 调用与全部无密钥环境覆盖；
5. runner 外手工补跑使当前 OUT `NON-COMPLIANT`；
6. runner 修复后必须换新 OUT，旧 OUT 保留并在 pre-run adaptations 指名。

### 3.3 上游网络规则

允许：

- 对固定官方 URL 执行 `git ls-remote`、`git fetch origin main`；
- 对 GitHub Search API 执行匿名只读 GET；
- 下载 Go 模块、Go 工具链、golangci-lint v2.6 系列；
- 必要时拉取 `redis:7.2-alpine`。

禁止：

- 使用带写权限的 GitHub token；
- 把任何 token、cookie、Authorization header 写入日志；
- push、fork、API POST/PATCH/PUT/DELETE；
- fetch 任意 PR head 或执行搜索结果中的代码；
- 改 SOURCE 的 remote/ref/config。

### 3.4 Redis 容器规则

完整 pkg/vfs 测试只允许使用任务创建的一次性 Redis：

1. 先证明宿主 `127.0.0.1:6379` 未监听；若占用，停止并标 `REDIS-PORT-BLOCKED`，禁止连接、清库或杀进程；
2. 容器名必须含 RUN_ID，保存 container ID；
3. 只绑定 `127.0.0.1:6379:6379`；
4. 不挂宿主 volume，数据目录用容器 tmpfs；
5. 禁 privileged、host network、sudo；
6. 每个工具链创建全新容器，测试结束停止精确 container ID；
7. trap 在任何退出路径停止本任务容器；
8. 禁止 `docker system prune`、删除其他容器/镜像/volume。

允许的参考形态：

~~~bash
docker run -d --rm \
  --name "juicefs-c03-redis-${RUN_ID}-${TOOL}" \
  --label "juicefs.c03.run=${RUN_ID}" \
  -p 127.0.0.1:6379:6379 \
  --tmpfs /data \
  redis:7.2-alpine \
  redis-server --save '' --appendonly no
~~~

### 3.5 自主修复与必须停止

可自主修复并记录：

- GOPROXY、证书、只读 API 重试；
- runner 的日志/路径/退出码采集 bug；
- Docker pull 重试；
- lint 工具 v2.6 系列内的补丁版本解析。

必须停止，禁止 GLM 自行修改：

- B patch 不能标准 apply；
- 社区测试与最新接口不兼容；
- go.mod 或 verify CI 矩阵变化；
- 测试名/等待窗口/断言需要改变；
- stock oracle 不符合预注册分支；
- 为通过 lint/test 而改生产代码或测试；
- 任何最终 patch 超出两条路径。

---

## 四、执行步骤

### 步骤 0：通读、输入冻结与 preflight

完整阅读：

1. 本任务书；
2. C02 任务书与原始报告；
3. C02 Codex 复核裁定（本任务 §0.1）；
4. `prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.8、§二.9、§二.11；
5. `prod-deploy/skills/SYSTEM-SAFETY-SKILL.md`；
6. fetch 后冻结 commit 的 CONTRIBUTING 和 CI 文件。

输入准备：

- 附录 A 保存为 `writer_flush_test.go`，执行一次 gofmt；
- C02 附录 A 保存为 `writer_flush_c02_test.go`，执行一次 gofmt；
- C02 附录 B 保存为 `async-catchup-main.patch`；
- 核验三个固定 SHA256；
- runner 与 pre-run adaptations 冻结后生成 `input.sha256`；
- `bash -n run-c03.sh`。

preflight 必须写明：C02 reviewer waiver、C02 空 adaptations 缺口、B 是唯一社区候选、允许 fetch/匿名搜索/一次性 Redis、禁止社区写操作。

### 步骤 1：OUT、xtrace、trap 与磁盘门

至少需要 30 GiB 可用空间。设置：

~~~bash
export TMPDIR="$OUT/cache/os-tmp"
export GOTMPDIR="$OUT/cache/go-tmp"
export GOMODCACHE="$OUT/cache/go-mod"
export GOPROXY="${C03_GOPROXY:-https://goproxy.cn,direct}"
~~~

创建 `assets artifacts cache community-search diffs drafts logs meta rc services src tools`。复制全部 input 与任务书快照。

开启：

~~~bash
exec 19>>"$OUT/logs/shell-xtrace.log"
export BASH_XTRACEFD=19
PS4='+C03 ${BASH_SOURCE##*/}:${LINENO}: '
set -x
printf '%s\n' 'C03_ANCHOR:INIT'
~~~

trap 只能停止本轮记录的 Redis container ID、写 final status 并做 partial archive；不得删除 OUT 或其他资源。

### 步骤 2：只读冻结官方 main

在 OUT 内先 clone 本地对象库，再把该隔离 clone 的 origin 校正为官方 URL。不得修改 SOURCE：

~~~bash
printf '%s\n' 'C03_ANCHOR:FETCH'
git clone --no-hardlinks --no-checkout "$SOURCE" "$OUT/src/upstream-fetch"
git -C "$OUT/src/upstream-fetch" remote set-url origin \
  https://github.com/juicedata/juicefs
git -C "$OUT/src/upstream-fetch" remote -v
git ls-remote https://github.com/juicedata/juicefs refs/heads/main
git -C "$OUT/src/upstream-fetch" fetch --no-tags origin main
~~~

fetch 后再次 `ls-remote`。要求 `FETCH_HEAD` 等于 fetch 后远端 main；若 fetch 窗口内发生漂移，最多整体重试两次，最终只冻结一个 commit并记录全部尝试。

必须验证：

~~~bash
git -C "$OUT/src/upstream-fetch" cat-file -e "$UPSTREAM_COMMIT^{commit}"
git -C "$OUT/src/upstream-fetch" merge-base --is-ancestor \
  "$C02_BASE" "$UPSTREAM_COMMIT"
~~~

若非祖先，标 `UPSTREAM-HISTORY-DIVERGED` 停止。

保存上游政策/CI 文件和哈希；解析并要求：

- go.mod 仍为 Go 1.25 系；
- verify build matrix 仍含 1.25/1.26；
- lint 仍为 v2.6 系。

### 步骤 3：建立四个固定 commit clone

从 `upstream-fetch` 创建 S/B/Q/R 四个 `--no-hardlinks --no-checkout` clone，全部 detach 到 `UPSTREAM_COMMIT`。保存 before HEAD/status，要求干净。

禁止 R-replay 提前注入任何文件；它必须保持全净直到最终 patch 导出。

### 步骤 4：静态上游状态与冲突门

在 S-oracle 保存：

- `pkg/vfs/writer.go` 完整文件和 C02 base→latest diff；
- `prepareID`、`writeChunk`、`FlushTo`、`SetID` 上下文；
- `git log C02_BASE..UPSTREAM_COMMIT -- pkg/vfs/writer.go`；
- `git log -S 's.writer.SetID(s.id)'` 和 `-S 's.writer.FlushTo(int(s.slen))'`；
- 目标测试名、helper 名和 `writer_flush_test.go` 是否冲突。

任何同名文件/测试/helper 冲突都停止 `TEST-ASSET-CONFLICT`，禁止重命名继续。

### 步骤 5：注入社区测试并判定 stock

只向 S-oracle 复制社区测试，hash 必须等于固定值。`git add -N` 仅用于 diff 可见性。

两个工具链分别：

1. `go test ./pkg/vfs -run '^$' -count=1` 编译门；
2. U2 单项必须 PASS；
3. U1/U3 单项必须按指定信息 FAIL；
4. U1/U3 各十个独立进程，全部同样 FAIL；
5. 日志不得出现 build failed、panic、fatal、timeout 或 DATA RACE。

生成 `meta/upstream-state-gate.tsv`。

如果 U1/U3 都 PASS，先检查源码是否已有等价补派发：确认后输出 `UPSTREAM-ALREADY-FIXED`，定位可能提交、完成 partial archive，**不得应用 B**。

### 步骤 6：B 标准 apply 与社区候选

只有 `UPSTREAM-AFFECTED` 才执行：

~~~bash
printf '%s\n' 'C03_ANCHOR:APPLY_B'
git -C "$OUT/src/B-candidate" apply --check \
  "$OUT/assets/async-catchup-main.patch"
git -C "$OUT/src/B-candidate" apply \
  "$OUT/assets/async-catchup-main.patch"
~~~

禁止 `--recount`、3-way、reject、手工编辑。如果不能标准 apply，状态 `B-PATCH-DRIFT`，保存上下文后停止。

随后复制社区测试、gofmt、hash。两个工具链运行：

- U1/U2/U3 单项；
- 三项合跑 `count=100`；
- 三项合跑 `-race count=20`；
- 每个测试 PASS 行数必须精确；
- race 无 DATA RACE。

### 步骤 7：Q-semantic 全语义回归

Q-semantic 标准 apply 同一 B patch，只复制固定 SHA 的 C02 内部测试。两个工具链分别运行：

1. 十项各单独一次；
2. 十项 `count=100`；
3. 十项 `-race count=20`；
4. 每测试 PASS 数量精确为 100/20；
5. 无 panic、timeout、build failure 或 DATA RACE。

禁止把内部测试合入 B-candidate 或最终 patch。

### 步骤 8：完整 pkg/vfs + 一次性 Redis

先记录 Docker version/context，只允许默认本地 daemon。若宿主 6379 已监听，停止，不得使用已有服务。

必要时 pull `redis:7.2-alpine`，记录 image ID、RepoDigests、创建时间。每工具链：

1. 创建独立 Redis 容器；
2. 用 `docker exec <id> redis-cli ping` 轮询，必须 PONG；
3. 确认映射仅为 `127.0.0.1:6379`；
4. 在 B-candidate 运行：

~~~bash
go test ./pkg/vfs -count=1 -v -timeout=15m
~~~

5. 保存 Redis log、inspect、go test rc；
6. 停止精确 container ID并确认容器不存在；
7. 第二工具链使用全新容器。

完整 pkg/vfs 任一失败都不得归因于 B；先报告具体测试。如果是已知 upstream flaky，仍记 `FULL-VFS-FAIL`，由 Codex判断，GLM 不重跑挑结果。

### 步骤 9：tidy、vet、lint 与构建

在 B-candidate 执行并记录：

#### 9.1 gofmt/diff

- `gofmt -d` 对两条变更路径必须无输出；
- `git diff --check` rc=0；
- 测试 license header 存在；
- `go.mod/go.sum` 当前 hash 固定。

#### 9.2 go mod tidy

分别用 Go 1.25.7 与 Go 1.26.0 执行 `go mod tidy`。每次前后 `go.mod/go.sum` hash 必须相同；任何变化立即停止并保存 diff。

#### 9.3 vet

两个工具链分别：

~~~bash
go vet ./pkg/vfs
~~~

#### 9.4 golangci-lint

从冻结 `verify.yml` 读取 v2.6 系列。若本机无工具，在 `$OUT/tools` 中只读查询该 module 的版本列表，选择最高 v2.6.x，安装到 `$OUT/tools/bin`，记录 module version 与二进制 SHA256。

使用 Go 1.25.7，从 B-candidate 仓库根运行与官方等价的全仓 lint；不得只 lint 新文件后宣称官方 lint 通过。

#### 9.5 Linux 与 lite build

两个工具链分别运行：

~~~bash
make -B juicefs
./juicefs version
make -B juicefs.lite
./juicefs.lite version
~~~

分别保存日志、rc、版本和产物 SHA256。C03 不运行 Windows/Ceph/FDB build，并在报告列为“官方 CI 待跑”，不能写 PASS。

### 步骤 10：导出最终 patch 与干净 replay

先对 B-candidate 做路径、HEAD、测试 hash、生产 diff 门禁。然后：

~~~bash
git -C "$OUT/src/B-candidate" diff --binary --full-index -- \
  pkg/vfs/writer.go pkg/vfs/writer_flush_test.go \
  > "$OUT/artifacts/community-candidate.patch"
sha256sum "$OUT/artifacts/community-candidate.patch"
~~~

R-replay 必须在此之前保持 clean。执行标准 `git apply --check` 和 `git apply`，禁止其他模式。随后核验：

- R diff 与 B-candidate diff 逐字节一致；
- 两条路径完全一致；
- 两工具链 U1/U2/U3 PASS；
- 两工具链三项合跑 `count=20`；
- `git diff --check`、test hash、HEAD 通过。

### 步骤 11：只读社区查重

先检查 CONTRIBUTING 的搜索/issue要求。匿名 GET 查询至少覆盖：

~~~text
repo:juicedata/juicefs is:issue prepareID FlushTo
repo:juicedata/juicefs is:pr prepareID FlushTo
repo:juicedata/juicefs is:issue "slice ID" writer flush
repo:juicedata/juicefs is:pr "full block" FlushTo
repo:juicedata/juicefs is:issue random write flush block
repo:juicedata/juicefs is:pr random write flush block
~~~

每次保存：请求时间、HTTP status、rate-limit headers、完整 JSON。不得使用认证 token；不得调用写 API。

同时保存本地 Git history 搜索。GLM 只列出匹配 URL、标题、状态和更新时间，不下“重复/不重复”结论。

查询失败不影响源码测试，但状态必须为 `COMMUNITY-SEARCH-BLOCKED`，不能输出 PR-ready。

### 步骤 12：生成社区草稿与脱敏门

根据附录 C 生成：

~~~text
drafts/issue.md
drafts/pr.md
drafts/commit-message.md
~~~

草稿必须：

- 只讲可公开复现的源码行为和合成单元测试；
- 明确 main 上是确定性漏派发行为，不夸大为所有环境必然吞吐崩塌；
- 说明 B 保留异步 NewSlice；
- 列出本地测试事实与仍待官方 CI；
- 不含内部机器、IP、路径、凭据、客户/生产信息、DeepSeek/GLM/Codex 名称。

对最终 patch 与三个草稿做 secret/internal scan。任何命中先保存原扫描结果并停止，禁止 GLM自行改措辞后继续。

### 步骤 13：源码与社区候选门禁

保存四臂 after HEAD/status/full diff/diff-stat/changed paths。必须：

- HEAD 全等于 `UPSTREAM_COMMIT`；
- 变化路径等于 §2.4；
- B/R 社区测试逐字一致；
- B/Q/R 的 writer.go 生产 diff 等价；
- B 与 R 最终两路径 diff 逐字一致；
- B 生产代码不含内部标识或测试分支；
- Q 的内部测试不出现在最终 patch；
- go.mod/go.sum/vendor 无变化。

### 步骤 14：candidate-gates 与执行审计

`candidate-gates.tsv` 至少包含：

~~~text
upstream_freeze
upstream_stock_oracle
B_community_tests
B_semantic_suite
B_full_vfs
B_targeted_race
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

xtrace anchors：

~~~text
C03_ANCHOR:INIT
C03_ANCHOR:FETCH
C03_ANCHOR:STOCK_ORACLE
C03_ANCHOR:APPLY_B
C03_ANCHOR:SEMANTIC
C03_ANCHOR:FULL_VFS
C03_ANCHOR:LINT_BUILD
C03_ANCHOR:REPLAY
C03_ANCHOR:COMMUNITY_SEARCH
C03_ANCHOR:SOURCE_GUARD
C03_ANCHOR:AUDIT
C03_ANCHOR:PACKAGE
~~~

审计器必须排除其自身命令行后再匹配禁止项，并把“原始命中”和“排除审计器后的真实命中”分成两个文件。禁止像 C02 一样以非空原始命中直接判 NO。

真实禁止项至少检查：根级 `/tmp/`、sudo、commit、push、GitHub 写 API、issue/PR 创建命令、非本任务容器操作、mount/fio/Ceph/TiKV/S3、补丁 `--recount/--3way/reject`。

`pre-run-adaptations.md` 与 `runtime-adaptations.md` 任何一个为空即 audit FAIL。

### 步骤 15：合规复核、冻结与归档

先按步骤 0 的两份项目规范逐项复核并写入 `meta/final-compliance-review.md`：

- SOURCE、现有 worktree、C02 OUT/archive 均未变化；
- 没有 sudo、根级 `/tmp/`、生产访问、社区写操作或越权 Docker 操作；
- 所有判据均能回溯到 §2.7 指名的数据源；
- 所有工程适配均进入两个非空 adaptations 文件；
- 本任务不含 fio、mount、卷清理、Ceph/OSD 操作，性能测试专属 skill 条款明确记为 `N/A`，不得伪造对应证据。

任一不符先落盘并将状态置为 `NON-COMPLIANT`，不得输出 PR-ready。

写 `C03_ANCHOR:PACKAGE` 后完成 final metadata，再关闭 xtrace并归档：

~~~text
assets artifacts community-search diffs drafts logs meta rc
commands.sh summary.tsv candidate-gates.tsv SHA256SUMS
~~~

不归档 src/cache/tools 二进制体，但 OUT 中保留到 Codex复核完成。`SHA256SUMS` 全部校验，archive 另生成 `.sha256`。任何早停分支也生成 partial archive。

---

## 五、状态判定

### 5.1 `PASS-B-PR-READY-LOCAL`

§1.6 全部满足，且没有合规否项。允许结论：

> 在执行时冻结的官方 main commit 上，stock 社区回归测试确定性证明完整 block 在异步 slice ID 就绪后未补派发；B 保留原异步调用语义并覆盖该行为。最终两文件 patch 可从干净 clone 标准回放，并通过双工具链语义、完整 pkg/vfs、race、vet、tidy、lint、Linux/lite build 本地门禁。候选可交由项目方决定是否先建 issue并提交 PR；GitHub 官方 CI 尚未执行。

### 5.2 `UPSTREAM-ALREADY-FIXED`

必须有 stock 测试通过、源码等价逻辑和可能修复提交三类证据。不得继续应用 B。下一步由 Codex分析上游修复能否 backport 到 v1.3.1。

### 5.3 `B-PATCH-DRIFT` / `CI-MATRIX-DRIFT`

最新 main 或官方 CI 已变化，旧任务不能机械继续。保存差异，等待 Codex重写 patch/任务书。

### 5.4 `FULL-VFS-FAIL` / `LINT-BUILD-FAIL`

目标测试可能通过，但社区本地质量门不完整。不得输出 PR-ready，不得挑选重跑结果。

### 5.5 `COMMUNITY-SEARCH-BLOCKED` / `DUPLICATE-REVIEW-REQUIRED`

- 查询未完成：BLOCKED；
- 存在可能重复项：本地技术门可记通过，但整体等待 Codex人工判重。

### 5.6 `NON-COMPLIANT` / `BLOCKED`

审计否项或基础设施阻塞。两者均不允许进入社区写操作。

---

## 六、GLM 交付物

必须交付：

1. OUT、archive、archive.sha256 绝对路径与 SHA256；
2. frozen upstream commit、时间、标题、parents、ls-remote 前后结果；
3. 上游 CI/贡献文件快照与 hash；
4. upstream state gate 全文；
5. 社区单测单项、repeat10、count100、race20 全部日志/rc；
6. Q-semantic 十项、count100、race20 全部日志/计数；
7. 两工具链完整 pkg/vfs 日志；
8. Redis image/container identity、inspect、log、清理证明；
9. tidy/vet/lint/build 全部日志与产物版本/hash；
10. community-candidate.patch 与 SHA256；
11. replay apply/diff/test 证据；
12. GitHub 搜索原始 JSON、headers 与候选 URL 列表；
13. issue/PR/commit-message 草稿与脱敏扫描；
14. 四臂 before/after HEAD、status、full diff、path guards；
15. `summary.tsv`、`candidate-gates.tsv`；
16. runner、commands、完整 xtrace、anchor/forbidden 审计；
17. pre-run/runtime adaptations 全文；
18. 所有预期外失败全文；
19. OUT/src/cache/tools 保留声明。

报告落点：

~~~text
prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-execution-YYYYmmdd-HHMMSS.md
~~~

GLM 不选择是否提交、不修改草稿、不创建下一任务。

---

## 七、红线汇总

1. 禁止修改 SOURCE、现有 worktree、C02 OUT/archive。
2. 禁止使用根级 `/tmp/`、sudo、系统包安装。
3. 禁止 commit、push、fork、issue/PR 写操作或任何 GitHub 写 API。
4. 禁止在 freeze 后再次漂移 upstream commit。
5. 禁止 B patch 的 recount、3-way、reject 或手工 rebase。
6. 禁止修改社区测试、C02 内部测试、marker、等待窗口、次数。
7. 禁止接触已有 6379 服务；端口占用即停止。
8. 禁止操作非本任务 Docker container/image/volume，禁止 prune。
9. 禁止 fio、mount、生产 Redis/Ceph/TiKV/S3、性能和生产测试。
10. 禁止把内部 C02 测试纳入最终 patch。
11. 禁止最终 patch 超过 writer.go 与 writer_flush_test.go。
12. 禁止把本地门禁写成官方 GitHub CI PASS。
13. 禁止遗漏任何适配、失败、搜索匹配或审计命中。
14. 任一控制变量需要变化，停止等待 Codex。

---

## 附录 A：社区候选测试 `pkg/vfs/writer_flush_test.go`

必须逐字保存并 gofmt。该文件是最终社区 patch 的一部分。

```go
/*
 * JuiceFS, Copyright 2020 Juicedata, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

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
)

const flushDispatchBlockSize = 256 << 10

type delayedSliceMeta struct {
	meta.Meta
	called  chan struct{}
	release chan struct{}
	once    sync.Once
}

func newDelayedSliceMeta() *delayedSliceMeta {
	return &delayedSliceMeta{
		called:  make(chan struct{}),
		release: make(chan struct{}),
	}
}

func (m *delayedSliceMeta) NewSlice(_ meta.Context, id *uint64) syscall.Errno {
	m.once.Do(func() { close(m.called) })
	<-m.release
	*id = 1
	return 0
}

type recordingChunkWriter struct {
	mu        sync.Mutex
	id        uint64
	idSet     chan struct{}
	idOnce    sync.Once
	flushes   chan int
	flushErr  error
	finishes  int
	abortions int
}

func newRecordingChunkWriter(flushErr error) *recordingChunkWriter {
	return &recordingChunkWriter{
		idSet:    make(chan struct{}),
		flushes:  make(chan int, 4),
		flushErr: flushErr,
	}
}

func (w *recordingChunkWriter) WriteAt(p []byte, _ int64) (int, error) {
	return len(p), nil
}

func (w *recordingChunkWriter) ID() uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.id
}

func (w *recordingChunkWriter) SetID(id uint64) {
	w.mu.Lock()
	w.id = id
	w.mu.Unlock()
	w.idOnce.Do(func() { close(w.idSet) })
}

func (w *recordingChunkWriter) SetWriteback(bool) {}

func (w *recordingChunkWriter) FlushTo(offset int) error {
	w.flushes <- offset
	return w.flushErr
}

func (w *recordingChunkWriter) Finish(int) error {
	w.mu.Lock()
	w.finishes++
	w.mu.Unlock()
	return nil
}

func (w *recordingChunkWriter) Abort() {
	w.mu.Lock()
	w.abortions++
	w.mu.Unlock()
}

type singleWriterStore struct {
	writer chunk.Writer
}

func (s *singleWriterStore) NewReader(uint64, int) chunk.Reader { return nil }

func (s *singleWriterStore) NewWriter(uint64, uint8) chunk.Writer { return s.writer }

func (s *singleWriterStore) Remove(uint64, int) error { return nil }

func (s *singleWriterStore) FillCache(uint64, uint32) error { return nil }

func (s *singleWriterStore) EvictCache(uint64, uint32) error { return nil }

func (s *singleWriterStore) CheckCache(uint64, uint32, func(bool, string, int)) error {
	return nil
}

func (s *singleWriterStore) UsedMemory() int64 { return 0 }

func (s *singleWriterStore) UpdateLimit(int64, int64) {}

func (s *singleWriterStore) BlobStorage() object.ObjectStorage { return nil }

type flushDispatchHarness struct {
	file   *fileWriter
	slice  *sliceWriter
	writer *recordingChunkWriter
}

func writeSliceWithDelayedID(t *testing.T, size int, flushErr error) *flushDispatchHarness {
	t.Helper()

	m := newDelayedSliceMeta()
	writer := newRecordingChunkWriter(flushErr)
	w := &dataWriter{
		m:         m,
		store:     &singleWriterStore{writer: writer},
		blockSize: flushDispatchBlockSize,
	}
	f := &fileWriter{
		w:      w,
		inode:  2,
		chunks: make(map[uint32]*chunkWriter),
	}
	c := &chunkWriter{indx: 0, file: f}
	// Keep commitThread out of this dispatch-only test.
	c.slices = []*sliceWriter{{
		chunk:   c,
		off:     8 * flushDispatchBlockSize,
		slen:    flushDispatchBlockSize,
		freezed: true,
	}}
	f.chunks[0] = c

	go func() {
		<-m.called
		close(m.release)
	}()

	f.Lock()
	st := f.writeChunk(meta.Background(), 0, 0, make([]byte, size))
	f.Unlock()
	if st != 0 && flushErr == nil {
		t.Fatalf("writeChunk returned %s", st)
	}

	select {
	case <-writer.idSet:
	case <-time.After(2 * time.Second):
		t.Fatal("slice ID was not assigned")
	}

	f.Lock()
	s := c.slices[len(c.slices)-1]
	f.Unlock()
	return &flushDispatchHarness{file: f, slice: s, writer: writer}
}

func (h *flushDispatchHarness) sliceError() syscall.Errno {
	h.file.Lock()
	defer h.file.Unlock()
	return h.slice.err
}

func TestFullBlockDispatchedWhenSliceIDBecomesReady(t *testing.T) {
	h := writeSliceWithDelayedID(t, flushDispatchBlockSize, nil)

	select {
	case got := <-h.writer.flushes:
		if got != flushDispatchBlockSize {
			t.Fatalf("FlushTo offset = %d, want %d", got, flushDispatchBlockSize)
		}
	case <-time.After(time.Second):
		t.Fatal("full block was not dispatched after slice ID became ready")
	}

	select {
	case got := <-h.writer.flushes:
		t.Fatalf("duplicate FlushTo(%d)", got)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestPartialBlockNotDispatchedWhenSliceIDBecomesReady(t *testing.T) {
	h := writeSliceWithDelayedID(t, flushDispatchBlockSize/2, nil)

	select {
	case got := <-h.writer.flushes:
		t.Fatalf("partial block unexpectedly dispatched with FlushTo(%d)", got)
	case <-time.After(250 * time.Millisecond):
	}
}

func TestFlushErrorRecordedWhenSliceIDBecomesReady(t *testing.T) {
	h := writeSliceWithDelayedID(t, flushDispatchBlockSize, errors.New("injected flush error"))

	select {
	case got := <-h.writer.flushes:
		if got != flushDispatchBlockSize {
			t.Fatalf("FlushTo offset = %d, want %d", got, flushDispatchBlockSize)
		}
	case <-time.After(time.Second):
		t.Fatal("full block with injected flush error was not dispatched")
	}

	deadline := time.Now().Add(time.Second)
	for h.sliceError() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := h.sliceError(); got != syscall.EIO {
		t.Fatalf("slice error = %s, want EIO", got)
	}
}
```

---

## 附录 B：B 生产补丁

内容与 C02 相同；必须标准 apply，SHA256 必须与 §2.1 一致。

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

## 附录 C：社区文字草稿骨架

GLM 只能填入冻结 commit、测试命令和原始结果，不得扩展因果或发布。

### C.1 Issue 标题

~~~text
VFS may miss dispatching a full block when the slice ID is prepared asynchronously
~~~

### C.2 Issue 正文骨架

~~~markdown
**What happened**

When a write creates a new slice, `prepareID` runs asynchronously. If the first write fills at least one block before the slice ID is ready, `sliceWriter.write` skips `FlushTo` because `s.id == 0`. When the ID later becomes ready, the current code assigns it to the chunk writer but does not revisit the missed dispatch.

**What was expected**

After the slice ID becomes available, a non-frozen slice that already contains at least one complete block should dispatch those complete blocks exactly once. A partial or frozen slice should retain its existing behavior.

**Minimal reproduction**

The attached in-memory unit test delays `NewSlice`, writes one complete block, then releases the ID allocation. It fails on stock `<UPSTREAM_COMMIT>` and passes with the proposed catch-up logic. No external metadata or object service is required.

**Environment**

- JuiceFS commit: `<UPSTREAM_COMMIT>`
- Go: `<VERSIONS>`
- OS/arch: `<OS_ARCH>`

**Additional evidence**

The proposed change preserves asynchronous `NewSlice`, avoids dispatching partial/frozen slices, records `FlushTo` failures as `EIO`, and passed the listed local tests. Official project CI has not yet run.
~~~

### C.3 PR 标题

~~~text
vfs: dispatch complete blocks after preparing slice ID
~~~

### C.4 PR 正文骨架

~~~markdown
## What does this PR do?

Dispatch complete blocks that were written before an asynchronously allocated slice ID became available.

The catch-up runs under the existing file-writer lock, only for a non-frozen slice with a nonzero ID and at least one complete block. `FlushTo` failures are stored as `EIO` so a later flush can observe them.

## Why is this needed?

The first write to a new slice can fill a complete block while `s.id` is still zero. The write path then skips `FlushTo`, and the existing ID-ready path only calls `SetID`.

Fixes: `<ISSUE-TO-BE-CREATED-AFTER-REVIEW>`

## Tests

- `<TARGETED TEST COMMANDS AND RESULTS>`
- `<FULL pkg/vfs RESULTS>`
- `<LINT/VET/BUILD RESULTS>`

GitHub Actions has not yet run.
~~~

### C.5 Commit message

~~~text
vfs: dispatch complete blocks after preparing slice ID

The first write to a new slice can fill a complete block before the
asynchronously allocated slice ID is ready. In that case the write path
skips FlushTo because the ID is still zero, and the ID-ready path does not
revisit the missed dispatch.

After assigning the ID, dispatch complete blocks for a non-frozen slice.
Record a FlushTo failure as EIO so it remains observable by later flushes.
Add deterministic in-memory tests for full, partial, and error paths.
~~~
