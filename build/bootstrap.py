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

def patch_native(path, old, new, count=1):
    """Apply one audited allocator change, rejecting upstream source drift."""
    text = path.read_text()
    if text.count(new) == count and old not in text.replace(new, ''):
        return
    if text.count(old) != count or new in text:
        raise RuntimeError(f'{path}: allocator patch no longer matches pinned source')
    path.write_text(text.replace(old, new))


def configure_image_allocators(sdl, image, codecs):
    # SDL captures these functions in each error buffer, so replacing them is
    # ownership-safe. Otherwise decoder errors allocate outside the job hooks.
    patch_native(sdl / 'src/thread/SDL_thread.c',
                 'SDL_GetOriginalMemoryFunctions(NULL, NULL, &realloc_func, &free_func);',
                 'SDL_GetMemoryFunctions(NULL, NULL, &realloc_func, &free_func);')
    patch_native(sdl / 'src/thread/SDL_thread.c',
                 '        SDL_SetTLS(&tls_errbuf, errbuf, SDL_FreeErrBuf);',
                 '        if (!SDL_SetTLS(&tls_errbuf, errbuf, SDL_FreeErrBuf)) {\n'
                 '            SDL_FreeErrBuf(errbuf);\n'
                 '            return SDL_GetStaticErrBuf();\n'
                 '        }')
    for name, source in codecs.items():
        destination = image / 'external' / name
        if destination.is_symlink():
            if destination.resolve() != source.resolve():
                raise RuntimeError(f'{destination}: unexpected codec source link')
        else:
            # Discard only the old generated vendored copy, never the pinned
            # source. All future builds share that source through a symlink.
            if destination.exists():
                shutil.rmtree(destination)
            destination.symlink_to(source, target_is_directory=True)
    # Custom libpng hooks cover creation, row/metadata heaps, and zlib's
    # png_zalloc/png_zfree without changing unrelated libpng allocation owners.
    png_loader = image / 'src/IMG_libpng.c'
    patch_native(png_loader,
                 'png_structp (*png_create_read_struct)(png_const_charp user_png_ver, png_voidp error_ptr, png_error_ptr error_fn, png_error_ptr warn_fn);',
                 'png_structp (*png_create_read_struct_2)(png_const_charp user_png_ver, png_voidp error_ptr, png_error_ptr error_fn, png_error_ptr warn_fn, png_voidp mem_ptr, png_malloc_ptr malloc_fn, png_free_ptr free_fn);')
    patch_native(png_loader,
                 'FUNCTION_LOADER_LIBPNG(png_create_read_struct, png_structp(*)(png_const_charp user_png_ver, png_voidp error_ptr, png_error_ptr error_fn, png_error_ptr warn_fn))',
                 'FUNCTION_LOADER_LIBPNG(png_create_read_struct_2, png_structp(*)(png_const_charp user_png_ver, png_voidp error_ptr, png_error_ptr error_fn, png_error_ptr warn_fn, png_voidp mem_ptr, png_malloc_ptr malloc_fn, png_free_ptr free_fn))')
    patch_native(png_loader, 'struct png_load_vars\n{',
                 'static png_voidp PNGCBAPI spica_png_malloc(png_structp png_ptr, png_alloc_size_t size)\n'
                 '{\n    (void)png_ptr;\n    return SDL_malloc(size);\n}\n\n'
                 'static void PNGCBAPI spica_png_free(png_structp png_ptr, png_voidp ptr)\n'
                 '{\n    (void)png_ptr;\n    SDL_free(ptr);\n}\n\n'
                 'static void PNGCBAPI spica_png_error(png_structp png_ptr, png_const_charp message)\n'
                 '{\n    SDL_SetError("%s", message);\n    png_longjmp(png_ptr, 1);\n}\n\n'
                 'static void PNGCBAPI spica_png_warning(png_structp png_ptr, png_const_charp message)\n'
                 '{\n    (void)png_ptr;\n    SDL_SetError("%s", message);\n}\n\n'
                 'struct png_load_vars\n{')
    patch_native(png_loader,
                 'lib.png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL)',
                 'lib.png_create_read_struct_2(PNG_LIBPNG_VER_STRING, NULL, spica_png_error, spica_png_warning, NULL, spica_png_malloc, spica_png_free)',
                 count=2)
    jpeg = codecs['jpeg']
    # Use the upstream no-backing-store manager: jmemansi's tmpfile/stdio heap
    # cannot be included through jpeg's allocation callbacks.
    patch_native(jpeg / 'CMakeLists.txt',
                 'target_sources(jpeg PRIVATE jmemansi.c)',
                 'target_sources(jpeg PRIVATE jmemnobs.c)')
    patch_native(jpeg / 'jmemnobs.c', '#include "jinclude.h"',
                 '#include "jinclude.h"\n#include <SDL3/SDL_stdinc.h>')
    patch_native(jpeg / 'jmemnobs.c', ' malloc(sizeofobject);',
                 ' SDL_malloc(sizeofobject);', count=2)
    patch_native(jpeg / 'jmemnobs.c', '  free(object);', '  SDL_free(object);', count=2)
    webp = codecs['libwebp']
    patch_native(webp / 'src/utils/utils.c', '#include <stdlib.h>',
                 '#include <stdlib.h>\n#include <SDL3/SDL_stdinc.h>')
    patch_native(webp / 'src/utils/utils.c', 'ptr = malloc((size_t)(nmemb * size));',
                 'ptr = SDL_malloc((size_t)(nmemb * size));')
    patch_native(webp / 'src/utils/utils.c', 'ptr = calloc((size_t)nmemb, size);',
                 'ptr = SDL_calloc((size_t)nmemb, size);')
    patch_native(webp / 'src/utils/utils.c', '  free(ptr);', '  SDL_free(ptr);')
    # All decode/demux heaps use WebPSafe*. Their utils object libraries need
    # SDL's headers; final codec libraries need ordinary SDL symbol resolution.
    patch_native(image / 'CMakeLists.txt',
                 'add_subdirectory(external/jpeg external/jpeg-build EXCLUDE_FROM_ALL)',
                 'add_subdirectory(external/jpeg external/jpeg-build EXCLUDE_FROM_ALL)\n'
                 '            target_link_libraries(jpeg PRIVATE SDL3::SDL3-shared)')
    patch_native(image / 'CMakeLists.txt',
                 'add_subdirectory(external/libwebp external/libwebp-build EXCLUDE_FROM_ALL)',
                 'add_subdirectory(external/libwebp external/libwebp-build EXCLUDE_FROM_ALL)\n'
                 '        target_link_libraries(webputils PRIVATE SDL3::Headers)\n'
                 '        target_link_libraries(webputilsdecode PRIVATE SDL3::Headers)\n'
                 '        target_link_libraries(webp PRIVATE SDL3::SDL3-shared)\n'
                 '        target_link_libraries(webpdecoder SDL3::SDL3-shared)')


