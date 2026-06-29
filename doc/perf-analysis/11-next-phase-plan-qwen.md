# 11 下阶段调优计划（qwen）

> **来源**: qwen  
> **时间**: 2026-06-22  
> **定位**: 承接 08~10 系列结论，规划下一阶段工作  
> **操作节点**: tikv-node (192.168.11.12, turboai)

---

## 一、已固化结论（精简记录）

### 1.1 基线与最优配置

| 项 | 值 | 来源 |
|----|----|------|
| 卷 block-size | **256K**（零存储代价，`09_1` 六.二） | `08_2` 五之三/四 |
| 后端 | **librados 直连**（去 RGW） | `08_1` |
| 版本 | v1.3.1（单客户端）/ v1.4（多客户端） | `10_1` |
| 元数据 | TiKV 单节点（单副本） | 配置 |
| 数据池 | EC 4+2, failure-domain=osd | 配置 |

### 1.2 性能现状（v1.3.1, 256K, RADOS, 128G 全口径）

| 用例 | 结果 | 目标 59 | 状态 |
|------|------|---------|------|
| 顺序读 | 107 MB/s | 59 | ✅ 达标 |
| 顺序写 | 117 MB/s | 59 | ✅ 达标 |
| 纯随机写 | 63~124 MB/s | 59 | ✅ 达标 |
| **纯随机读** | **~46 MB/s** | 59 | ❌ 78% |

### 1.3 已排除的非瓶颈（不再尝试）

| 已排除项 | 证据 |
|---------|------|
| 网络/介质 | 网卡 64-84%，盘 SSD (4K IOPS 92.5k) |
| RGW HTTP 层 | 去 RGW 随机读仅 +34% |
| JuiceFS 客户端参数（buffer-size/prefetch/readahead） | `08_2` B 实验：全部无效 |
| 元数据（TiKV） | 延迟 ~1ms |
| BlueStore 参数 | `09_1` 三：全部无效 |
| EC 取片 | `09_1` 四：EC vs 副本 randread 相同 |
| RAID 改 JBOD | 优先级极低，预期收益远低于其他方向 |

### 1.4 瓶颈定量定位

```
残余放大 ~2.5× → NIC RX = 有效读 × 2.5
千兆线速 ~124 MB/s → 单客户端理论上限 = 124 / 2.5 ≈ 49.6 MB/s
当前 46 ≈ 理论上限的 93%
```

**2.5× 的构成尚未精确分解。** 已知排除 EC 取片和 Ceph 后台噪声（客户端 NIC 不含 OSD 间流量），其余嫌疑：JuiceFS slice 碎片化、prefetch/readahead 拉取相邻块、FUSE 内核限制流、librados 协议开销等。

---

## 二、当前困境：预读的双刃剑效应

### 2.1 已确认的事实

预读（JuiceFS `--prefetch` / FUSE 层 readahead）对随机读带宽有显著影响，但关闭预读对其他指标（如顺序读）产生负面效果。

### 2.2 两条路线的抉择

| 路线 | 策略 | 优点 | 风险 |
|------|------|------|------|
| **A: 关闭预读 + 修复被拉低的指标** | 先关预读提升随机读，再补回其他损失 | 随机读可能大幅改善 | 被拉低的指标可能难以修复 |
| **B: 保留预读 + 用其他手段攻随机读** | 不动预读，用 tcpdump/pprof/FUSE 参数等其他手段降低 2.5× | 不影响已有指标 | 其他手段的改善幅度不确定 |

### 2.3 我的判断：**走路线 A + B 组合**

理由：

1. **顺序读已有充裕空间**：当前 107 MB/s 远超目标 59，即使关预读后顺序读降 20-30%，仍远超目标。**不必为已经达标的指标过度保护**。
2. **瓶颈在随机读**：所有不达标的问题集中在随机读（46 vs 59），应优先攻这个点。
3. **先确认预读对随机读的量化收益**：如果关预读后随机读能涨 10+ MB/s，即使顺序读降到 80 MB/s 也完全值得。
4. **但预读不是唯一杠杆**：即使关了预读，如果 2.5× 中只有 0.3-0.5× 来自预读，那还需其他手段消除剩余部分。

**建议步骤**：先在 256K 卷上量化预读对每项指标的精确影响，再决定组合策略。

---

## 三、下阶段调优路线图

### 3.1 优先级总览

