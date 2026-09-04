# 04-tmp3 竞品大块单流顺序口径 L1 筛选正式报告

```text
RUN_ID=20260904-095827
EVIDENCE_LEVEL=L1_SCREEN
MATRIX=12/12 PASS
READ_FIO=SCREEN_CONTINUE_R_ONLY
READ_CP=SCREEN_STOP
WRITE_FIO=F_CONFIRMATION_ELIGIBLE_L1
WRITE_BUFFER_1024=SCREEN_STOP_NO_INCREMENTAL_SIGNAL
COMPETITOR_DISCLOSED_TARGETS=4/4 NOT_MET
AUTOMATIC_L2=NO
ENVIRONMENT_CLOSED=PASS
LOCAL_ARCHIVE_VERIFIED=PASS
```

## 一、结论

本 RUN 在 exact patched v1.4.1、同一 `juicefs-prod` 卷、`cache-size=0` 和私有
`ms_async_op_threads=8` 下，完成竞品披露的 20 GiB `cp` 单流读写与 20 MiB/16 MiB fio 单流
读写口径，并用最小 A/F/R/W 参数臂筛选大块 I/O 适配空间。

1. **大块 fio 读存在明确的 readahead 工程信号。** 当前交付臂 A 均值为
   `1581.68 MiB/s`；只把 `max-fuse-io` 调到 1 MiB 的 F 臂反而为 `1465.44 MiB/s`；在此基础上
   增加 `max-readahead=8M` 的 R 臂为 `2614.08 MiB/s`，相对 A 为 `+65.27%`。两次 R 仅相差
   `0.29%`，可记 `SCREEN_CONTINUE_R_ONLY`，但仍只达到竞品披露 5.4 GB/s 的 `50.76%`。
2. **该读收益不能外推到普通 cp。** A/R 的 20 GiB cp 分别耗时 `21.56/21.65 s`，约
   `0.996/0.992 GB/s`，R 没有改善，且只达到竞品 2 GB/s 的约一半。因此
   `max-readahead=8M` 只对本次 `direct=1、bs=20M、time_based` fio 命令形成 L1 信号，不是通用
   单流顺序读收益。
3. **写侧的 `max-fuse-io=1M` 具备最小确认资格，但本 RUN 不签正式效应。** A/F/W 均值分别为
   `2365.31/2616.09/2585.66 MiB/s`；F 相对同位置头/尾 A 分别为 `+10.29%/+10.89%`，方向一致，
   因而记为 `F_CONFIRMATION_ELIGIBLE_L1`。不过 A/F 各自前后点都上行约 `10%`，本 L1 又未采集
   正式窗跨层性能 sidecar，不能把 `+10.60%` 当作稳定因果效应。W 相对 F 均值反而低 `1.16%`，
   且两次增量方向相反，因此 `buffer-size=1024` 没有独立增益。
4. **四个竞品披露目标均未达到。** 最佳有效 fio 读、写臂分别约 `2.741 GB/s` 和
   `2.743 GB/s`，低于 `5.4/3.2 GB/s`；cp 读、写候选约 `0.992/0.986 GB/s`，低于 2 GB/s。
   竞品未披露硬件、客户端缓存、后端和一致性条件，因此这里只能写“在其命令口径下未达到其披露值”，
   不能据此宣称严格同条件产品优劣。

本任务只允许 L1 筛选，不能自动升级 L2。它不改写 256 KiB 七项交付基线，也不足以把
`max-fuse-io=1M` 或 `max-readahead=8M` 直接加入通用生产配置；若业务确实采用 20 MiB direct fio
式读取，可另立一个精简 A/R 确认任务，同时补测该挂载参数对七项原始 IO 模型的回归影响。

## 二、测试条件

