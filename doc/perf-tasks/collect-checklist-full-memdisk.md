# 采集补充清单（GLM）：全内存盘（DATA+WAL/DB 全内存）全量测试 —— 必采证据

> 出题：opencode（规划/校验）　日期：2026-07-09
> 适用：本轮"全内存盘（DATA 也迁 tmpfs）全量冷态基线 + 全量后端裸能力"测试。
> 目的：把上轮缺的关键证据一次补齐，使这两个方向能**直接落判、不返工**：
> - **方向 1**：若顺序写后端裸能力能打满网卡、而 JuiceFS 有效带宽 <59 → 看 JuiceFS 时客户端网卡满没满（没满=JuiceFS 自身瓶颈；满了=JuiceFS 写放大来源）。
> - **方向 2**：若顺序写后端裸能力打不满网卡 → 定位是客户端网卡 / OSD CPU / EC 协调 / 网络栈。
>
> ⚠️ 本清单是**采集要求**，不改测试项目本身；正常测什么照测，只是**每一项都同步把下面几样采上**。

---

## 0. 为什么补这些（上轮的缺口）
上轮 `node2-raid-fix-memdisk-ceiling`：① **客户端网卡 sar 列解析失败，TX 只能"从带宽推算 47%"——没实测**；② 未采 OSD CPU；③ 是纯 rados，无 JuiceFS 侧证据。**这三样正是两个方向落判的依据，且事后补不了（要重测），必须本轮钉进去。**

---

## 1. 【公共关键刀】客户端 eno1 网卡 TX —— rados 与 JuiceFS 两处都要，且必须实测成功

这是两个方向共同的、决定性的一刀。上轮 sar 解析失败，本轮**换稳妥方法 + 现场自检**：

### 1.1 采集方法（三选一，选能出数的，落盘用的是哪个）
```bash
# 方法A（推荐，直接算差值，不依赖列解析）：读 /proc/net/dev 的 eno1 TX 字节，每秒差分
NIC=eno1
( prev=0; while true; do
    now=$(awk -v n="$NIC" '$1 ~ n":" {gsub(/.*:/,"",$1); print $10}' /proc/net/dev)  # 第10列=tx bytes（注意含冒号列偏移，见1.2自检）
    echo "$(date +%s) tx_bytes=$now"
    sleep 1
  done ) > client-nic-<项目名>.txt
# 方法B：sar -n DEV 1 <秒数>（若装了 sysstat），但必须按 1.2 自检确认 eno1 行/txkB 列取对
# 方法C：ifstat -i eno1 -b 1（若装了 ifstat），输出 Kbps
```

### 1.2 采集前现场自检（关键，避免又解析失败）
开测前先手动跑 2 行确认能取到 eno1 的 TX 且是递增字节数：
```bash
grep eno1 /proc/net/dev   # 确认 eno1 存在，记下 TX bytes 是第几列（RX 8 列在前，TX 从第 9 或 10 列起）
```
**报告里必须给出"稳态 TX = X MB/s = 118 的 Y%"的实测值**（用字节差分/时间，不再"从带宽推算"）。

### 1.3 采集时机
- **每个 rados write 项**（256K/各块大小/并发扫描）运行期采。
- **每个 JuiceFS 写项**（seqwrite / multi-seqwrite）运行期采 —— **方向1 全靠这个**。

---

## 2. 【方向 1 专用】JuiceFS 侧证据 —— 有效写 vs 客户端 TX vs object put 字节

JuiceFS 全量测试时，每个写项同步采：

### 2.1 juicefs stats 分段
```bash
juicefs stats <挂载点> -l 1 --interval 1 --count <runtime+5> > jfs-stats-<项>.txt
```
关注并报告：fuse write 带宽、object put 并发/带宽、staging/buffer、meta ops。

### 2.2 写放大直接量化（方向1 的 A/B 分支判据）
一个写项测完，算三个字节数并给比值：
- **fio 有效写字节**（fio 报告的 io=xxx）
- **客户端 eno1 TX 字节**（§1 差分累计）
- **写到池的 object put 字节**（`juicefs stats` 的 object put 累计，或测前后 `rados df` 的 `juicefs-data` WR 差值）

