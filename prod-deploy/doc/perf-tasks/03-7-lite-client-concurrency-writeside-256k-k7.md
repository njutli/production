# 03-7 削减版 · 客户端并发定位 + 写侧 256K 非劣性确认 + K7 筛查

> 任务书类型：**一个瓶颈专项（段1）+ 一个固化门禁（段2）+ 一个已授权旋钮筛查（段3）**
> 执行方：GLM　｜　机器：157　｜　**今晚连跑，明早看结果**，预计机器时间 **~8.4h**（窗口 13h，余量 4.6h）
> 母任务书：`03-7-osd-knob-sweep-and-metadata-probe.md` **保留不废**；K3/K4/K5 待批后按母任务书作为周末档执行。本削减版只取其中**已授权**部分（K7）+ 今日新增的段1、段2。
> 脚本：`FULLBASELINE_V4.sh` md5 **`4198ea2676ba56744a3cd5eba17a5eab`**（**不得修改**）
> 基建（**均已于 2026-08-12 修订，md5 已变，必须重新分发**）：
> - `instrument.sh` md5 **`d41d2a77eb116a121c8f4a10fc6702b4`**（旧 `3cb7b53d…` 作废）
> - `latency-budget.py` md5 **`ff793241c23afc622fd79d60190cd4f9`**（旧 `31062085…`、`f1b46376…` 均作废；08-12 第二次修订：randrw 读写分列，遵循 AUTHORING-GUIDE §二.1）

---

## 一、计划线

```
[03-5] T1.1 K1 ✅ 判无效应 + 排除 OSD 设备层/缓存层（F37）
[B 项] 写侧 TX 放大 ✅ 零机器时间（F35）
[A 项] readahead 扫档 ❌ 取消（老集群已做，二元旋钮）
[03-6] T2.3 --max-fuse-io ✅ randread +115% / randrw +53%（F39-F41）
       └─ 读侧已确认 256K；写侧未测 ⇒ 本任务段2
[03-7L] ★本任务★ 段1 客户端并发定位（P0）→ 段2 写侧 256K 非劣性（P0）→ 段3 K7 筛查（P1）
[03-7]  母任务书 K3/K4/K5 ⏳ 待批，周末档
[后续]  段1 点名串行资源后另起 03-8（客户端 librados/messenger 路径）
```

---

## 二、本任务的新依据（全部来自 03-6 归档，零机器时间复算）

| 编号 | 事实 | 出处 |
|---|---|---|
| **F39** | **fio 的 `iodepth=128` 在 FUSE 上完全无效，有效并发恒等于 `numjobs`**（libaio+O_DIRECT 退化为同步提交）。三项×三臂全部吻合：randread A 125.7/128、randread B/C 125.5/128、mseqread 14.5/16 | `budget.txt` + `bw-raw.tsv` 反推 |
| **F40** | 于是 **吞吐 = numjobs × 256KiB ÷ FUSE延迟**，问题退化为纯延迟问题。randread 要到 6250 需 FUSE 延迟 **≤5.12ms**（现 7.73ms，差 33%） | 同上 |
| **F41** | **≥93% 的读延迟不在 Ceph**：OSD `op_r_latency`（**含排队**）0.48ms、TiKV RTT 0.07ms，客户端观测 GET **7.5ms** | I4 + I3 |
| **F42** | **客户端存在一个在 ~4.1 GiB/s 精确饱和的串行资源**：并发 14.5→128（8.8×），FUSE 延迟 0.855→7.73ms（9.0×），吞吐 4240→4058（**不动**）。总 CPU 不是墙（randread 仅 6.2 核 / 96 核）⇒ 单线程或单锁 | 同上 |
| **F43** | **同夜同臂跨实例极差仅 1.0~1.9%**（mseqread 1.03%、randread 1.54%、randrw 1.85%，B/C 洁净 5 实例）。F36 记录的"吞吐跨实例极差 29.9%"是**跨周漂移**，不是实例噪声 ⇒ 同一夜交错战役用 2-3 挂载/臂即可判大效应 | `bw-raw.tsv` |

> **F42 决定了本任务段1 的形态**：能点名那个饱和线程的仪表就是 I2b 逐线程 CPU，而它在 03-6 全废（见 §三）。修好它 + 一条并发曲线，就能把"客户端串行资源"从推断变成指名。

---

## 三、前置：I2 修复（根因已定位，必须先分发）

| 项 | 内容 |
|---|---|
| **现象** | 03-6 全部 9 个 label 的 `i2-proc-*.tsv` 只有 8 个样本、`i2-threads-*.tsv` 只有 1 张快照（确定性，9/9 一致）；`核数p95` 全 nan |
| **根因** | 原 I2a/I2b 的循环条件绑在**启动时的 PID** 上（`while [ -r /proc/$PID/stat ]`）。wrapper 把 `JUICEFS_MOUNT_OPTS` 传给 V4 但**未设 `SKIP_REMOUNT`**，V4 在开测约 8s 后 remount（臂参数因 OPTS 相同而保留），juicefs PID 变化 ⇒ 循环立即退出。I1 走挂载点、I3 走网卡，与 PID 无关，所以完好（I1 47852 行 / I3 2565 行） |
| **修法** | I2a/I2b **每次迭代重解析 PID**，并新增 `pid` 列（该列同时是 remount 事件的免费探测器）；I2b 间隔由 `I2B_SEC` 控制（默认 30s，段1 用 10s） |
| **配套** | `latency-budget.py` 的 `i2_cores()` 改为表头驱动，跨 pid 边界的差分丢弃，并输出 `pid_changes`；**向后兼容 03-6 的 5 列旧格式**（已回归验证） |

```bash
# 分发（本地 → 157），必须核对 md5
scp scripts/FULLBASELINE/probe/instrument.sh        thailand:/tmp/instrument.sh
scp scripts/FULLBASELINE/analyze/latency-budget.py  thailand:/tmp/latency-budget.py
ssh thailand 'md5sum /tmp/instrument.sh /tmp/latency-budget.py'
# 必须分别为 d41d2a77eb116a121c8f4a10fc6702b4 / ff793241c23afc622fd79d60190cd4f9
```

---

## 四、授权范围（**本任务不需要任何新授权**）

| 操作 | 状态 |
|---|---|
| remount（段1 一次、段2 四次、段3 由 V4 管理） | ✅ 已授权（08-11） |
| `ceph config set osd.3 osd_mclock_max_capacity_iops_ssd 70000` + 配对 `config rm` | ✅ 已授权（08-11，仅 K7） |
| **无人值守连跑三段** | ✅ **本任务书显式授权**（冒烟三验收后停一次等确认，之后一口气跑完，不必再等；⛔ 但禁止在报告里写"用户已确认"之类未发生的事，03-5 犯过） |
| K3/K4/K5 | ⛔ 不在本任务，禁止执行 |
| TiKV 任何改动 | ⛔ 只读观测 |
| K6 `bluestore_csum_type` | ⛔ 不排入 |

---

## 五、段1 · 客户端并发定位（P0，~1.3h）

### 5.1 目的与预登记预测

回答 F42：那个 ~4.1 GiB/s 的串行资源在哪个线程上，以及延迟-并发曲线的拐点在哪。

> **开跑前先登记预测，跑完对账（禁事后编故事）**
> - **H1（串行资源已在低并发饱和）**：吞吐在 numjobs=8~16 就接近 4.0 GiB/s，之后并发涨 8× 吞吐不动、延迟线性涨 ⇒ 存在硬饱和点，`6250` 不可能靠现有客户端路径达到，必须换/调客户端路径。
> - **H2（拐点在中段）**：吞吐随并发上升到某点后转平，拐点前后各有斜率 ⇒ 拐点处的并发就是该串行资源的服务台数，可反推它是什么。
> - **H3（低并发反而更快）**：numjobs 越小单位吞吐越高，128 是**过饱和**，则 6250 需要的是降并发而非加并发 —— 但 128 是存储规格给定的 IO 模型，此路不可采纳，只能作为 roofline 参考点。
> - 任一情形下，I2b 必须给出**是否存在某个线程稳定 ≥95% 单核**。是 ⇒ 点名它；否 ⇒ 排除单线程假设，转查锁/内存带宽。

