# 04-tmp3b 竞品大块顺序 I/O 路径对齐正式报告

```text
RUN_ID=20260904-132417
EVIDENCE_LEVEL=L1_SCREEN
STEP1_VALIDITY=VALID_STEP1_L1_SCREEN
RA_RESULT=RA32_SMALL_SIGNAL_NOT_SELECTED_KEEP_RA8
ASYNC_READ_RESULT=SCREEN_STOP_NO_SIGNAL_KEEP_OFF
BLOCKSIZE_READ_RESULT=BLOCK4_READ_SCREEN_NO_SIGNAL
BLOCKSIZE_WRITE_RESULT=EVIDENCE_INVALID_PERSISTENCE_GATE
TARGET_STATUS=READ_NOT_REACHED / WRITE_NOT_ACCEPTED
PRODUCTION_CHANGE=NONE
LIFECYCLE_STATE=ENVIRONMENT_CLOSED
```

## 一、结论

1. **保留 `max-readahead=8M`，不启用 `async_dio`。** RA32 相对 RA8 的两个配对增益为
   `+9.74%/+13.80%`，第一对未过预注册的“双配对均不低于 10%”门；`async_dio` 两个配对均约
   `0%`，同时 RSS、线程数和对象读放大上升。因此两项都没有形成可交付配置变化。
2. **把 JuiceFS format BlockSize 从 256 KiB 增至 4 MiB，不能改善本口径单流读。** fresh
   B256/B4 同起点 ABBA 中，B4 两个配对分别下降 `34.13%/33.47%`。B4 将 GET 密度从约
   `4096` 降至 `256 GET/GiB`，但单 GET 平均时延由约 `1.15 ms` 增至 `5.59 ms`；单流流水线不能
   隐藏更大的单请求时延，带宽由 B256 约 `2500.81 MiB/s` 降至 B4 约 `1654.46 MiB/s`。
3. **写侧不形成 B256/B4 结论。** 第一个 B256 写 cell 的 fio 前台均值为
   `3163.45 MiB/s`、close-complete 为 `3150.57 MiB/s`，但 clean unmount 后重挂时，已完成
   size/hash 校验的 10 GiB 文件在原路径不可见，而 volume status 仍计入约 10 GiB UsedSpace。
   该 cell 触发持久性硬门，属于工程观察值，不能用于目标达成或 block-size 效应；按合同停止
   S2W02--S2W04，不用补样掩盖异常。
4. **04-tmp3b 不产生生产配置变更。** 竞品 20 MiB 读目标 `5149.84 MiB/s` 未达到；写目标虽被
   无效 cell 的前台数值越过，但持久性未通过，不能签收。当前 256 KiB 七项基线不被本专项覆盖。

## 二、竞品对比与针对性配置

### 2.1 竞品公开口径与本方结果

竞品只披露了命令和带宽，没有披露客户端CPU/内存、网络、后端介质、数据保护方式、缓存状态及
软件版本，因此下表是**公开命令口径对照**，不是严格同硬件产品排名。GB/s按十进制换算，目标
5.4/3.2 GB/s分别等于约`5149.84/3051.76 MiB/s`。

```bash
time cp /mnt/epc/20Gfile /tmp/                         # 竞品：2 GB/s
time cp /tmp/20Gfile /mnt/epc/                         # 竞品：2 GB/s
fio --name=seq_read  --filename=/mnt/epc/testfile1 --size=10G --bs=20M --rw=read  --direct=1 --numjobs=1 --runtime=60  --time_based --group_reporting  # 5.4 GB/s
fio --name=seq_write --filename=/mnt/epc/testfile1 --size=10G --bs=16M --rw=write --direct=1 --numjobs=1 --runtime=120 --time_based --group_reporting  # 3.2 GB/s
```

| 公开测试项 | 竞品值 | 本方结果/观察值 | 达成率 | 判读 |
|---|---:|---:|---:|---|
| `fio bs=20M`单流读 | `5.4 GB/s` | 最终保留RA8均值`2658.65 MiB/s`（`2.788 GB/s`） | `51.63%` | 未达标 |
| `fio bs=20M`单流读 | `5.4 GB/s` | RA32最佳观察臂均值`3005.24 MiB/s`（`3.151 GB/s`） | `58.36%` | 两配对之一未过10%门，不选用 |
| fresh B256 `fio bs=20M`单流读 | `5.4 GB/s` | `2500.81 MiB/s`（`2.622 GB/s`） | `48.56%` | 未达标 |
| fresh B4 `fio bs=20M`单流读 | `5.4 GB/s` | `1654.46 MiB/s`（`1.735 GB/s`） | `32.13%` | 相对B256下降约34% |
| `fio bs=16M`单流写 | `3.2 GB/s` | 04-tmp3已接受L1参考`2616.09 MiB/s`（`2.743 GB/s`） | `85.72%` | 未达标，仍非正式生产效应 |
| B256 `fio bs=16M`单流写 | `3.2 GB/s` | 前台`3163.45 MiB/s`（`3.317 GB/s`） | `103.66%` | **重挂持久性门失败，禁止作为达标结果** |
| `cp`单流读/写 | 各`2 GB/s` | 04-tmp3参考`0.996/0.986 GB/s` | `49.80%/49.30%` | 本任务不重复cp；参考值均未达标 |

