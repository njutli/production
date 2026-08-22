# 03-17g 任务书：写侧 −11% 的二进制归因（`1f60618c` vs `de93563f` 同日 meta 对照）

> 计划线：`03-16 → 03-17（作废）→ 03-17b → 03-17c → 03-17d → 03-17e（Seg A 成立/Seg B 撤回）→ 03-17f（msgr=8 定案）→ **03-17g（本任务书）** → B1 写侧 TiKV`
> 执行方：GLM　｜　分析方：opencode　｜　立项日：2026-08-22
> 前置报告：`doc/perf-report/03-17f-deliver-config-baseline-20260821.md`（§4.7 定因、§9.2 写侧暂缓固化、§9.4 下一步第 1 条）
> 前置结论：主计划 **F67**（写侧 −11% = meta/写op 0.91→0.989）、**R21**（比值型历史指标须核对计数器口径）、**A38**（不需要全套二进制 ABBA）

---

## 〇、GLM 全自动执行纪律（与 03-17f §〇 相同，逐条仍生效）

1. ⛔ **全程不得向人提问**。只有 §七 穷举的 STOP 条件才停机；其余异常一律记录并续跑。
2. cell 与 cell 之间**直接连跑**，不等确认。
3. 进度播报**只报机械状态**（cell 名 / 结束时间 / `rounds.tsv` 最后一行原文 / 二进制校验四行原文）；⛔ 不报均值、不报百分比、不做好坏判断、不写结论。
4. ⛔ **不要计算 meta/写op，不要做任何比值、差值、百分比**。一切统计量由 opencode 从原始数据计算；你只负责让原始计数器落盘并完整回传。
5. 开工前先 `md5sum` 本文件，与派发报文中的 md5 核对，不一致立即回报并停手。

---

## 一、本次唯一要回答的问题

**03-17f 测到的写侧 −11%（randwrite 2681 vs 03-10 的 3018.5），是新二进制 `de93563f`（B-catchup）造成的，还是跨批口径/漂移造成的？**

判决量 = **meta/写op**，定义（⚑ 本任务书唯一合法口径，由 opencode 复算）：

```
meta/写op = Δ juicefs_transaction_durations_histogram_seconds_total
          ÷ Δ juicefs_fuse_ops_total_write
```

| 已知 | 值 | 来源 |
|---|---|---|
| `de93563f`（新，B-catchup） | **0.984 ~ 0.991**（7 个 cell） | 03-17f §4.7，opencode 从 `jfs-stats-pre/post.txt` 复算 |
| `1f60618c`（旧，A-sync） | **0.91** ⚠ | 03-10 报告**正文文字**，⛔ **计数器口径未经核对** |

⇒ 本次要做的就是**把上表第二行从"历史正文文字"换成"同日实测、同公式复算"**。

### 一.1 ⚑ 为什么不能只跑旧二进制一个 cell

我（分析方）曾判断"15 min 单 cell 即可"，**该判断已撤回**：只跑旧二进制 = 今天白天 vs 昨天 17:00–22:00 的跨天比较。而 F44/F45 已证 meta 管线存在日/夜态切换（白天 ~12K/s ⇒ ~3000 MiB/s；退化态 6~7K/s ⇒ 1500~1800）。这正是 A37/A38 栽过两次的同一类错误。

⇒ **必须同日、同集群、连续时段内跑两个二进制做对照**，两臂唯一差异 = 二进制文件本身。

---

## 二、设计（两臂 ABBA，4 个 cell）

| 项 | 值 |
|---|---|
| **O 臂**（Old / A-sync） | `/tmp/juicefs-03-8-async-backup`，md5 **`1f60618c44fda1c19fecd75d52e053e9`** |
| **N 臂**（New / B-catchup） | `/tmp/juicefs-03-8`，md5 **`de93563f11a5ff3bd94dd25a4e0283b1`** |
| 执行序列 | **O1 → N1 → N2 → O2**（ABBA，消时序漂移） |
| 测试项 | **`ITEMS=randwrite`**，仅此一项 |
| 每 cell | 1 次独立挂载 + 1 轮 fio，`RUNTIME=180`、`REPEAT=1`、`--remount` ⇒ **调用 V4 四次** |
| 挂载参数（两臂逐字符相同） | `JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"` |
| **Ceph 客户端配置** | ⚑ **两臂都用系统默认 `/etc/ceph/ceph.conf`（不含 `ms_async_op_threads` ⇒ 默认 3）；⛔ 本次不注入任何私有 conf、不设 `CEPH_CONF`** |
| 对象闸门 | `OBJ_TARGET=2500000`，`OBJ_MAX=8000000`（已授权） |
| 预估时长 | **~1.5 ~ 2 h**（4 cell × [挂载 ~1min + fio 3min + obj gate/gc ~2-4min + aggressive_cleanup 8-12min]） |

