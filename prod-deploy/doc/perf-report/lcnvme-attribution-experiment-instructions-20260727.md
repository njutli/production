# GLM 执行指令：NVMe 集群 randread 波动完整归因实验（LC-NVMe）

> 来源：analyst `/tmp/bridge/analysis.md` §-MEMDISK / §-LOCATE（LC.8-LC.11）。
> 前序结论：brd 内存盘上 randread 轮间 CV ~10%（稳态口径复核确认为真实，非采样伪影）。LC 拆解出 B(数据布局) 3.7% + C(OSD重启) 3.8%，叠加仅 ~5%，**解释不了 M 组 9.5% 的全部波动，缺口 ~5% 待坐实**。
> 本实验目标：在 NVMe 生产介质、干净集群、足够轮数下，**完整归因 randread 轮间波动**，坐实那 ~5% 缺口来自何处，产出可复现的稳定基线口径。

---

## 零、平台与授权

- **平台**：NVMe 集群（生产真实介质，双峰特征明显）。GLM 正在重建 NVMe osd 0-5（已 marked lost）+ 重灌 128GiB。
- **⛔ 内存盘(brd)实验到此为止**（上一轮 OOM，风险失控）。本实验全程在 NVMe，禁止再用 brd。
- **授权**：环境/bug 修复可自主但**须报告**；**禁止擅改控制变量**（EC profile / pool 参数 / crush rule / fio 的 bs·iodepth·numjobs·direct·rw / JuiceFS 挂载参数）。遇到需改控制变量、或阶段前置验证失败 —— **停下报告 analyst**。

---

## 一、致命方法论前置（上一轮教训，务必遵守）

> 上一轮 LC 的 C 组数据全废，根因=**GLM 把 runtime 改成 60s，OSD restart 后前 ~15s 恢复期占了 25% 采样窗口，把 fio 平均带宽人为拉低 ~25%**，造出"restart 导致带宽衰减"的假象。真相是稳态带宽根本没降。

**本实验强制规则：**
1. **runtime = 180s**（不得改小）。给 OSD restart 后的恢复期留足够小的占比。
2. **交付逐秒 bw_log**（`--write_bw_log` + `--log_avg_msec=1000`），且**必须保留全部 128 个 job 的 bw log**。analyst 一律用**稳态中位数**（截掉每轮前 15 秒预热/恢复段后取逐秒总带宽中位数）评估，**不看 fio 的 group_reporting 平均值**。
3. 凡涉及 OSD restart 的轮次，**确认 restart 后 PG 全部 active+clean 再开始 fio**（不能在 recovery 进行中跑）。

---

## 二、阶段 0：集群就绪（须报告后放行）

1. 完成 NVMe osd 0-5 重建 + pool 重建（EC 4+2 profile ec-prod、failure-domain=osd）+ JuiceFS format + 重灌 128×1G。
2. 确认 **HEALTH_OK + 所有 PG active+clean**（无 degraded/undersized/recovery）。
3. 冒烟：sunrise 身份 dd 读一个整文件 + 一个中段随机 512M，确认数据完整可读。
4. **报告** `ceph -s` + `ceph osd tree` + `rados -p juicefs-data df`（objects 数）+ 冒烟结果，analyst 确认后放行阶段 1。

---

## 三、阶段 1：前置技术验证（同上轮，NVMe 上重新确认）

- **NVMe 上 OSD 容器重启后数据保留**（NVMe 是持久盘，预期保留，但仍确认一次）：记 `rados df` objects → `podman restart` 一个 osd → 等 up+in+active+clean → 再看 objects 不变。用于确认 C 组"纯重启不重灌"可行。
- 若异常，停下报告。

---

## 四、阶段 2：四组对照实验（每组 10 轮 × randread 180s×1）

### 4.1 通用规则（四组一致）
- 每轮结构：`[组特定操作] → 等 PG active+clean → drop_caches(三节点) → 采 pg-map → randread 180s×1`
- **每轮 randread 前采 PG 映射**（埋点）：
  ```
  sudo ceph pg dump pgs_brief 2>/dev/null > <resultdir>/<组>-<轮>/pg-map.txt
  ```
- **randread fio 参数（逐字复刻，仅确认 runtime=180，其余一字不改）**：
  ```
  fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=128 --group_reporting \
      --time_based --runtime=180 --write_bw_log=<bwdir>/<组>-<轮>_bw --log_avg_msec=1000
  ```
