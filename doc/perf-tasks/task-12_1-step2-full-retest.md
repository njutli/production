# 任务（GLM）12.1-步骤2：全量重测（内存盘 · WAL/DB独立+DATA独立 · 128G layout · A默认/B关预读）

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-10
> 前置已完成：步骤1（`results/memdisk-redeploy-128g-probe-20260709/`）已把 6 OSD 改成 **WAL/DB 独立 tmpfs(4G) + DATA 独立 tmpfs(45G)**，确认 128G layout 安全承载（%USE 73.5%、余量足），集群 HEALTH_OK、池已清空、净态就绪。**本任务在此新部署上直接开跑，不再改部署。**
> 目的：拿到**准确、可汇报给领导**的全内存盘全量数据，修复上一版 12.1 的三缺陷（① 组间相互影响 ② layout 大小不一致无法与真盘对比 ③ 没测写类）。
> **对比基准**：上周真盘 128G = `results/patched-v1.3.1-retest-20260702/full-bs256k-cold-mu150-full-20260703-145314/`（同 commands.sh 流程、mu150、cold、128G layout，但**只有默认组、无 max-readahead 0**）。本任务内存盘侧 A组=默认（与真盘同口径 → 介质对比），B组=+`--max-readahead 0`（内存盘内部 A/B 对比）。

---

## 0. 铁律
1. **二进制确认**：开跑先 `juicefs --version`，落盘确认含 `1.3.1+2025-12-02.e0032b2a`（patch）。不含则停下报告。
2. **完全复刻上周真盘流程**（见 §2 commands，逐字对齐 fio 参数），只改两处变量：① 挂载加不加 `--max-readahead 0`；② 净态纪律+采集（真盘那轮没做）。**fio 的 rw/bs/size/numjobs/ioengine/iodepth/direct/fallocate/runtime 全部与真盘一致，一个都不能改**。
3. **组间净态隔离（修复上一版污染）**：A组（默认）跑完 → **切 B组前**：umount → 清测试目录 + 清池对象 + `compact` 到 `compact_queue_len=0`（数字非空白）+ 等 iostat idle + 确认 `ceph df` 池回空 → 再挂 B组。**A/B 各自从干净态起跑**。（组内项间顺序依赖照真盘保留，不拆。）
4. **只认 r1（冷态）**，但 rand 3 轮全跑看方差；**禁用 MAX 口径**；>124 MB/s 必查是否缓存（本环境全内存盘后端上限~112，正常不应超千兆线速~118-123）。
5. **边测边盯容量**：128G layout 占池 73.5%，randwrite/randrw 覆盖写会产生临时 slice。**每个写类项前后采 `ceph df` %USE**，若任一 OSD ≥85% 立即停+报告（不硬闯 full）。
6. bash 默认 120s；长项（layout 写 128G）后台 `setsid ... </dev/null >run.log 2>&1 & disown`，轮询等完成。
7. **一切对账原始 fio/网卡/stats；无数据标"未取证"；不手填 summary。**

## 1. 全量项清单（每组内分两个阶段，A组 + B组各跑一遍完整流程）

> **⚠️ 容量约束（内存盘特有）**：内存盘池仅 294G raw（有效~152G）。顺序类峰值 64G（multi-seqwrite 16×4G）+ layout 128G = 192G 有效 = 288G raw ≈ 98% 池，**同时存在会撑爆池（撞 full 拒写）**。真盘 sdb 953G 无此约束。
> **因此顺序类与 layout+rand 必须分时占用**：顺序阶段跑完 → **清 seq_dir（删文件+清池对象+compact 到 queue_len=0+确认 `ceph df` 池回空）** → 再进 layout+rand 阶段。这不改变各项测量值（真盘跑顺序类时 test_dir 本就空、跑 rand 时 seq_dir 数据不参与 rand 读写对象），仅规避内存盘容量上限，与真盘口径实质差异极小，报告须显式标注此差异。

**每组（A/B）流程：**
- **阶段①顺序类**（seq_dir，psync iodepth=1，**非 direct**）：prep(write 4G) → seqread(read 4G, numjobs=1) → seqwrite(write 4G, numjobs=1, end_fsync=1) → multi-seqread(read 4G, numjobs=16) → multi-seqwrite(write 4G, numjobs=16, end_fsync=1)
- **【分时清理】** 清 seq_dir + 清池 + compact 到 0 + 确认池回空（落盘 `clean-seq-<组>.txt`）
- **阶段②layout**：test_dir 128 jobs × 1G = 128G，bs=4M rw=write fallocate=none end_fsync=1
- **阶段③rand**（test_dir，libaio iodepth=128 numjobs=128 **direct=1** time_based 60s，3 轮）：每轮 randread → randwrite → randrw（rwmix 默认50/50）

