# 测试用例（cases/）

> 用例按前缀分类：
>
> | 前缀 | 全称 | 含义 |
> |------|------|------|
> | **FT** | Fault Tolerance | 容错验证——验证故障期间数据可用、I/O 不中断 |
> | **OPS** | Operations | 运维操作——验证恢复/重建等运维流程可执行 |
> | **DG** | Degradation | 性能退化量化——验证故障期间吞吐退化幅度可控 |
>


---

---

## 一、P0 用例

### FT-001：单盘故障——OSD 进程异常

| 项 | 值 |
|----|-----|
| 故障注入 | 内联 SIGKILL（同 `stop_osd` 逻辑：`systemctl stop --no-block` + `docker kill --signal KILL`） |
| 关键断言 | fault 期间 I/O 写入延迟 < 5000ms、PG degraded、恢复后 PG clean + 恢复时间 < 300s |
| 预估时长 | 5min |

**I/O 行为总结**：SIGKILL 1 OSD 后，通过 fast-fail 检测 + PG peering 恢复。客户端本地 dd 写入途中 kill OSD（从 .12 同网段 SSH kill，延迟 ~0.5s），实测故障写入延迟 692ms-2.6s——包含 fast-fail 检测 + MON 标记 down + PG peering + 客户端获取新 OSD map + rerouting。

> **实测结果**（客户端本地 1GB dd 写入途中 kill OSD）：
> - 基线写入 1GB：~9150-9170ms（稳定）
> - 故障写入 1GB：~9860-11730ms
> - **延迟：692ms ~ 2565ms**
> - I/O 成功率 100%（dd 退出码 rc=0，1GB 全部写入成功无失败）
>
> 延迟构成：fast-fail 检测 + MON 标记 down + PG peering + 客户端获取新 OSD map + rerouting。
> SSH 从客户端到存储节点同网段延迟 ~0.3-0.5s，仍会部分掩盖延迟。
> 所有 I/O 最终成功（EC 4+2 容忍 1 OSD down，min_size=5）。OSD 不会自动恢复（cephadm 管理的 OSD 被 `systemctl stop` 后不会自动重启——OSD unit 为 `Restart=on-failure`，手动 stop 不触发重启；TiKV 是 kill -9 被 `Restart=always` 拉起，机制不同）。

### FT-002：单盘故障——磁盘故障

| 项 | 值 |
|----|-----|
| 故障注入 | `dmsetup load` error target（让 dm 设备返回 EIO，模拟真实磁盘故障） |
| 关键断言 | fault 期间 I/O 写入延迟 < 8000ms、PG degraded、故障期间数据完整 |
| 预估时长 | 8min |

**I/O 行为总结**：`dmsetup load` error target 让磁盘返回 EIO，OSD 的 BlueStore 检测到 I/O 错误后 crash → 恢复路径与 FT-001（SIGKILL）相同。crash 之前 OSD 仍运行，命中 BlueStore 缓存的 I/O 正常完成，触发磁盘 I/O 的操作收到 EIO 返回错误。crash 之后通过 fast-fail + peering 恢复。

> 注：OSD unit 为 `Restart=on-failure`（RestartSec=10s），EIO 窗口内 OSD 实际处于 crash loop（反复 boot→EIO→abort），每次 crash 产生一条 crash 归档；测得延迟含首次 EIO-to-crash + loop 期间的 fast-fail/peering。
>
> **实测结果**（客户端本地 1GB dd 写入途中注入 EIO）：
> - 基线写入 1GB：~9160-9170ms（稳定）
> - 故障写入 1GB：~11400-13850ms
> - **延迟：2227ms ~ 4685ms**（波动因 EIO-to-crash 间隔不确定）
> - I/O 成功率 100%（dd 退出码 rc=0，1GB 全部写入成功无失败）
>
> 延迟构成：EIO-to-crash（不确定，~1-3.5s）+ fast-fail + peering + rerouting（~1s，与 FT-001 一致）。
> EIO-to-crash 间隔取决于 OSD 何时做磁盘 I/O：命中 BlueStore 缓存的操作不碰 EIO，crash 慢；触发磁盘 I/O 的操作立即碰到 EIO，crash 快。
> **与 FT-001 的关键区别**：FT-001 SIGKILL 延迟 692-2565ms（无 EIO-to-crash 间隔），FT-002 多了不确定的 EIO-to-crash 延迟。crash 之后的恢复路径两者一致。

