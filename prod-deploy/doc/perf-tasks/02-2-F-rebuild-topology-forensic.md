# 02-2-F 重建波动因果取证任务书（rebuild-topology forensic）

> 面向对象：GLM 执行
> 是否重跑性能：**否**。本任务不跑任何 fio，只在重建后快照 Ceph 拓扑元数据（零性能开销）。
> 承接结果目录：`results/prod-02-2-rebuild-forensic-20260723/`
> 方法论 skill：`skills/TESTING-GUIDE.md`（§1.1 health）、`skills/baseline-reproduction-skill.md`（重建流程）
> 关联数据：`doc/perf-report/00-baseline-20260723.md` §五（跨重建不收敛）、`00-baseline-20260722.md` §10（波动归因）

---

## 〇、背景

00-baseline 两次 P1（0722、0723）都出现同一现象：
- **同一次挂载会话内 3 轮：CV < 0.35%（极稳）**
- **跨重建：randread/randrw/randwrite-true 漂移 16~37%，方向不可预测（0722 cleanup 偏高 +17~31%，0723 反转成 -4~26%）**

现有证据链已达"强相关 + 排除法"级别（跨重建噪声 = 会话内 20 倍；方向随机排除预热/劣化；同轮极稳排除客户端/负载侧）。**但缺一个直接观测：证明"重建确实改变了 Ceph 物理布局"这个中间机制**。

本任务补齐这最后一环，把结论从"强相关"钉死为"因果闭环"。

---

## 一、目标

**用直接的 Ceph 元数据证据证明：每次重建后，同一份数据/同一个 PG 被 CRUSH 映射到不同的 OSD 组合 / 不同的 primary OSD / 不同的 tmpfs 物理落点**，从而说明跨重建性能漂移的根因是"重建 = 新的随机物理系统"，而非 JuiceFS 参数或调优不当。

一句话判定：**若两次重建的 PG→OSD 映射 / primary-OSD 分布 / 采样对象 acting set 明显不同 → 因果成立，跨重建波动物理上不可通过重测消除，基线只能用区间表达。**

---

## 二、口径与执行矩阵

- 脚本：`scripts/tests/rebuild-topology-forensic.sh <TAG>`
- **采样时机（关键）**：在**每次重建 + layout 铺完数据之后、跑第一个 fio 之前**调用一次。这样快照的是"性能测试当时"的物理布局。
- 至少采集 **4 个重建点**（与 0723 轮次对齐，复用其重建即可，不新增重建）：
  | TAG | 组 | 说明 |
  |-----|----|----|
  | R1-A | default | 第 1 次重建 |
  | R2-B | ra0 | 第 2 次重建 |
  | R3-A | default | 第 3 次重建（与 R1-A 同组，做 default 内对比）|
  | R4-B | ra0 | 第 4 次重建（与 R2-B 同组，做 ra0 内对比）|
- **若已无重建机会**：至少在下一次任何重建的前后各采一次（≥2 个 TAG），最小可证。
- 无验收线（非性能测试）。

---

## 三、执行步骤（逐条勾选）

0. [ ] **【测试前必做】通读 skill 并确认关键点**：`skills/baseline-reproduction-skill.md`（§2.2/§2.5 清理层级）、`skills/TESTING-GUIDE.md`（§1.1 health）。确认本任务为**只读取证**，不触发任何清理/重建操作。
1. [ ] 确认脚本可执行：`chmod +x scripts/tests/rebuild-topology-forensic.sh`
2. [ ] 每次重建 layout 铺完、跑 fio 前，执行 `./rebuild-topology-forensic.sh <TAG>`（TAG 用 R1-A 等）
3. [ ] 收齐 4 个 TAG 快照后，做跨重建 diff：
   - `diff <R1-A>/07-pg-brief.txt <R3-A>/07-pg-brief.txt`（同为 default，看 PG→OSD 是否变）
   - `diff <R2-B>/07-pg-brief.txt <R4-B>/07-pg-brief.txt`（同为 ra0）
   - 对比各 TAG 的 `10-primary-osd-histogram.txt`（primary OSD 是否均衡/倾斜不同）
   - 对比各 TAG 的 `11-object-osd-map.txt`（采样对象 acting set 是否变）
   - 对比 `05-osd-metadata.txt` 里 tmpfs/设备落点是否变
4. [ ] 把快照目录同步回本地 `results/prod-02-2-rebuild-forensic-20260723/<TAG>/`
5. [ ] 出结论：把"PG 映射变化条数 / primary 直方图差异 / 采样对象落点差异"填入报告
6. [ ] **【测试后必做】按 skill 复核**：确认取证过程未意外触发清理/重建（本任务应零副作用），在报告记录合规自查结果。

---

## 四、交付物

- 结果目录：`results/prod-02-2-rebuild-forensic-20260723/{R1-A,R2-B,R3-A,R4-B}/`
  每个含：`00-FINGERPRINT.txt`（速览）、`02-osd-tree.txt`、`05-osd-metadata.txt`、`06-pg-dump-full.txt`、`07-pg-brief.txt`、`09-crush-dump.txt`、`10-primary-osd-histogram.txt`、`11-object-osd-map.txt`
- 报告落点：在 `doc/perf-report/00-baseline-20260723.md` 新增 §九「重建拓扑取证」，给出：
  1. 跨重建 PG→OSD 映射差异条数 / 总 PG 数（如 "512 个 PG 中 X 个 primary 变化"）
  2. primary-OSD 直方图对比（证明 default 两次重建的 OSD 负载分布不同）
  3. 采样对象 acting set 变化示例
  4. **因果结论**：CRUSH 规则不变、参数不变，唯一变化是重建导致的 OSD 状态/PG 映射 → 性能漂移根因确认为重建
- 同步 `skills/baseline-reproduction-skill.md`：在 §4.3 波动归因处补一行"因果已由 02-2-F 取证闭环，见 00-baseline-20260723 §九"

---

## 五、通用注意事项（必带，见 TASK-BOOK-AUTHORING-GUIDE §二）

1. **只读取证**：本任务不写数据、不跑 fio、不动 pool 对象。所有命令为 `ceph`/`rados` 只读查询。
2. **157 红线**：157 上有 WekaIO 业务在跑，**禁动内核/网卡/RoCE/md0/WekaIO 路径**；本脚本只读元数据，天然安全，但仍不得在 157 上做任何写操作。
3. **环境前置**：采样前 `ceph health` 应为 `HEALTH_OK`、OSD 全 `up`（skill §1.1）；若非健康态，记录在 `01-ceph-status.txt` 但仍采样（异常态也是证据）。
4. **记录规范**：每个 TAG 目录保留 `forensic.log` 与全部原始输出，不裁剪。
5. **WSL/SSH 注意**：157→slave 的 SSH 若挂住，先人工确认可连通再批量执行；脚本内 `sudo ceph` 在 157 本机执行（157 已配 ceph client），`rados ls` 亦在 157 本机。
6. **不新增重建**：优先复用既有 P1 的 4 次重建时机采样，**不为取证单独重建**（省时间）。

---

## 红线汇总

- **只读，零性能开销，不占性能测试窗口**。
- **不为取证单独重建**——搭车既有重建。
- 若两次重建映射**没有**明显差异（小概率）→ 说明根因另有其人，**显式标注、提示人工复审**，不得为凑结论而强解读（TASK-BOOK-AUTHORING-GUIDE §四）。
