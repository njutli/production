# 全量基线测试 Skill（FULLBASELINE）

> 目的：在 157 上产出**可对外汇报、可复核、可作为调优参照**的 JuiceFS/Ceph 全量基线。
> 状态：**已验证**。2026-08-06 W2 运行（GATE1 + W2P1/P2/P3）按本流程执行，randread/mseqread/randrw 三项 L2+L3 达标签收。
> 依据：`report/基线测试报告-JuiceFS-E6-20260806.md`、`doc/perf-report/02-2h-e6-v4-fullbaseline-20260803.md`（R1~R5）
> 前置必读：`SYSTEM-SAFETY-SKILL.md`（红线）、`LONG-RUNNING-TEST-SKILL.md`（长跑挂起/守护）
> 关系说明：本文取代 `baseline-reproduction-skill.md` 中的**执行流程**部分（那份是 V2/V3 时代的方法演进史，其集群配置与根因链仍然有效，作为背景阅读）。

---

## 〇、一句话流程

```
自检 → randread 探针门控（抽到高档才开跑）→ 固定实例连跑 3 次全量 → 实例同一性校验
→ 从 bw log 独立复核 → 出签收表
```

**唯一脚本**：`scripts/FULLBASELINE/FULLBASELINE_V4.sh`。不许 `cp` 出副本，不许另写脚本。

---

## 一、为什么必须门控（不可跳过）

性能"档位"属于 **JuiceFS 挂载实例**，不属于机器：

| 观测 | 值 |
|---|---|
| 同一实例内轮间差异 | ≤1.1% |
| 跨实例（每次 remount 重抽签）median 极差 | **29.9%**（1334-1891 MiB/s） |
| 高档命中率 | ≈49% |

⇒ 不门控就连跑 = 重测抽签分布，不是测配置。**跨运行比较（L3）在实例不固定时必然 FAIL，那是设计使然，不是 bug。**

---

## 二、阶段 0：开跑前自检（每次都做）

```bash
# 1) 脚本完整性（本地 WSL 算，不在 157 算）
md5sum scripts/FULLBASELINE/FULLBASELINE_V4.sh
#   ⚑ 当前应为 4551ef3c0d405734ea0a4a281427a989（1373 行，含 obj_gate()，2026-08-07 起）
#   ⚑ 历史值 3fd1281fea1c08342051d64fc8eb1348 = 无 obj_gate 的旧版
#   🔴 上传到 157 后必须在 157 上再算一次核对 —— 用错版本会静默跑出"每轮起点不同"的废数据
bash -n scripts/FULLBASELINE/FULLBASELINE_V4.sh          # 语法
python3 scripts/FULLBASELINE/debug/fnorder_check.py \
        scripts/FULLBASELINE/FULLBASELINE_V4.sh          # 函数定义顺序

# 2) 157 上 dry-run
bash FULLBASELINE_V4.sh dry-run

# 3) 集群就绪（157）
sudo ceph health                      # 必须 HEALTH_OK
sudo ceph osd ls | wc -l              # 必须 6
sudo ceph osd pool get juicefs-data pg_num pgp_num pg_autoscale_mode
                                      # 必须 32 / 32 / off
sudo ceph df | grep juicefs-data      # 记录 stored / objects / used
df -h /mnt/juicefs                    # 余量 <20G 会 abort

# 4) layout 文件在位（384 个，缺了就说明有人带过 --layout）
ls /mnt/juicefs/test_dir/read_test.*.0    | wc -l    # 128
ls /mnt/juicefs/test_dir/rw_test.*.0      | wc -l    # 128
ls /mnt/juicefs/test_dir/storage_test.*.0 | wc -l    # 128
```

> ⚠ **`dry-run` 全绿不等于能跑**。`dry-run` 在 `line 1108` 提前 return，之后的代码从未被验证。2026-08-06 就因此吃了一次亏：`line 1196` 引用未定义的 `CACHE_SIZE_GB`，`set -u` 下算术展开静默致命退出，dry-run 完全看不出来。
> ⇒ **自检必须包含一次真实的短跑（门控本身就是）**，不能只靠 dry-run。

---

## 三、阶段 1：门控（randread 探针）

```bash
ITEMS="randread" bash FULLBASELINE_V4.sh GATE1 75 1 2>&1 | tee /tmp/gate1.log
```