### FT-003：节点宕机（2 OSD + 1 MON + 1 TiKV + 1 PD 同时失效）

| 项 | 值 |
|----|-----|
| 故障注入 | `crash_node_storage <ip>`（iptables 隔离节点全部流量，模拟节点不可达） |
| 关键断言 | PD leader 切换、OSD count=4、MON quorum 2/3、I/O 恢复、恢复后数据完整 |
| 预估时长 | 10min |

**I/O 行为总结**：节点隔离同时影响数据面（2 OSD down）和元数据面（PD leader + 1 TiKV down）。集群恢复快（PD leader 切换 ~16s + OSD heartbeat 20s + peering 2s ≈ 38s），但 **JuiceFS 客户端检测不到 TiKV/PD 连接断开**（iptables DROP 不回 RST，TCP 连接半开），I/O 实际阻塞 ~500s（8 分钟），直到 TCP 重传超时后客户端切换到健康节点。2 OSD down 导致 4 可用 < min_size(5)，**写入在整个故障期间不可用**，直到节点恢复。

#### I/O 行为分析（实测数据）

**与 FT-001/FT-002 的关键区别**：

| | FT-001/FT-002（1 OSD SIGKILL/EIO） | FT-003（节点隔离） |
|---|---|---|
| 故障范围 | 1 OSD | 2 OSD + 1 MON + 1 TiKV + 1 PD |
| 网络行为 | TCP RST（进程退出） | **iptables DROP**（不回 RST） |
| fast fail | ✓ | ✗（DROP 无 RST，客户端不知道连接断了） |
| peering | ✓（~2s） | ✓（~2s） |
| 写入能否成功 | ✓（5 ≥ min_size=5） | ✗（4 < min_size=5） |
| I/O 恢复时间 | 0.7-2.6s(FT-001) / 2.2-4.7s(FT-002) | **~500s**（TCP 重传超时） |

**故障检测路径（多层恢复，但客户端卡在 TCP 超时）**：

```
T=0      iptables DROP → 节点全部流量被丢弃
         │
         ├─ Ceph 数据面：
         │  OSD 进程活着但无法通信 → heartbeat 20s 超时 → MON 标记 down
         │  → peering ~2s → PG active+degraded
         │  → 4 OSD 可用，读可以（EC k=4），写不行（4 < min_size=5）
         │
         ├─ TiKV/PD 元数据面：
         │  PD leader 隔离 → Raft 选举 → 新 leader ~16s
         │  TiKV store 隔离 → PD 标记 store Down
         │  → 集群层面元数据面已恢复
         │
         └─ JuiceFS 客户端（.12）：
            TCP 连接到宕机节点的 PD/TiKV → 半开（DROP 无 RST）
            → 客户端不知道连接断了 → 持续重传
            → TCP 重传超时（~500s）→ 检测到连接断开
            → 切换到健康节点的 PD/TiKV → I/O 恢复
            ↑
            这才是 500s 的真正来源
```

> **集群恢复快（~38s），但客户端恢复慢（~500s）**：peering 和 PD leader 切换都在 38s 内完成，但 JuiceFS 客户端的 TCP 连接被 iptables DROP 半开，客户端无法感知连接已断，持续重传直到 TCP 超时。
> 这是 **iptables DROP 模拟节点宕机的固有缺陷**——真实宕机（断电）会让 TCP 连接立即超时（对端无响应 + ARP 失败），客户端能更快感知。

**各类 I/O 表现**：

| I/O 类型 | 故障期间 | 恢复后 |
|----------|---------|--------|
| 读（命中 4 个存活 OSD 的 PG） | **阻塞**（客户端 TCP 连接到宕机节点的 TiKV 半开，metadata 不可用） | 恢复后正常 |
| 写 | **失败**（4 < min_size=5，EC 降级写入不满足） | 节点恢复后正常（6 ≥ min_size=5） |
| in-flight 读 | 阻塞（同上） | — |
| in-flight 写 | 阻塞，peering 后也失败（min_size 不满足） | — |

