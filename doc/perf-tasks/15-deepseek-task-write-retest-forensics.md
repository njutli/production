# 15 执行任务（deepseek）：写侧复测 —— 后端状态控制 + 并发扫描 + stall 取证

> 出题：opencode（规划/校验）　执行：deepseek　日期：2026-07-05（周末，时间宽裕，做扎实）
> 依据：`results/write-push-20260704/`（含 README/analysis）复盘 + 用户三点要求。
> 上一轮问题：①同 mu=150 两次数值差 12–16%，deepseek 归因"旧测被 destroy/layout 污染"（**合理但未取证**）；
> ②多线程写 stall 归因"RocksDB compaction 跟不上 + WAL/DB 共享 SSD"（**方向对但 osd.0/3/5、HEALTH_WARN 文本、compaction 指标全未落盘**）。
> 本轮目标：**用受控实验 + 原始数据取证**，把这两个"猜想"变成"结论或推翻"。

---

## 0. 总原则（本轮最重要，违反即数据作废）

1. **一切结论必须有落盘的原始数据支撑**。上一轮 analysis.md 里的 `HEALTH_WARN ... stalled read in db device of BlueFS`、
   `osd.0/3/5 中招` 在 `results/write-push-20260704/` 里**根本搜不到**——只有一个 `[health check]: stall` 的单词标签。
   **这种"凭观察/记忆写进报告但没存原始数据"的做法本轮禁止。** 每一个 stall、每一次 compaction、每一个 OSD 身份，
   都要有对应的落盘文件能对账。
2. **控后端状态**：每组测试前不仅查 `ceph health`，还要**采集并落盘**后端"数据状态 + 繁忙状态"基线（见 §1），
   确认各组起跑线一致，否则该组作废重跑。
3. **只认 r1 判定达标**（避免 OSD cache 预热虚高），但本轮**每格跑 5 轮**看稳定性/方差（回答"到底稳不稳过 59"）。
4. **二进制**：patched `/usr/local/bin/juicefs`（`juicefs --version` 须含 `1.3.1+2025-12-02.e0032b2a`），开跑前确认并落盘。
5. **冷态口径**：挂载显式 `--cache-size 0`（连带关 writeback+prefetch，这正是要的真实后端能力）；**不传 `--max-readahead`**；不开 writeback、不加大 cache。
6. **单 master 串行**、后台起（`setsid ... </dev/null >run.log 2>&1 & disown`，确认进 fio 再放手）；杀 fio 后等 `pgrep -x fio` 空再起下一个。
7. **NIC 双向都采**：上一轮 `multi-seqwrite NIC_RX=1092.4 MB`（写测却 1GB+ 入流量）是异常信号，本轮必须查清（见 §3 注意）。同时采 **TX**（写测主要看 TX）。

---

## 1. 后端状态基线采集（新增，回答用户"保证后端状态一致"）

封装成函数 `snapshot_backend <tag>`，在**每一格测试开始前**和**该格结束后**各调一次，落盘到 `<格>/backend-<tag>-{before,after}.txt`。至少包含：

```bash
snapshot_backend(){   # $1 = 文件路径前缀
  local f="$1"
  { echo "### date: $(date)"; 
    echo "== ceph health detail =="; sudo ceph health detail 2>&1;
    echo "== ceph status =="; sudo ceph -s 2>&1;
    echo "== osd perf (commit/apply latency) =="; sudo ceph osd perf 2>&1;
    echo "== pool stats =="; sudo ceph df detail 2>&1;
    echo "== osd df (util%) =="; sudo ceph osd df 2>&1;
  } > "${f}.txt" 2>&1
}
```

并且**每台 OSD 节点**（.11/.13/.14）采一次系统繁忙度基线（落盘 `<格>/sys-<tag>-<ip>.txt`）：

```bash
# 在 ceph 节点上采：负载 + SSD 忙碌度 + compaction 迹象
for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
  PW=TurboAi@303; [ "$ip" != 192.168.11.11 ] && PW=123456
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@$ip \
    'echo "== uptime =="; uptime; echo "== iostat 1 3 =="; iostat -x 1 3 2>/dev/null; echo "== disk util =="; cat /proc/loadavg' \
    > "<格>/sys-<tag>-$ip.txt" 2>&1
done
```

