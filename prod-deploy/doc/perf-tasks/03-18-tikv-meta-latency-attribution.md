# 03-18 任务书：TiKV meta `Write` 延迟服务端归因与快慢态触发捕获

> 面向执行方：**GLM**；分析方：**Codex/GPT**；立项日：2026-08-22
> 任务类型：**只采集、后分析**。本轮不调 TiKV/PD/Ceph 参数，不重启服务，不做容量变更。
> 前置结论：`03-17g` 已立 **F68**——写侧回退的一阶信号是客户端观测 meta `Write` 延迟由 138.1 ms 升至 187.3 ms；同一挂载曾出现 136.6 → 172.3/179.3 ms 跳变。
> 配套脚本：`scripts/FULLBASELINE/debug/t54-tikv-meta-latency-attribution.sh`。
> 方法论：`skills/SYSTEM-SAFETY-SKILL.md`、`skills/TESTING-GUIDE.md`、`skills/FULLBASELINE-SKILL.md`、`skills/LONG-RUNNING-TEST-SKILL.md`、`skills/test-commands-reference.md`。

---

## ⚑ 计划线

```text
03-16：默认 msgr=3 下发现第一道 per-mount 读瓶颈
  → 03-17b/c：定位 msgr-worker 落位偏斜，当前 6 OSD 配 msgr=8
  → 03-17d/e：读侧收敛到 6.1~6.28 GiB/s 共享服务墙，封板
  → 03-17f：交付配置七项基线，写侧处在 meta 慢态
  → 03-17g：否证二进制回退，立 F68（TiKV meta 延迟 + 双态）
  → ★ 03-18（你在这里）：同一挂载 randwrite×3 + TiKV/PD 全链路采集
       ├─ 服务端某阶段同步变慢 → 只选该阶段的最小可逆实验
       ├─ 服务端快、客户端慢   → 转客户端事务流水线/重试退避分析
       └─ 服务端已饱和且无安全余量 → 输出同步元数据架构限制
  → 有明确候选才做一次 A-B-A；无候选不再重复全基线
  → 最终 ≥8h 长稳签收与 03 阶段总结
```

一句话：**在不改变生产配置的前提下，把客户端约 180 ms 的 meta `Write` 延迟拆到 TiKV scheduler、storage/RocksDB、Raft/复制或客户端—服务端间隙中的某一层，并尝试捕获同挂载快慢态切换的同步事件。**

---

## 〇、GLM 全自动执行纪律

1. GLM 只执行、监控、打包和回传；⛔ **不算均值、延迟、命中率、比例、相关系数，不做根因判断**。
2. 本轮矩阵固定，禁止因带宽看起来高或低而重跑、加轮、删轮或提前换挂载。
3. 只有 §七列出的 STOP 条件允许停机；STOP 后保留现场、打包已有文件，不自行修环境后续跑。
4. 进度只报机械状态：当前阶段、挂载 PID/starttime、V4 日志末行、Ceph health、对象数、脚本 rc。
5. 开工前核对本任务书和四个脚本的 md5；任一与派发报文不一致即 STOP。
6. 脚本实现问题可在**不改变实验变量**的前提下修复；修复后必须回传 diff、新 md5、`bash -n` 结果。需要改变矩阵、配置、清理方式或阈值时必须 STOP。

---

## 一、背景与本次边界

### 1.1 已经确认的事实

- `03-17g` 同日 ABBA 表明新二进制 `de93563f` 相对旧二进制写侧约 **+5.7%**，不是 −11% 回退的原因。
- 每写所需 meta 次数基本不变，meta 在飞并发反而增加，Ceph PUT 延迟下降；退化方向已从对象路径排除到元数据路径。
- 客户端 meta `Write` 平均延迟：历史快态约 **122~149 ms**，近期慢态约 **172~200 ms**。
- 同一挂载的连续三轮曾从 136.62 ms 跳到 172.27/179.30 ms，故不能再解释为二进制、挂载参数或 msgr 落位抽签。
- 旧 03-12 虽跑过 TiKV 指标采集，但宽前缀结果被 `head` 截断，只留下 3 个 TiKV 指标，不能回答服务端归属。

### 1.2 本轮明确不做的事情

