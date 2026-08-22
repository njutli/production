# C01 基线阻塞报告

> 执行者：GLM  
> 日期：2026-08-16  
> 任务书：`tasks/C01-main-deterministic-flush-dispatch.md`  
> OUT：`/tmp/juicefs-c01-20260816-220647`  
> archive：`/tmp/juicefs-c01-20260816-220647-artifacts.tar.gz`（sha256 `2c6bfb27e1a965cd99234ccdf33cc5385e5ab1cbe2983eb0c09436711dbb7594`）  
> 性质：基线阻塞，未注入测试，未应用补丁

---

## 一、执行摘要

C01 任务书要求在 main 提交 `edabf9c2` 上用确定性单元测试复现"首个整块写漏派发"缺陷，并验证两种候选修法（A 同步 ID / B 异步补派发）。

步骤 0~2（通读、建目录、三臂 clone）全部完成。步骤 3（原始基座健康验证）阻塞：`go test ./pkg/vfs ./pkg/chunk -count=1` 返回 rc=1，不满足 §2.4 通过条件"原始基座测试须在注入 C01 测试前 PASS"。

用户指示停止并报告。

---

## 二、完成步骤

### 步骤 0：通读与 preflight

- 通读了任务书全文、TASK-BOOK-AUTHORING-GUIDE §二.8/§二.9/§二.11/§二.12、SYSTEM-SAFETY-SKILL 全文、docs/SUMMARY.md
- `meta/preflight.txt` 逐条确认：不运行生产测试、stock FAIL 是预期、不改固定提交/测试/补丁、变量变更须停止、不覆盖现有 /tmp/juicefs-*

### 步骤 1：建立隔离目录

- `OUT=/tmp/juicefs-c01-20260816-220647`
- `meta/source-refs.txt` 冻结：source=/home/lilingfeng/project/juicefs, main_commit=edabf9c2..., sync_patch=juicefs-flush-race-fix-main.patch
- `meta/go-env.txt`：go1.26.0 linux/amd64, GOPROXY=https://proxy.golang.org,direct, GOTOOLCHAIN=auto
- `meta/uname.txt`：Linux GM1B7TBT 6.6.114.1-microsoft-standard-WSL2 x86_64

### 步骤 2：三臂独立 clone

| 臂 | HEAD | 门禁 |
|---|---|---|
| S-stock | `edabf9c24601510476e7453abff177f4aaca07ac` | ✅ |
| A-sync | `edabf9c24601510476e7453abff177f4aaca07ac` | ✅ |
| B-async-catchup | `edabf9c24601510476e7453abff177f4aaca07ac` | ✅ |

门禁 `awk '$2 != want {bad=1}' arm-heads.tsv` rc=0，三臂 HEAD 全部等于固定提交。

---

## 三、阻塞点：步骤 3 基线验证

### 3.1 执行过程

任务书步骤 3 要求：

```bash
export GOCACHE="$OUT/cache/go-build"
export GOMODCACHE="$OUT/cache/go-mod"
export GOTOOLCHAIN=local
go mod download    # BASE_RC 须为 0
go test ./pkg/vfs ./pkg/chunk -count=1   # BASE_RC 须为 0
```

#### 第一次尝试

- GOPROXY 默认 `https://proxy.golang.org,direct`
- `go mod download` 超时（dial tcp 142.250.21.141:443: i/o timeout）
- rc=1，记录于 `logs/go-mod-download.log`

#### 环境适应 #1：GOPROXY 换镜像

- 改为 `GOPROXY=https://goproxy.cn,direct`
- 记录于 `meta/dependency-adaptations.txt`

#### 环境适应 #2：GOMODCACHE 从全局复制

- 全局 GOMODCACHE 已有 418M 缓存（之前构建过 JuiceFS）
- `cp -a /home/lilingfeng/go/pkg/mod/. "$OUT/cache/go-mod/"`（2.0G，成功）
- 避免写入全局 module cache

#### 环境适应 #3：GOCACHE 移出 /tmp

- /tmp 是 tmpfs，总容量仅 7.7G
- 三份 clone（369M）+ GOMODCACHE（2.0G）+ GOCACHE 副本 = 超出 tmpfs
- 复制全局 GOCACHE 到 OUT 失败：`设备上没有空间`
- 改为 `GOCACHE=/home/lilingfeng/tmp/c01-gocache`（隔离目录，非全局 ~/.cache/go-build）
- 同时设置 `GOTMPDIR=/home/lilingfeng/tmp/c01-gotmp`（Go $WORK 编译中间文件 >3G）

