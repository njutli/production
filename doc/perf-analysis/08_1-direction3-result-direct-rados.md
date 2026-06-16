# 08_1 方向三实测结论：去 RGW 直连 RADOS（2026-06-16）

> 本文是 `08-next-steps-comparison.md` 方向三（去 RGW 直连 RADOS）的**独立实测记录**。
> 结论一句话：**RGW 不是随机读的根因**——去掉 RGW 后随机写大涨、随机读反而下降，
> 瓶颈被锁定到 **JuiceFS 单客户端 FUSE / 读并发调度层**。
> 详细规划与衔接见 `08`，随机读诊断方法论见本文"五、下一步如何定位瓶颈"。

---

## 一、实验目的

验证 `07` 的根因假设：**「RGW 对象 GET ~100ms 延迟是随机读的主因」**。
手段：让 JuiceFS 绕过 RGW（S3 网关），改用 **librados 后端直连 RADOS**，
少一层 HTTP/RGW 往返，对比随机读写带宽变化。

- 这是一次**排除法实验**：它本身不直接指出瓶颈是谁，而是验证/排除「RGW」这个头号嫌疑。
- 这是判断「后续 JuiceFS 客户端调优（方向一）是否值得做」的前提。

---

## 二、实验配置

| 项 | 值 |
|----|----|
| 后端 | `STORAGE=ceph`（JuiceFS librados 直连），独立 EC 池 `juicefs-data`（EC 4+2, crush-failure-domain=osd, allow_ec_overwrites=true） |
| cephx 用户 | `client.juicefs`（mon `allow r` / osd `allow rwx pool=juicefs-data`） |
| 元数据 | TiKV（`tikv://192.168.11.12:2379/juicefs-prod`），不变 |
| fio 规格 | 256k / iodepth=128 / numjobs=128 / direct=1 / time_based runtime=60s（验收口径） |
| 对照基线 | S3(RGW) 路径下的随机写 38、randrw 读 3.8 / 写 38（见 `07`） |

### 关键修复：JuiceFS Ceph 后端的认证参数

初次 `juicefs format --storage ceph` 报 `Invalid argument`。多轮 debug 确认：
**JuiceFS 的 Ceph 后端把 S3 风格的认证字段重映射了**——

| JuiceFS 参数 | 在 Ceph 后端的实际含义 |
|--------------|------------------------|
| `--access-key` | **Ceph 集群名**（通常 `ceph`） |
| `--secret-key` | **Ceph 用户名**（如 `client.juicefs`，对应 `/etc/ceph/ceph.client.juicefs.keyring`） |

正确写法（已硬编码进 `tests/bench-juicefs.sh` 的 `do_format` ceph 分支）：

```bash
juicefs format --storage ceph --bucket ceph://juicefs-data \
    --access-key ceph --secret-key client.juicefs \
    --trash-days 0 tikv://192.168.11.12:2379/juicefs-prod juicefs-prod
```

---

## 三、执行差异说明（实际操作 vs bench 脚本）

实测时**未能直接一把跑完 `bench-juicefs.sh`**，原因有二，已逐一处理：

| 差异 | 原因 | 处理 |
|------|------|------|
| keyring 部署方式改为先 `ceph auth get-key` 再手写 | cephadm shell 内 `-o keyring` 重定向未落到宿主机 | 直接取 key 拼 keyring，结果等价 |
| 纯 randread 布局阶段需写 128GB（128 jobs × 1G），>20min 触发超时（当时脚本结构每个随机用例各铺一次） | 布局逻辑过重、且重复布局 | 当时手动只跑 randwrite + randrw（与脚本验收口径等价）；事后已修脚本：布局只做一次 + randread 复用 + 顺序重排（见七） |

> **口径对齐说明**：验收基线 3.8/38 本就出自 **randrw（verbatim, `--create_on_open=1` 自建文件、不预铺）**，
> 手动跑的 randwrite/randrw 与脚本对应用例完全等价，结果**可直接对比，可信**。

---

## 四、测试结果与结论

### 测试结果（STORAGE=ceph，EC 4+2，验收规格 60s）

