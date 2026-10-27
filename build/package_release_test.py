"""Offline fixture tests for the release staging boundary."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

try:
    import package_release
except ModuleNotFoundError:  # direct ``python build/package_release_test.py`` invocation
    from build import package_release


@unittest.skipUnless(sys.platform == "linux", "Linux ELF packaging only")
class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.deps = self.root / "deps" / "linux-x86_64"
        self.lib = self.deps / "lib"
        self.lib.mkdir(parents=True)
        self.fonts = self.deps.parent / "fonts"
        self.fonts.mkdir()
        self.assets = self.root / "assets"
        self.assets.mkdir()
        for name in package_release.FONT_NAMES:
            (self.fonts / name).write_bytes(("font:" + name).encode())
        (self.assets / "theme.json").write_text("{}\n")
        self.source = self.root / "src" / "SDL-release-3.4.16"
        self.source.mkdir(parents=True)
        (self.source / "LICENSE.txt").write_text("fixture license text\n")
        self.lock = self.root / "deps.lock.json"
        self.lock.write_text(json.dumps({"schema": 1, "sources": {
            "SDL": {"version": "release-3.4.16", "url": "offline", "sha256": "a" * 64},
            "Inter": {"version": "fixture", "sha256": "b" * 64},
            "JetBrainsMono": {"version": "fixture", "sha256": "c" * 64},
        }}))
        self.font_notice = self.root / "OFL.txt"
        self.font_notice.write_text("fixture font license\n")
        self._compile_fixture()

    def tearDown(self):
        self.temp.cleanup()

    def _compile_fixture(self, runpath="$ORIGIN/../lib"):
        source = self.root / "fixture.c"
        source.write_text("int spica_fixture(void) { return 7; }\n")
        subprocess.run(["cc", "-fPIC", "-shared", "-Wl,-soname,libSDL3.so.0",
                        "-o", str(self.lib / "libSDL3.so.0"), str(source)], check=True)
        if not (self.lib / "libSDL3.so").exists():
            (self.lib / "libSDL3.so").symlink_to("libSDL3.so.0")
        main = self.root / "main.c"
        main.write_text("extern int spica_fixture(void); int main(void) { return spica_fixture() != 7; }\n")
        self.binary = self.root / "spica"
        subprocess.run(["cc", str(main), "-L" + str(self.lib), "-lSDL3",
                        "-Wl,-rpath," + runpath, "-o", str(self.binary)], check=True)

    def command(self, destination, *extra):
        return package_release.main([
            "--binary", str(self.binary), "--destination", str(destination),
            "--deps-root", str(self.deps), "--font-root", str(self.fonts),
            "--assets-root", str(self.assets), "--lock", str(self.lock),
            "--source", "SDL=" + str(self.source),
            "--notice", "Inter=" + str(self.font_notice),
            "--notice", "JetBrainsMono=" + str(self.font_notice), *extra,
        ])

    def test_stages_pinned_elf_resources_and_hash_manifest(self):
        destination = self.root / "out"
        self.assertEqual(self.command(destination), 0)
        self.assertTrue((destination / "bin/spica").exists())
        self.assertTrue((destination / "lib/libSDL3.so.0").exists())
        manifest = json.loads((destination / "manifest.json").read_text())
        self.assertEqual(manifest["layout"]["executable"], "bin/spica")
        self.assertEqual(manifest["binary"]["elf"]["runpaths"], ["$ORIGIN/../lib"])
        self.assertTrue(manifest["binary"]["elf"]["interpreter"].startswith("/"))
        self.assertEqual(len(manifest["fonts"]), 6)
        self.assertTrue(manifest["licenses"])
        self.assertEqual({row["dependency"] for row in manifest["licenses"]}, {"SDL", "Inter", "JetBrainsMono"})
        self.assertIn("share/spica/fonts/Inter.ttf", {row["path"] for row in manifest["files"]})
        records = {record["path"]: record for record in package_release.files_manifest(destination)}
        self.assertEqual(records["bin/spica"]["sha256"], manifest["binary"]["sha256"])
        expected_manifest_hash = hashlib.sha256((destination / "manifest.json").read_bytes()).hexdigest()
        self.assertTrue((destination / "manifest.sha256").read_text().startswith(expected_manifest_hash))

    def test_existing_destination_is_never_overwritten(self):
        destination = self.root / "out"
        destination.mkdir()
        marker = destination / "marker"
        marker.write_text("keep")
        self.assertNotEqual(self.command(destination), 0)
        self.assertEqual(marker.read_text(), "keep")

    def test_checkout_runpath_is_rejected(self):
        self._compile_fixture("$ORIGIN/../../.deps/install/linux-x86_64/lib")
        destination = self.root / "out"
        self.assertNotEqual(self.command(destination), 0)
        self.assertFalse(destination.exists())

    def test_unresolved_pinned_dependency_fails_before_staging(self):
        (self.lib / "libSDL3.so.0").unlink()
        destination = self.root / "out"
        self.assertNotEqual(self.command(destination), 0)
        self.assertFalse(destination.exists())

    def test_escaping_asset_symlink_is_rejected(self):
        outside = self.root / "outside.txt"
        outside.write_text("outside")
        (self.assets / "escape").symlink_to(outside)
        destination = self.root / "out"
        self.assertNotEqual(self.command(destination), 0)
        self.assertFalse(destination.exists())

    def test_asset_directory_symlink_is_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.assets / "escape-directory").symlink_to(outside, target_is_directory=True)
        destination = self.root / "out"
        self.assertNotEqual(self.command(destination), 0)
        self.assertFalse(destination.exists())

    def test_manifest_does_not_include_unselected_checkout_files(self):
        (self.root / "unselected-secret").write_text("not packaged")
        destination = self.root / "out"
        self.assertEqual(self.command(destination), 0)
        paths = {entry["path"] for entry in package_release.files_manifest(destination)}
        self.assertNotIn("unselected-secret", paths)

    def test_moved_package_resolves_indirect_pinned_dependencies_without_changing_sources(self):
        source = self.root / "leaf.c"
        source.write_text("int spica_leaf(void) { return 7; }\n")
        leaf = self.lib / "libleaf.so.0"
        subprocess.run(["cc", "-fPIC", "-shared", "-Wl,-soname,libleaf.so.0",
                        "-o", str(leaf), str(source)], check=True)
        (self.lib / "libleaf.so").symlink_to(leaf.name)
        middle = self.root / "middle.c"
        middle.write_text("extern int spica_leaf(void); int spica_fixture(void) { return spica_leaf(); }\n")
        library = self.lib / "libSDL3.so.0"
        subprocess.run(["cc", "-fPIC", "-shared", "-Wl,-soname,libSDL3.so.0",
                        "-L" + str(self.lib), "-Wl,-rpath," + str(self.lib),
                        "-o", str(library), str(middle), "-lleaf"], check=True)
        source_hash = hashlib.sha256(library.read_bytes()).hexdigest()
        destination = self.root / "stage"
        self.assertEqual(self.command(destination), 0)
        self.assertEqual(source_hash, hashlib.sha256(library.read_bytes()).hexdigest())
        moved = self.root / "moved 世界 package"
        destination.rename(moved)
        # Remove the fixture's source libraries to prove no checkout fallback.
        shutil.rmtree(self.lib)
        subprocess.run([str(moved / "bin/spica")], cwd="/", check=True)
        manifest = json.loads((moved / "manifest.json").read_text())
        report = next(row for row in manifest["library_relocations"] if row["path"] == "lib/libSDL3.so.0")
        self.assertEqual(report["original_runpaths"], [str(self.lib)])
        self.assertEqual(report["runpaths"], ["$ORIGIN"])
        self.assertEqual(report["source_sha256"], source_hash)
        self.assertNotEqual(report["source_sha256"], report["staged_sha256"])

    def test_atomic_publication_never_replaces_raced_empty_destination(self):
        source = self.root / "temporary"
        source.mkdir()
        (source / "marker").write_text("candidate")
        destination = self.root / "raced"
        destination.mkdir()
        with self.assertRaises(FileExistsError):
            package_release.publish_noreplace(source, destination)
        self.assertEqual(list(destination.iterdir()), [])
        self.assertEqual((source / "marker").read_text(), "candidate")

    def test_extra_runpath_entry_is_rejected(self):
        self._compile_fixture("$ORIGIN/../lib:relative-user-directory")
        self.assertNotEqual(self.command(self.root / "out"), 0)

    def test_missing_font_notice_refuses_incomplete_package(self):
        self.font_notice.unlink()
        destination = self.root / "out"
        self.assertNotEqual(self.command(destination), 0)
        self.assertFalse(destination.exists())

    def test_records_indirect_system_runtime_dependencies(self):
        system = self.root / "host-libraries"
        system.mkdir()
        leaf = system / "libhostleaf.so.0"
        leaf_source = system / "leaf.c"
        leaf_source.write_text("int host_leaf(void) { return 7; }\n")
        subprocess.run(["cc", "-shared", "-fPIC", "-Wl,-soname,libhostleaf.so.0",
                        str(leaf_source), "-o", str(leaf)], check=True)
        parent = system / "libhostparent.so.0"
        parent_source = system / "parent.c"
        parent_source.write_text("extern int host_leaf(void); int host_parent(void) { return host_leaf(); }\n")
        subprocess.run(["cc", "-shared", "-fPIC", "-Wl,-soname,libhostparent.so.0",
                        str(parent_source), str(leaf), "-o", str(parent)], check=True)
        source = self.root / "library.c"
        source.write_text("extern int host_parent(void); int spica_fixture(void) { return host_parent(); }\n")
        subprocess.run(["cc", "-shared", "-fPIC", "-Wl,-soname,libSDL3.so.0",
                        str(source), str(parent), "-o", str(self.lib / "libSDL3.so.0")], check=True)
        mapping = package_release.system_library_map()
        mapping.update({leaf.name: str(leaf), parent.name: str(parent)})
        destination = self.root / "out"
        with patch.object(package_release, "system_library_map", return_value=mapping):
            self.assertEqual(self.command(destination), 0)
        manifest = json.loads((destination / "manifest.json").read_text())
        requirements = {entry["name"] for entry in manifest["system_runtime_dependencies"]}
        self.assertTrue({leaf.name, parent.name}.issubset(requirements))
        self.assertFalse((destination / "lib" / leaf.name).exists())


if __name__ == "__main__":
    unittest.main()
