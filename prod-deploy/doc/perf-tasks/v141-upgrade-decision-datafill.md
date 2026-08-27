# 任务书（不占编号）：patched v1.3.1 → patched v1.4.1 升级必要性判定数据补齐

> 本任务书不占用 03-xx 编号，不进入主计划阶段台账，只作为一次性升级决策的数据补齐。
> 结论只回答一个问题：**有没有必要把 patched v1.3.1 换成 patched v1.4.1。**

## 计划线

```
[已完成] 08-24 批（T141/T141b/T141c/T141d/T141p）— 已复核，数据本身准确，但对照列整列错误
[已完成] opencode 复算 — 已确认 patched v1.4.1 randwrite 落在 patched v1.3.1 的写侧流形上（±1σ）
[本任务]  U141 一夜 ABBA 四项配对 — 补齐唯一能决定升级与否的数据
   └── 必须排在 03-19 之前执行（03-19 会永久改写 rw_test，randrw 1870 参照点将永久失去）
[之后]   03-19 randwrite 活跃 inode 128 vs 256
[之后]   B1 TiKV 服务端逐 op 延迟采集
```

- 执行方：GLM，**全自动跑完，中途不得暂停提问**。
- 窗口：157 本地 **20:00 起**，预计 **5.2 h**（20:00 → 约 01:10）。
- 授权范围：只读集群配置、只挂/卸 JuiceFS、只跑 fio。⛔ 不改 `/etc/ceph/ceph.conf`，⛔ 不 `ceph config set`，⛔ 不改 `/tmp/FULLBASELINE_V4.sh`。

---

## 〇、任务边界与结论边界

**本任务能给出的结论**：patched v1.4.1 在 randread / randrw / randwrite / mseqwrite 四项上，相对 patched v1.3.1 是否**非劣**。

**本任务不能给出的结论**：
1. 不判定 patched v1.4.1 是否**更优**（见 §一，本任务按非劣性设计，不是优越性设计）。
2. 不判定 v1.4.0/v1.4.1 的功能、稳定性、社区支持等非性能因素 —— 这些不在性能测试能回答的范围内。
3. 不重复验证 B-catchup 补丁的必要性。该结论已由 08-24 同日 A/B（551→2724，间隔 1.5 h、同 layout、CV 0.10%）加 03-7L 的独立同值 551 确证，**⛔ 本任务不再复测 551**。
4. 不判定 loadRange 补丁的作用。patched v1.4.1 只带 B-catchup，不带 loadRange；本任务把「patched v1.4.1 = 现有 1.4.1 补丁版本」作为整体待测对象，不做补丁级分解。

---

## 一、决策问题的形式化：非劣性，不是优越性

升级动机不是「1.4.1 更快」。08-24 批已显示读侧最大正向变化仅 +2.6%（且该项 92.8–100% 是 buffer 命中，不是文件系统性能）。因此：

> **升级只在「性能不退步」的前提下才可考虑；一旦任一项退步超过边界，升级即被否决。**

这决定了三件事：

1. **判据是单侧非劣性检验**，不是双侧差异检验。零假设 = 「退步不小于边界」，需要用数据推翻它。
2. **不需要证明 Δ > 0**。Δ ≈ 0 就是通过。若四项全部非劣，正确结论是「**性能上没有升级的必要性，也没有升级的障碍；是否升级应由非性能理由决定**」，⛔ 不得写成「1.4.1 更优，建议升级」。
3. **预登记边界**（执行前写死，禁止事后调整，A39）：

| 项 | 非劣边界 | 依据 |
|---|---|---|
| randread | −3% | 交付头条项，03-17f 5544 = 目标 88.7%，任何退步直接吃掉交付水位 |
| randrw | −3% | 08-24 观测到 −6.8%，两批 CV 均 ≤2%，边界须小于观测效应 |
| randwrite | 流形残差差 ±74.8 MiB/s | 见 §九 3；原始带宽受双态支配（CV 12.94%）不可直接判 |
| mseqwrite | −5% | CV 最大项，边界放宽；⚑ 见 §九 4 功效不足声明 |

---

## 二、为什么只测四项

⑤「尽量少重测」。三项**明确排除**，GLM ⛔ 不得自行加回：

| 排除项 | 08-24 实测 | 真实 03-17f | Δ | 排除理由 |
|---|---:|---:|---:|---|
| seqwrite | 1570 | 1570 | **0.0%** | 两批独立落在同一个数上，各自 CV 0.69%/1.03%，无信息量 |
| seqread | 1441 | 1449 | −0.6% | Δ 小于两批 CV（0.50%/1.20%）之和，且 hit_rate 已升至 100% |
| mseqread | 5505 | 5366 | +2.6% | hit_rate 93.5/99.7/100% ⇒ 测的是内存带宽而非 JuiceFS，对升级决策无判别力 |

四项**必测**：

