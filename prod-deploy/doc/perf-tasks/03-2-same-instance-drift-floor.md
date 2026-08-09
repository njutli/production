# 03-2 同实例跨运行漂移底噪测定（读侧连跑 12h）

> 面向对象：**GLM**
> 是否重跑：新任务
> 承接结果目录：`/tmp/opencode-fullbaseline-v4/`（沿用，新增 `Y1`…`Y10` 子目录）
> 计划书：`doc/perf-analysis/03-juicefs-parameter-tuning-execution-plan.md` §六（T1 协议）
> 方法论：`skills/FULLBASELINE-SKILL.md`、`skills/TUNING-SKILL.md`、`skills/SYSTEM-SAFETY-SKILL.md`、`skills/TESTING-GUIDE.md`
> 脚本：`/tmp/FULLBASELINE_V4.sh`（md5 **`3fd1281fea1c08342051d64fc8eb1348`**，1272 行，**不得修改**）
> 日期：2026-08-06 夜间

---

## 〇、背景

### 0.1 我们缺一个分母

03 阶段全部 T1 战役（OSD 侧在线旋钮，同实例 A-B-A）的判定式是：

```
旋钮有效  ⟺  |B − mean(A, A')|  ≥  max( 该项可检出效应量 , 2 × |A − A'| )
                                                            ↑
                                                    这个底噪从未被测过
```

`|A − A'|` = **同一个 JuiceFS 挂载实例内、两次连续运行之间的漂移**。

现有全部数据都测不出它：W2 基线的三次运行（W2P1/P2/P3）**每次都 remount**，所以 W2 测到的跨运行偏差里混着 F1 的档位抽签（跨实例极差 29.9%）。R3 的十组同样是每组重挂。⇒ **同实例跨运行漂移，至今 n=0。**

没有这个数，明天就算批了旋钮，A/B 差异出来也**判不了**（不知道该跟多大的底噪比）。

### 0.2 顺带排掉计划的最大单点风险

T1 协议假设"一个挂载实例的档位在整场 A-B-A（数小时）内保持不变"。这个假设的全部证据都来自 **≤30min 的窗口**（R3 每组 2 轮、03-1 每实例 ~34min）。

**如果档位在数小时内会自己漂，T1 全线（K1-K8，约 25h 机器时间）当场作废。** 本任务连跑 12h 同实例，直接给出档位的长时稳定性曲线。

### 0.3 为什么今晚能跑（不受当前阻塞影响）

当前池状态被 03-1 污染到 **OBJECTS 12.44M / STORED 3.0 TiB**（签收态是 2.36M / 576 GiB），已超 R5 拐点上界 2.8 倍 ⇒ **一切写侧测试的绝对值现在都不可用**（计划书 §3.1，P0 阻塞）。

但本任务只跑**读侧三项**，不受影响，依据两条：

1. **F5 读写解耦（已证）**：randread 跨 1222 GiB 写入极差仅 2.0%，与轮前对象数、累计写入量均不相关（R4/R5）。
2. **脚本事实（已核）**：`item_seqread` / `item_mseqread` / `item_randread` 三个函数体内**没有任何 `gc` / `compact` / 写入调用**，只读 `${TEST_DIR}/seqread/`、`${TEST_DIR}/mseqread/`、`read_test.*.0`。其中 `read_test.*.0` 按设计**永不被写测试覆盖**。

⇒ 本任务**不需要**先做池回收，**不需要** `gc --delete` 授权，**不产生**新对象。

---

## 一、目标

**一句话**：在同一个 JuiceFS 挂载实例上连续跑 10 次只读全项运行，测出 `seqread` / `mseqread` / `randread` 三项的**跨运行漂移底噪**，并判定挂载实例的性能档位能否在 12 小时内保持稳定。

具体要回答四个问题：

| # | 问题 | 判据 |
|---|---|---|
| Q1 | 同实例跨运行漂移 `\|A−A'\|` 是多少？ | 给出三项各自的 n−1 个相邻运行 `\|Δ\|`、median、max、CV |
| Q2 | 同实例内 L3（跨运行 median 偏差）能否 ≤5%？ | 若能 ⇒ `seqread` 可从"条件签收"转正式签收 |
| Q3 | 档位在 12h 内是否漂移？ | randread 全部运行 median 落在 ±2% 带内 ⇒ 档位稳定，T1 协议成立 |
| Q4 | 轮间 L2 的分布长什么样？ | 50 轮 randread 是我们能拿到的最紧重复性估计 |