> **写入和 FT-001/FT-002 的关键区别**：FT-001/FT-002 只 down 1 OSD，5 ≥ min_size(5)，写入可成功。FT-003 down 2 OSD，4 < min_size(5)，写入在整个故障期间不可用。
> **读取也不同于 FT-001/FT-002**：即使 Ceph peering 完成（4 OSD 可用，EC k=4 可读），JuiceFS 客户端的 metadata 请求仍卡在半开 TCP 连接上，导致读取也无法完成。

**实测数据**（最近一次 FT-003 运行）：

| 指标 | 值 | 说明 |
|------|-----|------|
| PD leader 切换 | 16s | Raft 选举完成 |
| OSD 标记 down | ~22s | heartbeat 20s grace + 处理 |
| peering | ~2s | 与 FT-001 一致 |
| 集群恢复总计 | ~38s | PD + OSD + MON 全部恢复 |
| I/O 恢复（首次读成功） | **~500s** | 探测耗时 558s，8 次失败（每次 60s timeout） |
| I/O 恢复后写入 | 不可用 | 4 < min_size(5)，节点恢复后写入才可用 |
| 恢复后成功率 | 100% | 节点恢复后 I/O 全部正常 |

> I/O 恢复的 ~500s 远超集群恢复的 ~38s，差额 ~462s 是 JuiceFS 客户端 TCP 重传超时。
> 探测机制每 15s 发起一次读取（loop 变量），但每次失败的 dd 有 60s timeout，实际每次迭代耗时 ~62s。8 次失败 = 8 × 62s = 496s，第 9 次成功。

### FT-004：单 TiKV down（元数据面选举延迟 + 数据面不受影响）

| 项 | 值 |
|----|-----|
| 故障注入 | `freeze_tikv <ip>`（kill -STOP 冻结 TiKV，模拟节点假死） |
| 目标选择 | PD API 查 metadata region leader 所在节点（确定性命中） |
| 关键断言 | 元数据成功率 100%、最大延迟 < 30s、I/O 不中断 |
| 预估时长 | 6min |

**I/O 行为总结**：冻结 1 TiKV（Raft 2/3 majority 保持），数据面（Ceph OSD）完全不受影响。元数据操作在 Raft 选举期间阻塞 10-20s 后自然恢复（100% 成功率）。kill -STOP 不触发 Restart=always，无 TCP RST，follower 心跳超时后真实选举。

**实测数据**（`results/20260811-160355/`，19/19 PASS）：

| 指标 | 值 | 说明 |
|------|-----|------|
| 元数据成功率 | 71/71 = 100% | 阻塞后自然恢复 |
| 元数据最大延迟 | **15.5s** | 落在 Raft 选举超时 10-20s 范围内 |
| fio 成功率 | 100% | 数据面不受影响 |
| fio P99 | 17.1s | 与基线相同（稳态排队延迟） |
| OSD | 6/6 up | 数据面完全不受影响 |
| 集群健康 | HEALTH_OK | 全程无 ERR |

> 数据面 fio 走 Ceph 直连 RADOS，不经过 TiKV，不受影响。
> 元数据操作（touch/create）需查 TiKV，选举期间阻塞 10-20s。

#### 元数据恢复延迟分析

逐层调优实验（5 组），定位了恢复延迟的完整检测链：

| 层 | 机制 | 默认耗时 | 可调 |
|----|------|---------|------|
| 1 | gRPC keepalive（检测连接无响应） | 13s（10s+3s） | 需改 JuiceFS 源码 |
| 2 | batch recvLoop waitConnReady（等连接恢复） | **5s** | **硬编码（dialTimeout, 不可配）** |
| 3 | checkLiveness（HealthCheck 探测） | 1s | 硬编码 |
| 4 | 连接新 leader + RPC | ~3s | — |
| **总计** | | **~17s（默认）** | |

调优效果：gRPC keepalive 10s/3s→2s/1s 可省 10s（17.3→12.2s），但层 2-4 共 ~9s 硬编码不可调，是理论最低值。Raft 选举（hibernate-regions、raft-base-tick-interval）对总延迟无影响——选举 1-2s 完成，但客户端要 3s 才检测到连接死亡，之后还要等 waitConnReady 5s。