def allocator_fingerprint():
    # Include patch rules, CMake flags, platform, and all locked source versions.
    # A preexisting .so is not evidence that it uses the inclusive allocator.
    digest = hashlib.sha256(Path(__file__).read_bytes())
    digest.update((ROOT / 'deps.lock.json').read_bytes())
    digest.update((platform.system() + platform.machine()).encode())
    return digest.hexdigest()


def build_is_current(library, stamp, fingerprint):
    return library.exists() and stamp.exists() and stamp.read_text() == fingerprint

def build_highlighting(prefix, fingerprint):
    core = acquire('tree-sitter')
    grammars = {name: acquire('tree-sitter-' + name)
                for name in ('zig', 'json', 'javascript', 'python')}
    libraries = prefix / 'lib'
    libraries.mkdir(parents=True, exist_ok=True)
    shutil.copytree(core / 'lib' / 'include' / 'tree_sitter',
                    prefix / 'include' / 'tree_sitter', dirs_exist_ok=True)
    system = platform.system()
    if system not in ('Linux', 'Darwin'):
        raise RuntimeError('Native Tree-sitter bootstrap currently requires a Unix C toolchain; Windows artifacts are not verified')
    suffix = '.dylib' if system == 'Darwin' else '.so'
    shared = '-dynamiclib' if system == 'Darwin' else '-shared'
    runtime = libraries / ('libtree-sitter' + suffix)
    runtime_stamp = prefix / '.tree-sitter-allocator-config'
    if not build_is_current(runtime, runtime_stamp, fingerprint):
        identity = ['-Wl,-install_name,@rpath/' + runtime.name] if system == 'Darwin' else ['-Wl,-soname,' + runtime.name]
        subprocess.run(['cc', '-std=c11', '-D_DEFAULT_SOURCE', '-O2', '-fPIC', shared,
                        '-I' + str(core / 'lib' / 'include'),
                        '-I' + str(core / 'lib' / 'src'),
                        str(core / 'lib' / 'src' / 'lib.c'),
                        *identity, '-o', str(runtime)], check=True)
        runtime_stamp.write_text(fingerprint)
    for name, source in grammars.items():
        library = libraries / ('libspica-tree-sitter-' + name + suffix)
        stamp = prefix / ('.tree-sitter-' + name + '-allocator-config')
        if build_is_current(library, stamp, fingerprint):
            continue
        sources = [str(source / 'src' / 'parser.c')]
        scanner = source / 'src' / 'scanner.c'
        if scanner.exists():
            sources.append(str(scanner))
        loader = ['-Wl,-rpath,@loader_path'] if system == 'Darwin' else ['-Wl,-rpath,$ORIGIN', '-Wl,-z,defs']
        subprocess.run(['cc', '-std=c11', '-O2', '-fPIC', shared,
                        '-DTREE_SITTER_REUSE_ALLOCATOR', '-I' + str(source / 'src'),
                        *sources, '-L' + str(libraries), '-ltree-sitter',
                        *loader, '-o', str(library)], check=True)
        stamp.write_text(fingerprint)


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
    codecs = {name: acquire(name) for name in ('jpeg', 'libpng', 'libwebp', 'zlib')}
    configure_image_allocators(sdl, image, codecs)
    fingerprint = allocator_fingerprint()
    acquire_font('JetBrainsMono', 'fonts/ttf/JetBrainsMono-Regular.ttf', 'JetBrainsMono-Regular.ttf')
    acquire_font('Inter', 'InterVariable.ttf', 'Inter.ttf')
    acquire_font('Inter', 'InterVariable-Italic.ttf', 'InterVariable-Italic.ttf')
    for style in ('Bold', 'Italic', 'BoldItalic'):
        filename = 'JetBrainsMono-' + style + '.ttf'
        acquire_font('JetBrainsMono', 'fonts/ttf/' + filename, filename)
    machine = platform.machine().lower()
    machine = {'amd64': 'x86_64', 'arm64': 'aarch64'}.get(machine, machine)
    system = {'darwin': 'macos', 'windows': 'windows'}.get(platform.system().lower(), platform.system().lower())
    prefix = CACHE / 'install' / (system + '-' + machine)
    build_highlighting(prefix, fingerprint)
    library = prefix / 'lib' / ('libSDL3.dylib' if system == 'macos' else 'libSDL3.so')
    sdl_stamp = prefix / '.sdl-allocator-config'
    if not build_is_current(library, sdl_stamp, fingerprint):
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
        sdl_stamp.write_text(fingerprint)
    image_library = prefix / 'lib' / ('libSDL3_image.dylib' if system == 'macos' else 'libSDL3_image.so')
    image_stamp = prefix / '.image-allocator-config'
    if not build_is_current(image_library, image_stamp, fingerprint):
        build = CACHE / 'build' / 'sdl-image'
        subprocess.run(['cmake', '-S', str(image), '-B', str(build),
                        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={prefix}',
                        f'-DCMAKE_PREFIX_PATH={prefix}', '-DBUILD_SHARED_LIBS=ON',
                        '-DSDLIMAGE_VENDORED=ON', '-DSDLIMAGE_STRICT=ON',
                        '-DSDLIMAGE_BACKEND_STB=OFF', '-DSDLIMAGE_BACKEND_WIC=OFF',
                        '-DSDLIMAGE_BACKEND_IMAGEIO=OFF', '-DSDLIMAGE_PNG_LIBPNG=ON',
                        '-DSDLIMAGE_JPG_SHARED=OFF', '-DSDLIMAGE_PNG_SHARED=OFF',
                        '-DSDLIMAGE_WEBP_SHARED=OFF', '-DSDLIMAGE_ZLIB_SHARED=OFF',
                        '-DWEBP_USE_THREAD=OFF',
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
        image_stamp.write_text(fingerprint)
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
