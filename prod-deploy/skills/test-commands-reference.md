# 测试命令参考手册（Test Commands Reference）

> 本文整合所有测试项的**完整可执行命令**，便于：
> 1. 一眼看清楚每个测试项怎么测（fio 参数、口径、验收线）
> 2. 提供给他人复现——**不依赖我们的测试脚本**，按本文命令即可构建自己的测试
>
> 配套：方法论（health 检查/cooldown/缓冲暂态/可靠性判据）见同目录 `TESTING-GUIDE.md`。
> 命令中的 `<PD_ENDPOINTS>` / `<MOUNT>` 等占位符按实际环境替换（见 §0 环境变量）。

---

## 〇、环境变量与通用约定

```bash
# 以下变量按实际环境填（对应 prod-deploy/config.sh）
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"                             # JuiceFS 挂载点（157）
TEST_DIR="${MNT}/test_dir"                     # fio 工作目录
LAYOUT_DIR="${MNT}/test_dir"                   # randread 预铺数据目录（与 TEST_DIR 同）
CACHE_DIR="/mnt/jfs-cache"                     # 暖态缓存目录（157 的 nvme1n1；冷态不用）
POOL="juicefs-data"                            # Ceph RADOS 池名（直连 RADOS 后端）
CEPHX="client.juicefs"                         # cephx 用户名

# 验收线（单项有效数据带宽 ≥ 此值）
#   不限速口径（100GbE TCP）：6250 MiB/s（网卡半速 12500/2）
#   千兆限速口径（eno12409 TBF 1Gbps）：59 MB/s（网卡半速 118/2）
#   多客户端：N × 单客户端验收线
ACCEPT=6250   # 不限速口径；限速口径改 ACCEPT=59

# JuiceFS 版本要求（关键）：
#   必须使用含 loadRange 修复（commit eaf3d21f）的版本。
#   stock v1.3.1 有 2× 读放大 bug（cached_store.go:153 条件阻止 128K 半块读）。
#   方案一：patched v1.3.1（应用 eaf3d21f）
#   方案二：v1.4.x（已含此 fix）
#   验证方法：juicefs --version 应显示 1.3.1+ 或 1.4.x
JUICEFS_BW_LOG_DIR="/tmp/jfs-bw"  # bw_log 输出目录（§8）
RESULTS_DIR=""                    # 测试结果保存目录（每项 fio 的产出都存这里）
```

**通用口径（所有测试项）：**
- 所有项 `--bs=256k`：与 JuiceFS `--block-size 256K` 对齐，消 16× 读放大（见 `doc/perf-analysis/08_2`）
- 随机项 `--ioengine=libaio --iodepth=128`：异步 IO，深度 128
- 随机项 `--numjobs=128`：128 并发 job；顺序项 numjobs=1（单流）或 16（多线程）
- `--direct=1`：绕开内核页缓存（但绕不开 JuiceFS 客户端缓冲，见 TESTING-GUIDE §5.6）
- `--time_based --runtime=180s`：时间基准，跑满 180s（60s 太短，缓冲暂态占 15s 后稳态样本不够）
- `--group_reporting`：多 job 合并上报
- **所有项必须加 `--write_bw_log --log_avg_msec=1000`**：每秒一个瞬时带宽点，用于稳态中位数计算（见 §8）
- 随机项 REPEAT=3（冷态）或 7（暖态看收敛），取稳态中位数（见 §8）

---

## 一、测试项总表