**判据**：
- 客户端 TX ≈ fio 有效写 → **JuiceFS 客户端侧无放大**；若此时有效带宽仍 <59 且 TX 未打满 → **瓶颈在 JuiceFS 自身**（FUSE 单线程/mu 上传并发/buffer flush），看 §2.1 哪段瓶颈 + §3 juicefs 进程 CPU。
- 客户端 TX 明显 > fio 有效写 → **JuiceFS 有客户端侧写放大**，量化倍数，并从 object put 字节/对象大小分布找放大来源（RMW 补齐整块？重复上传？meta/小对象额外流量？）。
- 客户端 TX 打满 118 → 网卡是墙，放大倍数 = TX/有效写。

### 2.3 juicefs 进程资源
```bash
pidstat -p <juicefs_pid> 1 <runtime>  > jfs-proc-<项>.txt   # 或 top -b -p <pid>
```
看 JuiceFS 进程是否单核打满（FUSE/上传线程瓶颈）。

---

## 3. 【方向 2 专用】OSD CPU + perf 分段 —— 定位后端打不满网卡时卡在哪

rados 顺序写（尤其若稳态打不满网卡）运行期，3 台 ceph 节点采：

### 3.1 OSD 进程 CPU
```bash
mpstat -P ALL 1 <runtime> > cpu-<node>.txt          # 看是否有单核 100%
top -b -d1 -n <runtime> | grep -E "ceph-osd" > osd-cpu-<node>.txt
```
### 3.2 OSD perf 分段（沿用已验证方法，t0/tend delta）
6 OSD 各 t0/tend，重点段：`op_w_latency` 总、`subop_w_latency`（EC 协调）、`state_aio_wait_lat`（DATA 写，全内存后应很小）、`txc_throttle_lat`、messenger 的 `msgr_*_lat`。

### 3.3 方向2 判据（全内存已排除磁盘）
- 客户端 TX 没满 + 某 OSD 单核 CPU 100% → **OSD CPU/EC 编码 瓶颈**。
- 客户端 TX 没满 + `subop_w_latency` 大头 → **EC PG 协调串行**。
- 客户端 TX 没满 + CPU 不满 + perf 各段都小 → 网络栈/messenger。
- 客户端 TX 打满 118 → 网卡就是墙，后端已够（方向2 不成立，回到方向1）。

---

## 4. 全内存盘配置与口径提醒
- **DATA + WAL/DB 全部 tmpfs**：本轮目的就是彻底排除物理盘/RAID（node2 WriteThrough）影响，看软件真实上限。回滚风险大，务必用 `bluefs-bdev-migrate` 正确流程或直接 purge 重建（无业务数据），全程 ops.log。
- **口径**：内存盘=上限评估，非交付基线，报告显式标注。
- **稳态铁律**：一切结论用稳态段中位数（截前 30s），**不用含缓冲暂态的 bench mean**（上轮 bench mean 59.5 就是暂态假象，稳态仍 55）。
- **DATA 也进内存后的核心预期问题**：`state_aio_wait_lat`（DATA 写等待）应从 98.8ms 骤降；**若稳态写这才终于过 59 → 证明之前的墙确实是 DATA 物理写路径（node2 RAID）**；**若 DATA 进内存后稳态写仍卡在 ~55 不动 → 墙在更上层软件（EC 协调/OSD CPU/网络/JuiceFS），与物理盘无关**，此时 §1/§3 的证据直接给出答案。

---

## 5. 报告必须回答（对接两个方向）
1. **全内存盘 256K 稳态写（中位数）= 多少？过 59 否？IOPS = 多少？** —— 先定"后端裸能力能否打满网卡"这个分叉。
2. **rados 顺序写时客户端 eno1 TX 实测 = 多少 MB/s = 118 的几 %？**（不许再"推算"）
3. **若后端能打满网卡**：JuiceFS 写项的 客户端 TX、fio 有效写、object put 字节三者比值 → JuiceFS 有无放大 / 瓶颈在 JuiceFS 自身还是放大。
4. **若后端打不满网卡**：客户端 TX + OSD CPU + perf 分段 → 墙在 CPU / EC / 网络 哪一个。
5. 每项稳态中位数 + 趋势；所有结论对账原始逐秒/perf/网卡数据；缺的标"未取证"。

## 6. 明确不做
- ❌ 不用 bench mean / 含缓冲暂态值下"过 59"结论。
- ❌ 客户端网卡不许再"从带宽推算"，必须实测字节差分成功（§1.2 先自检）。
- ❌ 不把内存盘数据当交付基线（上限评估口径，显式标注）。
- ❌ 无数据支撑写进结论。
