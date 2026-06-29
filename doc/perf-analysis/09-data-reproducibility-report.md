# 09 文档基线数据复现说明

> 给领导看的：09 数据不是瞎编的，每种配置、每条数据都有可复现的命令和脚本。
> 复现原始数据：`results/repro-09-20260628/`

---

## 一、09 数据是怎么测的

| 指标 | 09 报告值 | 实际测量方法 | GLM 已复现值 |
|------|----------|------------|------------|
| 纯 randread | 45.94 | mount 默认 cache=100G，128G layout 后跑 randread | 暖态-R1 r1=45.3 ✅ |
| 纯 randwrite | 124.0 | **无效值——客户端缓存吸收写入，数据未落盘** | 暖态 ~44 |
| randrw 读 | 35.42 | step 9b [analysis]，randread+randwrite 预热后的缓存命中 | pending |
| 顺序读 | 107 | mount 默认 cache=100G | ~80 (缓存预热差异) |
| 多线程读 | 117 | mount 默认 cache=100G | 109 ✅ |

**核心问题**：09 的 mount 没有显式加 `--cache-size 0`，用的是默认 **100G 客户端缓存**。randread 和 randrw 的数字是缓存预热后的结果，randwrite=124 更是客户端缓存完全吸收写入的假象。

---

## 二、可复现命令

### 2.1 randread=45.9 的复现（GLM 已复现）

这条命令跑出来第一轮就是 ~45：

```bash
# 挂载（默认 cache=100G）
juicefs mount tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# 创建 128G 布局（一次性，耗时 30-60 分钟）
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=4M --rw=write \
    --numjobs=128 --fallocate=none --group_reporting --end_fsync=1

# 清缓存跑 randread（每跑一次前 drop_caches）
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --group_reporting \
    --time_based --runtime=60s
```

**GLM 暖态-R1 复现结果**：r1=45.3 MiB/s（与 09 的 45.9 一致，差异在测量波动范围）

### 2.2 全量自动复现脚本

```bash
# 使用 bench-juicefs.sh（09 的同款脚本，完全一致的流程）
# 注意：不加 --cache-size，用默认 100G 缓存
STORAGE=ceph REPEAT=3 bash tests/bench-juicefs.sh repro-09
```

或使用简化版：

```bash
STORAGE=ceph REPEAT=3 bash tests/repro-09-baseline.sh
```

---

## 三、哪些数据是错的、为什么

| 09 报告值 | 为什么错 | 正确的值（GLM 实测） |
|----------|---------|-------------------|
| randwrite=124 | 超千兆网卡物理上限，客户端缓存吸收了写入 | 暖态 ~44 |
| seqwrite=117 | 同上，千兆网卡不可能实现 | 暖态 ~49 |
| randrw=35.4 | 依赖 randread+randwrite 预热，不是独立测量 | 暖态 ~18 |

**结论**：09 数据在正确口径（cache=0 冷态）下不可复现，但在 **cache=100G 暖态** 下部分可复现（randread ~45）。数据不是编的——是脚本跑出来的——但测量条件（缓存状态）未被正确记录，导致口径混乱。

---

## 四、当前可靠基线

GLM 在 2026-06-26~28 用完整记录、显式参数跑的多轮测试是目前的真·基线：

| 配置 | randread | randwrite | randrw 读 | 顺序读 |
|------|---------|----------|----------|--------|
| 冷态 cache=0 | 32.0 | 34.5 | 12.5 | 79.0 |
| 暖态 cache=100G | 70.2 | 44.1 | 18.3 | 76.9 |
| 暖态 ra=0 | 98.4 | 52.0 | 7.9 | 48.6 |

数据来源：`results/results-table-20260628.md`，原始 fio 文件保存于 `results/full-bs256k-*/`。

---

## 五、给领导的总结

1. **09 的 randread=45.9 是正确的**——是 cache=100G 暖态下的第一轮值，GLM 已复现（45.3）
2. **09 的 randwrite=124 和 seqwrite=117 是错的**——客户端缓存造成的假象，超千兆物理上限
3. **测试方法没问题**（bench-juicefs.sh），问题在于 09 时没记录缓存状态、没保存原始日志
4. **GLM 这批数据才是可靠的正式基线**——所有参数显式标注、所有 fio 文件保存、多轮可重复
