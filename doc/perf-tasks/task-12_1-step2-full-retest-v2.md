# 任务（GLM）12.1-步骤2修订版：全量重测（口径校准——fio 瞬时带宽稳态中位数 + 放大单列 + 网卡原始字节）

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-10
> **背景**：上一版 step2（`results/memdisk-fullretest-128g-20260710/`）测试流程/净态/单变量都合格，但**数据口径有三处硬伤，导致达标值不可信，必须重测**：
> 1. **fio 未开 bw_log**，只有全程平均值，而写类平均值被开头 JuiceFS 客户端写缓冲暂态拉高（randwrite 报 127 MB/s > 千兆网卡上限，物理不可能，是缓冲假象）。
> 2. **达标口径错**：曾想用 object put 稳态替代——但 object put 是**落后端物理带宽（含写放大 + EC 1.5×）**，不是有效数据带宽；若 put=100 有 2× 放大则有效只有 50，用 put 会把放大洗白得出假达标。
> 3. **网卡只存了汇总值、没存原始 /proc/net/dev 逐秒字节**，且 Duration 未对齐 fio 稳态，导致 RX(89) < object get(110) 的物理矛盾，网卡判据不可信。
> **本任务 = 用校准后的口径重跑全量。** 部署形态不变（WAL/DB 独立 + DATA 独立，已就绪），layout 仍 128G。真盘对比暂降为参考（口径不同），本轮以内存盘新口径准确值为汇报主数据。

---

## 0. 口径校准（本任务的灵魂，务必先读）
**验收看的是"有效数据带宽"= 应用真正读写的有效字节速率 = fio 看到的速率。但取值方式变了：**

1. **达标值 = fio 瞬时带宽曲线的稳态段中位数**（不是 fio 全程平均、不是 max）。
   - 所有 fio 项加 `--write_bw_log=<name> --log_avg_msec=1000`（写类）/ `--read_bw_log=<name> --log_avg_msec=1000`（读类），每秒输出一个瞬时带宽点。
   - 测完对 `<name>_bw.*.log` 逐秒序列：**截掉开头缓冲暂态段**（randwrite/写类暂态约前 10-15s，看曲线从虚高跌落到平台的拐点，实际按曲线定），取**剩余稳态段的中位数**作为达标值；同时报均值/min/max/stddev/样本数 + 简述曲线形状。
2. **object put/get 只用于算放大，绝不当达标值**：
   - 写放大 = object put 稳态 / fio 有效写稳态；读放大 = object get 稳态 / fio 有效读稳态。**单列报告**。
   - 三者应满足 **fio 有效 ≤ 客户端网卡 ≤ object（放大后）**。若不满足（如上一版 RX<get），说明采样错，排查。
3. **网卡存原始字节**：`/proc/net/dev` 逐秒**原始行**落盘（timestamp + eno1 整行，不要只存算好的 MB/s），窗口覆盖 fio 全程；分析时**只取与 fio 稳态段对齐的时段**做字节差分。报稳态 RX/TX 中位数 + 占千兆(118-123)百分比。

## 1. 拉长时间（保证稳态样本足够）
- **随机类**（randread/randwrite/randrw）：`--time_based --runtime=180s`（原 60s→180s）。覆盖写不涨容量，放心拉长。截前 10-15s 暂态后剩 ~165 稳态点，中位数扎实。
- **顺序类**（seqread/seqwrite/multi-seqread/multi-seqwrite）：改 `--time_based --runtime=180s`（原 size=4G 写完即停 ~38s）。
  - ⚠️ **seqread/multi-seqread 缓存陷阱**：time_based 反复读同一 4G 文件，第 2 遍起可能命中内核页缓存/JuiceFS 缓冲 → 假高。**防护**：① 挂载已 `--cache-size 0`（关 JuiceFS 读缓存）；② 读类**每次 fio 前 `echo 3 > /proc/sys/vm/drop_caches`（客户端）**；③ 更稳妥——把 seqread 的文件加大到 `--size=32G`（单流 180s 读不完一遍，避免重复命中；multi 16 job 每 4G→改每 job 读大文件的不同区段）。**由你选防护方式并落盘说明，报告须验证 seqread 不是缓存命中（对账 object get：若 get≈0 而 fio 高 = 缓存命中，作废）**。
  - 顺序写类 time_based 反复覆写同一文件，不涨容量。

