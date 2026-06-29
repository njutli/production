# GLM5.1 调优方向补充（2026-06-22）

> 基于对 `doc/perf-analysis/` 01–10 全系列文档的完整阅读，在已有分析基础上补充的
> 调优方向与手段。文档命名 `11-glm51-tuning-supplement.md` 体现模型标识。
>
> **前置结论认同**：10 系列文档的瓶颈定位链已非常扎实——单客户端随机读 45.9 MB/s
> = `min(后端118 ÷ 2.5×, NIC 113 ÷ 2.5×)`。已排除网络/介质/RGW/TiKV/BlueStore/
> EC取片/客户端参数，全部闭环。以下为在此基础上的补充。

---

## 一、关键硬约束：单客户端 59 MB/s 在物理上不可达

### 1.1 计算

当前残余读放大 2.5× 意味着每 1 字节有效读需要 2.5 字节 NIC RX 流量：

```
59 MB/s × 2.5 = 147.5 MB/s > 124 MB/s (1 Gbps 线速)
```

即使 NIC 跑到 100% 线速（实际不可能），理论极限：

```
124 ÷ 2.5 = 49.6 MB/s
```

当前 45.9 已达理论极限的 92.5%，剩余空间仅 ~3.7 MB/s。

### 1.2 推论

**在 1 Gbps + 2.5× 残余放大条件下，单客户端 59 MB/s 在物理上不可能实现。** 这意味着：

| 路径 | 条件 | 单客户端理论极限 |
|------|------|----------------|
| 保持 1Gbps + 2.5× | 当前 | 49.6 MB/s |
| 降放大到 2.1× + 1Gbps | 需压掉 0.4× | 124/2.1 = 59.0 MB/s（刚好达标） |
| 保持 2.5× + 升万兆 | 硬件升级 | 1240/2.5 = 496 MB/s（远超） |
| 降放大到 1.5× + 1Gbps | 理想情况 | 124/1.5 = 82.7 MB/s |

> 这一计算在 01–10 文档中被分别暗示但从未正面给出。它直接决定后续方向的取舍。

---

## 二、2.5× 残余放大的精确分解——仍有未探测的盲区

### 2.1 当前认知

09_1 步骤 2A 已排除 EC 取片（换副本后 NIC RX ≈相同、2.5× 不变），判定放大在 FUSE
路径。但 **2.5× 的具体构成仍未分解**——只知道"不是 EC"，不知道"是什么"。

### 2.2 可能的来源分解

> ⚠️ **2026-06-23 修正**：原稿将"Ceph OSD→OSD 心跳等后台噪声"列为 0.2–0.5× 贡献，
> 这是**错误的**。tikv-node(.12) 的 NIC RX 不含 Ceph 节点间流量（OSD 心跳/MON 同步/
> PG Peering 全在 .11/.13/.14 之间流动，不经过 .12），TiKV 查询走 localhost loopback
> 也不走物理网卡。因此客户端侧的 2.5× = NIC RX / fio 有效读，**几乎全是 JuiceFS
> 应用层数据路径放大**，不含后台噪声稀释。下表已修正。

| 来源 | 预估贡献 | 说明 |
|------|---------|------|
| **JuiceFS slice 碎片化**（1 个 block = N 个 slice = N 个对象 GET） | 1.0–2.0× | 部分覆盖写后 block 分裂成多个 slice，读 256K block 需 GET 多个对象 |
| **JuiceFS 内部 readahead/prefetch** 拉了相邻 block | 0.5–1.0× | `--prefetch=1` 默认值可能在随机读下仍然拉取相邻 block；08_2 B 实验测 `--prefetch 0/16` 几乎无变化，但对象层放大可能是 slice 碎片 + prefetch 叠加 |
| librados/S3 协议帧 ( messenger header / auth / keepalive ) | ~0.05× | 每对象几百字节框架开销，量级极小 |
| TCP/IP 头开销 | ~0.02× | 每包 52 字节，量级极小 |
| ~~Ceph OSD→OSD 心跳 / MON 通信~~ | ~~0.2–0.5×~~ ❌ | **不经过客户端 NIC**，不是 2.5× 的来源 |
| ~~TiKV 元数据查询的 NIC 流量~~ | ~~0.05×~~ ❌ | **走 localhost loopback**，不走物理网卡 |