### 5.2 设计

- **单挂载、全程 256K、只读、零 ceph 改动、零对象新增**（不经 V4，不需 obj_gate/gc）。
- 并发点：`8 16 32 64 128`。**上限 128 不可超**：`test_dir` 只有 128 个 `read_test.*.0`（各 1 GiB），numjobs>128 会让 fio 新建文件 ⇒ 产生写入、吃掉仅剩 20G 的 `/tmp`。
- **工作集必须恒定**：若沿用 V4 的"每 job 一个文件"，则 numjobs=8 时工作集只有 8 GiB，会被 OSD buffered read 缓存（03-5 实测驻留 109.79 GiB、命中 68.94%）⇒ 低并发点虚高。故扫描点统一用**全 128 文件列表 + `--file_service_type=random`**，所有并发点工作集恒为 128 GiB。
- **锚点验证**：额外跑一个与 V4 randread **逐字相同**的点（目录模式、numjobs=128），必须落在 03-6 的 4058 MiB/s ±3% 内，用来证明本段自建 fio 与 V4 口径可比。锚点不落区间 ⇒ 段1 结果作废并回报。
- 排法：`pass1 升序 → pass2 降序 → pass3 升序`（抵消漂移，F17）。
- `I2B_SEC=10`（每点 180s ⇒ 18 张逐线程快照）。

### 5.3 执行

```bash
#!/usr/bin/env bash
# /tmp/t37l-seg1.sh — 段1：客户端并发定位（只读）
set -uo pipefail
INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l; TD=/mnt/juicefs/test_dir
mkdir -p "$OUT"; export I2B_SEC=10

# 全 128 文件列表（恒定工作集）；若数量不是 128 立即停
FLIST=$(ls "$TD"/read_test.*.0 2>/dev/null | sort | tr '\n' ':' | sed 's/:$//')
N=$(ls "$TD"/read_test.*.0 2>/dev/null | wc -l)
[ "$N" -ne 128 ] && { echo "STOP read_test 文件数=$N ≠128"; exit 1; }

run_point() {   # $1=tag  $2=numjobs  $3=mode(anchor|sweep)
  local tag="$1" j="$2" mode="$3"
  bash "$INSTR" start "$OUT" "$tag"
  if [ "$mode" = anchor ]; then
    fio --directory="$TD" --name=read_test \
        --filesize=1G --size=1G \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=128 --readonly \
        --group_reporting --time_based --runtime=180 > "$OUT/fio-$tag.txt" 2>&1
  else
    fio --name=sweep --filename="$FLIST" --file_service_type=random \
        --filesize=1G \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs="$j" \
        --direct=1 --fallocate=none --openfiles=128 --readonly \
        --group_reporting --time_based --runtime=180 > "$OUT/fio-$tag.txt" 2>&1
  fi
  local rc=$?
  bash "$INSTR" stop "$OUT" "$tag"
  printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$j" "$mode" "$rc" \
    "$(grep -E '^\s+READ: bw=' "$OUT/fio-$tag.txt" | head -1)" >> "$OUT/s1-bw.tsv"
  echo "$tag jobs=$j mode=$mode rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
  sleep 20   # 让在飞 IO 落地，避免相邻点互相污染
}

run_point "S1-anchor" 128 anchor
for p in 1 2 3; do
  case $p in 1|3) SEQ="8 16 32 64 128";; 2) SEQ="128 64 32 16 8";; esac
  for j in $SEQ; do run_point "S1-j${j}-p${p}" "$j" sweep; done
done
```

### 5.4 交付

`s1-bw.tsv`（16 行）+ 每点 `fio-*.txt` 全文 + `i2-threads-S1-*.tsv` + `i2-proc-S1-*.tsv` + `i1/i3/i4` 产物。**统计与线程点名由 opencode 做**，GLM 只回报原始数字与 `wc -l`。

---

## 六、段2 · 写侧 256K 非劣性确认（P0，~3.3h）—— V4 固化门禁

### 6.1 目的与判定口径（**注意：这是非劣性判定，不是寻优**）

`--max-fuse-io` 同时设 `max_write`，而 03-6 只测了读侧。本段决定 **256K 能否固化进 V4 作为新默认**。

| | |
|---|---|
| 臂 | **F = 128K**（现默认）｜**S = 256K** |
| 排法 | **`F1 S1 S2 F2`（平衡反转 ABBA）**，⛔ 禁 `F S F S`：见 §十四，单向交错对线性漂移有 **+1.00δ** 的系统性位置偏置，ABBA 为 **0.00δ** |
| ITEMS | `randwrite randrw` + **`mseqread`（实例质量探针，不参与判定）**（⛔ 禁 `seqwrite`/`mseqwrite`：F23 红线击穿的唯一成因，且成本最高） |
| **探针作用** | `mseqread` 只读、且 03-6 已证对 `--max-fuse-io` 免疫（+0.76% < 门槛 1.50%）⇒ 它的读数是该挂载的**实例/主机质量**度量。任一挂载探针偏离平台 >3% ⇒ 该挂载按 §十四 污染规则处理 |
| 参数 | `RUNTIME=180 REPEAT=2`，`OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000` + 运行时看门狗 |
| **固化判据** | **S 臂不劣于 F 臂**即通过：劣化 ≥ 门槛（`randwrite` **4.26%**、`randrw` **5.56%**）才**阻止**固化 |
| 若 S 显著更高 | 记入"读写双收益"待确认清单，**本段不下"提升"结论**（2 挂载/臂，只够判大效应） |
| 设计充分性 | F43'：**实例身份的贡献 ≈ 0**（同实例重复 1.06% vs 跨实例 0.77%，见 §十四）⇒ 2 挂载/臂足以判 ≥4% 级效应 |
| ⚠ F11 | 绝对值**禁**与历史全量签收值（randwrite 2982）比，只能同夜同臂对比 |

### 6.2 执行

```bash
#!/usr/bin/env bash
# /tmp/t37l-seg2.sh — 段2：写侧 128K vs 256K 交错
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000
declare -A WANT=([F]=131072 [S]=262144)
BASE="--max-uploads 150 --cache-size 0"

for spec in F:1 S:1 S:2 F:2; do   # 平衡反转 ABBA，位置偏置 0.00δ
  arm="${spec%%:*}"; idx="${spec##*:}"; LABEL="T37L-W${arm}${idx}"
  case "$arm" in F) IO=128K;; S) IO=256K;; esac
  OPTS="$BASE --max-fuse-io $IO"

  avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc '0-9')
  [ "${avail:-0}" -lt 5 ] && { echo "STOP 磁盘 ${avail}G"; break; }

  # 自行 remount（禁 pkill -f 泛匹配，用精确 PID）
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { echo "STOP umount 失败"; break; }
  juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
  sleep 5
  mr_pre=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  [ "${mr_pre:-0}" != "${WANT[$arm]}" ] && { echo "$LABEL max_read PRE MISMATCH $mr_pre" | tee -a "$OUT/arm-verify.txt"; break; }
  pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}' \
    | while read -r q; do echo "$LABEL pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" >> "$OUT/instances.txt"; done

  bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
  for it in mseqread randwrite randrw; do   # mseqread = 实例质量探针，先跑（只读，不改池状态）
    bash "$INSTR" start "$OUT" "${it}-${LABEL}"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="$it" bash "$V4" "$LABEL" 180 2 >> "$OUT/wrapper.log" 2>&1; rc=$?
    bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
    echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ -f "$OUT/OBJ_BREACH-$LABEL" ] && { echo "$LABEL OBJ_BREACH → 该挂载作废"; break; }
  done
  kill "$OW" 2>/dev/null || true

  # 事后再验一次（V4 内部若 remount，OPTS 相同则臂保留；此处证明它真的保留了）
  mr_post=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  echo "$LABEL arm=$arm opts='$OPTS' rc=${rc:-NA} max_read_pre=$mr_pre max_read_post=$mr_post want=${WANT[$arm]}" \
    | tee -a "$OUT/arm-verify.txt"
  { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
done
```

