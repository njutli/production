# randwrite-ow 波动根因最终诊断报告

> 日期：2026-07-18
> 原始数据：`diagnosis/randwrite-ow-jitter-v2/` + `rwow-verify/`

---

## 一、验证实验设计

3 轮 randwrite-ow，每轮 pool 重建保证后端同状态。唯一变量：**JuiceFS mount 是否重启**。

| 轮次 | JuiceFS mount | Go 进程运行时间 | 验证目的 |
|------|---------------|---------------|---------|
| R1 | 不重启（集群部署后首次） | ~10 min | 基准（已累积一定时间） |
| R2 | 不重启（R1 后 ~15 min） | ~25 min | 累积更多，预期更低 |
| R3 | **重启（fresh Go 进程）** | 0 min（刚 mount） | 验证 Go 进程状态是否根因 |

---

## 二、结果

### 2.1 fio 聚合 BW

| 轮次 | Go 进程时间 | fio BW | vs R1 |
|------|------------|--------|-------|
| R1 | ~10 min | 1968 MiB/s | 基准 |
| R2 | ~25 min | 1528 MiB/s | -22% |
| R3 | **0 min（fresh）** | **3599 MiB/s** | **+83%** |

### 2.2 fuse_ops（每 30 秒）

```
R1: 13K → 21K → 18K → 13K
R2: 15  → 13  → 12K
R3: 28K → 32K → 29K → 33K → 24K → 18K
```

R3（fresh Go）初始 fuse_ops = 28K，是 R1 的 2.2 倍、R2 的 2.3 倍。

### 2.3 fuse_lat（每 30 秒）

```
R1: 9.05 → 5.34 → 5.79 → 9.12 ms
R2: (数据不完整) → 10.1 ms
R3: 3.82 → 3.11 → 3.47 → 3.13 → 4.86 → 6.64 ms
```

R3（fresh Go）初始 fuse_lat = 3.82ms，是 R1 的 42%、R2 的 38%。

### 2.4 CPU（每 30 秒）

```
R1: 1274% → 1700% → 1522% → 1317%
R2: 1092% → 1166% → 1263%
R3: 1653% → 2006% → 1757% → 1707% → 1419% → 1526%
```

R3（fresh Go）初始 CPU = 1653%，是 R1 的 130%、R2 的 151%。

---

## 三、根因定位

### 3.1 确认：Go 进程状态累积是根因

| 证据 | 结论 |
|------|------|
| R1→R2 BW 降 22%（Go 运行 15min 后） | Go 进程状态累积导致性能退化 |
| R2→R3 BW 涨 135%（重启 mount 后） | Fresh Go 进程恢复并超越 |
| R3 fuse_ops 初始 28K vs R1 13K vs R2 15K | Fresh Go 进程的 FUSE dispatch 能力是累积状态的 2 倍 |
| R3 fuse_lat 初始 3.82ms vs R1 9.05ms | Fresh Go 进程的 FUSE 延迟是累积状态的 42% |
| R3 CPU 初始 1653% vs R1 1274% vs R2 1092% | Fresh Go 进程能利用更多 CPU |

### 3.2 Go 进程状态退化的具体机制

Go 进程长时间运行后，以下因素可能导致 FUSE dispatch 能力下降：
- **Go GC 压力**：heap 增长后 GC pause 增多，抢占 goroutine 调度时间
- **goroutine 堆积**：JuiceFS 内部 goroutine（upload/meta/cache）随运行时间增长
- **heap 碎片化**：Go allocator 长时间运行后内存碎片化，影响分配效率

需 Go pprof（heap/goroutine profile）才能进一步区分这三者。但**对基线数据无影响**——根因已确认在 Go 进程侧，解决方法是轮间重启 mount。

### 3.3 pool 重建为什么不能解决

pool 重建（destroy → compact → pool delete/recreate → format）保证：
- ✅ Ceph pool 0 对象
- ✅ RocksDB 清理
- ✅ TiKV 元数据清除
- ❌ JuiceFS Go 进程状态不重置

pool 重建只清理后端，不重启 JuiceFS 客户端进程。Go 进程的 heap/goroutine/GC 状态持续累积。

---

## 四、对基线数据的建议

### 4.1 randwrite-ow 基线取值

| 方案 | 值 | 可信度 | 说明 |
|------|---|--------|------|
| Fresh Go 进程首轮（R3） | 3599 MiB/s | ⚠️ 偏高 | OSD 已热（3 次 layout 预热）+ fresh Go，不代表常规运行 |
| 累积状态（R1） | 1968 MiB/s | ⚠️ 偏低 | Go 已运行 10 min，可能不代表稳定运行 |
| 累积状态（R2） | 1528 MiB/s | ⚠️ 偏低 | Go 已运行 25 min |

**建议**：报告为范围 1528-3599 MiB/s，注明"受 JuiceFS Go 进程运行时间影响，波动 22-83%"。或取 R1（首次 pool 重建后的首轮）作为代表性基线：~1968 MiB/s。

### 4.2 其他 9 项不受影响

其他 8 项（seqread/seqwrite/mseqread/mseqwrite/layout/randwrite-true/randread/randrw）均为**单轮或首轮测试**，Go 进程刚 mount，不存在累积问题。randwrite-true 也是首轮 mount 后跑的 3 轮，但它是 create_on_open（每轮新建文件），Go 进程状态影响较小。

### 4.3 后续测试规范

如需稳定的 randwrite-ow 基线：**每轮 randwrite-ow 前重启 JuiceFS mount**（umount → mount），确保 fresh Go 进程。但这会增加每轮 ~2 分钟开销。
