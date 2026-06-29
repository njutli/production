# GLM5.2 调优方向补充（2026-06-22）

> 基于对 `doc/perf-analysis/` 01–10 全系列文档的完整阅读，以及与
> 同目录 `11-glm51-tuning-supplement.md`（GLM5.1）、`residual-amplification-tuning-qwen.md`
> 的交叉对照，本文补充 GLM5.2 视角的调优方向与手段。文档命名 `11b-glm52-tuning-supplement.md`
> 体现模型标识。
>
> **前置结论认同**：10 系列文档已锁定三层瓶颈链（FUSE 读放大 → 单客户端千兆 RX 饱和 →
> 后端 EC 池 145/2.5≈58 天花板），并把所有"框架内可调参"全部排除。GLM5.1 已点出
> "2.5× 残余放大未分解"和"单客户端 59 物理不可达"两个关键判断，Qwen 已点出
> "FUSE congestion_threshold"和"达标率只取决于 RAF"两个洞察。本文**不重复已覆盖方向**，
> 聚焦补充 GLM5.1/Qwen 尚未触及的六个新角度。

---

## 一、与已有两份补充的差异定位

### 1.1 GLM5.1（`11-glm51`）已覆盖

- 单客户端 59 在 2.5× 放大下物理不可达（124/2.5=49.6）
- `sar -n DEV` 含后台噪声，需 tcpdump 拆解
- FUSE splice / max_read / max_pages / no_readahead 验证
- JuiceFS slice 碎片化（fsck / gc --compact）
- 256K 对象 rados bench（修正后端裸上限口径）
- pprof CPU 热力图

### 1.2 Qwen（`residual-amplification-tuning-qwen`）已覆盖

- 达标率 = 1/RAF，与网卡绝对带宽无关
- FUSE `max_background` / `congestion_threshold` 节流疑点
- 元数据强缓存复测（attr-cache/entry-cache/open-cache）
- 残余放大逐层剥离量化法
- JuiceFS FUSE dispatch 线程模型调研

### 1.3 本文新增（不重复）

| 方向 | 核心 | 与已覆盖的差异 |
|------|------|--------------|
| **二、EC 4+2 → EC 2+1 池对照** | 同 1.5× 存储开销，但读分片从 4 降到 2 | `09_1` 只测了 EC vs 副本(size=3)，**EC 2+1 是中间档，未测** |
| **三、`allow_ec_overwrites=true` 关闭对照** | 检验 parity 校验读是否在拉多余的 2 个 parity 分片 | `09_1` 4.1 没列这个变量，但它是 EC 池的关键 flag |
| **四、OSD 侧 perf dump 分解 `op_latency`** | 把"后端 145"再拆成排队延迟 vs 处理延迟 | `08_2` A 看的是客户端 stats，**OSD 侧的 perf dump 没做** |
| **五、PG primary 分布与 `primary_affinity` 调整** | 检查 PG primary 是否集中导致热点 OSD | 全部 22 篇文档没提过 PG 分布均衡 |
| **六、MTU 9000 jumbo frame 全链路验证** | 4 分片 × 64K 在 MTU 1500 下 ~14% 头开销，jumbo 降到 ~0.5% | 全部 22 篇文档没测过 jumbo frame |
| **七、多客户端下 RAF 是否被摊薄的验证** | 10_2 v1.4 4-cl 92.1 超过理论天花板 58，暗示多客户端 RAF < 2.5× | `10_2` 数据与单客户端瓶颈链不自洽，**这个矛盾没被正面解释** |

---

## 二、EC 4+2 → EC 2+1 池对照实验

### 2.1 动机

`09_1` §4 的 EC vs 副本(size=3) 对照已证"EC 取片不是残余放大主因"——但**这是用 size=3 副本做的对照**，副本读只需 1 个 OSD round-trip，而 EC 4+2 读需要 4 个数据分片 round-trip。两者结构差异太大，"EC 取片非主因"这个结论可能下得太早。