**Q3 是本任务最高优先级**：它决定明天 25h 的 T1 排期成立与否。即使只跑完 5 个运行，Q3 也能出结论。

---

## 二、口径与矩阵

### 2.1 固定量（全程不得变）

| 项 | 值 |
|---|---|
| 脚本 | `/tmp/FULLBASELINE_V4.sh`，md5 `3fd1281fea1c08342051d64fc8eb1348`，**禁止修改** |
| `ITEMS` | `"seqread mseqread randread"`（顺序即执行顺序，读侧三项） |
| `RUNTIME` | `180`（秒，第 2 个位置参数） |
| `REPEAT` | `5`（第 3 个位置参数） |
| `SKIP_REMOUNT` | `1`（**全程**，绝不 remount） |
| 挂载参数 | `--max-uploads 150 --cache-size 0`（当前实例已是此配置，**不得改**） |
| 元数据 | `tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod` |
| 挂载点 / 测试目录 | `/mnt/juicefs` / `/mnt/juicefs/test_dir` |
| ceph 配置 | **一个字都不改** |

### 2.2 运行矩阵

| 运行 | LABEL | 说明 |
|---|---|---|
| 1 | `Y1` | 兼作档位门控（见 §3 步骤 3） |
| 2-10 | `Y2` … `Y10` | 同实例连跑 |

**单运行耗时估算**（据 W2 与 03-1 实测分解）：

| 阶段 | 耗时 | 依据 |
|---|---|---|
| `reset_state` 的 `gc --compact` | ~10-20min ⚠ | W2P2/P3 实测 ≈10min（当时 ~2.4M 对象）；现 12.44M，可能更长 |
| `compact_cooldown` + `drop_caches` | ~2-4min | 03-1：首次 4min，后续 1.5min |
| `deterministic_warmup`（读 418 文件 / 577 GiB） | ~8.5min | 03-1 实测 |
| fio：3 项 × 5 轮 × 180s + 间隔 | ~45min | seqread/mseqread/randread 各 ~3min/轮 |
| `summary` + `guard_report` + `steady_state_eval` | ~2min | — |
| **合计** | **≈70-80min / 运行** | ⇒ 10 运行 ≈ **12-13h** |

> ⚠ `gc --compact` 是本任务里唯一的不确定项（池里有 ~2.4 TiB 垃圾切片）。**Y1 跑完必须立刻回报实测单运行耗时**，据此重算 N（见 §3 步骤 5）。

### 2.3 停止规则（墙钟优先，硬性）

1. **T+11h 之后不再启动新的运行**（T = Y1 启动时刻）。已启动的跑完即止。
2. **N ≥ 5 即达成最低可用样本**（4 个相邻漂移估计，足以回答 Q3）。N < 5 须在报告里标注结论强度受限。
3. 到点即停，**不要为了凑 10 个而超时**。宁可 N=7 按时交，不要 N=10 拖到中午。

### 2.4 验收口径（继承，不得变）

- **逐秒均值**，窗口 `15 ≤ sec − t0 ≤ 175`（**相对该轮起点 t0**，不是绝对时刻）；每项取**逐轮中位数**。
- 不认 fio 汇总 BW。`rounds.tsv` 的 `BW_MiBs` 列是 fio 汇总值，**不是验收口径**（该文件表头是旧 5 列、数据实为 8 列 `LABEL round BW_MiBs hit status pg_gate pg gear`）。
- 三项都是**读项**，不适用首轮剔除规则（该规则只针对 `randwrite`/`randrw`，因其每轮后有 `gc --compact`）。⇒ **5 轮全部进 L2 统计**。
- 参考值（W2 签收）：`randread` **1880**（正式）、`mseqread` **4160**（正式）、`seqread` **1290**（条件）。
- 高档带：`randread ∈ [1830, 1930]`。

### 2.5 ⚠ ITEMS 子集纪律（F11）

子集运行的绝对值**不必然等于**全量运行的绝对值。但本任务三项均为**只读**，不受"前面跑过哪些写项"影响 ⇒ **本任务是 F11 的例外，可与 W2 全量签收值直接比较**。

**但**：本任务的核心交付是 Q1（**运行之间的相对漂移**），即使绝对值与 1880/4160/1290 有偏差，Q1/Q3 结论依然成立。**不要因为绝对值对不上就中止或重测。**

---

## 三、执行步骤

