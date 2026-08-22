# C03-R5：独立反例 Oracle 驱动的 main 社区候选洁净重跑

> 面向执行方：GLM  
> 方案与结果复核：Codex  
> 日期：2026-08-18  
> 性质：C03-R3/R4 技术日志有价值、但 runner 自证产生假阳性后的审计重建；不占 03 阶段性能任务编号  
> 执行范围：仅 WSL 本地临时目录、隔离 Docker Redis、匿名只读 GitHub；不连接 157，不访问生产 Ceph/TiKV/Redis  
> 上游：执行时重新冻结官方 `https://github.com/juicedata/juicefs` 的稳定 `main`  
> 唯一正式入口：冻结后的 `launch-c03-r5.sh RUN_ID ATTEMPT`  
> 核心原则：producer 只生产证据，独立 oracle 只读复算；oracle 必须先拒绝真实 R4 坏包，才允许执行任何 Go 测试  
> 禁止：修改旧证据、复用旧 PASS/log/rc/src/cache/build、运行性能/生产测试、使用 sudo，以及任何 GitHub/community 写操作

---

## ⚑ 计划线

```text
C01-R1 / C02
  └─ 确定性复现：异步 slice ID 就绪后漏派整块 FlushTo；B 修正该行为
C03 / R1 / R2
  └─ 技术测试多次通过，执行与归档证据链持续不闭合
C03-R3 / R4
  ├─ main/B 原始测试仍支持功能结论
  └─ 13 列、Redis 三列、tar 重名等被错误判成全绿，PR-ready 无效
★ C03-R5（你在这里）
  ├─ 独立审计 R4 并固定为 KNOWN-BAD 负例
  ├─ 用同一只读 oracle 跑 37 个接受/拒绝用例
  ├─ 预飞全过后，在最新 main 上完整洁净重跑
  └─ producer 24 门 + oracle 24 门 + 12 终态门全绿才可 PASS
  ↓
  ├─ PASS：交 Codex 做最终代码/重复性审核，再由用户决定社区提交
  └─ FAIL/DRIFT：保留现场，禁止以历史 PASS 兜底
后续独立线
  └─ V01-R2 远端 ABI → pool-object 诊断 → v1.3 S/A/B 性能
```

一句话：本轮不是再堆测试次数，而是先证明审计器会拒绝已知坏证据，再从全新 main 现场生成一条不依赖 runner 自我声明的社区候选证据链。

---

## 〇、背景、正式订正与不可继承项

### 0.1 C03-R4 正式裁定

R4 报告：

```text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/V01-R1-execution-20260818-001227.md
```

R4 原始现场：

```text
/home/lilingfeng/tmp/juicefs-v01-r1-20260818-001227/c03-r4
/home/lilingfeng/tmp/juicefs-c03-r4-20260818-004733
/home/lilingfeng/tmp/juicefs-c03-r4-20260818-004733-terminal
/home/lilingfeng/tmp/juicefs-c03-r4-20260818-004733-artifacts.tar.gz
```

本任务启动时先只读重算下列固定 hash；任一不符只标记 `R4-REFERENCE-DRIFT`，保存实际值并停止使用该项作真实负例，不得修改旧现场：

| R4 资产 | SHA256 |
|---|---|
| `run-c03-r4.sh` | `9458d9004d5e7cfd1c3043e15b945d02b58fc49a97e574fbeaa7df882b3ed305` |
| `launch-c03-r4.sh` | `2b6a55b64035c36b56d60180e3c6d58a5f21ab448d8f11e730ee9ec6528548d8` |
| `terminal-finalize.sh` | `ad145c7cd6867597ea23656507fda02dcd95c37612f86d35437d5815175d75fd` |
| `summary.tsv` | `7b740f0dd6921c47f09833bf1308b8d11a0cd311bca3c2db3b2475c32bb81849` |
| `meta/redis-lifecycle.tsv` | `6767289f078e892bdae7a89ca944de5add970fa1e91746ea8a366fc492a71551` |
| `meta/archive-members.expected` | `5c8c153b75a8f5d11fd42d105547d712c70f36666da09cd05a3ed5f29f6d0a0e` |
| `candidate-gates.tsv` | `e2270c689944c2d485b06d375747b95a4220a66b442ed85b581cc32dc319e9e0` |
| terminal `archive.integrity.tsv` | `42d69dc10e50f5df8a27f2be339ccc8adb885530d368cbc72be1b3e5be782372` |
| R4 archive | `d014b8ebc5a3bae420c92fe3521397598a70b47338793a54e09cc77f9dd52047` |

R4 的有效和无效部分必须分开：

```text
C03-R4 = FUNCTIONAL RAW EVIDENCE PRESENT
        + RUNNER / TERMINAL / ARCHIVE INVALID
        + PR-READINESS BLOCKED
```

可作历史旁证：stock 与 B 的原始 Go 日志、补丁可标准应用、双工具链测试/build 的实际日志。不得继承：24/24 YES、10/10 YES、`PASS-B-PR-READY-LOCAL`、R4 archive 完整性和“全部 R3 缺陷已修复”的文字结论。

### 0.2 R4 已确认的假阳性根因

R5 必须逐项关闭，禁止再写“R3 已基本处理”：

1. result 表头和数据仍为 13 列，缺 `expectation_matched`；部分 single 行又少 `bad`，导致 `log` 左移；
2. result gate 主要看进程 rc 或模糊 grep，没有从每个原始日志独立复算 PASS/FAIL/marker；
3. Redis 表头七列，但数据用 `tool + 冒号拼接串` 写成三列；
4. `archive-members.expected` 在重定向创建后被 `find` 找到，又被显式加入，造成同一路径两次；
5. archive 用集合比较，忽略路径 multiplicity，tar 内重名仍写 `member_set_exact=YES`；
6. expected/manifest/tar/extract 三个 diff sidecar 没有生成；
7. runner 在正式 extraction 前执行 `rm -rf "$VERIFY"`，可覆盖旧证据；
8. payload/manifest/archive 冻结后又写 `meta/final-compliance-review.md`；
9. static review 只是手写 YES，且明确称“13-column TSV”，没有执行 R4 要求的 parser/archive/source 负例；
10. R4 input 中的 `taskbook.md` 实际仍是 C03-R3 任务书，未冻结本轮权威要求。

### 0.3 本轮固定业务资产

只读来源及固定 SHA：