更精确的对照应是 **EC 2+1**：

| 池类型 | 数据分片 | parity | 存储开销 | 单次读 OSD round-trip | round-trip 比 EC 4+2 |
|--------|---------|--------|---------|---------------------|---------------------|
| EC 4+2（当前） | 4 | 2 | 1.50× | 4 | 1.00× |
| **EC 2+1**（建议测） | 2 | 1 | 1.50× | 2 | **0.50×** |
| 副本 size=3（已测） | 1 | 2 | 3.00× | 1 | 0.25× |

EC 2+1 与 EC 4+2 **存储开销完全相同（1.5×）**，唯一差异是读时只需 2 个分片而非 4 个。
如果 EC 2+1 下 RAF 显著降低（如 2.5→1.7），则说明"4 分片"本身就是残余放大的重要来源；
如果 RAF 不变，则 `09_1` §4 的结论才真正成立。

### 2.2 实验步骤

```bash
# 1. 创建 EC 2+1 对照池
ceph osd pool create juicefs-ec21 32 erasure
ceph osd pool set juicefs-ec21 allow_ec_overwrites true
ceph osd erasure-code-profile set juicefs-ec21 k=2 m=1 crush-failure-domain=osd

# 2. format 新 JuiceFS 卷，block-size 256K，使用 EC 2+1 池
juicefs format --storage ceph --bucket ceph://juicefs-ec21 \
    --access-key ceph --secret-key client.juicefs \
    --block-size 256K --trash-days 0 \
    tikv://192.168.11.12:2379/juicefs-ec21 juicefs-ec21

# 3. 同口径 128G 布局 + randread（与 09_1 §4.2 完全一致）
LAYOUT_NUMJOBS=128 STORAGE=ceph POOL=juicefs-ec21 \
    bash tests/bench-juicefs.sh

# 4. 测试期间监控 NIC RX，对照 EC 4+2 的 117 MB/s
```

### 2.3 预期与判定

| EC 2+1 实测 randread | RAF | 判定 |
|---------------------|-----|------|
| ≈ 46 MB/s（同 EC 4+2） | ≈ 2.5× | `09_1` §4 结论坐实：EC 分片数无关 |
| 55–65 MB/s | ≈ 1.8–2.1× | **EC 4 分片贡献了 0.4–0.7× RAF**，EC 2+1 单客户端可冲 59 |
| 70+ MB/s | < 1.7× | 分片数是主因，建议生产改 EC 2+1（仅牺牲容错能力 1→1，仍可容忍 1 OSD 故障） |

### 2.4 副作用评估

- **容错降级**：EC 4+2 可容忍任意 2 OSD 故障；EC 2+1 仅容忍 1 OSD 故障。3 节点 6 OSD 规模下，2 OSD 同时故障概率较低，可接受。
- **存储开销**：完全相同（1.5×），无副作用。
- **写性能**：EC 2+1 写只需 3 OSD，单 OSD 负载更高，写带宽可能下降。需在测试中观察。

---

## 三、`allow_ec_overwrites=true` 关闭对照实验

### 3.1 动机

当前 EC 池配置 `allow_ec_overwrites=true`（见 `09_1` §一）。这个 flag 允许 EC 池支持部分覆盖写（RMW）。JuiceFS 写新 chunk 时是整对象写，理论上不触发 RMW（`blktrace` 实测盘上读≈0 已证实）。

**但读路径上可能有隐性开销**：`allow_ec_overwrites=true` 模式下，Ceph 客户端在读对象时**可能拉取全部 6 个分片（含 2 个 parity）做完整性校验**，以检测 RMW 留下的不一致。这会从 4 分片读变成 6 分片读，**额外增加 1.5× 流量**——这正好对应"未解释的 1.4× 幽灵流量"。

GLM5.1 在 §2.2 列出了这个嫌疑但没深入；本文把它作为**首要验证方向**。

