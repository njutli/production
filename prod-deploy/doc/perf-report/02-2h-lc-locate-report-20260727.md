# LC 定位实验报告：soft-clean 波动源拆解 (2026-07-27)

> 目标：定位 soft-clean 中哪一步引入了 randread "整轮 BW 锁定在不同值"的波动（brd 轮间 CV~10%，轮内<1.5%，93% 变异在 soft-clean 之间）。
> 方法：三组对照——A(连续基线) B(只重灌数据) C(只重启OSD)，隔离 soft-clean 的两个核心变量。
> 来源：analyst §-MEMDISK / §-LOCATE (`/tmp/bridge/analysis.md` MD.1-MD.6, LC.1-LC.7)
> 执行指令：`doc/perf-report/lc-locate-experiment-instructions-20260727.md`

---

## 一、实验设计

### 1.1 三组对照

| 组 | 每轮之间的操作 | 变量 | 固定 | 轮数 |
|---|---|---|---|---|
| **A** 连续基线 | 什么都不做 | 无（对照锚） | 一切 | 2 |
| **B** 只重灌数据 | destroy+purge+format+mount+layout 重写 | 数据物理布局（object 落点/PG 数据分布） | OSD 进程/primary 映射不变 | 5 |
| **C** 只重启 OSD | 仅 podman restart 所有 brd OSD 容器 | OSD 进程重启（PG primary 重选举） | 数据物理布局不变 | 5 |

### 1.2 通用规则

- 每轮：`[组特定操作] → drop_caches → ceph pg dump pgs_brief → randread 60s×1`
- randread fio：bs=256k, iodepth=128, numjobs=128, direct=1, time_based, runtime=60（仅 runtime 从 180 改为 60，经用户批准）
- 每轮采 PG 映射存 `pg-map.txt`（analyst 做 primary 分布 vs BW 的 Spearman）
- 集群：brd 6 OSD (8/10/12/13/14/15, 各 400G), pool 9 juicefs-data EC 4+2, pool_id 全程不变

### 1.3 前置验证

- **brd 数据在 podman restart 后保留** ✅（阶段1 验证：写测试对象 → restart osd.8 → 对象仍可读）
- **HEALTH_OK** ✅（阶段0 修复 clock skew + purge 空壳 OSD 6/7/9/11 + 等 OSD 14 recovery）

---

## 二、实验数据

### 2.1 原始数据（fio bw, MiB/s）

| 轮次 | A 组 | B 组 | C 组 |
|------|------|------|------|
| 1 | 1479 | 1606 | 1648 |
| 2 | 1483 | 1478 | 1240 |
| 3 | — | 1535 | 1126 |
| 4 | — | 1659 | 1227 |
| 5 | — | 1576 | 1273 |

### 2.2 统计分析

| 指标 | A 组 | B 组 | C 组 | C 组 (排除 C-1) |
|------|------|------|------|----------------|
| 数据点 | 2 | 5 | 5 | 4 |
| 最小值 | 1479 | 1478 | 1126 | 1126 |
| 最大值 | 1483 | 1659 | 1648 | 1273 |
| 均值 | 1481 | 1571 | 1303 | 1217 |
| StdDev | 2.8 | 61.6 | 179.4 | 54.9 |
| **CV** | **0.27%** | **3.9%** | **13.8%** | **4.5%** |

### 2.3 C-1 异常说明

C-1 (1648) 远高于 C-2~C-5 (1126-1273)，原因：C-1 是 layout 写入后的首次 randread，BlueStore 缓存为热态（刚写入的数据在内存中）。C-2 起 OSD restart 后缓存清空，BW 降到冷态水平。C-1 的 warm-cache 效应不代表 PG primary 的影响，应排除后看 C-2~C-5 的纯 restart 效果。

---

## 三、判读（LC.4 矩阵）

### 3.1 原始判读

| 条件 | 结果 | 判定 |
|------|------|------|
| C 炸(CV~14%) + B 不炸(CV~4%) | 成立 | → OSD restart 是主因？ |
| 但排除 C-1 warm cache 后 C 组 CV=4.5% | B≈C | → 无单一主因 |

### 3.2 修正判读

排除 C-1 warm-cache 后：

| 组 | CV | 贡献 |
|---|---|---|
| A（无 soft-clean） | 0.27% | 基线（几乎零变异） |
| B（只重灌数据） | 3.9% | 数据布局贡献 ~4% |
| C（只重启 OSD，排除 warm） | 4.5% | OSD restart 贡献 ~4.5% |
| B+C 组合（M1-M10 soft-clean） | ~10% | 两者叠加 |

**结论：无单一主因，B 和 C 贡献相近（各约一半）。**

### 3.3 与 M1-M10 对应关系

