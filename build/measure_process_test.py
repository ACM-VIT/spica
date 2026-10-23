import importlib.util
from pathlib import Path
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
        self.process(10, 1, 100)

    def process(self, pid, parent, start, cpu=5):
        directory = self.proc / str(pid)
        directory.mkdir(exist_ok=True)
        tail = ['S', str(parent)] + ['0'] * 18
        tail[11], tail[12], tail[19] = str(cpu), '0', str(start)
        (directory / 'stat').write_text(f'{pid} (name with ) spaces) ' + ' '.join(tail))
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

    def test_reused_child_not_subtracted(self):
        self.process(11, 10, 101)
        first = m.sample(10, self.proc)
        self.process(11, 10, 102, cpu=1)
        second = m.sample(10, self.proc)
        self.assertEqual(len(m.cpu_delta(first, second)['unknown']), 2)

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
