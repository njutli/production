# 03-6 · `--max-fuse-io` 拆包验证 + I1-I4 瓶颈定位仪表化

> 任务书类型：**一个调优项（T2.3）+ 一套仪表化基建**
> 执行方：GLM　｜　机器：157　｜　预计机器时间 **~6.5h**（今晚 19:00 → 01:30 左右）
> 脚本：`FULLBASELINE_V4.sh` md5 **`4198ea2676ba56744a3cd5eba17a5eab`**（1368 行，**本战役不得修改**）
> 新增基建：`scripts/FULLBASELINE/probe/instrument.sh`、`scripts/FULLBASELINE/analyze/latency-budget.py`
> 🔴 **本战役是 03 阶段第一个"调参 + 瓶颈定位"双产出战役**。仪表化部分的价值高于调参部分。

---

## 一、计划线（本任务在整体中的位置）

```
[03-1..03-4] 前置测量（探针能力 / 漂移底噪 / 写侧底噪）          ✅ 已完成
[03-5]  T1.1 = K1 bluestore_default_buffered_read               ✅ 已完成，判无效应 + 释放 18.3 GiB/OSD
        └─ 副产物：排除 OSD 设备层（落盘 56.6× 吞吐 0）、OSD 缓存层
[B 项]  写侧 TX 放大测量（归档数据重算，零机器时间）              ✅ 已完成，见 §0.2
[A 项]  readahead 扫档                                          ❌ 取消（老集群 10_A_4 §6.1 已做，旋钮是二元的）
[03-6]  ★本任务★ T2.3 `--max-fuse-io` + I1-I4 仪表化           ← 今晚
[03-7]  §五 OSD 旋钮清扫 K3-K7（两级筛查，带 I1-I4）             周末，无人值守
[后续]  依 03-6/03-7 的延迟预算结果决定：客户端路径 or 元数据路径
```

---

## 二、背景：为什么是这一项（三条实测依据，非理论推测）

### 2.1 FUSE 拆包已实测确认

从 172 轮归档数据（`results/stability-raw/week3-20260803-0806/`）的 `jfs-stats` 提取：

| 项 | 平均 FUSE 读请求尺寸 | fio `bs` |
|---|---|---|
| seqread | 130,919 B | 256 KiB |
| mseqread | 131,025 B | 256 KiB |
| randread | 130,961 B | 256 KiB |
| randrw | 130,908 B | 256 KiB |

**七项全部落在 131,072 B = 128 KiB**，而全部测试项 `bs=256k` ⇒ **每个客户端 IO 被 FUSE 拆成 2 个请求**。挂载实查 `/proc/mounts` 亦为 `max_read=131072`，`juicefs mount --help` 的 `--max-fuse-io` 默认值正是 `128K`。三处独立吻合。

### 2.2 这是唯一"已声称大收益但从未复验"的旋钮

`02-1b` 报告曾声称 `--max-fuse-io 128K→256K` 带来"读 +16% / 写 +70%"，但该结论建立在**漂移基线**上（当时写侧 683↔1760 相差 2.6×）。03 计划 §7.2 已标注它是"02 计划里唯一已声称大收益但可能是假的结论"。

### 2.3 它作用在唯一尚未被排除的层

已被实测排除的层：

| 层 | 余量 / 结论 | 依据 |
|---|---|---|
| NVMe 设备 | **≥3.7×** 余量 | 03-5：落盘 19→1073 MB/s/OSD（56.6×），吞吐 +0.22% |
| OSD 内存 / BlueStore 缓存 | 无关 | 03-5：110 GiB 缓存全废，吞吐 +0.22% |
| OSD CPU | ~1 核，未饱和 | `01-5:161` |
| 网卡字节 | RX 21-34% / TX 11-41% 线速 | §0.2 全项放大表 |

剩下的唯一嫌疑段 = **`fio → FUSE → JuiceFS → librados`**，`--max-fuse-io` 正作用于其入口。

### 2.4 已知的并发压缩现象（本战役要看它是否被改善）

同一批归档数据反推（Little 定律）：

| 项 | fio 要求并发 | 对象层实际在飞 GET | 压缩比 |
|---|---|---|---|
| randread | 16384 | **164** | ~100× |
| randrw | 16384 | **132** | ~124× |
| mseqread | 16 | 82 | —（readahead 放大） |

