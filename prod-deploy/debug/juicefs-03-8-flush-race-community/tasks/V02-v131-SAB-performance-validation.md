# V02：JuiceFS v1.3.1 S/A/B 真实 Ceph 性能、正确性与完整性验证

> 执行方：GLM　｜　计划/复核方：Codex　｜　编写/修订日期：2026-08-19
> 性质：承接 V02-PRE 恢复历史与 V02-PRE-R1 只读重新认证的独立性能任务；交接完成后白天态预计 8～12 小时，meta 退化重查时最长约 14 小时
> 执行位置：WSL 本地构建 + 经明确授权的 `ssh thailand`（客户端 157）及测试集群只读/测试动作
> 禁止：业务挂载/业务路径、系统 JuiceFS 二进制、pool delete/create、format/destroy、OSD/TiKV/主机重启、参数修改、生产替换、社区写入
> 重要：本任务书本身不授权 SSH、sudo、mount、fio、drop_caches、gc 或 compact；V02-PRE/R1 的授权、READY 或只读证据均不自动继承，必须另行满足 §3.2

---

## 计划线

```text
C01/C02
  └─ main 目标行为与 B 语义已有确定性技术旁证
V01/V01-R1
  ├─ v1.3 B port、本地定向/C02/race 与三臂 Ceph build 有技术旁证
  └─ 远端 pool objects 18.3M > 3.11M，性能与 ABI 未运行
C03
  └─ 社区证据线独立收口为 CLOSED-BLOCKED，不决定 v1.3 性能
V02 首轮 / V02-PRE / V02-PRE-R1
  ├─ 首轮 objects 7.46M > 3.11M，正确停止且没有运行 fio
  ├─ PRE 独立观察/分类/恢复；对象降至 2.43M，临时挂载全退
  └─ R1 以三组原始 Ceph JSON + 同步 health/PG/OSD 重新证明低对象；资产门留给 V02 只读 B smoke
★ V02（你在这里）
  ├─ 洁净重建 S/A/B 与 provenance（可先行）
  ├─ 真正只读、no-bgjob 的远端 ABI/read smoke（可先行）
  ├─ 校验固定 PRE+R1 双证据、由 B read smoke 闭合资产，再实时重过 3.11M 写入门
  ├─ 3 mount/arm 的 Latin-square randwrite/randrw
  └─ B 独立目录 fio verify
Codex 复算
  ├─ B 恢复且工程风险可接受 → 进入生产候选/长稳决策
  ├─ B 恢复但 A 比较不可判 → 保留 A/B，补充决策证据
  └─ 环境门阻塞/对照无效 → 不外推性能结论
```

一句话：在安全、可鉴别的真实 v1.3.1 Ceph 测试卷上，以 S-stock、A-sync 和
B-async-catchup 同基座交错对照，回答 B 是否恢复 randwrite，以及 B/A 的差异在已知
挂载档位噪声下能否可靠判定。

2026-08-19 修订只改变交接证据编排，不改变 S/A/B、fio、统计或性能判据：对象池恢复历史
由固定 V02-PRE 提供，当前低对象状态由固定 V02-PRE-R1 原始样本提供；本地洁净构建和
真只读 ABI 可在写入门前先行；R1 未完成的资产门必须由 V02 的 B 只读 smoke 闭合。任何
写能力仍必须同时拿到双证据交接、资产实测 PASS、V02 新授权和三次实时
`objects <=3,110,000`。

---

## 〇、背景与承接边界

### 0.1 已有技术输入

1. v1.3.1 base 固定为 `e0032b2a`，三臂都应包含 loadRange 修复 `eaf3d21f`。
2. 历史 A-sync 在真实 v1.3.1 塌态有约 551 → 2970～3583 MiB/s 的同会话证据。
3. V01-R1 原始日志支持 B port 的三项、C02、count/race 和本地 Ceph build；但其结果
   表、provenance、远端 ABI 和交付包不闭合，只能作为技术输入，不能直接复用 PASS。
4. V01 性能没有运行：当时 `juicefs-data` pool objects 为 18,337,356，超过预登记
   启动门 3,110,000。没有任何 B/S 或 B/A 远端性能结论。
5. V02 首轮报告 `report/V02-execution-20260818-143450.md` 再次在早期门停止：对象数
   7,461,762，仍无构建、ABI、fio 或性能数据。它证明安全门生效，不证明对象已经恢复。
6. `V02-PRE-object-pool-recovery-and-classification.md` 是独立环境任务：它最多自然观察、
   一次 `gc --compact` 和一次无 `--delete` 的分类扫描；只有低对象、资产完整、临时挂载
   全退时才签 `READY-V02-LOW-OBJECT`。PRE 不产生性能结论，也不把授权传给 V02。
7. V02-PRE 的初始交付缺少三次低对象原始样本，后补归档不能恢复其采样来源；固定的
   V02-PRE-R1 以三份原始 Ceph JSON、对应 health/PG/OSD 原文及 143s/158s 文件时间间隔
   补足当前低对象证据。R1 没有 mount，因此没有重证数据集资产；该缺口只能由本轮
   §6.3 的 B 真只读 mount 闭合，不能把 R1 receipt 的 `N/A` 改写成历史 `YES`。

### 0.2 本轮必须重新完成

- 从 frozen v1.3 base 洁净构建三臂并闭合 source/patch/binary provenance；
- 远端逐二进制 hash、真正只读且禁后台任务的挂载/read smoke；
- 冻结并核验 §2.1 指定的 PRE 恢复包与 R1 重新认证包，机械生成双证据裁定，再实时
  重过写入门；
- 在环境安全门内执行三挂载/臂、三轮/项的交错矩阵；
- 从全部 per-job bw log 计算稳态中位数；
- 单独验证 B 的小规模数据完整性；
- 如实区分“恢复相对 S”与“相对 A 的 5% 非劣是否可判”。

### 0.3 本轮不回答

- 不证明 latest main 或社区 PR 状态；
- 不修改、替换或重启生产 JuiceFS；
- 不扫描 OSD/TiKV/网络参数；
- 不创建、删除或重建 pool/PG/CRUSH；
- 不把观察到的短窗吞吐外推为长期生产稳定性；正式 soak 另行决策。

---

## 一、问题、优先级和允许终态

### 1.1 P0：环境与对照有效

必须先证明：

- 测试卷、pool、layout、health、对象数和共享业务满足安全门；
- pre/post 环境快照闭合，写测前 meta profile 有可复算的静置探针；
- S 在本窗口仍表现为可鉴别塌态；
- 已知有效的 A 在本窗口恢复；
- 九个正式 mount 都通过 ns/B 档位门，实例身份全程稳定。

环境/对照无效时，任何 B 高数值都不能叫修复。

### 1.2 P0：B 恢复

主问题：

> B 是否在 v1.3.1 真实 randwrite 塌态中达到 `B/S >= 3.00` 且自身稳态中位数
> `>=1653 MiB/s`，并无 EIO、进程退出、对象/health/缓冲安全事件？

### 1.3 P1：B 相对 A

观察非劣界限预登记为 5%：`B/A >= 0.95`。但 A/B 必须通过不同 mount 运行，而历史
最深 mount tier 可达 -30%。因此本任务同时报告：

1. **观察比值**；
2. **-30% 不利档位压力测试**；
3. 是否达到“稳健非劣”、是否仅为“观察非劣但档位下不可判”。

不得把三挂载/臂的观察比值自动写成 5% 精密非劣证明。

### 1.4 P1：randrw 与完整性

- randrw 读、写方向分别计算，绝不相加；
- B/A 两方向观察安全带均为 `>=0.944`；
- B 完成 task-owned 隔离目录的 fio verify；
- 任一数据校验错误、EIO、panic 或 silent truncation 都是技术失败。

### 1.5 允许终态

```text
PASS-B-V131-RECOVERY-A-NONINFERIOR-ROBUST
PASS-B-V131-RECOVERY-A-COMPARISON-INCONCLUSIVE
PASS-B-V131-RECOVERY-BUT-A-INFERIOR
FAIL-B-V131-NO-RECOVERY
FAIL-B-V131-CORRECTNESS-OR-SAFETY
INVALID-S-OR-A-CONTROL
INVALID-MOUNT-TIER-OR-DRIFT
BLOCKED-V02-PRE
INVALID-V02-PRE-HANDOFF
BLOCKED-SAFETY-GATE
BLOCKED-AUTH
BLOCKED-REMOTE-OR-NETWORK
BLOCKED-BUILD-OR-ABI
RESULTS-V131-DEGRADED-META-ONLY
PARTIAL-V02
V02-NON-COMPLIANT
```

`PASS-*` 只代表本轮性能结论可交 Codex复核；不授权生产替换或社区提交。

---

## 二、固定输入、三臂和目录

### 2.1 项目与固定资产

```text
ROOT=/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community
MATERIALS=$ROOT/community-materials
BASE=e0032b2ae5e9603403ca955eed7d05426f6f2f8c
```

| 资产 | 路径 | SHA256 | 进入 arm |
|---|---|---|---|
| loadRange patch | `$ROOT/patch/eaf3d21f-partial-read.patch` | `88bcd1afb708f363fe38a4d208976be7f409204674d7d7fc6e452ab01d4081ae` | S/A/B |
| A-sync patch | `$ROOT/patch/juicefs-flush-race-fix-v131.patch` | `e8dca1048a5f3765e97c7d57a2e7699c3c514f1ba155e519ace4369bfced5e92` | A |
| B-v1.3 port | `$MATERIALS/v131-reference/B-v131-port.patch` | `349d870e3130b5061ae37bed97bb0768edeb3865e217653285e132488bbdace9` | B |
| v1.3 community tests | `$MATERIALS/v131-reference/writer_flush_test_v131.go` | `dd87551145829ec795b504fb7837c46993edd60a0b4ebbb02e163fc81bfc7b50` | local S/A/B test |
| v1.3 C02 tests | `$MATERIALS/v131-reference/writer_flush_c02_test_v131.go` | `b698a0dee6831c6a031eb2553b8db7aa8ada54c33a2d8be486634a938f6dbfe4` | local B test |
| 环境快照脚本 | `/home/lilingfeng/demo/production/prod-deploy/scripts/FULLBASELINE/probe/env-snapshot.sh` | `5d171e6cf93dc5ef9090dde9e5e7f19a2b62027b105eda1eb656e98c99e55093` | pre/post 环境证据 |
| health 库 | `/home/lilingfeng/demo/production/prod-deploy/scripts/tests/lib/ceph-health-check.sh` | `9a11a7b6b39d2714f366c82ac453c633a54d179bec81cdc2ec9a822b9eae473d` | 每次 fio 前 health gate |
| V01-R1 复核 | `$ROOT/report/V01-R1-execution-20260818-001227.md` | 执行时实算 | 历史边界 |
| V02 首轮阻塞报告 | `$ROOT/report/V02-execution-20260818-143450.md` | 执行时实算 | 当前 7.46M 阻塞事实 |
| V02-PRE 任务书 | `$ROOT/tasks/V02-PRE-object-pool-recovery-and-classification.md` | 执行时实算 | 环境恢复与交接约束 |
| 本任务书 | `$ROOT/tasks/V02-v131-SAB-performance-validation.md` | 执行时实算 | 权威要求 |