| 用例 | S3 (RGW) 基线 | Direct RADOS | 变化 |
|------|---------------|--------------|------|
| 顺序读 | ~100 MB/s | 100 MB/s | — |
| 顺序写 | ~102 MB/s | 102 MB/s | — |
| 纯随机写（randwrite） | 38 MB/s | **65.1 MB/s** | **+71%** |
| 混合随机读写（randrw）— 读 | 3.8 MB/s | **2.2 MB/s** | **−42%** |
| 混合随机读写（randrw）— 写 | 38 MB/s | **33.4 MB/s** | −12% |

### 结论

1. **随机写 +71%（38→65.1）**：RGW 层确实是**写入路径**的瓶颈之一。
   去掉 HTTP/RGW 转发后，逐对象写入直连 RADOS 受益明显（已超目标 59 的写侧门槛）。
2. **随机读 −42%（3.8→2.2，不升反降）**：**推翻** `07` 的「RGW GET ~100ms 是随机读主因」假设。
   去 RGW 后读不但没提升反而更差 → **瓶颈不在 RGW HTTP 层，在 JuiceFS 客户端读路径**。
3. **方向三判定**：RGW 不是随机读根因。按 `08` 判定逻辑，**转回方向一**，
   但打法要从「换后端组件」改为「量化并发」（见五）。

---

## 五、关键分析：为什么 RGW 不是瓶颈？读为什么反而降？

### 1. `juicefs stats` 显示 RGW 延迟高 ≠ RGW 是病因

`stats` 里看到的 object GET ~100ms 是**现象**，有两种成因：

- **A. RGW 本身慢**（处理一个 GET 要 100ms）→ 去掉 RGW 应变快。
- **B. RGW 不忙，但上游（FUSE/客户端）很少并发发请求**，GET 在队列里等 → 端到端显示 100ms。

本次「去 RGW 读反而 3.8→2.2」**直接证伪 A、坐实 B**：
高延迟是**「等出来的」（并发不足），不是「算出来的」（RGW 处理慢）**。

### 2. 去掉 RGW 读为什么反而下降？

两个合理解释（待五-下的诊断确认）：

- **缓存/预读流水线变保守**：JuiceFS 对 S3 后端有成熟的并发 GET / 预读；
  换 librados 后端后并发/预读策略更保守，单请求虽更短但**并发度更低**，总吞吐反降。
- **丢失了 RGW 的「无意并发扇出」**：S3 路径前有 HAProxy + 多 RGW，GET 被摊到多 RGW 并行；
  直连 RADOS 时对象固定落某 OSD，少了这层扇出。

无论哪种，**共同指向同一句话：随机读瓶颈是「并发度 / in-flight 请求数」不够，不是单请求延迟。**

### 3. 嫌疑范围收敛

| 嫌疑 | 状态 |
|------|------|
| 网络 | ❌ 已排除（千兆，`03`） |
| 裸盘 | ❌ 已排除（4K 随机读 92500 IOPS，`06`） |
| RGW HTTP 层 | ❌ **本次排除**（去掉读反而降） |
| **JuiceFS 单客户端 FUSE / 读并发调度** | ✅ **当前最强嫌疑** |

旁证：`06_3` CephFS（内核态、无 FUSE、同后端）随机读 13.9，是 JuiceFS 3.8 的 **3.6 倍**，
唯一差别就是 **FUSE 层**。

---

## 六、下一步如何定位瓶颈（从「换后端」转向「量并发」）

打法转变：之前是换组件（网络→RGW→后端），已到头；接下来做**白盒诊断，直接量「并发够不够」**。

| 手段 | 看什么 | 能区分什么 |
|------|--------|------------|
| **A. `juicefs stats` + randread 同跑** | object GET 的 in-flight 并发数与延迟 | 若并发恒为个位数 → 客户端没打满队列 = 调度/FUSE 瓶颈（零成本，先做） |
| **B. 调 `--max-downloads` / `--buffer-size`（方向一 1.1/1.2）** | 上调并发上限后 randread 是否随之升 | 升 → 瓶颈是并发上限（可解）；不动 → FUSE 单线程瓶颈 |
| **C. 多客户端并发实验（关键判别）** | 2 个客户端各跑 randread 看聚合带宽 | 聚合≈2× → 单客户端是软件天花板，横向扩展即可达标；聚合不变 → 后端共享瓶颈 |
| **D. CephFS 内核态对照（已有 13.9）** | 无 FUSE 的读为 3.6× | 已强烈暗示 FUSE 层是主因 |

