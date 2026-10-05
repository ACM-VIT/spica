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
        self.commands = []
        self.invocations = []
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
        self.invocations.append((command, kwargs))
        if command[0] == 'cmake' and '-S' in command:
            build = command[command.index('-B') + 1]
            source = Path(command[command.index('-S') + 1]).name
            prefix = next(arg.split('=', 1)[1] for arg in command if arg.startswith('-DCMAKE_INSTALL_PREFIX='))
            self.configures[build] = (source, Path(prefix))
        elif command[:2] == ['cmake', '--install']:
            source, prefix = self.configures[command[2]]
            suffix = '.dylib' if prefix.name.startswith('macos-') else '.so'
            library = {'SDL': 'libSDL3' + suffix, 'SDL_image': 'libSDL3_image' + suffix,
                       'cmark-gfm': 'libcmark-gfm.a', 'libpng': 'libpng16' + suffix,
                       'FreeType': 'libfreetype' + suffix}[source]
            (prefix / 'lib' / library).touch()
            if source == 'cmark-gfm':
                headers = Path(command[2]) / 'src'
                headers.mkdir(parents=True, exist_ok=True)
                (headers / 'config.h').touch()
        elif '--bootstrap' in command:
            (kwargs['cwd'] / 'ninja').touch()
        elif 'setup' in command:
            build = command[command.index('setup') + 1]
            prefix = Path(command[command.index('--prefix') + 1])
            self.configures[build] = (Path(build).name, prefix)
        elif command[0] == 'make' and command[-1] == 'install':
            _, prefix = self.configures[str(kwargs['cwd'])]
            (prefix / 'lib' / 'libunibreak.a').touch()
        elif command[-1] == 'install':
            source, prefix = self.configures[command[command.index('-C') + 1]]
            suffix = '.dylib' if prefix.name.startswith('macos-') else '.so'
            (prefix / 'lib' / ('lib' + source + suffix)).touch()
        elif Path(command[0]).name == 'configure':
            prefix = Path(command[1].split('=', 1)[1])
            self.configures[str(kwargs['cwd'])] = ('libunibreak', prefix)

    def seed_install(self, machine):
        prefix = self.cache / 'install' / ('macos-' + machine)
        (prefix / 'lib').mkdir(parents=True, exist_ok=True)
        for library in ('SDL3', 'SDL3_image', 'freetype', 'png16', 'harfbuzz', 'fribidi'):
            (prefix / 'lib' / ('lib' + library + '.dylib')).touch()
        for library in ('cmark-gfm', 'unibreak'):
            (prefix / 'lib' / ('lib' + library + '.a')).touch()
        for stamp in ('.sdl-allocator-config', '.image-allocator-config'):
            (prefix / stamp).write_text(bootstrap.allocator_fingerprint())
        tools = self.cache / 'build' / ('macos-' + machine) / 'ninja'
        tools.mkdir(parents=True, exist_ok=True)
        (tools / 'ninja').touch()
        headers = tools.parent / 'cmark-gfm' / 'src'
        headers.mkdir(parents=True, exist_ok=True)
        (headers / 'config.h').touch()
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

    @patch.object(bootstrap.platform, 'system', return_value='Darwin')
    @patch.object(bootstrap.platform, 'machine', return_value='arm64')
    def test_existing_cmark_install_regenerates_platform_headers(self, *unused):
        self.seed_install('aarch64')
        headers = self.cache / 'build/macos-aarch64/cmark-gfm/src/config.h'
        headers.unlink()
        legacy = self.cache / 'build/cmark-gfm/src'
        legacy.mkdir(parents=True)
        (legacy / 'config.h').touch()
        bootstrap.main()
        self.assertIn('cmark-gfm', self.cmake_sources())
        self.assertTrue(headers.exists())

    def test_all_builds_and_ninja_are_platform_specific(self):
        # Legacy shared Ninja must never be reused.
        (self.cache / 'tools').mkdir(parents=True)
        (self.cache / 'tools' / 'ninja').write_text('wrong platform')
        builds = set()
        for system, host, target in (
                ('Darwin', 'arm64', 'macos-aarch64'),
                ('Darwin', 'x86_64', 'macos-x86_64'),
                ('Linux', 'aarch64', 'linux-aarch64'),
                ('Linux', 'AMD64', 'linux-x86_64')):
            with self.subTest(target=target), \
                    patch.object(bootstrap.platform, 'system', return_value=system), \
                    patch.object(bootstrap.platform, 'machine', return_value=host):
                prefix = self.cache / 'install' / target
                (prefix / 'lib').mkdir(parents=True)
                build_root = self.cache / 'build' / target
                self.commands.clear()
                self.invocations.clear()
                bootstrap.main()
                expected = {'sdl', 'sdl-image', 'cmark-gfm', 'ninja', 'freetype',
                            'harfbuzz', 'libunibreak', 'fribidi'}
                if system == 'Darwin':
                    expected.add('libpng')
                self.assertEqual(set(self.configures) - builds,
                                 {str(build_root / name) for name in expected - {'ninja'}})
                builds.update(self.configures)
                ninja = build_root / 'ninja' / 'ninja'
                self.assertTrue(ninja.exists())
                for command, kwargs in self.invocations:
                    if '--bootstrap' in command:
                        self.assertEqual(command[1], str(self.cache / 'src/ninja/configure.py'))
                        self.assertEqual(kwargs['cwd'], ninja.parent)
                    if '-C' in command:
                        self.assertEqual(command[0], str(ninja))
                        self.assertEqual(Path(command[command.index('-C') + 1]).parent, build_root)
                    if 'env' in kwargs:
                        self.assertEqual(kwargs['env']['PATH'].split(bootstrap.os.pathsep)[0],
                                         str(ninja.parent))
                self.commands.clear()
                bootstrap.main()
                self.assertEqual(self.commands, [])


if __name__ == '__main__':
    unittest.main()
