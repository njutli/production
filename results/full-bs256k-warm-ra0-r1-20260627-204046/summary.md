============================================================
全量测试 warm-ra0-r1 20260627-204046
============================================================
## 口径:
  block-size=256K, fio seq bs=256K, fio rand bs=256K
  mode=warm, mount_opts=--cache-size 102400 --cache-dir /data/jfsCache --max-readahead
  seq: 1次; rand: 3轮

  env snapshot -> results/full-bs256k-warm-ra0-r1-20260627-204046/env-snapshot.txt
## 挂载
FATAL: mount failed
