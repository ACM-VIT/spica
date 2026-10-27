#!/usr/bin/env python3
"""Stage a relocatable Linux Spica release from a prebuilt binary.

This command deliberately does not build, download, install, deploy, or run the
application. It selects local inputs using ELF metadata and the dependency lock,
then normalizes library RUNPATHs with patchelf in staging copies only. A
destination is published atomically and must not already exist.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Iterable


ROOT = Path(__file__).resolve().parent.parent
FONT_NAMES = (
    "Inter.ttf",
    "InterVariable-Italic.ttf",
    "JetBrainsMono-Regular.ttf",
    "JetBrainsMono-Bold.ttf",
    "JetBrainsMono-Italic.ttf",
    "JetBrainsMono-BoldItalic.ttf",
)
EXPECTED_RUNPATH = "$ORIGIN/../lib"
MAX_ASSET_COUNT = 1024
MAX_ASSET_BYTES = 512 * 1024 * 1024
MAX_FILE_BYTES = 256 * 1024 * 1024
LICENSE_BASENAMES = re.compile(r"^(?:license|licence|copying|notice|copyright)(?:[._-].*)?$", re.I)
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+-]*$")


class PackageError(RuntimeError):
    """An actionable packaging failure."""


def fail(message: str) -> None:
    raise PackageError(message)


def publish_noreplace(source: Path, destination: Path) -> None:
    """Linux atomic publication must not replace even an empty raced directory."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = getattr(libc, "renameat2", None)
    if rename is None:
        fail("atomic release publication requires Linux renameat2")
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def parse_assignment(value: str, option: str) -> tuple[str, Path]:
    if "=" not in value:
        fail(f"{option} requires NAME=PATH (got {value!r})")
    name, raw_path = value.split("=", 1)
    if not NAME_RE.fullmatch(name):
        fail(f"{option}: unsafe name {name!r}")
    if not raw_path:
        fail(f"{option}: empty path for {name}")
    return name, Path(raw_path).expanduser()


def run_readelf(path: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["readelf", *args, str(path)], capture_output=True, text=True, check=False,
            env={**os.environ, "LC_ALL": "C"}, timeout=30,
        )
    except OSError as exc:
        fail(f"cannot inspect ELF {path}: readelf is unavailable ({exc})")
    if result.returncode:
        detail = (result.stderr or result.stdout).strip().splitlines()[-1:]
        suffix = f": {detail[0]}" if detail else ""
        fail(f"cannot inspect ELF {path}{suffix}")
    return result.stdout


def elf_dynamic(path: Path) -> dict[str, object]:
    output = run_readelf(path, "-dW")
    needed = re.findall(r"\(NEEDED\).*?\[([^]]+)\]", output)
    tags = re.findall(r"\((RPATH|RUNPATH)\).*?\[([^]]*)\]", output)
    runpaths = [value for _, value in tags]
    if "Dynamic section" not in output:
        fail(f"{path}: not a dynamic ELF executable/library")
    header = run_readelf(path, "-hW")
    identity = {}
    for name in ("Class", "Machine"):
        match = re.search(r"^\s*" + name + r":\s*(.+)$", header, re.M)
        if not match:
            fail(f"{path}: missing ELF {name}")
        identity[name.lower()] = match.group(1).strip()
    return {"needed": needed, "runpaths": runpaths, "dynamic": output, "identity": identity}


def elf_interpreter(path: Path) -> str | None:
    output = run_readelf(path, "-lW")
    match = re.search(r"Requesting program interpreter:\s*([^]]+)\]", output)
    return match.group(1) if match else None


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(root.resolve(strict=False))
        return True
    except ValueError:
        return False


def reject_source_symlink(path: Path, root: Path, label: str) -> None:
    if not inside(path, root):
        fail(f"{label}: symlink escapes its allowed root ({path})")
    if path.is_symlink() and os.readlink(path).startswith("/"):
        fail(f"{label}: absolute symlink is not relocatable ({path})")