GET 延迟 9.1-9.7 ms，而单流 seqread 仅 966 µs ⇒ **延迟几乎全是排队**。若拆包是排队来源之一，加大 `--max-fuse-io` 应同时降低 FUSE 请求数与在飞压缩比。

---

## 三、目标与判定（两层，严格分开）

### 3.1 第一层：机制层（**本战役的正式判定，档位免疫**）

跨 8 个挂载实例实测，下列指标 CV 仅 **0.04-0.94%**（对照：吞吐跨实例 median 极差 **29.9%**），故可用少量挂载判定：

| 指标 | A 臂基线值 | 判定 |
|---|---|---|
| **平均 FUSE 读请求尺寸** | 131,072 B | B 臂须 ≥262,144；C 臂须 ≥1,048,576。**否则该臂参数未生效，判无效** |
| **RX 放大率** randread | 2.07 | 变化 ≥2%（=2× 跨实例 CV）才算真变化 |
| **RX 放大率** randrw | 2.33 | 同上 |
| **GET 次数 / 客户端 IO** | randread 1.53｜randrw 1.62 | 同上 |
| **JFS 层放大**（GET 字节÷fio 读字节） | randread 2.04｜randrw 2.26 | 同上 |

### 3.2 第二层：吞吐（**本战役明确不判定**）

🔴 **本战役不对吞吐下任何结论。** 理由：跨挂载实例 median 极差 **29.9%**，3 挂载/臂的分辨力约 29.9%/√3 ≈ 17%，而待判效应声称仅 +16% ⇒ **结构上不可判**。

- 吞吐**只记录、不判定**，且必须连同该挂载的 `gear` 值一并记录，供后续合并进完整 T2 协议（12 挂载/臂）时复用。
- ⛔ 报告中**禁止**出现"提升 / 改善 / 变好"等对吞吐的定性表述。只允许写"A 臂 median X，B 臂 median Y，不可判"。
- ⚠ 档位门控（探针筛高档）在本战役**不可用**：探针本身是 randread，而 `--max-fuse-io` 会改变 randread ⇒ 门控失效（03 计划 §7.1 已载明）。故不做门控。

### 3.3 第三层：仪表化交付（**与调参同等重要**）

跑完后必须产出一张**跨层延迟预算表**，覆盖：`fio clat → FUSE → JuiceFS 调度 → meta(TiKV) → 对象(RADOS) → OSD 服务`。这是 03-7 及后续所有战役的基建。

---

## 四、口径矩阵

| 项 | 值 |
|---|---|
| 臂 | **A** `--max-fuse-io 128K`（=现状基线）｜**B** `256K`｜**C** `1M` |
| 其余挂载参数 | 三臂完全一致：`--max-uploads 150 --cache-size 0`（单变量） |
| `ITEMS` | `mseqread randread randrw` |
| `RUNTIME` / `REPEAT` | `180` / `2` |
| 挂载次数 | **9**（A B C A B C A B C，**强制交错**，禁分臂串行） |
| LABEL | `T36-A1 T36-B1 T36-C1 T36-A2 T36-B2 T36-C2 T36-A3 T36-B3 T36-C3` |
| remount | **每挂载一次**（用 V4 的 `--remount`）— 本战役唯一授权的非查询操作 |
| 单挂载耗时 | mseqread ~6min + randread ~11min + randrw ~16min + reset/remount ~10min ≈ **43min** |
| 总计 | 9 × 43min ≈ **6.5h** |
| 结果目录 | V4：`/tmp/opencode-fullbaseline-v4/`｜仪表：`/tmp/opencode-t3.6/` |

> **不含写侧重项**：`randwrite`（39min/臂）与 `seqwrite`/`mseqwrite` 不在本战役。randwrite 的元数据层异常（meta 延迟 149 ms）归 03-7 专门处理。
> **对象数风险低**：仅 randrw 产生对象，单轮 gross ~0.88M，9 挂载 × 2 轮远低于红线；`OBJ_GATE` 保持开启即可。

---

## 五、执行步骤

### 步骤 0 · 红线自查（必须逐条打勾后落盘 `redlines-step0.txt`）

