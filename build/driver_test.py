"""SDK fallback and explicit SDK constraints, without requiring Apple tools."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import driver


class DriverTests(unittest.TestCase):
    def test_falls_back_when_either_compiler_rejects_sdk(self):
        for failing_compiler in ('cc', 'zig'):
            with self.subTest(compiler=failing_compiler), tempfile.TemporaryDirectory() as temporary:
                commands = []
                def run(command, **kwargs):
                    commands.append((command, kwargs['env']))
                    fails = kwargs['env']['SDKROOT'] == '/new.sdk' and command[0] == failing_compiler
                    return subprocess.CompletedProcess(command, int(fails), '', 'incompatible' if fails else '')
                with patch.object(driver, 'sdk_candidates', return_value=[Path('/new.sdk'), Path('/old.sdk')]), \
                     patch.object(driver.subprocess, 'run', side_effect=run):
                    environment = driver.select_sdk({'PATH': '/tools'}, Path(temporary))
                self.assertEqual(environment['SDKROOT'], '/old.sdk')
                self.assertEqual(environment['PATH'], '/tools')
                self.assertIn('include_dir=/old.sdk/usr/include', Path(environment['ZIG_LIBC']).read_text())
                self.assertEqual(commands[-1][0][0], 'zig')

    def test_explicit_sdk_does_not_fall_back(self):
        with patch.object(driver.subprocess, 'check_output', return_value='/chosen.sdk\n') as lookup:
            self.assertEqual(driver.sdk_candidates({'SDKROOT': '/chosen.sdk'}), [Path('/chosen.sdk')])
            self.assertEqual(lookup.call_count, 1)

    def test_no_compatible_sdk_reports_compiler_error(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(driver, 'sdk_candidates', return_value=[Path('/bad.sdk')]), \
             patch.object(driver.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'unknown architecture')):
            with self.assertRaisesRegex(RuntimeError, 'unknown architecture'):
                driver.select_sdk({}, Path(temporary))
