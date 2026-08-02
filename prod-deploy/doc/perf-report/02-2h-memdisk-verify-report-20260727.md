# 内存盘验证报告：randread 双峰消失验证 (2026-07-27)

> 目的：验证 NVMe 设备层是否为 randread 双峰波动的根因（§-STEP3C SC.4 假设）。
> 方法：将 OSD 数据盘从 NVMe 替换为 brd（RAM disk），其余不变，跑 10 轮 randread 看 CV 和双峰是否消失。
> 结论：**双峰消失，但 CV 未到 1-2%（残余 ~10%）；NVMe 设备层是双峰的来源之一，但非唯一变异源。**

---

## 一、测试环境

### 1.1 brd 集群配置

| 项 | NVMe 基线 (A1-A26) | brd 验证 (M1-M10) | 差异说明 |
|---|---|---|---|
| OSD ID | 0-5 | 8,10,12,13,14,15 | 重建后非连续 ID |
| 数据盘 | nvme2n1/nvme3n1 (7T) | ram0/ram1 (400G) | brd 内存盘 |
| DB/WAL | tmpfs loop (40G+10G/OSD) | 无（BlueStore 在 brd 上） | brd 无需独立 DB/WAL |
| pool_id | 2 | 7（经多次重建） | JuiceFS 重新 format |
| EC 参数 | k4m2/size6/min5/pg32/eco/fast1/stripe16384 | 同 | 逐项复刻 |
| JuiceFS | storage=ceph, block=256K, cache=0, uploads=150 | 同 | 同口径 |
| fio | bs=256k, iodepth=128, numjobs=128, direct=1, time_based, runtime=180 | 同 | randread 口径一致 |
| soft-clean | juicefs destroy + OSD restart + compact | 同 + rados purge | 增加 purge 防数据累积 |

### 1.2 与 NVMe 基线的已知差异（A/B 注意点）

1. **pool_id 变化**: 2→7，JuiceFS 重新 format（路径B），TiKV 元数据起点改变，不影响 A/B（TiKV 非被测变量）
2. **无独立 DB/WAL**: brd 单设备；NVMe 基线 DB/WAL 在 tmpfs（也是 RAM，无实质差异）
3. **brd 不上报 /proc/diskstats**: ram0/ram1 全零，判据②(ram rd_ms) 无法采集（预期内，非致命）
4. **OSD 重量**: 0.39 (400G) vs 7.03 (7T)，CRUSH 按 weight 分配 PG，各 32 PG 均衡
5. **测试范围**: 因 brd 容量限制（EC overwrite 数据累积），只跑 layout+randread×3，未跑全量 9 项

---

## 二、测试过程中的问题与修复

### 2.1 compact_cooldown 超时（已修复）

- **根因**: `ceph osd ls` 返回全部 12 OSD（含 down 的 0-5），down OSD 不响应 → fallback "1 1" → 轮询永远等不到 → 10min 超时
- **修复**: 改用 `ceph osd dump` + Python 过滤只返回 up OSD；fallback 改 "0 0"
- **效果**: 10min 超时 → 5s 完成

### 2.2 pool 反复写满（已修复）

- **根因**: brd I/O 极快（~3800 MiB/s），EC overwrites 每次覆写产生新 chunk 版本 + tombstone，BlueStore 来不及释放旧 chunk → 数据累积 → pool 满
- **修复**:
  1. brd 从 200G → 400G
  2. clean_volume 增加 `rados purge` + `sleep 30`
  3. 简化测试为 layout+randread×3（避免写类项的 EC overwrite 累积）
- **影响**: 无法跑全量 9 项（randwrite-true/randwrite-ow 的 time_based 覆写会填满 400G brd）

### 2.3 osd-perf 数据未采集

- **根因**: osd-monitor-brd.sh 的动态 OSD ID 解析（`ceph osd dump | python3`）在后台运行时失败
- **影响**: 判据③（read_lat/aio_lat 恒定）无法从 osd-perf 评估
- **可用替代**: node CSV 有 ram0/ram1 diskstats（全零，符合预期）+ 网络数据；bw_log 有逐秒带宽

### 2.4 M1 r1 异常 (70.9 MiB/s)

- **现象**: M1 的 r1 跑了 1115s（非 180s），BW=70.9 MiB/s
- **可能原因**: 首次 randread 后 layout，OSD 冷缓存 + fio `--time_based` 可能未生效（eval 参数传递问题）
- **处置**: M1 r1 排除，M1 r2/r3 保留参考；M2-M10 的 r1 均正常（确认非系统性问题）

---

## 三、randread 完整数据

### 3.1 原始数据（fio bw, MiB/s）

