# C03-R5 attempt-3 专用执行补充任务书

> 性质：C03-R5 最后一次 preflight implementation attempt 的执行附录  
> 执行者：GLM  
> 复核者：Codex  
> 任务类型：WSL 本地审计框架实现、合成预飞，以及满足硬门后的 main formal 验证  
> 不属于：C03-R6、性能测试、157/生产验证、社区写操作  
> 核心原则：先证明“裁判会按正确理由拒绝坏证据”，再允许裁判审查补丁

---

## 0. 先读：本附录解决什么

当前暴露的是 R5 harness/oracle/fixture/证据链实现问题，不是 B patch 的新技术
失败。C03-R5 formal 尚未启动，因此 attempt-2 没有重新测试 patch，也不能据此
推翻 C01/C02/C03 已有的技术旁证。

本附录不是让 GLM 给 attempt-2 的 13 个 NO 各加一个 `if`。attempt-2 中原本写为
PASS 的 Terminal 8、Result 10 和 R4 4 项也不能继承，因为 Codex 复核确认：

- 37 行的全部 `evidence` 路径均不存在；
- Terminal 结果按 case ID 硬编码，没有真实调用 finalizer；
- R02～R10 的表头实际均为 12 列，多个负例因错误 schema 碰巧 REJECT；
- Redis/archive/guard 正控不完整；
- R4 四行 evidence 为空，KB04 存在无条件 REJECT；
- formal oracle 只实现了局部检查，未检查的 gate 可能被默认写成 YES；
- producer、27 文件 INPUT 和 formal attempt 均未开始。

attempt-3 要完成的是一次完整、洁净、可审计的 harness 实现。它和此前的区别是：

1. 正控必须真实完整；
2. 每个负例只引入一个预登记的语义缺陷；
3. REJECT 必须命中正确 finding code，不能只比较最终布尔值；
4. Terminal 必须真实执行同一 finalizer；
5. 每个 case 的全部原始输入/输出/rc/hash 永久保留；
6. formal oracle 的 24 gate 和 12 integrity 必须逐项实现，不允许从“没有发现
   finding”推导未执行检查为 YES；
7. 只有 attempt-3 预飞和静态硬门全部通过，才能启动 formal。

---

## 1. 权威文件、优先级与身份

### 1.1 必须完整阅读

执行前必须完整阅读并保存读取确认：

1. 原始 R5 任务书：

   ```text
   /home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C03-R5-upstream-main-independent-oracle-clean-rerun.md
   ```

   固定 SHA256：

   ```text
   7f07976dc54767177582635ddc1161bbcb6ca5fcb08c1ee5e013eef990936cd7
   ```

2. attempt-2 执行报告，尤其是 `Codex 后续复核与阶段裁定`：

   ```text
   /home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R5-execution-20260818-090003.md
   ```

   本附录编写时该报告 SHA256：

   ```text
   8afad19015378e5b996d75778a81fdf24ad37e8131998a8ff8796638ba4dc5f7
   ```

3. 本补充任务书：

   ```text
   /home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C03-R5-attempt3-execution-addendum.md
   ```

### 1.2 优先级

按以下顺序解释要求：

1. 用户本次明确授权与安全边界；
2. 原始 R5 任务书的 formal 矩阵、24 gate、12 integrity、目录和安全要求；
3. 本附录对 attempt-3 的实现与收口要求；
4. attempt-2 报告中的 Codex 后续复核；
5. attempt-2 报告的原始执行者声明，仅作失败历史。

原报告中的“Terminal 8/8 PASS”“Result 10/10 PASS”“只剩 13 个检测”已被 Codex
复核否决，不得作为 attempt-3 输入结论。本附录不改变原任务书的技术测试矩阵；
发生未明确覆盖的冲突时 fail closed，并在报告中记录，不得自行降低原任务书门槛。

### 1.3 本任务书不授予执行权限

必须先取得用户对本轮实际执行的明确授权，把授权原文逐字保存并记录 SHA。未取得
授权时只允许读取这些文档和旧证据；不得创建临时目录、运行脚本、clone/fetch、
Docker 或 Go 命令。

---

## 2. 最终边界和唯一停止规则

### 2.1 attempt 数量

- 本轮是 **preflight implementation attempt-3，最后一次**。
- 不允许 attempt-4，不允许 C03-R6/R7。
- attempt-3 正式预飞一旦启动，脚本、contract、expectation registry 和 fixture
  builder 全部冻结；失败后禁止原地修改再跑。
- attempt-3 全过后，formal 最多两个全新 attempt，沿用原 R5 任务书的限制。

### 2.2 两种 C03 收口路径

```text
attempt-3 任一硬门失败
  => R5-HARNESS-BLOCKED
  => 保存现场和报告
  => C03 结束，不再追加同类 harness 任务

attempt-3 全部硬门通过
  => 冻结 27 文件 INPUT
  => 执行 formal attempt
  => 由原任务书允许终态收口
  => Codex 复核后 C03 结束
```

