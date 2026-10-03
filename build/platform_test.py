"""Run native platform regressions independently of the app's GUI dependencies."""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(platform.system() in ('Darwin', 'Linux'), 'Unix platform tests')
class PlatformTests(unittest.TestCase):
    def run_probe(self, name, arguments=(), libraries=()):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / name
            subprocess.run(['cc', '-std=c11', '-D_DEFAULT_SOURCE',
                            str(ROOT / 'src/platform' / (name + '_test.c')),
                            *libraries, '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary), temporary, *arguments], check=True, timeout=10)

    def test_read_only_legacy_migration(self):
        self.run_probe('database', ['readonly'], ['-lsqlite3'])

    def test_wal_database_without_sidecars(self):
        self.run_probe('database', ['wal'], ['-lsqlite3'])

    @unittest.skipUnless(platform.system() == 'Darwin', 'macOS process traversal')
    def test_large_child_list_and_failure_resume(self):
        self.run_probe('process')


if __name__ == '__main__':
    unittest.main()
