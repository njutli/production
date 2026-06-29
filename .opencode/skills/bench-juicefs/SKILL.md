---
name: bench-juicefs
description: Use ONLY when running, reading, or modifying bench-juicefs.sh. Covers env vars (STORAGE, CEPH_POOL, EXTRA_FORMAT_OPTS, LAYOUT_NUMJOBS, REPEAT), flow control flags (SKIP_LAYOUT, DO_LAYOUT_ONLY, SKIP_RANDWRITE, SKIP_SEQ), step structure, analysis vs spec 口径, and common workflows for single-client JuiceFS performance testing. Trigger on: bench-juicefs, juicefs benchmark, SKIP_LAYOUT, DO_LAYOUT_ONLY, layout reuse, 单客户端测试.
---

# bench-juicefs.sh

位于 `tests/bench-juicefs.sh`。JuiceFS 全周期性能测试脚本，基于 256K block-size + 直连 RADOS (STORAGE=ceph)。

## 调用方式

```bash
bash tests/bench-juicefs.sh <label> [extra_mount_opts...]
```

必须从 `/home/turboai/production` 目录执行。

## 核心 env 变量

| 变量 | 默认 | 作用 |
|------|------|------|
| `STORAGE` | `s3` | 后端类型。**生产测试必须设 `STORAGE=ceph`** 以直连 RADOS |
| `CEPH_POOL` | `default.rgw.buckets.data` | Ceph 数据池名。设为 `juicefs-data`（EC 4+2） |
| `EXTRA_FORMAT_OPTS` | — | 透传给 `juicefs format`。**必须设 `--block-size 256K`** |
| `LAYOUT_NUMJOBS` | `128` | 布局文件数和 randread 并发数。128=128G，32=32G（快速探路） |
| `LAYOUT_FILESIZE` | `1G` | 每文件大小 |
| `REPEAT` | `5` | 每随机项重复次数。调参用 1-3，出正式结论用 3-5 |
| `SKIP_SEQ` | `0` | `=1` 跳过顺序读写（step 4-7），省 ~20min |
| `WARMUP` | `0` | `=1` 在 randread 前执行 warmup 且不清缓存（热态，不作验收依据） |

## 流程控制 flag

### SKIP_LAYOUT=1
跳过 destroy/format/mount/layout（step 1-8），直接在**已挂载且已有 layout 数据**的卷上跑随机项（step 9/9a/9b）。结束时**不下卷不销毁**。

### DO_LAYOUT_ONLY=1
仅建卷 + 布局后退出，不下卷不销毁。**必须配合 `SKIP_SEQ=1`**。结束后卷保留供 `SKIP_LAYOUT=1` 复用。

### SKIP_RANDWRITE=1
跳过随机写/混合项（step 9a/9b/10/11），只跑纯 randread（step 9）。与 `SKIP_LAYOUT=1` 可组合。

## Step 结构

| Step | 内容 | 靠 ENV 跳过 |
|------|------|-----------|
| 1-3 | destroy → format → mount | `SKIP_LAYOUT=1` |
| 4-7 | 顺序读写（单/多 job） | `SKIP_SEQ=1` |
| 8 | Layout（128 jobs × 1G） | `SKIP_LAYOUT=1` 或 `DO_LAYOUT_ONLY=1` |
| 9 | **纯 randread**（analysis 口径，复用 layout） | — |
| 9a | **纯 randwrite [analysis]**（复用 layout） | `SKIP_RANDWRITE=1` |
| 9b | **randrw [analysis]**（复用 layout） | `SKIP_RANDWRITE=1` |
| 10 | **纯 randwrite [spec]**（fresh 空卷，create_on_open） | `SKIP_RANDWRITE=1` |
| 11 | **randrw [spec]**（fresh 空卷，create_on_open） | `SKIP_RANDWRITE=1` |
| 12 | Cleanup + destroy | `SKIP_LAYOUT=1` |

> **[analysis] 口径**（step 9/9a/9b）= 复用真实 layout 数据，可靠。
> **[spec] 口径**（step 10/11）= create_on_open 边写边读，randrw 读 short≈100%，仅作参考。

## 典型用法

### 完整测试（出正式结论，~35-40min）
```bash
STORAGE=ceph CEPH_POOL=juicefs-data \
  LAYOUT_NUMJOBS=128 REPEAT=3 \
  EXTRA_FORMAT_OPTS='--block-size 256K' \
  bash tests/bench-juicefs.sh full-test
```

