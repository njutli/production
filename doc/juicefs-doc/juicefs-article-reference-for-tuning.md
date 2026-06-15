# JuiceFS 官方文章与当前调优工作的参考映射

> 分析来源：GLM 5.1
> 生成时间：2026-06-15
> 基于项目：/home/lilingfeng/demo/production（JuiceFS + TiKV + Ceph RGW 生产环境调优）

---

## 一、与架构选型和瓶颈方向相关的文章

### 1. 《从 CephFS 到 JuiceFS：同程旅行亿级文件存储平台构建之路》

- **URL**: https://juicefs.com/zh-cn/blog/user-stories/cephfs-vs-juicefs-draco-travel-file-storage
- **作者**: 位传海@同程旅行，2024-12-13

**与当前调优的对应点**：

- **S3 链路中间层延迟损耗**：同程发现四层 LB 有较大延时损耗，升级到 DPDK 版 LB 后显著提升。我们的双 RGW+HAProxy 架构可以参考这个经验。

  **具体可尝试的操作**：

  1. **绕过 HAProxy 直连 RGW 测试**：当前架构是 JuiceFS → HAProxy → RGW，同程经验表明 LB 层可能有隐藏延迟。可临时修改 JuiceFS 的 `--bucket` 参数直接指向某个 RGW 节点（如 `http://192.168.11.11:8080`），跳过 HAProxy，对比随机读延迟是否有变化。若无变化则 HAProxy 不是瓶颈；若有改善则考虑优化 LB 或换 DPDK 方案。

  2. **直连 RADOS（去掉 RGW）**：同程的核心优化是缩短链路。当前 07 文档已确认 RGW object GET 延迟 ~100ms 是主因，08 文档方向三已规划此测试。JuiceFS 支持 RADOS 后端，格式化时指定 `--storage rados`，彻底去掉 HTTP/RGW 层。这是对当前瓶颈最直接的一刀：

     ```bash
     # 格式化新文件系统，使用 RADOS 后端（替代 S3/RGW）
     juicefs format \
         --storage rados \
         --bucket rados://default.rgw.buckets.data \
         tikv://127.0.0.1:2379/juicefs-rados \
         juicefs-rados

     # 挂载
     juicefs mount -d tikv://127.0.0.1:2379/juicefs-rados /mnt/juicefs-rados
     ```

     > 权衡：去掉 RGW 失去 S3 协议兼容（其他终端无法标准 S3 接入）。若业务无此需求，去 RGW 是净收益；若有，可另起 RGW 仅供外部，JuiceFS 走 RADOS。

### 2. 《vivo 轩辕文件系统：AI 计算平台存储性能优化实践》

- **URL**: https://juicefs.com/zh-cn/blog/user-stories/vivo-ai
- **作者**: 于相洋@vivo，2024-10-25

**与当前调优的对应点**：

- **分布式读缓存层 + warmup**：vivo 用 JuiceFS warmup 预加载训练数据到缓存层，读取延迟从"十几到几十毫秒"降到"10ms 以内"。**如果验收允许缓存，这是最直接可参考的实践**。

  **具体操作步骤**：

  > 注意：warmup 对 randrw 帮助有限——写操作会修改数据块导致缓存失效，randrw 场景缓存命中率极低（07 文档已验证：去掉 `--direct=1` 也无变化 3.7 vs 3.8）。若验证 warmup 效果，应改用纯随机读测试。

  ```bash
  # 1. 先写入数据
  fio --directory=/mnt/juicefs/test_dir --name=write_data \
      --nrfiles=100 --filesize=1G --size=1G --bs=256k \
      --rw=write --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
      --group_reporting --time_based --runtime=60s

  # 2. warmup 预热
  juicefs warmup /mnt/juicefs/test_dir

  # 3. 纯随机读测试（而非 randrw）
  fio --directory=/mnt/juicefs/test_dir --name=randread_test \
      --nrfiles=100 --filesize=1G --size=1G --bs=256k \
      --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 \
      --group_reporting --time_based --runtime=60s
  ```

  最终验收口径是 randrw，warmup 的收益在 randrw 中会被写操作稀释。

### 3. 《从资源闲置到弹性高吞吐，JuiceFS 如何构建 70GB/s 吞吐的缓存池》

- **URL**: https://juicefs.com/zh-cn/blog/solutions/building-high-throughput-cache-pool-resilience-with-juicefs
- **作者**: 蔡敏，2025-07-25

**与当前调优的对应点**：

- **内存盘做本地缓存**：此文核心思路是利用各节点闲置磁盘/内存作为缓存。本环境可直接用 tmpfs 构建 JuiceFS 本地缓存：

  ```bash
  # 1. 创建内存盘作为缓存目录
  mkdir -p /dev/shm/jfsCache
  mount -t tmpfs -o size=10G tmpfs /dev/shm/jfsCache

  # 2. 挂载时指定缓存目录为内存盘
  juicefs mount -d tikv://127.0.0.1:2379/juicefs-prod /mnt/juicefs \
      --cache-dir /dev/shm/jfsCache \
      --cache-size 10240
  ```

  > 注意：07 文档已验证 randrw 场景缓存命中率极低（去掉 `--direct=1` 也无变化 3.7 vs 3.8），用内存盘做缓存对 randrw 帮助不大。只有 warmup + 纯随机读（randread）才能受益。

---

## 二、按调优优先级的参考映射总表

| 优先级 | 调优方向 | 状态 | 参考文章 | 具体操作 |
|---|---|---|---|---|
| 1 | **去 RGW 直连 RADOS** | 待测 | 同程旅行 | 缩短链路（JuiceFS→RADOS），去掉 RGW HTTP ~100ms 延迟；需 `--storage rados` 重新格式化 |
| 2 | **绕过 HAProxy 直连 RGW 对比** | 待测 | 同程旅行 | 修改 `--bucket` 直连 RGW 节点，验证 HAProxy 是否引入额外延迟 |
| 3 | **warmup + randread 缓存预热** | 可选 | vivo | 先写数据→warmup→纯随机读测试；对 randrw 帮助有限（写使缓存失效） |
| 4 | **内存盘做本地缓存** | 可选 | 缓存池 | tmpfs 做 `--cache-dir`；对 randrw 同样帮助有限（缓存命中率极低） |

---
