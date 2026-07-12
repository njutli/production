# 任务（GLM）12.1-步骤2重测：定位 gc 失效 + A/B 全量干净重测（一次连续，不拼接）

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-10
> **背景**：上一版 v2（`results/memdisk-fullretest-128g-v2-20260710/`）口径校准（bw_log 稳态中位数）方向对，但**过程严重污染，写类数据不可信，必须整体重测**：
> - 经历 3 次 attempt + 池删重建 3 次（pool 54→57→58）+ block-size 误改，A 组 seq 来自 attempt1、rand 来自 attempt3，**拼接而成**，不可复现。
> - **写类全部在高压脏池里测**：A 组 randwrite/randrw 池涨到 87-88.5%（过 85% nearfull），B 组更从 51G 残留起跑、涨到 92%（backfillfull，Ceph 限流降级）。B randwrite stddev 25-35、min 13-34 剧烈波动就是降级佐证。
> - **randwrite/randrw 被迫从 180s 改 60s**（怕池满），违背拉长稳态的目的。
> - 根子：**gc --delete 对覆盖写产生的 orphan slice 全 skip**，池被撑满。
> **本轮目标**：先搞清 gc 为何 skip，保证环境能持续干净；然后**一次连续、同池、同 block-size、全 180s** 重测 A/B 全量 8 项（seq + rand 都重测，不复用旧数据）。
> **仍可信、本轮作对照**：上一版 randread A=54 FAIL / B=108 PASS（纯读不受污染）——本轮应复现，若复现即互证。

---

## 阶段 A：定位 gc --delete 失效根因（前置，先做）

### A.1 关键线索（先验证，别急着下 bug 结论）
上一版 ops.log 有矛盾：**18:23「gc --delete → 池回空 10MiB」是成功的**（clean-seq-A 确实回空），但 rand 阶段「gc --delete skipped 705K objects」。同是 gc --delete，一成一败。
- **强烈怀疑：gc 不是失效，而是"slice 仍被引用时正常 skip"**——成功那次是**删了文件 + umount/静止后**再 gc；失败那次可能是**文件还在 / fio 刚跑完 slice 未解引用 / 边写边 gc**。
- gc 的语义：只回收**无引用的 orphan**。覆盖写 180s×多轮产生大量旧 slice，若 JuiceFS 的 slice compaction 跟不上写入、或文件未删就 gc，slice 仍被视为有效 → 正常 skip，不是 bug。

### A.2 要做的验证（落盘 gc 原始输出）
1. 复现：干净池 → 挂载 → 写一个文件 → randwrite 覆盖它 60s → **不删文件**直接 `juicefs gc --delete`，记录 skip/valid/leaked 数字。
2. 对照：同样场景，**先删文件 + 等几秒** 再 `juicefs gc --delete`，看是否正常回收。
3. 对照：`juicefs compact` 是否能压实旧 slice（compaction 才是回收覆盖写旧 slice 的正道，gc 是清 orphan）。
4. 查 JuiceFS 文档/config：`--trash-days`（当前 format 是否 trash-days 0？trash 不为 0 时删除的数据进 trash 不回收）、slice compaction 相关参数。
5. **结论**：gc skip 是"正常语义（slice 有引用/在 trash）"还是"真 bug"？回收覆盖写旧空间的**正确手段**是什么（gc --delete？compact？删文件+gc？trash 设置？）。

### A.3 据结论定"可持续干净"方案（供阶段 B 用）
- **能靠正确手段回收**（如每项后删文件+gc 或 compact 生效）→ 阶段 B 每项/每轮后用该手段清理，池不涨。
- **回收仍跟不上写入**（真清不动）→ 用绕过方案（二选一，落盘理由）：
  - **方案①每轮重建池**：每个 randwrite/randrw 轮次后删池重建、从空池起跑（最干净，慢）。
  - **方案②扩大 DATA tmpfs**：当前每 OSD 45G。三节点内存 available ~172G（128G 时）仍宽裕，可把 DATA tmpfs 扩到每 OSD ~70-80G（需停 OSD 重建，见步骤1的做法），让"128G layout + 覆盖写 slice 累积"也撑得住 180s×3 轮不撞 85%。**由你算内存账后选**。

---

## 阶段 B：A/B 全量干净重测（阶段 A 就绪后，一次连续）