| 阶段 | 方向 | 核心问题 | 依赖 |
|------|------|---------|------|
| **P0** | **预读量化测试** | 在 256K 卷上精确测预读开/关对各项指标的影响 | 无 |
| **P1** | **tcpdump 分解 2.5×** | 一次 256K 读触发几个对象 GET、每个 GET 多大 | 无 |
| **P2** | **FUSE 参数调优** | max_background/congestion_threshold/splice/max_read | P0 结果 |
| **P3** | **256K 对象 rados bench** | 修正后端裸上限（当前 118 是 4M 口径） | python-rados |
| **P4** | **pprof CPU 热力图** | JuiceFS randread 时 CPU 花在哪里 | Go 工具链 |
| **P5** | **slice 碎片检查与 compact** | `juicefs fsck` + `gc --compact` 后 randread 是否改善 | 无 |

### 3.2 P0：预读量化测试（首先执行）

在 256K 卷上，其他参数不变，只切换预读状态，**对所有验收指标逐项复测**：

```bash
# 基线：预读开启（默认）
STORAGE=ceph SKIP_SEQ=1 REPEAT=3 bash tests/bench-juicefs.sh prefetch-default

# 实验：关闭预读（--prefetch 0，JuiceFS 应用层）
STORAGE=ceph SKIP_SEQ=1 REPEAT=3 SKIP_LAYOUT=1 \
    bash tests/bench-juicefs.sh noprefetch --prefetch 0

# 实验：预读 + FUSE no_readahead（两层都关）
STORAGE=ceph SKIP_SEQ=1 REPEAT=3 SKIP_LAYOUT=1 \
    bash tests/bench-juicefs.sh no-prefetch-no-readahead --prefetch 0 -o no_readahead
```

**需记录的指标矩阵**：

| 指标 | prefetch=default | --prefetch 0 | --prefetch 0 + no_readahead |
|------|-----------------|-------------|---------------------------|
| 顺序读 | | | |
| 顺序写 | | | |
| 纯随机读 | | | |
| 纯随机写 | | | |
| randrw 读 | | | |
| randrw 写 | | | |
| NIC RX（sar） | | | |

**判读**：
- 如果 `--prefetch 0` 使随机读提升 **≥5 MB/s** 且顺序读写仍 > 59 → 确认预读是净损，生产关闭
- 如果随机读提升很小（<2 MB/s）但顺序显著下降 → 预读不是主因，走 P1 分解其他来源
- 如果随机读提升很大但顺序也大幅下降（<59） → 需要评估场景权重

### 3.3 P1：tcpdump 精确分解 2.5×（并行执行）

**目标**：回答"一次 fio 256K 随机读触发了几个对象 GET"和"每个 GET 返回多少字节"。

```bash
# 需要 tshark 或 wireshark
sudo apt install -y tshark

# 启动 randread
fio --directory=/mnt/juicefs/test_dir \
    --name=randread --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
    --time_based --runtime=30s --group_reporting &

# 同时抓包（Ceph OSD 端口 6800-6810）
sudo tshark -i eno1 -f "tcp portrange 6800-6810" \
    -a duration:30 -w /tmp/randread-30s.pcap

wait

# 分析：TCP payload 总量 vs fio 报告的有效读
sudo tshark -r /tmp/randread-30s.pcap -T fields -e tcp.len | \
    awk -F: '{s+=$1} END {printf "TCP payload: %.1f MB in 30s = %.1f MB/s\n", s/1024/1024, s/1024/1024/30}'
```

**如果 tcpdump 总 payload = ~115 MB/s，fio 有效读 = ~46 MB/s** → 2.5× 确认在应用层。
进一步分析**单个 GET 的大小分布**，区分是 slice 碎片化（多个小 GET）还是 prefetch（偶尔大 GET）。

### 3.4 P2：FUSE 层参数调优

**P2.1：FUSE congestion 限流**（零成本验证）

```bash
# 查看当前值
cat /sys/fs/fuse/connections/*/max_background        # 当前 50
cat /sys/fs/fuse/connections/*/congestion_threshold  # 当前 37

# 调高
sudo sh -c 'echo 1024 > /sys/fs/fuse/connections/*/max_background'
sudo sh -c 'echo 768 > /sys/fs/fuse/connections/*/congestion_threshold'

# 跑 randread，同时监控 waiting
fio ... randread ... &
sleep 5; for i in $(seq 1 10); do
    echo "[$i] waiting=$(cat /sys/fs/fuse/connections/*/waiting)"
    sleep 3
done
wait
```

判读：如果 waiting 之前一直 > 0，调高后降到 ~0 且 randread 涨 → 是瓶颈。如果 waiting 在调高前后都 ≈ 0 → FUSE 限流不是瓶颈。

