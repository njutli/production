# 测试报告

## 1. 测试概述

全部测试在官方 JuiceFS main commit
`53835e2481f45cba159cdbcc1ce0f1fc576e3f1a` 上执行。
三个独立测试组：

| 组 | 源码修改 | 用途 |
|----|---------|------|
| 未打补丁原版 | + 社区测试文件 | 验证 bug 存在 |
| 修复版 | + 补丁 + 社区测试文件 | 验证修复纠正 bug |
| 语义覆盖 | + 补丁 + 扩展语义测试文件 | 语义/故障/并发覆盖 |

执行环境：WSL（Linux 5.15，16 核，15 GiB 内存），Go 1.26.0，
`GOFLAGS=-mod=readonly`，`GOTOOLCHAIN=auto`。

## 2. 社区回归测试

### 2.1 设计思路

Bug 的根因是**代码路径逻辑问题**（FlushTo 没有被调），不是性能问题。
测试通过 Go interface 和 mock 依赖直接验证派发决策——不需要 FUSE 挂载、
fio、Ceph 或 TiKV。

三个 mock 类型替换外部依赖：

| 依赖 | Mock 实现 | 作用 |
|------|----------|------|
| `meta.Meta`（TiKV） | `delayedSliceMeta` | `NewSlice` 阻塞在 channel 上直到被放行，保证 ID 在 `write` 检查时不可用 |
| `chunk.Writer`（Ceph RADOS） | `recordingChunkWriter` | `WriteAt` 直接返回成功；`FlushTo` 往 channel 写值——测试通过读 channel 判断派发是否发生 |
| `chunk.ChunkStore` | `singleWriterStore` | 总是返回同一个 `recordingChunkWriter` |

测试构造真实的 `dataWriter` 和 `fileWriter`（`writer.go` 的生产类型），
注入 mock 依赖，然后调用真实的 `writeChunk()`——同一条生产代码路径、
同一把互斥锁、同一个 goroutine 启动 `prepareID`。Go 的 interface 分发
确保 `NewSlice()` 和 `FlushTo()` 在运行时调用 mock 实现。

### 2.2 三项测试函数

| 测试函数 | 写入量 | 未打补丁预期 | 修复版预期 | 验证什么 |
|---------|--------|-----------|-------------|---------|
| `TestFullBlockDispatchedWhenSliceIDBecomesReady`（U1） | 256 KiB（满 block） | FAIL：FlushTo 没被调 | PASS：FlushTo 被调 | 主路径：满 block 应该派发 |
| `TestPartialBlockNotDispatchedWhenSliceIDBecomesReady`（U2） | 128 KiB（半 block） | PASS：FlushTo 没被调 | PASS：FlushTo 没被调 | 负控：不满 block 不该派发 |
| `TestFlushErrorRecordedWhenSliceIDBecomesReady`（U3） | 256 KiB + 注入 flush 错误 | FAIL：FlushTo 没被调 | PASS：FlushTo 被调 + s.err=EIO | 错误路径：派发失败记为 EIO |

### 2.3 未打补丁原版判别结果

U1 和 U3 各跑 **10 个独立 `go test -count=1` 进程**（不是在一个进程内
跑 `-count=10`），确保进程级独立。每个进程必须精确失败于目标 marker，
不能有 panic、DATA RACE、timeout 或 build error。

| 测试 | 进程数 | rc | marker | 结果 |
|------|--------|----|--------|------|
| U1 | 10 | 10× rc=1 | 10× "full block was not dispatched after slice ID became ready"（各 count=1） | ✅ TARGET-BEHAVIOR-PRESENT |
| U2 | 1 | rc=0 | N/A（PASS） | ✅ |
| U3 | 10 | 10× rc=1 | 10× "full block with injected flush error was not dispatched"（各 count=1） | ✅ |

原始日志：`raw-test-data/U01/logs/s-u1-run{1..10}.log`、
`s-u2-single.log`、`s-u3-run{1..10}.log`。
RC 文件：`raw-test-data/U01/rc/s-u1-run{1..10}.rc` 等。

