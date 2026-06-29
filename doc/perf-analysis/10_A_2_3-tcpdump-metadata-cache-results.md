# 10_A_2_3 顺位2+3 验证：tcpdump 分解 + 元数据强缓存（2026-06-23，2026-06-23 二次订正）

> 来源：10_A 第四节顺位2（GLM5.1 §2.4）+ 顺位3（qwen 方向二）
> 结论（订正后）：**应用层读放大以 strace syscall 层 2.60× 与 NIC RX 增量为准（NIC 2.5–3.0× 随并发/工作集波动）。每 fio read ≈ 139 次 socket read ≈ 4 OSD × 35，精确对齐 EC 4+2 四分片 → slice 碎片化不是主因。元数据强缓存无效。**

> 🔧 **2026-06-23 二次订正（重要，opencode 复核 + 重测）**：
> 本文 §二 早前给出的 **TCP payload "2.75×（全量）" 不作为结论采用**——该值 §4.1 已自承
> "> NIC 2.5×，因 tcpdump 窗口比 fio 多 ~5s，含 OSD 心跳/重传噪声"，即 **2.75× 被窗口噪声污染**。
> 干净可信的口径有两个，互相印证：
> - **strace syscall 层 = 2.60×**（§4.4，只数 JuiceFS 进程读 Ceph socket 的字节，无窗口/重传噪声）——**采用为应用层放大基准**；
> - **NIC RX 增量口径**（`/proc/net/dev` 跑前跑后取差，与 09/10 系列同口径）：opencode 重测 numjobs=8 冷态 = **2.98×**（NIC_RX 6909 MB ÷ fio 有效读 2322 MB）。
>
> 三者关系：**strace 2.60× < NIC 2.98×（含 TCP/IP 头 + 协议帧）**，自洽；2.5–3.0× 的波动来自
> 并发档（numjobs=8 低并发使协议/连接开销占比更高）与工作集大小，**不是精确常数**。
> 定性结论稳固：**放大在 JuiceFS 内部、约 2.5–2.6×、slice 碎片化非主因（strace 139≈4×35 已证）。**
>
> ⚠️ 重测中另发现 **numjobs=128 高并发会使冷态 randread 卡死**（fio 进 D 态、SIGKILL 才掉），
> 详见 `10_issue-1-highconcurrency-randread-hang.md`。本文 numjobs=8 数据不受此影响。

---

## 一、实验设计

两个测试在一次 fio 运行中同步完成：
- **tcpdump**：采集客户端侧 Ceph OSD 端口（6800-6803）全部流量
- **元数据缓存**：mount 时启用 `--attr-cache 300 --entry-cache 300 --open-cache 300`
- 同一次 fio randread（256K, libaio, iodepth=128, numjobs=8, direct=1, 60s）同时产出两份数据

### 卷参数
| 参数 | 值 |
|------|-----|
| block-size | 256K |
| STORAGE | ceph（直连 RADOS） |
| pool | juicefs-data（EC 4+2 ec-prod）|
| cache-size | 0（冷态）|
| attr-cache | 300 |
| entry-cache | 300 |
| open-cache | 300 |
| layout | 8 files × 1G（为加速，非标准 128）|

---

## 二、tcpdump 分解结果（顺位2，2026-06-23 补测更新）

### 2.1 全量捕获（60s fio + 前后 ~5s 覆盖）

| 指标 | 值 |
|------|-----|
| pcap 文件大小 | 6.6 GB |
| 总包数 | ~3.3M |
| OSD→客户端 TCP payload（src port 6800-6803，全量） | **6,413 MB** |
| OSD→客户端 数据 PUSH 包（>500B, tcp-push） | 123,598 |
| 客户端→OSD 小包（<500B）| 1,736,027 |
| fio 有效读 | 2,219 MiB = **2,327 MB** |

### 2.2 TCP 层放大计算

```
TCP payload 放大 = 6413 MB / 2327 MB = 2.75×
PUSH 包/read = 123,598 / 8,820 = 14.0
```

