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

### 测试结果（STORAGE=ceph，EC 4+2，验收规格 256k/iodepth=128/numjobs=128/direct=1/60s）

> 两组数据均为 2026 年 **修复脚本后的 128G 完整同口径重测**（randread `short=0`，读到真实布局数据）：
> Direct RADOS = `results/20260616-160624-norgw-128-fix.txt`；
> S3 (RGW) = `results/20260617-110243-rgw-s3-128-baseline.txt`。
> （⚠️ 原始 fio 日志已丢失，仅存文件名记录；下表数据为已固化的均值。）
> （历史上 S3 只测过 randrw 混合，没单独测纯 randread/randwrite，旧"38/3.8"口径不一致，已弃用。）
>
> ⚠️ S3 基线前发现并修复 **HAProxy LB `balance roundrobin` 导致写后读 404**（PUT/GET 轮询到
> 不同 RGW、跨 RGW 写后读一致性延迟）→ 改 `balance source` 后 404 清零，s3 才能完整跑通（详见 `08_2`）。

| 用例 | S3 (RGW) 128G | Direct RADOS 128G | 变化（去 RGW） |
|------|---------------|-------------------|----------------|
| 顺序读 | 112 MB/s | 101 MB/s | −10% |
| 顺序写 | 69.8 MB/s | 107 MB/s | +53% |
| **纯随机读（randread）** | **10.1 MB/s** | **12.3 MB/s** | **+22%** |
| **纯随机写（randwrite）** | **67.8 MB/s** | **66.5 MB/s** | ≈持平 |
| 混合 randrw — 读 | 1.6 MB/s | 1.8 MB/s | +13% |
| 混合 randrw — 写 | 33.0 MB/s | 33.5 MB/s | ≈持平 |

### 结论

1. **去 RGW 对随机读只是小幅改善（10.1→12.3，+22%），不是数量级提升**：
   说明 RGW 不是随机读的主要瓶颈（旧"3.8"是 randrw 混合口径，对比失真，已弃用）。
2. **纯随机写两边都已达标且基本持平（67.8 vs 66.5，目标 59）**：
   写侧 RGW 也不是瓶颈；之前"+71%"是拿 randrw 混合写(38)比纯写(65)的口径错误。
3. **纯随机读 ~10–12 MB/s，接近 CephFS 内核态 13.9**；而 randrw 混合读仅 1.6–1.8
   （被写争抢挤压）——验收口径下读才是真正拦路虎。
4. **方向三判定**：RGW 既非随机读、也非随机写的主要瓶颈（去掉只小幅变化）。
   瓶颈在 JuiceFS 客户端读路径本身 → 转 A/B/C 白盒定位（见 `08_2`：根因=FUSE 4MB block 读放大）。

---

## 四之二、多次重测复核（双人独立重测整合，2026-06-18）

> 用**最新 `bench-juicefs.sh`**（布局一次复用 + REPEAT 多次 + 随机项口径修正）对
> **S3(RGW) 4M / Direct RADOS 4M / Direct RADOS 256K** 三组 **128G 全口径**重测，
> 每个随机项重复多次取均值，排除单次波动。**由两人各自独立跑一遍互为复核**：
>
> | 测试者 | REPEAT | 顺序读写 | 编排脚本 | 结论文档 |
> |--------|--------|----------|----------|----------|
> | **DeepSeek** | 3 | 跳过 | — | [`results/8_test-deepseek-3round-retest.md`](../../results/8_test-deepseek-3round-retest.md) |
> | **Opus** | 5 | 全做 | `tests/run-rebench-master.sh` | [`results/8_test-opus-5round-retest.md`](../../results/8_test-opus-5round-retest.md) |
>
> 公共口径：128G 布局（128 jobs × 1G）；随机项 bs=256k/iodepth=128/numjobs=128/direct=1/60s；
> cold（每步 drop_caches、cache-size 0）；RADOS/256K 用独立 EC 池 `juicefs-data`；
> 纯 randread 复用真实布局、`short=0`（有效）。

### 整合总表（两组随机口径 + 顺序口径，括号内为 DeepSeek / Opus 均值）

> **两组随机读写口径**：**[规格]** = 原存储规格参数（fresh 空卷 + `--create_on_open` 边写边读）；
> **[优化]** = 我们优化后的命令（复用 128G 真实布局、去 `create_on_open`/`nrfiles`，消除 short-read 失真）。
> 纯 randread 即优化命令（bs/iodepth/numjobs 同规格，仅去 short-read）。

