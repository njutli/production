# JuiceFS flush race 社区交流材料

> 整理日期：2026-08-18  
> 性质：本地审阅与社区提交准备入口；不是已获授权发布的附件包  
> 当前状态：`U01 技术通过 / U01 archive 部分不合规 / 社区写入未授权 / GitHub CI 未运行`

## 1. 当前裁定

U01 在执行时从官方 JuiceFS main 冻结了
`53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`。stock 上，完整 block 在异步 slice ID
就绪前写完后不会补派发；B 候选在 `SetID` 后按条件补做 `FlushTo`，能够纠正该
目标行为。

可以承接：

- frozen main 上 stock 的 U1/U3 目标失败和 U2 通过；
- B 仅修改 `pkg/vfs/writer.go` 7 行，并新增三项确定性社区回归测试；
- B/Q 的定向、count/race、完整 `pkg/vfs`、gofmt、diff-check、vet、Linux build；
- 候选在全新 replay tree 上标准 apply，且 replay 文件与 B 逐字节一致。

不能承接：

- U01 tar 是完整审计包或候选已经 `PR-ready`；
- GitHub Actions 已通过或社区维护者已经接受补丁；
- B 已恢复 v1.3 真实 Ceph randwrite 性能；
- 本目录可以不经筛选整体上传。

U01 的缺口位于命令/控制记录和 archive 打包层，不是现有原始日志显示了补丁失败。
详细裁定见 `reports/U01-execution-20260818-130955.md`。

## 2. 你需要审阅和提交的文件

| 文件 | 用途 | 社区处理 |
|---|---|---|
| `candidate/community-candidate.patch` | 规范 full-index 两文件 patch | 提交候选；实际 PR 中形成同等 git diff |
| `tests/writer_flush_test.go` | 三项确定性回归测试 | 已包含在候选 patch 中，审阅即可 |
| `drafts/commit-message.md` | commit message | 创建本地提交时使用 |
| `drafts/pr.md` | PR 标题和正文 | 直接 PR 时更新动态字段后使用 |
| `drafts/issue.md` | issue 标题和正文 | 选择先报 issue 时使用；不是 PR 的强制前置 |
| `SUBMISSION-CHECKLIST.md` | 提交前动态检查与允许口径 | 提交前逐项确认 |

以下文件默认不随 PR 提交：

- `tests/writer_flush_c02_test.go`：十项内部语义/故障/并发测试，作为本地深度旁证；
- `evidence/`、`reports/`：本地复核材料，只在维护者要求时挑选最小原文；
- `v131-reference/`：v1.3 自研/性能线输入，不属于 main PR；
- `historical-context/`：项目内部历史，不作为社区附件。

## 3. 权威候选与测试