**修正后的判断**：2.5× 的主体是 JuiceFS 应用层放大——即"一次 fio 256K 读触发了几
个对象 GET"和"每个 GET 拉了多大数据"。协议帧/TCP 头的贡献极小（<0.1×）。

### 2.3 关键修正：客户端 NIC RX 不含 Ceph 后台噪声

> ⚠️ **2026-06-23 修正**：本节原稿认为"`sar` 统计全部 RX 包含非数据流量、后台噪声
> 可能虚高"——对**客户端侧**测量这是错误的。

08_2 四之二和 09_1 中 NIC RX 监控用的是 `sar -n DEV 1`，统计的是网卡全部 RX 流量。
但关键区分：

- **tikv-node(.12) 的 NIC RX**：几乎全是 JuiceFS → Ceph OSD/RGW 的数据响应流量。
  Ceph 节点间通信（OSD 心跳/MON 同步/PG Peering）在 .11/.13/.14 之间流动，**不经过
  .12 的物理网卡**。TiKV 查询走 localhost loopback（127.0.0.1:2379），也不走物理网卡。
  → **客户端侧的 2.5× 是纯 JuiceFS 应用层数据路径放大，不含后台噪声稀释。**

- **ceph-node(.11/.13/.14) 的 NIC RX/TX**：包含 OSD 间心跳/MON 通信 + 客户端数据
  流量 + RGW 服务流量，多角色混合。08_2 四之二中 ceph-node1 兼客户端时 RX=86、
  TX=56——这里的 TX 包含 OSD 对外服务读 + 对其他 OSD 的心跳/PG 同步。**千兆全双工
  下 RX 和 TX 各自独立，不互抢**（已修正，见 09_deepseek_0619），但 ceph 节点侧的
  NIC 数据**不能直接用来算读放大倍数**，因为 TX 里混了非数据流量。

### 2.4 建议验证：tcpdump 精确分解 JuiceFS 应用层放大

tcpdump 在**客户端侧**能回答两个关键问题：

1. **一次 fio 256K 读触发了几个对象 GET？**——如果 >1，说明 slice 碎片化或 prefetch
   在拉多余对象。
2. **每个对象 GET 返回了多少字节？**——如果 >256K，说明 readahead/prefetch 在拉
   相邻 block 的数据。

```bash
# randread 期间，在客户端 tikv-node 上抓 Ceph 数据端口
sudo tcpdump -i eno1 -c 50000 'dst port 6800 or dst port 6801 or dst port 6802' \
    -w /tmp/ceph-randread.pcap

# 另一终端跑 60s randread，然后分析
sudo tcpdump -r /tmp/ceph-randread.pcap -q 2>/dev/null | \
    awk '{total += $NF} END {print "Total packets:", NR}'

# 更精确：用 tshark 统计 TCP payload
sudo tshark -r /tmp/ceph-randread.pcap -T fields -e tcp.len | \
    awk '{s+=$1} END {print "Ceph data payload:", s/1024/1024, "MB"}'
```

将 Ceph 数据端口的纯 payload 与 fio 报告的有效读对比，得到**真实的读放大倍数**。
注意：由于客户端 NIC RX 不含 Ceph 后台噪声，tcpdump 测出的放大倍数应该与 `sar`
测出的 2.5× 高度一致（差异仅在 TCP/IP 头 ~0.02× 和 librados 协议帧 ~0.05×）。

**tcpdump 的真正价值不在"发现放大低于 2.5×"，而在分解 2.5× 的构成**——回答
"一次 256K 读触发了几个对象 GET"和"每个 GET 返回多少字节"，从而定位放大来源
（slice 碎片化 vs prefetch vs 其他），对症下药。

