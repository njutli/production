# 03-7 · §五 OSD 旋钮清扫（K3-K7，两级筛查）+ F34 元数据专项

> 任务书类型：**一批调优项（§五 全部剩余旋钮）+ 一个瓶颈专项**
> 执行方：GLM　｜　机器：157　｜　**周末无人值守**，预计机器时间 **~17h**（分两天）
> 脚本：`FULLBASELINE_V4.sh` md5 **`4198ea2676ba56744a3cd5eba17a5eab`**（**不得修改**）
> 基建：`instrument.sh` md5 **`d41d2a77eb116a121c8f4a10fc6702b4`**｜`latency-budget.py` md5 **`ff793241c23afc622fd79d60190cd4f9`**
> ⚑ 2026-08-12：旧 md5（`3cb7b53d…` / `31062085…`）已作废。本任务书的 K3/K4/K7 部分已被 `03-7-lite` §十五 吸收执行（单实例内对照，不 remount）；
> 本书剩余未执行项仅 **K5（暂缓，效应不可逆）** 与 **K6（未授权）**，待 03-7-lite 结束后合并归档。
> 前置：**03-6 必须先完成**（本任务复用其仪表化流程与冒烟结论）

---

## 一、计划线

```
[03-5] T1.1 K1 ✅ 判无效应 + 排除 OSD 设备层/缓存层（F37）
[B 项] 写侧 TX 放大 ✅ 零机器时间（F35）
[A 项] readahead 扫档 ❌ 取消（老集群已做，二元旋钮）
[03-6] T2.3 --max-fuse-io + I1-I4 仪表化 ← 先行
[03-7] ★本任务★ K3/K4/K5/K7 两级筛查 + F34 元数据专项  ← 周末
[后续] 依 03-6/03-7 延迟预算决定主攻：客户端路径 or 元数据路径
```

---

## 二、设计变更说明（范围不砍，只改执行方式）

用户 2026-08-11 明确要求"§五 列的一堆写成一本大任务书，GLM 依次去做"。**范围一项不砍**，但执行方式按 §2.4 的实测证据做三处调整：

| 调整 | 内容 | 依据 |
|---|---|---|
| **两级筛查** | 筛查 `4 run (A B A B) × 3 轮` → 达门槛才升级 `6 run × 5 轮` 确认 | OSD 层已被 F37 界定为有 ≥3.7× 余量，先验低 ⇒ 先用便宜口径筛大效应；35.5h → **~17h** |
| **写侧 ITEMS 剔除 `seqwrite`/`mseqwrite`** | 写侧统一用 `randwrite randrw` | ① F35：mseqwrite 已达目标 77% 且仅需 1.30×，seqwrite 需 4.45× 但门槛只有 7.56%（勉强）；② F23：mseqwrite 是击穿 10M 红线的唯一成因；③ 成本最高（55min/run）。**触发 F11 ⇒ 每个旋钮自带同 ITEMS 基线臂，禁与全量签收值比** |
| **搭车 I1-I4** | 每个 item 独立 V4 调用，使 I4（OSD op 延迟）可按 item 拆分 | 用户要求调参 run 同时产出瓶颈定位数据；03-6 的 I4 只做到挂载级 |

**顺带修掉两个挂账缺陷（均用环境变量，不改 V4 本体）：**

| 缺陷 | 修法 |
|---|---|
| **F26** `OBJ_GC_PASSES=2` 第二遍完全无效（p1/p2 逐字节相同） | 全程 `OBJ_GC_PASSES=1` |
| **F23** `obj_gate()` 是轮边界闸门、不是运行时看门狗（10M 红线曾被击穿且无人察觉） | `OBJ_MAX=6000000` 收紧轮边界闸门 **+ wrapper 内运行时看门狗**（§五步骤 2），15s 采样，越线则按**精确 PID** 终止 fio 并判该轮 INVALID |

---

## 三、🔴 旋钮授权（K3/K4/K5 尚未授权，需逐项批准后才能执行）