- ⛔ 不测试 block cache、线程数、region 调度、leader 迁移、批量提交等候选解法。
- ⛔ 不执行 `ceph config set`、不改 `/etc/ceph/ceph.conf`、不改 TiKV/PD 配置。
- ⛔ 不重启 TiKV、PD、OSD、157，不改变网络、IRQ/RPS、PG、CRUSH 或 pool。
- ⛔ 不跑读侧判档门、randrw 对照、60s randwrite 静置探针或任何写前压力探针。
- ⛔ 不做 `--layout`、`juicefs destroy`、pool 删除/重建或卷重新 format。

上述边界很重要：本轮只回答“时间花在服务端哪一段、状态切换与什么同步”，不在同一批次里一边测量一边调参。

---

## 二、目标、矩阵与口径

### 2.1 两个问题

| # | 问题 | 本轮交付 |
|---|---|---|
| **Q1（主问题）** | 客户端 meta `Write` 的 138→187 ms 增量落在 TiKV 哪一段？ | 客户端逐秒/逐轮计数器 + TiKV scheduler/storage/Raft/RocksDB 精确指标 + 三节点主机资源 |
| **Q2（副问题）** | 同挂载快态→慢态切换是否与 region/leader、compaction/cache、Raft 或主机资源事件同步？ | 同一 PID 连续三轮 + 秒级时间线 + PD hotspot/store 快照 + phase markers |

如果三轮都处在同一状态，**Q1 仍然有效**；Q2 标为“本窗口未观测到切换”，不得自动加测。

### 2.2 固定环境

| 项 | 固定值 |
|---|---|
| 客户端 | 157 |
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端配置 | 基于系统 conf 生成进程私有 conf，`[client] ms_async_op_threads = 8` |
| 系统 conf | `/etc/ceph/ceph.conf`，期望 md5 `5b6be34179a64e0a5f9c6d3a9690041f`，起止必须一致 |
| fio | randwrite，256K，128 jobs，iodepth=128，direct=1，已有 `storage_test.*.0` 覆盖写 |
| 挂载实例 | 只挂一次；三轮必须为相同 PID + `starttime_ticks` |
| 目标线 | 6250 MiB/s；本轮是归因采集，不以带宽高低决定 STOP |

`msgr=8` 是当前 6 OSD 拓扑的交付配置；此处不把“OSD 数×1.33”当通用公式。

### 2.3 唯一矩阵

```text
挂载并校验交付配置
  → 120s idle 原始采集（无 fio、无 preprobe）
  → V4 reset_state / deterministic_warmup（全程已在采集）
  → 同一挂载 randwrite r1，180s
  → V4 标准一次 aggressive_cleanup，边界对象数采样
  → 同一挂载 randwrite r2，180s
  → 同上
  → 同一挂载 randwrite r3，180s
  → 收尾采集、优雅卸载、打包
```

- V4 只调用一次：`ITEMS=randwrite SKIP_REMOUNT=1 ... T54 180 3`。
- `OBJ_GC_PASSES=0`：V4 的 `aggressive_cleanup` 已执行一次 `juicefs gc --compact`；关闭 `obj_gate` 的额外 GC，避免同一边界清两遍。
- 第一轮正式 randwrite 本身就是写状态观测；没有“先跑 60s 看快慢、再决定是否正式测试”的选择性预探针。

### 2.4 有效带宽口径

本阶段以总计划 §14.1 的较新口径为准，覆盖旧 skill 中“截前 1/4 取中位数”的通用写法：

```text
每个 job 的 *_bw.<job>.log
  → timestamp_ms // 1000 对齐
  → direction=1
  → 同秒跨 128 jobs 求和
  → 取 15 <= sec - t0 <= 175
  → 对窗口取逐秒均值，单位 MiB/s
```

- `fio.txt`/`rounds.tsv` 的 group summary 只作机械进度，不作验收值。
- 统计由分析方完成；GLM 只保证每轮 **128 个 per-job bw log** 全部回传。

---

## 三、必须采集的信息

### 3.1 客户端 JuiceFS/Ceph