任一固定资产缺失或 hash 不符，停止为 `V02-NON-COMPLIANT`。历史三枚 114 MB
二进制仅作 hash 参考，禁止直接复制为 V02 正式 binary。

本轮不再接受“找最新”或任意 PRE。恢复历史与只读重新认证固定为以下两组输入；用户启动
V02 时必须在授权原文中同时指定它们：

```text
PRE_RUN_ID=20260818-160041
PRE_REPORT=$ROOT/report/V02-PRE-execution-$PRE_RUN_ID.md
PRE_REPORT_SHA=$PRE_REPORT.sha256
PRE_ARCHIVE=/home/lilingfeng/tmp/juicefs-v02-pre-$PRE_RUN_ID.tar.gz
PRE_ARCHIVE_SHA=$PRE_ARCHIVE.sha256

PRE_REPORT_EXPECTED_SHA256=b82fe47297f46b92007a812e18484f6e66d78f1fcf57f009f933219110be7b94
PRE_ARCHIVE_EXPECTED_SHA256=d03477508ef80acc001986bdaad3b1e8dd4a25fbb80fd2a6dfcfdced4dd1a244
PRE_READY_EXPECTED_SHA256=05c291ae4afaef2575c0c49cc01f65932a019cce8ac726e3cef8e561f2be90a8

RECERT_RUN_ID=20260819-102825
RECERT_REPORT=$ROOT/report/V02-PRE-R1-execution-$RECERT_RUN_ID.md
RECERT_REPORT_SHA=$RECERT_REPORT.sha256
RECERT_ARCHIVE=/home/lilingfeng/tmp/juicefs-v02-pre-r1-$RECERT_RUN_ID.tar.gz
RECERT_ARCHIVE_SHA=$RECERT_ARCHIVE.sha256

RECERT_REPORT_EXPECTED_SHA256=d01b91f7a9afc18fb8f468b70cf5010b86e9f397514c4ee5caa007ee07b54424
RECERT_ARCHIVE_EXPECTED_SHA256=e733d052cb98b4ceaeb019227f19a147cef6472b25a0afb975e041f3b5bf1f16
RECERT_READY_EXPECTED_SHA256=f5edda144d3b6572c832b90b91fdac6b97ffb3664921c3ce5c75639530379993
```

禁止 glob、按 mtime 选择、猜测 latest 或用新文件替换同名输入。两个 archive 必须分别
完成 member 安全/唯一性和 manifest 实校验；V02 只读取 PRE 中唯一后缀
`handoff/V02-PRE-READY.tsv` 与 R1 中唯一后缀 `handoff/V02-PRE-R1-READY.tsv`，不得执行
archive 中的脚本。两组 receipt、report、archive、sidecar 的路径、size、mtime_ns 和实算
SHA 一并冻结。两个 archive sidecar 已知保留远端 `/tmp/...` 路径：只允许读取首个严格
64 位小写十六进制 token 与对应本地文件实算 SHA 比较；不得因路径不同跳过 hash，也不得
改写原 sidecar。用户未同时给出这两组精确输入不妨碍本地构建，但禁止任何写能力和正式
fio。

### 2.2 三臂精确定义

| arm | 源码 | production 差异 |
|---|---|---|
| S | `BASE + eaf3d21f` | 无 flush-race patch |
| A | `S + A-sync` | 同步首次 NewSlice |
| B | `S + B-v1.3-port` | 保留异步分配；SetID 后 catch-up FlushTo |

B 必须保持五条语义：异步 `prepareID`、SetID 后检查、正 ID + 非 frozen + 完整 block、
`FlushTo(int(s.slen))`、错误映射 EIO。三臂不得修改 block size、buffer、flush timer、
retry 或其它 production 文件。

### 2.3 本地目录

```text
RUN_ID=YYYYmmdd-HHMMSS
CTRL=/home/lilingfeng/tmp/juicefs-v02-control-$RUN_ID
INPUT=/home/lilingfeng/tmp/juicefs-v02-input-$RUN_ID
LOCAL=/home/lilingfeng/tmp/juicefs-v02-local-$RUN_ID
LOCAL_ARCHIVE=/home/lilingfeng/tmp/juicefs-v02-local-$RUN_ID.tar.gz
```

源码固定为 `$LOCAL/src/{S,A,B}`，二进制固定为：

```text
$LOCAL/binaries/juicefs-v02-$RUN_ID-S
$LOCAL/binaries/juicefs-v02-$RUN_ID-A
$LOCAL/binaries/juicefs-v02-$RUN_ID-B
```

### 2.4 远端目录

```text
REMOTE_OUT=/tmp/juicefs-v02-$RUN_ID
REMOTE_ARCHIVE=/tmp/juicefs-v02-$RUN_ID.tar.gz
REMOTE_BIN_S=/tmp/juicefs-v02-$RUN_ID-S
REMOTE_BIN_A=/tmp/juicefs-v02-$RUN_ID-A
REMOTE_BIN_B=/tmp/juicefs-v02-$RUN_ID-B
MNT=/mnt/juicefs-v02
TEST_DIR=$MNT/test_dir
INTEGRITY_DIR=$TEST_DIR/v02-integrity-$RUN_ID
REPORT=$ROOT/report/V02-execution-$RUN_ID.md
```

上述路径启动前必须不存在、MNT 必须未挂载且为空。冲突时换 RUN_ID；禁止删除未知
目录。`/mnt/juicefs`、`/usr/local/bin/juicefs`、`/tmp/juicefs-03-8` 只做 identity
快照，禁止修改、卸载、覆盖或在其下起 fio。

---

## 三、授权、环境 profile 与自主边界

### 3.1 未授权时允许的动作

任务书本身不授权执行。未取得 §3.2 授权时只允许读文档、固定资产和旧报告；禁止
创建 V02 目录、构建、Docker、SSH、scp、sudo、mount、fio、drop_caches、gc、compact。

### 3.2 建议的精确授权原文

用户必须明确选择测试环境，并授权下列动作。授权原文逐字保存到
`$CTRL/authorization.txt` 并计算 SHA：

> 我授权执行 V02 任务书，并指定 §2.1 固定的双交接输入：
> `PRE_RUN_ID=20260818-160041` 及其 exact report/archive，
> `RECERT_RUN_ID=20260819-102825` 及其 exact report/archive；允许在 WSL 新建
> `/home/lilingfeng/tmp/juicefs-v02-*`，
> 洁净构建 S/A/B、使用本轮隔离 Redis；允许通过 `ssh thailand`/scp 访问客户端 157，
> 仅在 `/tmp/juicefs-v02-*`、`/mnt/juicefs-v02` 和测试卷既有
> `test_dir/{storage_test,rw_test,mseqread}` 数据集执行任务书规定的只读 smoke、mount、
> randwrite/randrw 与 task-owned integrity，并精确创建/清理本轮 integrity 子目录；
> 允许对 157/150/151/152 执行每个 fio 前的 drop_caches，允许 §6.5 一轮 baseline OSD
> compact，并在任务书规定的每个写轮（含 meta probe 和 integrity）后对测试卷执行一遍
> `juicefs gc --compact` 及 OSD compact/只读状态轮询；仅允许为任务书列出的 Ceph 只读
> 采集/compact 和四节点 drop_caches 使用
> sudo。禁止触碰 `/mnt/juicefs`、业务数据、系统二进制，禁止 format/destroy、
> `juicefs gc --delete`、pool/PG/CRUSH 增删改、配置修改、服务/节点重启、生产替换和
> 社区写入。

该授权是 V02 的新授权；不得引用 PRE/R1 授权替代。R1 报告中的“从 V02-PRE 授权继承”
不构成本轮或 R1 可变动作授权，V02 只把 R1 当作既有只读证据。若双证据交接尚未通过，
用户也可先只授权
“本地构建 + §6.2A/§7.1 的只读 ABI”，但这不授权 write-capable mount、fio、drop_caches、
JuiceFS gc 或 OSD compact；完成后终态只能 `BLOCKED-V02-PRE`，等待另一次明确授权执行
正式写入阶段。

若授权没有精确包含 drop_caches、测试卷 gc 和 OSD compact，则不得运行性能矩阵，
状态 `BLOCKED-AUTH`。GLM 不得用“以前允许过”推断本轮权限。

所有 sudo 调用必须限定为任务书列出的只读 Ceph、OSD compact 和四节点 drop_caches，
并使用非交互方式；出现密码提示或需扩大 sudo 命令集合时立即 `BLOCKED-AUTH`，禁止把
密码写入脚本、stdin、日志或环境变量。

安全派生版 snapshot helper 使用 `sudo -n`；每次调用前仍必须在同一 SSH 会话执行
`sudo -n true` 成功，再给脚本 stdin 接 `/dev/null` 并设有界 timeout；预检失败则不运行
脚本。禁止直接运行会使用裸 sudo、记录 raw cmdline 的 source helper。

### 3.3 环境 profile

默认且唯一自动可用 profile：

```text
PROFILE=VALIDATED-LOW-OBJECT-EXISTING-TEST-VOLUME
START_OBJECTS_MAX=3110000
HARD_OBJECTS_MAX=8000000
```

`START_OBJECTS_MAX` 是 **write-capable mount、meta 写探针、正式 fio 和 integrity** 的
有效性硬门，不是本地构建门，也不是 §7.1 真只读 ABI 门。若执行时对象数仍高于
3,110,000，记录 `WRITE_GATE=PENDING`：允许完成已授权的本地构建，以及在 §6.2A 全过后
完成 §7.1；禁止把 §6.2B 判为 PASS，禁止进入 §6.4～§6.5、§7.2、§8 和 §十一，最终
`BLOCKED-V02-PRE`。

V02 自身禁止通过 drain、启动额外 gc、删除文件、destroy、format 或 pool 重建把环境
“修到能跑”。对象恢复只属于既有 V02-PRE；PRE 恢复历史或 R1 原始重新认证不合法、
§6.3 资产未闭合，或实时门回升时，V02 只停止并报告，绝不接管 PRE。

若用户将来提供**已经创建、完全专用、预铺 layout** 的独立 META/POOL，可在授权中
另行给出 exact META、POOL、mount、对象上限和清理责任；那属于新 profile，必须先由
Codex 更新任务书。GLM 不得自行切换 pool 或重定义阈值。

### 3.4 可自主修复

允许且必须记录在 `adaptations.tsv`：

- `/tmp` 路径、quoting、日志命名、SSH 瞬时重连；
- task-owned SDK 的头文件/库搜索路径；
- 采集增强、parser bug、精确 PID watchdog；
- 远端纯 runner bug：仅在任何正式 fio 启动前，保留旧 attempt 后最多修一次。

另有一个**预批准且强制**的安全派生，不计为自由改脚本：以固定
`env-snapshot.sh` 为 source，只允许把其中 `sudo` 调用机械改为 `sudo -n`，并把
`pgrep -af juicefs` 的原始命令行输出替换为 §4.2 的脱敏 process identity 索引；完整
unified diff、派生脚本 SHA 和 `bash -n` 必须冻结。禁止其它改动。

### 3.5 禁止自主改变