若选择现在不执行 attempt-3，也只能以 `R5-HARNESS-BLOCKED` 结束，不能写
`PASS-B-PR-READY-LOCAL`。

### 2.3 不允许中途向用户抛 A/B 选择

GLM 在授权范围内自主完成静态实现、只读审计、证据记录和允许的 formal 分支。
官方 attempt-3 失败时直接按硬停止规则交付 BLOCKED 报告，不请求“是否再修一次”。
只有需要新增权限、访问 157/生产或社区写入时才停止并说明；这些动作不属于本任务。

---

## 3. 新路径与旧现场隔离

取得授权后生成新的 `RUN_ID=YYYYmmdd-HHMMSS`，禁止复用 `20260818-090003`：

```text
CTRL=/home/lilingfeng/tmp/juicefs-c03-r5-control-$RUN_ID
PREFLIGHT=/home/lilingfeng/tmp/juicefs-c03-r5-preflight-$RUN_ID
INPUT=/home/lilingfeng/tmp/juicefs-c03-r5-input-$RUN_ID-a<FORMAL_ATTEMPT>
OUT=/home/lilingfeng/tmp/juicefs-c03-r5-$RUN_ID-a<FORMAL_ATTEMPT>
ARCHIVE=/home/lilingfeng/tmp/juicefs-c03-r5-$RUN_ID-a<FORMAL_ATTEMPT>-artifacts.tar.gz
LAUNCH_LOG=/home/lilingfeng/tmp/juicefs-c03-r5-$RUN_ID-a<FORMAL_ATTEMPT>.launch.log
TERMINAL=/home/lilingfeng/tmp/juicefs-c03-r5-$RUN_ID-a<FORMAL_ATTEMPT>-terminal
VERIFY=/home/lilingfeng/tmp/juicefs-c03-r5-verify-$RUN_ID-a<FORMAL_ATTEMPT>
```

每个目标在创建前必须逐字路径执行不存在检查。任一存在就换新 RUN_ID，禁止删除、
清空或复用。

以下 attempt-2 路径只读，禁止复制其中的结果表作为新结果，禁止修改：

```text
/home/lilingfeng/tmp/juicefs-c03-r5-control-20260818-090003
/home/lilingfeng/tmp/juicefs-c03-r5-preflight-20260818-090003
```

可以阅读 attempt-2 脚本理解失败，但不得把其脚本直接作为已验证组件。attempt-3
所有可执行组件必须进入新 CTRL，完成静态审查后冻结 hash。

新报告必须使用新文件，禁止覆盖或续写旧报告原文：

```text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R5-attempt3-execution-$RUN_ID.md
```

---

## 4. attempt-3 一次性执行纪律

### 4.1 冻结前允许做什么

在官方 attempt-3 预飞启动前，允许：

- 编写新的 launcher、producer、oracle、finalizer、fixture builder 和 preflight
  runner；
- 做人工逐行审查；
- 执行不产生语义 verdict 的语法检查，例如 `bash -n`、Python AST/compile 检查；
- 对文件集合、schema 常量、gate 名单做静态 parser 检查；
- 生成但不执行 dry-run command manifest；
- 记录设计变更和与 attempt-2 的 diff。

禁止把部分 fixture/oracle/finalizer 执行包装成“开发调试”以规避 attempt 次数；任何
根据输入产生 ACCEPT/REJECT/final-status 的运行都算 attempt-3 正式预飞的一部分。

### 4.2 冻结点

正式预飞前必须：

1. 完成全部四个 formal 组件和 preflight builder/runner；
2. 完成 machine-readable oracle gate map、finding code registry 和 expectation
   registry；
3. 保存所有源文件 SHA256、size、mode、mtime_ns；
4. 把组件副本设为只读；
5. 写 `attempt3-freeze.tsv`；
6. 在 `controller-state.tsv` 记录 `ATTEMPT3_FROZEN`；
7. 之后仅通过唯一 preflight launcher 执行一次完整 37+4+clean-controls。

任何冻结后的组件变化都使 attempt-3 失败；不得重新标记同一个 attempt。

### 4.3 控制状态

沿用原任务书 11 列 `controller-state.tsv`。至少增加这些不可缺行：

```text
AUTH_SAVED
AUTHORITIES_HASHED
OLD_ATTEMPT_READONLY_SNAPSHOT
ATTEMPT3_STATIC_REVIEW_DONE
ATTEMPT3_FROZEN
ATTEMPT3_PREFLIGHT_STARTED
ATTEMPT3_PREFLIGHT_RC
ATTEMPT3_37_RESULT
ATTEMPT3_R4_RESULT
ATTEMPT3_CLEAN_CONTROLS_RESULT
ATTEMPT3_RENAME_RESULT
ATTEMPT3_BUNDLE_RESULT
FORMAL_ALLOWED_OR_BLOCKED
FINAL_STATUS
REPORT_WRITTEN
```

不允许预先写 DONE/PASS，也不允许进程消失后根据目录存在猜测完成。

---

## 5. 必须重写/完成的组件契约

### 5.1 组件职责

