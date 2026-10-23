#!/usr/bin/env python3
"""Finite external Linux process-tree sampling; raw incomplete reads stay explicit."""
import argparse
import json
import math
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


def stat(path):
    text = path.read_text()
    pid = int(text.split(' ', 1)[0])
    tail = text.rsplit(')', 1)[1].split()
    return dict(pid=pid, ppid=int(tail[1]), starttime_ticks=int(tail[19]),
                cpu_ticks=int(tail[11]) + int(tail[12]))


def identity(row):
    return row['pid'], row['starttime_ticks']


def sample(pid, proc=Path('/proc'), expected_root=None):
    begin = time.monotonic()
    errors, table = [], {}
    for directory in proc.iterdir():
        if not directory.name.isdigit():
            continue
        try:
            row = stat(directory / 'stat')
            table[row['pid']] = row
        except (OSError, ValueError, IndexError) as error:
            errors.append(dict(pid=int(directory.name), stage='enumeration', error=str(error)))
    root = table.get(pid)
    if root is None or (expected_root is not None and identity(root) != expected_root):
        return dict(monotonic_seconds=begin, duration_seconds=time.monotonic() - begin,
                    root_exited=True, complete=False, members=[], errors=errors + [dict(pid=pid, stage='root', error='missing or reused root')],
                    rss_bytes=None, pss_bytes=None)
    selected = {pid}
    while True:
        children = {p for p, row in table.items() if row['ppid'] in selected}
        if children <= selected:
            break
        selected |= children
    members = []
    for member_pid in sorted(selected):
        original = table[member_pid]
        member = dict(original, errors=[])
        directory = proc / str(member_pid)
        try:
            before = stat(directory / 'stat')
            if identity(before) != identity(original):
                raise ValueError('PID identity changed before memory read')
            memory = fields(directory / 'smaps_rollup')
            member.update({key: int(memory[field].split()[0]) * 1024 for key, field in
                           [('rss_bytes', 'Rss'), ('pss_bytes', 'Pss'), ('anonymous_bytes', 'Anonymous')]})
            status = fields(directory / 'status')
            member.update(voluntary_context_switches=int(status['voluntary_ctxt_switches']),
                          involuntary_context_switches=int(status['nonvoluntary_ctxt_switches']))
            after = stat(directory / 'stat')
            if identity(after) != identity(original):
                raise ValueError('PID identity changed around memory read')
            member['cpu_ticks'] = after['cpu_ticks']
        except (OSError, ValueError, IndexError, KeyError) as error:
            member['errors'].append(str(error))
            # Never retain apparently valid memory from an inconsistent instance.
            for key in ('rss_bytes', 'pss_bytes', 'anonymous_bytes'):
                member.pop(key, None)
        parent = table.get(original['ppid'])
        member['parent_identity'] = list(identity(parent)) if parent else None
        members.append(member)
    complete = not errors and all(not member['errors'] for member in members)
    return dict(monotonic_seconds=begin, duration_seconds=time.monotonic() - begin,
                root_exited=False, complete=complete, members=members, errors=errors,
                rss_bytes=sum(m['rss_bytes'] for m in members if 'rss_bytes' in m) if any('rss_bytes' in m for m in members) else None,
                pss_bytes=sum(m['pss_bytes'] for m in members if 'pss_bytes' in m) if any('pss_bytes' in m for m in members) else None)


def distribution(values):
    values = sorted(values)
    if not values:
        return dict(count=0, p50=None, p95=None, p99=None, worst=None)
    return dict(count=len(values), **{f'p{p}': values[max(0, math.ceil(len(values) * p / 100) - 1)] for p in (50, 95, 99)}, worst=values[-1])


