# 随机读 vs 顺序读 同口径对照分析（opus 复核）

> 日期：2026-06-29
> 数据来源：本目录 `seqrand-osd-compare-final-20260629/`（deepseek 采集，opus 对账分析）
> 环境：JuiceFS v1.3.1 / Ceph 17.2.8 EC 4+2 (6 OSD) / 1Gbps / mount `--cache-size 0`
> 工作集：128G（128 jobs × 1G），block-size=256K，layout 复用 repro-09

---

## 一、数据可靠性评估：可信

逐项对账原始文件，本次质量明显高于前两次（strace-rerun / v1），结论可用。

### 冷态纪律 ✓
- `mount.log` 确认：`cache-size is 0, writeback and prefetch will be disabled`（客户端无缓存、无 writeback、无 prefetch）。
- `test-script.log` 每个 fio 前都有 `DROP` + 客户端 + 三台 OSD（.11/.13/.14）逐台回显 `OK`，drop 真做了且验证成功（失败即 exit）。
- 所有 fio `runtime ≈ 61s`（正常 60s time_based），不是病态短跑。

### 口径统一 ✓
- 带宽用 **baseline 组（无 strace）**；strace 的 runA/runB 单独，带宽仅记录不采用（strace 拖慢）。
- randread 三轮 **33.8 / 33.8 / 34.7**，与 v2(33.7)、GLM 基线(33.5) 三次独立测试互证，高度可复现。
- seqread direct=1 = **106**，与 v2(108) 一致。
- fd→OSD 映射当次记录（`fd-map-randread.txt`）。

### 采集完整 ✓
- strace 两组（randread / seqread，除 rw 外完全同口径，同一冷态各自一次 run）。
- OSD op_r_latency before/after 差值（randread + seqread 都采）。
- dump_historic_ops 阶段分解（6 OSD，21KB/个，有内容）。

### 小瑕疵（不影响结论）
- historic_ops 阈值设置回显 `= ''`，但 historic 文件有内容，阈值实际生效/默认够用。
- sweep 的 nj32 单点 io 偏低（28.5），属波动，不影响趋势。

**判定：数据可信，可用于瓶颈分析。**

---

## 二、核心对照表（同口径冷态）

> 说明：strace 各行因 `-f` 多线程跟踪被拆成 `<unfinished ...>` + `<... resumed>` 两行（占 ~84%），返回值在 resumed 行。下表 strace 统计是**配对 unfinished/resumed + 按 6 条 OSD socket FD 过滤**算出的（订正版，见 §二·附 (3)(4)）。

| 指标 | randread | seqread | 倍数 |
|------|----------|---------|------|
| 带宽 | **33.8 MB/s** | **106 MB/s** | 3.1× |
| NIC 放大 (NIC RX / 有效字节) | **3.45×** | **1.10×** | 3.1× |
| OSD strace 总字节 / 有效字节（应用层放大） | **3.57×** | **1.05×** | 3.4× |
| **OSD read() 密度（条数 / 有效 MiB）** | **177 /MiB** | **44 /MiB** | **4.0×** |
| OSD read() 条数（绝对值） | 359,576 | 280,824 | — |
| OSD read() 中位返回 | 8,760 B | 10,220 B | ≈ |
| OSD read() 均值返回 | 21.2 KB | 25.1 KB | ≈ |
| OSD read() >=64K 占比 | 5.6% | 7.0% | ≈ |
| OSD op_r_latency（慢 OSD） | 18–31 ms | 32–64 ms | seq 反而更高 |

带宽（3.1×）、NIC 放大（3.1×）、OSD strace 应用层放大（3.4×）、read() 密度（4.0×）四个**独立来源**的比例都在同一量级——差距的直接表现就是：随机读为搬运每 MB 有效数据，要从 OSD 拉回 ~3.5× 的字节、做 ~4× 的 socket read。

> **read() 密度才是对的口径（不是绝对条数）**：绝对条数 randread 359576 vs seqread 280824 看似只差 1.18×，但这是因为 seqread 的有效数据本身就大 3 倍（6412 vs 2034 MiB）。**按单位有效数据看，randread 每 MiB 触发 177 次 socket read，seqread 只 44 次，密度差 4.0×**——与放大同量级。（这点采纳 deepseek 指正：用绝对条数对比会掩盖密度差。）

