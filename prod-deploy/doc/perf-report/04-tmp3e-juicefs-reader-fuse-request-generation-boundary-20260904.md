# 04-tmp3e JuiceFS Reader/FUSE 请求生成边界报告

## 一、裁决

| 字段 | 结果 |
|---|---|
| RUN_ID | `20260904-184259` |
| Phase A | `APPLICATION_QD_SCALABLE` |
| Phase B | `RESOLUTION_INSUFFICIENT`（RA64不登记为优化） |
| VALIDITY | `VALID_L1_DIAGNOSIS` |
| 环境状态 | 临时B4卷已按META+UUID精确销毁；业务卷指纹不变；Ceph `HEALTH_OK`、6/6 OSD up/in、97 PG全部`active+clean` |
| 权威证据 | `/mnt/c/SunRise/test/04-tmp3e/20260904-184259/final-raw/` |
| manifest | 376项全部校验通过；`final-manifest.sha256`的SHA256=`bca1d68d86f1b4115768a20efea90f310cd9fbaf871954436aa30ccad11cadca` |

**核心结论：对象后端有余量，而且JuiceFS能够在应用提供异步在途请求时利用这部分余量；当前
20 MiB单流同步读的主要限制，是应用/FUSE/Reader链路只维持约4个对象GET，而不是Ceph对象
服务能力不足。** 单job由QD1提高到QD8后，带宽从约`1.98`提高到`5.28 GiB/s`，GET在途量
从`4.32`提高到`15.07`，已经超过竞品`5149.84 MiB/s`，但仍低于项目`6250 MiB/s`目标。

只把`max-readahead`从32 MiB提高到64 MiB没有稳定材料收益，两组配对为`0%/+8.82%`，不能作为
生产参数交付。故本RUN找到的是**应用异步并发可提升**的架构/使用方式，不是新的通用挂载调优项；
原七项256 KiB基线也不由本专项改写。

## 二、测试合同

- 发起节点157；patched JuiceFS v1.4.1，MD5=`24fae0852051c80ca571cb2f20275d46`。
- 只创建一个RUN私有B4卷和一份10 GiB非稀疏只读资产；业务卷`juicefs-prod`全程只读指纹保护。
- 共同参数：`bs=20M size=10G direct=1 numjobs=1 cache=0 max-fuse-io=1M`，RUN私有
  `ms_async_op_threads=8`；每格均为time-based循环读。
- Phase A固定B4/RA32并显式`async_dio`，比较psync QD1与libaio QD1/2/4/8；该阶段只做机制诊断。
- Phase B恢复生产语义`async_dio=off`，按RA32/64/64/32执行psync QD1 A-B-B-A。
- 不执行sudo、drop_caches、scrub/compact控制、Ceph/服务/网络/内核配置修改。

## 三、Phase A：请求入口并发曲线

| Cell | fio入口 | mean / median MiB/s | CV | GET在途量 | FUSE read平均时延 | FUSE waiting中位/最大 |
|---|---|---:|---:|---:|---:|---:|
| A01 | psync/QD1 | `1957.75 / 1960.00` | `3.45%` | `4.34` | `4.25 ms` | `9 / 19` |
| A02 | libaio/QD1 | `1975.30 / 1990.99` | `4.01%` | `4.32` | `4.20 ms` | `8 / 18` |
| A03 | libaio/QD2 | `3021.45 / 3040.00` | `3.24%` | `8.50` | `6.26 ms` | `16 / 39` |
| A04 | libaio/QD4 | `4432.65 / 4440.00` | `2.87%` | `14.53` | `9.10 ms` | `44.5 / 51` |
| A05 | libaio/QD8 | **`5277.79 / 5270.00`** | `1.63%` | `15.07` | `9.17 ms` | `51 / 51` |
| A06 | psync/QD1 | `1950.29 / 1940.00` | `3.75%` | `4.31` | `4.33 ms` | `7 / 20` |

- A01→A06中位锚漂移仅`-1.02%`；六格对象错误增量均为0。
- libaio QD1→2→4→8吞吐和在途量连续增长；QD8相对libaio QD1的mean提升`167.19%`。
- QD8相对竞品线高`2.48%`，但相对项目目标仍低`15.56%`。
- QD4/8时FUSE `waiting`达到`51`，而该挂载的`max_background=50`；同时QD4→8的GET在途量仅
  `14.53→15.07`。这提示FUSE请求队列已成为下一层候选边界。当前版本源码将普通mount的
  `MaxBackground`固定为50，没有生产CLI旋钮；本任务不继续做源码改动或扩大矩阵。

Phase A使用`async_dio+libaio`改变了应用提交语义，绝对值不能直接替代psync生产基线；它证明
“增加入口在途请求可以调用后端余量”，并给异步化应用提供明确方向。

## 四、Phase B：RA64可交付旋钮

