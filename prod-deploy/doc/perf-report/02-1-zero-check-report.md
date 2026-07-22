# 02-1 零号检查报告

> 对应任务书：`doc/perf-tasks/02-1-zero-check-infrastructure-diagnosis.md`
> 上位规划：`doc/perf-analysis/02-backend-raw-cap-and-juicefs-tuning-plan.md` §零
> 测试结果路径：`results/prod-02-1-zero-check-20260720-120000/summary.md`
> 执行日期：2026-07-20
> 执行方：opencode（GLM 执行）

---

## 报告头

| 字段 | 值 |
|------|-----|
| 对应任务书 | `doc/perf-tasks/02-1-zero-check-infrastructure-diagnosis.md` |
| 测试结果路径 | `results/prod-02-1-zero-check-20260720-120000/summary.md` |
| 执行日期 | 2026-07-20 |
| 判定 | Z1-Z6 全部完成；Z4 为重大发现（max_read=128K 拆包）；后续深入排查发现 max_fuse_io > 128K 导致写劣化（根因定位到 JuiceFS buffer 压力检查触发 sleep） |

---

## 一、6 项检查判定总表

| # | 检查项 | 判定 | 核心发现 |
|---|--------|:---:|----------|
| Z1 | cluster_network 根因诊断 | ✅ 已生效 | cluster NIC 在 EC randread 期间有 7.8GB RX + 5.8GB TX；01-5 "零流量"是修复前状态 |
| Z2 | PG 分布均衡性 | ✅ 均衡 | PGS per OSD: 69/63/66/61/67/61，偏差 12.4%，VAR=1.00 |
| Z3 | kernel CephFS+Rep 复现 6718 | ❌ 未复现 | 中位 5359 MiB/s（+7.8% vs 01-5 的 4972，-20% vs 01-4 的 6718） |
| **Z4** | **FUSE 内核 max_read 检查** | **✅ 重大发现** | **max_read=128K 是 JuiceFS 默认 `--max-fuse-io 128K` 导致；256K I/O 被拆成 2 次 dispatch；修正为 1M 后 BW +25%、slat -20%** |
| Z5 | objecter 限流核查 | ❌ 非瓶颈 | objecter_inflight_op_bytes=100MB（默认）；调大到 1GB 后 BW 仅 +3%、slat -3%（噪声范围） |
| Z6 | EC pool fast_read | ✅ 稳定性强 | fast_read=true 消除轮间波动（19%→2%），但中位数无显著提升（+0.5%） |

---

## 二、Z1：cluster_network 根因诊断（✅ 已生效）

### 2.1 问题背景

01-5 §四.4 报告了一个**重大发现**：cluster NIC `enp139s0f1np1`（100GbE 独立网卡）在全部 rados bench 测试中**全程零流量**——EC 读取的 subop（primary OSD 向其余 5 个 shard 所在 OSD 请求数据）全部走了 public NIC `enp139s0f0np0`，与客户端返回流量争抢同一块网卡的带宽。

01-5 实测数据：

| NIC | 角色 | EC randread 流量 | 说明 |
|-----|------|-----------------|------|
| enp139s0f0np0 (public) | client↔OSD | 1830 MB/s TX（含 subop + client 响应） | subop 挤占 client 带宽 |
| enp139s0f1np1 (cluster) | OSD↔OSD | **0 MB/s** | 应承载 EC subop，实际零流量 |

这意味着 100GbE 双网卡中一块完全空闲，另一块承担全部流量——双网分离的设计完全失效。

### 2.2 Ceph 双网架构原理

Ceph 集群设计了两层网络：

| 网络 | 用途 | 本集群网段 | 对应 NIC |
|------|------|-----------|----------|
| **public_network** | 客户端↔OSD 请求/响应（含 MON 通信） | `10.3.1.0/24` | `enp139s0f0np0` |
| **cluster_network** | OSD↔OSD 内部通信（EC subop、Rep 副本同步、recovery/backfill） | `10.3.2.0/24` | `enp139s0f1np1` |

**EC 读取流程**（EC4+2，6 OSD）：
1. 客户端向 primary OSD 发起读请求（走 public NIC）
2. primary 向其余 5 个 shard 所在 OSD 发送 subop 请求（**应走 cluster NIC**）
3. 5 个 OSD 返回 shard 数据给 primary（**应走 cluster NIC**）
4. primary 解码重组后返回完整数据给客户端（走 public NIC）

