# 04-tmp2c：randread 本地读缓存驻留比例修正曲线

> 级别：`L1_SCREEN`；执行方：Luna；审核方：GPT。  
> 承接：04-tmp2b 因缓存文件系统 inode 密度错误而失效。本任务只修正该错误，不重开 writeback。

```text
UNIQUE_QUESTION=本地读缓存容量占16GiB随机读工作集12.5%--200%时，实际命中率和randread带宽如何变化
MINIMUM_EVIDENCE=同窗cache=0双锚点+2/4/8/16/32GiB五档+缓存命中/未命中计数+正确Ceph数据网流量
STOP_AFTER_ANSWER=完成七个只读cell并形成容量/命中/带宽曲线后停止
MAX_PREP_BUDGET=60min
```

## 一、上一轮失效原因

04-tmp2b 使用 `mkfs.ext4 -T largefile`。该格式在20/40/80 GiB文件系统中分别只创建
20,480/40,960/81,920个 inode；JuiceFS 在 `cache-items=0` 时又按
`free-space-ratio=0.20`把缓存条目限制为约80%的可用 inode。按256 KiB块计算，名义
16/32/64 GiB缓存实际只能容纳约4/8/16 GiB，与实测物理峰值
`4.06/8.13/16.25 GiB`精确一致。

因此上一轮实际只缓存128 GiB工作集的3.125%/6.25%/12.5%，不能用于判定缓存无收益。

## 二、冻结变量与矩阵

- JuiceFS：`/tmp/juicefs-1.4.1-patched`，MD5
  `24fae0852051c80ca571cb2f20275d46`；
- 现有只读资产：`/mnt/juicefs/test_dir/read_test.0.0`至`read_test.127.0`，每个1 GiB；
- 每个job只访问对应文件前128 MiB，总工作集16 GiB；128 job、256 KiB、`libaio`、
  `iodepth=128`、`direct=1`、固定随机种子；
- mount固定：`--read-only --prefetch 0 --max-fuse-io 256K --max-uploads 150`；
- 只开启读缓存，明确禁止 `--writeback`、全局 `drop_caches`、新layout和任何写入测试资产；
- 直接使用157本地NVMe现有ext4 `/mnt/jfs-cache` 下RUN专属目录，不再创建loop文件系统；
  其现有inode容量须在inventory中复核，避免再次发生条目上限截断。

执行顺序：

| Cell | cache-size | 占16 GiB工作集 | 动作 |
|---|---:|---:|---|
| A0-pre | 0 | 0% | 正式180s |
| C02 | 2 GiB | 12.5% | 空缓存预热180s + 正式180s |
| C04 | 4 GiB | 25% | 同上 |
| C08 | 8 GiB | 50% | 同上 |
| C16 | 16 GiB | 100% | 同上 |
| C32 | 32 GiB | 200% | 同上；实际占用不应超过16 GiB工作集 |
| A0-post | 0 | 0% | 正式180s，量化窗口漂移 |

每个缓存档使用独立的空子目录；不得跨档复用缓存内容。cell内部自主连续执行，除安全硬门失败外
不逐档暂停。

## 三、必要证据与判读

每档保存：

1. fio JSON、128份逐秒bw log、实际起止时间和完整命令；
2. 预热前、预热后、正式后完整metrics，并差分
   `juicefs_blockcache_bytes/blocks/hit_bytes/miss_bytes/writes/evicts/drops`；
3. 正确Ceph数据网卡（由 `ip route get 10.3.1.6`确认）的RX/TX差分；
4. cache目录文件数、逻辑/物理字节、可用空间和inode；
5. fio前后128个资产的名称、inode、大小、mtime一致性；
6. Ceph health/PG、参考挂载和外来fio检查。

硬门：

- 任一写入测试资产、fio错误、缺bw log、资产漂移、缓存目录越界、cache drops、metrics缺失或
  实际mount参数不符：本RUN停止；
- `blockcache_bytes`必须与目标容量关系相符：C02--C16达到目标附近，C32达到工作集附近；否则
  先解释限制来源，不得将点值写成容量曲线；
- Ceph NIC必须来自到`10.3.1.6`的路由；采到TiKV网卡则证据失效；
- L1只输出工程曲线，不直接成为生产交付配置。容量越大不保证严格单调，但带宽必须与实测命中率
  联合解释。

## 四、安全与授权

- 禁止触碰WekaIO、K8s、网卡、内核参数、Ceph配置、TiKV、`/mnt/juicefs`挂载本身；
- 禁止重启、kill业务进程、强制/lazy umount、裸盘格式化、loop/mkfs和全局drop_caches；
- sudo写操作只允许以下两个精确动作，必须在执行前以固定RUN_ID展开并经用户确认：
  1. 创建 `/mnt/jfs-cache/jfs-04tmp2c-<RUN_ID>`，属主1002:1002、模式0700；
  2. 在内容已由属主安全清空且目录确认为空后，精确`rmdir`同一路径。
- 缓存文件清理必须校验路径前缀、非空、非根、非符号链接且与RUN_ID一致；仅删除RUN专属缓存
  子目录，不递归扫描其他目录。
- 任何现场事实与本任务书不符时停止，保留现场并回报GPT。

## 五、执行与生命周期

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2c/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2c-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=精确卸载测试挂载、清空并rmdir RUN专属缓存目录
```

步骤只有两个审核停点：

1. GPT/Luna离线Gate、只读inventory和完整sudo计划通过后，等待一次授权；
2. Luna连续完成七个cell、证据持久化和非sudo收口；GPT复算后再执行最终精确sudo `rmdir`。

证据生命周期遵循 `TEST-DATA-LIFECYCLE-POLICY.md`；RUN公共证据只回传一次，cell只回传增量，
不得复制整棵RUN树。最终报告写入`doc/perf-report/04-tmp2c-*.md`，并更新04状态表和
`results-table.md`。

