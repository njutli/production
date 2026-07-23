# 任务书生成指导（Task-Book Authoring Guide）

> 本文件规定**每一份**测试任务书（面向 GLM 执行）必须遵守的写作规范与固化注意事项。
> **今后新建任何 `NN-*` 测试任务书，都必须内含"通用注意事项"整段（可引用本文件章节号，但关键红线须就地复述）。**
>
> **⚠️ 测试过程必须严格遵守 `prod-deploy/skills/` 下全部文档：**
> - `skills/TESTING-GUIDE.md`：health 检查 / compact cooldown / 缓冲暂态 / 可靠性判据 / OSD compaction 状态检查（admin socket，含 `compact_queue_len`/`compact_running`/`kv_sync_lat` 三指标全绿才继续）
> - `skills/test-commands-reference.md`：完整 fio 命令 / §8.3 稳态中位数 / §9 数据采集
> - `skills/LONG-RUNNING-TEST-SKILL.md`：长跑任务监控
>
> 特别是 TESTING-GUIDE 的以下要求**不可省略**：
> - §1.3：高强度写后必须用 admin socket 检查 compaction 三指标，全绿才继续下一项
> - §2.2：每个 fio 命令前必须调用 `check_ceph_health`
> - §3：layout 后必须 compact cooldown 并轮询至 `compact_running=0`
> - 数据异常时必须排查原因并重测，不得跳过
>
> 权威方法论仍以 `prod-deploy/skills/test-commands-reference.md`（§8 统计）、`prod-deploy/skills/TESTING-GUIDE.md`（踩坑教训）为准；本文件是"每份任务书必带清单"。

---

## 一、任务书结构（固定骨架）

每份任务书按此顺序：

1. **抬头**：面向对象（GLM）、是否重跑、承接的结果目录、方法论 skill 引用。
2. **〇、背景**：为什么做这个任务 / 上一轮遗留什么问题（让执行者理解意图，不是盲跑）。
3. **一、目标**：一句话说清要判定/回答什么。
4. **二、口径与矩阵**：测试参数、并发档、REPEAT、验收线。
5. **三、执行步骤**：可逐条勾选。**第一条（步骤 0）必须是"测试前通读 skill 并确认关键点"，最后一条必须是"测试后按 skill 复核执行合规"**（见 §二.8，必带）。
6. **四、交付物**：结果目录结构 + 报告落点 + results-table 更新。
7. **五、通用注意事项**（见本文件 §二，**必带**）。
8. **红线汇总**：本任务特有红线 + 复述关键通用红线。

---

## 二、通用注意事项（每份任务书必带，逐条固化）

> 以下六条是历史反复踩坑固化下来的红线。新任务书须整段包含（可精简措辞，但每条都要在）。

### 1. 数据统计口径（本次新增固化）

- **稳态中位数优先**：fio 平均 BW 受测试前期写缓冲/冷启动暂态污染（写类偏高约 7-8%，曾超网卡线速属假象）。正确值 = fio 逐秒瞬时带宽序列**截掉开头 1/4 爬升段后取中位数**（skill §8）。
- **所有 fio 命令必须加** `--write_bw_log=<prefix> --log_avg_msec=1000`。fio 默认 `per_job_logs=1`，多 job 会自动落 `<prefix>_bw.<job_id>.log` 共 numjobs 份——**务必确认这些 per-job 文件全部保留**（不要 `--per_job_logs=0`、不要只留一份合并 log）。
- **多 job 统计**：
  - 有 per-job log → **§8.3：按时间戳对齐【求和】所有 job 的逐秒带宽 → 截前 1/4 → 稳态中位数**（最优）。
  - 只有一份合并 log 或无 log → **退取 fio 全文 `Run status group (all jobs)` 聚合行**（次优，含爬升段略偏高但物理正确）。
  - **绝对禁止**：一份合并 bw_log 稳态中位数 **× numjobs** 外推（历史 65× 失真的错误来源）。