### 3.2 实验步骤

```bash
# 1. 创建对照池（关闭 allow_ec_overwrites）
ceph osd pool create juicefs-ec-readonly 32 erasure
ceph osd erasure-code-profile set juicefs-ec-readonly k=4 m=2 crush-failure-domain=osd
# 注意：不 set allow_ec_overwrites（默认 false，append-only）

# 2. format 新卷
juicefs format --storage ceph --bucket ceph://juicefs-ec-readonly \
    --access-key ceph --secret-key client.juicefs \
    --block-size 256K --trash-days 0 \
    tikv://192.168.11.12:2379/juicefs-ec-readonly juicefs-ec-readonly

# 3. 关键差异：必须用 layout-only 模式一次写完，然后只读不写
#    （因为 allow_ec_overwrites=false 下 randwrite 会失败）
DO_LAYOUT_ONLY=1 STORAGE=ceph POOL=juicefs-ec-readonly \
    bash tests/bench-juicefs.sh

# 4. 然后 SKIP_LAYOUT=1 只跑 randread
SKIP_LAYOUT=1 SKIP_SEQ=1 STORAGE=ceph POOL=juicefs-ec-readonly \
    bash tests/bench-juicefs.sh

# 5. 测试期间用 tcpdump 验证拉取的分片数
sudo tcpdump -i eno1 -w /tmp/ec-readonly-randread.pcap &
# 跑 60s randread
sudo kill %1
# 分析：看是否有 OSD 收到了 parity shard 请求
```

### 3.3 判定

| EC 2+1 实测 randread | tcpdump 显示 | 判定 |
|---------------------|------------|------|
| ≈ 46 MB/s | 4 分片 | parity 校验非主因，关闭 overwrites 无效 |
| 60–80 MB/s | 4 分片 | 与 parity 无关，但 overwrites=false 有其他正效应 |
| 60–80 MB/s | 6→4 分片 | **parity 校验读是主因**，关闭 overwrites 可降 RAF 到 ~1.7× |

### 3.4 副作用

- **randwrite 失效**：`allow_ec_overwrites=false` 下 randwrite 会报错。但**纯 randread 仍可测**（数据是 layout 阶段一次写入的）。
- **生产可行性**：如果该实验有效，生产环境需权衡——JuiceFS 的写实际上是 append 新 chunk，理论上可用 append-only EC 池，但需验证 JuiceFS 是否真的不依赖对象覆盖写。

---

## 四、OSD 侧 perf dump 分解后端延迟

### 4.1 动机

`08_2` A 实验在客户端侧采集了 `juicefs stats`，看到 object get_c 50–124、object get 吞吐 ~100 MB/s。但**这只是客户端视角**——客户端看到 GET 在飞，但不知道 GET 在 OSD 侧是排队还是处理。

`09_1` 标定的后端裸能力 118 MB/s（单节点）/ 145 MB/s（双节点）是 rados bench 测的聚合数，**也没拆开"排队"与"处理"**。`10_2` v1.4 4-cl 92.1 超过单客户端瓶颈链天花板 58，这个不自洽暗示**多客户端下后端实际能力比 145 更高**——可能就是排队延迟被并发打平了。

### 4.2 实验步骤

```bash
# 1. randread 期间，逐 OSD 采集 perf dump
for osd in 0 1 2 3 4 5; do
    ssh turboai@192.168.11.11 "sudo cephadm shell -- ceph daemon osd.$osd perf dump" \
        > /tmp/osd-$osd-perf.json &
done
wait

# 2. 关键指标提取
for osd in 0 1 2 3 4 5; do
    echo "=== OSD $osd ==="
    jq '{
        op_latency: ."osd"."op_latency"."avgcount" + " / " + ."osd"."op_latency"."sum",
        op_in_queue: ."osd"."op_in_queue"."avgcount",
        op_process_latency: ."osd"."op_process_latency"."avgcount" + " / " + ."osd"."op_process_latency"."sum",
        op_prepare_latency: ."osd"."op_prepare_latency"."avgcount" + " / " + ."osd"."op_prepare_latency"."sum",
        op_r_latency: ."osd"."op_r_latency"."avgcount" + " / " + ."osd"."op_r_latency"."sum"
    }' /tmp/osd-$osd-perf.json
done

# 3. 单客户端 vs 多客户端对比
# 跑单客户端 randread → 采集
# 跑 4 客户端 randread → 采集
# 对比 op_in_queue 和 op_process_latency 的变化
```