### B.0 铁律
1. **一次连续测完，不拼接**：不复用任何旧 attempt 数据。seq + rand 全部本轮重测。若中途池满/崩溃，**整轮作废重来**，不允许拼接不同 attempt。
2. **block-size 全程 256**（KiB）：format 后 `juicefs config` 落盘确认 `BlockSize=256`（**不是 4096**，上一版 commands.sh 残留 4096 是误导，务必核对）。二进制 patch `e0032b2a` 确认。
3. **净态起跑 + 每项净态**：每项（尤其写类）开测前池占用回到基线（借阶段 A 的正确清理手段），**开测前 `ceph df` 落盘证明 OSD %USE 未过 80%**；全程盯 %USE，任一 OSD ≥85% 立即停、整轮作废。
4. **全 180s + time_based + bw_log**（含 randwrite/randrw，靠阶段 A 方案保证不撑爆池，**不许再降到 60s**）。
5. 组间净态隔离：A→B 切换清池到空（gc 在 **mounted** 态做）+ compact + 确认回空 + 落盘。
6. 顺序类↔layout 分时清理（池容量约束仍在，除非阶段 A 选了扩 tmpfs）。

### B.1 口径（沿用 v2 已定，不变）
- A 组 `--cache-size 0 --max-uploads 150`；B 组 `+ --max-readahead 0`。单变量。
- **达标值 = fio 瞬时带宽稳态中位数**（截暂态：写类跳前 10-15s，读类跳前 5s），非全程平均、非 max。
- **randrw 的 bw_log 必须聚合 128 个 job 分文件**（`_bw.<job>.log`）按时间戳求和，分读(dir=0)/写(dir=1)再取稳态中位数。**上一版只看单 job 文件误判"数据点过少"退回用平均值——这是分析错误，本轮禁止；128 job 聚合后每秒样本充足。**
- object put/get 只算放大单列，不当达标值。
- 网卡存**原始 /proc/net/dev 逐秒行**，只取 fio 稳态段差分。读类 drop_caches + 大文件防缓存命中 + object get 非零验证。

### B.2 全量项（A/B 各一遍，本轮全部重测）
seq_dir：prep → seqread → seqwrite → multi-seqread → multi-seqwrite（psync，全 time_based 180s，seqread 用 20G 大文件防缓存）
→ 分时清理 → layout 128G → test_dir：randread → randwrite → randrw（libaio direct=1 iodepth=128 numjobs=128，全 180s，3 轮）

### B.3 采集（每项）
fio + bw_log（128 job 分文件都留）+ 原始 /proc/net/dev 逐秒 + juicefs stats（--interval 1）+ pidstat + 写类前后 ceph df（%USE 证明未降级）+ 读类 drop_caches 记录。

## 判据（回报 opencode）
1. **阶段 A**：gc skip 是正常语义还是 bug？回收覆盖写旧空间的正确手段是什么？阶段 B 用了哪个清理/绕过方案？（附 gc/compact 原始输出）
2. **全量 8 项 A/B 达标表**：fio 稳态中位数（+均值/min/max/stddev/N/曲线）+ 过 59。**randwrite/randrw 必须是 180s 且池未过 85%**（附每项开测前 %USE），否则标注不可信。
3. randread 是否复现上一版（A~54 / B~108）？ra0 根因是否再证。
4. randrw：128 job 聚合后稳态中位数（读/写），过 59 否；确认无"超网卡物理不可能值"（上一版 164 是错误）。
5. randwrite 稳态中位数（应 ≤ 网卡 ~117），127 假象再证。
6. 放大表、网卡（无 RX<get 矛盾）、净态证明（每项 %USE、组间回空）。
7. block-size=256 确认、单次连续未拼接确认。
8. 异常如实列。

## 明确不做
- ❌ 不拼接多 attempt；中途污染就整轮作废重来。
- ❌ randwrite/randrw 不许降到 60s（靠阶段 A 方案撑住 180s）。
- ❌ randrw 不许因"单 job 点少"退回用 fio 平均（必须 128 job 聚合）。
- ❌ 不用平均/max/object put-get 当达标值。
- ❌ block-size 不许是 4096（必须 256，落盘 config 确认）。
- ❌ 网卡只存汇总；读类缓存命中态测；gc 在 umount 态做。
- ❌ 不改 OSD 部署（除非阶段 A 选扩 tmpfs 方案，那按步骤1做法扩并落盘）；不改验收口径/单变量。

## 产出目录
`results/memdisk-fullretest-128g-v3-20260711/`：
```
├── ops.log（全程连续时间线，含阶段A gc定位 + 阶段B每项，不留矛盾）
├── version.txt / config-blocksize.txt（BlockSize=256 证明）/ commands.sh（实际执行，无 4096 残留）
├── gc-diagnosis/  （gc/compact 原始输出 + A.2 各对照 + 结论）
├── A/  B/  每项 fio + bw_log(128分文件) + nic原始 + stats + proc + dropcache
├── cephdf-per-item.txt（每项开测前 %USE 证明未降级）
├── clean-*.txt（净态证明）
├── bw-steady-analysis.md（含 randrw 128job 聚合稳态中位数）
├── amplification.md
└── report.md（8 判据）
```