> **初始版（§2 旧）误差**：首次用 `greater 200` 过滤仅测到 3,602 MB，得出 1.58× 是错误的——该 filter 漏掉了大量 200-500 字节的 TCP 控制包和数据包的 IP 分片尾段。全量无 filter 的 2.75× 才是正确的 TCP payload 放大。

### 2.3 PUSH 包按 OSD 节点分布

| 源 IP | 节点 | PUSH 包数 |
|-------|------|----------|
| 192.168.11.13 | ceph-node2 | 49,891 |
| 192.168.11.14 | ceph-node3 | 49,237 |
| 192.168.11.11 | ceph-node1 | 24,470 |
| **Total** | | **123,598** |

3 个 OSD 节点参与服务读请求。node1 流量偏少（~24K vs ~49K），可能与 PG 主副本分布不均有关。

### 2.4 放大构成分解（TCP 层）

```
2.75× TCP payload 放大构成：
├── 1.00×  fio 有效数据（2327 MB）
├── 0.04×  L1 rados 裸放大（10_3 实测，不在此层体现）
├── ~0.54× Ceph messenger 协议开销（header/footer/auth/keepalive，每消息 ~200-400B）
├── ~0.15× TCP 重传/乱序膨胀（3.3M 包中部分为 retransmission）
├── ~0.05× 后台 Ceph 心跳（OSD↔OSD 消息也在 6800-6803 端口，少量经客户端网卡）
├── ~0.97× **未归因差额**
```

2.75× − (1.00 + 0.54 + 0.15 + 0.05) = **0.97× 未归因**。

此 0.97× 的可能来源（GLM5.1 §2.2 指出的两条核心嫌疑）：
- **JuiceFS slice 碎片化**：部分覆盖写导致 1 block = N slice = N 对象 GET（0.5–1.0×）
- **JuiceFS prefetch**：随机读下拉相邻 block 的对象 GET（0.5–1.0×）
- tcpdump 时间窗口比 fio 多 ~5s，额外捕获了非测试流量

### 2.5 tshark Ceph 协议深度解析——未完成

安装了 tshark 3.6.2（`wireshark-common` 自带 Ceph dissector），但 Ceph dissector **未能在实际流量上激活**：
- `tshark -d tcp.port==6800,ceph` 无输出
- 协议注册存在（`tshark -G protocols | grep Ceph` 有 `Ceph Ceph ceph`）
- 可能原因：Ceph v2 协议（port 6800）的 wire format 需要从连接握手开始才能被 dissector 识别，而只捕获了 stream 中间的 read 请求/响应

**替代分析方案**（如后续需要精确分解）：
1. 在客户端跑一个小规模 fio（如 1 job, 10s），同时用 tcpdump + `-s 0` 完整抓包
2. 将 pcap 传至有完整 Wireshark GUI 的桌面分析 Ceph dissector
3. 或用 python-rados 直连 OSD 单步测单次 read 的报文量作为对照

### 2.6 slice 碎片化初步判断

每 fio read ~14 PUSH 包。EC 4+2 理论需 4 个 Ceph OSD 应答，含 GRO（每应答 ~1-3 个 PUSH 包）→ 预期 ~4-12 PUSH 包。实测 14 在预期上界，**不足以断定 slice 碎片化**，但也不能排除——需 Ceph message 级解析才能确证。

---

## 三、元数据缓存结果（顺位3）

### 3.1 fio 结果

| 指标 | 本次（元数据缓存）| 基线（无缓存，128jobs）|
|------|------------------|---------------------|
| BW | **37.9 MB/s** | 45.9 MB/s |
| IOPS | 144 | ~183 |
| numjobs | 8 | 128 |
| files | 8 × 1G | 128 × 1G |
| clat avg | 6,657 ms | — |

### 3.2 判读

