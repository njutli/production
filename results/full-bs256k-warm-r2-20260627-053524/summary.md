============================================================
全量测试 warm-r2 20260627-053524
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache 
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-warm-r2-20260627-053524/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=80.6 WRITE=NA NIC_RX=4318.3
  seqwrite: READ=NA WRITE=39.4 NIC_RX=59.6
  multi-seqread: READ=109 WRITE=NA NIC_RX=69102.5
  multi-seqwrite: READ=NA WRITE=39.2 NIC_RX=1060.7

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=30.4

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=23.8 WRITE=NA NIC_RX=4767.1
  randwrite r1: READ=NA WRITE=36.9 NIC_RX=36.4
  randrw r1: READ=21.8 WRITE=21.5 NIC_RX=1926.0
### Round 2
  randread r2: READ=76.4 WRITE=NA NIC_RX=6395.7
  randwrite r2: READ=NA WRITE=51.1 NIC_RX=48.5
  randrw r2: READ=21.3 WRITE=21.0 NIC_RX=1338.5
### Round 3
  randread r3: READ=105 WRITE=NA NIC_RX=5794.9
  randwrite r3: READ=NA WRITE=45.3 NIC_RX=43.3
  randrw r3: READ=13.2 WRITE=13.0 NIC_RX=847.0

DONE
  commands.sh generated