> **起跑线一致判据**（写进每格 README）：`ceph health` = HEALTH_OK、无 `slow ops`/`stalled read` 残留、
> `ceph osd perf` 各 OSD commit latency 回落到 idle 水平（无上一轮 compaction 余波）、loadavg 回落。
> **若某格 before 基线显示后端还在 compaction/slow，等它平静(轮询 `ceph health` 到 OK 且 osd perf 回落)再跑**，
> 并把等待过程落盘。这是本轮控变量的核心。

---

## 2. 实验 A：验证/推翻"destroy/layout 污染"假说（回答问题 1）

**假说**（deepseek）：旧测 seqwrite=57/randwrite=54.8 偏低，是因为紧跟在 destroy(21min)+128G layout 之后，OSD RocksDB compaction 未消退。新测 64/63.7 是干净态。

**设计**：在**同一挂载、同一 mu=150 冷态**下，制造三种后端起跑状态，各跑 5 轮 seqwrite + randwrite（只这两项），对比：

| 组 | 后端起跑状态 | 制造方法 |
|----|----|----|
| A-idle | 完全空闲（deepseek 认为的"干净态"） | 挂载前轮询 `ceph health`=OK 且 `ceph osd perf` 回落到 idle，drop 三台 OSD cache，静置 5 min 再测 |
| A-postlayout | 刚经历大写入（模拟旧测污染） | 测前先做一轮 64G 顺序大写入（16job×4G）制造 compaction 积压，**立即**（不等待）测 seqwrite/randwrite |
| A-repeat | 重复 A-idle 3 天内不同时段 | 同 A-idle 口径，换时间点再测一遍，看 idle 态自身方差 |

- **判据**：
  - 若 `A-postlayout` 明显低于 `A-idle`（且 backend 基线显示 postlayout 组 compaction/slow 更重）→ **污染假说成立**，旧测 57/54.8 确实被污染,新测 64/63.7 是真实态。
  - 若 `A-idle` 自身 5 轮就有 ±10% 抖动、且 `A-repeat` 与 `A-idle` 也差一大截 → **主因是运行间方差**，不是污染，"达标"要按多轮中位数重新判定，不能靠单次 r1 高点。
  - 每格必须附 §1 的 before/after 后端基线 + `ceph osd perf` 对比，用数据说话。
- **产出**：`results/write-push-retest-20260705/expA-contamination/`，含三组各自的 5 轮原始 fio + backend 基线 + 一张对比表 + 结论（污染 or 方差 or 两者兼有）。

---

## 3. 实验 B：多线程写并发扫描 + 固定总量对照（回答问题 2 的"减并发/固定总量"）

**上一轮陷阱**：numjobs=1 只写 4G（短跑），numjobs=16 写 64G（马拉松），总量差 16 倍，不是公平对比。本轮拆成两个子实验分离"并发数"与"总写入量"两个变量：

#### 为什么"总写入量"会影响 fio 报的带宽（不只是影响时长）—— 本设计的核心依据

> 直觉上"数据量大只影响测试时长、不影响带宽"在**理想稳态**下成立：后端稳定吐 X MB/s，写 4G 用 4/X 秒、
> 写 64G 用 64/X 秒，平均带宽都是 X。**但 fio 报的是 `平均带宽 = 总数据 ÷ 总时长`，分母里混进了两种非稳态成分，
> 使得不同总量测出的平均带宽不同**：
>
> 1. **起步瞬态被稀释（短测容易虚高/虚低）**：每次 fio 有一段爬坡（建文件、填队列、缓存/连接预热）。
>    若前几秒是半速或"数据先进 buffer 未落盘的虚高"，**4G 短跑整段可能都落在这个瞬态窗口内就结束了**，
>    测到的是瞬态而非稳态；64G 会把这几秒摊薄到 <5%，暴露真实稳态。→ **短测最大的风险是只测到起步瞬态高点。**
> 2. **后端随累计写入量退化（本例主因）**：这正是 BlueFS/RocksDB compaction 问题。
>    写 4G 时 RocksDB 还没积压、OSD 全程顺畅 → 测到"未退化"的高带宽；写 64G 到一定量后 compaction 跟不上、
>    SSD 读写争抢、触发 stall，**后半程真实带宽掉下来**，平均值被低谷拖低。
>    这不是"量大所以时间长"的错觉，而是**量大把后端拖进了退化态，后半段带宽真的变低了**。
>
> **结论**：上一轮 `nj1=64 / nj16=42` 的差，缠着两个原因——"16 并发本身有害" vs "64G 写到后端退化"，分不清。
> 要判断"并发数的纯影响"，**必须把总写入量钉死**（B1）；再用固定 per-job 大小的对照（B2）暴露"短跑 vs 马拉松"混淆。
> 并用 §4 的 OSD perf 时间线看"带宽掉下来的那一刻是否正好 compaction 积压/stall"，用数据坐实退化，而非猜测。