| 组件 | 必须做 | 明确禁止 |
|---|---|---|
| fixture builder | 从完整正控复制 fixture，只施加 registry 指定变异并生成 diff | 生成 oracle verdict；同时破坏多个无关字段 |
| preflight runner | 逐 case 调真实 oracle/finalizer，保存所有原始输出，独立比较 expectation | 按 case ID 直接填 actual；删除 case 目录 |
| `oracle-r5.py` | 从 raw evidence 逐 checker/逐 gate复算，输出 finding code、24 gate、12 integrity | 读取 expected verdict；按 case ID 分支；无 finding 即批量 YES |
| `terminal-finalize-r5.py` | 检查固定 key、重复、枚举、runner/oracle rc、producer-oracle 一致性并映射允许终态 | 自造状态；忽略 `oracle.rc`；覆盖/删除证据 |
| `run-c03-r5.sh` | 执行 original R5 formal producer，保存 raw log/rc/hash，冻结 archive 前停止写 payload | 写最终 PASS；复制 oracle gate；修改旧证据 |
| `launch-c03-r5.sh` | 精确捕获各 rc，无论 producer rc 均调用 oracle/finalizer | `|| true` 掩盖 rc；从 console 摘要推导结果 |

### 5.2 Oracle 内部状态

每个 checker 和 24 个 formal gate 在内部初始状态必须是 `NOT_EVALUATED`。只有对应
检查真实执行、所需证据全部存在、解析成功且条件满足，才可转为 YES。输出文件虽然
只允许 YES/NO，但任何内部 `NOT_EVALUATED`、异常、缺文件或未知枚举都必须输出 NO
和稳定 finding code。

禁止以下实现：

```text
if not all_findings: all_gates = YES
if any_finding: all_gates = NO
if case_id == ...: return expected_verdict
copy producer gate status into oracle output
catch Exception: return ACCEPT
```

每个 gate 必须在 `oracle-gate-map.tsv` 中精确一行：

```text
gate	checker_function	required_evidence	pass_expression	finding_codes
```

该文件的 gate 集必须与原任务书 §10 的 24 项完全相等；静态 parser 要拒绝缺失、
重复、未知 gate，以及多个 gate 仅指向一个 blanket checker 的实现。

### 5.3 Preflight mode 限制

允许同一 oracle 通过显式 contract 选择 `preflight` 或 `formal` 数据规模，但：

- 只能改变 miniature fixture 的合法行数、工具名和根路径；
- contract 必须在所有同组 case 中逐字节相同并进入 bundle/hash；
- 不得跳过该 case 所测试的 checker 家族；
- 不得使用 `R5_PREFLIGHT=1` 把 formal-only 检查直接写 YES；
- preflight 与 formal 必须使用同一 checker 函数；
- oracle 不得读取 `expected`、`matched`、case 名或 expectation registry。

### 5.4 稳定 finding code

`oracle-findings.tsv` 至少包含：

```text
checker	finding_code	status	evidence	detail
```

`detail` 可包含动态路径；`finding_code` 必须来自冻结 registry。判定负例成功要求命中
对应 code。仅得到 REJECT、但 finding code 不对，必须 `matched=NO`。

### 5.5 退出码

统一约定：

```text
oracle/checker ACCEPT       => rc=0
oracle/checker evidence REJECT => rc=1
harness/config/parser crash => rc>=2
finalizer PASS              => rc=0
finalizer 非 PASS 允许终态  => rc=1
```

rc>=2 绝不能当成一个成功的负例。

---

## 6. 完整正控宇宙

先创建并冻结一个 `_valid` 正控宇宙，再从它复制 R/D/A/G fixture。不能分别临时拼装
负例。正控至少满足：

### 6.1 Result 正控

- 四张 miniature result TSV 均使用精确 14 列：

  ```text
  arm	tool	mode	test	actual_rc	expected_pass	actual_pass	expected_fail	actual_fail	expected_marker	actual_marker	bad	log	expectation_matched
  ```

- 每个物理行只对应一个测试，唯一键 `(arm,tool,mode,test)` 无重复；
- raw log、`.rc`、log SHA/size 均存在并与行内容匹配；
- PASS/FAIL/marker 使用锚定模式复算；
- `bad`、`expectation_matched` 均为合法枚举；
- 无 `no tests to run`、panic、fatal、timeout、DATA RACE 等 bad pattern。

### 6.2 Redis 正控

- 表头和每个物理数据行精确七列；
- 按冻结的 `redis-steps.expected` 为两个 miniature tool 提供完整、唯一步骤；
- 每个 `actual_rc` 与独立 rc sidecar 相等；
- PONG、inspect、log、CID、vfs、stop、gone 内容均有独立 raw evidence；
- 不把冒号打包串拆开后“修复性接受”。

### 6.3 Archive 正控

- payload 中存在真实普通文件；
- `archive-members.expected`、manifest、tar regular members、extract regular files
  的 Counter/multiset 完全一致且各自无重复；