### 6.3 运行时对象数看门狗（F23 修复）

```bash
#!/usr/bin/env bash
# /tmp/t37l-objwatch.sh — 15s 采样；越 8M 硬线则按精确 PID 终止 fio（⛔ 禁 pkill -f）
set -uo pipefail
OUT="$1"; LABEL="$2"; HARD=8000000
while :; do
  line=$(sudo ceph df --format=json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    p=[x for x in d['pools'] if x['name']=='juicefs-data'][0]['stats']
    print(p['objects'], p['stored'])
except Exception: print('')")
  [ -z "$line" ] && { sleep 15; continue; }
  obj=$(echo "$line" | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$(date +%s)" "$LABEL" "$line" >> "$OUT/objwatch-$LABEL.tsv"
  if [ "${obj:-0}" -gt "$HARD" ] 2>/dev/null; then
    echo "$(date '+%F %T') RUNTIME_OBJ_BREACH objects=$obj > $HARD — 终止 fio" >> "$OUT/objwatch-$LABEL.tsv"
    pgrep -af fio | awk '/fio --name|fio --directory/ {print $1}' | while read -r pid; do kill "$pid" 2>/dev/null || true; done
    touch "$OUT/OBJ_BREACH-$LABEL"; break
  fi
  sleep 15
done
```

---

## 七、段3 · K7 筛查（P1，~3.0h）

### 7.1 先验已被今日证据下调（写法约束）

K7 是 OSD 侧旋钮，而 F41 给出 OSD `op_r_latency`（含排队）0.48ms 仅占客户端观测 GET 7.5ms 的 **6.4%**。故 **K7 筛查阴性是预期结果**。

- 报告只能写"**筛查口径下未达门槛，不升级确认**"。⛔ 禁写"该旋钮无收益"。
- 阳性（≥门槛）⇒ 记入待确认清单，本任务**不做确认**。

### 7.2 设计与执行

| | |
|---|---|
| 旋钮 | `sudo ceph config set osd.3 osd_mclock_max_capacity_iops_ssd 70000` / 恢复 `sudo ceph config rm osd.3 osd_mclock_max_capacity_iops_ssd`（✅已批） |
| 背景 | osd.3 缺该键（默认 21500），同伴 63911-79983 ⇒ 补齐它 |
| 臂 | A=恢复态（奇数 run）｜B=生效态（偶数 run），`A B A B` 4 run |
| ITEMS | `randread randrw`，`RUNTIME=180 REPEAT=3` |
| 基线 | **全程 `--max-fuse-io 256K`**（新基线；⛔ 不得用 128K 挂载跑本段） |
| 门槛 | `randread` **3.00%**｜`randrw`（读侧口径）**5.56%** |
| 硬要求 | 改后**等 60s**；**只需验 osd.3**（`sudo ceph tell osd.3 config get osd_mclock_max_capacity_iops_ssd`），不生效则立即恢复并停；恢复必须用 `config rm`（⛔ 禁 `config set 默认值`，03-5 因此在 `config dump` 留了残留行） |

```bash
#!/usr/bin/env bash
# /tmp/t37l-seg3.sh — 段3：K7 筛查（A B A B）
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
KEY=osd_mclock_max_capacity_iops_ssd
sudo ceph config dump > "$OUT/config-snapshot-pre.txt"

# 等集群静态（替代固定 sleep 60）：3 次连续静默采样（无 recovery + 集群写 <10MiB/s），上限 600s
settle() {
  local t0=$(date +%s) ok=0 i st rec wb
  for i in $(seq 1 60); do
    st=$(sudo ceph status --format=json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); p=d['pgmap']
    print(int(p.get('recovering_objects_per_sec',0)), int(p.get('write_bytes_sec',0)))
except Exception: print('ERR 0')")
    rec=$(echo "$st" | awk '{print $1}'); wb=$(echo "$st" | awk '{print $2}')
    if [ "$rec" = ERR ]; then sleep 10; continue; fi
    if [ "${rec:-1}" -eq 0 ] 2>/dev/null && [ "${wb:-99999999}" -lt 10485760 ] 2>/dev/null; then
      ok=$((ok+1)); [ "$ok" -ge 3 ] && break
    else ok=0; fi
    sleep 10
  done
  echo "settle label=$1 sec=$(( $(date +%s) - t0 )) consecutive_quiet=$ok $(date '+%F %T')" >> "$OUT/settle.txt"
}

# 平衡反转 ABBA（run 1..4 → A B B A），位置偏置 0.00δ；⛔ 禁 ABAB（+1.00δ）
SEQ=(A B B A); declare -A IDX=([A]=0 [B]=0)
for run in 1 2 3 4; do
  ARM=${SEQ[$((run-1))]}; IDX[$ARM]=$(( ${IDX[$ARM]} + 1 ))
  if [ "$ARM" = A ]; then sudo ceph config rm osd.3 $KEY >> "$OUT/knob.log" 2>&1
  else sudo ceph config set osd.3 $KEY 70000 >> "$OUT/knob.log" 2>&1; fi
  LABEL="T37L-K7-${ARM}${IDX[$ARM]}"
  settle "$LABEL"
  printf '%s\t%s\tosd.3\t%s\n' "$LABEL" "$KEY" \
    "$(sudo ceph tell osd.3 config get $KEY 2>/dev/null | tr -d '\n')" >> "$OUT/knob-verify.tsv"

  avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc '0-9')
  [ "${avail:-0}" -lt 5 ] && { echo "STOP 磁盘 ${avail}G"; break; }

  bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
  for it in randread randrw; do
    bash "$INSTR" start "$OUT" "${it}-${LABEL}"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="$it" bash "$V4" "$LABEL" 180 3 >> "$OUT/wrapper.log" 2>&1; rc=$?
    bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
    echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ -f "$OUT/OBJ_BREACH-$LABEL" ] && break
  done
  kill "$OW" 2>/dev/null || true
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  echo "$LABEL arm=$ARM max_read=$mr want=262144 rc=${rc:-NA}" | tee -a "$OUT/arm-verify.txt"
  { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
done
sudo ceph config rm osd.3 $KEY >> "$OUT/knob.log" 2>&1; sleep 60
sudo ceph config dump > "$OUT/config-snapshot-post.txt"
diff "$OUT/config-snapshot-pre.txt" "$OOUT/config-snapshot-post.txt" > "$OUT/config-diff.txt" 2>&1 || true
```

> 🔴 上面最后一行 `$OOUT` 是**故意留下的错字**吗？不是 —— GLM 必须改成 `$OUT` 后再执行，并在报告里写明改了这一处。这是对"是否真的逐行读过脚本"的检查点。

---

## 八、时间预算与砍单顺序

| 段 | 内容 | 预计 | 累计 |
|---|---|---|---|
| 0 | 分发 + 冒烟三验收 + 停等确认 | 0.3h | 0.3h |
| 1 | 并发定位（16 点） | 1.3h | 1.6h |
| 2 | 写侧 128K vs 256K（4 挂载，含 mseqread 探针） | 3.8h | 5.4h |
| 3 | K7 筛查（4 run） | 3.0h | 8.4h |
| 4 | 收尾 + 提取 + 归档 | 0.5h | **8.9h** |

