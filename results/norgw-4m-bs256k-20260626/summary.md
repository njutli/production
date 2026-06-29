============================================================
回退测试2：去 RGW + fio bs=4M / block-size=256K 冷态基线 20260626-144303
============================================================
## 口径:
  STORAGE=ceph (直连 RADOS)
  block-size=256K, fio bs=4M (bs != block-size)
  cache-size=0 (冷态), client drop_caches
  --max-uploads=150 (官方推荐)
  随机项 REPEAT=3

  env snapshot -> results/norgw-4m-bs256k-20260626/env-snapshot.txt
## 格式化卷 (直连 Ceph, block-size=256K)
## 挂载 (--cache-size 0, --max-uploads=150)
  mount OK

## 顺序测试 (fio bs=4M, block-size=256K, cache-size 0)
### seqread prep (write 4G)
  seqread: READ=79.8 WRITE=NA
  seqwrite: READ=NA WRITE=48.3
  multi-seqread: READ=108 WRITE=NA
  multi-seqwrite: READ=NA WRITE=40.7

## 布局 (128 jobs x 1G = 128G)
  layout: WRITE=37.4

## 随机测试 (REPEAT=3)
### Round 1
  randread r1: READ=27.4 WRITE=NA
  randwrite r1: READ=NA WRITE=52.5
  randrw r1: READ=18.2 WRITE=17.9
### Round 2
  randread r2: READ=30.5 WRITE=NA
  randwrite r2: READ=NA WRITE=51.4
  randrw r2: READ=18.4 WRITE=18.0
### Round 3
  randread r3: READ=30.6 WRITE=NA
  randwrite r3: READ=NA WRITE=55.5
  randrw r3: READ=19.7 WRITE=19.3

DONE
  commands.sh generated