### 只跑随机读（调参迭代，~25min）
```bash
STORAGE=ceph CEPH_POOL=juicefs-data SKIP_SEQ=1 SKIP_RANDWRITE=1 \
  LAYOUT_NUMJOBS=128 REPEAT=3 \
  EXTRA_FORMAT_OPTS='--block-size 256K' \
  bash tests/bench-juicefs.sh randread-only
```

### 建卷+布局一次保留（~20min）
```bash
STORAGE=ceph CEPH_POOL=juicefs-data SKIP_SEQ=1 DO_LAYOUT_ONLY=1 \
  LAYOUT_NUMJOBS=128 EXTRA_FORMAT_OPTS='--block-size 256K' \
  bash tests/bench-juicefs.sh setup-layout
```

### 复用布局反复测（每轮 ~3min）
```bash
# 只测 randread
STORAGE=ceph CEPH_POOL=juicefs-data SKIP_LAYOUT=1 SKIP_RANDWRITE=1 REPEAT=3 \
  bash tests/bench-juicefs.sh retest-1

# 测 randread + analysis randwrite + analysis randrw
STORAGE=ceph CEPH_POOL=juicefs-data SKIP_LAYOUT=1 REPEAT=3 \
  bash tests/bench-juicefs.sh retest-full
```

## 预读参数与布局：必须分离（重要纪律）

`--max-readahead 0`（或很小的预读值）**会让顺序写严重退化**（实测 117→35~54 MB/s，−43~70%），
导致 step 8 的 128G 布局阶段（128 job 顺序写）**极慢甚至超时卡死**。

**纪律：布局一律用默认参数（全速顺序写），优化的预读参数只在随机/读测试阶段用。** 两步分离：

```bash
# 1) 用默认参数建布局（不带 --max-readahead，避免顺序写退化超时）
STORAGE=ceph CEPH_POOL=juicefs-data SKIP_SEQ=1 DO_LAYOUT_ONLY=1 \
  LAYOUT_NUMJOBS=128 EXTRA_FORMAT_OPTS='--block-size 256K' \
  bash tests/bench-juicefs.sh setup-layout

# 2) 换优化参数（如 --cache-size 0 --max-readahead <值>）复用布局跑随机/读测试
STORAGE=ceph CEPH_POOL=juicefs-data SKIP_LAYOUT=1 REPEAT=3 \
  bash tests/bench-juicefs.sh opt-test --cache-size 0 --max-readahead 0
```

> 同理也更贴近生产：布局/写入用默认预读，随机读路径才用关/小预读。
> 切勿在带 `--max-readahead 0` 的挂载下做大顺序写布局。

## 缓存口径：必须显式 `--cache-size 0` 才是真冷态（重要纠正）

`juicefs mount` 的 **`--cache-size` 默认是 100G**（不是 0），默认目录 `~/.juicefs/cache`。
**不显式传 `--cache-size 0` 时，"冷态"测试实际带着 100G 客户端读缓存**——`drop_caches` 删了缓存目录，
JuiceFS 进程运行中还会写回，删了也白删。

- **冷态口径（瓶颈定位/验收下界）**：挂载必须显式带 `--cache-size 0`。
- **热态口径（重复访问/AI 训练）**：显式传大 cache（如 `--cache-size 102400`），是真实收益，须标注口径。
- **严格冷态还需清服务端**：客户端 drop_caches 清不掉 OSD 端 BlueStore cache（在 ceph 节点）。
  取真冷态须在 3 台 OSD 也 `echo 3 > /proc/sys/vm/drop_caches`，否则 r2/r3 会被服务端缓存预热污染，
  **只认 r1 冷态值**。

## 其他重要约束

1. `SKIP_LAYOUT=1` 必须在 layout 已存在且卷已挂载时使用，不会自动 mount/destroy
2. `DO_LAYOUT_ONLY=1` 必须配合 `SKIP_SEQ=1`，否则会先跑顺序测试再布局
3. `REPEAT` 只影响随机项（每轮 +60s），布局不重复
4. 结果文件写入 `results/<timestamp>-<label>.txt`
5. `drop_caches` 清的是内核 page cache + 缓存目录文件；**真冷态还须挂载时 `--cache-size 0`**（见上节），
   否则默认 100G 缓存仍在写回。WARMUP=1 为热态口径除外。
6. spec randrw 的 READ 因 create_on_open 几乎为 0，**不用于横向对比**
7. 高并发（iodepth=128 × numjobs=128/32）偶发 fio 起不来：根因是前一个 fio 被 SIGKILL 后的残留，
   非系统卡死（见 `doc/perf-analysis/10_issue-1`）。规避：杀完 fio 等几秒、确认 `pgrep -x fio` 为空再起下一个。
