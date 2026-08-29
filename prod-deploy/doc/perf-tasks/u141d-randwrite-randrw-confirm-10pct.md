# U141d 任务书：randwrite + randrw 单夜确认（M_eng = 10%）

## 日期：2026-08-29

> 面向：GLM 执行；opencode 离线独立复算与签收。
> **本任务取代 U141c 的 3–5 夜方案**（`u141c-methodology-revision-replace-decision.md` 转入暂缓）。
> 承接：`doc/perf-report/u141b-replace-decision-status-20260829.md`、`doc/perf-tasks/u141b-findings-log.md`（F-01…F-17）。
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、`skills/TESTING-GUIDE.md` §1.3/§2.2/§3、
> `skills/test-commands-reference.md` §8.3/§9、`skills/SYSTEM-SAFETY-SKILL.md`、`skills/LONG-RUNNING-TEST-SKILL.md`。
> 未在本文件复述的执行细节，一律按 U141b 任务书同名章节执行（脚本、硬门、红线均不变）。

```text
U141b  32 轮跑完、硬门全过、退步 0/7，但判据要求 3% 而每轮噪声 1.0–3.4% ⇒ REPLACE_NOT_PROVEN
  ↓    诊断：卡点不是稳定性门，是从未被论证的 3% 阈值
U141d  把阈值按业务定为 10%，只测两个风险项，8 轮 1 夜  ← 你在这里
  ├─ 两项 CI 下界 ≥ −10% → REPLACE_APPROVED（连同 U141b 的读侧描述性证据一起收口）
  ├─ 任一项 effect < −10% 且 CI 上界 < −10% → REPLACE_REJECTED
  └─ 任一非性能硬门失败 → EVIDENCE_INVALID，保留现场，⛔ 禁止补样
```

一句话：只回答"升级会不会带来**明显**退步"，阈值 10%，测 `randwrite` 与 `randrw` 两个历史风险项，8 轮，一夜出结论。

---

## 一、⚑ 预注册（⛔ 取数前冻结，取数后一律不得改）

| 项 | 值 | 依据 |
|---|---|---|
| **`M_eng`** | **10%**（两项相同） | 业务口径：只需排除"明显退步"。⚑ **本值在取数前冻结**，⛔ 不得事后调整 |
| **点估计量** | 正式窗 `[15,175)` 逐秒全 job 求和序列的 **算术平均 mean** | mean × 窗长 = 实际传输字节数，是有效带宽的定义。U141b F-13：randwrite 秒级双峰（CV 36–45%），median 落稀疏谷、ε 达 17.28%，mean 仅 2.09% |
| **判定统计量** | `BW_r = β0 + β1·r + β2·r² + βarm·1[V14]`（OLS），判 `βarm` 单侧 95% CI | 设计使 `arm ⊥ {1,r,r²}`（§二），去趋势不吸收 arm 效应；不确定度用全部残差自由度，不再由 2 个相邻对决定 |
| **趋势阶数** | 二次，⛔ 禁数据驱动选阶 | 选阶即引入 D36 同类漏洞 |
| **测试项** | `randrw`、`randwrite` | 两者是历史崩塌与退步风险项（原版 v1.4.1 randwrite 崩到 551；randrw 是 U141b 唯一负向项） |
| **轮数** | 8（每臂 4） | 功效：`s` 实测 randrw 2.43% / randwrite 1.02% ⇒ n=8 的 CI 半宽 3.67% / 1.54%，**远小于 10%**，余量 ≥2.7× |

判定表：

| 条件 | 判定 |
|---|---|
| `halfw < 10%` 且 `CI_low ≥ −10%` | **NON_INFERIOR** |
| `halfw < 10%` 且 `effect < −10%` 且 `effect + halfw < −10%` | **MATERIAL_REGRESSION** |
| `halfw ≥ 10%` | `RESOLUTION_INSUFFICIENT`（按功效表 n=8 时不应发生；若发生须解释 `s` 为何翻倍） |
| 其余 | `INCONCLUSIVE` |

⚑ median 与 20% trimmed mean **必须同时算出落盘**作已登记敏感性，⛔ 不得用于改写判定。
⚑ 任何偏差数字必须写明**基准估计量**（F-17 教训）。
⚑ **报告须显式声明**：`M_eng=10%` 是在本任务取数前冻结的；U141b 的数据 ⛔ 不得拼进本任务效应量。

---

## 二、矩阵（沿用 U141b 的 8 轮设计，已验证二阶平衡）

```text
R01=V13  R02=V14  R03=V14  R04=V13   |   R05=V14  R06=V13  R07=V13  R08=V14
        ── ABBA block 1 ──                    ── BAAB block 2 ──
```

