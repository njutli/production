# 10_2 多客户端聚合测试结果（v1.3.1 vs v1.4，2026-06-21→22）

> 脚本：`tests/bench-multiclient.sh`（每档独立 format → layout → test → destroy，256K block-size）
> 目标：每客户端接近其千兆网卡半速 = N × 59 MB/s，不是固定的 59。
> 问题：destroy 因池累积 1.32M 孤儿对象 + OSD.2/3 BlueFS db 延迟反复超时，删池重建 + 重启 OSD 后修复。
>
> ---
> ⚠️ **数据可信度（opus 对账,详见 `10` 六）**：
> - ✅ **randread 全部 final 数据可信**（逐主机逐 run 已回原始 fio 日志对账吻合,runtime 正常）。
> - ❌ **randrw[analysis] 全系列不可用**（`--create_on_open` 口径病态,run1=0/KiB/s 失真,均值靠 run2-3 凑）——**不作任何结论依据,且不重测**。
> - ❌ **第五节 rados bench 120/154 是 4M 对象,口径错位**——**不作随机读后端基准**;正确基准由 `10` 步骤 A 的 L1（256K）现测替代。
> - ❌ **第四节末顺序读写不完整 + 4cl 超时**——非主线,弃用。
> - 曾出现卡死实证（非-final 3cl randread 一次 299KiB/s 挂起）,已废弃重跑,未污染上述 final 结论。
>
> ⚠️ **方向**：本表为**多客户端聚合**,按用户口径仅作**旁证**（证明后端/网络有横向扩展空间）;
> 调优主线是**单客户端**（见 `10`）,聚合数据不作单客户端达标依据。
> ---

## 一、测试配置

| 项 | 值 |
|----|----|
| 池 | `juicefs-data` EC 4+2 ec-prod |
| block-size | 256K |
| 布局 | LAYOUT_NUMJOBS=128 × 1G = 128G |
| fio 参数 | bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s |
| 缓存 | cold（cache-size 0, drop_caches） |
| 重复 | REPEAT=3（每随机项 ×3） |
| 客户端 | tikv(.12) + ceph-node1(.11) + ceph-node2(.13) + ceph-node3(.14) |

## 二、v1.3.1 全量结果

### 2-cl（tikv + node1）

| 测试 | run1 | run2 | run3 | 均值 |
|------|------|------|------|------|
| **纯 randread** | 55.0 | 55.7 | 55.1 | **55.3 MB/s** |
| randwrite [analysis] | 52.4 | 67.7 | 67.6 | 62.6 MB/s |
| randrw 读 [analysis] | 0* | 23.6 | 26.3 | 25.0 MB/s |
| randrw 写 [analysis] | 0* | 23.3 | 26.0 | 24.7 MB/s |
| randwrite [spec] | 66.3 | 84.8 | 85.2 | 78.8 MB/s |
| randrw 写 [spec] | 63.1 | 64.3 | 64.7 | 64.0 MB/s |

> *run1=0 系 parser bug（KiB/s 格式），均值从 run2-3 计算

### 3-cl（tikv + node1 + node2）

| 测试 | run1 | run2 | run3 | 均值 |
|------|------|------|------|------|
| **纯 randread** | 56.2 | 57.6 | 57.4 | **57.1 MB/s** |
| randwrite [analysis] | 72.9 | 40.6 | 63.4 | 59.0 MB/s |
| randrw 读 [analysis] | 15.6 | 25.2 | 25.2 | 22.0 MB/s |
| randrw 写 [analysis] | 15.6 | 25.2 | 25.2 | 22.0 MB/s |
| randwrite [spec] | 80.0 | 96.9 | 90.6 | 89.2 MB/s |
| randrw 写 [spec] | 75.8 | 75.7 | 79.6 | 77.0 MB/s |

### 4-cl（tikv + node1 + node2 + node3）

| 测试 | run1 | run2 | run3 | 均值 |
|------|------|------|------|------|
| **纯 randread** | 66.7 | 66.9 | 67.1 | **66.9 MB/s** |
| randwrite [analysis] | 83.2 | 85.0 | 42.0 | 70.1 MB/s |
| randrw 读 [analysis] | 20.8 | 25.2 | 25.2 | 23.7 MB/s |
| randrw 写 [analysis] | 20.8 | 23.0 | 25.2 | 23.0 MB/s |
| randwrite [spec] | 83.2 | 106.3 | 104.7 | 98.1 MB/s |
| randrw 写 [spec] | 105.2 | 105.5 | 104.4 | 105.0 MB/s |

## 三、v1.4 全量结果

### 2-cl（tikv + node1）

