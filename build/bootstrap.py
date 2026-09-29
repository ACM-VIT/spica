#!/usr/bin/env python3
"""Acquire and build pinned native sources outside Zig's app compilation graph."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
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
    with archive.open('rb') as file:
        actual = hashlib.file_digest(file, 'sha256').hexdigest()
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
    image = acquire('SDL_image')
    markdown = acquire('cmark-gfm')
    unibreak = acquire('libunibreak')
    fribidi = acquire('fribidi')
    meson = acquire('meson')
    ninja = acquire('ninja')
    freetype = acquire('FreeType')
    harfbuzz = acquire('HarfBuzz')
    for codec in ('jpeg', 'libpng', 'libwebp', 'zlib'):
        source = acquire(codec)
        destination = image / 'external' / codec
        if not (destination / 'CMakeLists.txt').exists():
            shutil.copytree(source, destination, dirs_exist_ok=True)
    acquire_font('JetBrainsMono', 'fonts/ttf/JetBrainsMono-Regular.ttf', 'JetBrainsMono-Regular.ttf')
    acquire_font('Inter', 'InterVariable.ttf', 'Inter.ttf')
    machine = platform.machine().lower()
    machine = {'amd64': 'x86_64', 'arm64': 'aarch64'}.get(machine, machine)
    system = {'darwin': 'macos', 'windows': 'windows'}.get(platform.system().lower(), platform.system().lower())
    prefix = CACHE / 'install' / (system + '-' + machine)
    library = prefix / 'lib' / ('libSDL3.dylib' if system == 'macos' else 'libSDL3.so')
    if not library.exists():
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
    image_library = prefix / 'lib' / ('libSDL3_image.dylib' if system == 'macos' else 'libSDL3_image.so')
    if not image_library.exists():
        build = CACHE / 'build' / 'sdl-image'
        subprocess.run(['cmake', '-S', str(image), '-B', str(build),
                        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={prefix}',
                        f'-DCMAKE_PREFIX_PATH={prefix}', '-DBUILD_SHARED_LIBS=ON',
                        '-DSDLIMAGE_VENDORED=ON', '-DSDLIMAGE_STRICT=ON',
                        '-DSDLIMAGE_BACKEND_STB=OFF', '-DSDLIMAGE_BACKEND_WIC=OFF',
                        '-DSDLIMAGE_BACKEND_IMAGEIO=OFF', '-DSDLIMAGE_PNG_LIBPNG=ON',
                        '-DSDLIMAGE_JPG=ON', '-DSDLIMAGE_PNG=ON', '-DSDLIMAGE_GIF=ON',
                        '-DSDLIMAGE_WEBP=ON', '-DSDLIMAGE_PNG_SAVE=ON',
                        '-DSDLIMAGE_ANI=OFF', '-DSDLIMAGE_AVIF=OFF', '-DSDLIMAGE_BMP=OFF',
                        '-DSDLIMAGE_LBM=OFF', '-DSDLIMAGE_PCX=OFF', '-DSDLIMAGE_PNM=OFF',
                        '-DSDLIMAGE_QOI=OFF', '-DSDLIMAGE_SVG=OFF', '-DSDLIMAGE_TGA=OFF',
                        '-DSDLIMAGE_TIF=OFF', '-DSDLIMAGE_XCF=OFF', '-DSDLIMAGE_XPM=OFF',
                        '-DSDLIMAGE_XV=OFF', '-DSDLIMAGE_SAMPLES=OFF', '-DSDLIMAGE_TESTS=OFF'], check=True)
        subprocess.run(['cmake', '--build', str(build), '--parallel', '4'], check=True)
        subprocess.run(['cmake', '--install', str(build)], check=True)
        if not image_library.exists():
            raise RuntimeError(f'SDL_image install did not produce {image_library}')
    cmark_library = prefix / 'lib' / 'libcmark-gfm.a'
    if not cmark_library.exists():
        build = CACHE / 'build' / 'cmark-gfm'
        subprocess.run(['cmake', '-S', str(markdown), '-B', str(build),
                        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={prefix}',
                        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
                        '-DCMARK_TESTS=OFF', '-DCMARK_SHARED=OFF', '-DCMARK_STATIC=ON'], check=True)
        subprocess.run(['cmake', '--build', str(build), '--parallel', '4'], check=True)
        subprocess.run(['cmake', '--install', str(build)], check=True)
        if not cmark_library.exists():
            raise RuntimeError(f'cmark install did not produce {cmark_library}')
    tools = CACHE / 'tools'
    tools.mkdir(exist_ok=True)
    ninja_binary = tools / 'ninja'
    if not ninja_binary.exists():
        subprocess.run([sys.executable, 'configure.py', '--bootstrap'], cwd=ninja, check=True)
        shutil.copy2(ninja / 'ninja', ninja_binary)
    child_env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get('PATH', ''))
    pkg_config = str(prefix / 'lib' / 'pkgconfig')
    child_env['PKG_CONFIG_PATH'] = pkg_config + os.pathsep + child_env.get('PKG_CONFIG_PATH', '')
    freetype_library = prefix / 'lib' / 'libfreetype.so'
    if not freetype_library.exists():
        build = CACHE / 'build' / 'freetype'
        subprocess.run(['cmake', '-S', str(freetype), '-B', str(build),
                        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={prefix}',
                        '-DBUILD_SHARED_LIBS=ON', '-DFT_DISABLE_HARFBUZZ=ON'], check=True)
        subprocess.run(['cmake', '--build', str(build), '--parallel', '4'], check=True)
        subprocess.run(['cmake', '--install', str(build)], check=True)
        if not freetype_library.exists():
            raise RuntimeError(f'FreeType install did not produce {freetype_library}')
    harfbuzz_library = prefix / 'lib' / 'libharfbuzz.so'
    if not harfbuzz_library.exists():
        build = CACHE / 'build' / 'harfbuzz'
        subprocess.run([sys.executable, str(meson / 'meson.py'), 'setup', str(build), str(harfbuzz),
                        '--prefix', str(prefix), '--buildtype=release',
                        '-Ddefault_library=shared', '-Dfreetype=enabled',
                        '-Dglib=disabled', '-Dgobject=disabled', '-Dicu=disabled',
                        '-Dcairo=disabled', '-Dsubset=disabled', '-Draster=disabled',
                        '-Dvector=disabled', '-Dgpu=disabled', '-Dpng=disabled',
                        '-Dutilities=disabled', '-Dtests=disabled', '-Ddocs=disabled',
                        '-Dintrospection=disabled'], env=child_env, check=True)
        subprocess.run([str(ninja_binary), '-C', str(build)], env=child_env, check=True)
        subprocess.run([str(ninja_binary), '-C', str(build), 'install'], env=child_env, check=True)
        if not harfbuzz_library.exists():
            raise RuntimeError(f'HarfBuzz install did not produce {harfbuzz_library}')
    unibreak_library = prefix / 'lib' / 'libunibreak.a'
    if not unibreak_library.exists():
        subprocess.run(['autoreconf', '-fi'], cwd=unibreak, check=True)
        build = CACHE / 'build' / 'libunibreak'
        build.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(unibreak / 'configure'), f'--prefix={prefix}'], cwd=build, check=True)
        subprocess.run(['make', '-j4'], cwd=build, check=True)
        subprocess.run(['make', 'install'], cwd=build, check=True)
        if not unibreak_library.exists():
            raise RuntimeError(f'libunibreak install did not produce {unibreak_library}')
    fribidi_library = prefix / 'lib' / 'libfribidi.so'
    if not fribidi_library.exists():
        build = CACHE / 'build' / 'fribidi'
        subprocess.run([sys.executable, str(meson / 'meson.py'), 'setup', str(build), str(fribidi),
                        '--prefix', str(prefix), '--buildtype=release',
                        '-Ddefault_library=shared', '-Ddocs=false', '-Dbin=false',
                        '-Dtests=false', '-Ddeprecated=false'], env=child_env, check=True)
        subprocess.run([str(ninja_binary), '-C', str(build)], env=child_env, check=True)
        subprocess.run([str(ninja_binary), '-C', str(build), 'install'], env=child_env, check=True)
        if not fribidi_library.exists():
            raise RuntimeError(f'FriBidi install did not produce {fribidi_library}')


if __name__ == '__main__':
    main()