V13 占位 `{1,4,6,7}`、V14 `{2,3,5,8}`。平衡性自证（必须在报告复算）：
`mean(r)` 两臂均 **4.5**（一阶精确）；`mean((r−4.5)²)` 两臂均 **5.25**（二阶精确）。

**单一 phase，两个 item 同轮执行**：`ITEMS="randrw randwrite"`（两臂的分组与项内顺序完全相同）。

⚑ **预热轮**（丢弃但留证，针对 F-14 的跨轮 settle）：矩阵前跑 4 轮，臂序 `V13 V14 V14 V13`（对称）。
LABEL 用 `U141D-P1-W<nn>-<ARM>`。收敛判据：最后 3 个预热轮 randwrite 的
`|BW_i/BW_{i-1} − 1|` 连续 2 次 **< 2.0%**；不达标最多再成对追加 2 轮（`V14 V13`），仍不达标 ⇒ STOP 回传。
依据：U141b randwrite 前三轮 `2844→2685→2629`（−5.6%/−2.1%），第 4 轮起进入 ±2% 带内。

**排空点**（`juicefs gc --compact --delete`，前后对象数与原文输出必须落盘）：
矩阵 `R01` 前、`R05` 前（block 边界，两臂对称）各一次。
依据：U141b P2 实测 randrw 每轮增 66K–222K 对象；起点 1.98M、门 3.11M ⇒ 4 轮最坏 2.87M，安全。
randwrite 为纯覆写（U141b P3 实测 `post−pre ≤ 1`），不贡献棘轮。

---

## 三、墙钟预算（按 U141b 实测标定，⛔ 不再用估值）

| 段 | 轮数 | 每轮实测依据 | 小计 |
|---|---:|---|---:|
| 前置 + P0 兼容性门 | — | — | ~0.5 h |
| 预热 | 4 | 25.5 min（U141b P2 两 item 实测 24.2–28.9） | ~1.7 h |
| 矩阵 | 8 | 25.5 min | ~3.4 h |
| 排空 ×2 | — | 55 s（U141b 实测） | ~2 min |
| **合计** | | | **≈ 5.7 h（单夜）** |

⚑ **S01 时长门（按 F-06/F-07 修订）**：`check_timing` 必须**秒级比较**，⛔ 禁整数除法
（U141b 因 `1258/60=20` 掩盖了 20.97 min 的真实越界）。`PHASE_EXPECT_MAX` 置 **32 min**
（= 25.5 × 1.25）。**任一轮 > 1.6 × 25.5 = 41 min ⇒ 立即中止整个 phase**，记 `EVIDENCE_INVALID`，回传等重排。
⛔ 不得"继续但压缩后续轮"、⛔ 不得"停下等指示再续跑"——两者都产生非均匀轮间隔。

---

## 四、保留的硬门（只留这些；其余项改为"记录不设门"）

### 4.1 非性能证据门（失败 → `EVIDENCE_INVALID`，STOP，⛔ 禁止补样）

| Gate | 检查 | 条件 |
|---|---|---|
| **S09b** | 切臂自证 | 启动 V4 **之前** `command -v juicefs` 必须解析到本臂 shim，且其 md5 = 本臂值 |
| **S10** | `exe_md5` | 该轮**所有** `juicefs.*mount` 进程 `/proc/<pid>/exe` md5 = 本臂 md5 |
| **S11** | `CEPH_CONF` | 每个 mount 进程 environ 含 `CEPH_CONF=/tmp/t141-msgr8.conf` |
| **S12** | `max_read` | `mount` 输出含 `max_read=262144`（⚑ 见 §五 前置条件，F-08 曾因此废掉一轮） |
| **S13** | fio 有效性 | `rounds.tsv` 该轮 status = `VALID`；无 `INVALID.txt` |
| **S14** | per-job BW 日志 | randrw 128 个、randwrite 128 个 `*_bw.*.log`，零缺失 |
| **S14b** | 正式窗样本数 | 每 item 每轮 `n = 160`（W1–W4 各 40） |
| **S15** | 对象数门 | 轮前 pre ≤ **3,110,000**；超过 → 立即 `drain`，排空后仍超 → STOP。⛔ 无 SOFT-PASS |
| **S17** | Ceph | 全程 `HEALTH_OK`、`nonclean=0` |
| **S18** | 冻结项 | 系统 ceph.conf `5b6be341…`、msgr conf `86351c58…`、V4 脚本 `4198ea26…` 三个 md5 不变 |
| **S19** | 卸载 | 优雅卸载成功且 `mount \| grep -c juice` 为 0 |
| **S21** | 轮间隔 | 除两个计划 `drain` 外相邻轮 `END = BEGIN` 为 0 |
| **S22** | 预热收敛 | 按 §二达标 |

### 4.2 改为「记录不设门」（相对 U141b 的简化）

