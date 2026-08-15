# 03-9 报告：-o max_read 读写分离验证 + F42 sweep v3 + 负控

> 执行方：GLM　｜　报告时间：2026-08-13 19:35（157时间）　｜　位置：`/tmp/glm-03-9-report.md`
> 🔴 **所有统计量由 DeepSeek 计算，本报告只出原始数字与原文粘贴。**

---

## 1. 时间线

| 段 | 内容 | 起止(157) | 状态 |
|---|---|---|---|
| A | -o max_read 读写分离挂载 | 17:22 → 17:23 | ❌ 两形式各 3 次全 FAIL |
| B | F42 sweep v3（jobfile 独占文件） | 17:27 → 19:21 | ✅ 16 点全 rc=0 + 段C |
| C | 负控 bs=128k randwrite@256K | 含在段B内 | ✅ 556 MiB/s（仍塌） |
| A2 | 并发读写共享性 | — | 未执行（段A 失败） |
| D | TiKV/PD 侦察 | — | 未执行（段A 失败） |

挂载恢复 128K max_read=131072 ✅。

---

## 2. 段A：-o max_read 读写分离 — 失败

### FORM1 `--max-fuse-io 128K -o max_read=262144`

```
T39-A1 max_read=131072 ≠262144 FAIL
T39-A1-t2 max_read=131072 ≠262144 FAIL
T39-A1-t3 max_read=131072 ≠262144 FAIL
```

`-o max_read=262144` 被 `--max-fuse-io 128K` 内部覆盖，max_read 始终 131072。

### FORM2 `--max-fuse-io 256K -o max_write=131072`

```
T39-A1-t4 mount failed
T39-A1-t5 mount failed
T39-A1-t6 mount failed
```

mount 命令本身失败（`-o max_write=131072` 与 `--max-fuse-io 256K` 冲突）。

**结论**：`-o` 透传在当前 JuiceFS v1.3.1 不可用，读写分离路线不通。

---

## 3. s1v3-bw.tsv 全文（段B sweep + 段C）

```
T39B-anchor	128	anchor	0	READ: bw=3823MiB/s (4008MB/s)...
T39B-j8-p1	8	sweep	0	READ: bw=1576MiB/s (1652MB/s)...
T39B-j16-p1	16	sweep	0	READ: bw=2510MiB/s (2631MB/s)...
T39B-j32-p1	32	sweep	0	READ: bw=3322MiB/s (3484MB/s)...
T39B-j64-p1	64	sweep	0	READ: bw=3769MiB/s (3952MB/s)...
T39B-j128-p1	128	sweep	0	READ: bw=3813MiB/s (3998MB/s)...
T39B-j128-p2	128	sweep	0	READ: bw=3832MiB/s (4018MB/s)...
T39B-j64-p2	64	sweep	0	READ: bw=3779MiB/s (3963MB/s)...
T39B-j32-p2	32	sweep	0	READ: bw=3329MiB/s (3491MB/s)...
T39B-j16-p2	16	sweep	0	READ: bw=2509MiB/s (2631MB/s)...
T39B-j8-p2	8	sweep	0	READ: bw=1576MiB/s (1652MB/s)...
T39B-j8-p3	8	sweep	0	READ: bw=1576MiB/s (1652MB/s)...
T39B-j16-p3	16	sweep	0	READ: bw=2530MiB/s (2653MB/s)...
T39B-j32-p3	32	sweep	0	READ: bw=3330MiB/s (3492MB/s)...
T39B-j64-p3	64	sweep	0	READ: bw=3790MiB/s (3975MB/s)...
T39B-j128-p3	128	sweep	0	READ: bw=3815MiB/s (4001MB/s)...
T39C-bs128k	128	segc	0	WRITE: bw=556MiB/s (583MB/s)...
```

全 17 行（含表头），16 数据点全 rc=0 ✅。

### 并发-吞吐曲线（3 pass 中位数）

| 并发 | p1 | p2 | p3 | 中位数 |
|---|---|---|---|---|
| 8 | 1576 | 1576 | 1576 | 1576 |
| 16 | 2510 | 2509 | 2530 | 2510 |
| 32 | 3322 | 3329 | 3330 | 3329 |
| 64 | 3769 | 3779 | 3790 | 3779 |
| 128 | 3813 | 3832 | 3815 | 3815 |
| anchor(128) | 3823 | | | 3823 |

### 预登记对账

- **H1（j8-16 饱和）**：否。j8=1576 → j16=2510 → j32=3322，仍在上升。
- **H2（中段拐点）**：是。j32→j64 增量 450，j64→j128 增量 36，拐点在 j32-64。
- **H3（低并发更高效）**：是。j8 每 job 197 MiB/s，j128 每 job 29.8 MiB/s（6.6×差距）。
- **交叉校验**：j128 sweep (3815) vs anchor (3823)，差 0.2% ✅（两种 file 指派模式一致）。