| 资产 | 来源 | SHA256 |
|---|---|---|
| B writer patch | `/home/lilingfeng/tmp/juicefs-c03-r2-input-20260817-182702/async-catchup-main.patch` | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` |
| 社区三项测试 | `/home/lilingfeng/tmp/juicefs-c03-r2-input-20260817-182702/writer_flush_test.go` | `bce85ad4abf92a47074849a544aaa756963fb44a1839619bbc71c5d7ce1fe9bc` |
| C02 十项测试 | `/home/lilingfeng/tmp/juicefs-c03-r2-input-20260817-182702/writer_flush_c02_test.go` | `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` |

固定参考：

| 项 | 值 |
|---|---|
| C02 base | `edabf9c24601510476e7453abff177f4aaca07ac` |
| 历史 main | `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`，仅作祖先/变化参考 |
| 历史最终两文件 patch | `1050e94f6f2f52091a99afd4ad2aaf3c6cde1475909f28b48b377e72b5281f9`；仅当 writer base blob 未变时要求相等 |
| 官方 remote | `https://github.com/juicedata/juicefs` |
| 只读 object seed | `/home/lilingfeng/project/juicefs`；禁止在此 fetch/checkout/apply/build/test |
| 主工具链 | `GOTOOLCHAIN=go1.25.7` |
| 兼容工具链 | `GOTOOLCHAIN=local`，记录实际版本，不预先伪定 |
| Redis | `redis:7.2-alpine`，运行时冻结 image ID/RepoDigest |

仓库中的 `patch/juicefs-flush-race-fix-main.patch` 不是本轮固定两文件社区输入，禁止用它替换上述三个资产。

---

## 一、目标、问题与允许终态

### 1.1 唯一通过问题

在执行时稳定冻结的官方 main 上，能否同时满足：

1. stock 确定性表现为 U1/U3 指定失败、U2 通过；
2. B 保留异步 `NewSlice`，在同一 main 上纠正 ID-ready 后漏掉的完整块 dispatch；
3. 社区三项、C02 十项、race、完整 `pkg/vfs`、lint/build/replay 全部符合精确矩阵；
4. 与 producer 完全独立的只读 oracle 能从原始日志、rc、文件内容和 archive multiset 复算出相同结论；
5. R4 真实坏包和全部合成坏例均被该 oracle 拒绝。

只有以上五项同时成立才允许 `PASS-B-PR-READY-LOCAL`。

### 1.2 本轮不回答的问题

- 不证明真实 Ceph randwrite 性能恢复；
- 不证明 v1.3 B 已达到生产可替换状态；
- 不证明数据完整性事故已被修复；
- 不代表 GitHub Actions 或维护者 review 已通过；
- 不自行判断社区一定不存在重复 issue/PR；
- 不授权提交、push、创建 issue/PR 或评论。

### 1.3 允许的最终状态

只能从以下状态中选择一个，禁止自造 `DONE`：

```text
PASS-B-PR-READY-LOCAL
UPSTREAM-ALREADY-FIXED
UPSTREAM-ORACLE-DRIFT
B-PATCH-DRIFT
CI-MATRIX-DRIFT
R5-HARNESS-BLOCKED
R5-TECHNICAL-FAIL
R5-NON-COMPLIANT
```

技术测试全绿不能覆盖 `R5-NON-COMPLIANT`。任何 oracle/selftest/archive/input 失败均禁止 PR-ready。

---

## 二、授权边界

任务书本身不授予执行权限。GLM 启动前必须把用户授权原文逐字保存到 `$CTRL/authorization.txt`；授权未出现时只允许读取任务书、旧报告和固定资产，禁止 clone、下载、Docker、写临时目录或跑测试。

建议用户授权原文：

> 我授权执行 C03-R5 任务书 §二 B1—B4；仅限 WSL 本地临时目录、隔离 Redis 和匿名只读 GitHub，禁止 157/生产/社区写入及所有 sudo 操作。

| 编号 | 获授权后允许的状态变化 | 精确边界 |
|---|---|---|
| B1 | 本地任务目录 | 仅新建 `/home/lilingfeng/tmp/juicefs-c03-r5-*` 下的 input/OUT/cache/tools/build/VERIFY/TERMINAL；禁止覆盖或删除既有路径 |
| B2 | 匿名只读网络 | 官方 JuiceFS `git fetch/ls-remote`、匿名 GitHub GET、Go module/toolchain/lint 下载；不得携带 token/cookie/Authorization header |
| B3 | 隔离 Redis | 可 pull `redis:7.2-alpine`，仅 run/inspect/log/stop/remove 名称和 label 均含本轮 RUN_ID 的容器；禁止 prune、启停 Docker 服务或触碰未知容器 |
| B4 | 报告写入 | 仅新建 `report/C03-R5-execution-$RUN_ID.md`，禁止修改旧 task/report/archive/source |

明确未授权：SSH/157、Ceph/TiKV/生产 Redis、mount/fio、sudo、系统包安装、系统服务、重启、网络/内核、业务目录、删除旧现场、Git commit/push/fork/tag/branch、GitHub issue/PR 写操作。

---

## 三、目录、attempt 与控制器

### 3.1 动态路径

```text
RUN_ID=YYYYmmdd-HHMMSS
CTRL=/home/lilingfeng/tmp/juicefs-c03-r5-control-$RUN_ID
PREFLIGHT=/home/lilingfeng/tmp/juicefs-c03-r5-preflight-$RUN_ID
INPUT=/home/lilingfeng/tmp/juicefs-c03-r5-input-$RUN_ID-a<ATTEMPT>
OUT=/home/lilingfeng/tmp/juicefs-c03-r5-$RUN_ID-a<ATTEMPT>
ARCHIVE=/home/lilingfeng/tmp/juicefs-c03-r5-$RUN_ID-a<ATTEMPT>-artifacts.tar.gz
LAUNCH_LOG=/home/lilingfeng/tmp/juicefs-c03-r5-$RUN_ID-a<ATTEMPT>.launch.log
TERMINAL=/home/lilingfeng/tmp/juicefs-c03-r5-$RUN_ID-a<ATTEMPT>-terminal
VERIFY=/home/lilingfeng/tmp/juicefs-c03-r5-verify-$RUN_ID-a<ATTEMPT>
```

所有路径启动前必须 `test ! -e`。存在就换 RUN_ID/attempt，禁止 `rm -rf`、清空、覆盖或“复用继续”。工作根必须是 `/home/lilingfeng/tmp`，禁止使用根级 `/tmp`。

### 3.2 preflight 与 formal attempt

- oracle/producer 编写阶段最多三个 preflight implementation attempt；每次保存旧脚本 hash、diff、失败 case 和修复理由；
- 只有 37/37 selftest 与 R4 真实负例全部符合预期，才允许冻结正式 input；
- formal attempt 最多两个；每次必须使用全新 INPUT/OUT/ARCHIVE/TERMINAL/VERIFY；
- attempt 1 若因 runner/oracle/基础设施工程 bug 失败，可修复后从头完整执行 attempt 2；禁止给同一 OUT 补跑或补表；
- attempt 2 仍有 harness/audit 缺陷即 `R5-HARNESS-BLOCKED`；测试本身失败则 `R5-TECHNICAL-FAIL`；
- 所有失败现场永久保留，本任务不做清理。

