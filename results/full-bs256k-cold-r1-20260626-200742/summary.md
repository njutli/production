============================================================
全量测试 cold-r1 20260626-200742
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=cold, mount_opts=--cache-size 0 
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-cold-r1-20260626-200742/env-snapshot.txt
## 格式化卷
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=77.7 WRITE=NA NIC_RX=4320.2
  seqwrite: READ=NA WRITE=50.8 NIC_RX=60.8
  multi-seqread: READ=110 WRITE=NA NIC_RX=69122.6
  multi-seqwrite: READ=NA WRITE=41.5 NIC_RX=994.9

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=33.3

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=33.6 WRITE=NA NIC_RX=6641.8
  randwrite r1: READ=NA WRITE=29.0 NIC_RX=612.6
  randrw r1: READ=NA WRITE=NA NIC_RX=1646.2
### Round 2
  randread r2: READ=32.4 WRITE=NA NIC_RX=7017.7
  randwrite r2: READ=NA WRITE=53.5 NIC_RX=209.5
  randrw r2: READ=15.1 WRITE=14.7 NIC_RX=3934.5
### Round 3
  randread r3: READ=29.8 WRITE=NA NIC_RX=6869.7
  randwrite r3: READ=NA WRITE=31.9 NIC_RX=523.5
  randrw r3: READ=10.3 WRITE=10.3 NIC_RX=2640.6

DONE
  commands.sh generated