- base/patch/arm、挂载参数、顺序、次数、runtime、fio 参数、统计口径和判据；
- 对象/health/档位门、drop_caches、gc/compact 纪律；
- pool、META、PG、CRUSH、Ceph/TiKV/网络参数；
- 为完成测试而清理别人数据、杀未知进程、重启服务或扩大 sudo；
- 正式 fio 启动后原地修脚本并接着补行。

---

## 四、步骤 0：必读、静态预飞和长跑控制

### 4.1 必读

执行前完整阅读并在 `preflight-review.md` 逐项确认：

1. 本任务书；
2. `prod-deploy/skills/SYSTEM-SAFETY-SKILL.md`；
3. `prod-deploy/skills/LONG-RUNNING-TEST-SKILL.md`；
4. `prod-deploy/skills/baseline-reproduction-skill.md`：§2.2 清理层级、§2.5
   soft-clean、§3.1 执行顺序、§4.3 判据；这里只理解历史变量控制，不执行其中的
   destroy/format/OSD restart/config set/pkill/credential 示例。本任务采用更新的
   AUTHORING-GUIDE §二.12 白名单和本任务红线；
5. `prod-deploy/skills/TESTING-GUIDE.md`：§1 health/OSD compaction 三指标、§2.2
   每 fio 前 health、§3 cooldown/卷生命周期；
6. `prod-deploy/skills/test-commands-reference.md`：§8 稳态中位数和 §9 数据采集；
7. `prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`：§二通用注意事项、§二.10
   挂载档位、§二.11 数据来源和 §二.12 环境快照/meta 静置检查；
8. `prod-deploy/scripts/FULLBASELINE/FULLBASELINE_V4.sh` 中当前 fio 参数与 cleanup
   口径，只读参考，禁止直接运行其可能 format/auto-mount 的总入口；
9. V01-R1 报告 Codex 复核和本轮固定资产。

### 4.2 runner 静态门

GLM 可写本轮 wrapper，但正式执行前必须保存：

- `bash -n`、shellcheck（若已有）及真实 rc；
- 所有 sudo/ssh/scp/mount/umount/fio/gc/compact/rm/kill 命令清单；
- 禁词扫描：format、destroy、pool delete/create、config set、restart、pkill、killall、
  `rm -rf`、业务 mount 写入；任一命中必须逐行解释，否则禁止启动；
- parser 合成自测：128 job 正常、缺 1 job、空 log、重复
  `(job_id,timestamp,direction)`、randrw 方向缺失；后四类必须拒绝。randrw 中同一
  timestamp 的 read/write 两个不同 direction 是合法数据，禁止误判为重复；
- PID guard 自测：PID/starttime/exe hash 任一变化必须拒绝；
- object parser 自测必须读取 **Ceph pool objects**，禁止用 JuiceFS UsedInodes 替代；
- 所有状态初始 `NOT_RUN`，禁止默认 PASS。

同时从固定 snapshot helper 生成唯一 `env-snapshot-safe.sh`：静态 diff 只允许
§3.4 的两类变化。脱敏 process identity 每个 JuiceFS PID 只落盘
`pid/starttime/exe_path_sha256/exe_sha256/role/raw_cmdline_sha256`，原始 cmdline 只在
pipe 中计算 hash，任何 URI/argv 字节不得写入临时文件或日志。派生脚本或索引不满足
该约束时不得 scp/运行 source helper。

### 4.3 controller 与无人值守

`$CTRL/controller-state.tsv` 每个 phase/arm/mount/round 更新一次，至少包含：北京时间、
attempt、phase、label、PID、status、health、objects、evidence、next。长跑每 30 分钟
保存 heartbeat；预计 10 分钟内结束的步骤每 2～5 分钟检查。

判断完成必须同时看到精确 PID 退出、rc sidecar 和 DONE/STOP marker，不能只看进程
消失。遇安全 STOP 立即收尾/报告，不等待环境自行变绿后偷偷续跑。

长跑正式 runner 必须驻留 157 的 `$REMOTE_OUT`，启动前冻结 runner/launcher SHA，使用
唯一 PID file 同时记录 PID/starttime/exe/argv_sha256；WSL 只做监控。SSH 断线后先重连核对该
身份，匹配则继续观察，绝不重复 launch；不匹配则停止自动恢复并报告。runner 的 trap
只能处理登记的 task fio、task mount 和本轮临时文件，不能 pkill/killall。正式完成以
runner rc sidecar + terminal marker + PID gone 三者为准。

### 4.4 早期只读观察（不再作为本地构建门）

静态预飞通过后，验证 fixed source 和安全派生版 SHA/diff，只 scp
`env-snapshot-safe.sh`；在不传 META 的前提下生成 `pre-early` 快照，再使用授权的
`ssh thailand` 只读执行 §6.1 身份确认，并采集 `ceph health`、PG/OSD 和
`juicefs-data` pool objects 原文。本步骤可在 §5 前执行，也可与本地准备分阶段安排；
它不再阻止 §5 的洁净构建。

- 身份错误、health/PG/OSD 不安全：禁止任何远端 mount/fio，保留证据；本地构建可按
  已有本地授权完成。
- 身份/health 安全但 objects `>3,110,000`：记录 `WRITE_GATE=PENDING`；§5 可继续，
  §6.2A 全过后还可做 §7.1 真只读 ABI，但不得启动任何写能力或环境恢复动作。
- objects `<=3,110,000`：只说明早期样本满足，不替代 PRE/R1 双证据、§6.3 live asset 和
  §6.2B 实时三样本。

无论哪一分支都须生成不传 META 的 `post-early` 快照、做 secret scan 并保存 raw log/rc。
如果没有有效双证据交接、§6.3 资产 PASS 或实时写入门，完成允许的本地/ABI 前置后按
§6.0/§6.2B/§6.3 的精确 INVALID/BLOCKED 状态收口，不能只留一句终态，更不能等待中
偷偷运行 PRE 动作。

---

## 五、本地洁净构建与正确性

### 5.1 输入冻结

复制 §2.1 的全部固定静态资产到 INPUT，保存 source path、mode、size、mtime_ns、SHA，
冻结只读。若用户已指定双交接输入，再把 exact PRE/R1 report、archive、sidecar 和从安全
archive 中提取的两个 receipt 冻结到 `$INPUT/pre-handoff/{pre,recert}/`；保留原路径、
member path、size、mtime_ns 和实算 SHA，禁止仅复制 receipt 而丢弃其来源 archive。
另生成 §6.0 规定的 source map、known deviations 与 canonical verdict。记录本机 hostname、
时间、CPU/内存/磁盘、git/Go/gcc、Docker、librados runtime 和只读 seed status。

### 5.2 三个全新源码 arm

从只读 seed 的 Git object 创建三个不含 hardlink 的独立 clone，detached checkout
`e0032b2ae5e9603403ca955eed7d05426f6f2f8c`，并证明三臂 HEAD 都精确等于该完整
commit。三臂依次标准 apply loadRange；A 再 apply A；B 再 apply B。每次保存
`git apply --check` 和 apply 的 stdout/stderr/rc。

每臂保存：HEAD、base writer blob、before/after status、changed+untracked 并集、完整
binary diff、go.mod/go.sum hash、`git diff --check`。允许 production changed path：

| arm | 允许路径 |
|---|---|
| S | loadRange patch 规定路径 |
| A | S 路径 + `pkg/vfs/writer.go` |
| B | S 路径 + `pkg/vfs/writer.go` |

除下一段登记的固定测试文件和 §5.3 已知 full-vfs 临时副作用外，发现
SQLite/WAL/未知文件立即停止并保留，不得 ignore。

上表是 **production diff guard**。正确性阶段还可临时加入固定测试文件：S/A/B 的
`pkg/vfs/writer_flush_test.go`，以及 B 的 `pkg/vfs/writer_flush_c02_test.go`；复制后
SHA 必须仍等于 §2.1。它们必须在 source-state 中单独登记，不能混入 production diff。
所有 Go test/vet/build 使用只读 module 口径（如 `GOFLAGS=-mod=readonly`）；若 v1.3
官方流程明确使用 vendor，则记录后使用其官方模式，但仍禁止修改 go.mod/go.sum。

### 5.3 本地正确性最小重证

使用固定 v1.3-adapted tests，不允许再次改断言：

```text
U1=TestFullBlockDispatchedWhenSliceIDBecomesReady
U2=TestPartialBlockNotDispatchedWhenSliceIDBecomesReady
U3=TestFlushErrorRecordedWhenSliceIDBecomesReady
U1_MARKER="full block was not dispatched after slice ID became ready"
U3_MARKER="full block with injected flush error was not dispatched"
```

| arm | 必须项目 | 预期 |
|---|---|---|
| S | U2 单次；U1/U3 各总计 5 个独立 `-count=1` 进程 | U1/U3 每次仅目标 marker 失败、U2 PASS |
| A | U1/U2 single；U3 仅观察 | U1/U2 PASS；U3 不作为 A 性能门 |
| B | U1/U2/U3 single、count20、race5 | 全 PASS，无 DATA RACE |
| B+C02 | 十项 single、合并 count10、race3 | 全 PASS，无 DATA RACE |

A 的 U3 也运行一次并保存：PASS 或仅含 U3 目标 marker 的预期失败都可作为“观察”；
panic、timeout、DATA RACE、编译错误或其它测试失败仍判技术无效。B community 的精确
PASS 总数为 3、60、15。

B+C02 的十个固定名称为：

```text
TestC02FullBlockDispatchAfterDelayedID
TestC02MultiBlockDispatchUsesLatestLength
TestC02FlushToFailureIsObservable
TestC02PartialThenFullAfterIDDispatchesOnce
TestC02DelayedNewSliceDoesNotBlockWriteAt
TestC02NonEIONewSliceDoesNotRetryBeforeFlush
TestC02TransientEIORecoversOnFreeze
TestC02PermanentENOSPCAbortsFrozenSlice
TestC02FrozenSliceSkipsCatchupFlush
TestC02ConcurrentIndependentFullBlocks
```

执行前机械证明固定文件的 `^func TestC02` 集合精确等于上表；十项 single/count10/race3
的 PASS 总数分别为 10/100/30，regex 必须锚定完整名称，禁止宽泛吞入其它测试。

B 还必须：
`gofmt -d pkg/vfs/writer.go pkg/vfs/writer_flush_test.go pkg/vfs/writer_flush_c02_test.go`
输出为空、`git diff --check`、`go vet ./pkg/vfs`、隔离 Redis 下
`go test ./pkg/vfs -count=1`。Redis 名称/label 含 RUN_ID，仅 loopback 6379，无 host
network、privileged 或宿主 bind；启动前若 6379 已有 listener，立即
`BLOCKED-BUILD-OR-ABI`，禁止复用或停止未知服务。只管理精确 CID，最后保存 gone。

full `pkg/vfs` 前后都保存完整 tracked/untracked 快照。v1.3 upstream test 已知可能在
`pkg/vfs` 生成 `?_journal=WAL&_timeout=5000&cache=shared`；若本轮新生成，必须证明
before 不存在、路径位于 B clone、是普通文件且非 symlink，保存 stat/size/SHA/file
magic 后只删除这一精确文件并保存 gone。不得 glob、不得删除既存文件；任何其它未知
副作用均为 `V02-NON-COMPLIANT`。最终 source guard 必须洁净闭合，不能只加 ignore。

