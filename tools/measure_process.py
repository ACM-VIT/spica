#!/usr/bin/env python3
"""External Linux process-baseline sampler; never runs inside the application."""
import argparse
import json
import os
from pathlib import Path
import platform
import time


def fields(path):
    result = {}
    for line in path.read_text().splitlines():
        key, separator, value = line.partition(':')
        if separator:
            result[key] = value.strip()
    return result


def sample(pid):
    root = Path('/proc') / str(pid)
    memory = fields(root / 'smaps_rollup')
    status = fields(root / 'status')
    # comm may contain spaces or parentheses; fields after its final ')' begin
    # with state (field3), so utime/stime are indexes11/12 in this tail.
    stat = (root / 'stat').read_text().rsplit(')', 1)[1].split()
    return {
        'monotonic_seconds': time.monotonic(),
        'rss_bytes': int(memory['Rss'].split()[0]) * 1024,
        'anonymous_bytes': int(memory['Anonymous'].split()[0]) * 1024,
        'pss_bytes': int(memory['Pss'].split()[0]) * 1024,
        'cpu_ticks': int(stat[11]) + int(stat[12]),
        'voluntary_context_switches': int(status['voluntary_ctxt_switches']),
        'involuntary_context_switches': int(status['nonvoluntary_ctxt_switches']),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--label', required=True)
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--settle', type=int, default=10)
    args = parser.parse_args()
    if args.seconds < 1 or args.settle < 0:
        parser.error('seconds must be positive; settle cannot be negative')
    time.sleep(args.settle)
    samples = [sample(args.pid)]
    deadline = samples[0]['monotonic_seconds'] + args.seconds
    while time.monotonic() < deadline:
        time.sleep(min(1, max(0, deadline - time.monotonic())))
        samples.append(sample(args.pid))
    first, last = samples[0], samples[-1]
    elapsed = last['monotonic_seconds'] - first['monotonic_seconds']
    report = {
        'scenario': args.label,
        'pid': args.pid,
        'os': platform.platform(),
        'architecture': platform.machine(),
        'measurement': 'Linux smaps_rollup Rss: whole-process resident pages, including shared libraries and CPU driver memory',
        'elapsed_seconds': elapsed,
        'maximum_rss_bytes': max(row['rss_bytes'] for row in samples),
        'maximum_rss_mib': max(row['rss_bytes'] for row in samples) / (1024 * 1024),
        'cpu_percent_of_one_core': (last['cpu_ticks'] - first['cpu_ticks']) / os.sysconf('SC_CLK_TCK') / elapsed * 100,
        'voluntary_context_switches': last['voluntary_context_switches'] - first['voluntary_context_switches'],
        'involuntary_context_switches': last['involuntary_context_switches'] - first['involuntary_context_switches'],
        'gpu_memory': 'Not measured: do not interpret process RSS as GPU allocation accounting',
        'acceptance': 'Baseline only; not the full warm-idle/history-stress fixture or a cross-platform pass',
        'samples': samples,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'samples'}, indent=2))


if __name__ == '__main__':
    main()
