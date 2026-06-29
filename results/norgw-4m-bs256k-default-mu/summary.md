============================================================
回退测试2：去 RGW + fio bs=4M / block-size=256K 冷态基线 20260627-132506
============================================================
## 口径:
  STORAGE=ceph (直连 RADOS)
  block-size=256K, fio bs=4M (bs != block-size)
  cache-size=0 (冷态), client drop_caches
   (官方推荐)
  随机项 REPEAT=3

  env snapshot -> results/norgw-4m-bs256k-default-mu/env-snapshot.txt
## 格式化卷 (直连 Ceph, block-size=256K)
## 挂载 (--cache-size 0, )
  mount OK

## 顺序测试 (fio bs=4M, block-size=256K, cache-size 0)
### seqread prep (write 4G)
  seqread: READ=79.9 WRITE=NA
  seqwrite: READ=NA WRITE=53.8
  multi-seqread: READ=107 WRITE=NA
  multi-seqwrite: READ=NA WRITE=39.7

## 布局 (128 jobs x 1G = 128G)
  layout: WRITE=32.3

## 随机测试 (REPEAT=3)
### Round 1
  randread r1: READ=32.3 WRITE=NA
  randwrite r1: READ=NA WRITE=32.7
  randrw r1: READ=15.0 WRITE=14.6
### Round 2
  randread r2: READ=31.3 WRITE=NA
  randwrite r2: READ=NA WRITE=26.3
  randrw r2: READ=14.2 WRITE=13.9
### Round 3
  randread r3: READ=32.4 WRITE=NA
  randwrite r3: READ=NA WRITE=33.3
  randrw r3: READ=15.6 WRITE=15.4

DONE
  commands.sh generated