正确性证据落盘后，再次验证各臂注入 test 的 SHA 与 INPUT 相同；只有同时证明 base 中
原本不存在、路径是 task-created 普通文件且非 symlink，才可逐个删除这些精确 test
副本并保存 gone。固定原件保留在 `$LOCAL/tests/`。进入 Ceph build 时三个源码 arm 的
untracked 集合必须为空，production diff 只剩 §5.2 允许路径。

结果索引必须指向逐命令 raw log/rc；不得复用 V01 的错列表。

### 5.4 三臂 Ceph build provenance

使用 v1.3 实际支持的工具链和相同构建命令生成三枚 Ceph binary。允许把已存在且 hash
已记录的 `librados-dev` deb 用 `dpkg-deb -x` 解到 task-owned SDK；禁止 apt/yum、sudo
安装或改系统 linker。

每臂保存：

- build 命令、完整 stdout/stderr/rc；
- source diff SHA、toolchain、CGO flags、SDK/deb SHA；
- binary SHA256/MD5/size/ELF build-id；
- version、file、ldd 及 Ceph symbols/library 路径；
- S/A/B 三臂 source path guard。

v1.3 Makefile 的 `make juicefs.ceph` 会先在源码根生成 `juicefs.ceph`。每臂 build 前
必须证明该路径不存在；build 成功后把这个**精确的本轮普通文件**移动到 §2.3 对应
`$LOCAL/binaries/juicefs-v02-$RUN_ID-{S|A|B}`，然后保存源路径 gone 和最终 source
guard。禁止复制后把源码根产物留在 untracked 集合，也禁止复用 V01 旧产物。

任一 build/ldd 失败或 provenance 不完整，`BLOCKED-BUILD-OR-ABI`，禁止使用 V01 旧
binary 顶替。

---

## 六、远端分层启动门

### 6.0 V02-PRE 恢复历史 + R1 重新认证双证据门（任何写能力前强制）

本门不阻止 §5，也不阻止在 §6.2A 全过且有独立只读授权时执行 §7.1；但任何
write-capable mount、drop_caches、JuiceFS gc、OSD compact、meta 写探针、正式 fio 或
integrity 前，必须同时达到 `HANDOFF_CORE=PASS`、§6.3 `ASSET_GATE=YES` 和
`HANDOFF_FINAL=PASS`。R1 的 `asset_gate=N/A` 只能暂记
`DEFERRED-TO-V02-6.3`，绝不能直接当作 PASS。

#### 6.0.1 两组输入的真实性与安全检查

1. 授权中同时出现 §2.1 四个 exact report/archive path 和两个 RUN_ID；四个相邻 sidecar
   path 按 §2.1 固定推导。每个 report 内的 `RUN_ID`、文件名与对应 archive 根目录必须
   分别一致，PRE 与 R1 的父子关系必须为
   `R1.pre_run_id=20260818-160041`。禁止 glob、mtime 选择、latest 或替代文件。
2. PRE/R1 report 与 archive 的实算 SHA 必须逐字等于 §2.1 四个 expected SHA；report
   sidecar 必须直接 `sha256sum -c` 成功。两个 archive sidecar 只按 §2.1 的已知远端路径
   偏差读取首个 64 位 hash token，与本地 archive 实算 SHA 比较；token 缺失、多值或 hash
   不等即失败，禁止改写 sidecar 后制造 PASS。
3. 两个 tar 分别保存 member list；去掉单一 staging 根后不得重复、不得有绝对路径、`..`、
   device/FIFO 或 symlink/hardlink 越界。只能解到本轮 task-owned staging，禁止 source、
   exec 或运行其中的 `commands.sh`/脚本。
4. 分别从安全 staging 根执行各自 `SHA256SUMS` 的 `sha256sum -c`，保存 stdout/stderr 和
   **新生成的 rc sidecar**；PRE 应唯一匹配后缀 `handoff/V02-PRE-READY.tsv`，R1 应唯一
   匹配后缀 `handoff/V02-PRE-R1-READY.tsv`。两个 receipt 实算 SHA 必须分别等于 §2.1
   expected SHA。archive 内旧 `SHA256SUMS.check.log` 只作旁证，不能替代本轮实校验。
5. 把 exact report、archive、原 sidecar、member list、manifest 实校验和两个 receipt
   冻结到 `$INPUT/pre-handoff/{pre,recert}/`，另写 `handoff-source-map.tsv`；不得修改或
   重新打包历史证据。

#### 6.0.2 PRE 恢复历史门

PRE 只负责解释对象从 7.46M 降到 2.43M 的恢复动作和身份，不再用它后补的摘要冒充三次
低对象原始证据。机械要求：

1. PRE report 和 receipt 状态均为 `READY-V02-LOW-OBJECT`，run_id、report_path、
   evidence_root、receipt SHA、pool=`juicefs-data`、pool_id=3 与 META identity hash 闭合；
2. receipt 的 `taskbook_sha256` 必须等于当前
   `V02-PRE-object-pool-recovery-and-classification.md` 实算 SHA
   `8f180305e56550c8d8882e73132d6063cc03e1c81b441d901f02a9e98dc7e286`；
3. 本次恢复累计 `gc_compact_passes=1`、`gc_scan_passes=0`、`osd_compact_rounds=1`、
   `gc_delete_passes=0`、`performance_data=NONE`、`forbidden_actions=0`；报告明确未执行
   destroy、format、pool/PG/CRUSH/config 修改、restart、fio、`gc --delete` 或 compact
   内部已披露回收之外的删除；
4. PRE archive manifest 本轮实校验通过。其 `objects/object-trace.tsv` 缺少 compact 后三次
   低对象原始样本是**已登记历史缺口**，只允许由下一节固定 R1 原始样本补足；不得据此
   声称 PRE archive 自身完整，也不得接受其它缺口。

全部成立才记 `PRE_HISTORY=PASS`。

#### 6.0.3 R1 原始重新认证与规范化

R1 receipt 是带已知格式缺陷的索引，不是可直接信任的规范 receipt。V02 必须从 archive
原始文件独立生成 `$INPUT/pre-handoff/recert-canonical.tsv`，每行包含
`field/source/member/source_sha/raw_value/canonical_value/verdict`：

1. R1 report/receipt 的 `status=READY-V02-LOW-OBJECT`、`run_id=20260819-102825`、
   `pre_run_id=20260818-160041`；receipt 中 `taskbook_sha256` 只作为 PRE ancestry 指针，
   **不**表示 R1 有独立任务书或继承了任何授权；
2. 分别解析 `samples/ceph-df-{1,2,3}.json` 中名字精确为 `juicefs-data` 的唯一 pool；三份
   原文必须都是 `id=3`、`objects=2434623`、`stored=639177654272`、
   `max_avail=28541886398464`，且 objects 均 `<=3,110,000`、max_avail `>=10 TiB`；禁止从
   receipt 或 snapshot 复制数值覆盖 JSON；
3. 同编号 `health-{1,2,3}.txt` 必须精确 `HEALTH_OK`，`pg-stat-*` 必须为全部 33 PG
   active+clean，`osd-stat-*` 必须为 6 up/6 in；每组四文件 archive mtime 差不得超过 2s；
4. 安全提取后以 `stat -c %Y` 取得三个 `ceph-df` epoch，间隔必须分别为 143s 和 158s
   （且都 >=120s）；保存 epoch、CST/ICT 转换和原始 stat 输出。不得使用 receipt 中字面量
   `$(date +%s)`；
5. `identity/crush-map.bin` SHA、snapshot 中 config hash、OSD up_from、GC_BIN SHA 与 PRE
   一致；`identity/all-juicefs-mounts.txt` 为空且实时 §6.2A 仍证明 PRE drain/task process
   gone。META identity 由 PRE receipt 提供并必须在本轮读取受保护 META 后重新计算匹配；
6. R1 的三种 `max_avail` 摘要值互相有微小差异是已登记抄写缺陷，规范值只取三份原始
   JSON 的 `28541886398464`；它远高于 10 TiB，但差异必须写入 known deviations，禁止
   静默修正历史文件。

只有上述原始证据全部通过才记 `RECERT_RAW=PASS`。以下 R1 缺陷仅对 §2.1 固定 hash
白名单允许，并逐项写入 `$INPUT/pre-handoff/known-deviations.tsv`：

| 已知缺陷 | V02 处理 |
|---|---|
| receipt member 名为 `V02-PRE-R1-READY.tsv` | 只按固定唯一后缀读取，不改名 |
| `asset_gate=N/A (...)`，archive 中 `assets/check.tsv` 为 0/0/0 | 只表示无 mount；资产门延后 §6.3，禁止解释为资产缺失或 PASS |
| `protected_mount_unchanged=YES (...)` 非规范值 | 不截断为 YES；以 R1 mount 原文和 §6.2A/§6.2B 实时身份重证 |
| `ready_epoch=$(date +%s)` | 丢弃该字段，以三份原始样本 mtime 规范化 |
| 缺 `report_path/evidence_root` | 由 §2.1 exact path、archive member 和 source map 补来源，不改 receipt |
| receipt/snapshot 的 `max_avail_last` 与 JSON 不同 | 只以原始 JSON 为权威并披露差异 |
| archive sidecar 保留远端 `/tmp` 路径 | 只允许 §6.0.1 的 hash-token 比对 |
| 报告称授权“继承” | 不承认授权传递；必须另有 §3.2 V02 新授权 |

发现表外缺陷、任一 expected hash/member/manifest/raw 值不符、无法机械解析或 source map
不唯一，终态 `INVALID-V02-PRE-HANDOFF`，不得由 GLM 扩大白名单。

#### 6.0.4 core/final 两阶段裁定

在 `PRE_HISTORY=PASS`、`RECERT_RAW=PASS` 且所有已知缺陷均精确命中白名单后，写：

```text
HANDOFF_CORE=PASS
ASSET_GATE=DEFERRED-TO-V02-6.3
HANDOFF_FINAL=PENDING
```

这只允许继续 §7.1 真只读 ABI/read smoke。B smoke 按 §6.3 从现存 test_dir 保存真实 sorted
file list/size/inode/抽样只读 hash；通过后另写不可覆盖的 `handoff-final.tsv`：

```text
HANDOFF_CORE=PASS
ASSET_GATE=YES
ASSET_SOURCE=V02-6.3-LIVE-B-READ-ONLY
HANDOFF_FINAL=PASS
```

§6.3 失败不得回写 core 或历史 receipt，状态 `BLOCKED-SAFETY-GATE`。双证据缺失、非 READY
或实时对象数回升为 `BLOCKED-V02-PRE`；证据互相矛盾或不满足本节真实性要求为
`INVALID-V02-PRE-HANDOFF`。receipt/重新认证都不是当前状态免检令，也不传递授权；两类
失败均禁止 V02 执行恢复动作。

### 6.1 连接与身份