### 4.3 判定矩阵

| 单客户端 op_in_queue | 多客户端 op_in_queue | op_process_latency | 判定 |
|---------------------|---------------------|-------------------|------|
| 高 | 更高 | 不变 | **OSD 排队瓶颈** → 加 `osd_op_threads` 或调 PG primary 分散 |
| 低 | 低 | 高 | **BlueStore 处理瓶颈** → 调 `bluestore_cache_size_ssd`（GLM5.1 未测的 BlueStore 参数） |
| 低 | 高 | 不变 | **客户端并发不足**（单客户端下没打满后端） |

### 4.4 与 `09_1` §三（BlueStore 调参）的差异

`09_1` §三测的是 `bluestore_max_blob_size_ssd` 和 `prefer_deferred_size_ssd`——**都是写路径参数**。本文建议测的是 `bluestore_cache_size_ssd`（**读路径 KV cache**，默认 1G），这是 `09_1` 没碰过的。

```bash
# 默认 1G → 调到 4G 看 op_process_latency 是否下降
ceph config set osd bluestore_cache_size_ssd 4G
# 重测 rados bench rand 和 JuiceFS randread
```

---

## 五、PG primary 分布与 `primary_affinity` 调整

### 5.1 动机

EC 池的每个 PG 有一个 primary OSD，**所有读请求都先到 PG primary，由它分发到其他 OSD 取分片再聚合**。如果 PG primary 集中在少数 OSD 上，那些 OSD 会成为热点，单 OSD 的 `op_in_queue` 飙升，拖慢整体。

全部 22 篇文档没检查过 PG 分布。在 3 节点 6 OSD 的小集群上，PG 分布不均的概率较高。

### 5.2 检查命令

```bash
# 1. PG primary 分布
sudo cephadm shell -- ceph pg dump | awk '
    /^pg_stat/ {next}
    {split($1, a, "."); primary=a[1]; up=$6}
    {primary_osd[primary]++}
    END {for (o in primary_osd) print "OSD", o, "primary count:", primary_osd[o]}
' | sort -k4 -n

# 2. 看 PG 在 OSD 上的分布
sudo cephadm shell -- ceph osd pool stats juicefs-data

# 3. 看是否有 OSD 的 op_in_queue 显著高于其他
for osd in 0 1 2 3 4 5; do
    ssh turboai@192.168.11.11 "sudo cephadm shell -- ceph daemon osd.$osd perf dump" | \
        jq '."osd"."op_in_queue"."avgcount"'
done
```

### 5.3 调优

如果发现 PG primary 集中：

```bash
# 方案 A：开启 balancer（upmap 模式，最稳）
sudo cephadm shell -- ceph balancer mode upmap
sudo cephadm shell -- ceph balancer on
# 等待自动均衡（可能需要数小时）

# 方案 B：手动调整 primary_affinity
# 把过载 OSD 的 primary_affinity 降到 0.5
sudo cephadm shell -- ceph osd primary-affinity <osd_id> 0.5
# 把欠载 OSD 的 primary_affinity 提到 1.0
sudo cephadm shell -- ceph osd primary-affinity <osd_id> 1.0
```

### 5.4 预期