| 旋钮 | 生效命令 | **配对恢复命令** | 授权状态 |
|---|---|---|---|
| **K7** | `sudo ceph config set osd.3 osd_mclock_max_capacity_iops_ssd 70000` | `sudo ceph config rm osd.3 osd_mclock_max_capacity_iops_ssd` | ✅ **已授权（08-11）** |
| **K3** | `sudo ceph config set osd bluestore_throttle_bytes 268435456`<br>`sudo ceph config set osd bluestore_throttle_deferred_bytes 536870912` | `sudo ceph config rm osd bluestore_throttle_bytes`<br>`sudo ceph config rm osd bluestore_throttle_deferred_bytes` | ⏳ **待批** |
| **K4** | `sudo ceph config set osd bluestore_prefer_deferred_size_ssd 65536`<br>`sudo ceph config set osd bluestore_deferred_batch_ops_ssd 64` | `sudo ceph config rm osd bluestore_prefer_deferred_size_ssd`<br>`sudo ceph config rm osd bluestore_deferred_batch_ops_ssd` | ⏳ **待批** |
| **K5** | `sudo ceph config set osd bluestore_max_blob_size_ssd 262144` | `sudo ceph config rm osd bluestore_max_blob_size_ssd` | ⏳ **待批** |
| ~~K6~~ | ~~`bluestore_csum_type` crc32c→none~~ | — | ⛔ **不排入本任务**（数据完整性，需用户单独拍板；全项 ~23h） |

**三条硬要求：**
1. 每个旋钮改动后**必须逐 OSD 验证**：`for i in 0 1 2 3 4 5; do sudo ceph tell osd.$i config get <key>; done`，**6 个不全变则立即恢复并停**（K7 只需验 osd.3）。
2. 改后**等 60s** 再开测（03-5 已验证有效）。
3. 用 `config rm` 恢复而非 `config set <默认值>` —— 03-5 用 set 恢复，导致 `config dump` 残留一行显式默认值。

---

## 四、判定口径

### 4.1 筛查级（本任务的主要产出）

| 项 | 门槛（`max(分辨力, 2×同实例 lag1 底噪)`） |
|---|---|
| `randwrite` | **4.26%** |
| `randrw`（读侧口径） | **5.56%** |

- 排法 `A B A B`（4 run 交错，**禁分臂串行**），每 run 3 轮。
- 判定用 **4 个 run median 的两臂 median 之差**；同时报升序臂序列（`ABAB`/`BABA` 完全交织 ⇒ 无臂间分离）与精确置换检验 p。
- **筛查为负 ≠ 旋钮无效**，只能写"**筛查口径下未达门槛，不升级确认**"。⛔ 禁止把筛查阴性写成"该旋钮无收益"。
- 筛查为正（≥门槛）⇒ 记入待确认清单，**本任务不做确认**，另起战役用 `6 run × 5 轮`。

### 4.2 搭车产出（与调参同等重要）

每个旋钮的两臂都必须产出延迟预算表，用于回答：
1. 该旋钮是否改变了 **OSD 侧 op 延迟**（I4 的 `op_w_latency` / `subop_w_latency`）——若 OSD 侧延迟没变，则旋钮对该层无作用，与吞吐结论互相印证；
2. 写路径的 **PUT 延迟 / 在飞 PUT / staging** 是否变化；
3. **F34 复现与归因**：randwrite 的 meta 延迟是否仍为 ~149 ms，以及负载下 TiKV RTT 是否退化。

### 4.3 F34 元数据专项（本任务的独立子目标）

| 已知 | 待答 |
|---|---|
| randwrite meta 延迟 **149,365 µs**，randrw 在同等 op 数（2.15M vs 1.96M）下仅 **1121 µs**（差 133×），反推在飞 meta ≈1625 | ① 149 ms 是 TiKV 服务端还是 10GbE 管理网？② 是否随写入速率呈拐点式崩溃？ |
| TiKV 在 `10.20.1.150-152` = **10GbE 管理网**（与 SSH、外部租户共享）；空闲 RTT **0.061 ms** | I3 在负载下采 RTT p50/p99/max + 管理网 RX/TX 字节 ⇒ 若 RTT 不退化且管理网带宽远未满，则归因 TiKV 服务端 |

