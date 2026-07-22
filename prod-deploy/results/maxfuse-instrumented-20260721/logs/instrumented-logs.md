# Instrumented test logs

## 1. go-fuse write-stats (128K max_fuse_io, file backend)

Mount: `juicefs mount --max-uploads 150 --cache-size 0 --max-readahead 0`
fio: bs=256k, 128 jobs, 20s

```
[write-stats] count=102222 avg_total=1ms handler=1ms response=0ms read_wait=0ms
[write-stats] count=141434 avg_total=2ms handler=2ms response=0ms read_wait=0ms
[write-stats] count=183276 avg_total=2ms handler=2ms response=0ms read_wait=0ms
[write-stats] count=232386 avg_total=2ms handler=2ms response=0ms read_wait=0ms
[write-stats] count=273861 avg_total=2ms handler=2ms response=0ms read_wait=0ms
```

fio result: BW=1715 MiB/s, slat avg=5489μs (5.5ms)

## 2. go-fuse write-stats (256K max_fuse_io, file backend)

Mount: `juicefs mount --max-uploads 150 --cache-size 0 --max-readahead 0 --max-fuse-io 256K`
fio: bs=256k, 128 jobs, 20s

```
[write-stats] count=33837 avg_total=48ms handler=48ms response=0ms read_wait=0ms
[write-stats] count=36238 avg_total=49ms handler=49ms response=0ms read_wait=0ms
[write-stats] count=38639 avg_total=49ms handler=49ms response=0ms read_wait=0ms
[write-stats] count=41040 avg_total=50ms handler=50ms response=0ms read_wait=0ms
[write-stats] count=43428 avg_total=50ms handler=50ms response=0ms read_wait=0ms
```

fio result: BW=542 MiB/s, slat avg=51284μs (51.3ms)

## 3. JuiceFS VFS.Write stats (256K max_fuse_io)

```
[vfs-write] size=262144 wlock=0ms write=110ms total=110ms
[vfs-write] size=262144 wlock=0ms write=10ms total=10ms
[vfs-write] size=262144 wlock=0ms write=10ms total=10ms
[vfs-write] size=262144 wlock=0ms write=10ms total=10ms
[vfs-write] size=262144 wlock=0ms write=10ms total=10ms
```

## 4. fileWriter.Write stats (256K max_fuse_io) — 根因定位

```
[fw-write] size=262144 bufwait=111ms lockwait=0ms chunk=0ms total=111ms bufUsed=581MB bufLimit=300MB
[fw-write] size=262144 bufwait=10ms  lockwait=0ms chunk=0ms total=10ms  bufUsed=447MB bufLimit=300MB
[fw-write] size=262144 bufwait=111ms lockwait=0ms chunk=0ms total=111ms bufUsed=583MB bufLimit=300MB
[fw-write] size=262144 bufwait=10ms  lockwait=0ms chunk=0ms total=10ms  bufUsed=491MB bufLimit=300MB
[fw-write] size=262144 bufwait=10ms  lockwait=0ms chunk=0ms total=10ms  bufUsed=534MB bufLimit=300MB
```

## 5. strace -c summary (256K max_fuse_io, ceph backend)

```
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 95.30   10.717628         102    104614     14233 read
  4.70    0.528061          39     13420           writev
------ ----------- ----------- --------- --------- ----------------
100.00   11.245689          95    118034     14233 total
```

## 6. GC trace (256K max_fuse_io, ceph backend)

```
gc 1 @0.003s 2%: 0.97+0.23+0.036 ms clock, ... 3->4->2 MB, 4 MB goal, ...
gc 2 @0.008s 2%: 0.10+0.43+0.064 ms clock, ... 6->6->5 MB, 6 MB goal, ...
gc 3 @0.014s 3%: 0.099+0.69+0.16 ms clock, ... 10->11->7 MB, 11 MB goal, ...
gc 4 @0.019s 3%: 0.10+1.0+0.23 ms clock, ... 16->16->13 MB, 16 MB goal, ...
```

GC count during fio test (30s): 0

## 7. FUSE kernel waiting counter (256K max_fuse_io)

```
waiting=1 (most samples)
waiting=2 (some samples)
waiting=35 (occasional spike)
waiting=128 (end of test burst)
max_background=50, congestion_threshold=37
```

## 8. Controlled experiment: max_fuse_io=256K with bs=128K

```
slat avg=24187μs (24.2ms)
BW=331 MiB/s
```

Same 128K data per dispatch, same 1 dispatch per I/O, only max_write differs (128K→256K):
per-dispatch slat went from ~4ms to 24.2ms (6×).