- 三个规定 diff sidecar 即使为空也真实存在；
- freeze snapshot 含 path、size、mode、mtime_ns、SHA；
- freeze 后没有新增或修改 payload；
- tar 可读，hash 正确，VERIFY 启动前不存在且解包后保留。

### 6.4 Guard 正控

- 使用以 `# C03-R5` 开头的正确 taskbook 副本，source/copy hash 相同；
- miniature source clone 使用真实 git 状态，tracked/clean；
- protected-path before/after 清单和 hash 相同；
- input expected/stat/SHA 身份闭合；
- VERIFY 不存在；
- oracle 执行前后 SOURCE 和固定历史资产无变化。

### 6.5 Terminal 正控

- producer 24 gate 精确且全 YES；
- oracle 24 gate 精确且全 YES；
- producer/oracle 语义一致；
- 12 integrity 精确且全 YES；
- R4 四行精确且 matched=YES；
- `prearchive-status.txt=ALL-REQUIRED-GATES-YES`；
- runner rc=0、oracle rc=0、launch-log hash 存在；
- 真实 finalizer 输出 `PASS-B-PR-READY-LOCAL`。

正控自身任一缺项时禁止生成负例；不得靠 oracle 的 preflight skip 接受不完整正控。

---

## 7. 37 个 case 的唯一实现表

### 7.1 通用判定

每个负例必须有：

```text
base.sha256
mutation.spec.tsv
mutation.diff
expected-verdict.txt
expected-findings.tsv
oracle-command.json
oracle.stdout
oracle.stderr
oracle.rc
oracle-findings.tsv
evidence.index.tsv
```

Terminal case 另外必须保存 finalizer 输入副本、stdout、stderr、rc、
`final-status.txt` 和 `finalizer-findings.tsv`。`evidence.index.tsv` 列出相对路径、size、SHA，且
`preflight-results.tsv.evidence` 必须指向这个真实存在的文件。

`matched=YES` 的条件是以下全部成立：

1. actual 与 expected verdict 相同；
2. rc 语义正确且不是 harness crash；
3. 预登记 finding code 全部命中；
4. 不存在未登记的无关 finding code；
5. evidence index 中所有文件存在且 hash 成功；
6. fixture 与 `_valid` 的差异只包含登记 mutation。

### 7.2 Terminal/finalizer：8 case

所有 case 都真实调用冻结后的同一 `terminal-finalize-r5.py`：

| case | 相对 T01 的唯一语义变异 | expected | 必须命中 |
|---|---|---|---|
| `T01-valid` | 无 | ACCEPT；`PASS-B-PR-READY-LOCAL`；rc=0 | 无 finding |
| `T02-runner17` | runner rc 从 0 改为 17 | REJECT；`R5-TECHNICAL-FAIL`；rc=1 | `FINALIZER_RUNNER_RC_NONZERO` |
| `T03-producer-gate-no` | producer 的 `B_community_single` 改为 NO | REJECT；`R5-TECHNICAL-FAIL` | `FINALIZER_PRODUCER_GATE_NO` |
| `T04-oracle-gate-no` | oracle 的 `B_community_single` 改为 NO | REJECT；`R5-NON-COMPLIANT` | `FINALIZER_ORACLE_GATE_NO` |
| `T05-integrity-no` | `required_evidence_present` 改为 NO | REJECT；`R5-NON-COMPLIANT` | `FINALIZER_INTEGRITY_NO` |
| `T06-missing-key` | 删除 oracle gate `input_integrity` | REJECT；`R5-NON-COMPLIANT` | `FINALIZER_KEYSET_MISMATCH` |
| `T07-duplicate-key` | 重复 oracle gate `input_integrity` | REJECT；`R5-NON-COMPLIANT` | `FINALIZER_DUPLICATE_KEY` |
| `T08-pending-unknown` | oracle gate `input_integrity` 改为 PENDING | REJECT；`R5-NON-COMPLIANT` | `FINALIZER_INVALID_ENUM` |

`final_status` 列必须写真实 `final-status.txt` 内容，禁止写 `terminal-passed`、
`findings=N` 或 `RUNNER-FAILED-rc=17`。finalizer 必须读取并验证 `oracle.rc`；缺失、
非整数或非零与全 YES 自相矛盾时 fail closed。

### 7.3 Result/raw-log：10 case

R02～R10 只修改四张 valid miniature result 表中的一个指定目标表；其余三张保持
正控。除表中明确说明的语义变异外，不得同时改变 schema 或四张表：

