============================================================
全量测试 prod-nolimit-cold-ra0-20260715-235631
============================================================

## 口径: 不限速 100GbE (ra0 --max-readahead 0)
  JuiceFS v1.3.1+eaf3d21f, cephadm 容器 OSD, 双网分离
  cache-size=0, runtime=180s, REPEAT=3
  fsid: 7bb47ec2-8061-11f1-a671-97520597268c

## 顺序测试
  seqread: READ=178
  seqwrite: WRITE=1350
  mseqread: READ=1755
  mseqwrite: WRITE=2799

## 布局 (128G)
  layout: WRITE=2954

## 随机测试 (3轮, 128jobs, iodepth=128, direct=1)
  randread: R1=2576 | R2=2570 | R3=2572 | MEDIAN=2572 MiB/s
  randwrite: R1=2652 | R2=2673 | R3=2560 | MEDIAN=2652 MiB/s
  randrw: R1 R=20.6/W=52.0 | R2 R=20.8/W=52.7 | R3 R=20.6/W=52.1
  randrw MEDIAN: R=20.6 W=52.1 合计=72.7 MiB/s
  (R/W 分列为高并发队列失真，以合计为准)

DONE