| # | 测试项 | fio --rw | bs | numjobs | runtime | 验收口径 | 说明 |
|---|--------|----------|-----|---------|---------|---------|------|
| 1 | 顺序读 seqread | `read` | 256k | 1 | 180s | ≥ ACCEPT | 单流顺序读，bs 对齐 block-size |
| 2 | 顺序写 seqwrite | `write` | 4M | 1 | — | ≥ ACCEPT | 单流大块顺序写（fsync/nofsync 两版） |
| 3 | 多线程读 mseqread | `read` | 256k | 16 | 180s | ≥ ACCEPT | 16 job 并发顺序读 |
| 4 | 多线程写 mseqwrite | `write` | 4M | 16 | — | ≥ ACCEPT | 16 job 并发顺序写 |
| 5 | 布局写 layout | `write` | 4M | 128 | — | — | 预铺 128G 数据供 randread 复用 |
| 6 | 随机读 randread | `randread` | 256k | 128 | 180s | ≥ ACCEPT | 验收核心项 |
| 7 | 随机写 randwrite | `randwrite` | 256k | 128 | 180s | ≥ ACCEPT | 验收核心项 |
| 8 | 随机读写 randrw | `randrw` | 256k | 128 | 180s | R/W 各 ≥ ACCEPT | 混合读写，最难点 |

---

## 二、JuiceFS 卷生命周期命令

### 2.1 format（直连 RADOS，生产口径）

```bash
juicefs format \
  --storage ceph \
  --bucket "ceph://${POOL}" \
  --access-key ceph \
  --secret-key "${CEPHX}" \
  --block-size 256K \
  --trash-days 0 \
  "${META}" \
  juicefs-prod
```

> `--access-key ceph` = Ceph 集群名；`--secret-key client.juicefs` = cephx 用户名（keyring 在 `/etc/ceph/ceph.client.juicefs.keyring`）。
> `--block-size 256K` 是核心调优结论（`doc/perf-analysis/08_2`：消 16× 读放大）。

### 2.2 mount — 冷态基线（cache=0 + ra0，全项达标口径）

```bash
juicefs mount -d \
  --storage ceph --bucket "ceph://${POOL}" \
  --access-key ceph --secret-key "${CEPHX}" \
  --block-size 256K \
  --max-uploads 150 \
  --cache-size 0 \
  --max-readahead 0 \
  "${META}" "${MNT}"
```

> `--max-readahead 0` 是 randread/randrw 达标的关键开关：默认预读（2 MiB）对 128 job 随机读造成 2.02× 投机预取放大（object GET 111 MB/s 但 fio 有效仅 55.7），关预读后放大降至 ~1.0×，randread 55.7→112.2（+103%）、randrw 48.6→76.1（+57%）。写类不受影响。
> 副作用：单流顺序读 -33%（103→69，预读流水线消失），但多线程顺序读不受影响（16 job 仍 112）。按主负载选配——随机/混合为主必须关；纯顺序单流读为主可保留默认。
> **JuiceFS 版本**：必须含 loadRange 修复（commit eaf3d21f），否则 2× 读放大 bug 叠加预读，ra0 效果被掩盖。见 §0 版本要求。

### 2.3 mount — 暖态（cache=100G + ra0，需缓存盘）

```bash
juicefs mount -d \
  --storage ceph --bucket "ceph://${POOL}" \
  --access-key ceph --secret-key "${CEPHX}" \
  --block-size 256K \
  --max-uploads 150 \
  --cache-size 102400 --cache-dir "${CACHE_DIR}" \
  --max-readahead 0 \
  "${META}" "${MNT}"
```

> `--max-readahead 0`：消除预读 2.02× 随机读放大（`doc/perf-analysis/12` §三）。冷态下是 seqread↔randread 零和，按主负载选。
> `--writeback` 仅突发写负载（如 AI checkpoint）且有独立缓存盘时追加。staging 空间由 `--free-space-ratio`（默认 0.1）控制，不受 `--cache-size` 约束。

### 2.4 warmup（暖态热读口径，预热缓存）

```bash
juicefs warmup "${TEST_DIR}"
```

### 2.5 unmount / destroy

```bash
# unmount
fusermount -u "${MNT}" 2>/dev/null || fusermount -uz "${MNT}" 2>/dev/null || umount -l "${MNT}"

# destroy（删元数据 + RADOS 对象，等 session TTL ~65s）
UUID=$(juicefs status "${META}" | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
juicefs destroy "${META}" "${UUID}" --yes
```

---

## 三、环境净化命令（每项跑前）