| 信息 | 文件 | 分析用途 |
|---|---|---|
| `Write` op 总耗时/次数 | `client/write-meta-series.tsv`；每轮 `jfs-stats-pre/post.txt` | 逐秒及逐轮 meta `Write` 延迟 |
| transaction、FUSE write、PUT、buffer | 同上 + `client/i1-jfsstats-T54.tsv` | 排除计数器口径错配，关联在飞/对象路径 |
| 进程/逐线程 CPU | `client/i2-proc-*`、`client/i2-threads-*` | 排除客户端 CPU/worker 再次饱和 |
| 双 NIC 与 TiKV RTT | `client/i3-net-*`、`client/i3-tikv-rtt-*` | 排除管理网 RTT/流量跳变 |
| OSD perf pre/post | `client/i4-osdperf-*` | 确认对象路径没有同步恶化 |
| 挂载实况 | `mount-verify.txt`、V4 `jfs-instance-T54.txt` | 二进制、max_read、msgr=8、PID/starttime 不变量 |

任务书和分析脚本引用比值时必须打印分子/分母完整计数器名；禁止再次发生 F67 的跨计数器比较。

### 3.2 TiKV 精确指标（3 个 `:20180/metrics`）

配套脚本逐周期抓以下指标，且 preflight 对 histogram 的 `_sum/_count` 和 label 集合做硬校验：

- `tikv_scheduler_command_duration_seconds_{sum,count}`
- `tikv_scheduler_latch_wait_duration_seconds_{sum,count}`
- `tikv_scheduler_processing_read_duration_seconds_{sum,count}`
- `tikv_storage_engine_async_request_duration_seconds_{sum,count}`
- `tikv_storage_command_total`
- `tikv_raftstore_{append,commit,apply}_log_duration_seconds_{sum,count}`
- `tikv_raftstore_apply_wait_time_duration_seconds_{sum,count}`
- `tikv_engine_cache_efficiency`
- `tikv_engine_pending_compaction_bytes`

同时在 `preflight`、`idle-post`、`post-load` 三个边界保存每个 TiKV/PD 端点的**完整 `/metrics` gzip 原文**及 metric 名清单。精确子集遗漏的新版本指标可以从完整快照补查，绝不再使用 `head` 截断。

### 3.3 PD/region/leader

每 10s 原样保存：

- `/pd/api/v1/hotspot/regions/write`
- `/pd/api/v1/hotspot/regions/read`
- `/pd/api/v1/hotspot/stores`
- `/pd/api/v1/stores`
- PD metrics 中 leader changes、scheduler、TSO、gRPC histogram。

Hotspot API 不可用不阻塞主任务，但必须保存 HTTP 错误原文；TiKV 三个 metrics 端点及其核心指标缺失则必须 STOP。

### 3.4 三个 TiKV 主机

每个节点周期性采：远端 epoch、TiKV PID、CPU、RSS、线程数、上下文切换、`iostat -x`。收尾按测试 epoch 拉取三节点 TiKV journal，并保存版本、配置 md5、服务 active 状态。

### 3.5 对象数与健康

- 起点对象数必须 `<=3,110,000`；不满足即 STOP，⛔ 禁现场自动 GC 后强行开跑。
- 正式负载期间每 10s 记录 pool `objects/stored/max_avail`，形成**轮内峰值**证据，关闭 B4-25。
- 轮内硬安全上限 `8,000,000`；超过即按 V4 精确 process-group 终止本批。
- 每轮 `aggressive_cleanup` 后的边界必须回到 `<=3,110,000`；否则停止后续轮次。
- Ceph health 每 30s 留痕，必须全程 HEALTH_OK；本任务不放行 clock skew WARN。

---

## 四、执行步骤

### 步骤 0｜测试前 skill 与安全扫描

GLM 必须通读并在 `preflight-report.txt` 中逐条确认：

1. `SYSTEM-SAFETY-SKILL.md` §1.3/§1.7/§2.5：sudo 写操作与重启预扫描。
2. `TESTING-GUIDE.md` §1.3、§2.2、§3、§5.6：health、compact、drop cache、写稳态。
3. `FULLBASELINE-SKILL.md` §2、§5、§6、§7、§9：V4 完整性、同实例、有效带宽复核、安全红线。
4. `test-commands-reference.md` §8.3/§9：per-job bw logs 与原始数据保存；有效带宽按本任务 §2.4 的更新口径覆盖。
5. `LONG-RUNNING-TEST-SKILL.md` §3：运行期间检查进程、日志与 health。

运行前扫描四个脚本：

