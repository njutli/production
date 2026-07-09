# 任务（GLM）：node2 写慢根因取证 —— RAID 控制器缓存/BBU 直查 + 修复尝试 + 内存盘兜底

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-08
> 来源：`results/iops-wall-locate-20260708/` 定位到 **node2(.13) 是全局 IOPS 短板**（写路径特有）。
> 已坐实（opencode 逐层对账原始数据）：
> - **node2 的 osd.2/3 每写 op 延迟是 node1/3 的 5-8 倍**（perf delta：aio_wait node2 ~55ms vs node1 ~11ms vs node3 ~7ms；6 OSD 的 dcount 几乎相同=EC 均匀分片，node2 不是干得多、是每 op 就是慢）。
> - **node2 sdb 写延迟 ~73ms vs node3 ~5ms**（同一 diskstats 脚本、同一公式复算，15× 差距，非口径差）。
> - **三节点读速一致 ~400 MB/s**（物理盘健康）；**读快写慢 + 仅 node2 异常** = 典型 RAID 控制器 WriteBack 缓存未生效特征。
> - throttle 不是墙（0.014ms）、客户端网卡不是墙（44%）、WAL fsync 不是大头（kv_sync 2.9ms）——均已排除。
> **但"RAID 控制器 WriteBack/BBU 降级"是排除法推断，未直接取证**（上轮无 storcli/perccli）。本任务：**直查 RAID 卡状态坐实病因 → 若可修则修并复测 → storcli 不可用时用内存盘绕盘对照兜底。**

---

## 0. 硬件与工具（GLM 请先读）
- RAID 卡：**Dell PERC H730 Mini**（三台 ceph 节点相同）。Dell 对应工具是 **`perccli`/`perccli64`**（storcli 的 Dell 版），也可能是 `MegaCli`/`storcli64`。sdb = RAID 卡后挂的单盘 VD（物理是 SSD，Ceph 误判 hdd）。
- OSD 映射：node1(.11)=osd0,1 / node2(.13)=osd2,3 / **node2 是嫌疑节点** / node3(.14)=osd4,5。密码 .11=`TurboAi@303`，.13/.14=`123456`。
- **历史**：早前"全内存盘集群 +0.2% 无效"（`doc/perf-analysis/08` 记录）——但那是 node2 异常出现**之前**的全局测试；用户判断 node2 的 RAID 卡可能是**这段时间新降级**的，故内存盘"曾无效"不能否定"现在对 node2 有效"。本任务据此重新评估。

---

## 1. 铁律
1. **阶段 A（读取取证）只读、零风险，先做**；确诊后再评估阶段 B（有创修改）是否做。
2. 有创操作（改 RAID 缓存策略 / 迁 WAL 到内存盘）**全程 ops.log 落盘 + 明确回滚预案 + 逐步确认 HEALTH_OK / OSD up-in**。集群无业务数据可有创，但每步留痕。
3. 复测口径与上轮完全一致：`rados bench -p juicefs-data 300 write -b 256K -t 64`，SSD 基线参数（deferred=0/throttle=4000，当前已是），净态三确认（池清零 + compact queue_len=0 数字 + iostat idle + HEALTH_OK）。
4. perf/iostat 采集沿用上轮方法（admin socket t0/tend delta；节点本地前台采集），**复测要能和上轮 node2 vs node3 的 73ms/5ms 直接对比**。
5. 一切结论对账原始数据；无数据标"未取证"；不手填 summary。

---

## 2. 阶段 A（先做·只读取证）：直查三台 RAID 卡缓存策略 + BBU 状态

### 2.1 装工具（若未装）
Dell PERC H730 用 perccli。尝试顺序（哪个能用用哪个，落盘用的是哪个）：
```bash
# 优先 perccli（Dell）；退而求其次 storcli64 / MegaCli
which perccli perccli64 storcli64 storcli MegaCli MegaCli64 2>/dev/null
# 未装则尝试（Dilos/Ubuntu 上 perccli 通常需从 Dell 下载 deb；若离线，用 MegaCli/storcli 亦可读 LSI 芯片）
# 若都装不上：转阶段 A' 用 /sys 或 dmesg 尽量取证，再走阶段 C 内存盘兜底
```