### 3.3 controller-state.tsv

第一分钟创建 `$CTRL/controller-state.tsv`，精确 11 列：

```text
beijing_ts	phase	attempt	pid	status	input	out	action	evidence	next	comment
```

至少记录：授权、旧证据 hash、每个 preflight attempt、37-case 结果、input freeze、正式 launcher PID/rc、main freeze、四臂、每组测试、Redis cleanup、producer freeze、oracle、archive、final status、报告。单个步骤失败只转入允许分支，不能静默提前写 PASS。

---

## 四、R5 架构：producer 与 oracle 彻底分离

### 4.1 四组件

| 组件 | 职责 | 禁止 |
|---|---|---|
| `launch-c03-r5.sh` | 捕获 producer rc、记录 launch log hash、无论 rc 均调用 oracle/finalizer | 不解析 Go 日志，不自行把缺证据改 YES |
| `run-c03-r5.sh` | fetch/clone/test/build，保存原始证据，生成 producer gate 和冻结 archive | 不写最终 PASS，不调用 oracle 内部函数 |
| `oracle-r5.py` | Python 标准库、只读复算 raw evidence/TSV/hash/tar multiset/extract/source guards | 不 import/source/复制 producer helper，不修改 OUT/archive/input |
| `terminal-finalize-r5.py` | 仅根据 runner rc、oracle 24 门、12 integrity 和固定 key 集映射最终状态 | 不重新解释测试，不容忍缺 key/PENDING/重复 key |

oracle 与 producer 必须由不同文件、不同函数实现。oracle 禁止：

- `source run-c03-r5.sh`、解析 producer 函数输出代替复算；
- 读取 producer 的 gate=YES 后直接传播；
- 以 `set()` 比较 tar path 而丢掉 multiplicity；
- 通过 case 名称硬编码 ACCEPT/REJECT；
- 调用任何会修改 OUT、archive、VERIFY 或源 clone 的命令；
- 网络访问、Docker、Go、git fetch 或测试执行。

### 4.2 正式控制流

```text
launcher
  ├─ if producer; then RUNNER_RC=0; else RUNNER_RC=$?; fi
  ├─ 保存 runner.rc 与 launch-log.sha256
  ├─ 调用 oracle（即使 producer 非零也调用，缺项必须显式 NO）
  ├─ 调用 finalizer
  └─ 原子写唯一 final-status.txt
```

producer 只允许把 `candidate-gates.tsv` 写在 OUT 内；oracle 输出全部写 TERMINAL：

```text
oracle-candidate-gates.tsv
archive.integrity.tsv
oracle-findings.tsv
oracle-command.json
oracle.stdout
oracle.stderr
oracle.rc
final-status.txt
```

### 4.3 taskbook identity 硬门

正式 INPUT 的 `taskbook.md` 必须是本文件的逐字复制：

```text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/C03-R5-upstream-main-independent-oracle-clean-rerun.md
```

冻结前保存 source/copy SHA 与 `cmp` rc。oracle 必须检查：首行以 `# C03-R5` 开头、不含 C03-R3 标题、source/copy hash 相同、source 在正式 attempt 前后未变。任何失败令 `input_integrity=NO`。

---

## 五、正式执行前 37-case 反例矩阵

任何 Go 命令、fetch、clone、Docker 或下载之前，必须用**正式同一份** `oracle-r5.py` 与 `terminal-finalize-r5.py` 执行本节。测试专用的另一套 validator 无效。

### 5.1 输出 schema

`$PREFLIGHT/preflight-results.tsv` 精确九列：

```text
case	group	fixture	expected	actual	oracle_rc	final_status	evidence	matched
```

精确 37 个数据行；`expected/actual` 只能是 `ACCEPT/REJECT`，`matched` 只能是 YES/NO。必须 37/37 `matched=YES`、无重复 case、所有 evidence 存在且 hash 进入 `preflight-SHA256SUMS`。

### 5.2 Terminal/finalizer：8 case

| case | 变异 | 期望 |
|---|---|---|
| T01-valid | runner=0，producer/oracle 24 YES，12 integrity YES | ACCEPT + PASS |
| T02-runner17 | runner=17，其余全 YES | REJECT，`R5-TECHNICAL-FAIL` |
| T03-producer-gate-no | producer 一门 NO | REJECT |
| T04-oracle-gate-no | producer 全 YES、oracle 一门 NO | REJECT |
| T05-integrity-no | 12 项中一项 NO | REJECT |
| T06-missing-key | 少一个固定 key | REJECT |
| T07-duplicate-key | 重复一个 key | REJECT |
| T08-pending-unknown | 值为 PENDING 或出现未知 key | REJECT |

非 T01 绝不能生成包含 PASS 的 final status；T02 也必须映射到 §1.3 已列出的
`R5-TECHNICAL-FAIL`，禁止 producer、oracle 或 finalizer 自造状态。每个 case
单独目录，禁止前一 case sidecar 污染后一 case。

### 5.3 Result/raw-log：10 case

| case | 变异 | 期望 |
|---|---|---|
| R01-valid14 | 14 列、唯一行、raw log 精确匹配 | ACCEPT |
| R02-header13 | 删除 `expectation_matched` 表头列 | REJECT |
| R03-data13 | 任一数据行少 `bad` 或末列 | REJECT |
| R04-data15 | 任一数据行多一列 | REJECT |
| R05-invalid-enum | `bad=0`、空值或 matched 非 YES/NO | REJECT |
| R06-duplicate-row | arm/tool/mode/test 唯一键重复 | REJECT |
| R07-count99 | expected 100、raw/TSV 只有 99 PASS | REJECT |
| R08-no-tests | rc=0 但含 `warning: no tests to run` | REJECT |
| R09-raw-mismatch | TSV 写 100、raw log 实际 99 或有额外 FAIL | REJECT |
| R10-log-missing-hash | log 缺失、为空、越界路径或 hash 不匹配 | REJECT |

oracle 必须直接读取 raw log，用锚定模式 `^--- PASS: <test>( |$)`、`^--- FAIL: <test>( |$)` 和固定 marker 复算；不得相信 TSV 的 actual 值。

### 5.4 Redis：5 case

| case | 变异 | 期望 |
|---|---|---|
| D01-valid7 | 表头和每个数据行精确七列、步骤唯一完整 | ACCEPT |
| D02-r4-packed-real | 直接输入真实 R4 `meta/redis-lifecycle.tsv` | REJECT |
| D03-duplicate-step | 同 tool/step 重复 | REJECT |
| D04-missing-step | 少 run/PONG/inspect/log/vfs/stop/gone 任一步 | REJECT |
| D05-wrong-rc-content | rc 或 content/status 与 raw sidecar 不一致 | REJECT |

