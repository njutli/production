# C03-R3：最新 main 社区候选终态证据链洁净重跑

> 面向执行方：GLM  
> 方案与结果复核：Codex  
> 日期：2026-08-17  
> 性质：C03-R2 技术通过但终态与机械审计不合规后的完整洁净重跑；不占 03 阶段性能任务编号  
> 上游：执行时从 `https://github.com/juicedata/juicefs` 重新冻结最新 `main`  
> 主工具链：Go 1.25.7  
> 兼容工具链：本机 Go 1.26.0  
> 工作根：`/home/lilingfeng/tmp`；禁止使用根级 `/tmp/`  
> 唯一入口：冻结后的 `launch-c03-r3.sh RUN_ID`  
> 核心原则：先通过 launcher/result/archive 合成预飞，再冻结 input；随后使用全新 input、OUT、clone、cache、tools 和 Redis 完整重跑。  
> 禁止：修改或补写 C03-R2 及更早证据、复用旧 PASS/log/rc/src/cache/build、性能测试、生产操作和任何社区写操作。

---

## ⚑ 计划线与本轮唯一任务

~~~text
C01-R1 / C02
  └─ 确定性复现 + B 异步 catch-up + 十项语义/故障/race
  ↓
C03 / C03-R1
  └─ 技术结果多次全绿；PR-readiness 因 lint/runner/archive 审计不闭合而阻塞
  ↓
C03-R2
  ├─ frozen main 53835e24 上技术结果再次全绿
  ├─ 原始日志可确认 B 社区三项各 100/100、race 20/20
  └─ terminal PENDING、结果 gate 失真、input/archive 集合不闭合
  ↓
★ C03-R3（你在这里）
  ├─ 在任何正式测试前合成验证 launcher、结果解析和 archive 集合算法
  ├─ 动态自定位并冻结唯一 launcher/runner/finalizer
  ├─ 在执行时最新 main 上完整重跑 S/B/Q/R
  ├─ 每个测试、每个工具链、每种模式逐行机械计数
  ├─ input/executed/archive 三方逐文件闭合
  ├─ archive expected set、manifest、实际 tar set 三方精确相等
  └─ 仅当 24 candidate gate + 10 terminal integrity 全 YES 才输出 PASS
  ↓
  ├─ PASS：停止同类 main 重跑，交 Codex 做代码/重复性审阅
  ├─ UPSTREAM-ALREADY-FIXED：停止 B，转官方修复 backport 分析
  └─ DRIFT/FAIL/NON-COMPLIANT：停止，不进入社区流程
~~~

本轮不增加补丁功能，也不增加新的 JuiceFS 测试语义。唯一任务是：修正 C03-R2 的执行与归档状态机，并从全新现场重新产生一条可以由归档和外部 sidecar 独立验证的完整证据链。

---

## 〇、C03-R2 正式复核结论

### 0.1 R2 原始报告与证据

~~~text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R2-execution-20260817-183244.md
/home/lilingfeng/tmp/juicefs-c03-r2-input-20260817-182702
/home/lilingfeng/tmp/juicefs-c03-r2-20260817-183244
/home/lilingfeng/tmp/juicefs-c03-r2-20260817-183244-artifacts.tar.gz
~~~

固定参考值：

| 项 | SHA256 |
|---|---|
| C03-R2 任务书 | `a365fbb856ff9123d380f9afbca569c27148812b4476c72dcce7a759b10e607c` |
| C03-R2 GLM 原始报告（追加 Codex 分析前） | `f533e1faa8c7c7962917b583bbf593eb041399c724df71c4b8d643db5ea60ab0` |
| C03-R2 archive | `08174e2abb8413778540e3efb766328533e56b9aaf2a00d80dac0c23e51550f2` |
| R2 attempt 7 runner | `dee8331a8719c17bd2759602f3f2d5cbf203af9e6026fbadeb67eb88f054ff78` |
| R2 attempt 7 launcher | `a4473b1285dc0ad40f39448e9eb6ef120e50bdf3729f970fefdb69d41dacd4af` |
| R2 最终两文件 patch | `1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9` |

报告后续可能按用户要求追加 Codex 复核段；上述报告 hash 只锚定 GLM 原始 185 行内容，不是 R3 的业务输入硬门。R3 启动时必须另行记录报告文件的实际当前 hash，并只要求它在本轮 before/after 不变。

### 0.2 R2 可以承接的技术旁证

Codex 对 R2 OUT 做了只读复核，确认：

1. frozen main `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a` 上，stock U1/U3 在双工具链下稳定命中指定失败，U2 通过；
2. B 社区三项原始日志中，每项在双工具链下精确 `100/100`，race 每项精确 `20/20`；
3. Q 十项原始结果在双工具链下每项 `100/100`，race 每项 `20/20`；
4. 未发现 DATA RACE、panic、timeout 或 no-tests；
5. 双工具链完整 `pkg/vfs`、tidy、vet、Linux/lite build 有 rc=0 日志；
6. golangci-lint v2.6.2 的 query/install/version/run 均有 rc=0，lint 输出无 finding；
7. B 可标准 apply，R-replay diff 与 B 一致，最终 patch SHA256 为上述固定值。

这些只能作为历史技术旁证。R3 禁止复制其 PASS、日志、rc、源码、cache、工具或 build 作为本轮结果。

### 0.3 R2 正式裁定

~~~text
C03-R2-REVIEWED = TECHNICAL PASS-B / PR-READINESS BLOCKED / AUDIT NON-COMPLIANT
~~~

R3 必须同时关闭以下问题，禁止只修 `$OUT.meta` 一个路径：

