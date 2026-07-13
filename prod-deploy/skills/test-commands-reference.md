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
```

**通用口径（所有随机项）：**
- `--bs=256k`：与 JuiceFS `--block-size 256K` 对齐，消 16× 读放大（见 `doc/perf-analysis/08_2`）
- `--ioengine=libaio --iodepth=128`：异步 IO，深度 128
- `--numjobs=128`：128 并发 job
- `--direct=1`：绕开内核页缓存（但绕不开 JuiceFS 客户端缓冲，见 TESTING-GUIDE §5.6）
- `--time_based --runtime=60s`：时间基准，跑满 60s
- `--group_reporting`：多 job 合并上报
- 随机项 REPEAT=3（冷态）或 7（暖态看收敛），取稳态中位数（见 §8）

---

## 一、测试项总表

| # | 测试项 | fio --rw | bs | numjobs | 验收口径 | 说明 |
|---|--------|----------|-----|---------|---------|------|
| 1 | 顺序读 seqread | `read` | 4M | 1 | ≥ ACCEPT | 单流大块顺序读 |
| 2 | 顺序写 seqwrite | `write` | 4M | 1 | ≥ ACCEPT | 单流大块顺序写（fsync/nofsync 两版） |
| 3 | 多线程读 mseqread | `read` | 4M | 16 | ≥ ACCEPT | 16 job 并发顺序读 |
| 4 | 多线程写 mseqwrite | `write` | 4M | 16 | ≥ ACCEPT | 16 job 并发顺序写 |
| 5 | 布局写 layout | `write` | 4M | 128 | — | 预铺 128G 数据供 randread 复用 |
| 6 | 随机读 randread | `randread` | 256k | 128 | ≥ ACCEPT | 验收核心项 |
| 7 | 随机写 randwrite | `randwrite` | 256k | 128 | ≥ ACCEPT | 验收核心项 |
| 8 | 随机读写 randrw | `randrw` | 256k | 128 | R/W 各 ≥ ACCEPT | 混合读写，最难点 |

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

### 2.2 mount — 冷态基线（cache=0，环境无关）

```bash
juicefs mount -d \
  --storage ceph --bucket "ceph://${POOL}" \
  --access-key ceph --secret-key "${CEPHX}" \
  --block-size 256K \
  --max-uploads 150 \
  --cache-size 0 \
  "${META}" "${MNT}"
```

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

> 顺序项 bs=4M（与 JuiceFS 256K block 不对齐——故意测大块顺序吞吐，非对齐场景）。
> 顺序读为**热读口径**：先写 4G 再读（4G << cache，数据在缓存内）；冷读后端用 drop_caches 后直接读。

### 4.1 顺序读 seqread

```bash
# 热读口径（先写 4G 再读）
mkdir -p "${TEST_DIR}"
fio --name=prep --directory="${TEST_DIR}/" --rw=write --bs=4M --size=4G >/dev/null 2>&1
fio --name=sequential-read --directory="${TEST_DIR}/" \
    --rw=read --refill_buffers --bs=4M --size=4G
```

### 4.2 顺序写 seqwrite（fsync 版）

```bash
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --name=sequential-write --directory="${TEST_DIR}/" \
    --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1
```

### 4.3 顺序写 seqwrite（nofsync 版）

```bash
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --name=sequential-write --directory="${TEST_DIR}/" \
    --rw=write --refill_buffers --bs=4M --size=4G
```

### 4.4 多线程读 mseqread（16 job）

```bash
# prep：16 job 各写 4G
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --name=prep --directory="${TEST_DIR}/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
fio --name=big-file-multi-read --directory="${TEST_DIR}/" \
    --rw=read --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting
```

### 4.5 多线程写 mseqwrite（16 job）

```bash
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --name=big-file-multi-write --directory="${TEST_DIR}/" \
    --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting
```

---

## 五、布局写 layout（randread 预铺数据，128G）

```bash
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none \
    --group_reporting --end_fsync=1
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
    --direct=1 --fallocate=none \
    --group_reporting --time_based --runtime=60s