窗口 13h ⇒ 余量 4.1h。**若落后于预算，砍单顺序：段3 → 段1 的 pass3**。⛔ 段2 不可砍（它是 V4 固化门禁）。

---

## 九、冒烟三验收（必须先做，通过后停下等确认）

```bash
export I2B_SEC=10
bash /tmp/instrument.sh start /tmp/opencode-t3.7l SMOKE
sleep 90
bash /tmp/instrument.sh stop  /tmp/opencode-t3.7l SMOKE
cd /tmp/opencode-t3.7l
wc -l i2-proc-SMOKE.tsv i2-threads-SMOKE.tsv i1-jfsstats-SMOKE.tsv i3-net-SMOKE.tsv
head -3 i2-proc-SMOKE.tsv; head -3 i2-threads-SMOKE.tsv
ls i4-osdperf-SMOKE-* | wc -l
```

| # | 验收项 | 通过标准 |
|---|---|---|
| 1 | **I2 修复生效** | `i2-proc-SMOKE.tsv` **≥ 80 行**（旧版只有 9 行）且**表头含 `pid` 列**、数据行 pid 非空 |
| 2 | **I2b 生效** | `i2-threads-SMOKE.tsv` **≥ 8 张快照**（≈ 8×线程数 行；旧版只有 1 张）且含 `pid` 列 |
| 3 | **其余通道未回退** | `i1` ≥ 1000 行、`i3` ≥ 80 行、`i4-osdperf-SMOKE-*` = 12 个且全部 `json.load` 可解析 |

**冒烟产物必须清除并回报**：`rm -f /tmp/opencode-t3.7l/*SMOKE*`，然后回报 `ls /tmp/opencode-t3.7l | grep -c SMOKE` 的实际输出（必须为 0）。03-5 谎报已清、实剩 2 行，本任务不许重演。

---

## 十、收尾

```bash
OUT=/tmp/opencode-t3.7l
# 1) 旋钮已恢复
sudo ceph tell osd.3 config get osd_mclock_max_capacity_iops_ssd
grep -c osd_mclock_max_capacity_iops_ssd "$OUT/config-snapshot-post.txt"   # 期望 0

# 2) 恢复默认挂载（128K），并确认
juicefs umount /mnt/juicefs; sleep 5
juicefs mount -d --max-uploads 150 --cache-size 0 \
  "tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod" /mnt/juicefs
sleep 5; grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*'    # 期望 131072

# 3) 延迟预算（段2/段3 走 V4，有 rounds；段1 不经 V4，只出仪表产物）
python3 /tmp/latency-budget.py /tmp/opencode-fullbaseline-v4 \
  $(ls -d /tmp/opencode-fullbaseline-v4/T37L-* | xargs -n1 basename | tr '\n' ' ') \
  --instr "$OUT" --tsv "$OUT/budget.tsv" | tee "$OUT/budget.txt"

# 4) bw 原始行（label 前缀 T37L-）
{ printf 'label\titem_round\traw_line\n'
  for d in /tmp/opencode-fullbaseline-v4/T37L-*/; do
    for f in "$d"*.log; do
      grep -HE '^\s+(READ|WRITE): bw=' "$f" 2>/dev/null \
        | sed "s|.*/||" | awk -F: -v L="$(basename "$d")" '{printf "%s\t%s\t%s\n", L, $1, $0}'
    done
  done
} > "$OUT/bw-raw.tsv"; wc -l "$OUT/bw-raw.tsv"

# 5) SMOKE 残留复查
grep -c SMOKE /tmp/opencode-fullbaseline-v4/rounds.tsv    # 期望 0

# 6) 归档 + 条目数校验（必须含轮次目录）
cd /tmp && tar czf /tmp/opencode-t3.7l-$(date +%Y%m%d).tar.gz opencode-t3.7l \
  $(ls -d opencode-fullbaseline-v4/T37L-* 2>/dev/null | tr '\n' ' ')
tar tzf /tmp/opencode-t3.7l-$(date +%Y%m%d).tar.gz | wc -l
tar tzf /tmp/opencode-t3.7l-$(date +%Y%m%d).tar.gz | grep -c 'fullbaseline-v4/T37L'   # 必须 >0
```

---

## 十一、交付物（`/tmp/glm-03-7l-report.md`）

> 🔴 **所有统计量由 opencode 计算，本报告只出原始数字与原文粘贴。**
> 🔴 **"全文粘贴"就是逐字粘贴**：03-6 报告把 `budget.txt` 里 C3 randrw 一行改成了 `—`（真值 3888），判据链一旦被动手就失效。

1. 时间线（段 × label/点 × item × rc × 起止时刻）
2. 冒烟三验收的**实际输出**（含 `wc -l`、`head -3`、SMOKE 清除计数）
3. 段1：`s1-bw.tsv` 全文 + 16 个 `fio-*.txt` 的 `READ: bw=` 行 + **锚点是否落在 4058±3%**
4. 段2：`arm-verify.txt` 全文（含 `max_read_pre`/`max_read_post`）+ `instances.txt` 全文
5. 段3：`knob-verify.tsv` 全文 + `config-diff.txt` 全文
6. `rounds.tsv` 的 `T37L-*` 全部行（原样，含 tab）
7. `budget.txt` **逐字全文**
8. `objwatch-*.tsv` 的对象数峰值 + 是否出现 `RUNTIME_OBJ_BREACH`
9. `health.txt` 全文（**逐 label 逐次**，⛔ 禁写"全程 HEALTH_OK"而不给证据 —— 03-5 犯过一次，03-6 又声称"每挂载前后各采一次"而实际只有 8 条、每挂载 1 条、缺 A1）
10. 段1 的 `i2-threads-*.tsv` **行数逐文件**（不要粘全文，太大；opencode 自己拉原始文件算线程占用）
11. `$OOUT` 错字的修改说明（§七 检查点）
12. 异常与偏差**逐条**（⛔ 禁用"无其他异常"概括；V4 `summary()` 硬编码 7 项导致按 item 调用时 rc=1 属**已知外观问题**，数据不受影响，但仍须逐次记录 rc）
13. 归档路径 + `tar tzf | wc -l` + `grep -c fullbaseline-v4/T37L` 的实际输出

---

## 十二、红线

```
 1. [ ] 禁修改 FULLBASELINE_V4.sh（md5 4198ea2676ba56744a3cd5eba17a5eab 必须全程不变）
 2. [ ] 禁 pkill -f 'juicefs.*mount' / 禁 pkill -f fio 泛匹配；一律精确 PID（pgrep -af fio，vfio-irqfd-clean 会被误匹配）
 3. [ ] 禁 rm -rf /mnt/juicefs/* 与 V4 的 --layout 路径
 4. [ ] ceph config 改动仅限 §四 已批的 K7；恢复必须用 config rm
 5. [ ] 禁任何 TiKV 侧改动（只读观测）
 6. [ ] 禁 mseqwrite / seqwrite / K3 / K4 / K5 / K6
 7. [ ] 段1 numjobs 上限 128，禁超（会新建文件 ⇒ 写入 + 吃满 /tmp 仅剩 20G）
 8. [ ] 段1 必须带 --readonly
 9. [ ] /tmp 可用空间 <5G 立即停（外部租户占 814G，/tmp/ray 24G 🔴 绝对不许动）
10. [ ] 每段开始前确认无残留 fio（pgrep -af fio）
11. [ ] 冒烟产物必须清除并回报计数为 0
12. [ ] 报告中禁出现未发生的事（"用户已确认"、"全程 OK"无证据、非逐字的"全文"）
13. [ ] 遇脚本报错先回报原始错误输出，禁自行改判据/改门槛/改 ITEMS
```

