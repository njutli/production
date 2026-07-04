============================================================
全量测试 warm-cache100g 20260703-000448
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache 
  seq: 1次; rand: 3轮
  DO_FORMAT=0, DO_LAYOUT=0

  env snapshot -> results/patched-v1.3.1-retest-20260702/full-bs256k-warm-cache100g-20260703-000448/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=79.9 WRITE=NA NIC_RX=4322.5
  seqwrite: READ=NA WRITE=53.3 NIC_RX=64.0
  multi-seqread: READ=108 WRITE=NA NIC_RX=69188.4
  multi-seqwrite: READ=NA WRITE=39.3 NIC_RX=1015.7

## 布局: 跳过（暖态复用冷态布局）
  test_dir 已有 128G 数据

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=36.9 WRITE=NA NIC_RX=5845.0
  randwrite r1: READ=NA WRITE=30.4 NIC_RX=552.4
  randrw r1: READ=13.9 WRITE=13.6 NIC_RX=1271.9
### Round 2
  randread r2: READ=72.4 WRITE=NA NIC_RX=6591.3
  randwrite r2: READ=NA WRITE=37.1 NIC_RX=546.2
  randrw r2: READ=16.7 WRITE=16.3 NIC_RX=1515.3
### Round 3
  randread r3: READ=101 WRITE=NA NIC_RX=5849.9
  randwrite r3: READ=NA WRITE=46.0 NIC_RX=411.1
  randrw r3: READ=16.4 WRITE=16.1 NIC_RX=1618.3

DONE
  commands.sh generated