1. 第 25 个终态门的 `runner_exit_rc_zero`、`launch_log_sha_recorded` 保持 `PENDING`，且正式 `.final-status.txt` 不存在；
2. launcher 使用 `set -e` 后裸调用 runner，runner 非零时无法可靠捕获 rc；
3. launcher 没有把 runner 生成的 provisional integrity 补成十项最终 integrity；
4. launcher 的 `$OUT.meta/prearchive-status.txt` 路径错误，fallback 甚至写出 `RUNNER-FAILED-rc=0`；
5. B 社区 count/race TSV 的 `actual_pass=0`，gate 却只看进程 rc 写 YES；R-replay 同类字段也为 0；
6. `B_standard_apply` 指向的 `B-apply-check.rc`、`B-apply.rc` 实际不存在；
7. Redis lifecycle 表头为七列，数据却被写成冒号拼接字段，pull/run/inspect/log 的真实 rc 未进入 gate；
8. archive 有 434 个普通文件而 `SHA256SUMS` 只有 431 项；除 `SHA256SUMS` 自身外，`logs/sha256-check.log`、`rc/sha256-check.rc` 未受 manifest 覆盖；
9. 没有生成 `archive-members.expected`；`member_set_exact` 只由两次 checksum 成功推导，没有比较 expected/manifest/tar 三个路径集合；
10. `assets/input` 缺少 `input.expected-files`、`input.stat.tsv`、`input.sha256`，且只比较 runner，没有闭合 launcher 三方 hash；
11. input gate 没有按 `input.stat.tsv` 重建 stat、检查文件集合/权限/新增目录并比较 archived copy；
12. archive 解包验证目录在 runner 退出前被删除，违反保留现场要求；
13. runner static review 把上述不满足项写成 YES，说明文字勾选不能充当可执行预飞。

### 0.4 禁止修补旧现场

- 不修改 R2 input、OUT、archive、sidecar、runner、launcher、task 或 report；
- 不手工给 R2 integrity TSV 把 `PENDING` 改成 `YES`；
- 不给 R2 archive 重建 manifest、补文件或重打包；
- R3 只能读取上述路径并在全新位置生成证据。

---

## 一、目标、分支与唯一成功状态

### 1.1 Q0：执行时最新官方 main 是否仍受影响

从官方 remote 稳定冻结一个精确 `UPSTREAM_COMMIT`：

| 观察 | 状态 | 动作 |
|---|---|---|
| U1/U3 指定 marker FAIL，U2 PASS | `UPSTREAM-AFFECTED` | 继续 S/B/Q/R 全矩阵 |
| U1/U2/U3 均 PASS，源码存在等价 catch-up | `UPSTREAM-ALREADY-FIXED` | 禁止应用 B，保存候选修复提交后早停 |
| 测试表现与以上两类不一致 | `UPSTREAM-ORACLE-DRIFT` | 停止，交 Codex |
| B 无法标准 apply 或 writer 语义变化 | `B-PATCH-DRIFT` | 停止，GLM 不得自行 rebase |
| 官方 Go/lint/build 口径变化 | `CI-MATRIX-DRIFT` | 停止，不得换版本迁就 |
| C02 base 不再是 main 祖先 | `UPSTREAM-HISTORY-DIVERGED` | 停止，交 Codex |

### 1.2 Q1：B 是否继续满足社区与完整语义

必须在本轮新 OUT 中重新证明：

- stock 社区正控红、负控绿；
- B 社区三项逐项、count100、race20 每项精确计数；
- Q 十项逐项、count100、race20 每项精确计数；
- 双工具链完整 `pkg/vfs` 通过；
- R-replay 从 frozen main 标准 apply，diff 与 B 逐字节一致，社区三项逐项与 count20 精确通过；
- B 继续保留异步 `NewSlice`、partial/frozen/error/non-EIO/并发语义。

### 1.3 Q2：本地社区质量门是否闭合

必须实际执行并机械纳入 gate：

- gofmt、license、`git diff --check`；
- 双工具链 tidy，命令 rc=0 且 go.mod/go.sum 不变；
- 双工具链 `go vet ./pkg/vfs`；
- frozen main 官方口径的 golangci-lint v2.6 系列全仓 lint；
- 双工具链 Linux/lite build、version rc、冻结 revision、文件非空可执行、SHA 和复制一致性；
- 每工具链一次性 Redis 的完整生命周期。

### 1.4 Q3：执行链与归档能否独立还原

必须同时证明：

- launcher、runner、terminal finalizer 的 executed/input/archived 三份 hash 分别一致；
- input 起止文件集合、内容 hash、stat、权限、目录集合完全一致；
- archived input 包含全部 input 文件和三个 manifest，集合与 hash 精确相等；
- 所有 result gate 从逐测试 TSV 的精确计数计算，不只看进程 rc；
- archive expected set、SHA manifest set、实际 tar regular-file set 满足预注册集合关系；
- archive 解包后 SHA 与成员集合重新验证通过；
- SOURCE 和历史证据在执行前后未变化；
- terminal finalizer 的成功、runner 非零、integrity NO、缺文件四个合成分支均在启动前通过。

### 1.5 唯一成功状态

只有以下两个条件同时满足：

1. `candidate-gates.tsv` 的 24 项全部精确为 `YES`；
2. 外部 `archive.integrity.tsv` 的十项全部精确为 `YES`；

launcher 才允许写：

~~~text
PASS-B-PR-READY-LOCAL
~~~

该状态只表示“可交 Codex 做 patch 代码审阅和社区重复性判断”。它不表示 GitHub Actions 已运行，不授权 GLM commit、push 或创建 issue/PR，也不保证维护者接受。

### 1.6 执行 attempt 上限

- 冻结 input 前可以修改脚本，但每次修改后必须重新执行全部合成预飞并重新生成 static review；
- input 一旦生成 `input.sha256` 并设为只读，即视为一次正式 attempt；
- 正式 attempt 最多两次；第一次若因 runner/launcher/基础设施设计错误失败，完整保留 input、OUT、partial archive 和 sidecar后，允许新建一次 input/OUT；
- 第二次仍出现 harness bug、audit NO 或未预注册适配：停止，报告 `R3-HARNESS-BLOCKED`，不得继续第三次挑选重跑；
- frozen runner 内预注册的有限网络重试不计为新 attempt，但必须逐次保存日志和 rc。

### 1.7 明确不做

- 不运行 fio、benchmark、性能 AB、mount、fio verify 或 soak；
- 不修改或运行 v1.3.1、A-sync 或生产二进制；
- 不访问生产 Redis/Ceph/TiKV/S3；
- 不修改生产部署；
- 不执行完整多服务 `make test.pkg`；
- 不执行 Windows/Ceph/FDB build；
- 不使用 sudo，不安装系统包；
- 不 commit、push、fork、branch 或 tag；
- 不创建、评论、编辑或关闭 issue/PR；
- 不使用 GitHub token、cookie 或 Authorization header；
- 不删除任何 C03/C03-R1/C03-R2/R3 失败现场。

---

