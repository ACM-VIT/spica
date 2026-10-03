from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(platform.system() == 'Darwin', 'macOS font collections')
class CollectionTests(unittest.TestCase):
    def test_postscript_match_is_required(self):
        machine = {'arm64': 'aarch64'}.get(platform.machine().lower(), platform.machine().lower())
        prefix = ROOT / '.deps/install' / ('macos-' + machine)
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'collection'
            subprocess.run(['cc', '-std=c11', str(ROOT / 'src/native/text_test.c'),
                            '-I' + str(prefix / 'include'),
                            '-I' + str(prefix / 'include/freetype2'),
                            '-I' + str(prefix / 'include/harfbuzz'),
                            '-I' + str(prefix / 'include/fribidi'),
                            '-L' + str(prefix / 'lib'), '-Wl,-rpath,' + str(prefix / 'lib'),
                            '-lSDL3', '-lfreetype', '-lharfbuzz', '-lunibreak', '-lfribidi',
                            '-framework', 'CoreText', '-framework', 'CoreFoundation',
                            '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
