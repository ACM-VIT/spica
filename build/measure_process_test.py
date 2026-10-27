import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('measure_process', Path(__file__).resolve().parents[1] / 'tools/measure_process.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class ProcessTreeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.proc = Path(self.temporary.name)
        self.parents = {}
        self.process(10, 1, 100)

    def process(self, pid, parent, start, cpu=5):
        directory = self.proc / str(pid)
        directory.mkdir(exist_ok=True)
        tail = ['S', str(parent)] + ['0'] * 18
        tail[11], tail[12], tail[19] = str(cpu), '0', str(start)
        contents = f'{pid} (name with ) spaces) ' + ' '.join(tail)
        (directory / 'stat').write_text(contents)
        task = directory / 'task' / str(pid)
        task.mkdir(parents=True, exist_ok=True)
        (task / 'stat').write_text(contents)
        self.parents[pid] = parent
        for owner in self.parents:
            children = sorted(child for child, parent in self.parents.items() if parent == owner)
            (self.proc / str(owner) / 'task' / str(owner) / 'children').write_text(' '.join(map(str, children)))
        (directory / 'smaps_rollup').write_text('Rss: 100 kB\nPss: 40 kB\nAnonymous: 20 kB\n')
        (directory / 'status').write_text('voluntary_ctxt_switches: 3\nnonvoluntary_ctxt_switches: 1\n')
        return directory

    def test_tree_new_child_exit_and_cpu(self):
        first = m.sample(10, self.proc)
        self.process(11, 10, 101)
        second = m.sample(10, self.proc)
        self.assertEqual(second['rss_bytes'], 200 * 1024)
        self.assertEqual(second['pss_bytes'], 80 * 1024)
        delta = m.cpu_delta(first, second, 100)
        self.assertEqual(len(delta['unknown']), 1)
        self.assertFalse(delta['complete'])
        third = dict(second, members=[second['members'][0]], monotonic_seconds=second['monotonic_seconds'] + 1)
        self.assertIn('exited', m.cpu_delta(second, third)['unknown'][0]['reason'])

    def test_reused_root_is_exit_not_zero_plateau(self):
        self.assertTrue(m.sample(10, self.proc, (10, 99))['root_exited'])
        self.assertIsNone(m.sample(10, self.proc, (10, 99))['rss_bytes'])

    def test_missing_root_is_terminal_but_malformed_root_is_retryable(self):
        self.assertTrue(m.sample(99, self.proc)['root_exited'])
        path = self.proc / '10' / 'stat'
        original = path.read_text()
        invalid_rows = ['malformed', original.replace('10 (', '99 (', 1)]
        for invalid in invalid_rows:
            with self.subTest(contents=invalid):
                path.write_text(invalid)
                row = m.sample(10, self.proc)
                self.assertFalse(row['root_exited'])
                self.assertFalse(row['complete'])

    def test_reused_child_not_subtracted(self):
        self.process(11, 10, 101)
        first = m.sample(10, self.proc)
        self.process(11, 10, 102, cpu=1)
        second = m.sample(10, self.proc)
        self.assertEqual(len(m.cpu_delta(first, second)['unknown']), 2)

    def test_unrelated_process_reads_are_never_needed(self):
        (self.proc / '999').mkdir()  # An unrelated process exits before its stat read.
        original = Path.iterdir
        def scoped(directory):
            if directory == self.proc:
                raise AssertionError('sampler enumerated unrelated processes')
            return original(directory)
        with patch.object(Path, 'iterdir', scoped):
            row = m.sample(10, self.proc)
        self.assertTrue(row['complete'], row['errors'])
        self.assertEqual([member['pid'] for member in row['members']], [10])

    def test_children_of_secondary_threads_and_their_descendants_are_counted_once(self):
        self.process(11, 10, 101)
        self.process(12, 11, 102)
        main = self.proc / '10' / 'task' / '10'
        (main / 'children').write_text('')
        worker = main.parent / '13'
        worker.mkdir()
        (worker / 'stat').write_text((main / 'stat').read_text().replace('10 (', '13 (', 1))
        (worker / 'children').write_text('11')
        row = m.sample(10, self.proc)
        self.assertTrue(row['complete'], row['errors'])
        self.assertEqual([member['pid'] for member in row['members']], [10, 11, 12])
        self.assertEqual(row['pss_bytes'], 120 * 1024)
        self.assertEqual(row['members'][2]['parent_identity'], [11, 101])

    def test_new_child_during_memory_read_invalidates_topology(self):
        original = m.fields
        def spawned(path):
            if path == self.proc / '10' / 'smaps_rollup':
                self.process(11, 10, 101)
            return original(path)
        with patch.object(m, 'fields', side_effect=spawned):
            row = m.sample(10, self.proc)
        self.assertFalse(row['complete'])
        self.assertFalse(row['root_exited'])
        self.assertTrue(any(error['stage'] == 'topology' for error in row['errors']))
        self.assertEqual(m.summarize([row])['pss_bytes']['count'], 0)

    def test_known_child_disappearance_remains_incomplete(self):
        self.process(11, 10, 101)
        original = m.stat
        def vanished(path):
            if path == self.proc / '11' / 'stat':
                raise FileNotFoundError('known child exited')
            return original(path)
        with patch.object(m, 'stat', side_effect=vanished):
            row = m.sample(10, self.proc)
        self.assertFalse(row['complete'])
        self.assertFalse(row['root_exited'])
        self.assertIn('known child exited', row['errors'][0]['error'])

    def test_reparented_child_cannot_contribute_a_complete_sample(self):
        self.process(11, 10, 101)
        original = m.fields
        def reparented(path):
            if path == self.proc / '10' / 'smaps_rollup':
                self.process(11, 99, 101)
            return original(path)
        with patch.object(m, 'fields', side_effect=reparented):
            row = m.sample(10, self.proc)
        self.assertFalse(row['complete'])
        self.assertNotIn('pss_bytes', row['members'][1])
        self.assertIn('reparented', row['members'][1]['errors'][0])

    def test_task_discovery_failure_is_not_a_zero_or_complete_sample(self):
        original = Path.open
        def denied(path, *args, **kwargs):
            if path.name == 'children':
                raise PermissionError('children unavailable')
            return original(path, *args, **kwargs)
        with patch.object(Path, 'open', denied):
            row = m.sample(10, self.proc)
        self.assertFalse(row['complete'])
        self.assertFalse(row['root_exited'])
        self.assertEqual(row['rss_bytes'], 100 * 1024)
        self.assertIn('children unavailable', row['errors'][0]['error'])

    def test_discovery_limits_are_explicit_incomplete_results(self):
        self.process(11, 10, 101)
        for limit, value in (('MAX_MEMBERS', 1), ('MAX_TASKS', 0), ('MAX_CHILDREN_BYTES', 1)):
            with self.subTest(limit=limit), patch.object(m, limit, value):
                row = m.sample(10, self.proc)
            self.assertFalse(row['complete'])
            self.assertFalse(row['root_exited'])
            self.assertTrue(any('limit' in error['error'] for error in row['errors']))

    def test_root_denial_is_retryable_and_collection_pins_first_readable_identity(self):
        original = m.stat
        def denied(path):
            if path == self.proc / '10' / 'stat':
                raise PermissionError('root temporarily unavailable')
            return original(path)
        with patch.object(m, 'stat', side_effect=denied):
            unavailable = m.sample(10, self.proc)
        self.assertFalse(unavailable['root_exited'])
        self.assertFalse(unavailable['complete'])
        self.assertIsNone(unavailable['rss_bytes'])
        valid = m.sample(10, self.proc)
        unavailable['monotonic_seconds'] = .1
        valid['monotonic_seconds'] = .4
        exited = dict(unavailable, root_exited=True, monotonic_seconds=.7)
        with patch.object(m, 'sample', side_effect=[unavailable, valid, exited]) as sample, \
                patch.object(m.time, 'monotonic', side_effect=[0, 0, .1, .2, .3, .4, .5, .6, .7, .8]), \
                patch.object(m.time, 'sleep'):
            report = m.collect(10, 1, proc=self.proc)
        self.assertEqual(sample.call_args_list[0].args[2], None)
        self.assertEqual(sample.call_args_list[1].args[2], None)
        self.assertEqual(sample.call_args_list[2].args[2], (10, 100))
        self.assertEqual(report['summary']['complete_samples'], 1)
        self.assertEqual(report['summary']['samples'], 3)
        self.assertEqual(report['summary']['discovery_methods'], ['per_thread_children_v1'])

    @unittest.skipUnless(Path('/proc/self/task').is_dir(), 'Linux procfs required')
    def test_live_tree_contains_controlled_child(self):
        child = subprocess.Popen([sys.executable, '-c', 'import sys; print("ready", flush=True); sys.stdin.read()'],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            row = m.sample(os.getpid())
            self.assertTrue(row['complete'], row['errors'])
            self.assertIn(child.pid, {member['pid'] for member in row['members']})
            self.assertGreater(row['pss_bytes'], 0)
        finally:
            child.stdin.close()
            child.wait(timeout=5)
            child.stdout.close()

    def test_missing_memory_keeps_partial_not_zero(self):
        child = self.process(11, 10, 101)
        (child / 'smaps_rollup').unlink()
        row = m.sample(10, self.proc)
        self.assertFalse(row['complete'])
        self.assertEqual(row['rss_bytes'], 100 * 1024)
        self.assertTrue(row['members'][1]['errors'])
        self.assertEqual(m.summarize([row])['rss_bytes']['count'], 0)

    def test_permission_and_identity_race_explicit(self):
        original = m.fields
        def denied(path):
            if path.name == 'smaps_rollup':
                raise PermissionError('fixture denied')
            return original(path)
        with patch.object(m, 'fields', side_effect=denied):
            row = m.sample(10, self.proc)
        self.assertFalse(row['complete'])
        self.assertIsNone(row['pss_bytes'])
        original_stat = m.stat
        calls = 0
        def changed(path):
            nonlocal calls
            calls += 1
            row = original_stat(path)
            if calls >= 3:
                row['starttime_ticks'] += 1
            return row
        with patch.object(m, 'stat', side_effect=changed):
            row = m.sample(10, self.proc)
        self.assertFalse(row['complete'])
        self.assertIn('identity changed', row['members'][0]['errors'][0])

    def test_empty_one_and_negative_counter(self):
        self.assertIsNone(m.distribution([])['p99'])
        self.assertEqual(m.distribution([4])['p99'], 4)
        first = m.sample(10, self.proc)
        self.process(10, 1, 100, cpu=1)
        second = m.sample(10, self.proc)
        self.assertIn('nonmonotonic', m.cpu_delta(first, second)['unknown'][0]['reason'])

    def test_nonfinite_and_invalid_collection_bounds(self):
        for value in (float('nan'), float('inf'), -float('inf'), 0, -1):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    m.collect(10, value, proc=self.proc)
                with self.assertRaises(ValueError):
                    m.collect(10, 1, interval=value, proc=self.proc)
        with self.assertRaises(ValueError):
            m.collect(0, 1, proc=self.proc)

    def test_cli_rejects_nonfinite_before_sleep(self):
        for flag in ('--seconds', '--settle', '--interval'):
            for value in ('nan', 'inf', '-inf'):
                argv = ['measure_process', '--pid', '10', '--label', 'test', '--output', str(self.proc / 'out.json'), flag + '=' + value]
                with self.subTest(flag=flag, value=value), patch('sys.argv', argv), patch.object(m.time, 'sleep') as sleep:
                    with self.assertRaises(SystemExit) as error:
                        m.main()
                    self.assertEqual(error.exception.code, 2)
                    sleep.assert_not_called()



if __name__ == '__main__':
    unittest.main()