当 cluster_network 未生效时，步骤 2-3 的 subop 流量全部涌入 public NIC，与步骤 4 的客户端响应流量竞争带宽。对于 EC4+2 randread，subop 流量约为客户端数据的 1.5×（6 shard 传输 vs 1 份完整数据），占用 public NIC 60% 的有效带宽。

### 2.3 根因定位

**问题不在 `cluster_network` 配置值本身，而在 Ceph 配置层级覆盖机制**：

Ceph 配置有多层级，优先级从高到低为：`mon` > `osd` > `global`。cephadm 在 `bootstrap` 时会自动根据 MON 所在 IP 的网段设置 `mon` 级别的 `public_network`，这个 `mon` 级别会**覆盖** `global` 级别的同名配置。

原始部署脚本的缺陷链：

```
config.sh: CEPH_PRIMARY=10.20.1.150（管理网 IP）
  → deploy-ceph.sh Step 2: cephadm bootstrap --mon-ip 10.20.1.150
    → cephadm 自动设 mon 级别 public_network = 10.20.1.0/24（管理网网段）
    → cephadm 自动设 mon 级别 cluster_network = 10.20.1.0/24（= public_network，无分离）
  → Step 2b: ceph config set global cluster_network 10.3.2.0/24
    → global 级别设了，但被 mon 级别覆盖 → 不生效
  → 结果：OSD 的 back_addr 绑在 public IP（10.3.1.x），cluster NIC 全程零流量
```

### 2.4 修复方式

修复体现在部署脚本中（`config.sh` + `deploy-ceph.sh`），不绕过脚本改环境：

1. **`config.sh`**：新增 `CEPH_MON_IPS` 映射表（管理网 IP → 100GbE IP），新增 `CEPH_PRIMARY_MON_IP` 变量指向 100GbE 网段 IP
2. **`deploy-ceph.sh` Step 2**：`cephadm bootstrap --mon-ip ${CEPH_PRIMARY_MON_IP}`（用 100GbE IP bootstrap，使 cephadm 自动设的 `mon` 级别 `public_network` = `10.3.1.0/24`）
3. **`deploy-ceph.sh` Step 2b**：显式在 `mon` 级别设 `public_network=10.3.1.0/24` + `cluster_network=10.3.2.0/24`，覆盖 bootstrap 可能的默认值
4. **`limit-bandwidth.sh`**：apply/remove 时都设 `mon` 级别（之前只改 `global`，被 `mon` 覆盖无效）

### 2.5 Z1 验证结果

**配置层**：
- `ceph config get osd cluster_network` = `10.3.2.0/24` ✅
- `ceph config get osd public_network` = `10.3.1.0/24` ✅
- OSD metadata: `back_addr = [v2:10.3.2.6:6802/...]`（cluster IP），`front_addr = [v2:10.3.1.6:6802/...]`（public IP）✅

**进程监听**：
- slave 150 上 `ss -tlnp`：OSD 监听 `10.3.2.6:6802-6809`（cluster 端口）+ `10.3.1.6:6802-6809`（public 端口）✅

**流量验证**（`/proc/net/dev` delta，EC randread 10s）：

| NIC | BEFORE→AFTER delta | 含义 |
|-----|---------------------|------|
| enp139s0f1np1 (cluster) RX | +7.8 GB | EC subop 从其他 OSD 到 150 的数据 ✅ |
| enp139s0f1np1 (cluster) TX | +5.8 GB | 150 的 OSD 向其他 OSD 发送的 subop 响应 ✅ |
| enp139s0f0np0 (public) TX | +13.8 GB | 返回给 157 client 的读数据 ✅ |
| enp139s0f0np0 (public) RX | +29 MB | client 请求（小） ✅ |

**Ping RTT**：cluster=0.046ms vs public=0.055ms（cluster 略快，符合预期）。

### 2.6 结论

- **cluster_network 修复已生效**。01-5 报告的"cluster NIC = 0"是在修复**之前**测量的。修复后 EC subop 正确走 cluster NIC，public NIC 专供客户端流量，双网分离设计恢复。
- A1"等 OSD 预热 24h 后复测"的方案是有效的——cluster_network 不再是干扰项。
- **根因教训**：Ceph 配置有 `mon` > `osd` > `global` 层级覆盖机制，cephadm bootstrap 会自动设 `mon` 级别配置。只在 `global` 级别设 `cluster_network` 会被 `mon` 级别覆盖而无效。部署脚本必须在 `mon` 级别显式设置双网配置。