def check_regular(path: Path, label: str, *, maximum: int = MAX_FILE_BYTES) -> None:
    if not path.exists():
        fail(f"{label}: missing {path}")
    if path.is_symlink():
        fail(f"{label}: symlink is not allowed here ({path})")
    if not path.is_file():
        fail(f"{label}: not a regular file ({path})")
    size = path.stat().st_size
    if size > maximum:
        fail(f"{label}: file is too large ({size} bytes, limit {maximum})")


def copy_one(source: Path, destination: Path, root: Path, label: str) -> None:
    reject_source_symlink(source, root, label)
    if source.is_symlink():
        target = os.readlink(source)
        if target.startswith("/"):
            fail(f"{label}: absolute symlink is not allowed ({source})")
        resolved = source.parent.joinpath(target).resolve()
        if not inside(resolved, root):
            fail(f"{label}: symlink escapes its allowed root ({source} -> {target})")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            fail(f"destination collision at {destination}")
        os.symlink(target, destination)
        return
    check_regular(source, label)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        fail(f"destination collision at {destination}")
    shutil.copyfile(source, destination)
    shutil.copymode(source, destination, follow_symlinks=False)


def hash_file(path: Path) -> tuple[str, int, str]:
    if path.is_symlink():
        data = ("symlink:" + os.readlink(path)).encode()
        return hashlib.sha256(data).hexdigest(), len(data), "symlink"
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size, "file"


def files_manifest(root: Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if path.is_dir():
            continue
        digest, size, kind = hash_file(path)
        entries.append({"path": path.relative_to(root).as_posix(), "sha256": digest,
                        "size": size, "type": kind})
    return entries


def system_library_map() -> dict[str, str]:
    """Return loader-known system libraries without using ldd or executing code."""
    try:
        result = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True, check=False)
    except OSError:
        return {}
    found: dict[str, str] = {}
    for line in result.stdout.splitlines():
        match = re.match(r"\s*(\S+)\s+\([^)]*\)\s+=>\s+(\S+)", line)
        if match and Path(match.group(2)).is_absolute():
            found.setdefault(match.group(1), match.group(2))
    return found


