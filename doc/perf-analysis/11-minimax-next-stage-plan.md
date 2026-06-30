# 11 下一阶段调优计划（minimax, 2026-06-24）

> 操作节点：tikv-node（192.168.11.12, turboai/TurboAi@303）
> 承接 10_1 / 10_2 结论，规划下一阶段工作
> 精简已有结论，聚焦下阶段计划

---

## 一、当前结论（精简版）

### 1.1 性能现状（单客户端 v1.3.1, 256K block-size, RADOS 直连）

| 指标 | 结果 | 目标 59 | 状态 |
|------|------|---------|------|
| 顺序读 | 107 MB/s | 59 | ✅ 达标 |
| 顺序写 | 117 MB/s | 59 | ✅ 达标 |
| 纯随机写 | 63-65 MB/s | 59 | ✅ 达标 |
| **纯随机读** | **45.9 MB/s** | 59 | ❌ 78% |

### 1.2 已排除的非瓶颈

| 排除项 | 证据 |
|--------|------|
| 网络 | 网卡 RX 仅 64-84%，未打满 |
| 介质 | SSD 4K IOPS 92.5k |
| RGW HTTP | 去 RGW 只 +34%，非根因 |
| 元数据 TiKV | 延迟 ~1ms |
| JuiceFS 客户端参数（buffer/prefetch） | 08_2 B 实验全部无效 |

### 1.3 瓶颈定位

```
千兆线速 124 MB/s → 单客户端理论上限 = 124 / 2.5 ≈ 49.6 MB/s
实测 45.9 = 理论上限的 92%
```

**核心瓶颈**：JuiceFS 应用层残余放大 ~2.5×，单客户端已接近物理上限。

---

## 二、关于预读问题的判断

### 2.1 已有证据

`08_2` B 实验证明 JuiceFS `--prefetch` 参数在 4M block-size 下对随机读**无影响**（3.0 vs 3.1 MB/s）。

但最新测试显示预读仍是重要因素，**可能来源**：
- FUSE 内核层 readahead（VFS 层）
- 256K block-size 下的新行为（与 4M 不同）
- randrw 混合读写下的交互效应

### 2.2 下阶段策略

**不是简单的"开"或"关"预读，而是先定位预读影响来自哪一层**：

| 层级 | 关闭方式 | 需验证 |
|------|----------|--------|
| JuiceFS 预读 | `--prefetch 0` | 已有数据，256K 下效果未知 |
| FUSE readahead | `-o no_readahead` | **需新测** |
| 两者叠加 | `--prefetch 0 -o no_readahead` | **需新测** |

---

## 三、对 10_A 第四节未完成测试的评估

> 10_A 应指 10_1 或 10_2 中的某节，根据内容推断为版本测试后的补充验证

### 3.1 已有的相关数据

| 测试 | 结果 | 是否需继续 |
|------|------|-----------|
| `--max-downloads` sweep (32G) | 100 以上已饱和 | ❌ 不必要，128G 不会不同 |
| v1.3.1 vs v1.4 单客户端 | 基本持平 (-3~8%) | ❌ 已闭环 |
| 多客户端聚合 | 2-cl=76.8 已达标 | ❌ 不作为单客户端依据 |

### 3.2 仍需补测的

| 测试 | 理由 | 优先级 |
|------|------|--------|
| **256K block-size 下 prefetch 开/关对比** | 08_2 数据是 4M，新 block-size 行为未知 | **P0** |
| **FUSE no_readahead 测试** | 验证 VFS 层预读影响 | **P0** |
| **tcpdump 分解 2.5×** | 精确回答一次 256K 读触发几个 GET | **P1** |

---

## 四、下阶段行动计划

### P0：预读分层定位（必须先做）

```bash
# 1. 基线：默认配置
STORAGE=ceph SKIP_SEQ=1 REPEAT=3 bash tests/bench-juicefs.sh baseline

# 2. 关 JuiceFS 预读
STORAGE=ceph SKIP_SEQ=1 REPEAT=3 SKIP_LAYOUT=1 \
    bash tests/bench-juicefs.sh prefetch-off --prefetch 0

# 3. 关 FUSE readahead（挂载参数）
STORAGE=ceph SKIP_SEQ=1 REPEAT=3 SKIP_LAYOUT=1 \
    bash tests/bench-juicefs.sh no-readahead -o no_readahead

# 4. 两者都关
STORAGE=ceph SKIP_SEQ=1 REPEAT=3 SKIP_LAYOUT=1 \
    bash tests/bench-juicefs.sh both-off --prefetch 0 -o no_readahead
```

