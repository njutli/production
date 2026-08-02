# GLM 执行指令：soft-clean 波动源定位实验（LC 实验）

> 来源：analyst 分析 `/tmp/bridge/analysis.md` §-MEMDISK / §-LOCATE。
> 目标：坐实 soft-clean 中**哪一步**引入了 randread "整轮 BW 锁定在不同值"的波动（当前 brd 轮间 CV~10%，轮内<1.5%，93% 变异在 soft-clean 之间）。
> 授权口径：环境修复/bug 修复可自主但**须报告**；**禁止擅改控制变量**（EC 参数、pool、fio 的 bs/iodepth/numjobs/direct、JuiceFS 挂载参数）。runtime 60s 与 pg dump 埋点是本实验唯一经用户批准的口径变更。

---

## 阶段 0：环境修复（须先做，恢复到 HEALTH_OK 再开测）

当前 brd 集群（150 实测 2026-07-27）=HEALTH_WARN，不能开测，否则恢复流量污染结论。请依次处理并**报告结果**：

1. **修时钟偏移**：`mon.ceph-node2 clock skew 0.0575s > 0.05s`。三节点同步时钟（chrony/ntp，或临时 `sudo chronyc makestep`）。
2. **清理 down 空壳 OSD**：`osd 6/7/9/11` 为 down、weight0 空壳（重建 brd OSD 遗留），会干扰 CRUSH。用 `ceph osd purge <id> --yes-i-really-mean-it` 逐个清除（先确认它们确实无数据、非当前 up 的 8/10/12/13/14/15）。
   - 旧 NVMe `osd 0-5` 已 marked lost，保持 down 即可，本实验不碰。
3. **等 PG 恢复干净**：当前 5 PG stuck undersized/degraded（acting 含 NONE）。清完空壳 OSD 后应能补齐。等到 `ceph -s` = **HEALTH_OK + 33 PG 全 active+clean**。
4. **报告**：贴出修复后 `ceph -s` + `ceph osd tree`，analyst 确认 up OSD 集合（预期 6 个 brd OSD 全 up+in）后再进阶段 1。

---

## 阶段 1：前置技术验证（决定 C 组是否可行，务必先测）

**关键未知**：C 组要"只重启 OSD、不重灌数据"。但 brd 是内存盘（ram0/ram1），**需确认 podman restart OSD 容器后，brd 上的 BlueStore 数据是否保留**。
- 做法：记下当前 `rados -p juicefs-data df`（objects 数），对**一个** brd OSD 容器 `sudo podman restart <osd容器>`，等其 up+in，再看 objects 数与 PG 状态。
- **若数据保留**（brd 是独立块设备、容器重启不清空）→ C 组可行，按下方执行。
- **若数据丢失**（重启后 OSD 空/需 backfill）→ C 组无法"纯重启"，**停下报告 analyst 改设计**（改为对照"重启触发 backfill 后 primary 变化"）。

---

## 阶段 2：三组对照实验（每组 5 轮 × randread 60s×1）

### 通用规则（三组一致）
- 每轮结构：`[组特定操作] → drop_caches → 采 pg-map → layout(若需) → randread 60s×1`。
- **每轮 randread 前采 PG 映射**（新增埋点）：
  ```
  sudo ceph pg dump pgs_brief 2>/dev/null > <resultdir>/<组>-<轮>/pg-map.txt
  ```
- randread fio 参数（**仅 runtime 改 60，其余逐字复刻**）：
  ```
  fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=128 --group_reporting \
      --time_based --runtime=60 --write_bw_log=<bwdir>/... --log_avg_msec=1000
  ```
- 复用现有 `run_fio`（含 drop_caches + 采集器 + bw_log 收集）；采集器 osd-monitor-brd.sh 若仍有后台 OSD-ID 解析 bug（报告§2.3），修复它（这是 bug，可自主修，报告即可）。
- 结果目录：`/tmp/opencode-lc-verify/<组>/<组>-<轮>/`（与原 verify 同结构，便于 analyst 复用分析脚本）。

### A 组 —— 连续基线（2 轮足够，确认"不动就稳"）
- 挂载一次，**不做任何 soft-clean**，连续跑 2 轮 randread（A-1, A-2）。
- 预期 CV ~0.5%（已知，仅作在位复核 + 作 B/C 的对照锚）。

### B 组 —— 只重灌数据（5 轮）
- 每轮之间：`fusermount -u` → `juicefs destroy` → `rados purge` → **`juicefs format --force`** → `mount` → **layout 重写 128×1G** → randread。
- **不重启任何 OSD**（跳过 podman restart OSD 那段）。
- 变量=数据物理布局（object 落点/PG 数据分布每轮新建）；固定=OSD 进程/primary 映射不变。

### C 组 —— 只重启 OSD（5 轮）
> 仅当阶段 1 验证"brd 数据在容器重启后保留"才执行。
- 每轮之间：**仅** `sudo podman restart <所有 up 的 brd OSD 容器>`（150/151/152 各 2 个），等全部 up+in + PG active+clean。
- **不 destroy、不 purge、不 format、不重挂 JuiceFS、不重写 layout**（数据保持不变）。
- 首轮前正常挂载 + layout 一次；之后每轮只重启 OSD。
- 变量=OSD 进程重启（触发 PG primary 重选举）；固定=数据物理布局不变。

---

## 阶段 3：交付给 analyst
每组每轮产出：`fio.txt`（BW）+ `pg-map.txt`（PG acting/primary）+ `osd/node-*.csv` + bw_log。跑完打包路径告知 analyst，analyst 做：
1. 三组各自轮间 CV（A vs B vs C）。
2. 判读（LC.4）：
   - **C 炸(CV~10%) + B 不炸(CV~2%)** → 主因=OSD restart 的 PG primary 重分布 → 解法：钉死 primary（primary-affinity / pg-upmap-primary），单轮可当基线。
   - **B 炸 + C 不炸** → 主因=数据物理布局 → 解法：改用不删数据的清理。
   - 都炸 → 分别量化；都不炸 → 主因是 rados purge，单独测。
3. pg-map 佐证：每轮 primary 在 6 OSD 分布的 stdev/Gini vs 该轮 BW 做 Spearman。

---

## 时间预算
阶段0 修复 ~30min；阶段1 验证 ~15min；阶段2 三组≈ A(2轮×4min) + B(5轮×~5min含layout) + C(5轮×~4min) ≈ **~1.5-2h**。总计半天内。

## 禁止事项
- 不改 EC profile / pool 参数 / crush rule。
- 不改 fio 的 bs/iodepth/numjobs/direct/rw（仅 runtime=60）。
- 不改 JuiceFS 挂载参数（max-uploads 150 / cache-size 0 / block 256K）。
- 遇到需要改上述任一控制变量、或阶段1 发现 C 组不可行时——**停下，报告 analyst**。
