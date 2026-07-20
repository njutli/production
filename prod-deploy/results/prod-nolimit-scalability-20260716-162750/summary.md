# 01-3 测试结果 Summary

## 任务信息
- 任务书：`doc/perf-tasks/01-3-client-scalability-and-cpu-ceiling.md`
- 执行日期：2026-07-16
- 结果目录：`results/prod-nolimit-scalability-20260716-162750/`
- 远端数据（157）：`/tmp/scalability-results/`
- JuiceFS 版本：1.3.1+2025-12-02.e0032b2
- Ceph 状态：全程 HEALTH_OK

## 步骤0：direct_io / FUSE 页缓存确认

- direct_io **未启用**（/proc/mounts 无 direct_io）
- 尝试挂载 `-o direct_io` 失败：fusermount3 3.10.5 (FUSE3) 不支持 direct_io 作为挂载选项
- **结论**：FUSE 页缓存处于开启状态，但 fio `--direct=1` 在 VFS 层绕过页缓存；01-2 数据验证 object GET 与读带宽匹配，读请求确实穿透到后端

## 步骤1：CPU 饱和曲线（ra0，randread，5档×3轮）

| 档 | 并发 | fio_bw | steady_bw | CPU% | cores | FUSE_read | obj_get | NIC_RX | FUSE/NIC | FUSE_lat |
|----|------|--------|-----------|------|-------|-----------|---------|--------|----------|----------|
| S4 | 32 | 1230 | 1230.0 | 566 | 5.7 | 2708 | 2708 | 1260 | 2.15 | 2.8ms |
| S3 | 128 | 1833 | 1834.2 | 573 | 5.7 | 2747 | 2748 | 1879 | 1.46 | 2.8ms |
| S2 | 1024 | 2344 | 2350.2 | 581 | 5.8 | 2790 | 2790 | 2408 | 1.16 | 3.9ms |
| S1 | 4096 | 2740 | 2746.2 | 591 | 5.9 | 2850 | 2850 | 2810 | 1.01 | 5.3ms |
| S0 | 16384 | 2894 | 2876.2 | 595 | 6.0 | 2873 | 2871 | 2932 | 0.98 | 5.4ms |

- FUSE_read ≈ obj_get（全档一致），ra0 无读放大；FUSE/NIC 反映低并发时 FUSE 管线未充分利用

**饱和判定**：S1→S0，bw +4.7%，CPU +0.7% → **双双饱和**
- CPU 封顶 ~595%（6.0 核 / 64 logical = 9.3%）
- bw 封顶 ~2876 MiB/s（rados 后端裸测 3198 的 90%）

## 步骤2：线程级归因 + 参数扫描

### 线程级 CPU
- 正确 PID=2427123，进程 CPU 平均 567%（usr 320 + sys 247）
- **CPU 最集中**：librados msgr-worker-0/1/2（3 个网络线程轮替，稳态各 54-98%），无单线程 100% 锁死
- 其余大量匿名 Go 线程各 ≤4%，CPU 分散分布
- 结论：非单点锁、是单进程总量封顶
- pprof 已捕获（80KB binary），157 上无 go tool，待本地分析

### 参数扫描（S0 16384并发，ra0）
| 参数 | fio_bw | vs baseline |
|------|--------|-------------|
| baseline (max-uploads=150) | 2929 MiB/s | — |
| max-uploads=300 | 2791 MiB/s | -4.7% |
| max-uploads=600 | 2863 MiB/s | -2.3% |

**结论**：max-uploads 对 randread 无增益（反而略降），客户端参数无红利

## 步骤3：多实例倍增测试

### ra0 口径（32×32 per instance，shared read）

| N | 单机总 bw | vs N=1 | 倍增效率 | 每实例均分 |
|---|----------|--------|---------|-----------|
| 1 | 2350 MiB/s | 1.0× | 100% | 2350 |
| 2 | 3865 MiB/s | 1.64× | 82% | 1933 |
| 4 | 5013 MiB/s | 2.13× | 53% | 1253 |

### default 口径（32×32 per instance，shared read）

| N | 单机总 bw | vs N=1 | 倍增效率 | 每实例均分 |
|---|----------|--------|---------|-----------|
| 1 | 1213 MiB/s | 1.0× | 100% | 1213 |
| 2 | 2173 MiB/s | 1.79× | 90% | 1087 |
| 4 | 2822 MiB/s | 2.33× | 58% | 706 |

### 判定

| 判据 | 结果 |
|------|------|
| 单挂载 CPU 是否饱和 | ✅ 595%（6核）封顶，S1→S0 仅 +0.7% |
| 多实例是否倍增 | ✅ N=4 ra0 达 2.13×，default 达 2.33× |
| 倍增是否线性 | ❌ N=4 仅 53%/58% 效率，后端/网络成为共享瓶颈 |

**落到 §一判定表第一行**：✅ 单进程封顶属实，workaround = 多挂载。N=4 时后端/网络开始成为共享瓶颈，限制了线性倍增。

## 目录结构
```
results/prod-nolimit-scalability-20260716-162750/
├── env-snapshot.txt              # 环境快照
├── step0-directio.md              # direct_io 判定
├── step1-scan/                    # CPU 饱和曲线数据
│   ├── processed-summary-v3.txt  # 聚合处理结果
│   ├── scan-summary.txt           # fio 原始 BW 汇总
│   └── fio-S{0-4}-r{1-3}.txt     # 各档各轮 fio 输出
├── step2-threads-pprof/           # 线程级 CPU + pprof
│   ├── pidstat-threads-correct.txt
│   └── pidstat-proc-correct.txt
├── step2-param-sweep/            # 参数扫描
│   └── param-sweep-summary.txt
├── step3-multi-instance/         # 多实例倍增
│   ├── multi-summary.txt
│   ├── {ra0,default}-N{1,2,4}-summary.txt
│   └── {ra0,default}-N{1,2,4}-fio-inst{1-4}.txt
└── scan-run-log.txt              # 扫描运行日志
```

> 原始 bw_log 文件和 juicefs stats 文件保留在 157 `/tmp/scalability-results/`，未全部下载（bw_log 807 个文件，通过三层 SSH 传输耗时过长）