| case | 唯一语义变异 | expected | 必须命中 |
|---|---|---|---|
| `R01-valid14` | 无；header/data 均 14 列 | ACCEPT | 无 finding |
| `R02-header13` | 仅目标表 header 删除末列，实际 13 列 | REJECT | `RESULT_HEADER_WIDTH` |
| `R03-data13` | 保持 14 列 header，目标数据行删除 `bad` 字段 | REJECT | `RESULT_ROW_WIDTH` |
| `R04-data15` | 保持 14 列 header，目标数据行增加一个字段 | REJECT | `RESULT_ROW_WIDTH` |
| `R05-invalid-enum` | 一个 `bad` 单元从 NO 改为 `0` | REJECT | `RESULT_INVALID_ENUM` |
| `R06-duplicate-row` | 增加一行相同唯一键 | REJECT | `RESULT_DUPLICATE_KEY` |
| `R07-count99` | 一次 count100 执行只有 99 PASS；raw 与 actual_pass 都诚实写 99 | REJECT | `RESULT_EXPECTED_COUNT_MISMATCH` |
| `R08-no-tests` | rc=0 的 raw log 改成 `warning: no tests to run` | REJECT | `RESULT_NO_TESTS` |
| `R09-raw-mismatch` | TSV 保持 100，raw log 删除一个 PASS 后只有 99 PASS | REJECT | `RESULT_RAW_TSV_MISMATCH` |
| `R10-log-missing-hash` | 删除行所指 raw log，其他字段不变 | REJECT | `RESULT_LOG_MISSING` |

R02 的 header 必须实测为 13 列；R03 为 header 14/data 13；R04 为
header 14/data 15。runner 在 oracle 前把这些物理列数写入 case evidence，禁止依赖
`csv.DictReader` 填充后的 dict 长度。

### 7.4 Redis：5 case

| case | 唯一语义变异 | expected | 必须命中 |
|---|---|---|---|
| `D01-valid7` | 完整正控，所有物理行七列、步骤完整唯一 | ACCEPT | 无 finding |
| `D02-r4-packed-real` | 仅把目标 lifecycle TSV 替换为真实 R4 文件 | REJECT | `REDIS_ROW_WIDTH` |
| `D03-duplicate-step` | 复制一个 `(tool,step)` 数据行 | REJECT | `REDIS_DUPLICATE_STEP` |
| `D04-missing-step` | 删除一个 tool 的 `gone` 必需步骤 | REJECT | `REDIS_MISSING_STEP` |
| `D05-wrong-rc-content` | 将一个 run rc sidecar 从 0 改为 1，TSV 保持 0 | REJECT | `REDIS_RC_CONTENT_MISMATCH` |

D02 必须直接读取固定 hash 的真实文件：

```text
/home/lilingfeng/tmp/juicefs-c03-r4-20260818-004733/meta/redis-lifecycle.tsv
SHA256=6767289f078e892bdae7a89ca944de5add970fa1e91746ea8a366fc492a71551
```

不得重新手写一个“类似 R4”的冒号串代替真实资产。

### 7.5 Archive/freeze：9 case

| case | 唯一语义变异 | expected | 必须命中 |
|---|---|---|---|
| `A01-valid` | expected/manifest/tar/extract Counter 精确，diff sidecar 完整 | ACCEPT | 无 finding |
| `A02-expected-duplicate` | expected 中重复 `payload/file1` | REJECT | `ARCHIVE_EXPECTED_DUPLICATE` |
| `A03-r4-tar-real` | 直接检查固定 hash 的真实 R4 archive | REJECT | `ARCHIVE_TAR_DUPLICATE` |
| `A04-manifest-missing` | manifest 删除 `payload/file2` | REJECT | `ARCHIVE_MANIFEST_MISSING` |
| `A05-manifest-extra` | manifest 增加未预期的 `payload/extra` | REJECT | `ARCHIVE_MANIFEST_EXTRA` |
| `A06-tar-extra-or-missing` | tar 增加未预期的 `payload/extra` | REJECT | `ARCHIVE_TAR_MULTISET_MISMATCH` |
| `A07-extract-extra-or-missing` | extract 删除预期的 `payload/file2` | REJECT | `ARCHIVE_EXTRACT_MULTISET_MISMATCH` |
| `A08-missing-sidecars` | 删除 `manifest-vs-expected.diff` | REJECT | `ARCHIVE_SIDECAR_MISSING` |
| `A09-post-freeze-mutation` | freeze 后只修改 `payload/file1` 内容 | REJECT | `ARCHIVE_PAYLOAD_FREEZE_CHANGED` |

A03 必须直接读取：

```text
/home/lilingfeng/tmp/juicefs-c03-r4-20260818-004733-artifacts.tar.gz
SHA256=d014b8ebc5a3bae420c92fe3521397598a70b47338793a54e09cc77f9dd52047
```

不能只复制 R4 的 `archive-members.expected` 来冒充真实 archive 检查。expected、
manifest、tar、extract 必须分别先检查 duplicate，再用 Counter 比较；集合比较无效。

### 7.6 Guard/input：5 case

| case | 唯一语义变异 | expected | 必须命中 |
|---|---|---|---|
| `G01-valid` | taskbook/input/source/protected/VERIFY 全满足 | ACCEPT | 无 finding |
| `G02-preexisting-verify` | oracle 启动前创建 VERIFY，并记录其内容/hash | REJECT | `GUARD_VERIFY_PREEXISTS` |
| `G03-untracked-source` | clean miniature clone 中新增 `src/B/test.db` | REJECT | `GUARD_SOURCE_UNTRACKED` |
| `G04-protected-change` | before snapshot 后只修改 `protected/asset.txt` | REJECT | `GUARD_PROTECTED_CHANGED` |
| `G05-wrong-taskbook` | 正确 taskbook 替换为真实 R4 C03-R3 taskbook | REJECT | `GUARD_TASKBOOK_IDENTITY` |

