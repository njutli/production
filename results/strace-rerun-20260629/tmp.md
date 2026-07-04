# librados 内部分层与读放大机制

## 完整调用链

```
JuiceFS 调用 rados_read(obj_name, buf, 256K)
          │
          ▼
┌─ librados API ────────────────────────────────────┐
│  对外接口。JuiceFS 调 ioctx.read("chunk_xxx", 256K) │
│  这层几乎零开销，就是参数校验后往下传                  │
└──────────────────────┬────────────────────────────┘
                       ▼
┌─ Objecter ───────────────────────────────────────┐
│  对象定位层。用 crush 算法计算：                     │
│    obj_name → hash → PG → primary OSD             │
│  发 1 个 read op 给 primary OSD，由后者负责 EC 解码  │
│  客户端侧不做 EC 分片拆分——Objecter 只路由、不拆片   │
└──────────────────────┬────────────────────────────┘
                       ▼
┌─ Messenger (核心问题所在) ────────────────────────┐
│  Ceph 的网络 I/O 引擎。管理到每个 OSD 的 TCP 连接。  │
│  收 primary OSD 返回的完整 256K 对象响应            │
│                                                    │
│  共享线程池(2-3 worker) + epoll 多路复用 6 条连接:   │
│    epoll_wait() → 有数据可读 → read(fd, buf, N)    │
│                                                    │
│  关键参数: ms_async_op_threads / ms_dispatch_throttle│
└──────────────────────┬────────────────────────────┘
                       ▼
┌─ TCP/IP + 网卡 ──────────────────────────────────┐
│  千兆网卡 + kernel TCP 栈。OSD 响应数据到达客户端    │
│  时被拆成 TCP segment (MSS=1460B) 逐个传输           │
│  epoll 唤醒时 socket buffer 里只攒了 1-6 个 segment   │
│  → read() 期望 117KB, 实际只拿到 ~6KB                │
└───────────────────────────────────────────────────┘
```

## 为什么 read() 返回这么少 —— 不是 messenger 的问题

### strace 证据

从 76,281 次已完成的 read() 中提取期望读取长度(buffer)与实际返回值:

```
Buffer (期望读取): avg 117,130 字节, max 262,124
Return (实际返回): avg   5,858 字节, max 258,599

短差率: 75.6% 的 read() 拿到不到期望的 10%
       仅有 4.3% 的 read() 拿到 100%
```

messenger 每次 read() 时要求的 buffer 很大（平均 117KB），说明**它不是在用小 buffer 碎读**。但实际返回很小，且高度集中在 TCP MSS 的整数倍:

```
返回值分布:
  1460 B → 21,054 次 (1 × MSS)    ← 最多
  2920 B → 13,602 次 (2 × MSS)
  4380 B →  9,020 次 (3 × MSS)
  5840 B →  6,236 次 (4 × MSS)
  7300 B →  4,609 次 (5 × MSS)
```

### 结论: 瓶颈在数据到达速率，不在 messenger

messenger 的工作模式是对的——epoll 通知数据到了 → 用一个很大的 buffer 去读 → 拿到当前 socket buffer 里所有可用的数据。问题不是它"故意读小块"，而是**每次 epoll 触发时 socket buffer 里只有 1-6 个 TCP segment（≈1.5-8KB）**。

数据从 OSD 经千兆网卡到达的速率跟不上 messenger 的消费速度。千兆带宽下，1 个 256K 响应需要 ~2ms 传输，但在高并发随机读场景下，单个对象的响应是分段到达的，epoll 在数据还没到齐时就唤醒了。

## 为什么不是 1 次 read 而是 295 次

Objecter 对每个对象只发 **1 个 read op** 给 primary OSD。服务端 OSD 负责 EC 分片读取和组装，返回一个完整的 256K 对象。但 Messenger 在收这个响应时，不是一次性读完：

```
OSD 响应: [Ceph header 64B] [256K payload] [Ceph footer 32B]

Messenger 的读法:
  read() → ~6KB (header + payload 前段)
  read() → ~6KB (payload 中段)
  read() → ~6KB (payload 中段)
  ...
  read() → ~6KB (payload 末段 + footer)

一个 256K 响应 ≈ 45-50 次 read()
多个对象并发 × 6 条连接 ≈ 295 次 total

根本原因: messenger 每次要 117KB, 但千兆网卡下数据分段到达, epoll 早醒,
          socket buffer 里只攒了 1-6 个 segment (1.5-8KB)

## 总结

- **不是 messenger 用小块碎读**: 它每次 read() 要求平均 117KB, 非常贪
- **不是 EC 分片放大**: L1 rados bench 256K rand = 1.04×, EC 机制本身几乎零开销
- **是数据到达速率跟不上消费速度**: 千兆网卡 + EC OSD 处理延迟下, OSD 响应分段到达, epoll 唤醒时 socket buffer 里只有 1-6 个 MSS (1.5-8KB), messenger 只能拿走这点
- **结果**: 75.6% 的 read() 拿到期望的不到 10%, 每次 read 带独立协议头帧边界 → 295 次 read × 协议开销 → 3× NIC 放大

## 每个对象只发给一个 OSD

一个 256K 对象的读请求，客户端**只发给 1 个 OSD 进程**——该对象所在 PG 的 primary OSD。

EC 分片不是在读请求时临时拆分的。对象在**写入时**就已经被 EC 拆成 4 data + 2 parity 共 6 个分片，分散存储在 6 个 OSD 上。primary OSD 收到客户端的读请求后，自己去其他 3 个 data OSD 把分片拉回来：

```
客户端: "读对象 X"
   │
   ▼  1 个请求, 走 1 条 TCP 连接