| 项 | 规则 |
|---|---|
| 取值 | randread **逐秒均值**（不是 fio 汇总，不是中位数） |
| 高档区间 | **[1830, 1930] MiB/s** |
| 命中 | 停手，进入阶段 2 |
| 未命中 | 换实例重抽（GATE2、GATE3…），**最多 5 次** |
| 5 次全不中 | **停下汇报，不许放宽区间**（放宽 = 基线不可比） |
| ⚑ 命中率参考 | 约 **61%**（平均挂 **1.6** 次中一个），来自 03-1 |

> ### ⚑ 门控探针的能力边界（2026-08-07，03-1 否证后必读）
>
> | 用途 | 是否有效 |
> |---|---|
> | 确认 randread **自身**落在高档 | ✅ |
> | 确认**实例同一性** —— 硬判据 **pid + starttime_ticks** | ✅ |
> | 用探针值推断"其它项也是高档" | 🔴 **无效**。03-1 留一法：r = **−0.1291**、传导增益 **0.221**、SNR 差 **22 倍** |
> | 用探针值**归一化**其它项 | 🔴 **无效，已作废**（读项也不例外） |
> | 长跑中当"越界即中止"的**看门狗** | 🔴 **必然误报**。日间 4.5h 内 randread 就能跌 **1.72%**，最低点 1830.7 距下界 1830 只剩 0.04% 余量 ⇒ 长跑应把它当**外部负载协变量**记录，中止线放到远离常态波动处 |
>
> ⇒ 门控的价值是**固定一个实例**并知道它的读侧档位，**不是**给整份基线打包票。

为什么 75s 能用：`parse_bwlog_mean` 的窗口是 `15 <= sec - t0 <= 175`，**相对起点**，所以 75s 跑一样出值 —— 门控不需要改脚本。

命中后立即抄下实例身份：

```bash
cat /tmp/opencode-fullbaseline-v4/jfs-instance-GATE1.txt
# 记下 pid= 与 starttime_ticks=，后面三次运行必须完全一致
```

---

## 四、阶段 2：同实例连跑 3 次全量

```bash
cd <脚本目录>
nohup bash -c '
  SKIP_REMOUNT=1                bash FULLBASELINE_V4.sh W2P1 180 5 &&
  SKIP_REMOUNT=1 REF_LABEL=W2P1 bash FULLBASELINE_V4.sh W2P2 180 5 &&
  SKIP_REMOUNT=1 REF_LABEL=W2P2 bash FULLBASELINE_V4.sh W2P3 180 5
' > /tmp/w2base.log 2>&1 &
sleep 15; tail -20 /tmp/w2base.log; pgrep -f FULLBASELINE_V4.sh | head -3
```

要点：

- **一个 `nohup` 用 `&&` 串起来**：中间不落地，避免人为间隔引入时间漂移，也保证前一次失败就不再往下跑。
- `SKIP_REMOUNT=1` 保住档位；`REF_LABEL` 链式指向前一次，脚本才会算 L3。
- **不带 `ITEMS`**（7 项全跑）；**绝对不带 `--layout` / `--remount` / `--allow-restart`**。
- 为什么 3 次：L3 至少需要 2 次；3 次才能识别"哪一次是离群运行"（W2 实测 W2P1 是首运行离群、W2P2 的 mseqwrite 是单项离群 —— 只跑 2 次会把离群当基线）。

**时间预算**（实测，来自 S4 目录时间戳与 W2 时间线）：

| 单元 | 耗时 |
|---|---|
| randread 1 轮 | 3.3 min |
| randrw 1 轮（含 cleanup） | 8 min |
| randwrite 1 轮（含 cleanup） | 11.3 min |
| 全量 1 次（7 项 × 5 轮） | **≈3h40m** |
| 门控 + 3 次全量 | **≈11.5h**（过夜） |
| `reset_state` 的 `gc --compact` | 首次 ≈46s；每经历一次全量写后 ≈10 min |

---

## 五、阶段 3：实例同一性校验（**最关键的一步**）

```bash
grep -c "沿用现有挂载实例" /tmp/w2base.log        # 必须 = 3
grep -c "forced-mount"     /tmp/w2base.log        # 必须 = 0
cat /tmp/opencode-fullbaseline-v4/jfs-instance-*.txt
# 四行的 pid= 与 starttime_ticks= 必须完全一致
```

`SKIP_REMOUNT=1` 但检测到未挂载时，脚本会**静默 forced-mount**（= 换实例 = 重抽档位）。一旦看到 `forced-mount`：

