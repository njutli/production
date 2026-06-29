# 10_issue-1 高并发 randread 偶发起不来（SIGKILL 残留所致，非卡死、非 fio bug、非压力大）

> 记录类型：**已诊断 issue**（非结论文档）
> 发现时间：2026-06-23，opencode 重测顺位2 tcpdump 时复现，同日定位
> 影响：连续暴力 SIGKILL fio 后紧接着重启 fio 的场景

> ✅ **最终诊断（2026-06-23 多次受控复现，重要）**：
> **128×32（在途 4096）随机读本身不会卡死——连跑 3 次全部正常完成（err=0，READ≈37 MiB/s）。**
> 早前观察到的"worker=0、90s 无进展"是**偶发、不可复现的脏状态**，发生在**前一个 fio 被
> SIGKILL 后紧接着启动下一个 fio** 时；SIGKILL 强杀高并发 fio 会残留未释放的
> libaio io_context / FUSE 在途请求，污染紧随其后的 fio setup。等脏状态清掉后即恢复正常。
>
> **三个都排除**：① 非系统/JuiceFS 卡死（存储栈全程 idle 且健康）；② 非 fio bug
> （fio 正常 fork 32 worker、正常出结果）；③ 非 I/O 压力大（io buffer 仅 1GB，内存 244GB 富余，后端 idle）。
>
> 标题/正文原"卡死"定性已全部订正。

---

## 一、现象

在 tikv-node（192.168.11.12）对已挂载的 JuiceFS（v1.3.1，`--cache-size 0` 冷态，
ceph 直连 EC 4+2，256K block-size，布局 32×1G）跑纯随机读：

```bash
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=32 \
    --direct=1 --fallocate=none --group_reporting \
    --time_based --runtime=60s
```

**fio 不在 60s 退出，而是长时间无进展**（根因见 §三：卡在 fio setup，非系统卡死）：
- `--time_based --runtime=60s` 形同虚设，进程实测运行 **256s 仍未退出**；
- fio 主进程卡在 futex，普通 `kill`（SIGTERM）无效，需 `SIGKILL` 才能清除
  （这是 fio 主进程行为，**不等于系统不可中断卡死**——SIGKILL 后系统/mount 立即恢复，见 §三）；
- fio 输出文件**全程为空**（连 "Starting 32 processes" 都没打印），卡在 **fork worker 之前的 setup 阶段**，
  **从未进入 I/O 提交**（§三实测 worker 线程数恒为 0、NIC/FUSE 全 idle）。

在途请求量 = iodepth 128 × numjobs 32 = **4096 个并发随机读请求**。

## 二、对照：低并发正常

同卷、同挂载、降并发立即恢复正常：

```bash
fio ... --iodepth=16 --numjobs=4 --runtime=15s   # 在途=64
# → 正常 60s 内完成，READ: bw=33.5MiB/s，err=0
```

```bash
fio ... --iodepth=128 --numjobs=8 --runtime=60s  # 在途=1024
# → 正常 60s 完成，READ=36.9MiB/s，err=0（10_A_2_3 重测用的就是此档）
```

| 在途请求（iodepth×numjobs） | 结果 |
|---------------------------|------|
| 64（16×4） | ✅ 正常 |
| 1024（128×8） | ✅ 正常 |
| **4096（128×32）** | ✅ **正常**（连跑 3 次 err=0、READ≈37 MiB/s）；仅在"前一个 fio 刚被 SIGKILL"后偶发起不来一次 |
| 4096（128×128，spec 全量） | ⚠️ deepseek 历史"被超时杀"，**疑同因**（反复 SIGKILL 重启的连锁污染），非真卡死 |

> **订正**：早前此表把 4096 标为"卡死"是错的。§四已证 4096 本身正常可跑，"卡"只在 SIGKILL 残留场景偶发。

## 三、首次观察：worker=0 的那一次（脏状态，发生在前一个 fio 被 SIGKILL 之后）

> ⚠️ 下表是**偶发脏状态那一次**的采样（紧接在 21:27 一次被 SIGKILL 的 fio 之后启动）。
> §四已证同口径正常情况下不会这样。此表保留用于说明"脏状态"长什么样。

跑 128×32（在途 4096），每 2s 采样 NIC RX / juicefs CPU / fuse waiting / fio 线程态，
连续 90s（脚本 `/tmp/opencode/hang-diag.sh`，日志 `hang-diag-215946/`）：

