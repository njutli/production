============================================================
暖态基线第二轮（验证） 20260626-003829
============================================================

## 口径: 复用冷态布局, --cache-size 102400 --max-readahead 0, 不 drop_caches

## 挂载
  mount OK
  布局文件数=128（期望128）

## 顺序测试 (100G cache, 不 drop_caches)
### seqread prep (write 4G)
  seqread: READ=47.1 WRITE=NA NIC_RX=4321.4
  seqwrite: READ=NA WRITE=51.6 NIC_RX=63.0
  multi-seqread: READ=107 WRITE=NA NIC_RX=69131.8
  multi-seqwrite: READ=NA WRITE=39.5 NIC_RX=1056.3

## 随机测试 (reuse 128G layout, 100G cache, 不 drop_caches, 7 rounds)
### Round 1
  randread r1: READ=65.7 WRITE=NA NIC_RX=5151.7
  randwrite r1: READ=NA WRITE=46.0 NIC_RX=425.5
  randrw r1: READ=14.7 WRITE=14.4 NIC_RX=1467.3
### Round 2
  randread r2: READ=97.2 WRITE=NA NIC_RX=5500.3
  randwrite r2: READ=NA WRITE=47.0 NIC_RX=367.1
  randrw r2: READ=16.6 WRITE=16.2 NIC_RX=1604.5
### Round 3
  randread r3: READ=142 WRITE=NA NIC_RX=6078.1
  randwrite r3: READ=NA WRITE=52.2 NIC_RX=230.9
  randrw r3: READ=16.3 WRITE=15.9 NIC_RX=1632.9
### Round 4
  randread r4: READ=183 WRITE=NA NIC_RX=6106.8
  randwrite r4: READ=NA WRITE=52.7 NIC_RX=197.1
  randrw r4: READ=13.4 WRITE=13.2 NIC_RX=1379.4
### Round 5
  randread r5: READ=219 WRITE=NA NIC_RX=6051.8
  randwrite r5: READ=NA WRITE=51.1 NIC_RX=260.2
  randrw r5: READ=14.2 WRITE=13.9 NIC_RX=1530.1
### Round 6
  randread r6: READ=260 WRITE=NA NIC_RX=5986.0
  randwrite r6: READ=NA WRITE=41.3 NIC_RX=195.2
  randrw r6: READ=11.2 WRITE=11.1 NIC_RX=1209.5
### Round 7
  randread r7: READ=286 WRITE=NA NIC_RX=4440.8
  randwrite r7: READ=NA WRITE=42.5 NIC_RX=311.6
  randrw r7: READ=15.3 WRITE=15.0 NIC_RX=1527.5

DONE
