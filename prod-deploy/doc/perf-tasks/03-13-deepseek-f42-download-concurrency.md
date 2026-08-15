# 03-13-deepseek：F42 最后点名——下载并发扫描（T1）+ 条件性 librados 参数（T2）

> 任务书类型：**一个分支式实验**（T1 无条件；T2 由 T1 结果自动决定，脚本内置判定）
> 作者：DeepSeek　｜　日期：2026-08-14　｜　执行方：GLM
> 母文档：03-9 报告 §9.5 / 03-11 报告 §6.5（F42 = librados 读路径排队墙，在飞对象读 ~94 × 5.6ms）、计划书 §2.4b（F42）
> 🔴 **统计与点名结论由 DeepSeek 做，GLM 只出原始数字与原文粘贴；脚本内置的数值分支是执行开关，不是结论**
> 🔴 脚本：`scripts/FULLBASELINE/debug/t43-f42.sh`（scp 到 `/tmp/`）；二进制：main edabf9c2 `/tmp/juicefs-main-stock`（含 #6472 `--max-downloads`，md5 `f5541d20654cc56bd80c678620540243`，段0 复核）

---

## ⚑ 计划线

```
03-9/03-11 段B 双实例：F42 = librados 读路径排队墙（~4.1 GiB/s，在飞对象读 ~94 × 5.6ms）
   ——达 6250 需 25K 读/s × 5.6ms = 140 在飞（缺口 ~1.5×）
查证：main #6472 --max-downloads（默认 200）= currentDownload 信号量；v1.3.1 无此旋钮
★ 03-13（你在这里）：
  T1（无条件）：--max-downloads {200, 512, 1024} 扫描 × randread j128，各配 pprof+i1
     ├─ 破墙（1024 档 ≥4200 或 Δ≥+3%）⇒ F42=下载并发墙 ⇒ 下一步反向同步 #6472 到 1.3 生产构建
     └─ 不破墙 ⇒ T2（脚本自动转）
  T2（条件）：ceph.conf [client] 参数 t2a ms_async_op_threads=8 → t2b 叠加 objecter_inflight_ops=4096
     ├─ 破墙 ⇒ 墙在 librados 消息层/objecter
     └─ 仍不破 ⇒ F42 更深层，另起分析
一句话：用两个可回滚的客户端旋钮把 F42 的"哪条队列"点出来，并直接回答"有没有解"。
```

---

## 〇、背景

F42 已框定到 librados 读路径（03-9 §9.5/03-11 §6.5）：j128 时在飞 rados_read ≈ 94、单读 5.6ms（OSD 侧仅 0.48ms，F41），CPU 仅 4.5 核。两个候选盖子：**客户端下载并发**（main 有 `--max-downloads` 旋钮、默认 200；v1.3.1 无）与 **librados 内部**（async messenger 线程数默认 2~3、objecter 在飞上限）。T1/T2 分别打这两个盖子，全程只读、参数可回滚。

## 一、目标

- **T1（唯一通过/不通过项）**：`--max-downloads` 三档扫描的 bw 曲线 + 各点 pprof（在飞 rados_read 数）。**分支判据（脚本内置，数值开关非结论）**：1024 档 bw ≥ 4200 或 相对 200 档 ≥ +3% ⇒ 破墙 ⇒ T2 跳过；否则 T2 执行。
- **T2（条件，只报数据）**：ceph.conf 两档参数后的 bw + pprof。破墙与否由分析侧定。

## 二、口径与矩阵

- 二进制：`/tmp/juicefs-main-stock`（段0 `md5sum` 复核）；挂载基座 `--max-uploads 150 --cache-size 0 --max-fuse-io 256K`。
- T1 三档 = 三次挂载（`--max-downloads` 是挂载参数）：`200`（默认对照）、`512`、`1024`。
- T2 两档 = 两次挂载（参数从 ceph.conf 读，进程启动时生效）：t2a `[client] ms_async_op_threads = 8`；t2b 叠加 `objecter_inflight_ops = 4096`。
- 每档：**ns/B 判档门**（I1 直连 mseqread，3.287±10%，重试换 label）→ randread j128（V4 逐字参数 + `--readonly`）1 轮 180s → pprof goroutine dump（t=120s）+ i1。
- ⛔ 全任务**只读**（randread/mseqread 均只读），零写入零对象变化。

