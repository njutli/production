============================================================
冷态 mu=150 精简测试 20260703-125419（仅随机测试）
============================================================
## 口径:
  block-size=256K, cache=0, max-uploads=150
  rand: 3轮（跳过顺序测试避免 BlueFS stall）
  复用已有 128G 布局

## Drop OSD page cache
  192.168.11.11 cache dropped
  192.168.11.13 cache dropped
  192.168.11.14 cache dropped
## 挂载
  mount OK

## 随机测试 (3轮, bs=256K, 128jobs, iodepth=128, direct=1, runtime=60s)
### Round 1
  randread r1: READ=48.7 WRITE=NA NIC_RX=6674.0
  randwrite r1: READ=NA WRITE=45.9 NIC_RX=203.4
  randrw r1: READ=26.6 WRITE=26.3 NIC_RX=3743.3
### Round 2
  randread r2: READ=48.4 WRITE=NA NIC_RX=6607.8
  randwrite r2: READ=NA WRITE=46.3 NIC_RX=225.1
  randrw r2: READ=26.3 WRITE=26.0 NIC_RX=3701.9
### Round 3
  randread r3: READ=33.2 WRITE=NA NIC_RX=4769.6
  randwrite r3: READ=NA WRITE=41.8 NIC_RX=172.6
  randrw r3: READ=21.8 WRITE=21.5 NIC_RX=3106.1

DONE
  commands.sh generated
