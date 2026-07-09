# Segment Latency Breakdown (delta: t0→tend)

## Per-OSD detail

### OSD.0

| Segment | dCount | Avg (ms) |
|---------|--------|----------|
| txc_throttle_lat | 90137 | 0.014 |
| state_prepare_lat | 90137 | 0.118 |
| state_aio_wait_lat | 90137 | 11.588 |
| state_kv_queued_lat | 90137 | 11.345 |
| state_kv_commiting_lat | 90137 | 11.593 |
| kv_sync_lat | 60702 | 1.506 |
| kv_flush_lat | 60702 | 0.005 |
| kv_commit_lat | 60702 | 1.501 |
| kv_final_lat | 60702 | 0.024 |
| state_deferred_aio_wait_lat | 0 | 0.000 |
| [osd] op_w_latency | 9819 | 252.379 |
| [osd] op_w_prepare_latency | 9819 | 0.997 |
| [osd] op_w_process_latency | 9819 | 242.212 |
| [osd] subop_w_latency | 250 | 2.144 |

### OSD.1

| Segment | dCount | Avg (ms) |
|---------|--------|----------|
| txc_throttle_lat | 90164 | 0.014 |
| state_prepare_lat | 90164 | 0.119 |
| state_aio_wait_lat | 90164 | 11.695 |
| state_kv_queued_lat | 90164 | 11.327 |
| state_kv_commiting_lat | 90164 | 11.806 |
| kv_sync_lat | 60250 | 1.508 |
| kv_flush_lat | 60250 | 0.005 |
| kv_commit_lat | 60250 | 1.503 |
| kv_final_lat | 60250 | 0.025 |
| state_deferred_aio_wait_lat | 1 | 0.180 |
| [osd] op_w_latency | 11585 | 250.643 |
| [osd] op_w_prepare_latency | 11585 | 1.017 |
| [osd] op_w_process_latency | 11585 | 241.706 |
| [osd] subop_w_latency | 284 | 1.395 |

### OSD.2

| Segment | dCount | Avg (ms) |
|---------|--------|----------|
| txc_throttle_lat | 90167 | 0.014 |
| state_prepare_lat | 90167 | 0.122 |
| state_aio_wait_lat | 90167 | 55.796 |
| state_kv_queued_lat | 90167 | 55.637 |
| state_kv_commiting_lat | 90167 | 56.061 |
| kv_sync_lat | 21770 | 12.787 |
| kv_flush_lat | 21770 | 0.003 |
| kv_commit_lat | 21770 | 12.784 |
| kv_final_lat | 21766 | 0.047 |
| state_deferred_aio_wait_lat | 0 | 0.000 |
| [osd] op_w_latency | 5790 | 254.080 |
| [osd] op_w_prepare_latency | 5790 | 1.037 |
| [osd] op_w_process_latency | 5790 | 242.215 |
| [osd] subop_w_latency | 338 | 63.571 |

### OSD.3

| Segment | dCount | Avg (ms) |
|---------|--------|----------|
| txc_throttle_lat | 90134 | 0.014 |
| state_prepare_lat | 90134 | 0.119 |
| state_aio_wait_lat | 90134 | 55.246 |
| state_kv_queued_lat | 90134 | 55.394 |
| state_kv_commiting_lat | 90134 | 56.648 |
| kv_sync_lat | 22223 | 12.532 |
| kv_flush_lat | 22223 | 0.002 |
| kv_commit_lat | 22223 | 12.530 |
| kv_final_lat | 22223 | 0.043 |
| state_deferred_aio_wait_lat | 0 | 0.000 |
| [osd] op_w_latency | 5876 | 253.247 |
| [osd] op_w_prepare_latency | 5876 | 0.978 |
| [osd] op_w_process_latency | 5876 | 241.157 |
| [osd] subop_w_latency | 198 | 92.832 |

### OSD.4

| Segment | dCount | Avg (ms) |
|---------|--------|----------|
| txc_throttle_lat | 90351 | 0.014 |
| state_prepare_lat | 90351 | 0.117 |
| state_aio_wait_lat | 90351 | 7.290 |
| state_kv_queued_lat | 90351 | 6.739 |
| state_kv_commiting_lat | 90351 | 6.725 |
| kv_sync_lat | 65755 | 1.027 |
| kv_flush_lat | 65755 | 0.004 |
| kv_commit_lat | 65755 | 1.022 |
| kv_final_lat | 65755 | 0.025 |
| state_deferred_aio_wait_lat | 0 | 0.000 |
| [osd] op_w_latency | 17623 | 239.328 |
| [osd] op_w_prepare_latency | 17623 | 0.993 |
| [osd] op_w_process_latency | 17623 | 231.725 |
| [osd] subop_w_latency | 324 | 18.254 |

### OSD.5

| Segment | dCount | Avg (ms) |
|---------|--------|----------|
| txc_throttle_lat | 89950 | 0.015 |
| state_prepare_lat | 89950 | 0.123 |
| state_aio_wait_lat | 89950 | 7.368 |
| state_kv_queued_lat | 89950 | 6.777 |
| state_kv_commiting_lat | 89950 | 6.574 |
| kv_sync_lat | 65693 | 1.020 |
| kv_flush_lat | 65693 | 0.005 |
| kv_commit_lat | 65693 | 1.015 |
| kv_final_lat | 65693 | 0.023 |
| state_deferred_aio_wait_lat | 0 | 0.000 |
| [osd] op_w_latency | 11635 | 246.828 |
| [osd] op_w_prepare_latency | 11635 | 1.039 |
| [osd] op_w_process_latency | 11635 | 237.729 |
| [osd] subop_w_latency | 134 | 12.627 |

## Summary (6-OSD weighted average)

Reference: op_w_latency (total) = 249.417 ms

| Segment | Avg (ms) | % of op_w_latency |
|---------|----------|-------------------|
| txc_throttle_lat | 0.014 | 0.0% |
| state_prepare_lat | 0.120 | 0.0% |
| state_aio_wait_lat | 24.831 | 10.0% |
| state_kv_queued_lat | 24.537 | 9.8% |
| state_kv_commiting_lat | 24.901 | 10.0% |
| kv_sync_lat | 2.948 | 1.2% |
| kv_flush_lat | 0.004 | 0.0% |
| kv_commit_lat | 2.943 | 1.2% |
| kv_final_lat | 0.027 | 0.0% |
| state_deferred_aio_wait_lat | 0.180 | 0.1% |
| [osd] op_w_latency | 249.417 | 100.0% |
| [osd] op_w_prepare_latency | 1.010 | 0.4% |
| [osd] op_w_process_latency | 239.457 | 96.0% |
| [osd] subop_w_latency | 31.804 | 12.8% |
