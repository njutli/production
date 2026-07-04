============================================================
RA Sweep ra=1 20260703-103329
============================================================
## 口径:
  block-size=256K, cache=0, max-readahead=1 MiB
  seqread: 1次 (无 direct=1，与历史一致); randread: 3轮
  复用已有 128G 布局，不 destroy/format/layout

## Drop OSD page cache
  192.168.11.11 cache dropped
  192.168.11.13 cache dropped
  192.168.11.14 cache dropped
  env snapshot saved
## 挂载
  mount OK

## 顺序读 (bs=256K, 无 direct=1)
### seqread prep (write 4G)
  seqread: READ=74.7 NIC_RX=4320.7

## 随机读 (3轮, bs=256K, 128jobs, iodepth=128, direct=1, runtime=60s)
  randread r1: READ=51.0 NIC_RX=6971.8
  randread r2: READ=54.6 NIC_RX=7099.6
  randread r3: READ=54.5 NIC_RX=7094.5

DONE
  commands.sh generated