### 3.1 drop 客户端缓存（冷态必做）

```bash
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
# 清 JuiceFS 本地读缓存（暖态测试跳过此步）
[ -d "${CACHE_DIR}" ] && find "${CACHE_DIR}" -type f -path '*raw*' -delete 2>/dev/null
```

### 3.2 OSD compaction cooldown（高强度写后必做）

```bash
FSID=$(sudo ceph fsid)
OSD_IDS=$(sudo ceph osd ls)
# 强制 compact 清残余状态（restart OSD 不清积压，必须 compact）
for osd_id in ${OSD_IDS}; do
  ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
  [ -S "$ASOK" ] || continue   # admin socket per-node，跨节点需 ssh
  sudo ceph --admin-daemon "$ASOK" compact
done
# 轮询直到 compact_running=0
while true; do
  all_done=true
  for osd_id in ${OSD_IDS}; do
    ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
    [ -S "$ASOK" ] || continue
    running=$(sudo ceph --admin-daemon "$ASOK" perf dump | \
      python3 -c "import sys,json;print(json.load(sys.stdin).get('rocksdb',{}).get('compact_running',1))")
    [ "$running" != "0" ] && all_done=false
  done
  $all_done && break
  sleep 5
done
```

> 干净态判据：`compact_queue_len=0` + `compact_running=0` + `kv_sync_lat avg<2ms`（见 TESTING-GUIDE §1.3）。

---

## 四、顺序测试项命令

> 顺序读 bs=256K（与 JuiceFS block-size 对齐）；顺序写 bs=4M（大块写吞吐）。
> 所有项加 `--write_bw_log --log_avg_msec=1000` 采逐秒瞬时带宽（§8 稳态中位数计算用）。
> 顺序读用 `--time_based --runtime=180`（固定时长，非固定数据量——4G 太短，稳态样本不够）。

### 4.1 顺序读 seqread

```bash
# prep：写 4G 数据（冷态读前必须有数据）
mkdir -p "${TEST_DIR}"
fio --name=prep --directory="${TEST_DIR}/" --rw=write --bs=4M --size=4G >/dev/null 2>&1
# drop_caches 后冷读
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
fio --name=seqread --directory="${TEST_DIR}/" \
    --rw=read --refill_buffers --bs=256k --size=4G \
    --direct=1 --ioengine=psync --iodepth=1 \
    --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/seqread" --log_avg_msec=1000
```

> seqread 单线程 psync iodepth=1：吞吐受单请求往返延迟限（clat ~3.6ms → 256K/3.6ms ≈ 71 MB/s），无法打满网卡。
> 这是并发度限制，非 JuiceFS 特性——同配置 16 job multi-seqread 可打满网卡（见 4.4）。

### 4.2 顺序写 seqwrite（fsync 版）

```bash
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --name=seqwrite --directory="${TEST_DIR}/" \
    --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 \
    --direct=1 --ioengine=psync --iodepth=1 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/seqwrite" --log_avg_msec=1000
```

### 4.3 顺序写 seqwrite（nofsync 版）

```bash
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --name=seqwrite --directory="${TEST_DIR}/" \
    --rw=write --refill_buffers --bs=4M --size=4G \
    --direct=1 --ioengine=psync --iodepth=1 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/seqwrite-nofsync" --log_avg_msec=1000
```

### 4.4 多线程读 mseqread（16 job）

```bash
# prep：16 job 各写 4G
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --name=prep --directory="${TEST_DIR}/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
fio --name=mseqread --directory="${TEST_DIR}/" \
    --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting \
    --direct=1 --ioengine=psync --iodepth=1 \
    --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/mseqread" --log_avg_msec=1000
```

### 4.5 多线程写 mseqwrite（16 job）

```bash
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --name=mseqwrite --directory="${TEST_DIR}/" \
    --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting \
    --direct=1 --ioengine=psync --iodepth=1 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/mseqwrite" --log_avg_msec=1000
```

---

## 五、布局写 layout（randread 预铺数据，128G）