### 二.1 ⚑ 为什么用系统默认 conf（msgr=3）而不是交付配置的 msgr=8

三条理由，缺一不可：

1. **F67 已证 meta/写op 与 msgr 无关**：03-17f 中 msgr=8 臂均值 0.989 vs msgr=3 臂均值 0.986（差 0.3%）⇒ 用 msgr=3 不损失对交付配置的推断效力。
2. **msgr=3 = 03-10 的原始条件**，于是本次**顺带得到 03-10 randwrite 3018.5 的同日重锚**，可把"二进制"与"8 天集群漂移"两个因子一并分开（见 §八.2）。
3. **少一个动件少一类事故**：不注入 conf ⇒ 不存在 `CEPH_CONF` 未生效、私有 conf 写错、误改全机 conf 的风险面（B6）。

---

## 三、三个已知陷阱（开跑前逐条自检，结果写进日志）

### 三.1 ⚠ 陷阱一：裸 `juicefs` 会取到第三个错版本

| 路径 | md5 | 本次用途 |
|---|---|---|
| `/tmp/juicefs-03-8-async-backup` | `1f60618c44fda1c19fecd75d52e053e9` | ✅ **O 臂** |
| `/tmp/juicefs-03-8` | `de93563f11a5ff3bd94dd25a4e0283b1` | ✅ **N 臂** |
| `/usr/local/bin/juicefs` | `bdd182cf2cd43be657cb4ec0b5a6a048` | ⛔ **错版本，绝不可用** |

V4 调用的是**裸 `juicefs`**，必须靠 PATH shim 切换：

```bash
mkdir -p /tmp/t53-bin-old /tmp/t53-bin-new
ln -sf /tmp/juicefs-03-8-async-backup /tmp/t53-bin-old/juicefs
ln -sf /tmp/juicefs-03-8             /tmp/t53-bin-new/juicefs
```

每个 cell 开跑前 **export 对应 PATH 并落盘四行证据**到 `/tmp/production/binary-verify-<LABEL>.txt`：

```bash
export PATH=/tmp/t53-bin-old:$PATH        # 或 -new
{ command -v juicefs
  readlink -f "$(command -v juicefs)"
  juicefs version
  md5sum "$(readlink -f "$(command -v juicefs)")"
} > /tmp/production/binary-verify-<LABEL>.txt 2>&1
```

md5 与本 cell 期望值不符 ⇒ **STOP（S2）**。

### 三.2 ⚠ 陷阱二（本次最关键）：shim 只能证明"打算用哪个"，不能证明"实际跑的是哪个"

**必须按实测挂载进程取二进制指纹**（R20 的等价物；03-17e 就是死在"只验意图不验实况"）。挂载成功后 30 s 内执行：

```bash
PID=$(pgrep -f "juicefs.*mount.*/mnt/juicefs" | head -1)
{ echo "pid=$PID"
  readlink -f /proc/$PID/exe
  md5sum "$(readlink -f /proc/$PID/exe)"
} >> /tmp/production/binary-verify-<LABEL>.txt 2>&1
```

- `/proc/$PID/exe` 的 md5 与本 cell 期望二进制**不一致 ⇒ STOP（S4）**。
- 取不到 pid ⇒ 重试 3 次（间隔 10 s），仍失败 ⇒ **STOP（S4）**。
- ⚑ 若 `readlink` 显示 `(deleted)`，改用 `md5sum /proc/$PID/exe` 直接算，仍须匹配。

### 三.3 ⚠ 陷阱三：判决量依赖两个计数器，缺一即全废

