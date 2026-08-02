# 任务书 02-2：基线复现锁定 + buffer-size 总闸假说验证（正交实验）

> 面向 GLM。承接 02-1（`doc/perf-report/02-1-zero-check-report.md`）+ `doc/perf-analysis/02-backend-raw-cap-and-juicefs-tuning-plan.md` §五 B 线。
>
> **本任务回答两个递进的问题**：
> 1. **基线能不能复现？** 02-1b 的 `max-fuse-io 256K + buffer-size 1024` 收益无法采信，根因是**基线本身在漂移**（同一配置 randwrite 在不同报告里从 683 到 1760，差 2.6×）。任何"+X%"都是拿浮动基线算出来的。**必须先把上周的 01-2d 基线在当前环境重新复现稳定，才能谈收益。**
> 2. **buffer-size 是不是一道"总闸"，之前判为无效的并发/大块类配置，是不是被 300MB 默认写限憋住了？**（用户假说）
>
> 承接数据：`results/prod-01-2d-fullretest-20260717/summary.md`（准确基线）+ `results/prod-02-1-zero-check-20260720-120000/`（02-1 sweep）+ `results/maxfuse-instrumented-20260721/`（写劣化根因）。
> 方法论见 skill：`TESTING-GUIDE.md`、`test-commands-reference.md` §6.1/§8。
> 上位规划：`doc/perf-analysis/02-backend-raw-cap-and-juicefs-tuning-plan.md` §五 B1/B2。

---

## 〇、背景：为什么必须先复现基线再谈收益

### 0.1 基线漂移的证据（同一 `256K + buffer-size 1024` 配置，三处数字打架）

| 来源 | randread | randwrite-true | 备注 |
|------|:-:|:-:|:-:|
| 02-1 §9.1 sweep（256K，无 buf 调整） | 3791 | 535 | 无 buf1024 |
| 02-1 §十一（256K + buf1024） | 3757 | 683 | 有 buf1024 |
| 02-1b 报告 | 3528 | 1760 | 同配置，写差 2.6× |
| 01-2d 准确基线（128K 默认 ra0） | 2404 | 4274 | **历史基准** |

- randread 在 2404 / 3528 / 3757 / 3791 之间跳；randwrite-true 在 535 / 683 / 1760 / 4274 之间跳。
- **同一配置 randwrite 从 683 到 1760，差 2.6×**——这不是调优收益，是环境噪声。
- 02-1 §7（Z6）已给出噪声来源实锤：**EC 随机读 fast_read=false 时轮间偏差 19.3%**（4173/3377/4178）。这与"基线难复现"高度同源。

### 0.2 buffer-size 总闸假说（用户提出）

02-1 §10 已用 instrumented binary 把写劣化根因钉死到一行 JuiceFS 源码：

```
--max-fuse-io 256K → go-fuse readPool buffer 每个 262K（vs 128K 的 131K）
  → Go 运行时 m.Sys 涨到 447-583MB
  → 超过 --buffer-size 默认 300MB（writer.go:301 usedBufferSize > bufferSize）
  → fileWriter.Write() 触发 time.Sleep(10ms)，极端时 100ms
  → 写 slat 从 ~7ms 暴涨到 ~50ms
```

**用户假说**：`--buffer-size 300MB` 是一道**总闸**。之前判为"无效/有害"的一些配置，可能本来有收益，但一提高并发/内存占用就撞上 300MB 写限触发 sleep，收益被 sleep 吃掉、于是显示为"无效"。放开 buffer 后，这些配置也许翻盘。

### 0.3 假说的边界（必须先厘清，避免走偏）

**关键机制**：`usedBufferSize()` 卡的是 **Go 进程总内存 m.Sys**，`sleep` 只发生在**写路径** `fileWriter.Write()`。所以 buffer-size 只对"**会推高 m.Sys 的配置**"起总闸作用，**不是对所有配置普适**。逐项分类：

| 之前判定 | 配置 | 是否推高 m.Sys | 放开 buffer 后是否可能翻盘 |
|------|------|:-:|:-:|
| 有害（02-1 §8.2） | `async_dio` | 否（机制=kernel 侧 ~1ms/dispatch 计数） | **不会** → 不重试 |
| 无收益（02-1 §8.1） | `MaxBackground=200` | **是**（并发↑→in-flight↑） | **可能** → 重试 |
| +3% 噪声（Z5） | `objecter_inflight_op_bytes` | 否（OSD/objecter 侧） | 不会 → 不重试 |
| 读不如 256K（§9.1） | `max-fuse-io 512K/1M` | **是**（buffer 更大） | **很可能** → 重扫 |
| 控写不控读（01-3） | `max-uploads` | 部分（上传并发） | 可能 → 顺带扫 |