### 步骤 0（测试前）：通读 skill 并逐条确认

必读章节，须在回报里**逐条打勾确认**：

- `skills/SYSTEM-SAFETY-SKILL.md` §〇 / §1.1 / §1.2 —— 共享机红线
- `skills/FULLBASELINE-SKILL.md` —— 验收口径算法、门控协议、11 条已知坑
- `skills/TESTING-GUIDE.md` §1.3（compact 三指标）/ §2.2（每 fio 前 health）/ §3（cooldown）
- `skills/test-commands-reference.md` §8.3（稳态中位数）
- `skills/LONG-RUNNING-TEST-SKILL.md` —— 长跑监控（本任务 12h，必读）

并**逐条确认以下 8 条红线**（缺一条不许开跑）：

1. ⛔ 禁 `pkill -f fio` / `pkill -f juicefs` / `killall` —— **157 是 3075 人共享机**，跑着 WekaIO / K8s
2. ⛔ 禁 `--layout`（会 `rm -rf ${TEST_DIR}/*`，384 文件，10.5min 不可逆）
3. ⛔ 禁 `--allow-restart`；禁重启 157、禁重启任何 OSD
4. ⛔ 禁改任何 ceph 配置（`ceph config set` 本任务**一条都不用**）；禁动 IRQ / RPS / pg_num（autoscale 保持 off）
5. ⛔ **禁 `juicefs gc --delete`**、禁 `juicefs destroy`、禁 `juicefs format`、禁删除 `/mnt/juicefs/test_dir` 下任何文件（`read_test.*.0` 是 layout 资产，删了要重铺 10.5min 且换 epoch）
6. ⛔ 禁 remount（`SKIP_REMOUNT=1` 全程）；禁修改脚本
7. ⚠ `ceph health` 非 `HEALTH_OK` → 立即停止并上报
8. ⚠ 157 的 `/` **只剩 41 GB（96%）** → 见步骤 1 磁盘门禁

### 步骤 1：前置门禁（四项，任一不过则停止并上报）

```bash
# 1) 脚本完整性
md5sum /tmp/FULLBASELINE_V4.sh
#    必须 == 3fd1281fea1c08342051d64fc8eb1348

# 2) 集群健康
ceph health                     # 必须 HEALTH_OK
ceph osd tree | grep -c " up "  # 6 个 OSD 全 up
ceph pg stat                    # pg_num=32，全 active+clean

# 3) 磁盘（157 的 / 只剩 41G）
df -h /                         # 可用 < 25G ⇒ 停止并上报，不要自行删任何东西

# 4) 挂载实例身份（基准，后续每个运行都要比对）
pid=$(pgrep -f "^juicefs mount" | head -1)
echo "pid=${pid} starttime_ticks=$(awk '{print $22}' /proc/${pid}/stat)"
ps -o lstart= -p ${pid}
mount | grep juicefs
```

**基准值（2026-08-06 21:02 核实）**：

```
pid = 1631722
starttime_ticks = 1502152363
started = Thu Aug  6 19:34:12 2026
挂载参数 = --max-uploads 150 --cache-size 0
```

> 这个实例就是 03-1 的 **X8**，当时实测 `randread = 1860.8`（落在高档带 `[1830,1930]` 内）。
> **优先沿用它**：它已存活 ~1.5h，连跑 12h 后可给出 **~14h 的同实例档位曲线**，比新挂一个更有价值。

### 步骤 2：记录起跑前池状态（只读）

```bash
ceph df                          > /tmp/opencode-y-drift/ceph-df-pre.txt
juicefs status "${META}" | head -20
du -sh /mnt/juicefs/test_dir     # 预期 ~577G
ls /mnt/juicefs/test_dir | wc -l # 预期 388
```

预期：`OBJECTS ≈ 12.44M`、`STORED ≈ 3.0 TiB`。**记录即可，不要试图清理**（池回收是明天的 03-3 任务，需单独授权）。

### 步骤 3：跑 Y1（兼档位门控）

```bash
export META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
ITEMS="seqread mseqread randread" SKIP_REMOUNT=1 \
  bash /tmp/FULLBASELINE_V4.sh Y1 180 5 2>&1 | tee /tmp/y-drift-Y1.log
```

跑完检查 `steady_state_eval` 输出的 `randread median`：