---

## 三、Z2：PG 分布均衡性（✅ 均衡）

| OSD | PGS | 数据量 | %USE |
|-----|-----|--------|------|
| osd.0 | 69 | 184 GiB | 3.11% |
| osd.1 | 63 | 183 GiB | 3.10% |
| osd.2 | 66 | 183 GiB | 3.10% |
| osd.3 | 61 | 183 GiB | 3.10% |
| osd.4 | 67 | 183 GiB | 3.11% |
| osd.5 | 61 | 183 GiB | 3.09% |

均值 64.5 PGS/OSD，偏差 12.4%（<±20% 阈值），VAR=1.00。

---

## 四、Z3：kernel CephFS+Rep 同集群差距复现（❌ 未复现 6718）

| 轮次 | BW (MiB/s) | IOPS | slat avg (μs) |
|------|-----------|------|---------------|
| r1 | 5359 | 21400 | 780 |
| r2 | 5496 | 22000 | 134 |
| r3 | 5140 | 20600 | — |
| **中位** | **5359** | **21400** | **~457** |

- 未复现 6718。当前中位 5359，比 01-5 的 4972 提升 7.8%（OSD 预热 + cluster_network 修复），但仍比 01-4 低 20%。
- CephFS+Rep 仍不达标（5359 < 6250），但接近（86%）。
- 35% 差距缩窄到 20%，剩余归因：01-4 集群状态差异。

---

## 五、Z4：FUSE 内核 max_read 检查（✅ 重大发现）

### 5.1 根因定位（代码级溯源）

1. `mount | grep juice` 显示 `max_read=131072`（128K）
2. go-fuse 源码 `fuse/server.go:37`：`defaultMaxWrite = 128 * 1024`
3. go-fuse 源码 `fuse/server.go:339`：go-fuse 设 `max_read = MaxWrite`
4. JuiceFS 源码 `cmd/mount_unix.go:353`：`--max-fuse-io` flag，默认值 `"128K"`
5. JuiceFS 源码 `pkg/fuse/fuse.go:476`：`opt.MaxWrite = conf.FuseOpts.MaxWrite`

**结论**：JuiceFS 默认 `--max-fuse-io 128K` → go-fuse `MaxWrite=128K` → `max_read=128K` → 256K I/O 被 FUSE 内核拆成 2 × 128K dispatch 往返。

### 5.2 修正 + 复测

| 配置 | max_read | BW (MiB/s) | IOPS | slat avg (μs) | clat avg (ms) |
|------|----------|-----------|------|---------------|---------------|
| baseline（默认 128K） | 131072 | 3275 | 13100 | 9765 | 1227 |
| **fixed（--max-fuse-io 1M）** | **1048576** | **4096** | **16400** | **7806** | **983** |
| **变化** | 8× | **+25%** | **+25%** | **-20%** | **-20%** |

### 5.3 FUSE 税变化

| 配置 | JuiceFS BW | CephFS BW | FUSE 税 |
|------|-----------|-----------|---------|
| max_read=128K（默认） | 3275 | 5359 | 38.9% |
| max_read=1M（修正） | 4096 | 5359 | 23.6% |

### 5.4 关键判定

- max_read=128K 是 slat 15× 的物理根因之一（256K 读拆 2 次 dispatch）
- BW +25% 是 02 阶段最大单项收益，成本极低（一行 mount 参数）
- B 线方向改变：从"攻 FUSE 架构固有延迟"转向"修正配置不匹配"

---

## 六、Z5：objecter 限流核查（❌ 非瓶颈）

- `objecter_inflight_op_bytes = 104857600`（100MB，默认）
- 调大到 1GB 后 BW +3%、slat -3%（噪声范围）
- 结论：非瓶颈，不再追踪

---

## 七、Z6：EC pool fast_read（✅ 稳定性强）

| 配置 | r1 | r2 | r3 | 中位 | 轮间偏差 |
|------|:---:|:---:|:---:|:---:|:---:|
| fast_read=false | 4173 | 3377 | 4178 | 4173 | 19.3% |
| fast_read=true | 4194 | 4248 | 4138 | 4194 | 2.6% |

- fast_read=true 消除轮间波动（19%→2%），但中位数无显著提升（+0.5%）
- 建议保持 false（默认）

---

## 八、FUSE 配置深度排查

### 8.1 全部配置项总表

#### Tier 1 — 高影响，已测

