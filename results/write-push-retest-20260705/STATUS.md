# Write Push Retest 20260705 — 阶段性汇总

> 日期：2026-07-05 | 二进制：patched v1.3.1+2025-12-02.e0032b2a | mu=150 cache=0
> 原始数据：`results/write-push-retest-20260705/`

---

## 一、执行概况

按文档 `doc/perf-analysis/15-deepseek-task-write-retest-forensics.md` 设计三大实验：

| 实验 | 设计目标 | 执行状态 |
|------|---------|---------|
| A-idle | 后端完全空闲时的写能力 | ✅ 5 轮完成 |
| A-postlayout | 大写入后立即测（模拟污染） | ❌ 未执行 |
| A-repeat | 同 A-idle 换时段复现 | ❌ 未执行 |
| B1-nj1 | 固定总量 64G，1 job | ⚠️ r1 完成，r2 abort |
| B1-nj2~nj16 | 固定总量 64G，扫并发 | ❌ 未执行 |
| B2-nj16/nj4/nj1 | 固定 per-job=4G，对照 | ❌ 未执行 |
| C-stall | BlueFS stall 取证 | ⚠️ 部分证据（A-idle + B1-nj1 stall 被 backend-after 捕获） |

**中断原因**：B1-nj1 r1（1 进程写 64G）触发 osd.0/osd.2 的 BlueFS stalled read。r2 前的 `check_ceph_health` 等待 120s 后 health 未恢复 → abort。这是 `check_ceph_health` 的预期行为（health 非 OK 超时即退出），与 v1 的 write-push.sh 中 return-0-then-continue 的行为不同。

---

## 二、核心数据

### 2.1 A-idle：完全空闲后端

> 起跑条件：HEALTH_OK，无 slow_ops/stalled_read 残留，drop 三台 OSD cache，静置后开测。

| 轮次 | seqwrite (MiB/s) | randwrite (MiB/s) | 较 r1 退化 |
|------|:---:|:---:|:---:|
| r1 | **68.0** ✓ | **62.6** ✓ | — |
| r2 | 47.3 | 48.2 | seq −30% / rw −23% |
| r3 | 42.8 | 48.3 | seq −37% / rw −23% |
| r4 | 40.1 | 50.6 | seq −41% / rw −19% |
| r5 | 42.1 | 48.7 | seq −38% / rw −22% |

- **r1 达标且创新高**：seqwrite=68.0、randwrite=62.6，均高于此前写推的 64.0/63.7。
- **r1→r2 断崖式退化**：仅一轮累积写入（~4G seqwrite + ~3.8G randwrite ≈ 7.8G）就让 seqwrite 从 68 跌到 47（−30%）。
- **r3→r5 稳定在 40–50 区间**：seqwrite ~40-43、randwrite ~48-51，不再继续跌。
- **每轮都 drop caches**（客户端 + 3 OSD 全部 drop），所以退化不是 page cache 而是 RocksDB compaction 积压。
- A-idle 完成后 **osd.5 出现 stalled read**（见 backend-after），300s 自愈超时，需手动 restart OSD。

**NIC 数据**：
| 轮次 | seqwrite TX(MB) | seqwrite RX(MB) |
|------|:---:|:---:|
| r1 | 4255.5 | 73.4 |
| r2 | 4254.7 | 71.2 |
| r3 | 4254.8 | 69.2 |
| r4 | 4420.4 | 71.3 |
| r5 | 4254.5 | 68.3 |

- TX 稳定在 ~4255 MB（4GB 写入的 TX 开销），TX/写入比 ≈ 1.04×
- 与 EC 4+2 理论放大 1.5× 有差距（可能 JuiceFS 写 4M 对象到 EC pool 时有额外合并/压缩）

### 2.2 B1-nj1：1 进程写 64G

> 起跑条件：osd.5 重启后 HEALTH_OK，drop caches 后开测。

| 轮次 | 状态 | WRITE (MiB/s) | 耗时 | NIC |
|------|------|:---:|------|-----|
| r1 | ✅ 完成 | 41.5 | 1580s (26.3min) | TX=68076MB RX=1072MB |
| r2 | ❌ abort | — | — | — |

- r1 运行期间 osd.0 出现 `BLUESTORE_SLOW_OP_ALERT`，osd.0 + osd.2 出现 `DB_DEVICE_STALLED_READ_ALERT`
- r1 完成后 health 未恢复，r2 前 health check 120s 超时 → abort
- TX=68076MB / 65536MB(64G) = 1.039×，与 A-idle 一致

### 2.3 Cooldown 日志

**A-idle → B1-nj1**：
```
cooldown start: 15:58:57
stall detected: 15:59:23 (osd.5 stalled read)
self-heal attempt: 300s (to 16:04:29) — FAILED
restart osd.5: 16:04:29
HEALTH_OK: 16:05:31 (restart + 30s)
total cooldown: 6m34s (300s wait + restart + 30s recovery)
```

**B1-nj1 → B1-nj2**：
```
B1-nj1 r1 completed → osd.0/osd.2 stalled
check_ceph_health timeout 120s → script abort
```

---

## 三、受影响的 OSD 汇总

| 触发场景 | 受影响的 OSD | 告警类型 |
|---------|:---:|---|
| A-idle 5 轮 (~39GB 累计写入) | osd.5 | stalled read |
| B1-nj1 r1 (64GB 单次写入) | osd.0, osd.2 | slow ops + stalled read |

共 6 个 OSD 中 3 个先后中招（0、2、5），覆盖全部 3 台 Ceph 节点。

---

## 四、对三个核心问题的结论

### 问题 1：旧测 57/54.8 为什么比新测 64/63.7 低？