### 2.5 补充验证：JuiceFS slice 碎片化

JuiceFS 的一个 block 在被部分覆盖写后，会分裂成多个 slice 分布在不同对象上。
**读一个 256K block 可能需要 GET 多个对象**（每个对象包含该 block 的一个 slice）。

如果测试卷经历了多轮 layout + randwrite + destroy，slice 碎片可能累积，导致
读放大高于理论值。这在 256K block-size 下影响更大（block 更小、被覆盖的概率更高）。

**验证**：

```bash
# 在测试卷上检查 slice 碎片
juicefs fsck tikv://192.168.11.12:2379/juicefs-prod
juicefs info tikv://192.168.11.12:2379/juicefs-prod <testfile>

# 对比 slice 数 vs block 数
# 如果 slice >> block → 碎片化严重
```

**缓解**：

```bash
juicefs gc tikv://192.168.11.12:2379/juicefs-prod --compact
```

合并碎片 slice 可能降低每次读触发的对象 GET 数，从而降低放大倍数。

---

## 三、FUSE 层参数调优——未充分探索的选项

### 3.1 FUSE splice 零拷贝

Linux FUSE 支持 splice 零拷贝（`splice_read` / `splice_write` / `splice_move`），
可减少内核↔用户态的内存拷贝次数。虽然 splice 不直接影响 NIC 流量（不影响 2.5×
放大），但它**减少 CPU 开销和内存带宽占用**，在高并发随机读场景下可能释放 CPU
瓶颈，间接提升吞吐。

07 文档中记录 JuiceFS 随机读 CPU 峰值达 1067%（全部核心），splice 可能降低这个
峰值，让 CPU 不再是隐性的次级瓶颈。

**验证**：

```bash
juicefs mount -d tikv://... /mnt/juicefs \
    -o splice_read,splice_write,splice_move \
    --cache-size 0

# 然后跑 128G randread + juicefs stats，观察 CPU%
```

### 3.2 FUSE max_read / max_write

这两个参数控制单次 FUSE 操作的最大 I/O 大小。默认值取决于内核版本，可能是 128K
或更小。如果 `max_read < 256K`，则一次 256K 读请求会被 FUSE 拆成多次小操作，增加
内核↔用户态往返次数。

**验证**：

```bash
# 查看当前值
cat /sys/fs/fuse/connections/*/max_read 2>/dev/null

# 或在挂载时指定
juicefs mount -d tikv://... /mnt/juicefs \
    -o max_read=1048576,max_write=1048576
```

### 3.3 FUSE max_pages

Linux 5.x+ 支持 `max_pages` FUSE 选项，允许单次操作传输更多页面。默认可能是 32
（128KB），对于 256K 块来说刚好被拆分。

**验证**：

```bash
juicefs mount -d tikv://... /mnt/juicefs \
    -o max_pages=128
```

### 3.4 FUSE 预读控制

`-o no_readahead` 可以关闭 FUSE 层自身的预读（区别于 JuiceFS 的 `--prefetch`），
在纯随机读场景下避免无意义的预读开销。

```bash
juicefs mount -d tikv://... /mnt/juicefs \
    -o no_readahead --cache-size 0
```

---

## 四、v1.4 `--max-downloads` 的单客户端退化分析

### 4.1 现状

10_1 已测：v1.4 单客户端 randread 44.2 vs v1.3.1 45.7（−3%），多客户端 +53~61%。
v1.4 的 `--max-downloads` 引入调度开销（信号量 / goroutine 池管理），单客户端下
并发不足以摊薄这个开销，是净损。

### 4.2 可能的恢复手段

| 方案 | 思路 | 可行性 |
|------|------|--------|
| `--max-downloads 0` | 禁用/无限制，回到 v1.3.1 行为 | 需确认 v1.4 是否支持 0 值 |
| `--max-downloads 1` | 最小并发，减少锁竞争 | 可能退化到串行 |
| 降级到 v1.3.1 + 打 patch | 将 `--max-downloads` 以最小侵入方式 backport | 需修改 Go 源码 |
| **保持 v1.3.1、走多客户端** | 已证 v1.3.1 三客户端 55.6 ≈ 天花板 58 | 最务实 |

