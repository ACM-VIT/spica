#!/usr/bin/env python3
"""Acquire and build pinned native sources outside Zig's app compilation graph."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.deps'
SOURCES = json.loads((ROOT / 'deps.lock.json').read_text())['sources']


def acquire(name):
    spec = SOURCES[name]
    archive = CACHE / 'archives' / (name.lower() + '-' + spec['version'] + '.tar.gz')
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        with urllib.request.urlopen(spec['url'], timeout=90) as response, archive.open('wb') as output:
            while chunk := response.read(65536):
                output.write(chunk)
    actual = hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest()
    if actual != spec['sha256']:
        raise RuntimeError(f'{name}: locked SHA-256 mismatch: {actual}')
    target = CACHE / 'src' / (name.lower() + '-' + spec['version'])
    if not target.exists():
        target.mkdir(parents=True)
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                parts = Path(member.name).parts
                if len(parts) < 2 or member.issym() or member.islnk() or '..' in parts:
                    continue
                member.name = str(Path(*parts[1:]))
                tar.extract(member, target, filter='data')
    return target



def acquire_font(name, member, filename):
    spec = SOURCES[name]
    archive = CACHE / 'archives' / (name.lower() + '-' + spec['version'] + '.zip')
    destination = CACHE / 'install' / 'fonts' / filename
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        with urllib.request.urlopen(spec['url'], timeout=90) as response, archive.open('wb') as output:
            while chunk := response.read(65536):
                output.write(chunk)
    with archive.open('rb') as file:
        actual = hashlib.file_digest(file, 'sha256').hexdigest()
    if actual != spec['sha256']:
        raise RuntimeError(f'{name}: locked SHA-256 mismatch: {actual}')
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as zipped, zipped.open(member) as source, destination.open('wb') as output:
            while chunk := source.read(65536):
                output.write(chunk)


def main():
    sdl = acquire('SDL')
    acquire('clay')
    acquire_font('Inter', 'InterVariable.ttf', 'Inter.ttf')
    prefix = CACHE / 'install' / (sys.platform + '-' + os.uname().machine)
    library = prefix / 'lib' / 'libSDL3.so'
    if library.exists():
        print(f'Pinned SDL already built: {library}')
        return
    build = CACHE / 'build' / 'sdl'
    subprocess.run(['cmake', '-S', str(sdl), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
                    f'-DCMAKE_INSTALL_PREFIX={prefix}', '-DSDL_SHARED=ON', '-DSDL_STATIC=OFF',
                    '-DSDL_TEST_LIBRARY=OFF', '-DSDL_TESTS=OFF', '-DSDL_EXAMPLES=OFF',
                    '-DSDL_AUDIO=OFF', '-DSDL_JOYSTICK=OFF', '-DSDL_HAPTIC=OFF',
                    '-DSDL_SENSOR=OFF', '-DSDL_CAMERA=OFF', '-DSDL_HIDAPI=OFF',
                    '-DSDL_X11=ON', '-DSDL_WAYLAND=ON', '-DSDL_RENDER=ON'], check=True)
    subprocess.run(['cmake', '--build', str(build), '--parallel', '4'], check=True)
    subprocess.run(['cmake', '--install', str(build)], check=True)
    if not library.exists():
        raise RuntimeError(f'SDL install did not produce {library}')


if __name__ == '__main__':
    main()
