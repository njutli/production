============================================================
全量测试 cold-mu150-memdisk 20260709
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=cold, mount_opts=--cache-size 0 --max-uploads 150
  seq: 1次; rand: 3轮
  后端: 全内存盘（6 OSD DATA+WAL/DB 全 tmpfs）
  layout: 128j×512M=64G（tmpfs 空间限制，从 128G 缩小）

## 格式化卷
## 挂载 (mu=150)
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=106 WRITE=NA
  seqwrite: READ=NA WRITE=117
  multi-seqread: READ=116 WRITE=NA
  multi-seqwrite: READ=NA WRITE=69.8

## 布局 (128 jobs x 512M = 64G, bs=4M)
  layout: WRITE=104
## Layout cooldown: 等待 compaction 完成

## 随机测试 (3轮, bs=256K, block-size=256K)
### Round 1
  randread r1: READ=53.1 WRITE=NA
  randwrite r1: READ=NA WRITE=126
  randrw r1: READ=47.8 WRITE=47.4
### Round 2
  randread r2: READ=54.1 WRITE=NA
  randwrite r2: READ=NA WRITE=124
  randrw r2: READ=48.1 WRITE=47.6
### Round 3
  randread r3: READ=54.1 WRITE=NA
  randwrite r3: READ=NA WRITE=125
  randrw r3: READ=47.9 WRITE=47.6

DONE