**结论：重点重试对象 = `max-fuse-io 512K/1M` + `MaxBackground` + 并发/上传深度类；`async_dio` / `objecter` 机制无关，不回头。**

### 0.4 一个必须先证伪的对照（防止机制误判）

默认 128K 配置下 m.Sys 不超 300MB（所以不 sleep）。因此：**在 128K 默认下单独把 buffer-size 300→1024，写应当"没有变化"。**
- 若这一步就涨了 → 说明机制理解有误（buffer 是独立瓶颈，不是"总闸副作用解除"），假说要重写。
- 若如预期无变化 → 证实 buffer 只是"256K 等大配置的副作用解除阀"，假说成立，可继续矩阵。

这是整个任务的**机制锚点**，必须第一个做。

---

## 一、目标

| 阶段 | 目标 | 判据 |
|------|------|------|
| **P1 基线锁定** | 在当前环境把 128K 默认 ra0 基线测**准**（收敛稳定），锁定为本阶段权威新基线 | **唯一硬门槛=收敛性**：每轮 REPEAT≥5 的 CV<5%，**且轮间**（多轮 + 轮间清理/重部署之间）也收敛于同一值。与 01-2d（2404/4274）的偏差**仅作参考记录、不作门槛**——旧基线本身可能有偏差 |
| **P2 总闸证伪对照** | 128K 默认下单变量调 buffer-size 300→1024 | 写无显著变化（±5%）= 假说边界成立 |
| **P3 矩阵重扫** | buffer 放开后重扫之前"无效"的并发/大块类配置 | 找出被 buffer 憋住、放开后翻盘的配置 |
| **P4 收益判定** | 以复现稳的基线为分母，给 `256K+buf1024` 及矩阵最优配置的**可信收益** | 读、写分别给出 vs 稳定基线的净变化 |

**成功标准**：产出一张"配置 → 稳定基线归一化收益"表，读写分列，每格 REPEAT≥5、CV<5%，杜绝拿浮动基线算收益。**分母 = 本阶段收敛锁定的新基线，而非 01-2d 旧值**。

---

## 二、口径与前置

### 2.1 测试口径（继承 01-2d / 02-1）

- **block size**：256K（随机项）；大块项 mseqwrite 用 4M（沿用 01-2d layout 口径）。
- **fio**：128job × iodepth128，`--direct=1 --openfiles=128`。
- **readahead 口径（已定，用户拍板）**：
  - **步骤 1（P1 基线锁定）保留 default + ra0 双组**——需要一份完整 A/B 对照收敛数据固化"已知代价"（顺序读 default 强项 vs 随机读 ra0 强项）。
  - **步骤 2–4（P2/P3/P4）及本阶段之后所有全量测试，一律只测 ra0（`--max-readahead 0`）**。依据：生产只能用一种挂载配置，不可能按 IO 类型换配置重挂；**AI 训推稳态热点 = shuffle DataLoader 高并发随机读 + checkpoint 并发写，ra0 全面且显著占优**（randread 2.0×、randwrite +18%、mseqwrite +30%、randrw 1.4×）；default 唯一强项(顺序大文件读)属权重加载类**冷启动一次性开销**,已在 P1 双组对照中作"已知代价"记录，不再每轮双测。
- **统计**：§8.3 稳态中位数（截开头 1/4），`--write_bw_log --log_avg_msec=1000`，保留全部 128 份 per-job bw_log。**禁止** bw_log×numjobs 外推。
- **REPEAT**：本任务因要对抗基线漂移，**REPEAT≥5**（不是 3），取中位数（第 3 大值），并报告 CV。
- **收敛性判据（本任务的核心纪律，替代"贴近旧基线"）**：基线是否"测准"只看**收敛**，分两层：
  - **轮内收敛**：单配置 REPEAT≥5 的 CV<5%。
  - **轮间收敛**：多轮之间（含轮间 drop_caches / 清理 / 必要时重部署集群以排除轮间相互影响）的中位值也稳定收敛于同一值（轮间 CV 亦 <5%）。
  - 两层都满足 = **本次测准**，该收敛值即锁定为**本阶段权威新基线（分母）**，无论它与 01-2d 旧值差多少。
  - 与 01-2d（2404/4274）的偏差**仅作参考记录**：若偏差 >10%，不视为失败，在报告中注明"旧基线 01-2d 疑有偏差，本次采用轮间清理/重部署消除轮间干扰，方法上更可信，以本次收敛值为准"。