不得把冒号串再次 split 后“修复性接受”；物理 TSV 本身不是七列就必须拒绝。

### 5.5 Archive/freeze：9 case

| case | 变异 | 期望 |
|---|---|---|
| A01-valid | expected/manifest/tar/extract multiset 精确、无重名 | ACCEPT |
| A02-expected-duplicate | expected 同一路径两次 | REJECT |
| A03-r4-tar-real | 直接检查真实 R4 archive，其成员重名 | REJECT |
| A04-manifest-missing | manifest 少一个 expected 文件 | REJECT |
| A05-manifest-extra | manifest 多一个未预期文件 | REJECT |
| A06-tar-extra-or-missing | tar 多/少成员 | REJECT |
| A07-extract-extra-or-missing | extract 多/少普通文件 | REJECT |
| A08-missing-sidecars | 三个规定 diff 任一不存在，即使应为空 | REJECT |
| A09-post-freeze-mutation | manifest 后修改/新建 payload 文件 | REJECT |

oracle 对 expected、manifest、tar、extract 使用**排序列表 + Counter/multiset**；先分别检查 duplicate，再比较数量和内容。真实 R4 archive 必须因 `meta/archive-members.expected` 重复成员被拒绝。

### 5.6 Guard/input：5 case

| case | 变异 | 期望 |
|---|---|---|
| G01-valid | taskbook/input/source/protected/VERIFY 全满足 | ACCEPT |
| G02-preexisting-verify | VERIFY 启动前已存在 | REJECT，且原目录不被删除 |
| G03-untracked-source | clone 中生成未登记 SQLite/临时文件 | REJECT |
| G04-protected-change | SOURCE 或历史固定资产 before/after 改变 | REJECT |
| G05-wrong-taskbook | 使用真实 R4 的 C03-R3 `taskbook.md` | REJECT |

### 5.7 selftest 防作弊门

- 每个 invalid fixture 必须由一个 valid fixture 做单一变异，保存 mutation diff；R4-real 四例除外；
- oracle 源码不得包含针对 `T01/R02/D02/A03/G05` 等 case ID 的 verdict 分支；
- 交换 case 文件名后 verdict 不得变化；随机抽三例改名复跑并保存结果；
- preflight 使用的 oracle SHA 必须与正式 INPUT、executed、archive 中的 oracle SHA 相同；
- 37/37 之外，另写 `$PREFLIGHT/r4-known-bad-results.tsv`，精确八列：

  ```text
  case	asset	expected	actual	oracle_rc	evidence	finding	matched
  ```

  其中精确四个数据行：`KB01-result-schema`、`KB02-redis-schema`、`KB03-archive-duplicate`、`KB04-terminal-contradiction`。四项必须全部 `expected=REJECT`、`actual=REJECT`、`matched=YES`；KB04 要求把 R4 的 24/24、10/10、PASS 与前三项真实坏事实一起输入正式 oracle，证明总体仍被拒绝；
- 任一不满足不得启动正式 attempt，状态 `R5-HARNESS-BLOCKED`。

---

## 六、冻结 INPUT 与静态硬门

### 6.1 INPUT 精确普通文件集合

正式 input 只允许以下 27 个普通文件，不允许子目录、PID、stdout、cache 或临时文件：

```text
anchors.expected
async-catchup-main.patch
candidate-gates.expected
community-secret-patterns.txt
final-integrity.expected
forbidden-runtime-patterns.txt
input.expected-files
input.sha256
input.stat.tsv
launch-c03-r5.sh
oracle-contract.md
oracle-r5.py
pre-run-adaptations.md
preflight-bundle.tar.gz
preflight-results.tsv
preflight-SHA256SUMS
protected-paths.txt
r4-known-bad-results.tsv
redis-steps.expected
result-schema.tsv
run-c03-r5.sh
runner-static-review.md
taskbook.md
terminal-finalize-r5.py
terminal-selftest.log
writer_flush_c02_test.go
writer_flush_test.go
```

`preflight-bundle.tar.gz` 包含 37-case 的小型 fixture、每个 mutation diff、逐 case oracle stdout/stderr/rc 和 finalizer sidecar；不得包含真实 R4 archive，只记录其绝对路径、固定 SHA、只读复算命令与四项结果。`preflight-SHA256SUMS` 精确覆盖 bundle、`preflight-results.tsv`、`r4-known-bad-results.tsv`，从 PREFLIGHT 和正式 INPUT 两处校验均成功。

`input.expected-files` 必须是上述 27 个 basename 的 C-locale 排序列表。生成顺序：先完成 24 个业务/脚本/预飞文件并设为 0444，再生成并设为 0444 的 `input.expected-files`；随后生成 `input.stat.tsv`，它覆盖前述 25 个文件、排除自身和尚未生成的 `input.sha256`；最后生成 `input.sha256`，覆盖除自身外全部 26 文件。设两个 manifest 为 0444 后再把 INPUT 目录设为 0555。

所有文件最终 mode=0444，INPUT 目录 mode=0555；脚本通过解释器显式执行。冻结前后保存 owner/mode/size/mtime_ns/SHA；运行期不得修改。

### 6.2 result-schema.tsv

内容必须精确一行：

```text
arm	tool	mode	test	actual_rc	expected_pass	actual_pass	expected_fail	actual_fail	expected_marker	actual_marker	bad	log	expectation_matched
```

规则：

- 所有结果表精确 14 列；
- `actual_rc` 与六个计数字段为十进制非负整数；
- `bad`、`expectation_matched` 只能为 YES/NO；
- `log` 是 OUT 内相对普通文件路径，无绝对路径、`..`、tab/newline，存在且非空；
- 每行唯一键为 `(arm, tool, mode, test)`；
- oracle 根据 contract 重新计算 `expectation_matched`，不能接受 producer 自填值。

### 6.3 Redis schema

精确七列：

```text
tool	step	expected_rc	actual_rc	content_check	status	evidence
```

每工具链步骤必须精确、唯一且有 raw rc：

```text
image_ready
run
pong
inspect_running
logs
full_vfs
stop
inspect_gone
```

`inspect_gone` 若记录直接 `docker inspect`，expected/actual 都应为 1；若使用专门 absence helper，则另存原始 inspect rc=1，并在 TSV 中明确 helper expected/actual=0。两种只能预登记一种，禁止事后换口径。

### 6.4 静态 review 必须是命令证据

`runner-static-review.md` 至少包含命令、stdout/stderr、真实 rc 和结论：

