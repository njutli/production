#!/usr/bin/env python3
"""05-3b: completion-byte accounting, not integration of per-IO rates.

fio 3.28 log_avg_msec=0 BW rows have completion-relative milliseconds,
instantaneous rate, direction, completed bytes. Only columns 1/3/4 are used.
Reads require exact JSON byte/IO reconciliation.  For asynchronous writes only,
a bounded final-drain delta is allowed after every job log has crossed 180 s,
five seconds beyond the [15,175) formal window.  Real per-job stalls remain
measured phenomena; the bounded missing-byte fraction limits their ambiguity.
Old averaged logs are deliberately rejected: absent samples are not zeros.
"""
import argparse
import csv
import importlib.util
import json
import math
from pathlib import Path
import statistics
import tempfile

_spec = importlib.util.spec_from_file_location('old053', Path(__file__).with_name('t05-3-randrw-analyze.py'))
_old = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_old)
EvidenceError = _old.EvidenceError


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise EvidenceError(f'{path.name}: {exc}') from exc


def analyze_cell(cell, direction):
    contract = read_json(cell / 'logging-contract.json')
    if contract.get('mode') != 'per_io_completion' or contract.get('log_avg_msec') != 0:
        raise EvidenceError('averaged logs cannot establish completion coverage')
    jobs_n = int(contract['numjobs'])
    bs = int(contract['bs_bytes'])
    formal_window = contract.get('formal_window_s', [15, 175])
    tail_guard = float(contract.get('write_tail_guard_s', 5))
    tail_max_per_job = int(contract.get('write_tail_max_per_job', 8))
    declared_tail_fraction = float(contract.get('write_tail_max_fraction', 0.002))
    tail_max_fraction = min(declared_tail_fraction, 0.002)
    if jobs_n not in (1, 16, 128) or bs <= 0:
        raise EvidenceError('invalid logging contract')
    if (formal_window != [15, 175] or tail_guard != 5 or tail_max_per_job not in (4, 8)
            or declared_tail_fraction not in (0.002, 0.001, 0.0001)):
        raise EvidenceError('unexpected formal/write-tail contract')
    if (cell / 'fio.rc').read_text().strip() != '0':
        raise EvidenceError('fio nonzero rc')
    data = read_json(cell / 'fio.json')
    jobs = data.get('jobs')
    if not isinstance(jobs, list) or len(jobs) not in (1, jobs_n):
        raise EvidenceError('invalid grouped/per-job JSON')
    side = 'read' if direction == 'randread' else 'write'
    dd = 0 if direction == 'randread' else 1
    for j in jobs:
        opts = dict(data.get('global options', {}), **j.get('job options', {}))
        if int(j.get('error', -1)) or int(opts.get('log_avg_msec', -1)) != 0:
            raise EvidenceError('fio error or actual log mode differs')
        if int(j[side].get('short_ios', 0)) or int(j[side].get('drop_ios', 0)):
            raise EvidenceError('short/drop IO requires review')
        if int(j.get('write' if side == 'read' else 'read', {}).get('io_bytes', 0)):
            raise EvidenceError('unexpected opposite direction IO')
    runtime = max(float(j[side]['runtime']) / 1000 for j in jobs)
    if not math.isfinite(runtime) or runtime < 175 or runtime > 3600:
        raise EvidenceError('runtime cannot cover formal window')
    total = sum(int(j[side]['io_bytes']) for j in jobs)
    ios = sum(int(j[side]['total_ios']) for j in jobs)
    if total <= 0 or ios <= 0:
        raise EvidenceError('empty JSON IO counters')
    paths = sorted((cell / 'bw').glob('*_bw.*.log'))
    if len(paths) != jobs_n:
        raise EvidenceError(f'expected {jobs_n} BW logs, got {len(paths)}')
    ids = sorted(int(p.name.rsplit('.', 2)[1]) for p in paths)
    if ids != list(range(1, jobs_n + 1)):
        raise EvidenceError('duplicate/missing job IDs')
    series = {s: 0.0 for s in range(math.ceil(runtime) + 1)}
    count = byte_sum = 0
    bounds = []
    for path in paths:
        prev = -1.0
        first = last = None
        max_gap = 0.0
        job_ios = job_bytes = 0
        with path.open(newline='') as stream:
            for row in csv.reader(stream):
                if not row:
                    continue
                if len(row) < 4:
                    raise EvidenceError('short completion row')
                timestamp = float(row[0]) / 1000.0
                actual_bytes = int(row[3])
                if (not math.isfinite(timestamp) or timestamp < prev or timestamp < 0
                        or timestamp > runtime + 0.1 or int(row[2]) != dd
                        or actual_bytes != bs):
                    raise EvidenceError('invalid completion timestamp/direction/bytes')
                if first is None:
                    first = timestamp
                if prev >= 0:
                    max_gap = max(max_gap, timestamp - prev)
                last = prev = timestamp
                second = math.floor(timestamp)
                series[second] += actual_bytes / 1048576
                count += 1
                byte_sum += actual_bytes
                job_ios += 1
                job_bytes += actual_bytes
        if len(jobs) == jobs_n:
            j = jobs[int(path.name.rsplit('.', 2)[1]) - 1][side]
            if job_bytes != int(j['io_bytes']) or job_ios != int(j['total_ios']):
                raise EvidenceError('per-job completion/JSON mismatch')
        bounds.append({'job': int(path.name.rsplit('.', 2)[1]), 'first_completion_s': first,
                       'last_completion_s': last, 'max_completion_gap_s': max_gap,
                       'io_count': job_ios, 'io_bytes': job_bytes})
    exact = count == ios and byte_sum == total
    missing_ios = ios - count
    missing_bytes = total - byte_sum
    formal_uncertainty = missing_bytes / (formal_window[1] - formal_window[0]) / 1048576
    short_window_uncertainty = missing_bytes / 40 / 1048576
    bounded_write_tail = (
        direction == 'randwrite' and len(jobs) == 1 and 0 < missing_ios <= jobs_n * tail_max_per_job
        and missing_ios / ios <= tail_max_fraction and missing_bytes == missing_ios * bs
        and formal_uncertainty <= 2 and short_window_uncertainty <= 8
        and all(b['first_completion_s'] is not None and b['first_completion_s'] <= 15
                and b['last_completion_s'] is not None and b['last_completion_s'] >= formal_window[1]
                for b in bounds)
    )
    if not exact and not bounded_write_tail:
        raise EvidenceError(f'incomplete completion logs: bytes {byte_sum}/{total}; IOs {count}/{ios}')
    # Exact reconciliation, or the bounded write-drain contract above, makes
    # empty bins inside [15,175) verified zero-completion seconds.
    formal = _old.stats(series)
    formal.update(window_status='MEASURED', bwlog_integral_over_fio_bytes=byte_sum / total,
                  completion_accounting=('exact byte and IO count reconciliation' if exact else
                  'bounded asynchronous write final-drain delta outside formal window'),
                  completion_missing_ios=missing_ios, completion_missing_bytes=missing_bytes,
                  formal_mean_uncertainty_MiB_s_max=formal_uncertainty,
                  forty_second_window_uncertainty_MiB_s_max=short_window_uncertainty,
                  accounting='sum completed bytes in each half-open 1s bin; per-job relative epochs')
    lat = [j[side].get('clat_ns', {}) for j in jobs]
    n = sum(int(x.get('N', 0)) for x in lat)
    quantiles = lat[0].get('percentile', {}) if len(lat) == 1 else {}
    result = {'schema': 1, 'direction': direction, 'cell': cell.name, 'runtime_s': runtime,
              'formal': formal, 'fio_summary': {'io_bytes': total, 'total_ios': ios,
              'summary_MiB_s': total / runtime / 1048576,
              'iops': sum(float(j[side].get('iops', 0)) for j in jobs),
              'clat_mean_ns': sum(float(x.get('mean', 0)) * int(x.get('N', 0)) for x in lat) / n if n else None,
              'clat_p95_ns': quantiles.get('95.000000'), 'clat_p99_ns': quantiles.get('99.000000')},
              'actual_io_start_epoch_ns': None,
              'absolute_alignment': 'UNKNOWN: shell return minus runtime is not a job start',
              'per_job_completion_bounds': bounds,
              'evidence_status': 'SAMPLING_VALID_PENDING_IDENTITY_HEALTH_REVIEW'}
    # A real zero-completion W1/whole window has undefined CV/ratio, not inf.
    def finite_json(x):
        if isinstance(x, dict):
            return {k: finite_json(v) for k, v in x.items()}
        if isinstance(x, list):
            return [finite_json(v) for v in x]
        return None if isinstance(x, float) and not math.isfinite(x) else x
    return finite_json(result)