### 2.2 三台各采（只读，全落盘）
```bash
CLI=<能用的工具名>
sudo $CLI /c0 show all                    > raidcli-<node>-controller.txt   # 控制器总览
sudo $CLI /c0/vall show all               > raidcli-<node>-vd.txt           # ★ 虚拟盘 Cache Policy (WB/WT, ReadAhead, Direct/Cached)
sudo $CLI /c0/eall/sall show all          > raidcli-<node>-pd.txt           # 物理盘（确认 SSD、健康、Media Error）
sudo $CLI /c0/bbu show all                > raidcli-<node>-bbu.txt          # ★ BBU/电容 状态、是否 degraded、是否触发 WT 回退
sudo $CLI /c0 show all | grep -i "cache\|bbu\|battery\|preserved" > raidcli-<node>-summary.txt
```

### 2.3 阶段 A 判据（核心对比 node2 vs node1/node3）
逐项对比三台，**重点看 node2 与 node1/node3 的差异**：
- **VD 的 Current Cache Policy**：node1/3 是否 `WriteBack`、node2 是否被降为 `WriteThrough`？（`Cache = WB` vs `WT`；注意 `Current` 而非 `Default`）
- **BBU/电容**：node2 的 Battery State 是否 `Degraded`/`Failed`/`Learn Cycle`，导致控制器自动 `WriteThrough`？
- **WriteCache when BBU bad 策略**：是否 `No Write Cache if Bad BBU`（默认安全策略，BBU 坏就回退 WT）。
- **物理盘**：三台 sdb 是否都是 SSD、无 Media/Predictive Error（排除盘本身坏）。
- **产出**：一张"三节点 RAID 状态对比表"，明确 **node2 到底哪一项与 node1/3 不同** → 坐实/推翻"RAID 缓存降级"。

> ⚠️ 若 node2 的 VD 缓存策略、BBU 都与 node1/3 **相同且正常**，则 RAID 假设被削弱——那 node2 写慢另有原因（如该 VD 的 stripe/其它设置、或 OSD 层问题），如实记录，转阶段 C 用内存盘绕盘定位是否在物理写路径。

---

## 3. 阶段 B（视 A 结果·有创·可选）：修复并复测

**仅当阶段 A 确诊 node2 是 `WriteThrough` 且原因可安全修复时执行。** 每步落盘 + 回滚预案。

### 情形 B1：BBU 正常但策略是 WriteThrough（可直接开 WB）
```bash
# 记录当前值 → 开 WriteBack
sudo $CLI /c0/v0 show all | grep -i cache          # 落盘改前
sudo $CLI /c0/v0 set wrcache=WB                     # 开 WriteBack
sudo $CLI /c0/v0 show all | grep -i cache          # 落盘改后
```
### 情形 B2：BBU degraded 导致自动 WT
- **不建议强开 `wrcache=FWB`（Force WriteBack，无电池保护，掉电丢数据）** 作为长期方案；但本集群无业务数据，**可临时 FWB 仅用于验证"开 WB 后 IOPS 是否恢复"**，验证完立即回滚。落盘标注"仅验证、非生产建议"。
```bash
sudo $CLI /c0/v0 set wrcache=ForcedWB               # 仅验证用，无 BBU 保护
```
### B 复测（与上轮同口径）
- 净态三确认 → `rados bench 300 write -b 256K -t 64` → 同步采 node2 perf delta + node2/3 iostat。
- **判据**：node2 写延迟是否从 ~73ms 降到 ~5ms（对齐 node3）；全局 IOPS 是否从 ~230 显著上升；稳态写 MB/s 是否过 59。
- **回滚**：验证完把 node2 缓存策略改回原值（若原为 WT）；确认 HEALTH_OK。

