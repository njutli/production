============================================================
全量测试 warm-ra0-r2 20260627-230543
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache --max-readahead 0
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-warm-ra0-r2-20260627-230543/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=48.4 WRITE=NA NIC_RX=4367.0
  seqwrite: READ=NA WRITE=62.3 NIC_RX=55.9
  multi-seqread: READ=98.4 WRITE=NA NIC_RX=74625.9
  multi-seqwrite: READ=NA WRITE=44.8 NIC_RX=870.8

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=42.9

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=37.8 WRITE=NA NIC_RX=1964.8
  randwrite r1: READ=NA WRITE=49.3 NIC_RX=112.5
  randrw r1: READ=NA WRITE=NA NIC_RX=956.3
### Round 2
  randread r2: READ=101 WRITE=NA NIC_RX=2670.8
  randwrite r2: READ=NA WRITE=44.6 NIC_RX=45.7
  randrw r2: READ=NA WRITE=NA NIC_RX=1216.1
### Round 3
  randread r3: READ=129 WRITE=NA NIC_RX=3241.9
  randwrite r3: READ=NA WRITE=45.2 NIC_RX=51.2
  randrw r3: READ=NA WRITE=NA NIC_RX=1294.7

DONE
  commands.sh generated