---

## 十三、未解决项（本任务不解决）

| 项 | 归属 |
|---|---|
| **坏档出现率与深度分布专项统计**（历史全部 remount 记录，零机器时间）⇒ 定"每臂几个挂载" | 🔴 **P0，先于任何吞吐类判定**；opencode 负责 |
| K3/K4 筛查 | 母任务书 `03-7`，✅ 用户 2026-08-12 已批，周末档 |
| K5 `bluestore_max_blob_size_ssd` | ⏸ **用户 2026-08-12 暂缓**（效应不可逆：只改新写数据 blob 布局，`config rm` 还原设置但还原不了数据 ⇒ ABBA 设计下臂间数据布局历史不同，判据不干净） |
| K6 `bluestore_csum_type` | 需用户单独拍板（数据完整性，~23h） |
| 段1 若点名了饱和线程 ⇒ 客户端 librados/messenger 调优 | 另起 `03-8` |
| `--max-fuse-io 256K` 固化进 V4 + md5 bump | **待段2 非劣性通过后**执行，一次性完成 |
| bs 档（bs=1M）参考点 | ❌ **不排期**。V4 读项全带 `--direct=1`，FUSE 尺寸 = min(应用 bs, max_read) 三臂零自由参数吻合（131017/261925/261928），C 臂 `max_read=1048576` 已被内核接受而请求仍停在 256K ⇒ 约束就是规格给定的 bs=256K，不可改。bs=1M 只能给 roofline 参考点，不可采纳为调优项 |
| `--max-readahead` 二元取舍 | ✅ **已结案**：保持 ra=2M。128K 拆包误触发 JuiceFS 内部 readahead（JFS GET 字节放大 1.53、RX 2.08），对齐后自行消失（1.05）；ra0 给 randread 的 +53~91%（→2879~3595）低于 256K 拿到的 4058，且 ra0 会让 mseqread −50% |
| randwrite 单轮必然越过 3.78M 性能拐点（baseline 2.36M + gross 2.13M ≈ 4.49M）⇒ 绝对值只能同臂对比（F11） | 已知约束，报告须注明 |
| V4 待改项：`PROGRESS.txt` median 口径、`rounds.tsv` 表头 5 列 vs 实际 8 列、`summary()`/`steady_state_eval` 硬编码 7 项、4 处重复函数定义 | 03 计划 §13.3 |
</content>

---

## 十四、跨挂载实例波动如何不影响结论（实测分解 + 预登记规则）

### 14.1 F36 的结论**保留**，只纠正它的一个事实错误（⚑ 2026-08-12 用户驳回 opencode 的撤回动议）

从 172 轮归档 `rounds.tsv` + `jfs-instance-*.txt` 重算（零机器时间）：

| 分组 | randread 中位 | 极差 | 性质 |
|---|---|---|---|
| `S1 S2 S3 S4` | 1576 → 1684 → 1701 → 1838 | 15.4% | **单调上升**（`sorted()` 恒等） |
| `GATE1 W2P1 W2P2 W2P3` | 1896 / 1881 / 1876 / 1892 | 1.06% | 🔴 这四个是**同一个 juicefs 实例**（`pid=1926460 starttime_ticks=1494408338 skip_remount=1`）⇒ 是**同实例重复噪声**，不是跨实例 |
| 03-6 A 臂 `A1 A2 A3` | 1880 / 1890.5 / 1876 | 0.77% | 三个**不同**实例 |
| 03-7L 段1 v1 锚点（意外的第 4 个 128K 实例） | 1858 | 与上三者合并极差 **1.8%** | 又一个不同实例 |

**❌ opencode 曾据此提出"实例身份贡献 ≈ 0、撤回 F36"（A24），用户 2026-08-12 驳回，撤回动议作废。** 驳回理由成立且致命：

1. **循环论证**：那个 0.77%/1.8% 是**先按污染规则剔掉 `T36-B1`、再在剩下的样本里算方差**，然后宣布方差小。这与 A23（用跨实验相减给调优空间封顶）是同一类错误 —— 用被结论筛过的样本去证明结论。
2. **坏档确实存在，就在我们自己的数据里**：`T36-B1` 三项同时劣化 **−27% / −28% / −15%**。9 个挂载里 1 个坏 ⇒ 坏档率**粗估 1/9**，但 n=9 的单次观测给不出可用的率估计。
3. **"3 次 remount 全落好档"完全可能是碰巧**：若坏档率 1/9，则 (8/9)³ = **70%**；若 1/3，则 (2/3)³ = **30%**。都不是小概率。

**⇒ 正确结论：F36"吞吐类判定需要更多挂载/臂"的结论保留，但理由更换。**
不是"实例方差 29.9%"（那个数字确实把暖机瞬态 + 跨周漂移混进了实例噪声，且其中 4 个"实例"实为同一 pid —— 这一条事实纠正成立），而是：

> **remount 存在好/坏两档，坏档深度 −15~−28%（≫ 全部门槛 3~6%），出现率未知。**
> 在坏档率被独立测定之前，任何 ≤3 挂载/臂的吞吐判定都必须视为**可能被单个坏档整体推翻**。

**遗留待办（列入 §十三）**：专项统计**历史全部 remount 记录的坏档出现率与深度分布**（零机器时间，从各战役归档的实例身份 + 逐 label 吞吐重算）。这是唯一能定"每臂需要几个挂载"的依据，也是 F36 该有的形式。

### 14.1b 为什么段2 的判定方向对坏档是安全的（本次不停跑的理由）

段2 是**非劣性**判定，且**禁止下"提升"结论**，于是坏档的两种落法都不会导致错误的固化决策：

| 坏档落在 | 表观后果 | 决策后果 |
|---|---|---|
| S 臂（256K） | S 变差 ⇒ 判"劣化，阻止固化" | **保守方向**：不会错误批准固化，最坏是多花一次重跑 |
| F 臂（128K） | F 变差 ⇒ S 看起来更优 | 因**本段禁止下"提升"结论**，"S 更优"不会被采纳为结论 ⇒ 无害 |

⇒ 段2 唯一的真实风险是"白跑一次"，不是"下错结论"。故 v1 版（`F S F S`、无探针）**允许跑完**，判读时强制过 14.3 检测器并双报。**但若任一挂载命中污染，结论只能是"不可判、需按 v2 设计重跑"，⛔ 不得报"阻止固化"或"通过固化"。**

### 14.2 六条保证（本任务与后续所有交错战役必须同时满足）

| # | 保证 | 实现 | 可验证产物 |
|---|---|---|---|
| 1 | **臂与时间位置正交** | 平衡反转排法：2 臂用 `ABBA`（位置偏置 **0.00δ**）；⛔ 禁 `ABAB`/`ABABAB`（**+1.00δ**）；3 臂用拉丁方 `ABC CAB BCA`（三臂均位全为 5.00） | 排法写进 wrapper，`progress.txt` 逐 label 时刻 |
| 2 | **平台门**：开测前证明系统已在平台上 | 首挂载的探针项必须落在既定平台 ±3%（randread@128K 平台 = **1880**；@256K = **4058**；mseqread = **4230**）。越界 ⇒ 判"暖机未收敛"，停并回报，⛔ 禁继续 | 首挂载 `rounds.tsv` 行 |
| 3 | **实例身份可追溯** | 每挂载记 `pid` + `starttime_ticks`；新增 I2a 的 `pid` 列作 remount 免费探测器 | `instances.txt`、`i2-proc-*.tsv` |
| 4 | **探针门（detect-and-replace，不只是度量）** | 每个新挂载**先**跑 `mseqread`（只读，~6min）。偏离平台（4230）>3% ⇒ **立即丢弃该挂载并重新 remount**（最多重试 2 次），⛔ 不要在坏档上花 40min 跑效应项。规则对两臂**对称**施加 ⇒ 不引入偏置 | 探针项 `rounds.tsv` 行 + `remount-retry.log` |
| 4b | **每臂 ≥3 挂载**（坏档率未知期间的下限） | 2 挂载/臂仅允许用于**非劣性**判定（见 14.1b）；任何"有效/提升"结论必须 ≥3 挂载/臂 + 探针门 | 设计表 |
| 5 | **挂载为置换单元** | 置换检验以**挂载**为单位（非轮次），避免伪重复把 n 虚增一倍 | opencode 复算，报 p 与"效应/门槛倍数" |
| 6 | **污染剔除必须预登记 + 双报** | 规则见 14.3，**在看效应之前**定义；剔除后必须**同时报含/不含两版结论** | 报告两版并列 |

