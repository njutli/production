============================================================
全量测试 full-bs256k-warm-3patch-ra0-r1-20260702-132647
============================================================

## 挂载: 

## 顺序 (bs=256K)
seqread: READ=5.9 MiB/s
seqwrite: WRITE=42.6 MiB/s
multi-seqread: READ=108 MiB/s
multi-seqwrite: WRITE=38.4 MiB/s

## 布局 (128G)
layout: WRITE= MiB/s

## 随机 (3轮bs=256K, 128jobs, iodepth=128, direct=1)
randread: r1=117 | r2=163 | r3=204 | MAX=204 MiB/s
randwrite: r1=46.2 | r2=53.6 | r3=55.2 | MAX=55.2 MiB/s
randrw: r1 R=16.1/W=15.7 | r2 R=14.6/W=14.3 | r3 R=15.3/W=15.0 | MAX R=16.1/W=15.7 MiB/s