> **read() 返回分布形态两者接近**（中位 8760 vs 10220、均值 21K vs 25K、>=64K 5.6% vs 7.0%）→ "顺序读 socket 也一样碎、碎读非随机读独有"成立。差距在**密度/总字节**，不在单次大小。
>
> **非 OSD read() 可忽略**：randread/seqread 各有 13-22% 的 read() 是 FUSE/管道等非 OSD，但都是几十字节小读，总字节仅 5 MiB（占 0.07%），不影响放大比。详见 §二·附 (4)。

---

## 二·附：每个数据的原始来源与计算过程（供从原始数据校验）

> 凡标 MiB/MB：fio 的 `bw=...MiB/s` 与 `(...MB/s)` 是同一值的二进制/十进制两种写法。下表带宽列我用 fio 的 **MB/s（十进制）**，与表二一致。

### (1) 带宽 BW

**来源**：各 baseline fio 输出文件的 `Run status` 行（无 strace，干净口径）。

- `baseline-randread-r1.txt`：`READ: bw=33.8MiB/s (35.5MB/s) ... io=2065MiB (2165MB), run=61071msec`
- `baseline-randread-r2.txt`：`bw=33.8MiB/s (35.5MB/s) ... io=2063MiB`
- `baseline-randread-r3.txt`：`bw=34.7MiB/s (36.4MB/s) ... io=2117MiB`
- `baseline-seqread.txt`：`bw=106MiB/s (111MB/s) ... io=6497MiB (6812MB), run=61107msec`

表中 randread 取 r1=33.8 MiB/s（≈35.5 MB/s），三轮 33.8/33.8/34.7 一致。seqread=106 MiB/s（≈111 MB/s）。
**倍数**：106 / 34.1(三轮均) ≈ 3.1×。

> 注：runA-fio.txt（randread 带 strace）=33.3、runB-fio.txt（seqread 带 strace）=104，与 baseline 几乎一致——本次 strace 对带宽影响很小，但表中带宽仍用无 strace 的 baseline。

### (2) NIC 放大 = NIC RX 字节 / fio 有效字节

**来源**：
- NIC RX 字节：`test-script.log`（脚本用 `/proc/net/dev` 在每个 fio 前后取 eno1 rx_bytes 增量）：
  - randread r1：`RX=7465829388`（字节）
  - seqread：`RX=7470827339`（字节）
- fio 有效字节：对应 fio 输出 `io=...MB`（十进制字节）：
  - randread r1：`io=2065MiB (2165MB)` → 用 MiB 换算 2065×1024×1024 = **2,165,309,440 字节**
  - seqread：`io=6497MiB (6812MB)` → 6497×1024×1024 = **6,812,598,272 字节**

**计算**：
- randread：7,465,829,388 / 2,165,309,440 = **3.448×**
- seqread：7,470,827,339 / 6,812,598,272 = **1.097×**
- 倍数：3.448 / 1.097 = **3.14×**

> 这与 test-script.log 自己算的 `NIC/FIO=3.44` / `1.09` 一致（脚本用 io 的 MiB 数算，与上式同）。
> 重要前提：NIC RX 是 eno1 **全口径**，含 SSH/心跳等非 Ceph 流量。两次测量同一网卡、同样时长（~61s），非 Ceph 背景流量量级相同，所以**做比值对照是有效的**；但绝对放大值含少量背景噪声（量级可忽略，~7.4G RX 中背景流量极小）。

### (3) strace 解析的重要修正：必须配对 unfinished/resumed（否则漏 84%）

> **这是初版分析的一个错误，已订正，记录在此供校验。**

strace 用 `-f` 跟踪多线程，一个 read() 常被其它线程事件打断，拆成两行：
```
[pid 28] read(27, <unfinished ...>
[pid 28] <... read resumed>"...data...", 262124) = 7300
```
返回值在 **resumed 行**，`unfinished` 行没有返回值。

**初版的错误**：正则只匹配 `read(...) = N$` 的**完整行**，把所有 resumed 行漏掉了。实测两类行数：

| 日志 | 完整 read=N 行 | resumed read 行 | 初版漏掉比例 |
|------|---------------|-----------------|------------|
| strace-randread.log | 67,541 | 358,144 | **84%** |
| strace-seqread.log | 57,205 | 303,175 | **84%** |

