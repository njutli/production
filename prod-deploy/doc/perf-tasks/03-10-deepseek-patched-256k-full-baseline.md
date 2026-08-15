# 03-10-deepseek：补丁版 256K 全 7 项基线（固化证据集，夜间长块）

> 任务书类型：**一个补丁路线固化基线**（P 臂 2 挂载 × 全 7 项 × 2 轮，非劣性判定）
> 作者：DeepSeek　｜　日期：2026-08-13　｜　执行方：GLM（夜间长块，需挂机监控）
> 母文档：03-8（补丁已证 randwrite 恢复 +445%、randrw 无回归）、03-9（白天/傍晚档）、REFERENCE-VALUES 表一
> 🔴 **所有统计量由 DeepSeek 计算，GLM 只出原始数字与原文粘贴**
> 🔴 脚本：`t40-wrapper.sh`（scp 到 `/tmp/`）；判档门复用 `/tmp/t39-nsbgate.sh`；objwatch 由 `t37l-objwatch.sh` 拷贝并改 `HARD=12M`（wrapper 自动完成并声明）

---

## ⚑ 计划线

```
03-8  通过：补丁修复 FlushTo 竞态（randwrite 551→3003.5，+445%，落 128K 平台）；randrw 无回归（−1.4%）
03-8  ★新墙：写侧 ~3000 = meta 提交率 ~12K/s（F44 候选，两臂共享，TiKV 侧待证）
03-9  执行中/待执行：段A -o max_read 分离挂载（无补丁路线）｜段A2 读写共享性｜段B F42 sweep｜段C 负控｜段D TiKV 侦察
              │
★ 03-10（你在这里，夜间长块）：
  补丁版 256K × 2 挂载（P1 P2，ns/B 判档门）+ V4 全 7 项 × 2 轮
        ⇒ 非劣性判：mseqread/randread/randrw/randwrite 落平台（4 项判定）
        ⇒ 填未测格：seqread/seqwrite/mseqwrite@256K（描述性）
        ⇒ 顺带：randwrite 轮 jfs-stats 再确认 F44 meta 率 ~12K/s
              │
  通过 ─→ 补丁路线 7 项固化证据集齐（+03-8 的 randwrite/randrw 加挂载数）
  异常 ─→ 记录并回报，判定留给 DeepSeek
一句话：给补丁路线补齐全 7 项的固化证据，并填上 256K 从未测过的顺序项格子。
```

---

## 〇、背景

03-8 只测了补丁臂的 randwrite/randrw（写受影响项）。固化 256K+补丁 需要**全 7 项非劣性证据**；且 REFERENCE-VALUES 表一有三个格子是空的：**seqread/seqwrite/mseqwrite @256K 从未测过**（顺序路径机制上不受 max-fuse-io 影响——03-6 顺序读尺寸×2/延迟×2.00 零收益——但补丁把 `NewSlice` 从异步改同步，顺序写路径同样经过该代码点，需实测确认无回归）。另 03-8 复核发现的 F44 候选（写侧 meta 提交率 ~12K/s）需要第二个独立会话的 jfs-stats 证据。

## 一、目标

- **唯一通过/不通过项（非劣性判定，4 项）**：mseqread、randread、randrw（单方向）、randwrite 的中位数各自落入平台区间（§三）。全落 ⇒ 补丁路线固化证据齐；任一未落 ⇒ 只报数据，判定留给 DeepSeek（⛔ GLM 不判）。
- **描述性（3 项）**：seqread/seqwrite/mseqwrite @256K 首测，只报数值与 F44 顺带数据（randwrite 轮 jfs-stats）。

## 二、口径与矩阵

- 挂载：补丁版二进制 `/tmp/juicefs-03-8`（md5 `1f60618c44fda1c19fecd75d52e053e9`，段0 先复核），`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`；验 `max_read=262144`。⛔ 不碰 `/usr/local/bin/juicefs`。
- 2 挂载（T40-P1/P2），每挂载：ns/B 判档门（≤3 试，重试换 label，`t39-nsbgate.sh`）→ V4 全 7 项 × 2 轮（`SKIP_REMOUNT=1` 单实例、`RUNTIME=180`、`OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=12000000`）。
- ⚑ **OBJ_MAX/objwatch HARD 由 6M/8M 上调至 12M**（声明）：起始对象 2.36M，2 挂载全项净增预估 ~7M（randwrite ~0.9M/轮 + randrw/seqwrite/mseqwrite 覆盖写）；池 MAX AVAIL 26 TiB，容量无虞。⛔ 不得再上调。
- 项顺序 = V4 默认（seqread mseqread randread randrw seqwrite mseqwrite randwrite）。

## 三、判据（每条指名数据来源）