| 测试 | run1 | run2 | run3 | 均值 |
|------|------|------|------|------|
| **纯 randread** | 73.4 | 78.4 | 77.8 | **76.5 MB/s** |
| randwrite [analysis] | 38.0 | 44.5 | 36.6 | 39.7 MB/s |
| randrw 读 [analysis] | 16.8 | 21.3 | 21.3 | 19.8 MB/s |
| randrw 写 [analysis] | 16.8 | 21.1 | 21.1 | 19.7 MB/s |
| randwrite [spec] | 83.0 | 82.7 | 83.1 | 82.9 MB/s |
| randrw 写 [spec] | 57.6 | 63.0 | 57.7 | 59.4 MB/s |

### 3-cl（tikv + node1 + node2）

| 测试 | run1 | run2 | run3 | 均值 |
|------|------|------|------|------|
| **纯 randread** | 74.1 | 77.9 | 80.5 | **77.5 MB/s** |
| randwrite [analysis] | 48.5 | 52.5 | 41.8 | 47.6 MB/s |
| randrw 读 [analysis] | 11.4 | 19.9 | 23.0 | 18.1 MB/s |
| randrw 写 [analysis] | 10.5 | 19.9 | 23.0 | 17.8 MB/s |
| randwrite [spec] | 79.8 | 85.3 | 94.5 | 86.5 MB/s |
| randrw 写 [spec] | 87.5 | 80.6 | 76.6 | 81.6 MB/s |

### 4-cl（tikv + node1 + node2 + node3）

| 测试 | run1 | run2 | run3 | 均值 |
|------|------|------|------|------|
| **纯 randread** | 88.3 | 92.0 | 95.9 | **92.1 MB/s** |
| randwrite [analysis] | 64.4 | 53.5 | 48.5 | 55.5 MB/s |
| randrw 读 [analysis] | 9.3 | 20.8 | 20.8 | 17.0 MB/s |
| randrw 写 [analysis] | 9.3 | 20.8 | 19.8 | 16.6 MB/s |
| randwrite [spec] | 90.2 | 76.7 | 92.2 | 86.4 MB/s |
| randrw 写 [spec] | 90.3 | 91.9 | 91.7 | 91.3 MB/s |

## 四、randread 聚合对比

| 客户端数 | 目标（N × 59） | v1.3.1 | v1.4.0-rc1 | Δ | 达目标% |
|----------|---------------|--------|-----------|-----|---------|
| **1-cl** | 59 | 45.9* | 44.2* | — | 75-78% |
| **2-cl** | 118 | 55.3 | 76.5 | +38% | 65% |
| **3-cl** | 177 | 57.1 | 77.5 | +36% | 44% |
| **4-cl** | 236 | 66.9 | 92.1 | +38% | 39% |

> *单客户端数据来自 `bench-juicefs.sh` 128G 256K 测试。
> 多客户端目标 = N × 59（每客户端需达到半速千兆），不是固定的 59。

### 全量对比（v1.3.1 vs v1.4，randread + randwrite[spec] + randrw[spec] write）

| 测试 | v1.3.1 2-cl | v1.4 2-cl | v1.3.1 3-cl | v1.4 3-cl | v1.3.1 4-cl | v1.4 4-cl |
|------|------------|----------|------------|----------|------------|----------|
| **randread** | 55.3 | **76.5** | 57.1 | **77.5** | 66.9 | **92.1** |
| randwrite [spec] | 78.8 | 82.9 | 89.2 | **86.5** | 98.1 | **86.4** |
| randrw 写 [spec] | 64.0 | 59.4 | 77.0 | **81.6** | **105.0** | 91.3 |

### 顺序读写（v1.4，128G 256K，SKIP_SEQ 补测）

| 测试 | v1.4 2-cl | v1.4 3-cl |
|------|----------|----------|
| seq-read（4G 单 job） | 44 MB/s | 83 MB/s |
| seq-write（4G 单 job） | 43 MB/s | — |

> v1.3.1 未补测顺序读写。v1.4 4-cl 顺序测试超时未完成。

## 五、rados bench 后端裸能力（测试对象 4M）

| 并发 | 聚合 MB/s | 明细 |
|------|----------|------|
| 单节点 | **120** | 与历史 118 一致 |
| 2 并发 | **154** | node1=81.5 + node2=72.6（15s rand，各写各读） |

> 测试对象大小 4M（rados bench 默认），与 JuiceFS 256K block-size 无关。

## 六、问题与修复记录

| 问题 | 现象 | 根因 | 修复 |
|------|------|------|------|
| destroy 超时 | bench-multiclient.sh 每轮 destroy 卡 300s+ | pool 累积 1.32M 孤儿对象（历史 destroy 失败累积），OSD.2/3 BlueFS db 读延迟 | 删池重建，重启 OSD.2/3 |
| bench-multiclient.sh 不退出 | DONE 后进程僵尸 | cleanup 函数外误用 `local uuid` | 去掉 `local` |
| node3 挂载权限 | FATAL: mount on .14 failed | node3 无 sudo，/mnt/juicefs 不可写 | 挂载到 ~/jfs_mnt |
| randread run1 返回 KiB/s 数据 | parser 报 0 MB/s | fio 慢路径输出 KiB/s 格式 | parser 加 KiB/s fallback |