```bash
grep -nE 'sudo (reboot|shutdown|halt|poweroff|systemctl (stop|restart|reboot|poweroff)|rm |chown|chmod|dd |wipefs|lvremove|lvcreate|umount|podman rm|docker rm)|\brm -rf\b|ceph osd pool (delete|create)|ceph config set' \
  /tmp/t54-tikv-meta-latency-attribution.sh \
  /tmp/FULLBASELINE_V4.sh /tmp/instrument.sh /tmp/env-snapshot.sh \
  > /tmp/t54-safety-scan.txt || true
```

预期只会看到 V4 `phase0_layout()` 内的 `rm -rf "${TEST_DIR}"/*`；本任务**绝不传 `--layout`，该分支不得执行**。脚本允许的状态改变仅为：

- `ceph tell osd.N compact`；
- 157 与三个节点 `drop_caches`；
- 固定挂载点 `/mnt/juicefs` 的优雅 umount/mount；
- 正式 randwrite；
- 每轮一次 `juicefs gc --compact`；
- 将旧 `/tmp/opencode-fullbaseline-v4` **无损移动**到唯一备份目录，防止混包。

任何 restart/reboot、TiKV/PD 配置写、pool/PG/CRUSH 修改都不在授权清单。

### 步骤 1｜上传与 md5 核对

上传到 157 `/tmp/`：

```text
03-18-tikv-meta-latency-attribution.md
t54-tikv-meta-latency-attribution.sh
FULLBASELINE_V4.sh
instrument.sh
env-snapshot.sh
```

本地与 157 各执行一次：

```bash
md5sum /tmp/03-18-tikv-meta-latency-attribution.md \
  /tmp/t54-tikv-meta-latency-attribution.sh \
  /tmp/FULLBASELINE_V4.sh /tmp/instrument.sh /tmp/env-snapshot.sh
bash -n /tmp/t54-tikv-meta-latency-attribution.sh
bash -n /tmp/FULLBASELINE_V4.sh
bash -n /tmp/instrument.sh
```

固定依赖脚本期望值：

| 文件 | md5 |
|---|---|
| `FULLBASELINE_V4.sh` | `4198ea2676ba56744a3cd5eba17a5eab` |
| `instrument.sh` | `fa57cc0fff02b5843a289e08f6a21477` |
| `env-snapshot.sh` | `b6d1c556e43b183c43ea3fdc7de49cd7` |
| `t54-tikv-meta-latency-attribution.sh` | 以本任务派发报文为准 |
| 本任务书 | 以本任务派发报文为准 |

### 步骤 2｜只读 preflight

配套脚本会自动完成并落盘：

- hostname/时间、fio、脚本 md5；
- 根分区可用空间 `>=5 GiB`；
- Ceph HEALTH_OK、6 OSD、PG 状态；
- 二进制与系统 ceph.conf md5；
- V4 硬前置文件存在：`storage_test/read_test/rw_test` 各 128 个，且 `seqread/seqread.0.0` 在位；缺失时 STOP，禁止现场 layout；
- 三个 TiKV 与三个 PD metrics 端点可读；TiKV 核心 histogram pair/labels 齐全；
- 起点对象数 `<=3.11M`。

脚本不复用旧结果目录：若 `/tmp/opencode-fullbaseline-v4` 已存在，会移动到 `/tmp/opencode-fullbaseline-v4.pre-t54-<RUN_ID>`，不删除、不覆盖。

### 步骤 3｜启动唯一正式批次

在 157 上：

```bash
RUN_ID=$(date +%Y%m%d-%H%M%S)
setsid bash /tmp/t54-tikv-meta-latency-attribution.sh "$RUN_ID" \
  > "/tmp/t54-${RUN_ID}.launcher.log" 2>&1 &
echo "$!" > "/tmp/t54-${RUN_ID}.launcher.pid"
echo "RUN_ID=$RUN_ID PID=$(cat /tmp/t54-${RUN_ID}.launcher.pid)"
```

启动 10s 后机械检查：

```bash
tail -30 "/tmp/t54-${RUN_ID}.launcher.log"
pgrep -af 't54-tikv-meta-latency-attribution|FULLBASELINE_V4|fio'
sudo ceph health
```

禁止同时启动第二份 T54/V4/fio。

### 步骤 4｜运行中监控

本轮预计 **35~60 min**。GLM 每 10 min 查看：