G02 运行后必须证明预存 VERIFY 内容/hash 未变且没有被删除。G05 使用真实文件：

```text
/home/lilingfeng/tmp/juicefs-c03-r4-20260818-004733/assets/input/taskbook.md
```

不得只写一个九字节的 `# C03-R3` 合成文件。

---

## 8. R4 real-known-bad 四项与反“永远 REJECT”正控

### 8.1 固定资产

启动时按原任务书 §0.1 重算所有 R4 固定 hash。任一漂移：

- 不修改旧资产；
- 不继续把漂移项当真实负例；
- 记录子原因 `R4-REFERENCE-DRIFT`；
- 总状态 `R5-HARNESS-BLOCKED` 并结束 attempt-3。

### 8.2 四个独立检查

`r4-known-bad-results.tsv` 精确八列、四行，case 名沿用原任务书。每行必须：

- 单独调用对应 checker；
- `asset` 指向直接读取的真实资产；
- `evidence` 非空并指向存在的 evidence index；
- expected/actual 均 REJECT；
- standalone checker rc=1；
- matched=YES；
- finding code 与对应缺陷一致。

KB04 不得无条件 REJECT。它必须真实读取：

- R4 的 24/24 candidate gate 声明；
- R4 的 10 项 integrity 与 PASS 声明；
- KB01～KB03 从真实资产得到的结果；
- 由这些输入计算“声明与事实矛盾”。

### 8.3 clean controls

除正式四行外，必须为 KB01～KB04 每个 checker 提供一个 clean surrogate，证明同一
checker 在缺陷不存在时会 ACCEPT。写：

```text
r4-known-bad-clean-controls.tsv
```

精确四行且全部 ACCEPT/rc=0/matched=YES。该文件和证据进入 preflight bundle，
但不改变原任务书规定的正式 `r4-known-bad-results.tsv` 四行结构。

若真实坏例 REJECT、但 clean control 也 REJECT，该 checker 属于恒拒绝，attempt-3
失败。

---

## 9. 防作弊、改名复跑和证据保留

### 9.1 静态硬门

冻结前通过可执行 parser 生成 raw 输出和 rc，至少检查：

1. oracle/finalizer 源码不含 37 个 case ID；
2. oracle 不读取 expectation registry、expected verdict 或 `matched`；
3. runner 不按 case ID 直接构造 actual；case ID 只可用于选择 builder mutation 和
   runner 侧 expected；
4. 没有 `shutil.rmtree`、`rm -rf`、`unlink` 或清理 VERIFY/case evidence 的路径；
5. launcher 无 `|| true` 掩盖 rc；
6. finalizer 的输出只可能是原任务书 §1.3 八种允许终态；
7. runner rc=17 映射为 `R5-TECHNICAL-FAIL`；
8. finalizer 检查 `oracle.rc`，缺失/异常/矛盾 fail closed；
9. 24 gate map 和 12 integrity key 精确、唯一、无未知项；
10. oracle 没有“无 finding 则所有 gate YES”的 blanket 分支；
11. producer 不写最终 PASS，不调用/import oracle checker；
12. oracle 不读取 producer gate status 后复制；
13. preflight runner 不删除任何 terminal/fixture/失败现场；
14. result/Redis 使用原始物理 tab 列宽校验，而非 DictReader dict 长度；
15. archive 使用 Counter/multiset，并检查 duplicate；
16. source guard 检查真实 git untracked/changed 状态；
17. taskbook 身份同时校验首行、source/copy hash 和固定原 R5 taskbook SHA；
18. Python/Bash 语法检查成功且没有生成未登记 cache 文件。

手写 Markdown “YES”不算静态硬门；必须保存命令、stdout/stderr、真实 rc 和 parser
结果。

### 9.2 改名复跑

37/37 首轮完成后、汇总前：

1. 从 29 个非 Terminal case 中用一次保存的随机 seed 选择三个不同组的负例；
2. 只更改 fixture 目录名和外部显示名，不改内容、contract 或 mutation；
3. 使用同一冻结 oracle 再跑；
4. verdict、finding code 集和 rc 必须与改名前一致；
5. 保存 seed、chosen cases、before/after command/output/hash。

任一变化说明 oracle 依赖名字，attempt-3 失败。禁止人工挑选“容易通过”的三例。

### 9.3 禁止删除证据

- 不得在 case 后删除 terminal directory；
- 不得删除失败 fixture；
- 不得删除或重建 preexisting VERIFY；
- 空 diff 也保留为零字节普通文件并进入 hash；
- 所有 case evidence 在 bundle 创建前后做 path/size/SHA 对比；
- bundle 创建后不得回写其内部来源目录再伪造 hash。