#### 第二次尝试（最终）

- `go mod download` rc=0 ✅（goproxy.cn 成功）
- `go test ./pkg/vfs ./pkg/chunk -count=1` rc=1 ❌
- 记录于 `logs/S-stock-baseline-packages.log`

### 3.2 失败根因（两个独立问题）

#### 问题 1：pkg/chunk — mockey 与 Go 1.26 不兼容（build failed）

```
# github.com/bytedance/mockey/internal/monkey/inst.duffcopy·f:
  relocation target runtime.duffcopy not defined
# github.com/bytedance/mockey/internal/monkey/inst.duffzero·f:
  relocation target runtime.duffzero not defined
FAIL github.com/juicedata/juicefs/pkg/chunk [build failed]
```

**分析**：

- mockey 库用于 `pkg/chunk/disk_cache_test.go`，通过运行时函数替换实现 mock
- `runtime.duffcopy` / `runtime.duffzero` 是 Go 运行时的内部符号，用于结构体拷贝/清零
- 这两个符号在 Go 1.24 起被移除/改签名（mockey 依赖的汇编桩失效）
- go.mod 声明 `go 1.25.0`，本机安装的是 `go1.26.0`
- `GOTOOLCHAIN=local` 阻止 Go 自动下载 1.25.0 工具链
- 即使能使用 Go 1.25.0，mockey 仍可能不兼容（duffcopy 移除始于 1.24）

**影响**：pkg/chunk 的测试二进制无法链接，`go test ./pkg/chunk` 永远返回 build failed。

**无法通过环境适应解决**：

- 禁止修改 go.mod/go.sum（§5.9 红线）
- 禁止修改源码（§5.9 红线）
- 安装 Go ≤1.23 可能解决，但属于大范围环境变更

#### 问题 2：pkg/vfs — Redis 不可用（test FAIL）

```
redis: 2026/08/16 22:26:11 pool.go:617: redis: connection pool: failed to dial
  after 5 attempts: dial tcp 127.0.0.1:6379: connect: connection refused
FAIL github.com/juicedata/juicefs/pkg/vfs 85.173s
```

**分析**：

- pkg/vfs 的测试二进制编译成功（非 build failed），85 秒内执行了多个测试
- 部分测试使用 Redis 作为元数据引擎（`127.0.0.1:6379`）
- 本环境无 Redis 实例
- §1.4 明确禁止访问 Redis

**影响**：依赖 Redis 的测试 FAIL，导致 `go test ./pkg/vfs` 整体返回 rc=1。

### 3.3 C01 测试本身不受影响

| 检查项 | 结果 |
|---|---|
| pkg/vfs 测试是否用 mockey | 否（`grep -rl 'bytedance/mockey' pkg/vfs/*_test.go` 无匹配） |
| pkg/vfs 测试是否用 gomonkey | 否（`grep -rl 'agiledragon/gomonkey' pkg/vfs/*_test.go` 无匹配） |
| 附录 A 测试是否需 Redis | 否（纯内存 mock：`c01DelayedNewSliceMeta` + `c01RecordingWriter` + `c01ChunkStore`） |
| 附录 A 测试是否能编译 | 理论可以（pkg/vfs 测试二进制编译成功，mockey 不影响 pkg/vfs） |

即：若跳过基线门禁直接注入测试，`go test ./pkg/vfs -run '^TestFullBlockWriteIsDispatchedWhenSliceIDBecomesReady$'` 预期能编译并运行。但任务书 §2.4 禁止在基线未通过时注入测试。

---

## 四、环境适应全量记录

| # | 适应项 | 原值 | 新值 | 原因 | 任务书依据 |
|---|--------|------|------|------|------------|
| 1 | GOPROXY | https://proxy.golang.org,direct | https://goproxy.cn,direct | proxy.golang.org 不可达（i/o timeout） | §3 "允许调整 GOPROXY" |
| 2 | GOMODCACHE | 全局 /home/lilingfeng/go/pkg/mod | OUT/cache/go-mod（从全局复制 2.0G） | 禁止写全局 module cache | §2.1 "禁止写全局 module/build cache" |
| 3 | GOCACHE | OUT/cache/go-build（/tmp tmpfs） | /home/lilingfeng/tmp/c01-gocache | /tmp 7.7G 不足以放 Go build cache（编译 JuiceFS 需 >3G） | §5.9 "允许修复只读路径" |
| 4 | GOTMPDIR | 未设置（默认 /tmp） | /home/lilingfeng/tmp/c01-gotmp | Go $WORK 编译中间文件 >3G，tmpfs 不足 | §5.9 "允许修复只读路径" |