```
1. [ ] 禁 pkill -f fio / pkill -f juicefs / killall（157 是共享机，3075 用户）
2. [ ] 禁 --layout / rm -rf test_dir / juicefs gc --delete / destroy / format
3. [ ] 禁 --allow-restart、禁重启 157、禁重启任何 OSD
4. [ ] 禁修改 FULLBASELINE_V4.sh（md5 必须始终为 4198ea2676ba56744a3cd5eba17a5eab）
5. [ ] 禁任何 ceph config set（本战役不碰 Ceph 配置）
6. [ ] 禁触碰 /tmp/ray（24G，属 server 用户）
7. [ ] /tmp 余量 <5G 立即停
8. [ ] ceph health 连续 3 次非 OK → 恢复默认挂载参数并停
9. [ ] 出现 recovery / backfill / nonclean PG → 停
10.[ ] 本战役唯一授权的写操作 = remount（`juicefs mount` / `fusermount -u`），其余一律只读
11.[ ] 收尾必须把挂载恢复成 `--max-uploads 150 --cache-size 0`（即 128K 默认）
```

### 步骤 1 · 前置门禁（全部通过才开跑，落盘 `gate-pre.txt`）

```bash
set -uo pipefail
OUT=/tmp/opencode-t3.6; mkdir -p "$OUT"
{
  echo "=== 1. V4 md5（必须 4198ea2676ba56744a3cd5eba17a5eab）==="
  md5sum /tmp/FULLBASELINE_V4.sh
  echo "=== 2. 磁盘余量（<5G 停）==="
  df -h /tmp | tail -1
  echo "=== 3. ceph health / PG ==="
  sudo ceph health detail 2>&1 | head -5
  sudo ceph pg stat
  echo "=== 4. 当前挂载实例与 FUSE 参数 ==="
  pgrep -af juicefs | grep mount
  grep juicefs /proc/mounts
  echo "=== 5. 卷格式（BlockSize 必须 256，Readahead 2097152）==="
  python3 -c "import json;d=json.load(open('/mnt/juicefs/.config'));c=d.get('Chunk',{});print({k:c.get(k) for k in ['BlockSize','BufferSize','Readahead','Prefetch','MaxUpload','CacheSize']})"
  echo "=== 6. 池对象数起点 ==="
  sudo ceph df --format=json | python3 -c "import json,sys;d=json.load(sys.stdin);[print(p['name'],p['stats']['objects'],p['stats']['stored']) for p in d['pools'] if p['name']=='juicefs-data']"
  echo "=== 7. 仪表化脚本就位 ==="
  md5sum /tmp/instrument.sh
  echo "=== 8. 内核 FUSE 上限（5.15 编译上限 256 页 = 1 MiB）==="
  uname -r
} > "$OUT/gate-pre.txt" 2>&1
cat "$OUT/gate-pre.txt"
```

### 步骤 2 · 冒烟测试（**强制，三条验收，未过不得进正式**）

用 `T36-SMOKE` 标签、`ITEMS=mseqread`、`REPEAT=1`、`RUNTIME=60`、B 臂参数跑一次，验收：

```
[ ] 验收1：/proc/mounts 的 max_read 变成 262144（证明 --max-fuse-io 256K 真生效）
[ ] 验收2：instrument.sh start/stop 产出全部 18 类文件，i4 的 12 个 JSON 均可 json.load
[ ] 验收3：latency-budget.py 能解析出 T36-SMOKE 的平均 FUSE 请求尺寸，且该值 ≥262144
```

三条全过后，**必须把 SMOKE 的产物从 `rounds.tsv` 与结果目录彻底清除**（03-5 的教训：GLM 声称已清除但实际残留 2 行 `randrw-SMOKE1-r1`）。清除后回报 `grep -c SMOKE /tmp/opencode-fullbaseline-v4/rounds.tsv` 必须为 **0**。

### 步骤 3 · wrapper 要求（九条）