如果 PG 分布极不均（如某 OSD primary 数是其他 3 倍），均衡后单 OSD 队列压力下降，**后端聚合能力可能从 145 跳到 160–180**，间接抬高单客户端瓶颈链天花板。

---

## 六、MTU 9000 jumbo frame 全链路验证

### 6.1 动机

EC 4+2 读 256K 对象 = 4 × 64K 分片。在 MTU 1500 下：

- 每分片 = 64K / 1460（TCP payload）≈ 44 个包
- 每包 TCP/IP 头 52 字节
- 4 分片 × 44 包 × 52 字节 = 9152 字节 / 256K 对象 ≈ **3.5% 头开销**

这个 3.5% 不大，但加上小包带来的中断频率、TCP ACK 频率、CPU 系统调用开销，**累积可能贡献 5–8% 的 RAF**。

GLM5.1 在 §2.2 列了 "TCP/IP 头开销 ~0.02×"——这是低估了。在 64K 分片粒度下，每分片要 44 个包，包级别的开销不能忽略。

### 6.2 实验步骤

```bash
# 1. 检查当前 MTU
ip link show eno1  # 看 mtu 字段

# 2. 全链路调到 9000（客户端 + 3 Ceph 节点都要改）
#    PERC H730 RAID 卡和网卡驱动都需支持
for host in tikv-node ceph-node1 ceph-node2 ceph-node3; do
    ssh turboai@$host "sudo ip link set eno1 mtu 9000"
done

# 3. 验证 jumbo frame 生效（ping 大包不丢）
ping -M do -s 8972 192.168.11.11
ping -M do -s 8972 192.168.11.13
ping -M do -s 8972 192.168.11.14

# 4. 重测 randread（256K block-size，与基线完全同口径）
LAYOUT_NUMJOBS=128 STORAGE=ceph bash tests/bench-juicefs.sh

# 5. 对比 NIC RX / 有效读 比，看 RAF 是否从 2.5 降到 2.3-2.4
```

### 6.3 预期

| MTU | 每包 payload | 64K 分片包数 | 头开销 | 预期 RAF |
|-----|------------|------------|--------|---------|
| 1500（当前） | 1460 | 44 | 3.5% | 2.5× |
| 9000（jumbo） | 8960 | 7 | 0.5% | **2.4×（省 0.1×）** |

降 0.1× 看似不大，但按 GLM5.1 §1.1 的硬约束：**单客户端达标需 RAF ≤ 2.10×**，从 2.5 降到 2.4 是接近达标的第一步。配合 EC 2+1（降到 1.7–2.0×）才可能达标。

### 6.4 风险

- **网卡驱动 / 交换机支持**：千兆网卡部分型号不支持 jumbo，需先确认。
- **跨网段不一致**：如果只有部分节点支持，会导致 PMTU 黑洞，性能反而下降。
- **生产网络影响**：MTU 9000 会影响所有走该网卡的流量，需评估是否可接受。

---

## 七、多客户端下 RAF 是否被摊薄的验证

### 7.1 动机

`10_2` §四实测 v1.4 4-cl randread 聚合 **92.1 MB/s**，超过单客户端瓶颈链算出的天花板：

```
单客户端瓶颈链：min(NIC 124, 后端 145 ÷ RAF 2.5) = 58 MB/s
4 客户端聚合：4 × min(每客户端 NIC, 后端 145 ÷ RAF 2.5) ≈ 58 MB/s（瓶颈在后端）
但实测 92.1 > 58 → 矛盾
```

这个矛盾有两种解释，**当前 10 系列文档没有正面区分**：

1. **后端实际能力 > 145**：双节点 rados bench 145 是 4M 对象测的（GLM5.1 §6 已指出），256K 对象下后端可能更高。如果后端实际 230 MB/s，则 230/2.5 = 92，自洽。
2. **多客户端下 RAF < 2.5×**：多客户端共享 TiKV 连接、共享 OSD 连接、TCP 慢启动摊薄，单字节摊到的协议开销降低。如果 4 客户端下 RAF 降到 1.6×，则 145/1.6 = 90.6，自洽。

