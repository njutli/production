# Stable-ID 重建 Skill（规范重建路线 + 全量重建 + 问题库）

> 定位：**给 AI 自己用的操作手册**。每次重建 OSD/集群时加载本 skill，避免重复踩坑。
> 分工：
> - **本文件** = 规范重建路线（`destroy` + `auth rm` + `ceph-volume lvm` 复用现有 LV，保 OSD ID 0-5 / 不删 pool）+ 半损坏后的全量重建步骤 + 完整问题库。
> - **`cluster-rebuild-skill.md`** = 分层诊断 + 止血恢复（集群半损坏时先去那里定位）。
> 相关文件：`scripts/tests/rebuild-stable-ids.sh`（固化脚本）、`/tmp/cleanup-node.sh`（节点清理，仅在必须重做 LVM 时用）。

---

## 一、为什么用 Stable-ID 重建（destroy 派，非 purge）

| 方式 | OSD ID | pool_id | CRUSH 映射 | 跨重建漂移 | 适用 |
|------|--------|---------|-----------|-----------|------|
| purge + pool recreate（旧路线，弃用） | 变 | 变 | 全变(32/32 PG) | ±16~37% | 仅模拟冷装机/末位兜底 |
| **destroy + ceph-volume 复用现有 LV** | **不变** | **不变** | **不变** | 目标 <5% | **调优基线复现（默认）** |
| soft-clean（不重建） | 不变 | 不变 | 不变 | 会话内可复现 | 轮间清理 A→B 切换 |

> 因果依据：`doc/perf-report/00-baseline-20260723.md` §九（重建=随机源1）、§9.6（pool delete+recreate=随机源2）。
> ⚑ purge + 删 pool 同时踩两个随机源，**与稳定复现目标自相矛盾**，仅在 destroy 路线实测彻底走不通、且已报告获准"重标基线"时作兜底。

---

## 二、规范重建步骤（stable-ID，保 pool_id，~15min）

```
1. 停 OSD：systemctl reset-failed + stop（+ 必要时 mask；不能只 pkill，systemd 会自动重启）→ 确认 pgrep 无残留
2. down + destroy：ceph osd down <id> → ceph osd destroy <id> --yes-i-really-mean-it
3. 验证 destroyed：ceph osd info <id> | grep destroyed（关键！up 状态下 destroy 不生效）
4. ⚑ 删旧 auth key：ceph auth rm osd.<id>   ← 解决 PG unknown 的关键（问题 5）
5. 复用现有 LV（不 zap）：
   - LV 带 ceph tag → ceph-volume lvm activate --all
   - LV 存在但 tag 空 → ceph-volume lvm prepare 传【现有 LV 路径】+ activate（问题 7）
   - 仅当 LV 真损坏才 cleanup-node.sh 重做 LVM（末位）
6. Start OSDs + 等 PG active+clean（保留业务 pool，不 delete）
7. soft-clean 清 pool 对象：juicefs destroy（保 pool_id）+ compact 到 queue_len=0 + drop_caches
```

LV ↔ OSD 映射（3 节点 × 2 OSD）：
| OSD | 节点 | data | db | wal |
|---|---|---|---|---|
| osd.0 | 150 | ceph-vg-osd1/osd | ceph-vg-db1/osd-db | ceph-vg-wal1/osd-wal |
| osd.1 | 150 | ceph-vg-osd2/osd | ceph-vg-db2/osd-db | ceph-vg-wal2/osd-wal |
| osd.2 | 151 | ceph-vg-osd3/osd | ceph-vg-db3/osd-db | ceph-vg-wal3/osd-wal |
| osd.3 | 151 | ceph-vg-osd4/osd | ceph-vg-db4/osd-db | ceph-vg-wal4/osd-wal |
| osd.4 | 152 | ceph-vg-osd5/osd | ceph-vg-db5/osd-db | ceph-vg-wal5/osd-wal |
| osd.5 | 152 | ceph-vg-osd6/osd | ceph-vg-db6/osd-db | ceph-vg-wal6/osd-wal |

---

## 三、半损坏后的全量重建（8 步，~45min）

> 触发：集群大面积上层元数据缺失（mgr auth / ec profile / crush rule 丢、OSD 未 activate、残留 osd.6/7）。**磁盘/LV 通常完好，不必重做 LVM。** 先用 `cluster-rebuild-skill.md` §二分层确认。

