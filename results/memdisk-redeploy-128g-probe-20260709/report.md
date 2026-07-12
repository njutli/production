# 任务 12.1-步骤1：改部署 + 探 128G 容量 — 报告

> 日期：2026-07-10　执行：GLM　产出目录：results/memdisk-redeploy-128g-probe-20260709/

---

## 判据 1：部署改成功否

**成功。** 6 OSD 全部从 `bluefs_single_shared_device=1`（WAL/DB/DATA 同一 tmpfs）改为 `bluefs_single_shared_device=0`（WAL/DB 独立 + DATA 独立）。

- **方式**：purge 重建（非在线迁移）。每个 OSD 用 `ceph osd purge --force` 删除，然后在节点上建独立 DATA tmpfs(45G) + WAL/DB tmpfs(4G)，经 loop device 中转，手动 `pvcreate/vgcreate/lvcreate` 后用 `ceph-volume lvm prepare --data <DATA LV> --block.db <DB LV>` 创建 BlueStore，最后 `cephadm deploy` 注册守护进程。
- **对账**（deploy-after.txt）：
  - 6/6 OSD `bluefs_single_shared_device=0` ✅
  - 6/6 OSD `bluefs_dedicated_db=1` ✅
  - DATA devices: osd.0/2/4=loop20, osd.1/3/5=loop21（各 45G）
  - DB devices: osd.0/2/4=loop30, osd.1/3/5=loop31（各 4G）

## 判据 2：DATA tmpfs 每 OSD 多大 + 余量

- **DATA tmpfs**：每 OSD 45G（LVM LV <45.00 GiB）
- **WAL/DB tmpfs**：每 OSD 4G（LVM LV <4.00 GiB）
- **每节点 tmpfs 合计**：2×(45+4) = 98G
- **每节点 available（部署后空载）**：node1=227G, node2=227G, node3=228G
- **余量**：227G >> 40G 安全线 ✅
- **每节点内存账**：251G total − 98G tmpfs − ~5G 系统 = ~148G available 给页缓存/进程

## 判据 3：128G layout 能否安全承载

**能。** 128G layout 安全承载，无需退回 96G/64G。

- 渐进试写 32G→64G→96G→128G 全程未触发停止条件
- 停止条件回顾：①任一 OSD %USE≥85% ②任一节点 available<30G ③OOM/OSD down/health WARN
- **128G 时指标**：
  - 最高 OSD %USE = **73.50%** < 85% nearfull ✅（余量 11.5pp）
  - 最低节点 available = **172G** >> 30G ✅（余量 142G）
  - HEALTH_OK ✅
  - 无 OOM、无 OSD down ✅
- **建议**：layout 用 128G（对齐上周真盘基准 128 jobs×1G，控制变量）

## 判据 4：128G 时最高 OSD %USE + 最低 available

| 指标 | 值 | 阈值 | 余量 |
|------|-----|------|------|
| 最高 OSD %USE | 73.50% | 85% nearfull | 11.5pp |
| 最低节点 available | 172G | 30G | 142G |
| ceph health | HEALTH_OK | OK | — |
| OOM/OSD down | 无 | 无 | — |

各档详细数据（cap-{32,64,96,128}g.log）：

| 档位 | OSD %USE | DATA/OSD | 最低 available | shared/节点 | Health |
|------|---------|----------|----------------|-------------|--------|
| 32G | 24.51% | 8 GiB | 228G | 18G | OK |
| 64G | 40.84% | 16 GiB | 209G | 36G | OK |
| 96G | 57.17% | 24 GiB | 190G | 54G | OK |
| 128G | 73.50% | 32 GiB | 172G | 71G | OK |

## 判据 5：集群状态 + 池参数 + 清理

- **部署后**：HEALTH_OK, 6 up/in, 161 pgs active+clean, degraded=0 ✅
- **池参数**：juicefs-data, EC 4+2 (k=4 m=2), 32 PGs, crush-failure-domain=osd, jerasure/reed_sol_van ✅
- **OSD 均匀**：6 OSD weight=0.04779, %USE=8.18%, VAR=1.00, STDDEV=0 ✅
- **清理后**：juicefs-data STORED=9.9 MiB（仅元数据）, USED=15 MiB, MAX AVAIL=170 GiB; 6 up/in; HEALTH_OK ✅
- **新部署保留**：WAL/DB 独立 + DATA 独立形态未回滚，步骤2可用 ✅

## 判据 6：异常清单

1. **ceph orch daemon add osd 不支持裸 loop 设备**：ceph-volume lvm batch 将 loop 设备识别为 LVM 但无 LV，报 IndexError。解决：手动创建 PV/VG/LV 后用 LV 路径或 podman 直接运行 ceph-volume lvm prepare。
2. **cephadm deploy 缺 config 文件**：cephadm deploy 创建 unit.run 后立即 systemctl start，但未创建 ceph.conf 导致启动失败。解决：deploy 后手动从 mon 或相邻 OSD 复制 config 文件到 /var/lib/ceph/<fsid>/osd.X/config，然后 reset-failed + start。
3. **node3 使用 Docker 而非 Podman**：node1/2 用 podman，node3 用 docker。podman 命令在 node3 不可用。解决：node3 用 docker run 替代 podman run 执行 ceph-volume prepare。
4. **Docker 挂载 config 为目录**：当 config 文件不存在时，Docker 将挂载点创建为目录而非报错，导致 ceph-volume 报 IsADirectoryError。解决：先 rm -rf config 目录，再 cp 文件，再 start。
5. **bootstrap-osd keyring 不在节点上**：cephadm ceph-volume 不挂载 bootstrap keyring，导致 ceph-volume prepare 报 permission denied。解决：从集群 auth 导出 client.bootstrap-osd keyring 到节点 /var/lib/ceph/bootstrap-osd/ceph.keyring，podman/docker run 时显式挂载。
6. **pvremove 交互式确认**：pvremove -ff 仍弹出确认提示，非交互 SSH 下无法回答。解决：先 dd if=/dev/zero 覆写头 10MB 再 pvcreate。
7. **osd.4 stop 延迟**：ceph orch daemon stop 后立即 purge 报 EBUSY。解决：等待 8s 确认 down 再 purge。
8. **无数据丢失/OSD 损坏/OOM**：全程 6 OSD 无 down（除主动 stop+purge），无 OOM kill，无回滚翻车。

---

## 总结

| 项目 | 结果 |
|------|------|
| 改部署 | ✅ 6 OSD 全部 WAL/DB 独立 + DATA 独立（purge 重建） |
| DATA 大小 | 45G/OSD, 4G WAL/DB, 98G/节点 |
| 128G 承载 | ✅ 能（%USE=73.5%, available=172G） |
| 建议 layout | 128G |
| 集群状态 | HEALTH_OK, 6 up/in, 池回空 |
| 新部署保留 | ✅ 不回滚 |
| 异常 | 8 项（均已解决，详见判据6） |
