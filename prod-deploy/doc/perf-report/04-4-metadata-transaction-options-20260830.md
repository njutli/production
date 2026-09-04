# 04-4 报告：JuiceFS 同步元数据事务架构方案审计

## 日期与机器可读结论

```text
ANALYSIS_ID=M1-20260830-GPT-SOURCE-AUDIT
EVIDENCE_CLASS=PAPER_ONLY_SOURCE_AND_HISTORICAL_EVIDENCE
VERDICT=M1_SINGLE_OPTION_ONLY
QUALIFYING_OPTION=O1_PER_INODE_MULTICHUNK_METADATA_BATCH
MODEL_GRADE=T2_CONDITIONAL_NOT_MEASURED
PRIORITY=PRIORITY_PENDING_A2
SOURCE_V13=EXACT_DELIVERED_BINARY_PROVENANCE_CLOSED
SOURCE_V14=EXACT_SOURCE_SEMANTICS_CLOSED_BUILD_REPRODUCIBILITY_PARTIAL
ENVIRONMENT_MUTATION=NONE
PROTOTYPE_EXECUTION_AUTHORITY=NO
NEXT_TASK=04-5-metadata-transaction-batching-prototype.md
```

一句话结论：现有 writer 已能并发上传、每个 chunk 也各有提交线程，但 completed slice 最终被同 inode
客户端锁、共同的 inode attr key 和同步 TiKV Commit 串成“一 slice 一事务”；四类方向中，只有在该 fan-in
处做 **同 inode、跨 chunk、仅 non-growing overwrite 的元数据事务批处理** 同时具备材料性上界、无新 schema、
默认关闭和旧路径回退能力，因此值得进入带前置插桩硬门的 04-5；其他三类不应为凑候选而进入原型。

---

## 1. 执行范围与证据包

本任务由 GPT 直接完成静态源码审计和历史证据复算。全过程没有 SSH、sudo、fio、mount、服务操作、编译、
源码修改或集群访问；唯一联网动作是取得官方 v1.4.1 tag 的只读源码，并以 `git apply --check` 验证现有
B-catchup patch 可用，未将 patch 写入源码树。

完整可复核证据位于：

`results/prod-stage04-analysis-20260830/m1-20260830-gpt-source-audit/`

其中 `callgraph.tsv`、`lock-transaction-map.tsv`、`keyset-conflict-map.tsv` 是源码静态路径；
`throughput-model.tsv` 是独立 roofline 复算；两种方法在“前端已有队列，但全局事务服务率不足”上闭合。

### 1.1 源码真值

| 视图 | 真值 | 闭合度 |
|---|---|---|
| V13 当前交付 | commit `e0032b2a...` + loadRange patch + B-catchup patch；binary MD5 `de93563f...`、SHA256 `3aa17f6c...`、BuildID 和 `go1.26.0` 均在 | **完整闭合** |
| V14 U1 候选 | 官方 v1.4.1 commit `0b90c7db...` + 同一 B-catchup patch；patch 对 tag `apply --check=PASS`；报告保留 binary MD5 `24fae085...` | exact build command、Go version、binary SHA256/BuildID 因本地构建现场丢失而未闭合 |

V14 的缺口不阻断本次 mechanics 判断：exact tag、精确 patch 和所有关键源文件已闭合；但它阻断“按原工具链
比特级复现 V14 二进制”。U1 尚未选定最终版本，04-5 在任何构建前必须先绑定 U1 结果并补齐所选基座的构建真值。

---

## 2. 真实写入与提交路径

```text
FUSE Write
  -> VFS.Write / handle.Wlock
  -> fileWriter.Write                 # 写入内存 slice 后即可返回，不等 meta commit
  -> sliceWriter.flushData (goroutine)# NewSlice + object Writer.Finish
  -> one chunkWriter.commitThread per active chunk
       -> wait head slice upload done
       -> Meta.Write(one slice)        # 当前 fan-in；每个 slice 单独调用
          -> baseMeta.Write
             -> openFile.Lock(inode)   # Write histogram 从锁前开始
             -> kvMeta.doWrite
                -> txBatchLock(inode)  # 客户端 1024-slot hashed inode lock
                -> TiKV transaction
                   read  inodeAttr + one chunkKey
                   write inodeAttr + one chunkKey
                   Enable1PC + EnableAsyncCommit
                   synchronous Commit # 客户端仍等待提交结果
          -> invalidate range / update stats / maybe compact chunk

Flush / Fsync / Close
  -> freeze pending slices
  -> wait fileWriter chunks empty      # 等对象上传和上述 meta commits 都完成
```

关键澄清有四点：