### 步骤 0：清残留（osd.6/7 + 僵死 mgr）
```bash
for id in 6 7 8 9; do
  sudo systemctl disable --now ceph-osd@$id 2>/dev/null; sudo systemctl reset-failed ceph-osd@$id 2>/dev/null
  sudo rm -rf /var/lib/ceph/osd/ceph-$id 2>/dev/null
done
sudo ceph osd rm 6 7 8 9 2>/dev/null; sudo ceph osd crush rm osd.6 2>/dev/null
```
✅ `ceph osd tree` 只剩 0-5。

### 步骤 1：停所有 OSD
```bash
for id in 0 1 2 3 4 5; do sudo systemctl reset-failed ceph-osd@$id 2>/dev/null; sudo systemctl stop ceph-osd@$id 2>/dev/null; done
pgrep ceph-osd && echo STILL_RUNNING || echo ALL_STOPPED
```

### 步骤 2：down + destroy + 删旧 auth key
```bash
for id in 0 1 2 3 4 5; do sudo ceph osd down $id 2>/dev/null; done; sleep 5
for id in 0 1 2 3 4 5; do sudo ceph osd destroy $id --yes-i-really-mean-it 2>/dev/null; done
for id in 0 1 2 3 4 5; do sudo ceph auth rm osd.$id 2>/dev/null; done
```
✅ `ceph osd info <id> | grep destroyed`；`ceph auth ls | grep 'osd\.'` 为空。

### 步骤 3：复用现有 LV（**不 zap、不重做 LVM**）—— 见问题 7
```bash
for id in 0 1 2 3 4 5; do sudo systemctl unmask ceph-osd@$id 2>/dev/null; done
# 情况 A：LV 带 tag
sudo ceph-volume lvm activate --all 2>&1 | tail -20
# 情况 B：LV 存在但 tag 空 → lvm prepare 传现有 LV 路径（逐个 OSD，见问题 7 命令）
```
✅ 每节点 `ls /var/lib/ceph/osd/ceph-*/block` 存在；`systemctl is-active ceph-osd@<id>`=active。

### 步骤 4：救活 mgr（无 active mgr 时 up_thru 不推进）
```bash
FSID=4f4e3ca0-8297-11f1-a671-97520597268c
sudo ceph auth import -i /var/lib/ceph/${FSID}/mgr.ceph-node1.zrdrjl/keyring
sudo systemctl restart ceph-${FSID}@mgr.ceph-node1.zrdrjl 2>/dev/null || \
  sudo podman restart $(sudo podman ps -a --format '{{.Names}}' | grep mgr-ceph-node1)
sleep 10; sudo ceph mgr dump | grep active_name
```
✅ `ceph -s` mgr 行 `active`。

### 步骤 5：等 OSD up + osdmap 推进
```bash
for id in 0 1 2 3 4 5; do sudo systemctl start ceph-osd@$id 2>/dev/null; done
sleep 30; sudo ceph osd stat; sudo ceph osd dump | grep up_thru | grep -c 'up_thru 0'
```
✅ `6 up, 6 in`；`up_thru 0` 计数=0。

### 步骤 6：重建 EC profile + crush rule（若已丢）
```bash
sudo ceph osd erasure-code-profile set ec-prod k=4 m=2 crush-failure-domain=osd crush-device-class=ssd --force
sudo ceph osd erasure-code-profile get ec-prod
```
✅ `ceph osd erasure-code-profile ls` 含 ec-prod。

### 步骤 7：建 pool（PG active+clean 后）
```bash
sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod
sudo ceph osd pool set juicefs-data allow_ec_overwrites true
sudo ceph osd pool set juicefs-data fast_read true
sudo ceph osd pool application enable juicefs-data juicefs
sudo ceph osd pool set juicefs-data pg_autoscale_mode off
sleep 15; sudo ceph -s | grep -E 'pgs:|health'
```
✅ `pgs: 32 active+clean`。

### 步骤 8：157 客户端 keyring + 收尾
```bash
sudo ceph auth get-or-create client.juicefs mon 'allow r' osd 'allow rwx pool=juicefs-data'
sudo ceph auth get client.juicefs | sudo tee /etc/ceph/ceph.client.juicefs.keyring
sudo chmod 644 /etc/ceph/ceph.client.juicefs.keyring   # 非 root 的 juicefs 要读（问题 9）
sudo ceph config set mon auth_allow_insecure_global_id_reclaim false 2>/dev/null || true
```

---

## 四、已知问题与解决方案