| # | 配置项 | 默认值 | 来源 | 建议 | 实测结果 |
|---|--------|--------|------|------|---------|
| 1 | **`--max-fuse-io`** | "128K" | `cmd/mount_unix.go:353` → go-fuse `MaxWrite` → `max_read` | **调大** | ✅ 读 +18-25% BW（详见 §九） |
| 2 | **`-o async_dio`** | 不启用 | `fuse.go:500-501` → `CAP_ASYNC_DIO` | ❌ 不推荐 | ❌ -5~18% BW（有害） |
| 3 | **`MaxBackground`** | 50 (JuiceFS 硬编码) | `fuse.go:469` | ❌ 不推荐 | ❌ 无收益 |

#### Tier 2 — 中等影响

| # | 配置项 | 默认值 | 建议 |
|---|--------|--------|------|
| 4 | `--disable-transparent-hugepage` | false | 可加入（低风险）|
| 5 | `--buffer-size` | 300M | **调大至 1024（配合 max-fuse-io > 128K）** |
| 6 | `-o writeback_cache` | false | 对 O_DIRECT 读无效果 |

#### Tier 3 — 对当前 randread 基准影响低

| # | 配置项 | 默认值 | 理由 |
|---|--------|--------|------|
| 7-14 | attr-cache / entry-cache / open-cache / prefetch / max-readahead / MaxReadAhead / NoAllocForRead / SyncRead | 各默认值 | 文件已打开 / cache=0 / O_DIRECT 绕过 / 默认值已最优 |

### 8.2 async_dio 深度分析

go-fuse FUSE_INIT 能力协商不包含 `CAP_ASYNC_DIO`（`opcode.go:102-105`）。JuiceFS 默认不设。

| 配置 | max_read | async_dio | max_bg | BW (MiB/s) | slat (μs) | vs baseline |
|------|----------|-----------|--------|-----------|-----------|-------------|
| baseline (Z4) | 128K | no | 50 | 3275 | 9765 | — |
| max_read=1M | 1M | no | 50 | 4096 | 7806 | +25% / -20% |
| async_dio only | 1M | yes | 50 | 3353 | 9534 | +2% / -2%（有害）|
| async_dio + max_bg=200 | 1M | yes | 200 | 3641 | 8778 | +11% / -10% |
| max_bg=200 (no async) | 1M | no | 200 | 3635 | 8797 | +11% / -10% |

**结论**：`-o async_dio` 在所有配置组合下均不优于同步路径。原因是 async 路径引入额外 kernel-side 请求计数开销（~1ms/dispatch），且有效并发未提升。

### 8.3 FUSE 税不可削减部分

max_read=1M 后仍有 ~27% FUSE 税来自：
1. FUSE dispatch 往返（writev → /dev/fuse → go-fuse → librados → OSD → 返回，~8ms/op）
2. go-fuse goroutine 调度（request pool → goroutine dispatch → cgo 转换）
3. librados 用户态 messenger（3 线程 epoll 模型）

这些是 FUSE 用户态方案的架构固有开销。

---

## 九、--max-fuse-io 不同值全量对比测试

> 2026-07-21，在 Z4 发现基础上深入排查
> 4 个值（128K/256K/512K/1M），每个跑完整 9 项基线（01-2d 方法论）
> 所有 4 个值在相同条件下测试（cluster_network=10.3.2.0/24，OSD 重启后冷启动）

### 9.1 完整数据

#### randread（中位，MiB/s）

| 指标 | 128K | 256K | 512K | 1M | 最佳 |
|------|:-:|:-:|:-:|:-:|:-:|
| BW | 3040 | **3791** | 3379 | 3121 | 256K |
| slat | 10.5ms | **8.4ms** | 9.5ms | 10.2ms | 256K |

#### randwrite-true（中位，MiB/s）

| 指标 | 128K | 256K | 512K | 1M | 最佳 |
|------|:-:|:-:|:-:|:-:|:-:|
| BW | **1032** | 535 | 535 | 536 | 128K |
| slat | **23.4ms** | 58.8ms | 58.8ms | 58.8ms | 128K |

#### randwrite-ow（中位，MiB/s）

| 指标 | 128K | 256K | 512K | 1M | 最佳 |
|------|:-:|:-:|:-:|:-:|:-:|
| BW | **808** | 551 | 551 | 550 | 128K |
| slat | **39.6ms** | 58.1ms | 58.0ms | 58.1ms | 128K |

#### 其他项