```bash
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none \
    --direct=1 --ioengine=libaio --iodepth=128 \
    --group_reporting --end_fsync=1 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/layout" --log_avg_msec=1000
```

> 128 jobs × 1G = 128G 工作集。目的：randread 读真实冷数据（不是 short read 空转）。
> 生产规模：layout 大小须 > 暖态 cache-size 保证冷态真冷（见 TESTING-GUIDE §3.1）。
> layout 后**必须**跑 §3.2 compact cooldown 再开始随机测试。

---

## 六、随机测试项命令（验收核心）

> 所有随机项 `--bs=256k` 对齐 JuiceFS block-size，`--direct=1` 绕页缓存。
> **注意**：`--direct=1` 绕不开 JuiceFS 客户端写缓冲，写类 fio 平均 BW 会虚高（见 §8 + TESTING-GUIDE §5.6）。

### 6.1 随机读 randread（验收口径，复用 layout）

```bash
# 复用 §5 layout 的文件（同 --name/--numjobs/--filesize），只读不建
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/randread" --log_avg_msec=1000
```

> 跑前：冷态 drop_caches（§3.1）+ layout cooldown（§3.2）；暖态 warmup（§2.4）。
> `--openfiles=128`：必须 = numjobs（显式声明，防止遗漏导致假瓶颈）。
> REPEAT=3（冷态取 r1）/ 7（暖态看收敛），取稳态中位数（§8）。

### 6.2 随机写 randwrite（验收口径，fresh volume + 自建文件）

```bash
# 每次跑前 fresh volume（destroy→format→mount），确保全新空卷
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --nrfiles=100 --filesize=1G --size=1G \
    --bs=256k --rw=randwrite \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/randwrite" --log_avg_msec=1000
```

> `--create_on_open=1 --nrfiles=100`：自建 100 个文件，测真随机写（非覆写已有数据）。
> `--openfiles=128`：必须 = numjobs。旧值 100 会导致 28 个 job 排队等 fd（BeeGFS 单变量对照实验证实 +507% 假瓶颈，详见 `beegfs-production/results/20260707-beegfs-cold-baseline-v2/evidence/control-experiment-conclusion.md`）。

### 6.3 随机读写 randrw（验收口径，fresh volume + 自建文件）

```bash
# 每次跑前 fresh volume
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --nrfiles=100 --filesize=1G --size=1G \
    --bs=256k --rw=randrw \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/randrw" --log_avg_msec=1000
```

> randrw 是最难点（读写争抢 + 协议开销，历史所有调参手段无效，关预读后才达标，见 `doc/perf-analysis/12` §三）。
> `--openfiles=128`：同 §6.2，必须 = numjobs。

### 6.4 随机写/读写 analysis 版（复用 layout，隔离文件创建开销）

```bash
# randwrite analysis（复用 §5 layout，不 fresh_volume、不 create_on_open）
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randwrite \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/randwrite-analysis" --log_avg_msec=1000

# randrw analysis（同上，改 --rw=randrw）
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randrw \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/randrw-analysis" --log_avg_msec=1000
```

> analysis 版目的：消除文件创建开销，测已有数据上的稳态随机写/读写，便于调参对比。
> `--openfiles=128`：同 §6.2，必须 = numjobs（旧值 100 已废止）。

---

## 七、后端裸测命令（L1 定位，绕开 JuiceFS/FUSE）

> 目的：在 RADOS 池直接跑 256K 随机读，算"放大倍数 = NIC RX ÷ 有效读带宽"，
> 与 JuiceFS randread 的 ~2.5× 对照，切分"放大在 librados/EC 层"还是"JuiceFS 内部"。
> 详见 `doc/perf-analysis/10_3` / `bench-rados-256k-rand.sh`。

