# 03-8-deepseek：randwrite@256K 崩塌根因修复验证（write 路径 FlushTo 竞态补丁）

> 任务书类型：**一个根因修复验证**（DeepSeek 源码定位 + 补丁，GLM 执行验证）
> 作者：DeepSeek（opencode 复核）　｜　日期：2026-08-13　｜　执行方：GLM
> 母文档：03-7-lite 分析（`/tmp/opencode/t37l-analysis-20260813.md`）、评审（`/tmp/deepseek-coaching/review-20260813-03-7L.md`）
> 🔴 **所有统计量由 opencode 计算，GLM 只出原始数字与原文粘贴**（同 03-7-lite 口径）

---

## 一、背景与根因（源码 + 实测双证，修复对象明确）

03-7L 发现：`--max-fuse-io 256K` 下 **randwrite 崩塌 5.8×**（551 vs 128K 挂载的 3065~3701 MiB/s，14 轮稳定、极差 0.2%）。DeepSeek 通读 JuiceFS v1.3.1（e0032b2a，本地 `~/project/juicefs`）写路径后定位根因：

**根因链（每条均有代码行号 + 实测数据）：**

1. **每个 256K 写 = 一个新 slice**。`pkg/vfs/writer.go` `findWritableSlice` 仅在写位置**精确落在**既有 slice 末尾时才复用（`pos >= s.off+flushoff && pos <= s.off+s.slen`），随机写永不命中 ⇒ 每写新建 slice。实测：meta 写事务/写op = **0.99**（128K 挂载为 0.45——内核把 256K 应用写拆成两笔**连续** 128K FUSE 写，第二笔精确续写同一 slice）。
2. **上传派发被竞态永久跳过**。`pkg/vfs/writer.go:140-141`：`FlushTo`（=上传派发）带 `if s.id > 0` 守卫；而 id 由 `writer.go:268` 的 `go s.prepareID(...)` **异步**分配 ⇒ 每个新 slice 的唯一一次写必然读到 `id==0` ⇒ 跳过。此后该 slice 再无第二次写机会 ⇒ 数据只能等**冻结链**（同 chunk 内再积累 4 个 slice）或 **10s 强制刷**（`flushDuration*2`）才上传。
   - 注：`NewSlice` 本身是**本地计数器**（`pkg/meta/base.go:1654-1671`），µs 级；仅每 `sliceIdBatch=4096` 个打一次 TiKV。异步化省的是 0.02% 的场景，代价是 100% 的写路径滞留——这是设计失误。
3. **滞留 → 缓冲节流 → 57.7ms/写op**。i1 逐秒实测（157 `/tmp/opencode-t3.7l/i1-jfsstats-*.tsv`）：
   | 场景 | `juicefs_used_buffer_size_bytes` 均值/峰值 |
   |---|---|
   | S 臂(256K) 纯写 randwrite | **144.3 MiB / 609.2 MiB** |
   | F 臂(128K) 纯写 randwrite | 43.5 MiB / 415.5 MiB |
   | S 臂(256K) 混合 randrw | 29.8 MiB / 144.5 MiB |
   滞留把 `fileWriter.Write` 的 buffer 节流（>300M sleep 10ms、>600M sleep 100ms，`writer.go:299-304`）＋内核 `max_background=50` 准入排队全部激活 ⇒ FUSE 写 op 均值 **57.7ms**（128K 臂 3.7~4.9ms）⇒ 551 MiB/s（F40 公式闭环）。
4. 128K 挂载不受影响的原因：应用写 256K 被拆成两笔连续 128K ⇒ 第二笔续写 ⇒ `FlushTo` 命中 ⇒ 每 2 写即时上传（PUT/写op=0.52）。
5. **上游未修**：该竞态在 origin/main（含 1.4）仍存在（`git diff HEAD..origin/main -- pkg/vfs/writer.go` 无相关改动）。

**修复方向（本任务书验证两种 + 一种兜底）：**
- **P（本任务书 P0）**：补丁——写路径同步分配 slice id，消除 `id==0` 竞态 ⇒ 每写即时派发上传。
- **B（P1 兜底）**：`--buffer-size 4G` 抬节流阈值 ⇒ 节流不触发（滞留仍在，半修复，用于证伪/兜底）。
- **R（P1 兜底）**：`--max-fuse-io 128K -o max_read=262144` 读写分离 ⇒ 读 256K + 写 128K（评审 E5 路线）。

**目标（用户意图）**：让 `--max-fuse-io 256K` 提升**所有**测试项（读侧 +115.6% 已多次复现；本任务书消除写侧崩塌）。

---

## 二、补丁（P）

