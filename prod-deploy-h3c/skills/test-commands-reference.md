# 测试命令参考手册（H3C 对比口径）

> 本文整合 4 项 H3C 对比测试的**完整可执行命令**，便于不依赖脚本即可复现。
> 配套方法论（health 检查/cooldown/可靠性判据）见同目录 `TESTING-GUIDE.md`。

---

## 〇、环境变量与通用约定

```bash
# 按实际环境填（对应 config.sh）
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-h3c"
EPC_MOUNT="/mnt/epc"                          # JuiceFS 挂载点（H3C 对比口径）
TESTFILE="${EPC_MOUNT}/testfile1"             # fio 测试文件
EPC_20GFILE="${EPC_MOUNT}/20Gfile"            # cp 读测试文件（预放好的 20G 文件）
CP_LOCAL_DIR="/mnt/jfs-cache"                 # cp 本地端（nvme1n1，非 /tmp：避 WekaIO 内存/带宽竞争 + tmpfs 红线）
TMP_20GFILE="${CP_LOCAL_DIR}/20Gfile"         # cp 写测试文件（本地端 20G 文件）
CP_READ_DST="${CP_LOCAL_DIR}/20Gfile.cpread"  # cp 读的目标（独立名，防误删 cp 写源文件）
POOL="juicefs-data"
CEPHX="client.juicefs"
RESULTS_DIR=""                                # 测试结果保存目录
```

---

## 一、测试项总表

| # | 测试项 | 命令 | bs | runtime | 说明 |
|---|--------|------|-----|---------|------|
| 1 | cp 读 | `time cp ${EPC_20GFILE} ${CP_READ_DST}` | — | — | 文件级顺序读（20G，本地端走 nvme1n1） |
| 2 | cp 写 | `time cp ${TMP_20GFILE} ${EPC_MOUNT}/` | — | — | 文件级顺序写（20G） |
| 3 | fio 顺序读 | `fio --bs=20M --rw=read ...` | 20M | 60s | 块级顺序读（10G, direct） |
| 4 | fio 顺序写 | `fio --bs=16M --rw=write ...` | 16M | 120s | 块级顺序写（10G, direct） |

---

## 二、JuiceFS 卷生命周期命令

### 2.1 format

```bash
juicefs format \
  --storage ceph \
  --bucket "ceph://${POOL}" \
  --access-key ceph \
  --secret-key "${CEPHX}" \
  --block-size 4M \
  --trash-days 0 \
  --force \
  "${META}" \
  juicefs-h3c
```

### 2.2 mount

```bash
juicefs mount -d \
  --storage ceph --bucket "ceph://${POOL}" \
  --access-key ceph --secret-key "${CEPHX}" \
  --block-size 4M \
  --max-fuse-io 1M \
  --buffer-size 1024 \
  --max-uploads 150 \
  --cache-size 0 \
  --max-readahead 8M \
  "${META}" "${EPC_MOUNT}"
# 挂载后验证 max-fuse-io 生效（应显示 max_read = 1048576）
CONN=$(mount | grep "${EPC_MOUNT}" | grep -o 'dev=[0-9:]*' | head -1)
# 或：ls /sys/fs/fuse/connections/ 找到新连接，cat .../max_read
```

### 2.3 unmount / destroy

```bash
# unmount
fusermount -u "${EPC_MOUNT}" 2>/dev/null || fusermount -uz "${EPC_MOUNT}" 2>/dev/null || umount -l "${EPC_MOUNT}"

# destroy（等 session TTL ~65s）
UUID=$(juicefs status "${META}" | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
juicefs destroy "${META}" "${UUID}" --yes
```

---

## 三、环境净化命令（每项跑前）

### 3.1 drop 客户端缓存

```bash
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
```

### 3.2 OSD compaction cooldown（写后必做）

```bash
FSID=$(sudo ceph fsid)
OSD_IDS=$(sudo ceph osd ls)
for osd_id in ${OSD_IDS}; do
  ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
  [ -S "$ASOK" ] || continue
  sudo ceph --admin-daemon "$ASOK" compact
done
# 轮询直到 compact_running=0
```

---

## 四、测试 1：cp 读（storage → 本地缓存盘 CP_LOCAL_DIR）

```bash
# 前置：确保 20Gfile 已在挂载点
ls -lh "${EPC_20GFILE}"   # 应显示 ~20G

# 清缓存
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches

# 执行（目标用独立名 CP_READ_DST，避免与 cp 写的源文件同名）
time cp "${EPC_20GFILE}" "${CP_READ_DST}"

# 清理（只删副本，绝不删 cp 写的源文件 TMP_20GFILE）
rm -f "${CP_READ_DST}"
```

> cp 读测的是文件级顺序读吞吐。`time` 输出的 real 时间是关键指标，
> 带宽 = 20G / real_seconds。
> cp 使用 page cache（不绕缓存），这是真实应用场景。

---

## 五、测试 2：cp 写（本地缓存盘 CP_LOCAL_DIR → storage）

```bash
# 前置：确保 20Gfile 已在本地缓存盘
ls -lh "${TMP_20GFILE}"   # 应显示 ~20G

# 清缓存
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches

# 执行
time cp "${TMP_20GFILE}" "${EPC_MOUNT}/"

# 清理
rm -f "${EPC_MOUNT}/20Gfile"
```

