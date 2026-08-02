# JuiceFS 性能测试指导 Skill（H3C 对比口径）

> 目的：保证测试数据可靠、可追溯、可复现。
> 定位：H3C 对比测试的方法论主体。测试项只有 4 项（cp 读/cp 写/fio 顺序读/fio 顺序写），
> 与 prod-deploy 的 9 项全量基线口径不同，但方法论（health/cooldown/可靠性判据/命令记录规范）环境无关。
> **配套命令手册**：各项的完整可执行命令见同目录 `test-commands-reference.md`。

---

## 一、测试前检查清单

### 1.1 集群健康检查（必须）

每次启动测试前，手动确认：

```bash
sudo ceph health          # 必须 HEALTH_OK
sudo ceph osd tree        # 所有 OSD 必须 up
sudo ceph osd stat        # 确认 in 数量正确
```

如果非 HEALTH_OK，**不要开始测试**。先修复问题（重启 OSD、等恢复等）。

### 1.2 BlueFS DB Stall 检查

```bash
sudo ceph health detail | grep -i bluefs
# 如果有 stalled read in db device of BlueFS，需要重启对应 OSD
```

### 1.3 OSD Compaction 状态检查

高强度写后，RocksDB LSM tree 可能膨胀。使用 admin socket 直采：

```bash
FSID=$(sudo ceph fsid)
OSD_IDS=$(sudo ceph osd ls 2>/dev/null)
for osd_id in ${OSD_IDS}; do
  ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
  [ -S "$ASOK" ] || continue
  echo "--- osd.${osd_id} ---"
  sudo ceph --admin-daemon "$ASOK" perf dump | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('rocksdb',{})
print('  compact_queue_len:', r.get('compact_queue_len','N/A'))
print('  compact_running:', r.get('compact_running','N/A'))
"
done
```

**干净态判据**：`compact_queue_len` = 0 + `compact_running` = 0

如果积压未消除，强制 compaction：

```bash
OSD_IDS=$(sudo ceph osd ls 2>/dev/null)
for osd_id in ${OSD_IDS}; do
  ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
  [ -S "$ASOK" ] || continue
  sudo ceph --admin-daemon "$ASOK" compact
done
```

### 1.4 磁盘空间检查

```bash
sudo ceph df
df -h /mnt/jfs-cache      # cp 本地端需有 20G 空间（nvme1n1，非 /tmp）
df -h "${EPC_MOUNT_POINT:-/mnt/epc}"  # 挂载点空间
```

### 1.5 网络检查

```bash
for nic in "${PUBLIC_NIC}" "${CLUSTER_NIC}"; do
  cat /sys/class/net/${nic}/mtu     # 100GbE 应为 4200
  ip link show ${nic} | grep -q 'state UP' && echo "${nic}: UP" || echo "${nic}: DOWN"
done
```

### 1.6 JuiceFS 挂载确认

```bash
mount | grep "${EPC_MOUNT_POINT:-/mnt/epc}"   # 必须已挂载
juicefs --version                              # 确认版本
```

### 1.7 测试文件准备

| 文件 | 位置 | 大小 | 用途 |
|------|------|------|------|
| 20Gfile（存储端） | `${EPC_MOUNT_POINT}/20Gfile` | 20G | cp 读测试（storage → 本地缓存盘） |
| 20Gfile（本地端） | `/mnt/jfs-cache/20Gfile` | 20G | cp 写测试（本地缓存盘 → storage） |

> **本地端一律用 nvme1n1 缓存盘 `/mnt/jfs-cache`（`CP_LOCAL_DIR`），不用 /tmp**：157 上有 WekaIO 业务，/tmp 若为 tmpfs 会撞内存红线并与 WekaIO 争内存/带宽。

如文件不存在，需提前准备（用 dd 或 fio 写入）。

---

## 二、测试中的健康检查（自动）

### 2.1 健康检查库

所有测试脚本 **必须** source 健康检查库：

```bash
source tests/lib/ceph-health-check.sh
```

### 2.2 检查点位置

| 检查点 | 位置 | 说明 |
|--------|------|------|
| 测试开始前 | 环境快照之后 | 确认初始状态 OK |
| 每个测试项前 | 各 test_* 函数内 | 防止集群异常时继续跑 |
| 测试结束后 | 收尾前 | 记录终态 |

---

## 三、写后 Cooldown

### 3.1 问题

fio seq_write 和 cp write 产生写数据，可能导致 RocksDB SST 积压。

### 3.2 规避方法

写测试后，确保 compaction 完成再进入下一项：

```bash
# 强制 compact + 轮询
OSD_IDS=$(sudo ceph osd ls 2>/dev/null)
for osd_id in ${OSD_IDS}; do
  ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
  [ -S "$ASOK" ] || continue
  sudo ceph --admin-daemon "$ASOK" compact
done
# 轮询直到 compact_running=0
```

或简单等待：`sleep 30 + check_ceph_health`

### 3.3 推荐等待时间

| 写入量 | 建议等待 |
|--------|---------|
| < 10G | 30s |
| 10-20G | 60s |
| > 20G | 120s |

---

## 三·五、卷清理

### 3.5.1 问题

多轮测试中数据只增不减，最终导致 OSD 积压、性能退化。

### 3.5.2 清理方式

| 方式 | 删什么 | 用途 |
|------|--------|------|
| `juicefs destroy` | JuiceFS 拥有的 pool 对象 + TiKV 元数据 | 标准清卷 |
| `ceph osd pool delete + create` | 全部 | destroy 失败兜底 |