| Cell | RA | mean / median MiB/s | CV | GET平均时延 | GET在途量 | 错误增量 |
|---|---:|---:|---:|---:|---:|---:|
| B01 | 32M | `2872.37 / 2871.43` | `3.59%` | `6.18 ms` | `4.44` | `0` |
| B02 | 64M | `2865.85 / 2871.43` | `6.39%` | `6.08 ms` | `4.36` | `0` |
| B03 | 64M | `2953.02 / 2961.47` | `6.37%` | `6.31 ms` | `4.66` | `0` |
| B04 | 32M | `2743.41 / 2721.36` | `3.69%` | `5.80 ms` | `3.98` | `0` |

RA64相对相邻RA32的中位效应分别为`0%`和`+8.82%`，均未越过预注册10%门且不构成一致双配对；
GET在途量也分别`-1.81%/+17.18%`。因此签`RESOLUTION_INSUFFICIENT`，保持RA32候选，不继续
增加RA128。

## 五、证据有效性与事故

- 10/10正式cell均`error=0`、写字节为0、实际读量超过文件大小；Phase A首尾锚和Phase B双配对完整。
- 每格保留fio JSON/stdout/stderr、逐秒bw、JuiceFS metrics、客户端CPU/RSS/NIC、FUSE connection
  sidecar及前后健康快照；GPT和Luna分别从raw复算，结果一致。
- 第一次Phase A在fio前因Go daemon改写并截断`/proc/PID/cmdline`，使`async_dio`后置检查假阴性；
  失败挂载已精确卸载，证据归档到`mounts/INVALID-PHASE-A-ARGV-CHECK`。修复只将验证改为固定脚本
  SHA加pre-exec `mount-contract.tsv`，未改变format、fio、矩阵或采样。逐行差异和理由见
  `/mnt/c/SunRise/test/04-tmp3e/20260904-184259/runtime-script-evidence-repair.md`。
- inventory登记的executor SHA为`6293c2...`，正式执行版本为`48805d...`；上述语义diff已独立复核，
  analyzer始终为`a4a169...`，不构成工作负载合同漂移。

## 六、生命周期与下一步

- 临时卷UUID=`978e4d05-9de7-4b2e-b97e-0dc67ec12cba`；业务卷UUID=
  `e1b69ea9-0e3d-427d-bea9-8765928afa66`。销毁前二次核对不相等，销毁后META明确返回
  `database is not formatted`。
- 最终无临时挂载、进程或19657端口残留；业务卷mount/asset/status/process四项指纹完全一致。
- 本地376项manifest校验后，157上的11 MiB本RUN临时证据目录已按精确路径删除且不可从157恢复；
  本地`final-raw`完整保留，审计见`remote-purge-audit.tsv`。
- 本专项到此停止。若应用允许异步I/O或多请求并发，可把QD4--8作为生产使用方式候选另做真实应用
  canary；若必须让同步单流继续接近项目目标，则需要修改/验证FUSE `MaxBackground`或Reader请求
  生成策略，属于代码级改造，不是现有挂载参数调优。

## 七、最优有效配置与竞品披露值对比

竞品仅披露命令和带宽，未披露硬件、网络、后端副本/一致性、缓存状态和软件版本；下表因此是
**公开命令口径对照**，不是同硬件产品排名。GB/s均按十进制换算。

| 测试项 | 竞品披露值 | JuiceFS最佳有效值 | 达成率 | JuiceFS针对性配置与结论 |
|---|---:|---:|---:|---|
| `cp`单流读20 GiB | `2.0 GB/s` | `0.996 GB/s` | `49.80%` | patched 1.4.1、现有B256卷；增大预读未带来有效改善 |
| `cp`单流写20 GiB | `2.0 GB/s` | `0.986 GB/s` | `49.30%` | patched 1.4.1、现有B256卷；仅为单点工程观察，不据此固化参数 |
| `fio bs=20M`同步单流读 | `5.4 GB/s` | `2921.87 MiB/s`（`3.064 GB/s`） | `56.74%` | B4、RA32、`max-fuse-io=1M`、`cache=0`、psync/QD1；L2候选，尚未做七项回归 |
| `fio bs=16M`同步单流写 | `3.2 GB/s` | `2616.09 MiB/s`（`2.743 GB/s`） | `85.72%` | B256、`max-fuse-io=1M`、`cache=0`、psync/QD1；有效L1候选，尚非生产效应量 |
| `fio bs=20M`异步单job读（诊断） | `5.4 GB/s` | `5277.79 MiB/s`（`5.534 GB/s`） | `102.48%` | B4/RA32、`async_dio+libaio`、QD8；超过竞品披露值，但提交语义与竞品命令不同 |

同命令语义下，JuiceFS当前最佳有效结果仍未达到竞品披露值；其中写侧差距最小。异步QD8结果证明
后端具备达到竞品读带宽的能力，差距主要在同步单流应用/FUSE/Reader只能形成有限在途请求，不能
把该诊断值冒充为同步命令达标。以上专项配置也不替代256 KiB七项生产基线。