## 三、判据（每条指名来源）

| # | 判据 | 值域 | 数据来源 |
|---|---|---|---|
| T1-1 | 分支开关 | 1024 档 bw ≥4200 或 (B3−B1)/B1 ≥ +3% ⇒ 跳过 T2；否则执行 T2 | `progress.txt`（脚本自动判定并落盘） |
| T1-2 | pprof 并发 | 各点在飞 rados_read 数（分析侧数） | `pprof-goroutine-T43A-*.txt` |
| G | 判档门 | ns/B ∈ [2.958, 3.616]，重试换 label | `probe-gate.log` |
| T2-1 | 配置护栏 | ceph.conf 测前备份 md5、测后还原 + `md5sum -c` 通过 | `ceph-conf-md5.txt`、`ceph-conf-verify.txt` |
| E | 环境 | HEALTH_OK、全程无写入 | `health.txt` |

## 四、执行步骤

**步骤 0（测试前）**：通读 TESTING-GUIDE §2.2、AUTHORING-GUIDE §二.8/§二.10/§二.11。本任务**无 layout、无 destroy、无写入、无 ceph 集群侧配置变更**。
1. `md5sum /tmp/juicefs-main-stock` 复核 = `f5541d20…`；`bash -n /tmp/t43-f42.sh`；scp 到 `/tmp/`。
2. 跑 `bash /tmp/t43-f42.sh`（T1 → 自动分支 → 可能的 T2 → ceph.conf 强制还原 → 恢复默认挂载）。
3. 观察 `progress.txt`/`wrapper.log` 的分支日志行；任何 STOP ⇒ 停并回报。
**末步**：skill 合规自查——⛔ **必查**：① ceph.conf 已还原且 `ceph-conf-verify.txt` 全 OK；② 全程无写入命令执行；③ 判档门重试换 label。任一不符显式标注。

## 五、交付物（157 `/tmp/opencode-t3.13/`）

1. `progress.txt`、`wrapper.log` 全文（含 T1 三档 bw + 分支判定行）
2. `pprof-goroutine-T43*.txt` 文件清单与行数；`i1-T43*.tsv` 行数
3. `fio-T43*.txt` 的 `READ: bw=` 行；`probe-gate.log`、`remount-retry.log`、`instances.txt` 全文
4. `ceph-conf-md5.txt`、`ceph-conf-verify.txt`、`ceph.conf.original`（若 T2 执行）
5. `health.txt` 全文；异常与偏差逐条

## 六、风险与红线

1. ⛔ ceph.conf 改动仅限 [client] 节两条参数；测后强制还原 + md5 校验（脚本内置，交付物第 4 条）。
2. ⛔ 全程只读；不碰 `/usr/local/bin/juicefs`、`/tmp/ray`；无任何 ceph 集群侧（OSD/MON/TiKV）配置变更。
3. T2 若 t2a 已破墙，t2b 仍照跑（叠加档，用于确认方向）——脚本顺序固定。
4. 分支判定只控制执行流，**结论由分析侧出**（R3/R4）。
5. 时钟：157 时间 = WSL − 1h；归档 mtime 偏差照录。

## 七、时间预算

| 段 | 内容 | 预算 |
|---|---|---|
| T1（3 挂载 ×（门 ~6min + 180s）） | ~1h | |
| T2（2 挂载 × 同） | ~0.4h（仅 T1 不破墙时） | |
| **合计** | **~1h ~ 1.4h**，白天单会话 | |

砍单顺序：T2 的 t2b → T1 的 512 档。⛔ T1 的 200 与 1024 档不可砍（分支判据依赖）。