本次最重要的对标结论不是“某个瞬时值是否越线”，而是：针对大块单流路径放大 readahead 后，读
仍只有竞品披露值的约58%；把对象BlockSize增大16倍反而使读下降；写虽出现超过3.2 GB/s的前台值，
但未通过卸载—重挂可见性检查，不能以牺牲正确性换取达标声明。

### 2.2 为竞品 I/O 模型采用的针对性配置

| 层次 | 本次配置 | 对齐目的 |
|---|---|---|
| JuiceFS二进制 | patched v1.4.1，MD5 `24fae0852051c80ca571cb2f20275d46` | 使用当前已批准替代1.3的交付二进制 |
| 共同挂载参数 | `--max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0`，writeback关闭 | 让16/20 MiB应用I/O使用较大的FUSE请求，同时排除本地读写缓存收益 |
| 读路径变量 | `--max-readahead 8M/16M/32M`；随后在获选RA8下比较`async_dio=off/on` | 检验20 MiB同步读能否靠更大预取窗或FUSE子请求重叠提速 |
| Ceph客户端 | 仅RUN私有配置`ms_async_op_threads=8`；不修改系统`ceph.conf` | 沿用已验证的Ceph消息线程配置，避免客户端消息线程先成为瓶颈 |
| format变量 | fresh B256=`BlockSize 256 KiB`、fresh B4=`BlockSize 4 MiB`，其余Setting一致 | 把每GiB对象GET数理论上从4096降到256，单独验证对象切分是否是主因 |
| fio公共合同 | `ioengine=psync, iodepth=1, direct=1, numjobs=1` | 对齐竞品“单流同步I/O”语义，不用提高应用并发掩盖单流瓶颈 |
| fio读 | `rw=read, bs=20M, size=10G, runtime=60, time_based` | 对齐竞品公开fio读命令 |
| fio写 | `rw=write, bs=16M, size=10G, runtime=120, time_based` | 对齐竞品公开fio写命令 |
| 数据与缓存边界 | 10 GiB固定内容；不执行`drop_caches` | `direct=1`绕过客户端页缓存；不把Ceph/BlueStore warm effect误称为绝对冷态 |

这些参数是为竞品16/20 MiB单流模型做的专项适配，不等于七项256 KiB生产基线。最终配置裁决仍是
RA8、`async_dio=off`、BlockSize 256 KiB；RA32和4 MiB BlockSize均未通过各自选择门。

## 三、Step 1：现有 256 KiB 卷读路径筛选

测试使用 patched JuiceFS 1.4.1、当前 `juicefs-prod` 的既有 32 GiB 只读资产、
`max-fuse-io=1M`、`cache-size=0` 和私有 `ms_async_op_threads=8`。所有 cell 均为单 job、
`psync/iodepth=1/direct=1`、20 MiB read；正式窗、客户端与 Ceph sidecar 完整。

| Cell | 参数臂 | 正式窗中位数 MiB/s | CV |
|---|---|---:|---:|
| R01 / R06 | RA8 | `2670.00 / 2681.34` | `3.11% / 3.79%` |
| R02 / R05 | RA16 | `2820.00 / 2840.00` | `4.63% / 2.94%` |
| R03 / R04 | RA32 | `2930.00 / 3051.47` | `3.79% / 3.11%` |
| A01 / A04 | async off | `2580.00 / 2600.00` | `2.63% / 2.83%` |
| A02 / A03 | async on | `2580.00 / 2600.00` | `1.33% / 1.47%` |

1 MiB FUSE read 稳定拆成 4 个 256 KiB GET，约 `4096 GET/GiB`；RA8 下平均 GET 时延约
`1.13--1.14 ms`。客户端只使用约 `4.4--4.9` 个 CPU 核，100GbE Ceph 数据网卡最高约
`3121 MiB/s`，没有先达到 CPU 或网络上限。因此进入 BlockSize 因果对照是合理的，但 Step 1
本身没有产生可交付调参。

## 四、Step 2：fresh B256/B4 读因果对照

两卷使用同一 TiKV endpoints、Ceph pool、二进制和其余 Setting，仅 BlockSize 不同；两个 10 GiB
读资产内容及抽样哈希一致。读矩阵为 `B256→B4→B4→B256`，其余挂载和 fio 参数固定。