### 7.2 实验步骤

```bash
# 1. 单客户端 randread，采集 NIC RX
sar -n DEV 1 > /tmp/sar-1cl.txt &
fio ... --runtime 60s  # 单客户端
kill %1

# 2. 4 客户端 randread，逐客户端采集 NIC RX
# 在每台客户端上
sar -n DEV 1 > /tmp/sar-4cl-<host>.txt &
# 在主控机上启动 4 客户端并行 randread
bash tests/bench-c-multihost-3client.sh  # 扩展到 4 客户端
# 测试结束后 kill 所有 sar

# 3. 计算两种 RAF
# 单客户端：RAF_1 = NIC_RX_1 / fio_bandwidth_1
# 多客户端：RAF_4 = sum(NIC_RX_4) / sum(fio_bandwidth_4)

# 4. 同时采集 OSD perf dump（见第四节），对比单/多客户端下的后端延迟
```

### 7.3 判定

| RAF_1 | RAF_4 | 判定 | 后续行动 |
|-------|-------|------|---------|
| 2.5× | 2.5× | RAF 不被摊薄，10_2 92.1 的解释是后端实际 > 145 | 重测 256K 对象的 rados bench（GLM5.1 §6） |
| 2.5× | 1.6× | **RAF 在多客户端下被摊薄** | 单客户端 59 不可达，但多客户端路线有更高天花板，建议改验收口径 |
| 2.5× | 1.8× | 部分摊薄 | 多客户端是部分解，但仍需降 RAF |

### 7.4 与 GLM5.1 §6 的关系

GLM5.1 §6 建议"用 256K 对象重测 rados bench"——这验证的是**解释 1**（后端实际能力）。
本文建议的是**同时验证解释 2**（RAF 摊薄）。两个实验互补，**必须同时做**才能区分是哪个因素让 10_2 的 92.1 超过天花板。

---

## 八、综合调优路线图（GLM5.2 视角）

按"诊断先行、参数其次、架构最后"原则排序：

| 优先级 | 方向 | 来源 | 预期收益 | 成本 | 与已有方向的关系 |
|--------|------|------|---------|------|---------------|
| **P0** | tcpdump 精确分解 2.5× 放大 | GLM5.1 §2.4 | 决定后续所有方向是否值得做 | 极低（1h） | 已有 |
| **P0** | OSD 侧 perf dump 分解后端延迟 | **本文 §四** | 拆开"排队 vs 处理"，定位后端天花板真实位置 | 低（2h） | 新增 |
| **P1** | EC 2+1 池对照 | **本文 §二** | 可能降 RAF 2.5→1.7，单客户端冲 59 | 中（半天，需新建池） | 新增（`09_1` 只测了 EC vs 副本） |
| **P1** | `allow_ec_overwrites=false` 对照 | **本文 §三** | 可能降 RAF 2.5→1.7（如果 parity 校验读是主因） | 中（半天） | 新增 |
| **P1** | 多客户端下 RAF 摊薄验证 | **本文 §七** | 区分 10_2 92.1 的成因，决定单/多客户端路线 | 低（2h） | 新增（10_2 没正面解释这个矛盾） |
| **P2** | FUSE congestion_threshold 调优 | Qwen 方向一 | 可能 +20-40 MB/s（如果 waiting > 0） | 零成本 | 已有 |
| **P2** | PG primary 分布检查 + balancer | **本文 §五** | 可能抬后端天花板 145→160+ | 低（1h 检查 + 数小时自动均衡） | 新增 |
| **P3** | MTU 9000 jumbo frame | **本文 §六** | 降 RAF 0.1×，小幅 | 中（需全链路支持） | 新增 |
| **P3** | 256K 对象 rados bench | GLM5.1 §6 | 修正后端裸上限口径 | 低 | 已有 |
| **P3** | FUSE splice / max_read / no_readahead | GLM5.1 §3 | 可能减少 CPU 开销 | 低 | 已有 |
| **P4** | JuiceFS slice 碎片化检查 | GLM5.1 §2.5 | 可能发现隐性对象 GET 放大 | 低 | 已有 |
| **P4** | pprof CPU 热力图 | GLM5.1 §5 | 精确定位 FUSE 读路径 CPU 热点 | 中 | 已有 |
| **P5** | JuiceFS 源码读路径修改 | — | 根本性降 RAF | 高（数周） | 终极方案 |

