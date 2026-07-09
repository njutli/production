============================================================
冷态全量基线复测（加强 stall 检查） 20260706-105817
============================================================

## 测试方法
  脚本: tests/bench-cold-baseline-recheck.sh
  口径: patched v1.3.1, cache=0, 无 mu 无 ra
  fio bs: seq=256K / layout=4M / rand=256k（匹配旧基线）
  目的: 复现旧基线流程,全程采集 stall,回答过去数据准不准
  对照旧基线: results/full-bs256k-cold-r1-20260626-200742/

## 环境快照
  env snapshot -> results/cold-baseline-recheck-20260706/env-snapshot.txt

## 启动后台监控
### Starting background monitoring at Mon Jul  6 10:58:20 CST 2026 ###
  health timeline PID=3987570
344938
  started osd.0 perf monitor on 192.168.11.11
344998
  started osd.1 perf monitor on 192.168.11.11
3621287
  started osd.2 perf monitor on 192.168.11.13
3621341
  started osd.3 perf monitor on 192.168.11.13
2490879
  started osd.4 perf monitor on 192.168.11.14
2490933
  started osd.5 perf monitor on 192.168.11.14
345121
  started iostat on 192.168.11.11 (ceph-node1)
3621446
  started iostat on 192.168.11.13 (ceph-node2)
2491038
  started iostat on 192.168.11.14 (ceph-node3)
  monitoring started, sleep 5 to verify
  health timeline verified (7 lines)
  osd.0 perf monitor verified (1 lines)
  osd.1 perf monitor verified (1 lines)
  osd.2 perf monitor verified (1 lines)
  osd.3 perf monitor verified (1 lines)
  osd.4 perf monitor verified (1 lines)
  osd.5 perf monitor verified (1 lines)

## 格式化卷
  STORAGE=ceph, pool=juicefs-data, block-size=256K

## 挂载
  --cache-size 0 (patched v1.3.1, 无 mu 无 ra)
  mount OK

## 顺序测试 (bs=256K, cache=0, 匹配旧基线口径)
### seqread prep (write 4G)
  seqread: READ=78.9 WRITE=NA
  seqwrite: READ=NA WRITE=55.3
  multi-seqread: READ=109 WRITE=NA
  multi-seqwrite: READ=NA WRITE=40.8

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=33.7

## layout 后 stall 检查
  layout 后无 stall
  等待 120s cooldown (匹配旧基线)...

## 随机测试 (reuse layout, cache=0, 3 rounds)
### Round 1
  randread r1: READ=39.7 WRITE=NA
  randwrite r1: READ=NA WRITE=43.0
  randrw r1: READ=18.1 WRITE=17.7
### Round 2
  randread r2: READ=49.2 WRITE=NA
  randwrite r2: READ=NA WRITE=25.3
  randrw r2: READ=16.6 WRITE=16.3
### Round 3
  randread r3: READ=48.3 WRITE=NA
  randwrite r3: READ=NA WRITE=41.5
  randrw r3: READ=17.2 WRITE=16.8

## 停止监控
### Stopping background monitoring at Mon Jul  6 13:27:27 CST 2026 ###
  health timeline stopped
  collected osd.0 perf timeline (1 lines)
  collected osd.1 perf timeline (1 lines)
  collected osd.2 perf timeline (1 lines)
  collected osd.3 perf timeline (1 lines)
  collected osd.4 perf timeline (1 lines)
  collected osd.5 perf timeline (1 lines)
  collected iostat from ceph-node1
  collected iostat from ceph-node2
  collected iostat from ceph-node3

============================================================
## 汇总
============================================================

所有原始 fio 输出保存在: results/cold-baseline-recheck-20260706/
  - env-snapshot.txt / format.log / mount.log
  - seqread.txt / seqwrite.txt / multi-seqread.txt / multi-seqwrite.txt
  - layout.txt
  - randread-r{1,2,3}.txt / randwrite-r{1,2,3}.txt / randrw-r{1,2,3}.txt
  - backend/ (health-timeline, osd-perf-timelines, iostat, snapshots)
  - stall-events.log / restart.log (如有)

DONE