| 必测项 | 08-24 | 真实 03-17f | Δ | 必测理由 |
|---|---:|---:|---:|---|
| randrw | 1743 | 1870 | **−6.8%** | 唯一超噪声的退步信号；两批 CV 2.04%/0.28%，Δ 是 CV 的 3–24 倍 |
| randwrite | 2724（补丁版） | 2707 | +0.6% | B-catchup 主战场；需确认流形等价不是单跑巧合 |
| randread | 5616 | 5544 | +1.3% | 交付头条项，必须确认无退步；同时充当每 block 的批次漂移锚点 |
| mseqwrite | 4548 中位 / 4720 均值 | 4676 | −2.7% 中位 / +0.3% 均值 | 结论对统计量选择敏感（r3=5071 为 +11.6% 离群），须提高 n |

---

## 三、固定环境与不变量

以下全部已在 2026-08-24 13:2x 由 opencode 实测核对，GLM 在批首必须逐项复验并落盘。

| 项 | 冻结值 |
|---|---|
| A 臂二进制（patched v1.3.1，现生产） | `/tmp/juicefs-03-8`，md5 **`de93563f11a5ff3bd94dd25a4e0283b1`**，version `1.3.1+2025-12-02.e0032b2a` |
| B 臂二进制（patched v1.4.1，待测） | `/tmp/juicefs-1.4.1-patched`，md5 **`24fae0852051c80ca571cb2f20275d46`**，version `1.4.1+unknown` |
| A 臂 PATH shim | `/tmp/t53-bin-new/juicefs` → `/tmp/juicefs-03-8` |
| B 臂 PATH shim | `/tmp/t141p-bin/juicefs` → `/tmp/juicefs-1.4.1-patched` |
| 客户端私有 conf | `CEPH_CONF=/tmp/t141-msgr8.conf`，md5 **`86351c58848c7e4caaa1bbeccb211730`**，内含 `[client] ms_async_op_threads = 8` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| 系统 ceph.conf | md5 **`5b6be34179a64e0a5f9c6d3a9690041f`**，⛔ 禁改 |
| `ceph config dump` | md5 **`fd4551893fc7f0868369551e27b64e5c`**，⛔ 禁改 |
| V4 脚本 | `/tmp/FULLBASELINE_V4.sh`，md5 **`4198ea2676ba56744a3cd5eba17a5eab`**，1368 行，⛔ 禁改一个字符 |
| 池起点 | `juicefs-data`，objects ≈ 2.43M，stored ≈ 595 GiB |
| 文件资产 | `/mnt/juicefs/test_dir/` 下 `storage_test.*.0` / `read_test.*.0` / `rw_test.*.0` **各 128 个 × 恰 1073741824 字节** |
| 集群 | Ceph 17.2.8 quincy，EC 4+2，6 OSD，数据池 32 PG，主 PG 恒 `[0:6 1:6 2:5 3:6 4:5 5:4]` |
| fio | 3.28 |
| 根分区 | 起点余量 20 G |

### 3.1 ⛔ 禁止新建二进制、禁止重新编译

两个二进制都已就位并经 `/proc/<pid>/exe` 验证过。GLM ⛔ 不得 `go build`、⛔ 不得下载源码、⛔ 不得动 `/usr/local/bin/juicefs`（该文件 md5 `bdd182cf2cd43be657cb4ec0b5a6a048` 是**错版本**，只能靠 PATH shim 绕开，绝不能覆盖它）。

### 3.2 写历史已对等，不需要弃用预热臂

`rw_test.*.0` 全 128 个文件 mtime = `2026-08-24 08:43`（T141 randrw r3 覆盖写），`storage_test.0.0` mtime = `2026-08-24 12:56`。两套文件都已有当日写历史，不存在 03-19 面对的「处女文件」问题 ⇒ **本任务不设弃用预热臂**，节省 29 min。残余顺序效应由 §四 的 ABBA 抵消。

---

## 四、ABBA 区组设计

跨日漂移是本任务的头号敌人：F68 已实测**同一个二进制**跨日漂移 **−14.27%**（03-17g O 臂 2587.5 vs 03-10 均值 3018.25），而待判效应量级只有 1%。⇒ **任何跨日比较一律无效**，必须同夜配对。

### 4.1 四个 block，ABBA

| block | LABEL | 臂 | 二进制 | PATH shim |
|---|---|---|---|---|
| 1 | `UP1A` | A | `de93563f`（patched v1.3.1） | `/tmp/t53-bin-new` |
| 2 | `UP2B` | B | `24fae085`（patched v1.4.1） | `/tmp/t141p-bin` |
| 3 | `UP3B` | B | `24fae085` | `/tmp/t141p-bin` |
| 4 | `UP4A` | A | `de93563f` | `/tmp/t53-bin-new` |

ABBA 的作用：A 臂两个 block 的时间重心 =(t₁+t₄)/2，B 臂 =(t₂+t₃)/2，在 block 等长时两者相等 ⇒ **线性漂移对 A−B 对比的贡献为零**。这是本设计不可替换的核心，⛔ 不得改成 AABB、不得删减 block。

### 4.2 每 block 内的项顺序（四个 block 完全相同）