记录于 `meta/dependency-adaptations.txt`。

---

## 五、summary.tsv 全文

```
arm	test	rc	expected	log	expectation_matched
S-stock	baseline-packages	1	0	logs/S-stock-baseline-packages.log	NO
S-stock	go-mod-download	0	0	logs/go-mod-download.log	YES
```

---

## 六、arm-heads.tsv 全文

```
S-stock	edabf9c24601510476e7453abff177f4aaca07ac
A-sync	edabf9c24601510476e7453abff177f4aaca07ac
B-async-catchup	edabf9c24601510476e7453abff177f4aaca07ac
```

---

## 七、基线测试日志要点

### go mod download

```
rc=0（使用 goproxy.cn 成功）
```

### go test ./pkg/vfs ./pkg/chunk -count=1

```
# pkg/chunk 链接错误：
github.com/bytedance/mockey/internal/monkey/inst.duffcopy·f:
  relocation target runtime.duffcopy not defined
github.com/bytedance/mockey/internal/monkey/inst.duffzero·f:
  relocation target runtime.duffzero not defined

# pkg/vfs 测试输出（尾部）：
redis: connection pool: failed to dial after 5 attempts:
  dial tcp 127.0.0.1:6379: connect: connection refused

FAIL github.com/juicedata/juicefs/pkg/vfs 85.173s
FAIL github.com/juicedata/juicefs/pkg/chunk [build failed]
FAIL

rc=1
```

完整日志见 `logs/S-stock-baseline-packages.log`（归档于 artifacts.tar.gz）。

---

## 八、合规自查

| # | 检查项 | 结果 |
|---|--------|------|
| 1 | 是否只使用固定 main commit | YES（三臂 HEAD 全部 = edabf9c2） |
| 2 | 是否未修改 SOURCE 和现有 worktree | YES（只读 clone，未 push/commit） |
| 3 | 是否未运行 fio/mount/Ceph/TiKV 命令 | YES（只运行 go mod download + go test） |
| 4 | 是否未执行 sudo/OSD restart/pool 操作 | YES |
| 5 | 是否未改 go.mod/go.sum | YES |
| 6 | 是否未改变附录 A/B 的语义 | YES（未到达注入步骤） |
| 7 | 是否所有预期外错误均完整保留 | YES（logs/S-stock-baseline-packages.log 完整） |
| 8 | 是否未 git commit/push/发 issue | YES |
| 9 | commands.sh/summary.tsv/diff/日志/rc 是否齐备 | YES（无 diff，因未注入测试/补丁） |
| 10 | 是否保留 OUT/src 和 OUT/cache 供复核 | YES |

---

## 九、可能的解法（供 Codex 参考）

### 方案 A：安装 Go ≤1.23

- mockey 依赖的 `runtime.duffcopy`/`runtime.duffzero` 在 Go ≤1.23 仍存在
- 需下载安装 Go 1.23.x，设置 GOROOT 指向它
- go.mod 声明 `go 1.25.0`，但 Go 1.23 可以编译（go.mod 的 go 指令是最低要求而非严格上限，实际行为取决于 GOTOOLCHAIN）
- **风险**：Go 1.23 可能无法编译 go.mod 中要求 1.25.0 的代码（如果使用了 1.25 新特性）
- **需验证**：Go 1.23 能否编译 JuiceFS main edabf9c2

### 方案 B：只跑 pkg/vfs，跳过 pkg/chunk

- C01 测试在 pkg/vfs，附录 A 不依赖 pkg/chunk 的测试编译
- 修改 Q3 判据：`go test ./pkg/vfs` 替代 `go test ./pkg/vfs ./pkg/chunk`
- pkg/vfs 编译成功（85s 运行），只是部分测试需 Redis
- 用 `-run` 精确匹配只跑 C01 两个测试，不触发 Redis 依赖
- **风险**：修改了任务书判据，需 Codex 批准

### 方案 C：本地启 Redis

