============================================================
基线重测第二轮（验证） 20260625-215656
============================================================

## 口径: STORAGE=ceph, block-size 256K, cache-size 0, client drop_caches, 随机项 REPEAT=3

## 格式化卷
## 挂载
  mount OK

## 顺序测试
### seqread prep (write 4G)
  seqread: READ=79.4 WRITE=NA
  seqwrite: READ=NA WRITE=53.9
  multi-seqread: READ=110 WRITE=NA
  multi-seqwrite: READ=NA WRITE=40.0

## 布局 (128 jobs x 1G = 128G)
  layout: WRITE=33.4

## 随机测试 (REPEAT=3)
### Round 1
  randread r1: READ=34.0 WRITE=NA
  randwrite r1: READ=NA WRITE=21.1
  randrw r1: READ=NA WRITE=NA
### Round 2
  randread r2: READ=30.8 WRITE=NA
  randwrite r2: READ=NA WRITE=38.9
  randrw r2: READ=16.1 WRITE=15.8
### Round 3
  randread r3: READ=30.7 WRITE=NA
  randwrite r3: READ=NA WRITE=39.8
  randrw r3: READ=16.2 WRITE=16.0

DONE