```
ITEMS="randread randrw randwrite mseqwrite"    REPEAT=2   RUNTIME=180
```

- 顺序在四个 block 中完全一致 ⇒ 项间顺序效应为共模，在 A−B 对比中抵消。
- 读项在前（V4 原生顺序，`:1351` 注释），挂载后缓存状态干净。
- **`mseqwrite` 故意排在最后**：它是四项里优先级最低、耗时最长的。若夜间超时被截断，损失的是 mseqwrite 的一个 block，而 randread/randrw/randwrite 的 ABBA 完整性不受影响。⇒ **mseqwrite 数据允许不完整，GLM 不得为了补它而延长或重跑。**

### 4.3 每臂样本量

每项每臂 n = 2 block × 2 round = **4**。randwrite 另按 §九 3 用流形残差聚合。

### 4.4 时间预算（按 08-24 test.log 实测节拍推算）

| 段 | 时长 |
|---|---|
| 挂载 + gc --compact + remount + deterministic_warmup（418 文件）+ compact | 12.3 min |
| randread × 2 轮（无 aggressive_cleanup） | 8 min |
| randrw × 2 轮（每轮 fio 3 min + aggressive_cleanup 4.6 min + obj_gate） | 17 min |
| randwrite × 2 轮 | 17 min |
| mseqwrite × 2 轮 | 15 min |
| **单 block** | **≈ 70 min** |
| 4 block | 280 min |
| 批首核验 + 批尾归档 | 30 min |
| **合计** | **≈ 5.2 h** |

---

## 五、V4 调用规格

### 5.1 ★ 必须设 `OBJ_GATE=1`：这同时修掉 08-24 批的 rc=1 与证据缺口

08-24 批被迫拆成 5 次调用，真因已定位：

`item_randrw`(`:918`)、`item_seqwrite`(`:929`)、`item_mseqwrite`(`:940`)、`item_randwrite`(`:953`) 四处，每轮循环体的**最后一条语句**是

```bash
[ "${OBJ_GATE}" = "1" ] && obj_gate "<item>" "$r"
```

当 `OBJ_GATE=0`（默认）时，`[ ... ]` 判否 ⇒ 整个 `&&` 列表退出码 = 1。循环内因 bash 对「`&&` 列表中非末条命令失败」的 `set -e` 豁免而不会中途退出，但**函数返回值为 1**，回到 `:1352` 的 `for _item` / `case` 调用点时 `set -e` 触发 ⇒ 脚本在最后一轮 `aggressive_cleanup` 结束后、`summary()` 之前退出，rc=1。这与 08-24 test.log 的截断位置逐行吻合（日志末尾停在 `gc --compact done`，无 `=== 汇总 ===`）。

⇒ **设 `OBJ_GATE=1` 后 `obj_gate` 实际执行并在正常路径 `return 0`（`:641-643`），rc=1 消失。** 且当前池对象数 2.43M ≤ `OBJ_TARGET` 默认 2500000，闸门会立即 OK 返回、不触发额外 gc ⇒ **零时间成本**。同时补上 08-24 批完全缺失的对象数起点/终点证据（B4 族）。

一举三得。⛔ 不得用 `set +e`、`|| true`、拆分调用等方式绕过 —— 那些做法会把真实 STOP 也一起吞掉。

### 5.2 每 block 的调用形式

```bash
ARM_BIN_DIR=<A: /tmp/t53-bin-new | B: /tmp/t141p-bin>
LBL=<UP1A|UP2B|UP3B|UP4A>

env PATH="${ARM_BIN_DIR}:${PATH}" \
    CEPH_CONF=/tmp/t141-msgr8.conf \
    ITEMS="randread randrw randwrite mseqwrite" \
    OBJ_GATE=1 \
    OBJ_TARGET=2500000 \
    OBJ_GC_PASSES=2 \
    OBJ_MAX=8000000 \
    JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K" \
    bash /tmp/FULLBASELINE_V4.sh "${LBL}" 180 2
```

### 5.3 V4 口径硬约束（GLM 必须遵守，不得试图绕过）

| 约束 | 位置 | 说明 |
|---|---|---|
| `RUNTIME` / `REPEAT` **只认位置参数** `$2`/`$3` | `:40-41` | ⛔ 不是环境变量，`RUNTIME=180 bash ...` 无效 |
| `RESULTS` 硬编码 `/tmp/opencode-fullbaseline-v4` | `:33` | 非 `${VAR:-}` 形式 ⇒ **不可环境覆盖**，见 §5.4 |
| `LAYOUT_JOBS=128` 硬编码 | `:47` | 不可覆盖；randrw/randwrite 的 `numjobs`/`openfiles` 由它决定 |
| `SKIP_REMOUNT` 保持默认 0 | `:82` | 换二进制必须 remount，⛔ 不得设 1 |
| 每次调用只 remount 一次 | `mount_jfs :698-713` | 已挂载则跳过 ⇒ block 之间必须先卸载，见 §六 |
| ⛔ 不加 `--layout` | `phase0_layout :817-841` | 会重建 128×1G 文件、毁掉写历史对等 |
| ⛔ 不加 `--remount` / `--allow-restart` | `:1240` | |
| 不设 `REF_LABEL` | `:94` | 跨 block 换实例，L3 判据本就无效（`:1045`） |

