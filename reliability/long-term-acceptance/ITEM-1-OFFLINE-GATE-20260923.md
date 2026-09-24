# 长稳验收项1：配置契约与离线门

完成时间：2026-09-23。只修改工程内 LT 脚本、执行本机离线自测；未部署到157、未改远端环境、未运行fio。

## 最小修补

- `reliability/lib/long_term.sh`：生产 profile 固定 patched 1.4.1 MD5、卷 UUID、BlockSize 256K、FUSE `max_read=262144`；运行中 JuiceFS 进程必须显式使用指定的客户端私有 `CEPH_CONF`，该文件 `[client] ms_async_op_threads=8`，实际 worker 进程须有8个 `msgr-worker-*`。允许 `mount -d` 父进程有0个worker，不能把它误判为错配置；任何非零但非8的数量均拒绝。
- 独立慢集群通过 `reliability/env/cluster-192.168.11.env` 显式使用另一 profile（FUSE 128K、另一个卷UUID）；不能通过留空参数绕过生产门。
- LT引擎和独立的QD校准器用已有 Python3 解析所需JSON，消除157缺 `jq` 导致的硬阻断；结果快照新增配置 profile 和私有配置哈希。没有安装软件。
- `reliability/test-long-term.sh` 增加正/反例：UUID、BlockSize、FUSE值、私有Ceph配置路径与8线程、父子进程worker数量 `[0,8]`通过与`[0,3]`拒绝，另检查慢集群 profile。全部在本机 fixture 上运行。

## 验证

`bash -n` 与 `./reliability/test-long-term.sh` 均通过，输出 `LT_GATE0_OFFLINE_PASS cases=4 common_engine=1 cluster_access=0`。该通过仅说明本地脚本结构和拒绝逻辑，**不说明157的运行配置通过**。

## 后续阻断及计划调整

157 的当前挂载进程仍未设置 `CEPH_CONF`；系统 Ceph 客户端配置查询值为3，与交付基线8不符。下一步不是直接运行LT-002：先在业务可控窗口确认并修复该挂载配置，之后用部署到157的新版脚本执行只读 `plan`；再冻结业务负载/SLO、容量预算并单独评估短时canary。重挂载会影响 `/mnt/juicefs` 的使用者，本项没有执行，也不包含在既有压测授权中。