> **立即停机上报，本次所有 L3 作废。** 停机只能按精确 pid `kill`，**禁止 `pkill -f fio` / `pkill -f juicefs` / `killall`**（157 是 3075 人共享机，跑着 WekaIO / K8s）。

---

## 六、判定规则

### 6.1 口径（只有一个验收口径）：逐秒均值(15-175s)

`FULLBASELINE_V4.sh:1017 parse_bwlog_mean()`。fio bw log 每行格式：

```
<毫秒时间戳>,<带宽 KiB/s>,<方向位>,<块大小>,...
方向位：0=read  1=write  2=trim
```

算法：

```
1) 读取该轮子目录下所有 *_bw.*.log（128 个 job 各一个文件）
2) 秒对齐：sec = int(field[0]) / 1000
3) 方向过滤：仅保留 field[2] == direction 的行
4) 同秒跨 job 求和：per_sec[sec] += field[1]      ← 128 个 job 的带宽相加
5) 取窗口：t0 = min(per_sec.keys())，保留 15 <= sec - t0 <= 175
6) 逐秒均值 = mean(窗口内 per_sec 值) / 1024      ← 单位 MiB/s
```

三个易错点：

- **窗口相对 t0**（`trim_sec <= k - t0 <= 175`），不是绝对秒 —— 所以 75s 的门控探针也能正确出值。
- 截前 15s 去掉写缓冲/ramp 虚高；用**均值**而非中位数，因为中位数会把 stall 剔掉、掩盖真实抖动。
- 方向位（`FULLBASELINE_V4.sh:976`）：

| 项 | direction |
|---|---|
| seqread / mseqread / randread | 0（读） |
| **randrw** | **0（只取读侧）** |
| seqwrite / mseqwrite / randwrite | 1（写） |

fio 汇总值（`bw_from_fio()` 解析 `fio.txt` 的 `READ:`/`WRITE:` 行）与逐秒中位数（`parse_bwlog()`）**仅作参考，不作验收**。

L2 / L3 公式：

```
median   = median(该项各轮逐秒均值)
L2 极差幅度 = (max - min) / median × 100%          ← 判定用这条
max_dev  = max(|v - median|) / median × 100%       ← 打印参考
CV       = stdev / mean × 100%                     ← 打印参考
L3 偏差  = (median(本运行) / median(REF_LABEL) - 1) × 100%
```

> 脚本只算"与前一次运行"的链式 L3。**复核时要补算全 pairwise**（P1↔P3 也算），否则会漏掉累积漂移。

### 6.1b 辅助指标公式

| 指标 | 公式 / 来源 | 用途 |
|---|---|---|
| hit% | `collect_hitrate` 每轮 fio 前后采集，差分 | 读项是否命中 BlueStore 缓存；ρ(hit%, randread)=1.000 |
| C_amp | NIC 计数器首末差分 ÷ fio 读字节 | 守卫：default 应 2.0±0.1，`--max-readahead 0` 应 1.0±0.1，超范围判该轮无效 |
| gear / stall | 逐秒序列 stall 占比 + CV | L1 单轮清洁度 |
| **compact 成本** | `秒 ≈ 1.95e-4 × 回收对象数`（误差 6%） | 预算 `gc --compact` 时间；单轮回收约 148s |
| **空间放大** | `used 增量 / fio 写入量` | 实测 1.84-1.88×，其中 46-56% 是可回收垃圾 |
| **对象产生率** | 每写入 **292 KiB** 产生 **1 个新对象**（R5 直接实测：211 GiB ⇒ +757k） | 估算"写入量 → 新增对象数"**只能用这个**。⚠ **不要拿"池内平均对象大小 256 KiB"（`STORED÷objects`）代替** —— 会高估新增量 ≈14%（约 12% 的写是覆写，不产生新对象）。2026-08-07 实际踩过 |

### 6.2 三层判据

| 层 | 阈值 | 备注 |
|---|---|---|
| L1 单轮清洁度 | 读项 stall ≤1% 且逐秒 CV <6% | 写项天生双模（stall 1.2-22.3%），只记录不判定 |
| L2 轮间极差幅度 | **≤5%** | `(max-min)/median` |
| L3 跨运行 median 偏差 | **≤5%** | 只在同一实例间有意义 |

**不要把 L2 放宽到 10%**：S3+S4 的 9.6% 会擦线通过而其中藏着 +8.0% 的整档跃迁；阈值放到 10%，后续调优的分辨力下限就是 10%，5-15% 的真实收益全部测不出来。