V4 已自动落盘 `jfs-stats-pre.txt` / `jfs-stats-post.txt`。**每个 cell 跑完立即自检这两个键存在且增量 > 0**：

```bash
for K in juicefs_transaction_durations_histogram_seconds_total juicefs_fuse_ops_total_write; do
  PRE=$(awk -v k=$K '$1==k{print $2}'  <cell>/randwrite-<LABEL>-r1/jfs-stats-pre.txt)
  POST=$(awk -v k=$K '$1==k{print $2}' <cell>/randwrite-<LABEL>-r1/jfs-stats-post.txt)
  echo "$K pre=$PRE post=$POST"
done
```

任一键缺失、或 post−pre ≤ 0 ⇒ **STOP（S5）**。把这段输出落盘 `/tmp/production/counter-check-<LABEL>.txt`。

⚑ 旧二进制 `1f60618c` 的计数器名**可能与新版不同**。若 `juicefs_fuse_ops_total_write` 在 O 臂缺失：**不要 STOP**，改为落盘该 cell 的 `jfs-stats-*.txt` 全文 + `curl` 一次完整 metrics 端点（若 V4 已存则跳过），并在日志写明 `COUNTER_NAME_MISMATCH=O`，然后**继续跑完全部 4 个 cell**。这种情况本身就是 R21 要找的答案（口径不同），必须让 opencode 拿到全部键名去比对。

---

## 四、执行步骤

### 步 0 环境自检（约 5 min，全部落盘 `/tmp/production/env-check-t53.txt`）

1. `md5sum` 本任务书，与派发报文核对。
2. `md5sum /tmp/FULLBASELINE_V4.sh`，与 03-17f 记录一致（⛔ 不得修改一个字符）。
3. `md5sum /etc/ceph/ceph.conf` ⇒ 必须为 **`5b6be34179a64e0a5f9c6d3a9690041f`**；不符 ⇒ STOP（S7）。
4. `md5sum /tmp/juicefs-03-8 /tmp/juicefs-03-8-async-backup` ⇒ 必须为上表两值；不符 ⇒ STOP（S2）。
5. 建两个 shim 目录（§三.1）。
6. `df -h /` ⇒ 根分区可用 < 5 G ⇒ STOP（S11）。
7. `ceph -s` ⇒ 记录 HEALTH 与 PG；非 `active+clean` 或 HEALTH_ERR ⇒ STOP（S8）。
8. `rados df` 或 `ceph df detail` 记录数据池对象数（**预期 ≈ 2,434,615**）。
9. 确认无 JuiceFS 残留挂载：`mount | grep juicefs`；有则优雅卸载后再开工。
10. ⚑ `export CEPH_CONF=` **显式清空**（防止上批残留环境变量），并 `env | grep -i ceph` 落盘。

### 步 1 ~ 步 4：四个 cell，按 O1 → N1 → N2 → O2 顺序

对每个 cell，`<LABEL>` ∈ {`O1`, `N1`, `N2`, `O2`}，`<BIN>` = old/new：

```bash
export PATH=/tmp/t53-bin-<BIN>:$PATH
unset CEPH_CONF
# 1) 二进制意图证据（§三.1 四行）
# 2) 启动 V4：
ITEMS=randwrite \
OBJ_TARGET=2500000 OBJ_MAX=8000000 \
JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K" \
LABEL=<LABEL> \
bash /tmp/FULLBASELINE_V4.sh <LABEL> 180 1 --remount
# 3) 挂载后 30s 内：max_read 验证 + /proc/<pid>/exe 指纹（§三.2）
# 4) 跑完：计数器自检（§三.3）
```

每 cell 必做的三项落盘：

| 文件 | 内容 |
|---|---|
| `/tmp/production/binary-verify-<LABEL>.txt` | shim 四行 + `/proc/<pid>/exe` 三行 |
| `/tmp/production/mount-verify-<LABEL>.txt` | `grep -H max_read /proc/mounts`，必须含 `max_read=262144`；否则 STOP（S3） |
| `/tmp/production/counter-check-<LABEL>.txt` | §三.3 两个计数器的 pre/post |

⚑ **cell 之间不要跳过 V4 的 `aggressive_cleanup`**（写项后 8–12 min），这是保证下一 cell 起点对齐的唯一手段。

