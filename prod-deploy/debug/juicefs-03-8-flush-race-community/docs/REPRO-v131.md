# 复现步骤（REPRO）

> 缺陷：写尺寸 = 数据块大小时，纯随机覆盖写的新块"编号登记"异步执行，上传环节误判未登记而跳过，
> 数据滞留触发缓冲节流，写吞吐崩塌约 5.8 倍。
> 完整机制见 `docs/bugzilla-juicefs-randwrite-flush-race-20260813.md`。

## 1. 环境要求

| 项 | 值 |
|---|---|
| 客户端 | 96 核 Xeon 8462Y+，100GbE |
| JuiceFS | v1.3.1（`e0032b2a`；上游 main 与 1.4-beta2 均未修复） |
| 卷格式 | `juicefs config <META>`：`BlockSize: 256`、`Compression: none`、`Storage: ceph`（EC 后端） |
| 数据块 | 256 KiB（官方默认 4 MiB；本卷因 EC 配置切小——**触发条件要求写尺寸恰好 = 块大小**） |
| 挂载选项 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K`（max-fuse-io ≥ 块大小是触发前提） |

## 2. 构建（原版 vs 补丁版）

```bash
# 原版（复现崩塌）：
git clone https://github.com/juicedata/juicefs && cd juicefs && git checkout e0032b2a
# 与本环境同源的一个本地项（非缺陷本体）：
git apply patch/eaf3d21f-partial-read.patch      # 上游 main 已有（#6364），未 backport 到 v1.3.1；现网二进制含它
make juicefs            # 如使用 Ceph 后端需 -tags ceph（官方支持，librados 头文件即可，CI 覆盖）

# 补丁版（验证修复）：
git apply patch/juicefs-flush-race-fix.patch
make juicefs
# 版本串会带 dev 后缀，可作身份标识
```

> Ceph 连接的 cluster/user 由**卷格式配置**提供（`juicefs format --access-key ceph --secret-key client.admin`），
> 上游原生支持，无需任何代码改动。

## 3. 预置数据

```bash
# 128 个 1 GiB 覆盖写目标文件（fio 直接建即可）
mkdir -p /mnt/juicefs/test_dir
fio --name=layout --directory=/mnt/juicefs/test_dir --rw=write --bs=4M --size=1G \
    --numjobs=128 --direct=1 >/dev/null 2>&1
```

## 4. 挂载 + fio

```bash
juicefs mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K <META> /mnt/juicefs
grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*'   # 应输出 262144

fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180
```

## 5. 预期结果（判据）

| 二进制 | randwrite | 判定 |
|---|---|---|
| 原版（256K 挂载） | **≈ 551 MiB/s**（14 轮实测极差 0.2%；历史 128K 挂载平台 2942~3258） | 崩塌 5.8× |
| 补丁版（256K 挂载） | **≥ 2942 MiB/s**（实测 2970~3583，落 128K 平台） | 修复成立 |

## 6. 机制实证（客户端 .stats 计数器，逐秒采样 1Hz）

```bash
# 采样窗口覆盖 fio 全程：
while :; do cat /mnt/juicefs/.stats | grep -E 'juicefs_(used_buffer_size_bytes|fuse_ops_durations_histogram_seconds_(sum|total)|fuse_ops_total_write|object_request_durations_histogram_seconds_PUT_(sum|total)|meta_ops_durations_histogram_seconds_(sum|total))'; sleep 1; done
```

| 计数器 | 原版 256K（塌） | 补丁版 256K（健康） |
|---|---|---|
| `used_buffer_size_bytes` 均值/峰值 | **144 MiB / 609 MiB** | ≤50 MiB 量级 |
| FUSE 写 op 平均耗时 | **≈57.7 ms** | ≈10 ms |
| PUT 总数 ÷ 写 op 数 | ≈1.01（每写触发 1 次 PUT，靠兜底） | ≈1.06（即时派发） |
| 吞吐闭环（F40） | 128×0.25MiB÷57.7ms ≈ **551** | 128×0.25MiB÷10ms ≈ 3200 |

## 7. 数据（本目录 data/）

- `collapse-14-rounds/bw-raw-03-7L-randwrite-WS-WF.tsv`：256K 臂 randwrite 全部 **28 轮 = 551/552**（WS1/WS2 两实例 4 轮 + K3/K4/K7 旋钮块单实例 24 轮，极差 0.4%）；128K 对照臂（WF1/WF2）3383/3045。
- `collapse-14-rounds/i1-jfsstats-randwrite-T37L-WS1.tsv`：崩塌轮的逐秒缓冲/延迟原始数据（144 MiB 均值证据）。
- `patch-abba-03-8/bw-raw-03-8-full.tsv`：补丁 A/B 实验全部 33 行（含探针与 randrw）。
- `patch-abba-03-8/jfs-stats-T38-{A1,B1}-randwrite-r1-{pre,post}.txt`：单轮前后计数器快照（写 op 2.58M vs 0.40M 的直接对照）。