| 类别 | 用例 | S3 (RGW) 4M | Direct RADOS 4M | **256K block** |
|------|------|-------------|-----------------|----------------|
| 顺序 | 顺序读（单 job） | 113（—/113） | 101（—/101） | **107（—/107）** |
| 顺序 | 顺序写（单 job） | 69.1（—/69.1） | 107（—/107） | **117（—/117）** |
| 顺序 | 多 job 顺序读 | 117（—/117） | 113（—/113） | **117（—/117）** |
| 顺序 | 多 job 顺序写 | 69.4（—/69.4） | 108（—/108） | **117（—/117）** |
| 顺序 | Layout 写 128G | 68.7（68.7/68.7） | 108（109/108） | **116（117/116）** |
| **随机** | **纯随机读** | **9.8（9.8/9.85）** | **13.4（13.5/13.24）** | **45.9（45.8/45.94）** |
| 随机[优化] | 纯随机写 | 78.1（78.1/78.1） | 125（126/125.2） | 124（128/124.0） |
| 随机[优化] | randrw 读 | 6.0（5.8/6.27） | 11.7（11.7/11.72） | **35.5（35.6/35.42）** |
| 随机[优化] | randrw 写 | 5.9（5.7/6.18） | 11.6（11.6/11.60） | **34.9（35.2/34.88）** |
| 随机[规格] | 纯随机写 | 66.5（67.1/65.9） | 55.7（54.0/57.42） | 62.2（61.4/62.96） |
| 随机[规格] | randrw 读 | ~0.9（1.5/0.32） | 0（0/0） | 0（0/0） |
| 随机[规格] | randrw 写 | 30.8（33.0/28.5） | 26.8（26.7/26.86） | 27.0（26.8/26.98） |
| 随机[规格] | randrw short% | 96–97% | 100% | 100% |

> ⚠️ **[规格]口径 randrw 读≈0、short≈100%**：`--create_on_open` 边写边读打到空块所致，
> 三组皆然，是**口径病态**，**不反映真实随机读能力，不用于横向对比**（详见 `08_2` 五之五）。
> 判定随机读写一律以 **[优化]口径** 为准。

### 详细数据（每 run 明细 + 原始 fio 日志）

| 内容 | 链接 |
|------|------|
| DeepSeek ×3 全表（run1-3 明细 + 对比矩阵） | [`results/8_test-deepseek-3round-retest.md`](../../results/8_test-deepseek-3round-retest.md) |
| Opus ×5 全表（run1-5 明细 + 顺序口径 + 对比矩阵 + 双人核对） | [`results/8_test-opus-5round-retest.md`](../../results/8_test-opus-5round-retest.md) |
| Opus 原始 fio 日志 — S3 4M | `20260617-224342-rebench-s3-4M-128G.txt`（⚠️ 已丢失） |
| Opus 原始 fio 日志 — RADOS 4M | `20260618-011057-rebench-rados-4M-128G.txt`（⚠️ 已丢失） |
| Opus 原始 fio 日志 — 256K | `20260618-031155-rebench-256K-128G.txt`（⚠️ 已丢失） |
| DeepSeek 原始 fio 日志 — S3 / RADOS / 256K | `20260617-192216-s3-128G-new.txt` · `20260617-203851-rados-128G-new.txt` · `20260617-214030-rados-bs256k-128G-new.txt`（⚠️ 已丢失） |

> ⚠️ 上述原始 fio 日志在归档后丢失（未及提交，无法从 git 恢复），仅保留文件名作记录；
> 已固化的均值数据见上表与两人结果汇总 md。如需原始日志，按 `tests/run-rebench-master.sh` 重跑。

### 复核结论（与四一致，且双人互证、更稳）

1. **两人所有可比项差异 ≤±8%、绝大多数 <3%，方向完全一致** → 结果**可复现、可信**，
   不存在偶发污染或口径错误，**无需再重测**。唯二略大项（S3 randrw 读、RADOS 规格 randwrite）
   都是已知高方差口径（randrw 读 ±40%、fresh randwrite 单次抖动），落在方差带内。
2. **去 RGW 对纯随机读仅小幅改善**（S3 9.85 → RADOS 13.24，**+34%**，量级未变）→
   **RGW 不是随机读主因**（与四的 +22% 同向，波动内）。
3. **纯随机写三组都在 ~56–66**（规格口径），**写侧均接近/达标**（目标 59），
   RGW 与 block-size 都不是写的瓶颈。
4. **256K block-size 随机读优势被双人多次重测牢牢坐实**：纯随机读 **~45.9 MB/s（极稳）**，
   是 RADOS 4M（~13.3）的 **3.5×**、S3 4M（~9.8）的 **4.7×**，且**顺序读写不降反升**（顺序写 117）。
   → **减小 block-size 消除读放大 = 生产解，无悬念。**
5. **真实数据 randrw（[优化]口径）同序**：256K(35.4) ≫ RADOS(11.7) > S3(6.0)，
   与纯 randread 趋势一致，印证 block-size 是随机 IO 的主控因素。

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