### 6.3 ⚑ randrw / randwrite 的 r1 规则

这两项**每轮后都做 `gc --compact`**，所以 r1 是"池刚复位"的特殊状态：

- `randrw` 的 r1 是**唯一受控状态**，历史签收 2400 取的就是 r1；
- `randwrite` 的 r1 **系统性偏高**，混进 5 轮统计会把极差撑到 5-8%。

> **规则：r1 单独记录、不进 L2 统计（两项口径必须一致）。** W2 实测 randwrite 剔 r1 后 L2 = 2.6% / 3.8% / 4.0% 全部达标。

### 6.4 ⚑ randrw 双口径（最容易出 2 倍错）

| 口径 | 算法 | 产出者 |
|---|---|---|
| **读侧** | 只累加 `direction==0` | `FULLBASELINE_V4.sh`（`line 979`） |
| **读写合计** | 不过滤方向 | `debug/mount-gear-attrib-test.sh` 的 `bw_mean`（默认 `all`）、`r5chk.py` |

实测读写几乎精确对半（R5 A-rw1：read 1205 + write 1204 = 2408）。**对外报数必须写明口径**，否则同一性能会被看成掉 50%。

### 6.5 判"是否漂移"必须看轮序

只看 range 会误判。W2P2 randwrite `r1=2976 … r5=2976`（净漂移 0）却因 r1 偏高而 range 越界。**必须按 `label-r<N>` 取值保留轮序，不要排序后看极差。**

领先指标：**轮内 q1→q4 趋势跌破 −5%** 即报警（均值仍健康时趋势会先转负）。

---

## 七、复核（不采信任何自算值）

**任何签收值必须由第二方从 `*_bw.*.log` 重算**，偏差应 ≤0.5%。

产物位置：`/tmp/opencode-fullbaseline-v4/<LABEL>/<item>-<LABEL>-r<N>/`，每个轮次子目录内含：

| 文件 | 内容 |
|---|---|
| `*_bw.*.log` | **逐秒带宽原始日志，128 个（验收计算的唯一数据源）** |
| `fio.txt` | fio 完整输出（含 `READ:`/`WRITE:` 汇总行） |
| `nic.txt` | 每秒 NIC 计数器（C_amp 用） |
| `hit-rate.txt` | fio 前后命中率 |
| `pg-map.txt` / `up_from.txt` / `config-md5.txt` | 每轮集群配置快照 |
| `jfs-stats-pre.txt` / `jfs-stats-post.txt` | JuiceFS VmRSS/Threads + `.stats` |
| `gear.txt` | L1 单轮清洁度（stall% + CV） |
| `weka-load.txt` | 轮前 load average（外部干扰记录） |
| `mount-cmd.txt` | 挂载命令行 |

运行级产物：`jfs-instance-<LABEL>.txt`、`cache-config-check-<LABEL>.txt`、`rounds.tsv`、`test.log`。

```python
import glob, statistics as st
def bw_mean(subdir, direction=0, lo=15, hi=175):   # direction=None ⇒ 读写合计
    per = {}
    for f in glob.glob(subdir + "/*_bw.*.log"):
        for line in open(f):
            p = line.split(',')
            if len(p) < 3: continue
            if direction is not None and int(p[2]) != direction: continue
            t = int(p[0]) // 1000
            per[t] = per.get(t, 0.0) + float(p[1]) / 1024.0
    t0 = min(per)
    return st.mean([per[k] for k in sorted(per) if lo <= k - t0 <= hi])
```

复核清单：

1. 窗口是否 `15 <= sec - t0 <= 175`（**相对 t0**）。
2. randrw 口径是否标明。
3. **是否有跨轮串台的 bw log**：`ls <subdir>/*_bw.*.log | grep -v <本轮 label>` 必须为空。R2 曾因残留 128 个别轮日志被通配捞走，把 1886 算成 2162（+14.6%），组间极差从 32.2% 夸大到 47.5%。
4. 轮序是否保留。
5. fio 汇总值与逐秒均值应在 1-2% 内一致；差得多说明窗口或方向位错了。

---

## 八、回报清单（执行方必须交这些）

