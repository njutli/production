# GLM 执行指令：NVMe 集群无损恢复 + C/D 组重跑（LC-NVMe 续）

> 来源：analyst `/tmp/bridge/analysis.md` LC.13。承接 `lcnvme-attribution-experiment-instructions-20260727.md`。
> 背景：四组实验中 C 组跑到 C-7 时集群进入灾难态（仅 osd.1/osd.3 up，全部 33 PG down）。A 组(10轮)、B 组(10轮，已复现双峰)数据完整有效。
> **analyst 已只读核查确认：osd.0/2/6/7 的底层数据完好无损（LVM/ceph-volume 映射全在盘上，未被 zap），只是容器/systemd 未拉起。可无损恢复，物理布局分毫不动。**

---

## 零、最高红线（本次恢复的生命线）

**⛔ 严禁 purge / zap / `ceph osd destroy` / `ceph-volume lvm create` / 任何重建 OSD 的操作。**

原因：本实验的核心结论就是"**数据物理布局是 randread 波动主因**"（B 组已在 NVMe 复现双峰）。osd.0/2/6/7 上的 128GiB 数据布局，与已完成的 A/B 组是**同一份**。一旦重建 OSD，物理布局改变 → C 组、D 组与 A/B 组不再可比 → 整个四组对照实验作废。

**恢复方式只允许"原地拉起现有 OSD"**（activate 现有 LV / 修 cephadm 数据库条目），不碰盘上数据。

若发现无损拉起不可行、或任何一步需要动到盘上数据 —— **立即停下，报告 analyst，不要自行决定重建。**

---

## 一、现状（analyst 已核实，供你对照）

- 集群 FSID=020ed5ec-8703-11f1-a671-97520597268c。EC pool 10 juicefs-data：size6 **min_size5** → 需 ≥5 shard 才 active。
- OSD 分布：osd.1/osd.3 在 node1（up in）；osd.6/osd.7 在 node2（down）；osd.0/osd.2 在 node3（down，`weight 0 autoout`）。
- **数据完好证据**（node2/node3 上 `ceph-volume lvm list` 均可见）：
  - osd.6 → `/dev/ceph-2e6b83c1.../osd-block-44b1555a...`（nvme2n1），osd fsid 44b1555a-ce9e-4dbe-8e92-affaadf816f8
  - osd.7 → `/dev/ceph-9658b68b.../osd-block-af7a9034...`（nvme3n1），osd fsid af7a9034-a7e2-4a5f-a07c-491d81d632fb
  - osd.0 → `/dev/ceph-8f493d49.../osd-block-372c648a...`（nvme2n1），osd fsid 372c648a-30df-4454-a4ba-5a4c62e15f1f
  - osd.2 → `/dev/ceph-8dd21f84.../osd-block-e3aecc91...`（nvme3n1），osd fsid e3aecc91-542c-4097-bd0b-3d1d17b1fea9
- 问题根因=cephadm **duplicate 守护进程条目**（`orch ps` 里 osd.1/6/7/10 同时挂在两个 host），来源=重建时混用 `ceph orch daemon add osd` + `ceph-volume lvm prepare`。cephadm agent 巡检时删了它认为"冲突"的容器 → C-7 撞上。

---

## 二、阶段 A：无损恢复到 HEALTH_OK（须报告后放行下一步）

**目标：让 osd.0/1/2/3/6/7 六个全部 up+in+active+clean，且盘上数据不动。**

推荐步骤（若你有更安全的等效路径可用，但须先报告再执行）：

1. **先清 cephadm duplicate 数据库条目**（只动 cephadm 记账，不动盘）：
   - 查 `sudo ceph orch ps --daemon-type osd`，确认哪些 osd.X 同时挂在多个 host。
   - 用 `sudo ceph orch daemon rm osd.X --force` **仅删除"错误 host 上的那条 stale 守护进程记录"**（例如 osd.6/osd.7 在 node1 的 error 条目，正确 host 是 node2）。⚠️ 这只删 cephadm 记账里的重复项，不会 zap 盘。删前把当前 `orch ps` 完整输出报告 analyst 一并核对哪条该删。
   - **如果对某条记录是否该删有任何不确定 → 停下报告，不要猜。**

2. **恢复 osd.0/osd.2 的 in 状态**（它们是 `weight 0 autoout`）：
   - `sudo ceph osd in osd.0 osd.2`
   - 若被 noout/norebalance 等标志影响，检查 `ceph osd dump | grep flags`。

