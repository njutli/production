============================================================
全量测试 warm-cache100g-mu150 20260703-054239
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache --max-uploads 150
  seq: 1次; rand: 3轮
  DO_FORMAT=0, DO_LAYOUT=0

  env snapshot -> results/patched-v1.3.1-retest-20260702/full-bs256k-warm-cache100g-mu150-20260703-054239/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=36.4 WRITE=NA NIC_RX=4343.8
  seqwrite: READ=NA WRITE=44.7 NIC_RX=68.6
  multi-seqread: READ=103 WRITE=NA NIC_RX=69288.3
  multi-seqwrite: READ=NA WRITE=39.4 NIC_RX=1111.6

## 布局: 跳过（暖态复用冷态布局）
  test_dir 已有 128G 数据

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=36.0 WRITE=NA NIC_RX=5706.8
  randwrite r1: READ=NA WRITE=51.9 NIC_RX=341.7
  randrw r1: READ=25.8 WRITE=25.4 NIC_RX=2497.2
### Round 2
  randread r2: READ=80.1 WRITE=NA NIC_RX=6770.2
  randwrite r2: READ=NA WRITE=53.2 NIC_RX=256.1
  randrw r2: READ=25.8 WRITE=25.2 NIC_RX=1725.8
### Round 3
  randread r3: READ=111 WRITE=NA NIC_RX=6561.9
  randwrite r3: READ=NA WRITE=55.3 NIC_RX=170.4
  randrw r3: READ=24.3 WRITE=24.0 NIC_RX=1713.2

DONE
  commands.sh generated