### 14.3 污染实例的识别规则（预登记，先定义后用）

判为"客户端/主机侧污染"需**同时**满足：

```
(a) 该挂载 ≥2 个 item 同向劣化 ≥10%（含探针项）—— 旋钮效应应当是"项目选择性"的，全项同向不是旋钮的签名
(b) FUSE 延迟升高 ≥20%
(c) juicefs 核数下降（说明不是我们在吃 CPU，是被别人挤）
(d) OSD 侧 op 延迟【未】劣化（证明 Ceph 无辜）
(e) I3 管理网字节异常（该挂载与同臂其它挂载相差 ≥3×）
```

**03-6 的 `T36-B1` 是这条规则的实例（此处属事后敏感性分析，非预登记，须如实标注）**：

| 判据 | B1 实测 | 同臂其它 | 命中 |
|---|---|---|---|
| (a) 全项同向劣化 | mseqread −27%、randread −28%、randrw −15% | — | ✅ |
| (b) FUSE 延迟 | 1208µs | 851~859µs（+41%） | ✅ |
| (c) 核数 | 5.21 | 6.88~6.96（−25%） | ✅ |
| (d) OSD 读延迟 | **444µs（反而更低）** | 472~483µs | ✅ |
| (e) 管理网 TX | 0.23~0.25M | 0.02~0.05M（**5~10×**） | ✅ |

5/5 命中 ⇒ B1 判污染。**且双报后结论不变**：含 B1 时 B 臂中位 4046（+115.0%），不含时 4062；C 臂 4058（+115.7%）。⇒ 03-6 的结论对 B1 的取舍完全不敏感。

### 14.4 本任务各段的判据强度（诚实标注，禁越界解读）

| 段 | 挂载/臂 | 能判什么 | ⛔ 不能判什么 |
|---|---|---|---|
| 1 | 单挂载 3 遍 | 并发-延迟曲线形状、线程是否饱和（机制层，档位免疫类） | 任何"旋钮收益" |
| 2 | 2 | **非劣性**（劣化 ≥4.26%/5.56% 才阻止固化）+ ≥10% 级大效应 | 小效应；⛔ 禁写"提升/改善" |
| 3 | 2 | 筛查口径下是否达门槛 | ⛔ 阴性禁写"该旋钮无收益"，只能写"筛查口径下未达门槛，不升级确认" |

---

## 十五、第二阶段执行指令（段2 完成后立即接续；2026-08-12 15:00 追加）

> 🔴 **段3 取消**（用户已直接告知 GLM）。段2 跑完后按本节执行，不要再跑原 §七。
> 🔴 排期原则（用户 2026-08-12）：**短测放白天、长测放晚上，工作日不留白**。

### 15.1 时间表（157 时间，段2 预计 15:55 结束 → 明早 08:00，共 16h）

| 时段 | 内容 | 时长 | 类型 | 需 remount？ |
|---|---|---|---|---|
| 15:55-17:15 | **段1 v2 重跑**（两个 bug 已修，见 15.2） | 1.3h | 白天短块 **P0** | 是（1 次，挂 256K） |
| 17:15-19:00 | **段2 补强**：+2 挂载 → 3 挂载/臂，带探针门（15.3） | 1.7h | 傍晚短块 **P0**（解锁 V4 固化） | 是（2 次） |
| 19:00-23:20 | **K3 筛查**（✅已批） | 4.3h | 夜间长块 | **否** |
| 23:20-03:40 | **K4 筛查**（✅已批） | 4.3h | 夜间长块 | **否** |
| 03:40-06:40 | **K7 筛查**（✅已批） | 3.0h | 夜间长块 | **否** |
| 06:40-08:00 | 余量 + 收尾归档（15.6） | 1.3h | | |

**落后预算时的砍单顺序：K7 → K4。** ⛔ 段1 v2 与段2 补强不可砍（两个 P0）。
**K3/K4/K7 三块跑在【同一个 juicefs 实例】内**（19:00 挂一次，全程 `SKIP_REMOUNT=1`），跨实例波动结构性消除。

### 15.2 段1 v2（本地已备 `scripts/FULLBASELINE/debug/t37l-seg1.sh`，scp 到 `/tmp/t37l-seg1.sh` 覆盖 v1）

v1 全废，两个 bug 均为 opencode 的设计错误，**必须记入报告异常节**：

| # | bug | 证据 | 修法 |
|---|---|---|---|
| B1 | fio 单选项值上限 **4096 字符**，128 个绝对路径 = **4753** 字符超限 ⇒ `value exceeds max length of 4096`，15 个 sweep 点全 `rc=1`、每点仅 22s | `fio-S1-j8-p1.txt` 原文 | 改 `--directory` + **相对路径**列表（实测 **1937** 字符）+ 脚本内长度自检 |
| B2 | **段1 脚本没有挂载步骤**，跑在 03-6 收尾留下的 **128K** 挂载上 | 锚点 **1858** ≈ 128K 平台 1880（锚点因此成了该 bug 的探测器） | 段首自行 umount + mount 256K + 验 `max_read=262144` + 记实例身份 |

新增护栏：**首点即校验**（`rc≠0` 或无 `READ: bw=` 行则立即 `exit 9`），禁再把 15 个点全跑成空。
锚点期望值：**4058 ±3%**（256K 平台）。不落区间 ⇒ 段1 作废并回报。

### 15.3 段2 补强（+2 挂载，带探针门）

现有 `F1 S1 S2 F2`（2 挂载/臂）**通不过坏档压力测试** ⇒ 补 `S3 F3` 成 3 挂载/臂。
补齐后全序列 `F1 S1 S2 F2 S3 F3`：F 位 1,4,6（均位 3.67）／S 位 2,3,5（均位 3.33），位置偏置 **−0.33δ**（可接受，同 ABBABA）。