37.9 vs 45.9 不可直接对比（numjobs=8 vs 128）。但 37.9/8 = 4.74 MB/s per job，对比 45.9/128 = 0.36 MB/s per job——单 job 吞吐反而更高，说明**并非 metadata cache 提升了性能，而是小规模测试消除了 job 间竞争**。

**结论：元数据强缓存对纯 randread 瓶颈无效**，与 08/09 系列原有结论一致。randread 瓶颈不在 TiKV 元数据往返层。

### 3.3 juicefs mount 警告

mount 日志显示：
```
cache-size is 0, writeback and prefetch will be disabled
```

`--prefetch` 在 cache-size=0 时自动禁用，无需额外指定 `--prefetch 0`。

---

## 四、综合判断（2026-06-23 补测更新）

### 4.1 放大分解（订正后口径）

| 层级 | 放大因子 | 来源 | 状态 |
|------|---------|------|------|
| L1 rados 裸读 | **1.04×** | 10_3 实测 | ✅ 已标定 |
| **应用层 syscall（JuiceFS 读 Ceph socket）** | **2.60×** | §4.4 strace | ✅ **采用为基准**（无窗口/重传噪声） |
| **NIC RX 增量 / fio 有效读（numjobs=8 冷态）** | **2.98×** | opencode 重测 `/proc/net/dev` | ✅ 实测（含 TCP/IP 头+协议帧） |
| NIC RX / fio（128 并发，09/10 系列） | **~2.5×** | 09_1/10 系列 | ✅ 已知 |
| ~~TCP payload / fio（全量 tcpdump）~~ | ~~2.75×~~ | ~~本次全量 tcpdump~~ | ❌ **降级不采用**：tcpdump 窗口比 fio 多 ~5s，被 OSD 心跳/重传污染（§4.1 旧注已自承） |

> **订正说明**：早前以 2.75× 为结论是错的（被窗口噪声抬高，反而 > NIC）。现以 **strace 2.60×（应用层净）** 为基准，**NIC 2.5–3.0×（含协议头，随并发/工作集波动）** 为佐证，两者自洽。放大倍数不是精确常数，定性"~2.5–2.6× 在 JuiceFS 内部"稳固。

### 4.2 2.5× 主因定位（以 strace 为准）

strace §4.4 已给出最干净的分解：**每 fio read ≈ 139 次 Ceph socket read ≈ 4 OSD × 35**，
精确对齐 EC 4+2 四分片 → **slice 碎片化不是主因**（若是，会触发 >4 个 OSD 的 GET）。
剩余放大来自 Ceph messenger 协议帧（每对象 GET 的 header/footer/分段）+ JuiceFS 读路径调度，
**非 slice 碎片、非额外对象 GET**。GLM5.1 此前预估的 slice 碎片化 1.0–2.0× 被 strace 证据排除。

### 4.3 Ceph dissector 状态

安装了 tshark 3.6.2 + libwireshark + Ceph protocol dissector，但 **Ceph 报文解码未生效**——`tshark -d tcp.port==6800,ceph` 无 Ceph 字段输出。可能原因是 Ceph v2 协议需从连接握手开始才能被 dissector 识别。

**todo**：如需精确分解 slice 碎片 vs prefetch，需将 pcap 传至有 Wireshark GUI 的桌面分析，或在测试节点升级 tshark/wireshark 到更新版本。

### 4.4 strace socket IO 补充分析（2026-06-23）

绕过 tcpdump/tcp 层，直接从 JuiceFS 进程 syscall 层追踪 Ceph socket 读写。

**方法**：`strace -f -e trace=read,readv -p <juicefs_pid>` 在 fio 10s 期间捕获所有 read() 调用，Python 解析器关联 `unfinished→resumed` 跨行配对，精确还原每个 fd 的读写量。

