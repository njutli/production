============================================================
顺序读写测试 warm 20260627-193050
============================================================
## 口径:
  block-size=4M, fio seq bs=4M
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache 

  env snapshot -> results/seq-4m-bs4m-warm-20260627-193050/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=4M, block-size=4M)
### seqread prep (write 4G)
  seqread: READ=90.3 WRITE=NA NIC_RX=4303.7
  seqwrite: READ=NA WRITE=62.7 NIC_RX=58.5
  multi-seqread: READ=110 WRITE=NA NIC_RX=68847.3
  multi-seqwrite: READ=NA WRITE=48.1 NIC_RX=855.9

DONE
  commands.sh generated