| 文件 | SHA256 | 状态 |
|---|---|---|
| `candidate/community-candidate.patch` | `1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9` | 当前规范候选 |
| `candidate/async-catchup-main.patch` | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` | writer-only 输入/审阅辅助 |
| `tests/writer_flush_test.go` | `bce85ad4abf92a47074849a544aaa756963fb44a1839619bbc71c5d7ce1fe9bc` | 随 PR 的三项测试 |
| `tests/writer_flush_c02_test.go` | `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` | internal-only |

U01 重新生成的 patch SHA 为 `c5b18845...`；它与规范候选只有两个 `index` 行的
object ID 缩写长度不同（7 位与 40 位），所有 hunk、7 行 production 修改和 243 行
测试正文相同。为避免社区交流中出现两个等价 SHA，本目录只把 full-index
`1050e94f...` 作为权威候选；U01 原始版本保留在其 evidence 目录。

### 3.1 为什么候选看起来有 250 行

`git apply --numstat` 的真实拆分是：

```text
7    0    pkg/vfs/writer.go
243  0    pkg/vfs/writer_flush_test.go
```

也就是说，B 的 production 修复本身只有 7 行；其 writer-only patch 只有 545 bytes。
其余 243 行是新的 `_test.go`，不会进入 JuiceFS 生产二进制。测试文件中约 30 行是
license/package/import，103 行是实现 `chunk.Writer`、`ChunkStore` 和延迟
`NewSlice` 的可控 fake，61 行是构造真实 `writeChunk` 时序的 harness，真正三项
断言约 49 行。

上游现有测试没有一个可直接记录 `SetID/FlushTo`、注入 `FlushTo` 错误并阻塞
`NewSlice` 的 writer helper。把测试放在新文件中可避免修改无关测试；若改成直接
手工调用 `prepareID` 虽能少写一些 harness，却不再覆盖触发问题的真实 write 路径。

## 4. 证据边界

| 证据组 | frozen base | 可承接内容 | 主要限制 |
|---|---|---|---|
| C01-R1 | `edabf9c2...` | stock 最小机制复现；A/B 覆盖目标行为 | 旧 base、审计不完整 |
| C02 | `edabf9c2...` | B 十项语义、故障、count/race | 旧执行审计不完整 |
| C03-R2 | `53835e24...` | stock/B/Q、完整 vfs、lint/build 原始技术旁证 | 自定义 gate/archive 不支持 PR-ready |
| U01 | `53835e24...` | latest-main stock/B/Q/full/replay 最小洁净技术结论 | archive/命令时序部分不合规 |
| V01-R1 | v1.3.1 `e0032b2a...` | v1.3 B 本地正确性/build 旁证 | 真实 S/A/B 性能未运行 |

U01 的逐字节原始文件收在
`evidence/raw/U01-20260818-130955/`。其中 `raw-evidence.tsv` 仍可校验其登记的
log/rc/meta/patch；`CURATION-NOTES.md` 说明了复制范围和不能继承的 archive 声明。

## 5. 目录

```text
candidate/                 main 最终候选与 writer-only 辅助 patch
tests/                     社区三项测试和 internal-only C02 十项测试
drafts/                    已按 U01 更新的 issue/PR/commit 草稿
reports/                   含 Codex 复核的关键报告
evidence/raw/              原始或精选原始 log/rc/meta
evidence/archives/         历史执行 archive；不是默认社区附件
search/                    历史查重原文；提交时必须重查
v131-reference/            V02 固定输入，不属于 main PR
historical-context/        内部历史背景
SUBMISSION-CHECKLIST.md    提交前人工清单
SOURCE-MANIFEST.tsv        关键材料来源、SHA 和边界
```

## 6. 提交前仍需动态完成

1. 再次读取 official main。若 HEAD 不再是 `53835e24...`，在新 HEAD 上重做最小
   stock/apply/三项测试后再生成 patch。
2. 重新做匿名 issue/PR/commit 查重；当前 `search/` 只代表 2026-08-17。
3. 人工确认 writer 7 行修改、测试 helper/命名、Apache-2.0 header 和 PR 措辞。
4. 选择直接 PR 或先 issue；两者都需要用户明确授权社区写入。
5. PR 创建后以 GitHub 官方 CI 和维护者 review 作为外部独立验证。

## 7. 与 V02 性能线的关系

V02 回答 v1.3.1 真实 Ceph 下 S/A/B 性能、正确性和环境稳定性。它能帮助内部生产决策，
但不是 main 修复 PR 的必要前置，也不能替代 main 的确定性回归测试。两条线可并行。

## 8. 测试方案说明

### 8.1 测试方式：Go 单元测试（非 fio/挂载测试）

本项目的三项社区测试和十项 C02 语义测试都是**纯 Go 单元测试**，在 WSL
本地通过 `go test` 运行，不涉及 FUSE 挂载、fio、Ceph 或 TiKV。测试验证的是
`writer.go` 的**代码路径逻辑**（FlushTo 有没有被调），而非端到端吞吐。

### 8.2 为什么单元测试能覆盖这个 bug

Bug 的根因是 `writeChunk`（第 257 行，持 `f.Lock()`）启动了 `go s.prepareID()`
goroutine，而 `prepareID`（第 68 行）也要 `f.Lock()`——被锁阻塞，必然在
`writeChunk` 返回后才执行。因此 `write` 检查 `s.id > 0` 时 `s.id` 必然为 0，
FlushTo 被跳过。这是**锁顺序决定的确定性时序**，不是随机竞态。

测试用三个 mock 替换依赖，但 `writeChunk`/`write`/`prepareID` 走的都是
production 代码的真实路径——同一把锁、同一个 goroutine 启动、同一个条件判断：

| 生产依赖 | Mock 实现 | 作用 |
|---------|----------|------|
| TiKV 元数据 (`meta.Meta`) | `delayedSliceMeta` | `NewSlice` 阻塞等放行，精确控制 ID 就绪时序 |
| Ceph RADOS (`chunk.Writer`) | `recordingChunkWriter` | `WriteAt` 直接返回成功；`FlushTo` 往 channel 写值，测试据此判断派发是否发生 |
| chunk store (`chunk.ChunkStore`) | `singleWriterStore` | 总是返回同一个 `recordingChunkWriter` |

Go 的 interface 机制让 mock 无缝接入：测试代码构造 `&dataWriter{m: mockMeta,
store: mockStore}` 传入，`writeChunk` 内部调 `f.w.m.NewSlice()` 和
`s.writer.FlushTo()` 时自然走到 mock 实现，production 代码一行不改。

### 8.3 测试执行方式

在源码 clone 目录下执行 `go test`，通过 `-run` 正则指定测试函数：

```bash
# stock 判别：10 个独立进程，每个预期 FAIL + marker
go test -count=1 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/