```bash
# 从干净客户端节点发起（非 OSD 主机，否则 RX/TX 混算）
# 对象大小 -b 262144(=256K) 必须与 JuiceFS 256K 卷对齐

# 1. prefill：垫够 256K 对象（write --no-cleanup），保证 rand 读到真实冷数据
rados bench -p "${POOL}" 120 write -b 262144 -t 16 --no-cleanup --run-name rados-l1

# 2. rand：256K 随机读（-t 并发，扫 16 / 128 两档）
rados bench -p "${POOL}" 60 rand -t 128 --run-name rados-l1

# 3. cleanup：删 prefill 写的对象
rados -p "${POOL}" cleanup --run-name rados-l1
```

> 同时采发起节点 NIC RX（`/proc/net/dev` 或 `iftop`），算放大 = NIC_RX_MBps ÷ rados_bench_有效读_MBps。
> L1 ≈ 1.0× → 放大在 JuiceFS 内部；L1 ≈ 2.5× → 放大在 librados/EC/网络层。

---

## 八、稳态中位数采集与数据处理（所有项必做）

### 8.1 为什么不能看 fio 平均 BW

fio 报的 **平均** BW（`bw=`行）会被以下两种暂态污染：

1. **客户端写缓冲暂态**（写类）：测试开头几秒写进 JuiceFS 内存缓冲即返回，fio 以为写完，瞬时 bw 冲到 ~485 MiB/s（远超网卡线速），缓冲填满后跌落到真实稳态。全程平均被暂态拉高 7-8%，曾报 120-127 MB/s 超千兆物理上限（~118），是假象。
2. **冷启动暂态**（读类）：开头几秒 OSD 缓存/连接池未热，带宽偏低或偏高。

**达标值 = fio 瞬时带宽稳态段中位数**，不是全程平均/最大。

### 8.2 采集方法

所有 fio 命令统一加 `--write_bw_log=<prefix> --log_avg_msec=1000`：

> **注意**：fio 3.28 无 `--read_bw_log` 选项。`--write_bw_log` 对**所有 I/O 类型**（read/write/randread/randwrite/randrw）都生效。bw_log 文件内每行有 `data_direction` 列（0=read, 1=write），用于区分读写方向。

```bash
# 所有 fio 命令追加（已在 §4-§6 各命令中嵌入）：
--write_bw_log="${JUICEFS_BW_LOG_DIR}/<item>" --log_avg_msec=1000
```

生成文件：`<prefix>_bw.<job_id>.log`（128 job → 128 个文件）。格式：`timestamp_ms, bw_kibps, data_direction`。

### 8.3 数据处理：稳态中位数

```bash
# 单 job 项（seqread/seqwrite，1 个 bw_log 文件）：
python3 -c "
import statistics
vals = [float(l.split(',')[1]) for l in open('${JUICEFS_BW_LOG_DIR}/seqread_bw.1.log')]
# 截掉开头 1/4 缓冲暂态，取剩余中位数（KiB/s → MB/s）
steady = vals[len(vals)//4:]
print(round(statistics.median(steady)/1024, 1), 'MB/s')
"

# 128 job 项（randread/randwrite/randrw，128 个 bw_log 文件）：
# 按时间戳对齐求和所有 job 的逐秒带宽，再按 data_direction 分开（randrw 有读有写），
# 截缓冲暂态后取稳态中位数
python3 -c "
import glob, statistics
from collections import defaultdict

ts_dir = defaultdict(lambda: [0, 0])  # {sec: [read_bw, write_bw]} KiB/s
for f in glob.glob('${JUICEFS_BW_LOG_DIR}/randread-r1_bw.*.log'):
    for line in open(f):
        parts = line.strip().split(',')
        sec = int(parts[0]) // 1000  # fio bw_log 时间戳是毫秒，必须按整秒归桶
        bw = float(parts[1])         # 否则各 job 毫秒抖动(4999 vs 5000)会分散归桶，128-job 聚合被严重低估
        d = int(parts[2])  # 0=read, 1=write
        ts_dir[sec][d] += bw

# randread 只有 read(d=0)；randrw 有 read(d=0)+write(d=1)
read_vals = [v[0] for v in sorted(ts_dir.values())]
write_vals = [v[1] for v in sorted(ts_dir.values()) if v[1] > 0]

# 截掉开头 1/4 缓冲暂态，取中位数（KiB/s → MB/s）
n = len(read_vals)
if read_vals:
    print('R:', round(statistics.median(read_vals[n//4:])/1024, 1), 'MB/s')
if write_vals:
    print('W:', round(statistics.median(write_vals[n//4:])/1024, 1), 'MB/s')
"
```