- `apt install redis-server` 或 `podman run -d -p 6379:6379 redis`
- 解决 pkg/vfs 的 Redis 依赖
- 但 §1.4 明确"不访问 Redis"
- **风险**：违反任务书红线，不推荐

### 方案 D：升级 mockey

- go.mod 中 mockey 可能有兼容 Go 1.26 的新版本
- 但 §5.9 禁止修改 go.mod
- **不可行**：除非 Codex 授权修改 go.mod

---

## 十、归档清单

| 文件 | 说明 |
|------|------|
| `meta/preflight.txt` | 步骤 0 确认 |
| `meta/source-refs.txt` | 源仓库/提交/补丁路径 |
| `meta/go-env.txt` | Go 版本与环境 |
| `meta/uname.txt` | 系统信息 |
| `meta/arm-heads.tsv` | 三臂 HEAD |
| `meta/dependency-adaptations.txt` | 环境适应记录 |
| `meta/archive-path.txt` | 归档路径 |
| `meta/out-path.txt` | OUT 路径 |
| `meta/taskbook.snapshot.md` | 任务书快照 |
| `logs/go-mod-download.log` | go mod download 日志 |
| `logs/S-stock-baseline-packages.log` | 基线测试完整日志 |
| `logs/clone-{S-stock,A-sync,B-async-catchup}.log` | 三臂 clone 日志 |
| `logs/sha256-check.log` | SHA256SUMS 校验 |
| `rc/go-mod-download.rc` | 0 |
| `rc/S-stock-baseline-packages.rc` | 1 |
| `rc/sha256-check.rc` | 0 |
| `commands.sh` | 全部执行命令 |
| `summary.tsv` | 结果汇总 |
| `SHA256SUMS` | 证据文件校验和 |

OUT/src（三份 clone）和 OUT/cache 保留在 /tmp 供 Codex 复核，未纳入归档。

---

## 十一、Codex 后续复核与阶段裁定

> 追加日期：2026-08-17  
> 本节是对 GLM 原始报告的后续分析；不改写前文原始执行记录。

### 11.1 证据边界

本轮在注入 C01 测试和应用 A/B 补丁之前即被基线门禁阻塞。因此已有证据只能用于判断“原任务为什么跑不下去”，不能用于判断 main 是否存在漏派发，也不能用于判断任一补丁是否有效。

追加本节时，报告所列的根级 `/tmp/juicefs-c01-20260816-220647` OUT 与 archive 均已不存在，无法再独立校验 archive hash 和原始日志；以下裁定以本报告保留的执行记录为边界。该情况不改变“本轮没有产生缺陷/补丁结论”，但意味着 C01 不能作为长期可回放的原始证据包。

### 11.2 分析

1. `go mod download` 成功，三臂也固定到了同一 main commit；真正阻塞发生在混合执行 `./pkg/vfs ./pkg/chunk` 的全包基线。
2. `pkg/vfs` 失败来自既有 Redis 用例，`pkg/chunk` 失败来自 mockey 与本机 Go 1.26 的链接兼容性；两者都不是新增 C01 纯内存测试的失败证据。
3. 原任务同时要求“不访问 Redis”并运行会访问 Redis 的完整 `pkg/vfs`，门禁设计自身不闭合。为这个最小源码问题启动 Redis 没有必要，应改成包编译门加明确的纯内存测试白名单。
4. `/tmp` 是容量不足的 tmpfs，不适合作为三臂源码、模块缓存和构建缓存根目录；后续执行必须迁到 `/home/lilingfeng/tmp`。
5. 报告提出的“降到 Go ≤1.23”不采纳：固定 main 的 `go.mod` 已要求 Go 1.25 系，正确做法是以 Go 1.25.7 对齐项目基线，再用本机 Go 1.26.0 做定向兼容验证。
6. 本轮没有注入测试、没有应用 A/B、没有出现目标 marker；“C01 测试本身不受影响”只能是静态推断，不能升级为测试结论。

### 11.3 正式裁定

~~~text
C01-REVIEWED = BLOCKED-BASELINE / NO DEFECT OR PATCH VERDICT
~~~

- 可保留的结论：原全包基线不适合无外部服务的源码级最小复现，且根级 `/tmp` 容量不足。
- 不允许的结论：main 已复现缺陷、A/B 已修复缺陷、任一候选可进入性能或社区流程。
- 后续动作：以全新磁盘 OUT、Go 1.25.7/1.26.0 双工具链、定向纯内存测试和三臂隔离设计执行 C01-R1。
