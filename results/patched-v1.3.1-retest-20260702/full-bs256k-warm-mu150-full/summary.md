============================================================
暖态 mu=150 全量测试 20260703-174018（patched v1.3.1，预热+5轮）
============================================================
## 口径:
  block-size=256K, cache=100G, max-uploads=150
  seq: 1次; rand: 5轮
  先预热（读 128G test_dir 填充 cache），再正式测
  复用冷态布局，不 destroy/format/layout

## 挂载
  mount OK

## 预热（读 128G test_dir 填充 cache）
  preheat: READ=111
  预热完成

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=71.5 WRITE=NA NIC_RX=4324.6
  seqwrite: READ=NA WRITE=44.0 NIC_RX=68.6
  multi-seqread: READ=109 WRITE=NA NIC_RX=69253.5
  multi-seqwrite: READ=NA WRITE=42.0 NIC_RX=1054.5

## 随机测试 (5轮, bs=256K, 128jobs, iodepth=128, direct=1, runtime=60s)
### Round 1
  randread r1: READ=36.6 WRITE=NA NIC_RX=5883.8
  randwrite r1: READ=NA WRITE=54.8 NIC_RX=336.4
  randrw r1: READ=18.5 WRITE=18.2 NIC_RX=1488.8
### Round 2
  randread r2: READ=69.2 WRITE=NA NIC_RX=6275.6
  randwrite r2: READ=NA WRITE=54.8 NIC_RX=303.1
  randrw r2: READ=22.7 WRITE=22.5 NIC_RX=1668.8
### Round 3
  randread r3: READ=96.4 WRITE=NA NIC_RX=6580.2
  randwrite r3: READ=NA WRITE=57.0 NIC_RX=143.0
  randrw r3: READ=24.6 WRITE=24.2 NIC_RX=1762.4
### Round 4
  randread r4: READ=125 WRITE=NA NIC_RX=6579.7
  randwrite r4: READ=NA WRITE=57.5 NIC_RX=162.1
  randrw r4: READ=16.9 WRITE=16.4 NIC_RX=1270.1
### Round 5
  randread r5: READ=146 WRITE=NA NIC_RX=6414.5
  randwrite r5: READ=NA WRITE=55.1 NIC_RX=167.6
  randrw r5: READ=23.8 WRITE=23.2 NIC_RX=1731.5

DONE
  commands.sh generated