| Y1 randread median | 动作 |
|---|---|
| **∈ [1830, 1930]** | ✅ 档位合格，**Y1 数据有效**，直接进步骤 4 |
| ∉ 该带 | ⚠ 当前实例不在高档。做**一次**优雅卸载 + 重挂（`umount` → 挂载 → 记录新 pid/starttime_ticks），把该轮记为 `Y1-discard`，重跑 Y1。**最多重挂 3 次**；3 次都不在带内 → 停止并上报（说明抽签分布变了，这本身是重要发现） |

> 优雅卸载只用已授权的 `umount` / `mount`，**禁止** `pkill`。卸载失败时按 `FULLBASELINE-SKILL.md` 的四级优雅卸载流程处理，**不得升级到 kill**。

### 步骤 4：回报 Y1，重算 N

Y1 一跑完**立即**回报（不要等全部跑完）：

1. 实测单运行墙钟耗时，及其中 `gc --compact` 单独耗时
2. `randread` / `mseqread` / `seqread` 的逐轮逐秒均值 + median + 轮间极差%
3. 按实测耗时重算 N：`N = floor(11h / 单运行耗时)`，上限 10

### 步骤 5：连跑 Y2 … YN（同实例）

```bash
for i in $(seq 2 ${N}); do
  # 每个运行前：健康 + 实例身份 + 磁盘，三项门禁
  ceph health | grep -q HEALTH_OK || { echo "STOP: health"; break; }
  pid=$(pgrep -f "^juicefs mount" | head -1)
  st=$(awk '{print $22}' /proc/${pid}/stat)
  [ "${st}" = "<Y1 记录的 starttime_ticks>" ] || { echo "STOP: 实例被换"; break; }
  [ $(df --output=avail -BG / | tail -1 | tr -dc 0-9) -ge 25 ] || { echo "STOP: disk"; break; }

  ITEMS="seqread mseqread randread" SKIP_REMOUNT=1 \
    bash /tmp/FULLBASELINE_V4.sh Y${i} 180 5 2>&1 | tee /tmp/y-drift-Y${i}.log

  # 每运行后记录池状态（只读，用于事后验证读写解耦）
  ceph df | grep juicefs-data >> /tmp/opencode-y-drift/ceph-df-per-run.txt
done
```

**每个运行必须核对**：
- `jfs-instance-Y*.txt` 里 **不得出现 `forced-mount`**。一旦出现 ⇒ 实例被换 ⇒ 该运行及其后全部数据的 L3 比较**无效** ⇒ **立即停止**并上报（此时已完成的 Y1..Y(i-1) 仍然有效，照样交）。
- `rounds.tsv` 该运行的 15 行全部 `pg_gate=CLEAN`。有 `DIRTY` 行须标注。

### 步骤 6：中途监控（每 ~2h 一次，只读）

```bash
ceph health; ceph pg stat
pgrep -f "^juicefs mount" | head -1        # pid 应恒为 1631722
uptime                                      # 记录 load（157 外部租户 core 1-16 占满，load 常态 27.6-32.0）
df -h /
tail -5 /tmp/y-drift-Y*.log | tail -20
```

**只看不动**。load 高不是停止理由（历史已证 load 不解释档位：最慢的 g6 反而 load 最低）。

### 步骤 7：末步（测试后）—— skill 合规自查

对照 skill 逐条复核并在报告中记录结果，必查项：

1. 全程**未出现** `pkill` / `killall` / `juicefs destroy` / `ceph osd pool delete` / `gc --delete`
2. 全程**未修改**任何 ceph 配置（附 `ceph config dump` 前后 diff，应为空）
3. 全程**未 remount**（`jfs-instance-Y*.txt` 无 `forced-mount`，pid/starttime_ticks 全部相同）
4. 每 fio 前 `drop_caches`（脚本内置，确认日志有）
5. 每 fio 前 `check_ceph_health`（脚本内置，确认日志有）
6. 统计口径用逐秒均值（窗口相对 t0），**不是** fio 汇总
7. 脚本 md5 前后一致
8. 未删除 `test_dir` 下任何文件（`ls | wc -l` 仍为 388，`du -sh` 仍 ~577G）

**任一不符须显式标注并说明对结论的影响，不得默默跳过。**

---

## 四、交付物

### 4.1 报告落点

`doc/perf-report/03-2-same-instance-drift-floor-20260806.md`，须含：