- **冷态**：cache=0，每轮跑前 drop_caches（157 + 3 slave）。
- **稳定化**：若 CV 仍 >5%，**开 EC pool `fast_read=true`**（02-1 Z6 证明可把 EC 读轮间偏差从 19.3% 压到 2.6%）作为稳定化手段；记录是否开启。
- **验收线**：6250 MiB/s（不限速 100GbE 网卡 50%）。

### 2.2 环境前置

- [ ] `ceph health` = HEALTH_OK，6 OSD up/in。
- [ ] **157 可用内存确认**：`free -g`。buffer-size 拟调至 1024MB+，须确认 157 剩余内存足够（WekaIO 是红线，不得因测试把 client 内存打爆）。记录基线可用内存，设定 buffer-size 上限不超过"可用内存的一半且 ≤ 4096MB"。
- [ ] JuiceFS 版本 `1.3.1+`。
- [ ] `ceph osd dump` 快照（配置变更前留底）。
- [ ] BeeGFS 错峰用盘。
- [ ] 记录 JuiceFS 默认值基准：`--max-fuse-io 128K`、`--buffer-size 300M`、`--max-uploads`（02-1 用 150）、go-fuse `MaxBackground=50`（`pkg/fuse/fuse.go:469` 硬编码，用户态；内核侧 `/sys/fs/fuse/connections/*/max_background` 是另一变量，需同时调）。

---

## 三、执行步骤

### 步骤 0：环境前置检查（见 §2.2）

### 步骤 1（P1）：复现 01-2d 128K 默认基线 —— 最优先，其余步骤依赖它

> 目标：在当前环境把 128K 默认 ra0 基线测**准**——通过多轮 + 轮间清理/重部署使测值收敛于特定值，锁定为后续所有收益的可信分母（权威新基线）。不要求贴近 01-2d 旧值，旧值本身可能有偏差。

**1.1 mount（128K 默认，ra0）**：
```bash
juicefs mount -d \
  --storage ceph --bucket "ceph://${POOL}" \
  --access-key ceph --secret-key "${CEPHX}" \
  --block-size 256K \
  --max-fuse-io 128K --buffer-size 300M \
  --max-uploads 150 --cache-size 0 --max-readahead 0 \
  "${META}" /mnt/juicefs
```

**1.2 复用 01-2d layout 数据**（若已失效则重 layout，compact cooldown 至 `compact_running=0`）。

**1.3 跑 randread + randwrite-true，REPEAT≥5**：
```bash
# randread（每轮跑前 drop_caches 157+3 slave）
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log=/tmp/p1-128k-randread --log_avg_msec=1000
# randwrite-true 同口径，--rw=randwrite
# 各跑 5 轮
```

**1.4 判定**（硬门槛=收敛，不看是否贴近旧基线）：
- **✅ 基线锁定成功**：randread 与 randwrite-true 满足**轮内 CV<5% 且轮间收敛（轮间 CV<5%）**——即多轮 + 轮间清理/重部署后，测值收敛于某个特定值。此收敛值即锁定为本阶段**权威新基线（分母）**，进步骤 2。
  - 与 01-2d（2404/4274）偏差 >10% **不影响锁定**，仅在报告中记录偏差并注明"以本次收敛值为准，旧基线疑有偏差"。
- **❌ 未收敛**（轮内或轮间 CV>5%，测值不收敛于特定值）→ 说明仍受干扰，尚未测准，排查顺序：
  1. 开 `fast_read=true` 重跑，看 CV 是否收敛（02-1 Z6 手段）。
  2. 检查 OSD 是否预热/是否有 scrub/degraded/compaction（`ceph status`、`ceph osd pool stats`）。
  3. 检查 cluster_network 状态（02-1 Z1 已生效，但确认流量仍在 cluster NIC）。
  4. 加大轮间清理力度（drop_caches / 卸载重挂 / 必要时重部署集群），排除轮间相互影响。
  - **基线未收敛锁定前，不得进入步骤 2–4**（否则重蹈 02-1b 覆辙）。

