============================================================
全量测试 full-bs256k-cold-3patch-ra0-r1-20260702-051430
============================================================

## 挂载: mount -d --cache-size 0 --max-readahead 0 OK

## 顺序 (bs=256K)
seqread: READ=54.4 MiB/s
seqwrite: WRITE=55.9 MiB/s
multi-seqread: READ=107 MiB/s
multi-seqwrite: WRITE= MiB/s

## 布局 (128G)
layout: WRITE=37.2 MiB/s

## 随机 (3轮bs=256K, 128jobs, iodepth=128, direct=1)
randread: r1=98.1 | r2=51.0 | r3=68.2 | MAX=98.1 MiB/s
randwrite: r1=62.7 | r2=39.2 | r3=47.9 | MAX=62.7 MiB/s
randrw: r1 R=10.6/W=10.4 | r2 R=16.6/W=16.3 | r3 R=13.7/W=13.5 | MAX R=16.6/W=16.3 MiB/s
