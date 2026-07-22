# max-fuse-io instrumented 测试结果

> 日期：2026-07-21
> 目的：定位 --max-fuse-io 从 128K 调大到 256K+ 时写劣化的根因

## 目录结构

```
patches/
  go-fuse-server-go.patch    # go-fuse server.go 加计时（handler/response/read_wait 分解）
  juicefs-vfs-go.patch      # JuiceFS vfs.go 加计时（wlock/write 分解）
  juicefs-writer-go.patch   # JuiceFS writer.go 加计时（bufwait/lockwait/chunk 分解 + bufUsed/bufLimit）
logs/
  instrumented-logs.md      # 所有采集到的日志汇总
```

## 排查路径

1. 4 值全量基线 sweep（128K/256K/512K/1M）→ 确认写 slat 在 128K→256K 跳变 6×
2. Linux 内核 FUSE 源码分析 → 排除内核阈值（无 128K 硬编码）
3. GODEBUG=gctrace=1 → 排除 GC（128K 和 256K 均为 0 GC）
4. strace -c -f → 排除 syscall 开销（read=102μs, writev=39μs，合计 0.14ms）
5. FUSE waiting 计数 → 排除内核排队（waiting=1-2）
6. go-fuse instrumented → 定位到 handler（49ms 全在 handler）
7. JuiceFS VFS.Write instrumented → 定位到 h.writer.Write（49ms 全在 write）
8. fileWriter.Write instrumented → **定位到 bufwait**（bufUsed=447-583MB > bufLimit=300MB → time.Sleep(10ms)）

## 根因

`fileWriter.Write()` 的 buffer 压力检查触发 sleep：

```go
if f.w.usedBufferSize() > f.w.bufferSize {  // 447-583 MB > 300 MB
    time.Sleep(time.Millisecond * 10)       // ← 每次 sleep 10ms
}
```

256K max_fuse_io → go-fuse readPool buffer 262K（vs 131K）→ Go m.Sys 增长 → 超过 300MB 限制 → sleep。

## 复现方法

```bash
# 构建 instrumented binary（不含 ceph tag，用 file 后端测试）
cd /home/lilingfeng/project/juicefs
# 应用 patches
patch -p1 < results/maxfuse-instrumented-20260721/patches/juicefs-vfs-go.patch
patch -p1 < results/maxfuse-instrumented-20260721/patches/juicefs-writer-go.patch
# 修改 go.mod 指向 instrumented go-fuse
# （先 patch go-fuse，再设置 replace 指令）
go build -o /tmp/juicefs-instr .

# 测试（file 后端，不需要 ceph）
/tmp/juicefs-instr format --storage file --bucket /tmp/jfs-data --block-size 256K --trash-days 0 \
    "tikv://<PD_ENDPOINTS>/testjfs" testjfs
/tmp/juicefs-instr mount --max-uploads 150 --cache-size 0 --max-readahead 0 --max-fuse-io 256K \
    "tikv://<PD_ENDPOINTS>/testjfs" /mnt/juicefs 2>/tmp/jfs.log
fio --directory=/mnt/juicefs/test_dir --bs=256k --rw=randwrite ... --runtime=20
grep "fw-write" /tmp/jfs.log
```