### 4.3 建议

如果业务允许多客户端架构，v1.3.1 + 2-3 客户端是当前最稳路径（55.6 ≈ 目标 94%）。
如果坚持单客户端，v1.3.1 是最优版本，但需接受 45.9 ≈ 78% 的达标率。

---

## 五、pprof 热力图分析——定位 2.5× 的精确来源

### 5.1 动机

所有排除法实验已证"不是什么"，但**没人看过 JuiceFS 在 randread 时 CPU 到底花在哪里**。
2.5× 放大的来源在 FUSE 路径，但 FUSE 路径包含：FUSE 内核↔用户态切换、slice 解析、
对象 GET 调度、TiKV 查询、librados 通信、数据拷贝。pprof 可以精确告诉哪个函数
占 CPU 最多。

### 5.2 方法

```bash
# 1. 挂载时启用 pprof
juicefs mount -d tikv://... /mnt/juicefs \
    --cpuprofile /tmp/juicefs-cpu.pprof \
    --memprofile /tmp/juicefs-mem.pprof \
    --cache-size 0

# 2. 跑 60s randread
fio --name=randread --directory=/mnt/juicefs/testdir \
    --bs=256k --rw=randread --iodepth=128 --numjobs=128 \
    --direct=1 --time_based --runtime=60s

# 3. 分析
go tool pprof -http=:8080 /tmp/juicefs-cpu.pprof
# 浏览器打开 http://localhost:8080/ui/flamegraph
```

### 5.3 预期发现

| 如果 pprof 显示 | 则 |
|----------------|-----|
| 大量 CPU 在 `syscall.Read` / FUSE dispatch | FUSE 内核态往返是瓶颈 → 优化 splice / max_read |
| 大量 CPU 在 `golang.org/x/sync/semaphore` | 并发调度锁竞争 → 调整 max-downloads / goroutine 池 |
| 大量 CPU 在 `ceph/rados` 连接管理 | librados 连接复用不足 → 调整连接池参数 |
| 大量 CPU 在 `memmove` / `runtime.memcpy` | 数据拷贝是瓶颈 → 优化 splice 零拷贝 |

---

## 六、跨节点的 rados bench 256K 对象测试

### 6.1 动机

09_1 和 10_2 中 `rados bench rand` 的测试对象大小是 **4M**（rados bench 默认），
而 JuiceFS 256K 卷的对象大小是 **256K**。4M 对象的 rand 测试掩盖了小对象的
协议开销放大（每个对象都有固定的 messenger header / auth / CRC），对小对象
场景不公平。

10_2 第五节已标注 "rados bench 120/154 是 4M 对象，口径错位——不作随机读后端基准"，
但**正确的 256K 对象基准尚未测出**。

### 6.2 方法

```bash
# rados bench 不支持指定对象大小，需要用 rados api 自写测试
# 或用 fio 直接压 Ceph RBD（但 RBD 不完全等价于 librados 对象访问）

# 替代方案：用 python + rados 绑定
python3 -c "
import rados, time, random
cluster = rados.Rados(conffile='/etc/ceph/ceph.conf', name='client.juicefs')
cluster.connect()
ioctx = cluster.open_ioctx('juicefs-data')

# 写入 10000 个 256K 对象
objs = []
for i in range(10000):
    name = f'bench-256k-{i:05d}'
    ioctx.write(name, b'\\x00' * 256 * 1024)
    objs.append(name)

# 随机读 60s
start = time.time()
bytes_read = 0
count = 0
while time.time() - start < 60:
    obj = random.choice(objs)
    ioctx.read(obj, length=256*1024)
    bytes_read += 256 * 1024
    count += 1

elapsed = time.time() - start
print(f'Randread 256K: {bytes_read/elapsed/1024/1024:.1f} MB/s, {count/elapsed:.0f} IOPS')
"
```