文件资产 384 项逐轮清单、PG primary map、`c_amp`、cache hit、`W4/W1`、`ns/B` 判档器读数、
`jfs-stats` 差分 —— **照常采集落盘**，但 ⛔ 不作为放行条件。
理由：U141b 32 轮实测这些项**全部恒定/无异常**，继续设门只增加中止风险而不增加信息
（指导 §二.12：一道总是通过或总是失败的门不携带信息）。
⚑ 但 `S16` 的**弱化版**保留：R01 前与末轮后各采一次 384 文件清单，比对数量与大小；
中间轮不比对。资产是绝对不可损坏项。

### 4.3 性能端点（⛔ 永不触发样本删除）

⚑ **S20**：带宽绝对值、秒级 CV、`W4/W1`、CI 半宽 **再差都是结果，不是删样本的理由**。

---

## 五、前置条件与执行（其余照 U141b）

```bash
export PATH="${SHIM}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CEPH_CONF=/tmp/t141-msgr8.conf
export JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"   # ⚑ F-08：V4 默认不含 256K，缺它撞 S12

ITEMS="randrw randwrite" OBJ_GATE=1 \
  bash /tmp/FULLBASELINE_V4.sh "U141D-P1-R${nn}-${ARM}" 180 1 --remount \
  > ${RUN_ROOT}/v4-U141D-P1-R${nn}-${ARM}.stdout.log 2>&1
echo "rc=$?" >> ${RUN_ROOT}/v4-U141D-P1-R${nn}-${ARM}.stdout.log
```

- `SHIM` = `/tmp/t53-bin-new`（V13，md5 `de93563f11a5ff3bd94dd25a4e0283b1`）
  或 `/tmp/t141p-bin`（V14，md5 `24fae0852051c80ca571cb2f20275d46`）。
  切臂**只允许**改 `PATH`；⛔ 禁 `cp`/`ln -sf` 覆盖 `/usr/local/bin/juicefs`（那是错版本 `bdd182cf…`）。
- `OBJ_GATE=1` 强制（否则 V4 `:1352` 触发 `set -e`，rc=1）。
- `--remount` 必须（这就是切臂的实现方式）。`RUNTIME`/`REPEAT` 只认位置参数 `$2`/`$3`。
- 轮后顺序不可颠倒：① 挂载指纹（**卸载之前**）② 对象数 post ③ 拷回产物 ④ 优雅卸载。
- ⚑ 每次重试必须**换 LABEL**（`rounds.tsv` 按 label 累计，同 label 重试会稀释坏读数）。

**阶段 I 前置**（照 U141b，只做这些）：环境快照 `pre`；mount/fio/t6x/端口残留全 0
（判 fio 必须用 `pgrep -c -f '(^|/)fio( |$)'`，⛔ 禁 `pgrep -c fio` —— 会命中内核线程 `vfio-irqfd-clea`）；
`HEALTH_OK` + 6/6 OSD + `nonclean=0`；冻结指纹 manifest；对象数三次采样 spread=0；
**根分区可用 ≥ 20 G**（⚑ F-11：U141b 因预存 94.3% 占用、可用 4.7 G 导致 R05 直接 abort，
开跑前必须清 `/tmp` 旧测试数据）；写类静置检查 meta 提交率 ≥ 8000/s。

**P0 兼容性门**：V14 挂 → 卸 → V13 挂 → 卸 → V14 挂，三次全成功；落三份 `p0-status-*.json`
（⚑ 先 `sed -n '/^{/,$p'` 剥掉 juicefs 的 2 行日志前缀再落盘，否则不是合法 JSON —— D33）。
Setting 段做键集合 diff，期望：**V14 是 V13 超集，仅多 `Tiers`（空默认 tier 0），15 个共有字段逐字节相同**；
⛔ 不得表述为「identical」（F-02）。任一次挂载失败 ⇒ `ROLLBACK_BLOCKED` ⇒ 强制 `REPLACE_REJECTED`。

---

## 六、交付物与回传

`RUN_ROOT=/tmp/production/opencode-u141d-<RUN_ID>`，归档 `+ .sha256` 并 scp 回 `/home/lilingfeng/tmp/production/`。

必交：`MATRIX_AUTHORIZED.tsv`、**`PREREG.tsv`**（§一逐项写死）、`timing.tsv`（秒级）、
`incidents.tsv`（append-only，动作前后各一条）、`objects.tsv`、`rounds-u141d.tsv`、
`fingerprint/`（manifest + 每轮 mount-post + arm-resolve）、`assets/`（首末各一份）、
`v4/` 全部 12 个 LABEL 目录（4 预热 + 8 矩阵）完整内容含全部 `*_bw.*.log`、
P0 三份 json + `juicefs config` 只读回显、两次 drain 的前后对象数与 `gc` 原文、
`closure/`（冻结核对 + 二进制副本 + `SHA256SUMS` 全 PASS）、环境快照 `pre`/`post`。