primary OSD (node2, osd.2):
   │
   ├── 从本地读自己的 data shard
   ├── 向 osd.0 拉 data shard      ← OSD 间内网, 不经过客户端
   ├── 向 osd.4 拉 data shard      ← 同上
   ├── 向 osd.5 拉 data shard      ← 同上
   │
   ▼  拼成完整 256K, 1 个响应返回
客户端: 收到完整对象
```

这 4 个 OSD 之间的分片搬运走的是 OSD 间集群内网，**不经过客户端网卡**——所以我们在客户端 strace 里只看到"收 1 个响应"而非"连 4 个 OSD 各取 64K"。

pool 配置证实了这点：

```
ceph osd pool get juicefs-data all | grep fast_read
fast_read: 0
```

`fast_read=0` 意味着由 primary OSD 负责重建完整对象。如果设为 1，客户端会同时向 4 个 data OSD 发请求、自己拼数据，每条连接都会独立产生响应流量。

## 为什么客户端维持到每个 OSD 的连接

虽然每个对象只跟它的 primary OSD 交互，但**不同对象分布在不同 primary OSD 上**。128G 数据包含 ~500K 个 256K 对象，CRUSH 算法把它们均匀 hash 到 6 个 OSD，每个 OSD 都担任一部分对象的 primary：

```
对象 A → hash → PG 7  → primary = OSD 2 → 走 FD 31 (node2:6800)
对象 B → hash → PG 3  → primary = OSD 5 → 走 FD 32 (node3:6801)
对象 C → hash → PG 15 → primary = OSD 0 → 走 FD 34 (node1:6800)
...
```

30 秒 randread 测试中 fio 并发访问的对象随机分布在所有 PG 上，**6 个 OSD 轮番担任 primary**——所以 6 条连接全都在工作，没有一条闲置。strace 里每条 FD 都有数万次 read() 印证了这一点。

## 请求 × 线程 × 连接：多对多关系

### 拓扑

```
fio (128 job) ──┐
  ...            ├── /dev/fuse ── JuiceFS daemon (单进程)
fio (128 job) ──┘                      │
                                        ▼
                                 librados (同一进程内)
                                        │
                                 Objecter: 并发 rados_read
                                        │
                                 Messenger: 2-3 个 worker 线程 (共享线程池)
                                        │
                                 epoll 复用 6 条 TCP 连接
                                        │
                              ┌─────────┼─────────┐
                              ▼         ▼         ▼
                           node1     node2     node3
                          (OSD 0,1) (OSD 2,3) (OSD 4,5)
```

不是每个 OSD 一个 worker。6 条 TCP 连接挂在共享的 epoll fd 上，线程池里的 worker 通过 epoll_wait 轮询，哪条连接有数据到达就哪个线程去 read。

### strace 证据

同一线程读取两个不同 OSD 的 FD，证明线程池共享连接：

```
2180982 read(28, ...)  ← FD 28 → ceph-node3:6800 (osd.4)
2180982 read(31, ...)  ← FD 31 → ceph-node2:6800 (osd.2)
```

完整映射（本次运行）：

| 线程 | 管理的 FD | 对应 OSD |
|------|----------|---------|
| 2180982 | 28 + 31 | node3 osd.4 + node2 osd.2 |
| 2180983 | 29 + 32 | node2 osd.3 + node3 osd.5 |
| 2180984 | 30 + 34 | node1 osd.1 + node1 osd.0 |

3 个线程管理 6 条连接，每个线程负责 2 条。线程和连接是 **多对多**（不是 1:1 绑定）：同一线程轮询多条连接，同一连接的数据在不同时间点可能由不同线程处理（取决于 epoll 当时的调度）。

### 这对读放大的影响

线程池共享模型意味着一个线程在 epoll 返回后会立刻读完当时可用的数据（~5-6KB），然后立即返回 epoll_wait 循环，**不会阻塞等待同一条连接上攒够 64K 或 256K 再读**。这就是为何每个 read() 只能拿到 TCP 栈里已经到达的 3-4 个 segment（≈5-6KB），而非完整的数据块。
