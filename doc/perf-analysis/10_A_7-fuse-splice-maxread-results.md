# 10_A_7 顺位7 验证：FUSE splice/max_read/max_pages/no_readahead（2026-06-23）

> 来源：10_A 第四节顺位7 → GLM5.1 §3.1-3.4
> 结论：**此系统（kernel 5.15, fusermount3 3.10.5）不支持这些 FUSE 调优选项，无法验证。**

---

## 一、背景

GLM5.1 §3 提出四项 FUSE 层参数调优，旨在减少 CPU 上下文切换、降低内核↔用户态往返次数：

| 选项 | GLM5.1 章节 | 作用 |
|------|-----------|------|
| `splice_read,splice_write,splice_move` | §3.1 | FUSE splice 零拷贝 |
| `max_read=1048576,max_write=1048576` | §3.2 | 单次 FUSE 读写上限 1MB（默认 128K）|
| `max_pages=128` | §3.3 | 单次操作最多 128 页（512KB）|
| `no_readahead` | §3.4 | 关闭 FUSE 内核预读 |

## 二、可用性测试

逐项尝试挂载，记录 fusermount3 报错：

### 2.1 splice 选项

```bash
juicefs mount -d ... -o splice_read,splice_write,splice_move
```

日志：
```
/usr/bin/fusermount3: unknown option 'splice_read'
```
**结论：不支持。**

### 2.2 max_write

```bash
juicefs mount -d ... -o max_write=1048576
```

日志：
```
/usr/bin/fusermount3: unknown option 'max_write=1048576'
```
**结论：不支持。**

### 2.3 max_pages

```bash
juicefs mount -d ... -o max_pages=128
```

日志：
```
/usr/bin/fusermount3: unknown option 'max_pages=128'
```
**结论：不支持。** `/sys/fs/fuse/connections/*/max_pages` 文件也不存在。

### 2.4 no_readahead

```bash
juicefs mount -d ... -o no_readahead
```

日志：
```
/usr/bin/fusermount3: unknown option 'no_readahead'
```
**结论：不支持。**

### 2.5 max_read

```bash
juicefs mount -d ... -o max_read=1048576
```

挂载成功，但 mount 输出仍显示 `max_read=131072`（128K 默认值）。/sys/fs/fuse/connections/*/ 下不存在 `max_read` 文件。

**结论：选项被挂载命令静默忽略，实际未生效。**

## 三、系统环境

| 组件 | 版本 |
|------|------|
| kernel | 5.15.0-181-generic |
| fusermount3 | 3.10.5 |
| CONFIG_FUSE_FS | y (builtin) |
| CONFIG_FUSE_DAX | y |

### 实际可用的 FUSE sysfs 接口

```
/sys/fs/fuse/connections/49/
├── abort               (write-only)
├── congestion_threshold (rw, =37)
├── max_background       (rw, =50)
└── waiting              (read-only)
```

仅 `congestion_threshold` 和 `max_background` 可用——均已在 10_A_1 验证为无效（waiting≈0）。

## 四、实测对比

在不支持 max_read 参数的情况下仍跑了一次 fio，仅作完整性记录：

| 指标 | 本次（FUSE 调优尝试）| 基线（10_A_2_3，无调优）|
|------|--------------------|----------------------|
| BW | 38.8 MB/s | 37.9 MB/s |
| IOPS | 147 | 144 |
| numjobs | 8 | 8 |
| files | 8 × 1G | 8 × 1G |
| max_read | 131072（未改变）| 131072 |

差距 2.4%，噪声范围内。**间接证实 max_read 确实未生效（生效应有显著变化）。**

## 五、结论

**顺位7 在此系统上无法验证，因 kernel/fusermount3 版本过低不支持所需 FUSE 选项。**

| 选项 | 状态 |
|------|------|
| splice_read/write/move | ❌ fusermount3 报 unknown option |
| max_write | ❌ fusermount3 报 unknown option |
| max_pages | ❌ fusermount3 报 unknown option；sysfs 文件不存在 |
| no_readahead | ❌ fusermount3 报 unknown option |
| max_read | ⚠️ 挂载成功但选项被静默忽略（mount 输出仍 128K）|

### 若需启用这些选项

需升级内核到 ≥5.15 后续版本（`max_pages` 在 5.14+ 引入，但具体支持取决于发行版），或替换 fusermount3 到 ≥3.12+ 版本。

但升级后收益仍存疑——即便 `max_read` 从 128K 升到 1MB，256K randread 只省 1 次 FUSE 往返（256K/128K=2 → 256K/1MB=1），在小 IOPS 场景（~147 IOPS）下收益极小。

---

环境：tikv-node (192.168.11.12)，JuiceFS v1.3.1，Ceph HEALTH_OK，2026-06-23 20:37 CST。
