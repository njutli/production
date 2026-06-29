============================================================
顺序读写 bs=256K 专项测试 (cold) 20260626-180350
============================================================
## 口径:
  block-size=256K, fio bs=256K (bs == block-size)
  mode=cold, mount_opts=--cache-size 0
  顺序项各 1 次

## 格式化卷
## 挂载
  mount OK

## 顺序测试 (bs=256K, block-size=256K)
### seqread prep (write 4G)
  seqread: READ=76.1 WRITE=NA NIC_RX=4325.5
  seqwrite: READ=NA WRITE=49.4 NIC_RX=65.2
