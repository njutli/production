============================================================
顺序读写测试 cold 20260627-160936
============================================================
## 口径:
  block-size=4M, fio seq bs=4M
  mode=cold, mount_opts=--cache-size 0 

  env snapshot -> results/seq-4m-bs4m-cold-20260627-160936/env-snapshot.txt
## 格式化卷
## 挂载
  mount OK

## 顺序测试 (bs=4M, block-size=4M)
### seqread prep (write 4G)
  seqread: READ=86.7 WRITE=NA NIC_RX=4302.9
  seqwrite: READ=NA WRITE=54.2 NIC_RX=57.1
  multi-seqread: READ=110 WRITE=NA NIC_RX=68866.4
  multi-seqwrite: READ=NA WRITE=44.0 NIC_RX=894.9

DONE
  commands.sh generated