# B 验证：count=100（跑 100 次）
go test -count=100 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/

# B race 检测
go test -race -count=20 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
```

参数说明：
- `-count=N`：每个测试函数跑 N 次（禁用缓存）
- `-run`：正则过滤只运行匹配的测试函数
- `-race`：启用 Go 的数据竞争检测器
- `./pkg/vfs/`：要测试的包路径

任务书要求 U1/U3 各跑 10 个**独立进程**（不能用 `-count=10` 代替，因为那是
一个进程内跑 10 次），所以要分 10 次执行命令。完整 `pkg/vfs` 测试需要 Redis
（上游测试用它做元数据引擎），所以开了一个隔离 Docker Redis 容器。

### 8.4 单元测试与 fio 测试的关系

单元测试测**根因**（代码路径是否走对），fio 测**症状**（吞吐是否恢复）。
两者互补，不能互相替代：

- 单元测试证明 `FlushTo` 有没有被调——确定性 100% 复现，0.1 秒跑完
- fio 测试证明修复在生产中带来性能恢复——需要真实 Ceph/挂载，180 秒一轮

V02 任务书设计了完整的 S/A/B fio 性能矩阵来回答后者，但因 pool objects
超过安全门（7.46M > 3.11M）而阻塞。

### 8.5 为什么不通过实际集群 fio 测试来复现验证

理论上可以用 fio 在真实 Ceph + JuiceFS 挂载上复现 bug（stock 吞吐 ~551 MiB/s
vs B 修复后 ~3000 MiB/s），但这条路作为**社区提交证据**存在以下问题：

1. **不是确定性复现**：竞态在生产中 99.2% 触发，不是 100%。fio 每轮结果受
   OSD compaction、缓冲暂态、网络波动、pool 对象数等环境因素影响，可能某轮
   stock 也不塌，需要多轮统计才能归因，而社区 reviewer 难以从一批 fio 数据中
   独立判定根因。

2. **环境不可复制**：fio 测试依赖特定 Ceph 集群状态、TiKV、挂载参数和 pool
   对象数。社区 reviewer 无法在自己的环境中复现完全相同的条件。而 Go 单元测试
   只需 `go test` 和一个隔离 Redis，任何人 clone 代码后都能跑出相同结果。

3. **测的是症状不是根因**：fio 只能观察吞吐数字，无法直接证明"FlushTo 没有被
   调用"。单元测试直接检查 mock 的 channel 里有没有值——如果断言失败，错误信息
   精确指出"full block was not dispatched after slice ID became ready"，reviewer
   一眼看到根因。

4. **成本和时间**：一轮 fio 需要 180 秒 + health 检查 + drop_caches + gc/compact
   cooldown，完整 S/A/B 矩阵需要 9 个挂载 × 6 轮 = 54 轮，约 8~12 小时；而单元测试
   single + count=100 + race=20 总共不到 1 分钟。

5. **main 上补丁对性能无效**：历史调查（DeepSeek 二分 + 模式 B 判决实验）证明，
   同一竞态代码在 main 上是旁观者——main 的塌态由上传队列排水驱动，不是竞态驱动。
   补丁对 main 性能无影响，因此 fio 在 main 上无法展示 stock vs patched 的差异。

因此社区提交的确定性证据用 Go 单元测试，fio 性能验证作为独立的 v1.3 生产验证线
（V02）单独执行。两条线相互独立：单元测试证明代码逻辑正确，fio 证明修复在 v1.3
生产环境恢复吞吐。

## 9. 使用规则

1. 不原地改写 `candidate/`、`tests/` 或 raw evidence；新版本使用新文件和新 SHA。
2. 不把整个 `community-materials` 或历史 archive 上传社区。
3. 对外每条测试声明都指向 frozen commit、实际命令、raw log/rc 和已复核报告。
4. 不公开授权原文、凭据、META、完整内部路径、主机信息或生产环境数据。
5. 不把本地 technical pass 写成 GitHub CI、维护者接受、性能恢复或生产上线完成。
