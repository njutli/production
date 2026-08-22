# JuiceFS 纯随机写"登记竞态"缺陷——内部证据与验证资料包

> 原始资料包：DeepSeek　｜　日期：2026-08-16（v4）　｜　缺陷编号：INTERNAL-2026-08-13-001
>
> **状态订正（2026-08-18）**：原 v4 的“只做内部存档、main 上无社区修复价值”是历史口径，已被 C01～C03 后续确定性源码级证据修订，不能再作为当前裁定。
>
> `docs/SUMMARY.md` 和下文原始速查表保留为历史性能/机制材料；当前阶段裁定以各 execution report 中的“Codex 后续复核与阶段裁定”和本 README 的收口规则为准。
>
> 当前一句话结论：最后完成验证的 frozen main 仍存在目标漏派发行为，B 能纠正该行为；C03 已以 `CLOSED-BLOCKED` 结束，下一步改走 latest-main 最小洁净回放；真实 v1.3 Ceph randwrite 性能仍待安全门满足后的新一轮 S/A/B 验证。

## 2026-08-18 当前阶段总览与收口规则

### C03 的目的

C03 只有一个总目标：把已经确认的 flush race 修复整理成可以由 JuiceFS
社区长期维护的 main patch、回归测试和可信的本地验证材料。

各阶段回答的问题不同：

| 阶段 | 回答的问题 | 当前结论 |
|---|---|---|
| C01 | main 上是否存在异步 slice ID 就绪后漏派发完整 block 的行为 | 已确认 |
| C02 | B 是否满足完整/部分 block、错误传播、冻结、重试与并发语义 | 已确认 |
| C03 | patch/test 是否能在执行时 main 上洁净回放，并形成社区提交材料 | 技术结论已收敛；R5 harness 阻塞，阶段已 `CLOSED-BLOCKED` |
| V01 | B 移植到 v1.3 后是否恢复真实 Ceph randwrite，且不劣于 A | 本地 correctness/build 有旁证；远端性能未运行 |

C03 不负责证明 v1.3 的真实 Ceph randwrite 性能恢复；main 社区证据线与
v1.3 生产性能线相互独立。

### 为什么出现多份 C03 任务书

C03、R1、R2、R3、R4 并没有反复推翻补丁结论。各轮原始日志持续支持：

- stock main 的 U1/U3 失败、U2 通过；
- B 修正目标行为；
- C02 语义、count/race、完整 `pkg/vfs`、lint/build 等技术检查通过；
- production patch 内容和 hash 保持稳定。

反复重跑的主要原因是证据 producer/runner 多次把不合规结果自报为
`PASS-B-PR-READY-LOCAL`：先后出现结果列错位、Redis 冒号打包、input
边界不闭合、tar 重名、payload freeze 后修改和 finalizer 自证等问题。

因此：

- **技术/科学结论已经基本收敛**；
- **执行证据链此前没有收敛**；
- R5 的 37-case 主要验证 oracle 会不会接受坏证据，不是重新研究 bug 原理。

对应正式复核见：

- `report/C03-R2-execution-20260817-183244.md`：`TECHNICAL PASS-B / PR-READINESS BLOCKED / AUDIT NON-COMPLIANT`；
- `report/C03-R3-execution-20260817-200133.md`：同上；
- `report/V01-R1-execution-20260818-001227.md`：`PARTIAL-OFFLINE-EVIDENCE`，并否决 R4 的 PR-ready 自报终态。

### C03-R5 最终状态

记录时点：2026-08-18 复核 attempt-3 后。

- attempt-3 没有完成 fixture builder、preflight runner、static review、launcher
  或 formal producer；正式 37-case preflight 未启动，PREFLIGHT 目录为空；
- 改名复跑、bundle、27 文件 INPUT 和 formal attempt 均未形成；
- 已写 registry/oracle/finalizer 仍存在物理列宽、finding 登记、未计算 gate 默认
  `YES`、archive 未读 tar、非法 `RUNNER-FAILED-rc=*` 终态等静态合同缺陷；
- attempt-3 没有测试 patch，因此这不是 B 的新技术失败，也不能产生新的 PASS；
- Codex 最终裁定：`R5-HARNESS-BLOCKED / FORMAL_ALLOWED=NO /
  PR-READINESS=BLOCKED / C03=CLOSED-BLOCKED`。

详细证据见
`report/C03-R5-attempt3-execution-20260818-104714.md` 的“Codex 后续复核与
阶段裁定”。C03 不再追加 attempt-4、R6 或 R7。

### C03 硬终止规则

C03-R5 是最后一份 C03 本地审计任务书。不得因为 harness 问题自然扩展出
C03-R6、R7。

1. 只允许再做一次 preflight implementation attempt。
2. attempt 3 达到 37/37 且 R4 real-known-bad 4/4 后，最多执行两个 formal attempt。
3. R5 通过：C03 结束，进入社区提交决策。
4. 执行时最新 main 已包含等价修复：C03 结束，转官方修复 commit 与 v1.3 backport 分析。
5. attempt 3 仍为 harness 缺陷：记录 `R5-HARNESS-BLOCKED`，C03 同样结束，不再编写 R6。
6. B 在执行时 main 出现实质技术失败或源码漂移：如实记录技术状态并结束 C03，由 Codex 决定修补候选还是保留自研 patch。

`R5-HARNESS-BLOCKED` 不自动推翻 C01/C02/C03 原始日志已经支持的技术事实。
若 R5 因审计框架本身被阻塞，社区路径改为人工代码审阅、最小洁净回放和
GitHub 官方 CI，不再继续制造比补丁本身更大的自定义验证系统。

### 整个 bug 工作的剩余量