**最强假设**：瓶颈 = JuiceFS 单 FUSE 进程的读并发序列化。
**最高性价比的判别实验是 C（多客户端）**：直接回答「单客户端软件天花板，还是集群硬上限」。

### 建议顺序

1. 先跑 **A**（stats 盯并发，几乎零成本）。
2. 再跑 **B 的 1.1 / 1.2**（用已修脚本，在 RADOS 路径上调 max-downloads / buffer-size）。
3. 若 B 无效 → 跑 **C 多客户端**，据此决定「调客户端」还是「上多客户端架构 / 转 CephFS」。

---

## 七、脚本修复（bench-juicefs.sh，配合本方向）

实测暴露的 step 布局 128GB 超时问题已修复，并重排了测试顺序：

- **测试顺序重排**：布局（pre-fill）只做**一次**（step 8），紧随其后的纯 randread（step 9）
  **复用同一批文件**；其余顺序测试（4G 单/多 job）与 randwrite/randrw 均不写满 128GB。
- **randread 与布局严格对齐**：step 9 randread 的 `--numjobs`/`--filesize`/`--size`
  引用 `LAYOUT_NUMJOBS`/`LAYOUT_FILESIZE`，与 step 8 布局完全一致 —— 避免「布局调小、randread
  仍按 128 job 跑」时 `--create_on_open=1` 现建空文件、**读到空洞导致虚高**。
  `bs/iodepth/direct/time_based` 保持验收规格。
- 新增 env：
  - `LAYOUT_NUMJOBS`（**默认 128**，即 128GB 完整口径）、`LAYOUT_FILESIZE`（默认 1G）；
  - `SKIP_SEQ=1`：跳过顺序测试（step 4-7），只跑布局 + 随机三项，调参迭代省 ~20min。
- `do_format` ceph 分支已硬编码 `--access-key ceph --secret-key client.juicefs`，
  `STORAGE=ceph bash tests/bench-juicefs.sh` 现可一把跑完。

### 工作流：调参用轻量、定稿用完整

| 阶段 | 配置 | 看什么 | 说明 |
|------|------|--------|------|
| 调参迭代 | `SKIP_SEQ=1 LAYOUT_NUMJOBS=16`（+ 挂载 `--cache-size 0`） | `juicefs stats` 并发数 + randread **相对变化** | 快速筛参数（~10min）。⚠️ 251G 内存下 16G 工作集易被 page cache 兜住，必须关 JuiceFS 缓存，否则趋势失真 |
| 定稿验证 | `LAYOUT_NUMJOBS=128`（verbatim 128G） | randread/randrw **绝对带宽** | 出正式结论、与 3.8 基线对比、报验收数。整轮 ~45-50min |

> ⚠️ **16 ≠ 128 的口径差异**：① 16G 工作集在 251G 内存下可能命中缓存使带宽虚高；
> ② randread 并发度 16 jobs vs 128 jobs 差 8 倍，瓶颈在客户端并发时带宽显著不同。
> 故 **16 仅用于看相对趋势，绝对值与正式结论必须用 128 完整重跑**（可能存在 16→128 拐点，不能外推）。

### 预估时长

| 配置 | 时长 |
|------|------|
| 完整（SKIP_SEQ=0, LAYOUT=128） | ~45-50min（128G 布局 ~15-20min + 顺序多 job ~20min + 随机三项各 60s + fresh_volume × N 各含 65s 会话过期） |
| 调参（SKIP_SEQ=1, LAYOUT=128） | ~25-30min（省顺序测试 ~20min，128G 布局仍是大头） |
| 极速（SKIP_SEQ=1, LAYOUT=16） | ~10min（仅看趋势） |

---

## 八、环境清理状态

> 方向三测试完成后已清理：pool `juicefs-data` 已删除，cephx 用户 `client.juicefs` 已删除。
> 如方向一需在 RADOS 路径上验证，需按 `08` 方向三步骤重新创建。
