============================================================
全量测试 full-bs256k-warm-3patch-mu150-r1-20260702-150405
============================================================

## 挂载: 

## 顺序 (bs=256K)
seqread: READ=30.2 MiB/s
seqwrite: WRITE=46.3 MiB/s
multi-seqread: READ=104 MiB/s
multi-seqwrite: WRITE=39.9 MiB/s

## 布局 (128G)
layout: WRITE= MiB/s

## 随机 (3轮bs=256K, 128jobs, iodepth=128, direct=1)
randread: r1=53.8 | r2=101 | r3=140 | MAX=140 MiB/s
randwrite: r1=53.3 | r2=50.7 | r3=56.1 | MAX=56.1 MiB/s
randrw: r1 R=23.5/W=23.0 | r2 R=15.8/W=15.6 | r3 R=22.9/W=22.5 | MAX R=23.5/W=23.0 MiB/s
