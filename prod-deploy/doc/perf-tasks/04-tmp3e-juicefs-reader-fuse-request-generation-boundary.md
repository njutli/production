# 04-tmp3e 任务书：JuiceFS B4/RA32 Reader/FUSE 请求生成边界

> 状态：`COMPLETED / VALID_L1_DIAGNOSIS / ENVIRONMENT_CLOSED`；正式RUN=`20260904-184259`；
> Phase A=`APPLICATION_QD_SCALABLE`，Phase B=`RESOLUTION_INSUFFICIENT`；详见对应正式报告。

## 状态与目标

本任务承接 04-tmp3c 与 04-tmp3d，仅定位单流大块读的上层请求生成边界，不产生生产配置。

```text
EVIDENCE_LEVEL=L1_SCREEN
BASELINE=B4/RA32，约 2.9 GiB/s，Little 在途 GET 约 4.54--4.59
BACKEND_REFERENCE=4MiB RADOS QD8 5403.20 / QD16 6659.20 MiB/s
TARGETS=竞品 5149.84 / 项目 6250 MiB/s
SUDO_REQUIRED=0
STOP_AFTER_ANSWER=true
```

唯一问题：在同一份 B4、同一份 10 GiB 资产和同一后端上，增加应用进入 FUSE 的在途请求，
能否把有效 GET 在途量从约 4.6 推至 8，并使带宽接近两条参考线；若不能，边界属于
Reader/FUSE 上层，而不是 Ceph 对象服务。

04-tmp3c 的 B4 临时卷已经精确销毁，当前 `juicefs-prod` 是 B256，故本任务必须新建一只
RUN 私有 B4 临时卷；可复用 04-tmp3c 的 format、seed、挂载、指标、生命周期和 analyzer
逻辑，不复用已销毁的 META、UUID 或 RADOS namespace。

## 固定条件与隔离

- 发起节点 157；patched JuiceFS `/tmp/juicefs-1.4.1-patched`，MD5
  `24fae0852051c80ca571cb2f20275d46`。
- 临时 META 仅使用 RUN 后缀，数据池固定 `juicefs-data`；当前 `juicefs-prod`、业务挂载、
  TiKV 其他 namespace 和 Ceph pool 均不改。
- B4 `--block-size 4M`，只 seed 一份 10 GiB `0x5a` 非稀疏资产，重挂后校验 size、inode、
  mtime 和首尾 hash。
- 挂载固定 `--max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300
  --cache-size 0 --max-readahead 32M`，RUN 私有 `ms_async_op_threads=8`。
- Phase A 诊断挂载额外显式 `-o async_dio`，整段所有点保持不变；其绝对值不是生产结论。
- Phase B 只要 Phase A 证据有效就运行，恢复 `async_dio=off`，只改变 RA32/RA64；即使 Phase A
  的应用 QD 未扩展，也不能排除 RA64 通过内部预读改善 psync。
- fio 读固定 `rw=read bs=20M size=10G direct=1 numjobs=1`；psync 锚 60 秒，诊断点 30 秒。
  每个 cell 保存原始 JSON、stdout、stderr、逐秒带宽和指标快照。
- 不执行 drop-caches、scrub/compact、Ceph config/pool/PG/OSD/CRUSH、服务、网络或内核修改；
  不使用 sudo。

## 最小矩阵与执行顺序

### Phase A：应用入口诊断（同一 B4/RA32/async_dio 挂载）

```text
A01 psync QD1 60s   锚点
A02 libaio QD1 30s  capability 后正式诊断
A03 libaio QD2 30s
A04 libaio QD4 30s
A05 libaio QD8 30s
A06 psync QD1 60s   回环锚点
```

开始 Phase A 前，先执行一次独立 libaio `1GiB/5s/QD1` capability canary。canary 失败时不跑
其余矩阵：签 `TOOLING_BLOCKED`，只保留只读 goroutine/profile 诊断建议或停止；不得拿 psync
结果冒充应用并发诊断。A01/A06 同为显式 async_dio 挂载上的 psync，用于校验诊断挂载本身
没有造成大偏移；若两锚差异超过 5%，Phase A 无效并停止。

Phase A 的采集除 JuiceFS metrics（FUSE read、GET bytes/count/duration/errors、read buffer、
process CPU）和客户端 CPU/RSS/thread/NIC 外，尽力只读采集可唯一识别的临时 FUSE connection
的 `waiting/max_background/congestion_threshold/max_read`；无法唯一映射或无权限时只记 NA，
不得使用 sudo。

### Phase B：可交付旋钮（Phase A 有效即执行，async_dio=off）

```text
B01 B4/RA32/async_off 60s
B02 B4/RA64/async_off 60s
B03 B4/RA64/async_off 60s
B04 B4/RA32/async_off 60s
```

B 阶段是 RA32/RA64 的 A-B-B-A；只改变 `--max-readahead`，并重新验证 mount identity、
`async_dio=off`、资产和业务卷指纹。

## 预注册判定与停止条件

- Phase A `libaio` 从 QD1 到 QD8 至少出现两档同向增长，且 QD8 的 GET inflight 相对 A01
  增加至少 25%，同时 psync A01/A06 均低于 5149.84：记 `APPLICATION_QD_SCALABLE`；Phase B
  仍照常运行，用于测试 RA64 的独立可交付旋钮。
- 若 Phase A 完全不扩展（吞吐、GET inflight 均无材料增长），记
  `READER_FUSE_SERVICE_BOUNDARY`，但仍运行有效性要求的 Phase B；Phase A 绝对值不作为生产
  或交付性能。
- Phase A capability 失败记 `TOOLING_BLOCKED`；锚漂移、健康/错误/指标覆盖/资产门失败，
  记 `EVIDENCE_INVALID` 并保留现场。
- Phase B 两个 RA64 相对相邻 RA32 均提升至少 10%，且 GET inflight 同向增加、错误率不恶化：
  记 `RA64_READER_WINDOW_SIGNAL`；否则 `<5%` 记 `RA64_NO_MATERIAL_RECOVERY`，5--10%或方向
  不一致记 `RESOLUTION_INSUFFICIENT`。答案即停，不扩 RA128、B16、写或随机 I/O。
- 任一时刻 Ceph 非 `HEALTH_OK`、PG 非全 `active+clean`、OSD 非全 up/in、mount 日志出现
  assert/SIGABRT/panic/fatal、非本 RUN 进程或业务卷指纹漂移，立即停止并保留原始证据。

## 授权、清理与交付

正常 format、seed、mount、fio、graceful umount、精确 META/UUID destroy 均不需要 sudo；prepare、
Phase A、Phase B、cleanup 各需独立 ACK（capability canary 是 Phase A 的起始硬门）。默认只生成
cleanup-plan，审核后才按 META+UUID 精确销毁临时卷。
禁止通配、递归删除、pool 删除和强制卸载。证据先写入唯一权威根并校验 manifest，再清远端
临时证据。

交付包括本任务书、executor、analyzer、实际命令、两阶段 raw/derived、FUSE/客户端 sidecar、
资产与业务指纹、manifest/hash、清理审计和唯一 verdict。Gate 仅作为 executor 的 `gate0`
动作，不另建通用框架。

预计：离线 30--45 分钟；B4 创建/seed/校验 20--35 分钟；Phase A 35--50 分钟；Phase B
增加 30--45 分钟；持久化和清理 25--40 分钟；总计约 1.5--2.5 小时，上限 3 小时。
