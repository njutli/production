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

> 🔴 **重建前置门禁（2026-07-24 血泪教训，`rebuild-stable-ids.sh` Step 0 已实装）**：**任何重建/大批 `ceph-volume lvm create` 前，先确认 mon quorum 健康**——`sudo ceph -s` 25s 内有输出，且 `ceph quorum_status` 里 `len(quorum) == len(monmap.mons)` 且 ≥1。mon 亚健康（3-mon 退化到单 mon、probing 无 quorum）时跑 create，`ceph osd new` 请求会堆积把 mon 彻底拖 hung（曾致 398 slow ops + 跨天僵尸 create）。不满足门禁 → **先按 §三.F 恢复 mon quorum，别跑 create**。

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

> 🔴 **进程识别陷阱（2026-07-24 实测教训）**：`ps -ef | grep ceph-mon` 会**误匹配**到其它 ceph 进程命令行里的 `--default-log-to-stderr` 等片段，看起来"mon 进程在"其实是假象；反过来 `systemctl is-active ceph-mon.target` 显示 `inactive` 也**不代表没有 mon**——本集群 **mon/mgr 是 cephadm 容器**（`ceph-<FSID>-mon-ceph-node3` 等），只有 **OSD 是 systemd（ceph-volume）**。**判定 mon/mgr 死活一律用 `sudo podman ps -a --format '{{.Names}} {{.Status}}' | grep -E 'mon|mgr'`，不要用 ps/grep 或 systemctl 下结论。** 另注意本集群是 **单 mon（mon.ceph-node3 在 152）**，mon 一旦 hung 整个控制面全停。

对照下表**先确定层级，再对症**：

| 症状 | 层级 | 去哪 |
|------|------|------|
| `ceph -s`/`ceph osd tree`/`quorum_status` **全超时无输出**，但 mon 容器 `podman ps` 显示 Up | **mon 容器 hung（控制面挂）** | **§三.F**（先看这个：mon 不响应时下面所有 ceph 命令都会假性超时，会误导诊断） |
| mon 软重启后仍 `probing` / `outside_quorum` / `quorum=[]`，日志一直 form quorum | **monmap 退化**（多 mon 掉到不足多数，如 3→1） | **§三.F-2**（monmap 手术删已消失的 mon，软重启治不了） |
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

### F. ⚑ mon 容器 hung —— 所有 ceph 命令假性超时（单 mon 控制面挂）
现象：`ceph -s` / `ceph osd tree` / `ceph quorum_status` 全**超时无任何输出**（不是报错，是挂住），但 `podman ps` 显示 mon 容器 `Up`。本集群**单 mon**（`mon-ceph-node3` 在 152），它 hung → 整个控制面停 → 依赖 mon 的 `ceph-volume lvm create`（要调 `ceph osd new`）会跟着卡死。
> 2026-07-24 实测触发链：`rebuild-stable-ids.sh` Step 5 的多个 `ceph-volume lvm create` 请求堆积把单 mon 拖 hung，甚至叠了**跨天的僵尸 create 进程**（Jul23 一批 + 当日一批同时挂在 osd.0）。

**恢复顺序（逐步停等，先止血再动 mon）：**
```bash
# 1) 先清所有卡死的 ceph-volume lvm create 僵尸进程（在有 create 残留的 slave 上）——
#    不清掉它们，mon 一起来就又被冲垮。用 pgrep 精确杀，勿 kill -9 mon/osd。
sudo pgrep -af 'ceph-volume lvm create' 
sudo pkill -f 'ceph-volume lvm create'; sleep 2; sudo pgrep -af 'ceph-volume lvm create' || echo CLEARED
# 2) 软重启单 mon 容器（在 152）——⚠️ 用 cephadm 的 systemd 包装单元，
#    绝不 podman rm mon、绝不删 /var/lib/ceph/<FSID>/mon.* store。
FSID=4f4e3ca0-8297-11f1-a671-97520597268c
sudo systemctl restart ceph-${FSID}@mon.ceph-node3 2>/dev/null || \
  sudo podman restart $(sudo podman ps --format '{{.Names}}' | grep -E "\-mon-ceph-node3")
# 3) 等 30s 确认 mon 恢复响应
sleep 30; sudo ceph -s | grep -E 'health|mon:|mgr:|osd:'
```
✅ `ceph -s` 恢复输出、看到 mon quorum。
🔴 **恢复后立刻核对 CRUSH 不变**（stable-ID 命脉）：`sudo ceph osd getcrushmap -o /tmp/cm && crushtool -i /tmp/cm --dump | md5sum`，对比基线 `694101a9b09080848ab8c8f9342f04d4`。**若 mon store 有损、CRUSH 变了、或 mon 软重启仍不响应 → 停下报告，不要重建 mon / 不要删 pool 绕道。**

#### F-2. ⚑ mon 软重启后仍 `probing` / `outside_quorum` —— monmap 退化（多 mon 掉到不足多数）
现象：软重启后 `mon_status` 显示 `state=probing`、`outside_quorum=[本 mon]`、`quorum=[]`，日志一直 form quorum。**根因**：monmap 里定义了 N 个 mon，但实际只剩 <多数 个存活（如 3-mon 集群 node1/node2 的 mon store 消失只剩 node3）→ 永远凑不齐多数，**无法自愈，软重启无用**。
> 判定：容器内 `ceph --admin-daemon /var/run/ceph/ceph-mon.<name>.asok mon_status` 看 `monmap.mons`（期望几个）对比实际存活的 mon 容器数（`podman ps | grep mon`）。本集群 monmap 三个 mon 地址在 `10.3.1.6/7/8`（集群网），node1/node2 的 mon store 曾丢失退化成单 mon。
> ⚑ 附带线索：mon 目录旁若见 `mon.<name>-old/`、`mon.<name>-new2/` 残留 → 说明之前手工折腾过 mon（很可能就是退化根源），**勿删勿用这些残留**。