```bash
date
tail -30 "/tmp/t54-${RUN_ID}.launcher.log"
tail -10 "/tmp/opencode-t3.18-${RUN_ID}/object-series.tsv"
tail -10 "/tmp/opencode-t3.18-${RUN_ID}/health-series.tsv"
sudo ceph health
```

- 只报告原文，不从带宽或延迟判断快慢态。
- 进程仍在且 health 正常则继续等待；日志出现 `STOP` 时不自行恢复或重跑。
- 用户插话时先回应；测试后台继续，恢复后重新检查进程、日志和 health。

### 步骤 5｜结束与完整性检查

脚本正常结束必须打印 `T54 DONE`、`OUT=`、`ARCHIVE=`。GLM随后只读核验：

```bash
RUN_DIR="/tmp/opencode-t3.18-${RUN_ID}"
ARCHIVE="/tmp/production/opencode-t3.18-${RUN_ID}.tar.gz"
test -f "$ARCHIVE" && md5sum -c "${ARCHIVE}.md5"
( cd "$RUN_DIR" && md5sum -c MANIFEST.md5 )
find "$RUN_DIR/v4/T54" -type f -name '*_bw.*.log' | wc -l
wc -l "$RUN_DIR"/metrics-series/* "$RUN_DIR/client/write-meta-series.tsv" \
  "$RUN_DIR/object-series.tsv" "$RUN_DIR/health-series.tsv"
grep -R 'forced-mount' "$RUN_DIR/v4" || true
```

预期 bw log 总数为 **384**（3 轮 ×128）；不符不得补跑，按缺件回传。

若脚本按 STOP 条件退出而未自动生成压缩包，确认 launcher 和其精确子进程均已退出后，只做一次**现场归档**，不修复、不续跑：

```bash
RUN_DIR="/tmp/opencode-t3.18-${RUN_ID}"
ARCHIVE="/tmp/production/opencode-t3.18-${RUN_ID}-STOP.tar.gz"
if grep -q 'v4-start' "$RUN_DIR/phase-markers.tsv" 2>/dev/null \
   && test -d /tmp/opencode-fullbaseline-v4 \
   && ! test -e "$RUN_DIR/v4-partial"; then
  mv /tmp/opencode-fullbaseline-v4 "$RUN_DIR/v4-partial"
fi
( cd "$RUN_DIR" && find . -type f ! -name MANIFEST.md5 -print0 \
    | sort -z | xargs -0 md5sum > MANIFEST.md5 )
tar -C /tmp -czf "$ARCHIVE" "$(basename "$RUN_DIR")"
md5sum "$ARCHIVE" > "${ARCHIVE}.md5"
```

此处只移动本批在 `v4-start` 之后新建的 V4 目录；`*.pre-t54-*` 历史备份禁止移动、合并或删除。

### 末步｜skill 合规复核

在回传报文中逐项声明：

1. 未执行 pool delete/create、destroy、format、layout、OSD/TiKV/PD restart。
2. 未修改 `/etc/ceph/ceph.conf`，起止 md5 一致；只使用进程私有 msgr=8 conf。
3. 每个 fio 前 V4 已执行 health/PG gate 与四节点 drop cache；写后已走一次 aggressive cleanup/compact。
4. 三轮为同一 PID/starttime，无 `forced-mount`。
5. 384 个 bw logs、fio 原文、客户端/TiKV/PD/对象/主机指标均已打包。
6. 所有偏离、缺件和 HTTP/SSH 错误均逐条列出；没有则明确写“无”。

---

## 五、有效性判据及数据来源

| # | 判据 | 数据源 | 规则 |
|---|---|---|---|
| V1 | 同一挂载 | `mount-verify.txt`、`v4/jfs-instance-T54.txt`、wrapper 监控 | PID + starttime 三轮不变；否则全批失效 |
| V2 | 配置生效 | `mount-verify.txt` | `/proc/<pid>/exe` md5 正确、`max_read=262144`、`msgr_workers=8` |
| V3 | 三轮负载完整 | `v4/T54/randwrite-T54-r*/fio.txt` + bw logs | 3/3 rc=0，每轮 128 个 bw log |
| V4 | 客户端计数完整 | `client/write-meta-series.tsv`、每轮 `jfs-stats-pre/post.txt` | `Write` duration/total、transaction、FUSE write、PUT 均存在且增长 |
| V5 | TiKV 核心指标完整 | `metrics-manifest.tsv`、`metrics-series/`、`metrics-full/` | 3 TiKV endpoints；核心 histogram sum/count + labels 全配对 |
| V6 | 状态边界可比 | `object-series.tsv`、`v4/obj-gate-T54.tsv` | 起点/每轮 cleanup 后 `<=3.11M`；轮内峰值完整 |
| V7 | 集群稳定 | `health-series.tsv`、env pre/post、V4 PG gate | 全程 HEALTH_OK、6 OSD、PG active+clean、up_from 未变 |
| V8 | 时间可对齐 | `phase-markers.tsv`、各 series epoch、三节点 remote_ts | 客户端/服务端时间线可在秒级对齐 |