**结论**：污染假说成立。旧测是被 destroy 后的 RocksDB compaction 余波污染。

- 当后端完全 idle 时，seqwrite r1 = **68.0**（比 64 更高）
- 但仅 1 轮累积写入（~8GB）就跌到 47.3（−30%）
- 旧测 57 处于 40-68 的区间内，是"非 idle 状态"的值
- 后续 r3-r5 稳定在 40-43，说明 RocksDB compaction 达到了一个新的稳态（compaction 速率 = 新产生 metadata 速率）
- 此前的 57 可能是"从某个中间污染状态起步"，而 64 是"较干净但非完全 idle"，68 是"完全 idle"

**数据支撑**：A-idle 5 轮数据 + backend-before/after + cooldown-wait.log

### 问题 2：多线程写不如单线程写的原因？并发数的影响？

**结论**：并发数不是主因，写入总量/时长驱动的 RocksDB compaction 才是根因。

- B1-nj1（1 进程写 64G）= 41.5 MiB/s，触发 stall
- 对比：A-idle r1 seqwrite（1 进程写 4G）= 68.0 MiB/s，无 stall
- 1 进程写 64G 跟 16 进程写 64G 都会 stall，证明 stall 由写入总量决定
- 并发数的影响被"总量不相等"混淆了——短跑 4G 在 stall 发生前就结束了

**未完成**：B1-nj2~nj16 固定总量对比（因 stall → abort 链无法执行）

### 问题 3：BlueFS stall 的根因

**部分证实**：
- stall 由 RocksDB compaction 积压导致 ✓（cooldown 日志证明不可自愈，需 restart OSD）
- WAL/DB 与 Data 共享 SSD 是瓶颈 ✓（系统环境已知）
- 与"进程数 > OSD 数"无关 ✓（1 进程也触发）
- EC 写放大加重了 metadata 压力（待定量：A-idle TX ≈ 1.04× 而非理论 1.5×）

**未完成**：实时 health-timeline、OSD perf dump 序列、磁盘布局取证（因 B1-nj16 未执行到）

---

## 五、暴露的设计问题

### 5.1 "每格跑 5 轮"与"持续写必触发 stall"的矛盾

当前环境（WAL/DB 与 Data 共享 SSD、db=none wal=none）下，**超过约 40GB 的持续写入必然触发 BlueFS stall**。A-idle 的 5 轮（~39GB）就触发了 osd.5 stall。任何要求 5 轮 × multi-seqwrite 的格子都会在第一轮或第二轮触发 stall，后续轮次无法在 HEALTH_OK 下运行。

### 5.2 check_ceph_health 的 abort 行为

v2 脚本使用 `check_ceph_health` 函数（来自 `tests/lib/ceph-health-check.sh`），health 非 OK 时等待 120s 超时即 `exit 1`。这与 v1 write-push.sh 的 `restart_osds_if_needed` 不同——v1 会等当前 fio 完成后重启 OSD。

在这个环境下，一旦 stall 发生，120s 内不会自愈，必然 abort。这意味着"有多个测试项的格子"在 stall 发生后无法继续。

### 5.3 实验顺序问题

B1-nj1（64G 单次写入）放在 A-idle 之后、并发扫描之前是正确的。但 B1-nj1 本身就是一个"必触发 stall"的测试（64G > ~40GB 阈值）。它跑完后，后续 B1-nj2~nj16 需要 OSD restart 才能继续。

---

## 六、推荐的后续方向

### 方向 A：改"每格 5 轮"为"每格 1 轮 + OSD restart 每格间"

- 每格只跑 r1（本来就是判定的依据）
- 每格间必 restart 受影响 OSD + 等 HEALTH_OK
- 好处：每个数据点都从干净态出发，不受前一轮 compaction 干扰
- 代价：单格时间增加（restart + recovery ~2-3 分钟）
- 剩余工作：A-postlayout、A-repeat、B1-nj2~nj16、B2，约 10 个格子，每个 ~30-60 分钟（含 recovery）

### 方向 B：接受当前数据为终态

- A-idle 5 轮 + B1-nj1 r1 已给出核心结论
- 未完成的实验数据不影响三个问题的判定
- 关闭本次复测，更新报告

### 方向 C：加 NVMe WAL/DB 后再测

- 根本解决 BlueFS stall 问题
- 但这是硬件改造，不在当前可操作范围内

---

## 七、数据目录清单

```
results/write-push-retest-20260705/
├── bg-run.log                          # 全程 stdout
├── env-snapshot.txt                    # 环境快照
├── expA-contamination/
│   └── A-idle/
│       ├── run.log                     # 5 轮 seqwrite+randwrite 记录
│       ├── summary.md                  # 汇总表
│       ├── seqwrite-r{1..5}.txt        # 原始 fio 输出
│       ├── randwrite-r{1..5}.txt       # 原始 fio 输出
│       ├── backend-before.txt          # 起跑前后端快照
│       ├── backend-after.txt           # 跑完后后端快照（含 osd.5 stall 证据）
│       ├── sys-before-{ip}.txt         # OSD 节点系统状态
│       ├── sys-after-{ip}.txt          # OSD 节点系统状态
│       ├── cooldown-wait.log           # cooldown 过程完整轮询
│       └── mount.log                   # 挂载日志
└── expB-concurrency/
    └── B1-nj1/
        ├── run.log                     # r1 完成 r2 abort
        ├── multi-r1.txt                # 原始 fio 输出（41.5 MiB/s）
        ├── backend-before.txt          # 起跑前快照
        ├── backend-after.txt           # r1 后快照（含 osd.0/osd.2 stall 证据）
        └── mount.log
```