### 3.5.3 标准清卷流程

```bash
META="<tikv://...>"
MNT="${EPC_MOUNT_POINT:-/mnt/epc}"

# 1. 卸载
juicefs umount "${MNT}"

# 2. 等会话过期
sleep 65

# 3. 提取 UUID → destroy
UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
[ -n "${UUID}" ] && juicefs destroy "${META}" "${UUID}" --yes

# 4. compact cooldown

# 5. format + mount
```

---

## 四、测试项总表

| # | 测试项 | 命令 | bs | runtime | 说明 |
|---|--------|------|-----|---------|------|
| 1 | cp 读 | `time cp /mnt/epc/20Gfile /mnt/jfs-cache/20Gfile.cpread` | — | — | 文件级顺序读 |
| 2 | cp 写 | `time cp /mnt/jfs-cache/20Gfile /mnt/epc/` | — | — | 文件级顺序写 |
| 3 | fio 顺序读 | `fio --bs=20M --rw=read --direct=1 --numjobs=1 --runtime=60` | 20M | 60s | 块级顺序读 |
| 4 | fio 顺序写 | `fio --bs=16M --rw=write --direct=1 --numjobs=1 --runtime=120` | 16M | 120s | 块级顺序写 |

> 与 prod-deploy 的区别：h3c 口径只有 4 项顺序测试，无随机 IO、无 layout 预铺、无 rados bench、无暖态/冷态区分。

---

## 五、测试口径规范

### 5.1 基本口径

- 所有测试在 JuiceFS 挂载点 `${EPC_MOUNT_POINT}`（默认 `/mnt/epc`）上执行
- fio 测试 `--direct=1`：绕开内核页缓存
- cp 测试不绕缓存（cp 用 page cache，这是文件级真实场景）
- 每项测试前 `echo 3 > /proc/sys/vm/drop_caches` 清缓存
- REPEAT≥3 取中位数

### 5.2 数据记录要求

每项测试必须保存：
- `cp`：`time` 输出（real/user/sys）
- `fio`：完整原始输出（BW/IOPS/clat）
- 挂载参数
- 日期时间
- NIC RX/TX 字节量

### 5.3 fio 平均 BW 注意事项

> 详见 `test-commands-reference.md` §5。

JuiceFS 是 FUSE 文件系统，`--direct=1` 只绕开内核页缓存，绕不开 JuiceFS 自己的写缓冲。fio 写类平均 BW 可能虚高（开头几秒写缓冲吸入），如需精确稳态值应加 `--write_bw_log` 取稳态段中位数。

对于 h3c 对比口径，H3C 测试同样用 fio 平均值，因此**同口径对比时可直接用 fio 报告的 BW**，无需额外处理。

---

## 六、测试中遇到的问题及处理方法

### 6.1 BlueFS DB 读停滞

**现象**：`ceph health` 显示 `DB_DEVICE_STALLED_READ_ALERT`

**处理**：重启有告警的 OSD 或 `compact`

### 6.2 OSD down

**处理**：`sudo ceph orch daemon restart osd.X`，等 up + health OK

### 6.3 JuiceFS mount 失败

**处理**：
```bash
juicefs umount /mnt/epc 2>/dev/null || fusermount -uz /mnt/epc 2>/dev/null
# 重新挂载
```

### 6.4 fio 进程残留

```bash
sudo kill -9 $(pgrep -x fio)
```

---

## 七、测试结果可靠性判断标准

| 条件 | 判定 |
|------|------|
| ceph health 全程 OK | 数据可靠 |
| ceph health 中途非 OK 但自动恢复 | 标记 "recovered"，仅供参考 |
| ceph health 中途非 OK 且超时 abort | 数据不可靠，重测 |
| fio BW 明显偏低（低于预期 50%以下） | 检查 BlueFS stall，重测 |
| REPEAT 3 轮波动 >10% | 排查环境，重测 |
| NIC RX/TX 与 fio BW 严重不符 | 检查异常流量或缓存命中 |

---

## 八、测试脚本

| 脚本 | 说明 |
|------|------|
| `scripts/tests/h3c-4item-test.sh` | h3c 4 项测试主脚本，支持 `--repeat N --label <name>` |
| `scripts/tests/lib/ceph-health-check.sh` | 健康检查库（被主脚本 source） |

用法：

```bash
# 单轮
bash scripts/tests/h3c-4item-test.sh

# 3 轮取中位数
bash scripts/tests/h3c-4item-test.sh --repeat 3 --label h3c-baseline

# 自定义标签
bash scripts/tests/h3c-4item-test.sh --repeat 5 --label h3c-tuning-buf1024
```

---

## 九、测试命令记录规范

每个测试结果目录 **必须** 包含 `commands.sh` 文件，记录：
1. JuiceFS format/mount 完整命令
2. 每个测试项的完整命令
3. 环境特殊操作（drop_caches 等）

> 脚本 `h3c-4item-test.sh` 已自动生成 `commands.sh`。

---

## 十、Todo List 管理

### 10.1 实时更新

每次测试完成或状态变化时，立即更新 todo list。

> **AI 长跑监控**：sleep 间隔规则和每次唤醒的检查清单详见 `LONG-RUNNING-TEST-SKILL.md`。

### 10.2 串行执行

- 同一时间只有一个测试在跑
- 当前测试完成且数据可靠后，才启动下一项