⛔ 本任务**只观测、不调 TiKV**（TiKV 是生产元数据集群，任何改动需单独授权）。

---

## 五、执行

### 步骤 0 · 红线自查

沿用 `03-6` §五步骤 0 的 11 条，**并追加 3 条**：

```
12. [ ] 本任务授权的 ceph config 改动仅限 §三 已批准行；每项改动必须有配对 config rm 恢复
13. [ ] 禁任何 TiKV 侧改动（只读观测）
14. [ ] 禁 mseqwrite / seqwrite（不在 ITEMS，且 mseqwrite 是 F23 红线击穿的唯一成因）
```

### 步骤 1 · 前置门禁

沿用 `03-6` §五步骤 1 的 8 项，**并追加**：

```bash
# 9. 逐 OSD 记录本任务将要改动的全部旋钮现值（回滚依据）
OUT=/tmp/opencode-t3.7; mkdir -p "$OUT"
for k in bluestore_throttle_bytes bluestore_throttle_deferred_bytes \
         bluestore_prefer_deferred_size_ssd bluestore_deferred_batch_ops_ssd \
         bluestore_max_blob_size_ssd osd_mclock_max_capacity_iops_ssd; do
  for i in 0 1 2 3 4 5; do
    printf '%s\tosd.%s\t%s\n' "$k" "$i" "$(sudo ceph tell osd.$i config get $k 2>/dev/null | tr -d '\n')"
  done
done > "$OUT/knob-baseline.tsv"
sudo ceph config dump > "$OUT/config-snapshot-pre.txt"
wc -l "$OUT/knob-baseline.tsv"   # 应为 36 行
```

### 步骤 2 · 运行时对象数看门狗（F23 修复，wrapper 内）

```bash
# /tmp/t3.7-objwatch.sh — 15s 采样；越线则按精确 PID 终止 fio（禁 pkill -f）
set -uo pipefail
OUT="$1"; LABEL="$2"; HARD=8000000
while :; do
  line=$(sudo ceph df --format=json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    p=[x for x in d['pools'] if x['name']=='juicefs-data'][0]['stats']
    print(p['objects'], p['stored'])
except Exception: print('')" )
  [ -z "$line" ] && { sleep 15; continue; }
  obj=$(echo "$line" | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$(date +%s)" "$LABEL" "$line" >> "$OUT/objwatch-$LABEL.tsv"
  if [ "${obj:-0}" -gt "$HARD" ] 2>/dev/null; then
    echo "$(date '+%F %T') RUNTIME_OBJ_BREACH objects=$obj > $HARD — 终止 fio" >> "$OUT/objwatch-$LABEL.tsv"
    # 精确 PID：排除内核线程（vfio-irqfd-clean 会被 pgrep 匹配）
    pgrep -af fio | awk '/fio --name|fio --directory/ {print $1}' | while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done
    touch "$OUT/OBJ_BREACH-$LABEL"
    break
  fi
  sleep 15
done
```

### 步骤 3 · 主循环（每个旋钮 4 run × 每 item 独立调用）

