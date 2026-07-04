# 顺序读 vs 随机读 同口径对比 v2

> 日期：2026-06-29
> 环境：JuiceFS v1.3.1 / Ceph EC 4+2 (6 OSD) / 1Gbps
> 挂载：`--cache-size 0` (mount.log 确认 `writeback and prefetch will be disabled`)
> 工作集：128G（128 jobs × 1G），block-size=256K，layout 复用 repro-09

## 冷态处理

每轮 fio 前执行 `drop_all()`：
- 客户端：`sync; echo 3 > /proc/sys/vm/drop_caches`
- 3 台 OSD：SSH 到 192.168.11.11/13/14 执行同上 + 回显 OK 确认
- 所有 SSH 确认 OK 后才起 fio，drop 完成后等待 2s

## 1. 随机读 3 轮

| round | BW (MiB/s) | NIC RX (MiB) | NIC/FIO |
|-------|-----------|-------------|---------|
| r1 | **33.7** | 7,109 | 3.45× |
| r2 | 33.7 | 7,121 | 3.45× |
| r3 | 34.5 | 7,106 | 3.39× |

> GLM 冷态基线 r1=33.6 — 复现

## 2. 顺序读同口径对照

| 模式 | numjobs | BW (MiB/s) | NIC/FIO |
|------|---------|-----------|---------|
| randread | 128 | 33.7 | 3.45× |
| seqread (direct=1) | 128 | **108** | **1.08×** |

## 3. 并发扫描

| numjobs | BW (MiB/s) | NIC/FIO |
|---------|-----------|---------|
| 8 | 34.7 | 3.22× |
| 32 | 36.7 | 3.17× |
| 64 | 35.9 | 3.24× |
| 128 | 33.7 | 3.45× |
| 256 | 35.2 | — |

> NIC/FIO 恒 ~3.2-3.5×

## 4. OSD 侧延迟（randread 55s 窗口）

| osd | Δops | avg(ms) | node |
|-----|------|---------|------|
| 0 | 1,793 | 11.6 | node1 |
| 1 | 8,749 | 14.1 | node1 |
| 2 | 11,040 | 15.0 | node2 |
| 3 | 13,355 | 15.0 | node2 |
| 4 | 12,906 | 16.9 | node3 |
| 5 | 14,971 | **30.3** | node3 |

> 采集方法：`cephadm shell -- ceph daemon osd.X perf dump osd`，fio 运行前后各一次，取 `op_r_latency` 的 (sum_after-sum_before)/(avgcount_after-avgcount_before)

## 文件清单

```
seqrand-osd-compare-v2-20260629/
├── README.md                 本文件
├── test-script.sh            完整测试脚本（含所有命令）
├── test-script.log           脚本运行日志
├── env.txt                   环境信息
├── randread-r{1,2,3}.txt    随机读 3 轮 fio 输出
├── seqread-128j.txt          顺序读 fio 输出
├── randread-nj{8,32,64,256}.txt 并发扫描
├── osd-delta-osd{0-5}-before.json  OSD perf dump (fio前)
├── osd-delta-osd{0-5}-after.json   OSD perf dump (fio中)
└── osd-delta-fio.txt         OSD 采集期间的 fio 输出
```

## 关联数据

- GLM 冷态基线：`results/full-bs256k-cold-r1-20260626-200742/`、`results/full-bs256k-cold-r2-20260626-224117/`