| § | 内容 |
|---|---|
| 〇 | 结论：Q1-Q4 四个问题的直接答案（各一句） |
| 一 | 步骤 0 的 8 条红线逐条确认 |
| 二 | 脚本 md5（前后） |
| 三 | **主表**：Y1..YN × 3 项，每项列 5 轮逐秒均值 + median + 轮间极差% |
| 四 | **Q1 漂移表**：相邻运行 `\|Δ\|`（N−1 个）、median、max、CV；三项各一行 |
| 五 | **Q2**：同实例 L3（各项 max−min / median），是否 ≤5% |
| 六 | **Q3 档位曲线**：randread median 随运行序的变化（含时刻），是否全部落 ±2% 带内 |
| 七 | **Q4**：全部 5N 轮 randread 的分布（median / CV / 极差） |
| 八 | 实例身份表：每运行的 pid + starttime_ticks + 时刻（证明同一实例） |
| 九 | `ceph df` 起跑前 / 每运行后 / 跑完（验证读侧不产生对象、池状态无漂移） |
| 十 | `ceph health` 与 `pg_gate` 全程记录 |
| 十一 | 异常与偏离计划之处（**有就写，没有就写"无"**） |
| 十二 | 数据路径（157 + 本地） |
| 十三 | skill 合规自查结果（步骤 7 八项） |

### 4.2 数据

- 157：`/tmp/opencode-fullbaseline-v4/Y1..YN/`（含 per-job `*_bw.*.log` 全部保留）、`/tmp/y-drift-Y*.log`、`/tmp/opencode-y-drift/`
- **当天必须归档到本地** `results/prod-03-2-drift-floor-<timestamp>/` —— 157 的 `/tmp` 易失，这是 `stability-raw` 那次教训固化下来的纪律
- 结果目录必须含 `commands.sh`（实际执行的完整命令，可复现）

### 4.3 回报纪律

- **Y1 跑完立即回报**（步骤 4），不要等 12h 全部跑完
- 之后每 ~4h 简报一次（当前运行序、randread median 序列、health、有无异常）
- 任何"必须改变量才能跑通"的障碍 → **停下来报告，等确认，不得自行绕道**
- 结论**必须**明确落在 Q3 的哪一侧（档位稳定 / 档位漂移），这是明天排期的开关

---

## 五、通用注意事项（必带）

### 1. 数据统计口径

- 稳态优先：fio 平均 BW 受前期暂态污染（写类偏高 7-8%，曾出现超网卡线速的假象）。**正确值 = 逐秒带宽序列按窗口取均值/中位数**（本任务口径见 §2.4）。
- 所有 fio 必须带 `--write_bw_log=<prefix> --log_avg_msec=1000`（脚本内置）。fio 默认 `per_job_logs=1`，多 job 会落 `<prefix>_bw.<job_id>.log` 共 numjobs 份 —— **务必确认这些 per-job 文件全部保留**（不要 `--per_job_logs=0`）。randread 每轮应有 **128 份**。
- 多 job 统计：按时间戳对齐**求和**所有 job 的逐秒带宽 → 取窗口内均值。**绝对禁止**"一份合并 log × numjobs"外推（历史 65× 失真的来源）。
- 多实例（多个独立 fio 进程）：各自聚合后**求和**，不是乘。
- REPEAT=5 **取中位数**，不取平均、不挑轮次。
- randrw 的 R/W 分开报、不合计（本任务不含 randrw，但口径纪律照旧）。
- **超网卡线速的值一律不认**（100GbE ≈ 12500 MiB/s 为物理上限）。

### 2. 冷态净化（drop_caches）

- 冷态口径下每轮跑前必须 drop_caches（客户端 157 + 3 个 slave 全部执行，脚本内置）。
- `direct=1` 只绕内核页缓存，**绕不开 JuiceFS 客户端缓冲** ⇒ 还需 `--cache-size 0`（当前实例已是）。

### 3. fresh-volume / 冷启动失真

- 本任务**全部复用已 layout 铺好的卷**（`read_test.*.0` / `seqread/` / `mseqread/`），**不 create_on_open、不 fresh volume** ⇒ 无该失真。
- ⛔ 不得为"干净"而清卷或重铺。

### 4. 后端干净态（compact cooldown）

- 高强度写后 **restart OSD 不能清除 compaction 积压** —— 必须 `compact` + 轮询至 `compact_running=0` 且 `compact_queue_len=0`（脚本 `compact_cooldown` 内置）。
- `compact_running=0` + `queue_len=0` 只表示"没在 compact"，**不保证 LSM tree 最优**。数据异常须排查，不得跳过。
- 本任务无写项，但 `reset_state` 仍会做 `gc --compact` + cooldown，**照做不跳过**。

