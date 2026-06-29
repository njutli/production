============================================================
全量测试 warm-r1 20260627-014343
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache 
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-warm-r1-20260627-014343/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=73.1 WRITE=NA NIC_RX=4322.3
  seqwrite: READ=NA WRITE=48.7 NIC_RX=64.5
  multi-seqread: READ=109 WRITE=NA NIC_RX=69184.2
  multi-seqwrite: READ=NA WRITE=40.6 NIC_RX=1021.9

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=30.6

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=45.3 WRITE=NA NIC_RX=6952.1
  randwrite r1: READ=NA WRITE=44.0 NIC_RX=112.4
  randrw r1: READ=NA WRITE=NA NIC_RX=575.4
### Round 2
  randread r2: READ=69.3 WRITE=NA NIC_RX=5196.2
  randwrite r2: READ=NA WRITE=49.8 NIC_RX=50.8
  randrw r2: READ=23.2 WRITE=22.6 NIC_RX=1417.9
### Round 3
  randread r3: READ=101 WRITE=NA NIC_RX=5939.6
  randwrite r3: READ=NA WRITE=37.2 NIC_RX=38.0
  randrw r3: READ=22.4 WRITE=21.9 NIC_RX=1128.2

DONE
  commands.sh generated
