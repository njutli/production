============================================================
--max-uploads=150 对照测试 20260626-093152
============================================================
## 口径: STORAGE=ceph, block-size 256K, cache-size 0, --max-uploads=150
## 目标: 对照默认 --max-uploads=20 的 seqwrite/multi-seqwrite
## 格式化卷
## 挂载 (--max-uploads=150)
  mount OK

## 顺序写测试
### seqwrite prep (write 4G for read baseline)
  seqwrite: READ=NA WRITE=54.0
  multi-seqwrite: READ=NA WRITE=39.9

DONE

---

## 对比分析

| 测试项 | --max-uploads=20（默认） | --max-uploads=150 | 变化 |
|--------|------------------------|-------------------|------|
| seqwrite (1job) | 54.4 MB/s | 54.0 MB/s | -0.7% |
| multi-seqwrite (16job) | 40.4 MB/s | 39.9 MB/s | -1.2% |

### 结论

--max-uploads=150 对写性能**无明显提升**：
- 单进程：54.0 vs 54.4，差异在测量误差内
- 16 进程：39.9 vs 40.4，差异在测量误差内

### 原因分析

--max-uploads 控制的是 JuiceFS 客户端到后端的并发上传连接数。
在直连 Ceph（librados）模式下，EC 4+2 的写放大（6 分片/min_size=5）由
JuiceFS 客户端自己协调，瓶颈不在连接数，而在 EC 写的 OSD 端处理延迟。

对比官方基准用 S3 后端：1 个 PUT 由 RGW 线程池（默认 512 线程）处理 EC 拆分，
客户端的 --max-uploads 才能发挥作用。

### 后续

走 RGW 测试时多进程写预期会更好（EC 并发由 RGW 处理），需实测验证。
