# 11 下一阶段调优计划 (DeepSeek-V4, 2026-06-24)

> 替换旧 `doc/tun/11-glm51-tuning-supplement.md`。
> 精简已有结论，聚焦未验证方向与行动计划。

---

## 一、现状速览

### 1.1 已达标的

| 指标 | 值 | 判断 |
|------|----|------|
| 顺序读写 | 107-117 MB/s | ≈ 94% 线速，已对齐后端天花板 |
| 纯 randwrite | 63-65 MB/s | > 59 目标 |
| 多客户端聚合 randread (v1.4) | 2-cl=76.5, 3-cl=77.5 | > 59（多客户端口径） |

### 1.2 未达标的

| 指标 | 值 | 目标 | 差距 |
|------|----|------|------|
| 单客户端纯 randread | 45.9 MB/s | 59 | −22% |
| 单客户端 randrw 读写 | ~35 MB/s | 59 | −41% |

### 1.3 瓶颈链（已定量的）

```
有效读 = min(千兆NIC 124, 后端145) ÷ RAF 2.5 ≈ 58 MB/s 天花板
实测 45.9 = 天花板的 79%
```

- **后端 145 MB/s**（双节点 rados bench 4M 对象）有余量，非瓶颈
- **千兆网卡 RX 113 MB/s** = 91% 线速，接近但未完全触顶
- **RAF 2.5×** = 核心瓶颈，确认是纯 JuiceFS 应用层放大（客户端 NIC 不含 Ceph 内部流量）
- **256K block-size** 已是最优（存储零代价，RSS 更低），无需再调
- **v1.3.1 单客户端最优**，v1.4 多客户端更优

---

## 二、预读（Prefetch / Readahead）的已有证据

### 2.1 已测试

| 测试 | 条件 | 结果 | 来源 |
|------|------|------|------|
| `--prefetch 0` vs `--prefetch 16` | 4M block-size, ceph 直连 | randread 5.1 vs 5.1 MB/s（零差异） | `08_2` B |
| `--prefetch 0` vs `--prefetch 16` | 4M block-size, S3/RGW | randread 3.1 vs 3.0 MB/s（零差异） | `08_2` B |
| `--prefetch 0` vs `--prefetch 16` | 256K block-size, rados 直连 | randread 31.3 vs 31.1 MB/s（零差异） | `bs256k-sweep` |

**结论**：JuiceFS 应用层的 `--prefetch` 参数对随机读**无影响**（两次实验、两种 block-size、两种后端，全部归零）。

### 2.2 未测试的盲区

| 盲区 | 说明 | 为何可能有效 |
|------|------|------------|
| **FUSE 内核 readahead** (`-o no_readahead`) | Linux VFS 层在检测到顺序访问模式时自动预读 | 即使 JuiceFS 自身不做 prefetch，内核 VFS 看到足够多的读请求后可能触发自己的预读。256K block 的 4 分片取片模式可能恰好匹配内核的顺序检测窗口 |
| **randrw 下的读写交互** | 写操作创建新文件/新 block 可能改变 readahead 状态 | randrw 中写和读交替，内核预读窗口可能被写操作意外触发 |

### 2.3 判断

- 如果只关注纯 randread → `--prefetch` 不用关（关了也没收益），FUSE `readahead` 是否关**待验证**
- 如果关注 randrw → 读写交互可能引入新的预读路径，**需要验证**
- **关预读会损害顺序读性能**（官方数据：prefetch=1 → 顺序读可用 674→1418 MiB/s 取决于并发度），如果业务混合顺序+随机，不能轻易关闭

---

## 三、关键矛盾与未验证方向

### 3.1 核心矛盾：多客户端 92.1 > 瓶颈链天花板 58

`10_2` v1.4 4-cl randread 聚合 **92.1 MB/s** 超过 `145 ÷ 2.5 = 58` 的理论天花板。两种互斥解释：

| 解释 | 验证方法 |
|------|---------|
| **后端实际能力 > 145**（4M 对象 rados bench 口径错位，256K 对象下更高） | 256K 对象 rados bench（需自写） |
| **多客户端下 RAF 摊薄**（共享连接、TCP 慢启动摊薄） | 多客户端逐机采集 NIC RX，对比 RAF_1 vs RAF_N |

**这个矛盾不解决，后续所有天花板判断都不可信。**

### 3.2 FUSE 节流：Randread 阶段 waiting 未采样

Qwen 文档在 **顺序写** 阶段采集到 `waiting=128, max_background=50, congestion_threshold=37`，但**没在 randread 阶段采集**。顺序写的大块请求堆积不等同于随机读被限流。

```bash
# 零成本验证（1 分钟）
fio --name=randread --bs=256k --rw=randread --ioengine=libaio \
    --iodepth=128 --numjobs=128 --direct=1 --time_based --runtime=60s \
    --directory=/mnt/juicefs/test_dir &
for i in $(seq 1 20); do
    cat /sys/fs/fuse/connections/*/waiting 2>/dev/null
    sleep 3
done
```

**如果 randread 阶段 waiting > 0（尤其是 > 37），调大 `max_background`/`congestion_threshold` 是零成本高收益招数。**

### 3.3 EC 取片来源盲区

`09_1` 第四节排除了 EC 4+2 vs 副本(size=3) 的差异，**但从未测过 EC 2+1**（同 1.5× 存储开销，读分片从 4 降到 2）。这是一个真正的对照——与 4+2 只有分片数差异，没有存储开销差异。

### 3.4 2.5× 来源未分解

已知 2.5× = 纯 JuiceFS 应用层（客户端 NIC 不含 Ceph 后台噪声），但其内部构成未分解：
- slice 碎片化（1 block = 多个 GET）？
- FUSE readahead（拉相邻 block）？
- EC 分片协议开销（4 OSD 各建 TCP 连接）？
- FUSE 内核↔用户态切换？

