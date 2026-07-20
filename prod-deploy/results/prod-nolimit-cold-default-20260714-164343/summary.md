============================================================
全量测试 prod-nolimit-cold-default-20260714-164343
============================================================

## 口径:
  STORAGE=ceph (直连 RADOS)
  block-size=256K, fio bs=256k(读)/4M(写)
  cache-size=0 (冷态), drop_caches
  JuiceFS v1.3.1+eaf3d21f (partial read fix)
  cephadm 容器 OSD, 双网分离 (public=10.3.1 / cluster=10.3.2)
  readahead=default (A 组)
  随机项 REPEAT=3, runtime=180s

## 顺序测试
  seqread: READ=1272
  seqwrite: WRITE=1346
  multi-seqread: READ=3330
  multi-seqwrite: WRITE=3891

## 布局 (128G)
  layout: WRITE=3841

## 随机测试 (3轮, 128jobs, iodepth=128, direct=1)
  randread: r1=1519 | r2=1474 | r3=1471 | MEDIAN=1474 MiB/s
  randwrite: r1=3471 | r2=3412 | r3=3373 | MEDIAN=3412 MiB/s
  randrw: r1 R=17.9/W=47.4 | r2 R=17.9/W=47.5 | r3 R=18.0/W=47.6 | MEDIAN R=17.9/W=47.5 MiB/s

DONE