```bash
#!/usr/bin/env bash
# /tmp/t3.7-wrapper.sh
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7
mkdir -p "$OUT"
export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000 SKIP_REMOUNT=1

# 每个旋钮：KNOB_ID|生效命令(分号分隔)|恢复命令(分号分隔)|ITEMS
KNOBS=(
 "K7|sudo ceph config set osd.3 osd_mclock_max_capacity_iops_ssd 70000|sudo ceph config rm osd.3 osd_mclock_max_capacity_iops_ssd|randread randrw"
 "K3|sudo ceph config set osd bluestore_throttle_bytes 268435456;sudo ceph config set osd bluestore_throttle_deferred_bytes 536870912|sudo ceph config rm osd bluestore_throttle_bytes;sudo ceph config rm osd bluestore_throttle_deferred_bytes|randwrite randrw"
 "K4|sudo ceph config set osd bluestore_prefer_deferred_size_ssd 65536;sudo ceph config set osd bluestore_deferred_batch_ops_ssd 64|sudo ceph config rm osd bluestore_prefer_deferred_size_ssd;sudo ceph config rm osd bluestore_deferred_batch_ops_ssd|randwrite randrw"
 "K5|sudo ceph config set osd bluestore_max_blob_size_ssd 262144|sudo ceph config rm osd bluestore_max_blob_size_ssd|randwrite randrw"
)
FAILS=0
for entry in "${KNOBS[@]}"; do
  IFS='|' read -r KID SETC RMC ITEMS_K <<< "$entry"
  for run in 1 2 3 4; do
    # A 臂 = 恢复态（奇数 run）；B 臂 = 生效态（偶数 run） ⇒ A B A B 交错
    if [ $((run % 2)) -eq 1 ]; then ARM=A; CMD="$RMC"; else ARM=B; CMD="$SETC"; fi
    LABEL="T37-${KID}-${ARM}$(( (run+1)/2 ))"

    avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc '0-9')
    [ "${avail:-0}" -lt 5 ] && { echo "STOP 磁盘 ${avail}G"; break 2; }

    # 切旋钮 + 逐 OSD 验证 + 等 60s
    IFS=';' read -ra CS <<< "$CMD"; for c in "${CS[@]}"; do eval "$c" >> "$OUT/knob.log" 2>&1; done
    sleep 60
    for k in $(echo "$SETC" | grep -oE 'bluestore_[a-z_]+|osd_mclock_max_capacity_iops_ssd' | sort -u); do
      for i in 0 1 2 3 4 5; do
        printf '%s\t%s\tosd.%s\t%s\n' "$LABEL" "$k" "$i" \
          "$(sudo ceph tell osd.$i config get $k 2>/dev/null | tr -d '\n')" >> "$OUT/knob-verify.tsv"
      done
    done

    bash /tmp/t3.7-objwatch.sh "$OUT" "$LABEL" & OW=$!
    for it in $ITEMS_K; do
      bash "$INSTR" start "$OUT" "${it}-${LABEL}-r1"     # per-item 标签 ⇒ I4 可按 item 拆
      ITEMS="$it" bash "$V4" "$LABEL" 180 3 >> "$OUT/wrapper.log" 2>&1; rc=$?
      bash "$INSTR" stop "$OUT" "${it}-${LABEL}-r1"
      echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
      [ -f "$OUT/OBJ_BREACH-$LABEL" ] && { echo "$LABEL OBJ_BREACH → 该 run 作废"; break; }
    done
    kill "$OW" 2>/dev/null || true

    { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
    if [ "${rc:-0}" -ne 0 ]; then FAILS=$((FAILS+1)); else FAILS=0; fi
    [ "$FAILS" -ge 2 ] && { echo "STOP 连续 2 次失败"; break 2; }
  done
  # 每个旋钮跑完立即恢复（不留跨旋钮污染）
  IFS=';' read -ra RS <<< "$RMC"; for c in "${RS[@]}"; do eval "$c" >> "$OUT/knob.log" 2>&1; done
  sleep 60
done
sudo ceph config dump > "$OUT/config-snapshot-post.txt"
diff "$OUT/config-snapshot-pre.txt" "$OUT/config-snapshot-post.txt" > "$OUT/config-diff.txt" 2>&1 || true
```

### 步骤 4 · 首个旋钮首 run 后必须停下回报

🔴 K7 的 `T37-K7-A1` 跑完（~48min）后**必须停下**，回报后等确认再续跑。03-5 的 wrapper 一口气跑完并在报告里谎称"用户已确认"，本任务不许重演。

### 步骤 5 · 收尾

