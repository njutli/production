#!/bin/bash
# Multi-client aggregation test
# Binary: patched v1.3.1 (v1.3.1+2025-12-02.e0032b2a, loadRange fixed)
# Date: 2026-07-04

# ---- Mount all 3 clients ----
# tikv (.12): juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs
# node1 (.11): ssh .11 "juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs"
# node2 (.13): ssh .13 "juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs"
# config: default ra, mu=150, cache=0, reuse 128G layout

# ---- fio command template ----
# fio --directory=/mnt/juicefs/test_dir --name=storage_test \
#     --filesize=1G --size=1G --bs=256k \
#     --rw={randread|randrw} --ioengine=libaio --iodepth=128 --numjobs=128 \
#     --direct=1 --fallocate=none --openfiles=100 --create_serialize=0 \
#     --group_reporting --time_based --runtime=60s

# ---- Drop all (before each round) ----
# for ip in 192.168.11.12 192.168.11.11 192.168.11.13 192.168.11.14; do
#   ssh $ip 'sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo OK'
# done

# ---- NIC sampling ----
# cat /proc/net/dev | grep eno1 | awk '{rx=$2; tx=$10; print rx, tx}'
