============================================================
全量测试 cold-mu150-full 20260703-145314
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=cold, mount_opts=--cache-size 0 --max-uploads 150
  seq: 1次; rand: 3轮
  DO_FORMAT=1, DO_LAYOUT=1

  env snapshot -> results/patched-v1.3.1-retest-20260702/full-bs256k-cold-mu150-full-20260703-145314/env-snapshot.txt
## 格式化卷
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=78.5 WRITE=NA NIC_RX=4326.2
  seqwrite: READ=NA WRITE=57.0 NIC_RX=67.8
  multi-seqread: READ=108 WRITE=NA NIC_RX=69177.3
  multi-seqwrite: READ=NA WRITE=43.7 NIC_RX=1073.7

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=39.1
## Layout cooldown: 等待 compaction 完成

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=38.6 WRITE=NA NIC_RX=5311.6
  randwrite r1: READ=NA WRITE=54.8 NIC_RX=338.4
  randrw r1: READ=13.8 WRITE=13.7 NIC_RX=1950.2
### Round 2
  randread r2: READ=30.3 WRITE=NA NIC_RX=4165.2
  randwrite r2: READ=NA WRITE=55.4 NIC_RX=165.7
  randrw r2: READ=19.4 WRITE=19.1 NIC_RX=2737.7
### Round 3
  randread r3: READ=47.8 WRITE=NA NIC_RX=6545.7
  randwrite r3: READ=NA WRITE=55.7 NIC_RX=269.1
  randrw r3: READ=17.4 WRITE=17.1 NIC_RX=2467.8

DONE
  commands.sh generated
