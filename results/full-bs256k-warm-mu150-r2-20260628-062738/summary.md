============================================================
全量测试 warm-mu150-r2 20260628-062738
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache --max-uploads 150
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-warm-mu150-r2-20260628-062738/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=91.5 WRITE=NA NIC_RX=4304.1
  seqwrite: READ=NA WRITE=60.9 NIC_RX=58.3
  multi-seqread: READ=109 WRITE=NA NIC_RX=68856.2
  multi-seqwrite: READ=NA WRITE=42.6 NIC_RX=882.1

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=42.3

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=44.4 WRITE=NA NIC_RX=4127.2
  randwrite r1: READ=NA WRITE=56.0 NIC_RX=58.7
  randrw r1: READ=18.9 WRITE=18.7 NIC_RX=1699.5
### Round 2
  randread r2: READ=107 WRITE=NA NIC_RX=5914.4
  randwrite r2: READ=NA WRITE=53.6 NIC_RX=55.0
  randrw r2: READ=16.9 WRITE=16.6 NIC_RX=1756.7
### Round 3
  randread r3: READ=119 WRITE=NA NIC_RX=6477.3
  randwrite r3: READ=NA WRITE=44.5 NIC_RX=65.9
  randrw r3: READ=10.8 WRITE=10.6 NIC_RX=1312.7

DONE
  commands.sh generated
