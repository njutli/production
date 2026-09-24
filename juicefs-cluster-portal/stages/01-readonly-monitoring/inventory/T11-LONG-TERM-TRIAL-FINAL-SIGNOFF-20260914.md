# T11 管理门户长期试运行最终签收

> 签收时间：2026-09-14 10:30 CST
>
> RUN：`20260911-194748-cont`
>
> 裁决：`T11_LONG_TERM_MONITOR_PASS`

## 1. 试运行结果

- 观察时间：2026-09-11 19:48:47至2026-09-14 10:28:35，共62小时39分48秒；
- 采样周期：5分钟；
- 有效样本：752；
- 失败样本：0；
- 前2小时人工持续观察的25/25样本和后续后台样本全部通过。

每个样本同时检查157业务挂载与metrics转发器，以及152管理服务、14/14 Prometheus targets、T09快照、Portal路径隔离、Ceph健康、PD/TiKV PID、关键挂载和系统盘余量。

## 2. 终点检查

记录器停止前的独立只读终点检查返回：

```text
namespace_generation=3855 namespace_age_seconds=35.0
SAMPLE_152_PASS epoch=1789352951 disk_available_bytes=793850060800
T11_FINAL_READONLY_GATE_PASS
```

停止记录器后再次确认：

```text
T11_POST_STOP_157_PASS
```

这表明T11监控进程已退出，而157上的`juicefs-metrics-forwarder.service`仍为active、`NRestarts=0`，业务JuiceFS挂载保持存在。停止动作没有操作Portal、Prometheus、Grafana、JuiceFS、PD/TiKV或Ceph服务。

## 3. 证据归档

证据已持久化到：

```text
/mnt/c/SunRise/test/juicefs-cluster-portal/20260914/t11-final-20260911-194748-cont/
```

关键文件哈希：

```text
841253301419424c5ebb4e788914c11ae7655a445213e41adcc272b05cfd8411  monitor.log
3a1ff3ca7fa11cca31aff5fa848c7127f2f47abb6bad086163f72b9e1ea27831  samples.tsv
25ce0061de9b1fd60ddb271ed124acf5a2dc5ba83064e747788198abb9f66fcb  t11-readonly-sample-152.sh
41c331d55d46c5b976a18d4e108a9c3b403d5dbfb9fac9c32684dbf446482dfb  t11-two-hour-monitor-157.sh
```

157上的原始目录`/tmp/jfsportal-t11-20260911-194748-cont`暂时保留，未在本次收口中删除。

## 4. 最终结论

管理门户在超过原定24小时的62.7小时观察窗口内未出现采样失败，未发现管理服务重启、targets中断、T09快照过期、Ceph异常或业务指纹变化。T11长期稳定性验收完成，门户可结束试运行阶段并进入日常人工启停和只读使用状态。