### 步 5 收尾

1. 再次 `md5sum /etc/ceph/ceph.conf` 与 `ceph -s`，落盘。
2. 记录数据池最终对象数。
3. 确认无挂载残留。
4. 打包（§六）。

---

## 五、⛔ 明确"不要做"的事

1. ⛔ 不改 `/tmp/FULLBASELINE_V4.sh`。
2. ⛔ 不注入私有 `ceph.conf`、不设 `CEPH_CONF`、不执行 `ceph config set`、不改 `/etc/ceph/ceph.conf`（B6）。
3. ⛔ 不动卷设置（`BlockSize` / `TrashDays` / `Compression`）。
4. ⛔ 不用 `/usr/local/bin/juicefs`。
5. ⛔ 不计算任何比值/百分比/均值（纪律 §〇.4）。
6. ⛔ 不因单轮带宽"看起来偏低/偏高"而重跑或加轮 —— 那是选择性剔除（R18）。
7. ⛔ 不删 `/tmp/opencode-fullbaseline-v4/`、`/tmp/production/` 下任何本批产物。

---

## 六、回传物

打包为 `/home/lilingfeng/tmp/production/opencode-t3.17g.tar.gz` + 同名 `.md5`，内含：

| 内容 | 路径 |
|---|---|
| V4 结果**整目录** | `/tmp/opencode-fullbaseline-v4/`（含 4 个 cell 的 `randwrite-<LABEL>-r1/` 全部文件，**`jfs-stats-pre.txt` / `jfs-stats-post.txt` / `fio.txt` 一个都不能少**） |
| 二进制指纹 | `/tmp/production/binary-verify-*.txt`（4 份） |
| 挂载验证 | `/tmp/production/mount-verify-*.txt`（4 份） |
| 计数器自检 | `/tmp/production/counter-check-*.txt`（4 份） |
| 环境自检 | `/tmp/production/env-check-t53.txt` |
| 运行日志 | V4 的 `test.log`、`rounds.tsv` + 你自己的 wrapper 日志 |
| 清单 | 包内根目录 `MANIFEST.md5`（对包内每个文件逐一 `md5sum`） |

回传报文里只写：4 个 cell 的 `rounds.tsv` 原文行、4 份 `binary-verify` 的 md5 行、包的 md5 与大小。⛔ 不写结论。

---

## 七、STOP 条件（穷举；只有这些才停机）

| # | 条件 | 动作 |
|---|---|---|
| S1 | 本任务书 md5 与派发报文不符 | 停手，回报两个 md5 |
| S2 | shim 解析到的二进制 md5 ≠ 本 cell 期望值，或 `/tmp/juicefs-03-8*` 两文件 md5 与 §三.1 不符 | STOP，回传 `binary-verify-*` |
| S3 | 挂载后 `/proc/mounts` 无 `max_read=262144` | STOP，回传 `mount-verify-*` |
| S4 | `/proc/<pid>/exe` 的 md5 ≠ 本 cell 期望二进制；或重试 3 次仍取不到挂载 pid | STOP，回传 `binary-verify-*` |
| S5 | `juicefs_transaction_durations_histogram_seconds_total` 缺失或增量 ≤ 0 | STOP，回传该 cell 全部 `jfs-stats-*` |
| S6 | 任一 cell randwrite BW **< 1500 MiB/s**（03-7L 崩塌形态，551 量级） | STOP，回传该 cell 全部原始文件 |
| S7 | `/etc/ceph/ceph.conf` md5 与 `5b6be34179a64e0a5f9c6d3a9690041f` 不符（起或止） | STOP |
| S8 | Ceph `HEALTH_ERR`，或 PG 出现非 `active+clean` 且 5 min 内未自愈 | STOP，回传 `ceph -s` |
| S9 | 挂载失败，或 `juicefs` 报元数据格式/版本不兼容（⚑ **O 臂旧二进制的特有风险**） | STOP，回传完整错误原文 |
| S10 | 数据池对象数 > `OBJ_MAX=8000000` | STOP |
| S11 | 根分区可用 < 5 G | STOP |
| S12 | `/tmp/FULLBASELINE_V4.sh` md5 与步 0 记录不符（运行中被改） | STOP |

