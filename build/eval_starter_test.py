import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
# The preserved pre-repair runner exercises the same tests for failure evidence.
TARGET = Path(os.environ.get('SPICA_EVAL_TEST_TARGET', ROOT / 'tools/eval-starter'))
LOADER = importlib.machinery.SourceFileLoader('eval_starter_under_test', str(TARGET))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
m = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(m)


def native():
    stats = dict(fixed_cpu_bytes=10, font_bytes=20, layout_bytes=30, glyph_bytes=40,
                 live_layouts=1, glyph_count=2, face_count=1)
    return dict(clock_mapping=dict(native_before_ns=0, native_after_ns=0, host_monotonic_ns=0),
                dropped=0, attempts=1, failures=0, run_error=None, successful_presents=1,
                text_stats=stats, frames=[dict(frame_id=1, succeeded=True, paint_begin_ns=1,
                    present_begin_ns=2, present_end_ns=3, text_stats=stats)])


def run_smoke_fixture(value):
    """Drive the actual runner entrypoint with external desktop commands isolated."""
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        output, session = root / 'out', root / 'session'
        session.mkdir()
        (session / 'session.json').write_text(json.dumps(dict(environment=dict(SWAYSOCK='fixture'))))
        (session / 'compositor.log').write_text('fixture')
        binary = root / 'spica'
        binary.write_bytes(b'fixture')
        value.update(renderer='fixture', video='fixture')
        def command(*args, **kwargs):
            if args[:2] == ('vd', 'start'):
                return str(session)
            if args[:2] == ('vd', 'run'):
                return json.dumps(dict(pid=os.getpid()))
            if args[:2] == ('vd', 'key'):
                (output / 'automation.json').write_text(json.dumps(dict(close_reason='ctrl_q', running=False)))
                (output / 'native.json').write_text(json.dumps(value))
            if args[0] == 'swaymsg':
                return '[{\"success\":true}]'
            return ''
        argv = ['eval-starter', '--binary', str(binary), '--binary-sha256', m.sha(binary),
                '--source-sha256', 'fixture', '--output', str(output)]
        with patch('sys.argv', argv), patch.object(m, 'source_fingerprint', return_value='fixture'), patch.object(m, 'run', side_effect=command), patch.object(m, 'wait_windows', return_value='1 Spica'):
            try:
                m.main()
            except RuntimeError:
                pass
        return json.loads((output / 'manifest.json').read_text())


class RunnerBoundaries(unittest.TestCase):
    def test_missing_clock_fails_required_frame_assertion(self):
        value = native()
        value['clock_mapping'] = None
        with self.assertRaisesRegex(RuntimeError, 'clock mapping'):
            m.frame_summary(value, dict(begin=0, end=1))
    def test_runner_never_passes_missing_clock_cache_overflow_or_drops(self):
        for failure in ('clock', 'cache', 'drops'):
            value = native()
            if failure == 'clock':
                value['clock_mapping'] = None
            elif failure == 'cache':
                value['text_stats']['glyph_count'] = 513
            else:
                value.update(dropped=1, attempts=2)
            with self.subTest(failure=failure):
                report = run_smoke_fixture(value)
                self.assertFalse(report['passed'])
                self.assertIn('error', report)

    def test_complete_sample_and_empty_phase_keep_real_denominators(self):
        row = native()
        m.validate_native(row)
        report = m.frame_summary(row, dict(begin=0, end=2))
        self.assertEqual(report['achieved_fps'], .5)
        self.assertEqual(report['frame_work_ns']['p50'], 1)
        empty = m.frame_summary(row, dict(begin=1, end=2))
        self.assertEqual(empty['achieved_fps'], 0)
        self.assertIsNone(empty['frame_work_ns']['p99'])


    def test_cache_overflow_and_missing_ledger_fail_required_assertion(self):
        for key, value in [('glyph_count', 513), ('glyph_bytes', 2097153), ('font_bytes', 4194305)]:
            with self.subTest(key=key):
                row = native()
                row['text_stats'][key] = value
                with self.assertRaisesRegex(RuntimeError, 'cache ledger'):
                    m.validate_native(row)
        row = native()
        row['text_stats'] = None
        with self.assertRaisesRegex(RuntimeError, 'ledger unavailable'):
            m.validate_native(row)

    def test_drop_has_lower_bound_not_achieved_fps_or_percentiles(self):
        row = native()
        row.update(dropped=1, attempts=2, successful_presents=2)
        report = m.frame_summary(row, dict(begin=0, end=1))
        self.assertIsNone(report['achieved_fps'])
        self.assertEqual(report['sampled_fps_lower_bound'], 1)
        self.assertEqual(report['successful_presents_run_total'], 2)
        self.assertIsNone(report['frame_work_ns'])
        self.assertFalse(report['full_cohort'])

    def test_partial_export_retried_and_finite_deadline(self):
        path = Mock()
        path.read_text.side_effect = [FileNotFoundError(), '{', '{"close_reason":"escape"}']
        with patch.object(m.time, 'monotonic', return_value=0), patch.object(m.time, 'sleep'):
            self.assertEqual(m.read_export(path, 1)['close_reason'], 'escape')
        path.read_text.side_effect = ['{']
        with patch.object(m.time, 'monotonic', return_value=2):
            with self.assertRaisesRegex(RuntimeError, 'incomplete'):
                m.read_export(path, 1)

    def test_cache_state_carried_through_idle_and_tail_overflow_rejected(self):
        row = native()
        phase = dict(name='settled_1', begin=1, end=7)
        report = m.cache_tail_summary(row, phase)
        self.assertTrue(report['bounds_passed'])
        self.assertEqual(report['states'], 1)
        bad = copy.deepcopy(row['frames'][0])
        bad['present_end_ns'] = 4000000000
        bad['text_stats']['glyph_count'] = 513
        row['frames'].append(bad)
        with self.assertRaisesRegex(RuntimeError, 'cache ledger'):
            m.cache_tail_summary(row, phase)
        row = native()
        row['dropped'] = 1
        with self.assertRaisesRegex(RuntimeError, 'Dropped telemetry'):
            m.cache_tail_summary(row, phase)


if __name__ == '__main__':
    unittest.main()