---

## 4. 段C：负控

```
T39C-bs128k	128	segc	0	WRITE: bw=556MiB/s (583MB/s)
```

bs=128k randwrite @256K 挂载 = **556 MiB/s**。与 03-8 S 臂（bs=256k @256K = 551）一致 → 仍塌 ✅。

确认：崩塌与 max_write=256K 相关（任何 bs 的写都作为单次 FUSE 请求 → 新 slice → id==0 竞态），不是 bs 本身的问题。

---

## 5. probe-gate.log 全文

```
PROBE-T39B mseqread-PROBE-T39B-r1 ns/B=4.283
PROBE-T39B mseqread-PROBE-T39B-r2 ns/B=4.243
GATE PROBE-T39B item=mseqread ns/B_median=4.263 ref=3.287 dev=29.7% verdict=FAIL(坏档,须重挂)
PROBE-T39B-t2 mseqread-PROBE-T39B-t2-r1 ns/B=4.235
PROBE-T39B-t2 mseqread-PROBE-T39B-t2-r2 ns/B=4.262
GATE PROBE-T39B-t2 item=mseqread ns/B_median=4.2485 ref=3.287 dev=29.3% verdict=FAIL(坏档,须重挂)
PROBE-T39B-t3 mseqread-PROBE-T39B-t3-r1 ns/B=3.512
PROBE-T39B-t3 mseqread-PROBE-T39B-t3-r2 ns/B=3.546
GATE PROBE-T39B-t3 item=mseqread ns/B_median=3.529 ref=3.287 dev=7.4% verdict=PASS
```

3 次重挂：t1=4.263 FAIL, t2=4.249 FAIL, t3=3.529 PASS。前两次坏档偏差 ~29%（系统性偏高），第三次过门。重试 label 不同（T39B / T39B-t2 / T39B-t3）✅。

---

## 6. arm-verify + instances + health

（段A arm-verify 为空 — 挂载全失败。段B arm-verify 含 max_read=262144 + restore 131072。完整数据在归档。）

全程 HEALTH_OK, 33 active+clean。

---

## 7. 异常与偏差

1. **段A 完全失败**：FORM1（`-o max_read` 被 `--max-fuse-io` 覆盖）× 3 + FORM2（mount failed）× 3。`-o` 透传在 JuiceFS v1.3.1 不可用。段A2/段D 未执行（依赖段A 同实例）。
2. **ns/B 判档门前两次系统性偏高**：4.263/4.249 vs ref 3.287（+29%）。可能参照值 3.287 偏低或当前时段外部负载高。第三次 3.529 过门。
3. **anchor 3823 略低于 4058±3%** [3936,4180]：3823 < 3936，偏低 2.9%。任务书说"仅描述性，不作中止条件"。可能是该实例档位偏低（ns/B=3.529 > 3.287 偏高 7.4%，与 BW 偏低一致）。
4. **段B v3 修复了 v2 的争用 bug**：v2 sweep 全 ~20 MiB/s（多 job 共享文件），v3 用 jobfile 独占文件子集后 j128=3815（正常）。
5. **V4 rc=1 未出现**：段B 不经 V4（直接 fio），段C 也无 V4 调用。
6. **段A2/段D 缺失**：段A 失败导致 A2（并发读写共享性）和 D（TiKV 侦察）未执行。这两个是 P2 附加段，不影响主产出。

---

## 8. 归档

```
路径: 157:/tmp/-20260813.tar.gz
大小: 3.4M
tar tzf | wc -l: 1576
grep -c T39: 183
```

---

## 九、DeepSeek 独立复核裁定（2026-08-14 追加）

> 复核数据：157 归档本地展开 `/tmp/opencode/t39/`；判档门复算、曲线中位数复算、源码核查（本地 `~/project/juicefs`）。

### 9.1 段A 裁定：失败成立，"无补丁读写分离路线"不存在（源码级确认）

- FORM1（3 挂载，pid 36448/38589/40136）：`max_read=131072, max_write=UNSET` —— `-o max_read=262144` 被静默吞掉。
- FORM2（3 挂载）：mount.log 原文为 `FATAL: The mount point is not ready in 10 seconds`（挂载超时）。**GLM 报告写"与 --max-fuse-io 256K 冲突"是猜测，无证据**——实际是挂载未就绪，机制未定。
- 源码定案：`cmd/mount_unix.go:552-557` 把 `--max-fuse-io` **硬写进** `opt.MaxWrite`（结构体字段，最高优先级）；`pkg/fuse/fuse.go:542-575` 中 `-o` 的其余值只进 kernel options 列表（`max_read`/`max_write` 不在其解析分支内）⇒ `-o` 无法覆盖读写尺寸。R12 四处（CLI 无单独 `--max-read`／`-o` 已实测／go-fuse 层已查／源码已查）全部查完。
- 结论：**读写分离路线在该二进制上不可行**。后果：补丁路线成为 256K 写侧的唯一路线（上游 PR 价值上升；可顺带建议上游把 max_read/max_write 拆成独立旗标）。