使用用户已确认可用的 `ssh thailand`。第一步只读记录 hostname、解析 IP、时间、内核、
CPU/内存/磁盘和当前用户，确认它是预期客户端 157。身份不符立即停止，不尝试其它
主机。连接/传输在两次有界重试后仍失败则 `BLOCKED-REMOTE-OR-NETWORK`，保存每次
stdout/stderr/rc，禁止改试其它 host。scp 三枚 binary 到三个唯一
`REMOTE_BIN_{S,A,B}` 后重算 SHA，必须与本地一致。

### 6.2 两层集群与共享业务硬门

#### 6.2A ABI-only 门

只为 §7.1 的真只读 mount 判定；不需要 objects `<=3,110,000`，也不需要双证据
`HANDOFF_FINAL=PASS`，
但必须有本轮明确的只读 ABI 授权，并在每一臂 mount 前保存/机械判定：

1. `ceph health` 精确 `HEALTH_OK`；所有 PG active+clean、全部 OSD up/in；
2. `juicefs-data` pool objects 可解析，pool `MAX AVAIL >=10 TiB`；禁止 UsedInodes 冒充；
3. pool_id、pg_num/pgp_num、CRUSH map hash、Ceph config hash 已冻结；
4. OSD `compact_running=0`、`compact_queue_len=0`、`kv_sync_lat` 满足 skill 安全线；
5. 没有未知 fio/gc/compact；WekaIO、BeeGFS、K8s 和共享 NIC 无异常/竞争窗口；
6. `/mnt/juicefs` mountinfo、PID、starttime、脱敏 options/role、raw cmdline SHA256、exe
   hash 和业务路径 stat 冻结且与早期样本一致；禁止 raw argv/META 落盘；
7. `/mnt/juicefs-v02` 未挂载且为空；`/mnt/juicefs-v01-drain`、
   `/mnt/juicefs-v02-pre-drain` 和 PRE/R1 task process 均不存在；
8. 本轮 META/POOL 明确属于允许只读核验的测试卷，不是业务卷；157 `/tmp` 可用
   `>=5 GiB`，WSL `$LOCAL` 文件系统可用 `>=5 GiB`。

本门任一失败禁止远端 mount；不得为通过本门执行环境修复。对象数高只记录
`WRITE_GATE=PENDING`，不单独否决只读 ABI。

#### 6.2B 完整写入/性能门

在 §7.1 全部卸载、§6.0 `HANDOFF_CORE=PASS`、§6.3 `ASSET_GATE=YES` 且
`HANDOFF_FINAL=PASS` 后重新采集，不得复用 R1 或 ABI 前样本。除 §6.2A 全部条件仍成立
外，还必须：

1. 以至少 120 秒间隔取得连续三次有效 Ceph pool 样本，三个 objects 均
   `<=3,110,000`；各样本 health/PG/OSD 全绿；
2. 三次样本期间 pool_id、PG/PGP、CRUSH/config hash、主挂载 identity 不变；
3. PRE receipt 中的 META identity、PRE/R1 中的 pool_id 与实时身份一致，所有 PRE/R1
   drain/task mount/process 仍 gone；
4. `storage_test`、`rw_test`、`mseqread` 已由 §6.3 的只读 B smoke 证明完整；
5. 没有未知 fio、外部测试写入或共享业务竞争；空间门仍满足。

PRE/R1/对象条件失败为 `BLOCKED-V02-PRE`；其它 health、身份、资产、容量或共享安全门失败
为 `BLOCKED-SAFETY-GATE`。V02 禁止 drain、额外 gc、清卷、重启、参数调整或删除数据后
重查。只有本门全过，才能进入 §6.4～§6.5、§7.2、§8 和 §十一。

### 6.3 既有数据集硬门

此门在 §7.1 的 B 只读 smoke mount 内执行；§6 阶段不为它额外提前 mount，也不使用
主业务挂载。检查：

```text
test_dir/storage_test.0.0 ... storage_test.127.0   精确 128 个，大小一致
test_dir/rw_test.0.0      ... rw_test.127.0        精确 128 个，大小一致
test_dir/mseqread/mseqread.0.0 ... .15.0           精确 16 个，大小一致
```

保存 sorted file list、size、inode 和抽样只读 hash。不得 layout、create-on-open、
format 或修改文件数量来补门。`assets/check.tsv` 中历史 0/0/0 只表示 R1 没有 mount，禁止
复用。缺失即 `BLOCKED-SAFETY-GATE`，并否决 §6.2B；全部符合才按 §6.0.4 写
`ASSET_GATE=YES` 与 `HANDOFF_FINAL=PASS`。

### 6.4 正式写入前环境快照

§7.1 真只读 ABI 使用独立的 `env-snapshot-abi-{pre,post}.txt`；它不能冒充正式 pre。
§6.0 `HANDOFF_FINAL=PASS`、§6.2B 和 §6.3 全过后，在第一次 write-capable mount、
JuiceFS gc、OSD compact
或 fio 之前，使用 §4.2 已冻结的 `env-snapshot-safe.sh` 且**不传 META**，生成
`$REMOTE_OUT/env-snapshots/env-snapshot-pre.txt` 和脱敏 process identity。另外使用 SHA
已核验的 `"$REMOTE_BIN_B" config "$META"`，只经内存 parser 输出预登记的非敏感 format
字段到 `volume-config-safe-pre.json`（例如 block size、compression、trash days、storage
type；禁止输出 access/secret key 和完整认证 URL）。

META 从既有受保护配置读取，不回显；`commands.sh` 只记录 `$META` 占位符。组合快照必须
有 PRE/R1 handoff identity、health、ceph df、三个实时 object 样本、OSD up_from、mount/
process、client/fio 和 safe volume format 各段；缺段或 secret scan 命中时停止。final
teardown 无论终态为何都必须用相同脚本和 allowlist parser 生成同口径 `post` 组合快照。

### 6.5 三指标 baseline cooldown

取得本轮明确 sudo/OSD compact 授权后，在正式矩阵前执行一次 skill 规定的 OSD compact
（不是 JuiceFS gc），并轮询所有 OSD：`compact_running=0`、
`compact_queue_len=0`、`kv_sync_lat avg<2ms`；同时 health 仍 OK。无法完整采集任一 OSD
不得用“未见异常”代替全绿。完成后再次确认 objects `<=3,110,000`、pool/main mount
identity 不变；否则 `BLOCKED-V02-PRE` 或 `BLOCKED-SAFETY-GATE`，不得补做 PRE 动作。

---

## 七、远端 ABI 与只读 read smoke

### 7.1 三臂真只读 ABI/read smoke

本节只要求 §6.1 和 §6.2A；可在双证据 final 未 PASS 或 objects 高于 3.11M 时先行，但绝不产生
性能结论。先生成 ABI-only pre snapshot；按 S→A→B 依次执行，每臂使用专用 mount、
完全相同参数并在 smoke 后卸载：

```text
--read-only --no-bgjob --backup-meta 0
--max-uploads 150 --cache-size 0 --max-fuse-io 256K
```

命令静态审计必须证明三臂都有上述 flags，且没有后台清理、写测试、drop_caches、
JuiceFS gc 或 OSD compact。保存：binary version/ldd/SHA、mount stdout/stderr/rc、
mountinfo、PID/starttime/脱敏 options/role、raw cmdline SHA256、exe hash、`.stats` 可读、
已知 layout 文件 `stat`、16 MiB 只读 `dd` 的 stdout/rc、优雅 umount rc 和 mount gone。
B smoke 同时完成 §6.3 文件清单。不得写测试文件或据此声称可写 ABI 已验证。

三臂结束后生成 ABI-only post snapshot并逐项比较；任何 mount/PID 未退出都禁止后续阶段。
任何一臂 ABI/mount/read 失败为 `BLOCKED-BUILD-OR-ABI`；不能只测 B 或跳过 S/A 后进入
性能。B smoke 必须实际闭合 §6.3，不能用 R1 的 `N/A` 替代。若 ABI 全过但
§6.0 `HANDOFF_FINAL`/§6.2B 未过，安全收尾为 `BLOCKED-V02-PRE` 或本节规定的更具体
INVALID/BLOCKED 状态，不得继续等待或自行恢复对象池。

### 7.2 写测前 meta 静置检查

只有 §6.0 `HANDOFF_FINAL=PASS`、§6.2B、§6.3、§6.4 和 §6.5 全过才可开始。使用 A binary 新建一个不进入
正式矩阵的 write-capable `Q-A-t1` mount，参数与 §8 性能 mount 相同且不得含
`--read-only/--no-bgjob`；先按 §8.2 完成两轮 mseqread ns/B 门，失败重挂规则同样为
t1/t2/t3、每次换 label。随后：

1. 每次探针前保存 health、objects、OSD compact 三指标、A/task mount 与主挂载
   identity；objects 必须仍 `<=3,110,000`，再在 157/150/151/152 四节点 drop_caches。
   超门停止，不允许靠追加 gc 恢复后挑高点续跑。
2. 对既有 `storage_test` 运行与 §8.4 randwrite 完全相同的参数，仅 runtime 改为 60s；
   使用唯一 bw prefix，必须保存 128 份 per-job log、fio 全文和 rc。
3. 同步保存 `.stats` 首末样本与 ns 时间戳，从
   `meta_ops_durations_histogram_seconds_total` 取 delta，并按
   `delta / ((last_ns-first_ns)/1e9)` 计算 meta 提交率。计数器缺失、reset 或 delta<0
   视为 probe 无效，不得猜字段。
4. 每个 60s 写探针后执行一次 §8.5 的 gc/compact/cooldown，确认 health 和 objects；
   objects 触发 §8.6 硬门时立即停止。
5. 首次 rate `>=8000/s`：记录 `META_PROFILE=DAYTIME`，结束静置检查。
6. 首次不足：保持同一 A mount/PID，等待 30 分钟；等待期间每 10 分钟记录 heartbeat、
   health、objects 和 identity，然后重做步骤 1～4。最多四次等待/重查（累计最多 2h，
   即最多 5 个 probe），不得缩短等待或挑选中间高点。
7. 最终仍 `<8000/s`：记录 `META_PROFILE=DEGRADED` 后仍按指南完成正式矩阵，但终态最高
   只能 `RESULTS-V131-DEGRADED-META-ONLY`，不得给出生产 PASS/FAIL-B 归因。
8. 静置检查结束后优雅卸载 Q-A，确认 mount gone；再做一次 baseline cooldown。正式
   矩阵启动前 objects 必须重新回到 `<=3,110,000`，否则
   `BLOCKED-SAFETY-GATE`。

静置探针全部写入 `$REMOTE_OUT/quiescence/` 和 `quiescence-results.tsv`，不得混入
27+27 个正式 run。若 S/A 控制后来无效，仍优先判 `INVALID-S-OR-A-CONTROL`；正确性或
安全事件仍优先判相应 FAIL，而不是用退化态标签遮盖。

---

## 八、正式 S/A/B 性能矩阵

本节开始前再次机械确认 §6.0 `HANDOFF_FINAL`/§6.2B/§6.3/§6.4/§6.5 均为 PASS；任何一个为
NOT_RUN、PENDING 或仅引用 PRE/R1 旧样本都禁止启动第一轮 fio。