| # | 内容 |
|---|---|
| 1 | 脚本 md5（若有修改：diff + 新 md5 + `bash -n` 结果 + **为什么改**） |
| 2 | 门控值与尝试次数 |
| 3 | 三次运行的**稳态评估段原文**（不要转述、不要自算） |
| 4 | 三次运行的**逐轮逐秒均值**（不只是 median 和 range —— 少了逐轮值就无法做 r1 规则复算） |
| 5 | `jfs-instance-*.txt` 四份全文 |
| 6 | `grep -c "沿用现有挂载实例"` 与 `grep -c forced-mount` 的结果 |
| 7 | `rounds.tsv` 的本次全部行 |
| 8 | GUARD 行、`pg_gate` 统计 |
| 9 | 起跑前/跑完后 `ceph df` 与 `ceph health` |
| 10 | 时间线（各阶段起止） |
| 11 | 异常与偏离指令之处（**没有也要显式说"无"**） |

> 执行方**不要自己下结论、不要自己判 PASS/FAIL**，只交数据与脚本原文输出。判定与复核由另一方独立做。

---

## 九、红线（违反即事故）

1. 禁 `pkill -f fio` / `pkill -f juicefs` / `killall`（共享机，157 上有 WekaIO / K8s 生产业务）。停跑只能按精确 pid。
2. ⛔ 禁 `--layout`（`phase0_layout()` 含 `rm -rf ${TEST_DIR}/*`，删 384 个文件、重建 10.5min、此后历史数据全部不可比）。
3. 禁 `--remount` / `--allow-restart`。
4. 不改 ceph 配置 / IRQ / RPS / `pg_num`；`pg_autoscale_mode` 保持 **off**。
5. 不重启 157，不重启任何 OSD。
6. `ceph health` 异常立即停。
7. 脚本报错**可以改**，但：改完必须 `bash -n` + 回报 diff 与新 md5；**不许留副本**（不许 `cp FULLBASELINE_V4.sh xxx.sh`）。
8. 已授权的 sudo 写操作（每轮会执行几十次，属预期）：`ceph tell osd.N compact`（6 OSD）、经 sshpass 到 3 个 OSD 节点 `sync; echo 3 > /proc/sys/vm/drop_caches`、`juicefs gc --compact`、`umount`/`mount`。**超出此清单的 sudo 写操作一律先确认。**
9. 执行环境要分清：`md5sum` / `diff` / 复核在**本地 WSL**；测试 / `ceph` / `health` 在 **157 经 SSH**。

---

## 十、收尾（容易漏）

```bash
# /tmp 是易失的！结果必须归档
cp -r /tmp/opencode-fullbaseline-v4/<LABEL>/ \
      <repo>/results/E6/opencode-fullbaseline-v4/
```

| # | 动作 |
|---|---|
| 1 | 归档 157 `/tmp/opencode-fullbaseline-v4/` 到 `results/E6/opencode-fullbaseline-v4/` |
| 2 | 归档 `/tmp/w2base.log`、`rounds.tsv`、`jfs-instance-*.txt`、`cache-config-check-*.txt` |
| 3 | 出签收表（值 + 口径 + L2 + L3 + **可检出效应量**），写入 `report/` |
| 4 | 把"可检出效应量"传给调优阶段 —— 它决定哪些旋钮**根本不值得测** |

---

## 十一、已知坑速查

| 坑 | 表现 | 对策 |
|---|---|---|
| dry-run 覆盖不全 | dry-run 全绿但真实运行秒退 | 自检必须含一次真实短跑；`set -u` + `$(( ))` 引用未定义变量 = **静默**致命退出 |
| stderr 被吞 | 产物 0 字节、无报错 | 关键块别用 `2>/dev/null`；`\|\| true` 挡不住展开错误 |
| `rounds.tsv` 表头 | 表头是 S1 遗留的旧 5 列，数据是 8 列 | 表头不可信，按位取列：`LABEL round BW_MiBs hit status pg_gate pg gear` |
| `rounds.tsv` 的 BW | 是 **fio 汇总值**，不是验收口径 | 验收一律回到 `*_bw.*.log` |
| randrw 口径 | 同一性能相差 2 倍 | 见 §6.4 |
| 只看 range | 把首轮效应误判成累积漂移 | 见 §6.5，保留轮序 |
| 首运行效应 | 第一次运行的 seqread r1 冷启动（hit 85%）、randwrite 整体偏高 ≈5% | 首次运行作废，或安排在配对的对称位 |
| 跨轮 bw log 串台 | 带宽被两次跑加总，虚高 +14.6% | 见 §7 第 3 条 |
| `gear=N/A` | `gear_stat` 未产出 fast/slow/stall | 已知，不影响 L2/L3 |
| 挂载实例被换掉 | 出现 `forced-mount` | L3 全废，停机重来 |