### B1：固定总写入量 = 64G，扫并发数
每格总量都是 64G，只变 numjobs（用 size 抵消）：

| 格 | numjobs | 每 job size | 总量 |
|----|:---:|:---:|:---:|
| B1-nj1 | 1 | 64G | 64G |
| B1-nj2 | 2 | 32G | 64G |
| B1-nj4 | 4 | 16G | 64G |
| B1-nj8 | 8 | 8G | 64G |
| B1-nj16 | 16 | 4G | 64G |

- 冷态 mu=150，`--end_fsync=1 --group_reporting`，bs=256K。
- **每格 5 轮，只认 r1，记录 5 轮全值看方差**。
- 这样"总落盘量一致"，纯看并发数对 aggregate 带宽和 stall 的影响 → 直接回答"减少并发是否更好 / 最优并发点在哪"。

### B2（对照）：固定每 job=4G，扫并发数（重现旧口径，作对照）
| 格 | numjobs | 总量 |
|----|:---:|:---:|
| B2-nj1 | 1 | 4G |
| B2-nj4 | 4 | 16G |
| B2-nj16 | 16 | 64G |

- 用来说明"上一轮 nj1=64 vs nj16=42 的差,有多少是总量差(短跑vs马拉松)造成的假象"。B1 与 B2 一对比,变量就分离清楚了。

> **⚠️ NIC 异常必查**：上一轮 `multi-seqwrite NIC_RX=1092.4 MB`（写测出现 1GB+ 入流量）。本轮每格同时采 **RX 和 TX 增量**，
> 写测理论上 TX 应主导。若再现大 RX，附 `ss -tin`/`nstat` 或说明 fio 是否有 layout/verify 读，查清入流量来源，落盘。

---

## 4. 实验 C：BlueFS stall 取证（回答用户"让 stall 有原始数据"）

**目标**：把 analysis.md 里"osd.0/3/5 中招 / HEALTH_WARN stalled read in db device of BlueFS / RocksDB compaction 跟不上 / WAL/DB 共享 SSD"这一串**猜想逐条取证或推翻**。在 B1-nj16（必触发 stall 的场景）运行期间同步采集：

1. **实时 health 轮询**：整个 multi-seqwrite 运行期间，后台每 5s 采一次 `sudo ceph health detail` 追加到 `expC/health-timeline.txt`（**带时间戳**）。要能看到 `HEALTH_WARN`、`stalled read in db device of BlueFS`、`slow ops` 出现和消失的完整时间线，以及**具体哪些 osd.X**。
2. **OSD perf dump 序列**：运行期间每 10s 对 6 个 OSD 采 `sudo cephadm shell -- ceph daemon osd.X perf dump` 追加落盘（`expC/osd<X>-perf-timeline.txt`），重点字段：
   - `bluefs`: `db_used_bytes`、`log_bytes`、`files_written_wal/sst`、`bytes_written_wal/sst`、`read_random_*`
   - `bluestore`: `kv_sync_lat`、`kv_commit_lat`、`commit_lat`、`state_kv_queued_lat`、`throttle_lat`
   - `rocksdb`: `compact`、`compact_queue_len`、`get`/`submit_latency`
   - `osd`: `op_w`、`op_w_latency`、`subop_w_latency`
   → 用来验证"compaction 跟不上"是否真发生：看 `compact_queue_len` 是否堆积、`kv_sync_lat` 是否飙升、`bluefs read_random` 是否暴涨（对应 stalled read）。
3. **磁盘布局取证（验证"WAL/DB 与 Data 共享 SSD"）**：对每个 OSD 采一次并落盘 `expC/osd-layout.txt`：
   - `sudo ceph osd metadata osd.X`（看 `bluefs_db_devices`/`bluefs_wal_devices`/`bluestore_bdev_devices` 是否同一设备）
   - `sudo cephadm shell -- ceph-volume lvm list`（看 db/wal/data 的 LV/设备）
   - 在各 OSD 节点 `lsblk` / `iostat -x 1` 运行期采样（看是否单块 SSD 同时被读写打满）。