---

## 10. 37 行、bundle 与正式准入公式

### 10.1 `preflight-results.tsv`

精确九列、37 个数据行，case 名必须与 §7 完全一致：

```text
case	group	fixture	expected	actual	oracle_rc	final_status	evidence	matched
```

字段约束：

- `expected/actual` 只能 ACCEPT/REJECT；
- `oracle_rc` 只能按 §5.5；T 组记录被测 finalizer 的真实 rc，R/D/A/G 组记录
  oracle 的真实 rc；
- Terminal 的 `final_status` 是真实允许终态；
- R/D/A/G 的 `final_status` 固定写 `N/A`，不得写 `findings=N`；
- `evidence` 是 PREFLIGHT 下存在的相对 evidence index；
- `matched` 只能 YES/NO，且按 §7.1 六条件计算；
- 精确 8+10+5+9+5，无重复/未知/漏项。

### 10.2 Bundle

`preflight-bundle.tar.gz` 至少包含：

- 冻结的 builder、runner、oracle、finalizer 和静态审查证据；
- `_valid` 正控 contract 与 hash；
- 37 个 fixture 的 mutation spec/diff 和全部 evidence；
- 三例改名复跑证据；
- R4 四项的绝对路径/hash/只读命令/结果/evidence index；
- 四个 R4 clean controls；
- 本补充任务书逐字副本及 source/copy hash；
- `attempt3-freeze.tsv`、gate map、finding registry、expectation registry。

不得把真实 R4 archive 本体装入 bundle。bundle 内所有路径必须相对、安全、无 `..`、
无绝对路径成员、无 symlink/hardlink/device/FIFO。

### 10.3 `preflight-SHA256SUMS`

按原任务书只覆盖并精确覆盖：

```text
preflight-bundle.tar.gz
preflight-results.tsv
r4-known-bad-results.tsv
```

从 PREFLIGHT 原位和之后的 formal INPUT 两处分别校验成功。bundle 内部文件由 bundle
内独立 manifest 覆盖。

### 10.4 正式准入公式

仅当以下全部成立才写 `FORMAL_ALLOWED=YES`：

```text
attempt-3 frozen component hash unchanged
AND 37/37 matched=YES with expected finding codes
AND five positive controls T01/R01/D01/A01/G01 ACCEPT with zero finding
AND R4 real-known-bad 4/4 REJECT
AND R4 clean controls 4/4 ACCEPT
AND rename rerun 3/3 invariant
AND all 37 evidence indexes exist and hash verify
AND static hard gates all pass with raw rc
AND bundle safe/readable/complete
AND preflight-SHA256SUMS verifies
AND formal producer/oracle/finalizer/launcher implementation complete
```

缺任一项：

```text
FORMAL_ALLOWED=NO
final status=R5-HARNESS-BLOCKED
禁止 clone/fetch/Go/Docker/formal
```

---

## 11. 27 文件 INPUT 冻结

formal allowed 后严格沿用原任务书 §6 的精确 27 文件集合、生成顺序和权限。特别
说明：

- `taskbook.md` 仍是原始 R5 任务书的逐字副本，SHA 必须为 `7f0797...936cd7`；
- 本附录逐字副本放入 `preflight-bundle.tar.gz/authority/`，不额外增加第 28 个
  INPUT 顶层文件；
- `pre-run-adaptations.md` 记录本附录 source path、source SHA、bundle copy SHA 和
  优先级；
- preflight 使用的 oracle/finalizer SHA 必须与 INPUT、executed、archive 中副本
  完全相等；
- INPUT 27 个普通文件全部 0444，目录 0555；
- `input.expected-files`、`input.stat.tsv`、`input.sha256` 的覆盖范围和生成顺序严格
  按原任务书，不得省略或手工补表。

INPUT freeze 后任何组件变化都禁止 formal；不得在 INPUT 内修脚本。

---

## 12. Formal 阶段：不改变技术矩阵

attempt-3 预飞通过后，formal 完全执行原 R5 任务书，不因本附录减少任何项目：

1. 官方 main 三点稳定冻结和 policy/CI parser；
2. S/stock 46 行；
3. B/community 18 行；
4. Q/semantic 60 行；
5. R/replay 12 行；
6. 双工具链 full `pkg/vfs`、Redis 生命周期、gofmt/license/tidy/vet/lint、
   Linux/lite build；
7. 标准 patch apply/replay、source/untracked/protected guards；
8. 匿名只读社区查重与草稿/secret scan；
9. producer 独立生成 24 gate；
10. archive 严格冻结；
11. oracle 从 raw evidence 独立复算 24 gate 和 12 integrity；
12. finalizer 按唯一公式产生允许终态。

formal 仍不回答真实 Ceph randwrite 性能、v1.3 生产替换和官方 GitHub CI。

### 12.1 Formal attempt-2 的限制

formal attempt-1 若失败：

