# 集群重建 / 恢复 Skill（h3c 指针页）

> ⚑ 本文件已合并到 prod-deploy 的规范文档，**不在此维护重复内容**。
> h3c 与 prod-deploy **共用同一物理集群和 `juicefs-data` pool**，重建/恢复口径完全一致。

请直接使用 prod-deploy 侧的权威文档：

| 需求 | 权威文档 |
|------|---------|
| **规范重建路线** + 全量重建步骤 + 完整问题库（destroy + `ceph auth rm` + `ceph-volume lvm` 复用现有 LV，禁 zap） | `../../prod-deploy/pre-skills/stable-rebuild-skill.md` |
| **集群半损坏时的分层诊断 + 止血恢复**（PG unknown / 无 active mgr / OSD 起不来 / LV 缺 tag） | `../../prod-deploy/pre-skills/cluster-rebuild-skill.md` |

## h3c 首测前的一次性清理（口径提醒）

- 目的：清掉 prod-deploy 256K 口径在 `juicefs-data` 里的历史残留（~305 万对象 / 1.1 TiB），让 h3c 4M 卷在干净态测试。见 `doc/perf-tasks/01-h3c-baseline-and-config-adaptation.md` 步骤 0.5。
- 推荐：按 `stable-rebuild-skill.md` §二 **stable-ID 重建**（复用现有 LV，禁 zap，~15min），或 pool 级 delete+recreate（更快）。
- **h3c 是一次性前置，跨部署不比绝对值** → pool_id 是否保留不影响 h3c 口径；重点是 `rados df` 确认 `juicefs-data` OBJECTS=0 后再建 h3c 卷。

> 历史：本文件原为 07-22 的 orch+purge 全量重建副本，已弃用（orch+purge 改 OSD 身份/pool_id = 已证随机源）。相关踩坑并入上述 prod-deploy 两个文档。