PD hotspot API、TiKV host iostat 或 journal 单项缺失不会自动否决 Q1，但必须降级相应分支的归因强度；TiKV 核心 metrics 缺失则 Q1 不可判。

---

## 六、交付物

157 产物：

```text
/tmp/production/opencode-t3.18-<RUN_ID>.tar.gz
/tmp/production/opencode-t3.18-<RUN_ID>.tar.gz.md5
```

回传至：

```text
/home/lilingfeng/tmp/production/
```

压缩包至少包含：

```text
opencode-t3.18-<RUN_ID>/
├── taskbook.md
├── commands.sh
├── wrapper.log
├── v4.stdout.log
├── env-check.txt
├── env-snapshot-{pre,post}.txt
├── mount-verify.txt
├── phase-markers.tsv
├── health-series.tsv
├── object-series.tsv
├── metrics-manifest.tsv
├── series-manifest.tsv
├── metrics-full/                 # 3 个边界 × 3 TiKV + 3 PD 的 gzip 原文
├── metrics-series/               # 3 TiKV + 3 PD 连续精确子集
├── pd-api/                       # hotspot/stores 原文
├── tikv-host/                    # 三节点资源、身份、journal
├── client/                       # I1-I4 + write-meta-series
├── v4/                           # 本批独占 V4 结果，含 3×128 bw logs
├── ceph.conf.system-{before,after}
├── ceph.conf.private-msgr8
└── MANIFEST.md5
```

GLM回传报文只写：RUN_ID、起止时间、脚本 rc、三轮 `rounds.tsv` 原文、PID/starttime、起点/峰值/终点对象数原文、health 末行、文件数量、包大小与 md5、异常/偏差。⛔ 不写性能结论。

分析方收到原始包后产出 `doc/perf-report/03-18-tikv-meta-latency-attribution-20260822.md`，并同步总计划和 `doc/deploy-log/results-table.md`；GLM 不编辑这些结论文档。

---

## 七、STOP 条件（穷举）

| # | 条件 | 动作 |
|---|---|---|
| S1 | 任务书/脚本 md5 与派发报文不一致，或 `bash -n` 失败 | 不开跑，回报原文 |
| S2 | 二进制 md5、实跑 `/proc/<pid>/exe`、system ceph.conf md5 不符 | STOP |
| S3 | 非 HEALTH_OK、OSD 数不是 6、PG 非 active+clean 或 up_from 变化 | 精确 process-group 停负载，保留现场 |
| S4 | TiKV 任一 `:20180/metrics` 不可读，或核心 histogram pair/labels 缺失 | STOP，不用宽前缀/`head` 降级绕过 |
| S5 | 起点对象数 >3.11M，或不可解析 | STOP；禁止自动 GC 后重试 |
| S6 | 轮内对象数 >8M，或任一 cleanup 后 >3.11M | 精确 process-group 停负载 |
| S7 | 挂载失败、`max_read!=262144`、msgr-worker≠8、找不到准确 PID/starttime | STOP |
| S8 | 三轮中 PID/starttime 漂移、出现 forced-mount | STOP，整批跨轮比较无效 |
| S9 | `storage_test/read_test/rw_test` 任一不是 128 个，或 V4 所需 seqread prep 缺失 | STOP；禁止 `--layout` |
| S10 | V4/fio rc≠0、timeout、缺 fio summary 或 bw logs 不完整 | STOP；不补跑、不删该轮 |
| S11 | 根分区可用空间 <5 GiB | STOP |
| S12 | 出现脚本未预登记的 sudo 写操作、restart/reboot、配置/PG/pool/CRUSH 修改需求 | STOP，等待授权 |

