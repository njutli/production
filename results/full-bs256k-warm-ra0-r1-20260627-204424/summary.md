============================================================
全量测试 warm-ra0-r1 20260627-204424
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache --max-readahead 0
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-warm-ra0-r1-20260627-204424/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=48.8 WRITE=NA NIC_RX=4361.3
  seqwrite: READ=NA WRITE=67.3 NIC_RX=59.9
  multi-seqread: READ=99.6 WRITE=NA NIC_RX=74810.4
  multi-seqwrite: READ=NA WRITE=49.1 NIC_RX=882.1

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=41.8

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=56.3 WRITE=NA NIC_RX=2550.9
  randwrite r1: READ=NA WRITE=57.1 NIC_RX=76.4
  randrw r1: READ=NA WRITE=NA NIC_RX=1025.3
### Round 2
  randread r2: READ=111 WRITE=NA NIC_RX=2668.9
  randwrite r2: READ=NA WRITE=57.9 NIC_RX=55.3
  randrw r2: READ=NA WRITE=NA NIC_RX=1127.0
### Round 3
  randread r3: READ=155 WRITE=NA NIC_RX=3623.5
  randwrite r3: READ=NA WRITE=57.8 NIC_RX=143.7
  randrw r3: READ=NA WRITE=NA NIC_RX=1130.4

DONE
  commands.sh generated