| # | item | 区间（好档平台） | 来源 |
|---|---|---|---|
| P1 | mseqread | **[4133, 4321]**（256K 平台 4196~4257 ±1.50%） | `rounds.tsv` 列3，label=T40-P* |
| P2 | randread | **[3906, 4219]**（256K 平台 4027~4096 ±3%） | 同上 |
| P3 | randrw 单方向 | **[1824, 2088]**（256K 平台 1931~1978 ±5.56%）| `bw-raw.tsv`（读/写分向，禁相加） |
| P4 | randwrite | **[2817, 3397]**（128K 平台 2942~3258 ±4.26%） | `rounds.tsv` 列3 |
| P5⛔ | seqwrite | 描述性：week3 平台 [1356,1462]（±14.50% 门槛过宽，禁判定） | 同上 |
| P6 | mseqwrite | **[4247, 5491]**（week3 [4594,5105] ±7.56%）；首测@256K，只报不转正 | 同上 |
| P7⛔ | seqread | 描述性：week3 [1234,1324]（±7.78% 门槛过宽，禁判定） | 同上 |
| G | 档位门 | ns/B ∈ [2.958, 3.616]（3.287±10%），重试换 label | `probe-gate.log` |
| E | 环境门 | 全程 HEALTH_OK、无 SMOKE、pid/starttime_ticks 恒定 | `health.txt`、`instances.txt` |

- 判定口径 = **非劣性**（2 挂载/臂允许，§二.10.4.3）；中位数 = 各挂载中位再取中位（2 挂载时 = 均值）。
- 坏档压力测试（§二.10.4.4）：若某臂被 ns/B 门拒掉重挂、最终臂内混档，报告须报出各臂档位；任何"落平台"结论附 d_max=−30% 折算。
- F44 顺带：P 臂 randwrite 各轮 `jfs-stats-{pre,post}.txt` 交付（DeepSeek 算 meta 提交率，与 03-8/03-7L 的 ~12K/s 三会话对账）。

## 四、执行步骤

**步骤 0（测试前）**：通读 `TESTING-GUIDE.md`（§1.3/§2.2/§3）、`test-commands-reference.md` §8.3、AUTHORING-GUIDE §二.8/§二.10/§二.11。本任务**无 layout、无 destroy、无 pool 操作**。

1. `md5sum /tmp/juicefs-03-8` 复核 = `1f60618c44fda1c19fecd75d52e053e9`；scp `t40-wrapper.sh` 到 `/tmp/`，`bash -n` 检查。
2. 跑 `bash /tmp/t40-wrapper.sh`：健康/容量/对象数前置检查 → P1 判档门 → 全 7 项 → P2 判档门 → 全 7 项 → 恢复 128K。
3. **夜间监控（LONG-RUNNING-TEST-SKILL）**：每 ~1h `tail -3 /tmp/opencode-t3.10/progress.txt` + `tail -1 wrapper.log` + `ceph health`；任何 STOP/OBJ_BREACH/health 非 OK ⇒ 记录后按任务书红线处理（停止并回报，不自行改变量）。
4. 早晨收尾：归档 `tar czf /tmp/opencode-t3.10-20260814.tar.gz /tmp/opencode-t3.10`，回报进度 + 交付物清单。

**末步（测试后）**：skill 合规自查——① 未动 `/usr/local/bin/juicefs`、未碰 `/tmp/ray`；② 写项后 compact cooldown（V4 内部 aggressive_cleanup 已做，wrapper 只记录）；③ 每 fio 前 drop_caches（V4 内部）；④ 统计口径 §8.3；⑤ randrw 分向。**任一不符显式标注**。

## 五、交付物（GLM，157 `/tmp/opencode-t3.10/`）

1. `arm-verify.txt`、`instances.txt`（含 verify 行）、`probe-gate.log`、`remount-retry.log` 全文
2. `rounds.tsv` T40-P* 与 PROBE-T40-* 全部行；`bw-raw.tsv` 全文
3. 每挂载每项 `fio-*.txt` 的 bw 行；每轮 `jfs-stats-{pre,post}.txt` 原件（F44 用）
4. `i1-jfsstats-*`、`i2-*` 行数逐文件；`health.txt`、`wrapper.log`、`progress.txt` 全文
5. `objwatch-T40-P*.tsv` 峰值与行数；OBJ_BREACH 事件（如有）原文
6. 夜间每小时监控记录（时间 + progress 尾行 + health）
7. 异常与偏差逐条

## 六、风险与红线

1. **对象数**：OBJ_MAX/HARD 已上调至 12M（声明）；若仍 BREACH ⇒ 停并回报（数据保留），⛔ 不得再上调。
2. **坏档**：判档门 + 重试换 label；臂内若混档，报告逐臂档位（§二.10.4）。
3. **夜间无人值守**：任何 STOP/健康异常 ⇒ 停，回报，⛔ 不自行改变量继续（分层授权 §二.9）。
4. ⛔ 全程不碰 `/usr/local/bin/juicefs`、`/tmp/ray`；无 layout/destroy/pool 操作；157 有 WekaIO/BeeGFS 业务，禁动内核/网卡/RoCE/md0。
5. 时钟：157 时间 = WSL − 1h；归档 fio mtime 与报告时间线有 ~55min 系统偏差（照录）。

## 七、时间预算

| 挂载 | 内容 | 预算 |
|---|---|---|
| P1 | 判档门 ~6min + 7 项×2 轮 ~100min + 清理 | ~2h |
| P2 | 同上 | ~2h |
| 收尾 | 归档 | ~0.25h |
| **合计** | | **~4.3h**，夜间长块（03-9 之后接续） |

砍单顺序：**seqread → seqwrite → P2 全项**。⛔ P1 的 7 项与 P2 的 randread/randrw/randwrite/mseqread 不可砍。
