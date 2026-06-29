============================================================
全量测试 cold-r2 20260626-224117
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=cold, mount_opts=--cache-size 0 
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-cold-r2-20260626-224117/env-snapshot.txt
## 格式化卷
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=80.4 WRITE=NA NIC_RX=4323.4
  seqwrite: READ=NA WRITE=47.8 NIC_RX=64.5
  multi-seqread: READ=109 WRITE=NA NIC_RX=69181.0
  multi-seqwrite: READ=NA WRITE=41.1 NIC_RX=1023.6

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=32.4

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=33.5 WRITE=NA NIC_RX=6662.6
  randwrite r1: READ=NA WRITE=27.4 NIC_RX=620.7
  randrw r1: READ=10.4 WRITE=10.3 NIC_RX=2628.3
### Round 2
  randread r2: READ=32.1 WRITE=NA NIC_RX=6952.3
  randwrite r2: READ=NA WRITE=31.4 NIC_RX=542.6
  randrw r2: READ=17.3 WRITE=17.0 NIC_RX=4294.5
### Round 3
  randread r3: READ=30.7 WRITE=NA NIC_RX=6812.8
  randwrite r3: READ=NA WRITE=34.8 NIC_RX=621.6
  randrw r3: READ=15.5 WRITE=15.2 NIC_RX=3931.3

DONE
  commands.sh generated