### 问题 1：`pkill -9 ceph-osd` 后 systemd 自动重启
`ceph-volume lvm create/activate` 成功后 enable+start 的 `ceph-osd@<id>` 服务 `Restart=always`，`pkill` 只杀进程不停服务。
**解决**：先 mask/stop 再操作：
```bash
for id in $(systemctl list-units 'ceph-osd@*' --no-legend | grep -oP 'osd@\K[0-9]+'); do
  sudo systemctl mask ceph-osd@$id; sudo systemctl stop ceph-osd@$id
done
sudo pkill -9 ceph-osd; sleep 3; pgrep ceph-osd && echo STILL_RUNNING || echo ALL_STOPPED
```
**首次遇到**：2026-07-22

### 问题 2：`ceph osd destroy` 对 up 的 OSD 不设 `destroyed` 标志
destroy 需 OSD 先 down；up 状态下虽返回成功但标志没设 → `ceph-volume ... --osd-id` 报 `already in use or does not exist`。
**解决**：mask+stop → `ceph osd down` → `ceph osd destroy` → 验证 `ceph osd info <id> | grep destroyed`。
**flag 注意**：destroy 用 `--yes-i-really-mean-it`（3 really）；pool delete 用 `--yes-i-really-really-mean-it`（4 really）。
**首次遇到**：2026-07-22

### 问题 3：`ceph osd crush get osd.X` 返回 "not in crush"（误读）
它返回的是 crush location 路径，不是"是否在 crush map"。判断在不在看 `ceph osd tree`。非问题。
**首次遇到**：2026-07-22

### 问题 4：LVM 创建静默失败（仅在必须重做 LVM 时相关）
`cleanup-node.sh` 未彻底清 loop/PV → `vgcreate` 失败，脚本 `2>/dev/null || true` 吞错继续 → `ceph-volume lvm create` 报 IO error。
**解决**：重做 LVM 后**必须验证**每节点 6 个 LV（2×osd + 2×db + 2×wal），缺则手动重做该节点。
> ⚑ 但默认路线**不重做 LVM**（复用现有 LV，见问题 7），本问题只在 LV 真损坏时相关。
**首次遇到**：2026-07-23

### 问题 5：`ceph osd destroy` 保留旧 auth key → OSD 无法 beacon → PG 卡 unknown
> **⚑ 2026-07-23 纠正**：当初"改用 purge + 删 pool"的结论是错的（引入两个随机源）。**正解 = destroy 后先 `ceph auth rm osd.<id>` 再 activate/create**（新 key 无冲突即可注册）→ beacon 正常，pool_id 不变。当初只试了 `ceph auth add`（方向错），漏了先 `auth rm`。
现象：destroy+create 后所有 PG `unknown`、`up_thru=0`。
```bash
for id in 0 1 2 3 4 5; do sudo ceph auth rm osd.$id 2>/dev/null; done
sudo ceph-volume lvm activate --all   # 或 prepare（问题7）
sudo systemctl restart ceph-osd@<id>
sudo ceph osd dump | grep "osd.<id>"  # up_thru 非 0
```
~~旧错误结论：改 purge 替代 destroy → 删 pool 重建~~（已废弃，仅末位兜底，须先报告）。
**首次遇到**：2026-07-23　**纠正**：2026-07-23

### 问题 6：purge 后旧 pool PGMap 卡 unknown（仅 purge 路线相关）
purge 删 OSD 后旧 PGMap 指向已删 OSD UUID → 不兼容 → 必须删 pool 重建 → **pool_id 变**。这正是不用 purge 的原因。默认走问题 5 的 destroy+auth rm。
**首次遇到**：2026-07-23

### 问题 7：⚑ LV 存在但缺 ceph tag → activate 找不到；此时禁 zap / 禁裸盘 create / 禁手动 mkfs
> 2026-07-23 晚验证。destroy 会清 LV 的 `lv_tags`，但 LV/VG/PV 本身完好。activate 靠 tag 找 OSD，tag 空就"找不到"。**这不是"必须重做 LVM"。**

**现象**：`ceph-volume lvm activate --all` 找不到 osd.1-5；`lvs -o lv_tags` 显示这些 LV tag 空（osd.0 的在）。曾误走：`lvm create/prepare` 传裸盘触发 `zap` 破坏 loop PV；转手动 `ceph-osd --mkfs` 报 `fsck found fatal error: No such file or directory`，卡约 4h。

**根因**：① destroy 清 tag → activate 找不到（唯一真障碍）；② 传裸设备给 `lvm create/prepare` 会先 `zap` → 擦 loop PV 元数据（"LVM 反复消失"真凶）；③ 手动 `--mkfs` 缺 `osd new`/block 软链/monmap 上下文 → fsck fatal。