- **多实例（多个独立 fio 进程）**：各实例取自己的聚合值后**求和**，不是乘。
- REPEAT=3 **取中位数（第 2 大值）**，不取平均、不挑轮次。
- **randrw 的 R/W 分开报，不合计**（读=入向、写=出向，全双工独立，各自对验收线）。
- **超网卡线速的平均值一律不认**（100GbE≈12500 MiB/s、千兆≈124 MB/s 为物理上限），汇报前必换稳态真实值。

### 2. 冷态净化（drop_caches）

- 冷态口径下，**每档每轮跑前必须 drop_caches**（客户端 157 + 3 个 slave 全部执行，见 skill §3.1）；暖态测试才跳过。
- direct=1 只绕内核页缓存，**绕不开 JuiceFS 客户端缓冲**——冷态还需 cache=0 挂载。

### 3. fresh-volume / 冷启动失真（randwrite/randrw 重点）

- randrw/randwrite 若用 `--create_on_open=1` 在**新建卷**上跑，第 1 轮会"读命中刚建的稀疏/空洞区 → R 虚低、W 独占带宽虚高"，是纯冷启动失真、非真实能力。
- **须用方案 A**：复用已 layout 铺好数据的卷（skill §6.4 analysis 版），**不 create_on_open、不 fresh volume**，消除该失真。
- 若确需 fresh volume，须按标准清卷流程（见本文件 §7）执行，并在报告里显式声明该档为冷启动失真档。

### 4. 后端干净态（OSD compaction cooldown）

- 高强度写测试后，**restart OSD 不能清除 compaction 积压**——必须用 `compact` 命令 + cooldown 轮询至 `compact_running=0`（skill §3.2）后再进行下一项，否则残余积压污染下一档。
- `compact_running=0` + `compact_queue_len=0` 只表示"没有正在 compact"，**不保证 LSM tree 最优**。膨胀的 LSM tree 会在三指标全绿时仍导致高并发读性能骤降。关键测试项前须强制 compact + 轮询确认。数据异常必须排查并重测，不得跳过。
- 写项之间必须 compact cooldown（randwrite-true → layout → randrw → randwrite-ow 之间均需）。
- 切换 OSD config 模式后，须等集群**完全恢复**（经验 10+ min）再开测；对比测试两组须在**同等干净态**下测，否则对比无效。

### 5. 环境前置检查

- 开测前 `ceph health` 必须 `HEALTH_OK`、所有 OSD `up`（skill §1.1）。
- 确认 JuiceFS 版本含 loadRange 修复（commit eaf3d21f，即 `1.3.1+` 或 `1.4.x`）——stock v1.3.1 有 2× 读放大 bug。
- **157 红线**：157 上有 WekaIO 业务在跑，**禁动内核/网卡/RoCE/md0/WekaIO 路径**；BeeGFS 与本测试抢同批盘须错峰。

### 6. 记录规范

- 每个结果目录**必须含 `commands.sh`**，记录实际执行的完整命令（可复现）。
- 每项测试须保存：fio 全文输出、全部 per-job bw_log、`env-snapshot`、ceph 状态、（如涉及）pprof/pidstat/nic 采集。
- 验收线随口径：不限速 100GbE = **6250 MiB/s**（网卡半速）；千兆限速 = **59 MB/s**；多客户端 = N × 单客户端线。
- randrw 验收档 = **128 并发**（D2 档 16×8 的整机等效，以当前项目约定为准）。

### 7. 卷清理（防止数据累积污染后续测试）

- **`juicefs format` 不删除任何 pool 对象**——只重置 TiKV 元数据，pool 中的 Ceph 对象成为孤儿。多轮测试中数据只增不减。
- **必须用 `juicefs destroy`**（删除 pool 中 JuiceFS 拥有的对象 + TiKV 元数据）。详见 `skills/TESTING-GUIDE.md` §3.5。
- **标准清卷流程**（从老集群脚本固化）：
  1. `juicefs umount`
  2. `sleep 65`（等会话 TTL 过期，不等待 destroy 会失败）
  3. 提取 UUID：`UUID=$(juicefs status "${META}" | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)`
  4. `juicefs destroy "${META}" "${UUID}" --yes`
  5. compact cooldown（destroy 产生 tombstone 积压，必须清理）
  6. `juicefs format` + `juicefs mount` + `mkdir`