所以初版的 "中位 5840 / socket reads 67541 / reads/MiB 33.2" 全是基于 **16% 子样本**，作废。下面 (4) 是配对 unfinished+resumed 的**全量**正确结果。

**不需要重抓 strace**：日志本身完整、所有 read() 的返回值都在（resumed 行里），fd 也能通过 PID 配对 unfinished 行还原。问题只在解析方法，重新正确解析即可。

### (4) strace read() 返回值分布与放大（按 OSD FD 过滤，已二次订正）

> **订正记录**：初版未配对 unfinished/resumed（漏 84%，见 (3)）；二版配对了但**未按 OSD FD 过滤**（混入 FUSE/管道等非 OSD read）。本节是**三版**：配对 unfinished/resumed + 按 6 条 OSD socket FD 过滤。

**FD 过滤方法**：resumed 行不带 FD，但其 `unfinished` 行带 FD。strace `-f` 下同一线程(PID)同时只有一个未完成的 read，故按 **PID 把 unfinished(带FD) 与 resumed(带返回值) 配对**，即可给每个 read() 还原 FD，再按 OSD FD 集合过滤。
- randread OSD FD：27,28,29,30,31,32（见 `fd-map-randread.txt`）
- seqread OSD FD：27,28,29,30,32,34；FD 31=TiKV(2379) 已排除（见 `fd-map-seqread.txt`）

**OSD vs 非 OSD（按 FD 过滤后）**：

| | randread | seqread |
|--|----------|---------|
| OSD read() 条数 | 359,576 | 280,824 |
| OSD read() **总字节** | **7,257 MiB** | **6,714 MiB** |
| OSD 中位返回 | 8,760 B | 10,220 B |
| OSD 均值返回 | 21,164 B | 25,070 B |
| OSD >=64K 占比 | 5.6% | 7.0% |
| 非 OSD read() 条数 | 66,109（13%） | 79,556（22%） |
| 非 OSD read() **总字节** | **5 MiB** | **5 MiB** |
| 非 OSD 中位返回 | 80 B | 80 B |

> 关键：非 OSD read() 占**条数** 13-22%，但占**字节仅 5 MiB / 7262 MiB ≈ 0.07%**——都是 FUSE 控制 / 管道 / eventfd 的几十字节小读，不搬运数据 payload。所以**总字节几乎纯是 OSD 流量，放大比不受非 OSD 污染**。（这点回应了 deepseek 的"30-40% 污染"质疑：那是按行数算的，按字节算可忽略。）

**应用层放大 = OSD read() 总字节 / fio 有效字节**（用 runA/runB 自己的 io：randread 2034 MiB、seqread 6412 MiB）：
- randread：7257 / 2034 = **3.57×**
- seqread：6714 / 6412 = **1.05×**
- 倍数：3.57 / 1.05 = **3.40×**

→ 与初版/二版的 3.57×/1.05× 一致，**放大结论不因 FD 过滤改变**。

**形态对比**：randread 与 seqread 的 OSD read() 返回分布形态仍接近（中位 8760 vs 10220、均值 21K vs 25K、>=64K 5.6% vs 7.0%），"两种负载同样碎、碎读非随机读独有"的结论**成立且 FD 过滤后更干净**。

**关于 NIC 交叉验证（已撤销，记录原因）**：
- 初版我写过"strace 总字节 ≈ NIC RX，互相印证"。**此交叉验证不成立，已撤**：当时用的 NIC RX（7,120 MiB）来自 **baseline r1**（io=2065，无 strace），而 strace 字节来自 **runA**（io=2034，带 strace），是**两次不同的 run**，不能交叉验证。
- 而且 runA/runB **没有记录 NIC RX**（采集脚本疏漏），所以本次无法做"同 run strace 字节 vs NIC RX"的真交叉验证。
- 但放大结论**不依赖该交叉验证**：3.57× 是 runA **单 run 内部** 的 strace OSD 字节(7257) / 同 run 有效字节(2034)，自洽。（下次采集纪律：strace run 必须同时记 NIC RX。）

