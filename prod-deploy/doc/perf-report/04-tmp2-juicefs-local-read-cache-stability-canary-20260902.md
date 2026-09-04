# 04-tmp2 JuiceFS 本地读缓存最小稳定收益 canary 报告

```text
RUN_ID=20260902-133433
VERDICT=CACHE_SCREEN_EVIDENCE_INVALID
ENGINEERING_OBSERVATION=HOTSET_CACHE_MECHANISM_SIGNAL_STRONG_NOT_PRODUCTION_SIZING
L2_DECISION=DO_NOT_RUN
ENVIRONMENT_CLOSURE=PASS
```

## 一、结论

64 GiB JuiceFS 本地缓存对固定 32 GiB 热窗口表现出很强的机制信号：A（`cache-size=0`）均值
`3713.56 MiB/s`，B（缓存开启）均值 `36490.02 MiB/s`，描述性差为 `+882.62%`。但是本轮
**不能签成稳定、可交付的 NVMe 缓存收益**：R02-B 正式窗仍新增约 `19.51 GiB` 缓存，R03-B
才基本稳定；同时 B 的物理 NVMe 读取接近零，热点主要由 Linux 页缓存承载。任务书要求的缓存
命中三源合同没有闭合，正式 verdict 因而是 `CACHE_SCREEN_EVIDENCE_INVALID`。

本轮不补跑、不升级 192 GiB L2。它证明“充分热且能驻留主机内存的读热点，开启 JuiceFS 缓存
可大幅减少后端读取”，但没有回答“工作集主要由本地 NVMe 而非主机页缓存承载时，稳定收益有
多大”，也不能据此给出生产缓存容量。

## 二、实验合同与执行

- 二进制：`/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`；
- 既有 128 个 1 GiB 文件，每文件固定读取前 256 MiB，总热窗口 32 GiB；
- `randread, bs=256KiB, iodepth=128, numjobs=128, runtime=180s`；
- ABBA：`R01-A,R02-B,R03-B,R04-A`，A 为无缓存，B 为 64 GiB 本地缓存；
- 四轮 fio、sampler、只读资产门和卸载均 PASS；矩阵结束后 scrub 已恢复；
- 原始矩阵 873 个文件已持久化，远端/本地 SHA256 清单逐文件一致。

## 三、结果

| 轮次 | 配置 | 均值 MiB/s | 秒级 CV | W4/W1 | fio 读取 | 157 RX / fio | cache 增量 |
|---|---|---:|---:|---:|---:|---:|---:|
| R01-A | cache=0 | 3849.58 | 3.75% | 1.0036 | 678.03 GiB | 107.04% | 0 |
| R02-B | cache=64 GiB | 35881.70 | 2.13% | 0.9914 | 5938.78 GiB | 1.095% | **19.51 GiB** |
| R03-B | cache=64 GiB | 37098.34 | 1.69% | 1.0126 | 6509.55 GiB | 0.001% | 0.02 GiB |
| R04-A | cache=0 | 3577.53 | 2.98% | 1.0153 | 629.49 GiB | 107.05% | 0 |

复算结果：

```text
A_mean=3713.5554 MiB/s
B_mean=36490.0189 MiB/s
effect=+882.6168%
epsilon=7.0672%
M=max(5%,2*epsilon)=14.1343%
pair_effects=+832.09%,+936.98%
```

两次 B 的轮内稳定性良好，但两次 A 相差 `7.07%`，还触发了任务书预设的
`epsilon>=5%` 分辨率门。即使不考虑该门，缓存合同失败也足以阻止正式收益签收。

## 四、缓存归因

任务书要求三源联合证明，实测结果如下：

1. **缓存占用稳定：FAIL。** R02-B 从 `14.16 GB` 增至 `35.11 GB`，正式轮仍在填充；R03-B
   才基本稳定。
2. **本地 NVMe 读取与 fio 同量级：FAIL。** 两个 B 正式窗的块设备物理读取均接近零；R02
   主要表现为约 `19.77 GiB` 缓存写入。
3. **后端网络读取不高于 fio 的 10%：PASS。** R02-B 为 `1.095%`，R03-B 为 `0.001%`；
   A 两轮约为 `107%`。

这说明 B 的绝大多数请求确实没有再走 Ceph，但热数据随后主要命中 Linux 页缓存，测得的是
“JuiceFS 缓存文件 + 主机页缓存”的热集上界，不是本地 NVMe 裸介质吞吐。R02 尚在填充却仍有
高带宽，也不能被表述为“正式前已经全暖”。

## 五、恢复与生命周期

- 缓存销毁计划精确限定到 `/mnt/jfs-cache/jfs-04tmp2-20260902-133433`，共
  `131949` 个文件、8 个子目录、`34582325316` 字节；
- 非 sudo 安全遍历删除内容后，仅父目录权限导致最后一个空 RUN 根需要精确
  `sudo rmdir`；目录现已不存在；
- `POST-A=3841.24 MiB/s`，相对 A 均值偏差 `3.44%`，低于恢复门 `14.13%`；
- 无本任务 fio、挂载或缓存目录残留，Ceph `HEALTH_OK`，scrub 已恢复；
- 环境签 `DOWNSTREAM_RESUME_PASS`。

权威证据：

- 矩阵：`/mnt/c/SunRise/test/04-tmp2/20260902-133433/phase2-remote/`；
- 收口：`/mnt/c/SunRise/test/04-tmp2/20260902-133433/phase3-closure/`。

## 六、工程决策

1. 当前无缓存七项基线不变，不把本轮 B 数值写成交付性能；
2. 不执行本任务书的 192 GiB L2，也不为满足硬门补轮；
3. 本地缓存保留为“生产有额外盘且读热点明显时”的候选能力；若未来确需生产化，应另立最小
   任务，先证明正式窗开始前缓存占用稳定，并明确区分主机页缓存收益与 NVMe 介质收益；
4. 04-tmp2 到此关闭，04 主线继续 04-2/A1。