### 步骤 2（P2）：buffer-size 总闸证伪对照 —— 机制锚点

> 目标：128K 默认下单独调 buffer-size 300→1024，验证"buffer 只是 256K 等大配置的副作用解除阀，不是独立瓶颈"。

**2.1 单变量测试**（仅改 buffer-size，其余同步骤 1）：
```bash
juicefs mount ... --max-fuse-io 128K --buffer-size 1024 ...
# 跑 randread + randwrite-true，REPEAT≥5
```

**2.2 判定**：
- 写变化 ±5% 内（无显著变化）→ ✅ **假说边界成立**：buffer 对 128K（不撞限）无影响，总闸只在大配置下起作用。继续步骤 3。
- 写显著上涨（>5%）→ ⚠️ **机制误判**：buffer 是独立写瓶颈，非"副作用解除"。记录，重新评估 §0.2 假说；此时 buffer-size 本身应升级为独立调优项。
- 写下降 → 记录（可能内存压力反噬），分析后再定。

### 步骤 3（P3）：buffer 放开后矩阵重扫 —— 验证被憋住的配置

> **P3 有效性判据（基于 P1 六段 + T1 实验结论制定）**
>
> P1 基线四轮测试已确认：跨重建周期 randread 漂移 12-20%、randwrite-true 漂移 4-25%，
> 这是重建引入的 OSD ID/PG 映射/tmpfs 差异导致的**已知噪声带**，无法靠重测消除。
> 因此 P3 不能用"跨重建 CV<5%"作为判据，改用以下 5 条：
>
> 1. **同周期背靠背对比**：256K+buf1024（待验）与 128K+buf300（对照）在**同一次重建/同一次挂载会话内**背靠背跑，只比二者 Δ，**不跨重建比绝对值**（跨重建漂移 12-29% 是已知噪声带）。
> 2. **效应量门槛**：只有 Δ **显著大于 ±15% 噪声带**才算真实效应。max-fuse-io 历史效应量 randread ~2.0×、mseqwrite ~+30%，远大于噪声，信号可辨。
> 3. **randrw 用 T1 确定的干净口径**：每轮 `rm -rf TEST_DIR && mkdir` 重建 layout + drop_caches 全节点 + compact_cooldown（T1.2 验证 CV=2.1% 消除骤降）；或直接**丢弃 r3 污染样本、取 r1/r2 中位**。
> 4. **randwrite-ow 用 bw_log 稳态中位**（非 fio 平均），且标注为非目标项（递减趋势是覆写确定性行为）。
> 5. **T1 实验结论**：randrw r3 骤降 = 脚本缺陷（layout 复用累积污染），非系统波动。详见 `results/prod-02-2-p1-baseline-20260722/t1-randrw-r3-drop-analysis.md`。

> 目标：在 buffer-size=1024（或步骤 2 确定的安全值）打底下，重扫之前判为"无效"的、会推高 m.Sys 的配置，看是否翻盘。
> **不重扫** async_dio（机制无关）、objecter（OSD 侧）。

**3.1 max-fuse-io 重扫（配 buf1024）**：
```bash
# 矩阵：max-fuse-io ∈ {128K, 256K, 512K, 1M} × buffer-size=1024
# 每格跑 randread + randwrite-true + mseqwrite(4M)，REPEAT≥5
for mfio in 128K 256K 512K 1M; do
  juicefs mount ... --max-fuse-io $mfio --buffer-size 1024 ...
  # 3 项 fio，各 5 轮，记录 BW/slat/CV
done
```
- 重点看：①放开 buffer 后，512K/1M 的读是否追上或超过 256K（此前 §9.1 的"1M 读不如 256K"是否为 sleep 污染的假象）；②写在各档是否都不再劣化；③mseqwrite 4M 的 +89%（2265→4279）是否在稳定基线下复现。

**3.2 MaxBackground 重扫（配 buf1024）**：
```bash
# 内核侧 + 用户态两个 max_background 需同时调
# 用户态：go-fuse fuse.go:469 硬编码 50 —— 若要改需改源码或确认 JuiceFS 是否暴露 flag
# 内核侧：mount 后 echo N > /sys/fs/fuse/connections/<id>/max_background
# 矩阵：max_background ∈ {50, 100, 200} × 最优 max-fuse-io × buf1024
```
- 判定：此前 §8.2 中 max_bg=200 只 +11%（且伴随 sleep 污染），放开 buffer 后是否 >+11%。

