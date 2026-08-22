# VFS 异步分配 slice ID 时可能漏派发完整 block

## 问题概述

当写入创建新的 slice 时，`prepareID` 以 goroutine 异步执行。如果首次写入
在 slice ID 就绪前就写满了一个完整 block（写入大小 == block size），
`sliceWriter.write` 因 `s.id == 0` 跳过 `FlushTo`。ID 后续就绪时，ID 就绪
路径只调 `SetID`，不补做被跳过的派发。数据滞留内存，最终触发客户端缓冲
节流，导致 randwrite 吞吐崩塌。

## 受影响版本

- **v1.3.x**（`e0032b2a`）：严重——randwrite 吞吐崩塌约 3.4 倍
  （256 KiB block size 下 560.9 vs 1917.0 MiB/s，Latin-square 3 挂载
  交错实测）。
- **main**（`53835e24`）：同一竞态代码存在（插桩实测跳过率 99.2%），但
  main 的 commitThread 重构（#6311 "improve lock management in commitThread"）
  使兜底排水更快——滞留数据在缓冲超限前被吸收，新鲜环境下不出现可见
  崩塌。但代码路径仍然不正确，只是被掩盖。

## 根因分析

### 写路径时序

```
writer.go:257  writeChunk()     — 持有 f.Lock()
writer.go:268    go s.prepareID()  — goroutine，需要 f.Lock() → 被阻塞
writer.go:277    s.write()         — 检查 s.id > 0 → s.id == 0 → FlushTo 被跳过
                  f.Unlock()         — writeChunk 返回
                  prepareID 拿到锁 → NewSlice → SetID → 不补 FlushTo
```

`prepareID` 需要和 `writeChunk` 同一把 `fileWriter` 互斥锁。Go 的 mutex
不可重入，`prepareID` 无法在 `writeChunk` 内同步执行——它被作为 goroutine
启动，被锁阻塞直到 `writeChunk` 返回。此时 `write` 已经检查过 `s.id`
（发现为 0）并跳过了 `FlushTo`。`prepareID` 后续设置 ID 时，被跳过的派发
不会被重新触发。

### 为什么只有满 block 随机写触发可见崩塌

- **block size == 写入大小**（如 256K block + 256K fio bs）：首次写即写满
  block，`FlushTo` 被跳过，随机写不会再访问同一 slice → 没有第二次派发机会。
- **写入大小 < block size**（如 128K bs）：内核将 256K 应用写拆成两笔连续
  128K，第二笔续写同一 slice，此时 ID 已就绪 → `FlushTo` 命中。
- **顺序写/混合读写**：后续写或读操作穿插给兜底排水（5 秒定时、10 秒强制）
  足够时间清空积压。

### 为什么 main 不崩塌而 v1.3 崩塌

两个版本都有同一竞态（跳过率均 99.2%）。差异在兜底排水速度：

- **v1.3.1**：`commitThread` 用 `defer f.Unlock()`——整个函数生命周期持锁，
  仅在 `WaitWithTimeout(100ms)` 时短暂放锁。`prepareID`（被 `flushData`
  兜底调用）抢锁困难 → 排水慢 → 缓冲增长超过 300 MB 阈值 → 节流启动
  （每笔写睡 10/100ms）→ 自锁在 ~560 MiB/s。
- **main**（#6311）：去掉 `defer f.Unlock()`，锁持有窗口更短；#7016 增加
  提交依赖追踪（`dep`/`committed`/`commitcond`）实现有序提交 →
  `prepareID` 更快拿到锁 → 排水跟得上写速率 → 缓冲不涨 → 不触发节流 →
  ~1900+ MiB/s。

B patch 不改变排水速度——它通过在 `SetID` 后补做 `FlushTo` 消除滞留源头。
在 v1.3.1 上防止缓冲涨起；在 main 上缓冲本已被兜底排空，patch 无额外
可见效果。

## 修复

在 `prepareID` 的 `SetID` 之后，检查 slice 是否已包含完整 block 并补派发：

```go
if s.writer != nil && s.writer.ID() == 0 {
    s.writer.SetID(s.id)
    // 新增：
    if s.id > 0 && !s.freezed && int(s.slen) >= f.w.blockSize {
        if err := s.writer.FlushTo(int(s.slen)); err != nil {
            logger.Warnf("flush inode: %v chunk: %d after preparing slice ID: %s",
                s.chunk.file.inode, s.id, err)
            s.err = syscall.EIO
        }
    }
}
```

修复保持 `prepareID` 异步设计不变（不同于将 `NewSlice` 改为同步——那会在
元数据 roundtrip 期间持 `f.Lock()` 阻塞同一文件的其他写）。仅在 ID 设置后
增加条件性补派发——`pkg/vfs/writer.go` 共 7 行。

## 历史背景

异步 `prepareID` 原本是合理的：2021 年 `NewSlice` 每次调用都做真实元数据
roundtrip（Redis/TiKV，毫秒级），异步化避免写路径被阻塞。2022 年 #2397
重构 `NewSlice` 为本地计数器 + 批量预分配（每 4096 个 block 一次 roundtrip），
使大多数调用为微秒级。但异步外壳从未被重新审查，竞态由此遗留。
