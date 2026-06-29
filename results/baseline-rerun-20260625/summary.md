============================================================
基线重测（可追溯） 20260625-173440
============================================================

## 测试方法
  脚本: tests/bench-baseline-rerun.sh
  启动命令: cd /home/turboai/production && bash tests/bench-baseline-rerun.sh
  输出目录: results/baseline-rerun-20260625/
  口径: STORAGE=ceph (RADOS 直连), block-size 256K, cache-size 0 (真冷态)
  每项跑前 client drop_caches, 不 drop OSD
  顺序项各 1 次; 随机项 REPEAT=3

## 环境快照

### 集群状态
  ceph status -> results/baseline-rerun-20260625/ceph-status.txt
### 客户端状态
  client status -> results/baseline-rerun-20260625/client-status.txt

## 格式化卷
  STORAGE=ceph, pool=juicefs-data, block-size=256K
## 挂载
  --cache-size 0 (真冷态, 无客户端缓存)
  mount OK

## 顺序测试 (cache-size 0, client drop_caches per item)
### seqread prep (write 4G)
  seqread: READ=78.7 WRITE=NA
  seqwrite: READ=NA WRITE=54.4
  multi-seqread: READ=109 WRITE=NA
  multi-seqwrite: READ=NA WRITE=40.4

## 布局 (128 jobs x 1G = 128G)
  layout: WRITE=31.8

## 随机测试 (reuse layout, cache-size 0, client drop_caches per round)
### Round 1
  randread r1: READ=27.3 WRITE=NA
  randwrite r1: READ=NA WRITE=37.5
  randrw r1: READ=14.5 WRITE=14.2
### Round 2
  randread r2: READ=30.5 WRITE=NA
  randwrite r2: READ=NA WRITE=34.1
  randrw r2: READ=13.9 WRITE=13.7
### Round 3
  randread r3: READ=31.2 WRITE=NA
  randwrite r3: READ=NA WRITE=29.1
  randrw r3: READ=16.3 WRITE=16.0

============================================================
## 汇总
============================================================

所有原始 fio 输出保存在: results/baseline-rerun-20260625/
  - ceph-status.txt (集群状态快照)
  - client-status.txt (客户端状态快照)
  - format.log / mount.log (卷配置)
  - seqread.txt / seqwrite.txt / multi-seqread.txt / multi-seqwrite.txt
  - layout.txt
  - randread-r{1,2,3}.txt / randwrite-r{1,2,3}.txt / randrw-r{1,2,3}.txt
  - summary.txt (本文件)

DONE

---

## 顺序写性能分析：与官方基准的差异

### 现象

| 测试项 | 我们的结果 | 官方基准（S3 后端） | 差异 |
|--------|-----------|-------------------|------|
| seqwrite (1job) | 54.4 MB/s | ~150+ MB/s | 3x 差距 |
| multi-seqwrite (16job) | 40.4 MB/s | ~200+ MB/s | 5x 差距，多进程反而更慢 |

### 根因分析

**1. 挂载参数：--max-uploads 差 7.5 倍**

官方基准挂载命令：
    juicefs mount --max-uploads=150 --io-retries=20 localhost /jfs

我们的挂载命令：
    juicefs mount -d --cache-size 0 tikv://... /mnt/juicefs

--max-uploads 控制 JuiceFS 到后端的并发上传连接数，默认 20，官方测试设 150。
16 个 fio job 同时写时，每个 4M block 都要上传，20 个连接不够用，大量写请求排队。

**2. 后端差异：EC 4+2 vs S3**

| | 官方（S3） | 我们（Ceph EC 4+2） |
|--|-----------|-------------------|
| 写 1 个 4M 对象 | 1 次 PUT | 拆成 6 分片（4 data + 2 parity）写 6 个 OSD |
| min_size | N/A | 5（至少 5 个 OSD ack） |
| 写放大 | 1x | 1.5x（6/4） |
| 每写延迟 | ~10-20ms | ~65ms（单 job） / ~1561ms（16 job） |

**3. 延迟数据印证**

| | 单进程 | 16 进程 | 延迟放大 |
|---|---|---|---|
| avg latency | 65ms | 1561ms | 24x |
| p99 latency | 188ms | 2567ms | 14x |
| 带宽 | 54.4 MB/s | 40.4 MB/s | 0.74x |

16 个 job 抢 20 个上传连接 + EC 写放大 6x = 严重排队。
78% 的写延迟超过 1 秒，最高 3.3 秒。

### 结论

不是 JuiceFS 写性能差，是挂载参数和后端配置与官方基准差异大：
- --max-uploads 差 7.5 倍（20 vs 150）
- EC 4+2 写开销是 S3 的 6 倍（6 分片 vs 1 次 PUT）

### 后续行动

加一轮 --max-uploads=150 对照测试（顺序写单进程/16进程），验证上传连接数对写性能的影响。

---

## 补充分析：cache-size=0 导致 writeback 禁用（Opus 指出）

### 现象

挂载时 JuiceFS 日志输出：


### 原因

官方基准测试使用默认 cache-size（100G），writeback 缓冲开启：
- 写数据先写本地缓存，异步上传到后端，fio 感知的写延迟只是本地磁盘写入延迟
- 官方 mount 命令未指定 --cache-size，使用默认值

我们冷态测试设置 ：
- writeback 被禁用，每次写都要同步上传到后端并等 ack
- fio 感知的写延迟 = 后端完整 RTT（EC 写放大 + 网络往返）
- 这也是  无效的原因：连接数不是瓶颈，同步等待才是

### 影响

| 配置 | seqwrite | multi-seqwrite | 原因 |
|------|---------|---------------|------|
| 官方（cache=100G, writeback on, S3） | ~150+ MB/s | ~200+ MB/s | 写本地缓存，异步上传 |
| 我们（cache=0, writeback off, EC 4+2） | 54.4 MB/s | 40.4 MB/s | 同步写后端，EC 放大 |

### 结论

顺序写性能差异有两个原因（均需验证）：
1. **cache-size=0 导致 writeback 禁用**（Opus 指出）— 写操作同步等待后端，无缓冲
2. **--max-uploads 默认 20 vs 官方 150 + EC 4+2 写放大**（之前分析）— 连接数和后端写开销

验证计划（当前 todo list 完成后再做）：
- 走 RGW + cache=100G + writeback on：预期写性能显著提升
- 直连 Ceph + cache=100G + writeback on：对照 EC 后端 vs S3 后端