本集群已恢复为默认配置。

### FT-005：双 TiKV down（元数据面完全不可用）

| 项 | 值 |
|----|-----|
| 故障注入 | 停 2/3 TiKV |
| 关键断言 | 元数据操作先阻塞后报错（~80s 量级）、恢复后无感继续、无元数据损坏 |
| 预估时长 | 8min |

**为什么剩 1 个 TiKV 仍然不可用**：Raft 需要配置成员的 majority（2/3）才能选 leader。停 2 个只剩 1 个时，这个 TiKV 知道自己是 3 成员组的一部分，无法获得 2 票 → 选不出 leader → 读写全阻塞。数据没丢（还在那 1 个 TiKV 上），但无法服务。

> **实测结果**（`results/20260811-160915/`，20/20 PASS）：dd 写阻塞 41s 后返回错误（rc=1），并非无限阻塞。fio SIGINT 无效被 SIGKILL（元数据全阻塞的预期表现——fio randrw 需元数据）。

> 这和一开始只部署 1 个 TiKV 不同：1 成员 Raft 组，自己投自己 = 1/1 = 100% majority → 立即当选 leader → 正常服务。关键不是"剩几个节点"，而是"Raft 能否凑够 majority"——3 配置的组 down 到只剩 1 个，那 1 个不会自作主张当 leader。

### OPS-001：磁盘故障换盘重建

| 项 | 值 |
|----|-----|
| 考察点 | 备用盘（tmpfs 模拟）能加入集群并发挥作用 |
| 验证方式 | 销毁 OSD A → tmpfs 备用盘替代 → 恢复后对另一盘 B 注入故障 → I/O 正常说明备用盘真正生效 |
| 预估时长 | ~20min |

---

## 二、P1 用例

### FT-006：单 MON down（仍保持 quorum）

| 项 | 值 |
|----|-----|
| 故障注入 | `stop_mon <ip>` |
| 关键断言 | 集群可操作、quorum 2/3 不受影响 |
| I/O 延迟检测 | 无（MON 不在数据路径上） |
| 预估时长 | 4min |

**I/O 行为总结**：单 MON down 对 I/O 无影响。MON 不在数据路径上——客户端缓存 OSD map 后直接和 OSD 通信。3 MON down 1 个，quorum 2/3 保持，集群管理功能（OSD map 更新、认证）正常。

**I/O 延迟构成**：

```
IO 延迟 = 0s（MON 不在数据路径上，无影响）
```

**受控实验结果**（见上方"受控 I/O 对比实验"表）：IOPS 233→250、P50/P99 不变、Max 不变，全部在正常波动范围内。

### FT-007：双 MON down（丢失 quorum）

| 项 | 值 |
|----|-----|
| 故障注入 | 停 2/3 MON |
| 关键断言 | 管理面冻结、已有 I/O 前 30s 正常后逐渐退化（monc_lock 竞争）、恢复后立即正常 |
| I/O 延迟检测 | 无（MON 不在数据路径上，但 quorum 丢失会触发锁竞争，见下方分析） |
| 预估时长 | 4min |

**I/O 行为总结**：2/3 MON down → quorum 丢失 → 客户端 `MonClient` 进入 hunting 模式（反复尝试连接 MON）。hunting 期间多个线程竞争 `monc_lock`，间接拖慢 Objecter 的周期性维护（`tick`），导致 I/O dispatch 变慢。**不会完全卡住**——退化为略低的稳态吞吐（IOPS 233→214，-8%），因为 I/O 提交的 fast path 不需要 `monc_lock`。

**源码级分析**（Ceph `MonClient.cc` + `Objecter.cc`）：

`monc_lock` 是 `MonClient` 的**唯一一把锁**（`MonClient.h:309`），保护 MON 连接状态、cephx auth、OSD map 订阅、hunting 标志。

**timer 行为**（`SafeTimer` 绑定 `monc_lock`，`safe_callbacks=true`）：