- **关键**：destroy 必须传 UUID（从 `juicefs status` 提取），不能传卷名。传错会报 `UUID <name> != expected <uuid>`。
- **测试中数据累积检查点**：每个清卷点前后用 `rados df -p <pool>` 确认对象数，确保 destroy 后归零。
- **⚑ 2026-07-23 红线：轮间清理与组内清卷统一用 `juicefs destroy`（soft-clean，保留 pool）**。**禁用 `ceph osd pool delete + create`**——删建 pool 会改 pool_id → CRUSH 重算 PG→OSD 映射 → 同一次重建内也产生 -22~-26% 漂移（实证见 `00-baseline-20260723.md` §9.6）。**禁 OSD restart 作轮间清理**（重置 tmpfs/BlueStore 内存态）。pool delete+create 仅在 destroy 失败/孤儿累积时兜底，用后须视为一次重建、重新标定基线。

### 8. skill 合规自查（测试前后必带，2026-07-23 固化）

> GLM 执行测试必须遵循 `skills/` 全部文档。为确保"遵循"落到实处，每份任务书的执行步骤须首尾各加一条：

- **步骤 0（测试前）**：通读相关 skill 并确认关键点——至少 `baseline-reproduction-skill.md`（§2.2 清理层级 / §2.5 soft-clean 流程 / §3.1 执行顺序 / §4.3 判据）、`TESTING-GUIDE.md`（§1.3 compact 三指标 / §2.2 health / §3 cooldown）、`test-commands-reference.md`（§8.3 稳态中位）。**须显式列出本任务最相关的 skill 章节号。**
- **末步（测试后）**：对照 skill 逐条复核执行合规，并在报告记录"skill 合规自查结果"。必查项至少含：① 清理是否只用 `juicefs destroy`、**未出现 `ceph osd pool delete`**；② 清理未夹带禁止的操作；③ 每写项后 compact cooldown 已轮询至 `compact_running=0` **且 `compact_queue_len=0`**；④ 每 fio 前 drop_caches；⑤ 统计口径用 §8.3 稳态中位。**任一不符须显式标注并说明对结论的影响，不得默默跳过。**

### 9. 分层授权：可自主修复区 vs 禁止擅动区（2026-07-23 固化）

> 背景：GLM 曾因钦定脚本跑不通（auth key）**擅自改用被禁的重建方式且不声明** → 采到无效数据。故每份任务书须明确授权边界。

- **✅ 可自主修复（工程性，不改变量）**：脚本 bug、环境适配（auth/路径/依赖）、采集增强。**发现脚本会采到错误数据时应先修好再采，不要用错误脚本采错误数据。修完必须在报告显式声明改了什么、为什么。**
- **🔴 禁止擅动（改变量则实验失效）**：控制变量（清理方式/是否删 pool/是否重建/pool_id/CRUSH/pg_num）、测试项、口径、判据、任何标"红线/核心变量"的项。**遇到"必须改变量才能跑通"的障碍 → 停下来报告障碍、等确认，不得自行绕道。**
- **规则一句话**：实现怎么修都行；**改变量之前必须停下来报告，不能绕道**。
- **建议**：验证性任务书对应脚本应内置"变量守卫"（运行时自动比对控制变量是否被动，触发即报警并把判定标为不可信），使擅自改变量当场暴露，而非事后靠人工审计。

---

## 三、命名与落点约定

- 测试任务书：`doc/perf-tasks/NN-<slug>.md`（`00-*`=归档、`01-N-*`=不限速阶段）；非编号的专项（如审计）用描述性名，明确标注"不占编号"。
- 每份任务书完成后须在 `doc/perf-report/` 产出**同编号分析报告**；数据入同一 `results/` 目录（多项建子目录）。
- 审阅记录入 `doc/deploy-log/`；`perf-analysis/` 只放计划文档。
- 真值同步进 `doc/deploy-log/results-table.md`。

---

## 四、术语与表达

- 统一用**"失真"**（存储领域通用），**禁用"伪影"**。
- 结论若与既有论断冲突或被数据推翻，**显式标注、提示人工复审**，不得默默改写论断。