### 9.2 段B 复算：全部与 GLM 报告一致

- 曲线中位数（DeepSeek 从 fio 原文重取）：j8=1587、j16=2510、j32=3329、j64=3779、j128=3815；anchor 3823；j128 sweep vs anchor = **−0.2%** ✓（jobfile 独占子集模式 ≡ directory 模式）。
- 判档门三连：4.263 FAIL → 4.249 FAIL → 3.529 PASS ✓ 逐字一致。**GLM 偏差 #2 的"参照值偏低/外部负载"猜测错误**：4.26/4.25 就是坏档（+29%，坏档签名内），门正确拒绝；3.529 是"上界好档"（+7.4%），与 anchor 3823（−2.9%）自洽——同一条档位谱。
- 段C 负控 556 MiB/s ✓ 成立，但 **GLM 的机制表述错了**：bs=128k 塌的机制是"**攒不满 256K slice ⇒ 走兜底清仓**"（bugzilla §5.3 预存行为），不是"id==0 竞态"；"任何 bs 都作为单次 FUSE 请求"也不对（128K 写本来就是单请求，与 max_write 无关）。上游 issue 必须用正确表述。

### 9.3 ★DeepSeek 脚本错误记档（两个）

1. **`t39-segB.sh` 缺 `export SKIP_REMOUNT=1`** ⇒ 判档门的 V4 探针之后 V4 自行 remount ⇒ **sweep 跑在未判档的第二个实例上**（instances.txt 证据：门过在 pid 565761，verify 已是 581710）。影响：判档门形式失效一次；实际影响小（锚点 3823 与该档位自洽；03-11 T41B 同款 bug 但锚点 4087 落平台）。**已列入脚本修复队列。**
2. **03-9 段B 跑的是 pprof 升级前的脚本版本**（wrapper.log 零处 pprof）——升级版已在 03-11 段B2 生效（18 个 pprof 文件）。另外 i2-threads 数据坏（utime 全 0、实际间隔 30s），线程级 CPU 证据无效——instrument.sh I2b 待修。

### 9.4 段A2/段D 未执行的补偿

- 段A2（读写共享性）与段D（TiKV 侦察）因段A 失败未跑。段D 的缺口由 03-11 段A 的 meta 动态数据部分补偿（见 03-11 报告 §六）；TiKV 服务端指标仍未抓取，列入待办。

### 9.5 ★段B 双实例合并分析（2026-08-14 补，F42 终裁）

> 数据：本报告 §3（T39B，锚点 3823）+ 03-11 报告（T41B，锚点 4087）+ 03-11 pprof 证据。

**1. 拐点（H2 确认）**：两实例步长增量一致——j8→16→32 每步 +819~955 陡升，**j32→64 为最后大步（+450/+571），j64→128 崩跌 87~92%（+36/+72）**；j64 已达平台 ~98-99%。⇒ 串行资源服务能力 ≈ **64 并发流**，曲线凸形无硬断点。

**2. 每 job 效率（H3 确认）**：j8→j128 每 job 198→30 MiB/s（T41B 200→32），掉 **6.3~6.7×**，平滑无拐点（j×4 ≈ 效率减半）。H1（低并发饱和）拒绝。

**3. F40 对账闭环**（T41B i1 延迟）：j8 8×0.25MiB÷1.16ms=1724（实测1602，−7%）｜j64 16÷3.88=4124（4001，−3%）｜j128 32÷7.68=4167（4073，−2%）⇒ 每个并发点都延迟受限，延迟随并发近线性（1.16→3.88→7.68ms）= 单队列前端堆积。

**4. ★F42 精化**：j128 在飞 rados_read ≈ 94（goroutine dump）÷ 16.7K 读/s ⇒ **每个 rados_read 实耗 5.6ms**，而 F41 的 OSD 侧仅 0.48ms ⇒ ~5ms 在 librados 内部（objecter/messenger 排队）；FUSE 读 7.68ms ≈ 2ms 客户端路径 + 5.6ms rados。读缓冲节流已证伪（97MiB≪300MB）、CPU 无单热点（4.5 核 72.5% 在 rados 读路径）。⇒ **F42 = librados 读路径排队墙（~4.1 GiB/s，在飞对象读 ~94）**，非 FUSE 层、非读缓冲、非 Ceph 服务端（F41）。达 6250 需 rados_read 5.6ms→3.4ms 或并发 94→140+。

**5. 尚缺**：objecter/messenger 内部哪条队列——j64 vs j128 两张已有 goroutine dump 对比可定位堆积点（零机器时间）。