**记录指标矩阵**：

| 配置 | randread | seq-read | seq-write | randwrite |
|------|----------|----------|-----------|-----------|
| 默认 | 45.9 | 107 | 117 | 63-65 |
| --prefetch 0 | ? | ? | ? | ? |
| -o no_readahead | ? | ? | ? | ? |
| 两者都关 | ? | ? | ? | ? |

**判读**：
- 若某层关闭后 randread 提升 ≥5 MB/s，且其他指标仍 > 59 → 采用该配置
- 若提升小或副作用大 → 进入 P1 继续定位

---

### P1：tcpdump 精确分解放大因子

```bash
# 安装 tshark
sudo apt install -y tshark

# 启动 randread
fio --directory=/mnt/juicefs/test_dir \
    --name=randread --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
    --time_based --runtime=30s --group_reporting &

# 抓包（Ceph OSD 端口）
sudo tshark -i eno1 -f "tcp portrange 6800-6810" \
    -a duration:30 -w /tmp/randread.pcap

wait

# 分析
sudo tshark -r /tmp/randread.pcap -T fields -e tcp.len | \
    awk '{s+=$1} END {print "Total:", s/1024/1024, "MB"}'
```

**回答问题**：
- 一次 256K 随机读触发 N 个对象 GET？
- 每个 GET 返回多少字节？
- N×字节 vs fio 有效读 = 放大倍数来源

---

### P2：FUSE 参数调优（如 P0/P1 需要）

```bash
# 查看 FUSE 当前状态
cat /sys/fs/fuse/connections/*/max_background    # 默认 50
cat /sys/fs/fuse/connections/*/congestion_threshold  # 默认 37

# 调高限流阈值
sudo sh -c 'echo 1024 > /sys/fs/fuse/connections/*/max_background'
sudo sh -c 'echo 768 > /sys/fs/fuse/connections/*/congestion_threshold'

# 监控 waiting
fio ... randread ... &
for i in $(seq 1 10); do
    cat /sys/fs/fuse/connections/*/waiting
    sleep 3
done
```

---

### P3：确认达标方案

| 方案 | 条件 | 结果 |
|------|------|------|
| **单客户端** | P0/P1 定位后 randread ≥ 59 | 达标 |
| **多客户端** | 单客户端无法达标 | 2-cl v1.4 = 76.8 已验证 |
| **接受现状** | 45.9/59 = 78% | 报备验收差异 |

---

## 五、决策树

```
P0: 预读分层测试
  │
  ├─ randread 提升 ≥5 MB/s → 采用该配置，复测全部指标
  │   └─ 如顺序读仍 > 59 → 生产采用，否则进入 P2 修复
  │
  ├─ randread 提升 < 2 MB/s → 进入 P1 tcpdump 分解
  │   └─ 分解后决定后续方向
  │
  └─ 所有层关闭无改善 → 确认单客户端上限 46 MB/s
      └─ 转向多客户端方案或接受现状
```

---

## 六、不再继续的方向

| 方向 | 理由 |
|------|------|
| BlueStore 调参 | 09_1 已测无效 |
| EC 副本转换 | 09_1 已证 randread 不变 |
| `--buffer-size` / `--max-readahead` sweep | 08_2 已证无效 |
| 元数据缓存 | TiKV 延迟仅 1ms，非瓶颈 |
| RGW 根因 | 08_1 已排除 |
| 版本切换 | 10_1 已证 v1.4 对单客户端无提升 |

---

## 七、一句话

**先做 P0 预读分层定位（区分 JuiceFS vs FUSE），再做 P1 tcpdump 精确分解放大因子。找到放大来源后，单客户端路线能否达标自然见分晓；否则转向多客户端方案（已验证 2-cl = 76.8 > 59）。**