## 2. 其余口径（沿用上一版，已验证 OK 的部分不变）
- 二进制 patch `1.3.1+2025-12-02.e0032b2a`（开跑确认落盘）。
- A组 `--cache-size 0 --max-uploads 150`；B组 `+ --max-readahead 0`。单变量。
- **组间净态隔离**（A→B 切换清池 + compact 到 0 + iostat idle + 确认池回空，且 **gc 要在 mounted 状态做**——上一版异常1：umount 后 gc 会 skip 全部对象致池 92% 假满）。
- **顺序类↔layout 分时清理**（内存盘池 294G raw 放不下 seq 64G + layout 128G 同存）。
- 边测边盯 OSD %USE（≥85% 停）。rand 3 轮。
- layout 仍 128 jobs×1G=128G（layout 也加 bw_log 取稳态中位数）。

## 3. 每项采集（齐全,缺一不可）
1. **fio + bw_log**（`_bw.log` 逐秒瞬时带宽，本任务核心）。
2. **网卡原始 /proc/net/dev 逐秒行**（覆盖 fio 全程，含 timestamp）。
3. **juicefs stats**（`--interval 1`，覆盖全程，用于算放大 + 验缓存命中）。
4. **juicefs 进程 CPU**（pidstat）。
5. 读类额外：drop_caches 记录 + object get 验证非缓存命中。

## 4. 判据（回报 opencode）
1. **全量 8 项 A/B 达标表**：每项 fio 瞬时带宽**稳态中位数**（+ 均值/max/stddev/样本数/曲线形状），过 59 否。**明确对比"稳态中位数 vs 全程平均"差多少**（暴露暂态污染程度）。
2. **放大表**（单列）：每项写放大(put/fio)、读放大(get/fio)；验证 fio有效 ≤ 网卡 ≤ object。
3. **网卡**：每项稳态 RX/TX 中位数（原始字节差分算），占千兆%，是否撞墙。**验证不再有 RX<get 矛盾**。
4. **A vs B（关预读）**：ra0 对每项稳态中位数的影响。
5. **seqread/multi-seqwrite 画像**：稳态中位数 + 网卡占用 + 放大 + stats 并发/lat（为步骤3铺垫）。验证 seqread 非缓存命中。
6. **randwrite 127 复核**：新口径下 randwrite 稳态中位数是多少（应 ≤ 网卡上限），确认 127 是暂态假象。
7. 容量安全、组间/分时净态干净、缓存陷阱防护有效。
8. 异常如实列。

## 5. 明确不做
- ❌ 不用 fio 全程平均/ max 当达标值（用稳态中位数）。
- ❌ 不用 object put/get 当达标值（只算放大，单列）。
- ❌ 网卡不许只存汇总 MB/s（必存原始 /proc/net/dev 逐秒行）。
- ❌ 读类不许在缓存命中态测（drop_caches + 验 object get 非零）。
- ❌ gc 不许在 umount 态做（会 skip 致假满）。
- ❌ 不改 OSD 部署/config/验收口径；不改单变量设计。
- ❌ 无数据支撑写结论；不深挖 seqread/multi-seqwrite 根因（留步骤3）。

## 6. 产出目录
`results/memdisk-fullretest-128g-v2-20260710/`：
```
├── ops.log / version.txt / commands.sh
├── A/  B/   每项: fio-*.txt + *_bw.log(逐秒瞬时) + nic-*-raw.txt(原始/proc/net/dev行) + jfs-stats-*.txt + jfs-proc-*.txt + dropcache-*.txt(读类)
├── clean-seq-A/B.txt + clean-between-AB.txt   净态证明
├── cephdf-write-monitor.txt
├── bw-steady-analysis.md    每项稳态中位数 vs 全程平均 对比 + 截尾拐点说明
├── amplification.md         放大表(put/get 除以 fio有效) + 三者关系验证
└── report.md                8 个判据
```