> **128 job 聚合要点**：不能对 128 个文件分别取中位数再平均（会丢失并发效应），必须按时间戳对齐求和后再取中位数。**时间戳按整秒归桶（`ms//1000`），不能用原始毫秒**——各 job 的毫秒时间戳有抖动（如 4999 vs 5000），直接用毫秒当 key 会把同一秒的值分散到不同桶，导致 128-job 聚合被严重低估（实测低估数十倍）。
> randrw 的 bw_log 同时含 read(d=0) 和 write(d=1) 行，按 data_direction 分开后各自取中位数。

### 8.4 红线

- 任何 fio 平均 BW 超单客户端网卡线速（千兆限速≈124 / 100GbE TCP≈12500 MiB/s）必是假象，**不认**，改取 bw_log 稳态中位数。
- 达标判定只看**稳态中位数**，不看 fio 报告的 `bw=` 平均值。
- 多轮测试取各轮稳态中位数的最高值（MAX 口径）或均值，需标注口径。

---

## 九、数据采集与保存规范（每项 fio 必做）

> 目的：保证测试过程和数据可追溯。每个测试项的产出必须包含以下 5 类文件，存入 `${RESULTS_DIR}/<item>/`。

### 9.1 fio 原始输出

```bash
# fio 命令 stdout 重定向到文件
fio ... 2>&1 | tee "${RESULTS_DIR}/<item>/fio-<item>.txt"
```

保存：fio 完整终端输出（含 IOPS、BW、clat 分布、latency percentiles 等）。

### 9.2 bw_log 文件（逐秒瞬时带宽）

```bash
# fio 自动生成到 ${JUICEFS_BW_LOG_DIR}/，测后拷贝到结果目录
cp ${JUICEFS_BW_LOG_DIR}/<prefix>_bw.*.log "${RESULTS_DIR}/<item>/"
```

保存：所有 job 的 `*_bw.<job_id>.log` 文件（128 job → 128 个文件）。用于 §8 稳态中位数计算。

### 9.3 NIC 监控（网卡逐秒 RX/TX）

```bash
# 在 fio 启动前后台采，fio 结束后停
NIC_IF="<网卡名>"  # 限速口径用 eno12409；不限速用 enp139s0f0np0
( while true; do
    echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"
    sleep 1
  done ) > "${RESULTS_DIR}/<item>/nic-<item>-raw.txt" &
NIC_PID=$!
# ... 跑 fio ...
kill ${NIC_PID} 2>/dev/null
```

> 用途：验证 fio 有效带宽 ≤ NIC 物理带宽（三者关系：fio ≤ NIC ≤ object）。NIC RX/TX 可算协议开销和读放大。

### 9.4 juicefs stats（JuiceFS 内部计数器）

```bash
# 在 fio 启动前后台采，每秒一行
JFS_PID=$(pgrep -f 'juicefs.*mount')
( while true; do
    echo "------ $(date +%H:%M:%S) ------"
    sudo cat /proc/${JFS_PID}/status | grep -E 'VmRSS|Threads' 2>/dev/null
    juicefs stats "${MNT}" 2>/dev/null || true
    sleep 1
  done ) > "${RESULTS_DIR}/<item>/jfs-stats-<item>.txt" &
STATS_PID=$!
# ... 跑 fio ...
kill ${STATS_PID} 2>/dev/null
```

> 用途：FUSE ops/lat、meta ops/lat、object GET/PUT 带宽——用于算读/写放大 = object / fio 有效带宽。

### 9.5 JuiceFS 进程 CPU（pidstat）

