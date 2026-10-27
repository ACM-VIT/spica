"""Offline failure boundaries for populated-history pressure evaluation."""
import copy
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
TARGET = ROOT / 'tools/eval-history'
LOADER = importlib.machinery.SourceFileLoader('eval_history_under_test', str(TARGET))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
m = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(m)


def snapshot():
    return dict(draft=m.DRAFT, connected=True, pending_command=False, notice=None, visible_rich_blocks=2,
                thread_id='current', run_id='run', session_id='session', send_command_id='', send_run_id='',
                transcript_message_ids=['u1', 'a1'], transcript_ordinals=[0, 1], thread_labels=['current'],
                sidebar_search='', thread_more_available=False, frame_id=1)


class HistoryEvaluationTests(unittest.TestCase):
    def test_help_invalid_limits_and_prebuilt_hash_requirement_never_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'fresh'
            for flags in (['--threads', '1'], ['--turns', '64'], ['--content-bytes', '65537'],
                          ['--threads', '256', '--turns', '130'], ['--interval', 'nan'],
                          ['--binary', '/does-not-exist']):
                with self.subTest(flags=flags):
                    result = subprocess.run([str(TARGET), '--output', str(output), *flags], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())
            help_result = subprocess.run([str(TARGET), '--help'], capture_output=True, text=True)
            self.assertEqual(help_result.returncode, 0, help_result.stderr)

    def test_total_content_and_duration_bounds_are_independent(self):
        m.validate_config(40, 130, 1024, 10, 15, 3, .25, 1)
        for arguments in ((40, 130, 65536, 10, 15, 3, .25, 1),
                          (40, 130, 1024, 10, 100, 10, .25, 1),
                          (40, 130, 1024, 10, 15, 3, .01, 1),
                          (40, 130, 1024, 10, 15, 3, .25, 6)):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                m.validate_config(*arguments)

    def test_fixture_requires_public_host_provenance_exact_counts_and_paths(self):
        value = dict(fixture='synthetic-large-history', state_path='/new/state', workspace_path='/new/workspace',
                     generated_threads=40, generated_turns=5200, generated_runs=5200, generated_messages=10400,
                     completed_runs=5200, cancelled_runs=0, prompt_bytes=5324800, latest_thread_id='last',
                     provenance=dict(git_initialized=True, runtime='domain.Host fake'))
        m.validate_fixture(value, Path('/new/state'), Path('/new/workspace'), 40, 130, 1024)
        for changed in (dict(generated_runs=5199), dict(cancelled_runs=1), dict(workspace_path='/old/workspace'),
                        dict(provenance=dict(git_initialized=False, runtime='domain.Host fake')),
                        dict(provenance=dict(git_initialized=True, runtime='direct-sql')), dict(latest_thread_id='')):
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                m.validate_fixture(dict(value, **changed), Path('/new/state'), Path('/new/workspace'), 40, 130, 1024)

    def test_actions_must_preserve_draft_provider_identity_and_bounded_visible_state(self):
        before = snapshot()
        self.assertEqual(m.snapshot_summary(before, before)['ordinals'], [0, 1])
        for changed in (dict(draft='lost'), dict(thread_id='other'), dict(run_id='other'), dict(session_id='other'),
                        dict(send_command_id='new'), dict(send_run_id='new'), dict(pending_command=True),
                        dict(connected=False), dict(notice='failure'), dict(visible_rich_blocks=9),
                        dict(transcript_message_ids=[]), dict(transcript_ordinals=['0', 1]),
                        dict(thread_labels=['overflow'] * 33)):
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                m.snapshot_summary(dict(before, **changed), before)

    def test_partial_cpu_intervals_do_not_become_zero_complete_cpu(self):
        member = dict(pid=1, starttime_ticks=7, cpu_ticks=0, errors=[], voluntary_context_switches=0,
                      involuntary_context_switches=0)
        first = dict(monotonic_seconds=1, duration_seconds=.01, complete=True, members=[member],
                     rss_bytes=100, pss_bytes=80)
        second = copy.deepcopy(first)
        second.update(monotonic_seconds=2, rss_bytes=200, pss_bytes=160)
        second['members'][0]['cpu_ticks'] = 10
        report = m.resource_summary([first, second])
        self.assertEqual(report['cpu_percent_of_one_core']['count'], 1)
        self.assertGreater(report['cpu_percent_of_one_core']['p50'], 0)
        second['complete'] = False
        report = m.resource_summary([first, second])
        self.assertEqual(report['cpu_percent_of_one_core']['count'], 0)
        self.assertIsNone(report['cpu_percent_of_one_core']['p99'])
        self.assertEqual(report['incomplete_cpu_intervals'], 1)
        self.assertEqual(report['rss_bytes']['worst'], 100)
        self.assertEqual(report['coverage'], 'incomplete_or_unavailable')

    def test_short_phases_cannot_claim_a_complete_history_workload(self):
        actions = [dict(operation='history_navigation', key=key)
                   for key in ('alt+Home', 'alt+Page_Down', 'alt+End', 'alt+Page_Up')]
        actions += [dict(operation='sidebar_search', query=query)
                    for query in ('thread=39 turn=0', 'turn=0', 'missing', '')]
        phases = [dict(name='navigation_1', delivered_actions=4), dict(name='search_1', delivered_actions=4)]
        m.validate_action_coverage(actions, phases)
        with self.assertRaises(RuntimeError):
            m.validate_action_coverage(actions[:-1], phases)
        with self.assertRaises(RuntimeError):
            m.validate_action_coverage(actions[:-1] + [dict(operation='sidebar_search', query='', cleanup=True)], phases)
        with self.assertRaises(RuntimeError):
            m.validate_action_coverage(actions, phases + [dict(name='search_2', delivered_actions=0)])

    def test_observer_refuses_another_process_nonce_before_accepting_state(self):
        gui = m.HistoryInput('session', '5', 'socket', Path('/fresh/live'), 'expected', snapshot(), {}, Mock())
        with patch.object(m.evaluation, 'read_export', return_value=dict(snapshot(), process_nonce='old')):
            with self.assertRaisesRegex(RuntimeError, 'another GUI'):
                gui.observe(lambda s: True, 'must not accept stale file')

    def test_pointer_uses_painted_target_and_private_window_origin(self):
        gui = m.HistoryInput('private', '5', 'socket', Path('/fresh/live'), 'nonce', None, {}, Mock())
        current = dict(targets=[], sidebar_targets=[], navigation_targets=[dict(id='composer.input', enabled=True, pointer_bounds=[20, 30, 101, 51])])
        gui.observe = Mock(return_value=current)
        tree = dict(nodes=[dict(id=5, rect=dict(x=100, y=200))])
        with patch.object(m, 'run', side_effect=[json.dumps(tree), '[{"success":true}]', '']) as command:
            gui.click('composer.input')
        self.assertEqual(command.call_args_list[-1].args, ('vd', 'click', 'private', '5', '170', '255'))

    def test_failed_window_start_records_failure_and_cleans_only_owned_desktop(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output, session = root / 'output', root / 'private'
            session.mkdir()
            (session / 'session.json').write_text(json.dumps(dict(environment=dict(SWAYSOCK='private-socket'))))
            (session / 'compositor.log').write_text('fixture compositor')
            binary, fixture = root / 'spica', root / 'build-history-fixture'
            binary.write_bytes(b'frozen-app')
            fixture.write_bytes(b'frozen-fixture')
            manifest = dict(fixture='synthetic-large-history', state_path=str(output / 'conversation-state'),
                workspace_path=str(output / 'workspace'), generated_threads=40, generated_turns=5200,
                generated_runs=5200, generated_messages=10400, completed_runs=5200, cancelled_runs=0,
                prompt_bytes=5324800, latest_thread_id='last',
                provenance=dict(git_initialized=True, runtime='domain.Host fake'))
            commands = []
            def command(*args, **kwargs):
                commands.append(args)
                if args[0] == str(fixture):
                    return json.dumps(manifest)
                if args[:2] == ('vd', 'start'):
                    return str(session)
                if args[:2] == ('vd', 'run'):
                    return json.dumps(dict(pid=123))
                return ''
            argv = [str(TARGET), '--output', str(output), '--binary', str(binary),
                    '--binary-sha256', m.evaluation.sha(binary), '--source-sha256', 'source',
                    '--fixture-sha256', m.evaluation.sha(fixture)]
            with patch.object(sys, 'argv', argv), patch.object(m, 'run', side_effect=command), \
                    patch.object(m.evaluation, 'source_fingerprint', return_value='source'), \
                    patch.object(m.measure, 'stat', return_value=dict(pid=123, starttime_ticks=456)), \
                    patch.object(m.evaluation, 'wait_windows', side_effect=RuntimeError('no native window')):
                with self.assertRaisesRegex(RuntimeError, 'no native window'):
                    m.main()
            self.assertEqual(commands[-1], ('vd', 'clean', str(session)))
            result = json.loads((output / 'manifest.json').read_text())
            self.assertFalse(result['passed'])
            self.assertFalse(result['performance_accepted'])
            self.assertIn('no native window', result['error'])
            self.assertEqual(json.loads((output / 'samples.json').read_text()), [])


if __name__ == '__main__':
    unittest.main()
