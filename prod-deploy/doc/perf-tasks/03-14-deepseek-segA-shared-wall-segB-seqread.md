# 03-14-deepseek：段A 读写共享性补跑（今晚）+ 段B seqread 转正 3 实例（明早日间窗口）

> 任务书类型：**两个独立 P 段**（段A：读写墙共享性判定；段B：seqread 转正收口）
> 作者：DeepSeek　｜　日期：2026-08-14　｜　执行方：GLM（段A 今晚、段B 明早日间窗口）
> 母文档：03-9（段A2 未跑）、计划书 §3.4（seqread 转正条件）、F42/F44（两侧墙）
> 🔴 **统计与判定由 DeepSeek 做，GLM 只出原始数字与原文粘贴**
> 🔴 脚本：`t44-night-morning.sh` + `scripts/FULLBASELINE/probe/env-snapshot.sh`（scp 到 `/tmp/`）；判档门复用 `/tmp/t39-nsbgate.sh`

---

## ⚑ 计划线

```
03-9 段A2 未跑（-o max_read 分离挂载失败）⇒ 读写共享性至今未知
03-11 段A 已证：写墙（F44）随 TiKV 延迟漂移；读墙（F42）在 librados 排队
03-12/03-13 排队中：F44 TiKV 归属闭环 + F42 下载并发点名
★ 03-14（你在这里）：
  段A（今晚，~0.6h）：/tmp/juicefs-03-8 补丁版 256K 挂载，randread+randwrite 并行
     ├─ A2a 独立：读≈[3906,4219] 且写≈[2817,3397]，合计≈7 GiB/s ⇒ 两侧墙各治各的
     ├─ A2b 共享：合计≈4.1 GiB/s ⇒ 客户端串行资源读写共用
     └─ A2c 部分共享：合计介于两者
  段B（明早，~1.5h）：seqread 转正——3 实例（stock 128K，签收基线同口径）+ 判档门 + 各 2 轮
     ⇒ 3 实例中位 vs week3 平台 [1234,1324]（计划书 §3.4 转正条件：≥3 实例含日间窗口）
一句话：补上读写共享性这个 6250 路径问题，并用明早的日间窗口把 seqread 转正收口。
```

---

## 〇、背景

- **段A**：读墙（F42 ~4.1 GiB/s）与写墙（F44 meta ~3000）是独立还是共享，决定 6250 的路径——共享则两向无法同时达标；独立则各治各的。03-9 因分离挂载失败没跑成；现在补丁版 256K 挂载（写侧健康）让这个实验重新可行。
- **段B**：seqread 是七项里最后一个未转正项（签收基线 1290 条件）；计划书 §3.4 的转正条件 = **≥3 实例含日间窗口**——明早正是日间窗口，且纯读不扰动环境。

## 一、目标

- **段A（只报数据，预登记对账）**：A2a/A2b/A2c 三结局哪个成立（判定由分析侧做）。
- **段B（只报数据）**：3 实例 seqread 数据；转正判定由分析侧做。

## 二、口径与矩阵

- 段A：二进制 `/tmp/juicefs-03-8`（md5 `1f60618c…`，段0 复核），`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`；判档门后 **randread(read_test) 与 randwrite(storage_test) 两个 fio 并行**，各 128 jobs × 180s（V4 逐字参数，读侧加 `--readonly`）；i1 采样 + 环境快照 pre/post。
- 段B：stock 128K（`--max-uploads 150 --cache-size 0`），3 实例 ×（ns/B 判档门 + seqread 2 轮）；seqread 参数与 V4 逐字（`directory=seqread/ bs=256k rw=read refill_buffers size=32G direct=1 ioengine=psync iodepth=1`，180s）。
- ⚑ 环境前置（GUIDE §二.12，本任务首次全量执行）：每段开跑前 `env-snapshot.sh pre`、收尾 `post`；段A 是写类 ⇒ 前置 health + compact 三指标 + drop_caches + **meta 静置检查**（60s randwrite 探针率 ≥8000/s；不达标 30min 等待 ×4，仍不达标则标注"退化态"继续）；段B 纯读 ⇒ 仅 health + compact + drop_caches。

## 三、判据（每条指名来源）

| # | 判据 | 值域 | 数据来源 |
|---|---|---|---|
| A1 | 读写共享性 | 预登记：A2a 读≈[3906,4219] 且写≈[2817,3397] 合计≈7 GiB/s｜A2b 合计≈4.1｜A2c 介于 | `summary.tsv` 行 `T44A*-rwcon` + 两个 `fio-*.txt` + `i1-T44A*.tsv`（分析侧对账） |
| B1 | seqread 3 实例 | 各实例中位 + 3 实例中位；对照 week3 [1234,1324] | `summary.tsv` T44B-* 行 |
| G | 判档门 | ns/B ∈ [2.958, 3.616]，重试换 label | `probe-gate.log` |
| E | 环境 | HEALTH_OK、快照 pre/post 落盘、静置检查记录 | `env-snapshot-*.txt`、`health.txt`、`quiesce.log` |

## 四、执行步骤

**步骤 0（测试前）**：通读 TESTING-GUIDE §1.3/§2.2/§3、AUTHORING-GUIDE §二.8/§二.10/§二.11/§二.12。本任务无 layout/destroy/pool 操作；段B 全程只读。
1. scp `t44-night-morning.sh` + `env-snapshot.sh` 到 `/tmp/`；`md5sum /tmp/juicefs-03-8` 复核；`bash -n` 两脚本。
2. 今晚：`bash /tmp/t44-night-morning.sh`（段A 自动执行，含静置检查）。
3. 明早（日间窗口，08:00-12:00 157 时间）：`RUN_A=0 bash /tmp/t44-night-morning.sh`（段B 3 实例）。
4. 观察 `summary.tsv`/`wrapper.log`；任何 STOP ⇒ 停并回报。
**末步**：skill 合规自查——① 快照 pre/post 齐全；② 段A 写后 compact cooldown；③ 判档门重试换 label；④ 段B 无任何写入。任一不符显式标注。

## 五、交付物（157 `/tmp/opencode-t3.14/`）

1. `summary.tsv`、`wrapper.log`、`progress.txt` 全文
2. `env-snapshot-seg{A,B}-{pre,post}.txt` 4 张全文
3. `i1-*.tsv` 行数逐文件；`fio-*.txt` 的 bw 行；`probe-gate.log`、`remount-retry.log`、`instances.txt` 全文
4. `health.txt` 全文；异常与偏差逐条（含"退化态"标注）

## 六、风险与红线

1. 段A 的 randwrite 是写操作（180s ≈ 130~450 GiB）：在静置检查之后执行，写后 compact cooldown（脚本收尾已含）。
2. ⛔ 不碰 `/usr/local/bin/juicefs`、`/tmp/ray`；无 ceph 集群侧配置变更；段B 全程只读。
3. 段B 必须**日间窗口**执行（转正条件），禁夜间代跑。
4. 时钟：157 时间 = WSL − 1h。

## 七、时间预算

| 段 | 内容 | 预算 |
|---|---|---|
| A | 静置（0.2~2.2h）+ 判档门 + 并行双 fio | ~0.6h（不含静置等待） |
| B | 3 ×（判档门 6min + 2×180s） | ~1.2h（明早） |

砍单顺序：段B 的第 3 实例 → 段A 的静置等待第 3/4 次。⛔ 段A 的并行双 fio 与段B 前 2 实例不可砍。