1. 三个 Python/shell 文件语法解析成功；Python 用 `ast.parse`，禁止在 INPUT 生成 `__pycache__`；
2. launcher 用 `if ...; then RC=0; else RC=$?; fi` 捕获 producer 与 oracle rc；
3. producer 不含 `PASS-B-PR-READY-LOCAL`；
4. oracle 不 import/source producer，不包含 case-ID verdict；
5. producer 无 `rm -rf "$VERIFY"`，任何 preexisting VERIFY 直接失败；
6. archive expected 生成时输出到 OUT 外临时文件，完成 duplicate/self 检查后原子 rename；禁止在 `find` 扫描目录内提前创建目标文件；
7. 无 `xargs -0` 读取换行列表、无 `for f in $(...)` 处理路径、无 `sort -u` 掩盖重复；
8. freeze 后无写 OUT payload 的命令；final review 必须 freeze 前完成或写 TERMINAL；
9. 所有 candidate gate 初始 NOT_RUN、只解析一次、精确 24 个；
10. oracle 独立复算 exact row matrix、raw log、rc、hash、source/path、multiset；
11. 禁止 sudo、ssh、fio、mount、Ceph/TiKV 地址、Docker prune、killall/pkill、git 写远端；
12. 37-case preflight 精确通过，真实 R4 四类 contradiction 被拒绝；
13. taskbook identity 为 C03-R5；
14. INPUT、OUT、VERIFY 和旧现场均没有删除逻辑；
15. secret scan pattern 不把命令自身匹配当泄漏，也不泄露实际 secret。

文字写 YES 但没有命令/rc 一律视为 NO。

---

## 七、官方 main 冻结与四臂

### 7.1 稳定冻结

在全新无 hardlink clone 中，对官方 `refs/heads/main` 最多三次尝试；每次保存：

- `git ls-remote` before/after 原文、北京时间、rc；
- fetch rc、FETCH_HEAD、origin/main、selected HEAD；
- commit/date/title/parents；
- official remote URL 与无 credential 证明；
- C02 base、历史 main 是否为祖先；
- `pkg/vfs/writer.go` 相对历史 main 的 blob/hash/diff；
- go.mod、workflows、lint 和 Makefile policy。

同一 attempt 的 remote-before、fetched origin/main、remote-after 三者完全相同才冻结；冻结后禁止再次 fetch。若策略已变化，`CI-MATRIX-DRIFT`，不得私自选择顺眼版本。

### 7.2 stock 分支

| 观察 | 状态/动作 |
|---|---|
| U1/U3 指定 marker FAIL、U2 PASS | `UPSTREAM-AFFECTED`，继续 B/Q/R |
| U1/U2/U3 全 PASS 且源码存在等价 catch-up | `UPSTREAM-ALREADY-FIXED`，禁止应用 B，保存修复候选提交和 partial archive |
| mixed、marker/次数漂移、额外 panic/timeout | `UPSTREAM-ORACLE-DRIFT` |
| B 标准 apply 失败或 writer 语义改变 | `B-PATCH-DRIFT`，禁止手工 rebase/`--recount` |

### 7.3 四臂