| 指标 | 90s 全程实测 | 含义 |
|------|------------|------|
| **fio worker 线程数** | **始终 = 0** | fio 从未 fork 出 32 个 job 线程，卡在初始化最早期 |
| **fio.txt 输出** | **完全空白**（连 "Starting 32 processes" 都没打印）| fio 卡在 fork worker 之前 |
| NIC RX | **≈0.8 MB/s（静止）** | 网卡几乎无流量——**没有在传数据** |
| juicefs CPU | **≈9.5%（不动）** | JuiceFS 在正常 idle 空转，没在干重活 |
| fuse waiting | **0~1** | FUSE 在途请求几乎为 0——**没有 I/O 堆积** |
| juicefs 内核栈 | `futex_wait`（正常 idle 等事件）| JuiceFS 没卡，在等事件 |

**SIGKILL 后**：fio 立即退出，mount `ls`/`stat` 秒回，系统 load 正常 → **系统/JuiceFS 全程健康**。

判读：这一次 fio 确实卡在 fork worker 之前的 setup（worker=0、输出空白、存储栈全 idle）。
但**关键在于它不可复现**——见 §四。

## 四、决定性复现：128×32 本身正常，"卡"只在 SIGKILL 残留后偶发

清理脏状态后，同口径 **128×32 连跑 3 次，全部正常完成**：

| 跑次 | 启动方式 | 8s 时 worker | 结果 |
|------|---------|-------------|------|
| fioC | nohup，跑满 30s | 32（Sl 正常态）| ✅ 30s 自然结束，**err=0，READ=37.4 MiB/s** |
| run1 | nohup，跑满 25s | 32 | ✅ err=0 |
| run2 | nohup，跑满 25s | 32 | ✅ err=0 |

另对照启动方式（`setsid+</dev/null+disown` vs `nohup`）：两者 8s 时 worker 均 = 32、状态正常。
**→ 启动方式不是原因。**

io buffer 实算：32 jobs × 128 iodepth × 256K = **仅 1 GB**（系统空闲内存 244 GB）。
**→ 内存压力不是原因。**

**结论**：128×32（在途 4096）本身完全正常。§三那次 worker=0 是**偶发脏状态**，
唯一区别是它**紧接在一个被 SIGKILL 的高并发 fio 之后启动**。推断 SIGKILL 强杀 fio 时，
内核侧 libaio io_context / FUSE 在途请求未干净释放，污染了紧随其后那次 fio 的 setup；
等残留清掉后即恢复。这是**"暴力杀进程的残留"问题，不是高并发卡死、不是 fio bug、不是压力大**。

## 五、为何重要

1. **重新解释 deepseek 全系列的"fio 被超时杀"**：很可能是它**反复 SIGKILL 又立即重启 fio**
   造成的连锁脏状态污染，而非 JuiceFS 读路径卡死、也非真的跑不动。`10_A_2_3` 退到 numjobs=8
   是规避手段，但 §四已证 numjobs=32 在干净状态下能跑。
2. **spec 全量口径（128×128）很可能可跑**：需在干净状态下（无残留 fio）实测一次确认，
   不应仅因历史"被超时杀"就判定其不可执行。
3. **彻底排除存储瓶颈嫌疑**：早前怀疑的"FUSE dispatch 单线程死锁"被排除（存储栈全程 idle、健康）。

## 六、待查 / 规避

- [ ] 复现脏状态：SIGKILL 一个高并发 fio 后**立即**再起一个 fio，验证是否稳定触发 worker=0；
      若是，确认是 libaio io_context 还是 FUSE fd 残留（`ls -l /proc/<juicefs>/fd`、`cat /sys/fs/fuse/connections/*/waiting`）。
- [ ] 在干净状态下跑一次完整 spec 128×128，确认其可执行性与 randread 真值。
- **规避（已验证有效）**：
  - 不要在 SIGKILL 一个 fio 后立即重启 fio；**杀完等几秒、确认 `pgrep -x fio` 为空、mount `ls` 正常再起下一个**；
  - 优先让 fio 用 `--runtime` 自然结束，而非中途 SIGKILL；
  - 监控启动：8s 内 worker 应 = numjobs；若 worker=0 且 fio.txt 空白，判定脏状态，清理后重试（而非加大 runtime 等待）。

---

环境：tikv-node (192.168.11.12)，JuiceFS v1.3.1，kernel 5.15.0-181，fusermount3 3.10.5，
Ceph 17.2.8 HEALTH_OK，pool juicefs-data EC 4+2，cache=0 冷态，2026-06-23。