### ⚑ 以下情况**明确不 STOP**，记录并续跑

1. **时钟漂移**：唯一告警、且为 clock skew、且 ≤ 0.5 s ⇒ 记录续跑；⛔ 禁 `ceph config set mon mon_clock_drift_allowed`。
2. `obj_gate` 报 `SOFT-PASS (ABOVE_START_MAX)` ⇒ 记录续跑（B4-24 已知）。
3. `gc --compact` 零回收 ⇒ 记录续跑（B4-24 已知）。
4. `hit_rate=0.0%` ⇒ randwrite 的正常值。
5. 单轮 BW 与历史 03-10/03-8 数值不同（只要 ≥1500）⇒ **这正是待测量，记录续跑**。
6. L2 极差判据 FAIL ⇒ 每臂只有 2 点，判据无意义，记录续跑。
7. O 臂计数器名与 N 臂不同 ⇒ 按 §三.3 末段处理，续跑。
8. V4 dry-run 阶段的假 ⚠️（B4-22 已知）⇒ 忽略。

---

## 八、分析方（opencode）判决预案 —— 执行方不必读

### 八.1 主判据：meta/写op

按 §一 公式对 4 个 cell 逐一复算，并与 03-17f 的 7 个 cell 合表。

| 情形 | O 臂（`1f60618c`） | N 臂（`de93563f`） | 判决 |
|---|---|---|---|
| ① | ≈ 0.91（≤0.94） | ≈ 0.99 | ✅ **F67 归因成立**：−11% 是 B-catchup 的确定代价 ⇒ 写入交付说明，03-17f §9.2 写侧三项按 2707/1570/4676 固化并附注此代价 |
| ② | ≈ 0.99（与 N 臂差 <3%） | ≈ 0.99 | ❌ **F67 归因推翻**：03-10 的 0.91 系计数器口径不同或已漂移 ⇒ 撤回 F67 的二进制归因，改查 03-10 原始数据里 0.91 的分子分母定义（R21 §①），写侧缺口另找 |
| ③ | O 臂显著 **高于** N 臂 | — | ⚠ 与 F67 反向 ⇒ 重查 `/proc/<pid>/exe` 指纹是否两臂搞反 |
| ④ | O 臂计数器名缺失 | — | ⇒ 直接证明 R21 §① 命中：0.91 与 0.989 本非同一量，F67 归因作废，按情形②处理 |

判据门槛：两臂**臂内极差 < 1.5%**（03-17f 实测该比值 7 cell 仅 0.979~0.991，极差 1.2%）时，臂间差 ≥ 5% 即可判显著；n=2/臂 对 8.7% 的待测效应足够。

### 八.2 副产物（同样有价值，⚑ 不额外花机器时间）

1. **03-10 randwrite 3018.5 的同日重锚**：O 臂 msgr=3 + 256K + 旧二进制 = 03-10 的完整口径。若 O 臂 BW ≈ 3018 ⇒ 8 天集群漂移可忽略，F67 的跨批比较合法；若 O 臂 BW ≈ 2660 ⇒ **是集群漂移而非二进制**，情形①②之外的第三种答案。⇒ 本项与 §八.1 交叉即可完全拆开"二进制 / 漂移"两因子。
2. **F44 模型第三次检验**：对 4 个 cell 各算 `meta率 ÷ (meta/写op) × 256KiB`，与实测 BW 比对（03-17f 中该模型逐 MiB 吻合）。
3. **PUT/写字节**：03-17f 测得 1.071~1.081，看旧二进制是否更低（若更低，则"slice 合并更好"的机理进一步闭合）。
4. **B4-24 复核**：本批无 mseqwrite，对象数应全程 ≈2.43M；若仍膨胀，说明 gc 零回收与 mseqwrite 无关，缺陷定位前移。

### 八.3 落地文档

- 结论写入 `doc/perf-report/03-17g-…-20260822.md`
- 主计划：更新 **F67**（把"跨批单点比较"的自限解除或撤回归因）、§2.4d 交付基座写侧数值、§9.2 对应的写侧固化状态、§11.1 台账、路线图；若情形② 则新增一条 A39（F67 归因撤回）
