# U141 ABBA 非劣性测试报告：patched v1.4.1 vs patched v1.3.1

## 日期：2026-08-24

---

## 1. 测试概述

回答一个问题：patched v1.4.1 在 randread / randrw / randwrite / mseqwrite 四项上，相对 patched v1.3.1 是否非劣。

方法：同夜 4 block ABBA（A=v1.3.1, B=v1.4.1+补丁），每 block 4 项 × 2 轮，共 32 cell。`OBJ_GATE=1` 修复 V4 rc=1 问题，全程单进程跑完。

## 2. 测试环境

| 项 | A 臂 | B 臂 |
|---|---|---|
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` | `/tmp/juicefs-1.4.1-patched`，md5 `24fae0852051c80ca571cb2f20275d46` |
| PATH shim | `/tmp/t53-bin-new/juicefs` | `/tmp/t141p-bin/juicefs` |
| 版本 | `1.3.1+2025-12-02.e0032b2a` + 补丁 | `1.4.1+unknown` + 补丁 |
| 补丁 | writer.go prepareID 中 SetID 后补 FlushTo | 相同 |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` | 相同 |
| Ceph 客户端 | 进程私有 conf，ms_async_op_threads=8 | 相同 |
| fio | 3.28，256K bs，128 jobs，iodepth=128，direct=1，180s | 相同 |
| V4 脚本 | FULLBASELINE_V4.sh (md5 4198ea26...)，OBJ_GATE=1 | 相同 |

## 3. 执行结果

| Block | 臂 | 二进制 | 开始 | 耗时 | V4 rc | 轮目录数 |
|---|---|---|---:|---:|---:|---:|
| UP1A | A | v1.3.1 | 14:26 | 77min | 0 | 8 |
| UP2B | B | v1.4.1+补丁 | 15:43 | 97min | 0 | 8 |
| UP3B | B | v1.4.1+补丁 | 17:21 | 100min | 0 | 8 |
| UP4A | A | v1.3.1 | 19:01 | 117min | 0 | 8 |

- 32/32 cell VALID，PG 全程 active+clean
- S23：UP4A 墙钟 117min > 110min（记录，非致命）
- 批首/批尾不变量全部一致（二进制/conf/V4 md5 起止不变，health=HEALTH_OK）
- `OBJ_GATE=1` 成功修复 V4 rc=1 问题，4 block 全部单进程跑完

## 4. 全部 32 cell 原始数据

### 4.1 randread（MiB/s）

| Block | 臂 | r1 | r2 |
|---|---|---:|---:|
| UP1A | A | 5537 | 5561 |
| UP2B | B | 5482 | 5516 |
| UP3B | B | 5595 | 5546 |
| UP4A | A | 5470 | 5555 |

### 4.2 randrw（MiB/s）

| Block | 臂 | r1 | r2 |
|---|---|---:|---:|
| UP1A | A | 1849 | 1866 |
| UP2B | B | 1812 | 1808 |
| UP3B | B | 1731 | 1737 |
| UP4A | A | 1767 | 1813 |

### 4.3 randwrite（MiB/s）

| Block | 臂 | r1 | r2 |
|---|---|---:|---:|
| UP1A | A | 2649 | 2544 |
| UP2B | B | 2570 | 2530 |
| UP3B | B | 2552 | 2576 |
| UP4A | A | 2611 | 2625 |

### 4.4 mseqwrite（MiB/s）

| Block | 臂 | r1 | r2 |
|---|---|---:|---:|
| UP1A | A | 4212 | 4830 |
| UP2B | B | 4691 | 4752 |
| UP3B | B | 4178 | 4997 |
| UP4A | A | 4664 | 4590 |

## 5. 不变量验证

### 批首

| 项 | 值 |
|---|---|
| juicefs-03-8 md5 | de93563f11a5ff3bd94dd25a4e0283b1 |
| juicefs-1.4.1-patched md5 | 24fae0852051c80ca571cb2f20275d46 |
| t141-msgr8.conf md5 | 86351c58848c7e4caaa1bbeccb211730 |
| ceph.conf md5 | 5b6be34179a64e0a5f9c6d3a9690041f |
| V4 md5 | 4198ea2676ba56744a3cd5eba17a5eab |
| health | HEALTH_OK |

### 批尾

| 项 | 值 | 与批首一致 |
|---|---|---|
| juicefs-03-8 md5 | de93563f11a5ff3bd94dd25a4e0283b1 | ✓ |
| juicefs-1.4.1-patched md5 | 24fae0852051c80ca571cb2f20275d46 | ✓ |
| t141-msgr8.conf md5 | 86351c58848c7e4caaa1bbeccb211730 | ✓ |
| ceph.conf md5 | 5b6be34179a64e0a5f9c6d3a9690041f | ✓ |
| V4 md5 | 4198ea2676ba56744a3cd5eba17a5eab | ✓ |
| health | HEALTH_OK | ✓ |

## 6. 脚本偏离说明

1. **u141-cells.tsv 数据提取不完整**：脚本生成 u141-cells.tsv 时，从 jfs-stats 文件提取 meta 计数器的逻辑有 bug（AWK 匹配问题），导致 cells.tsv 只有表头无数据行。rounds.tsv 数据完整，per-round 的 jfs-stats-pre/post.txt 文件保留在各自轮目录中，可供 GPT 手动提取。
2. **Block 级归档未自动生成**：脚本在 Phase 5 批尾归档阶段退出，4 个 block 的独立 tar.gz 未生成。手动打包了 `opencode-u141.tar.gz`（含 4 block 目录 + rounds.tsv + test.log + 不变量 + STOPS.md）。
3. **S23 UP4A 墙钟超限**：UP4A 耗时 117min > 110min 阈值，记录为 S23。数据完整，不影响有效性。
4. **pool tail 对象数显示异常**：invariants-batch-tail.txt 中 pool_objects=1.3 和 pool_stored=3 是 `ceph df` 输出解析问题（列偏移），实际对象数从 rounds.tsv 的 obj_gate 记录可见（cleanup 后回到 ~2.43M）。

以上均不改变实验变量（ABBA 顺序、二进制、配置、V4 脚本）。

## 7. 证据位置

| 文件 | 位置 |
|---|---|
| Archive | `/home/lilingfeng/tmp/production/opencode-u141.tar.gz`（md5 `413487b7...`） |
| 157 产物 | `/tmp/production/opencode-u141.tar.gz` |
| V4 rounds.tsv | Archive 内 |
| V4 test.log | Archive 内 |
| STOPS.md | Archive 内（仅 S23） |
| T141 系列留存包 | `/home/lilingfeng/tmp/production/opencode-t141-preserve.tar.gz`（157） |
| 任务书 | `doc/perf-tasks/v141-upgrade-decision-datafill.md` |
| u141 脚本 | `scripts/FULLBASELINE/debug/u141-upgrade-abba.sh` |

## 8. 待 GPT 分析

- 32 cell 的 BW 数据已在 rounds.tsv 中，jfs-stats-pre/post.txt 在各轮目录中
- 预登记非劣边界：randread -3%, randrw -3%, randwrite 流形残差 ±74.8 MiB/s, mseqwrite -5%
- 漂移检查（randread 作锚点）、randwrite 流形残差、mseqwrite 功效声明均按任务书 §9 执行
- GLM 不做统计判决，等待 GPT 从原始数据计算
