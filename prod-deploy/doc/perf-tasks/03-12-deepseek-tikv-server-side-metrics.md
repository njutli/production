# 03-12-deepseek：补跑段D——TiKV/PD 服务端指标抓取（F44 归属闭环）

> 任务书类型：**一个归属闭环采集**（无通过/不通过——只出数据与候选，归属分析归分析侧）
> 作者：DeepSeek　｜　日期：2026-08-14　｜　执行方：GLM
> 母文档：03-8 报告 §13.4（F44 候选）、03-11 报告 §六.1（F44 升格"已点名（客户端侧）"）、计划书 §2.4b（F44/F45）
> 🔴 **所有统计量与归属分析由 DeepSeek 做，GLM 只出原始数字与原文粘贴**
> 🔴 脚本：`scripts/FULLBASELINE/debug/t42-segD.sh`（scp 到 `/tmp/`），判档门复用 `/tmp/t39-nsbgate.sh`
> 🔴 二进制：**`/tmp/juicefs-03-8`（生产候选构建 = v1.3.1 + eaf3d21f 部分读 + flushfix 同步 slice ID，md5 `1f60618c44fda1c19fecd75d52e053e9`）**——段0 先复核 md5。⛔ 不用 stock 版（它会塌，meta 墙不显形）。

---

## ⚑ 计划线

```
03-8/03-10/03-11 已证：写侧 ~3000 墙 = meta 提交管线（四会话，客户端侧闭环）
        ——吞吐 = 客户端在飞 meta 队列 ÷ TiKV 每 op 延迟
03-9 段D 未跑（-o max_read 分离挂载失败）⇒ TiKV 服务端归属至今是缺口
03-11 段A 补证：墙随 TiKV 延迟漂移（85→315ms），客户端在飞队列 524→2192 补偿加深
★ 03-12（你在这里）：
  环境静置检查（meta 提交率回白天态 ≥8K/s，最多等 2h）→ TiKV/PD 端点可达性
  → 判档门 → randwrite（打墙）×2 + randrw（不打墙，对照）×1，各配 1Hz TiKV/PD 指标抓取
        │
  产出 → 分析侧定归属：TiKV 饱和 / 单 region 热点 / compaction 积压 / 客户端并发盖顶 四选一
  定归属 → 下一任务按类型出解法（调参/分片/上游优化/客户端批处理）
一句话：给 F44 补上 TiKV 服务端数据，让"写侧墙"从客户端侧点名走向完整闭环。
```

---

## 〇、背景

F44（计划书 §2.4b）：写吞吐 = 客户端在飞 meta 队列（~0.5~2.2K）÷ TiKV 每 op 延迟。四会话把客户端侧钉死，但 TiKV 侧两种可能未区分：**TiKV 真饱和/热点/积压**（12K txn/s 对 3 节点 TiKV 很低，除非单 region 热点或 compaction 积压），还是**客户端并发盖顶**（延迟 120~315ms 本身异常，需服务端视角解释）。03-9 段D 因分离挂载失败未跑，本任务补上。

## 一、目标

- **唯一交付**：健康 randwrite（打墙态）与 randrw（对照态）期间的 **TiKV/PD metrics 抓取原始数据** + 静置检查/可达性/判档记录。**归属判定由分析侧做，GLM 不出结论**（R3/R4）。

## 二、口径与矩阵

- 二进制：`/tmp/juicefs-03-8`（段0 复核 md5 + `version` 串）。
- 挂载：`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`；判档门 = ns/B（I1 直连 mseqread 探针，参照 3.287 ±10%，重试换 label）。
- 效应轮（fio 与 V4 逐字同参）：
  - randwrite ×2：`storage_test`，`bs=256k rw=randwrite iodepth=128 numjobs=128 direct=1`，180s；
  - randrw ×1（对照，meta 率低于墙）：`rw_test`，同上参数 `rw=randrw`，180s。