### 6.3 预期

256K 对象的 rados rand 吞吐大概率低于 4M 对象的 118 MB/s（小对象的协议/寻址
开销占比更高），这会给出更精确的后端裸上限，从而修正瓶颈链中的天花板值。

---

## 七、调优路线图（按优先级）

| 优先级 | 方向 | 预期收益 | 成本 | 依赖 |
|--------|------|---------|------|------|
| **P0** | tcpdump 精确分解 2.5× 放大来源 | 可能发现真实放大 < 2.5×，意味着单客户端还有空间 | 极低（1 小时） | 无 |
| **P1** | 256K 对象 rados rand bench | 修正后端裸上限（当前 118 是 4M 对象的，口径错位） | 低（2 小时） | python rados 绑定 |
| **P2** | FUSE splice / max_read / no_readahead 验证 | 可能减少 CPU 开销和 FUSE 往返 | 低（2 小时） | 无 |
| **P3** | JuiceFS slice 碎片化检查 | 可能发现隐性对象 GET 放大 | 低（1 小时） | 无 |
| **P4** | pprof 热力图分析 | 精确定位 FUSE 读路径的 CPU 热点 | 中（半天） | Go pprof 工具链 |
| **P5** | 与业务方确认验收口径 | 可能直接达标（多客户端 / warmup） | 沟通成本 | 无 |
| **P6** | 升万兆网卡（客户端侧） | 直接破物理天花板 | 中（硬件） | 采购 |
| **P7** | 深入 JuiceFS 源码修改读路径 | 根本性降低残余放大 | 高（数周） | Go 开发能力 |

### P0 详解：tcpdump 分解 2.5× 的判定矩阵

> ⚠️ **2026-06-23 修正**：原稿预期"tcpdump 可能发现真实放大 < 2.5×（因后台噪声稀释）"
> 是错误的——客户端 NIC RX 不含 Ceph 节点间通信，2.5× 是纯 JuiceFS 应用层放大。
> tcpdump 的真正价值是**分解 2.5× 的构成**（几个 GET per read / 每个 GET 多大字节），
> 而不是"发现放大低于 2.5×"。

| tcpdump 结果 | 含义 | 单客户端理论极限 | 对症方向 |
|-------------|------|----------------|---------|
| 每 fio read 触发 ~2-3 个 GET，每个 ~256K | slice 碎片化主导（1 block = 多 slice） | 仍 49.6 | `juicefs gc --compact` 合并 slice |
| 每 fio read 触发 ~1 个 GET，但返回 ~512-640K | prefetch/readahead 拉了相邻 block | 仍 49.6 | `--prefetch 0` + `-o no_readahead`（08_2 B 已测 prefetch 无效，但 FUSE 层 no_readahead 未测） |
| 每 fio read 触发 ~2-3 个 GET，总返回 ~640K | slice 碎片 + prefetch 叠加 | 仍 49.6 | 先 compact slice，再关 prefetch |
| 每 fio read 触发 ~1 个 GET，返回 ~256K | 理想情况（放大仅协议帧 ~1.05×） | 124/1.05 = 117.1 | 说明 JuiceFS 读路径高效，瓶颈在别处 |

**关键认知**：无论 tcpdump 分解出什么，2.5× 放大在客户端侧的总量不变（≈NIC RX /
fio 有效读）。tcpdump 不能降低放大倍数，但能**定位放大来源**——是 slice 碎片化还是
prefetch，从而对症下药（compact vs 关 prefetch vs 两者叠加）。

**P0 仍是最高性价比实验**，但预期从"可能发现 59 可达"修正为"定位 2.5× 的对症方向"。
单客户端 59 MB/s 在 1Gbps + 2.5× 下的物理上限 49.6 不变——除非对症方向能把放大
压到 ~2.1× 以下（124/2.1=59.0），59 才在临界线上有望达标。

---

## 八、对 10 系列已有结论的确认与修正

### 8.1 确认（无异议）