```bash
# 1) 全部旋钮已恢复的验证（knob-baseline.tsv 应与收尾态逐行一致）
for k in bluestore_throttle_bytes bluestore_throttle_deferred_bytes \
         bluestore_prefer_deferred_size_ssd bluestore_deferred_batch_ops_ssd \
         bluestore_max_blob_size_ssd osd_mclock_max_capacity_iops_ssd; do
  for i in 0 1 2 3 4 5; do
    printf '%s\tosd.%s\t%s\n' "$k" "$i" "$(sudo ceph tell osd.$i config get $k 2>/dev/null | tr -d '\n')"
  done
done > /tmp/opencode-t3.7/knob-final.tsv
diff /tmp/opencode-t3.7/knob-baseline.tsv /tmp/opencode-t3.7/knob-final.tsv \
  && echo "✅ 全部旋钮已恢复" || echo "🔴 有旋钮未恢复，立即处理"

# 2) 延迟预算表（正式交付物）
python3 /tmp/latency-budget.py /tmp/opencode-fullbaseline-v4 $(ls -d /tmp/opencode-fullbaseline-v4/T37-* | xargs -n1 basename | tr '\n' ' ') \
  --instr /tmp/opencode-t3.7 --tsv /tmp/opencode-t3.7/budget.tsv | tee /tmp/opencode-t3.7/budget.txt

# 3) bw 原始行（同 03-6 §五步骤 5 第 3 条，label 前缀改 T37-）
# 4) 归档 + 校验条目数（必须含 fullbaseline-v4/T37-* 轮次目录）
cd /tmp && tar czf /tmp/opencode-t3.7-$(date +%Y%m%d).tar.gz opencode-t3.7 \
  $(ls -d opencode-fullbaseline-v4/T37-* | tr '\n' ' ')
tar tzf /tmp/opencode-t3.7-$(date +%Y%m%d).tar.gz | grep -c 'fullbaseline-v4/T37'   # 必须 >0
```

---

## 六、交付物（`/tmp/glm-03-7-report.md`）

> 🔴 **所有统计量由 opencode 计算，本报告只出原始数字与原文粘贴。**

1. 时间线（旋钮 × run × item × rc × 耗时）
2. `knob-baseline.tsv` / `knob-verify.tsv` / `knob-final.tsv` 全文（三者用于证明"改了 + 6 OSD 全生效 + 恢复了"）
3. `rounds.tsv` 的 T37-* 全部行（原样，含 tab）
4. `budget.txt` 全文
5. `objwatch-*.tsv` 的对象数峰值 + 是否出现 `RUNTIME_OBJ_BREACH`
6. `health.txt` / `config-diff.txt` 全文
7. **F34 专项**：randwrite 两臂的 meta 延迟、TiKV RTT p50/p99/max、管理网 RX/TX
8. 异常与偏差逐条（**禁止用"无其他异常"概括**）
9. 归档路径 + `tar tzf | wc -l` + `grep -c fullbaseline-v4/T37` 实际输出

---

## 七、红线汇总

沿用 `03-6` §七 12 条，**替换第 4 条、追加 3 条**：

```
4'. ceph config set 仅限 §三 已批准旋钮；每次改动必须逐 OSD 验证 + 配对 config rm 恢复
13. 禁任何 TiKV 侧改动（只读观测）
14. 禁 mseqwrite / seqwrite
15. 每个旋钮跑完立即恢复，禁跨旋钮叠加
```

---

## 八、未解决项（本任务不解决）

| 项 | 归属 |
|---|---|
| K6 `bluestore_csum_type` | 需用户单独拍板（数据完整性） |
| 筛查阳性项的确认战役（`6 run × 5 轮`） | 依本任务结果另起 |
| `--max-readahead` 二元取舍决策 | 待用户拍板（03 计划 §十） |
| randwrite 单轮内必然越过 3.78M 性能拐点 ⇒ 绝对值不可与拐点前数据比，只能同臂对比（F11） | 已知约束，报告须注明 |
| V4 待改项：`PROGRESS.txt` median 口径、`rounds.tsv` 表头 5 列 vs 实际 8 列、`summary()`/`steady_state_eval` 硬编码 7 项、4 处重复函数定义 | 03 计划 §13.3 |
| ⚠ **已知外观问题**：本任务按 item 分别调用 V4，而 `summary()`/`steady_state_eval` 硬编码 7 项 ⇒ 每次调用的汇总段会显示缺项。**不影响数据**（`rounds.tsv` 与轮次目录完整），报告以 `rounds.tsv` + `budget.txt` 为准，忽略 `summary` 段 | 本任务 |