def self_test():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        for numjobs in (1, 16, 128):
            cell = root / str(numjobs)
            (cell / 'bw').mkdir(parents=True)
            contract = dict(mode='per_io_completion', log_avg_msec=0, numjobs=numjobs, bs_bytes=1048576)
            (cell / 'logging-contract.json').write_text(json.dumps(contract))
            (cell / 'fio.rc').write_text('0')
            for i in range(1, numjobs + 1):
                (cell / 'bw' / f't_bw.{i}.log').write_text(''.join(f'{s*1000+250},777,0,1048576\n' for s in range(180)))
            j = {'error': 0, 'job options': {'log_avg_msec': '0'},
                 'read': {'runtime': 180000, 'io_bytes': numjobs*180*1048576, 'total_ios': numjobs*180}}
            (cell / 'fio.json').write_text(json.dumps({'jobs': [j]}))
            result = analyze_cell(cell, 'randread')
            assert result['formal']['mean_MiB_s'] == numjobs
            assert result['formal']['W4_W1'] == 1
            assert result['actual_io_start_epoch_ns'] is None
            # Grouped and per-job JSON must yield the same series.
            one = dict(j, read=dict(runtime=180000, io_bytes=180*1048576, total_ios=180))
            (cell / 'fio.json').write_text(json.dumps({'jobs': [one for _ in range(numjobs)]}))
            assert analyze_cell(cell, 'randread')['formal'] == result['formal']
            (cell / 'fio.json').write_text(json.dumps({'jobs': [j]}))
            p = cell / 'bw' / 't_bw.1.log'
            healthy = p.read_text()
            p.write_text('\n'.join(healthy.splitlines()[24:])+'\n')
            try:
                analyze_cell(cell, 'randread')
                raise AssertionError('late first/missing events accepted')
            except EvidenceError:
                pass
            p.write_text('\n'.join(x for k, x in enumerate(healthy.splitlines()) if not 70 <= k < 100)+'\n')
            try:
                analyze_cell(cell, 'randread')
                raise AssertionError('long lost interval accepted')
            except EvidenceError:
                pass
            p.write_text(healthy)
            # Post-IO shell/fsync tail cannot shift relative formal windows.
            (cell / 'fio-end-epoch-ns.txt').write_text('9999999999999999')
            assert analyze_cell(cell, 'randread')['formal'] == result['formal']
            contract['log_avg_msec'] = 1000
            (cell / 'logging-contract.json').write_text(json.dumps(contract))
            try:
                analyze_cell(cell, 'randread')
                raise AssertionError('averaged log accepted as completion log')
            except EvidenceError:
                pass
        # fio can include a small set of writes drained after its BW logger has
        # crossed 180 s.  This is acceptable only beyond the formal window and
        # within a small aggregate bound; the same delta on reads is rejected.
        tail = root / 'write-tail'
        (tail / 'bw').mkdir(parents=True)
        jobs_n = 128
        contract = dict(mode='per_io_completion', log_avg_msec=0, numjobs=jobs_n, bs_bytes=262144)
        (tail / 'logging-contract.json').write_text(json.dumps(contract))
        (tail / 'fio.rc').write_text('0')
        logged = 0
        for i in range(1, jobs_n + 1):
            rows = [f'{s*1000+250},777,1,262144\n' for s in range(181)]
            (tail / 'bw' / f't_bw.{i}.log').write_text(''.join(rows))
            logged += len(rows)
        total_ios = logged + 2
        job = {'error': 0, 'job options': {'log_avg_msec': '0'},
               'read': {'runtime': 180500, 'io_bytes': 0, 'total_ios': 0},
               'write': {'runtime': 180500, 'io_bytes': total_ios*262144, 'total_ios': total_ios}}
        (tail / 'fio.json').write_text(json.dumps({'jobs': [job]}))
        result = analyze_cell(tail, 'randwrite')
        assert result['formal']['completion_missing_ios'] == 2
        assert result['formal']['window_status'] == 'MEASURED'
        try:
            analyze_cell(tail, 'randread')
            raise AssertionError('read tail mismatch accepted')
        except EvidenceError:
            pass
    print('T053B_ANALYZER_SELF_TEST_PASS 1/16/128 grouped/perjob late/gap/tail/mode')


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='command', required=True)
    sub.add_parser('self-test')
    p = sub.add_parser('cell')
    p.add_argument('--cell', type=Path, required=True)
    p.add_argument('--direction', choices=['randread', 'randwrite'], required=True)
    p.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    if args.command == 'self-test':
        self_test()
        return
    try:
        result = analyze_cell(args.cell, args.direction)
    except (EvidenceError, OSError, KeyError, ValueError, TypeError) as exc:
        result = {'evidence_status': 'EVIDENCE_INVALID', 'formal': {'window_status': 'UNKNOWN/REVIEW'}, 'reason': str(exc)}
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False)+'\n')
    if result['formal']['window_status'] != 'MEASURED':
        raise SystemExit(42)
    print(f'T053B_CELL_SAMPLING_PASS {args.cell.name}')


if __name__ == '__main__':
    main()