文件：`pkg/vfs/writer.go`，位置：`writeChunk` 中 slice 创建处（v1.3.1 第 262~268 行）。

```go
		s = &sliceWriter{
			chunk:   c,
			off:     off,
			writer:  f.w.store.NewWriter(0),
			notify:  utils.NewCond(&f.Mutex),
			started: time.Now(),
		}
		go s.prepareID(meta.Background(), false)
```

改为：

```go
		s = &sliceWriter{
			chunk:   c,
			off:     off,
			writer:  f.w.store.NewWriter(0),
			notify:  utils.NewCond(&f.Mutex),
			started: time.Now(),
		}
		// ⚑ DeepSeek-03-8：同步分配 slice id（NewSlice 为本地计数器，µs 级，
		// 仅每 sliceIdBatch=4096 个打一次 TiKV）。原异步写法使每个新 slice 的
		// 首次写因 id==0 竞态跳过 FlushTo，数据滞留至冻结链/10s 强制刷，
		// 256K 纯写崩至 551 MiB/s。失败时回退原异步路径。
		var id uint64
		if st := f.w.m.NewSlice(meta.Background(), &id); st == 0 {
			s.id = id
			s.writer.SetID(id)
		} else {
			go s.prepareID(meta.Background(), false)
		}
```

- 无死锁：`NewSlice` 只取 `baseMeta.freeMu`（`base.go:1654`），不取文件锁；调用点已在 `f.Mutex` 保护内，`s.id` 读写均在该锁下，无数据竞争。
- 编译基座：**v1.3.1（e0032b2a）+ cherry-pick eaf3d21f**（loadRange 读路径修复，现网二进制含它，重建必须同源）+ 本补丁。
- 版本标识：重建后 `juicefs version` 会带 dev 后缀 ⇒ 天然的"补丁版"身份标识。

---

## 三、执行设计

### 3.0 段0：部署与冒烟（GLM，~15min）

1. 补丁版二进制已就位：**157 上 `/tmp/juicefs-03-8`**，md5 **`1f60618c44fda1c19fecd75d52e053e9`**，版本串 `juicefs version 1.3.1+2026-08-13.e0032b2a-03-8-ceph`（⚑ 2026-08-13 第二版：**带 Ceph 后端**，`-tags ceph` + librados 17.2.9 头文件编译，与 157 运行时 librados2 17.2.9 同版本；第一版 f31c619a 无 Ceph 已作废）。⛔ 禁止触碰 `/usr/local/bin/juicefs`。段0 第 1 步先复核 `md5sum /tmp/juicefs-03-8` 与上值一致再开工。
2. `chmod +x /tmp/juicefs-03-8 && /tmp/juicefs-03-8 version` → 记录版本串（应与上面一致）。
3. 冒烟：用 03-7-lite 的挂载命令（`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`）挂 `juicefs-prod`（META=`tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod`），验 `max_read=262144`，`fio` 直写 10s（任意临时文件，测完删除），验 rc=0 后 umount。任何异常立即停并回报。

### 3.1 段1（P0，~1.5-2h）：补丁版 vs 原版，ABBA，256K 挂载

| run | 顺序 | 臂 | 二进制 |
|---|---|---|---|
| 1 | A1 | P（补丁版） | `/tmp/juicefs-03-8` |
| 2 | B1 | S（原版） | `juicefs`（现网） |
| 3 | B2 | S（原版） | `juicefs`（现网） |
| 4 | A2 | P（补丁版） | `/tmp/juicefs-03-8` |

- 每挂载流程（沿用 03-7-lite §十五）：
  1. 挂载（对应二进制）+ 验 `max_read=262144` + 记 `pid`/`starttime_ticks`（`instances.txt`）。
  2. **探针门（ns/B 判别器）**：`mseqread` 2 轮（`ITEMS="mseqread"`），算 `ops_durations_histogram_seconds_sum/total ÷ read_size_bytes_sum/ops_total_read`，与参照 **3.287 ns/B** 偏离 >10% ⇒ 丢弃重挂，⛔ **重试必须换 label**（`T37-8-A1-t1/t2/t3` 式，§二.10.4.1 硬规则）。
  3. 效应项：`randwrite` 2 轮 → `randrw` 2 轮（V4 口径，`JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"`）。
  4. `health` 落盘一次。