- 技术矩阵真实失败：按 `R5-TECHNICAL-FAIL` 收口，不挑选重跑；
- upstream/main/policy/patch 漂移：按原任务书对应允许终态收口；
- 单纯瞬时基础设施失败，且所有冻结组件字节不变：可用全新路径完整执行 formal
  attempt-2；
- 需要修改 oracle、finalizer、contract 或 expectation registry：不能再证明与
  attempt-3 同一预飞组件，直接 `R5-HARNESS-BLOCKED`，禁止 attempt-4；
- 需要修改 producer/launcher：仅在 oracle/finalizer hash 不变、问题不影响
  attempt-3 自证、重新完成静态审查和全新 INPUT freeze 时允许 formal attempt-2；
- formal attempt-2 仍有 harness/audit 缺陷：`R5-HARNESS-BLOCKED` 并结束 C03。

所有失败 attempt 永久保留；禁止向同一 OUT 补行、补 log、补 manifest 或补报告来
改变终态。

---

## 13. 安全和禁止事项

本附录不扩展原授权。除非用户另行明确授权，本轮仍禁止：

- SSH/157、生产主机、生产 Redis、Ceph/TiKV；
- fio、mount、drop_caches、format、compact、服务重启；
- sudo、系统包安装和系统配置修改；
- Docker prune、模糊 kill/remove；
- commit、push、fork、tag、branch；
- issue/PR/comment 或任何社区写 API；
- 携带 GitHub token/cookie/auth header；
- 删除旧现场、失败现场、VERIFY 或用户文件；
- 修改固定 patch/test/history 资产；
- 把本地功能结果表述为性能恢复、生产验证或官方 CI 通过。

Docker 只允许管理本轮精确记录的 CID；trap 只能作用于该 CID。匿名网络只读操作按
原任务书和用户授权执行。任一权限边界不确定时 fail closed。

---

## 14. 交付报告

无论 attempt-3 在何处停止，都必须写新报告。报告至少包含：

1. 用户授权原文/hash；
2. 三份 authority source path/hash 和优先级；
3. 新 RUN_ID 及全部绝对路径；
4. attempt-2 只读快照与未修改声明；
5. attempt-3 freeze 的组件 hash；
6. 37 行完整表和按组统计；
7. 每个 NO 的 expected/actual/expected finding/actual finding/evidence；
8. 五个正控（T01/R01/D01/A01/G01）、R4 4 个真实坏例、R4 4 个 clean control；
9. 三例改名复跑；
10. 所有 evidence 存在性/hash 统计；
11. 静态硬门逐项 raw rc；
12. bundle/manifest/tar safety 统计；
13. `FORMAL_ALLOWED` 公式逐项结果；
14. 若 formal 启动：main commit、四矩阵、双工具链、24+24 gate、12 integrity、
    runner/oracle/finalizer rc 和唯一终态；
15. 所有 runtime adaptation、失败 attempt 和未执行项；
16. 明确声明没有执行性能、157、生产、社区写入和越权动作。

禁止只写“37/37”“4/4”“全绿”而不提供逐 case 表和 evidence。禁止在报告中把
未执行项补成 PASS。

### 14.1 GLM 最终回复模板

```text
RUN_ID：
authority hashes：base taskbook / attempt-2 reviewed report / attempt-3 addendum
attempt-3 frozen component hashes：

37-case：<matched>/37
positive controls：T01 / R01 / D01 / A01 / G01
expected finding code matched：<n>/32 negative cases
R4 real-known-bad：<matched>/4
R4 clean controls：<matched>/4
rename invariant：<matched>/3
all evidence exists/hash verifies：YES/NO
static hard gates：<matched>/<total>
preflight bundle/SHA：
FORMAL_ALLOWED：YES/NO

若 NO：
final status：R5-HARNESS-BLOCKED
first failing gate/case：
expected / actual / finding code / evidence：
C03：结束，不请求 attempt-4/R6

若 YES 且 formal 已完成：
formal attempt：
frozen main：
stock 46 / B 18 / Q 60 / R 12：
producer gates：<YES>/24
oracle gates：<YES>/24
integrity：<YES>/12
runner/oracle/finalizer rc：
final status：

report：
声明：未执行性能、157、生产或社区写入；未修改旧证据；等待 Codex 复核。
```

---

## 15. Codex 复核入口

GLM 交付后停止，不自行创建社区 issue/PR。Codex 将优先复核：

1. authority 和 frozen component identity；
2. 正控是否完整、负例是否单一变异；
3. REJECT 是否命中正确 finding code；
4. 37 个 evidence 是否真实存在；
5. oracle 是否逐 gate 独立而非 blanket verdict；
6. Terminal 是否真实执行 finalizer；
7. R4 checker 是否有 clean control，KB04 是否非恒拒绝；
8. preflight/formal oracle SHA 是否一致；
9. formal 原始日志、rc、matrix 和 archive Counter；
10. 最终状态是否满足原任务书唯一公式。

只有 Codex 完成上述复核，才能裁定 C03 为 PASS、官方已修复、技术失败或规定的
BLOCKED，并与用户讨论社区提交或 v1.3 后续工作。
