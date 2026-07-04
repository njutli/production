============================================================
全量测试 cold-cache0-ra0 20260702-211717
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=cold, mount_opts=--cache-size 0 --max-readahead 0
  seq: 1次; rand: 3轮
  DO_FORMAT=1, DO_LAYOUT=1

  env snapshot -> results/patched-v1.3.1-retest-20260702/full-bs256k-cold-cache0-ra0-20260702-211717/env-snapshot.txt
## 格式化卷
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=51.6 WRITE=NA NIC_RX=4333.6
  seqwrite: READ=NA WRITE=44.6 NIC_RX=65.4
  multi-seqread: READ=108 WRITE=NA NIC_RX=69318.1
  multi-seqwrite: READ=NA WRITE=38.2 NIC_RX=1054.5

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=32.6
## Layout cooldown: 等待 compaction 完成

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=53.4 WRITE=NA NIC_RX=3893.4
  randwrite r1: READ=NA WRITE=48.1 NIC_RX=353.5
  randrw r1: READ=10.2 WRITE=10.1 NIC_RX=1253.2
### Round 2
  randread r2: READ=51.4 WRITE=NA NIC_RX=3759.4
  randwrite r2: READ=NA WRITE=48.2 NIC_RX=378.5
  randrw r2: READ=14.1 WRITE=13.8 NIC_RX=1511.7
### Round 3
  randread r3: READ=73.1 WRITE=NA NIC_RX=5273.5
  randwrite r3: READ=NA WRITE=54.9 NIC_RX=240.0
  randrw r3: READ=9.7 WRITE=9.6 NIC_RX=1114.0

DONE
  commands.sh generated
