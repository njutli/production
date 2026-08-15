# JuiceFS 纯随机写"登记竞态"缺陷——内部证据与验证资料包

> 打包：DeepSeek　｜　日期：2026-08-14（修订版 v3）　｜　缺陷编号：INTERNAL-2026-08-13-001
> 用途：**内部存档**（不对外报告——main 已由上游修复）。
> **一句话结论**：写尺寸 = 数据块大小时纯随机写崩塌 ~5.8×。**main 已由上游 #6311 修复，但 #6311 单独
> backport 到 v1.3.1 实测无效（548/542 仍塌）⇒ 生产修复 = 本包补丁（v1.3.1 + eaf3d21f + 同步 slice ID）。**

## 目录结构

```
patch/
  juicefs-flush-race-fix-v131.patch    生产补丁（against e0032b2a；28+8 轮历史验证 2970~3583）
  juicefs-flush-race-fix-main.patch    参考变体（against edabf9c2；仅用于归因矩阵）
scripts/
  repro.sh                             自包含复现脚本（任意基座通用：环境落盘+layout+双臂+计数器采样）
docs/
  bugzilla-juicefs-randwrite-flush-race-20260813.md   缺陷报告全文（原理/代码级证据/A.4 实测修订）
  REPRO.md                             复现步骤（main + #6311 回退法）
  REPRO-v131.md                        v1.3.1 基座复现法（历史证据）
  VERIFICATION.md                       验证矩阵 + 归因 + 版本拓扑证据
  ENV.md                                环境信息（已脱敏）
data/
  main-repro/                          main 基座实测（健康 3815｜回退#6311 543/539｜+补丁 1379｜v1.3.1+#6311 548/542｜单job机制）
  v131-32rounds/                       v1.3.1 基座历史证据（28 轮崩塌 + 补丁 A/B 全量）
```

## 验证矩阵速览（2026-08-14 全部实测）

| 构建 | randwrite（MiB/s） | 结论 |
|---|---|---|
| v1.3.1 原版 | 551（28 轮历史） | 崩塌 |
| v1.3.1 + 本包补丁 | 2970~3583（8 轮历史） | **修复（生产路线）** |
| v1.3.1 + #6311（cherry-pick 零冲突） | 548 / 542 | ⚑ **仍塌——上游修复在 1.3 线无效** |
| main 原版 | 3815 | 已修复 |
| main 回退 #6311 | 543 / 539 | 崩塌精确复现 |
| main 回退 #6311 + 本包补丁 | 1379 | 修复 |

## 生产修复定案

- **构建基座 = v1.3.1（e0032b2a）+ eaf3d21f（部分读，上游 main 已合，对齐现网二进制）+ `patch/juicefs-flush-race-fix-v131.patch`**。
- 不带 #6311（1.3 线上实测无效）。
- 实测二进制：`/tmp/juicefs-03-8`，版本串 `1.3.1+2026-08-13.e0032b2a-03-8-ceph`，md5 `1f60618c44fda1c19fecd75d52e053e9`。
- Ceph 连接走卷格式配置的 `--access-key/--secret-key`（cluster/user），**无需任何代码改动**。

## 归因备忘

- main 的修复 = #6311（`00b5ebcf`，2025-08-21，"refactor: improve lock management in commitThread"），首含 v1.4.0-beta1；v1.3.1 与 release-1.3 均不含。
- #6311 单独 backport 无效 ⇒ main 的健康是 #6311 与其它 post-v1.3.1 变更的共同作用；1.3 线崩塌主因 = 异步登记跳首写上传（本包补丁直接消除）。
- 修复边界：仅覆盖"写尺寸 = 块大小"；<块大小的小随机写为预存行为（负控 bs=128k@256K = 556）；修复后 ~3000 平台由 meta 提交率墙（F44）决定，与本缺陷无关。