**回传节奏（2 个检查点，相对 U141b 的 5–6 个大幅压缩）**：

| 批次 | 内容 | 停下等审核？ |
|---|---|---|
| 批 0 | 阶段 I + P0 + `PREREG.tsv` + 预热 4 轮（含收敛判据结果） | **是** |
| 批 1 | 矩阵 8 轮 + 归档 + `closure/` | **是**，出最终判定 |

⚑ **交付边界**：GLM 只交原始数据 + 逐门 PASS/FAIL 清单 + `incidents.tsv`。
⛔ 不写效应量、不写"非劣/等价/退步"、不算 CV/中位数/CI、不挑轮次。统计全部由 opencode 独立复算。
**phase 内部不要停**（含预热轮）：中途停下会引入时间偏置，破坏轮级交错的意义。

---

## 七、红线（就地复述，⛔ 无例外）

1. 硬门失败：**停止 phase、保留现场**（不卸载、不删目录、不清 sampler），`incidents.tsv` 前后各一条。
   ⛔ 禁换 RUN_ID 重来、禁同 RUN 热改脚本、禁补样替换、禁把 U141b 或无效轮的点值拼进本任务效应量、
   禁门失败后改挑有利判据、⛔ 禁事后调整 `M_eng`。
2. ⛔ 禁 `pkill`/`killall`/`fuser -k`/模式 kill；禁 `fusermount -uz`、`umount -l`、`losetup -D`、`rm -rf`；
   禁 kill mount PID。这四条在 03-19/03-20A/03-20B/首次 03-22c 都被违反过。
3. ⛔ 禁 reboot/shutdown/systemctl 改生产服务；禁写 `/dev/nvme*`、`/mnt/jfs-tikv`、`/opt`、`/etc`、`/var/lib/ceph`。
4. ⛔ 禁 `ceph osd pool delete/create`、禁改 CRUSH/PG/pool 参数、禁 `ceph config set`、
   禁 OSD restart 作轮间清理、禁 `juicefs destroy`（本任务复用生产卷）。
5. 允许的 sudo 写操作**全集**：三节点 `echo 3 | sudo tee /proc/sys/vm/drop_caches`（V4 内部）、
   `sudo ceph tell osd.N compact`（V4 `compact_cooldown` 内部）。其余只有只读 sudo。
6. 脚本实现层 bug 可修，但必须：停止 phase、`incidents.tsv` 说明 diff 与原因、重新生成指纹、
   **从第一个预热轮重跑**。⛔ 不得在已开始的 phase 中静默换脚本。
7. `pool_sample` 必须用 `ceph df --format=json` + python3 解析。⛔ 禁 `rados df` 列切分。
8. 每写项后 compact cooldown 必须轮询至 `compact_running=0` **且 `compact_queue_len=0`**；每 fio 前 drop_caches。
9. 长跑期间每 10–30 min 检查：mount PID、`v4-*.stdout.log` 尾部、Ceph health、objects、`MemAvailable`、无 foreign fio。

### 最终红线一句话

本任务可以丢掉的是本 RUN 的 COW 垃圾对象；**绝不能碰**的是
`read_test.*`/`rw_test.*`/`storage_test.*` 这 384 个文件资产、生产 PD/TiKV/Ceph 的任何配置或服务、
系统 `ceph.conf`、`/tmp/FULLBASELINE_V4.sh`，以及任何无法由指纹文件精确证明归属的 PID 或挂载。

---

## 八、收口与遗留

- 两项 `NON_INFERIOR` ⇒ 连同 U141b 的读侧证据（seqread/mseqread/randread 效应量 ≤ +0.33%，
  见现状报告 §4）与 P0 回滚证据一起出 **`REPLACE_APPROVED`** 报告。
- ⚑ **唯一遗留缺口 = `mseqwrite`**（U141b/U141d 均未测）。旁证：U141 旧 ABBA 的 4 cell/臂
  给出 A 均值 4574 / B 均值 4654（B 略高，无崩塌），但轮间散布约 ±10%，**只能作旁证不作判定**。
  报告须显式登记该缺口；若需闭合，单独 1 夜（`mseqwrite` 每轮排空，8 轮）。
- 收口后一次性落地 U141b 的脚本欠账：**D33**（json 日志前缀）、**D34**（整除掩盖越界）、
  **D35**（子脚本失败不回写 incident）、**D36**（估计量未锁定）+ F-01（PG 按池过滤）
  + F-07（`PHASE_EXPECT` 重标定）+ F-08（mount opts 前置检查）。
- U141c（3–5 夜、7 项 @3%）转入**暂缓**；仅当业务明确需要 3% 分辨力时才重启。