### 5.4 ★ 批首必须先把现有 RESULTS 目录整体挪走并留存

`RESULTS` 不可覆盖，本次会写进同一个目录。而 **`/tmp/opencode-fullbaseline-v4/rounds.tsv` 与 `test.log` 是 08-24 T141d（551 MiB/s）唯一存活的证据**（`T141d/` 轮目录已丢失）。

批首第一步（在任何测试之前）：

```bash
sudo umount -l /mnt/juicefs 2>/dev/null; /tmp/t53-bin-new/juicefs umount --flush /mnt/juicefs 2>/dev/null || true
cp -a /tmp/opencode-fullbaseline-v4 /tmp/opencode-fullbaseline-v4.pre-u141-$(date +%Y%m%d-%H%M%S)
tar czf ~/tmp/production/opencode-t141-preserve.tar.gz -C /tmp opencode-fullbaseline-v4.pre-u141-*
md5sum ~/tmp/production/opencode-t141-preserve.tar.gz
```

⛔ 不得 `rm -rf /tmp/opencode-fullbaseline-v4`（会丢 T141 系列）；只做副本 + 打包，原目录留在原地续写。

---

## 六、每个 block 的固定执行步骤

对 block = 1..4，严格按序：

1. **卸载**：若 `/mnt/juicefs` 已挂载 → `<本 block 的 shim>/juicefs umount --flush /mnt/juicefs`；等 10 s；`mount | grep -q juice` 必须为假。⚑ block 1 需卸掉遗留的 T141p 挂载（pid 1126354/1126400，`/tmp/juicefs-1.4.1-patched`）。
2. **不变量门**：复验 §三 全表（两个二进制 md5、两个 shim 的 `readlink`、`/tmp/t141-msgr8.conf` md5、`/etc/ceph/ceph.conf` md5、`ceph config dump` md5、V4 md5）→ 落盘 `invariants-<LBL>.txt`。任一不符 → STOP。
3. **文件资产门（修 B4-26）**：三套文件各自计数必须 = 128，且每个文件 `stat -c %s` 必须 = 1073741824。落盘 `filecount-<LBL>.tsv`（含每文件 size + mtime）。不符 → STOP。
   > V4 自带的 layout 门禁（`:1318-1320`）只检查 `storage_test.0.0` 是否存在，不查文件数、不查大小，不足以保证口径 ⇒ 本步骤在 V4 之外补做。
4. **调用 V4**：按 §5.2。
5. **挂载指纹（修 R20 缺口）**：V4 挂载完成后（`jfs-instance-<LBL>.txt` 出现即可取 pid），对挂载 pid 采集并落盘 `mountproc-<LBL>.txt`：
   - `readlink /proc/<pid>/exe` → 必须等于本 block 期望的二进制路径
   - `md5sum $(readlink /proc/<pid>/exe)` → 必须等于期望 md5
   - `tr '\0' '\n' < /proc/<pid>/environ | grep -E '^(CEPH_CONF|PATH)='` → `CEPH_CONF` 必须 = `/tmp/t141-msgr8.conf`
   - `for t in /proc/<pid>/task/*; do cat $t/comm; done | grep -c '^msgr-worker-'` → **必须 = 8**
   - `mount | grep juicefs` → 必须含 `max_read=262144`
   - 任一不符 → STOP
   > 该采集必须在 fio 期间进行（进程存活时）。08-24 批完全没做这一步；opencode 事后只是因为 T141p 挂载恰好没被卸载才补验成功，属侥幸，不可重演。
6. **block 结束后立即归档**：`tar czf ~/tmp/production/u141-<LBL>.tar.gz -C /tmp/opencode-fullbaseline-v4 <LBL> rounds.tsv test.log obj-gate-<LBL>.tsv ...` 并 `md5sum`。⛔ 不得只在批尾打一次包 —— 08-24 的 `T141d/` 就是这样整目录丢失的。
7. **轮目录完整性门**：`<LBL>/` 下必须存在 8 个轮目录（randread r1-r2、randrw r1-r2、randwrite r1-r2、mseqwrite r1-r2；mseqwrite 允许缺，见 §4.2），每个目录内 `fio.txt` 非空。缺失 → STOP。

---

## 七、每轮必须落盘的证据

针对 08-24 批复核出的 8 个证据缺口，逐条封堵：

