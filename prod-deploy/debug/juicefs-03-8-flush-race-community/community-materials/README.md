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

## 8. 使用规则

1. 不原地改写 `candidate/`、`tests/` 或 raw evidence；新版本使用新文件和新 SHA。
2. 不把整个 `community-materials` 或历史 archive 上传社区。
3. 对外每条测试声明都指向 frozen commit、实际命令、raw log/rc 和已复核报告。
4. 不公开授权原文、凭据、META、完整内部路径、主机信息或生产环境数据。
5. 不把本地 technical pass 写成 GitHub CI、维护者接受、性能恢复或生产上线完成。