### 5. 环境前置检查

- 开测前 `ceph health` = `HEALTH_OK`、6 个 OSD 全 `up`。
- JuiceFS 版本须含 loadRange 修复（当前 `1.3.1+2025-12-02.e0032b2` ✅，stock v1.3.1 有 2× 读放大 bug）。
- **157 红线**：157 上有 WekaIO 业务在跑，**禁动内核 / 网卡 / RoCE / md0 / WekaIO 路径**；BeeGFS 与本测试抢同批盘须错峰。

### 6. 记录规范

- 每个结果目录**必须含 `commands.sh`**。
- 每项须保存：fio 全文输出、**全部** per-job bw_log、`env-snapshot`、ceph 状态。
- 验收线随口径（本任务不对验收线，只测漂移）。

### 7. 卷清理

- **本任务不做任何清理。** `juicefs format` 不删对象（只重置元数据，pool 里成孤儿）；`juicefs destroy` 才删 —— **两者本任务都禁用**。
- ⛔ **禁用 `ceph osd pool delete + create`**：会改 pool_id → CRUSH 重算 PG→OSD → 同一次重建内也产生 −22~−26% 漂移（实证 `00-baseline-20260723.md` §9.6）。
- ⛔ 禁 OSD restart 作轮间清理。

### 8. 分层授权：可自主修复 vs 禁止擅动

- ✅ **可自主修复（工程性，不改变量）**：环境适配（路径 / 依赖 / auth）、采集增强、日志改进。**发现会采到错误数据时应先修好再采**；修完必须在报告显式声明改了什么、为什么。
- 🔴 **禁止擅动（改变量则实验失效）**：`ITEMS` / `RUNTIME` / `REPEAT` / `SKIP_REMOUNT` / 挂载参数 / ceph 配置 / 是否 remount / 是否清理 / 判据 / 口径 / 脚本本体。
- **规则一句话**：实现怎么修都行；**改变量之前必须停下来报告，不能绕道。**
- ⚑ 特别提醒（03-1 的教训）：03-1 擅自加了 `RANDREAD_REPEAT=1` 并把 runtime 从 75s 改成 180s，虽然事后判定不影响口径、也做了披露，但**这类改动必须先问**。本任务 `REPEAT=5` 是漂移统计的样本量基础，**擅自减小会直接毁掉 Q1**。

---

## 红线汇总

### 本任务特有

1. ⛔ **禁 remount**：`SKIP_REMOUNT=1` 全程。整个任务的价值就建立在"同一个挂载实例"上，remount 一次 = 全部 L3 比较作废。
2. ⛔ **禁 `juicefs gc --delete`**：池回收是另一个任务（需单独授权）。本任务只允许脚本内置的 `gc --compact`。
3. ⛔ **禁删 `/mnt/juicefs/test_dir` 下任何文件**：`read_test.*.0` 是 layout 资产（388 项 / 577 GiB），删了要重铺 10.5min 且换 layout epoch，跨 epoch 绝对值不可比。
4. ⛔ **禁改脚本**：md5 必须始终为 `3fd1281fea1c08342051d64fc8eb1348`。
5. ⛔ **禁改任何 ceph 配置**：本任务一条 `ceph config set` 都不需要。前后 `ceph config dump` diff 必须为空。
6. ⚠ **磁盘**：157 的 `/` 仅剩 41 GB（96%）。可用 < 25 GB 即停止上报，**不要自行删任何东西**。
7. ⚠ **墙钟硬停**：T+11h 后不启新运行。N≥5 即可交。**不要为凑 10 个而超时。**

### 复述通用红线

8. ⛔ 禁 `pkill -f fio` / `pkill -f juicefs` / `killall` —— **157 是 3075 人共享机**（WekaIO / K8s 在跑）。卸载卡住走四级优雅流程，**不得升级到 kill**。
9. ⛔ 禁 `--layout`、禁 `--allow-restart`、禁重启 157 或任何 OSD。
10. ⛔ 禁动 IRQ / RPS / pg_num（autoscale 保持 off）、禁动 157 内核 / 网卡 / md0 / WekaIO。
11. ⚠ `ceph health` 异常 → 立即停止并上报。
12. ✅ 已授权 sudo：`ceph tell osd.N compact`、3 节点 `drop_caches`、`juicefs gc --compact`、`umount` / `mount`。**其余一律先问。**