→ **tcpdump 在客户端侧抓包可精确回答"一次 fio read 触发了几个对象 GET、每个 GET 返回多少字节"。**

---

## 四、下阶段行动计划（按优先级）

### P0：两条零成本快速诊断（并行做，1 小时内）

| # | 方向 | 操作 | 判定 |
|---|------|------|------|
| **P0-1** | FUSE congestion 节流 | randread 期间采样 `/sys/fs/fuse/*/waiting` | waiting>0 → 调大 max_background=1024，预期 +20-40 MB/s |
| **P0-2** | tcpdump 分解 RAF | 客户端 `tcpdump dst port 6800-6803`，统计 GET 数/对象字节 | 1 GET×256K=理想 → RAF 在别处；N GET×640K=slice 碎片+预读 |

**P0 做完了才知道后续该往哪个方向。如果 P0-1 或 P0-2 发现 RAF 低于预期，单客户端路线可能直接达标。**

### P1：解决多客户端矛盾 + 精确标定后端

| # | 方向 | 说明 | 成本 |
|---|------|------|------|
| **P1-1** | 多客户端 RAF 摊薄验证 | 2/3/4 客户端逐机 sar NIC RX，算 RAF_N | 跟 P0-2 同流程，顺手做 |
| **P1-2** | EC 2+1 池对照 | 新建 EC 2+1 池，同口径 randread | 半天（需重建池+format+layout+test） |
| **P1-3** | 256K 对象 rados bench | 替代 4M 对象的 145，给后端天花板精确值 | python rados 脚本，2 小时 |

### P2：降放大手段（P0/P1 有方向后才做）

| # | 方向 | 前提 | 操作 | 预期收益 |
|---|------|------|------|---------|
| P2-1 | 关 FUSE readahead | P0-2 发现 GET 返 >256K | `-o no_readahead` 挂载 | RAF −0.2-0.5× |
| P2-2 | gc --compact 合并 slice | P0-2 发现 N>1 GET/read | `juicefs gc --compact` | RAF −0.3-1.0× |
| P2-3 | `allow_ec_overwrites=false` 对照 | P1-2 无效果后 | 新建 append-only EC 池 | 未知（如果 parity 校验读是幽灵流量 → RAF 大降） |
| P2-4 | FUSE splice/big_read 零拷贝 | P0-1/2 均无效后 | 挂载 splice_read+max_read=4M | CPU 侧收益，RAF 本身不变 |

### P3：不推荐或低优先级

| 方向 | 原因 |
|------|------|
| MTU 9000 jumbo frame | 4 个交换机 + 4 台机器全链路改 MTU，风险/收益不成比例（预期 RAF 降 0.05×） |
| PG primary 均衡 | 小集群（6 OSD）PG 分散有限，不做也影响不大 |
| BlueStore cache_size_ssd | `10_1` 已确认 BlueStore 参数无效（瓶颈在上层协议栈） |
| 元数据强缓存 | TiKV 仅 1ms 延迟，180 ops/s × 1ms = 18% 时间占比，不是主因 |
| 升万兆网卡 | RAF 2.5× 不变，达标率 = 1/RAF，升网卡不解决比例问题 |
| pprof 热力图 | 诊断价值不如 tcpdump（pprof 看 CPU 花在哪，tcpdump 看流量花在哪） |

---

## 五、决策树

```
P0-1: FUSE waiting 采样 + P0-2: tcpdump 分解
  │
  ├─ waiting > 0 → 调 max_background=1024 复测
  │   ├─ randread > 59 → 达标，FUSE 节流是主因
  │   └─ randread 还是 46-50 → P0-2 结果决定方向
  │
  ├─ tcpdump: 1 GET/read × 256K → RAF 未分解，主因不是 slice/预读
  │   └─ 做 P1-2 EC 2+1 池对照 + P1-3 256K rados bench
  │
  ├─ tcpdump: N>1 GET/read × 640K → slice 碎片 + 预读是主因
  │   └─ 做 P2-1/2: 关 FUSE readahead + gc --compact
  │
  └─ P0 做完 RAF 仍 2.5× → 单客户端 49.6 物理上限坐实
      ├─ 转多客户端路线（v1.4 2-cl 76.5 已达标）
      └─ 或接受 45.9 / 59 = 78% 达标率
```

---

## 六、对 "10_A 第四节" 未完成测试的评估

由于未找到 `10_A` 文档，理解为 10 系列中未闭环的验证项，逐项评估：

| 来源 | 未完成项 | 是否有必要 | 理由 |
|------|---------|-----------|------|
| `10_2` §四 | 4-cl 顺序读写超时 | **不必要** | 顺序读写已达标（107-117），不进入 randrw 验收 |
| `10_2` §五 | 256K 对象 rados bench | **必要** | 4M 对象 145 口径错位，256K 对象后端能力待定标 |
| `10_2` §六矛盾 | 多客户端 92.1 > 天花板 58 的正面对数 | **必要** | 矛盾不解，所有天花板判断不可信 |
| `10_1` §四 | `--max-downloads` 对 128G 工作集 sweep | **不必要** | 32G sweep 已显示 100+ 饱和，128G 不会不同 |
| `08_2` 待办② | 叠加缓存 | **不必要** | 冷态验收口径（已明确不采用热态） |

---

## 七、一句话

**先做 P0（FUSE waiting + tcpdump，1 小时零成本），再做 P1（EC 2+1 + 256K rados bench + RAF 摊薄，半天）。P0 能排除"FUSE 内核限流"和"slice 碎片的幽灵放大"，这两步做完了，瓶颈链是否可破、拿什么破，自然见分晓。**