**✅ 正解**：`ceph-volume lvm prepare` 传**已存在的 LV 路径**（不是裸盘）→ 只重打 tag + mkfs，**不 zap**：
```bash
sudo lvs -o lv_name,vg_name,lv_tags        # 先核对，不新建/删除任何 LV
# 以 osd.1（节点150）为例，逐个 OSD：
sudo ceph-volume lvm prepare --bluestore \
  --data ceph-vg-osd2/osd --block.db ceph-vg-db2/osd-db --block.wal ceph-vg-wal2/osd-wal \
  --crush-device-class ssd --osd-id 1
sudo ceph-volume lvm activate --all
```
LV↔OSD 映射见 §二表。

**🔴 绝对禁止**：`ceph-volume lvm zap`、裸设备 `lvm create`、手动 `ceph-osd --mkfs`。若连"传现有 LV 的 prepare"都因旧 bluestore 残留想 zap → **停下报告**，再考虑 `dd if=/dev/zero of=/dev/ceph-vg-osdN/osd bs=1M count=100`（只碰 LV 不碰 PV）+ prepare，动数据前须经人工确认。
**首次遇到**：2026-07-23

### 问题 8：`ceph orch daemon rm --force` 删 auth key（仅 orch 路线，历史）
orch 派已弃用。若历史环境遇到：从 `/var/lib/ceph/osd/ceph-X/keyring` 读 key 手动 `ceph auth add osd.X`（caps: mgr/mon `allow profile osd`、osd `allow *`）。默认路线不用 orch，见问题 5。
**首次遇到**：2026-07-22

### 问题 9：JuiceFS mount 报 "Permission denied" (rados ret=-13)
keyring 权限 600 → 非 root 的 juicefs 读不到。**解决**：`chmod 644` keyring（测试环境无风险）。
**首次遇到**：2026-07-22

### 问题 10：.mgr pool PG stuck stale+down（历史，重建后偶发）
OSD 重建后旧 .mgr PG 指向已销毁 OSD。**解决**：删 .mgr pool + `ceph mgr fail`，cephadm 自动重建。
```bash
sudo ceph config set mon mon_allow_pool_delete true
sudo ceph osd pool delete .mgr .mgr --yes-i-really-really-mean-it
sudo ceph mgr fail; sleep 30
```
**首次遇到**：2026-07-22

---

## 五、重建后验证清单
```bash
sudo ceph -s | grep -E 'health|mgr:|osd:|pgs:'   # mgr active；6 up；32 active+clean
sudo ceph osd ls                                 # 0 1 2 3 4 5（stable-ID）
sudo ceph osd dump | grep up_thru | grep -c 'up_thru 0'   # =0
sudo ceph osd erasure-code-profile get ec-prod   # k=4 m=2 osd
sudo ceph osd pool get juicefs-data fast_read    # fast_read: 1
sudo rados df --format json | python3 -c "import sys,json;print([p['num_objects'] for p in json.load(sys.stdin)['pools']])"  # ≈0
sudo ceph auth get client.juicefs                # key + caps
```
OSD uptime 应 <1800s、`df -h /mnt/dbwal` 占用低（fresh BlueStore）。

---

## 六、耗时参考 & 纪律
| 场景 | 目标 |
|------|------|
| stable-ID 重建（§二，复用 LV） | ~15min |
| 半损坏全量重建（§三 8 步） | ~45min |

- 任一步卡 >20min 或反复重试同操作 → **停下报告**（分层授权，02-2-G §四b）。
- **禁 zap / 禁裸盘 create / 禁手动 mkfs**（问题 7）；LV 完好就复用。
- **禁 purge+删 pool 旧路**（改 pool_id，破坏 stable-ID）；auth 问题用 `auth rm`（问题 5）。
- 改控制变量前必须报告；全程只碰 slave(150-152)，不动 157 WekaIO。

---

## 七、更新日志
| 日期 | 内容 |
|------|------|
| 2026-07-23 | 初始：destroy+ceph-volume --osd-id stable-ID 重建 + 问题 1-6 |
| 2026-07-23 晚 | 新增问题 7（LV 缺 tag → lvm prepare 复用现有 LV，禁 zap/裸盘 create/手动 mkfs）|
| 2026-07-23 晚 | 重构合并：吸收 cluster-full-rebuild-guide 的 §三全量重建 8 步（含救 mgr / 重建 ec profile / 建 pool）；并入 orch 路线残留问题 8-10（标历史）；§一把 purge 路线弃用为兜底 |