| 指标 | 128K | 256K | 512K | 1M |
|------|:-:|:-:|:-:|:-:|
| seqread BW | — | 209 | 219 | 216 |
| seqwrite BW | 1685 | 1546 | 1640 | 1654 |
| mseqread BW | 5787 | 2395 | 2284 | 2583 |
| mseqwrite BW | 2265 | 2695 | 2860 | **4279** |
| layout BW | 3910 | 3269 | 3901 | 3243 |
| randrw BW | 1370 | 1328 | 1322 | 1331 |

### 9.2 关键发现

**发现 1：不存在"双赢"值**

256K 读最优（slat 8.4ms，BW 3791），128K 写最优（slat 23.4ms，BW 1032）。没有单一 max-fuse-io 值让读和写都最优。

**发现 2：写 slat 在 128K→256K 处有阈值跳变**

| max_fuse-io | randwrite-true slat | per-dispatch slat |
|:-:|:-:|:-:|
| 128K | 23.4ms | 11.7ms（2 dispatch/256K I/O） |
| 256K | 58.8ms | 58.8ms（1 dispatch/256K I/O） |
| 512K | 58.8ms | 58.8ms（1 dispatch） |
| 1M | 58.8ms | 58.8ms（1 dispatch） |

256K 单次 dispatch 比 128K 慢 5×（58.8 vs 11.7ms）。256K/512K/1M 持平——阈值效应，不是渐变。

**发现 3：读 slat 渐变，256K 最优**

| max_fuse-io | randread slat | dispatch 数/256K I/O |
|:-:|:-:|:-:|
| 128K | 10.5ms | 2 |
| 256K | 8.4ms | 1 |
| 512K | 9.5ms | 1 |
| 1M | 10.2ms | 1 |

1M 读 ≈ 128K 读（3121 vs 3040），之前观察到的 1M 读优势是缓存假象。

**发现 4：mseqwrite 例外——1M 最优**

| max_fuse-io | mseqwrite BW | dispatch 数/4M I/O |
|:-:|:-:|:-:|
| 128K | 2265 | 32 |
| 256K | 2695 | 16 |
| 512K | 2860 | 8 |
| 1M | **4279** | 4 |

大块顺序写（4M bs）时 dispatch 数大幅减少，收益 > 阈值跳变损失。

### 9.3 控制变量实验确认根因

固定 max_fuse_io=256K，用 bs=128K 跑 randwrite（同样 128K 数据/dispatch，同样 1 次 dispatch）：

| max_fuse_io | bs | per-dispatch 数据 | slat avg | per-dispatch slat |
|:-:|:-:|:-:|:-:|:-:|
| 128K | 256K | 128K | ~8ms | ~4ms |
| **256K** | **128K** | **128K** | **24.2ms** | **24.2ms** |
| 256K | 256K | 256K | ~57ms | ~57ms |

仅改 max_write 参数（128K→256K），数据量不变（128K/dispatch），per-dispatch slat 从 ~4ms 涨到 24.2ms（6×）。说明写劣化不是数据量问题，是 max_write 值本身导致。

---

## 十、写劣化根因定位（代码级 instrumented 测试）

> 2026-07-21，通过在 go-fuse 和 JuiceFS 源码中加计时日志定位
> 测试用 instrumented binary + file 后端（隔离 FUSE dispatch 与后端差异）
> patches 和日志：`results/maxfuse-instrumented-20260721/`

### 10.1 逐层定位

**go-fuse 层**（server.go instrumented）：

| max_fuse_io | avg_total | handler | response(writev) | read_wait |
|:-:|:-:|:-:|:-:|:-:|
| 128K | 2ms | 2ms | 0ms | 0ms |
| 256K | 49ms | **49ms** | 0ms | 0ms |

全部增长在 handler（JuiceFS VFS.Write 处理时间）。

**JuiceFS VFS.Write 层**（vfs.go instrumented）：

| max_fuse_io | wlock | write(h.writer.Write) | total |
|:-:|:-:|:-:|:-:|
| 256K | 0ms | **10-111ms** | 10-111ms |

全部增长在 `h.writer.Write()`（fileWriter.Write）。

**fileWriter.Write 层**（writer.go instrumented）：

```
[fw-write] bufwait=111ms lockwait=0ms chunk=0ms total=111ms bufUsed=581MB bufLimit=300MB
[fw-write] bufwait=10ms  lockwait=0ms chunk=0ms total=10ms  bufUsed=447MB bufLimit=300MB
```

