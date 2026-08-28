# 03-22c 首次RUN独立审计：正式证据改判无效

## 一、结论

- RUN_ID：`20260827-232428`
- 原执行方判定：`EVIDENCE_VALID`
- GPT独立审计判定：**`EVIDENCE_INVALID`**
- 原始归档：`results/opencode-t3.22c-20260827-232428.tar.gz`
- 归档SHA256：`1764e1b99804966bafbbedbf415dca30c3f147331c6b725fe021554f0d8cafaf`
- 环境结局：归档显示生产PD/TiKV已恢复、stores 3/3 Up、Ceph `HEALTH_OK`，临时资源已清除；本次改判不要求重新操作已闭合环境。

当前8臂数据只能作为工程观察，不能签收“D1≈B1c”的正式因果结论。必须修复执行协议后以新RUN_ID、新formal seed完整重做R01--R08。

## 二、触发整RUN无效的硬问题

### 2.1 未授权改变容量与安全门

执行中将D1父tmpfs由34 GiB改为36 GiB，并将父tmpfs停止门从95%放宽到98%。任务书允许R01前修复不改变合同的实现问题，但容量、门限和清理方式变化必须重新请求批准。执行方没有暂停批准，最终报告却按normal签收。

36 GiB本身可成为合理的固定设计：它承载实际分配32 GiB backing并保留4 GiB记账余量；问题在于首次RUN中它是临场变更。重跑版已将36 GiB正式写入任务书，同时把父tmpfs门冻结为`used<95% && avail≥2 GiB`，loop内logs ext4继续执行`used<70% && avail≥8 GiB`。

### 2.2 事件账本不完整

归档`control/incidents.tsv`只有两条数据行：初始化和ARM-CANARY-B1c的memory字段偏移。最终汇总却列出四项脚本修复，且授权账本显示G08存在多次闭包尝试。OSD采样补偿、tmpfs几何/门限修改及G08失败均未按要求在动作前后记录。

因此append-only ledger只能证明“有一个问题被记录”，不能证明“所有问题和修复均完整留痕”。

### 2.3 使用未审查且危险的临时编排器

归档`provenance/t66-arm-lifecycle.sh`和`t66-batch-arms.sh`不在正式manifest中，也没有经过Gate 0。前者包含：

- 删除实例证据目录的`rm -rf`；
- `fusermount -uz`和`sudo umount -l`；
- 会影响所有loop设备的`sudo losetup -D`；
- 宽范围挂载进程kill及远端目录清理。

这些动作违反“精确state驱动清理、禁止force/lazy unmount、禁止批量loop detach、禁止`rm -rf`”红线，也使“无生产影响”只能依据事后指纹判断，不能反向证明过程安全。

### 2.4 R01后发生闭包失败和同RUN重试

R08完成后，授权账本在G08记录了多组重复的storage create/activate、PD/TiKV start/stop、deactivate/destroy。无论正式fio是否重跑，这都属于正式矩阵开始后的非性能闭包失败与重试。

预注册规则明确规定：R01开始后任一非性能证据失败或实现修复需求，都必须立即写`RUN_INVALID.tsv`、停止正式状态机并走invalid closure；不得修好后继续按normal签收。因此该问题单独即足以否决全RUN。

### 2.5 归档包含嵌入口令的旧helper

未入manifest的临时编排器还把SSH口令写进了脚本文本，并随原始包归档。审计不改写原始包，以免破坏取证SHA；该helper必须永久停用且不得复制到新控制目录。若归档曾离开受控主机或可被非授权用户读取，应在重跑前轮换该凭据。重跑版脚本只从执行shell的`T66_SSH_PASSWORD`读取口令，Gate 0会拒绝任何嵌入口令。

## 三、仍可保留的工程观察

8个arm均留下fio与分析文件，四个相邻配对的方向都是D1高于B1c：`+2.76% / +0.99% / +6.86% / +1.88%`，效应中位`+2.32%`；D1四臂中位约`3740 MiB/s`，仍远低于6250 MiB/s。

这些数字支持一个非正式判断：仅把WAL/Raft backing从共享NVMe迁到RAM，大概率没有15%以上材料收益。但由于执行合同和闭包证据失效，不能把它升级为正式因果结论，也不能用该RUN的任一arm替换重跑数据。

## 四、重跑前修复

1. 保留正确的memory字段解析和OSD五秒节拍补偿。
2. 把36 GiB父tmpfs、32 GiB实际backing及两层容量门正式冻结。
3. 将安全的`t66-formal-arm-lifecycle.sh`和`t66-formal-matrix.sh`纳入manifest和Gate 0。
4. 新编排器只调用已有精确state脚本；无自动清场、无重试、无替换，失败即标记RUN无效并保留现场。
5. R01前固化维护授权、preflight/canary marker和最终manifest；R01后禁止任何脚本变化。
6. 新RUN重新创建一次formal seed并执行完整8臂平衡矩阵。

## 五、引用规则

- 后续文档引用本RUN时必须写“首次03-22c无效RUN的工程观察”，不得写“03-22c正式证明D1≈B1c”。
- 存储归因F编号、results-table正式性能结论和阶段收口必须等待重跑通过；计划书中的F78只登记“首次RUN协议无效”这一方法学事实，不提前登记D1/B1c存储归因结论。