| # | 08-24 缺口 | 本任务的封堵手段 | 责任步骤 |
|---|---|---|---|
| 1 | `T141d/` 整目录丢失，551 的 fio.txt / meta 计数器 / pg-map 全无 | 每 block 结束立即打包 + 轮目录完整性门 | §六 6/7 |
| 2 | 全批零条 `obj_gate`，对象数起点/终点无记录 | `OBJ_GATE=1`，生成 `obj-gate-<LBL>.tsv` | §5.1 |
| 3 | msgr=8 / CEPH_CONF 无任何直接证据 | 按 pid 采 `environ` + 数 `msgr-worker-*` 线程 | §六 5 |
| 4 | 二进制身份只能靠 shim mtime 反推 | 按 pid 采 `/proc/<pid>/exe` + md5 | §六 5 |
| 5 | 报告 md5 被截成 `58f4406e...` | 所有 md5 一律落全 32 位 | §六 2 |
| 6 | 缓存命中未与带宽同报 | V4 已写 `hit-rate.txt`；GLM 须汇总进 §7.1 的 TSV | §7.1 |
| 7 | layout 只验存在、不验文件数与大小 | 文件资产门 | §六 3 |
| 8 | meta 计数器只有 T141p 有 | 每轮验 `jfs-stats-pre/post.txt` 非空且含目标计数器 | §7.2 |

### 7.1 ★ 汇总 TSV（GLM 只采集，不做统计判决）

⑧「一切统计由 opencode 从原始数据算」。GLM 生成 `/tmp/opencode-fullbaseline-v4/u141-cells.tsv`，**只做计数器差分与除法，不做任何均值/相关/回归/判决**：

列（制表符分隔，表头一行）：

```
block  label  arm  binary_md5  item  round  bw_mibs  hit_rate  \
d_meta_ops_Write  d_meta_dur_Write_s  d_fuse_ops_write  d_txn_total  \
obj_post  stored_post  pg_primary  fio_rc  mount_pid  msgr_workers
```

计数器口径**必须逐字照用**（R19：同口径须列文件:行号，以下取自 `jfs-stats-pre.txt` / `jfs-stats-post.txt`）：

- `d_meta_ops_Write` = Δ `juicefs_meta_ops_total_Write`
- `d_meta_dur_Write_s` = Δ `juicefs_meta_ops_duration_seconds_Write`
- `d_fuse_ops_write` = Δ `juicefs_fuse_ops_total_write`
- `d_txn_total` = Δ `juicefs_transaction_durations_histogram_seconds_total`

⛔ GLM 不得自行计算 `meta 延迟`、`meta/写op`、`在飞 meta`、任何比值或百分比。⛔ 特别禁止计算 `BW×lat/inode` 型判据 —— 该式与 `在飞 meta ≡ 4 × BW × 延迟 × (meta/写op)` 恒等（15 cell 最大误差 0.017%），是自证循环（A39 §④）。

### 7.2 首轮 pre 计数器为空是正常的，不是 STOP

新挂载后第一个写轮之前，`juicefs_meta_ops_total_Write` 等计数器**尚未出现**在 metrics 里（T141p r1 实测如此）。此时按 **pre = 0** 处理，差分仍然干净（T141p r1 已验证：`Δfuse_write` 与 BW 之比 = 1.229，与 r2 的 1.229 逐位吻合）。

⇒ 判定规则：
- `post` 文件缺失 / 为空 / 不含目标计数器 → **STOP**
- `pre` 文件缺失或不含目标计数器，**且该轮是本挂载的第一个写轮** → 记 pre=0，在 TSV 的 `round` 列标 `r1*`，**不 STOP**
- 其他情况的 `pre` 缺失 → **STOP**

---

## 八、有效性门（批次级，全部由 opencode 事后判；GLM 只需保证证据齐全）

| 门 | 内容 | 不满足时的后果 |
|---|---|---|
| G1 | 四个 block 的不变量表全部一致（§三） | 整批作废 |
| G2 | 每 block `msgr_workers` = 8、`max_read=262144`、`/proc/exe` 与臂匹配 | 该 block 作废 |
| G3 | 三套文件在每 block 批首均为 128 个 × 1073741824 字节 | 该 block 作废 |
| G4 | randwrite 的 `meta/写op`（= `d_meta_ops_Write ÷ d_fuse_ops_write`）：r2 轮须落 **0.9131 ± 0.005**；r1* 轮放宽到 **0.900 – 0.920** | 该 cell 不进流形分析 |
| G5 | 每 block 起点 objects ≤ 3,110,000；全程 ≤ `OBJ_MAX` 8,000,000 | 该 block 标注，降级为参考 |
| G6 | 主 PG 全程 `[0:6 1:6 2:5 3:6 4:5 5:4]`、nonclean = 0 | 该轮作废 |
| G7 | A 臂 randread 四个 cell 均 > 4239 MiB/s（F65 的 msgr=3 天花板） | msgr=8 未生效，整批作废 |
| G8 | A 臂 randwrite 四个 cell 对 §九 3 流形的残差均在 ±2σ（±106）内 | 流形在本夜不成立，randwrite 降级为原始带宽比较（功效不足，标"不可判"） |

G4 的 0.9131 ± 0.0016 来自 15 个 256K randwrite cell（跨 2 二进制、2 msgr 配置、相隔 8 天两批），CV 0.179%；此处放宽到 ±0.005 是给跨版本留余量。

---