## 2. 逐字复刻的 fio 命令（照抄真盘 commands.sh，勿改）
```bash
# --- seq (psync, 非direct) ---
fio --name=prep          --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G
fio --name=seqread       --directory=/mnt/juicefs/seq_dir --rw=read  --refill_buffers --bs=256K --size=4G
fio --name=seqwrite      --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read  --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting
fio --name=multi-seqwrite--directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1
# --- layout (bs=4M, 128 jobs x 1G) ---
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1
# --- rand (libaio iodepth=128 numjobs=128 direct=1 time_based 60s, 3 rounds) ---
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread  --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randrw    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
```
- **A组挂载**：`juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/<vol> /mnt/juicefs`
- **B组挂载**：同上 **+ `--max-readahead 0`**
- format 用 256K block、trash-days 0（同真盘）。卷名沿用当前内存盘卷。

## 3. 每项同步采集（真盘那轮全缺，本任务必补）
每个 fio 项运行期同时采：
1. **客户端 eno1 网卡**：`/proc/net/dev` eno1 字节差分（读类看 RX，写类看 TX）。**开测前先确认 eno1 在 /proc/net/dev 的列位**（避免解析错位）。落盘 `nic-<组>-<项>.txt`，报告"稳态 X MB/s = 千兆线速(118-123)的几 %"。
2. **juicefs stats**：`juicefs stats /mnt/juicefs --interval 1 --count <runtime+5> > jfs-stats-<组>-<项>.txt`（关注 fuse read/write、object get/put 带宽+并发+lat、meta）。
3. **juicefs 进程 CPU**：`pidstat -p <jfs_pid> 1 <runtime>` → `jfs-proc-<组>-<项>.txt`。
4. **写类额外**：每个写类项前后 `ceph df`（%USE 监控）落盘。
5. **放大量化**（报告算）：读类 amp=RX/有效读、写类 amp=object put/有效写。

## 4. 判据（回报 opencode）
1. **全量 8 项 A/B 两组带宽表**（seqwrite/multi-seqwrite/seqread/multi-seqread/randwrite/randread/randrw/layout，各 r1 + 3轮方差），过 59 否。
2. **内存盘A组 vs 上周真盘128G 对比表**（同口径，介质=唯一变量）：哪些项内存盘明显高（介质收益）、哪些持平。
3. **A vs B（关预读）对比**：ra0 对每项的影响（读类预期升、seqread 可能降、写类理论不受影响——**用数据验证是否真不受影响**，不许臆断）。
4. **网卡占用**：每项 RX/TX 占千兆几 %，哪些项撞网卡墙、哪些没撞（**seqread/multi-seqwrite 是否撞墙？没撞说明有软件瓶颈→步骤3深挖**）。
5. **seqread / multi-seqwrite 初步画像**：带宽多少、网卡占用、stats 里 get/put 并发与 lat（为步骤3提供线索，本步骤不深挖根因）。
6. 容量安全（写类期间最高 OSD %USE）、组间净态是否干净（B组起跑前池确认回空）。
7. 异常如实列。

## 5. 明确不做
- ❌ 不改任何 fio 参数（必须逐字复刻真盘）；不改验收口径；不改 OSD 部署/config。
- ❌ 不取 MAX；不在含缓冲暂态/后台清理污染下取值（组间必须净态隔离）。
- ❌ 网卡不许推算，/proc/net/dev 实测（先自检列位）。
- ❌ 写类不许臆断"不受 ra 影响"就跳过 B组——B组也要全量跑。
- ❌ 无数据支撑写进结论；不深挖 seqread/multi-seqwrite 根因（留步骤3）。

## 6. 产出目录
`results/memdisk-fullretest-128g-20260710/`：
```
├── ops.log                          # 全程 + 版本 + 挂载参数 + 组间净态复位记录
├── version.txt
├── commands.sh                      # 实际执行命令（对账可复刻真盘）
├── A/  (默认组)  fio-*.txt / nic-A-*.txt / jfs-stats-A-*.txt / jfs-proc-A-*.txt
├── B/  (ra0组)   fio-*.txt / nic-B-*.txt / jfs-stats-B-*.txt / jfs-proc-B-*.txt
├── cephdf-write-monitor.txt         # 写类期间 %USE 监控
├── clean-seq-A.txt / clean-seq-B.txt   # 顺序类→layout 分时清理证明(池回空+compact 0)
├── clean-between-AB.txt             # A→B 切换净态复位证明(池回空+compact 0)
├── compare-vs-realdisk.md           # A组 vs 上周真盘128G 对比表
└── report.md                        # 7 个判据
```