def cpu_delta(previous, current, ticks=None):
    ticks = ticks or os.sysconf('SC_CLK_TCK')
    before = {identity(m): m for m in previous['members'] if not m['errors']}
    after = {identity(m): m for m in current['members'] if not m['errors']}
    elapsed = current['monotonic_seconds'] - previous['monotonic_seconds']
    records, unknown = [], []
    for key in before.keys() | after.keys():
        if key not in before or key not in after:
            unknown.append(dict(identity=key, reason='new child boundary' if key not in before else 'exited or unreadable child tail'))
            continue
        delta = after[key]['cpu_ticks'] - before[key]['cpu_ticks']
        if delta < 0 or elapsed <= 0:
            unknown.append(dict(identity=key, reason='nonmonotonic counters or timestamp'))
            continue
        records.append(dict(identity=key, ticks=delta, cpu_percent_of_one_core=delta / ticks / elapsed * 100,
                            voluntary_context_switches=after[key]['voluntary_context_switches'] - before[key]['voluntary_context_switches'],
                            involuntary_context_switches=after[key]['involuntary_context_switches'] - before[key]['involuntary_context_switches']))
    return dict(elapsed_seconds=elapsed, covered=records, unknown=unknown,
                covered_cpu_percent_of_one_core=sum(r['cpu_percent_of_one_core'] for r in records),
                complete=not unknown and previous['complete'] and current['complete'])


def summarize(samples):
    result = dict(samples=len(samples), complete_samples=sum(s['complete'] for s in samples),
                  peak_members=max((len(s['members']) for s in samples), default=0),
                  acquisition_seconds=distribution([s['duration_seconds'] for s in samples]),
                  cpu_intervals=[cpu_delta(a, b) for a, b in zip(samples, samples[1:])])
    for metric in ('rss_bytes', 'pss_bytes'):
        values = [s[metric] for s in samples if s['complete'] and s[metric] is not None]
        result[metric] = dict(distribution(values), first=values[0] if values else None, last=values[-1] if values else None,
                              growth=values[-1] - values[0] if values else None)
    return result


def collect(pid, seconds, interval=0.25, proc=Path('/proc')):
    if pid <= 0 or not all(math.isfinite(v) and v > 0 for v in (seconds, interval)):
        raise ValueError('positive PID and finite positive seconds/interval required')
    samples = []
    start, due = time.monotonic(), time.monotonic()
    expected = None
    while time.monotonic() < start + seconds:
        row = sample(pid, proc, expected)
        row['scheduled_monotonic_seconds'] = due
        row['lateness_seconds'] = max(0, row['monotonic_seconds'] - due)
        samples.append(row)
        if row['root_exited']:
            break
        if expected is None:
            expected = identity(next(m for m in row['members'] if m['pid'] == pid))
        due += interval
        # Skip missed deadlines, do not manufacture catch-up observations.
        skipped = max(0, math.floor((time.monotonic() - due) / interval))
        row['missed_intervals'] = skipped
        due += skipped * interval
        time.sleep(max(0, min(due, start + seconds) - time.monotonic()))
    return dict(version=2, pid=pid, requested_interval_seconds=interval, begin_monotonic_seconds=start,
                end_monotonic_seconds=time.monotonic(), clock_ticks=os.sysconf('SC_CLK_TCK'),
                summary=summarize(samples), samples=samples,
                limitations='RSS sums double-count shared pages; PSS is proportional, not VRAM/system memory. Enumeration can miss short-lived descendants; exited child CPU tails and first-seen child prefixes are unknown. Partial samples are not complete peaks. No waited-child usage is added.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--label', required=True)
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--settle', type=float, default=10)
    parser.add_argument('--interval', type=float, default=0.25)
    args = parser.parse_args()
    if args.pid <= 0 or not all(math.isfinite(v) for v in (args.seconds, args.settle, args.interval)) or args.seconds <= 0 or args.settle < 0 or args.interval <= 0:
        parser.error('positive PID, finite positive seconds/interval and finite nonnegative settle required')
    time.sleep(args.settle)
    report = collect(args.pid, args.seconds, args.interval)
    report.update(scenario=args.label, os=platform.platform(), architecture=platform.machine())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()