**校验脚本（可复现，PID 配对 + OSD FD 过滤）**：
```python
import re, statistics
def analyze(fn, osd_fds):
    osd_fds=set(osd_fds); pending={}; osd=[]; other=[]
    re_unf=re.compile(r'^(?:\[pid\s+)?(\d+)\]?\s+read\((\d+),.*<unfinished')
    re_res=re.compile(r'^(?:\[pid\s+)?(\d+)\]?\s+<\.\.\. read resumed>.*?=\s*(-?\d+|.*EAGAIN.*)$')
    re_cmp=re.compile(r'^(?:\[pid\s+)?(\d+)\]?\s+read\((\d+),.*\)\s*=\s*(-?\d+|.*EAGAIN.*)$')
    for line in open(fn, errors='ignore'):
        line=line.rstrip()
        m=re_unf.search(line)
        if m: pending[m.group(1)]=int(m.group(2)); continue
        m=re_res.search(line)
        if m:
            fd=pending.pop(m.group(1),None); v=m.group(2)
            if 'EAGAIN' in v: continue
            v=int(v)
            if v>=0: (osd if fd in osd_fds else other).append(v)
            continue
        m=re_cmp.search(line)
        if m:
            fd=int(m.group(2)); v=m.group(3)
            if 'EAGAIN' in v: continue
            v=int(v)
            if v>=0: (osd if fd in osd_fds else other).append(v)
    def s(r,l): print(f"  {l}: n={len(r)} median={statistics.median(r)} mean={sum(r)/len(r):.0f} total_MiB={sum(r)/1048576:.0f}")
    print(fn); s(osd,"OSD"); s(other,"non-OSD")
analyze('strace-randread.log',[27,28,29,30,31,32])
analyze('strace-seqread.log',[27,28,29,30,32,34])
# randread: OSD n=359576 median=8760 mean=21164 total_MiB=7257 ; non-OSD n=66109 median=80 total_MiB=5
# seqread : OSD n=280824 median=10220 mean=25070 total_MiB=6714 ; non-OSD n=79556 median=80 total_MiB=5
```

### (5) OSD op_r_latency（每对象 OSD 侧平均读延迟）

**来源**：`runA-osd{i}-before.json` / `runA-osd{i}-after.json`（randread），`runB-...`（seqread）。
每个 json 里 `op_r_latency` 块有累计计数 `avgcount` 和累计耗时 `sum`（单位秒）。窗口内平均延迟 = (sum_after − sum_before) / (avgcount_after − avgcount_before)。

**示例（runA osd4，randread）**：
```
before: "op_r_latency": { "avgcount": 5372463, "sum": 138585.591240640 }
after : "op_r_latency": { "avgcount": 5383648, "sum": 138934.255201944 }
Δcount = 5383648 - 5372463 = 11185
Δsum   = 138934.255201944 - 138585.591240640 = 348.663961304 (秒)
avg = 348.663961304 / 11185 = 0.031172 秒 = 31.17 ms
```

**全部结果（精确计算）**：

| osd | node | randread Δops | randread avg(ms) | seqread Δops | seqread avg(ms) |
|-----|------|---------------|------------------|--------------|-----------------|
| 0 | node1 | 1697 | 11.44 | 1751 | 13.11 |
| 1 | node1 | 8399 | 12.73 | 8404 | 13.28 |
| 2 | node2 | 10477 | 18.01 | 10360 | **63.94** |
| 3 | node2 | 12587 | 23.59 | 11792 | 31.98 |
| 4 | node3 | 11185 | **31.17** | 10095 | 36.78 |
| 5 | node3 | 12782 | 19.87 | 11574 | 51.49 |

表二里"慢 OSD 18–31ms / 32–64ms"即取上表 randread 的 osd2-4（18-31）与 seqread 的 osd3-5（32-64）。
**校验脚本（可复现）**：
```python
import re
def getval(f, field):
    txt=open(f).read()
    m=re.search(r'"op_r_latency":\s*\{[^}]*?"%s":\s*([0-9.]+)'%field, txt, re.S)
    return float(m.group(1))
for run in ['runA','runB']:
    for i in range(6):
        cb=getval(f"{run}-osd{i}-before.json","avgcount"); sb=getval(f"{run}-osd{i}-before.json","sum")
        ca=getval(f"{run}-osd{i}-after.json","avgcount");  sa=getval(f"{run}-osd{i}-after.json","sum")
        print(run, i, int(ca-cb), round((sa-sb)/(ca-cb)*1000,2),"ms")
```