- drop_caches 每轮已控（非变量），保留。
- 结果目录：`/tmp/opencode-lcnvme-verify/<组>/<组>-<轮>/`（沿用原结构：fio.txt + pg-map.txt + 128 个 *_bw.N.log + osd/node-*.csv + load-monitor.csv）。
- 采集器若仍有 osd-perf / OSD-ID 解析 bug（历史报告记录过），修复它（bug 可自主修，报告即可）。

### 4.2 四组定义

| 组 | 每轮之间的操作 | 变量 | 固定 | 轮数 |
|---|---|---|---|---|
| **A** 连续基线 | 什么都不做（挂载一次连续跑） | 无（对照锚，预期 CV~0.5%） | 一切 | 10 |
| **B** 只重灌数据 | `fusermount -u` → `juicefs destroy` → `rados purge` → `juicefs format --force` → mount → **layout 重写 128×1G**。**不重启 OSD** | 数据物理布局 | OSD 进程/primary 映射 | 10 |
| **C** 只重启 OSD | 仅 `sudo podman restart` 所有 up 的 NVMe OSD 容器，等全部 up+in+active+clean。**不 destroy / purge / format / 重挂 / 重写 layout** | OSD 进程重启（primary 重选举） | 数据物理布局 | 10 |
| **D** 完整 soft-clean | B + C 一起做（= M1-M10 的 soft_clean_restart 全流程：destroy+purge+OSD restart+format+layout） | 布局 + 重启 组合 | — | 10 |

- **A/B/C/D 顺序执行**，每组独立起止。A、C、D 首轮前各正常挂载+layout 一次（A/C 之后不再重灌，D 每轮重灌）。
- **⚠️ 关键：D 组直接实测"完整 soft-clean 的组合 CV"**，与 B、C 单独 CV 对照 → 无需再依赖旧 brd M 数据即可回答"B+C 叠加 vs 组合"的缺口问题。

### 4.3 时间预算
每组 10 轮 × (180s randread + 操作开销 ~1-2min) ≈ 40-50min/组 × 4 组 ≈ **3-3.5h**。用户已批准不限时。

---

## 五、阶段 3：交付 analyst 分析

每组每轮产出：`fio.txt` + `pg-map.txt` + 128 个逐秒 `*_bw.N.log` + `osd/node-*.csv` + `load-monitor.csv`。跑完打包路径告知 analyst。analyst 做：

1. **稳态口径 CV**：每轮 128 job 逐秒 bw 求和成集群总带宽序列，截前 15s 取中位数，算四组各自轮间 CV（A/B/C/D）。
2. **缺口归因**（核心）：
   - 若 **D ≈ B+C 线性叠加** → 波动=布局+重启两个独立源，无额外缺口（推翻旧 brd 的缺口，归因于旧 M 期集群 recovery 或样本少）。
   - 若 **D ≫ B+C** → 存在真实的 B×C 交叉耦合效应 → 坐实缺口来源=组合效应。
   - 对比 D 组 CV 与旧 brd M 组 9.5%，看 NVMe 是否复现 ~10%（介质无关性验证）。
3. **primary 相关性**：每轮 pg-map 算 primary 在 6 OSD 上分布的均衡度（stdev/Gini）vs 该轮稳态 BW 做 Spearman → 坐实/证伪"PG primary 分布"对带宽的影响（预期弱，因 C 稳态 CV 不高）。
4. **双峰确认**：NVMe D 组是否复现 brd 上消失的双峰（好~1466-1497 / 坏~1287-1307）。
5. **产出稳定基线口径**：确定 randead 可复现基线（单轮稳态中位数是否可用，还是须 N 轮均值），供后续调优验证提速。

---

## 六、禁止事项（红线）
- 不改 EC profile / pool 参数 / crush rule。
- 不改 fio 的 bs / iodepth / numjobs / direct / rw（**runtime 必须 =180，不得再改小**）。
- 不改 JuiceFS 挂载参数（max-uploads 150 / cache-size 0 / block 256K）。
- 不在 recovery/degraded 状态下跑 fio。
- 不用内存盘。
- 遇到需改上述任一控制变量、或阶段 1 前置验证失败 —— **停下，报告 analyst**。
