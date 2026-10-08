#!/usr/bin/env python3
"""Verify native SDL clipboard delivery to a separate process on Linux/macOS."""

import argparse
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


class Event(ctypes.Union):
    _fields_ = [('type', ctypes.c_uint32), ('alignment', ctypes.c_uint64),
                ('padding', ctypes.c_ubyte * 128)]


def load_sdl(library, driver):
    os.environ['SDL_VIDEODRIVER'] = driver
    sdl = ctypes.CDLL(str(library))
    signatures = {
        'SDL_Init': ([ctypes.c_uint32], ctypes.c_bool),
        'SDL_Quit': ([], None),
        'SDL_GetError': ([], ctypes.c_char_p),
        'SDL_GetCurrentVideoDriver': ([], ctypes.c_char_p),
        'SDL_GetVersion': ([], ctypes.c_int),
        'SDL_CreateWindow': ([ctypes.c_char_p, ctypes.c_int, ctypes.c_int,
                              ctypes.c_uint64], ctypes.c_void_p),
        'SDL_DestroyWindow': ([ctypes.c_void_p], None),
        'SDL_CreateRenderer': ([ctypes.c_void_p, ctypes.c_char_p], ctypes.c_void_p),
        'SDL_DestroyRenderer': ([ctypes.c_void_p], None),
        'SDL_SetRenderDrawColor': ([ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint8,
                                    ctypes.c_uint8, ctypes.c_uint8], ctypes.c_bool),
        'SDL_RenderClear': ([ctypes.c_void_p], ctypes.c_bool),
        'SDL_RenderPresent': ([ctypes.c_void_p], ctypes.c_bool),
        'SDL_PollEvent': ([ctypes.POINTER(Event)], ctypes.c_bool),
        'SDL_SetClipboardText': ([ctypes.c_char_p], ctypes.c_bool),
        'SDL_GetClipboardText': ([], ctypes.c_void_p),
        'SDL_free': ([ctypes.c_void_p], None),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(sdl, name)
        function.argtypes = arguments
        function.restype = result
    if not sdl.SDL_Init(0x20):  # SDL_INIT_VIDEO
        raise RuntimeError(sdl.SDL_GetError().decode('utf-8', errors='replace'))
    if sdl.SDL_GetCurrentVideoDriver().decode() != driver:
        sdl.SDL_Quit()
        raise RuntimeError('Requested native video driver was not selected')
    return sdl


def check(sdl, result):
    if not result:
        raise RuntimeError(sdl.SDL_GetError().decode('utf-8', errors='replace'))
    return result


def pump(sdl):
    event = Event()
    while sdl.SDL_PollEvent(ctypes.byref(event)):
        if event.type == 0x100:  # SDL_EVENT_QUIT
            raise RuntimeError('Verification window was closed')


def read_external(sdl, command):
    # A file prevents a long clipboard payload filling a pipe while the sender
    # pumps events to service deferred X11/Wayland/Cocoa data requests.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        with subprocess.Popen(command, stdout=output, stderr=errors) as child:
            deadline = time.monotonic() + 10
            try:
                while child.poll() is None:
                    pump(sdl)
                    if time.monotonic() >= deadline:
                        raise RuntimeError('External clipboard read timed out')
                    time.sleep(0.005)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
            if child.returncode:
                errors.seek(0)
                reason = errors.read(512).decode('utf-8', errors='replace').strip()
                raise RuntimeError(f'External clipboard reader failed: {reason}')
        output.seek(0)
        return output.read()


def verify(sdl, driver, library):
    if driver == 'wayland':
        reader = shutil.which('wl-paste')
        if not reader:
            raise RuntimeError('Wayland verification requires wl-paste')
        command = [reader, '--no-newline']
    elif driver == 'cocoa':
        command = ['/usr/bin/env', 'LC_ALL=en_US.UTF-8',
                   '/usr/bin/pbpaste', '-Prefer', 'txt']
    else:
        # A fresh process has no SDL-local clipboard cache: this reads X11's
        # selection from the sender rather than its own in-memory callback.
        command = [sys.executable, str(Path(__file__).resolve()), '--library',
                   str(library), '--driver', driver, '--read']
    window = check(sdl, sdl.SDL_CreateWindow(
        b'Clipboard verification: click this window to start', 480, 240,
        0 if driver == 'wayland' else 8))  # SDL_WINDOW_HIDDEN
    renderer = None
    try:
        if driver == 'wayland':
            renderer = check(sdl, sdl.SDL_CreateRenderer(window, b'software'))
            check(sdl, sdl.SDL_SetRenderDrawColor(renderer, 60, 70, 120, 255))
            check(sdl, sdl.SDL_RenderClear(renderer))
            check(sdl, sdl.SDL_RenderPresent(renderer))
            print('Click the blue verification window once to grant Wayland '
                  'clipboard ownership. Test text temporarily replaces your clipboard.',
                  flush=True)
            event = Event()
            deadline = time.monotonic() + 120
            while True:
                if time.monotonic() >= deadline:
                    raise RuntimeError('No real user input received; Wayland was not verified')
                if sdl.SDL_PollEvent(ctypes.byref(event)):
                    if event.type in (0x300, 0x401):  # key down / mouse button down
                        break
                    if event.type == 0x100:
                        raise RuntimeError('Verification cancelled')
                else:
                    time.sleep(0.01)
        pointer = check(sdl, sdl.SDL_GetClipboardText())
        try:
            previous = ctypes.string_at(pointer)
        finally:
            sdl.SDL_free(pointer)
        try:
            cases = [
                'Résumé café cafe\u0301 العربية 中文 👩‍💻 🇮🇳\n',
                'Second response\n  indented code\nName\tValue\n\nlast line',
                ('long café 👩‍💻\n' * 9000),
            ]
            for index, text in enumerate(cases, 1):
                expected = text.encode('utf-8')
                buffer = ctypes.create_string_buffer(expected)
                check(sdl, sdl.SDL_SetClipboardText(buffer))
                # The app releases its payload immediately. Mutate and discard
                # ours before another process requests the clipboard data.
                ctypes.memset(ctypes.addressof(buffer), ord('!'), len(expected))
                del buffer
                # Native ownership announcements can arrive after the write
                # returns. Keep pumping and require the actual new payload.
                deadline = time.monotonic() + 3
                actual = b''
                reason = ''
                while time.monotonic() < deadline:
                    try:
                        actual = read_external(sdl, command)
                        reason = ''
                    except RuntimeError as error:
                        reason = str(error)
                    if actual == expected:
                        break
                    pump(sdl)
                    time.sleep(0.01)
                else:
                    raise RuntimeError(f'Case {index}: external text differs '
                                       f'({len(actual)} vs {len(expected)} bytes); {reason}')
                print(f'PASS {driver} case {index}: {len(expected)} bytes', flush=True)
        finally:
            check(sdl, sdl.SDL_SetClipboardText(previous))
            # Let an existing desktop clipboard manager collect restored text.
            for _ in range(20):
                pump(sdl)
                time.sleep(0.005)
    finally:
        if renderer:
            sdl.SDL_DestroyRenderer(renderer)
        sdl.SDL_DestroyWindow(window)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path,
                        help='Path to the locked SDL3 shared library')
    parser.add_argument('--driver', required=True, choices=('x11', 'wayland', 'cocoa'))
    parser.add_argument('--read', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.driver == 'cocoa' and sys.platform != 'darwin':
        parser.error('Cocoa verification must run on macOS')
    if args.driver != 'cocoa' and not sys.platform.startswith('linux'):
        parser.error('X11/Wayland verification must run on Linux')
    library = args.library.resolve(strict=True)
    sdl = load_sdl(library, args.driver)
    try:
        if args.read:
            window = check(sdl, sdl.SDL_CreateWindow(b'Clipboard reader', 32, 32, 8))
            try:
                # X11 discovers the selection owner's MIME types asynchronously.
                for _ in range(20):
                    pump(sdl)
                    time.sleep(0.005)
                text = check(sdl, sdl.SDL_GetClipboardText())
                try:
                    sys.stdout.buffer.write(ctypes.string_at(text))
                finally:
                    sdl.SDL_free(text)
                # Finish pending selection protocol events before destroying
                # the requesting window on X11.
                for _ in range(20):
                    pump(sdl)
                    time.sleep(0.005)
            finally:
                sdl.SDL_DestroyWindow(window)
        else:
            print(f'SDL version {sdl.SDL_GetVersion()}; native driver {args.driver}', flush=True)
            verify(sdl, args.driver, library)
    finally:
        sdl.SDL_Quit()


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
