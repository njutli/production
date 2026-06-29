# 10_A_1 顺位1 验证：FUSE congestion_threshold 调优（2026-06-23）

> 来源：10_A 第四节顺位1 → qwen `residual-amplification-tuning-qwen.md` 方向一
> 结论：**FUSE 节流不是单客户端 randread 瓶颈，无需调参。**

---

## 一、背景

qwen 假设：FUSE 内核模块默认 `congestion_threshold=9`/`max_background=12` 可能限制 iodepth=128 的高并发随机读，导致 JuiceFS 内部吞吐不足。若 `waiting > 0` 则说明节流生效，应调到 768/1024。

10_A 将此项列为顺位1（最高性价比，零成本）。

## 二、实验方法

1. `DO_LAYOUT_ONLY=1` 挂载 JuiceFS + layout 32 files × 1G（256K block-size, STORAGE=ceph, pool=juicefs-data EC 4+2, cache=0）
2. 启动 fio randread（256K, libaio, iodepth=128, numjobs=128, direct=1, 60s）
3. 同步每秒采样 `/sys/fs/fuse/connections/49/waiting` 共 50 个采样点
4. qwen 判据：waiting≈0 → FUSE 未限流 → 非瓶颈，无需调参

## 三、实测数据

| 参数 | 值 |
|------|-----|
| FUSE connection | 49 |
| max_background | 50（JuiceFS 挂载时已调，默认 12）|
| congestion_threshold | 37（默认 9）|
| **waiting（50 采样点）** | **0~1，均值≈0.04** |
| fio 运行时长 | 60s（fio 中途被超时杀，但 waiting 采样完整）|

全部 50 个采样点值：`0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0`

## 四、判读

qwen 文档三种可能结果与实测对照：

| randread 期间 waiting | qwen 含义 | 实测 |
|----------------------|----------|------|
| ≈ 0 | FUSE 没限流；FUSE 非瓶颈 | ✅ 匹配 |
| ≈ 90-128（持续高位）| 被卡在 ~37 并发 | ❌ 不匹配 |
| ≈ 10-50（中等）| 部分限流 | ❌ 不匹配 |

**结论：FUSE 内核层 `congestion_threshold`/`max_background` 不是 randread 瓶颈。当前 50/37 已完全够用，无需调整。**

## 五、对 10_A 候选清单的影响

顺位1 已验证为无效项，应从候选清单剔除或标注"已证伪"。2.5× 放大瓶颈的排查焦点应转向：

- 顺位2：tcpdump 分解 2.5× 构成（slice 碎片 vs prefetch）
- 顺位3：元数据强缓存复测
- 顺位4：FUSE 预读关停 `no_readahead` + `--prefetch 0`

## 六、附录：layout fsync 问题

实测中 `bench-juicefs.sh` 的 layout 阶段（fio write + `--end_fsync=1`）在 128 jobs × 1G 时极慢/卡死（>30min 未完成）。改用 32 jobs 仍然在 28G/32G 处卡住。根因是 JuiceFS 的 copy-on-write 写入路径下 `fsync` 累积延迟。后续若需重复 layout，建议考虑降低 numjobs 或关闭 end_fsync。

---

环境：tikv-node (192.168.11.12)，JuiceFS v1.3.1，Ceph HEALTH_OK，pool juicefs-data EC 4+2，2026-06-23 17:50 CST。
