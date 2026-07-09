# 14 执行任务（deepseek）：步骤 2 —— 写侧冲线

> 出题：opencode（规划/校验）　执行：deepseek　日期：2026-07-04
> 依据：`doc/perf-analysis/11-next-stage-plan.md` §五 步骤 2 + §七。
> 本文是**给 deepseek 的执行任务书**，deepseek 严格照此执行、采数、如实回报，**不得跳测、不得拼旧数、不得编造**。

---

## 0. 一句话目标

在 **patched v1.3.1 + 冷态(cache=0) + 默认 ra** 下，用**纯后端手段（max-uploads / buffer-size，绝不开 writeback）**，
把当前贴线的**三项写类**推过 **59 MB/s**，把冷态达标数从 2 项拉到 5 项。

三项目标（当前冷态 r1 值 → 目标 59）：

| 项 | 当前(冷 r1) | 缺口 | fio 形态 |
|----|:---:|:---:|----|
| 顺序写(单) | 57.0 | 差 2.0 | seqwrite，bs=256K size=4G numjobs=1 end_fsync=1 |
| 随机写 | 55.7 | 差 3.3 | randwrite，bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s |
| 多线程写 | 43.7 | 差 15.3 | multi-seqwrite，bs=256K size=4G numjobs=16 end_fsync=1 |

> 只测这三项，**不要测读类/randrw**（那是步骤 2b/3，本任务不碰）。

---

## 1. 铁律（违反即数据作废，务必逐条遵守）

1. **二进制**：必须是 patched `/usr/local/bin/juicefs`（版本串含 `1.3.1+2025-12-02.e0032b2a`）。
   开跑前 `juicefs --version` 确认并写进 env-snapshot。**不是这个版本立即停手上报。**
2. **冷态口径**：挂载**必须显式** `--cache-size 0`（默认是 100G！）。`--cache-size 0` 连带关掉 writeback+prefetch，
   这正是我们要的"真实后端能力"。**绝不加 `--writeback`、不加大 cache。**
3. **默认 ra**：**不要**传 `--max-readahead`（保持默认）。ra=0 会砸顺序写布局，禁用。
4. **只认 r1**：每格跑 3 轮，但**结论只取 r1（第 1 轮）**。r2/r3 只用来看稳定性，不进达标判定
   （避免 OSD BlueStore cache 预热虚高）。
5. **每轮测前清缓存**：客户端 `drop_caches` + **3 台 OSD 全部 drop**（用下方 `drop_all_caches` 函数，
   **逐台检查返回码**，任何一台失败要在日志里明确标 FAILED，不能静默略过）。
6. **NIC_RX 红线**：每格采 `eno1` RX 增量（MB）。**任何写值 > 79 或 NIC_RX 明显偏离，立即回查
   writeback 泄漏 / cache 命中，标红上报，不得当达标数**。79 = 千兆线速 118 ÷ EC 写放大 1.5。
7. **对账原始 fio**：summary 里每个数必须能在对应 `*.txt` 原始 fio 输出里找到出处，
   **禁止手填、禁止跨目录拼旧数**。
8. **单 master 串行**：一次只跑一个 fio；杀 fio 后等到 `pgrep -x fio` 为空再起下一个。
9. **前台/后台**：整轮扫描耗时长，用后台方式起，**确认进入 fio 后再放手**：
   `setsid bash <脚本> </dev/null >run.log 2>&1 & disown`；用 `pgrep -x fio` / `tail run.log` 观察。

---

## 2. 实验设计（单变量扫描，patched + cache=0 冷态）

基线：`--cache-size 0 --max-uploads 150`（步骤 1 交付起点）。

### A. max-uploads 扫描（最可能奏效的杠杆）
固定 buffer 默认(300M)，扫 mu：

| 格子 | 挂载参数 |
|----|----|
| A1(基线) | `--cache-size 0 --max-uploads 150` |
| A2 | `--cache-size 0 --max-uploads 200` |
| A3 | `--cache-size 0 --max-uploads 300` |

### B. buffer-size 扫描
固定 mu 用 A 的最优值（记为 `mu*`），扫 buffer：

| 格子 | 挂载参数 |
|----|----|
| B1 | `--cache-size 0 --max-uploads <mu*> --buffer-size 300`（=A 最优，可复用不重跑） |
| B2 | `--cache-size 0 --max-uploads <mu*> --buffer-size 1024` |

> `--buffer-size` 单位 MB（300=300M，1024=1G）。

### C. 组合确认
取 A、B 各自最优组合再跑一轮确认是否叠加（若 B2 就是最优则 C 免跑，注明即可）。

> **依赖说明**：B 要等 A 出结果拿到 `mu*` 才能定；C 要等 B。所以 **A 三格先跑完 → 定 mu* → 再跑 B → 再定 C**，串行推进，不要一次全开。

---