- 瓶颈主因 = FUSE 读放大（4M→256K block-size 已消除 16×，残余 2.5×）
- 瓶颈次因 = 单客户端千兆网卡入向饱和（RX 91% 线速）
- RGW 非随机读根因（去 RGW 仅 +22~34%）
- 256K block-size 无副作用（USED 相同、RSS 更低、元数据无差异）
- v1.3.1 单客户端最优，v1.4 多客户端更优
- 后端有余量（rados bench 118，2 并发 145）

### 8.2 修正 / 补充

| 原结论 | 修正 |
|-------|------|
| "单客户端 45.9 ≈ 目标 78%，差 22%" | 补充：在 2.5× 放大 + 1Gbps 下，**单客户端物理上限 49.6**，实际已达上限 92.5%，剩余空间远比 22% 小 |
| "残余 2.5× 放大在 FUSE 路径，不可通过换池/调参消除" | 修正：**2.5× 是纯 JuiceFS 应用层放大**（客户端 NIC 不含 Ceph 后台噪声），具体构成未分解——可能是 slice 碎片化（1 block = 多 GET）+ prefetch（拉相邻 block）叠加。FUSE splice / max_read / slice 碎片化也未排除 |
| "rados bench rand=118 是后端裸能力" | 修正：118 是 **4M 对象**的裸能力，256K 对象的后端裸能力**尚未标定**（10_2 已标注口径错位），大概率低于 118 |
| "调并发/缓冲/预读参数无一提升" | 补充：**FUSE 层参数**（splice / max_read / max_pages / no_readahead）未在 08_2 B 实验中测试，该实验只测了 JuiceFS 应用层参数 |
| "v1.4 单客户端 -3% 是 tradeoff" | 补充：可尝试 `--max-downloads 0` 或回到 v1.3.1，单客户端场景下 v1.3.1 就是最优 |

---

## 九、对 randrw 验收口径的补充观点

### 9.1 当前问题

randrw 验收口径（`--create_on_open` 边写边读）下读带宽极低（4M 卷 ~2.3、256K 卷
~4.2 MB/s），10 系列文档已判定为"口径病态"。但这个口径仍在规格书中，无法直接忽略。

### 9.2 randrw 读低的根因分析

randrw 读低不是因为读本身慢，而是因为**写抢占读的资源**：

1. **写放大挤压读带宽**：randrw 中写占用的后端/网络带宽是读的 8–10×（写 ~35 MB/s
   有效但占 ~87.5 MB/s 后端带宽，读 ~4 MB/s 有效但仅占 ~10 MB/s）
2. **FUSE 串行化**：JuiceFS 单 FUSE 进程的读写请求走同一个队列，写请求的阻塞
   （等对象 PUT 完成后才能处理下一个请求）会拖慢读的调度
3. **create_on_open 的额外开销**：每个新文件先创建空对象、再写、再读，三次对象操作
   串行化

### 9.3 可能的改善

```bash
# 分离读写队列（如果 JuiceFS 支持）
juicefs mount ... --max-uploads 40 --max-downloads 200

# 或用 fio 的 rw_sequencer=sequential 减少读写交替
fio ... --rw_sequencer=sequential
```

但根本问题是 randrw 口径本身在 JuiceFS 架构下对读不利——这不是调优能解决的，
需要与业务方沟通是否接受纯 randread 作为验收指标。

---

## 十、一句话总结

单客户端随机读 59 MB/s 在 1Gbps + 2.5× 放大下物理不可达（上限 49.6）。
客户端侧的 2.5× 是纯 JuiceFS 应用层放大（不含 Ceph 后台噪声），最高优先级
是用 tcpdump 分解其构成——是一次读触发了几个对象 GET（slice 碎片化）还是
每个 GET 拉了多余字节（prefetch），从而对症下药（compact slice / 关 prefetch）。
只有把放大压到 ~2.1× 以下，单客户端 59 才在 1Gbps 下有达标希望；
否则应转多客户端架构或升万兆网卡。
