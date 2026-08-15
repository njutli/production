=== 客户端 ===
Linux <redacted-client-host> 5.15.0-170-generic #180-Ubuntu SMP Fri Jan 9 16:10:31 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
cores=96
               total        used        free      shared  buff/cache   available
Mem:           1.0Ti        66Gi       910Gi       6.5Gi        30Gi       927Gi
=== juicefs 二进制（两者必须同基座，仅差补丁）===
STOCK:   juicefs version 1.5.0-dev+2026-08-14.edabf9c2
PATCHED: juicefs version 1.5.0-dev+2026-08-14.edabf9c2-flushfix
=== 卷格式（触发条件：BlockSize = BS）===
2026/08/14 09:41:36.996816 juicefs[2812514] <INFO>: Meta address: tikv://<redacted> [NewClient@interface.go:652]
2026/08/14 09:41:36.996960 juicefs[2812514] <INFO>: TiKV gc interval is set to 3h0m0s [newTikvClient@tkv_tikv.go:90]
{
  "Name": "juicefs-prod",
  "UUID": "e1b69ea9-0e3d-427d-bea9-8765928afa66",
  "Storage": "ceph",
  "Tiers": {
    "0": {
      "ID": 0,
      "StorageClass": "",
      "Tag": ""
    }
  },
  "Bucket": "ceph://juicefs-data",
  "AccessKey": "ceph",
=== fio ===
fio-3.28