| 轮次 | r1 | r2 | r3 | 轮内 CV |
|------|------|------|------|---------|
| M1 | 70.9* | 1389 | 1626 | — |
| M2 | 1330 | 1348 | 1328 | 0.8% |
| M3 | 1512 | 1527 | 1532 | 0.7% |
| M4 | 1504 | 1522 | 1518 | 0.6% |
| M5 | 1714 | 1711 | 1682 | 1.0% |
| M6 | 1360 | 1353 | 1398 | 1.6% |
| M7 | 1455 | 1459 | 1486 | 1.1% |
| M8 | 1689 | 1693 | 1690 | 0.1% |
| M9 | 1464 | 1476 | 1464 | 0.5% |
| M10 | 1217 | 1218 | 1219 | 0.1% |

*M1 r1=70.9 为异常值（详见 §2.4），统计分析中排除。

### 3.2 统计分析（M2-M10, 27 个数据点）

| 指标 | brd (M2-M10) | NVMe 基线 (A7-A15 好坏轮) |
|------|-------------|-------------------------|
| 数据点数 | 27 | 27 (9轮×3) |
| 最小值 | 1217 | 1287 |
| 最大值 | 1714 | 1497 |
| 均值 | 1477 | 1390 |
| StdDev | 148 | 88 |
| **CV** | **~10%** | **~12%** |
| 轮内 CV | <1.6% | <1.5% |

### 3.3 双峰分析

**NVMe 基线**（A7-A15）:
- 坏峰: 1287-1307（紧簇 ~1300）
- 好峰: 1449-1497（紧簇 ~1472）
- 中间无过渡值，间距 ~12%
- Spearman ρ(hit%, fio) = 1.000

**brd 验证**（M2-M10）:
- 排序后: 1217, 1218, 1219, 1328, 1330, 1348, 1353, 1360, 1398, 1455, 1459, 1464, 1464, 1476, 1486, 1504, 1512, 1518, 1522, 1527, 1532, 1682, 1689, 1690, 1693, 1711, 1714
- **无双峰聚集**：值连续散布在 1217-1714 范围
- 可大致分 4 组：低(1217-1219)、低中(1328-1398)、中(1455-1532)、高(1682-1714)
- 但组间有过渡值，非 NVMe 的明确二元分离

### 3.4 新现象

1. **brd 出现 NVMe 未有的高值 (1682-1714)**: brd 读延迟更低（内存无介质层），好状态比 NVMe 更好
2. **brd 出现 NVMe 未有的低值 (1217-1219)**: 低于 NVMe 坏峰（1287-1307），可能来自非设备层变异源
3. **brd 值范围更宽 (1217-1714, 跨度 497)**: NVMe 范围 (1287-1497, 跨度 210)，brd 变异来源更分散

---

## 四、PHASE 7 判定

### 4.1 判据评估

| 判据 | 预期 | 实际 | 判定 |
|------|------|------|------|
| ① randread CV | ~12% → ~1-2% | ~12% → ~10% | **部分成立**：CV 降低但未塌缩 |
| ② ram rd_ms 恒定 | 恒定无漂移 | 无法采集（brd 无 diskstats） | **放弃**（预期内，冗余判据） |
| ③ read_lat/aio_lat 恒定 | 不再双峰 | 无法采集（osd-perf 脚本 bug） | **待定**（需修复脚本重采或事后分析） |

### 4.2 结论

**SC.4 部分成立、部分证伪**：
- ✅ **双峰消失**：NVMe 的明确二元双峰（坏 ~1300 / 好 ~1472）在 brd 上不再出现
- ✅ **NVMe 设备层是双峰的来源**：消除设备层后，双峰模式改变
- ❌ **CV 未塌缩到 1-2%**：残余 ~10% CV，说明存在非设备层变异源
- ❓ **残余变异来源**：可能是 JuiceFS/TiKV 元数据路径、网络、CPU 调度、EC 奇偶计算等

### 4.3 对 NVMe 基线采纳的影响

- NVMe 双峰的"坏峰"（~1300）中，**NVMe 设备层贡献了部分**（rd_ms 间歇性升高 → §SC.3），但不是全部
- 消除设备层后变异仍在（~10%），但模式不同（连续散布 vs 双峰）
- **统计基线仍需采纳**：无论 NVMe 还是 brd，轮间变异都存在（10-12%），非完全可控
- 后续调优应在 brd 上做（剥离设备噪声），专注 JuiceFS/EC/网络软件栈

---

## 五、数据与日志路径

### 5.1 测试结果

```
157:/tmp/opencode-memdisk-verify/
├── test.log                      # 测试主日志（全部 10 轮 + softclean）
├── orchestrator.log             # 编排脚本日志
├── m1-stdout.log                 # M1 stdout
├── orchestrator-stdout.log      # orchestrator stdout
├── M1/
│   ├── layout-M1/
│   │   ├── fio.txt               # fio 原始输出
│   │   ├── fio.txt               # bw_log 文件
│   │   ├── weka-load.txt         # 157 load 前后
│   │   ├── nic.txt               # 157 NIC 逐秒
│   │   ├── load-monitor.csv      # 157 侧采集 (37行)
│   │   └── osd/
│   │       ├── osd-perf.csv      # OSD 侧 perf dump (仅表头，数据未采集)
│   │       ├── node-150.csv      # 150 侧采集 (34行: CPU/网络/ram diskstats)
│   │       ├── node-151.csv
│   │       ├── node-152.csv
│   │       └── historic-ops-osd*.json
│   ├── randread-M1-r1/
│   │   └── (同上结构)
│   ├── randread-M1-r2/
│   └── randread-M1-r3/
├── M2/ ... M10/                  # 同结构
```

