============================================================
顺序读写测试 warm 20260627-174415
============================================================
## 口径:
  block-size=4M, fio seq bs=4M
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache 

  env snapshot -> results/seq-4m-bs4m-warm-20260627-174415/env-snapshot.txt
## 挂载
  mount OK

## 顺序测试 (bs=4M, block-size=4M)
### seqread prep (write 4G)