```
timer 持锁 → tick() → _check_auth_tickets() + _reopen_session()
  → _add_conns() → messenger->connect_to_mon() （异步 TCP，不等）
  → 放锁 → 等 hunt_interval 后再持锁跑下一轮

messenger 线程：TCP connect 到 DROP'd MON → SYN 重传 → 超时
  → ms_handle_reset() → 持 monc_lock（短，检查 hunting 状态后返回）
```

timer **不持锁等 TCP**——TCP connect 是异步的，`tick()` 启动连接后立即放锁。

**为什么前 30s 正常**：TCP SYN 重传未超时（DROP 不回 RST，内核重传 1s→3s→7s→15s→31s），messenger 还没回调，`monc_lock` 无竞争。I/O 用缓存的 OSD map + 有效 cephx authorizer，走 fast path。

**为什么 30s 后逐渐退化**：TCP 超时触发 `ms_handle_reset()` 回调，与 timer `tick()` 竞争 `monc_lock`。Objecter 的周期性维护（`sub_want`/`renew_subs` 续期 OSD map 订阅）也要 `monc_lock`，被竞争拖慢 → `tick()` 延迟增大 → 重传/调度变慢 → 吞吐下降。

**为什么不会完全卡住**：

| 组件 | 是否需要 `monc_lock` | 频率 |
|------|---------------------|------|
| `op_submit()`（每次 I/O 提交） | **否**（用 `objecter_lock` + 缓存 map） | 每 I/O 一次，不碰 `monc_lock` |
| `sub_want`/`renew_subs`（订阅续期） | 是（持锁短，入队请求不等响应） | 周期性 |
| `build_authorizer`（新 OSD 连接） | **否触发**（OSD 没变，不新建连接） | — |
| `get_version`（拉新 map） | **否触发**（OSD 没返回 stale） | — |

I/O 提交的 fast path 不碰 `monc_lock` → 吞吐不会降到 0。

**为什么退化会稳定**：

1. `hunt_interval` 带退避递增（`reopen_interval_multiplier` 每轮 ×backoff）→ timer 持锁越来越少
2. TCP 超时后不再重连（退避到 max）→ messenger 回调越来越少
3. 竞争频率收敛到稳态 → `monc_lock` 竞争稳定 → 吞吐稳定在略低水平

**I/O 延迟构成**：

| 阶段 | 延迟 | 说明 |
|------|------|------|
| 0-30s | ~0s | TCP 未超时，`monc_lock` 无竞争，fast path 正常 |
| 30s+ | 逐渐增加 | TCP 超时回调 + timer tick 竞争 `monc_lock`，Objecter 维护被拖慢 |
| 稳态 | -8% IOPS | 竞争频率收敛，吞吐稳定在 214 IOPS（不降到 0） |
| 恢复后 | 立即恢复 | MON quorum 恢复，hunting 停止，锁竞争消失 |

> **根因**：不是 MON 直接阻塞了 I/O（MON 不在数据路径上），而是 MON 不可用触发的 TCP 重试回调与 timer 竞争 `monc_lock`，间接拖慢 Objecter 周期性维护，导致 I/O dispatch 变慢。退化是渐进的（前 30s TCP 未超时）且稳定的（fast path 不受影响，退化为略低吞吐而非卡死）。
> **证据**：strace 显示 16+ 线程竞争 `monc_lock`；受控实验前 30s I/O 正常、之后退化到 214 IOPS 稳态（-8%，非 0）。
> **对比 FT-006（1 MON down）**：quorum 保持，无 hunting，`monc_lock` 无竞争，I/O 无影响。

### FT-008：单 PD down

| 项 | 值 |
|----|-----|
| 故障注入 | `freeze_pd <ip>`（kill -STOP 冻结 PD，模拟节点假死） |
| 关键断言 | 元数据成功率 100%、最大延迟 < 30s、PD leader 自动切换、I/O 不中断 |
| 预估时长 | 6min |

**I/O 行为总结**：冻结 1 PD（kill -STOP），Raft majority 保持（2/3）。数据面（Ceph OSD）完全不受影响。元数据最大延迟 21.0s——PD 冻结后 TSO 不可用，TiKV 事务阻塞，直到 PD Raft 选举新 leader + gRPC keepalive 检测连接死亡 + 客户端重连。

