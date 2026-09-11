# T09社区版DirStats规模测试计划

## 目标

在当前三节点TiKV环境上，用独立临时JuiceFS卷验证社区版`DirStats`相对`--strict`和`du`的查询收益，并确定T09后台快照的刷新周期。测试不进入业务卷命名空间，不写Ceph对象数据。

## 固定隔离范围

- 执行客户端：157；
- 临时META：`tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/jfsportal-dirstats-20260911`；
- 临时卷名：`jfsportal-dirstats-20260911`；
- 临时根：157的tmpfs `/dev/shm/jfsportal-dirstats-20260911`；
- 对象后端及JuiceFS日志：157的tmpfs `/dev/shm/jfsportal-dirstats-20260911-*`；仅创建零字节文件，挂载时设置`--cache-size=0 --backup-meta=0`并显式把`--log`指向tmpfs；禁止把对象后端、缓存或持续日志放在仅余约20 GiB的系统盘；
- 格式：`DirStats=true`、`trash-days=0`；不修改`juicefs-prod`配置、挂载或数据。

## 阶段

1. **A只读预检（已完成）**：冻结业务指纹、确认DirStats和临时前缀未占用。
2. **B 1万文件canary（已完成）**：创建临时卷和三层树，限速不超过500 create/s；对比fast、strict和du，各执行首次值及3次复测。
3. **B2正确性canary（已完成）**：以独立4 KiB对齐清单为预期，验证grow、shrink、rename、hardlink和unlink后fast/strict结果。
4. **C 10万文件（已完成）**：只有B/B2无业务影响且统计正确才追加；保持同一目录结构和限速。
5. **D 100万文件（已跳过）**：C已足以确定实现架构；用户确认进入下一步，不再为单一曲线点追加90万文件。
6. **E精确清理**：先卸载；按临时META、卷名和运行时UUID三重校验后单独审批destroy；确认业务指纹及TiKV状态回归。

## 数据与对比

固定三层目录为10×10×10，共1110个目录；规模档只增加各叶目录中的零字节文件。每档等待DirStats收敛后比较：

```bash
juicefs info -r TEST_ROOT
juicefs info -r --strict TEST_ROOT
juicefs summary --depth 3 --csv TEST_ROOT
juicefs summary --depth 3 --strict --csv TEST_ROOT
du -s --block-size=1 TEST_ROOT
```

记录wall time、文件/目录/空间结果、TiKV CPU、pending compaction、业务I/O、targets和Ceph健康。网页不会直接执行这些命令；测试结果只用于决定后台SQLite快照周期。

## 硬停止门

- 任一PD/TiKV PID、`/mnt/juicefs`、`/mnt/jfs-tikv`或`/mnt/dbwal`指纹变化；
- Prometheus targets少于14、OSD少于6/6或PG不是全clean；
- TiKV pending compaction不能回到阶段前值；
- 统计结果无法与strict参考解释一致；
- 157可用系统盘低于15 GiB。

此外，每个测试档前后检查系统盘和`/dev/shm`；系统盘测试目录累计不得超过100 MiB，`/dev/shm`对象及日志目录不得超过64 MiB。64 MiB是“零字节文件不应产生数据对象”的异常保护门，不是测试卷的逻辑容量限制：100万个零字节文件的目录项和统计值保存在TiKV，按4 KiB最小统计粒度可显示约4 GiB逻辑占用，但对象后端预期仍接近空。任一门超限立即停止，不进入下一档。

阶段B以后每档单独签收；不因一档通过自动进入下一档。

## 阶段B裁决

1万文件下fast为0.05～0.06秒、strict为0.09秒、`du`为0.79～0.80秒；fast与strict结果一致，业务及Ceph无变化，详见`inventory/T09-DIRSTATS-PHASE-B-10K-SIGNOFF-20260911.md`。该规模不足以判断扩展趋势，允许申请阶段C，但不自动执行。

## 阶段B2裁决

七种有序元数据变更中，fast与strict均和独立清单精确一致，且阶段B的原始树、业务指纹和Ceph容量不变，详见`inventory/T09-DIRSTATS-PHASE-B2-CORRECTNESS-SIGNOFF-20260911.md`。该结果支持进入阶段C；它不覆盖并发竞争或异常客户端崩溃，生产实现仍需快照时间戳及低频strict抽样审计。

## 阶段C裁决

10万文件下fast仍约0.05秒，strict约0.18秒，而`du`增至约22秒；fast/strict统计一致，业务与Ceph无变化，详见`inventory/T09-DIRSTATS-PHASE-C-100K-SIGNOFF-20260911.md`。结果已足以确定“异步采集DirStats汇总、网页只查SQLite”的架构，建议跳过只提供额外曲线点的100万档，转入T09实现。