**恢复 = monmap 手术**（删掉 monmap 里已消失的 mon，让存活 mon 成唯一 mon 立即成 quorum）。**只改 mon 成员拓扑，不碰 OSDMap/CRUSH/pool。属改控制面拓扑，须先报告获准（§六）。** 步骤（存活 mon 节点，先停 mon）：
```bash
FSID=4f4e3ca0-8297-11f1-a671-97520597268c; NAME=ceph-node3   # 按存活 mon 改
STORE=/var/lib/ceph/${FSID}/mon.${NAME}
sudo systemctl stop ceph-${FSID}@mon.${NAME}
sudo cp -a $STORE ${STORE}.bak-$(date +%s)                    # ① 必做备份（回滚用）
IMG=$(sudo podman inspect ceph-${FSID}-mon-${NAME} --format '{{.ImageName}}')
CI=/var/lib/ceph/mon/ceph-${NAME}                             # 容器内挂载点
mon(){ sudo podman run --rm -v $STORE:$CI --entrypoint ceph-mon $IMG -i $NAME "$@"; }
mmt(){ sudo podman run --rm -v $STORE:$CI --entrypoint monmaptool $IMG "$@"; }
mon --extract-monmap $CI/monmap.extract                       # ② 提取
mmt --print $CI/monmap.extract                                # 手术前：见全部 mon
mmt $CI/monmap.extract --rm ceph-node1 --rm ceph-node2        # ③ 删已消失的 mon（按实际改）
mmt --print $CI/monmap.extract                                # 停等点：确认只剩存活 mon 才继续
mon --inject-monmap $CI/monmap.extract                        # ④ 注回
sudo systemctl start ceph-${FSID}@mon.${NAME}; sleep 20        # ⑤ 启，应立即 leader
sudo ceph -s | grep -E 'health|mon:|osd:'
```
🔴 手术后仍 probing / `ceph -s` 超时 → 停下报告，勿反复重启，用备份回滚（`rm -rf $STORE && cp -a $STORE.bak-<TS> $STORE`）。
🔴 quorum 恢复后**核对 CRUSH md5 + pool_id=1 + fast_read=1**（monmap 手术理论上不碰，但必须验证）。
> 单 mon 无冗余，救活稳定后应用 `ceph orch apply mon`（或手动 add-mon）补回丢失的 mon 恢复多数冗余 —— 独立后续步骤，先把集群救活。

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
5. **判 mon/mgr 死活只用 `podman ps`**，不用 `ps|grep`（误匹配）也不用 `systemctl is-active ceph-mon.target`（本集群 mon 是容器不是 systemd）。所有 ceph 命令超时无输出 → 先怀疑单 mon hung（§三.F），别急着下"mon 挂了要重建"的结论。
6. **`ceph-volume lvm create` 卡住 → 先查 mon 是否响应**（很可能是 mon hung 导致，不是 destroyed/auth 问题）；清僵尸 create 进程后再动 mon，别反复重跑 create 叠加请求把 mon 压垮。
7. **重建/大批 create 前必须过 mon quorum 前置门禁**（`rebuild-stable-ids.sh` Step 0：quorum 数==monmap mon 数且≥1）；mon 亚健康时严禁跑 create（会拖 hung）。mon 软重启后仍 probing → monmap 退化（§三.F-2），做 monmap 手术前须停下报告获准。
8. 任一步卡 >20min 或反复重试同操作 → 停下报告。全程只碰 slave(150-152)，不动 157 WekaIO。

---

## 七、更新日志
| 日期 | 内容 |
|------|------|
| 2026-07-22 | 初始（orch+purge 全量重建路线 + 10 问题）|
| 2026-07-23 | 合并 cluster-recovery-and-rebuild-guide：重构为**分层诊断+止血恢复**；orch+purge 降级为历史/兜底（§五）；新增 §三.B 救 mgr、§二诊断表（含 LV 缺 tag / ec profile 丢失指引）；问题库统一并入 stable-rebuild-skill |
| 2026-07-24 | 实测教训：rebuild Step 5 把单 mon 拖 hung + 跨天僵尸 create 进程叠加。新增 §三.F（mon 容器 hung 恢复：清僵尸 create→软重启单 mon→核对 CRUSH md5）；§二加进程识别陷阱警告（mon/mgr 判死活只用 podman ps，勿 ps\|grep / systemctl）+ mon hung 诊断行；纪律加第 5-6 条 |
| 2026-07-24 | monmap 退化事故：3-mon 集群 node1/node2 mon store 消失只剩 node3 → 永远 probing 无 quorum。新增 §三.F-2（monmap 手术删已消失 mon）+ 诊断表 probing 行；§二加重建前置门禁（mon quorum 数==monmap 数，`rebuild-stable-ids.sh` Step 0 已实装）；纪律加第 7 条 |
