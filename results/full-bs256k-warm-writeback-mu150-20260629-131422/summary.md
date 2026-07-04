============================================================
全量测试 warm-writeback-mu150 20260629-131422
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache --max-uploads 150 --writeback
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-warm-writeback-mu150-20260629-131422/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=1193 WRITE=NA NIC_RX=16.5
  seqwrite: READ=NA WRITE=346 NIC_RX=10.9
  multi-seqread: READ=NA WRITE=NA NIC_RX=167.7
  multi-seqwrite: READ=NA WRITE=431 NIC_RX=101.6

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=417

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=197 WRITE=NA NIC_RX=2367.6
  randwrite r1: READ=NA WRITE=688 NIC_RX=64.7
  randrw r1: READ=203 WRITE=204 NIC_RX=1320.3
### Round 2
  randread r2: READ=637 WRITE=NA NIC_RX=2951.1
  randwrite r2: READ=NA WRITE=647 NIC_RX=239.2
  randrw r2: READ=268 WRITE=270 NIC_RX=1397.7
### Round 3
  randread r3: READ=864 WRITE=NA NIC_RX=3153.9
  randwrite r3: READ=NA WRITE=679 NIC_RX=291.8
  randrw r3: READ=260 WRITE=261 NIC_RX=1191.6

DONE
  commands.sh generated