本节、§7.2 静置探针和 §十一 integrity 中的“fio 前 health”都必须 source INPUT 中
SHA 已冻结的 `ceph-health-check.sh` 并实际调用 `check_ceph_health`；runner 不得定义
同名空函数或只用 `echo HEALTH_OK` 代替。每次调用的 stdout/stderr/rc 单独落盘。

### 8.1 Latin-square 固定顺序

九个逻辑位置，每个位置必须是新 mount：

```text
block 1: S1 → A1 → B1
block 2: B2 → S2 → A2
block 3: A3 → B3 → S3
```

每个 arm 恰好出现在早/中/晚位置各一次。禁止根据前一轮数值换序、跳臂或补选“好看”
mount。只有全部九位置有效才可出正式 arm-level 结论。

### 8.2 每个新 mount 的 ns/B 档位门

1. 用该 arm binary 按固定性能参数
   `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` 挂载 `/mnt/juicefs-v02`；不得沿用
   ABI-only 的 `--read-only/--no-bgjob`，保存完整脱敏 options 和 identity。
2. 每轮探针前分别保存 `ceph health`、pool objects/OSD 三指标、mount/主挂载 identity，
   并在 157/150/151/152 四节点逐一 drop_caches；任一缺失或失败不得启动该轮。
3. 对既有 `mseqread` 16×固定文件执行两轮 180s 只读探针：256K、16 job、psync、
   direct=1、time_based、group_reporting；每轮使用唯一 `--write_bw_log` 和
   `--log_avg_msec=1000 --kb_base=1024`，保存精确 16 份非空 per-job log。
4. 每轮保存 `.stats` pre/post，按已验证公式计算：

```text
ns/B = [Δduration_sum / Δduration_total]
       / [Δread_size_bytes_sum / Δfuse_read_ops_total] × 1e9
```

5. 两轮 ns/B 的 median 固定定义为 `(v1+v2)/2`；它相对历史 3.287 ns/B 的绝对
   偏差 `<=10%` 才 PASS。
6. FAIL 后优雅卸载，以新 label 重挂；每逻辑位置最多 3 次（t1/t2/t3），不得复用 label。
7. 三次都失败或指标不足，`INVALID-MOUNT-TIER-OR-DRIFT`；停止矩阵。
8. gate 后重新冻结 PID/starttime/exe hash；效应项全程任一变化，该位置全部无效。

禁止用 raw mseqread 吞吐、fio 汇总或旧 label 累计值替代 ns/B。

### 8.3 每个有效 mount 的固定负载

顺序不可改：

```text
randwrite r1 → cleanup → r2 → cleanup → r3 → cleanup
randrw    r1 → cleanup → r2 → cleanup → r3 → cleanup
```

每个 fio 前必须：

1. source INPUT 中固定 SHA 的 `ceph-health-check.sh` 副本并调用
   `check_ceph_health`，保存原文和 rc；禁止用 runner 自写的同名空函数替代；
2. 157、150、151、152 四节点 `drop_caches`，逐节点保存命令/rc；
3. 保存 pool objects/stored/max_avail、PG/OSD、compaction 三指标；
4. 保存 mount PID/starttime/脱敏 options/raw-cmdline-SHA/exe SHA 与 `/mnt/juicefs`
   主挂载 identity；
5. 确认无未知 fio 和共享业务异常。

其中本轮 fio 启动前 objects 必须 `<=3,110,000`。这是每轮有效性门，不只检查矩阵第一轮；
超门立即停止，禁止增加 cleanup pass、等待后只补跑有利轮或把该轮标成正式数据。

### 8.4 fio 固定参数

`randwrite`：

```text
--directory=$TEST_DIR --name=storage_test
--filesize=1G --size=1G --bs=256k --rw=randwrite
--ioengine=libaio --iodepth=128 --numjobs=128
--direct=1 --fallocate=none --openfiles=128
--group_reporting --time_based --runtime=180
--write_bw_log=<本轮唯一前缀> --log_avg_msec=1000 --kb_base=1024
```

`randrw` 除 `--name=rw_test --rw=randrw` 外完全相同。禁止 `create_on_open`、重新
layout、`per_job_logs=0` 或覆盖不同数据集。

每轮必须保存 fio 全文、rc、start/end ns、全部 128 个 per-job bw log、PID/health/
objects/I1/NIC/进程 CPU-RSS 和只读 OSD/TiKV 指标。timeout 只能精确终止本轮登记的
fio PID/process group，禁止 pkill/killall。

### 8.5 每个写轮后的 cleanup

这里的“写轮”包括全部 27 轮 randwrite 和全部 27 轮 randrw。每一轮都按当前
FULLBASELINE/skill 口径执行且逐步落盘：

1. 用当前 mount 对应且 SHA 已核验的 arm binary 执行一遍 `gc --compact "$META"`
   （只针对已授权测试卷；命令记录仍以 `$META` 占位）；
2. Ceph OSD compact；
3. 轮询所有 OSD 至 `compact_running=0`、`compact_queue_len=0`、kv sync 安全；
4. health 恢复 `HEALTH_OK`；
5. 再记录 objects 和 mount identity；只有 post-cleanup objects `<=3,110,000` 才可进入
   下一写轮。

禁止用 OSD restart 代替 compact，禁止额外 gc pass、destroy/format 或 pool 重建。
cleanup 超时、health 不恢复或 objects 未回到 3.11M 门，保存 STOP 并
`BLOCKED-SAFETY-GATE`；这属于 V02 写后状态，不回跳 V02-PRE。

一个 logical position 的六轮 fio 及六次 cleanup 全部完成后，再保存一次 mount
PID/starttime/exe、health、objects 和主挂载 identity，然后优雅卸载并证明
`/mnt/juicefs-v02` mount gone。只有该证据闭合才进入下一个 position；禁止在仍挂载时
覆盖挂载或把同一进程冒充“新 mount”。

### 8.6 对象与运行时 watchdog

fio 期间每 30 秒采集 pool objects、stored/max_avail、health、mount identity、进程 RSS
和 `juicefs_used_buffer_size_bytes`：

- 连续三次解析失败；
- objects `>8,000,000`；
- used buffer `>4 GiB`；
- health 连续三次非 OK；
- mount PID/starttime/exe 变化；
- `/mnt/juicefs` identity 变化或共享业务异常；

任一触发即优雅停止本轮登记 fio，保存证据，停止后续矩阵。禁止等待指标回落再续跑。

---

## 九、统计口径与数据来源

### 9.1 单轮稳态值

只从该轮全部 per-job bw log 计算：

1. 验证精确 128 份、非空、job ID 唯一；
2. 验证每文件 timestamp 单调，`(job,timestamp,direction)` 唯一；randrw 同 timestamp
   的不同 direction 合法。按 timestamp+direction 对齐，同一秒跨 job **求和**；已
   证明文件正常时某 job/direction 某秒无行按 0 计入 stall，不得把整秒从序列删除；
3. 180 秒窗口截掉开头 1/4，即前 45 秒；
4. fio group runtime 必须为 180s±5s、bw log 覆盖至少 175 个不同秒，截断后至少 130
   个 steady 秒，否则该 run 无效；
5. bw log 在固定 `kb_base=1024` 下按 KiB/s 解析，跨 job 求和后除 1024 得 MiB/s；对
   剩余逐秒总带宽取中位数；
6. 同时保存 p10/p50/p90、CV、零/低带宽 stall 比例；主值只用 p50；
7. randrw 按 direction 分别求 read/write，绝不相加；
8. fio `Run status group` 仅作物理量级 sanity，不作为主值。

禁止单个 bw log ×128、禁止取平均替代稳态中位、禁止删除低轮或超网卡线速仍接受。

### 9.2 mount 与 arm 级

- 每 mount 的三轮稳态值排序后取第 2 个；
- 每 arm 的三个 mount-level 值排序后再取第 2 个；
- 报告同时列出全部 27 个 randwrite 和 27 个 randrw run-level 值，不只给最终值；
- 任何缺轮、缺 job log、时间窗不足的 mount 无效，不能用另一 mount 多跑补齐。

### 9.3 结果表

`results-raw.tsv` 每行一个正式 fio run，至少包含：

```text
block	position	arm	mount_label	mount_attempt	item	round	fio_rc	jobs_expected	jobs_found	steady_p50_mib_s	read_p50_mib_s	write_p50_mib_s	nsb_gate	pid_stable	health_ok	objects_start	objects_peak	log_dir	valid
```

所有列物理宽度一致；`valid` 只能 YES/NO。每个数字必须指向 log_dir 中的原始文件。

`quiescence-results.tsv` 每个 probe 一行，固定列：

```text
attempt	label	first_ns	last_ns	meta_total_first	meta_total_last	rate_per_s	fio_rc	jobs_found	health_ok	objects_peak	cooldown_ok	raw_dir	valid
```

`results-mechanical.tsv` 每个最终判据一行，固定列：

```text
criterion	source_file	source_field	input_values	formula	threshold	actual	verdict
```

### 9.4 判据到原始数据的固定映射

| 判据 | 唯一主来源 | 字段/算法 |
|---|---|---|
| 固定输入 | `$INPUT/input.sha256`、`input.stat.tsv` | path/size/SHA 全匹配 |
| PRE/R1 双交接 | `$INPUT/pre-handoff/{pre,recert}/` 原件及 `handoff-source-map.tsv`、`known-deviations.tsv`、`recert-canonical.tsv`、`handoff-final.tsv` | expected SHA、双 RUN_ID、PRE 历史、R1 raw、§6.3 live asset 与 core/final 裁定 |
| source/build provenance | `$LOCAL/meta/source-state-*.tsv`、`binaries/provenance.tsv`、逐臂 build log/rc | HEAD/diff/path/binary SHA/rc |
| 本地 correctness | `$LOCAL/results-correctness.tsv` 指向的逐命令 log/rc | target PASS/FAIL/marker/rc 精确计数 |
| early/ABI/full 安全门 | `$REMOTE_OUT/preflight/{early,abi,formal}/` 的 health/pool/gate 原文 | ABI 与 write gate 分列；formal 含三次实时 objects |
| 环境漂移 | ABI-only pre/post、正式 `env-snapshot-{pre,post}.txt`、`volume-config-safe-{pre,post}.json` | health/df/objects/up_from/mount/config 逐段 diff |
| meta profile | `quiescence-results.tsv` 指向的 `.stats` 原样本 | `Δmeta_total/Δseconds`，阈值 8000/s |
| ABI/read | `$REMOTE_OUT/abi/<arm>/` 的 sha/ldd/mountinfo/dd/rc | local=remote SHA、ldd、dd rc、mount gone |
| ns/B | `$REMOTE_OUT/mounts/<position>/<attempt>/gate.tsv` 指向两组 stats pre/post | §8.2 公式、两轮中位、3.287±10% |
| 单 run 带宽 | `results-raw.tsv:log_dir` 下 128 个 bw log | 同秒求和、截前45s、direction、p50 |
| arm/B-S/B-A/randrw | `results-mechanical.tsv` 引用全部 `results-raw.tsv` 行 | run→mount→arm 两级中位及 §10 公式 |
| watchdog | 每 run `objects-watch.tsv`、`mount-identity.tsv`、`health.tsv`、`buffer.tsv` | max/连续失败/PID-starttime-exe |
| cooldown | 每 run `cleanup/compact-status.tsv`、`gc.log/.rc`、`health-after.txt` | 三指标全绿、rc、health |
| integrity | `$REMOTE_OUT/integrity/fio.log/.rc`、4 bw logs、verify-errors.txt | rc=0、4 logs、verify error=0 |
| archive | local/remote `SHA256SUMS.check.log/.rc`、member list、archive sha | hash 全通过、member 合法且无重复 |