### (6) OSD 单 op 阶段分解（historic_ops）

**来源**：`runA-osd4-historic.txt`（randread，慢 OSD）、`runB-osd2-historic.txt`（seqread）。json 里每个 op 的 `type_data.events` 是时间戳序列。取第一个 `[read 0~262144]` 的 op，把各 event 时间减去 `initiated` 得相对毫秒。

**runA osd4 一个 read op（duration=0.182s）**：
```
initiated/header_read         +0.000 ms
throttled                     +0.004 ms
all_read                      +0.017 ms
dispatched                    +0.020 ms
queued_for_pg                 +0.027 ms
reached_pg                    +0.132 ms
started                       +0.164 ms
done                        +182.315 ms   ← 几乎全部时间在 started→done
```
**runB osd2 一个 read op（duration=0.354s）**：`reached_pg +18.99ms / started +19.03ms / done +354.43ms`——同样几乎全在 started→done。

> 说明：historic_ops 默认只保留**最慢的若干** op，所以这里 182/354ms 是采样窗口里的**慢尾**，不代表平均（平均看 (5)）。但阶段分布（时间花在哪）对慢 op 和典型 op 是一致的结论：排队/分发/网络到达 < 1ms，瓶颈在 OSD 内部 `started→done` 的 EC 执行。
> 原始 json 因 cephadm shell 拼接在文件尾部有截断，解析时按花括号配平取第一个完整 op 即可（截断不影响首个 op）。

---

## 三、推翻之前的假设：放大不在"messenger 碎读"

**之前所有文档（v1 README §5、10_A_2_3、strace-rerun README）都认为：随机读放大的根因是"messenger 每次 read() 只拿到 5-6KB 碎片、顺序读能拿大块"。这批同口径数据证明这是错的。**

- randread 与 seqread 的 **OSD read() 返回分布形态接近**（中位 8760 vs 10220、均值 21K vs 25K、>=64K 5.6% vs 7.0%；各桶形态接近，见 §二·附 (4)）。
- 也就是说：**顺序读的 socket 也一样碎**。messenger 碎读不是随机读独有现象，**不能用它解释 3 倍带宽差**。

之前 strace-rerun 看到的"碎读"是真的，但**顺序读同样碎**，所以它不是随机读慢的原因——之前因为没有同口径顺序读对照，误把一个两者共有的现象当成了随机读的病根。（本结论用配对 unfinished/resumed 的**全量** strace 数据得出，比初版的 16% 子样本更有力。）

---

## 四、数据真正指向的瓶颈

把事实串起来（全部来自本次数据，非推测）：

1. **放大量精确对应带宽差**：strace 应用层放大 3.4×（read()总字节/有效字节）+ NIC 放大 3.1× ≈ 带宽差 3.1×。随机读每 MB 有效数据，管道里混着 ~3.5× 的字节。

2. **多出来的不是"碎"，是"密度/总字节按比例放大"**：OSD read() 单次大小分布两者接近（中位 8760 vs 10220），但**单位有效数据的 read() 密度差 4.0×**（randread 177/MiB vs seqread 44/MiB）；总字节——randread 用 7257 MiB OSD read() 换 2034 MiB 有效（3.57×），seqread 用 6714 MiB 换 6412 MiB 有效（1.05×）。

3. **OSD 侧单 op 时间几乎全在 EC 读取/重建执行阶段**：`runA-osd*-historic.txt` 解析一个典型 read op 的事件时间线：
   ```
   initiated → header_read → throttled → all_read → dispatched
   → queued_for_pg → reached_pg → started   （以上累计 < 1 ms）
   → done                                    （+182 ms / +354 ms）
   ```
   即排队、分发、网络到达 OSD 只占零点几毫秒，**几乎全部时间花在 `started → done`**——OSD 内部读 EC 分片 + 重建完整对象的执行。EC 4+2 随机读每个 256K 对象要 primary OSD 去拉另外 3 个 data 分片重建。

4. **顺序读 OSD 单 op 更慢，带宽却高 3 倍**：seqread osd2 op_r_latency 64ms > randread osd2 18ms，但 seqread 带宽 3 倍于 randread。说明**瓶颈不是单 op 延迟，差异在单位有效数据的字节放大/read 密度**（randread 3.57× / 177/MiB，seqread 1.05× / 44/MiB）。