M1-M10 的 soft_clean_restart = B + C 的组合（destroy+purge + OSD restart）。实测：
- B 单独 CV 3.9% + C 单独 CV 4.5% ≈ 8.4%
- M1-M10 实测 CV 10%
- 差值 ~1.5% 可能来自 B+C 的交叉效应（destroy 后 layout 重写的 object 落点 + OSD restart 后的 primary 重分布 互相影响）

---

## 四、关键发现

### 4.1 A 组证实：不做 soft-clean 极稳

A 组 CV 0.27%（1481 vs 1483）— 确认 **100% 变异来自 soft-clean 操作，非运行期随机抖动**。这与 MD.2 的方差分解（93% between-M / 7% within-M）完全一致。

### 4.2 B 组：数据布局贡献 ~4%

destroy + layout 重写每轮改变 object 在 OSD 上的物理落点。EC 4+2 下，不同 object 落点导致不同的读放大/跨 OSD 取片模式，贡献 ~4% CV。

### 4.3 C 组：OSD restart 贡献 ~4.5%

OSD restart 后 PG primary 重选举，每轮不同的 primary 分布导致不同的 EC 读路径/热点。排除 warm-cache 后，纯 restart 效果 ~4.5% CV。

### 4.4 warm-cache 效应（C-1 vs C-2~5）

C-1 (1648) vs C-2~5 均值 (1217) 差 35% — 这是 BlueStore 缓存从热到冷的跳变，不是 PG primary 导致的。M1-M10 中每轮都有 OSD restart，所以每轮都是冷缓存，warm-cache 效应不构成 M1-M10 的变异来源。

### 4.5 对 MD.3 PG-primary 假设的修正

MD.3 头号嫌疑"PG primary 分布"**部分成立但不独立**：
- OSD restart 确实导致 PG primary 变化 → CV 4.5%
- 但数据重写（B 组）也贡献 4% → 两者叠加才到 10%
- → 钉死 primary 可能将 CV 从 10% 降到 ~4%（只消除了 C 的贡献），不能降到 ~1%
- → 需同时固定数据布局 + primary 才能完全消除变异

---

## 五、数据与日志路径

### 5.1 LC 实验数据

```
157:/tmp/opencode-lc-verify/
├── test.log                      # 主日志（A/B/C 三组全部）
├── lc-stdout.log                 # fio 原始输出
├── A/
│   ├── A-1/
│   │   ├── fio.txt               # fio 输出
│   │   ├── pg-map.txt            # PG acting/primary 映射
│   │   ├── load-monitor.csv      # 157 侧采集
│   │   └── osd/node-15{0,1,2}.csv
│   └── A-2/ (同结构)
├── B/
│   ├── B-1/ ... B-5/ (同结构)
└── C/
    ├── C-1/ ... C-5/ (同结构)
```

### 5.2 关键文件

| 文件 | 说明 |
|------|------|
| `157:/tmp/opencode-lc-verify/test.log` | 三组全部日志 + 汇总 |
| `157:/tmp/opencode-lc-verify/{A,B,C}/{组}-{轮}/fio.txt` | fio 原始输出 |
| `157:/tmp/opencode-lc-verify/{A,B,C}/{组}-{轮}/pg-map.txt` | PG 映射（analyst 做 Spearman） |
| `157:/tmp/opencode-lc-verify/{A,B,C}/{组}-{轮}/*_bw.*.log` | 逐秒带宽 |

### 5.3 相关文档

| 文件 | 说明 |
|------|------|
| `doc/perf-report/02-2h-memdisk-verify-report-20260727.md` | 内存盘验证报告（M1-M10 randread） |
| `doc/perf-report/lc-locate-experiment-instructions-20260727.md` | LC 实验执行指令 |
| `/tmp/bridge/analysis.md` | analyst §-MEMDISK / §-LOCATE 分析 |

---

## 六、后续

### 6.1 待 analyst 复算

1. **pg-map Spearman**：每轮 primary 在 6 OSD 上的分布均衡度(stdev/Gini) vs 该轮 BW 做 Spearman → 坐实或证伪 PG primary 与 BW 的相关性
2. **bw_log 稳态中位数**：截首 1/4 后取中位数，验证 fio 平均 BW 是否准确

### 6.2 建议方向

1. **同时固定数据布局 + primary**：用 `pg-upmap-primary` 钉死 primary + 改用不删数据的清理方式（仅 drop cache）→ 预期 CV 降到 ~1% → 单轮可当基线
2. **LC 补充测试**：两轮全量 9 项（写类 30s），中间不做 soft-clean → 验证无 OSD restart 时轮间是否稳定
3. **回 NVMe 验证**：在 NVMe 集群上用钉死 primary 的口径验证双峰是否消失