1. 普通 `write(2)` 返回点早于 metadata commit；真正等待全部提交的是 Flush/Fsync/Close。这不等于后台提交可任意
   乱序，因为跨客户端可见性、barrier、truncate 和 crash recovery 仍依赖当前顺序。
2. 并发并非不存在。1 GiB 文件有 16 个 64 MiB chunk，每个 active chunk 都有 commit thread；问题是这些线程
   进入 `baseMeta.Write` 后又在 inode lock 和共同 inode attr key 上收敛。
3. `doWrite` 对 overwrite 也每次读写 inode attr，并更新 mtime/ctime；不同 chunk 事务仍冲突于 inode attr。
4. V14 增加了 growing slice 的跨 chunk dependency，解决 length 增长顺序；它没有把 overwrite metadata commit
   pipeline 化，也没有减少一 slice 一事务。

### 2.1 为什么历史延迟能解释这个结构

03-18 有效计数显示 `meta Write / FUSE write = 0.9144--0.9154`，底层 transaction 约
`12.8--13.5 ms`，而 meta Write 约 `186--201 ms`。以约 `9--9.5K Write/s` 复算 Little 定律，
约有 `1700--1900` 个 Write 在飞/排队，即 128 inode 每条约 `13--15` 个。

这证明锁前队列很深，也与“16 个 chunk commit thread 最终挤入 inode 通道”一致；但它没有直接测出其中有多少
已完成对象上传且能同时进入一个 batch。因此 O1 的第一步必须是被动 ready-depth 插桩，不能把 13--15 直接写成
平均 batch size。

---

## 3. 四个方向的统一裁决

| 方向 | 事务数/并行度是否真正改变 | 正确性/回滚 | 模型级别 | 裁决 |
|---|---|---|---|---|
| **O1 同 inode跨 chunk批处理** | N 个 eligible slice 合成 1 个事务；读 inode 一次、各 chunk 一次 | 第一切片无 schema，默认 off，unsupported 全部 singleton fallback | **T2 conditional** | **唯一可实施候选** |
| O2 非关键字段异步化 | slice mapping 仍每 write 一事务；已有 dir/user/group stats 已在热事务外 | 延后 mtime/ctime 改 stat/crash/fsync 语义 | T0 | 不单独原型 |
| O3 有序 pipeline | 只拆本地锁会在共同 inode key 上 TiKV conflict/retry | 真并行需 epoch/guard/schema 并重做 truncate/fsync 顺序 | T0--T1 上界 | 不作为首原型 |
| O4 inode metadata分片 | chunk key 本来已分片；还需拆 inode attr 才有收益 | metadata version、mixed client、dual read/write、不可简单回滚 | 未可评级/XL | 转未来 RFC |

### 3.1 O1 的精确第一切片

候选边界为 `chunkWriter.commitThread -> Meta.Write`：每个 inode 的 coordinator 只收集已经完成上传的各 chunk
队首，首版仅允许 TiKV、`ChangeLog=false`、已存在文件的 non-growing overwrite；growth、quota delta、
truncate/fallocate/unlink 竞争、其他 engine 或任何不确定状态均走旧 singleton。

batch transaction 保持既有 key schema：读取一次 inode attr 和全部 distinct chunk keys，按确定顺序追加原有 slice
record，写一次 inode attr 和改变过的 chunk keys。建议初始 `max_items=8`、`max_wait<=200us`、预计编码后
transaction payload `<=512 KiB`，barrier 立即 drain；具体值只能在插桩后冻结，超出 item/byte cap 必须走旧路径。

失败模型必须是事务整体 abort；语义错误按 coordinator 原序 singleton replay。commit succeeded/ACK lost 要用现有
exact-slice duplicate detection 做幂等闭合并故障注入验证。V14 `ChangeLog=true` 时，一个 TiKV transaction 只有一个
transaction-ID log key，无法无设计地保留“一 logical write 一 log”，所以第一版强制 fallback，不能静默合并日志。

### 3.2 为什么 O2/O3 不是第二候选

把 mtime/ctime 延后可能减少 inode attr 的一部分工作，却不能删除 chunk mapping transaction；而把 inode attr
完全移出 transaction 才能让 O3 的不同 chunk 并行，这已经同时改变 stat、length、truncate、跨客户端冲突和 schema。
两者拼起来才可能有材料收益，但不再是可无损回滚的小原型。将其包装成两个候选只会重复计算同一未解决的 inode
一致性问题，因此本报告选择诚实签 `M1_SINGLE_OPTION_ONLY`。

---

## 4. 统一吞吐模型