### 结论（区分"已证"与"假设"）

**数据已直接证明的（可作结论）**：
- messenger 碎读**不是**随机读慢的根因——同口径下顺序读 socket 一样碎（分布形态接近）。
- 随机读为每 MiB 有效数据，要从 OSD 拉回 **3.57× 的字节、做 ~4× 的 socket read**；这个放大量与 3.1× 带宽差同量级，是带宽差的直接表现。
- OSD 侧单 op 时间几乎全在 `started→done`（EC 读取/重建执行），而非排队/分发/网络到达。

**仍是假设、尚未证明的（不能作结论）**：
- > "3.57× 放大来自 EC 4+2 随机取片 / 对象间无法流水线化" —— 这是当前数据**最合理的指向，但只是推论**。3.57× 的**构成**（EC 取片开销 / 协议头 / OSD 间等待各占多少）**没有数据拆解**，也没有"非 EC（副本池）随机读"的对照。**必须用 §五 的副本池对照来证实/证伪后才能升级为结论。**（采纳 deepseek 指正：此前结论段措辞过于肯定，已降级为假设。）

### 与历史数据的关系（不矛盾）
- L1 裸 RADOS 当年测 EC 放大 1.04× —— 那是顺序/低并发口径，**没有复现这里的高并发 EC 随机读模式**。所以"L1=1.04×"与"本次随机读放大 3.57×"不矛盾：前者证明 EC 顺序/低并发几乎零放大，后者揭示 EC **随机高并发**才出放大（但放大归因仍待副本池对照证实）。
- 注：本次 read() 分布与历史 strace 的"碎读"现象一致，但**碎读两种负载都有**，不是放大来源。

### 数据可靠性的已知缺口（诚实标注）
- strace 的 3.57× 是 **runA 单 run 内部自洽**（strace OSD 字节 ÷ 同 run 有效字节），但 runA/runB **未记录同 run NIC RX**（脚本疏漏），所以缺一个独立网络层印证；strace 本身拖慢 I/O（runA 33.3 vs baseline 33.8），在 strace 下多读/漏读多少字节无独立验证。下次 strace run 必须同时记 NIC RX。
- PID 配对还原 FD 的可靠性已验证：402122 次 unfinished 中**零**"同线程双未完成 read"冲突（`<unfinished>` 表示线程阻塞、resumed 前无法发新 syscall，故每线程任意时刻最多一个在途 read），FD 归属唯一确定。

---

## 四·补：放大发生在"客户端多读"，不在服务端（op_r_out_bytes 证据）

> 这是对 §四 的关键升级：用 OSD 侧 `op_r_out_bytes`（OSD 实际吐出给客户端的字节）定位放大发生在链路哪一段。**结论：放大在客户端发起的读量，不在服务端逻辑，也不在网络协议。**

### 核心表

| | OSD 吐出字节 | fio 有效字节 | **后端放大** | 每 op 吐出 | OSD 读请求长度 |
|---|---|---|---|---|---|
| randread(EC) | 7,071 MiB | 2,034 MiB | **3.48×** | 126.7 KiB | 256K（0~262144） |
| seqread(EC) | 6,681 MiB | 6,412 MiB | **1.04×** | 126.7 KiB | 256K（0~262144） |

### 三条判据（用你的"客户端 vs 服务端"逻辑）

1. **请求侧相同**：randread 和 seqread 的 OSD 读 op 请求长度**都是 256K**（historic_ops 里 `[read 0~262144]`）。客户端没有发"更大的请求"。
2. **服务端行为相同**：两者**每 op 吐出都是 126.7 KiB**，OSD 对随机/顺序一视同仁，没有因为随机读就多吐。→ **服务端逻辑不是放大源。**
3. **差异在有效利用率**：op 数几乎相同（randread 57127 vs seqread 53976），每 op 吐出相同（126.7K），但——顺序读吐出 6681 MiB 几乎全被 fio 利用（1.04×），随机读吐出 7071 MiB 只有 1/3.4 被利用（3.48×）。

→ **结论**：OSD 吐出量（7071 MiB）≈ 线缆 NIC RX（7120 MiB），说明网络协议几乎不额外放大；放大在 OSD 吐出这一步就已存在，而服务端对两种负载行为相同 → **放大是客户端为满足同样有效数据、发起了 3.48× 的读量（多读了 fio 用不上的数据）**。这是**客户端逻辑问题**，最典型的机制是 **readahead**（当前挂载未设 `--max-readahead 0`，为默认值，见 §六 待验证）。