```bash
#!/usr/bin/env bash
# /tmp/t3.6-wrapper.sh
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh
INSTR=/tmp/instrument.sh
OUT=/tmp/opencode-t3.6
BASE_OPTS="--max-uploads 150 --cache-size 0"
mkdir -p "$OUT"

declare -A ARM=( [A]="128K" [B]="256K" [C]="1M" )
declare -A WANT=( [A]=131072 [B]=262144 [C]=1048576 )
FAILS=0

for cycle in 1 2 3; do
  for arm in A B C; do
    LABEL="T36-${arm}${cycle}"
    OPTS="${BASE_OPTS} --max-fuse-io ${ARM[$arm]}"

    # (1) 磁盘 / health 门禁：每挂载前检查
    avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc '0-9')
    [ "${avail:-0}" -lt 5 ] && { echo "STOP 磁盘 ${avail}G <5G"; break 2; }

    # (2) 仪表化 start（tag = LABEL，提取器按轮次 nic.txt 时间窗切片）
    bash "$INSTR" start "$OUT" "$LABEL"

    # (3) 跑 V4：带 --remount，挂载参数经 JUICEFS_MOUNT_OPTS 注入
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="mseqread randread randrw" \
      bash "$V4" "$LABEL" 180 2 --remount >> "$OUT/wrapper.log" 2>&1
    rc=$?

    # (4) 仪表化 stop（先采 I4 post 再停采样器）
    bash "$INSTR" stop "$OUT" "$LABEL"

    # (5) 参数生效验证：max_read 必须等于该臂期望值
    mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
    echo "$LABEL arm=$arm opts='$OPTS' rc=$rc max_read=$mr want=${WANT[$arm]}" | tee -a "$OUT/arm-verify.txt"
    if [ "${mr:-0}" != "${WANT[$arm]}" ]; then
      echo "$LABEL ❌ max_read 未生效，该臂数据作废" >> "$OUT/arm-verify.txt"
    fi

    # (6) 实例记录：本战役每挂载都是新实例（与 03-5 相反，此处要求各不相同）
    pid=$(pgrep -af juicefs | awk '/mount/{print $1;exit}')
    echo "$LABEL pid=$pid starttime_ticks=$(awk '{print $22}' /proc/$pid/stat 2>/dev/null)" \
      >> "$OUT/instances.txt"

    # (7) 连续失败才停：单次 rc≠0 记录后继续，连续 2 次才中止
    if [ "$rc" -ne 0 ]; then FAILS=$((FAILS+1)); else FAILS=0; fi
    [ "$FAILS" -ge 2 ] && { echo "STOP 连续 2 次失败"; break 2; }

    # (8) health 记录（03-5 教训：全程无任何 HEALTH_ 落盘，"全程 OK"是无据之言）
    { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; \
      sudo ceph pg stat; } >> "$OUT/health.txt"

    # (9) 首挂载后回报校验点，等确认再继续
    if [ "$LABEL" = "T36-A1" ]; then
      echo "=== 首挂载校验点，等待确认 ===" | tee -a "$OUT/wrapper.log"
      python3 /tmp/latency-budget.py /tmp/opencode-fullbaseline-v4 T36-A1 --instr "$OUT" \
        | tee "$OUT/checkpoint-A1.txt"
      break 2   # 🔴 首挂载后必须停下等确认，不得自行续跑
    fi
  done
done
```

🔴 **步骤 3 的第 (9) 条是硬要求。** 03-5 的 wrapper 一口气跑完 6 run 且在报告里写"用户确认继续"——**并无此确认**。本战役首挂载（~43min）后必须停下、回报、等确认。确认后把 `break 2` 删掉再续跑剩余 8 挂载。

### 步骤 4 · 首挂载校验点必须回报的内容

1. `arm-verify.txt` 全文（`max_read` 是否等于 131072）
2. `checkpoint-A1.txt` 全文（延迟预算表）
3. `rounds.tsv` 中 T36-A1 的全部行（原样，含 tab）
4. `health.txt` 全文
5. 是否出现 `forced-mount`（`grep -c forced-mount wrapper.log`）

### 步骤 5 · 收尾（必做，缺一项算未完成）