### 2.4 修复版结果

| 模式 | U1 | U2 | U3 | 总 PASS | rc | DATA RACE |
|------|-----|-----|-----|---------|-----|-----------|
| single（count=1） | 1 PASS | 1 PASS | 1 PASS | 3 | 0 | 无 |
| count=100 | 100 PASS | 100 PASS | 100 PASS | 300 | 0 | 无 |
| race -count=20 | 20 PASS | 20 PASS | 20 PASS | 60 | 0 | 无 |

原始日志：`raw-test-data/U01/logs/b-single-{u1,u2,u3}.log`、
`b-count100-{u1,u2,u3}.log`、`b-race20-{u1,u2,u3}.log`。

## 3. 扩展语义测试（补充覆盖，未包含在提交补丁中）

我们额外执行了十项语义测试，覆盖修复语义、兼容性、故障处理和并发
（多 block 派发、freeze 跳过、ENOSPC 中止、32 并发等），在修复版
上以同一 writer patch 全部通过：

| 模式 | 测试数 | PASS | 总数 | rc | DATA RACE |
|------|--------|------|------|-----|-----------|
| single | 10 | 10 | 10 | 0 | 无 |
| count=20 | 10×20 | 200 | 200 | 0 | 无 |
| race -count=5 | 10×5 | 50 | 50 | 0 | 无 |

这些测试作为内部加强覆盖保留，不包含在社区提交补丁中。如果 maintainer
有需要可以单独提供。

原始日志：`raw-test-data/U01/logs/q-single.log`、`q-count20.log`、
`q-race5.log`。

## 4. 完整 pkg/vfs 测试套

`go test ./pkg/vfs -count=1` 运行 `pkg/vfs` 包下全部上游 JuiceFS 测试
（19 个官方测试函数）+ 我们的 3 项社区测试 + 10 项扩展语义测试。
使用隔离 Redis 7.2 容器（Docker，仅 loopback，名称含 RUN_ID）作为
上游测试的元数据引擎。

结果：`ok github.com/juicedata/juicefs/pkg/vfs 13.049s`（rc=0）。

原始日志：`raw-test-data/U01/logs/b-full-vfs.log`。

## 5. 测试执行命令

```bash
# Stock 判别（10 个独立进程）
for i in $(seq 1 10); do
  go test -count=1 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
  go test -count=1 -run '^TestFlushErrorRecordedWhenSliceIDBecomesReady$' ./pkg/vfs/
done
go test -count=1 -run '^TestPartialBlockNotDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/

# 修复版验证
go test -count=1 -run '^Test...' ./pkg/vfs/      # single（3 项）
go test -count=100 -run '^Test...' ./pkg/vfs/    # count（3 项 × 100）
go test -race -count=20 -run '^Test...' ./pkg/vfs/  # race（3 项 × 20）

# 完整 pkg/vfs（需要 Redis on 127.0.0.1:6379）
go test ./pkg/vfs -count=1

# 质量门
gofmt -d pkg/vfs/writer.go pkg/vfs/writer_flush_test.go
go vet ./pkg/vfs
make juicefs
```

## 6. 未测试项

- 无。v1.3 真实 Ceph 性能已由 V02 完成（见 §7）。

## 7. fio 性能验证

### 集群架构与环境配置

| 组件 | 配置 |
|------|------|
| 客户端 | 96 核 Xeon 8462Y+，100GbE 网卡 |
| Ceph 集群 | 3 节点，每节点 2 块 7T NVMe OSD，共 6 OSD |
| Ceph 纠删码 | EC 4+2，failure domain = host |
| Ceph pool | `juicefs-data`，256 KiB block size，无压缩 |
| 元数据引擎 | TiKV 3 副本，部署在与 Ceph 相同的 3 个节点 |
| JuiceFS 版本 | v1.3.1（`e0032b2a`）+ loadRange 修复（`eaf3d21f`） |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| fio 负载 | 128 jobs × 1 GiB × 256K bs × randwrite × direct=1 × 180s |

### 说明