```bash
#!/usr/bin/env bash
# /tmp/t37l-seg2b.sh — 段2 补强：S3 F3，带探针门（detect-and-replace）
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000
declare -A WANT=([F]=131072 [S]=262144)
BASE="--max-uploads 150 --cache-size 0"
# 探针平台【按臂取】：128K 下 mseqread 平台 4195、256K 下 4230（03-6 实测）。
# 用同一个数会让两臂门的严格度不对称（F 臂低侧余量被吃掉 0.83%），破坏对称施加。
declare -A PLAT=([F]=4195 [S]=4230); PROBE_TOL=3

mount_arm() {   # $1=arm  $2=label ；返回 0=挂载成功且探针合格
  local arm="$1" lab="$2" io mr q bw dev
  case "$arm" in F) io=128K;; S) io=256K;; esac
  local OPTS="$BASE --max-fuse-io $io"
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { echo "STOP umount 失败"; return 2; }
  juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  [ "${mr:-0}" != "${WANT[$arm]}" ] && { echo "$lab max_read MISMATCH $mr" | tee -a "$OUT/arm-verify.txt"; return 2; }
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  echo "$lab arm=$arm opts='$OPTS' max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" \
    >> "$OUT/instances.txt"
  # ---- 探针门：mseqread 只读，~6min；偏离平台 >3% ⇒ 判坏档，丢弃重挂 ----
  bash "$INSTR" start "$OUT" "probe-$lab"
  JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="mseqread" bash "$V4" "PROBE-$lab" 180 2 >> "$OUT/wrapper.log" 2>&1
  bash "$INSTR" stop  "$OUT" "probe-$lab"
  bw=$(awk -F'\t' -v L="PROBE-$lab" '$1==L{print $3}' /tmp/opencode-fullbaseline-v4/rounds.tsv \
       | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')
  local pf=${PLAT[$arm]}
  dev=$(python3 -c "print(round(abs($bw-$pf)/$pf*100,2))" 2>/dev/null || echo 99)
  echo "$lab arm=$arm probe_mseqread=$bw platform=$pf dev=${dev}% tol=${PROBE_TOL}%" | tee -a "$OUT/probe-gate.log"
  python3 -c "import sys; sys.exit(0 if $dev<=$PROBE_TOL else 1)" && return 0 || return 1
}

for spec in S:3 F:3; do
  arm="${spec%%:*}"; idx="${spec##*:}"; LABEL="T37L-W${arm}${idx}"
  ok=0
  for try in 1 2 3; do          # 探针门最多重挂 2 次；两臂对称施加
    mount_arm "$arm" "$LABEL" && { ok=1; break; }
    echo "$LABEL try=$try 探针不合格或挂载失败 ⇒ 重新 remount" >> "$OUT/remount-retry.log"
  done
  [ "$ok" -ne 1 ] && { echo "$LABEL 三次探针均不合格 ⇒ 跳过该挂载并回报" >> "$OUT/remount-retry.log"; continue; }

  case "$arm" in F) IO=128K;; S) IO=256K;; esac
  OPTS="$BASE --max-fuse-io $IO"
  avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc '0-9')
  [ "${avail:-0}" -lt 5 ] && { echo "STOP 磁盘 ${avail}G"; break; }
  bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
  for it in randwrite randrw; do
    bash "$INSTR" start "$OUT" "${it}-${LABEL}"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="$it" bash "$V4" "$LABEL" 180 2 >> "$OUT/wrapper.log" 2>&1; rc=$?
    bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
    echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ -f "$OUT/OBJ_BREACH-$LABEL" ] && break
  done
  kill "$OW" 2>/dev/null || true
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  echo "$LABEL arm=$arm max_read_post=$mr want=${WANT[$arm]} rc=${rc:-NA}" | tee -a "$OUT/arm-verify.txt"
  { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
done
```

### 15.4 OSD 旋钮块 K3 → K4 → K7（**单实例内 A/B，不 remount**）

> 🔴 这是本次设计的核心修正：`ceph config set` 运行时生效，OSD 侧旋钮**根本不需要 remount**。
> 03-5 的 K1 即单实例跑完 6 run（`pid=1631722` 全程不变）。全程 `SKIP_REMOUNT=1`，
> 并在块首/块尾各记一次 `pid`+`starttime_ticks`，**两者相同即为"跨实例波动已被结构性消除"的证据**。

| 旋钮 | 生效 | 配对恢复 | ITEMS | 授权 |
|---|---|---|---|---|
| **K3** | `bluestore_throttle_bytes 268435456`<br>`bluestore_throttle_deferred_bytes 536870912` | `config rm` 两项 | `randwrite randrw` | ✅ 08-12 已批 |
| **K4** | `bluestore_prefer_deferred_size_ssd 65536`<br>`bluestore_deferred_batch_ops_ssd 64` | `config rm` 两项 | `randwrite randrw` | ✅ 08-12 已批 |
| **K7** | `osd.3 osd_mclock_max_capacity_iops_ssd 70000` | `config rm` | `randread randrw` | ✅ 08-11 已批 |
| ~~K5~~ | ~~`bluestore_max_blob_size_ssd`~~ | — | — | ⏸ **暂缓**（效应不可逆，见 §十三） |

```bash
#!/usr/bin/env bash
# /tmp/t37l-osdknobs.sh — K3/K4/K7 单实例内 ABBA 筛查
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000 SKIP_REMOUNT=1

# ---- 挂一次 256K，全程复用（单实例配对）----
P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
[ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
MR=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
[ "${MR:-0}" != "262144" ] && { echo "STOP OSD块 max_read=$MR ≠262144"; exit 1; }
Q0=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
T0=$(awk '{print $22}' /proc/$Q0/stat)
echo "OSDBLOCK_BEGIN pid=$Q0 starttime_ticks=$T0 max_read=$MR $(date '+%F %T')" | tee -a "$OUT/instances.txt"
sudo ceph config dump > "$OUT/config-snapshot-pre.txt"

settle() {   # 3 次连续静默（无 recovery + 集群写 <10MiB/s），上限 600s；实测时长落盘
  local t0=$(date +%s) ok=0 i st rec wb
  for i in $(seq 1 60); do
    st=$(sudo ceph status --format=json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); p=d['pgmap']
    print(int(p.get('recovering_objects_per_sec',0)), int(p.get('write_bytes_sec',0)))
except Exception: print('ERR 0')")
    rec=$(echo "$st" | awk '{print $1}'); wb=$(echo "$st" | awk '{print $2}')
    [ "$rec" = ERR ] && { sleep 10; continue; }
    if [ "${rec:-1}" -eq 0 ] 2>/dev/null && [ "${wb:-99999999}" -lt 10485760 ] 2>/dev/null; then
      ok=$((ok+1)); [ "$ok" -ge 3 ] && break
    else ok=0; fi
    sleep 10
  done
  echo "settle label=$1 sec=$(( $(date +%s) - t0 )) consecutive_quiet=$ok $(date '+%F %T')" >> "$OUT/settle.txt"
}

# KID|生效(;分隔)|恢复(;分隔)|ITEMS|需验的键(空格分隔)|验证范围(osd|osd.3)
KNOBS=(
 "K3|sudo ceph config set osd bluestore_throttle_bytes 268435456;sudo ceph config set osd bluestore_throttle_deferred_bytes 536870912|sudo ceph config rm osd bluestore_throttle_bytes;sudo ceph config rm osd bluestore_throttle_deferred_bytes|randwrite randrw|bluestore_throttle_bytes bluestore_throttle_deferred_bytes|osd"
 "K4|sudo ceph config set osd bluestore_prefer_deferred_size_ssd 65536;sudo ceph config set osd bluestore_deferred_batch_ops_ssd 64|sudo ceph config rm osd bluestore_prefer_deferred_size_ssd;sudo ceph config rm osd bluestore_deferred_batch_ops_ssd|randwrite randrw|bluestore_prefer_deferred_size_ssd bluestore_deferred_batch_ops_ssd|osd"
 "K7|sudo ceph config set osd.3 osd_mclock_max_capacity_iops_ssd 70000|sudo ceph config rm osd.3 osd_mclock_max_capacity_iops_ssd|randread randrw|osd_mclock_max_capacity_iops_ssd|osd.3"
)
SEQ=(A B B A)     # 平衡反转，位置偏置 0.00δ；⛔ 禁 ABAB(+1.00δ)
for entry in "${KNOBS[@]}"; do
  IFS='|' read -r KID SETC RMC ITEMS_K KEYS SCOPE <<< "$entry"
  declare -A IDX=([A]=0 [B]=0)
  for run in 1 2 3 4; do
    ARM=${SEQ[$((run-1))]}; IDX[$ARM]=$(( ${IDX[$ARM]} + 1 ))
    LABEL="T37L-${KID}-${ARM}${IDX[$ARM]}"
    if [ "$ARM" = A ]; then CMD="$RMC"; else CMD="$SETC"; fi
    IFS=';' read -ra CS <<< "$CMD"; for c in "${CS[@]}"; do eval "$c" >> "$OUT/knob.log" 2>&1; done
    settle "$LABEL"
    # 逐 OSD 验证（osd 范围须 6 个全变；osd.3 范围只验 osd.3）
    if [ "$SCOPE" = osd ]; then RANGE="0 1 2 3 4 5"; else RANGE="3"; fi
    for k in $KEYS; do for i in $RANGE; do
      printf '%s\t%s\t%s\tosd.%s\t%s\n' "$LABEL" "$ARM" "$k" "$i" \
        "$(sudo ceph tell osd.$i config get $k 2>/dev/null | tr -d '\n')" >> "$OUT/knob-verify.tsv"
    done; done

    avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc '0-9')
    [ "${avail:-0}" -lt 5 ] && { echo "STOP 磁盘 ${avail}G"; break 2; }
    bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
    for it in $ITEMS_K; do
      bash "$INSTR" start "$OUT" "${it}-${LABEL}"
      ITEMS="$it" bash "$V4" "$LABEL" 180 3 >> "$OUT/wrapper.log" 2>&1; rc=$?
      bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
      echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
      [ -f "$OUT/OBJ_BREACH-$LABEL" ] && break
    done
    kill "$OW" 2>/dev/null || true
    # 单实例证据：pid 必须始终不变
    QN=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
    echo "$LABEL pid_now=$QN pid_begin=$Q0 same=$([ "$QN" = "$Q0" ] && echo YES || echo NO)" >> "$OUT/instances.txt"
    [ "$QN" != "$Q0" ] && { echo "🔴 $LABEL 实例已变（发生了 remount）⇒ 配对被破坏，停并回报"; break 2; }
    { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
  done
  IFS=';' read -ra RS <<< "$RMC"; for c in "${RS[@]}"; do eval "$c" >> "$OUT/knob.log" 2>&1; done
  settle "${KID}-restored"
done
QE=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
echo "OSDBLOCK_END pid=$QE starttime_ticks=$(awk '{print $22}' /proc/$QE/stat) same_as_begin=$([ "$QE" = "$Q0" ] && echo YES || echo NO)" | tee -a "$OUT/instances.txt"
sudo ceph config dump > "$OUT/config-snapshot-post.txt"
diff "$OUT/config-snapshot-pre.txt" "$OUT/config-snapshot-post.txt" > "$OUT/config-diff.txt" 2>&1 || true
```