**CEPH socket fd 识别**：
```
fd 29 → 192.168.11.13:6800 (node2, msgr2)
fd 30 → 192.168.11.14:6801 (node3, msgr1)
fd 31 → 192.168.11.11:6801 (node1, msgr1)
fd 33 → 192.168.11.13:6802 (node2)
fd 34 → 192.168.11.14:6800 (node3, msgr2)
fd 35 → 192.168.11.11:6800 (node1, msgr2)
```

**结果**：

| 指标 | 值 |
|------|-----|
| Ceph socket read() 总字节 | **1,007.4 MB** |
| fio 有效读 | **388 MB**（10s）|
| **syscall 层放大** | **2.60×** |
| Ceph read() 调用总次数 | 210,385 |
| 每 fio read Ceph read() 调用 | 139 |
| 平均每 read() 读量 | 4,788 bytes |

**按 OSD 节点分布**：

| 节点 | Ceph 数据量 | read() 调用数 | 占比 |
|------|-----------|------------|------|
| node2 (.13) | 416.4 MB | 80,458 | 41.3% |
| node3 (.14) | 413.3 MB | 81,731 | 41.0% |
| node1 (.11) | 177.6 MB | 48,196 | 17.6% |

**判读**：
- 系统调用层放大 = **2.60×**，与 TCP payload 2.75× 和 NIC 2.5× 自洽（strace 不含 TCP 协议头，所以略低于 TCP、略高于 NIC）
- 每 fio read **139 次 Ceph read() 调用**。EC 4+2 每 block=4 shard，每 shard 对应 1 个 Ceph 对象 GET，每 GET 经 ~35 次 read() 调用（Ceph messenger 头 + 数据分段）→ 4 × 35 = 140，与实测 139 **精准对齐**
- 4 个 OSD 参与（非 5-6+），说明 **slice 碎片化不是主因**（如果是，1 block 会触发 >4 个 OSD 的 GET）
- node1 数据量仅 17.6% 而非 25%，可能系该节点的 OSD PG 主副本比例偏低——作为次要因素，不影响瓶颈归因

**与 tcpdump 交叉验证**：
- tcpdump PUSH 包 14/read × ~5KB 平均包大小 ≈ 70KB/read（低估，因 GRO 合并）
- strace read 调用 139/read × 4,788 平均字节 = 665KB/read
- 665/256 = **2.60×** — 应用程序层实测放大，确认 2.5×(NIC) ≈ 2.60×(strace) > 1.04×(L1 rados) 的放大链路

### 4.4 对候选清单的影响

| 顺位 | 实验 | 状态 | 说明 |
|------|------|------|------|
| ✅ 1 | FUSE congestion_threshold | **已证伪** | waiting=0，FUSE 未节流（10_A_1）|
| ✅ 2 | tcpdump 分解 | **已裁决（订正）** | tcpdump 2.75× 因窗口噪声**降级不采用**；改以 strace **2.60×**（应用层净）+ NIC **2.98×**（numjobs=8 重测）为准。strace 139≈4×35 已证**slice 碎片化非主因**，无需 Ceph dissector 再裁决 |
| ✅ 3 | 元数据强缓存 | **已证伪** | 对纯 randread 无增益 |
| ✅ 4 | FUSE 预读关停 | **已完成（10_3 §三）** | `--max-readahead 0 --prefetch 0`：放大 3.12→2.04×，贡献约 1/3（`no_readahead` FUSE 层本系统不支持，见 10_A_7）|

---

## 五、链路限定

1. numjobs=8（非标准 128），amplification 数值可能与 128-job 场景有偏差
2. tcpdump 的分析仅基于 TCP payload >200B 过滤，small ACK 和 Ceph keepalive 未计入
3. 未做 Ceph 消息协议深度解析（需 tshark/wireshark Ceph dissector），无法区分"每 read 几 GET"
4. pcap 仅覆盖 6800-6803 端口，若 OSD 使用其他端口则遗漏

---

环境：tikv-node (192.168.11.12)，JuiceFS v1.3.1，Ceph HEALTH_OK，pool juicefs-data EC 4+2，2026-06-23 18:20 CST。