| 臂 | 内容 | changed-path 白名单 |
|---|---|---|
| S-oracle | frozen main + 社区测试 | `pkg/vfs/writer_flush_test.go` |
| B-candidate | frozen main + writer patch + 社区测试 | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |
| Q-semantic | frozen main + writer patch + C02 测试 | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_c02_test.go` |
| R-replay | frozen main + 最终两文件 patch | `pkg/vfs/writer.go`、`pkg/vfs/writer_flush_test.go` |

全部 HEAD 必须等于同一 frozen commit；禁止 hardlink。每臂测试前后保存 `status --porcelain=v2`、tracked diff、untracked 路径及内容 SHA。任何测试新生 SQLite/临时文件必须使对应 source guard=NO，不能忽略或测试后删除再写 clean。

---

## 八、正式测试矩阵与 oracle 复算

### 8.1 社区三项

```text
TestFullBlockDispatchedWhenSliceIDBecomesReady
TestPartialBlockNotDispatchedWhenSliceIDBecomesReady
TestFlushErrorRecordedWhenSliceIDBecomesReady
```

### 8.2 C02 十项

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

### 8.3 精确行数

| 表 | 数据行 | 组成 |
|---|---:|---|
| stock | 46 | 双工具链 × 3 single = 6；双工具链 × U1/U3 × 10 个独立进程 = 40 |
| community | 18 | 双工具链 × 3 测试 × single/count100/race20 |
| semantic | 60 | 双工具链 × 10 测试 × single/count100/race20 |
| replay | 12 | 双工具链 × 3 测试 × single/count20 |

每个物理行只代表一个测试。组合命令完成后也必须逐测试写行。

### 8.4 预期

- stock U2 single：rc=0、PASS=1、FAIL=0、marker=0、bad=NO；
- stock U1/U3 single/repeat：rc=1、PASS=0、FAIL=1、指定 marker=1、bad=NO；
- B/Q/R：rc=0；single/count/race 的每测试 PASS 精确为 1/100/20（R replay count=20），FAIL/marker=0、bad=NO；
- bad pattern 至少包含 `[build failed]`、panic、fatal、timeout、DATA RACE、no tests；
- producer 每行计算一次，oracle从 raw log、rc sidecar、hash 独立再算一次；两者必须逐字段一致。

### 8.5 原始日志纪律

- 每次命令单独 log 和 `.rc`，先捕获 rc 再做解析；
- 禁止 `cmd || true; echo $?`、tee 管道吞 rc、后一命令覆盖 rc；
- raw log 不得改写、截断、过滤后替代全文；
- 每个 log 的 SHA 和 size 进入 `raw-evidence.tsv`；
- oracle 只读 raw log，不读取控制台摘要代替；
- report 中所有次数必须指向具体 TSV 行和 raw log。

---

## 九、社区质量、Redis、build 与只读查重

### 9.1 Redis/full pkg-vfs

- 确认宿主目标 loopback 端口未监听；端口动态选取并记录，不抢 6379 现有服务；
- 每工具链使用独立、名称/label 含 RUN_ID 的容器；
- image inspect/pull、run、PONG、inspect、logs、full vfs、stop、gone 均保存 raw rc；
- trap 只能按已记录 CID stop/remove 本轮容器；不得按名字模糊匹配；
- oracle 从七列 TSV、rc sidecar、inspect JSON、PONG/log 和 gone evidence 复算；
- Docker 不可用则相应 gate=NO 并报告，禁止复用未知 Redis。

### 9.2 格式/tidy/vet/lint/build

双工具链按 frozen main 官方 policy 执行：

- gofmt diff 为空、license 正确、`git diff --check` rc=0；
- `go mod tidy` rc=0 且 go.mod/go.sum hash 不变；
- `go vet ./pkg/vfs` rc=0；
- 官方口径 golangci-lint：query/install/version/run 各自 rc、version、binary/config SHA、源码 before/after；
- Linux/lite build：make rc、version rc、revision、size、mode、SHA、copy cmp；
- build/src/cache/tools 不进入小型 archive，只保留 provenance。

禁止安装系统包、修改 Makefile/go.mod/go.sum 迁就环境、降低 lint 范围或只保留最后命令 rc。

### 9.3 patch replay

- B 使用固定 writer patch标准 `git apply --check` 与 `git apply`，两个 rc 分开保存；
- 从 B 生成最终两文件 patch；若 writer base blob 未变，SHA 必须为历史 `1050e94f...`；
- R 在第五个干净 clone 标准 apply 最终 patch；
- R 完整 diff 与 B 的两文件 diff 逐字节相等；
- R 双工具链 single/count20 重新执行；禁止复制 B 日志。

### 9.4 匿名只读查重与草稿

- 六组 GitHub GET 和本地 history 查询，保存 URL、时间、HTTP/rc/rate-limit/body/parse；
- 不携带 token/cookie/auth header，不下“不重复”的最终结论；
- issue/PR/commit-message 草稿只写实际通过项目，明确官方 CI 与性能 NOT RUN；
- 禁止声称“修复 main 所有 randwrite 塌陷”或“已生产验证”；
- 对最终 patch、测试、草稿做 secret/internal-path scan，原始命中和真实 rc 分开记录；
- 不发送任何草稿。

---

## 十、24 个 producer/oracle candidate gate

producer 与 oracle 各自输出同样 24 个 gate，精确三列：

```text
gate	status	evidence
```

状态只能 YES/NO。必须精确 24 行、无缺失/重复/未知/PENDING。oracle 不得复制 producer status。

| gate | oracle 读取文件/字段与计算 |
|---|---|
| input_integrity | INPUT expected/stat/SHA/start/end/archived-copy、taskbook/source copy、三组件 executed/input/archive hash 全等 |
| upstream_freeze | `upstream-freeze-attempts.tsv` 中同 attempt 三 hash 相等，commit/ancestry/policy raw rc 满足 |
| upstream_policy_ci | frozen go.mod/workflow/lint/Makefile parser 输出与实际文件 hash、命令矩阵一致 |
| upstream_stock_oracle | `stock-results.tsv` 46 行 + raw log/rc/marker 全量复算 |
| B_standard_apply | apply-check/apply 两个独立 rc=0，writer diff 精确 |
| B_community_single | community 六个 single 唯一行与 raw log精确 |
| B_community_count100 | 六个 count100 行各 100 PASS |
| B_community_race20 | 六个 race20 行各 20 PASS 且无 race |
| Q_semantic_single | semantic 二十个 single 行精确 |
| Q_semantic_count100 | 二十个 count100 行各 100 PASS |
| Q_semantic_race20 | 二十个 race20 行各 20 PASS 且无 race |
| B_full_vfs | 双工具链 full-vfs raw rc=0、log 非空、无 bad pattern |
| redis_lifecycle | 每行七列、两工具链精确步骤、raw rc/content/CID/gone 全匹配 |
| B_gofmt_diff_license | gofmt/license/diffcheck/changed-path/source pre-post 全满足 |
| B_tidy | 双工具链 tidy rc=0、mod/sum pre-post SHA 相等 |
| B_vet | 双工具链 vet rc=0、日志 hash 在 manifest |
| B_lint | query/install/version/run rc、policy version、finding、source pre-post 全满足 |
| B_linux_build | 双工具链 make/version/revision/size/SHA/cmp provenance 全满足 |
| B_lite_build | 同上，lite 产物 |
| patch_replay | apply 两 rc、B/R diff cmp、replay 12 行 raw 复算 |
| community_search | 六组 HTTP/parse 与本地 history 证据完整；只表示搜索完成 |
| community_drafts_secret_scan | 三草稿存在、内容声明合规、secret scan raw rc/空命中正确 |
| source_asset_guards | SOURCE/历史 before-after、所有臂 untracked/changed-path/protected 对比无未登记变化 |
| execution_audit | commands/controller/anchors/adaptations/attempt/forbidden/taskbook/preflight 37-case 全闭合 |

producer gate 与 oracle gate 必须逐 gate 完全相等；不一致时即使 oracle 为 YES，也标 `producer_oracle_gate_agreement=NO`，最终不得 PASS。

---

## 十一、archive、multiset 与 12 项终态门

### 11.1 archive payload

只包含冻结的小型证据：

```text
assets/input/
artifacts/
community-search/
diffs/
drafts/
logs/
meta/
rc/
services/
commands.sh
controller-state.tsv
runtime-adaptations.tsv
summary.tsv
candidate-gates.tsv
deferred-checks.tsv
SHA256SUMS
```

禁止 src/cache/tools/builds、`.git`、Docker layer、module cache、二进制大文件、credential、旧 R4 archive。

### 11.2 无自引用且不提前创建 expected

严格顺序：

1. 完成全部 payload、`final-compliance-review.md`、producer 24 gate、`prearchive-status.txt`；关闭 xtrace；
2. 在 OUT **之外**生成 candidate expected 临时文件；不得先在 `OUT/meta/` 创建目标；
3. candidate 中预登记未来 `meta/archive-members.expected` 与 `SHA256SUMS`，但当前 `find` 不能看到它们；
4. 检查 candidate 已 C-locale 排序、每行合法相对普通路径、无空行、无重复；
5. 原子 rename 为 `OUT/meta/archive-members.expected`；从此唯一允许新建的 payload 是 `SHA256SUMS`；
6. 生成 `SHA256SUMS`，覆盖 expected 除自身的每个路径恰好一次；
7. 记录 payload freeze 的 path Counter、size/mode/mtime_ns/SHA；从此 OUT 只读，不再写 final review；
8. producer 从 OUT 根用 `tar -czf "$ARCHIVE" -T meta/archive-members.expected` 创建 archive；
9. producer 不输出最终 integrity，只退出；
10. launcher 调用 oracle，所有 manifest/tar/extract/diff/final日志只写 TERMINAL。

### 11.3 oracle 必须始终生成的外部 sidecar

无论 PASS/FAIL、差集是否为空，都生成：

```text
expected.paths
expected.duplicates
manifest.paths
manifest.duplicates
tar.regular.paths
tar.duplicates
extract.regular.paths
extract.duplicates
archive-vs-expected.diff
extract-vs-expected.diff
manifest-vs-expected.diff
payload-freeze-vs-final.diff
```

`VERIFY` 必须在正式 attempt 前不存在，由 oracle 用排他创建；存在则拒绝，绝不删除。解包后永久保留。

### 11.4 12 项 final integrity

`$TERMINAL/archive.integrity.tsv` 无 header，固定顺序、精确 12 行：

```text
archive_sha256_match
tar_readable
archive_multiset_exact
manifest_coverage_exact
manifest_check_before_archive
manifest_check_after_extract
payload_freeze_unchanged
forbidden_large_members_absent
required_evidence_present
runner_exit_rc_zero
launch_log_sha_recorded
independent_oracle_selftest_and_formal_pass
```

值只能 YES/NO，无重复/未知/PENDING。最后一项要求：37-case 全匹配、真实 R4 四类拒绝、正式 oracle rc=0、oracle 24 gate 全 YES、producer/oracle gate 全等。

### 11.5 唯一 PASS 公式

```text
runner.rc == 0
AND producer candidate gates == exact 24 YES
AND oracle candidate gates == exact 24 YES
AND producer gates byte/semantic agree with oracle gates
AND final integrity == exact 12 YES
AND finalizer selftest passed
=> PASS-B-PR-READY-LOCAL
```

缺任一文件、解析异常或 oracle 自身异常必须 fail closed，禁止 fallback 为历史 PASS。

---

## 十二、顺序执行步骤

1. **步骤 0：通读规范**。完整阅读 `SYSTEM-SAFETY-SKILL.md`、`LONG-RUNNING-TEST-SKILL.md`、`TESTING-GUIDE.md`、`test-commands-reference.md`、`TASK-BOOK-AUTHORING-GUIDE.md` 和本任务书；记录本任务无 fio/生产操作，性能章节均为 N/A，安全/记录/授权仍适用。
2. 保存授权原文与 hash；没有授权只做只读盘点并停止。
3. 创建全新 CTRL/PREFLIGHT；记录本机、时间、磁盘/内存、Go/git/Python/Docker 版本与 SOURCE 状态。
4. 只读校验三项固定业务资产、R4 known-bad 资产、旧 task/report/archive hash。
5. 写全新 launcher/producer/oracle/finalizer；禁止 sed 修改 R4 脚本后直接正式运行。
6. 执行静态硬门与 37-case selftest；每个失败 preflight 保存并修复，最多三个实现 attempt。
7. 37/37 与 R4 real-known-bad 4/4 全匹配后，复制本 C03-R5 taskbook和固定业务资产，生成正式 INPUT 27 文件并冻结只读。
8. 确认 formal 所有动态路径不存在；通过唯一 launcher 前台启动 attempt 1，保存准确 PID/start time。
9. producer 完成 INPUT/SOURCE/history start guard、官方 main 三点稳定冻结和 policy 解析。
10. 创建全新 S/B/Q/R 四臂，记录 HEAD、remote、文件系统 inode（证明无 hardlink）和 before guard。
11. 运行 stock 46 行矩阵；按 §7.2 分支，drift/already-fixed 也必须做 partial archive/oracle/final status。
12. affected 时执行 B 标准 apply、community 18 行；执行 Q semantic 60 行。
13. 两工具链各自完成隔离 Redis 生命周期和完整 `pkg/vfs`，无论测试结果都精确清理本轮容器并保存 gone proof。
14. 完成 gofmt/license/diff/tidy/vet、官方 lint、Linux/lite build。
15. 生成最终两文件 patch，在全新 R clone 标准 replay，执行 replay 12 行矩阵。
16. 完成匿名只读社区/本地 history 搜索、三份草稿与脱敏。
17. 执行四臂/source/history/input end guard；任何未跟踪文件如实使 gate=NO，禁止删除后伪装 clean。
18. 完成 commands、controller、runtime adaptations、anchors、forbidden、final review；producer 一次性解析 24 gate。
19. 严格按 §11 冻结 payload、expected、manifest、archive；producer 退出，不写 PASS。
20. launcher 记录 runner/log sidecar并调用独立 oracle；oracle 创建/保留 VERIFY，复算 24+12。
21. finalizer fail-closed 写唯一 final status；launcher 返回与 final status 一致的非零/零 rc。
22. 若 attempt 1 为 harness bug，完整保留后允许全新 attempt 2；否则不挑选重跑。
23. GLM 从现存证据写新报告，不修改任何证据来迎合报告。
24. **末步：skill 合规复核**。逐条记录未使用 sudo/SSH/fio/mount/Ceph/TiKV、只管理本轮容器、无社区写入、无旧现场删除；N/A 项也明确写 N/A 理由。

长命令监控：每 10～15 分钟检查精确 PID、日志尾、目录增长和 Redis CID；进程消失不等于完成。不得因为某个 gate 失败就遗失原始证据或跳过 oracle/finalizer。

---

## 十三、交付物

### 13.1 必须保留

```text
$CTRL/
$PREFLIGHT/
$INPUT/
$OUT/
$ARCHIVE
$LAUNCH_LOG
$TERMINAL/
$VERIFY/
```

TERMINAL 至少包含：

```text
runner.rc
finalizer.rc
launch-log.sha256
oracle.rc
oracle.stdout
oracle.stderr
oracle-command.json
oracle-candidate-gates.tsv
oracle-findings.tsv
archive.integrity.tsv
archive.sha256
expected.paths
expected.duplicates
manifest.paths
manifest.duplicates
tar.regular.paths
tar.duplicates
extract.regular.paths
extract.duplicates
archive-vs-expected.diff
extract-vs-expected.diff
manifest-vs-expected.diff
payload-freeze-vs-final.diff
final-status.txt
```

### 13.2 报告

写入：

```text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R5-execution-$RUN_ID.md
```

报告必须包括：

1. 授权、起止时间、attempt、全部绝对路径和 SHA；
2. R4 独立复核表，明确四种 real-known-bad 被 oracle 拒绝；
3. 37-case 全表，而非只写 37/37；
4. input 27 文件、taskbook identity、四组件 executed/input/archive 三方 hash；
5. frozen main 三点 commit/date/title/ancestry/policy；
6. stock 46、B 18、Q 60、R 12 的 producer/oracle 双重摘要；
7. 每测试 count/race 精确次数和 raw path；
8. Redis 七列逐行、CID 和 gone proof；
9. gofmt/tidy/vet/lint/build/replay；
10. source/untracked/protected/history guard；
11. producer 24 gate、oracle 24 gate及差异；
12. expected/manifest/tar/extract 的总数、duplicate 数、三个 diff sidecar；
13. 12 项 integrity、runner/oracle/finalizer rc 和唯一 final status；
14. adaptations、失败现场、未执行项及原因；
15. 明确未执行性能、生产、官方 CI 和社区写入。

禁止只写“全绿”、隐藏 attempt 1、用报告文字补证据或在报告中自行授权下一阶段。

---

## 十四、判定与后续

### 14.1 PASS

只有 §11.5 公式满足时，报告可写：

> 在本轮冻结的官方 main commit 上，stock 确定性证明完整 block 在异步 slice ID 就绪后未补派发；B 保留异步分配并纠正该行为。producer 与独立 oracle 对原始日志、精确测试矩阵、双工具链质量门、source guards 和 archive multiset 得到一致全绿结果；oracle 同时拒绝了真实 R4 坏包及全部预登记反例。候选可交 Codex 做最终代码和重复性审核。官方 GitHub CI、生产性能和 v1.3 远端验证尚未运行。

PASS 后停止同类本地重跑。下一步不是 GLM 自行提交，而是 Codex 审核最终 patch/test/drafts，由用户明确授权社区动作。

### 14.2 UPSTREAM-ALREADY-FIXED

若 stock 转绿且存在等价官方修复：保存候选 commit、diff、测试和 oracle-validated partial archive；禁止应用 B。下一步由 Codex 分析官方补丁能否 backport v1.3。

### 14.3 FAIL/NON-COMPLIANT

- 技术测试失败：`R5-TECHNICAL-FAIL`；
- main/patch/policy 漂移：对应 drift；
- oracle/runner 第二次仍有工程缺陷：`R5-HARNESS-BLOCKED`；
- 复用旧 PASS、错列仍 YES、tar 重名仍 YES、修改旧证据、越权或报告补证据：`R5-NON-COMPLIANT`。

任何失败都保留现场，不自动转性能测试，也不反向否定已有“B 修正目标内部行为”的历史功能旁证。

---

## 十五、通用注意事项与 skill 合规

1. **数据口径**：本任务无 fio/BW/REPEAT 性能统计；稳态中位、per-job log、randrw R/W 均 `N/A`。Go 测试只按 raw log 的逐测试锚定 PASS/FAIL 计数。
2. **drop_caches**：无冷态性能测试，`N/A`；禁止为本任务 drop 任何主机缓存。
3. **fresh volume**：无 volume/layout/create-on-open，`N/A`；禁止 format/destroy。
4. **compaction cooldown**：无 Ceph 写入，`N/A`；禁止 compact、OSD restart 或 Ceph 操作。
5. **环境前置**：仅记录 WSL 本机版本/资源、Docker 和匿名网络；不得把生产 health 当本任务门，也不得连接生产取数。
6. **记录规范**：OUT 必须有 `commands.sh`，记录全部真实命令、cwd、env 白名单、rc 和时间；不得记录 secret。
7. **清理纪律**：不做卷清理，不删除旧目录；唯一 cleanup 是按精确 CID stop/remove 本轮隔离 Redis。
8. **前后 skill 自查**：步骤 0 与末步强制完成；性能条目明确 N/A，安全、授权、记录、长跑监控不能省略。
9. **分层授权**：只允许 §二 B1—B4；工程性 parser/path/脚本修复可自主进行并记录，测试语义、预期、矩阵、gate、工具链和上游 patch 不得擅改。
10. **挂载档位**：无 mount，`N/A`；禁止为了“补性能证据”临时连接 157。
11. **判据来源**：每个报告数字必须给相对/绝对文件、字段、计算；24/12 门均按 §10/§11 指定源文件复算。
12. **环境快照**：生产 `env-snapshot.sh` 不适用；以 CTRL 的 WSL local pre/post、SOURCE before/after、Docker before/after 代替，理由写入报告。

---

## 十六、红线汇总

1. 禁止修改 C01～C03-R4、V01-R1 的 task/report/input/OUT/archive/sidecar。
2. 禁止从 R3/R4 复制 PASS、log、rc、src、cache、tools、build 作为 R5 结果。
3. 禁止运行 R4 producer 后只改 `$OUT.meta` 再宣称修复；R5 必须有独立 oracle。
4. 禁止 13 列结果、缺 `bad`、冒号 Redis、模糊 grep 或仅凭 rc 写 YES。
5. 禁止用集合去重掩盖 expected/manifest/tar/extract 的重复路径。
6. 禁止 expected 在被扫描目录中提前创建；禁止 self-entry 被加入两次。
7. 禁止删除/覆盖 VERIFY、失败 OUT、旧现场或 preflight 失败证据。
8. 禁止 manifest/payload freeze 后修改 OUT，包括 final compliance review。
9. 禁止 oracle import/source producer、复制 gate、按 case ID 硬编码结果。
10. 禁止 input 放错任务书；必须冻结本 C03-R5 原文。
11. 禁止同一 OUT 补跑、补 rc、补 TSV、补 manifest 或手工写 PASS。
12. 禁止超过两个 formal attempt；第二次仍 harness fail 就停止。
13. 禁止手工 rebase、`git apply --recount`、三方 apply或修改测试断言。
14. 禁止忽略测试生成的 untracked SQLite/临时文件；发现即 guard NO。
15. 禁止 sudo、SSH、fio、mount、Ceph/TiKV/生产 Redis、系统包/服务/重启/网络操作。
16. 禁止 Docker prune、广泛 kill、按模糊名字删除容器；只管理精确 CID。
17. 禁止 commit/push/fork/tag/branch 和任何 issue/PR/community 写 API。
18. 禁止草稿声称宏观 randwrite 性能已修复、生产已验证或官方 CI 已通过。
19. 禁止把 `UPSTREAM-ALREADY-FIXED` 当 B PASS；应转官方补丁 backport 分析。
20. 任一安全、授权或证据边界不确定时 fail closed，保留现场并报告。

---

## 附录 A：GLM 最终回复模板

```text
RUN_ID / attempt：
总状态（八选一）：
授权文件/SHA：
CTRL/PREFLIGHT/INPUT/OUT/ARCHIVE/TERMINAL/VERIFY：

R4 real-known-bad：result / Redis / archive / terminal contradiction 是否均 REJECT：
37-case：<matched>/37，preflight hash：
taskbook identity / 四组件三方 hash：

frozen main commit/date/title：
stock 46：
B 18 / Q 60 / R 12：
双工具链 full-vfs / Redis / lint / build：

producer gates：<YES>/24
oracle gates：<YES>/24
producer-oracle diff：
archive expected/manifest/tar/extract count + duplicates：
12 integrity：<YES>/12
runner/oracle/finalizer rc：
唯一 final-status：

所有 adaptations / failed attempts：
未执行项：性能、157、生产、官方 CI、社区写入
声明：未修改旧证据，未使用 sudo/SSH/fio/mount，未删除 VERIFY/失败现场，等待 Codex 审核。
```