- **判据（数据来源全部指名）**：
  - 主判据【randwrite 恢复】：P 臂 randwrite 中位数（`rounds.tsv` 列 3）vs S 臂。目标 **≥ +200%（即 ≥1653 MiB/s）**；若 P 臂落入 128K 平台区间 **2942~3258**（REFERENCE-VALUES 表一）⇒ 判"修复成立且不劣于 128K 基线"。
  - 无回归判据【randrw】：P 臂 randrw 单方向中位数落在 256K 平台 **1931~1978** 的 ±5.56%（判定门槛）内。
  - 机制实证判据【i1 逐秒】：P 臂 `juicefs_used_buffer_size_bytes` 均值应回落至 **≤50 MiB** 量级（S 臂实况 144.3 MiB）；`juicefs_object_request_uploading` 出现非零采样。
  - 档位门：每挂载 ns/B 与 3.287 偏离 ≤10%（§二.10.3）。
  - 环境门：`arm-verify.txt` 的 `max_read_pre/post=262144`、`health` 全 `HEALTH_OK, 33 active+clean`、12 run 无 `SMOKE`。
- 若 ABBA 四挂载不能干净分离（P 两挂载不全高于 S 两挂载）⇒ 追加 P3/S3 各一（按 §二.10.4.3，提升结论需 ≥3 挂载/臂；本轮预期效应 ~+5×，远大于档位噪声上界 1.43×，四挂载即可判，追加仅为保险）。

### 3.2 段2（P1 兜底，仅段1 未达标时执行，~15min）

- 原版二进制，1 挂载，`--max-uploads 150 --cache-size 0 --max-fuse-io 256K --buffer-size 4096`，探针门同上，`randwrite` 2 轮。
- 判据：randwrite 中位数 ≥1653 MiB/s ⇒ "节流是主制动"成立（补丁仍需，因内存滞留未除）；否则记录并转段3。

### 3.3 段3（P1 兜底，仅段1/段2 均未达标时执行，~20min）

- 原版二进制，1 挂载，`--max-fuse-io 128K -o max_read=262144`，验 `/proc/mounts` 中 `max_read=262144` 且写侧 max_write 仍 128K（`mount-cmd.txt` 记录），探针门同上，`randread` 2 轮 + `randwrite` 2 轮。
- 判据：randread 中位数落入 **4027~4096**（256K 平台）±3%、randwrite 落入 **2942~3258**（128K 平台）±4.26% ⇒ "读写分离路线可用"。

---

## 四、时间预算与砍单顺序

| 段 | 内容 | 预算 |
|---|---|---|
| 0 | 部署+冒烟 | 0.25h |
| 1 | 补丁 A/B（4 挂载 × ~18min） | ~1.5h（含重挂） |
| 2 | buffer-size 兜底 | 0.25h（按需） |
| 3 | -o max_read 兜底 | 0.35h（按需） |
| **合计** | | **≤2.5h**，白天单会话可跑 |

砍单顺序：**段3 → 段2 → 段1 的 randrw 轮次**。⛔ 段1 的 randwrite A/B 不可砍。

---

## 五、交付物清单（GLM，全部落盘 157 `/tmp/opencode-t3.8/`）

1. `arm-verify.txt` 全文（含每挂载 `max_read_pre/post`、`want`、二进制路径）
2. `instances.txt` 全文（pid + starttime_ticks + 二进制路径；**补丁版与原版 pid 必须不同**）
3. `bw-raw.tsv` 全文、`rounds.tsv` T37-8-* 行、`budget.txt` 全文（64/92 行口径，不截断不改写）
4. `probe-gate.log` + `remount-retry.log` 全文（重挂次数逐臂报出；重试 label 必须不同）
5. 每挂载 i1 逐秒文件（`i1-jfsstats-*-T37-8-*.tsv`）行数；`health.txt` 全文
6. `juicefs-03-8 version` 输出原文；段0 冒烟 rc
7. 异常与偏差逐条（含任何 pid 异常、rc 非零、SMOKE 残留）

---

## 六、风险与污染规则

1. **补丁不生效**（57.7ms 另有其因）：段1 显示 P 臂 randwrite 仍 ~551 ⇒ 停止下"修复失败"结论之外的一切推断，转段2/段3，并保留 i1 数据供下一轮定位。
2. **新瓶颈显形**：补丁后若 randwrite 停在新的天花板（如 meta 提交率、上传管线），按"记录现象 + 出 i1/预算数据"处理，**不下"已修复到极限"结论**（R3：灵敏度未证）。
3. **内存安全**：补丁后缓冲若冲高，i1 峰值 >4 GiB ⇒ 立即停该项（P0 保护），回报不自行处理。
4. **坏档**：ABBA 对称 + ns/B 门 + 重试换 label（§二.10）；任何"提升"结论附坏档压力测试（d_max=−30%）。
5. ⛔ `/usr/local/bin/juicefs` 全程不得改动；补丁版只放 `/tmp`。
6. 时钟：157 时间 = WSL − 1h；归档 fio mtime 与报告时间线有 ~55min 系统性偏差（已记档，报告照录即可）。
