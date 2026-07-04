============================================================
全量测试 full-bs256k-warm-3patch-r1-20260702-115419
============================================================

## 挂载: 

## 顺序 (bs=256K)
seqread: READ=29.1 MiB/s
seqwrite: WRITE=42.8 MiB/s
multi-seqread: READ=98.7 MiB/s
multi-seqwrite: WRITE=34.6 MiB/s

## 布局 (128G)
layout: WRITE= MiB/s

## 随机 (3轮bs=256K, 128jobs, iodepth=128, direct=1)
randread: r1=35.6 | r2=25.4 | r3=71.0 | MAX=71.0 MiB/s
randwrite: r1=28.6 | r2=46.6 | r3=24.2 | MAX=46.6 MiB/s
randrw: r1 R=2.6/W=2.6 | r2 R=15.8/W=15.5 | r3 R=15.1/W=14.7 | MAX R=15.8/W=15.6 MiB/s