- TiKV/PD 抓取：6 端点（PD `2379/metrics`、`9090/metrics`；TiKV `20180/metrics`、`20181/metrics` ×3 主机）1Hz，指标前缀 `grpc_server_handling|pd_server|tikv_grpc_msg_duration|tikv_scheduler|tikv_engine|etcd_server|tikv_server_report|tikv_raftstore|tikv_storage|tikv_grpc_messenger`，每轮 240s 上限。
- ⚑ **环境静置检查（新标准前置，本任务首次落地）**：60s randwrite 探针 → i1 算 meta 提交率（Δmeta_total ÷ 实际窗口）。**判定：≥8000/s = 白天态 ⇒ 继续；否则等 30min 重查，最多 4 次（2h）**；仍不达标 ⇒ 记录并继续执行，但全部数据标注"退化态"。

## 三、判据（每条指名来源）

| # | 判据 | 值域 | 数据来源 |
|---|---|---|---|
| Q1 | 静置检查 | meta 率 ≥8000/s（白天态；退化态 5~7K/s） | `quiesce.log` + `i1-quiesce-*.tsv`（率=Δ`meta_ops_durations_histogram_seconds_total`÷窗口，窗口取 TSV 首末时间戳） |
| G1 | 判档门 | ns/B ∈ [2.958, 3.616]（3.287±10%），重试换 label | `probe-gate.log` |
| D1 | 可达性 | 6 端点逐个 http 码 | `tikv-reach.log` |
| D2 | 抓取 | 3 轮各 1 个 `tikv-metrics-*.txt`（行数 + 端点分布） | `tikv-metrics-*.txt`（内容由分析侧解析，GLM 不判） |
| E | 环境 | HEALTH_OK、compact 三指标全绿、md5 复核 | `health.txt`、`wrapper.log` |

## 四、执行步骤

**步骤 0（测试前）**：通读 TESTING-GUIDE §1.3/§2.2/§3、AUTHORING-GUIDE §二.8/§二.10/§二.11。本任务无 layout/destroy/pool 操作。
1. `md5sum /tmp/juicefs-03-8` 复核 = `1f60618c…`；`bash -n /tmp/t42-segD.sh`；scp 脚本到 `/tmp/`。
2. 跑 `bash /tmp/t42-segD.sh`：health/compact/drop_caches → 挂载 → **静置检查循环**（含 30min 等待，注意观察 quiesce.log 每次探针的 meta 率走势）→ 可达性 → 判档门 → 3 效应轮 → 收尾 health。
3. 静置等待期间每 10min `tail quiesce.log`；任何 STOP ⇒ 停并回报。
**末步**：skill 合规自查（同 03-9 清单）；任一不符显式标注。

## 五、交付物（157 `/tmp/opencode-t3.12/`）

1. `quiesce.log` 全文（每轮探针的 meta 延迟/率/bw + 等待次数 + 最终判定）
2. `tikv-reach.log` 全文；`tikv-metrics-*.txt` 3 个文件的行数与大小（不粘全文）
3. `i1-{quiesce-*,probe-*,T42D-*}.tsv` 行数逐文件
4. `fio-*.txt` 的 bw 行；`probe-gate.log`、`remount-retry.log` 全文
5. `health.txt`、`wrapper.log`、`progress.txt` 全文；`mount.log` 尾部
6. 异常与偏差逐条（含"静置检查未达标仍继续"的标注）

## 六、风险与红线

1. ⛔ 全程不碰 `/usr/local/bin/juicefs`、`/tmp/ray`；无 layout/destroy；157 业务路径禁动。
2. 抓取失败（端点全不可达）只记录不重试不推断；归属结论不由 GLM 出。
3. 静置检查未达标继续执行 = **已授权**（§二口径），但必须在交付物第 6 条显式标注"退化态"。
4. 效应轮是写操作：3 轮 × 180s ≈ 600~700 GiB 覆盖写 + 对象净增 ~2.5M——在既定预算内（当前池 ~7M，上限 15M）。
5. 时钟：157 时间 = WSL − 1h；归档 mtime 偏差照录。

## 七、时间预算

| 段 | 内容 | 预算 |
|---|---|---|
| 静置检查（含等待） | 0.2h ~ 2.2h（取决于环境恢复速度） | |
| 可达性 + 判档门 | ~0.3h | |
| 效应轮 ×3 + 抓取 | ~0.3h | |
| **合计** | **~0.8h ~ 2.8h**，白天单会话 | |

砍单顺序：randrw 对照轮 → 静置等待第 3/4 次。⛔ 静置检查、randwrite 两轮不可砍。
