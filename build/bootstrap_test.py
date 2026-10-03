"""Exercise bootstrap cache decisions without downloading or compiling dependencies."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import bootstrap


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'deps.lock.json').write_bytes((bootstrap.ROOT / 'deps.lock.json').read_bytes())
        self.cache = self.root / '.deps'
        (self.cache / 'tools').mkdir(parents=True)
        (self.cache / 'tools' / 'ninja').touch()
        self.commands = []
        self.configures = {}
        for target, replacement in (
                ('ROOT', self.root), ('CACHE', self.cache),
                ('acquire', lambda name: self.cache / 'src' / name),
                ('acquire_font', lambda *args: None),
                ('configure_image_allocators', lambda *args: None),
                ('build_highlighting', lambda *args: None), ('log', lambda *args: None)):
            patcher = patch.object(bootstrap, target, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(bootstrap.subprocess, 'run', self.run_command)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(bootstrap.subprocess, 'check_output', return_value='/SDK/MacOSX.sdk\n')
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.dict(bootstrap.os.environ, {'SDKROOT': '/SDK/MacOSX.sdk'})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == 'cmake' and '-S' in command:
            build = command[command.index('-B') + 1]
            source = Path(command[command.index('-S') + 1]).name
            prefix = next(arg.split('=', 1)[1] for arg in command if arg.startswith('-DCMAKE_INSTALL_PREFIX='))
            self.configures[build] = (source, Path(prefix))
        elif command[:2] == ['cmake', '--install']:
            source, prefix = self.configures[command[2]]
            library = {'libpng': 'libpng16.dylib', 'FreeType': 'libfreetype.dylib'}[source]
            (prefix / 'lib' / library).touch()
        elif 'setup' in command:
            build = command[command.index('setup') + 1]
            prefix = Path(command[command.index('--prefix') + 1])
            self.configures[build] = (Path(build).name, prefix)
        elif command[-1] == 'install':
            source, prefix = self.configures[command[command.index('-C') + 1]]
            (prefix / 'lib' / ('lib' + source + '.dylib')).touch()

    def seed_install(self, machine):
        prefix = self.cache / 'install' / ('macos-' + machine)
        (prefix / 'lib').mkdir(parents=True, exist_ok=True)
        for library in ('SDL3', 'SDL3_image', 'freetype', 'png16', 'harfbuzz', 'fribidi'):
            (prefix / 'lib' / ('lib' + library + '.dylib')).touch()
        for library in ('cmark-gfm', 'unibreak'):
            (prefix / 'lib' / ('lib' + library + '.a')).touch()
        for stamp in ('.sdl-allocator-config', '.image-allocator-config'):
            (prefix / stamp).write_text(bootstrap.allocator_fingerprint())
        return prefix

    def cmake_sources(self):
        return [Path(cmd[cmd.index('-S') + 1]).name for cmd in self.commands if '-S' in cmd]

    @patch.object(bootstrap.platform, 'system', return_value='Darwin')
    @patch.object(bootstrap.platform, 'machine', return_value='arm64')
    def test_lock_change_rebuilds_png_and_freetype(self, *unused):
        self.seed_install('aarch64')
        bootstrap.main()
        self.assertEqual(self.cmake_sources(), ['libpng', 'FreeType'])
        self.commands.clear()
        bootstrap.main()
        self.assertEqual(self.commands, [])
        # A changed locked dependency must invalidate both installs, even if their files exist.
        lock = self.root / 'deps.lock.json'
        lock.write_text(lock.read_text().replace('4b9e071b2fc4216369372a3ed260d335dd036f15', 'new-libpng-revision'))
        for stamp in ('.sdl-allocator-config', '.image-allocator-config'):
            (self.cache / 'install/macos-aarch64' / stamp).write_text(bootstrap.allocator_fingerprint())
        bootstrap.main()
        self.assertEqual(self.cmake_sources(), ['libpng', 'FreeType'])

    @patch.object(bootstrap.platform, 'system', return_value='Darwin')
    @patch.object(bootstrap.platform, 'machine', return_value='arm64')
    def test_png_and_freetype_pin_sdk_zlib(self, *unused):
        self.seed_install('aarch64')
        bootstrap.main()
        for cmd in self.commands:
            if '-S' not in cmd:
                continue
            self.assertIn('-DCMAKE_OSX_SYSROOT=/SDK/MacOSX.sdk', cmd)
            self.assertIn('-DCMAKE_OSX_ARCHITECTURES=arm64', cmd)
            self.assertIn('-DZLIB_INCLUDE_DIR=/SDK/MacOSX.sdk/usr/include', cmd)
            for variable in ('ZLIB_LIBRARY', 'ZLIB_LIBRARY_RELEASE', 'ZLIB_LIBRARY_DEBUG'):
                self.assertIn(f'-D{variable}=/SDK/MacOSX.sdk/usr/lib/libz.tbd', cmd)

    @patch.object(bootstrap.platform, 'system', return_value='Darwin')
    def test_meson_builds_use_distinct_architecture_directories(self, *unused):
        builds = []
        for host, machine in (('arm64', 'aarch64'), ('x86_64', 'x86_64')):
            with patch.object(bootstrap.platform, 'machine', return_value=host):
                prefix = self.seed_install(machine)
                for library in ('harfbuzz', 'fribidi'):
                    (prefix / 'lib' / ('lib' + library + '.dylib')).unlink()
                self.commands.clear()
                bootstrap.main()
                setups = [cmd for cmd in self.commands if 'setup' in cmd]
                self.assertEqual(len(setups), 2)
                for cmd in setups:
                    build = Path(cmd[cmd.index('setup') + 1])
                    self.assertEqual(build.parent.name, 'macos-' + machine)
                    builds.append(build)
        self.assertEqual(len(set(builds)), 4)


if __name__ == '__main__':
    unittest.main()