| Cell | 臂 | mean / median MiB/s | CV | clat mean/p99 | GET/GiB | GET均值/时延 |
|---|---|---:|---:|---:|---:|---:|
| S2R01 | B256 | `2515.81 / 2520.00` | `2.84%` | `7944/11862 µs` | `4096.0` | `256 KiB / 1.171 ms` |
| S2R02 | B4 | `1654.70 / 1660.00` | `1.94%` | `12315/17957 µs` | `256.1` | `4094.6 KiB / 5.646 ms` |
| S2R03 | B4 | `1654.21 / 1650.82` | `2.41%` | `12078/17695 µs` | `256.1` | `4094.5 KiB / 5.539 ms` |
| S2R04 | B256 | `2485.82 / 2481.24` | `3.00%` | `8078/12124 µs` | `4096.0` | `256 KiB / 1.123 ms` |

B4 的请求数减少 16 倍并未转化成带宽收益，说明当前单流路径需要的是足够的请求重叠，而不是单纯
增大对象请求。该结论只适用于本次相同 readahead、单流同步 20 MiB 口径；不外推到高并发或其他
readahead 设置，但已足够否决把 4 MiB BlockSize 作为本口径生产候选。

## 五、写侧异常与证据边界

S2W01 使用 B256、16 MiB write、单 job、`psync/iodepth=1/direct=1`、120 秒 time-based。fio、
逐秒带宽、close 和 drain 均通过，正式窗 CV 为 `2.10%`，W4/W1=`1.028`；首次卸载前文件大小及
固定抽样哈希正确，mount 日志没有 assert、panic 或异常信号。

但重挂同一 META/UUID 后，原精确路径不存在；只读核验同时看到 volume status 的 UsedSpace 仍为
`10737426432 B`、UsedInodes=`3`。随后仅对该临时 META 执行的 `gc --delete` 未消除这部分账面空间。
现有证据不足以把问题唯一归因于客户端、执行脚本路径状态或元数据可见性缺陷，因此报告只签
`EVIDENCE_INVALID_PERSISTENCE_GATE`，不把它扩大成 JuiceFS 普遍数据丢失结论，也不再用 B4 写点
继续消耗测试窗口。

## 六、环境与生命周期闭环

- 两个临时卷销毁前 UUID 分别核对为
  `b19667b8-144d-4993-adb2-38a28ce78c42`（B256）和
  `72f742e0-1ec5-4f98-8d2d-644aa4f370ef`（B4），均与当前卷 UUID 不同；精确 destroy 后两个 META
  的 status 均返回非零。
- Ceph pool 从 Step 2 创建前 `1978607 objects / 519327875072 B stored`，销毁后回到
  `1978606 objects / 519327809536 B stored`，仅差 1 object / 64 KiB 的采样边界；Ceph
  `HEALTH_OK`，flags 恢复为原值。
- `juicefs-prod` UUID 仍为 `e1b69ea9-0e3d-427d-bea9-8765928afa66`；`/mnt/juicefs` 挂载正常，
  32 GiB 资产 inode、size、mtime 和首尾哈希与执行前完全一致。
- 无本 RUN 测试挂载或 fio 残留。临时卷已不可恢复；其原始性能、日志、异常和销毁证据均已先持久化。

## 七、证据索引

| 证据 | 位置 |
|---|---|
| 持久证据根 | `/mnt/c/SunRise/test/04-tmp3b/20260904-132417/` |
| Step 1 原始包 | `04tmp3b-20260904-132417-evidence.tar` 及同名 `.sha256` |
| Step 1 独立复核 | `gpt-independent-review.md` |
| Step 2 原始证据 | `step2-evidence/`；fio 为 `cells/<CELL>/fio.json`，逐秒日志在对应 `bwlog/` |
| Step 2 读独立复核 | `step2-gpt-review.md` |
| 写异常 | `step2-evidence/incidents/S2W01-remount-missing-after-clean-close/` 及 `cells/S2W01*` |
| 销毁与环境回归 | `step2-evidence/closure/` |
| Step 2 全量清单 | `step2-evidence-manifest.sha256`；403/403校验通过；清单 SHA256=`a92c04732375bec588a751d480c91a9b6ae094bcd065456b330fa3b80a37ec2f` |

## 八、下一步

04-tmp3b 到此关闭，不补跑写 ABBA，也不为竞品口径继续扩大参数矩阵。若未来需要研究 S2W01，必须
另立最小“单文件写入—卸载—重挂可见性”复现任务，先区分执行路径问题和存储语义问题；它不阻塞
当前无缓存生产基线，也不影响已独立确认的读缓存、条件性 writeback 和 04 主线结论。