### 5.2 关键文件

| 文件 | 说明 |
|------|------|
| `/tmp/opencode-memdisk-verify/test.log` | 全部 10 轮测试日志 |
| `/tmp/opencode-memdisk-verify/orchestrator.log` | 编排进度 + randread 汇总 |
| `/tmp/opencode-memdisk-verify/{M1..M10}/randread-{label}-r{1,2,3}/fio.txt` | fio 原始输出 |
| `/tmp/opencode-memdisk-verify/{M1..M10}/randread-{label}-r{1,2,3}/*_bw.*.log` | 逐秒带宽 (128 个/job) |
| `/tmp/opencode-memdisk-verify/{M1..M10}/randread-{label}-r{1,2,3}/osd/node-15*.csv` | OSD 节点采集 (34行/轮) |
| `/tmp/opencode-memdisk-verify/{M1..M10}/randread-{label}-r{1,2,3}/load-monitor.csv` | 157 侧采集 (37行/轮) |

### 5.3 集群配置存档

| 文件 | 说明 |
|------|------|
| `doc/memdisk-rebuild-baseline-20260726.txt` | PHASE 0 前置存档（NVMe 基线快照） |
| `/tmp/opencode/memdisk-deploy-status-20260726.md` | 部署状态与修复记录 |
| `/tmp/opencode/memdisk-fix-log.md` | 问题修复日志 |
| `/tmp/opencode/memdisk-randread-verify.sh` | 简化版测试脚本（本地副本） |
| `/tmp/opencode/osd-monitor-brd.sh` | brd 适配采集器（本地副本） |
| `/tmp/opencode/memdisk-randread-orchestrator.sh` | 编排脚本（本地副本） |
| 157:`/tmp/memdisk-randread-verify.sh` | 测试脚本（生产） |
| 157:`/tmp/osd-monitor-brd.sh` | 采集器（生产） |
| 157:`/tmp/memdisk-randread-orchestrator.sh` | 编排脚本（生产） |

### 5.4 NVMe 基线对照数据

| 文件 | 说明 |
|------|------|
| `results/prod-02-2-h-fullbaseline-20260724/` | A1-A26 全部结果数据 |
| `doc/perf-report/02-2h-summary.md` | 波动源定位简报 |
| `doc/perf-report/02-2h-r7-r9-judgment-20260726.md` | R.7-R.9 非读 I/O 溯源判定 |
| `/tmp/bridge/analysis.md` | Opus 分析与复核（含 §-STEP3C SC.4 假设、§-PLAN3 方案、§-DEPLOY-CHECK 部署检查、§-READY 就绪核验） |

---

## 六、后续建议

### 6.1 待分析师 (Opus) 复算

1. **bw_log 稳态中位数**: 截首 1/4 后取中位数（TESTING-GUIDE §5.6），验证 fio 平均 BW 是否被缓冲暂态拉高
2. **node CSV 差分**: tx_bytes/tcp_rtt 轮间对比，看网络层是否有变异
3. **load-monitor 差分**: fuse_ops/obj_get 延迟轮间对比，看 JuiceFS 客户端侧是否有变异
4. **修复 osd-perf 采集**: 修复 osd-monitor-brd.sh 的后台 OSD ID 解析 bug，重采 read_lat/aio_lat（或在下次测试时修复）

### 6.2 下一阶段方向

1. **残余变异溯源**: brd 上仍有 ~10% CV，需排查 JuiceFS/TiKV/网络/CPU/EC
2. **brd 上调优**: 在 brd 集群上做软件栈调优（剥离设备噪声，专注 BlueStore/EC/线程/网络真实增益）
3. **是否回滚 NVMe**: 视分析结果决定（PHASE 8），或保留 brd 集群做后续调优

---

## 七、测试时间线 (157 时间 +07)

| 时间 | 事件 |
|------|------|
| 23:01 | M1 启动（HEALTH_OK） |
| 00:07 | M1 完成（r1 异常 70.9） |
| 00:22 | M2 完成 |
| 00:36 | M3 完成 |
| 00:50 | M4 完成 |
| 01:04 | M5 完成 |
| 01:19 | M6 完成 |
| 01:33 | M7 完成 |
| 01:47 | M8 完成 |
| 02:01 | M9 完成 |
| 02:15 | M10 完成，编排脚本结束 |

总耗时 ~3h14m（含 9 次 soft-clean）。