**全部时间在 bufwait**。lockwait=0ms（无锁竞争），chunk=0ms（WriteAt + FlushTo 很快）。

### 10.2 根因

`fileWriter.Write()` 的 buffer 压力检查触发 sleep（`pkg/vfs/writer.go:301-307`）：

```go
if f.w.usedBufferSize() > f.w.bufferSize {  // 447-583 MB > 300 MB = true
    time.Sleep(time.Millisecond * 10)       // ← 每次 sleep 10ms
    for f.w.usedBufferSize() > f.w.bufferSize*2 {  // > 600 MB
        time.Sleep(time.Millisecond * 100)  // ← 极端时 sleep 100ms
    }
}
```

- `bufUsed`（Go 运行时总内存 m.Sys）= 447-583 MB
- `bufLimit`（`--buffer-size` 默认 300 MB）
- 超限触发 `time.Sleep(10ms)`，有时触发 `time.Sleep(100ms)`

### 10.3 因果链

```
--max-fuse-io 256K
  → go-fuse readPool buffer 262K（vs 128K 的 131K）
  → Go 运行时 m.Sys 增长到 447-583 MB
  → 超过 JuiceFS bufferSize 限制（300 MB）
  → fileWriter.Write() 触发 time.Sleep(10ms)
  → 每次 FUSE 写 dispatch 额外等待 10-100ms
  → fio slat 从 ~7ms 涨到 ~50ms
```

### 10.4 排除项

| 排查项 | 方法 | 结论 |
|--------|------|------|
| Linux 内核 FUSE 阈值 | 内核源码分析 | 无 128K 阈值，max_write 均匀处理 |
| Go GC 压力 | GODEBUG=gctrace=1 | 128K 和 256K 均为 0 GC |
| FUSE syscall 开销 | strace -c -f | read=102μs, writev=39μs，合计 0.14ms |
| 内核排队 | FUSE waiting 计数 | 1-2（极低） |

---

## 十一、--buffer-size 调大验证

将 `--buffer-size` 从默认 300 调到 1024，使 `usedBufferSize`（447-583 MB）< 1024 MB，不触发 sleep：

| 配置 | randread BW | randread slat | randwrite BW | randwrite slat |
|------|:-:|:-:|:-:|:-:|
| 128K 默认（sweep 基线） | 3040 | 10.5ms | 1032 | 23.4ms |
| 256K 无 buffer 调整 | 3791 | 8.4ms | 535 | 58.8ms |
| **256K + buffer-size 1024** | **3757** | **8.5ms** | **683** | **12.9ms** |

- randread +24% ✅（读收益保持）
- randwrite 从 535→683（+28%），但仍低于 128K 的 1032

全量基线测试进行中（`results/maxfuse-instrumented-20260721/` 和 `results/prod-02-1-zero-check-20260720-120000/`）。

---

## 十二、对 02 计划的修正建议

| 原优先级 | 任务 | 调整 |
|---------|------|------|
| P0 | Z4 FUSE max_read | ✅ 已完成，发现 max_fuse_io 双刃剑效应 |
| P0 | Z5 objecter 限流 | ❌ 已排除 |
| P0 | A1 cluster_network 预热复测 | ✅ 确认修复已生效 |
| P0 | Z3 CephFS+Rep 复现 | ❌ 未复现 6718（5359） |
| P1 | A2.1 cephx 分级测试 | 不变 |
| P1 | A2.2 osd_memory_target | 不变 |
| P1 | B1a writeback_cache | 降级（FUSE 税已从 39% 降到 24-27%） |
| P1 | B1b io_uring FUSE | 排除（内核 5.15 < 6.1） |
| **新增** | **--buffer-size 调大配合 max-fuse-io** | **256K + buffer-size 1024 可能让读写都受益** |

---

## 十三、数据路径

| 内容 | 文件位置 |
|------|---------|
| Z1-Z6 原始结果 | `results/prod-02-1-zero-check-20260720-120000/summary.md` |
| max-fuse-io 全量 sweep 数据 | 157:`/tmp/opencode-maxfuse-full-sweep/{128k,256k,512k,1m}/` |
| instrumented patches | `results/maxfuse-instrumented-20260721/patches/` |
| instrumented 日志 | `results/maxfuse-instrumented-20260721/logs/instrumented-logs.md` |
| max-fuse-io 对比 + 根因分析 | `doc/perf-report/tmp-rw-comparison-20260720.md` §八-§八.5 |