## 3. 每格的采集项（写进 summary 表）

每格、每项（seqwrite / randwrite / multi-seqwrite）× 3 轮，记录：

- `READ / WRITE` 带宽（从原始 fio）——写项只看 WRITE。
- `NIC_RX`（eno1 RX 增量 MB）。
- **OSD op_w perf**（在 fio 运行窗口内，对 6 个 OSD 采 `sudo cephadm shell -- ceph daemon osd.X perf dump osd`，
  取 op_w / op_w_latency，前后差值），至少在**每格 r1** 采一次即可（3 轮全采也行）。
  - OSD 映射：node1(.11)=osd0,1；node2(.13)=osd2,3；node3(.14)=osd4,5。

summary 表建议列：`格子 | 挂载参数 | seqwrite(r1) | randwrite(r1) | multi-seqwrite(r1) | NIC_RX | 是否达标 | 备注`。

---

## 4. 复用现成脚本（推荐，减少出错）

顺序写/随机写/多线程写的 fio 形态、drop、bwget/rxget、commands.sh 生成，
**参照 `tests/bench-warm-mu150-full.sh` 与 `tests/bench-cold-mu150-rand.sh`** 里已验证过的函数，
改成"冷态 + 只测三项写 + 每格换挂载参数"即可。要点：

- 挂载：`juicefs mount -d <MOUNT_OPTS> tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs`。
- seqwrite/multi-seqwrite（复用 `run_seq`）：`--bs=256K --size=4G --refill_buffers --end_fsync=1`，单 job / `--numjobs=16 --group_reporting`。
- randwrite（复用 `run_rand`）：`--bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s`。
- 复用已有 128G 布局（randwrite 用 test_dir；seq 用 seq_dir，prep 一次 4G 即可）；**不要 destroy/format/重布局**。
- 每格换挂载前先 `juicefs umount /mnt/juicefs`，`sleep 3` 再挂新参数。
- drop_caches 函数（逐台验返回码）：

```bash
drop_all_caches(){
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || echo "  client drop FAILED"
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    if sshpass -p "TurboAi@303" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        turboai@$ip "echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null" 2>/dev/null; then
      echo "  $ip cache dropped"
    else
      echo "  $ip drop FAILED"
    fi
  done
}
```

> ⚠️ node1(.11) 用密码 `TurboAi@303`；若脚本里连 node2/node3 用 `123456`。本任务 OSD drop 只用 .11/.13/.14，
> .11 密码 `TurboAi@303`、.13/.14 密码 `123456`（照仓库既有脚本明文写法）。

---

## 5. 结果落盘

- 目录：`results/write-push-20260704/`（或带时间戳的子目录），每格一个子目录
  （如 `mu200/`、`mu300/`、`mu300-buf1g/`），内含各 `*.txt` 原始 fio、`summary.md`、`env-snapshot.txt`、
  `commands.sh`、OSD perf dump 采样文件、后台 `run.log`。
- 顶层写一个 `README.md`：三项写类的达标结论表（只用 r1）、最优挂载配置、NIC_RX 核对、
  以及"哪几项过了 59 / 哪项没过、缺口多少"。

---

## 6. 判定与预案

- **达标判定**：某项 **r1 ≥ 59 且 NIC_RX < 118 且 WRITE ≤ 79（未越 EC 写天花板红线）** → 记达标。
- **越线告警**：若某项 WRITE > 79 或 r1 > r2/r3 异常抬高伴随 NIC 异常 → 疑 writeback 泄漏/缓存命中，
  **标红、附原始 fio、暂不认达标**，回报 opencode 复核。
- **多线程写缺口大(15.3)**：若 mu/buffer 扫到顶（mu=300、buffer=1G）仍卡在 ~79 以下过不了 59，
  **如实标"EC 写放大 + 单千兆物理受限"**，不硬凑；这是可接受的结论，转多客户端聚合口径讨论。
- **某项 mu 越大反降**：取拐点值，注明。

---

## 7. 回报给 opencode 的内容（最终一条消息）

1. 三项写类各自的 **r1 达标情况表**（+ 最优挂载参数）。
2. 结果目录路径 + summary/README 位置。
3. NIC_RX 核对结论（有无越线嫌疑）。
4. 任何异常（drop 失败、版本不符、fio 起不来、越 79 红线等）如实列出。
5. **不要自行下结论改验收口径**；软件调不动就如实标缺口，交 opencode/用户判断。

---

## 8. 明确不做

- ❌ 不测顺序读 / 多线程读 / 纯随机读 / randrw（非本任务）。
- ❌ 不开 writeback、不加大 cache、不传 `--max-readahead`。
- ❌ 不 destroy/format/重布局（复用现有 128G 布局）。
- ❌ 不取 3 轮 MAX、不跨目录拼旧数、不手填 summary。
- ❌ 不升级 v1.4（那是步骤 0，另议）。