目标为 `6250 / 0.25 = 25000 logical writes/s`。以历史稳定约 `12000 meta transactions/s` 和
`meta Write / logical write = 0.915` 作为参考，singleton ceiling 为：

```text
12000 / 0.915 * 0.25 = 3278.69 MiB/s
```

令平均有效 batch size 为 `b`，batch transaction 相对 singleton 的服务成本放大为 `k`：

```text
modeled_bw = 12000 * b / k / 0.915 * 0.25
actual_bw  = min(modeled_bw, unknown_random_write_data_path_ceiling)
```

| 情景 | b | k | b/k | 未计数据面 cap 的模型 BW | 相对 singleton |
|---|---:|---:|---:|---:|---:|
| conservative | 2.0 | 1.15 | 1.74 | 5702 MiB/s | 1.74× |
| base | 3.0 | 1.35 | 2.22 | 7286 MiB/s | 2.22× |
| optimistic | 6.0 | 2.00 | 3.00 | 9836 MiB/s | 3.00× |
| kill boundary | 1.5 | 1.25 | 1.20 | 3934 MiB/s | 1.20× |

该表只说明 O1 **有可能**越过约 2 倍事务率缺口，故标 `T2_CONDITIONAL`；它不证明 batch opportunity、1PC 保持、
事务成本或数据面 cap。03-22c 的有效 D1 中位仍为 `3756.51 MiB/s`，说明现环境距离目标很远；模型超过 6250
不能被写成“原型会达标”。

---

## 5. 正确性和回滚硬门

证据包 `correctness-obligations.tsv` 已将 15 项义务写成 precondition/fault/expected/kill。最容易被低估的是：

- batch 把原先逐 slice 的中间可见点变成多 slice 原子可见，虽然原子性更强，仍是可观察语义变化；
- Flush/Fsync/Close 必须等待 batch 真正 Commit，而不是只等入队；
- truncate/fallocate/hole/open-unlinked 与 batch 必须通过 drain 或 singleton fallback 排序；
- ACK 丢失、leader change、client kill 的 duplicate/replay 不得产生重复 slice；
- batch 跨过多个 slice-count compaction 阈值时，不得漏调度 compaction；
- V13/V14、gate on/off 的客户端都必须能读相同旧 schema；任一新 metadata version 即失去快速回滚资格。

第一原型 feature gate 默认 off；仅在新 volume 上启用；关闭开关无需 dump/load 或 migration。任一数据、slice map、
stat、barrier 或 crash recovery 不一致，直接 kill，不进入性能阶段。

---

## 6. 工作量与是否编写 04-5

O1 完整 prototype（未含生产化）估算 `17--30` 人日；其中最前面的只读/被动机制插桩约 `4--7` 人日。
O3 约 `32--51` 人日，O4 约 `65--130` 人日，且仍缺 schema/rollback 设计。详见 `workload-estimate.tsv`。

本报告决定 **需要编写 04-5**，但只批准“任务书存在”，不批准执行，理由是：

1. O1 的精确边界、fallback 和无 schema 回滚路径已经足以写成可审查原型；
2. 其 base 模型有材料上界，值得用很小的被动插桩先验证；
3. 04-5 把插桩 opportunity gate 放在行为修改之前，若平均 eligible batch `<2`、`b/k<1.25` 或 1PC 明显退化，
   可在低成本阶段停止；
4. 只有一个候选意味着路线风险高，所以不能把任务书写成“必做实现”，更不能绕过正确性硬门。

04-5 任务书为 `doc/perf-tasks/04-5-metadata-transaction-batching-prototype.md`，当前状态
`DRAFT_FOR_REVIEW / NO_EXECUTION_AUTHORITY`。开始前至少要完成：U1 最终二进制选择、所选源码/构建 provenance、
代码/脚本离线 Gate 0 和用户对新 volume/故障注入范围的明确授权。

---

## 7. 未闭合边界与最终建议

- A2 尚未完成，故原型与 TiKV 扩容/分片的最终优先级只能写 `PRIORITY_PENDING_A2`。
- U1 尚未完成，04-5 不能预设 V14；V14 build reproducibility 也需补齐。
- ready-depth、batch transaction 成本、1PC/fallback、random-write data cap 都是 04-5 Phase I/II 的实测问题。
- 本结论不改变 03 阶段生产交付配置；O1 是源码研发方向，不是现有配置参数。

当前最合理动作不是继续扫 JuiceFS/TiKV 小参数，也不是立刻写完整 batch patch，而是：先完成 U1；随后只实现
默认关闭的被动插桩。插桩硬门通过，才进入 O1 正确性原型；不通过则签负结论，转 A2/C03 容量路线或接受当前
randwrite 架构上限。
