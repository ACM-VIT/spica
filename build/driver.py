#!/usr/bin/env python3
"""Run Zig builds with a macOS SDK accepted by both native and Zig compilers."""
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def sdk_candidates(environment):
    explicit = environment.get('SDKROOT')
    if explicit:
        # An explicit SDK is a constraint, not a suggestion.
        return [Path(subprocess.check_output(
            ['xcrun', '--sdk', explicit, '--show-sdk-path'],
            env=environment, text=True).strip())]
    active = Path(subprocess.check_output(
        ['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
        env=environment, text=True).strip()).resolve()
    roots = [active.parent, Path('/Library/Developer/CommandLineTools/SDKs')]
    candidates = {sdk.resolve() for root in roots for sdk in root.glob('MacOSX*.sdk')}
    def version(sdk):
        return tuple(int(part) for part in re.findall(r'\d+', sdk.name))
    return [active, *sorted(candidates - {active}, key=version, reverse=True)]


def libc_config(sdk):
    return '\n'.join([
        f'include_dir={sdk / "usr/include"}',
        f'sys_include_dir={sdk / "usr/include"}',
        'crt_dir=', 'msvc_lib_dir=', 'kernel32_lib_dir=', 'gcc_dir=', '',
    ])


def select_sdk(environment, directory):
    source = directory / 'probe.cpp'
    source.write_text('#include <cmath>\n#include <string>\n'
                      'int main() { std::string s("sdk"); return s.empty() || std::isinf(1.0); }\n')
    config = directory / 'macos.libc'
    failures = []
    for sdk in sdk_candidates(environment):
        config.write_text(libc_config(sdk))
        candidate_env = dict(environment, SDKROOT=str(sdk), ZIG_LIBC=str(config))
        commands = [
            ['cc', str(source), '-lc++', '-isysroot', str(sdk), '-o', str(directory / 'native-probe')],
            ['zig', 'c++', '-isysroot', str(sdk),
             str(source), '-o', str(directory / 'zig-probe')],
        ]
        for command in commands:
            result = subprocess.run(command, env=candidate_env, capture_output=True, text=True)
            if result.returncode:
                failures.append(f'{sdk}: {command[0]} failed\n{result.stderr[-2000:]}')
                break
        else:
            print(f'[build] macOS SDK: {sdk}', file=sys.stderr, flush=True)
            return candidate_env
    raise RuntimeError('No installed macOS SDK works with both cc and Zig. '
                       'Install compatible Xcode/Command Line Tools or set SDKROOT explicitly.\n'
                       + '\n'.join(failures))


def main():
    environment = os.environ.copy()
    # Keep the libc file alive throughout the build and any bootstrap subprocesses.
    with tempfile.TemporaryDirectory(prefix='spica-sdk-') as temporary:
        if platform.system() == 'Darwin':
            environment = select_sdk(environment, Path(temporary))
        return subprocess.call(['zig', 'build', *sys.argv[1:]], cwd=ROOT, env=environment)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f'[build] {error}', file=sys.stderr)
        sys.exit(1)
