# mu300 Summary

| 测试 | r1 MiB/s | r2 MiB/s | r3 MiB/s | stall | 判定(取r1) |
|------|----------|----------|----------|-------|-----------|
| seqwrite | 45.8 | 44.7 | 44.8 | ok/ok/ok | 未达标 |
| randwrite | 51.4 | 50.8 | 50.5 | ok/ok/ok | 未达标 |

挂载参数: `--cache-size 0 --max-uploads 300`