**3.3 max-uploads 顺带扫（可选，低优先级）**：
- 01-3 判"控写不控读"，但那是 300MB buffer 下。buf1024 下重测 max-uploads ∈ {150, 300} 对写的影响。

**3.4 判定**：
- 任一配置在稳定基线下净收益 ≥+10%（读或写）→ ✅ 该配置被 buffer 憋住过，纳入候选最优配置组合。
- 全部仍 <+5% → ❌ 假说不成立，这些配置确实无效（与 buffer 无关），B 线不再追这些参数。

### 步骤 4（P4）：收益汇总 + 最优配置组合复测

**4.1** 以步骤 1 锁定的稳定基线为分母，产出归一化收益表（读/写分列，每格 REPEAT≥5、CV<5%）。

**4.2** 取矩阵最优组合（如 `max-fuse-io 256K + buffer-size 1024 + max_background X`），跑完整 9 项 01-2d 基线，与稳定基线全项对照，确认无某项被拖累（尤其写不能低于 128K 基线的 4274）。

**4.3** 判定最终推荐配置：
- 读写都不劣于 128K 基线、且至少一项显著提升 → 纳入 B 线生产候选配置，写入 02 计划。
- 存在读涨写跌（无法两全）→ 明确记录 trade-off，交用户按业务读写比拍板，**不擅自定为最优**。

---

## 四、交付物

```
results/prod-02-2-baseline-reproduce-buffer-<YYYYMMDD-HHMMSS>/
├── commands.sh                              # 完整可执行命令
├── env-snapshot.txt                         # HEALTH_OK + 6 OSD + 157 free -g + 池配置 + JuiceFS 默认值
├── p1-baseline-reproduce/
│   ├── randread-r{1..5}.txt + _bw.log        # 128K 默认，5 轮
│   ├── randwrite-true-r{1..5}.txt + _bw.log
│   └── summary.md                            # 轮内/轮间 CV 收敛判定 + 锁定的新基线值（附 vs 01-2d 偏差，仅记录）
├── p2-buffer-control/
│   ├── randread-r{1..5}.txt + _bw.log        # 128K + buf1024
│   ├── randwrite-true-r{1..5}.txt + _bw.log
│   └── summary.md                            # 证伪对照判定
├── p3-matrix/
│   ├── maxfuse-{128k,256k,512k,1m}-buf1024/  # 各含 randread/randwrite/mseqwrite r{1..5}
│   ├── maxbg-{50,100,200}/
│   ├── maxuploads-{150,300}/                 # 可选
│   └── summary.md                            # 矩阵 BW/slat/CV 全表 + 翻盘判定
├── p4-final/
│   ├── best-combo-9item-r{1..5}.txt + _bw.log # 最优组合完整 9 项基线
│   └── summary.md                            # 归一化收益表 + trade-off + 推荐
└── summary.md                                # 四阶段总判定 + 对 02 计划 B 线的修正建议
```

**输出分析报告（强制）**：完成后建 `doc/perf-report/02-2-baseline-reproduce-and-buffer-report.md`，正文含：
- P1 基线是否**测准锁定**（关键：轮内/轮间是否收敛；与 01-2d 偏差仅记录，>10% 不算失败，注明以本次收敛值为准）。
- P2 总闸假说证伪结果（机制是否如 §0.3 预期）。
- P3 矩阵：哪些"之前无效"的配置在放开 buffer 后翻盘，哪些确认无效。
- P4：稳定基线归一化的可信收益表 + 最优配置推荐 + 读写 trade-off。
- 对 02 计划 §五 B1/B2 的修正建议（尤其推翻/确认 02-1b 的 `256K+buf1024` 收益结论）。

实测追加 `doc/deploy-log/results-table.md`。

---

## 五、通用注意事项

