#!/usr/bin/env python3
"""Finite external Linux process-tree sampling; raw incomplete reads stay explicit."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import time

MAX_MEMBERS = 4096
MAX_TASKS = 16384
MAX_CHILDREN_BYTES = 64 * 1024
READ_ERRORS = (OSError, ValueError, IndexError, KeyError)
DISCOVERY = 'per_thread_children_v1'


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


def children_snapshot(directory, task_budget):
    """Inspect every thread: a worker thread can own children the leader omits.

    Kernel children lists can skip processes during concurrent exits. Recheck
    topology after reading memory; this remains an observed, non-atomic census.
    https://www.kernel.org/doc/html/latest/filesystems/proc.html#proc-pid-task-tid-children-information-about-task-children
    """
    tasks, children = [], set()
    for task in (directory / 'task').iterdir():
        if not task.name.isdigit():
            continue
        if task_budget[0] == 0:
            raise ValueError('process-tree task discovery limit')
        task_budget[0] -= 1
        before = stat(task / 'stat')
        with (task / 'children').open() as source:
            raw = source.read(MAX_CHILDREN_BYTES + 1)
        if len(raw) > MAX_CHILDREN_BYTES:
            raise ValueError('process-tree children byte limit')
        found = {int(value) for value in raw.split()}
        if any(value <= 0 for value in found) or len(children | found) > MAX_MEMBERS:
            raise ValueError('process-tree children count limit or invalid PID')
        children |= found
        after = stat(task / 'stat')
        if before['pid'] != int(task.name) or identity(before) != identity(after):
            raise ValueError('thread identity changed during child discovery')
        tasks.append(identity(after))
    if not tasks:
        raise ValueError('process has no readable tasks')
    return tuple(sorted(tasks)), frozenset(children)


def sample(pid, proc=Path('/proc'), expected_root=None):
    begin = time.monotonic()
    errors, table, topologies = [], {}, {}
    try:
        root = stat(proc / str(pid) / 'stat')
    except READ_ERRORS as error:
        # Denial/malformed reads are not authoritative evidence of exit.
        return dict(monotonic_seconds=begin, duration_seconds=time.monotonic() - begin,
                    root_exited=isinstance(error, FileNotFoundError), complete=False, members=[],
                    discovery=DISCOVERY,
                    errors=[dict(pid=pid, stage='root', error=str(error))],
                    rss_bytes=None, pss_bytes=None)
    if root['pid'] != pid or (expected_root is not None and identity(root) != expected_root):
        return dict(monotonic_seconds=begin, duration_seconds=time.monotonic() - begin,
                    root_exited=root['pid'] == pid, complete=False, members=[], discovery=DISCOVERY,
                    errors=[dict(pid=pid, stage='root', error='reused root or root stat PID mismatch')], rss_bytes=None, pss_bytes=None)
    table[pid] = root
    selected, task_budget = [pid], [MAX_TASKS]
    for member_pid in selected:
        try:
            topology = children_snapshot(proc / str(member_pid), task_budget)
            topologies[member_pid] = topology
            for child_pid in sorted(topology[1]):
                child = stat(proc / str(child_pid) / 'stat')
                if child['pid'] != child_pid or child['ppid'] != member_pid or child_pid == pid:
                    raise ValueError('child identity or parent changed during discovery')
                if child_pid in table:
                    if identity(child) != identity(table[child_pid]) or child['ppid'] != table[child_pid]['ppid']:
                        raise ValueError('child identity changed during discovery')
                    continue
                if len(table) == MAX_MEMBERS:
                    raise ValueError('process-tree member discovery limit')
                table[child_pid] = child
                selected.append(child_pid)
        except READ_ERRORS as error:
            errors.append(dict(pid=member_pid, stage='children', error=str(error)))
    members = []
    for member_pid in sorted(selected):
        original = table[member_pid]
        member = dict(original, errors=[])
        directory = proc / str(member_pid)
        try:
            before = stat(directory / 'stat')
            if identity(before) != identity(original) or before['ppid'] != original['ppid']:
                raise ValueError('PID identity changed or process reparented before memory read')
            memory = fields(directory / 'smaps_rollup')
            member.update({key: int(memory[field].split()[0]) * 1024 for key, field in
                           [('rss_bytes', 'Rss'), ('pss_bytes', 'Pss'), ('anonymous_bytes', 'Anonymous')]})
            status = fields(directory / 'status')
            member.update(voluntary_context_switches=int(status['voluntary_ctxt_switches']),
                          involuntary_context_switches=int(status['nonvoluntary_ctxt_switches']))
            after = stat(directory / 'stat')
            if identity(after) != identity(original) or after['ppid'] != original['ppid']:
                raise ValueError('PID identity changed or process reparented around memory read')
            member['cpu_ticks'] = after['cpu_ticks']
        except READ_ERRORS as error:
            member['errors'].append(str(error))
            # Never retain apparently valid memory from an inconsistent instance.
            for key in ('rss_bytes', 'pss_bytes', 'anonymous_bytes'):
                member.pop(key, None)
        parent = table.get(original['ppid'])
        member['parent_identity'] = list(identity(parent)) if parent else None
        members.append(member)
    root_exited, task_budget = False, [MAX_TASKS]
    for member_pid in selected:
        try:
            current = stat(proc / str(member_pid) / 'stat')
            if identity(current) != identity(table[member_pid]) or current['ppid'] != table[member_pid]['ppid']:
                if member_pid == pid and identity(current) != identity(root):
                    root_exited = True
                raise ValueError('PID identity or parent changed at sample boundary')
        except READ_ERRORS as error:
            if member_pid == pid and isinstance(error, FileNotFoundError):
                root_exited = True
            errors.append(dict(pid=member_pid, stage='identity', error=str(error)))
            continue
        if member_pid in topologies:
            try:
                if children_snapshot(proc / str(member_pid), task_budget) != topologies[member_pid]:
                    raise ValueError('process-tree topology changed during sample')
            except READ_ERRORS as error:
                errors.append(dict(pid=member_pid, stage='topology', error=str(error)))
    complete = not errors and all(not member['errors'] for member in members)
    return dict(monotonic_seconds=begin, duration_seconds=time.monotonic() - begin,
                root_exited=root_exited, complete=complete, members=members, errors=errors, discovery=DISCOVERY,
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
                  discovery_methods=sorted({s.get('discovery', 'legacy_global_proc') for s in samples}),
                  incomplete_samples=sum(not s['complete'] for s in samples),
                  missing_intervals=sum(s.get('missed_intervals', 0) for s in samples),
                  coverage='complete_observed_samples' if samples and all(s['complete'] for s in samples) else 'incomplete_or_unavailable',
                  peak_scope='observed complete-sample maximum only; not an absolute tree peak',
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
            root = next((m for m in row['members'] if m['pid'] == pid), None)
            if root is not None:
                expected = identity(root)
        due += interval
        # Skip missed deadlines, do not manufacture catch-up observations.
        skipped = max(0, math.floor((time.monotonic() - due) / interval))
        row['missed_intervals'] = skipped
        due += skipped * interval
        time.sleep(max(0, min(due, start + seconds) - time.monotonic()))
    return dict(version=3, pid=pid, requested_interval_seconds=interval, begin_monotonic_seconds=start,
                end_monotonic_seconds=time.monotonic(), clock_ticks=os.sysconf('SC_CLK_TCK'),
                summary=summarize(samples), samples=samples,
                discovery='bounded per-thread children lists, identities and topology checked around memory reads',
                limitations='RSS sums double-count shared pages; PSS is proportional, not VRAM/system memory. Per-thread children lists are non-atomic and can skip descendants during exits, even when endpoint checks agree. Short-lived descendants, exited child CPU tails and first-seen child prefixes are unknown. Partial samples are not complete peaks. No waited-child usage is added.')


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
