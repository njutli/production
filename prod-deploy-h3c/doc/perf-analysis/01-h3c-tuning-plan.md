# 01 — H3C 对比基线测试

> 目标：基于历史调优经验 + H3C 测试口径，暂定一组最优配置，测一组可靠基线，后续再基于此基线调优。
> H3C 目标 + 历史经验详见 `README.md`。

---

## 一、暂定最优配置

基于历史调优经验，针对 H3C 的"大块顺序单线程"口径，暂定以下配置：

| 参数 | prod-deploy 值 | H3C 最优值 | 理由 |
|------|:-:|:-:|------|
| **--block-size** | 256K | **4M** | 顺序读无半块放大问题；RADOS GET 数 80→5（16×↓），PUT 数 64→4（16×↓） |
| **--max-fuse-io** | 不设（128K） | **1M** | kernel 5.15 FUSE 硬上限（`FUSE_MAX_PAGES_PER_REQ`=256=1MB）；dispatch 数 160→20 |
| **--buffer-size** | 不设（300M） | **1024** | 配合 max-fuse-io 1M，防 go-fuse readPool 涨内存触发 write sleep |
| **--max-readahead** | default / 0 | **8M** ⚑ | 顺序读受益于预取；⚑ **8M 为经验外推、未实测**：prod-deploy 只测过 0/default，此值须在本轮 sweep（default/4M/8M/16M）验证，不预设为最优 |
| **--max-uploads** | 150 | **150** | seqwrite +23%（历史已验证） |
| **--cache-size** | 0 | **0** | 冷态基线；writeback 后续再考虑 |

> **block-size 4M 需新建卷**（format 时参数，不能改 mount 参数）。新建 `juicefs-h3c` 卷，不动 `juicefs-prod`。

### 配置命令

```bash
# 1. Format 新卷（block-size 4M）
juicefs format \
  --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs \
  --block-size 4M --trash-days 0 --force \
  "${META}" juicefs-h3c

# 2. Mount（最优参数）
juicefs mount -d \
  --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs \
  --block-size 4M \
  --max-uploads 150 \
  --cache-size 0 \
  --max-fuse-io 1M \
  --buffer-size 1024 \
  --max-readahead 8M \
  "${META}" /mnt/epc
```

### block-size 4M + max-fuse-io 1M 的读取流程

```
fio seq_read bs=20M:
  FUSE 拆成 20×1M dispatch（kernel 5.15 硬上限，无法减少）
    ↓
  每 4 次 dispatch 命中同一个 4M block
    ↓
  首次访问 block: RADOS GET 4M → 缓存进程内存
  后续 3 次 dispatch: 命中内存缓存（~1-2ms vs ~8ms 冷 GET）
    ↓
  readahead 8M = 2 块 ahead: 处理 block N 时已 GET block N+1
    ↓
  20M → 5 个 4M block → 5 次 RADOS GET（vs 256K 的 80 次）
```

> `--cache-size 0` 只关闭磁盘缓存，不关闭进程内内存缓存。block 被首次 GET 后在内存中存活，同 block 的后续 dispatch 命中内存，不产生重复 GET。

---

## 二、测试计划

### 2.1 前置：查本地端瓶颈 + 选定 cp 本地目录

> **不用 /tmp**：157 上有 WekaIO 业务在跑，且 /tmp 可能是 tmpfs（走内存，撞内存红线）。
> cp 项的本地端统一走 nvme1n1 缓存盘 `/mnt/jfs-cache`（`CP_LOCAL_DIR`），既避开 WekaIO 内存/带宽竞争，也拿到稳定的盘速基线。

```bash
# 157 上执行，确认缓存盘可用且测其裸速
CP_LOCAL_DIR=/mnt/jfs-cache
df -h "${CP_LOCAL_DIR}" && mount | grep jfs-cache
dd if=/dev/zero of="${CP_LOCAL_DIR}/ddtest" bs=4M count=5120 oflag=direct  # 写速
dd if="${CP_LOCAL_DIR}/ddtest" of=/dev/null bs=4M count=5120 iflag=direct   # 读速
rm "${CP_LOCAL_DIR}/ddtest"
```

> H3C cp 读=cp 写=2 GB/s 的对称性表明本地端是共同瓶颈。如缓存盘 < 2 GB/s，cp 项无法超过 H3C。

### 2.2 基线测试

```bash
# 1. 集群健康检查
sudo ceph health  # 必须 HEALTH_OK

# 2. Format + mount（§一 配置命令）

# 3. 准备测试文件
dd if=/dev/zero of=/mnt/epc/20Gfile bs=4M count=5120           # 存储端 20G（cp 读的源）
dd if=/dev/zero of=/mnt/jfs-cache/20Gfile bs=4M count=5120     # 本地端 20G（cp 写的源，CP_LOCAL_DIR）

# 4. 跑 4 项 × REPEAT=3
bash scripts/tests/h3c-4item-test.sh --repeat 3 --label h3c-baseline

# 5. 记录 m.Sys
cat /proc/$(pgrep -f 'juicefs.*mount' | head -1)/status | grep -E 'VmRSS|VmSize'
```

### 2.3 数据对比表

| 测试项 | 基线 r1 | 基线 r2 | 基线 r3 | 中位 | H3C 目标 | 判定 |
|--------|---------|---------|---------|------|---------|------|
| cp 读 | | | | | 2.0 GB/s | |
| cp 写 | | | | | 2.0 GB/s | |
| fio seq_read | | | | | 5.4 GB/s | |
| fio seq_write | | | | | 3.2 GB/s | |

> **fio BW 口径**：如 H3C 用 fio 平均值则同口径可对比。如需绝对真值，加 `--write_bw_log --log_avg_msec=1000` 取稳态中位数（历史教训：fio 平均 BW 被客户端写缓冲拉高 7-8%）。

---

## 三、后续调优方向（基线确定后）

基线测试完成后，根据与 H3C 的差距选择调优方向：

| 未达标项 | 候选调优 | 预期 |
|---------|---------|------|
| fio seq_read | CephFS 内核态（无 FUSE 税，历史读快 3.6×） | 大幅提升 |
| fio seq_read | bluestore_cache_size_ssd 增大（默认 1G→4G） | 提升读缓存命中 |
| fio seq_read | EC 2+1（读分片 4→2，减少 subop 往返） | 中等提升 |
| fio seq_read | **numjobs=1 单流 FUSE dispatch 串行延迟**（README §经验：seqread 单流不满速、NIC 93% 未撞墙的结构性根因）→ 增大 readahead 深度 / 提高 dispatch 并发（max_background） | 单流达速关键 |
| fio seq_write | --writeback（写先落本地 staging，异步刷后端） | 突发写大幅提升，但非后端真值 |
| cp 读/写 | 本地端已在基线用 /mnt/jfs-cache（nvme1n1）而非 /tmp；如仍受限，考虑更快本地盘或多流 cp | 消除本地端瓶颈 |