任何实现生成不同文件名，必须在正式 fio 前冻结 `evidence-path-map.tsv`，逐项给出上表
逻辑名到实际路径的 1:1 映射；报告不得只引用聚合表而不引用其 raw source。

---

## 十、机械判据与挂载档位压力测试

阈值来源在执行前冻结到 `$INPUT/threshold-sources.tsv`：`1653 MiB/s` 和“至少 +200%”
来自 `prod-deploy/doc/perf-tasks/03-8-deepseek-randwrite-256k-flush-fix.md` 的预登记主判据
（历史 stock 551 MiB/s ×3）；randrw `0.944` 来自 V01 §7.5 沿用的 03-8 ±5.56%
安全带；B/A `0.95` 是本任务预登记的 5% 工程非劣线；档位 `0.70` 与 3.287±10%
来自 AUTHORING-GUIDE §二.10。S `<1000` 且 max `<1200` 是本任务为了确认“当前窗口仍为
可鉴别塌态”而设置的保守控制门，不冒充历史置信区间。

### 10.1 全局有效性门

只有以下全部成立才进入性能状态映射：

- 本地 S/A/B correctness/build provenance 全闭合；
- 三臂远端 ABI/read smoke 全通过；
- 指定 PRE/R1 双证据的来源、expected hash、manifest、known deviations、R1 raw
  canonicalization 与 §6.3 live asset 闭合，`HANDOFF_FINAL=PASS`，且 §6.2B 三个实时
  objects 样本全过；
- 九个逻辑位置全部完成并通过 ns/B 门；
- 每位置六个正式 fio run 全有效，PID/hash 全程不变；
- health、objects、配置、主挂载和共享业务守卫无变化；
- 没有 EIO、panic、corruption、timeout 或 watchdog STOP。

标准 PASS/FAIL-B 状态还要求 `META_PROFILE=DAYTIME`。若上述全局门与 S/A 控制均有效、
但 §7.2 最终为 `META_PROFILE=DEGRADED`，仍完整报告所有机械数值和方向，终态固定为
`RESULTS-V131-DEGRADED-META-ONLY`；不得把退化环境下的 B 高/低值归因为补丁。

否则只能是 BLOCKED/INVALID/PARTIAL/NON-COMPLIANT。

### 10.2 S 与 A 控制门

S randwrite：

```text
S_arm_p50 < 1000 MiB/s
且三个 S_mount_p50 的最大值 < 1200 MiB/s
```

A randwrite：

```text
A_arm_p50 >= 1653 MiB/s
```

S 不塌或 A 不恢复：`INVALID-S-OR-A-CONTROL`。不得用历史 551/3000 替代本轮控制。

### 10.3 B 恢复门

```text
B_arm_p50 >= 1653 MiB/s
B_arm_p50 / S_arm_p50 >= 3.00
每个 B_mount_p50 > max(三个 S_mount_p50)
```

同时无正确性/安全事件才叫观察恢复。再做最坏档位压力：

```text
recovery_stress_ratio = 0.70 * B_arm_p50 / S_arm_p50
```

- `recovery_stress_ratio >=3.00`：恢复幅度对历史 -30% 坏档仍稳健；
- 原始比值 >=3 但 stress <3：只能报告观察恢复、幅度对档位敏感，不得写稳健 3×；
- 原始比值 <3 或 B<1653：`FAIL-B-V131-NO-RECOVERY`，除非控制门/档位门本身无效。

### 10.4 B/A 非劣的能力边界

```text
r = B_arm_p50 / A_arm_p50
```

- 稳健非劣：`0.70 * r >=0.95`；
- 观察非劣但不可稳健判定：`r >=0.95` 且 `0.70*r <0.95`；
- 稳健劣于 A：`r/0.70 <0.95`；
- 其余：A/B 档位不确定区。

这条故意严格：历史 mount tier 最大可造成约 1/0.70=1.43 倍臂间比，三 mount/arm
不能凭空支持 5% 精密非劣。若只达到观察非劣，最终状态必须
`PASS-B-V131-RECOVERY-A-COMPARISON-INCONCLUSIVE`，不能写“A/B 等价”。

### 10.5 randrw

read/write 分别计算 `B/A`，观察安全带均为 `>=0.944`，并各自做同样 ±30% 压力区间。
randrw 任一方向明显回退必须标红并阻止生产替换；不能用 randwrite 恢复覆盖。

### 10.6 状态映射

| 条件 | 状态 |
|---|---|
| B 恢复稳健 + B/A 稳健非劣 + randrw/verify 无异常 | `PASS-B-V131-RECOVERY-A-NONINFERIOR-ROBUST` |
| B 恢复成立，但 B/A 落档位不确定区或仅观察非劣 | `PASS-B-V131-RECOVERY-A-COMPARISON-INCONCLUSIVE` |
| B 恢复成立，且 B 相对 A 稳健劣于 5% 界 | `PASS-B-V131-RECOVERY-BUT-A-INFERIOR` |
| 控制有效但 B 不满足恢复门 | `FAIL-B-V131-NO-RECOVERY` |
| EIO/corruption/process/safety 技术事件 | `FAIL-B-V131-CORRECTNESS-OR-SAFETY` |
| 全局门和 S/A 控制有效，但最终 meta profile 仍退化 | `RESULTS-V131-DEGRADED-META-ONLY`（优先于性能 PASS/FAIL-B） |

若恢复原始门成立但 -30% stress 不成立，报告必须同时写“观察恢复、稳健 3× 不成立”，
由 Codex决定工程口径；不得升级为最高 PASS。

---

## 十一、B 数据完整性验证

性能矩阵全部安全完成后，在一个新的 B mount 上执行；PRE/R1 `HANDOFF_FINAL`/full write gate 仍须
有效，并再次通过 objects/nsB/identity/health 门。只允许创建 `$INTEGRITY_DIR`，realpath
必须位于 `$TEST_DIR` 且 basename 精确含 RUN_ID。

integrity fio 前必须再次保存 health、pool objects/OSD 三指标、B mount 与主挂载
identity，且 objects `<=3,110,000`，再在 157/150/151/152 四节点逐一 drop_caches；任一项
失败不得启动。其
`--write_bw_log` 必须产生精确 4 份非空 per-job log，缺失即校验无效。

固定口径：

```text
fio --name=v02verify --directory=$INTEGRITY_DIR
    --rw=randwrite --bs=256k --filesize=4G --size=4G --numjobs=4
    --direct=1 --ioengine=libaio --iodepth=32 --fallocate=none
    --verify=xxhash64 --verify_fatal=1 --do_verify=1 --group_reporting
    --write_bw_log=<唯一前缀> --log_avg_msec=1000 --kb_base=1024
```

保存 write/verify 全文、rc、所有 verify error、目录 before/after、文件清单和 mount
identity。rc=0 且零 verify error 才通过。

清理仅允许删除本轮精确 `INTEGRITY_DIR`：删除前记录 realpath、mount、文件清单，禁止
变量为空、glob 扩大或 `rm -rf` 未解析路径。清理后执行一遍授权的 gc/compact/cooldown，
并确认 health/objects 安全。任何路径守卫失败宁可保留目录，不得删除。

若因时间但非安全原因未执行，状态只能 `PARTIAL-V02`；若执行后校验失败则
`FAIL-B-V131-CORRECTNESS-OR-SAFETY`。

---

## 十二、attempt、暂停与恢复

1. 本地 build/correctness 最多两个正式 attempt；每次全新子目录，旧证据保留。
2. 远端正式 attempt 最多两个；只有**任何正式 fio 启动前**的纯 wrapper/SSH 瞬时
   故障才允许在同一授权下新 attempt。
3. 一旦产生任一正式 fio 数据，不得修改脚本后续跑拼包；保存为 partial。是否开新
   attempt 由用户/Codex决定。
4. PRE/R1 未 READY、缺失或实时对象门失败时为 `BLOCKED-V02-PRE`；expected hash、member、
   manifest、raw canonicalization 或表外偏差失败时为 `INVALID-V02-PRE-HANDOFF`；§6.3
   资产失败时为 `BLOCKED-SAFETY-GATE`。这些分支可先完成已授权的本地构建和真只读 ABI，
   随后必须按对应状态收口；不得在 V02 内等待数小时、启动 drain/gc 或接着执行 PRE。
   下次正式 V02 必须重新授权、采用新 RUN_ID，并重新执行所有实时/ABI 门；旧 build/ABI
   仅作诊断旁证，不能跳过洁净构建和本轮远端重证。
5. 其它安全门失败不重试、不通过清理环境修复；立即报告。
6. session 中断时，只有 frozen input/binary hash、PRE/R1 handoff、远端配置、health、objects、mount
   identity 全部复核不变，才允许从下一个完整 logical position 恢复；不得从半个 mount
   或半个 round 续接。
7. `META_PROFILE=DAYTIME` 时 V02 自身预计 8～12 小时；发生四次 30 分钟静置重查时最长
   约 14 小时，**不含 V02-PRE**。GLM 不因“无人值守”扩大权限，也不因剩余时间不足砍轮次。
8. 无论 PASS、FAIL、BLOCKED 或中断，收尾都只能终止登记的本轮 fio/process group，
   优雅卸载 `/mnt/juicefs-v02` 并证明 mount gone；重新采集主挂载 identity、health、
   objects 和本轮 Redis/container gone。若已经生成 §6.4 正式 pre，必须用相同固定脚本和
   safe config allowlist 生成正式 `env-snapshot-post.txt`/`volume-config-safe-post.json`；
   若只进入 ABI，则只闭合 ABI-only post，禁止伪造一对正式快照。证据目录和三枚
   `/tmp` binary 保留待 Codex 复核，
   不擅自删除；若安全卸载/快照失败，报告 STOP 并请求人工处理，禁止强杀未知进程。

---

## 十三、交付物与报告

### 13.1 本地

```text
$CTRL/
  authorization.txt
  preflight-review.md
  controller-state.tsv
  runner-static-review/

$INPUT/
  taskbook.md
  fixed patches/tests
  pre-handoff/{pre,recert}/        exact PRE/R1 report/archive/receipt 校验材料
  pre-handoff/handoff-source-map.tsv
  pre-handoff/known-deviations.tsv
  pre-handoff/recert-canonical.tsv
  pre-handoff/handoff-final.tsv
  input.stat.tsv
  input.sha256

$LOCAL/
  src/{S,A,B}/
  patches/
  tests/
  binaries/
  sdk-provenance/
  logs/
  rc/
  meta/
  diffs/
  redis/
  remote-evidence/
  results-correctness.tsv
  commands.sh
  adaptations.tsv
  proposed-results-table-row.md
  SHA256SUMS
```

### 13.2 远端