4. **对照实验（关键，验证"进程数 vs OSD 数"无关）**：deepseek 声称"1 个进程写足够久也会 stall"。**用 B1-nj1（1 进程写 64G）验证**：若 nj1 也触发同样的 BlueFS stall（health-timeline 抓到）→ 证明与并发数无关、是写入总量/时长驱动的 compaction 问题；若 nj1 全程无 stall 而 nj16 有 → 说明并发数确实是诱因之一。这条直接判决 deepseek 的核心论断。

- **产出**：`results/write-push-retest-20260705/expC-stall-forensics/`，含 health-timeline、6 个 OSD perf timeline、osd-layout、iostat 采样，以及一份**取证结论**：逐条标注 analysis.md 的 4 个猜想哪些被数据证实、哪些被推翻、哪些仍存疑。

---

## 5. 采什么数据能证实"多进程写不如单进程"的根因（用户直接问）

汇总本计划里为回答这个问题而设计的取证矩阵（deepseek 执行时对号入座）：

| 猜想（你/deepseek 提出的） | 用哪个数据证实/推翻 | 出处 |
|----|----|----|
| 并发数本身有害 | B1（固定总量扫 nj）：若 aggregate 随 nj 单调下降 → 有害；若先升后平 → 不是并发本身 | §3 B1 |
| 其实是"总写入量/时长"造成(短跑vs马拉松) | B1 vs B2 对照：固定总量后 nj1 与 nj16 若差距大幅缩小 → 主因是总量非并发 | §3 B1/B2 |
| RocksDB compaction 跟不上 | OSD perf `compact_queue_len` 堆积 + `kv_sync_lat` 飙升，与带宽下降时间对齐 | §4.2 |
| BlueFS stalled read | `bluefs read_random` 暴涨 + health `stalled read in db device` 时间戳 | §4.1/4.2 |
| WAL/DB 与 Data 共享 SSD 是瓶颈 | `ceph osd metadata`/`ceph-volume lvm list` 证明同设备 + 运行期 `iostat` 单盘读写双高 | §4.3 |
| 与"进程数>OSD数"无关（1进程也 stall） | B1-nj1 是否也触发 stall（health-timeline 判决） | §4.4 |
| EC 写放大 1.5× + 单千兆物理封顶 ~79 | NIC TX 是否逼近 118÷1.5≈79；OSD op_w 后端写入总量 ÷ fio io ≈ 1.5× | §3 NIC + §4.2 |

---

## 6. 结果落盘与回报

- 顶层目录：`results/write-push-retest-20260705/`，子目录 `expA-contamination/`、`expB-concurrency/`、`expC-stall-forensics/`，各含原始 fio、backend 基线、timeline、`commands.sh`、`run.log`。
- 顶层 `README.md`：三个实验各一段结论 + 一张"猜想取证对照表"（§5 那张，逐条标 ✅证实/❌推翻/⚠️存疑 + 数据出处）。
- **回报给 opencode（最终一条消息）**：
  1. 问题 1 结论：57/54.8 vs 64/63.7 到底是污染还是方差(附 A-idle/A-postlayout/A-repeat 数据)。
  2. 问题 2 结论：最优并发点、固定总量后并发的真实影响、多进程不如单进程的**根因（有数据支撑的那个）**。
  3. BlueFS stall 取证结论：analysis.md 4 猜想逐条判决。
  4. 任何异常（NIC 入流量、drop/采集失败、版本不符、越 79 红线）如实列。
  5. **不自行改验收口径、不凭记忆写结论**；无数据支撑的话一律标"存疑/未取证"。

---

## 7. 明确不做

- ❌ 不测读类 / randrw（本轮只写侧）。
- ❌ 不开 writeback、不加大 cache、不传 `--max-readahead`。
- ❌ 不 destroy/format/重布局（A-postlayout 的"大写入"用 fio 顺序写制造即可，复用现卷）。
- ❌ 不取 3/5 轮 MAX；不跨目录拼旧数；不手填 summary；**不把没落盘的观察写进结论**。
- ❌ 不升级 v1.4。