3. **原地激活/拉起 down 的 OSD**（无损，二选一，优先 orch）：
   - 优先：`sudo ceph orch daemon start osd.0`（及 osd.2/6/7）。
   - 若 orch 不生效（duplicate 未清干净），在对应节点用 `sudo ceph-volume lvm activate --all` 或 `sudo ceph-volume lvm activate <osd_id> <osd_fsid>`（fsid 见上表）拉起——**activate 是无损的，只挂载现有 LV，不格式化**。
   - 严禁 `ceph-volume lvm create` / `prepare` / `zap`。

4. **等待恢复完成**：观察 `ceph -s` 直到 **HEALTH_OK + 全部 PG active+clean**（33 PG 从 down → active+clean，backfill/recovery 跑完）。

5. **数据完整性冒烟**（sunrise 身份，非 sudo）：
   - `rados -p juicefs-data df` 看 objects 数（应回到 A/B 组时的量级，约 425k objects / 104GiB）。
   - dd 读一个整文件 + 一个中段 512M，确认可读。

6. **报告 analyst**：`ceph -s` + `ceph osd tree` + `ceph orch ps --daemon-type osd`（确认无 duplicate）+ `rados -p juicefs-data df` + 冒烟结果。**analyst 确认布局与 A/B 组一致、无 duplicate、HEALTH_OK 后放行阶段 B。**

---

## 三、阶段 B：C 组从头重跑 10 轮

> 用户决策：C-1~C-6 虽数据本身有效，但跑于集群异常窗口，为纯净起见**全部弃用，C 组从头重跑 10 轮**。旧 C-1~C-7 数据目录保留存档但不参与分析。

- 完全按 `lcnvme-attribution-experiment-instructions-20260727.md` 的 **C 组定义**执行：每轮 `sudo podman restart` 所有 up 的 NVMe OSD 容器（osd.0/1/2/3/6/7），**不 destroy/purge/format/重挂/重写 layout**。
- **★★ 每轮 restart 后，必须等 `ceph -s` 回到全部 up+in+active+clean 再跑 fio。**（这正是 C-7 出事的教训——restart 后不确认健康就继续会累积问题。）
- **★ runtime=180 不得改小**（60s 会被 restart 恢复期污染，见方法论前置）。
- **★ 交付全部 128 个逐秒 bw_log**，analyst 用稳态中位数评估。
- 每轮 randread 前采 `ceph pg dump pgs_brief > pg-map.txt`。
- 结果目录：`/tmp/opencode-lcnvme-verify/C/C-{1..10}/`（**先把旧的 C-1~C-7 移到 `C_aborted/` 存档**，避免混淆）。

**⚠️ 防 cephadm duplicate 复发**：C 组是唯一反复 restart OSD 的组，最可能再触发上次的 duplicate 删容器。建议在开跑前确认 `ceph orch ps` 已无 duplicate；若跑 C 组期间 cephadm agent 再删容器，**停下报告 analyst**，不要在 degraded 状态下继续跑或自行重建。

---

## 四、阶段 C：D 组 10 轮

- C 组 10 轮完成、集群 HEALTH_OK 后，按原指令 **D 组定义**执行：每轮完整 soft-clean（destroy+purge+OSD restart+format+layout=B+C 组合）。
- 同样 runtime=180、128 bw_log、每轮 pg-map、restart 后等 active+clean 再跑 fio。
- 结果目录：`/tmp/opencode-lcnvme-verify/D/D-{1..10}/`。

---

## 五、交付

四组（A 已完成 10 轮 / B 已完成 10 轮 / C 重跑 10 轮 / D 10 轮）全部完成后，打包路径告知 analyst。analyst 按原指令阶段 3 做稳态 CV、缺口归因（D vs B+C）、primary Spearman、双峰确认、基线口径。

---

## 六、本次红线汇总
1. ⛔ 严禁 purge/zap/destroy/重建 OSD——只允许无损 activate。
2. 对任何"该不该删这条记录/该不该动这块盘"不确定 → 停下报告，不要猜。
3. C/D 每轮 OSD restart 后必须等 HEALTH_OK+active+clean 再跑 fio。
4. runtime=180 不得改小；交付 128 bw_log；每轮采 pg-map。
5. 不改 EC/pool/crush/fio 核心/JuiceFS 挂载等控制变量。
6. 旧 C-1~C-7 移入 `C_aborted/` 存档，不参与分析。