---

## 4. 阶段 C（兜底·视需要）：内存盘绕盘对照

**触发条件**：阶段 A 装不上任何 RAID 工具 / 读不出关键状态，或 A 显示 node2 RAID 状态与 node1/3 无异（需另证墙是否在物理写路径）。

- **做法**：把 **node2 的 osd.2 与 osd.3** 的 WAL+DB（必要时含 data）迁到 node2 本地 **tmpfs/ramdisk**（node2 有充足内存），绕开 RAID 卡/物理盘。
  - deepseek exp4 曾卡在容器路径（`ceph-bluestore-tool` 在 cephadm shell 内找不到 osd block）——用 `cephadm shell --name osd.X` 挂设备，或 `ceph-volume`，**详录每步命令与返回码**。
  - **只动 node2 两个 OSD**（对照实验，node1/3 不动），逐个做完确认 up/in + HEALTH_OK。
- **复测同口径**，判据：node2 写延迟是否从 73ms 骤降、全局 IOPS 是否大涨。
  - 若是 → **反证墙就在 node2 的物理写路径（RAID 卡/盘）**，与"RAID 缓存降级"假设一致（用户怀疑成立，且解释"上次全内存盘无效"是因当时 node2 未坏）。
  - 若否 → 墙不在 node2 物理盘，另有原因（OSD 软件/节点级），如实记录。
- **口径提醒**：内存盘远快于任何 SSD/RAID，只能**定性**证明"绕开 node2 物理写路径后是否变快"，不能定量预测修好 RAID 后的确切值。
- **回滚**：把 node2 两 OSD 的 WAL/DB 迁回 sdb，确认 6 OSD up/in、HEALTH_OK、池数据完整。

---

## 5. 回报 opencode（最终一条消息）
1. **阶段 A（核心）**：三节点 RAID 状态对比表 —— node2 的 VD Cache Policy / BBU 到底与 node1/3 差在哪？**坐实还是推翻"RAID WriteBack 缓存降级"**。用的什么工具（perccli/storcli/MegaCli）。
2. **阶段 B（若做）**：开 WriteBack 后 node2 写延迟、全局 IOPS、稳态写 MB/s 的变化 → **是否解决 230 IOPS 墙、能否过 59**。是否已回滚。
3. **阶段 C（若做）**：内存盘绕盘后 node2 是否骤快 → 墙是否在物理写路径。
4. **总判决**：node2 写慢的确切病因（RAID 缓存策略 / BBU / 盘 / OSD 软件），及**是否可修复、修复后能否达标 59**。
5. 异常（工具装不上、config/内存盘未回滚、复测退化态）如实列。

## 6. 明确不做
- ❌ 阶段 A 未确诊前不动任何 RAID 设置（先只读）。
- ❌ 不把 ForcedWB 作为生产长期建议（仅验证，验完回滚）。
- ❌ 不动 node1/node3（本任务聚焦 node2 短板）。
- ❌ 改 RAID/迁内存盘后不回滚（务必回滚 + 确认 HEALTH_OK + 数据完整）。
- ❌ 无数据支撑写进结论；不手填。

## 7. 产出目录
`results/node2-raid-forensics-20260709/`：
```
├── ops.log                              # 全程 + 每步改动/回滚
├── raidcli-{node1,node2,node3}-{controller,vd,pd,bbu,summary}.txt   # 阶段A 只读取证
├── raid-compare.md                      # 三节点 RAID 状态对比表 + 差异定位
├── [B] retest-after-wb/                 # 若修：净态确认 + rados 逐秒 + node2/3 iostat + node2 perf delta
├── [C] memdisk-bypass/                  # 若兜底：迁移记录 + 复测 + node2 perf/iostat delta
└── report.md                            # 三阶段结论 + 总判决（病因/可修否/达标否）
```
