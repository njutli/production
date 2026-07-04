============================================================
全量测试 full-bs256k-cold-3patch-r1-20260701-215203
============================================================

## 挂载: 

## 顺序 (bs=256K)
seqread: READ=104 MiB/s
seqwrite: WRITE=60.6 MiB/s
multi-seqread: READ=109 MiB/s
multi-seqwrite: WRITE= MiB/s

## 布局 (128G)
layout: WRITE=36.6 MiB/s

## 随机 (3轮bs=256K, 128jobs, iodepth=128, direct=1)
randread: r1=49.1 | r2=51.5 | r3=48.0 | MAX=51.5 MiB/s
randwrite: r1=61.1 | r2=58.3 | r3=34.3 | MAX=61.1 MiB/s
randrw: r1 R=21.8/W=21.4 | r2 R=14.8/W=14.5 | r3 R=15.5/W=15.2 | MAX R=21.8/W=21.4 MiB/s