```bash
JFS_PID=$(pgrep -f 'juicefs.*mount')
pidstat -p ${JFS_PID} 1 > "${RESULTS_DIR}/<item>/jfs-proc-<item>.txt" &
PIDSTAT_PID=$!
# ... 跑 fio ...
kill ${PIDSTAT_PID} 2>/dev/null
```

> 用途：观察 JuiceFS 进程 CPU 占用，判断是否 CPU-bound。

### 9.6 结果目录结构（每个测试项必须包含）

```
${RESULTS_DIR}/
├── seqread/
│   ├── fio-seqread.txt           # §9.1
│   ├── seqread_bw.1.log          # §9.2
│   ├── nic-seqread-raw.txt       # §9.3
│   ├── jfs-stats-seqread.txt     # §9.4
│   └── jfs-proc-seqread.txt      # §9.5
├── seqwrite/
│   └── ...
├── randread-r1/
│   ├── fio-randread-r1.txt
│   ├── randread-r1_bw.1.log ~ _bw.128.log   # 128 个文件
│   ├── nic-randread-r1-raw.txt
│   ├── jfs-stats-randread-r1.txt
│   └── jfs-proc-randread-r1.txt
└── ...
```

---

## 十、典型测试序列（端到端一例）

冷态基线全量（从空卷到销毁）：

```bash
# 0. 环境净化
sudo ceph health                                     # 必须 HEALTH OK
# （高强度写后）跑 §3.2 compact cooldown

# 1. format + mount（冷态 + ra0）
#   §2.1 format
#   §2.2 mount（cache=0 + ra0）

# 2. 顺序五项（每项跑前 drop_caches §3.1，采 NIC + jfs-stats + pidstat §9）
#   §4.1 seqread（bs=256k, 180s）
#   §4.2 seqwrite fsync
#   §4.3 seqwrite nofsync（可选）
#   §4.4 mseqread（bs=256k, 16 job, 180s）
#   §4.5 mseqwrite（bs=4M, 16 job）

# 3. layout 预铺 128G
#   §5 layout
#   §3.2 compact cooldown（layout 后必做）

# 4. 随机三项（复用 layout，每项 REPEAT=3，每轮采全部数据 §9）
#   drop_caches（§3.1）
#   §6.1 randread ×3（180s each）
#   §6.4 randwrite analysis ×3
#   §6.4 randrw analysis ×3
#   每轮间：删 test_dir + gc + 等 + 重建 layout（保证净态）

# 5. 验收口径纯随机写/读写（fresh volume，每项 REPEAT=3）
#   §6.2 randwrite（fresh volume + create_on_open）×3
#   §6.3 randrw（fresh volume + create_on_open）×3

# 6. 数据处理
#   对每项跑 §8.3 稳态中位数计算
#   交叉验证：fio ≤ NIC ≤ object（§9.3 + §9.4）

# 7. 销毁
#   §2.5 destroy
```

> 暖态全量：mount 改 §2.3（cache=100G + ra0），randread 前用 §2.4 warmup，不 drop_caches、不 fresh volume、复用 layout 卷。
> 每项预计耗时：180s fio + ~30s 数据采集/处理 ≈ 4min；128 job 项 ×3 轮 ≈ 12min/项。

---

## 十一、命令记录规范（每个测试结果目录必含 commands.sh）

```bash
#!/bin/bash
# 完整命令记录：<测试名称>
# 日期：<日期>
# 验收线：<ACCEPT>
# JuiceFS 版本：<juicefs --version>

# ---- 格式化 ----
juicefs format ...

# ---- 挂载 ----
juicefs mount ...

# ---- 顺序测试 ----
fio --name=seqread ...

# ---- 随机测试 ----
fio --name=randread ...
```

> 必须记录：format/mount 完整参数 + 每个 fio 完整参数（bs/rw/size/numjobs/ioengine/iodepth/direct 等）+ 环境特殊操作（drop_caches/compact）。
> 目的：仅凭 commands.sh 即可复现整个测试，不依赖脚本（脚本可能漏参数）。详见 TESTING-GUIDE §10。