```bash
# 1) 恢复默认挂载（回到 128K 基线口径）
JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0" ITEMS="mseqread" \
  bash /tmp/FULLBASELINE_V4.sh T36-RESTORE 60 1 --remount
grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1   # 必须回到 131072

# 2) 生成完整延迟预算表（正式交付物）
python3 /tmp/latency-budget.py /tmp/opencode-fullbaseline-v4 \
  T36-A1 T36-B1 T36-C1 T36-A2 T36-B2 T36-C2 T36-A3 T36-B3 T36-C3 \
  --instr /tmp/opencode-t3.6 --tsv /tmp/opencode-t3.6/budget.tsv \
  | tee /tmp/opencode-t3.6/budget.txt

# 3) 提取 bw 原始行（opencode 独立复算用）
{ printf 'label\titem_round\traw_line\n'
  for d in /tmp/opencode-fullbaseline-v4/T36-*/; do L=$(basename "$d")
    for s in "$d"*/; do n=$(basename "$s")
      grep -hE '^\s+(READ|WRITE): bw=' "$s/fio.txt" 2>/dev/null \
        | while IFS= read -r ln; do printf '%s\t%s\t%s\n' "$L" "$n" "$ln"; done
    done; done; } > /tmp/opencode-t3.6/bw-raw.tsv

# 4) 归档（🔴 必须校验条目数，03-5 的归档 tar 漏掉了全部 V4 轮次目录且无人发现）
cd /tmp && tar czf /tmp/opencode-t3.6-20260811.tar.gz \
  opencode-t3.6 $(ls -d opencode-fullbaseline-v4/T36-* | tr '\n' ' ') \
  opencode-fullbaseline-v4/jfs-instance-T36-*.txt
tar tzf /tmp/opencode-t3.6-20260811.tar.gz | wc -l    # 必须 >2000，且必须含 T36-*/ 轮次目录
tar tzf /tmp/opencode-t3.6-20260811.tar.gz | grep -c 'fullbaseline-v4/T36'   # 必须 >0
```

---

## 六、交付物（`/tmp/glm-03-6-report.md`）

> 🔴 **所有统计量（效应量、放大率变化、判定）由 opencode 计算。本报告只出原始数字与原文粘贴，禁止自行计算百分比与下结论。**

| # | 段 | 内容 |
|---|---|---|
| 1 | 过程时间线 | 9 挂载 × (arm, opts, rc, max_read, 耗时, 起止) |
| 2 | `arm-verify.txt` | 全文原样 |
| 3 | `instances.txt` | 全文原样（9 个实例的 pid + starttime_ticks，应各不相同） |
| 4 | `rounds.tsv` 的 T36-* 全部行 | 原样，保留 tab |
| 5 | `budget.txt` | 延迟预算表全文原样 |
| 6 | `health.txt` | 全文原样 |
| 7 | 异常与偏差 | 逐条列，**不许写"无其他异常"来概括** |
| 8 | 归档 | 路径 + `tar tzf | wc -l` + `grep -c fullbaseline-v4/T36` 的实际输出 |

---

## 七、红线汇总（12 条）

1. 禁 `pkill -f` 任何模式；停进程只用精确 PID
2. 禁修改 `FULLBASELINE_V4.sh`（md5 锚点）
3. 禁 `--layout` / `rm -rf` / `gc --delete` / `destroy` / `format`
4. 禁任何 `ceph config set`
5. 禁重启 157 / OSD / 任何服务
6. 禁触碰 `/tmp/ray`
7. `/tmp` <5G 立即停
8. ceph health 连续 3 次非 OK → 恢复默认挂载并停
9. 唯一授权写操作 = remount；收尾必须恢复 128K 默认
10. 首挂载后**必须**停下等确认
11. SMOKE 产物必须彻底清除，并回报 `grep -c SMOKE rounds.tsv` = 0
12. 归档后**必须**校验 tar 条目数与 `T36-*` 轮次目录存在

---

## 八、未解决项（本战役不解决，仅记录）

| 项 | 归属 |
|---|---|
| randwrite meta 延迟 149 ms（randrw 同 op 数仅 1121 µs，差 133×） | 03-7 |
| 每轮级 I4（OSD op 延迟按 item 拆分）——本战役 I4 是挂载级 | 03-7 |
| 吞吐判定（需完整 T2 协议 12 挂载/臂，且门控不可用） | 待排期 |
| `osd.3` 缺 `osd_mclock_max_capacity_iops_ssd` | 03-7 / K7 |
| `--max-readahead` 二元取舍决策（randread ↔ mseqread） | 待用户拍板 |