## 二、固定资产、动态量与目录

### 2.1 固定输入资产

从 R2 attempt 7 input 只读复制以下三个业务资产；复制后必须先校验 SHA，任何不符立即停止：

| 资产 | 只读来源 | SHA256 |
|---|---|---|
| B writer patch | `/home/lilingfeng/tmp/juicefs-c03-r2-input-20260817-182702/async-catchup-main.patch` | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` |
| 社区测试 | `/home/lilingfeng/tmp/juicefs-c03-r2-input-20260817-182702/writer_flush_test.go` | `bce85ad4abf92a47074849a544aaa756963fb44a1839619bbc71c5d7ce1fe9bc` |
| C02 十项内部测试 | `/home/lilingfeng/tmp/juicefs-c03-r2-input-20260817-182702/writer_flush_c02_test.go` | `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` |

固定历史参考：

| 项 | 值 |
|---|---|
| C02 base | `edabf9c24601510476e7453abff177f4aaca07ac` |
| R2 frozen main | `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`；仅供历史对照，不得冒充 R3 最新 main |
| 参考两文件 patch SHA | `1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9`；仅当 writer base blob 未变时要求相等 |
| 官方 remote | `https://github.com/juicedata/juicefs` |
| 只读 SOURCE | `/home/lilingfeng/project/juicefs`；仅作为 Git object seed，不得 fetch/checkout/reset/clean |
| 主工具链 | `GOTOOLCHAIN=go1.25.7` |
| 兼容工具链 | `GOTOOLCHAIN=local`，必须实测为 Go 1.26.0 |
| Redis | `redis:7.2-alpine`，执行时冻结 image ID/RepoDigest |

### 2.2 动态命名

~~~text
RUN_ID=YYYYmmdd-HHMMSS
INPUT=/home/lilingfeng/tmp/juicefs-c03-r3-input-$RUN_ID
OUT=/home/lilingfeng/tmp/juicefs-c03-r3-$RUN_ID
ARCHIVE=/home/lilingfeng/tmp/juicefs-c03-r3-$RUN_ID-artifacts.tar.gz
LAUNCH_LOG=/home/lilingfeng/tmp/juicefs-c03-r3-$RUN_ID.launch.log
TERMINAL=/home/lilingfeng/tmp/juicefs-c03-r3-$RUN_ID-terminal
VERIFY=/home/lilingfeng/tmp/juicefs-c03-r3-verify-$RUN_ID
~~~

启动前必须证明以上所有路径不存在。禁止覆盖、清空或复用同名路径。

### 2.3 R3 input 精确成员

冻结后的 input 只允许包含以下普通文件，不允许运行期 PID、stdout、rc、cache 或子目录：

~~~text
anchors.expected
async-catchup-main.patch
community-secret-patterns.txt
forbidden-runtime-patterns.txt
launch-c03-r3.sh
pre-run-adaptations.md
protected-paths.txt
run-c03-r3.sh
runner-static-review.txt
taskbook.md
terminal-finalize.sh
terminal-selftest.log
terminal-selftest.rc
writer_flush_c02_test.go
writer_flush_test.go
input.expected-files
input.stat.tsv
input.sha256
~~~

规则：

1. `input.expected-files` 是以上 18 个 basename 的 C-locale 排序列表；
2. 先完成业务文件、脚本、selftest 和 static review，再生成 manifest；
3. `input.stat.tsv` 记录除三个 manifest 外每个文件的 mode、uid、gid、size、mtime_ns；
4. `input.sha256` 覆盖除自身外的全部 17 个文件，包括 `input.expected-files` 和 `input.stat.tsv`；
5. 生成后所有文件 mode=0444，input 目录 mode=0555；脚本均由 `bash path`/source 执行，不依赖 executable bit；
6. launcher stdout、PID、rc 和所有运行日志写在 input 外；
7. 启动时间必须晚于 input 最后一个 mtime；
8. R3 archive 中的 `assets/input/` 必须包含这 18 个文件，不能像 R2 一样删除 manifest。

---

## 三、正式执行前的合成预飞

任何 Go 命令、fetch、clone、Redis 或正式测试之前，必须完成本节。预飞失败不得启动正式 attempt。

### 3.1 shell 语法与静态硬门

`runner-static-review.txt` 必须保存命令、关键输出和真实 rc，不能只写手工 YES。至少包括：

1. `bash -n` 分别检查 launcher、runner、terminal-finalize，三项 rc=0；
2. launcher 和 runner 只通过 `${BASH_SOURCE[0]}` + `readlink -f` 动态定位 input；
3. 不包含任何带时间戳的 C03/R1/R2/R3 input 绝对路径；
4. launcher 中不存在 `$OUT.meta`；必须出现 `$OUT/meta/prearchive-status.txt`；
5. launcher 必须在 `if bash "$RUNNER" ...; then ... else ... fi` 中捕获 runner rc，禁止在 `set -e` 下裸调用后读取 `$?`；
6. runner 只生成八项 provisional archive integrity；launcher/finalizer生成十项 final integrity；
7. finalizer 明确拒绝 `PENDING`、重复 key、未知 key、缺 key 和非 YES/NO 值；
8. result gate 按每个测试逐行判断 expected/actual 次数，禁止把 `"$U1\n$U2"` 当测试列表；
9. `B_standard_apply` 保存 apply-check/apply 两个真实 rc；
10. Redis lifecycle 每行使用七个真实 TSV 字段，禁止冒号打包；
11. archive 使用 `meta/archive-members.expected` 作为 tar 文件列表，禁止直接 tar 整个可继续变化的目录；
12. manifest 生成后，所有 checksum/list/extract/terminal log 和 rc 都写到 `$TERMINAL`，不再写 archive payload；
13. VERIFY 目录不在 runner/launcher 中删除；
14. executed/input/archived 的 launcher、runner、finalizer 都有 hash 与 cmp；
15. 无 `rm -rf`、Docker prune、sudo、commit、push、GitHub 写 API、fio、mount 或生产地址；
16. 所有 24 gate 初始为 `NOT_RUN`，只能解析一次；不存在默认 YES 或遗漏 gate 仍 PASS 的分支；
17. final PASS 同时依赖 24 gate、十项 integrity、runner rc=0 和 launch-log SHA 自校验。

### 3.2 terminal finalizer 合成自测

