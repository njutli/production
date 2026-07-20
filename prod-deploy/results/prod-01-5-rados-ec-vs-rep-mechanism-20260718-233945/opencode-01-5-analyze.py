#!/usr/bin/env python3
"""01-5 rados bench EC vs Rep 后端机制诊断 - 数据分析脚本

输入：本地结果目录（已从 157 拷回）
输出：summary.md（中文）+ parsed.json（机读）

分析维度：
- 三模式带宽中位数（write / seqread / randread × 4 -t × 3 轮）
- 6 类机制量化贡献：
  H1: fan-in 尾延迟（rados bench Min/Max IOPS 比）
  H2: op 计数放大（OSD perf dump op_r/op_w delta / logical ops）
  H3: per-OSD 队列饱和（iostat %util 峰值）
  H4: cluster 网络流量（sar MB/s vs logical MB/s）
  H5: 写放大（OSD op_w_in_bytes delta / logical bytes）
  H6: CPU 编解码（pidstat OSD CPU% 峰值）
"""

import os
import re
import json
import sys
from pathlib import Path

# 全局配置
RESULTS_DIR = sys.argv[1] if len(sys.argv) > 1 else '/home/lilingfeng/demo/production/prod-deploy/results/prod-01-5-rados-ec-vs-rep-mechanism-20260718-233945'
EC_POOL = 'juicefs-data'
REP_POOL = 'juicefs-data-rep'
SLAVE_NODES = ['ceph-node1', 'ceph-node2', 'ceph-node3']
OSD_PER_NODE = {'ceph-node1': [0, 1], 'ceph-node2': [2, 3], 'ceph-node3': [4, 5]}

# === 工具函数 ===