```

> 跑前：冷态 drop_caches（§3.1）+ layout cooldown（§3.2）；暖态 warmup（§2.4）。
> REPEAT=3（冷态取 r1）/ 7（暖态看收敛），取稳态中位数（§8）。

### 6.2 随机写 randwrite（验收口径，fresh volume + 自建文件）

```bash
# 每次跑前 fresh volume（destroy→format→mount），确保全新空卷
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --nrfiles=100 --filesize=1G --size=1G \
    --bs=256k --rw=randwrite \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
    --group_reporting --time_based --runtime=60s
```

> `--create_on_open=1 --nrfiles=100`：自建 100 个文件，测真随机写（非覆写已有数据）。

### 6.3 随机读写 randrw（验收口径，fresh volume + 自建文件）

```bash
# 每次跑前 fresh volume
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --nrfiles=100 --filesize=1G --size=1G \
    --bs=256k --rw=randrw \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
    --group_reporting --time_based --runtime=60s
```

> randrw 是最难点（读写争抢 + 协议开销，历史所有调参手段无效，关预读后才达标，见 `doc/perf-analysis/12` §三）。

### 6.4 随机写/读写 analysis 版（复用 layout，隔离文件创建开销）

```bash
# randwrite analysis（复用 §5 layout，不 fresh_volume、不 create_on_open）
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randwrite \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 \
    --group_reporting --time_based --runtime=60s

# randrw analysis（同上，改 --rw=randrw）
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randrw \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 \
    --group_reporting --time_based --runtime=60s
```

> analysis 版目的：消除文件创建开销，测已有数据上的稳态随机写/读写，便于调参对比。

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

## 八、稳态中位数采集（写类必做，避免缓冲暂态假象）

> fio 写类平均 BW 会因客户端写缓冲虚高（可超网卡线速，物理不可能）。
> 达标值取 **fio 瞬时带宽稳态段中位数**，不是全程平均/最大（TESTING-GUIDE §5.6）。

```bash
# 写类加 bw_log（每秒一个瞬时带宽点）
fio ... [其他参数] \
    --write_bw_log=/tmp/jfs-bw --log_avg_msec=1000

# 读类同理用 --read_bw_log
fio ... [其他参数] \
    --read_bw_log=/tmp/jfs-bw --log_avg_msec=1000

# 测完对逐秒序列（/tmp/jfs-bw_bw.1.log）截掉开头缓冲暂态段，取中位数：
python3 -c "
import sys
vals=[float(l.split(',')[1]) for l in open('/tmp/jfs-bw_bw.1.log')]
# 截掉开头 1/4 缓冲暂态，取剩余中位数（KiB/s → MB/s）
import statistics
print(round(statistics.median(vals[len(vals)//4:])/1024, 1), 'MB/s')
"
```

> **红线**：任何 fio 平均 BW 超单客户端网卡线速（千兆限速≈124 / 100GbE TCP≈12500 MiB/s）必是假象，不认。

---

## 九、典型测试序列（端到端一例）

冷态基线全量（最常用，从空卷到销毁）：

```bash
# 0. 环境净化
sudo ceph health                                     # 必须 HEALTH_OK
# （高强度写后）跑 §3.2 compact cooldown

# 1. format + mount（冷态）
#   §2.1 format
#   §2.2 mount（cache=0）

# 2. 顺序四项
#   §4.1 seqread → §4.2 seqwrite(fsync) → §4.4 mseqread → §4.5 mseqwrite

# 3. layout 预铺 128G
#   §5 layout
#   §3.2 compact cooldown（layout 后必做）

# 4. 随机三项（复用 layout，每项 REPEAT=3 取 r1）
#   drop_caches（§3.1）
#   §6.1 randread ×3
#   §6.4 randwrite analysis ×3
#   §6.4 randrw analysis ×3

# 5. 验收口径纯随机写/读写（fresh volume，每项 REPEAT=3）
#   §6.2 randwrite（fresh volume + create_on_open）×3
#   §6.3 randrw（fresh volume + create_on_open）×3

# 6. 销毁
#   §2.5 destroy
```

> 暖态全量：mount 改 §2.3（cache=100G + ra0），randread 前用 §2.4 warmup，不 drop_caches、不 fresh volume、复用 layout 卷。

---

## 十、命令记录规范（每个测试结果目录必含 commands.sh）

```bash
#!/bin/bash
# 完整命令记录：<测试名称>
# 日期：<日期>
# 验收线：<ACCEPT>

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
