============================================================
全量测试 cold-cache0 20260702-175523
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=cold, mount_opts=--cache-size 0 
  seq: 1次; rand: 3轮
  DO_FORMAT=1, DO_LAYOUT=1

  env snapshot -> results/patched-v1.3.1-retest-20260702/full-bs256k-cold-cache0-20260702-175523/env-snapshot.txt
## 格式化卷
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=78.8 WRITE=NA NIC_RX=4324.9
  seqwrite: READ=NA WRITE=51.9 NIC_RX=66.0
  multi-seqread: READ=109 WRITE=NA NIC_RX=69170.2
  multi-seqwrite: READ=NA WRITE=38.4 NIC_RX=1060.9

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=33.0
## Layout cooldown: 等待 compaction 完成

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=37.2 WRITE=NA NIC_RX=5098.0
  randwrite r1: READ=NA WRITE=43.1 NIC_RX=401.7
  randrw r1: READ=14.3 WRITE=14.0 NIC_RX=2508.7
### Round 2
  randread r2: READ=45.4 WRITE=NA NIC_RX=6277.7
  randwrite r2: READ=NA WRITE=45.2 NIC_RX=417.7
  randrw r2: READ=13.9 WRITE=13.6 NIC_RX=2446.7
### Round 3
  randread r3: READ=35.1 WRITE=NA NIC_RX=4802.1
  randwrite r3: READ=NA WRITE=30.6 NIC_RX=475.7
  randrw r3: READ=14.7 WRITE=14.4 NIC_RX=2513.3

DONE
  commands.sh generated