## 九、分析与判决预案（预登记；执行方不计算）

以下全部由 opencode 在收到原始包后计算。**预先写死，禁止事后调整**（A39）。

### 9.1 漂移检查（先做，做完才允许看主判据）

用每 block 的 randread 四个 cell 作批次锚点，对 block 序号做线性回归。若斜率显著（|斜率| × 3 block > 3% 锚点均值），则所有主判据必须先做漂移校正后再判；ABBA 已使一阶漂移对 A−B 对比归零，此步只用于确认没有二阶/突变漂移。

### 9.2 randread 与 randrw（主路径：单侧非劣性）

对每项，A 臂 4 cell、B 臂 4 cell：

```
Δ%       = (mean_B − mean_A) / mean_A × 100
sem_diff = sqrt(var_A/4 + var_B/4)
下界     = Δ% − 1.645 × sem_diff%        (单侧 95%)
```

- 下界 > −3% → **非劣**
- 上界 < −3%（即 Δ% + 1.645×sem_diff% < −3%）→ **确证退步，升级否决**
- 两者之间 → **不可判**，需专项加测（⛔ 本任务不自动加测）

预期：若 08-24 的 randrw −6.8% 是真实回退，本设计的 randrw `sem_diff` ≈ 1.4%，效应/噪声 ≈ 4.9 ⇒ 可确证。

### 9.3 randwrite（主判据 = 流形残差，不是原始带宽）

原始带宽被双态支配：T141p 三轮 3348/2724/2669，CV **12.94%**，n=4 时 sem ≈ 6.5% ⇒ **原始带宽无法分辨 1% 级效应，⛔ 不得作为主判据**。

改用 128-inode 参考流形（15 个 256K cell 拟合，r=0.9541、R²=0.9104、残差 sd = **52.9** MiB/s）：

```
lat_ms   = d_meta_dur_Write_s / d_meta_ops_Write × 1000
BW_pred  = 1753.6 + 171.5 × (1000 / lat_ms)
resid    = bw_mibs − BW_pred
```

判据：

```
Δresid   = mean_resid(B) − mean_resid(A)
sem      = 52.9 / sqrt(4) × sqrt(2) = 37.4 MiB/s
等价带   = ±2 × 37.4 = ±74.8 MiB/s   (≈ ±2.8%)
```

- |Δresid| ≤ 74.8 → **写路径等价**（两个版本在同一条流形上，带宽差异全部由 meta Write 延迟双态解释，与版本无关）
- Δresid ≤ −74.8 → 写路径退步，升级否决
- Δresid ≥ +74.8 → 写路径确有改善（意外结果，须先复核 G4 再采信）

先验：opencode 已用 T141p 的 meta 计数器算出 patched v1.4.1 三轮残差：

| 轮 | BW | lat_ms | meta/写op | BW_pred | resid | resid/52.9 |
|---|---:|---:|---:|---:|---:|---:|
| r1* | 3348 | 116.94 | 0.9070 | 3220.2 | +127.8 | +2.42σ |
| r2 | 2724 | 172.60 | 0.9129 | 2747.2 | −23.2 | −0.44σ |
| r3 | 2669 | 177.19 | 0.9131 | 2721.5 | −52.5 | −0.99σ |

r2/r3 的 `meta/写op` 精确落在 patched v1.3.1 的 0.9131 门内，残差在 1σ 内 ⇒ **预期结论是「等价」**。本项的价值是把这个单跑结论升级为同夜配对确证，⛔ 不是去找收益。

同时必须报告：A、B 两臂各 4 cell 的 `lat_ms`，并标注每 cell 属快态（≈110–140 ms）还是慢态（≈170–200 ms）。若某臂 4 cell 恰好全落一态而另一臂不是，则该次对比标注「态失衡」，Δresid 判据仍有效（流形已吸收态效应），但原始带宽比较作废。

### 9.4 mseqwrite（⚑ 预先声明功效不足）

以 CV 4.5% 规划（03-17f 2.36% 与 T141c 6.43% 之间），n=4 时 `sem_diff` ≈ 3.2%。在 −5% 非劣边界下，只有 Δ% > +10 才能宣告非劣 ⇒ **本项在 n=4 下几乎不可能宣告非劣性**。

⇒ 预登记处理：mseqwrite **只报点估计 + 90% 双侧 CI + 是否包含 0**，一律标「**功效不足，不可判**」，除非出现 `上界 < −5%`（此时可以单方向确证退步）。

⇒ **若最终升级决策卡在 mseqwrite 上**，需要一次专项测（估算 n ≥ 12/臂），届时另立任务书。⛔ 本任务不自动追加。

### 9.5 综合判决表

| randread | randrw | randwrite | 结论 |
|---|---|---|---|
| 非劣 | 非劣 | 等价 | **性能上无升级必要性，也无升级障碍**；是否升级由非性能理由（社区支持/bugfix/功能）决定。⛔ 不得表述为「1.4.1 更优，建议升级」 |
| 任一确证退步 | | | **升级否决**；并对该项做版本级归因（另立任务书） |
| 任一不可判 | | | **升级悬置**；列出需要的最小加测量 |