| 项 | 冻结值 |
|---|---|
| JuiceFS | `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46` |
| META/卷 | 三节点 TiKV `juicefs-prod`；既有卷，不 format/destroy |
| 共同挂载 | `--max-uploads 150 --cache-size 0`，私有 Ceph `ms_async_op_threads=8` |
| A | `--max-fuse-io 256K` |
| F | `--max-fuse-io 1M` |
| R | F + `--max-readahead 8M` |
| W | F + `--buffer-size 1024` |
| 读顺序 | `A→F→R→R→F→A`；fio `bs=20M`、60 s、单 job、direct=1 |
| 写顺序 | `A→F→W→W→F→A`；fio `bs=16M`、120 s、单 job、direct=1 |
| fio 主窗 | 读 `[10,50)`；写 `[10,110)`；按 1 s bw log 重采样，不用 summary 代替 |
| 资产 | 20 GiB 本地非稀疏源；JuiceFS 20 GiB cp 读文件、10 GiB fio 读文件、6 个独立10 GiB写文件 |

## 三、fio 结果

### 3.1 读：A/F/R/R/F/A

| Cell | 臂 | MiB/s | CV | W4/W1 |
|---|---|---:|---:|---:|
| R01 | A | 1579.20 | 1.44% | 1.0076 |
| R02 | F | 1471.69 | 2.05% | 0.9972 |
| R03 | R | 2617.83 | 2.28% | 1.0279 |
| R04 | R | 2610.33 | 2.78% | 1.0210 |
| R05 | F | 1459.19 | 2.73% | 0.9728 |
| R06 | A | 1584.16 | 1.17% | 0.9937 |

| 臂 | 两点均值 MiB/s | 相对 A | 前后点漂移 | 5.4 GB/s目标达成率 |
|---|---:|---:|---:|---:|
| A | 1581.68 | — | +0.31% | 30.71% |
| F | 1465.44 | −7.35% | −0.85% | 28.46% |
| R | 2614.08 | **+65.27%** | −0.29% | 50.76% |

读组自身回环稳定，R 的两点也稳定，因此可以确认存在材料级 L1 信号；但本 L1 未采集正式窗跨层性能
sidecar，health/object/recovery 只是状态门，且 cp 没有同向收益，不能把增益解释为整个顺序读路径提升。

### 3.2 写：A/F/W/W/F/A

| Cell | 臂 | MiB/s | CV | W4/W1 |
|---|---|---:|---:|---:|
| W01 | A | 2252.98 | 4.85% | 1.0023 |
| W02 | F | 2484.69 | 3.71% | 1.0192 |
| W03 | W | 2666.98 | 4.84% | 1.0485 |
| W04 | W | 2504.35 | 4.38% | 1.0036 |
| W05 | F | 2747.48 | 5.45% | 0.9995 |
| W06 | A | 2477.63 | 6.56% | 1.0589 |

| 臂 | 两点均值 MiB/s | 相对 A | 前后点漂移 | 3.2 GB/s目标达成率 |
|---|---:|---:|---:|---:|
| A | 2365.31 | — | +9.97% | 77.51% |
| F | 2616.09 | +10.60% | +10.58% | 85.72% |
| W | 2585.66 | +9.32% | −6.10% | 84.73% |

`W/F−1=−1.16%`，而且 W 相对同位置 F 的两次增量为 `+7.34%/−8.85%`，因此没有证据支持
为大块写额外设置 `buffer-size=1024`。F 相对同位置 A 的两次增量为 `+10.29%/+10.89%`，可作为后续
精简 A/F 确认的排期依据；但它仍是 L1 筛选信号，不是生产效应量。

## 四、cp 结果

| 方向 | 臂/Cell | 20 GiB耗时 | 吞吐 MiB/s | 吞吐 GB/s | 2 GB/s目标达成率 |
|---|---|---:|---:|---:|---:|
| 读 | A / R01 | 21.56 s | 949.91 | 0.996 | 49.80% |
| 读 | R / R04 | 21.65 s | 945.96 | 0.992 | 49.60% |
| 写 | A / W01 | 24.78 s | 826.47 | 0.867 | 43.33% |
| 写 | W / W04 | 21.78 s | 940.31 | 0.986 | 49.30% |

cp 每种配置只有一个点，写侧名义 `+13.77%` 又处于写组整体上行时间段，因此只作工程观察；读侧
本 RUN 单点未观察到 R 臂收益。cp 不是 direct fio，页缓存、复制 syscall 和前台返回语义也不同，不能把 fio
结果代入 cp。

