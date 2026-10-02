#!/usr/bin/env python3
"""Format owned Zig/C/C++ sources, or check without changing files."""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ZIG_VERSION = "0.16.0"
CLANG_FORMAT_VERSION = "22.1.8"
NATIVE_SUFFIXES = {".c", ".h", ".cpp"}


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check without changing files")
    args = parser.parse_args()

    zig_version = run(["zig", "version"], capture_output=True, text=True).stdout.strip()
    clang_version = run(["clang-format", "--version"], capture_output=True, text=True).stdout
    if zig_version != ZIG_VERSION or f"clang-format version {CLANG_FORMAT_VERSION}" not in clang_version:
        parser.error(f"requires Zig {ZIG_VERSION} and clang-format {CLANG_FORMAT_VERSION}")

    names = run(["git", "ls-files", "-z"], capture_output=True).stdout.decode().split("\0")
    sources = [name for name in names if name and (
        name in {"build.zig", "build.zig.zon"}
        or (name.startswith("src/") and Path(name).suffix in NATIVE_SUFFIXES | {".zig"})
    )]
    failed = False
    for name in sources:
        is_zig = Path(name).suffix in {".zig", ".zon"}
        command = ["zig", "fmt"] if is_zig else ["clang-format"]
        command += (["--check"] if is_zig else ["--dry-run", "--Werror"]) if args.check else ([] if is_zig else ["-i"])
        result = subprocess.run([*command, name], cwd=ROOT)
        failed |= result.returncode != 0
    if failed:
        print("Run python3 tools/format.py, then stage the intended changes again.", file=sys.stderr)
        return 1
    print(f"Formatting {'checked' if args.check else 'applied'}: {len(sources)} files.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        print(f"Formatting failed: {error}", file=sys.stderr)
        sys.exit(1)
