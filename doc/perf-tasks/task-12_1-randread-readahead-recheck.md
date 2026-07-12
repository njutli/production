# 任务（GLM）12.1：随机读补证定位 —— 补 `--max-readahead 0` 重测 + 网卡/stats 坐实

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-09
> 来源：`12-post-diskbottleneck-plan.md` 步骤 12.1（主线 B 读侧第一步）。
> 背景：全内存盘 JuiceFS 冷态基线（`results/node2-raid-fix-memdisk-ceiling-20260709/full-memdisk/jfs-cold-mu150/`）写类全达标，但 **randread 54、randrw 读 48 未达标**。该轮挂载只带了 `--cache-size 0 --max-uploads 150`，**漏了 `--max-readahead 0`**。
> 核心怀疑：**randread 54 未达标极可能只是漏关预读**（历史已证 readahead 贡献 1.73× 放大，patch + `--max-readahead 0` 冷态 randread 曾达 77.7-98，见 `11-random-read-tuning-summary.md`）。本任务补上预读关停重测，并**同采网卡 RX + juicefs stats**，坐实"是漏关预读，还是有 patch/readahead 之外的新放大源"。

---

## 0. 要回答的三个问题（GLM 请先读）
1. **补 `--max-readahead 0` 后，randread 能否从 54 冲到历史水平（77-98）、过 59？**
2. **未达标时网卡打没打满？**（客户端 RX 实测）—— 二分：没满=卡在 JuiceFS 读路径软件；满了=读放大把有效读压低。
3. **patch 在当前全内存盘重建环境里是否仍生效？**（`loadRange` 修复，避免"环境重建后 patch 丢了"这种假象）

### 历史账（随机读放大，供参考不预设结论）
| 层 | 放大/效果 | 手段 | 状态 |
|----|----|----|----|
| v1.3.1 `loadRange` bug | 客户端全量读 256K | 单行 patch（`1.3.1+2025-12-02.e0032b2a`）| ✅ 已解 |
| JuiceFS readahead 预读 | **1.73×** 放大 | `--max-readahead 0` | ✅ 手段已知，本轮补上 |
| 残余（EC 1.04× + messenger ~0.45×）| 1.51× | 架构固有 | 接受 |
- 历史最优：patch + `--max-readahead 0`，冷态 randread **77.7**（真盘时代）；专项 ra0 曾达 98.3。**本轮后端是全内存盘（rados randread 已 112），若补预读，randread 应 ≥ 历史 77.7、很可能更高。**
- 关 prefetch 单独无益甚至略降（77.7→75.9），**本任务不关 prefetch**，只补 `--max-readahead 0`。

---

## 1. 铁律
1. **环境**：沿用当前全内存盘配置（6 OSD DATA+WAL/DB 全 tmpfs，SSD 参数），不改后端。
2. **二进制确认**：开跑先 `juicefs --version`，落盘确认含 `1.3.1+2025-12-02.e0032b2a`（patch 标识）。**若不含 patch，先说明并停下等指示**（不能在无 patch 下测随机读）。
3. **挂载口径**：`--cache-size 0 --max-uploads 150 --max-readahead 0`（相比上轮**只多 `--max-readahead 0` 这一项**，其余完全一致，保证单变量对比）。不开 writeback、不关 prefetch、不加 cache。
4. **只认 r1**（冷态），但每项跑 3 轮看方差；**不取 MAX**（报告禁止用 MAX 口径）。
5. **layout 复用/重建**：与上轮同口径（128j，tmpfs 空间限制下用 512M×128=64G）；randread 复用 layout，randrw 用 fresh。
6. 每项冷态：客户端 `echo 3 > /proc/sys/vm/drop_caches`；net 采集本地前台。
7. **一切结论对账原始 fio/网卡/stats；无数据标"未取证"；不手填 summary。**

---

## 2. 实验：randread + randrw 各 3 轮，同采网卡 + stats