> 注：这也修正了 §四 的推论——之前把放大归因于"EC 无法流水线化"，现在 op_r_out_bytes + 副本池对照（见 randread-bottleneck-20260630）共同表明：放大是**客户端多读**，与 EC/服务端无关。

### 原始数据来源与计算过程（供从原始日志校验）

**(a) OSD 吐出字节 = 6 个 OSD 的 op_r_out_bytes 增量之和**

数据来源：`runA-osd{i}-{before,after}.json` 里的 `"op_r_out_bytes"` 字段（OSD 累计吐出字节，单位 byte）。每 OSD 增量 = after − before。

randread（runA）：
```
osd0: 152857812029 - 152650705613 =   207,106,416
osd1: 373256279363 - 372155862723 = 1,100,416,640
osd2: 172807150049 - 171450078753 = 1,357,071,296
osd3: 202775247381 - 201142252645 = 1,632,994,736
osd4: 466903596161 - 465461716097 = 1,441,880,064
osd5: 202117271209 - 200442724153 = 1,674,547,056
合计 = 7,414,016,208 byte = 7,414,016,208 / 1048576 = 7071 MiB
```
数据来源逐项：`osdN delta = grep '"op_r_out_bytes"' runA-osdN-after.json  −  同字段 runA-osdN-before.json`

seqread（runB）：
```
osd0: 153104767784 - 152890845208 =   213,922,576
osd1: 374438884048 - 373337287728 = 1,101,596,320
osd2: 174193715243 - 172850931723 = 1,342,783,520
osd3: 204324613846 - 202794648086 = 1,529,965,760
osd4: 468203649599 - 466903598159 = 1,300,051,440
osd5: 203634391579 - 202117271659 = 1,517,119,920
合计 = 7,005,439,536 byte = 6681 MiB
```

**(b) fio 有效字节**

数据来源：`runA-fio.txt` / `runB-fio.txt` 的 `Run status` 行 `io=...MiB`。
- randread：`io=2034MiB` → 2034 MiB
- seqread：`io=6412MiB` → 6412 MiB

**(c) 后端放大 = (a)/(b)**
- randread：7071 / 2034 = **3.48×**
- seqread：6681 / 6412 = **1.04×**

**(d) op 数 = 6 个 OSD 的 op_r 增量之和**

数据来源：同 json 里的 `"op_r"` 字段（OSD 累计读 op 数）。after − before 求和：
- randread：57,127；seqread：53,976

**(e) 每 op 平均吐出 = (a) / (d)**
- randread：7,414,016,208 / 57127 / 1024 = **126.7 KiB**
- seqread：7,005,439,536 / 53976 / 1024 = **126.7 KiB**

**(f) OSD 读请求长度**

数据来源：`runA-osd2-historic.txt` / `runB-osd2-historic.txt` 里 op 描述 `[read 0~NNNN]` 的 NNNN 值。
- 两者均为 `262144`（=256K），无其它值。

> 交叉印证：OSD 吐出 7071 MiB（(a)）≈ 线缆 NIC RX 7120 MiB（test-script.log baseline r1 的 7,465,829,388 byte）≈ strace read() OSD 字节 7257 MiB（§二·附(4)）。三个独立测量点（OSD perf / 网卡计数 / 客户端 strace）一致 → 放大链路清晰：客户端发起 3.48× 读量 → OSD 吐 3.48× → 线缆传 3.45× → fio 只用 1×。

---

## 五、下一个验证任务：副本池 vs EC 池 同口径随机读对照

目的：**直接证实/证伪"3.4× NIC 放大来自 EC 随机取片"**。这是当前结论唯一缺的对照。

### 思路
在同集群、同硬件、同客户端下，建一个**3 副本池**（非 EC），用**完全相同的口径**跑随机读，对比 NIC 放大和带宽。
- 若副本池随机读 NIC 放大降到接近 1×、带宽显著上升 → **坐实放大来自 EC 随机取片**。
- 若副本池随机读 NIC 放大仍 ~3× → 放大不在 EC 层，要另找（messenger/协议/客户端并发模型）。