---

## 十、STOP 条件

STOP = **GLM 自行终止本 block、卸载、打包、把已完成部分回传，然后继续下一个 block（若不变量类 STOP 则终止整批）**。⛔ STOP 不等于向用户提问 —— 本任务全程不得暂停提问。

| # | 条件 | 范围 |
|---|---|---|
| S1 | `ceph health` ≠ `HEALTH_OK` | 整批 |
| S2 | OSD up ≠ 6 | 整批 |
| S3 | PG nonclean ≠ 0 或主 PG 落位 ≠ `[0:6 1:6 2:5 3:6 4:5 5:4]` | 整批 |
| S4 | `/etc/ceph/ceph.conf` md5 ≠ `5b6be34179a64e0a5f9c6d3a9690041f` | 整批 |
| S5 | `ceph config dump` md5 ≠ `fd4551893fc7f0868369551e27b64e5c` | 整批 |
| S6 | `/tmp/FULLBASELINE_V4.sh` md5 ≠ `4198ea2676ba56744a3cd5eba17a5eab` | 整批 |
| S7 | `/tmp/t141-msgr8.conf` md5 ≠ `86351c58848c7e4caaa1bbeccb211730` | 整批 |
| S8 | 任一臂二进制 md5 与 §三 不符，或 shim `readlink` 指错 | 整批 |
| S9 | `/proc/<mount_pid>/exe` ≠ 本 block 期望二进制 | 本 block |
| S10 | `msgr-worker-*` 线程数 ≠ 8 | 本 block |
| S11 | `CEPH_CONF` 未出现在挂载进程 environ 中 | 本 block |
| S12 | `mount` 输出不含 `max_read=262144` | 本 block |
| S13 | 三套文件任一计数 ≠ 128，或任一文件大小 ≠ 1073741824 | 整批 |
| S14 | 根分区余量 < 15 G | 整批 |
| S15 | block 起点 objects > 3,110,000 | 本 block |
| S16 | 任一轮 objects > 8,000,000（V4 自身 `OBJ_MAX_EXCEEDED` 会触发） | 整批 |
| S17 | 任一轮 fio rc ≠ 0 | 本轮，本 block 续跑 |
| S18 | 任一轮 `jfs-stats-post.txt` 缺失/为空/不含 `juicefs_meta_ops_total_Write` | 本轮，本 block 续跑 |
| S19 | 非首写轮的 `jfs-stats-pre.txt` 缺失或不含目标计数器 | 本轮，本 block 续跑 |
| S20 | block 结束后轮目录数 < 6（randread/randrw/randwrite 六个必须齐） | 本 block 重跑一次，仅一次 |
| S21 | 任一 randread cell < 4239 MiB/s | 整批（msgr 未生效） |
| S22 | B 臂任一 randwrite cell 落在 [450, 750] MiB/s | 整批（B-catchup 失效，二进制身份存疑） |
| S23 | 单 block 墙钟 > 110 min | 本 block 完成当前项后收尾，跳到下一 block |
| S24 | 累计墙钟 > 6.5 h | 收尾归档，剩余 block 不再跑 |

### 明确**不 STOP**（记录并续跑）

1. randwrite 轮间极差达 25%（双态，F68 已定为常态，T141p 实测 3348→2669 = 25.4%）。
2. mseqwrite CV 达 10%，或出现单轮 +12% 离群（T141c r3=5071 已有先例）。
3. V4 自身的 L2（轮间极差 ≤5%）/ L3（跨运行 median 偏差 ≤5%）判 FAIL —— 跨 block 换挂载实例，L3 本就无效（`:1045`，R1 实测跨实例极差 29.9%）。
4. 读项 `hit_rate` 升到 100%（seqread/mseqread 已排除；randread/randrw 的 hit_rate 记录即可）。
5. 首个写轮 `jfs-stats-pre.txt` 不含 meta 计数器（§7.2 已定为正常）。
6. `obj_gate` 需要走 1–2 遍 gc 才降到 `OBJ_TARGET`（走完即通过；`SOFT-PASS` 也算通过）。
7. 写轮期间池内 objects 上涨到 4.2M 量级（03-17f A 臂实测 4.13/4.21/2.74M，对 randwrite 带宽影响 ≤3%）。
8. `drop_caches` 报「2/3 或 1/3 节点成功」。
9. randread 与 03-17f 的 5544 相差 ±10% 以内。
10. mseqwrite 完全没跑到（§4.2 已授权牺牲）。
11. `compact 超时` 警告。
12. `up_from 变了` 警告（V4 `summary()` 的三元守卫里只有 UUID / CRUSH 变化才是致命）。

---

## 十一、批首、批尾与回传物

### 11.1 批首（20:00 起，约 15 min）

