# mu300-buf1g Summary

| 测试 | r1 MiB/s | r2 MiB/s | r3 MiB/s | stall | 判定(取r1) |
|------|----------|----------|----------|-------|-----------|
| seqwrite | 45.0 | 45.1 | 40.7 | ok/ok/ok | 未达标 |
| randwrite | 76.9 | 76.6 | 78.4 | ok/ok/ok | 达标 |

挂载参数: `--cache-size 0 --max-uploads 300 --buffer-size 1024`