`terminal-finalize.sh` 必须由 launcher source，并在冻结 input 前用临时合成文件验证。不得另写一份测试专用判定逻辑。至少覆盖：

| case | runner rc | prearchive | provisional 8 项 | 期望 final status |
|---|---:|---|---|---|
| success | 0 | ALL-REQUIRED-GATES-YES | 全 YES | PASS-B-PR-READY-LOCAL |
| runner-fail | 17 | ALL-REQUIRED-GATES-YES | 全 YES | RUNNER-FAILED-rc=17 |
| gate-fail | 0 | NOT-PR-READY | 全 YES | NOT-PR-READY |
| integrity-no | 0 | ALL-REQUIRED-GATES-YES | 一项 NO | TERMINAL-INTEGRITY-FAIL |
| pending | 0 | ALL-REQUIRED-GATES-YES | 含 PENDING | TERMINAL-INTEGRITY-FAIL |
| duplicate-key | 0 | ALL-REQUIRED-GATES-YES | 重复 key | TERMINAL-INTEGRITY-FAIL |
| missing-key | 0 | ALL-REQUIRED-GATES-YES | 缺 key | TERMINAL-INTEGRITY-FAIL |
| missing-prearchive | 0 | 文件不存在 | 全 YES | TERMINAL-EVIDENCE-MISSING |

每个 case 必须同时断言：

- runner rc sidecar 内容正确；
- launch log SHA 文件存在且 `sha256sum -c` 成功；
- final integrity 精确十行、key 顺序与附录 B 一致、无 PENDING；
- 非 success case 绝不生成 PASS；
- success case 恰好生成一份 PASS sidecar。

完整输出写入 `terminal-selftest.log`，最终 rc 写入 `terminal-selftest.rc`。只有 rc=0 才允许冻结 input。

### 3.3 result parser 合成自测

在 `runner-static-review.txt` 中追加三个小型合成日志的解析结果：

1. 三测试各出现 100 个 `--- PASS:`，解析为三行 `actual_pass=100`；
2. 其中一个只有 99 个 PASS，gate 必须为 NO；
3. rc=0 但包含 `warning: no tests to run`，gate 必须为 NO。

禁止只证明命令 rc=0。

### 3.4 archive set 算法合成自测

用小型临时 payload 验证：

- expected set 与实际文件相同：PASS；
- 多一个未列文件：FAIL；
- 少一个预期文件：FAIL；
- manifest 少覆盖一个文件：FAIL；
- archive 多一个文件：FAIL。

结果写入 `runner-static-review.txt`。该预飞必须调用与正式 runner 相同的 set-compare helper。

---

## 四、launcher、runner 与 terminal 状态机硬约束

### 4.1 launcher 捕获 runner rc

必须使用等价于以下的控制流，禁止裸调用：

~~~bash
if bash "$RUNNER" "$RUN_ID" > "$LAUNCH_LOG" 2>&1; then
  RUNNER_RC=0
else
  RUNNER_RC=$?
fi
printf '%s\n' "$RUNNER_RC" > "$TERMINAL/runner.rc"
~~~

无论 runner rc 是 0 还是非零，launcher 都必须继续记录 launch log SHA、生成 final integrity 和明确 final status。launcher 自身最后退出码可以反映最终状态，但不得在 sidecar 生成前退出。

### 4.2 provisional 与 final integrity 分离

runner 只能写：

~~~text
$TERMINAL/archive.integrity.provisional.tsv
~~~

其中精确包含附录 B 前八项，值只能是 YES/NO。launcher 在 runner 退出后验证 runner rc 和 launch log SHA，再原子生成：

~~~text
$TERMINAL/archive.integrity.tsv
$TERMINAL/final-status.txt
$TERMINAL/runner.rc
$TERMINAL/launch-log.sha256
~~~

禁止原地 sed R2 式 PENDING 文件。final integrity 必须从 provisional 重新解析、验证 key 集合后写十项；任何异常均为 NO/FAIL，不能保持 PENDING。

### 4.3 launcher/runner/finalizer 三方来源证明

最终证据至少记录：

~~~text
executed_launcher_realpath / sha256
executed_runner_realpath / sha256
executed_finalizer_realpath / sha256
input_manifest_*_sha256
archived_*_sha256
launcher_cmp_rc
runner_cmp_rc
finalizer_cmp_rc
~~~

三组 executed/input/archived hash 必须分别相等，三个 cmp 必须为 0。launcher 也必须校验，禁止只校验 runner。

### 4.4 input 起止双检

runner 开始和 PACKAGE 前分别机械执行：

1. 当前普通文件 basename 集合与 `input.expected-files` 精确相等；
2. 从 input 根运行 `sha256sum -c input.sha256` 并立即捕获 rc；
3. 按 `input.stat.tsv` 重新生成实际 stat 表并 `cmp`；
4. 确认所有 input 普通文件不可写、目录不可写；
5. 确认无新子目录、PID、stdout、swap、tmp；
6. 复制全部 18 个 input 文件到 `OUT/assets/input/`；
7. 比较 input 与 archived input 的文件集合、逐文件 SHA、stat；
8. 单独比较 launcher、runner、finalizer。

`input_integrity` 只能在 end check 和 archived copy check 全部完成后解析一次。

### 4.5 runner bug 与重试

若正式 attempt 中出现任何脚本错误、gate 算法错误或未预注册适配：

1. 当前 OUT 写明确失败状态；
2. trap 只停止本轮已登记的 Redis 容器；
3. 生成 partial archive/sidecar，禁止补跑；
4. 不修改当前 input、OUT、archive；
5. 若尚未达到两次上限，修复后重新执行全部合成预飞，创建新 input/OUT；
6. `pre-run-adaptations.md` 记录旧/新 input、OUT、失败步骤、runner/launcher/finalizer SHA 和修复内容。

---

## 五、上游冻结、工具策略与四臂

### 5.1 冻结执行时最新 main

使用不含 hardlink 的隔离 fetch clone，origin 精确设为官方 URL。允许最多三个稳定冻结 attempt，每次保存：

- fetch 前后 `git ls-remote origin refs/heads/main` 的原文、时间、rc；
- fetch rc、FETCH_HEAD、origin/main、selected HEAD；
- commit hash/date/title/parents；
- C02 base 是否为祖先；
- C03-R2 frozen commit 是否为祖先；
- `pkg/vfs/writer.go` 相对 R2 base blob 是否变化；
- official main URL 与无 credential 证明。