## 五、有效性与环境收口

- 12/12 cell 的 fio rc/error、唯一 per-job bw log、文件路径/大小、挂载 worker/starttime/exe、
  `msgr-worker=8`、health 和分析合同全部通过；GPT 使用持久副本独立重放 12 个 cell，关键统计一致，
  R02/R06/W01 的 CV 只存在 Python 浮点末位 1 ULP 差异。
- READ、WRITE 对象数均从 `O1=2347246` 精确回到 `2347246`；每个写 cell 使用独立文件并在
  GC/compact 后通过三点稳定门，避免上一点的版本对象直接串入下一点。
- 两个 scrub lease 均由 state-driven controller 恢复；最终对象数从 O1 回到
  `O0=1978606`，Ceph `HEALTH_OK`、6/6 OSD up/in、97/97 PG `active+clean`。
- 最终不存在本 RUN 资产、scratch、测试挂载或 fio 进程；`incidents.tsv` 仅表头。
- 归档 manifest 共 626 项，校验全部通过。
- 归档内 `run-state=ACTIVE` 与 `persistence_status=PENDING` 是 bundle 生成前的时间切片；归档复制后，
  GPT 已校验本地 tar SHA256、626 项 manifest 并完成独立签收。环境资产收口与证据持久化分开判定，
  最终状态见持久根顶层 `gpt-final-signoff.tsv`。

最终 RUN 前的失效尝试全部排除在性能结论外：权限、例行 scrub、fio 3.28 JSON兼容和 Go 进程标题
截断分别留下最小故障记录；其中 `20260904-093726` 在 R03 fio 前停止，清理精确回 O0，其原始故障
包已持久化。正式 RUN 使用修复后新 RUN_ID，没有复用任何失败 cell。

## 六、证据索引

| 证据 | 位置/摘要 |
|---|---|
| 持久证据根 | `/mnt/c/SunRise/test/04-tmp3/20260904-095827/` |
| 原始归档 | `04tmp3-20260904-095827-evidence.tar` |
| 归档 SHA256 | `da7cce079b9fa83c66e1c517a33b9d7c5202a610db661aa0f638d75da5ce141c`；本地可重放sidecar为`local-archive.sha256` |
| 解包根 | `opencode-04tmp3-20260904-095827/` |
| fio原始输出 | `cells/<CELL>/fio.txt`；每秒日志为`cells/<CELL>/bwlog/*_bw.1.log` |
| 单cell复算 | `cells/<CELL>/analysis.json` |
| cp原始计时 | `cells/R01,R04/cp-read.time`；`cells/W01,W04/cp-write.time` |
| 命令与身份 | `commands.sh`、`plans/runtime-scripts.sha256`、各cell `mount-state.tsv` |
| 恢复 | `recovery/`、`scrub/`、`READ/WRITE-objects-*.tsv`、`closure/CLEANUP_PASS` |
| 全量manifest | `closure/manifest.sha256`，626/626 PASS |
| GPT聚合复算 | 持久根顶层 `gpt-independent-recalc.tsv`，SHA256 `b21c2cd7dfd1d731c764438350310c859d75a5551ffc85f3968ff4dec1eab7b4` |
| GPT最终签收 | 持久根顶层 `gpt-final-signoff.tsv`，SHA256 `6f214a1cac170a9901f464c8a7282a1796556f5d1aa62e677b100371f80e1a08`；记录归档/环境/远端副本生命周期最终状态 |

## 七、下一步

本任务在 L1 边界结束，不自动补样：

- 不继续 `buffer-size=1024`；它相对 F 没有增益。
- 若 20 MiB direct 单流读是生产真实模型，可新建最小 A/R 正式确认，并同步跑七项原口径回归；否则
  将 R 仅记录为竞品命令适配信号。
- 写侧只有在业务重视 16 MiB fio/cp 口径时，才值得做精简的 A/F 交错确认；否则写组因漂移直接关闭。
- 无论是否补测，都不把本报告的大块值覆盖到 `results-table` 的七项 256 KiB 基线。