### 8.1 决策树

```
P0: tcpdump + OSD perf dump
    ├─ RAF < 2.1×（真实放大低于预期）→ 单客户端路线可行，调 FUSE 参数即可达标
    ├─ RAF ≈ 2.5× 且后端 op_in_queue 高 → P2 PG 均衡 + 加 osd_op_threads
    └─ RAF ≈ 2.5× 且后端 op_process_latency 高 → P1 EC 2+1 + allow_ec_overwrites=false
        ├─ RAF 降到 1.7× → 单客户端可达 73 MB/s，达标
        └─ RAF 不变 → 转多客户端路线（接受单客户端 78%）
```

---

## 九、对 10 系列已有结论的修正建议

### 9.1 确认（无异议）

- 主因 = FUSE 读放大（4M→256K 已消除 16×）
- 次因 A = 单客户端千兆 RX 饱和（91% 线速）
- 次因 B = 后端 EC 池聚合天花板（145 MB/s）
- 256K block-size 无副作用（`09_1` 六之二精测）
- v1.3.1 单客户端最优，v1.4 多客户端更优
- RGW、BlueStore 写参数、客户端参数（buffer/prefetch/readahead）全部非瓶颈

### 9.2 建议修正/补充

| 原结论 | 建议修正 | 理由 |
|-------|---------|------|
| `09_1` §4 "EC 取片不是残余放大主因" | **建议加限定**："EC 4 分片 vs 副本 1 分片"对照成立，但**未测 EC 2+1 这个中间档** | 副本结构差异太大，EC 2+1 才是真正对照 |
| `09_1` §7.5 残余放大 5 项分解 | **建议补一项**：`allow_ec_overwrites=true` 下的 parity 校验读 | 这是 EC 池的关键 flag，未被排除 |
| `10_2` §四 v1.4 4-cl 92.1 | **建议正面解释**：超过单客户端瓶颈链天花板 58，需区分"后端实际 > 145"还是"多客户端 RAF 摊薄" | 当前数据与瓶颈链不自洽 |
| `09_1` §3 BlueStore 调参"全部无效" | **建议补测 `bluestore_cache_size_ssd`** | `09_1` 测的都是写路径参数，读路径 KV cache 没测 |
| `results-table.md` "网络" 排除 | **建议补注**：MTU 1500 下的头开销未测，jumbo frame 未验证 | 22 篇文档都没碰过 MTU |

---

## 十、一句话总结

10 系列已锁定"FUSE 读放大 + 千兆 RX + 后端 145"三层瓶颈链，但 **2.5× 残余放大里
~1.4× 是"未解释的幽灵流量"**——三个最可能的来源（EC 4 分片 vs 2 分片、
`allow_ec_overwrites=true` 的 parity 校验读、MTU 1500 的小包头开销）都还没被测试。
其中 EC 2+1 和 overwrites=false 两个实验是同 1.5× 存储开销下的真正对照，**预计能把
RAF 从 2.5× 降到 1.7× 左右，单客户端 randread 从 45.9 冲到 70+ MB/s**——
这是当前未挖方向里性价比最高的两个。同时 10_2 的 92.1 与瓶颈链天花板 58 的矛盾
必须用"多客户端 RAF 摊薄验证"正面解释，否则多客户端路线的天花板判断不可信。