**P2.2：FUSE splice 零拷贝**

```bash
juicefs mount -d tikv://... /mnt/juicefs \
    -o splice_read,splice_write --cache-size 0 --prefetch 0
# 跑 randread，对比 CPU 用量
```

**P2.3：FUSE max_read / no_readahead**

```bash
juicefs mount -d tikv://... /mnt/juicefs \
    -o max_read=1048576,no_readahead --cache-size 0 --prefetch 0
```

### 3.5 P3：256K 对象 rados bench（修正后端基准）

当前 118 MB/s 是 **4M 对象**的 rados bench rand 结果，而 JuiceFS 256K 卷的对象大小是 **256K**。
小对象的协议开销占比更高，256K 对象的后端裸上限大概率低于 118。

```bash
# 用 rados bench 的 -b 参数（v17+支持指定对象大小）
sudo cephadm shell -- rados bench -p juicefs-data 60 rand -b 262144

# 如不支持 -b，用 python rados 绑定（见 GLM51 文档六.2）
```

**影响**：如果后端裸上限从 118 降到 ~80 MB/s，则：
- 残余放大实际 = 80 / 46 ≈ 1.7×（不是 2.5×）
- 瓶颈更接近后端，而非客户端
- 优化方向从"降客户端放大"转向"提升后端 256K 对象能力"

### 3.6 P4：pprof CPU 热力图

```bash
juicefs mount -d tikv://... /mnt/juicefs \
    --cpuprofile /tmp/jfs-cpu.pprof --cache-size 0 --prefetch 0

fio ... randread ... runtime=60s
wait

go tool pprof -http=:8080 /tmp/jfs-cpu.pprof
```

**看什么**：
- `syscall.Read` 占比高 → FUSE 内核往返是瓶颈 → 优化 splice
- `semaphore.Acquire` 占比高 → goroutine 锁竞争 → 调整 max-downloads
- `rados_read` / `ceph` 函数高 → librados 开销 → 连接池优化
- `memmove` / `runtime.memcpy` 高 → 数据拷贝 → splice 零拷贝

### 3.7 P5：slice 碎片检查与 compact

```bash
# 在已 layout 的测试卷上检查
juicefs fsck tikv://192.168.11.12:2379/juicefs-prod --compact

# compact 前后对比 randread
fio ... randread ...
```

如果 tcpdump（P1）显示"一次 256K 读触发多个对象 GET"，compact 可能减少 GET 次数。

---

## 四、明确不再继续的测试

| 测试 | 理由 |
|------|------|
| BlueStore 调参 | `09_1` 已测全部无效 |
| EC 4+2 → 副本 size=3 | `09_1` 已测：randread 不变（46 vs 46），写放大 3× |
| 多客户端聚合（v1.3.1） | `10_2` 已测：4cl=66.9，边际递减明显 |
| RAID 改 JBOD/HBA | 后端 rados bench 已证明不是瓶颈，改 RAID 模式风险高 |
| 万兆网卡 | 验收标准是网卡 50%，升网卡同时升目标，不解决比例问题 |
| `--buffer-size` / `--max-readahead` 反复调参 | `08_2` B 实验已证全部无效 |
| 元数据缓存（attr/entry/open-cache） | TiKV 延迟仅 1ms，非瓶颈 |

---

## 五、执行顺序建议

```
P0 预读量化（30min）
  ├─ 如果随机读提升小 → P1 tcpdump + P3 256K rados（并行）
  │     └─ 根据分解结果 → P2 FUSE 参数 / P4 pprof / P5 compact
  └─ 如果随机读提升大 → 确认关闭预读为生产配置
        └─ 复测顺序读写确认是否仍达标
              └─ 如有损失 → P1 tcpdump 找其他放大来源补偿
```

**第一步永远是 P0**：量化预读的真实影响是后续所有决策的基础。

---

## 六、验收标准备忘

```
验收指标：各项带宽 ≥ 千兆网卡的 50%
千兆线速：~124 MB/s
目标阈值：59 MB/s

fio 基准参数（所有随机用例通用）：
  --bs=256k --ioengine=libaio --iodepth=128 --numjobs=128
  --direct=1 --time_based --runtime=60s

卷配置：block-size 256K, 后端 librados 直连, cache-size 0（冷态）
```

**关键约束**：目标随网卡线性增长。万兆网卡下目标 = 620 MB/s，但此时后端裸能力需 620 × 2.5 = 1550 MB/s，远超当前后端。因此**升网卡不解决达标率问题，降残余放大才是通用解**。
