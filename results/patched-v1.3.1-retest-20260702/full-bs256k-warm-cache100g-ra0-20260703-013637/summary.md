============================================================
全量测试 warm-cache100g-ra0 20260703-013637
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache --max-readahead 0
  seq: 1次; rand: 3轮
  DO_FORMAT=0, DO_LAYOUT=0

  env snapshot -> results/patched-v1.3.1-retest-20260702/full-bs256k-warm-cache100g-ra0-20260703-013637/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=48.3 WRITE=NA NIC_RX=4322.1
  seqwrite: READ=NA WRITE=53.0 NIC_RX=64.1
  multi-seqread: READ=107 WRITE=NA NIC_RX=69156.4
  multi-seqwrite: READ=NA WRITE=40.4 NIC_RX=1084.4

## 布局: 跳过（暖态复用冷态布局）
  test_dir 已有 128G 数据

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=70.1 WRITE=NA NIC_RX=5202.5
  randwrite r1: READ=NA WRITE=41.1 NIC_RX=418.4
  randrw r1: READ=18.0 WRITE=17.6 NIC_RX=1665.3
### Round 2
  randread r2: READ=118 WRITE=NA NIC_RX=6155.6
  randwrite r2: READ=NA WRITE=52.1 NIC_RX=242.8
  randrw r2: READ=13.3 WRITE=13.0 NIC_RX=1423.9
### Round 3
  randread r3: READ=156 WRITE=NA NIC_RX=6150.0
  randwrite r3: READ=NA WRITE=48.7 NIC_RX=311.5
  randrw r3: READ=15.4 WRITE=15.0 NIC_RX=1557.2

DONE
  commands.sh generated
