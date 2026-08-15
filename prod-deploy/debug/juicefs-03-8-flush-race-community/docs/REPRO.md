# 复现步骤（REPRO）——基于最新 main + #6311 回退

> 缺陷：写请求尺寸 = 数据块大小时，异步 slice ID 登记 + commitThread 持锁提交共同导致
> 纯随机写崩塌 ~5.8×。完整机制与 2×2 验证矩阵见 `bugzilla-*.md` §A.4。
> v1.3.1 基座的复现法见 `REPRO-v131.md`（历史 32 轮证据）。

## 结论先行（2026-08-14 实测）

| 构建 | randwrite | 判定 |
|---|---|---|
| main（edabf9c2）原版 | **3815 MiB/s** | 不复现——#6311 已修复 |
| main 回退 #6311 | **543/539 MiB/s** | 崩塌精确复现（v1.3.1 同签名） |
| main 回退 #6311 + 本包补丁 | **1379 MiB/s** | 修复 |

## 1. 环境要求

| 项 | 值 |
|---|---|
| 客户端 | 96 核 Xeon 8462Y+，100GbE，Linux |
| 卷格式 | `BlockSize: 256`、`Compression: none`、`Storage: ceph`（EC）；社区默认 4M 块亦可触发（BS 跟随块大小） |
| 触发条件 | **fio 写尺寸 BS = 卷数据块大小**，且挂载 `--max-fuse-io` ≥ 块大小 |
| 二进制 | 同基座两版：原版（或回退 #6311 版）与补丁版 |

## 2. 构建

```bash
git clone https://github.com/juicedata/juicefs && cd juicefs
git checkout edabf9c2                    # 2026-08-14 实测基座

# 崩塌侧：回退 #6311（上游修复提交，把 meta 提交移回文件锁内）
git revert --no-commit 00b5ebcf && git commit -m "revert 6311 (repro)"

# 修复侧：应用本包补丁
git apply patch/juicefs-flush-race-fix-main.patch

# 构建（Ceph 后端需 -tags ceph；其余后端无需）
make juicefs.ceph    # 或 go build -tags ceph -o juicefs .
```

## 3. 复现（自包含脚本）

```bash
META=<卷元数据引擎URL> \
STOCK=<回退6311版二进制> PATCHED=<回退6311+补丁版二进制> \
MOUNTPOINT=/mnt/juicefs RUNTIME=120 BS=256k \
./scripts/repro.sh
```

脚本自动：环境信息落盘 → layout 128×1GiB → 各臂挂载/randwrite/1Hz 计数器采样/umount → summary。
预期：stock ≈ 550，patched ≥ 1000（本包实测 543/539 vs 1379）。

## 4. 机制实证（每臂 sample-*.tsv 里的"吸烟枪"）

| 计数器 | 崩塌臂 | 修复臂 |
|---|---|---|
| FUSE 写 op 平均延迟 | ~57 ms | <20 ms |
| `used_buffer_size_bytes` 峰值 | ~580 MiB | <50 MiB |
| 写/PUT 秒级节奏 | 首几秒 PUT 滞后（兜底清仓赶进度） | 即时跟随 |

## 5. 本包原始数据

- `data/main-repro/repro-out-20260814-094136/`：main 原版健康（3815）+ 补丁臂
- `data/main-repro/repro-out-20260814-100529/`：main−#6311 崩塌（543/539，两臂同版）
- `data/main-repro/repro-out-20260814-103453/`：main−#6311+补丁（1379/891）
- `data/main-repro/1job-mechanism/`：单 job 机制对照（PUT 呈 ~2s 周期兜底清仓节律，证明首写跳过上传）
- `data/v131-32rounds/`：v1.3.1 基座历史证据（28 轮 551/552 + 补丁 A/B）
- `docs/ENV.md`：环境信息（客户端/内核/二进制/卷格式/fio 版本）