| 工作线 | 当前状态 | 条件满足后的预计用时 |
|---|---|---:|
| 根因与 main 确定性复现 | 已完成 | 0 |
| B 语义、race 与压力旁证 | 已完成 | 0 |
| main 社区本地证据收口 | U01 任务书已写，待单独授权执行 | GLM 约 1～3 小时，Codex 复核约 1 小时 |
| issue/PR 最终材料 | 草稿已有，待 U01 和最终代码审阅 | 约 1～2 小时 |
| v1.3 port、correctness、Ceph build | 本地技术证据已有 | 0 |
| v1.3 远端 ABI/read smoke | 未完成 | 约 0.5～1 小时 |
| v1.3 完整 S/A/B 性能矩阵 | pool objects 安全门阻塞 | 白天态约 8～12 小时；meta 重查时最长约 14 小时 |
| 社区 review/merge | 尚未提交 | 外部时间，无法承诺 |

### “结束”的三个口径

1. **C03/社区提交准备结束**：R5 已得到规定的 BLOCKED 终态并经 Codex 复核，C03 于 2026-08-18 结束；U01 是后续独立轻量回放，不是 C03-R6。
2. **内部生产替换验证结束**：还需一个满足对象数与 health 门的完整夜间 S/A/B 性能窗口；当前无法承诺日历时间。若现有 pool 长期不能达到门限，需要用户另行选择专用测试环境或接受自维护 patch 的证据边界。
3. **社区维护闭环结束**：issue/PR 获得社区处理或合并；耗时取决于维护者，可能是数天到数周，不属于本地任务可保证范围。

### 下一决策点

C03 已按硬停止规则结束。下一阶段不再修建 R5 的 37-case 自定义 harness，建议
优先走轻量社区候选路径：人工代码/测试审阅、全新 latest-main 最小洁净回放、
草稿与匿名查重复核；完成后由用户明确授权社区写操作，并依赖 GitHub 官方 CI
提供外部独立验证。该路径不得继承 R3/R4 的旧 `PASS-B-PR-READY-LOCAL`。

与之独立的生产线仍是 v1.3 远端 ABI/read smoke，以及对象数和 health 安全门满足
后的完整 S/A/B 性能矩阵。v1.3 本地单测不能外推为真实 randwrite 性能恢复。

## 目录结构

```
docs/
  SUMMARY.md                             历史汇总（结论/时间线/机理/开放问题）
  bugzilla-juicefs-randwrite-flush-race-20260813.md   缺陷报告全文（机制/代码证据/实测修订）
  REPRO.md / REPRO-v131.md               main / v1.3.1 基座复现步骤
  VERIFICATION.md                        验证矩阵与归因
  ENV.md                                 环境信息（已脱敏）
scripts/
  repro.sh                               成品复现脚本（模式 A 复位对照 / 模式 B 无复位预热 + ⚑塌态标注）
patch/
  juicefs-flush-race-fix-v131.patch      生产补丁（against e0032b2a；v1.3.1 上 4.9× 同会话验证）
  juicefs-flush-race-fix-main.patch      参考变体（against edabf9c2；main 上无收益，仅供存档）
  eaf3d21f-partial-read.patch            构建基座 pin（上游 main 已合，仅对齐现网二进制）
community-materials/
  README.md                              社区交流归档入口、证据边界与发布前置条件
  candidate/ + tests/                    最终两文件候选、writer-only B patch、社区/C02 测试
  v131-reference/                        V02 固定使用的 v1.3 B port 与接口适配测试
  evidence/ + reports/                   C01-R1/C02/C03-R2 原始技术日志、archive 与复核报告
  drafts/ + search/                      历史 issue/PR/commit 草稿与匿名只读查重材料
tasks/
  U01-latest-main-minimal-clean-replay.md      latest main 最小洁净回放
  V02-v131-SAB-performance-validation.md       v1.3.1 S/A/B 真实 Ceph 性能验证
data/
  v131-32rounds/                         v1.3.1 历史证据（28 轮崩塌 + 补丁 ABBA 全量）
  main-repro/                            main 基座全部会话（fresh-3way ×2、multiround ×2、模式 B 16 轮签名、1job 机制）
```

## 生产路线（待项目方拍板）

- 首选：v1.3.1（e0032b2a）+ eaf3d21f + `patch/juicefs-flush-race-fix-v131.patch`；实测二进制 `/tmp/juicefs-03-8`（md5 `1f60618c44fda1c19fecd75d52e053e9`），8+ 轮实测 2970~3583。
- 代价：与上游分叉，升级时需重新适配复验；QA（单元测试/完整性/soak）未完成——**待做清单在 SUMMARY §2.3，全部在隔离目录进行、共享布局零写入**。
- 备选：退回 128K 挂载（放弃读侧 +115.6%）。

## 关键事实速查

| 事实 | 数值 |
|---|---|
| 竞态跳过率（两基座同款） | 99.2%（插桩） |
| v1.3.1 原版 randwrite | 535~551 自锁（与轮次/对象数/复位无关） |
| v1.3.1+补丁（同会话） | 4.9×（544→2647） |
| main 原版 | 新鲜 3096~4404；深退化 525~546（模式 B r3 起 ⚑塌态） |
| main+补丁 | 与 main 无差异（签名逐轮相同：42~63ms、300~500MiB） |
| 上游竞态修复提交 | 截至 frozen `53835e24` 未发现等价修复；latest main 待 U01 重查（历史二分分界 #6336 不是该竞态修复） |
| 单提交回合 v1.3.1 | #6311 / #6311+#7016 / +#6271 全部无效 |
| `-o max_read` 路线 | 不可行（源码确认） |
