# 集群恢复 + 分层诊断 Skill

> 定位：**给 AI 自己用的操作手册**。集群"半损坏 / PG unknown / OSD 起不来"时，先加载本 skill 分层定位，再对症止血。**不盲目全量重建。**
> 与 `stable-rebuild-skill.md` 的分工：
> - **本文件** = 诊断 + 恢复（止血让集群回到可用）。
> - **`stable-rebuild-skill.md`** = 规范重建路线（destroy + auth rm + lvm 复用现有 LV）+ 全量重建步骤 + 完整问题库。
> 相关文件：`scripts/tests/rebuild-stable-ids.sh`、`scripts/rebuild-osds.sh`（旧 orch 全量脚本，仅历史）、`/tmp/cleanup-node.sh`。
>
> ⚑ 历史更正：本文件旧版是"orch + purge"全量重建路线，已被否定（purge 改 OSD 身份、删 pool 改 pool_id = 两个已证随机源，破坏 stable-ID 复现）。旧路线仅作历史/末位兜底，见 §五。

---

## 一、环境概要

| 组件 | 配置 |
|------|------|
| Ceph | 17.2.8 quincy, FSID=4f4e3ca0-8297-11f1-a671-97520597268c |
| 节点 | 3 storage (150/151/152) + 1 client (157) |
| OSD | 6 OSD (3节点×2 NVMe: nvme2n1 + nvme3n1), DB/WAL on tmpfs /mnt/dbwal 200G |
| EC | ec-prod k=4 m=2, failure-domain=osd, fast_read=true, allow_ec_overwrites=true |
| pool | juicefs-data, autoscaler off |
| TiKV | 150/151/152 3副本 |
| auth | mon+osd auth_*_required=none（测试集群） |
| SSH | opencode 侧只读诊断经 thailand→157→150-152；GLM 在能直连 slave 环境执行修复 |

---

## 二、先分层定位（不要盲目重建）

按顺序在 slave（如 10.20.1.150，用户 sunrise）执行：
```bash
sudo ceph -s                                   # health / osd up 数 / pgs / mgr 行
sudo ceph osd tree                             # OSD 是否在树、是否 up、ID 0-5
sudo ceph osd dump | grep -E '^osd|up_thru'    # up_thru=0 表示从未 beacon 成功
sudo ceph pg stat                              # active+clean / unknown / peering
sudo ceph auth ls | grep 'osd\.'               # OSD auth key 是否存在
sudo ceph mgr dump | grep active_name          # 有无 active mgr
sudo ceph osd erasure-code-profile ls          # ec-prod 是否还在
sudo lvs -o lv_name,vg_name,lv_tags            # LV 是否在、是否带 ceph tag
```

对照下表**先确定层级，再对症**：

| 症状 | 层级 | 去哪 |
|------|------|------|
| OSD 进程起不来 / systemctl 反复重启 | 进程/systemd | §三.A |
| 无 active mgr（`no daemons active`） | mgr auth key 丢 | §三.B |
| OSD up 但 `up_thru=0`、PG `unknown` | **auth key 不匹配（最常见）** | §三.C |
| `lvm activate` 找不到 OSD，`lvs` 显示 LV 在但 tag 空 | LV 缺 ceph tag（destroy 清了） | **stable-rebuild-skill 问题 7**（lvm prepare 复用现有 LV，禁 zap） |
| auth 匹配但 PG 仍 unknown | PGMap 与新 OSD 不兼容 | §三.D |
| ec-prod profile / EC crush rule 丢失 | 上层元数据缺失 | stable-rebuild-skill §全量重建 步骤 6 |
| 只剩 `failed cephadm daemon` stray 告警 | 仅告警 | §三.E（可忽略） |
| LVM/PV 真损坏（vgcreate 报错/IO error） | 磁盘/LVM | stable-rebuild-skill §全量重建 |

> ⚠️ 大多数"半损坏"是**上层元数据缺失**（mgr auth / ec profile / crush rule / OSD 未 activate），**不是磁盘坏**。先确认 `lvs` LV 完整再决定是否动磁盘。

---

## 三、对症止血

### A. OSD 进程反复重启 / 起不来
systemd `Restart=always` 会和手工操作打架。**先 stop（必要时 mask）**：
```bash
for id in $(systemctl list-units 'ceph-osd@*' --no-legend | grep -oP 'osd@\K[0-9]+'); do
  sudo systemctl reset-failed ceph-osd@$id 2>/dev/null; sudo systemctl stop ceph-osd@$id
done
pgrep ceph-osd && echo STILL_RUNNING || echo STOPPED
```
若报 `Start request repeated too quickly` → 先 `systemctl reset-failed ceph-osd@<id>` 再 start。
恢复：`sudo systemctl unmask ceph-osd@$id && sudo systemctl start ceph-osd@$id`。

