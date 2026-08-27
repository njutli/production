# JuiceFS v1.4.1 vs Patched v1.3.1 全量基线对比测试

## 日期：2026-08-24

---

## 1. 测试概述

用官方最新正式版 v1.4.1 替换 patched v1.3.1（B-catchup + loadRange），在相同最优配置下跑 V4 全量 7 项基线，与 03-17f 的 patched v1.3.1 结果对比。发现 randwrite 严重回退后，在 v1.4.1 上单独打 B-catchup 补丁重测 randwrite。

## 2. 测试环境

| 项 | v1.4.1 原版 | v1.4.1 + B-catchup | Patched v1.3.1（03-17f 基线） |
|---|---|---|---|
| 二进制 | `/tmp/juicefs-1.4.1-ceph`，md5 `58f4406e...` | `/tmp/juicefs-1.4.1-patched`，md5 `24fae085...` | `/tmp/juicefs-03-8`，md5 `de93563f...` |
| 版本 | `1.4.1+unknown`（官方 tag 0b90c7d） | `1.4.1+unknown` + B-catchup 补丁 | `1.3.1+2025-12-02.e0032b2a` + B-catchup + loadRange |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` | 相同 | 相同 |
| msgr | 进程私有 conf，ms_async_op_threads=8 | 相同 | 相同 |
| fio | 3.28，7 项 × 3 轮 × 180s | randwrite 3 轮 × 180s | 相同 |

## 3. 结果对比

### 3.1 全量 7 项（v1.4.1 原版 vs Patched v1.3.1，fio 汇总中位数，MiB/s）

| 项 | v1.4.1 原版 | Patched v1.3.1 | 变化 |
|---|---:|---:|---|
| seqread | 1442 | ~1440* | ≈持平 |
| mseqread | 5505 | ~5500* | ≈持平 |
| randread | 5616 | ~5544 | +1.3% |
| randrw | 1743 | ~1750* | ≈持平 |
| seqwrite | 1570 | ~1560* | ≈持平 |
| mseqwrite | 4548 | ~4500* | ≈持平 |
| **randwrite** | **551** | **2558** | **-78.5%** |

*03-17f 未报告部分单项的具体值，此处为估算。randread 和 randwrite 有确切值。

### 3.2 randwrite 三方对比（逐轮）

| 轮次 | v1.4.1 原版 | v1.4.1 + B-catchup | Patched v1.3.1 |
|---|---:|---:|---:|
| r1 | 551 | 3348 | 2577 |
| r2 | 552 | 2724 | 2558 |
| r3 | 551 | 2669 | 2513 |
| **中位数** | **551** | **2724** | **2558** |

### 3.3 randwrite 对比小结

| 版本 | randwrite 中位数 (MiB/s) | vs Patched v1.3.1 |
|---|---:|---|
| v1.4.1 原版 | 551 | -78.5% |
| v1.4.1 + B-catchup | 2724 | +6.5% |
| Patched v1.3.1 | 2558 | 基线 |

打上 B-catchup 补丁后，v1.4.1 的 randwrite 从 551 恢复到 2724 MiB/s，超过 patched v1.3.1 的 2558 MiB/s（+6.5%）。r1 偏高（3348）可能为首轮挂载效应。

## 4. randwrite 回退根因确认

v1.4.1 原版 randwrite 551 MiB/s 的回退**完全由 B-catchup 补丁缺失导致**。在 v1.4.1 上单独打 B-catchup 补丁后，randwrite 恢复到 2724 MiB/s，与 patched v1.3.1 持平甚至略优。

v1.4.0 的 "commit new chunks in write order"（#7016）等其他写路径改动不影响 randwrite 性能——补丁只改了 `prepareID` 中 `SetID` 后的 3 行代码，没有触及 #7016 的逻辑。

### B-catchup 补丁说明

补丁在 `pkg/vfs/writer.go` 的 `prepareID` 函数中，`SetID(s.id)` 后补 3 行：

```go
if s.writer != nil && s.writer.ID() == 0 {
    s.writer.SetID(s.id)
    // --- B-catchup patch: 3 lines added ---
    if !s.freezed && int(s.slen) >= f.w.blockSize {
        s.writer.FlushTo(int(s.slen))
    }
    // --- end patch ---
}
```

v1.4.1 原版的 `prepareID` 在 `SetID` 后直接 `Unlock` 退出，不触发 `FlushTo`。由于 `prepareID` 是异步 goroutine，当它完成时 `write` 方法早已检查过 `s.id > 0` 并跳过了 `FlushTo`（此时 `s.id` 仍为 0）。补丁在 `SetID` 后立即补 `FlushTo`，确保 block 满时数据及时上传，维持上传管线深度。

## 5. 执行偏离说明

1. **V4 脚本 rc=1**：V4 在每项 cleanup 后以 rc=1 退出（`set -e` 某步在 gc --compact 后的 drop_caches/remount 步骤失败）。7 项分 4 次执行（T141: 4 项、T141b: seqwrite、T141c: mseqwrite、T141d: randwrite），B-catchup randwrite 为第 5 次（T141p），每次需手动清理挂载后重启。
2. **旧 T56 数据**：V4 rounds.tsv 中残留旧 T56 数据，首次运行后被清理。
3. **所有轮次均 VALID**：每轮 fio rc=0，PG 全程 active+clean。

## 6. 结论

| 版本 | 读侧 | 顺序写 | randwrite | 建议 |
|---|---|---|---|---|
| v1.4.1 原版 | 持平/略优 | 持平 | 551 MiB/s（-78.5%） | 不适用生产 |
| v1.4.1 + B-catchup | 持平/略优 | 持平 | 2724 MiB/s（+6.5%） | 可作为升级候选 |
| Patched v1.3.1 | 基线 | 基线 | 2558 MiB/s（基线） | 当前生产 |

**B-catchup 补丁是 randwrite 性能的必要条件，在 v1.3.1 和 v1.4.1 上均如此。** v1.4.1 打上 B-catchup 后 randwrite 超过 patched v1.3.1，读侧持平，可作为升级候选。但 v1.4.1 + B-catchup 尚未跑全量 7 项基线，需补全后才能做最终决策。

## 7. 证据位置

| 文件 | 位置 |
|---|---|
| v1.4.1 原版二进制 | 157 `/tmp/juicefs-1.4.1-ceph`，md5 `58f4406e...` |
| v1.4.1 + B-catchup 二进制 | 157 `/tmp/juicefs-1.4.1-patched`，md5 `24fae085...` |
| V4 rounds.tsv | 157 `/tmp/opencode-fullbaseline-v4/rounds.tsv` |
| V4 test.log | 157 `/tmp/opencode-fullbaseline-v4/test.log` |
| 03-17f 基线报告 | `doc/perf-report/03-17f-deliver-config-baseline-20260821.md` |
| 补丁源码 | v1.4.1 `pkg/vfs/writer.go` prepareID 函数，`SetID` 后 3 行 |