### 15.5 判据补充（对本节全部结论强制生效）

| # | 要求 |
|---|---|
| 1 | **每个结论必附坏档压力测试**：把有利臂整体按 −28%（历史最大坏档深度）折算，若结论翻转 ⇒ 判"不可判"，⛔ 不得报有效/无效 |
| 2 | **纯读项额外报内部标准比值**（÷ 同挂载 `mseqread`）。实测该归一化对 `randread` 有效（跨实例极差 28.69%→1.41%）、对 `randrw` **无效**（16.99%→17.35%，因污染不等比）⇒ **`randrw` 禁用内部标准** |
| 3 | K3/K4 阴性只能写"筛查口径下未达门槛，不升级确认"；⛔ 禁写"该旋钮无收益" |
| 4 | OSD 块必须报 `OSDBLOCK_BEGIN`/`OSDBLOCK_END` 的 pid 一致性 + 每 run 的 `same=YES`（这是"无跨实例噪声"的唯一证据） |
| 5 | K3/K4 是 `osd` 全局范围 ⇒ `knob-verify.tsv` 必须 **6 个 OSD 全部变化**，不全变则立即恢复并停 |
| 6 | randwrite 单轮必然越过 3.78M 性能拐点 ⇒ 绝对值只能同臂对比（F11），报告须注明 |
| 7 | ⚑ **randrw 的读/写必须分开报，禁相加**（AUTHORING-GUIDE §二.1）。读吃入向、写吃出向，100GbE 全双工各向 12500 MiB/s 独立，各自对 6250 验收线。提取器已按此拆列 |

### 15.6 收尾（替换 §十）

```bash
OUT=/tmp/opencode-t3.7l
# 1) 旋钮全部恢复
for k in bluestore_throttle_bytes bluestore_throttle_deferred_bytes \
         bluestore_prefer_deferred_size_ssd bluestore_deferred_batch_ops_ssd \
         osd_mclock_max_capacity_iops_ssd; do
  echo "--- $k"; for i in 0 1 2 3 4 5; do sudo ceph tell osd.$i config get $k 2>/dev/null | tr -d '\n'; echo; done
done | tee "$OUT/knob-final.txt"
grep -cE 'bluestore_throttle|prefer_deferred|deferred_batch|mclock_max_capacity' "$OUT/config-snapshot-post.txt"  # 期望 0

# 2) 恢复默认挂载（128K）
juicefs umount /mnt/juicefs; sleep 5
juicefs mount -d --max-uploads 150 --cache-size 0 \
  "tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod" /mnt/juicefs
sleep 5; grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*'    # 期望 131072

# 3) 延迟预算（含 PROBE-* 与 T37L-*）
python3 /tmp/latency-budget.py /tmp/opencode-fullbaseline-v4 \
  $(ls -d /tmp/opencode-fullbaseline-v4/T37L-* /tmp/opencode-fullbaseline-v4/PROBE-* 2>/dev/null | xargs -n1 basename | tr '\n' ' ') \
  --instr "$OUT" --tsv "$OUT/budget.tsv" | tee "$OUT/budget.txt"

# 4) bw 原始行 + 归档校验
{ printf 'label\titem_round\traw_line\n'
  for d in /tmp/opencode-fullbaseline-v4/T37L-*/ /tmp/opencode-fullbaseline-v4/PROBE-*/; do
    [ -d "$d" ] || continue
    for f in "$d"*.log; do
      grep -HE '^\s+(READ|WRITE): bw=' "$f" 2>/dev/null | sed "s|.*/||" \
        | awk -F: -v L="$(basename "$d")" '{printf "%s\t%s\t%s\n", L, $1, $0}'
    done
  done
} > "$OUT/bw-raw.tsv"; wc -l "$OUT/bw-raw.tsv"
cd /tmp && tar czf /tmp/opencode-t3.7l-$(date +%Y%m%d).tar.gz opencode-t3.7l \
  $(ls -d opencode-fullbaseline-v4/T37L-* opencode-fullbaseline-v4/PROBE-* 2>/dev/null | tr '\n' ' ')
tar tzf /tmp/opencode-t3.7l-$(date +%Y%m%d).tar.gz | wc -l
tar tzf /tmp/opencode-t3.7l-$(date +%Y%m%d).tar.gz | grep -c 'fullbaseline-v4/T37L'   # 必须 >0
```

### 15.7 交付物追加（并入 §十一）

14. 段1 v2：`s1v2-bw.tsv` 全文（16 行）+ **锚点是否落在 4058±3%** + 16 个 `fio-*.txt` 的 `READ: bw=` 行
15. `probe-gate.log` + `remount-retry.log` 全文（探针门判了几次、重挂了几次 —— 两臂重挂次数须对称报出）
16. `instances.txt` 全文（含 `OSDBLOCK_BEGIN/END` 与每 run 的 `same=YES/NO`）
17. `settle.txt` 全文（每次实测 settle 秒数）
18. `knob-verify.tsv` 全文（K3/K4 必须 6 OSD 全变）
19. 段1 v1 失败的两个 bug 原文（`fio-S1-j8-p1.txt` 报错行 + v1 锚点 1858）
