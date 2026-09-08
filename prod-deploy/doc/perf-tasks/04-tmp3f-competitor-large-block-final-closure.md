# 04-tmp3f任务书：竞品大块单流读最终收口

> 日期：2026-09-05
> 状态：`COMPLETED / VALID / ENVIRONMENT_CLOSED`；有效RUN `20260905-125702`
> 证据等级：`L1_SCREEN`；本任务不自动改变生产配置。

## 一、为什么只剩这一项

04-tmp3系列已经回答了大部分问题：

- 04-tmp3c确认B4必须配合更大的readahead，B4/RA32约为`2.9 GiB/s`；
- 04-tmp3d确认Ceph对象层4 MiB/QD8达到`5403.20 MiB/s`，对象后端有余量；
- 04-tmp3e确认异步应用QD8达到`5277.79 MiB/s`，同步QD1才是当前主要约束；
- 04-6b刚确认`max-fuse-io=1M`对seqwrite有L1信号，写侧转05正式回归。

因此不再重复创建临时卷、layout、RADOS seed、写侧fio、GC或compact。04-tmp3f只回答尚未闭合的
读侧问题：**在当前B256格式上，应用`bs=20M`本身、RA32以及`max-fuse-io=1M`各有多少作用，
能否让同步单流读达到竞品`5149.84 MiB/s`。**

```text
STOP_AFTER_ANSWER=true
FORMAL_MATRIX=10 read-only cells
ESTIMATED_WALL_CLOCK=30--60min
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3f/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp3f-<RUN_ID>
```

## 二、固定环境和保护边界

- 发起端固定157；二进制固定`/tmp/juicefs-1.4.1-patched`，MD5
  `24fae0852051c80ca571cb2f20275d46`。
- 数据只读复用现有`juicefs-prod`中的`/test_dir/seqread/seqread.0.0`；冻结META/UUID、路径、inode、
  size、mtime及首尾hash。
- 每个参数臂使用`/tmp/jfs-04tmp3f-<RUN_ID>-<LABEL>`只读临时挂载；禁止通过业务挂载运行fio。
- 公共参数固定`--max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-size 0`，
  `async_dio=off`，并使用RUN私有Ceph配置`ms_async_op_threads=8`；仅改变矩阵声明的
  `max-readahead`和`max-fuse-io`。
- fio固定`rw=read/direct=1/numjobs=1/ioengine=psync/iodepth=1/size=10G/runtime=60/time_based`；
  只改变`bs=256K/20M`。
- 禁止format、layout、写fio、destroy、GC、RADOS seed、pool/PG/CRUSH/OSD配置、compact、
  drop_caches、服务/网络/内核修改以及任何sudo写操作。
- 不暂停scrub；每格前后检查Ceph health。若出现scrub、recovery、backfill或非`HEALTH_OK`，
  当前RUN停止且不得补样。

## 三、预注册矩阵

| 臂 | max-fuse-io | max-readahead | 含义 |
|---|---:|---:|---|
| A | 256K | 8M（显式写出当前默认） | 当前交付对照 |
| B | 256K | 32M | 只增大预读窗 |
| C | 1M | 32M | 再增大FUSE请求上限 |

同一行连续cell共用一个只读挂载，换行即优雅卸载后重挂：

```text
A01 A/256K -> A02 A/20M
B01 B/20M
C01 C/256K -> C02 C/20M
C03 C/20M -> C04 C/256K
B02 B/20M
A03 A/20M -> A04 A/256K
```

固定配对：

- A臂纯bs：`A02/A01`、`A03/A04`；
- C臂纯bs：`C02/C01`、`C03/C04`；
- RA32：`B01/A02`、`B02/A03`；
- max-fuse：`C02/B01`、`C03/B02`。

不得根据中间性能改序、删格、补格、换文件或挑挂载。

## 四、采样和裁决

每格保存fio JSON、stdout/stderr、唯一1秒bw log、挂载命令/PID/starttime/exe、FUSE与对象GET累计量、
客户端CPU/NIC及前后health。主口径使用实际I/O起点，正式窗`[10,50)`，输出mean、median、CV和
四个10秒窗；fio summary只作交叉检查。

- 同一因素的两组固定配对均同向且均`>=10%`：登记`L1_MATERIAL_SIGNAL`；
- 两组均`<5%`：登记`NO_MATERIAL_SIGNAL`；
- 其余：登记`RESOLUTION_INSUFFICIENT`；
- 任一可交付同步臂的两个20M点都达到`5149.84 MiB/s`：登记
  `READ_TARGET_OBSERVED_TWICE_L1`；否则明确给出差距；
- 任一同臂同bs重复锚漂移`>8%`、fio error、采样不足、身份/资产/health异常：RUN无效，停止而不补样。

即使出现L1信号，也只进入后续七项回归；不得直接覆盖256K交付配置。若三个因素均无材料信号且
同步读仍未达标，则结合04-tmp3d/e签署：当前无缓存同步QD1分支的剩余提升需要应用异步并发或代码级
Reader/FUSE流水线改造，而不是继续调整现有挂载参数。

## 五、执行阶段

### Phase 0：离线Gate

检查shell/Python语法、10格矩阵、固定配对、分析fixture、路径/身份保护及禁止命令。Gate通过前不SSH。

### Phase I：只读inventory和plan

核对二进制、META/UUID、业务挂载和资产指纹、Ceph `HEALTH_OK`、6/6 OSD、PG全active+clean、
无foreign fio和无本任务残留；输出完整10格命令及脚本SHA。该阶段不挂载、不跑fio。

### Phase II：连续执行R

按矩阵连续执行；phase内不逐格暂停。实现缺陷若改变已执行脚本，当前RUN作废，修复后换RUN_ID重来；
环境或数据异常则保留现场。

### Phase III：持久化和收口

先将raw、实际脚本、commands、state、分析和manifest持久化到`EVIDENCE_ROOT`并核验SHA；确认所有
任务挂载均已优雅卸载、worker退出、临时空目录删除，业务META/UUID/挂载/资产和Ceph状态前后一致。
本任务没有临时数据资产，不删除任何卷内文件。

## 六、交付物

1. `doc/perf-report/04-tmp3f-competitor-large-block-final-closure-20260905.md`；
2. `/mnt/c/SunRise/test/04-tmp3f/<RUN_ID>/`原始证据、脚本和SHA；
3. 必要时更新04状态表、当前性能现状及results-table。

## 七、修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-05 | 初版：R/O1/O2/W一体化计划。 |
| 2026-09-05 | 精简：04-tmp3d已闭合对象层、04-6b已闭合写F1，因此删除重复临时卷、layout、RADOS、写侧、GC和compact，只保留10格只读矩阵。 |
| 2026-09-05 | RUN `20260905-125702`完成：APP_BS、RA32和FUSE1M均为L1材料信号；最佳`2963.95 MiB/s`仍未达到竞品`5149.84 MiB/s`，环境关闭。 |
| 2026-09-05 | 原始证据持久化、339项manifest与GPT独立复算通过；远端本RUN临时副本已精确清理，生命周期关闭。 |