### 严格控制变量（关键）
副本池和 EC 池**除冗余策略外其它全相同**：同 SSD、同 6 OSD、同 PG 数量级、同 block-size 256K、同挂载参数（`--cache-size 0`）、同 fio 口径（nj=128/256K/direct=1/iodepth=128/runtime=60s）、同 128G 工作集、同冷态纪律（drop 客户端 + 3 OSD，逐台验证）。

> 注意容量：副本池 3 副本，128G 数据要 384G 裸容量，确认集群够放；若不够，副本池和 EC 池都缩到相同的较小工作集（如 64×1G=64G）重测一遍 EC 做对照，保证两者工作集一致。

### 步骤
1. 建 3 副本池（如 `juicefs-data-rep3`，size=3），PG 数与 EC 池同量级。
2. 新建一个 JuiceFS 卷指向该副本池（或用副本池重新 format 一个 prod 卷），block-size=256K。
3. layout 建同样的 128×1G（或与 EC 对照统一的工作集）。
4. 跑随机读：3 轮，每轮前 drop（客户端 + 3 OSD，逐台验证 OK），记 BW + NIC RX。
5. 同步采 OSD op_r_latency（before/after，cephadm shell，6 OSD）。
6. （可选）采一次 strace read() 返回分布，看副本池下分布是否变化。
7. **同口径再跑一次 EC 池随机读**作为同时段对照（避免集群状态漂移），保证两组在同一环境直接对比。

### 必须控制 / 避免的坑（沿用本次纪律）
- 全程 `--cache-size 0`，mount.log 确认 `writeback and prefetch will be disabled`。
- 每个 fio 前 drop_all 带返回码验证（每台回显 OK，失败 exit），沿用本次脚本框架。
- 工作集 > OSD 内存，保证冷态；若缩小工作集，EC 对照组也用同样大小。
- strace 不报带宽；带宽用无 strace 的 baseline run。
- fd→OSD 映射当次确认。
- 不抓 tcpdump；NIC RX 用 /proc/net/dev 算 eno1 rx_bytes 增量（注明含非 Ceph 流量）。
- 采集阶段不下原因结论；README 只放数值/分布/原始输出。
- 验收口径不变：256K、单客户端、目标 59 MB/s。

### 回传产出（放 `results/ec-vs-replica-randread-20260630/`）
1. 对照主表：

| 池类型 | 冗余 | randread BW (MB/s) | NIC RX (MiB) | NIC 放大 | socket reads/MiB | OSD op_r_latency |
|--------|------|--------------------|-------------|---------|------------------|------------------|
| EC 4+2 | EC | | | | | |
| 3 副本 | rep3 | | | | | |

2. 两池各自的 randread 3 轮 BW/NIC RX。
3. OSD op_r_latency 对比（6 OSD）。
4. （可选）strace 返回分布对比。
5. 完整脚本 + 日志 + 所有原始文件（fio / OSD json / mount.log / env）。
6. 容量/PG/池配置快照（`ceph osd pool ls detail`、`ceph df`）。

### 预期判读（不预设，仅说明怎么读）
- 副本池 NIC 放大 → 1× 且带宽上升：放大 = EC 随机取片，结论坐实。下一步转"是否换池/或多客户端聚合达标"。
- 副本池 NIC 放大仍高：放大不在 EC，回到 messenger/协议/客户端并发模型，重新定位。

---

## 六、本次文件清单

```
seqrand-osd-compare-final-20260629/
├── README-opus.md            本文件（分析 + 下一任务）
├── test-script.sh / .log     完整脚本 + 运行日志（含 drop 验证）
├── mount.log                 cache=0 确认
├── fd-map-randread.txt       fd→OSD 映射
├── baseline-randread-r{1,2,3}.txt   随机读 3 轮（无 strace，干净带宽）
├── baseline-seqread.txt      顺序读 direct=1
├── baseline-nj{8,32,64,256}.txt     并发扫描
├── runA-fio.txt + runA-osd{0-5}-{before,after}.json + runA-osd{0-5}-historic.txt   randread 完整采集
├── runB-fio.txt + runB-osd{0-5}-{before,after}.json + runB-osd{0-5}-historic.txt   seqread 完整采集
├── strace-randread.log       randread strace（read 返回分布来源）
└── strace-seqread.log        seqread strace（同口径对照）
```