### 2.1 对照设计（单变量：加 `--max-readahead 0`）
| 组 | 挂载 | 项 | 目的 |
|----|----|----|----|
| 基线（引用上轮）| cache=0 mu=150 | randread 54 / randrw 48 | 上轮已有，直接引用对比 |
| **本轮** | cache=0 mu=150 **+ max-readahead 0** | randread 3 轮 + randrw 3 轮 | 看补预读后是否达标 |

- randread：`fio ... -rw=randread -bs=256K -iodepth=128 -numjobs=128 -runtime=60`（与上轮完全同 fio 参数，只改挂载）。
- randrw：同上 `-rw=randrw -rwmixread=50`。
- 顺便复测 seqread 1 次（看预读关停对顺序读有无退化，历史顺序读 `--max-readahead 0` 有退化风险，但读侧影响小，记录即可）。

### 2.2 同步采集（本任务的关键，上轮全缺）
每个随机项运行期同时采：
1. **客户端 eno1 网卡 RX**（随机读是收数据，看 RX）：用 `/proc/net/dev` eno1 RX 字节差分（开测前先 `grep eno1 /proc/net/dev` 自检列位，避免上轮 sar 解析失败重演），落盘 `nic-<项>.txt`，报告给"稳态 RX MB/s = 118 的几 %"。
2. **juicefs stats**：`juicefs stats <挂载点> -l 1 --interval 1 --count <runtime+5> > jfs-stats-<项>.txt`，关注 object get 带宽/并发、fuse read、meta ops。
3. **读放大量化**：fio 有效读字节（io=xxx）vs 客户端 RX 字节 vs object get 字节（`juicefs stats` 或测前后 `rados df` 的 `juicefs-data` RD 差值）。给放大倍数 = RX / fio有效读。
4. juicefs 进程 CPU（`pidstat -p <pid> 1`），看是否单核瓶颈。

---

## 3. 判据（回报 opencode）
1. **补预读后 randread r1 = 多少？过 59 否？**
   - **冲到 77-98、网卡 RX 逼近线速** → 坐实"randread 未达标只是漏关预读，无新放大源"，**randread 收工**。
   - **仍卡 ~54 左右** → 有 patch/readahead 之外的新因素 → 报告网卡/stats/CPU 证据供深挖（pprof/strace 下一步）。
2. **网卡 RX 实测**：未达标项 RX 占线速几 %（没满=JuiceFS 读路径软件瓶颈；满了=放大）。
3. **读放大倍数**：RX/有效读、object get/有效读 → readahead 关停后残余放大是否 ≈ 历史 1.51×。
4. **patch 生效确认**：版本号 + randread 单 op 是否仍全量读放大（对比 patch 前 2.17×）。
5. **randrw**：补预读后读写各多少？randrw 是否仍是硬骨头（历史 patch/调参无效）→ 是否转 12.4 单独诊断。
6. 异常（版本不符、采集失败、layout 缩小影响）如实列。

## 4. 明确不做
- ❌ 不关 prefetch（历史证无益）；不开 writeback、不加 cache。
- ❌ 不取 MAX / 不用含缓冲暂态均值下结论（randread 稳态，取 r1）。
- ❌ 网卡不许"从带宽推算"，用 /proc/net/dev 实测（先自检列位）。
- ❌ 不改后端配置（沿用全内存盘）；不改验收口径。
- ❌ 无数据支撑写进结论。

## 5. 产出目录
`results/randread-readahead-recheck-20260709/`：
```
├── ops.log                         # 全程 + 版本确认 + 挂载参数
├── version.txt                     # juicefs --version（patch 标识）
├── fio-randread-r{1,2,3}.txt       # 补 max-readahead 0 后逐轮
├── fio-randrw-r{1,2,3}.txt
├── fio-seqread.txt                 # 顺便看预读关停对顺序读影响
├── nic-randread.txt / nic-randrw.txt   # 客户端 eno1 RX 字节差分（实测）
├── jfs-stats-randread.txt / jfs-stats-randrw.txt
├── jfs-proc.txt                    # juicefs 进程 CPU
└── report.md                       # 三问结论 + 放大量化 + randread 是否收工 + randrw 去向
```