```text
$REMOTE_OUT/
  preflight/
  pre-handoff/                     只含非敏感双交接索引、core/final 与实时复核结果
  env-snapshots/
  quiescence/
  binaries/                         仅 version/hash/ABI 元数据，不复制大 binary
  abi/{S,A,B}/
  mounts/<logical-position>/<attempt>/
  runs/<logical-position>/<item>/<round>/
  health/
  objects/
  metrics/
  integrity/
  results-raw.tsv
  results-mechanical.tsv
  quiescence-results.tsv
  commands.sh
  adaptations.tsv
  controller-state.tsv
  final-status.txt
  SHA256SUMS
```

每个 run 目录必须含 fio 全文、rc、128 个 bw log、start/end ns、health/object/mount
identity 和采集原文。禁止归档完整源码 `.git`、Go cache、三枚重复大 binary、认证 META
或 secret。

### 13.3 原始执行报告

写入 `$REPORT`，至少包含：

1. GLM 机械状态与全部 attempt；
2. 固定输入、source、binary 和远端 copy SHA；
3. exact PRE 与 R1 两组 RUN_ID/report/archive/receipt SHA、known deviations、R1 raw
   canonicalization、§6.3 asset source、core/final 裁定及实时三次对象门；
4. 本地 correctness/build/Redis；
5. ABI-only 授权、pre/post snapshot 与三臂 read smoke；
6. 正式 pre/post env snapshot 对比、每次 meta probe rate/raw 路径、等待次数与 META_PROFILE；
7. 九位置顺序、每位置 mount attempt/nsB/PID/hash；
8. 54 个正式 fio run 的完成度与 raw 路径；
9. S/A/B mount-level、arm-level、B/S、B/A 和 randrw R/W；
10. -30% 压力结果及能力边界；
11. integrity、health、objects 起止/峰值和 cleanup；
12. 所有偏差、未运行项、安全 STOP；
13. 明确“等待 Codex 从 raw bw log 复算；未授权生产替换或社区写入”。

GLM 只生成 `proposed-results-table-row.md`，不得直接改写
`prod-deploy/doc/deploy-log/results-table.md`。这是因为用户已明确由 Codex 负责结果分析；
Codex 复算并裁定后再同步项目真值，避免把未经审核的机械终态写入总表。

### 13.4 manifest、归档与跨端校验

1. 本地和远端分别生成覆盖交付证据中全部普通文件的 path/size/SHA256 manifest；
   `SHA256SUMS` 不自包含，必须实际 `sha256sum -c`，检查结果和 rc 单独保存。
2. 远端 archive 必须包含全部 128-job bw logs、fio/health/object/mount/metrics 原文、rc、
   parser 输出和 controller 状态；排除三枚大 binary、认证 META、授权原文、私钥、
   token、完整敏感 URL、挂载数据和 `/proc` dump。
3. tar 从唯一 staging 根生成一次；`tar -tzf` 必须可读，去掉 `./` 后的 member path
   不得重复、不得绝对路径或 `..`。保存远端 archive SHA256。
4. 把远端 archive 和 SHA sidecar scp 到 `$LOCAL/remote-evidence/`，本地重算必须一致，
   并随机抽取至少一个 S/A/B mount 的 ns/B 原文、一个 randwrite run 的 128 logs、一个
   randrw run 的读写 logs 逐文件比 SHA。
5. 本地 archive 只打包 frozen input 的副本、patch/diff、build/correctness/Redis 原始
   证据、binary provenance、结果表、远端 archive 的 hash/index 和报告副本；排除完整
   `.git`、Go/module cache、SDK 内容、三枚 binary、授权原文和 secret。源码 clone 与
   binary 保留到 Codex 复核，但不塞进证据包。
6. 两个 archive 均保存 size/SHA、member list、可读性和重复成员检查。archive 检查
   失败只能 `PARTIAL-V02` 或 `V02-NON-COMPLIANT`，不得写最高 PASS。

---

## 十四、通用注意事项（必须逐条执行）

### 14.1 数据统计

- 所有 fio 加 `--write_bw_log`、`--log_avg_msec=1000 --kb_base=1024`，保留每个 job 文件；
- 多 job 同秒求和后截前 1/4、取稳态中位数；禁止单 log × job；
- REPEAT=3 取中位，不取平均、不挑轮；
- randrw 读写分开；100GbE 单方向物理上界约 12,500 MiB/s，超线速值不接受并必须
  排查 parser/单位，不能作为高性能结果。

### 14.2 冷态与既有 layout

- 每个 fio 前 157+150+151+152 drop_caches；direct=1 不能替代；
- cache-size=0；不 create-on-open、不 fresh volume；
- 复用既有 layout，缺失即停止，不临时铺盘。

### 14.3 后端干净态

- V02 启动环境的恢复/分类只由既有 V02-PRE 完成；V02 消费 PRE 恢复历史与 R1 原始
  重新认证，由自身 §6.3 闭合资产并实时重查，禁止把 R1 变成新的恢复动作；
- 每个高强度写轮后 gc/compact/cooldown；
- compact 三指标和 health 全绿才继续；
- OSD restart 不能替代 compact；异常必须停止并报告。

### 14.4 卷与 pool

- `juicefs format` 不能清对象，本任务禁用；
- 本任务也禁 `juicefs destroy`、pool delete/create、PG/CRUSH 修改；
- 对象门前后必须来自 Ceph pool 原始输出。

### 14.5 挂载档位

- 每个新 mount 做 ns/B detect-and-replace，重试必须新 label；
- 每 arm 三个 mount，arm-level 取挂载中位；
- 不用 mseqread 吞吐或跨负载归一化替代 ns/B；
- 每个结论附 -30% 坏档压力测试，翻转则不可判。

### 14.6 环境与记录

- 每个 fio 前 health、objects、mount identity、共享业务检查并落盘；
- `commands.sh` 必须记录实际命令；报告每个数字指向具体原始文件/字段；
- 不记录密码、token、私钥、完整认证 URL；META 只从受保护来源读入，`commands.sh`
  用字面 `$META` 占位，另记不含明文的 SHA256 fingerprint；archive 前 secret scan；
- mount/config/gc/status 的 stdout/stderr 若可能回显 META，必须在**写盘前**用精确值和
  credential-URL 规则流式替换为 `<META:redacted>`，同时只在 pipe 中计算 raw stream
  SHA；保存 pipeline 各段 rc，不能先写 raw 再事后脱敏；
- `/proc/*/cmdline` 同样只保存 raw SHA 与脱敏 options/role，禁止把 NUL 分隔原文写盘；
- 不修改 `/mnt/juicefs`、系统 binary、WekaIO/BeeGFS/NIC/RoCE/MTU/md0。

### 14.7 分层授权

- 实现/路径/采集 bug 可在正式数据前修复并记录；
- 控制变量、判据、环境、安全门和权限不得擅改；
- 必须改变量才能继续时停止，不绕道。

### 14.8 环境快照与 meta 静置

- ABI-only 与正式写入分别有固定脚本生成的 pre/post snapshot；正式 pre/post 缺任一张
  不能出最高 PASS，ABI snapshot 不得冒充正式快照；
- 写类正式矩阵前做 60s meta 探针，rate 来源只能是
  `meta_ops_durations_histogram_seconds_total` delta/实际秒数；
- `<8000/s` 时按 30 分钟×最多四次重查，最终仍低则全数据标记退化态；
- 静置 probe 也属于 fio：health/drop_caches/per-job logs/写后 cooldown 一项不能少。

### 14.9 测试后 skill 合规自查

末步逐项写入报告：

1. 无 format/destroy/pool delete/create/OSD restart/config set；
2. PRE/R1 exact 双交接、§6.3 live asset 和 V02 实时三次 objects 门闭合，PRE/R1 授权
   未被冒充为 V02 授权；
3. ABI mount 全部为 read-only/no-bgjob/backup-meta=0，且没有把 ABI 结果当性能；
4. 只使用测试专用 mount/path，主挂载 before/after 一致；
5. 每 fio 前 health/drop_caches/identity/object 证据完整；
6. 每写轮后 gc/compact 三指标闭合；
7. 所有 per-job logs 齐全，统计为 §9 稳态中位；
8. ns/B labels 唯一、重挂次数对称披露、-30% 压力已算；
9. ABI-only 和正式 pre/post、meta probe/wait/profile 证据闭合；
10. 只管理精确本轮 PID/container/path；
11. 未执行生产替换、社区写入或越权操作。

任一不符必须标注对结论的影响，不得默默跳过。

---

## 十五、红线汇总

- 禁止对象数 >3,110,000 时启动性能；禁止 UsedInodes 代替 pool objects；
- 禁止把 PRE/R1 receipt 当实时免检或授权；禁止 V02 自行运行 drain/前置恢复 gc；
- 双证据 core、§6.3 资产、handoff final 任一未 PASS 时，只可按明确授权做本地构建和
  真只读 ABI，禁止任何写能力；
- 禁止触碰 `/mnt/juicefs`、业务路径或 `/usr/local/bin/juicefs`；
- 禁止 `gc --delete`、format/destroy、pool/PG/CRUSH 改动、配置 set、OSD/TiKV/节点 restart；
- 禁止 fresh layout、create-on-open、删别人数据或在 V02 中通过 drain“修环境”；
- 禁止跳过 health/drop_caches/gc/compact/nsB/PID guard；
- 禁止改变 Latin-square 顺序、3 mount/arm、REPEAT=3、runtime=180 或 fio 参数；
- 禁止单 bw log ×128、randrw R+W 相加、挑轮、只看 fio summary；
- 禁止用观察 B/A>=0.95 冒充稳健 5% 非劣；
- 禁止 pkill/killall、模糊 rm、停止未知容器/进程；
- 禁止安装系统包、替换生产 binary、commit/push/issue/PR/comment；
- 禁止把短窗结果写成正式长稳或生产上线完成。

---

## 十六、GLM 最终回复模板

```text
V02 状态：<允许终态之一>
RUN_ID / PROFILE：
CTRL / INPUT / LOCAL / REMOTE_OUT / archives / report：
PRE_RUN_ID / exact report / archive / receipt SHA / PRE_HISTORY：
RECERT_RUN_ID / exact report / archive / receipt SHA / RECERT_RAW：
known deviations / recert canonical / §6.3 ASSET_GATE / HANDOFF_CORE / HANDOFF_FINAL：
ABI-only gate / full write gate / 三次实时 objects：
固定输入与 S/A/B source/binary SHA：
本地 correctness / Redis / Ceph build：
远端 ABI/read smoke S/A/B：
初始 health / pool objects / compaction / 主挂载 identity：
pre/post env snapshot / meta probe rates / 等待次数 / META_PROFILE：
九个逻辑位置完成度与每位置 ns/B、mount attempts、PID/hash：
randwrite 27 runs raw 完成度：
randrw 27 runs raw 完成度：
S/A/B randwrite mount-level 与 arm-level：
B/S、0.70*B/S：
B/A、0.70*B/A、(B/A)/0.70：
randrw read/write B/A 与压力区间：
integrity rc / verify errors / cleanup：
objects 起止/峰值、health/compaction 异常：
所有 attempts、偏差、STOP 与未运行项：
skill 合规自查：
声明：未做生产替换、未做社区写入，等待 Codex 从全部 per-job raw log 复算。
```
