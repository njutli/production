============================================================
暖态基线 noRA 测试（可追溯） 20260625-201339
============================================================

## 测试方法
  脚本: tests/bench-warm-baseline-noRA.sh
  启动命令: cd /home/turboai/production && bash tests/bench-warm-baseline.sh
  输出目录: results/warm-baseline-noRA-20260625/
  口径: 复用冷态基线的卷和 128G 布局, 不 destroy/reformat
  挂载: --cache-size 102400 --max-readahead 0 --cache-dir /data/jfsCache (100G, JuiceFS 默认)
  不 drop_caches (客户端 + OSD 都不 drop, 模拟生产暖态)
  顺序项各 1 次; 随机项 7 轮, 观察收敛趋势
  每轮记录: cache 大小 + NIC RX

## 环境快照

### 集群状态
  ceph status -> results/warm-baseline-noRA-20260625/ceph-status-before.txt
### 客户端状态
  client status -> results/warm-baseline-noRA-20260625/client-status-before.txt

## 挂载
  --cache-size 102400 --max-readahead 0 --cache-dir /data/jfsCache (100G, JuiceFS 默认)
  不 drop_caches（暖态，模拟生产）
  清空 cache 目录（确保 r1 cache 为空）
  mount OK
  布局文件数=128（期望128）

## 顺序测试 (100G cache, 不 drop_caches)
### seqread prep (write 4G)
  seqread: READ=48.6 WRITE=NA NIC_RX=4321.8
  seqwrite: READ=NA WRITE=53.5 NIC_RX=63.4
  multi-seqread: READ=107 WRITE=NA NIC_RX=69177.6
  multi-seqwrite: READ=NA WRITE=39.0 NIC_RX=1000.5

## 随机测试 (reuse 128G layout, 100G cache, 不 drop_caches, 7 rounds)
  目标：观察 r1→r7 收敛趋势，连续两轮变化 <5% 视为稳态
### Round 1
  randread r1: READ=62.0 WRITE=NA NIC_RX=4861.7
  randwrite r1: READ=NA WRITE=46.0 NIC_RX=449.9
  randrw r1: READ=17.3 WRITE=17.0 NIC_RX=1632.1
### Round 2
  randread r2: READ=104 WRITE=NA NIC_RX=6005.3
  randwrite r2: READ=NA WRITE=52.9 NIC_RX=257.4
  randrw r2: READ=14.2 WRITE=13.9 NIC_RX=1469.9
### Round 3
  randread r3: READ=132 WRITE=NA NIC_RX=5677.3
  randwrite r3: READ=NA WRITE=48.9 NIC_RX=309.9
  randrw r3: READ=14.8 WRITE=14.5 NIC_RX=1493.3
### Round 4
  randread r4: READ=163 WRITE=NA NIC_RX=5900.5
  randwrite r4: READ=NA WRITE=51.5 NIC_RX=244.7
  randrw r4: READ=13.7 WRITE=13.4 NIC_RX=1421.7
### Round 5
  randread r5: READ=206 WRITE=NA NIC_RX=5535.8
  randwrite r5: READ=NA WRITE=45.8 NIC_RX=311.8
  randrw r5: READ=16.2 WRITE=15.9 NIC_RX=1613.3
### Round 6
  randread r6: READ=251 WRITE=NA NIC_RX=5995.7
  randwrite r6: READ=NA WRITE=50.6 NIC_RX=196.9
  randrw r6: READ=15.3 WRITE=15.0 NIC_RX=1551.5
### Round 7
  randread r7: READ=293 WRITE=NA NIC_RX=6042.1
  randwrite r7: READ=NA WRITE=47.8 NIC_RX=250.0
  randrw r7: READ=14.7 WRITE=14.4 NIC_RX=1534.5

## OSD 后状态
  ceph status after -> results/warm-baseline-noRA-20260625/ceph-status-after.txt

============================================================
## 汇总
============================================================

所有原始 fio 输出保存在: results/warm-baseline-noRA-20260625/
  - ceph-status-before.txt / ceph-status-after.txt (集群状态前后对比)
  - client-status-before.txt (客户端状态快照)
  - mount.log (挂载参数)
  - seqread.txt / seqwrite.txt / multi-seqread.txt / multi-seqwrite.txt
  - randread-r{1..7}.txt / randwrite-r{1..7}.txt / randrw-r{1..7}.txt
  - summary.txt (本文件)

每轮 fio 文件包含: mount 参数 + 日期 + cache 大小 + fio 完整输出
每轮 summary 记录: READ/WRITE/NIC_RX

DONE