def source_candidates(source: Path) -> list[Path]:
    candidates = []
    for path in sorted(source.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        if LICENSE_BASENAMES.fullmatch(path.name):
            candidates.append(path)
    return candidates


def source_lock_name(name: str, lock: dict[str, object]) -> str:
    if name in lock:
        return name
    lowered = name.lower()
    for candidate in lock:
        if candidate.lower() == lowered:
            return candidate
    fail(f"dependency {name!r} is absent from the dependency lock")


def source_tree_hash(source: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(source.rglob("*")):
        if path.is_dir() or path.is_symlink():
            continue
        relative = path.relative_to(source).as_posix().encode()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    return digest.hexdigest()


def dynamic_source_name(soname: str) -> str | None:
    base = soname.removeprefix("lib")
    base = re.sub(r"\.so(?:\.[0-9.]+)?$", "", base)
    aliases = {
        "SDL3": "SDL", "SDL3_image": "SDL_image", "freetype": "FreeType",
        "harfbuzz": "HarfBuzz", "fribidi": "fribidi", "unibreak": "libunibreak",
        "tree-sitter": "tree-sitter", "cmark-gfm": "cmark-gfm", "png16": "libpng",
        "jpeg": "jpeg", "webp": "libwebp", "webpdemux": "libwebp",
        "webpmux": "libwebp", "z": "zlib",
    }
    return aliases.get(base)


class Stager:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.project_root = args.project_root.resolve()
        self.binary = args.binary.resolve()
        self.deps_root = args.deps_root.resolve()
        self.destination = args.destination.expanduser().absolute()
        self.source_specs = dict(parse_assignment(v, "--source") for v in args.source)
        self.notice_specs = [parse_assignment(v, "--notice") for v in args.notice]
        self.static_names = list(args.static_dependency)
        self.grammar_specs = [parse_assignment(v, "--grammar") for v in args.grammar]
        self.system = system_library_map()
        self.libraries: dict[str, Path] = {}
        self.library_reports: dict[str, dict[str, object]] = {}
        self.relocations: list[dict[str, object]] = []
        self.system_dependencies: dict[str, str | None] = {}
        self._source_lib_root = self.deps_root / "lib"

    def validate_inputs(self) -> None:
        if sys.platform != "linux":
            fail("release staging currently supports Linux only")
        check_regular(self.binary, "--binary")
        if not os.access(self.binary, os.X_OK):
            fail(f"--binary is not executable: {self.binary}")
        if not self.deps_root.is_dir() or self.deps_root.is_symlink():
            fail(f"--deps-root must be a local directory: {self.deps_root}")
        if not self._source_lib_root.is_dir() or self._source_lib_root.is_symlink():
            fail(f"pinned dependency lib directory is missing: {self._source_lib_root}")
        if self.destination.exists() or self.destination.is_symlink():
            fail(f"refusing to overwrite existing destination: {self.destination}")
        if self.destination.name in ("", ".", ".."):
            fail(f"unsafe destination: {self.destination}")
        if not self.destination.parent.exists() or self.destination.parent.is_symlink():
            fail(f"destination parent must be an existing non-symlink directory: {self.destination.parent}")
        if self.destination == self.binary or inside(self.binary, self.destination):
            fail(f"destination overlaps the prebuilt binary: {self.destination}")
        if not self.args.lock.is_file() or self.args.lock.is_symlink():
            fail(f"dependency lock is missing or unsafe: {self.args.lock}")
        try:
            self.lock = json.loads(self.args.lock.read_text())['sources']
        except (OSError, ValueError, KeyError, TypeError) as exc:
            fail(f"cannot read dependency lock {self.args.lock}: {exc}")
        if not isinstance(self.lock, dict):
            fail(f"dependency lock {self.args.lock}: sources is not an object")

    def validate_runpath(self, report: dict[str, object], path: Path, executable: bool) -> None:
        runpaths = report["runpaths"]
        assert isinstance(runpaths, list)
        for runpath in runpaths:
            for item in str(runpath).split(":"):
                if item.startswith("/") or ".deps" in item or ".." in item and "$ORIGIN" not in item:
                    fail(f"{path}: absolute/checkout ELF RUNPATH is not relocatable: {item}")
        if executable and runpaths != [EXPECTED_RUNPATH]:
            fail(f"{path}: expected ELF RUNPATH {EXPECTED_RUNPATH!r}; existing checkout binaries are not release binaries")
        pinned_needed = [needed for needed in report["needed"]
                         if (self._source_lib_root / str(needed)).exists() or
                         (self._source_lib_root / str(needed)).is_symlink()]
        if not executable and pinned_needed and not any("$ORIGIN" in str(raw) for raw in runpaths):
            fail(f"{path}: bundled library has no $ORIGIN RUNPATH for its pinned dependencies")

    def register_source_for(self, name: str) -> None:
        lock_name = source_lock_name(name, self.lock)
        explicit = [path for key, path in self.notice_specs if source_lock_name(key, self.lock) == lock_name]
        if explicit:
            for path in explicit:
                check_regular(path, f"notice for {lock_name}")
            return
        if name not in self.source_specs and lock_name not in self.source_specs:
            fail(f"no local notice for pinned dependency {lock_name}; pass --source {lock_name}=PATH or --notice {lock_name}=PATH")
        path = self.source_specs.get(name, self.source_specs.get(lock_name))
        assert path is not None
        if not path.is_dir() or path.is_symlink():
            fail(f"source for {lock_name} must be a local directory: {path}")
        notices = source_candidates(path)
        if not notices:
            fail(f"source for {lock_name} has no root/embedded license or copyright text: {path}")

    def stage_library_chain(self, source: Path, relative_name: str, staging: Path) -> None:
        if not NAME_RE.fullmatch(relative_name):
            fail(f"unsafe ELF dependency name: {relative_name!r}")
        if relative_name in self.libraries:
            return
        candidate = source / relative_name
        reject_source_symlink(candidate, source, "pinned library")
        if not candidate.exists():
            fail(f"pinned dependency {relative_name} is unresolved in {source}")
        destination = staging / "lib" / relative_name
        copy_one(candidate, destination, source, "pinned library")
        self.libraries[relative_name] = destination
        if candidate.is_symlink():
            target = os.readlink(candidate)
            target_path = candidate.parent.joinpath(target).resolve()
            self.stage_library_chain(source, target_path.relative_to(source).as_posix(), staging)
        else:
            # RUNPATH is not transitive. Every staged library must resolve its
            # own pinned dependencies locally, including dependency leaves.
            report = elf_dynamic(destination)
            before = hash_file(destination)[0]
            if report["runpaths"] != ["$ORIGIN"]:
                try:
                    result = subprocess.run(["patchelf", "--set-rpath", "$ORIGIN", str(destination)],
                                            capture_output=True, text=True, timeout=30, check=False)
                except OSError as exc:
                    fail(f"library relocation requires installed patchelf: {exc}")
                if result.returncode:
                    fail(f"cannot relocate staged library {destination}: {result.stderr.strip()}")
            updated = elf_dynamic(destination)
            if updated["runpaths"] != ["$ORIGIN"] or updated["needed"] != report["needed"]:
                fail(f"staged library relocation changed its dependency contract: {destination}")
            self.relocations.append({"path": f"lib/{relative_name}", "source": str(candidate),
                                     "source_sha256": before, "staged_sha256": hash_file(destination)[0],
                                     "original_runpaths": report["runpaths"], "runpaths": updated["runpaths"]})

    def resolve_dependency(self, needed: str, staging: Path) -> None:
        if not NAME_RE.fullmatch(needed):
            fail(f"unsafe ELF dependency name: {needed!r}")
        if needed in self.libraries or needed in self.system_dependencies:
            return
        candidate = self._source_lib_root / needed
        if candidate.exists() or candidate.is_symlink():
            self.stage_library_chain(self._source_lib_root, needed, staging)
            return
        locked_name = dynamic_source_name(needed)
        if locked_name and (locked_name in self.source_specs or
                            any(key.lower() == locked_name.lower() for key in self.source_specs)):
            fail(f"pinned dependency {needed} is unresolved in {self._source_lib_root}")
        path = self.system.get(needed)
        if path is None:
            fail(f"unresolved ELF dependency {needed}; it is neither pinned in {self._source_lib_root} nor a known system runtime")
        self.system_dependencies[needed] = path

    def inspect_elf_closure(self, path: Path, staging: Path, executable: bool = False) -> None:
        pending = [(path, executable)]
        seen: set[Path] = set()
        while pending:
            current, is_executable = pending.pop()
            real = current.resolve()
            if real in seen:
                continue
            seen.add(real)
            report = elf_dynamic(current)
            if report["identity"] != self.executable_identity:
                fail(f"{current}: ELF architecture does not match the executable")
            self.validate_runpath(report, current, is_executable)
            if is_executable:
                self.library_reports["bin/spica"] = {"needed": report["needed"], "runpaths": report["runpaths"],
                                                     "identity": report["identity"], "interpreter": elf_interpreter(current)}
            else:
                self.library_reports[current.name] = {"needed": report["needed"], "runpaths": report["runpaths"]}
            for needed in report["needed"]:
                before = set(self.libraries)
                self.resolve_dependency(needed, staging)
                if needed in self.libraries:
                    dependency = self.libraries[needed]
                    if dependency.resolve() not in seen:
                        pending.append((dependency, False))
                elif needed not in before:
                    # System dependencies are deliberately recorded, never copied.
                    pass

    def inspect_system_closure(self) -> None:
        # Record indirect host requirements too (for example Brotli common),
        # without copying or executing a system library.
        pending = list(self.system_dependencies)
        seen: set[str] = set()
        while pending:
            name = pending.pop()
            if name in seen:
                continue
            seen.add(name)
            if len(seen) > 256:
                fail("system dependency closure exceeds 256 libraries")
            report = elf_dynamic(Path(self.system_dependencies[name]))
            for needed in report["needed"]:
                if needed in self.libraries or needed in seen:
                    continue
                if needed not in self.system:
                    fail(f"unresolved indirect system dependency {needed} required by {name}")
                self.system_dependencies[needed] = self.system[needed]
                pending.append(needed)

    def collect_resources(self, staging: Path) -> None:
        assets_root = self.args.assets_root.resolve()
        if not assets_root.is_dir() or assets_root.is_symlink():
            fail(f"--assets-root must be a local directory: {assets_root}")
        entries = sorted(assets_root.rglob("*"))
        for entry in entries:
            if entry.is_symlink():
                fail(f"asset selection contains a symlink: {entry}")
        assets = [p for p in entries if not p.is_dir()]
        if len(assets) > MAX_ASSET_COUNT:
            fail(f"asset selection exceeds {MAX_ASSET_COUNT} files")
        total = 0
        for source in assets:
            if source.is_symlink():
                fail(f"asset selection contains a symlink: {source}")
            check_regular(source, "asset", maximum=MAX_FILE_BYTES)
            total += source.stat().st_size
            if total > MAX_ASSET_BYTES:
                fail(f"asset selection exceeds {MAX_ASSET_BYTES} bytes")
            copy_one(source, staging / "share/spica/assets" / source.relative_to(assets_root), assets_root, "asset")
        fonts_root = self.args.font_root.resolve()
        if not fonts_root.is_dir() or fonts_root.is_symlink():
            fail(f"--font-root must be a local directory: {fonts_root}")
        for name in FONT_NAMES:
            source = fonts_root / name
            check_regular(source, f"required font {name}", maximum=MAX_FILE_BYTES)
            copy_one(source, staging / "share/spica/fonts" / name, fonts_root, "font")
        for name, source in self.grammar_specs:
            check_regular(source, f"grammar {name}")
            elf_dynamic(source)
            self.stage_library_chain(source.parent, source.name, staging)
            self.inspect_elf_closure(staging / "lib" / source.name, staging)
            source_name = "tree-sitter-" + name if not name.startswith("tree-sitter-") else name
            self.register_source_for("tree-sitter")
            if source_name in self.lock:
                self.register_source_for(source_name)

    def collect_licenses(self, staging: Path) -> list[dict[str, object]]:
        required = set(self.static_names)
        required.update(("Inter", "JetBrainsMono"))
        required.update(dynamic_source_name(name) for name in self.libraries if dynamic_source_name(name))
        required.discard(None)
        for name in required:
            self.register_source_for(str(name))
        for name in self.static_names:
            source_lock_name(name, self.lock)
        records = []
        destination = staging / "share/licenses"
        used: set[str] = set()
        for name, source in sorted(self.source_specs.items()):
            lock_name = source_lock_name(name, self.lock)
            if not source.is_dir() or source.is_symlink():
                fail(f"source for {lock_name} must be a local directory: {source}")
            for notice in source_candidates(source):
                if not inside(notice, source):
                    fail(f"license source escapes dependency root: {notice}")
                suffix = notice.relative_to(source).as_posix().replace("/", "__")
                filename = f"{lock_name}-{suffix}"
                if filename in used:
                    continue
                used.add(filename)
                copy_one(notice, destination / filename, source, "license text")
                records.append({"dependency": lock_name, "source": str(notice), "staged": f"share/licenses/{filename}"})
        for index, (name, source) in enumerate(self.notice_specs):
            lock_name = source_lock_name(name, self.lock)
            check_regular(source, f"notice for {lock_name}")
            filename = f"{lock_name}-{index}-{source.name}"
            copy_one(source, destination / filename, source.parent, "explicit dependency notice")
            records.append({"dependency": lock_name, "source": str(source),
                            "staged": f"share/licenses/{filename}", "origin": "explicit notice"})
        if required and not records:
            fail("license collection is incomplete: no notices were staged for pinned dependencies")
        return records

    def git_provenance(self) -> dict[str, object]:
        result: dict[str, object] = {"project_root": str(self.project_root), "revision": None, "dirty": None}
        try:
            revision = subprocess.run(["git", "-C", str(self.project_root), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
            status = subprocess.run(["git", "-C", str(self.project_root), "status", "--porcelain"], capture_output=True, text=True, check=True).stdout
            result.update(revision=revision, dirty=bool(status))
        except (OSError, subprocess.CalledProcessError):
            result["limitation"] = "git provenance unavailable"
        return result

    def stage(self) -> Path:
        self.validate_inputs()
        executable_report = elf_dynamic(self.binary)
        self.executable_identity = executable_report["identity"]
        self.validate_runpath(executable_report, self.binary, True)
        parent = self.destination.parent
        temporary = Path(tempfile.mkdtemp(prefix=f".{self.destination.name}-", dir=parent))
        try:
            (temporary / "bin").mkdir()
            copy_one(self.binary, temporary / "bin/spica", self.binary.parent, "prebuilt binary")
            self.inspect_elf_closure(temporary / "bin/spica", temporary, True)
            self.collect_resources(temporary)
            self.inspect_system_closure()
            notices = self.collect_licenses(temporary)
            manifest = {
                "schema": 1,
                "layout": {"executable": "bin/spica", "libraries": "lib", "fonts": "share/spica/fonts",
                           "assets": "share/spica/assets", "licenses": "share/licenses"},
                "binary": {"source": str(self.binary), "sha256": hash_file(temporary / "bin/spica")[0],
                           "elf": self.library_reports.get("bin/spica", {})},
                "libraries": sorted(self.library_reports.items()),
                "library_relocations": self.relocations,
                "static_dependencies": self.static_names,
                "files": files_manifest(temporary),
                "grammars": [{"name": n, "source": str(p), "staged": f"lib/{p.name}"} for n, p in self.grammar_specs],
                "fonts": list(FONT_NAMES),
                "assets_root": str(self.args.assets_root.resolve()),
                "licenses": notices,
                "dependency_lock": str(self.args.lock.resolve()),
                "pinned_sources": {name: {"path": str(path.resolve()), "lock": self.lock[source_lock_name(name, self.lock)],
                                           "tree_sha256": source_tree_hash(path)} for name, path in sorted(self.source_specs.items())},
                "system_runtime_dependencies": [{"name": name, "resolved": self.system_dependencies[name]}
                                                 for name in sorted(self.system_dependencies)],
                "provenance": self.git_provenance(),
                "tool": {"argv": sys.argv, "python": sys.version, "readelf": "readelf -dW/-lW"},
                "limitations": ["System runtime libraries are required from the host and are not bundled.",
                                "Lock entries and local source trees are recorded; legal conclusions are intentionally not made.",
                                "A source tree hash is not a re-download or archive verification unless bootstrap provenance supplied it."],
            }
            (temporary / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            digest, _, _ = hash_file(temporary / "manifest.json")
            (temporary / "manifest.sha256").write_text(f"{digest}  manifest.json\n")
            publish_noreplace(temporary, self.destination)
            return self.destination
        except Exception:
            shutil.rmtree(temporary, ignore_errors=True)
            raise


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--binary", type=Path, required=True, help="prebuilt executable (must be an ELF with the release RUNPATH)")
    p.add_argument("--destination", type=Path, required=True, help="new release staging directory; existing paths are refused")
    p.add_argument("--deps-root", type=Path, required=True, help="pinned install prefix containing lib/")
    p.add_argument("--project-root", type=Path, default=ROOT)
    p.add_argument("--lock", type=Path, default=ROOT / "deps.lock.json")
    p.add_argument("--font-root", type=Path, default=None)
    p.add_argument("--assets-root", type=Path, default=None)
    p.add_argument("--source", action="append", default=[], metavar="NAME=PATH", help="pinned local source tree; repeat for static and dynamic dependencies")
    p.add_argument("--notice", action="append", default=[], metavar="NAME=PATH", help="explicit local dependency notice when a source tree is unavailable")
    p.add_argument("--static-dependency", action="append", default=[], metavar="NAME", help="dependency linked statically; requires a matching --source")
    p.add_argument("--grammar", action="append", default=[], metavar="NAME=PATH", help="grammar ELF to stage under lib/; repeat as needed")
    return p


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.font_root is None:
        args.font_root = args.deps_root.parent / "fonts"
    if args.assets_root is None:
        args.assets_root = args.project_root / "assets"
    try:
        destination = Stager(args).stage()
    except PackageError as exc:
        print(f"package-release: error: {exc}", file=sys.stderr)
        return 2
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"package-release: error: {exc}", file=sys.stderr)
        return 2
    print(destination)
    return 0


if __name__ == "__main__":
    sys.exit(main())