以下情况**不 STOP**，只记录：

- 单轮有效带宽低于历史或低于 6250；这正是本轮要解释的状态。
- 三轮都快、都慢或出现中间态。
- PD hotspot API 返回空集合或单个 API 404/超时。
- 某个 TiKV host 辅助 `iostat`/journal 无权限，但核心 metrics 完整。
- V4 的写类 L1/L2 判据 FAIL；本轮不是配置效果验收，保留真实轮序。

---

## 八、通用注意事项与本任务特化

1. **统计口径**：全部 per-job bw logs 必须保存；禁止用 fio summary 固化基线，禁止单日志×128。正式值按 §2.4 重算。
2. **drop cache**：V4 每个 fio 前在 157 和三个节点执行；任一节点失败必须落日志。
3. **fresh-volume**：本轮故意使用既有 `storage_test` 覆盖写，不使用 `create_on_open`，避免文件创建/冷启动失真。
4. **后端净化**：V4 在正式负载前和每轮写后执行 compact cooldown；必须看到 `compact_running=0` 且 `compact_queue_len=0`。
5. **健康**：wrapper 30s health 序列 + V4 每轮 PG gate 双重留证；不带病测。
6. **记录**：`commands.sh`、fio 原文、384 个 bw logs、环境 pre/post、客户端/TiKV/PD/主机原始文件缺一项都要显式报告。
7. **清理特化**：本轮禁止 destroy/format，因为它们会重置 TiKV 元数据状态；只允许正式轮后的 `gc --compact`。禁止 pool delete/create。
8. **挂载波动**：写侧归因不使用旧 ns/B 判档器；消除实例噪声的方法是三轮固定同一 PID/starttime。
9. **授权边界**：实现层采集可修；矩阵、时长、阈值、配置、清理和服务状态不可擅改。
10. **原始来源**：每一个最终数字必须注明文件、字段、公式和窗口；派生比值必须打印完整分子/分母名。
11. **完整 metrics**：精确子集用于秒级分析，完整 gzip 用于补漏；两者都要，不得以其中一个替代另一个。
12. **结果隔离**：旧 V4 目录只移动备份，禁止合并进本批，解决 03-17g 混入历史 cell 的包装问题。

---

## 九、分析方判决预案（GLM 不执行）

### 9.1 状态划分

按每轮完整客户端计数器计算：

```text
client meta Write latency
  = Δjuicefs_meta_ops_duration_seconds_Write
    / Δjuicefs_meta_ops_total_Write
```

- 快态参考：`<=150 ms`
- 慢态参考：`>=170 ms`
- 150~170 ms：中间态，保留，不强行二分。

有效带宽从 bw logs 按 §2.4 独立复算；不使用 fio summary。

### 9.2 服务端分支

| 观测 | 首要归属 | 后续动作 |
|---|---|---|
| scheduler command/latch wait 随 client 延迟同步抬升，hot region 集中 | scheduler/锁存/单 key 或 region 热点 | 核查 key/region 分布；只有明确可逆方案才立 A-B-A |
| storage async 延迟、cache miss 或 pending compaction 与慢态同步，主机盘延迟上升 | RocksDB/cache/compaction | 先评估无需重启的手段；涉及 cache/restart 必须另请授权 |
| Raft append/commit/apply/apply-wait 抬升，伴 leader change/hot store | Raft 复制/leader/store 倾斜 | 做架构容量/region/leader 分析；不在本批调度 |
| TiKV 服务端各阶段都快且稳定，但 client `Write` 延迟抬升 | 客户端—TiKV 网络、重试/退避、事务流水线 | 转客户端代码与重试计数器，停止猜服务端参数 |
| 服务端已持续排队，当前约 9~12K meta/s，安全手段没有接近 25K/s 的理论余量 | 同步元数据事务架构墙 | 输出架构原因；不重复全基线 |

### 9.3 停止继续扫参的条件

6250 MiB/s ÷ 256 KiB = **25,000 次有效写/s**。若服务端分解表明当前持续提交率约 9~12K/s 且瓶颈需要扩 TiKV、分片/region、异步或批量事务等架构变化才能接近 25K/s，则 03 阶段写侧直接进入“未达标但架构原因已闭环”，不再用小参数反复试探。