> cp 写测的是文件级顺序写吞吐。带宽 = 20G / real_seconds。
> JuiceFS 写缓冲可能让 cp 写的开头几秒很快（数据吸入内存缓冲），
> 但 20G 数据量足够大，缓冲占比小，`time` 的 real 时间仍能反映真实吞吐。

---

## 六、测试 3：fio 顺序读（bs=20M, 60s）

```bash
# 清缓存
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches

# 执行
fio --name=seq_read \
    --filename="${TESTFILE}" \
    --size=10G \
    --bs=20M \
    --rw=read \
    --direct=1 \
    --numjobs=1 \
    --runtime=60 \
    --time_based \
    --group_reporting
```

> `--direct=1`：绕开内核页缓存（但绕不开 JuiceFS 客户端读缓存，--cache-size 0 时无客户端缓存）。
> `--bs=20M`：大块顺序读，最大化吞吐。
> `--numjobs=1`：单线程（与 H3C 同口径）。
> fio 报告的 `READ: bw=` 即为顺序读带宽。

---

## 七、测试 4：fio 顺序写（bs=16M, 120s）

```bash
# 清缓存
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches

# 执行
fio --name=seq_write \
    --filename="${TESTFILE}" \
    --size=10G \
    --bs=16M \
    --rw=write \
    --direct=1 \
    --numjobs=1 \
    --runtime=120 \
    --time_based \
    --group_reporting
```

> `--bs=16M`：大块顺序写。
> `--runtime=120`：写跑 120s（比读长，让写稳态更充分）。
> JuiceFS 写缓冲可能导致开头几秒 BW 虚高。如需精确稳态值，加 `--write_bw_log=<prefix> --log_avg_msec=1000`，
> 测后截掉开头 1/4 取中位数。H3C 对比口径如同样用 fio 平均值，则可直接对比。

---

## 八、数据采集与保存规范

### 8.1 结果目录结构

```
${RESULTS_DIR}/
├── env-snapshot.txt           # 环境快照
├── commands.sh                # 完整命令记录
├── cp-read-r1/
│   ├── cp-time.txt            # time cp 输出
│   ├── nic-raw.txt            # NIC 逐秒 RX/TX
│   └── jfs-stats.txt          # JuiceFS 内部计数器
├── cp-write-r1/
│   └── ...
├── fio-seq-read-r1/
│   ├── fio-seq-read.txt       # fio 完整输出
│   ├── nic-raw.txt
│   └── jfs-stats.txt
├── fio-seq-write-r1/
│   └── ...
└── summary.md                 # 汇总（手写）
```

### 8.2 NIC 监控

```bash
NIC_IF="${PUBLIC_NIC}"
( while true; do
    echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"
    sleep 1
done ) > "${RESULTS_DIR}/<item>/nic-raw.txt" &
NIC_PID=$!
# ... 跑测试 ...
kill ${NIC_PID} 2>/dev/null
```

### 8.3 JuiceFS stats

```bash
( while true; do
    echo "------ $(date +%H:%M:%S) ------"
    juicefs stats "${EPC_MOUNT}" 2>/dev/null || true
    sleep 1
done ) > "${RESULTS_DIR}/<item>/jfs-stats.txt" &
STATS_PID=$!
# ... 跑测试 ...
kill ${STATS_PID} 2>/dev/null
```

---

## 九、典型测试序列

```bash
# 0. 环境检查
sudo ceph health                                     # 必须 HEALTH OK

# 1. format + mount
#   §2.1 format
#   §2.2 mount

# 2. 准备测试文件
#   20Gfile（存储端）：dd if=/dev/zero of=${EPC_20GFILE} bs=4M count=5120
#   20Gfile（本地端）：dd if=/dev/zero of=${TMP_20GFILE} bs=4M count=5120

# 3. 4 项测试（每项跑前 drop_caches §3.1，采 NIC + jfs-stats §8）
#   §4 cp 读
#   §5 cp 写
#   §6 fio 顺序读
#   §7 fio 顺序写
#   写后 compact cooldown（§3.2）

# 4. REPEAT=3 取中位数

# 5. 销毁（可选）
#   §2.3 destroy
```

> 一键执行：`bash scripts/tests/h3c-4item-test.sh --repeat 3 --label h3c-baseline`

---

## 十、命令记录规范

```bash
#!/bin/bash
# 完整命令记录：<测试名称>
# 日期：<日期>
# JuiceFS 版本：<juicefs --version>

# ---- 格式化 ----
juicefs format ...

# ---- 挂载 ----
juicefs mount ...

# ---- 测试 1: cp 读 ----
time cp ${EPC_20GFILE} ${CP_READ_DST}

# ---- 测试 2: cp 写 ----
time cp ${TMP_20GFILE} ${EPC_MOUNT}/

# ---- 测试 3: fio 顺序读 ----
fio --name=seq_read --filename=${TESTFILE} --size=10G --bs=20M --rw=read --direct=1 --numjobs=1 --runtime=60 --time_based --group_reporting

# ---- 测试 4: fio 顺序写 ----
fio --name=seq_write --filename=${TESTFILE} --size=10G --bs=16M --rw=write --direct=1 --numjobs=1 --runtime=120 --time_based --group_reporting
```