1. **数据统计口径**：§8.3 稳态中位数（截开头 1/4），保留全部 128 份 per-job bw_log，**禁止** bw_log×numjobs 外推。
2. **REPEAT≥5**（对抗基线漂移，比常规 3 更严），取中位数（第 3 大值），每格报告 CV。
3. **冷态净化**：每轮跑前 drop_caches（157 + 3 slave）。
4. **变量隔离**：P2/P3 每次只改一个变量（buffer-size / max-fuse-io / max_background / max-uploads 分开测），杜绝叠加导致归因不清。
5. **基线优先**：**步骤 1 未收敛锁定不得进入步骤 2–4**（本任务的核心纪律）。判准是收敛（轮内+轮间 CV<5%），**不是**贴近 01-2d 旧值——旧基线本身可能有偏差，本次以收敛值为权威新基线。
6. **fast_read 稳定化**：若 CV 压不下来，用 `fast_read=true` 作为稳定化手段并记录；测毕按 §六 R3 处理。
7. **Ceph 侧调优前置验证**：`ceph config set` 运行时参数（如 `osd_memory_target`）可能触发 BlueStore 缓存重整，导致锁定布局失效（等效于一次缓存重抽签）。P2 前需做 15min 对照：锁定布局下 `ceph config set` 一个无害参数 → 连测 5 轮 randread 看 CV。若 CV 仍 <2% → Ceph 侧调优可用锁定布局法（±5%）；若 CV 显著升高 → 归入交错 A/B 多轮抽签对比类（±10%，见 `interleaved-ab-tuning-skill.md`）。需 restart OSD 的 Ceph 侧调优**必然**失效锁定布局（C 组实测 CV=13%），直接归入交错 A/B 类。

---

## 六、红线汇总

- **R1（157 内存红线）**：buffer-size 上限 ≤ min(157 可用内存的一半, 4096MB)。调 buffer 前后监控 157 内存，**不得因测试把 client 内存打爆影响 WekaIO**。每次 mount 后确认 JuiceFS 进程 RSS 与系统剩余内存。
- **R2（157 通用红线）**：禁动 157 内核 / 100GbE NIC / RoCE / md0 / WekaIO。buffer-size / max-fuse-io / mount 参数变更不触碰内核网卡，但须确认 WekaIO 不受影响。
- **R3（fast_read 回滚）**：若用 `fast_read=true` 稳定化，测毕回滚为 `false`（除非同时确认有净收益，交用户拍板），不擅自保持。
- **R4（配置可回滚）**：所有 ceph config / pool set 变更前 `ceph osd dump` 快照。
- **R5（不破坏生产池）**：优先用诊断池；若必须用生产 EC 池，测毕恢复默认属性。
- **R6（BeeGFS 错峰）**：与 BeeGFS 错峰用同批 NVMe 盘。

---

## 七、执行顺序与依赖

```
步骤 0 环境前置（含 157 free -g）── 必须先做
     │
     ▼
步骤 1（P1）测准并锁定 128K 默认基线 ── 核心门槛
     │
     ├─ 收敛（轮内 CV<5% 且轮间收敛）→ 锁定为权威新基线（分母），继续
     │   （与 01-2d ±10% 偏差仅记录、不作门槛）
     └─ 未收敛 → 排查/加大轮间清理（fast_read/scrub/compaction/cluster_net/重部署），收敛前不得继续
          │
          ▼
步骤 2（P2）buffer 证伪对照（128K + buf1024）── 机制锚点
     │
     ├─ 写无变化 → 假说边界成立，继续
     └─ 写变化 → 机制误判，重评估假说
          │
          ▼
步骤 3（P3）矩阵重扫（buf1024 打底）
     ├─ max-fuse-io {128K,256K,512K,1M}   ← 重点：512K/1M 读是否翻盘 + mseqwrite +89% 复现
     ├─ max_background {50,100,200}        ← 内核侧 + 用户态同调
     ├─ max-uploads {150,300}（可选）
     └─ 不扫 async_dio / objecter（机制无关）
          │
          ▼
步骤 4（P4）最优组合 9 项基线复测 + 归一化收益表 + trade-off
          │
          ▼
汇总 → 报告 → 修正 02 计划 §五 B1/B2（确认/推翻 256K+buf1024 收益）
```

---

## 八、与 02 计划文档的衔接

本任务是 02 计划 §五 B 线的**前置校准**，产出直接用于修正计划文档中以下待订正项（见 `/tmp/02-plan-corrections.md`）：
- §五 B1「`--max-fuse-io 256K --buffer-size 1024` 当前最优配置（读+16%/写+70%）」→ 本任务给出**基于稳定基线的可信收益**替换之。
- §8.1 优先级表 B1「已完成」→ 依本任务结果更新。
- 新增结论：buffer-size 作为"总闸"对哪些配置有效（P3 矩阵）。