1. §5.4 的 RESULTS 目录留存 + 打包（**必须先做**）。
2. 卸掉遗留的 T141p 挂载。
3. §三 全表不变量核验 → `invariants-batch-head.txt`（全 32 位 md5）。
4. `nproc`、`free -g`、`uptime`、`df -h /`、`date` → `hostenv-head.txt`。
5. 确认无其他用户负载：`ps -eo pcpu,pid,comm --sort=-pcpu | head -15`，若存在非本任务的 >50% CPU 进程 → 等 10 min 复查，仍在则记录并续跑（不 STOP）。

### 11.2 批尾（约 15 min）

1. 卸载 JuiceFS（`juicefs umount --flush`），确认 `mount | grep juice` 为空。
2. 复采 §三 全表 → `invariants-batch-tail.txt`，与批首逐行对比，差异写入 `invariants-diff.txt`。
3. 复采池状态：objects / stored → `pool-tail.txt`。⚑ 期望回到 ≈2.43M / ≈595 GiB。
4. 生成 `u141-cells.tsv`（§7.1）。
5. 打总包。

### 11.3 回传物

```
~/tmp/production/opencode-u141.tar.gz
```

必须包含：

| 内容 | 说明 |
|---|---|
| `UP1A/` `UP2B/` `UP3B/` `UP4A/` | 全部轮目录，含 `fio.txt`、`jfs-stats-pre.txt`、`jfs-stats-post.txt`、`hit-rate.txt`、`pg-map.txt`、`pg-summary.txt`、`mount-cmd.txt`、`config-md5.txt`、`c_amp.txt`、`nic.txt` |
| `rounds.tsv`、`test.log` | V4 原生 |
| `obj-gate-UP*.tsv`、`obj-unaligned-UP*.tsv`（若有） | 对象闸门 |
| `invariants-UP*.txt`、`invariants-batch-{head,tail}.txt`、`invariants-diff.txt` | 不变量 |
| `filecount-UP*.tsv` | 文件资产门（含每文件 size + mtime） |
| `mountproc-UP*.txt` | 按 pid 的二进制/CEPH_CONF/msgr 线程/max_read 指纹 |
| `jfs-instance-UP*.txt`、`jfs-placement-UP*.txt`、`cache-config-check-UP*.txt` | V4 原生 |
| `u141-cells.tsv` | 汇总 TSV |
| `hostenv-head.txt`、`pool-tail.txt` | 主机与池状态 |
| `STOPS.md` | 每条触发的 STOP：编号、时间、现场值、期望值、采取的动作 |

另外单独回传 §5.4 生成的 `~/tmp/production/opencode-t141-preserve.tar.gz`（T141 系列留存包）。

**回传时必须给出两个包的全 32 位 md5。**

### 11.4 ⛔ GLM 不写报告、不下结论

GLM 只交原始包 + `STOPS.md` + `u141-cells.tsv`。⛔ 不写分析、不算均值/CV/百分比、不判非劣、不给升级建议。所有统计与判决由 opencode 从原始数据计算（⑧）。

---

## 十二、授权边界

**允许**：`ceph df` / `ceph -s` / `ceph health` / `ceph osd stat|ls|dump|getcrushmap` / `ceph config dump` / `ceph tell osd.* compact|perf dump`（V4 内部调用）、`juicefs mount|umount|gc --compact|status`、`fio`、`drop_caches`、读 `/proc/<pid>/{exe,environ,task}`、`tar`、`cp`。

**禁止**：
- ⛔ 改 `/etc/ceph/ceph.conf`、⛔ `ceph config set`、⛔ 改任何 OSD/MON 配置
- ⛔ 改 `/tmp/FULLBASELINE_V4.sh`
- ⛔ 覆盖 `/usr/local/bin/juicefs`
- ⛔ `juicefs format`（V4 的 `mount_jfs` 在已挂载时会跳过；若未挂载它会自行 format，这是 V4 原生行为，不得手工另跑）
- ⛔ 重编译、下载源码、生成新二进制
- ⛔ `rm -rf /tmp/opencode-fullbaseline-v4`
- ⛔ 加 `--layout` / `--remount` / `--allow-restart`
- ⛔ 用 `set +e` / `|| true` / 拆分调用绕过 rc≠0
- ⛔ 中途暂停向用户提问
- ⛔ 新建脚本副本（⑪）：本任务只允许一个新脚本 `/tmp/u141-upgrade-abba.sh`，⛔ 不留 `.bak`/`.v2`/`.old` 等任何副本；脚本若需修改，原地改并重新 `bash -n`

---

## 十三、完成后的路线

1. opencode 从 `u141-cells.tsv` + 原始包重算全部统计，按 §9.5 出判决。
2. 订正 `doc/perf-report/juicefs-v1.4.1-vs-patched-v1.3.1-baseline-20260824.md`：换真实 03-17f 基线、randwrite 对照列出处改标 03-18、`+6.5%` 改为流形等价结论、补 8 项证据缺口说明。
3. 若 randrw 确证退步 → 另立任务书做版本级归因。
4. 随后才执行 **03-19**（randwrite 活跃 inode 128 vs 256）—— 03-19 会永久改写 `rw_test`，务必在本任务之后。