### B. 无 active mgr（mgr auth key 丢）
现象：mgr 容器 Up 但 `ceph -s` mgr 行 `no daemons active`，mon 日志 `failed to find mgr.<name> in keyring`。
```bash
FSID=4f4e3ca0-8297-11f1-a671-97520597268c
sudo ceph auth import -i /var/lib/ceph/${FSID}/mgr.ceph-node1.zrdrjl/keyring
sudo systemctl restart ceph-${FSID}@mgr.ceph-node1.zrdrjl 2>/dev/null || \
  sudo podman restart $(sudo podman ps -a --format '{{.Names}}' | grep mgr-ceph-node1)
sleep 10; sudo ceph mgr dump | grep active_name
```
✅ `ceph -s` mgr 行出现 `active`。**注意：无 active mgr 时 up_thru 不会推进**，所以救 mgr 常是 PG unknown 的前置。

### C. ⚑ OSD up 但 up_thru=0 / PG unknown —— auth key 不匹配
`ceph osd destroy` **保留**旧 auth key，`ceph-volume` 生成的**新** key 因旧 key 还在而不覆盖 → 不匹配 → 无法 beacon。
**正解（不删 pool、保 stable-ID）：先删旧 key 再 activate。**
```bash
for id in 0 1 2 3 4 5; do sudo ceph auth rm osd.$id 2>/dev/null; done   # ⚑ 关键，别用 ceph auth add 硬糊
sudo ceph auth ls | grep 'osd\.' || echo "no osd keys (expected)"
# 对应节点上重新 activate（复用现有 LV，见 stable-rebuild-skill 问题 7）
sudo ceph-volume lvm activate --all
sudo systemctl restart ceph-osd@<id>
sudo ceph osd dump | grep "osd.<id>"   # up_thru 应变非 0
```
> up_thru 仍 0 → 查 `ceph -s` slow ops，杀 157 上残留 juicefs mount / stale rados client 后再重启 OSD。

### D. auth 匹配但 PG 仍 unknown
若 OSD 是 **purge**（非 destroy）重建，旧 PGMap 指向已删 OSD UUID → 不兼容。**先尝试让 mon 重算，不要一上来删业务 pool**：
```bash
sudo ceph osd force-create-pg <pgid> --yes-i-really-mean-it
```
仅当无效且**确认数据可丢** → delete+recreate pool（⚠️ pool_id 会变 → 破坏 stable-ID 复现前提 → 视为一次全新部署、重新标定基线，且须先报告，见 §六）。

### E. 仅 "failed cephadm daemon" stray 告警
OSD 全 up + PG active+clean，只 HEALTH_WARN `N failed cephadm daemon(s)` → podman/systemd 混部产生的 stray，不影响功能。
```bash
sudo ceph orch ps 2>/dev/null | grep error
sudo ceph health mute CEPHADM_FAILED_DAEMON 1h 2>/dev/null || true
```

---

## 四、恢复后验证清单
```bash
sudo ceph -s | grep -E 'health|mgr:|osd:|pgs:'   # mgr active；6 up；all active+clean
sudo ceph osd ls                                 # 0 1 2 3 4 5
sudo ceph osd dump | grep up_thru | grep -c 'up_thru 0'   # =0
sudo ceph osd erasure-code-profile get ec-prod   # k=4 m=2 osd
sudo ceph osd pool get juicefs-data fast_read    # fast_read: 1
sudo rados df --format json | python3 -c "import sys,json;print([p['num_objects'] for p in json.load(sys.stdin)['pools']])"  # ≈0
sudo ceph auth get client.juicefs                # key 存在
```

---

## 五、旧路线（orch + purge 全量重建）—— 仅历史/末位兜底，默认不用

> ⚑ 已弃用为默认路线：`ceph orch daemon add osd` + `ceph osd purge` 改 OSD 身份、删 pool 改 pool_id，破坏 stable-ID 复现。默认走 `stable-rebuild-skill.md`（destroy + auth rm + 复用现有 LV）。
> 仅当 destroy 路线在实测环境彻底走不通、且已停下报告并获准"接受一次全新部署重标基线"时，才用旧脚本 `scripts/rebuild-osds.sh`。其踩坑（orch 竞态扫盘、`already created?`、`orch daemon rm --force` 删 key、.mgr pool stuck、3 层 SSH 拷 keyring）已并入 `stable-rebuild-skill.md` 问题库，不在此重复。

---

## 六、纪律（本次教训）
1. **先分层诊断（§二表），再动手**，不盲目重建。
2. **auth key 不匹配 → 先 `ceph auth rm osd.<id>` 再 activate**（§三.C），不跳 purge+删 pool。
3. **LV 缺 tag ≠ 磁盘坏**：用 lvm prepare 复用现有 LV（禁 zap / 禁裸盘 create / 禁手动 mkfs），见 stable-rebuild-skill 问题 7。
4. **改控制变量（purge / 删 pool / 改 pool_id）前必须停下来报告**（分层授权，02-2-G §四b）——遇障碍报告障碍，不自行绕道。
5. 任一步卡 >20min 或反复重试同操作 → 停下报告。全程只碰 slave(150-152)，不动 157 WekaIO。

---

## 七、更新日志
| 日期 | 内容 |
|------|------|
| 2026-07-22 | 初始（orch+purge 全量重建路线 + 10 问题）|
| 2026-07-23 | 合并 cluster-recovery-and-rebuild-guide：重构为**分层诊断+止血恢复**；orch+purge 降级为历史/兜底（§五）；新增 §三.B 救 mgr、§二诊断表（含 LV 缺 tag / ec profile 丢失指引）；问题库统一并入 stable-rebuild-skill |