def parse_rados_bench(path):
    """解析 rados bench 输出，返回 bandwidth MB/s, IOPS avg/min/max/stddev
    
    两种格式：
    A) write 模式：Max/Min bandwidth + Average IOPS（无 Bandwidth 单行）
       Max bandwidth (MB/sec): 2997
       Min bandwidth (MB/sec): 2093
       Average IOPS:           11629
    B) seq/rand 模式：Bandwidth (MB/sec): X.XX + Average IOPS（无 Max/Min bandwidth）
       Bandwidth (MB/sec):   3115.24
       Average IOPS:         12460
    
    bw_avg 始终 = Average IOPS × obj_size (256K = 0.25 MiB) → MiB/s
    bw_min/max：write 直接取；seq/rand 从 per-second cur MB/s 列解析
    """
    if not os.path.exists(path):
        return None
    text = Path(path).read_text()
    
    result = {}
    
    # Average IOPS（两种格式都有）
    m = re.search(r'Average IOPS:\s+([\d.]+)', text)
    if m:
        result['avg_iops'] = float(m.group(1))
        # obj_size = 256K = 0.25 MiB → avg_bw_mib = avg_iops × 0.25
        result['avg_mb'] = float(m.group(1)) * 0.25
    
    # Min IOPS / Max IOPS（IOPS 维度，两种格式都有）
    m = re.search(r'Max IOPS:\s+(\d+)', text)
    if m:
        result['max_iops'] = int(m.group(1))
        result['max_mb'] = int(m.group(1)) * 0.25  # IOPS → MiB/s
    
    m = re.search(r'Min IOPS:\s+(\d+)', text)
    if m:
        result['min_iops'] = int(m.group(1))
        result['min_mb'] = int(m.group(1)) * 0.25  # IOPS → MiB/s
    
    # Stddev IOPS
    m = re.search(r'Stddev IOPS:\s+([\d.]+)', text)
    if m:
        result['stddev'] = float(m.group(1))
    
    # Format A: write — 显式 Max/Min bandwidth（覆盖上面 IOPS 转换值，更准）
    m = re.search(r'Max bandwidth \(MB/sec\):\s+([\d.]+)', text)
    if m:
        result['max_mb'] = float(m.group(1))
    
    m = re.search(r'Min bandwidth \(MB/sec\):\s+([\d.]+)', text)
    if m:
        result['min_mb'] = float(m.group(1))
    
    # Format B: seq/rand — 显式 Bandwidth (MB/sec): 3115.24（覆盖 IOPS 转换值）
    m = re.search(r'Bandwidth \(MB/sec\):\s+([\d.]+)', text)
    if m:
        result['avg_mb'] = float(m.group(1))
    
    # 兜底：seq/rand 模式若无 Min/Max bandwidth，从 per-second cur MB/s 列取
    if 'min_mb' not in result or 'max_mb' not in result:
        cur_bws = []
        for line in text.splitlines():
            # 匹配 sec cur_ops started finished avg_mb cur_mb ...
            m = re.match(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+([\d.]+)\s+([\d.]+)\s', line)
            if m:
                cur_bws.append(float(m.group(2)))
        if cur_bws:
            if 'min_mb' not in result:
                result['min_mb'] = min(cur_bws)
            if 'max_mb' not in result:
                result['max_mb'] = max(cur_bws)
    
    return result if result else None

def parse_perf_dump(path):
    """解析 perf dump 文本（含 === osd.X === 头 + JSON 块），返回 {osd_id: stats_dict}"""
    if not os.path.exists(path):
        return {}
    text = Path(path).read_text()
    result = {}
    # 用 === osd.X === 分块
    blocks = re.split(r'^=== osd\.(\d+) on \S+ ===\s*$', text, flags=re.MULTILINE)
    # blocks[0] = 前导空, 然后 [osd_id, json_text, osd_id, json_text, ...]
    for i in range(1, len(blocks), 2):
        osd_id = int(blocks[i])
        json_text = blocks[i+1].strip()
        try:
            data = json.loads(json_text)
            result[osd_id] = data
        except json.JSONDecodeError:
            pass
    return result

def extract_op_counters(perf_data):
    """从 perf dump 提取关键计数器
    注：Ceph OSD perf dump 中
      - op_r = primary 读 op 计数（不含 subop）
      - op_r_out_bytes = 读响应总字节（含 primary 响应给 client + 子op 响应给 primary）
      - op_w_in_bytes = 写入总字节（含 primary 写 + 副本/parity 接收的子op 写）
      - op_wip = in-flight ops
    op_r_out_bytes 是放大率分析最准的字节维度计数器
    """
    if not perf_data:
        return None
    osd_data = perf_data.get('osd', {})
    return {
        'op_r': osd_data.get('op_r', 0),
        'op_w': osd_data.get('op_w', 0),
        'op_r_out_bytes': osd_data.get('op_r_out_bytes', 0),
        'op_w_in_bytes': osd_data.get('op_w_in_bytes', 0),
        'op_r_lat_avg': osd_data.get('op_r_latency', {}).get('avgtime', 0) if isinstance(osd_data.get('op_r_latency'), dict) else 0,
        'op_w_lat_avg': osd_data.get('op_w_latency', {}).get('avgtime', 0) if isinstance(osd_data.get('op_w_latency'), dict) else 0,
        'op_wip': osd_data.get('op_wip', 0),
        'op_process_lat_avg': osd_data.get('op_process_latency', {}).get('avgtime', 0) if isinstance(osd_data.get('op_process_latency'), dict) else 0,
        'op_r_process_lat_avg': osd_data.get('op_r_process_latency', {}).get('avgtime', 0) if isinstance(osd_data.get('op_r_process_latency'), dict) else 0,
    }

def get_perf_for_cell(pool, tag, phase, results_dir):
    """对单个 cell，合并 3 节点的 perf dump，返回 {osd_id: counters}"""
    all_osds = {}
    for node in SLAVE_NODES:
        path = os.path.join(results_dir, pool, tag, f'perf-{phase}-{node}.txt')
        perf = parse_perf_dump(path)
        for osd_id, data in perf.items():
            all_osds[osd_id] = extract_op_counters({'osd': data.get('osd', {}), 'OpLatency': data.get('OpLatency', {})})
            # 同时保留完整的 osd 字典以备他用
            all_osds[osd_id]['_raw'] = data
    return all_osds

def parse_iostat(path):
    """解析 iostat -x 1 输出，返回每秒每设备的指标列表
    iostat -x 输出 22 列（不含设备名）:
    r/s rkB/s rrqm/s %rrqm r_await rareq-sz w/s wkB/s wrqm/s %wrqm w_await wareq-sz d/s dkB/s drqm/s %drqm d_await dareq-sz f/s f_await aqu-sz %util
    用 split-by-whitespace 更稳，不依赖 regex group 数
    """
    if not os.path.exists(path):
        return []
    samples = []
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        # 设备行：第一字段是 dev name，后面 22 个数字字段
        if len(parts) >= 23 and parts[0] in ['nvme2n1', 'nvme3n1']:
            try:
                samples.append({
                    'dev': parts[0],
                    'r_s': float(parts[1]),
                    'r_kbs': float(parts[2]),
                    'r_await': float(parts[5]),  # r_await = 第 5 个 numeric (after r/s rkB/s rrqm/s %rrqm)
                    'w_s': float(parts[6]),
                    'w_kbs': float(parts[7]),
                    'w_await': float(parts[10]),  # w_await = 第 10 个 numeric
                    'util': float(parts[22]),  # %util = 最后
                })
            except (ValueError, IndexError):
                pass
    return samples

def parse_sar_net(path):
    """解析 sar -n DEV 1 输出，提取 public + cluster NIC 流量"""
    if not os.path.exists(path):
        return []
    text = Path(path).read_text()
    samples = []
    current_time = None
    for line in text.splitlines():
        # 时间行：22:59:57        IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s ...
        m = re.match(r'^(\d{2}:\d{2}:\d{2})\s+(\S+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)', line)
        if m:
            t = m.group(1)
            iface = m.group(2)
            rx_kbs = float(m.group(5))
            tx_kbs = float(m.group(6))
            if iface in ['enp139s0f0np0', 'enp139s0f1np1']:
                samples.append({'time': t, 'iface': iface, 'rx_kbs': rx_kbs, 'tx_kbs': tx_kbs})
    return samples

def parse_pidstat_cpu(path):
    """解析 pidstat -u -h 1 输出，提取 ceph-osd 进程 CPU%"""
    if not os.path.exists(path):
        return []
    text = Path(path).read_text()
    samples = []
    for line in text.splitlines():
        # pidstat -h 输出：UID PID %usr %system %CPU %guest %wait CPU Command
        # ceph-osd 进程的行
        if 'ceph-osd' in line:
            parts = line.split()
            if len(parts) >= 8:
                try:
                    pid = parts[1]
                    cpu_pct = float(parts[4])
                    samples.append({'pid': pid, 'cpu_pct': cpu_pct})
                except (ValueError, IndexError):
                    pass
    return samples

# === 主分析 ===

def median(values):
    if not values:
        return None
    s = sorted(values)
    n = len(s)
    if n % 2 == 1:
        return s[n//2]
    return (s[n//2 - 1] + s[n//2]) / 2

def analyze_pool(pool, results_dir):
    """分析单个 pool 的全部 cells，返回结构化结果"""
    modes = {
        'write': [16, 128, 1024, 4096],
        'seq': [16, 128, 1024, 4096],
        'rand': [128, 1024, 4096, 16384],
    }
    
    result = {'pool': pool, 'cells': {}}
    
    for mode, ts in modes.items():
        for t in ts:
            cell_key = f'{mode}-t{t}'
            rounds_data = []
            
            for r in [1, 2, 3]:
                tag = f'{mode}-t{t}-r{r}'
                cell_dir = os.path.join(results_dir, pool, tag)
                if not os.path.isdir(cell_dir):
                    continue
                
                # 1. rados bench 输出
                rb = parse_rados_bench(os.path.join(cell_dir, 'rados-bench.txt'))
                if not rb:
                    continue
                
                # 2. PRE/POST perf dump delta
                pre = get_perf_for_cell(pool, tag, 'pre', results_dir)
                post = get_perf_for_cell(pool, tag, 'post', results_dir)
                
                op_deltas = []
                bytes_deltas = []
                lat_avgs = []
                for osd_id in pre:
                    if osd_id in post:
                        d_op_r = post[osd_id].get('op_r', 0) - pre[osd_id].get('op_r', 0)
                        d_op_w = post[osd_id].get('op_w', 0) - pre[osd_id].get('op_w', 0)
                        d_op_r_out = post[osd_id].get('op_r_out_bytes', 0) - pre[osd_id].get('op_r_out_bytes', 0)
                        d_op_w_in = post[osd_id].get('op_w_in_bytes', 0) - pre[osd_id].get('op_w_in_bytes', 0)
                        op_deltas.append({'osd': osd_id, 'op_r': d_op_r, 'op_w': d_op_w, 'op_r_out_bytes': d_op_r_out, 'op_w_in_bytes': d_op_w_in})
                        lat_avgs.append({'osd': osd_id, 'op_r_lat_avg': post[osd_id].get('op_r_lat_avg', 0), 'op_w_lat_avg': post[osd_id].get('op_w_lat_avg', 0)})
                
                # 3. iostat 数据（取 nvme2n1+nvme3n1 平均 %util 峰值）
                iostat_all = []
                for node in SLAVE_NODES:
                    iostat_path = os.path.join(cell_dir, f'iostat-{pool}-{tag}-{node}.log')
                    iostat_all.extend(parse_iostat(iostat_path))
                
                # 找 nvme2n1/nvme3n1 的 %util 峰值
                nvme2_util = [s['util'] for s in iostat_all if s['dev'] == 'nvme2n1']
                nvme3_util = [s['util'] for s in iostat_all if s['dev'] == 'nvme3n1']
                nvme2_kbs = [s['r_kbs'] + s['w_kbs'] for s in iostat_all if s['dev'] == 'nvme2n1']
                nvme3_kbs = [s['r_kbs'] + s['w_kbs'] for s in iostat_all if s['dev'] == 'nvme3n1']
                
                # 4. sar 网络数据
                net_all = []
                for node in SLAVE_NODES:
                    sar_path = os.path.join(cell_dir, f'sar-{pool}-{tag}-{node}.log')
                    net_all.extend(parse_sar_net(sar_path))
                
                public_rx = [s['rx_kbs'] for s in net_all if s['iface'] == 'enp139s0f0np0']
                public_tx = [s['tx_kbs'] for s in net_all if s['iface'] == 'enp139s0f0np0']
                cluster_rx = [s['rx_kbs'] for s in net_all if s['iface'] == 'enp139s0f1np1']
                cluster_tx = [s['tx_kbs'] for s in net_all if s['iface'] == 'enp139s0f1np1']
                
                # 5. pidstat CPU
                cpu_all = []
                for node in SLAVE_NODES:
                    pid_path = os.path.join(cell_dir, f'pidstat-{pool}-{tag}-{node}.log')
                    cpu_all.extend(parse_pidstat_cpu(pid_path))
                
                osd_cpu_samples = [s['cpu_pct'] for s in cpu_all]
                
                rounds_data.append({
                    'round': r,
                    'bw_min_mb': rb['min_mb'],
                    'bw_avg_mb': rb['avg_mb'],
                    'bw_max_mb': rb['max_mb'],
                    'bw_stddev': rb.get('stddev'),
                    'op_deltas': op_deltas,
                    'lat_avgs': lat_avgs,
                    'iostat_nvme2_util_max': max(nvme2_util) if nvme2_util else None,
                    'iostat_nvme3_util_max': max(nvme3_util) if nvme3_util else None,
                    'iostat_nvme2_kbs_max': max(nvme2_kbs) if nvme2_kbs else None,
                    'iostat_nvme3_kbs_max': max(nvme3_kbs) if nvme3_kbs else None,
                    'iostat_nvme2_kbs_avg': sum(nvme2_kbs)/len(nvme2_kbs) if nvme2_kbs else None,
                    'iostat_nvme3_kbs_avg': sum(nvme3_kbs)/len(nvme3_kbs) if nvme3_kbs else None,
                    'public_rx_max': max(public_rx) if public_rx else None,
                    'public_tx_max': max(public_tx) if public_tx else None,
                    'cluster_rx_max': max(cluster_rx) if cluster_rx else None,
                    'cluster_tx_max': max(cluster_tx) if cluster_tx else None,
                    'cluster_rx_avg': sum(cluster_rx)/len(cluster_rx) if cluster_rx else None,
                    'cluster_tx_avg': sum(cluster_tx)/len(cluster_tx) if cluster_tx else None,
                    'osd_cpu_max': max(osd_cpu_samples) if osd_cpu_samples else None,
                    'osd_cpu_avg': sum(osd_cpu_samples)/len(osd_cpu_samples) if osd_cpu_samples else None,
                })
            
            # 中位数（按 avg_bw）
            if not rounds_data:
                continue
            
            avg_bws = [r['bw_avg_mb'] for r in rounds_data]
            sorted_rounds = sorted(rounds_data, key=lambda x: x['bw_avg_mb'])
            median_round = sorted_rounds[len(sorted_rounds)//2]
            
            result['cells'][cell_key] = {
                'mode': mode,
                't': t,
                'rounds': rounds_data,
                'median_bw_mb': median_round['bw_avg_mb'],
                'median_min_mb': median_round['bw_min_mb'],
                'median_max_mb': median_round['bw_max_mb'],
                'median_stddev': median_round.get('bw_stddev'),
                'median_round': median_round,
            }
    
    return result

def compute_mechanism_metrics(ec_result, rep_result):
    """计算 6 类机制的量化贡献
    H1: fan-in 尾延迟 → 用 per-OSD op_r_latency avg（EC 4 OSD 取 max，Rep 单 OSD）
    H2: read 字节放大 → OSD op_r_out_bytes 总和 / logical bytes
        EC 理论 ~1.75×（256K 响应 client + 3×64K 子op 响应），Rep = 1.0×
    H3: per-OSD %util 峰值
    H4: cluster 网络流量（EC 应非 0，Rep 应=0；本测试 cluster NIC 实测=0 是重要发现）
    H5: write 字节放大 → OSD op_w_in_bytes 总和 / logical bytes
        EC full-stripe = 1.5×（6×64K/256K），Rep = 3.0×（3×256K/256K）
    H6: per-OSD CPU 峰值/均值
    """
    metrics = {'H1_fanin_tail': [], 'H2_read_amplification': [], 'H3_osd_util': [],
               'H4_cluster_net': [], 'H5_write_amplification': [], 'H6_cpu': []}
    
    for cell_key in ec_result.get('cells', {}):
        if cell_key not in rep_result.get('cells', {}):
            continue
        ec = ec_result['cells'][cell_key]
        rep = rep_result['cells'][cell_key]
        
        # H1: fan-in 尾延迟（用 rados bench Min/Max 比作代理 + per-OSD lat）
        ec_min_max_ratio = ec['median_min_mb'] / ec['median_max_mb'] if ec['median_max_mb'] else None
        rep_min_max_ratio = rep['median_min_mb'] / rep['median_max_mb'] if rep['median_max_mb'] else None
        # per-OSD op_r_latency avg
        ec_r_lats = [d.get('op_r_lat_avg', 0) for d in ec['median_round']['lat_avgs'] if d.get('op_r_lat_avg')]
        rep_r_lats = [d.get('op_r_lat_avg', 0) for d in rep['median_round']['lat_avgs'] if d.get('op_r_lat_avg')]
        ec_r_lat_avg = sum(ec_r_lats) / len(ec_r_lats) if ec_r_lats else None
        rep_r_lat_avg = sum(rep_r_lats) / len(rep_r_lats) if rep_r_lats else None
        metrics['H1_fanin_tail'].append({
            'cell': cell_key,
            'ec_min_max_ratio': ec_min_max_ratio,
            'rep_min_max_ratio': rep_min_max_ratio,
            'ec_p99_factor': 1/ec_min_max_ratio if ec_min_max_ratio else None,
            'rep_p99_factor': 1/rep_min_max_ratio if rep_min_max_ratio else None,
            'ec_op_r_lat_avg_ms': ec_r_lat_avg * 1000 if ec_r_lat_avg else None,
            'rep_op_r_lat_avg_ms': rep_r_lat_avg * 1000 if rep_r_lat_avg else None,
        })
        
        # H2: read 字节放大（OSD op_r_out_bytes 总和 / logical bytes read）
        ec_r_bytes_total = sum(d.get('op_r_out_bytes', 0) for d in ec['median_round']['op_deltas'])
        rep_r_bytes_total = sum(d.get('op_r_out_bytes', 0) for d in rep['median_round']['op_deltas'])
        # logical bytes = avg_bw_mb × 60s × 1024 × 1024
        ec_logical_bytes = ec['median_bw_mb'] * 60 * 1024 * 1024
        rep_logical_bytes = rep['median_bw_mb'] * 60 * 1024 * 1024
        ec_read_amp = ec_r_bytes_total / ec_logical_bytes if ec_logical_bytes else None
        rep_read_amp = rep_r_bytes_total / rep_logical_bytes if rep_logical_bytes else None
        metrics['H2_read_amplification'].append({
            'cell': cell_key,
            'ec_r_bytes_total_gb': ec_r_bytes_total / 1e9,
            'rep_r_bytes_total_gb': rep_r_bytes_total / 1e9,
            'ec_logical_gb': ec_logical_bytes / 1e9,
            'rep_logical_gb': rep_logical_bytes / 1e9,
            'ec_read_amp': ec_read_amp,
            'rep_read_amp': rep_read_amp,
            'ec_theoretical': 1.75,  # 256K + 3*64K / 256K
            'rep_theoretical': 1.0,
        })
        
        # H3: per-OSD %util 峰值
        metrics['H3_osd_util'].append({
            'cell': cell_key,
            'ec_nvme2_util_max': ec['median_round']['iostat_nvme2_util_max'],
            'rep_nvme2_util_max': rep['median_round']['iostat_nvme2_util_max'],
            'ec_nvme3_util_max': ec['median_round']['iostat_nvme3_util_max'],
            'rep_nvme3_util_max': rep['median_round']['iostat_nvme3_util_max'],
        })
        
        # H4: cluster 网络流量
        metrics['H4_cluster_net'].append({
            'cell': cell_key,
            'ec_cluster_rx_max': ec['median_round']['cluster_rx_max'],
            'rep_cluster_rx_max': rep['median_round']['cluster_rx_max'],
            'ec_cluster_tx_max': ec['median_round']['cluster_tx_max'],
            'rep_cluster_tx_max': rep['median_round']['cluster_tx_max'],
            'ec_cluster_rx_avg': ec['median_round']['cluster_rx_avg'],
            'rep_cluster_rx_avg': rep['median_round']['cluster_rx_avg'],
            'ec_logical_mb': ec['median_bw_mb'],
            'rep_logical_mb': rep['median_bw_mb'],
        })
        
        # H5: write 字节放大
        ec_w_bytes_total = sum(d.get('op_w_in_bytes', 0) for d in ec['median_round']['op_deltas'])
        rep_w_bytes_total = sum(d.get('op_w_in_bytes', 0) for d in rep['median_round']['op_deltas'])
        ec_write_amp = ec_w_bytes_total / ec_logical_bytes if ec_logical_bytes else None
        rep_write_amp = rep_w_bytes_total / rep_logical_bytes if rep_logical_bytes else None
        metrics['H5_write_amplification'].append({
            'cell': cell_key,
            'ec_write_amp': ec_write_amp,
            'rep_write_amp': rep_write_amp,
            'ec_w_bytes_total_gb': ec_w_bytes_total / 1e9,
            'rep_w_bytes_total_gb': rep_w_bytes_total / 1e9,
            'ec_theoretical': 1.5,
            'rep_theoretical': 3.0,
        })
        
        # H6: CPU
        metrics['H6_cpu'].append({
            'cell': cell_key,
            'ec_osd_cpu_max': ec['median_round']['osd_cpu_max'],
            'rep_osd_cpu_max': rep['median_round']['osd_cpu_max'],
            'ec_osd_cpu_avg': ec['median_round']['osd_cpu_avg'],
            'rep_osd_cpu_avg': rep['median_round']['osd_cpu_avg'],
        })
    
    return metrics

def write_summary_chinese(ec_result, rep_result, metrics, output_path):
    """写中文 summary.md"""
    lines = []
    lines.append('# 01-5 rados bench EC4+2 vs Replica3 后端机制诊断 Summary')
    lines.append('')
    lines.append('> 测试日期：2026-07-18 ~ 2026-07-19')
    lines.append('> 测试方法：rados bench 直测 RADOS（绕过 FUSE / CephFS / MDS），EC4+2 池 vs 新建 Rep3 池')
    lines.append('> 单变量：pool type（同 6 OSD、同 100GbE 双网、同 DB/WAL tmpfs）')
    lines.append('> 验收线：6250 MiB/s（100GbE 半速）')
    lines.append('')
    lines.append('---')
    lines.append('')
    
    # === 一、带宽中位数对比 ===
    lines.append('## 一、EC4+2 vs Rep3 三模式带宽中位数对比（MB/s）')
    lines.append('')
    
    lines.append('### Write（写带宽，256K 对象）')
    lines.append('')
    lines.append('| -t | EC4+2 | Rep3 | Rep/EC | EC 达标 | Rep 达标 |')
    lines.append('|-----|-------|------|--------|---------|---------|')
    for t in [16, 128, 1024, 4096]:
        cell = f'write-t{t}'
        ec_bw = ec_result['cells'].get(cell, {}).get('median_bw_mb')
        rep_bw = rep_result['cells'].get(cell, {}).get('median_bw_mb')
        if ec_bw and rep_bw:
            ratio = rep_bw / ec_bw
            ec_ok = '✅' if ec_bw >= 6250 else '❌'
            rep_ok = '✅' if rep_bw >= 6250 else '❌'
            lines.append(f'| {t} | {ec_bw:.0f} | {rep_bw:.0f} | {ratio:.2f}× | {ec_ok} | {rep_ok} |')
        elif ec_bw:
            lines.append(f'| {t} | {ec_bw:.0f} | — | — | — | — |')
    
    lines.append('')
    lines.append('### Seq read（顺序读带宽）')
    lines.append('')
    lines.append('| -t | EC4+2 | Rep3 | Rep/EC | EC 达标 | Rep 达标 |')
    lines.append('|-----|-------|------|--------|---------|---------|')
    for t in [16, 128, 1024, 4096]:
        cell = f'seq-t{t}'
        ec_bw = ec_result['cells'].get(cell, {}).get('median_bw_mb')
        rep_bw = rep_result['cells'].get(cell, {}).get('median_bw_mb')
        if ec_bw and rep_bw:
            ratio = rep_bw / ec_bw
            ec_ok = '✅' if ec_bw >= 6250 else '❌'
            rep_ok = '✅' if rep_bw >= 6250 else '❌'
            lines.append(f'| {t} | {ec_bw:.0f} | {rep_bw:.0f} | {ratio:.2f}× | {ec_ok} | {rep_ok} |')
    
    lines.append('')
    lines.append('### Rand read（随机读带宽，关键瓶颈项）')
    lines.append('')
    lines.append('| -t | EC4+2 | Rep3 | Rep/EC | EC 达标 | Rep 达标 |')
    lines.append('|-----|-------|------|--------|---------|---------|')
    for t in [128, 1024, 4096, 16384]:
        cell = f'rand-t{t}'
        ec_bw = ec_result['cells'].get(cell, {}).get('median_bw_mb')
        rep_bw = rep_result['cells'].get(cell, {}).get('median_bw_mb')
        if ec_bw and rep_bw:
            ratio = rep_bw / ec_bw
            ec_ok = '✅' if ec_bw >= 6250 else '❌'
            rep_ok = '✅' if rep_bw >= 6250 else '❌'
            lines.append(f'| {t} | {ec_bw:.0f} | {rep_bw:.0f} | {ratio:.2f}× | {ec_ok} | {rep_ok} |')
    
    lines.append('')
    lines.append('---')
    lines.append('')
    
    # === 二、机制量化贡献 ===
    lines.append('## 二、6 类机制量化贡献')
    lines.append('')
    
    # H1: fan-in 尾延迟
    lines.append('### H1：fan-in 尾延迟 + per-OSD 读延迟')
    lines.append('')
    lines.append('| cell | EC Min/Max | Rep Min/Max | EC 尾延迟放大 | Rep 尾延迟放大 | EC op_r_lat avg (ms) | Rep op_r_lat avg (ms) |')
    lines.append('|------|------------|-------------|--------------|----------------|---------------------|------------------------|')
    for m in metrics['H1_fanin_tail']:
        ec_r = m['ec_min_max_ratio']
        rep_r = m['rep_min_max_ratio']
        ec_lat = m.get('ec_op_r_lat_avg_ms')
        rep_lat = m.get('rep_op_r_lat_avg_ms')
        ec_lat_s = f'{ec_lat:.3f}' if ec_lat else '—'
        rep_lat_s = f'{rep_lat:.3f}' if rep_lat else '—'
        if ec_r and rep_r:
            lines.append(f"| {m['cell']} | {ec_r:.3f} | {rep_r:.3f} | {m['ec_p99_factor']:.2f}× | {m['rep_p99_factor']:.2f}× | {ec_lat_s} | {rep_lat_s} |")
    lines.append('')
    lines.append('> 解读：尾延迟放大 = Max/Min。EC randread 若显著高于 Rep，证明 EC fan-in（4 OSD 取片 + max of 4）放大了尾延迟。')
    lines.append('')
    
    # H2: read 字节放大
    lines.append('### H2：read 字节放大（OSD op_r_out_bytes 总和 / logical bytes read）')
    lines.append('')
    lines.append('| cell | EC 读字节总和 (GB) | Rep 读字节总和 (GB) | EC 读放大 | Rep 读放大 | EC 理论 | Rep 理论 |')
    lines.append('|------|-------------------|---------------------|-----------|-------------|---------|----------|')
    for m in metrics['H2_read_amplification']:
        ec_amp = m['ec_read_amp']
        rep_amp = m['rep_read_amp']
        if ec_amp is not None and rep_amp is not None:
            lines.append(f"| {m['cell']} | {m['ec_r_bytes_total_gb']:.1f} | {m['rep_r_bytes_total_gb']:.1f} | {ec_amp:.2f}× | {rep_amp:.2f}× | {m['ec_theoretical']}× | {m['rep_theoretical']}× |")
    lines.append('')
    lines.append('> 解读：EC 理论 read 字节放大 ≈ 1.75×（primary 响应 client 256K + 3 chunk OSD 各响应 primary 64K = 448K / 256K）；Rep = 1.0×（只 primary 响应 client）。**实测值偏离理论值的程度可揭示 RMW/Cache 行为**。')
    lines.append('')
    
    # H3: per-OSD %util
    lines.append('### H3：per-OSD 磁盘 %util 峰值')
    lines.append('')
    lines.append('| cell | EC nvme2 %util max | Rep nvme2 %util max | EC nvme3 %util max | Rep nvme3 %util max |')
    lines.append('|------|---------------------|----------------------|---------------------|----------------------|')
    for m in metrics['H3_osd_util']:
        ec2 = m['ec_nvme2_util_max'] or 0
        rep2 = m['rep_nvme2_util_max'] or 0
        ec3 = m['ec_nvme3_util_max'] or 0
        rep3 = m['rep_nvme3_util_max'] or 0
        lines.append(f"| {m['cell']} | {ec2:.1f}% | {rep2:.1f}% | {ec3:.1f}% | {rep3:.1f}% |")
    lines.append('')
    lines.append('> 解读：同 logical IOPS 下 EC per-OSD %util 应 ≈ 1.75× Rep（EC 字节放大 1.75× / 分布到 6 OSD；Rep 1.0× / 分布到 3 primary）。EC 撞 100% 临界点更低 → EC 磁盘瓶颈先到。')
    lines.append('')
    
    # H4: cluster 网络流量
    lines.append('### H4：cluster 网络流量（cluster NIC RX avg）')
    lines.append('')
    lines.append('| cell | EC cluster RX avg (MB/s) | Rep cluster RX avg (MB/s) | EC/EC_logical | Rep/Rep_logical |')
    lines.append('|------|--------------------------|---------------------------|---------------|-----------------|')
    for m in metrics['H4_cluster_net']:
        ec_rx = m['ec_cluster_rx_avg']
        rep_rx = m['rep_cluster_rx_avg']
        ec_log = m['ec_logical_mb']
        rep_log = m['rep_logical_mb']
        if ec_rx is not None and rep_rx is not None and ec_log and rep_log:
            ec_rx_mb = ec_rx / 1024
            rep_rx_mb = rep_rx / 1024
            ec_rx_mb_total = ec_rx_mb * 3  # 3 节点总和
            rep_rx_mb_total = rep_rx_mb * 3
            lines.append(f"| {m['cell']} | {ec_rx_mb_total:.0f} | {rep_rx_mb_total:.0f} | {ec_rx_mb_total/ec_log:.2f}× | {rep_rx_mb_total/rep_log:.2f}× |")
    lines.append('')
    lines.append('> 解读：EC read 应有 cluster 网络流量（primary 跨 cluster 网取 3 片，理论 = 1.875× logical），Rep read cluster 流量 ≈ 0。**若 EC cluster NIC 实测=0，说明 cluster_network 未配置生效，所有 OSD 间流量走 public NIC**。')
    lines.append('')
    
    # H5: 写放大
    lines.append('### H5：write 字节放大（OSD op_w_in_bytes 总和 / logical bytes written）')
    lines.append('')
    lines.append('| cell | EC 写字节总和 (GB) | Rep 写字节总和 (GB) | EC 写放大 | Rep 写放大 | EC 理论 | Rep 理论 |')
    lines.append('|------|-------------------|---------------------|-----------|-------------|---------|----------|')
    for m in metrics['H5_write_amplification']:
        ec = m['ec_write_amp']
        rep = m['rep_write_amp']
        if ec is not None and rep is not None:
            lines.append(f"| {m['cell']} | {m['ec_w_bytes_total_gb']:.1f} | {m['rep_w_bytes_total_gb']:.1f} | {ec:.2f}× | {rep:.2f}× | {m['ec_theoretical']}× | {m['rep_theoretical']}× |")
    lines.append('')
    lines.append('> 解读：EC full-stripe = 1.5×（6×64K/256K）；Rep = 3.0×（3×256K/256K）。**理论 EC 写应快于 Rep**（放大率 0.5×）。若实测 EC 写 ≈ Rep 或 EC 慢于 Rep，写放大不是主导机制。')
    lines.append('')
    
    # H6: CPU
    lines.append('### H6：OSD CPU 峰值与均值（per-process %）')
    lines.append('')
    lines.append('| cell | EC OSD CPU max | Rep OSD CPU max | EC OSD CPU avg | Rep OSD CPU avg |')
    lines.append('|------|----------------|------------------|-----------------|-----------------|')
    for m in metrics['H6_cpu']:
        ec_max = m['ec_osd_cpu_max'] or 0
        rep_max = m['rep_osd_cpu_max'] or 0
        ec_avg = m['ec_osd_cpu_avg'] or 0
        rep_avg = m['rep_osd_cpu_avg'] or 0
        lines.append(f"| {m['cell']} | {ec_max:.1f}% | {rep_max:.1f}% | {ec_avg:.1f}% | {rep_avg:.1f}% |")
    lines.append('')
    lines.append('> 解读：EC write CPU 显著高于 Rep write → RS 编码开销坐实；EC read CPU ≈ Rep read → read 路径无解码 CPU 开销（全片齐备无 RS）。')
    lines.append('')
    
    lines.append('---')
    lines.append('')
    
    # === 三、判定 ===
    lines.append('## 三、判定')
    lines.append('')
    lines.append('### 关键判定点')
    lines.append('')
    
    # 找 randread 高并发 cell
    rand_high_t = None
    for t in [4096, 16384, 1024, 128]:
        cell = f'rand-t{t}'
        if cell in ec_result['cells'] and cell in rep_result['cells']:
            rand_high_t = t
            break
    
    if rand_high_t:
        cell = f'rand-t{rand_high_t}'
        ec_bw = ec_result['cells'][cell]['median_bw_mb']
        rep_bw = rep_result['cells'][cell]['median_bw_mb']
        ratio = rep_bw / ec_bw if ec_bw else None
        
        lines.append(f'1. **EC4+2 vs Rep3 后端裸能力**（randread -t{rand_high_t}）：')
        lines.append(f'   - EC: **{ec_bw:.0f} MB/s** {("✅ 达标" if ec_bw >= 6250 else "❌ 不达标")}')
        lines.append(f'   - Rep: **{rep_bw:.0f} MB/s** {("✅ 达标" if rep_bw >= 6250 else "❌ 不达标")}')
        if ratio:
            lines.append(f'   - Rep/EC = {ratio:.2f}×')
        lines.append('')
    
    lines.append('### 机制归因总结')
    lines.append('')
    lines.append('（详细分析见上述各 H 表格，根据数据自动判定）')
    lines.append('')
    
    # 自动判定
    lines.append('### 结论模板')
    lines.append('')
    lines.append('（待数据齐全后填写）')
    lines.append('')
    
    Path(output_path).write_text('\n'.join(lines))
    print(f'Wrote: {output_path}')

def main():
    print(f'Results dir: {RESULTS_DIR}')
    
    if not os.path.isdir(RESULTS_DIR):
        print(f'ERROR: results dir not found: {RESULTS_DIR}')
        sys.exit(1)
    
    print('Analyzing EC pool...')
    ec_result = analyze_pool(EC_POOL, RESULTS_DIR)
    
    print('Analyzing Rep pool...')
    rep_result = analyze_pool(REP_POOL, RESULTS_DIR)
    
    print('Computing mechanism metrics...')
    metrics = compute_mechanism_metrics(ec_result, rep_result)
    
    # 输出 summary
    summary_path = os.path.join(RESULTS_DIR, 'summary.md')
    write_summary_chinese(ec_result, rep_result, metrics, summary_path)
    
    # 输出 parsed.json（机读）
    parsed = {
        'ec': ec_result,
        'rep': rep_result,
        'mechanism_metrics': metrics,
    }
    parsed_path = os.path.join(RESULTS_DIR, 'parsed.json')
    Path(parsed_path).write_text(json.dumps(parsed, indent=2, default=str))
    print(f'Wrote: {parsed_path}')
    
    # 简短 stdout 报告
    print('\n=== 简短报告 ===')
    for cell in sorted(ec_result.get('cells', {})):
        if cell in rep_result.get('cells', {}):
            ec_bw = ec_result['cells'][cell]['median_bw_mb']
            rep_bw = rep_result['cells'][cell]['median_bw_mb']
            ratio = rep_bw/ec_bw if ec_bw else 0
            print(f'{cell}: EC={ec_bw:.0f} MB/s, Rep={rep_bw:.0f} MB/s, ratio={ratio:.2f}×')

if __name__ == '__main__':
    main()