以下 fio 结果基于 v1.3.1 真实 Ceph 集群，使用 Latin-square 交错矩阵
（2 个版本 × 3 次挂载 × 3 轮 = 18 randwrite + 18 randrw = 36 个
正式 fio run）：

| 版本 | 源码修改 | 用途 |
|------|---------|------|
| 未打补丁原版 | v1.3.1 base + loadRange 修复 | 验证塌态存在 |
| 修复版 | 未打补丁原版 + 补丁（异步 prepareID + SetID 后 catch-up FlushTo） | 验证修复 |

所有 fio 参数固定：`128 jobs × 1 GiB × 256K bs × randwrite × direct=1 × 180s`，
每个 fio 前四节点 drop_caches，每个写轮后 `gc --compact` + OSD compact。
稳态值从 128 份 per-job bw log 逐秒跨 job 求和、截前 45s、取 p50。
每次挂载取三轮中位，版本级取三次挂载中位。

### v1.3.1 结果

#### randwrite 版本级稳态中位数

| 版本 | 挂载 1 | 挂载 2 | 挂载 3 | **版本级** |
|------|--------|--------|--------|-----------|
| 未打补丁原版 | 561.4 | 560.9 | 560.6 | **560.9 MiB/s** |
| 修复版 | 2078.6 | 1917.0 | 1828.4 | **1917.0 MiB/s** |

修复版每次挂载均高于未打补丁原版最高值，修复/原版比值 3.42。

#### 结论

- 修复版确认恢复：1917 MiB/s，修复/原版=3.42，无 EIO/panic/safety 事件

### 原始日志路径说明

原始数据在 `raw-test-data/V02/juicefs-v02-20260819-110158/runs/` 下，
按 `block{1-3}-{S|B}{1-3}/{randwrite|randrw}-{1-3}/` 组织。其中 `S` 表示
未打补丁原版，`B` 表示修复版。

例如，未打补丁原版挂载 1 的 randwrite 第 1 轮：

- fio 全文：`runs/block1-S1/randwrite-1/fio.txt`
- fio 返回码：`runs/block1-S1/randwrite-1/fio.rc`
- 128 份 per-job bw log：`runs/block1-S1/randwrite-1/S1-rw1_bw.1.log` ~ `S1-rw1_bw.128.log`
- JuiceFS .stats 前后样本：`runs/block1-S1/randwrite-1/stats-pre.txt`、`stats-post.txt`
- 挂载信息：`runs/block1-S1/randwrite-1/mountinfo.txt`
- gc/compact cleanup：`runs/block1-S1/randwrite-1/gc.log`

修复版挂载 1 的 randwrite 第 1 轮同理，路径为 `runs/block1-B1/randwrite-1/`，
bw log 文件名前缀为 `B1-rw1_bw.*`。

## 8. 原始测试数据位置

### Go 测试（U01）

`raw-test-data/U01/`，5159 个文件，按以下结构组织：

- `logs/` — 每个 `go test` 命令的完整 stdout/stderr
- `rc/` — 每个命令的返回码（.rc 文件，一个数字）
- `results.tsv` — 12 列结果索引，每行一个测试命令
- `diffs/b-writer-diff.patch` — 修复版与原版的 git diff
- `meta/` — 各测试组的 git status 快照

例如，未打补丁原版 U1 第 1 次运行：
- 测试输出：`raw-test-data/U01/logs/s-u1-run1.log`
- 返回码：`raw-test-data/U01/rc/s-u1-run1.rc`

修复版 U1 count=100：
- 测试输出：`raw-test-data/U01/logs/b-count100-u1.log`
- 返回码：`raw-test-data/U01/rc/b-count100-u1.rc`

文件名前缀：`s-` = 未打补丁原版，`b-` = 修复版，`q-` = 扩展语义测试。

### fio 性能验证（V02）

`raw-test-data/V02/juicefs-v02-20260819-110158/`，5159 个文件，含全部
fio run × 128 per-job bw log、fio 全文、health/objects/mount identity、
gc/compact cleanup 原文。