**实测数据**（`results/20260811-163348/`，22/22 PASS）：

| 指标 | 值 | 说明 |
|------|-----|------|
| 元数据成功率 | 58/58 = 100% | 阻塞后自然恢复 |
| 元数据最大延迟 | **21.0s** | gRPC keepalive 13s + PD 选举 ~3s + 重试 ~5s |
| fio 成功率 | 100% | 数据面不受影响 |
| PD leader 切换 | ceph-node2→ceph-node3 | 自动切换 |
| OSD | 6/6 up | 数据面完全不受影响 |
| 集群健康 | HEALTH_OK | 全程无 ERR |

> 使用 kill -STOP 冻结 PD（不触发 Restart=always，无 TCP RST → 真实选举）。
> PD down 阻塞 TSO 分配（事务启动依赖），与 FT-004（TiKV down 阻塞 region leader 访问）机制不同，但延迟量级相近（~20s）。

### FT-009：双 PD down（PD quorum 丢失）

| 项 | 值 |
|----|-----|
| 故障注入 | 停 2/3 PD |
| 关键断言 | PD 管理面冻结、TiKV 事务阻塞（TSO 不可用）、恢复后元数据可用 |
| I/O 延迟检测 | 无（PD 不在数据路径上，但 TSO 完全不可用会阻塞元数据，见下方分析） |
| 预估时长 | 8min |

**I/O 行为总结**：2/3 PD down → PD quorum 丢失 → TSO（时间戳分配）完全不可用 → TiKV 所有事务无法启动（region cache 只省路由不省 TSO）→ JuiceFS 元数据操作完全阻塞。数据面（Ceph 6/6 OSD）不受影响，但需要元数据的 I/O（写新 block、查新 chunk 位置）全部阻塞，不需要元数据的 I/O（读已缓存 chunk 位置的数据）不受影响。

> **和 FT-008（1 PD down）的区别**：FT-008 quorum 保持，元数据阻塞 ~21s 后恢复（gRPC keepalive + 选举）。FT-009 quorum 丢失，TSO 完全不可用，元数据操作彻底阻塞直到 PD 恢复。
> **和 FT-007（2 MON down）的区别**：MON quorum 丢失是 librados `monc_lock` 锁竞争间接阻塞 I/O dispatch。PD quorum 丢失是 TSO 不可用直接阻塞 TiKV 事务，进而阻塞 JuiceFS 元数据。两者都不在数据路径上，但间接影响机制不同。

### FT-010：JuiceFS FUSE crash

| 项 | 值 |
|----|-----|
| 故障注入 | kill JuiceFS FUSE 进程 |
| 关键断言 | mount 不可用、已 close 数据完整（无 writeback，close 即持久化）、重启 FUSE 后恢复 |
| 预估时长 | 3min |

**I/O 行为总结**：FUSE 进程被 kill → mount 点不可用（所有 I/O 返回 ENOTCONN 或阻塞）→ 数据在 Ceph OSD 上完整（不受 FUSE crash 影响）→ 重新 mount 后 FUSE 连接 Ceph + TiKV，数据立即可读。JuiceFS 无 --writeback，close() 即上传后端持久化，已 close 的数据在 crash 后完整保留。

> **数据面不受影响**：Ceph OSD 和 TiKV 都是独立进程，FUSE crash 不影响它们。重新 mount 后数据立即可用。
> **和 OSD/MON/TiKV/PD 故障的区别**：FUSE crash 影响的是客户端接入层，不是后端存储。后端存储故障影响"数据是否还在"，FUSE crash 只影响"客户端能否访问"。

### OPS-002：逐节点重启

| 项 | 值 |
|----|-----|
| 操作 | 逐节点 reboot（tmpfs 丢失 = 每节点 2 OSD 走重建路径） |
| 关键断言 | 重建流程逐节点可重复、重建后数据完整、单节点重建期间数据可用 |
| 预估时长 | ~3×单节点重建时长 |
| 状态 | ⚠️ 暂不执行（需 reboot 节点，影响大） |

### DG-001：OSD down 吞吐退化

