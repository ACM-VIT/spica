#!/usr/bin/env python3
"""Offline contract checks for tools/spica-ui.

These tests intentionally do not start a desktop, build the native binary, or
inspect an application database.  The real desktop cohort belongs to an
explicitly invoked scenario command.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "tools" / "spica-ui"


def load_cli():
    loader = importlib.machinery.SourceFileLoader("spica_ui", str(CLI))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SpicaUiOfflineTests(unittest.TestCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(CLI), *args], cwd=ROOT, text=True,
                              capture_output=True, check=False)

    def test_python_syntax(self):
        result = subprocess.run(["python3", "-m", "py_compile", str(CLI)], cwd=ROOT,
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help_is_offline(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("scenario", result.stdout)
        self.assertIn("ordinary private-desktop", result.stdout)

    def test_launch_dry_run_does_not_require_binary_or_vd(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("launch", "--private", "--provider", "fake",
                                  "--output", directory, "--dry-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"provider": "fake"', result.stdout)
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_root_dry_run_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("--dry-run", "scenario", "disabled-send", "--output", directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"command": "scenario"', result.stdout)
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_input_and_wait_dry_runs_are_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            for command in (("click", "command.send"), ("key", "Return"),
                            ("wait", "--receipt", "accepted"), ("receipt",)):
                result = self.run_cli(*command, "--output", directory, "--dry-run")
                self.assertEqual(result.returncode, 0, (command, result.stderr))
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_rejected_scenario_bounds_fixture_size(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("scenario", "rejected-send", "--output", directory,
                                  "--rejected-bytes", "4096", "--dry-run")
            self.assertEqual(result.returncode, 2)
            self.assertIn("between 4097 and 65536", result.stderr)

    def test_redaction_does_not_leak_account_material(self):
        module = load_cli()
        value = module.redact({"account_directory": "/tmp/private", "nested": {"token": "secret"},
                               "model": "fixture"})
        self.assertEqual(value["account_directory"], "<redacted>")
        self.assertEqual(value["nested"]["token"], "<redacted>")
        self.assertEqual(value["model"], "fixture")
        omitted = module.redact({"draft": "private prompt", "transcript": ["private reply"]})
        self.assertEqual(omitted, {"draft": "<omitted>", "transcript": "<omitted>"})


if __name__ == "__main__":
    unittest.main()
