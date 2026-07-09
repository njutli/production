# 全内存盘 JuiceFS 全量冷态基线报告

> 日期：2026-07-08 ~ 2026-07-09
> 配置：6 OSD DATA+WAL/DB 全 tmpfs + JuiceFS --cache-size 0（无 --max-readahead 0）
> 口径：与 cold-baseline-recheck-20260706 完全一致（cache=0, 无 mu, 无 ra）

## 全量结果（7 项）

| 测试 | 真盘 | 全内存盘 | 变化 | 过 59? |
|------|------|---------|------|--------|
| seqread 4G 256K | 82.7 MB/s | **106 MB/s** | +28% | ✅ |
| seqwrite 4G 256K | 58.0 MB/s | **117 MB/s** | +102% | ✅ 2.0× |
| multi-seqread 16j×4G | 115 MB/s | **117 MB/s** | +2% | ✅ |
| multi-seqwrite 16j×4G | 42.8 MB/s | **49.4 MB/s** | +15% | ❌ |
| randread 16j×128 60s | 41.7 MB/s | **58.2 MB/s** | +40% | ❌ (差0.8) |
| randwrite 16j×128 60s | 45.1 MB/s | **127 MB/s** | +182% | ✅ 2.2× |
| randrw 16j×128 60s | 18.9(r) | 28.3(r)+28.8(w)=57.1 | +50% | ❌ (差1.9) |

## 分析

### 写指标（验收核心）
- **seqwrite 117 MB/s = 2× 目标**：后端无磁盘瓶颈后，JuiceFS 写打满 NIC
- **randwrite 127 MB/s = NIC 饱和**：direct I/O + 高并发直接打满
- **multi-seqwrite 49.4 MB/s**：16 job buffered write 受 JuiceFS 上传管道限制（非后端瓶颈，真盘也仅 42.8）

### 读指标
- **seqread 106 MB/s**：接近 NIC（JuiceFS 顺序读开销小）
- **randread 58.2 MB/s**：受 JuiceFS 读路径限制（FUSE + TiKV 元数据 + object get 串行），接近 59 但不达标
- **randrw 57.1 MB/s 总**：读写各半，受 randread 拖累

### multi-seqwrite 瓶颈分析
单 job seqwrite=117 vs 16 job multi-seqwrite=49.4，退化 2.4×。原因：
- --cache-size 0 下 writeback 禁用，每次写同步上传
- 默认 --max-uploads 不足以支撑 16 job 并发上传
- 之前真盘也是 42.8（同样未用 --max-uploads）
- **加 --max-uploads 150 预期可大幅提升**（其他测试脚本均用此参数）

## 结论

1. **写验收指标 seqwrite 117 MB/s = 2× 目标** ✅
2. **全内存盘后端消除 DATA 写瓶颈后，JuiceFS 写 = NIC 饱和**
3. **multi-seqwrite 受 JuiceFS 上传管道限制**（非后端，需 --max-uploads 优化）
4. **randread 58.2 接近 59**（JuiceFS 读路径开销，冷态无 cache）
5. **所有指标均优于真盘**（+2% ~ +182%），全内存盘确实提升全路径性能