| 项 | 值 |
|----|-----|
| 故障注入 | 停 1 OSD |
| 关键断言 | 降级稳态吞吐 ≥ 基线 80% |
| 预估时长 | 5min |

**I/O 行为总结**：比较 6/6 OSD up vs 5/6 OSD down（稳态 active+degraded）的吞吐差异。两轮相同时长 fio（randread，预创建文件避免元数据干扰），唯一变量是有无 OSD down。

**实测结果**：基线 IOPS=164，降级 IOPS=192，比率=110%。**单 OSD down 对稳态吞吐无可测量影响。** 瓶颈在 FUSE/JuiceFS（~233 IOPS），不在 Ceph OSD——5 个 OSD 足够支撑 FUSE 瓶颈吞吐，少 1 个不影响。

### DG-002：TiKV down 吞吐退化

| 项 | 值 |
|----|-----|
| 故障注入 | 停 1 TiKV |
| 关键断言 | 降级稳态吞吐 ≥ 基线 70% |
| 预估时长 | 5min |

**I/O 行为总结**：比较 3/3 TiKV up vs 2/3 TiKV down（Raft leader 切换后稳态）的吞吐差异。两轮相同时长 fio（randread，预创建文件避免元数据干扰），唯一变量是有无 TiKV down。

**实测结果**：基线 IOPS=164，降级 IOPS=181，比率=110%。**单 TiKV down 对稳态吞吐无可测量影响。** TiKV down 只影响 1/3 region，Raft 切换后其余正常。数据 I/O 走 Ceph 直连 RADOS，不经过 TiKV。

> **注意**：使用 `randrw`（含文件创建）时会出现 IOPS 下降（256→149，-42%），但这是 `--create_on_open=1` 在 TiKV down 时文件创建变慢导致，不是数据吞吐问题。改用 `randread`（预创建文件）后影响消失。

---

## 三、用例模板

```bash
#!/bin/bash
# FT-001: single-osd-down
# 停 1 OSD，I/O 全程运行，验证 fault 期间不中断 + recovery 期间延迟/吞吐量化
# EXPECTED_DURATION=480

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-001"
TEST_NAME="single-osd-down"
EXPECTED_DURATION=480

trap 'stop_io_load; start_osd "$TARGET_OSD" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" "描述..."
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    TARGET_OSD=$(pick_random_osd)
    capture_io_baseline
    start_io_load randread 256K 128
    sleep 30
}

inject() {
    stop_osd "$TARGET_OSD"
}

check_during() {
    sleep 5
    assert_pg_state_contains "degraded" 30 "PG 进入 degraded"
    # 不停止 I/O——让它跑过 recovery 阶段
}

recover() {
    start_osd "$TARGET_OSD"
    # 等待 recovery 完成
    local elapsed=0
    while [ "$elapsed" -lt 300 ]; do
        get_pg_states 2>/dev/null | grep -q "active+clean" && break
        sleep 5; elapsed=$((elapsed + 5))
    done
    stop_io_load
}

check_after() {
    assert_pg_state_contains "active+clean" 10 "PG active+clean"
    assert_eq "$(get_osd_count_up)" "6" "6/6 OSD up"
    assert_io_success_rate 100 "I/O 成功率 100%"
    assert_fio_lat_p99_lt "$((_IO_BASELINE_P99 * 3))" "P99 < 3×基线"
    assert_gt "$(get_io_bw)" "$((_IO_BASELINE_BW * 70 / 100))" "吞吐 ≥ 基线 70%"
}

teardown() {
    stop_io_load
    ensure_osd_up "$TARGET_OSD"
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
```

> 模板说明：
> - `EXPECTED_DURATION`：预估执行时长（秒），框架据此设定超时
> - `capture_io_baseline` + `start_io_load`：采集基线后启动 I/O，I/O 全程运行覆盖 fault + recovery
> - `check_during` 不停止 I/O，`recover` 中等待 recovery 完成后停止 I/O，`check_after` 断言全程 I/O 表现
> - `recover()` 必须幂等（即使故障未成功注入也不得有副作用）
> - 所有断言即使 FAIL 也继续执行（采集完整信息），`recover()` 始终执行
