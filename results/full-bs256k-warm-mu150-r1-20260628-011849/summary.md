============================================================
全量测试 warm-mu150-r1 20260628-011849
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache --max-uploads 150
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-warm-mu150-r1-20260628-011849/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=89.9 WRITE=NA NIC_RX=4305.2
  seqwrite: READ=NA WRITE=62.4 NIC_RX=58.7
  multi-seqread: READ=109 WRITE=NA NIC_RX=68869.9
  multi-seqwrite: READ=NA WRITE=41.7 NIC_RX=891.8

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=42.5

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=38.3 WRITE=NA NIC_RX=4979.3
  randwrite r1: READ=NA WRITE=42.8 NIC_RX=45.2
  randrw r1: READ=NA WRITE=NA NIC_RX=1275.7
### Round 2
  randread r2: READ=61.6 WRITE=NA NIC_RX=4795.4
  randwrite r2: READ=NA WRITE=51.8 NIC_RX=52.9
  randrw r2: READ=17.9 WRITE=17.4 NIC_RX=1917.9
### Round 3
  randread r3: READ=102 WRITE=NA NIC_RX=6332.5
  randwrite r3: READ=NA WRITE=52.3 NIC_RX=72.4
  randrw r3: READ=16.4 WRITE=16.2 NIC_RX=1737.6

DONE
  commands.sh generated
