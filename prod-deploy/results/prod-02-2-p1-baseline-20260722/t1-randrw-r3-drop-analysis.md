# T1：randrw r3 骤降机制确认

> 任务来源：`/tmp/02-2-maxfuse-validity-fix-taskbook.md` T1
> 执行日期：2026-07-22
> 原始数据：`results/prod-02-2-p1-baseline-20260722/opencode-t1-randrw/`

## T1.1：现有日志判定

对比 R2-B1 和 R4-B 的 randrw 三轮 fio 输出：

### R2-B1 randrw

| 指标 | r1 | r2 | r3 | r3 变化 |
|------|-----|-----|-----|---------|
| BW (MiB/s) | 1178 | 1201 | 863 | -28% |
| WRITE slat avg | 26.9ms | 26.4ms | **36.8ms** | **+39%** |
| WRITE clat avg | 1709ms | 1677ms | **2324ms** | **+36%** |
| READ slat avg | 198μs | 221μs | 225μs | 稳定 |

### R4-B randrw

| 指标 | r1 | r2 | r3 | r3 变化 |
|------|-----|-----|-----|---------|
| BW (MiB/s) | 1355 | 1282 | 819 | -36% |
| WRITE slat avg | 23.4ms | 24.7ms | **38.7ms** | **+65%** |
| WRITE clat avg | 1487ms | 1570ms | **2441ms** | **+64%** |

### R1-A randrw（对照组，A 组从不骤降）

| 指标 | r1 | r2 | r3 |
|------|-----|-----|-----|
| BW (MiB/s) | 905 | 920 | 905 |
| WRITE slat avg | 35.1ms | 34.5ms | 35.1ms |

### T1.1 结论

**r3 骤降是累积/污染，不是真实波动。** 证据：
1. B 组 r3 WRITE slat +39~65%，clat +36~64% → 提交和完成延迟均恶化
2. A 组 r1/r2/r3 slat 始终稳定 35ms → 不发生骤降（A 组写更慢，累积效应被高基线延迟掩盖）
3. READ slat 全程稳定（~200μs）→ FUSE 读路径不受影响，问题在写侧
4. compact_cooldown 不足以清除两轮 ~200GiB 覆写产生的 SST tombstone 积压

## T1.2：X/Y 对照小实验

在当前 R4-B 挂载（ra0）上，只跑 randrw 3 轮，对比两种取样方式：

- **变体 X（现状复现）**：复用同一 layout 目录，轮间仅 compact_cooldown + drop_caches
- **变体 Y（隔离累积）**：每轮 `rm -rf TEST_DIR && mkdir` 重建 layout + drop_caches 全节点 + compact_cooldown

参数：`bs=256k rw=randrw iodepth=128 numjobs=128 runtime=180 direct=1 filesize=1G size=1G`

### 结果

| 变体 | r1 BW | r2 BW | r3 BW | CV | r1 slat | r3 slat |
|------|-------|-------|-------|-----|---------|---------|
| X（复用） | 1401 | 835 (-40%) | 715 (-49%) | **33%** ❌ | 22.6ms | **44.4ms** |
| Y（每轮重建） | 1452 | 1399 (-3.6%) | 1395 (-3.9%) | **2.1%** ✅ | 21.8ms | 22.7ms |

### T1.2 结论

**randrw r3 骤降 = 脚本缺陷（layout 复用导致累积污染），非系统性能波动。**

- 变体 X：layout 复用 → r2 已骤降（-40%），累积效应比全量基线更早爆发（全量基线 r3 才爆发）
- 变体 Y：每轮重建 layout + drop_caches → 三轮 CV=2.1%，slat 稳定 22ms，**完全消除骤降**
- **后续 randrw 测试口径：采用变体 Y（每轮重建 layout + drop_caches 全节点）**