只有同一 attempt 的 remote-before、fetched origin/main、remote-after 三者相同才可冻结。冻结后禁止再次 fetch。

### 5.2 官方策略冻结

从 frozen main 保存并机械解析：

- `go.mod` 的 Go directive/toolchain；
- GitHub workflows 中 Go matrix；
- lint action/version系列；
- `.golangci.yml`；
- Makefile 的 Linux/lite build 入口；
- CONTRIBUTING 中相关测试要求。

若不再兼容 Go 1.25.7/1.26.0、lint v2.6 或既定 build 入口，输出 `CI-MATRIX-DRIFT`，不得自行更换版本继续。

### 5.3 四臂

| 臂 | 内容 | 允许变更 |
|---|---|---|
| S-oracle | frozen main + 社区测试 | `pkg/vfs/writer_flush_test.go` |
| B-candidate | frozen main + B writer patch + 社区测试 | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |
| Q-semantic | frozen main + B writer patch + C02 内部测试 | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_c02_test.go` |
| R-replay | frozen main + 最终两文件 patch | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |

四臂 HEAD 必须等于同一 frozen commit。禁止 hardlink；禁止把 Q 内部测试放入最终社区 patch。

### 5.4 patch drift 分支

- 若 writer base blob 与 R2 相同：最终两文件 patch SHA 必须等于参考 `1050e94f...`；
- 若 base blob 改变但 B 可以标准 apply：保存 `R2..R3 -- pkg/vfs/writer.go` 和最终完整 patch，交 Codex 复核；GLM 不得自行宣布语义等价；
- 若标准 apply 失败：`B-PATCH-DRIFT` 早停；禁止 `--recount`、手工编辑、rebase 或三方 apply。

---

## 六、结果 TSV 与精确计数门

### 6.1 统一 schema

stock/community/semantic/replay 结果统一为：

~~~text
arm	tool	mode	test	actual_rc	expected_pass	actual_pass	expected_fail	actual_fail	expected_marker	actual_marker	bad	log	expectation_matched
~~~

每个物理 TSV 行只能表示一个测试函数。禁止在 `test` 字段塞入反斜杠 `\n` 或多个测试名。

`bad=YES` 的模式至少包括：

~~~text
[build failed]
panic:
fatal error:
test timed out
DATA RACE
no tests to run
warning: no tests to run
~~~

### 6.2 计数规则

对每个 `tn` 使用锚定测试名计数：

~~~text
^--- PASS: <tn>( |$)
^--- FAIL: <tn>( |$)
~~~

不得只数包级 `PASS`，不得只看 rc。组合命令完成后，必须为列表中每个测试独立生成一行。

### 6.3 stock oracle 精确矩阵

数据行精确 46 行：

- 两工具链 × 三项 single = 6；
- 两工具链 × U1/U3 × 10 个独立进程 = 40。

预期：

- U2 single：rc=0、PASS=1、FAIL=0、marker=0、bad=NO；
- U1/U3 single 与 repeat：rc=1、PASS=0、FAIL=1、各自 marker=1、bad=NO；
- 任何 mixed outcome、marker 不唯一、额外失败、build/race/timeout 均为 oracle drift。

### 6.4 B 社区矩阵

数据行精确 18 行：两工具链 × 三测试 × `single/count100/race20`。

| mode | 每测试 expected_pass | expected_fail | rc |
|---|---:|---:|---:|
| single | 1 | 0 | 0 |
| count100 | 100 | 0 | 0 |
| race20 | 20 | 0 | 0 |

三种 mode 每个测试都必须独立检查。最终日志不得包含 DATA RACE。

### 6.5 Q 十项矩阵

数据行精确 60 行：两工具链 × 十测试 × `single/count100/race20`。每测试分别要求 1/100/20 次 PASS、0 FAIL、rc=0、bad=NO。

十项名称沿用 C02 固定测试文件，不允许删除、改名或只跑子集。

### 6.6 R-replay 矩阵

数据行精确 12 行：两工具链 × 三社区测试 × `single/count20`。

- single 每项 1 PASS；
- count20 每项 20 PASS；
- R diff 与 B 完整两文件 patch 逐字节一致；
- 标准 apply-check/apply 各自有真实 rc=0 文件。

### 6.7 gate 算法

每张 TSV 必须同时满足：

- 数据行数精确；
- test/tool/mode 组合无缺失、无重复；
- 每行 `expectation_matched=YES`；
- actual_pass/fail/marker 与 expected 精确相等；
- bad=NO；
- 对应日志存在、非空、hash 已记录。

任何一项不满足，对应 gate=NO。禁止 `go test rc=0` 覆盖计数错误。

---

## 七、Redis、格式、lint 与 build 硬门

### 7.1 Redis lifecycle

先确认宿主 loopback 6379 未监听；占用则 `REDIS-PORT-BLOCKED`。只管理名称和 label 都包含本轮 RUN_ID 的容器 ID。

TSV schema 精确为：

~~~text
tool	step	expected_rc	actual_rc	content_check	status	evidence
~~~

以下每步必须独立捕获真实 rc，禁止 `|| true` 后硬写 0：

- image inspect/pull；
- docker run 与非空 CID；
- PONG；
- docker inspect JSON；
- docker logs；
- full `pkg/vfs`；
- docker stop；
- gone proof。

所有预期 rc、内容检查和 status 都匹配，双工具链完整 `pkg/vfs` rc=0，才能同时设置 `redis_lifecycle=YES`、`B_full_vfs=YES`。

### 7.2 gofmt/license/diff

必须保存并纳入 gate：

- gofmt diff 为空；
- 社区测试保留 JuiceFS license header；
- `git diff --check` rc=0；
- changed paths 精确符合白名单；
- gofmt 前后不得静默改变 B patch；如有变化直接 FAIL，不自动 `gofmt -w` 后继续。

### 7.3 tidy/vet

两个工具链分别：

- `go mod tidy` rc=0；
- go.mod/go.sum 前后 SHA 相同；
- `go vet ./pkg/vfs` rc=0。

每个命令单独 log/rc，不能由后一命令覆盖。

### 7.4 golangci-lint

从 frozen policy 解析 v2.6 系列，选择查询结果中的最高稳定 v2.6.x。保存 query/install/version/run rc、版本原文、binary SHA、config SHA。

lint 前后分别保存并比较：

- HEAD；
- `status --porcelain=v2`；
- tracked diff SHA；
- go.mod/go.sum SHA；
- writer.go 和社区测试 SHA。

全部一致且全仓 lint rc=0、无 timeout/panic/finding，才设置 `B_lint=YES`。

### 7.5 build

Go 1.25.7/1.26.0 分别执行 Linux 与 lite build。每个产物必须：

- make rc=0；
- version 命令 rc=0；
- version 含 frozen commit revision；
- 文件非空且可执行；
- SHA256 已记录；
- 复制到 `OUT/builds/TOOL/` 后 cmp=0。

build 大文件保留在 OUT，不进入 archive；archive 只包含 retained path、size、SHA 和 version 证据。

---

## 八、社区只读资料与边界

### 8.1 重复性搜索

执行六组匿名 GitHub GET 查询和 frozen repo 本地 history 搜索。每组保存：

- request URL（无 token）；
- started/finished timestamp；
- curl rc；
- HTTP status；
- rate-limit headers；
- body；
- JSON 解析 rc；
- 候选 number/type/state/title/updated-at/url。

`community_search=YES` 只表示搜索证据完整，不表示“不重复”。最终重复性判断由 Codex 在 R3 PASS 后完成。

### 8.2 草稿与脱敏

生成 issue、PR、commit message 草稿，但不得发送。草稿只能列本轮实际为 YES 的门，必须明确：

- fixed main commit；
- stock 最小行为；
- B 保留异步语义；
- 没有运行性能测试；
- 不声称修复 main 所有 randwrite 塌速或数据损坏；
- GitHub Actions 尚未运行。

使用冻结的 secret pattern 文件扫描最终 patch、测试和三份草稿。真实 rc 与无命中语义必须区分，禁止同 OUT 静默改稿再扫。

---

## 九、SOURCE、历史证据与 changed-path 守卫

### 9.1 SOURCE 保护

对 `/home/lilingfeng/project/juicefs` 使用 `GIT_OPTIONAL_LOCKS=0` 保存 before/after：

- HEAD；
- status porcelain v2；
- tracked diff binary SHA；
- refs 摘要；
- untracked 文件路径与内容 SHA 清单。

禁止在 SOURCE 上 fetch、checkout、apply、build 或测试。

### 9.2 历史证据保护

至少保护 C02/C03/C03-R1/C03-R2 的 task、report、input、最终 OUT、archive 和 sidecar。对普通文件生成 before/after：

- 相对路径、类型、mode、uid/gid、size、symlink target；
- 内容 SHA256；
- 文件集合总 hash。

不要用目录 mtime 或读操作会变化的 `.git` mtime 作为唯一判据；Git 仓库另用 HEAD/status/diff/refs 证明。任何内容或集合变化均令 `source_asset_guards=NO`。

### 9.3 四臂 path guard

每臂分别保存 `git diff --check` 真实 rc、changed paths 和完整 diff。白名单外路径、go.mod/go.sum 变化、内部 C02 测试进入社区 patch均为 NO。

---

## 十、24 个 candidate gate

`candidate-gates.tsv` 精确包含以下 24 行，不得增删、PENDING、SKIP 或 N/A：

| gate | YES 的必要证据 |
|---|---|
| input_integrity | 起止集合/SHA/stat/权限 + archived input + launcher/runner/finalizer 三方一致 |
| upstream_freeze | 官方 main 三点稳定冻结与祖先关系 |
| upstream_policy_ci | Go/lint/build 口径未漂移 |
| upstream_stock_oracle | 46 行精确矩阵全匹配 |
| B_standard_apply | apply-check/apply 两个真实 rc=0 |
| B_community_single | 六行 single 精确通过 |
| B_community_count100 | 六行各 100 PASS |
| B_community_race20 | 六行各 20 PASS、无 race |
| Q_semantic_single | 二十行 single 精确通过 |
| Q_semantic_count100 | 二十行各 100 PASS |
| Q_semantic_race20 | 二十行各 20 PASS、无 race |
| B_full_vfs | 双工具链完整 pkg/vfs rc=0 |
| redis_lifecycle | 七列逐步 rc/内容/销毁全匹配 |
| B_gofmt_diff_license | gofmt/license/diffcheck/path 全满足 |
| B_tidy | 双工具链 rc=0、mod hash 不变 |
| B_vet | 双工具链 rc=0 |
| B_lint | query/install/version/run/source guard 全满足 |
| B_linux_build | 双工具链 rc/version/revision/hash/cmp 全满足 |
| B_lite_build | 双工具链 rc/version/revision/hash/cmp 全满足 |
| patch_replay | 标准 replay、diff cmp、12 行精确矩阵 |
| community_search | HTTP/JSON/本地 history 证据完整 |
| community_drafts_secret_scan | 三草稿真实、扫描闭合 |
| source_asset_guards | SOURCE/历史 before-after + 四臂 path guard |
| execution_audit | anchors、commands/xtrace、forbidden、adaptations、attempt 上限全闭合 |

gate 初始全部 `NOT_RUN`，由单一 `resolve_gate` 只解析一次。二次解析、默认 YES、缺行、重复行或非 24 行均为 `NON-COMPLIANT`。

---

## 十一、archive payload、manifest 与十项终态门

### 11.1 payload 边界

archive 只包含冻结的小型证据：

~~~text
assets/input/
artifacts/
community-search/
diffs/
drafts/
logs/                 # 仅 manifest 冻结前已完成的测试/审计日志
meta/
rc/                   # 仅 manifest 冻结前已完成的命令 rc
services/
commands.sh
summary.tsv
candidate-gates.tsv
deferred-checks.tsv
SHA256SUMS
~~~

不得包含 src/cache/tools/builds。所有 manifest/tar/extract/finalizer 的后生成日志与 rc 都写到 `$TERMINAL`，不得回写 OUT payload。

### 11.2 无自引用的生成顺序

严格按以下顺序：

1. 完成全部测试、审计、24 gate、`prearchive-status.txt` 和 payload 文件；关闭 xtrace；
2. 从允许 payload 集合生成 `meta/archive-members.expected`，预先把 `meta/archive-members.expected` 自身和未来的 `SHA256SUMS` 列入；
3. expected 生成后，唯一允许的新 payload 文件是下一步的 `SHA256SUMS`；其他 payload 从此禁止创建或修改；
4. 生成 `SHA256SUMS`，覆盖 expected set 中除 `SHA256SUMS` 自身以外的所有普通文件，包括 `meta/archive-members.expected`；从此冻结全部 OUT payload；
5. 比较 manifest path set 精确等于 `expected - SHA256SUMS`；
6. 从 OUT 根运行 `sha256sum -c SHA256SUMS`，日志/rc 写 `$TERMINAL`；
7. 在 `cd "$OUT"` 的受控子 shell 中用 `tar -czf "$ARCHIVE" -T meta/archive-members.expected` 创建 archive，禁止 tar 整个目录；
8. 写 archive SHA 到 `$TERMINAL` 并从外部重算比较；
9. 保存 tar listing/rc 到 `$TERMINAL`；
10. 比较 tar regular-file set 与 expected set 精确相等；
11. 解包到全新 `$VERIFY`，不得在复核前删除；
12. 从 VERIFY 运行 `sha256sum -c SHA256SUMS`；
13. 比较 extracted regular-file set 与 expected set 精确相等；
14. 比较 extracted manifest set 与 `expected - SHA256SUMS`；
15. 检查全部要求证据存在，并确认无 src/cache/tools/builds；
16. runner 写八项 provisional integrity 后退出；
17. launcher 捕获 runner rc、校验 launch log SHA，由 finalizer 写十项 final integrity 和 final status。

### 11.3 十项 final integrity

详见附录 B。十项必须全部 YES，不能有 PENDING。任何成员差集必须把全文保存到 `$TERMINAL`，空差集文件也保留。

### 11.4 必须保留的外部终态证据

~~~text
$TERMINAL/runner.rc
$TERMINAL/launch-log.sha256
$TERMINAL/archive.sha256
$TERMINAL/archive.integrity.provisional.tsv
$TERMINAL/archive.integrity.tsv
$TERMINAL/final-status.txt
$TERMINAL/manifest-check-before.{log,rc}
$TERMINAL/tar-listing.{log,rc}
$TERMINAL/archive-vs-expected.diff
$TERMINAL/extract-sha-check.{log,rc}
$TERMINAL/extract-vs-expected.diff
$TERMINAL/manifest-vs-expected.diff
$VERIFY/
~~~

---

## 十二、顺序步骤

1. **资产核验**：校验三项固定业务资产和 R2 历史参考，只读记录；
2. **编写脚本与合成预飞**：完成 §3，失败不得启动；
3. **冻结 input**：生成 expected/stat/SHA，设只读；
4. **唯一 launcher 前台启动**：不使用 tee 管道吞 rc；
5. **INIT / input start / SOURCE-history before**；
6. **官方 main 稳定冻结与 policy gate**；
7. **创建四个全新隔离臂**；
8. **S stock oracle 精确矩阵**；
9. **B 标准 apply 与社区精确矩阵**；
10. **Q 十项精确矩阵**；
11. **Redis 生命周期与完整 pkg/vfs**；
12. **gofmt/license/diff/tidy/vet**；
13. **官方口径全仓 lint**；
14. **双工具链 Linux/lite build**；
15. **R-replay 标准回放与精确矩阵**；
16. **只读社区/本地 history 搜索**；
17. **草稿与脱敏**；
18. **四臂、SOURCE、历史、input end/archived-copy 守卫**；
19. **anchors/forbidden/adaptations 审计并一次性解析 24 gate**；
20. **冻结 payload、expected set、manifest、archive、extract 与 provisional integrity**；
21. **runner 退出，launcher/finalizer 生成十项 final integrity 与最终状态**；
22. **GLM 只根据现存证据写原始报告，不修改任何证据文件**。

anchors 必须按上述主要阶段预注册、逐次写事件文件并 exact cmp。禁止 grep xtrace 判断 anchor，因为检查命令会污染匹配。

---

## 十三、状态判定

### 13.1 `PASS-B-PR-READY-LOCAL`

只在 24+10 全 YES 时允许。报告结论只能写：

> 在执行时冻结的官方 main commit 上，stock 确定性证明完整 block 在异步 slice ID 就绪后未补派发；B 在保留异步语义的同时修复该行为。最终两文件 patch 可从干净 clone 标准回放，并通过双工具链社区/语义/race/完整 pkg/vfs、Redis 生命周期、gofmt/tidy/vet、官方本地 lint、Linux/lite build及完整 input/archive/terminal 审计。候选可交 Codex 做重复性与代码审阅；官方 GitHub CI 尚未运行，未执行性能或生产测试。

PASS 后停止同类 main 本地重跑。下一步由 Codex 做代码/重复性审阅；B 的 v1.3 性能验证是独立证据线，由用户另行授权和安排。

### 13.2 `UPSTREAM-ALREADY-FIXED`

stock 三项转绿且源码有等价修复时禁止应用 B。保存候选提交与 source diff，partial archive 后停止；下一步分析官方修复能否 backport v1.3。

### 13.3 drift / technical fail

`B-PATCH-DRIFT`、`CI-MATRIX-DRIFT`、`UPSTREAM-ORACLE-DRIFT`、`FULL-VFS-FAIL`、`LINT-FAIL`、`BUILD-FAIL`、`SEARCH-BLOCKED` 均不得 PR-ready。保留现场，不改控制变量挑选重跑。

### 13.4 `NON-COMPLIANT`

包括但不限于：

- 合成预飞未通过仍启动；
- 超过两次正式 attempt；
- runner/launcher/finalizer/input/archive hash 不一致；
- input 运行后被写入；
- 同一 OUT 手工补跑；
- result TSV 次数不精确但 gate=YES；
- rc 被 `|| true`、管道或后一命令覆盖；
- Redis/apply/lint/build 证据列不存在或硬编码；
- expected/manifest/tar/extract 集合未精确比较；
- archive 存在未受 manifest 覆盖的 payload；
- VERIFY 或旧失败现场被删除；
- SOURCE/history 变化；
- 社区或生产越界操作。

技术日志全绿不能豁免 NON-COMPLIANT。

---

## 十四、GLM 原始报告要求

报告写入：

~~~text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R3-execution-$RUN_ID.md
~~~

必须逐项给出或指向唯一证据：

1. input/OUT/archive/launch log/TERMINAL/VERIFY 绝对路径；
2. taskbook、三项固定业务资产、launcher/runner/finalizer SHA；
3. 正式 attempt 数和所有失败现场；
4. terminal/result/archive 合成预飞的 case 表、log、rc；
5. executed/input/archived 三方 hash/cmp；
6. input start/end/archive copy 的集合/SHA/stat/权限结果；
7. frozen main commit/date/title/parent、三点冻结和祖先关系；
8. upstream policy 解析；
9. stock 46 行矩阵摘要与 repeat 精确统计；
10. B 18 行、Q 60 行、R 12 行矩阵摘要；
11. count100/race20 每测试精确通过次数；
12. 完整 pkg/vfs 与七列 Redis lifecycle；
13. gofmt/license/diff/tidy/vet；
14. lint query/install/version/run/source before-after；
15. 四个 build 的 rc/version/revision/size/SHA/cmp；
16. B/R patch SHA、base blob 与 changed paths；
17. GitHub/local history 搜索候选，不自行下“不重复”结论；
18. 三份草稿与 secret scan；
19. SOURCE/history before-after；
20. anchors、commands、xtrace、forbidden、adaptations；
21. 24 项 candidate gate 全表；
22. expected/manifest/tar/extract 四个集合的数量与空差集证据；
23. archive SHA/readability/extract SHA；
24. 十项 final integrity 全表；
25. runner rc、launch-log SHA 自检和唯一 final-status 原文；
26. deferred Windows/Ceph/FDB/GitHub Actions=`NOT_RUN_BY_DESIGN`；
27. 明确声明未运行性能/生产测试、未执行社区写操作。

报告不得只写“全绿”，不得把 technical PASS 写成 PR-ready，除非唯一 final-status 文件确实为 `PASS-B-PR-READY-LOCAL`。GLM 不得创建下一任务、删除现场或自行提交社区。

---

## 十五、红线清单

1. 禁止修改 C02/C03/C03-R1/C03-R2 的 task、report、input、OUT、archive 和 sidecar。
2. 禁止从 R2 复制 PASS、log、rc、src、cache、tools 或 build 作为 R3 结果。
3. 禁止给旧 archive 补 manifest 或手工写 PASS sidecar。
4. 禁止 runner/launcher/finalizer 硬编码任何时间戳 input 路径。
5. 禁止向冻结 input 写 PID/stdout/rc/log/tmp。
6. 禁止正式 attempt 启动后修改同一 input；修复必须全新 input+OUT。
7. 禁止超过两次正式 attempt。
8. 禁止 `--recount`、三方 apply、手工 rebase B。
9. 禁止把 literal `\n` 测试名当精确计数结果。
10. 禁止只凭 go test rc 设置 count/race gate YES。
11. 禁止 Redis/apply/inspect/log rc 硬写 0。
12. 禁止 manifest 生成后向 archive payload 写校验 log/rc。
13. 禁止删除 VERIFY、失败 OUT、partial archive。
14. 禁止根级 `/tmp/`、sudo、Docker prune、广泛 kill、生产路径写入。
15. 禁止 fio、mount、Ceph/TiKV/S3、v1.3 性能或数据完整性测试。
16. 禁止 commit、push、fork、branch、tag、issue/PR 写操作。
17. 禁止在草稿中声称 main 宏观 randwrite 已修复、数据损坏已修复或官方 CI 已通过。

---

## 附录 A：精确测试清单

### 社区三项

~~~text
TestFullBlockDispatchedWhenSliceIDBecomesReady
TestPartialBlockNotDispatchedWhenSliceIDBecomesReady
TestFlushErrorRecordedWhenSliceIDBecomesReady
~~~

### C02 十项

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

---

## 附录 B：final integrity 精确 key 与顺序

runner provisional 前八项：

~~~text
archive_sha256_match
tar_readable
member_set_exact
manifest_coverage_exact
manifest_check_before_archive
manifest_check_after_extract
forbidden_large_members_absent
required_evidence_present
~~~

launcher/finalizer 追加并验证：

~~~text
runner_exit_rc_zero
launch_log_sha_recorded
~~~

最终 `archive.integrity.tsv` 必须精确十行、无 header、无重复、无未知 key、无 PENDING，值只能是 YES/NO。十项全 YES 才允许 PASS。

---

## 附录 C：R2 缺陷到 R3 门禁映射

| R2 缺陷 | R3 防复发门 |
|---|---|
| `$OUT.meta` 路径错误 | static review + missing-prearchive selftest |
| runner rc 非零无法捕获 | `if bash ...` 静态门 + runner-fail rc=17 selftest |
| terminal 两项 PENDING | provisional/final 分离 + pending selftest + 十项 key 门 |
| B count/race actual_pass=0 仍 YES | parser 合成 100/99/no-tests + 18 行逐测试门 |
| replay count actual_pass=0 | R 12 行逐测试门 |
| apply rc 文件缺失 | apply-check/apply 双 rc 硬门 |
| Redis TSV 冒号拼接/硬写 rc | 七列 schema + 每步真实 rc/内容门 |
| archive 多两个未覆盖文件 | manifest 后所有校验写 TERMINAL + tar `-T expected` |
| 没有 archive-members.expected | expected/manifest/tar/extract 四集合门 |
| archived input 删除三个 manifest | assets/input 18 文件 exact set/hash/stat 门 |
| 只校验 runner | launcher/runner/finalizer 三组 executed/input/archived 门 |
| VERIFY 被删除 | VERIFY retained path 硬门 |
| static review 文字误判 | 终态/parser/archive 共 16 个合成 case 的可执行预飞 |

---

## 附录 D：R3 放行后的边界

若且仅若 R3 得到唯一 `PASS-B-PR-READY-LOCAL`：

1. 停止继续同类 main 本地重跑；
2. Codex 先完成最终 patch 代码审阅和 issue/PR 重复性判断；
3. B 的 v1.3 性能验证作为独立 S/A/B 证据线，不反向改变 R3 correctness 结论；
4. 用户明确授权后，才制定社区 issue/PR 提交流程；
5. GitHub Actions、维护者 review 和扩展 CI 属于提交后的独立门；
6. 社区合入前，v1.3 A-sync 仍是已有性能实证的内部兜底，不能把 B 候选当成生产已验证替代品。
